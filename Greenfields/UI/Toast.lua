--[[ Greenfields - UI/Toast.lua
     Road-sign toasts that drop in from the top of the screen.

       UI:Toast{ title, text, icon, style = "green"|"yellow"|"red"|"blue",
                 duration = 6, sound = true|kitID, onClick = fn, key = "dedupe-key" }
     At most 3 visible; the rest queue. Same `key` within 10 s is ignored. ]]

local _, GF = ...

local UI = GF.UI
local T = GF.Theme
local API = GF.API

local SIGNS = {
    green = T.tex.signGreen, yellow = T.tex.signYellow, red = T.tex.signRed, blue = T.tex.signBlue,
}
local TEXT_DARK = { yellow = true }

local active, queue, pool = {}, {}, {}
local recentKeys = {}
local MAX_VISIBLE = 3
local W, H = 384, 96
local TEXT_W = W - 78 - 26
local MAX_H = H + 32        -- room for two more lines; anything longer than that gets cut off
local DROP = 24             -- how far a new sign falls into its slot
local PITCH_OVERLAP = 8     -- the art has clear space round the plate, so signs can sit closer

local anchor

local function layout()
    local y = 0
    for _, t in ipairs(active) do
        t:ClearAllPoints()
        -- still falling: it's parked above its slot and the Translation carries it down
        t:SetPoint("TOP", anchor, "TOP", 0, -y + (t.dropping and DROP or 0))
        y = y + t:GetHeight() - PITCH_OVERLAP
    end
end

local function release(t)
    t.intro:Stop()
    t.dropping = false
    t:Hide()
    for i, a in ipairs(active) do
        if a == t then table.remove(active, i) break end
    end
    pool[#pool + 1] = t
    layout()
    if #queue > 0 and #active < MAX_VISIBLE then
        UI:Toast(table.remove(queue, 1))
    end
end

local function makeToast()
    local t = CreateFrame("Button", nil, UIParent)
    t:SetSize(W, H)
    t:SetFrameStrata("DIALOG")
    t:SetFrameLevel(50)
    -- three bands, so a sign that grows a line only stretches the plain middle of the plate
    t.signs = {}
    for i, band in ipairs({ { 0, 0.4 }, { 0.4, 0.6 }, { 0.6, 1 } }) do
        local s = t:CreateTexture(nil, "BACKGROUND")
        s:SetTexCoord(0, 1, band[1], band[2])
        t.signs[i] = s
    end
    t.signs[1]:SetPoint("TOPLEFT")
    t.signs[1]:SetPoint("TOPRIGHT")
    t.signs[1]:SetHeight(H * 0.4)
    t.signs[3]:SetPoint("BOTTOMLEFT")
    t.signs[3]:SetPoint("BOTTOMRIGHT")
    t.signs[3]:SetHeight(H * 0.4)
    t.signs[2]:SetPoint("TOPLEFT", t.signs[1], "BOTTOMLEFT")
    t.signs[2]:SetPoint("BOTTOMRIGHT", t.signs[3], "TOPRIGHT")
    -- the shine sweeps this, not the whole texture, so it stays on the metal
    t.shineBox = CreateFrame("Frame", nil, t)
    t.shineBox:SetPoint("TOPLEFT", 8, -8)
    t.shineBox:SetPoint("BOTTOMRIGHT", -8, 10)
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(40, 40)
    t.icon:SetPoint("LEFT", 26, 1)
    t.title = UI:Text(t, 14, "text", "ui")
    t.title:SetWidth(TEXT_W)
    t.text = UI:Para(t, 12, "text")
    t.text:SetPoint("TOPLEFT", t.title, "BOTTOMLEFT", 0, -4)
    t.text:SetWidth(TEXT_W)

    local ag = t:CreateAnimationGroup()
    local slide = ag:CreateAnimation("Translation")
    slide:SetOffset(0, -DROP)
    slide:SetDuration(0.22)
    slide:SetSmoothing("OUT")
    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(0)
    fade:SetToAlpha(1)
    fade:SetDuration(0.18)
    ag:SetScript("OnFinished", function()
        t:SetAlpha(1)
        -- the animation lets go of the frame here: settle it in its slot on the same frame
        t.dropping = false
        layout()
    end)
    t.intro = ag

    local out = t:CreateAnimationGroup()
    local fo = out:CreateAnimation("Alpha")
    fo:SetFromAlpha(1)
    fo:SetToAlpha(0)
    fo:SetDuration(0.3)
    out:SetScript("OnFinished", function() release(t) end)
    t.outro = out

    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and self.onClick then GF:Safe("toast:click", self.onClick) end
        self.outro:Play()
    end)
    t:SetScript("OnEnter", function(self) self.hover = true end)
    t:SetScript("OnLeave", function(self) self.hover = false end)
    t:SetScript("OnUpdate", function(self, elapsed)
        if self.hover or self.outro:IsPlaying() then return end
        self.remaining = (self.remaining or 0) - elapsed
        if self.remaining <= 0 then self.outro:Play() end
    end)
    return t
end

function UI:Toast(opts)
    if type(opts) ~= "table" or GF.gateShut then return end
    if GF.db and GF.db.settings.toasts == false and not opts.force then return end
    if opts.key then
        local now = API.Time()
        if recentKeys[opts.key] and now - recentKeys[opts.key] < 10 then return end
        recentKeys[opts.key] = now
    end
    if not anchor then
        anchor = CreateFrame("Frame", nil, UIParent)
        anchor:SetSize(W, 10)
        -- high enough to clear the main window's header on most screens
        anchor:SetPoint("TOP", UIParent, "TOP", 0, -36)
    end
    if #active >= MAX_VISIBLE then
        if #queue < 12 then queue[#queue + 1] = opts end
        return
    end
    local t = table.remove(pool) or makeToast()
    local style = SIGNS[opts.style or "green"] and (opts.style or "green") or "green"
    for _, s in ipairs(t.signs) do
        s:SetTexture(SIGNS[style])
        UI.NoSnap(s)
    end
    local dark = TEXT_DARK[style]
    t.title:SetTextColor(dark and 0.08 or 1, dark and 0.08 or 1, dark and 0.06 or 1, 1)
    t.text:SetTextColor(dark and 0.12 or 0.92, dark and 0.12 or 0.97, dark and 0.10 or 0.94, 1)
    -- a black shadow under black text on yellow just doubles it
    t.title:SetShadowOffset(dark and 0 or 1, dark and 0 or -1)
    t.text:SetShadowOffset(dark and 0 or 1, dark and 0 or -1)
    t.title:SetText(GF.Util.StripCodes(tostring(opts.title or "")):upper())
    t.text:SetHeight(0)   -- pooled: a height left from its last use would cut the new text short
    t.text:SetText(opts.text or "")
    -- fit the text: centred on the plate, and the sign grows if it won't go. The plate sits 2 units
    -- high in its art, for the shadow underneath.
    local hasText = opts.text ~= nil and opts.text ~= ""
    local textH = hasText and math.max(14, t.text:GetStringHeight() or 14) or 0
    local blockH = 18 + (hasText and (4 + textH) or 0)
    local height = math.max(H, math.min(MAX_H, blockH + 34))
    t.text:SetHeight(math.max(1, math.min(textH, height - 34 - 22)))
    t:SetHeight(height)
    t.title:ClearAllPoints()
    t.title:SetPoint("TOPLEFT", 78, -math.floor((height - 2 - math.min(blockH, height - 34)) / 2))
    t.icon:ClearAllPoints()
    t.icon:SetPoint("LEFT", 26, 1)
    UI:SetIcon(t.icon, opts.icon or "bell")
    if not t.icon.isGameIcon then
        if dark then t.icon:SetVertexColor(0.08, 0.08, 0.06, 1) else t.icon:SetVertexColor(1, 1, 1, 1) end
    else
        t.icon:SetVertexColor(1, 1, 1, 1)
    end
    t.onClick = opts.onClick
    t.remaining = opts.duration or 6
    t.hover = false
    t.dropping = true
    active[#active + 1] = t
    layout()
    t:SetAlpha(0)
    t:Show()
    t.intro:Play()
    GF:After(0.25, function() if t:IsShown() then UI:Shine(t.shineBox, 0.9) end end)
    -- a crown, a boss or a win gets the gold going off round its icon
    if opts.burst or opts.icon == "crown" or opts.icon == "trophy" then
        GF:After(0.2, function() if t:IsShown() then UI:Burst(t.icon, opts.burst or "gold", 2.4) end end)
    end
    if opts.sound ~= false and GF.db and GF.db.settings.toastSounds ~= false then
        API.PlaySound(type(opts.sound) == "number" and opts.sound or 18019) -- UI_BNET_TOAST
    end
end

GF:RegisterSlash("toast", function()
    UI:Toast({ title = "Nah yeah", text = "Toasts are working. She'll be right.", icon = "bell", style = "green" })
end, "test a toast")
