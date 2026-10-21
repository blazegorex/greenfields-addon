--[[ tools/harness/wow_mock.lua  --  core of the WoW: Forever (1.60.1 / TOC 16001) client mock.

     Loaded first into a fresh lupa LuaRuntime (real Lua 5.1) as a chunk called with
     (MOCK, CFG). Later parts receive the same MOCK table, in this order: wow_mock_data.lua,
     wow_mock_widgets.lua, wow_mock_anim.lua, wow_mock_api.lua, wow_mock_game.lua,
     wow_mock_scene.lua; then run.py calls MOCK.Setup() (wow_mock_game.lua) which installs
     the globals. Nothing here is a global: run.py keeps the MOCK reference, the addon only
     sees the WoW-shaped globals.

     This file provides:
       * private references to the stock Lua libs (debug, os.date, ...) before they are
         removed from _G (WoW has no io/os/debug/package/require/dofile/loadfile)
       * the deterministic per-client PRNG behind math.random / random / fastrandom
       * the virtual clock: GetTime, GetServerTime, time, date (fixed AWST, UTC+8)
       * secret values (newproxy userdata) + the taint log of secret misuse
       * error recording (WoW's error frame): every script/event/timer runs protected
       * C_Timer driven by the virtual clock
       * the event registry (valid-event whitelist, restricted events) and dispatch
       * strict globals: logs undefined global reads and new-global writes by addon code
]]

local MOCK, CFG = ...

-------------------------------------------------------------------------------
-- Private references (taken before anything is wrapped or removed)
-------------------------------------------------------------------------------
local R = {
    type = type, tostring = tostring, tonumber = tonumber, pairs = pairs, ipairs = ipairs,
    next = next, select = select, error = error, pcall = pcall, xpcall = xpcall,
    rawget = rawget, rawset = rawset, rawequal = rawequal, setmetatable = setmetatable,
    getmetatable = getmetatable, unpack = unpack, loadstring = loadstring, setfenv = setfenv,
    newproxy = newproxy, debug = debug, os_date = os.date, os_time = os.time, os_clock = os.clock,
    floor = math.floor, ceil = math.ceil, abs = math.abs, max = math.max, min = math.min,
    sqrt = math.sqrt, fmod = math.fmod,
    format = string.format, sub = string.sub, gsub = string.gsub, find = string.find,
    match = string.match, gmatch = string.gmatch, byte = string.byte, char = string.char,
    len = string.len, lower = string.lower, upper = string.upper, rep = string.rep,
    reverse = string.reverse,
    concat = table.concat, insert = table.insert, remove = table.remove, sort = table.sort,
    collectgarbage = collectgarbage,
}
MOCK.R = R
MOCK.CFG = CFG or {}

local type, pairs, ipairs, tostring, select, error = R.type, R.pairs, R.ipairs, R.tostring, R.select, R.error
local floor, format, sub, find = R.floor, R.format, R.sub, R.find
local tinsert, tremove, concat = R.insert, R.remove, R.concat
local debug = R.debug

MOCK.clientName = MOCK.CFG.name or "Player"

-------------------------------------------------------------------------------
-- Source classification helpers
-------------------------------------------------------------------------------
local ADDON_PREFIX = "@Greenfields/"
local MOCK_PREFIX = "@mock/"

local function isAddonSource(src) return type(src) == "string" and sub(src, 1, #ADDON_PREFIX) == ADDON_PREFIX end
local function isMockSource(src) return type(src) == "string" and sub(src, 1, #MOCK_PREFIX) == MOCK_PREFIX end
MOCK.isAddonSource = isAddonSource
MOCK.isMockSource = isMockSource

--- First stack frame (from `level` up) that lives in addon code -> "Greenfields/x.lua:12"
local function addonLocation(level)
    level = (level or 2) + 1
    for _ = 1, 40 do
        local info = debug.getinfo(level, "Sl")
        if not info then break end
        if isAddonSource(info.source) then
            return sub(info.source, 2) .. ":" .. tostring(info.currentline or 0)
        end
        level = level + 1
    end
    return nil
end
MOCK.addonLocation = addonLocation

--- Up to two addon frames: "Greenfields/UI/Widgets.lua:65 <- Greenfields/Modules/Home.lua:595"
-- (objects made through the widget kit are attributed to the module that asked for them)
local function addonWhere(level)
    level = (level or 2) + 1
    local first, firstFile
    for _ = 1, 40 do
        local info = debug.getinfo(level, "Sl")
        if not info then break end
        if isAddonSource(info.source) then
            local loc = sub(info.source, 2) .. ":" .. tostring(info.currentline or 0)
            if not first then
                first, firstFile = loc, info.source
            elseif info.source ~= firstFile and info.source ~= "@Greenfields/Core/Init.lua" then
                -- Core/Init.lua is plumbing (GF:Safe / timers / message dispatch): look past it
                return first .. " <- " .. loc
            end
        end
        level = level + 1
    end
    return first
end
MOCK.addonWhere = addonWhere

--- traceback lines, filtering lupa/[C] noise, rewritten like WoW's debugstack
local function traceback(level, maxLines)
    local tb = debug.traceback("", (level or 1) + 1)
    local out = {}
    for line in R.gmatch(tb, "[^\n]+") do
        if not find(line, "stack traceback:", 1, true) then
            line = R.gsub(line, "^%s+", "")
            out[#out + 1] = line
            if maxLines and #out >= maxLines then break end
        end
    end
    return concat(out, "\n")
end
MOCK.traceback = traceback

-------------------------------------------------------------------------------
-- Errors (the "error frame")
-------------------------------------------------------------------------------
MOCK.errors = {}          -- { kind, label, msg, trace, t, origin = "addon"|"mock"|"unknown" }
MOCK.warnings = {}        -- { kind, msg, where }
local errorKeys = {}

local function classifyOrigin(msg)
    msg = tostring(msg)
    if find(msg, "Greenfields/", 1, true) == 1 then return "addon" end
    if find(msg, "mock/", 1, true) == 1 then return "mock" end
    return "unknown"
end

function MOCK.RecordError(kind, label, msg, trace)
    msg = tostring(msg)
    local origin = classifyOrigin(msg)
    if origin == "unknown" and trace then
        -- message without position (error(x, 0) or a table): blame the first frame we know
        for line in R.gmatch(trace, "[^\n]+") do
            if find(line, "Greenfields/", 1, true) then origin = "addon" break end
            if find(line, "mock/", 1, true) then origin = "mock" break end
        end
    end
    local key = kind .. "|" .. tostring(label) .. "|" .. msg
    local e = errorKeys[key]
    if e then
        e.count = e.count + 1
        return e
    end
    e = { kind = kind, label = tostring(label or ""), msg = msg, trace = trace or "", t = MOCK.uptime or 0,
          origin = origin, count = 1, client = MOCK.clientName, scenario = MOCK.scenario }
    errorKeys[key] = e
    MOCK.errors[#MOCK.errors + 1] = e
    return e
end

function MOCK.Warn(kind, msg, level)
    local where = MOCK.addonWhere and MOCK.addonWhere((level or 2) + 1) or addonLocation((level or 2) + 1)
    local key = kind .. "|" .. tostring(msg) .. "|" .. tostring(where)
    if errorKeys[key] then errorKeys[key].count = errorKeys[key].count + 1 return end
    local w = { kind = kind, msg = tostring(msg), where = where or "?", count = 1, scenario = MOCK.scenario }
    errorKeys[key] = w
    MOCK.warnings[#MOCK.warnings + 1] = w
end

local userErrorHandler -- seterrorhandler()

function MOCK.SetUserErrorHandler(fn) userErrorHandler = fn end
function MOCK.GetUserErrorHandler() return userErrorHandler end

local function packn(...) return { n = select("#", ...), ... } end
MOCK.packn = packn

--- Protect(kind, label, fn, ...) -> ok, results...   (errors recorded, never raised)
function MOCK.Protect(kind, label, fn, ...)
    local args = packn(...)
    local trace
    local res = packn(R.xpcall(function() return fn(R.unpack(args, 1, args.n)) end, function(err)
        trace = traceback(2, 14)
        if userErrorHandler then R.pcall(userErrorHandler, err) end
        return err
    end))
    if res[1] then return R.unpack(res, 1, res.n) end
    MOCK.RecordError(kind, label, res[2], trace)
    return false
end
local Protect = MOCK.Protect

-------------------------------------------------------------------------------
-- Deterministic PRNG (Park-Miller minimal standard; exact in doubles)
-------------------------------------------------------------------------------
local rngState = 1
local function seedRng(s)
    s = floor(tonumber(s) or 1) % 2147483646
    if s <= 0 then s = s + 2147483646 end
    rngState = s
end
seedRng(MOCK.CFG.seed or 12345)
MOCK.SeedRandom = seedRng

local function nextUnit()
    rngState = (rngState * 16807) % 2147483647
    return (rngState - 1) / 2147483646
end
MOCK.RandomUnit = nextUnit

local function random(m, n)
    local r = nextUnit()
    if m == nil then return r end
    if type(m) ~= "number" then error("bad argument #1 to 'random' (number expected, got " .. type(m) .. ")", 2) end
    if n == nil then m, n = 1, m end
    if type(n) ~= "number" then error("bad argument #2 to 'random' (number expected, got " .. type(n) .. ")", 2) end
    m, n = floor(m), floor(n)
    if m > n then error("bad argument #" .. (n == nil and 1 or 2) .. " to 'random' (interval is empty)", 2) end
    return m + floor(r * (n - m + 1))
end
math.random = random
math.randomseed = function(s) seedRng(s) end
MOCK.random = random

-------------------------------------------------------------------------------
-- Virtual clock (set by run.py every tick)
-------------------------------------------------------------------------------
local TZ = (MOCK.CFG.tzOffset or 8) * 3600   -- AWST: Mandurah, WA
MOCK.TZ = TZ
MOCK.epoch = MOCK.CFG.epoch or 1796727600
MOCK.uptime = MOCK.CFG.uptime or 1000
MOCK.tickNo = 0

function MOCK.SetClock(epoch, uptime)
    MOCK.epoch = epoch
    MOCK.uptime = uptime
end

local function daysFromCivil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function timeFromTable(t)
    for _, k in ipairs({ "day", "month", "year" }) do
        if t[k] == nil then error("field '" .. k .. "' missing in date table", 3) end
    end
    local y, mo = floor(t.year), floor(t.month)
    y = y + floor((mo - 1) / 12)
    mo = (mo - 1) % 12 + 1
    local days = daysFromCivil(y, mo, 1) + floor(t.day) - 1
    local secs = days * 86400 + floor(t.hour or 12) * 3600 + floor(t.min or 0) * 60 + floor(t.sec or 0)
    return secs - TZ
end

function MOCK.Now() return floor(MOCK.epoch) end

local function wowTime(t)
    if t == nil then return floor(MOCK.epoch) end
    if type(t) ~= "table" then error("bad argument #1 to 'time' (table expected, got " .. type(t) .. ")", 2) end
    return timeFromTable(t)
end

local function wowDate(fmt, t)
    fmt = fmt or "%c"
    if type(fmt) ~= "string" then error("bad argument #1 to 'date' (string expected, got " .. type(fmt) .. ")", 2) end
    if t == nil then t = floor(MOCK.epoch) end
    if type(t) ~= "number" then error("bad argument #2 to 'date' (number expected, got " .. type(t) .. ")", 2) end
    if sub(fmt, 1, 1) == "!" then return R.os_date(fmt, t) end
    local r = R.os_date("!" .. fmt, t + TZ)
    if type(r) == "table" then r.isdst = false end
    return r
end

MOCK.time = wowTime
MOCK.date = wowDate

-------------------------------------------------------------------------------
-- Secret values
-------------------------------------------------------------------------------
local secretProto = R.newproxy(true)
local secretMT = R.getmetatable(secretProto)
local secretVal = R.setmetatable({}, { __mode = "k" })
MOCK.secretOn = {}          -- category -> bool (set by run.py)
MOCK.taint = {}             -- aggregated misuse log
local taintKeys = {}

local function logTaint(op, level, severity)
    local where = addonWhere((level or 2) + 1) or "?"
    local key = op .. "|" .. where
    local e = taintKeys[key]
    if e then e.count = e.count + 1 return e end
    e = { op = op, where = where, count = 1, severity = severity or "error",
          trace = traceback((level or 2) + 1, 8), scenario = MOCK.scenario }
    taintKeys[key] = e
    MOCK.taint[#MOCK.taint + 1] = e
    return e
end
MOCK.LogTaint = logTaint

local function secretError(what)
    logTaint(what, 3, "error")
    error("attempt to " .. what .. " a secret value", 3)
end
secretMT.__index = function() secretError("index") end
secretMT.__newindex = function() secretError("index") end
secretMT.__call = function() secretError("call") end
secretMT.__concat = function() secretError("concatenate") end
secretMT.__len = function() secretError("get length of") end
secretMT.__eq = function() secretError("compare") end
secretMT.__lt = function() secretError("compare") end
secretMT.__le = function() secretError("compare") end
secretMT.__unm = function() secretError("perform arithmetic on") end
for _, mm in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__pow" }) do
    secretMT[mm] = function() secretError("perform arithmetic on") end
end
secretMT.__tostring = function() return "<secret>" end
secretMT.__metatable = "secret"

local function isSecret(v)
    return R.type(v) == "userdata" and secretVal[v] ~= nil
end
MOCK.IsSecret = isSecret

function MOCK.Secret(v)
    if v == nil then return nil end
    local p = R.newproxy(secretProto)
    secretVal[p] = { v }
    return p
end

function MOCK.Unwrap(v)
    if isSecret(v) then return secretVal[v][1] end
    return v
end

--- Secret(v) if category `cat` is on, else v
function MOCK.MaybeSecret(cat, v)
    if MOCK.secretOn[cat] and v ~= nil then return MOCK.Secret(v) end
    return v
end

-- type(secret) reports the underlying value's type (stricter: `type(x) == "string"` is
-- not a secret guard). MOCK.CFG.secretType = "userdata" switches to the lenient model.
local rawtype = R.type
local function wowType(...)
    if select("#", ...) == 0 then error("bad argument #1 to 'type' (value expected)", 2) end
    local v = ...
    local t = rawtype(v)
    if t == "userdata" and MOCK.CFG.secretType ~= "userdata" then
        local s = secretVal[v]
        if s then return rawtype(s[1]) end
    end
    return t
end

local rawtostring = R.tostring
local function wowTostring(...)
    if select("#", ...) == 0 then error("bad argument #1 to 'tostring' (value expected)", 2) end
    local v = ...
    if isSecret(v) then
        logTaint("tostring", 2, "warn")
        return v
    end
    return rawtostring(v)
end

local rawtonumber = R.tonumber
local function wowTonumber(v, base)
    if isSecret(v) then
        logTaint("tonumber", 2, "warn")
        local n = rawtonumber(secretVal[v][1], base)
        return MOCK.Secret(n)
    end
    return rawtonumber(v, base)
end

-- string library: inspection functions raise on secrets (as the client does), transforms
-- silently produce a secret result; every touch is logged.
local INSPECT = { byte = true, find = true, gmatch = true, gsub = true, len = true, match = true, sub = true }
local function wrapStringFn(name, fn)
    if INSPECT[name] then
        return function(a, b, c, d, ...)
            if rawtype(a) == "userdata" or rawtype(b) == "userdata" or rawtype(c) == "userdata" or rawtype(d) == "userdata" then
                if isSecret(a) or isSecret(b) or isSecret(c) or isSecret(d) then
                    logTaint("string." .. name, 2, "error")
                    error("bad argument to '" .. name .. "' (secret value)", 2)
                end
            end
            return fn(a, b, c, d, ...)
        end
    end
    return function(...)
        local n = select("#", ...)
        local found = false
        for i = 1, n do
            local v = select(i, ...)
            if rawtype(v) == "userdata" and isSecret(v) then found = true break end
        end
        if not found then return fn(...) end
        logTaint("string." .. name, 2, "warn")
        local args = packn(...)
        for i = 1, args.n do args[i] = MOCK.Unwrap(args[i]) end
        local ok, r = R.pcall(fn, R.unpack(args, 1, args.n))
        if not ok then error(r, 2) end
        return MOCK.Secret(r)
    end
end

local function installSecretWrappers()
    for _, name in ipairs({ "byte", "find", "format", "gmatch", "gsub", "len", "lower", "match", "rep", "reverse", "sub", "upper" }) do
        string[name] = wrapStringFn(name, string[name])
    end
    local rawconcat = table.concat
    table.concat = function(t, sep, i, j)
        if rawtype(t) == "table" then
            for k = i or 1, j or #t do
                local v = t[k]
                if rawtype(v) == "userdata" and isSecret(v) then
                    logTaint("table.concat", 2, "error")
                    error("invalid value (secret) at index " .. k .. " in table for 'concat'", 2)
                end
            end
        end
        if isSecret(sep) then logTaint("table.concat", 2, "error") error("bad argument #2 to 'concat' (secret value)", 2) end
        return rawconcat(t, sep, i, j)
    end
    local rawinsert = table.insert
    table.insert = function(t, ...)
        local n = select("#", ...)
        local v = select(n, ...)
        if rawtype(v) == "userdata" and isSecret(v) then logTaint("table.insert(secret)", 2, "warn") end
        return rawinsert(t, ...)
    end
    _G.type = wowType
    _G.tostring = wowTostring
    _G.tonumber = wowTonumber
end
MOCK.installSecretWrappers = installSecretWrappers

-------------------------------------------------------------------------------
-- C_Timer
-------------------------------------------------------------------------------
local timers = {}
local timerSeq = 0
MOCK.timers = timers

local function addTimer(due, entry)
    timerSeq = timerSeq + 1
    entry.due, entry.seq = due, timerSeq
    local lo, hi = 1, #timers
    while lo <= hi do
        local mid = floor((lo + hi) / 2)
        local m = timers[mid]
        if m.due < due or (m.due == due and m.seq < entry.seq) then lo = mid + 1 else hi = mid - 1 end
    end
    tinsert(timers, lo, entry)
    return entry
end
MOCK.AddTimer = addTimer

local TimerHandle = {}
TimerHandle.__index = TimerHandle
function TimerHandle:Cancel()
    -- a cancelled handle stops counting as live straight away
    if self._live then self._live = false; MOCK.NoteLive(-1) end
    self._cancelled = true
end
function TimerHandle:IsCancelled() return self._cancelled == true end
function TimerHandle:Invoke(...) if self._callback then return self._callback(...) end end
TimerHandle.__metatable = false

local function checkTimerArgs(fname, seconds, callback)
    if type(seconds) ~= "number" then
        error("bad argument #1 to '" .. fname .. "' (number expected, got " .. type(seconds) .. ")", 3)
    end
    if type(callback) ~= "function" then
        error("bad argument #2 to '" .. fname .. "' (function expected, got " .. type(callback) .. ")", 3)
    end
end

--- the addon code that asked for the timer (looking past Core/Init.lua's GF:After/Ticker/Debounce)
local function timerWhere()
    local fallback
    for level = 3, 40 do
        local info = debug.getinfo(level, "Sl")
        if not info then break end
        if isAddonSource(info.source) then
            local loc = sub(info.source, 2) .. ":" .. tostring(info.currentline or 0)
            if info.source ~= "@Greenfields/Core/Init.lua" then return loc end
            fallback = fallback or loc
        end
    end
    return fallback or "?"
end

MOCK.liveTimers = 0
MOCK.maxLiveTimers = 0
MOCK.peakTimers = {}     -- where -> live count at the peak (FACTS G18: keep <= 50 live handles)
local function noteLive(delta)
    MOCK.liveTimers = MOCK.liveTimers + delta
    if MOCK.liveTimers > MOCK.maxLiveTimers then
        MOCK.maxLiveTimers = MOCK.liveTimers
        if MOCK.liveTimers > 40 then
            local hist = {}
            for _, t in ipairs(timers) do
                if not (t.handle and t.handle._cancelled) then hist[t.where or "?"] = (hist[t.where or "?"] or 0) + 1 end
            end
            MOCK.peakTimers = hist
            MOCK.peakTimersAt = MOCK.scenario
        end
    end
end
MOCK.NoteLive = noteLive

local C_Timer = {}
function C_Timer.After(seconds, callback)
    checkTimerArgs("After", seconds, callback)
    addTimer(MOCK.uptime + R.max(0, seconds), { fn = callback, where = timerWhere() })
    noteLive(1)
end
function C_Timer.NewTimer(seconds, callback)
    checkTimerArgs("NewTimer", seconds, callback)
    local h = R.setmetatable({ _callback = callback, _live = true }, TimerHandle)
    addTimer(MOCK.uptime + R.max(0, seconds), { fn = callback, handle = h, where = timerWhere() })
    noteLive(1)
    return h
end
function C_Timer.NewTicker(seconds, callback, iterations)
    checkTimerArgs("NewTicker", seconds, callback)
    if iterations ~= nil and type(iterations) ~= "number" then
        error("bad argument #3 to 'NewTicker' (number expected, got " .. type(iterations) .. ")", 2)
    end
    local h = R.setmetatable({ _callback = callback, _remaining = iterations, _live = true }, TimerHandle)
    addTimer(MOCK.uptime + R.max(0, seconds), { fn = callback, handle = h, interval = R.max(0.01, seconds), where = timerWhere() })
    noteLive(1)
    return h
end
MOCK.C_Timer = C_Timer

local function runTimers()
    local limit = timerSeq
    local now = MOCK.uptime
    while true do
        local t = timers[1]
        if not t or t.due > now or t.seq > limit then break end
        tremove(timers, 1)
        local h = t.handle
        if h and h._cancelled then
            -- already stopped counting when it was cancelled
        else
            Protect("timer", t.where, t.fn, h)
            if t.interval and not h._cancelled then
                if h._remaining then h._remaining = h._remaining - 1 end
                if h._remaining == nil or h._remaining > 0 then
                    addTimer(now + t.interval, t)
                elseif h._live then
                    h._live = false
                    noteLive(-1)
                end
            elseif h then
                if h._live then h._live = false; noteLive(-1) end
            else
                noteLive(-1)
            end
        end
    end
end
MOCK.RunTimers = runTimers

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
MOCK.validEvents = {}           -- filled by wow_mock_data.lua
MOCK.restrictedEvents = { COMBAT_LOG_EVENT_UNFILTERED = true, COMBAT_LOG_EVENT = true }
MOCK.eventReg = {}              -- event -> array of frames (registration order)
MOCK.unknownEvents = {}         -- event -> { count, where }
MOCK.forbidden = {}             -- { what, where }
MOCK.eventsFired = {}           -- event -> count (diagnostics)
MOCK.secretArgs = {}            -- event -> { cat = ..., [argIndex] = true } (filled by data)

function MOCK.NoteUnknownEvent(event, level)
    local e = MOCK.unknownEvents[event]
    if not e then
        e = { count = 0, where = addonLocation((level or 2) + 1) or "?" }
        MOCK.unknownEvents[event] = e
    end
    e.count = e.count + 1
end

function MOCK.NoteForbidden(what, level)
    local where = addonWhere((level or 2) + 1) or "?"
    MOCK.forbidden[#MOCK.forbidden + 1] = { what = what, where = where, scenario = MOCK.scenario }
end

local function applySecretArgs(event, args)
    local spec = MOCK.secretArgs[event]
    if not spec then return end
    for cat, idx in pairs(spec) do
        if MOCK.secretOn[cat] then
            for _, i in ipairs(idx) do
                if args[i] ~= nil and not isSecret(args[i]) then args[i] = MOCK.Secret(args[i]) end
            end
        end
    end
end

--- FireEvent(event, ...) -- dispatches to every frame registered for it (errors recorded)
function MOCK.FireEvent(event, ...)
    if not MOCK.validEvents[event] then
        error("mock: harness fired an event that is not in the whitelist: " .. tostring(event), 2)
    end
    MOCK.eventsFired[event] = (MOCK.eventsFired[event] or 0) + 1
    local list = MOCK.eventReg[event]
    if not list or #list == 0 then return 0 end
    local args = packn(...)
    applySecretArgs(event, args)
    local snapshot = {}
    for i = 1, #list do snapshot[i] = list[i] end
    local n = 0
    for _, frame in ipairs(snapshot) do
        local reg = MOCK.EventRegistration(frame, event)
        if reg then
            local ok = true
            if reg.units then
                local unit = MOCK.Unwrap(args[1])
                ok = reg.units[unit] == true
            end
            if ok then
                n = n + 1
                MOCK.RunScript(frame, "OnEvent", event, R.unpack(args, 1, args.n))
            end
        end
    end
    return n
end

-------------------------------------------------------------------------------
-- Strict globals
-------------------------------------------------------------------------------
MOCK.globalReads = {}      -- name -> { count, where, trace }
MOCK.globalWrites = {}     -- name -> { count, where, allowed }
MOCK.mockGlobalReads = {}  -- name -> where   (a mock bug)

local ALLOWED_WRITE_PREFIXES = { "Greenfields", "SLASH_GREENFIELDS", "GreenfieldsDB", "GreenfieldsCharDB" }
local function writeAllowed(name)
    if type(name) ~= "string" then return false end
    for _, p in ipairs(ALLOWED_WRITE_PREFIXES) do
        if sub(name, 1, #p) == p then return true end
    end
    return false
end

function MOCK.InstallStrictGlobals()
    local G = _G
    R.setmetatable(G, {
        __index = function(_, k)
            local info = debug.getinfo(2, "Sl")
            local src = info and info.source
            if isAddonSource(src) then
                local e = MOCK.globalReads[k]
                if not e then
                    e = { count = 0, where = sub(src, 2) .. ":" .. tostring(info.currentline or 0), trace = traceback(2, 6), scenario = MOCK.scenario }
                    MOCK.globalReads[k] = e
                end
                e.count = e.count + 1
            elseif isMockSource(src) then
                MOCK.mockGlobalReads[k] = sub(src, 2) .. ":" .. tostring(info.currentline or 0)
            end
            return nil
        end,
        __newindex = function(t, k, v)
            local info = debug.getinfo(2, "Sl")
            local src = info and info.source
            if isAddonSource(src) then
                local e = MOCK.globalWrites[k]
                if not e then
                    e = { count = 0, where = sub(src, 2) .. ":" .. tostring(info.currentline or 0), allowed = writeAllowed(k), scenario = MOCK.scenario }
                    MOCK.globalWrites[k] = e
                end
                e.count = e.count + 1
            end
            R.rawset(t, k, v)
        end,
    })
end

--- The addon probes most client APIs with rawget(_G, "Name") (FACTS 0.3), which strict
-- globals cannot see. This wraps rawget so misses on _G from addon code are logged too,
-- with the two innermost addon frames (the probe helper and its caller).
MOCK.rawgetMisses = {}     -- name -> { count, where }
function MOCK.InstallRawgetProbe()
    local raw = R.rawget
    local G_ = _G
    local function where2()
        local out = {}
        for level = 3, 30 do
            local info = debug.getinfo(level, "Sl")
            if not info then break end
            if isAddonSource(info.source) then
                out[#out + 1] = sub(info.source, 2) .. ":" .. tostring(info.currentline or 0)
                if #out >= 2 then break end
            end
        end
        return concat(out, " <- ")
    end
    R.rawset(_G, "rawget", function(t, k)
        local v = raw(t, k)
        if v == nil and t == G_ and type(k) == "string" then
            local info = debug.getinfo(2, "S")
            if info and isAddonSource(info.source) then
                local e = MOCK.rawgetMisses[k]
                if not e then
                    e = { count = 0, where = where2(), scenario = MOCK.scenario }
                    MOCK.rawgetMisses[k] = e
                end
                e.count = e.count + 1
            end
        end
        return v
    end)
end

-------------------------------------------------------------------------------
-- JSON (deterministic: object keys sorted; used for everything handed to run.py)
-------------------------------------------------------------------------------
local JSON_ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function jsonString(s)
    s = R.gsub(s, '[%c"\\]', function(c)
        return JSON_ESC[c] or R.format("\\u%04x", R.byte(c))
    end)
    return '"' .. s .. '"'
end
local function jsonEncode(v, out, depth, seen)
    local t = R.type(v)
    if v == nil then out[#out + 1] = "null"
    elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
        elseif v == floor(v) and v > -1e15 and v < 1e15 then out[#out + 1] = R.format("%d", v)
        else out[#out + 1] = R.format("%.6g", v) end
    elseif t == "string" then out[#out + 1] = jsonString(v)
    elseif t == "userdata" then out[#out + 1] = isSecret(v) and '"<secret>"' or '"<userdata>"'
    elseif t == "table" then
        if depth > 40 or seen[v] then out[#out + 1] = '"<cycle>"' return end
        seen[v] = true
        local n = 0
        for _ in R.pairs(v) do n = n + 1 end
        local isArray = n > 0
        for i = 1, n do if R.rawget(v, i) == nil then isArray = false break end end
        if n == 0 then
            out[#out + 1] = (R.getmetatable(v) == MOCK.ARRAY) and "[]" or "{}"
        elseif isArray then
            out[#out + 1] = "["
            for i = 1, n do
                if i > 1 then out[#out + 1] = "," end
                jsonEncode(R.rawget(v, i), out, depth + 1, seen)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in R.pairs(v) do keys[#keys + 1] = k end
            R.sort(keys, function(a, b)
                local ta, tb = R.type(a), R.type(b)
                if ta ~= tb then return ta < tb end
                if ta == "number" or ta == "string" then return a < b end
                return R.tostring(a) < R.tostring(b)
            end)
            out[#out + 1] = "{"
            for i, k in R.ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                local ks = R.type(k) == "string" and k or (isSecret(k) and "<secret>" or R.tostring(k))
                out[#out + 1] = jsonString(ks)
                out[#out + 1] = ":"
                jsonEncode(R.rawget(v, k), out, depth + 1, seen)
            end
            out[#out + 1] = "}"
        end
        seen[v] = nil
    else
        out[#out + 1] = '"<' .. t .. '>"'
    end
end
MOCK.ARRAY = {}   -- metatable marker: an empty table that must encode as []
function MOCK.JSON(v)
    local out = {}
    jsonEncode(v, out, 0, {})
    return concat(out)
end
function MOCK.Array(t) return R.setmetatable(t or {}, MOCK.ARRAY) end

-------------------------------------------------------------------------------
-- Environment cleanup: remove what the WoW client does not have
-------------------------------------------------------------------------------
function MOCK.StripStockLibs()
    for _, k in ipairs({ "io", "os", "debug", "package", "require", "module", "dofile", "loadfile", "python" }) do
        R.rawset(_G, k, nil)
    end
end

--- Loads one addon file the way the client does: chunk(addonName, ns). Returns ok.
function MOCK.LoadAddonFile(src, chunkname, addonName, ns)
    local fn, err = R.loadstring(src, chunkname)
    if not fn then
        MOCK.RecordError("load", chunkname, err, "")
        return false
    end
    local ok = Protect("load", sub(chunkname, 2), fn, addonName, ns)
    return ok and true or false
end
