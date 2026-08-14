# -*- coding: utf-8 -*-
"""Lock: TPL_STRINGS_JSON in MinidoracatZonesShared.lua must match the four
UI.json files verbatim (per design: "常數必須與 UI.json 逐字同步").

The Lua desktop tests cannot decode the CJK ``\\uXXXX`` escapes in the constant
(PUC/LuaJIT ``string.char`` rejects code points > 255 -- see the ENV-LIMITED
note in test_zones_lua.lua). Python has no such limit, so this test is the
authoritative four-language "decode -> compare to UI.json" verification for the
generated constant.

Usage:
  python scripts/tests/test_tpl_strings.py [repoRoot]           # verify (default)
  python scripts/tests/test_tpl_strings.py [repoRoot] --emit    # print the Lua line
"""
import json
import os
import re
import sys

LANGS = ("CH", "CN", "EN", "JP")
KEYS = (
    ("wp", "UI_MinidoracatMiniMapZones_TplWestPoint"),
    ("rw", "UI_MinidoracatMiniMapZones_TplRosewood"),
    ("br", "UI_MinidoracatMiniMapZones_TplBunker"),
    ("ml", "UI_MinidoracatMiniMapZones_TplMultiRect"),
    ("ct", "UI_MinidoracatMiniMapZones_TplCatTown"),
    ("cf", "UI_MinidoracatMiniMapZones_TplCatField"),
    ("doc", "UI_MinidoracatMiniMapZones_TplDoc"),
)


def _ui_path(root, lang):
    return os.path.join(
        root, "MOD", "MinidoracatMiniMapZonesFor42", "Contents", "mods",
        "MinidoracatMiniMapZonesFor42", "42", "media", "lua", "shared",
        "Translate", lang, "UI.json")


def _shared_path(root):
    return os.path.join(
        root, "MOD", "MinidoracatMiniMapZonesFor42", "Contents", "mods",
        "MinidoracatMiniMapZonesFor42", "42", "media", "lua", "shared",
        "MinidoracatZonesShared.lua")


def _load_ui(root, lang):
    with open(_ui_path(root, lang), encoding="utf-8-sig") as f:
        return json.load(f)


def build_payload(root):
    """Inner JSON string (ASCII \\u-escaped), before Lua-literal escaping."""
    data = {}
    for lang in LANGS:
        ui = _load_ui(root, lang)
        data[lang] = {short: ui[full] for short, full in KEYS}
    return json.dumps(data, ensure_ascii=True, separators=(",", ":"))


def lua_escape(s):
    """Embed a string in a Lua single-quoted literal: only \\ and ' need escaping."""
    return s.replace("\\", "\\\\").replace("'", "\\'")


def lua_unescape(payload):
    """Reverse lua_escape: undo only \\\\ -> \\ and \\' -> ', keep \\u/\\\" intact."""
    out, i = [], 0
    while i < len(payload):
        c = payload[i]
        if c == "\\" and i + 1 < len(payload) and payload[i + 1] in ("\\", "'"):
            out.append(payload[i + 1])
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def build_line(root):
    return "local TPL_STRINGS_JSON = '" + lua_escape(build_payload(root)) + "'"


def extract_payload(root):
    src = open(_shared_path(root), encoding="utf-8").read()
    m = re.search(r"^local TPL_STRINGS_JSON = '(.*)'\s*$", src, re.M)
    assert m, "找不到 shared lua 內的 TPL_STRINGS_JSON 常數行"
    return m.group(1)


def main():
    args = [a for a in sys.argv[1:] if a != "--emit"]
    root = args[0] if args else "."
    if "--emit" in sys.argv[1:]:
        print(build_line(root))
        return

    expected = build_payload(root)
    actual_lua = extract_payload(root)
    actual = lua_unescape(actual_lua)
    assert actual == expected, (
        "TPL_STRINGS_JSON 與 UI.json 不同步 (逐字比對失敗)。"
        "請重跑 `python scripts/tests/test_tpl_strings.py . --emit` 更新常數。")

    # 四語各 decode 驗證 name/doc = 對應語言 UI.json (Python 無 CJK string.char 限制)
    decoded = json.loads(actual)
    for lang in LANGS:
        ui = _load_ui(root, lang)
        for short, full in KEYS:
            assert decoded[lang][short] == ui[full], (
                f"{lang}.{short} 與 UI.json[{full}] 不符")
    print("[OK] TPL_STRINGS_JSON matches all four UI.json (CH/CN/EN/JP)")


if __name__ == "__main__":
    main()
