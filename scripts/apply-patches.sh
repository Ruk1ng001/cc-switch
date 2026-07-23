#!/usr/bin/env bash
# 补丁重放/验证脚本：把 brand/patches/*.patch 按 NN 序应用到 upstream/ submodule
# （基线应为 brand/BASE_SHA）。用于「submodule 锁上游 + 薄叠加层」中的重放环节。
#
# 模式：
#   scripts/apply-patches.sh              # apply：当前干净工作区 strict 落地（发布/构建前重放）
#   scripts/apply-patches.sh --preflight  # 只验 LF / patch 语法（+ 可选 manifest）；零 worktree、零副作用
#   scripts/apply-patches.sh --check      # 临时 worktree 从 BASE_SHA strict 累积重放；与 CI 完全一致
#   scripts/apply-patches.sh --check-3way # 临时 worktree 三方重放；仅诊断上游漂移，成功不代表 CI 可过
#   scripts/apply-patches.sh -h | --help
#
# 关键不变式：任何 apply/check 前先完整 preflight。若后序 patch 是 corrupt patch，必须在修改
#   upstream/ 或创建 worktree 前失败，避免「前序补丁已落地，最后才发现格式坏」的副作用泄漏。
#
# 为什么 check 用临时 worktree：补丁是「按序累积」的（后序补丁可能依赖前序补丁改过的文件）。
#   单个 `git apply --check` 对干净基线跑会假 FAIL；必须真实按序落地才能验证。worktree 让验证
#   不污染 upstream/ 当前状态。
#
# apply / check 的 git apply 语义（刻意区分）：
#   - apply / --check（发布 / CI 重放）：strict `git apply`，补丁须精确适用，fuzzy 成功=隐患→硬失败；
#   - --check-3way（维护者诊断）：`git apply --3way`，上下文轻微漂移时三方合并兜底，作诊断信号。
#   故 --check 通过≈CI 能过；以 strict apply 为最终判据。
#
# manifest 可选：若存在 brand/patches.manifest（每段 [补丁名] 列出该补丁涉及的文件），preflight
#   会校验 manifest 声明的补丁集与磁盘 .patch 集一致；无此文件则跳过该校验（cc-switch 当前无 manifest）。
#
# 退出码：
#   0     全部成功（apply 落地 / preflight/check 验证通过）
#   非 0  某补丁失败（apply/preflight 见首个失败；check 跑完全部再汇总失败）
set -euo pipefail

# —— 路径解析（不依赖调用时 cwd）——
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$PROJECT_ROOT/upstream"
BRAND_DIR="$PROJECT_ROOT/brand"
PATCHES_DIR="$BRAND_DIR/patches"
BASE_SHA_FILE="$BRAND_DIR/BASE_SHA"
MANIFEST_FILE="$BRAND_DIR/patches.manifest"
PREFIX="ccs"

# —— 日志（对齐 update.sh）——
log()  { printf '\033[36m[%s]\033[0m %s\n' "$PREFIX" "$*"; }
warn() { printf '\033[33m[%s]\033[0m %s\n' "$PREFIX" "$*" >&2; }
err()  { printf '\033[31m[%s]\033[0m %s\n' "$PREFIX" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
read_base_sha() { tr -d '[:space:]' < "$BASE_SHA_FILE" 2>/dev/null || true; }

# check 模式的临时 worktree 清理钩子。
CHECK_WT=""
cleanup_wt() {
  [ -n "${CHECK_WT:-}" ] || return 0
  git -C "$SRC_DIR" worktree remove --force "$CHECK_WT" >/dev/null 2>&1 || true
  rm -rf "$CHECK_WT" >/dev/null 2>&1 || true
  CHECK_WT=""
}
trap cleanup_wt EXIT

# 按 NN 序列出所有补丁的绝对路径（无补丁则空）。LC_ALL=C 保证 01-,02-... 稳定字典序。
list_patches() {
  find "$PATCHES_DIR" -maxdepth 1 -type f -name '*.patch' -print 2>/dev/null | LC_ALL=C sort
}

list_patch_basenames() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && basename "$p"
  done < <(list_patches)
}

list_manifest_patch_names() {
  grep -E '^\[[^][]+\]$' "$MANIFEST_FILE" 2>/dev/null \
    | sed 's/^\[//; s/\]$//; s/$/.patch/' \
    | LC_ALL=C sort
}

# manifest 校验（可选）：无 manifest 文件时静默跳过；有则要求声明集与磁盘 .patch 集完全一致。
run_manifest_check() {
  [ -f "$MANIFEST_FILE" ] || { log "无 brand/patches.manifest，跳过 manifest 校验。"; return 0; }

  local actual expected missing extra
  actual="$(list_patch_basenames)"
  expected="$(list_manifest_patch_names)"
  missing="$(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$expected") || true)"
  extra="$(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$expected") || true)"

  if [ -n "$missing" ] || [ -n "$extra" ]; then
    err "manifest 与 patch 文件集不一致：$MANIFEST_FILE"
    if [ -n "$missing" ]; then
      err "manifest 缺少以下 section："
      printf '%s\n' "$missing" | sed 's/\.patch$//; s/^/        [/; s/$/]/' >&2
    fi
    if [ -n "$extra" ]; then
      err "manifest 声明了不存在的 patch："
      printf '%s\n' "$extra" | sed 's/^/        /' >&2
    fi
    return 1
  fi
  log "manifest 校验通过：$(printf '%s\n' "$actual" | sed '/^$/d' | wc -l) 个 patch section 一致。"
}

# 单补丁预检：validate-patch.py 严格核对 hunk 结构 + LF；git apply --numstat 覆盖 binary/扩展 header 语义。
preflight_patch() {
  local patch="$1" name out
  name="$(basename "$patch")"

  if ! out="$(python3 "$SCRIPT_DIR/validate-patch.py" "$patch" 2>&1)"; then
    printf 'PARSE FAIL  %s\n' "$name" >&2
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    return 1
  fi
  if out="$(git -C "$SRC_DIR" apply --numstat "$patch" 2>&1)"; then
    printf 'PARSE OK    %s\n' "$name"
    return 0
  fi
  printf 'PARSE FAIL  %s\n' "$name" >&2
  printf '%s\n' "$out" | sed 's/^/        /' >&2
  return 1
}

run_preflight() {
  run_manifest_check || return 1

  local total=0 fails=0 patch
  while IFS= read -r patch; do
    [ -n "$patch" ] || continue
    total=$((total + 1))
    preflight_patch "$patch" || fails=$((fails + 1))
  done < <(list_patches)

  if [ "$total" -eq 0 ]; then
    warn "$PATCHES_DIR 下没有 .patch，无补丁可预检。"
    return 0
  fi
  if [ "$fails" -ne 0 ]; then
    err "preflight 失败：$total 个补丁中 $fails 个无法解析；未创建 worktree、未修改 upstream/。"
    return 1
  fi
  log "preflight 通过：$total 个补丁均为 LF 且可被 git apply 解析。"
}

# check 模式：临时 worktree 里从 BASE_SHA 累积重放，逐个报告 OK/FAIL。
run_check_mode() {
  local mode="$1" base_sha patch name fails=0 total=0 label
  run_preflight || return 1

  base_sha="$(read_base_sha)"
  [ -n "$base_sha" ] || die "读取基线 SHA 失败：$BASE_SHA_FILE"
  git -C "$SRC_DIR" cat-file -e "${base_sha}^{commit}" 2>/dev/null \
    || die "upstream/ 内找不到基线 commit ${base_sha}（先 git submodule update --init）。"

  CHECK_WT="$(mktemp -d "${TMPDIR:-/tmp}/ccs-apply-check.XXXXXX")"
  git -C "$SRC_DIR" worktree add --detach "$CHECK_WT" "$base_sha" >/dev/null 2>&1 \
    || die "创建临时 worktree 失败（基线 ${base_sha}）。"

  if [ "$mode" = "strict" ]; then
    label="check(strict)"
    log "${label}：从基线 $base_sha 按序 strict 重放（与 Release/CI 一致，不碰当前工作区）"
  else
    label="check(3way)"
    warn "${label}：仅诊断上游漂移；成功不代表 Release/CI strict apply 可通过。"
  fi

  while IFS= read -r patch; do
    [ -n "$patch" ] || continue
    total=$((total + 1))
    name="$(basename "$patch")"
    if [ "$mode" = "strict" ]; then
      if git -C "$CHECK_WT" apply "$patch" >/dev/null 2>&1; then
        printf 'APPLY OK    %s\n' "$name"
      else
        fails=$((fails + 1))
        printf 'APPLY FAIL  %s\n' "$name" >&2
        git -C "$CHECK_WT" apply "$patch" 2>&1 | sed 's/^/        /' >&2 || true
      fi
    else
      if git -C "$CHECK_WT" apply --3way "$patch" >/dev/null 2>&1; then
        printf 'APPLY3 OK   %s\n' "$name"
      else
        fails=$((fails + 1))
        printf 'APPLY3 FAIL %s\n' "$name" >&2
        git -C "$CHECK_WT" apply --3way "$patch" 2>&1 | sed 's/^/        /' >&2 || true
      fi
    fi
  done < <(list_patches)

  if [ "$fails" -ne 0 ]; then
    err "$label 失败：$total 个补丁中 $fails 个应用失败。"
    [ "$mode" = "strict" ] && warn "如需判断是否仅为上下文漂移，可运行：scripts/apply-patches.sh --check-3way"
    return 1
  fi
  log "$label 通过：$total 个补丁按序应用零冲突。"
}

# apply 模式：在 upstream/ 内真实按序 strict 落地。
run_apply() {
  run_preflight || return 1

  local base_sha head total=0 patch name
  base_sha="$(read_base_sha)"
  head="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || true)"

  if [ -n "$(git -C "$SRC_DIR" status --porcelain 2>/dev/null)" ]; then
    err "upstream/ 工作区非干净——可能已重放过补丁或有手改。"
    err "如需重新重放，先 git -C upstream checkout -f . && git -C upstream clean -fd。"
    return 1
  fi
  if [ -n "$base_sha" ] && [ -n "$head" ] && [ "$head" != "$base_sha" ]; then
    warn "upstream/ HEAD ($head) 与基线 BASE_SHA ($base_sha) 不一致，strict patch 可能不适用。"
  fi

  while IFS= read -r patch; do
    [ -n "$patch" ] || continue
    total=$((total + 1))
    name="$(basename "$patch")"
    if git -C "$SRC_DIR" apply "$patch" >/dev/null 2>&1; then
      log "应用 $name"
    else
      err "应用 $name 失败："
      git -C "$SRC_DIR" apply "$patch" 2>&1 | sed 's/^/        /' >&2 || true
      die "重放中断于 ${name}（前序补丁改动已落在 upstream/ 工作区，可 checkout -f 回退）。"
    fi
  done < <(list_patches)

  [ "$total" -gt 0 ] || { warn "$PATCHES_DIR 下没有 .patch，无补丁可应用。"; return 0; }
  log "已按序落地 $total 个补丁到 upstream/（gitlink 仍指向基线，编译取工作区文件）。"
}

main() {
  local mode="apply"
  case "${1:-}" in
    -h|--help)   usage; exit 0 ;;
    --preflight) mode="preflight" ;;
    --check)     mode="check" ;;
    --check-3way) mode="check-3way" ;;
    "")          mode="apply" ;;
    *)           die "未知参数：${1}（用 -h 查看用法）。" ;;
  esac

  [ -d "$SRC_DIR/.git" ] || [ -f "$SRC_DIR/.git" ] \
    || die "找不到已初始化的 submodule：${SRC_DIR}（先 git submodule update --init）。"
  [ -d "$PATCHES_DIR" ] || die "找不到补丁目录：$PATCHES_DIR"

  case "$mode" in
    preflight)  run_preflight ;;
    check)      run_check_mode strict ;;
    check-3way) run_check_mode 3way ;;
    apply)      run_apply ;;
  esac
}

main "$@"
