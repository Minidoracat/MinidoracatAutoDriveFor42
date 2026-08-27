# -*- coding: utf-8 -*-
"""由 CHANGELOG.md 產生可直接貼進 Steam Workshop 更新說明的 BBCode。

用法：
    python scripts/gen_steam_changelog.py              # 最新一版
    python scripts/gen_steam_changelog.py 42.20.2-0.2.6  # 指定版本

產出 STEAM_CHANGELOG.md（BBCode，非 Markdown），內容整檔複製貼上即可。

為什麼要有這支腳本：CHANGELOG.md 是雙受眾文件——bullet 給玩家、`> 技術要點：` 給開發。
靠人工「複製時記得跳過技術區塊」遲早會漏，而漏掉的後果是把出處行號、內部機制、
甚至攻擊面描述貼上公開頁面。改由腳本抽取＋轉換，來源單一、規則固定。

轉換規則：
- 只取指定版本那一節；`>` 開頭的引用塊（技術要點）整段剔除
- `### 小節` → [h3] 加對應 emoji；`- 項目` → [list][*]；4 空格縮排 → 巢狀 [list]
- `**粗體**` → [b][/b]；反引號整個剝掉（依撰寫規則，玩家層本就不該出現程式碼）
- 產出後自動跑洩漏掃描（路徑／IP／SteamID／主機名）並在有命中時以非零碼結束

注意：Steam Workshop 的「更新說明」是單一欄位、沒有語系分頁（描述才有），
因此本檔只產生 CHANGELOG 的原始語言版本。要附其他語言就在產出後手動追加一段。
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "CHANGELOG.md")
DST = os.path.join(REPO, "STEAM_CHANGELOG.md")

SECTION_EMOJI = {
    "新增": "✨", "變更": "🔄", "更新": "🔄", "修正": "🔧", "效能": "⚡", "移除": "🗑️", "安全": "🛡️",
    "Added": "✨", "Changed": "🔄", "Fixed": "🔧", "Removed": "🗑️", "Notes": "📝",
}

# 術語啟發式：命中不代表錯（可能是刻意提及的 MOD 名），但玩家層 bullet 出現這些
# 通常代表該條目該改寫。只警告不失敗——判斷交給人。
JARGON_PATTERNS = [
    (re.compile(r"\b\w+\.(?:java|lua)\b"), "原始檔名"),
    (re.compile(r"\b[a-z][A-Za-z0-9]*\s*\("), "函式呼叫"),
    (re.compile(r"\b(?:Kahlua|BaseLib|TableLib|Lua|API|callback|hook|packet|thread|"
                r"cache|index|null|nil|boolean|table|string)\b"), "引擎／程式術語"),
    (re.compile(r":\d{2,4}\b"), "行號引用"),
]

LEAK_PATTERNS = [
    (re.compile(r"/home/\w+"), "Linux 家目錄路徑"),
    (re.compile(r"[A-Z]:\\Users\\"), "Windows 使用者路徑"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "IPv4 位址"),
    (re.compile(r"\b7656\d{13}\b"), "SteamID64"),
    (re.compile(r"\bssh\b", re.IGNORECASE), "ssh 字樣"),
    (re.compile(r"pz-?server", re.IGNORECASE), "伺服器主機名"),
]


def mod_display_name():
    """從 mod.info 取顯示名稱當標題；找不到就退回資料夾名。"""
    mod_root = os.path.join(REPO, "MOD")
    if os.path.isdir(mod_root):
        for folder in os.listdir(mod_root):
            base = os.path.join(mod_root, folder, "Contents", "mods")
            if not os.path.isdir(base):
                continue
            for inner in os.listdir(base):
                info = os.path.join(base, inner, "42", "mod.info")
                if os.path.isfile(info):
                    with open(info, encoding="utf-8") as fh:
                        for line in fh:
                            if line.startswith("name="):
                                return line.split("=", 1)[1].strip()
                    return inner
    return os.path.basename(REPO)


def inline(text):
    text = re.sub(r"\*\*(.+?)\*\*", r"[b]\1[/b]", text)
    text = text.replace("`", "")
    return text.strip()


def main():
    if not os.path.isfile(SRC):
        print("找不到 CHANGELOG.md")
        return 2

    with open(SRC, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    want = sys.argv[1] if len(sys.argv) > 1 else None
    # 家族內存在兩種版本標題寫法，都要吃：
    #   ## [42.20.2-0.2.6] - 2026-08-10      （Keep a Changelog 式，多數 repo）
    #   ## 42.19.0-1.0.0（2026-07-13）        （無方括號＋全形括號，LootQualityLang）
    # 版本號必須以數字開頭，藉此排除「## Changelog」這類非版本標題
    head_re = re.compile(
        r"^##\s+\[?(\d[\w.\-]*)\]?\s*(?:[-–—]\s*(\S.*?)|[（(]\s*(.+?)\s*[）)])?\s*$"
    )

    start = end = None
    version = date = ""
    for i, line in enumerate(lines):
        mm = head_re.match(line)
        if not mm:
            continue
        if start is None and (want is None or mm.group(1) == want):
            start, version = i + 1, mm.group(1)
            date = (mm.group(2) or mm.group(3) or "").strip()
        elif start is not None:
            end = i
            break
    if start is None:
        print(f"找不到版本節：{want or '（最新）'}")
        return 2
    body = lines[start:end]

    out = [f"[h1]{mod_display_name()} {version}[/h1]"]
    if date:
        out.append(f"[i]{date}[/i]")

    in_list = in_sub = False

    def close_sub():
        nonlocal in_sub
        if in_sub:
            out.append("[/list]")
            in_sub = False

    def close_list():
        nonlocal in_list
        close_sub()
        if in_list:
            out.append("[/list]")
            in_list = False

    for raw in body:
        if raw.lstrip().startswith(">"):          # 技術要點：整段剔除
            continue
        sec = re.match(r"^###\s+(.+?)\s*$", raw)
        if sec:
            close_list()
            title = sec.group(1)
            out.append("")
            out.append(f"[h3]{SECTION_EMOJI.get(title, '•')} {title}[/h3]")
            continue
        sub = re.match(r"^\s{2,}[-*]\s+(.+)$", raw)   # 巢狀（2 空格以上縮排）
        if sub and in_list:
            if not in_sub:
                out.append("[list]")
                in_sub = True
            out.append(f"[*] {inline(sub.group(1))}")
            continue
        top = re.match(r"^[-*]\s+(.+)$", raw)
        if top:
            close_sub()
            if not in_list:
                out.append("[list]")
                in_list = True
            out.append(f"[*] {inline(top.group(1))}")
            continue
        if raw.strip() == "":
            continue
        if (in_list or in_sub) and raw[:1].isspace():
            # 縮排續行（無 dash）＝上一個條目的折行，接回同一 [*]；CJK 邊界不補空格
            cont = inline(raw)
            sep = "" if (out[-1] and ord(out[-1][-1]) > 0x2E7F) or ord(cont[0]) > 0x2E7F else " "
            out[-1] += sep + cont
            continue
        close_list()
        out.append(inline(raw))
    close_list()

    text = "\n".join(out).strip() + "\n"
    with open(DST, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)

    bullets = text.count("[*]")
    print(f"寫出: {DST}")
    print(f"  版本: {version}{'  ' + date if date else ''}")
    print(f"  條目: {bullets}   位元組: {len(text.encode('utf-8'))}")

    leaks = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for pat, desc in LEAK_PATTERNS:
            mm = pat.search(line)
            if mm:
                leaks.append(f"  第 {lineno} 行 {desc}（{mm.group()[:40]}）")
    if leaks:
        print("\n洩漏掃描 FAIL——貼上前必須先修 CHANGELOG 來源：")
        print("\n".join(leaks))
        return 1
    if bullets == 0:
        print("\n警告：這一版剝掉技術區塊後沒有任何條目，檢查 CHANGELOG 是否只寫了技術要點")
        return 1
    print("  洩漏掃描: PASS")

    jargon = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line.startswith("[*]"):
            continue
        for pat, desc in JARGON_PATTERNS:
            for mm in pat.finditer(line):
                jargon.append(f"  第 {lineno} 行 {desc}：{mm.group().strip()}")
    if jargon:
        seen, uniq = set(), []
        for j in jargon:
            if j not in seen:
                seen.add(j)
                uniq.append(j)
        print(f"\n術語警示（{len(uniq)} 處）——玩家層條目出現這些通常代表該改寫 CHANGELOG："
              "\n" + "\n".join(uniq[:12]))
        if len(uniq) > 12:
            print(f"  …另有 {len(uniq) - 12} 處")
        print("  （僅警告，不影響退出碼；確認是刻意用詞就忽略）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
