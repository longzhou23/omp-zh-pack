& {
    # Windows PowerShell 5.1 / PowerShell 7; also supports irm ... | iex.
    $ErrorActionPreference = 'Stop'
    function Quote-PS([string] $Value) { "'" + $Value.Replace("'", "''") + "'" }
    # ASCII source works in both PS 5.1 -File and irm | iex without a UTF-8 BOM.
    function Get-Text([string] $Value) { [regex]::Unescape($Value) }
    function Assert-RegularFile([string] $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw ((Get-Text '\u62d2\u7edd\u76ee\u5f55\u6216\u91cd\u89e3\u6790\u94fe\u63a5\uff1a{0}') -f $Path)
        }
    }
    function Download-HTTPS([string] $Url, [string] $Path) {
        # Disable automatic redirects so every redirect must remain HTTPS.
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $client = New-Object Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromMinutes(5)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("omp-zh-installer/$version")
        try {
            $uri = [Uri] $Url
            for ($redirect = 0; $redirect -le 10; $redirect++) {
                if ($uri.Scheme -cne 'https') { throw (Get-Text '\u4e0b\u8f7d\u5730\u5740\u6216\u91cd\u5b9a\u5411\u4e0d\u662f HTTPS\u3002') }
                $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try {
                    $status = [int] $response.StatusCode
                    if ($status -in @(301, 302, 303, 307, 308)) {
                        if ($null -eq $response.Headers.Location) { throw (Get-Text '\u4e0b\u8f7d\u91cd\u5b9a\u5411\u7f3a\u5c11\u5730\u5740\u3002') }
                        $uri = [Uri]::new($uri, $response.Headers.Location)
                        continue
                    }
                    $response.EnsureSuccessStatusCode() | Out-Null
                    $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    $output = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
                    try { $source.CopyTo($output) } finally { $output.Dispose(); $source.Dispose() }
                    return
                } finally { $response.Dispose() }
            }
            throw (Get-Text '\u4e0b\u8f7d\u91cd\u5b9a\u5411\u6b21\u6570\u8fc7\u591a\u3002')
        } finally { $client.Dispose(); $handler.Dispose() }
    }
    function Run-Candidate([string] $Argument) {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $temp 'omp.exe'
        $info.Arguments = $Argument
        $info.WorkingDirectory = $temp
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
        foreach ($name in @('HOME', 'USERPROFILE')) { $info.EnvironmentVariables[$name] = Join-Path $temp 'home' }
        $info.EnvironmentVariables['APPDATA'] = Join-Path $temp 'config'
        $info.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $temp 'data'
        foreach ($kind in @('CONFIG', 'DATA', 'CACHE', 'STATE')) {
            $info.EnvironmentVariables["XDG_${kind}_HOME"] = Join-Path $temp $kind.ToLowerInvariant()
        }
        $info.EnvironmentVariables['PI_CODING_AGENT_DIR'] = Join-Path $temp 'agent'
        $info.EnvironmentVariables['TEMP'] = $temp
        $info.EnvironmentVariables['TMP'] = $temp
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        try {
            if (-not $process.Start()) { throw (Get-Text '\u65e0\u6cd5\u542f\u52a8\u5019\u9009\u7a0b\u5e8f\u3002') }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(60000)) {
                $process.Kill()
                $process.WaitForExit()
                throw ((Get-Text '\u5019\u9009\u7a0b\u5e8f {0} \u9a8c\u8bc1\u8d85\u65f6\u3002') -f $Argument)
            }
            $text = $stdout.GetAwaiter().GetResult()
            $errorText = $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { throw ((Get-Text '\u5019\u9009\u7a0b\u5e8f {0} \u5931\u8d25\uff08{1}\uff09\uff1a{2}') -f $Argument, $process.ExitCode, $errorText) }
            return $text
        } finally { $process.Dispose() }
    }

    $temp = $null
    $staged = $null
    $notices = $null
    $installed = $false
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw (Get-Text '\u6b64\u5b89\u88c5\u5668\u4ec5\u652f\u6301 Windows\u3002') }
        # .NET 7 fixed OSArchitecture under ARM64 emulation; older runtimes need
        # IsWow64Process2 because GetNativeSystemInfo can report the emulated ISA.
        $architecture = $null
        if ([Environment]::Version.Major -ge 7) {
            $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        } else {
            if (-not ('OmpZhInstaller.NativeArchitecture' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace OmpZhInstaller {
    public static class NativeArchitecture {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
        public static string Get() {
            ushort processMachine, nativeMachine;
            try {
                if (!IsWow64Process2(new IntPtr(-1), out processMachine, out nativeMachine))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } catch (EntryPointNotFoundException) { return null; }
            if (nativeMachine == 0x8664) return "X64";
            if (nativeMachine == 0xAA64) return "Arm64";
            return "Unsupported-" + nativeMachine.ToString("X4");
        }
    }
}
'@
            }
            $architecture = [OmpZhInstaller.NativeArchitecture]::Get()
        }
        # Only older Windows without IsWow64Process2 use the legacy environment.
        if (-not $architecture) {
            $architecture = $env:PROCESSOR_ARCHITEW6432
            if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
        }
        switch ($architecture) {
            { $_ -in @('X64', 'AMD64') } { $arch = 'x64' }
            'Arm64' { $arch = 'arm64' }
            default { throw ((Get-Text '\u4e0d\u652f\u6301\u6b64 Windows \u67b6\u6784\uff1a{0}\uff1b\u4ec5\u652f\u6301 x64 \u548c arm64\u3002') -f $architecture) }
        }
        $version = 'v18.8.5-zh.3'
        if (Test-Path Env:OMP_ZH_VERSION) { $version = $env:OMP_ZH_VERSION }
        if ($version -cnotmatch '^v[0-9][A-Za-z0-9._-]*$') { throw (Get-Text 'OMP_ZH_VERSION \u5fc5\u987b\u662f\u5b89\u5168\u7684\u53d1\u5e03\u6807\u7b7e\uff0c\u4f8b\u5982 v18.8.5-zh.3\u3002') }
        $installDir = Join-Path $HOME '.local/bin'
        if (Test-Path Env:OMP_ZH_INSTALL_DIR) { $installDir = $env:OMP_ZH_INSTALL_DIR }
        if ([string]::IsNullOrWhiteSpace($installDir)) { throw (Get-Text 'OMP_ZH_INSTALL_DIR \u4e0d\u80fd\u4e3a\u7a7a\u3002') }
        $installDir = [IO.Path]::GetFullPath($installDir)
        $destination = Join-Path $installDir 'omp.exe'
        if (Test-Path -LiteralPath $destination) { Assert-RegularFile $destination }
        Add-Type -AssemblyName System.Net.Http
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('omp-zh-install.' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($temp) | Out-Null
        # Candidate execution and downloads use a directory accessible only to this user.
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.SetOwner($sid)
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $temp -AclObject $acl
        $asset = "omp-zh-windows-$arch.zip"
        $baseUrl = "https://github.com/longzhou23/omp-zh-pack/releases/download/$version"
        Write-Host ((Get-Text '\u6b63\u5728\u4e0b\u8f7d OMP \u4e2d\u6587\u5305 {0}\uff08Windows {1}\uff09\u2026') -f $version, $arch)
        Download-HTTPS "$baseUrl/SHA256SUMS" (Join-Path $temp 'SHA256SUMS')
        $entries = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        foreach ($line in [IO.File]::ReadAllLines((Join-Path $temp 'SHA256SUMS'))) {
            if ($line -cnotmatch '^([0-9a-fA-F]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._-]*)$') { throw (Get-Text 'SHA256SUMS \u5305\u542b\u683c\u5f0f\u65e0\u6548\u7684\u6761\u76ee\u3002') }
            $digest = $Matches[1]
            $name = $Matches[2]
            if ($entries.ContainsKey($name)) { throw ((Get-Text 'SHA256SUMS \u5305\u542b\u91cd\u590d\u6761\u76ee\uff1a{0}') -f $name) }
            $entries[$name] = $digest
        }
        if (-not $entries.ContainsKey($asset)) { throw ((Get-Text 'SHA256SUMS \u7f3a\u5c11\u7cbe\u786e\u6587\u4ef6\u540d\uff1a{0}') -f $asset) }
        Download-HTTPS "$baseUrl/$asset" (Join-Path $temp $asset)
        $actual = (Get-FileHash -LiteralPath (Join-Path $temp $asset) -Algorithm SHA256).Hash
        if ($actual -ine $entries[$asset]) { throw (Get-Text '\u53d1\u884c\u5305 SHA-256 \u6821\u9a8c\u5931\u8d25\u3002') }
        $members = @('omp.exe', 'LICENSE', 'BUN-LICENSE.md', 'THIRD_PARTY_NOTICES.md', 'THIRD-PARTY-NOTICES.txt', 'VERSION', 'UPSTREAM_VERSION', 'UPSTREAM_COMMIT')
        $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $temp $asset))
        try {
            foreach ($entry in $zip.Entries) {
                $name = $entry.FullName
                if ($members -cnotcontains $name -or -not $seen.Add($name)) { throw ((Get-Text 'ZIP \u5305\u542b\u672a\u77e5\u8def\u5f84\u6216\u91cd\u590d\u6761\u76ee\uff1a{0}') -f $name) }
                $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
                if (($unixType -ne 0 -and $unixType -ne 0x8000) -or ($entry.ExternalAttributes -band 0x410)) {
                    throw ((Get-Text 'ZIP \u6761\u76ee\u4e0d\u662f\u666e\u901a\u6587\u4ef6\uff1a{0}') -f $name)
                }
                $input = $entry.Open()
                $output = [IO.File]::Open((Join-Path $temp $name), [IO.FileMode]::CreateNew)
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            }
            if ($seen.Count -ne $members.Count) { throw (Get-Text 'ZIP \u7f3a\u5c11\u5fc5\u9700\u7684\u7a0b\u5e8f\u3001\u6388\u6743\u58f0\u660e\u6216\u7248\u672c\u6587\u4ef6\u3002') }
        } finally { $zip.Dispose() }
        if ([IO.File]::ReadAllText((Join-Path $temp 'VERSION')).Trim() -cne $version) { throw (Get-Text '\u53d1\u884c\u5305 VERSION \u4e0e\u53d1\u5e03\u6807\u7b7e\u4e0d\u4e00\u81f4\u3002') }
        if ([IO.File]::ReadAllText((Join-Path $temp 'UPSTREAM_VERSION')).Trim() -cne 'v18.8.5') { throw (Get-Text '\u53d1\u884c\u5305\u4e0a\u6e38\u7248\u672c\u4e0d\u662f v18.8.5\u3002') }
        if ([IO.File]::ReadAllText((Join-Path $temp 'UPSTREAM_COMMIT')).Trim() -cne '4bf0d9d3e9f910ef4af25dec9733fbb4d6912d4c') { throw (Get-Text '\u53d1\u884c\u5305 UPSTREAM_COMMIT \u4e0e\u56fa\u5b9a\u4e0a\u6e38\u63d0\u4ea4\u4e0d\u4e00\u81f4\u3002') }
        foreach ($dir in @('home', 'config', 'data', 'cache', 'state', 'agent')) { [IO.Directory]::CreateDirectory((Join-Path $temp $dir)) | Out-Null }
        $versionOutput = Run-Candidate '--version'
        if ($versionOutput -notmatch '(?<![0-9.])18\.8\.5(?![0-9.])') { throw (Get-Text '\u5019\u9009\u7a0b\u5e8f\u7248\u672c\u4e0e\u4e0a\u6e38\u7248\u672c\u4e0d\u4e00\u81f4\u3002') }
        $helpOutput = Run-Candidate '--help'
        if ($helpOutput -notmatch '(?m)^\u7528\u6cd5\r?$' -or $helpOutput -notmatch '(?m)^\u9009\u9879\r?$') { throw (Get-Text '\u5019\u9009\u7a0b\u5e8f\u672a\u663e\u793a\u9884\u671f\u7684\u4e2d\u6587\u5e2e\u52a9\u3002') }
        [IO.Directory]::CreateDirectory($installDir) | Out-Null
        $staged = Join-Path $installDir ('.omp-zh-install.' + [Guid]::NewGuid().ToString('N') + '.exe')
        [IO.File]::Copy((Join-Path $temp 'omp.exe'), $staged, $false)
        $notices = Join-Path $installDir ("omp-zh-pack.$version." + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($notices) | Out-Null
        foreach ($member in $members) {
            if ($member -cne 'omp.exe') { [IO.File]::Copy((Join-Path $temp $member), (Join-Path $notices $member), $false) }
        }
        $backup = $null
        try {
            if (Test-Path -LiteralPath $destination) {
                Assert-RegularFile $destination
                $backup = Join-Path $installDir ("omp.exe.backup.$version." + [Guid]::NewGuid().ToString('N'))
                # Same-directory atomic replacement; never delete the old program first.
                [IO.File]::Replace($staged, $destination, $backup)
            } else {
                [IO.File]::Move($staged, $destination)
            }
        } catch {
            throw ((Get-Text '\u65e0\u6cd5\u66ff\u6362 omp.exe\uff1b\u672a\u4e3b\u52a8\u5220\u9664\u73b0\u6709\u7a0b\u5e8f\u3002\u8bf7\u5173\u95ed\u6240\u6709\u6b63\u5728\u4f7f\u7528 omp.exe \u7684\u7ec8\u7aef/\u8fdb\u7a0b\u540e\u91cd\u8bd5\uff0c\u5e76\u68c0\u67e5\u76ee\u5f55\u6743\u9650\u3002{0}') -f $_.Exception.Message)
        }
        $staged = $null
        $installed = $true
        Write-Host ((Get-Text '\u5df2\u5b89\u88c5 OMP \u4e2d\u6587\u5305 {0}\uff1a{1}') -f $version, $destination)
        Write-Host ((Get-Text '\u6388\u6743\u58f0\u660e\u548c\u7248\u672c\u4fe1\u606f\uff1a{0}') -f $notices)
        if ($backup) {
            Write-Host ((Get-Text '\u539f\u7a0b\u5e8f\u5df2\u4fdd\u5b58\u4e3a\u552f\u4e00\u5907\u4efd\uff1a{0}') -f $backup)
            Write-Host (Get-Text '\u6062\u590d\u539f\u7a0b\u5e8f\uff08\u5148\u5173\u95ed omp\uff1b\u4fdd\u7559\u5907\u4efd\uff0c\u4e34\u65f6\u6587\u4ef6\u4e0e\u7a0b\u5e8f\u540c\u76ee\u5f55\uff09\uff1a')
            Write-Host ('  $restore = ' + (Quote-PS ($destination + '.restore.')) + ' + [Guid]::NewGuid().ToString(''N'')')
            Write-Host ('  [IO.File]::Copy(' + (Quote-PS $backup) + ', $restore, $false)')
            Write-Host ('  try { [IO.File]::Replace($restore, ' + (Quote-PS $destination) + ', $null) } finally { if (Test-Path -LiteralPath $restore) { Remove-Item -LiteralPath $restore } }')
        }
        Write-Host (Get-Text '\u4ec5\u4e3a\u5f53\u524d PowerShell \u7ec8\u7aef\u542f\u7528 PATH\uff08\u4e0d\u4fee\u6539\u7528\u6237/\u7cfb\u7edf PATH \u6216\u914d\u7f6e\u6587\u4ef6\uff09\uff1a')
        Write-Host ('  $env:PATH = ' + (Quote-PS ($installDir + ';')) + ' + $env:PATH')
        Write-Host (Get-Text '\u968f\u540e\u8fd0\u884c omp --help\u3002Windows \u6b63\u5728\u4f7f\u7528\u7684\u53ef\u6267\u884c\u6587\u4ef6\u53ef\u80fd\u65e0\u6cd5\u66ff\u6362\uff0c\u8bf7\u5173\u95ed\u540e\u91cd\u8bd5\u3002')
    } catch {
        throw ((Get-Text 'OMP \u4e2d\u6587\u5305\u5b89\u88c5\u5931\u8d25\uff1a{0}') -f $_.Exception.Message)
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $oldTls
        if ($staged -and (Test-Path -LiteralPath $staged)) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
        if (-not $installed -and $notices -and (Test-Path -LiteralPath $notices)) { Remove-Item -LiteralPath $notices -Recurse -Force -ErrorAction SilentlyContinue }
        if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
