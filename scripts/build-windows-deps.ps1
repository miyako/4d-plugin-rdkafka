#!/usr/bin/env pwsh
# Builds the static libraries RDKAFKA.vcxproj links from lib\64, on Windows,
# with the installed MSVC toolchain, from the same pinned, checksummed source
# releases as scripts/build-macos-deps.sh:
#   OpenSSL 1.1.1w    -> libcrypto.lib, libssl.lib   (VC-WIN64A, static, no-asm)
#   zlib 1.3.1        -> libz.lib                    (nmake win32/Makefile.msc)
#   librdkafka 0.11.1 -> librdkafka.lib              (the win32 vcxproj source
#                        list; WITH_SSL + SSPI SASL + zlib + bundled LZ4 come
#                        from src/win32_config.h; matches include/librdkafka/
#                        rdkafka.h, RD_KAFKA_VERSION 0x000b01ff)
#   libjson 7.6.1     -> libjson.lib                 (_internal/Source/*.cpp
#                        with the committed include/libjson headers, like macOS)
#
# Outputs are copied to lib\64, which the vcxproj's AdditionalLibraryDirectories
# already names. WORK (default build/windows-deps; gitignored) holds downloads
# and build trees; a rerun reuses them.
#
# LTCG (/GL) is intentionally NOT used. The plugin compiles its own objects
# with /GL and links /LTCG, and LNK C1047 is caused by LTCG object files
# created by a *different MSVC generation* than the rest of the link - the
# previously committed lib\64 archives were 2017-era v140 builds carrying that
# foreign IL data. A plain (non-LTCG) static library links into an /LTCG link
# from any MSVC generation, so these archives can never reproduce C1047.
#
# usage: pwsh scripts/build-windows-deps.ps1 [-Check]
#   -Check only verifies lib\64 (used by CI on a cache hit). Environment
#   variable WORK overrides the download/build directory.
[CmdletBinding()]
param(
  [switch]$Check
)

$ErrorActionPreference = 'Stop'

$ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$OUT = Join-Path $ROOT 'lib\64'
$WORK = if ($env:WORK) { $env:WORK } else { Join-Path $ROOT 'build\windows-deps' }
$DL = Join-Path $WORK 'dl'

$OPENSSL_URL = 'https://www.openssl.org/source/openssl-1.1.1w.tar.gz'
$OPENSSL_SHA = 'cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8'
$ZLIB_URL    = 'https://zlib.net/fossils/zlib-1.3.1.tar.gz'
$ZLIB_SHA    = '9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23'
$RDKAFKA_URL = 'https://github.com/confluentinc/librdkafka/archive/refs/tags/v0.11.1.tar.gz'
$RDKAFKA_SHA = 'dd035d57c8f19b0b612dd6eefe6e5eebad76f506e302cccb7c2066f25a83585e'
$JSON_URL    = 'https://downloads.sourceforge.net/project/libjson/libjson_7.6.1.zip'
$JSON_SHA    = '07267a3951038ee2e02d26cc41bf8e275668c38f751240d3e78dc979182e7376'

function Import-VsDevEnv {
  # Load the Visual Studio developer environment (cl.exe, nmake.exe, lib.exe,
  # dumpbin.exe, INCLUDE, LIB, PATH) into this process, then prefer the v143
  # (MSVC 14.3x/14.4x) toolset that RDKAFKA.vcxproj builds with, if present.
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found at $vswhere" }
  $vsPath = & $vswhere -latest -products * -property installationPath |
    Select-Object -First 1
  if (-not $vsPath) { throw 'Visual Studio not found' }
  $devCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
  if (-not (Test-Path $devCmd)) { throw "VsDevCmd.bat not found at $devCmd" }
  Write-Host "Visual Studio: $vsPath"
  $envText = & cmd.exe /d /s /c "call `"$devCmd`" -arch=x64 -host_arch=x64 >nul 2>&1 && set"
  if ($LASTEXITCODE -ne 0) { throw "VsDevCmd.bat exited $LASTEXITCODE" }
  foreach ($line in $envText) {
    $i = $line.IndexOf('=')
    if ($i -gt 0) {
      try { Set-Item -Path ("env:" + $line.Substring(0, $i)) -Value $line.Substring($i + 1) }
      catch { } # odd entries (=C:=C:\...) are harmless
    }
  }
  if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw 'cl.exe not on PATH after VsDevCmd'
  }

  $msvcRoot = Join-Path $vsPath 'VC\Tools\MSVC'
  $v143 = Get-ChildItem $msvcRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^14\.[34]\d\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
  if ($v143) {
    $env:PATH = "$(Join-Path $v143.FullName 'bin\Hostx64\x64');$env:PATH"
    $env:INCLUDE = "$(Join-Path $v143.FullName 'include');$env:INCLUDE"
    $env:LIB = "$(Join-Path $v143.FullName 'lib\x64');$env:LIB"
    Write-Host "MSVC toolset: $($v143.Name) (v143)"
  } else {
    Write-Host 'v143 toolset not found, building with the default toolset'
  }
  if (-not (Get-Command nmake.exe -ErrorAction SilentlyContinue)) {
    throw 'nmake.exe not found'
  }
}

function Get-Source {
  # fetch <url> <sha256> <name>: download with retries into $DL, verify checksum
  param([string]$Url, [string]$Sha256, [string]$Name)
  $f = Join-Path $DL $Name
  if (Test-Path $f) {
    $h = (Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLowerInvariant()
    if ($h -eq $Sha256) { Write-Host "$($Name): cached"; return }
    Write-Host "$($Name): bad checksum ($h), re-downloading"
    Remove-Item -Force $f
  }
  for ($i = 1; $i -le 3; $i++) {
    & curl.exe -fSL --retry 3 -o "${f}.tmp" $Url
    if ($LASTEXITCODE -eq 0) { break }
    if ($i -eq 3) { throw "download failed: $Url" }
    Write-Host "download $Url failed (exit $LASTEXITCODE), retrying"
    Start-Sleep -Seconds 10
  }
  $h = (Get-FileHash -Algorithm SHA256 -Path "${f}.tmp").Hash.ToLowerInvariant()
  if ($h -ne $Sha256) { Remove-Item -Force "${f}.tmp"; throw "checksum mismatch: $Url (got $h)" }
  Move-Item -Force "${f}.tmp" $f
}

function Expand-Source {
  # fresh extraction of $Archive into $Dest (tar.gz strips the top directory)
  param([string]$Archive, [string]$Dest)
  if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  if ($Archive -like '*.zip') {
    # tar.exe (libarchive) reads zip, and is present on Windows 10+ / Git
    & tar.exe -xf $Archive -C $Dest
  } else {
    & tar.exe -xzf $Archive -C $Dest --strip-components=1
  }
  if ($LASTEXITCODE -ne 0) { throw "extracting $Archive failed" }
}

function Test-Deps {
  # every library the vcxproj links must be fresh and x64
  $bad = $false
  foreach ($n in @('libcrypto.lib', 'libssl.lib', 'libz.lib', 'librdkafka.lib', 'libjson.lib')) {
    $p = Join-Path $OUT $n
    if (-not (Test-Path $p)) { Write-Error "missing $p"; $bad = $true; continue }
    $m = & dumpbin.exe /headers $p | Select-String 'machine \((x64|ARM64)\)' | Select-Object -First 1
    $arch = if ($m -and $m.Matches.Count -gt 0) { $m.Matches[0].Groups[1].Value } else { 'unknown' }
    Write-Host "$n : $arch"
    if ($arch -ne 'x64') { Write-Error "$n is not an x64 archive"; $bad = $true }
  }
  if ($bad) { throw 'prebuilt library check failed' }
}

Import-VsDevEnv

if ($Check) { Test-Deps; exit 0 }

New-Item -ItemType Directory -Force -Path $DL, $OUT | Out-Null
Get-Source $OPENSSL_URL $OPENSSL_SHA 'openssl-1.1.1w.tar.gz'
Get-Source $ZLIB_URL    $ZLIB_SHA    'zlib-1.3.1.tar.gz'
Get-Source $RDKAFKA_URL $RDKAFKA_SHA 'librdkafka-0.11.1.tar.gz'
Get-Source $JSON_URL    $JSON_SHA    'libjson_7.6.1.zip'

# zlib 1.3.1: static lib with the static CRT (/MT), as the plugin links /MT.
# Makefile.msc's compile rule is `$(CC) -c $(WFLAGS) $(CFLAGS) $<`, so the
# command-line CFLAGS override replaces the default -MD and WFLAGS still adds
# the _CRT_*_NO_DEPRECATE macros.
Write-Host '::group::zlib'
$z = Join-Path $WORK 'zlib'
Expand-Source (Join-Path $DL 'zlib-1.3.1.tar.gz') $z
Push-Location $z
try {
  & nmake.exe /f 'win32\Makefile.msc' zlib.lib 'CFLAGS=-nologo -MT -W3 -O2'
  if ($LASTEXITCODE -ne 0) { throw 'nmake zlib.lib failed' }
} finally { Pop-Location }
$zlibLib = Join-Path $z 'zlib.lib'
if (-not (Test-Path $zlibLib)) { throw "zlib.lib not produced in $z" }
Copy-Item -Force $zlibLib (Join-Path $OUT 'libz.lib')
Write-Host '::endgroup::'

# OpenSSL 1.1.1w: static (no-shared), no-asm (no NASM on the runner), static
# CRT (-MT, as vcpkg does for static triplet). install_sw also lays the headers
# librdkafka's OpenSSL includes need into the prefix.
Write-Host '::group::openssl'
$o = Join-Path $WORK 'openssl'
$oPrefix = Join-Path $WORK 'openssl-prefix'
Expand-Source (Join-Path $DL 'openssl-1.1.1w.tar.gz') $o
Push-Location $o
try {
  & perl.exe Configure VC-WIN64A no-shared no-asm no-tests -MT `
    "--prefix=$oPrefix" "--openssldir=$oPrefix\ssl"
  if ($LASTEXITCODE -ne 0) { throw 'openssl Configure failed' }
  & nmake.exe build_libs
  if ($LASTEXITCODE -ne 0) { throw 'nmake build_libs failed' }
  & nmake.exe install_sw
  if ($LASTEXITCODE -ne 0) { throw 'nmake install_sw failed' }
} finally { Pop-Location }
foreach ($n in @('libcrypto.lib', 'libssl.lib')) {
  $p = Join-Path $oPrefix "lib\$n"
  if (-not (Test-Path $p)) { throw "$n not produced under $oPrefix\lib" }
  Copy-Item -Force $p (Join-Path $OUT $n)
}
Write-Host '::endgroup::'

# librdkafka 0.11.1: static library from the win32 build's own source list
# (win32/librdkafka.vcxproj <ClCompile> items - the same 54 files the shipped
# 2017 archive came from), with LIBRDKAFKA_STATICLIB instead of
# LIBRDKAFKA_EXPORTS like the README's original recipe. Feature flags come
# from src/win32_config.h (included by rd.h): WITH_SSL, WITH_ZLIB,
# WITH_SASL_SCRAM, WITH_SNAPPY, WITH_PLUGINS. rdwin32.h pulls in ws2_32.lib
# and Secur32.lib via #pragma comment(lib, ...), so the plugin's link line
# needs no changes.
Write-Host '::group::librdkafka'
$rk = Join-Path $WORK 'librdkafka'
$rkObj = Join-Path $WORK 'librdkafka-obj'
Expand-Source (Join-Path $DL 'librdkafka-0.11.1.tar.gz') $rk
# the committed header is what the plugin compiles against; it differs from
# the v0.11.1 tag only in doc comments
Copy-Item -Force (Join-Path $ROOT 'include\librdkafka\rdkafka.h') (Join-Path $rk 'src\rdkafka.h')
New-Item -ItemType Directory -Force -Path $rkObj | Out-Null
Get-ChildItem "$rkObj\*.obj" -ErrorAction SilentlyContinue | Remove-Item -Force

[xml]$proj = Get-Content -Raw (Join-Path $rk 'win32\librdkafka.vcxproj')
$srcFiles = @($proj.SelectNodes('//*[local-name()="ClCompile"]') |
  ForEach-Object { $_.GetAttribute('Include') } |
  Where-Object { $_ -like '..\src\*.c' })
if ($srcFiles.Count -ne 54) { throw "expected 54 librdkafka sources, got $($srcFiles.Count)" }

$incs = @("/I$(Join-Path $oPrefix 'include')", "/I$z")
$defs = @('/DWIN32', '/DNDEBUG', '/D_WINDOWS', '/D_USRDLL',
          '/D_CRT_SECURE_NO_WARNINGS', '/DLIBRDKAFKA_STATICLIB')
Push-Location (Join-Path $rk 'win32')
try {
  foreach ($c in $srcFiles) {
    $obj = Join-Path $rkObj (([IO.Path]::GetFileName($c)) -replace '\.c$', '.obj')
    & cl.exe /nologo /c /W3 /O2 /MT @defs @incs "/Fo$obj" $c
    if ($LASTEXITCODE -ne 0) { throw "cl failed: $c" }
  }
} finally { Pop-Location }
& lib.exe /nologo "/OUT:$(Join-Path $OUT 'librdkafka.lib')" `
  @(Get-ChildItem "$rkObj\*.obj" | ForEach-Object { $_.FullName })
if ($LASTEXITCODE -ne 0) { throw 'lib librdkafka failed' }
Write-Host '::endgroup::'

# libjson 7.6.1: upstream sources overlaid with the committed include/libjson
# headers (same JSONOptions.h the plugin compiles with), plus the JSONDefs.h
# pair fix the macOS build applies (JSON_MAP spells "const x"; with x = void *
# that is "const void *", not the map's "void * const").
Write-Host '::group::libjson'
$jsrc = Join-Path $WORK 'json-src'
$J = Join-Path $jsrc 'libjson'
$jObj = Join-Path $WORK 'libjson-obj'
Expand-Source (Join-Path $DL 'libjson_7.6.1.zip') $jsrc
if (-not (Test-Path $J)) { throw "expected $J from $($DL)\libjson_7.6.1.zip" }
Copy-Item -Path (Join-Path $ROOT 'include\libjson\*') -Destination $J -Recurse -Force
$jdefs = Join-Path $J '_internal\Source\JSONDefs.h'
$jsonDefs = Get-Content -Raw $jdefs
if ($jsonDefs -notmatch 'std::pair<x const, y>') {
  $fixed = $jsonDefs.Replace('std::pair<const x, y>', 'std::pair<x const, y>')
  if ($fixed -eq $jsonDefs) { throw 'JSONDefs.h pair fix did not match anything' }
  [IO.File]::WriteAllText($jdefs, $fixed)
}
if (-not (Select-String -Path $jdefs -Pattern 'std::pair<x const, y>' -Quiet)) {
  throw 'JSONDefs.h pair fix not present'
}
New-Item -ItemType Directory -Force -Path $jObj | Out-Null
Get-ChildItem "$jObj\*.obj" -ErrorAction SilentlyContinue | Remove-Item -Force
foreach ($f in Get-ChildItem (Join-Path $J '_internal\Source\*.cpp')) {
  $obj = Join-Path $jObj ($f.BaseName + '.obj')
  & cl.exe /nologo /c /W3 /O2 /MT /DNDEBUG /D_CRT_SECURE_NO_DEPRECATE `
    "/I$J" "/Fo$obj" $f.FullName
  if ($LASTEXITCODE -ne 0) { throw "cl failed: $($f.Name)" }
}
& lib.exe /nologo "/OUT:$(Join-Path $OUT 'libjson.lib')" `
  @(Get-ChildItem "$jObj\*.obj" | ForEach-Object { $_.FullName })
if ($LASTEXITCODE -ne 0) { throw 'lib libjson failed' }
Write-Host '::endgroup::'

Test-Deps
Write-Host 'windows prebuilt libraries ready in lib\64'