-- test_zones_lua.lua — E4 regression lock for the Zones cross-file wire contract
-- (review-fixes.md B/C section). Run with a desktop Lua 5.x interpreter:
--   lua scripts/tests/test_zones_lua.lua [repoRoot]
--
-- This does NOT modify any file under 42/media/lua/ -- it only `dofile`s the
-- shared/server modules and pokes at their public surface + Events hooks.
--
-- shared/json (MinidoracatZonesShared.lua, MinidoracatZonesJson.lua) are pure
-- Lua with no PZ engine calls, so they load directly under any Lua 5.x.
-- The server module (MinidoracatMiniMapZonesServer.lua) calls PZ engine
-- globals (Events, getFileReader, isServer, sendServerCommand, ...) -- each
-- check() below stubs exactly what that check's code path touches.
--
-- NOTE on \u unicode (B5): the current fix stores BMP codepoints via
-- string.char(codepoint) directly, matching Kahlua's internal string model
-- (a sequence of UTF-16 code units, per StringLib.java:756) rather than
-- emitting UTF-8 bytes. Desktop/PUC Lua's string.char only accepts 0-255,
-- so this correctly errors here for any codepoint > 0xFF (e.g. 中 U+4E2D) --
-- that is expected under this interpreter and is NOT something this file can
-- verify further; verifying real multi-byte-codepoint handling requires the
-- actual Kahlua/JVM runtime (in-game), out of reach for a scripts/ stub test.
-- This file locks what IS interpreter-portable: surrogate validation logic,
-- and BMP codepoints <= 0xFF.
--
-- Everything below is expected GREEN today (B1-B4, B6, B7, C1-C3 landed in
-- the shared/server executor pass this file was written against). If a
-- future change regresses one of them, the failing check name identifies
-- which review-fixes.md item broke.

local repoRoot = arg[1] or "."
local sharedDir = repoRoot ..
    "/MOD/MinidoracatMiniMapZonesFor42/Contents/mods/MinidoracatMiniMapZonesFor42/42/media/lua/shared"
local serverDir = repoRoot ..
    "/MOD/MinidoracatMiniMapZonesFor42/Contents/mods/MinidoracatMiniMapZonesFor42/42/media/lua/server"

local passCount, failed = 0, {}
local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passCount = passCount + 1
        print("[PASS] " .. name)
    else
        failed[#failed + 1] = name
        print("[FAIL] " .. name .. ": " .. tostring(err))
    end
end

-------------------------------------------------------------------------------
-- Section A: shared validator + wire pack/unpack + json decode (pure logic)
-------------------------------------------------------------------------------

dofile(sharedDir .. "/MinidoracatZonesJson.lua")
dofile(sharedDir .. "/MinidoracatZonesShared.lua")

local function goodZone(overrides)
    local z = { name = "Test Zone", rects = { { 0, 0, 10, 10 } } }
    for k, v in pairs(overrides or {}) do z[k] = v end
    return z
end

check("validator: 好條目通過並正規化", function()
    local result = MinidoracatZonesShared.validateZones({ goodZone() })
    assert(result.count == 1, "count 應為 1")
    assert(#result.errors == 0, "不應有錯誤")
    local z = result.zones[1]
    assert(z.id == "Test Zone", "id 未預設用 name")
    assert(z.fillAlpha == 0.25, "fillAlpha 預設值錯")
    assert(z.borderAlpha == 0.9, "borderAlpha 預設值錯")
    assert(z.rects[1].x1 == 0 and z.rects[1].x2 == 10, "rects 正規化錯誤")
end)

check("validator: 壞條目（缺 rects）記錯不崩潰", function()
    local result = MinidoracatZonesShared.validateZones({ { name = "NoRects" } })
    assert(result.count == 0, "壞條目不應計入 count")
    assert(#result.errors == 1, "應有一筆 error")
end)

check("validator: meta 超過 byte 上限整組捨棄，zone 本身仍合法", function()
    local raw = goodZone({ blob = string.rep("x", 3000) })  -- > maxMetaBytes(2048)
    local result = MinidoracatZonesShared.validateZones({ raw })
    assert(result.count == 1, "zone 本身仍應合法")
    assert(result.zones[1].meta == nil, "超限 meta 應被捨棄")
    local warned = false
    for _, e in ipairs(result.errors) do
        if e:find("meta", 1, true) then warned = true end
    end
    assert(warned, "應記一筆 meta 超限警告")
end)

check("validator: 合法未知欄位透傳進 meta 保留", function()
    local raw = goodZone({ expiresAt = 12345 })
    local result = MinidoracatZonesShared.validateZones({ raw })
    local z = result.zones[1]
    assert(z.meta and z.meta.expiresAt == 12345, "未知欄位應透傳進 meta")
end)

check("validator(B6): raw.meta table 直接落 zone.meta，不被包成 zone.meta.meta", function()
    local raw = goodZone({ meta = { expiresAt = 42 } })
    local result = MinidoracatZonesShared.validateZones({ raw })
    local z = result.zones[1]
    assert(z.meta and z.meta.expiresAt == 42 and z.meta.meta == nil,
        "meta 欄位應被當已知欄位處理，不應巢狀出 zone.meta.meta")
end)

check("validator(B2): JSON null 洞後的合法資料仍被驗證（decoder 填 sentinel，#arr 可信）", function()
    local decoded = MinidoracatZonesJson.decode(
        '[null, {"name":"After Hole","rects":[[0,0,10,10]]}]')
    assert(#decoded == 2, "decode 應以 sentinel 保住陣列長度，得到 #=" .. #decoded)
    local result = MinidoracatZonesShared.validateZones(decoded)
    local foundAfterHole = false
    for _, z in ipairs(result.zones) do
        if z.name == "After Hole" then foundAfterHole = true end
    end
    assert(result.count == 1 and foundAfterHole,
        "null 洞後的合法 zone 應被驗證到，得到 count=" .. result.count)
end)

check("validator(B3): 非有限座標（NaN/inf）應被拒絕", function()
    local infZone = goodZone({ rects = { { 0, 0, math.huge, 10 } } })
    assert(MinidoracatZonesShared.validateZones({ infZone }).count == 0,
        "inf 座標應被拒絕")
    local nan = 0 / 0
    local nanZone = goodZone({ rects = { { 0, 0, nan, 10 } } })
    assert(MinidoracatZonesShared.validateZones({ nanZone }).count == 0,
        "NaN 座標應被拒絕")
end)

check("validator(B4): 超長 id/category 應被拒絕（避免 wire 字串破表）", function()
    local longId = string.rep("a", 40000)
    local result = MinidoracatZonesShared.validateZones({ goodZone({ id = longId }) })
    assert(result.count == 0, "超長 id 應被拒絕")
    local result2 = MinidoracatZonesShared.validateZones({ goodZone({ category = longId }) })
    assert(result2.count == 0, "超長 category 應被拒絕")
end)

check("validator: 無 fillAlpha 但有 alpha（number）別名→採為 fillAlpha，且不透傳進 meta", function()
    local raw = goodZone({ alpha = 0.4 })
    local result = MinidoracatZonesShared.validateZones({ raw })
    assert(result.count == 1, "alias 條目仍應合法")
    local z = result.zones[1]
    assert(z.fillAlpha == 0.4, "fillAlpha 應取 alpha 別名值，得到 " .. tostring(z.fillAlpha))
    assert(z.meta == nil or z.meta.alpha == nil, "alpha 別名一旦採用不應透傳進 meta")
end)

check("validator(enabled): enabled=false 的 zone 跳過不計數＋disabledCount 記 1", function()
    local result = MinidoracatZonesShared.validateZones({
        goodZone({ name = "Shown" }),
        goodZone({ name = "Hidden", enabled = false }),
    })
    assert(result.count == 1, "disabled zone 不應計入 count，得到 " .. result.count)
    assert(result.disabledCount == 1, "disabledCount 應為 1，得到 " .. tostring(result.disabledCount))
    assert(#result.errors == 0, "disabled 非錯誤，不應記 error，得到 " .. #result.errors .. " 筆")
    assert(result.zones[1].name == "Shown", "只應留下顯示中的 zone")
end)

check("validator(enabled): 省略＝視為 true 照常顯示；enabled=true 顯示且不透傳進 meta", function()
    local omitted = MinidoracatZonesShared.validateZones({ goodZone() })
    assert(omitted.count == 1 and omitted.disabledCount == 0,
        "省略 enabled 應照常顯示、disabledCount=0")
    local explicit = MinidoracatZonesShared.validateZones({ goodZone({ enabled = true }) })
    assert(explicit.count == 1, "enabled=true 應照常顯示")
    local z = explicit.zones[1]
    assert(z.meta == nil or z.meta.enabled == nil, "enabled 為已知欄位，不應透傳進 meta")
end)

check("validator(enabled): enabled 非 boolean（字串 yes）→ 記 error 並跳過", function()
    local result = MinidoracatZonesShared.validateZones({ goodZone({ enabled = "yes" }) })
    assert(result.count == 0, "非 boolean enabled 應跳過，不計入 count")
    assert(result.disabledCount == 0, "非 boolean 非 disabled，disabledCount 應為 0")
    assert(#result.errors == 1, "應記一筆 error，得到 " .. #result.errors .. " 筆")
    assert(result.errors[1]:find("enabled must be a boolean", 1, true),
        "error 訊息應含 'enabled must be a boolean'，得到 " .. result.errors[1])
end)

check("validator(enabled): disabled 不佔 maxZones 上限（501 個含 2 disabled → 不觸截斷）", function()
    local raw = {}
    for i = 1, 501 do raw[i] = goodZone({ name = "Z" .. i }) end
    raw[100].enabled = false
    raw[300].enabled = false
    local result = MinidoracatZonesShared.validateZones(raw)
    assert(result.count == 499, "499 個顯示中的 zone 應全過，得到 " .. result.count)
    assert(result.disabledCount == 2, "disabledCount 應為 2，得到 " .. tostring(result.disabledCount))
    local truncated = false
    for _, e in ipairs(result.errors) do
        if e:find("truncated", 1, true) then truncated = true end
    end
    assert(not truncated, "499 顯示 zone 未達 500 上限，不應截斷")
end)

check("validator(fix1): zones 欄位非陣列 → fatal＋errors≥1＋count 0（呼叫端保留舊快取）", function()
    local result = MinidoracatZonesShared.validateZones({ zones = "oops" })
    assert(result.fatal == true, "zones 非陣列應回 fatal，得到 " .. tostring(result.fatal))
    assert(#result.errors >= 1, "fatal 應至少一筆 error，得到 " .. #result.errors)
    assert(result.count == 0, "fatal 應 count=0，得到 " .. tostring(result.count))
    -- 頂層非 table 也應 fatal（同保留舊快取語意）
    assert(MinidoracatZonesShared.validateZones("not a table").fatal == true,
        "頂層非 table 應 fatal")
    -- 正常 { zones = {...} } 不應誤判 fatal
    local good = MinidoracatZonesShared.validateZones({ zones = { goodZone() } })
    assert(good.fatal == nil and good.count == 1, "正常 zones 陣列不應 fatal")
end)

check("validator(fix5): 300 個空 table 的 meta 現被估算超限而捨棄（補洞前 total=0 全放行）", function()
    local blobs = {}
    for i = 1, 300 do blobs[i] = {} end  -- 300 個空 table 的陣列
    local result = MinidoracatZonesShared.validateZones({ goodZone({ meta = blobs }) })
    assert(result.count == 1, "zone 本身仍應合法，得到 " .. result.count)
    assert(result.zones[1].meta == nil, "空 table 陣列 meta 補洞後應超限被捨棄")
    local warned = false
    for _, e in ipairs(result.errors) do
        if e:find("meta", 1, true) then warned = true end
    end
    assert(warned, "應記一筆 meta 超限警告")
end)

check("utf8ByteLen(fix6): ASCII 每字元 1 byte", function()
    assert(MinidoracatZonesShared.utf8ByteLen("hello") == 5, "ASCII 應每字元 1 byte")
    assert(MinidoracatZonesShared.utf8ByteLen("") == 0, "空字串應為 0")
end)

check("utf8ByteLen(fix6): code unit 0x80..0x7FF → 2 bytes（如 é=U+00E9）", function()
    -- 桌面 Lua string.char(0xE9) 為單一 byte 233＝模擬 Kahlua 的單一 UTF-16 code unit 0x00E9，
    -- 落 <0x800 分支 → 2 bytes（等同真機 é 的 UTF-8 長度）。
    assert(MinidoracatZonesShared.utf8ByteLen(string.char(0xE9)) == 2, "0xE9 應為 2 bytes")
    assert(MinidoracatZonesShared.utf8ByteLen(string.char(0x80)) == 2, "0x80 邊界應為 2 bytes")
    assert(MinidoracatZonesShared.utf8ByteLen(string.char(0x7F)) == 1, "0x7F 邊界應為 1 byte")
    assert(MinidoracatZonesShared.utf8ByteLen("A" .. string.char(0xE9)) == 3, "'A'(1)+0xE9(2) 應為 3")
end)

check("utf8ByteLen(fix6)[ENV-LIMITED]: >0xFF code unit（CJK 3-byte／surrogate 4-byte）需實機驗證", function()
    -- 桌面/PUC Lua 的 string 為 UTF-8 byte 序列、string.char 僅收 0-255，無法產生單一 >0xFF 的
    -- code unit（每 byte 必 <0x800），故 >=0x800（CJK 3-byte）與 surrogate（lead 4／trail 0）分支
    -- 在此環境不可達，只能由實機 Kahlua（UTF-16 code unit）驗證。此處僅鎖桌面等價事實：
    -- 任一 0x80..0xFF byte 串長度 == 2×byte 數。
    local s = string.char(0xC3, 0xA9)  -- 桌面 Lua 下 'é' 的 UTF-8 兩 byte，各 <0x800 → 各 2
    assert(MinidoracatZonesShared.utf8ByteLen(s) == 4,
        "桌面 Lua 下兩個 0x80+ byte 各算 2（ENV-LIMITED：真機此為單一 CJK code unit=3）")
end)

check("wire: packZone/unpackZone round-trip", function()
    local raw = goodZone({
        category = "test", meta = { expiresAt = 99 }, fill = "#3aa0ff",
        border = { 255, 0, 0 }, fillAlpha = 0.4, borderAlpha = 0.8,
    })
    local zone = MinidoracatZonesShared.validateZones({ raw }).zones[1]
    local roundtrip = MinidoracatZonesShared.unpackZone(MinidoracatZonesShared.packZone(zone))
    assert(roundtrip.id == zone.id, "id 未保留")
    assert(roundtrip.name == zone.name, "name 未保留")
    assert(#roundtrip.rects == #zone.rects
        and roundtrip.rects[1].x1 == zone.rects[1].x1
        and roundtrip.rects[1].x2 == zone.rects[1].x2, "rects 未保留")
    assert(math.abs(roundtrip.fill.r - zone.fill.r) < 1e-9, "fill 未保留")
    assert(roundtrip.fillAlpha == zone.fillAlpha, "fillAlpha 未保留")
    assert(math.abs(roundtrip.border.r - zone.border.r) < 1e-9, "border 未保留")
    assert(roundtrip.borderAlpha == zone.borderAlpha, "borderAlpha 未保留")
    assert(roundtrip.category == zone.category, "category 未保留")
    assert(roundtrip.meta and roundtrip.meta.expiresAt == 99, "meta 未保留")
end)

check("wire: wireBytes 估算單一 zone 落在 maxZoneWireBytes 之內（B1 驗證器閘）", function()
    local zone = MinidoracatZonesShared.validateZones({ goodZone() }).zones[1]
    local wb = MinidoracatZonesShared.wireBytes(MinidoracatZonesShared.packZone(zone))
    assert(type(wb) == "number" and wb > 0, "wireBytes 應回傳正數")
    assert(wb <= MinidoracatZonesShared.LIMITS.maxZoneWireBytes, "一般 zone 應遠低於單 zone 上限")
end)

check("validator(B1): 單 zone wire 序列化超過 maxZoneWireBytes 應被拒絕", function()
    -- meta 上限(2048 bytes)本身低於 maxZoneWireBytes(60000)，故用多個 rects 撐大 wire size
    local rects = {}
    for i = 1, 64 do rects[i] = { i, i, i + 1, i + 1 } end  -- maxRectsPerZone=64
    local raw = goodZone({ rects = rects, meta = (function()
        local m = {}
        for i = 1, 40 do m["k" .. i] = string.rep("x", 40) end  -- 遠低於 maxMetaBytes 但推高 wire bytes
        return m
    end)() })
    local result = MinidoracatZonesShared.validateZones({ raw })
    -- 這裡不斷言一定被拒絕（64 rects 不必然超過 60000 bytes）；只驗證：若 wire 超限，count 必為 0，
    -- 且 wireBytes 計算與 validateZones 的拒絕判斷一致（同一套 estimator，見 shared 檔內註解）
    if result.count == 1 then
        local wb = MinidoracatZonesShared.wireBytes(MinidoracatZonesShared.packZone(result.zones[1]))
        assert(wb <= MinidoracatZonesShared.LIMITS.maxZoneWireBytes, "通過驗證的 zone 其 wire bytes 應在上限內")
    else
        assert(result.count == 0 and result.errors[1]:find("wire", 1, true),
            "超限應以 wire 相關 error 拒絕")
    end
end)

check("json(B7): JSON 巢狀深度超過上限應報錯而非炸 stack", function()
    local deep = string.rep("[", 200) .. "1" .. string.rep("]", 200)
    local ok = pcall(MinidoracatZonesJson.decode, deep)
    assert(not ok, "超過深度上限應該 decode_error，而非成功或 stack overflow")
end)

check("json(B5): lone/不合法 surrogate 應被拒絕（不落地壞資料）", function()
    assert(not pcall(MinidoracatZonesJson.decode, '"\\ud800"'), "lone high surrogate 應被拒絕")
    assert(not pcall(MinidoracatZonesJson.decode, '"\\ud800\\ud800"'),
        "high+high（非合法 low surrogate）應被拒絕")
end)

check("json(B5): BMP codepoint <= 0xFF 走 string.char(codepoint) 直存路徑", function()
    -- é = 'é' (U+00E9)，落在桌面 Lua string.char 的 0-255 合法範圍內，
    -- 可在此環境驗證「BMP 直接存 codepoint」這條路徑本身沒有算錯（不驗證真正
    -- Kahlua UTF-16 code unit 語意，那需要 in-game 驗證，見檔頭 NOTE）。
    local decoded = MinidoracatZonesJson.decode('"\\u00e9"')
    assert(#decoded == 1 and decoded:byte(1) == 0xE9,
        "應直接存 codepoint 0xE9 為單一 char，得到 bytes=" .. #decoded)
end)

check("json(B5)[ENV-LIMITED]: 中文等 >0xFF codepoint 在桌面 Lua 下預期 range-error", function()
    -- 目前實作對 BMP 一律 string.char(codepoint)（模擬 Kahlua UTF-16 code unit 儲存）。
    -- 桌面/PUC Lua 的 string.char 只收 0-255，所以 codepoint=0x4E2D（中）在這裡必然
    -- range-error——這是本測試環境的限制，不是本測試要鎖的行為；真正驗證需要
    -- 實機/Kahlua。這裡只確認它是「乾淨地報錯」而非靜默產生亂碼位元組。
    local ok, err = pcall(MinidoracatZonesJson.decode, '"\\u4e2d"')
    assert(not ok and tostring(err):find("char", 1, true),
        "預期 string.char range-error（桌面 Lua 限制，見檔頭 NOTE），實際: " .. tostring(err))
end)

-------------------------------------------------------------------------------
-- Section A2: ensureZonesTemplate first-run bootstrap (getFileReader/Writer stub)
-- Stubs the engine globals the function touches; each check sets them fresh.
--
-- 範本改「依遊戲語系用 getText 生成可讀文字」後合法含 UTF-8 多位元組（中文/日文），故舊的
-- 「逐 byte 全 ASCII」硬斷言已移除，改鎖「安全性 + 可解析」：無 BOM、無原始控制字元（<0x20 除
-- 結構 LF；字串內控制字元應被 tplJsonEscape 跳脫）、合法 UTF-8 序列、可被 MinidoracatZonesJson.decode
-- 解析。中文改以「字面 UTF-8」出檔（非 \u escape），桌面 Lua 亦可直接 decode（不再撞 string.char>255）。
-------------------------------------------------------------------------------

-- 範本輸出安全性斷言：無 BOM、無原始控制字元、合法 UTF-8 well-formed。
local function assertTemplateSafe(raw)
    assert(raw:sub(1, 3) ~= "\239\187\191", "範本不應含 UTF-8 BOM")
    for i = 1, #raw do
        local b = string.byte(raw, i)
        assert(b >= 0x20 or b == 0x0a,
            string.format("範本第 %d byte=0x%02X 為原始控制字元（JSON 禁；字串內控制字元應跳脫）", i, b))
    end
    local i, n = 1, #raw
    while i <= n do
        local c = string.byte(raw, i)
        local len
        if c < 0x80 then len = 1
        elseif c >= 0xc2 and c <= 0xdf then len = 2
        elseif c >= 0xe0 and c <= 0xef then len = 3
        elseif c >= 0xf0 and c <= 0xf4 then len = 4
        else error(string.format("範本第 %d byte=0x%02X 非合法 UTF-8 lead byte", i, c)) end
        for j = 1, len - 1 do
            local cc = string.byte(raw, i + j)
            assert(cc and cc >= 0x80 and cc <= 0xbf,
                string.format("範本第 %d byte 非法 UTF-8 continuation", i + j))
        end
        i = i + len
    end
end

check("template(a): 檔缺→getTextOrNull 未載入時退 ASCII fallback，安全性＋數值契約鎖定", function()
    _G.getTextOrNull = nil  -- 無翻譯環境（server 翻譯未載入極端情況）→ tplText 退 ASCII 英文
    local written = {}
    local writerCalls = 0
    _G.getFileSeparator = function() return "/" end
    _G.getFileReader = function() return nil end  -- 檔不存在
    _G.getFileWriter = function(_, createIfNull, append)
        writerCalls = writerCalls + 1
        assert(createIfNull == true and append == false,
            "getFileWriter 參數應為 (path,true,false)")
        return {
            write = function(_, s) written[#written + 1] = s end,
            close = function() end,
        }
    end
    local ret = MinidoracatZonesShared.ensureZonesTemplate()
    assert(ret == true, "寫入成功應回 true")
    assert(writerCalls == 1, "getFileWriter 應恰呼叫一次，得到 " .. writerCalls)
    local raw = table.concat(written, "")

    -- (1) 安全性：無 BOM、無原始控制字元、合法 UTF-8（ASCII fallback 全 ASCII，必然通過）
    assertTemplateSafe(raw)

    -- (2) 可被自家 parser 解析並驗出數值契約（座標/顏色/fillAlpha 結構不變）
    local decoded = MinidoracatZonesJson.decode(raw)
    assert(decoded._doc ~= nil, "範本頂層應含 _doc 說明欄位")
    local result = MinidoracatZonesShared.validateZones(decoded)
    assert(result.count == 4, "範本應驗出 4 個示範區域（_doc 被忽略），得到 " .. result.count)

    local byFrag = function(frag)
        for _, z in ipairs(result.zones) do
            if tostring(z.name):find(frag, 1, true) then return z end
        end
    end
    local wp = byFrag("West Point")
    assert(wp, "應含 West Point 示範區域")
    assert(wp.rects[1].x1 == 11882 and wp.rects[1].y1 == 6928
        and wp.rects[1].x2 == 11918 and wp.rects[1].y2 == 6961, "West Point rects 應為範本值")
    -- fill "#3B82F6" 正規化：r=0x3B/255, g=0x82/255, b=0xF6/255
    assert(math.abs(wp.fill.r - 59 / 255) < 1e-9
        and math.abs(wp.fill.g - 130 / 255) < 1e-9
        and math.abs(wp.fill.b - 246 / 255) < 1e-9, "West Point fill 應為 #3B82F6")
    -- 範本用正式欄位名 fillAlpha（非 alpha 別名），驗其實際生效，非 fallback 到預設 0.25
    assert(wp.fillAlpha == 0.3, "West Point fillAlpha 應為範本值 0.3，得到 " .. tostring(wp.fillAlpha))
    local rw = byFrag("Rosewood")
    assert(rw and rw.fillAlpha == 0.3, "應含 Rosewood 示範區域且 fillAlpha 0.3")
    local mr = byFrag("March Ridge")
    assert(mr and mr.fillAlpha == 0.3, "應含 March Ridge 示範區域且 fillAlpha 0.3")
    -- 第四個為多矩形示範（L 形雙矩形，Riverside）＋帶 "enabled": true 展示欄位存在
    local ml = byFrag("Riverside")
    assert(ml, "應含多矩形示範區域（Riverside）")
    assert(#ml.rects == 2, "多矩形示範應含兩個 rects，得到 " .. #ml.rects)
    assert(ml.rects[1].x1 == 6115 and ml.rects[1].y1 == 5235
        and ml.rects[1].x2 == 6150 and ml.rects[1].y2 == 5285, "多矩形示範第一個 rect 應為範本值")
    assert(ml.rects[2].x1 == 6115 and ml.rects[2].y1 == 5285
        and ml.rects[2].x2 == 6180 and ml.rects[2].y2 == 5320, "多矩形示範第二個 rect 應為範本值")

    -- (3) 無翻譯時 name 為 .lua 內建純 ASCII fallback 全文
    assert(wp.name == "Demo zone: West Point Police",
        "無翻譯應退 ASCII fallback，得到 " .. tostring(wp.name))
end)

check("template(a2): getTextOrNull 回中文/特殊字元→UTF-8 原樣＋JSON 跳脫，decode round-trip 正確", function()
    -- WestPoint name 混入 JSON 必跳脫字元（" \ 換行）＋中文，一次驗「跳脫正確」與「中文原樣通過」。
    -- 字面 Chinese 在桌面 Lua 下即 UTF-8 位元組（測試檔 UTF-8 讀入），正是 in-game getText 回傳形狀的等價。
    local trickyName = '示範"a\\b\nc警局'  -- 中文 + " + 反斜線 + 換行 + 中文
    local docText = "以任何語言文字編輯皆可（檔案以 UTF-8 讀取）。"
    local translations = {
        UI_MinidoracatMiniMapZones_TplWestPoint = trickyName,
        UI_MinidoracatMiniMapZones_TplRosewood = "示範區域：Rosewood 消防局",
        UI_MinidoracatMiniMapZones_TplBunker = "示範區域：March Ridge 地堡",
        UI_MinidoracatMiniMapZones_TplDoc = docText,
    }
    _G.getTextOrNull = function(key) return translations[key] end
    _G.getFileSeparator = function() return "/" end
    _G.getFileReader = function() return nil end
    local written = {}
    _G.getFileWriter = function()
        return { write = function(_, s) written[#written + 1] = s end, close = function() end }
    end
    local ret = MinidoracatZonesShared.ensureZonesTemplate()
    assert(ret == true, "寫入成功應回 true")
    local raw = table.concat(written, "")

    -- 安全性仍成立：字串內的換行/引號/反斜線已被跳脫（無原始控制字元），中文為合法 UTF-8
    assertTemplateSafe(raw)

    -- 中文以字面 UTF-8 出檔，桌面 Lua 直接 decode（無 \u→string.char>255 問題）
    local decoded = MinidoracatZonesJson.decode(raw)
    local result = MinidoracatZonesShared.validateZones(decoded)
    assert(result.count == 4, "範本應驗出 4 個示範區域，得到 " .. result.count)

    -- round-trip：帶 " \ 換行 中文 的 name 經 跳脫→decode 應原樣還原（zones 保序，WestPoint 為第 1 筆）
    local wp = result.zones[1]
    assert(wp.name == trickyName,
        "跳脫/中文 round-trip 失敗：期望 " .. string.format("%q", trickyName)
        .. " 得到 " .. string.format("%q", tostring(wp.name)))
    -- _doc 中文原樣通過
    assert(decoded._doc == docText, "_doc 中文應原樣通過")
end)

check("template(b): 檔已存在（含非空白內容）→不覆寫（getFileWriter 不被呼叫）", function()
    local writerCalls = 0
    local closed = false
    _G.getFileSeparator = function() return "/" end
    -- 新 probe「存在且有非空白內容」才算已存在 → stub 需回非空白內容（yield 一行有內容再 nil）
    _G.getFileReader = function()
        local lines, idx = { '{ "zones": [] }' }, 0
        return { readLine = function() idx = idx + 1; return lines[idx] end,
                 close = function() closed = true end }
    end
    _G.getFileWriter = function()
        writerCalls = writerCalls + 1
        return { write = function() end, close = function() end }
    end
    local ret = MinidoracatZonesShared.ensureZonesTemplate()
    assert(ret == true, "檔已存在應回 true")
    assert(writerCalls == 0, "檔已存在不應呼叫 getFileWriter")
    assert(closed, "探測用 reader 應被 close")
end)

check("template(c): getFileWriter 回 nil→回 false 不拋", function()
    _G.getFileSeparator = function() return "/" end
    _G.getFileReader = function() return nil end
    _G.getFileWriter = function() return nil end
    local ret = MinidoracatZonesShared.ensureZonesTemplate()
    assert(ret == false, "getFileWriter nil 應回 false（不拋）")
end)

-- Task 1：執行期檔案消失 → ensureZonesTemplateEmpty 重生「空範本」
check("template(empty): ensureZonesTemplateEmpty 寫空範本，decode 得 0 區域＋_doc", function()
    _G.getTextOrNull = nil
    _G.getFileSeparator = function() return "/" end
    _G.getFileReader = function() return nil end  -- 檔不存在
    local written = {}
    local writerCalls = 0
    _G.getFileWriter = function(_, createIfNull, append)
        writerCalls = writerCalls + 1
        assert(createIfNull == true and append == false,
            "getFileWriter 參數應為 (path,true,false)")
        return { write = function(_, s) written[#written + 1] = s end, close = function() end }
    end
    local ret = MinidoracatZonesShared.ensureZonesTemplateEmpty()
    assert(ret == true, "寫入成功應回 true")
    assert(writerCalls == 1, "getFileWriter 應恰呼叫一次，得到 " .. writerCalls)
    local raw = table.concat(written, "")
    assertTemplateSafe(raw)  -- 無 BOM、無原始控制字元、合法 UTF-8
    local decoded = MinidoracatZonesJson.decode(raw)
    assert(decoded._doc ~= nil, "空範本頂層應含 _doc 說明欄位")
    local result = MinidoracatZonesShared.validateZones(decoded)
    assert(result.count == 0, "空範本應驗出 0 個區域，得到 " .. result.count)
end)

check("template(empty-b): 檔已存在（含非空白內容）→ ensureZonesTemplateEmpty 不覆寫", function()
    _G.getFileSeparator = function() return "/" end
    _G.getFileReader = function()
        local lines, idx = { '{ "zones": [] }' }, 0
        return { readLine = function() idx = idx + 1; return lines[idx] end, close = function() end }
    end
    local writerCalls = 0
    _G.getFileWriter = function()
        writerCalls = writerCalls + 1
        return { write = function() end, close = function() end }
    end
    assert(MinidoracatZonesShared.ensureZonesTemplateEmpty() == true, "檔已存在應回 true")
    assert(writerCalls == 0, "檔已存在不應呼叫 getFileWriter")
end)

check("template(empty-c): getFileWriter 回 nil → ensureZonesTemplateEmpty 回 false 不拋", function()
    _G.getFileSeparator = function() return "/" end
    _G.getFileReader = function() return nil end
    _G.getFileWriter = function() return nil end
    assert(MinidoracatZonesShared.ensureZonesTemplateEmpty() == false,
        "getFileWriter nil 應回 false（不拋）")
end)

-- Task 1：0-byte／全空白既有檔 → 新 probe 視同缺失 → 重寫範本（使用者實測踩到的空檔卡死）
check("template(blank-probe): 0-byte／全空白既有檔 → probe 視同缺失，重寫範本", function()
    _G.getTextOrNull = nil
    _G.getFileSeparator = function() return "/" end
    -- 外部工具（VS Code 分頁存空緩衝）弄成 0-byte／全空白：檔「存在但空白」。
    -- 舊 probe 只看存在→永不補寫→卡死；新 probe 需讀到非空白字元才算存在。
    local blankLines, idx = { "", "   ", "\t" }, 0  -- 0-byte 行＋全空白行混合
    _G.getFileReader = function()
        idx = 0
        return { readLine = function() idx = idx + 1; return blankLines[idx] end, close = function() end }
    end
    local written, writerCalls = {}, 0
    _G.getFileWriter = function(_, createIfNull, append)
        writerCalls = writerCalls + 1
        assert(createIfNull == true and append == false, "getFileWriter 參數應為 (path,true,false)")
        return { write = function(_, s) written[#written + 1] = s end, close = function() end }
    end
    local ret = MinidoracatZonesShared.ensureZonesTemplate()
    assert(ret == true, "全空白既有檔應重寫範本並回 true")
    assert(writerCalls == 1, "全空白既有檔應觸發重寫恰一次，得到 " .. writerCalls)
    local raw = table.concat(written, "")
    assertTemplateSafe(raw)
    assert(MinidoracatZonesShared.validateZones(MinidoracatZonesJson.decode(raw)).count == 4,
        "重寫的範本應含 4 個示範區域")
end)

-- Task 1：組字移到建檔之前 → 組字階段拋錯不留空檔（getFileWriter 0 次）。
-- tplText 為 local 無法直接 stub；用 getTextOrNull 回非字串（number）逼 tplText 透傳、
-- tplJsonEscape 對其取 #（length）於組字階段拋錯（#number 拋 "attempt to get length"）。
check("template(assembly-fail): 組字失敗發生在建檔前，getFileWriter 0 次（不留空檔）", function()
    _G.getFileSeparator = function() return "/" end
    _G.getFileReader = function() return nil end  -- 檔不存在
    _G.getTextOrNull = function() return 42 end    -- 非字串 → tplJsonEscape #s 於組字階段拋錯
    local writerCalls = 0
    _G.getFileWriter = function()
        writerCalls = writerCalls + 1
        return { write = function() end, close = function() end }
    end
    local ret = MinidoracatZonesShared.ensureZonesTemplateEmpty()
    assert(ret == false, "組字失敗應回 false（呼叫端 pcall 捕捉）")
    assert(writerCalls == 0, "組字失敗發生在建檔前，getFileWriter 不應被呼叫，得到 " .. writerCalls)
end)

-- tplJsonEscape 逐 byte 跳脫（無 gsub/pattern）：JSON 必跳脫者短跳脫、其餘控制字元丟棄、多位元組原樣。
-- tplJsonEscape 為 local，經 ensureZonesTemplate 的 name 間接測（round-trip）。
check("template(esc): 逐 byte 跳脫 \" \\ \\n \\r \\t，其餘控制字元丟棄，多位元組原樣", function()
    local nameIn = 'A"B\\C\tD\12E中'  -- "(跳脫) \(跳脫) TAB(跳脫) FF=0x0C(丟棄) 中文(原樣)
    _G.getTextOrNull = function(key)
        if key == "UI_MinidoracatMiniMapZones_TplWestPoint" then return nameIn end
        return nil  -- 其餘退 ASCII fallback
    end
    _G.getFileSeparator = function() return "/" end
    _G.getFileReader = function() return nil end
    local written = {}
    _G.getFileWriter = function()
        return { write = function(_, s) written[#written + 1] = s end, close = function() end }
    end
    assert(MinidoracatZonesShared.ensureZonesTemplate() == true, "寫入應成功")
    local raw = table.concat(written, "")
    assertTemplateSafe(raw)  -- TAB 已跳脫、FF 已丟棄 → 無原始控制字元；中文合法 UTF-8
    local wp = MinidoracatZonesShared.validateZones(MinidoracatZonesJson.decode(raw)).zones[1]
    -- FF(0x0C) 被丟棄，其餘 round-trip 還原（\" → "、\\ → \、\t → TAB）
    assert(wp.name == 'A"B\\C\tDE中',
        "跳脫/丟棄 round-trip 錯：得到 " .. string.format("%q", tostring(wp.name)))
end)

-- Task 1 附帶：靜態鎖 shared 原始碼不得再有「數字轉義字元類」pattern（Kahlua StringLib 會拋）。
check("static(pattern-safe): MinidoracatZonesShared.lua 無數字轉義字元類 pattern", function()
    local f = io.open(sharedDir .. "/MinidoracatZonesShared.lua", "r")
    assert(f, "應能開啟 shared 原始碼")
    local src = f:read("*a")
    f:close()
    -- 偵測 `[` 或 `[^` 後緊跟「反斜線＋數字」的字元類（如 [\0-\31...]）——真機炸點。
    -- 本測試跑在桌面 Lua，grep 原始碼字串安全；shared 原始碼與註解皆不應再含此序列。
    assert(not src:find("%[%^?\\%d"),
        "偵測到數字轉義字元類 pattern（[\\d…）——Kahlua 會拋 malformed pattern，需改逐 byte 掃描")
end)

-------------------------------------------------------------------------------
-- Section A3: generateTemplateForLanguage (指定語系範本生成 / 不覆蓋語意)
-- EN 與「跟隨當前」(nil) 走可 decode 的 ASCII 路徑，完整鎖內容＋檔案目標邏輯；
-- CH/CN/JP 的 \u CJK 在桌面 Lua 下 string.char>255 range-error（見檔頭 NOTE），四語逐字
-- 內容鎖定改由 scripts/tests/test_tpl_strings.py 負責（Python 無此限制）。
-------------------------------------------------------------------------------

-- 真實 backupStamp 格式鎖（須在下方 harness stub 之前跑）：YYYYMMDD-HHMMSS，毫秒尾碼可選（fix3a）
check("backupStamp: 真實時鐘輸出為 YYYYMMDD-HHMMSS（毫秒尾碼可選）", function()
    local s = MinidoracatZonesShared.backupStamp()
    -- 此環境無 getTimestampMs stub → 走秒級（無尾碼）；pattern 允許可選 -%d%d%d 尾碼
    assert(type(s) == "string" and (s:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$")
        or s:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d%d%d$")),
        "backupStamp 應為 YYYYMMDD-HHMMSS[-mmm]，得到 " .. tostring(s))
end)

-- fix3a：getTimestampMs 可用時附加毫秒尾碼（同秒連按不再撞同名 .bak）
check("backupStamp(fix3a): getTimestampMs 可用時附加 -mmm 毫秒尾碼", function()
    _G.getTimestampMs = function() return 1234567789 end  -- %1000 = 789
    local s = MinidoracatZonesShared.backupStamp()
    _G.getTimestampMs = nil  -- 還原，避免污染後續（其餘測試預期秒級）
    assert(s:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-789$"),
        "應附加 -789 毫秒尾碼，得到 " .. tostring(s))
end)

-- 共用 IO stub 建構器：readerContent=nil → zones.json 不存在（空→直接寫 zones.json、不備份）；
-- 非 nil → zones.json 已有該內容（→先備份 .bak 再覆寫 zones.json）。bakFails=true → 對 *.bak 的
-- getFileWriter 回 nil，模擬備份 getFileWriter 失敗（應中止、zones.json 不被寫）。bakCorrupt=true →
-- .bak 的 getFileWriter 成功但 close 後「落地內容」與寫入不符（模擬 PZ PrintWriter 吞 IO），使 fix3b
-- 讀回驗證失敗（應中止、zones.json 不被寫）。回傳 state：writes 記錄每次寫入 path/parts；files 為
-- path→可讀內容表（getFileReader 依 path 回，zones.json 回 readerContent、.bak 回落地內容供讀回驗證）。
-- 同時 stub 固定時鐘（backupStamp 經 module table 呼叫故可覆蓋）讓備份檔名可斷言；
-- stub 對本檔後續所有測試生效（含 server 段），server 段故只斷言 bakName 樣式不斷言時刻。
local function newGenHarness(readerContent, bakFails, bakCorrupt)
    MinidoracatZonesShared.backupStamp = function() return "20260101-120000" end
    local state = { writes = {}, files = {} }  -- writes[i]={path,parts}; files[path]=可讀內容
    if readerContent ~= nil then
        state.files["MinidoracatMiniMapZones/zones.json"] = readerContent
    end
    _G.getFileSeparator = function() return "/" end
    _G.getFileReader = function(path, _)
        local content = state.files[path]
        if content == nil then return nil end  -- 檔不存在
        local pos = 1
        return {
            readLine = function()
                if pos > #content then return nil end
                local nl = content:find("\n", pos, true)
                local line
                if nl then line = content:sub(pos, nl - 1); pos = nl + 1
                else line = content:sub(pos); pos = #content + 1 end
                return line
            end,
            close = function() end,
        }
    end
    _G.getFileWriter = function(path, createIfNull, append)
        assert(createIfNull == true and append == false, "getFileWriter 參數應為 (path,true,false)")
        if bakFails and path:sub(-4) == ".bak" then return nil end  -- 模擬備份 getFileWriter 失敗
        local rec = { path = path, parts = {} }
        state.writes[#state.writes + 1] = rec
        return {
            write = function(_, s) rec.parts[#rec.parts + 1] = s end,
            close = function()
                -- 落地到可讀檔案表（供 fix3b 讀回驗證）；bakCorrupt 對 .bak 落地不同內容模擬 IO 吞噬
                if bakCorrupt and path:sub(-4) == ".bak" then
                    state.files[path] = "CORRUPTED-BAK-DIFFERENT-FROM-EXPECTED"
                else
                    state.files[path] = table.concat(rec.parts, "")
                end
            end,
        }
    end
    return state
end

-- 內容與檔案目標邏輯用「跟隨當前」(nil) 路徑驗證：走 tplText/getText，getTextOrNull 回 ASCII
-- 即可 decode（指定語系 CH/CN/EN/JP 都會整份 decode 到 CH 的 CJK \u 而 range-error，見下 ENV-LIMITED）。
local GEN_NAMES = {
    UI_MinidoracatMiniMapZones_TplWestPoint = "CUR West",
    UI_MinidoracatMiniMapZones_TplRosewood = "CUR Rose",
    UI_MinidoracatMiniMapZones_TplBunker = "CUR Bunk",
    UI_MinidoracatMiniMapZones_TplMultiRect = "CUR Multi Riverside",
    UI_MinidoracatMiniMapZones_TplDoc = "CUR doc",
}

check("generate(nil): 跟隨當前→zones.json，decode 4 區域（含多矩形）＋名稱取自 getText", function()
    _G.getTextOrNull = function(k) return GEN_NAMES[k] end
    local state = newGenHarness(nil)  -- zones.json 不存在 → 寫 zones.json
    local gen = MinidoracatZonesShared.generateTemplateForLanguage(nil)
    assert(gen.ok == true, "生成應成功")
    assert(gen.wrotePath == "zones.json", "空檔應寫 zones.json，得到 " .. tostring(gen.wrotePath))
    assert(gen.backedUp == false, "缺檔生成不應備份，backedUp 應為 false")
    assert(gen.bakName == nil, "缺檔生成 bakName 應為 nil，得到 " .. tostring(gen.bakName))
    assert(#state.writes == 1 and state.writes[1].path == "MinidoracatMiniMapZones/zones.json",
        "應恰寫入 zones.json 一次（無 .bak）")
    local raw = table.concat(state.writes[1].parts, "")
    assertTemplateSafe(raw)
    local result = MinidoracatZonesShared.validateZones(MinidoracatZonesJson.decode(raw))
    assert(result.count == 4, "範本應 4 區域，得到 " .. result.count)
    assert(result.zones[1].name == "CUR West", "第一區域名稱應取自 getText，得到 " .. tostring(result.zones[1].name))
    assert(result.zones[4].name == "CUR Multi Riverside" and #result.zones[4].rects == 2,
        "第四區域應為多矩形（兩 rects）")
end)

check("generate(有內容→備份+套用): zones.json 有內容→先原樣備份 .bak 再覆寫 zones.json", function()
    _G.getTextOrNull = function(k) return GEN_NAMES[k] end
    local oldContent = '{ "zones": [ { "name": "existing" } ] }'
    local state = newGenHarness(oldContent)  -- zones.json 已有內容
    local gen = MinidoracatZonesShared.generateTemplateForLanguage(nil)
    assert(gen.ok == true, "生成應成功")
    assert(gen.wrotePath == "zones.json", "有內容也一律套用到 zones.json，得到 " .. tostring(gen.wrotePath))
    assert(gen.backedUp == true, "有內容應先備份，backedUp 應為 true")
    assert(gen.bakName == "zones.json.20260101-120000.bak",
        "bakName 應為時間戳備份檔名，得到 " .. tostring(gen.bakName))
    -- 順序：先寫 .bak（原樣備份），再寫 zones.json（新範本）
    assert(#state.writes == 2, "應恰兩次寫入（.bak + zones.json），得到 " .. #state.writes)
    assert(state.writes[1].path == "MinidoracatMiniMapZones/zones.json.20260101-120000.bak",
        "第一次寫入應為時間戳 .bak 備份，得到 " .. state.writes[1].path)
    assert(state.writes[2].path == "MinidoracatMiniMapZones/zones.json",
        "第二次寫入應覆寫 zones.json，得到 " .. state.writes[2].path)
    -- (a) .bak 內容與舊 zones.json byte 相同（單行內容 readLine 逐行 concat 完整還原）
    assert(table.concat(state.writes[1].parts, "") == oldContent,
        ".bak 內容應與舊 zones.json byte 相同")
    -- zones.json 為新 4 區域範本
    local result = MinidoracatZonesShared.validateZones(
        MinidoracatZonesJson.decode(table.concat(state.writes[2].parts, "")))
    assert(result.count == 4, "zones.json 應為新 4 區域範本，得到 " .. result.count)
end)

check("generate(備份失敗→中止): .bak 寫入失敗→中止、zones.json 不被寫、ok=false", function()
    _G.getTextOrNull = function(k) return GEN_NAMES[k] end
    local oldContent = '{ "zones": [ { "name": "existing" } ] }'
    local state = newGenHarness(oldContent, true)  -- *.bak 的 getFileWriter 回 nil（備份失敗）
    local gen = MinidoracatZonesShared.generateTemplateForLanguage(nil)
    assert(gen.ok == false, "備份失敗應回 ok=false，得到 " .. tostring(gen.ok))
    assert(gen.wrotePath == nil, "備份失敗不應回 wrotePath，得到 " .. tostring(gen.wrotePath))
    assert(gen.backedUp == false, "備份失敗 backedUp 應為 false")
    assert(gen.bakName == nil, "備份失敗 bakName 應為 nil，得到 " .. tostring(gen.bakName))
    -- 關鍵：zones.json 一位元組不動（getFileWriter 從未成功寫過 zones.json）
    for _, w in ipairs(state.writes) do
        assert(w.path ~= "MinidoracatMiniMapZones/zones.json",
            "備份失敗絕不可寫 zones.json，卻寫了 " .. w.path)
    end
    assert(#state.writes == 0, "備份失敗不應留下任何成功寫入，得到 " .. #state.writes)
end)

check("generate(fix3b): bak 讀回驗證失敗（PrintWriter 吞 IO）→中止、zones.json 不被寫、ok=false", function()
    _G.getTextOrNull = function(k) return GEN_NAMES[k] end
    local oldContent = '{ "zones": [ { "name": "existing" } ] }'
    local state = newGenHarness(oldContent, false, true)  -- .bak 落地內容與寫入不符
    local gen = MinidoracatZonesShared.generateTemplateForLanguage(nil)
    assert(gen.ok == false, "讀回驗證失敗應回 ok=false，得到 " .. tostring(gen.ok))
    assert(gen.wrotePath == nil, "讀回驗證失敗不應回 wrotePath，得到 " .. tostring(gen.wrotePath))
    assert(gen.backedUp == false and gen.bakName == nil, "讀回驗證失敗不應宣稱備份成功")
    -- 關鍵：zones.json 一位元組不動（.bak 寫過但 zones.json 從未被寫）
    for _, w in ipairs(state.writes) do
        assert(w.path ~= "MinidoracatMiniMapZones/zones.json",
            "讀回驗證失敗絕不可寫 zones.json，卻寫了 " .. w.path)
    end
end)

check("generate(blank→zones.json): zones.json 全空白視同缺檔→寫 zones.json（非 example）", function()
    _G.getTextOrNull = function(k) return GEN_NAMES[k] end
    local state = newGenHarness("   \n\t\n")  -- 存在但全空白
    local gen = MinidoracatZonesShared.generateTemplateForLanguage(nil)
    assert(gen.wrotePath == "zones.json", "全空白應視同缺檔寫 zones.json，得到 " .. tostring(gen.wrotePath))
    assert(gen.backedUp == false, "全空白視同缺檔不應備份，backedUp 應為 false")
    assert(#state.writes == 1 and state.writes[1].path == "MinidoracatMiniMapZones/zones.json",
        "應恰寫 zones.json 一次（無 .bak）")
end)

check("generate(指定語系)[ENV-LIMITED]: 桌面 Lua decode CJK \\u range-error → pcall 吞成 ok=false", function()
    -- TPL_STRINGS_JSON 為單一 JSON 物件，decode 會整份解析；第一個語系 CH 的中文 \u 於桌面/PUC Lua
    -- string.char>255 即 range-error，故「任一」指定語系（含純 ASCII 的 EN）在桌面 Lua 皆 decode 失敗，
    -- 由 generateTemplateForLanguage 外層 pcall 吞成 { ok=false }（不炸 harness）。實機 Kahlua 以 UTF-16
    -- code unit 儲存 BMP codepoint 故四語皆正常生成；四語逐字內容由 test_tpl_strings.py 鎖定（見檔頭 NOTE）。
    _G.getTextOrNull = nil
    local state = newGenHarness(nil)
    for _, lang in ipairs({ "CH", "CN", "EN", "JP", "ZZ" }) do
        local gen = MinidoracatZonesShared.generateTemplateForLanguage(lang)
        assert(gen.ok == false and gen.wrotePath == nil,
            lang .. " 在桌面 Lua 下應 ok=false（ENV-LIMITED/未知語系），得到 ok=" .. tostring(gen.ok))
    end
    assert(#state.writes == 0, "decode 失敗不應留下任何寫入")
end)

-------------------------------------------------------------------------------
-- Section B: server cache replacement + byte budget (Events/engine stub)
-------------------------------------------------------------------------------

-- 共用的引擎 stub 建構器：每個 check() 各自呼叫一次，取得獨立作用域的
-- handlers/fileContent/captured，避免跨 check 互相污染狀態。
local function newServerHarness()
    local state = { fileContent = nil, handlers = {}, sent = {}, written = {}, writerCalls = 0 }
    _G.getFileReader = function(_, _)
        if state.fileContent == nil then return nil end
        local text, pos = state.fileContent, 1
        return {
            readLine = function()
                if pos > #text then return nil end
                local nl = text:find("\n", pos, true)
                local line
                if nl then
                    line = text:sub(pos, nl - 1)
                    pos = nl + 1
                else
                    line = text:sub(pos)
                    pos = #text + 1
                end
                return line
            end,
            close = function() end,
        }
    end
    _G.getFileSeparator = function() return "/" end
    -- 空範本重生（ensureZonesTemplateEmpty）用：捕捉寫出內容與呼叫次數。
    -- getTextOrNull=nil → 範本 _doc 走 ASCII fallback（server 測試不校驗翻譯文字，求確定性）。
    _G.getTextOrNull = nil
    _G.getFileWriter = function(_, _, _)
        state.writerCalls = state.writerCalls + 1
        return { write = function(_, s) state.written[#state.written + 1] = s end, close = function() end }
    end
    _G.isServer = function() return true end
    _G.getTimestampMs = function() return 0 end
    _G.SandboxVars = nil
    _G.Capability = { ManipulateMods = "ManipulateMods" }
    _G.Events = {
        OnServerStarted = { Add = function(fn) state.handlers.onServerStarted = fn end },
        OnClientCommand = { Add = function(fn) state.handlers.onClientCommand = fn end },
        OnTick = { Add = function(fn) state.handlers.onTick = fn end },
        EveryOneMinute = { Add = function(fn) state.handlers.onEveryMinute = fn end },
    }
    _G.sendServerCommand = function(...)
        state.sent[#state.sent + 1] = { ... }
    end
    -- Task 3：語系重同步 stub。預設「選項語言＝生效語言」一致 → resyncTranslatorLanguage no-op，
    -- 現有 server 測試不受影響；Task 3 專屬測試呼叫 newServerHarness 後再覆寫 optionLang/currentLang
    -- 觸發不一致。loadFiles 預設把 currentLang 對齊 optionLang 並計數。
    state.loadFilesCalls = 0
    state.optionLang = "EN"
    state.currentLang = "EN"
    _G.getCore = function()
        return { getOptionLanguageName = function() return state.optionLang end }
    end
    _G.Translator = {
        getLanguage = function() return { name = function() return state.currentLang end } end,
        loadFiles = function()
            state.loadFilesCalls = state.loadFilesCalls + 1
            state.currentLang = state.optionLang
        end,
    }
    dofile(serverDir .. "/MinidoracatMiniMapZonesServer.lua")
    return state
end

check("server: pollNow 對 decode 成功原子替換快取／decode 失敗保留快取", function()
    local state = newServerHarness()
    assert(state.handlers.onServerStarted, "OnServerStarted 未註冊")
    assert(state.handlers.onClientCommand, "OnClientCommand 未註冊")

    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]}]'
    state.handlers.onServerStarted()

    local player = { getRole = function() return { hasCapability = function() return true end } end }

    -- 壞 JSON → reloadResult.ok=false，快取應保留原本 1 筆
    state.sent = {}
    state.fileContent = "{not valid json"
    state.handlers.onClientCommand("MinidoracatMiniMapZones", "reloadZones", player, {})
    local reloadResult
    for _, call in ipairs(state.sent) do
        if call[3] == "reloadResult" then reloadResult = call[4] end
    end
    assert(reloadResult, "應送出 reloadResult")
    assert(reloadResult.ok == false, "壞 JSON 應回報 ok=false")
    assert(reloadResult.count == 1, "快取應保留原本 1 筆，得到 " .. tostring(reloadResult.count))

    -- 好 JSON（2 個 zone）→ 快取應原子替換為 2
    state.sent = {}
    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]},{"name":"Z2","rects":[[20,20,30,30]]}]'
    state.handlers.onClientCommand("MinidoracatMiniMapZones", "reloadZones", player, {})
    reloadResult = nil
    for _, call in ipairs(state.sent) do
        if call[3] == "reloadResult" then reloadResult = call[4] end
    end
    assert(reloadResult and reloadResult.ok == true and reloadResult.count == 2,
        "好 JSON 應原子替換快取為 2 筆")
end)

check("server(B1): enqueueFullSync 依 wire byte budget 分包，不只看 zone 數", function()
    local state = newServerHarness()

    -- 150 個 zone（count-based 舊上限）、每個 name 190 字元 → 若分包只看數量
    -- (150/包) 會遠超 maxPacketWireBytes；現在應依 byte budget 切成多包
    local zones = {}
    local longName = string.rep("N", 190)
    for i = 1, 150 do
        zones[i] = string.format('{"name":"%s%d","rects":[[%d,%d,%d,%d]]}',
            longName, i, i, i, i + 10, i + 10)
    end
    state.fileContent = "[" .. table.concat(zones, ",") .. "]"
    state.handlers.onServerStarted()
    for _ = 1, 20 do state.handlers.onTick() end  -- 消化送包佇列（≤2 包/tick）

    local packets = {}
    for _, call in ipairs(state.sent) do
        if call[2] == "zoneData" then packets[#packets + 1] = call[3] end
    end
    assert(#packets > 1, "150 個長 name zone 應被切成多包，得到 " .. #packets .. " 包")

    local budget = MinidoracatZonesShared.LIMITS.maxPacketWireBytes
    local totalZones = 0
    for i, packet in ipairs(packets) do
        local packetBytes = 0
        for _, wireZone in ipairs(packet.zones) do
            packetBytes = packetBytes + MinidoracatZonesShared.wireBytes(wireZone)
        end
        totalZones = totalZones + #packet.zones
        assert(packetBytes <= budget,
            string.format("封包 #%d 為 %d bytes，超過 budget %d", i, packetBytes, budget))
        -- 同時遠離引擎 1MB 死鎖線，留大量安全邊際
        assert(packetBytes < 200000, string.format("封包 #%d 為 %d bytes，遠超預期安全邊際", i, packetBytes))
    end
    assert(totalZones == 150, "分包後 zone 總數應仍為 150，得到 " .. totalZones)
end)

check("server(task1): 執行期檔案消失 → pollNow 重生空範本恰一次且套用空集(count=0)", function()
    local state = newServerHarness()
    -- 啟動時檔案存在（1 zone）→ ensureZonesTemplate probe 命中，不寫範本
    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]}]'
    state.handlers.onServerStarted()
    assert(state.writerCalls == 0, "檔案存在時啟動不應寫範本，得到 " .. state.writerCalls)

    -- 檔案在執行期消失（getFileReader 回 nil）
    state.fileContent = nil
    state.sent = {}
    local player = { getRole = function() return { hasCapability = function() return true end } end }
    state.handlers.onClientCommand("MinidoracatMiniMapZones", "reloadZones", player, {})

    -- 恰重生一次（reloadZones→pollNow(true)→readRawZones nil→ensureZonesTemplateEmpty→getFileWriter 一次）
    assert(state.writerCalls == 1, "檔案消失應重生空範本恰一次，得到 " .. state.writerCalls)
    -- 寫出的內容 decode 後為 0 區域＋含 _doc
    local raw = table.concat(state.written, "")
    assertTemplateSafe(raw)
    local decoded = MinidoracatZonesJson.decode(raw)
    assert(decoded._doc ~= nil, "重生的空範本應含 _doc")
    assert(MinidoracatZonesShared.validateZones(decoded).count == 0, "空範本應驗出 0 區域")
    -- 套用空集：reloadResult.count == 0
    local reloadResult
    for _, call in ipairs(state.sent) do
        if call[3] == "reloadResult" then reloadResult = call[4] end
    end
    assert(reloadResult and reloadResult.ok == true and reloadResult.count == 0,
        "重生後套用空集，reloadResult.count 應為 0")
end)

check("server(task1-ws): runtime 全空白內容 → 視同空集 count=0，不 decode 不報 parse error", function()
    local state = newServerHarness()
    -- 啟動時 1 zone（probe 命中非空白 → 不寫範本、載入 1 筆）
    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]}]'
    state.handlers.onServerStarted()
    -- 執行期檔案被弄成全空白（外部工具存空緩衝：檔存在但只有空白）
    state.fileContent = "   \n\t \n  "
    state.sent = {}
    local writerBefore = state.writerCalls
    local player = { getRole = function() return { hasCapability = function() return true end } end }
    state.handlers.onClientCommand("MinidoracatMiniMapZones", "reloadZones", player, {})
    local reloadResult
    for _, call in ipairs(state.sent) do
        if call[3] == "reloadResult" then reloadResult = call[4] end
    end
    assert(reloadResult and reloadResult.ok == true and reloadResult.count == 0,
        "全空白內容應視同空集 count=0 ok=true，得到 ok=" .. tostring(reloadResult and reloadResult.ok)
        .. " count=" .. tostring(reloadResult and reloadResult.count))
    assert(#reloadResult.errors == 0, "全空白不應產生 parse error，得到 " .. #reloadResult.errors .. " 筆")
    -- 檔案「存在但空白」非「不存在」→ 不觸發空範本重生（只有 readRawZones 回 nil 才重生）
    assert(state.writerCalls == writerBefore,
        "全空白（檔案存在）不應觸發空範本重生，得到 " .. (state.writerCalls - writerBefore) .. " 次額外寫入")
end)

-- Task 3：伺服器 init 排序 quirk 補救——範本生成前，選項語言≠生效語言時重同步 Translator。
check("server(task3): 選項語言≠生效語言 → OnServerStarted 重同步呼叫 loadFiles 恰一次", function()
    local state = newServerHarness()
    state.optionLang = "CH"     -- options.ini 的 language=CH
    state.currentLang = "EN"    -- 被 init quirk 卡死的生效語言
    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]}]'
    state.handlers.onServerStarted()
    assert(state.loadFilesCalls == 1,
        "語言不一致應觸發 loadFiles 恰一次，得到 " .. state.loadFilesCalls)
    assert(state.currentLang == "CH", "重同步後生效語言應為 CH，得到 " .. state.currentLang)
end)

check("server(task3): 選項語言==生效語言 → 不觸發 loadFiles", function()
    local state = newServerHarness()
    state.optionLang = "CH"
    state.currentLang = "CH"
    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]}]'
    state.handlers.onServerStarted()
    assert(state.loadFilesCalls == 0,
        "語言一致不應觸發 loadFiles，得到 " .. state.loadFilesCalls)
end)

check("server(task3): loadFiles 拋錯 → 補救 pcall 吞掉不炸，OnServerStarted 照常跑完", function()
    local state = newServerHarness()
    state.optionLang = "CH"
    state.currentLang = "EN"
    _G.Translator.loadFiles = function() error("boom") end
    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]}]'
    local ok = pcall(function() state.handlers.onServerStarted() end)
    assert(ok, "loadFiles 拋錯不應讓 OnServerStarted 崩潰")
    assert(state.handlers.onTick ~= nil, "OnServerStarted 應跑完並掛上 OnTick 輪詢")
end)

-- generateTemplate OnClientCommand：capability 閘、不覆蓋語意、pollNow 廣播（EN＝可 decode 路徑）
check("server(gen): 非 admin 的 generateTemplate 被拒（不生成、不回 generateResult）", function()
    local state = newServerHarness()
    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]}]'
    state.handlers.onServerStarted()
    local before = state.writerCalls
    state.sent = {}
    local nonAdmin = { getRole = function() return { hasCapability = function() return false end } end }
    state.handlers.onClientCommand("MinidoracatMiniMapZones", "generateTemplate", nonAdmin, { lang = "EN" })
    for _, call in ipairs(state.sent) do
        assert(call[3] ~= "generateResult", "非 admin 不應收到 generateResult")
    end
    assert(state.writerCalls == before, "非 admin 不應觸發任何檔案寫入，得到 "
        .. (state.writerCalls - before) .. " 次")
end)

check("server(gen): admin＋zones.json 有內容→備份+套用 zones.json＋廣播恰一次、backedUp=true", function()
    local state = newServerHarness()
    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]}]'  -- zones.json 已有內容
    state.handlers.onServerStarted()
    for _ = 1, 5 do state.handlers.onTick() end  -- 沖掉暖啟動廣播
    state.sent = {}
    local admin = { getRole = function() return { hasCapability = function() return true end } end }
    state.handlers.onClientCommand("MinidoracatMiniMapZones", "generateTemplate", admin, {})
    for _ = 1, 5 do state.handlers.onTick() end
    local genResult, broadcastCount = nil, 0
    for _, call in ipairs(state.sent) do
        if call[3] == "generateResult" then genResult = call[4] end
        if call[2] == "zoneData" then broadcastCount = broadcastCount + 1 end
    end
    assert(genResult and genResult.ok == true, "應回 generateResult ok=true")
    assert(genResult.path == "zones.json",
        "有內容也一律套用 zones.json，path 得到 " .. tostring(genResult.path))
    assert(genResult.backedUp == true, "有內容應先備份，backedUp 應為 true")
    assert(type(genResult.bakName) == "string" and genResult.bakName:match("^zones%.json%..+%.bak$"),
        "generateResult 應轉發時間戳 bakName，得到 " .. tostring(genResult.bakName))
    assert(broadcastCount == 1, "成功套用 zones.json 應觸發 pollNow 全體廣播恰一次，得到 " .. broadcastCount .. " 包")
end)

check("server(gen): admin＋zones.json 空→寫 zones.json＋pollNow 廣播、path=zones.json", function()
    local state = newServerHarness()
    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]}]'
    state.handlers.onServerStarted()
    for _ = 1, 5 do state.handlers.onTick() end  -- 沖掉暖啟動廣播
    state.fileContent = nil  -- 執行期 zones.json 消失 → generateTemplate 應寫 zones.json
    state.sent = {}
    local admin = { getRole = function() return { hasCapability = function() return true end } end }
    state.handlers.onClientCommand("MinidoracatMiniMapZones", "generateTemplate", admin, {})
    for _ = 1, 5 do state.handlers.onTick() end
    local genResult, broadcast = nil, false
    for _, call in ipairs(state.sent) do
        if call[3] == "generateResult" then genResult = call[4] end
        if call[2] == "zoneData" then broadcast = true end
    end
    assert(genResult and genResult.ok == true and genResult.path == "zones.json",
        "空檔應寫 zones.json，path 得到 " .. tostring(genResult and genResult.path))
    assert(genResult.backedUp == false, "空檔生成不應備份，backedUp 應為 false")
    assert(broadcast, "寫 zones.json 應觸發 pollNow 全體廣播（zoneData）")
end)

-- fix1：zones 欄位非陣列（fatal）→ 保留舊快取、不清空不廣播
check("server(fix1): zones 非陣列（fatal）→ 保留舊快取、不清空不廣播", function()
    local state = newServerHarness()
    state.fileContent = '[{"name":"Z1","rects":[[0,0,10,10]]}]'
    state.handlers.onServerStarted()
    for _ = 1, 5 do state.handlers.onTick() end  -- 沖掉暖啟動廣播
    -- 換成 zones 非陣列的壞檔（合法 JSON 但整檔壞：{"zones":"x"}）
    state.fileContent = '{"zones":"x"}'
    state.sent = {}
    local player = { getRole = function() return { hasCapability = function() return true end } end }
    state.handlers.onClientCommand("MinidoracatMiniMapZones", "reloadZones", player, {})
    for _ = 1, 5 do state.handlers.onTick() end
    local reloadResult, broadcast = nil, false
    for _, call in ipairs(state.sent) do
        if call[3] == "reloadResult" then reloadResult = call[4] end
        if call[2] == "zoneData" then broadcast = true end
    end
    assert(reloadResult and reloadResult.ok == false, "fatal 應回 ok=false")
    assert(reloadResult.count == 1, "快取應保留原本 1 筆，得到 " .. tostring(reloadResult.count))
    assert(not broadcast, "fatal 不應廣播 zoneData（不清空既有 client）")
end)

-- fix4：送包佇列整批淘汰——製造超過 MAX_SEND_QUEUE 的多批 enqueue，斷言佇列內無殘缺批次
check("server(fix4): 送包佇列整批淘汰，佇列內無殘缺批次（每組包數==tot）", function()
    local state = newServerHarness()
    -- 每 zone 64 rects 撐大 wire → 每批分成多包（校準：60 zone ≈ 6 包/批）
    local rectsJson = {}
    for r = 1, 64 do rectsJson[r] = string.format("[%d,%d,%d,%d]", r, r, r + 1, r + 1) end
    local rectsStr = "[" .. table.concat(rectsJson, ",") .. "]"
    local zones = {}
    for i = 1, 60 do zones[i] = string.format('{"name":"Z%d","rects":%s}', i, rectsStr) end
    state.fileContent = "[" .. table.concat(zones, ",") .. "]"
    state.handlers.onServerStarted()
    for _ = 1, 100 do state.handlers.onTick() end  -- 沖掉暖啟動廣播
    -- 40 個不同 player 物件各自 requestZones → 各入一批（≈6 包）；40×6=240 > MAX_SEND_QUEUE(128)
    -- → 觸發整批淘汰。不同物件參照 → 不同 target key，彼此不 purge。此段無 onTick 故無中途送包。
    for p = 1, 40 do
        state.handlers.onClientCommand("MinidoracatMiniMapZones", "requestZones", { id = p }, {})
    end
    -- 排乾佇列並捕捉（onTick ≤2 包/tick；getTimestampMs=0 故不會中途重新輪詢造成新批次）
    state.sent = {}
    for _ = 1, 400 do state.handlers.onTick() end
    -- 以 (target,bid) 分組：per-player 送包 call=(player,MODULE,"zoneData",args)
    local groups = {}
    for _, call in ipairs(state.sent) do
        if call[2] == "MinidoracatMiniMapZones" and call[3] == "zoneData" then
            local args = call[4]
            local key = tostring(call[1]) .. "#" .. tostring(args.bid)
            local g = groups[key]
            if not g then g = { count = 0, tot = args.tot }; groups[key] = g end
            g.count = g.count + 1
        end
    end
    -- 不變式：每個殘存批次都完整（count==tot）；被淘汰的批次一包不送（不在 groups）
    local surviving = 0
    for key, g in pairs(groups) do
        assert(g.count == g.tot, "批次 " .. key .. " 殘缺：" .. g.count .. "/" .. tostring(g.tot) .. " 包")
        surviving = surviving + 1
    end
    -- 淘汰確實發生（總包數遠超 128，不可能 40 批全存活），但也不會全清光
    assert(surviving < 40, "應有批次被整批淘汰，卻全部存活（" .. surviving .. " 批）")
    assert(surviving > 0, "不應把所有批次都淘汰光（" .. surviving .. " 批）")
end)

-------------------------------------------------------------------------------
-- Section C: client 版本守衛（fix2）＋ STALE 逾時重請求（fix4）
-- client 檔呼叫主 MOD API（MinidoracatMiniMapAPI.*）與 PZ 引擎 globals；每個 check 各自
-- 用 newClientHarness 取得獨立 stub。放 server 段之後，client 的全域 stub 不污染 server 測試。
-------------------------------------------------------------------------------
local clientDir = repoRoot ..
    "/MOD/MinidoracatMiniMapZonesFor42/Contents/mods/MinidoracatMiniMapZonesFor42/42/media/lua/client"

-- opts: { noProvider, noAction, apiVersion(預設1), isSP }。預設＝完整 0.8.0 API＋MP。
local function newClientHarness(opts)
    opts = opts or {}
    local state = { providerRegistered = false, actionRegistered = false,
                    handlers = {}, sent = {}, nowMs = 0 }
    local api = { zoneApiVersion = opts.apiVersion or 1 }
    if not opts.noProvider then api.registerZoneProvider = function() state.providerRegistered = true end end
    if not opts.noAction then api.registerZoneAction = function() state.actionRegistered = true end end
    _G.MinidoracatMiniMapAPI = api
    _G.Events = {
        OnServerCommand = { Add = function(fn) state.handlers.onServerCommand = fn end },
        OnTick = { Add = function(fn) state.handlers.onTick = fn end },
        EveryOneMinute = { Add = function(fn) state.handlers.everyMinute = fn end },
        OnGameStart = { Add = function(fn) state.handlers.onGameStart = fn end },
    }
    -- 引擎 globals（僅 handler 執行期用到；載入時守衛/註冊不觸及）
    state.player = { id = "P" }
    _G.getPlayer = function() return state.player end
    _G.sendClientCommand = function(...) state.sent[#state.sent + 1] = { ... } end
    _G.getTimestampMs = function() return state.nowMs end
    _G.getFileSeparator = function() return "/" end
    _G.getText = function() return "txt" end
    _G.ISChat = nil
    _G.HaloTextHelper = nil
    _G.luautils = { stringStarts = function() return false end }
    -- spFallbackActive = not isClient() and not isServer()；isSP=true → SP fallback
    _G.isClient = function() return not opts.isSP end
    _G.isServer = function() return false end
    dofile(clientDir .. "/MinidoracatMiniMapZonesClient.lua")
    return state
end

check("client(fix2): 完整 0.8.0 zone API（provider＋action＋zoneApiVersion==1）→ 註冊 provider＋action", function()
    local state = newClientHarness()
    assert(state.providerRegistered, "完整 API 應註冊 provider")
    assert(state.actionRegistered, "完整 API 應註冊 action")
    assert(state.handlers.onGameStart ~= nil, "應掛上 OnGameStart 事件")
end)

check("client(fix2): 缺 registerZoneAction → C1 守衛降級，不註冊 provider/action", function()
    local state = newClientHarness({ noAction = true })
    assert(not state.providerRegistered, "zone API 不完整應降級不註冊 provider")
    assert(not state.actionRegistered, "降級不應註冊 action")
    assert(state.handlers.onGameStart == nil, "降級應早退，不掛任何事件")
end)

check("client(fix2): zoneApiVersion≠1 → 守衛降級不註冊", function()
    local state = newClientHarness({ apiVersion = 2 })
    assert(not state.providerRegistered, "zoneApiVersion≠1 應降級")
    assert(state.handlers.onGameStart == nil, "降級應早退")
end)

check("client(fix4): MP 逾時批次丟棄後補發 requestZones，冷卻窗內不重發", function()
    local state = newClientHarness()  -- MP
    state.nowMs = 0
    state.handlers.onGameStart()  -- MP 分支送一次 requestZones（清掉不看）
    state.sent = {}
    -- 批次1：tot=2 只送 seq=1 → pendingBatches 留一筆未集滿，ts=0
    state.handlers.onServerCommand("MinidoracatMiniMapZones", "zoneData",
        { bid = 5, seq = 1, tot = 2, count = 0, zones = {} })
    state.nowMs = 100000  -- > STALE_MS(60000)
    state.handlers.everyMinute()  -- 逾時丟棄 + 補發（lastStaleRequestMs 0→100000）
    local req1 = 0
    for _, call in ipairs(state.sent) do
        if call[3] == "requestZones" then req1 = req1 + 1 end
    end
    assert(req1 == 1, "逾時丟棄後應補發一次 requestZones，得到 " .. req1)
    -- 冷卻：批次2 回溯 ts=40000，於上次補發後僅 5s（<10s 冷卻）觸發逾時 → 不應重發
    state.nowMs = 40000
    state.handlers.onServerCommand("MinidoracatMiniMapZones", "zoneData",
        { bid = 6, seq = 1, tot = 2, count = 0, zones = {} })
    state.sent = {}
    state.nowMs = 105000  -- 批次2 逾時(65s)，但距上次補發僅 5s < 冷卻 10s
    state.handlers.everyMinute()
    local req2 = 0
    for _, call in ipairs(state.sent) do
        if call[3] == "requestZones" then req2 = req2 + 1 end
    end
    assert(req2 == 0, "冷卻窗內(<10s)不應重發 requestZones，得到 " .. req2)
end)

-------------------------------------------------------------------------------
print(string.format("\n%d/%d passed", passCount, passCount + #failed))
if #failed > 0 then
    print("failed: " .. table.concat(failed, "; "))
    os.exit(1)
end
