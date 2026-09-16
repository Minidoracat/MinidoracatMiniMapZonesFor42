[h1]🗺️ Minidoracat MiniMap Zones[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ 這是什麼[/h2]
[b]Minidoracat MiniMap for B42[/b] 主 MOD 的[b]伺服器自訂區域 addon[/b]：
在小地圖與世界地圖上疊加半透明填色區域＋框線＋名稱標籤。
[list]
[*] [b]伺服器自訂區域[/b]：伺服器端 `zones.json` 定義（可由外部程式寫入，例如活動範圍工具、重置區標記工具），伺服器驗證後即時廣播給所有玩家；單機直接讀取本地 `zones.json`
[*] [b]檔名改回 `zones.json`（0.3.0）[/b]：遊戲 42.20.0 曾把 `.json` 排除在 Lua 寫檔副檔名白名單之外（0.2.0 因此暫改 `zones.txt`），[b]42.20.1 已把 `.json` 加回[/b]，故正典檔改回 `zones.json`；0.2.0 的 `zones.txt` 首次啟動自動搬入 `zones.json`（一次性，覆寫前先備份為 `zones.premigrate.bak.json`），外部程式請改寫 `zones.json`。[b]本版需要遊戲 Build 42.20.1 以上[/b]
[/list]
[i]內建資源點（POI，原版地圖 14 類軍事／醫療／超市…）已於 0.8.0 內建於主 MOD 本體，裝主 MOD 即見，不再需要本 addon。[/i]

[h2]⚠️ 版本需求[/h2]
[b]需要主 MOD [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url] 42.19.0-0.8.0 以上版本[/b]（提供 Zone 圖層渲染 API 與設定頁動作列 API）。
主 MOD 版本過舊或未安裝時，本包安靜降級——不顯示任何區域，不影響主 MOD 其餘功能。
0.4.0 的類別篩選／暗色描邊／縮放 LOD [b]完整效果需主 MOD 42.20.1-0.14.0 以上[/b]；舊版主 MOD 下區域照常顯示，僅無新效果。

[h2]🧰 特色[/h2]
[list]
[*] [b]純地圖顯示[/b]：區域僅為地圖上的視覺標示，不含 PVP／安全區等任何遊戲機制
[*] [b]伺服器權威同步[/b]：改 `zones.json` 後，輪詢間隔內（sandbox 可調）自動更新；管理員也可用 [b]/reloadzones[/b] 指令立即刷新；新進玩家進服即看到當前區域
[*] [b]雙地圖顯示[/b]：小地圖與世界地圖皆正確投影、正確裁切
[*] [b]開關[/b]：主 MOD「顯示自訂區域圖層」總開關（統一設定視窗，預設開）——關閉即整層不繪製
[*] [b]矩形區域[/b]：一個區域可由多個矩形組成，涵蓋不規則範圍
[*] [b]類別篩選（0.4.0）[/b]：區域可帶 `category` 欄位——玩家在主 MOD「自訂區域」設定區逐類勾選顯示（全選／全不選），設定視窗開著時區域資料到貨自動刷新；範本自帶「示範：城鎮／示範：野外」演示
[*] [b]暗色描邊 `haloAlpha`（0.4.0）[/b]：框線之外的便宜描邊——區塊底下墊一層外擴暗色底，邊界一樣清楚、繪製成本更低
[*] [b]名稱遠距顯示＋縮放 LOD（0.4.0）[/b]：區域名稱預設不受縮放限制、拉遠也找得到位置（可關）；建物尺度區域自動三檔 LOD——中距只畫聯集色塊、遠距隱藏、拉近才畫細節
[*] [b]自動範本與生成按鈕[/b]：首次啟動自動生成含四個示範區域的 `zones.json` 範本（依伺服器語系出字）；統一設定視窗另有「生成區域範本」按鈕，可選語言（繁中／簡中／英／日）重生範本——確認視窗防誤按，現有檔先備份為帶時間戳的 `.bak.json` 再覆寫，伺服器上需「管理模組」權限
[*] [b]enabled 欄位[/b]：區域可設 `"enabled": false` 保留座標但暫時隱藏，不必刪除
[*] [b]壞資料容錯[/b]：格式錯誤或超出上限的條目會被跳過並記錄，不影響其他區域正常顯示
[*] [b]單機／多人皆可用[/b]：單機直接讀取本地 `zones.json`；多人由伺服器統一驗證與廣播
[/list]

[h2]🔗 系列 MOD[/h2]
[list]
[*] [b]主 MOD（必裝，0.8.0+）[/b]：[url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url]——地圖圖片化本體
[*] [b]本頁[/b]：Zones——伺服器自訂區域顯示
[*] [b]選裝[/b]：[url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url]——地圖 MOD 圖像包
[*] [b]選裝[/b]：[url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]MOD Compatibility[/url]——第三方 MOD 相容包（狗、馬等動物圖標）
[/list]

[h2]📋 MOD 資訊[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatMiniMapZonesFor42
[*] [b]必要 MOD:[/b] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url]（主 MOD，需 42.19.0-0.8.0 以上版本，缺少或版本過舊時本包無作用）
[*] [b]支援版本:[/b] Build 42.20.1+（42.20.0 無法寫入 `.json`，故不支援）
[*] 單機 / 多人皆可用
[/list]

[h2]💬 問題回報 & 交流[/h2]
[url=https://discord.gg/Gur2V67]👉 點此加入 Discord 伺服器[/url]

[h2]☕ 支持作者[/h2]
MOD 永遠免費。喜歡的話可以請我喝杯咖啡，贊助會用在伺服器與 MOD 開發上。原始碼公開在 GitHub。
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url] [url=https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_github.png[/img][/url]

[b]#地圖 #小地圖 #minimap #worldmap #Minidoracat[/b]

Workshop ID: 3768276209
Mod ID: MinidoracatMiniMapZonesFor42
