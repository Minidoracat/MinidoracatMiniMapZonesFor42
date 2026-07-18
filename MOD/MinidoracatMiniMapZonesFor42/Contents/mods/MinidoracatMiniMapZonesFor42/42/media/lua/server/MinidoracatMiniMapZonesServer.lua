-- MinidoracatMiniMapZonesServer.lua — 伺服器權威資料層（讀 zones.json → 驗證 → 分包廣播）
--
-- 職責：讀 Zomboid/Lua/MinidoracatMiniMapZones/zones.json（外部程式可寫＝信任邊界）、
-- 逐輪輪詢偵測變化、驗證後快取、對客戶端全量分包廣播；admin `/reloadzones` 強制重讀。
-- 繪製、開關 UI、provider 註冊全在主 MOD／本包 client——本檔只碰檔案 IO＋網路。
--
-- 只在 isServer() 時運作（dedicated server / MP host）；SP 路徑由本包 client fallback
-- 處理（US-006 定案），本檔在 SP 完全 dormant——輪詢與 OnClientCommand 皆 isServer() 閘。
--
-- 引擎 API 出處（AGENTS.md 鐵則：禁憑記憶寫 PZ API）：
--   getFileReader(filename, createIfNull) → LuaManager.java:5844-5870
--     · root = getLuaCacheDir()（Zomboid/Lua/）；filename 內 `/` 與 `\` 皆被 normalize 成
--       File.separator（:5849-5850）——所以 separator 其實引擎會統一，但仍照 AGENTS.md 鐵則
--       用 getFileSeparator() 組路徑
--     · createIfNull=false 且檔不存在 → 回 null（:5868-5869）＝合法空區域集，非錯誤
--     · UTF-8 讀取（:5861）
--   reader:readLine() 迴圈＋reader:close() → ISUIEmoteConfig.lua:121-136
--   getFileSeparator() → WorkshopSubmitScreen.lua:41、LoadGameScreen.lua:338
--   isServer() → server/Farming/SPlantGlobalObject.lua:51、server/XpSystem/XpUpdate.lua:168
--   sendServerCommand(module,cmd,args) 廣播版 → server/BuildingObjects/ISEmptyGraves.lua:47
--   sendServerCommand(player,module,cmd,args) 對單一玩家 → server/ClientCommands.lua:453
--   Events.OnClientCommand(module,command,player,args) → 家族 MinidoracatMiniMapServer.lua:57
--       ＋ ClientCommands.lua:1246-1257 簽名
--   Events.OnServerStarted → shared/Fishing/fishing_properties.lua:76、shared/Util/LuaNet.lua:288
--   Events.EveryOneMinute → server/Camping/SCampfireSystem.lua:183
--   getTimestampMs()（毫秒）→ client/Vehicles/TimedActions/ISHorn.lua:10、ISSearchManager.lua:112
--   player:getRole():hasCapability(Capability.ManipulateMods)
--       · 伺服器端 hasCapability 用例 → server/ClientCommands.lua:646
--       · Capability.ManipulateMods 存在 → commands/serverCommands/CheckModsNeedUpdate.java:19
--       · Role.hasCapability(Capability) → characters/Role.java:185
--
-- 分包協定（研究報告 §5）：ClientCommand RELIABLE 但無序 → 自描述 {bid,seq,tot,count}，
-- client 按 bid 緩存 seq、集滿 tot 原子替換；每包 ≤150 zone（≈64KB，遠離 1MB 死鎖線）；
-- 每 tick ≤2 包節流（送包佇列＋OnTick 消化，勿一次全噴）。

local MODULE = "MinidoracatMiniMapZones"
local MAX_ZONES_PER_PACKET = 150   -- 每包 zone 數硬上限（byte budget 為主，此為次要保底）
local MAX_PACKETS_PER_TICK = 2     -- 送包節流：每 tick 最多 2 包
local MAX_RELOAD_ERRORS = 30       -- reloadResult 回傳的錯誤訊息上限（防 payload 膨脹）
local MAX_SEND_QUEUE = 128         -- 送包佇列硬上限（C1：滿則丟最舊並 log，防 DoS 無界成長）
local REQUEST_COOLDOWN_MS = 3000   -- 單玩家 requestZones 冷卻（C1：<3s 重複請求忽略）

-- 廣播 target 的 sendQueue/coalescing key sentinel（nil 不能當 table key）
local BROADCAST = {}

-- 伺服器權威快取（分包一律從此出；validateZones 的正規化輸出形狀）
local zoneCache = {}
local zoneCacheCount = 0

-- 變化偵測：先比長度、長度同才算 djb2（省掉未變檔的 hash 成本）
local lastLen = nil
local lastHash = nil
local oversizeReported = false     -- C3：超大檔 log-once 旗標（避免每輪重 log）
local missingRegenFailReported = false  -- 執行期檔案消失時空範本重生「失敗」的 log-once 旗標
local translatorResyncFailReported = false  -- Task 3：語系重同步失敗的 log-once 旗標

-- 送包佇列（OnTick 消化）；每項 { target = player|nil(廣播), args = {...} }
local sendQueue = {}
local batchCounter = 0

-- C1：per-player requestZones 冷卻表（[player]=last-served ms）。以 player 物件為 key
-- （session 內穩定參照，免動用未證實的 getUsername）；斷線殘留有界（並發玩家數），
-- ponytail: 不特別清，量級小
local lastServedMs = {}

-- 輪詢節奏（OnServerStarted 時定案）；C2：一律 wall-clock（getTimestampMs）計時
local pollIntervalSeconds = 60
local lastPollMs = 0

local function log(msg)
    print("[MinidoracatMiniMapZones] " .. tostring(msg))
end

-- 廣播 target(nil) 與單玩家 target 統一成可當 table key 的值
local function keyOf(target)
    if target == nil then return BROADCAST end
    return target
end

-- djb2 hash 移至 MinidoracatZonesShared.djb2（client SP fallback 本地輪詢共用同一份，
-- US-006 SP fallback 新增；見 shared 檔尾段），本檔不再自帶一份。

-- 讀 sandbox（min 10 / max 3600 / default 60，見 sandbox-options.txt）；nil-safe＋clamp
local function getPollInterval()
    local sb = SandboxVars and SandboxVars.MinidoracatMiniMapZones
    local v = sb and sb.PollIntervalSeconds
    if type(v) ~= "number" then return 60 end
    if v < 10 then return 10 end
    if v > 3600 then return 3600 end
    return v
end

-- 讀 zones.json 原始字串。回傳值三態：
--   string → 檔案內容（可能 ""）；nil → 檔不存在（合法空集）；false → 超過 1MB（放棄本輪）
-- 邊讀邊累加長度、超 maxFileBytes 立即放棄（防外部無界輸入把整檔灌進記憶體）。
local function readRawZones()
    local path = "MinidoracatMiniMapZones" .. getFileSeparator() .. "zones.json"
    local reader = getFileReader(path, false)
    if not reader then return nil end  -- 檔不存在＝合法空集
    local maxBytes = MinidoracatZonesShared.LIMITS.maxFileBytes
    local parts = {}
    local total = 0
    while true do
        local line = reader:readLine()
        if line == nil then break end
        -- C3：單行即超限就放棄（minified 單行 JSON 不讓它繞過 size gate）；
        -- 逐行累加也擋多行超大檔。log 移到 pollNow（log-once），此處只回 false。
        -- 位元組估用 UTF-8 byte（非 code unit #）：CJK 名稱多的檔以真實 byte 計，貼近檔案大小。
        local lineBytes = MinidoracatZonesShared.utf8ByteLen(line)
        total = total + lineBytes + 1  -- +1 補 readLine 去掉的換行
        if lineBytes > maxBytes or total > maxBytes then
            reader:close()
            return false
        end
        parts[#parts + 1] = line
    end
    reader:close()
    return table.concat(parts, "\n")
end

local function nextBid()
    batchCounter = batchCounter + 1
    return batchCounter
end

-- C1 coalescing：移除佇列中同 target 尚未送出的舊全量包。新全量 bid 較新、client 以
-- lastAppliedBid 取捨，舊包留著只是佔佇列＋送過時資料；同時天然擋同 target 重複請求堆疊。
local function purgeQueuedFor(target)
    local k = keyOf(target)
    local kept = {}
    for i = 1, #sendQueue do
        if keyOf(sendQueue[i].target) ~= k then
            kept[#kept + 1] = sendQueue[i]
        end
    end
    sendQueue = kept
end

-- 從快取組全量分包，入送包佇列。target=nil → 廣播；target=player → 對該玩家。
-- 空快取仍送一包（tot=1,count=0,zones={}）→ client 原子套用空集（檔案刪除→客戶端清空）。
-- B1：以 wire byte budget（maxPacketWireBytes）分包，非只數 zone 數——單 zone 已於
-- validateZones 保證 <= maxZoneWireBytes <= budget，確保任一包遠低於引擎 1MB buffer。
local function enqueueFullSync(target)
    purgeQueuedFor(target)  -- C1：同 target 舊全量作廢，換上新的

    local zones = zoneCache
    local n = #zones
    local budget = MinidoracatZonesShared.LIMITS.maxPacketWireBytes
    local packets = {}
    if n == 0 then
        packets[1] = {}
    else
        local pkt = {}
        local pktBytes = 0
        for i = 1, n do
            local wire = MinidoracatZonesShared.packZone(zones[i])
            local wb = MinidoracatZonesShared.wireBytes(wire)
            -- 現包非空且加入會爆 byte budget 或到達 zone 數上限 → 先封包、開新包
            if #pkt > 0 and (pktBytes + wb > budget or #pkt >= MAX_ZONES_PER_PACKET) then
                packets[#packets + 1] = pkt
                pkt = {}
                pktBytes = 0
            end
            pkt[#pkt + 1] = wire
            pktBytes = pktBytes + wb
        end
        if #pkt > 0 then packets[#packets + 1] = pkt end
    end
    local bid = nextBid()
    local tot = #packets
    for i = 1, tot do
        sendQueue[#sendQueue + 1] = {
            target = target,
            args = { bid = bid, seq = i, tot = tot, count = #packets[i], zones = packets[i] },
        }
    end
    -- C1：送包佇列硬上限——以「整批」為淘汰單位（非逐包）。逐包丟最舊會把某廣播批次的前段 seq
    -- 丟掉、留下殘缺批次，client 永遠集不滿又收不到重送（廣播只在 hash 變化時發）→ 該 client 停在
    -- 舊區域。改為整批淘汰：取最舊 entry 的 (target,bid)，移除佇列中所有同批 entry，重複到佇列回落
    -- 上限內。整批消失可被 client STALE 逾時後重發 requestZones 補救，殘缺批次則不會。
    while #sendQueue > MAX_SEND_QUEUE do
        local oldest = sendQueue[1]
        local dropKey = keyOf(oldest.target)
        local dropBid = oldest.args.bid
        local kept = {}
        local dropped = 0
        for i = 1, #sendQueue do
            local e = sendQueue[i]
            if keyOf(e.target) == dropKey and e.args.bid == dropBid then
                dropped = dropped + 1
            else
                kept[#kept + 1] = e
            end
        end
        sendQueue = kept
        log("send queue exceeded " .. MAX_SEND_QUEUE .. ", dropped whole batch bid=" .. tostring(dropBid)
            .. " (" .. dropped .. " packet(s)) (requestZones overload?)")
    end
end

-- 讀檔 → 變化偵測 → decode → validate → 更新快取 → 廣播。
-- force=true（admin /reloadzones）無視 hash 強制重讀。回 { ok, count, errors }。
local function pollNow(force)
    local raw = readRawZones()
    if raw == false then
        -- 超大檔：放棄本輪、不動快取/hash（外部修檔後長度變→下輪自然重試）。
        -- C3：log-once，避免每輪重複刷 console（檔案修好後 readRawZones 回非 false 才復位旗標）
        if not oversizeReported then
            log("zones.json exceeds " .. MinidoracatZonesShared.LIMITS.maxFileBytes
                .. " bytes limit, load aborted (same state not logged again)")
            oversizeReported = true
        end
        return { ok = false, count = zoneCacheCount, errors = { "zones.json exceeds size limit" } }
    end
    oversizeReported = false
    if raw == nil then
        -- 執行期檔案消失：重生「空範本」（區域清空但檔案隨時存在，保留「刪檔＝清空」語意）。
        -- 每輪只嘗試一次；成功記一條、失敗 log-once（不重試刷屏）。pcall 已在 ensureZonesTemplateEmpty 內。
        if MinidoracatZonesShared.ensureZonesTemplateEmpty() then
            missingRegenFailReported = false
            log("zones.json missing at runtime, regenerated empty template (zones cleared)")
        elseif not missingRegenFailReported then
            missingRegenFailReported = true
            log("zones.json missing and empty-template regen failed (getFileWriter unavailable?), continuing with empty set")
        end
        raw = ""  -- 以空內容續行（清空區域）
    end

    local newLen = #raw
    if not force then
        if newLen == lastLen and lastHash ~= nil and MinidoracatZonesShared.djb2(raw) == lastHash then
            return { ok = true, count = zoneCacheCount, errors = {} }  -- 未變化，不廣播
        end
    end
    -- 走到這＝已變化（或 force）；更新 hash 基準（decode 失敗也更新，避免壞檔每輪重 log）
    lastLen = newLen
    lastHash = MinidoracatZonesShared.djb2(raw)

    local zones, errors
    local disabledCount = 0
    -- 空字串／全空白（含 0-byte 空檔、外部工具存空緩衝殘留）視同空集：不 decode、不報 parse
    -- error，直接清空區域——消除空檔造成的 decode 噪音（檔案不存在則已於上方重生空範本）。
    -- 用 shared byte 掃描而非 pattern（Kahlua pattern 相容性，見 shared tplJsonEscape 註解）。
    if not MinidoracatZonesShared.hasNonBlank(raw) then
        zones, errors = {}, {}
    else
        local okDecode, decoded = pcall(MinidoracatZonesJson.decode, raw)
        if not okDecode then
            log("zones.json parse failed, keeping previous cache: " .. tostring(decoded))
            return { ok = false, count = zoneCacheCount, errors = { tostring(decoded) } }
        end
        local result = MinidoracatZonesShared.validateZones(decoded)
        -- fatal（整檔壞：頂層非 table／zones 非陣列）→ 保留前一份快取，不清空不廣播。hash 已於上方
        -- 記錄，同壞檔下輪不再重 log（force 重讀時仍會走此判斷、同樣保留快取）。
        if result.fatal then
            log("zones.json invalid (" .. tostring(result.errors[1]) .. "), keeping previous cache")
            return { ok = false, count = zoneCacheCount, errors = result.errors }
        end
        zones, errors = result.zones, result.errors
        disabledCount = result.disabledCount or 0
    end

    -- 原子替換快取
    zoneCache = zones
    zoneCacheCount = #zones
    for i = 1, #errors do
        log(errors[i])
    end
    -- 載入摘要：enabled:false 的 zone 計入 disabledCount，>0 時才顯示 disabled 段（Y=0 省略維持簡潔）。
    local summary = "zones.json loaded " .. zoneCacheCount .. " zone(s) ("
    if disabledCount > 0 then
        summary = summary .. disabledCount .. " disabled, "
    end
    log(summary .. #errors .. " warning(s))")

    enqueueFullSync(nil)  -- 全體廣播
    return { ok = true, count = zoneCacheCount, errors = errors }
end

-- OnTick：消化送包佇列（≤2 包/tick）＋輪詢計時。C2：一律用 wall-clock 現實秒
-- （getTimestampMs），不用 EveryOneMinute 的遊戲分鐘——後者受時間倍率/快轉影響，
-- sandbox 標「秒」會嚴重失準（已驗 GameTime.java:648 EveryOneMinute 由 world-time 觸發）。
local function onTick()
    if not isServer() then return end
    local sent = 0
    while sent < MAX_PACKETS_PER_TICK and #sendQueue > 0 do
        -- ponytail: table.remove(,1) O(n)；佇列僅數包，長到值得換 head-index 再說
        local job = table.remove(sendQueue, 1)
        if job.target then
            sendServerCommand(job.target, MODULE, "zoneData", job.args)
        else
            sendServerCommand(MODULE, "zoneData", job.args)
        end
        sent = sent + 1
    end
    local now = getTimestampMs()
    if now - lastPollMs >= pollIntervalSeconds * 1000 then
        lastPollMs = now
        pollNow(false)
    end
end

-- Task 3：修正原版伺服器 init 排序 quirk 造成範本語言錯誤（使用者實測：伺服器生成範本為英文）。
-- 根因（反編譯定案）：ServerOptions.init() 先 initOptions()（ServerOptions.java:246 呼 Translator.getText）
--   → 此刻 options.ini 未載入 → Translator 語言解析走系統 locale（Core.java:1420-1421：optionLanguageName
--   空時取 System.getProperty("user.language").toUpperCase()＝"ZH"）≠ PZ 的 "CH" → fallback EN 並把
--   Translator.language 快取定案；:263 Core.loadOptions() 才載入 options.ini 的 language=CH——太遲，
--   Translator.language 已定案 EN 不再重解析 → 範本走 EN fallback。
-- 補救：比對「選項語言」getCore():getOptionLanguageName()（Core.java:4449，回傳 option 值即 "CH"）與
--   「目前生效語言」Translator.getLanguage():name()（Language.name()＝語言碼，Language.java:19）。
--   Translator/Language 皆對 Lua 曝露（setExposed，LuaManager.java:1839,1842）。兩者不一致＝被 quirk
--   卡在 EN → Translator.loadFiles()（public static，開頭 language=null 重解析，Translator.java:161-162；
--   此時 optionLanguageName 已是 CH → 正確解析＋重載全部翻譯含本 mod UI.json）。
-- 全段 pcall，失敗＝維持英文 fallback（無害）＋log-once；SP 不需要（client 端語言本就正確）。
local function resyncTranslatorLanguage()
    local ok, err = pcall(function()
        local core = getCore and getCore()
        local optName = core and core:getOptionLanguageName()
        local cur = Translator and Translator.getLanguage and Translator.getLanguage()
        local curName = cur and cur:name()
        if optName and curName and optName ~= curName then
            Translator.loadFiles()
            log("translator language re-synced to " .. tostring(optName) .. " (server init ordering quirk)")
        end
    end)
    if not ok and not translatorResyncFailReported then
        translatorResyncFailReported = true
        log("translator language re-sync failed, keeping current language: " .. tostring(err))
    end
end

-- 首次載入：OnServerStarted（server-only 啟動 event）暖快取＋掛輪詢
Events.OnServerStarted.Add(function()
    if not isServer() then return end
    pollIntervalSeconds = getPollInterval()
    lastPollMs = getTimestampMs()
    -- Task 3：範本生成前先修正原版 init 排序 quirk，讓刪檔重生的範本用正確語系（繁中）而非
    -- 被卡死的 EN fallback（見上方 resyncTranslatorLanguage 註解與反編譯佐證）。
    resyncTranslatorLanguage()
    -- 首次啟動：zones.json 不存在時寫一份含四個示範區域的範本（見 shared ensureZonesTemplate），
    -- 讓伺服器一開就有東西可看／照著改；失敗（getFileWriter 不可用等）僅 log 一條照常暖讀
    if not MinidoracatZonesShared.ensureZonesTemplate() then
        log("zones.json template creation failed (getFileWriter unavailable?), loading current state as-is")
    end
    pollNow(true)  -- 強制首讀（此時尚無 client，廣播為 no-op，僅暖快取）
    Events.OnTick.Add(onTick)  -- C2：輪詢改由 OnTick wall-clock 計時，不再掛 EveryOneMinute
    log("server data layer started, poll interval " .. pollIntervalSeconds .. "s")
end)

-- OnClientCommand dispatcher（isServer() 閘：SP 由 client fallback 處理，且防 SP loopback
-- 讓送包佇列在無 OnTick drainer 時無界成長）
Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE then return end
    if not isServer() then return end
    if not player then return end

    if command == "requestZones" then
        -- C1：per-player 冷卻，<3s 內重複請求忽略（防 DoS：每次全快取重打包＋佇列膨脹）
        local now = getTimestampMs()
        local last = lastServedMs[player]
        if last and (now - last) < REQUEST_COOLDOWN_MS then return end
        lastServedMs[player] = now
        -- 新進玩家中途進服 → 送當前快取全量（AC-1）。同玩家舊全量由 enqueueFullSync 內 purge coalescing。
        enqueueFullSync(player)

    elseif command == "reloadZones" then
        -- 信任邊界：第一行權限守衛（研究 §4）
        local role = player:getRole()
        if not (role and role:hasCapability(Capability.ManipulateMods)) then return end
        local result = pollNow(true)  -- 強制重讀＋全體廣播
        local errs = {}
        for i = 1, #result.errors do
            if i > MAX_RELOAD_ERRORS then
                errs[#errs + 1] = "...and " .. (#result.errors - MAX_RELOAD_ERRORS) .. " more (see server-console.txt)"
                break
            end
            errs[i] = result.errors[i]
        end
        sendServerCommand(player, MODULE, "reloadResult",
            { ok = result.ok, count = result.count, errors = errs })

    elseif command == "generateTemplate" then
        -- 信任邊界：比照 reloadZones 的權限守衛（檔案在伺服器上，client 只是發起）
        local role = player:getRole()
        if not (role and role:hasCapability(Capability.ManipulateMods)) then return end
        -- args 型別防禦：dispatcher 未驗 args（惡意 client 可傳 nil）；雖在 capability
        -- 守衛之後（僅 admin 可達），仍不留 logged-error 路徑
        local lang = type(args) == "table" and args.lang or nil
        if lang ~= nil and type(lang) ~= "string" then lang = nil end
        local gen = MinidoracatZonesShared.generateTemplateForLanguage(lang)
        -- 新語意一律寫 zones.json（有內容先備份 .bak）；成功即強制重讀＋全體廣播讓所有 client
        -- 立即看到新示範區域。備份失敗會回 ok=false（zones.json 未動），此時不廣播。
        if gen.ok then
            pollNow(true)
        end
        sendServerCommand(player, MODULE, "generateResult",
            { ok = gen.ok, path = gen.wrotePath, backedUp = gen.backedUp, bakName = gen.bakName, lang = lang })
    end
end)
