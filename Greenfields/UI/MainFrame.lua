--[[ Greenfields - UI/MainFrame.lua
     The main window: road-sign header, sidebar navigation, page host.

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
local SIDEBAR_W = 220
local HEADER_H = 76

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
    b.hl:SetColorTexture(1, 1, 1, 0.04)
    b.hl:Hide()
    b.sel = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.sel:SetAllPoints()
    b.sel:SetTexture(T.tex.white)
    if b.sel.SetGradient and CreateColor then
        b.sel:SetGradient("HORIZONTAL", CreateColor(1, 0.78, 0.25, 0.20), CreateColor(1, 0.78, 0.25, 0))
    else
        b.sel:SetColorTexture(1, 0.78, 0.25, 0.10)
    end
    b.sel:Hide()
    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetPoint("TOPLEFT")
    b.bar:SetPoint("BOTTOMLEFT")
    b.bar:SetWidth(3)
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
    b.badge:SetPoint("RIGHT", -12, 0)
    b.badge:Hide()
    b:SetScript("OnEnter", function(self)
        if not self.selected then self.hl:Show(); self:Tint("text") end
    end)
    b:SetScript("OnLeave", function(self)
        self.hl:Hide()
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
                h = UI:Text(nav, 10, "bronze", "ui")
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
            e.head:SetPoint("TOPLEFT", 18, y)
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
            b.label:SetPoint("RIGHT", b.badge, "LEFT", -6, 0)
        else
            b.badge:Hide()
            b.label:SetPoint("RIGHT", b, "RIGHT", -10, 0)
        end
    end
end

-------------------------------------------------------------------------------
-- Pages
-------------------------------------------------------------------------------
function UI:ShowPage(key, arg)
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
        UI:AddHeroArt(page, def.key)
        GF:Safe("page:build:" .. def.key, def.build, page)
    end
    main.current = def.key
    GF.db.ui.lastPage = def.key
    def.frame:Show()
    UI:FadeIn(def.frame, 0.16)
    if def.onShow then GF:Safe("page:show:" .. def.key, def.onShow, def.frame, arg) end
    local navKey = def.navParent or def.key
    for k, b in pairs(main.nav.buttons or {}) do b:SetSelected(k == navKey) end
    self:RefreshNav()
end

function UI:CurrentPage() return main and main.current end

--- Painted banner behind a page's header when Media/art has one (Data/Art.lua). It bleeds
-- to the content edges and fades out into the slate so the cards sit on top cleanly.
function UI:AddHeroArt(page, key)
    local path = GF.Art and GF.Art.heroes and GF.Art.heroes[key]
    if not path then return end
    local hero = page:CreateTexture(nil, "BACKGROUND", nil, -2)
    hero:SetTexture(path)
    hero:SetPoint("TOPLEFT", page, "TOPLEFT", -22, 18)
    hero:SetPoint("TOPRIGHT", page, "TOPRIGHT", 22, 18)
    hero:SetHeight(170)
    hero:SetAlpha(0.75)
    -- crop the 4:1 art to the strip's shape, centred vertically
    local function crop()
        local w = hero:GetWidth() or 0
        if w <= 0 then return end
        local visible = math.min(1, (170 / w) * 4)
        local top = (1 - visible) / 2
        hero:SetTexCoord(0, 1, top, top + visible)
    end
    page:HookScript("OnSizeChanged", crop)
    crop()
    local fade = page:CreateTexture(nil, "BACKGROUND", nil, -1)
    fade:SetPoint("TOPLEFT", hero, "TOPLEFT")
    fade:SetPoint("BOTTOMRIGHT", hero, "BOTTOMRIGHT")
    fade:SetTexture(T.tex.white)
    if fade.SetGradient and CreateColor then
        fade:SetGradient("VERTICAL", CreateColor(C.bg0[1], C.bg0[2], C.bg0[3], 1), CreateColor(C.bg0[1], C.bg0[2], C.bg0[3], 0.15))
    else
        fade:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 0.5)
    end
    page.hero = hero
end

function UI:IsMainShown() return main and main:IsShown() or false end

function UI:OpenMain(key, arg)
    if not main then self:BuildMain() end
    self:ShowPage(key or main.current or GF.db.ui.lastPage or "home", arg)
end

function UI:ToggleMain()
    if main and main:IsShown() then
        main:Hide()
    else
        self:OpenMain()
    end
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
    UI:SetBackdrop(f, C.bg0, C.line)
    UI:Shadow(f, 22)
    tinsert(UISpecialFrames, "GreenfieldsMainFrame")

    -- worn slate under everything, then film grain
    local slate = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    slate:SetTexture(T.tex.stone, "REPEAT", "REPEAT")
    slate:SetHorizTile(true)
    slate:SetVertTile(true)
    slate:SetPoint("TOPLEFT", 1, -1)
    slate:SetPoint("BOTTOMRIGHT", -1, 1)
    slate:SetVertexColor(0.45, 0.5, 0.47, 0.55)
    -- film grain over everything (very subtle)
    local grain = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    grain:SetTexture(T.tex.noise, "REPEAT", "REPEAT")
    grain:SetHorizTile(true)
    grain:SetVertTile(true)
    grain:SetPoint("TOPLEFT", 1, -1)
    grain:SetPoint("BOTTOMRIGHT", -1, 1)
    grain:SetAlpha(0.55)

    ---------------------------------------------------------------- header
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H)
    header.bg = header:CreateTexture(nil, "BACKGROUND")
    header.bg:SetAllPoints()
    header.bg:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 1)
    header.leather = header:CreateTexture(nil, "BACKGROUND", nil, 1)
    header.leather:SetAllPoints()
    header.leather:SetTexture(T.tex.leather, "REPEAT", "REPEAT")
    header.leather:SetHorizTile(true)
    header.leather:SetVertTile(true)
    header.leather:SetVertexColor(0.85, 0.8, 0.75, 0.85)
    if GF.Art and GF.Art.header then
        -- painted street scene behind the sign, darkened so the text stays readable
        header.art = header:CreateTexture(nil, "BACKGROUND", nil, 2)
        header.art:SetAllPoints()
        header.art:SetTexture(GF.Art.header)
        header.art:SetTexCoord(0, 1, 0.3, 0.7)
        header.art:SetVertexColor(0.55, 0.55, 0.55, 1)
    end
    -- streetlight glow behind the sign
    header.glow = header:CreateTexture(nil, "BACKGROUND", nil, 1)
    header.glow:SetTexture(T.tex.glow)
    header.glow:SetVertexColor(C.green[1], C.green[2], C.green[3], 0.10)
    header.glow:SetSize(420, 220)
    header.glow:SetPoint("CENTER", header, "LEFT", 140, 0)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function() f:StopMovingOrSizing(); saveGeometry() end)
    f.header = header

    local logo = header:CreateTexture(nil, "ARTWORK")
    logo:SetTexture(T.tex.logo)
    logo:SetSize(256, 64)
    if GF.Art and GF.Art.crest then
        -- painted guild crest hanging off the left of the sign
        local crest = header:CreateTexture(nil, "ARTWORK", nil, 1)
        crest:SetTexture(GF.Art.crest)
        crest:SetSize(72, 72)
        crest:SetPoint("LEFT", 4, -1)
        logo:SetPoint("LEFT", crest, "RIGHT", 0, 0)
        f.crest = crest
    else
        logo:SetPoint("LEFT", 8, -1)
    end
    f.logo = logo

    f.pageTitle = UI:Text(header, 24, "wowGold", "title")
    f.pageTitle:SetPoint("TOPLEFT", logo, "TOPRIGHT", 18, -12)
    f.pageSub = UI:Text(header, 12, "dim")
    f.pageSub:SetPoint("TOPLEFT", f.pageTitle, "BOTTOMLEFT", 0, -5)

    local close = UI:IconButton(header, "close", 28, "Close (Esc)", function() f:Hide() end)
    close:SetPoint("TOPRIGHT", -10, -10)
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
        tooltip = function() return { "Update available", "A guildie is running a newer Greenfields. Click for how to update." } end })
    f.updatePill:SetScript("OnMouseUp", function() if GF.Update then GF.Update:ShowHowTo() end end)
    f.updatePill:Hide()

    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    line:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
    line:SetHeight(2)
    line:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 1)
    local rule = f:CreateTexture(nil, "OVERLAY")
    rule:SetTexture(T.tex.dividerGold)
    rule:SetHeight(14)
    rule:SetPoint("LEFT", line, "LEFT", 0, 0)
    rule:SetPoint("RIGHT", line, "RIGHT", 0, 0)
    local lineGlow = f:CreateTexture(nil, "ARTWORK")
    lineGlow:SetPoint("TOPLEFT", line, "BOTTOMLEFT")
    lineGlow:SetPoint("TOPRIGHT", line, "BOTTOMRIGHT")
    lineGlow:SetHeight(10)
    lineGlow:SetTexture(T.tex.white)
    if lineGlow.SetGradient and CreateColor then
        lineGlow:SetGradient("VERTICAL", CreateColor(0.24, 0.86, 0.47, 0), CreateColor(0.24, 0.86, 0.47, 0.10))
    else
        lineGlow:SetColorTexture(0.24, 0.86, 0.47, 0.05)
    end

    ---------------------------------------------------------------- sidebar
    local nav = CreateFrame("Frame", nil, f)
    nav:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    nav:SetPoint("BOTTOMLEFT", 1, 1)
    nav:SetWidth(SIDEBAR_W)
    nav.bg = nav:CreateTexture(nil, "BACKGROUND")
    nav.bg:SetAllPoints()
    nav.bg:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 0.85)
    nav.leather = nav:CreateTexture(nil, "BACKGROUND", nil, 1)
    nav.leather:SetAllPoints()
    nav.leather:SetTexture(T.tex.leather, "REPEAT", "REPEAT")
    nav.leather:SetHorizTile(true)
    nav.leather:SetVertTile(true)
    nav.leather:SetVertexColor(0.6, 0.56, 0.52, 0.55)
    local navLine = nav:CreateTexture(nil, "ARTWORK")
    navLine:SetPoint("TOPRIGHT")
    navLine:SetPoint("BOTTOMRIGHT")
    navLine:SetWidth(1)
    navLine:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.8)
    f.nav = nav
    f:HookScript("OnSizeChanged", function() UI:LayoutNav() end)

    -- me card at the bottom of the sidebar
    local me = CreateFrame("Button", nil, nav)
    me:SetPoint("BOTTOMLEFT", 0, 0)
    me:SetPoint("BOTTOMRIGHT", -1, 0)
    me:SetHeight(ME_H)
    me.bg = me:CreateTexture(nil, "BACKGROUND")
    me.bg:SetAllPoints()
    me.bg:SetColorTexture(0, 0, 0, 0.18)
    me.avatar = UI:Avatar(me, 34)
    me.avatar:SetPoint("LEFT", 14, 0)
    me.name = UI:Text(me, 13, "text", "head")
    me.name:SetPoint("TOPLEFT", me.avatar, "TOPRIGHT", 10, -2)
    me.sub = UI:Text(me, 11, "dim")
    me.sub:SetPoint("TOPLEFT", me.name, "BOTTOMLEFT", 0, -3)
    me.sub:SetWidth(SIDEBAR_W - 70)
    me:SetScript("OnClick", function()
        if UI.OpenProfile then UI:OpenProfile(API.MyKey()) end
    end)
    f.me = me

    ---------------------------------------------------------------- content
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 22, -18)
    content:SetPoint("BOTTOMRIGHT", -22, 18)
    f.content = content

    ---------------------------------------------------------------- gold frame
    local chrome = CreateFrame("Frame", nil, f)
    chrome:SetPoint("TOPLEFT", -6, 6)
    chrome:SetPoint("BOTTOMRIGHT", 6, -6)
    chrome:SetFrameLevel(f:GetFrameLevel() + 40)
    chrome:EnableMouse(false)
    chrome.rim = chrome:CreateTexture(nil, "OVERLAY")
    chrome.rim:SetAllPoints()
    UI.Sliced(chrome.rim, T.tex.frameGold, 16)
    local CORNERS = {
        { "TOPLEFT", -4, 4, 0, 1, 0, 1 }, { "TOPRIGHT", 4, 4, 1, 0, 0, 1 },
        { "BOTTOMLEFT", -4, -4, 0, 1, 1, 0 }, { "BOTTOMRIGHT", 4, -4, 1, 0, 1, 0 },
    }
    for _, c in ipairs(CORNERS) do
        local t = chrome:CreateTexture(nil, "OVERLAY", nil, 1)
        t:SetTexture(T.tex.cornerGold)
        t:SetSize(46, 46)
        t:SetPoint(c[1], chrome, c[1], c[2], c[3])
        t:SetTexCoord(c[4], c[5], c[6], c[7])
    end
    f.chrome = chrome

    ---------------------------------------------------------------- resize grip
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip.tex = grip:CreateTexture(nil, "OVERLAY")
    grip.tex:SetAllPoints()
    grip.tex:SetTexture(T.Icon("chevron_right"))
    grip.tex:SetRotation(-math.pi / 4)
    grip.tex:SetVertexColor(C.faint[1], C.faint[2], C.faint[3], 0.8)
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
    -- header: a greeting (or the GM's message of the day) over a rotating tagline;
    -- the page's own header carries the page title, so it isn't repeated up here
    local motd = GF.Roster:Config().motd
    if type(motd) == "string" and motd ~= "" then
        main.pageTitle:SetText(U.Truncate(motd, 60))
    else
        main.pageTitle:SetText(("G'DAY, %s"):format(U.ShortName(API.MyKey() or "legend")):upper())
    end
    if fresh or not main.tagline then main.tagline = U.Pick(GF.Flavor.taglines) end
    main.pageSub:SetText(main.tagline)
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
end

GF:On("GF_ROSTER_UPDATED", function() if main and main:IsShown() then UI:UpdateChrome() end end)

GF:On("GF_LOGIN", function()
    UI:BuildMain()
    UI:BuildNav()
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
