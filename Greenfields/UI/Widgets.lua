--[[ Greenfields - UI/Widgets.lua
     The widget kit every page is built from. All widgets are plain frames (no Blizzard
     templates except BackdropTemplate), so they look the same everywhere and never taint.

       UI:Panel(parent, bg, border)            UI:SetBackdrop(frame, bg, border)
       UI:Nine(owner, style, layer, sub, target)   UI:Well(parent)
       UI:Hairline(parent, color, alpha, fade)     UI:Gradient(tex, orient, ...)
       UI:Tiled(frame, name, r, g, b, a, inset)    UI:Scrim(frame, side, size, alpha)
       UI:Para(parent, size, color, kind)          UI:SectionLabel(parent, text)
       UI:Stat(parent, opts)  UI:StatTile(parent, opts)  UI:IconChip(parent, size, icon)
       UI:Segmented(parent, items, onSelect)    UI:Parchment(frame, inset)  UI:Window(name, opts)
       UI:Text(parent, size, color, kind, flags)
       UI:Icon(parent, size, icon)              UI:SetIcon(texture, icon)
       UI:Button(parent, text, opts)            UI:IconButton(parent, icon, size, tooltip, onClick)
       UI:Input(parent, opts)                   UI:Search(parent, opts)
       UI:Toggle(parent, label, opts)           UI:Dropdown(parent, opts)
       UI:OpenMenu(anchor, items, opts)         UI:CloseMenu()
       UI:List(parent, opts)                    UI:Scroll(parent)
       UI:Card(parent, opts)                    UI:Pill(parent, text, color)
       UI:Bar(parent, opts)                     UI:ItemButton(parent, size)
       UI:ClassIcon(parent, size)               UI:Avatar(parent, size)
       UI:Tabs(parent, items, onSelect)         UI:PageHeader(page, title, subtitle)
       UI:Empty(parent, text, icon)             UI:Divider(parent)
       UI:Modal(opts) / UI:Confirm / UI:Prompt / UI:CopyBox
       UI:Tip(owner, title, lines, anchor)      UI:FadeIn(frame)   UI:Pulse(frame)
       UI:Shadow(frame, size)                   UI:EnableLinks(frame)
     Colours are theme names ("green", "dim") or {r,g,b,a} tables. ]]

local _, GF = ...

local UI = GF.UI or {}
GF.UI = UI

local T = GF.Theme
local C = T.c
local API, U = GF.API, GF.Util
local WHITE = T.tex.white
local CARD_R, CARD_G, CARD_B = 0.069, 0.088, 0.134   -- a card's fill, for things that fade into one
local type, pairs, ipairs, max, min, floor = type, pairs, ipairs, math.max, math.min, math.floor

local function col(c)
    if type(c) == "string" then return C[c] or C.text end
    return c or C.text
end
UI.col = col

local function sound(kit) if GF.db and GF.db.settings.toastSounds ~= false then API.PlaySound(kit) end end
UI.Sound = sound

-------------------------------------------------------------------------------
-- Basics
-------------------------------------------------------------------------------
function UI:SetBackdrop(f, bg, border)
    if not f.SetBackdrop then
        if not BackdropTemplateMixin then return end
        Mixin(f, BackdropTemplateMixin)
        if f.OnBackdropSizeChanged then f:HookScript("OnSizeChanged", f.OnBackdropSizeChanged) end
    end
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    bg, border = bg and col(bg), border and col(border)
    if bg then f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1) else f:SetBackdropColor(0, 0, 0, 0) end
    if border then f:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1) else f:SetBackdropBorderColor(0, 0, 0, 0) end
end

function UI:Panel(parent, bg, border)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    self:SetBackdrop(f, bg or C.bg2, border == nil and C.line or border)
    return f
end

function UI:Text(parent, size, color, kind, flags, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    T:Font(fs, kind or "body", size or 12, flags)
    local c = col(color)
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

function UI:SetTextColor(fs, color)
    local c = col(color)
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
end

function UI:Tex(parent, layer, color, sub)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    if color then
        local c = col(color)
        t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    end
    return t
end

--- Wrapped body text with proper leading. Set a width or two anchors on it.
function UI:Para(parent, size, color, kind)
    local fs = self:Text(parent, size or 12, color or "text", kind)
    fs:SetWordWrap(true)
    fs:SetJustifyV("TOP")
    if fs.SetSpacing then fs:SetSpacing((size or 12) >= 13 and 3 or 2) end
    return fs
end

--- Sub-heading inside a card: small bronze label with a fine rule running off to the right.
-- Returns a frame of height 16; :SetText(s). Anchor its left and right edges.
function UI:SectionLabel(parent, text)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(16)
    f.label = self:Text(f, 11, "bronze", "ui")
    f.label:SetPoint("LEFT")
    f.rule = self:Hairline(f, "bronze", 0.34)
    f.rule:SetPoint("LEFT", f.label, "RIGHT", 8, 0)
    f.rule:SetPoint("RIGHT")
    function f:SetText(t) self.label:SetText(t or "") end
    f:SetText(text)
    return f
end

local iconExists = {}   -- game icon path -> does the client have it (asked once)

--- icon: our media icon name ("trophy"), a texture path, or a fileID.
function UI:SetIcon(t, icon)
    if type(icon) == "string" and not icon:find("\\", 1, true) and not icon:find("/", 1, true) then
        t:SetTexture(T.Icon(icon))
        t:SetTexCoord(0, 1, 0, 1)
        t.isGameIcon = false
    else
        -- a game icon path the client doesn't have would draw nothing: show the "?" instead
        if type(icon) == "string" and icon:lower():find("^interface\\icons\\") then
            local known = iconExists[icon]
            if known == nil then
                local fid = rawget(_G, "GetFileIDFromPath")
                known = true
                if fid then
                    local ok, id = pcall(fid, icon)
                    if ok and id == nil then known = false end
                end
                iconExists[icon] = known
            end
            if not known then icon = 134400 end
        end
        t:SetTexture(icon or 134400)
        t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t.isGameIcon = true
    end
end

function UI:Icon(parent, size, icon, layer, color)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetSize(size or 16, size or 16)
    if icon then self:SetIcon(t, icon) end
    if color then local c = col(color); t:SetVertexColor(c[1], c[2], c[3], c[4] or 1) end
    return t
end

local function sliced(tex, path, margin)
    tex:SetTexture(path)
    if tex.SetTextureSliceMargins then
        pcall(tex.SetTextureSliceMargins, tex, margin, margin, margin, margin)
        if tex.SetTextureSliceMode and Enum and Enum.UITextureSliceMode then
            pcall(tex.SetTextureSliceMode, tex, Enum.UITextureSliceMode.Stretched)
        end
    end
end
UI.Sliced = sliced

-- Native slicing draws one texel as one UI unit, which goes soft once the UI is scaled up on a
-- big screen. Nine plain textures cut by hand let the art sit at 2 texels per UI unit instead,
-- the same density as the game's own frames.
local NineMethods = {}
NineMethods.__index = NineMethods
local NINE_KEYS = { "tl", "t", "tr", "l", "c", "r", "bl", "b", "br" }

function NineMethods:SetVertexColor(r, g, b, a)
    for _, t in pairs(self.parts) do t:SetVertexColor(r, g, b, a or 1) end
end
function NineMethods:SetAlpha(a) for _, t in pairs(self.parts) do t:SetAlpha(a) end end
function NineMethods:SetShown(on) for _, t in pairs(self.parts) do t:SetShown(on and true or false) end end
function NineMethods:Show() self:SetShown(true) end
function NineMethods:Hide() self:SetShown(false) end
function NineMethods:SetDesaturated(on) for _, t in pairs(self.parts) do t:SetDesaturated(on and true or false) end end
function NineMethods:SetBlendMode(mode) for _, t in pairs(self.parts) do t:SetBlendMode(mode) end end

--- This art is scaled by a non-whole number: pixel snapping would nudge neighbouring pieces apart.
-- Call it after setting the art, the way the game's own frames do.
function UI.NoSnap(t)
    if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
    if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
end

local function nineCut(n)
    local s = n.style
    local a = s.margin / s.size
    local b = 1 - a
    local p = n.parts
    local function cut(t, l, r, top, bot)
        if t then
            t:SetTexture(s.path)
            t:SetTexCoord(l, r, top, bot)
            UI.NoSnap(t)
        end
    end
    cut(p.tl, 0, a, 0, a); cut(p.t, a, b, 0, a); cut(p.tr, b, 1, 0, a)
    cut(p.l, 0, a, a, b); cut(p.c, a, b, a, b); cut(p.r, b, 1, a, b)
    cut(p.bl, 0, a, b, 1); cut(p.b, a, b, b, 1); cut(p.br, b, 1, b, 1)
end

-- corners keep their full size until the frame is too small for two of them
local function nineFit(n)
    local s = n.style
    local o = s.outset or 0
    local want = s.margin * s.texel
    local w, h = n.target:GetWidth() or 0, n.target:GetHeight() or 0
    local d = want
    if w > 0 then d = min(d, (w + o * 2) / 2) end
    if h > 0 then d = min(d, (h + o * 2) / 2) end
    if d == n.d then return end
    n.d = d
    local p = n.parts
    p.tl:SetSize(d, d); p.tr:SetSize(d, d); p.bl:SetSize(d, d); p.br:SetSize(d, d)
end

local function ninePlace(n)
    local o = n.style.outset or 0
    local p, tg = n.parts, n.target
    p.tl:ClearAllPoints(); p.tr:ClearAllPoints(); p.bl:ClearAllPoints(); p.br:ClearAllPoints()
    p.tl:SetPoint("TOPLEFT", tg, "TOPLEFT", -o, o)
    p.tr:SetPoint("TOPRIGHT", tg, "TOPRIGHT", o, o)
    p.bl:SetPoint("BOTTOMLEFT", tg, "BOTTOMLEFT", -o, -o)
    p.br:SetPoint("BOTTOMRIGHT", tg, "BOTTOMRIGHT", o, -o)
end

--- Swap the art on an existing Nine.
function NineMethods:SetStyle(name)
    local s = T.nine[name]
    if not s or s == self.style then return end
    self.style = s
    self.d = nil
    ninePlace(self)
    nineCut(self)
    nineFit(self)
end

--- Nine(owner, style, layer, sub, target) -> nine-piece skin from T.nine[style] on `owner`, fitted
-- around `target` (default owner; a frame, so it can follow size changes).
function UI:Nine(owner, style, layer, sub, target)
    local s = T.nine[style] or T.nine.card
    local n = setmetatable({ style = s, target = target or owner, parts = {} }, NineMethods)
    for _, key in ipairs(NINE_KEYS) do
        if not (key == "c" and s.hollow) then
            n.parts[key] = owner:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
        end
    end
    local p, tg = n.parts, n.target
    ninePlace(n)
    p.t:SetPoint("TOPLEFT", p.tl, "TOPRIGHT")
    p.t:SetPoint("BOTTOMRIGHT", p.tr, "BOTTOMLEFT")
    p.b:SetPoint("TOPLEFT", p.bl, "TOPRIGHT")
    p.b:SetPoint("BOTTOMRIGHT", p.br, "BOTTOMLEFT")
    p.l:SetPoint("TOPLEFT", p.tl, "BOTTOMLEFT")
    p.l:SetPoint("BOTTOMRIGHT", p.bl, "TOPRIGHT")
    p.r:SetPoint("TOPLEFT", p.tr, "BOTTOMLEFT")
    p.r:SetPoint("BOTTOMRIGHT", p.br, "TOPRIGHT")
    if p.c then
        p.c:SetPoint("TOPLEFT", p.tl, "BOTTOMRIGHT")
        p.c:SetPoint("BOTTOMRIGHT", p.br, "TOPLEFT")
    end
    nineCut(n)
    nineFit(n)
    if tg.HookScript then tg:HookScript("OnSizeChanged", function() nineFit(n) end) end
    return n
end

--- A road sign as a backing plate (T.tex.signGreen and friends, 4:1 art). It stretches sideways
-- without squashing: the ends keep their shape, sized by the plate's height, and only the plain
-- middle stretches. SignPlate(frame, path, layer, sub) -> plate with :SetTexture(path).
function UI:SignPlate(f, path, layer, sub)
    local plate = { parts = {} }
    for i, band in ipairs({ { 0, 0.125 }, { 0.125, 0.875 }, { 0.875, 1 } }) do
        local t = f:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
        t:SetTexCoord(band[1], band[2], 0, 1)
        plate.parts[i] = t
    end
    local l, m, r = plate.parts[1], plate.parts[2], plate.parts[3]
    l:SetPoint("TOPLEFT")
    l:SetPoint("BOTTOMLEFT")
    r:SetPoint("TOPRIGHT")
    r:SetPoint("BOTTOMRIGHT")
    m:SetPoint("TOPLEFT", l, "TOPRIGHT")
    m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
    local function fit()
        local cap = (f:GetHeight() or 0) * 0.5
        l:SetWidth(cap)
        r:SetWidth(cap)
    end
    f:HookScript("OnSizeChanged", fit)
    fit()
    function plate:SetTexture(p)
        for _, t in ipairs(self.parts) do
            t:SetTexture(p)
            UI.NoSnap(t)
        end
    end
    if path then plate:SetTexture(path) end
    return plate
end

--- A carved dark well for tiles and inputs inside a card: depth instead of another rim.
function UI:Well(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.skin = self:Nine(f, "inset", "BACKGROUND", -6)
    return f
end

--- Gradient(tex, orient, r, g, b, aMin, aMax): one colour fading. Min is bottom or left, max top or right.
function UI:Gradient(t, orient, r, g, b, aMin, aMax)
    t:SetTexture(WHITE)
    if t.SetGradient and CreateColor then
        t:SetGradient(orient, CreateColor(r, g, b, aMin), CreateColor(r, g, b, aMax))
    else
        t:SetVertexColor(r, g, b, (aMin + aMax) / 2)
    end
    return t
end

--- Same, but fades a texture you've already set instead of painting it flat.
function UI:Gradient2(t, orient, r, g, b, aMin, aMax)
    if t.SetGradient and CreateColor then
        t:SetGradient(orient, CreateColor(r, g, b, aMin), CreateColor(r, g, b, aMax))
    else
        t:SetAlpha((aMin + aMax) / 2)
    end
    return t
end

--- Fine rule, 1 UI unit high, that fades out to the right unless fade = "none". Anchor it yourself.
function UI:Hairline(parent, color, alpha, fade, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    local c = col(color or "line")
    alpha = alpha or 0.8
    t:SetHeight(1)
    if fade == "none" then
        t:SetColorTexture(c[1], c[2], c[3], alpha)
    else
        self:Gradient(t, "HORIZONTAL", c[1], c[2], c[3], alpha, 0)
    end
    return t
end

--- A repeating material (T.tex.leather, parchment, noise) filling `f`, inset by `inset`.
function UI:Tiled(f, path, r, g, b, a, inset, layer, sub)
    local t = f:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 1)
    t:SetTexture(path, "REPEAT", "REPEAT")
    t:SetHorizTile(true)
    t:SetVertTile(true)
    inset = inset or 0
    t:SetPoint("TOPLEFT", inset, -inset)
    t:SetPoint("BOTTOMRIGHT", -inset, inset)
    t:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
    return t
end

--- A dark gradient behind text or controls on art. side = "LEFT", "RIGHT", "TOP" or "BOTTOM": the
-- edge it starts dark from. size is how far it reaches; it covers `f` the other way.
function UI:Scrim(f, side, size, alpha, layer, sub)
    local t = f:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 3)
    alpha = alpha or 0.6
    local r, g, b = 0.012, 0.018, 0.035
    if side == "LEFT" or side == "RIGHT" then
        t:SetPoint("TOP" .. side)
        t:SetPoint("BOTTOM" .. side)
        t:SetWidth(size)
        self:Gradient(t, "HORIZONTAL", r, g, b, side == "LEFT" and alpha or 0, side == "LEFT" and 0 or alpha)
    else
        t:SetPoint(side .. "LEFT")
        t:SetPoint(side .. "RIGHT")
        t:SetHeight(size)
        self:Gradient(t, "VERTICAL", r, g, b, side == "BOTTOM" and alpha or 0, side == "BOTTOM" and 0 or alpha)
    end
    return t
end

--- Soft drop shadow around a frame (native nine-slice when available).
function UI:Shadow(f, size)
    size = size or 14
    local s = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    sliced(s, T.tex.shadow, 20)
    s:SetVertexColor(0, 0, 0, 0.85)
    s:SetPoint("TOPLEFT", -size, size)
    s:SetPoint("BOTTOMRIGHT", size, -size)
    f.shadow = s
    return s
end

function UI:Divider(parent, color)
    local t = parent:CreateTexture(nil, "ARTWORK")
    local c = col(color or "line")
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    t:SetHeight(1)
    return t
end

-------------------------------------------------------------------------------
-- Tooltips
-------------------------------------------------------------------------------
--- Tip(owner, title, lines, anchor). lines: strings, or {left, right} pairs.
function UI:Tip(owner, title, lines, anchor)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    if title then GameTooltip:AddLine(title, 1, 1, 1) end
    if type(lines) == "string" then lines = { lines } end
    for _, l in ipairs(lines or {}) do
        if type(l) == "table" then
            GameTooltip:AddDoubleLine(l[1], l[2], 0.8, 0.85, 0.82, 1, 1, 1)
        else
            GameTooltip:AddLine(l, 0.75, 0.82, 0.78, true)
        end
    end
    GameTooltip:Show()
end

function UI:HideTip() if GameTooltip then GameTooltip:Hide() end end

local function attachTip(f, tip)
    if not tip then return end
    f:HookScript("OnEnter", function(self)
        local t = tip
        if type(tip) == "function" then t = tip(self) end
        if not t then return end
        if type(t) == "table" then UI:Tip(self, t[1], t[2]) else UI:Tip(self, nil, { tostring(t) }) end
    end)
    f:HookScript("OnLeave", function() UI:HideTip() end)
end
UI.AttachTip = attachTip

-------------------------------------------------------------------------------
-- Animation helpers
-------------------------------------------------------------------------------
function UI:FadeIn(f, dur)
    if not f.fadeIn then
        local ag = f:CreateAnimationGroup()
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(0)
        a:SetToAlpha(1)
        a:SetDuration(dur or 0.18)
        a:SetSmoothing("OUT")
        f.fadeIn = ag
    end
    f:SetAlpha(1)
    f.fadeIn:Stop()
    f.fadeIn:Play()
end

function UI:Pulse(f, loops)
    if not f.pulse then
        local ag = f:CreateAnimationGroup()
        local a1 = ag:CreateAnimation("Alpha")
        a1:SetFromAlpha(1); a1:SetToAlpha(0.35); a1:SetDuration(0.45); a1:SetOrder(1); a1:SetSmoothing("IN_OUT")
        local a2 = ag:CreateAnimation("Alpha")
        a2:SetFromAlpha(0.35); a2:SetToAlpha(1); a2:SetDuration(0.45); a2:SetOrder(2); a2:SetSmoothing("IN_OUT")
        ag:SetLooping("REPEAT")
        f.pulse = ag
    end
    f.pulse:Play()
    if loops then GF:After(loops * 0.9, function() if f.pulse then f.pulse:Stop(); f:SetAlpha(1) end end) end
end

-------------------------------------------------------------------------------
-- Buttons
-------------------------------------------------------------------------------
-- Lit bezel over a painted face (Media/btn_*.tga); ghost stays flat. Green is for the one thing
-- a screen wants you to press; secondary is matte, so it doesn't compete.
local STYLES = {
    primary = { nine = "btnGreen", text = { 1, 1, 1, 1 } },
    secondary = { nine = "btnDark", text = C.gold },
    ghost = { bg = { 0, 0, 0, 0 }, hover = { 1, 0.9, 0.68, 0.07 }, text = C.dim, textHover = C.text, border = { 0, 0, 0, 0 } },
    danger = { nine = "btnRed", text = { 1, 1, 1, 1 } },
    warn = { nine = "btnGold", text = { 0.11, 0.07, 0.02, 1 } },
    sign = { nine = "btnGreen", text = { 1, 1, 1, 1 } },
}
UI.ButtonStyles = STYLES

local function applyButtonColors(b, hover)
    local s = b.style
    if s.nine then
        b:SetBackdropColor(0, 0, 0, 0)
        b:SetBackdropBorderColor(0, 0, 0, 0)
        b.face:SetStyle(s.nine)
        b.face:Show()
        b.hl:Show()
        b.hl:SetAlpha(hover and 0.30 or 0)
    else
        b.face:Hide()
        b.hl:Hide()
        local bg = hover and s.hover or s.bg
        b:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
        b:SetBackdropBorderColor(s.border[1], s.border[2], s.border[3], s.border[4] or 1)
    end
    local tc = (hover and s.textHover) or s.text
    if b.inactive then tc = C.dim end
    b.label:SetTextColor(tc[1], tc[2], tc[3], tc[4] or 1)
    if b.icon and not b.icon.isGameIcon then b.icon:SetVertexColor(tc[1], tc[2], tc[3], tc[4] or 1) end
end

--- Button(parent, text, {style, icon, width, height, size, onClick, tooltip, upper})
function UI:Button(parent, text, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetHeight(opts.height or 26)
    self:SetBackdrop(b, C.bg3, C.line)
    b.face = self:Nine(b, "btnDark", "BACKGROUND", 1)
    b.hl = self:Nine(b, "btnHl", "ARTWORK", -1)
    b.hl:SetBlendMode("ADD")
    b.hl:SetAlpha(0)
    b.style = STYLES[opts.style or "secondary"] or STYLES.secondary
    b.opts = opts
    b.label = self:Text(b, opts.size or 12, b.style.text, "ui")
    b.label:SetJustifyH("CENTER")
    if opts.icon then
        b.icon = self:Icon(b, opts.iconSize or 14, opts.icon)
    end
    if opts.rightClick then b:RegisterForClicks("LeftButtonUp", "RightButtonUp") else b:RegisterForClicks("LeftButtonUp") end

    function b:Layout()
        local w = self.label:GetStringWidth() or 0
        local hasText = (self.label:GetText() or "") ~= ""
        self.label:ClearAllPoints()
        if self.icon then
            self.icon:ClearAllPoints()
            if hasText then
                local total = (self.icon:GetWidth() or 14) + 6 + w
                self.icon:SetPoint("LEFT", self, "CENTER", -total / 2, 0)
                self.label:SetPoint("LEFT", self.icon, "RIGHT", 6, 0)
            else
                self.icon:SetPoint("CENTER")
            end
        else
            self.label:SetPoint("CENTER", 0, 0)
        end
        if not self.opts.width then
            local pad = self.icon and (hasText and 34 or 12) or 24
            self:SetWidth(max(self.opts.minWidth or 0, w + pad + (self.icon and hasText and (self.icon:GetWidth() or 14) or 0)))
        end
    end

    function b:SetText(t)
        t = t or ""
        -- Friz Quadrata reads best in title case, the way the game's own buttons are
        if self.opts.upper == true then t = tostring(t):upper() end
        self.label:SetText(t)
        self:Layout()
    end

    function b:SetStyle(name)
        self.style = STYLES[name] or STYLES.secondary
        applyButtonColors(self, self:IsMouseOver())
    end

    function b:SetActive(on)
        self:SetEnabled(on and true or false)
        self.inactive = not on
        -- a dead button stays readable: greyed metal, plain text, no see-through mud
        self.face:SetDesaturated(not on)
        self.face:SetVertexColor(on and 1 or 0.62, on and 1 or 0.62, on and 1 or 0.62, 1)
        applyButtonColors(self, false)
    end

    if opts.width then b:SetWidth(opts.width) end
    b:SetText(text)
    applyButtonColors(b, false)

    b:SetScript("OnEnter", function(self) applyButtonColors(self, true) end)
    b:SetScript("OnLeave", function(self) applyButtonColors(self, false) end)
    b:SetScript("OnMouseDown", function(self)
        if not self:IsEnabled() then return end
        self.face:SetVertexColor(0.76, 0.76, 0.76, 1)
        -- tiny press-in nudge (text-only buttons; icon layouts re-anchor on mouse up)
        if not self.icon then
            self.label:ClearAllPoints()
            self.label:SetPoint("CENTER", 0, -1)
        end
    end)
    b:SetScript("OnMouseUp", function(self)
        if self:IsEnabled() then self.face:SetVertexColor(1, 1, 1, 1) end
        self:Layout()
    end)
    b:SetScript("OnClick", function(self, button)
        sound(856)
        if self.opts.onClick then GF:Safe("button", self.opts.onClick, self, button) end
    end)
    attachTip(b, opts.tooltip)
    return b
end

--- Small square icon-only button (toolbar style).
function UI:IconButton(parent, icon, size, tooltip, onClick, color)
    size = size or 24
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    sliced(b.bg, T.tex.round6, 6)
    b.bg:SetVertexColor(1, 1, 1, 0)
    b.icon = self:Icon(b, floor(size * 0.6), icon)
    b.icon:SetPoint("CENTER")
    local base = col(color or "dim")
    b.baseColor = base
    if not b.icon.isGameIcon then b.icon:SetVertexColor(base[1], base[2], base[3], base[4] or 1) end
    b:SetScript("OnEnter", function(self)
        self.bg:SetVertexColor(1, 1, 1, 0.08)
        if not self.icon.isGameIcon then self.icon:SetVertexColor(1, 1, 1, 1) end
    end)
    b:SetScript("OnLeave", function(self)
        self.bg:SetVertexColor(1, 1, 1, 0)
        local c = self.baseColor
        if not self.icon.isGameIcon then self.icon:SetVertexColor(c[1], c[2], c[3], c[4] or 1) end
    end)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function(self, button)
        sound(856)
        if onClick then GF:Safe("iconbutton", onClick, self, button) end
    end)
    function b:SetColor(c)
        self.baseColor = col(c)
        if not self.icon.isGameIcon then self.icon:SetVertexColor(self.baseColor[1], self.baseColor[2], self.baseColor[3], self.baseColor[4] or 1) end
    end
    attachTip(b, tooltip)
    return b
end

-------------------------------------------------------------------------------
-- Inputs
-------------------------------------------------------------------------------
--- Input(parent, {placeholder, width, height, onChange(text), onEnter(text), max, numeric, icon, multiline})
function UI:Input(parent, opts)
    opts = opts or {}
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetHeight(opts.height or 26)
    if opts.width then box:SetWidth(opts.width) end
    box:SetAutoFocus(false)
    box:SetMaxLetters(opts.max or 255)
    T:Font(box, "body", opts.size or 12)
    box:SetTextColor(C.text[1], C.text[2], C.text[3], 1)
    self:SetBackdrop(box, { 0, 0, 0, 0 }, { 0, 0, 0, 0 })
    box.well = self:Nine(box, "inset", "BACKGROUND", -6)
    -- focus: a gold edge along the bottom, the way a selected tab shows it
    box.focusRim = box:CreateTexture(nil, "ARTWORK")
    box.focusRim:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.8)
    box.focusRim:SetHeight(2)
    box.focusRim:SetPoint("BOTTOMLEFT", 3, 0)
    box.focusRim:SetPoint("BOTTOMRIGHT", -3, 0)
    box.focusRim:Hide()
    local left = 8
    if opts.icon then
        box.icon = self:Icon(box, 13, opts.icon, "OVERLAY", "faint")
        box.icon:SetPoint("LEFT", 8, 0)
        left = 26
    end
    box:SetTextInsets(left, opts.clear and 24 or 8, 0, 0)
    if opts.numeric then box:SetNumeric(true) end
    box.placeholder = self:Text(box, opts.size or 12, "faint")
    box.placeholder:SetPoint("LEFT", left, 0)
    -- bounded so a long hint truncates inside the box instead of spilling past it
    box.placeholder:SetPoint("RIGHT", opts.clear and -24 or -8, 0)
    box.placeholder:SetText(opts.placeholder or "")

    local function refreshPlaceholder(self)
        local empty = (self:GetText() or "") == ""
        self.placeholder:SetShown(empty and not self:HasFocus())
        if self.clearBtn then self.clearBtn:SetShown(not empty) end
    end
    box.RefreshPlaceholder = refreshPlaceholder

    if opts.clear then
        box.clearBtn = self:IconButton(box, "close", 18, nil, function()
            box:SetText("")
            box:ClearFocus()
            if opts.onChange then opts.onChange("") end
            refreshPlaceholder(box)
        end)
        box.clearBtn:SetPoint("RIGHT", -4, 0)
        box.clearBtn:Hide()
    end

    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self)
        if opts.onEnter then GF:Safe("input", opts.onEnter, self:GetText(), self) end
        if not opts.keepFocus then self:ClearFocus() end
    end)
    box:SetScript("OnEditFocusGained", function(self)
        self.focusRim:Show()
        refreshPlaceholder(self)
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self.focusRim:Hide()
        refreshPlaceholder(self)
    end)
    box:SetScript("OnTextChanged", function(self, user)
        refreshPlaceholder(self)
        if user and opts.onChange then
            if opts.debounce then
                GF:Debounce(tostring(self) .. "change", opts.debounce, function() opts.onChange(self:GetText(), self) end)
            else
                GF:Safe("input", opts.onChange, self:GetText(), self)
            end
        end
    end)
    refreshPlaceholder(box)
    return box
end

function UI:Search(parent, opts)
    opts = opts or {}
    opts.icon = "search"
    opts.clear = true
    opts.debounce = opts.debounce or 0.15
    opts.placeholder = opts.placeholder or "Search..."
    return self:Input(parent, opts)
end

-------------------------------------------------------------------------------
-- Toggle switch
-------------------------------------------------------------------------------
--- Toggle(parent, label, {get() -> bool, set(bool), tooltip})
function UI:Toggle(parent, label, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(22)
    b.track = b:CreateTexture(nil, "ARTWORK")
    b.track:SetSize(36, 18)
    b.track:SetPoint("LEFT")
    b.knob = b:CreateTexture(nil, "OVERLAY")
    b.knob:SetSize(14, 14)
    b.label = self:Text(b, 12, "text")
    b.label:SetPoint("LEFT", b.track, "RIGHT", 10, 0)
    b.label:SetText(label or "")
    b:SetWidth(36 + 10 + (b.label:GetStringWidth() or 0) + 4)

    function b:SetChecked(on)
        self.checked = on and true or false
        self.knob:ClearAllPoints()
        if self.checked then
            self.track:SetTexture(T.tex.toggleOn)
            self.knob:SetTexture(T.tex.knobOn)
            self.knob:SetPoint("RIGHT", self.track, "RIGHT", -2, 0)
        else
            self.track:SetTexture(T.tex.toggleOff)
            self.knob:SetTexture(T.tex.knobOff)
            self.knob:SetPoint("LEFT", self.track, "LEFT", 2, 0)
        end
    end
    function b:GetChecked() return self.checked end
    function b:Refresh() if opts.get then self:SetChecked(opts.get()) end end

    b:SetScript("OnClick", function(self)
        self:SetChecked(not self.checked)
        sound(self.checked and 856 or 857)
        if opts.set then GF:Safe("toggle", opts.set, self.checked) end
    end)
    b:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 1, 1, 1) end)
    b:SetScript("OnLeave", function(self) UI:SetTextColor(self.label, "text") end)
    attachTip(b, opts.tooltip)
    b:Refresh()
    if b.checked == nil then b:SetChecked(false) end
    return b
end

-------------------------------------------------------------------------------
-- Menu popup (dropdowns + context menus)
-------------------------------------------------------------------------------
local menu, catcher
local MENU_ROW, MENU_MAX = 22, 16
local MENU_TITLE, MENU_SEP, MENU_MORE = 20, 9, 12

local function buildMenu()
    catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:SetAllPoints(UIParent)
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", function() UI:CloseMenu() end)
    catcher:Hide()

    menu = CreateFrame("Frame", "GreenfieldsMenu", UIParent, "BackdropTemplate")
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    UI:SetBackdrop(menu, { 0, 0, 0, 0 }, false)
    UI:Shadow(menu, 10)
    -- the card art is a touch see-through; a popup over the header's sign can't be
    menu.fill = menu:CreateTexture(nil, "BACKGROUND", nil, -7)
    menu.fill:SetColorTexture(0.055, 0.075, 0.11, 1)
    menu.fill:SetPoint("TOPLEFT", 1, -1)
    menu.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    menu.rim = UI:Nine(menu, "card", "BACKGROUND", -6)
    menu.rows = {}
    menu.offset = 0
    menu:EnableMouseWheel(true)
    menu:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = max(0, #self.items - MENU_MAX)
        self.offset = U.Clamp(self.offset - delta, 0, maxOff)
        self:Refresh()
    end)
    menu:Hide()
    tinsert(UISpecialFrames, "GreenfieldsMenu")
    menu:SetScript("OnHide", function() catcher:Hide() end)

    -- only shown on lists too long for the menu: says there's more to wheel through
    menu.more = UI:Icon(menu, 12, "chevron_down", "OVERLAY", "bronze")
    menu.more:SetPoint("BOTTOM", 0, 3)
    menu.more:Hide()

    function menu:Refresh()
        local y = 4
        for i = 1, MENU_MAX do
            local row = self.rows[i]
            local item = self.items[i + self.offset]
            if row then
                if item then
                    row.item = item
                    local h = (item.separator and MENU_SEP) or (item.title and MENU_TITLE) or MENU_ROW
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", 4, -y)
                    row:SetPoint("TOPRIGHT", -4, -y)
                    row:SetHeight(h)
                    y = y + h
                    if item.title then T:Font(row.text, "ui", 11) else T:Font(row.text, "body", 12) end
                    row.text:SetText(item.text or "")
                    local c = item.title and C.bronze or (item.disabled and C.faint) or col(item.color or "text")
                    row.text:SetTextColor(c[1], c[2], c[3], c[4] or 1)
                    if item.icon then
                        UI:SetIcon(row.icon, item.icon)
                        if row.icon.isGameIcon then row.icon:SetVertexColor(1, 1, 1, 1) else row.icon:SetVertexColor(C.dim[1], C.dim[2], C.dim[3], 1) end
                        row.icon:Show()
                        row.text:SetPoint("LEFT", 28, 0)
                    else
                        row.icon:Hide()
                        row.text:SetPoint("LEFT", 10, 0)
                    end
                    local sel = (item.checked) or (self.selected ~= nil and item.value ~= nil and item.value == self.selected)
                    row.check:SetShown(sel and true or false)
                    row.sep:SetShown(item.separator and true or false)
                    row:SetEnabled(not item.title and not item.disabled and not item.separator)
                    row:Show()
                else
                    row:Hide()
                end
            end
        end
        local long = #self.items > MENU_MAX
        self.more:SetShown(long and self.offset < #self.items - MENU_MAX)
        self:SetHeight(y + (long and MENU_MORE or 4))
    end
end

local function menuRow()
    local row = CreateFrame("Button", nil, menu)
    row:SetHeight(MENU_ROW)
    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints()
    row.hl:SetColorTexture(1, 0.82, 0.42, 0.10)
    row.hl:Hide()
    row.icon = UI:Icon(row, 14, nil)
    row.icon:SetPoint("LEFT", 8, 0)
    row.text = UI:Text(row, 12, "text")
    row.text:SetPoint("LEFT", 10, 0)
    row.text:SetPoint("RIGHT", -24, 0)
    row.check = UI:Icon(row, 12, "check", "OVERLAY", "gold")
    row.check:SetPoint("RIGHT", -6, 0)
    row.sep = row:CreateTexture(nil, "ARTWORK")
    row.sep:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.35)
    row.sep:SetHeight(1)
    row.sep:SetPoint("LEFT", 6, 0)
    row.sep:SetPoint("RIGHT", -6, 0)
    row:SetScript("OnEnter", function(self) if self:IsEnabled() then self.hl:Show() end end)
    row:SetScript("OnLeave", function(self) self.hl:Hide() end)
    row:SetScript("OnClick", function(self)
        local item = self.item
        UI:CloseMenu()
        if not item then return end
        sound(856)
        if item.func then GF:Safe("menu", item.func, item) end
        if menu.onPick then GF:Safe("menu", menu.onPick, item) end
    end)
    return row
end

--- OpenMenu(anchor, items, {onPick(item), selected, width, point})
-- items: { {text=, value=, icon=, color=, func=, checked=, disabled=, title=, separator=} }
function UI:OpenMenu(anchor, items, opts)
    if not menu then buildMenu() end
    opts = opts or {}
    if menu:IsShown() and menu.anchor == anchor then self:CloseMenu() return end
    menu.items = items or {}
    menu.onPick = opts.onPick
    menu.selected = opts.selected
    menu.anchor = anchor
    menu.offset = 0
    local n = min(#menu.items, MENU_MAX)
    for i = #menu.rows + 1, n do menu.rows[i] = menuRow() end
    local w = opts.width or (anchor and anchor:GetWidth() or 160)
    local probe = menu.rows[1] and menu.rows[1].text
    if probe then T:Font(probe, "body", 12) end
    for _, item in ipairs(menu.items) do
        if probe and item.text then
            probe:SetText(item.text)
            w = max(w, (probe:GetStringWidth() or 0) + (item.icon and 60 or 44))
        end
    end
    menu:SetWidth(min(w, 360))
    menu:ClearAllPoints()
    if anchor then
        menu:SetPoint(opts.point or "TOPLEFT", anchor, opts.relPoint or "BOTTOMLEFT", 0, -2)
    else
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, y / s)
    end
    menu:Refresh()
    catcher:Show()
    menu:Show()
    menu:Raise()
end

function UI:CloseMenu()
    if menu then menu:Hide() end
    if catcher then catcher:Hide() end
end

-------------------------------------------------------------------------------
-- Dropdown
-------------------------------------------------------------------------------
--- Dropdown(parent, {items = list | fn() -> list, get() -> value, set(value, item), width, placeholder})
function UI:Dropdown(parent, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(opts.width or 160, opts.height or 26)
    self:SetBackdrop(b, { 0, 0, 0, 0 }, { 0, 0, 0, 0 })
    b.well = self:Nine(b, "inset", "BACKGROUND", -6)
    b.hoverRim = b:CreateTexture(nil, "ARTWORK")
    b.hoverRim:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.55)
    b.hoverRim:SetHeight(1)
    b.hoverRim:SetPoint("BOTTOMLEFT", 3, 0)
    b.hoverRim:SetPoint("BOTTOMRIGHT", -3, 0)
    b.hoverRim:Hide()
    b.icon = self:Icon(b, 14, nil)
    b.icon:SetPoint("LEFT", 8, 0)
    b.icon:Hide()
    b.text = self:Text(b, 12, "text")
    b.text:SetPoint("LEFT", 8, 0)
    b.text:SetPoint("RIGHT", -22, 0)
    b.chev = self:Icon(b, 12, "chevron_down", "OVERLAY", "bronze")
    b.chev:SetPoint("RIGHT", -8, 0)

    local function items() return type(opts.items) == "function" and opts.items() or opts.items or {} end

    function b:Refresh()
        local v = opts.get and opts.get()
        local found
        for _, it in ipairs(items()) do if it.value == v then found = it break end end
        if found then
            self.text:SetText(found.text or tostring(v))
            local c = col(found.color or "text")
            self.text:SetTextColor(c[1], c[2], c[3], c[4] or 1)
            if found.icon then
                UI:SetIcon(self.icon, found.icon)
                self.icon:Show()
                self.text:SetPoint("LEFT", 28, 0)
            else
                self.icon:Hide()
                self.text:SetPoint("LEFT", 8, 0)
            end
        else
            self.text:SetText(opts.placeholder or "Choose...")
            UI:SetTextColor(self.text, "faint")
            self.icon:Hide()
            self.text:SetPoint("LEFT", 8, 0)
        end
    end

    b:SetScript("OnClick", function(self)
        UI:OpenMenu(self, items(), {
            selected = opts.get and opts.get(),
            onPick = function(item)
                if opts.set then opts.set(item.value, item) end
                self:Refresh()
            end,
        })
    end)
    b:SetScript("OnEnter", function(self) if self:IsEnabled() then self.hoverRim:Show() end end)
    b:SetScript("OnLeave", function(self) self.hoverRim:Hide() end)
    --- Locked controls look locked: dimmed, no chevron, and the value stays readable.
    function b:SetLocked(on)
        self:SetEnabled(not on)
        self.chev:SetShown(not on)
        self:SetAlpha(on and 0.6 or 1)
    end
    attachTip(b, opts.tooltip)
    b:Refresh()
    return b
end

-------------------------------------------------------------------------------
-- Scrollbar (shared by List and Scroll)
-------------------------------------------------------------------------------
local function makeScrollbar(owner, onScroll)
    local bar = CreateFrame("Frame", nil, owner)
    bar:SetWidth(6)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    bar.track = UI:Nine(bar, "pill", "BACKGROUND")
    bar.track:SetVertexColor(0, 0, 0, 0.34)
    bar.thumb = CreateFrame("Button", nil, bar)
    bar.thumb:SetWidth(6)
    bar.thumb.tex = UI:Nine(bar.thumb, "pill", "ARTWORK")
    bar.thumb.tex:SetVertexColor(C.bronze[1], C.bronze[2], C.bronze[3], 0.62)
    bar.thumb:SetScript("OnEnter", function(self) self.tex:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.9) end)
    bar.thumb:SetScript("OnLeave", function(self) if not self.dragging then self.tex:SetVertexColor(C.bronze[1], C.bronze[2], C.bronze[3], 0.62) end end)
    bar.thumb:RegisterForDrag("LeftButton")
    bar.thumb:SetScript("OnDragStart", function(self)
        self.dragging = true
        local _, y = GetCursorPosition()
        self.startY = y / bar:GetEffectiveScale()
        self.startFrac = bar.frac or 0
        self:SetScript("OnUpdate", function()
            local _, cy = GetCursorPosition()
            cy = cy / bar:GetEffectiveScale()
            local travel = max(1, bar:GetHeight() - self:GetHeight())
            local frac = U.Clamp(self.startFrac + (self.startY - cy) / travel, 0, 1)
            onScroll(frac)
        end)
    end)
    bar.thumb:SetScript("OnDragStop", function(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
        self.tex:SetVertexColor(C.bronze[1], C.bronze[2], C.bronze[3], 0.62)
    end)
    --- visibleFrac: portion of content visible (0..1], frac: scroll position 0..1
    function bar:Update(visibleFrac, frac)
        if visibleFrac >= 1 then self:Hide() return end
        self:Show()
        self.frac = frac
        local h = self:GetHeight()
        local th = max(20, h * visibleFrac)
        self.thumb:SetHeight(th)
        self.thumb:ClearAllPoints()
        self.thumb:SetPoint("TOP", self, "TOP", 0, -(h - th) * frac)
    end
    return bar
end

-------------------------------------------------------------------------------
-- Virtual list
-------------------------------------------------------------------------------
--- List(parent, {rowHeight, spacing, createRow(row), updateRow(row, item, index),
---               onClick(item, row, button), isSelected(item), onEnter(row,item), onLeave(row,item)})
-- The kit owns row.item, row.index, row.bg, row.hl, row.sel and row.selBar - use other
-- field names in createRow.
function UI:List(parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, parent)
    f.rowHeight = opts.rowHeight or 28
    f.spacing = opts.spacing or 2
    f.rows, f.items, f.offset = {}, {}, 0
    f:SetClipsChildren(true)
    f:EnableMouseWheel(true)

    f.bar = makeScrollbar(f, function(frac)
        local maxOff = max(0, #f.items - f:VisibleCount() + 1)
        f.offset = floor(frac * maxOff + 0.5)
        f:Refresh()
    end)

    -- the half-cut last row fades into the card, and says "there's more"
    f.fade = CreateFrame("Frame", nil, f)
    f.fade:SetPoint("BOTTOMLEFT")
    f.fade:SetPoint("BOTTOMRIGHT", -10, 0)
    f.fade:SetHeight(26)
    f.fade:SetFrameLevel(f:GetFrameLevel() + 30)
    f.fade:EnableMouse(false)
    self:Gradient(f.fade:CreateTexture(nil, "OVERLAY"), "VERTICAL", CARD_R, CARD_G, CARD_B, 0.97, 0):SetAllPoints()
    f.fade:Hide()

    function f:VisibleCount()
        local h = self:GetHeight() or 0
        return max(1, floor(h / (self.rowHeight + self.spacing)))
    end

    local function makeRow(i)
        local row = CreateFrame("Button", nil, f)
        row:SetHeight(f.rowHeight)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * (f.rowHeight + f.spacing))
        row:SetPoint("TOPRIGHT", -10, -(i - 1) * (f.rowHeight + f.spacing))
        -- rows are lines on the page, not boxes: a faint wash and a hairline under each
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 0.96, 0.86, opts.zebra == false and 0 or 0.016)
        row.rule = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.rule:SetPoint("BOTTOMLEFT")
        row.rule:SetPoint("BOTTOMRIGHT")
        row.rule:SetHeight(1)
        row.rule:SetColorTexture(C.line[1], C.line[2], C.line[3], opts.zebra == false and 0 or 0.36)
        row.hl = row:CreateTexture(nil, "BACKGROUND", nil, 2)
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 0.90, 0.68, 0.055)
        row.hl:Hide()
        row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 3)
        row.sel:SetAllPoints()
        row.sel:SetTexture(WHITE)
        if row.sel.SetGradient and CreateColor then
            row.sel:SetGradient("HORIZONTAL", CreateColor(1, 0.80, 0.30, 0.18), CreateColor(1, 0.80, 0.30, 0.03))
        else
            row.sel:SetVertexColor(1, 0.80, 0.30, 0.10)
        end
        row.sel:Hide()
        row.selBar = row:CreateTexture(nil, "ARTWORK")
        row.selBar:SetPoint("TOPLEFT")
        row.selBar:SetPoint("BOTTOMLEFT")
        row.selBar:SetWidth(2)
        row.selBar:SetColorTexture(C.wowGold[1], C.wowGold[2], C.wowGold[3], 1)
        row.selBar:Hide()
        --- A coloured left edge (a status, a class): SetEdge(color) or SetEdge(nil).
        function row:SetEdge(color)
            if not color then
                if self.edge then self.edge:Hide() end
                return
            end
            if not self.edge then
                self.edge = self:CreateTexture(nil, "ARTWORK")
                self.edge:SetPoint("TOPLEFT")
                self.edge:SetPoint("BOTTOMLEFT")
                self.edge:SetWidth(2)
            end
            local c = col(color)
            self.edge:SetColorTexture(c[1], c[2], c[3], c[4] or 0.9)
            self.edge:Show()
        end
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnEnter", function(self)
            self.hl:Show()
            if opts.onEnter and self.item then GF:Safe("list:enter", opts.onEnter, self, self.item) end
        end)
        row:SetScript("OnLeave", function(self)
            self.hl:Hide()
            if opts.onLeave and self.item then GF:Safe("list:leave", opts.onLeave, self, self.item) else UI:HideTip() end
        end)
        row:SetScript("OnClick", function(self, button)
            if self.item and opts.onClick then GF:Safe("list:click", opts.onClick, self.item, self, button) end
        end)
        if opts.createRow then GF:Safe("list:create", opts.createRow, row) end
        return row
    end

    function f:Refresh()
        local vis = self:VisibleCount() + 1
        for i = #self.rows + 1, vis do self.rows[i] = makeRow(i) end
        local maxOff = max(0, #self.items - self:VisibleCount())
        if self.offset > maxOff then self.offset = maxOff end
        if self.offset < 0 then self.offset = 0 end
        for i, row in ipairs(self.rows) do
            local idx = self.offset + i
            local item = self.items[idx]
            if item and i <= vis then
                row.item, row.index = item, idx
                local sel = opts.isSelected and opts.isSelected(item) or false
                row.sel:SetShown(sel)
                row.selBar:SetShown(sel)
                if opts.updateRow then GF:Safe("list:update", opts.updateRow, row, item, idx) end
                row:Show()
            else
                row.item = nil
                row:Hide()
            end
        end
        local total = #self.items
        local visible = self:VisibleCount()
        self.bar:Update(total > 0 and visible / total or 1, maxOff > 0 and self.offset / maxOff or 0)
        self.fade:SetShown(self.offset < maxOff)
    end

    function f:SetItems(items, keepOffset)
        self.items = items or {}
        if not keepOffset then self.offset = 0 end
        self:Refresh()
    end

    function f:ScrollTo(index)
        local vis = self:VisibleCount()
        if index <= self.offset then self.offset = index - 1
        elseif index > self.offset + vis then self.offset = index - vis end
        self:Refresh()
    end

    f:SetScript("OnMouseWheel", function(self, delta)
        self.offset = self.offset - delta * 3
        self:Refresh()
    end)
    f:SetScript("OnSizeChanged", function(self) self:Refresh() end)
    return f
end

-------------------------------------------------------------------------------
-- Free-form scroll area
-------------------------------------------------------------------------------
--- Scroll(parent, {outside, inCard}) -> scrollFrame, content. Call scroll:SetContentHeight(h) after
-- layout. outside = true hangs the scrollbar in the gutter, so content keeps its full width. What's
-- clipped fades out: into a card's own colour inside a card (the default unless outside, or inCard
-- says so), into the night on the page itself.
function UI:Scroll(parent, opts)
    opts = opts or {}
    local sf = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(1, 1)
    sf:SetScrollChild(content)
    sf.content = content
    sf.contentHeight = 0
    sf.bar = makeScrollbar(sf, function(frac)
        local maxScroll = max(0, sf.contentHeight - sf:GetHeight())
        sf:SetVerticalScroll(frac * maxScroll)
        sf:UpdateBar()
    end)
    if opts.outside then
        sf.bar:ClearAllPoints()
        sf.bar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 7, 0)
        sf.bar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 7, 0)
    end
    local fades = CreateFrame("Frame", nil, sf)
    fades:SetAllPoints()
    fades:SetFrameLevel(sf:GetFrameLevel() + 30)
    fades:EnableMouse(false)
    sf.fadeBottom = self:Scrim(fades, "BOTTOM", 26, 0.82, "OVERLAY")
    sf.fadeTop = self:Scrim(fades, "TOP", 18, 0.7, "OVERLAY")
    if opts.inCard or not opts.outside then
        self:Gradient(sf.fadeBottom, "VERTICAL", CARD_R, CARD_G, CARD_B, 0.97, 0)
        self:Gradient(sf.fadeTop, "VERTICAL", CARD_R, CARD_G, CARD_B, 0, 0.97)
    end
    sf.fadeTop:Hide()
    sf.fadeBottom:Hide()
    function sf:UpdateBar()
        local h = self:GetHeight() or 1
        local maxScroll = max(0, self.contentHeight - h)
        local cur = U.Clamp(self:GetVerticalScroll() or 0, 0, maxScroll)
        if cur ~= self:GetVerticalScroll() then self:SetVerticalScroll(cur) end
        self.bar:Update(self.contentHeight > 0 and h / self.contentHeight or 1, maxScroll > 0 and cur / maxScroll or 0)
        self.fadeTop:SetShown(cur > 1)
        self.fadeBottom:SetShown(cur < maxScroll - 1)
    end
    function sf:SetContentHeight(h)
        self.contentHeight = h or 0
        content:SetHeight(max(1, self.contentHeight))
        self:UpdateBar()
    end
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = max(0, self.contentHeight - self:GetHeight())
        self:SetVerticalScroll(U.Clamp((self:GetVerticalScroll() or 0) - delta * 48, 0, maxScroll))
        self:UpdateBar()
    end)
    sf:SetScript("OnSizeChanged", function(self, w)
        content:SetWidth(max(1, (w or self:GetWidth() or 1) - (opts.outside and 0 or 12)))
        self:UpdateBar()
    end)
    return sf, content
end

-------------------------------------------------------------------------------
-- Cards, pills, bars
-------------------------------------------------------------------------------
--- Card(parent, {title, icon, accent, subtitle, tier}) -> card; card.body is the area under the header.
-- Rank decides the rim, so gold keeps its meaning: tier "hero" is the gold rim, for the one thing a
-- page is about; the default is one fine lit edge and a soft drop; "plain" has no skin at all.
-- Never nest cards: use UI:Well for tiles inside one.
function UI:Card(parent, opts)
    opts = opts or {}
    local c = self:Panel(parent, { 0, 0, 0, 0 }, false)
    local tier = opts.tier or (opts.hero and "hero") or "card"
    if tier ~= "plain" then
        c.skin = self:Nine(c, tier == "hero" and "gold" or "card", "BACKGROUND", -6)
        c.rim = c.skin
    end
    c.body = CreateFrame("Frame", nil, c)
    if opts.title then
        -- kept for callers that recolour it; the icon carries the accent now
        local bar = c:CreateTexture(nil, "ARTWORK")
        bar:SetSize(1, 1)
        bar:SetPoint("TOPLEFT")
        bar:Hide()
        c.accent = bar
        local x = 12
        if opts.icon then
            c.icon = self:Icon(c, 14, opts.icon, "ARTWORK", opts.iconColor or opts.accent or "bronze")
            c.icon:SetPoint("TOPLEFT", 12, -11)
            x = 32
        end
        c.title = self:Text(c, 13, "wowGold", "ui")
        c.title:SetPoint("TOPLEFT", x, -11)
        c.title:SetText(tostring(opts.title))
        if opts.subtitle then
            c.subtitle = self:Text(c, 11, "faint")
            c.subtitle:SetPoint("LEFT", c.title, "RIGHT", 8, 0)
            c.subtitle:SetText(opts.subtitle)
        end
        c.right = CreateFrame("Frame", nil, c)
        c.right:SetSize(1, 22)
        c.right:SetPoint("TOPRIGHT", -12, -6)
        -- a fine rule under the title, fading to the right
        c.rule = self:Hairline(c, "bronze", 0.40)
        c.rule:SetPoint("TOPLEFT", 12, -31)
        c.rule:SetPoint("TOPRIGHT", -12, -31)
        c.body:SetPoint("TOPLEFT", 12, -38)
        c.body:SetPoint("BOTTOMRIGHT", -12, 10)
    else
        c.body:SetPoint("TOPLEFT", 12, -12)
        c.body:SetPoint("BOTTOMRIGHT", -12, 12)
    end
    function c:SetTitle(t) if self.title then self.title:SetText(tostring(t)) end end
    return c
end

--- Pill(parent, text, color, {size, icon, height, tooltip, onClick}) -> pill with :SetText(text, color)
function UI:Pill(parent, text, color, opts)
    opts = opts or {}
    local p = CreateFrame("Frame", nil, parent)
    p:SetHeight(opts.height or 18)
    p.bg = self:Nine(p, "tag", "BACKGROUND")
    p.label = self:Text(p, opts.size or 11, color or "text", "head")
    p.label:SetPoint("CENTER", opts.icon and 7 or 0, 0)
    if opts.icon then
        p.icon = self:Icon(p, 10, opts.icon)
        p.icon:SetPoint("RIGHT", p.label, "LEFT", -4, 0)
    end
    function p:SetText(t, c)
        c = col(c or self.color or "text")
        self.color = c
        self.label:SetText(t or "")
        self.label:SetTextColor(c[1], c[2], c[3], 1)
        self.bg:SetVertexColor(c[1], c[2], c[3], 1)
        if self.icon and not self.icon.isGameIcon then self.icon:SetVertexColor(c[1], c[2], c[3], 1) end
        self:SetWidth((self.label:GetStringWidth() or 0) + 16 + (self.icon and 14 or 0))
    end
    p:SetText(text, color)
    if opts.tooltip or opts.onClick then p:EnableMouse(true) end
    if opts.onClick then
        p:SetScript("OnMouseUp", function(self, button) GF:Safe("pill", opts.onClick, self, button) end)
        p:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 1, 1, 1) end)
        p:SetScript("OnLeave", function(self) local c = self.color; self.label:SetTextColor(c[1], c[2], c[3], 1) end)
    end
    attachTip(p, opts.tooltip)
    return p
end

--- Bar(parent, {height, color, text}) -> bar with :SetValue(0..1), :SetColor(c), :SetLabel(s)
function UI:Bar(parent, opts)
    opts = opts or {}
    local b = CreateFrame("Frame", nil, parent)
    b:SetHeight(opts.height or 8)
    b.track = self:Nine(b, "groove", "BACKGROUND")
    b.fill = b:CreateTexture(nil, "ARTWORK")
    b.fill:SetTexture(T.tex.barFill)
    b.fill:SetPoint("TOPLEFT", 1, -1)
    b.fill:SetPoint("BOTTOMLEFT", 1, 1)
    -- a bright lip on the leading edge
    b.lip = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.lip:SetColorTexture(1, 1, 1, 0.5)
    b.lip:SetWidth(1)
    b.lip:SetPoint("TOPRIGHT", b.fill, "TOPRIGHT")
    b.lip:SetPoint("BOTTOMRIGHT", b.fill, "BOTTOMRIGHT")
    b.value = 0
    if opts.text then
        b.text = self:Text(b, 10, "text", "num", "OUTLINE")
        b.text:SetPoint("CENTER")
    end
    function b:SetColor(c)
        c = col(c)
        self.fill:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
    end
    function b:SetValue(v)
        self.value = U.Clamp(tonumber(v) or 0, 0, 1)
        local w = max(0, (self:GetWidth() or 0) - 2)
        self.fill:SetWidth(max(0.001, w * self.value))
        self.fill:SetShown(self.value > 0)
        self.lip:SetShown(self.value > 0 and self.value < 1)
    end
    function b:SetLabel(s) if self.text then self.text:SetText(s or "") end end
    b:SetScript("OnSizeChanged", function(self) self:SetValue(self.value) end)
    b:SetColor(opts.color or "green")
    return b
end

--- Stat(parent, {value, label, color, size}): a number over a small caption, no frame around it.
-- :Set(value, label, color). Sized to its text; lay out with SetPoint.
function UI:Stat(parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, parent)
    f.value = self:Text(f, opts.size or 20, opts.color or "text", "ui")
    f.value:SetPoint("TOPLEFT")
    f.label = self:Text(f, 11, "dim")
    f.label:SetPoint("TOPLEFT", f.value, "BOTTOMLEFT", 0, -2)
    function f:Set(value, label, color)
        self.value:SetText(tostring(value == nil and "" or value))
        if label then self.label:SetText(label) end
        if color then UI:SetTextColor(self.value, color) end
        self:SetSize(max(self.value:GetStringWidth() or 0, self.label:GetStringWidth() or 0) + 6,
            (opts.size or 20) + 18)
    end
    f:Set(opts.value, opts.label or "", opts.color)
    return f
end

--- StatTile(parent, {icon, value, label, color, size}): a carved well with an optional icon, a number
-- and a caption. :Set(value, label, color). Give it a size; it doesn't pick one.
function UI:StatTile(parent, opts)
    opts = opts or {}
    local f = self:Well(parent)
    local x = 10
    if opts.icon then
        f.icon = self:Icon(f, 16, opts.icon, "ARTWORK", opts.iconColor or "bronze")
        f.icon:SetPoint("LEFT", 10, 0)
        x = 34
    end
    f.value = self:Text(f, opts.size or 17, opts.color or "text", "ui")
    f.value:SetPoint("TOPLEFT", x, -7)
    f.value:SetPoint("TOPRIGHT", -6, -7)
    f.label = self:Text(f, 11, "dim")
    f.label:SetPoint("TOPLEFT", f.value, "BOTTOMLEFT", 0, -2)
    f.label:SetPoint("TOPRIGHT", f.value, "BOTTOMRIGHT", 0, -2)
    function f:Set(value, label, color)
        self.value:SetText(tostring(value == nil and "" or value))
        if label then self.label:SetText(label) end
        if color then UI:SetTextColor(self.value, color) end
    end
    f:Set(opts.value, opts.label or "", opts.color)
    attachTip(f, opts.tooltip)
    if opts.tooltip then f:EnableMouse(true) end
    return f
end

--- Segmented(parent, items, onSelect, {height, width}): one connected control for a single choice,
-- for "All time / This week" and the like. items = {{key=, text=, icon=}}. :Select(key, silent).
function UI:Segmented(parent, items, onSelect, opts)
    opts = opts or {}
    local f = self:Well(parent)
    local h = opts.height or 24
    f:SetHeight(h)
    f.buttons = {}
    local x = 2
    for _, it in ipairs(items) do
        local b = CreateFrame("Button", nil, f)
        b.key = it.key
        b:SetHeight(h - 4)
        b.wash = b:CreateTexture(nil, "BACKGROUND")
        b.wash:SetAllPoints()
        self:Gradient(b.wash, "VERTICAL", 1, 0.78, 0.26, 0.10, 0.24)
        b.wash:Hide()
        b.line = b:CreateTexture(nil, "ARTWORK")
        b.line:SetColorTexture(C.wowGold[1], C.wowGold[2], C.wowGold[3], 1)
        b.line:SetHeight(1)
        b.line:SetPoint("BOTTOMLEFT", 2, 0)
        b.line:SetPoint("BOTTOMRIGHT", -2, 0)
        b.line:Hide()
        b.label = self:Text(b, 11, "dim", "ui")
        b.label:SetPoint("CENTER", it.icon and 7 or 0, 0)
        b.label:SetText(tostring(it.text))
        if it.icon then
            b.icon = self:Icon(b, 11, it.icon, "ARTWORK", "dim")
            b.icon:SetPoint("RIGHT", b.label, "LEFT", -4, 0)
        end
        b:SetWidth(opts.width or ((b.label:GetStringWidth() or 40) + 20 + (it.icon and 15 or 0)))
        b:SetPoint("LEFT", x, 0)
        x = x + b:GetWidth()
        b:SetScript("OnEnter", function(self) if f.selected ~= self.key then UI:SetTextColor(self.label, "text") end end)
        b:SetScript("OnLeave", function(self) if f.selected ~= self.key then UI:SetTextColor(self.label, "dim") end end)
        b:SetScript("OnClick", function(self) sound(841); f:Select(self.key) end)
        f.buttons[#f.buttons + 1] = b
    end
    f:SetWidth(x + 2)
    function f:Select(key, silent)
        self.selected = key
        for _, b in ipairs(self.buttons) do
            local on = b.key == key
            b.wash:SetShown(on)
            b.line:SetShown(on)
            UI:SetTextColor(b.label, on and "wowGold" or "dim")
            if b.icon then local c = on and C.wowGold or C.dim; b.icon:SetVertexColor(c[1], c[2], c[3], 1) end
        end
        if not silent and onSelect then GF:Safe("segmented", onSelect, key) end
    end
    return f
end

--- Paints `f` as a sheet of parchment with a fine edge: the one light material, so it's for notices
-- and date tiles only. Write on it in UI.INK colours, with the text shadow off.
UI.INK = { dark = { 0.16, 0.10, 0.04, 1 }, red = { 0.52, 0.08, 0.06, 1 }, dim = { 0.33, 0.24, 0.13, 1 } }
function UI:Parchment(f, inset)
    f.paper = self:Tiled(f, T.tex.parchment, 1, 1, 1, 1, inset or 1, "BACKGROUND", 1)
    f.paperRim = self:Nine(f, "paperEdge", "BORDER")
    return f
end

-------------------------------------------------------------------------------
-- Items, classes, avatars
-------------------------------------------------------------------------------
local waitingItems = setmetatable({}, { __mode = "k" })

GF:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
    if not API.Readable(itemID) then return end
    local failed = API.Clean(success) == false
    for btn, id in pairs(waitingItems) do
        if id == itemID then
            waitingItems[btn] = nil
            -- a failed load must not re-request forever
            if not failed and btn.Update then btn:Update() end
        end
    end
end)

--- ItemButton(parent, size) -> button with :SetItem(itemID | link)
function UI:ItemButton(parent, size)
    size = size or 32
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(size, size)
    self:SetBackdrop(b, { 0.03, 0.035, 0.05, 1 }, false)
    local inset = max(1, floor(size * 0.075 + 0.5))
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", inset, -inset)
    b.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    -- neutral metal bezel, tinted the item's quality
    b.bezel = b:CreateTexture(nil, "OVERLAY")
    b.bezel:SetTexture(T.tex.iconFrameWhite)
    b.bezel:SetAllPoints()
    b.count = self:Text(b, 10, "text", "num", "OUTLINE")
    b.count:SetPoint("BOTTOMRIGHT", -3, 3)
    function b:SetBackdropBorderColor(r, g, bb, a) self.bezel:SetVertexColor(r, g, bb, a or 1) end

    function b:Update()
        local id = self.itemID
        if not id then
            self.icon:SetTexture(nil)
            self:SetBackdropBorderColor(C.bronze[1], C.bronze[2], C.bronze[3], 1)
            return
        end
        self.icon:SetTexture(API.ItemIcon(id))
        local q = API.ItemQuality(self.link or id)
        if q then
            local r, g, bb = API.QualityColor(q)
            self:SetBackdropBorderColor(r, g, bb, 1)
        else
            self:SetBackdropBorderColor(C.bronze[1], C.bronze[2], C.bronze[3], 1)
            if self.requested ~= id then
                self.requested = id
                waitingItems[self] = id
                API.RequestItem(id)
            end
        end
    end

    function b:SetItem(item, count)
        self.itemID = API.ItemID(item)
        self.link = (type(item) == "string" and item:find("|H", 1, true)) and item or nil
        self.count:SetText((count and count > 1) and count or "")
        self:Update()
    end

    b:SetScript("OnEnter", function(self)
        if not self.itemID or not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.link then
            pcall(GameTooltip.SetHyperlink, GameTooltip, self.link)
        else
            pcall(GameTooltip.SetItemByID, GameTooltip, self.itemID)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() UI:HideTip() end)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(self)
        local link = self.link or API.ItemLink(self.itemID)
        if link and API.IsShiftKeyDown() then UI:InsertLink(link) end
        if self.onClick then self.onClick(self) end
    end)
    return b
end

--- Opens the chat box with a whisper to `name` ready to type.
function UI:Whisper(name)
    if type(name) ~= "string" or name == "" then return end
    name = API.WhisperName(name)
    if not name then
        GF:Print("Two residents answer to that name and the addon won't guess. /w the full name yourself.")
        return
    end
    local CFU = rawget(_G, "ChatFrameUtil")
    if CFU and CFU.SendTell and pcall(CFU.SendTell, name) then return end
    local st = rawget(_G, "ChatFrame_SendTell")
    if st and pcall(st, name) then return end
    local oc = (CFU and CFU.OpenChat) or rawget(_G, "ChatFrame_OpenChat")
    if oc then pcall(oc, "/w " .. name .. " ") end
end

--- Puts a link into the open chat box (shift-click behaviour).
function UI:InsertLink(link)
    if type(link) ~= "string" then return end
    local CFU = rawget(_G, "ChatFrameUtil")
    if CFU and CFU.InsertLink then
        if pcall(CFU.InsertLink, link) then return end
    end
    local f = rawget(_G, "ChatEdit_InsertLink")
    if f then pcall(f, link) end
end

--- Game icon in a bevelled frame (action-button style).
-- FramedIcon(parent, size, icon, tone) -> frame with :SetIcon(icon), :SetDesaturated(bool),
-- :SetTone("bronze"|"gold"). Bronze by default: gold is for what's actually special.
function UI:FramedIcon(parent, size, icon, tone)
    size = size or 32
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    local inset = math.max(1, math.floor(size * 0.075 + 0.5))
    f.icon:SetPoint("TOPLEFT", inset, -inset)
    f.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    f.frame = f:CreateTexture(nil, "OVERLAY")
    f.frame:SetAllPoints()
    function f:SetTone(t) self.frame:SetTexture(t == "gold" and T.tex.iconFrameGold or T.tex.iconFrame) end
    f:SetTone(tone)
    function f:SetIcon(ic)
        UI:SetIcon(self.icon, ic)
        if not self.icon.isGameIcon then
            -- our line icons sit on a dark well so they read like a game icon
            self.icon:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 1)
        else
            self.icon:SetVertexColor(1, 1, 1, 1)
        end
    end
    function f:SetDesaturated(on) self.icon:SetDesaturated(on and true or false) end
    f.well = f:CreateTexture(nil, "BACKGROUND")
    f.well:SetAllPoints(f.icon)
    f.well:SetColorTexture(0.03, 0.035, 0.05, 1)
    if icon then f:SetIcon(icon) end
    return f
end

--- A tiny game icon with a thin dark edge, for 12 to 18 unit sizes where a bevel would eat the picture.
-- IconChip(parent, size, icon) -> frame with :SetIcon(icon), :SetDesaturated(bool)
function UI:IconChip(parent, size, icon)
    size = size or 16
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.edge = f:CreateTexture(nil, "BACKGROUND")
    f.edge:SetAllPoints()
    f.edge:SetColorTexture(0, 0, 0, 0.85)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("TOPLEFT", 1, -1)
    f.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    function f:SetIcon(ic)
        UI:SetIcon(self.icon, ic)
        if not self.icon.isGameIcon then
            self.icon:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 1)
        else
            self.icon:SetVertexColor(1, 1, 1, 1)
        end
    end
    function f:SetDesaturated(on) self.icon:SetDesaturated(on and true or false) end
    if icon then f:SetIcon(icon) end
    return f
end

--- One achievement-style light sweep across a frame (clipped to it). Safe to call often.
function UI:Shine(target, duration)
    if not target or not target.CreateAnimationGroup then return end
    local s = target.gfShine
    if not s then
        s = CreateFrame("Frame", nil, target)
        s:SetAllPoints()
        s:SetClipsChildren(true)
        s:SetFrameLevel(target:GetFrameLevel() + 5)
        s.tex = s:CreateTexture(nil, "OVERLAY")
        s.tex:SetTexture(T.tex.shine)
        s.tex:SetBlendMode("ADD")
        s.tex:SetVertexColor(1, 0.92, 0.65, 0.9)
        s.ag = s.tex:CreateAnimationGroup()
        s.move = s.ag:CreateAnimation("Translation")
        s.move:SetSmoothing("IN_OUT")
        s.ag:SetScript("OnFinished", function() s.tex:Hide() end)
        target.gfShine = s
    end
    local w, h = target:GetWidth() or 64, target:GetHeight() or 64
    s.tex:SetSize(math.max(32, h * 1.2), math.max(16, h * 1.4))
    s.tex:ClearAllPoints()
    s.tex:SetPoint("RIGHT", s, "LEFT", 0, 0)
    s.move:SetOffset(w + s.tex:GetWidth() * 1.2, 0)
    s.move:SetDuration(duration or 0.75)
    s.tex:Show()
    s.ag:Stop()
    s.ag:Play()
end

function UI:ClassIcon(parent, size)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetSize(size or 16, size or 16)
    function t:SetClass(classFile) API.SetClassIcon(self, classFile) end
    return t
end

--- Circular class avatar in a metal ring tinted the class colour.
function UI:Avatar(parent, size)
    size = size or 32
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.back = f:CreateTexture(nil, "BACKGROUND")
    f.back:SetTexture(T.tex.circle)
    f.back:SetAllPoints()
    f.back:SetVertexColor(0.03, 0.035, 0.05, 1)
    f.ring = f:CreateTexture(nil, "OVERLAY")
    f.ring:SetTexture(T.tex.ringMetal)
    f.ring:SetAllPoints()
    local inset = math.max(1, math.floor(size * 0.07 + 0.5))
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("TOPLEFT", inset, -inset)
    f.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    if f.CreateMaskTexture then
        local mask = f:CreateMaskTexture()
        mask:SetTexture(T.tex.circle, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(f.icon)
        f.icon:AddMaskTexture(mask)
    end
    function f:SetClass(classFile)
        API.SetClassIcon(self.icon, classFile)
        local c = API.ClassColor(classFile) or { r = 0.5, g = 0.5, b = 0.5 }
        self.ring:SetVertexColor(c.r, c.g, c.b, 1)
    end
    return f
end

-------------------------------------------------------------------------------
-- Tabs (segmented control)
-------------------------------------------------------------------------------
--- Tabs(parent, {{key=, text=, icon=, count=}, ...}, onSelect(key)) -> tabs with :Select(key), :SetCount(key, n)
function UI:Tabs(parent, items, onSelect)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(30)
    f.buttons = {}
    local x = 0
    for _, it in ipairs(items) do
        local b = CreateFrame("Button", nil, f)
        b.key = it.key
        b:SetHeight(30)
        b.label = self:Text(b, 12, "dim", "ui")
        b.label:SetPoint("CENTER", it.icon and 8 or 0, 1)
        b.label:SetText(tostring(it.text))
        if it.icon then
            b.icon = self:Icon(b, 12, it.icon, "ARTWORK", "dim")
            b.icon:SetPoint("RIGHT", b.label, "LEFT", -5, 0)
        end
        -- selected: a gold edge with light rising off it
        b.glow = b:CreateTexture(nil, "BACKGROUND")
        b.glow:SetPoint("BOTTOMLEFT", 4, 0)
        b.glow:SetPoint("BOTTOMRIGHT", -4, 0)
        b.glow:SetHeight(18)
        self:Gradient(b.glow, "VERTICAL", 1, 0.80, 0.30, 0.16, 0)
        b.glow:Hide()
        b.line = b:CreateTexture(nil, "ARTWORK")
        b.line:SetHeight(2)
        b.line:SetPoint("BOTTOMLEFT", 4, 0)
        b.line:SetPoint("BOTTOMRIGHT", -4, 0)
        b.line:SetColorTexture(C.wowGold[1], C.wowGold[2], C.wowGold[3], 1)
        b.line:Hide()
        if it.count ~= nil then
            b.countText = self:Text(b, 11, "faint", "num")
            b.countText:SetPoint("LEFT", b.label, "RIGHT", 5, 0)
            b.countText:SetText(tostring(it.count))
        end
        b:SetWidth((b.label:GetStringWidth() or 40) + 24 + (it.icon and 16 or 0)
            + (b.countText and (b.countText:GetStringWidth() or 8) + 5 or 0))
        b:SetPoint("LEFT", x, 0)
        x = x + b:GetWidth() + 2
        b:SetScript("OnEnter", function(self) if f.selected ~= self.key then UI:SetTextColor(self.label, "text") end end)
        b:SetScript("OnLeave", function(self) if f.selected ~= self.key then UI:SetTextColor(self.label, "dim") end end)
        b:SetScript("OnClick", function(self) sound(841); f:Select(self.key) end)
        f.buttons[#f.buttons + 1] = b
    end
    f:SetWidth(x)
    local base = UI:Divider(f, "lineSoft")
    base:SetPoint("BOTTOMLEFT")
    base:SetPoint("BOTTOMRIGHT")
    function f:Select(key, silent)
        self.selected = key
        for _, b in ipairs(self.buttons) do
            local on = b.key == key
            b.line:SetShown(on)
            b.glow:SetShown(on)
            UI:SetTextColor(b.label, on and "wowGold" or "dim")
            if b.icon then local c = on and C.wowGold or C.dim; b.icon:SetVertexColor(c[1], c[2], c[3], 1) end
        end
        if not silent and onSelect then GF:Safe("tabs", onSelect, key) end
    end
    function f:SetCount(key, n)
        local x = 0
        for _, b in ipairs(self.buttons) do
            if b.key == key and b.countText then b.countText:SetText(tostring(n or "")) end
            -- a count changing width moves everything after it
            b:SetWidth((b.label:GetStringWidth() or 40) + 24 + (b.icon and 16 or 0)
                + (b.countText and (b.countText:GetStringWidth() or 8) + 5 or 0))
            b:ClearAllPoints()
            b:SetPoint("LEFT", x, 0)
            x = x + b:GetWidth() + 2
        end
        self:SetWidth(x)
    end
    return f
end

-------------------------------------------------------------------------------
-- Page furniture
-------------------------------------------------------------------------------
--- PageHeader(page, title, subtitle) -> header; header.actions is a right-aligned
--- container: header:AddAction(button) appends right-to-left.
function UI:PageHeader(page, title, subtitle)
    local h = CreateFrame("Frame", nil, page)
    h:SetHeight(48)
    h:SetPoint("TOPLEFT")
    h:SetPoint("TOPRIGHT")
    -- quest-title Morpheus in the game's gold, written straight onto the night sky. It's the only
    -- headline on the screen.
    h.title = self:Text(h, 28, "wowGold", "title")
    h.title:SetPoint("TOPLEFT", 0, 0)
    h.title:SetText(tostring(title or ""))
    if h.title.SetShadowOffset then
        h.title:SetShadowOffset(1, -2)
        h.title:SetShadowColor(0, 0, 0, 1)
    end
    h.sub = self:Text(h, 12, "text")
    h.sub:SetPoint("TOPLEFT", h.title, "BOTTOMLEFT", 1, -2)
    h.sub:SetText(subtitle or "")
    if h.sub.SetShadowOffset then
        h.sub:SetShadowOffset(1, -1)
        h.sub:SetShadowColor(0, 0, 0, 1)
    end
    h.actions = {}
    -- keep the subtitle clear of the right-aligned actions (it truncates instead)
    local function fit(self)
        local used = 0
        for _, a in ipairs(self.actions) do used = used + (a:GetWidth() or 0) + 6 end
        local w = (self:GetWidth() or 0) - used - 16
        if w > 60 then
            self.sub:SetWidth(w)
            self.title:SetWidth(w)
        end
    end
    h:SetScript("OnSizeChanged", fit)
    function h:AddAction(btn)
        btn:SetParent(self)
        btn:ClearAllPoints()
        local last = self.actions[#self.actions]
        if last then btn:SetPoint("RIGHT", last, "LEFT", -6, 0) else btn:SetPoint("TOPRIGHT", 0, -4) end
        self.actions[#self.actions + 1] = btn
        fit(self)
        return btn
    end
    function h:SetSubtitle(s) self.sub:SetText(s or "") end
    return h
end

--- Empty-state block, centred in parent: Empty(parent, text, icon, {heading, action, actionIcon,
-- actionStyle, onAction, width}). It shrinks to fit a narrow parent, and action adds a button so
-- the page says what to do next.
function UI:Empty(parent, text, icon, opts)
    opts = opts or {}
    local fullW = opts.width or 360
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(fullW, 120)
    f:SetPoint("CENTER")
    f.icon = self:Icon(f, 40, icon or "eye", "ARTWORK", { C.bronze[1], C.bronze[2], C.bronze[3], 0.5 })
    f.icon:SetPoint("TOP", 0, 0)
    local above = f.icon
    if opts.heading then
        f.heading = self:Text(f, 14, "gold", "ui")
        f.heading:SetPoint("TOP", f.icon, "BOTTOM", 0, -10)
        f.heading:SetText(opts.heading)
        above = f.heading
    end
    f.text = self:Para(f, 13, "dim")
    f.text:SetPoint("TOP", above, "BOTTOM", 0, opts.heading and -6 or -12)
    f.text:SetWidth(fullW)
    f.text:SetJustifyH("CENTER")
    f.text:SetText(text or "")
    if opts.action then
        f.action = self:Button(f, opts.action, { style = opts.actionStyle or "secondary", icon = opts.actionIcon, onClick = opts.onAction })
        f.action:SetPoint("TOP", f.text, "BOTTOM", 0, -12)
    end
    local function fit()
        local w = parent.GetWidth and parent:GetWidth() or 0
        if w and w > 0 then
            local fw = min(fullW, max(120, w - 32))
            f:SetWidth(fw)
            f.text:SetWidth(fw)
        end
    end
    if parent.HookScript then parent:HookScript("OnSizeChanged", fit) end
    fit()
    function f:SetText(t) self.text:SetText(t or "") end
    return f
end

--- Lets a frame's FontStrings show clickable item/spell links.
function UI:EnableLinks(f)
    if not f.SetHyperlinksEnabled then return end
    f:SetHyperlinksEnabled(true)
    f:SetScript("OnHyperlinkEnter", function(self, link)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        pcall(GameTooltip.SetHyperlink, GameTooltip, link)
        GameTooltip:Show()
    end)
    f:SetScript("OnHyperlinkLeave", function() UI:HideTip() end)
    f:SetScript("OnHyperlinkClick", function(_, link, text)
        if API.IsShiftKeyDown() then UI:InsertLink(text) end
    end)
end

-------------------------------------------------------------------------------
-- Modals
-------------------------------------------------------------------------------
local modal

-- Blocks: the parts a long modal body is made of. Each is a pooled frame; layout measures it at the
-- width it's given and returns its height, so wrapped lines never have to be estimated.
local BLOCK_GAP = { heading = 18, bullet = 4, step = 8, para = 8 }
local BLOCK_KINDS = {}

function BLOCK_KINDS.para(f)
    f.fs = UI:Para(f, 12, "text")
    f.fs:SetPoint("TOPLEFT")
    function f:Fill(b, w)
        T:Font(self.fs, b.font or "body", b.size or 12)
        if self.fs.SetSpacing then self.fs:SetSpacing((b.size or 12) >= 13 and 3 or 2) end
        UI:SetTextColor(self.fs, b.color or "text")
        self.fs:SetWidth(w)
        self.fs:SetText(b.text or "")
        return max(14, self.fs:GetStringHeight() or 14)
    end
end

function BLOCK_KINDS.heading(f)
    f.fs = UI:Text(f, 15, "wowGold", "ui")
    f.fs:SetPoint("TOPLEFT")
    f.meta = UI:Text(f, 11, "dim")
    f.meta:SetPoint("TOPRIGHT", 0, -3)
    f.rule = UI:Hairline(f, "bronze", 0.5)
    f.rule:SetPoint("TOPLEFT", 0, -21)
    f.rule:SetPoint("TOPRIGHT", 0, -21)
    function f:Fill(b)
        self.fs:SetText(b.text or "")
        self.meta:SetText(b.meta or "")
        return 26
    end
end

function BLOCK_KINDS.bullet(f)
    f.dot = UI:Icon(f, 10, "dot", "ARTWORK", "wowGold")
    f.dot:SetPoint("TOPLEFT", -2, -2)
    f.fs = UI:Para(f, 12, "text")
    f.fs:SetPoint("TOPLEFT", 14, 0)
    function f:Fill(b, w)
        self.fs:SetWidth(w - 14)
        self.fs:SetText(b.text or "")
        return max(14, self.fs:GetStringHeight() or 14)
    end
end

function BLOCK_KINDS.step(f)
    f.disc = f:CreateTexture(nil, "ARTWORK")
    f.disc:SetTexture(T.tex.circle)
    f.disc:SetSize(20, 20)
    f.disc:SetPoint("TOPLEFT")
    f.disc:SetVertexColor(0.84, 0.66, 0.26, 1)
    f.num = UI:Text(f, 11, { 0.07, 0.05, 0.02, 1 }, "ui")
    f.num:SetPoint("CENTER", f.disc, "CENTER", 0, 0)
    f.num:SetShadowOffset(0, 0)
    f.fs = UI:Para(f, 12, "text")
    f.fs:SetPoint("TOPLEFT", 28, -3)
    function f:Fill(b, w)
        self.num:SetText(tostring(b.n or ""))
        self.fs:SetWidth(w - 28)
        self.fs:SetText(b.text or "")
        return max(20, 3 + (self.fs:GetStringHeight() or 14))
    end
end

local function buildModal()
    local overlay = CreateFrame("Frame", "GreenfieldsModal", UIParent)
    overlay:SetFrameStrata("FULLSCREEN_DIALOG")
    overlay:SetAllPoints(UIParent)
    overlay:EnableMouse(true)
    overlay.dim = overlay:CreateTexture(nil, "BACKGROUND")
    overlay.dim:SetAllPoints()
    overlay.dim:SetColorTexture(0.01, 0.015, 0.03, 0.66)
    overlay:Hide()
    tinsert(UISpecialFrames, "GreenfieldsModal")

    local d = UI:Panel(overlay, { 0, 0, 0, 0 }, false)
    d:SetPoint("CENTER", 0, 60)
    UI:Shadow(d, 18)
    d.rim = UI:Nine(d, "gold", "BACKGROUND", -6)
    overlay.dialog = d
    -- the modal's mood: a soft wash of its colour behind the title
    d.stripe = d:CreateTexture(nil, "BACKGROUND", nil, -4)
    d.stripe:SetPoint("TOPLEFT", 4, -4)
    d.stripe:SetPoint("TOPRIGHT", -4, -4)
    d.stripe:SetHeight(46)
    -- title and body get explicit widths (set per modal): measuring a wrapped string whose
    -- width only comes from anchors reads short before the dialog has been laid out
    d.title = UI:Text(d, 20, "wowGold", "title")
    d.title:SetPoint("TOPLEFT", 18, -18)
    d.title:SetWordWrap(true)
    d.text = UI:Para(d, 12, "text")
    d.text:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -10)
    d.input = UI:Input(d, { height = 28 })
    d.input:SetPoint("LEFT", 18, 0)
    d.input:SetPoint("RIGHT", -18, 0)
    -- multi-line box for import/export
    d.scroll = CreateFrame("ScrollFrame", nil, d, "BackdropTemplate")
    UI:SetBackdrop(d.scroll, { 0, 0, 0, 0 }, false)
    d.scroll.well = UI:Nine(d.scroll, "inset", "BACKGROUND", -6)
    d.edit = CreateFrame("EditBox", nil, d.scroll)
    d.edit:SetMultiLine(true)
    d.edit:SetAutoFocus(false)
    d.edit:SetMaxLetters(0)
    T:Font(d.edit, "num", 12)
    d.edit:SetTextColor(C.text[1], C.text[2], C.text[3], 1)
    d.edit:SetTextInsets(8, 8, 8, 8)
    d.edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    d.scroll:SetScrollChild(d.edit)
    d.scroll:EnableMouseWheel(true)
    d.scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = max(0, (d.edit:GetHeight() or 0) - self:GetHeight())
        self:SetVerticalScroll(U.Clamp(self:GetVerticalScroll() - delta * 40, 0, maxScroll))
    end)
    d.scroll:SetScript("OnSizeChanged", function(self, w) d.edit:SetWidth(max(50, (w or 300) - 4)) end)
    d.scroll:SetScript("OnMouseDown", function() d.edit:SetFocus() end)
    -- scrolling body for long reads
    d.body, d.bodyContent = UI:Scroll(d, { outside = true })
    d.body:Hide()
    d.blocks = { used = {} }
    for kind in pairs(BLOCK_KINDS) do d.blocks[kind] = {} end
    d.buttons = {}
    modal = overlay
end

local function layoutBlocks(d, blocks, w)
    local used = {}
    local y = 0
    for _, b in ipairs(blocks) do
        local kind = BLOCK_KINDS[b.kind] and b.kind or "para"
        used[kind] = (used[kind] or 0) + 1
        local f = d.blocks[kind][used[kind]]
        if not f then
            f = CreateFrame("Frame", nil, d.bodyContent)
            BLOCK_KINDS[kind](f)
            d.blocks[kind][used[kind]] = f
        end
        if y > 0 then y = y + (b.gap or BLOCK_GAP[kind]) end
        local h = f:Fill(b, w)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", 0, -y)
        f:SetSize(w, h)
        f:Show()
        y = y + h
    end
    for kind in pairs(BLOCK_KINDS) do
        for i = (used[kind] or 0) + 1, #d.blocks[kind] do d.blocks[kind][i]:Hide() end
    end
    return y
end

--- Modal{ title, text, width, style ("green"|"yellow"|"red"), input = {default, placeholder},
---        multiline = {text, readOnly}, buttons = { {text, style, onClick(value), keepOpen} },
---        scrollText = long string, or blocks = { {kind, ...} }, maxHeight (default 420) }
-- blocks read top down and scroll when they don't fit: {kind="heading", text, meta},
-- {kind="bullet", text}, {kind="step", n, text}, {kind="para", text, size, font, color}; any can
-- set gap, the space above it.
function UI:Modal(opts)
    if not modal then buildModal() end
    local d = modal.dialog
    local w = opts.width or 420
    d:SetWidth(w)
    d.title:SetWidth(w - 36)
    d.text:SetWidth(w - 36)
    local stripe = col(opts.style or "green")
    UI:Gradient(d.stripe, "VERTICAL", stripe[1], stripe[2], stripe[3], 0, 0.15)
    d.title:SetText(tostring(opts.title or ""))
    local hasText = opts.text ~= nil and opts.text ~= ""
    d.text:SetText(opts.text or "")
    d.input:Hide()
    d.scroll:Hide()
    d.body:Hide()
    local blocks = opts.blocks or (opts.scrollText and { { kind = "para", text = opts.scrollText } })
    local mh = opts.multiline and (opts.multiline.height or 220) or 0
    if opts.input then
        d.input:Show()
        d.input:SetText(opts.input.default or "")
        d.input.placeholder:SetText(opts.input.placeholder or "")
        d.input:RefreshPlaceholder()
    elseif opts.multiline then
        d.scroll:Show()
        d.scroll:SetHeight(mh)
        d.edit:SetWidth(w - 40)
        d.edit:SetText(opts.multiline.text or "")
        d.edit:SetHeight(max(mh, 2000))
        d.scroll:SetVerticalScroll(0)
        if opts.multiline.text and opts.multiline.text ~= "" then
            d.edit:HighlightText()
        end
    end
    -- size the dialog to its text; run again a frame after showing in case the client
    -- only wrapped the strings properly once they were on screen
    local function fit()
        local titleH = max(20, d.title:GetStringHeight() or 20)
        local textH = hasText and max(14, d.text:GetStringHeight() or 14) or 0
        local y = 18 + titleH + 10 + textH + 14
        if opts.input then
            d.input:ClearAllPoints()
            d.input:SetPoint("TOPLEFT", 18, -y)
            d.input:SetPoint("TOPRIGHT", -18, -y)
            y = y + 28 + 14
        elseif opts.multiline then
            d.scroll:ClearAllPoints()
            d.scroll:SetPoint("TOPLEFT", 18, -y)
            d.scroll:SetPoint("TOPRIGHT", -18, -y)
            y = y + mh + 14
        elseif blocks then
            -- a gutter is always kept for the scrollbar, so the text never reflows when it appears
            local bw = w - 36 - 14
            local total = layoutBlocks(d, blocks, bw)
            local room = min(opts.maxHeight or 420, max(160, (UIParent:GetHeight() or 768) - 240))
            local bh = min(total, room)
            d.body:ClearAllPoints()
            d.body:SetPoint("TOPLEFT", 18, -y)
            d.body:SetSize(bw, bh)
            d.bodyContent:SetWidth(bw)
            d.body:SetContentHeight(total)
            y = y + bh + 14
        end
        d:SetHeight(y + 28 + 16 + 4)
    end
    d.fit = fit
    for _, b in ipairs(d.buttons) do b:Hide() end
    local prev
    local defs = opts.buttons or { { text = "OK", style = "primary" } }
    for i = #defs, 1, -1 do
        local def = defs[i]
        local b = d.buttons[i]
        if not b then
            b = UI:Button(d, "", { height = 28, minWidth = 84 })
            d.buttons[i] = b
        end
        b:SetStyle(def.style or "secondary")
        b.opts.onClick = function()
            local value
            if opts.input then value = d.input:GetText() elseif opts.multiline then value = d.edit:GetText() end
            if not def.keepOpen then modal:Hide() end
            if def.onClick then def.onClick(value) end
        end
        b:SetText(def.text or "OK")
        b:ClearAllPoints()
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -8, 0) else b:SetPoint("BOTTOMRIGHT", -18, 16) end
        b:Show()
        prev = b
    end
    if blocks then
        d.body:Show()
        d.body:SetVerticalScroll(0)
    end
    fit()
    modal:Show()
    GF:After(0, function() if d.fit == fit and modal:IsShown() then fit() end end)
    UI:FadeIn(d, 0.12)
    if opts.input then d.input:SetFocus() end
    return d
end

function UI:CloseModal() if modal then modal:Hide() end end

function UI:Confirm(title, text, onYes, yesText, style)
    return self:Modal({
        title = title, text = text, style = style or "yellow",
        buttons = { { text = "Nah" }, { text = yesText or "Yeah", style = style == "red" and "danger" or "primary", onClick = onYes } },
    })
end

function UI:Prompt(title, text, default, onAccept, placeholder)
    return self:Modal({
        title = title, text = text, input = { default = default, placeholder = placeholder },
        buttons = { { text = "Cancel" }, { text = "Save", style = "primary", onClick = onAccept } },
    })
end

--- CopyBox(title, text) for exports; CopyBox(title, "", onImport) for imports.
function UI:CopyBox(title, text, onImport, help)
    if onImport then
        return self:Modal({
            title = title, text = help or "Paste below, then hit Import.", width = 560,
            multiline = { text = text or "", height = 260 },
            buttons = { { text = "Cancel" }, { text = "Import", style = "primary", onClick = onImport } },
        })
    end
    return self:Modal({
        title = title, text = help or "Ctrl+C to copy. Everything's already selected.", width = 560,
        multiline = { text = text or "", height = 260 },
        buttons = { { text = "Done", style = "primary" } },
    })
end

-------------------------------------------------------------------------------
-- Floating windows
-------------------------------------------------------------------------------
--- Window(name, {width, height, strata, title, sub, icon, onHide, noEsc, closeTip}) -> a floating,
-- gold-rimmed frame with a dark title band and a close button, closed by Esc unless noEsc. f.head is
-- the band, f.body what's under it. Drag it by the band. Used by panels outside the main window.
UI.windows = {}

function UI:Window(name, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    self.windows[#self.windows + 1] = f
    f:Hide()
    f:SetFrameStrata(opts.strata or "DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetSize(opts.width or 420, opts.height or 240)
    self:SetBackdrop(f, { 0, 0, 0, 0 }, false)
    self:Shadow(f, 16)
    f.rim = self:Nine(f, "gold", "BACKGROUND", -6)
    if name and not opts.noEsc then tinsert(UISpecialFrames, name) end
    local bandH = opts.band or 44
    local head = CreateFrame("Frame", nil, f)
    head:SetPoint("TOPLEFT", 4, -4)
    head:SetPoint("TOPRIGHT", -4, -4)
    head:SetHeight(bandH)
    head.leather = self:Tiled(head, T.tex.leather, 0.8, 0.8, 0.86, 0.7)
    head.shade = head:CreateTexture(nil, "BACKGROUND", nil, 2)
    head.shade:SetAllPoints()
    self:Gradient(head.shade, "VERTICAL", 0.01, 0.015, 0.03, 0.5, 0)
    head.rule = self:Hairline(head, "bronze", 0.7, "none")
    head.rule:SetPoint("BOTTOMLEFT")
    head.rule:SetPoint("BOTTOMRIGHT")
    head:EnableMouse(true)
    head:RegisterForDrag("LeftButton")
    f:SetMovable(true)
    head:SetScript("OnDragStart", function() f:StartMoving() end)
    head:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f.head = head
    local x = 12
    if opts.icon then
        f.headIcon = self:Icon(head, 16, opts.icon, "ARTWORK", opts.iconColor or "gold")
        f.headIcon:SetPoint("LEFT", 12, 0)
        x = 36
    end
    f.title = self:Text(head, 16, "wowGold", "ui")
    local y = opts.sub and -7 or -14
    f.title:SetPoint("TOPLEFT", x, y)
    f.title:SetPoint("TOPRIGHT", -40, y)
    f.title:SetText(opts.title or "")
    f.sub = self:Text(head, 11, "dim")
    f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
    f.sub:SetPoint("TOPRIGHT", f.title, "BOTTOMRIGHT", 0, -3)
    f.sub:SetText(opts.sub or "")
    f.close = self:IconButton(head, "close", 24, opts.closeTip or "Close (Esc)", function() f:Hide() end)
    f.close:SetPoint("RIGHT", -8, 0)
    f.body = CreateFrame("Frame", nil, f)
    f.body:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 8, -8)
    f.body:SetPoint("BOTTOMRIGHT", -12, 12)
    if opts.onHide then f:SetScript("OnHide", opts.onHide) end
    return f
end
