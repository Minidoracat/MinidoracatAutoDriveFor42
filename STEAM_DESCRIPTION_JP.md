[h1]🚗 Minidoracat MiniMap - AutoDrive for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ これは何？[/h2]
アイテム駆動の車両ナビゲーションと自動運転——GPSナビでルートを計画し、オートパイロットモジュールが道路網に沿って自動走行します

[h2]マップMODの対応条件：利用前に確認[/h2]
[b]購読だけで全道路がナビ・自動運転に対応するわけではありません。[/b]
[list]
[*] 追加・変更道路には作者か互換パッチ作者が維持する[b]streets.xml[/b]が必要です。現行の公式形式、実際の路面との一致、マップ内外の接続が条件です。
[*] プレイ可・地図画像・ファイルの存在だけでは道路データの完全性は保証されません。画像からの道路生成や欠落・位置ずれ・未接続の自動修復はしません。
[*] 特定マップの不調は両MODを更新し、作者に道路データを確認。下の道路報告にマップリンク・ナビ画像・座標テキストを添付。ログ不要。
[/list]

[h2]🚀 クイックスタート[/h2]
[olist]
[*] [b]GPSナビゲーター[/b]と[b]オートパイロットモジュール[/b]を入手（漁るか、電気 3／6 でクラフト）
[*] 車の横で[b]車両を右クリック[/b]→「オートパイロットモジュールを取り付ける」（ドライバー・車用バッテリー・電気1が必要）。GPSは取り付けず、電池入りで所持しても使えます
[*] ワールドマップを開いて目的地を選び、ルートを計画
[*] 運転席に座り、ダッシュボード上のパネルで[b]オートドライブを開始[/b]。ハンドルやアクセルに触れればいつでも手動に戻ります
[/olist]

[h2]🧰 主な機能[/h2]
[list]
[*] [b]GPSナビゲーター[/b]：入手・作成後、地図で目的地を選ぶと道路網に沿って経路を計画
[*] [b]オートパイロットモジュール[/b]：車両に取り付けると経路を自動走行、目的地で停車
[*] [b]運転HUD[/b]：状態・速度・巡航上限・ギア・減速理由・電力・燃料を表示。開始／停止、ギア、テーマ、表示、音声・音量を操作。メタル／ガラス／ファミリーカード／サイドウィングの4テーマ、縮小・折畳対応。ウィングは路面を隠さず左右別に折畳可
[*] [b]走行時間[/b]：待機・脱出を含む実時間。停止後は前回分を表示し、次の開始成功時にリセット。ゲーム中のみ保持、セーブには保存しません
[*] [b]速度ギアと積極的なMAX[/b]：30／50／70 km/hは快適走行。MAXはカーブや隙間を速めに走り、アクセルオフも遅め。HUDで直接切替え、別設定は不要。巡航上限は車両・サンドボックス設定に従い、車況・衝突防止の判定は維持
[*] [b]手動介入[/b]：ハンドル・アクセル・ブレーキで停止、目的地は保持しパネルから再開可。「手動介入後」で2／3／5／10秒を選ぶと、手を離した後にHUDのカウントダウンと通知を経て自動再開
[*] [b]Uターン[/b]：目的地が後方に変わると、既定の「穏やか」はほぼ停車してゆっくり旋回。「素早い」にすると勢いをつけて曲がります
[*] [b]右側通行と障害物回避[/b]：既定で右側を走り、対向車と自然にすれ違い。駐車車両や障害物の通過可能な隙間を探し、回避後は元の車線へ戻る
[*] [b]復旧と迂回[/b]：詰まると別の隙間や後退を試し、通れなければ停車・待機。HUD「迂回」で代替経路、設定で自動迂回も可能。未解決なら通知して操作を返します
[*] [b]音声案内[/b]：開始・停止・障害・後退・操作返還・到着・迂回結果・手動引き継ぎ／再開を自分だけに案内。中国語／英語／日本語をゲーム言語に合わせるか指定し、HUDでオン／オフ・音量を調整
[*] [b]シングルプレイの自動一時停止[/b]：脱出失敗時／到着・停車後の2設定（既定オン）。ESC MOD Options／MiniMapで個別に変更。自動運転終了→通知音声終了→一時停止（音声オフ・再生不可なら即停止）。待機中の手動運転・再開で取り消し、解除後も自動運転は停止状態。手動停止・一時的な通行待ち・マルチ／Host・画面分割は対象外。音声待機中は世界が動きます
[*] [b]減速と回避[/b]：カーブ・車流・未読込区間に応じて減速。ゾンビ／死体は安全な隙間を一緒に探し、通れない場合は元の車線と減速設定を維持
[*] [b]検知距離[/b]：48／80／120（既定）／160／200 m。速度・障害物・カーブで延長を要求しますが、処理予算と読込範囲を超えません
[*] [b]走行予定ライン[/b]：通常は半透明の青、確定した回避区間は黄。MOD Options／新版MiniMapで表示・太さを変更
[*] [b]入手方法[/b]：両デバイスはクラフト・探索で入手。GPS／自動運転別にクラフト・生成設定あり
[*] [b]電力・燃料コスト[/b]：GPS／自動運転別に消費電力と追加燃料を0～500%で設定でき、同時使用は加算。100%時の追加燃料消費はGPSナビ中5%、自動運転25%
[*] [b]レシピ習得[/b]：電子ナビゲーション整備マニュアル、完成品を消費しない研究（電気3：GPS自身／モジュールからGPS、電気6：モジュール自身）、電気6／8での自動習得。製作は電気3／6。マニュアルは未生成の電子機器・コンピューター書籍・図書館・雑誌コンテナに出現し、既存戦利品には追加しません
[/list]

[h2]⚠️ 前提MOD[/h2]
[list]
[*] 必須：[url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url]
[*] 必須UIフレームワーク：[url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library for B42[/url]
[*] Navigatorとは併用不可（どちらも車両ダッシュボード上部を使用します）
[/list]

[h2]🔗 MODシリーズ[/h2]
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url]（本体MOD、必須）
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Minidoracat MiniMap Zones[/url]
[/list]

[h2]📋 MOD情報[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatAutoDriveFor42
[*] [b]Workshop ID:[/b] 3792675881
[*] [b]対応バージョン:[/b] Build 42.20.4+
[*] [b]シングル / マルチ:[/b] 両対応
[/list]

[h2]💬 フィードバック[/h2]
[list]
[*] [url=https://discord.gg/Gur2V67]Discordコミュニティ[/url]
[*] [url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new?template=road-data.yml]道路・経路の報告[/url]：ずれ・欠落・遠回りは[b]経路と座標の画像＋座標テキスト[/b]、症状を一言。起終点・方向・マップ／版も推奨。[b]Telemetry不要。[/b]
[*] [url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new/choose]車両制御の報告[/url]：正しい経路から逸脱・詰まり・異常減速は診断出力をオンにし、Telemetry全体をZIPで添付。設定の報告ボタンでリンクをコピー。
[/list]

[h2]☕ 作者を応援[/h2]
常に無料、ソースはGitHubで公開。コーヒーのご支援はサーバーとMOD開発に使います。
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url] [url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_github.png[/img][/url]

[b]#Minidoracat[/b]
