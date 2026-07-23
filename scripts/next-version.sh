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
#   scripts/next-version.sh                       # 自动读 BASE_TAG + 本地 tag；stdout 打 tag 值
#   scripts/next-version.sh --base v3.17.0        # 覆盖基线版本
#   scripts/next-version.sh --field version       # stdout 改打 version 字段（默认 tag）
#   EXISTING_TAGS="v3.17.0-ccs.1 v3.17.0-ccs.2" scripts/next-version.sh --base v3.17.0
#
# 输出：
#   - stdout：只打「一个字段的纯值」一行（默认 tag，即最终版本 tag）。这样
#     `NEWTAG="$(next-version.sh)"` 天然拿到干净的 tag，无需调用方再 sed/awk 抽取。
#     用 --field <base|n|version|tag> 选别的字段。
#   - ${GITHUB_OUTPUT}（若设置）：照旧写全部 KEY=VALUE 四行（base=/n=/version=/tag=），
#     供 GitHub Actions 用 steps.<id>.outputs.<key> 消费。
#
# 历史坑（勿回退）：早期 stdout 也打四行 KEY=VALUE，auto-upgrade 里 `$(next-version.sh)`
#   会把四行整个吞进变量，git tag 报 "not a valid tag name"。现在 stdout 与 GITHUB_OUTPUT
#   职责分离：stdout=纯值给命令替换，GITHUB_OUTPUT=KEY=VALUE 给 Actions。
#
# 退出码：0 成功；非 0 参数/基线缺失。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_TAG_FILE="$PROJECT_ROOT/brand/BASE_TAG"

usage() { sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

base=""
field="tag"   # stdout 打哪个字段的纯值（默认 tag）；GITHUB_OUTPUT 始终写全部四行。
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) base="${2:-}"; shift 2 ;;
    --base=*) base="${1#--base=}"; shift ;;
    --field) field="${2:-}"; shift 2 ;;
    --field=*) field="${1#--field=}"; shift ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
done
# 校验 --field 取值（只认四个已知字段，挡掉打错字导致 stdout 空输出）。
case "$field" in
  base|n|version|tag) : ;;
  *) printf '未知字段：%s（可选 base|n|version|tag）\n' "$field" >&2; exit 2 ;;
esac

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

# emit：只往 $GITHUB_OUTPUT 写 KEY=VALUE（供 Actions 的 steps.<id>.outputs.<key> 消费）。
# stdout 不在这里打——stdout 只在最后打「选中字段的纯值」一行，职责分离（见文件头历史坑）。
emit() {
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  return 0
}

emit "base=${base}"
emit "n=${next_n}"
emit "version=${version}"
emit "tag=${version}"

# stdout：只打选中字段的纯值一行，供 `$(next-version.sh)` 命令替换直接取用。
case "$field" in
  base)    printf '%s\n' "$base" ;;
  n)       printf '%s\n' "$next_n" ;;
  version) printf '%s\n' "$version" ;;
  tag)     printf '%s\n' "$version" ;;
esac
