--[[ Greenfields - Core/Serialize.lua
     A tiny, deterministic serializer for addon-channel payloads.

     Wire format (all printable ASCII, never contains \0, \n or the chunk marker "\031"):
       ^N<number>;   number          ^S<len>:<bytes>  string (length-prefixed, no escaping)
       ^T            true            ^F               false
       ^Z            nil (array holes)
       ^{ ... ^}     table: sequence of key,value pairs
     Strings are length-prefixed, so any byte except \0 round-trips untouched. ]]

local _, GF = ...

local Ser = {}
GF.Serialize = Ser

local type, tostring, tonumber, pairs, sort = type, tostring, tonumber, pairs, table.sort
local concat, sub, find, byte = table.concat, string.sub, string.find, string.byte
local floor, huge = math.floor, math.huge

local function numstr(n)
    if n ~= n then return "0" end
    if n == huge then return "1e999" end
    if n == -huge then return "-1e999" end
    if n == floor(n) and n > -1e15 and n < 1e15 then return tostring(floor(n)) end
    return string.format("%.17g", n)
end

local function keyOrder(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end

local function write(out, v, depth)
    local t = type(v)
    if t == "number" then
        out[#out + 1] = "^N" .. numstr(v) .. ";"
    elseif t == "string" then
        out[#out + 1] = "^S" .. #v .. ":" .. v
    elseif t == "boolean" then
        out[#out + 1] = v and "^T" or "^F"
    elseif t == "table" then
        if depth > 24 then error("Serialize: table nested too deep") end
        out[#out + 1] = "^{"
        -- array part first (in order), then the rest sorted so output is deterministic
        local n = #v
        for i = 1, n do
            out[#out + 1] = "^N" .. i .. ";"
            local item = v[i]
            if item == nil then out[#out + 1] = "^Z" else write(out, item, depth + 1) end
        end
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == floor(k)) then
                local kt = type(k)
                if kt == "string" or kt == "number" or kt == "boolean" then keys[#keys + 1] = k end
            end
        end
        sort(keys, keyOrder)
        for i = 1, #keys do
            local k = keys[i]
            local item = v[k]
            local it = type(item)
            if it ~= "function" and it ~= "userdata" and it ~= "thread" then
                write(out, k, depth + 1)
                write(out, item, depth + 1)
            end
        end
        out[#out + 1] = "^}"
    else
        out[#out + 1] = "^Z"
    end
end

--- Serialize(value) -> string
function Ser.Encode(v)
    local out = {}
    write(out, v, 0)
    return concat(out)
end

local read

-- returns value, nextPos  (errors on malformed input; callers pcall)
read = function(s, pos, depth)
    if sub(s, pos, pos) ~= "^" then error("Serialize: bad token at " .. pos) end
    local tag = sub(s, pos + 1, pos + 1)
    pos = pos + 2
    if tag == "N" then
        local e = find(s, ";", pos, true)
        if not e then error("Serialize: unterminated number") end
        local n = tonumber(sub(s, pos, e - 1))
        if not n then error("Serialize: bad number") end
        return n, e + 1
    elseif tag == "S" then
        local c = find(s, ":", pos, true)
        if not c then error("Serialize: bad string header") end
        local len = tonumber(sub(s, pos, c - 1))
        if not len or len < 0 then error("Serialize: bad string length") end
        local str = sub(s, c + 1, c + len)
        if #str ~= len then error("Serialize: truncated string") end
        return str, c + len + 1
    elseif tag == "T" then
        return true, pos
    elseif tag == "F" then
        return false, pos
    elseif tag == "Z" then
        return nil, pos
    elseif tag == "{" then
        if depth > 24 then error("Serialize: nested too deep") end
        local t = {}
        while true do
            if sub(s, pos, pos + 1) == "^}" then return t, pos + 2 end
            if pos > #s then error("Serialize: unterminated table") end
            local k
            k, pos = read(s, pos, depth + 1)
            local v
            v, pos = read(s, pos, depth + 1)
            if k ~= nil then t[k] = v end
        end
    end
    error("Serialize: unknown tag " .. tostring(tag))
end

--- Decode(string) -> ok, value | false, err
function Ser.Decode(s)
    if type(s) ~= "string" or s == "" then return false, "empty" end
    local ok, v, pos = pcall(read, s, 1, 0)
    if not ok then return false, v end
    if pos ~= #s + 1 then return false, "trailing data" end
    return true, v
end

-------------------------------------------------------------------------------
-- Base64 (pure Lua fallback for when C_EncodingUtil is unavailable)
-------------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64enc, b64dec = {}, {}
for i = 1, 64 do
    local c = sub(B64, i, i)
    b64enc[i - 1] = c
    b64dec[byte(c)] = i - 1
end

function Ser.ToBase64(s)
    local out, n = {}, #s
    for i = 1, n, 3 do
        local a, b, c = byte(s, i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = floor(v / 262144) % 64
        local c2 = floor(v / 4096) % 64
        local c3 = floor(v / 64) % 64
        local c4 = v % 64
        out[#out + 1] = b64enc[c1] .. b64enc[c2] .. (b and b64enc[c3] or "=") .. (c and b64enc[c4] or "=")
    end
    return concat(out)
end

function Ser.FromBase64(s)
    s = s:gsub("[^%w%+/=]", "")
    local out = {}
    for i = 1, #s, 4 do
        local a, b, c, d = byte(s, i, i + 3)
        local va, vb = b64dec[a], b64dec[b]
        if va == nil or vb == nil then break end
        local vc = c and b64dec[c]
        local vd = d and b64dec[d]
        local v = va * 262144 + vb * 4096 + (vc or 0) * 64 + (vd or 0)
        out[#out + 1] = string.char(floor(v / 65536) % 256)
        if vc then out[#out + 1] = string.char(floor(v / 256) % 256) end
        if vd then out[#out + 1] = string.char(v % 256) end
    end
    return concat(out)
end

-------------------------------------------------------------------------------
-- Small string hash for change digests: two independent 32-bit djb2-style
-- accumulators (kept well under 2^53 so doubles stay exact) -> 16 hex chars.
-------------------------------------------------------------------------------
function Ser.Hash(s)
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local x = byte(s, i)
        h1 = (h1 * 33 + x) % 4294967296
        h2 = (h2 * 31 + x * 7 + 1) % 4294967291
    end
    return string.format("%08x%08x", h1, h2)
end
