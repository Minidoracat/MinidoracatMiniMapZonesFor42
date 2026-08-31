-- MinidoracatZonesShared.lua
-- Zones 驗證器＋wire 短欄位名編解碼——server（讀 zones.json）與 client（SP fallback，
-- 見計畫 Phase 3 step 8）共用。純資料驗證＋檔名契約與 legacy 遷移，方便兩端呼叫同一套規則。
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

-------------------------------------------------------------------------------
-- 檔名契約（0.3.0 起）：正典檔＝zones.json。
--
-- getFileWriter 副檔名白名單（ALLOWED_FILE_EXTENSIONS，不合白名單**靜默回 null**）的演進，
-- 三份反編譯快照逐版比對定案：
--   · 42.19  ：無白名單（任何副檔名可寫）
--   · 42.20.0：{ini,cfg,txt,log}（LuaManager.java:2726、判定 :6716）——.json 寫不出，
--              這是 0.2.0 暫時改用 zones.txt 的唯一原因
--   · 42.20.1+：{ini,cfg,txt,log,**json**}（LuaManager.java:1034、判定 :6730）——json 解禁
-- 故 0.3.0 起正典檔改回 zones.json（0.1.0 原檔名，內容格式從頭到尾都是 JSON，只有副檔名
-- 反覆過）；備份檔為 zones.<時間戳>.bak.json——ZomboidFileSystem.getFileExtension 取
-- **最後一個點之後**（:1436-1440），故 extension＝json 過白名單，裸 .bak 仍寫不出。
-- 白名單比對走 Set.of 且不 lower-case ⇒ **大小寫敏感**，副檔名一律小寫。
-- versionMin=42.20.1 把 42.20.0 擋在門外（ChooseGameInfo.isAvailableSelf :640-644），
-- 不讓 0.2.0 那種「寫檔靜默全滅」重演。
--
-- zones.txt 為 0.2.0 legacy——僅讀（getFileReader 無白名單，LuaManager.java:5919-5950）、
-- 永不寫，首次啟動一次性遷移進 zones.json（見 migrateLegacyZones）。
-- 外部程式 0.3.0 起請改寫 zones.json。
-------------------------------------------------------------------------------
MinidoracatZonesShared.ZONES_DIR = "MinidoracatMiniMapZones"
MinidoracatZonesShared.ZONES_FILENAME = "zones.json"
MinidoracatZonesShared.ZONES_FILENAME_LEGACY = "zones.txt"

function MinidoracatZonesShared.zonesPath()
    return MinidoracatZonesShared.ZONES_DIR .. getFileSeparator()
        .. MinidoracatZonesShared.ZONES_FILENAME
end

function MinidoracatZonesShared.zonesLegacyPath()
    return MinidoracatZonesShared.ZONES_DIR .. getFileSeparator()
        .. MinidoracatZonesShared.ZONES_FILENAME_LEGACY
end

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
    border = true, borderAlpha = true, haloAlpha = true, category = true,
    meta = true, enabled = true,
    -- lodRect 是「計算欄位」（attachLodRect 依聯集尺寸決定，不讀使用者輸入）：
    -- 列 known 使手寫的頂層 lodRect 被靜默丟棄，而非依未知欄位規則塞進
    -- meta.lodRect 占 wire bytes（codex review 抓出的窄例外）
    lodRect = true,
}

local INF = 1 / 0

-- 建物尺度 LOD 門檻（ZN-3）：區域 rects 聯集 AABB 的最長邊 <= 此值才附 lodRect
-- 進主 MOD 三檔縮放 LOD（<1.5px/格 隱藏、<6 聯集框純填色、>=6 完整細節——框線
-- 與名稱僅細節檔）。大範圍區域（PVP 區、城區標記——伺服器區域的主用途）不附、
-- 維持任何縮放可見：拉遠消失會違反其「全圖展示」語意。門檻是啟發式：100 格
-- 約當最大型建物（Louisville 商場 273 格寬不附、一般商店街區 <100 附）。
local LOD_MAX_EDGE = 100

-- 對正規化 zone 就地附 lodRect（純 Lua、每 zone 驗證/解包時一次、非每幀）。
-- SP 路（validateZones）與 MP 路（unpackZone）都要過這裡；lodRect 刻意不進
-- wire（client 端重算即可，不佔廣播 bytes）。空 rects 不附。
local function attachLodRect(zone)
    local rects = zone.rects
    if not rects or not rects[1] then return zone end
    local r1 = rects[1]
    local x1, y1, x2, y2 = r1.x1, r1.y1, r1.x2, r1.y2
    for i = 2, #rects do
        local r = rects[i]
        if r.x1 < x1 then x1 = r.x1 end
        if r.y1 < y1 then y1 = r.y1 end
        if r.x2 > x2 then x2 = r.x2 end
        if r.y2 > y2 then y2 = r.y2 end
    end
    local w = x2 - x1
    local h = y2 - y1
    local edge = w > h and w or h
    if edge <= LOD_MAX_EDGE then
        zone.lodRect = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    end
    return zone
end

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
MinidoracatZonesShared.wireBytes = estimateWireBytes

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

    -- haloAlpha（選填，預設 nil＝不畫）：主 MOD fill pass 的暗色底襯描邊——
    -- 每可見矩形 1 次 drawPolygon，取代 border 的每矩形 4 次 drawLine（全縮放檔）。
    -- 檔位（主 MOD 42.20.1-0.14.1 起）：帶 lodRect 的建物尺度區域僅細節檔畫；
    -- 未附 lodRect 的大範圍區域（attachLodRect 的 >LOD_MAX_EDGE 側）全檔位畫
    -- ——恆顯區域的描邊跟著填色走。0.14.0 主 MOD 為細節檔限定，行為差異僅
    -- 大範圍區域拉遠時多描邊，屬純增益、無相容性問題。
    -- 推薦組合 "borderAlpha": 0, "haloAlpha": 0.5＝便宜描邊；預設不設不改變既有
    -- 伺服器外觀。渲染端對 nil 短路（主 MOD MinidoracatMiniMap.lua fill pass），
    -- 舊版主 MOD 讀到多餘欄位自然忽略，zoneApiVersion 不需升版
    local haloAlpha = nil
    if raw.haloAlpha ~= nil then
        local a = clampAlpha(raw.haloAlpha)
        if not a then return fail("haloAlpha wrong type (need number)") end
        haloAlpha = a
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
        haloAlpha = haloAlpha,
        category = category,
        meta = meta,
    }
    attachLodRect(zone) -- 建物尺度才附（ZN-3）；不進 wire，不影響下方 byte 檢查


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
    border = "bc", borderAlpha = "ba", haloAlpha = "ha", category = "cat",
    meta = "mt",
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
    if zone.haloAlpha then wire[F.haloAlpha] = zone.haloAlpha end
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
    local zone = {
        id = wire[F.id],
        name = wire[F.name],
        rects = rects,
        fill = { r = fc[1], g = fc[2], b = fc[3] },
        fillAlpha = wire[F.fillAlpha],
        border = { r = bc[1], g = bc[2], b = bc[3] },
        borderAlpha = wire[F.borderAlpha],
        haloAlpha = wire[F.haloAlpha],
        category = wire[F.category],
        meta = wire[F.meta],
    }
    return attachLodRect(zone)
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

-- 讀 sandbox 輪詢間隔（min 10 / max 3600 / default 60，見 sandbox-options.txt）；
-- nil-safe＋clamp。server（OnServerStarted）與 client SP fallback（OnGameStart）共用。
function MinidoracatZonesShared.getPollInterval()
    local sb = SandboxVars and SandboxVars.MinidoracatMiniMapZones
    local v = sb and sb.PollIntervalSeconds
    if type(v) ~= "number" then return 60 end
    if v < 10 then return 10 end
    if v > 3600 then return 3600 end
    return v
end

-------------------------------------------------------------------------------
-- 範本：Zomboid/Lua/MinidoracatMiniMapZones/zones.json。兩種入口——
--   ensureZonesTemplate（首次啟動，檔不存在→含四個示範區域，玩家照著改）；
--   ensureZonesTemplateEmpty（執行期檔案消失→重生空範本 { "zones": [] }，區域清空但檔案隨時
--     存在，保留「刪檔＝清空」語意）。兩者共用內部 writeZonesTemplate（遷移閘＋probe＋_doc＋IO）。
-- server（OnServerStarted／pollNow）與 client SP fallback（首讀前／spPollNow）呼叫；
-- MP client 絕不呼叫（伺服器權威，見 client 檔）。
--
-- 引擎 API 出處（AGENTS.md 鐵則：禁憑記憶寫 PZ API；行號為 42.20 反編譯）：
--   getFileWriter(filename, createIfNull, append) → LuaManager.java:6715-6751
--     · **副檔名白名單** {ini,cfg,txt,log,json}（ALLOWED_FILE_EXTENSIONS :1034、
--       判定 :6730）——不合白名單**靜默回 null**；42.20.0 曾少了 json（:2726/:6716）
--       致 0.2.0 全面改 .txt，42.20.1 加回來後 0.3.0 改回 .json，見檔頭契約段
--     · root＝getLuaCacheDir()（Zomboid/Lua/，與 getFileReader 同根）；filename 內 `/`\`
--       皆 normalize 成 File.separator，父資料夾 mkdirs() 自動建
--     · createIfNull=true → 檔不存在時建檔；UTF-8 PrintWriter
--     vanilla 用例 getFileWriter(name,true,false)：client/PZAPI/ModOptions.lua:260
--   writer:write(str) → client/ISUI/ISLayoutManager.lua:174；writer:close() → :185
--   getFileReader（**無白名單**，.json 仍可讀）→ LuaManager.java:5919-5950；
--     探測存在（reader nil＝不存在）＋ reader:close() → client/PZAPI/ModOptions.lua:289
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

-- 探測檔案內容三態：nil＝不存在；false＝存在但 0-byte/全空白；true＝存在且有非空白內容。
-- writeZonesTemplate 的「0-byte/全空白視同缺檔」probe 與 legacy 遷移共用（單一語意來源）。
local function probeFileContent(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local hasContent = false
    while true do
        local line = reader:readLine()
        if line == nil then break end
        if MinidoracatZonesShared.hasNonBlank(line) then hasContent = true; break end
    end
    reader:close()
    return hasContent
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
local function buildDemoZoneLines(wp, rw, br, ml, ct, cf)
    return {
        '    { "name": "' .. wp .. '", "rects": [[11882, 6928, 11918, 6961]], "fill": "#3B82F6", "fillAlpha": 0.3, "border": "#3B82F6", "borderAlpha": 0, "haloAlpha": 0.5, "category": "' .. ct .. '" },',
        -- ^ West Point 示範「便宜描邊」組合（ZN-1）：borderAlpha 0＝不畫框線（省每矩形
        --   4 次 drawLine/幀）、haloAlpha 0.5＝主 MOD 細節檔的暗色底襯描邊（每矩形 1 次
        --   drawPolygon）。其餘三筆維持傳統框線示範，兩種樣式玩家都看得到
        '    { "name": "' .. rw .. '", "rects": [[8123, 11723, 8163, 11757]], "fill": "#FF3B30", "fillAlpha": 0.3, "border": "#FF3B30" , "category": "' .. ct .. '" },',
        '    { "name": "' .. br .. '", "rects": [[9916, 12595, 9986, 12651]], "fill": "#22C55E", "fillAlpha": 0.3, "border": "#22C55E" , "category": "' .. cf .. '" },',
        '    { "name": "' .. ml .. '", "rects": [[6115, 5235, 6150, 5285], [6115, 5285, 6180, 5320]], "fill": "#F59E0B", "fillAlpha": 0.3, "border": "#F59E0B", "enabled": true , "category": "' .. ct .. '" }',
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

-- legacy 遷移 marker（0.3.0）：Zomboid/Lua/MinidoracatMiniMapZones/migratedToJsonV2.txt。
-- 語意＝「0.2.0 的 zones.txt 已一次性處置完畢，之後 zones.json 是唯一正典」。marker 存在後，
-- 刪除 zones.json 的行為：執行期刪除→重生「空範本」（清空區域）；關服期間刪除→下次啟動
-- 重生「示範範本」——兩者皆**絕不**從殘留的 zones.txt 復活資料（Lua 無刪檔 API，殘留的
-- legacy 檔永遠在磁碟上，marker 是唯一判定依據）。比照主 MOD keyMigratedV1 先例。
--
--
-- 為何**不**讀 0.2.0 的 V1 marker（legacyMigratedV1.txt）來判定既存 zones.json 是不是
-- 過期殘骸（設計上刻意放棄的一條路，codex 對抗式審查抓出）：V1 marker 在 0.2.0 有四種
-- 寫入情境（migrated / no legacy / legacy blank / zones.txt already present），其中三種
-- 完全不代表「磁碟上現在有一份過期的 zones.json」。以它為據去 truncate 非空的 zones.json
-- 會誤刪真實資料（0.2.0 期間手動重建、只還原 json 的備份、降版又升版⋯⋯）。
-- 取捨：寧可讓極少數「0.2.0 關服期間刪掉 zones.txt、且留有 42.19 舊 json」的使用者在升級後
-- 看到舊區域重新出現（**可見、可自行編輯/清空、零資料損失**），也不做基於推論的破壞性刪除。
-- README／CHANGELOG 已提示升級後確認 zones.json 內容。
local function markerPath()
    return MinidoracatZonesShared.ZONES_DIR .. getFileSeparator() .. "migratedToJsonV2.txt"
end

local function writeMarker(note)
    local w = getFileWriter(markerPath(), true, false)
    if not w then return false end
    w:write("MinidoracatMiniMapZones legacy handled: " .. tostring(note) .. "\n")
    w:close()
    return true
end

-- 檔案是否存在，**三態**（cacheFileExists＝同根 CacheDir/Lua 的純 exists 檢查、@LuaMethod
-- 全域，42.20.2 反編譯 LuaManager.java:5545-5550）：
--   true＝存在／false＝確定不存在／**nil＝探測失敗，未知**。
-- 把「探測失敗」壓成 false 等於謊稱檔案不存在，下游會據此覆寫真實檔案；未知一律讓呼叫端
-- fail closed。離線測試環境無 cacheFileExists 全域時回 false（確定不存在，維持既有語意）。
local function fileExists(path)
    if cacheFileExists == nil then return false end
    local ok, exists = pcall(cacheFileExists, path)
    if not ok then return nil end  -- 探測本身失敗＝未知
    return exists and true or false
end

-- 逐行讀檔（帶 maxFileBytes 上限，外部檔＝信任邊界，不無界吃記憶體）。
-- 回傳 string＝內容（行以 "\n" 接回）／nil＝getFileReader 回 nil／false＝超過上限。
-- ⚠ 這裡的 nil **不等於「檔不存在」**——42.20 getFileReader 對「不存在」與「存在但開檔
-- IOException」都回 null。需要區分者一律用 readFileCappedStrict（見下），別直接吃這個 nil。
-- ponytail: 行終止符不保留（readLine 拿不到）——寫回/驗證端一律以 "\n" 接回為準。
-- 公開：server pollNow 與 client spPollNow 讀 zones.json 也走此函式（三態＋1MB gate
-- 單一實作；string 可能 ""＝存在但空檔）。
local function readFileCapped(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local maxBytes = MinidoracatZonesShared.LIMITS.maxFileBytes
    local parts, total = {}, 0
    while true do
        local line = reader:readLine()
        if line == nil then break end
        total = total + MinidoracatZonesShared.utf8ByteLen(line) + 1
        if total > maxBytes then reader:close(); return false end
        parts[#parts + 1] = line
    end
    reader:close()
    return table.concat(parts, "\n")
end
MinidoracatZonesShared.readFileCapped = readFileCapped

-- 把檔案清空（Lua 無刪檔 API；getFileWriter append=false 即 truncate，42.20.2 反編譯
-- LuaManager.java:6753 FileOutputStream(outFile, append)）。空檔在 probeFileContent
-- 與 writeZonesTemplate 眼中「視同缺檔」，故等效於刪除。回 true＝成功。
-- 回 true＝確認已清空（讀回驗證過）；false＝writer 取不到、或清空後讀回仍有內容。
-- 必須驗證：清不乾淨會留下非空半寫檔，下次啟動可能被誤認成有效內容／有效備份收據。
local function truncateFile(path)
    local w = getFileWriter(path, true, false)
    if not w then return false end
    w:write("")
    w:close()
    local back = readFileCapped(path)
    return back == "" or back == nil
end

-- 寫檔＋逐行讀回驗證。**PZ 的 getFileWriter 包 java PrintWriter，IO 失敗被吞不拋**
-- （42.20.2 反編譯：getFileWriter LuaManager.java:6729-6765 只在建構期 catch IOException，
-- 包裝類 LuaFileWriter:12751-12770 的 write/close 直接轉呼 PrintWriter——PrintWriter 自身
-- 吞 IOException 只設旗標）→ write/close 回來不代表資料真的落地，故凡是「資料不可遺失」
-- 的寫入一律走此函式（遷移搬運、遷移前備份、生成按鈕備份）。
-- 回 true＝內容確認落地；false＝getFileWriter 回 nil／讀不回／讀回不符。
-- 只給「失敗就整個放棄、不需要對半寫檔做損害控制」的呼叫端用（兩處備份：寫不成就中止，
-- 來源檔一位元組不動）。正典檔的寫入**不走這裡**——它需要精確知道「writer 是否已取得」
-- 才能決定要不要 truncate，見 migrateLegacyZonesBody 內展開的版本。
local function writeFileVerified(path, content)
    local w = getFileWriter(path, true, false)
    if not w then return false end
    w:write(content)
    w:close()
    return readFileCapped(path) == content
end

-- readFileCapped 的 fail-closed 版：nil 只在**確定檔案不存在**時才回 nil；
-- 「存在但打不開」「存在性未知」與「超過上限」一律回 false（呼叫端據此中止，
-- 絕不把讀不到的檔誤判成空檔而覆寫掉）。
-- 回傳 string＝內容／nil＝確定不存在／false＝不可讀、未知或超限。
local function readFileCappedStrict(path)
    local content = readFileCapped(path)
    -- ~= false ⇒ 存在(true) 或 未知(nil) 都不算「確定不存在」
    if content == nil and fileExists(path) ~= false then return false end
    return content
end

-- legacy zones.txt 無資料可搬時的收尾：既存的 zones.json **一位元組不動**（它可能是
-- 42.19 使用者的有效資料，也可能是外部工具剛寫的），只補 marker。
-- 本分支不做任何破壞性動作，故 marker 寫入失敗可容忍：下次啟動重入同一分支、狀態完全相同、
-- 零資料損失。（反之若本分支曾 truncate 過檔案，marker 失敗就會讓下次啟動重複破壞——
-- 這正是不做推論式刪除的第二個理由。）
local function finishNoCarryOver()
    writeMarker("no legacy zones.txt to carry over")
    return "none"
end

-- 一次性 legacy 遷移：zones.txt（0.2.0 舊檔）→ zones.json（內容原樣逐行搬運）。
-- 回傳三態："migrated"＝已搬入 zones.json；"none"＝無需遷移（marker 已在／無 legacy／
-- legacy 全空白）；false＝遷移失敗（legacy 超過 1MB 上限或不可讀／既有 zones.json 備份
-- 失敗／寫入或讀回驗證不符／marker 寫不出／例外）——此時**不寫 marker**，下次啟動自動重試。
-- marker 嚴格性只施於「legacy 有內容」分支（不變式承載）；無 legacy／全空白分支容忍
-- marker 失敗——該分支不做任何破壞性動作，下次啟動重入同分支、狀態完全相同。
-- 例外（reader/writer 物件拋錯）由外層 pcall 收斂為 false 並快取；若 body 已寫過
-- zones.json 則 best-effort truncate（狀態未知的半寫檔不得被後續啟動追認成正典）。
--
-- ⚠ 順序契約（與 0.2.0 的 V1 正向遷移最關鍵的差異）：**先看 legacy zones.txt 有沒有內容，
-- 再看正典 zones.json**。0.2.0 可以「正典已有內容就早退」，因為當時的正典 zones.txt 不可能
-- 事先存在；反向時正典 zones.json 極可能是 42.19 時代的過期副本（0.2.0 從不寫它、Lua 也
-- 刪不掉）。若沿用早退順序，過期副本會被當成正典保留、使用者 0.2.0 期間的真實資料
-- （在 zones.txt）反而被丟棄。故 legacy 有內容時一律覆寫 zones.json——但**覆寫前必先備份**
-- 到 zones.premigrate.bak.json（不對既有內容做血統推論，見下方註解）。
--
-- session 快取：終態（"migrated"/"none"/false）本 session 只算一次——防 oversize legacy
-- 被 pollNow→ensureZonesTemplateEmpty 穩態迴圈每輪重掃 1MB。false 亦快取（本 session
-- 不再嘗試），下次啟動（新 Lua VM）重試。離線測試以 _migrateSessionResult = nil 重置。
--
-- 已知殘餘（刻意取捨，均為 codex 對抗式審查提出後評估保留）：
--   (1) 讀回不符→truncate 本身再失敗（雙重 IO 失敗）時，壞檔會留到下次啟動被追認——
--       損害有界（legacy 原檔完好在磁碟上；pollNow 每輪 parse failed log 可見）。
--   (2) 讀完 legacy 到寫 marker 之間，外部工具若又改了 zones.txt，該次變更會被遮蔽。
--       窗口＝啟動當下數毫秒，且 0.2.0 的 V1 遷移是同一形狀、已實戰兩週；不為此加
--       hash 重比對。
--   (3) 遷移失敗（false）時 server/SP 仍會照常讀取現有 zones.json，可能顯示到 42.19 時代
--       的舊區域。刻意不擋：擋了會連「marker 寫失敗但內容其實已正確搬完」與
--       「getFileWriter 全壞但 zones.json 完全正常」的情況一起遮蔽，代價更大。
--       區域純屬地圖標示、不影響遊戲機制，且 console 有明確 FAILED log、下次啟動自動重試。
local migrateTouchedJson = false  -- body 是否已寫過 zones.json（外層例外處置用）

local function migrateLegacyZonesBody()
    -- marker 判定 fail-closed：probeFileContent 的 nil 含「存在但打不開」，若當成「沒 marker」
    -- 就會在 IO 抖動時重跑遷移、用殘留 legacy 覆蓋掉遷移後才寫進去的新資料。存在即結案。
    -- `~= false`：fileExists 是三態，nil＝探測失敗＝未知。未知不可當成「沒 marker」——
    -- 那會在 IO 抖動時重跑遷移、用殘留 legacy 覆蓋掉遷移後才寫進去的新資料。
    if probeFileContent(markerPath()) ~= nil or fileExists(markerPath()) ~= false then return "none" end
    local jsonPath = MinidoracatZonesShared.zonesPath()
    local legacyPath = MinidoracatZonesShared.zonesLegacyPath()
    -- 讀 legacy（帶 1MB 上限，同 readFileCapped 語意：外部檔＝信任邊界，不無界吃記憶體）。
    -- strict：false＝超限**或存在但打不開**（不寫 marker，回 false 下次啟動重試——否則
    -- legacy 永不遷移）；nil＝確定不存在。
    local content = readFileCappedStrict(legacyPath)
    if content == false then return false end
    if content == nil then return finishNoCarryOver() end  -- 確定不存在
    if not MinidoracatZonesShared.hasNonBlank(content) then return finishNoCarryOver() end
    -- 尾端換行剝除：readLine 拿不到行終止符，"...}\n\n" 結尾會多出空行——若保留，寫出後
    -- 讀回必少該空行、驗證必不符（合法舊檔被誤判失敗、無限重試）。剝掉尾端 "\n" 使
    -- write→readLine 冪等（只餘行終止符差異，同備份驗證的既知限制）。
    -- 逐字元比較而非 pattern（Kahlua StringLib 相容性，見 tplJsonEscape 註解）。
    while #content > 0 and string.sub(content, #content, #content) == "\n" do
        content = string.sub(content, 1, #content - 1)
    end

    local existing = readFileCappedStrict(jsonPath)
    if existing == false then return false end  -- 超限或不可讀：備份不了就不覆寫
    if existing == content then
        -- 內容已就位（首次即相同，或先前搬運成功、只差 marker）→ 只補 marker，不重寫檔案
        if not writeMarker("migrated from zones.txt") then return false end
        return "migrated"
    end

    -- 覆寫前備份既有的 zones.json（本流程唯一的破壞性動作＝唯一需要備份的動作，同
    -- generateTemplateForLanguage「絕不在無備份下覆蓋」的紀律）。內容多半只是 42.19 遷移
    -- 留下的舊副本，但也可能是使用者手動重建的——不做內容血統推論，一律留一份。
    -- **write-once**：備份檔用固定檔名，已存在就絕不覆寫——它是「搬運前原檔」的收據。
    -- 重試時若無條件重寫，第二輪會把第一輪搬進去的 legacy 內容當成「原檔」蓋掉真正的原檔。
    --
    -- ⚠ 備份存在只證明 **PREPARED**（曾備份過），**不證明 APPLIED**（搬運真的落地）——
    -- 備份成功後 canonical writer 可能取不到、或寫了但驗證不符被 truncate 清空。若只憑
    -- 「備份存在」就結案，legacy 會被永久忽略、正典停在舊資料。故用備份內容當基準判定：
    --   · zones.json 空白／不存在／內容 == 備份 ⇒ 搬運**尚未套用** → 沿用既有備份，繼續搬運
    --   · zones.json 有內容且 ≠ 備份（上方已排除 == legacy 的情況）⇒ 搬運已套用、事後被
    --     外部程式或使用者改過 → **不可用 legacy 覆蓋回去**（資料回滾），保持現狀補 marker 結案
    local bakPath = MinidoracatZonesShared.ZONES_DIR .. getFileSeparator() .. "zones.premigrate.bak.json"
    local bakContent = readFileCappedStrict(bakPath)
    if bakContent == false then return false end  -- 備份存在但讀不到／超限 → 不確定，中止重試
    -- 收據可信度：非空**且能解析成合法 JSON**才算數。清空半寫備份（上方 truncateFile）可能
    -- 自己也失敗（雙重 IO 失敗），留下截斷的破格內容；只看「非空」會把它當成有效收據，
    -- 進而把正典誤判成「已套用後被改過」而寫 marker、legacy 永久被遮蔽。
    -- 破格 ⇒ bakDone=false ⇒ 下一輪重做備份（原檔還在正典檔上，覆蓋掉半寫備份是正確的）。
    local bakDone = type(bakContent) == "string"
        and MinidoracatZonesShared.hasNonBlank(bakContent)
        and pcall(MinidoracatZonesJson.decode, bakContent)
    local jsonBlank = type(existing) ~= "string" or not MinidoracatZonesShared.hasNonBlank(existing)
    if bakDone then
        if not jsonBlank and existing ~= bakContent then
            -- 走到這裡有兩種可能，內容本身是唯一能區分的線索：
            --   (a) 搬運已套用、事後被外部程式／使用者改過 → 內容是合法 JSON。
            --   (b) 先前半寫的殘骸沒清乾淨（truncate 也失敗）→ 內容是截斷的破格文字。
            -- 對 (a) 補 marker 結案（不可用 legacy 覆蓋回去＝資料回滾）；對 (b) **不可寫 marker**
            -- ——寫了就把壞狀態鎖死、legacy 永久被遮蔽，且之後刪 zones.json 只會重生示範範本。
            -- 回 false 則什麼都不動、每次啟動 log 一次，使用者清掉壞檔後下次啟動自動收斂。
            if not pcall(MinidoracatZonesJson.decode, existing) then return false end
            if not writeMarker("zones.json changed after migration; kept as-is") then return false end
            return "none"
        end
        -- 尚未套用 → 直接進搬運，既有備份原封保留（write-once）
    elseif not jsonBlank and not writeFileVerified(bakPath, existing) then
        -- 備份寫失敗可能留下**非空的半寫檔**。若原樣留著，下次啟動的 bakDone 只看「非空」就會
        -- 誤判成有效收據，並因 existing ~= bakContent 而判成「已套用後被外部改過」→ 寫 marker、
        -- legacy 永久被遮蔽。清空它，讓「非空備份」恆等於「已通過讀回驗證的備份」。
        truncateFile(bakPath)
        return false
    end

    -- TOCTOU 收窄：讀 zones.json（上方）到真正取得 writer 之間，外部工具可能又寫了新內容；
    -- 直接 truncate 會把它銷毀，而備份裡只有更早的版本。臨寫前再讀一次比對，不同就中止
    -- （不寫 marker，下次啟動重新評估）。無法完全消除窗口（Lua 沒有原子開檔），但把它從
    -- 「讀檔＋備份＋驗證」整段縮到「比對→getFileWriter」兩步之間。
    if readFileCappedStrict(jsonPath) ~= existing then return false end

    -- 正典檔的寫入刻意展開（不走 writeFileVerified）：必須在**取得 writer 的那一刻**就把
    -- migrateTouchedJson 立起來。getFileWriter 回 nil＝原檔一位元組沒被碰過，**絕不能去
    -- truncate**（回 nil 除了白名單不合，也可能是暫時性 FileOutputStream IOException，
    -- 42.20.2 反編譯 LuaManager.java:6756-6759——此時後續的 truncate 反而可能成功，
    -- 等於親手清掉一個我們沒動過的檔）。旗標放在 write/close/讀回之前，讀回途中拋例外時
    -- 外層 pcall 也能正確做損害控制。
    local writer = getFileWriter(jsonPath, true, false)
    if not writer then return false end
    migrateTouchedJson = true
    writer:write(content)
    writer:close()
    if readFileCapped(jsonPath) ~= content then
        -- 讀回不符＝損壞內容已落在正典檔上（Lua 無刪檔 API）→ 清空回「全空白視同缺檔」
        -- 再回 false，否則下次啟動會把壞檔追認成正典、永久遮蔽 legacy。
        truncateFile(jsonPath)
        return false
    end
    if not writeMarker("migrated from zones.txt") then return false end
    return "migrated"
end

function MinidoracatZonesShared.migrateLegacyZones()
    if MinidoracatZonesShared._migrateSessionResult ~= nil then
        return MinidoracatZonesShared._migrateSessionResult
    end
    migrateTouchedJson = false
    local ok, r = pcall(migrateLegacyZonesBody)
    if not ok then
        if migrateTouchedJson then
            -- 例外前已寫過 zones.json＝狀態未知，best-effort truncate（同讀回不符路徑的理由）
            pcall(function() truncateFile(MinidoracatZonesShared.zonesPath()) end)
        end
        r = false
    end
    MinidoracatZonesShared._migrateSessionResult = r
    return r
end

local function writeZonesTemplate(zoneLines)
    -- 進範本判定前先跑一次性 legacy 遷移（marker 閘，重入安全）。遷移失敗（false）＝
    -- legacy 有內容但搬不進 zones.json → **中止範本寫入**：若在此寫範本，下次啟動
    -- probe 會把範本誤判成正典、寫 marker，legacy 舊資料被示範範本永久遮蔽。
    if MinidoracatZonesShared.migrateLegacyZones() == false then return false end
    local path = MinidoracatZonesShared.zonesPath()
    local probed = probeFileContent(path)
    if probed == true then return true end  -- 已存在且非空 → 不覆寫（含剛遷移完成的情況）
    -- ⚠ probed == nil 有兩義：檔不存在／存在但 getFileReader 打不開。後者若當成缺檔而往下走，
    -- 下方的 getFileWriter(append=false) 會在建檔當下就 truncate（42.20.2 反編譯
    -- LuaManager.java:6753 FileOutputStream(outFile, append)）——把讀不到的**真實正典資料**
    -- 直接輾成示範／空範本。故不確定不存在就一律中止（回 false，呼叫端只 log 一條照常運作）。
    if probed == nil and fileExists(path) ~= false then return false end
    -- 確定不存在／0-byte／全空白 → 重寫範本
    -- 先組完整內容（此前任何失敗都在建檔之前）
    local content = assembleTemplate(zoneLines,
        tplJsonEscape(tplText("UI_MinidoracatMiniMapZones_TplDoc", DEMO_DOC_ASCII)))
    -- TOCTOU 收窄（同 migrateLegacyZonesBody 臨寫前重讀）：上面 probe 到現在，外部工具可能
    -- 剛寫進真實資料；getFileWriter(append=false) 一開就 truncate，會把它輾掉。
    -- ⚠ 這裡**不能**拿新舊 probe 值相等當「沒變」——兩次都回 nil 可能是「一直不存在」，
    -- 也可能是「期間被建立、但這次 reader 剛好打不開」，等於在未知狀態下 fail-open 覆寫。
    -- 只認一種放行條件：**再次確認檔案不存在或全空白**。存在或未知一律中止。
    local reprobe = probeFileContent(path)
    if reprobe == true then return true end  -- 期間被寫入內容 → 範本職責（確保存在且非空）已達成
    if reprobe == nil and fileExists(path) ~= false then return false end
    -- 內容備妥，才建檔。寫後讀回驗證：PrintWriter 吞 IO 不拋，write/close 回來不代表落地——
    -- 沒驗證就回 true 等於謊報成功（呼叫端據此不再 log 任何異常）。
    return writeFileVerified(path, content)
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
        -- 類別演示（實測回饋：範本應自我演示類別篩選）：城鎮×3＋野外×1，
        -- 統一視窗會長出兩個勾選。類別值刻意無逗號/非 sentinel（可編碼契約）
        local ct = tplJsonEscape(tplText("UI_MinidoracatMiniMapZones_TplCatTown", "Demo: Town"))
        local cf = tplJsonEscape(tplText("UI_MinidoracatMiniMapZones_TplCatField", "Demo: Field"))
        return writeZonesTemplate(buildDemoZoneLines(wp, rw, br, ml, ct, cf))
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
local TPL_STRINGS_JSON = '{"CH":{"wp":"\\u793a\\u7bc4\\u5340\\u57df\\uff1aWest Point \\u8b66\\u5c40","rw":"\\u793a\\u7bc4\\u5340\\u57df\\uff1aRosewood \\u6d88\\u9632\\u5c40","br":"\\u793a\\u7bc4\\u5340\\u57df\\uff1aMarch Ridge \\u5730\\u5821","ml":"\\u793a\\u7bc4\\uff1a\\u591a\\u77e9\\u5f62 L \\u5f62\\uff08Riverside\\uff09","ct":"\\u793a\\u7bc4\\uff1a\\u57ce\\u93ae","cf":"\\u793a\\u7bc4\\uff1a\\u91ce\\u5916","doc":"\\u5340\\u57df\\u50c5\\u70ba\\u5730\\u5716\\u986f\\u793a\\u6a19\\u793a\\uff0c\\u4e0d\\u5f71\\u97ff\\u4efb\\u4f55\\u904a\\u6232\\u6a5f\\u5236\\uff08\\u672c MOD \\u7121 PVP\\uff0f\\u5b89\\u5168\\u5340\\u7b49\\u529f\\u80fd\\uff09\\u3002\\u4ee5\\u4e0a\\u70ba\\u793a\\u7bc4\\u5340\\u57df\\uff0c\\u53ef\\u81ea\\u884c\\u4fee\\u6539\\u6216\\u522a\\u9664\\u3002\\u6bcf\\u500b\\u5340\\u57df\\u53ef\\u52a0 \\"enabled\\": false \\u66ab\\u6642\\u96b1\\u85cf\\u800c\\u4e0d\\u5fc5\\u522a\\u9664\\uff08\\u7701\\u7565\\u8996\\u70ba true\\uff09\\u3002\\u5ea7\\u6a19\\u70ba\\u4e16\\u754c square \\u5ea7\\u6a19 [x1,y1,x2,y2]\\uff08\\u5de6\\u4e0a\\u5230\\u53f3\\u4e0b\\uff09\\u3002\\u76f4\\u63a5\\u4ee5\\u4efb\\u4f55\\u8a9e\\u8a00\\u6587\\u5b57\\u7de8\\u8f2f\\u7686\\u53ef\\uff08\\u6a94\\u6848\\u4ee5 UTF-8 \\u8b80\\u53d6\\uff09\\u3002\\u6539\\u6a94\\u5f8c\\u7b49\\u8f2a\\u8a62\\u9593\\u9694\\u6216 admin \\u4e0b /reloadzones \\u7acb\\u5373\\u751f\\u6548\\uff0c\\u7121\\u9700\\u91cd\\u555f\\u3002"},"CN":{"wp":"\\u793a\\u8303\\u533a\\u57df\\uff1aWest Point \\u8b66\\u5bdf\\u5c40","rw":"\\u793a\\u8303\\u533a\\u57df\\uff1aRosewood \\u6d88\\u9632\\u5c40","br":"\\u793a\\u8303\\u533a\\u57df\\uff1aMarch Ridge \\u5730\\u5821","ml":"\\u793a\\u8303\\uff1a\\u591a\\u77e9\\u5f62 L \\u5f62\\uff08Riverside\\uff09","ct":"\\u793a\\u8303\\uff1a\\u57ce\\u9547","cf":"\\u793a\\u8303\\uff1a\\u91ce\\u5916","doc":"\\u533a\\u57df\\u4ec5\\u4e3a\\u5730\\u56fe\\u663e\\u793a\\u6807\\u793a\\uff0c\\u4e0d\\u5f71\\u54cd\\u4efb\\u4f55\\u6e38\\u620f\\u673a\\u5236\\uff08\\u672c MOD \\u65e0 PVP\\uff0f\\u5b89\\u5168\\u533a\\u7b49\\u529f\\u80fd\\uff09\\u3002\\u4ee5\\u4e0a\\u4e3a\\u793a\\u8303\\u533a\\u57df\\uff0c\\u53ef\\u81ea\\u884c\\u4fee\\u6539\\u6216\\u5220\\u9664\\u3002\\u6bcf\\u4e2a\\u533a\\u57df\\u53ef\\u52a0 \\"enabled\\": false \\u6682\\u65f6\\u9690\\u85cf\\u800c\\u4e0d\\u5fc5\\u5220\\u9664\\uff08\\u7701\\u7565\\u89c6\\u4e3a true\\uff09\\u3002\\u5750\\u6807\\u4e3a\\u4e16\\u754c square \\u5750\\u6807 [x1,y1,x2,y2]\\uff08\\u5de6\\u4e0a\\u5230\\u53f3\\u4e0b\\uff09\\u3002\\u76f4\\u63a5\\u4ee5\\u4efb\\u4f55\\u8bed\\u8a00\\u6587\\u5b57\\u7f16\\u8f91\\u7686\\u53ef\\uff08\\u6587\\u4ef6\\u4ee5 UTF-8 \\u8bfb\\u53d6\\uff09\\u3002\\u6539\\u6863\\u540e\\u7b49\\u8f6e\\u8be2\\u95f4\\u9694\\u6216 admin \\u4e0b /reloadzones \\u7acb\\u5373\\u751f\\u6548\\uff0c\\u65e0\\u9700\\u91cd\\u542f\\u3002"},"EN":{"wp":"Demo zone: West Point Police","rw":"Demo zone: Rosewood Fire Dept","br":"Demo zone: March Ridge Bunker","ml":"Demo zone: multi-rect L-shape (Riverside)","ct":"Demo: Town","cf":"Demo: Field","doc":"Zones are map display markers only -- they do not affect gameplay (this mod has no PVP/safe-zone mechanics). The zones above are demos; edit or delete them freely. Add \\"enabled\\": false to a zone to hide it without deleting (omitted means true). Coordinates are world square coordinates [x1,y1,x2,y2] (top-left to bottom-right). You can edit them in any language (the file is read as UTF-8). Changes take effect after the poll interval, or immediately when an admin runs /reloadzones -- no restart needed."},"JP":{"wp":"\\u30c7\\u30e2\\u30be\\u30fc\\u30f3\\uff1aWest Point \\u8b66\\u5bdf\\u7f72","rw":"\\u30c7\\u30e2\\u30be\\u30fc\\u30f3\\uff1aRosewood \\u6d88\\u9632\\u7f72","br":"\\u30c7\\u30e2\\u30be\\u30fc\\u30f3\\uff1aMarch Ridge \\u5730\\u4e0b\\u58d5","ml":"\\u30c7\\u30e2\\u30be\\u30fc\\u30f3\\uff1a\\u8907\\u6570\\u77e9\\u5f62\\u306e L \\u5b57\\uff08Riverside\\uff09","ct":"\\u30c7\\u30e2\\uff1a\\u753a","cf":"\\u30c7\\u30e2\\uff1a\\u91ce\\u5916","doc":"\\u30be\\u30fc\\u30f3\\u306f\\u30de\\u30c3\\u30d7\\u8868\\u793a\\u7528\\u306e\\u30de\\u30fc\\u30ab\\u30fc\\u306e\\u307f\\u3067\\u3001\\u30b2\\u30fc\\u30e0\\u306e\\u52d5\\u4f5c\\u306b\\u306f\\u5f71\\u97ff\\u3057\\u307e\\u305b\\u3093\\uff08\\u3053\\u306e MOD \\u306b PVP\\uff0f\\u5b89\\u5168\\u5730\\u5e2f\\u306a\\u3069\\u306e\\u6a5f\\u80fd\\u306f\\u3042\\u308a\\u307e\\u305b\\u3093\\uff09\\u3002\\u4e0a\\u8a18\\u306f\\u30c7\\u30e2\\u30be\\u30fc\\u30f3\\u3067\\u3059\\u3002\\u81ea\\u7531\\u306b\\u7de8\\u96c6\\u30fb\\u524a\\u9664\\u3067\\u304d\\u307e\\u3059\\u3002\\u5404\\u30be\\u30fc\\u30f3\\u306b \\"enabled\\": false \\u3092\\u8ffd\\u52a0\\u3059\\u308b\\u3068\\u3001\\u524a\\u9664\\u305b\\u305a\\u306b\\u4e00\\u6642\\u7684\\u306b\\u975e\\u8868\\u793a\\u306b\\u3067\\u304d\\u307e\\u3059\\uff08\\u7701\\u7565\\u6642\\u306f true\\uff09\\u3002\\u5ea7\\u6a19\\u306f\\u30ef\\u30fc\\u30eb\\u30c9\\u306e square \\u5ea7\\u6a19 [x1,y1,x2,y2]\\uff08\\u5de6\\u4e0a\\u304b\\u3089\\u53f3\\u4e0b\\uff09\\u3067\\u3059\\u3002\\u4efb\\u610f\\u306e\\u8a00\\u8a9e\\u3067\\u7de8\\u96c6\\u3067\\u304d\\u307e\\u3059\\uff08\\u30d5\\u30a1\\u30a4\\u30eb\\u306f UTF-8 \\u3067\\u8aad\\u307f\\u8fbc\\u307e\\u308c\\u307e\\u3059\\uff09\\u3002\\u5909\\u66f4\\u306f\\u30dd\\u30fc\\u30ea\\u30f3\\u30b0\\u9593\\u9694\\u306e\\u5f8c\\u3001\\u307e\\u305f\\u306f\\u7ba1\\u7406\\u8005\\u304c /reloadzones \\u3092\\u5b9f\\u884c\\u3059\\u308b\\u3068\\u5373\\u5ea7\\u306b\\u53cd\\u6620\\u3055\\u308c\\u3001\\u518d\\u8d77\\u52d5\\u306f\\u4e0d\\u8981\\u3067\\u3059\\u3002"}}'

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
-- 已有內容 → 先把舊內容原樣備份到同目錄 zones.<時間戳>.bak.json（尾綴 .json＝過副檔名
-- 白名單，getFileExtension 只看最後一個點之後，裸 .bak 仍寫不出；每次生成各自保留、
-- 不互相覆蓋；同秒內連按仍同名覆蓋，可接受），備份成功才覆寫 zones.json（backedUp=true）。
-- 備份失敗（getFileWriter 回 nil／IO 例外）→ 中止，zones.json 一位元組不動、回 ok=false
-- ——絕不在沒有備份的情況下覆蓋使用者的 zones.json。
-- 回傳 { ok = bool, wrotePath = "zones.json"|nil, backedUp = bool, bakName = string|nil }。
-- 全段 pcall（組字/decode/IO 任一失敗都回 ok=false 不炸呼叫端；桌面測試對 CJK \u 的
-- string.char range-error 亦於此被吞成 ok=false）。
-- ponytail: 備份經 readLine 逐行 concat("\n") 還原，為「逐行內容一致」（JSON 可還原），行尾符/CRLF
--   不保留——Kahlua 無讀原始位元組的 API，同 readFileCapped 的既知限制。
function MinidoracatZonesShared.generateTemplateForLanguage(langCode)
    local ok, result = pcall(function()
        local wp, rw, br, ml, ct, cf, doc
        if langCode == nil then
            wp = tplText("UI_MinidoracatMiniMapZones_TplWestPoint", "Demo zone: West Point Police")
            rw = tplText("UI_MinidoracatMiniMapZones_TplRosewood", "Demo zone: Rosewood Fire Dept")
            br = tplText("UI_MinidoracatMiniMapZones_TplBunker", "Demo zone: March Ridge Bunker")
            ml = tplText("UI_MinidoracatMiniMapZones_TplMultiRect", "Demo zone: multi-rect L-shape (Riverside)")
            ct = tplText("UI_MinidoracatMiniMapZones_TplCatTown", "Demo: Town")
            cf = tplText("UI_MinidoracatMiniMapZones_TplCatField", "Demo: Field")
            doc = tplText("UI_MinidoracatMiniMapZones_TplDoc", DEMO_DOC_ASCII)
        else
            local all = MinidoracatZonesJson.decode(TPL_STRINGS_JSON)
            local L = type(all) == "table" and all[langCode]
            if type(L) ~= "table" or type(L.wp) ~= "string" or type(L.rw) ~= "string"
                or type(L.br) ~= "string" or type(L.ml) ~= "string" or type(L.doc) ~= "string"
                or type(L.ct) ~= "string" or type(L.cf) ~= "string" then
                return { ok = false, wrotePath = nil, backedUp = false }  -- 未知語系
            end
            wp, rw, br, ml, ct, cf, doc = L.wp, L.rw, L.br, L.ml, L.ct, L.cf, L.doc
        end
        local content = assembleTemplate(
            buildDemoZoneLines(tplJsonEscape(wp), tplJsonEscape(rw), tplJsonEscape(br),
                tplJsonEscape(ml), tplJsonEscape(ct), tplJsonEscape(cf)),
            tplJsonEscape(doc))

        -- 進生成前先跑一次性 legacy 遷移（marker 閘，重入安全）——正常流程 server 啟動的
        -- ensureZonesTemplate 已遷移完；此為 belt-and-suspenders，失敗即中止（同 writeZonesTemplate
        -- 的遮蔽風險理由：不能在 legacy 未搬完前覆寫 zones.json）。
        if MinidoracatZonesShared.migrateLegacyZones() == false then
            return { ok = false, wrotePath = nil, backedUp = false, bakName = nil }
        end
        -- 讀舊 zones.json（供備份）。strict 版含 maxFileBytes 上限（外部工具寫超大檔時不無界
        -- 讀入記憶體）**且**把「存在但打不開」與「確定不存在」分開——false（超限／不可讀）
        -- 一律中止（zones.json 不動、不備份不覆寫），絕不把不可讀的檔誤判成空檔而無備份覆蓋。
        -- nil（確定不存在）／全空白視同缺檔 → 直接寫 zones.json、不備份（同 writeZonesTemplate 的 probe）。
        local sep = getFileSeparator()
        local zonesPath = MinidoracatZonesShared.zonesPath()
        local old = readFileCappedStrict(zonesPath)
        if old == false then return { ok = false, wrotePath = nil, backedUp = false, bakName = nil } end
        local hasContent = type(old) == "string" and MinidoracatZonesShared.hasNonBlank(old)

        -- 有內容：先原樣備份到 zones.<時間戳>.bak.json（寫後讀回驗證，見 writeFileVerified
        -- 註解的 PrintWriter 吞 IO 根因），成功才覆寫。備份失敗 → 中止，zones.json 一位元組
        -- 不動（絕不在無備份的情況下覆蓋使用者的檔案）。
        local backedUp = false
        local bakName = nil
        if hasContent then
            bakName = "zones." .. MinidoracatZonesShared.backupStamp() .. ".bak.json"
            if not writeFileVerified(MinidoracatZonesShared.ZONES_DIR .. sep .. bakName, old) then
                return { ok = false, wrotePath = nil, backedUp = false, bakName = nil }
            end
            backedUp = true
        end

        -- TOCTOU 收窄（同 migrateLegacyZonesBody／writeZonesTemplate）：讀 old＋備份的這段期間，
        -- 外部工具可能剛寫進新資料；直接覆寫會把它銷毀，而備份裡只有更早的版本。臨寫前重讀比對，
        -- 不同即中止（zones.json 一位元組不動；備份已寫成，bakName 照樣回報讓使用者知道在哪）。
        if readFileCappedStrict(zonesPath) ~= old then
            return { ok = false, wrotePath = nil, backedUp = backedUp, bakName = bakName }
        end
        -- 寫後讀回驗證：PrintWriter 吞 IO 不拋，沒驗證就回 ok=true 等於謊報成功。
        -- 失敗時 zones.json 可能已被半寫，但舊內容有**已驗證**的備份（bakName 一併回報）。
        if not writeFileVerified(zonesPath, content) then
            return { ok = false, wrotePath = nil, backedUp = backedUp, bakName = bakName }
        end
        return { ok = true, wrotePath = MinidoracatZonesShared.ZONES_FILENAME, backedUp = backedUp, bakName = bakName }
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
