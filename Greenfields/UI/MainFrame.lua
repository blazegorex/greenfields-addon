--[[ Greenfields - UI/MainFrame.lua
     The main window: a night scene behind the road-sign header, sidebar navigation, page host,
     all inside a forged gold frame.

       UI:RegisterPage{ key, title, subtitle, icon, order, group,
                        build(page)          -- called once, lazily, the first time the page opens
                        onShow(page), onHide(page),
                        badge() -> number|string|nil,  -- sidebar count bubble
                        hidden() -> bool }   -- hide from nav (e.g. officer-only)
       UI:ShowPage(key [, arg])   -- arg is passed to onShow(page, arg)
       UI:ToggleMain()  UI:OpenMain(key)  UI:IsMainShown()  UI:RefreshNav()
     Pages are plain frames filling the content area; build them with the widget kit. ]]

local _, GF = ...

local UI = GF.UI
local T = GF.Theme
local C = T.c
local API, U = GF.API, GF.Util
local max = math.max

UI.pages = {}
UI.pageList = {}

local GROUPS = {
    { key = "street", label = "THE STREET" },
    { key = "raid", label = "RAID NIGHTS" },
    { key = "community", label = "THE LOCALS" },
    { key = "tools", label = "TOOLS" },
}

local main
-- sidebar rows grow a little to fill the spare height; plain line icons, no frames
local NAV_H_MIN, NAV_H_MAX = 30, 36
local NAV_ICON = 20
local NAV_TOP, NAV_HEAD, NAV_GAP = 12, 16, 6
local ME_H = 64
local SIDEBAR_W = 232     -- "Neighbourhood Watch" has to fit beside a count
local HEADER_H = 76
local SCENE_W, SCENE_H = 1040, 148   -- what the banner art is painted for, in UI units
local SCENE_SOLID = 130   -- fully opaque down to here, then it dissolves into the window
local CORNER = 112        -- gum-leaf corner pieces

function UI:RegisterPage(def)
    assert(def.key and def.title, "page needs key + title")
    def.order = def.order or 100
    def.group = def.group or "tools"
    self.pages[def.key] = def
    self.pageList[#self.pageList + 1] = def
    table.sort(self.pageList, function(a, b) return a.order < b.order end)
    if main then self:BuildNav() end
end

-------------------------------------------------------------------------------
-- Navigation
-------------------------------------------------------------------------------
local function navButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(NAV_H_MIN)
    b.hl = b:CreateTexture(nil, "BACKGROUND")
    b.hl:SetAllPoints()
    UI:Gradient(b.hl, "HORIZONTAL", 1, 0.90, 0.68, 0.075, 0)
    b.hl:Hide()
    b.sel = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.sel:SetAllPoints()
    UI:Gradient(b.sel, "HORIZONTAL", 1, 0.78, 0.25, 0.22, 0)
    b.sel:Hide()
    b.bar = b:CreateTexture(nil, "ARTWORK")
    -- in from the edge: the window's rim covers the first few units
    b.bar:SetPoint("TOPLEFT", 5, 0)
    b.bar:SetPoint("BOTTOMLEFT", 5, 0)
    b.bar:SetWidth(2)
    b.bar:SetColorTexture(C.wowGold[1], C.wowGold[2], C.wowGold[3], 1)
    b.bar:Hide()
    b.icon = UI:Icon(b, NAV_ICON)
    b.icon:SetPoint("LEFT", 16, 0)
    function b:Tint(name)
        local c = C[name]
        self.icon:SetVertexColor(c[1], c[2], c[3], 1)
        UI:SetTextColor(self.label, name)
    end
    b.label = UI:Text(b, 13, "dim", "ui")
    b.label:SetPoint("LEFT", b.icon, "RIGHT", 10, 0)
    -- bounded on the right so a long name truncates instead of spilling into the page
    b.label:SetPoint("RIGHT", b, "RIGHT", -10, 0)
    b.badge = UI:Pill(b, "", "green", { height = 16, size = 10 })
    b.badge:SetPoint("RIGHT", -8, 0)
    b.badge:Hide()
    b:SetScript("OnEnter", function(self)
        if not self.selected then UI:Ease(self.hl, 1, 0.12); self:Tint("text") end
    end)
    b:SetScript("OnLeave", function(self)
        UI:Ease(self.hl, 0, 0.2, true)
        if not self.selected then self:Tint("dim") end
    end)
    b:SetScript("OnClick", function(self)
        UI.Sound(841)
        UI:ShowPage(self.key)
    end)
    function b:SetSelected(on)
        self.selected = on
        self.sel:SetShown(on)
        self.bar:SetShown(on)
        self:Tint(on and "wowGold" or "dim")
    end
    return b
end

function UI:BuildNav()
    if not main then return end
    local nav = main.nav
    nav.buttons = nav.buttons or {}
    nav.headers = nav.headers or {}
    for _, b in pairs(nav.buttons) do b:Hide() end
    for _, h in pairs(nav.headers) do h:Hide() end
    local order = {}
    for _, g in ipairs(GROUPS) do
        local any = false
        for _, def in ipairs(self.pageList) do
            if def.group == g.key and not (def.hidden and def.hidden()) then any = true break end
        end
        if any then
            local h = nav.headers[g.key]
            if not h then
                h = UI:Text(nav, 11, "bronze", "ui")
                h:SetAlpha(0.9)
                nav.headers[g.key] = h
            end
            h:SetText(g.label)
            h:Show()
            order[#order + 1] = { head = h }
            for _, def in ipairs(self.pageList) do
                if def.group == g.key and not (def.hidden and def.hidden()) then
                    local b = nav.buttons[def.key]
                    if not b then
                        b = navButton(nav)
                        b.key = def.key
                        nav.buttons[def.key] = b
                    end
                    -- plain line icons: pictures here made the sidebar too busy
                    UI:SetIcon(b.icon, def.icon or "dot")
                    b.label:SetText(def.title)
                    local cur = main.current and self.pages[main.current]
                    b:SetSelected((cur and (cur.navParent or cur.key)) == def.key)
                    b:Show()
                    order[#order + 1] = { button = b }
                end
            end
        end
    end
    nav.order = order
    self:LayoutNav()
    self:RefreshNav()
end

--- Places the sidebar rows, sizing them to the window: as tall as fits between the header
-- and the me card, within NAV_H_MIN..NAV_H_MAX. Re-run whenever the window is resized.
function UI:LayoutNav()
    local order = main and main.nav.order
    if not order then return end
    local rows, heads = 0, 0
    for _, e in ipairs(order) do
        if e.button then rows = rows + 1 else heads = heads + 1 end
    end
    if rows == 0 then return end
    local room = (main:GetHeight() or 0) - HEADER_H - 3 - ME_H - NAV_TOP - 8 - heads * (NAV_HEAD + NAV_GAP)
    local rowH = U.Clamp(math.floor(room / rows), NAV_H_MIN, NAV_H_MAX)
    local y = -NAV_TOP
    for i, e in ipairs(order) do
        if e.button then
            local b = e.button
            b:SetHeight(rowH)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 0, y)
            b:SetPoint("TOPRIGHT", 0, y)
            y = y - rowH
        else
            if i > 1 then y = y - NAV_GAP end
            e.head:ClearAllPoints()
            e.head:SetPoint("TOPLEFT", 16, y)
            y = y - NAV_HEAD
        end
    end
end

function UI:RefreshNav()
    if not main or not main.nav.buttons then return end
    for key, b in pairs(main.nav.buttons) do
        local def = self.pages[key]
        local val = def and def.badge and select(2, GF:Safe("badge:" .. key, def.badge))
        if val and val ~= 0 and val ~= "" then
            b.badge:SetText(tostring(val), type(val) == "string" and "yellow" or "green")
            b.badge:Show()
            -- a word in the badge ("!", "REC") means it wants you; a count is just news
            UI:Attention(b.badge, type(val) == "string", T.c.wowGold)
            b.label:SetPoint("RIGHT", b.badge, "LEFT", -4, 0)
        else
            b.badge:Hide()
            UI:Attention(b.badge, false)
            b.label:SetPoint("RIGHT", b, "RIGHT", -10, 0)
        end
    end
end

-------------------------------------------------------------------------------
-- Pages
-------------------------------------------------------------------------------
function UI:ShowPage(key, arg)
    if GF.gateShut then return self:ShowGate() end
    if not main then self:BuildMain() end
    local def = self.pages[key] or self.pageList[1]
    if not def then return end
    if not main:IsShown() then main:Show() end
    if main.current and main.current ~= def.key then
        local old = self.pages[main.current]
        if old and old.frame then
            old.frame:Hide()
            if old.onHide then GF:Safe("page:hide", old.onHide, old.frame) end
        end
    end
    if not def.frame then
        local page = CreateFrame("Frame", nil, main.content)
        page:SetAllPoints(main.content)
        page.def = def
        def.frame = page
        GF:Safe("page:build:" .. def.key, def.build, page)
    end
    main.current = def.key
    GF.db.ui.lastPage = def.key
    UI:SetScene(def)
    def.frame:Show()
    UI:FadeIn(def.frame, 0.16)
    if def.onShow then GF:Safe("page:show:" .. def.key, def.onShow, def.frame, arg) end
    local navKey = def.navParent or def.key
    for k, b in pairs(main.nav.buttons or {}) do b:SetSelected(k == navKey) end
    self:RefreshNav()
end

function UI:CurrentPage() return main and main.current end

--- The night outside the window. One scene runs across the top of the whole window, behind the
-- header and the page title, and changes with the page (Data/Art.lua, tools/make_scenes.py).
local function sceneLayer(parent)
    local l = CreateFrame("Frame", nil, parent)
    l:SetPoint("TOPLEFT", 1, -1)
    l:SetPoint("TOPRIGHT", -1, -1)
    l:SetHeight(SCENE_H)
    l.top = l:CreateTexture(nil, "BACKGROUND")
    l.top:SetPoint("TOPLEFT")
    l.top:SetPoint("TOPRIGHT")
    l.top:SetHeight(SCENE_SOLID)
    l.low = l:CreateTexture(nil, "BACKGROUND")
    l.low:SetPoint("TOPLEFT", l.top, "BOTTOMLEFT")
    l.low:SetPoint("BOTTOMRIGHT")
    l.fade = l:CreateAnimationGroup()
    local a = l.fade:CreateAnimation("Alpha")
    a:SetFromAlpha(0)
    a:SetToAlpha(1)
    a:SetDuration(0.28)
    a:SetSmoothing("OUT")
    l:Hide()
    return l
end

-- A narrower window than the art was painted for loses its sides. A wider one scales the art up
-- and loses more sky than ground, because the lit windows sit low and the band fades out there.
local function cropScene(l)
    local w = l:GetWidth() or 0
    if w <= 0 then return end
    local u0, u1, v0, v1 = 0, 1, 0, 1
    if w < SCENE_W then
        u0 = (1 - w / SCENE_W) / 2
        u1 = 1 - u0
    else
        local spare = 1 - SCENE_W / w
        v0 = spare * 0.6
        v1 = 1 - spare * 0.4
    end
    local vm = v0 + (v1 - v0) * (SCENE_SOLID / SCENE_H)
    l.top:SetTexCoord(u0, u1, v0, vm)
    l.low:SetTexCoord(u0, u1, vm, v1)
end

--- Crossfades to a page's scene: its own, else its nav parent's, else The Street's.
function UI:SetScene(def)
    if not main then return end
    local heroes = GF.Art and GF.Art.heroes
    local path = heroes and (heroes[def.scene or def.key] or heroes[def.navParent or ""] or heroes.home)
    if not path or main.scenePath == path then return end
    main.scenePath = path
    local new, old = main.sceneA, main.sceneB
    if main.sceneOn == new then new, old = old, new end
    main.sceneOn = new
    new.top:SetTexture(path)
    new.low:SetTexture(path)
    self:Gradient2(new.low, "VERTICAL", 1, 1, 1, 0, 1)
    cropScene(new)
    new:SetFrameLevel(main:GetFrameLevel() + 2)
    old:SetFrameLevel(main:GetFrameLevel() + 1)
    new:Show()
    if main:IsShown() and old:IsShown() then
        new.fade:SetScript("OnFinished", function() if main.sceneOn == new then old:Hide() end end)
        new.fade:Stop()
        new.fade:Play()
    else
        old:Hide()
    end
end

function UI:IsMainShown() return main and main:IsShown() or false end

function UI:OpenMain(key, arg)
    if not main then self:BuildMain() end
    self:ShowPage(key or main.current or GF.db.ui.lastPage or "home", arg)
end

function UI:ToggleMain()
    if GF.gateShut then return self:ToggleGate() end
    if main and main:IsShown() then
        main:Hide()
    else
        self:OpenMain()
    end
end

function UI:HideMain()
    if main then main:Hide() end
end

--- Refresh the visible page (modules call this after data changes).
function UI:RefreshPage(key)
    if not main or not main:IsShown() then return end
    if key and main.current ~= key then return end
    local def = self.pages[main.current]
    if def and def.frame and def.onShow then GF:Safe("page:refresh", def.onShow, def.frame) end
    self:RefreshNav()
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------
local function saveGeometry()
    if not main then return end
    local point, _, relPoint, x, y = main:GetPoint(1)
    GF.db.ui.point = { point, relPoint, x, y }
    GF.db.ui.w, GF.db.ui.h = main:GetWidth(), main:GetHeight()
end

-- the greeting stops short of the pills, whichever are showing
local function fitGreeting()
    local leftmost = (main.updatePill:IsShown() and main.updatePill) or (main.statusPill:IsShown() and main.statusPill) or main.onlinePill
    local right, left = leftmost:GetLeft(), main.pageTitle:GetLeft()
    if right and left then
        local w = max(60, right - left - 14)
        main.pageTitle:SetWidth(w)
        -- the second line sits lower than the pills, so it can run on underneath them
        main.pageSub:SetWidth(max(w, (main.syncDot:GetRight() or right) - left))
    end
end

function UI:BuildMain()
    if main then return main end
    local f = CreateFrame("Frame", "GreenfieldsMainFrame", UIParent, "BackdropTemplate")
    main = f
    f:Hide()
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetResizable(true)
    f:EnableMouse(true)
    if f.SetResizeBounds then f:SetResizeBounds(900, 600, 1600, 1100) end
    f:SetSize(GF.db.ui.w or 1040, GF.db.ui.h or 680)
    local p = GF.db.ui.point
    if p then f:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else f:SetPoint("CENTER", 0, 30) end
    f:SetScale(GF.db.settings.scale or 1)
    UI:SetBackdrop(f, { 0, 0, 0, 0 }, false)
    UI:Shadow(f, 26)
    tinsert(UISpecialFrames, "GreenfieldsMainFrame")

    -- the night behind everything; it stretches, so it carries no fine detail
    local night = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    night:SetTexture(T.tex.windowBg)
    night:SetPoint("TOPLEFT", 1, -1)
    night:SetPoint("BOTTOMRIGHT", -1, 1)

    ---------------------------------------------------------------- scene
    f.sceneA = sceneLayer(f)
    f.sceneB = sceneLayer(f)
    f:HookScript("OnSizeChanged", function()
        cropScene(f.sceneA)
        cropScene(f.sceneB)
    end)
    -- shade over the scene: where text and controls sit on it, plus a little grain to bed it in
    local shade = CreateFrame("Frame", nil, f)
    shade:SetPoint("TOPLEFT", 1, -1)
    shade:SetPoint("TOPRIGHT", -1, -1)
    shade:SetHeight(SCENE_H)
    shade:SetFrameLevel(f:GetFrameLevel() + 3)
    shade:EnableMouse(false)
    UI:Scrim(shade, "TOP", HEADER_H, 0.22)
    -- both of these are soft pools, the glow art tinted dark: a straight-edged shade draws a hard
    -- line across the painting. One quarter of the glow, so it stops at the window's corner.
    local ctrl = shade:CreateTexture(nil, "BACKGROUND", nil, 3)
    ctrl:SetTexture(T.tex.glow)
    ctrl:SetTexCoord(0, 0.5, 0.5, 1)
    ctrl:SetVertexColor(0.012, 0.018, 0.035, 0.7)
    ctrl:SetPoint("TOPRIGHT")
    ctrl:SetSize(340, 120)
    -- the page title writes on the sky: a little dark behind it
    local titleShade = shade:CreateTexture(nil, "BACKGROUND", nil, 2)
    titleShade:SetTexture(T.tex.glow)
    titleShade:SetVertexColor(0.012, 0.018, 0.035, 0.72)
    titleShade:SetPoint("CENTER", shade, "TOPLEFT", SIDEBAR_W + 130, -(HEADER_H + 34))
    titleShade:SetSize(820, 190)
    UI:Tiled(f, T.tex.noise, 1, 1, 1, 0.3, 1, "BACKGROUND", 2)

    ---------------------------------------------------------------- header
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H)
    header:SetFrameLevel(f:GetFrameLevel() + 6)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function() f:StopMovingOrSizing(); saveGeometry() end)
    f.header = header

    local logo = header:CreateTexture(nil, "ARTWORK")
    logo:SetTexture(T.tex.logo)
    logo:SetSize(256, 64)
    if GF.Art and GF.Art.crest then
        -- guild crest hanging off the left of the sign
        local crest = header:CreateTexture(nil, "ARTWORK", nil, 1)
        crest:SetTexture(GF.Art.crest)
        crest:SetSize(66, 66)
        crest:SetPoint("LEFT", 20, -1)
        logo:SetPoint("LEFT", crest, "RIGHT", 2, 0)
        f.crest = crest
    else
        logo:SetPoint("LEFT", 22, -1)
    end
    f.logo = logo

    -- a quiet greeting beside the sign: the page title below is the headline, not this
    f.pageTitle = UI:Text(header, 15, { 0.96, 0.90, 0.76, 1 }, "ui")
    f.pageTitle:SetPoint("TOPLEFT", logo, "TOPRIGHT", 14, -13)
    f.pageSub = UI:Text(header, 11, "dim")
    f.pageSub:SetPoint("TOPLEFT", f.pageTitle, "BOTTOMLEFT", 0, -4)
    for _, fs in ipairs({ f.pageTitle, f.pageSub }) do
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 1)
    end

    local close = UI:IconButton(header, "close", 28, "Close (Esc)", function() f:Hide() end)
    close:SetPoint("TOPRIGHT", -26, -10)
    local gear = UI:IconButton(header, "gear", 28, "Settings", function() UI:ShowPage("settings") end)
    gear:SetPoint("RIGHT", close, "LEFT", -2, 0)
    f.syncDot = UI:IconButton(header, "sync", 28, function()
        local s = GF.Comm.stats
        return { "Neighbourhood sync", { "Greenfields users online: " .. GF.Comm:OnlinePeers(), "Messages sent/received: " .. s.sent .. " / " .. s.recv, "Click to sync now" } }
    end, function() GF.Store:Flush(); GF.Store:SyncNow(); GF:Print("Syncing with the neighbourhood...") end)
    f.syncDot:SetPoint("RIGHT", gear, "LEFT", -2, 0)

    f.onlinePill = UI:Pill(header, "", "green", { icon = "dot", height = 20 })
    f.onlinePill:SetPoint("RIGHT", f.syncDot, "LEFT", -10, 0)
    f.statusPill = UI:Pill(header, "", "yellow", { icon = "calendar", height = 20 })
    f.statusPill:SetPoint("RIGHT", f.onlinePill, "LEFT", -6, 0)
    f.statusPill:Hide()
    -- "a newer Greenfields is out" (Core/Update.lua); click for how to update
    f.updatePill = UI:Pill(header, "", "yellow", { icon = "import", height = 20,
        onClick = function() if GF.Update then GF.Update:ShowHowTo() end end,
        tooltip = function() return { "Update available", "A guildie is running a newer Greenfields. Click for how to update." } end })
    f.updatePill:Hide()
    -- the tag art is see-through and a moon can sit right behind these: give them a dark plate
    for _, pill in ipairs({ f.onlinePill, f.statusPill, f.updatePill }) do
        pill.plate = UI:Nine(pill, "pill", "BACKGROUND", -1)
        pill.plate:SetVertexColor(0.03, 0.04, 0.07, 0.9)
    end

    ---------------------------------------------------------------- sidebar
    local nav = CreateFrame("Frame", nil, f)
    nav:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    nav:SetPoint("BOTTOMLEFT", 1, 1)
    nav:SetWidth(SIDEBAR_W)
    nav:SetFrameLevel(f:GetFrameLevel() + 5)
    nav.bg = nav:CreateTexture(nil, "BACKGROUND")
    nav.bg:SetAllPoints()
    nav.bg:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 0.97)
    nav.leather = UI:Tiled(nav, T.tex.leather, 0.72, 0.74, 0.82, 0.34, 0, "BACKGROUND", 1)
    nav.light = nav:CreateTexture(nil, "BACKGROUND", nil, 2)
    nav.light:SetPoint("TOPLEFT")
    nav.light:SetPoint("TOPRIGHT")
    nav.light:SetHeight(90)
    UI:Gradient(nav.light, "VERTICAL", 0.55, 0.62, 0.78, 0, 0.09)
    -- a hard top and right edge, with its shadow falling onto the page
    local navTop = UI:Hairline(nav, "bronze", 0.6, "none")
    navTop:SetPoint("TOPLEFT")
    navTop:SetPoint("TOPRIGHT")
    local navLine = nav:CreateTexture(nil, "ARTWORK")
    navLine:SetPoint("TOPRIGHT")
    navLine:SetPoint("BOTTOMRIGHT")
    navLine:SetWidth(1)
    navLine:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.5)
    local navDrop = nav:CreateTexture(nil, "BACKGROUND", nil, 3)
    navDrop:SetPoint("TOPLEFT", nav, "TOPRIGHT")
    navDrop:SetPoint("BOTTOMLEFT", nav, "BOTTOMRIGHT")
    navDrop:SetWidth(14)
    UI:Gradient(navDrop, "HORIZONTAL", 0, 0, 0, 0.42, 0)
    f.nav = nav
    f:HookScript("OnSizeChanged", function()
        UI:LayoutNav()
        if f.onlinePill then fitGreeting() end
    end)

    -- me card at the bottom of the sidebar
    local me = CreateFrame("Button", nil, nav)
    me:SetPoint("BOTTOMLEFT", 0, 0)
    me:SetPoint("BOTTOMRIGHT", -1, 0)
    me:SetHeight(ME_H)
    me.bg = me:CreateTexture(nil, "BACKGROUND")
    me.bg:SetAllPoints()
    me.bg:SetColorTexture(0, 0, 0, 0.26)
    me.hl = me:CreateTexture(nil, "BACKGROUND", nil, 1)
    me.hl:SetAllPoints()
    me.hl:SetColorTexture(1, 0.90, 0.68, 0.05)
    me.hl:Hide()
    me.rule = UI:Hairline(me, "bronze", 0.42, "none")
    me.rule:SetPoint("TOPLEFT")
    me.rule:SetPoint("TOPRIGHT")
    me.avatar = UI:Avatar(me, 36)
    me.avatar:SetPoint("LEFT", 20, 0)
    me.name = UI:Text(me, 13, "text", "ui")
    me.name:SetPoint("TOPLEFT", me.avatar, "TOPRIGHT", 10, -2)
    me.name:SetWidth(SIDEBAR_W - 76)
    me.sub = UI:Text(me, 11, "dim")
    me.sub:SetPoint("TOPLEFT", me.name, "BOTTOMLEFT", 0, -3)
    me.sub:SetWidth(SIDEBAR_W - 76)
    me:SetScript("OnEnter", function(self) self.hl:Show() end)
    me:SetScript("OnLeave", function(self) self.hl:Hide() end)
    me:SetScript("OnClick", function()
        if UI.OpenProfile then UI:OpenProfile(API.MyKey()) end
    end)
    f.me = me

    ---------------------------------------------------------------- content
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 22, -12)
    content:SetPoint("BOTTOMRIGHT", -22, 18)
    content:SetFrameLevel(f:GetFrameLevel() + 5)
    f.content = content

    ---------------------------------------------------------------- gold frame
    local chrome = CreateFrame("Frame", nil, f)
    chrome:SetAllPoints()
    chrome:SetFrameLevel(f:GetFrameLevel() + 40)
    chrome:EnableMouse(false)
    chrome.rim = UI:Nine(chrome, "window", "OVERLAY")
    -- four corners in one atlas, each lit from the same side as everything else
    local CORNERS = {
        { "TOPLEFT", -6, 6, 0, 0.5, 0, 0.5 }, { "TOPRIGHT", 6, 6, 0.5, 1, 0, 0.5 },
        { "BOTTOMLEFT", -6, -6, 0, 0.5, 0.5, 1 }, { "BOTTOMRIGHT", 6, -6, 0.5, 1, 0.5, 1 },
    }
    for _, c in ipairs(CORNERS) do
        local t = chrome:CreateTexture(nil, "OVERLAY", nil, 1)
        t:SetTexture(T.tex.frameCorners)
        t:SetTexCoord(c[4], c[5], c[6], c[7])
        t:SetSize(CORNER, CORNER)
        t:SetPoint(c[1], chrome, c[1], c[2], c[3])
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
        if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
    end
    f.chrome = chrome

    ---------------------------------------------------------------- resize grip
    -- the bottom-right corner piece is the handle: its gem lights up under the mouse
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(30, 30)
    grip:SetPoint("BOTTOMRIGHT", 6, -6)
    grip:SetFrameLevel(chrome:GetFrameLevel() + 1)
    grip.tex = grip:CreateTexture(nil, "OVERLAY")
    grip.tex:SetTexture(T.tex.glow)
    grip.tex:SetPoint("CENTER", -2, 2)
    grip.tex:SetSize(38, 38)
    grip.tex:SetBlendMode("ADD")
    grip.tex:SetVertexColor(C.green[1], C.green[2], C.green[3], 0.8)
    grip.tex:Hide()
    grip:SetScript("OnEnter", function(self)
        self.tex:Show()
        UI:Tip(self, nil, { "Drag to resize" })
    end)
    grip:SetScript("OnLeave", function(self)
        self.tex:Hide()
        UI:HideTip()
    end)
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing(); saveGeometry() end)

    f:SetScript("OnShow", function()
        UI.Sound(839)
        UI:UpdateChrome(true)
        GF.Roster:Refresh()
    end)
    f:SetScript("OnHide", function()
        UI.Sound(840)
        UI:CloseMenu()
        -- let the visible page stop its tickers too (page switches already do this)
        local def = main.current and UI.pages[main.current]
        if def and def.frame and def.onHide then GF:Safe("page:hide", def.onHide, def.frame) end
    end)

    self:BuildNav()
    return f
end

--- Header pills + me-card; cheap, called on show and on roster/peer changes.
function UI:UpdateChrome(fresh)
    if not main then return end
    -- header: a greeting over a rotating tagline, or the GM's message of the day in their place;
    -- the page's own header carries the page title, so it isn't repeated up here
    local motd = GF.Roster:Config().motd
    if fresh or not main.tagline then main.tagline = U.Pick(GF.Flavor.taglines) end
    if type(motd) == "string" and motd ~= "" then
        main.pageTitle:SetText("Word from the top")
        main.pageSub:SetText(U.Truncate(motd, 60))
    else
        main.pageTitle:SetText(("G'day, %s"):format(U.ShortName(API.MyKey() or "legend")))
        main.pageSub:SetText(main.tagline)
    end
    local online = GF.Roster:OnlineCount()
    main.onlinePill:SetText(online .. " ONLINE", "green")
    local me = API.MyKey()
    local cls = API.UnitClassFile("player")
    main.me.avatar:SetClass(cls)
    main.me.name:SetText(me or "?")
    local sub = (GF.Roster:Get(me) and GF.Roster:Get(me).rankName) or "Greenfields resident"
    if GF.Stats and GF.Stats.TitlesOf then
        local ok, titles = GF:Safe("chrome:titles", GF.Stats.TitlesOf, GF.Stats, me)
        if ok and type(titles) == "table" and titles[1] then sub = T:Wrap("gold", titles[1].title) end
    end
    main.me.sub:SetText(sub)
    -- next raid pill
    local nextEv
    if GF.Raids and GF.Raids.Upcoming then
        local ok, list = GF:Safe("chrome:raids", GF.Raids.Upcoming, GF.Raids, 1)
        if ok and type(list) == "table" then nextEv = list[1] end
    end
    if nextEv and nextEv.time then
        local left = nextEv.time - API.ServerTime()
        if left > 0 and left < 7 * 86400 then
            main.statusPill:SetText("RAID IN " .. U.Duration(left):upper(), "yellow")
            main.statusPill:Show()
        else
            main.statusPill:Hide()
        end
    else
        main.statusPill:Hide()
    end
    -- update pill sits left of whatever else is showing
    local newer = GF.Update and GF.Update:Newest()
    if newer then
        main.updatePill:SetText("UPDATE " .. newer.v, "yellow")
        main.updatePill:ClearAllPoints()
        main.updatePill:SetPoint("RIGHT", main.statusPill:IsShown() and main.statusPill or main.onlinePill, "LEFT", -6, 0)
        main.updatePill:Show()
    else
        main.updatePill:Hide()
    end
    fitGreeting()
end

GF:On("GF_ROSTER_UPDATED", function() if main and main:IsShown() then UI:UpdateChrome() end end)

GF:On("GF_LOGIN", function()
    UI:BuildMain()
    UI:BuildNav()
    -- updated with the game open, then /reloaded: the game may not see files that are brand new, and
    -- every panel would come up blank. Say so, or it just looks broken.
    local probe = main:CreateTexture()
    if probe:SetTexture(T.nine.card.path) == false then
        GF:Print("Fresh paint's in the shed, but it only turns up after you quit and reopen WoW.")
        GF:After(5, function()
            UI:Toast({ title = "Fresh paint", text = "The new art only turns up after you quit and reopen WoW. A /reload won't find it.",
                icon = "warning", style = "yellow", duration = 15, force = true, key = "fresh-paint" })
        end)
    end
end)

GF:RegisterSlash("show", function(arg) UI:OpenMain(arg ~= "" and arg or nil) end, "[page] - open the window (optionally on a page)")
GF:RegisterSlash("reset", function()
    GF.db.ui.point, GF.db.ui.w, GF.db.ui.h = nil, nil, nil
    if main then
        main:ClearAllPoints()
        main:SetPoint("CENTER", 0, 30)
        main:SetSize(1040, 680)
    end
    GF:Print("Window position reset.")
end, "reset the window position and size")
