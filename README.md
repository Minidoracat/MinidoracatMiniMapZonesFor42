# MinidoracatMiniMapZonesFor42

[Minidoracat MiniMap for B42](https://github.com/Minidoracat) 主 MOD 的**伺服器自訂區域 addon**：
伺服器端一份 `zones.json` 定義任意矩形區域，主 MOD 在小地圖與世界地圖上畫出半透明填色＋
框線＋置中名稱標籤。純資料 MOD——繪製、開關、統一設定視窗全在主 MOD
（`registerZoneProvider` / `registerZoneAction` API），本包只負責「資料從哪來」。

- **需要主 MOD**：`MinidoracatMiniMapFor42` **42.19.0-0.8.0 以上**（`require=` 確保
  存在與載入順序；版本過舊時本包版本守衛安靜降級，不 crash、不影響主 MOD 其餘功能）
- **本包版本**：`42.19.0-0.1.0`（Build 42.19.0+，單人／多人皆可用）

## 特色

- **伺服器自訂區域**：`Zomboid/Lua/MinidoracatMiniMapZones/zones.json` 定義區域，
  外部程式可直接寫入（活動範圍工具、重置區標記工具等）；伺服器驗證後即時廣播全體，
  輪詢間隔 sandbox 可調（`PollIntervalSeconds`，預設 60 秒）；新進玩家進服即同步全量
- **純地圖顯示**：區域僅為視覺標示，不含 PVP／安全區等任何遊戲機制
- **自動示範範本**：首次啟動自動生成四個示範區域（含多矩形 L 形），文字依伺服器語系
  （繁中／簡中／英／日）；執行期檔案被刪自動重生空範本
- **生成區域範本按鈕**：統一設定視窗語言下拉＋按鈕；確認視窗防誤按、現有檔先備份為
  `zones.json.<時間戳>.bak` 再覆寫；伺服器上需「管理模組」權限
- **`/reloadzones`**：管理員聊天指令，立即強制重讀＋全體廣播（單機走本地重讀）
- **`enabled` 欄位**：`"enabled": false` 保留座標暫時隱藏，不必刪除
- **壞資料容錯**：錯誤條目跳過並記錄，不影響其他區域；上限：總數 ≤500、
  單區域 rects ≤64

## 截圖

| | |
|---|---|
| ![伺服器自訂區域（小地圖示範）](docs/screenshots/server-zones-demo.png) | ![zones.json 範例](docs/screenshots/zones-json-example.png) |

## zones.json 格式

```json
{
  "zones": [
    {
      "name": "區域名稱（任意語言）",
      "rects": [[11882, 6928, 11918, 6961], [11918, 6961, 11950, 7000]],
      "fill": "#3B82F6",
      "fillAlpha": 0.3,
      "border": "#3B82F6",
      "borderAlpha": 0.9,
      "enabled": true
    }
  ]
}
```

- `rects`：`[[x1,y1,x2,y2], ...]` 世界 square 座標（左上到右下，x2>x1、y2>y1），
  一個區域可含多個矩形
- `fill`／`border`：`"#RRGGBB"` 或 `[r, g, b]`；`fillAlpha`／`borderAlpha` 0–1
  （缺省 fill 為紅、`alpha` 別名亦通）
- `enabled`：選填布林，省略＝`true`；`false`＝保留在檔案但不顯示
- 檔案以 UTF-8 讀取，任何語言文字皆可；改檔後等輪詢間隔或 `/reloadzones` 立即生效

## 開關（皆在主 MOD 統一設定視窗）

| 開關 | 預設 | 說明 |
|------|------|------|
| 顯示自訂區域圖層 | 開 | Zone 圖層總開關（有外部 provider 才出現） |
| 顯示伺服器區域 | 開 | 本包專屬母開關（per-provider） |

## 測試

- `lua scripts/tests/test_zones_lua.lua`：47 案例（validator 上限／分包／權限守衛／
  範本生成／備份語意／SP fallback）
- `python scripts/tests/test_tpl_strings.py`：四語範本常數與 UI.json 逐字鎖定
- 實機驗證清單見 [TESTING.md](TESTING.md)

## 家族專案

| MOD | 說明 |
|-----|------|
| MinidoracatMiniMapFor42 | 主 MOD（小地圖／世界地圖／圖標／POI／統一設定視窗） |
| MinidoracatMiniMapModMapsFor42 | 地圖 MOD 小地圖圖像包 |
| MinidoracatMiniMapCompatFor42 | 第三方 MOD 相容包 |
| MinidoracatMiniMapZonesFor42 | 本包——伺服器自訂區域 |
