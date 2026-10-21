--[[ tools/harness/wow_mock_anim.lua  --  AnimationGroup / Animation, the per-tick driver
     (timers, OnUpdate of visible frames, animations, cooldowns, layout pass) and the
     "user input" helpers run.py's fuzzer drives (click, hover, type, wheel, Escape).

     Animations advance on the virtual clock only while their owning region is visible.
     Alpha animations override the target's alpha while playing (absolute from/to, as on
     the client); Translation offsets are applied to the rendered position only. ]]

local MOCK = ...
local R = MOCK.R
local type, pairs, ipairs, select, tostring, tonumber = R.type, R.pairs, R.ipairs, R.select, R.tostring, R.tonumber
local error, setmetatable, rawget = R.error, R.setmetatable, R.rawget
local floor, max, min = R.floor, R.max, R.min
local format, upper, lower = R.format, R.upper, R.lower
local tinsert, sort = R.insert, R.sort
local S, ST = MOCK.S, MOCK.ST
local runScript, Protect = MOCK.RunScript, MOCK.Protect

local playing = MOCK.OrderedSet()
MOCK.playingGroups = playing

local function isNum(v) return type(v) == "number" and v == v end

-------------------------------------------------------------------------------
-- Smoothing
-------------------------------------------------------------------------------
local SMOOTH = {
    NONE = function(p) return p end,
    IN = function(p) return p * p end,
    OUT = function(p) return 1 - (1 - p) * (1 - p) end,
    IN_OUT = function(p) if p < 0.5 then return 2 * p * p end return 1 - 2 * (1 - p) * (1 - p) end,
    OUT_IN = function(p) if p < 0.5 then return 0.5 - 2 * (0.5 - p) * (0.5 - p) end return 0.5 + 2 * (p - 0.5) * (p - 0.5) end,
}

-------------------------------------------------------------------------------
-- Timeline helpers
-------------------------------------------------------------------------------
local function timeline(gst)
    local phases = {}
    for _, a in ipairs(gst.anims) do
        local ast = S[a]
        local o = ast.order or 1
        local d = (ast.startDelay or 0) + (ast.duration or 0) + (ast.endDelay or 0)
        phases[o] = max(phases[o] or 0, d)
    end
    local orders = {}
    for o in pairs(phases) do orders[#orders + 1] = o end
    sort(orders)
    local starts, t = {}, 0
    for _, o in ipairs(orders) do starts[o] = t; t = t + phases[o] end
    return t, starts
end

local function targetOf(ast, gst)
    if ast.target then return ast.target end
    local owner = gst.owner
    if ast.childKey and type(owner) == "table" then
        local c = rawget(owner, ast.childKey)
        if c and S[c] then return c end
    end
    if ast.targetKey and type(owner) == "table" then
        local c = rawget(owner, ast.targetKey)
        if c and S[c] then return c end
    end
    if ast.targetName then
        local c = rawget(_G, ast.targetName)
        if c and S[c] then return c end
    end
    return owner
end

local function clearFx(gst)
    for _, a in ipairs(gst.anims) do
        local tgt = targetOf(S[a], gst)
        if tgt and S[tgt] then S[tgt].fx = nil end
    end
end

local function applyAt(gst, elapsed, starts)
    for _, a in ipairs(gst.anims) do
        local ast = S[a]
        local tgt = targetOf(ast, gst)
        local tst = tgt and S[tgt]
        if tst then
            local t0 = (starts[ast.order or 1] or 0) + (ast.startDelay or 0)
            local local_ = elapsed - t0
            local dur = ast.duration or 0
            if local_ >= 0 then
                local p = dur > 0 and min(1, local_ / dur) or 1
                if gst.reverse then p = 1 - p end
                p = (SMOOTH[ast.smoothing or "NONE"] or SMOOTH.NONE)(p)
                ast.progress = p
                local fx = tst.fx or {}
                tst.fx = fx
                local k = ast.kind
                if k == "Alpha" then
                    local from, to = ast.fromAlpha or 0, ast.toAlpha or 0
                    fx.alpha = max(0, min(1, from + (to - from) * p))
                elseif k == "Translation" then
                    fx.dx = (fx.dx or 0) + (ast.offX or 0) * p
                    fx.dy = (fx.dy or 0) + (ast.offY or 0) * p
                elseif k == "Path" then
                    local pts = ast.controlPoints or {}
                    if #pts > 0 then
                        local seg = p * #pts
                        local i = min(#pts, floor(seg) + 1)
                        local prev = i > 1 and S[pts[i - 1]] or { offX = 0, offY = 0 }
                        local cur = S[pts[i]]
                        local f = seg - (i - 1)
                        fx.dx = (fx.dx or 0) + (prev.offX or 0) + ((cur.offX or 0) - (prev.offX or 0)) * f
                        fx.dy = (fx.dy or 0) + (prev.offY or 0) + ((cur.offY or 0) - (prev.offY or 0)) * f
                    end
                elseif k == "Scale" then
                    local fx0, fy0 = ast.fromX or 1, ast.fromY or 1
                    local tx, ty = ast.toX or 1, ast.toY or 1
                    fx.sx = (fx.sx or 1) * (fx0 + (tx - fx0) * p)
                    fx.sy = (fx.sy or 1) * (fy0 + (ty - fy0) * p)
                elseif k == "Rotation" then
                    fx.rot = (fx.rot or 0) + (ast.degrees or 0) * p
                elseif k == "VertexColor" then
                    local c1, c2 = ast.startColor or { 1, 1, 1, 1 }, ast.endColor or { 1, 1, 1, 1 }
                    fx.vc = { c1[1] + (c2[1] - c1[1]) * p, c1[2] + (c2[2] - c1[2]) * p, c1[3] + (c2[3] - c1[3]) * p, (c1[4] or 1) + ((c2[4] or 1) - (c1[4] or 1)) * p }
                end
            end
        end
    end
end

local function finishGroup(g, gst, requested)
    gst.isPlaying, gst.paused, gst.done = false, false, true
    MOCK.osRemove(playing, g)
    if gst.toFinalAlpha then
        for _, a in ipairs(gst.anims) do
            local ast = S[a]
            if ast.kind == "Alpha" then
                local tgt = targetOf(ast, gst)
                if tgt and S[tgt] then S[tgt].alpha = gst.reverse and (ast.fromAlpha or 0) or (ast.toAlpha or 0) end
            end
        end
    end
    clearFx(gst)
    for _, a in ipairs(gst.anims) do runScript(a, "OnFinished", requested and true or false) end
    runScript(g, "OnFinished", requested and true or false)
end

local function ownerVisible(gst)
    local o = gst.owner
    return o and S[o] and MOCK.IsVisible(o)
end

local function tickGroup(g, gst, dt)
    if gst.paused or not ownerVisible(gst) then return end
    local total, starts = timeline(gst)
    gst.elapsed = (gst.elapsed or 0) + dt * (gst.speed or 1)
    runScript(g, "OnUpdate", dt)
    for _, a in ipairs(gst.anims) do
        if S[a].scripts.OnUpdate then runScript(a, "OnUpdate", dt) end
    end
    if gst.elapsed >= total then
        local loop = gst.looping or "NONE"
        if loop == "REPEAT" and total > 0 then
            gst.elapsed = gst.elapsed % total
            runScript(g, "OnLoop", "FORWARD")
        elseif loop == "BOUNCE" and total > 0 then
            gst.elapsed = gst.elapsed % total
            gst.reverse = not gst.reverse
            runScript(g, "OnLoop", gst.reverse and "REVERSE" or "FORWARD")
        else
            applyAt(gst, total, starts)
            finishGroup(g, gst, false)
            return
        end
    end
    clearFx(gst)
    applyAt(gst, gst.elapsed, starts)
end

-------------------------------------------------------------------------------
-- AnimationGroup methods
-------------------------------------------------------------------------------
local M_Group = {}
function M_Group:Play(reverse, offset)
    local gst = ST(self)
    if gst.isPlaying and not gst.paused then return end
    if gst.paused then gst.paused = false; runScript(self, "OnPlay") return end
    gst.isPlaying, gst.done = true, false
    gst.elapsed = tonumber(offset) or 0
    gst.reverse = reverse and true or false
    MOCK.osAdd(playing, self)
    runScript(self, "OnPlay")
    for _, a in ipairs(gst.anims) do runScript(a, "OnPlay") end
    local _, starts = timeline(gst)
    applyAt(gst, gst.elapsed, starts)
end
function M_Group:Restart(reverse, offset)
    local gst = ST(self)
    gst.isPlaying, gst.paused = false, false
    MOCK.osRemove(playing, self)
    clearFx(gst)
    self:Play(reverse, offset)
end
function M_Group:Stop()
    local gst = ST(self)
    if not gst.isPlaying then return end
    gst.isPlaying, gst.paused = false, false
    MOCK.osRemove(playing, self)
    clearFx(gst)
    for _, a in ipairs(gst.anims) do runScript(a, "OnStop", true) end
    runScript(self, "OnStop", true)
end
function M_Group:Pause()
    local gst = ST(self)
    if gst.isPlaying then gst.paused = true; runScript(self, "OnPause") end
end
function M_Group:Finish()
    local gst = ST(self)
    if not gst.isPlaying then return end
    local total, starts = timeline(gst)
    applyAt(gst, total, starts)
    finishGroup(self, gst, true)
end
function M_Group:IsPlaying() local gst = ST(self) return gst.isPlaying == true and not gst.paused end
function M_Group:IsPaused() return ST(self).paused == true end
function M_Group:IsDone() return ST(self).done == true end
function M_Group:IsPendingFinish() ST(self) return false end
function M_Group:IsReverse() return ST(self).reverse == true end
function M_Group:SetLooping(l)
    local gst = ST(self)
    if type(l) ~= "string" or (upper(l) ~= "NONE" and upper(l) ~= "REPEAT" and upper(l) ~= "BOUNCE") then
        error("Usage: AnimationGroup:SetLooping(\"NONE\"|\"REPEAT\"|\"BOUNCE\")", 2)
    end
    gst.looping = upper(l)
end
function M_Group:GetLooping() return ST(self).looping or "NONE" end
function M_Group:GetLoopState() local gst = ST(self) return gst.reverse and "REVERSE" or "FORWARD" end
function M_Group:GetDuration() local gst = ST(self) local t = timeline(gst) return t end
function M_Group:GetElapsed() return ST(self).elapsed or 0 end
function M_Group:GetProgress()
    local gst = ST(self)
    local t = timeline(gst)
    if t <= 0 then return 0 end
    return min(1, (gst.elapsed or 0) / t)
end
function M_Group:SetToFinalAlpha(on) ST(self).toFinalAlpha = on and true or false end
function M_Group:IsSetToFinalAlpha() return ST(self).toFinalAlpha == true end
function M_Group:SetPlaying(on) if on then self:Play() else self:Stop() end end
function M_Group:SetAnimationSpeedMultiplier(m) ST(self).speed = tonumber(m) or 1 end
function M_Group:GetAnimationSpeedMultiplier() return ST(self).speed or 1 end
function M_Group:GetAnimations() return R.unpack(ST(self).anims) end
function M_Group:RemoveAnimations() local gst = ST(self) clearFx(gst) gst.anims = {} end
function M_Group:GetParent() return ST(self).owner end
function M_Group:GetName() return ST(self).name end
function M_Group:GetObjectType() return "AnimationGroup" end
function M_Group:IsObjectType(t) return type(t) == "string" and (lower(t) == "animationgroup" or lower(t) == "object") end

local ANIM_KINDS = { Alpha = true, Translation = true, Scale = true, Rotation = true, Path = true,
    VertexColor = true, LineTranslation = true, LineScale = true, TextureCoordTranslation = true, FlipBook = true,
    Animation = true }
MOCK.ANIM_KINDS = ANIM_KINDS

function M_Group:CreateAnimation(kind, name, inherits)
    local gst = ST(self)
    if kind == nil then kind = "Animation" end
    local k
    if type(kind) == "string" then
        for n in pairs(ANIM_KINDS) do if lower(n) == lower(kind) then k = n end end
    end
    if not k then error(format("AnimationGroup:CreateAnimation(): Unknown animation type '%s'", tostring(kind)), 2) end
    if inherits ~= nil then error(format("AnimationGroup:CreateAnimation(): Couldn't find inherited node \"%s\"", tostring(inherits)), 2) end
    local ast = { kind = k, group = self, duration = 0, order = 1, name = name }
    local a = MOCK.NewObject("Anim_" .. k, ast)
    gst.anims[#gst.anims + 1] = a
    return a
end

-------------------------------------------------------------------------------
-- Animation methods
-------------------------------------------------------------------------------
local M_Anim = {}
local function grp(self) return S[ST(self, 3).group] end
function M_Anim:Play() local ast = ST(self) ast.group:Play() end
function M_Anim:Stop() local ast = ST(self) ast.group:Stop() end
function M_Anim:Pause() local ast = ST(self) ast.group:Pause() end
function M_Anim:Restart() local ast = ST(self) ast.group:Restart() end
function M_Anim:Finish() local ast = ST(self) ast.group:Finish() end
function M_Anim:IsPlaying() local g = grp(self) return g.isPlaying == true and not g.paused end
function M_Anim:IsPaused() return grp(self).paused == true end
function M_Anim:IsStopped() return not grp(self).isPlaying end
function M_Anim:IsDone() return grp(self).done == true end
function M_Anim:IsDelaying() ST(self) return false end
function M_Anim:SetDuration(d)
    local ast = ST(self)
    if not isNum(d) then error("Usage: Animation:SetDuration(seconds)", 2) end
    ast.duration = max(0, d)
end
function M_Anim:GetDuration() return ST(self).duration or 0 end
function M_Anim:SetStartDelay(d) local ast = ST(self) if not isNum(d) then error("Usage: Animation:SetStartDelay(seconds)", 2) end ast.startDelay = max(0, d) end
function M_Anim:GetStartDelay() return ST(self).startDelay or 0 end
function M_Anim:SetEndDelay(d) local ast = ST(self) if not isNum(d) then error("Usage: Animation:SetEndDelay(seconds)", 2) end ast.endDelay = max(0, d) end
function M_Anim:GetEndDelay() return ST(self).endDelay or 0 end
function M_Anim:SetOrder(o)
    local ast = ST(self)
    if not isNum(o) or o < 0 or o > 100 then error("Usage: Animation:SetOrder(order 0-100)", 2) end
    ast.order = floor(o)
end
function M_Anim:GetOrder() return ST(self).order or 1 end
local SMOOTHINGS = { NONE = true, IN = true, OUT = true, IN_OUT = true, OUT_IN = true }
function M_Anim:SetSmoothing(s)
    local ast = ST(self)
    if type(s) ~= "string" or not SMOOTHINGS[upper(s)] then error("Usage: Animation:SetSmoothing(\"NONE\"|\"IN\"|\"OUT\"|\"IN_OUT\"|\"OUT_IN\")", 2) end
    ast.smoothing = upper(s)
end
function M_Anim:GetSmoothing() return ST(self).smoothing or "NONE" end
function M_Anim:SetSmoothProgress(p) ST(self).progress = p end
function M_Anim:GetSmoothProgress() return ST(self).progress or 0 end
function M_Anim:GetProgress() return ST(self).progress or 0 end
function M_Anim:GetElapsed() return grp(self).elapsed or 0 end
function M_Anim:SetTarget(t)
    local ast = ST(self)
    if t ~= nil and not (S[t] and S[t].isRegionLike) then error("Usage: Animation:SetTarget(region)", 2) end
    ast.target = t
end
function M_Anim:GetTarget() local ast = ST(self) return targetOf(ast, S[ast.group]) end
function M_Anim:SetTargetKey(k) ST(self).targetKey = k end
function M_Anim:SetChildKey(k) ST(self).childKey = k end
function M_Anim:SetTargetName(n) ST(self).targetName = n end
function M_Anim:SetTargetParent() local ast = ST(self) ast.target = S[ast.group].owner end
function M_Anim:GetRegionParent() return S[ST(self).group].owner end
function M_Anim:GetParent() return ST(self).group end
function M_Anim:GetName() return ST(self).name end
function M_Anim:SetPlaying(on) if on then self:Play() else self:Stop() end end

local function animType(kind, extra)
    local m = {}
    for k, v in pairs(MOCK.M.ScriptObject) do m[k] = v end
    for k, v in pairs(M_Anim) do m[k] = v end
    for k, v in pairs(extra or {}) do m[k] = v end
    m.GetObjectType = function() return kind end
    m.IsObjectType = function(_, t) return type(t) == "string" and (lower(t) == lower(kind) or lower(t) == "animation" or lower(t) == "object") end
    local t = { name = "Anim_" .. kind, methods = m, scripts = MOCK.SCRIPTS_ANIM, isa = {}, meta = { __index = m } }
    MOCK.Types["Anim_" .. kind] = t
end

local A_Alpha = {}
function A_Alpha:SetFromAlpha(a) local ast = ST(self) if not isNum(a) then error("Usage: Alpha:SetFromAlpha(alpha)", 2) end ast.fromAlpha = a end
function A_Alpha:GetFromAlpha() return ST(self).fromAlpha or 0 end
function A_Alpha:SetToAlpha(a) local ast = ST(self) if not isNum(a) then error("Usage: Alpha:SetToAlpha(alpha)", 2) end ast.toAlpha = a end
function A_Alpha:GetToAlpha() return ST(self).toAlpha or 0 end
local A_Trans = {}
function A_Trans:SetOffset(x, y) local ast = ST(self) if not isNum(x) or not isNum(y) then error("Usage: Translation:SetOffset(x, y)", 2) end ast.offX, ast.offY = x, y end
function A_Trans:GetOffset() local ast = ST(self) return ast.offX or 0, ast.offY or 0 end
local A_Scale = {}
function A_Scale:SetScale(x, y) local ast = ST(self) ast.fromX, ast.fromY, ast.toX, ast.toY = 1, 1, x, y end
function A_Scale:GetScale() local ast = ST(self) return ast.toX or 1, ast.toY or 1 end
function A_Scale:SetScaleFrom(x, y) local ast = ST(self) ast.fromX, ast.fromY = x, y end
function A_Scale:GetScaleFrom() local ast = ST(self) return ast.fromX or 1, ast.fromY or 1 end
function A_Scale:SetScaleTo(x, y) local ast = ST(self) ast.toX, ast.toY = x, y end
function A_Scale:GetScaleTo() local ast = ST(self) return ast.toX or 1, ast.toY or 1 end
function A_Scale:SetFromScale(x, y) A_Scale.SetScaleFrom(self, x, y) end
function A_Scale:SetToScale(x, y) A_Scale.SetScaleTo(self, x, y) end
function A_Scale:SetOrigin(p, x, y) ST(self).origin = { p, x, y } end
function A_Scale:GetOrigin() local o = ST(self).origin or { "CENTER", 0, 0 } return o[1], o[2], o[3] end
local A_Rot = {}
function A_Rot:SetDegrees(d) local ast = ST(self) if not isNum(d) then error("Usage: Rotation:SetDegrees(degrees)", 2) end ast.degrees = d end
function A_Rot:GetDegrees() return ST(self).degrees or 0 end
function A_Rot:SetRadians(r) ST(self).degrees = (tonumber(r) or 0) * 180 / math.pi end
function A_Rot:GetRadians() return (ST(self).degrees or 0) * math.pi / 180 end
function A_Rot:SetOrigin(p, x, y) ST(self).origin = { p, x, y } end
function A_Rot:GetOrigin() local o = ST(self).origin or { "CENTER", 0, 0 } return o[1], o[2], o[3] end
local A_VC = {}
local function colorArgs(r, g, b, a)
    if type(r) == "table" and type(r.GetRGBA) == "function" then return { r:GetRGBA() } end
    return { r or 1, g or 1, b or 1, a or 1 }
end
function A_VC:SetStartColor(...) ST(self).startColor = colorArgs(...) end
function A_VC:GetStartColor() local c = ST(self).startColor or { 1, 1, 1, 1 } return MOCK.CreateColor and MOCK.CreateColor(c[1], c[2], c[3], c[4]) end
function A_VC:SetEndColor(...) ST(self).endColor = colorArgs(...) end
function A_VC:GetEndColor() local c = ST(self).endColor or { 1, 1, 1, 1 } return MOCK.CreateColor and MOCK.CreateColor(c[1], c[2], c[3], c[4]) end
local A_Path = {}
local CP = {}
function CP:SetOffset(x, y) local s = ST(self) s.offX, s.offY = x, y end
function CP:GetOffset() local s = ST(self) return s.offX or 0, s.offY or 0 end
function CP:SetOrder(o) ST(self).cpOrder = o end
function CP:GetOrder() return ST(self).cpOrder or 0 end
function CP:GetObjectType() return "ControlPoint" end
MOCK.Types.ControlPoint = { name = "ControlPoint", methods = CP, scripts = {}, isa = {}, meta = { __index = CP } }
function A_Path:CreateControlPoint(name, template, order)
    local ast = ST(self)
    if template ~= nil then error(format("Path:CreateControlPoint(): Couldn't find inherited node \"%s\"", tostring(template)), 2) end
    local cp = MOCK.NewObject("ControlPoint", { cpOrder = order or 0, name = name })
    ast.controlPoints = ast.controlPoints or {}
    ast.controlPoints[#ast.controlPoints + 1] = cp
    return cp
end
function A_Path:GetControlPoints() return R.unpack(ST(self).controlPoints or {}) end
function A_Path:GetMaxOrder() return #(ST(self).controlPoints or {}) end
function A_Path:SetCurveType(t) ST(self).curve = t end
function A_Path:GetCurveType() return ST(self).curve or "NONE" end
local A_Flip = {}
for _, k in ipairs({ "FlipBookRows", "FlipBookColumns", "FlipBookFrames", "FlipBookFrameWidth", "FlipBookFrameHeight" }) do
    A_Flip["Set" .. k] = function(self, v) ST(self)[k] = v end
    A_Flip["Get" .. k] = function(self) return ST(self)[k] or 0 end
end

animType("Animation")
animType("Alpha", A_Alpha)
animType("Translation", A_Trans)
animType("LineTranslation", A_Trans)
animType("Scale", A_Scale)
animType("LineScale", A_Scale)
animType("Rotation", A_Rot)
animType("VertexColor", A_VC)
animType("Path", A_Path)
animType("TextureCoordTranslation", A_Trans)
animType("FlipBook", A_Flip)

do
    local m = {}
    for k, v in pairs(MOCK.M.ScriptObject) do m[k] = v end
    for k, v in pairs(M_Group) do m[k] = v end
    MOCK.Types.AnimationGroup = { name = "AnimationGroup", methods = m, scripts = MOCK.SCRIPTS_ANIMGROUP, isa = {}, meta = { __index = m } }
end

-- CreateAnimationGroup / GetAnimationGroups / StopAnimating on every region and frame type
local function createAnimationGroup(self, name, inherits)
    local st = ST(self)
    if inherits ~= nil then error(format("%s:CreateAnimationGroup(): Couldn't find inherited node \"%s\"", st.otype, tostring(inherits)), 2) end
    local g = MOCK.NewObject("AnimationGroup", { owner = self, anims = {}, name = name })
    st.animGroups = st.animGroups or {}
    st.animGroups[#st.animGroups + 1] = g
    return g
end
local function getAnimationGroups(self) return R.unpack(ST(self).animGroups or {}) end
local function stopAnimating(self)
    for _, g in ipairs(ST(self).animGroups or {}) do g:Stop() end
end
for _, t in pairs(MOCK.Types) do
    if t.isa and t.isa.scriptregion then
        t.methods.CreateAnimationGroup = createAnimationGroup
        t.methods.GetAnimationGroups = getAnimationGroups
        t.methods.StopAnimating = stopAnimating
    end
end

-------------------------------------------------------------------------------
-- Tick
-------------------------------------------------------------------------------
MOCK.tickHooks = {}  -- functions(elapsed) run each tick by other mock parts (e.g. item cache)

function MOCK.Tick(epoch, uptime, elapsed)
    MOCK.epoch, MOCK.uptime = epoch, uptime
    MOCK.tickNo = MOCK.tickNo + 1
    for _, h in ipairs(MOCK.tickHooks) do Protect("mock", "tickHook", h, elapsed) end
    MOCK.RunTimers()
    for _, f in ipairs(MOCK.osSnapshot(MOCK.updateSet)) do
        if MOCK.IsVisible(f) then runScript(f, "OnUpdate", elapsed) end
    end
    for _, g in ipairs(MOCK.osSnapshot(playing)) do
        local gst = S[g]
        if gst.isPlaying then tickGroup(g, gst, elapsed) end
    end
    if MOCK.cooldowns then
        for cd in pairs(MOCK.cooldowns) do
            local st = S[cd]
            if st.cdStart and st.cdDuration and st.cdDuration > 0 and uptime >= st.cdStart + st.cdDuration then
                st.cdStart, st.cdDuration = nil, nil
                MOCK.cooldowns[cd] = nil
                runScript(cd, "OnCooldownDone")
            end
        end
    end
    MOCK.LayoutPass()
end

--- run after every harness-driven action (no time passes)
function MOCK.Flush()
    MOCK.LayoutPass()
end

-------------------------------------------------------------------------------
-- User input (driven by run.py)
-------------------------------------------------------------------------------
MOCK.hw = false

local function withHW(fn, ...)
    local prev = MOCK.hw
    MOCK.hw = true
    local res = MOCK.packn(R.pcall(fn, ...))
    MOCK.hw = prev
    if not res[1] then error(res[2], 0) end
    return R.unpack(res, 2, res.n)
end

local function clickable(obj)
    local st = S[obj]
    return st and MOCK.IsVisible(obj) and st.mouse ~= false
end

--- real mouse click: OnMouseDown, OnMouseUp, then (Buttons, if enabled + registered) Pre/OnClick/Post
function MOCK.UserClick(obj, button)
    button = button or "LeftButton"
    if not clickable(obj) then return false end
    return withHW(function()
        local st = S[obj]
        if st.isButton and not st.enabled then return false end
        runScript(obj, "OnMouseDown", button)
        if not S[obj] then return true end
        runScript(obj, "OnMouseUp", button, MOCK.IsVisible(obj))
        if st.isButton and st.enabled and MOCK.IsVisible(obj) then
            local c = st.clicks or {}
            if c[button .. "Up"] or c.AnyUp or c.AnyDown or c[button .. "Down"] then
                if st.isCheckButton then st.checked = not st.checked end
                runScript(obj, "PreClick", button, false)
                runScript(obj, "OnClick", button, false)
                runScript(obj, "PostClick", button, false)
            end
        end
        MOCK.Flush()
        return true
    end)
end

function MOCK.UserEnter(obj)
    if not clickable(obj) then return false end
    local st = S[obj]
    if st.isButton and not st.enabled and not st.motionWhileDisabled then return false end
    MOCK.hoverObject = obj
    runScript(obj, "OnEnter", true)
    MOCK.Flush()
    return true
end

function MOCK.UserLeave(obj)
    if MOCK.hoverObject == obj then MOCK.hoverObject = nil end
    if not S[obj] then return false end
    runScript(obj, "OnLeave", true)
    MOCK.Flush()
    return true
end

function MOCK.UserWheel(obj, delta)
    local st = S[obj]
    if not (st and MOCK.IsVisible(obj) and st.wheel) then return false end
    runScript(obj, "OnMouseWheel", delta)
    MOCK.Flush()
    return true
end

local function utf8chars(s)
    local out, i = {}, 1
    while i <= #s do
        local b = R.byte(s, i)
        local n = (b >= 240 and 4) or (b >= 224 and 3) or (b >= 192 and 2) or 1
        out[#out + 1] = R.sub(s, i, i + n - 1)
        i = i + n
    end
    return out
end

--- types text into an edit box as a user would: focus, then per character OnChar + OnTextChanged(true)
function MOCK.UserType(box, text, replace)
    local st = S[box]
    if not (st and st.isEditBox and MOCK.IsVisible(box) and st.enabled ~= false) then return false end
    return withHW(function()
        MOCK.SetFocus(box)
        if replace then MOCK.EditBoxSetText(box, st, "", true) end
        for _, ch in ipairs(utf8chars(text)) do
            if not st.focus then break end
            if not (st.numeric and not R.find(ch, "^%d$")) then
                local cur = MOCK.TextOf(st)
                if (st.maxLetters or 0) <= 0 or MOCK.utf8len(cur) < st.maxLetters then
                    st.text = cur .. ch
                    st.cursor = MOCK.utf8len(st.text)
                    MOCK.LayoutDirty()
                    runScript(box, "OnChar", ch)
                    runScript(box, "OnTextChanged", true)
                end
            end
        end
        MOCK.Flush()
        return true
    end)
end

function MOCK.UserKey(box, key)
    local st = S[box]
    if not st then return false end
    return withHW(function()
        if key == "ENTER" then runScript(box, "OnEnterPressed")
        elseif key == "ESCAPE" then runScript(box, "OnEscapePressed")
        elseif key == "TAB" then runScript(box, "OnTabPressed")
        elseif key == "SPACE" then runScript(box, "OnSpacePressed") end
        MOCK.Flush()
        return true
    end)
end

--- Escape: the focused edit box gets it first, otherwise UISpecialFrames windows close
function MOCK.PressEscape()
    if MOCK.focus then return MOCK.UserKey(MOCK.focus, "ESCAPE") end
    local closed = 0
    local list = rawget(_G, "UISpecialFrames")
    if type(list) == "table" then
        for _, name in ipairs(list) do
            local f = rawget(_G, name)
            if type(f) == "table" and S[f] and f:IsShown() then
                f:Hide()
                closed = closed + 1
            end
        end
    end
    MOCK.Flush()
    return closed
end

--- visible widgets of the given kinds in a subtree, in creation order
function MOCK.CollectVisible(root, kindsCsv)
    local kinds = {}
    for k in R.gmatch(kindsCsv, "[^,]+") do kinds[k] = true end
    local out = {}
    MOCK.Walk(root, function(o, st)
        if st.isFrame and not st.shown then return false end
        if kinds[st.otype] and MOCK.IsVisible(o) then out[#out + 1] = o end
    end)
    return out
end

function MOCK.HasScript(obj, name)
    local st = S[obj]
    return st ~= nil and (st.scripts[name] ~= nil or (st.hooks[name] ~= nil and #st.hooks[name] > 0))
end

-------------------------------------------------------------------------------
-- Fuzz helpers (run.py's page fuzzer)
-------------------------------------------------------------------------------
--- visible frames with the mouse wheel enabled and an OnMouseWheel script
function MOCK.CollectWheel(root)
    local out = {}
    MOCK.Walk(root, function(o, st)
        if st.isFrame and not st.shown then return false end
        if st.isFrame and st.wheel and MOCK.IsVisible(o) and MOCK.HasScript(o, "OnMouseWheel") then out[#out + 1] = o end
    end)
    return out
end

--- visible mouse-enabled non-button frames that react to the mouse (rows, cards, icons)
function MOCK.CollectHoverables(root)
    local out = {}
    MOCK.Walk(root, function(o, st)
        if st.isFrame and not st.shown then return false end
        if st.isFrame and not st.isButton and MOCK.IsVisible(o)
            and (MOCK.HasScript(o, "OnEnter") or MOCK.HasScript(o, "OnMouseDown") or MOCK.HasScript(o, "OnMouseUp")) then
            out[#out + 1] = o
        end
    end)
    return out
end

function MOCK.IsDescendant(obj, root)
    local o = obj
    while o do
        if o == root then return true end
        o = S[o] and S[o].parent
    end
    return false
end

function MOCK.ButtonText(obj)
    local st = S[obj]
    if not st then return "" end
    local fs = st.FontString
    local t = fs and S[fs] and S[fs].text
    if type(t) == "string" then return t end
    -- custom buttons keep their label in a child FontString
    for _, r in ipairs(st.regions or {}) do
        local rs = S[r]
        if rs.isFontString and type(rs.text) == "string" and rs.text ~= "" then return rs.text end
    end
    return ""
end

function MOCK.RegisteredFor(obj, button)
    local st = S[obj]
    local c = st and st.clicks or {}
    return c[button .. "Up"] or c[button .. "Down"] or c.AnyUp or c.AnyDown or false
end

--- hides every visible UISpecialFrames window except `keep` (Escape without the main window)
function MOCK.HideSpecials(keep)
    local closed = 0
    local list = rawget(_G, "UISpecialFrames")
    if type(list) == "table" then
        for i = #list, 1, -1 do
            local name = list[i]
            local f = rawget(_G, name)
            if name ~= keep and type(f) == "table" and S[f] and f:IsShown() then
                f:Hide()
                closed = closed + 1
            end
        end
    end
    MOCK.Flush()
    return closed
end

function MOCK.VisibleSpecials(keep)
    local out = {}
    local list = rawget(_G, "UISpecialFrames")
    if type(list) == "table" then
        for _, name in ipairs(list) do
            local f = rawget(_G, name)
            if name ~= keep and type(f) == "table" and S[f] and MOCK.IsVisible(f) then out[#out + 1] = f end
        end
    end
    return out
end

--- Protected call for harness-driven addon calls (errors are recorded, never raised)
function MOCK.HarnessCall(label, fn, ...)
    return MOCK.Protect("harness", label, fn, ...)
end

--- Like HarnessCall but as a hardware event (a click on a Blizzard UI element)
function MOCK.HardwareCall(label, fn, ...)
    local prev = MOCK.hw
    MOCK.hw = true
    local res = MOCK.packn(MOCK.Protect("harness", label, fn, ...))
    MOCK.hw = prev
    return R.unpack(res, 1, res.n)
end

function MOCK.ObjId(obj) local st = S[obj] return st and st.id or 0 end
