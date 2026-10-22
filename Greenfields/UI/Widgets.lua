--[[ Greenfields - UI/Widgets.lua
     The widget kit every page is built from. All widgets are plain frames (no Blizzard
     templates except BackdropTemplate), so they look the same everywhere and never taint.

       UI:Panel(parent, bg, border)            UI:SetBackdrop(frame, bg, border)
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
-- Gold-rimmed textured buttons (Media/btn_*.tga, 9-sliced); ghost stays flat.
local STYLES = {
    primary = { tex = T.tex.btnGreen, text = { 1, 1, 1, 1 } },
    secondary = { tex = T.tex.btnDark, text = C.wowGold },
    ghost = { bg = { 0, 0, 0, 0 }, hover = C.bg3, text = C.dim, textHover = C.text, border = { 0, 0, 0, 0 } },
    danger = { tex = T.tex.btnRed, text = { 1, 1, 1, 1 } },
    warn = { tex = T.tex.btnGold, text = { 0.12, 0.08, 0.02, 1 } },
    sign = { tex = T.tex.btnGreen, text = { 1, 1, 1, 1 } },
}
UI.ButtonStyles = STYLES

local function applyButtonColors(b, hover)
    local s = b.style
    if s.tex then
        b:SetBackdropColor(0, 0, 0, 0)
        b:SetBackdropBorderColor(0, 0, 0, 0)
        sliced(b.face, s.tex, 10)
        b.face:Show()
        b.hl:SetAlpha(hover and 1 or 0)
    else
        b.face:Hide()
        b.hl:SetAlpha(0)
        local bg = hover and s.hover or s.bg
        b:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
        b:SetBackdropBorderColor(s.border[1], s.border[2], s.border[3], s.border[4] or 1)
    end
    local tc = (hover and s.textHover) or s.text
    b.label:SetTextColor(tc[1], tc[2], tc[3], tc[4] or 1)
    if b.icon and not b.icon.isGameIcon then b.icon:SetVertexColor(tc[1], tc[2], tc[3], tc[4] or 1) end
end

--- Button(parent, text, {style, icon, width, height, size, onClick, tooltip, upper})
function UI:Button(parent, text, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetHeight(opts.height or 26)
    self:SetBackdrop(b, C.bg3, C.line)
    b.face = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.face:SetAllPoints()
    b.hl = b:CreateTexture(nil, "ARTWORK", nil, -1)
    b.hl:SetPoint("TOPLEFT", 3, -3)
    b.hl:SetPoint("BOTTOMRIGHT", -3, 3)
    b.hl:SetColorTexture(1, 1, 1, 0.12)
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
        self:SetAlpha(on and 1 or 0.4)
    end

    if opts.width then b:SetWidth(opts.width) end
    b:SetText(text)
    applyButtonColors(b, false)

    b:SetScript("OnEnter", function(self) applyButtonColors(self, true) end)
    b:SetScript("OnLeave", function(self) applyButtonColors(self, false) end)
    b:SetScript("OnMouseDown", function(self)
        -- tiny press-in nudge (text-only buttons; icon layouts re-anchor on mouse up)
        if self:IsEnabled() and not self.icon then
            self.label:ClearAllPoints()
            self.label:SetPoint("CENTER", 0, -1)
        end
    end)
    b:SetScript("OnMouseUp", function(self) self:Layout() end)
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
    self:SetBackdrop(box, C.bg3, C.line)
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
        self:SetBackdropBorderColor(C.green[1], C.green[2], C.green[3], 0.8)
        refreshPlaceholder(self)
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(C.line[1], C.line[2], C.line[3], 1)
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
    b.track:SetTexture(T.tex.pill)
    b.track:SetSize(36, 18)
    b.track:SetPoint("LEFT")
    b.knob = b:CreateTexture(nil, "OVERLAY")
    b.knob:SetTexture(T.tex.circle)
    b.knob:SetSize(14, 14)
    b.label = self:Text(b, 12, "text")
    b.label:SetPoint("LEFT", b.track, "RIGHT", 10, 0)
    b.label:SetText(label or "")
    b:SetWidth(36 + 10 + (b.label:GetStringWidth() or 0) + 4)

    function b:SetChecked(on)
        self.checked = on and true or false
        self.knob:ClearAllPoints()
        if self.checked then
            self.track:SetVertexColor(C.green[1], C.green[2], C.green[3], 1)
            self.knob:SetVertexColor(0.04, 0.1, 0.06, 1)
            self.knob:SetPoint("RIGHT", self.track, "RIGHT", -2, 0)
        else
            self.track:SetVertexColor(C.bg4[1], C.bg4[2], C.bg4[3], 1)
            self.knob:SetVertexColor(C.dim[1], C.dim[2], C.dim[3], 1)
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
    UI:SetBackdrop(menu, C.bg1, false)
    UI:Shadow(menu, 10)
    menu.rim = menu:CreateTexture(nil, "OVERLAY", nil, 7)
    menu.rim:SetAllPoints()
    sliced(menu.rim, T.tex.frameBronze, 8)
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

    function menu:Refresh()
        for i = 1, MENU_MAX do
            local row = self.rows[i]
            local item = self.items[i + self.offset]
            if row then
                if item then
                    row.item = item
                    row.text:SetText(item.text or "")
                    local c = item.title and C.faint or (item.disabled and C.faint) or col(item.color or "text")
                    row.text:SetTextColor(c[1], c[2], c[3], c[4] or 1)
                    if item.icon then
                        UI:SetIcon(row.icon, item.icon)
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
    end
end

local function menuRow(i)
    local row = CreateFrame("Button", nil, menu)
    row:SetHeight(MENU_ROW)
    row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * MENU_ROW)
    row:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * MENU_ROW)
    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints()
    row.hl:SetColorTexture(1, 1, 1, 0.06)
    row.hl:Hide()
    row.icon = UI:Icon(row, 14, nil)
    row.icon:SetPoint("LEFT", 8, 0)
    row.text = UI:Text(row, 12, "text")
    row.text:SetPoint("LEFT", 10, 0)
    row.text:SetPoint("RIGHT", -24, 0)
    row.check = UI:Icon(row, 12, "check", "OVERLAY", "green")
    row.check:SetPoint("RIGHT", -6, 0)
    row.sep = row:CreateTexture(nil, "ARTWORK")
    row.sep:SetColorTexture(C.line[1], C.line[2], C.line[3], 1)
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
    for i = #menu.rows + 1, n do menu.rows[i] = menuRow(i) end
    local w = opts.width or (anchor and anchor:GetWidth() or 160)
    for _, item in ipairs(menu.items) do
        local probe = menu.rows[1] and menu.rows[1].text
        if probe and item.text then
            probe:SetText(item.text)
            w = max(w, (probe:GetStringWidth() or 0) + (item.icon and 60 or 44))
        end
    end
    menu:SetSize(min(w, 360), n * MENU_ROW + 8)
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
    self:SetBackdrop(b, C.bg3, C.line)
    b.icon = self:Icon(b, 14, nil)
    b.icon:SetPoint("LEFT", 8, 0)
    b.icon:Hide()
    b.text = self:Text(b, 12, "text")
    b.text:SetPoint("LEFT", 8, 0)
    b.text:SetPoint("RIGHT", -22, 0)
    b.chev = self:Icon(b, 12, "chevron_down", "OVERLAY", "dim")
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
    b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(C.green[1], C.green[2], C.green[3], 0.6) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(C.line[1], C.line[2], C.line[3], 1) end)
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
    bar.track = bar:CreateTexture(nil, "BACKGROUND")
    bar.track:SetAllPoints()
    sliced(bar.track, T.tex.pill, 3)
    bar.track:SetVertexColor(1, 1, 1, 0.04)
    bar.thumb = CreateFrame("Button", nil, bar)
    bar.thumb:SetWidth(6)
    bar.thumb.tex = bar.thumb:CreateTexture(nil, "ARTWORK")
    bar.thumb.tex:SetAllPoints()
    sliced(bar.thumb.tex, T.tex.pill, 3)
    bar.thumb.tex:SetVertexColor(C.dim[1], C.dim[2], C.dim[3], 0.45)
    bar.thumb:SetScript("OnEnter", function(self) self.tex:SetVertexColor(C.green[1], C.green[2], C.green[3], 0.8) end)
    bar.thumb:SetScript("OnLeave", function(self) if not self.dragging then self.tex:SetVertexColor(C.dim[1], C.dim[2], C.dim[3], 0.45) end end)
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
        self.tex:SetVertexColor(C.dim[1], C.dim[2], C.dim[3], 0.45)
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

    function f:VisibleCount()
        local h = self:GetHeight() or 0
        return max(1, floor(h / (self.rowHeight + self.spacing)))
    end

    local function makeRow(i)
        local row = CreateFrame("Button", nil, f)
        row:SetHeight(f.rowHeight)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * (f.rowHeight + f.spacing))
        row:SetPoint("TOPRIGHT", -10, -(i - 1) * (f.rowHeight + f.spacing))
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(C.bg2[1], C.bg2[2], C.bg2[3], opts.zebra == false and 0 or 0.7)
        row.hl = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.05)
        row.hl:Hide()
        row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 2)
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(C.green[1], C.green[2], C.green[3], 0.10)
        row.sel:Hide()
        row.selBar = row:CreateTexture(nil, "ARTWORK")
        row.selBar:SetPoint("TOPLEFT")
        row.selBar:SetPoint("BOTTOMLEFT")
        row.selBar:SetWidth(2)
        row.selBar:SetColorTexture(C.green[1], C.green[2], C.green[3], 1)
        row.selBar:Hide()
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
--- Scroll(parent) -> scrollFrame, content. Call scroll:SetContentHeight(h) after layout.
function UI:Scroll(parent)
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
    function sf:UpdateBar()
        local h = self:GetHeight() or 1
        local maxScroll = max(0, self.contentHeight - h)
        local cur = U.Clamp(self:GetVerticalScroll() or 0, 0, maxScroll)
        if cur ~= self:GetVerticalScroll() then self:SetVerticalScroll(cur) end
        self.bar:Update(self.contentHeight > 0 and h / self.contentHeight or 1, maxScroll > 0 and cur / maxScroll or 0)
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
        content:SetWidth(max(1, (w or self:GetWidth() or 1) - 12))
        self:UpdateBar()
    end)
    return sf, content
end

-------------------------------------------------------------------------------
-- Cards, pills, bars
-------------------------------------------------------------------------------
--- Card(parent, {title, icon, accent, subtitle}) -> card; card.body is the area under the header.
function UI:Card(parent, opts)
    opts = opts or {}
    local c = self:Panel(parent, C.bg2, false)
    -- worn slate under the panel colour, a bronze 9-slice rim, and a faint top sheen
    c.stone = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.stone:SetPoint("TOPLEFT", 2, -2)
    c.stone:SetPoint("BOTTOMRIGHT", -2, 2)
    c.stone:SetTexture(T.tex.stone, "REPEAT", "REPEAT")
    c.stone:SetHorizTile(true)
    c.stone:SetVertTile(true)
    c.stone:SetVertexColor(0.62, 0.66, 0.64, 0.30)
    c.sheen = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.sheen:SetPoint("TOPLEFT", 2, -2)
    c.sheen:SetPoint("TOPRIGHT", -2, -2)
    c.sheen:SetHeight(40)
    c.sheen:SetTexture(WHITE)
    if c.sheen.SetGradient and CreateColor then
        c.sheen:SetGradient("VERTICAL", CreateColor(1, 0.85, 0.5, 0), CreateColor(1, 0.85, 0.5, 0.06))
    else
        c.sheen:SetColorTexture(1, 0.85, 0.5, 0.03)
    end
    c.rim = c:CreateTexture(nil, "BORDER")
    c.rim:SetAllPoints()
    sliced(c.rim, T.tex.frameBronze, 8)
    c.body = CreateFrame("Frame", nil, c)
    if opts.title then
        local accent = col(opts.accent or "green")
        local bar = c:CreateTexture(nil, "ARTWORK")
        bar:SetColorTexture(accent[1], accent[2], accent[3], 1)
        bar:SetSize(22, 2)
        bar:SetPoint("TOPLEFT", 9, -3)
        c.accent = bar
        local x = 12
        if opts.icon then
            c.icon = self:Icon(c, 14, opts.icon, "ARTWORK", opts.iconColor or opts.accent or "green")
            c.icon:SetPoint("TOPLEFT", 12, -13)
            x = 32
        end
        c.title = self:Text(c, 13, "wowGold", "ui")
        c.title:SetPoint("TOPLEFT", x, -13)
        c.title:SetText(tostring(opts.title))
        if opts.subtitle then
            c.subtitle = self:Text(c, 11, "faint")
            c.subtitle:SetPoint("LEFT", c.title, "RIGHT", 8, 0)
            c.subtitle:SetText(opts.subtitle)
        end
        c.right = CreateFrame("Frame", nil, c)
        c.right:SetSize(1, 22)
        c.right:SetPoint("TOPRIGHT", -8, -8)
        c.body:SetPoint("TOPLEFT", 12, -38)
        c.body:SetPoint("BOTTOMRIGHT", -12, 10)
    else
        c.body:SetPoint("TOPLEFT", 12, -12)
        c.body:SetPoint("BOTTOMRIGHT", -12, 12)
    end
    function c:SetTitle(t) if self.title then self.title:SetText(tostring(t)) end end
    return c
end

--- Pill(parent, text, color, {size, icon}) -> pill with :SetText(text, color)
function UI:Pill(parent, text, color, opts)
    opts = opts or {}
    local p = CreateFrame("Frame", nil, parent)
    p:SetHeight(opts.height or 18)
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    sliced(p.bg, T.tex.pill, 8)
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
        self.bg:SetVertexColor(c[1], c[2], c[3], 0.16)
        if self.icon and not self.icon.isGameIcon then self.icon:SetVertexColor(c[1], c[2], c[3], 1) end
        self:SetWidth((self.label:GetStringWidth() or 0) + 16 + (self.icon and 14 or 0))
    end
    p:SetText(text, color)
    if opts.tooltip then p:EnableMouse(true) end
    attachTip(p, opts.tooltip)
    return p
end

--- Bar(parent, {height, color, text}) -> bar with :SetValue(0..1), :SetColor(c), :SetLabel(s)
function UI:Bar(parent, opts)
    opts = opts or {}
    local b = CreateFrame("Frame", nil, parent)
    b:SetHeight(opts.height or 8)
    b.track = b:CreateTexture(nil, "BACKGROUND")
    b.track:SetAllPoints()
    sliced(b.track, T.tex.pill, 4)
    b.track:SetVertexColor(1, 1, 1, 0.06)
    b.fill = b:CreateTexture(nil, "ARTWORK")
    sliced(b.fill, T.tex.pill, 4)
    b.fill:SetPoint("TOPLEFT")
    b.fill:SetPoint("BOTTOMLEFT")
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
        local w = self:GetWidth() or 0
        self.fill:SetWidth(max(0.001, w * self.value))
        self.fill:SetShown(self.value > 0)
    end
    function b:SetLabel(s) if self.text then self.text:SetText(s or "") end end
    b:SetScript("OnSizeChanged", function(self) self:SetValue(self.value) end)
    b:SetColor(opts.color or "green")
    return b
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
    self:SetBackdrop(b, C.black, C.line)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 1, -1)
    b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.count = self:Text(b, 10, "text", "num", "OUTLINE")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)

    function b:Update()
        local id = self.itemID
        if not id then
            self.icon:SetTexture(nil)
            self:SetBackdropBorderColor(C.line[1], C.line[2], C.line[3], 1)
            return
        end
        self.icon:SetTexture(API.ItemIcon(id))
        local q = API.ItemQuality(self.link or id)
        if q then
            local r, g, bb = API.QualityColor(q)
            self:SetBackdropBorderColor(r, g, bb, 1)
        else
            self:SetBackdropBorderColor(C.line[1], C.line[2], C.line[3], 1)
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

--- Game icon in a bevelled gold frame (action-button style).
-- FramedIcon(parent, size, icon) -> frame with :SetIcon(icon), :SetDesaturated(bool)
function UI:FramedIcon(parent, size, icon)
    size = size or 32
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    local inset = math.max(2, math.floor(size * 0.09 + 0.5))
    f.icon:SetPoint("TOPLEFT", inset, -inset)
    f.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    f.frame = f:CreateTexture(nil, "OVERLAY")
    f.frame:SetAllPoints()
    sliced(f.frame, T.tex.iconFrame, math.max(4, math.floor(size * 0.16)))
    function f:SetIcon(ic)
        UI:SetIcon(self.icon, ic)
        if not self.icon.isGameIcon then
            -- our line icons sit on a dark well so they read like a game icon
            self.icon:SetVertexColor(C.wowGold[1], C.wowGold[2], C.wowGold[3], 1)
        else
            self.icon:SetVertexColor(1, 1, 1, 1)
        end
    end
    function f:SetDesaturated(on) self.icon:SetDesaturated(on and true or false) end
    f.well = f:CreateTexture(nil, "BACKGROUND")
    f.well:SetAllPoints(f.icon)
    f.well:SetColorTexture(0.03, 0.03, 0.03, 1)
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

--- Circular class avatar with a coloured ring.
function UI:Avatar(parent, size)
    size = size or 32
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.ring = f:CreateTexture(nil, "BACKGROUND")
    f.ring:SetTexture(T.tex.circle)
    f.ring:SetAllPoints()
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("TOPLEFT", 2, -2)
    f.icon:SetPoint("BOTTOMRIGHT", -2, 2)
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
--- Tabs(parent, {{key=, text=, icon=}, ...}, onSelect(key)) -> tabs with :Select(key)
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
        b.line = b:CreateTexture(nil, "ARTWORK")
        b.line:SetHeight(2)
        b.line:SetPoint("BOTTOMLEFT", 4, 0)
        b.line:SetPoint("BOTTOMRIGHT", -4, 0)
        b.line:SetColorTexture(C.wowGold[1], C.wowGold[2], C.wowGold[3], 1)
        b.line:Hide()
        b:SetWidth((b.label:GetStringWidth() or 40) + 24 + (it.icon and 16 or 0))
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
            UI:SetTextColor(b.label, on and "wowGold" or "dim")
            if b.icon then local c = on and C.wowGold or C.dim; b.icon:SetVertexColor(c[1], c[2], c[3], 1) end
        end
        if not silent and onSelect then GF:Safe("tabs", onSelect, key) end
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
    -- quest-title Morpheus in the game's gold, over an ornate gold rule
    h.title = self:Text(h, 26, "wowGold", "title")
    h.title:SetPoint("TOPLEFT", 0, 0)
    h.title:SetText(tostring(title or ""))
    if h.title.SetShadowOffset then
        h.title:SetShadowOffset(2, -2)
        h.title:SetShadowColor(0, 0, 0, 0.9)
    end
    h.sub = self:Text(h, 12, "dim")
    h.sub:SetPoint("TOPLEFT", h.title, "BOTTOMLEFT", 1, -3)
    h.sub:SetText(subtitle or "")
    h.rule = h:CreateTexture(nil, "ARTWORK")
    h.rule:SetTexture(T.tex.dividerGold)
    h.rule:SetHeight(12)
    h.rule:SetPoint("TOPLEFT", h, "BOTTOMLEFT", -24, 4)
    h.rule:SetPoint("TOPRIGHT", h, "BOTTOMRIGHT", 24, 4)
    h.rule:SetAlpha(0.85)
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

--- Empty-state block: big faint icon + text, centred in parent.
function UI:Empty(parent, text, icon)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(360, 120)
    f:SetPoint("CENTER")
    f.icon = self:Icon(f, 40, icon or "eye", "ARTWORK", { 1, 1, 1, 0.12 })
    f.icon:SetPoint("TOP", 0, 0)
    f.text = self:Text(f, 13, "faint")
    f.text:SetPoint("TOP", f.icon, "BOTTOM", 0, -12)
    f.text:SetWidth(360)
    f.text:SetJustifyH("CENTER")
    f.text:SetWordWrap(true)
    f.text:SetText(text or "")
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

local function buildModal()
    local overlay = CreateFrame("Frame", "GreenfieldsModal", UIParent)
    overlay:SetFrameStrata("FULLSCREEN_DIALOG")
    overlay:SetAllPoints(UIParent)
    overlay:EnableMouse(true)
    overlay.dim = overlay:CreateTexture(nil, "BACKGROUND")
    overlay.dim:SetAllPoints()
    overlay.dim:SetColorTexture(0, 0, 0, 0.55)
    overlay:Hide()
    tinsert(UISpecialFrames, "GreenfieldsModal")

    local d = UI:Panel(overlay, C.bg1, false)
    d:SetPoint("CENTER", 0, 60)
    UI:Shadow(d, 18)
    d.stone = d:CreateTexture(nil, "BACKGROUND", nil, 1)
    d.stone:SetPoint("TOPLEFT", 3, -3)
    d.stone:SetPoint("BOTTOMRIGHT", -3, 3)
    d.stone:SetTexture(T.tex.stone, "REPEAT", "REPEAT")
    d.stone:SetHorizTile(true)
    d.stone:SetVertTile(true)
    d.stone:SetVertexColor(0.55, 0.6, 0.57, 0.45)
    d.rim = d:CreateTexture(nil, "OVERLAY", nil, 7)
    d.rim:SetPoint("TOPLEFT", -5, 5)
    d.rim:SetPoint("BOTTOMRIGHT", 5, -5)
    sliced(d.rim, T.tex.frameGold, 16)
    overlay.dialog = d
    d.stripe = d:CreateTexture(nil, "ARTWORK")
    d.stripe:SetPoint("TOPLEFT", 1, -1)
    d.stripe:SetPoint("TOPRIGHT", -1, -1)
    d.stripe:SetHeight(3)
    -- title and body get explicit widths (set per modal): measuring a wrapped string whose
    -- width only comes from anchors reads short before the dialog has been laid out
    d.title = UI:Text(d, 20, "wowGold", "title")
    d.title:SetPoint("TOPLEFT", 18, -16)
    d.title:SetWordWrap(true)
    d.text = UI:Text(d, 12, "dim")
    d.text:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -10)
    d.text:SetWordWrap(true)
    d.text:SetJustifyV("TOP")
    d.input = UI:Input(d, { height = 28 })
    d.input:SetPoint("LEFT", 18, 0)
    d.input:SetPoint("RIGHT", -18, 0)
    -- multi-line box for import/export
    d.scroll = CreateFrame("ScrollFrame", nil, d, "BackdropTemplate")
    UI:SetBackdrop(d.scroll, C.bg3, C.line)
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
    d.buttons = {}
    modal = overlay
end

--- Modal{ title, text, width, style ("green"|"yellow"|"red"), input = {default, placeholder},
---        multiline = {text, readOnly}, buttons = { {text, style, onClick(value), keepOpen} } }
function UI:Modal(opts)
    if not modal then buildModal() end
    local d = modal.dialog
    local w = opts.width or 420
    d:SetWidth(w)
    d.title:SetWidth(w - 36)
    d.text:SetWidth(w - 36)
    local stripe = col(opts.style or "green")
    d.stripe:SetColorTexture(stripe[1], stripe[2], stripe[3], 1)
    d.title:SetText(tostring(opts.title or ""))
    local hasText = opts.text ~= nil and opts.text ~= ""
    d.text:SetText(opts.text or "")
    d.input:Hide()
    d.scroll:Hide()
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
        local y = 16 + titleH + 10 + textH + 14
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
