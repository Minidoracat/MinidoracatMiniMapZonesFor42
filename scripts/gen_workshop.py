#!/usr/bin/env python3
"""產生 MOD/MinidoracatMiniMapZonesFor42/workshop.txt（Workshop 上傳工具輸入）。

workshop.txt 是產物、不進版控（.gitignore）：來源＝STEAM_DESCRIPTION_EN.md
（EN＝上傳工具推成 Steam 主/預設語言槽，所有無專屬槽語言的 fallback；
繁中/日文靠網頁語言槽貼），metadata 內建於本腳本（變動極罕）。
同主 MOD scripts/gen_workshop.py 家族規則（AGENTS.md 發布流程第 2 步）。

遊戲上傳（或開上傳工具）後會回寫本檔——內容為 Steam 主語言槽描述＋CRLF＋
結尾 "Workshop ID:" 行（getSubmitDescription，SteamWorkshopItem.java:164-181）。
因不進版控，回寫不會弄髒工作樹；下次發版重跑本腳本即還原。
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EN = os.path.join(ROOT, "STEAM_DESCRIPTION_EN.md")
OUT = os.path.join(ROOT, "MOD", "MinidoracatMiniMapZonesFor42", "workshop.txt")

# Workshop metadata（來源真相在此；workshop.txt 已不入版控）
META_HEAD = [
    "version=1",
    "id=3768276209",
    "title=Minidoracat MiniMap Zones",
]
META_TAIL = [
    "tags=Build 42;Interface;Map;Multiplayer",
    "visibility=public",
]


def main():
    with open(EN, encoding="utf-8") as fh:
        en = fh.read().rstrip("\n").splitlines()
    lines = META_HEAD + ["description=" + l for l in en] + META_TAIL
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"workshop.txt: {len(en)} description lines, {os.path.getsize(OUT)} bytes")


if __name__ == "__main__":
    main()
