-- MinidoracatMiniMapZonesClient.lua
-- Zones addon 的 client 層：向主 MOD 註冊「伺服器自訂區域」zone provider、
-- 接收伺服器廣播的自訂區域（分包重組）、/reloadzones 聊天糖衣。
--
-- 純自訂區域定位：內建 POI（原版地圖資源點）已於 0.8.0 搬進主 MOD 本體
-- MinidoracatMiniMapFor42，本 addon 不再處理 POI。本檔「只出資料」：所有繪製
-- （填色/框線/名稱/投影/裁切）都在主 MOD。母開關「顯示伺服器區域」由主 MOD 依
-- registerZoneProvider 第三參 optionLabelKey 動態追加於統一視窗（本檔不再自建 ModOptions）。
--
-- 引擎 API 佐證（禁止憑記憶寫 PZ Lua）：
--   Events.OnServerCommand 簽名 (module, command, args)＝ServerCommands.lua:183/194，
--     主 MOD 同用例 MinidoracatMiniMap.lua:3019。
--   sendClientCommand(player, module, command, args)＝主 MOD MinidoracatMiniMap.lua:2866/2894
--     （家族約定帶 playerObj；B42 SP 走 spnetwork loopback，OnClientCommand 單機亦觸發，
--      佐證主 MOD server 檔 MinidoracatMiniMapServer.lua:7）。
--   ISChat.onCommandEntered 以 ISChat.instance.textEntry:getText() 取指令、不吃 self；
--     textEntry 綁定於 createChildren（ISChat.lua:170）＝原版 Chat/ISChat.lua:onCommandEntered。
--   luautils.stringStarts / getTimestampMs / getText 皆原版 ISChat.lua 內用例。

local MODULE = "MinidoracatMiniMapZones"       -- ClientCommand / ServerCommand 模組名
local OWN_MOD_ID = "MinidoracatMiniMapZonesFor42"
local STALE_MS = 60000                          -- 未集滿批次逾時清理門檻（研究 §5：RELIABLE 無序）

--------------------------------------------------------------------------------
-- 契約 C1：版本守衛。require= 只保證主 MOD 存在、不保證版本。要求 0.8.0 完整 zone API——
-- registerZoneProvider（出資料）＋registerZoneAction（設定頁生成按鈕）＋zoneApiVersion==1
-- （契約版本鎖）。缺任一 → 印一次 log ＋整個 client 功能降級 no-op（早退，之後的 provider
-- 註冊/action/事件/聊天攔截全不掛載），不得 crash。
--------------------------------------------------------------------------------
if not (MinidoracatMiniMapAPI and MinidoracatMiniMapAPI.registerZoneProvider
    and MinidoracatMiniMapAPI.registerZoneAction and MinidoracatMiniMapAPI.zoneApiVersion == 1) then
    print("[" .. MODULE .. "] requires main MOD 42.19.0-0.8.0+ (zone API incomplete), disabled")
    return
end

--------------------------------------------------------------------------------
-- 狀態（module-level upvalue；closures 以參照捕捉，指派即所有讀取端可見）
--------------------------------------------------------------------------------
local serverZones = {}     -- 目前套用的伺服器自訂區域（已 unpack 正規化）；provider 直接回傳此參照
local pendingBatches = {}  -- { [bid] = { tot=, ts=, received=, total=, chunks={ [seq]=<已unpack陣列> } } }
local lastAppliedBid = 0   -- D1：已套用的最高 bid；拒絕 <= 此值的舊/重放 bid（無序封包防倒退）
local chatHookInstalled = false

-- 修正4：MP 下未集滿批次逾時（STALE_MS）丟棄後，補發一次 requestZones 重新索取全量——server 送包
-- 佇列滿時以整批淘汰（見 server enqueueFullSync），整批消失後 client 不會自動再收到（廣播只在
-- hash 變化時發）。本地冷卻避免 STALE 連環觸發洗版請求；server 端另有 3s per-player 冷卻不變。
local STALE_REREQUEST_COOLDOWN_MS = 10000
local lastStaleRequestMs = 0

-- SP fallback 狀態（US-006 定案：真 SP 下 server round-trip 不可能成立，見下方
-- spReadRawZones/spPollNow 區塊的完整證據註解）。spFallbackActive 於 OnGameStart 判定後
-- 定值，之後不再變動；spXxx 輪詢節奏變數僅在 spFallbackActive 為真時被讀寫。
local spFallbackActive = false
local spLastLen = nil
local spLastHash = nil
local spOversizeReported = false  -- C3：SP 超大檔 log-once 旗標
local spMissingRegenFailReported = false  -- SP 執行期檔案消失時空範本重生「失敗」的 log-once 旗標
local spPollIntervalSeconds = 60
local spLastPollMs = 0

-- D1 分包重組上限（防惡意 tot 撐爆記憶體）。必須 ≥ server 最壞分包數：server 按
-- 60000-byte wire 預算分包（enqueueFullSync），單 zone 上限＝單包預算 → 最壞每包
-- 恰 1 個 zone → tot ≤ zone 數 ≤ maxZones。綁共用真值使不變式結構成立（舊值 64
-- 在全合規的重型 zones.json 下會被超過 → 整批靜默丟棄，review 抓出）。記憶體上界
-- 不變：已組裝 zone 總數仍由 handleZoneData 的 batch.total>maxZones 閘封頂。
local MAX_BATCH_PACKETS = (MinidoracatZonesShared and MinidoracatZonesShared.LIMITS
    and MinidoracatZonesShared.LIMITS.maxZones) or 500

local function log(msg)
    print("[" .. MODULE .. "] " .. tostring(msg))
end

-- 本地提示（reloadResult / 送出指令回饋）：console 一律 print；有 HaloTextHelper
-- 就額外浮一則玩家可見「good」綠字。用兩參 addGoodText（佐證 ISReadABook.lua:95、
-- HaloTextHelper.java:131）。舊寫法 addText(player,text,getCore():getGoodHighlitedColor()) 會拋錯：
-- 唯一的三參 addText 多載是 addText(player,String,String separator)（HaloTextHelper.java:151），
-- 第三參要 String，傳 Core Color 物件無對應多載 → 拋錯（pcall 吞住但 Break-On-Error 攔到）。
-- addGoodText 內部走 getGoodColor() 產同一 good-highlite 綠且型別正確。pcall 續留防 API 漂移。
local function showLocalNote(text)
    local player = getPlayer()
    if player and HaloTextHelper and HaloTextHelper.addGoodText then
        pcall(function()
            HaloTextHelper.addGoodText(player, text)
        end)
    end
end

-- 契約 C2：providerFn 每幀被主 MOD 呼叫（世界＋小地圖 ×2），只回快取參照，不重建。
-- serverZones 於分包集滿 / SP 讀檔時整體原子替換，故直接回傳即為穩定快取；
-- 「顯示伺服器區域」母開關由主 MOD 端 gate（關＝渲染時整個 provider 跳過），本檔不再過濾。
local function zoneProvider()
    return serverZones
end

--------------------------------------------------------------------------------
-- 接收：zoneData（分包重組）＋ reloadResult
-- 分包協定（研究 §5）：args={bid,seq,tot,count,zones={wire...}}；ClientCommand RELIABLE
-- 但無序 → 按 bid 緩存 seq，集滿 tot 才「原子替換」serverZones，並丟棄其他未完成批次。
-- count＝本包 zone 數（Kahlua 無 nil 洞、勿依賴 #；仍以 nil-guard 兜住 count 與實陣列不一致）。
--------------------------------------------------------------------------------
local function handleZoneData(args)
    local bid, seq, tot = args.bid, args.seq, args.tot
    -- D1：bid/seq/tot 皆須為數字
    if type(bid) ~= "number" or type(seq) ~= "number" or type(tot) ~= "number" then
        return
    end
    -- tot 整數且合理上限；seq 整數且落在 1..tot（擋 seq=99/tot=1 套空集）
    if tot ~= math.floor(tot) or tot < 1 or tot > MAX_BATCH_PACKETS then return end
    if seq ~= math.floor(seq) or seq < 1 or seq > tot then return end
    -- 拒絕已套用的舊/重放 bid（無序封包時舊 bid 不得覆蓋新全量）
    if bid <= lastAppliedBid then return end

    local batch = pendingBatches[bid]
    if not batch then
        batch = { tot = tot, ts = getTimestampMs(), received = 0, total = 0, chunks = {} }
        pendingBatches[bid] = batch
    end

    if not batch.chunks[seq] then
        -- 本包就地 unpack，存正規化 zone 陣列（免集滿時再解一輪）。
        -- D5：count 僅作迭代上界，實際以逐項到齊為準；壞 wire 用 pcall 兜住不 crash（rc="bad"）。
        local wireList = args.zones
        if type(wireList) ~= "table" then wireList = {} end
        local n = args.count
        if type(n) ~= "number" or n ~= math.floor(n) or n < 0 then
            n = #wireList
        end
        local maxZones = MinidoracatZonesShared.LIMITS.maxZones
        if n > maxZones then n = maxZones end
        local chunk = {}
        for i = 1, n do
            local w = wireList[i]
            if type(w) == "table" then
                local ok, zone = pcall(MinidoracatZonesShared.unpackZone, w)
                if ok and type(zone) == "table" then
                    chunk[#chunk + 1] = zone
                end
            end
        end
        -- 單批 zone 總數上限：超限整批作廢（不套半套；防惡意 tot×count 撐爆）
        if batch.total + #chunk > maxZones then
            pendingBatches[bid] = nil
            return
        end
        batch.chunks[seq] = chunk
        batch.received = batch.received + 1
        batch.total = batch.total + #chunk
    end

    -- 集滿判定用實際到齊的 seq 數（batch.received），非信任任何單一 count 欄位（D5）
    if batch.received >= batch.tot then
        -- 集滿：依 seq 1..tot 串接 → 原子替換 serverZones
        local newZones = {}
        for s = 1, batch.tot do
            local chunk = batch.chunks[s]
            if chunk then
                for i = 1, #chunk do
                    newZones[#newZones + 1] = chunk[i]
                end
            end
        end
        serverZones = newZones -- 原子替換即快取更新（provider 回傳此參照）
        lastAppliedBid = bid  -- D1：記錄已套用 bid，後續舊 bid 一律拒絕
        pendingBatches = {}   -- 丟棄所有其他未完成批次（新全量已到，舊的作廢）
    end
end

local function handleReloadResult(args)
    local ok = args.ok
    if ok == nil then ok = true end
    local text
    if ok then
        text = getText("UI_MinidoracatMiniMapZones_ReloadResult", tostring(args.count or "?"))
    else
        -- D2：server 送的是 errors（複數陣列），取前幾條串接；相容舊 args.error（單數）
        local msg = ""
        local errs = args.errors
        if type(errs) == "table" and #errs > 0 then
            local parts = {}
            for i = 1, math.min(3, #errs) do parts[i] = tostring(errs[i]) end
            msg = table.concat(parts, "; ")
            if #errs > 3 then msg = msg .. " ...(+" .. (#errs - 3) .. ")" end
        elseif args.error ~= nil then
            msg = tostring(args.error)
        end
        text = getText("UI_MinidoracatMiniMapZones_ReloadFailed", msg)
    end
    log(text)
    showLocalNote(text)
end

-- 生成範本結果回饋（沿 reloadResult 顯示路徑：console log ＋玩家浮字）。三態：失敗（GenFailed）／
-- 已備份舊 zones.json 後寫入（GenResultBackup，帶 .bak 檔名）／直接寫入無備份（GenResult）。
local function handleGenerateResult(args)
    local ok = args.ok
    if ok == nil then ok = true end
    local text
    if not ok then
        text = getText("UI_MinidoracatMiniMapZones_GenFailed", tostring(args.path or "?"))
    elseif args.backedUp then
        -- bakName＝時間戳備份檔名（zones.<YYYYMMDD-HHMMSS>.bak.json，0.3.0 起；舊 server 無此欄位時退舊格式）
        text = getText("UI_MinidoracatMiniMapZones_GenResultBackup",
            tostring(args.bakName or (tostring(args.path or "zones.json") .. ".bak")))
    else
        text = getText("UI_MinidoracatMiniMapZones_GenResult", tostring(args.path or "?"))
    end
    log(text)
    showLocalNote(text)
end

--------------------------------------------------------------------------------
-- SP fallback：真單機下 server round-trip 不可能成立，client 直接讀檔（取代原
-- TODO(US-006)，主 agent 反編譯定案）：
--   全域 sendServerCommand 兩個 overload 皆 `if (GameServer.server)` 閘，SP 下 no-op
--   （LuaManager.java:8978-8992）；SP 去程可通（SinglePlayerServer.receiveClientCommand
--   觸發 OnClientCommand，SinglePlayerServer.java:197）但回程無 Lua 可及路徑——
--   SinglePlayerServer.sendServerCommand（:92-121）存在卻未 setExposed 給 Lua
--   （LuaManager.java 全文查無 setExposed(SinglePlayerServer)）。故 SP 下
--   sendClientCommand(requestZones/reloadZones) 送得出去，但伺服器端 sendServerCommand
--   廣播永遠到不了 Lua——OnServerCommand 在 SP 不會為此觸發，只能本地讀檔。
-- 讀檔路徑／1MB 早退／變化偵測邏輯照抄主 MOD server 檔
-- MinidoracatMiniMapZonesServer.lua 的 readRawZones/pollNow（getFileReader 出處
-- LuaManager.java:5919-5950（無副檔名白名單），root＝Zomboid/Lua/，兩端同一路徑
-- ＝MinidoracatZonesShared.zonesPath()）；hash 用共用的
-- MinidoracatZonesShared.djb2（server 檔已改呼叫同一函式，見該檔沿用註解）。
--------------------------------------------------------------------------------

-- 讀 zones.json 原始字串；三態同 server 端：nil=不存在(合法空集)、false=超過上限、string=內容
local function spReadRawZones()
    local path = MinidoracatZonesShared.zonesPath()
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local maxBytes = MinidoracatZonesShared.LIMITS.maxFileBytes
    local parts = {}
    local total = 0
    while true do
        local line = reader:readLine()
        if line == nil then break end
        -- C3：單行即超限就放棄（minified 單行 JSON 不繞過 gate）；log 移到 spPollNow（log-once）。
        -- 位元組估用 UTF-8 byte（非 code unit #），與 server readRawZones 一致。
        local lineBytes = MinidoracatZonesShared.utf8ByteLen(line)
        total = total + lineBytes + 1
        if lineBytes > maxBytes or total > maxBytes then
            reader:close()
            return false
        end
        parts[#parts + 1] = line
    end
    reader:close()
    return table.concat(parts, "\n")
end

-- force=true（/reloadzones 本地觸發）無視 hash 強制重讀。讀到即直接原子替換
-- serverZones＋標髒——重用既有 merged 快取重建路徑（時點 a，同 handleZoneData 集滿套用）。
-- 回傳 {ok, count, errors} 供 spReloadNow 接給既有 handleReloadResult 顯示路徑。
local function spPollNow(force)
    local raw = spReadRawZones()
    if raw == false then
        -- C3：log-once，避免每輪重複刷 console（檔案修好後 spReadRawZones 回非 false 才復位旗標）
        if not spOversizeReported then
            log("zones.json exceeds " .. MinidoracatZonesShared.LIMITS.maxFileBytes
                .. " bytes limit (SP fallback), load aborted (same state not logged again)")
            spOversizeReported = true
        end
        return { ok = false, count = #serverZones, errors = { "zones.json exceeds size limit" } }
    end
    spOversizeReported = false
    if raw == nil then
        -- SP 執行期檔案消失：重生「空範本」（區域清空但檔案隨時存在，保留「刪檔＝清空」語意）。
        -- 每輪只嘗試一次；成功記一條、失敗 log-once（不重試刷屏）。
        if MinidoracatZonesShared.ensureZonesTemplateEmpty() then
            spMissingRegenFailReported = false
            log("zones.json missing at runtime (SP fallback), regenerated empty template (zones cleared)")
        elseif not spMissingRegenFailReported then
            spMissingRegenFailReported = true
            log("zones.json missing and empty-template regen failed (SP fallback; getFileWriter unavailable?), continuing with empty set")
        end
        raw = ""
    end

    local newLen = #raw
    if not force then
        if newLen == spLastLen and spLastHash ~= nil and MinidoracatZonesShared.djb2(raw) == spLastHash then
            return { ok = true, count = #serverZones, errors = {} } -- 未變化，不套用
        end
    end
    spLastLen = newLen
    spLastHash = MinidoracatZonesShared.djb2(raw)

    local zones, errors
    -- 空字串／全空白（含 0-byte 空檔、外部工具存空緩衝殘留）視同空集：不 decode、不報 parse
    -- error，直接清空區域——消除空檔造成的 decode 噪音（檔案不存在則已於上方重生空範本）。
    -- 用 shared byte 掃描而非 pattern（Kahlua pattern 相容性，見 shared tplJsonEscape 註解）。
    if not MinidoracatZonesShared.hasNonBlank(raw) then
        zones, errors = {}, {}
    else
        local okDecode, decoded = pcall(MinidoracatZonesJson.decode, raw)
        if not okDecode then
            log("zones.json parse failed (SP fallback), keeping previous cache: " .. tostring(decoded))
            return { ok = false, count = #serverZones, errors = { tostring(decoded) } }
        end
        local result = MinidoracatZonesShared.validateZones(decoded)
        -- fatal（整檔壞：頂層非 table／zones 非陣列）→ 保留前一份快取，不清空。hash 已於上方記錄，
        -- 同壞檔下輪不再重 log（force 重讀時仍走此判斷、同樣保留快取）。
        if result.fatal then
            log("zones.json invalid (SP fallback, " .. tostring(result.errors[1]) .. "), keeping previous cache")
            return { ok = false, count = #serverZones, errors = result.errors }
        end
        zones, errors = result.zones, result.errors
    end

    serverZones = zones -- 原子替換即快取更新（fallback 一次到位，套用效果同 handleZoneData）
    for i = 1, #errors do log(errors[i]) end
    return { ok = true, count = #zones, errors = errors }
end

-- /reloadzones 在 SP 分支的處理：無 server 可轉發，立即本地強制重讀＋原地回饋
-- （複用既有 handleReloadResult，翻譯鍵與 MP 端共用，UX 一致只是同步觸發而非等回包）
local function spReloadNow()
    local result = spPollNow(true)
    -- D2：傳 errors（陣列）對齊 MP 端 handleReloadResult 讀法（不再用單數 error）
    handleReloadResult({ ok = result.ok, count = result.count, errors = result.errors })
end

-- 主 MOD 設定頁「生成範例檔」按鈕呼叫此全域（見下方 registerZoneAction 註冊）。
-- langCode: "current"/nil＝跟隨當前語系；"CH"/"CN"/"EN"/"JP"＝指定語系。
--   SP：直接本地生成（檔在本機），寫的是 zones.json 時順帶本地強制重讀讓區域立即更新；
--   MP：發 generateTemplate client command（伺服器權威，capability 驗證＋生成＋必要時 pollNow 廣播，
--        結果由 server 回 generateResult）。回饋沿 reloadResult 顯示路徑。
function MinidoracatZonesClient_GenerateTemplate(langCode)
    local code = langCode
    if code == "current" or code == "" then code = nil end
    if spFallbackActive then
        local gen = MinidoracatZonesShared.generateTemplateForLanguage(code)
        if gen.ok then spPollNow(true) end
        handleGenerateResult({ ok = gen.ok, path = gen.wrotePath, backedUp = gen.backedUp,
            bakName = gen.bakName, lang = code })
    else
        local player = getPlayer()
        if player then
            sendClientCommand(player, MODULE, "generateTemplate", { lang = code })
        end
        showLocalNote(getText("UI_MinidoracatMiniMapZones_GenSent"))
    end
end

-- 讀 sandbox（min 10 / max 3600 / default 60，同 sandbox-options.txt／server 檔
-- getPollInterval，nil-safe＋clamp 手法一致）
local function spGetPollInterval()
    local sb = SandboxVars and SandboxVars.MinidoracatMiniMapZones
    local v = sb and sb.PollIntervalSeconds
    if type(v) ~= "number" then return 60 end
    if v < 10 then return 10 end
    if v > 3600 then return 3600 end
    return v
end

--------------------------------------------------------------------------------
-- /reloadzones 聊天糖衣（研究 §4）：指令只是糖衣，信任邊界在 server 端 capability 檢查。
-- 保存原 ISChat.onCommandEntered，覆寫成先攔 /reloadzones → sendClientCommand 吞掉，
-- 否則轉呼原函式。原函式不吃 self（走 ISChat.instance），故 ... 透傳即可。
-- 同時補綁當前 live instance 的 textEntry（createChildren 於遊戲啟動前可能已跑，
-- textEntry.onCommandEntered 已捕捉舊參照，ISChat.lua:170）。
--------------------------------------------------------------------------------
local function installChatHook()
    if chatHookInstalled then return end
    if not (ISChat and ISChat.onCommandEntered) then return end
    chatHookInstalled = true

    local original = ISChat.onCommandEntered
    local function wrapper(...)
        local inst = ISChat.instance
        local command = inst and inst.textEntry and inst.textEntry:getText()
        if command and luautils.stringStarts(command, "/reloadzones") then
            if spFallbackActive then
                -- SP：無 server 可轉發，立即本地重讀＋回饋（見 spReloadNow 的證據註解）
                spReloadNow()
            else
                local player = getPlayer()
                if player then
                    sendClientCommand(player, MODULE, "reloadZones", {})
                end
                showLocalNote(getText("UI_MinidoracatMiniMapZones_ReloadSent"))
            end
            if inst.textEntry then inst.textEntry:setText("") end
            if inst.unfocus then inst:unfocus() end
            return
        end
        return original(...)
    end

    ISChat.onCommandEntered = wrapper
    if ISChat.instance and ISChat.instance.textEntry then
        ISChat.instance.textEntry.onCommandEntered = wrapper
    end
end

--------------------------------------------------------------------------------
-- 掛載：註冊 provider（檔載時即註冊，早於主 MOD OnGameBoot 對 provider 數的檢查）＋事件。
-- 第三參 optionLabelKey＝「顯示伺服器區域」：主 MOD 據此於統一視窗動態追加一顆 per-provider
-- 母開關（關＝渲染時整個跳過本 provider），取代舊本檔自建的 ServerZones ModOptions 選項。
--------------------------------------------------------------------------------
MinidoracatMiniMapAPI.registerZoneProvider(OWN_MOD_ID, zoneProvider,
    "UI_MinidoracatMiniMapZones_ServerZones")

-- 設定頁「生成範例檔」列（主 MOD 於「圖層顯示」伺服器區域 tick 之後渲染 [combo]+[按鈕]）。
-- registerZoneAction 由檔頭 C1 版本守衛保證存在（0.8.0 完整 zone API），此處直接註冊。
local GEN_LANG_LABEL_KEYS = {
    current = "UI_MinidoracatMiniMapZones_LangCurrent",
    CH = "UI_MinidoracatMiniMapZones_LangCH",
    CN = "UI_MinidoracatMiniMapZones_LangCN",
    EN = "UI_MinidoracatMiniMapZones_LangEN",
    JP = "UI_MinidoracatMiniMapZones_LangJP",
}
MinidoracatMiniMapAPI.registerZoneAction(OWN_MOD_ID, {
    labelKey = "UI_MinidoracatMiniMapZones_GenTemplate",
    tooltipKey = "UI_MinidoracatMiniMapZones_GenTemplate_tooltip",
    options = {
        { value = "current", labelKey = "UI_MinidoracatMiniMapZones_LangCurrent" },
        { value = "CH", labelKey = "UI_MinidoracatMiniMapZones_LangCH" },
        { value = "CN", labelKey = "UI_MinidoracatMiniMapZones_LangCN" },
        { value = "EN", labelKey = "UI_MinidoracatMiniMapZones_LangEN" },
        { value = "JP", labelKey = "UI_MinidoracatMiniMapZones_LangJP" },
    },
    onTrigger = function(value)
        -- 覆寫前二次確認（vanilla yes/no 模式：ISAnimalContextMenu.lua:1118-1120）。
        -- new(0,0) 自動置中於滑鼠、CalcSize 依多行文字擴框（ISModalDialog.lua:188-207）；
        -- onclick 收 (target, button)，button.internal=="YES"（ISModalDialog.lua:58-64）。
        local langLabel = getText(GEN_LANG_LABEL_KEYS[value] or GEN_LANG_LABEL_KEYS.current)
        -- 帶參 getText 在翻譯值含真換行時會因引擎 %1 轉換失效（Translator.java:251
        -- matches 不跨行）而丟格式例外、Lua 端拿到 nil——翻譯故用字面 \n（vanilla 慣例，
        -- ISModalDialog:new :188 會轉真換行）；此處仍 fallback 到無參版（永不回 nil）保底。
        local confirmMsg = getText("UI_MinidoracatMiniMapZones_GenConfirm", langLabel)
            or getText("UI_MinidoracatMiniMapZones_GenConfirm")
        local modal = ISModalDialog:new(0, 0, 350, 150,
            confirmMsg, true, nil,
            function(_, button)
                if button.internal == "YES" then
                    MinidoracatZonesClient_GenerateTemplate(value)
                end
            end)
        modal:initialise()
        modal:addToUIManager()
    end,
})

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or type(args) ~= "table" then return end
    if command == "zoneData" then
        handleZoneData(args)
    elseif command == "reloadResult" then
        handleReloadResult(args)
    elseif command == "generateResult" then
        handleGenerateResult(args)
    end
end)

-- SP fallback 的 <60s 輪詢秒級計時掛在 OnTick（同 server 檔 onTick 的
-- pollIntervalSeconds<60 分支做法）。MP 下此 handler 每幀 O(1) 早退。
Events.OnTick.Add(function()
    -- D4：SP 輪詢一律用 wall-clock 現實秒（getTimestampMs），不用 EveryOneMinute 遊戲分鐘
    if spFallbackActive then
        local now = getTimestampMs()
        if now - spLastPollMs >= spPollIntervalSeconds * 1000 then
            spLastPollMs = now
            spPollNow(false)
        end
    end
end)

-- 60 秒未集滿批次清理（先蒐集過期 bid 再刪，避免 pairs 迭代中改表）。
-- D4：SP 輪詢已改由 OnTick wall-clock 計時，此處不再做分鐘計數輪詢。
Events.EveryOneMinute.Add(function()
    local now = getTimestampMs()
    local expired
    for bid, batch in pairs(pendingBatches) do
        if now - batch.ts > STALE_MS then
            expired = expired or {}
            expired[#expired + 1] = bid
        end
    end
    if expired then
        for i = 1, #expired do
            pendingBatches[expired[i]] = nil
        end
        -- 修正4：MP 下整批逾時多半是 server 佇列淘汰整批所致 → 補發 requestZones 重新索取全量
        -- （帶本地冷卻，避免連環洗版）。SP fallback 直接本地讀檔、無 server round-trip，不需重請求。
        if not spFallbackActive and (now - lastStaleRequestMs) >= STALE_REREQUEST_COOLDOWN_MS then
            local player = getPlayer()
            if player then
                lastStaleRequestMs = now
                sendClientCommand(player, MODULE, "requestZones", {})
            end
        end
    end
end)

Events.OnGameStart.Add(function()
    -- D3：跨世界/切伺服器重置——serverZones、未完成批次、變化偵測基準、lastAppliedBid 全在
    -- module scope，不清會殘留前一世界 zones 或讓新伺服器的低 bid 被 lastAppliedBid 拒收。
    serverZones = {}
    pendingBatches = {}
    lastAppliedBid = 0
    spLastLen = nil
    spLastHash = nil
    spOversizeReported = false
    spMissingRegenFailReported = false

    -- 真 SP 判定（US-006 定案）：not isClient() and not isServer()。MP 分支行為完全不變。
    spFallbackActive = not isClient() and not isServer()

    if spFallbackActive then
        -- SP：requestZones 送出後沒有 Lua 可及的回程（見 spPollNow 區塊證據），
        -- 改為本地首次讀取＋掛本地輪詢節奏。
        spPollIntervalSeconds = spGetPollInterval()
        spLastPollMs = getTimestampMs()
        -- 0.2.0→0.3.0 一次性 legacy 遷移的可見性 log（遷移本體在 ensureZonesTemplate 內
        -- 也會跑，session 快取使真實 IO 只執行一次；與 server 端 log 對稱）
        local okMig, mig = pcall(MinidoracatZonesShared.migrateLegacyZones)
        if okMig and mig == "migrated" then
            log("legacy zones.txt migrated to zones.json (one-time; 42.20.1 re-allowed the .json extension)")
        elseif okMig and mig == false then
            log("legacy zones.txt migration FAILED (oversize/IO/verify), will retry next launch")
        elseif not okMig then
            log("legacy migration raised: " .. tostring(mig))
        end
        -- 首次進世界：zones.json 不存在時寫一份含四個示範區域的範本（見 shared ensureZonesTemplate）
        -- ——SP 進世界就看得到／照著改；失敗僅 log 一條照常讀現況。MP client 絕不呼叫（伺服器權威）。
        if not MinidoracatZonesShared.ensureZonesTemplate() then
            log("zones.json template creation failed (getFileWriter unavailable?), reading current state as-is")
        end
        spPollNow(true)
        log("SP fallback active, local poll interval " .. spPollIntervalSeconds .. "s")
    else
        -- MP：進場請求當前全量（server 端 requestZones handler 對新進玩家送全量，AC-1）。
        local player = getPlayer()
        if player then
            sendClientCommand(player, MODULE, "requestZones", {})
        end
    end

    -- /reloadzones 聊天攔截（此時 ISChat live instance 已建立，一併補綁 textEntry）
    installChatHook()
end)
