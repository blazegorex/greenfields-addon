--[[ Greenfields - UI/Motion.lua
     The little bits of life.

       UI:Ease(region, alpha, dur)      fade a texture or frame to an alpha, eased, from wherever it is
       UI:Attention(frame, on, colour)  a soft glow breathing behind something that wants you
       UI:Burst(frame, kind, scale)     a one-shot sparkle over something, for a win or a yes. The
                                        bursts are Data/ArtFx.lua, written by tools/pixel_art.py.

     One OnUpdate drives the eases, and only while something's fading. ]]

local _, GF = ...

local UI = GF.UI
local T = GF.Theme

local floor, min, max = math.floor, math.min, math.max

-------------------------------------------------------------------------------
-- Eases
-------------------------------------------------------------------------------
local eases, driver = {}, nil

local function ease(t) return 1 - (1 - t) * (1 - t) end

local function drive(_, elapsed)
    local any = false
    for r, e in pairs(eases) do
        e.t = e.t + elapsed
        local k = min(1, e.t / e.dur)
        e.now = e.from + (e.to - e.from) * ease(k)
        r:SetAlpha(e.now)
        r.gfAlpha = e.now
        if k >= 1 then
            eases[r] = nil
            if e.to <= 0 and e.hide then r:Hide() end
        else
            any = true
        end
    end
    if not any then driver:SetScript("OnUpdate", nil) end
end

--- Fades a region to `alpha` over `dur` seconds (0.12 by default), from wherever it is now. Shows
-- it first if it's hidden; hide = true hides it again once it's faded out.
function UI:Ease(r, alpha, dur, hide)
    if not r then return end
    driver = driver or CreateFrame("Frame")
    -- a nine-slice (UI:Nine) only takes SetAlpha and Show, so it remembers its own alpha here
    local shown = not r.IsShown or r:IsShown()
    local from = r.GetAlpha and r:GetAlpha() or r.gfAlpha or 0
    if alpha > 0 and not shown then from = 0; r:SetAlpha(0); r:Show() end
    eases[r] = { from = from, to = alpha, t = 0, dur = max(0.01, dur or 0.12), hide = hide and r.Hide and true }
    driver:SetScript("OnUpdate", drive)
end

-------------------------------------------------------------------------------
-- Attention: a glow breathing behind a badge or a button
-------------------------------------------------------------------------------
function UI:Attention(f, on, colour)
    if not f then return end
    local g = f.gfAttention
    if not on then
        if g then g.ag:Stop(); g:Hide() end
        return
    end
    if not g then
        g = f:CreateTexture(nil, "BACKGROUND", nil, -2)
        g:SetTexture(T.tex.glow)
        g:SetBlendMode("ADD")
        g:SetPoint("TOPLEFT", -10, 8)
        g:SetPoint("BOTTOMRIGHT", 10, -8)
        g.ag = g:CreateAnimationGroup()
        local up = g.ag:CreateAnimation("Alpha")
        up:SetFromAlpha(0.15); up:SetToAlpha(0.6); up:SetDuration(1.1); up:SetSmoothing("IN_OUT"); up:SetOrder(1)
        local down = g.ag:CreateAnimation("Alpha")
        down:SetFromAlpha(0.6); down:SetToAlpha(0.15); down:SetDuration(1.1); down:SetSmoothing("IN_OUT"); down:SetOrder(2)
        g.ag:SetLooping("REPEAT")
        f.gfAttention = g
    end
    local c = colour or T.c.wowGold
    g:SetVertexColor(c[1], c[2], c[3], 1)
    g:Show()
    if not g.ag:IsPlaying() then g.ag:Play() end
end

-------------------------------------------------------------------------------
-- Bursts: a one-shot flipbook over something, for a win or a yes
-------------------------------------------------------------------------------
local function burstStep(b, elapsed)
    local d = b.def
    b.t = b.t + elapsed
    local f = floor(b.t * (d.fps or 14))
    if f >= d.frames then
        b:SetScript("OnUpdate", nil)
        b:Hide()
        return
    end
    if f ~= b.frame then
        b.frame = f
        local col, row = f % d.cols, floor(f / d.cols)
        b.tex:SetTexCoord(col * d.cw, (col + 1) * d.cw, row * d.ch, (row + 1) * d.ch)
    end
end

--- Plays burst `kind` ("gold", "green": Data/ArtFx.lua) once, centred on frame or texture f,
-- `scale` times its height across.
function UI:Burst(f, kind, scale)
    local d = f and GF.ArtFx and GF.ArtFx.bursts and GF.ArtFx.bursts[kind or "gold"]
    if not d or not f.GetCenter then return end
    local host = f.GetParent and f:GetObjectType() ~= "Texture" and f or f:GetParent()
    if not host then return end
    local b = host.gfBurst
    if not b then
        b = CreateFrame("Frame", nil, host)
        b:SetFrameLevel(host:GetFrameLevel() + 8)
        b.tex = b:CreateTexture(nil, "OVERLAY")
        b.tex:SetAllPoints()
        host.gfBurst = b
    end
    local size = max(24, (f:GetHeight() or 32) * (scale or 2.2))
    b:ClearAllPoints()
    b:SetPoint("CENTER", f, "CENTER")
    b:SetSize(size, size)
    b.tex:SetTexture(d.tex)
    b.tex:SetBlendMode(d.add and "ADD" or "BLEND")
    b.def, b.t, b.frame = d, 0, -1
    b:Show()
    burstStep(b, 0)
    b:SetScript("OnUpdate", burstStep)
end
