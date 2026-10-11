<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3817849328 -->
<!-- Steam 指南稿源（繁中）：MOD 的完整說明以本指南為準，簡介只放摘要。格式與同步方式見 pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 小地圖 - 伺服器自訂區域 MiniMap Zones MOD 完整說明：zones.json、同步與玩家設定 -->
<!-- 摘要：Minidoracat 小地圖伺服器自訂區域 MOD 的圖文說明（寫給伺服器管理員）：快速上手、zones.json 怎麼寫、同步與 /reloadzones、生成區域範本按鈕，以及玩家端設定。 -->
=== 🚀 快速上手
[b]English version:[/b] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817849388]MiniMap Zones Mod Guide[/url]

MOD 本體（Steam Workshop）：
https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209

Zones 讓伺服器在小地圖與世界地圖上標出自訂區域（半透明色塊＋框線＋名稱），例如活動範圍、重置區。
[list]
[*] [b]只是地圖標示[/b]：不含 PVP、安全區等任何遊戲機制。
[*] [b]寫給伺服器管理員[/b]：一般玩家只需要看「玩家端設定」。
[/list]
{{img:01-server-zones-demo-zh.jpg}}
[olist]
[*] [b]安裝[/b]：主 MOD [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]MiniMap[/url] 與本 MOD（遊戲版本跟隨主 MOD，目前需 Build 42.21.0 以上），啟動一次伺服器（單機就是開一次遊戲）。
[*] [b]找到範本[/b]：自動產生在 [b]Zomboid/Lua/MinidoracatMiniMapZones/zones.json[/b]，內含四個示範區域，文字依伺服器語言產生。
[*] [b]編輯[/b]：修改示範區域或新增自己的區域，存檔。
[*] [b]生效[/b]：等自動更新（預設 60 秒），或由管理員在聊天輸入 [b]/reloadzones[/b] 立即生效，不需要重啟。
[/olist]
=== 🧰 同步與重新載入
[list]
[*] [b]自動重讀[/b]：伺服器會定期重讀 zones.json，內容有變才廣播給所有玩家。
[*] [b]新進玩家[/b]：進服就會收到目前的區域。
[*] [b]重讀間隔[/b]：沙盒選項「Minidoracat 地圖區域 → 區域資料輪詢間隔（秒）」，範圍 10–3600 秒，預設 60 秒。數字越小更新越快，但伺服器讀檔負擔越高。
[/list]
[h3]/reloadzones[/h3]
[list]
[*] [b]立即重讀[/b]：不等間隔、立即重讀並廣播，完成後會顯示載入了幾個區域，或顯示錯誤原因。
[*] [b]權限[/b]：伺服器上需要「管理模組」權限；單機則直接重讀本機檔案。
[/list]
[h3]刪掉 zones.json[/h3]
[list]
[*] [b]伺服器執行中刪掉[/b]：清空所有區域（會自動補一份空白檔）。
[*] [b]關服期間刪掉[/b]：下次啟動重新產生示範範本。
[/list]
=== 🧰 生成區域範本按鈕
[list]
[*] [b]位置[/b]：主 MOD 統一設定視窗的「自訂區域」區。
[*] [b]用法[/b]：先在下拉選單選語言（跟隨當前語言／繁體中文／簡體中文／English／日本語），再按「生成區域範本」。
[*] [b]防誤按[/b]：會先跳出確認視窗。
[*] [b]權限[/b]：生成後立即套用；在伺服器上需要「管理模組」權限。
[/list]
[h3]會不會蓋掉現有的檔案[/h3]
[list]
[*] [b]zones.json 不存在或是空的[/b]：直接寫入範本。
[*] [b]zones.json 已有內容[/b]：先把舊檔備份成帶時間戳的檔案（例如 zones.20260101-120000.bak.json，每次生成各自保留、不互相覆蓋），再覆寫。
[*] [b]備份失敗[/b]：就不動 zones.json。
[/list]
[h3]範本內容[/h3]
[list]
[*] 四個示範區域，其中一個是多矩形的 L 形區域。
[*] 示範「示範：城鎮」「示範：野外」兩種類別。
[/list]
=== ⚙️ zones.json 怎麼寫
檔案是 JSON 格式、以 UTF-8 讀取，區域名稱可用任何語言。
[h3]最小範例[/h3]
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
[h3]欄位[/h3]
[table]
[tr][th]欄位[/th][th]必填[/th][th]說明[/th][/tr]
[tr][td]name[/td][td]必填[/td][td]區域名稱，會顯示在地圖上[/td][/tr]
[tr][td]rects[/td][td]必填[/td][td][i][[x1,y1,x2,y2], ...][/i]，世界座標（square），左上到右下，x2 要大於 x1、y2 要大於 y1[/td][/tr]
[tr][td]fill[/td][td]選填[/td][td]填色，寫 "#RRGGBB" 或 [r, g, b]；省略時為紅色[/td][/tr]
[tr][td]border[/td][td]選填[/td][td]框線顏色，寫法同 fill；省略時跟 fill 同色[/td][/tr]
[tr][td]fillAlpha[/td][td]選填[/td][td]填色不透明度 0–1，省略時 0.25；寫成 alpha 也認得[/td][/tr]
[tr][td]borderAlpha[/td][td]選填[/td][td]框線不透明度 0–1，省略時 0.9[/td][/tr]
[tr][td]haloAlpha[/td][td]選填[/td][td]0–1，在色塊底下墊一層稍微外擴的暗色底[/td][/tr]
[tr][td]category[/td][td]選填[/td][td]區域類別，玩家可依類別勾選要不要顯示[/td][/tr]
[tr][td]enabled[/td][td]選填[/td][td]設成 false 可保留座標但暫時隱藏，不必刪掉；省略等於 true[/td][/tr]
[/table]
[list]
[*] [b]不規則範圍[/b]：一個區域可以放多個矩形，拼出 L 形等形狀。
[*] [b]haloAlpha[/b]：效果像描邊，繪製成本比框線低；可以和框線一起用，也可以把 borderAlpha 設成 0 只用它。
[*] [b]不列入勾選清單的類別[/b]：類別名稱含逗號，或剛好是 "-"、"nil" 時不會出現在勾選清單（區域照常顯示）。
[/list]
[h3]其他規則[/h3]
[list]
[*] [b]建物大小的區域[/b]（整個區域最長邊不超過 100 格）：自動依縮放簡化，中距離只畫一整塊色塊、拉遠隱藏、拉近才畫細節，不需要設定任何欄位。
[*] [b]上限[/b]：最多 500 個區域、每個區域最多 64 個矩形，檔案不可超過約 1 MB。
[*] [b]寫錯時[/b]：格式錯誤或超過上限的區域會被跳過並記錄在伺服器 log，其他區域照常顯示。
[*] [b]外部程式[/b]：活動範圍工具、重置區標記工具等可以直接寫入 zones.json。
[*] [b]完整格式說明[/b]：[url=https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42]GitHub README[/url]
[/list]
=== ⚙️ 玩家端設定
都在主 MOD 的統一設定視窗：
[list]
[*] [b]顯示自訂區域圖層[/b]（預設開）：總開關，關掉就完全不畫區域。
[*] [b]「自訂區域」區的類別勾選[/b]：依伺服器實際的 category 自動列出，可逐類勾選或全選／全不選；視窗開著時收到新區域資料會自動刷新。
[*] [b]區域名稱不受縮放限制[/b]（預設開）：拉遠也顯示區域名稱，方便找位置；關掉後小型區域的名稱只在拉近時顯示。
[/list]
=== ❓ 常見問題
[h3]看不到區域？[/h3]
[list]
[*] 確認主 MOD 已安裝並更新到最新版：主 MOD 沒裝或太舊時，本 MOD 不會顯示區域，但不影響主 MOD 其他功能。
[*] 再確認「顯示自訂區域圖層」有開、該類別沒被取消勾選。
[/list]
[h3]改了檔案沒反應？[/h3]
[list]
[*] 等一個輪詢間隔，或用 /reloadzones。
[*] JSON 寫壞時會保留上一次成功載入的區域，錯誤會記在伺服器 log，用 /reloadzones 也會直接顯示。
[/list]
[h3]區域會影響遊戲嗎？[/h3]
[list]
[*] 不會，只是地圖標示。
[/list]
[h3]支援 Build 42.20.x 嗎？[/h3]
[list]
[*] 不支援。主 MOD 目前需要 Build 42.21.0 以上，本 MOD 跟著主 MOD。
[*] 請更新遊戲到 42.21.0 以上。
[/list]
[h3]以前用的 zones.txt 怎麼辦？[/h3]
[list]
[*] 首次啟動會自動搬進 zones.json；若 zones.json 原本有內容，會先備份為 zones.premigrate.bak.json。
[*] 之後外部程式請改寫 zones.json。
[/list]
[h3]原版資源點（軍事、醫療、超市…）呢？[/h3]
[list]
[*] 那是主 MOD 內建的功能，不需要本 MOD。
[/list]
[h3]單機能用嗎？[/h3]
[list]
[*] 可以，單機直接讀取本機的 zones.json。
[/list]
=== 💬 回報方式
[list]
[*] [b]回報時請附上[/b]：
[list]
[*] 遊戲版本
[*] 發生什麼事
[*] 相關的 zones.json 片段或伺服器 log 錯誤訊息
[/list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatMiniMapZonesFor42/issues]GitHub Issues[/url][/b]
[*] [b][url=https://discord.gg/Gur2V67]Discord 社群[/url][/b]
[/list]
