# Minidoracat MiniMap - AutoDrive for B42

道具驅動的車輛導航與自動駕駛：GPS 導航儀規劃路線，自駕模組沿路網自動行駛

Project Zomboid Build 42 MOD。

## 目前功能

- 兩件分級道具：GPS 導航儀與自動駕駛模組，可從電子／軍用物資取得或以電子技能合成
- GPS 導航需求可由沙盒開關；缺少帶電導航儀時，主 MOD 的導航路線與目標會被鎖定並顯示提示
- 使用螺絲起子在車輛電瓶艙安裝／卸載裝置；單人與多人共用伺服器權威驗證
- 安裝狀態隨車保存；GPS 卸下時保留原有電量
- 車輛 radial 選單可啟停自駕；沿導航路線分幀建立限速剖面，以前瞻 PID 跟線、彎道與航向未對正時先減速、目的地煞停
- 轉向採側向橫推車尾的衝量模型（量級隨車重與車速縮放），過彎帶輕微甩尾屬正常特性
- 玩家碰方向盤、油門或煞車時立即讓位；放手後連續 10 幀才恢復，避免人機搶控制
- 車輛卡住（撞上障礙物等）持續 5 秒會自動停止自駕並提示；M3 尚無避障與倒車脫困
- 耗電比例可由沙盒設為 0–500；自駕期間引擎運轉由發電機供電，電瓶失效會立即交還控制
- 目前開發階段為 M3（路線跟隨核心）；障礙物偵測／繞行與 GameProfiler 實測完成前不發布

## 安裝

- Steam Workshop：（首次上傳後補上連結）
- 手動安裝：把 `MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42` 複製到 `%USERPROFILE%\Zomboid\mods\` 並將資料夾改名為 `MinidoracatAutoDriveFor42`

本 addon 需要 [Minidoracat MiniMap for B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359)。

## 開發

- `link_workshop.bat`：把 repo 掛載到 `Zomboid\Workshop\` 與 `Zomboid\mods\`（符號連結，repo 改動即時生效）
- `PZ_Test.bat`：啟動測試（客戶端 / 專用伺服器 / 多客戶端組合）

## 版本

版本號格式：`{PZ 版本}-{mod 版本}`（例 `42.20.4-0.1.0`），詳見 [CHANGELOG.md](CHANGELOG.md)。

## 作者

Minidoracat — [Discord](https://discord.gg/Gur2V67) | [Twitch](https://www.twitch.tv/minidoracat)
