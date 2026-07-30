#!/usr/bin/env python3
"""Guard: MOD runtime Lua must not call globals absent from PZ's Kahlua VM.

PZ (B42.19/42.20 verified) registers only 18 globals in Kahlua BaseLib (pcall/print/select/
type/tostring/tonumber/getmetatable/setmetatable/error/unpack/setfenv/getfenv/
rawequal/rawset/rawget/collectgarbage/debugstacktrace/bytecodeloader) plus
pairs/ipairs from TableLib -- notably **no `next` and no `assert`** (verified
against the decompiled 42.19.0/42.20.0 snapshots (BaseLib byte-identical)). Calling one crashes in-game with
"Object tried to call nil", but offline tests run under standard Lua where
these exist, so they can't catch it (0.10.0 shipped exactly this bug in
getLoadedMapDirs and every player fell back to the vanilla vector map).

Pure stdlib, no pytest dependency required -- but plain `assert` in
`test_*` functions is also pytest-discoverable, so both invocations work:
    python scripts/tests/test_kahlua_globals.py
    pytest scripts/tests/test_kahlua_globals.py
"""
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
RUNTIME_LUA_GLOB = "MOD/*/Contents/mods/*/42/media/lua/**/*.lua"

# Verified-missing globals only (extend after checking the decompiled
# BaseLib/TableLib/... registration, not on suspicion): bare call `name(`,
# not preceded by `.`/`:`/identifier char (excludes st.nextMs, obj:next()).
FORBIDDEN_CALL = re.compile(r"(?<![\w.:])(next|assert)\s*\(")
LINE_COMMENT = re.compile(r"--.*")


def test_no_kahlua_missing_globals_in_runtime_lua():
    files = sorted(REPO_ROOT.glob(RUNTIME_LUA_GLOB))
    assert files, f"glob matched no runtime lua files: {RUNTIME_LUA_GLOB}"
    hits = []
    for f in files:
        for lineno, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            m = FORBIDDEN_CALL.search(LINE_COMMENT.sub("", line))
            if m:
                hits.append(f"{f.relative_to(REPO_ROOT)}:{lineno}: {m.group(1)}( -- {line.strip()}")
    assert not hits, (
        "PZ Kahlua 未註冊這些全域，實機會炸 'Object tried to call nil'（離線測試抓不到）：\n"
        + "\n".join(hits)
    )


if __name__ == "__main__":
    test_no_kahlua_missing_globals_in_runtime_lua()
    print("test_kahlua_globals: OK")
