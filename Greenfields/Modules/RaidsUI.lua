--[[ Greenfields - Modules/RaidsUI.lua
     The Raid Nights page. Upcoming raids sit on the left; the picked raid fills the right
     under a road sign (where, when, how long till the pull). Under that: your call (five
     answer buttons, role, which toon, a note) and who's coming, grouped by answer, with
     the guildies who haven't answered at the bottom.

     Officers also get the raid editor (new, edit, weekly repeats, call off) and the roster
     builder, which takes over the page: pick a name, click a slot, auto-fill, check the
     comp and buff coverage, save the lineup into the raid. Officers and raid lead/assists
     get the raid tools menu (invite the signed, apply groups, post the lineup).

     Everything goes through GF.Raids; this file only draws. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local R = GF.Raids
if not (R and UI and UI.RegisterPage) then return end

local C = T.c
local col = UI.col
local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local tsort, tinsert, tremove, concat = table.sort, table.insert, table.remove, table.concat

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------
local GAP = 16
local BANNER_H = 92
local TABS_Y = BANNER_H + 8            -- tabs row sits under the banner
local VIEW_Y = TABS_Y + 30 + 10        -- the two views start under the tabs
local MY_H = 104
local EVENT_ROW_H = 60
local CHIP_ROW_H = 26
local CHIP_MIN_W = 128
local MAX_CHIP_COLS = 5
local POOL_W, BENCH_W, COMP_H = 168, 150, 74
local SLOT_H = 18
local GROUP_H = 22 + 5 * (SLOT_H + 2) + 4
local GROUP_GAP = 8
local GROUP_MIN_W = 104

-- Warcraft chrome bits used on this page
local REST_GOLD = { 0.84, 0.70, 0.36, 1 }     -- gold lettering on an unpicked dark button
local GOLD_INK = { 0.12, 0.08, 0.02, 1 }      -- dark ink on the gold button
local INK = { 0.20, 0.12, 0.04, 1 }           -- ink on parchment
local INK_SOFT = { 0.36, 0.25, 0.12, 1 }
--- The answer button that lights up when picked (maybe and bench get a tinted dark one).
local STATUS_FACE = { yes = T.tex.btnGreen, late = T.tex.btnGold, no = T.tex.btnRed }

local DOT = "  \194\183  "
local DOW = { "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" }
local MON = { "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" }
local DOW_NAME = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MON_NAME = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- The banner swaps road signs with the raid's state; ink is the text colour on it.
local SIGNS = {
    green = { tex = T.tex.signGreen, ink = { 1, 1, 1 } },
    yellow = { tex = T.tex.signYellow, ink = { 0.09, 0.08, 0.05 } },
    red = { tex = T.tex.signRed, ink = { 1, 1, 1 } },
    blue = { tex = T.tex.signBlue, ink = { 1, 1, 1 } },
}

local FLAVOR = {
    none = "You in or what?",
    yes = "Locked in. Don't be late, don't stand in the fire.",
    late = "Running late? We'll save you a spot near the bins.",
    maybe = "Nah yeah... maybe. We'll pencil you in.",
    bench = "On the bench. Keep ya boots on.",
    no = "Yeah nah. Fair enough, legend.",
    cancelled = "Called off. Back to the servo.",
    over = "Done and dusted. Hope you didn't stand in it.",
}

local STATUS_TIP = {
    yes = "You're coming. On time. Sober-ish.",
    late = "You're coming, just not for the first pull.",
    maybe = "Can't promise. Officers will plan around it.",
    bench = "Happy to sit out if the raid's full.",
    no = "Can't make it this time.",
}

local BUFF_STATUS = {
    class = { color = "green", text = "Covered by a class buff" },
    camp = { color = "yellow", text = "Only from a camp object (the weaker version)" },
    missing = { color = "red", text = "Nobody in this lineup brings it" },
    na = { color = "faint", text = "Doesn't apply to this lineup" },
}

-------------------------------------------------------------------------------
-- State. Builders are per raid, so an unsaved lineup survives flicking between raids.
-------------------------------------------------------------------------------
local S = { selected = nil, tab = "signups", pending = {}, builders = {}, chipCols = 0, poolIndex = {}, cur = nil }
local P            -- the page frame; widgets hang off it
local E = {}       -- raid editor working values
local editor       -- the raid editor sheet (built on first use)

local refreshAll, refreshDetail, refreshSignupList, refreshRoster, layoutGrid
local selectEvent, selectTab, openEditor, closeEditor

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function now() return API.ServerTime() end

--- Feedback for something the player just clicked (shown even with guild toasts off).
local function toast(title, text, style, icon)
    UI:Toast({ title = title, text = text, style = style or "green", icon = icon or "calendar", duration = 5, force = true })
end

local function fail(err) toast("Didn't stick", tostring(err or "Something went sideways."), "red", "warning") end

local function tint(tex, c, alpha)
    c = col(c)
    tex:SetVertexColor(c[1], c[2], c[3], alpha or c[4] or 1)
end

local function setRoleIcon(tex, role)
    local meta = T.roles[role] or T.roles.ranged
    UI:SetIcon(tex, meta.icon)
    tex:SetVertexColor(meta.color[1], meta.color[2], meta.color[3], 1)
end

--- Role glyph in its role colour, set into a little gold frame (UI:FramedIcon).
local function setRoleArt(fi, role)
    local meta = T.roles[role] or T.roles.ranged
    fi:SetIcon(meta.icon)
    fi.icon:SetVertexColor(meta.color[1], meta.color[2], meta.color[3], 1)
end

--- A 9-sliced rim (frameBronze / iconFrame) over a frame's own background.
local function rim(f, path, margin, layer, sub)
    local t = f:CreateTexture(nil, layer or "BORDER", nil, sub)
    t:SetAllPoints()
    UI.Sliced(t, path, margin)
    return t
end

--- A tiled chrome texture (stone, parchment) filling a frame.
local function tiled(f, path, inset, layer, sub)
    local t = f:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    inset = inset or 0
    t:SetPoint("TOPLEFT", inset, -inset)
    t:SetPoint("BOTTOMRIGHT", -inset, inset)
    t:SetTexture(path, "REPEAT", "REPEAT")
    t:SetHorizTile(true)
    t:SetVertTile(true)
    return t
end

--- A hairline that fades out to the right (section heads).
local function fadeLine(t, c, a)
    c = col(c)
    t:SetTexture(T.tex.white)
    if t.SetGradient and CreateColor then
        t:SetGradient("HORIZONTAL", CreateColor(c[1], c[2], c[3], a or 0.8), CreateColor(c[1], c[2], c[3], 0))
    else
        t:SetVertexColor(c[1], c[2], c[3], (a or 0.8) * 0.5)
    end
end

--- A soft halo hugging a frame's edges, brightest at the rim: the glow texture cut into
-- its four quarters (corners) and centre slivers (edges), drawn just outside the frame.
-- Returns a hidden holder frame; :Show() / :Hide() it.
local function makeHalo(f, size, c, a)
    local h = CreateFrame("Frame", nil, f)
    h:SetPoint("TOPLEFT", -size, size)
    h:SetPoint("BOTTOMRIGHT", size, -size)
    local function piece(l, r, t, b)
        local tex = h:CreateTexture(nil, "BACKGROUND")
        tex:SetTexture(T.tex.glow)
        tex:SetTexCoord(l, r, t, b)
        tex:SetBlendMode("ADD")
        tex:SetVertexColor(c[1], c[2], c[3], a)
        return tex
    end
    local tl = piece(0, 0.5, 0, 0.5)
    tl:SetSize(size, size)
    tl:SetPoint("BOTTOMRIGHT", f, "TOPLEFT")
    local tr = piece(0.5, 1, 0, 0.5)
    tr:SetSize(size, size)
    tr:SetPoint("BOTTOMLEFT", f, "TOPRIGHT")
    local bl = piece(0, 0.5, 0.5, 1)
    bl:SetSize(size, size)
    bl:SetPoint("TOPRIGHT", f, "BOTTOMLEFT")
    local br = piece(0.5, 1, 0.5, 1)
    br:SetSize(size, size)
    br:SetPoint("TOPLEFT", f, "BOTTOMRIGHT")
    local top = piece(0.49, 0.51, 0, 0.5)
    top:SetPoint("BOTTOMLEFT", f, "TOPLEFT")
    top:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT")
    top:SetHeight(size)
    local bottom = piece(0.49, 0.51, 0.5, 1)
    bottom:SetPoint("TOPLEFT", f, "BOTTOMLEFT")
    bottom:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT")
    bottom:SetHeight(size)
    local left = piece(0, 0.5, 0.49, 0.51)
    left:SetPoint("TOPRIGHT", f, "TOPLEFT")
    left:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT")
    left:SetWidth(size)
    local right = piece(0.5, 1, 0.49, 0.51)
    right:SetPoint("TOPLEFT", f, "TOPRIGHT")
    right:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT")
    right:SetWidth(size)
    h:Hide()
    return h
end

--- Gold-rimmed textured face on a plain button: face + additive hover sheen.
local function texturedFace(b)
    b.face = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.face:SetAllPoints()
    UI.Sliced(b.face, T.tex.btnDark, 10)
    b.hl = b:CreateTexture(nil, "ARTWORK", nil, -1)
    b.hl:SetPoint("TOPLEFT", 3, -3)
    b.hl:SetPoint("BOTTOMRIGHT", -3, 3)
    b.hl:SetColorTexture(1, 1, 1, 0.12)
    b.hl:SetBlendMode("ADD")
    b.hl:Hide()
end

local function nameOf(key, class) return U.ClassName(key or "?", class) end

local function colored(key)
    if GF.Roster then return GF.Roster:Colored(key) end
    return U.ShortName(key)
end

local function timeOf(ts)
    local s = U.DateTime(ts)
    return s:match(", (.+)$") or s
end

local function whenText(ev) return U.DateTime(ev.time) .. " - " .. timeOf(ev.time + ev.duration) end

local function srText(ev)
    local n = ev.srLimit
    if n == nil and GF.Roster then n = GF.Roster:Config().srLimit end
    if not n or n <= 0 then return "No soft res" end
    return n .. " SR each"
end

--- countdown(ev) -> short text, colour, kind ("future" | "live" | "done" | "cancelled")
local function countdown(ev, t)
    t = t or now()
    if ev.cancelled then return "Called off", "red", "cancelled" end
    local left = ev.time - t
    if left > 0 then
        local s
        if left >= 86400 then
            s = ("%dd %dh"):format(floor(left / 86400), floor(left / 3600) % 24)
        elseif left >= 3600 then
            s = ("%dh %02dm"):format(floor(left / 3600), floor(left / 60) % 60)
        elseif left >= 60 then
            s = ("%dm"):format(floor(left / 60))
        else
            s = "<1m"
        end
        return s, left < 86400 and "yellow" or "dim", "future"
    end
    if t <= ev.time + ev.duration then return "Live now", "green", "live" end
    return "Done", "faint", "done"
end

local function selectedEvent() return S.selected and R:Get(S.selected) or nil end

local function fitEmpty(e, w)
    w = max(140, (w or 300) - 20)
    e:SetSize(w, 150)
    e.text:SetWidth(w)
end

local function setPill(p, text, color, icon)
    if p.icon then UI:SetIcon(p.icon, icon or "dot") end
    p:SetText(text, color)
end

local function roleCounts(list)
    local c = {}
    for _, r in ipairs(T.roleOrder) do c[r] = 0 end
    for _, s in ipairs(list) do c[s.role] = (c[s.role] or 0) + 1 end
    return c
end

local function pendingFor(id)
    local p = S.pending[id]
    if not p then
        p = {}
        S.pending[id] = p
    end
    return p
end

-------------------------------------------------------------------------------
-- Upcoming list (left)
-------------------------------------------------------------------------------
local function createEventRow(row)
    -- a dark plaque with a bronze rim; the picked raid swaps it for a gold one
    row.card = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.card:SetAllPoints()
    row.card:SetColorTexture(0, 0, 0, 0.26)
    row.rim = rim(row, T.tex.frameBronze, 8, "BORDER", 1)
    row.rim:SetAlpha(0.85)
    row.gold = rim(row, T.tex.iconFrame, 6, "BORDER", 2)
    row.gold:Hide()
    -- the kit's selection wash in the game's gold (the gold rim replaces its bar)
    row.sel:SetColorTexture(C.wowGold[1], C.wowGold[2], C.wowGold[3], 0.07)
    row.selBar:SetAlpha(0)
    row.accent = row:CreateTexture(nil, "ARTWORK", nil, -1)
    row.accent:SetPoint("TOPLEFT", 3, -4)
    row.accent:SetPoint("BOTTOMLEFT", 3, 4)
    row.accent:SetWidth(2)
    -- a little parchment calendar page
    row.page = CreateFrame("Frame", nil, row)
    row.page:SetSize(40, 46)
    row.page:SetPoint("LEFT", row, "LEFT", 9, 0)
    row.paper = tiled(row.page, T.tex.parchment, 1)
    row.paper:SetVertexColor(0.95, 0.88, 0.72, 1)
    row.pageRim = rim(row.page, T.tex.frameBronze, 8)
    row.dow = UI:Text(row.page, 9, INK_SOFT, "head")
    row.dow:SetPoint("TOP", row.page, "TOP", 0, -5)
    row.day = UI:Text(row.page, 18, INK, "title")
    row.day:SetPoint("CENTER", row.page, "CENTER", 0, -1)
    row.mon = UI:Text(row.page, 9, INK_SOFT, "head")
    row.mon:SetPoint("BOTTOM", row.page, "BOTTOM", 0, 5)
    for _, fs in ipairs({ row.dow, row.day, row.mon }) do
        fs:SetJustifyH("CENTER")
        if fs.SetShadowColor then fs:SetShadowColor(0, 0, 0, 0) end   -- ink doesn't cast shadows
    end
    -- line 1: title, countdown on the right; line 2: where + time (full width);
    -- line 3: answer counts, your pill on the right
    row.when = UI:Text(row, 11, "dim", "num")
    row.when:SetPoint("TOPRIGHT", row, "TOPRIGHT", -10, -9)
    row.when:SetJustifyH("RIGHT")
    row.title = UI:Text(row, 12, "text", "ui")
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 59, -8)
    row.title:SetPoint("TOPRIGHT", row.when, "TOPLEFT", -8, 1)
    row.sub = UI:Text(row, 11, "dim")
    row.sub:SetPoint("TOPLEFT", row, "TOPLEFT", 59, -24)
    row.sub:SetPoint("TOPRIGHT", row, "TOPRIGHT", -10, -24)
    row.pill = UI:Pill(row, "", "yellow", { icon = "dot", height = 18, size = 10 })
    row.pill:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 6)
    row.counts = {}
    for i, s in ipairs(T.statusOrder) do
        local meta = T.status[s]
        local icon = UI:Icon(row, 10, meta.icon, "ARTWORK", meta.color)
        local text = UI:Text(row, 11, meta.color, "num")
        text:SetPoint("LEFT", icon, "RIGHT", 3, 0)
        row.counts[i] = { icon = icon, text = text, status = s }
    end
    row.none = UI:Text(row, 11, "faint")
    row.none:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 59, 9)
    row.none:SetText("No answers yet")
end

local function updateEventRow(row, ev)
    local t = now()
    local ac = col(R.InstanceInfo(ev.instance).color)
    row.accent:SetColorTexture(ac[1], ac[2], ac[3], 1)
    local picked = ev.id == S.selected
    row.gold:SetShown(picked)
    row.rim:SetShown(not picked)
    local d = R.DateParts(ev.time)
    row.dow:SetText(d and DOW[d.wday] or "")
    row.day:SetText(d and tostring(d.day) or "?")
    row.mon:SetText(d and MON[d.month] or "")
    row.title:SetText(ev.title)
    UI:SetTextColor(row.title, picked and "wowGold" or "text")
    -- default titles are the instance name, so don't say it twice
    local where = (ev.title ~= ev.instance) and ev.instance or (ev.size .. "-man")
    row.sub:SetText(where .. DOT .. timeOf(ev.time))
    local cd, cdColor, kind = countdown(ev, t)
    row.when:SetText(kind == "future" and ("in " .. cd) or cd)
    UI:SetTextColor(row.when, cdColor)

    local mine = R:MySignup(ev.id)
    if ev.cancelled then
        setPill(row.pill, "CALLED OFF", "red", "close")
    elseif mine then
        local m = T.status[mine.status]
        setPill(row.pill, m.label:upper(), m.color, m.icon)
    elseif kind == "done" then
        setPill(row.pill, "NO ANSWER", "faint", "dot")
    else
        setPill(row.pill, "YOU IN?", "yellow", "bell")
    end

    -- answer counts along the bottom, as many as fit beside the pill
    local c = R:Counts(ev.id)
    local room = (row:GetWidth() or 240) - 59 - (row.pill:GetWidth() or 70) - 16
    local x = 0
    for _, e in ipairs(row.counts) do
        local n = c[e.status] or 0
        e.text:SetText(tostring(n))
        local w = 13 + (e.text:GetStringWidth() or 8)
        if n > 0 and x + w <= room then
            e.icon:ClearAllPoints()
            e.icon:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 59 + x, 10)
            e.icon:Show()
            e.text:Show()
            x = x + w + 8
        else
            e.icon:Hide()
            e.text:Hide()
        end
    end
    row.none:SetShown(c.total == 0)
    row:SetAlpha(ev.cancelled and 0.6 or 1)
end

local function eventTooltip(row, ev)
    local c = R:Counts(ev.id)
    local lines = {
        { "When", U.DateTime(ev.time) },
        { "Where", ("%s (%d)"):format(ev.instance, ev.size) },
        { "Run time", U.Duration(ev.duration) },
        { "Soft res", srText(ev) },
    }
    if ev.leader then lines[#lines + 1] = { "Running it", colored(ev.leader) } end
    lines[#lines + 1] = { "Answers", ("%d yeah, %d late, %d maybe, %d nah"):format(c.yes, c.late, c.maybe, c.no) }
    if ev.notes then
        lines[#lines + 1] = " "
        lines[#lines + 1] = ev.notes
    end
    UI:Tip(row, ev.title, lines)
end

local function buildLeft(page)
    local card = UI:Card(page.body, { title = "Upcoming", icon = "calendar" })
    card:SetPoint("TOPLEFT")
    card:SetPoint("BOTTOMLEFT")
    card:SetWidth(290)
    card.count = UI:Pill(card.right, "", "dim", { height = 18, size = 10 })
    card.count:SetPoint("RIGHT", card.right, "RIGHT")
    page.left = card
    page.evList = UI:List(card.body, {
        rowHeight = EVENT_ROW_H, spacing = 4, zebra = false,
        createRow = createEventRow, updateRow = updateEventRow,
        onClick = function(ev) selectEvent(ev.id) end,
        isSelected = function(ev) return ev.id == S.selected end,
        onEnter = eventTooltip,
    })
    page.evList:SetAllPoints(card.body)
    page.evEmpty = UI:Empty(card.body, "", "calendar")
    page.evEmpty:Hide()
    card.body:HookScript("OnSizeChanged", function(_, w) fitEmpty(page.evEmpty, w) end)
end

-------------------------------------------------------------------------------
-- Banner: the road sign over the picked raid
-------------------------------------------------------------------------------
local function bannerTooltip(self)
    local ev = selectedEvent()
    if not ev then return end
    local lines = { { "When", whenText(ev) }, { "Soft res", srText(ev) } }
    if ev.leader then lines[#lines + 1] = { "Running it", colored(ev.leader) } end
    if ev.created then lines[#lines + 1] = { "Put up", U.Ago(ev.created) } end
    if ev.notes then
        lines[#lines + 1] = " "
        lines[#lines + 1] = ev.notes
    end
    UI:Tip(self, ev.title, lines, "ANCHOR_BOTTOM")
end

local function buildBanner(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(BANNER_H)
    b:SetPoint("TOPLEFT")
    b:SetPoint("TOPRIGHT")
    b.sign = b:CreateTexture(nil, "BACKGROUND")
    b.sign:SetAllPoints()
    UI.Sliced(b.sign, T.tex.signGreen, 22)
    -- the road sign is the guild's brand: its type stays sign lettering, and every line
    -- sits inside the sign's white border (13px in from the top, 15px up from the bottom)
    b.kicker = UI:Text(b, 11, "text", "head")
    b.kicker:SetPoint("TOPLEFT", b, "TOPLEFT", 22, -14)
    b.kicker:SetPoint("TOPRIGHT", b, "TOPRIGHT", -150, -14)
    b.title = UI:Text(b, 22, "text", "head")
    b.title:SetPoint("TOPLEFT", b, "TOPLEFT", 22, -25)
    b.title:SetPoint("TOPRIGHT", b, "TOPRIGHT", -150, -25)
    -- sits under the countdown, so it only has to clear the edit cog
    b.when = UI:Text(b, 12, "text")
    b.when:SetPoint("TOPLEFT", b, "TOPLEFT", 22, -48)
    b.when:SetPoint("TOPRIGHT", b, "TOPRIGHT", -48, -48)
    b.notes = UI:Text(b, 11, "text")
    b.notes:SetPoint("TOPLEFT", b, "TOPLEFT", 22, -62)
    b.notes:SetPoint("TOPRIGHT", b, "TOPRIGHT", -56, -62)
    b.count = UI:Text(b, 24, "text", "num")
    b.count:SetPoint("TOPRIGHT", b, "TOPRIGHT", -24, -16)
    b.count:SetJustifyH("RIGHT")
    b.countLbl = UI:Text(b, 10, "text", "head")
    b.countLbl:SetPoint("TOPRIGHT", b.count, "BOTTOMRIGHT", 0, -3)
    b.countLbl:SetJustifyH("RIGHT")
    b.edit = UI:IconButton(b, "gear", 24, "Edit this raid", function() openEditor(S.selected) end, { 1, 1, 1, 0.85 })
    b.edit:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -16, 12)
    b:SetScript("OnEnter", function(self) GF:Safe("raids:banner", bannerTooltip, self) end)
    b:SetScript("OnLeave", function() UI:HideTip() end)
    return b
end

--- The sign catches the light once whenever a raid lands on it (picked, or page opened).
local function shineBanner(id)
    if not P or P.shineFor == id then return end
    P.shineFor = id
    GF:After(0.05, function()
        if P and P.banner and P.banner:IsVisible() then UI:Shine(P.banner, 0.8) end
    end)
end

local function updateBanner(ev)
    local b = P.banner
    local cd, _, kind = countdown(ev)
    local style = (kind == "cancelled" and "red") or (kind == "live" and "yellow") or (kind == "done" and "blue") or "green"
    local sign = SIGNS[style]
    UI.Sliced(b.sign, sign.tex, 22)
    local ink = sign.ink
    b.kicker:SetTextColor(ink[1], ink[2], ink[3], 0.75)
    b.title:SetTextColor(ink[1], ink[2], ink[3], 1)
    b.when:SetTextColor(ink[1], ink[2], ink[3], 0.92)
    b.notes:SetTextColor(ink[1], ink[2], ink[3], 0.72)
    b.count:SetTextColor(ink[1], ink[2], ink[3], 1)
    b.countLbl:SetTextColor(ink[1], ink[2], ink[3], 0.7)
    b.edit:SetColor({ ink[1], ink[2], ink[3], 0.85 })
    b.kicker:SetText(("%s" .. DOT .. "%d-man"):format(ev.instance, ev.size):upper())
    b.title:SetText(ev.title:upper())
    b.when:SetText(whenText(ev) .. DOT .. srText(ev))
    if ev.notes then
        b.notes:SetText(ev.notes)
    elseif ev.leader then
        b.notes:SetText("Run by " .. U.ShortName(ev.leader))
    else
        b.notes:SetText("")
    end
    if kind == "future" then
        b.count:SetText(cd:upper())
        b.countLbl:SetText("TILL THE PULL")
    elseif kind == "live" then
        b.count:SetText("LIVE")
        b.countLbl:SetText("GET IN HERE")
    elseif kind == "done" then
        b.count:SetText("DONE")
        b.countLbl:SetText("GG, LEGENDS")
    else
        b.count:SetText("OFF")
        b.countLbl:SetText("CALLED OFF")
    end
end

-------------------------------------------------------------------------------
-- Your call: answer buttons, role, toon, note
-------------------------------------------------------------------------------
local function chooseStatus(status)
    local cur = S.cur
    if not cur then return end
    local note = P.my.note:GetText()
    local ok, err = R:SignupAs(cur.id, cur.char, status, cur.role, note)
    if not ok then
        fail(err)
        return
    end
    pendingFor(cur.id).note = nil
    -- the store change refreshes the page; flip the buttons now so it feels instant
    cur.status = status
    for _, b in ipairs(P.my.status) do
        b:SetOn(b.status == status)
        -- you're coming: the button catches the light
        if b.status == status and (status == "yes" or status == "late") then UI:Shine(b, 0.6) end
    end
    P.my.flavor:SetText(FLAVOR[status])
    local c = col(T.status[status].color)
    P.my.stripe:SetColorTexture(c[1], c[2], c[3], 1)
end

local function chooseRole(role)
    local cur = S.cur
    if not cur or not T.roles[role] then return end
    cur.role = role
    pendingFor(cur.id).role = role
    R:RememberRole(cur.char, role)
    local mine = R:MySignup(cur.id)
    if mine then
        local ok, err = R:SignupAs(cur.id, cur.char, mine.status, role, nil)
        if not ok then fail(err) end
    end
end

local function chooseChar(key)
    local cur = S.cur
    if not cur or type(key) ~= "string" then return end
    cur.char = key
    cur.role = R:RoleFor(key)
    local p = pendingFor(cur.id)
    p.char, p.role = key, cur.role
    P.my.role:Refresh()
    local mine = R:MySignup(cur.id)
    if mine then
        local ok, err = R:SignupAs(cur.id, key, mine.status, cur.role, nil)
        if not ok then fail(err) end
    end
end

local function saveNote(text)
    local cur = S.cur
    if not cur then return end
    text = R.CleanText(text, 60)
    pendingFor(cur.id).note = text
    local mine = R:MySignup(cur.id)
    if mine and (mine.note or "") ~= text then
        local ok, err = R:SignupAs(cur.id, mine.char, mine.status, mine.role, text)
        if not ok then fail(err) end
    end
end

local function roleItems()
    local out = {}
    for _, r in ipairs(T.roleOrder) do
        local m = T.roles[r]
        out[#out + 1] = { value = r, text = m.label, icon = m.icon, color = m.color }
    end
    return out
end

local function charItems()
    local out = {}
    for _, c in ipairs(R:MyChars()) do
        local lvl = (c.level and c.level > 0) and ("  " .. T:Wrap("faint", c.level)) or ""
        out[#out + 1] = { value = c.key, text = nameOf(c.key, c.class) .. lvl }
    end
    return out
end

--- One of the five answers: a gold-rimmed game button. Unpicked ones are dark with gold
-- lettering and the answer's colour on the icon; the picked one takes the answer's own
-- button face (green, gold, red; maybe and bench tint the dark one) under a gold halo.
local function makeStatusButton(parent, status)
    local meta = T.status[status]
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(28)
    b.status = status
    -- picked: a gold halo round the rim
    b.glow = makeHalo(b, 7, { 1, 0.78, 0.18 }, 0.95)
    texturedFace(b)
    b.wash = b:CreateTexture(nil, "BORDER")
    b.wash:SetPoint("TOPLEFT", 3, -3)
    b.wash:SetPoint("BOTTOMRIGHT", -3, 3)
    b.wash:SetTexture(T.tex.white)
    b.wash:SetBlendMode("ADD")
    b.wash:Hide()
    b.icon = UI:Icon(b, 12, meta.icon)
    -- Friz in title case, the way the game's own buttons read
    b.label = UI:Text(b, 12, REST_GOLD, "ui")
    b.label:SetText(meta.label)
    --- Room for icon + label inside the rim at this width?
    function b:IconFits(w)
        return (w or self:GetWidth() or 0) >= (self.label:GetStringWidth() or 30) + 17 + 16
    end
    --- icon + label centred; narrow buttons drop the icon rather than crowd the rim
    -- (layoutMyPanel decides for all five at once, so the row stays uniform)
    function b:Fit(withIcon)
        local tw = self.label:GetStringWidth() or 30
        if withIcon == nil then withIcon = self:IconFits() end
        self.icon:ClearAllPoints()
        self.label:ClearAllPoints()
        if withIcon then
            self.icon:SetPoint("LEFT", self, "CENTER", -(tw + 17) / 2, 0)
            self.label:SetPoint("LEFT", self.icon, "RIGHT", 5, 0)
            self.icon:Show()
        else
            self.icon:Hide()
            self.label:SetPoint("CENTER", self, "CENTER", 0, 0)
        end
    end
    function b:Paint(hover)
        local c = col(meta.color)
        local enabled = self:IsEnabled()
        if not enabled then hover = false end   -- locked raids don't light up
        self.hl:SetShown(hover and true or false)
        self.face:SetDesaturated(not enabled)
        if self.on then
            UI.Sliced(self.face, STATUS_FACE[status] or T.tex.btnDark, 10)
            self.glow:SetShown(enabled)
            local washed = STATUS_FACE[status] == nil
            self.wash:SetShown(washed)
            if washed then self.wash:SetVertexColor(c[1], c[2], c[3], status == "bench" and 0.16 or 0.32) end
            local ink = status == "late" and GOLD_INK or C.text
            self.label:SetTextColor(ink[1], ink[2], ink[3], 1)
            self.icon:SetVertexColor(ink[1], ink[2], ink[3], 1)
        else
            UI.Sliced(self.face, T.tex.btnDark, 10)
            self.glow:Hide()
            self.wash:Hide()
            local tc = hover and C.wowGold or REST_GOLD
            self.label:SetTextColor(tc[1], tc[2], tc[3], 1)
            self.icon:SetVertexColor(c[1], c[2], c[3], hover and 1 or 0.85)
        end
    end
    function b:SetOn(on)
        self.on = on and true or false
        self:Paint(self:IsMouseOver())
    end
    b:SetScript("OnEnter", function(self) self:Paint(true) end)
    b:SetScript("OnLeave", function(self) self:Paint(false) end)
    b:SetScript("OnClick", function(self)
        UI.Sound(856)
        GF:Safe("raids:status", chooseStatus, self.status)
    end)
    UI.AttachTip(b, { meta.long, { STATUS_TIP[status] } })
    b:SetOn(false)
    b:Fit()
    return b
end

local function layoutMyPanel(w)
    local mp = P.my
    w = (w and w > 0) and w or mp:GetWidth() or 400
    local inner = max(200, w - 24)
    local bw = floor((inner - 4 * 6) / 5)
    local icons = true
    for _, b in ipairs(mp.status) do
        if not b:IconFits(bw) then icons = false end
    end
    for i, b in ipairs(mp.status) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", mp, "TOPLEFT", 12 + (i - 1) * (bw + 6), -31)
        b:SetWidth(bw)
        b:Fit(icons)
    end
    local rw = floor(inner * 0.27)
    local cw = floor(inner * 0.33)
    mp.role:SetWidth(rw)
    mp.char:SetWidth(cw)
    mp.note:SetWidth(max(60, inner - rw - cw - 12))
end

local function buildMyPanel(parent)
    -- a card (slate + bronze rim) with no kit title: the answer buttons are the content
    local mp = UI:Card(parent)
    mp:SetPoint("TOPLEFT")
    mp:SetPoint("TOPRIGHT")
    mp:SetHeight(MY_H)
    P.my = mp
    -- the card accent notch, in the colour of your answer
    mp.stripe = mp:CreateTexture(nil, "ARTWORK")
    mp.stripe:SetSize(22, 2)
    mp.stripe:SetPoint("TOPLEFT", 9, -3)
    mp.lbl = UI:Text(mp, 12, "wowGold", "ui")
    mp.lbl:SetPoint("TOPLEFT", mp, "TOPLEFT", 12, -11)
    mp.lbl:SetText("Your call")
    mp.flavor = UI:Text(mp, 11, "dim")
    mp.flavor:SetPoint("TOPLEFT", mp.lbl, "TOPRIGHT", 10, -1)
    mp.flavor:SetPoint("TOPRIGHT", mp, "TOPRIGHT", -12, -12)
    mp.status = {}
    for i, s in ipairs(T.statusOrder) do mp.status[i] = makeStatusButton(mp, s) end
    mp.role = UI:Dropdown(mp, {
        width = 120, items = roleItems,
        get = function() return S.cur and S.cur.role end,
        set = function(v) GF:Safe("raids:role", chooseRole, v) end,
        tooltip = "Your role for this one. Remembered per toon.",
    })
    mp.role:SetPoint("TOPLEFT", mp, "TOPLEFT", 12, -66)
    mp.char = UI:Dropdown(mp, {
        width = 150, items = charItems, placeholder = "Which toon?",
        get = function() return S.cur and S.cur.char end,
        set = function(v) GF:Safe("raids:char", chooseChar, v) end,
        tooltip = "Which toon you're bringing. Every character you've logged in shows up here.",
    })
    mp.char:SetPoint("LEFT", mp.role, "RIGHT", 6, 0)
    mp.note = UI:Input(mp, { placeholder = "Add a note (late, swapping toons...)", max = 60, onEnter = function(text) saveNote(text) end })
    mp.note:SetPoint("LEFT", mp.char, "RIGHT", 6, 0)
    mp.note:HookScript("OnEditFocusLost", function(self) GF:Safe("raids:note", saveNote, self:GetText()) end)
    mp:HookScript("OnSizeChanged", function(_, w) layoutMyPanel(w) end)
    layoutMyPanel(400)
end

local function refreshMyPanel(ev)
    local mp = P.my
    local mine = R:MySignup(ev.id)
    local p = pendingFor(ev.id)
    local char = (mine and mine.char) or p.char or API.MyKey()
    local role = (mine and mine.role) or p.role or R:RoleFor(char)
    S.cur = { id = ev.id, status = mine and mine.status or nil, char = char, role = role }
    local over = R:IsOver(ev)
    local locked = ev.cancelled or over
    for _, b in ipairs(mp.status) do
        b:SetEnabled(not locked)        -- before painting: a locked raid's buttons stay unlit
        b:SetOn(S.cur.status == b.status)
        b:SetAlpha(locked and 0.45 or 1)
    end
    mp.role:Refresh()
    mp.char:Refresh()
    for _, w in ipairs({ mp.role, mp.char, mp.note }) do
        w:SetEnabled(not locked)
        w:SetAlpha(locked and 0.5 or 1)
    end
    if not mp.note:HasFocus() then
        mp.note:SetText((mine and mine.note) or p.note or "")
        mp.note:RefreshPlaceholder()
    end
    local key = (ev.cancelled and "cancelled") or (over and "over") or S.cur.status or "none"
    mp.flavor:SetText(FLAVOR[key])
    local stripe = (locked and "faint") or (S.cur.status and T.status[S.cur.status].color) or "yellow"
    local c = col(stripe)
    mp.stripe:SetColorTexture(c[1], c[2], c[3], 1)
end

-------------------------------------------------------------------------------
-- Who's coming: a virtual list of section heads and rows of name chips
-------------------------------------------------------------------------------
local function chipMenu(chip, e)
    local items = { { text = nameOf(e.key, e.class), title = true } }
    items[#items + 1] = { text = "Whisper", icon = "bubble", func = function() UI:Whisper(e.key) end }
    if UI.OpenProfile then
        items[#items + 1] = { text = "Profile", icon = "eye", func = function() UI:OpenProfile(e.key) end }
    end
    local s = e.signup
    if s and R:IsOfficer() then
        items[#items + 1] = { separator = true }
        for _, st in ipairs(T.statusOrder) do
            local meta = T.status[st]
            items[#items + 1] = {
                text = "Mark " .. meta.label, icon = meta.icon, color = meta.color, checked = s.status == st,
                func = function()
                    local ok, err = R:SetStatusFor(s.id, st)
                    if not ok then fail(err) end
                end,
            }
        end
        items[#items + 1] = {
            text = "Remove answer", icon = "trash", color = "red",
            func = function()
                UI:Confirm("Remove answer?", ("Take %s's answer off this raid?"):format(U.ShortName(s.char)), function()
                    local ok, err = R:RemoveSignup(s.id)
                    if not ok then fail(err) end
                end, "Remove", "red")
            end,
        }
    end
    UI:OpenMenu(chip, items, { width = 170 })
end

local CHIP_BG, CHIP_BG_HOVER = { 0, 0, 0, 0.30 }, { 0.16, 0.13, 0.08, 0.92 }
local CHIP_EDGE = { C.bronze[1], C.bronze[2], C.bronze[3], 0.55 }

local function paintChip(chip, hover)
    local bg = hover and CHIP_BG_HOVER or CHIP_BG
    local edge = hover and C.wowGold or CHIP_EDGE
    chip:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    chip:SetBackdropBorderColor(edge[1], edge[2], edge[3], hover and 0.9 or edge[4])
end

local function chipEnter(self)
    local e = self.entry
    if not e then return end
    paintChip(self, true)
    local lines = {}
    local s = e.signup
    if s then
        local m = T.status[s.status]
        lines[#lines + 1] = { "Answer", U.Color(m.long, col(m.color)) }
        lines[#lines + 1] = { "Role", (T.roles[s.role] or T.roles.ranged).label }
        if s.char ~= s.player then lines[#lines + 1] = { "Main", colored(s.player) } end
        lines[#lines + 1] = { "Answered", U.Ago(s.t) }
        if s.note then
            lines[#lines + 1] = " "
            lines[#lines + 1] = '"' .. s.note .. '"'
        end
    else
        lines[#lines + 1] = e.online and "Online now and hasn't answered." or "Offline. Hasn't answered."
        lines[#lines + 1] = { "Level", tostring(e.level or "?") }
    end
    lines[#lines + 1] = " "
    lines[#lines + 1] = T:Wrap("faint", "Right-click for options")
    UI:Tip(self, nameOf(e.key, e.class), lines)
end

local function chipLeave(self)
    paintChip(self, false)
    UI:HideTip()
end

local function chipClick(self, button)
    local e = self.entry
    if not e then return end
    if button == "LeftButton" and UI.OpenProfile then
        GF:Safe("raids:profile", UI.OpenProfile, UI, e.key)
    else
        GF:Safe("raids:chipmenu", chipMenu, self, e)
    end
end

--- A name plate: dark, bronze-edged, the role framed in gold.
local function makeChip(row)
    local b = CreateFrame("Button", nil, row, "BackdropTemplate")
    b:SetHeight(CHIP_ROW_H - 4)
    UI:SetBackdrop(b, CHIP_BG, CHIP_EDGE)
    b.role = UI:FramedIcon(b, 18)
    b.role:SetPoint("LEFT", 2, 0)
    b.name = UI:Text(b, 11, "text", "ui")
    b.name:SetPoint("LEFT", b, "LEFT", 26, 0)
    b.name:SetPoint("RIGHT", b, "RIGHT", -18, 0)
    b.flag = UI:Icon(b, 10, "bubble", "OVERLAY", "faint")
    b.flag:SetPoint("RIGHT", -6, 0)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnEnter", GF:Wrap("raids:chip", chipEnter))
    b:SetScript("OnLeave", GF:Wrap("raids:chip", chipLeave))
    b:SetScript("OnClick", GF:Wrap("raids:chip", chipClick))
    b:Hide()
    return b
end

local function doNudge()
    local ev = selectedEvent()
    if not ev then return end
    local ok, err = R:Nudge(ev.id)
    if ok then
        toast("Nudge sent", "Everyone who hasn't answered just got a poke.", "green", "bell")
    else
        fail(err)
    end
end

local function createChipRow(row)
    row.hl:SetAlpha(0)          -- chips do their own hover
    local h = CreateFrame("Frame", nil, row)
    h:SetAllPoints()
    row.head = h
    -- section head: the answer's icon, its name in Friz gold, a bronze rule fading out
    h.icon = UI:Icon(h, 12, "check")
    h.icon:SetPoint("LEFT", 2, -1)
    h.label = UI:Text(h, 12, "wowGold", "ui")
    h.label:SetPoint("LEFT", h.icon, "RIGHT", 6, 0)
    h.count = UI:Text(h, 11, "dim", "num")
    h.count:SetPoint("LEFT", h.label, "RIGHT", 6, 0)
    h.line = h:CreateTexture(nil, "ARTWORK")
    fadeLine(h.line, "bronze", 0.85)
    h.line:SetHeight(1)
    h.line:SetPoint("BOTTOMLEFT", 0, 1)
    h.line:SetPoint("BOTTOMRIGHT", 0, 1)
    h.roles = {}
    local prev
    for i = #T.roleOrder, 1, -1 do
        local r = T.roleOrder[i]
        local text = UI:Text(h, 11, "dim", "num")
        if prev then text:SetPoint("RIGHT", prev, "LEFT", -9, 0) else text:SetPoint("RIGHT", h, "RIGHT", -4, -1) end
        local icon = UI:Icon(h, 11, T.roles[r].icon)
        icon:SetPoint("RIGHT", text, "LEFT", -3, 0)
        setRoleIcon(icon, r)
        h.roles[r] = { icon = icon, text = text }
        prev = icon
    end
    h.nudge = UI:Button(h, "Nudge", {
        style = "ghost", icon = "bell", height = 20, size = 11, onClick = function() doNudge() end,
        tooltip = { "Nudge", { "Pokes everyone who hasn't answered with a toast. Officers only, once every ten minutes." } },
    })
    h.nudge:SetPoint("RIGHT", h, "RIGHT", -2, 0)
    row.chips = {}
    for i = 1, MAX_CHIP_COLS do row.chips[i] = makeChip(row) end
end

local function updateChipRow(row, item)
    local h = row.head
    if item.kind == "head" then
        h:Show()
        for _, c in ipairs(row.chips) do
            c.entry = nil
            c:Hide()
        end
        if item.status == "none" then
            UI:SetIcon(h.icon, "eye")
            tint(h.icon, "faint")
            h.label:SetText("Not answered yet")
            UI:SetTextColor(h.label, REST_GOLD)
            UI:SetTextColor(h.count, "faint")
        else
            local meta = T.status[item.status]
            UI:SetIcon(h.icon, meta.icon)
            tint(h.icon, meta.color)
            h.label:SetText(meta.long)
            UI:SetTextColor(h.label, "wowGold")
            UI:SetTextColor(h.count, meta.color)
        end
        h.count:SetText(tostring(item.n))
        for r, e in pairs(h.roles) do
            local n = item.roles and item.roles[r]
            e.text:SetText(tostring(n or 0))
            e.icon:SetShown(item.roles ~= nil)
            e.text:SetShown(item.roles ~= nil)
        end
        h.nudge:SetShown(item.nudge and true or false)
        return
    end
    h:Hide()
    local cols = max(1, S.chipCols)
    local w = max(60, (P.signList:GetWidth() or 300) - 10)
    local cw = floor((w - (cols - 1) * 6) / cols)
    for i, chip in ipairs(row.chips) do
        local e = item[i]
        if e and i <= cols then
            chip.entry = e
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (cw + 6), -2)
            chip:SetWidth(cw)
            chip.name:SetText(nameOf(e.key, e.class))
            paintChip(chip, chip:IsMouseOver())
            if e.signup then
                setRoleArt(chip.role, e.signup.role)
                chip.flag:SetShown(e.signup.note ~= nil)
                chip:SetAlpha(1)
            else
                chip.role:SetIcon("dot")
                tint(chip.role.icon, e.online and "green" or "faint")
                chip.flag:Hide()
                chip:SetAlpha(e.online and 0.95 or 0.6)
            end
            chip:Show()
        else
            chip.entry = nil
            chip:Hide()
        end
    end
end

local function chipCols(w)
    w = (w or P.signList:GetWidth() or 0) - 10
    return U.Clamp(floor((w + 6) / (CHIP_MIN_W + 6)), 1, MAX_CHIP_COLS)
end

local function buildSignupItems(ev, cols)
    local items = {}
    local by = {}
    for _, s in ipairs(R:SignupsFor(ev.id)) do
        local list = by[s.status]
        if not list then
            list = {}
            by[s.status] = list
        end
        list[#list + 1] = s
    end
    local function addChips(entries)
        for i = 1, #entries, cols do
            local row = { kind = "chips" }
            for j = i, min(#entries, i + cols - 1) do row[#row + 1] = entries[j] end
            items[#items + 1] = row
        end
    end
    for _, st in ipairs(T.statusOrder) do
        local list = by[st]
        if list and #list > 0 then
            tsort(list, function(a, b)
                local ra, rb = R.ROLE_RANK[a.role] or 9, R.ROLE_RANK[b.role] or 9
                if ra ~= rb then return ra < rb end
                return a.char < b.char
            end)
            local showRoles = st == "yes" or st == "late"
            items[#items + 1] = { kind = "head", status = st, n = #list, roles = showRoles and roleCounts(list) or nil }
            local entries = {}
            for i, s in ipairs(list) do entries[i] = { key = s.char, class = s.class, signup = s } end
            addChips(entries)
        end
    end
    if not ev.cancelled and not R:IsOver(ev) then
        local nr = R:NotResponded(ev.id)
        if #nr > 0 then
            items[#items + 1] = { kind = "head", status = "none", n = #nr, nudge = R:IsOfficer() }
            local entries = {}
            for i, m in ipairs(nr) do entries[i] = { key = m.key, class = m.class, level = m.level, online = m.online } end
            addChips(entries)
        end
    end
    return items
end

refreshSignupList = function()
    local ev = selectedEvent()
    if not ev or not P.sv:IsShown() then return end
    S.chipCols = chipCols()
    local items = buildSignupItems(ev, S.chipCols)
    P.signList:SetItems(items, true)
    local c = R:Counts(ev.id)
    local going = c.yes + c.late
    P.whoCard.pill:SetText(("%d / %d"):format(going, ev.size), going >= ev.size and "green" or "yellow")
    if #items == 0 then
        local line = "Nobody's answered yet. Be first - the bin chickens are watching."
        if ev.cancelled then
            line = "Called off before anyone answered. Back to the servo."
        elseif R:IsOver(ev) then
            line = "Nobody answered this one. Tumbleweeds."
        end
        P.signEmpty:SetText(line)
        P.signEmpty:Show()
    else
        P.signEmpty:Hide()
    end
end

local function buildSignupsView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -VIEW_Y)
    v:SetPoint("BOTTOMRIGHT")
    P.sv = v
    buildMyPanel(v)
    local card = UI:Card(v, { title = "Who's coming", icon = "roster" })
    card:SetPoint("TOPLEFT", P.my, "BOTTOMLEFT", 0, -10)
    card:SetPoint("BOTTOMRIGHT")
    card.pill = UI:Pill(card.right, "", "green", { height = 18, size = 10, tooltip = "Yeahs and lates against the raid size." })
    card.pill:SetPoint("RIGHT", card.right, "RIGHT")
    P.whoCard = card
    P.signList = UI:List(card.body, {
        rowHeight = CHIP_ROW_H, spacing = 2, zebra = false,
        createRow = createChipRow, updateRow = updateChipRow,
    })
    P.signList:SetAllPoints(card.body)
    P.signList:HookScript("OnSizeChanged", function(_, w)
        if chipCols(w) ~= S.chipCols then GF:Safe("raids:chips", refreshSignupList) end
    end)
    P.signEmpty = UI:Empty(card.body, "", "roster")
    P.signEmpty:Hide()
    card.body:HookScript("OnSizeChanged", function(_, w) fitEmpty(P.signEmpty, w) end)
end

-------------------------------------------------------------------------------
-- Roster builder: model. Slots are 5 per group with `false` for empty, so a name lands
-- exactly where you clicked; the saved lineup is the packed version.
-------------------------------------------------------------------------------
local function fillBuilder(b, lineup)
    b.slots, b.bench = {}, {}
    for g = 1, b.G do
        local src = (lineup.groups and lineup.groups[g]) or {}
        local row = {}
        for i = 1, 5 do row[i] = type(src[i]) == "string" and src[i] or false end
        b.slots[g] = row
    end
    for _, k in ipairs(lineup.bench or {}) do b.bench[#b.bench + 1] = k end
end

local function builderLineup(b)
    local out = { groups = {}, bench = {} }
    for g = 1, b.G do
        local list = {}
        for i = 1, 5 do
            local k = b.slots[g][i]
            if k then list[#list + 1] = k end
        end
        out.groups[g] = list
    end
    for i, k in ipairs(b.bench) do out.bench[i] = k end
    return out
end

--- The working copy for a raid: the saved lineup unless there are unsaved changes.
local function loadBuilder(ev)
    local G = R.GroupsFor(ev.size)
    local b = S.builders[ev.id]
    if b and b.dirty then
        if b.G ~= G then
            local l = R.FitLineup(builderLineup(b), G)
            b.G = G
            fillBuilder(b, l)
        end
        return b
    end
    local pick = b and b.pick or nil
    b = { id = ev.id, G = G, dirty = false, pick = pick }
    fillBuilder(b, R:Lineup(ev.id) or { groups = {}, bench = {} })
    S.builders[ev.id] = b
    return b
end

local function currentBuilder()
    return S.selected and S.builders[S.selected] or nil
end

local function locate(b, key)
    for g = 1, b.G do
        for i = 1, 5 do
            if b.slots[g][i] == key then return "g", g, i end
        end
    end
    for i, k in ipairs(b.bench) do
        if k == key then return "b", i end
    end
    return nil
end

local function placedCount(b)
    local n = 0
    for g = 1, b.G do
        for i = 1, 5 do
            if b.slots[g][i] then n = n + 1 end
        end
    end
    return n
end

local function touched(b)
    b.dirty = true
    refreshRoster()
end

local function pickKey(key)
    local b = currentBuilder()
    if not b then return end
    b.pick = (b.pick ~= key) and key or nil
    refreshRoster()
end

--- Click on group g, slot i: drop the pick there (swapping with whoever was in it), or
-- with nothing picked, pull the occupant out.
local function slotClickAt(g, i)
    local b = currentBuilder()
    if not b or not b.slots[g] then return end
    local cur = b.slots[g][i]
    local pick = b.pick
    if pick then
        b.pick = nil
        if cur == pick then
            refreshRoster()
            return
        end
        local kind, a, c = locate(b, pick)
        if kind == "g" then
            b.slots[a][c] = cur or false
        elseif kind == "b" then
            if cur then b.bench[a] = cur else tremove(b.bench, a) end
        end
        b.slots[g][i] = pick
        touched(b)
    elseif cur then
        b.slots[g][i] = false
        touched(b)
    end
end

local function benchPick()
    local b = currentBuilder()
    if not b or not b.pick then return end
    local pick = b.pick
    b.pick = nil
    local kind, a, c = locate(b, pick)
    if kind == "b" then
        refreshRoster()
        return
    end
    if kind == "g" then b.slots[a][c] = false end
    b.bench[#b.bench + 1] = pick
    touched(b)
end

local function benchClick(key)
    local b = currentBuilder()
    if not b then return end
    if b.pick then
        benchPick()
        return
    end
    for i, k in ipairs(b.bench) do
        if k == key then
            tremove(b.bench, i)
            break
        end
    end
    touched(b)
end

local function autoFill()
    local ev = selectedEvent()
    local b = currentBuilder()
    if not ev or not b then return end
    local lineup = R:AutoFill(ev.id)
    if not lineup or R.LineupCount(lineup) == 0 then
        toast("Nothing to fill", "Nobody's said yeah yet. Give 'em a nudge.", "yellow", "bolt")
        return
    end
    fillBuilder(b, lineup)
    b.pick = nil
    touched(b)
end

local function clearLineup()
    local b = currentBuilder()
    if not b then return end
    local function wipe()
        for g = 1, b.G do b.slots[g] = { false, false, false, false, false } end
        b.bench = {}
        b.pick = nil
        touched(b)
    end
    if placedCount(b) + #b.bench == 0 then return end
    UI:Confirm("Clear the lineup?", "Empties every group and the bench. Nothing's saved until you hit Save.", wipe, "Clear it", "yellow")
end

local function saveLineup()
    local ev = selectedEvent()
    local b = currentBuilder()
    if not ev or not b then return end
    local ok, err = R:SaveLineup(ev.id, builderLineup(b))
    if not ok then
        fail(err)
        return
    end
    b.dirty = false
    toast("Lineup saved", ("%d placed. Raid tools will sort the groups on the night."):format(placedCount(b)), "green", "check")
    refreshRoster()
end

--- Class, role and answer for a key in the builder, from its signup when there is one.
local function slotInfo(key)
    local info = S.poolIndex[key]
    if info then return info end
    local class = R:ClassOf(key)
    return { key = key, class = class, role = R.DefaultRole(class), stale = true }
end

local function placeTag(b, key)
    local kind, a = locate(b, key)
    if kind == "g" then return "G" .. a, "Group " .. a end
    if kind == "b" then return "BN", "Bench" end
    return nil
end

-------------------------------------------------------------------------------
-- Roster builder: pool (signed up), groups grid, bench
-------------------------------------------------------------------------------
local function createPoolRow(row)
    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetTexture(T.tex.circle)
    row.dot:SetSize(6, 6)
    row.dot:SetPoint("LEFT", 6, 0)
    row.role = UI:FramedIcon(row, 18)
    row.role:SetPoint("LEFT", 15, 0)
    row.name = UI:Text(row, 12, "text", "head")
    row.name:SetPoint("LEFT", row, "LEFT", 38, 0)
    row.name:SetPoint("RIGHT", row, "RIGHT", -30, 0)
    row.sel:SetColorTexture(C.wowGold[1], C.wowGold[2], C.wowGold[3], 0.10)
    row.selBar:SetColorTexture(C.wowGold[1], C.wowGold[2], C.wowGold[3], 1)
    row.tag = UI:Text(row, 10, "faint", "num")
    row.tag:SetPoint("RIGHT", -6, 0)
    row.tag:SetJustifyH("RIGHT")
end

local function updatePoolRow(row, item)
    local meta = item.status and T.status[item.status]
    tint(row.dot, (item.stale or item.status == "no") and "red" or (meta and meta.color) or "faint")
    setRoleArt(row.role, item.role)
    row.name:SetText(nameOf(item.key, item.class))
    row.tag:SetText(item.place or "")
    local b = currentBuilder()
    local picked = b and b.pick == item.key
    row:SetAlpha((item.place and not picked) and 0.5 or 1)
end

local function poolTooltip(row, item)
    local lines = {}
    if item.signup then
        local m = T.status[item.status]
        lines[#lines + 1] = { "Answer", U.Color(m.long, col(m.color)) }
    else
        lines[#lines + 1] = U.Color("Not signed up any more", col("red"))
    end
    lines[#lines + 1] = { "Role", (T.roles[item.role] or T.roles.ranged).label }
    if item.placeLong then lines[#lines + 1] = { "Placed", item.placeLong } end
    if item.note then lines[#lines + 1] = '"' .. item.note .. '"' end
    lines[#lines + 1] = " "
    lines[#lines + 1] = T:Wrap("faint", "Click to pick, then click a slot or the bench.")
    UI:Tip(row, nameOf(item.key, item.class), lines)
end

local function slotEnter(self)
    local b = currentBuilder()
    if not b or not b.slots[self.g] then return end
    local key = b.slots[self.g][self.i]
    local title, lines
    if b.pick then
        self.hl:SetColorTexture(C.green[1], C.green[2], C.green[3], 0.16)
        title = (key and "Swap in " or "Put ") .. U.ShortName(b.pick) .. " here"
        if not key then
            lines = { "Group " .. self.g .. "." }
        elseif locate(b, b.pick) then
            lines = { ("%s goes where %s was."):format(U.ShortName(key), U.ShortName(b.pick)) }
        else
            lines = { ("%s goes back to the signed-up list."):format(U.ShortName(key)) }
        end
    elseif key then
        self.hl:SetColorTexture(C.red[1], C.red[2], C.red[3], 0.10)
        local info = slotInfo(key)
        title = nameOf(key, info.class)
        lines = { { "Group", tostring(self.g) }, { "Role", (T.roles[info.role] or T.roles.ranged).label } }
        if info.status then lines[#lines + 1] = { "Answer", U.Color(T.status[info.status].long, col(T.status[info.status].color)) } end
        if info.stale then lines[#lines + 1] = U.Color("Not signed up any more", col("red")) end
        lines[#lines + 1] = " "
        lines[#lines + 1] = T:Wrap("faint", "Click to pull them out.")
    else
        self.hl:SetColorTexture(1, 1, 1, 0.04)
        title = "Empty slot"
        lines = { "Pick a name on the left first." }
    end
    self.hl:Show()
    UI:Tip(self, title, lines)
end

local function makeSlot(parent, g, i)
    local s = CreateFrame("Button", nil, parent)
    s:SetHeight(SLOT_H)
    s.g, s.i = g, i
    s.bg = s:CreateTexture(nil, "BACKGROUND")
    s.bg:SetAllPoints()
    s.bg:SetColorTexture(0, 0, 0, 0.3)
    s.hl = s:CreateTexture(nil, "BORDER")
    s.hl:SetAllPoints()
    s.hl:Hide()
    s.role = UI:FramedIcon(s, 16)
    s.role:SetPoint("LEFT", 1, 0)
    s.name = UI:Text(s, 11, "text", "head")
    s.name:SetPoint("LEFT", s, "LEFT", 22, 0)
    s.name:SetPoint("RIGHT", s, "RIGHT", -12, 0)
    s.mark = s:CreateTexture(nil, "OVERLAY")
    s.mark:SetTexture(T.tex.circle)
    s.mark:SetSize(5, 5)
    s.mark:SetPoint("RIGHT", -4, 0)
    s.mark:Hide()
    s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    s:SetScript("OnEnter", function(self) GF:Safe("raids:slot", slotEnter, self) end)
    s:SetScript("OnLeave", function(self)
        self.hl:Hide()
        UI:HideTip()
    end)
    s:SetScript("OnClick", function(self)
        UI.Sound(856)
        GF:Safe("raids:slot", slotClickAt, self.g, self.i)
    end)
    return s
end

--- A raid group: a slate plaque with a bronze rim (a titleless kit card), five slots.
local function makeGroup(parent, g)
    local f = UI:Card(parent)
    f:SetHeight(GROUP_H)
    f.head = UI:Text(f, 11, "wowGold", "ui")
    f.head:SetPoint("TOPLEFT", 9, -6)
    f.head:SetText("Group " .. g)
    f.count = UI:Text(f, 10, "faint", "num")
    f.count:SetPoint("TOPRIGHT", -9, -7)
    f.count:SetJustifyH("RIGHT")
    f.slots = {}
    for i = 1, 5 do
        local s = makeSlot(f, g, i)
        local y = -22 - (i - 1) * (SLOT_H + 2)
        s:SetPoint("TOPLEFT", f, "TOPLEFT", 5, y)
        s:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, y)
        f.slots[i] = s
    end
    f:Hide()
    return f
end

local function updateSlot(s, key, pick)
    if key then
        local info = slotInfo(key)
        setRoleArt(s.role, info.role)
        s.role:Show()
        s.name:SetText(nameOf(key, info.class))
        s.bg:SetColorTexture(1, 0.9, 0.7, 0.06)
        local mark = (info.stale or info.status == "no") and "red" or (info.status == "late" and "yellow")
            or (info.status == "maybe" and "blue") or (info.status == "bench" and "dim") or nil
        if mark then
            tint(s.mark, mark)
            s.mark:Show()
        else
            s.mark:Hide()
        end
    else
        s.role:Hide()
        s.mark:Hide()
        s.name:SetText(pick and T:Wrap("green", "+ put here") or T:Wrap("faint", "empty"))
        if pick then s.bg:SetColorTexture(C.green[1], C.green[2], C.green[3], 0.07) else s.bg:SetColorTexture(0, 0, 0, 0.3) end
    end
end

layoutGrid = function()
    local b = currentBuilder()
    if not b or not P.gridContent then return end
    local w = P.gridContent:GetWidth() or 0
    if w < 60 then w = max(60, (P.gridScroll:GetWidth() or 300) - 12) end
    local cols = min(U.Clamp(floor((w + GROUP_GAP) / (GROUP_MIN_W + GROUP_GAP)), 1, 4), b.G)
    local gw = floor((w - (cols - 1) * GROUP_GAP) / cols)
    for g = 1, 8 do
        local f = P.groups[g]
        if g <= b.G then
            local r, c = floor((g - 1) / cols), (g - 1) % cols
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", P.gridContent, "TOPLEFT", c * (gw + GROUP_GAP), -r * (GROUP_H + GROUP_GAP))
            f:SetWidth(gw)
            f:Show()
        else
            f:Hide()
        end
    end
    local rows = ceil(b.G / cols)
    P.gridScroll:SetContentHeight(rows * (GROUP_H + GROUP_GAP) - GROUP_GAP)
end

local function createBenchRow(row)
    row.role = UI:FramedIcon(row, 18)
    row.role:SetPoint("LEFT", 3, 0)
    row.name = UI:Text(row, 11, "text", "head")
    row.name:SetPoint("LEFT", row, "LEFT", 26, 0)
    row.name:SetPoint("RIGHT", row, "RIGHT", -4, 0)
end

local function updateBenchRow(row, key)
    local info = slotInfo(key)
    setRoleArt(row.role, info.role)
    row.name:SetText(nameOf(key, info.class))
end

local function benchTooltip(row, key)
    local info = slotInfo(key)
    local b = currentBuilder()
    local hint = (b and b.pick) and ("Click to bench " .. U.ShortName(b.pick) .. " too.") or "Click to take them off the bench."
    UI:Tip(row, nameOf(key, info.class), { { "Role", (T.roles[info.role] or T.roles.ranged).label }, " ", T:Wrap("faint", hint) })
end

--- The bench drop target: a dark gold-rimmed button that turns green once a name is picked.
local function makeBenchTarget(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(24)
    b:SetPoint("TOPLEFT")
    b:SetPoint("TOPRIGHT", -10, 0)
    texturedFace(b)
    b.icon = UI:Icon(b, 11, "plus", "ARTWORK", REST_GOLD)
    b.icon:SetPoint("LEFT", 9, 0)
    b.label = UI:Text(b, 11, REST_GOLD, "ui")
    b.label:SetPoint("LEFT", b, "LEFT", 25, 0)
    b.label:SetPoint("RIGHT", b, "RIGHT", -8, 0)
    --- text = "Bench <name>" while a name is picked, nil otherwise
    function b:SetArmed(text)
        local ink = text and C.text or REST_GOLD
        UI.Sliced(self.face, text and T.tex.btnGreen or T.tex.btnDark, 10)
        self.label:SetText(text or "Pick a name")
        self.label:SetTextColor(ink[1], ink[2], ink[3], 1)
        self.icon:SetVertexColor(ink[1], ink[2], ink[3], text and 1 or 0.8)
    end
    b:SetScript("OnClick", function()
        UI.Sound(856)
        GF:Safe("raids:bench", benchPick)
    end)
    b:SetScript("OnEnter", function(self)
        self.hl:Show()
        UI:Tip(self, "Bench", { "Pick a name, then click here to put them on the bench." })
    end)
    b:SetScript("OnLeave", function(self)
        self.hl:Hide()
        UI:HideTip()
    end)
    b:SetArmed(nil)
    return b
end

-------------------------------------------------------------------------------
-- Roster builder: comp + buff coverage strip
-------------------------------------------------------------------------------
local function coreCategories()
    local out = {}
    local D = GF.BuffData
    if D and type(D.categories) == "table" then
        for _, c in ipairs(D.categories) do
            if c.core then out[#out + 1] = c end
        end
    end
    return out
end

local function analyzeBuffs(members)
    local B = GF.Buffs
    if not (B and B.Analyze) then return nil end
    local ok, rep = GF:Safe("raids:buffs", B.Analyze, B, members)
    if ok and type(rep) == "table" then return rep end
    return nil
end

local function namesList(keys)
    local out = {}
    if type(keys) == "table" then
        for i, k in ipairs(keys) do
            if i > 6 then
                out[#out + 1] = "..."
                break
            end
            if type(k) == "string" then out[#out + 1] = colored(k) end
        end
    end
    return concat(out, ", ")
end

local function buffEnter(self)
    local cat = self.cat
    local st = BUFF_STATUS[self.status] or BUFF_STATUS.na
    local lines = { U.Color(st.text, col(st.color)) }
    local entry = self.entry
    if type(entry) == "table" then
        local from = namesList(entry.providers)
        if from ~= "" then lines[#lines + 1] = { "From", from } end
        local camp = namesList(entry.camp)
        if camp ~= "" then lines[#lines + 1] = { "Camp", camp } end
    end
    if not self.report then
        lines[#lines + 1] = " "
        lines[#lines + 1] = T:Wrap("faint", "Place some people to see coverage.")
    end
    UI:Tip(self, cat.long or cat.label, lines)
end

local function buildComposition(cp)
    cp.lbl1 = UI:Text(cp, 11, "wowGold", "ui")
    cp.lbl1:SetPoint("TOPLEFT", 12, -14)
    cp.lbl1:SetText("Comp")
    cp.roles = {}
    for i, r in ipairs(T.roleOrder) do
        local f = CreateFrame("Frame", nil, cp)
        f:SetSize(50, 18)
        f:SetPoint("TOPLEFT", 58 + (i - 1) * 54, -10)
        f.art = UI:FramedIcon(f, 18)
        f.art:SetPoint("LEFT")
        setRoleArt(f.art, r)
        f.text = UI:Text(f, 14, "text", "num")
        f.text:SetPoint("LEFT", f.art, "RIGHT", 5, 0)
        f:EnableMouse(true)
        UI.AttachTip(f, function() return { T.roles[r].label, { "Placed in groups (bench not counted)." } } end)
        f.role = r
        cp.roles[i] = f
    end
    cp.sep = cp:CreateTexture(nil, "ARTWORK")
    cp.sep:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.7)
    cp.sep:SetSize(1, 16)
    cp.sep:SetPoint("TOPLEFT", 58 + 4 * 54 + 2, -11)
    cp.classes = {}
    for i, cls in ipairs(API.CLASSES) do
        local f = CreateFrame("Frame", nil, cp)
        f:SetSize(36, 18)
        -- the class crest in a gold frame, like an action button
        f.art = UI:FramedIcon(f, 18)
        f.art:SetPoint("LEFT")
        API.SetClassIcon(f.art.icon, cls)
        f.text = UI:Text(f, 12, "text", "num")
        f.text:SetPoint("LEFT", f.art, "RIGHT", 4, 0)
        f:EnableMouse(true)
        UI.AttachTip(f, function(self) return { API.ClassName(cls), { (self.n or 0) .. " in the groups" } } end)
        f.class = cls
        f:Hide()
        cp.classes[i] = f
    end
    cp.lbl2 = UI:Text(cp, 11, "wowGold", "ui")
    cp.lbl2:SetPoint("TOPLEFT", 12, -48)
    cp.lbl2:SetText("Buffs")
    cp.score = UI:Text(cp, 16, "green", "num")
    cp.score:SetPoint("TOPLEFT", 58, -44)
    cp.scoreLbl = UI:Text(cp, 9, "faint", "head")
    cp.scoreLbl:SetPoint("BOTTOMLEFT", cp.score, "BOTTOMRIGHT", 3, 1)
    cp.scoreLbl:SetText("/100")
    cp.note = UI:Text(cp, 11, "faint")
    cp.note:SetPoint("TOPLEFT", 58, -48)
    cp.chips = {}
    for i, cat in ipairs(coreCategories()) do
        -- the buff's spell icon in a gold frame; a coloured jewel in the corner grades it
        local f = UI:FramedIcon(cp, 22)
        f:SetPoint("TOPLEFT", 112 + (i - 1) * 26, -42)
        f:SetIcon(API.SpellIcon(cat.icon))
        f.pipRing = f:CreateTexture(nil, "OVERLAY", nil, 2)
        f.pipRing:SetTexture(T.tex.circle)
        f.pipRing:SetSize(9, 9)
        f.pipRing:SetPoint("CENTER", f, "BOTTOMRIGHT", -3, 3)
        f.pipRing:SetVertexColor(0, 0, 0, 0.9)
        f.pip = f:CreateTexture(nil, "OVERLAY", nil, 3)
        f.pip:SetTexture(T.tex.circle)
        f.pip:SetSize(6, 6)
        f.pip:SetPoint("CENTER", f.pipRing, "CENTER")
        f.cat = cat
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self) GF:Safe("raids:buff", buffEnter, self) end)
        f:SetScript("OnLeave", function() UI:HideTip() end)
        cp.chips[i] = f
    end
end

local function updateComposition(b)
    local cp = P.comp
    local roles, classes, members = {}, {}, {}
    for _, r in ipairs(T.roleOrder) do roles[r] = 0 end
    for g = 1, b.G do
        for i = 1, 5 do
            local k = b.slots[g][i]
            if k then
                local info = slotInfo(k)
                roles[info.role] = (roles[info.role] or 0) + 1
                if info.class then classes[info.class] = (classes[info.class] or 0) + 1 end
                local lvl = R:LevelOf(k)
                members[#members + 1] = { key = k, class = info.class, level = (lvl and lvl > 0) and lvl or 60 }
            end
        end
    end
    for _, f in ipairs(cp.roles) do
        local n = roles[f.role] or 0
        f.text:SetText(tostring(n))
        UI:SetTextColor(f.text, n > 0 and "text" or "faint")
    end
    local x = 58 + 4 * 54 + 14
    for _, f in ipairs(cp.classes) do
        local n = classes[f.class] or 0
        f.n = n
        if n > 0 then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", x, -10)
            f.text:SetText(tostring(n))
            f:Show()
            x = x + 40
        else
            f:Hide()
        end
    end
    -- buff coverage from the Buffs module, when it's loaded
    local hasBuffs = GF.Buffs and GF.Buffs.Analyze
    local report = (#members > 0 and hasBuffs) and analyzeBuffs(members) or nil
    cp.note:SetShown(not hasBuffs)
    cp.note:SetText(hasBuffs and "" or "Buff planner isn't loaded, so no coverage check.")
    cp.score:SetShown(hasBuffs and true or false)
    cp.scoreLbl:SetShown(hasBuffs and true or false)
    local score = report and tonumber(report.score)
    if score then
        cp.score:SetText(tostring(floor(score + 0.5)))
        UI:SetTextColor(cp.score, score >= 80 and "green" or score >= 50 and "yellow" or "red")
    else
        cp.score:SetText("--")
        UI:SetTextColor(cp.score, "faint")
    end
    local cats = report and type(report.cats) == "table" and report.cats or nil
    for _, f in ipairs(cp.chips) do
        f:SetShown(hasBuffs and true or false)
        local entry = cats and cats[f.cat.key]
        local status = type(entry) == "table" and BUFF_STATUS[entry.status] and entry.status or "na"
        if not report then status = "na" end
        f.status, f.entry, f.report = status, entry, report
        local c = col(BUFF_STATUS[status].color)
        f.pip:SetVertexColor(c[1], c[2], c[3], 1)
        f.pip:SetShown(status ~= "na")
        f.pipRing:SetShown(status ~= "na")
        f:SetDesaturated(status == "missing" or status == "na")
        f.icon:SetAlpha((status == "na") and 0.35 or (status == "missing" and 0.6 or 1))
    end
end

-------------------------------------------------------------------------------
-- Roster builder: refresh + view
-------------------------------------------------------------------------------
refreshRoster = function()
    local ev = selectedEvent()
    if not ev or not P.rv:IsShown() then return end
    local b = loadBuilder(ev)
    local items, index = {}, {}
    for _, s in ipairs(R:SignupsFor(ev.id)) do
        local info = { key = s.char, class = s.class, role = s.role, status = s.status, note = s.note, signup = s }
        index[s.char] = info
        if s.status ~= "no" or locate(b, s.char) then items[#items + 1] = info end
    end
    -- people in the lineup who no longer have an answer still show, flagged red
    local function addStale(k)
        if k and not index[k] then
            local class = R:ClassOf(k)
            local info = { key = k, class = class, role = R.DefaultRole(class), stale = true }
            index[k] = info
            items[#items + 1] = info
        end
    end
    for g = 1, b.G do
        for i = 1, 5 do addStale(b.slots[g][i]) end
    end
    for _, k in ipairs(b.bench) do addStale(k) end
    S.poolIndex = index
    tsort(items, function(x, y)
        local sx = x.stale and 9 or (R.STATUS_RANK[x.status] or 8)
        local sy = y.stale and 9 or (R.STATUS_RANK[y.status] or 8)
        if sx ~= sy then return sx < sy end
        local rx, ry = R.ROLE_RANK[x.role] or 9, R.ROLE_RANK[y.role] or 9
        if rx ~= ry then return rx < ry end
        return x.key < y.key
    end)
    for _, it in ipairs(items) do it.place, it.placeLong = placeTag(b, it.key) end
    if b.pick and not index[b.pick] then b.pick = nil end
    P.poolList:SetItems(items, true)
    P.pool.count:SetText(tostring(#items), "dim")
    P.poolEmpty:SetShown(#items == 0)

    layoutGrid()
    for g = 1, b.G do
        local f = P.groups[g]
        local n = 0
        for i = 1, 5 do
            local k = b.slots[g][i]
            if k then n = n + 1 end
            updateSlot(f.slots[i], k, b.pick)
        end
        f.count:SetText(n .. "/5")
        UI:SetTextColor(f.count, n == 5 and "green" or "faint")
    end

    local bench = {}
    for i, k in ipairs(b.bench) do bench[i] = k end
    P.benchList:SetItems(bench, true)
    P.benchEmpty:SetShown(#bench == 0)
    P.benchCard:SetTitle(("Bench (%d)"):format(#bench))
    P.benchBtn:SetArmed(b.pick and ("Bench " .. U.ShortName(b.pick)) or nil)

    local placed = placedCount(b)
    P.grid.fill:SetText(("%d / %d"):format(placed, ev.size), placed >= ev.size and "green" or "yellow")
    P.grid.subtitle:SetText(b.dirty and T:Wrap("yellow", "unsaved changes") or "pick a name, then a slot")
    P.saveBtn:SetStyle(b.dirty and "primary" or "secondary")
    updateComposition(b)
end

local function buildRosterView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -VIEW_Y)
    v:SetPoint("BOTTOMRIGHT")
    v:Hide()
    P.rv = v

    local cp = UI:Card(v)
    cp:SetPoint("BOTTOMLEFT")
    cp:SetPoint("BOTTOMRIGHT")
    cp:SetHeight(COMP_H)
    P.comp = cp
    buildComposition(cp)

    local pool = UI:Card(v, { title = "Signed up", icon = "check" })
    pool:SetPoint("TOPLEFT")
    pool:SetPoint("BOTTOMLEFT", cp, "TOPLEFT", 0, 10)
    pool:SetWidth(POOL_W)
    pool.count = UI:Pill(pool.right, "", "dim", { height = 18, size = 10 })
    pool.count:SetPoint("RIGHT", pool.right, "RIGHT")
    P.pool = pool
    P.poolList = UI:List(pool.body, {
        rowHeight = 24, spacing = 2,
        createRow = createPoolRow, updateRow = updatePoolRow,
        onClick = function(item) pickKey(item.key) end,
        isSelected = function(item)
            local b = currentBuilder()
            return b ~= nil and b.pick == item.key
        end,
        onEnter = poolTooltip,
    })
    P.poolList:SetAllPoints(pool.body)
    P.poolEmpty = UI:Text(pool.body, 11, "faint")
    P.poolEmpty:SetPoint("TOPLEFT", pool.body, "TOPLEFT", 2, -4)
    P.poolEmpty:SetPoint("TOPRIGHT", pool.body, "TOPRIGHT", -2, -4)
    P.poolEmpty:SetWordWrap(true)
    P.poolEmpty:SetText("Nobody's signed up yet. Tumbleweeds.")
    P.poolEmpty:Hide()

    local bench = UI:Card(v, { title = "Bench", icon = "minus", accent = "dim" })
    bench:SetPoint("TOPRIGHT")
    bench:SetPoint("BOTTOMRIGHT", cp, "TOPRIGHT", 0, 10)
    bench:SetWidth(BENCH_W)
    P.benchCard = bench
    P.benchBtn = makeBenchTarget(bench.body)
    P.benchList = UI:List(bench.body, {
        rowHeight = 22, spacing = 2,
        createRow = createBenchRow, updateRow = updateBenchRow,
        onClick = function(key) benchClick(key) end,
        onEnter = benchTooltip,
    })
    P.benchList:SetPoint("TOPLEFT", P.benchBtn, "BOTTOMLEFT", 0, -6)
    P.benchList:SetPoint("BOTTOMRIGHT", bench.body, "BOTTOMRIGHT")
    P.benchEmpty = UI:Text(bench.body, 11, "faint")
    P.benchEmpty:SetPoint("TOPLEFT", P.benchBtn, "BOTTOMLEFT", 2, -10)
    P.benchEmpty:SetPoint("TOPRIGHT", P.benchBtn, "BOTTOMRIGHT", -2, -10)
    P.benchEmpty:SetWordWrap(true)
    P.benchEmpty:SetText("Nobody on the bench. Everyone's keen as.")
    P.benchEmpty:Hide()

    local grid = UI:Card(v, { title = "Groups", icon = "roster", subtitle = "pick a name, then a slot" })
    grid:SetPoint("TOPLEFT", pool, "TOPRIGHT", 10, 0)
    grid:SetPoint("BOTTOMRIGHT", bench, "BOTTOMLEFT", -10, 0)
    grid.fill = UI:Pill(grid.right, "", "green", { height = 18, size = 10, tooltip = "Placed in groups against the raid size." })
    grid.fill:SetPoint("RIGHT", grid.right, "RIGHT")
    P.grid = grid
    local sc, content = UI:Scroll(grid.body)
    sc:SetAllPoints(grid.body)
    P.gridScroll, P.gridContent = sc, content
    P.groups = {}
    for g = 1, 8 do P.groups[g] = makeGroup(content, g) end
    sc:HookScript("OnSizeChanged", function() GF:Safe("raids:grid", layoutGrid) end)
end

-------------------------------------------------------------------------------
-- Raid tools (officers, raid lead, assists)
-------------------------------------------------------------------------------
--- What the tools act on: the builder's working copy when it has unsaved changes.
local function toolsLineup(ev)
    local b = S.builders[ev.id]
    if b and b.dirty then return builderLineup(b) end
    return R:Lineup(ev.id)
end

local function doInvite(id)
    local ok, n, left = R:InviteSigned(id)
    if not ok then
        fail(n)
        return
    end
    local text = ("Inviting %d %s."):format(n, U.Plural(n, "legend"))
    if left and left > 0 then text = text .. (" %d more waiting on a spot."):format(left) end
    toast("Invites going out", text, "green", "roster")
end

local function doApply(id)
    local ev = R:Get(id)
    if not ev then return end
    local ok, err = R:ApplyGroups(id, toolsLineup(ev))
    if not ok then fail(err) end
end

local function doPost(id)
    local ev = R:Get(id)
    if not ev then return end
    local ok, err = R:PostLineup(id, toolsLineup(ev))
    if not ok then fail(err) end
end

local function openToolsMenu(anchor)
    local ev = selectedEvent()
    if not ev then return end
    local online = #R:InviteCandidates(ev.id)
    local placed = R.LineupCount(toolsLineup(ev))
    local chat = API.InRaid() and "raid" or "party"
    UI:OpenMenu(anchor, {
        { text = "Raid tools", title = true },
        { text = ("Invite the signed (%d online)"):format(online), icon = "plus", func = function() doInvite(ev.id) end },
        { text = ("Apply groups (%d placed)"):format(placed), icon = "roster", func = function() doApply(ev.id) end },
        { text = ("Post lineup to %s chat"):format(chat), icon = "megaphone", func = function() doPost(ev.id) end },
    }, { width = 230, point = "TOPRIGHT", relPoint = "BOTTOMRIGHT" })
end

local function layoutToolbar(rosterMode)
    local anchor = P.toolsBtn:IsShown() and P.toolsBtn or nil
    for _, b in ipairs({ P.saveBtn, P.autoBtn, P.clearBtn }) do
        b:ClearAllPoints()
        if rosterMode then
            if anchor then
                b:SetPoint("RIGHT", anchor, "LEFT", -6, 0)
            else
                b:SetPoint("TOPRIGHT", P.banner, "BOTTOMRIGHT", 0, -11)
            end
            anchor = b
            b:Show()
        else
            b:Hide()
        end
    end
end

-------------------------------------------------------------------------------
-- Raid editor (a sheet over the page: it needs dropdowns, so not UI:Modal)
-------------------------------------------------------------------------------
local function dayKey(t) return t.year * 10000 + t.month * 100 + t.day end
local function dateLabel(t) return ("%s %d %s"):format(DOW_NAME[t.wday] or "?", t.day, MON_NAME[t.month] or "?") end

local function splitDay(v) return floor(v / 10000), floor(v / 100) % 100, v % 100 end

local function editorTime()
    if type(E.day) ~= "number" then return nil end
    local y, m, d = splitDay(E.day)
    return R.LocalEpoch(y, m, d, E.hour or 19, E.min or 30)
end

local function defaultDay()
    local t = R.DateParts(now())
    if not t then return nil end
    if t.hour >= 18 then t = R.DateParts(now() + 86400) or t end
    return dayKey(t)
end

local function dateItems()
    local out = {}
    local today = R.DateParts(now())
    if not today then return out end
    local noon = R.LocalEpoch(today.year, today.month, today.day, 12, 0) or now()
    local have = {}
    for i = 0, 27 do
        local t = R.DateParts(noon + i * 86400)
        if t then
            local key = dayKey(t)
            have[key] = true
            local suffix = (i == 0 and "  (today)") or (i == 1 and "  (tomorrow)") or ""
            out[#out + 1] = { value = key, text = dateLabel(t) .. suffix }
        end
    end
    if type(E.day) == "number" and not have[E.day] then
        -- editing a raid outside the next four weeks keeps its own date on the list
        local y, m, d = splitDay(E.day)
        local ts = R.LocalEpoch(y, m, d, 12, 0)
        local t = ts and R.DateParts(ts)
        if t then tinsert(out, 1, { value = E.day, text = dateLabel(t) }) end
    end
    return out
end

local function hourItems()
    local out = {}
    -- afternoon first: raid nights live in the top of the list
    for i = 0, 23 do
        local h = (12 + i) % 24
        local h12 = h % 12
        if h12 == 0 then h12 = 12 end
        out[#out + 1] = { value = h, text = h12 .. (h < 12 and "am" or "pm") }
    end
    return out
end

--- Quarter hours, plus a raid's own odd minute when editing one (so saving an edit never
-- quietly moves the start time).
local function minuteItems()
    local out = {}
    for m = 0, 45, 15 do out[#out + 1] = { value = m, text = (":%02d"):format(m) } end
    if type(E.min) == "number" and E.min % 15 ~= 0 then
        tinsert(out, floor(E.min / 15) + 2, { value = E.min, text = (":%02d"):format(E.min) })
    end
    return out
end

local function durationItems()
    local out = {
        { value = 3600, text = "1 hour" }, { value = 5400, text = "1h 30m" }, { value = 7200, text = "2 hours" },
        { value = 9000, text = "2h 30m" }, { value = 10800, text = "3 hours" }, { value = 12600, text = "3h 30m" },
        { value = 14400, text = "4 hours" }, { value = 18000, text = "5 hours" },
    }
    local found = false
    for _, it in ipairs(out) do if it.value == E.duration then found = true end end
    if not found and type(E.duration) == "number" then tinsert(out, 1, { value = E.duration, text = U.Duration(E.duration) }) end
    return out
end

local function srItems()
    local out = { { value = 0, text = "No soft res" } }
    for n = 1, 3 do out[#out + 1] = { value = n, text = n .. " per player" } end
    if type(E.sr) == "number" and E.sr > 3 then out[#out + 1] = { value = E.sr, text = E.sr .. " per player" } end
    return out
end

local function repeatItems()
    local out = { { value = 1, text = "Just this once" } }
    for n = 2, 8 do out[#out + 1] = { value = n, text = ("Weekly, %d weeks"):format(n) } end
    return out
end

local function instanceItems()
    local out = {}
    for _, inst in ipairs(R.INSTANCES) do
        local size = inst.size and ("  " .. T:Wrap("faint", inst.size .. "-man")) or ""
        out[#out + 1] = { value = inst.name, text = inst.name .. size, color = inst.color }
    end
    return out
end

local function sizeItems()
    local out = {}
    for _, n in ipairs(R.SIZES) do out[#out + 1] = { value = n, text = n .. "-man" } end
    return out
end

local function editorPreview()
    if not editor then return end
    local d = editor.dialog
    local inst = R.InstanceInfo(E.instance)
    if inst.size then
        E.size = inst.size
        d.size:Hide()
        d.sizeFixed:SetText(inst.size .. "-MAN")
        d.sizeFixed:Show()
    else
        d.size:Show()
        d.size:Refresh()
        d.sizeFixed:Hide()
    end
    local ts = editorTime()
    if not ts then
        d.preview:SetText("")
        return
    end
    local txt = U.DateTime(ts) .. " - " .. timeOf(ts + (E.duration or R.DEFAULT_DURATION))
    if not E.id and (E.weeks or 1) > 1 then txt = txt .. ("\nthen weekly - %d raids all up"):format(E.weeks) end
    if ts < now() then txt = T:Wrap("red", "That's in the past, legend.") end
    d.preview:SetText(txt)
end

--- Small gold Friz field label, the way the game labels its own forms.
local function editorLabel(parent, text, x, y)
    local fs = UI:Text(parent, 10, REST_GOLD, "ui")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function editorSave()
    local d = editor.dialog
    local ts = editorTime()
    if not ts then
        fail("Pick a date and a start time.")
        return
    end
    if not E.id and ts < now() - 300 then
        fail("Can't put a raid in the past, legend.")
        return
    end
    local fields = {
        title = d.titleBox:GetText(), instance = E.instance, size = E.size, time = ts,
        duration = E.duration, srLimit = E.sr, notes = d.notes:GetText(),
    }
    if E.id then
        local ok, err = R:UpdateEvent(E.id, fields)
        if not ok then
            fail(err)
            return
        end
        closeEditor()
        toast("Raid updated", "Changes are out to the neighbourhood.", "green", "calendar")
        return
    end
    local ok, res = R:CreateEvent(fields, E.weeks)
    if not ok then
        fail(res)
        return
    end
    closeEditor()
    S.selected = res[1]
    local ev = R:Get(res[1])
    local title = ev and ev.title or "The raid"
    local text = #res > 1 and ("%s is on for the next %d weeks. Now go hassle people."):format(title, #res)
        or ("%s is on the calendar. Now go hassle people."):format(title)
    toast("Raid's up", text, "green", "calendar")
    refreshAll()
end

local function editorCallOff()
    local id, cancelled = E.id, E.cancelled
    if not id then return end
    if cancelled then
        local ok, err = R:SetCancelled(id, false)
        if not ok then fail(err) return end
        closeEditor()
        toast("Back on", "The raid's back on. Rally the troops.", "green", "calendar")
        return
    end
    UI:Confirm("Call it off?", "Everyone who answered will see it's off. You can put it back on later.", function()
        local ok, err = R:SetCancelled(id, true)
        if not ok then fail(err) return end
        closeEditor()
        toast("Called off", "Raid's off. Back to the servo.", "yellow", "calendar")
    end, "Call it off", "red")
end

local function editorDelete()
    local id = E.id
    if not id then return end
    UI:Confirm("Bin it?", "Deletes this raid and every answer to it. No take-backs.", function()
        local ok, err = R:DeleteEvent(id)
        if not ok then fail(err) return end
        closeEditor()
        if S.selected == id then S.selected = nil end
        S.builders[id] = nil
        refreshAll()
    end, "Delete", "red")
end

local function buildEditor()
    local ov = CreateFrame("Frame", nil, P)
    ov:SetAllPoints(P)
    ov:SetFrameLevel(P:GetFrameLevel() + 60)
    ov:EnableMouse(true)
    ov:EnableMouseWheel(true)
    ov:SetScript("OnMouseWheel", function() end)
    ov.dim = ov:CreateTexture(nil, "BACKGROUND")
    ov.dim:SetAllPoints()
    ov.dim:SetColorTexture(0, 0, 0, 0.62)
    ov:Hide()

    -- a floating sheet in the game's own dress: slate under a gold frame, like the kit's modals
    local d = UI:Panel(ov, C.bg1, false)
    d:SetSize(480, 440)
    d:SetPoint("CENTER", 0, 6)
    UI:Shadow(d, 16)
    ov.dialog = d
    d.stone = tiled(d, T.tex.stone, 3, "BACKGROUND", 1)
    d.stone:SetVertexColor(0.55, 0.6, 0.57, 0.45)
    d.rim = d:CreateTexture(nil, "OVERLAY", nil, 7)
    d.rim:SetPoint("TOPLEFT", -5, 5)
    d.rim:SetPoint("BOTTOMRIGHT", 5, -5)
    UI.Sliced(d.rim, T.tex.frameGold, 16)
    -- road-works tape just inside the frame (the guild's sign-shop touch)
    d.tape = d:CreateTexture(nil, "ARTWORK")
    d.tape:SetTexture(T.tex.hazard, "REPEAT", "REPEAT")
    d.tape:SetPoint("TOPLEFT", 4, -4)
    d.tape:SetPoint("TOPRIGHT", -4, -4)
    d.tape:SetHeight(5)
    d.tape:SetTexCoord(0, 472 / 24, 0, 5 / 24)
    d.tape:SetAlpha(0.85)
    d.title = UI:Text(d, 20, "wowGold", "title")
    d.title:SetPoint("TOPLEFT", 20, -20)
    if d.title.SetShadowOffset then
        d.title:SetShadowOffset(2, -2)
        d.title:SetShadowColor(0, 0, 0, 0.9)
    end
    d.sub = UI:Text(d, 12, "dim")
    d.sub:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -4)

    local L, R2, W1 = 20, 248, 212
    editorLabel(d, "Title", L, -72)
    d.titleBox = UI:Input(d, { placeholder = "Leave blank to use the raid's name", max = 40, width = 440 })
    d.titleBox:SetPoint("TOPLEFT", L, -86)

    editorLabel(d, "Raid", L, -122)
    d.inst = UI:Dropdown(d, {
        width = W1, items = instanceItems, get = function() return E.instance end,
        set = function(v)
            E.instance = v
            local inst = R.InstanceInfo(v)
            if inst.size then E.size = inst.size end
            editorPreview()
        end,
    })
    d.inst:SetPoint("TOPLEFT", L, -136)
    editorLabel(d, "Size", R2, -122)
    d.size = UI:Dropdown(d, {
        width = W1, items = sizeItems, get = function() return E.size end,
        set = function(v) E.size = v; editorPreview() end,
    })
    d.size:SetPoint("TOPLEFT", R2, -136)
    d.sizeFixed = UI:Text(d, 14, "text", "num")
    d.sizeFixed:SetPoint("TOPLEFT", R2 + 2, -142)

    editorLabel(d, "Date", L, -172)
    d.date = UI:Dropdown(d, {
        width = W1, items = dateItems, get = function() return E.day end,
        set = function(v) E.day = v; editorPreview() end,
    })
    d.date:SetPoint("TOPLEFT", L, -186)
    editorLabel(d, "Start (your time)", R2, -172)
    d.hour = UI:Dropdown(d, {
        width = 104, items = hourItems, get = function() return E.hour end,
        set = function(v) E.hour = v; editorPreview() end,
    })
    d.hour:SetPoint("TOPLEFT", R2, -186)
    d.min = UI:Dropdown(d, {
        width = 102, items = minuteItems, get = function() return E.min end,
        set = function(v) E.min = v; editorPreview() end,
    })
    d.min:SetPoint("LEFT", d.hour, "RIGHT", 6, 0)

    editorLabel(d, "Run time", L, -222)
    d.dur = UI:Dropdown(d, {
        width = W1, items = durationItems, get = function() return E.duration end,
        set = function(v) E.duration = v; editorPreview() end,
    })
    d.dur:SetPoint("TOPLEFT", L, -236)
    editorLabel(d, "Soft reserves", R2, -222)
    d.sr = UI:Dropdown(d, {
        width = W1, items = srItems, get = function() return E.sr end,
        set = function(v) E.sr = v end,
    })
    d.sr:SetPoint("TOPLEFT", R2, -236)

    editorLabel(d, "Notes", L, -272)
    d.notes = UI:Input(d, { placeholder = "Bring flasks, bring snags, bring your A game.", max = 160, width = 440 })
    d.notes:SetPoint("TOPLEFT", L, -286)

    d.repLbl = editorLabel(d, "Repeat", L, -322)
    d.rep = UI:Dropdown(d, {
        width = W1, items = repeatItems, get = function() return E.weeks end,
        set = function(v) E.weeks = v; editorPreview() end,
    })
    d.rep:SetPoint("TOPLEFT", L, -336)
    d.previewLbl = editorLabel(d, "Shows up as", R2, -322)
    d.preview = UI:Text(d, 11, "dim")
    d.preview:SetPoint("TOPLEFT", R2, -340)
    d.preview:SetWidth(W1)
    d.preview:SetWordWrap(true)

    d.save = UI:Button(d, "Save", { style = "primary", icon = "check", height = 28, minWidth = 96, onClick = function() editorSave() end })
    d.save:SetPoint("BOTTOMRIGHT", -20, 18)
    d.cancel = UI:Button(d, "Cancel", { style = "ghost", height = 28, minWidth = 80, onClick = function() closeEditor() end })
    d.cancel:SetPoint("RIGHT", d.save, "LEFT", -8, 0)
    d.calloff = UI:Button(d, "Call it off", { style = "danger", icon = "close", height = 28, onClick = function() editorCallOff() end })
    d.calloff:SetPoint("BOTTOMLEFT", 20, 18)
    d.delete = UI:Button(d, "Delete", {
        style = "ghost", icon = "trash", height = 28, onClick = function() editorDelete() end,
        tooltip = { "Delete", { "Bins the raid and every answer. Calling it off is usually kinder." } },
    })
    d.delete:SetPoint("LEFT", d.calloff, "RIGHT", 8, 0)
    editor = ov
end

closeEditor = function()
    if not editor then return end
    local d = editor.dialog
    d.titleBox:ClearFocus()
    d.notes:ClearFocus()
    UI:CloseMenu()
    editor:Hide()
end

openEditor = function(id)
    if not R:IsOfficer() then
        fail("Only officers can put raids up or change them.")
        return
    end
    if not P then return end
    if not editor then buildEditor() end
    UI:CloseMenu()
    local d = editor.dialog
    for k in pairs(E) do E[k] = nil end
    local ev = id and R:Get(id)
    local cfgSR = GF.Roster and GF.Roster:Config().srLimit or 2
    if ev then
        local t = R.DateParts(ev.time)
        E.id, E.cancelled = ev.id, ev.cancelled
        E.instance = R.InstanceInfo(ev.instance).name
        E.size = ev.size
        E.day = t and dayKey(t) or defaultDay()
        E.hour = t and t.hour or 19
        E.min = t and t.min or 30
        E.duration = ev.duration
        E.sr = ev.srLimit or cfgSR
        E.weeks = 1
        d.title:SetText("Edit raid")
        d.sub:SetText("Changes go out to everyone. Lineup and answers stay put.")
        d.titleBox:SetText(ev.title)
        d.notes:SetText(ev.notes or "")
        d.calloff:SetText(ev.cancelled and "Put it back on" or "Call it off")
        d.calloff:SetStyle(ev.cancelled and "secondary" or "danger")
        d.calloff:Show()
        d.delete:Show()
        d.repLbl:Hide()
        d.rep:Hide()
    else
        E.instance, E.size = "Barrow Deeps", 10
        E.day, E.hour, E.min = defaultDay(), 19, 30
        E.duration, E.sr, E.weeks = R.DEFAULT_DURATION, cfgSR, 1
        d.title:SetText("New raid")
        d.sub:SetText("Put a night on the calendar. Times are in your local time.")
        d.titleBox:SetText("")
        d.notes:SetText("")
        d.calloff:Hide()
        d.delete:Hide()
        d.repLbl:Show()
        d.rep:Show()
    end
    d.titleBox:RefreshPlaceholder()
    d.notes:RefreshPlaceholder()
    for _, dd in ipairs({ d.inst, d.size, d.date, d.hour, d.min, d.dur, d.sr, d.rep }) do dd:Refresh() end
    editorPreview()
    editor:Show()
    UI:FadeIn(d, 0.12)
end

-------------------------------------------------------------------------------
-- Page
-------------------------------------------------------------------------------
local function applyLayout()
    local focus = S.tab == "roster" and P.detail:IsShown()
    P.left:SetShown(not focus)
    P.right:ClearAllPoints()
    if focus then
        P.right:SetPoint("TOPLEFT", P.body, "TOPLEFT", 0, 0)
    else
        P.right:SetPoint("TOPLEFT", P.left, "TOPRIGHT", GAP, 0)
    end
    P.right:SetPoint("BOTTOMRIGHT", P.body, "BOTTOMRIGHT", 0, 0)
end

--- What the 30 s ticker watches: how many raids are listed and what state the picked one
-- is in. When either changes (a raid goes live, wraps up, drops off the list) the whole
-- page refreshes, so answer buttons lock and the list tidies itself without a data change.
local function tickSig(listed)
    local ev = selectedEvent()
    local kind = "-"
    if ev then
        local _, _, k = countdown(ev)
        kind = k
    end
    return tostring(listed) .. ":" .. tostring(S.selected) .. ":" .. kind
end

local function defaultSelection(list)
    local cur = R:Current()
    if cur then return cur.id end
    local t = now()
    for _, ev in ipairs(list) do
        if not ev.cancelled and ev.time > t then return ev.id end
    end
    return list[1] and list[1].id or nil
end

refreshDetail = function()
    if not P then return end
    local ev = selectedEvent()
    local officer = R:IsOfficer()
    if S.tab == "roster" and not officer then S.tab = "signups" end
    if not ev then
        S.tab = "signups"
        P.detail:Hide()
        -- the list on the left already says the calendar's empty; this side says what's next
        P.detailEmpty:SetText(officer and "Nothing on the calendar. Hit New raid and get the lads organised."
            or "When an officer puts a raid up it lands here. Keep ya boots by the door.")
        P.detailEmpty:Show()
        applyLayout()
        return
    end
    P.detailEmpty:Hide()
    P.detail:Show()
    updateBanner(ev)
    shineBanner(ev.id)
    P.banner.edit:SetShown(officer)
    P.tabs.buttons[2]:SetShown(officer)
    P.tabs:Select(S.tab, true)
    P.toolsBtn:SetShown(R:CanManage() and not ev.cancelled)
    local roster = S.tab == "roster"
    layoutToolbar(roster)
    applyLayout()
    if roster then
        P.sv:Hide()
        P.rv:Show()
        refreshRoster()
    else
        P.rv:Hide()
        P.sv:Show()
        refreshMyPanel(ev)
        refreshSignupList()
    end
end

refreshAll = function()
    if not P then return end
    P.newBtn:SetShown(R:IsOfficer())
    local list = R:List()
    local listed = false
    for _, ev in ipairs(list) do
        if ev.id == S.selected then listed = true break end
    end
    if not listed and not (S.selected and R:Get(S.selected)) then S.selected = defaultSelection(list) end
    P.evList:SetItems(list, true)
    local upcoming, t = 0, now()
    for _, ev in ipairs(list) do
        if not ev.cancelled and ev.time > t then upcoming = upcoming + 1 end
    end
    P.left.count:SetText(tostring(upcoming), upcoming > 0 and "green" or "dim")
    if #list == 0 then
        local line = GF.Flavor.emptyStates.events
        if R:IsOfficer() then line = line .. "\n\nHit New raid up top to put one on." end
        P.evEmpty:SetText(line)
        P.evEmpty:Show()
    else
        P.evEmpty:Hide()
    end
    refreshDetail()
    P.tickSig = tickSig(#list)
end

selectEvent = function(id)
    if S.selected == id then return end
    S.selected = id
    UI:CloseMenu()
    P.evList:Refresh()
    refreshDetail()
    P.tickSig = tickSig(#P.evList.items)
end

selectTab = function(key)
    if key == "roster" and not R:IsOfficer() then key = "signups" end
    if S.tab == key then return end
    S.tab = key
    UI:CloseMenu()
    refreshDetail()
end

local function buildRight(page)
    local right = CreateFrame("Frame", nil, page.body)
    page.right = right
    local content = CreateFrame("Frame", nil, right)
    content:SetAllPoints(right)
    page.detail = content
    page.detailEmpty = UI:Empty(right, "", "calendar")
    page.detailEmpty:Hide()
    right:HookScript("OnSizeChanged", function(_, w) fitEmpty(page.detailEmpty, w) end)

    page.banner = buildBanner(content)
    page.tabs = UI:Tabs(content, {
        { key = "signups", text = "Signups", icon = "check" },
        { key = "roster", text = "Roster builder", icon = "roster" },
    }, function(key) selectTab(key) end)
    page.tabs:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -TABS_Y)
    local line = UI:Divider(content, "lineSoft")
    line:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(TABS_Y + 29))
    line:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(TABS_Y + 29))

    page.toolsBtn = UI:Button(content, "Raid tools", {
        style = "warn", icon = "bolt", height = 24, onClick = function(btn) openToolsMenu(btn) end,
        tooltip = { "Raid tools", { "Invite everyone who said yeah, sort the groups, post the lineup. Officers, raid lead and assists." } },
    })
    page.toolsBtn:SetPoint("TOPRIGHT", page.banner, "BOTTOMRIGHT", 0, -11)
    page.saveBtn = UI:Button(content, "Save", {
        style = "secondary", icon = "check", height = 24, onClick = function() saveLineup() end,
        tooltip = { "Save lineup", { "Saves the groups and bench into the raid for everyone." } },
    })
    page.autoBtn = UI:Button(content, "Auto-fill", {
        style = "secondary", icon = "bolt", height = 24, onClick = function() autoFill() end,
        tooltip = { "Auto-fill", { "Yeahs first, then lates, first in best dressed.", "Tanks up front, a healer in every group, melee together, casters together." } },
    })
    page.clearBtn = UI:Button(content, "Clear", {
        style = "ghost", icon = "trash", height = 24, onClick = function() clearLineup() end,
        tooltip = "Empty every group and the bench.",
    })

    buildSignupsView(content)
    buildRosterView(content)
end

local function build(page)
    P = page
    page.header = UI:PageHeader(page, "Raid Nights", "Sign up, show up, don't stand in the fire.")
    page.newBtn = page.header:AddAction(UI:Button(page.header, "New raid", {
        style = "primary", icon = "plus", onClick = function() openEditor(nil) end,
        tooltip = { "New raid", { "Put a raid night on the calendar. Officers only." } },
    }))
    local body = CreateFrame("Frame", nil, page)
    body:SetPoint("TOPLEFT", page.header, "BOTTOMLEFT", 0, -12)
    body:SetPoint("BOTTOMRIGHT")
    page.body = body
    buildLeft(page)
    buildRight(page)
    body:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then page.left:SetWidth(U.Clamp(floor(w * 0.36), 250, 330)) end
    end)
    applyLayout()
end

local function startTicker(page)
    if page.ticker then return end
    page.ticker = GF:Ticker(30, function()
        if not page:IsVisible() then
            if page.ticker then page.ticker:Cancel() end
            page.ticker = nil
            return
        end
        if tickSig(#R:List()) ~= page.tickSig then
            refreshAll()
            return
        end
        page.evList:Refresh()
        local ev = selectedEvent()
        if ev and page.detail:IsShown() then updateBanner(ev) end
    end)
end

local function onShow(page, arg)
    if type(arg) == "string" and R:Get(arg) then
        if S.selected ~= arg then S.tab = "signups" end
        S.selected = arg
    end
    refreshAll()
    startTicker(page)
end

local function onHide(page)
    if page.ticker then
        page.ticker:Cancel()
        page.ticker = nil
    end
    page.shineFor = nil         -- the sign shines again next time the page opens
    closeEditor()
    UI:CloseMenu()
end

local function badge()
    local n = R:Unanswered(14)
    return n > 0 and n or nil
end

UI:RegisterPage({
    key = "raids", title = "Raid Nights", subtitle = "Sign up, show up, don't stand in the fire.",
    icon = "calendar", group = "raid", order = 10,
    build = build, onShow = onShow, onHide = onHide, badge = badge,
})

-------------------------------------------------------------------------------
-- Keep the page, the nav badge and the header pill fresh
-------------------------------------------------------------------------------
--- Only while the window is open (ShowPage refreshes the nav when it opens). On the raids
-- page RefreshPage re-runs onShow and the nav; anywhere else only the badge can change.
local function refreshVisible()
    if not UI:IsMainShown() then return end
    if UI:CurrentPage() == "raids" then UI:RefreshPage("raids") else UI:RefreshNav() end
end

GF:On("GF_RAIDS_CHANGED", function()
    GF:Debounce("raids-ui", 0.15, function()
        refreshVisible()
        if UI.UpdateChrome and UI:IsMainShown() then UI:UpdateChrome() end
    end)
end)
GF:On("GF_ROSTER_UPDATED", function() GF:Debounce("raids-ui-roster", 1, refreshVisible) end)
GF:On("GF_GROUP_UPDATED", function() GF:Debounce("raids-ui-group", 0.5, refreshVisible) end)

GF:RegisterSlash("raids", function() UI:OpenMain("raids") end, "open Raid Nights")
