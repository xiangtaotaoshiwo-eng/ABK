#!/usr/bin/env bash
# fengchi(hmbird) 补丁的 KABI 漂移修复
#
# 为什么需要这个脚本：
#   oneplus/hmbird/fengchi_<MODEL>_<OS>.patch 把 OnePlus 的 slim-sched 换回 hmbird，
#   其中 include/linux/sched.h 的 hunk 要把 task_struct 里的
#       #ifdef CONFIG_SLIM_SCHED
#           ANDROID_KABI_USE(1, unsigned long sched_prop);
#           ANDROID_KABI_USE(2, struct sched_ext_entity *scx);
#       #else
#           ANDROID_KABI_RESERVE(1);
#           ANDROID_KABI_RESERVE(2);
#       #endif
#   改回 ANDROID_KABI_RESERVE(1/2)。
#
#   较新的一加源码（如 6.6.89 A16）在同一处多插了一个 KABI 槽：
#       ANDROID_KABI_USE(3, struct task_dma_buf_info *dmabuf_info);
#   #else 分支也变成 USE(1, dmabuf_info) + RESERVE(2) + RESERVE(3)，
#   整个 hunk 的上下文对不上 → patch 丢弃该 hunk 并生成 .rej，
#   Apply Other Patches 步骤在 set -e 下直接退出，编译一次都没跑。
#
#   而且这个 hunk 失败是"半应用"状态：前一个 hunk 已经删掉了
#   #include <linux/sched/ext.h>，task_struct 却还留着
#   `struct sched_ext_entity *scx;`，即使继续编译也必然报未知类型。
#
# 做法：按目标 sched.h 的实际布局重写补丁里这一个 hunk —— 保留厂商的
#   #else 分支内容（dmabuf_info 槽不动），只删掉 slim-sched 的条件包裹。
#   不修改内核源码，补丁文件是构建时新克隆的，重写后原地应用。
#
# 用法: fix_hmbird_patch_drift.sh <kernel_common_dir> <patch_file>
set -uo pipefail

COMMON_DIR="${1:?用法: fix_hmbird_patch_drift.sh <kernel_common_dir> <patch_file>}"
PATCH_FILE="${2:?用法: fix_hmbird_patch_drift.sh <kernel_common_dir> <patch_file>}"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python

fail() { echo "::error::$1"; exit 1; }
info() { echo "  $*"; }

[ -d "$COMMON_DIR" ] || fail "内核目录不存在: $COMMON_DIR"
[ -f "$PATCH_FILE" ] || fail "hmbird 补丁不存在: $PATCH_FILE"

SCHED_H="$COMMON_DIR/include/linux/sched.h"
[ -f "$SCHED_H" ] || fail "找不到 include/linux/sched.h: $SCHED_H"

"$PY" - "$SCHED_H" "$PATCH_FILE" <<'PY'
import os
import re
import shutil
import subprocess
import sys
import tempfile

sched_path, patch_path = sys.argv[1], sys.argv[2]
CTX = 3

with open(sched_path, encoding='utf-8', errors='surrogateescape') as f:
    src = f.readlines()
with open(patch_path, encoding='utf-8', errors='surrogateescape') as f:
    patch = f.readlines()


def die(msg, rc=2):
    print("::error::" + msg)
    sys.exit(rc)


# ---- 1. 在 sched.h 里定位 slim-sched 的 KABI 块 ----
def locate_block():
    for i, line in enumerate(src):
        if line.strip() != '#ifdef CONFIG_SLIM_SCHED':
            continue
        window = ''.join(src[i + 1:i + 6])
        if 'ANDROID_KABI_USE(1, unsigned long sched_prop);' not in window:
            continue
        depth = 0
        else_idx = None
        for j in range(i, len(src)):
            t = src[j].strip()
            if t.startswith('#ifdef') or t.startswith('#ifndef') or t.startswith('#if '):
                depth += 1
            elif t.startswith('#endif'):
                depth -= 1
                if depth == 0:
                    return i, else_idx, j
            elif t.startswith('#else') and depth == 1 and else_idx is None:
                else_idx = j
        die("sched.h 的 CONFIG_SLIM_SCHED 块没有配对的 #endif")
    return None


block = locate_block()
if block is None:
    print("  sched.h 已无 slim-sched KABI 块，无需修复")
    sys.exit(0)

iface, else_idx, endif = block
if else_idx is None:
    die("sched.h 的 CONFIG_SLIM_SCHED 块缺少 #else（布局与预期不符）")

# 保留厂商 #else 分支的内容（非 slim 布局），删掉 ifdef/#else/#endif 包裹
cond_head = src[iface:else_idx + 1]      # '#ifdef ...' 到 '#else'（含）
else_body = src[else_idx + 1:endif]      # 非 slim 布局本体
endif_line = src[endif]

# ---- 2. 在补丁里定位对应 hunk ----
def hunk_spans():
    spans = []
    in_sched = False
    for idx, line in enumerate(patch):
        if line.startswith('diff --git '):
            in_sched = 'include/linux/sched.h' in line
        elif line.startswith('@@ ') and in_sched:
            spans.append(idx)
    out = []
    for k, start in enumerate(spans):
        end = spans[k + 1] if k + 1 < len(spans) else len(patch)
        for idx in range(start + 1, end):
            if patch[idx].startswith('diff --git '):
                end = idx
                break
        out.append((start, end))
    return out


target = None
for start, end in hunk_spans():
    for line in patch[start + 1:end]:
        if re.match(r'^-\s*ANDROID_KABI_USE\(1,\s*unsigned long sched_prop\);', line):
            target = (start, end)
            break
    if target:
        break


def build_hunk():
    lo = max(0, iface - CTX)
    hi = min(len(src), endif + 1 + CTX)
    body = []
    for line in src[lo:iface]:
        body.append(' ' + line)
    for line in cond_head:
        body.append('-' + line)
    for line in else_body:
        body.append(' ' + line)
    body.append('-' + endif_line)
    for line in src[endif + 1:hi]:
        body.append(' ' + line)

    old_count = sum(1 for b in body if b[0] in ' -')
    new_count = sum(1 for b in body if b[0] in ' +')
    header = '@@ -%d,%d +%d,%d @@ struct task_struct {\n' % (lo + 1, old_count, lo + 1, new_count)
    hunk = header + ''.join(body)
    if not hunk.endswith('\n'):
        hunk += '\n'
    return hunk


new_hunk = build_hunk()

if target is None:
    print("  补丁里没有 sched_prop hunk（上游可能已适配），无需修复")
    sys.exit(0)

start, end = target
old_hunk = ''.join(patch[start:end])


def changes(text):
    out = []
    for line in text.splitlines():
        if line.startswith('---') or line.startswith('+++'):
            continue
        if line[:1] in ('-', '+'):
            out.append(line.rstrip('\r'))
    return out


if changes(old_hunk) == changes(new_hunk):
    print("  补丁 hunk 与当前 KABI 布局已一致，无需修复")
    sys.exit(0)

had_dmabuf = 'dmabuf_info' in ''.join(else_body)

# ---- 3. 自检：在临时副本上试打这个 hunk ----
tmpdir = tempfile.mkdtemp(prefix='hmbird-kabi-')
try:
    dst = os.path.join(tmpdir, 'include', 'linux')
    os.makedirs(dst)
    tmp_sched = os.path.join(dst, 'sched.h')
    shutil.copyfile(sched_path, tmp_sched)

    probe = os.path.join(tmpdir, 'probe.patch')
    with open(probe, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write('--- a/include/linux/sched.h\n+++ b/include/linux/sched.h\n')
        f.write(new_hunk)

    r = subprocess.run(['patch', '-p1', '--no-backup-if-mismatch', '-i', probe],
                       cwd=tmpdir, capture_output=True, text=True)
    if r.returncode != 0:
        die("重写后的 hunk 自检失败（rc=%d）：%s" % (r.returncode, (r.stdout + r.stderr).strip()))

    with open(tmp_sched, encoding='utf-8', errors='surrogateescape') as f:
        applied = f.read()
    if 'ANDROID_KABI_USE(1, unsigned long sched_prop);' in applied:
        die("自检失败：应用后仍残留 slim-sched 的 sched_prop KABI 槽")
    if had_dmabuf and 'dmabuf_info' not in applied:
        die("自检失败：应用后 dmabuf_info 槽丢失")
finally:
    shutil.rmtree(tmpdir, ignore_errors=True)

# ---- 4. 写回补丁 ----
patch[start:end] = [new_hunk]
with open(patch_path, 'w', encoding='utf-8', errors='surrogateescape') as f:
    f.writelines(patch)

print("  已重写 fengchi 补丁的 sched.h KABI hunk（保留 dmabuf_info 槽）")
PY

rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

echo "hmbird 补丁 KABI 漂移检查完成: $(basename "$PATCH_FILE")"
