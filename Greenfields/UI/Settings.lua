--[[ Greenfields - UI/Settings.lua
     The Settings page inside the main window, plus a small canvas in the game's own
     Settings panel that just points here (canvas, not vertical layout: the vertical
     layout's search walk spreads taint on Forever). ]]

local _, GF = ...

local UI = GF.UI
local T = GF.Theme
local C = T.c
local API, U = GF.API, GF.Util

local TOGGLES = {
    { section = "Notifications" },
    { key = "toasts", label = "Road-sign toasts", tip = "Pop-up signs for guild news, SR wins, camp pings and the like." },
    { key = "toastSounds", label = "Toast sounds" },
    { key = "feedToasts", label = "Neighbourhood Watch toasts", tip = "Pop a road sign when the street has news: milestone dings, badges, boss kills, 300 tradies and new locals. Crowns and loot stay in the Watch." },
    { key = "welcome", label = "Login greeting" },
    { key = "campPings", label = "Camp duty pings", tip = "Let raid leaders ping you to drop your camp object." },
    { section = "Raid" },
    { key = "srPopups", label = "SR loot reminders", tip = "When an item drops: tells you if you reserved it (hit Need) or if someone else did (pass)." },
    { key = "srAutoAnnounce", label = "Announce SR'd drops (when you're running the SR)" },
    { key = "wipeRoastsLocal", label = "Wipe roasts (just for you)" },
    { key = "wipeRoastsRaid", label = "Wipe roasts in raid chat (leader only)", tip = "When you're raid leader, a wipe pops a sign - click it to read the roast out in raid chat. Use responsibly. Or don't." },
    { section = "Tooltips" },
    { key = "tooltipSR", label = "Show soft reserves on item tooltips" },
    { key = "tooltipCrafters", label = "Show guild crafters on item tooltips" },
    { key = "tooltipTitles", label = "Show Greenfields titles on player tooltips" },
    { section = "Privacy" },
    { key = "shareWealth", label = "Enter the Mandurah Millionaire ranking", tip = "Ranks you richest or poorest. The amount stays hidden on screen, but the score it shares shows other locals your gold to within about double. Untick it and you're off the board." },
}

local LABEL_X, CONTROL_W = 220, 130   -- the form grid: labels left, controls on one line down the page
local STACK_BELOW = 700               -- a content area narrower than this gets one column
local LEFT_MIN = 372                  -- the longest toggle label needs this
local TOGGLE_PITCH, SECTION_H = 24, 22

--- A label and a control, on the grid. Place it with :SetRow(y, bodyWidth).
local function formRow(parent, label, control)
    local lbl = UI:Text(parent, 12, "text")
    lbl:SetText(label)
    function control:SetRow(y, w)
        local x = math.min(LABEL_X, w - CONTROL_W)
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", x, -y)
        lbl:ClearAllPoints()
        lbl:SetPoint("TOPLEFT", 0, -y - 6)
    end
    control:SetWidth(CONTROL_W)
    return control
end

local function build(page)
    local header = UI:PageHeader(page, "Settings", "Tweak the neighbourhood to your liking.")
    local scroll, content = UI:Scroll(page, { outside = true })
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -14)
    scroll:SetPoint("BOTTOMRIGHT")
    page.scroll = scroll

    local left = UI:Card(content, { title = "Preferences", icon = "gear" })
    page.toggles = {}
    local prefRows = {}
    for _, t in ipairs(TOGGLES) do
        if t.section then
            prefRows[#prefRows + 1] = { section = UI:SectionLabel(left.body, t.section) }
        else
            local tg = UI:Toggle(left.body, t.label, {
                get = function() return GF.db.settings[t.key] and true or false end,
                set = function(v)
                    GF.db.settings[t.key] = v
                    if t.key == "shareWealth" and GF.Profile then GF.Profile:Touch() end
                    GF:Fire("GF_SETTING_CHANGED", t.key, v)
                end,
                tooltip = t.tip,
            })
            page.toggles[#page.toggles + 1] = tg
            prefRows[#prefRows + 1] = { toggle = tg }
        end
    end
    local toggleCount = #page.toggles

    -- right column: character, window, guild config, about
    local char = UI:Card(content, { title = "This character", icon = "roster" })
    local mainLbl = UI:Para(char.body, 12, "dim")
    mainLbl:SetPoint("TOPLEFT")
    mainLbl:SetText("Is this an alt? Name your main and your stats, attendance and loot roll up to them.")
    local mainBox = UI:Input(char.body, { placeholder = "Main's name (blank = this IS my main)", width = 240 })
    local save = UI:Button(char.body, "Save", { style = "primary", onClick = function()
        GF.Profile:SetMain(U.Trim(mainBox:GetText()))
        UI:Toast({ title = "Sorted", text = GF.cdb.main and ("This character now rolls up to " .. GF.cdb.main .. ".") or "This character is a main.", icon = "check" })
    end })
    save:SetPoint("LEFT", mainBox, "RIGHT", 8, 0)
    page.mainBox = mainBox

    local win = UI:Card(content, { title = "Window", icon = "home" })
    local scale = formRow(win.body, "Window scale", UI:Dropdown(win.body, {
        items = { { value = 0.8, text = "80%" }, { value = 0.9, text = "90%" }, { value = 1, text = "100%" }, { value = 1.1, text = "110%" }, { value = 1.25, text = "125%" } },
        get = function() return GF.db.settings.scale or 1 end,
        set = function(v)
            GF.db.settings.scale = v
            if GreenfieldsMainFrame then GreenfieldsMainFrame:SetScale(v) end
        end,
    }))
    local mm = UI:Toggle(win.body, "Minimap button", {
        get = function() return not GF.db.settings.minimap.hide end,
        set = function(v) UI:SetMinimapShown(v) end,
    })
    page.toggles[#page.toggles + 1] = mm
    local reset = UI:Button(win.body, "Reset window", { height = 24, width = CONTROL_W, onClick = function() GF.slash.reset.fn("") end })

    local guild = UI:Card(content, { title = "Guild config (GM)", icon = "lock", accent = "yellow" })
    page.guildCard = guild
    local gText = UI:Para(guild.body, 12, "dim")
    gText:SetPoint("TOPLEFT")
    gText:SetText("Only the Guild Master can change these. Officers can create raids, run SR and take attendance.")
    local rank = formRow(guild.body, "Officer = rank index up to", UI:Dropdown(guild.body, {
        items = function()
            local out = {}
            for i = 0, 9 do out[#out + 1] = { value = i, text = i .. (i == 0 and " (GM only)" or "") } end
            return out
        end,
        get = function() return GF.Roster:Config().officerRank end,
        set = function(v)
            local cfg = U.Copy(GF.Store:Get("config", "guild") or {})
            cfg.officerRank = v
            local ok, err = GF.Store:Put("config", "guild", cfg)
            if not ok then UI:Toast({ title = "Nah", text = "Only the GM can change that (" .. tostring(err) .. ").", style = "red", icon = "lock" }) end
        end,
    }))
    local sr = formRow(guild.body, "Default soft reserves per player", UI:Dropdown(guild.body, {
        items = { { value = 1, text = "1" }, { value = 2, text = "2" }, { value = 3, text = "3" } },
        get = function() return GF.Roster:Config().srLimit end,
        set = function(v)
            local cfg = U.Copy(GF.Store:Get("config", "guild") or {})
            cfg.srLimit = v
            GF.Store:Put("config", "guild", cfg)
        end,
    }))
    page.guildDropdowns = { rank, sr }

    local about = UI:Card(content, {})
    local crest = about.body:CreateTexture(nil, "ARTWORK")
    crest:SetTexture(GF.Art and GF.Art.crest or T.tex.minimap)
    crest:SetSize(56, 56)
    crest:SetPoint("TOPLEFT", -2, 2)
    local aboutName = UI:Text(about.body, 14, "wowGold", "ui")
    aboutName:SetPoint("TOPLEFT", 64, 0)
    page.aboutName = aboutName
    local at = UI:Para(about.body, 12, "dim")
    at:SetPoint("TOPLEFT", aboutName, "BOTTOMLEFT", 0, -4)
    page.aboutText = at

    -- Everything below is measured, not fixed: wrapped copy changes height with the window, and the
    -- columns stack when the window's too narrow for two.
    local CARD_HEAD, CARD_FOOT = 38, 10
    local function layCharacter(w)
        mainLbl:SetWidth(w)
        local y = math.max(14, mainLbl:GetStringHeight() or 14) + 8
        mainBox:ClearAllPoints()
        mainBox:SetPoint("TOPLEFT", 0, -y)
        mainBox:SetWidth(math.min(320, w - 8 - save:GetWidth()))
        return CARD_HEAD + y + 26 + CARD_FOOT
    end
    local function layWindow(w)
        scale:SetRow(0, w)
        mm:ClearAllPoints()
        mm:SetPoint("TOPLEFT", 0, -33)
        reset:ClearAllPoints()
        reset:SetPoint("TOPLEFT", math.min(LABEL_X, w - CONTROL_W), -32)
        return CARD_HEAD + 56 + CARD_FOOT
    end
    local function layGuild(w)
        gText:SetWidth(w)
        local y = math.max(14, gText:GetStringHeight() or 14) + 8
        rank:SetRow(y, w)
        sr:SetRow(y + 32, w)
        return CARD_HEAD + y + 58 + CARD_FOOT
    end
    local function layAbout(w)
        at:SetWidth(math.max(40, w - 64))
        local textH = 18 + 4 + math.max(14, at:GetStringHeight() or 14)
        return math.max(52, textH) + 24
    end
    local function layPrefs(pitch)
        local y = 0
        for _, r in ipairs(prefRows) do
            if r.section then
                if y > 0 then y = y + 4 end
                r.section:ClearAllPoints()
                r.section:SetPoint("TOPLEFT", 0, -y)
                r.section:SetPoint("TOPRIGHT", 0, -y)
                y = y + SECTION_H
            else
                r.toggle:ClearAllPoints()
                r.toggle:SetPoint("TOPLEFT", 0, -y)
                y = y + pitch
            end
        end
        return CARD_HEAD + y + CARD_FOOT
    end

    local rightCards = { char, win, guild, about }
    local layouts = { layCharacter, layWindow, layGuild, layAbout }
    local lastW
    local function relayout(force)
        local W = content:GetWidth() or 0
        if W < 100 or (W == lastW and not force) then return end
        lastW = W
        local stacked = W < STACK_BELOW
        local leftW = stacked and W or math.max(LEFT_MIN, math.floor((W - 16) / 2))
        local rightW = stacked and W or (W - 16 - leftW)
        local total = 0
        for i, card in ipairs(rightCards) do
            local h = layouts[i](rightW - 24)
            card:SetSize(rightW, h)
            total = total + h + (i > 1 and 16 or 0)
        end
        local leftH = layPrefs(TOGGLE_PITCH)
        if not stacked and leftH < total then
            -- spare height opens the rows up a little, so the two columns end level
            leftH = layPrefs(math.min(TOGGLE_PITCH + 3, TOGGLE_PITCH + (total - leftH) / toggleCount))
            leftH = math.max(leftH, total)
        elseif not stacked and leftH > total then
            about:SetHeight(about:GetHeight() + leftH - total)
        end
        left:ClearAllPoints()
        left:SetPoint("TOPLEFT", 0, 0)
        left:SetSize(leftW, leftH)
        local y = stacked and (leftH + 16) or 0
        local x = stacked and 0 or (leftW + 16)
        for _, card in ipairs(rightCards) do
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", x, -y)
            y = y + card:GetHeight() + 16
        end
        local height = stacked and (y - 16) or math.max(leftH, y - 16)
        content:SetHeight(height)
        scroll:SetContentHeight(height)
    end
    page.relayout = relayout
    content:HookScript("OnSizeChanged", function() relayout() end)
end

--- Locked controls look locked; only the GM's are live.
local function lockGuildCard(page)
    local isGM = GF.Roster:IsGM(API.MyKey())
    for _, d in ipairs(page.guildDropdowns) do
        d:Refresh()
        d:SetLocked(not isGM)
    end
    local icon = page.guildCard.icon
    if icon then
        UI:SetIcon(icon, isGM and "crown" or "lock")
        local c = isGM and C.wowGold or C.yellow
        icon:SetVertexColor(c[1], c[2], c[3], 1)
    end
end

local function onShow(page)
    for _, t in ipairs(page.toggles) do t:Refresh() end
    page.mainBox:SetText(GF.cdb.main or "")
    page.mainBox:RefreshPlaceholder()
    lockGuildCard(page)
    page.aboutName:SetText("Greenfields " .. GF.VERSION)
    page.aboutText:SetText(("For WoW Forever. Built for the lads from Greenfields, Mandurah WA 6210.\n"
        .. "%s guildies running it right now. /gf for commands, /gf errors if something's cooked."):format(GF.Comm:OnlinePeers() + 1))
    page.relayout(true)
end

local settingsDef = {
    key = "settings", title = "Settings", subtitle = "Tweak the neighbourhood.", icon = "gear",
    group = "tools", order = 990, build = build, onShow = onShow,
}
UI:RegisterPage(settingsDef)

-- your rank can turn up after the page is already open
GF:On("GF_ROSTER_UPDATED", function()
    if settingsDef.frame and UI:CurrentPage() == "settings" then lockGuildCard(settingsDef.frame) end
end)

-------------------------------------------------------------------------------
-- Game Settings panel entry
-------------------------------------------------------------------------------
GF:On("GF_LOGIN", function()
    local S = rawget(_G, "Settings")
    if not (S and S.RegisterCanvasLayoutCategory and S.RegisterAddOnCategory) then return end
    local canvas = CreateFrame("Frame")
    canvas:Hide()
    local logo = canvas:CreateTexture(nil, "ARTWORK")
    logo:SetTexture(T.tex.logo)
    logo:SetSize(384, 96)
    logo:SetPoint("TOPLEFT", 16, -16)
    local txt = UI:Text(canvas, 13, "text")
    txt:SetPoint("TOPLEFT", logo, "BOTTOMLEFT", 4, -12)
    txt:SetText("Everything lives in the Greenfields window. Type /gf or click below.")
    local open = UI:Button(canvas, "Open Greenfields", { style = "primary", height = 30, onClick = function()
        if SettingsPanel and SettingsPanel.IsShown and SettingsPanel:IsShown() and HideUIPanel then pcall(HideUIPanel, SettingsPanel) end
        GF:After(0, function() UI:OpenMain("settings") end)
    end })
    open:SetPoint("TOPLEFT", txt, "BOTTOMLEFT", 0, -14)
    local ok, cat = pcall(S.RegisterCanvasLayoutCategory, canvas, "Greenfields")
    if ok and cat then pcall(S.RegisterAddOnCategory, cat) end
end)
