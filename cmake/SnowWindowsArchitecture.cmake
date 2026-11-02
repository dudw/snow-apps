include_guard(GLOBAL)

function(snow_windows_normalize_architecture output value)
    string(TOLOWER "${value}" _architecture)
    if(_architecture MATCHES "^(x64|amd64|x86_64)$")
        set(_architecture x64)
    elseif(_architecture MATCHES "^(arm64|aarch64)$")
        set(_architecture arm64)
    else()
        message(FATAL_ERROR "Unsupported Windows architecture '${value}': use x64 or arm64")
    endif()
    set(${output} "${_architecture}" PARENT_SCOPE)
endfunction()

# Compiler metadata is authoritative: CMAKE_SYSTEM_PROCESSOR can still describe
# the build host when a Ninja build selects the cross compiler through PATH.
function(snow_configure_windows_architecture)
    if(NOT WIN32)
        return()
    endif()
    if(CMAKE_CXX_COMPILER_ARCHITECTURE_ID)
        set(_compiler_architecture "${CMAKE_CXX_COMPILER_ARCHITECTURE_ID}")
    elseif(MSVC_CXX_ARCHITECTURE_ID)
        set(_compiler_architecture "${MSVC_CXX_ARCHITECTURE_ID}")
    elseif(CMAKE_GENERATOR_PLATFORM)
        set(_compiler_architecture "${CMAKE_GENERATOR_PLATFORM}")
    else()
        set(_compiler_architecture "${CMAKE_SYSTEM_PROCESSOR}")
    endif()
    snow_windows_normalize_architecture(_detected "${_compiler_architecture}")
    if(SNOW_WINDOWS_ARCHITECTURE)
        snow_windows_normalize_architecture(_selected "${SNOW_WINDOWS_ARCHITECTURE}")
        if(NOT _selected STREQUAL _detected)
            message(FATAL_ERROR
                "SNOW_WINDOWS_ARCHITECTURE=${_selected} disagrees with the ${_detected} C++ compiler")
        endif()
    endif()
    if(DEFINED CMAKE_SIZEOF_VOID_P AND NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
        message(FATAL_ERROR "Snow Shot requires a 64-bit Windows compiler")
    endif()
    if(VCPKG_TARGET_TRIPLET)
        if(NOT VCPKG_TARGET_TRIPLET MATCHES "^(x64|arm64)-windows(-.*)?$")
            message(FATAL_ERROR "Unsupported Windows vcpkg target triplet: ${VCPKG_TARGET_TRIPLET}")
        endif()
        if(NOT CMAKE_MATCH_1 STREQUAL _detected)
            message(FATAL_ERROR
                "VCPKG_TARGET_TRIPLET=${VCPKG_TARGET_TRIPLET} disagrees with the ${_detected} C++ compiler")
        endif()
    endif()
    set(SNOW_WINDOWS_ARCHITECTURE "${_detected}" CACHE STRING
        "Windows target architecture: x64 or arm64." FORCE)
    set_property(CACHE SNOW_WINDOWS_ARCHITECTURE PROPERTY STRINGS x64 arm64)
    set(SNOW_WINDOWS_PLATFORM "windows-${_detected}" CACHE INTERNAL
        "Windows release platform selected by the C++ compiler." FORCE)
endfunction()

function(snow_windows_ninja_directory output)
    # shaderc-sys builds the bundled shaderc with the CMake Ninja generator when
    # the OCR worker has no Vulkan SDK, and its build script aborts with
    # "couldn't find required command: ninja" before CMake is started. Visual
    # Studio ships Ninja without exporting it, so look it up next to the tools.
    set(${output} "" PARENT_SCOPE)
    if(NOT WIN32)
        return()
    endif()
    set(_hints)
    if(IS_DIRECTORY "$ENV{SNOW_NINJA_DIR}")
        list(APPEND _hints "$ENV{SNOW_NINJA_DIR}")
    endif()
    if(IS_DIRECTORY "$ENV{VSINSTALLDIR}")
        set(_visual_studio_root "$ENV{VSINSTALLDIR}")
        cmake_path(NORMAL_PATH _visual_studio_root)
        cmake_path(APPEND _visual_studio_root "Common7" "IDE" "CommonExtensions"
            "Microsoft" "CMake" "Ninja" OUTPUT_VARIABLE _visual_studio_ninja)
        if(IS_DIRECTORY "${_visual_studio_ninja}")
            list(APPEND _hints "${_visual_studio_ninja}")
        endif()
    endif()
    find_program(SNOW_NINJA_EXECUTABLE NAMES ninja ninja.exe HINTS ${_hints})
    if(SNOW_NINJA_EXECUTABLE)
        get_filename_component(_directory "${SNOW_NINJA_EXECUTABLE}" DIRECTORY)
        set(${output} "${_directory}" PARENT_SCOPE)
    endif()
endfunction()

function(snow_windows_rust_environment output target)
    set(_environment)
    if(WIN32 AND MSVC)
        set(_c_compiler "${CMAKE_C_COMPILER}")
        if(NOT _c_compiler)
            set(_c_compiler "${CMAKE_CXX_COMPILER}")
        endif()
        string(REPLACE "-" "_" _target_key "${target}")
        string(TOUPPER "${_target_key}" _cargo_target_key)
        list(APPEND _environment
            "CARGO_TARGET_${_cargo_target_key}_LINKER=${CMAKE_LINKER}"
            "CC_${_target_key}=${_c_compiler}"
            "CXX_${_target_key}=${CMAKE_CXX_COMPILER}"
            "AR_${_target_key}=${CMAKE_AR}")
        # A Visual Studio custom build step does not hand the caller's PATH to
        # the cargo process. shaderc then cannot find Ninja, and its nested CMake
        # configure cannot find the resource compiler, so both break while the
        # build script runs. Prepend the configure-time developer PATH one
        # directory at a time: a single PATH=... argument would be split on its
        # ';' separators by COMMAND_EXPAND_LISTS.
        snow_windows_ninja_directory(_ninja_directory)
        set(_developer_path)
        if(_ninja_directory)
            list(APPEND _developer_path "${_ninja_directory}")
        endif()
        list(APPEND _developer_path $ENV{PATH})
        list(REMOVE_DUPLICATES _developer_path)
        # Later prepends win, so walk the list backwards to keep its order.
        list(REVERSE _developer_path)
        foreach(_directory IN LISTS _developer_path)
            if(_directory)
                list(APPEND _environment "--modify"
                    "PATH=path_list_prepend:${_directory}")
            endif()
        endforeach()
    endif()
    set(${output} "${_environment}" PARENT_SCOPE)
endfunction()
