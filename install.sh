#!/bin/sh
# 独立中文包安装器；不修改 OMP 设置、AI 语言或 shell 配置。
set -eu
umask 077

fail() {
    printf '错误：%s\n' "$1" >&2
    exit 1
}

if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 1 ] && [ "$1" = '--help' ]; then
        cat <<'HELP'
OMP 独立中文包安装器（Linux x86_64 / macOS Intel、Apple Silicon）

用法：sh install.sh [--help]
      curl -fsSL https://raw.githubusercontent.com/longzhou23/omp-zh-pack/main/install.sh | sh

环境变量：
  OMP_ZH_VERSION      发布标签，默认 v18.8.6-zh.1
  OMP_ZH_INSTALL_DIR  安装目录，默认 $HOME/.local/bin

安装前校验 SHA-256 和中文帮助；已有 omp 会保存为唯一备份。
不需要 Bun/Rust，不修改配置、AI 语言、PATH 或 shell 配置文件。
HELP
        exit 0
    fi
    fail '仅支持可选参数 --help；请运行 sh install.sh --help。'
fi

version=${OMP_ZH_VERSION-v18.8.6-zh.1}
case "$version" in
    v[0-9]*) ;;
    *) fail 'OMP_ZH_VERSION 必须是以 v 和数字开头的发布标签，例如 v18.8.6-zh.1。' ;;
esac
case "$version" in
    *[!a-zA-Z0-9._-]*) fail 'OMP_ZH_VERSION 仅允许 ASCII 字母、数字、点、下划线和连字符；不允许路径或 URL。' ;;
esac

for command in uname curl tar mktemp cp chmod mv mkdir rm grep env cat tr; do
    command -v "$command" >/dev/null 2>&1 || fail "缺少必要命令 $command；请先通过系统包管理器安装。"
done
if command -v sha256sum >/dev/null 2>&1; then
    hash_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    hash_tool=shasum
else
    fail '缺少 SHA-256 工具；请安装 sha256sum 或 shasum。'
fi
case "$(uname -s)" in
    Linux)
        platform=linux
        case "$(uname -m)" in
            x86_64|amd64) arch=x64 ;;
            *) fail 'Linux 预编译包仅支持 x86_64；其他架构请从源码构建。' ;;
        esac
        command -v getconf >/dev/null 2>&1 || fail '缺少 getconf，无法确认 glibc。'
        libc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || fail '未检测到 glibc；musl/Alpine 不支持此预编译包，请在 glibc 系统安装或从源码构建。'
        case "$libc" in
            'glibc '*) ;;
            *) fail '此预编译包要求 glibc，不支持 musl；请在 glibc 系统安装或从源码构建。' ;;
        esac
        [ -r /proc/cpuinfo ] || fail '无法读取 /proc/cpuinfo，不能确认 AVX2 支持；已取消安装。'
        grep -Eq '(^|[[:space:]])avx2([[:space:]]|$)' /proc/cpuinfo || fail 'CPU 未提供 AVX2；此预编译包无法安全运行，请从源码构建适合该 CPU 的版本。'
        mv_flags=-fT
        ;;
    Darwin)
        platform=darwin
        command -v sysctl >/dev/null 2>&1 || fail '缺少 macOS sysctl，无法确认硬件架构。'
        case "$(uname -m)" in
            arm64|aarch64) arch=arm64 ;;
            x86_64|amd64)
                # Rosetta 中 uname 会报告 x86_64，硬件能力仍能识别 Apple Silicon。
                if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || printf '0')" = 1 ]; then
                    arch=arm64
                else
                    arch=x64
                    cpu_features=$(sysctl -n machdep.cpu.leaf7_features 2>/dev/null) || fail '无法确认 Intel Mac 的 CPU 特性；已取消安装。'
                    printf '%s\n' "$cpu_features" | grep -Eiq '(^|[[:space:]])avx2([[:space:]]|$)' || fail 'Intel Mac 预编译包需要 AVX2；请从源码构建适合该 CPU 的版本。'
                fi
                ;;
            *) fail 'macOS 预编译包仅支持 Intel x86_64 和 Apple Silicon arm64。' ;;
        esac
        mv_flags=-fh
        ;;
    *) fail '此脚本支持 Linux 与 macOS；Windows 请使用仓库中的 install.ps1。' ;;
esac
asset=omp-zh-$platform-$arch.tar.gz

if [ "${OMP_ZH_INSTALL_DIR+x}" = x ]; then
    install_dir=$OMP_ZH_INSTALL_DIR
else
    [ -n "${HOME:-}" ] || fail 'HOME 未设置；请通过 OMP_ZH_INSTALL_DIR 指定安装目录。'
    install_dir=$HOME/.local/bin
fi
[ -n "$install_dir" ] || fail 'OMP_ZH_INSTALL_DIR 不能为空。'
# 使用绝对路径，避免以连字符开头的目录和临时工作目录造成歧义。
case "$install_dir" in
    /*) ;;
    *) install_dir=$PWD/$install_dir ;;
esac
destination=$install_dir/omp
[ ! -d "$destination" ] || fail '安装目标 omp 是目录（或指向目录的符号链接）；请先选择其他安装目录。'

tmp=
staged=
unfinished_backup=
unfinished_notices=
cleanup() {
    if [ -n "$staged" ]; then rm -f -- "$staged"; fi
    if [ -n "$unfinished_backup" ]; then rm -f -- "$unfinished_backup"; fi
    if [ -n "$unfinished_notices" ]; then rm -rf -- "$unfinished_notices"; fi
    if [ -n "$tmp" ]; then rm -rf -- "$tmp"; fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
tmp_parent=${TMPDIR:-/tmp}
case "$tmp_parent" in
    /*) ;;
    *) tmp_parent=$PWD/$tmp_parent ;;
esac
tmp=$(mktemp -d "$tmp_parent/omp-zh-install.XXXXXXXXXX") || fail '无法创建私有临时目录；请检查 TMPDIR 和磁盘空间。'
url=https://github.com/longzhou23/omp-zh-pack/releases/download/$version
printf '正在下载 OMP 中文包 %s…\n' "$version"
# curl 默认仅对临时网络/HTTP 错误重试；不使用 --retry-all-errors。
curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error --retry 3 --output "$tmp/$asset" "$url/$asset" || fail '下载发行包失败；请检查网络及 OMP_ZH_VERSION 对应的 GitHub Release。'
curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error --retry 3 --output "$tmp/SHA256SUMS" "$url/SHA256SUMS" || fail '下载 SHA256SUMS 失败；未修改现有 omp。'

checksum=
while IFS=' ' read -r digest filename extra || [ -n "$digest$filename$extra" ]; do
    case "$filename" in
        "$asset"|"*$asset")
            [ -z "$checksum" ] || fail 'SHA256SUMS 包含重复的发行包条目；已取消安装。'
            [ -z "$extra" ] || fail 'SHA256SUMS 的发行包条目格式无效；已取消安装。'
            [ "${#digest}" -eq 64 ] || fail 'SHA256SUMS 的 SHA-256 长度无效；已取消安装。'
            case "$digest" in
                *[!0-9a-fA-F]*) fail 'SHA256SUMS 包含无效的 SHA-256；已取消安装。' ;;
            esac
            checksum=$digest
            ;;
    esac
done < "$tmp/SHA256SUMS"
[ -n "$checksum" ] || fail "SHA256SUMS 缺少 $asset 的精确文件名条目；已取消安装。"
if [ "$hash_tool" = sha256sum ]; then
    actual_checksum=$(sha256sum < "$tmp/$asset") || fail '无法计算发行包 SHA-256；未修改现有 omp。'
else
    actual_checksum=$(shasum -a 256 < "$tmp/$asset") || fail '无法计算发行包 SHA-256；未修改现有 omp。'
fi
actual_checksum=${actual_checksum%% *}
checksum=$(printf '%s' "$checksum" | tr '[:upper:]' '[:lower:]')
[ "$actual_checksum" = "$checksum" ] || fail '发行包 SHA-256 校验失败；未修改现有 omp，请重新下载或联系维护者。'

# 不让 tar 创建归档中的任何路径或链接：只将固定名称的内容写入私有目录。
for member in omp LICENSE BUN-LICENSE.md THIRD_PARTY_NOTICES.md THIRD-PARTY-NOTICES.txt VERSION UPSTREAM_VERSION UPSTREAM_COMMIT; do
    tar -xzOf "$tmp/$asset" -- "$member" > "$tmp/$member" || fail "发行包缺少或无法读取必需文件 $member；未修改现有 omp。"
done
[ "$(cat "$tmp/VERSION")" = "$version" ] || fail '发行包 VERSION 与请求的发布标签不一致；未修改现有 omp。'
chmod 700 "$tmp/omp" || fail '无法设置候选程序权限；未修改现有 omp。'
mkdir "$tmp/home" "$tmp/config" "$tmp/data" "$tmp/cache" "$tmp/state" || fail '无法准备隔离验证目录；未修改现有 omp。'
# 清空继承环境并隔离 HOME/XDG，避免读取密钥、加载用户设置或修改缓存。
(cd "$tmp" && env -i PATH="$PATH" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache" XDG_STATE_HOME="$tmp/state" TMPDIR="$tmp" "$tmp/omp" --version > "$tmp/version-output" 2> "$tmp/version-error") || fail '候选 omp --version 无法运行；未修改现有 omp，请确认系统兼容性。'
upstream_version=$(cat "$tmp/UPSTREAM_VERSION")
[ -n "$upstream_version" ] || fail '发行包的上游版本信息为空；未修改现有 omp。'
grep -Fq -- "${upstream_version#v}" "$tmp/version-output" || fail '候选程序版本与发行包上游版本信息不一致；未修改现有 omp。'
(cd "$tmp" && env -i PATH="$PATH" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache" XDG_STATE_HOME="$tmp/state" TMPDIR="$tmp" "$tmp/omp" --help > "$tmp/help-output" 2> "$tmp/help-error") || fail '候选 omp --help 无法运行；未修改现有 omp。'
grep -Fxq '用法' "$tmp/help-output" && grep -Fxq '选项' "$tmp/help-output" || fail '候选程序未显示预期的中文帮助；未修改现有 omp。'

mkdir -p -- "$install_dir" || fail '无法创建安装目录；请检查 OMP_ZH_INSTALL_DIR 的权限。'
[ ! -d "$destination" ] || fail '安装目标 omp 是目录；已取消安装。'
staged=$(mktemp "$install_dir/.omp-zh-install.XXXXXXXXXX") || fail '无法在安装目录创建临时文件；请检查权限和磁盘空间。'
cp -- "$tmp/omp" "$staged" && chmod 755 "$staged" || fail '无法准备安装文件；未修改现有 omp。'
unfinished_notices=$(mktemp -d "$install_dir/omp-zh-pack.$version.XXXXXXXXXX") || fail '无法准备授权声明目录；未修改现有 omp。'
for member in LICENSE BUN-LICENSE.md THIRD_PARTY_NOTICES.md THIRD-PARTY-NOTICES.txt VERSION UPSTREAM_VERSION UPSTREAM_COMMIT; do
    cp -- "$tmp/$member" "$unfinished_notices/$member" && chmod 644 "$unfinished_notices/$member" || fail '无法保留授权声明和版本信息；未修改现有 omp。'
done
chmod 755 "$unfinished_notices" || fail '无法设置授权声明目录权限；未修改现有 omp。'
backup=
if [ -e "$destination" ] || [ -L "$destination" ]; then
    unfinished_backup=$(mktemp "$install_dir/omp.backup.$version.XXXXXXXXXX") || fail '无法创建唯一备份；未修改现有 omp。'
    # cp 默认跟随源符号链接，保存原程序内容而不是可能失效的链接。
    cp -p -- "$destination" "$unfinished_backup" || fail '无法备份现有 omp（请检查符号链接目标和读取权限）；未修改现有 omp。'
    backup=$unfinished_backup
    unfinished_backup=
    printf '原程序已备份至：%s\n' "$backup"
fi
# Linux 的 -T 和 macOS 的 -h 避免跟随目录型目标链接；同目录重命名替换运行中的程序。
[ ! -d "$destination" ] || fail '安装目标 omp 已变成目录；已取消安装，备份仍保留。'
mv "$mv_flags" -- "$staged" "$destination" || fail '无法原子替换 omp；现有程序未被覆盖，已创建的备份仍保留。'
staged=
notices=$unfinished_notices
unfinished_notices=
printf '已安装 OMP 中文包 %s：%s\n' "$version" "$destination"
printf '授权声明和版本信息：%s\n' "$notices"

# 输出可以直接粘贴的 shell 单引号字符串，包括目录中的单引号。
shell_quote() {
    value=$1
    printf "'"
    while :; do
        case "$value" in
            *\'*)
                printf '%s' "${value%%\'*}"
                printf "'\\\\''"
                value=${value#*\'}
                ;;
            *) printf "%s'" "$value"; break ;;
        esac
    done
}
if [ -n "$backup" ]; then
    printf '恢复原程序（原子替换，使用此备份）：\n  mv %s -- ' "$mv_flags"
    shell_quote "$backup"
    printf ' '
    shell_quote "$destination"
    printf '\n'
fi
case ":${PATH:-}:" in
    *":$install_dir:"*) printf '安装目录已在 PATH 中。若 shell 缓存了旧路径，请运行 hash -r；再运行 omp --help。\n' ;;
    *)
        printf '当前 PATH 未包含安装目录。仅为当前终端启用：\n  export PATH='
        shell_quote "$install_dir"
        printf ':"$PATH"\n  hash -r\n随后运行 omp --help。需要永久生效时，请自行将上述 export 添加到 shell 配置；安装器不会修改配置。\n'
        ;;
esac
