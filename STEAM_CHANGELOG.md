[h1]Minidoracat MiniMap Zones 42.22.2-0.7.0[/h1]
[i]2026-11-11[/i]

[b]English summary[/b]
[list]
[*] The custom zone limit is raised from 500 to 2000 visible zones per server.
[*] The zone file must still stay under about 1 MB. A larger file is not loaded at all, so save it without indentation when you have many zones.
[*] The more zones on screen at once, the more the map costs. Zooming all the way out with over a thousand zones visible lowers the frame rate noticeably.
[*] Server and players must all update to this version. Restart the server after updating; the zone file needs no changes.
[*] Checked against game Build 42.22.2.
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]自訂區域數量上限從 500 個提高到 2000 個[/b]：伺服器設定的顯示中區域超過 500 個時，第 501 個起原本不會出現在地圖上。現在最多顯示 2000 個，設成停用的區域照舊不計入。
[*] [b]區域檔大小上限不變（約 1 MB）[/b]：區域很多時會先碰到這個上限，超過時整個區域檔不會載入，請存成不縮排的格式。每個區域最多 64 個矩形也不變。
[*] [b]區域很多時的效能[/b]：同時在畫面裡的區域越多，地圖越吃效能。區域分散時，一般遊玩的縮放只畫畫面內的區域，影響很小；把地圖拉到最遠、上千個區域同時在畫面裡時，幀率會明顯下降。
[*] [b]伺服器與玩家都要更新到這一版[/b]：伺服器更新後重啟生效，區域檔不用改。玩家的 MOD 版本和伺服器不同時，可能進不了伺服器，或進得去但地圖上看不到自訂區域；更新 MOD 後重新進伺服器即可。
[*] 對應遊戲 Build 42.22.2：已確認區域讀寫、同步與指令在 42.22.2 下運作不受影響。
[/list]
