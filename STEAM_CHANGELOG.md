[h1]Minidoracat MiniMap - AutoDrive for B42 42.21.0-0.35.2[/h1]
[i]2026-11-09[/i]

[b]English summary[/b]
[list]
[*] Fixed: autodrive now steers around thin posts and small objects that the game uses to stop cars dead (recycling bins, player-built wooden wall posts, some mod fence posts) instead of crashing into them and getting stuck.
[*] Fixed: while the driver aims or reloads a rifle or shotgun out of the window, autodrive's emergency braking now still stops the car in time (pistols were never affected).
[*] Changed: the Yui and Classic voices are now about as loud as Stacy.
[*] Changed: the side-wing HUD theme now also fits at the game's 33px and 38px font sizes (default on 2560×1600 and 4K screens) by drawing the wings' text one size smaller, instead of switching to the metal top layout.
[*] Fixed: the voice volume and zombie/corpse slowdown range tooltips now describe what the settings actually do.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] 資源回收桶、玩家蓋的木牆角柱、一些 MOD 的籬笆柱這類細柱子，一般車速撞不壞，單機時遊戲會把車直接擋停，自駕卻看不到，撞上就卡住，嚴重時車還會被彈開、扣車況。現在自駕會繞開它們；交通錐、紙箱這類一撞就飛的小物照舊直接開過。
[*] 開窗在車內舉著步槍或霰彈槍瞄準、或裝彈時，自駕的緊急煞車沒有作用、煞車燈也不亮，障礙突然出現在很近的地方時會撞上。現在改用另一種不鎖輪的煞法，照樣能在障礙前停住，也能照常轉向。拿手槍不受影響。
[*] 語音音量的說明寫錯：遊戲的音量設定其實管不到自駕語音，實際大小只看語音音量和系統音量。覺得太小，可以把遊戲的「音效音量」和「車輛引擎音量」調低。
[*] 殭屍與屍體減速的範圍說明寫錯：實際是從車前 2 公尺算到每位玩家的「基礎感知距離」（48～200 公尺，預設 120）。
[/list]

[h3]🎛️ HUD 與語音[/h3]
[list]
[*] Yui 的語音原本比 Stacy 小聲約 4 dB，經典（舊版語音）小聲約 2 dB，現在都調到和 Stacy 差不多大聲。
[*] 遊戲的「字體大小」是 33px 或 38px 時（2560×1600、4K 這類較高的螢幕預設就會用到），側掛雙翼以前排不下，會改用金屬上方版面，看起來像側翼被拿掉了。現在側翼的字會縮小一號排進儀表板旁，資訊一樣不少；畫面太窄真的排不下時，樣式按鈕的提示會寫出原因。
[/list]
