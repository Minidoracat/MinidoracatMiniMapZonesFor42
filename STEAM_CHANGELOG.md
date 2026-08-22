[h1]Minidoracat MiniMap Zones 42.20.1-0.5.0[/h1]
[i]2026-08-22[/i]

[h3]• 修復[/h3]
[list]
[*] [b]MP 重登後整場看不到自訂區域[/b]（正式服實證）：進場的全量請求原本只在OnGameStart 送一次——該時點 MP 連線未必就緒（onlineId 尚未指派、GameClient.ingame尚未 true），sendClientCommand 可能靜默丟失；而既有補發機制只在「收到過部分分包」時觸發，初始請求丟失＝永不補發、整場空區域。生成範本／/reloadzones 當下看得到（走伺服器主動廣播）、重登即消失（走此請求）正是此因。改為 OnTick 等連線就緒（getOnlineID）後送出、每 10 秒重送直到收到伺服器回應（上限 12 次；同 process 重登會重置重試狀態），沿主 MOD SteamIdReport 同款先例。純客戶端修正，與任何版本的伺服器端相容。
[/list]

[h3]• 調整[/h3]
[list]
[*] [b]移除「顯示伺服器區域」母開關[/b]：與主 MOD「顯示自訂區域圖層」總開關作用完全重疊（本包是家族唯一 zone provider，兩顆相鄰的等效開關只造成困惑——實測回饋）。註冊時不再傳 optionLabelKey，主 MOD 不再生成這顆開關；區域顯示改由總開關單獨控制。先前關過此開關的玩家升級後區域會重新出現（舊設定值失效屬預期），用「顯示自訂區域圖層」關回即可。主 MOD 的 per-provider 開關機制保留（未來第三方區域 addon 仍可用）。對主 MOD 版本無新要求。
[/list]
