# Ponytail 債務清冊

刻意簡化的紀錄，避免「以後再說」變成「永遠不做」。
重新產生：`grep -rn 'ponytail:' .`（或 `/ponytail-debt`）。

最後盤點：2026-11-11 — 5 markers, 4 with no trigger.

## MOD/.../42/media/lua/server/MinidoracatMiniMapZonesServer.lua

- **:64** per-player 冷卻表 `lastServedMs` 不清理斷線玩家
  - ceiling: 殘留有界（並發玩家數），量級小
  - upgrade: 未指定 — `no-trigger`
- **:249** 送包佇列用 `table.remove(q, 1)` 出隊
  - ceiling: O(n) 出隊；常態數包，重型檔加十幾位玩家同時進場可到數千包
  - upgrade: 佇列長到值得時換 head-index

## MOD/.../42/media/lua/shared/MinidoracatZonesShared.lua

- **:762** `readFileCapped` 逐行 `readLine` 讀檔（server/client/備份讀檔唯一實作）
  - ceiling: 行終止符不保留（寫回/驗證端一律以 "\n" 接回為準）
  - upgrade: 未指定 — `no-trigger`
- **:1073** 備份以 `concat("\n")` 逐行還原
  - ceiling: 行尾符/CRLF 不保留，僅保證「逐行內容一致」（JSON 可還原）
  - upgrade: 阻於平台 — Kahlua 無讀原始位元組 API — `no-trigger`

## scripts/sync_mod.ps1

- **:667** 判斷兩個目錄是否同一個時只比建立時間
  - ceiling: 不同目錄剛好建立時間相同時判 unknown（算忙碌、不殺），擋住並行輪次
  - upgrade: 實際遇到再升級成 Windows handle／file identity（volume serial＋file index）比對

## 判讀

shared:762 與 shared:1073 是同一平台限制的兩處紀錄，已寫入 AGENTS.md 契約 —
實質是既知限制，非可回收債務。`no-trigger` 中真正會爛的是 server:64：無界成長，只是成長很慢。
