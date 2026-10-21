"""Compile-checks every Lua file of the addon with a real Lua 5.1 (WoW's dialect) and
checks the TOC lists every file that exists (and nothing that doesn't).

    tools\\.venv\\Scripts\\python.exe tools\\syntax_check.py [files...]

Exit code 0 = all good.
"""
import os
import re
import sys

import lupa.lua51 as lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(ROOT, "Greenfields")


def toc_files():
    toc = os.path.join(ADDON, "Greenfields.toc")
    out = []
    if not os.path.exists(toc):
        return out
    for line in open(toc, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append(line.replace("\\", os.sep))
    return out


def main(argv):
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    compile_ = rt.eval("function(src, name) local f, err = loadstring(src, name) return f ~= nil, err end")
    files = argv or []
    if not files:
        for dirpath, _, names in os.walk(ADDON):
            for n in names:
                if n.endswith(".lua"):
                    files.append(os.path.join(dirpath, n))
    bad = 0
    for path in sorted(files):
        raw = open(path, "rb").read()
        if raw.startswith(b"\xef\xbb\xbf"):
            print(f"BOM  {os.path.relpath(path, ROOT)} (strip the UTF-8 BOM)")
            bad += 1
            raw = raw[3:]
        src = raw.decode("utf-8", errors="replace")
        ok, err = compile_(src, "@" + os.path.relpath(path, ADDON))
        if not ok:
            print(f"FAIL {err}")
            bad += 1
        # WoW-specific footguns a compiler won't catch
        for i, line in enumerate(src.splitlines(), 1):
            code = line.split("--", 1)[0]
            if re.search(r"\bgetglobal\b|\bsetglobal\b|\bthis\b\s*[:.]", code):
                print(f"WARN {os.path.relpath(path, ROOT)}:{i}: legacy global API ({line.strip()[:80]})")
            if re.search(r'\bTRILINEAR\b', code):
                print(f"FAIL {os.path.relpath(path, ROOT)}:{i}: TRILINEAR filter crashes the Forever client")
                bad += 1
            if re.search(r"\bCombatLogGetCurrentEventInfo\b|COMBAT_LOG_EVENT_UNFILTERED", code):
                print(f"FAIL {os.path.relpath(path, ROOT)}:{i}: the combat log is restricted on Forever")
                bad += 1
    listed = toc_files()
    if listed:
        on_disk = set()
        for dirpath, _, names in os.walk(ADDON):
            for n in names:
                if n.endswith(".lua") or n.endswith(".xml"):
                    on_disk.add(os.path.relpath(os.path.join(dirpath, n), ADDON))
        for f in listed:
            if f not in on_disk:
                print(f"TOC  lists missing file {f}")
                bad += 1
        for f in sorted(on_disk - set(listed)):
            print(f"TOC  does not list {f}")
            bad += 1
    print(f"{len(files)} files checked, {bad} problem(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
