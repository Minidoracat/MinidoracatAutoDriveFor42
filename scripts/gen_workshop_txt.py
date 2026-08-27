# -*- coding: utf-8 -*-
"""由 STEAM_DESCRIPTION_EN.md 重新生成 workshop.txt 的 description 區塊。

用法：
    python scripts/gen_workshop_txt.py

規則（見 AGENTS.md 發布流程）：
- description 區塊是唯一由本腳本管理的部分；version/id/title/tags/visibility 保留既有值
- 首次發布時檔案尚無 id=，由遊戲內 Workshop 工具上傳後自動寫入；本腳本不生成也不猜 id
- EN 描述每行加 description= 前綴（空行也輸出 description=），行尾 LF、UTF-8 無 BOM
- 翻譯包（單語）把 SRC 改成 STEAM_DESCRIPTION.md

首發後流程：遊戲上傳 → 遊戲寫入 id= → 跑本腳本補描述 → commit。
之後每次更新：改 STEAM_DESCRIPTION_EN.md → 跑本腳本（id 會被保留）→ 上傳。
"""
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "STEAM_DESCRIPTION_EN.md")   # 翻譯包改為 STEAM_DESCRIPTION.md
DST = os.path.join(REPO, "MOD", "MinidoracatAutoDriveFor42", "workshop.txt")

TITLE = "Minidoracat MiniMap - AutoDrive for B42"
TAGS = "Build 42;Interface;Vehicles;Multiplayer"   # 翻譯類用 Build 42;Language/Translation
VISIBILITY = "public"

FIELD_RE = re.compile(r"^(version|id|title|tags|visibility)=", re.IGNORECASE)


def read_existing_fields(path):
    """保留既有的 version/id/title/tags/visibility（遊戲回寫的 id 絕不可覆蓋）。"""
    fields = {}
    if not os.path.isfile(path):
        return fields
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if FIELD_RE.match(line):
                key, _, value = line.partition("=")
                fields[key.strip().lower()] = value
    return fields


def build():
    with open(SRC, encoding="utf-8") as f:
        body = f.read().splitlines()

    existing = read_existing_fields(DST)
    out = ["version=" + existing.get("version", "1")]
    # id 只在既有檔案已有時保留；首次發布不輸出，待遊戲上傳後自動寫入
    if existing.get("id"):
        out.append("id=" + existing["id"])
    out.append("title=" + existing.get("title", TITLE))
    out.extend("description=" + line for line in body)
    out.append("tags=" + existing.get("tags", TAGS))
    out.append("visibility=" + existing.get("visibility", VISIBILITY))

    # 用 CRLF 寫出：與遊戲內 Workshop 工具上傳時的回寫格式一致，
    # 避免每次上傳後 git 都跳出只有行尾差異的假修改（.gitattributes 已對應設定，入庫仍為 LF）
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    with open(DST, "w", encoding="utf-8", newline="\r\n") as f:
        f.write("\n".join(out) + "\n")
    print("寫出:", DST)
    print("  description 行數:", len(body))
    print("  id:", existing.get("id") or "(尚未指派，首次上傳後由遊戲寫入)")


if __name__ == "__main__":
    build()
