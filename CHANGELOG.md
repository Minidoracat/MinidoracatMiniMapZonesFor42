# Changelog

## [42.20.0-0.2.0] - 2026-07-30

### 修正

- **42.20 寫檔全滅修復——檔名遷移 `zones.json` → `zones.txt`**：PZ 42.20 的
  `getFileWriter` 新增副檔名白名單 {ini,cfg,txt,log}（42.20 反編譯
  LuaManager.java:2726/:6716），不合白名單**靜默回 null**——0.1.0 的三個寫檔點
  （範本自動生成、時間戳備份、設定頁生成按鈕）全部失效（讀取不受影響）。
  0.2.0 起正典檔改為 `zones.txt`（**內容仍為 JSON 格式**）；備份檔改為
  `zones.<時間戳>.bak.txt`。外部程式請改寫 `zones.txt`。
- **42.19 舊檔一次性自動遷移**：首次啟動時若有內容的 `zones.json` 存在且
  `zones.txt` 尚未建立，原樣搬入 `zones.txt`（寫後讀回驗證），並寫 marker
  （`MinidoracatMiniMapZones/legacyMigratedV1.txt`）記錄已處置。marker 之後
  執行期刪 `zones.txt`＝清空（重生空範本）、關服期間刪除＝啟動重生示範範本
  （同 0.1.0 語意），兩者**絕不**從殘留舊檔復活資料
  （Lua 無法刪除 legacy 檔，靠 marker 判定；比照主 MOD keyMigratedV1 先例）。
  遷移失敗（超 1MB／IO／驗證不符／marker 寫不出）不寫 marker、中止範本寫入，
  下次啟動重試；讀回驗證不符時將半寫的 zones.txt truncate 清空（防後續啟動把
  壞檔追認成正典、永久遮蔽 legacy）；結果做 session 快取（oversize 舊檔不會被
  輪詢每輪重掃 1MB）；server 與 SP 端 console 皆有可見 log。

### 內部

- **測試 stub 模擬 42.20 白名單（回歸鎖）**：0.1.0 離線測試 60/60 全綠卻測不到
  實機寫檔全滅——stub 的 getFileWriter 無條件回 writer。重構為 path-aware stub
  並模擬副檔名白名單（不合回 nil），任何寫檔路徑回歸到非白名單副檔名都會在
  離線階段被抓（白名單模擬與引擎同為**大小寫敏感**）；新增 13 個遷移測試
  （原樣搬入／marker 防復活／txt 優先／超限中止重試／白名單回歸鎖／尾端空行
  冪等／marker 失敗不追認／讀回不符 truncate 後重試／生成閘先遷移／session
  快取防重掃／不可讀 legacy 區分（cacheFileExists）／verify 例外收斂／生成
  遇遷移失敗中止），73/73 通過。獨立雙 lane review（Claude/codex review-plus
  各一輪）發現的 3 Blocking＋6 Important 全數修復或列為已記錄取捨後綠燈。

## [42.19.0-0.1.0] - 2026-07-18

### 新增

- **專案初始版本**：`Minidoracat MiniMap for B42` 主 MOD 的區域顯示 addon——純資料
  MOD，半透明填色／框線／名稱標籤等繪製全在主 MOD（`registerZoneProvider` API），
  本包只負責「資料從哪來」。
- **伺服器自訂區域**：伺服器端 `zones.json`（`Zomboid/Lua/MinidoracatMiniMapZones/zones.json`）
  定義任意矩形區域，外部程式可寫入（例如活動範圍工具、重置區標記工具）。伺服器
  輪詢間隔可調（sandbox `PollIntervalSeconds`，預設 60 秒）偵測變更後自動廣播給
  所有玩家；管理員可用 `/reloadzones` 指令立即強制刷新。單機模式直接讀取本地
  `zones.json`，不經伺服器驗證流程。壞資料容錯：格式錯誤或超出上限（總 zone 數
  ≤500、單 zone rects ≤64 等）的條目會被跳過並記錄，不影響其他區域正常顯示。
- **自動示範範本**：伺服器啟動（或單機首次進世界）時，`zones.json` 不存在或空白即自動
  生成含四個示範區域（West Point 警局／Rosewood 消防局／March Ridge 地堡／Riverside
  多矩形 L 形）的範本，文字依伺服器語系出字（繁中／簡中／英／日；伺服器端補償
  `Translator` 初始化順序，`options.ini` 語系設定正確生效）。執行期檔案被刪除時自動
  重生空範本（區域清空、檔案常在，外部工具隨時可寫）。
- **「生成區域範本」按鈕**：統一設定視窗（主 MOD `registerZoneAction` API）語言下拉＋
  按鈕，可指定語言重生範本——按下先跳確認視窗（Yes/No）防誤按；`zones.json` 已有
  內容時先原樣備份為帶時間戳的 `zones.json.<YYYYMMDD-HHMMSS>.bak`（每次生成各自保留、
  不互相覆蓋）再覆寫並立即套用；備份失敗則中止、原檔一位元組不動。伺服器上需
  「管理模組」權限（與 `/reloadzones` 同守衛）。
- **`enabled` 欄位**：區域可設 `"enabled": false` 保留座標但暫時隱藏（不驗證、不廣播、
  不佔 500 區域上限），省略視為 `true`。
- **「顯示伺服器區域」母開關**：本包以 `registerZoneProvider` 第三參 `optionLabelKey`
  註冊，主 MOD 據此於統一設定視窗動態追加一顆 per-provider 母開關（預設開），
  關閉即渲染時整個跳過本 addon。本包不再自建 ModOptions 頁。
- **內建資源點（POI）已改由主 MOD 本體提供**：原版地圖資源點（軍事、醫療、超市等
  14 類）已於 0.8.0 內建於主 MOD `Minidoracat MiniMap for B42`，裝主 MOD 即見；
  本 addon 專注於伺服器自訂區域，不再處理 POI。
- **版本守衛**：需要主 MOD `42.19.0-0.8.0+`（提供 `registerZoneProvider` 與
  `registerZoneAction` API）；偵測到主 MOD 版本過舊或未安裝時安靜降級（不掛載
  provider）並記錄一次 log，不會 crash。
