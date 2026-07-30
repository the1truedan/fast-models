#!/usr/bin/env python3
"""Strip bees weak gettid redefinition so Alpine/musl libc gettid(3) is used.

Run from the bees source tree root (after git clone of a pinned tag).
bees sources use tabs for indentation inside extern \"C\" blocks.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def strip_header(path: Path) -> None:
    text = path.read_text()
    # Match both tab- and space-indented gettid declarations.
    new, n = re.subn(
        r'\nextern "C" \{\n'
        r"\t?pid_t gettid\(\) throw\(\);\n"
        r"\};\n",
        "\n",
        text,
        count=1,
    )
    if n != 1:
        if "gettid() throw()" not in text:
            print(f"{path}: gettid declaration already absent")
            return
        sys.exit(f"{path}: failed to remove gettid declaration")
    path.write_text(new)
    print(f"{path}: removed gettid declaration")


def strip_cc(path: Path) -> None:
    text = path.read_text()
    new, n = re.subn(
        r'\nextern "C" \{\n'
        r"\tpid_t\n"
        r"\t__attribute__\(\(weak\)\)\n"
        r"\tgettid\(\) throw\(\)\n"
        r"\t\{\n"
        r"\t\treturn syscall\(SYS_gettid\);\n"
        r"\t\}\n"
        r"\};\n",
        "\n",
        text,
        count=1,
    )
    if n != 1:
        if "gettid() throw()" not in text and "__attribute__((weak))" not in text:
            print(f"{path}: weak gettid definition already absent")
            return
        sys.exit(f"{path}: failed to remove weak gettid definition")
    path.write_text(new)
    print(f"{path}: removed weak gettid definition")


def main() -> None:
    root = Path.cwd()
    strip_header(root / "include" / "crucible" / "process.h")
    strip_cc(root / "lib" / "process.cc")
    print("musl gettid compatibility applied")


if __name__ == "__main__":
    main()
