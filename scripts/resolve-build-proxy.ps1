#Requires -Version 7.2
<#
.SYNOPSIS
    Prints the proxy the build should use for dependency downloads, or nothing.
.DESCRIPTION
    vcpkg, cargo, and git all read HTTPS_PROXY/HTTP_PROXY. GitHub, SourceForge, and the Google
    CIPD endpoints time out on networks that cannot reach them directly, and vcpkg turns that
    into a hard port failure. The wrapper only exports a proxy that answers a TCP connect, so a
    stopped local client degrades to a direct download instead of breaking every download.

    SNOW_BUILD_PROXY overrides the endpoint; the value "off" disables the proxy entirely.
.PARAMETER Proxy
    Proxy URL to validate, for example socks5h://127.0.0.1:1080.
.PARAMETER ConnectTimeoutMilliseconds
    How long the reachability probe may take before the proxy is considered down.
#>
[CmdletBinding()]
param(
    [string]$Proxy = $(if ($env:SNOW_BUILD_PROXY) { $env:SNOW_BUILD_PROXY }
        else { 'socks5h://127.0.0.1:1080' }),
    [int]$ConnectTimeoutMilliseconds = 500
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Proxy) -or $Proxy -in @('off', 'none')) {
    return
}

$endpoint = ($Proxy -replace '^[A-Za-z][A-Za-z0-9+.-]*://', '').Split('/')[0]
$parts = $endpoint.Split(':')
$proxyHost = $parts[0]
$portText = if ($parts.Count -gt 1) { $parts[1] } elseif ($Proxy -like 'socks*') { '1080' } else { '8080' }

$proxyPort = 0
if ([string]::IsNullOrWhiteSpace($proxyHost) -or
    -not [int]::TryParse($portText, [ref]$proxyPort) -or
    $proxyPort -lt 1 -or $proxyPort -gt 65535) {
    Write-Warning "Ignoring the build proxy '$Proxy': expected a proxy URL with host:port."
    return
}

$client = [System.Net.Sockets.TcpClient]::new()
try {
    $connect = $client.ConnectAsync($proxyHost, $proxyPort)
    if (-not $connect.Wait($ConnectTimeoutMilliseconds) -or -not $client.Connected) {
        Write-Warning "The build proxy ${proxyHost}:$proxyPort is not reachable; downloads run without it."
        return
    }
} catch {
    Write-Warning "The build proxy ${proxyHost}:$proxyPort is not reachable; downloads run without it."
    return
} finally {
    $client.Dispose()
}

Write-Output $Proxy
