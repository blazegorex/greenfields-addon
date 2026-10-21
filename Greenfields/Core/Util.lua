--[[ Greenfields - Core/Util.lua
     Pure-Lua helpers (strings, tables, time, colours, names). Nothing here touches a
     client C API except through GF.API, so it is safe to call from anywhere. ]]

local _, GF = ...

local U = {}
GF.Util = U

local type, pairs, ipairs, tostring, tonumber, select = type, pairs, ipairs, tostring, tonumber, select
local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local format, gsub, sub, upper, lower, find = string.format, string.gsub, string.sub, string.upper, string.lower, string.find
local concat, sort, tinsert, tremove = table.concat, table.sort, table.insert, table.remove

-------------------------------------------------------------------------------
-- Strings
-------------------------------------------------------------------------------
function U.Trim(s)
    if type(s) ~= "string" then return "" end
    return (gsub(s, "^%s*(.-)%s*$", "%1"))
end

function U.Split(s, sep, plain)
    local out = {}
    if type(s) ~= "string" or s == "" then return out end
    sep = sep or ","
    local pos = 1
    while true do
        local a, b = find(s, sep, pos, plain ~= false)
        if not a then
            out[#out + 1] = sub(s, pos)
            break
        end
        out[#out + 1] = sub(s, pos, a - 1)
        pos = b + 1
    end
    return out
end

function U.StartsWith(s, p) return type(s) == "string" and sub(s, 1, #p) == p end

function U.Truncate(s, n)
    s = tostring(s or "")
    if #s <= n then return s end
    local cut = max(1, n - 1)
    -- never split a UTF-8 character: back off continuation bytes (0x80-0xBF)
    while cut > 1 do
        local b = s:byte(cut + 1)
        if not b or b < 128 or b >= 192 then break end
        cut = cut - 1
    end
    return sub(s, 1, cut) .. "\226\128\166" -- ellipsis
end

function U.Capitalize(s)
    s = tostring(s or "")
    return upper(sub(s, 1, 1)) .. lower(sub(s, 2))
end

--- Plain (non-pattern) case-insensitive substring test, used by every search box.
function U.Matches(haystack, needle)
    if not needle or needle == "" then return true end
    if type(haystack) ~= "string" then return false end
    return find(lower(haystack), lower(needle), 1, true) ~= nil
end

--- Strips |c colour codes, |T textures and |H hyperlinks down to readable text.
function U.StripCodes(s)
    s = tostring(s or "")
    s = gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    s = gsub(s, "|cn[%w_]+:", "")   -- named colours (item links on Midnight-era clients)
    s = gsub(s, "|r", "")
    s = gsub(s, "|T.-|t", "")
    s = gsub(s, "|H.-|h(.-)|h", "%1")
    return s
end

--- Escapes a string so it is safe to put inside SendChatMessage (no stray pipes).
function U.ChatSafe(s)
    return (gsub(tostring(s or ""), "|", "||"))
end

-------------------------------------------------------------------------------
-- Numbers
-------------------------------------------------------------------------------
function U.Round(n, places)
    local m = 10 ^ (places or 0)
    return floor(n * m + 0.5) / m
end

function U.Clamp(n, lo, hi) return min(hi, max(lo, n)) end

function U.Commas(n)
    n = floor(tonumber(n) or 0)
    local s = tostring(abs(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if sub(out, 1, 1) == "," then out = sub(out, 2) end
    return (n < 0 and "-" or "") .. out
end

--- Short human number: 950, 1.2k, 34k, 1.5m
function U.Short(n)
    n = tonumber(n) or 0
    local a = abs(n)
    if a >= 1e6 then return format("%.1fm", n / 1e6) end
    if a >= 1e4 then return format("%dk", floor(n / 1e3)) end
    if a >= 1e3 then return format("%.1fk", n / 1e3) end
    return tostring(floor(n))
end

function U.Pct(part, whole)
    if not whole or whole <= 0 then return 0 end
    return floor((part or 0) * 100 / whole + 0.5)
end

-------------------------------------------------------------------------------
-- Tables
-------------------------------------------------------------------------------
function U.Copy(t, seen)
    if type(t) ~= "table" then return t end
    seen = seen or {}
    if seen[t] then return seen[t] end
    local c = {}
    seen[t] = c
    for k, v in pairs(t) do c[U.Copy(k, seen)] = U.Copy(v, seen) end
    return c
end

--- Fills missing keys of dst from src (recursively); never overwrites existing values.
function U.Defaults(dst, src)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = U.Copy(v)
        elseif type(v) == "table" and type(dst[k]) == "table" then
            U.Defaults(dst[k], v)
        end
    end
    return dst
end

function U.Count(t)
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

function U.Keys(t, cmp)
    local out = {}
    if type(t) == "table" then for k in pairs(t) do out[#out + 1] = k end end
    sort(out, cmp)
    return out
end

function U.Values(t)
    local out = {}
    if type(t) == "table" then for _, v in pairs(t) do out[#out + 1] = v end end
    return out
end

function U.Contains(list, value)
    if type(list) ~= "table" then return false end
    for i = 1, #list do if list[i] == value then return true end end
    return false
end

function U.Filter(list, fn)
    local out = {}
    for i = 1, #list do if fn(list[i], i) then out[#out + 1] = list[i] end end
    return out
end

function U.Map(list, fn)
    local out = {}
    for i = 1, #list do out[i] = fn(list[i], i) end
    return out
end

function U.Wipe(t)
    if type(t) ~= "table" then return {} end
    for k in pairs(t) do t[k] = nil end
    return t
end

--- Removes oldest entries so a list keeps at most n items (list is oldest-first).
function U.CapList(list, n)
    while #list > n do tremove(list, 1) end
    return list
end

--- Stable sort helper: sort by key fn descending then name ascending.
function U.SortBy(list, keyFn, desc)
    sort(list, function(a, b)
        local ka, kb = keyFn(a), keyFn(b)
        if ka == kb then
            return tostring(a.name or a.key or "") < tostring(b.name or b.key or "")
        end
        if desc then return ka > kb end
        return ka < kb
    end)
    return list
end

--- Picks a random element; `seed` (optional number) makes it deterministic.
function U.Pick(list, seed)
    if type(list) ~= "table" or #list == 0 then return nil end
    if seed then return list[(floor(seed) % #list) + 1] end
    return list[math.random(1, #list)]
end

-------------------------------------------------------------------------------
-- Time
-------------------------------------------------------------------------------
function U.Now()
    return GF.API and GF.API.ServerTime() or time()
end

function U.Ago(ts)
    if not ts or ts <= 0 then return "never" end
    local d = U.Now() - ts
    if d < 0 then d = 0 end
    if d < 60 then return "just now" end
    if d < 3600 then return floor(d / 60) .. "m ago" end
    if d < 86400 then return floor(d / 3600) .. "h ago" end
    if d < 86400 * 14 then return floor(d / 86400) .. "d ago" end
    return floor(d / (86400 * 7)) .. "w ago"
end

function U.Duration(sec)
    sec = max(0, floor(sec or 0))
    if sec < 60 then return sec .. "s" end
    if sec < 3600 then return format("%dm %02ds", floor(sec / 60), sec % 60) end
    if sec < 86400 then return format("%dh %02dm", floor(sec / 3600), floor(sec / 60) % 60) end
    return format("%dd %dh", floor(sec / 86400), floor(sec / 3600) % 24)
end

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- "Wed 13 Nov, 7:30pm" in the player's local time.
function U.DateTime(ts, withYear)
    if not ts then return "?" end
    local t = date("*t", ts)
    if type(t) ~= "table" then return "?" end
    local h = t.hour % 12
    if h == 0 then h = 12 end
    local s = format("%s %d %s, %d:%02d%s", DAYS[t.wday] or "?", t.day, MONTHS[t.month] or "?", h, t.min, t.hour < 12 and "am" or "pm")
    if withYear then s = s .. " " .. t.year end
    return s
end

function U.DateShort(ts)
    if not ts then return "?" end
    local t = date("*t", ts)
    if type(t) ~= "table" then return "?" end
    return format("%d %s", t.day, MONTHS[t.month] or "?")
end

--- Week key used for weekly leaderboards: the Wednesday (Oceanic/EU reset day) on or
-- before ts, as YYYYMMDD. Weekly stats bucket on this.
function U.WeekKey(ts)
    ts = ts or U.Now()
    local t = date("*t", ts)
    if type(t) ~= "table" then return 0 end
    local back = (t.wday - 4) % 7 -- days since Wednesday
    local w = date("*t", ts - back * 86400)
    return w.year * 10000 + w.month * 100 + w.day
end

-------------------------------------------------------------------------------
-- Colours & text
-------------------------------------------------------------------------------
function U.Hex(r, g, b)
    if type(r) == "table" then r, g, b = r[1] or r.r, r[2] or r.g, r[3] or r.b end
    return format("%02x%02x%02x", floor((r or 1) * 255 + 0.5), floor((g or 1) * 255 + 0.5), floor((b or 1) * 255 + 0.5))
end

function U.Color(text, r, g, b)
    if type(r) == "string" then return "|cff" .. r .. tostring(text) .. "|r" end
    return "|cff" .. U.Hex(r, g, b) .. tostring(text) .. "|r"
end

function U.ClassColorHex(classFile)
    local c = GF.API and GF.API.ClassColor(classFile)
    if c then return U.Hex(c.r, c.g, c.b) end
    return "c8d2cc"
end

--- Name wrapped in its class colour; realm suffix trimmed for same-realm players.
function U.ClassName(name, classFile)
    return "|cff" .. U.ClassColorHex(classFile) .. U.ShortName(name) .. "|r"
end

function U.Plural(n, one, many)
    return n == 1 and (one) or (many or (one .. "s"))
end

-------------------------------------------------------------------------------
-- Player names. Internally every player is keyed as "Name-Realm" (realm without
-- spaces), exactly the shape CHAT_MSG_ADDON delivers for cross-realm senders.
-------------------------------------------------------------------------------
local myRealm

function U.MyRealm()
    if not myRealm or myRealm == "" then
        myRealm = GF.API and GF.API.NormalizedRealm() or ""
    end
    return myRealm
end

function U.FullName(name)
    if type(name) ~= "string" or name == "" then return nil end
    if find(name, "-", 1, true) then return name end
    local realm = U.MyRealm()
    if realm == "" then return name end
    return name .. "-" .. realm
end

function U.ShortName(name)
    if type(name) ~= "string" then return "?" end
    local n, realm = name:match("^([^%-]+)%-(.+)$")
    if not n then return name end
    if realm == U.MyRealm() then return n end
    return n .. "*"
end

function U.SameName(a, b)
    if not a or not b then return false end
    return U.FullName(a) == U.FullName(b)
end
