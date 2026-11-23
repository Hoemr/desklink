param(
    [Parameter(Mandatory)] [string] $Upstream,
    [Parameter(Mandatory)] [string] $Bundle,
    [Parameter(Mandatory)] [ValidateSet('x64', 'arm64')] [string] $Architecture,
    [Parameter(Mandatory)] [string] $Output
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$upstreamPath = (Resolve-Path -LiteralPath $Upstream).Path
$bundlePath = (Resolve-Path -LiteralPath $Bundle).Path
$outputPath = [System.IO.Path]::GetFullPath($Output)
if ($outputPath -notlike '*install.exe') { throw 'Name the output *-install.exe to open the installer' }
$exePath = Join-Path $bundlePath 'Desklink.exe'
if (-not (Test-Path -LiteralPath $exePath) -or
    -not (Test-Path -LiteralPath (Join-Path $bundlePath 'librustdesk.dll')) -or
    -not (Test-Path -LiteralPath (Join-Path $bundlePath 'data/app.so'))) {
    throw 'Expected a complete graphical Desklink bundle'
}

$target = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$packer = Join-Path $upstreamPath 'libs/portable'
rustup target add $target
python -m pip install --disable-pip-version-check -r (Join-Path $packer 'requirements.txt')
Push-Location $packer
try {
    python generate.py -f $bundlePath -e $exePath -o . -t $target -l 5
} finally {
    Pop-Location
}
Copy-Item -LiteralPath (Join-Path $upstreamPath "target/$target/release/rustdesk-portable-packer.exe") -Destination $outputPath
