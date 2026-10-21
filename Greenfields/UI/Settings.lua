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
    { key = "feedToasts", label = "Neighbourhood Watch toasts", tip = "Toast when something happens in the guild (level 60s, epics, titles changing hands)." },
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
    { key = "shareWealth", label = "Enter the Mandurah Millionaire ranking", tip = "Shares a rough wealth score (never the amount) so you can be ranked richest/poorest. The UI only ever shows the order." },
}

local function build(page)
    local header = UI:PageHeader(page, "Settings", "Tweak the neighbourhood to your liking.")
    local scroll, content = UI:Scroll(page)
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
    scroll:SetPoint("BOTTOMRIGHT")

    local y = 0
    local colW = 380

    local left = UI:Card(content, { title = "Preferences", icon = "gear" })
    left:SetPoint("TOPLEFT", 0, 0)
    left:SetWidth(colW)
    local ly = 0
    page.toggles = {}
    for _, t in ipairs(TOGGLES) do
        if t.section then
            local s = UI:Text(left.body, 11, "faint", "head")
            s:SetPoint("TOPLEFT", 0, -ly - (ly > 0 and 8 or 0))
            s:SetText(t.section:upper())
            ly = ly + (ly > 0 and 26 or 18)
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
            tg:SetPoint("TOPLEFT", 0, -ly)
            page.toggles[#page.toggles + 1] = tg
            ly = ly + 26
        end
    end
    local mm = UI:Toggle(left.body, "Minimap button", {
        get = function() return not GF.db.settings.minimap.hide end,
        set = function(v) UI:SetMinimapShown(v) end,
    })
    mm:SetPoint("TOPLEFT", 0, -ly - 8)
    page.toggles[#page.toggles + 1] = mm
    ly = ly + 34
    left:SetHeight(ly + 50)

    -- right column: character + window + guild config
    local right = UI:Card(content, { title = "This character", icon = "roster" })
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 16, 0)
    right:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    right:SetHeight(170)
    local mainLbl = UI:Text(right.body, 12, "dim")
    mainLbl:SetPoint("TOPLEFT", 0, 0)
    mainLbl:SetText("Is this an alt? Name your main and your stats, attendance and loot roll up to them.")
    mainLbl:SetPoint("TOPRIGHT", 0, 0)
    mainLbl:SetWordWrap(true)
    local mainBox = UI:Input(right.body, { placeholder = "Main's name (blank = this IS my main)", width = 240 })
    mainBox:SetPoint("TOPLEFT", 0, -40)
    local save = UI:Button(right.body, "Save", { style = "primary", onClick = function()
        GF.Profile:SetMain(U.Trim(mainBox:GetText()))
        UI:Toast({ title = "Sorted", text = GF.cdb.main and ("This character now rolls up to " .. GF.cdb.main .. ".") or "This character is a main.", icon = "check" })
    end })
    save:SetPoint("LEFT", mainBox, "RIGHT", 8, 0)
    page.mainBox = mainBox
    local scaleLbl = UI:Text(right.body, 12, "dim")
    scaleLbl:SetPoint("TOPLEFT", 0, -82)
    scaleLbl:SetText("Window scale")
    local scale = UI:Dropdown(right.body, {
        width = 120,
        items = { { value = 0.8, text = "80%" }, { value = 0.9, text = "90%" }, { value = 1, text = "100%" }, { value = 1.1, text = "110%" }, { value = 1.25, text = "125%" } },
        get = function() return GF.db.settings.scale or 1 end,
        set = function(v)
            GF.db.settings.scale = v
            if GreenfieldsMainFrame then GreenfieldsMainFrame:SetScale(v) end
        end,
    })
    scale:SetPoint("LEFT", scaleLbl, "RIGHT", 12, 0)
    local reset = UI:Button(right.body, "Reset window", { onClick = function() GF.slash.reset.fn("") end })
    reset:SetPoint("LEFT", scale, "RIGHT", 8, 0)

    local guild = UI:Card(content, { title = "Guild config (GM)", icon = "lock", accent = "yellow" })
    guild:SetPoint("TOPLEFT", right, "BOTTOMLEFT", 0, -16)
    guild:SetPoint("TOPRIGHT", right, "BOTTOMRIGHT", 0, -16)
    guild:SetHeight(176)
    local gText = UI:Text(guild.body, 12, "dim")
    gText:SetPoint("TOPLEFT")
    gText:SetPoint("TOPRIGHT")
    gText:SetWordWrap(true)
    gText:SetText("Only the Guild Master can change these. Officers can create raids, run SR and take attendance.")
    local rankLbl = UI:Text(guild.body, 12, "text")
    rankLbl:SetPoint("TOPLEFT", 0, -42)
    rankLbl:SetText("Officer = rank index up to")
    local rank = UI:Dropdown(guild.body, {
        width = 150,
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
    })
    rank:SetPoint("LEFT", rankLbl, "RIGHT", 10, 0)
    local srLbl = UI:Text(guild.body, 12, "text")
    srLbl:SetPoint("TOPLEFT", 0, -80)
    srLbl:SetText("Default soft reserves per player")
    local sr = UI:Dropdown(guild.body, {
        width = 80,
        items = { { value = 1, text = "1" }, { value = 2, text = "2" }, { value = 3, text = "3" } },
        get = function() return GF.Roster:Config().srLimit end,
        set = function(v)
            local cfg = U.Copy(GF.Store:Get("config", "guild") or {})
            cfg.srLimit = v
            GF.Store:Put("config", "guild", cfg)
        end,
    })
    sr:SetPoint("LEFT", srLbl, "RIGHT", 10, 0)
    page.guildDropdowns = { rank, sr }

    local about = UI:Card(content, { title = "About", icon = "star" })
    about:SetPoint("TOPLEFT", guild, "BOTTOMLEFT", 0, -16)
    about:SetPoint("TOPRIGHT", guild, "BOTTOMRIGHT", 0, -16)
    about:SetHeight(120)
    local sign = about.body:CreateTexture(nil, "ARTWORK")
    sign:SetTexture(T.tex.minimap)
    sign:SetSize(48, 48)
    sign:SetPoint("TOPLEFT")
    local at = UI:Text(about.body, 12, "dim")
    at:SetPoint("TOPLEFT", sign, "TOPRIGHT", 12, 0)
    at:SetPoint("TOPRIGHT")
    at:SetWordWrap(true)
    page.aboutText = at

    content:SetHeight(math.max(left:GetHeight(), 170 + 16 + 176 + 16 + 120) + 10)
    page.scroll = scroll
    scroll:SetContentHeight(math.max(left:GetHeight(), 170 + 16 + 176 + 16 + 120) + 10)
end

local function onShow(page)
    for _, t in ipairs(page.toggles) do t:Refresh() end
    page.mainBox:SetText(GF.cdb.main or "")
    page.mainBox:RefreshPlaceholder()
    for _, d in ipairs(page.guildDropdowns) do d:Refresh() end
    page.aboutText:SetText(("Greenfields %s for WoW Forever. Built for the lads from Greenfields, Mandurah WA 6210.\n"
        .. "%s guildies running it right now. /gf for commands, /gf errors if something's cooked."):format(GF.VERSION, GF.Comm:OnlinePeers() + 1))
end

UI:RegisterPage({
    key = "settings", title = "Settings", subtitle = "Tweak the neighbourhood.", icon = "gear",
    group = "tools", order = 990, build = build, onShow = onShow,
})

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
