--[[ Greenfields - Modules/ProfessionsUI.lua
     The Tradies page (The Locals). Three tabs:
       Find a Tradie        trade chips, search over recipe and item names, whisper whoever
                            is on; click a job for the job sheet (every tradie and their skill)
       Residents' Licences  every resident's trades with skill bars, sortable by trade
       Cooldowns            who has a transmute, Mooncloth or Salt Shaker ready, and when
     Presentation only: every number comes from GF.Profs (Modules/Professions.lua).
     Look: every trade, item and recipe icon sits in the kit's gold action-button frame; the
     trade list mirrors the sidebar (gold wash + bar when picked); the job sheet floats in the
     window's gold frame over dark leather; the "open your windows" nudge is a parchment
     notice; cooldown headers are gold Friz over a gold wash.
     UI:ShowPage("tradies", arg) takes an itemID (opens its job sheet), a search string, or
     { person = key } (that resident's trades). /gf tradies [search] opens it too. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c
local D = GF.BuffData
local Profs = GF.Profs

local type, pairs, ipairs, tostring, next, rawget, pcall = type, pairs, ipairs, tostring, next, rawget, pcall
local floor, max, min = math.floor, math.max, math.min
local sort, concat, tinsert, tremove = table.sort, table.concat, table.insert, table.remove

local PAGE = "tradies"
local LEFT_W, DRAWER_W = 212, 296
local CHIP_H = 26
local NAME_W, SIDE_W = 186, 54
local SECONDARY = { 185, 129, 356 }
local DOT = "  \194\183  "
local TABS = { find = true, licences = true, cooldowns = true }

local state = {
    tab = "find", line = nil, search = "", person = nil, selected = nil,
    sort = "name", who = "", bannerClosed = false, scrollToSelected = false,
}
local page
local views = {}
local ticker
local refreshFind, refreshLicences, refreshCooldowns

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function prefs()
    local s = GF.db and GF.db.settings
    if type(s) ~= "table" then return {} end
    if type(s.profs) ~= "table" then s.profs = {} end
    return s.profs
end

local function to255(c) return floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5) end
local DOT_ON = ("|T%s:8:8:0:0:32:32:0:32:0:32:%d:%d:%d|t"):format(T.Icon("dot"), to255(C.green))

local function gameIcon(path, size)
    return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(tostring(path), size, size)
end

local function isMe(key) return key == API.MyKey() end
local function isOnline(key) return GF.Roster:IsOnline(key) and true or false end
local function colored(key) return GF.Roster:Colored(key) end

local function emptyProfs()
    local E = GF.Flavor and GF.Flavor.emptyStates
    return (E and E.profs) or "Nobody's shared their professions yet."
end

local function firstOnline(keys)
    for _, key in ipairs(Profs:OnlineFirst(keys)) do
        if not isMe(key) and isOnline(key) then return key end
    end
    return nil
end

local function onlineCount(keys)
    local n = 0
    for i = 1, #keys do
        if isOnline(keys[i]) then n = n + 1 end
    end
    return n
end

--- "(dot) Bazza, Shazza  +3 more": online first, class-coloured.
local function crafterSummary(keys, shown)
    local list = Profs:OnlineFirst(keys)
    local parts = {}
    for i = 1, min(shown, #list) do
        parts[i] = (isOnline(list[i]) and (DOT_ON .. " ") or "") .. colored(list[i])
    end
    local s = concat(parts, ", ")
    if #list > shown then s = s .. "  " .. T:Wrap("faint", "+" .. (#list - shown) .. " more") end
    return s
end

local function joinNames(names)
    if #names <= 1 then return names[1] or "" end
    return concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

local function cdLength(sec)
    if sec < 3600 then return floor(sec / 60) .. " min" end
    if sec % 3600 == 0 then return tostring(sec / 3600) .. "h" end
    return U.Duration(sec)
end

local function tooltip() return rawget(_G, "GameTooltip") end

local function spellTip(owner, id)
    local gt = tooltip()
    if not gt or type(id) ~= "number" then return end
    gt:SetOwner(owner, "ANCHOR_RIGHT")
    if not pcall(gt.SetSpellByID, gt, id) then gt:AddLine(Profs:RecipeName(id) or "Recipe", 1, 1, 1) end
    gt:Show()
end

local function spellLink(id)
    local CS = rawget(_G, "C_Spell")
    local f = type(CS) == "table" and CS.GetSpellLink
    if type(f) ~= "function" or type(id) ~= "number" then return nil end
    local ok, link = pcall(f, id)
    return ok and API.CleanString(link) or nil
end

-------------------------------------------------------------------------------
-- Item names: cached, requested once, refreshed as they arrive
-------------------------------------------------------------------------------
local itemNames, asked, queue = {}, {}, {}
local waiting = {}     -- asked and not answered yet: each answer refreshes the list once, at most
local draining = false

local function drain()
    if #queue == 0 or not (page and page:IsVisible()) then
        draining = false
        return
    end
    for _ = 1, 20 do
        local id = tremove(queue)
        if not id then break end
        API.RequestItem(id)
    end
    GF:After(0.25, drain)
end

local function startDrain()
    if draining or #queue == 0 then return end
    draining = true
    GF:After(0.05, drain)
end

local function itemName(id)
    local n = itemNames[id]
    if n then return n end
    n = API.CleanString(API.ItemName(id))
    if n then
        itemNames[id] = n
    elseif not asked[id] then
        asked[id], waiting[id] = true, true
        queue[#queue + 1] = id
        startDrain()
    end
    return n
end

local function entryName(e)
    if e.item then
        local n = itemName(e.item)
        if n then return n end
    end
    return Profs:RecipeName(e.recipe) or "Mystery recipe"
end

local function entryColor(e)
    if e.item then
        local q = API.ItemQuality(e.item)
        if type(q) == "number" then return API.QualityColor(q) end
    end
    return C.text[1], C.text[2], C.text[3]
end

-------------------------------------------------------------------------------
-- Shared bits
-------------------------------------------------------------------------------
--- Puts an icon button in the same bevelled gold frame as UI:FramedIcon (action-button look).
local function goldFrame(btn, size)
    local inset = max(2, floor(size * 0.09 + 0.5))
    btn.icon:ClearAllPoints()
    btn.icon:SetPoint("TOPLEFT", inset, -inset)
    btn.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    btn.goldRim = btn:CreateTexture(nil, "OVERLAY")
    btn.goldRim:SetAllPoints()
    UI.Sliced(btn.goldRim, T.tex.iconFrame, max(4, floor(size * 0.16)))
    -- the kit's 1px quality edge would only peek out at the bevelled corners: keep it hidden
    -- (the job's name already carries the quality colour)
    if btn.SetItem and btn.Update then
        local update = btn.Update
        function btn:Update()
            update(self)
            self:SetBackdropBorderColor(0, 0, 0, 0)
        end
    end
    btn:SetBackdropBorderColor(0, 0, 0, 0)
    return btn
end

--- Tileable texture (stone / leather / parchment) filling a region.
local function tiled(tex, path, r, g, b, a)
    tex:SetTexture(path, "REPEAT", "REPEAT")
    tex:SetHorizTile(true)
    tex:SetVertTile(true)
    tex:SetVertexColor(r, g, b, a)
end

--- Small-caps group label, the same bronze Friz the sidebar uses for its groups.
local function groupLabel(parent, text)
    local fs = UI:Text(parent, 10, "bronze", "ui")
    fs:SetText(text)
    return fs
end

--- Square spell icon (enchants have no output item): spell tooltip, shift-click links it.
local function spellButton(parent, size, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(size, size)
    UI:SetBackdrop(b, C.black, false)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    goldFrame(b, size)
    function b:SetRecipe(id)
        self.recipe = id
        self.icon:SetTexture(API.SpellIcon(id))
    end
    b:SetScript("OnEnter", function(self) spellTip(self, self.recipe) end)
    b:SetScript("OnLeave", function() UI:HideTip() end)
    b:SetScript("OnClick", function(self)
        if API.IsShiftKeyDown() then
            local link = spellLink(self.recipe)
            if link then UI:InsertLink(link) end
        elseif onClick then
            GF:Safe("tradies:spell", onClick, self)
        end
    end)
    return b
end

--- A child button forwards a plain click to its list row (select / open the job sheet).
local function clickRow(btn)
    local row = btn:GetParent()
    local fn = row and row:GetScript("OnClick")
    if fn then fn(row, "LeftButton") end
end

--- Keeps the row highlight on while the mouse is over one of its buttons.
local function keepHover(row, child)
    child:HookScript("OnEnter", function() if row.hl then row.hl:Show() end end)
    child:HookScript("OnLeave", function() if row.hl and not row:IsMouseOver() then row.hl:Hide() end end)
end

local function askGuild(e)
    if not e then return end
    if not API.InGuild() then
        UI:Toast({ title = "No guild, no tradies", text = "You need to be in the guild to ask the street.", icon = "warning", style = "yellow" })
        return
    end
    local what = (e.item and API.CleanString(API.ItemLink(e.item))) or spellLink(e.recipe) or entryName(e)
    local msg = ("Anyone able to make %s? Happy to bring the mats."):format(what)
    UI:Confirm("Ask the street", "Post this in guild chat?\n\n" .. msg, function()
        local ok, err = API.SendChat(msg, "GUILD")
        if not ok then
            UI:Toast({
                title = "Couldn't post that",
                text = err == "lockdown" and "Chat messages are restricted right now. Try again after the pull."
                    or "Guild chat said nah. Give it another go in a sec.",
                icon = "warning", style = "yellow",
            })
        end
    end, "Post it", "yellow")
end

-------------------------------------------------------------------------------
-- Find a Tradie: trade chips
-------------------------------------------------------------------------------
local function makeChip(parent, line)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(CHIP_H)
    b.line = line
    -- styled like the sidebar: the trade in a gold frame, a gold wash + bar when picked
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(1, 1, 1, 0.04)
    b.bg:Hide()
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
    b.art = UI:FramedIcon(b, 20, line and Profs:LineIcon(line) or "hammer")
    b.art:SetPoint("LEFT", 8, 0)
    b.icon = b.art.icon
    b.count = UI:Text(b, 11, "dim", "num")
    b.count:SetPoint("RIGHT", -8, 0)
    b.label = UI:Text(b, 12, "text", "ui")
    b.label:SetPoint("LEFT", b.art, "RIGHT", 8, 0)
    b.label:SetPoint("RIGHT", b.count, "LEFT", -6, 0)
    b.label:SetText(line and Profs:LineName(line) or "All trades")

    local function paint(self)
        self.sel:SetShown(self.selected and true or false)
        self.bg:SetShown(not self.selected and self:IsMouseOver())
    end

    function b:Refresh(selected, members, recipes)
        self.selected, self.members, self.recipes = selected, members, recipes
        self.count:SetText(members > 0 and tostring(members) or "")
        self.bar:SetShown(selected)
        UI:SetTextColor(self.label, selected and "wowGold" or (members > 0 and "text" or "faint"))
        UI:SetTextColor(self.count, selected and "wowGold" or "dim")
        if self.icon.isGameIcon then
            self.art:SetDesaturated(members == 0)
            self.art:SetAlpha(members == 0 and 0.45 or 1)
        end
        paint(self)
    end

    b:SetScript("OnEnter", function(self)
        paint(self)
        local who, n = self.members or 0, self.recipes or 0
        UI:Tip(self, self.line and Profs:LineName(self.line) or "All trades", {
            ("%d %s licensed"):format(who, U.Plural(who, "resident")),
            ("%s %s on the books"):format(U.Commas(n), U.Plural(n, "recipe")),
        })
    end)
    b:SetScript("OnLeave", function(self)
        paint(self)
        UI:HideTip()
    end)
    b:SetScript("OnClick", function(self)
        UI.Sound(841)
        state.line = self.line
        state.selected = nil
        refreshFind()
    end)
    return b
end

-------------------------------------------------------------------------------
-- Find a Tradie: result rows
-------------------------------------------------------------------------------
local function whisperTip(self)
    if self.target then return { "Whisper " .. colored(self.target), { "Opens a whisper, ready to type." } } end
    local e = self.entry
    if e and #e.crafters == 1 and isMe(e.crafters[1]) then return "That's you, legend. Craft it yourself." end
    return "Nobody who makes this is on right now. The job sheet can ask the guild for you."
end

--- Natural (untruncated) width of a FontString's text.
local function textWidth(fs)
    local f = fs.GetUnboundedStringWidth or fs.GetStringWidth
    return f(fs) or 0
end

local function findLayout(row)
    local w = row:GetWidth() or 0
    row.laidW, row.laidC = w, row.cNat
    -- the crafters only take what their names need (capped); the job name gets the rest,
    -- so "Bazza" alone doesn't squeeze "Journeyman Campfire Kit" down to "Journeyma..."
    local cap = floor(max(110, w * 0.34))
    local cw = floor(min(cap, max(40, (row.cNat or cap) + 2)))
    row.crafters:SetWidth(cw)
    local nw = max(60, w - 44 - cw - (row.whisper:GetWidth() or 80) - 8 - 20)
    row.name:SetWidth(nw)
    row.sub:SetWidth(nw)
end

local function findCreateRow(row)
    row.itemBtn = goldFrame(UI:ItemButton(row, 28), 28)
    row.itemBtn:SetPoint("LEFT", 6, 0)
    row.itemBtn.onClick = function(btn) if not API.IsShiftKeyDown() then clickRow(btn) end end
    row.spellBtn = spellButton(row, 28, clickRow)
    row.spellBtn:SetPoint("LEFT", 6, 0)
    row.whisper = UI:Button(row, "Whisper", {
        height = 22, size = 11, icon = "bubble", iconSize = 12, tooltip = whisperTip,
        onClick = function(self) if self.target then UI:Whisper(self.target) end end,
    })
    if row.whisper.SetMotionScriptsWhileDisabled then row.whisper:SetMotionScriptsWhileDisabled(true) end
    row.whisper:SetPoint("RIGHT", -8, 0)
    row.crafters = UI:Text(row, 12, "text")
    row.crafters:SetPoint("RIGHT", row.whisper, "LEFT", -12, 0)
    row.crafters:SetJustifyH("RIGHT")
    row.name = UI:Text(row, 13, "text")
    row.name:SetPoint("TOPLEFT", 44, -4)
    row.sub = UI:Text(row, 11, "dim")
    row.sub:SetPoint("BOTTOMLEFT", 44, 4)
    row:HookScript("OnSizeChanged", findLayout)
    keepHover(row, row.itemBtn)
    keepHover(row, row.spellBtn)
    keepHover(row, row.whisper)
end

local function findUpdateRow(row, e)
    row.crafters:SetText(crafterSummary(e.crafters, 2))
    row.cNat = textWidth(row.crafters)
    if row.laidW ~= row:GetWidth() or row.laidC ~= row.cNat then findLayout(row) end
    if e.item then
        row.itemBtn:SetItem(e.item)
        row.itemBtn:Show()
        row.spellBtn:Hide()
    else
        row.itemBtn:Hide()
        row.spellBtn:SetRecipe(e.recipe)
        row.spellBtn:Show()
    end
    row.name:SetText(entryName(e))
    row.name:SetTextColor(entryColor(e))
    local total, on = #e.crafters, onlineCount(e.crafters)
    local sub = gameIcon(Profs:LineIcon(e.line), 12) .. " " .. Profs:LineName(e.line) .. DOT .. total .. " " .. U.Plural(total, "tradie")
    if on > 0 then sub = sub .. ", " .. T:Wrap("green", on .. " online") end
    row.sub:SetText(sub)
    row.whisper.entry = e
    row.whisper.target = firstOnline(e.crafters)
    row.whisper:SetActive(row.whisper.target ~= nil)
end

local function findEntries()
    local idx = Profs:Index()
    local q = state.search ~= "" and state.search or nil
    local out = {}
    for id, e in pairs(idx.recipes) do
        if (not state.line or e.line == state.line) and (not state.person or e.set[state.person]) then
            if not q or U.Matches(Profs:RecipeName(id), q) or (e.item and U.Matches(itemName(e.item), q)) then
                out[#out + 1] = e
            end
        end
    end
    local names = {}
    for i = 1, #out do names[out[i]] = entryName(out[i]):lower() end
    sort(out, function(a, b)
        local na, nb = names[a], names[b]
        if na ~= nb then return na < nb end
        return a.recipe < b.recipe
    end)
    return out
end

local function findEmptyText()
    if Profs:Index().recipeCount == 0 then return emptyProfs() end
    if state.search ~= "" then
        return ('Nobody on the street makes "%s". Might be a Bunnings job.'):format(U.ChatSafe(state.search))
    end
    if state.person then
        if state.line then
            return ("%s hasn't shared any %s recipes. Ask nicely."):format(colored(state.person), Profs:LineName(state.line))
        end
        return ("%s hasn't shared any recipes yet. Tell them to open their profession windows."):format(colored(state.person))
    end
    if state.line then
        return ("No licensed %s tradies on the street. Cash jobs only, mate."):format(Profs:LineName(state.line))
    end
    return emptyProfs()
end

-------------------------------------------------------------------------------
-- Find a Tradie: the job sheet drawer
-------------------------------------------------------------------------------
local function crafterCreateRow(row)
    row.dot = UI:Icon(row, 8, "dot")
    row.dot:SetPoint("LEFT", 8, 0)
    row.cls = UI:ClassIcon(row, 16)
    row.cls:SetPoint("LEFT", 22, 0)
    row.name = UI:Text(row, 12, "text")
    row.name:SetPoint("LEFT", 44, 0)
    row.name:SetWidth(DRAWER_W - 24 - 44 - 82)
    row.rank = UI:Text(row, 12, "text", "num")
    row.rank:SetPoint("RIGHT", -32, 0)
    row.rank:SetJustifyH("RIGHT")
    row.whisper = UI:IconButton(row, "bubble", 22, "Whisper", function(self)
        if self.key then UI:Whisper(self.key) end
    end)
    row.whisper:SetPoint("RIGHT", -4, 0)
    keepHover(row, row.whisper)
end

local function crafterUpdateRow(row, c)
    local dc = c.online and C.green or C.faint
    row.dot:SetVertexColor(dc[1], dc[2], dc[3], c.online and 1 or 0.6)
    row.cls:SetClass(GF.Roster:Class(c.key))
    row.name:SetText(colored(c.key) .. (isMe(c.key) and T:Wrap("faint", " (you)") or ""))
    row.rank:SetText(c.rank > 0 and tostring(c.rank) or "?")
    UI:SetTextColor(row.rank, c.rank >= Profs.MAX_SKILL and "gold" or "dim")
    row.whisper.key = c.key
    row.whisper:SetShown(c.online and not isMe(c.key))
end

local function crafterTip(row, c)
    local lines = {}
    local m = GF.Roster:Get(c.key)
    if c.online then
        lines[#lines + 1] = T:Wrap("green", "On the street") .. ((m and m.zone) and (" - " .. m.zone) or "")
    else
        lines[#lines + 1] = T:Wrap("faint", "Offline")
    end
    local e = views.find and views.find.drawer.entry
    if e then
        lines[#lines + 1] = { Profs:LineName(e.line), c.rank > 0 and (c.rank .. " / " .. Profs.MAX_SKILL) or "?" }
    end
    local main = GF.Roster:MainOf(c.key)
    if main and main ~= c.key then lines[#lines + 1] = "Alt of " .. colored(main) end
    UI:Tip(row, colored(c.key), lines)
end

local function crafterRows(e)
    local rows = {}
    for _, key in ipairs(e.crafters) do
        rows[#rows + 1] = { key = key, rank = Profs:Skill(key, e.line), online = isOnline(key) }
    end
    sort(rows, function(a, b)
        if a.online ~= b.online then return a.online end
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.key < b.key
    end)
    return rows
end

local function buildDrawer(res)
    -- a raised holder keeps the sheet above the result rows it slides over
    local holder = CreateFrame("Frame", nil, res)
    holder:SetFrameLevel(res:GetFrameLevel() + 30)
    holder:SetPoint("TOPRIGHT", res, "TOPRIGHT", -1, -37)
    holder:SetPoint("BOTTOMRIGHT", res, "BOTTOMRIGHT", -1, 1)
    holder:SetWidth(DRAWER_W)
    local d = UI:Card(holder, { title = "Job sheet", icon = "clipboard" })
    d:SetAllPoints(holder)
    UI:Shadow(d, 10)
    -- a floating sheet: dark leather under the slate, in the window's own gold frame
    d.leather = d:CreateTexture(nil, "BACKGROUND", nil, 1)
    d.leather:SetPoint("TOPLEFT", 3, -3)
    d.leather:SetPoint("BOTTOMRIGHT", -3, 3)
    tiled(d.leather, T.tex.leather, 0.55, 0.5, 0.46, 0.5)
    d.gold = d:CreateTexture(nil, "BORDER", nil, 1)
    d.gold:SetAllPoints()
    UI.Sliced(d.gold, T.tex.frameGold, 16)
    d:EnableMouse(true)
    d:EnableMouseWheel(true)
    d:SetScript("OnMouseWheel", function() end) -- don't scroll the results underneath
    d.close = UI:IconButton(d, "close", 22, "Close the job sheet", function()
        state.selected = nil
        refreshFind(true)
    end)
    d.close:SetPoint("TOPRIGHT", -9, -8)

    local body = d.body
    d.itemBtn = goldFrame(UI:ItemButton(body, 40), 40)
    d.itemBtn:SetPoint("TOPLEFT", 0, 0)
    d.spellBtn = spellButton(body, 40, nil)
    d.spellBtn:SetPoint("TOPLEFT", 0, 0)
    d.name = UI:Text(body, 14, "text", "ui")
    d.name:SetPoint("TOPLEFT", 50, -2)
    d.name:SetWidth(DRAWER_W - 24 - 50)
    d.name:SetWordWrap(true)
    if d.name.SetMaxLines then d.name:SetMaxLines(2) end
    d.sub = UI:Text(body, 11, "dim")
    d.sub:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, -4)
    d.sub:SetWidth(DRAWER_W - 24 - 50)
    local div = body:CreateTexture(nil, "ARTWORK")
    div:SetTexture(T.tex.dividerGold)
    div:SetHeight(12)
    div:SetPoint("TOPLEFT", -4, -50)
    div:SetPoint("TOPRIGHT", 4, -50)
    div:SetAlpha(0.85)
    d.label = groupLabel(body, "")
    d.label:SetPoint("TOPLEFT", 0, -66)
    d.list = UI:List(body, { rowHeight = 32, createRow = crafterCreateRow, updateRow = crafterUpdateRow, onEnter = crafterTip })
    d.list:SetPoint("TOPLEFT", 0, -82)
    d.list:SetPoint("BOTTOMRIGHT", 0, 38)
    d.ask = UI:Button(body, "Ask in guild chat", {
        icon = "megaphone", height = 26, width = DRAWER_W - 24,
        tooltip = "Posts a short request in guild chat. You'll see it before it goes.",
        onClick = function() askGuild(d.entry) end,
    })
    d.ask:SetPoint("BOTTOMLEFT", 0, 2)
    d:Hide()
    return d
end

local function refreshDrawer(v)
    local d = v.drawer
    local e = state.selected and Profs:Index().recipes[state.selected]
    if not e then
        d.entry = nil
        d:Hide()
        return
    end
    local wasShown = d:IsShown()
    local same = wasShown and d.entry == e -- a different job starts at the top of its list
    d.entry = e
    if e.item then
        d.itemBtn:SetItem(e.item)
        d.itemBtn:Show()
        d.spellBtn:Hide()
    else
        d.itemBtn:Hide()
        d.spellBtn:SetRecipe(e.recipe)
        d.spellBtn:Show()
    end
    local name = entryName(e)
    d.name:SetText(name)
    d.name:SetTextColor(entryColor(e))
    local sub = gameIcon(Profs:LineIcon(e.line), 12) .. " " .. Profs:LineName(e.line)
    local spell = Profs:RecipeName(e.recipe)
    if e.item and spell and spell ~= name then sub = sub .. DOT .. spell end
    d.sub:SetText(sub)
    local rows = crafterRows(e)
    d.label:SetText(("%d %s ON THE BOOKS"):format(#rows, U.Plural(#rows, "TRADIE", "TRADIES")))
    d.list:SetItems(rows, same)
    d.ask:SetActive(API.InGuild())
    if not wasShown then
        d:Show()
        UI:FadeIn(d, 0.12)
    end
    -- a fresh job on the sheet gets the light sweep across its icon
    if not same then UI:Shine(e.item and d.itemBtn or d.spellBtn, 0.6) end
end

-------------------------------------------------------------------------------
-- Find a Tradie: view
-------------------------------------------------------------------------------
local function layoutFindBody(v)
    local y = 0
    if v.banner:IsShown() then
        v.banner:ClearAllPoints()
        v.banner:SetPoint("TOPLEFT", 0, -y)
        v.banner:SetPoint("TOPRIGHT", 0, -y)
        y = y + 38
    end
    if v.personBtn:IsShown() then
        v.personBtn:ClearAllPoints()
        v.personBtn:SetPoint("TOPLEFT", 0, -y)
        y = y + 30
    end
    v.list:ClearAllPoints()
    v.list:SetPoint("TOPLEFT", 0, -y)
    v.list:SetPoint("BOTTOMRIGHT", 0, 0)
end

local function buildFind(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    -- left column: the trades
    local left = UI:Card(v, { title = "Trades", icon = "hammer" })
    left:SetPoint("TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", 0, 0)
    left:SetWidth(LEFT_W)
    local scroll, content = UI:Scroll(left.body)
    scroll:SetAllPoints(left.body)
    v.chips = {}
    local y = 0
    local function addChip(line)
        local chip = makeChip(content, line)
        chip:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        chip:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
        v.chips[#v.chips + 1] = chip
        y = y + CHIP_H + 2
    end
    local function addLabel(text)
        local fs = groupLabel(content, text)
        fs:SetPoint("TOPLEFT", 9, -(y + 10))
        y = y + 28
    end
    addChip(nil)
    addLabel("TRADES")
    for _, line in ipairs(D.professionOrder) do
        if not Profs:IsSecondary(line) then addChip(line) end
    end
    addLabel("SECONDARY")
    for _, line in ipairs(D.professionOrder) do
        if Profs:IsSecondary(line) then addChip(line) end
    end
    scroll:SetContentHeight(y)

    -- right: results
    local res = UI:Card(v, { title = "On the books", icon = "search", subtitle = " " })
    res:SetPoint("TOPLEFT", left, "TOPRIGHT", 16, 0)
    res:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", 0, 0)
    v.res = res
    v.search = UI:Search(res, {
        placeholder = "Search recipes and items...", width = 200, height = 24,
        onChange = function(text)
            state.search = U.Trim(text)
            state.selected = nil
            refreshFind()
        end,
    })
    v.search:SetPoint("TOPRIGHT", res, "TOPRIGHT", -8, -7)
    v.search:SetText(state.search)
    v.search:RefreshPlaceholder()
    res:HookScript("OnSizeChanged", function(self, w)
        local tw = self.title:GetStringWidth() or 90
        self.subtitle:SetWidth(max(30, (w or 0) - 32 - tw - 8 - 200 - 24))
    end)

    -- the nudge is a parchment notice in a bronze rim, written in ink
    local INK = { 0.24, 0.14, 0.05, 1 }
    local banner = CreateFrame("Frame", nil, res.body)
    banner:SetHeight(30)
    banner.bg = banner:CreateTexture(nil, "BACKGROUND")
    banner.bg:SetPoint("TOPLEFT", 2, -2)
    banner.bg:SetPoint("BOTTOMRIGHT", -2, 2)
    tiled(banner.bg, T.tex.parchment, 0.95, 0.9, 0.8, 1)
    banner.rim = banner:CreateTexture(nil, "BORDER")
    banner.rim:SetAllPoints()
    UI.Sliced(banner.rim, T.tex.frameBronze, 8)
    banner.icon = UI:Icon(banner, 14, "warning", "ARTWORK", { 0.62, 0.16, 0.06, 1 })
    banner.icon:SetPoint("LEFT", 10, 0)
    banner.close = UI:IconButton(banner, "close", 20, "Hide this for now", function()
        state.bannerClosed = true
        refreshFind(true)
    end, { 0.36, 0.22, 0.1, 1 })
    banner.close:SetPoint("RIGHT", -5, 0)
    -- the kit's white hover would vanish on parchment: go a darker ink instead
    banner.close:HookScript("OnEnter", function(self) self.icon:SetVertexColor(0.55, 0.1, 0.04, 1) end)
    banner.text = UI:Text(banner, 11, INK)
    banner.text:SetShadowOffset(0, 0)
    banner.text:SetPoint("LEFT", banner.icon, "RIGHT", 8, 0)
    banner.text:SetPoint("RIGHT", banner.close, "LEFT", -6, 0)
    banner:Hide()
    v.banner = banner

    v.personBtn = UI:Button(res.body, "", {
        icon = "close", height = 22, size = 11, upper = false, tooltip = "Back to everyone's trades",
        onClick = function()
            state.person = nil
            state.selected = nil
            refreshFind()
        end,
    })
    v.personBtn:Hide()

    v.list = UI:List(res.body, {
        rowHeight = 36, createRow = findCreateRow, updateRow = findUpdateRow,
        onClick = function(e)
            state.selected = (state.selected ~= e.recipe) and e.recipe or nil
            refreshFind(true)
        end,
        isSelected = function(e) return e.recipe == state.selected end,
    })
    v.empty = UI:Empty(res.body, "", "hammer")
    v.empty:Hide()
    v.drawer = buildDrawer(res)
    layoutFindBody(v)
    return v
end

refreshFind = function(keep)
    local v = views.find
    if not v or not v:IsVisible() then return end
    local idx = Profs:Index()
    for _, chip in ipairs(v.chips) do
        if chip.line then
            chip:Refresh(state.line == chip.line, idx.lineMembers[chip.line] or 0, idx.lineRecipes[chip.line] or 0)
        else
            chip:Refresh(state.line == nil, idx.tradies, idx.recipeCount)
        end
    end

    -- nudge: my own trades nobody can see yet
    local missing = state.bannerClosed and {} or Profs:MissingLines()
    if #missing > 0 then
        local names = {}
        for i, line in ipairs(missing) do names[i] = Profs:LineName(line) end
        v.banner.text:SetText(("Open your %s %s once so the street knows what you can make."):format(
            joinNames(names), U.Plural(#names, "window")))
        v.banner:Show()
    else
        v.banner:Hide()
    end
    if state.person then
        v.personBtn:SetText("Showing " .. colored(state.person) .. "'s trades")
        v.personBtn:Show()
    else
        v.personBtn:Hide()
    end
    layoutFindBody(v)

    if state.selected and not idx.recipes[state.selected] then state.selected = nil end
    local entries = findEntries()
    v.list:SetItems(entries, keep)
    if state.scrollToSelected then
        state.scrollToSelected = false
        for i, e in ipairs(entries) do
            if e.recipe == state.selected then v.list:ScrollTo(i) break end
        end
    end

    local total = idx.recipeCount
    local sub
    if #entries == total then
        sub = U.Commas(total) .. " " .. U.Plural(total, "recipe")
    else
        sub = ("%s of %s recipes"):format(U.Commas(#entries), U.Commas(total))
    end
    if #entries > 0 then sub = sub .. DOT .. "click one for the job sheet" end
    v.res.subtitle:SetText(sub)
    if #entries == 0 then
        v.empty:SetText(findEmptyText())
        v.empty:Show()
    else
        v.empty:Hide()
    end
    refreshDrawer(v)
end

-------------------------------------------------------------------------------
-- Residents' Licences
-------------------------------------------------------------------------------
local function sortItems()
    local items = {
        { value = "name", text = "Name (mains with alts)", icon = "roster" },
        { value = "online", text = "Online first", icon = "dot" },
        { text = "By trade", title = true },
    }
    for _, line in ipairs(D.professionOrder) do
        items[#items + 1] = { value = line, text = Profs:LineName(line), icon = Profs:LineIcon(line) }
    end
    return items
end

local function licBlock(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(150, 26)
    f.art = UI:FramedIcon(f, 22)
    f.art:SetPoint("LEFT", 0, 0)
    f.icon = f.art.icon
    f.rank = UI:Text(f, 12, "text", "num")
    f.rank:SetPoint("BOTTOMRIGHT", f, "RIGHT", 0, 1)
    f.rank:SetJustifyH("RIGHT")
    f.name = UI:Text(f, 11, "dim")
    f.name:SetPoint("BOTTOMLEFT", f.art, "RIGHT", 6, 1)
    f.name:SetPoint("BOTTOMRIGHT", f.rank, "BOTTOMLEFT", -3, 0)
    f.bar = UI:Bar(f, { height = 5 })
    f.bar:SetPoint("TOPLEFT", f.art, "RIGHT", 6, -3)
    f.bar:SetPoint("TOPRIGHT", f, "RIGHT", 0, -3)
    return f
end

local function licSmall(parent, line)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(SIDE_W, 20)
    f.art = UI:FramedIcon(f, 20, Profs:LineIcon(line))
    f.art:SetPoint("LEFT", 0, 0)
    f.icon = f.art.icon
    f.rank = UI:Text(f, 11, "text", "num")
    f.rank:SetPoint("LEFT", f.art, "RIGHT", 5, 0)
    return f
end

local function licLayout(row)
    local w = row:GetWidth() or 0
    row.laidW = w
    local avail = w - NAME_W - #SECONDARY * SIDE_W - 30
    local bw = floor(U.Clamp((avail - 10) / 2, 96, 190))
    row.prim[1]:SetWidth(bw)
    row.prim[2]:SetWidth(bw)
end

local function licCreateRow(row)
    row.cls = UI:ClassIcon(row, 22)
    row.cls:SetPoint("LEFT", 10, 0)
    row.dot = UI:Icon(row, 8, "dot", "OVERLAY")
    row.dot:SetPoint("BOTTOMRIGHT", row.cls, "BOTTOMRIGHT", 3, -2)
    row.name = UI:Text(row, 13, "text")
    row.name:SetPoint("BOTTOMLEFT", row.cls, "RIGHT", 8, 1)
    row.note = UI:Text(row, 10, "faint")
    row.note:SetPoint("TOPLEFT", row.cls, "RIGHT", 8, -2)
    row.prim = { licBlock(row), licBlock(row) }
    row.prim[1]:SetPoint("LEFT", row, "LEFT", NAME_W, 0)
    row.prim[2]:SetPoint("LEFT", row.prim[1], "RIGHT", 10, 0)
    row.none = UI:Text(row, 11, "faint")
    row.none:SetPoint("LEFT", row, "LEFT", NAME_W, 0)
    row.none:SetText("No trade on file")
    row.sec = {}
    for i, line in ipairs(SECONDARY) do
        local s = licSmall(row, line)
        s:SetPoint("RIGHT", row, "RIGHT", -(8 + (#SECONDARY - i) * SIDE_W), 0)
        row.sec[i] = s
    end
    row:HookScript("OnSizeChanged", licLayout)
end

local function fillBlock(f, l, focus)
    if not l then
        f:Hide()
        return
    end
    f:Show()
    f.art:SetIcon(Profs:LineIcon(l.line))
    f.name:SetText(Profs:LineName(l.line))
    UI:SetTextColor(f.name, focus and "text" or "dim")
    local done = l.rank >= Profs.MAX_SKILL
    f.rank:SetText(l.rank > 0 and tostring(l.rank) or "?")
    UI:SetTextColor(f.rank, done and "gold" or "text")
    f.bar:SetColor(done and "gold" or "green")
    f.bar:SetValue(l.rank / Profs.MAX_SKILL)
end

local function licUpdateRow(row, r)
    if row.laidW ~= row:GetWidth() then licLayout(row) end
    local indent = (r.alt and state.sort == "name") and 22 or 0
    row.cls:ClearAllPoints()
    row.cls:SetPoint("LEFT", 10 + indent, 0)
    row.cls:SetClass(GF.Roster:Class(r.key))
    local dc = r.online and C.green or C.faint
    row.dot:SetVertexColor(dc[1], dc[2], dc[3], r.online and 1 or 0.6)
    row.name:SetWidth(NAME_W - 48 - indent)
    row.note:SetWidth(NAME_W - 48 - indent)
    row.name:SetText(colored(r.key) .. (isMe(r.key) and T:Wrap("faint", " (you)") or ""))
    if r.alt then
        row.note:SetText("Alt of " .. colored(r.main))
    else
        local m = GF.Roster:Get(r.key)
        row.note:SetText((m and m.rankName ~= "" and m.rankName) or "Resident")
    end

    -- primary trades, with the one being sorted on up front
    local prim = {}
    for _, line in ipairs(D.professionOrder) do
        if r.p.lines[line] and not Profs:IsSecondary(line) then prim[#prim + 1] = line end
    end
    if type(state.sort) == "number" then
        for i = 2, #prim do
            if prim[i] == state.sort then
                tinsert(prim, 1, tremove(prim, i))
                break
            end
        end
    end
    for i = 1, 2 do
        local line = prim[i]
        fillBlock(row.prim[i], line and r.p.lines[line], line ~= nil and line == state.sort)
    end
    row.none:SetShown(#prim == 0)

    for i, line in ipairs(SECONDARY) do
        local s, l = row.sec[i], r.p.lines[line]
        if l then
            s.art:SetDesaturated(false)
            s.art:SetAlpha(1)
            s.rank:SetText(l.rank > 0 and tostring(l.rank) or "?")
            UI:SetTextColor(s.rank, l.rank >= Profs.MAX_SKILL and "gold" or (line == state.sort and "text" or "dim"))
        else
            s.art:SetDesaturated(true)
            s.art:SetAlpha(0.3)
            s.rank:SetText("-")
            UI:SetTextColor(s.rank, "faint")
        end
    end
end

local function licTip(row, r)
    local lines = {}
    for _, line in ipairs(D.professionOrder) do
        local l = r.p.lines[line]
        if l then
            local right = l.rank > 0 and (l.rank .. " / " .. Profs.MAX_SKILL) or "?"
            if l.count > 0 then right = right .. DOT .. l.count .. " " .. U.Plural(l.count, "recipe") end
            if not l.synced then right = right .. " " .. T:Wrap("yellow", "(syncing)") end
            lines[#lines + 1] = { gameIcon(Profs:LineIcon(line), 14) .. " " .. Profs:LineName(line), right }
        end
    end
    local m = GF.Roster:Get(r.key)
    if r.online then
        lines[#lines + 1] = T:Wrap("green", "On the street") .. ((m and m.zone) and (" - " .. m.zone) or "")
    else
        lines[#lines + 1] = T:Wrap("faint", "Offline")
    end
    if r.p.t > 0 then lines[#lines + 1] = "Licence updated " .. U.Ago(r.p.t) end
    lines[#lines + 1] = T:Wrap("dim", "Click to see what they can make")
    if UI.OpenProfile then lines[#lines + 1] = T:Wrap("dim", "Right-click for their profile") end
    UI:Tip(row, colored(r.key), lines)
end

local function licClick(r, _, button)
    if button == "RightButton" then
        if UI.OpenProfile then UI:OpenProfile(r.key) end
        return
    end
    state.person, state.line, state.search, state.selected = r.key, nil, "", nil
    if views.find then
        views.find.search:SetText("")
        views.find.search:RefreshPlaceholder()
    end
    page.tabs:Select("find")
end

local function licenceRows()
    local idx = Profs:Index()
    local q = state.who ~= "" and state.who or nil
    local rows = {}
    for key, p in pairs(idx.players) do
        if next(p.lines) then
            local main = GF.Roster:MainOf(key) or key
            if not q or U.Matches(key, q) or U.Matches(main, q) then
                rows[#rows + 1] = { key = key, main = main, alt = main ~= key, online = isOnline(key), p = p }
            end
        end
    end
    local s = state.sort
    local function rankIn(r)
        local l = r.p.lines[s]
        return l and l.rank or -1
    end
    sort(rows, function(a, b)
        if type(s) == "number" then
            local ra, rb = rankIn(a), rankIn(b)
            if ra ~= rb then return ra > rb end
        elseif s == "online" then
            if a.online ~= b.online then return a.online end
        else
            local ma, mb = a.main:lower(), b.main:lower()
            if ma ~= mb then return ma < mb end
            if a.alt ~= b.alt then return not a.alt end
        end
        return a.key:lower() < b.key:lower()
    end)
    return rows
end

local function buildLicences(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    local card = UI:Card(v, { title = "Residents' licences", icon = "clipboard", subtitle = " " })
    card:SetAllPoints(v)
    v.card = card
    v.sort = UI:Dropdown(card, {
        width = 180, height = 24, items = sortItems,
        get = function() return state.sort end,
        set = function(value)
            state.sort = value
            prefs().sort = value
            refreshLicences()
        end,
        tooltip = "Sort by name, by who's on, or by skill in a trade",
    })
    v.sort:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -7)
    v.search = UI:Search(card, {
        placeholder = "Find a resident...", width = 170, height = 24,
        onChange = function(text)
            state.who = U.Trim(text)
            refreshLicences()
        end,
    })
    v.search:SetPoint("RIGHT", v.sort, "LEFT", -8, 0)
    card:HookScript("OnSizeChanged", function(self, w)
        local tw = self.title:GetStringWidth() or 120
        self.subtitle:SetWidth(max(30, (w or 0) - 32 - tw - 8 - 180 - 170 - 32))
    end)

    local body = card.body
    -- column labels line up with the row parts below (rows stop 10px short for the scrollbar)
    local function label(text, rel, x)
        local fs = groupLabel(body, text)
        fs:SetPoint("TOPLEFT", body, rel, x, 0)
    end
    label("RESIDENT", "TOPLEFT", 10)
    label("TRADES", "TOPLEFT", NAME_W)
    label("SECONDARY", "TOPRIGHT", -(18 + #SECONDARY * SIDE_W))

    v.list = UI:List(body, { rowHeight = 40, createRow = licCreateRow, updateRow = licUpdateRow, onEnter = licTip, onClick = licClick })
    v.list:SetPoint("TOPLEFT", 0, -18)
    v.list:SetPoint("BOTTOMRIGHT", 0, 0)
    v.empty = UI:Empty(body, "", "clipboard")
    v.empty:Hide()
    return v
end

refreshLicences = function(keep)
    local v = views.licences
    if not v or not v:IsVisible() then return end
    v.sort:Refresh()
    local rows = licenceRows()
    v.list:SetItems(rows, keep)
    local maxed = 0
    for _, r in ipairs(rows) do
        for _, l in pairs(r.p.lines) do
            if l.rank >= Profs.MAX_SKILL then maxed = maxed + 1 end
        end
    end
    v.card.subtitle:SetText(("%d %s%s%d %s at 300"):format(#rows, U.Plural(#rows, "resident"), DOT, maxed, U.Plural(maxed, "trade")))
    if #rows == 0 then
        if state.who ~= "" then
            v.empty:SetText(('No resident called "%s" holds a licence. Dodgy.'):format(U.ChatSafe(state.who)))
        else
            v.empty:SetText(emptyProfs())
        end
        v.empty:Show()
    else
        v.empty:Hide()
    end
end

-------------------------------------------------------------------------------
-- Cooldowns
-------------------------------------------------------------------------------
local function cooldownRows()
    local idx = Profs:Index()
    local now = API.ServerTime()
    local rows, ready = {}, 0
    for _, c in ipairs(Profs:Cooldowns()) do
        local who = {}
        local e = idx.recipes[c.id]
        if e then
            for _, key in ipairs(e.crafters) do who[key] = true end
        end
        for key, p in pairs(idx.players) do
            if p.cd[c.id] then who[key] = true end
        end
        local list = {}
        for key in pairs(who) do
            local p = idx.players[key]
            local at = p and p.cd[c.id]
            local left = at and (at - now) or nil
            list[#list + 1] = { kind = "c", recipe = c.id, key = key, at = at, left = (left and left > 0) and left or nil, online = isOnline(key) }
        end
        if #list > 0 then
            sort(list, function(a, b)
                if (a.left == nil) ~= (b.left == nil) then return a.left == nil end
                if a.left and b.left and a.left ~= b.left then return a.left < b.left end
                if a.online ~= b.online then return a.online end
                return a.key < b.key
            end)
            local n = 0
            for _, it in ipairs(list) do
                if not it.left then n = n + 1 end
            end
            rows[#rows + 1] = { kind = "h", recipe = c.id, cd = c.cd, ready = n, total = #list }
            for _, it in ipairs(list) do rows[#rows + 1] = it end
            ready = ready + n
        end
    end
    return rows, ready
end

local function cdCreateRow(row)
    -- recipe headers: a gold wash from the left, the spell in a gold frame, the name in gold
    row.hSheen = row:CreateTexture(nil, "BACKGROUND", nil, 3)
    row.hSheen:SetAllPoints()
    row.hSheen:SetTexture(T.tex.white)
    if row.hSheen.SetGradient and CreateColor then
        row.hSheen:SetGradient("HORIZONTAL", CreateColor(1, 0.78, 0.25, 0.12), CreateColor(1, 0.78, 0.25, 0))
    else
        row.hSheen:SetColorTexture(1, 0.78, 0.25, 0.05)
    end
    row.hEdge = row:CreateTexture(nil, "BORDER")
    row.hEdge:SetPoint("BOTTOMLEFT", 0, 0)
    row.hEdge:SetPoint("BOTTOMRIGHT", 0, 0)
    row.hEdge:SetHeight(1)
    row.hEdge:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.6)
    row.hIcon = UI:FramedIcon(row, 26)
    row.hIcon:SetPoint("LEFT", 4, 0)
    row.hName = UI:Text(row, 13, "wowGold", "ui")
    row.hName:SetPoint("LEFT", row.hIcon, "RIGHT", 9, 0)
    row.hCd = UI:Text(row, 11, "faint")
    row.hCd:SetPoint("LEFT", row.hName, "RIGHT", 10, 0)
    row.hCount = UI:Text(row, 11, "dim", "head")
    row.hCount:SetPoint("RIGHT", -10, 0)

    row.dot = UI:Icon(row, 8, "dot")
    row.dot:SetPoint("LEFT", 40, 0)
    row.cls = UI:ClassIcon(row, 16)
    row.cls:SetPoint("LEFT", 56, 0)
    row.whisper = UI:Button(row, "Whisper", {
        height = 20, size = 10, icon = "bubble", iconSize = 11,
        -- never nil: the kit would fall back to the function itself and AddLine it
        tooltip = function(self) return self.target and ("Whisper " .. colored(self.target)) or "Nobody to whisper" end,
        onClick = function(self) if self.target then UI:Whisper(self.target) end end,
    })
    row.whisper:SetPoint("RIGHT", -8, 0)
    row.status = UI:Text(row, 12, "text", "head")
    row.status:SetPoint("RIGHT", row.whisper, "LEFT", -12, 0)
    row.status:SetJustifyH("RIGHT")
    row.cName = UI:Text(row, 12, "text")
    row.cName:SetPoint("LEFT", 80, 0)
    row.cName:SetPoint("RIGHT", row.status, "LEFT", -12, 0)
    keepHover(row, row.whisper)
    row.headParts = { row.hIcon, row.hName, row.hCd, row.hCount, row.hSheen, row.hEdge }
    row.crafterParts = { row.dot, row.cls, row.cName, row.status }
end

local function cdUpdateRow(row, it)
    local head = it.kind == "h"
    for _, w in ipairs(row.headParts) do w:SetShown(head) end
    for _, w in ipairs(row.crafterParts) do w:SetShown(not head) end
    if head then
        row.bg:SetColorTexture(C.bg3[1], C.bg3[2], C.bg3[3], 1)
        row.hIcon:SetIcon(API.SpellIcon(it.recipe))
        row.hName:SetText(Profs:RecipeName(it.recipe) or "Mystery recipe")
        row.hCd:SetText(cdLength(it.cd) .. " cooldown")
        row.hCount:SetText(("%d of %d ready"):format(it.ready, it.total))
        UI:SetTextColor(row.hCount, it.ready > 0 and "green" or "dim")
        row.whisper:Hide()
        return
    end
    row.bg:SetColorTexture(C.bg2[1], C.bg2[2], C.bg2[3], 0.7)
    local dc = it.online and C.green or C.faint
    row.dot:SetVertexColor(dc[1], dc[2], dc[3], it.online and 1 or 0.6)
    row.cls:SetClass(GF.Roster:Class(it.key))
    row.cName:SetText(colored(it.key) .. (isMe(it.key) and T:Wrap("faint", " (you)") or ""))
    if it.left then
        row.status:SetText(T:Wrap("yellow", "in " .. U.Duration(it.left)))
    elseif it.at then
        row.status:SetText(T:Wrap("green", "READY"))
    else
        row.status:SetText(T:Wrap("dim", "PROBABLY READY"))
    end
    local target = (not it.left and it.online and not isMe(it.key)) and it.key or nil
    row.whisper.target = target
    row.whisper:SetShown(target ~= nil)
end

local function cdTip(row, it)
    if it.kind == "h" then
        spellTip(row, it.recipe)
        return
    end
    local lines = {}
    if it.left then
        lines[#lines + 1] = "Back on the tools " .. U.DateTime(it.at)
    elseif it.at then
        lines[#lines + 1] = "Ready since " .. U.DateTime(it.at)
    else
        lines[#lines + 1] = "No cast logged yet, so it's probably good to go."
    end
    lines[#lines + 1] = it.online and T:Wrap("green", "On the street") or T:Wrap("faint", "Offline")
    UI:Tip(row, colored(it.key), lines)
end

local function buildCooldowns(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    local card = UI:Card(v, { title = "Cooldowns", icon = "clock", subtitle = " " })
    card:SetAllPoints(v)
    v.card = card
    v.pill = UI:Pill(card, "", "green", { icon = "check", height = 20 })
    v.pill:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -9)
    card:HookScript("OnSizeChanged", function(self, w)
        local tw = self.title:GetStringWidth() or 90
        self.subtitle:SetWidth(max(30, (w or 0) - 32 - tw - 8 - 130))
    end)
    card.subtitle:SetText("Transmutes, Mooncloth and mates. Times come from each tradie's last cast.")
    v.list = UI:List(card.body, { rowHeight = 32, createRow = cdCreateRow, updateRow = cdUpdateRow, onEnter = cdTip })
    v.list:SetAllPoints(card.body)
    v.empty = UI:Empty(card.body, "", "clock")
    v.empty:Hide()
    return v
end

refreshCooldowns = function(keep)
    local v = views.cooldowns
    if not v or not v:IsVisible() then return end
    local rows, ready = cooldownRows()
    v.list:SetItems(rows, keep)
    v.pill:SetText(ready .. " READY NOW", ready > 0 and "green" or "dim")
    v.pill:SetShown(#rows > 0)
    -- another cooldown came off: a light sweep across the count (not on every 15 s tick)
    if ready > (v.readyWas or 0) and #rows > 0 then UI:Shine(v.pill) end
    v.readyWas = ready
    if #rows == 0 then
        v.empty:SetText("Nobody's on the tools for cooldowns. The transmute master's probably down the pub.")
        v.empty:Show()
    else
        v.empty:Hide()
    end
end

-------------------------------------------------------------------------------
-- Page
-------------------------------------------------------------------------------
local function stopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

-- countdowns tick while the Cooldowns tab is on screen, and only then
local function startTicker()
    if ticker then return end
    ticker = GF:Ticker(15, function()
        if page and page:IsVisible() and state.tab == "cooldowns" then
            refreshCooldowns(true)
        else
            stopTicker()
        end
    end)
end

local BUILDERS = { find = buildFind, licences = buildLicences, cooldowns = buildCooldowns }

local function showView(key, fresh)
    if not views[key] then views[key] = BUILDERS[key](page.body) end
    for k, v in pairs(views) do v:SetShown(k == key) end
    if key == "cooldowns" then startTicker() else stopTicker() end
    if key == "find" then
        refreshFind(not fresh)
    elseif key == "licences" then
        refreshLicences(not fresh)
    else
        refreshCooldowns(not fresh)
    end
end

local function updateHeader()
    local idx = Profs:Index()
    if idx.tradies == 0 then
        page.header:SetSubtitle("No licences lodged yet. Open a profession window and get the ball rolling.")
    else
        page.header:SetSubtitle(("%d licensed %s%s%s %s on the books"):format(
            idx.tradies, U.Plural(idx.tradies, "tradie"), DOT, U.Commas(idx.recipeCount), U.Plural(idx.recipeCount, "recipe")))
    end
end

--- Deep links: itemID or item link -> its job sheet, string -> search, { person = key } -> their trades.
local function applyArg(arg)
    if type(arg) == "string" then
        arg = API.CleanString(arg)
        if not arg then return end
        -- "/gf tradies [shift-clicked item]" hands us a whole hyperlink
        if arg:find("|Hitem:", 1, true) or arg:match("^item:%d+") then
            arg = API.ItemID(arg) or U.Trim((U.StripCodes(arg):gsub("[%[%]]", "")))
        end
    end
    if type(arg) == "number" then
        state.line, state.person, state.search, state.selected = nil, nil, "", nil
        for id, e in pairs(Profs:Index().recipes) do
            if e.item == arg then
                state.selected = id
                break
            end
        end
        if not state.selected then state.search = API.CleanString(API.ItemName(arg)) or "" end
        state.scrollToSelected = true
    elseif type(arg) == "string" and arg ~= "" then
        state.line, state.person, state.selected = nil, nil, nil
        state.search = U.Trim(arg)
    elseif type(arg) == "table" and type(arg.person) == "string" then
        state.line, state.search, state.selected = nil, "", nil
        state.person = arg.person
    else
        return
    end
    state.tab = "find"
    prefs().tab = "find"
    local v = views.find
    if v then
        v.search:SetText(state.search)
        v.search:RefreshPlaceholder()
    end
end

local function rescan()
    local res = Profs:Rescan()
    if res == "combat" then
        UI:Toast({ title = "Hang on", text = "You're in a scrap. Your toolbox gets checked once it's over.", icon = "clock", style = "yellow", key = "profs-rescan" })
    elseif res == "waiting" then
        UI:Toast({ title = "Not yet", text = "Still settling into the neighbourhood. Give it a few seconds.", icon = "clock", style = "yellow", key = "profs-rescan" })
    else
        UI:Toast({ title = "Checking the toolbox", text = "Rescanning your trades. Open a profession window for the full picture.", icon = "hammer", key = "profs-rescan" })
    end
end

local function build(p)
    page = p
    local pf = prefs()
    if TABS[pf.tab] then state.tab = pf.tab end
    if pf.sort == "name" or pf.sort == "online" or (type(pf.sort) == "number" and D.professions[pf.sort]) then
        state.sort = pf.sort
    end

    p.header = UI:PageHeader(p, "Tradies", "")
    p.header:AddAction(UI:Button(p.header, "Rescan", {
        style = "ghost", icon = "sync", onClick = rescan,
        tooltip = { "Check my toolbox", { "Re-reads your skills, cooldowns and any recipes you've picked up.", "Opening a profession window gives the full picture." } },
    }))

    p.tabs = UI:Tabs(p, {
        { key = "find", text = "Find a Tradie", icon = "search" },
        { key = "licences", text = "Residents' Licences", icon = "clipboard" },
        { key = "cooldowns", text = "Cooldowns", icon = "clock" },
    }, function(key)
        state.tab = key
        prefs().tab = key
        showView(key, true)
    end)
    p.tabs:SetPoint("TOPLEFT", p.header, "BOTTOMLEFT", 0, -4)

    p.body = CreateFrame("Frame", nil, p)
    p.body:SetPoint("TOPLEFT", p.tabs, "BOTTOMLEFT", 0, -14)
    p.body:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 0, 0)
end

local function onShow(p, arg)
    local fresh = arg ~= nil
    if fresh then applyArg(arg) end
    p.tabs:Select(state.tab, true)
    showView(state.tab, fresh)
    updateHeader()
    startDrain()
end

local function onHide()
    stopTicker()
end

UI:RegisterPage({
    key = PAGE, title = "Tradies", subtitle = "Need something made? Find a local tradie. Cash only, no receipts.",
    icon = "hammer", group = "community", order = 30,
    build = build, onShow = onShow, onHide = onHide,
})

-------------------------------------------------------------------------------
-- Keeping it fresh
-------------------------------------------------------------------------------
GF:On("GF_PROFS_UPDATED", function()
    GF:Debounce("tradies-refresh", 0.3, function() UI:RefreshPage(PAGE) end)
end)

GF:On("GF_ROSTER_UPDATED", function()
    GF:Debounce("tradies-roster", 1, function() UI:RefreshPage(PAGE) end)
end)

GF:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
    local id = API.CleanNumber(itemID)
    if not id or not waiting[id] then return end
    -- one refresh per item: a failed load (success false) must not loop refresh ->
    -- ItemButton re-request -> event -> refresh while the page is open
    waiting[id] = nil
    if API.Clean(success) == false then return end
    if page and page:IsVisible() and state.tab == "find" then
        GF:Debounce("tradies-items", 0.5, function() refreshFind(true) end)
    end
end)

GF:RegisterSlash("tradies", function(args)
    UI:OpenMain(PAGE, (type(args) == "string" and args ~= "") and args or nil)
end, "[item] - find a guild tradie who can make something")
