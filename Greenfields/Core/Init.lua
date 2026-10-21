--[[ Greenfields - Core/Init.lua
     Namespace, error isolation, event bus, internal messages, timers, modules, slash.

     Every handler runs through GF:Safe so one broken feature can never take the rest of
     the addon (or Blizzard's UI) down with it. Event registration is pcall'd because the
     Forever client raises on unknown events. ]]

local ADDON, GF = ...
_G.Greenfields = GF

GF.ADDON = ADDON
-- The TOC is the single source of truth for the version (tools/release.py bumps it).
do
    local CA = rawget(_G, "C_AddOns")
    local meta = (CA and CA.GetAddOnMetadata) or rawget(_G, "GetAddOnMetadata")
    local ok, v = false, nil
    if meta then ok, v = pcall(meta, ADDON, "Version") end
    GF.VERSION = (ok and type(v) == "string" and v:match("^%d+%.%d+%.%d+")) and v or "1.0.0"
end
GF.PROTOCOL = 1
GF.modules = {}
GF.moduleOrder = {}

local type, pairs, ipairs, select, tostring, pcall, xpcall = type, pairs, ipairs, select, tostring, pcall, xpcall
local format = string.format
local debugstack = debugstack

-------------------------------------------------------------------------------
-- Output
-------------------------------------------------------------------------------
local PREFIX = "|cff3ddb78Greenfields|r"

function GF:Print(fmt, ...)
    local msg = select("#", ...) > 0 and format(fmt, ...) or tostring(fmt)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. " " .. msg)
    end
end

function GF:Debug(fmt, ...)
    if not (self.db and self.db.settings and self.db.settings.debug) then return end
    local ok, msg = pcall(format, fmt, ...)
    self:Print("|cff8fa396[debug]|r " .. (ok and msg or tostring(fmt)))
end

-------------------------------------------------------------------------------
-- Error isolation
-------------------------------------------------------------------------------
GF.errors = {}
local errorCounts = {}

local function handler(err)
    local trace = debugstack and debugstack(3, 12, 0) or ""
    return tostring(err) .. "\n" .. trace
end

local function packn(...) return { n = select("#", ...), ... } end

--- Runs fn(...) protected. Returns true, results... or false. Errors are recorded (see
-- /gf errors) and printed once per unique message when debug is on.
function GF:Safe(label, fn, ...)
    if type(fn) ~= "function" then return false end
    -- stock Lua 5.1 xpcall passes no arguments through, so close over them
    local args = packn(...)
    local res = packn(xpcall(function() return fn(unpack(args, 1, args.n)) end, handler))
    if res[1] then return unpack(res, 1, res.n) end
    local err = tostring(res[2])
    local key = label .. ":" .. (err:match("^[^\n]*") or err)
    errorCounts[key] = (errorCounts[key] or 0) + 1
    if errorCounts[key] == 1 then
        local list = GF.errors
        list[#list + 1] = { label = label, err = err, time = time and time() or 0 }
        if #list > 50 then table.remove(list, 1) end
        if GF.db and GF.db.settings and GF.db.settings.debug then
            GF:Print("|cffff5555error in %s:|r %s", label, err:match("^[^\n]*") or err)
        end
    end
    return false
end

--- Wraps fn so every call is protected under `label`.
function GF:Wrap(label, fn)
    return function(...) return GF:Safe(label, fn, ...) end
end

-------------------------------------------------------------------------------
-- Event bus (game events)
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local eventHandlers = {}   -- event -> { {owner, fn}, ... }
local unitEventFrames = {} -- "EVENT:unit" -> frame

local function dispatch(event, ...)
    local list = eventHandlers[event]
    if not list then return end
    for i = 1, #list do
        local h = list[i]
        if h and not h.dead then
            GF:Safe(event, h.fn, event, ...)
        end
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...) dispatch(event, ...) end)

local function tryRegister(frame, event, unit)
    local ok
    if unit then
        ok = pcall(frame.RegisterUnitEvent, frame, event, unit)
    else
        ok = pcall(frame.RegisterEvent, frame, event)
    end
    return ok
end

--- GF:RegisterEvent("EVENT", fn [, owner]) -> true if the client knows the event.
-- fn(event, ...) is called for every firing. Several handlers per event are fine.
function GF:RegisterEvent(event, fn, owner)
    if type(event) ~= "string" or type(fn) ~= "function" then return false end
    local list = eventHandlers[event]
    if not list then
        if not tryRegister(eventFrame, event) then
            self:Debug("event %s is not available on this client", event)
            return false
        end
        list = {}
        eventHandlers[event] = list
    end
    list[#list + 1] = { fn = fn, owner = owner }
    return true
end

function GF:UnregisterEvent(event, owner)
    local list = eventHandlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        if owner == nil or list[i].owner == owner then
            list[i].dead = true
            table.remove(list, i)
        end
    end
    if #list == 0 then
        eventHandlers[event] = nil
        pcall(eventFrame.UnregisterEvent, eventFrame, event)
    end
end

--- Unit events ("UNIT_AURA", "player") get their own frame so they only fire for that unit.
function GF:RegisterUnitEvent(event, unit, fn)
    local key = event .. ":" .. unit
    local f = unitEventFrames[key]
    if not f then
        f = CreateFrame("Frame")
        f.handlers = {}
        if not tryRegister(f, event, unit) then return false end
        f:SetScript("OnEvent", function(_, ev, ...)
            for i = 1, #f.handlers do GF:Safe(ev, f.handlers[i], ev, ...) end
        end)
        unitEventFrames[key] = f
    end
    f.handlers[#f.handlers + 1] = fn
    return true
end

function GF:IsEventValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then
        local ok, valid = pcall(C_EventUtils.IsEventValid, event)
        if ok then return valid and true or false end
    end
    return true
end

-------------------------------------------------------------------------------
-- Internal messages (addon-wide callbacks)
-------------------------------------------------------------------------------
local callbacks = {}

--- GF:On("MESSAGE", fn) -> token; fn(...) gets whatever Fire passed.
function GF:On(msg, fn)
    local list = callbacks[msg]
    if not list then list = {}; callbacks[msg] = list end
    local token = { fn = fn }
    list[#list + 1] = token
    return token
end

function GF:Off(msg, token)
    local list = callbacks[msg]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == token then table.remove(list, i) end
    end
end

function GF:Fire(msg, ...)
    local list = callbacks[msg]
    if not list then return end
    -- copy so handlers may unregister during dispatch
    local n = #list
    local snapshot = {}
    for i = 1, n do snapshot[i] = list[i] end
    for i = 1, n do GF:Safe(msg, snapshot[i].fn, ...) end
end

-------------------------------------------------------------------------------
-- Timers (C_Timer, protected)
-------------------------------------------------------------------------------
function GF:After(sec, fn)
    if not (C_Timer and C_Timer.After) then return end
    C_Timer.After(math.max(0, sec or 0), function() GF:Safe("timer", fn) end)
end

--- Repeating timer; returns a handle with :Cancel().
function GF:Ticker(sec, fn)
    if not (C_Timer and C_Timer.NewTicker) then return { Cancel = function() end } end
    return C_Timer.NewTicker(sec, function() GF:Safe("ticker", fn) end)
end

--- Debounce: calls fn once, `sec` after the last Debounce(key) call. One live timer per
-- key: repeat calls only push the deadline out (keeps the client's timer count low).
local debounces = {}
function GF:Debounce(key, sec, fn)
    local now = GetTime and GetTime() or 0
    local d = debounces[key]
    if d then
        d.due, d.fn = now + sec, fn
        return
    end
    d = { due = now + sec, fn = fn }
    debounces[key] = d
    local function fire()
        local t = GetTime and GetTime() or 0
        if t + 0.01 < d.due then
            GF:After(d.due - t, fire)
            return
        end
        debounces[key] = nil
        d.fn()
    end
    self:After(sec, fire)
end

-------------------------------------------------------------------------------
-- Modules
--   GF:NewModule("Name") -> table. Optional lifecycle methods on it:
--     :OnInit()      SavedVariables are ready (ADDON_LOADED)
--     :OnLogin()     PLAYER_LOGIN - build UI, register events
--     :OnEnterWorld(isInitialLogin, isReload)
-------------------------------------------------------------------------------
function GF:NewModule(name)
    if self.modules[name] then return self.modules[name] end
    local m = { name = name }
    self.modules[name] = m
    self.moduleOrder[#self.moduleOrder + 1] = m
    return m
end

function GF:GetModule(name) return self.modules[name] end

local function runAll(method, ...)
    for _, m in ipairs(GF.moduleOrder) do
        if type(m[method]) == "function" then
            GF:Safe(m.name .. ":" .. method, m[method], m, ...)
        end
    end
end

-------------------------------------------------------------------------------
-- Slash commands: /gf <cmd> <args>
-------------------------------------------------------------------------------
GF.slash = {}

--- GF:RegisterSlash("cmd", fn(args), "help text")
function GF:RegisterSlash(cmd, fn, help)
    self.slash[cmd:lower()] = { fn = fn, help = help }
end

local function slashHandler(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    -- The handler runs inside the chat edit box's send path; defer real work a tick
    -- (Forever's gamepad navigation otherwise trips on focus changes).
    GF:After(0, function()
        local entry = GF.slash[cmd]
        if entry then
            entry.fn(rest)
        elseif cmd == "" then
            if GF.UI and GF.UI.ToggleMain then GF.UI:ToggleMain() end
        else
            GF:Print("Commands:")
            local keys = {}
            for k in pairs(GF.slash) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local h = GF.slash[k].help
                if h then GF:Print("  |cff3ddb78/gf %s|r - %s", k, h) end
            end
        end
    end)
end

SLASH_GREENFIELDS1 = "/gf"
SLASH_GREENFIELDS2 = "/greenfields"
SlashCmdList.GREENFIELDS = slashHandler

GF:RegisterSlash("errors", function()
    if #GF.errors == 0 then GF:Print("No errors recorded. She's running sweet.") return end
    for i, e in ipairs(GF.errors) do
        GF:Print("%d. [%s] %s", i, e.label, e.err:match("^[^\n]*") or e.err)
    end
end, "list captured Lua errors")

GF:RegisterSlash("debug", function()
    GF.db.settings.debug = not GF.db.settings.debug
    GF:Print("Debug %s.", GF.db.settings.debug and "on" or "off")
end, "toggle debug output")

GF:RegisterSlash("version", function()
    GF:Print("Version %s (protocol %d).", GF.VERSION, GF.PROTOCOL)
end, "show version")

-------------------------------------------------------------------------------
-- Boot
-------------------------------------------------------------------------------
GF:RegisterEvent("ADDON_LOADED", function(_, name)
    if name ~= ADDON then return end
    GF:UnregisterEvent("ADDON_LOADED", "core-boot")
    if GF.DB and GF.DB.Init then GF:Safe("DB:Init", GF.DB.Init, GF.DB) end
    runAll("OnInit")
    GF:Fire("GF_INIT")
end, "core-boot")

GF:RegisterEvent("PLAYER_LOGIN", function()
    GF.loggedIn = true
    runAll("OnLogin")
    GF:Fire("GF_LOGIN")
end)

GF:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReload)
    runAll("OnEnterWorld", isInitialLogin, isReload)
    GF:Fire("GF_ENTER_WORLD", isInitialLogin, isReload)
end)
