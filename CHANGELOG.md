# Changelog

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
