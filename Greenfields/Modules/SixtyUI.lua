--[[ Greenfields - Modules/SixtyUI.lua
     How level 60 looks. Modules/Sixty.lua decides when.

       The ceremony   the screen goes dark, the lookout comes up with fireworks over the estuary, the
                      fanfare plays and the medal comes down. Then your name, a line, where you came in
                      on the street, the numbers counting up, and the climb drawn level by level. Tell
                      the guild (a line in guild chat), Frame it (a screenshot without the buttons),
                      Done. Esc closes it, and so does a fight starting; /gf sixty plays it again.
       The street     a banner across the top when a guildie makes it: their name, the Watch's line,
                      fireworks, the first bars of the fanfare and a Grats button for guild chat.
       Sixty Club     a Hall of Fame tab (Modules/HallOfFame.lua asks for it): everyone who's made it,
                      in order, and who's next through the door.

     Art and sound come from tools/sixty_art.py. This is the one screen that gets all the gold. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c
local S = GF.Sixty

local SUI = {}
GF.SixtyUI = SUI

local floor, max, min, random = math.floor, math.max, math.min, math.random
local type, ipairs, pairs, tostring = type, ipairs, pairs, tostring

local MEDIA = "Interface\\AddOns\\Greenfields\\Media\\"
local HERO = MEDIA .. "art\\sixty_hero"
local MEDAL = MEDIA .. "art\\sixty_medal"
SUI.MEDAL = MEDAL
local FANFARE = MEDIA .. "sound\\sixty_fanfare.ogg"
local FANFARE_SHORT = MEDIA .. "sound\\sixty_short.ogg"
local HERO_ROWS = 304 / 512           -- tools/sixty_art.py: the art fills the top 304 rows of 512
local HERO_RATIO = 1024 / 304
local LEVEL_UP = 888                  -- the game's own ding, for when the fanfare's switched off

local CW = 800                        -- the ceremony card
local PAD = 24
local INSET = 6                       -- the art sits just inside the gold rim
local ART_H = floor((CW - INSET * 2) / HERO_RATIO + 0.5)
local MEDAL_SIZE = 124
local TILE_H = 46
local CHART_H = 58
local COLS = 120                      -- columns in the climb
local BURSTS = 7                      -- fireworks going at once
local FLAVOR = { 0.80, 0.74, 0.58, 1 }
local SILVER = { 0.78, 0.80, 0.84, 1 }
local BRONZE = { 0.82, 0.56, 0.34, 1 }
local NIGHT = { 0.035, 0.047, 0.075 }

local BANNER_W, BANNER_H = 548, 118
local BANNER_FOR = 20
local BANNER_WAIT = 300               -- a banner waits this long for a fight to finish, then gives up

local function settings() return GF.db and GF.db.settings or {} end
local function G(name) return rawget(_G, name) end

local function paint(c, s) return U.Color(s, c[1], c[2], c[3]) end

local function ordinal(n)
    local tail = n % 100
    local suffix = "th"
    if tail < 11 or tail > 13 then
        suffix = ({ "st", "nd", "rd" })[n % 10] or "th"
    end
    return n .. suffix
end
SUI.Ordinal = ordinal

local function played(p) return p and U.Duration(p) or nil end

--- "9 days", "1 day", "19 hours"
local function span(days)
    if not days then return nil end
    if days < 1 then
        local h = max(1, floor(days * 24 + 0.5))
        return h .. (h == 1 and " hour" or " hours")
    end
    local d = floor(days + 0.5)
    return d .. (d == 1 and " day" or " days")
end
SUI.Span = span

local function className(class)
    local n = class and API.ClassName(class)
    return type(n) == "string" and n or nil
end

-------------------------------------------------------------------------------
-- Fireworks: one-shot bursts from Data/ArtFx.lua, as many at once as BURSTS
-------------------------------------------------------------------------------
local function fireworkStep(b, elapsed)
    local d = b.def
    b.t = b.t + elapsed
    local f = floor(b.t * (d.fps or 14))
    if f >= d.frames then
        b:SetScript("OnUpdate", nil)
        b:Hide()
        return
    end
    if f ~= b.frame then
        b.frame = f
        local col, row = f % d.cols, floor(f / d.cols)
        b.tex:SetTexCoord(col * d.cw, (col + 1) * d.cw, row * d.ch, (row + 1) * d.ch)
    end
end

local function makeFireworks(host, level)
    local pool = {}
    for i = 1, BURSTS do
        local b = CreateFrame("Frame", nil, host)
        b:SetFrameLevel(level)
        b.tex = b:CreateTexture(nil, "OVERLAY")
        b.tex:SetAllPoints()
        b.tex:SetBlendMode("ADD")
        b:Hide()
        pool[i] = b
    end
    pool.next = 1
    return pool
end

local TINTS = {
    gold = { 1, 1, 1 },
    green = { 0.55, 1, 0.62 },
}

--- One burst at (x, y) from the TOPLEFT of `over`, `size` across. Always the gold sparkle (the green
-- burst is a ring, which reads as a ring); a green one is the gold one tinted.
local function firework(pool, over, x, y, size, tint)
    local d = GF.ArtFx and GF.ArtFx.bursts and GF.ArtFx.bursts.gold
    if not d then return end
    local c = TINTS[tint] or TINTS.gold
    local b = pool[pool.next]
    pool.next = pool.next % #pool + 1
    b:ClearAllPoints()
    b:SetPoint("CENTER", over, "TOPLEFT", x, -y)
    b:SetSize(size, size)
    b.tex:SetTexture(d.tex)
    b.tex:SetVertexColor(c[1], c[2], c[3], 1)
    b.def, b.t, b.frame = d, 0, -1
    b:Show()
    fireworkStep(b, 0)
    b:SetScript("OnUpdate", fireworkStep)
end

local function stopFireworks(pool)
    for i = 1, #pool do
        pool[i]:SetScript("OnUpdate", nil)
        pool[i]:Hide()
    end
end

-------------------------------------------------------------------------------
-- Sound
-------------------------------------------------------------------------------
local playing   -- the fanfare's handle, to fade it out early

local function fanfare(path)
    if settings().sixtyMusic == false then
        API.PlaySound(LEVEL_UP)
        return
    end
    local f = G("PlaySoundFile")
    if type(f) ~= "function" then return API.PlaySound(LEVEL_UP) end
    local ok, will, handle = pcall(f, path, "Master")
    if ok and will then
        playing = handle
    else
        API.PlaySound(LEVEL_UP)
    end
end

local function hush(fade)
    local f = G("StopSound")
    if playing and type(f) == "function" then pcall(f, playing, fade or 1500) end
    playing = nil
end

-------------------------------------------------------------------------------
-- The climb: level over time as columns, filling left to right
-------------------------------------------------------------------------------
local function buildChart(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetHeight(CHART_H)
    -- the well on the chart's own textures: a child frame would draw over the columns
    c.well = UI:Nine(c, "inset", "BACKGROUND", -6)
    c.lines = {}
    for i, l in ipairs({ 20, 40 }) do
        local line = c:CreateTexture(nil, "BORDER")
        line:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.16)
        line:SetHeight(1)
        c.lines[i] = { tex = line, level = l }
        local lab = UI:Text(c, 9, "faint", "num")
        lab:SetText(tostring(l))
        lab:SetPoint("RIGHT", line, "LEFT", -4, 0)
        c.lines[i].label = lab
    end
    c.cols, c.caps = {}, {}
    for i = 1, COLS do
        local col = c:CreateTexture(nil, "ARTWORK")
        col:SetTexture(T.tex.white or "Interface\\Buttons\\WHITE8X8")
        c.cols[i] = col
        local cap = c:CreateTexture(nil, "ARTWORK", nil, 2)
        cap:SetColorTexture(1, 0.93, 0.6, 1)
        cap:SetHeight(2)
        c.caps[i] = cap
    end
    c.flag = c:CreateTexture(nil, "OVERLAY")
    c.flag:SetTexture(MEDAL)
    c.flag:SetSize(22, 22)
    return c
end

--- Lays the climb out over the chart's width: each column is the level at its moment in time.
local function drawChart(c, climb)
    local w = c:GetWidth() or 0
    local inner = CHART_H - 8
    for _, l in ipairs(c.lines) do
        l.tex:ClearAllPoints()
        l.tex:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 22, 4 + floor(inner * l.level / S.MAX))
        l.tex:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -4, 4 + floor(inner * l.level / S.MAX))
    end
    local t0, t1 = climb[1].t, climb[#climb].t
    local x0, cw = 22, (w - 26) / COLS
    local j = 1
    for i = 1, COLS do
        local at = t0 + (t1 - t0) * (i - 0.5) / COLS
        while climb[j + 1] and climb[j + 1].t <= at do j = j + 1 end
        local level = i == COLS and climb[#climb].l or climb[j].l
        local k = level / S.MAX
        local h = max(1, floor(inner * k))
        local col, cap = c.cols[i], c.caps[i]
        col:ClearAllPoints()
        col:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", x0 + (i - 1) * cw, 4)
        col:SetSize(cw + 0.6, h)
        -- green down low, gold at the top
        col:SetVertexColor(0.34 + 0.66 * k, 0.86 - 0.04 * k, 0.53 - 0.35 * k, 0.55 + 0.35 * k)
        cap:ClearAllPoints()
        cap:SetPoint("BOTTOMLEFT", col, "TOPLEFT")
        cap:SetWidth(cw + 0.6)
        col:Hide()
        cap:Hide()
    end
    c.flag:ClearAllPoints()
    c.flag:SetPoint("CENTER", c.cols[COLS], "TOP", -6, 0)
    c.flag:Hide()
    c.shown = 0
end

local function revealChart(c, frac)
    local upto = floor(COLS * min(1, frac))
    for i = (c.shown or 0) + 1, upto do
        c.cols[i]:Show()
        c.caps[i]:Show()
    end
    c.shown = max(c.shown or 0, upto)
end

-------------------------------------------------------------------------------
-- The ceremony
-------------------------------------------------------------------------------
local cer   -- built on first use

local function closeCeremony(fast)
    if not cer or not cer:IsShown() then return end
    hush(fast and 400 or 1500)
    cer.closing = true
    UI:Ease(cer, 0, fast and 0.2 or 0.5, true)
end

local function buildCeremony()
    local f = CreateFrame("Frame", "GreenfieldsSixty", UIParent)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetAllPoints(UIParent)
    f:EnableMouse(true)
    f:Hide()
    tinsert(UISpecialFrames, "GreenfieldsSixty")

    f.dim = f:CreateTexture(nil, "BACKGROUND")
    f.dim:SetAllPoints()
    f.dim:SetColorTexture(0.01, 0.012, 0.025, 0.84)
    f.flash = f:CreateTexture(nil, "OVERLAY", nil, 7)
    f.flash:SetAllPoints()
    f.flash:SetTexture(T.tex.glow)
    f.flash:SetBlendMode("ADD")
    f.flash:SetVertexColor(1, 0.86, 0.45, 1)
    f.flash:SetAlpha(0)

    local card = CreateFrame("Frame", nil, f)
    card:SetWidth(CW)
    card:SetPoint("CENTER")
    card.skin = UI:Nine(card, "gold", "BACKGROUND", -6)
    UI:Shadow(card, 22)
    f.card = card

    -- the lookout, fading into the card at the bottom
    card.art = card:CreateTexture(nil, "BORDER")
    card.art:SetTexture(HERO)
    card.art:SetTexCoord(0, 1, 0, HERO_ROWS)
    card.art:SetPoint("TOPLEFT", INSET, -INSET)
    card.art:SetPoint("TOPRIGHT", -INSET, -INSET)
    card.art:SetHeight(ART_H)
    UI.NoSnap(card.art)
    card.artFade = card:CreateTexture(nil, "ARTWORK")
    card.artFade:SetPoint("BOTTOMLEFT", card.art, "BOTTOMLEFT")
    card.artFade:SetPoint("BOTTOMRIGHT", card.art, "BOTTOMRIGHT")
    card.artFade:SetHeight(84)
    UI:Gradient(card.artFade, "VERTICAL", NIGHT[1], NIGHT[2], NIGHT[3], 0.96, 0)
    card.artTop = card:CreateTexture(nil, "ARTWORK")
    card.artTop:SetPoint("TOPLEFT", card.art, "TOPLEFT")
    card.artTop:SetPoint("TOPRIGHT", card.art, "TOPRIGHT")
    card.artTop:SetHeight(40)
    UI:Gradient(card.artTop, "VERTICAL", NIGHT[1], NIGHT[2], NIGHT[3], 0, 0.45)

    f.fireworks = makeFireworks(card, card:GetFrameLevel() + 4)

    -- the medal, straddling the bottom of the picture
    local medal = CreateFrame("Frame", nil, card)
    medal:SetSize(MEDAL_SIZE, MEDAL_SIZE)
    medal:SetPoint("CENTER", card.art, "BOTTOM", 0, 6)
    medal:SetFrameLevel(card:GetFrameLevel() + 8)
    medal.glow = medal:CreateTexture(nil, "BACKGROUND")
    medal.glow:SetTexture(T.tex.glow)
    medal.glow:SetBlendMode("ADD")
    medal.glow:SetVertexColor(1, 0.78, 0.3, 0.55)
    medal.glow:SetPoint("TOPLEFT", -34, 34)
    medal.glow:SetPoint("BOTTOMRIGHT", 34, -34)
    medal.tex = medal:CreateTexture(nil, "ARTWORK")
    medal.tex:SetTexture(MEDAL)
    medal.tex:SetAllPoints()
    UI.NoSnap(medal.tex)
    f.medal = medal

    local slam = medal:CreateAnimationGroup()
    local sc = slam:CreateAnimation("Scale")
    if sc.SetScaleFrom then
        sc:SetScaleFrom(2.4, 2.4)
        sc:SetScaleTo(1, 1)
    else
        sc:SetScale(1, 1)
    end
    sc:SetDuration(0.2)
    sc:SetSmoothing("IN")
    local sa = slam:CreateAnimation("Alpha")
    sa:SetFromAlpha(0)
    sa:SetToAlpha(1)
    sa:SetDuration(0.12)
    slam:SetScript("OnFinished", function()
        medal:SetAlpha(1)
        UI:Burst(medal, "gold", 2.2)
        f.flash:SetAlpha(0.5)
        UI:Ease(f.flash, 0, 0.8)
        f.shake:Play()
    end)
    f.slam = slam

    local shake = card:CreateAnimationGroup()
    for i, o in ipairs({ { 0, -6 }, { 0, 9 }, { 0, -3 } }) do
        local t = shake:CreateAnimation("Translation")
        t:SetOffset(o[1], o[2])
        t:SetDuration(0.05)
        t:SetOrder(i)
    end
    f.shake = shake

    local rise = card:CreateAnimationGroup()
    local up = rise:CreateAnimation("Translation")
    up:SetOffset(0, 24)
    up:SetDuration(0.55)
    up:SetSmoothing("OUT")
    rise:SetScript("OnFinished", function()
        card:ClearAllPoints()
        card:SetPoint("CENTER", f, "CENTER", 0, 0)
    end)
    f.rise = rise

    -- the words
    f.made = UI:Text(card, 34, "wowGold", "title")
    f.made:SetJustifyH("CENTER")
    f.made:SetShadowOffset(1, -2)
    f.name = UI:Text(card, 15, "text", "ui")
    f.name:SetJustifyH("CENTER")
    f.lead = UI:Para(card, 15, "text", "body")
    f.lead:SetTextColor(FLAVOR[1], FLAVOR[2], FLAVOR[3], 1)
    f.lead:SetJustifyH("CENTER")
    f.lead:SetWidth(CW - PAD * 2 - 60)
    f.place = UI:Text(card, 13, "gold", "ui")
    f.place:SetJustifyH("CENTER")

    f.tiles = {}
    for i = 1, 5 do
        local tile = UI:StatTile(card, { size = 18 })
        tile:SetHeight(TILE_H)
        tile.value:SetJustifyH("CENTER")
        tile.label:SetJustifyH("CENTER")
        f.tiles[i] = tile
    end

    f.climbLabel = UI:Text(card, 12, "bronze", "ui")
    f.climbLabel:SetText("The climb")
    f.climbNote = UI:Text(card, 11, "dim")
    f.chart = buildChart(card)

    f.notes = UI:Para(card, 12, "dim")
    f.notes:SetJustifyH("CENTER")
    f.notes:SetWidth(CW - PAD * 2)

    f.tell = UI:Button(card, "Tell the guild", { style = "secondary", width = 140, height = 26, onClick = function(b)
        local ok = API.SendChat(S:TellLine(), "GUILD")
        if ok then
            b:SetText("Told them")
            b:Disable()
        end
    end })
    f.frameIt = UI:Button(card, "Frame it", { style = "secondary", width = 120, height = 26, onClick = function(b)
        local shot = G("Screenshot")
        if type(shot) ~= "function" then return end
        f.tell:SetAlpha(0); f.frameIt:SetAlpha(0); f.done:SetAlpha(0)
        GF:After(0.05, function()
            pcall(shot)
            GF:After(0.4, function()
                f.tell:SetAlpha(1); f.frameIt:SetAlpha(1); f.done:SetAlpha(1)
                b:SetText("Framed")
                GF:After(3, function() b:SetText("Frame it") end)
            end)
        end)
    end })
    UI.AttachTip(f.frameIt, "A screenshot of this, without the buttons. It goes in your Screenshots folder.")
    f.done = UI:Button(card, "Done", { style = "primary", width = 120, height = 26, onClick = function() closeCeremony() end })

    f:SetScript("OnHide", function(self)
        hush(400)
        stopFireworks(self.fireworks)
        self:SetScript("OnUpdate", nil)
        self.closing = nil
    end)
    return f
end

--- Picks up to five numbers worth showing. Each: { value, fmt, label }.
local function tilesFor(r)
    local out = {}
    out[#out + 1] = { key = "played", value = r.p, fmt = played, label = r.pLate and "Played, so far" or "Time played" }
    if r.days then
        local d = r.days
        if d < 1 then
            out[#out + 1] = { value = floor(d * 24 + 0.5), label = "Hours on the road" }
        else
            out[#out + 1] = { value = floor(d + 0.5), label = (r.from and r.from > 2) and ("Days from level " .. r.from) or "Days on the road" }
        end
    end
    local st = r.stats or {}
    if (st.quests or 0) > 0 then out[#out + 1] = { value = st.quests, label = "Quests handed in" } end
    out[#out + 1] = { value = st.deaths or 0, label = (st.deaths or 0) == 0 and "Deaths. None. Legend." or "Lie-downs on the way" }
    if (st.jumps or 0) > 0 then out[#out + 1] = { value = st.jumps, label = "Jumps, for some reason" } end
    if #out < 5 and (st.flights or 0) > 0 then out[#out + 1] = { value = st.flights, label = "Flights taken" } end
    while #out > 5 do table.remove(out) end
    return out
end

local function tileText(e, v)
    if e.key == "played" then
        if not e.value then return "?" end
        return played(v) or "?"
    end
    return U.Commas(floor(v + 0.5))
end

local function placeLine(r)
    local bits = {}
    if r.n == 1 then
        bits[#bits + 1] = "First in Greenfields to 60."
    elseif r.n then
        bits[#bits + 1] = ordinal(r.n) .. " in Greenfields to 60."
    end
    if (r.alts or 0) > 0 then
        bits[#bits + 1] = ("Your %s on this account. Show-off."):format(ordinal(r.alts + 1))
    end
    return table.concat(bits, "  ")
end

local function climbNote(r)
    local first = r.climb and r.climb[1]
    if not (first and r.days) then return "" end
    local from = first.l <= 2 and "Level 1" or ("Level " .. first.l)
    return ("%s to 60 in %s"):format(from, span(r.days))
end

local function notesFor(r)
    local lines = {}
    if r.nemesis then
        local n = r.nemesis.n
        lines[#lines + 1] = paint(C.red, r.nemesis.name) .. (n == 1 and " put you down once on the way up." or
            (" put you down %d times on the way up."):format(n)) .. " They'll keep."
    end
    if r.late then
        lines[#lines + 1] = "You got here before the fireworks did. This is the one you should have had."
    end
    if r.preview then
        lines[#lines + 1] = paint(C.faint, "A preview with made-up numbers. Yours will be the real ones.")
    end
    return table.concat(lines, "\n")
end

local function layout(f, r)
    local card = f.card
    local y = INSET + ART_H + MEDAL_SIZE / 2 + 6 - 2
    local function put(region, h, gap)
        y = y + (gap or 0)
        region:ClearAllPoints()
        region:SetPoint("TOP", card, "TOP", 0, -y)
        y = y + h
    end
    put(f.made, 38, 0)
    put(f.name, 18, 2)
    local leadH = max(18, f.lead:GetStringHeight() or 18)
    put(f.lead, leadH, 8)
    f.place:SetShown(f.place:GetText() ~= nil and f.place:GetText() ~= "")
    if f.place:IsShown() then put(f.place, 16, 6) end

    -- the tiles, side by side
    y = y + 16
    local n = f.tileCount
    local gap = 10
    local tw = (CW - PAD * 2 - gap * (n - 1)) / n
    for i, tile in ipairs(f.tiles) do
        tile:SetShown(i <= n)
        if i <= n then
            tile:ClearAllPoints()
            tile:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + (i - 1) * (tw + gap), -y)
            tile:SetWidth(tw)
        end
    end
    y = y + TILE_H

    local hasChart = r.climb and #r.climb >= 3 and r.climb[#r.climb].t > r.climb[1].t
    f.chart:SetShown(hasChart and true or false)
    f.climbLabel:SetShown(hasChart and true or false)
    f.climbNote:SetShown(hasChart and true or false)
    if hasChart then
        y = y + 16
        f.climbLabel:ClearAllPoints()
        f.climbLabel:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
        f.climbNote:ClearAllPoints()
        f.climbNote:SetPoint("LEFT", f.climbLabel, "RIGHT", 10, -1)
        y = y + 18
        f.chart:ClearAllPoints()
        f.chart:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
        f.chart:SetPoint("TOPRIGHT", card, "TOPRIGHT", -PAD, -y)
        y = y + CHART_H
    end

    local notes = f.notes:GetText()
    f.notes:SetShown(notes ~= nil and notes ~= "")
    if f.notes:IsShown() then
        put(f.notes, max(14, f.notes:GetStringHeight() or 14), 14)
    end

    y = y + 18
    local inGuild = API.InGuild() and not r.preview
    f.tell:SetShown(inGuild)
    local shots = type(G("Screenshot")) == "function"
    f.frameIt:SetShown(shots)
    local buttons = {}
    if inGuild then buttons[#buttons + 1] = f.tell end
    if shots then buttons[#buttons + 1] = f.frameIt end
    buttons[#buttons + 1] = f.done
    local total = 0
    for _, b in ipairs(buttons) do total = total + b:GetWidth() end
    total = total + (#buttons - 1) * 10
    local x = -total / 2
    for _, b in ipairs(buttons) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", card, "TOP", x, -y)
        x = x + b:GetWidth() + 10
    end
    y = y + 26 + 20
    card:SetHeight(y)
    -- small screens: the whole card shrinks to fit, never the words in it
    local screenH = UIParent:GetHeight() or 768
    card:SetScale(min(1, (screenH - 40) / y))
    if hasChart then drawChart(f.chart, r.climb) end
end

-- What comes up when, in seconds from the start.
local BEATS = {
    { at = 1.25, key = "made" }, { at = 1.6, key = "name" }, { at = 1.95, key = "lead" },
    { at = 2.3, key = "place" }, { at = 2.7, key = "tiles" }, { at = 3.3, key = "chart" },
    { at = 4.9, key = "notes" }, { at = 5.3, key = "buttons" },
}

local function setTiles(f, k)
    for i = 1, f.tileCount do
        local e = f.tileData[i]
        local tile = f.tiles[i]
        local v = e.value
        if type(v) == "number" then v = v * k end
        tile.value:SetText(tileText(e, v or 0))
    end
end

local function drive(f, elapsed)
    f.t = f.t + elapsed
    local t = f.t
    -- fireworks: a flurry while it opens, then every so often
    if t >= f.nextBurst then
        local card = f.card
        local w = card.art:GetWidth() or (CW - INSET * 2)
        local size = 56 + random() * 80
        local x = INSET + w * (0.40 + random() * 0.56)
        -- kept clear of the rim: the sky, never the frame
        local y = INSET + max(size * 0.5, ART_H * (0.08 + random() * 0.45))
        firework(f.fireworks, card, x, y, size, random() < 0.6 and "gold" or "green")
        f.nextBurst = t + (t < 9 and (0.28 + random() * 0.45) or (1.1 + random() * 1.6))
    end
    for i, beat in ipairs(BEATS) do
        if not f.beats[i] and t >= beat.at then
            f.beats[i] = true
            local key = beat.key
            if key == "tiles" then
                for j = 1, f.tileCount do UI:Ease(f.tiles[j], 1, 0.35) end
                f.countFrom = t
            elseif key == "chart" then
                if f.chart:IsShown() then
                    UI:Ease(f.chart, 1, 0.3); UI:Ease(f.climbLabel, 1, 0.3); UI:Ease(f.climbNote, 1, 0.3)
                    f.chartFrom = t
                end
            elseif key == "buttons" then
                -- a button laid out as hidden stays hidden: Ease would show it
                for _, b in ipairs({ f.tell, f.frameIt, f.done }) do
                    if b:IsShown() then UI:Ease(b, 1, 0.3) end
                end
            elseif f[key] and f[key]:IsShown() then
                UI:Ease(f[key], 1, 0.4)
            end
        end
    end
    if f.countFrom then
        local k = min(1, (t - f.countFrom) / 1.4)
        setTiles(f, 1 - (1 - k) * (1 - k) * (1 - k))
        if k >= 1 then f.countFrom = nil end
    end
    if f.chartFrom then
        local k = min(1, (t - f.chartFrom) / 1.6)
        revealChart(f.chart, k)
        if k >= 1 then
            f.chartFrom = nil
            f.chart.flag:Show()
            UI:Burst(f.chart.flag, "gold", 2.6)
        end
    end
end

--- Plays the ceremony for recap r (Sixty:Recap() or Sixty:Preview()).
function SUI:Ceremony(r)
    if GF.gateShut or type(r) ~= "table" then return end
    cer = cer or buildCeremony()
    local f = cer
    f.recap = r
    UI:Ease(f, 1, 0.01)
    f:SetAlpha(1)
    f.closing = nil
    f.made:SetText(r.late and "Made it. A while back." or "Made it.")
    local who = r.colored or r.key or "You"
    local what = { "Level 60" }
    if r.race then what[#what + 1] = r.race end
    what[#what + 1] = className(r.class)
    f.name:SetText(who .. paint(C.dim, "  \194\183  " .. table.concat(what, " ")))
    f.lead:SetText(r.lead or "")
    f.place:SetText(placeLine(r))
    f.climbNote:SetText(climbNote(r))
    f.notes:SetText(notesFor(r))
    f.tileData = tilesFor(r)
    f.tileCount = #f.tileData
    for i = 1, f.tileCount do f.tiles[i].label:SetText(f.tileData[i].label) end
    setTiles(f, 0)
    f.tell:SetText("Tell the guild")
    f.tell:Enable()
    layout(f, r)

    -- everything starts hidden and comes up on its beat
    for _, key in ipairs({ "made", "name", "lead", "place", "notes", "climbLabel", "climbNote", "chart", "tell", "frameIt", "done" }) do
        f[key]:SetAlpha(0)
    end
    for i = 1, 5 do f.tiles[i]:SetAlpha(0) end
    f.medal:SetAlpha(0)
    f.flash:SetAlpha(0)
    f.dim:SetAlpha(0)
    UI:Ease(f.dim, 1, 0.6)
    f.t, f.nextBurst, f.beats = 0, 0.35, {}
    f.countFrom, f.chartFrom = nil, nil
    f.card:ClearAllPoints()
    f.card:SetPoint("CENTER", f, "CENTER", 0, -24)
    f:Show()
    f.rise:Play()
    hush(200)
    fanfare(FANFARE)
    GF:After(0.9, function()
        if f:IsShown() and f.recap == r then f.slam:Play() end
    end)
    f:SetScript("OnUpdate", drive)
end

GF:On("GF_SIXTY_CEREMONY", function(r) SUI:Ceremony(r) end)

-- the played tile fills in when the reading lands
GF:On("GF_SIXTY_CHANGED", function()
    if not (cer and cer:IsShown() and cer.recap and not cer.recap.preview) then return end
    local m = GF.cdb and GF.cdb.sixty
    if not (m and m.p) or cer.recap.p then return end
    cer.recap.p = m.p
    for i = 1, cer.tileCount or 0 do
        local e = cer.tileData[i]
        if e.key == "played" then
            e.value = m.p
            if not cer.countFrom then cer.tiles[i].value:SetText(tileText(e, m.p)) end
        end
    end
end)

-- a fight takes it down straight away; /gf sixty brings it back
GF:RegisterEvent("PLAYER_REGEN_DISABLED", function()
    if cer and cer:IsShown() and not cer.closing then
        closeCeremony(true)
        GF:Print("Fight's on. /gf sixty plays your 60 again when you're done.")
    end
end, "SixtyUI")

-------------------------------------------------------------------------------
-- The street: a guildie's 60
-------------------------------------------------------------------------------
local banner

local function buildBanner()
    local f = CreateFrame("Button", nil, UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(70)
    f:SetSize(BANNER_W, BANNER_H)
    f:SetPoint("TOP", UIParent, "TOP", 0, -150)
    f:RegisterForClicks("LeftButtonUp")
    f.skin = UI:Nine(f, "gold", "BACKGROUND", -6)
    UI:Shadow(f, 16)
    -- the fireworks half of the lookout, darkened on the left where the words go
    f.art = f:CreateTexture(nil, "BORDER")
    f.art:SetTexture(HERO)
    f.art:SetPoint("TOPLEFT", 5, -5)
    f.art:SetPoint("BOTTOMRIGHT", -5, 5)
    local inner = (BANNER_W - 10) / (BANNER_H - 10)
    local u0 = 0.40
    local rows = (1 - u0) * 1024 / inner
    f.art:SetTexCoord(u0, 1, 10 / 512, (10 + rows) / 512)
    UI.NoSnap(f.art)
    f.shade = f:CreateTexture(nil, "ARTWORK")
    f.shade:SetPoint("TOPLEFT", f.art, "TOPLEFT")
    f.shade:SetPoint("BOTTOMLEFT", f.art, "BOTTOMLEFT")
    f.shade:SetWidth((BANNER_W - 10) * 0.78)
    UI:Gradient(f.shade, "HORIZONTAL", NIGHT[1], NIGHT[2], NIGHT[3], 0.95, 0.15)

    f.medal = f:CreateTexture(nil, "OVERLAY")
    f.medal:SetTexture(MEDAL)
    f.medal:SetSize(92, 92)
    f.medal:SetPoint("LEFT", 12, 0)
    UI.NoSnap(f.medal)

    f.kicker = UI:Text(f, 11, "bronze", "ui")
    f.kicker:SetPoint("TOPLEFT", 116, -14)
    f.kicker:SetText("Sixty on the street")
    f.title = UI:Text(f, 22, "wowGold", "title")
    f.title:SetPoint("TOPLEFT", f.kicker, "BOTTOMLEFT", 0, -3)
    f.title:SetWidth(BANNER_W - 116 - 40)
    f.title:SetShadowOffset(1, -2)
    f.line = UI:Para(f, 12, "text")
    f.line:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
    f.line:SetWidth(BANNER_W - 116 - 110)
    f.line:SetMaxLines(2)
    f.sub = UI:Text(f, 11, "dim")
    f.sub:SetPoint("BOTTOMLEFT", 116, 12)
    f.sub:SetWidth(BANNER_W - 116 - 110)

    f.grats = UI:Button(f, "Grats", { style = "primary", width = 88, height = 24, onClick = function(b)
        if not f.key then return end
        local ok = API.SendChat(S:GratsLine(f.key), "GUILD")
        if ok then
            b:SetText("Sent")
            b:Disable()
            UI:Burst(b, "green", 2)
        end
    end })
    f.grats:SetPoint("BOTTOMRIGHT", -14, 12)
    UI.AttachTip(f.grats, "Says grats in guild chat.")
    f.close = UI:IconButton(f, "close", 20, "Close", function() f.outro() end)
    f.close:SetPoint("TOPRIGHT", -8, -8)

    f.fireworks = makeFireworks(f, f:GetFrameLevel() + 3)

    local intro = f:CreateAnimationGroup()
    local drop = intro:CreateAnimation("Translation")
    drop:SetOffset(0, -30)
    drop:SetDuration(0.3)
    drop:SetSmoothing("OUT")
    intro:SetScript("OnFinished", function()
        f:ClearAllPoints()
        f:SetPoint("TOP", UIParent, "TOP", 0, -150)
    end)
    f.intro = intro
    function f.outro()
        UI:Ease(f, 0, 0.35, true)
        stopFireworks(f.fireworks)
    end

    f:SetScript("OnClick", function()
        f.outro()
        if UI.OpenMain then UI:OpenMain("fame", "sixty") end
    end)
    f:SetScript("OnEnter", function(self) self.hover = true end)
    f:SetScript("OnLeave", function(self) self.hover = false end)
    f:SetScript("OnUpdate", function(self, elapsed)
        self.t = (self.t or 0) + elapsed
        if self.t >= (self.nextBurst or 0) and self.t < 6 then
            local size = 40 + random() * 44
            local x = BANNER_W * (0.45 + random() * 0.45)
            local y = max(size * 0.5, BANNER_H * (0.2 + random() * 0.5))
            firework(self.fireworks, self, x, y, size, random() < 0.6 and "gold" or "green")
            self.nextBurst = self.t + 0.35 + random() * 0.5
        end
        if self.hover then return end
        self.left = (self.left or BANNER_FOR) - elapsed
        if self.left <= 0 and self:GetAlpha() > 0.99 then self.outro() end
    end)
    f:Hide()
    return f
end

local function streetSub(info)
    local bits = {}
    if info.n == 1 then bits[#bits + 1] = paint(C.wowGold, "First in Greenfields to 60")
    elseif info.n then bits[#bits + 1] = ordinal(info.n) .. " in Greenfields to 60" end
    if info.p then bits[#bits + 1] = U.Duration(info.p) .. " played" end
    return table.concat(bits, "  \194\183  ")
end

local function fillBanner(key, info)
    local R = GF.Roster
    local name = (R and R.Colored and R:Colored(key)) or key
    banner.key = key
    banner.title:SetText(name .. paint(C.wowGold, " hit 60"))
    local line = info.line and U.StripCodes(info.line)
    -- the Watch's line opens with "Name hit 60." and the title says that already
    local rest = line and line:gsub("^[^%.!]-60[%.!]%s*", "")
    if rest and rest ~= "" then line = rest end
    banner.line:SetText(line or "Someone light the drum.")
    banner.sub:SetText(streetSub(info))
end

local function showBanner(key, info)
    banner = banner or buildBanner()
    fillBanner(key, info)
    banner.grats:SetText("Grats")
    banner.grats:Enable()
    banner.grats:SetShown(API.InGuild() and not info.preview)
    banner.t, banner.nextBurst, banner.left, banner.hover = 0, 0.2, BANNER_FOR, false
    banner:SetAlpha(1)
    banner:ClearAllPoints()
    banner:SetPoint("TOP", UIParent, "TOP", 0, -120)
    banner:Show()
    banner.intro:Play()
    GF:After(0.35, function() if banner:IsShown() then UI:Burst(banner.medal, "gold", 2) end end)
    -- your own ceremony keeps its fanfare to itself
    if settings().toastSounds ~= false and not (cer and cer:IsShown()) then fanfare(FANFARE_SHORT) end
end

local pending   -- a banner waiting for a fight to finish

GF:On("GF_SIXTY_HEARD", function(key, info, fresh)
    if GF.gateShut then return end
    -- the second word on the same 60 only fills in what the first one didn't know
    if not fresh then
        if banner and banner:IsShown() and banner.key == key then fillBanner(key, info) end
        if pending and pending.key == key then pending.info = info end
        return
    end
    if not API.InCombat() then return showBanner(key, info) end
    pending = { key = key, info = info, since = API.Time() }
    local function try()
        if not pending then return end
        if API.Time() - pending.since > BANNER_WAIT then pending = nil return end
        if API.InCombat() then return GF:After(2, try) end
        local p = pending
        pending = nil
        showBanner(p.key, p.info)
    end
    GF:After(2, try)
end)

-------------------------------------------------------------------------------
-- The Sixty Club: a Hall of Fame tab
-------------------------------------------------------------------------------
local ROW_H = 48
local NEXT_H = 34
local SIDE_W = 270

local function makeRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(ROW_H)
    -- your own row
    r.wash = r:CreateTexture(nil, "BACKGROUND")
    r.wash:SetAllPoints()
    UI:Gradient(r.wash, "HORIZONTAL", C.wowGold[1], C.wowGold[2], C.wowGold[3], 0.12, 0)
    r.wash:Hide()
    r.line = UI:Hairline(r, "line", 0.5, "none")
    r.line:SetPoint("BOTTOMLEFT")
    r.line:SetPoint("BOTTOMRIGHT")
    r.place = UI:Text(r, 22, "dim", "title")
    r.place:SetPoint("LEFT", 2, 0)
    r.place:SetWidth(34)
    r.place:SetJustifyH("CENTER")
    r.medal = r:CreateTexture(nil, "ARTWORK")
    r.medal:SetTexture(MEDAL)
    r.medal:SetSize(34, 34)
    r.medal:SetPoint("LEFT", 40, 0)
    r.avatar = UI:Avatar(r, 26)
    r.avatar:SetPoint("LEFT", r.medal, "RIGHT", 8, 0)
    r.name = UI:Text(r, 14, "text", "ui")
    r.name:SetPoint("TOPLEFT", r.avatar, "TOPRIGHT", 10, 2)
    r.sub = UI:Text(r, 11, "dim")
    r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
    r.when = UI:Text(r, 13, "text", "ui")
    r.when:SetPoint("TOPRIGHT", -10, -9)
    r.when:SetJustifyH("RIGHT")
    r.how = UI:Text(r, 11, "faint")
    r.how:SetPoint("TOPRIGHT", r.when, "BOTTOMRIGHT", 0, -3)
    r.how:SetJustifyH("RIGHT")
    r.again = UI:Button(r, "Watch it again", { style = "ghost", height = 22, onClick = function() S:Play() end })
    return r
end

local function makeNext(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(NEXT_H)
    r.avatar = UI:Avatar(r, 22)
    r.avatar:SetPoint("LEFT", 0, 0)
    r.name = UI:Text(r, 13, "text", "ui")
    r.name:SetPoint("TOPLEFT", r.avatar, "TOPRIGHT", 8, 1)
    r.level = UI:Text(r, 13, "gold", "num")
    r.level:SetPoint("TOPRIGHT", 0, -1)
    r.bar = UI:Bar(r, { height = 5, color = "wowGold" })
    r.bar:SetPoint("BOTTOMLEFT", r.avatar, "BOTTOMRIGHT", 8, 1)
    r.bar:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 7)
    return r
end

function SUI:BuildClub(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints(parent)
    v.left = UI:Card(v, { title = "The Sixty Club", icon = "star_fill" })
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", -(SIDE_W + 16), 0)
    v.count = UI:Text(v.left, 12, "dim", "num")
    v.count:SetPoint("TOPRIGHT", -12, -12)
    v.bar = UI:Bar(v.left.body, { height = 6, color = "wowGold" })
    v.bar:SetPoint("TOPLEFT")
    v.bar:SetPoint("TOPRIGHT")
    v.scroll, v.content = UI:Scroll(v.left.body)
    v.scroll:SetPoint("TOPLEFT", 0, -16)
    v.scroll:SetPoint("BOTTOMRIGHT")
    v.rows = {}
    v.empty = UI:Empty(v.left.body, "Nobody's made it yet. Somebody's got to be first.", "star")
    v.empty:Hide()

    v.right = UI:Card(v, { title = "Next through the door", icon = "chevron_right" })
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 16, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.nexts = {}
    v.nempty = UI:Empty(v.right.body, "Nobody's in their 40s or 50s yet. Keep at it.", "chevron_right", { width = SIDE_W - 30 })
    v.nempty:Hide()
    v.content:HookScript("OnSizeChanged", function() SUI:LayoutClub(v) end)
    return v
end

function SUI:LayoutClub(v)
    for i = 1, v.rowCount or 0 do
        local r = v.rows[i]
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -(i - 1) * ROW_H)
        r:SetPoint("TOPRIGHT", v.content, "TOPRIGHT", 0, -(i - 1) * ROW_H)
    end
    v.scroll:SetContentHeight((v.rowCount or 0) * ROW_H)
end

local PLACE_COLOURS = { C.wowGold, SILVER, BRONZE }

local function profileOf(key) return GF.Profile and GF.Profile:Get(key) end

function SUI:RenderClub(v)
    local club = S:Club()
    local _, all = S:Count()
    v.count:SetText(("%d of %d at 60"):format(#club, max(all, #club)))
    v.bar:SetValue(all > 0 and #club / max(all, #club) or 0)
    local R = GF.Roster
    for i, e in ipairs(club) do
        local r = v.rows[i]
        if not r then
            r = makeRow(v.content)
            v.rows[i] = r
        end
        local class = R:Class(e.key)
        r.avatar:SetClass(class)
        r.name:SetText(R:Colored(e.key) or e.key)
        local prof = profileOf(e.key)
        local what = className(class) or ""
        if e.f and e.f > 2 then what = what .. paint(C.faint, "  \194\183  watched from level " .. e.f) end
        r.sub:SetText(what)
        if e.place then
            local c = PLACE_COLOURS[e.place] or C.dim
            r.place:SetText(tostring(e.place))
            r.place:SetTextColor(c[1], c[2], c[3], 1)
            r.medal:SetDesaturated(false)
            r.medal:SetAlpha(1)
            r.when:SetText(U.DateShort(e.t))
            local bits = {}
            if e.s and e.t > e.s then bits[#bits + 1] = span((e.t - e.s) / 86400) end
            if e.p then bits[#bits + 1] = U.Duration(e.p) .. " played" end
            r.how:SetText(table.concat(bits, "  \194\183  "))
        else
            r.place:SetText("")
            r.medal:SetDesaturated(true)
            r.medal:SetAlpha(0.55)
            r.when:SetText(paint(C.faint, "Date unknown"))
            r.how:SetText((prof and prof.v) and "Got there before we were counting" or "No Greenfields, no date")
        end
        r.wash:SetShown(e.me and true or false)
        -- yours, with a 60 to play: left of the date, however wide that runs
        r.again:SetShown(e.me and e.t ~= nil)
        if r.again:IsShown() then
            local w = max(r.when:GetStringWidth() or 0, r.how:GetStringWidth() or 0)
            r.again:ClearAllPoints()
            r.again:SetPoint("RIGHT", r, "RIGHT", -(10 + w + 14), 0)
        end
        r:Show()
    end
    for i = #club + 1, #v.rows do v.rows[i]:Hide() end
    v.rowCount = #club
    v.empty:SetShown(#club == 0)
    self:LayoutClub(v)

    local nexts = S:Next(10)
    for i, e in ipairs(nexts) do
        local r = v.nexts[i]
        if not r then
            r = makeNext(v.right.body)
            v.nexts[i] = r
            r:SetPoint("TOPLEFT", v.right.body, "TOPLEFT", 0, -(i - 1) * NEXT_H)
            r:SetPoint("TOPRIGHT", v.right.body, "TOPRIGHT", 0, -(i - 1) * NEXT_H)
        end
        r.avatar:SetClass(R:Class(e.key))
        r.name:SetText(R:Colored(e.key) or e.key)
        r.level:SetText(tostring(e.level))
        r.bar:SetValue(e.level / S.MAX)
        r:Show()
    end
    for i = #nexts + 1, #v.nexts do v.nexts[i]:Hide() end
    v.nempty:SetShown(#nexts == 0)
end

-- only the Sixty Club tab, and only while it's open: profiles change all the time
GF:On("GF_SIXTY_CHANGED", function()
    GF:Debounce("sixty-club", 0.5, function()
        local def = UI.pages and UI.pages.fame
        local pg = def and def.frame
        if pg and pg:IsVisible() and pg.tab == "sixty" and pg.views and pg.views.sixty then
            SUI:RenderClub(pg.views.sixty)
        end
    end)
end)
