[h1]Minidoracat MiniMap - AutoDrive for B42 42.22.2-0.38.0[/h1]
[i]2026-11-23[/i]

[b]English summary[/b]
[list]
[*] New: "Speed and distance units" in Mod Options (also on the Autodrive page of the MiniMap settings). Choose Imperial and the HUD shows speed, the cruise limit, the speed breakdown and the FSD card in mph, and the distance left in miles and feet. Gear buttons read 19 / 31 / 43 instead of 30 / 50 / 70. Display only: driving is unchanged. Thanks to Alpha Gamer for the suggestion.
[*] Fixed: vehicles whose braking force another mod sets to almost zero (for example tracked vehicles with their own parking brake) now stop with a message about the brakes instead of "incomplete body geometry data". These vehicles still cannot use Autodrive.
[*] Fixed: other stops caused by unreadable vehicle data no longer blame body geometry; the message now says the body or driving data could not be read.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] 速度和距離可以改用英里顯示：ESC 的 MOD 選項（或小地圖設定的「自動駕駛」頁）新增「速度與距離單位」，可選公制（預設）或英制。選英制後，HUD 的現在車速、巡航上限、速度明細、FSD 卡片改用 mph，剩餘路程改用英里和英尺；檔位按鈕從 30／50／70 變成 19／31／43。只改顯示，車怎麼開、速限多少都不變。感謝 Alpha Gamer 的建議。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] 煞車力被其他 MOD 改成幾乎零的車（例如自己接管駐車煞車的履帶車），停止原因不再寫成「車身幾何資料不完整」：改顯示煞車力讀數接近零，HUD 狀態列顯示「煞車異常停止」。這類車仍然不能自動駕駛，只是原因寫對了。感謝 四时白心c 回報。
[*] 其他讀不到車輛資料而停止的情形，原因也不再寫「車身幾何資料不完整」，改成「讀不到這輛車的車身或行駛資料」。
[*] 檔位名稱裡的速度會跟著單位選項換算；繁體與簡體中文原本寫「30 公里」，改成和 HUD 一樣的「30 km/h」。
[/list]
