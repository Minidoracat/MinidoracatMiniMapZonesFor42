-- MinidoracatZonesShared.lua
-- Zones 驗證器＋wire 短欄位名編解碼——server（讀 zones.json）與 client（SP fallback，
-- 見計畫 Phase 3 step 8）共用。純資料驗證，不碰檔案 IO、不碰網路，方便兩端呼叫同一套規則。
--
-- 整檔上限閘（外部程式可寫 zones.json＝信任邊界，見 AGENTS.md）：
--   總 zone 數 ≤ maxZones、單 zone rects 數 ≤ maxRectsPerZone、
--   meta 序列化粗估 ≤ maxMetaBytes/zone、原始檔 ≤ maxFileBytes
--   （maxFileBytes 由呼叫端在 decode 之前對檔案位元組長度檢查，見計畫 Phase 3 step 5；
--   這裡只放常數，不在 validateZones 內重覆檔案層級的檢查）。
--
-- 輸出的 zone 是「已正規化」結構，欄位直接對照主 MOD 0.7.0 registerZoneProvider 的
-- zone schema（MinidoracatMiniMap.lua:79-83；rects/fill/border 皆為 keyed table，
-- 非 positional array——繪製端直接讀 rc.x1/z.fill.r 等）：
--   { id=string, name=string, rects={ {x1=,y1=,x2=,y2=}, ... },
--     fill={r=,g=,b=}, fillAlpha=number, border={r=,g=,b=}, borderAlpha=number,
--     category=string|nil, meta=table|nil }
-- 輸入（zones.json 的單一 zone，見 AGENTS.md schema）用 positional 陣列：
--   rects={ {x1,y1,x2,y2}, ... }、fill={r,g,b} 或 "#RRGGBB"

MinidoracatZonesShared = MinidoracatZonesShared or {}

MinidoracatZonesShared.LIMITS = {
    maxZones = 500,
    maxRectsPerZone = 64,
    maxMetaBytes = 2048,
    maxFileBytes = 1000000,
    -- 字串 byte 上限（UTF-8 byte 計，非字元數）——name/id/category 各自封頂，
    -- 確保任何進 wire 的字串遠低於引擎 UTF writer 的 signed-short 長度極限 32767（B4）。
    maxNameBytes = 600,          -- ≈200 個 BMP 字元
    maxIdBytes = 600,            -- id/category 比照 name
    -- 分包 byte budget（B1）：單 zone wire 序列化上限＋單包 wire 序列化上限。
    -- 目標遠離引擎 UdpConnection 1,000,000-byte buffer（破表 → GameServer 只 catch
    -- IOException，connection 鎖死）。60000 留足封包外層（bid/seq/tot/count）＋引擎 overhead 餘裕。
    maxZoneWireBytes = 60000,
    maxPacketWireBytes = 60000,
}

-- 驗證器認得的欄位；其餘一律透傳進 zone.meta（保留擴充，如未來的 expiresAt）。
-- meta 本身列為 known（B6）：{meta={...}} 直接落 zone.meta，不再被當未知欄位包成 zone.meta.meta。
-- enabled 列為 known：顯示開關由 validateZones 迴圈直接處理（見下），不透傳進 meta。
local KNOWN_FIELDS = {
    id = true, name = true, rects = true, fill = true, fillAlpha = true,
    border = true, borderAlpha = true, category = true, meta = true,
    enabled = true,
}

local INF = 1 / 0

-- 有限數值檢查：擋 NaN（v ~= v）與 ±inf（parse_number 把 1e999 → inf）（B3）
local function isFinite(v)
    return v == v and v ~= INF and v ~= -INF
end

-- Kahlua 字串為 UTF-16 code unit 序列（#s 為 code unit 數，非 byte 數）。逐 code unit 估其對應
-- UTF-8 位元組數：unit < 0x80 → 1；< 0x800 → 2；surrogate lead（0xD800..0xDBFF）→ 4（一對 astral
-- 字元的完整 4 bytes 全記在 lead 上）；surrogate trail（0xDC00..0xDFFF）→ 0（已計於 lead）；其餘 BMP → 3。
-- 契約：這是三處 1MB 檔案閘（server/client/備份讀檔）與 wire/name byte 估算共用的「唯一一套」位元組
-- 計算，故設為公開（MinidoracatZonesShared.utf8ByteLen）供 server/client 分檔跨全域表呼叫。
-- **不可用 string pattern**（Kahlua StringLib 對數字轉義字元類會拋 malformed pattern，見 tplJsonEscape 註解）。
local function utf8ByteLen(s)
    local sbyte = string.byte
    local total = 0
    for i = 1, #s do
        local c = sbyte(s, i)
        if c < 0x80 then
            total = total + 1
        elseif c < 0x800 then
            total = total + 2
        elseif c >= 0xD800 and c <= 0xDBFF then
            total = total + 4
        elseif c >= 0xDC00 and c <= 0xDFFF then
            total = total + 0
        else
            total = total + 3
        end
    end
    return total
end
MinidoracatZonesShared.utf8ByteLen = utf8ByteLen

-- 保守 wire byte 估算：估一個 wire table（packZone 產出）經引擎 table 序列化後的 byte 數。
-- 一律高估（每值算 type tag、每 table 算容器＋逐 entry key overhead、字串按 UTF-8 byte
-- ＋length prefix）——目的是安全閘，不需與引擎逐 byte 精確，只需保證 >= 實際。
local WIRE_TYPE_TAG = 2        -- 每值型別標記（引擎多為 1，取 2 留餘裕）
local WIRE_TABLE_OVERHEAD = 8  -- 每 table 容器（開合標記＋entry count）
local WIRE_NUMBER_BYTES = 9    -- number：type + 8-byte double
local WIRE_BOOL_BYTES = 2
local WIRE_STR_PREFIX = 4      -- 字串 length prefix（引擎 UTF writer 2-byte，取 4 保守）

local function estimateWireBytes(v)
    local t = type(v)
    if t == "string" then
        return WIRE_TYPE_TAG + WIRE_STR_PREFIX + utf8ByteLen(v)
    elseif t == "number" then
        return WIRE_NUMBER_BYTES
    elseif t == "boolean" then
        return WIRE_BOOL_BYTES
    elseif t == "table" then
        local total = WIRE_TABLE_OVERHEAD
        for k, val in pairs(v) do
            if type(k) == "string" then
                total = total + WIRE_TYPE_TAG + WIRE_STR_PREFIX + utf8ByteLen(k)
            else
                total = total + WIRE_NUMBER_BYTES  -- numeric key
            end
            total = total + estimateWireBytes(val)
        end
        return total
    end
    return WIRE_TYPE_TAG  -- nil/function 等：保底
end

-- 公開：估一個 wire table 的序列化 byte 數（server 分包 budget 用，見 enqueueFullSync）。
-- validator（validateOneZone）與 server 分包共用此函式＝「三處同一套 byte 計算」。
function MinidoracatZonesShared.wireBytes(wire)
    return estimateWireBytes(wire)
end

-- 顏色：hex "#RRGGBB" 或 {r,g,b}（0-1 或 0-255，任一分量 >1 即判定整組是 0-255）。
-- 格式錯（非字串/非 table、hex 長度或十六進位錯、分量非 number）回傳 nil。
local function parseColor(c)
    if type(c) == "string" then
        if #c == 7 and c:sub(1, 1) == "#" then
            local r = tonumber(c:sub(2, 3), 16)
            local g = tonumber(c:sub(4, 5), 16)
            local b = tonumber(c:sub(6, 7), 16)
            if r and g and b then
                return r / 255, g / 255, b / 255
            end
        end
        return nil
    elseif type(c) == "table" then
        local r, g, b = c[1], c[2], c[3]
        if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
            return nil
        end
        if r > 1 or g > 1 or b > 1 then
            r, g, b = r / 255, g / 255, b / 255
        end
        r = math.max(0, math.min(1, r))
        g = math.max(0, math.min(1, g))
        b = math.max(0, math.min(1, b))
        return r, g, b
    end
    return nil
end

-- alpha：必須是 number 才合法（型別錯視為壞條目）；先做 finite 檢查（NaN/inf 一律拒絕，
-- 見 B3），範圍外（但有限）才 clamp 而非拒絕
local function clampAlpha(a)
    if type(a) ~= "number" or not isFinite(a) then return nil end
    if a < 0 then return 0 end
    if a > 1 then return 1 end
    return a
end

-- meta 序列化長度粗估：擋外部輸入無界放大，不需位元組精確但不可留洞。key/value 各型別皆計，
-- 每個 table（含巢狀）算容器 overhead、每個 entry 算固定 overhead——否則「大量空 table／numeric-key
-- 巢狀」等結構原本 total 全 0 可無界繞過上限。字串（key/value）用共用 utf8ByteLen（UTF-8 byte 估）。
local function estimateMetaBytes(t)
    local total = 0
    local function walk(tbl)
        total = total + 16  -- 每個 table（含巢狀）容器 overhead，杜絕「一堆空 table」total=0 繞過
        for k, v in pairs(tbl) do
            total = total + 4  -- 每個 entry 固定 overhead
            if type(k) == "string" then total = total + utf8ByteLen(k)
            elseif type(k) == "number" then total = total + 8
            elseif type(k) == "boolean" then total = total + 1 end
            if type(v) == "string" then
                total = total + utf8ByteLen(v)
            elseif type(v) == "number" then
                total = total + 8
            elseif type(v) == "boolean" then
                total = total + 1
            elseif type(v) == "table" then
                walk(v)
            end
        end
    end
    walk(t)
    return total
end

-- 驗證單一 zone；壞條目直接把原因寫進 errors（帶 index），回傳 nil。
-- 好條目回傳正規化後的 zone table。
local function validateOneZone(raw, index, limits, errors)
    local function fail(msg)
        table.insert(errors, "zone #" .. index .. ": " .. msg)
        return nil
    end

    -- JSON null 陣列元素會是 MinidoracatZonesJson.null sentinel（B2）——當非法條目跳過，
    -- 但關鍵是它讓 #arr 保住真實長度，後續合法 zone 不再被截斷。nil-guard 保持 shared 可獨立使用。
    if type(raw) ~= "table"
        or (MinidoracatZonesJson and raw == MinidoracatZonesJson.null) then
        return fail("entry is not a table (or is JSON null)")
    end

    -- name（UTF-8 byte 上限，保證進 wire 的字串遠低於 32767，B4）
    if type(raw.name) ~= "string" or raw.name == "" then
        return fail("name missing or not a string")
    end
    if utf8ByteLen(raw.name) > limits.maxNameBytes then
        return fail("name exceeds " .. limits.maxNameBytes .. " bytes")
    end

    -- rects：必填非空陣列，每項 4 個 number，x2>x1 且 y2>y1
    if type(raw.rects) ~= "table" or #raw.rects == 0 then
        return fail("rects missing or empty")
    end
    if #raw.rects > limits.maxRectsPerZone then
        return fail("rects count exceeds limit " .. limits.maxRectsPerZone)
    end
    local rects = {}
    for i = 1, #raw.rects do
        local r = raw.rects[i]
        if type(r) ~= "table" or #r ~= 4 then
            return fail("rects[" .. i .. "] malformed (need 4 numbers)")
        end
        local x1, y1, x2, y2 = r[1], r[2], r[3], r[4]
        if type(x1) ~= "number" or type(y1) ~= "number"
            or type(x2) ~= "number" or type(y2) ~= "number" then
            return fail("rects[" .. i .. "] has non-number element")
        end
        -- 有限性：擋 NaN/±inf（parse_number 把 1e999 → inf；NaN 意外被 x2>x1 擋、inf 沒擋）（B3）
        if not (isFinite(x1) and isFinite(y1) and isFinite(x2) and isFinite(y2)) then
            return fail("rects[" .. i .. "] has non-finite value (NaN/inf)")
        end
        if not (x2 > x1) or not (y2 > y1) then
            return fail("rects[" .. i .. "] needs x2>x1 and y2>y1")
        end
        rects[i] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    end

    -- fill（預設紅色）
    local fillR, fillG, fillB = 1, 0, 0
    if raw.fill ~= nil then
        local r, g, b = parseColor(raw.fill)
        if not r then return fail("fill malformed") end
        fillR, fillG, fillB = r, g, b
    end

    -- fillAlpha（預設 0.25；正式欄位優先，缺 fillAlpha 但有 number 型別的 alpha 別名時採用之——
    -- 外部工具作者常見誤寫成 alpha，寬容收下。alpha 一旦被採用即不再透傳進 meta，見下方 meta 迴圈）
    local fillAlpha = 0.25
    local alphaAliasUsed = false
    if raw.fillAlpha ~= nil then
        local a = clampAlpha(raw.fillAlpha)
        if not a then return fail("fillAlpha wrong type (need number)") end
        fillAlpha = a
    elseif type(raw.alpha) == "number" then
        local a = clampAlpha(raw.alpha)
        if a then
            fillAlpha = a
            alphaAliasUsed = true
        end
    end

    -- border（預設同 fill 正規化後的值）
    local borderR, borderG, borderB = fillR, fillG, fillB
    if raw.border ~= nil then
        local r, g, b = parseColor(raw.border)
        if not r then return fail("border malformed") end
        borderR, borderG, borderB = r, g, b
    end

    -- borderAlpha（預設 0.9）
    local borderAlpha = 0.9
    if raw.borderAlpha ~= nil then
        local a = clampAlpha(raw.borderAlpha)
        if not a then return fail("borderAlpha wrong type (need number)") end
        borderAlpha = a
    end

    -- category（選填；UTF-8 byte 上限，B4）
    local category = nil
    if raw.category ~= nil then
        if type(raw.category) ~= "string" then return fail("category must be a string") end
        if utf8ByteLen(raw.category) > limits.maxIdBytes then
            return fail("category exceeds " .. limits.maxIdBytes .. " bytes")
        end
        category = raw.category
    end

    -- id（選填，預設用 name；UTF-8 byte 上限，B4）
    local id = raw.name
    if raw.id ~= nil then
        if type(raw.id) ~= "string" then return fail("id must be a string") end
        if utf8ByteLen(raw.id) > limits.maxIdBytes then
            return fail("id exceeds " .. limits.maxIdBytes .. " bytes")
        end
        id = raw.id
    end

    -- meta：明確 raw.meta（table）作基底（B6：不再被包成 zone.meta.meta），再併入其餘未知頂層
    -- 欄位（向後相容舊資料把擴充欄位放頂層）。序列化粗估超限則整組捨棄並記一筆 error（zone 仍合法）。
    local meta = nil
    if type(raw.meta) == "table" then
        meta = {}
        for k, v in pairs(raw.meta) do meta[k] = v end
    end
    for k, v in pairs(raw) do
        if not KNOWN_FIELDS[k] and not (k == "alpha" and alphaAliasUsed) then
            meta = meta or {}
            meta[k] = v
        end
    end
    if meta then
        if estimateMetaBytes(meta) > limits.maxMetaBytes then
            table.insert(errors, "zone #" .. index .. " (" .. tostring(id) .. "): meta exceeds "
                .. limits.maxMetaBytes .. " bytes, dropped")
            meta = nil
        end
    end

    local zone = {
        id = id,
        name = raw.name,
        rects = rects,
        fill = { r = fillR, g = fillG, b = fillB },
        fillAlpha = fillAlpha,
        border = { r = borderR, g = borderG, b = borderB },
        borderAlpha = borderAlpha,
        category = category,
        meta = meta,
    }

    -- B1：單 zone 的 wire 序列化 byte 超限即拒絕（含 meta/rects/字串）。與 server 分包
    -- budget 共用 wireBytes；此處拒絕保證任何進佇列的 zone 都塞得下一包，server 分包不會卡死。
    local wb = MinidoracatZonesShared.wireBytes(MinidoracatZonesShared.packZone(zone))
    if wb > limits.maxZoneWireBytes then
        return fail("wire serialization " .. wb .. " bytes exceeds per-zone limit " .. limits.maxZoneWireBytes)
    end

    return zone
end

-- 輸入收 { zones = {...} }（zones.json 常見外層）或直接陣列（json.decode 一個
-- JSON 陣列時就是這形狀）。壞條目跳過並記錯，不使整檔失效。
function MinidoracatZonesShared.validateZones(rawTable)
    local errors = {}
    if type(rawTable) ~= "table" then
        return { zones = {}, count = 0, errors = { "validateZones: input is not a table" }, fatal = true }
    end

    -- fatal：zones 鍵存在但非 table（如 {"zones":"oops"}）＝整檔壞掉，不可 fallback 掃外層當合法空集
    -- （會靜默清空所有區域）。回 fatal，呼叫端保留前一份快取、不清空不廣播。
    if rawTable.zones ~= nil and type(rawTable.zones) ~= "table" then
        return { zones = {}, count = 0, errors = { "zones field must be an array" }, fatal = true }
    end

    local arr = rawTable
    if type(rawTable.zones) == "table" then
        arr = rawTable.zones
    end

    local limits = MinidoracatZonesShared.LIMITS
    -- #arr 可信：decoder 已把 JSON null 陣列元素填為 sentinel（B2），無 nil 洞截斷。
    -- enabled 顯示開關（選填，省略＝true）：enabled==false 的 zone 保留在檔案但整組跳過——
    -- 不驗證、不進輸出、不計數、更不佔 maxZones 上限（故不能沿用舊的「#arr 預先截斷」，需逐條
    -- 掃描、只對「顯示中」的 zone 計 maxZones）。present 但非 boolean → 記 error 跳過（與其他欄位
    -- 嚴格性一致）。Kahlua 無 goto，用 if/else 包裹表達 continue 語意（B2 null-sentinel／非 table
    -- 條目仍走 validateOneZone 的原錯誤路徑，enabled 判斷只作用於真正的 zone table）。
    local zones = {}
    local disabledCount = 0
    local considered = 0
    local truncated = false
    for i = 1, #arr do
        local raw = arr[i]
        local isZoneTable = type(raw) == "table"
            and not (MinidoracatZonesJson and raw == MinidoracatZonesJson.null)
        if isZoneTable and raw.enabled == false then
            disabledCount = disabledCount + 1  -- 明確隱藏：跳過且不佔 maxZones 上限
        else
            considered = considered + 1
            if considered > limits.maxZones then
                truncated = true
                break
            end
            if isZoneTable and raw.enabled ~= nil and type(raw.enabled) ~= "boolean" then
                table.insert(errors, "zone #" .. i .. ": enabled must be a boolean")
            else
                local zone = validateOneZone(raw, i, limits, errors)
                if zone then
                    table.insert(zones, zone)
                end
            end
        end
    end
    if truncated then
        table.insert(errors, "zones count exceeds limit " .. limits.maxZones .. ", truncated")
    end

    return { zones = zones, count = #zones, errors = errors, disabledCount = disabledCount }
end

-------------------------------------------------------------------------------
-- Wire 短欄位名編解碼（研究報告 §5：分包廣播省 bytes 用短 key；
-- rects/顏色用 positional 陣列而非 keyed table，省掉逐項欄位名開銷）
-------------------------------------------------------------------------------

MinidoracatZonesShared.FIELD = {
    id = "id", name = "n", rects = "rc", fill = "fc", fillAlpha = "fa",
    border = "bc", borderAlpha = "ba", category = "cat", meta = "mt",
}

-- 已正規化 zone（validateZones 的輸出形狀）→ wire table（短欄位名、positional 陣列）
function MinidoracatZonesShared.packZone(zone)
    local F = MinidoracatZonesShared.FIELD
    local wireRects = {}
    for i = 1, #zone.rects do
        local r = zone.rects[i]
        wireRects[i] = { r.x1, r.y1, r.x2, r.y2 }
    end
    local wire = {
        [F.id] = zone.id,
        [F.name] = zone.name,
        [F.rects] = wireRects,
        [F.fill] = { zone.fill.r, zone.fill.g, zone.fill.b },
        [F.fillAlpha] = zone.fillAlpha,
        [F.border] = { zone.border.r, zone.border.g, zone.border.b },
        [F.borderAlpha] = zone.borderAlpha,
    }
    if zone.category then wire[F.category] = zone.category end
    if zone.meta then wire[F.meta] = zone.meta end
    return wire
end

-- wire table → 正規化 zone（供 client 收到廣播後直接餵給 provider 快取/繪製端）
function MinidoracatZonesShared.unpackZone(wire)
    local F = MinidoracatZonesShared.FIELD
    local rects = {}
    local wireRects = wire[F.rects] or {}
    for i = 1, #wireRects do
        local r = wireRects[i]
        rects[i] = { x1 = r[1], y1 = r[2], x2 = r[3], y2 = r[4] }
    end
    local fc = wire[F.fill] or { 1, 0, 0 }
    local bc = wire[F.border] or fc
    return {
        id = wire[F.id],
        name = wire[F.name],
        rects = rects,
        fill = { r = fc[1], g = fc[2], b = fc[3] },
        fillAlpha = wire[F.fillAlpha],
        border = { r = bc[1], g = bc[2], b = bc[3] },
        borderAlpha = wire[F.borderAlpha],
        category = wire[F.category],
        meta = wire[F.meta],
    }
end

-------------------------------------------------------------------------------
-- 變化偵測 hash（server 輪詢與 client SP fallback 本地輪詢共用同一份，避免兩處
-- 各自維護一份 djb2；Kahlua 無 bit ops，用算術取模 2^32——h<2^32 時 h*33+c < 2^53，
-- 在 double 內精確不失真，沿用原 server 檔 MinidoracatMiniMapZonesServer.lua 的做法）
-------------------------------------------------------------------------------

function MinidoracatZonesShared.djb2(str)
    local sbyte = string.byte
    local h = 5381
    for i = 1, #str do
        h = (h * 33 + sbyte(str, i)) % 4294967296
    end
    return h
end

-------------------------------------------------------------------------------
-- 範本：Zomboid/Lua/MinidoracatMiniMapZones/zones.json。兩種入口——
--   ensureZonesTemplate（首次啟動，檔不存在→含四個示範區域，玩家照著改）；
--   ensureZonesTemplateEmpty（執行期檔案消失→重生空範本 { "zones": [] }，區域清空但檔案隨時
--     存在，保留「刪檔＝清空」語意）。兩者共用內部 writeZonesTemplate（probe＋_doc＋IO）。
-- server（OnServerStarted／pollNow）與 client SP fallback（首讀前／spPollNow）呼叫；
-- MP client 絕不呼叫（伺服器權威，見 client 檔）。
--
-- 引擎 API 出處（AGENTS.md 鐵則：禁憑記憶寫 PZ API）：
--   getFileWriter(filename, createIfNull, append) → LuaManager.java:6636-6672
--     · root＝getLuaCacheDir()（Zomboid/Lua/，與 getFileReader 同根）；filename 內 `/`\`
--       皆 normalize 成 File.separator，父資料夾 mkdirs() 自動建（:6646-6648）
--     · createIfNull=true → 檔不存在時建檔；UTF-8 PrintWriter
--     vanilla 用例 getFileWriter(name,true,false)：client/PZAPI/ModOptions.lua:260
--   writer:write(str) → client/ISUI/ISLayoutManager.lua:174；writer:close() → :185
--   getFileReader 探測存在（reader nil＝不存在）＋ reader:close() → client/PZAPI/ModOptions.lua:289
--
-- 字串是否含非空白字元（byte 掃描，**不用 pattern**）。空白＝space(32) 與控制字元 9(TAB)
-- 10(LF) 11(VT) 12(FF) 13(CR)。writeZonesTemplate probe（0-byte／全空白視同缺檔）與
-- server/client runtime 空集判定共用此函式——刻意 byte 比較而非 `%s`/`%S` pattern：本檔已因
-- Kahlua pattern 引擎相容性被咬過一次（見 tplJsonEscape 註解），新增碼一律避開 pattern。
function MinidoracatZonesShared.hasNonBlank(s)
    local sbyte = string.byte
    for i = 1, #s do
        local c = sbyte(s, i)
        if not (c == 32 or (c >= 9 and c <= 13)) then
            return true
        end
    end
    return false
end

-- JSON 字串跳脫 helper（範本組字用）。**逐 byte 掃描，完全不用 gsub/pattern**——真機證據
-- （server-console.txt）：Kahlua StringLib pattern 引擎不接受「字元類裡用數字轉義寫範圍」
-- （\0、\31 之類），gsub 直接拋 RuntimeException: malformed pattern (missing ']')
-- （StringLib.java:1521）；桌面 Lua 5.4 卻接受 → 測試綠、真機一跑就炸並留 0-byte 空檔。
-- 逐 byte 判斷：JSON 必跳脫者（" \ \n \r \t）短跳脫；其餘控制字元（<0x20）直接丟棄（翻譯文字
-- 不含此類，丟棄最穩且避開 string.format 的 Kahlua 相容疑慮）；>=0x20 者以 string.sub 原樣保留。
-- Kahlua（字串為 UTF-16 code unit 序列）與桌面 Lua（UTF-8 byte 序列）兩模型下，多碼元/多位元組
-- 序列皆逐單位 >=0x20 原樣通過 → 交由 UTF-8 PrintWriter 原樣落地為正確 UTF-8（行為同原設計）。
local function tplJsonEscape(s)
    local sbyte = string.byte
    local ssub = string.sub
    local out = {}
    local n = 0
    for i = 1, #s do
        local c = sbyte(s, i)
        local piece
        if c == 34 then piece = '\\"'          -- "
        elseif c == 92 then piece = "\\\\"     -- \
        elseif c == 10 then piece = "\\n"
        elseif c == 13 then piece = "\\r"
        elseif c == 9 then piece = "\\t"
        elseif c < 32 then piece = nil          -- 其餘控制字元：丟棄
        else piece = ssub(s, i, i) end          -- >=0x20（含多位元組序列的各單位）原樣
        if piece then
            n = n + 1
            out[n] = piece
        end
    end
    return table.concat(out)
end

-- 取翻譯字串；缺譯／未載入／例外時退回 .lua 內建純 ASCII 英文 fallback。
-- 為何「runtime 翻譯字串」這條路可安全放中文/日文，而 .lua 字面值不行（根因，附反編譯證據行號）：
--   · 翻譯 JSON 由引擎 Java 層以 UTF-8 明確載入（Translator.tryFillMapFromFile → Files.readString，
--     Translator.java:246-254），記憶體中為正確 UTF-16；經 getFileWriter 的 UTF-8 PrintWriter
--     （LuaManager.java:6663）寫出＝正確 UTF-8。故 getText 回傳的字串進範本安全。
--   · 反觀 .lua 原始碼載入的 charset 非保證 UTF-8——RunLuaInternal 編譯前經
--     IndieFileLoader.getStreamReader 取 reader（LuaManager.java:1342）；主路徑雖 UTF-8，但 catch
--     fallback 以 new InputStreamReader(fisx) 無 charset 參數＝平台預設（zh-TW＝CP950）
--     （IndieFileLoader.java:26）。故 .lua 字面值裡的 UTF-8 中文一旦走該 fallback 載入即毀成亂碼＋
--     原始控制字元 → 寫出的 zones.json 破格、parser 嚴拒 → decode 失敗、示範區域消失。
--   → 結論：中文/日文只住翻譯 JSON（走 getText）；.lua 內的 fallback 字串必須維持純 ASCII 英文。
-- getTextOrNull 可用性佐證（server/shared context）：LuaManager 以 @LuaMethod(global=true) 註冊
--   getText/getTextOrNull（LuaManager.java:8512-8564），client 與 server VM 共用；vanilla server lua
--   直接呼叫 getText（media/lua/server/BuildingObjects/ISBuildingObject.lua:680,686,691）。
--   getTextOrNull 缺譯回 nil（Translator.getTextInternal nullOK 分支，Translator.java:381-384）。
-- pcall 包裹＋`getTextOrNull and`：擋極端情況（server 翻譯未載入／未知語言／Translator 例外）不炸整段；
--   nil／空／等於 key 本身時退 ASCII（雙保險：PZ getText 對缺譯語言本會 fallback 引擎預設語言 EN）。
local function tplText(key, fallbackAscii)
    local s
    if getTextOrNull then
        local okTr, v = pcall(getTextOrNull, key)
        if okTr then s = v end
    end
    if s == nil or s == "" or s == key then
        return fallbackAscii
    end
    return s
end

-- 內部：寫 zones.json 範本。zoneLines＝"zones" 陣列的內容行（demo 帶 3 筆、空範本傳 {}）。
-- 先 probe：檔已存在「且含非空白內容」才視為已存在、回 true；否則組完整內容後寫入。
-- _doc 走 getText（依語系生成可讀文字，見 tplText/tplJsonEscape 註解）；座標/顏色為結構常數。
-- 呼叫端已用 pcall 包裹（見 ensureZonesTemplate/ensureZonesTemplateEmpty），此處直接做 IO。
--
-- 兩處硬化（使用者實測踩到 0-byte 空檔卡死）：
--   (1) probe 改「存在且有非空白內容」才算存在——外部工具（如 VS Code 分頁存空緩衝）可能
--       把檔弄成 0-byte／全空白，舊 probe 只看「存在」→ 判定已存在、永不補寫 → 卡死空檔。
--       改為 readLine 掃到第一個非空白字元才算「已存在」；全空白／0-byte → 視同不存在 → 重寫範本。
--   (2) 先組完整內容字串、再 getFileWriter——組字（tplText/tplJsonEscape/concat）任何失敗都
--       發生在建檔之前（由呼叫端 pcall 捕捉），杜絕「getFileWriter 建了空檔卻在後續組字失敗」的
--       永久空檔窗口。getFileWriter 之後只剩 write+close。
-- _doc 的純 ASCII 英文 fallback（tplText 缺譯時用；與 EN/UI.json 的 TplDoc 逐字一致）。
local DEMO_DOC_ASCII = "Zones are map display markers only -- they do not affect gameplay (this mod has no PVP/safe-zone mechanics). The zones above are demos; edit or delete them freely. Add \"enabled\": false to a zone to hide it without deleting (omitted means true). Coordinates are world square coordinates [x1,y1,x2,y2] (top-left to bottom-right). You can edit them in any language (the file is read as UTF-8). Changes take effect after the poll interval, or immediately when an admin runs /reloadzones -- no restart needed."

-- 四個示範區域的座標/顏色為唯一真實來源（ensureZonesTemplate 與 generateTemplateForLanguage
-- 共用，避免兩份座標）。四個 name 參數須「已 tplJsonEscape」。
local function buildDemoZoneLines(wp, rw, br, ml)
    return {
        '    { "name": "' .. wp .. '", "rects": [[11882, 6928, 11918, 6961]], "fill": "#3B82F6", "fillAlpha": 0.3, "border": "#3B82F6" },',
        '    { "name": "' .. rw .. '", "rects": [[8123, 11723, 8163, 11757]], "fill": "#FF3B30", "fillAlpha": 0.3, "border": "#FF3B30" },',
        '    { "name": "' .. br .. '", "rects": [[9916, 12595, 9986, 12651]], "fill": "#22C55E", "fillAlpha": 0.3, "border": "#22C55E" },',
        '    { "name": "' .. ml .. '", "rects": [[6115, 5235, 6150, 5285], [6115, 5285, 6180, 5320]], "fill": "#F59E0B", "fillAlpha": 0.3, "border": "#F59E0B", "enabled": true }',
    }
end

-- 組裝完整範本內容字串。zoneLines＝"zones" 陣列內容行（空範本傳 {}）；docEscaped＝已跳脫的 _doc。
local function assembleTemplate(zoneLines, docEscaped)
    local out = { "{", '  "zones": [' }
    for i = 1, #zoneLines do out[#out + 1] = zoneLines[i] end
    out[#out + 1] = "  ],"
    out[#out + 1] = '  "_doc": "' .. docEscaped .. '"'
    out[#out + 1] = "}"
    return table.concat(out, "\n")
end

local function writeZonesTemplate(zoneLines)
    local path = "MinidoracatMiniMapZones" .. getFileSeparator() .. "zones.json"
    local reader = getFileReader(path, false)
    if reader then
        local hasContent = false
        while true do
            local line = reader:readLine()
            if line == nil then break end
            if MinidoracatZonesShared.hasNonBlank(line) then hasContent = true; break end
        end
        reader:close()
        if hasContent then return true end  -- 已存在且非空 → 不覆寫
        -- 落到這＝存在但 0-byte／全空白 → 視同不存在，續往下重寫範本
    end
    -- 先組完整內容（此前任何失敗都在建檔之前）
    local content = assembleTemplate(zoneLines,
        tplJsonEscape(tplText("UI_MinidoracatMiniMapZones_TplDoc", DEMO_DOC_ASCII)))
    -- 內容備妥，才建檔（僅剩 write+close，不再有可能拋錯的組字）
    local writer = getFileWriter(path, true, false)
    if not writer then return false end
    writer:write(content)
    writer:close()
    return true
end

-- 首次啟動：檔不存在時寫含四個示範區域的範本（name 走 getText 依語系生成；
-- 第四個為多矩形示範——一個區域由兩個矩形組成 L 形，示範 rects 陣列可放多組）。
-- 回傳 true＝檔已存在或範本寫入成功；false＝寫入失敗（getFileWriter nil／IO 例外）。
function MinidoracatZonesShared.ensureZonesTemplate()
    local ok, result = pcall(function()
        local wp = tplJsonEscape(tplText("UI_MinidoracatMiniMapZones_TplWestPoint", "Demo zone: West Point Police"))
        local rw = tplJsonEscape(tplText("UI_MinidoracatMiniMapZones_TplRosewood", "Demo zone: Rosewood Fire Dept"))
        local br = tplJsonEscape(tplText("UI_MinidoracatMiniMapZones_TplBunker", "Demo zone: March Ridge Bunker"))
        local ml = tplJsonEscape(tplText("UI_MinidoracatMiniMapZones_TplMultiRect", "Demo zone: multi-rect L-shape (Riverside)"))
        return writeZonesTemplate(buildDemoZoneLines(wp, rw, br, ml))
    end)
    if not ok then return false end
    return result
end

-- 指定語系的四語範本字串（wp/rw/br/ml/doc ×CH/CN/EN/JP），以 \u escape 純 ASCII JSON 存放：
-- .lua 原始碼 charset 非保證 UTF-8（CP950 fallback 會毀掉字面中文，見 tplText 註解的反編譯佐證），
-- 故指定語系文字不能寫字面 UTF-8，改存 \u escape、生成時經 MinidoracatZonesJson.decode 解出真字串
-- （Kahlua string.char 以 UTF-16 code unit 儲存 BMP codepoint，實機正確；桌面 Lua 的 string.char
-- 只收 0-255 故 CJK 在桌面測試會 range-error，改由 scripts/tests/test_tpl_strings.py 逐字鎖定）。
-- ⚠ 本常數必須與四語 UI.json 的 Tpl* 鍵逐字同步：改譯文後重跑
--   `python scripts/tests/test_tpl_strings.py . --emit` 重生此行（勿手打）。
local TPL_STRINGS_JSON = '{"CH":{"wp":"\\u793a\\u7bc4\\u5340\\u57df\\uff1aWest Point \\u8b66\\u5c40","rw":"\\u793a\\u7bc4\\u5340\\u57df\\uff1aRosewood \\u6d88\\u9632\\u5c40","br":"\\u793a\\u7bc4\\u5340\\u57df\\uff1aMarch Ridge \\u5730\\u5821","ml":"\\u793a\\u7bc4\\uff1a\\u591a\\u77e9\\u5f62 L \\u5f62\\uff08Riverside\\uff09","doc":"\\u5340\\u57df\\u50c5\\u70ba\\u5730\\u5716\\u986f\\u793a\\u6a19\\u793a\\uff0c\\u4e0d\\u5f71\\u97ff\\u4efb\\u4f55\\u904a\\u6232\\u6a5f\\u5236\\uff08\\u672c MOD \\u7121 PVP\\uff0f\\u5b89\\u5168\\u5340\\u7b49\\u529f\\u80fd\\uff09\\u3002\\u4ee5\\u4e0a\\u70ba\\u793a\\u7bc4\\u5340\\u57df\\uff0c\\u53ef\\u81ea\\u884c\\u4fee\\u6539\\u6216\\u522a\\u9664\\u3002\\u6bcf\\u500b\\u5340\\u57df\\u53ef\\u52a0 \\"enabled\\": false \\u66ab\\u6642\\u96b1\\u85cf\\u800c\\u4e0d\\u5fc5\\u522a\\u9664\\uff08\\u7701\\u7565\\u8996\\u70ba true\\uff09\\u3002\\u5ea7\\u6a19\\u70ba\\u4e16\\u754c square \\u5ea7\\u6a19 [x1,y1,x2,y2]\\uff08\\u5de6\\u4e0a\\u5230\\u53f3\\u4e0b\\uff09\\u3002\\u76f4\\u63a5\\u4ee5\\u4efb\\u4f55\\u8a9e\\u8a00\\u6587\\u5b57\\u7de8\\u8f2f\\u7686\\u53ef\\uff08\\u6a94\\u6848\\u4ee5 UTF-8 \\u8b80\\u53d6\\uff09\\u3002\\u6539\\u6a94\\u5f8c\\u7b49\\u8f2a\\u8a62\\u9593\\u9694\\u6216 admin \\u4e0b /reloadzones \\u7acb\\u5373\\u751f\\u6548\\uff0c\\u7121\\u9700\\u91cd\\u555f\\u3002"},"CN":{"wp":"\\u793a\\u8303\\u533a\\u57df\\uff1aWest Point \\u8b66\\u5bdf\\u5c40","rw":"\\u793a\\u8303\\u533a\\u57df\\uff1aRosewood \\u6d88\\u9632\\u5c40","br":"\\u793a\\u8303\\u533a\\u57df\\uff1aMarch Ridge \\u5730\\u5821","ml":"\\u793a\\u8303\\uff1a\\u591a\\u77e9\\u5f62 L \\u5f62\\uff08Riverside\\uff09","doc":"\\u533a\\u57df\\u4ec5\\u4e3a\\u5730\\u56fe\\u663e\\u793a\\u6807\\u793a\\uff0c\\u4e0d\\u5f71\\u54cd\\u4efb\\u4f55\\u6e38\\u620f\\u673a\\u5236\\uff08\\u672c MOD \\u65e0 PVP\\uff0f\\u5b89\\u5168\\u533a\\u7b49\\u529f\\u80fd\\uff09\\u3002\\u4ee5\\u4e0a\\u4e3a\\u793a\\u8303\\u533a\\u57df\\uff0c\\u53ef\\u81ea\\u884c\\u4fee\\u6539\\u6216\\u5220\\u9664\\u3002\\u6bcf\\u4e2a\\u533a\\u57df\\u53ef\\u52a0 \\"enabled\\": false \\u6682\\u65f6\\u9690\\u85cf\\u800c\\u4e0d\\u5fc5\\u5220\\u9664\\uff08\\u7701\\u7565\\u89c6\\u4e3a true\\uff09\\u3002\\u5750\\u6807\\u4e3a\\u4e16\\u754c square \\u5750\\u6807 [x1,y1,x2,y2]\\uff08\\u5de6\\u4e0a\\u5230\\u53f3\\u4e0b\\uff09\\u3002\\u76f4\\u63a5\\u4ee5\\u4efb\\u4f55\\u8bed\\u8a00\\u6587\\u5b57\\u7f16\\u8f91\\u7686\\u53ef\\uff08\\u6587\\u4ef6\\u4ee5 UTF-8 \\u8bfb\\u53d6\\uff09\\u3002\\u6539\\u6863\\u540e\\u7b49\\u8f6e\\u8be2\\u95f4\\u9694\\u6216 admin \\u4e0b /reloadzones \\u7acb\\u5373\\u751f\\u6548\\uff0c\\u65e0\\u9700\\u91cd\\u542f\\u3002"},"EN":{"wp":"Demo zone: West Point Police","rw":"Demo zone: Rosewood Fire Dept","br":"Demo zone: March Ridge Bunker","ml":"Demo zone: multi-rect L-shape (Riverside)","doc":"Zones are map display markers only -- they do not affect gameplay (this mod has no PVP/safe-zone mechanics). The zones above are demos; edit or delete them freely. Add \\"enabled\\": false to a zone to hide it without deleting (omitted means true). Coordinates are world square coordinates [x1,y1,x2,y2] (top-left to bottom-right). You can edit them in any language (the file is read as UTF-8). Changes take effect after the poll interval, or immediately when an admin runs /reloadzones -- no restart needed."},"JP":{"wp":"\\u30c7\\u30e2\\u30be\\u30fc\\u30f3\\uff1aWest Point \\u8b66\\u5bdf\\u7f72","rw":"\\u30c7\\u30e2\\u30be\\u30fc\\u30f3\\uff1aRosewood \\u6d88\\u9632\\u7f72","br":"\\u30c7\\u30e2\\u30be\\u30fc\\u30f3\\uff1aMarch Ridge \\u5730\\u4e0b\\u58d5","ml":"\\u30c7\\u30e2\\u30be\\u30fc\\u30f3\\uff1a\\u8907\\u6570\\u77e9\\u5f62\\u306e L \\u5b57\\uff08Riverside\\uff09","doc":"\\u30be\\u30fc\\u30f3\\u306f\\u30de\\u30c3\\u30d7\\u8868\\u793a\\u7528\\u306e\\u30de\\u30fc\\u30ab\\u30fc\\u306e\\u307f\\u3067\\u3001\\u30b2\\u30fc\\u30e0\\u306e\\u52d5\\u4f5c\\u306b\\u306f\\u5f71\\u97ff\\u3057\\u307e\\u305b\\u3093\\uff08\\u3053\\u306e MOD \\u306b PVP\\uff0f\\u5b89\\u5168\\u5730\\u5e2f\\u306a\\u3069\\u306e\\u6a5f\\u80fd\\u306f\\u3042\\u308a\\u307e\\u305b\\u3093\\uff09\\u3002\\u4e0a\\u8a18\\u306f\\u30c7\\u30e2\\u30be\\u30fc\\u30f3\\u3067\\u3059\\u3002\\u81ea\\u7531\\u306b\\u7de8\\u96c6\\u30fb\\u524a\\u9664\\u3067\\u304d\\u307e\\u3059\\u3002\\u5404\\u30be\\u30fc\\u30f3\\u306b \\"enabled\\": false \\u3092\\u8ffd\\u52a0\\u3059\\u308b\\u3068\\u3001\\u524a\\u9664\\u305b\\u305a\\u306b\\u4e00\\u6642\\u7684\\u306b\\u975e\\u8868\\u793a\\u306b\\u3067\\u304d\\u307e\\u3059\\uff08\\u7701\\u7565\\u6642\\u306f true\\uff09\\u3002\\u5ea7\\u6a19\\u306f\\u30ef\\u30fc\\u30eb\\u30c9\\u306e square \\u5ea7\\u6a19 [x1,y1,x2,y2]\\uff08\\u5de6\\u4e0a\\u304b\\u3089\\u53f3\\u4e0b\\uff09\\u3067\\u3059\\u3002\\u4efb\\u610f\\u306e\\u8a00\\u8a9e\\u3067\\u7de8\\u96c6\\u3067\\u304d\\u307e\\u3059\\uff08\\u30d5\\u30a1\\u30a4\\u30eb\\u306f UTF-8 \\u3067\\u8aad\\u307f\\u8fbc\\u307e\\u308c\\u307e\\u3059\\uff09\\u3002\\u5909\\u66f4\\u306f\\u30dd\\u30fc\\u30ea\\u30f3\\u30b0\\u9593\\u9694\\u306e\\u5f8c\\u3001\\u307e\\u305f\\u306f\\u7ba1\\u7406\\u8005\\u304c /reloadzones \\u3092\\u5b9f\\u884c\\u3059\\u308b\\u3068\\u5373\\u5ea7\\u306b\\u53cd\\u6620\\u3055\\u308c\\u3001\\u518d\\u8d77\\u52d5\\u306f\\u4e0d\\u8981\\u3067\\u3059\\u3002"}}'

-- 備份檔名時間戳（現實時間）。Kahlua OsLib 支援 %Y%m%d/%H%M%S（strftime OsLib.java:150-238，
-- vanilla 用例 ISUsersList.lua:134）；異常時退 getTimestamp() epoch 秒，再退 "last"。
-- 經 table 呼叫（非 local upvalue）供測試 stub 固定時鐘。
function MinidoracatZonesShared.backupStamp()
    local ok, s = pcall(function() return os.date("%Y%m%d-%H%M%S") end)
    if ok and type(s) == "string" and s ~= "" then
        -- 附加毫秒尾碼：同秒內連按兩次生成不再撞同名 .bak 覆蓋掉唯一備份。取毫秒失敗
        -- （getTimestampMs 不可用）則維持秒級（可接受降級，同秒撞名屬邊角情況）。
        local okMs, ms = pcall(function() return getTimestampMs() % 1000 end)
        if okMs and type(ms) == "number" then
            return s .. "-" .. string.format("%03d", ms)
        end
        return s
    end
    local ok2, t = pcall(function() return string.format("%d", getTimestamp()) end)
    if ok2 and type(t) == "string" then return t end
    return "last"
end

-- 生成指定語系範本（設定頁面按鈕觸發）。langCode: nil＝跟隨當前（tplText/getText）；
-- "CH"/"CN"/"EN"/"JP"＝從 TPL_STRINGS_JSON 取對應語言（不動 Translator）。
-- 備份＋直接套用語意：zones.json 不存在／全空白 → 直接寫 zones.json（backedUp=false）；
-- 已有內容 → 先把舊內容原樣備份到同目錄 zones.json.<時間戳>.bak（每次生成各自保留、不互相
-- 覆蓋；同秒內連按仍同名覆蓋，可接受），備份成功才覆寫 zones.json（backedUp=true）。
-- 備份失敗（getFileWriter .bak 回 nil／IO 例外）→ 中止，zones.json 一位元組不動、回 ok=false
-- ——絕不在沒有備份的情況下覆蓋使用者的 zones.json。
-- 回傳 { ok = bool, wrotePath = "zones.json"|nil, backedUp = bool, bakName = string|nil }。
-- 全段 pcall（組字/decode/IO 任一失敗都回 ok=false 不炸呼叫端；桌面測試對 CJK \u 的
-- string.char range-error 亦於此被吞成 ok=false）。
-- ponytail: 備份經 readLine 逐行 concat("\n") 還原，為「逐行內容一致」（JSON 可還原），行尾符/CRLF
--   不保留——Kahlua 無讀原始位元組的 API，且既有 readRawZones 亦同限制。
function MinidoracatZonesShared.generateTemplateForLanguage(langCode)
    local ok, result = pcall(function()
        local wp, rw, br, ml, doc
        if langCode == nil then
            wp = tplText("UI_MinidoracatMiniMapZones_TplWestPoint", "Demo zone: West Point Police")
            rw = tplText("UI_MinidoracatMiniMapZones_TplRosewood", "Demo zone: Rosewood Fire Dept")
            br = tplText("UI_MinidoracatMiniMapZones_TplBunker", "Demo zone: March Ridge Bunker")
            ml = tplText("UI_MinidoracatMiniMapZones_TplMultiRect", "Demo zone: multi-rect L-shape (Riverside)")
            doc = tplText("UI_MinidoracatMiniMapZones_TplDoc", DEMO_DOC_ASCII)
        else
            local all = MinidoracatZonesJson.decode(TPL_STRINGS_JSON)
            local L = type(all) == "table" and all[langCode]
            if type(L) ~= "table" or type(L.wp) ~= "string" or type(L.rw) ~= "string"
                or type(L.br) ~= "string" or type(L.ml) ~= "string" or type(L.doc) ~= "string" then
                return { ok = false, wrotePath = nil, backedUp = false }  -- 未知語系
            end
            wp, rw, br, ml, doc = L.wp, L.rw, L.br, L.ml, L.doc
        end
        local content = assembleTemplate(
            buildDemoZoneLines(tplJsonEscape(wp), tplJsonEscape(rw), tplJsonEscape(br), tplJsonEscape(ml)),
            tplJsonEscape(doc))

        -- 讀舊 zones.json：逐行累加（供備份）＋偵測是否有非空白內容。
        -- probe 同 writeZonesTemplate（0-byte／全空白視同缺檔 → 直接寫 zones.json、不備份）。
        local sep = getFileSeparator()
        local zonesPath = "MinidoracatMiniMapZones" .. sep .. "zones.json"
        local oldLines, hasContent, oldBytes = {}, false, 0
        local reader = getFileReader(zonesPath, false)
        if reader then
            while true do
                local line = reader:readLine()
                if line == nil then break end
                oldBytes = oldBytes + utf8ByteLen(line) + 1  -- UTF-8 byte 估（非 code unit #）
                -- 同 readRawZones 的 maxFileBytes 上限：外部工具寫出超大檔時不無界讀入
                -- 記憶體；超限即中止（zones.json 不動、不備份不覆寫）
                if oldBytes > MinidoracatZonesShared.LIMITS.maxFileBytes then
                    reader:close()
                    return { ok = false, wrotePath = nil, backedUp = false, bakName = nil }
                end
                oldLines[#oldLines + 1] = line
                if MinidoracatZonesShared.hasNonBlank(line) then hasContent = true end
            end
            reader:close()
        end

        -- 有內容：先原樣備份到 zones.json.<時間戳>.bak，成功才覆寫。備份失敗 → 中止，zones.json 不動。
        local backedUp = false
        local bakName = nil
        if hasContent then
            bakName = "zones.json." .. MinidoracatZonesShared.backupStamp() .. ".bak"
            local bakPath = "MinidoracatMiniMapZones" .. sep .. bakName
            local bakWriter = getFileWriter(bakPath, true, false)
            if not bakWriter then return { ok = false, wrotePath = nil, backedUp = false, bakName = nil } end
            local expected = table.concat(oldLines, "\n")
            bakWriter:write(expected)
            bakWriter:close()
            -- 讀回驗證：PZ getFileWriter 包 java PrintWriter，IO 失敗被吞不拋（LuaManager.java:6659-6670/12735
            -- 已反編譯證實）→ write/close 回來不代表資料真的落地。逐行讀回 bak concat("\n") 與寫入內容
            -- 完全相等才算備份成功；讀不到／不相等 → 中止，zones.json 一位元組不動（絕不無備份覆寫）。
            local verifyReader = getFileReader(bakPath, false)
            if not verifyReader then return { ok = false, wrotePath = nil, backedUp = false, bakName = nil } end
            local backParts = {}
            while true do
                local line = verifyReader:readLine()
                if line == nil then break end
                backParts[#backParts + 1] = line
            end
            verifyReader:close()
            if table.concat(backParts, "\n") ~= expected then
                return { ok = false, wrotePath = nil, backedUp = false, bakName = nil }
            end
            backedUp = true
        end

        local writer = getFileWriter(zonesPath, true, false)
        if not writer then return { ok = false, wrotePath = nil, backedUp = false, bakName = nil } end
        writer:write(content)
        writer:close()
        return { ok = true, wrotePath = "zones.json", backedUp = backedUp, bakName = bakName }
    end)
    if not ok then return { ok = false, wrotePath = nil, backedUp = false } end
    return result
end

-- 執行期檔案消失時重生「空範本」{ "zones": [], "_doc": ... }：區域清空但檔案隨時存在。
-- 回傳同 ensureZonesTemplate（true＝檔已存在或寫入成功；false＝寫入失敗）。
function MinidoracatZonesShared.ensureZonesTemplateEmpty()
    local ok, result = pcall(function()
        return writeZonesTemplate({})
    end)
    if not ok then return false end
    return result
end
