--
-- MinidoracatZonesJson.lua
--
-- Vendored from rxi/json.lua — decode-only subset.
-- Source: https://github.com/rxi/json.lua
-- Raw:    https://raw.githubusercontent.com/rxi/json.lua/master/json.lua
--
-- Copyright (c) 2020 rxi
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of
-- this software and associated documentation files (the "Software"), to deal in
-- the Software without restriction, including without limitation the rights to
-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--
-- 本檔為 Minidoracat MiniMap Zones 客製裁切版：只保留 decode。伺服器讀 zones.txt
-- 只需要解析、不需要序列化輸出，且 Kahlua 沒有曝露全域 next（原版 encode_table
-- 用得到），砍掉 encode 半邊順便避開這個相容缺口（研究報告
-- .omc/research/zones-mod-tech-research.md §3：decode 路徑逐函式對照 Kahlua stdlib，
-- 零修改可用）。
-- 移除範圍：encode_nil/encode_table/encode_string/encode_number、escape_char
-- （encode_string 專用的轉義函式）、type_func_map、encode 分派函式、json.encode。
-- escape_char_map／escape_char_map_inv 兩張表保留——decode 的 parse_string 轉義
-- 還原（\n \t 等）要用 escape_char_map_inv，但它的建表迴圈讀 escape_char_map，
-- 兩者都不能刪。
-- PZ mod lua 沒有 require 模組系統，改走全域曝露：MinidoracatZonesJson.decode。

MinidoracatZonesJson = MinidoracatZonesJson or {}

-- JSON null 的 array sentinel：陣列元素為 null 時填入此值，讓 # 取得真實長度、
-- 不被 nil 洞截斷後續合法元素（B2）。物件欄位的 null 仍維持「欄位不存在」語意
-- （只 array 用 sentinel）。validateZones 會把 sentinel 條目當非法（帶 name 缺失）跳過。
MinidoracatZonesJson.null = MinidoracatZonesJson.null or {}

-- JSON 巢狀深度上限：parse_array/parse_object 互遞迴，深度爆炸會丟 StackOverflowError，
-- Kahlua pcall 攔不到 Error（只攔 LuaError）→ 可逃逸 decode 的 pcall（B7）。
local MAX_JSON_DEPTH = 64

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local parse

local function create_set(...)
  local res = {}
  for i = 1, select("#", ...) do
    res[ select(i, ...) ] = true
  end
  return res
end

local space_chars   = create_set(" ", "\t", "\r", "\n")
local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
local literals      = create_set("true", "false", "null")

local literal_map = {
  [ "true"  ] = true,
  [ "false" ] = false,
  [ "null"  ] = nil,
}

local escape_char_map = {
  [ "\\" ] = "\\",
  [ "\"" ] = "\"",
  [ "\b" ] = "b",
  [ "\f" ] = "f",
  [ "\n" ] = "n",
  [ "\r" ] = "r",
  [ "\t" ] = "t",
}

local escape_char_map_inv = { [ "/" ] = "/" }
for k, v in pairs(escape_char_map) do
  escape_char_map_inv[v] = k
end


local function next_char(str, idx, set, negate)
  for i = idx, #str do
    if set[str:sub(i, i)] ~= negate then
      return i
    end
  end
  return #str + 1
end


local function decode_error(str, idx, msg)
  local line_count = 1
  local col_count = 1
  for i = 1, idx - 1 do
    col_count = col_count + 1
    if str:sub(i, i) == "\n" then
      line_count = line_count + 1
      col_count = 1
    end
  end
  error( string.format("%s at line %d col %d", msg, line_count, col_count) )
end


-- Kahlua string.char(num) 以 (char)num 存「一個 UTF-16 code unit」（StringLib.java:756），
-- 不是產 UTF-8 bytes。原 rxi codepoint_to_utf8 產多個 UTF-8 byte 再逐一 string.char，
-- 在 Kahlua 每 byte 變獨立 Latin-1 char → 中文亂碼（B5）。故 \u 逃逸改為：
--   BMP（<=0xFFFF）直接存 codepoint；surrogate pair 各存一個 code unit（即字串內部 UTF-16 表示）。
--   lone / 不合法 surrogate → decode_error（壞資料不落地）。
local function parse_unicode_escape(str, pos, s)
  local n1 = tonumber( s:sub(1, 4),  16 )
  local n2 = tonumber( s:sub(7, 10), 16 )
  if n2 then -- surrogate pair（regex 已保證 n1 為 high surrogate，仍驗 n2 為 low surrogate）
    if not (n1 >= 0xd800 and n1 <= 0xdbff and n2 >= 0xdc00 and n2 <= 0xdfff) then
      decode_error(str, pos, "invalid surrogate pair in unicode escape")
    end
    return string.char(n1, n2)
  end
  if n1 >= 0xd800 and n1 <= 0xdfff then
    decode_error(str, pos, "invalid lone surrogate in unicode escape")
  end
  return string.char(n1)
end


local function parse_string(str, i)
  local res = ""
  local j = i + 1
  local k = j

  while j <= #str do
    local x = str:byte(j)

    if x < 32 then
      decode_error(str, j, "control character in string")

    elseif x == 92 then -- `\`: Escape
      res = res .. str:sub(k, j - 1)
      j = j + 1
      local c = str:sub(j, j)
      if c == "u" then
        local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
                 or str:match("^%x%x%x%x", j + 1)
                 or decode_error(str, j - 1, "invalid unicode escape in string")
        res = res .. parse_unicode_escape(str, j - 1, hex)
        j = j + #hex
      else
        if not escape_chars[c] then
          decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
        end
        res = res .. escape_char_map_inv[c]
      end
      k = j + 1

    elseif x == 34 then -- `"`: End of string
      res = res .. str:sub(k, j - 1)
      return res, j + 1
    end

    j = j + 1
  end

  decode_error(str, i, "expected closing quote for string")
end


local function parse_number(str, i)
  local x = next_char(str, i, delim_chars)
  local s = str:sub(i, x - 1)
  local n = tonumber(s)
  if not n then
    decode_error(str, i, "invalid number '" .. s .. "'")
  end
  return n, x
end


local function parse_literal(str, i)
  local x = next_char(str, i, delim_chars)
  local word = str:sub(i, x - 1)
  if not literals[word] then
    decode_error(str, i, "invalid literal '" .. word .. "'")
  end
  return literal_map[word], x
end


local function parse_array(str, i, depth)
  depth = (depth or 0) + 1
  if depth > MAX_JSON_DEPTH then
    decode_error(str, i, "exceeds max nesting depth " .. MAX_JSON_DEPTH)
  end
  local res = {}
  local n = 1
  i = i + 1
  while 1 do
    local x
    i = next_char(str, i, space_chars, true)
    -- Empty / end of array?
    if str:sub(i, i) == "]" then
      i = i + 1
      break
    end
    -- Read token
    x, i = parse(str, i, depth)
    -- JSON null（parse 回 nil）→ 填 sentinel，保住 array 長度不被 nil 洞截斷（B2）
    if x == nil then x = MinidoracatZonesJson.null end
    res[n] = x
    n = n + 1
    -- Next token
    i = next_char(str, i, space_chars, true)
    local chr = str:sub(i, i)
    i = i + 1
    if chr == "]" then break end
    if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
  end
  return res, i
end


local function parse_object(str, i, depth)
  depth = (depth or 0) + 1
  if depth > MAX_JSON_DEPTH then
    decode_error(str, i, "exceeds max nesting depth " .. MAX_JSON_DEPTH)
  end
  local res = {}
  i = i + 1
  while 1 do
    local key, val
    i = next_char(str, i, space_chars, true)
    -- Empty / end of object?
    if str:sub(i, i) == "}" then
      i = i + 1
      break
    end
    -- Read key
    if str:sub(i, i) ~= '"' then
      decode_error(str, i, "expected string for key")
    end
    key, i = parse(str, i, depth)
    -- Read ':' delimiter
    i = next_char(str, i, space_chars, true)
    if str:sub(i, i) ~= ":" then
      decode_error(str, i, "expected ':' after key")
    end
    i = next_char(str, i + 1, space_chars, true)
    -- Read value
    val, i = parse(str, i, depth)
    -- Set
    res[key] = val
    -- Next token
    i = next_char(str, i, space_chars, true)
    local chr = str:sub(i, i)
    i = i + 1
    if chr == "}" then break end
    if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
  end
  return res, i
end


local char_func_map = {
  [ '"' ] = parse_string,
  [ "0" ] = parse_number,
  [ "1" ] = parse_number,
  [ "2" ] = parse_number,
  [ "3" ] = parse_number,
  [ "4" ] = parse_number,
  [ "5" ] = parse_number,
  [ "6" ] = parse_number,
  [ "7" ] = parse_number,
  [ "8" ] = parse_number,
  [ "9" ] = parse_number,
  [ "-" ] = parse_number,
  [ "t" ] = parse_literal,
  [ "f" ] = parse_literal,
  [ "n" ] = parse_literal,
  [ "[" ] = parse_array,
  [ "{" ] = parse_object,
}


parse = function(str, idx, depth)
  local chr = str:sub(idx, idx)
  local f = char_func_map[chr]
  if f then
    -- parse_string/number/literal 忽略多帶的 depth；parse_array/object 用它擋巢狀爆炸（B7）
    return f(str, idx, depth)
  end
  decode_error(str, idx, "unexpected character '" .. chr .. "'")
end


function MinidoracatZonesJson.decode(str)
  if type(str) ~= "string" then
    error("expected argument of type string, got " .. type(str))
  end
  local res, idx = parse(str, next_char(str, 1, space_chars, true))
  idx = next_char(str, idx, space_chars, true)
  if idx <= #str then
    decode_error(str, idx, "trailing garbage")
  end
  return res
end
