--[[ tools/harness/wow_mock_widgets.lua  --  the widget system.

     Every widget is a plain Lua table ([0] = userdata, like the client) whose metatable
     __index is the method table of its type. A method a real widget of that type lacks is
     simply absent, so calling it raises "attempt to call method 'X' (a nil value)"
     exactly like WoW. Internal state lives in a side table keyed by the widget, so addon
     fields on frames never collide with mock state.

     Types: Frame, Button, CheckButton, EditBox, ScrollFrame, Slider, StatusBar, Cooldown,
     GameTooltip, MessageFrame (+ EventFrame/DropdownButton aliases); regions Texture,
     MaskTexture, FontString, Line; Font objects. Animations are in wow_mock_anim.lua.

     Geometry: anchors are resolved on demand (cached per layout version) in each region's
     own coordinate space, with two-point stretching, centre anchors, scale conversion
     between regions and anchor-cycle detection at SetPoint time (as the client does). ]]

local MOCK = ...
local R = MOCK.R
local type, pairs, ipairs, select, tostring, tonumber = R.type, R.pairs, R.ipairs, R.select, R.tostring, R.tonumber
local error, rawset, rawget, setmetatable = R.error, R.rawset, R.rawget, R.setmetatable
local floor, max, min, abs = R.floor, R.max, R.min, R.abs
local format, sub, gsub, find, upper, lower, byte = R.format, R.sub, R.gsub, R.find, R.upper, R.lower, R.byte
local tinsert, tremove, concat, sort = R.insert, R.remove, R.concat, R.sort
local Protect, isSecret = MOCK.Protect, MOCK.IsSecret

local S = {}                    -- object -> state
MOCK.S = S
local objects = {}              -- creation order
MOCK.objects = objects
local Types = {}
MOCK.Types = Types

local SCREEN_W, SCREEN_H = MOCK.CFG.screenW or 1920, MOCK.CFG.screenH or 1080
-- set of the addon's media files ("interface\addons\greenfields\media\glow", lower case, no extension)
if MOCK.CFG.addonMedia then
    MOCK.addonMedia = {}
    for _, p in ipairs(MOCK.CFG.addonMedia) do MOCK.addonMedia[p] = true end
end
MOCK.SCREEN_W, MOCK.SCREEN_H = SCREEN_W, SCREEN_H

local layoutVer = 1
local function dirty() layoutVer = layoutVer + 1 end
MOCK.layoutIssues = setmetatable({}, { __mode = "k" })   -- region -> inverted-rect record
MOCK.LayoutDirty = dirty

local function ST(self, level)
    local st = S[self]
    if not st then error("Attempt to find 'this' in non-framescript object", (level or 2) + 1) end
    return st
end
MOCK.ST = ST

local function isNum(v) return type(v) == "number" and v == v end
local function argErr(fname, n, expected, got, level)
    error(format("bad argument #%d to '%s' (%s expected, got %s)", n, fname, expected, isSecret(got) and "secret" or type(got)), (level or 2) + 1)
end

local function objLabel(obj)
    local st = S[obj]
    if not st then return "?" end
    if st.name then return st.name end
    return st.otype .. "@" .. (st.where or "?")
end
MOCK.ObjLabel = objLabel

-------------------------------------------------------------------------------
-- Ordered sets (deterministic iteration for OnUpdate / OnSizeChanged / animations)
-------------------------------------------------------------------------------
local function OrderedSet()
    return { list = {}, idx = {}, holes = 0 }
end
local function osAdd(set, obj)
    if set.idx[obj] then return end
    set.list[#set.list + 1] = obj
    set.idx[obj] = #set.list
end
local function osRemove(set, obj)
    local i = set.idx[obj]
    if not i then return end
    set.list[i] = false
    set.idx[obj] = nil
    set.holes = set.holes + 1
    if set.holes > 64 and set.holes > #set.list / 2 then
        local nl = {}
        for _, o in ipairs(set.list) do
            if o then nl[#nl + 1] = o; set.idx[o] = #nl end
        end
        set.list, set.holes = nl, 0
    end
end
local function osSnapshot(set)
    local out = {}
    for _, o in ipairs(set.list) do if o then out[#out + 1] = o end end
    return out
end
MOCK.OrderedSet, MOCK.osAdd, MOCK.osRemove, MOCK.osSnapshot = OrderedSet, osAdd, osRemove, osSnapshot

local updateSet = OrderedSet()       -- frames with OnUpdate
local sizeSet = OrderedSet()         -- frames with OnSizeChanged / scroll frames
MOCK.updateSet, MOCK.sizeSet = updateSet, sizeSet

-------------------------------------------------------------------------------
-- Type construction
-------------------------------------------------------------------------------
local function defineType(name, isa, mixins, scripts)
    local t = { name = name, methods = {}, scripts = {}, isa = {} }
    for _, m in ipairs(mixins) do
        for k, v in pairs(m) do t.methods[k] = v end
    end
    for _, s in ipairs(scripts) do
        for k in pairs(s) do t.scripts[k] = true end
    end
    for _, n in ipairs(isa) do t.isa[lower(n)] = true end
    t.isa[lower(name)] = true
    t.meta = { __index = t.methods }
    Types[name] = t
    return t
end

local function newObject(typeName, st)
    local t = Types[typeName]
    local obj = setmetatable({ [0] = R.newproxy() }, t.meta)
    st.otype = typeName
    st.T = t
    st.id = #objects + 1
    st.where = st.where or MOCK.addonWhere(3)
    st.scripts = {}
    st.hooks = {}
    S[obj] = st
    objects[#objects + 1] = obj
    return obj
end
MOCK.NewObject = newObject

local function set(...)
    local t = {}
    for i = 1, select("#", ...) do t[(select(i, ...))] = true end
    return t
end

-------------------------------------------------------------------------------
-- Script sets per widget kind
-------------------------------------------------------------------------------
local SCRIPTS_REGION = set("OnShow", "OnHide", "OnEnter", "OnLeave", "OnMouseDown", "OnMouseUp", "OnLoad")
local SCRIPTS_FRAME = set("OnAttributeChanged", "OnChar", "OnDisable", "OnDragStart", "OnDragStop", "OnEnable",
    "OnEnter", "OnEvent", "OnGamePadButtonDown", "OnGamePadButtonUp", "OnGamePadStick", "OnHide", "OnHyperlinkClick",
    "OnHyperlinkEnter", "OnHyperlinkLeave", "OnKeyDown", "OnKeyUp", "OnLeave", "OnLoad", "OnMouseDown", "OnMouseUp",
    "OnMouseWheel", "OnReceiveDrag", "OnShow", "OnSizeChanged", "OnUpdate")
local SCRIPTS_BUTTON = set("OnClick", "OnDoubleClick", "PreClick", "PostClick")
local SCRIPTS_EDITBOX = set("OnArrowPressed", "OnCharComposition", "OnCursorChanged", "OnEditFocusGained",
    "OnEditFocusLost", "OnEnterPressed", "OnEscapePressed", "OnInputLanguageChanged", "OnSpacePressed",
    "OnTabPressed", "OnTextChanged", "OnTextSet")
local SCRIPTS_SCROLL = set("OnHorizontalScroll", "OnScrollRangeChanged", "OnVerticalScroll")
local SCRIPTS_VALUE = set("OnMinMaxChanged", "OnValueChanged")
local SCRIPTS_COOLDOWN = set("OnCooldownDone")
local SCRIPTS_TOOLTIP = set("OnTooltipAddMoney", "OnTooltipCleared", "OnTooltipSetDefaultAnchor")
local SCRIPTS_MESSAGE = set("OnMessageScrollChanged")
MOCK.SCRIPTS_ANIMGROUP = set("OnFinished", "OnLoad", "OnLoop", "OnPause", "OnPlay", "OnStop", "OnUpdate")
MOCK.SCRIPTS_ANIM = set("OnFinished", "OnLoad", "OnPause", "OnPlay", "OnStop", "OnUpdate")

-------------------------------------------------------------------------------
-- Scripts
-------------------------------------------------------------------------------
local function trackScriptSets(obj, st, name)
    local has = st.scripts[name] ~= nil or (st.hooks[name] and #st.hooks[name] > 0)
    if name == "OnUpdate" and st.isFrame then
        if has then osAdd(updateSet, obj) else osRemove(updateSet, obj) end
    elseif name == "OnSizeChanged" and st.isFrame then
        if has or st.otype == "ScrollFrame" then osAdd(sizeSet, obj) else osRemove(sizeSet, obj) end
    end
end

--- RunScript(obj, "OnX", ...) -- handler then hooks, each protected; returns true if any ran
local function runScript(obj, name, ...)
    local st = S[obj]
    if not st then return false end
    local h = st.scripts[name]
    local ran = false
    if h then
        ran = true
        Protect("script", name .. " " .. objLabel(obj), h, obj, ...)
    end
    local hooks = st.hooks[name]
    if hooks then
        for i = 1, #hooks do
            ran = true
            Protect("script", name .. "(hook) " .. objLabel(obj), hooks[i], obj, ...)
        end
    end
    return ran
end
MOCK.RunScript = runScript

local M_ScriptObject = {}
function M_ScriptObject:SetScript(name, fn)
    local st = ST(self)
    if type(name) ~= "string" then error("Usage: " .. st.otype .. ":SetScript(\"type\", function)", 2) end
    if not st.T.scripts[name] then
        error(format("%s:SetScript(): %s doesn't have a \"%s\" script", st.otype, objLabel(self), name), 2)
    end
    if fn ~= nil and type(fn) ~= "function" then error("Usage: " .. st.otype .. ":SetScript(\"type\", function)", 2) end
    st.scripts[name] = fn
    st.hooks[name] = nil      -- SetScript discards HookScript hooks, as on the client
    trackScriptSets(self, st, name)
end
function M_ScriptObject:GetScript(name)
    local st = ST(self)
    if type(name) ~= "string" or not st.T.scripts[name] then
        error(format("%s:GetScript(): %s doesn't have a \"%s\" script", st.otype, objLabel(self), tostring(name)), 2)
    end
    return st.scripts[name]
end
function M_ScriptObject:HookScript(name, fn)
    local st = ST(self)
    if type(name) ~= "string" or not st.T.scripts[name] then
        error(format("%s:HookScript(): %s doesn't have a \"%s\" script", st.otype, objLabel(self), tostring(name)), 2)
    end
    if type(fn) ~= "function" then error("Usage: " .. st.otype .. ":HookScript(\"type\", function)", 2) end
    if not st.scripts[name] and not st.hooks[name] then
        st.scripts[name] = fn
    else
        st.hooks[name] = st.hooks[name] or {}
        tinsert(st.hooks[name], fn)
    end
    trackScriptSets(self, st, name)
    return true
end
function M_ScriptObject:HasScript(name)
    local st = ST(self)
    return type(name) == "string" and st.T.scripts[name] == true
end

-------------------------------------------------------------------------------
-- Object basics
-------------------------------------------------------------------------------
local M_Object = {}
function M_Object:GetName() return ST(self).name end
function M_Object:GetDebugName() return objLabel(self) end
function M_Object:GetObjectType() return ST(self).otype end
function M_Object:IsObjectType(t) return type(t) == "string" and ST(self).T.isa[lower(t)] == true end
function M_Object:IsForbidden() ST(self) return false end
function M_Object:GetParent() return ST(self).parent end
function M_Object:GetParentKey() return ST(self).parentKey end
function M_Object:SetParentKey(k) ST(self).parentKey = k end
function M_Object:ClearParentKey() ST(self).parentKey = nil end

-------------------------------------------------------------------------------
-- Effective scale / alpha
-------------------------------------------------------------------------------
local function esOf(obj)
    local st = S[obj]
    if not st then return 1 end
    if st.esVer == layoutVer then return st.esVal end
    local s = st.scale or 1
    local p = st.parent
    if p and not st.ignoreParentScale then s = s * esOf(p) end
    st.esVer, st.esVal = layoutVer, s
    return s
end
MOCK.EffectiveScale = esOf

local function effAlpha(obj)
    local st = S[obj]
    if not st then return 1 end
    local a = st.alpha or 1
    if st.fx and st.fx.alpha then a = st.fx.alpha end
    local p = st.parent
    if p and not st.ignoreParentAlpha then a = a * effAlpha(p) end
    return a
end
MOCK.EffectiveAlpha = effAlpha

-------------------------------------------------------------------------------
-- Text measurement (font metrics come from run.py: font_metrics.json)
-------------------------------------------------------------------------------
local METRICS = MOCK.CFG.fontMetrics
local function fontKey(path)
    path = lower(gsub(tostring(path or ""), "/", "\\"))
    local base = R.match(path, "([^\\]+)$") or path
    if sub(base, 1, 6) == "arialn" then return "arialn" end
    if sub(base, 1, 8) == "morpheus" or sub(base, 1, 6) == "skurri" then return "morpheus" end
    return "frizqt"
end
MOCK.FontKey = fontKey

local function stripForMeasure(s)
    s = gsub(s, "||", "\1")
    s = gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    s = gsub(s, "|r", "")
    s = gsub(s, "|H.-|h(.-)|h", "%1")
    s = gsub(s, "|T.-|t", "\2")
    s = gsub(s, "|A.-|a", "\2")
    s = gsub(s, "|K.-|k", "?")
    s = gsub(s, "|n", "\n")
    s = gsub(s, "\1", "|")
    return s
end
MOCK.StripForMeasure = stripForMeasure

local function measure(s, path, size)
    local m = METRICS and METRICS[fontKey(path)]
    local w = 0
    for i = 1, #s do
        local b = byte(s, i)
        if b == 2 then
            w = w + 100
        elseif b < 128 then
            w = w + ((m and m.adv[b]) or 52)
        elseif b >= 192 then
            w = w + ((m and m.adv.other) or 52)
        end
    end
    return w * size / 100
end

local function splitLines(s)
    local out = {}
    local start = 1
    while true do
        local i = find(s, "\n", start, true)
        if not i then out[#out + 1] = sub(s, start) break end
        out[#out + 1] = sub(s, start, i - 1)
        start = i + 1
    end
    return out
end

--- wraps plain text into lines no wider than width (greedy, on spaces)
local function wrapLines(s, path, size, width, wrap)
    local out = {}
    for _, line in ipairs(splitLines(s)) do
        if not wrap or not width or width <= 0 or measure(line, path, size) <= width + 0.5 then
            out[#out + 1] = line
        else
            local cur = ""
            for word in R.gmatch(line, "%S+") do
                local cand = (cur == "") and word or (cur .. " " .. word)
                if cur ~= "" and measure(cand, path, size) > width + 0.5 then
                    out[#out + 1] = cur
                    cur = word
                else
                    cur = cand
                end
            end
            out[#out + 1] = cur
        end
    end
    return out
end
MOCK.Measure, MOCK.WrapLines = measure, wrapLines

-------------------------------------------------------------------------------
-- Fonts (FontInstance)
-------------------------------------------------------------------------------
local function resolveFontField(st, field)
    if st[field] ~= nil then return st[field] end
    local fo, depth = st.fontObject, 0
    while fo and depth < 12 do
        local fst = S[fo]
        if not fst then break end
        if fst[field] ~= nil then return fst[field] end
        fo, depth = fst.fontObject, depth + 1
    end
    return nil
end
MOCK.ResolveFontField = resolveFontField

local function textOf(st)
    local t = st.text
    if t == nil then return "" end
    if isSecret(t) then return "<secret>" end
    return t
end
MOCK.TextOf = textOf

local function validFontPath(path)
    if type(path) ~= "string" then return false end
    local p = lower(gsub(path, "\\", "/"))
    if MOCK.fontFiles[p] then return true end
    if MOCK.CFG.addonFonts and MOCK.CFG.addonFonts[p] then return true end
    return false
end

local M_FontInstance = {}
function M_FontInstance:SetFont(path, size, flags)
    local st = ST(self)
    if type(path) ~= "string" then argErr("SetFont", 1, "string", path) end
    if not isNum(size) then argErr("SetFont", 2, "number", size) end
    if flags ~= nil and type(flags) ~= "string" then argErr("SetFont", 3, "string", flags) end
    if not validFontPath(path) then
        MOCK.Warn("font", "SetFont: font file not found: " .. path, 2)
        return false
    end
    st.font = { path, size, flags or "" }
    dirty()
    return true
end
function M_FontInstance:GetFont()
    local st = ST(self)
    local f = resolveFontField(st, "font")
    if not f then return nil end
    return f[1], f[2], f[3]
end
function M_FontInstance:SetFontObject(fo)
    local st = ST(self)
    if type(fo) == "string" then
        local g = rawget(_G, fo)
        if not g then error("Usage: " .. st.otype .. ":SetFontObject(fontObject) - unknown font object '" .. fo .. "'", 2) end
        fo = g
    end
    if fo ~= nil and not (S[fo] and S[fo].isFontObject) then
        error("Usage: " .. st.otype .. ":SetFontObject(fontObject)", 2)
    end
    st.fontObject = fo
    st.font = nil
    dirty()
end
function M_FontInstance:GetFontObject() return ST(self).fontObject end
function M_FontInstance:SetTextColor(r, g, b, a)
    local st = ST(self)
    if not isNum(r) or not isNum(g) or not isNum(b) then error("Usage: " .. st.otype .. ":SetTextColor(r, g, b[, a])", 2) end
    st.textColor = { r, g, b, isNum(a) and a or 1 }
end
function M_FontInstance:GetTextColor()
    local c = resolveFontField(ST(self), "textColor") or { 1, 1, 1, 1 }
    return c[1], c[2], c[3], c[4]
end
function M_FontInstance:SetShadowColor(r, g, b, a)
    local st = ST(self)
    if not isNum(r) or not isNum(g) or not isNum(b) then error("Usage: " .. st.otype .. ":SetShadowColor(r, g, b[, a])", 2) end
    st.shadowColor = { r, g, b, isNum(a) and a or 1 }
end
function M_FontInstance:GetShadowColor()
    local c = resolveFontField(ST(self), "shadowColor") or { 0, 0, 0, 1 }
    return c[1], c[2], c[3], c[4]
end
function M_FontInstance:SetShadowOffset(x, y)
    local st = ST(self)
    if not isNum(x) or not isNum(y) then error("Usage: " .. st.otype .. ":SetShadowOffset(x, y)", 2) end
    st.shadowOffset = { x, y }
end
function M_FontInstance:GetShadowOffset()
    local o = resolveFontField(ST(self), "shadowOffset") or { 0, 0 }
    return o[1], o[2]
end
local JH = set("LEFT", "CENTER", "RIGHT")
local JV = set("TOP", "MIDDLE", "BOTTOM")
function M_FontInstance:SetJustifyH(j)
    local st = ST(self)
    if type(j) ~= "string" or not JH[upper(j)] then error("Usage: " .. st.otype .. ":SetJustifyH(\"LEFT\"|\"CENTER\"|\"RIGHT\")", 2) end
    st.justifyH = upper(j)
end
function M_FontInstance:GetJustifyH() return resolveFontField(ST(self), "justifyH") or "CENTER" end
function M_FontInstance:SetJustifyV(j)
    local st = ST(self)
    if type(j) ~= "string" or not JV[upper(j)] then error("Usage: " .. st.otype .. ":SetJustifyV(\"TOP\"|\"MIDDLE\"|\"BOTTOM\")", 2) end
    st.justifyV = upper(j)
end
function M_FontInstance:GetJustifyV() return resolveFontField(ST(self), "justifyV") or "MIDDLE" end
function M_FontInstance:SetSpacing(n)
    local st = ST(self)
    if not isNum(n) then argErr("SetSpacing", 1, "number", n) end
    st.spacing = n
    dirty()
end
function M_FontInstance:GetSpacing() return resolveFontField(ST(self), "spacing") or 0 end
function M_FontInstance:SetIndentedWordWrap(on) ST(self).indented = on and true or false end
function M_FontInstance:GetIndentedWordWrap() return ST(self).indented == true end

-------------------------------------------------------------------------------
-- Geometry
-------------------------------------------------------------------------------
local POINTS = {
    TOPLEFT = { 0, 1 }, TOP = { 0.5, 1 }, TOPRIGHT = { 1, 1 },
    LEFT = { 0, 0.5 }, CENTER = { 0.5, 0.5 }, RIGHT = { 1, 0.5 },
    BOTTOMLEFT = { 0, 0 }, BOTTOM = { 0.5, 0 }, BOTTOMRIGHT = { 1, 0 },
}
MOCK.POINTS = POINTS

local intrinsicSize -- forward (fontstrings)

local rectOf
local function relRectScreen(rel)
    if rel == nil then return 0, 0, SCREEN_W, SCREEN_H end
    local l, b, w, h = rectOf(rel)
    if not l then return nil end
    local s = esOf(rel)
    return l * s, b * s, w * s, h * s
end

rectOf = function(obj)
    local st = S[obj]
    if not st then return nil end
    if st.rv == layoutVer then
        if st.rInvalid then return nil end
        return st.rl, st.rb, st.rw, st.rh
    end
    if st.resolving then return nil end
    st.resolving = true
    local s = esOf(obj)
    local L, Rr, CX, T, B, CY
    local ok = true
    if st.isScreenRoot then
        L, B, Rr, T = 0, 0, SCREEN_W / s, SCREEN_H / s
    elseif st.scrollFrame then
        local sf = st.scrollFrame
        local sl, sb, sw, sh = relRectScreen(sf)
        if not sl then ok = false else
            local sst = S[sf]
            L = sl / s - (sst.hscroll or 0)
            T = (sb + sh) / s + (sst.vscroll or 0)
        end
    else
        local pts = st.points
        if not pts or #pts == 0 then ok = false end
        if ok then
            for i = 1, #pts do
                local p = pts[i]
                local rel = p.rel
                if rel == nil then rel = st.parent end
                local rl, rb, rw, rh = relRectScreen(rel)
                if not rl then ok = false break end
                local f = POINTS[p.relPoint]
                local x = (rl + rw * f[1]) / s + p.x
                local y = (rb + rh * f[2]) / s + p.y
                local g = POINTS[p.point]
                if g[1] == 0 then L = x elseif g[1] == 1 then Rr = x else CX = x end
                if g[2] == 0 then B = y elseif g[2] == 1 then T = y else CY = y end
            end
        end
    end
    if not ok then
        st.resolving = false
        st.rv, st.rInvalid = layoutVer, true
        return nil
    end
    local w, h
    if L and Rr then w = Rr - L
    elseif L and CX then w = 2 * (CX - L)
    elseif Rr and CX then w = 2 * (Rr - CX)
    else w = st.width end
    if T and B then h = T - B
    elseif T and CY then h = 2 * (T - CY)
    elseif B and CY then h = 2 * (CY - B)
    else h = st.height end
    if (w == nil or h == nil) and st.isFontString then
        local iw, ih = intrinsicSize(obj, st, w)
        w = w or iw
        h = h or ih
    end
    w, h = w or 0, h or 0
    local left = L or (Rr and Rr - w) or (CX and CX - w / 2) or 0
    local bottom = B or (T and T - h) or (CY and CY - h / 2) or 0
    st.resolving = false
    st.rv, st.rInvalid = layoutVer, false
    st.rl, st.rb, st.rw, st.rh = left, bottom, w, h
    return left, bottom, w, h
end
MOCK.RectOf = rectOf

--- screen-space rect (pixels) incl. animation translation of the region and its ancestors
function MOCK.ScreenRect(obj)
    local l, b, w, h = rectOf(obj)
    if not l then return nil end
    local s = esOf(obj)
    local dx, dy = 0, 0
    local o = obj
    while o do
        local ost = S[o]
        if ost.fx and ost.fx.dx then
            local os_ = esOf(o)
            dx, dy = dx + ost.fx.dx * os_, dy + ost.fx.dy * os_
        end
        o = ost.parent
    end
    return l * s + dx, b * s + dy, w * s, h * s
end

local function dependsOn(a, target, seen)
    if a == target then return true end
    local st = S[a]
    if not st or seen[a] then return false end
    seen[a] = true
    local pts = st.points
    if pts then
        for i = 1, #pts do
            local rel = pts[i].rel
            if rel == nil then rel = st.parent end
            if rel and dependsOn(rel, target, seen) then return true end
        end
    end
    if st.scrollFrame and dependsOn(st.scrollFrame, target, seen) then return true end
    return false
end

local function resolveRegionArg(v, fname)
    if v == nil then return nil end
    if type(v) == "string" then
        local g = rawget(_G, v)
        if not (g and S[g]) then error(format("%s(): Couldn't find region named '%s'", fname, v), 3) end
        return g
    end
    if type(v) == "table" and S[v] and S[v].isRegionLike then return v end
    error(format("%s(): Invalid region (expected a frame or region, got %s)", fname, isSecret(v) and "secret" or type(v)), 3)
end

local M_ScriptRegion = {}

local function normPoint(p, fname)
    if type(p) ~= "string" then error(format("Usage: %s(\"point\" [, region, \"relativePoint\"] [, x, y])", fname), 3) end
    local u = upper(p)
    if not POINTS[u] then error(format("%s(): Invalid region point '%s'", fname, p), 3) end
    return u
end

function M_ScriptRegion:SetPoint(point, a, b, c, d)
    local st = ST(self)
    if st.isScreenRoot then return end
    point = normPoint(point, st.otype .. ":SetPoint")
    local rel, relPoint, x, y
    if a == nil and b == nil and c == nil and d == nil then
        rel, relPoint, x, y = nil, point, 0, 0
    elseif isNum(a) then
        rel, relPoint, x, y = nil, point, a, b or 0
        if not isNum(y) then error("Usage: " .. st.otype .. ":SetPoint(point, x, y)", 2) end
    else
        rel = resolveRegionArg(a, st.otype .. ":SetPoint")
        if type(b) == "string" then
            relPoint = normPoint(b, st.otype .. ":SetPoint")
            x, y = c or 0, d or 0
        elseif b == nil and isNum(c) then
            relPoint, x, y = point, c, d or 0
        else
            relPoint = point
            x, y = b or 0, c or 0
        end
        if not isNum(x) or not isNum(y) then error("Usage: " .. st.otype .. ":SetPoint(point, region, relativePoint, x, y)", 2) end
    end
    if rel == self then error("Action[SetPoint] failed because[Cannot anchor to itself]", 2) end
    local effRel = rel or st.parent
    if effRel and dependsOn(effRel, self, {}) then
        error("Action[SetPoint] failed because[Cannot anchor to a region dependent on it]", 2)
    end
    st.points = st.points or {}
    st.anchoredAt = MOCK.addonWhere(2)
    local entry = { point = point, rel = rel, relPoint = relPoint, x = x, y = y }
    for i, p in ipairs(st.points) do
        if p.point == point then st.points[i] = entry; dirty() return end
    end
    st.points[#st.points + 1] = entry
    dirty()
end
function M_ScriptRegion:SetAllPoints(rel, doResize)
    local st = ST(self)
    if rel == true then rel = nil end
    rel = resolveRegionArg(rel, st.otype .. ":SetAllPoints")
    local effRel = rel or st.parent
    if rel == self then error("Action[SetPoint] failed because[Cannot anchor to itself]", 2) end
    if effRel and dependsOn(effRel, self, {}) then
        error("Action[SetPoint] failed because[Cannot anchor to a region dependent on it]", 2)
    end
    st.anchoredAt = MOCK.addonWhere(2)
    st.points = {
        { point = "TOPLEFT", rel = rel, relPoint = "TOPLEFT", x = 0, y = 0 },
        { point = "BOTTOMRIGHT", rel = rel, relPoint = "BOTTOMRIGHT", x = 0, y = 0 },
    }
    dirty()
end
function M_ScriptRegion:ClearAllPoints()
    local st = ST(self)
    if st.points and #st.points > 0 then st.points = {}; dirty() end
end
function M_ScriptRegion:ClearPoint(point)
    local st = ST(self)
    point = normPoint(point, st.otype .. ":ClearPoint")
    for i, p in ipairs(st.points or {}) do
        if p.point == point then tremove(st.points, i); dirty() return end
    end
end
function M_ScriptRegion:AdjustPointsOffset(dx, dy)
    local st = ST(self)
    for _, p in ipairs(st.points or {}) do p.x, p.y = p.x + (dx or 0), p.y + (dy or 0) end
    dirty()
end
function M_ScriptRegion:GetNumPoints() return #(ST(self).points or {}) end
function M_ScriptRegion:GetPoint(i)
    local st = ST(self)
    i = i or 1
    if type(i) ~= "number" then argErr("GetPoint", 1, "number", i) end
    local p = (st.points or {})[i]
    if not p then return nil end
    return p.point, p.rel or st.parent, p.relPoint, p.x, p.y
end
function M_ScriptRegion:GetPointByName(name)
    local st = ST(self)
    for _, p in ipairs(st.points or {}) do
        if p.point == upper(tostring(name)) then return p.point, p.rel or st.parent, p.relPoint, p.x, p.y end
    end
end
function M_ScriptRegion:SetSize(w, h)
    local st = ST(self)
    if not isNum(w) then argErr("SetSize", 1, "number", w) end
    if h == nil then h = w end
    if not isNum(h) then argErr("SetSize", 2, "number", h) end
    st.width, st.height = w, h
    dirty()
end
function M_ScriptRegion:SetWidth(w)
    local st = ST(self)
    if not isNum(w) then argErr("SetWidth", 1, "number", w) end
    st.width = w
    dirty()
end
function M_ScriptRegion:SetHeight(h)
    local st = ST(self)
    if not isNum(h) then argErr("SetHeight", 1, "number", h) end
    st.height = h
    dirty()
end
local function sizeOf(obj)
    local st = S[obj]
    local _, _, w, h = rectOf(obj)
    if w then return w, h end
    local iw, ih
    if st.isFontString then iw, ih = intrinsicSize(obj, st, st.width) end
    return st.width or iw or 0, st.height or ih or 0
end
MOCK.SizeOf = sizeOf
function M_ScriptRegion:GetWidth() ST(self) local w = sizeOf(self) return w end
function M_ScriptRegion:GetHeight() ST(self) local _, h = sizeOf(self) return h end
function M_ScriptRegion:GetSize() ST(self) return sizeOf(self) end
function M_ScriptRegion:GetLeft() ST(self) local l = rectOf(self) return l end
function M_ScriptRegion:GetBottom() ST(self) local _, b = rectOf(self) return b end
function M_ScriptRegion:GetRight() ST(self) local l, _, w = rectOf(self) return l and l + w end
function M_ScriptRegion:GetTop() ST(self) local _, b, _, h = rectOf(self) return b and b + h end
function M_ScriptRegion:GetCenter()
    ST(self)
    local l, b, w, h = rectOf(self)
    if not l then return nil end
    return l + w / 2, b + h / 2
end
function M_ScriptRegion:GetRect() ST(self) return rectOf(self) end
function M_ScriptRegion:GetScaledRect()
    ST(self)
    local l, b, w, h = rectOf(self)
    if not l then return nil end
    local s = esOf(self)
    return l * s, b * s, w * s, h * s
end
function M_ScriptRegion:IsRectValid() ST(self) return rectOf(self) ~= nil end
function M_ScriptRegion:IsAnchoringRestricted() ST(self) return false end
function M_ScriptRegion:CanChangeProtectedState() ST(self) return not (MOCK.state and MOCK.state.combat) end
function M_ScriptRegion:IsProtected() ST(self) return false, false end
function M_ScriptRegion:GetSourceLocation() return ST(self).where end

-------------------------------------------------------------------------------
-- Visibility & hierarchy
-------------------------------------------------------------------------------
local function isVisible(obj)
    local st = S[obj]
    while st do
        if not st.shown then return false end
        local p = st.parent
        if not p then return true end
        st = S[p]
    end
    return true
end
MOCK.IsVisible = isVisible

local onBecameVisible -- forward (focus, toplevel)

local function fireShowTree(obj, scriptName, became)
    local st = S[obj]
    if became and onBecameVisible then onBecameVisible(obj, st) end
    if not became and st.isEditBox and st.focus then MOCK.ClearFocus(obj) end
    runScript(obj, scriptName)
    if st.children then
        local snap = {}
        for i, c in ipairs(st.children) do snap[i] = c end
        for _, c in ipairs(snap) do
            local cst = S[c]
            if cst.shown and cst.parent == obj then fireShowTree(c, scriptName, became) end
        end
    end
    if st.regions then
        for _, r in ipairs(st.regions) do
            local rst = S[r]
            if rst.shown and (rst.scripts[scriptName] or rst.hooks[scriptName]) then runScript(r, scriptName) end
        end
    end
end

function M_ScriptRegion:Show()
    local st = ST(self)
    if st.shown then return end
    st.shown = true
    dirty()
    if isVisible(self) then fireShowTree(self, "OnShow", true) end
end
function M_ScriptRegion:Hide()
    local st = ST(self)
    if not st.shown then return end
    local was = isVisible(self)
    st.shown = false
    dirty()
    if was then fireShowTree(self, "OnHide", false) end
end
function M_ScriptRegion:SetShown(on)
    if on then self:Show() else self:Hide() end
end
function M_ScriptRegion:IsShown() return ST(self).shown == true end
function M_ScriptRegion:IsVisible() ST(self) return isVisible(self) end

local function removeFrom(list, obj)
    if not list then return end
    for i = #list, 1, -1 do if list[i] == obj then tremove(list, i) end end
end

local function setParent(obj, newParent)
    local st = S[obj]
    if newParent == st.parent then return end
    local was = isVisible(obj)
    if st.parent then
        local pst = S[st.parent]
        if st.isFrame then removeFrom(pst.children, obj) else removeFrom(pst.regions, obj) end
    end
    st.parent = newParent
    if newParent then
        local pst = S[newParent]
        if st.isFrame then
            pst.children = pst.children or {}
            pst.children[#pst.children + 1] = obj
        else
            pst.regions = pst.regions or {}
            pst.regions[#pst.regions + 1] = obj
        end
    end
    dirty()
    local now = isVisible(obj)
    if was ~= now then fireShowTree(obj, now and "OnShow" or "OnHide", now) end
end
MOCK.SetParentRaw = setParent

function M_ScriptRegion:SetParent(p)
    local st = ST(self)
    if type(p) == "string" then
        local g = rawget(_G, p)
        if not (g and S[g]) then error(st.otype .. ":SetParent(): Couldn't find frame named '" .. p .. "'", 2) end
        p = g
    end
    if p ~= nil then
        local pst = S[p]
        if not (pst and pst.isFrame) then error("Usage: " .. st.otype .. ":SetParent(frame)", 2) end
        if st.isFrame then
            local q = p
            while q do
                if q == self then error(st.otype .. ":SetParent(): Can't set a frame as a child of its own descendant", 2) end
                q = S[q].parent
            end
        end
    elseif not st.isFrame then
        error("Usage: " .. st.otype .. ":SetParent(frame)", 2)
    end
    setParent(self, p)
end

-------------------------------------------------------------------------------
-- Mouse
-------------------------------------------------------------------------------
MOCK.cursorX, MOCK.cursorY = MOCK.CFG.cursorX or 4, MOCK.CFG.cursorY or 4
function M_ScriptRegion:EnableMouse(on) ST(self).mouse = on and true or false end
function M_ScriptRegion:IsMouseEnabled() return ST(self).mouse == true end
function M_ScriptRegion:SetMouseClickEnabled(on) ST(self).mouseClick = on and true or false end
function M_ScriptRegion:IsMouseClickEnabled() local st = ST(self) if st.mouseClick ~= nil then return st.mouseClick end return st.mouse == true end
function M_ScriptRegion:SetMouseMotionEnabled(on) ST(self).mouseMotion = on and true or false end
function M_ScriptRegion:IsMouseMotionEnabled() local st = ST(self) if st.mouseMotion ~= nil then return st.mouseMotion end return st.mouse == true end
function M_ScriptRegion:EnableMouseMotion(on) ST(self).mouseMotion = on and true or false end
function M_ScriptRegion:SetPassThroughButtons() ST(self) end
function M_ScriptRegion:IsMouseOver(top, bottom, left, right)
    ST(self)
    local l, b, w, h = MOCK.ScreenRect(self)
    if not l then return false end
    local s = esOf(self)
    local x, y = MOCK.cursorX, MOCK.cursorY
    if MOCK.hoverObject then
        local o = MOCK.hoverObject
        while o do
            if o == self then return true end
            o = S[o] and S[o].parent
        end
    end
    return x >= l - (left or 0) * s and x <= l + w + (right or 0) * s and y >= b - (bottom or 0) * s and y <= b + h + (top or 0) * s
end
function M_ScriptRegion:IsDragging() return ST(self).dragging == true end
function M_ScriptRegion:IsCollapsed() ST(self) return false end
function M_ScriptRegion:SetCollapsesLayout() ST(self) end

-------------------------------------------------------------------------------
-- Alpha / scale / draw layer (shared by regions and frames)
-------------------------------------------------------------------------------
local M_Alpha = {}
function M_Alpha:SetAlpha(a)
    local st = ST(self)
    if not isNum(a) then argErr("SetAlpha", 1, "number", a) end
    st.alpha = max(0, min(1, a))
end
function M_Alpha:GetAlpha() return ST(self).alpha or 1 end
function M_Alpha:GetEffectiveAlpha() ST(self) return effAlpha(self) end
function M_Alpha:SetIgnoreParentAlpha(on) ST(self).ignoreParentAlpha = on and true or false end
function M_Alpha:IsIgnoringParentAlpha() return ST(self).ignoreParentAlpha == true end
function M_Alpha:SetScale(s)
    local st = ST(self)
    if not isNum(s) then argErr("SetScale", 1, "number", s) end
    if s <= 0 then error(st.otype .. ":SetScale(): Scale must be > 0", 2) end
    st.scale = s
    dirty()
end
function M_Alpha:GetScale() return ST(self).scale or 1 end
function M_Alpha:GetEffectiveScale() ST(self) return esOf(self) end
function M_Alpha:SetIgnoreParentScale(on) ST(self).ignoreParentScale = on and true or false; dirty() end
function M_Alpha:IsIgnoringParentScale() return ST(self).ignoreParentScale == true end

local LAYERS = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }
MOCK.LAYERS = LAYERS
local function checkLayer(layer, sublevel, fname, level)
    if layer ~= nil then
        if type(layer) ~= "string" or not LAYERS[upper(layer)] then
            error(format("%s(): Invalid draw layer '%s'", fname, tostring(layer)), (level or 2) + 1)
        end
        layer = upper(layer)
    end
    if sublevel ~= nil then
        if not isNum(sublevel) or sublevel < -8 or sublevel > 7 then
            error(format("%s(): Sublevel must be between -8 and 7", fname), (level or 2) + 1)
        end
    end
    return layer, sublevel
end

local M_Region = {}
function M_Region:SetDrawLayer(layer, sublevel)
    local st = ST(self)
    layer, sublevel = checkLayer(layer, sublevel, st.otype .. ":SetDrawLayer")
    st.layer = layer or st.layer
    st.sublevel = sublevel or st.sublevel or 0
end
function M_Region:GetDrawLayer() local st = ST(self) return st.layer, st.sublevel or 0 end
function M_Region:SetVertexColor(r, g, b, a)
    local st = ST(self)
    if not isNum(r) or not isNum(g) or not isNum(b) then error("Usage: " .. st.otype .. ":SetVertexColor(r, g, b[, a])", 2) end
    st.vc = { r, g, b, isNum(a) and a or 1 }
end
function M_Region:GetVertexColor()
    local c = ST(self).vc or { 1, 1, 1, 1 }
    return c[1], c[2], c[3], c[4]
end
function M_Region:IsObjectLoaded() ST(self) return true end

-------------------------------------------------------------------------------
-- Textures
-------------------------------------------------------------------------------
local WRAP = set("CLAMP", "REPEAT", "CLAMPTOBLACK", "CLAMPTOBLACKADDITIVE", "CLAMPTOWHITE", "MIRROR")
local BLEND = set("BLEND", "ADD", "MOD", "ALPHAKEY", "DISABLE")

local function filterCrash(fname)
    -- FOREVER_FACTS R18: a filter argument crashes the client before pcall can catch it
    MOCK.RecordError("fatal", fname, fname .. ": filter argument passed (this crashes the Forever client, R18)",
        MOCK.traceback(3, 8))
    error(fname .. "(): filter argument crashes the client (FOREVER_FACTS R18)", 3)
end

local M_TextureBase = {}
function M_TextureBase:SetTexture(path, wrapH, wrapV, filter)
    local st = ST(self)
    if filter ~= nil then filterCrash(st.otype .. ":SetTexture") end
    if path ~= nil and type(path) ~= "string" and not isNum(path) then
        error("Usage: " .. st.otype .. ":SetTexture(file or fileID[, wrapH, wrapV])", 2)
    end
    for i, w in ipairs({ wrapH, wrapV }) do
        if w ~= nil and type(w) ~= "boolean" and not (type(w) == "string" and WRAP[upper(w)]) then
            error(format("%s:SetTexture(): Invalid wrap mode for argument #%d '%s'", st.otype, i + 1, tostring(w)), 2)
        end
    end
    if type(path) == "string" and MOCK.addonMedia then
        -- addon textures must exist on disk (the client draws a missing file as solid green)
        local p = lower(gsub(path, "/", "\\"))
        if find(p, "^interface\\addons\\") then
            local base = gsub(p, "%.[%a%d]+$", "")
            if not MOCK.addonMedia[base] then MOCK.Warn("texture", "SetTexture: addon file not found: " .. path, 2) end
        end
    end
    local tx = st.tex
    tx.file = path
    tx.atlas = nil
    tx.color = nil
    tx.wrapH = type(wrapH) == "string" and upper(wrapH) or (wrapH == true and "REPEAT" or nil)
    tx.wrapV = type(wrapV) == "string" and upper(wrapV) or (wrapV == true and "REPEAT" or nil)
    return true
end
function M_TextureBase:GetTexture()
    local tx = ST(self).tex
    if tx.atlas then local a = MOCK.atlases[tx.atlas] return a and a.file end
    return tx.file
end
function M_TextureBase:GetTextureFilePath() local f = ST(self).tex.file return type(f) == "string" and f or nil end
function M_TextureBase:GetTextureFileID() local f = ST(self).tex.file return isNum(f) and f or nil end
function M_TextureBase:SetColorTexture(r, g, b, a)
    local st = ST(self)
    if not isNum(r) or not isNum(g) or not isNum(b) then error("Usage: " .. st.otype .. ":SetColorTexture(r, g, b[, a])", 2) end
    local tx = st.tex
    tx.file, tx.atlas = nil, nil
    tx.color = { r, g, b, isNum(a) and a or 1 }
end
function M_TextureBase:SetAtlas(atlas, useAtlasSize, filter, resetTexCoords)
    local st = ST(self)
    if filter ~= nil then filterCrash(st.otype .. ":SetAtlas") end
    if type(atlas) ~= "string" then error("Usage: " .. st.otype .. ":SetAtlas(atlasName[, useAtlasSize])", 2) end
    local info = MOCK.atlases[atlas] or MOCK.atlases[lower(atlas)]
    if not info then
        MOCK.Warn("atlas", "SetAtlas: unknown atlas '" .. atlas .. "'", 2)
        return false
    end
    local tx = st.tex
    tx.atlas, tx.file, tx.color = atlas, nil, nil
    tx.coords = nil
    if useAtlasSize then st.width, st.height = info.width, info.height; dirty() end
    return true
end
function M_TextureBase:GetAtlas() return ST(self).tex.atlas end
function M_TextureBase:SetTexCoord(...)
    local st = ST(self)
    local n = select("#", ...)
    local a = { ... }
    for i = 1, n do if not isNum(a[i]) then n = -1 break end end
    if n == 4 then
        local l, r, t, b = a[1], a[2], a[3], a[4]
        st.tex.coords = { l, t, l, b, r, t, r, b }
    elseif n == 8 then
        st.tex.coords = a
    else
        error("Usage: " .. st.otype .. ":SetTexCoord(left, right, top, bottom) or (ULx, ULy, LLx, LLy, URx, URy, LRx, LRy)", 2)
    end
end
function M_TextureBase:GetTexCoord()
    local c = ST(self).tex.coords or { 0, 0, 0, 1, 1, 0, 1, 1 }
    return c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]
end
function M_TextureBase:ResetTexCoord() ST(self).tex.coords = nil end
function M_TextureBase:SetBlendMode(mode)
    local st = ST(self)
    if type(mode) ~= "string" or not BLEND[upper(mode)] then error(st.otype .. ":SetBlendMode(): Invalid blend mode '" .. tostring(mode) .. "'", 2) end
    st.tex.blend = upper(mode)
end
function M_TextureBase:GetBlendMode() return ST(self).tex.blend or "BLEND" end
function M_TextureBase:SetDesaturated(on) ST(self).tex.desat = on and 1 or 0 end
function M_TextureBase:IsDesaturated() return (ST(self).tex.desat or 0) > 0 end
function M_TextureBase:SetDesaturation(v) ST(self).tex.desat = tonumber(v) or 0 end
function M_TextureBase:GetDesaturation() return ST(self).tex.desat or 0 end
function M_TextureBase:SetHorizTile(on) ST(self).tex.htile = on and true or false end
function M_TextureBase:GetHorizTile() return ST(self).tex.htile == true end
function M_TextureBase:SetVertTile(on) ST(self).tex.vtile = on and true or false end
function M_TextureBase:GetVertTile() return ST(self).tex.vtile == true end
function M_TextureBase:SetRotation(rad, ox, oy)
    local st = ST(self)
    if not isNum(rad) then argErr("SetRotation", 1, "number", rad) end
    if type(ox) == "table" then ox, oy = ox.x, ox.y end
    st.tex.rotation = rad
    st.tex.rotOrigin = (isNum(ox) and isNum(oy)) and { ox, oy } or nil
end
function M_TextureBase:GetRotation() return ST(self).tex.rotation or 0 end
function M_TextureBase:SetGradient(orientation, minColor, maxColor)
    local st = ST(self)
    if type(orientation) ~= "string" or (upper(orientation) ~= "HORIZONTAL" and upper(orientation) ~= "VERTICAL") then
        error("bad argument #1 to 'SetGradient' (Usage: self:SetGradient(\"HORIZONTAL\"|\"VERTICAL\", minColor, maxColor))", 2)
    end
    for i, c in ipairs({ minColor, maxColor }) do
        if type(c) ~= "table" or type(c.GetRGBA) ~= "function" then
            error(format("bad argument #%d to 'SetGradient' (Usage: self:SetGradient(orientation, minColor, maxColor) - colors must be ColorMixin objects)", i + 1), 2)
        end
    end
    local r1, g1, b1, a1 = minColor:GetRGBA()
    local r2, g2, b2, a2 = maxColor:GetRGBA()
    st.tex.gradient = { upper(orientation), { r1, g1, b1, a1 or 1 }, { r2, g2, b2, a2 or 1 } }
end
function M_TextureBase:SetTextureSliceMargins(l, t, r, b)
    local st = ST(self)
    for i, v in ipairs({ l, t, r, b }) do if not isNum(v) then argErr("SetTextureSliceMargins", i, "number", v) end end
    st.tex.slice = { l, t, r, b }
end
function M_TextureBase:GetTextureSliceMargins()
    local s = ST(self).tex.slice
    if not s then return 0, 0, 0, 0 end
    return s[1], s[2], s[3], s[4]
end
function M_TextureBase:SetTextureSliceMode(mode)
    local st = ST(self)
    if mode ~= 0 and mode ~= 1 then error(st.otype .. ":SetTextureSliceMode(): Invalid slice mode " .. tostring(mode), 2) end
    st.tex.sliceMode = mode
end
function M_TextureBase:GetTextureSliceMode() return ST(self).tex.sliceMode or 0 end
function M_TextureBase:ClearTextureSlice() local tx = ST(self).tex tx.slice, tx.sliceMode = nil, nil end
function M_TextureBase:SetSnapToPixelGrid(on) ST(self).tex.snap = on end
function M_TextureBase:IsSnappingToPixelGrid() return ST(self).tex.snap == true end
function M_TextureBase:SetTexelSnappingBias(v) ST(self).tex.texelBias = v end
function M_TextureBase:GetTexelSnappingBias() return ST(self).tex.texelBias or 0 end
function M_TextureBase:SetNonBlocking(on) ST(self).tex.nonBlocking = on end
function M_TextureBase:GetNonBlocking() return ST(self).tex.nonBlocking == true end
function M_TextureBase:SetBlockingLoadsRequested(on) ST(self).tex.blocking = on end
function M_TextureBase:IsBlockingLoadRequested() return ST(self).tex.blocking == true end
function M_TextureBase:SetVertexOffset() ST(self) end

local M_TextureMask = {}
function M_TextureMask:AddMaskTexture(mask)
    local st = ST(self)
    local mst = S[mask]
    if not (mst and mst.otype == "MaskTexture") then error("Usage: " .. st.otype .. ":AddMaskTexture(maskTexture)", 2) end
    st.masks = st.masks or {}
    for _, m in ipairs(st.masks) do if m == mask then return end end
    st.masks[#st.masks + 1] = mask
end
function M_TextureMask:RemoveMaskTexture(mask)
    local st = ST(self)
    removeFrom(st.masks, mask)
end
function M_TextureMask:GetNumMaskTextures() return #(ST(self).masks or {}) end
function M_TextureMask:GetMaskTexture(i) return (ST(self).masks or {})[i] end

local M_Line = {}
local function linePoint(self, which, a, b, c, d)
    local st = ST(self, 2)
    local point = normPoint(a, "Line:Set" .. which .. "Point")
    local rel, x, y
    if isNum(b) then rel, x, y = nil, b, c or 0
    else rel = resolveRegionArg(b, "Line:Set" .. which .. "Point"); x, y = c or 0, d or 0 end
    st.line = st.line or {}
    st.line[which] = { point = point, rel = rel, x = x, y = y }
end
function M_Line:SetStartPoint(...) linePoint(self, "Start", ...) end
function M_Line:SetEndPoint(...) linePoint(self, "End", ...) end
function M_Line:GetStartPoint() local l = (ST(self).line or {}).Start if l then return l.point, l.rel, l.x, l.y end end
function M_Line:GetEndPoint() local l = (ST(self).line or {}).End if l then return l.point, l.rel, l.x, l.y end end
function M_Line:SetThickness(t) ST(self).thickness = tonumber(t) or 1 end
function M_Line:GetThickness() return ST(self).thickness or 1 end

-------------------------------------------------------------------------------
-- FontString
-------------------------------------------------------------------------------
local function fontOf(st)
    local f = resolveFontField(st, "font")
    if f then return f[1], f[2], f[3] end
    return nil
end
MOCK.FontOf = fontOf

local function linesOf(st, width)
    local path, size = fontOf(st)
    if not path then return {}, 12 end
    local text = stripForMeasure(textOf(st))
    if text == "" then return {}, size end
    local wrap = st.wordWrap ~= false
    local lines = wrapLines(text, path, size * (st.textScale or 1), width, wrap)
    if st.maxLines and st.maxLines > 0 and #lines > st.maxLines then
        local cut = {}
        for i = 1, st.maxLines do cut[i] = lines[i] end
        lines = cut
    end
    return lines, size * (st.textScale or 1)
end
MOCK.LinesOf = linesOf

intrinsicSize = function(obj, st, width)
    local path = fontOf(st)
    if not path then return 0, 0 end
    local lines, size = linesOf(st, width)
    local w = 0
    for _, l in ipairs(lines) do w = max(w, measure(l, path, size)) end
    local spacing = resolveFontField(st, "spacing") or 0
    local h = (#lines > 0) and (#lines * size + (#lines - 1) * spacing) or 0
    return w, h
end

local function constrainedWidth(obj, st)
    -- width that wraps the text: explicit width, or the stretched (two-point) width
    if st.width and st.width > 0 then return st.width end
    local pts = st.points or {}
    local hasL, hasR = false, false
    for _, p in ipairs(pts) do
        local g = POINTS[p.point]
        if g[1] == 0 then hasL = true elseif g[1] == 1 then hasR = true end
    end
    if hasL and hasR then
        local _, _, w = rectOf(obj)
        return w
    end
    return nil
end
MOCK.ConstrainedWidth = constrainedWidth

local M_FontString = {}
local function setText(self, st, text, fname)
    if text ~= nil and type(text) ~= "string" and not isNum(text) and not isSecret(text) then
        error(format("bad argument #1 to '%s' (string expected, got %s)", fname, type(text)), 3)
    end
    if not fontOf(st) then
        error(st.otype .. ":" .. fname .. "(): Font not set", 3)
    end
    if isNum(text) then text = tostring(text) end
    st.text = text
    dirty()
end
function M_FontString:SetText(text) local st = ST(self) setText(self, st, text, "SetText") end
function M_FontString:SetFormattedText(fmt, ...)
    local st = ST(self)
    if type(fmt) ~= "string" then argErr("SetFormattedText", 1, "string", fmt) end
    setText(self, st, string.format(fmt, ...), "SetFormattedText")
end
function M_FontString:GetText()
    local t = ST(self).text
    if t == nil then return nil end
    return t
end
function M_FontString:GetStringWidth()
    local st = ST(self)
    local path = fontOf(st)
    if not path then return 0 end
    local lines, size = linesOf(st, constrainedWidth(self, st))
    local w = 0
    for _, l in ipairs(lines) do w = max(w, measure(l, path, size)) end
    return w
end
function M_FontString:GetUnboundedStringWidth()
    local st = ST(self)
    local path, size = fontOf(st)
    if not path then return 0 end
    local w = 0
    for _, l in ipairs(splitLines(stripForMeasure(textOf(st)))) do w = max(w, measure(l, path, size * (st.textScale or 1))) end
    return w
end
function M_FontString:GetStringHeight()
    local st = ST(self)
    local _, h = intrinsicSize(self, st, constrainedWidth(self, st))
    return h
end
function M_FontString:GetWrappedWidth() return self:GetStringWidth() end
function M_FontString:GetLineHeight() local _, size = fontOf(ST(self)) return size or 0 end
function M_FontString:GetNumLines() local st = ST(self) local lines = linesOf(st, constrainedWidth(self, st)) return #lines end
function M_FontString:IsTruncated()
    local st = ST(self)
    local w = constrainedWidth(self, st)
    if not w then return false end
    return self:GetUnboundedStringWidth() > w + 0.5 and st.wordWrap == false
end
function M_FontString:SetWordWrap(on) ST(self).wordWrap = on and true or false; dirty() end
function M_FontString:CanWordWrap() return ST(self).wordWrap ~= false end
function M_FontString:SetNonSpaceWrap(on) ST(self).nonSpaceWrap = on and true or false end
function M_FontString:CanNonSpaceWrap() return ST(self).nonSpaceWrap == true end
function M_FontString:SetMaxLines(n)
    local st = ST(self)
    if not isNum(n) then argErr("SetMaxLines", 1, "number", n) end
    st.maxLines = n
    dirty()
end
function M_FontString:GetMaxLines() return ST(self).maxLines or 0 end
function M_FontString:SetTextHeight(h) local st = ST(self) local f = resolveFontField(st, "font") if f then st.font = { f[1], h, f[3] } end dirty() end
function M_FontString:SetTextScale(s) ST(self).textScale = tonumber(s) or 1; dirty() end
function M_FontString:GetTextScale() return ST(self).textScale or 1 end
function M_FontString:SetAlphaGradient() ST(self) return true end
function M_FontString:SetFixedColor(on) ST(self).fixedColor = on end
function M_FontString:HasFixedColor() return ST(self).fixedColor == true end
function M_FontString:FindCharacterIndexAtCoordinate() ST(self) return 1, false end
function M_FontString:CalculateScreenAreaFromCharacterSpan() ST(self) return nil end

-------------------------------------------------------------------------------
-- Region constructors
-------------------------------------------------------------------------------
local function newRegion(typeName, parent, name, layer, sublevel, extra)
    local st = extra or {}
    st.isRegionLike = true
    st.shown = true
    st.layer = layer
    st.sublevel = sublevel or 0
    local obj = newObject(typeName, st)
    if name then
        if type(name) ~= "string" then error("bad region name", 3) end
        local pname = parent and S[parent].name
        name = gsub(name, "%$[Pp]arent", pname or "")
        st.name = name
        rawset(_G, name, obj)
    end
    setParent(obj, parent)
    return obj
end
MOCK.NewRegion = newRegion

local function inheritFontTemplate(obj, st, inherits, fname)
    if inherits == nil then return end
    if type(inherits) ~= "string" then error("Usage: " .. fname .. "([name, layer, inherits])", 3) end
    for tname in R.gmatch(inherits, "[^,%s]+") do
        local fo = rawget(_G, tname)
        if fo and S[fo] and S[fo].isFontObject then
            st.fontObject = fo
        else
            error(format("%s(): Couldn't find inherited node \"%s\"", fname, tname), 3)
        end
    end
end

local M_FrameCreate = {}
function M_FrameCreate:CreateTexture(name, layer, inherits, sublevel)
    local st = ST(self)
    layer, sublevel = checkLayer(layer, sublevel, st.otype .. ":CreateTexture")
    if inherits ~= nil then error(format("%s:CreateTexture(): Couldn't find inherited node \"%s\"", st.otype, tostring(inherits)), 2) end
    return newRegion("Texture", self, name, layer or "ARTWORK", sublevel, { tex = {} })
end
function M_FrameCreate:CreateMaskTexture(name, layer, inherits, sublevel)
    local st = ST(self)
    layer, sublevel = checkLayer(layer, sublevel, st.otype .. ":CreateMaskTexture")
    if inherits ~= nil then error(format("%s:CreateMaskTexture(): Couldn't find inherited node \"%s\"", st.otype, tostring(inherits)), 2) end
    return newRegion("MaskTexture", self, name, layer or "ARTWORK", sublevel, { tex = {}, isMask = true })
end
function M_FrameCreate:CreateLine(name, layer, inherits, sublevel)
    local st = ST(self)
    layer, sublevel = checkLayer(layer, sublevel, st.otype .. ":CreateLine")
    if inherits ~= nil then error(format("%s:CreateLine(): Couldn't find inherited node \"%s\"", st.otype, tostring(inherits)), 2) end
    return newRegion("Line", self, name, layer or "ARTWORK", sublevel, { tex = {}, isLine = true })
end
function M_FrameCreate:CreateFontString(name, layer, inherits)
    local st = ST(self)
    layer = checkLayer(layer, nil, st.otype .. ":CreateFontString")
    local fs = newRegion("FontString", self, name, layer or "ARTWORK", 0, { isFontString = true })
    inheritFontTemplate(fs, S[fs], inherits, st.otype .. ":CreateFontString")
    return fs
end

-------------------------------------------------------------------------------
-- Frame methods
-------------------------------------------------------------------------------
local STRATA = { PARENT = 0, BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6,
    FULLSCREEN_DIALOG = 7, TOOLTIP = 8, BLIZZARD = 9 }
MOCK.STRATA = STRATA

local function strataOf(obj)
    local st = S[obj]
    local depth = 0
    while st and depth < 200 do
        if st.strata and st.strata ~= "PARENT" then return st.strata end
        if not st.parent then break end
        st = S[st.parent]
        depth = depth + 1
    end
    return "MEDIUM"
end
local function levelOf(obj)
    local st = S[obj]
    if st.level then return st.level end
    if st.parent and S[st.parent].isFrame then return levelOf(st.parent) + 1 end
    return 0
end
MOCK.StrataOf, MOCK.LevelOf = strataOf, levelOf

local M_Frame = {}
function M_Frame:SetFrameStrata(s)
    local st = ST(self)
    if type(s) ~= "string" or not STRATA[upper(s)] then error(st.otype .. ":SetFrameStrata(): Unknown frame strata '" .. tostring(s) .. "'", 2) end
    st.strata = upper(s)
end
function M_Frame:GetFrameStrata() ST(self) return strataOf(self) end
function M_Frame:SetFixedFrameStrata(on) ST(self).fixedStrata = on end
function M_Frame:HasFixedFrameStrata() return ST(self).fixedStrata == true end
function M_Frame:SetFrameLevel(n)
    local st = ST(self)
    if not isNum(n) then argErr("SetFrameLevel", 1, "number", n) end
    st.level = max(0, min(10000, floor(n)))
end
function M_Frame:GetFrameLevel() ST(self) return levelOf(self) end
function M_Frame:SetFixedFrameLevel(on) ST(self).fixedLevel = on end
function M_Frame:HasFixedFrameLevel() return ST(self).fixedLevel == true end
local function raise(obj)
    local strata = strataOf(obj)
    local top = 0
    for _, o in ipairs(objects) do
        local ost = S[o]
        if ost.isFrame and o ~= obj and ost.shown and strataOf(o) == strata then top = max(top, levelOf(o)) end
    end
    local st = S[obj]
    st.level = min(10000, max(levelOf(obj), top + 1))
end
MOCK.Raise = raise
function M_Frame:Raise() ST(self) raise(self) end
function M_Frame:Lower() ST(self).level = 0 end
function M_Frame:SetToplevel(on) ST(self).toplevel = on and true or false end
function M_Frame:IsToplevel() return ST(self).toplevel == true end
function M_Frame:SetClampedToScreen(on) ST(self).clamped = on and true or false end
function M_Frame:IsClampedToScreen() return ST(self).clamped == true end
function M_Frame:SetClampRectInsets(l, r, t, b) ST(self).clampInsets = { l, r, t, b } end
function M_Frame:GetClampRectInsets() local c = ST(self).clampInsets or { 0, 0, 0, 0 } return c[1], c[2], c[3], c[4] end
function M_Frame:SetMovable(on) ST(self).movable = on and true or false end
function M_Frame:IsMovable() return ST(self).movable == true end
function M_Frame:SetResizable(on) ST(self).resizable = on and true or false end
function M_Frame:IsResizable() return ST(self).resizable == true end
function M_Frame:SetResizeBounds(minW, minH, maxW, maxH)
    local st = ST(self)
    if not isNum(minW) or not isNum(minH) then error("Usage: " .. st.otype .. ":SetResizeBounds(minWidth, minHeight[, maxWidth, maxHeight])", 2) end
    st.resizeBounds = { minW, minH, maxW, maxH }
end
function M_Frame:GetResizeBounds()
    local b = ST(self).resizeBounds or { 0, 0, 0, 0 }
    return b[1], b[2], b[3] or 0, b[4] or 0
end
function M_Frame:StartMoving()
    local st = ST(self)
    if not st.movable then error(st.otype .. ":StartMoving(): Frame is not movable", 2) end
    st.dragging = true
    st.userPlaced = true
end
function M_Frame:StartSizing(point)
    local st = ST(self)
    if not st.resizable then error(st.otype .. ":StartSizing(): Frame is not resizable", 2) end
    st.dragging = true
end
function M_Frame:StopMovingOrSizing() ST(self).dragging = false end
function M_Frame:SetUserPlaced(on) ST(self).userPlaced = on and true or false end
function M_Frame:IsUserPlaced() return ST(self).userPlaced == true end
function M_Frame:SetDontSavePosition(on) ST(self).dontSave = on end
function M_Frame:GetDontSavePosition() return ST(self).dontSave == true end
function M_Frame:RegisterForDrag(...)
    local st = ST(self)
    st.dragButtons = {}
    for i = 1, select("#", ...) do st.dragButtons[(select(i, ...))] = true end
end
function M_Frame:GetChildren()
    local st = ST(self)
    return R.unpack(st.children or {})
end
function M_Frame:GetNumChildren() return #(ST(self).children or {}) end
function M_Frame:GetRegions()
    local st = ST(self)
    return R.unpack(st.regions or {})
end
function M_Frame:GetNumRegions() return #(ST(self).regions or {}) end
function M_Frame:EnableKeyboard(on) ST(self).keyboard = on and true or false end
function M_Frame:IsKeyboardEnabled() return ST(self).keyboard == true end
function M_Frame:SetPropagateKeyboardInput(on)
    local st = ST(self)
    if MOCK.state and MOCK.state.combat then error(st.otype .. ":SetPropagateKeyboardInput(): blocked in combat (ADDON_ACTION_BLOCKED)", 2) end
    st.propagateKeys = on and true or false
end
function M_Frame:GetPropagateKeyboardInput() return ST(self).propagateKeys == true end
function M_Frame:EnableMouseWheel(on) ST(self).wheel = on and true or false end
function M_Frame:IsMouseWheelEnabled() return ST(self).wheel == true end
function M_Frame:SetHitRectInsets(l, r, t, b) ST(self).hitInsets = { l, r, t, b } end
function M_Frame:GetHitRectInsets() local h = ST(self).hitInsets or { 0, 0, 0, 0 } return h[1], h[2], h[3], h[4] end
function M_Frame:SetClipsChildren(on) ST(self).clips = on and true or false end
function M_Frame:DoesClipChildren() return ST(self).clips == true end
function M_Frame:SetFlattensRenderLayers(on) ST(self).flattens = on end
function M_Frame:GetFlattensRenderLayers() return ST(self).flattens == true end
function M_Frame:SetIsFrameBuffer(on) ST(self).frameBuffer = on end
function M_Frame:IsFrameBuffer() return ST(self).frameBuffer == true end
function M_Frame:SetHyperlinksEnabled(on) ST(self).hyperlinks = on and true or false end
function M_Frame:GetHyperlinksEnabled() return ST(self).hyperlinks == true end
function M_Frame:SetHyperlinkPropagateToParent(on) ST(self).hyperlinkPropagate = on end
function M_Frame:SetID(id)
    local st = ST(self)
    if not isNum(id) then argErr("SetID", 1, "number", id) end
    st.frameID = id
end
function M_Frame:GetID() return ST(self).frameID or 0 end
function M_Frame:SetAttribute(k, v)
    local st = ST(self)
    st.attributes = st.attributes or {}
    st.attributes[k] = v
    runScript(self, "OnAttributeChanged", k, v)
end
function M_Frame:GetAttribute(k) local a = ST(self).attributes return a and a[k] end
function M_Frame:CanChangeAttribute() ST(self) return not (MOCK.state and MOCK.state.combat) end
function M_Frame:IgnoreDepth() ST(self) end
function M_Frame:SetDepth() ST(self) end
function M_Frame:GetDepth() ST(self) return 0 end
function M_Frame:GetEffectiveDepth() ST(self) return 0 end
function M_Frame:GetBoundsRect() ST(self) return rectOf(self) end
function M_Frame:RegisterAllEvents() error("Frame:RegisterAllEvents() is not available to addons", 2) end
function M_Frame:SetWindow() ST(self) end

-- events
local function checkEvent(st, event, fname)
    if type(event) ~= "string" then error(format("Usage: %s:%s(\"event\")", st.otype, fname), 3) end
    if MOCK.restrictedEvents[event] then
        MOCK.NoteForbidden(fname .. "(" .. event .. ")", 3)
        if MOCK.validEvents.ADDON_ACTION_FORBIDDEN then
            MOCK.pendingForbidden = MOCK.pendingForbidden or {}
            tinsert(MOCK.pendingForbidden, { "Greenfields", st.otype .. ":" .. fname .. "()" })
        end
        error(format("ADDON_ACTION_FORBIDDEN: AddOn tried to call the protected function '%s:%s()' (%s is restricted)", st.otype, fname, event), 3)
    end
    if not MOCK.validEvents[event] then
        MOCK.NoteUnknownEvent(event, 3)
        error(format("%s:%s(): Attempt to register unknown event \"%s\"", st.otype, fname, event), 3)
    end
end

local function regEvent(obj, st, event, units)
    st.events = st.events or {}
    local list = MOCK.eventReg[event]
    if not list then list = {}; MOCK.eventReg[event] = list end
    if not st.events[event] then list[#list + 1] = obj end
    st.events[event] = { units = units }
end
function M_Frame:RegisterEvent(event)
    local st = ST(self)
    checkEvent(st, event, "RegisterEvent")
    regEvent(self, st, event, nil)
    return true
end
function M_Frame:RegisterUnitEvent(event, ...)
    local st = ST(self)
    checkEvent(st, event, "RegisterUnitEvent")
    local units = {}
    local n = 0
    for i = 1, select("#", ...) do
        local u = select(i, ...)
        if u ~= nil then
            if type(u) ~= "string" then error("Usage: " .. st.otype .. ":RegisterUnitEvent(\"event\", \"unit1\"[, \"unit2\"])", 2) end
            units[u] = true
            n = n + 1
        end
    end
    regEvent(self, st, event, n > 0 and units or nil)
    return true
end
function M_Frame:UnregisterEvent(event)
    local st = ST(self)
    if type(event) ~= "string" then error("Usage: " .. st.otype .. ":UnregisterEvent(\"event\")", 2) end
    if not MOCK.validEvents[event] then
        MOCK.NoteUnknownEvent(event, 2)
        error(format("%s:UnregisterEvent(): Attempt to unregister unknown event \"%s\"", st.otype, event), 2)
    end
    if st.events and st.events[event] then
        st.events[event] = nil
        removeFrom(MOCK.eventReg[event], self)
    end
end
function M_Frame:UnregisterAllEvents()
    local st = ST(self)
    for ev in pairs(st.events or {}) do removeFrom(MOCK.eventReg[ev], self) end
    st.events = {}
end
function M_Frame:IsEventRegistered(event)
    local st = ST(self)
    local r = st.events and st.events[event]
    if not r then return false end
    if r.units then
        local us = {}
        for u in pairs(r.units) do us[#us + 1] = u end
        sort(us)
        return true, us[1], us[2]
    end
    return true
end
function MOCK.EventRegistration(obj, event)
    local st = S[obj]
    return st and st.events and st.events[event]
end

-------------------------------------------------------------------------------
-- Button / CheckButton
-------------------------------------------------------------------------------
local M_Button = {}
local function buttonTexture(self, st, slot, asset, layer)
    if asset == nil then
        if st[slot] then S[st[slot]].tex.file = nil end
        return
    end
    local tex = st[slot]
    if type(asset) == "table" and S[asset] and S[asset].tex then
        tex = asset
        if S[tex].parent ~= self then setParent(tex, self) end
        S[tex].layer = layer
    else
        if type(asset) ~= "string" and not isNum(asset) then error("Usage: Button:Set" .. slot .. "(texture or path)", 3) end
        if not tex then tex = newRegion("Texture", self, nil, layer, 0, { tex = {} }) end
        S[tex].tex.file = asset
    end
    if not S[tex].points or #S[tex].points == 0 then S[tex].points = {
        { point = "TOPLEFT", relPoint = "TOPLEFT", x = 0, y = 0 },
        { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT", x = 0, y = 0 } } end
    S[tex].buttonSlot = slot
    st[slot] = tex
    dirty()
end
function M_Button:SetNormalTexture(a) buttonTexture(self, ST(self), "NormalTexture", a, "ARTWORK") end
function M_Button:SetPushedTexture(a) buttonTexture(self, ST(self), "PushedTexture", a, "ARTWORK") end
function M_Button:SetHighlightTexture(a, blend) local st = ST(self) buttonTexture(self, st, "HighlightTexture", a, "HIGHLIGHT") if st.HighlightTexture and blend then S[st.HighlightTexture].tex.blend = upper(blend) end end
function M_Button:SetDisabledTexture(a) buttonTexture(self, ST(self), "DisabledTexture", a, "ARTWORK") end
function M_Button:GetNormalTexture() return ST(self).NormalTexture end
function M_Button:GetPushedTexture() return ST(self).PushedTexture end
function M_Button:GetHighlightTexture() return ST(self).HighlightTexture end
function M_Button:GetDisabledTexture() return ST(self).DisabledTexture end
function M_Button:ClearNormalTexture() local st = ST(self) if st.NormalTexture then S[st.NormalTexture].tex.file = nil end end
function M_Button:ClearPushedTexture() local st = ST(self) if st.PushedTexture then S[st.PushedTexture].tex.file = nil end end
function M_Button:ClearHighlightTexture() local st = ST(self) if st.HighlightTexture then S[st.HighlightTexture].tex.file = nil end end
function M_Button:ClearDisabledTexture() local st = ST(self) if st.DisabledTexture then S[st.DisabledTexture].tex.file = nil end end
local function atlasSlot(slot, layer)
    return function(self, atlas)
        local st = ST(self)
        buttonTexture(self, st, slot, "", layer)
        local ok, err = R.pcall(M_TextureBase.SetAtlas, st[slot], atlas)
        if not ok then error(err, 2) end
    end
end
M_Button.SetNormalAtlas = atlasSlot("NormalTexture", "ARTWORK")
M_Button.SetPushedAtlas = atlasSlot("PushedTexture", "ARTWORK")
M_Button.SetHighlightAtlas = atlasSlot("HighlightTexture", "HIGHLIGHT")
M_Button.SetDisabledAtlas = atlasSlot("DisabledTexture", "ARTWORK")
function M_Button:Enable()
    local st = ST(self)
    if st.enabled then return end
    st.enabled = true
    runScript(self, "OnEnable")
end
function M_Button:Disable()
    local st = ST(self)
    if not st.enabled then return end
    st.enabled = false
    runScript(self, "OnDisable")
end
function M_Button:SetEnabled(on) if on then self:Enable() else self:Disable() end end
function M_Button:IsEnabled() return ST(self).enabled == true end
function M_Button:RegisterForClicks(...)
    local st = ST(self)
    st.clicks = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) ~= "string" then error("Usage: Button:RegisterForClicks(\"type\"[, \"type\"...])", 2) end
        st.clicks[v] = true
    end
end
function M_Button:RegisterForMouse(...) ST(self) end
function M_Button:Click(button, down)
    local st = ST(self)
    if not st.enabled then return end
    button = button or "LeftButton"
    if st.isCheckButton then st.checked = not st.checked end
    runScript(self, "PreClick", button, down and true or false)
    runScript(self, "OnClick", button, down and true or false)
    runScript(self, "PostClick", button, down and true or false)
end
function M_Button:GetButtonState() return ST(self).buttonState or "NORMAL" end
function M_Button:SetButtonState(s, lock)
    local st = ST(self)
    if s ~= "NORMAL" and s ~= "PUSHED" and s ~= "DISABLED" then error("Usage: Button:SetButtonState(\"NORMAL\"|\"PUSHED\"[, lock])", 2) end
    st.buttonState = s
end
function M_Button:LockHighlight() ST(self).highlightLocked = true end
function M_Button:UnlockHighlight() ST(self).highlightLocked = false end
function M_Button:IsHighlightLocked() return ST(self).highlightLocked == true end
function M_Button:SetMotionScriptsWhileDisabled(on) ST(self).motionWhileDisabled = on and true or false end
function M_Button:GetMotionScriptsWhileDisabled() return ST(self).motionWhileDisabled == true end
function M_Button:SetPushedTextOffset(x, y) ST(self).pushedOffset = { x, y } end
function M_Button:GetPushedTextOffset() local p = ST(self).pushedOffset or { 1.5, -1.5 } return p[1], p[2] end
local function buttonFontString(self, st, create)
    if st.FontString then return st.FontString end
    if not create then return nil end
    local fs = newRegion("FontString", self, nil, "OVERLAY", 0, { isFontString = true })
    local fst = S[fs]
    fst.fontObject = st.normalFont
    fst.points = { { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 } }
    st.FontString = fs
    return fs
end
function M_Button:SetFontString(fs)
    local st = ST(self)
    if not (S[fs] and S[fs].isFontString) then error("Usage: Button:SetFontString(fontString)", 2) end
    st.FontString = fs
end
function M_Button:GetFontString() return ST(self).FontString end
function M_Button:SetText(text)
    local st = ST(self)
    local fs = buttonFontString(self, st, true)
    local fst = S[fs]
    if not fontOf(fst) then
        MOCK.Warn("font", "Button:SetText() with no NormalFontObject/FontString font (client behaviour unverified)", 2)
        fst.fontObject = rawget(_G, "GameFontNormal")
    end
    setText(fs, fst, text, "SetText")
end
function M_Button:SetFormattedText(fmt, ...) self:SetText(string.format(fmt, ...)) end
function M_Button:GetText() local st = ST(self) return st.FontString and S[st.FontString].text or nil end
function M_Button:GetTextWidth() local st = ST(self) return st.FontString and st.FontString:GetStringWidth() or 0 end
function M_Button:GetTextHeight() local st = ST(self) return st.FontString and st.FontString:GetStringHeight() or 0 end
local function fontObjSlot(field)
    return function(self, fo)
        local st = ST(self)
        if type(fo) == "string" then fo = rawget(_G, fo) end
        if fo ~= nil and not (S[fo] and S[fo].isFontObject) then error("Usage: Button:Set" .. field .. "(fontObject)", 2) end
        st[field] = fo
        if field == "normalFont" and st.FontString then S[st.FontString].fontObject = fo end
    end
end
M_Button.SetNormalFontObject = fontObjSlot("normalFont")
M_Button.SetHighlightFontObject = fontObjSlot("highlightFont")
M_Button.SetDisabledFontObject = fontObjSlot("disabledFont")
function M_Button:GetNormalFontObject() return ST(self).normalFont end
function M_Button:GetHighlightFontObject() return ST(self).highlightFont end
function M_Button:GetDisabledFontObject() return ST(self).disabledFont end

local M_CheckButton = {}
function M_CheckButton:SetChecked(on) ST(self).checked = on and true or false end
function M_CheckButton:GetChecked() return ST(self).checked == true end
function M_CheckButton:SetCheckedTexture(a) buttonTexture(self, ST(self), "CheckedTexture", a, "ARTWORK") end
function M_CheckButton:GetCheckedTexture() return ST(self).CheckedTexture end
function M_CheckButton:SetDisabledCheckedTexture(a) buttonTexture(self, ST(self), "DisabledCheckedTexture", a, "ARTWORK") end
function M_CheckButton:GetDisabledCheckedTexture() return ST(self).DisabledCheckedTexture end

-------------------------------------------------------------------------------
-- EditBox
-------------------------------------------------------------------------------
local M_EditBox = {}
local function utf8len(s)
    local n = 0
    for i = 1, #s do
        local b = byte(s, i)
        if b < 128 or b >= 192 then n = n + 1 end
    end
    return n
end
local function utf8trim(s, maxChars)
    if maxChars <= 0 then return s end
    local n = 0
    for i = 1, #s do
        local b = byte(s, i)
        if b < 128 or b >= 192 then
            n = n + 1
            if n > maxChars then return sub(s, 1, i - 1) end
        end
    end
    return s
end
MOCK.utf8len = utf8len

function MOCK.ClearFocus(obj)
    local st = S[obj]
    if not st.focus then return end
    st.focus = false
    if MOCK.focus == obj then MOCK.focus = nil end
    runScript(obj, "OnEditFocusLost")
end
function MOCK.SetFocus(obj)
    local st = S[obj]
    if st.focus then return end
    if MOCK.focus and MOCK.focus ~= obj then MOCK.ClearFocus(MOCK.focus) end
    st.focus = true
    MOCK.focus = obj
    runScript(obj, "OnEditFocusGained")
end

local function ebSetText(self, st, text, userInput)
    if text == nil then text = "" end
    if isNum(text) then text = tostring(text) end
    if type(text) ~= "string" and not isSecret(text) then
        error(format("bad argument #1 to 'SetText' (string expected, got %s)", type(text)), 3)
    end
    if not isSecret(text) then
        if (st.maxLetters or 0) > 0 then text = utf8trim(text, st.maxLetters) end
        if (st.maxBytes or 0) > 0 and #text > st.maxBytes then text = sub(text, 1, st.maxBytes) end
        st.cursor = utf8len(text)
    end
    if not fontOf(st) then MOCK.Warn("font", "EditBox:SetText() before a font was set", 3) end
    st.text = text
    dirty()
    runScript(self, "OnTextChanged", userInput and true or false)
    if not userInput then runScript(self, "OnTextSet") end
end
MOCK.EditBoxSetText = ebSetText
function M_EditBox:SetText(text) local st = ST(self) ebSetText(self, st, text, false) end
function M_EditBox:GetText() local st = ST(self) return st.text or "" end
function M_EditBox:Insert(text)
    local st = ST(self)
    if type(text) ~= "string" then argErr("Insert", 1, "string", text) end
    ebSetText(self, st, textOf(st) .. text, true)
end
function M_EditBox:SetFocus() ST(self) MOCK.SetFocus(self) end
function M_EditBox:ClearFocus() ST(self) MOCK.ClearFocus(self) end
function M_EditBox:HasFocus() return ST(self).focus == true end
function M_EditBox:SetAutoFocus(on) ST(self).autoFocus = on and true or false end
function M_EditBox:IsAutoFocus() return ST(self).autoFocus == true end
function M_EditBox:SetMaxLetters(n)
    local st = ST(self)
    if not isNum(n) then argErr("SetMaxLetters", 1, "number", n) end
    st.maxLetters = n
end
function M_EditBox:GetMaxLetters() return ST(self).maxLetters or 0 end
function M_EditBox:SetMaxBytes(n) ST(self).maxBytes = tonumber(n) or 0 end
function M_EditBox:GetMaxBytes() return ST(self).maxBytes or 0 end
function M_EditBox:SetNumeric(on) ST(self).numeric = on and true or false end
function M_EditBox:IsNumeric() return ST(self).numeric == true end
function M_EditBox:SetNumber(n) local st = ST(self) ebSetText(self, st, tostring(tonumber(n) or 0), false) end
function M_EditBox:GetNumber() return tonumber(ST(self).text or "") or 0 end
function M_EditBox:SetMultiLine(on) ST(self).multiLine = on and true or false end
function M_EditBox:IsMultiLine() return ST(self).multiLine == true end
function M_EditBox:SetTextInsets(l, r, t, b)
    local st = ST(self)
    for i, v in ipairs({ l, r, t, b }) do if not isNum(v) then argErr("SetTextInsets", i, "number", v) end end
    st.insets = { l, r, t, b }
end
function M_EditBox:GetTextInsets() local i = ST(self).insets or { 0, 0, 0, 0 } return i[1], i[2], i[3], i[4] end
function M_EditBox:HighlightText(a, b) ST(self).highlight = { a or 0, b or -1 } end
function M_EditBox:ClearHighlightText() ST(self).highlight = nil end
function M_EditBox:SetCursorPosition(n) ST(self).cursor = tonumber(n) or 0 end
function M_EditBox:GetCursorPosition() return ST(self).cursor or 0 end
function M_EditBox:GetUTF8CursorPosition() return ST(self).cursor or 0 end
function M_EditBox:GetNumLetters() local st = ST(self) return utf8len(textOf(st)) end
function M_EditBox:SetPassword(on) ST(self).password = on end
function M_EditBox:IsPassword() return ST(self).password == true end
function M_EditBox:SetBlinkSpeed() ST(self) end
function M_EditBox:SetHistoryLines(n) ST(self).historyLines = n end
function M_EditBox:GetHistoryLines() return ST(self).historyLines or 0 end
function M_EditBox:AddHistoryLine(l) local st = ST(self) st.history = st.history or {} st.history[#st.history + 1] = l end
function M_EditBox:ClearHistory() ST(self).history = {} end
function M_EditBox:SetCountInvisibleLetters(on) ST(self).countInvisible = on end
function M_EditBox:Enable() ST(self).enabled = true end
function M_EditBox:Disable() local st = ST(self) st.enabled = false if st.focus then MOCK.ClearFocus(self) end end
function M_EditBox:SetEnabled(on) if on then self:Enable() else self:Disable() end end
function M_EditBox:IsEnabled() return ST(self).enabled ~= false end
function M_EditBox:SetAltArrowKeyMode(on) ST(self).altArrow = on end
function M_EditBox:GetAltArrowKeyMode() return ST(self).altArrow == true end
function M_EditBox:SetHighlightColor(r, g, b, a) ST(self).hlColor = { r, g, b, a } end
function M_EditBox:GetHighlightColor() local c = ST(self).hlColor or { 0.5, 0.5, 0.5, 1 } return c[1], c[2], c[3], c[4] end
function M_EditBox:SetVisibleTextByteLimit(n) ST(self).visibleLimit = n end
function M_EditBox:GetVisibleTextByteLimit() return ST(self).visibleLimit or 0 end
function M_EditBox:IsInIMECompositionMode() ST(self) return false end
function M_EditBox:GetInputLanguage() ST(self) return "ROMAN" end
function M_EditBox:ToggleInputLanguage() ST(self) end

-------------------------------------------------------------------------------
-- ScrollFrame
-------------------------------------------------------------------------------
local M_ScrollFrame = {}
function M_ScrollFrame:SetScrollChild(child)
    local st = ST(self)
    if not (S[child] and S[child].isFrame) then error("Usage: ScrollFrame:SetScrollChild(frame)", 2) end
    if st.scrollChild and st.scrollChild ~= child then S[st.scrollChild].scrollFrame = nil end
    st.scrollChild = child
    local cst = S[child]
    if cst.parent ~= self then setParent(child, self) end
    cst.scrollFrame = self
    dirty()
end
function M_ScrollFrame:GetScrollChild() return ST(self).scrollChild end
local function scrollRange(self, st, horiz)
    local c = st.scrollChild
    if not c then return 0 end
    local cw, ch = sizeOf(c)
    local w, h = sizeOf(self)
    if horiz then return max(0, cw - w) end
    return max(0, ch - h)
end
function M_ScrollFrame:SetVerticalScroll(v)
    local st = ST(self)
    if not isNum(v) then argErr("SetVerticalScroll", 1, "number", v) end
    st.vscroll = v
    dirty()
    runScript(self, "OnVerticalScroll", v)
end
function M_ScrollFrame:GetVerticalScroll() return ST(self).vscroll or 0 end
function M_ScrollFrame:SetHorizontalScroll(v)
    local st = ST(self)
    if not isNum(v) then argErr("SetHorizontalScroll", 1, "number", v) end
    st.hscroll = v
    dirty()
    runScript(self, "OnHorizontalScroll", v)
end
function M_ScrollFrame:GetHorizontalScroll() return ST(self).hscroll or 0 end
function M_ScrollFrame:GetVerticalScrollRange() local st = ST(self) return scrollRange(self, st, false) end
function M_ScrollFrame:GetHorizontalScrollRange() local st = ST(self) return scrollRange(self, st, true) end
function M_ScrollFrame:UpdateScrollChildRect() ST(self) dirty() end
MOCK.ScrollRange = scrollRange

-------------------------------------------------------------------------------
-- Slider / StatusBar (value widgets)
-------------------------------------------------------------------------------
local M_Value = {}
function M_Value:SetMinMaxValues(lo, hi)
    local st = ST(self)
    if not isNum(lo) or not isNum(hi) then error("Usage: " .. st.otype .. ":SetMinMaxValues(min, max)", 2) end
    if lo > hi then error(st.otype .. ":SetMinMaxValues(): min must be <= max", 2) end
    local changed = st.minV ~= lo or st.maxV ~= hi
    st.minV, st.maxV = lo, hi
    if changed then runScript(self, "OnMinMaxChanged", lo, hi) end
    if st.value then
        local v = max(lo, min(hi, st.value))
        if v ~= st.value then st.value = v; runScript(self, "OnValueChanged", v, false) end
    end
end
function M_Value:GetMinMaxValues() local st = ST(self) return st.minV or 0, st.maxV or 0 end
function M_Value:SetValue(v, treatAsMouse)
    local st = ST(self)
    if not isNum(v) then argErr("SetValue", 1, "number", v) end
    v = max(st.minV or 0, min(st.maxV or 0, v))
    if st.step and st.step > 0 and st.otype == "Slider" then v = (st.minV or 0) + floor((v - (st.minV or 0)) / st.step + 0.5) * st.step end
    if v ~= st.value then
        st.value = v
        runScript(self, "OnValueChanged", v, treatAsMouse and true or false)
    end
end
function M_Value:GetValue() return ST(self).value or 0 end
function M_Value:SetOrientation(o) ST(self).orientation = o end
function M_Value:GetOrientation() return ST(self).orientation or "HORIZONTAL" end

local M_Slider = {}
function M_Slider:SetValueStep(s) ST(self).step = tonumber(s) or 0 end
function M_Slider:GetValueStep() return ST(self).step or 0 end
function M_Slider:SetStepsPerPage(n) ST(self).stepsPerPage = n end
function M_Slider:GetStepsPerPage() return ST(self).stepsPerPage or 1 end
function M_Slider:SetObeyStepOnDrag(on) ST(self).obeyStep = on end
function M_Slider:GetObeyStepOnDrag() return ST(self).obeyStep == true end
function M_Slider:SetThumbTexture(a) buttonTexture(self, ST(self), "ThumbTexture", a, "ARTWORK") S[ST(self).ThumbTexture].points = {} end
function M_Slider:GetThumbTexture() return ST(self).ThumbTexture end
function M_Slider:Enable() ST(self).enabled = true end
function M_Slider:Disable() ST(self).enabled = false end
function M_Slider:SetEnabled(on) ST(self).enabled = on and true or false end
function M_Slider:IsEnabled() return ST(self).enabled ~= false end

local M_StatusBar = {}
function M_StatusBar:SetStatusBarTexture(a)
    local st = ST(self)
    buttonTexture(self, st, "BarTexture", a, "ARTWORK")
    S[st.BarTexture].statusBar = self
end
function M_StatusBar:GetStatusBarTexture() return ST(self).BarTexture end
function M_StatusBar:SetStatusBarColor(r, g, b, a)
    local st = ST(self)
    st.barColor = { r, g, b, a or 1 }
    if st.BarTexture then S[st.BarTexture].vc = { r, g, b, a or 1 } end
end
function M_StatusBar:GetStatusBarColor() local c = ST(self).barColor or { 1, 1, 1, 1 } return c[1], c[2], c[3], c[4] end
function M_StatusBar:SetReverseFill(on) ST(self).reverseFill = on end
function M_StatusBar:GetReverseFill() return ST(self).reverseFill == true end
function M_StatusBar:SetFillStyle(s) ST(self).fillStyle = s end
function M_StatusBar:GetFillStyle() return ST(self).fillStyle or "STANDARD" end
function M_StatusBar:SetRotatesTexture(on) ST(self).rotates = on end
function M_StatusBar:GetRotatesTexture() return ST(self).rotates == true end
function M_StatusBar:SetStatusBarDesaturated(on) ST(self).barDesat = on end

-------------------------------------------------------------------------------
-- Cooldown
-------------------------------------------------------------------------------
local M_Cooldown = {}
function M_Cooldown:SetCooldown(start, duration, modRate)
    local st = ST(self)
    if not isNum(start) or not isNum(duration) then error("Usage: Cooldown:SetCooldown(start, duration[, modRate])", 2) end
    st.cdStart, st.cdDuration = start, duration
    MOCK.cooldowns = MOCK.cooldowns or {}
    MOCK.cooldowns[self] = true
end
function M_Cooldown:SetCooldownDuration(d) local st = ST(self) st.cdStart, st.cdDuration = MOCK.uptime, d end
function M_Cooldown:GetCooldownTimes() local st = ST(self) return (st.cdStart or 0) * 1000, (st.cdDuration or 0) * 1000 end
function M_Cooldown:GetCooldownDuration() return (ST(self).cdDuration or 0) * 1000 end
function M_Cooldown:Clear() local st = ST(self) st.cdStart, st.cdDuration = nil, nil end
function M_Cooldown:Pause() ST(self).cdPaused = true end
function M_Cooldown:Resume() ST(self).cdPaused = false end
function M_Cooldown:IsPaused() return ST(self).cdPaused == true end
for _, k in ipairs({ "SetSwipeColor", "SetSwipeTexture", "SetDrawEdge", "SetDrawSwipe", "SetDrawBling", "SetReverse",
    "SetHideCountdownNumbers", "SetEdgeTexture", "SetBlingTexture", "SetUseCircularEdge", "SetCountdownFont",
    "SetCountdownAbbrevThreshold", "SetEdgeScale", "SetTexCoordRange", "SetRotation", "SetDrawSwipeBling" }) do
    M_Cooldown[k] = function(self, ...) ST(self)[k] = { ... } end
end
function M_Cooldown:GetReverse() return ST(self).SetReverse ~= nil and ST(self).SetReverse[1] == true end
function M_Cooldown:GetDrawEdge() local v = ST(self).SetDrawEdge return v and v[1] == true end
function M_Cooldown:GetDrawSwipe() local v = ST(self).SetDrawSwipe return v == nil or v[1] == true end

-------------------------------------------------------------------------------
-- MessageFrame (minimal: AddMessage/Clear)
-------------------------------------------------------------------------------
local M_MessageFrame = {}
function M_MessageFrame:AddMessage(text, r, g, b, ...)
    local st = ST(self)
    st.messages = st.messages or {}
    st.messages[#st.messages + 1] = { text = text, r = r, g = g, b = b }
    if MOCK.OnChatFrameMessage then MOCK.OnChatFrameMessage(self, text, r, g, b) end
end
function M_MessageFrame:Clear() ST(self).messages = {} end
function M_MessageFrame:GetNumMessages() return #(ST(self).messages or {}) end
function M_MessageFrame:SetFading(on) ST(self).fading = on end
function M_MessageFrame:SetTimeVisible(n) ST(self).timeVisible = n end
function M_MessageFrame:SetMaxLines(n) ST(self).maxMsg = n end
function M_MessageFrame:SetInsertMode(m) ST(self).insertMode = m end
function M_MessageFrame:ScrollToBottom() ST(self) end

-------------------------------------------------------------------------------
-- Type table
-------------------------------------------------------------------------------
local FRAME_MIXINS = { M_Object, M_ScriptObject, M_ScriptRegion, M_Alpha, M_Frame, M_FrameCreate }
local function frameType(name, isa, extra, scripts)
    local mixins = {}
    for _, m in ipairs(FRAME_MIXINS) do mixins[#mixins + 1] = m end
    for _, m in ipairs(extra or {}) do mixins[#mixins + 1] = m end
    local sc = { SCRIPTS_FRAME }
    for _, s in ipairs(scripts or {}) do sc[#sc + 1] = s end
    local isaList = { "Object", "ScriptObject", "ScriptRegion", "Region", "Frame" }
    for _, n in ipairs(isa or {}) do isaList[#isaList + 1] = n end
    return defineType(name, isaList, mixins, sc)
end

frameType("Frame")
frameType("EventFrame")
frameType("Button", {}, { M_Button }, { SCRIPTS_BUTTON })
frameType("DropdownButton", { "Button" }, { M_Button }, { SCRIPTS_BUTTON })
frameType("CheckButton", { "Button" }, { M_Button, M_CheckButton }, { SCRIPTS_BUTTON })
frameType("EditBox", {}, { M_FontInstance, M_EditBox }, { SCRIPTS_EDITBOX })
frameType("ScrollFrame", {}, { M_ScrollFrame }, { SCRIPTS_SCROLL })
frameType("Slider", {}, { M_Value, M_Slider }, { SCRIPTS_VALUE })
frameType("StatusBar", {}, { M_Value, M_StatusBar }, { SCRIPTS_VALUE })
frameType("Cooldown", {}, { M_Cooldown }, { SCRIPTS_COOLDOWN })
frameType("MessageFrame", {}, { M_FontInstance, M_MessageFrame }, { SCRIPTS_MESSAGE })
frameType("ScrollingMessageFrame", { "MessageFrame" }, { M_FontInstance, M_MessageFrame }, { SCRIPTS_MESSAGE, SCRIPTS_SCROLL })
frameType("GameTooltip", {}, {}, { SCRIPTS_TOOLTIP })   -- methods added by wow_mock_api.lua
frameType("Minimap", {}, {}, {})                          -- methods added by wow_mock_api.lua
MOCK.DefineFrameType = frameType
MOCK.SCRIPTS = { FRAME = SCRIPTS_FRAME, BUTTON = SCRIPTS_BUTTON, TOOLTIP = SCRIPTS_TOOLTIP }

local REGION_MIXINS = { M_Object, M_ScriptObject, M_ScriptRegion, M_Alpha, M_Region }
local function regionType(name, isa, extra)
    local mixins = {}
    for _, m in ipairs(REGION_MIXINS) do mixins[#mixins + 1] = m end
    for _, m in ipairs(extra) do mixins[#mixins + 1] = m end
    local isaList = { "Object", "ScriptObject", "ScriptRegion", "Region" }
    for _, n in ipairs(isa) do isaList[#isaList + 1] = n end
    return defineType(name, isaList, mixins, { SCRIPTS_REGION })
end
regionType("Texture", { "TextureBase" }, { M_TextureBase, M_TextureMask })
regionType("MaskTexture", { "TextureBase" }, { M_TextureBase })
regionType("Line", { "TextureBase" }, { M_TextureBase, M_TextureMask, M_Line })
regionType("FontString", { "FontInstance" }, { M_FontInstance, M_FontString })

-- Font objects (CreateFont): FontInstance + a few Object methods
local M_Font = {}
function M_Font:CopyFontObject(src)
    local st = ST(self)
    if type(src) == "string" then src = rawget(_G, src) end
    local sst = S[src]
    if not (sst and sst.isFontObject) then error("Usage: Font:CopyFontObject(fontObject)", 2) end
    for _, k in ipairs({ "font", "textColor", "shadowColor", "shadowOffset", "justifyH", "justifyV", "spacing" }) do
        st[k] = sst[k] or resolveFontField(sst, k)
    end
end
function M_Font:SetAlpha(a) ST(self).alpha = a end
function M_Font:GetAlpha() return ST(self).alpha or 1 end
defineType("Font", { "Object", "FontInstance" }, { M_Object, M_FontInstance, M_Font }, {})

MOCK.M = { Object = M_Object, ScriptObject = M_ScriptObject, ScriptRegion = M_ScriptRegion, Frame = M_Frame,
    Button = M_Button, EditBox = M_EditBox, FontInstance = M_FontInstance, FontString = M_FontString,
    TextureBase = M_TextureBase }

-------------------------------------------------------------------------------
-- Frame construction
-------------------------------------------------------------------------------
local FRAME_TYPES = {}
for _, n in ipairs({ "Frame", "EventFrame", "Button", "DropdownButton", "CheckButton", "EditBox", "ScrollFrame", "Slider",
    "StatusBar", "Cooldown", "MessageFrame", "ScrollingMessageFrame", "GameTooltip" }) do
    FRAME_TYPES[lower(n)] = n
end
MOCK.FRAME_TYPES = FRAME_TYPES

local function newFrame(typeName, name, parent, level)
    local st = { isFrame = true, isRegionLike = true, shown = true, children = {}, regions = {} }
    st.where = MOCK.addonWhere((level or 2) + 1)
    if typeName == "Button" or typeName == "CheckButton" or typeName == "DropdownButton" then
        st.enabled = true
        st.mouse = true
        st.clicks = { LeftButtonUp = true }
        st.isButton = true
        st.isCheckButton = typeName == "CheckButton"
    elseif typeName == "EditBox" then
        st.mouse = true
        st.isEditBox = true
        st.autoFocus = true
        st.text = ""
        st.enabled = true
    elseif typeName == "Slider" then
        st.mouse = true
        st.minV, st.maxV, st.value = 0, 0, 0
    elseif typeName == "StatusBar" then
        st.minV, st.maxV, st.value = 0, 1, 0
    elseif typeName == "ScrollFrame" then
        st.vscroll, st.hscroll = 0, 0
    end
    local obj = newObject(typeName, st)
    if name then
        local pname = parent and S[parent] and S[parent].name
        name = gsub(name, "%$[Pp]arent", pname or "")
        st.name = name
        rawset(_G, name, obj)
    end
    setParent(obj, parent)
    if typeName == "ScrollFrame" then osAdd(sizeSet, obj) end
    return obj
end
MOCK.NewFrame = newFrame

MOCK.templates = {}       -- name -> function(frame, st, frameType)  (filled by wow_mock_api.lua)
MOCK.templateTypes = {}   -- name -> required base type (optional)

function MOCK.CreateFrame(frameType, name, parent, templates, id)
    if type(frameType) ~= "string" then error("CreateFrame(): Usage: CreateFrame(\"frameType\"[, \"name\"][, parent][, \"template\"][, id])", 2) end
    local tname = FRAME_TYPES[lower(frameType)]
    if not tname then error(format("CreateFrame(): Unknown frame type '%s'", frameType), 2) end
    if name ~= nil and type(name) ~= "string" then error("CreateFrame(): name must be a string or nil", 2) end
    if name == "" then name = nil end
    if type(parent) == "string" then
        local g = rawget(_G, parent)
        if not (g and S[g] and S[g].isFrame) then error(format("CreateFrame(): Couldn't find frame parent '%s'", parent), 2) end
        parent = g
    end
    if parent ~= nil and not (S[parent] and S[parent].isFrame) then
        error("CreateFrame(): parent must be a frame (got " .. (isSecret(parent) and "secret" or type(parent)) .. ")", 2)
    end
    local tlist = {}
    if templates ~= nil then
        if type(templates) ~= "string" then error("CreateFrame(): template must be a string", 2) end
        for t in R.gmatch(templates, "[^,%s]+") do
            if not MOCK.templates[t] then error(format("CreateFrame(): Couldn't find inherited node \"%s\"", t), 2) end
            tlist[#tlist + 1] = t
        end
    end
    local f = newFrame(tname, name, parent, 2)
    for _, t in ipairs(tlist) do MOCK.templates[t](f, S[f], tname) end
    if id ~= nil and isNum(id) then S[f].frameID = id end
    return f
end

-------------------------------------------------------------------------------
-- Becoming visible: autofocus edit boxes, raise toplevel frames
-------------------------------------------------------------------------------
onBecameVisible = function(obj, st)
    if st.toplevel then raise(obj) end
    if st.isEditBox and st.autoFocus and st.enabled ~= false then MOCK.SetFocus(obj) end
end

-------------------------------------------------------------------------------
-- Layout pass: fires OnSizeChanged / OnScrollRangeChanged for visible frames
-------------------------------------------------------------------------------
local lastPassVer = -1
function MOCK.LayoutPass()
    -- sizes and scroll ranges only change when something dirtied the layout
    if lastPassVer == layoutVer then return end
    local settled = false
    for _ = 1, 6 do
        local changed = false
        for _, obj in ipairs(osSnapshot(sizeSet)) do
            local st = S[obj]
            if isVisible(obj) then
                local l = rectOf(obj)
                if l then
                    local w, h = sizeOf(obj)
                    if w ~= st.lastW or h ~= st.lastH then
                        st.lastW, st.lastH = w, h
                        changed = true
                        runScript(obj, "OnSizeChanged", w, h)
                    end
                    if st.otype == "ScrollFrame" then
                        local xr, yr = scrollRange(obj, st, true), scrollRange(obj, st, false)
                        if xr ~= st.lastXR or yr ~= st.lastYR then
                            st.lastXR, st.lastYR = xr, yr
                            changed = true
                            runScript(obj, "OnScrollRangeChanged", xr, yr)
                        end
                    end
                end
            end
        end
        if not changed then settled = true break end
    end
    if settled then lastPassVer = layoutVer end
end

--- Depth-first walk of a frame subtree (creation order). fn(obj, st) -> false prunes.
function MOCK.Walk(root, fn)
    local function rec(o)
        local st = S[o]
        if fn(o, st) == false then return end
        if st.regions then for _, r in ipairs(st.regions) do fn(r, S[r]) end end
        if st.children then
            local snap = {}
            for i, c in ipairs(st.children) do snap[i] = c end
            for _, c in ipairs(snap) do rec(c) end
        end
    end
    rec(root)
end
