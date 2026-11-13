[h1]Minidoracat MiniMap - AutoDrive for B42 42.22.2-0.36.1[/h1]
[i]2026-11-14[/i]

[b]English summary[/b]
[list]
[*] Fixed: when catching up with a slower vehicle going the same way, autodrive could keep its speed and squeeze past right beside it (most visible while towing, because a towing vehicle drives along the middle of the road). It now slows down and follows unless the other vehicle is a full lane away.
[*] Fixed: when the vehicle ahead swerved aside for a few seconds (around a zombie or a parked car) and came back, autodrive sped up to pass during the swerve. It now keeps following for 6 seconds and only passes if the vehicle is still in the next lane after that.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] 追上同方向的慢車時沒有減速，貼著它從旁邊超過去：拖著車或掛車時自駕走道路中線，右車道上比較慢的車和自己只隔幾十公分，自駕卻照原速開到它旁邊。現在同方向的車只要和自己橫向相隔不到 1.5 公尺，自駕就減速跟在後面；隔一整條車道以上的車照舊可以超過。
[*] 前車繞開東西又切回來時，自駕會趁它偏開的那幾秒加速超過去，前車切回車道時兩台車差點擦到。現在前車偏開後自駕照樣跟 6 秒，這段時間內它切回來就接著跟；6 秒後它還在旁邊車道，才超過去。
[/list]
