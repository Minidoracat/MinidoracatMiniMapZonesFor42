<!-- Steam 討論區貼文稿源（繁中）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3768276209/586187095760055665/ -->
<!-- 標題：📖 Zones 完整說明（伺服器管理員） -->

[b]English version:[/b] [url=https://steamcommunity.com/workshop/filedetails/discussion/3768276209/586187095760055791/]Zones Guide for Server Admins[/url]

Zones 讓伺服器在小地圖與世界地圖上標出自訂區域（半透明色塊＋框線＋名稱），例如活動範圍、重置區。區域[b]只是地圖上的標示[/b]，不含 PVP、安全區等任何遊戲機制。本串寫給伺服器管理員；一般玩家只需要看「玩家端設定」。

[h2]🚀 快速上手[/h2]
[olist]
[*] 安裝主 MOD [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]MiniMap for B42[/url] 與本 MOD（遊戲版本跟隨主 MOD，目前需 Build 42.21.0 以上），啟動一次伺服器（單機就是開一次遊戲）
[*] 自動產生的範本在 [b]Zomboid/Lua/MinidoracatMiniMapZones/zones.json[/b]，內含四個示範區域，文字依伺服器語言產生
[*] 修改示範區域或新增自己的區域，存檔
[*] 等自動更新（預設 60 秒），或由管理員在聊天輸入 [b]/reloadzones[/b] 立即生效，不需要重啟
[/olist]

[h2]📝 zones.json 怎麼寫[/h2]
檔案是 JSON 格式、以 UTF-8 讀取，區域名稱可用任何語言。最小範例：
[code]
{
  "zones": [
    {
      "name": "活動區",
      "rects": [[11882, 6928, 11918, 6961], [11918, 6961, 11950, 7000]],
      "fill": "#3B82F6",
      "fillAlpha": 0.3,
      "border": "#3B82F6",
      "borderAlpha": 0.9,
      "haloAlpha": 0.55,
      "category": "活動區",
      "enabled": true
    }
  ]
}
[/code]
[list]
[*] [b]name[/b]（必填）：區域名稱，會顯示在地圖上
[*] [b]rects[/b]（必填）：[i][[x1,y1,x2,y2], ...][/i]，世界座標（square），左上到右下，x2 要大於 x1、y2 要大於 y1。一個區域可以放多個矩形拼出 L 形等不規則範圍
[*] [b]fill[/b]／[b]border[/b]：填色與框線顏色，寫 "#RRGGBB" 或 [r, g, b]。fill 省略時為紅色，border 省略時跟 fill 同色
[*] [b]fillAlpha[/b]／[b]borderAlpha[/b]：0–1 的不透明度，省略時分別是 0.25 與 0.9。fillAlpha 寫成 alpha 也認得
[*] [b]haloAlpha[/b]（選填，0–1）：在色塊底下墊一層稍微外擴的暗色底，效果像描邊，繪製成本比框線低；可以和框線一起用，也可以把 borderAlpha 設成 0 只用它
[*] [b]category[/b]（選填）：區域類別，玩家可依類別勾選要不要顯示。類別名稱含逗號，或剛好是 "-"、"nil" 時不會出現在勾選清單（區域照常顯示）
[*] [b]enabled[/b]（選填）：設成 false 可保留座標但暫時隱藏，不必刪掉；省略等於 true
[/list]
[b]其他規則[/b]
[list]
[*] 建物大小的區域（整個區域最長邊不超過 100 格）會自動依縮放簡化：中距離只畫一整塊色塊、拉遠隱藏、拉近才畫細節，不需要設定任何欄位
[*] 上限：最多 500 個區域、每個區域最多 64 個矩形，檔案不可超過約 1 MB
[*] 格式錯誤或超過上限的區域會被跳過並記錄在伺服器 log，其他區域照常顯示
[*] 外部程式（活動範圍工具、重置區標記工具等）可以直接寫入 zones.json
[/list]
完整格式說明：[url=https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42]GitHub README[/url]

[h2]🔄 同步與重新載入[/h2]
[list]
[*] 伺服器會定期重讀 zones.json，內容有變才廣播給所有玩家；新進玩家進服就會收到目前的區域
[*] 重讀間隔在沙盒選項「Minidoracat 地圖區域 → 區域資料輪詢間隔（秒）」調整，範圍 10–3600 秒，預設 60 秒。數字越小更新越快，但伺服器讀檔負擔越高
[*] [b]/reloadzones[/b]：不等間隔、立即重讀並廣播，完成後會顯示載入了幾個區域，或顯示錯誤原因。伺服器上需要「管理模組」權限；單機則直接重讀本機檔案
[*] 伺服器執行中刪掉 zones.json＝清空所有區域（會自動補一份空白檔）；關服期間刪掉＝下次啟動重新產生示範範本
[/list]

[h2]🧩 生成區域範本按鈕[/h2]
位置在主 MOD 統一設定視窗的「自訂區域」區：先在下拉選單選語言（跟隨當前語言／繁體中文／简体中文／English／日本語），再按「生成區域範本」。
[list]
[*] 會先跳出確認視窗，避免誤按
[*] zones.json 不存在或是空的：直接寫入範本
[*] zones.json 已有內容：先把舊檔備份成帶時間戳的檔案（例如 zones.20260101-120000.bak.json，每次生成各自保留、不互相覆蓋），再覆寫；備份失敗就不動 zones.json
[*] 生成後立即套用；在伺服器上需要「管理模組」權限
[*] 範本內含四個示範區域（其中一個是多矩形的 L 形區域），並示範「示範：城鎮」「示範：野外」兩種類別
[/list]

[h2]👀 玩家端設定[/h2]
都在主 MOD 的統一設定視窗：
[list]
[*] [b]顯示自訂區域圖層[/b]（預設開）：總開關，關掉就完全不畫區域
[*] [b]「自訂區域」區的類別勾選[/b]：依伺服器實際的 category 自動列出，可逐類勾選或全選／全不選；視窗開著時收到新區域資料會自動刷新
[*] [b]區域名稱不受縮放限制[/b]（預設開）：拉遠也顯示區域名稱，方便找位置；關掉後小型區域的名稱只在拉近時顯示
[/list]

[h2]❓ 常見問題[/h2]
[list]
[*] [b]看不到區域？[/b]確認主 MOD 已安裝並更新到最新版（主 MOD 沒裝或太舊時，本 MOD 不會顯示區域，但不影響主 MOD 其他功能）；再確認「顯示自訂區域圖層」有開、該類別沒被取消勾選
[*] [b]改了檔案沒反應？[/b]等一個輪詢間隔，或用 /reloadzones。JSON 寫壞時會保留上一次成功載入的區域，錯誤會記在伺服器 log，用 /reloadzones 也會直接顯示
[*] [b]區域會影響遊戲嗎？[/b]不會，只是地圖標示
[*] [b]支援 Build 42.20.x 嗎？[/b]不支援。主 MOD 目前需要 Build 42.21.0 以上，本 MOD 跟著主 MOD，請更新遊戲到 42.21.0 以上
[*] [b]以前用的 zones.txt 怎麼辦？[/b]首次啟動會自動搬進 zones.json（若 zones.json 原本有內容，會先備份為 zones.premigrate.bak.json）；之後外部程式請改寫 zones.json
[*] [b]原版資源點（軍事、醫療、超市…）呢？[/b]那是主 MOD 內建的功能，不需要本 MOD
[*] [b]單機能用嗎？[/b]可以，單機直接讀取本機的 zones.json
[/list]

[h2]💬 回報方式[/h2]
請附上遊戲版本、發生什麼事，以及相關的 zones.json 片段或伺服器 log 錯誤訊息。
[list]
[*] GitHub Issues：[url=https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42/issues]https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42/issues[/url]
[*] Discord：[url=https://discord.gg/Gur2V67]https://discord.gg/Gur2V67[/url]
[/list]
