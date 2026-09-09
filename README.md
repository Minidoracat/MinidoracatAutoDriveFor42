# Minidoracat MiniMap - AutoDrive for B42

道具驅動的車輛導航與自動駕駛：GPS 導航儀規劃路線，自駕模組沿路網自動行駛

Project Zomboid Build 42 MOD。

## 目前功能

- 兩件分級道具：GPS 導航儀與自動駕駛模組，可從電子／軍用物資取得或以電子技能合成；兩件道具的「允許合成」與「世界搜刮生成」各有獨立沙盒開關
- 電子導航維修手冊：閱讀一本即可學會 GPS 與自駕模組兩份配方；實際製作仍需電工 3／6 級。手冊只會出現在尚未生成戰利品的電子、電腦書籍、圖書館與雜誌容器，既有容器不會回填
- 三條學習路徑互補：GPS 可在電工 3 級研究自身配方；自駕模組可在電工 3 級研究 GPS、電工 6 級再研究自駕配方，且研究不消耗成品；電工 6／8 級則自動學會。多人既有高技能角色登入時由伺服器補學
- GPS 導航需求可由沙盒開關；缺少帶電導航儀時，主 MOD 的導航路線與目標會被鎖定並顯示提示
- 使用螺絲起子在車輛電瓶艙安裝／卸載裝置；單人與多人共用伺服器權威驗證
- 安裝狀態隨車保存；GPS 卸下時保留原有電量
- 車輛 radial 選單可啟停自駕；導航 API v4 的 20–90° 可行折點會在道路寬度內轉成平滑圓角（底層圓弧相切，行駛折線以最長 1 公尺、切線誤差不超過 2° 取樣；塞不進路面帶時保留折點爬行）。前方彎道只以 coast 包絡預降，正常彎道不以完整煞停代替減速
- 駕駛 HUD 與原版車輛儀表可見邊緣融合，金屬主題沿用原版 #343434 面板與斜角樣式；顯示狀態、車速、巡航上限、檔位、減速政策與電油量，可直接啟停與切檔。滑鼠停在殭屍／屍體政策上會顯示判定範圍、分級限速、非障礙物行為與伺服器鎖定狀態；原版儀表內建收放鈕與 M/S 主題切換鈕，另有簡約／精簡／收合模式。HUD 使用與原版儀表相同的一般 UI 層，設定與管理視窗會正常顯示在其上方
- **速度檔位與 MAX 積極模式**：HUD 的 30／50／70 km/h 採舒適策略，MAX 採積極策略（較快過彎與繞行、較晚收油），巡航上限仍由車輛與沙盒設定共同限制；沙盒預設上限為 120 km/h，既有存檔設定不覆寫。切檔會更新限速表，不更換導航路線；正在脫困或手動讓位時，策略於回到跟線後套用。沒有獨立風格選項，MAX 按鈕與收合檔位按鈕的提示會說明差異；感知、路面與碰撞安全判定仍生效
- **行車時間**：與「巡航上限」採同構欄位；完整展開為標籤上、數值下，精簡模式同列對齊，收合保留裸時間。以現實秒數計算本趟自駕，包含途中停等、脫困與手動操作待命；關閉、抵達停妥或返回主選單時凍結末趟時間，下一次成功啟動才歸零。每個本機玩家槽各自計算，僅保留於目前 Lua 執行期間，不寫入存檔，也不需要開啟診斷。未滿一小時顯示 `MM:SS`，之後為 `H:MM:SS`，超過 99:59:59 顯示 `100h+`；極窄畫面優先保留操作按鈕
- 可從 ESC 的 MOD Options 或支援 client-settings API v1 的 MiniMap 齒輪「自動駕駛」分類開關，並選擇 1／3／7 像素的細／標準／粗單線；三檔每段都只呼叫一次 client renderer，粗線只增加少量客戶端像素填充，完全不使用伺服器資源。舊版 MiniMap 不顯示齒輪分類，ESC 選項仍可用。紅色障礙圈、路面帶等診斷標記仍只在 DebugOverlay 顯示
- **開發用診斷紀錄（預設關閉）**：可在 MOD Options／新版 MiniMap「自動駕駛」分類選擇匯出本機診斷紀錄，設定從下一段自駕生效。紀錄只寫在這台電腦，含世界座標、時間戳記、啟用 MOD 與車輛物理狀態；採固定 64 個紀錄槽、每槽最多 2MiB。單槽寫滿後接續下一槽，同趟各段可由 `session-index.txt` 的 `drive`／`part` 對應；保留期限可選 1／3／7／14／30 天。回報問題請附整個紀錄資料夾，不只最後一段。複製路徑優先顯示家族共用 Toast，舊版框架或 Toast 失敗則改用頭上提示；更舊版 MiniMap 仍可用 ESC 選項
- **靠右行駛**：沿路線右車道行駛（偏移量沙盒可調 0-2 公尺，0＝關閉），會車時雙方自然錯開；繞行時從右車道平滑切換到繞行線再回來
- 轉向採作用於車身前方的側向衝量，量級隨車重與車速縮放；原地調頭使用力偶。實際循跡仍受車況、路面與物理滑移影響
- 玩家碰方向盤、油門或煞車時預設立即關閉自駕並交還控制；只有在「手動介入後」選了 2／3／5／10 秒，才會在放手後倒數恢復，期間計時繼續。恢復時仍依車速與方向處理，不與玩家搶控制
- 自駕以單一 2.5 秒進度監督取代舊的低速／高速兩套卡住判定：車體世界位移、沿線前進或原地轉向任一有進度就重臂；高檔空轉會先短暫關閉定速器讓變速箱回低檔，仍無進度才在確認後方 4 公尺淨空後倒車。倒車期間每 100ms 重查後方，未知區域、牆或車輛都會立即停止，不盲退
- 車輛 script 若缺少可信的車身尺寸或重心資料，會拒絕啟動並明確提示，而不是套用猜測尺寸繼續控制
- 走廊感知：可在 ESC MOD Options 或 MiniMap 齒輪選擇 48／80／120／160／200 公尺的基礎距離，預設 120。車速、障礙與彎道可提出額外延伸（總上限 240），但每幀查詢額度固定，實際範圍仍受幀率與已載入世界限制；HUD 減速按鈕說明顯示實際距離。未掃與未載入都不是淨空，新設定於下一輪生效，不重設路線
- 繞行：規劃、掃掠、跟隨與繪圖共用同一條世界座標線；一般繞行與貼縫皆沿線的切線修正姿態。MAX 在新鮮完整的世界證據與對線條件成立時，依各段實際曲率、淨距及側移需求分段限速，不讓遠處短入口／出口綁住整段寬敞路徑；不放寬接觸與未知區域防線
- 堵死處理鏈：目前車身碰撞守門或規劃堵死先煞停；脫困前檢查後方，成功倒退 3 公尺後先煞到低於 1 km/h 才重新掃描並前進。失敗縫的 episode ban 會跨同目標改道保留，前進至少 10 公尺且連續兩輪車身淨空後才解除；相同目標最多嘗試三次，改真正目的地才立即重置
- 終點、彎道與未載入區域使用同一套車型／路況包絡；可視距離以二次式正根反解速度，速度命令再以 jerk 上限平滑。正常彎道與直線超速以 coast／jerk 收油；完整煞停保留給碰撞、堵住、抵達、不安全回線、脫困、無效動態狀態、高速調頭，以及當段圓角或可視距離硬包絡被突破
- 殭屍／屍體減速各有三態政策。行駛線左右各 3 公尺內，依最近目標距離漸進減速；接近時殭屍 1–3／4–7／8+ 隻分別採 35／25／15 km/h，屍體採 30 km/h。另有預設開啟的「避讓殭屍與屍體」，兩類一起找安全縫、不各自搶車道；軟避讓以 40 公尺或 3 秒行程中較大者作為輪首採集窗口，實際判斷不超過本輪已收範圍，遠處屍堆不占近端額度。各類減速策略關閉時，能閃就閃，不為了閃避而減速；開啟時才允許配合側移放慢。沒有安全縫時維持原路，不把屍體當牆；道路、車流與硬障礙安全限制仍有效
- GPS 與自駕各有獨立電量／燃油倍率（0–500%），同時使用時相加。電量負載與原版發電機充電並存；現行倍率範圍內，引擎正常運轉時電瓶仍淨充電，倍率反映在回充速度（熄火 GPS 則直接放電）。燃油 100% 時，GPS 導航中的車輛在原生實際油耗上加 5%、自駕加 25%（同時啟用共加 30%）。隨身 GPS 的電量只扣自身電池，但用它導航行駛時仍套用 GPS 油耗加成

## 截圖

### 繁體中文

| | |
|---|---|
| ![自動駕駛 HUD＋導航路線](docs/screenshots/zh/01-autodrive-hud-route.png) | ![路口跟線＋小地圖同步](docs/screenshots/zh/02-autodrive-route-intersection.png) |
| ![AutoDrive 沙盒設定](docs/screenshots/zh/03-autodrive-sandbox-settings.png) | ![GPS 導航儀與自動駕駛模組](docs/screenshots/zh/04-autodrive-items.png) |
| ![HUD 主題：金屬擬物](docs/screenshots/zh/05-hud-theme-metal.png) | ![HUD 主題：簡約玻璃](docs/screenshots/zh/06-hud-theme-glass.png) |
| ![HUD 主題：家族卡片](docs/screenshots/zh/07-hud-theme-family.png) | ![HUD 主題：側掛雙翼](docs/screenshots/zh/08-hud-theme-wings.png) |
| ![MiniMap 設定「自動駕駛」分類](docs/screenshots/zh/09-minimap-autodrive-settings.png) | |

### English

| | |
|---|---|
| ![Autodrive HUD with voice prompt tooltip](docs/screenshots/en/01-autodrive-hud-voice.png) | ![Wings HUD theme following a route through an intersection](docs/screenshots/en/02-hud-theme-wings-route.png) |
| ![AutoDrive sandbox options](docs/screenshots/en/03-autodrive-sandbox-settings-en.png) | ![MiniMap settings, Autodrive category](docs/screenshots/en/04-minimap-autodrive-settings.png) |

Steam Workshop 用 JPG（每張 ≤280,000 bytes，Steamworks 預覽圖上限）在 `docs/screenshots/steam/{zh,en}/`，編號與上表一致；`scripts/publish_workshop.py --mode screenshots` 同步到作品頁。

## 安裝

- Steam Workshop：[Minidoracat MiniMap - AutoDrive for B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3792675881)
- 手動安裝：把 `MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42` 複製到 `%USERPROFILE%\Zomboid\mods\` 並將資料夾改名為 `MinidoracatAutoDriveFor42`

本 addon 需要 [Minidoracat MiniMap for B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359)
與 Minidoracat UI for B42；不與 Navigator 共存（兩者都佔用車輛儀表上方）。

## 回報導航問題

自動駕駛走錯路、卡住、無故停下或交還操控，請開 GitHub Issue（New issue → 「導航問題回報」），表單會逐欄要求資料。關鍵是**整個 `Telemetry` 資料夾的 zip**——靠 `session-index.txt` 的時間戳與各段紀錄才定位得到出問題的那一段：

1. ESC → MOD 選項（或 MiniMap 齒輪 → 「自動駕駛」）勾選「匯出自動駕駛診斷紀錄」（預設關，下一段自動駕駛生效）
2. 重現問題
3. 同一頁按「複製紀錄資料夾路徑」→ 檔案總管網址列貼上 → Enter
4. 對 `Telemetry` 資料夾右鍵 → 壓縮成 ZIP（整個資料夾）
5. 把 zip 拖進表單的附件欄；只附 zip，不要貼路徑（含你的電腦帳號名稱）

紀錄含遊戲內絕對座標、原始 epoch 毫秒時間戳與啟用的 MOD 清單，沒有帳號／Steam ID／IP／伺服器名稱；公開 repo 的附件任何人都能下載，請自行斟酌。zip 超過 25 MB 時只附 `session-index.txt`、`latest.txt`、`manifest.txt` 與最後幾段 `session-NNN.log`。

English: open a GitHub issue with the "Navigation problem report" form and attach the whole `Telemetry` folder as a zip — the form lists the steps.

## 開發
- `link_workshop.bat`：把 repo 掛載到 `Zomboid\Workshop\` 與 `Zomboid\mods\`（符號連結，repo 改動即時生效）
- `PZ_Test.bat`：啟動測試（客戶端 / 專用伺服器 / 多客戶端組合）
- 診斷紀錄（需先在選項開啟）：本機 `Lua/MinidoracatAutoDrive/Telemetry`，每段自駕一個 `session-NNN.log`；管理檔為 `manifest.txt`、`latest.txt`、`session-index.txt`。後者固定最多 64 列，以 raw epoch ms 對應每段檔案；MiniMap v2 可複製最新檔或資料夾絕對路徑

## 版本

版本號格式：`{PZ 版本}-{mod 版本}`（例 `42.20.4-0.1.0`），詳見 [CHANGELOG.md](CHANGELOG.md)。

## ☕ 支持作者

MOD 永遠免費。喜歡的話可以請我喝杯咖啡，贊助會用在伺服器與 MOD 開發上。

[![Ko-fi](https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png)](https://ko-fi.com/minidoracat)

## 作者

Minidoracat — [Discord](https://discord.gg/Gur2V67) | [Twitch](https://www.twitch.tv/minidoracat)

### 發布到 Workshop

雙擊 `Publish_Workshop.bat`：先確認 Steam 用戶端已以作者帳號登入（未登入會喚起 Steam 並等你登入後重試），
再選擇更新 MOD 內容（含 `STEAM_CHANGELOG.md` 更新說明）／GIF 封面／簡介／全部；提交後回查 Steam，
任一不符即以非零碼結束。設定在 `scripts/workshop_publish.json`（Workshop ID、簡介語言槽來源、GIF 路徑）。

```
uv run --no-project python -B scripts/publish_workshop.py --mode all --yes       # 自動化／AI；或 content / preview / description
uv run --no-project python -B scripts/publish_workshop.py --mode all --dry-run   # 只檢查、顯示計畫
```

退出碼：`0` 成功／`2` 參數或取消／`3` 未登入、帳號不是擁有者／`4` 前置檢查失敗／`5` 提交失敗／`6` 已提交但回查不符。
網頁動態封面放 `MOD/<資料夾>/workshop/preview.gif`（不在 `Contents/`，不會下載給玩家）；遊戲內上傳器仍用 `preview.png`，
且每次會把網頁封面覆回靜態，需要動態封面時一律改用本工具發布。
