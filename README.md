# omp-zh-pack

[OMP / Oh My Pi](https://github.com/can1357/oh-my-pi) 的简体中文终端界面汉化包，非官方项目。提供预编译程序、一行安装脚本和可复现的源码补丁。

## 一行安装

### Linux 与 macOS

```sh
curl -fsSL https://raw.githubusercontent.com/longzhou23/omp-zh-pack/main/install.sh | sh
```

安装到 `~/.local/bin/omp`，无需 Bun、Node.js 或 Rust。自动选择当前系统与硬件架构，校验发布包的 SHA-256 和中文帮助，然后原子替换程序；已有 `omp` 会保存为唯一备份。不修改 OMP 配置、账号凭据、会话或 shell 配置。

完整授权声明和版本信息会保存在安装目录下新建的 `omp-zh-pack.<版本>.<随机后缀>/` 目录；安装结束时打印实际路径，便于查询与随程序再分发。

首次安装后，如果找不到命令：

```sh
export PATH="$HOME/.local/bin:$PATH"
omp --help
omp
```

### Windows（PowerShell）

```powershell
irm https://raw.githubusercontent.com/longzhou23/omp-zh-pack/main/install.ps1 | iex
```

支持 Windows PowerShell 5.1 与 PowerShell 7，默认安装到 `$HOME\.local\bin\omp.exe`，无需管理员权限。按 Windows 系统架构选择 x64 或 ARM64，校验下载与中文帮助，保留唯一备份和授权声明。安装器不修改持久化 PATH；仅为当前终端启用：

```powershell
$env:PATH = "$HOME\.local\bin;$env:PATH"
omp --help
omp
```

Windows 正在使用的 `omp.exe` 可能被系统锁定；替换失败时保留原程序，请关闭相关终端和进程后重新安装。安装结束会打印可直接粘贴的恢复命令。

### 支持的平台

| 系统 | 架构 | 发行文件 |
| --- | --- | --- |
| Linux（glibc / AVX2） | x86_64 | `omp-zh-linux-x64.tar.gz` |
| macOS（Intel / AVX2） | x86_64 | `omp-zh-darwin-x64.tar.gz` |
| macOS（Apple Silicon） | ARM64 | `omp-zh-darwin-arm64.tar.gz` |
| Windows | x64 | `omp-zh-windows-x64.zip` |
| Windows | ARM64 | `omp-zh-windows-arm64.zip` |

Apple Silicon 上即使终端通过 Rosetta 运行，也选择原生 ARM64 包。不提供 Linux ARM64 或 Alpine/musl 的预编译包；系统库及安全策略仍需兼容，安装器会先验证候选程序能否运行。macOS 程序使用上游要求的本机 ad-hoc 签名，不是 Apple 开发者公证发行；不会关闭 Gatekeeper 或移除全局安全策略。

默认安装汉化发布版本 `v18.8.5-zh.3`，基于上游 `v18.8.5`。`omp --version` 显示的是上游版本，不是汉化包版本。

### 先查看脚本再安装

```sh
curl -fsSL https://raw.githubusercontent.com/longzhou23/omp-zh-pack/main/install.sh -o install-omp-zh.sh
less install-omp-zh.sh
sh install-omp-zh.sh
```

校验和用于发现下载损坏或发行文件不一致，不是独立签名；一行安装仍需要信任此 GitHub 仓库和 GitHub 发布渠道。

### 指定版本或目录

```sh
curl -fsSL https://raw.githubusercontent.com/longzhou23/omp-zh-pack/main/install.sh |
  OMP_ZH_VERSION=v18.8.5-zh.3 OMP_ZH_INSTALL_DIR="$HOME/.local/bin" sh
```

Windows 使用相同的环境变量：

```powershell
$env:OMP_ZH_VERSION = 'v18.8.5-zh.3'
$env:OMP_ZH_INSTALL_DIR = "$HOME\.local\bin"
irm https://raw.githubusercontent.com/longzhou23/omp-zh-pack/main/install.ps1 | iex
```

也可从 [Releases](https://github.com/longzhou23/omp-zh-pack/releases) 下载表中对应归档和同版本的 `SHA256SUMS`，用 Linux 的 `sha256sum`、macOS 的 `shasum -a 256` 或 PowerShell 的 `Get-FileHash -Algorithm SHA256` 核对该归档对应条目。清单包含全部平台，不能直接对只下载了一个归档的目录校验整份清单。解压后，Unix 运行 `./omp --help`，Windows 运行 `.\omp.exe --help`。

## 汉化范围

- 欢迎界面、设置及其说明、模型与会话菜单。
- 快捷键帮助、状态提示、工具调用展示。
- 内置登录提示与命令行帮助。

命令名、配置键、模型/提供商 ID、持久化值和协议字段保持原标识。**不修改 AI 默认回复语言**，不自动翻译用户内容或外部服务返回的文本；提供商名称、代码和外部错误可能仍为英文。汉化直接应用于界面文案，不是 `locale` 配置，不提供运行时中英文切换。

## 更新和回退

**官方 `omp update`、自动更新或重装官方版本会覆盖汉化程序。** 需要继续使用中文界面时，请重新运行本仓库安装脚本，或明确指定所需的汉化发布版本。脚本不会替你关闭官方自动更新。

安装完成时会打印备份路径和回退命令。执行该命令恢复备份，再重启 OMP；不要删除原版备份。Unix 正在运行的会话继续使用旧程序，退出后重启才会切换；Windows 请先关闭使用程序的进程，再安装或恢复。

## 从源码构建

本仓库不是上游完整源码镜像。`patches/omp-v18.8.5-zh.patch` 包含汉化及相关行为测试调整，`UPSTREAM_COMMIT` 锁定其基线：

```text
4bf0d9d3e9f910ef4af25dec9733fbb4d6912d4c
```

需要 Git、Bun **1.3.14**、Bash 与网络；Windows 可使用 Git for Windows 自带的 Git Bash。脚本在临时目录拉取锁定提交、检查并应用补丁、安装锁定依赖，并从官方 npm 获取同版本的原生模块，校验 SHA-512 与上游版本印记。不运行安装钩子，也不调用会修改全局 `omp` 链接的上游 `bun setup`。

```sh
git clone https://github.com/longzhou23/omp-zh-pack.git
cd omp-zh-pack
bash build.sh
```

默认产物为 `dist/omp`，Windows 为 `dist/omp.exe`。若本机已有同版本 OMP 原生模块缓存，可只读复用；`OMP_ZH_NATIVES_DIR` 可指定缓存目录，缓存未命中则获取同版本官方原生包。无需在本机重新编译 Rust/Bazel 原生模块，不会把 baseline 模块伪装成 modern。`OMP_ZH_BUILD_OUTPUT` 可指定程序输出路径；各平台必须在对应系统和架构上本机构建并验证。

如需修改并重新链接静态 Bun/JavaScriptCore 运行时，可按 [Bun 的授权说明](BUN-LICENSE.md) 构建自己的 Bun，再设置 `BUN_COMPILE_EXECUTABLE_PATH=/绝对路径/自定义/bun bash build.sh`。对应源码与重新链接说明见 [第三方归属说明](THIRD_PARTY_NOTICES.md)。

在对应系统上生成发行包：

```sh
bash package.sh
```

脚本自动选择本机产物，输出对应 `.tar.gz` 或 `.zip` 及 `SHA256SUMS-<平台>`。归档只含程序、完整授权声明与版本信息，不含本机配置、凭据、依赖目录或缓存。Unix 和 Windows 归档均固定成员顺序与时间；`SOURCE_DATE_EPOCH` 可设置归档时间。

## 维护与验证

补丁只承诺适用于锁定的上游提交。升级时先迁移汉化并验证，再更新补丁、版本文件、构建/打包脚本的版本限制及安装脚本默认版本；不要直接把旧补丁套到上游最新版。

发布前应验证：补丁应用、受影响包类型检查、终端行为测试、实际 PTY 中的 `/settings`、`/models`、`/hotkeys`，以及独立程序的 `--smoke-test`。安装流程还应覆盖校验失败、重复安装、带空格的安装目录和已有程序备份。

[跨平台发布工作流](.github/workflows/release.yml) 在 Linux、macOS Intel/Apple Silicon、Windows x64/ARM64 托管主机上分别构建和运行原生检查，全部成功后合并 SHA-256 并公开完整发行版，再从公开 GitHub URL 实测安装、重复备份和恢复。Windows 验证同时运行 PowerShell 5.1 与 PowerShell 7。推送与 `VERSION` 一致的 `v18.8.5-zh.*` 标签触发发布；手动运行工作流只构建，不发布。

`v18.8.5-zh.1` 已在 Linux x86_64 上完成锁定源码的隔离构建、发行包校验、公开 GitHub 入口安装和安装后 `--smoke-test`。实测覆盖带空格及单引号的安装目录、符号链接原程序备份、重复安装不覆盖旧备份、运行中程序的原子替换与备份恢复；下载后人为破坏校验和时，安装器拒绝替换并保留原程序。不支持的平台、非法版本标签和目录型目标也已验证拒绝安装。

## 授权与归属

汉化包按 [MIT License](LICENSE) 开源，保留上游作者版权声明。OMP、Bun 和其他依赖各自保留其许可证与商标权；见 [第三方归属说明](THIRD_PARTY_NOTICES.md)、[Bun 授权说明](BUN-LICENSE.md) 和随发行包分发的 [完整第三方声明](THIRD-PARTY-NOTICES.txt)。
