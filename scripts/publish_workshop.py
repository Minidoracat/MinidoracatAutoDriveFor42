# -*- coding: utf-8 -*-
"""Steam Workshop 發布工具（原生 Steamworks，需 Steam 用戶端已登入作者帳號）。

    uv run --no-project python -B scripts/publish_workshop.py                 # 互動選單
    uv run --no-project python -B scripts/publish_workshop.py --mode all --yes  # AI／自動化
    uv run --no-project python -B scripts/publish_workshop.py --mode description --dry-run

mode：content（MOD 內容＋更新說明）／preview（GIF 封面）／description（英繁簡日簡介）／screenshots（詳情頁介面預覽圖，英先中後）／all。
流程：登入檢查 → 前置檢查 → 顯示計畫 → 確認 → 提交 → 線上驗證。
非互動（stdin 非 tty 或給了 --mode）未登入時直接以 exit 3 結束，不等待輸入。

為什麼不用 SteamCMD：實測 SteamCMD 只寫英文槽（update_language 被忽略），VDF 遇到 \" 會截斷簡介；
原生 ISteamUGC 一次更新一個語言槽，內容／封面／更新說明隨英文那次提交。
退出碼：0 成功 2 參數 3 未登入或帳號不符 4 前置檢查失敗 5 提交失敗 6 線上驗證失敗
"""
import argparse
import ctypes
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STEAM_API_DLL = os.environ.get("PUBLISH_STEAM_API_DLL",
                               r"D:\SteamLibrary\steamapps\common\ProjectZomboid\steam_api64.dll")
LANG_NAMES = {"english": "英文", "tchinese": "繁中", "schinese": "簡中", "japanese": "日文"}
MODES = ("content", "preview", "description", "screenshots", "all")
SCREENSHOT_DIR = os.path.join("docs", "screenshots", "steam")
SCREENSHOT_LANGS = ("en", "zh")  # Workshop 詳情頁預覽圖順序：英文在前、中文在後
SCREENSHOT_MAX_BYTES = 280_000  # AddItemPreviewFile 實測 274KB 成功、314KB 回 EResult 25（LimitExceeded）；網頁上傳的 2MB 上限不適用
SUBMIT_RESULT_CALLBACK = 3404  # k_iSteamUGCCallbacks(3400) + 4 = SubmitItemUpdateResult_t
UPDATE_STATUS = {1: "準備設定", 2: "準備內容", 3: "上傳內容", 4: "上傳封面", 5: "提交變更"}  # 0 = Invalid（已結束）
INVALID_HANDLE = (0, 2**64 - 1)  # k_UGCUpdateHandleInvalid / k_UGCQueryHandleInvalid 是 UINT64_MAX


def die(code, message):
    print(f"[FAIL] {message}")
    sys.exit(code)


def ask(prompt):
    """互動輸入；stdin 無法讀（EOF／被重導）就明確結束，不讓自動化卡在提示。"""
    try:
        return input(prompt).strip()
    except EOFError:
        print()
        die(2, "沒有可用的互動輸入；自動化請指定 --mode <content|preview|description|all> --yes")


def load_config(path):
    with open(path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    for key in ("app_id", "published_file_id", "owner_steamid64", "workshop_root", "mod_info",
                "preview_gif", "changelog", "descriptions"):
        if key not in cfg:
            die(4, f"設定檔缺少 {key}：{path}")
    cfg.setdefault("titles", {})  # 選用：{語言: 標題}，與簡介同批逐槽提交
    if not cfg["published_file_id"]:
        die(4, "此 MOD 尚未首發（published_file_id 為 null）：先用遊戲內 Workshop 上傳器建立作品取得 ID，填入設定檔後再用本工具更新")
    return cfg


def repo_path(rel):
    return os.path.normpath(os.path.join(REPO, rel))


def read_text(path):
    with open(path, encoding="utf-8-sig") as fh:
        return fh.read().rstrip("\n")


def mod_version(mod_info_path):
    for line in read_text(mod_info_path).splitlines():
        if line.startswith("modversion="):
            return line.split("=", 1)[1].strip()
    die(4, f"mod.info 沒有 modversion：{mod_info_path}")


# ---- Steamworks flat API（ctypes）----
class Steam:
    def __init__(self, app_id):
        if not os.path.isfile(STEAM_API_DLL):
            raise RuntimeError(f"找不到 steam_api64.dll：{STEAM_API_DLL}（可用環境變數 PUBLISH_STEAM_API_DLL 指定）")
        # SteamAPI_Init 讀 cwd 的 steam_appid.txt；寫進暫存目錄，不污染 repo
        self.tmp = tempfile.mkdtemp(prefix="pz-workshop-")
        with open(os.path.join(self.tmp, "steam_appid.txt"), "w") as fh:
            fh.write(str(app_id))
        self.prev_cwd = os.getcwd()
        os.chdir(self.tmp)
        try:
            self._bind_and_init()
        except BaseException:
            os.chdir(self.prev_cwd)
            raise

    def _bind_and_init(self):
        self.dll = ctypes.CDLL(STEAM_API_DLL)
        d = self.dll
        d.SteamAPI_InitFlat.argtypes = [ctypes.c_char_p]
        d.SteamAPI_InitFlat.restype = ctypes.c_int
        d.SteamAPI_GetHSteamPipe.restype = ctypes.c_int32
        d.SteamAPI_ManualDispatch_RunFrame.argtypes = [ctypes.c_int32]
        for name in ("SteamAPI_SteamUser_v023", "SteamAPI_SteamUGC_v021", "SteamAPI_SteamUtils_v010"):
            getattr(d, name).restype = ctypes.c_void_p
        d.SteamAPI_ISteamUser_BLoggedOn.argtypes = [ctypes.c_void_p]
        d.SteamAPI_ISteamUser_BLoggedOn.restype = ctypes.c_bool
        d.SteamAPI_ISteamUser_GetSteamID.argtypes = [ctypes.c_void_p]
        d.SteamAPI_ISteamUser_GetSteamID.restype = ctypes.c_uint64
        d.SteamAPI_ISteamUGC_StartItemUpdate.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint64]
        d.SteamAPI_ISteamUGC_StartItemUpdate.restype = ctypes.c_uint64
        for name in ("SetItemUpdateLanguage", "SetItemTitle", "SetItemDescription", "SetItemContent", "SetItemPreview"):
            fn = getattr(d, "SteamAPI_ISteamUGC_" + name)
            fn.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
            fn.restype = ctypes.c_bool
        d.SteamAPI_ISteamUGC_SubmitItemUpdate.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        d.SteamAPI_ISteamUGC_SubmitItemUpdate.restype = ctypes.c_uint64
        d.SteamAPI_ISteamUGC_GetItemUpdateProgress.argtypes = [
            ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64)]
        d.SteamAPI_ISteamUGC_GetItemUpdateProgress.restype = ctypes.c_int
        d.SteamAPI_ISteamUtils_IsAPICallCompleted.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_bool)]
        d.SteamAPI_ISteamUtils_IsAPICallCompleted.restype = ctypes.c_bool
        d.SteamAPI_ISteamUtils_GetAPICallResult.argtypes = [
            ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_bool)]
        d.SteamAPI_ISteamUtils_GetAPICallResult.restype = ctypes.c_bool
        d.SteamAPI_ISteamUtils_GetAPICallFailureReason.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        d.SteamAPI_ISteamUtils_GetAPICallFailureReason.restype = ctypes.c_int
        d.SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint32]
        d.SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest.restype = ctypes.c_uint64
        d.SteamAPI_ISteamUGC_SetLanguage.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        d.SteamAPI_ISteamUGC_SetLanguage.restype = ctypes.c_bool
        for name in ("SetReturnLongDescription", "SetAllowCachedResponse"):
            fn = getattr(d, "SteamAPI_ISteamUGC_" + name)
            fn.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32 if name == "SetAllowCachedResponse" else ctypes.c_bool]
            fn.restype = ctypes.c_bool
        d.SteamAPI_ISteamUGC_SendQueryUGCRequest.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        d.SteamAPI_ISteamUGC_SendQueryUGCRequest.restype = ctypes.c_uint64
        d.SteamAPI_ISteamUGC_GetQueryUGCResult.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32, ctypes.c_void_p]
        d.SteamAPI_ISteamUGC_GetQueryUGCResult.restype = ctypes.c_bool
        d.SteamAPI_ISteamUGC_ReleaseQueryUGCRequest.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        d.SteamAPI_ISteamUGC_ReleaseQueryUGCRequest.restype = ctypes.c_bool
        d.SteamAPI_ISteamUGC_SetReturnAdditionalPreviews.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_bool]
        d.SteamAPI_ISteamUGC_SetReturnAdditionalPreviews.restype = ctypes.c_bool
        d.SteamAPI_ISteamUGC_GetQueryUGCNumAdditionalPreviews.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32]
        d.SteamAPI_ISteamUGC_GetQueryUGCNumAdditionalPreviews.restype = ctypes.c_uint32
        d.SteamAPI_ISteamUGC_GetQueryUGCAdditionalPreview.argtypes = [
            ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32, ctypes.c_uint32,
            ctypes.c_char_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_int)]
        d.SteamAPI_ISteamUGC_GetQueryUGCAdditionalPreview.restype = ctypes.c_bool
        d.SteamAPI_ISteamUGC_AddItemPreviewFile.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_int]
        d.SteamAPI_ISteamUGC_AddItemPreviewFile.restype = ctypes.c_bool
        d.SteamAPI_ISteamUGC_UpdateItemPreviewFile.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32, ctypes.c_char_p]
        d.SteamAPI_ISteamUGC_UpdateItemPreviewFile.restype = ctypes.c_bool
        d.SteamAPI_ISteamUGC_RemoveItemPreview.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32]
        d.SteamAPI_ISteamUGC_RemoveItemPreview.restype = ctypes.c_bool
        d.SteamAPI_ManualDispatch_Init()
        msg = ctypes.create_string_buffer(1024)
        rc = d.SteamAPI_InitFlat(msg)
        if rc != 0:
            os.chdir(self.prev_cwd)
            raise RuntimeError(f"SteamAPI_InitFlat 失敗（{rc}）：{msg.value.decode('utf-8', 'replace')}")
        self.user = d.SteamAPI_SteamUser_v023()
        self.ugc = d.SteamAPI_SteamUGC_v021()
        self.utils = d.SteamAPI_SteamUtils_v010()
        self.pipe = d.SteamAPI_GetHSteamPipe()

    def logged_on(self):
        return bool(self.dll.SteamAPI_ISteamUser_BLoggedOn(self.user))

    def steamid(self):
        return int(self.dll.SteamAPI_ISteamUser_GetSteamID(self.user))

    def close(self):
        self.dll.SteamAPI_Shutdown()
        os.chdir(self.prev_cwd)

    def _wait(self, call, callback_id, size, on_tick=None):
        """輪詢 call result；回傳原始 callback bytes。"""
        d = self.dll
        failed = ctypes.c_bool(False)
        deadline = time.time() + 3600
        while time.time() < deadline:
            d.SteamAPI_ManualDispatch_RunFrame(self.pipe)
            if d.SteamAPI_ISteamUtils_IsAPICallCompleted(self.utils, call, ctypes.byref(failed)):
                if failed.value:
                    raise RuntimeError(f"Steam 呼叫失敗：reason {d.SteamAPI_ISteamUtils_GetAPICallFailureReason(self.utils, call)}")
                result = ctypes.create_string_buffer(size)
                if not d.SteamAPI_ISteamUtils_GetAPICallResult(self.utils, call, result, size, callback_id, ctypes.byref(failed)) or failed.value:
                    raise RuntimeError("GetAPICallResult 失敗")
                return result.raw
            if on_tick:
                on_tick()
            time.sleep(0.5)
        raise RuntimeError("等待 Steam 回應超時")

    def submit(self, app_id, file_id, language, title=None, description=None, content=None, preview=None, changenote="",
               screenshots=None):
        """一次 ISteamUGC 更新（一個語言槽）。回傳 EResult；1 = OK。

        screenshots：附加預覽圖操作清單，元素為 ("add", path) / ("update", index, path) / ("remove", index)。
        """
        d = self.dll
        handle = d.SteamAPI_ISteamUGC_StartItemUpdate(self.ugc, app_id, int(file_id))
        if handle in INVALID_HANDLE:
            raise RuntimeError("StartItemUpdate 失敗")
        if not d.SteamAPI_ISteamUGC_SetItemUpdateLanguage(self.ugc, handle, language.encode()):
            raise RuntimeError(f"SetItemUpdateLanguage 拒絕 {language}")
        if title is not None and not d.SteamAPI_ISteamUGC_SetItemTitle(self.ugc, handle, title.encode("utf-8")):
            raise RuntimeError("SetItemTitle 拒絕（超過 128 bytes？）")
        if description is not None and not d.SteamAPI_ISteamUGC_SetItemDescription(self.ugc, handle, description.encode("utf-8")):
            raise RuntimeError("SetItemDescription 拒絕（超過長度上限？）")
        if content and not d.SteamAPI_ISteamUGC_SetItemContent(self.ugc, handle, content.encode("utf-8")):
            raise RuntimeError("SetItemContent 拒絕")
        if preview and not d.SteamAPI_ISteamUGC_SetItemPreview(self.ugc, handle, preview.encode("utf-8")):
            raise RuntimeError("SetItemPreview 拒絕")
        for op in screenshots or ():
            if op[0] == "add":
                ok = d.SteamAPI_ISteamUGC_AddItemPreviewFile(self.ugc, handle, op[1].encode("utf-8"), 0)  # k_EItemPreviewType_Image
            elif op[0] == "update":
                ok = d.SteamAPI_ISteamUGC_UpdateItemPreviewFile(self.ugc, handle, op[1], op[2].encode("utf-8"))
            else:
                ok = d.SteamAPI_ISteamUGC_RemoveItemPreview(self.ugc, handle, op[1])
            if not ok:
                raise RuntimeError(f"預覽圖操作被拒絕：{op}")
        call = d.SteamAPI_ISteamUGC_SubmitItemUpdate(self.ugc, handle, changenote.encode("utf-8"))
        if call == 0:
            raise RuntimeError("SubmitItemUpdate 回傳無效呼叫（k_uAPICallInvalid）")
        processed, total = ctypes.c_uint64(0), ctypes.c_uint64(0)
        seen = set()

        def progress():
            status = d.SteamAPI_ISteamUGC_GetItemUpdateProgress(self.ugc, handle, ctypes.byref(processed), ctypes.byref(total))
            if content and status in UPDATE_STATUS and status not in seen:
                seen.add(status)
                print(f"  … {UPDATE_STATUS[status]}")

        # SubmitItemUpdateResult_t：EResult(4) + bool；官方 k_iSteamUGCCallbacks(3400)+4
        raw = self._wait(call, 3404, 8, progress)
        eresult = int.from_bytes(raw[:4], "little", signed=True)
        if raw[4]:
            raise RuntimeError("Steam 要求先接受 Workshop 法律協議（作品在接受前不會公開），請到 Steam 網頁接受後重跑")
        return eresult

    def query_description(self, file_id, language):
        """向 Steam 取回指定語言槽目前的標題與簡介（不走網頁、不吃快取）。"""
        d = self.dll
        ids = (ctypes.c_uint64 * 1)(int(file_id))
        handle = d.SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest(self.ugc, ids, 1)
        if handle in INVALID_HANDLE:
            raise RuntimeError("CreateQueryUGCDetailsRequest 失敗")
        try:
            d.SteamAPI_ISteamUGC_SetLanguage(self.ugc, handle, language.encode())
            d.SteamAPI_ISteamUGC_SetReturnLongDescription(self.ugc, handle, True)
            d.SteamAPI_ISteamUGC_SetAllowCachedResponse(self.ugc, handle, 0)
            # SteamUGCQueryCompleted_t：handle(8) EResult(4) num(4) total(4) cached(1) cursor[256] → 280（pack 8）
            raw = self._wait(d.SteamAPI_ISteamUGC_SendQueryUGCRequest(self.ugc, handle), 3401, 280)
            eresult = int.from_bytes(raw[8:12], "little", signed=True)
            if eresult != 1:
                raise RuntimeError(f"查詢失敗 EResult={eresult}")
            # SteamUGCDetails_t 前段固定：id(8) EResult(4) type(4) creator(4) consumer(4) title[129] description[8000]
            details = ctypes.create_string_buffer(16384)
            if not d.SteamAPI_ISteamUGC_GetQueryUGCResult(self.ugc, handle, 0, details):
                raise RuntimeError("GetQueryUGCResult 失敗")
            title = details.raw[24:153].split(b"\0", 1)[0].decode("utf-8", "replace")
            description = details.raw[153:8153].split(b"\0", 1)[0].decode("utf-8", "replace")
            return title, description
        finally:
            d.SteamAPI_ISteamUGC_ReleaseQueryUGCRequest(self.ugc, handle)


    def query_screenshots(self, file_id):
        """回傳 Steam 上附加預覽圖（只算靜態圖片）的 [(index, 原始檔名)]，依 Steam 顯示順序。"""
        d = self.dll
        ids = (ctypes.c_uint64 * 1)(int(file_id))
        handle = d.SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest(self.ugc, ids, 1)
        if handle in INVALID_HANDLE:
            raise RuntimeError("CreateQueryUGCDetailsRequest 失敗")
        try:
            d.SteamAPI_ISteamUGC_SetReturnAdditionalPreviews(self.ugc, handle, True)
            d.SteamAPI_ISteamUGC_SetAllowCachedResponse(self.ugc, handle, 0)
            raw = self._wait(d.SteamAPI_ISteamUGC_SendQueryUGCRequest(self.ugc, handle), 3401, 280)
            eresult = int.from_bytes(raw[8:12], "little", signed=True)
            if eresult != 1:
                raise RuntimeError(f"查詢失敗 EResult={eresult}")
            found = []
            for i in range(d.SteamAPI_ISteamUGC_GetQueryUGCNumAdditionalPreviews(self.ugc, handle, 0)):
                url, name, kind = ctypes.create_string_buffer(1024), ctypes.create_string_buffer(260), ctypes.c_int(-1)
                if not d.SteamAPI_ISteamUGC_GetQueryUGCAdditionalPreview(self.ugc, handle, 0, i, url, 1024, name, 260, ctypes.byref(kind)):
                    raise RuntimeError(f"GetQueryUGCAdditionalPreview({i}) 失敗")
                if kind.value == 0:  # k_EItemPreviewType_Image；YouTube／Sketchfab 不動
                    found.append((i, name.value.decode("utf-8", "replace")))
            return found
        finally:
            d.SteamAPI_ISteamUGC_ReleaseQueryUGCRequest(self.ugc, handle)


# ---- 登入 ----
def connect(interactive, cfg):
    """回傳已登入且帳號相符的 Steam；未登入時互動模式引導登入，否則 exit 3。"""
    owner = str(cfg["owner_steamid64"])
    while True:
        try:
            steam = Steam(cfg["app_id"])
            if steam.logged_on():
                sid = str(steam.steamid())
                if sid != owner:
                    steam.close()
                    die(3, f"Steam 目前登入的帳號 {sid} 不是作品擁有者 {owner}，請切換帳號後重試")
                print(f"[OK] Steam 已登入，帳號 {sid}")
                return steam
            steam.close()
            problem = "Steam 用戶端已開啟但尚未登入"
        except (RuntimeError, OSError, AttributeError) as err:  # DLL 缺／載入失敗／匯出缺／Init 失敗
            problem = str(err)
        if not interactive:
            die(3, f"{problem}。請先開啟 Steam 並登入作者帳號，再重新執行")
        print(f"[!] {problem}")
        if os.name == "nt":
            os.startfile("steam://open/main")  # 喚起 Steam 登入視窗
        answer = ask("請在 Steam 完成登入後按 Enter 重試，輸入 q 放棄：").lower()
        if answer == "q":
            die(3, "使用者放棄登入")


# ---- 前置檢查 ----
def check_content(cfg):
    content = repo_path(os.path.join(cfg["workshop_root"], "Contents"))
    if not os.path.isdir(os.path.join(content, "mods")):
        die(4, f"內容目錄不存在或缺 mods/：{content}")
    version = mod_version(repo_path(cfg["mod_info"]))
    changelog = repo_path(cfg["changelog"])
    if not os.path.isfile(changelog):
        die(4, f"找不到更新說明 {changelog}；先執行 gen_steam_changelog.py {version} 產生")
    notes = read_text(changelog)
    if not notes.strip() or version not in notes.splitlines()[0]:
        die(4, f"更新說明為空或第一行不含 mod.info 版本 {version}；先執行 gen_steam_changelog.py {version}")
    gate = subprocess.run([sys.executable, "-B", os.path.join(REPO, "scripts", "verify_mod.py")],
                          cwd=REPO, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if gate.returncode != 0:
        print(gate.stdout[-2000:])
        die(4, "scripts/verify_mod.py 未通過，停止發布")
    print(f"[OK] verify_mod.py 通過；版本 {version}")
    return content, notes, version


def check_preview(cfg):
    if not cfg["preview_gif"]:
        die(4, "此 MOD 尚未提供 GIF 封面（workshop_publish.json 的 preview_gif 為 null）；先放好 GIF 再更新封面")
    gif = repo_path(cfg["preview_gif"])
    if not os.path.isfile(gif):
        die(4, f"找不到 GIF 封面：{gif}")
    with open(gif, "rb") as fh:
        magic = fh.read(4)
    size = os.path.getsize(gif)
    if magic != b"GIF8":
        die(4, f"封面不是 GIF：{gif}")
    if size > 1024000:
        die(4, f"封面 {size} bytes 超過 Steam 上限 1,024,000")
    print(f"[OK] GIF 封面 {size} bytes")
    return gif


def check_descriptions(cfg):
    texts = {}
    for lang, rel in cfg["descriptions"].items():
        if lang not in LANG_NAMES:
            die(4, f"不支援的語言代碼 {lang}（可用：{', '.join(LANG_NAMES)}）")
        text = read_text(repo_path(rel))
        if len(text.encode("utf-8")) > 8000:
            die(4, f"{rel} 超過 8000 bytes")
        texts[lang] = text
    if "english" not in texts:
        die(4, "descriptions 必須包含 english（Steam 主／預設語言槽）")
    print(f"[OK] 簡介 {len(texts)} 語：" + "、".join(LANG_NAMES[l] for l in texts))
    return texts


def check_titles(cfg):
    titles = {}
    for lang, title in cfg["titles"].items():
        if lang not in LANG_NAMES:
            die(4, f"titles 有不支援的語言代碼 {lang}（可用：{', '.join(LANG_NAMES)}）")
        title = title.strip()
        if not title or len(title.encode("utf-8")) > 128:
            die(4, f"{LANG_NAMES[lang]}標題為空或超過 128 bytes：{title!r}")
        titles[lang] = title
    if titles:
        print(f"[OK] 標題 {len(titles)} 語：" + "、".join(LANG_NAMES[l] for l in titles))
    return titles


def check_screenshots():
    """本機 docs/screenshots/steam/{en,zh}/*.jpg 依語系再檔名排序；回傳 [絕對路徑]。"""
    shots = []
    for lang in SCREENSHOT_LANGS:
        folder = repo_path(os.path.join(SCREENSHOT_DIR, lang))
        shots += [os.path.join(folder, n) for n in sorted(os.listdir(folder)) if n.lower().endswith(".jpg")] if os.path.isdir(folder) else []
    if not shots:
        die(4, f"{SCREENSHOT_DIR} 下沒有任何 JPG")
    names = [os.path.basename(p) for p in shots]
    if len(set(names)) != len(names):
        die(4, "預覽圖檔名跨語系重複（Steam 只記裸檔名，無法區分）：" + "、".join(sorted({n for n in names if names.count(n) > 1})))
    for path in shots:
        if os.path.getsize(path) > SCREENSHOT_MAX_BYTES:
            die(4, f"{os.path.relpath(path, REPO)} 超過 {SCREENSHOT_MAX_BYTES:,} bytes（Steamworks AddItemPreviewFile 會回 LimitExceeded）")
    print(f"[OK] 預覽圖 {len(shots)} 張：" + "、".join(names))
    return shots


def screenshot_ops(remote, local, force=False):
    """把 Steam 現況（[(index, 檔名)]）差分到本機順序（[路徑]）：同位置換檔、尾端追加、多餘移除（先高後低）。
    Steam 只記檔名，換了內容但檔名沒變要用 force 全部重傳。"""
    ops = []
    for k, path in enumerate(local):
        if k < len(remote):
            if force or remote[k][1] != os.path.basename(path):
                ops.append(("update", remote[k][0], path))
        else:
            ops.append(("add", path))
    ops += [("remove", idx) for idx, _ in reversed(remote[len(local):])]
    return ops

# ---- 線上驗證 ----
def http_get(url, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", **(headers or {})})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.headers.get("Content-Type", ""), resp.read()


def file_details(file_id):
    data = urllib.parse.urlencode({"itemcount": 1, "publishedfileids[0]": file_id}).encode()
    req = urllib.request.Request("https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/", data=data)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)["response"]["publishedfiledetails"][0]


def verify(steam, cfg, want, texts, titles, started, shots=()):
    """提交後對 Steam 回查：內容／封面看 Web API，簡介逐語言以 ISteamUGC 查詢比對。回傳問題清單。"""
    problems = []
    if "content" in want or "preview" in want:
        details = None
        for attempt in range(6):  # Web API 可能延遲反映，最多等約 60 秒
            details = file_details(cfg["published_file_id"])
            if "content" not in want or int(details.get("time_updated", 0)) >= started - 120:
                break
            time.sleep(10)
        if "content" in want:
            if int(details.get("time_updated", 0)) < started - 120:
                problems.append(f"Steam 回報 time_updated={details.get('time_updated')} 仍早於本次提交（可能只是延遲，請稍後到作品頁確認）")
            else:
                print(f"[OK] Steam time_updated 已更新（file_size={details.get('file_size')}）")
        if "preview" in want:
            ctype, body = http_get(details["preview_url"])
            if "gif" in ctype and body[:4] == b"GIF8":
                print("[OK] 線上封面為 GIF")
            else:
                problems.append(f"線上封面不是 GIF（Content-Type {ctype}）")
    if "screenshots" in want:
        remote = [n for _, n in steam.query_screenshots(cfg["published_file_id"])]
        local = [os.path.basename(p) for p in shots]
        if remote != local:
            problems.append(f"線上預覽圖順序與本機不一致：Steam {remote}／本機 {local}")
        else:
            print(f"[OK] 線上預覽圖 {len(remote)} 張，順序與本機一致")
    for lang in dict.fromkeys([*titles, *texts]):
        remote_title, remote = steam.query_description(cfg["published_file_id"], lang)
        if lang in titles:
            if remote_title.strip() != titles[lang]:
                problems.append(f"{LANG_NAMES[lang]}標題與本機不一致：Steam「{remote_title}」／本機「{titles[lang]}」")
            else:
                print(f"[OK] {LANG_NAMES[lang]}標題與本機一致")
        if lang not in texts:
            continue
        local = texts[lang]
        if remote.strip() != local.strip():
            i = next((k for k, (a, b) in enumerate(zip(remote, local)) if a != b), min(len(remote), len(local)))
            problems.append(f"{LANG_NAMES[lang]}簡介與本機不一致，位置 {i}：Steam「{remote[i:i+40]}」／本機「{local[i:i+40]}」")
        else:
            print(f"[OK] {LANG_NAMES[lang]}簡介與本機一致（{len(remote)} 字）")
    return problems


# ---- 主流程 ----
def choose_mode():
    print("\n要上傳什麼？\n  [1] 只更新 MOD 內容（含更新說明）\n  [2] 只更新 GIF 封面\n  [3] 只更新簡介（英／繁／簡／日）\n  [4] 只同步介面預覽圖（英先中後）\n  [5] 全部更新\n  [0] 離開")
    picks = {"1": "content", "2": "preview", "3": "description", "4": "screenshots", "5": "all"}
    while True:
        answer = ask("選擇：")
        if answer == "0":
            sys.exit(0)
        if answer in picks:
            return picks[answer]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=MODES, help="不給則顯示互動選單")
    parser.add_argument("--yes", action="store_true", help="不再詢問確認（AI／自動化必填）")
    parser.add_argument("--force", action="store_true", help="screenshots：檔名相同也重傳（內容有改時用）")
    parser.add_argument("--dry-run", action="store_true", help="只做登入與前置檢查、顯示計畫，不提交")
    parser.add_argument("--config", default=os.path.join(REPO, "scripts", "workshop_publish.json"))
    args = parser.parse_args()
    interactive = args.mode is None and sys.stdin.isatty()
    cfg = load_config(args.config)

    if not interactive and args.mode is None:
        die(2, "非互動環境請指定 --mode content|preview|description|screenshots|all")
    steam = connect(interactive, cfg)
    try:
        mode = args.mode or choose_mode()
        want = {"content", "preview", "description", "screenshots"} if mode == "all" else {mode}
        if mode == "all" and not cfg["preview_gif"]:
            print("[SKIP] 未設定 GIF 封面（preview_gif 為 null），本次不更新封面")
            want.discard("preview")
        if mode == "all" and not os.path.isdir(repo_path(SCREENSHOT_DIR)):
            print(f"[SKIP] 沒有 {SCREENSHOT_DIR}/，本次不同步預覽圖")
            want.discard("screenshots")
        content = notes = gif = None
        texts, titles = {}, {}
        shots, shot_ops = [], []
        if "content" in want:
            content, notes, _ = check_content(cfg)
        if "preview" in want:
            gif = check_preview(cfg)
        if "description" in want:
            texts = check_descriptions(cfg)
            titles = check_titles(cfg)
        if "screenshots" in want:
            shots = check_screenshots()
            shot_ops = screenshot_ops(steam.query_screenshots(cfg["published_file_id"]), shots, args.force)
        print(f"\n計畫：Workshop {cfg['published_file_id']}（app {cfg['app_id']}）")
        if content:
            print(f"  內容：{content}\n  更新說明：{notes.splitlines()[0]}")
        if gif:
            print(f"  封面：{gif}")
        for lang, rel in cfg["descriptions"].items():
            if lang in texts:
                print(f"  簡介 {LANG_NAMES[lang]}：{rel}")
        for lang, title in titles.items():
            print(f"  標題 {LANG_NAMES[lang]}：{title}")
        for op in shot_ops:
            print("  預覽圖 " + {"add": "追加", "update": "替換 #{}", "remove": "移除 #{}"}[op[0]].format(op[1]) + (f"：{os.path.basename(op[-1])}" if op[0] != "remove" else ""))
        if "screenshots" in want and not shot_ops:
            print("  預覽圖：Steam 已與本機一致，不重傳")
        if args.dry_run:
            print("\n[DRY-RUN] 未提交任何更新")
            return
        if not args.yes:
            if not interactive:
                die(2, "非互動模式需加 --yes 才會提交")
            if ask("\n確定提交？(y/N)：").lower() != "y":
                die(2, "使用者取消")

        started = int(time.time())
        # 英文那次一併帶內容／封面／更新說明；其餘語言只寫標題／簡介
        order = ["english"] + [l for l in dict.fromkeys([*texts, *titles]) if l != "english"]
        if "description" not in want:
            order = ["english"]
        if want == {"screenshots"}:
            order = []  # 預覽圖操作獨立提交（見下）
        done = []
        for lang in order:
            desc = texts.get(lang) if "description" in want else None
            title = titles.get(lang) if "description" in want else None
            first = lang == "english"
            try:
                rc = steam.submit(cfg["app_id"], cfg["published_file_id"], lang,
                                  title=title,
                                  description=desc,
                                  content=content if first else None,
                                  preview=gif if first else None,
                                  changenote=notes if (first and content) else "")
            except RuntimeError as err:
                rc = str(err)
            if rc != 1:
                already = f"；先前已成功：{'、'.join(done)}" if done else ""
                die(5, f"{LANG_NAMES[lang]}槽提交失敗（{rc if isinstance(rc, str) else 'EResult=' + str(rc)}）{already}")
            included = [x for x, on in (("內容", first and content), ("封面", first and gif), ("標題", title is not None), ("簡介", desc is not None)) if on]
            done.append(f"{LANG_NAMES[lang]}槽：{'／'.join(included)}")
            print(f"[OK] 已提交（{done[-1]}）")
        # 預覽圖一次提交只能帶一張（多張同批實測 EResult 25），逐張獨立提交；remove 已排在最後且先高後低
        for k, op in enumerate(shot_ops):
            rc = steam.submit(cfg["app_id"], cfg["published_file_id"], "english", screenshots=[op])
            if rc != 1:
                die(5, f"預覽圖操作 {op} 失敗（EResult={rc}）；先前 {k} 個操作已生效，重跑可續傳")
            print(f"[OK] 預覽圖 {op[0]} 完成（{k + 1}/{len(shot_ops)}）")

        print("\n線上驗證…")
        time.sleep(5)  # 給 Steam 生成縮圖
        try:
            problems = verify(steam, cfg, want, texts, titles, started, shots)
        except Exception as err:  # 提交已成功；回查本身失敗要講清楚，不能像沒上傳
            problems = [f"提交已成功，但回查 Steam 時失敗：{err!r}。請到作品頁人工確認"]
    finally:
        steam.close()
    for p in problems:
        print(f"[FAIL] {p}")
    if problems:
        sys.exit(6)
    print(f"\n完成：https://steamcommunity.com/sharedfiles/filedetails/?id={cfg['published_file_id']}")


if __name__ == "__main__":
    main()
