# omp-zh-pack

[OMP / Oh My Pi](https://github.com/can1357/oh-my-pi) 的简体中文终端界面汉化包，非官方项目。提供预编译程序、一行安装脚本和可复现的源码补丁。

## 一行安装

```sh
curl -fsSL https://raw.githubusercontent.com/longzhou23/omp-zh-pack/main/install.sh | sh
```

安装到 `~/.local/bin/omp`，无需 Bun、Node.js 或 Rust。脚本校验发布包的 SHA-256、验证中文帮助输出，然后原子替换程序；已有 `omp` 会备份，不覆盖旧备份。不修改 OMP 配置、账号凭据、会话或 shell 配置。

完整授权声明和版本信息会保存在安装目录下新建的 `omp-zh-pack.<版本>.<随机后缀>/` 目录；安装结束时打印实际路径，便于查询与随程序再分发。

首次安装后，如果找不到命令：

```sh
export PATH="$HOME/.local/bin:$PATH"
omp --help
omp
```

当前预编译包仅支持 **Linux x86_64、glibc、支持 AVX2 的 CPU**。不提供 macOS、Windows、ARM64 或 Alpine/musl 的预编译包；安装脚本会拒绝不支持的平台。已在 Linux x86_64 上验证，其他发行版仍取决于系统库兼容性。

默认安装汉化发布版本 `v18.8.5-zh.1`，基于上游 `v18.8.5`。`omp --version` 显示的是上游版本，不是汉化包版本。

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
  OMP_ZH_VERSION=v18.8.5-zh.1 OMP_ZH_INSTALL_DIR="$HOME/.local/bin" sh
```

也可从 [Releases](https://github.com/longzhou23/omp-zh-pack/releases) 下载 `omp-zh-linux-x64.tar.gz` 和 `SHA256SUMS`，在同一目录执行：

```sh
sha256sum -c SHA256SUMS
tar -xzf omp-zh-linux-x64.tar.gz
./omp --help
```

## 汉化范围

- 欢迎界面、设置及其说明、模型与会话菜单。
- 快捷键帮助、状态提示、工具调用展示。
- 内置登录提示与命令行帮助。

命令名、配置键、模型/提供商 ID、持久化值和协议字段保持原标识。**不修改 AI 默认回复语言**，不自动翻译用户内容或外部服务返回的文本；提供商名称、代码和外部错误可能仍为英文。汉化直接应用于界面文案，不是 `locale` 配置，不提供运行时中英文切换。

## 更新和回退

**官方 `omp update`、自动更新或重装官方版本会覆盖汉化程序。** 需要继续使用中文界面时，请重新运行本仓库安装脚本，或明确指定所需的汉化发布版本。脚本不会替你关闭官方自动更新。

安装完成时会打印原版备份路径和回退命令。执行该命令恢复备份，再重启 OMP；不要删除原版备份。正在运行的会话继续使用旧程序，退出后重启才会切换。

## 从源码构建

本仓库不是上游完整源码镜像。`patches/omp-v18.8.5-zh.patch` 包含汉化及相关行为测试调整，`UPSTREAM_COMMIT` 锁定其基线：

```text
4bf0d9d3e9f910ef4af25dec9733fbb4d6912d4c
```

需要 Git、Bun、Bash 和上游原生构建依赖。以下脚本在 Linux x86_64 上验证；其他系统的构建工具链请参考上游。脚本在临时目录拉取锁定版本、检查并应用补丁、安装锁定依赖并构建，不调用会修改全局 `omp` 链接的上游 `bun setup`。

```sh
git clone https://github.com/longzhou23/omp-zh-pack.git
cd omp-zh-pack
bash build.sh
```

默认产物为 `dist/omp`。若本机已有同版本 OMP 的官方原生模块缓存，脚本可复用；也可通过 `OMP_ZH_NATIVES_DIR` 显式指定目录。Linux x86_64 的缓存不完整时需要 Bazel/Bazelisk 及上游 C/C++ 工具链，以构建 modern 与 baseline 两种原生模块；其他主机构建还需 Rust/Cargo、CMake、pkg-config 等 [上游开发依赖](https://github.com/can1357/oh-my-pi/tree/v18.8.5#development)。`OMP_ZH_BUILD_OUTPUT` 可指定二进制输出路径。

如需修改并重新链接静态 Bun/JavaScriptCore 运行时，可按 [Bun 的授权说明](BUN-LICENSE.md) 构建自己的 Bun，再设置 `BUN_COMPILE_EXECUTABLE_PATH=/绝对路径/自定义/bun bash build.sh`。对应源码与重新链接说明见 [第三方归属说明](THIRD_PARTY_NOTICES.md)。

Linux x86_64 上生成发布包：

```sh
bash package.sh dist/omp
```

输出 `dist/omp-zh-linux-x64.tar.gz` 与 `dist/SHA256SUMS`。归档包含程序、许可证、完整第三方声明及版本元数据；不包含本机配置、凭据、依赖目录或缓存。

## 维护与验证

补丁只承诺适用于锁定的上游提交。升级时先迁移汉化并验证，再更新补丁、版本文件、构建/打包脚本的版本限制及安装脚本默认版本；不要直接把旧补丁套到上游最新版。

发布前应验证：补丁应用、受影响包类型检查、终端行为测试、实际 PTY 中的 `/settings`、`/models`、`/hotkeys`，以及独立程序的 `--smoke-test`。安装流程还应覆盖校验失败、重复安装、带空格的安装目录和已有程序备份。

`v18.8.5-zh.1` 已在 Linux x86_64 上完成锁定源码的隔离构建、发行包校验、公开 GitHub 入口安装和安装后 `--smoke-test`。实测覆盖带空格及单引号的安装目录、符号链接原程序备份、重复安装不覆盖旧备份、运行中程序的原子替换与备份恢复；下载后人为破坏校验和时，安装器拒绝替换并保留原程序。不支持的平台、非法版本标签和目录型目标也已验证拒绝安装。

## 授权与归属

汉化包按 [MIT License](LICENSE) 开源，保留上游作者版权声明。OMP、Bun 和其他依赖各自保留其许可证与商标权；见 [第三方归属说明](THIRD_PARTY_NOTICES.md)、[Bun 授权说明](BUN-LICENSE.md) 和随发行包分发的 [完整第三方声明](THIRD-PARTY-NOTICES.txt)。
