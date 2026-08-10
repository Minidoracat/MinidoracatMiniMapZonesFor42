[h1]Minidoracat MiniMap Zones 42.20.0-0.2.0[/h1]
[i]2026-07-30[/i]

[h3]🔧 修正[/h3]
[list]
[*] [b]42.20 寫檔全滅修復——檔名遷移 zones.json → zones.txt[/b]：PZ 42.20 的
[/list]
getFileWriter 新增副檔名白名單 {ini,cfg,txt,log}（42.20 反編譯
LuaManager.java:2726/:6716），不合白名單[b]靜默回 null[/b]——0.1.0 的三個寫檔點
（範本自動生成、時間戳備份、設定頁生成按鈕）全部失效（讀取不受影響）。
0.2.0 起正典檔改為 zones.txt（[b]內容仍為 JSON 格式[/b]）；備份檔改為
zones.<時間戳>.bak.txt。外部程式請改寫 zones.txt。
[list]
[*] [b]42.19 舊檔一次性自動遷移[/b]：首次啟動時若有內容的 zones.json 存在且
[/list]
zones.txt 尚未建立，原樣搬入 zones.txt（寫後讀回驗證），並寫 marker
（MinidoracatMiniMapZones/legacyMigratedV1.txt）記錄已處置。marker 之後
執行期刪 zones.txt＝清空（重生空範本）、關服期間刪除＝啟動重生示範範本
（同 0.1.0 語意），兩者[b]絕不[/b]從殘留舊檔復活資料
（Lua 無法刪除 legacy 檔，靠 marker 判定；比照主 MOD keyMigratedV1 先例）。
遷移失敗（超 1MB／IO／驗證不符／marker 寫不出）不寫 marker、中止範本寫入，
下次啟動重試；讀回驗證不符時將半寫的 zones.txt truncate 清空（防後續啟動把
壞檔追認成正典、永久遮蔽 legacy）；結果做 session 快取（oversize 舊檔不會被
輪詢每輪重掃 1MB）；server 與 SP 端 console 皆有可見 log。

[h3]• 內部[/h3]
[list]
[*] [b]測試 stub 模擬 42.20 白名單（回歸鎖）[/b]：0.1.0 離線測試 60/60 全綠卻測不到
[/list]
實機寫檔全滅——stub 的 getFileWriter 無條件回 writer。重構為 path-aware stub
並模擬副檔名白名單（不合回 nil），任何寫檔路徑回歸到非白名單副檔名都會在
離線階段被抓（白名單模擬與引擎同為[b]大小寫敏感[/b]）；新增 13 個遷移測試
（原樣搬入／marker 防復活／txt 優先／超限中止重試／白名單回歸鎖／尾端空行
冪等／marker 失敗不追認／讀回不符 truncate 後重試／生成閘先遷移／session
快取防重掃／不可讀 legacy 區分（cacheFileExists）／verify 例外收斂／生成
遇遷移失敗中止），73/73 通過。獨立雙 lane review（Claude/codex review-plus
各一輪）發現的 3 Blocking＋6 Important 全數修復或列為已記錄取捨後綠燈。
