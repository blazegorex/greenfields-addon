--[[ Greenfields - Modules/SoftRes.lua
     Soft reserves: sessions, reserves, the "+N" plus rule, whisper intake for raiders
     without the addon, and CSV import/export in softres.it's format.

     Two replicated datasets, both mirrored to the current group so PUG raiders running
     Greenfields see them as well:
       srsessions/ss  {title, instance, eventId, host, limit, locked, plus, created, closed}
       reserves/sr    id = sessionId.."|"..playerKey
                      {session, player, class, items = {itemIDs}, t, note?, pb? = {[itemID] = plus}}
     Raiders outside the guild also hand their picks to the host (op "SR") so the host
     republishes them to the guild. Raiders without the addon whisper "!sr <link or id>".

     Public:   GF.SR:ActiveSession()  :ReservesFor(itemID)  :MyReserves()
     Internal: Sessions, Session, Reserves, Index, Limit, IsOpen, CanHost, CanControl,
               CanEditReserves, PlusFor, AddReserve, RemoveReserve, WriteReserve, Start,
               SetLocked, Close, ClearAll, ExportCSV, ImportCSV, Announce, AddLinkTarget.
     Fires GF_SR_UPDATED (debounced) whenever sessions, reserves or loot history change. ]]

local _, GF = ...
local API, U, T = GF.API, GF.Util, GF.Theme
local Store, Comm = GF.Store, GF.Comm

local SR = GF:NewModule("SoftRes")
GF.SR = SR

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local floor, max, min = math.floor, math.max, math.min
local sort, concat = table.sort, table.concat

local SESSIONS, RESERVES = "srsessions", "reserves"
local MAX_LIMIT = 6            -- hard cap on reserves per player, whatever the session says
local ACTIVE_HOURS = 18        -- an unclosed session older than this counts as abandoned
local NOTE_MAX = 60
local TITLE_MAX = 48

SR.MAX_LIMIT = MAX_LIMIT

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------
local CLASS_SET = {}
for _, c in ipairs(API.CLASSES) do CLASS_SET[c] = true end

local function validClass(c)
    if type(c) == "string" and CLASS_SET[c] then return c end
    return nil
end

local function now() return API.ServerTime() end

local function sessionStop(s)
    return s.closed or ((s.created or 0) + ACTIVE_HOURS * 3600)
end

local function catalogEntry(itemID)
    if GF.Loot and GF.Loot.CatalogEntry then
        local ok, e = GF:Safe("sr:catalog", GF.Loot.CatalogEntry, GF.Loot, itemID)
        if ok and type(e) == "table" then return e end
    end
    return nil
end

-- itemID -> GetTime() of the last load request. Every refresh asks for names, and an item
-- the server can't load answers with another GET_ITEM_INFO_RECEIVED, so without a throttle
-- a bogus ID (typo'd whisper, junk CSV row) would keep the page refreshing forever.
local asked = {}

--- Display name for an item: client cache first, then the learned catalogue name.
local function itemName(itemID)
    if type(itemID) ~= "number" then return nil end
    local n = API.ItemName(itemID)
    if type(n) == "string" and n ~= "" and API.Readable(n) then return n end
    local e = catalogEntry(itemID)
    if e and type(e.n) == "string" then return e.n end
    local t = API.Time()
    if not asked[itemID] or t - asked[itemID] > 30 then
        asked[itemID] = t
        API.RequestItem(itemID)
    end
    return nil
end
SR.ItemName = itemName

-------------------------------------------------------------------------------
-- Caches (rebuilt lazily; everything is invalidated on any relevant change)
-------------------------------------------------------------------------------
local cache = {}

function SR:Invalidate()
    cache = {}
    GF:Debounce("sr-updated", 0.25, function() GF:Fire("GF_SR_UPDATED") end)
end

-------------------------------------------------------------------------------
-- Datasets
-------------------------------------------------------------------------------
-- Officers may edit any session; otherwise only the host, who may never hand it over.
local function sessionCanWrite(author, id, new, old)
    if GF.Roster:IsOfficer(author) then return true end
    if new then
        return type(new) == "table" and author == new.host and (old == nil or author == old.host)
    end
    return old ~= nil and author == old.host
end

local function shortString(v, n)
    return v == nil or (type(v) == "string" and #v <= n)
end

local function validSession(id, d)
    if type(id) ~= "string" or type(d) ~= "table" then return false end
    if type(d.host) ~= "string" or type(d.created) ~= "number" then return false end
    if d.limit ~= nil and (type(d.limit) ~= "number" or d.limit < 1 or d.limit > MAX_LIMIT) then return false end
    if not shortString(d.title, TITLE_MAX * 2) or not shortString(d.instance, 80) or not shortString(d.eventId, 80) then return false end
    return true
end

-- A player edits their own reserve while the session is open; the host and officers
-- may edit anyone's. A reserve for a session we haven't synced yet is accepted only
-- from its own player (the session doc usually lands a moment later).
local function reserveCanWrite(author, id, new, old)
    local d = new or old
    if type(d) ~= "table" or type(d.session) ~= "string" then return false end
    if GF.Roster:IsOfficer(author) then return true end
    local sess = Store:Get(SESSIONS, d.session)
    if sess and author == sess.host then return true end
    if author ~= d.player then return false end
    if old and old.player ~= author then return false end
    if not sess then return true end
    return not sess.locked and not sess.closed
end

local function validReserve(id, d)
    if type(d) ~= "table" or type(d.session) ~= "string" or type(d.player) ~= "string" then return false end
    if id ~= d.session .. "|" .. d.player then return false end
    if type(d.items) ~= "table" then return false end
    local sess = Store:Get(SESSIONS, d.session)
    local limit = sess and SR:Limit(sess) or MAX_LIMIT
    local n = 0
    for _, v in pairs(d.items) do
        if type(v) ~= "number" then return false end
        n = n + 1
    end
    if d.note ~= nil and (type(d.note) ~= "string" or #d.note > NOTE_MAX * 2) then return false end
    if d.class ~= nil and type(d.class) ~= "string" then return false end
    if d.pb ~= nil then
        if type(d.pb) ~= "table" then return false end
        local m = 0
        for k, v in pairs(d.pb) do
            m = m + 1
            if type(k) ~= "number" or type(v) ~= "number" or m > MAX_LIMIT * 2 then return false end
        end
    end
    return n <= limit
end

Store:Define({
    name = SESSIONS, code = "ss", owner = "shared", mirrorGroup = true, keepDays = 240,
    canWrite = sessionCanWrite, validate = validSession,
    onChange = function() SR:Invalidate() end,
})

Store:Define({
    name = RESERVES, code = "sr", owner = "shared", mirrorGroup = true, keepDays = 240,
    canWrite = reserveCanWrite, validate = validReserve,
    onChange = function() SR:Invalidate() end,
})

-------------------------------------------------------------------------------
-- Sessions
-------------------------------------------------------------------------------
--- All sessions, newest first. Each entry is a copy with .id set.
function SR:Sessions()
    if cache.sessions then return cache.sessions end
    local out = {}
    for id, d in pairs(Store:All(SESSIONS)) do
        if type(d) == "table" and type(d.created) == "number" then
            local s = U.Copy(d)
            s.id = id
            out[#out + 1] = s
        end
    end
    sort(out, function(a, b)
        if a.created ~= b.created then return a.created > b.created end
        return tostring(a.id) > tostring(b.id)
    end)
    cache.sessions = out
    return out
end

function SR:Session(id)
    if type(id) ~= "string" then return nil end
    for _, s in ipairs(self:Sessions()) do
        if s.id == id then return s end
    end
    return nil
end

function SR:IsOpen(s, at)
    if type(s) ~= "table" or s.closed then return false end
    return ((at or now()) - (s.created or 0)) < ACTIVE_HOURS * 3600
end

function SR:Limit(s)
    local l = type(s) == "table" and tonumber(s.limit) or nil
    if not l then l = GF.Roster:Config().srLimit or 2 end
    return U.Clamp(floor(l), 1, MAX_LIMIT)
end

--- The session that matters to me right now: my own, else one hosted by someone in my
-- group, else one linked to tonight's raid, else the newest open one in the guild.
function SR:ActiveSession()
    local t = now()
    if cache.activeAt and t - cache.activeAt < 30 then return cache.active end
    local me = API.MyKey()
    local currentEvent
    if GF.Raids and GF.Raids.Current then
        local ok, ev = GF:Safe("sr:raids", GF.Raids.Current, GF.Raids)
        if ok and type(ev) == "table" then currentEvent = ev.id end
    end
    local best, bestScore
    for _, s in ipairs(self:Sessions()) do
        if self:IsOpen(s, t) then
            local score = 1
            if me and s.host == me then
                score = 4
            elseif GF.Roster:InGroup(s.host) then
                score = 3
            elseif currentEvent and s.eventId == currentEvent then
                score = 2
            end
            -- sessions are newest first, so a tie keeps the newer one
            if not best or score > bestScore then best, bestScore = s, score end
        end
    end
    cache.active, cache.activeAt = best, t
    return best
end

function SR:CanHost(key)
    key = key or API.MyKey()
    if not key then return false end
    return GF.Roster:CanManage(key) and true or false
end

--- Host-level control (lock, close, import, edit anyone's reserves).
function SR:CanControl(s, key)
    key = key or API.MyKey()
    if type(s) ~= "table" or not key then return false end
    return key == s.host or GF.Roster:IsOfficer(key)
end

function SR:IsHost(s, key)
    key = key or API.MyKey()
    return type(s) == "table" and key ~= nil and s.host == key
end

--- May `key` change their own picks in this session?
function SR:CanEditReserves(s, key)
    if not self:IsOpen(s) then return false end
    if self:CanControl(s, key) then return true end
    return not s.locked
end

-------------------------------------------------------------------------------
-- Reserves
-------------------------------------------------------------------------------
--- Reserve docs of one session (copies with .id), sorted by player.
function SR:Reserves(sid)
    if type(sid) ~= "string" then
        local s = self:ActiveSession()
        sid = s and s.id
    end
    if not sid then return {} end
    cache.res = cache.res or {}
    if cache.res[sid] then return cache.res[sid] end
    local out = {}
    for id, d in pairs(Store:All(RESERVES)) do
        if type(d) == "table" and d.session == sid and type(d.player) == "string" and type(d.items) == "table" then
            -- remote docs aren't deduped on the way in; one player listed twice would
            -- show the item as "contested" against themselves
            local items, seen = {}, {}
            for _, v in ipairs(d.items) do
                if type(v) == "number" and not seen[v] then
                    seen[v] = true
                    items[#items + 1] = v
                end
            end
            out[#out + 1] = {
                id = id, session = sid, player = d.player, items = items, t = d.t, note = d.note, pb = d.pb,
                class = validClass(d.class) or GF.Roster:Class(d.player),
            }
        end
    end
    sort(out, function(a, b) return a.player < b.player end)
    cache.res[sid] = out
    return out
end

-------------------------------------------------------------------------------
-- Plus rule: +N = consecutive earlier sessions (same raid) in which the player
-- reserved this item and didn't walk away with it. Sessions they have no reserve in
-- (a night off, or the guild's other raid group) are skipped rather than resetting it;
-- changing the pick or winning the item resets it.
-------------------------------------------------------------------------------
local function winsIndex()
    if cache.wins then return cache.wins end
    local w = {}
    for _, e in pairs(Store:All("loot")) do
        if type(e) == "table" and type(e.itemID) == "number" and type(e.winner) == "string" then
            local k = e.itemID .. "|" .. e.winner
            local list = w[k]
            if not list then list = {}; w[k] = list end
            list[#list + 1] = { s = e.session, t = tonumber(e.t) or 0 }
        end
    end
    cache.wins = w
    return w
end

local function wonIn(s, player, itemID)
    local list = winsIndex()[itemID .. "|" .. player]
    if not list then return false end
    local stop = sessionStop(s)
    for _, e in ipairs(list) do
        if e.s == s.id or (e.t >= (s.created or 0) and e.t <= stop) then return true end
    end
    return false
end

function SR:PlusFor(s, player, itemID, reserve)
    if type(s) ~= "table" or not s.plus or type(s.id) ~= "string" or type(player) ~= "string" or type(itemID) ~= "number" then return 0 end
    local key = s.id .. "|" .. player .. "|" .. itemID
    cache.plus = cache.plus or {}
    if cache.plus[key] then return cache.plus[key] end
    local n = 0
    for _, prev in ipairs(self:Sessions()) do
        if prev.id ~= s.id and (prev.created or 0) < (s.created or 0)
            and (not s.instance or not prev.instance or prev.instance == s.instance) then
            if wonIn(prev, player, itemID) then break end
            local r = Store:Get(RESERVES, prev.id .. "|" .. player)
            if type(r) == "table" then
                if not (type(r.items) == "table" and U.Contains(r.items, itemID)) then break end
                n = n + 1
            end
        end
    end
    -- an imported softres.it sheet may carry its own plus count; honour it as a floor
    local pb = reserve and type(reserve.pb) == "table" and tonumber(reserve.pb[itemID]) or 0
    n = max(n, floor(pb or 0))
    cache.plus[key] = n
    return n
end

-------------------------------------------------------------------------------
-- Index of a session: byItem[itemID] = {{player, class, plus}...}, byPlayer[key] = reserve
-------------------------------------------------------------------------------
local function buildIndex(s)
    local idx = { byItem = {}, byPlayer = {}, items = {}, players = 0, count = 0 }
    for _, r in ipairs(SR:Reserves(s.id)) do
        if #r.items > 0 then
            idx.byPlayer[r.player] = r
            idx.players = idx.players + 1
        end
        for _, itemID in ipairs(r.items) do
            local list = idx.byItem[itemID]
            if not list then
                list = {}
                idx.byItem[itemID] = list
                idx.items[#idx.items + 1] = itemID
            end
            list[#list + 1] = { player = r.player, class = r.class, plus = SR:PlusFor(s, r.player, itemID, r) }
            idx.count = idx.count + 1
        end
    end
    for _, list in pairs(idx.byItem) do
        sort(list, function(a, b)
            if a.plus ~= b.plus then return a.plus > b.plus end
            return a.player < b.player
        end)
    end
    return idx
end

function SR:Index(s)
    s = s or self:ActiveSession()
    if type(s) ~= "table" or not s.id then return nil end
    cache.idx = cache.idx or {}
    local idx = cache.idx[s.id]
    if not idx then
        idx = buildIndex(s)
        cache.idx[s.id] = idx
    end
    return idx
end

-------------------------------------------------------------------------------
-- Public API (other modules call these; they never error and default to empty)
-------------------------------------------------------------------------------
function SR:ReservesFor(itemID)
    local id = API.ItemID(itemID)
    if not id then return {} end
    local idx = self:Index()
    local list = idx and idx.byItem[id]
    local out = {}
    if list then
        for i, e in ipairs(list) do out[i] = { player = e.player, class = e.class, plus = e.plus } end
    end
    return out
end

function SR:MyReserves()
    local out = {}
    local idx = self:Index()
    local r = idx and idx.byPlayer[API.MyKey() or ""]
    if r then
        for i, id in ipairs(r.items) do out[i] = id end
    end
    return out
end

-------------------------------------------------------------------------------
-- Writing reserves
-------------------------------------------------------------------------------
--- WriteReserve(session, playerKey, items, class, extra{note, pb}) -> ok, err
-- An empty item list removes the reserve.
function SR:WriteReserve(s, player, items, class, extra)
    if type(s) ~= "table" or type(player) ~= "string" then return false, "no session" end
    local id = s.id .. "|" .. player
    local clean, seen = {}, {}
    for _, v in ipairs(items or {}) do
        local iid = API.ItemID(v)
        if iid and not seen[iid] then
            seen[iid] = true
            clean[#clean + 1] = iid
        end
    end
    if #clean > self:Limit(s) then return false, "limit" end
    local old = Store:Get(RESERVES, id)
    if #clean == 0 then
        if old then return Store:Delete(RESERVES, id) end
        return true
    end
    local doc = {
        session = s.id, player = player, items = clean, t = now(),
        -- Roster:Class can fall back to a peer's HELLO payload, which is anyone's guess
        class = validClass(class) or (old and validClass(old.class)) or validClass(GF.Roster:Class(player)),
    }
    local note = extra and extra.note or (old and old.note)
    if type(note) == "string" and note ~= "" then doc.note = note:sub(1, NOTE_MAX) end
    local pb = extra and extra.pb or (old and old.pb)
    if type(pb) == "table" and next(pb) ~= nil then doc.pb = U.Copy(pb) end
    return Store:Put(RESERVES, id, doc)
end

-- Raiders outside the guild can't reach guildies who aren't in the group, so they hand
-- their picks to the host, who republishes them guild-wide.
local function pushToHost(s, items)
    local me = API.MyKey()
    if not me or s.host == me or GF.Roster:IsMember(me) then return end
    Comm:Whisper(s.host, "SR", { s = s.id, i = items, c = API.UnitClassFile("player") }, "NORMAL")
end

--- AddReserve(itemOrLink) -> ok, message
function SR:AddReserve(item)
    local s = self:ActiveSession()
    if not s then return false, "There's no SR running right now." end
    local me = API.MyKey()
    if not me then return false, "Still waking up. Give it a sec." end
    if not self:CanEditReserves(s, me) then return false, "The SR is locked. Should've been quicker." end
    local itemID = API.ItemID(item)
    if not itemID then return false, "That's not an item. Shift-click one or paste an item ID." end
    local mine = self:MyReserves()
    if U.Contains(mine, itemID) then return false, "You've already got dibs on that one." end
    local limit = self:Limit(s)
    if #mine >= limit then return false, ("You're maxed out (%d). Drop one first."):format(limit) end
    mine[#mine + 1] = itemID
    local ok, err = self:WriteReserve(s, me, mine, API.UnitClassFile("player"))
    if not ok then return false, "Couldn't save that (" .. tostring(err) .. ")." end
    pushToHost(s, mine)
    return true
end

function SR:RemoveReserve(itemID)
    local s = self:ActiveSession()
    if not s then return false, "There's no SR running right now." end
    local me = API.MyKey()
    if not me or not self:CanEditReserves(s, me) then return false, "The SR is locked. You're stuck with it." end
    local keep = {}
    for _, id in ipairs(self:MyReserves()) do
        if id ~= itemID then keep[#keep + 1] = id end
    end
    local ok, err = self:WriteReserve(s, me, keep, API.UnitClassFile("player"))
    if not ok then return false, "Couldn't save that (" .. tostring(err) .. ")." end
    pushToHost(s, keep)
    return true
end

--- Host tool: wipe one player's picks.
function SR:ClearPlayer(s, player)
    if not self:CanControl(s) then return false, "Only the host can do that." end
    return self:WriteReserve(s, player, {})
end

-------------------------------------------------------------------------------
-- Session control (host / officers)
-------------------------------------------------------------------------------
local function updateSession(s, fn)
    local cur = type(s) == "table" and Store:Get(SESSIONS, s.id)
    if not cur then return false, "That session's gone walkabout." end
    local d = U.Copy(cur)
    fn(d)
    return Store:Put(SESSIONS, s.id, d)
end

--- Start{title, instance, eventId, limit, plus} -> ok, err, sessionId
function SR:Start(opts)
    opts = opts or {}
    local me = API.MyKey()
    if not me then return false, "Still waking up. Give it a sec." end
    if not self:CanHost(me) then return false, "Only officers and raid leaders can run an SR." end
    local t = now()
    -- one live session per host: close any I left open
    for _, s in ipairs(self:Sessions()) do
        if s.host == me and not s.closed then
            updateSession(s, function(d) d.closed = t end)
        end
    end
    local title = U.Trim(opts.title or ""):gsub("|", "")
    local instance = type(opts.instance) == "string" and opts.instance ~= "" and opts.instance:sub(1, 40) or nil
    if title == "" then title = (instance or "Raid night") .. " SR" end
    local doc = {
        title = title:sub(1, TITLE_MAX),
        instance = instance,
        eventId = type(opts.eventId) == "string" and opts.eventId or nil,
        host = me,
        limit = U.Clamp(floor(tonumber(opts.limit) or GF.Roster:Config().srLimit or 2), 1, MAX_LIMIT),
        locked = false,
        plus = opts.plus and true or nil,
        created = t,
    }
    local id = me .. "-" .. t
    local ok, err = Store:Put(SESSIONS, id, doc)
    if not ok then return false, tostring(err) end
    return true, nil, id
end

function SR:SetLocked(s, on)
    if not self:CanControl(s) then return false, "Only the host can lock it." end
    return updateSession(s, function(d) d.locked = on and true or false end)
end

function SR:SetPlus(s, on)
    if not self:CanControl(s) then return false, "Only the host can change that." end
    return updateSession(s, function(d) d.plus = on and true or nil end)
end

function SR:Close(s)
    if not self:CanControl(s) then return false, "Only the host can close it." end
    return updateSession(s, function(d) d.closed = now(); d.locked = true end)
end

--- Removes every reserve in the session.
function SR:ClearAll(s)
    if not self:CanControl(s) then return false, "Only the host can clear it." end
    local n = 0
    for _, r in ipairs(self:Reserves(s.id)) do
        if Store:Delete(RESERVES, r.id) then n = n + 1 end
    end
    return true, n
end

local function groupChat()
    local ch = API.GroupChannel()
    if ch then return ch end
    if API.InGuild() then return "GUILD" end
    return nil
end
SR.GroupChat = groupChat

--- Posts the "SR is open" line to the group (or guild when solo). Click-only.
function SR:Announce(s)
    s = s or self:ActiveSession()
    if not s then return false, "There's no SR running right now." end
    local ch = groupChat()
    if not ch then return false, "You're not in a group or a guild. Who are we telling?" end
    local limit = self:Limit(s)
    local msg = ("SR open: %s%s. %d %s each%s. Greenfields users: /gf sr. No addon? Whisper %s: !sr <item link>")
        :format(U.ChatSafe(s.title or "Raid"), s.instance and (" (" .. U.ChatSafe(s.instance) .. ")") or "",
            limit, limit == 1 and "reserve" or "reserves", s.plus and ", plus mode on" or "",
            U.ShortName(s.host))
    if s.locked then msg = ("SR for %s is LOCKED. No more changes."):format(U.ChatSafe(s.title or "Raid")) end
    local ok, err = API.SendChat(msg, ch)
    if not ok then
        return false, err == "lockdown" and "Chat messages are restricted right now." or "Chat wouldn't take it."
    end
    return true
end

-------------------------------------------------------------------------------
-- CSV (softres.it layout: Item,ItemId,From,Name,Class,Spec,Note,Plus,Date)
-------------------------------------------------------------------------------
local function csvField(v)
    v = tostring(v == nil and "" or v)
    if v:find('[,"\r\n;]') then
        v = '"' .. (v:gsub('"', '""')) .. '"'
    end
    return v
end

function SR:ExportCSV(s)
    s = s or self:ActiveSession()
    local lines = { "Item,ItemId,From,Name,Class,Spec,Note,Plus,Date" }
    if not s then return lines[1] end
    for _, r in ipairs(self:Reserves(s.id)) do
        for _, itemID in ipairs(r.items) do
            local cat = catalogEntry(itemID)
            lines[#lines + 1] = concat({
                csvField(itemName(itemID) or ""), itemID, csvField(cat and cat.b or ""),
                csvField(U.ShortName(r.player)), csvField(r.class and API.ClassName(r.class) or ""), "",
                csvField(r.note or ""), self:PlusFor(s, r.player, itemID, r),
                csvField(date("%Y-%m-%d %H:%M:%S", r.t or s.created or 0)),
            }, ",")
        end
    end
    return concat(lines, "\n")
end

-- Quote-aware CSV reader; the delimiter (comma, semicolon or tab) is sniffed from the header.
local function parseCSV(text)
    local first = text:match("^[^\r\n]*") or ""
    local delim = ","
    local _, commas = first:gsub(",", "")
    local _, semis = first:gsub(";", "")
    local _, tabs = first:gsub("\t", "")
    if semis > commas and semis >= tabs then delim = ";" elseif tabs > commas then delim = "\t" end
    local rows, row, field = {}, {}, {}
    local inQuotes = false
    local i, n = 1, #text
    local function endRow()
        row[#row + 1] = concat(field)
        field = {}
        if #row > 1 or row[1] ~= "" then rows[#rows + 1] = row end
        row = {}
    end
    while i <= n do
        local c = text:sub(i, i)
        if inQuotes then
            if c == '"' then
                if text:sub(i + 1, i + 1) == '"' then
                    field[#field + 1] = '"'
                    i = i + 1
                else
                    inQuotes = false
                end
            else
                field[#field + 1] = c
            end
        elseif c == '"' then
            inQuotes = true
        elseif c == delim then
            row[#row + 1] = concat(field)
            field = {}
        elseif c == "\n" or c == "\r" then
            endRow()
            if c == "\r" and text:sub(i + 1, i + 1) == "\n" then i = i + 1 end
        else
            field[#field + 1] = c
        end
        i = i + 1
    end
    if #field > 0 or #row > 0 then endRow() end
    return rows
end

local function normHeader(h)
    return (tostring(h or ""):gsub("^\239\187\191", ""):lower():gsub("[^%a]", ""))
end

local classByText
local function classFromText(v)
    if type(v) ~= "string" then return nil end
    if not classByText then
        classByText = {}
        for _, c in ipairs(API.CLASSES) do
            classByText[c:lower()] = c
            local loc = API.ClassName(c)
            if type(loc) == "string" then classByText[(loc:lower():gsub("%s", ""))] = c end
        end
    end
    return classByText[(U.Trim(v):lower():gsub("[%s_]", ""))]
end

--- ImportCSV(session, text) -> ok, playersOrErr, skippedRows
function SR:ImportCSV(s, text)
    if not self:CanControl(s) then return false, "Only the host can import." end
    local rows = parseCSV(type(text) == "string" and text or "")
    if #rows < 2 then return false, "Nothing to import. Paste the CSV export from softres.it." end
    local cols = {}
    for i, h in ipairs(rows[1]) do
        local k = normHeader(h)
        if k ~= "" and not cols[k] then cols[k] = i end
    end
    local ci, cn = cols.itemid, cols.name
    if not ci or not cn then return false, "Couldn't find the ItemId and Name columns in that." end
    local byPlayer, order, skipped = {}, {}, 0
    for r = 2, #rows do
        local row = rows[r]
        local itemID = tonumber(U.Trim(row[ci] or ""))
        local raw = U.Trim(row[cn] or "")
        local key = raw ~= "" and API.Key(U.Capitalize(raw)) or nil
        if itemID and itemID > 0 and key then
            local e = byPlayer[key]
            if not e then
                e = { items = {}, pb = {}, class = classFromText(cols.class and row[cols.class]) }
                byPlayer[key] = e
                order[#order + 1] = key
            end
            if not U.Contains(e.items, itemID) then e.items[#e.items + 1] = itemID end
            local plus = cols.plus and tonumber(U.Trim(row[cols.plus] or ""))
            if plus and plus > 0 then e.pb[itemID] = floor(plus) end
            local note = cols.note and U.Trim(row[cols.note] or "") or ""
            if note ~= "" and not e.note then e.note = note:gsub("|", ""):sub(1, NOTE_MAX) end
        else
            skipped = skipped + 1
        end
    end
    if #order == 0 then return false, "No usable rows in there." end
    -- the sheet may hand out more reserves than our limit: raise it to match
    local need = 1
    for _, e in pairs(byPlayer) do need = max(need, #e.items) end
    need = min(need, MAX_LIMIT)
    local raised = need > self:Limit(s)
    if raised then updateSession(s, function(d) d.limit = need end) end
    -- write once the session update is on the wire, so remote validation sees the new limit
    GF:After(raised and 2.5 or 0, function()
        local cur = self:Session(s.id) or s
        local lim = self:Limit(cur)
        for _, key in ipairs(order) do
            local e = byPlayer[key]
            local items = {}
            for i = 1, min(#e.items, lim) do items[i] = e.items[i] end
            self:WriteReserve(cur, key, items, e.class, { note = e.note, pb = next(e.pb) and e.pb or nil })
        end
    end)
    return true, #order, skipped
end

-------------------------------------------------------------------------------
-- Whisper intake: "!sr <link or id>", "!sr" (list), "!sr clear"  (host only)
-------------------------------------------------------------------------------
local lastReply = {}
local LINK_PATTERN = "(|c[^|]*|Hitem:(%d+)[^|]*|h%[.-%]|h|r)"

-- Automatic chat (no click behind it): the whisper replies below and the Loot Desk's
-- timer-driven raid lines. CORE_API allows RAID/WHISPER; FOREVER_FACTS D.7 has them as
-- UNKNOWN on Forever. If the client ever blocks one, that channel stays quiet for the
-- session instead of tripping the block on every whisper and every roll.
local autoBlocked, lastAuto = {}, nil

function SR.AutoSend(text, chatType, target)
    if type(chatType) ~= "string" or autoBlocked[chatType] then return false, "blocked" end
    lastAuto = { ch = chatType, t = API.Time() }
    return API.SendChat(text, chatType, target)
end

local function onActionBlocked(_, addon, fn)
    addon, fn = API.CleanString(addon), API.CleanString(fn)
    if addon ~= GF.ADDON or type(fn) ~= "string" or not fn:find("SendChatMessage", 1, true) then return end
    local last = lastAuto
    if not last or API.Time() - last.t > 2 or autoBlocked[last.ch] then return end
    autoBlocked[last.ch] = true
    GF:Print("The game blocked an automatic %s message, so those stay off until you /reload. Buttons still work.", last.ch:lower())
end
GF:RegisterEvent("ADDON_ACTION_BLOCKED", onActionBlocked)
GF:RegisterEvent("ADDON_ACTION_FORBIDDEN", onActionBlocked)

local function reply(target, text)
    SR.AutoSend(text, "WHISPER", target)
end

-- our own client's link first: echoing a whispered link back verbatim would also echo
-- any doctored name in it (and the server bins the whole message)
local function linkFor(itemID, links)
    local own = API.ItemLink(itemID)
    if type(own) == "string" and API.Readable(own) then return own end
    return (links and links[itemID]) or itemName(itemID) or ("item " .. itemID)
end

-- Whispers cap at 255 bytes and a truncated link kills the whole send, so long link
-- lists fall back to plain names.
local function describe(items, links)
    local parts, plain = {}, {}
    for i = 1, min(#items, 2) do
        parts[#parts + 1] = linkFor(items[i], links)
        plain[#plain + 1] = itemName(items[i]) or ("item " .. items[i])
    end
    local more = #items > 2 and (" +" .. (#items - 2) .. " more") or ""
    local text = concat(parts, ", ")
    if #text > 190 then text = concat(plain, ", ") end
    return text .. more
end

local REPLY_GAP = 1.5

local function currentItems(s, key)
    local cur = Store:Get(RESERVES, s.id .. "|" .. key)
    local items = {}
    if type(cur) == "table" and type(cur.items) == "table" then
        for _, v in ipairs(cur.items) do
            if type(v) == "number" then items[#items + 1] = v end
        end
    end
    return items
end

local function listLine(s, key)
    local limit = SR:Limit(s)
    local items = currentItems(s, key)
    if #items == 0 then return ("No reserves yet (0/%d). Whisper me: !sr <item link>"):format(limit) end
    return ("Your SR (%d/%d): %s"):format(#items, limit, describe(items))
end

-- One reply per sender per REPLY_GAP. Someone pasting links faster than that still gets
-- every pick saved, plus one summary of where they ended up once they stop.
local function replyTo(key, sender, text)
    local t = API.Time()
    if lastReply[key] and t - lastReply[key] < REPLY_GAP then
        GF:Debounce("sr-reply:" .. key, REPLY_GAP + 0.1, function()
            local s = SR:ActiveSession()
            if not s or s.host ~= API.MyKey() then return end
            lastReply[key] = API.Time()
            reply(sender, listLine(s, key))
        end)
        return
    end
    lastReply[key] = t
    reply(sender, text)
end

local function onWhisper(_, text, sender)
    text, sender = API.CleanString(text), API.CleanString(sender)
    if not text or not sender then return end
    local lower = text:lower()
    if not (lower:match("^%s*!sr%s") or lower:match("^%s*!sr$")) then return end
    local s = SR:ActiveSession()
    local me = API.MyKey()
    if not s or not me or s.host ~= me or not SR:IsOpen(s) then return end
    local key = API.Key(sender)
    if not key or key == me then return end
    -- randoms off the street don't get to fill the sheet
    if not (GF.Roster:InGroup(key) or GF.Roster:IsMember(key)) then
        replyTo(key, sender, "Join the group first, then whisper me !sr <item link>.")
        return
    end

    local rest = U.Trim(text:match("^%s*![Ss][Rr](.*)$") or "")
    local restLower = rest:lower()
    local limit = SR:Limit(s)
    local items = currentItems(s, key)

    if rest == "" or restLower == "list" then
        replyTo(key, sender, listLine(s, key))
        return
    end
    if s.locked then
        replyTo(key, sender, "SR's locked, sorry mate. Too slow.")
        return
    end
    if restLower == "clear" then
        SR:WriteReserve(s, key, {})
        replyTo(key, sender, ("Cleared. Fresh slate (0/%d)."):format(limit))
        return
    end

    local ids, links = {}, {}
    for link, id in rest:gmatch(LINK_PATTERN) do
        id = tonumber(id)
        if id then ids[#ids + 1] = id; links[id] = link end
    end
    if #ids == 0 then
        for id in rest:gmatch("(%d+)") do ids[#ids + 1] = tonumber(id) end
    end
    if #ids == 0 then
        replyTo(key, sender, "Didn't catch an item there. Try: !sr <shift-click the item>")
        return
    end
    local added, dupes = {}, 0
    for _, id in ipairs(ids) do
        if id and id > 0 and #items < limit then
            if U.Contains(items, id) then
                dupes = dupes + 1
            else
                items[#items + 1] = id
                added[#added + 1] = id
            end
        end
    end
    if #added == 0 then
        if dupes > 0 then
            replyTo(key, sender, ("Already got that one (%d/%d)."):format(#items, limit))
        else
            replyTo(key, sender, ("You're at the limit (%d/%d). Whisper !sr clear to start over."):format(#items, limit))
        end
        return
    end
    local ok = SR:WriteReserve(s, key, items, GF.Roster:Class(key))
    if ok then
        replyTo(key, sender, ("Got it: %s (%d/%d). !sr clear to start over."):format(describe(added, links), #items, limit))
    else
        replyTo(key, sender, "Something's cooked on my end. Try again in a sec.")
    end
end

GF:RegisterEvent("CHAT_MSG_WHISPER", onWhisper)

-------------------------------------------------------------------------------
-- Op "SR": a raider outside the guild hands their picks to the host
-------------------------------------------------------------------------------
Comm:Register("SR", function(p, sender)
    if type(p) ~= "table" or type(p.s) ~= "string" or type(p.i) ~= "table" then return end
    local s = SR:Session(p.s)
    local me = API.MyKey()
    if not s or not me or s.host ~= me or not SR:IsOpen(s) or s.locked then return end
    if not (GF.Roster:InGroup(sender) or GF.Roster:IsMember(sender)) then return end
    local items = {}
    for _, v in ipairs(p.i) do
        if type(v) == "number" and v > 0 then items[#items + 1] = floor(v) end
    end
    if #items > SR:Limit(s) then return end
    SR:WriteReserve(s, sender, items, validClass(p.c) or GF.Roster:Class(sender))
end)

-------------------------------------------------------------------------------
-- Shift-click an item into our inputs: post-hook the chat link inserters and hand the
-- link to whichever registered EditBox has focus.
-------------------------------------------------------------------------------
local linkBoxes = {}
local lastLink, lastLinkAt
local hooked = false

local function onInsertLink(link)
    if type(link) ~= "string" or not API.Readable(link) or link == "" then return end
    local t = API.Time()
    -- ChatEdit_InsertLink may forward to ChatFrameUtil.InsertLink: don't insert twice
    if lastLink == link and lastLinkAt and t - lastLinkAt < 0.1 then return end
    for box in pairs(linkBoxes) do
        if box:IsVisible() and box:HasFocus() then
            lastLink, lastLinkAt = link, t
            box:Insert(link)
            return
        end
    end
end

local function hookLinks()
    if hooked then return end
    hooked = true
    local hsf = rawget(_G, "hooksecurefunc")
    if type(hsf) ~= "function" then return end
    local handler = function(link) GF:Safe("sr:insertlink", onInsertLink, link) end
    local CFU = rawget(_G, "ChatFrameUtil")
    if type(CFU) == "table" and type(CFU.InsertLink) == "function" then
        pcall(hsf, CFU, "InsertLink", handler)
    end
    if type(rawget(_G, "ChatEdit_InsertLink")) == "function" then
        pcall(hsf, "ChatEdit_InsertLink", handler)
    end
end

--- Registers an EditBox that should receive shift-clicked item links while focused.
function SR:AddLinkTarget(box)
    if type(box) == "table" and box.Insert and box.HasFocus then
        linkBoxes[box] = true
        hookLinks()
    end
end

-------------------------------------------------------------------------------
-- Wiring
-------------------------------------------------------------------------------
GF:On("GF_GROUP_UPDATED", function()
    cache.activeAt = nil
    GF:Debounce("sr-updated", 0.25, function() GF:Fire("GF_SR_UPDATED") end)
end)

GF:On("GF_STORE_CHANGED", function(name)
    if name == "loot" then SR:Invalidate() end
end)

-- pruning drops docs without a change event; don't keep serving them from the cache
GF:On("GF_STORE_PRUNED", function(name)
    if name == SESSIONS or name == RESERVES or name == "loot" then SR:Invalidate() end
end)

GF:On("GF_GUILD_CHANGED", function() SR:Invalidate() end)

GF:RegisterSlash("sr", function()
    if GF.UI and GF.UI.OpenMain then GF.UI:OpenMain("softres") end
end, "open the Soft Res page")
