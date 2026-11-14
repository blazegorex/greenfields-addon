--[[ Greenfields - Modules/NemesisUI.lua
     Most Wanted, the page: every enemy who's done a guildie over, on a parchment poster with their
     mugshot and the price on their head. Plus the two moments that make it: the poster that drops
     when you've been done over, and the stamp that slams down when you collect.

     The data is Modules/Nemesis.lua (GF.Nemesis); the mugshots and poster art are
     Data/WantedArt.lua (tools/wanted_art.py).

       /gf wanted            open the page
       /gf wanted test       the poster you'd get for being done over (nothing's recorded)
       /gf wanted collect    the stamp you'd get for collecting (nothing's recorded)
       /gf wanted pack       the poster you'd get for being jumped by a pack (nothing's recorded)
       /gf wanted snooze [m] no posters or sightings for m minutes (60 if you don't say)
       /gf wanted wake       back on ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c
local N = GF.Nemesis
local INK = UI.INK
local floor, max, min = math.floor, math.max, math.min

local PAGE = "wanted"
local RATIO = 1.72          -- a poster's height for its width
local GUTTER = 16
local POSTER_MIN, POSTER_MAX = 150, 196
local HERO_W = 220
local SIDE_W = 244
local SKURRI = "Fonts\\SKURRI.TTF"
local SOUND_DEATH, SOUND_STAMP = 847, 888   -- quest failed; level up
local MATE = 44             -- a pack member's mugshot on the "done over" popup

local function art() return GF.WantedArt or {} end
local function settings() return GF.db and GF.db.settings or {} end

-------------------------------------------------------------------------------
-- Ink on paper
-------------------------------------------------------------------------------
local function ink(parent, size, colour, kind, layer)
    local fs = UI:Text(parent, size, INK[colour] or INK.dark, kind or "ui", nil, layer or "ARTWORK")
    fs:SetShadowOffset(0, 0)
    fs:SetJustifyH("CENTER")
    return fs
end

--- The game's chunky old damage-number face; the narrow face if the client won't load it.
local function chunky(fs, size)
    local ok, r = pcall(fs.SetFont, fs, SKURRI, size, "")
    if not ok or r == false then T:Font(fs, "num", size) end
end

local function sizeFont(fs, kind, size)
    if kind == "skurri" then chunky(fs, size) else T:Font(fs, kind, size) end
    fs:SetShadowOffset(0, 0)   -- ink on paper: T:Font puts a shadow back on
end

local function nameOf(key)
    local R = GF.Roster
    if R and R.Colored then
        local ok, s = pcall(R.Colored, R, key)
        if ok and type(s) == "string" then return s end
    end
    return tostring(key)
end

local function plainName(key) return U.StripCodes(nameOf(key)) end

-------------------------------------------------------------------------------
-- The poster
-------------------------------------------------------------------------------
local function setMug(tex, p)
    local path, l, r, t, b = N:Mug(p)
    if path then
        tex:SetTexture(path)
        tex:SetTexCoord(l, r, t, b)
    else
        tex:SetColorTexture(0.2, 0.17, 0.13, 1)
    end
end

local function rapLine(p)
    local n = p.open and #p.open or 0
    if p.status ~= "wanted" then
        return ("Priors: %d."):format(p.priors or 0)
    end
    local s = n == 1 and "Done over 1 of us." or ("Done over %d of us"):format(n)
    if n > 1 then s = s .. (p.spread > 1 and (", %d different."):format(p.spread) or ".") end
    if (p.dogs or 0) > 0 then
        s = s .. (p.dogs == 1 and " A dog act." or (" %d dog acts."):format(p.dogs))
    elseif (p.pack or 0) > 0 then
        s = s .. " Runs in a pack."
    end
    return s
end

local function seenLine(p)
    local s = N:LastSeen(p)
    if not s or not s.t then return "" end
    local where = s.z and (s.z .. ", ") or ""
    return "Last seen: " .. where .. U.Ago(s.t)
end

local function layoutPoster(f, w)
    w = floor(w)
    local h = floor(w * RATIO)
    f:SetSize(w, h)
    local pad = max(8, floor(w * 0.07))
    local inner = w - pad * 2
    local pin = max(10, floor(w * 0.07))
    f.pins[1]:SetSize(pin, pin)
    f.pins[1]:ClearAllPoints()
    f.pins[1]:SetPoint("CENTER", f, "TOPLEFT", pad * 0.7, -pad * 0.6)
    f.pins[2]:SetSize(pin, pin)
    f.pins[2]:ClearAllPoints()
    f.pins[2]:SetPoint("CENTER", f, "TOPRIGHT", -pad * 0.7, -pad * 0.6)
    local headH = floor(inner / 4)
    f.head:SetSize(inner, headH)
    f.head:ClearAllPoints()
    f.head:SetPoint("TOP", 0, -floor(pad * 0.55))
    sizeFont(f.sub, "head", max(7, floor(w * 0.052)))
    f.sub:SetWidth(inner)
    f.sub:ClearAllPoints()
    f.sub:SetPoint("TOP", f.head, "BOTTOM", 0, 1)
    local ps = floor(w * 0.62)
    f.edge:SetSize(ps + 4, ps + 4)
    f.edge:ClearAllPoints()
    f.edge:SetPoint("TOP", f.sub, "BOTTOM", 0, -4)
    f.photo:ClearAllPoints()
    f.photo:SetPoint("TOPLEFT", f.edge, "TOPLEFT", 2, -2)
    f.photo:SetPoint("BOTTOMRIGHT", f.edge, "BOTTOMRIGHT", -2, 2)
    sizeFont(f.name, "title", max(12, floor(w * 0.1)))
    f.name:SetWidth(inner)
    f.name:ClearAllPoints()
    f.name:SetPoint("TOP", f.edge, "BOTTOM", 0, -5)
    sizeFont(f.what, "body", max(8, floor(w * 0.058)))
    f.what:SetWidth(inner)
    f.what:ClearAllPoints()
    f.what:SetPoint("TOP", f.name, "BOTTOM", 0, -2)
    f.rule:SetSize(floor(inner * 0.8), 1)
    f.rule:ClearAllPoints()
    f.rule:SetPoint("TOP", f.what, "BOTTOM", 0, -5)
    sizeFont(f.reward, "head", max(7, floor(w * 0.05)))
    f.reward:ClearAllPoints()
    f.reward:SetPoint("TOP", f.rule, "BOTTOM", 0, -4)
    sizeFont(f.points, "skurri", max(15, floor(w * 0.13)))
    f.points:SetWidth(inner)
    f.points:ClearAllPoints()
    f.points:SetPoint("TOP", f.reward, "BOTTOM", 0, -1)
    sizeFont(f.rap, "body", max(8, floor(w * 0.056)))
    f.rap:SetWidth(inner)
    f.rap:ClearAllPoints()
    f.rap:SetPoint("TOP", f.points, "BOTTOM", 0, -3)
    sizeFont(f.seen, "body", max(7, floor(w * 0.05)))
    f.seen:SetWidth(inner)
    f.seen:ClearAllPoints()
    f.seen:SetPoint("BOTTOM", 0, floor(pad * 0.6))
    -- the stamp lands across the mugshot, clear of the name under it
    f.stampBox:SetSize(floor(w * 0.98), floor(w * 0.49))
    f.stampBox:ClearAllPoints()
    f.stampBox:SetPoint("CENTER", f.edge, "CENTER", 0, -floor(w * 0.1))
    f.w = w
end

--- Poster(parent) -> poster with :SetEntry(entry, mode) and :SetWidth-like :Fit(w).
-- mode: nil (as the board has it), "fresh" (the price before you collected it)
local function makePoster(parent)
    local f = CreateFrame("Button", nil, parent)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    UI:Shadow(f, 7)
    UI:Parchment(f, 1)
    -- a tired warm wash, so a wall of them doesn't glare
    f.age = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    f.age:SetPoint("TOPLEFT", 1, -1)
    f.age:SetPoint("BOTTOMRIGHT", -1, 1)
    UI:Gradient(f.age, "VERTICAL", 0.35, 0.22, 0.08, 0.20, 0.02)
    local A = art()
    f.pins = {}
    for i = 1, 2 do
        local p = f:CreateTexture(nil, "OVERLAY", nil, 6)
        if A.pin then p:SetTexture(A.pin) end
        f.pins[i] = p
    end
    f.head = f:CreateTexture(nil, "ARTWORK")
    if A.head then f.head:SetTexture(A.head) end
    f.sub = ink(f, 8, "dim", "head")
    f.sub:SetText("FOR CRIMES AGAINST GREENFIELDS")
    f.edge = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.edge:SetColorTexture(INK.dark[1], INK.dark[2], INK.dark[3], 1)
    f.photo = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.name = ink(f, 16, "dark", "title")
    f.name:SetWordWrap(false)
    f.what = ink(f, 10, "dim", "body")
    f.what:SetWordWrap(false)
    f.rule = f:CreateTexture(nil, "ARTWORK")
    f.rule:SetColorTexture(INK.dim[1], INK.dim[2], INK.dim[3], 0.55)
    f.reward = ink(f, 8, "dim", "head")
    f.points = ink(f, 20, "red", "num")
    f.rap = ink(f, 9, "dark", "body")
    f.rap:SetWordWrap(true)
    if f.rap.SetMaxLines then f.rap:SetMaxLines(2) end
    f.seen = ink(f, 8, "dim", "body")
    f.seen:SetWordWrap(false)
    f.stampBox = CreateFrame("Frame", nil, f)
    f.stampBox:SetFrameLevel(f:GetFrameLevel() + 4)
    f.stamp = f.stampBox:CreateTexture(nil, "OVERLAY")
    f.stamp:SetAllPoints()
    f.stampBox:Hide()
    f.hl = f:CreateTexture(nil, "OVERLAY", nil, 7)
    f.hl:SetAllPoints()
    f.hl:SetColorTexture(1, 0.86, 0.5, 0.07)
    f.hl:SetBlendMode("ADD")
    f.hl:Hide()
    f:SetScript("OnEnter", function(self)
        UI:Ease(self.hl, 1, 0.12)
        if self.onEnter then GF:Safe("wanted:poster-enter", self.onEnter, self) end
    end)
    f:SetScript("OnLeave", function(self)
        UI:Ease(self.hl, 0, 0.2, true)
        UI:HideTip()
    end)

    function f:Fit(w) layoutPoster(self, w) end

    function f:SetEntry(p, mode)
        self.entry = p
        if not p then return end
        setMug(self.photo, p)
        self.name:SetText(p.name or "?")
        self.what:SetText(N:Describe(p))
        local dealt = p.status ~= "wanted" and mode ~= "fresh"
        -- an old poster: the mugshot's faded, and it's stamped
        self.photo:SetDesaturated(dealt)
        self.photo:SetVertexColor(1, dealt and 0.93 or 1, dealt and 0.82 or 1, 1)
        self.stampBox:SetShown(dealt and p.lastClaim ~= nil)
        if dealt and p.lastClaim then
            local A = art()
            self.stamp:SetTexture(p.lastClaim.revenge and A.square or A.dealt)
            self.reward:SetText("PAID IN FULL")
            self.points:SetText(N:PointsText(p.lastClaim.points + (p.lastClaim.revenge and 1 or 0)):upper())
            self.rap:SetText(("Collected by %s, %s."):format(plainName(p.lastClaim.by), U.Ago(p.lastClaim.t)))
        else
            self.reward:SetText("REWARD")
            self.points:SetText(N:PointsText(p.bounty or 0):upper())
            self.rap:SetText(rapLine(p))
        end
        self.seen:SetText(seenLine(p))
    end
    return f
end
N.MakePoster = makePoster

--- The rap sheet behind a poster, for its tooltip.
local function posterTip(f)
    local p = f.entry
    if not p then return end
    GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
    GameTooltip:AddLine(p.name, 1, 0.36, 0.28)
    GameTooltip:AddLine(N:Describe(p), 0.85, 0.8, 0.7)
    if p.status == "wanted" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Bounty", N:PointsText(p.bounty), 0.8, 0.85, 0.82, 1, 0.82, 0)
        local list = {}
        local seenV = {}
        for _, d in ipairs(p.open or {}) do
            if not seenV[d.v] then
                seenV[d.v] = 0
                list[#list + 1] = d.v
            end
            seenV[d.v] = seenV[d.v] + 1
        end
        local parts = {}
        for _, v in ipairs(list) do
            parts[#parts + 1] = nameOf(v) .. (seenV[v] > 1 and (" x" .. seenV[v]) or "")
        end
        GameTooltip:AddLine("Done over: " .. table.concat(parts, ", "), 0.75, 0.82, 0.78, true)
        if (p.pack or 0) > 0 then
            GameTooltip:AddLine(("%d of those with a pack, as one of the mates."):format(p.pack), 0.75, 0.82, 0.78, true)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("1 point a body. +1 for every different guildie, +1 for a dog act (10 or more levels under). Drop them and it's yours.", 0.6, 0.62, 0.6, true)
    GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- The page
-------------------------------------------------------------------------------
local page

local function selected()
    local b = N:Board()
    local sel = page and page.sel and b.byName[page.sel]
    if sel and sel.status ~= "cold" then return sel end
    return b.wanted[1] or b.dealt[1]
end

local function posterMenu(f)
    local p = f.entry
    if not p then return end
    local me = API.MyKey()
    local items = { { title = true, text = p.name } }
    local mine = {}
    for _, d in ipairs(p.open or {}) do
        if d.v == me then mine[#mine + 1] = d.id end
    end
    if #mine > 0 then
        items[#items + 1] = { text = "Wasn't them (take my report down)", icon = "close", func = function()
            for _, id in ipairs(mine) do N:Retract(id) end
        end }
    end
    if GF.Roster and GF.Roster.IsOfficer and GF.Roster:IsOfficer(me) then
        items[#items + 1] = { text = "Tear the poster down (officer)", icon = "trash", func = function()
            UI:Confirm("Tear it down?", ("The open reports about %s come off the board for everyone. Bounties already paid stay paid."):format(p.name), function()
                N:TearDown(p.name)
            end, "Tear it down", "danger")
        end }
    end
    if #items == 1 then items[#items + 1] = { text = "Nothing to do here", disabled = true } end
    UI:OpenMenu(f, items, { point = "TOP", relPoint = "CENTER" })
end

local function wirePoster(f)
    f.onEnter = posterTip
    f:SetScript("OnClick", function(self, button)
        if button == "RightButton" then return posterMenu(self) end
        if self.entry and page then
            page.sel = self.entry.name
            UI.Sound(856)
            N:RenderPage()
            if page.scroll then page.scroll:SetVerticalScroll(0); page.scroll:UpdateBar() end
        end
    end)
end

local function para(parent, size, colour)
    local fs = UI:Para(parent, size, colour)
    return fs
end

local function buildCase(content)
    local c = UI:Card(content, { title = "Public Enemy No. 1", icon = "skull", tier = "hero" })
    c.name = UI:Text(c.body, 24, "red", "title")
    c.name:SetPoint("TOPLEFT", 0, -2)
    c.name:SetPoint("TOPRIGHT", 0, -2)
    c.what = UI:Text(c.body, 12, "dim")
    c.what:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -4)
    c.what:SetPoint("TOPRIGHT", c.name, "BOTTOMRIGHT", 0, -4)
    c.tiles = {}
    local tiles = {
        { icon = "coin", label = "Bounty", tip = "1 point a body, +1 for every different guildie, +1 for a dog act (10 or more levels under). Drop them and it's yours." },
        { icon = "skull", label = "Bodies" },
        { icon = "roster", label = "Locals done" },
        { icon = "warning", label = "Dog acts", tip = "Kills on a guildie 10 or more levels under them." },
    }
    for i, t in ipairs(tiles) do
        c.tiles[i] = UI:StatTile(c.body, { icon = t.icon, label = t.label, tooltip = t.tip })
        c.tiles[i]:SetHeight(46)
    end
    c.text = para(c.body, 12, "text")
    c.foot = para(c.body, 11, "faint")
    return c
end

local function fillCase(c, p, top)
    if top then
        c:SetTitle(p.status == "wanted" and "Public Enemy No. 1" or "Last dealt with")
    else
        c:SetTitle("Case file")
    end
    c.name:SetText(p.name)
    c.what:SetText(N:Describe(p))
    local wanted = p.status == "wanted"
    if wanted then
        c.tiles[1]:Set(N:PointsText(p.bounty), "Bounty", "wowGold")
        c.tiles[2]:Set(#p.open, "Bodies on it")
        c.tiles[3]:Set(p.spread, "Locals done")
        c.tiles[4]:Set(p.dogs, "Dog acts")
    else
        local last = p.lastClaim
        c.tiles[1]:Set("Paid", "Bounty", "green")
        c.tiles[2]:Set(p.priors or 0, "Priors")
        c.tiles[3]:Set(#(p.history or {}), "Times sorted")
        c.tiles[4]:Set(last and N:PointsText(last.points) or "-", "Last paid", "wowGold")
    end
    local lines = {}
    -- who they've done, everyone they've ever done, class coloured
    local list, count = {}, {}
    for v, n in pairs(p.victims or {}) do
        list[#list + 1] = v
        count[v] = n
    end
    table.sort(list, function(a, b) if count[a] ~= count[b] then return count[a] > count[b] end return a < b end)
    local parts = {}
    for i, v in ipairs(list) do
        if i > 8 then parts[#parts + 1] = ("and %d more"):format(#list - 8) break end
        parts[#parts + 1] = nameOf(v) .. (count[v] > 1 and ("|cff8a8f8a x" .. count[v] .. "|r") or "")
    end
    lines[#lines + 1] = "|cffc19c65Done over:|r " .. (#parts > 0 and table.concat(parts, ", ") or "nobody yet")
    lines[#lines + 1] = ("|cffc19c65Priors:|r %d, all time."):format(p.priors or 0)
    if wanted and (p.pack or 0) > 0 then
        lines[#lines + 1] = ("|cffc19c65Runs in a pack:|r %d of those bodies %s a gang job, as one of the mates."):format(
            p.pack, p.pack == 1 and "was" or "were")
    end
    local s = N:LastSeen(p)
    if s and s.t then
        local by = s.by and (" (" .. nameOf(s.by) .. ")") or ""
        lines[#lines + 1] = "|cffc19c65Last seen:|r " .. (s.z and (s.z .. ", ") or "") .. U.Ago(s.t) .. by
    end
    lines[#lines + 1] = "|cffc19c65Known associates:|r " .. (p.guild and ("<" .. p.guild .. ">") or "no fixed address")
    local hist = p.history or {}
    if #hist > 0 then
        local h = hist[#hist]
        local helpers = ""
        if h.helpers and #h.helpers > 0 then
            local hp = {}
            for _, k in ipairs(h.helpers) do hp[#hp + 1] = nameOf(k) end
            helpers = ", with " .. table.concat(hp, ", ")
        end
        lines[#lines + 1] = ("|cffc19c65Dealt with:|r %s. Last by %s for %s%s%s, %s."):format(
            #hist == 1 and "once" or (#hist .. " times"), nameOf(h.by), N:PointsText(h.points),
            h.revenge and " (revenge)" or "", helpers, U.Ago(h.t))
    end
    c.text:SetText(table.concat(lines, "\n"))
    c.foot:SetText(wanted and "Right-click a poster if it wasn't them. Drop them and the points are yours; the rest of the street gets told."
        or "Paid in full. If they do anyone again, the poster goes straight back up.")
end

local function layoutCase(c, w, h)
    c:SetSize(w, h)
    local bw = w - 24
    local cols = bw >= 380 and 4 or 2
    local tw = floor((bw - (cols - 1) * 8) / cols)
    local y = 54
    for i, t in ipairs(c.tiles) do
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", c.body, "TOPLEFT", col * (tw + 8), -(y + row * 54))
        t:SetWidth(tw)
    end
    local rows = cols == 4 and 1 or 2
    local textY = y + rows * 54 + 6
    c.text:ClearAllPoints()
    c.text:SetPoint("TOPLEFT", c.body, "TOPLEFT", 0, -textY)
    c.text:SetWidth(bw)
    c.foot:ClearAllPoints()
    c.foot:SetPoint("BOTTOMLEFT", c.body, "BOTTOMLEFT", 0, 0)
    c.foot:SetWidth(bw)
    -- grow past the poster beside it rather than run the rap sheet into the footnote
    local need = 38 + textY + (c.text:GetStringHeight() or 0) + 12 + (c.foot:GetStringHeight() or 0) + 12
    h = max(h, floor(need + 0.5))
    c:SetHeight(h)
    return h
end

local function buildNemesisCard(content)
    local c = UI:Card(content, { title = "Your nemesis", icon = "eye" })
    c.mug = c.body:CreateTexture(nil, "ARTWORK", nil, 2)
    c.mug:SetSize(52, 52)
    c.mug:SetPoint("TOPLEFT", 0, -2)
    c.mugEdge = c.body:CreateTexture(nil, "ARTWORK", nil, 1)
    c.mugEdge:SetPoint("TOPLEFT", c.mug, "TOPLEFT", -1, 1)
    c.mugEdge:SetPoint("BOTTOMRIGHT", c.mug, "BOTTOMRIGHT", 1, -1)
    c.mugEdge:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.6)
    c.name = UI:Text(c.body, 14, "red", "ui")
    c.name:SetPoint("TOPLEFT", c.mug, "TOPRIGHT", 10, -2)
    c.name:SetPoint("RIGHT", c.body, "RIGHT", 0, 0)
    c.text = UI:Para(c.body, 11, "dim")
    c.text:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -4)
    c.text:SetPoint("RIGHT", c.body, "RIGHT", 0, 0)
    c.none = UI:Para(c.body, 12, "dim")
    c.none:SetPoint("TOPLEFT", 0, -4)
    c.none:SetPoint("RIGHT", c.body, "RIGHT", 0, 0)
    c.none:SetText("Nobody's got your number yet. Keep your head down and your hood up.")
    c.hit = CreateFrame("Button", nil, c.body)
    c.hit:SetAllPoints(c.body)
    c.hit:SetScript("OnClick", function()
        if c.entry and page then
            page.sel = c.entry.name
            N:RenderPage()
        end
    end)
    return c
end

local function fillNemesisCard(c)
    local p, n = N:NemesisOf(API.MyKey())
    c.entry = p
    local has = p ~= nil and n > 0
    c.mug:SetShown(has)
    c.mugEdge:SetShown(has)
    c.name:SetShown(has)
    c.text:SetShown(has)
    c.none:SetShown(not has)
    c.hit:SetShown(has)
    if not has then return end
    setMug(c.mug, p)
    c.name:SetText(p.name)
    local status = p.status == "wanted" and ("Wanted, %s."):format(N:PointsText(p.bounty))
        or (p.lastClaim and ("Last sorted out by %s."):format(nameOf(p.lastClaim.by)) or "Gone quiet.")
    c.text:SetText(("Has done you %s. %s"):format(n == 1 and "once" or (n .. " times"), status))
end

local WHY, ask   -- the question, below: the waiting list reopens it
local REPORT_ROWS, REPORT_H = 5, 42

--- Deaths you haven't answered yet: put them up, or call it a fair fight.
local function buildReports(content)
    local c = UI:Card(content, { title = "Waiting on you", icon = "bell", subtitle = "Done over and not answered yet" })
    c.rows = {}
    for i = 1, REPORT_ROWS do
        local r = CreateFrame("Button", nil, c.body)
        r:SetHeight(REPORT_H - 4)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * REPORT_H)
        r:SetPoint("TOPRIGHT", 0, -(i - 1) * REPORT_H)
        r.edge = r:CreateTexture(nil, "ARTWORK", nil, 1)
        r.edge:SetSize(36, 36)
        r.edge:SetPoint("LEFT", 0, 0)
        r.edge:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.6)
        r.mug = r:CreateTexture(nil, "ARTWORK", nil, 2)
        r.mug:SetPoint("TOPLEFT", r.edge, "TOPLEFT", 1, -1)
        r.mug:SetPoint("BOTTOMRIGHT", r.edge, "BOTTOMRIGHT", -1, 1)
        r.no = UI:Button(r, "Fair fight", { style = "secondary", height = 22, onClick = function()
            if r.rep then N:Drop(r.rep.id) end
        end })
        r.no:SetPoint("RIGHT", 0, 0)
        r.yes = UI:Button(r, "Put them up", { style = "primary", height = 22, onClick = function()
            if r.rep then N:File(r.rep.id) end
        end })
        r.yes:SetPoint("RIGHT", r.no, "LEFT", -6, 0)
        -- top corners only: a RIGHT point on the buttons would centre both lines on them
        r.text = UI:Text(r, 12, "text")
        r.text:SetPoint("TOPLEFT", r.edge, "TOPRIGHT", 10, -2)
        r.text:SetPoint("TOPRIGHT", r, "TOPRIGHT", -200, -2)
        r.sub = UI:Text(r, 11, "dim")
        r.sub:SetPoint("TOPLEFT", r.text, "BOTTOMLEFT", 0, -4)
        r.sub:SetPoint("TOPRIGHT", r.text, "BOTTOMRIGHT", 0, -4)
        r:SetScript("OnClick", function() if r.rep then ask(r.rep) end end)
        UI.AttachTip(r, "Click to see the poster and pick who goes up.")
        c.rows[i] = r
    end
    return c
end

local function fillReports(c)
    local list = N:Reports()
    local n = 0
    for i = #list, 1, -1 do             -- newest first
        if n >= REPORT_ROWS then break end
        n = n + 1
        local rep, r = list[i], c.rows[n]
        r.rep = rep
        setMug(r.mug, rep.killer)
        r.text:SetText(("|cffe8473c%s|r %s"):format(rep.killer.name, WHY[rep.why or ""] or "did you over"))
        local bits = { N:Describe(rep.killer) }
        local mates = rep.crew and #rep.crew or 0
        if mates > 0 then bits[#bits + 1] = ("and %d %s"):format(mates, U.Plural(mates, "mate")) end
        bits[#bits + 1] = U.Ago(rep.t) .. (rep.zone and (" in " .. rep.zone) or "")
        r.sub:SetText(table.concat(bits, "  -  "))
        r:Show()
    end
    for i = n + 1, REPORT_ROWS do c.rows[i]:Hide() end
    return n
end

--- The header's Snooze: how long, or wake up.
local function snoozeMenu(btn)
    local left = N:Snoozed()
    UI:OpenMenu(btn, {
        { title = true, text = left and ("Snoozed, %s left"):format(U.Duration(left)) or "No posters, no sightings for" },
        { text = "30 minutes", icon = "clock", func = function() N:Snooze(1800) end },
        { text = "An hour", icon = "clock", func = function() N:Snooze(3600) end },
        { text = "Two hours", icon = "clock", func = function() N:Snooze(7200) end },
        { text = "Wake up", icon = "bell", disabled = not left, func = function() N:Snooze(0) end },
    }, { point = "TOPRIGHT", relPoint = "BOTTOMRIGHT", width = 200 })
end

local HUNTER_ROWS = 6

local function buildHunters(content)
    local c = UI:Card(content, { title = "Bounty hunters", icon = "coin" })
    c.rows = {}
    for i = 1, HUNTER_ROWS do
        local r = CreateFrame("Frame", nil, c.body)
        r:SetHeight(22)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * 24)
        r:SetPoint("TOPRIGHT", 0, -(i - 1) * 24)
        r.rank = UI:Text(r, 12, "faint", "head")
        r.rank:SetPoint("LEFT", 0, 0)
        r.rank:SetWidth(18)
        r.name = UI:Text(r, 12, "text")
        r.name:SetPoint("LEFT", 20, 0)
        r.pts = UI:Text(r, 12, "wowGold", "head")
        r.pts:SetPoint("RIGHT", 0, 0)
        r.pts:SetJustifyH("RIGHT")
        r.name:SetPoint("RIGHT", r.pts, "LEFT", -6, 0)
        UI.AttachTip(r, function(self)
            local h = self.h
            if not h then return nil end
            return { plainName(h.key), {
                ("%d collected, %d %s"):format(h.claims, h.assists, h.assists == 1 and "hand in one" or "hands in others"),
                h.revenge > 0 and ("Revenge %d %s"):format(h.revenge, h.revenge == 1 and "time" or "times") or "No revenge yet",
                ("Biggest single bounty: %s"):format(N:PointsText(h.best)),
            } }
        end)
        r:EnableMouse(true)
        c.rows[i] = r
    end
    c.none = UI:Para(c.body, 12, "dim")
    c.none:SetPoint("TOPLEFT", 0, -4)
    c.none:SetPoint("RIGHT", c.body, "RIGHT", 0, 0)
    c.none:SetText("Nobody's collected. The points are just sitting there.")
    return c
end

local function fillHunters(c)
    local list = N:Board().hunters
    c.none:SetShown(#list == 0)
    for i, r in ipairs(c.rows) do
        local h = list[i]
        r.h = h
        r:SetShown(h ~= nil)
        if h then
            r.rank:SetText(i .. ".")
            r.name:SetText(nameOf(h.key))
            r.pts:SetText(N:PointsText(h.points))
        end
    end
end

local function build(pg)
    page = pg
    N.page = pg   -- for the harness
    local header = UI:PageHeader(pg, "Most Wanted", "If you see these people, do not call the police.")
    pg.header = header
    pg.snoozeBtn = header:AddAction(UI:Button(pg, "Snooze", { style = "ghost", icon = "clock",
        tooltip = "A break from Most Wanted: your deaths don't ask and wanted faces don't pop a sign. A kill on someone wanted still collects.",
        onClick = function(self) snoozeMenu(self) end }))
    local scroll, content = UI:Scroll(pg, { outside = true })
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -14)
    scroll:SetPoint("BOTTOMRIGHT")
    pg.scroll, pg.content = scroll, content
    pg.hero = makePoster(content)
    wirePoster(pg.hero)
    pg.reports = buildReports(content)
    pg.case = buildCase(content)
    pg.nem = buildNemesisCard(content)
    pg.hunters = buildHunters(content)
    pg.wallLabel = UI:SectionLabel(content, "ON THE POLES")
    pg.dealtLabel = UI:SectionLabel(content, "DEALT WITH")
    pg.posters, pg.dealtPosters = {}, {}
    pg.empty = UI:Empty(content, "Nobody's done anyone over yet. When an Alliance player drops one of us, their mugshot goes up here with a price on their head, and whoever drops them collects.",
        "skull", { heading = "The poles are bare", action = "Show me a poster", actionIcon = "eye",
            onAction = function() N:TestPoster("death") end, width = 420 })
    -- hooked, not set: the empty state above has its own hook on this
    content:HookScript("OnSizeChanged", function(self, w)
        w = floor((w or self:GetWidth() or 0) + 0.5)
        if w == self.gfLastWidth then return end
        self.gfLastWidth = w
        GF:Safe("wanted:layout", N.RenderPage, N)
    end)
end

local function poster(pool, i, content)
    local f = pool[i]
    if not f then
        f = makePoster(content)
        wirePoster(f)
        pool[i] = f
    end
    return f
end

local function grid(pool, list, skip, content, y, w)
    local cols = max(1, floor((w + GUTTER) / (POSTER_MIN + GUTTER)))
    local pw = min(POSTER_MAX, floor((w - (cols - 1) * GUTTER) / cols))
    local ph = floor(pw * RATIO)
    local n = 0
    for _, p in ipairs(list) do
        if p ~= skip then
            n = n + 1
            local f = poster(pool, n, content)
            f:Fit(pw)
            f:SetEntry(p)
            local col, row = (n - 1) % cols, floor((n - 1) / cols)
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", content, "TOPLEFT", col * (pw + GUTTER), -(y + row * (ph + GUTTER)))
            f:Show()
        end
    end
    for i = n + 1, #pool do pool[i]:Hide() end
    if n == 0 then return y, 0 end
    return y + (floor((n - 1) / cols) + 1) * (ph + GUTTER), n
end

function N:RenderPage()
    if not page or not page.content then return end
    local content = page.content
    local w = floor(content:GetWidth() or 0)
    if w < 100 then return end
    local b = N:Board()
    local sel = selected()
    local any = sel ~= nil or #b.hunters > 0
    local left = N:Snoozed()
    page.snoozeBtn:SetText(left and ("Snoozed, " .. U.Duration(left)) or "Snooze")
    -- anything waiting on an answer goes first
    local top = 0
    local waitingN = fillReports(page.reports)
    page.reports:SetShown(waitingN > 0)
    if waitingN > 0 then
        local h = 38 + waitingN * REPORT_H + 4
        page.reports:SetSize(w, h)
        page.reports:ClearAllPoints()
        page.reports:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        top = h + GUTTER
    end
    page.empty:SetShown(not any)
    page.hero:SetShown(sel ~= nil)
    page.case:SetShown(sel ~= nil)
    page.nem:SetShown(any)
    page.hunters:SetShown(any)
    if not any then
        for _, f in ipairs(page.posters) do f:Hide() end
        for _, f in ipairs(page.dealtPosters) do f:Hide() end
        page.wallLabel:Hide()
        page.dealtLabel:Hide()
        page.empty:ClearAllPoints()
        page.empty:SetPoint("TOP", content, "TOP", 0, -(top + 60))
        page.scroll:SetContentHeight(top + 300)
        return
    end
    local side = w >= 720 and SIDE_W or 0
    local heroW = sel and min(HERO_W, floor(w * 0.36)) or 0
    local heroH = floor(heroW * RATIO)
    local y = top
    if sel then
        page.hero:Fit(heroW)
        page.hero:SetEntry(sel)
        page.hero:ClearAllPoints()
        page.hero:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        local caseW = w - heroW - GUTTER - (side > 0 and (side + GUTTER) or 0)
        fillCase(page.case, sel, sel == (b.wanted[1] or b.dealt[1]))
        heroH = layoutCase(page.case, caseW, heroH)
        page.case:ClearAllPoints()
        page.case:SetPoint("TOPLEFT", content, "TOPLEFT", heroW + GUTTER, -y)
    end
    fillNemesisCard(page.nem)
    fillHunters(page.hunters)
    local nemH = 104
    local huntH = 38 + HUNTER_ROWS * 24 + 6
    if side > 0 then
        page.nem:SetSize(side, nemH)
        page.nem:ClearAllPoints()
        page.nem:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
        page.hunters:SetSize(side, max(huntH, (sel and heroH or 0) - nemH - GUTTER))
        page.hunters:ClearAllPoints()
        page.hunters:SetPoint("TOPRIGHT", page.nem, "BOTTOMRIGHT", 0, -GUTTER)
        y = y + max(sel and heroH or 0, nemH + GUTTER + page.hunters:GetHeight()) + GUTTER + 6
    else
        y = y + (sel and (heroH + GUTTER) or 0)
        local half = floor((w - GUTTER) / 2)
        page.nem:SetSize(half, huntH)
        page.nem:ClearAllPoints()
        page.nem:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        page.hunters:SetSize(w - half - GUTTER, huntH)
        page.hunters:ClearAllPoints()
        page.hunters:SetPoint("TOPLEFT", page.nem, "TOPRIGHT", GUTTER, 0)
        y = y + huntH + GUTTER + 6
    end
    -- the wall: everyone else wanted, then the ones dealt with this week
    local othersWanted = #b.wanted - ((sel and sel.status == "wanted") and 1 or 0)
    page.wallLabel:SetShown(othersWanted > 0)
    if othersWanted > 0 then
        page.wallLabel:ClearAllPoints()
        page.wallLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        page.wallLabel:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
        y = y + 26
    end
    y = grid(page.posters, b.wanted, sel, content, y, w)
    local othersDealt = #b.dealt - ((sel and sel.status == "dealt") and 1 or 0)
    page.dealtLabel:SetShown(othersDealt > 0)
    if othersDealt > 0 then
        page.dealtLabel:ClearAllPoints()
        page.dealtLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        page.dealtLabel:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
        y = y + 26
    end
    y = grid(page.dealtPosters, b.dealt, sel, content, y, w)
    page.scroll:SetContentHeight(y + 8)
end

local function onShow(pg, arg)
    if type(arg) == "string" and N:Get(arg) then pg.sel = arg end
    N:RenderPage()
end

UI:RegisterPage({
    key = PAGE, title = "Most Wanted", subtitle = "If you see these people, do not call the police.",
    icon = "skull", group = "community", order = 25, scene = "wanted",
    build = build, onShow = onShow,
})

GF:On("GF_WANTED_CHANGED", function()
    GF:Debounce("wanted-refresh", 0.5, function() UI:RefreshPage(PAGE) end)
end)
GF:On("GF_WANTED_REPORTS", function()
    GF:Debounce("wanted-refresh", 0.3, function() UI:RefreshPage(PAGE) end)
end)
GF:On("GF_WANTED_SNOOZE", function()
    GF:Debounce("wanted-refresh", 0.1, function() UI:RefreshPage(PAGE) end)
end)
GF:On("GF_WANTED_SEEN", function()
    GF:Debounce("wanted-refresh", 2, function() UI:RefreshPage(PAGE) end)
end)

-------------------------------------------------------------------------------
-- The moments
-------------------------------------------------------------------------------
local pop

local DEATH_CAPTIONS = {
    "You've been done over. Their face is going up on every pole in Greenfields.",
    "Rolled. The street's been told, and there's a price on their head.",
    "Put in the dirt. Nobody's calling the cops, but everybody's been told.",
    "Dog act. Their mugshot's already on the poles.",
}
local PACK_CAPTIONS = {
    "Jumped by a pack of {n}. Every one of them's going up on the poles.",
    "Took {n} of them to do you. Dog act. They're all on the poles now.",
    "{n} on one. Every face is going up, and every one's worth a point.",
}
local CLAIM_CAPTIONS = {
    "Paid in full.",
    "Street justice.",
    "Sorted. No questions asked.",
    "Collected. They'll be back in thirty seconds, but still.",
}

local function buildPop()
    local f = CreateFrame("Button", nil, UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(60)
    f:SetSize(250, 470)
    -- to the left of centre: the game's own "Release Spirit" box sits top and centre
    f:SetPoint("CENTER", UIParent, "CENTER", -330, 70)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f.poster = makePoster(f)
    f.poster:Fit(230)
    f.poster:SetPoint("TOP", 0, 0)
    f.poster:EnableMouse(false)
    f.plate = CreateFrame("Frame", nil, f)
    f.plate:SetPoint("TOPLEFT", f.poster, "BOTTOMLEFT", -10, -10)
    f.plate:SetPoint("TOPRIGHT", f.poster, "BOTTOMRIGHT", 10, -10)
    f.plate:SetHeight(64)
    f.plate.skin = UI:Nine(f.plate, "card", "BACKGROUND", -6)
    -- a set width, not two anchors: it's measured before the popup has ever been on screen
    f.caption = UI:Para(f.plate, 12, "text")
    f.caption:SetPoint("TOP", 0, -10)
    f.caption:SetWidth(226)
    f.caption:SetJustifyH("CENTER")
    -- the rest of the pack: a small mugshot each, name underneath
    f.mates = {}
    for i = 1, 4 do
        local m = CreateFrame("Frame", nil, f.plate)
        m:SetSize(MATE, MATE + 14)
        m.edge = m:CreateTexture(nil, "ARTWORK", nil, 1)
        m.edge:SetPoint("TOPLEFT")
        m.edge:SetSize(MATE, MATE)
        m.edge:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.7)
        m.photo = m:CreateTexture(nil, "ARTWORK", nil, 2)
        m.photo:SetPoint("TOPLEFT", m.edge, "TOPLEFT", 1, -1)
        m.photo:SetPoint("BOTTOMRIGHT", m.edge, "BOTTOMRIGHT", -1, 1)
        m.name = UI:Text(m, 9, "red", "ui")
        m.name:SetPoint("TOP", m.edge, "BOTTOM", 0, -2)
        m.name:SetWidth(MATE + 8)
        m.name:SetJustifyH("CENTER")
        -- while it's asking, a click leaves a mate off (or puts them back)
        m:SetScript("OnMouseUp", function(self)
            if not (f.ask and self.who) then return end
            f.leaveOff[self.who] = not f.leaveOff[self.who] or nil
            local off = f.leaveOff[self.who]
            self.photo:SetDesaturated(off and true or false)
            self:SetAlpha(off and 0.35 or 1)
            UI.Sound(856)
        end)
        UI.AttachTip(m, function(self)
            if not f.ask then return nil end
            return f.leaveOff[self.who] and "Left off. Click to put them back." or "Click to leave them off."
        end)
        m:Hide()
        f.mates[i] = m
    end
    f.big = UI:Text(f, 22, "wowGold", "title")
    f.big:SetPoint("BOTTOM", f.poster, "TOP", 0, 8)
    f.big:SetShadowOffset(1, -2)
    f.wasnt = UI:Button(f.plate, "Wasn't them", { style = "ghost", height = 20, onClick = function()
        for _, id in ipairs(f.recordIds or {}) do N:Retract(id) end
        f.recordIds = nil
        f.outro:Play()
    end })
    f.wasnt:SetPoint("BOTTOM", f.plate, "BOTTOM", 0, 6)
    -- the question: put them up, a fair fight, or leave me alone for a bit
    f.yes = UI:Button(f.plate, "Put them up", { style = "primary", width = 108, height = 22, onClick = function()
        local r = f.ask
        if not r then return end
        local up = 1
        for _, m in ipairs(r.crew or {}) do
            if not f.leaveOff[m.name] then up = up + 1 end
        end
        N:File(r.id, f.leaveOff)
        UI:Shine(f.poster, 0.8)
        f.Answered("Up on the poles", up > 1 and ("%d faces going up on every pole in Greenfields."):format(up)
            or "Their face is going up on every pole in Greenfields.", 2.5)
    end })
    f.no = UI:Button(f.plate, "Fair fight", { style = "secondary", width = 108, height = 22, onClick = function()
        if f.ask then N:Drop(f.ask.id) end
        f.Answered("Fair fight", "Nothing goes up. Respect.", 1.8)
    end })
    f.snooze = UI:Button(f.plate, "Snooze for an hour", { style = "ghost", height = 18, onClick = function()
        if f.ask then N:Drop(f.ask.id) end
        N:Snooze(3600)
        f.Answered("Snoozed", "An hour off: no posters, no sightings. /gf wanted wake brings it back.", 2.5)
    end })
    f.yes:SetPoint("BOTTOMRIGHT", f.plate, "BOTTOM", -4, 30)
    f.no:SetPoint("BOTTOMLEFT", f.plate, "BOTTOM", 4, 30)
    f.snooze:SetPoint("BOTTOM", f.plate, "BOTTOM", 0, 6)

    local intro = f:CreateAnimationGroup()
    local drop = intro:CreateAnimation("Translation")
    drop:SetOffset(0, -40)
    drop:SetDuration(0.28)
    drop:SetSmoothing("OUT")
    local fade = intro:CreateAnimation("Alpha")
    fade:SetFromAlpha(0)
    fade:SetToAlpha(1)
    fade:SetDuration(0.2)
    intro:SetScript("OnFinished", function()
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", -330, 70)
        f:SetAlpha(1)
    end)
    f.intro = intro

    local out = f:CreateAnimationGroup()
    local fo = out:CreateAnimation("Alpha")
    fo:SetFromAlpha(1)
    fo:SetToAlpha(0)
    fo:SetDuration(0.35)
    out:SetScript("OnFinished", function() f:Hide() end)
    f.outro = out

    -- the stamp: comes down hard from above the paper
    local box = f.poster.stampBox
    local slam = box:CreateAnimationGroup()
    local sc = slam:CreateAnimation("Scale")
    if sc.SetScaleFrom then
        sc:SetScaleFrom(2.6, 2.6)
        sc:SetScaleTo(1, 1)
    else
        sc:SetScale(1, 1)
    end
    sc:SetDuration(0.15)
    sc:SetSmoothing("IN")
    local sa = slam:CreateAnimation("Alpha")
    sa:SetFromAlpha(0)
    sa:SetToAlpha(1)
    sa:SetDuration(0.1)
    slam:SetScript("OnFinished", function()
        box:SetAlpha(1)
        f.shake:Play()
        UI:Burst(box, "gold", 1.6)
        API.PlaySound(SOUND_STAMP)
    end)
    f.slam = slam

    -- and the paper jumps when it lands
    local shake = f.poster:CreateAnimationGroup()
    local offs = { { 0, -5 }, { 0, 8 }, { 0, -3 } }
    for i, o in ipairs(offs) do
        local t = shake:CreateAnimation("Translation")
        t:SetOffset(o[1], o[2])
        t:SetDuration(0.05)
        t:SetOrder(i)
    end
    f.shake = shake

    f:SetScript("OnClick", function(self, button)
        if self.ask then return end   -- it wants an answer, not a click on the paper
        if button == "LeftButton" and self.entry and UI.OpenMain then UI:OpenMain(PAGE, self.entry.name) end
        self.outro:Play()
    end)
    f:SetScript("OnEnter", function(self) self.hover = true end)
    f:SetScript("OnLeave", function(self) self.hover = false end)
    f:Hide()
    return f
end

--- Takes the popup down after `sec`, or once the mouse is off it. A newer poster cancels this one.
local function hideLater(sec)
    pop.token = (pop.token or 0) + 1
    local token = pop.token
    local function check()
        if pop.token ~= token or not pop:IsShown() or pop.outro:IsPlaying() then return end
        if pop.hover then return GF:After(0.5, check) end
        pop.outro:Play()
    end
    GF:After(sec, check)
end

local function answered(big, caption, sec)
    pop.ask = nil
    pop.yes:Hide()
    pop.no:Hide()
    pop.snooze:Hide()
    for _, m in ipairs(pop.mates) do m:EnableMouse(false) end
    pop.big:SetText(big)
    pop.caption:SetText(caption)
    local textH = pop.caption:GetStringHeight() or 14
    pop.plate:SetHeight(max(44, textH + 20 + (pop.rowH or 0)))
    hideLater(sec)
end

local function present(p, opts)
    if GF.gateShut or type(p) ~= "table" then return end
    if not pop then
        pop = buildPop()
        pop.Answered = answered
    end
    pop.outro:Stop()
    pop.slam:Stop()
    pop.entry = p
    pop.ask = opts.ask
    pop.leaveOff = {}
    pop.recordIds = opts.recordIds
    pop.poster:SetEntry(p, opts.fresh and "fresh" or nil)
    pop.poster.stampBox:Hide()
    pop.big:SetText(opts.big or "")
    pop.caption:SetText(opts.caption or "")
    local hasIds = opts.recordIds ~= nil and #opts.recordIds > 0 and not opts.ask
    pop.wasnt:SetShown(hasIds)
    pop.yes:SetShown(opts.ask ~= nil)
    pop.no:SetShown(opts.ask ~= nil)
    pop.snooze:SetShown(opts.ask ~= nil)
    pop.wasnt:SetText(opts.recordIds and #opts.recordIds > 1 and "Wasn't them (takes all of them down)" or "Wasn't them")
    local textH = pop.caption:GetStringHeight() or 14
    -- the rest of the pack, in a row under the words
    local crew = opts.crew or {}
    local n = math.min(#crew, #pop.mates)
    local rowW = n * MATE + (n - 1) * 12
    for i, m in ipairs(pop.mates) do
        local e = crew[i]
        m:SetShown(i <= n)
        m:EnableMouse(opts.ask ~= nil and i <= n)
        m.who = e and e.name or nil
        m.photo:SetDesaturated(false)
        m:SetAlpha(1)
        if i <= n then
            setMug(m.photo, e)
            m.name:SetText(e.name or "?")
            m:ClearAllPoints()
            m:SetPoint("TOPLEFT", pop.plate, "TOP", -rowW / 2 + (i - 1) * (MATE + 12), -(10 + textH + 8))
        end
    end
    local rowH = n > 0 and (8 + MATE + 14) or 0
    pop.rowH = rowH
    pop.plate:SetHeight(max(44, textH + 20 + rowH + (opts.ask and 54 or (hasIds and 26 or 0))))
    pop.hover = false
    hideLater(opts.duration or 10)
    pop:ClearAllPoints()
    pop:SetPoint("CENTER", UIParent, "CENTER", -330, 110)
    pop:SetAlpha(0)
    pop:Show()
    pop.intro:Play()
    if opts.stamp then
        GF:After(0.5, function()
            if not pop:IsShown() then return end
            local A = art()
            pop.poster.stamp:SetTexture(opts.stamp == "square" and A.square or A.dealt)
            pop.poster.stampBox:SetAlpha(1)
            pop.poster.stampBox:Show()
            pop.slam:Play()
        end)
    elseif opts.sound then
        API.PlaySound(opts.sound)
    end
end

local function packCaption(n)
    return (U.Pick(PACK_CAPTIONS):gsub("{n}", tostring(n)))
end

WHY = {
    ["had you targeted"] = "had you targeted",
    ["was your target"] = "was your target",
    ["standing over you"] = "was standing over you",
    ["only enemy about"] = "was the only one about",
    ["death recap"] = "landed the killing blow",
}

--- The poster as a question: "Put them up?" Ignored, it waits on the Most Wanted page.
ask = function(r)
    if type(r) ~= "table" or type(r.killer) ~= "table" then return end
    local p = N:Preview(r)
    local crew = {}
    for _, m in ipairs(r.crew or {}) do crew[#crew + 1] = N:Preview(r, m) end
    local caption
    if #crew > 0 then
        caption = ("Jumped by a pack of %d. Put them all up on the poles? Click a face to leave them off. If you started it, call it a fair fight.")
            :format(#crew + 1)
    else
        caption = ("%s %s. Put them up on the poles? If you started it, call it a fair fight.")
            :format(r.killer.name, WHY[r.why or ""] or "did you over")
    end
    present(p, { ask = r, big = #crew > 0 and "Jumped" or "Done over", caption = caption, crew = crew,
        sound = SOUND_DEATH, duration = 45 })
end
N.AskAgain = ask

GF:On("GF_WANTED_ASK", function(r)
    -- posters off: the question waits on the page instead
    if settings().wantedPosters == false then return end
    -- a moment for the game's own death screen first
    GF:After(1.2, function() ask(r) end)
end)

GF:On("GF_WANTED_DEATH", function(p, ids, _, crew, filed)
    if filed or settings().wantedPosters == false then return end
    if type(ids) == "string" then ids = { ids } end
    crew = type(crew) == "table" and crew or {}
    -- a moment for the game's own death screen first
    GF:After(1.2, function()
        local caption = #crew > 0 and packCaption(#crew + 1) or U.Pick(DEATH_CAPTIONS)
        present(p, { big = #crew > 0 and "Jumped" or "Done over", caption = caption, recordIds = ids, crew = crew,
            sound = SOUND_DEATH, duration = #crew > 0 and 14 or 12 })
    end)
end)

GF:On("GF_WANTED_CLAIMED", function(p, pts, revenge)
    if settings().wantedPosters == false then return end
    local total = pts + (revenge and 1 or 0)
    local cap = U.Pick(CLAIM_CAPTIONS) .. " +" .. N:PointsText(total) .. (revenge and ". Revenge." or ".")
    present(p, { big = revenge and "Squared up" or "Collected", caption = cap, fresh = true,
        stamp = revenge and "square" or "dealt", duration = 9 })
end)

--- Previews, for /gf wanted test and the empty page's button. Nothing's recorded.
function N:TestPoster(kind)
    local b = N:Board()
    local p = b.wanted[1]
    if not p then
        p = { name = "Thrandor", race = "nightelf", raceName = "Night Elf", class = "ROGUE", sex = 2, level = 60,
            guild = "Darnassus Neighbourhood Watch", status = "wanted", bounty = 4, open = { {}, {}, {} }, spread = 2,
            dogs = 1, priors = 6, victims = {}, seen = { t = API.ServerTime() - 600, z = "Ashenvale" } }
    end
    if kind == "pack" then
        local crew = {}
        for i = 2, #b.wanted do
            if #crew < 3 then crew[#crew + 1] = b.wanted[i] end
        end
        if #crew == 0 then
            crew = { { name = "Brightblade", race = "human", class = "PALADIN", sex = 2 },
                { name = "Fizzlecrank", race = "gnome", class = "WARLOCK", sex = 2 } }
        end
        present(p, { big = "Jumped", caption = packCaption(#crew + 1) .. " (Just a preview.)", crew = crew,
            sound = SOUND_DEATH, duration = 14 })
        return
    end
    if kind == "collect" then
        present(p, { big = "Collected", caption = "Paid in full. +" .. N:PointsText(p.bounty) .. ". (Just a preview.)",
            fresh = true, stamp = "dealt", duration = 9 })
    else
        present(p, { big = "Done over", caption = U.Pick(DEATH_CAPTIONS) .. " (Just a preview.)", sound = SOUND_DEATH, duration = 12 })
    end
end

GF:RegisterSlash("wanted", function(args)
    local a = (args or ""):lower():match("^%s*(%S*)")
    if a == "test" then return N:TestPoster("death") end
    if a == "collect" or a == "claim" then return N:TestPoster("collect") end
    if a == "pack" or a == "gang" then return N:TestPoster("pack") end
    if a == "snooze" then
        local mins = tonumber((args or ""):match("snooze%s+(%d+)")) or 60
        N:Snooze(mins * 60)
        return GF:Print(("Most Wanted snoozed for %d minutes: no posters, no sightings. /gf wanted wake brings it back."):format(mins))
    end
    if a == "wake" then
        N:Snooze(0)
        return GF:Print("Most Wanted's back on.")
    end
    UI:OpenMain(PAGE)
end, "Most Wanted (test, pack, collect: previews; snooze [minutes], wake)")
