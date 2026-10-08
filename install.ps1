& {
    # Windows PowerShell 5.1 / PowerShell 7; also supports irm ... | iex.
    $ErrorActionPreference = 'Stop'
    function Quote-PS([string] $Value) { "'" + $Value.Replace("'", "''") + "'" }
    function Assert-RegularFile([string] $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "拒绝目录或重解析链接：$Path"
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
                if ($uri.Scheme -cne 'https') { throw '下载地址或重定向不是 HTTPS。' }
                $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try {
                    $status = [int] $response.StatusCode
                    if ($status -in @(301, 302, 303, 307, 308)) {
                        if ($null -eq $response.Headers.Location) { throw '下载重定向缺少地址。' }
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
            throw '下载重定向次数过多。'
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
            if (-not $process.Start()) { throw '无法启动候选程序。' }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(60000)) {
                $process.Kill()
                $process.WaitForExit()
                throw "候选程序 $Argument 验证超时。"
            }
            $text = $stdout.GetAwaiter().GetResult()
            $errorText = $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { throw "候选程序 $Argument 失败（$($process.ExitCode)）：$errorText" }
            return $text
        } finally { $process.Dispose() }
    }

    $temp = $null
    $staged = $null
    $notices = $null
    $installed = $false
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '此安装器仅支持 Windows。' }
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
            default { throw "不支持此 Windows 架构：$architecture；仅支持 x64 和 arm64。" }
        }
        $version = 'v18.8.5-zh.3'
        if (Test-Path Env:OMP_ZH_VERSION) { $version = $env:OMP_ZH_VERSION }
        if ($version -cnotmatch '^v[0-9][A-Za-z0-9._-]*$') { throw 'OMP_ZH_VERSION 必须是安全的发布标签，例如 v18.8.5-zh.3。' }
        $installDir = Join-Path $HOME '.local/bin'
        if (Test-Path Env:OMP_ZH_INSTALL_DIR) { $installDir = $env:OMP_ZH_INSTALL_DIR }
        if ([string]::IsNullOrWhiteSpace($installDir)) { throw 'OMP_ZH_INSTALL_DIR 不能为空。' }
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
        Write-Host "正在下载 OMP 中文包 $version（Windows $arch）…"
        Download-HTTPS "$baseUrl/SHA256SUMS" (Join-Path $temp 'SHA256SUMS')
        $entries = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        foreach ($line in [IO.File]::ReadAllLines((Join-Path $temp 'SHA256SUMS'))) {
            if ($line -cnotmatch '^([0-9a-fA-F]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._-]*)$') { throw 'SHA256SUMS 包含格式无效的条目。' }
            $digest = $Matches[1]
            $name = $Matches[2]
            if ($entries.ContainsKey($name)) { throw "SHA256SUMS 包含重复条目：$name" }
            $entries[$name] = $digest
        }
        if (-not $entries.ContainsKey($asset)) { throw "SHA256SUMS 缺少精确文件名：$asset" }
        Download-HTTPS "$baseUrl/$asset" (Join-Path $temp $asset)
        $actual = (Get-FileHash -LiteralPath (Join-Path $temp $asset) -Algorithm SHA256).Hash
        if ($actual -ine $entries[$asset]) { throw '发行包 SHA-256 校验失败。' }
        $members = @('omp.exe', 'LICENSE', 'BUN-LICENSE.md', 'THIRD_PARTY_NOTICES.md', 'THIRD-PARTY-NOTICES.txt', 'VERSION', 'UPSTREAM_VERSION', 'UPSTREAM_COMMIT')
        $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $temp $asset))
        try {
            foreach ($entry in $zip.Entries) {
                $name = $entry.FullName
                if ($members -cnotcontains $name -or -not $seen.Add($name)) { throw "ZIP 包含未知路径或重复条目：$name" }
                $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
                if (($unixType -ne 0 -and $unixType -ne 0x8000) -or ($entry.ExternalAttributes -band 0x410)) {
                    throw "ZIP 条目不是普通文件：$name"
                }
                $input = $entry.Open()
                $output = [IO.File]::Open((Join-Path $temp $name), [IO.FileMode]::CreateNew)
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            }
            if ($seen.Count -ne $members.Count) { throw 'ZIP 缺少必需的程序、授权声明或版本文件。' }
        } finally { $zip.Dispose() }
        if ([IO.File]::ReadAllText((Join-Path $temp 'VERSION')).Trim() -cne $version) { throw '发行包 VERSION 与发布标签不一致。' }
        if ([IO.File]::ReadAllText((Join-Path $temp 'UPSTREAM_VERSION')).Trim() -cne 'v18.8.5') { throw '发行包上游版本不是 v18.8.5。' }
        if ([IO.File]::ReadAllText((Join-Path $temp 'UPSTREAM_COMMIT')).Trim() -cne '4bf0d9d3e9f910ef4af25dec9733fbb4d6912d4c') { throw '发行包 UPSTREAM_COMMIT 与固定上游提交不一致。' }
        foreach ($dir in @('home', 'config', 'data', 'cache', 'state', 'agent')) { [IO.Directory]::CreateDirectory((Join-Path $temp $dir)) | Out-Null }
        $versionOutput = Run-Candidate '--version'
        if ($versionOutput -notmatch '(?<![0-9.])18\.8\.5(?![0-9.])') { throw '候选程序版本与上游版本不一致。' }
        $helpOutput = Run-Candidate '--help'
        if ($helpOutput -notmatch '(?m)^用法\r?$' -or $helpOutput -notmatch '(?m)^选项\r?$') { throw '候选程序未显示预期的中文帮助。' }
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
            throw "无法替换 omp.exe；未主动删除现有程序。请关闭所有正在使用 omp.exe 的终端/进程后重试，并检查目录权限。$($_.Exception.Message)"
        }
        $staged = $null
        $installed = $true
        Write-Host "已安装 OMP 中文包 $version：$destination"
        Write-Host "授权声明和版本信息：$notices"
        if ($backup) {
            Write-Host "原程序已保存为唯一备份：$backup"
            Write-Host '恢复原程序（先关闭 omp；保留备份，临时文件与程序同目录）：'
            Write-Host ('  $restore = ' + (Quote-PS ($destination + '.restore.')) + ' + [Guid]::NewGuid().ToString(''N'')')
            Write-Host ('  [IO.File]::Copy(' + (Quote-PS $backup) + ', $restore, $false)')
            Write-Host ('  try { [IO.File]::Replace($restore, ' + (Quote-PS $destination) + ', $null) } finally { if (Test-Path -LiteralPath $restore) { Remove-Item -LiteralPath $restore } }')
        }
        Write-Host '仅为当前 PowerShell 终端启用 PATH（不修改用户/系统 PATH 或配置文件）：'
        Write-Host ('  $env:PATH = ' + (Quote-PS ($installDir + ';')) + ' + $env:PATH')
        Write-Host '随后运行 omp --help。Windows 正在使用的可执行文件可能无法替换，请关闭后重试。'
    } catch {
        throw "OMP 中文包安装失败：$($_.Exception.Message)"
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $oldTls
        if ($staged -and (Test-Path -LiteralPath $staged)) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
        if (-not $installed -and $notices -and (Test-Path -LiteralPath $notices)) { Remove-Item -LiteralPath $notices -Recurse -Force -ErrorAction SilentlyContinue }
        if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
