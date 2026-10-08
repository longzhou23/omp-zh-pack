param([string] $Tag = $env:OMP_ZH_VERSION)
# Run on real Windows after publishing the release, with either Windows PowerShell 5.1 or pwsh.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Tag)) { throw 'Pass -Tag or set OMP_ZH_VERSION to an already published release.' }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This verification requires Windows.' }
$sourceRef = $env:OMP_ZH_SOURCE_REF
if ($sourceRef -cnotmatch '^[0-9a-f]{40}$') { throw 'Set OMP_ZH_SOURCE_REF to the public immutable 40-character source commit.' }
$root = Join-Path ([IO.Path]::GetTempPath()) ("omp-zh verify ' " + [Guid]::NewGuid().ToString('N'))
$installer = Join-Path $root 'public-install.ps1'
$oldTls = [Net.ServicePointManager]::SecurityProtocol
$installDir = Join-Path $root "bin with ' quote"
$exe = Join-Path $installDir 'omp.exe'
$previousVersion = [Environment]::GetEnvironmentVariable('OMP_ZH_VERSION')
$previousDir = [Environment]::GetEnvironmentVariable('OMP_ZH_INSTALL_DIR')
function Require([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Run-Isolated([string] $Argument) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = $Argument
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $info.EnvironmentVariables.Clear()
    foreach ($name in @('SystemRoot', 'WINDIR', 'COMSPEC')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $info.EnvironmentVariables[$name] = $value }
    }
    $info.EnvironmentVariables['PATH'] = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
    foreach ($name in @('HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'PI_CODING_AGENT_DIR')) {
        $directory = Join-Path $root $name
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $info.EnvironmentVariables[$name] = $directory
    }
    $info.EnvironmentVariables['TEMP'] = $root
    $info.EnvironmentVariables['TMP'] = $root
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        Require ($process.Start()) 'Could not start the real installed executable.'
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Installed omp $Argument timed out."
        }
        $text = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        Require ($process.ExitCode -eq 0) "Installed omp $Argument failed: $errors"
        return $text
    } finally { $process.Dispose() }
}
function Check-Sidecars([int] $ExpectedCount) {
    $sidecars = @(Get-ChildItem -LiteralPath $installDir -Directory -Filter 'omp-zh-pack.*')
    Require ($sidecars.Count -eq $ExpectedCount) 'Incorrect number of retained release sidecar directories.'
    foreach ($sidecar in $sidecars) {
        foreach ($member in @('LICENSE', 'BUN-LICENSE.md', 'THIRD_PARTY_NOTICES.md', 'THIRD-PARTY-NOTICES.txt', 'VERSION', 'UPSTREAM_VERSION', 'UPSTREAM_COMMIT')) {
            Require ([IO.File]::Exists((Join-Path $sidecar.FullName $member))) "Missing retained sidecar: $member"
        }
        Require ([IO.File]::ReadAllText((Join-Path $sidecar.FullName 'VERSION')).Trim() -ceq $Tag) 'Incorrect retained VERSION.'
    }
}
try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/longzhou23/omp-zh-pack/$sourceRef/install.ps1" -OutFile $installer
    $env:OMP_ZH_VERSION = $Tag
    $env:OMP_ZH_INSTALL_DIR = $installDir
    & $installer
    Require ([IO.File]::Exists($exe)) 'First installation did not produce omp.exe.'
    $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    Check-Sidecars 1
    $help = Run-Isolated '--help'
    Require ($help -match '(?m)^用法\r?$' -and $help -match '(?m)^选项\r?$') 'Installed help is not Chinese.'
    Write-Host (Run-Isolated '--smoke-test')

    # A missing public release must fail without changing the installed program.
    $env:OMP_ZH_VERSION = 'v0.0.0-zh.missing.' + [Guid]::NewGuid().ToString('N')
    $failed = $false
    try { & $installer } catch { $failed = $true; Write-Host "Expected download failure: $($_.Exception.Message)" }
    Require $failed 'Missing-release installation unexpectedly succeeded.'
    Require ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ceq $hash) 'Failed download changed the existing executable.'
    Check-Sidecars 1
    $env:OMP_ZH_VERSION = $Tag

    # Model a locked Windows executable by withholding FileShare.Delete.
    $lock = [IO.File]::Open($exe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = $false
        try { & $installer } catch {
            $failed = $true
            Require ($_.Exception.Message -match '关闭') 'Locked-file failure lacks close/retry guidance.'
            Write-Host "Expected locked-file failure: $($_.Exception.Message)"
        }
        Require $failed 'Replacement unexpectedly succeeded while destination was locked.'
        Require ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ceq $hash) 'Locked replacement changed the existing executable.'
    } finally { $lock.Dispose() }
    Check-Sidecars 1

    # Exercise the exact public quick-install pipeline, including HTTP text decoding.
    Invoke-RestMethod -Uri "https://raw.githubusercontent.com/longzhou23/omp-zh-pack/$sourceRef/install.ps1" | Invoke-Expression
    Check-Sidecars 2
    $backups = @(Get-ChildItem -LiteralPath $installDir -File -Filter 'omp.exe.backup.*')
    Require ($backups.Count -eq 1) 'Repeated installation must retain exactly one unique previous-program backup.'
    Require ((Get-FileHash -LiteralPath $backups[0].FullName -Algorithm SHA256).Hash -ceq $hash) 'Backup does not preserve the previous executable.'
    Write-Host (Run-Isolated '--smoke-test')

    # Exercise the printed recovery operation while retaining the backup.
    $restore = $exe + '.restore.' + [Guid]::NewGuid().ToString('N')
    [IO.File]::Copy($backups[0].FullName, $restore, $false)
    try { [IO.File]::Replace($restore, $exe, $null) }
    finally { if ([IO.File]::Exists($restore)) { Remove-Item -LiteralPath $restore -Force } }
    Require ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ceq $hash) 'Recovery changed the previous executable content.'
    Require ([IO.File]::Exists($backups[0].FullName)) 'Recovery consumed the backup.'
    Write-Host (Run-Isolated '--smoke-test')
    Require (@(Get-ChildItem -LiteralPath $installDir -Force -Filter '.omp-zh-install.*').Count -eq 0) 'Installer left staging files behind.'
    Write-Host "Verified public release $Tag: real smoke test, Chinese help, quoted paths, repeat/backup/recovery, failed download and locked destination."
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $oldTls
    [Environment]::SetEnvironmentVariable('OMP_ZH_VERSION', $previousVersion)
    [Environment]::SetEnvironmentVariable('OMP_ZH_INSTALL_DIR', $previousDir)
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
