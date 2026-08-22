# MinidoracatMiniMapZonesFor42 — 使用者手動驗證清單

本清單涵蓋自動化冒煙／dry-run 無法覆蓋的「進遊戲肉眼驗證」項目。自動化部分（雙 MOD 掛載、
boot 冒煙兩輪、500 zone 分包壓測、壞 JSON 三態）已在 US-009 通過；以下請使用者實機逐項打勾。

- 適用版本：主 MOD `MinidoracatMiniMapFor42` 42.19.0-0.8.0+ ＋ 本包 `MinidoracatMiniMapZonesFor42` 42.20.1-0.3.0
  （本包需遊戲 Build **42.20.1** 以上——42.20.0 的 Lua 寫檔副檔名白名單不含 `.json`）
- 相依：本包 `require=MinidoracatMiniMapFor42`，載入順序主 MOD 在前
- 座標系：世界 square 座標（x 向東、y 向南，左上為原點）

---

## 0. 前置

- [ ] 兩 MOD 皆已掛載到 `%USERPROFILE%\Zomboid\mods\`（`link_workshop.bat` 或 junction）
- [ ] 新遊戲的 Mods 清單同時勾選主 MOD 與本包（主 MOD 在前）
- [ ] 開關預設值確認：**Zone 圖層總開關（顯示自訂區域圖層）= 開**
      （0.5.0 起本包不再註冊「顯示伺服器區域」母開關——與總開關重複；內建 POI 開關屬主 MOD、不在本清單）

---

## 1. SP 單機：本地 zones.json 顯示

**放置路徑**（伺服器讀不到時 client 走本地 fallback，US-006 定案）：

```
%USERPROFILE%\Zomboid\Lua\MinidoracatMiniMapZones\zones.json
```

> **首次啟動自動範本**：server 啟動或 SP 首次進世界時，若上述路徑無 zones.json，會自動產生一份含
> 四個示範區域（West Point 警局／Rosewood 消防局／March Ridge 地堡／Riverside 多矩形 L 形）的範本，
> 進遊戲即可看到，可直接修改或刪除。下方 sample 為手動覆寫時的參考格式。

**sample `zones.json`**（Muldraugh 與 West Point 各一塊，含填色＋框線＋名稱）：

```json
{
  "zones": [
    {
      "name": "測試區-Muldraugh",
      "rects": [[10680, 9420, 10820, 9540]],
      "fill": "#3aa0ff",
      "fillAlpha": 0.25,
      "border": "#3aa0ff",
      "borderAlpha": 0.9
    },
    {
      "name": "測試區-WestPoint",
      "rects": [[11750, 6750, 11920, 6950]],
      "fill": [255, 120, 0],
      "fillAlpha": 0.30,
      "border": "#ffffff",
      "borderAlpha": 1.0,
      "category": "test"
    }
  ]
}
```

> 輸入 schema：`rects` 為 `[[x1,y1,x2,y2], ...]`（需 x2>x1、y2>y1）；`fill`/`border` 可用
> `"#RRGGBB"` 或 `[r,g,b]`；`fillAlpha`/`borderAlpha` 0–1（也接受 `alpha` 別名，缺 `fillAlpha` 時採用）；
> `category` 選填；`enabled` 選填布林，省略＝`true`，設 `false` 則該區域保留在檔案但不顯示
> （validator 直接跳過：不驗證、不廣播、不佔 500 區域上限）。缺省 fill 為紅色。

**步驟與預期：**

- [ ] 首次進世界**不手動放檔**
      **預期**：自動產生含四個示範區域的範本（West Point 警局／Rosewood 消防局／March Ridge 地堡／
      Riverside 多矩形 L 形），小地圖與世界地圖即出現對應色塊、框線與置中名稱標籤。
- [ ] 改用上述 sample 覆寫 zones.json → 重進世界
      **預期**：小地圖與世界地圖在 Muldraugh 出現半透明藍色方塊、West Point 出現橘色方塊，
      各自帶框線與置中名稱標籤。
- [ ] 開世界地圖（M）縮放 3 檔、平移
      **預期**：填色菱形貼合地圖投影、裁切邊緣不溢出視窗；小地圖與世界地圖同區同色同名。
- [ ] 遊戲執行中編輯 zones.json（改座標或加一塊）存檔，等 ≤ `PollIntervalSeconds`+5s
      **預期**：畫面自動更新，無需重進世界（SP 本地輪詢生效）。
- [ ] 把 zones.json 內容改成語法錯（故意刪一個 `]`）存檔
      **預期**：畫面保留上一版區域、不崩潰；`console.txt` 出現一條解析失敗 warning。

---

## 2. MP：本機 dedicated server ＋ 雙客戶端

伺服器讀 `%USERPROFILE%\Zomboid\Lua\MinidoracatMiniMapZones\zones.json`（cache root，
非 `Server\<servername>\` 底下；已驗證 `getFileReader` 解析路徑，見
`MinidoracatMiniMapZonesServer.lua:11`）。除非伺服器以 `-cachedir` 指定其他 cache 目錄，
否則固定是此路徑。伺服器權威，client 不自行讀檔。

- [ ] 伺服器放好 zones.json → 開 server → 客戶端 A 進服
      **預期**：A 進服即收到當前全量區域並顯示（`OnGameStart` 送 `requestZones`）。
- [ ] 客戶端 B 於伺服器已在跑、A 已在線後**中途進服**
      **預期**：B 一進來就看到與 A 相同的當前全量（新進玩家全量同步，AC-1）。
- [ ] 伺服器執行中，由外部改寫 zones.json（加/改一塊）
      **預期**：≤ `PollIntervalSeconds`+5s 內 A 與 B **兩台**同步更新（輪詢偵測變化→廣播）。
- [ ] 刪除伺服器上的 zones.json（或清空）
      **預期**：下一輪輪詢後兩客戶端區域清空（送空集原子套用）。
- [ ] dedicated server 設定介面找到 `PollIntervalSeconds`，改為 30 → 重啟 server
      **預期**：輪詢節奏跟著變快（改檔後約 30s 內生效）；預設 60s 下 `server-console.txt`
      無 tick 過載警告、遊玩無可感知卡頓（AC-1b）。

---

## 3. `/reloadzones` 聊天指令（權限）

- [ ] **admin/有 ManipulateMods 權限**帳號在聊天輸入 `/reloadzones`
      **預期**：≤3s 內伺服器強制重讀 zones.json 並全體廣播；該玩家收到 `reloadResult`
      回饋（載入數＋警告數）。
- [ ] **一般（無 ManipulateMods）**玩家輸入 `/reloadzones`
      **預期**：伺服器無動作、不重讀、不廣播（權限守衛第一行擋下）；不得有任何區域變化。
- [ ] SP 單機輸入 `/reloadzones`
      **預期**：改走本地重讀（fallback），區域依當前 zones.json 更新。

---

## 3b. 「生成區域範本」按鈕（確認視窗＋備份＋直接套用）

MOD 選項頁的語言下拉＋「生成區域範本」按鈕（伺服器上需 ManipulateMods 權限）：

- [ ] 按下按鈕
      **預期**：先跳出 Yes/No 確認視窗（顯示選定語言＋「現有 zones.json 會先備份為 zones.<時間戳>.bak.json 再覆寫」）；
      按 No＝什麼都不發生、檔案不動。
- [ ] 確認視窗按 Yes、zones.json 不存在或空白時
      **預期**：直接寫入含四個示範區域的 zones.json 並立即套用（不產生 .bak.json）；回饋「範本已寫入 …」。
- [ ] 確認視窗按 Yes、zones.json 已有內容時
      **預期**：先把舊 zones.json 原樣備份為同目錄時間戳檔 `zones.<YYYYMMDD-HHMMSS>.bak.json`
      （每次生成各自保留、不互相覆蓋；同秒內連按同名覆蓋屬可接受），再覆寫 zones.json 並立即套用；
      回饋「舊 zones.json 已備份為 zones.<時間戳>.bak.json，範本已寫入」（顯示實際檔名）。
- [ ] 連按兩次生成（間隔 >1 秒）
      **預期**：目錄出現兩個不同時間戳的 .bak.json，前一個備份不被後一個覆蓋。
- [ ] 備份不可寫時按 Yes（時間戳檔名難以預先設唯讀，可改將整個 `MinidoracatMiniMapZones`
      目錄暫設唯讀模擬）
      **預期**：中止生成、zones.json 一位元組不動；回饋「範本生成失敗…」。

> 備份檔會隨生成次數累積（每個約 1KB），不需要時可自行刪除 `.bak.json` 檔。

---

## 3c. 0.2.0 → 0.3.0 檔名遷移（`zones.txt` → `zones.json`，一次性）

在 `%USERPROFILE%\Zomboid\Lua\MinidoracatMiniMapZones\` 手動布置狀態後啟動遊戲／伺服器，
看 console 是否出現 `legacy zones.txt migrated to zones.json (one-time; ...)`。
每次測試前請先刪掉 `migratedToJsonV2.txt`（marker）讓遷移重跑。

- [ ] 只有 `zones.txt`（有內容）、無 `zones.json`
      **預期**：`zones.json` 出現且內容與 `zones.txt` 逐行相同；`migratedToJsonV2.txt` 產生；
      區域照 `zones.txt` 的內容顯示。`zones.txt` 保持原樣不被刪（Lua 無刪檔 API）。
- [ ] `zones.txt`（有內容）＋ `zones.json`（不同內容，模擬 42.19 舊副本）
      **預期**：`zones.json` 被 `zones.txt` 內容覆寫；覆寫前的舊內容原樣保留在
      `zones.premigrate.bak.json`。
- [ ] 只有 `zones.json`（有內容）、無 `zones.txt`（42.19 使用者直上 0.3.0）
      **預期**：`zones.json` **一位元組不動**、照常顯示；只多出 marker。
- [ ] marker 已存在後刪掉 `zones.json`（關服期間）
      **預期**：下次啟動重生四區域示範範本，**不會**從殘留的 `zones.txt` 復活舊資料。
- [ ] 遷移完成後（marker 已在）執行期刪 `zones.json`
      **預期**：≤ `PollIntervalSeconds` 內重生空範本（`{"zones": []}`），區域清空。

> 已知行為（刻意設計）：本包**不會**去猜既有的 `zones.json` 是不是 42.19 時代的舊檔。
> 若你在 0.2.0 期間刪過 `zones.txt` 來清空區域、且機器上還留著更早的 `zones.json`，
> 升級後會看到舊區域重新出現——直接編輯或清空 `zones.json` 即可（不做推論式刪除是為了
> 避免誤刪真實資料）。

---

> **MP 測試前置檢查（重要）**：確認整台機器**只有一個** PZ dedicated server 在跑
> （工作管理員搜 `java.exe`，或 PowerShell `Get-Process java`）。若殘留舊實例，新啟動的
> server 會綁不到 port（server-console.txt 出現 `Connection Startup Failed. Code: 5`）且
> `OnServerStarted` 不會觸發——本 MOD 的伺服器資料層完全不啟動，client 連到的其實是
> **舊 code 的殘留實例**，按鈕/指令都不會有反應；同時 SQLite 會噴
> `database is locked`。先 `Stop-Process -Name java -Force` 全清再開一個新 server。

---

## 4. 「顯示自訂區域圖層」總開關（契約 C3）

於統一設定視窗「圖層顯示」（或 ESC MOD 選項）操作：

- [ ] 關「**顯示自訂區域圖層**」總開關
      **預期**：整層都不畫（自訂區域消失），主 MOD 內建 POI 不受影響（若已開仍在）；重開恢復。
- [ ] 從 0.4.x 升級且先前關過「顯示伺服器區域」母開關的存檔
      **預期**：該開關已不存在、區域重新出現（舊值失效屬預期）；可用總開關關回。

> 內建 POI 的圖標/區塊/14 類別過濾與地標目測屬主 MOD 測試清單，見主 repo。

---

## 5. 效能觀感

- [ ] 有數十～數百個區域時，開關世界地圖、平移縮放
      **預期**：無明顯掉幀；provider 每幀只讀快取（不重建），切換開關才觸發一次重建。
- [ ] 長時間掛機（≥數分鐘），觀察 `console.txt` / `server-console.txt`
      **預期**：無每幀刷屏的 warning、無記憶體持續膨脹跡象。

---

## 回歸提醒（主 MOD 零回歸，US-009 自動化已背書，實機再抽驗）

- [ ] 只掛主 MOD（不掛本包）進世界
      **預期**：無「Zone 圖層」開關出現、zone 管線 dormant；金字塔標記/MapBounds/動物圖標/
      導航分享/LootMaps 相容等既有功能一切如常，`console.txt` 無新 error。
