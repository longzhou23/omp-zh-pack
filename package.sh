#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'HELP'
用法：./package.sh [编译后的 omp 路径 [输出目录]]
      ./package.sh --help
默认输入：仓库/dist/omp；默认输出目录：仓库/dist。
仅在 Linux x86_64、glibc、支持 AVX2 的主机上制作当前已验证的预编译包。
需要 GNU tar、gzip、sha256sum；先在隔离 HOME 中检查中文帮助和原生 smoke-test。
输出：omp-zh-linux-x64.tar.gz 与单独发布的 SHA256SUMS。
压缩包只包含 omp、授权声明和版本信息，不包含缓存、设置或凭据。
SOURCE_DATE_EPOCH 可指定归档时间（默认 0），成员排序、所有者及 gzip 时间固定。
HELP
}
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# -le 2 ]] || fail '参数过多；请运行 ./package.sh --help。'
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
binary=${1:-$repo/dist/omp}
output_dir=${2:-$repo/dist}
for tool in uname getconf tar gzip sha256sum mktemp cp chmod mv env; do
  command -v "$tool" >/dev/null || fail "缺少 $tool，请安装后重试。"
done
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || fail '当前预编译发布包只支持 Linux x86_64；其它平台请从源码构建。'
libc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || fail '当前预编译包需要 glibc；不支持 musl。'
[[ $libc == glibc\ * ]] || fail '无法确认 glibc；已停止打包。'
[[ -r /proc/cpuinfo ]] || fail '无法读取 CPU 特性；不能确认 AVX2。'
avx2=false
while IFS= read -r line; do
  if [[ $line == flags* && " $line " == *' avx2 '* ]]; then avx2=true; break; fi
done < /proc/cpuinfo
$avx2 || fail '当前预编译包需要支持 AVX2 的 CPU；请使用符合条件的 Linux x86_64 主机打包。'
tar_version=$(tar --version)
[[ $tar_version == *'GNU tar'* ]] || fail '可复现归档需要 GNU tar；请安装 GNU tar 后重试。'
[[ -f $binary && -x $binary ]] || fail "找不到可执行的编译产物：$binary；请先运行 ./build.sh 或指定二进制路径。"
binary=$(cd -- "$(dirname -- "$binary")" && printf '%s/%s' "$PWD" "$(basename -- "$binary")")
members=(LICENSE BUN-LICENSE.md THIRD_PARTY_NOTICES.md THIRD-PARTY-NOTICES.txt VERSION UPSTREAM_VERSION UPSTREAM_COMMIT)
for member in "${members[@]}"; do
  [[ -s $repo/$member ]] || fail "缺少发布所需文件：$member"
done
[[ $(<"$repo/UPSTREAM_VERSION") == v18.8.5 && $(<"$repo/UPSTREAM_COMMIT") == 4bf0d9d3e9f910ef4af25dec9733fbb4d6912d4c && $(<"$repo/VERSION") == v18.8.5-zh.1 ]] || fail '发布版本元数据不匹配；已停止打包。'
epoch=${SOURCE_DATE_EPOCH:-0}
[[ $epoch =~ ^[0-9]+$ ]] || fail 'SOURCE_DATE_EPOCH 必须是非负整数秒数。'
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
# Stage on the destination filesystem so final renames are atomic.
workspace=$(mktemp -d "$output_dir/.omp-zh-package.XXXXXXXX")
cleanup() { rm -rf -- "$workspace"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "错误：打包失败（第 %s 行）；请检查上方日志。\n" "$LINENO" >&2' ERR
stage=$workspace/stage
mkdir -p -- "$stage" "$workspace/check-home" "$workspace/check-cwd"
cp -- "$binary" "$stage/omp"
chmod 755 "$stage/omp"
# Check the staged copy, not a potentially changing source binary.
check_binary() {
  (cd -- "$workspace/check-cwd" && env -i PATH="$PATH" HOME="$workspace/check-home" TMPDIR="$workspace" XDG_CONFIG_HOME="$workspace/check-home/config" XDG_DATA_HOME="$workspace/check-home/data" XDG_STATE_HOME="$workspace/check-home/state" XDG_CACHE_HOME="$workspace/check-home/cache" NO_COLOR=1 "$stage/omp" "$@")
}
help_text=$(check_binary --help)
[[ $help_text == *'选项'* || $help_text == *'用法'* ]] || fail '输入二进制的 --help 未包含中文帮助；拒绝打包。'
check_binary --smoke-test
for member in "${members[@]}"; do
  cp -- "$repo/$member" "$stage/$member"
  chmod 644 "$stage/$member"
done
asset=omp-zh-linux-x64.tar.gz
# Explicit allowlist: no directories, native caches, node_modules or credentials.
# Clear tar/gzip environment options so caller settings cannot add files/metadata.
(env -u TAR_OPTIONS LC_ALL=C tar --sort=name --format=gnu --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -C "$stage" -cf - BUN-LICENSE.md LICENSE THIRD-PARTY-NOTICES.txt THIRD_PARTY_NOTICES.md UPSTREAM_COMMIT UPSTREAM_VERSION VERSION omp | env -u GZIP gzip -n -9) > "$workspace/$asset"
(cd -- "$workspace" && sha256sum "$asset") > "$workspace/SHA256SUMS"
chmod 644 "$workspace/$asset" "$workspace/SHA256SUMS"
mv -f -- "$workspace/$asset" "$output_dir/$asset"
mv -f -- "$workspace/SHA256SUMS" "$output_dir/SHA256SUMS"
printf '打包完成：%s/%s\n校验清单：%s/SHA256SUMS\n' "$output_dir" "$asset" "$output_dir"
