[h1]Minidoracat MiniMap - AutoDrive for B42 42.22.2-0.38.2[/h1]
[i]2026-11-27[/i]

[b]English summary[/b]
[list]
[*] AutoDrive keeps further from street lights, trees and lamp posts on the outside of left curves, including S-bends, zombie dodges and the return to the lane after passing an obstacle.
[*] Fixed: in rare cases the check around the car before a U-turn could look at the wrong spot, and turning off "Show autodrive trajectory and navigation line" might not clear the line for every player.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]左彎外側的路燈、樹、燈柱更不容易擦到[/b]：0.37.0 起，自駕在左彎會離彎外的路邊物遠一點，但還有幾種情況會擦撞。
[list]
[*] 先右彎、緊接著左彎（S 彎）時，車會收得更靠內，避免出第一個彎時的擺動加上第二個彎的外甩一起把車帶到路邊。
[*] 在左彎閃殭屍時，不再為了閃殭屍把車推到彎外的樹或燈柱旁；閃不開時會照原本的規則直接撞過殭屍，不去擦路邊物。
[*] 繞過障礙物後回到車道的那一段，不再被拉長到彎外的路邊物旁邊。
[/list]
[*] [b]調頭前的周圍檢查與軌跡清除更可靠[/b]：少數情況下，調頭前檢查車子周圍有沒有東西時可能量錯位置；關掉選項「顯示自動駕駛軌跡與導航線」時，也可能沒把所有玩家的線清乾淨。兩者都已修正。
[/list]
