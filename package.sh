#!/usr/bin/env bash
set -Eeuo pipefail
usage() {
  cat <<'HELP'
用法：./package.sh [编译后的 omp 路径 [输出目录]]
在当前原生主机打包；需要 Bun 1.3.14。
默认输入 dist/omp（Windows 为 dist/omp.exe）；默认输出 dist。
Unix 输出 omp-zh-<target>.tar.gz；Windows 输出 omp-zh-<target>.zip。
只归档可执行文件、授权和版本信息；隔离检查中文帮助及原生 smoke-test。
每个目标输出 SHA256SUMS-<target>，发布工作流合并为 SHA256SUMS。
SOURCE_DATE_EPOCH 指定固定归档时间（默认 0）。
HELP
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# -le 2 ]] || { printf '错误：参数过多。\n' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
command -v bun >/dev/null || { printf '错误：需要 Bun 1.3.14。\n' >&2; exit 1; }
[[ $(bun --version) == 1.3.14 ]] || { printf '错误：需要 Bun 1.3.14。\n' >&2; exit 1; }
target=$(bun "$repo/scripts/release-tools.ts" host)
name=omp
[[ $target != windows-* ]] || name=omp.exe
bun "$repo/scripts/release-tools.ts" package "$repo" "${1:-$repo/dist/$name}" "${2:-$repo/dist}"
