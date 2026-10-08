#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'HELP'
用法：./build.sh [--help]
从固定的官方标签/提交在临时目录构建中文 omp；不运行 bun setup 或创建全局链接。
依赖：git、Bun，以及未命中原生缓存时的上游原生构建工具链。
  OMP_ZH_NATIVES_DIR   原生缓存目录；仅复制当前平台且版本匹配的 .node 文件
                      默认尝试 ~/.omp/natives/18.8.5（不会写入缓存）
  OMP_ZH_BUILD_OUTPUT  输出可执行文件路径（默认：仓库/dist/omp）
Linux x64 缺少缓存时通过上游 build:native 构建 modern 和 baseline 两种原生库，
需要 Bazel/Bazelisk、C/C++ 工具链及网络；其它主机使用上游 host 构建路径，
需要 Rust/Cargo、C/C++ 编译器、CMake、pkg-config（详见上游工具链要求）。
构建后在隔离 HOME 中检查中文 --help 和 --smoke-test。
HELP
}
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# == 0 ]] || fail '不接受位置参数；请运行 ./build.sh --help。'
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for tool in git bun mktemp cp mv chmod; do
  command -v "$tool" >/dev/null || fail "缺少 $tool，请先安装后重试。"
done
for file in UPSTREAM_VERSION UPSTREAM_COMMIT patches/omp-v18.8.5-zh.patch; do
  [[ -s "$repo/$file" ]] || fail "缺少仓库文件：$file"
done
version=$(<"$repo/UPSTREAM_VERSION")
commit=$(<"$repo/UPSTREAM_COMMIT")
[[ $version == v18.8.5 && $commit == 4bf0d9d3e9f910ef4af25dec9733fbb4d6912d4c ]] || fail '上游版本元数据不符合此本地化包的固定版本。'
cache=${OMP_ZH_NATIVES_DIR:-${HOME:?}/.omp/natives/${version#v}}
[[ -z ${OMP_ZH_NATIVES_DIR:-} || -d $cache ]] || fail "原生缓存目录不存在：$cache"
if [[ -d $cache ]]; then cache=$(cd -- "$cache" && pwd -P); fi
workspace=$(mktemp -d "${TMPDIR:-/tmp}/omp-zh-build.XXXXXXXX")
output_tmp=
cleanup() {
  [[ -z $output_tmp ]] || rm -f -- "$output_tmp"
  rm -rf -- "$workspace"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "错误：构建失败（第 %s 行）；请检查上方日志和 ./build.sh --help 中的依赖说明。\n" "$LINENO" >&2' ERR
checkout=$workspace/upstream
git clone --depth 1 --branch "$version" --single-branch https://github.com/can1357/oh-my-pi.git "$checkout"
[[ $(git -C "$checkout" rev-parse HEAD) == "$commit" ]] || fail '官方标签提交与 UPSTREAM_COMMIT 不一致；已停止构建。'
git -C "$checkout" apply --check "$repo/patches/omp-v18.8.5-zh.patch"
git -C "$checkout" apply "$repo/patches/omp-v18.8.5-zh.patch"
# Skip install hooks; the binary build generates its own required stats/tool views.
(cd -- "$checkout" && bun install --frozen-lockfile --ignore-scripts)
platform=$(bun -e 'process.stdout.write(process.platform)')
arch=$(bun -e 'process.stdout.write(process.arch)')
if [[ $platform == linux ]]; then
  bun -e 'if (!process.report.getReport().header.glibcVersionRuntime) process.exit(1)' || fail '此构建脚本仅支持 Linux glibc 原生文件；不支持 musl 缓存。'
fi
if [[ $arch == x64 ]]; then
  filenames=("pi_natives.$platform-$arch-modern.node" "pi_natives.$platform-$arch-baseline.node")
else
  filenames=("pi_natives.$platform-$arch.node")
fi
native_dir=$checkout/packages/natives/native
for filename in "${filenames[@]}"; do
  candidate=$cache/$filename
  if [[ -f $candidate ]]; then
    # Use upstream's exact stamp/sentinel validation; never relabel a stale addon.
    if (cd -- "$checkout" && bun -e '
      import { readFileSync } from "node:fs";
      import { containsVersionStamp, containsLegacyVersionSentinel } from "./packages/natives/native/version-sentinel.js";
      const bytes = readFileSync(process.argv[1]);
      const version = process.argv[2];
      if (!containsVersionStamp(bytes, version) && !containsLegacyVersionSentinel(bytes, version)) process.exit(1);
    ' "$candidate" "${version#v}"); then
      cp -- "$candidate" "$native_dir/$filename"
    else
      printf '忽略版本不匹配的原生缓存：%s\n' "$candidate" >&2
    fi
  fi
done
missing=false
for filename in "${filenames[@]}"; do
  [[ -f $native_dir/$filename ]] || missing=true
done
if $missing; then
  if [[ $platform == linux && $arch == x64 ]]; then
    command -v bazel >/dev/null || command -v bazelisk >/dev/null || fail '缓存不完整；请安装 Bazel/Bazelisk 及上游 C/C++ 工具链，或设置含 modern 和 baseline 的 OMP_ZH_NATIVES_DIR。'
    (cd -- "$checkout" && OMP_NATIVE_BUILD_BACKEND=bazel bun run build:native linux-x64-modern linux-x64-baseline)
  else
    for tool in cargo rustc cmake pkg-config; do
      command -v "$tool" >/dev/null || fail "缓存不完整且缺少 $tool；请安装上游原生构建工具链，或设置 OMP_ZH_NATIVES_DIR。"
    done
    (cd -- "$checkout" && bun run build:native)
  fi
fi
(cd -- "$checkout" && unset CROSS_TARGET && bun --cwd=packages/coding-agent run build)
binary=$checkout/packages/coding-agent/dist/omp
[[ -x $binary ]] || fail '上游构建未生成可执行文件。'
mkdir -p -- "$workspace/check-home" "$workspace/check-cwd"
check_binary() {
  (cd -- "$workspace/check-cwd" && env -i PATH="$PATH" HOME="$workspace/check-home" TMPDIR="$workspace" XDG_CONFIG_HOME="$workspace/check-home/config" XDG_DATA_HOME="$workspace/check-home/data" XDG_STATE_HOME="$workspace/check-home/state" XDG_CACHE_HOME="$workspace/check-home/cache" NO_COLOR=1 "$binary" "$@")
}
help_text=$(check_binary --help)
[[ $help_text == *'选项'* || $help_text == *'用法'* ]] || fail '构建产物的 --help 未包含中文帮助。'
check_binary --smoke-test
output=${OMP_ZH_BUILD_OUTPUT:-$repo/dist/omp}
[[ $output != */ && ! -d $output ]] || fail 'OMP_ZH_BUILD_OUTPUT 必须是文件路径。'
mkdir -p -- "$(dirname -- "$output")"
output_tmp=$(mktemp "$(dirname -- "$output")/.omp-zh.XXXXXXXX")
cp -- "$binary" "$output_tmp"
chmod 755 "$output_tmp"
mv -f -- "$output_tmp" "$output"
output_tmp=
printf '构建完成：%s\n' "$output"
