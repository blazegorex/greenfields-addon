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

local anchor

local function layout()
    for i, t in ipairs(active) do
        t:ClearAllPoints()
        t:SetPoint("TOP", anchor, "TOP", 0, -(i - 1) * (H - 8))
    end
end

local function release(t)
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
    t.sign = t:CreateTexture(nil, "BACKGROUND")
    t.sign:SetAllPoints()
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(40, 40)
    t.icon:SetPoint("LEFT", 26, 1)
    t.title = UI:Text(t, 16, "text", "head")
    t.title:SetPoint("TOPLEFT", 78, -22)
    t.title:SetPoint("TOPRIGHT", -26, -22)
    t.text = UI:Text(t, 12, "text")
    t.text:SetPoint("TOPLEFT", t.title, "BOTTOMLEFT", 0, -4)
    t.text:SetPoint("TOPRIGHT", t.title, "BOTTOMRIGHT", 0, -4)
    t.text:SetWordWrap(true)
    t.text:SetJustifyV("TOP")
    t.text:SetHeight(32)

    local ag = t:CreateAnimationGroup()
    local slide = ag:CreateAnimation("Translation")
    slide:SetOffset(0, -24)
    slide:SetDuration(0.22)
    slide:SetSmoothing("OUT")
    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(0)
    fade:SetToAlpha(1)
    fade:SetDuration(0.18)
    ag:SetScript("OnFinished", function() t:SetAlpha(1) end)
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
    if type(opts) ~= "table" then return end
    if GF.db and GF.db.settings.toasts == false and not opts.force then return end
    if opts.key then
        local now = API.Time()
        if recentKeys[opts.key] and now - recentKeys[opts.key] < 10 then return end
        recentKeys[opts.key] = now
    end
    if not anchor then
        anchor = CreateFrame("Frame", nil, UIParent)
        anchor:SetSize(W, 10)
        anchor:SetPoint("TOP", UIParent, "TOP", 0, -110)
    end
    if #active >= MAX_VISIBLE then
        if #queue < 12 then queue[#queue + 1] = opts end
        return
    end
    local t = table.remove(pool) or makeToast()
    local style = SIGNS[opts.style or "green"] and (opts.style or "green") or "green"
    t.sign:SetTexture(SIGNS[style])
    local dark = TEXT_DARK[style]
    t.title:SetTextColor(dark and 0.08 or 1, dark and 0.08 or 1, dark and 0.06 or 1, 1)
    t.text:SetTextColor(dark and 0.12 or 0.92, dark and 0.12 or 0.97, dark and 0.10 or 0.94, 1)
    t.title:SetText(GF.Util.StripCodes(tostring(opts.title or "")):upper())
    t.text:SetText(opts.text or "")
    UI:SetIcon(t.icon, opts.icon or "bell")
    if not t.icon.isGameIcon then
        if dark then t.icon:SetVertexColor(0.08, 0.08, 0.06, 1) else t.icon:SetVertexColor(1, 1, 1, 1) end
    else
        t.icon:SetVertexColor(1, 1, 1, 1)
    end
    t.onClick = opts.onClick
    t.remaining = opts.duration or 6
    t.hover = false
    active[#active + 1] = t
    layout()
    t:SetAlpha(0)
    t:Show()
    t.intro:Play()
    GF:After(0.25, function() if t:IsShown() then UI:Shine(t, 0.9) end end)
    if opts.sound ~= false and GF.db and GF.db.settings.toastSounds ~= false then
        API.PlaySound(type(opts.sound) == "number" and opts.sound or 18019) -- UI_BNET_TOAST
    end
end

GF:RegisterSlash("toast", function()
    UI:Toast({ title = "Nah yeah", text = "Toasts are working. She'll be right.", icon = "bell", style = "green" })
end, "test a toast")
