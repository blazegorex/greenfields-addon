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
local SLOT_H, SLOT_GAP = 32, 4
local LEFT_W = 310
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
-- Warcraft dressing
-------------------------------------------------------------------------------
local function tile(tex, path, r, g, b, a)
    tex:SetTexture(path, "REPEAT", "REPEAT")
    tex:SetHorizTile(true)
    tex:SetVertTile(true)
    tex:SetVertexColor(r, g, b, a)
end

local function gradient(tex, orient, r, g, b, a1, a2)
    tex:SetTexture(T.tex.white)
    if tex.SetGradient and CreateColor then
        tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2))
    else
        tex:SetColorTexture(r, g, b, (a1 + a2) / 2)
    end
end

--- Turns a kit ItemButton into a Warcraft item slot: the icon sits under a bevelled frame
-- tinted to the item's quality (gold while unknown or common). Tooltip, shift-link and
-- clicks are untouched; the catalogue's learned quality covers items not cached yet.
local function dressItem(b)
    local size = b:GetWidth() or 32
    local inset = max(2, math.floor(size * 0.09 + 0.5))
    b.icon:ClearAllPoints()
    b.icon:SetPoint("TOPLEFT", inset, -inset)
    b.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    b.qframe = b:CreateTexture(nil, "OVERLAY", nil, -1)
    b.qframe:SetAllPoints()
    UI.Sliced(b.qframe, T.tex.iconFrame, max(4, math.floor(size * 0.16)))
    local update = b.Update
    b.Update = function(self)
        update(self)
        self:SetBackdropBorderColor(0, 0, 0, 0)
        local q = self.itemID and (qualityOf(self.itemID) or self.qHint)
        if type(q) == "number" and q >= 2 then
            local r, g, bb = API.QualityColor(q)
            self.qframe:SetDesaturated(true)
            self.qframe:SetVertexColor(min(1, r * 1.1 + 0.12), min(1, g * 1.1 + 0.12), min(1, bb * 1.1 + 0.12), 1)
        else
            self.qframe:SetDesaturated(false)
            self.qframe:SetVertexColor(1, 1, 1, 1)
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
    local header = UI:PageHeader(page, "Soft Res", "Call dibs before the bin chickens do.")
    page.header = header
    page.btnMore = UI:Button(header, "More", { icon = "chevron_down", onClick = function(b) openMore(b) end })
    page.btnLock = UI:Button(header, "Lock", { style = "warn", icon = "lock",
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
local BANNER_H = 88

--- The session's hero plate: worn leather under a gold rim, the Soft Res coin in a gold
-- slot, the session title in the quest-title face.
local function buildBanner()
    local b = UI:Panel(page, C.bg1, false)
    b:SetPoint("TOPLEFT", page.header, "BOTTOMLEFT", 0, -8)
    b:SetPoint("TOPRIGHT", page.header, "BOTTOMRIGHT", 0, -8)
    b:SetHeight(BANNER_H)
    b.leather = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.leather:SetPoint("TOPLEFT", 3, -3)
    b.leather:SetPoint("BOTTOMRIGHT", -3, 3)
    tile(b.leather, T.tex.leather, 0.78, 0.72, 0.66, 0.85)
    -- darker toward the right so the pills and the big count read cleanly
    b.shade = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    b.shade:SetPoint("TOPLEFT", 3, -3)
    b.shade:SetPoint("BOTTOMRIGHT", -3, 3)
    gradient(b.shade, "HORIZONTAL", 0, 0, 0, 0.05, 0.45)
    b.glow = b:CreateTexture(nil, "BACKGROUND", nil, 3)
    b.glow:SetTexture(T.tex.glow)
    b.glow:SetVertexColor(C.green[1], C.green[2], C.green[3], 0.10)
    -- kept inside the banner (a 320x170 glow centred on its edge bled over the sidebar)
    b.glow:SetPoint("TOPLEFT", 3, -3)
    b.glow:SetPoint("BOTTOMLEFT", 3, 3)
    b.glow:SetWidth(260)
    b.rim = b:CreateTexture(nil, "BORDER")
    b.rim:SetAllPoints()
    UI.Sliced(b.rim, T.tex.frameGold, 16)
    b.art = UI:FramedIcon(b, 52, T.navArt.softres or "dice")
    b.art:SetPoint("LEFT", 18, 0)
    -- right edges hang off TOP points: pairing a TOPLEFT with a plain "RIGHT" (the
    -- banner's vertical middle) would derive a bogus height for every line
    b.title = UI:Text(b, 21, "wowGold", "title")
    b.title:SetPoint("TOPLEFT", b.art, "TOPRIGHT", 14, 2)
    b.title:SetPoint("TOPRIGHT", b, "TOPRIGHT", -300, -16)
    if b.title.SetShadowOffset then
        b.title:SetShadowOffset(1, -1)
        b.title:SetShadowColor(0, 0, 0, 0.95)
    end
    b.sub = UI:Text(b, 12, "text")
    b.sub:SetPoint("TOPLEFT", b.title, "BOTTOMLEFT", 0, -5)
    b.sub:SetPoint("TOPRIGHT", b.title, "BOTTOMRIGHT", 150, -5)
    b.stats = UI:Text(b, 11, "dim")
    b.stats:SetPoint("TOPLEFT", b.sub, "BOTTOMLEFT", 0, -4)
    b.stats:SetPoint("TOPRIGHT", b.sub, "BOTTOMRIGHT", 0, -4)
    b.state = UI:Pill(b, "OPEN", "green", { icon = "check", height = 20 })
    b.plus = UI:Pill(b, "PLUS MODE", "blue", { icon = "star", height = 20, tooltip = { "Plus mode", { "+1 for every earlier session you reserved the item and missed out. Higher plus wins ties." } } })
    b.limit = UI:Pill(b, "", "text", { icon = "dice", height = 20 })
    b.pills = { b.state, b.plus, b.limit }
    b.big = UI:Text(b, 30, "wowGold", "num")
    b.big:SetPoint("BOTTOMRIGHT", -18, 13)
    b.bigLbl = UI:Text(b, 10, "bronze", "head")
    b.bigLbl:SetPoint("BOTTOMRIGHT", b.big, "BOTTOMLEFT", -6, 5)
    -- locked: hazard tape along the bottom, inside the rim
    b.hazard = b:CreateTexture(nil, "ARTWORK")
    b.hazard:SetTexture(T.tex.hazard, "REPEAT", "REPEAT")
    b.hazard:SetHorizTile(true)
    b.hazard:SetPoint("BOTTOMLEFT", 7, 7)
    b.hazard:SetPoint("BOTTOMRIGHT", -7, 7)
    b.hazard:SetHeight(5)
    b.hazard:SetAlpha(0.9)
    b.hazard:Hide()
    page.banner = b
end

local function layoutPills(b)
    local prev
    for _, p in ipairs(b.pills) do
        p:ClearAllPoints()
        if p:IsShown() then
            if prev then p:SetPoint("RIGHT", prev, "LEFT", -6, 0) else p:SetPoint("TOPRIGHT", -16, -15) end
            prev = p
        end
    end
end

local function refreshBanner(s)
    local b = page.banner
    if not s then
        b.title:SetText("No SR running")
        b.sub:SetText("Nobody's called dibs on anything yet. Suspiciously civilised.")
        b.stats:SetText("")
        for _, p in ipairs(b.pills) do p:Hide() end
        b.big:SetText("")
        b.bigLbl:SetText("")
        b.hazard:Hide()
        b.art:SetDesaturated(true)
        b.art:SetAlpha(0.7)
        return
    end
    b.art:SetDesaturated(false)
    b.art:SetAlpha(1)
    b.title:SetText(plain(s.title or "Soft reserves"))
    local bits = {}
    if s.instance then bits[#bits + 1] = plain(s.instance) end
    bits[#bits + 1] = "Hosted by " .. GF.Roster:Colored(s.host)
    bits[#bits + 1] = "Opened " .. U.Ago(s.created)
    b.sub:SetText(concat(bits, DOT))
    local idx = SR:Index(s)
    local players, count = idx and idx.players or 0, idx and idx.count or 0
    local contested = 0
    if idx then
        for _, list in pairs(idx.byItem) do if #list >= 2 then contested = contested + 1 end end
    end
    b.stats:SetText(("%d %s%s%d contested %s"):format(players, U.Plural(players, "raider"), DOT, contested, U.Plural(contested, "item")))
    if s.locked then b.state:SetText("LOCKED", "yellow") else b.state:SetText("OPEN", "green") end
    UI:SetIcon(b.state.icon, s.locked and "lock" or "check")
    b.state.icon:SetVertexColor(unpack(s.locked and C.yellow or C.green))
    b.state:Show()
    b.plus:SetShown(s.plus and true or false)
    local limit = SR:Limit(s)
    b.limit:SetText(limit .. " EACH", "text")
    b.limit:Show()
    layoutPills(b)
    b.big:SetText(count)
    b.bigLbl:SetText(U.Plural(count, "RESERVE", "RESERVES"))
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
    local size = on and 20 or 26
    r.item:SetSize(size, size)
    r.emptyIcon:SetSize(size, size)
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
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(SLOT_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * (SLOT_H + SLOT_GAP))
    r:SetPoint("TOPRIGHT", 0, -(i - 1) * (SLOT_H + SLOT_GAP))
    -- a gear-slot well: dark slate under a bronze rim
    r.bg = UI:Tex(r, "BACKGROUND", C.bg3)
    r.bg:SetPoint("TOPLEFT", 2, -2)
    r.bg:SetPoint("BOTTOMRIGHT", -2, 2)
    r.hl = UI:Tex(r, "BACKGROUND", { 1, 1, 1, 0.05 }, 1)
    r.hl:SetAllPoints(r.bg)
    r.hl:Hide()
    r.rim = r:CreateTexture(nil, "BORDER")
    r.rim:SetAllPoints()
    UI.Sliced(r.rim, T.tex.frameBronze, 8)
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
    r.item = dressItem(UI:ItemButton(r, 26))
    r.item:SetPoint("LEFT", 4, 0)
    r.name = UI:Text(r, 12, "text")
    r.name:SetPoint("TOPLEFT", r.item, "TOPRIGHT", 8, -1)
    r.name:SetPoint("TOPRIGHT", r, "TOPRIGHT", -32, -4)
    r.sub = UI:Text(r, 10, "faint")
    r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
    r.sub:SetPoint("TOPRIGHT", r.name, "BOTTOMRIGHT", 0, -3)
    r.remove = UI:IconButton(r, "trash", 22, "Drop this reserve", function(btn)
        local id = btn:GetParent().itemID
        if not id then return end
        local ok, err = SR:RemoveReserve(id)
        if not ok then fail(err) end
    end, "faint")
    r.remove:SetPoint("RIGHT", -5, 0)
    -- an empty slot is an empty gold socket, like a bare gear slot
    r.emptyIcon = UI:FramedIcon(r, 26, "plus")
    r.emptyIcon:SetPoint("LEFT", 4, 0)
    r.emptyIcon:SetAlpha(0.6)
    r.emptyIcon.icon:ClearAllPoints()
    r.emptyIcon.icon:SetPoint("CENTER")
    r.emptyIcon.icon:SetSize(11, 11)
    r.emptyIcon.icon:SetVertexColor(C.bronze[1], C.bronze[2], C.bronze[3], 1)
    r.emptyIcon.well:ClearAllPoints()
    r.emptyIcon.well:SetPoint("TOPLEFT", 2, -2)
    r.emptyIcon.well:SetPoint("BOTTOMRIGHT", -2, 2)
    r.emptyText = UI:Text(r, 12, "faint")
    r.emptyText:SetPoint("LEFT", r.emptyIcon, "RIGHT", 8, 0)
    return r
end

local function buildMine(cols)
    local card = UI:Card(cols, { title = "Your reserves", icon = "star" })
    card:SetPoint("TOPLEFT")
    card:SetWidth(LEFT_W)
    card:SetHeight(120)
    card.count = UI:Pill(card.right, "", "green", { height = 18, size = 10 })
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
                r.emptyIcon:Hide(); r.emptyText:Hide()
                r.remove:SetShown(editable)
                r.bg:SetColorTexture(0.035, 0.045, 0.04, 0.85)
                r.rim:SetAlpha(1)
                if before and not before[id] then UI:Shine(r, 0.8) end
            else
                r.subText = nil
                r.item:Hide(); r.name:Hide(); r.sub:Hide(); r.remove:Hide()
                r.emptyIcon:Show(); r.emptyText:Show()
                r.emptyText:SetText(editable and "Empty slot. Pick something below." or "Empty slot. Locked, sorry.")
                r.bg:SetColorTexture(0, 0, 0, 0.28)
                r.rim:SetAlpha(0.45)
            end
            r:Show()
        else
            r.itemID, r.subText = nil, nil
            r:Hide()
        end
    end
    card:SetHeight(38 + limit * (h + gap) + 6)
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
    row.btn = dressItem(UI:ItemButton(row, 24))
    row.btn:SetPoint("LEFT", 4, 0)
    -- the icon eats the row's click; make it do the same thing (shift-click still links)
    row.btn.onClick = function()
        if row.item and not API.IsShiftKeyDown() then toggleReserve(row.item.itemID) end
    end
    row.name = UI:Text(row, 12, "text")
    row.name:SetPoint("LEFT", row.btn, "RIGHT", 8, 6)
    row.name:SetPoint("RIGHT", row, "RIGHT", -64, 6)
    row.sub = UI:Text(row, 10, "faint")
    row.sub:SetPoint("LEFT", row.btn, "RIGHT", 8, -7)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -64, -7)
    row.mark = UI:Icon(row, 14, "plus", "OVERLAY", "dim")
    row.mark:SetPoint("RIGHT", -10, 0)
    row.count = UI:Pill(row, "", "yellow", { height = 16, size = 10 })
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

--- Tall list: icon + text centred in it. Short list (high limits, small window): text
-- only, from the top, so it stays inside the card.
local function layoutCatalogEmpty()
    local card = page and page.add
    if not card or not card.empty then return end
    local e = card.empty
    local short = (card.list:GetHeight() or 0) < 150
    e:ClearAllPoints()
    e.text:ClearAllPoints()
    if short then
        e.icon:Hide()
        e:SetPoint("TOP", card.list, "TOP", 0, -8)
        e.text:SetPoint("TOP", e, "TOP", 0, 0)
    else
        e.icon:Show()
        e:SetPoint("CENTER", card.list, "CENTER", 0, 0)
        e.text:SetPoint("TOP", e.icon, "BOTTOM", 0, -12)
    end
    local lines = CATALOG_EMPTY[card.emptyKind or "none"] or CATALOG_EMPTY.none
    e:SetText(short and lines[2] or lines[1])
end

local function buildAdd(cols)
    local card = UI:Card(cols, { title = "Add a reserve", icon = "plus" })
    card:SetPoint("TOPLEFT", page.mine, "BOTTOMLEFT", 0, -16)
    card:SetPoint("BOTTOMLEFT", cols, "BOTTOMLEFT", 0, 0)
    card:SetWidth(LEFT_W)
    local body = card.body
    card.input = UI:Input(body, { placeholder = "Shift-click an item, or paste a link / ID",
        onEnter = function(text, box) addFrom(text, box) end })
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
    card.list = UI:List(body, {
        rowHeight = 30,
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
    card.list:SetPoint("BOTTOMRIGHT", 0, 0)
    -- parented to the body, not the list: the list clips its children, and at high
    -- reserve limits it is shorter than the empty state
    card.empty = UI:Empty(body, "", "bag")
    card.empty:SetWidth(LEFT_W - 40)
    card.empty.text:SetWidth(LEFT_W - 50)
    card.list:HookScript("OnSizeChanged", function() layoutCatalogEmpty() end)
    card:HookScript("OnSizeChanged", function()
        GF:Debounce("srui-addsize", 0.1, function() if page.refreshCatalog then page.refreshCatalog() end end)
    end)
    card.lock = UI:Empty(body, "SR's locked. Your picks are set in stone. Well, in a SavedVariable.", "lock")
    card.lock:SetWidth(LEFT_W - 40)
    card.lock.text:SetWidth(LEFT_W - 50)
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
    row.btn = dressItem(UI:ItemButton(row, 28))
    row.btn:SetPoint("LEFT", 4, 0)
    row.name = UI:Text(row, 12, "text")
    row.name:SetPoint("TOPLEFT", row.btn, "TOPRIGHT", 10, -1)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -130, -5)
    row.who = UI:Text(row, 11, "dim")
    row.who:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
    row.who:SetPoint("TOPRIGHT", row.name, "BOTTOMRIGHT", 0, -4)
    row.count = UI:Text(row, 18, "dim", "num")
    row.count:SetPoint("RIGHT", -12, 0)
    row.pill = UI:Pill(row, "CONTESTED", "yellow", { height = 18, size = 10, icon = "warning" })
    row.pill:SetPoint("RIGHT", row.count, "LEFT", -8, 0)
end

local function itemRowUpdate(row, e)
    row.btn:SetItem(e.itemID)
    row.name:SetText(coloredName(e.itemID))
    row.who:SetText(whoText(e.list, 4))
    row.count:SetText(#e.list)
    local contested = #e.list >= 2
    row.pill:SetShown(contested)
    UI:SetTextColor(row.count, contested and "yellow" or "dim")
end

local function itemRowEnter(row, e)
    local lines = { T:Wrap("faint", dropText(e.itemID)) }
    for _, r in ipairs(e.list) do
        lines[#lines + 1] = { U.ClassName(r.player, r.class), (r.plus or 0) > 0 and T:Wrap("green", "+" .. r.plus) or " " }
    end
    UI:Tip(row, coloredName(e.itemID), lines)
end

local function playerRowCreate(row)
    row.avatar = UI:Avatar(row, 26)
    row.avatar:SetPoint("LEFT", 6, 0)
    row.name = UI:Text(row, 13, "text", "head")
    row.name:SetPoint("TOPLEFT", row.avatar, "TOPRIGHT", 10, -1)
    row.sub = UI:Text(row, 10, "faint")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.sub:SetPoint("TOPRIGHT", row.name, "BOTTOMRIGHT", 0, -3)
    row.icons = {}
    for i = 1, SR.MAX_LIMIT do
        local b = dressItem(UI:ItemButton(row, 24))
        b:SetPoint("RIGHT", row, "RIGHT", -8 - (i - 1) * 28, 0)
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
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -16 - min(n, #row.icons) * 28, -6)
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
    card.total = UI:Text(card.right, 11, "faint", "head")
    card.total:SetPoint("RIGHT", -4, 0)
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
        rowHeight = 36, createRow = itemRowCreate, updateRow = itemRowUpdate, onEnter = itemRowEnter,
        isSelected = function(e) return e.mine end,
    })
    card.byPlayer = UI:List(body, {
        rowHeight = 36, createRow = playerRowCreate, updateRow = playerRowUpdate, onClick = playerRowClick,
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
        l:SetPoint("BOTTOMRIGHT", 0, 0)
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
    card.total:SetText(idx and (idx.players .. " " .. U.Plural(idx.players, "RAIDER", "RAIDERS") .. DOT .. idx.count .. " " .. U.Plural(idx.count, "RESERVE", "RESERVES")) or "")
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
local function label(parent, text, x, y)
    local l = UI:Text(parent, 10, "bronze", "head")
    l:SetPoint("TOPLEFT", x, y)
    l:SetText(text:upper())
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

local function buildNone()
    local none = CreateFrame("Frame", nil, page)
    none:SetPoint("TOPLEFT", page.banner, "BOTTOMLEFT", 0, -16)
    none:SetPoint("BOTTOMRIGHT")
    page.none = none

    local form = UI:Card(none, { title = "Start a soft-res session", icon = "dice" })
    form:SetPoint("TOPLEFT")
    form:SetSize(420, 318)
    local body = form.body
    label(body, "Title", 0, 0)
    form.titleBox = UI:Input(body, { placeholder = "e.g. Onyxia Wednesday SR", max = 48,
        onChange = function() form.autoTitle = false end })
    form.titleBox:SetPoint("TOPLEFT", 0, -16)
    form.titleBox:SetPoint("TOPRIGHT", 0, -16)
    label(body, "Raid", 0, -56)
    form.instDrop = UI:Dropdown(body, {
        width = 200, items = function() return instanceItems("Not sure yet", form.instance) end,
        get = function() return form.instance or "" end,
        set = function(v) form.instance = v ~= "" and v or nil end,
    })
    form.instDrop:SetPoint("TOPLEFT", 0, -72)
    label(body, "Reserves each", 216, -56)
    form.limitDrop = UI:Dropdown(body, {
        width = 90,
        items = function()
            local out = {}
            for i = 1, SR.MAX_LIMIT do out[i] = { value = i, text = tostring(i) } end
            return out
        end,
        get = function() return form.limit or GF.Roster:Config().srLimit end,
        set = function(v) form.limit = v end,
    })
    form.limitDrop:SetPoint("TOPLEFT", 216, -72)
    label(body, "Linked raid night", 0, -112)
    form.eventDrop = UI:Dropdown(body, {
        width = 396, items = eventItems,
        get = function() return form.eventId or "" end,
        set = function(v, item)
            form.eventId = v ~= "" and v or nil
            if item and item.ev then applyEvent(form, item.ev) end
        end,
        placeholder = "None",
    })
    form.eventDrop:SetPoint("TOPLEFT", 0, -128)
    form.eventDrop:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -128)
    form.plus = UI:Toggle(body, "Plus mode", {
        get = function() return form.plusOn and true or false end,
        set = function(v) form.plusOn = v end,
        tooltip = { "Plus mode", { "+1 for every earlier session a raider reserved the same item and missed out. Higher plus wins ties." } },
    })
    form.plus:SetPoint("TOPLEFT", 0, -172)
    form.start = UI:Button(body, "Open the SR", { style = "primary", icon = "dice", height = 30, onClick = function()
        local ok, err = SR:Start({ title = form.titleBox:GetText(), instance = form.instance, eventId = form.eventId,
            limit = form.limit, plus = form.plusOn })
        if not ok then return fail(err) end
        form.prefilled = false
        UI:Toast({ title = "SR's open", text = "Hit Announce so the raid knows. Lock it when you're ready.", icon = "dice", style = "green" })
    end })
    form.start:SetPoint("TOPLEFT", 0, -214)
    form.hint = UI:Text(body, 11, "faint")
    form.hint:SetPoint("TOPLEFT", form.start, "BOTTOMLEFT", 0, -10)
    form.hint:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -254)
    form.hint:SetWordWrap(true)
    form.hint:SetText("You'll be the host. Starting a new one closes any SR you left open.")
    page.form = form

    local how = UI:Card(none, { title = "How it works", icon = "clipboard" })
    how:SetPoint("TOPLEFT", form, "TOPRIGHT", 16, 0)
    how:SetPoint("TOPRIGHT", none, "TOPRIGHT", 0, 0)
    how:SetHeight(318)
    for i, text in ipairs(HOW_STEPS) do
        local y = -(i - 1) * 58
        -- step numbers sit in gold slots, like ranks on a talent
        local disc = UI:FramedIcon(how.body, 28)
        disc:SetPoint("TOPLEFT", 0, y + 1)
        local num = UI:Text(disc, 14, "wowGold", "ui")
        num:SetPoint("CENTER", disc, "CENTER", 1, 0)
        num:SetJustifyH("CENTER")
        num:SetText(i)
        local t = UI:Text(how.body, 12, "dim")
        t:SetPoint("TOPLEFT", disc, "TOPRIGHT", 12, -4)
        t:SetPoint("TOPRIGHT", how.body, "TOPRIGHT", 0, y - 4)
        t:SetWordWrap(true)
        t:SetJustifyV("TOP")
        t:SetText(text)
    end
    page.how = how

    page.quiet = UI:Empty(none, "No SR running. Pester your raid leader, or bribe them with a Bunnings snag.", "dice")
    page.quiet:ClearAllPoints()
    page.quiet:SetPoint("CENTER", 0, 30)
end

local function refreshNone()
    local canHost = SR:CanHost()
    page.form:SetShown(canHost)
    page.how:SetShown(canHost)
    page.quiet:SetShown(not canHost)
    if not canHost then return end
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
        page.btnLock:SetStyle(s.locked and "secondary" or "warn")
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
    buildNone()
    page.refreshCatalog = refreshCatalog
    page.refreshList = refreshList
end

UI:RegisterPage({
    key = "softres", title = "Soft Res", subtitle = "Call dibs before the bin chickens do.",
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
