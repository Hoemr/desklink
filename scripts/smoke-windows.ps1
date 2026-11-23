param(
    [Parameter(Mandatory)][string]$Binary
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$exe = (Resolve-Path -LiteralPath $Binary).Path
$registry = [Microsoft.Win32.Registry]::CurrentUser
$scheme = 'Software\Classes\rustdesk'
$existing = $registry.OpenSubKey($scheme)
if ($existing) {
    $existing.Dispose()
    throw 'Run this test with a Windows user who has no RustDesk protocol registration.'
}

$id = [guid]::NewGuid().ToString('N')
$folder = Join-Path ([IO.Path]::GetTempPath()) "desklink-smoke-$id"
$handler = Join-Path $folder 'handler.ps1'
$config = Join-Path $folder 'desklink.json'
$record = Join-Path $folder 'url.txt'
$signal = "Local\DesklinkSmoke-$id"
$received = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, $signal)
$registered = $false

try {
    New-Item -ItemType Directory -Path $folder | Out-Null
    @'
param([string]$Uri, [string]$Record, [string]$Signal)
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath $Record -Value $Uri -NoNewline -Encoding UTF8
$event = [Threading.EventWaitHandle]::OpenExisting($Signal)
[void]$event.Set()
$event.Dispose()
'@ | Set-Content -LiteralPath $handler -Encoding UTF8
    @{
        id_server = 'relay.example.com:21116'
        server_key = 'ab+C/de='
        devices = @(
            @{ name = 'smoke'; id = '127.0.0.1:21118' },
            @{ name = 'scoped'; id = '123456789' }
        )
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $config -Encoding UTF8

    $key = $registry.CreateSubKey($scheme)
    $registered = $true
    try {
        $key.SetValue('', 'URL:Desklink smoke fixture')
        $key.SetValue('URL Protocol', '')
        $commandKey = $key.CreateSubKey('shell\open\command')
        try {
            $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $invocation = '"{0}" -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{1}" "%1" "{2}" "{3}"' -f $powershell, $handler, $record, $signal
            $commandKey.SetValue('', $invocation)
        } finally {
            $commandKey.Dispose()
        }
    } finally {
        $key.Dispose()
    }

    $modes = [ordered]@{
        desktop = 'connection/new/'
        files = 'file-transfer/'
        terminal = 'terminal/'
    }
    $targets = [ordered]@{
        smoke = '127.0.0.1:21118'
        scoped = '123456789@relay.example.com:21116?key=ab%2BC%2Fde%3D'
    }
    foreach ($target in $targets.Keys) {
        foreach ($mode in $modes.Keys) {
            & $exe -config $config $mode $target
            if (!$received.WaitOne(15000)) {
                throw "Windows did not invoke the RustDesk handler for $mode $target"
            }
            $expected = "rustdesk://$($modes[$mode])$($targets[$target])"
            $actual = Get-Content -LiteralPath $record -Raw
            if ($actual -cne $expected) {
                throw "Expected $expected, received $actual"
            }
            Write-Output "PASS $mode $actual"
        }
    }
} finally {
    $received.Dispose()
    if ($registered) { $registry.DeleteSubKeyTree($scheme) }
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
}
