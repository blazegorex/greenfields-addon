--[[ Greenfields - Modules/SoftResUI.lua
     The Soft Res page: the active session banner, your reserves, the add-a-reserve
     picker (search the learned loot catalogue, paste a link or ID, or shift-click an
     item straight into the box), the full list grouped by item or by player, and the
     host's tools (start, lock, announce, import/export, plus mode, clear, close).
     Rules and data live in Modules/SoftRes.lua; this file only draws and forwards clicks. ]]

local _, GF = ...
local SR = GF.SR
if not SR then return end

local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c
local type, ipairs, pairs, tostring, max, min = type, ipairs, pairs, tostring, math.max, math.min
local concat, sort = table.concat, table.sort

local KNOWN_RAIDS = { "Barrow Deeps", "Hyjal Summit", "Onyxia's Lair" }
-- one rhythm for every item row on the page (your slots, the catalogue, the list): 28 icon, 12 over 11
local ROW_H, ICON_SIZE = 36, 28
local SLOT_H, SLOT_GAP = ROW_H, 4
local LEFT_MIN, LEFT_MAX = 310, 400
local DOT = "  \194\183  "

local page            -- the page frame once built
local waiting = {}    -- itemID -> true while we wait on GET_ITEM_INFO_RECEIVED
local failed = {}     -- itemID -> true once the server said it can't load it (no refresh loop)

-------------------------------------------------------------------------------
-- Item text helpers
-------------------------------------------------------------------------------
local function catalog(itemID)
    if not (GF.Loot and GF.Loot.CatalogEntry) then return nil end
    local ok, e = GF:Safe("srui:catalog", GF.Loot.CatalogEntry, GF.Loot, itemID)
    if ok and type(e) == "table" then return e end
    return nil
end

local function nameOf(itemID)
    local n = SR.ItemName(itemID)
    if not n and type(itemID) == "number" and not failed[itemID] then waiting[itemID] = true end
    return n
end

--- Remote strings (titles, notes, raid names) shown verbatim: escape any "|" so a stray
-- code can't recolour or break the rest of the line.
local function plain(s)
    return U.ChatSafe(s)
end

local function qualityOf(itemID)
    local q = API.ItemQuality(itemID)
    if type(q) == "number" then return q end
    local e = catalog(itemID)
    return e and e.q or nil
end

local function coloredName(itemID)
    local n = nameOf(itemID)
    if not n then return T:Wrap("faint", "Fetching item info...") end
    local r, g, b = API.QualityColor(qualityOf(itemID) or 1)
    return U.Color(n, r, g, b)
end

local function dropText(itemID)
    local e = catalog(itemID)
    if not e then return "Not seen dropping yet" end
    if e.b and e.i then return e.b .. DOT .. e.i end
    return e.i or e.b or "Somewhere out there"
end

--- "Name +2, Other" with class colours; maxShown trims long lists.
local function whoText(list, maxShown)
    local parts = {}
    for i, e in ipairs(list) do
        if maxShown and i > maxShown then
            parts[#parts + 1] = T:Wrap("faint", "+" .. (#list - maxShown) .. " more")
            break
        end
        local s = U.ClassName(e.player, e.class)
        if (e.plus or 0) > 0 then s = s .. T:Wrap("green", " +" .. e.plus) end
        parts[#parts + 1] = s
    end
    return concat(parts, T:Wrap("faint", ", "))
end

local function fail(msg, title)
    UI:Toast({ title = title or "Nah", text = msg or "That didn't work.", style = "red", icon = "warning", duration = 5 })
end

local function itemTip(owner, itemID)
    if not GameTooltip or not itemID then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    pcall(GameTooltip.SetItemByID, GameTooltip, itemID)
    GameTooltip:Show()
end

local function safeList(obj, method, ...)
    if not (obj and obj[method]) then return {} end
    local ok, res = GF:Safe("srui:" .. method, obj[method], obj, ...)
    if ok and type(res) == "table" then return res end
    return {}
end

-------------------------------------------------------------------------------
-- Item slots
-------------------------------------------------------------------------------
--- A kit ItemButton, with its bezel tinted from the catalogue's learned quality too, for items the
-- client hasn't cached yet. Bronze while unknown or common: the rim only gets a colour when the colour
-- means something. Tooltip, shift-link and clicks are untouched.
local function dressItem(b)
    local update = b.Update
    b.Update = function(self)
        update(self)
        local q = self.itemID and (qualityOf(self.itemID) or self.qHint)
        if type(q) == "number" and q >= 2 then
            local r, g, bb = API.QualityColor(q)
            self:SetBackdropBorderColor(r, g, bb, 1)
        else
            self:SetBackdropBorderColor(C.bronze[1], C.bronze[2], C.bronze[3], 1)
        end
    end
    b:Update()
    return b
end

-------------------------------------------------------------------------------
-- Header actions (host tools)
-------------------------------------------------------------------------------
local function layoutActions()
    local prev
    for _, b in ipairs(page.actions) do
        b:ClearAllPoints()
        if b:IsShown() then
            if prev then b:SetPoint("RIGHT", prev, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", page.header, "TOPRIGHT", 0, -4) end
            prev = b
        end
    end
end

local function exportCSV()
    local s = page.session
    if not s then return end
    UI:CopyBox("Export soft reserves", SR:ExportCSV(s), nil,
        "softres.it layout. Ctrl+C to copy, then paste it into a spreadsheet or back into softres.it.")
end

local function importCSV()
    local s = page.session
    if not s then return end
    UI:CopyBox("Import from softres.it", "", function(text)
        local ok, n, skipped = SR:ImportCSV(s, text)
        if not ok then return fail(n, "Import cooked") end
        UI:Toast({ title = "Imported", icon = "import", style = "green",
            text = ("%d %s loaded%s. Give it a few seconds to land."):format(n, U.Plural(n, "raider"),
                (skipped or 0) > 0 and (", " .. skipped .. " junk " .. U.Plural(skipped, "row") .. " skipped") or "") })
    end, "Paste softres.it's CSV export below (it needs ItemId and Name columns), then hit Import.")
end

local function togglePlus()
    local s = page.session
    if not s then return end
    local ok, err = SR:SetPlus(s, not s.plus)
    if not ok then fail(err) end
end

local function confirmClear()
    local s = page.session
    if not s then return end
    local idx = SR:Index(s)
    local n = idx and idx.count or 0
    UI:Confirm("Clear every reserve?", ("Wipes all %d %s in this session. No undo, no refunds."):format(n, U.Plural(n, "reserve")),
        function()
            local ok, err = SR:ClearAll(s)
            if not ok then fail(err) end
        end, "Clear them", "red")
end

local function confirmClose()
    local s = page.session
    if not s then return end
    UI:Confirm("Close the SR?", "Closes and locks the session. The Loot Log keeps the receipts.", function()
        local ok, err = SR:Close(s)
        if not ok then fail(err) end
    end, "Close it", "red")
end

local function openMore(anchor)
    local s = page.session
    if not s then return end
    local items = { { text = "Export CSV", icon = "export", func = exportCSV } }
    if SR:CanControl(s) then
        items[#items + 1] = { text = "Import CSV (softres.it)", icon = "import", func = importCSV }
        items[#items + 1] = { text = s.plus and "Turn plus mode off" or "Turn plus mode on", icon = "star", func = togglePlus }
        items[#items + 1] = { separator = true }
        items[#items + 1] = { text = "Clear all reserves", icon = "trash", color = "yellow", func = confirmClear }
        items[#items + 1] = { text = "Close session", icon = "close", color = "red", func = confirmClose }
    end
    UI:OpenMenu(anchor, items, { width = 220, point = "TOPRIGHT", relPoint = "BOTTOMRIGHT" })
end

local function buildHeader()
    local header = UI:PageHeader(page, "Soft Res", "Call dibs. Leave a bag to hold your spot.")
    page.header = header
    page.btnMore = UI:Button(header, "More", { icon = "chevron_down", onClick = function(b) openMore(b) end })
    page.btnLock = UI:Button(header, "Lock", { icon = "lock",
        tooltip = { "Lock / unlock", { "Locked: raiders can't change their picks. You still can." } },
        onClick = function()
            local s = page.session
            if not s then return end
            local ok, err = SR:SetLocked(s, not s.locked)
            if not ok then fail(err) end
        end })
    page.btnAnnounce = UI:Button(header, "Announce", { icon = "megaphone",
        tooltip = { "Announce", { "Tells the raid the SR is open (or locked) and how to whisper you a reserve." } },
        onClick = function()
            local ok, err = SR:Announce(page.session)
            if not ok then fail(err) else UI:Toast({ title = "Told 'em", text = "The raid knows. Whether they read chat is another matter.", icon = "megaphone", duration = 3 }) end
        end })
    page.btnDesk = UI:Button(header, "Loot desk", { icon = "bag",
        tooltip = { "Loot desk", { "Opens the floating loot desk: drops, reservers, rolls and awards." } },
        onClick = function() if GF.Loot and GF.Loot.OpenDesk then GF.Loot:OpenDesk() end end })
    page.actions = { page.btnMore, page.btnLock, page.btnAnnounce, page.btnDesk }
    for _, b in ipairs(page.actions) do header:AddAction(b) end
end

-------------------------------------------------------------------------------
-- Session banner
-------------------------------------------------------------------------------
local BANNER_H = 68

--- What's running, in a quiet card: the fights over loot happen in the cards under it. Coin, session
-- title in the quest-title face with its state beside it, one line of facts, and the count alone on the right.
local function buildBanner()
    local b = UI:Card(page)
    b:SetPoint("TOPLEFT", page.header, "BOTTOMLEFT", 0, -14)
    b:SetPoint("TOPRIGHT", page.header, "BOTTOMRIGHT", 0, -14)
    b:SetHeight(BANNER_H)
    b.art = UI:FramedIcon(b, 44, T.navArt.softres or "dice")
    b.art:SetPoint("LEFT", 12, 0)
    b.title = UI:Text(b, 20, "wowGold", "title")
    b.title:SetPoint("TOPLEFT", b, "TOPLEFT", 68, -11)
    if b.title.SetShadowOffset then
        b.title:SetShadowOffset(1, -1)
        b.title:SetShadowColor(0, 0, 0, 0.95)
    end
    b.sub = UI:Text(b, 12, "text")
    b.sub:SetPoint("TOPLEFT", b, "TOPLEFT", 68, -39)
    b.sub:SetPoint("TOPRIGHT", b, "TOPRIGHT", -104, -39)
    b.state = UI:Pill(b, "OPEN", "green", { icon = "check" })
    b.plus = UI:Pill(b, "PLUS MODE", "blue", { icon = "star", tooltip = { "Plus mode", { "+1 for every earlier session you reserved the item and missed out. Higher plus wins ties." } } })
    b.limit = UI:Pill(b, "", "dim", { icon = "dice" })
    b.pills = { b.state, b.plus, b.limit }
    b.big = UI:Text(b, 26, "wowGold", "num")
    b.big:SetPoint("RIGHT", b, "RIGHT", -14, 0)
    b.big:SetJustifyH("RIGHT")
    b.bigLbl = UI:Text(b, 11, "dim", "ui")
    b.bigLbl:SetPoint("RIGHT", b.big, "LEFT", -6, -2)
    -- locked: hazard tape along the bottom edge, the one ornament on the card
    b.hazard = b:CreateTexture(nil, "ARTWORK")
    b.hazard:SetTexture(T.tex.hazard, "REPEAT", "REPEAT")
    b.hazard:SetPoint("BOTTOMLEFT", 4, 3)
    b.hazard:SetPoint("BOTTOMRIGHT", -4, 3)
    b.hazard:SetHeight(5)
    b.hazard:SetAlpha(0.9)
    b.hazard:Hide()
    page.banner = b
end

--- Title first, its pills right behind it; a long title gives way before they run under the count.
local function layoutPills(b)
    local pillsW, prev = 0, nil
    for _, p in ipairs(b.pills) do
        p:ClearAllPoints()
        if p:IsShown() then pillsW = pillsW + (p:GetWidth() or 60) + 6 end
    end
    local room = (b:GetWidth() or 500) - 68 - 104 - pillsW - 10
    -- whole stripes at any width, not one stripe smeared across the card
    b.hazard:SetTexCoord(0, ((b:GetWidth() or 500) - 8) / 24, 0, 5 / 24)
    b.title:SetWidth(max(80, min(room, (b.title:GetStringWidth() or 100) + 2)))
    for _, p in ipairs(b.pills) do
        if p:IsShown() then
            if prev then p:SetPoint("LEFT", prev, "RIGHT", 6, 0) else p:SetPoint("LEFT", b.title, "RIGHT", 10, 0) end
            prev = p
        end
    end
end

--- The facts line, shortest version that fits: "opened" is the first to go.
local function refreshFacts(s)
    local b = page.banner
    local idx = SR:Index(s)
    local players = idx and idx.players or 0
    local contested = 0
    if idx then
        for _, list in pairs(idx.byItem) do if #list >= 2 then contested = contested + 1 end end
    end
    local bits = {}
    if s.instance then bits[#bits + 1] = plain(s.instance) end
    bits[#bits + 1] = "Hosted by " .. GF.Roster:Colored(s.host)
    local opened = #bits + 1
    bits[opened] = "Opened " .. U.Ago(s.created)
    bits[#bits + 1] = ("%d %s"):format(players, U.Plural(players, "raider"))
    local c = ("%d contested %s"):format(contested, U.Plural(contested, "item"))
    bits[#bits + 1] = contested > 0 and T:Wrap("yellow", c) or c
    b.sub:SetText(concat(bits, DOT))
    if (b.sub:GetStringWidth() or 0) > (b:GetWidth() or 500) - 172 then
        table.remove(bits, opened)
        b.sub:SetText(concat(bits, DOT))
    end
end

local function refreshBanner(s)
    local b = page.banner
    b:SetShown(s ~= nil)
    if not s then return end
    b.title:SetText(plain(s.title or "Soft reserves"))
    refreshFacts(s)
    local idx = SR:Index(s)
    local count = idx and idx.count or 0
    if s.locked then b.state:SetText("LOCKED", "yellow") else b.state:SetText("OPEN", "green") end
    UI:SetIcon(b.state.icon, s.locked and "lock" or "check")
    b.state.icon:SetVertexColor(unpack(s.locked and C.yellow or C.green))
    b.state:Show()
    b.plus:SetShown(s.plus and true or false)
    local limit = SR:Limit(s)
    b.limit:SetText(limit .. " EACH", "dim")
    b.limit:Show()
    layoutPills(b)
    b.big:SetText(count)
    b.bigLbl:SetText(U.Plural(count, "reserve", "reserves"))
    b.hazard:SetShown(s.locked and true or false)
end

-------------------------------------------------------------------------------
-- Your reserves
-------------------------------------------------------------------------------
local SLOT_COMPACT_H, SLOT_COMPACT_GAP = 24, 3

-- Limits of 4+ would squeeze the catalogue below down to nothing at the default window
-- height, so those slots drop to one line and the "vs ..." detail moves to the tooltip.
local function setSlotCompact(r, on)
    if r.compact == on then return end
    r.compact = on
    local size = on and 20 or ICON_SIZE
    r.item:SetSize(size, size)
    r.socket:SetSize(size, size)
    r.name:ClearAllPoints()
    if on then
        r.name:SetPoint("LEFT", r.item, "RIGHT", 8, 0)
        r.name:SetPoint("RIGHT", r, "RIGHT", -32, 0)
    else
        r.name:SetPoint("TOPLEFT", r.item, "TOPRIGHT", 8, -1)
        r.name:SetPoint("TOPRIGHT", r, "TOPRIGHT", -32, -4)
    end
end

local function slotRow(parent, i)
    -- a carved well, no rim of its own: the only coloured edge in here is the item's quality
    local r = UI:Well(parent)
    r:SetHeight(SLOT_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * (SLOT_H + SLOT_GAP))
    r:SetPoint("TOPRIGHT", 0, -(i - 1) * (SLOT_H + SLOT_GAP))
    r.hl = UI:Tex(r, "BORDER", { 1, 1, 1, 0.05 })
    r.hl:SetAllPoints()
    r.hl:Hide()
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        self.hl:Show()
        itemTip(self, self.itemID)
        if self.subText and GameTooltip and GameTooltip:IsShown() then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(self.subText, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    r:SetScript("OnLeave", function(self) self.hl:Hide(); UI:HideTip() end)
    r.item = dressItem(UI:ItemButton(r, ICON_SIZE))
    r.item:SetPoint("LEFT", 4, 0)
    r.name = UI:Text(r, 12, "text")
    r.name:SetPoint("TOPLEFT", r.item, "TOPRIGHT", 8, -1)
    r.name:SetPoint("TOPRIGHT", r, "TOPRIGHT", -32, -5)
    r.sub = UI:Text(r, 11, "dim")
    r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -2)
    r.sub:SetPoint("TOPRIGHT", r.name, "BOTTOMRIGHT", 0, -2)
    r.remove = UI:IconButton(r, "trash", 22, "Drop this reserve", function(btn)
        local id = btn:GetParent().itemID
        if not id then return end
        local ok, err = SR:RemoveReserve(id)
        if not ok then fail(err) end
    end, "dim")
    r.remove:SetPoint("RIGHT", -5, 0)
    -- an empty slot is a bare socket with a plus in it
    r.socket = UI:Tex(r, "ARTWORK", { 0, 0, 0, 0.32 })
    r.socket:SetSize(ICON_SIZE, ICON_SIZE)
    r.socket:SetPoint("LEFT", 4, 0)
    r.plusIcon = UI:Icon(r, 12, "plus", "OVERLAY", { C.bronze[1], C.bronze[2], C.bronze[3], 0.85 })
    r.plusIcon:SetPoint("CENTER", r.socket, "CENTER")
    r.emptyText = UI:Text(r, 12, "dim")
    r.emptyText:SetPoint("LEFT", r.socket, "RIGHT", 8, 0)
    return r
end

local function buildMine(cols)
    -- the one gold rim on the page: this is the thing you hold
    local card = UI:Card(cols, { title = "Your reserves", icon = "star", tier = "hero" })
    card:SetPoint("TOPLEFT")
    card:SetWidth(LEFT_MIN)
    card:SetHeight(120)
    card.count = UI:Pill(card.right, "", "green", { height = 18 })
    card.count:SetPoint("RIGHT")
    card.slots = {}
    for i = 1, SR.MAX_LIMIT do card.slots[i] = slotRow(card.body, i) end
    page.mine = card
end

local function slotSub(s, itemID)
    local others = {}
    for _, e in ipairs(SR:ReservesFor(itemID)) do
        if e.player ~= API.MyKey() then others[#others + 1] = e end
    end
    local plus = SR:PlusFor(s, API.MyKey() or "", itemID, SR:Index(s) and SR:Index(s).byPlayer[API.MyKey() or ""])
    local lead = plus > 0 and T:Wrap("green", "+" .. plus .. "  ") or ""
    if #others == 0 then return lead .. T:Wrap("green", "Just you so far") end
    return lead .. T:Wrap("yellow", "vs ") .. whoText(others, 3)
end

local function refreshMine(s)
    local card = page.mine
    local limit = SR:Limit(s)
    local mine = SR:MyReserves()
    local editable = SR:CanEditReserves(s)
    local compact = limit >= 4
    local h = compact and SLOT_COMPACT_H or SLOT_H
    local gap = compact and SLOT_COMPACT_GAP or SLOT_GAP
    -- a pick that wasn't here last time (same session) gets one light sweep
    local before = card.shown
    if card.shownFor ~= s.id then before = nil end
    card.shown, card.shownFor = {}, s.id
    for _, id in ipairs(mine) do card.shown[id] = true end
    local saidEmpty = false
    for i, r in ipairs(card.slots) do
        if i <= limit then
            r:SetHeight(h)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -(i - 1) * (h + gap))
            r:SetPoint("TOPRIGHT", 0, -(i - 1) * (h + gap))
            setSlotCompact(r, compact)
            local id = mine[i]
            r.itemID = id
            if id then
                r.item:Show()
                r.item:SetItem(id)
                local sub = slotSub(s, id)
                r.subText = sub
                if compact then
                    r.name:SetText(coloredName(id) .. T:Wrap("faint", DOT) .. sub)
                    r.sub:Hide()
                else
                    r.name:SetText(coloredName(id))
                    r.sub:SetText(sub)
                    r.sub:Show()
                end
                r.name:Show()
                r.socket:Hide(); r.plusIcon:Hide(); r.emptyText:Hide()
                r.remove:SetShown(editable)
                r.skin:SetAlpha(1)
                if before and not before[id] then UI:Shine(r, 0.8) end
            else
                r.subText = nil
                r.item:Hide(); r.name:Hide(); r.sub:Hide(); r.remove:Hide()
                r.socket:Show(); r.plusIcon:Show()
                -- said once: on a limit of four it isn't news by the third slot
                r.emptyText:SetShown(not saidEmpty)
                saidEmpty = true
                r.emptyText:SetText(editable and "Empty slot. Pick something below." or "Empty slot. Locked, sorry.")
                r.skin:SetAlpha(0.6)
            end
            r:Show()
        else
            r.itemID, r.subText = nil, nil
            r:Hide()
        end
    end
    card:SetHeight(38 + limit * (h + gap) - gap + 12)
    card.count:SetText(#mine .. " / " .. limit, #mine >= limit and "green" or "yellow")
end

-------------------------------------------------------------------------------
-- Add a reserve: paste / shift-click box + the learned catalogue
-------------------------------------------------------------------------------
local function addFrom(text, box)
    text = U.Trim(text or "")
    if text == "" then return fail("Shift-click an item into the box, or paste a link or item ID.") end
    local ok, err = SR:AddReserve(text)
    if not ok then return fail(err) end
    local id = API.ItemID(text)
    if box then box:SetText(""); box:RefreshPlaceholder() end
    UI:Toast({ title = "Dibs called", icon = API.ItemIcon(id), duration = 4,
        text = (id and (API.ItemLink(id) or nameOf(id)) or "That one") .. " is on your list." })
end

local function toggleReserve(itemID)
    if U.Contains(SR:MyReserves(), itemID) then
        local ok, err = SR:RemoveReserve(itemID)
        if not ok then fail(err) end
    else
        local ok, err = SR:AddReserve(itemID)
        if not ok then fail(err) end
    end
end

--- extra: the currently picked value, listed even when it came from somewhere else
-- (a raid night's instance), so the dropdown never reads "Choose..." over a real pick.
local function instanceItems(allText, extra)
    local out = { { value = "", text = allText or "All raids" } }
    local seen = {}
    for _, name in ipairs(KNOWN_RAIDS) do
        seen[name] = true
        out[#out + 1] = { value = name, text = name }
    end
    for _, name in ipairs(safeList(GF.Loot, "Instances")) do
        if type(name) == "string" and not seen[name] then
            seen[name] = true
            out[#out + 1] = { value = name, text = plain(name) }
        end
    end
    if type(extra) == "string" and extra ~= "" and not seen[extra] then
        out[#out + 1] = { value = extra, text = plain(extra) }
    end
    return out
end

local function catalogRowCreate(row)
    row.btn = dressItem(UI:ItemButton(row, ICON_SIZE))
    row.btn:SetPoint("LEFT", 4, 0)
    -- the icon eats the row's click; make it do the same thing (shift-click still links)
    row.btn.onClick = function()
        if row.item and not API.IsShiftKeyDown() then toggleReserve(row.item.itemID) end
    end
    row.name = UI:Text(row, 12, "text")
    row.name:SetPoint("TOPLEFT", row.btn, "TOPRIGHT", 8, -1)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -64, -5)
    row.sub = UI:Text(row, 11, "dim")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.sub:SetPoint("TOPRIGHT", row.name, "BOTTOMRIGHT", 0, -2)
    row.mark = UI:Icon(row, 14, "plus", "OVERLAY", "dim")
    row.mark:SetPoint("RIGHT", -10, 0)
    row.count = UI:Pill(row, "", "yellow", { height = 18 })
    row.count:SetPoint("RIGHT", row.mark, "LEFT", -6, 0)
end

local function catalogRowUpdate(row, e)
    row.btn.qHint = e.q
    row.btn:SetItem(e.itemID)
    local n = nameOf(e.itemID)
    if n then
        local r, g, b = API.QualityColor(qualityOf(e.itemID) or e.q or 1)
        row.name:SetText(U.Color(n, r, g, b))
    elseif e.n then
        local r, g, b = API.QualityColor(e.q or 1)
        row.name:SetText(U.Color(e.n, r, g, b))
    else
        row.name:SetText(T:Wrap("faint", "Fetching item info..."))
    end
    row.sub:SetText(e.b and (e.b .. DOT .. (e.i or "")) or (e.i or "Trash drop"))
    local mineHas = U.Contains(page.myList or {}, e.itemID)
    UI:SetIcon(row.mark, mineHas and "check" or "plus")
    local mc = mineHas and C.green or C.dim
    row.mark:SetVertexColor(mc[1], mc[2], mc[3], 1)
    local others = #SR:ReservesFor(e.itemID) - (mineHas and 1 or 0)
    if others > 0 then
        row.count:SetText(others .. " SR", others >= 2 and "red" or "yellow")
        row.count:Show()
    else
        row.count:Hide()
    end
end

-- { full line, short line for a cramped list }
local CATALOG_EMPTY = {
    none = { "Nothing learned yet. Loot tables aren't published, so items show up here once someone loots them in a raid. Shift-click or paste in the meantime.",
             "Nothing learned yet. Shift-click or paste one in above." },
    nomatch = { "Nothing matches. Check your spelling, champ.", "Nothing matches. Check your spelling, champ." },
}

--- It holds an instruction people need, so it's plain reading text at the top of the list.
local function layoutCatalogEmpty()
    local card = page and page.add
    if not card or not card.empty then return end
    local lines = CATALOG_EMPTY[card.emptyKind or "none"] or CATALOG_EMPTY.none
    card.empty:SetText((card.list:GetHeight() or 0) < 76 and lines[2] or lines[1])
end

local function buildAdd(cols)
    local card = UI:Card(cols, { title = "Add a reserve", icon = "plus" })
    card:SetPoint("TOPLEFT", page.mine, "BOTTOMLEFT", 0, -16)
    card:SetPoint("BOTTOMLEFT", cols, "BOTTOMLEFT", 0, 0)
    card:SetWidth(LEFT_MIN)
    local body = card.body
    card.input = UI:Input(body, { placeholder = "Shift-click or paste a link",
        onEnter = function(text, box) addFrom(text, box) end })
    UI.AttachTip(card.input, { "Add a reserve", { "Shift-click an item into the box, paste a link, or type an item ID, then hit Add." } })
    card.input:SetPoint("TOPLEFT")
    card.input:SetPoint("TOPRIGHT", -64, 0)
    SR:AddLinkTarget(card.input)
    card.btn = UI:Button(body, "Add", { style = "primary", width = 58, onClick = function() addFrom(card.input:GetText(), card.input) end })
    card.btn:SetPoint("TOPRIGHT")
    card.inst = UI:Dropdown(body, {
        width = 128,
        items = function() return instanceItems(nil, page.instFilter) end,
        get = function() return page.instFilter or "" end,
        set = function(v) page.instFilter = v; page.refreshCatalog() end,
    })
    card.inst:SetPoint("TOPLEFT", 0, -34)
    card.search = UI:Search(body, { placeholder = "Search loot...",
        onChange = function(text) page.catSearch = text; page.refreshCatalog() end })
    card.search:SetPoint("TOPLEFT", card.inst, "TOPRIGHT", 6, 0)
    card.search:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -34)
    card.search:HookScript("OnSizeChanged", function(_, w)
        card.search.placeholder:SetText((tonumber(w) or 0) >= 136 and "Search loot..." or "Search...")
    end)
    card.list = UI:List(body, {
        rowHeight = ROW_H, spacing = 0,
        createRow = catalogRowCreate,
        updateRow = catalogRowUpdate,
        onClick = function(e) toggleReserve(e.itemID) end,
        onEnter = function(row, e)
            itemTip(row, e.itemID)
            if GameTooltip and GameTooltip:IsShown() then
                local mineHas = U.Contains(page.myList or {}, e.itemID)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(mineHas and "Click to drop this reserve." or "Click to reserve it.", C.green[1], C.green[2], C.green[3])
                GameTooltip:Show()
            end
        end,
    })
    card.list:SetPoint("TOPLEFT", 0, -68)
    -- the kit keeps 10 spare on a row's right for a scrollbar: hang that in the card's margin
    card.list:SetPoint("BOTTOMRIGHT", 10, 0)
    card.empty = UI:Para(body, 12, "dim")
    card.empty:SetPoint("TOPLEFT", 2, -74)
    card.empty:SetPoint("TOPRIGHT", -2, -74)
    card.empty:Hide()
    card.list:HookScript("OnSizeChanged", function() layoutCatalogEmpty() end)
    card:HookScript("OnSizeChanged", function()
        GF:Debounce("srui-addsize", 0.1, function() if page.refreshCatalog then page.refreshCatalog() end end)
    end)
    card.lock = UI:Empty(body, "SR's locked. Your picks are set in stone. Well, in a SavedVariable.", "lock")
    card.lock:Hide()
    page.add = card
end

local function refreshCatalog()
    if not page or not page.add then return end
    local card = page.add
    local s = page.session
    local editable = (s and SR:CanEditReserves(s)) and true or false
    -- a high limit on a small window leaves no room for the catalogue under the slots:
    -- keep the paste / shift-click box and drop the browser rather than overflow the card
    local roomy = (card:GetHeight() or 0) - 48 - 68 >= 40
    card.input:SetShown(editable)
    card.btn:SetShown(editable)
    for _, w in ipairs({ card.inst, card.search, card.list }) do w:SetShown(editable and roomy) end
    card.lock:SetShown(not editable)
    if not editable or not roomy then card.empty:Hide() return end
    card.inst:Refresh()
    page.myList = SR:MyReserves()
    local filter = page.instFilter or ""
    local q = page.catSearch or ""
    local all = safeList(GF.Loot, "CatalogItems")
    local items = {}
    for _, e in ipairs(all) do
        if type(e) == "table" and e.itemID and (filter == "" or e.i == filter) then
            -- the learned name first: asking the client about every catalogue entry on
            -- every refresh queues a server lookup for each uncached one
            if q == "" or U.Matches(e.n or nameOf(e.itemID), q) or U.Matches(e.b, q) then items[#items + 1] = e end
        end
    end
    card.list:SetItems(items, true)
    if #items == 0 then
        card.emptyKind = #all == 0 and "none" or "nomatch"
        layoutCatalogEmpty()
        card.empty:Show()
    else
        card.empty:Hide()
    end
end

-------------------------------------------------------------------------------
-- The list: grouped by item or by player
-------------------------------------------------------------------------------
local function itemRowCreate(row)
    -- your own row: the kit's edge and a lighter wash, because epic purple dies on a gold one
    row.sel:SetAlpha(0.35)
    row.btn = dressItem(UI:ItemButton(row, ICON_SIZE))
    row.btn:SetPoint("LEFT", 4, 0)
    row.name = UI:Text(row, 12, "text")
    row.name:SetPoint("TOPLEFT", row.btn, "TOPRIGHT", 8, -1)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -5)
    row.who = UI:Text(row, 11, "dim")
    row.who:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.who:SetPoint("TOPRIGHT", row.name, "BOTTOMRIGHT", 0, -2)
    row.pill = UI:Pill(row, "CONTESTED", "yellow", { icon = "warning" })
    row.pill:SetPoint("RIGHT", -4, 0)
end

local function itemRowUpdate(row, e)
    row.btn:SetItem(e.itemID)
    row.name:SetText(coloredName(e.itemID))
    row.who:SetText(whoText(e.list, 4))
    -- only a fight over an item earns anything on the right, so a fight is what you see
    local contested = #e.list >= 2
    if contested then row.pill:SetText(#e.list .. " CONTESTED", "yellow") end
    row.pill:SetShown(contested)
    -- the name only gives way to a pill that's there
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", contested and -(row.pill:GetWidth() + 12) or -8, -5)
end

local function itemRowEnter(row, e)
    local lines = { T:Wrap("faint", dropText(e.itemID)) }
    for _, r in ipairs(e.list) do
        lines[#lines + 1] = { U.ClassName(r.player, r.class), (r.plus or 0) > 0 and T:Wrap("green", "+" .. r.plus) or " " }
    end
    UI:Tip(row, coloredName(e.itemID), lines)
end

local function playerRowCreate(row)
    row.avatar = UI:Avatar(row, ICON_SIZE)
    row.avatar:SetPoint("LEFT", 4, 0)
    row.name = UI:Text(row, 12, "text", "ui")
    row.name:SetPoint("TOPLEFT", row.avatar, "TOPRIGHT", 8, -1)
    row.sub = UI:Text(row, 11, "dim")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.sub:SetPoint("TOPRIGHT", row.name, "BOTTOMRIGHT", 0, -2)
    row.icons = {}
    for i = 1, SR.MAX_LIMIT do
        local b = dressItem(UI:ItemButton(row, ICON_SIZE))
        b:SetPoint("RIGHT", row, "RIGHT", -4 - (i - 1) * 32, 0)
        row.icons[i] = b
    end
end

local function playerRowUpdate(row, e)
    local r = e.reserve
    row.avatar:SetClass(r.class)
    row.name:SetText(U.ClassName(r.player, r.class))
    local n = #r.items
    for i, b in ipairs(row.icons) do
        -- right-to-left, so the first pick sits leftmost
        local id = r.items[n - i + 1]
        if id then b:SetItem(id); b:Show() else b:Hide() end
    end
    -- the text stops short of however many item icons this row shows (sub follows name)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -12 - min(n, #row.icons) * 32, -5)
    local bits = {}
    for _, id in ipairs(r.items) do
        local nm = nameOf(id)
        if nm then bits[#bits + 1] = nm end
    end
    local sub = #bits > 0 and concat(bits, ", ") or (n .. " " .. U.Plural(n, "reserve"))
    if r.note then sub = T:Wrap("dim", plain(r.note)) .. DOT .. sub end
    row.sub:SetText(sub)
end

local function playerRowClick(e, row, button)
    local r = e.reserve
    local s = page.session
    if button == "RightButton" then
        local items = { { text = U.ClassName(r.player, r.class), title = true } }
        items[#items + 1] = { text = "Whisper", icon = "bubble", func = function() UI:Whisper(r.player) end }
        if s and SR:CanControl(s) and r.player ~= API.MyKey() then
            items[#items + 1] = { text = "Clear their reserves", icon = "trash", color = "red", func = function()
                UI:Confirm("Clear " .. U.ShortName(r.player) .. "'s reserves?", "Removes every pick they made in this session.", function()
                    local ok, err = SR:ClearPlayer(s, r.player)
                    if not ok then fail(err) end
                end, "Clear", "red")
            end }
        end
        UI:OpenMenu(nil, items, { width = 190 })
    elseif UI.OpenProfile then
        UI:OpenProfile(r.player)
    end
end

local function buildList(cols)
    local card = UI:Card(cols, { title = "The list", icon = "clipboard" })
    card:SetPoint("TOPLEFT", page.mine, "TOPRIGHT", 16, 0)
    card:SetPoint("BOTTOMRIGHT", cols, "BOTTOMRIGHT", 0, 0)
    local body = card.body
    card.tabs = UI:Tabs(body, {
        { key = "item", text = "By item", icon = "bag" },
        { key = "player", text = "By player", icon = "roster" },
    }, function(key) page.mode = key; page.refreshList() end)
    card.tabs:SetPoint("TOPLEFT", 0, 4)
    card.search = UI:Search(body, { width = 190, placeholder = "Search names or loot...",
        onChange = function(text) page.listSearch = text; page.refreshList() end })
    card.search:SetPoint("TOPRIGHT", 0, 2)
    -- shrink the search before it slides under the tabs on a narrow window
    body:HookScript("OnSizeChanged", function(self, w)
        w = tonumber(w) or self:GetWidth() or 0
        local sw = U.Clamp(w - (card.tabs:GetWidth() or 0) - 16, 90, 240)
        card.search:SetWidth(sw)
        card.search.placeholder:SetText(sw >= 170 and "Search names or loot..." or "Search...")
    end)
    card.byItem = UI:List(body, {
        rowHeight = ROW_H, spacing = 0, createRow = itemRowCreate, updateRow = itemRowUpdate, onEnter = itemRowEnter,
        isSelected = function(e) return e.mine end,
    })
    card.byPlayer = UI:List(body, {
        rowHeight = ROW_H, spacing = 0, createRow = playerRowCreate, updateRow = playerRowUpdate, onClick = playerRowClick,
        isSelected = function(e) return e.mine end,
        onEnter = function(row, e)
            local lines = {}
            for _, id in ipairs(e.reserve.items) do lines[#lines + 1] = coloredName(id) end
            if e.reserve.note then lines[#lines + 1] = T:Wrap("dim", "Note: " .. plain(e.reserve.note)) end
            lines[#lines + 1] = T:Wrap("faint", "Right-click for options")
            UI:Tip(row, U.ClassName(e.reserve.player, e.reserve.class), lines)
        end,
    })
    for _, l in ipairs({ card.byItem, card.byPlayer }) do
        l:SetPoint("TOPLEFT", 0, -40)
        -- the kit keeps 10 spare on a row's right for a scrollbar: hang that in the card's margin
        l:SetPoint("BOTTOMRIGHT", 10, 0)
    end
    card.empty = UI:Empty(body, "", "dice")
    card.empty:ClearAllPoints()
    card.empty:SetPoint("CENTER", 0, -20)
    page.list = card
    page.mode = "item"
    card.tabs:Select("item", true)
end

local function refreshList()
    if not page or not page.list then return end
    local card = page.list
    local s = page.session
    local idx = s and SR:Index(s)
    local q = page.listSearch or ""
    local me = API.MyKey()
    local rows = {}
    if idx then
        if page.mode == "player" then
            for player, r in pairs(idx.byPlayer) do
                local hit = q == "" or U.Matches(player, q)
                if not hit then
                    for _, id in ipairs(r.items) do
                        if U.Matches(nameOf(id), q) then hit = true break end
                    end
                end
                if hit then rows[#rows + 1] = { reserve = r, mine = player == me, key = player } end
            end
            sort(rows, function(a, b) return a.key < b.key end)
        else
            for itemID, list in pairs(idx.byItem) do
                local n = nameOf(itemID)
                local hit = q == "" or U.Matches(n, q)
                local mine = false
                for _, e in ipairs(list) do
                    if e.player == me then mine = true end
                    if not hit and U.Matches(e.player, q) then hit = true end
                end
                if hit then rows[#rows + 1] = { itemID = itemID, list = list, mine = mine, name = n or "" } end
            end
            sort(rows, function(a, b)
                if #a.list ~= #b.list then return #a.list > #b.list end
                if a.name ~= b.name then return a.name < b.name end
                return a.itemID < b.itemID
            end)
        end
    end
    local byPlayer = page.mode == "player"
    card.byItem:SetShown(not byPlayer)
    card.byPlayer:SetShown(byPlayer)
    local list = byPlayer and card.byPlayer or card.byItem
    list:SetItems(rows, true)
    if #rows == 0 then
        card.empty:SetText((idx and idx.count > 0) and "Nothing matches that. Check your spelling, champ."
            or GF.Flavor.emptyStates.sr)
        card.empty:Show()
    else
        card.empty:Hide()
    end
end

-------------------------------------------------------------------------------
-- No session: the host's start form, or a quiet street for everyone else
-------------------------------------------------------------------------------
local function label(parent, text)
    local l = UI:Text(parent, 11, "bronze", "ui")
    l:SetText(text)
    return l
end

local function eventItems()
    local out = { { value = "", text = "None" } }
    if GF.Raids and GF.Raids.Upcoming then
        for _, ev in ipairs(safeList(GF.Raids, "Upcoming", 6)) do
            if type(ev) == "table" and ev.id then
                out[#out + 1] = { value = ev.id, text = tostring(ev.title or "Raid") .. DOT .. U.DateTime(ev.time), ev = ev }
            end
        end
    end
    return out
end

local function applyEvent(form, ev)
    if type(ev) ~= "table" then return end
    form.eventId = ev.id
    if ev.instance then form.instance = ev.instance end
    if type(ev.srLimit) == "number" then form.limit = U.Clamp(math.floor(ev.srLimit), 1, SR.MAX_LIMIT) end
    if U.Trim(form.titleBox:GetText()) == "" or form.autoTitle then
        form.titleBox:SetText(tostring(ev.title or ev.instance or "Raid") .. " SR")
        form.titleBox:RefreshPlaceholder()
        form.autoTitle = true
    end
    form.instDrop:Refresh()
    form.limitDrop:Refresh()
    form.eventDrop:Refresh()
end

local HOW_STEPS = {
    "Open the SR and hit Announce so the raid knows it's on.",
    "Greenfields users pick here. Everyone else whispers you !sr <item link>.",
    "Lock it before the first pull. Late dibs are no dibs.",
    "When loot drops the Loot Desk shows who reserved what. Roll it, award it, done.",
}

--- The form is what this state is for, so it leads, and it's measured rather than fixed: the same
-- rows at every window size, narrower on a small window, with the steps beside it stacked by how
-- far their text actually wrapped.
local function layoutNone()
    local none, form, how = page.none, page.form, page.how
    local w = none:GetWidth() or 0
    if w <= 0 then return end
    local fw = U.Clamp(math.floor(w * 0.55), 340, 420)
    local inner = fw - 24
    form:SetWidth(fw)
    form.lead:SetWidth(inner)
    local y = (form.lead:GetStringHeight() or 16) + 14
    local function place(l, c, yy, x, right)
        l:ClearAllPoints()
        l:SetPoint("TOPLEFT", x or 0, -yy)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", x or 0, -(yy + 15))
        if right then c:SetPoint("TOPRIGHT", 0, -(yy + 15)) end
    end
    place(form.titleLbl, form.titleBox, y, 0, true)
    local rw = inner - form.limitDrop:GetWidth() - 12
    form.instDrop:SetWidth(rw)
    place(form.instLbl, form.instDrop, y + 48, 0)
    place(form.limitLbl, form.limitDrop, y + 48, rw + 12)
    place(form.eventLbl, form.eventDrop, y + 96, 0, true)
    form.plus:ClearAllPoints()
    form.plus:SetPoint("TOPLEFT", 0, -(y + 148))
    form.start:ClearAllPoints()
    form.start:SetPoint("TOPLEFT", 0, -(y + 182))
    form.hint:ClearAllPoints()
    form.hint:SetPoint("TOPLEFT", 0, -(y + 222))
    form.hint:SetWidth(inner)
    -- on a narrow form the plain wrap leaves "open." alone on a line
    form.hint:SetText("You'll be the host." .. (inner < 380 and "\n" or " ") .. "Starting a new one closes any SR you left open.")
    local total = y + 222 + (form.hint:GetStringHeight() or 14)
    local fh = 38 + total + 18
    form:SetHeight(fh)

    local tw = (w - fw - 16) - 24 - 28
    -- the steps share the card's height, so it doesn't read as half empty beside a taller form
    local used = 0
    for _, st in ipairs(how.steps) do
        st.text:SetWidth(tw)
        used = used + max(20, st.text:GetStringHeight() or 14)
    end
    local pitch = U.Clamp(math.floor((fh - 38 - 16 - used) / max(1, #how.steps - 1)), 14, 64)
    local sy = 2
    for _, st in ipairs(how.steps) do
        st.num:ClearAllPoints()
        st.num:SetPoint("TOPLEFT", 2, -(sy - 1))
        st.text:ClearAllPoints()
        st.text:SetPoint("TOPLEFT", 28, -sy)
        sy = sy + max(20, st.text:GetStringHeight() or 14) + pitch
    end
end

local function buildNone()
    local none = CreateFrame("Frame", nil, page)
    none:SetPoint("TOPLEFT", page.header, "BOTTOMLEFT", 0, -14)
    none:SetPoint("BOTTOMRIGHT")
    page.none = none

    local form = UI:Card(none, { title = "Start a soft-res session", icon = "dice", tier = "hero" })
    form:SetPoint("TOPLEFT")
    form:SetSize(420, 330)
    local body = form.body
    form.lead = UI:Para(body, 12, "dim")
    form.lead:SetPoint("TOPLEFT")
    form.lead:SetText("No SR running. Nobody's called dibs on anything yet.\nSuspiciously civilised.")
    form.titleLbl = label(body, "Title")
    form.titleBox = UI:Input(body, { placeholder = "e.g. Onyxia Wednesday SR", max = 48,
        onChange = function() form.autoTitle = false end })
    form.instLbl = label(body, "Raid")
    form.instDrop = UI:Dropdown(body, {
        width = 290, items = function() return instanceItems("Not sure yet", form.instance) end,
        get = function() return form.instance or "" end,
        set = function(v) form.instance = v ~= "" and v or nil end,
    })
    form.limitLbl = label(body, "Reserves each")
    form.limitDrop = UI:Dropdown(body, {
        width = 94,
        items = function()
            local out = {}
            for i = 1, SR.MAX_LIMIT do out[i] = { value = i, text = tostring(i) } end
            return out
        end,
        get = function() return form.limit or GF.Roster:Config().srLimit end,
        set = function(v) form.limit = v end,
    })
    form.eventLbl = label(body, "Linked raid night")
    form.eventDrop = UI:Dropdown(body, {
        width = 396, items = eventItems,
        get = function() return form.eventId or "" end,
        set = function(v, item)
            form.eventId = v ~= "" and v or nil
            if item and item.ev then applyEvent(form, item.ev) end
        end,
        placeholder = "None",
    })
    form.plus = UI:Toggle(body, "Plus mode", {
        get = function() return form.plusOn and true or false end,
        set = function(v) form.plusOn = v end,
        tooltip = { "Plus mode", { "+1 for every earlier session a raider reserved the same item and missed out. Higher plus wins ties." } },
    })
    form.start = UI:Button(body, "Open the SR", { style = "primary", icon = "dice", height = 30, onClick = function()
        local ok, err = SR:Start({ title = form.titleBox:GetText(), instance = form.instance, eventId = form.eventId,
            limit = form.limit, plus = form.plusOn })
        if not ok then return fail(err) end
        form.prefilled = false
        UI:Toast({ title = "SR's open", text = "Hit Announce so the raid knows. Lock it when you're ready.", icon = "dice", style = "green" })
    end })
    form.hint = UI:Para(body, 11, "dim")
    form.hint:SetText("You'll be the host. Starting a new one closes any SR you left open.")
    page.form = form

    local how = UI:Card(none, { title = "How it works", icon = "clipboard" })
    how:SetPoint("TOPLEFT", form, "TOPRIGHT", 16, 0)
    how:SetPoint("BOTTOMRIGHT", form, "BOTTOMRIGHT", 0, 0)
    how:SetPoint("RIGHT", none, "RIGHT", 0, 0)
    how.steps = {}
    for i, text in ipairs(HOW_STEPS) do
        local num = UI:Text(how.body, 15, "bronze", "ui")
        num:SetText(i)
        local t = UI:Para(how.body, 12, "text")
        t:SetText(text)
        how.steps[i] = { num = num, text = t }
    end
    page.how = how
    none:HookScript("OnSizeChanged", function() GF:Safe("srui:none", layoutNone) end)

    page.quiet = UI:Empty(none, "Nobody's called dibs on anything yet. Suspiciously civilised.\nPester your raid leader, or slip them forty bucks.", "dice",
        { heading = "No SR running" })
    page.quiet:ClearAllPoints()
    page.quiet:SetPoint("CENTER", 0, 20)
    -- the kit caps its block at 360, which leaves these lines ending in one lonely word
    local function widen()
        local w = min(480, max(120, (none:GetWidth() or 480) - 32))
        page.quiet:SetWidth(w)
        page.quiet.text:SetWidth(w)
    end
    none:HookScript("OnSizeChanged", widen)
    widen()
end

local function refreshNone()
    local canHost = SR:CanHost()
    page.form:SetShown(canHost)
    page.how:SetShown(canHost)
    page.quiet:SetShown(not canHost)
    if not canHost then return end
    layoutNone()
    -- again next frame, in case the client only wrapped the strings properly once they were on screen
    GF:After(0, function() if page.none:IsShown() and page.form:IsShown() then layoutNone() end end)
    local form = page.form
    if not form.prefilled then
        form.prefilled = true
        form.instance, form.eventId, form.limit, form.plusOn, form.autoTitle = nil, nil, nil, false, true
        form.titleBox:SetText("")
        form.titleBox:RefreshPlaceholder()
        local ev
        if GF.Raids and GF.Raids.Current then
            local ok, cur = GF:Safe("srui:current", GF.Raids.Current, GF.Raids)
            if ok and type(cur) == "table" then ev = cur end
        end
        if ev then applyEvent(form, ev) end
        form.plus:Refresh()
    end
    form.instDrop:Refresh()
    form.limitDrop:Refresh()
    form.eventDrop:Refresh()
end

-------------------------------------------------------------------------------
-- Page
-------------------------------------------------------------------------------
local function refresh()
    if not page then return end
    local s = SR:ActiveSession()
    page.session = s
    local ctl = s and SR:CanControl(s) or false
    page.btnAnnounce:SetShown(ctl)
    page.btnLock:SetShown(ctl)
    if s then
        page.btnLock:SetText(s.locked and "Unlock" or "Lock")
        -- a locked SR is the state worth noticing, and Unlock the button you'd come back for
        page.btnLock:SetStyle(s.locked and "warn" or "secondary")
    end
    page.btnMore:SetShown(s ~= nil)
    page.btnDesk:SetShown(ctl or SR:CanHost())
    layoutActions()
    refreshBanner(s)
    if not s then
        page.cols:Hide()
        page.none:Show()
        refreshNone()
        return
    end
    page.none:Hide()
    page.cols:Show()
    if page.form then page.form.prefilled = false end
    refreshMine(s)
    refreshCatalog()
    refreshList()
end

local function build(p)
    page = p
    buildHeader()
    buildBanner()
    local cols = CreateFrame("Frame", nil, page)
    cols:SetPoint("TOPLEFT", page.banner, "BOTTOMLEFT", 0, -16)
    cols:SetPoint("BOTTOMRIGHT")
    page.cols = cols
    buildMine(cols)
    buildAdd(cols)
    buildList(cols)
    cols:HookScript("OnSizeChanged", function(_, w)
        if not w or w <= 0 then return end
        -- a narrow window: the list is where people read, so the left column gives up the spare
        local lw = U.Clamp(math.floor(w * 0.36), w < 640 and 280 or LEFT_MIN, LEFT_MAX)
        page.mine:SetWidth(lw)
        page.add:SetWidth(lw)
        if page.session then GF:Safe("srui:banner", refreshBanner, page.session) end
    end)
    buildNone()
    page.refreshCatalog = refreshCatalog
    page.refreshList = refreshList
end

UI:RegisterPage({
    key = "softres", title = "Soft Res", subtitle = "Call dibs. Leave a bag to hold your spot.",
    icon = "dice", group = "raid", order = 20,
    build = build,
    onShow = function() refresh() end,
    badge = function()
        local s = SR:ActiveSession()
        if not s or s.locked or not SR:CanEditReserves(s) then return nil end
        local me = API.MyKey()
        if s.host ~= me and not GF.Roster:InGroup(s.host) then return nil end
        if #SR:MyReserves() == 0 then return "!" end
        return nil
    end,
})

GF:On("GF_SR_UPDATED", function()
    UI:RefreshPage("softres")
    UI:RefreshNav()
end)

GF:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
    itemID = API.CleanNumber(itemID)
    if not itemID or not waiting[itemID] then return end
    waiting[itemID] = nil
    -- a failed load would just ask again on the refresh, and fail again, forever
    if API.Clean(success) == false then failed[itemID] = true return end
    GF:Debounce("srui-items", 0.3, function() UI:RefreshPage("softres") end)
end)
