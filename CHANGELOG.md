# Changelog

## [42.20.1-0.3.0] - 2026-08-13

### 變更

- **區域檔改回 `zones.json`**：0.2.0 之所以暫時改用 `zones.txt`，是因為遊戲 42.20.0 擋掉了 `.json`
  的寫入；42.20.1 已經把 `.json` 放行，所以檔名改回原本的 `zones.json`
  （內容格式從頭到尾都是 JSON，只有副檔名反覆過）。備份檔一併改為 `zones.<時間戳>.bak.json`。
  **外部程式請改寫 `zones.json`。**
  > 技術要點：`getFileWriter` 的 `ALLOWED_FILE_EXTENSIONS`——42.19 無白名單／42.20.0
  > `{ini,cfg,txt,log}`（LuaManager.java:2726、判定 :6716）／42.20.1+ 加回 `json`
  > （:1034、判定 :6730），不合白名單靜默回 null。`ZomboidFileSystem.getFileExtension`
  > （:1436-1440）只取最後一個點之後且大小寫敏感 ⇒ `.bak.json` 合法、裸 `.bak` 與 `.JSON` 不行。
- **需要遊戲 Build 42.20.1 以上**：42.20.0 寫不出 `.json`，留在該版會重演 0.2.0 那次「寫檔
  全部靜默失效」的狀況，因此直接由遊戲擋下，而不是讓 MOD 裝上去之後才壞掉。
  > 技術要點：`versionMin=42.20.1`；PZ 以 `ChooseGameInfo.isAvailableSelf`（:640-644）
  > ＋ `ActiveMods.checkMissingMods` 落實，版本不符會直接從啟用清單移除。
- **0.2.0 的 `zones.txt` 會在首次啟動自動搬進 `zones.json`**：一次性，搬完會記錄已處理。
  若 `zones.json` 原本就有內容，會先把它原樣備份成 `zones.premigrate.bak.json` 再覆寫。
  搬運或備份只要有任何一步失敗，就什麼都不動、下次啟動自動重試。搬運完成後刪掉 `zones.json`
  就是清空區域（執行期重生空範本、關服期間刪除則啟動時重生示範範本），
  **不會**從殘留的 `zones.txt` 把舊資料復活。
  > 技術要點：marker `MinidoracatMiniMapZones/migratedToJsonV2.txt`。判定順序與 0.2.0 相反
  > ——先看 legacy 再看正典：升級者磁碟上常同時有 0.2.0 的真實資料（zones.txt）與 42.19 時代
  > 的舊副本（zones.json），沿用「正典有內容就早退」會保留舊副本、丟棄真實資料。

### 已知行為（刻意設計）

- 本包**不會**去猜既有的 `zones.json` 是不是 42.19 時代的舊檔而清掉它——那種推論會誤刪真實
  資料。代價：如果你在 0.2.0 期間刪掉 `zones.txt` 來清空區域、機器上又還留著更早的 `zones.json`，
  升級後會看到舊區域重新出現。**直接編輯或清空 `zones.json` 即可**，
  不會有任何資料遺失。
  > 技術要點：0.2.0 的 marker（legacyMigratedV1.txt）有四種寫入情境，其中三種並不代表磁碟上
  > 現在存在過期的 zones.json，據以做破壞性刪除會誤刪使用者資料。production code 不讀它。
- 萬一自動搬運失敗，伺服器／單機仍會照常讀取現有的 `zones.json`（可能顯示到舊區域）。
  這是刻意的——一併擋掉會連「其實已經搬好、只差記錄」與「檔案完全正常但寫入功能壞了」
  一起遮蔽，代價更大。console 會有明確的 FAILED 訊息，下次啟動自動重試。

### 內部

- **異常情境全面硬化**：三個寫檔入口（自動搬運／範本生成／設定頁生成按鈕）統一為
  「臨寫前重讀比對 → 寫入 → 讀回驗證」，並新增大量故障注入測試，涵蓋磁碟寫入失敗、
  檔案讀不到、清理動作本身失敗、以及外部程式在寫入空檔期改檔等異常情境。
  > 技術要點（實作）：抽出 `fileExists`（三態：存在／不存在／未知，探測失敗不得壓成不存在）、
  > `readFileCapped`／`readFileCappedStrict`（`getFileReader` 的 nil 同時代表「不存在」與
  > 「存在但打不開」，strict 版用 `cacheFileExists` 區分並對後者 fail closed）、
  > `writeFileVerified`（PZ getFileWriter 包 java PrintWriter，IO 失敗被吞不拋，write/close
  > 回來不代表落地）。正典檔的寫入刻意展開而不走 helper，以便在取得 writer 的那一刻才立起
  > 「已碰檔案」旗標——getFileWriter 回 nil 代表原檔一位元組沒被碰過，絕不可對它做 truncate。
  > `truncateFile` 亦做讀回驗證。
  > 技術要點（遷移重試安全）：正典內容已等於 legacy 時只補 marker、不重寫；
  > `zones.premigrate.bak.json` 為 write-once（它是「搬運前原檔」的收據）。
  > 「已備份」不等於「已搬運」——備份存在只證明 PREPARED、不證明 APPLIED，故改以備份內容
  > 當基準：正典空白／不存在／等於備份 ⇒ 尚未套用，繼續搬運；有內容且不等於備份 ⇒ 已套用
  > 後被外部改過，保持現狀不回滾。收據與正典的有效性都要求「非空且能解析成合法 JSON」，
  > 用以區分「外部寫入的真實資料」與「清不掉的破格半寫殘骸」；後者不寫 marker（寫了會把壞
  > 狀態鎖死、legacy 永久遮蔽），什麼都不動並每次啟動記一次 log，使用者清掉壞檔後自動收斂。
  > 技術要點（測試）：stub 的副檔名白名單模擬改為 42.20.1+ 的 {ini,cfg,txt,log,json}，保留裸
  > .bak 與大小寫不符（.JSON）被拒的回歸鎖；99/99 通過，其中 17 個為故障注入案例。
  > 另有 21 項 mutation test 把每個修正逐一還原成 bug 版，確認都有對應測試會變紅——其中 4 項
  > 需同時拆掉兩道守衛才會紅，證實那幾條路徑是雙重防線而非單點。
  > 技術要點（審查）：獨立雙 lane review 共五輪，對方提出 18 項 Blocking、採納 17 項；
  > 未採納者為「遷移失敗仍載入既有 json」，已列入上方「已知行為」。

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
