#Requires -Version 7.2
[CmdletBinding()]
param([string]$Resolver = (Join-Path $PSScriptRoot 'resolve-build-proxy.ps1'))

$ErrorActionPreference = 'Stop'

$script:failures = 0
function Require([bool]$Condition, [string]$Message) {
    if ($Condition) { return }
    $script:failures++
    Write-Host "FAIL: $Message"
}

function Get-ClosedLoopbackPort {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $closedPort = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()
    return $closedPort
}

# A listening loopback socket stands in for the local proxy client.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
try {
    $livePort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $liveProxy = "socks5h://127.0.0.1:$livePort"
    $reported = @(& $Resolver -Proxy $liveProxy -WarningAction SilentlyContinue)
    Require ($reported.Count -eq 1 -and $reported[0] -ceq $liveProxy) `
        'A reachable proxy is reported unchanged.'
    Write-Host "PASS: reachable proxy reported"
}
finally {
    $listener.Stop()
}

$deadProxy = "socks5h://127.0.0.1:$(Get-ClosedLoopbackPort)"
$reported = @(& $Resolver -Proxy $deadProxy -WarningAction SilentlyContinue)
Require ($reported.Count -eq 0) 'A proxy that refuses connections is dropped.'
Write-Host "PASS: unreachable proxy dropped"

$reported = @(& $Resolver -Proxy 'off' -WarningAction SilentlyContinue)
Require ($reported.Count -eq 0) 'The value "off" disables the proxy.'
Write-Host "PASS: off disables the proxy"

$reported = @(& $Resolver -Proxy 'socks5h://' -WarningAction SilentlyContinue)
Require ($reported.Count -eq 0) 'A proxy URL without host:port is rejected.'
Write-Host "PASS: malformed proxy rejected"

if ($script:failures -ne 0) {
    Write-Host "$($script:failures) proxy resolver check(s) failed."
    exit 1
}
Write-Host 'All proxy resolver checks passed.'
exit 0
