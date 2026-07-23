#!/usr/bin/env python3
"""严格校验 git unified diff 的 hunk 结构，不读取目标工作区。

`git apply --numstat` 对部分损坏的 hunk 会自动 recount，不能单独作为语法门禁。本校验器逐 hunk
核对 header 声明的 old/new 行数，并要求 body 每一行都有合法前缀（空上下文行必须是单个空格）。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HUNK = re.compile(rb"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: .*)?$")


def fail(path: Path, line: int, message: str) -> None:
    print(f"{path}:{line}: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate(path: Path) -> None:
    data = path.read_bytes()
    if b"\r" in data:
        fail(path, 1, "patch 含 CR/CRLF；必须使用 LF")

    lines = data.splitlines()
    if not lines:
        fail(path, 1, "空 patch")
    if not any(line.startswith(b"diff --git ") for line in lines):
        fail(path, 1, "缺少 diff --git 文件头")

    i = 0
    hunks = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith(b"@@"):
            match = HUNK.match(line)
            if not match:
                fail(path, i + 1, "非法 hunk header")

            old_need = int(match.group(2) or b"1")
            new_need = int(match.group(4) or b"1")
            old_seen = 0
            new_seen = 0
            hunks += 1
            i += 1

            while old_seen < old_need or new_seen < new_need:
                if i >= len(lines):
                    fail(path, i + 1, f"hunk 提前结束（old {old_seen}/{old_need}, new {new_seen}/{new_need}）")
                body = lines[i]
                if not body:
                    fail(path, i + 1, "hunk body 出现无前缀空行；空上下文行必须以一个空格开头")

                prefix = body[:1]
                if prefix == b" ":
                    old_seen += 1
                    new_seen += 1
                elif prefix == b"-":
                    old_seen += 1
                elif prefix == b"+":
                    new_seen += 1
                elif prefix == b"\\" and body == rb"\ No newline at end of file":
                    i += 1
                    continue
                else:
                    fail(path, i + 1, f"hunk body 非法前缀：{body[:20]!r}")

                if old_seen > old_need or new_seen > new_need:
                    fail(path, i + 1, f"hunk 行数超过 header（old {old_seen}/{old_need}, new {new_seen}/{new_need}）")
                i += 1
            continue
        i += 1

    # 纯 binary patch 可以没有 @@；普通文本 patch 至少应有一个 hunk。
    if hunks == 0 and b"GIT binary patch" not in data and b"Binary files " not in data:
        fail(path, 1, "未找到文本 hunk 或 binary patch 内容")


def main() -> None:
    if len(sys.argv) < 2:
        print(f"usage: {Path(sys.argv[0]).name} PATCH...", file=sys.stderr)
        raise SystemExit(2)
    for arg in sys.argv[1:]:
        validate(Path(arg))


if __name__ == "__main__":
    main()
