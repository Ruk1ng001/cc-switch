#!/usr/bin/env bash
# 跟随升级脚本：把 upstream/ submodule 更新到 farion1231/cc-switch 上游最新稳定
# release tag，刷新基线锁定文件（brand/BASE_TAG / brand/BASE_SHA），并把父仓库的
# submodule 指向（gitlink）暂存到更新后的 commit。实现对上游的可持续跟随。
#
# 自包含：不依赖外部 common.sh。
#
# 用法：
#   scripts/update.sh                 # 取上游最新稳定 tag，有新版本才更新（无则幂等退出）
#   scripts/update.sh v3.17.0         # 指定目标 tag（便于回滚 / 复现）
#   scripts/update.sh -h | --help
#
# 环境变量：
#   CCS_UPSTREAM_URL  上游仓库地址（默认从 .gitmodules 读，回退公开 HTTPS；
#                     避开 submodule origin 可能是 SSH 别名导致 CI 无凭据）
#
# 跟随策略：
#   - 只跟严格的 vX.Y.Z tag（cc-switch 的 release tag 形如 v3.17.0）；
#   - 排除预发布（v3.17.0-beta.1 / -rc.1 / -alpha.N 等带连字符后缀的 tag）；
#   - 按语义版本排序（sort -V）取最大者为「最新稳定版」。
#
# 幂等：
#   - 不带参数且已是最新版本时，不改动任何文件、不 checkout，直接退出 0；
#   - 重复运行不产生副作用（BASE 文件内容不变、submodule HEAD 不变、gitlink 不变）。
#
# 退出码：
#   0  已更新到目标 tag（或已是最新，无需更新）
#   非 0  网络不可达 / 无匹配 tag / 目标 tag 不存在 / 切换后校验失败（已回滚）
#
# 不变式：官方源码零手改。本脚本只切 submodule tag + 刷新基线 + 暂存 gitlink，
#         不提交（提交由维护者决定），不改 upstream/ 内任何文件。
set -euo pipefail

# —— 路径解析（不依赖调用时 cwd）——
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$PROJECT_ROOT/upstream"
BRAND_DIR="$PROJECT_ROOT/brand"
BASE_TAG_FILE="$BRAND_DIR/BASE_TAG"
BASE_SHA_FILE="$BRAND_DIR/BASE_SHA"

# —— 日志 ——
log()  { printf '\033[36m[ccs]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[ccs]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[ccs]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

read_base_tag() { tr -d '[:space:]' < "$BASE_TAG_FILE" 2>/dev/null || true; }
read_base_sha() { tr -d '[:space:]' < "$BASE_SHA_FILE" 2>/dev/null || true; }

# 解析上游仓库 URL：优先 CCS_UPSTREAM_URL，其次 .gitmodules 里 upstream 的 url，
# 最后回退公开 HTTPS。绝不用 submodule 的 origin（可能是 SSH 别名）。
resolve_upstream_url() {
  if [ -n "${CCS_UPSTREAM_URL:-}" ]; then
    printf '%s\n' "$CCS_UPSTREAM_URL"; return 0
  fi
  local u
  u="$(git -C "$PROJECT_ROOT" config -f .gitmodules submodule.upstream.url 2>/dev/null || true)"
  if [ -n "$u" ]; then printf '%s\n' "$u"; return 0; fi
  printf '%s\n' "https://github.com/farion1231/cc-switch.git"
}

# 查询上游最新稳定 release tag（vX.Y.Z）。
#   grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'  只留纯三段语义版本 —— 这一条同时：
#     · 排除任何非 v<数字> 开头的 tag
#     · 排除预发布 v3.17.0-rc.1 / -beta / -alpha（含连字符后缀，末尾非纯数字）
#   sort -V 取语义版本最大者。
latest_stable_tag() {
  local url="$1" tags
  tags="$(git ls-remote --tags --refs "$url" 'v*' 2>/dev/null \
            | awk '{print $2}' | sed 's#^refs/tags/##' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -V || true)"
  [ -n "$tags" ] && printf '%s\n' "$tags" | tail -1
  return 0
}

# 校验目标 tag 在上游存在并取其指向的 commit SHA。
# annotated tag：ls-remote 输出两行，peeled 行（refs/tags/<tag>^{}）才是真正的
# commit SHA —— brand/BASE_SHA 锁定的正是它，故优先取 peeled；轻量 tag 则取 plain。
resolve_tag_sha() {
  local url="$1" tag="$2" peeled plain
  peeled="$(git ls-remote --tags "$url" "refs/tags/${tag}^{}" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  if [ -n "$peeled" ]; then printf '%s\n' "$peeled"; return 0; fi
  plain="$(git ls-remote --tags "$url" "refs/tags/${tag}" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  [ -n "$plain" ] && printf '%s\n' "$plain"
  return 0
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac

  [ -d "$SRC_DIR/.git" ] || [ -f "$SRC_DIR/.git" ] \
    || die "找不到已初始化的 submodule：$SRC_DIR（先 git submodule update --init）。"
  [ -f "$BASE_TAG_FILE" ] || die "找不到基线文件：$BASE_TAG_FILE"
  [ -f "$BASE_SHA_FILE" ] || die "找不到基线文件：$BASE_SHA_FILE"

  local requested_tag="${1:-}" explicit=0
  [ -n "$requested_tag" ] && explicit=1

  local url; url="$(resolve_upstream_url)"

  # —— 更新前状态（用于对比 + 失败回滚）——
  local orig_tag orig_sha orig_head
  orig_tag="$(read_base_tag)"
  orig_sha="$(read_base_sha)"
  orig_head="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo "$orig_sha")"

  # submodule 工作区必须干净，否则 checkout -f 会丢改动
  if [ -n "$(git -C "$SRC_DIR" status --porcelain 2>/dev/null)" ]; then
    err "upstream/ 有未提交的改动，拒绝切换 tag（改动应导出到 brand/patches/）。"
    git -C "$SRC_DIR" status --short >&2
    exit 1
  fi

  # —— 1. 确定目标 tag ——
  local target_tag
  if [ "$explicit" -eq 1 ]; then
    target_tag="$requested_tag"
    log "指定目标 tag：$target_tag（当前基线 $orig_tag）"
  else
    log "查询上游最新稳定 release tag：$url"
    target_tag="$(latest_stable_tag "$url")"
    [ -n "$target_tag" ] || die "查询上游最新稳定 tag 失败（网络不可达或无匹配 tag）。"
    log "上游最新稳定 release：$target_tag（当前基线 $orig_tag）"
  fi

  # —— 幂等短路：不带参数且已是最新，什么都不做 ——
  if [ "$target_tag" = "$orig_tag" ] && [ "$explicit" -eq 0 ]; then
    log "已是最新版本 $orig_tag，无需更新。"
    printf '版本对比：%s → %s（无变化）\n' "$orig_tag" "$orig_tag"
    exit 0
  fi

  # —— 2. 校验目标 tag 存在并取其 commit SHA ——
  local target_sha
  target_sha="$(resolve_tag_sha "$url" "$target_tag")"
  [ -n "$target_sha" ] || die "目标 tag 不存在于上游：$target_tag"

  # —— 3. 把 submodule 切到目标 tag ——
  rollback() {
    warn "回滚：恢复 brand/BASE_TAG、brand/BASE_SHA 与 upstream/ 到更新前状态。"
    printf '%s\n' "$orig_tag" > "$BASE_TAG_FILE"
    printf '%s\n' "$orig_sha" > "$BASE_SHA_FILE"
    git -C "$SRC_DIR" checkout -f "$orig_head" >/dev/null 2>&1 || true
    git -C "$SRC_DIR" clean -fd >/dev/null 2>&1 || true
    git -C "$PROJECT_ROOT" add upstream >/dev/null 2>&1 || true
  }

  log "拉取并切换 upstream/ 到 $target_tag（$target_sha）"
  git -C "$SRC_DIR" fetch --force "$url" \
    "refs/tags/${target_tag}:refs/tags/${target_tag}" >/dev/null 2>&1 \
    || { err "从上游拉取 tag $target_tag 失败：$url"; exit 1; }
  git -C "$SRC_DIR" checkout -f "refs/tags/${target_tag}" >/dev/null 2>&1 \
    || { err "checkout tag $target_tag 失败。"; rollback; exit 1; }
  git -C "$SRC_DIR" clean -fd >/dev/null 2>&1 || true

  local new_sha
  new_sha="$(git -C "$SRC_DIR" rev-parse HEAD)"
  if [ "$new_sha" != "$target_sha" ]; then
    err "切换后 upstream/ HEAD ($new_sha) 与 tag $target_tag 指向的 SHA ($target_sha) 不符。"
    rollback
    exit 1
  fi

  # —— 4. 刷新基线锁定文件（保持末尾换行）——
  printf '%s\n' "$target_tag" > "$BASE_TAG_FILE"
  printf '%s\n' "$new_sha" > "$BASE_SHA_FILE"

  # —— 5. 把父仓库的 submodule 指向暂存到新 commit（不提交）——
  git -C "$PROJECT_ROOT" add upstream >/dev/null 2>&1 || true

  log "已刷新基线：brand/BASE_TAG=$target_tag  brand/BASE_SHA=$new_sha"

  # —— 6. 输出更新前后版本对比 ——
  if [ "$orig_tag" = "$target_tag" ]; then
    printf '版本对比：%s → %s（重放到同一 tag，无版本变化）\n' "$orig_tag" "$target_tag"
  else
    printf '版本对比：%s → %s\n' "$orig_tag" "$target_tag"
  fi
  printf '  SHA：%s → %s\n' "$orig_sha" "$new_sha"
  log "upstream/ 已切到 $target_tag，gitlink 已暂存。"
  log "如有 brand/patches/，请在编译发布前重放。"
  log "确认无误后提交：git commit brand/BASE_TAG brand/BASE_SHA upstream"
}

main "$@"
