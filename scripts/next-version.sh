#!/usr/bin/env bash
# 计算下一个定制发布版本号：<cc-switch版本>-ccs.N（release detect 阶段用）。
#
# 规则：
#   - 基线版本取自 brand/BASE_TAG（如 v3.17.0），即当前锁定的 cc-switch 上游 tag；
#   - 在「已有发布版本」列表里找形如 <base>-ccs.<N> 的 tag，取最大 N，下一个为 N+1；
#   - 该基线尚无任何 ccs 发布时，从 1 开始（首个发布 v3.17.0-ccs.1）。
#
# 已有版本来源（按优先级）：
#   1. 环境变量 EXISTING_TAGS（空白/换行分隔）—— CI 用 `gh release list` / `git tag` 填充；
#   2. 本地 `git tag -l`（无网络也能算，便于本机自测）。
#
# 用法：
#   scripts/next-version.sh                       # 自动读 BASE_TAG + 本地 tag
#   scripts/next-version.sh --base v3.17.0        # 覆盖基线版本
#   EXISTING_TAGS="v3.17.0-ccs.1 v3.17.0-ccs.2" scripts/next-version.sh --base v3.17.0
#
# 输出（若设置 GITHUB_OUTPUT 则写入其中，同时也打到 stdout 便于本机查看）：
#   base=v3.17.0
#   n=1
#   version=v3.17.0-ccs.1
#   tag=v3.17.0-ccs.1
#
# 退出码：0 成功；非 0 参数/基线缺失。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_TAG_FILE="$PROJECT_ROOT/brand/BASE_TAG"

usage() { sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

base=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) base="${2:-}"; shift 2 ;;
    --base=*) base="${1#--base=}"; shift ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
done

# 基线版本：优先 --base，其次 brand/BASE_TAG。
if [ -z "$base" ]; then
  [ -f "$BASE_TAG_FILE" ] || { printf '找不到基线文件：%s\n' "$BASE_TAG_FILE" >&2; exit 1; }
  base="$(tr -d '[:space:]' < "$BASE_TAG_FILE")"
fi
[ -n "$base" ] || { printf '基线版本为空。\n' >&2; exit 1; }
# 规整成 vX.Y.Z 形式（BASE_TAG 已带 v，容错处理缺 v 的情况）。
case "$base" in v*) : ;; *) base="v$base" ;; esac

# 已有 ccs tag 列表：EXISTING_TAGS 优先，否则本地 git tag。
existing="${EXISTING_TAGS:-}"
if [ -z "$existing" ]; then
  existing="$(git -C "$PROJECT_ROOT" tag -l "${base}-ccs.*" 2>/dev/null || true)"
fi

# 从已有 tag 中抽出严格匹配 <base>-ccs.<数字> 的 N，取最大值。
max_n=0
if [ -n "$existing" ]; then
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    case "$tag" in
      "${base}-ccs."*)
        n="${tag#"${base}-ccs."}"
        case "$n" in
          ''|*[!0-9]*) continue ;;
          *) [ "$n" -gt "$max_n" ] && max_n="$n" ;;
        esac
        ;;
    esac
  done <<EOF
$(printf '%s\n' $existing)
EOF
fi

next_n=$((max_n + 1))
version="${base}-ccs.${next_n}"

emit() {
  printf '%s\n' "$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  return 0
}

emit "base=${base}"
emit "n=${next_n}"
emit "version=${version}"
emit "tag=${version}"
