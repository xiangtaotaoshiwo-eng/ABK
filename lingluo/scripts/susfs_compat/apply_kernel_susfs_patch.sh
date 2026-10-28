#!/usr/bin/env bash
# SUSFS 内核侧补丁应用（50_add_susfs_in_<branch>.patch）
#
# 为什么需要这个脚本：
# susfs4ksu 的内核补丁以 GKI 基准树的代码为上下文生成。OnePlus / MTK 厂商分支
# 会删改这些上下文，导致 patch 把整个 hunk 丢掉（生成 .rej），构建在编译前就失败，
# 而且被丢掉的 hunk 里往往带着后续 hunk 依赖的宏（如 fs/namespace.c 的
# CL_COPY_MNT_NS），即使 patch 继续跑完也无法编译。
#
# 已覆盖的两类漂移：
#   1) include 上下文缺失（5.15 / 6.12 的厂商分支删了 vendor hook 头文件）
#      → 打补丁前注入垫片行，打完补丁再删掉。垫片只用于让 hunk 定位，
#        厂商分支本身并不需要这些 include。
#   2) 目标函数被厂商重构（6.12 的 show_smap / show_smaps_rollup 被
#      page-size-migration 改造）→ 跳过失败 hunk，按当前实现插入等价逻辑。
#
# 任何未修复的冲突都会以非零退出码显式失败，不会静默产出半成品内核。
#
# 用法: apply_kernel_susfs_patch.sh <kernel_common_dir> <patch_file>
set -uo pipefail

COMMON_DIR="${1:?用法: apply_kernel_susfs_patch.sh <kernel_common_dir> <patch_file>}"
PATCH_FILE="${2:?用法: apply_kernel_susfs_patch.sh <kernel_common_dir> <patch_file>}"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python

fail() { echo "::error::$1"; exit 1; }
info() { echo "  $*"; }

[ -d "$COMMON_DIR" ] || fail "内核目录不存在: $COMMON_DIR"
COMMON_DIR="$(cd "$COMMON_DIR" && pwd)" || fail "无法进入内核目录: $COMMON_DIR"
[ -f "$PATCH_FILE" ] || fail "SUSFS 内核补丁不存在: $PATCH_FILE"
PATCH_FILE="$(cd "$(dirname "$PATCH_FILE")" && pwd)/$(basename "$PATCH_FILE")"

cd "$COMMON_DIR" || fail "无法进入内核目录: $COMMON_DIR"

SHIMMED=()

# 补丁在「该文件的 diff 段落」里是否把这一行当作上下文
# （上下文行以单个空格开头）。必须限定文件段落：不同 GKI 分支的补丁会在
# 别的文件里出现同样的 include 行，按全文匹配会误判，例如 5.10 补丁只有
# 别的文件用了 <trace/hooks/mm.h>，task_mmu.c 段落并不依赖它。
patch_uses_context() {
  local file="$1" line="$2"
  awk -v header="diff --git a/$file b/$file" -v ctx=" $line" '
    $0 == header { insec = 1; next }
    /^diff --git / { insec = 0 }
    insec && $0 == ctx { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$PATCH_FILE"
}

# 在 anchor 行后注入垫片行
add_shim() {
  local file="$1" line="$2" anchor="$3"
  "$PY" - "$file" "$line" "$anchor" <<'PY'
import sys
path, line, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8', errors='surrogateescape') as f:
    lines = f.readlines()
if any(l.rstrip('\n') == line for l in lines):
    sys.exit(3)
for i, l in enumerate(lines):
    if l.rstrip('\n') == anchor:
        lines.insert(i + 1, line + '\n')
        with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
            f.writelines(lines)
        sys.exit(0)
sys.exit(4)
PY
}

# 删除垫片行（只删一行；注入前已确认不存在，故此删除是精确的）
del_shim() {
  local file="$1" line="$2"
  "$PY" - "$file" "$line" <<'PY'
import sys
path, line = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8', errors='surrogateescape') as f:
    lines = f.readlines()
for i, l in enumerate(lines):
    if l.rstrip('\n') == line:
        del lines[i]
        with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
            f.writelines(lines)
        sys.exit(0)
sys.exit(3)
PY
}

shim_candidate() {
  local file="$1" line="$2" anchor="$3"
  [ -f "$file" ] || return 0
  patch_uses_context "$file" "$line" || return 0
  grep -qxF "$line" "$file" && return 0
  grep -qxF "$anchor" "$file" || return 0
  if add_shim "$file" "$line" "$anchor"; then
    SHIMMED+=("$file"$'\t'"$line")
    info "上下文垫片注入: $file  ← $line"
  fi
}

echo "步骤 1/3: 注入上下文垫片（厂商分支删除的 include 行）"
shim_candidate fs/namespace.c        '#include <trace/hooks/blk.h>' '#include "internal.h"'
shim_candidate fs/proc/task_mmu.c    '#include <trace/hooks/mm.h>'  '#include <linux/pkeys.h>'
shim_candidate fs/exec.c             '#include <linux/dma-buf.h>'   '#include <linux/ksm.h>'

echo "步骤 2/3: 应用 SUSFS 内核补丁"
patch -p1 --forward --no-backup-if-mismatch <"$PATCH_FILE" >/tmp/susfs_kernel_patch.log 2>&1
patch_rc=$?
grep -E '^patching file|FAILED|Hunk #' /tmp/susfs_kernel_patch.log | grep -iE 'FAILED' || true
echo "  patch 退出码: $patch_rc"
[ "$patch_rc" -le 1 ] || fail "patch 执行失败（rc=$patch_rc），详见 /tmp/susfs_kernel_patch.log"

# 垫片使命完成，立即移除（厂商分支不需要这些头文件）
for entry in ${SHIMMED[@]+"${SHIMMED[@]}"}; do
  f="${entry%%$'\t'*}"; l="${entry##*$'\t'}"
  if del_shim "$f" "$l"; then
    info "上下文垫片移除: $f  ← $l"
  else
    fail "上下文垫片移除失败（$f: $l），请检查补丁产物"
  fi
done

echo "步骤 3/3: 失败 hunk 重适配"

# 6.12 起厂商分支把 show_smap / show_smaps_rollup 改成 page-size-migration 版本
# （vma_data_pages → vma_pages + show_map_pad_vma，rollup 循环体也重排），上游
# 补丁的 3 个 hunk 无法定位。这里按当前实现插入与上游语义等价的 SUS_MAP 过滤：
#   show_smap        : 命中 sus_map 的 VMA 直接返回 0（不输出该段）
#   show_smaps_rollup: 命中时跳过 gather，但仍推进 last_vma_end
fixup_task_mmu_smaps() {
  local rej="fs/proc/task_mmu.c.rej"
  [ -f "$rej" ] || return 0
  grep -q 'SUSFS_IS_INODE_SUS_MAP' "$rej" || return 0

  "$PY" - <<'PY'
import sys

path = "fs/proc/task_mmu.c"
with open(path, encoding='utf-8', errors='surrogateescape') as f:
    src = f.read()

done_smap = (
    "\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\tif (vma->vm_file) {\n"
    "\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n"
) in src

# --- show_smap：在函数首个语句前插入 sus_map 早退 ---
if not done_smap:
    idx = src.find("static int show_smap(struct seq_file *m, void *v)")
    if idx < 0:
        sys.exit(2)
    brace = src.find("{", idx)
    stmt = src.find("\n\tif (", brace)
    decl = src.find("struct mem_size_stats mss", brace, stmt)
    if brace < 0 or stmt < 0 or decl < 0:
        sys.exit(2)
    block = (
        "\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
        "\tif (vma->vm_file) {\n"
        "\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n"
        "\t\t\treturn 0;\n"
        "\t}\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    )
    src = src[:stmt] + block + src[stmt:]

# --- show_smaps_rollup：循环内跳过 sus_map 的 VMA，但仍推进 last_vma_end ---
idx = src.find("static int show_smaps_rollup(struct seq_file *m, void *v)")
if idx < 0:
    sys.exit(2)
nxt = src.find("\nstatic ", idx + 10)
seg = src[idx:nxt if nxt > 0 else len(src)]
if "bypass_orig_flow" not in seg:
    gather = "\t\tsmap_gather_stats(vma, &mss, 0);\n"
    pos = seg.find(gather)
    if pos < 0:
        sys.exit(2)
    tail = "\t\tlast_vma_end = vma->vm_end;\n"
    tpos = seg.find(tail, pos)
    if tpos < 0:
        sys.exit(2)
    seg = (
        seg[:pos]
        + "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
        + "\t\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n"
        + "\t\t\tgoto bypass_orig_flow;\n"
        + "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
        + gather
        + "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
        + "bypass_orig_flow:\n"
        + "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
        + seg[tpos:]
    )
    src = src[:idx] + seg + (src[nxt:] if nxt > 0 else "")

if 'bypass_orig_flow' not in seg:
    sys.exit(2)

with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
    f.write(src)
PY
  local rc=$?
  [ "$rc" -eq 0 ] || fail "task_mmu.c 的 smaps 漂移重适配失败（rc=$rc），当前内核实现与预期不符"
  rm -f "$rej"
  info "task_mmu.c smaps 漂移已重适配（show_smap / show_smaps_rollup）"
}

fixup_task_mmu_smaps

# ---- 结果校验：不允许任何未处理的冲突或半应用状态 ----
REJS=$(find . -name '*.rej' -not -path './.git/*' | wc -l)
[ "$REJS" -eq 0 ] || {
  find . -name '*.rej' -not -path './.git/*' | sed 's/^/  /'
  fail "SUSFS 内核补丁仍有 $REJS 个未修复的 .rej"
}
if grep -rqE '^(<<<<<<< |=======$|>>>>>>> )' fs kernel mm security 2>/dev/null; then
  fail "SUSFS 内核补丁产物存在冲突标记"
fi

grep -q 'susfs_def.h' fs/proc/task_mmu.c || fail "task_mmu.c 缺少 susfs_def.h（hunk 未应用）"
if grep -q '^+#define CL_COPY_MNT_NS' "$PATCH_FILE"; then
  grep -q 'define CL_COPY_MNT_NS' fs/namespace.c \
    || fail "namespace.c 缺少 CL_COPY_MNT_NS 定义（copy_mnt_ns 的 SUSFS 分支依赖它）"
fi
if grep -q '^+#include <linux/susfs_def.h>' "$PATCH_FILE" && [ -f fs/exec.c ]; then
  if grep -q '^diff --git a/fs/exec.c' "$PATCH_FILE"; then
    grep -q 'susfs_def.h' fs/exec.c || fail "exec.c 缺少 susfs_def.h（hunk 未应用）"
  fi
fi

find . -name '*.orig' -not -path './.git/*' -delete 2>/dev/null || true

echo "SUSFS 内核补丁应用完成（无残留冲突）"
