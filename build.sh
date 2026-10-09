#!/usr/bin/env bash
set -Eeuo pipefail
usage() {
  cat <<'HELP'
用法：./build.sh [--help]
在 Linux x64 glibc、macOS x64/arm64 或 Windows x64/arm64（Git Bash）本机构建。
依赖：git、Bun 1.3.14、网络；原生库取自版本固定、完整性校验的官方 npm 包。
OMP_ZH_NATIVES_DIR 可指定带上游版本印记的原生缓存；不会写入缓存。
OMP_ZH_BUILD_OUTPUT 指定输出文件，默认 dist/omp（Windows 为 dist/omp.exe）。
不运行安装钩子，不修改全局配置；构建后在隔离环境检查中文帮助和原生 smoke-test。
HELP
}
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# == 0 ]] || fail '不接受位置参数。'
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for tool in git bun mktemp cp mv chmod; do command -v "$tool" >/dev/null || fail "缺少 $tool"; done
[[ $(bun --version) == 1.3.14 ]] || fail '请使用 Bun 1.3.14（与发布包运行时授权版本一致）。'
for file in UPSTREAM_VERSION UPSTREAM_COMMIT VERSION patches/omp-v18.8.6-zh.patch; do
  [[ -s "$repo/$file" ]] || fail "缺少仓库文件：$file"
done
version=$(<"$repo/UPSTREAM_VERSION")
commit=$(<"$repo/UPSTREAM_COMMIT")
[[ $version == v18.8.6 && $commit =~ ^[0-9a-f]{40}$ ]] || fail '上游版本元数据无效。'
target=$(bun "$repo/scripts/release-tools.ts" host)
cache=${OMP_ZH_NATIVES_DIR:-${HOME:?}/.omp/natives/${version#v}}
[[ -z ${OMP_ZH_NATIVES_DIR:-} || -d $cache ]] || fail "原生缓存目录不存在：$cache"
if [[ -d $cache ]]; then cache=$(cd -- "$cache" && pwd -P); fi
workspace=$(mktemp -d "${TMPDIR:-${TEMP:-/tmp}}/omp-zh-build.XXXXXXXX")
output_tmp=
cleanup() { [[ -z $output_tmp ]] || rm -f -- "$output_tmp"; rm -rf -- "$workspace"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
checkout=$workspace/upstream
git clone -c core.autocrlf=false --depth 1 --branch "$version" --single-branch https://github.com/can1357/oh-my-pi.git "$checkout"
[[ $(git -C "$checkout" rev-parse HEAD) == "$commit" ]] || fail '官方标签提交与 UPSTREAM_COMMIT 不一致。'
git -C "$checkout" apply --check "$repo/patches/omp-v18.8.6-zh.patch"
git -C "$checkout" apply "$repo/patches/omp-v18.8.6-zh.patch"
(cd -- "$checkout" && bun install --frozen-lockfile --ignore-scripts)
bun "$repo/scripts/release-tools.ts" native "$checkout" "$cache" "${version#v}"
# Match upstream's production release compiler (including identifier minification
# and macOS entitlements) rather than the larger local development build.
if [[ -n ${BUN_COMPILE_EXECUTABLE_PATH:-} ]]; then
  # Retain the upstream local entrypoint for user-modified runtime relinking.
  (cd -- "$checkout" && unset BUN_NO_CODESIGN_MACHO_BINARY && CROSS_TARGET="$target" bun --cwd=packages/coding-agent run build)
  binary=$checkout/packages/coding-agent/dist/omp-$target
else
  native_target=$target
  [[ $target != windows-* ]] || native_target=win32-${target#windows-}
  (cd -- "$checkout" && unset BUN_NO_CODESIGN_MACHO_BINARY && bun scripts/ci-release-build-binaries.ts --targets "$native_target")
  binary=$checkout/packages/coding-agent/binaries/omp-$target
fi
if [[ $target == windows-* && -f $binary.exe ]]; then binary=$binary.exe; fi
[[ -f $binary ]] || fail '上游构建未生成可执行文件。'
bun "$repo/scripts/release-tools.ts" check "$binary"
name=omp
[[ $target != windows-* ]] || name=omp.exe
output=${OMP_ZH_BUILD_OUTPUT:-$repo/dist/$name}
[[ $output != */ && ! -d $output ]] || fail 'OMP_ZH_BUILD_OUTPUT 必须是文件路径。'
mkdir -p -- "$(dirname -- "$output")"
output_tmp=$(mktemp "$(dirname -- "$output")/.omp-zh.XXXXXXXX")
cp -- "$binary" "$output_tmp"
chmod 755 "$output_tmp"
mv -f -- "$output_tmp" "$output"
output_tmp=
printf '构建完成：%s（%s）\n' "$output" "$target"
