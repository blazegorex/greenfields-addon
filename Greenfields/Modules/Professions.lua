--[[ Greenfields - Modules/Professions.lua
     The Tradies data layer: who in the guild can make what, how good they are at it and
     whose transmute is ready. The page itself lives in Modules/ProfessionsUI.lua.

     Where the data comes from (FOREVER_FACTS C and A.16):
       * skill ranks: GetProfessions/GetProfessionInfo through GF.API.Professions(), keyed by
         skill line (child lines map to their parent via GF.BuffData.childSkillLines)
       * recipes, window open: C_TradeSkillUI once IsTradeSkillReady(). Linked and guild
         views are skipped, and a false .learned only counts on the line the window shows
       * recipes, window shut: GF.API.Knows (IsPlayerSpell) against the guild catalogue,
         which is every recipe anyone has published plus the camp, campfire and cooldown
         recipes we ship. That is how a recipe bought from a trainer shows up without the
         window ever opening
       * cooldowns: UNIT_SPELLCAST_SUCCEEDED on the player for the recipes in COOLDOWNS,
         refined by C_Spell.GetSpellCooldown when it answers
     Every scan runs out of combat (values can be secret there) and is throttled and
     time-sliced so no frame does more than SLICE client calls.

     Datasets
       recipes/rc  player-owned, id = player key
                   { lines = { [skillLine] = { r = rank, m = max, h = recipe list hash } },
                     cd = { [recipeSpellID] = readyAt (server time) }, t = publishedAt }
       crafts/cr   shared, id = playerKey.."|"..skillLine, then "|2", "|3"... for big lines
                   { p = player, s = skillLine, l = { recipe spell IDs, sorted },
                     o = { [recipeID] = outputItemID }, n = number of parts }
                   Only the player named in p (and at the front of the id) may write it.
                   Written only when the list hash changes; PART_SIZE recipes per doc keeps
                   each one around 2 KB on the wire.

     Public API (CORE_API.md section 5)
       GF.Profs:CraftersOf(itemID) -> { playerKey, ... } (online first)
       GF.Profs:Skill(key, skillLine) -> rank or 0
       GF.Profs:Recipes(key, skillLine) -> { recipeSpellID, ... }
     Used by ProfessionsUI.lua: Index(), LineName/LineIcon/IsSecondary(line), RecipeName(id),
     OnlineFirst(keys), MissingLines(), Cooldowns(), Rescan(). Fires GF_PROFS_UPDATED
     (debounced) whenever the index is rebuilt. Item tooltips get a "Guild tradies" line
     while settings.tooltipCrafters is on. ]]

local _, GF = ...
local API, U, T, Store, Ser = GF.API, GF.Util, GF.Theme, GF.Store, GF.Serialize
local D = GF.BuffData

local Profs = GF:NewModule("Profs")
GF.Profs = Profs

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local floor, min, abs, ceil = math.floor, math.min, math.abs, math.ceil
local sort, concat = table.sort, table.concat
local rawget, pcall = rawget, pcall

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local PART_SIZE = 160          -- recipes per crafts doc (~2.2 KB deflated inside its SU message)
local MAX_PARTS = 6            -- 960 recipes per line; no profession comes close
local MAX_SKILL = 300
local SLICE = 150              -- client calls per frame while scanning
local CATALOGUE_EVERY = 30     -- seconds between window-shut recipe checks
local WINDOW_EVERY = 8         -- seconds between rescans of the same open window
local SYNC_GRACE = 120         -- seconds after GF_GUILD_READY before a guessed list may start a doc
local REFRESH_DOC = 14 * 86400 -- republish the recipes doc at least this often so it never ages out
local CD_KEEP = 14 * 86400     -- keep a cooldown entry this long after it comes off cooldown
local KEEP_DAYS = 120
local RETRIES = { 5, 15, 60 }  -- GetProfessions can answer empty straight after login
local WINDOWS = { "ProfessionsFrame", "TradeSkillFrame" }

Profs.MAX_SKILL = MAX_SKILL

-- Profession cooldowns (FOREVER_FACTS F.7). `line` is only set where the trade is certain;
-- it seeds the window-shut recipe check. Salt Shaker is an item's use spell, not a recipe.
local COOLDOWNS = {
    { id = 17187, cd = 169200, line = 171 },   -- Transmute: Arcanite
    { id = 1317279, cd = 169200, line = 171 }, -- Transmute: Legionite
    { id = 17559, cd = 82800, line = 171 },    -- elemental transmutes (17559-17566)
    { id = 17560, cd = 82800, line = 171 },
    { id = 17561, cd = 82800, line = 171 },
    { id = 17562, cd = 82800, line = 171 },
    { id = 17563, cd = 82800, line = 171 },
    { id = 17564, cd = 82800, line = 171 },
    { id = 17565, cd = 82800, line = 171 },
    { id = 17566, cd = 82800, line = 171 },
    { id = 25146, cd = 600, line = 171 },      -- Transmute: Elemental Fire
    { id = 11479, cd = 3600, line = 171 },     -- Transmute: Iron to Gold
    { id = 11480, cd = 3600, line = 171 },     -- Transmute: Mithril to Truesilver
    { id = 22430, cd = 7200 },                 -- Refined Scale of Onyxia
    { id = 18560, cd = 342000, line = 197 },   -- Mooncloth
    { id = 19566, cd = 255600 },               -- Salt Shaker
}
local COOLDOWN_BY_ID = {}
for i, c in ipairs(COOLDOWNS) do
    c.order = i
    COOLDOWN_BY_ID[c.id] = c
end

-- Recipes known without anyone opening a window: camp kits, campfires and cooldowns.
-- SEED[line][recipeID] = outputItemID, or false when the output isn't certain.
local SEED = {}
local function seed(line, id, item)
    if not (line and D.professions[line] and type(id) == "number") then return end
    local s = SEED[line] or {}
    SEED[line] = s
    if not s[id] then s[id] = item or false end
end
for _, o in ipairs(D.camp) do
    if type(o.recipes) == "table" then
        local parallel = type(o.items) == "table" and #o.items == #o.recipes
        for i, r in ipairs(o.recipes) do seed(o.prof, r, parallel and o.items[i] or nil) end
    end
end
for _, f in ipairs(D.campfires) do seed(185, f.recipe, f.item) end
for _, c in ipairs(COOLDOWNS) do seed(c.line, c.id, nil) end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local started = false          -- true after GF_GUILD_READY
local guildReadyAt = 0
local myLines = {}             -- [line] = { r = rank, m = max } from GetProfessions
local myLinesFinal = false     -- myLines is a real answer, not an early-login empty one
local retryStep, retryPending = 0, false
local cdState = {}             -- [recipeID] = readyAt (server time)
local deferred = {}            -- work postponed until combat ends
local windowOpen, forceWindow = false, false
local winGen, catGen = 0, 0
local lastWindowScan = {}      -- [line] = GetTime of the last window scan
local lastCatalogue = 0
local pendingNew = {}          -- recipe IDs from NEW_RECIPE_LEARNED not yet published
local spellNames = {}
local lastRosterCount = -1

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------
local function validId(v)
    return type(v) == "number" and v > 0 and v < 2147483648 and v == floor(v)
end

--- Maps any skill line (child lines included) onto one of the 12 professions, or nil.
local function lineOf(v)
    v = API.CleanNumber(v)
    if not v then return nil end
    v = D.childSkillLines[v] or v
    return D.professions[v] and v or nil
end

local function truthy(v) return API.Readable(v) and v and true or false end

local function charDB()
    local c = GF.cdb
    if type(c) ~= "table" then return {} end
    if type(c.profs) ~= "table" then c.profs = {} end
    return c.profs
end

local function sortedKeys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    sort(out)
    return out
end

local function partId(key, line, k)
    if k == 1 then return key .. "|" .. line end
    return key .. "|" .. line .. "|" .. k
end

--- Hash of a recipe list plus its outputs; readers recompute it to spot half-synced lines.
local function hashOf(list, outs)
    local buf = {}
    for i = 1, #list do
        local id = list[i]
        local item = outs[id]
        buf[i] = item and (id .. ":" .. item) or tostring(id)
    end
    return Ser.Hash(concat(buf, ","))
end

-- Guarded C_TradeSkillUI call; returns the raw results (callers Clean them) or nil.
local function ts(name, ...)
    local t = rawget(_G, "C_TradeSkillUI")
    local f = type(t) == "table" and t[name]
    if type(f) ~= "function" then return nil end
    local ok, a, b, c = pcall(f, ...)
    if not ok then return nil end
    return a, b, c
end

--- Seconds left on a spell cooldown, 0 when the client says it's ready, nil when unknown.
local function cooldownLeft(spellID)
    local CS = rawget(_G, "C_Spell")
    local f = type(CS) == "table" and CS.GetSpellCooldown or rawget(_G, "GetSpellCooldown")
    if type(f) ~= "function" then return nil end
    local ok, a, b = pcall(f, spellID)
    if not ok then return nil end
    local start, dur
    if type(a) == "table" then start, dur = a.startTime, a.duration else start, dur = a, b end
    start, dur = API.CleanNumber(start), API.CleanNumber(dur)
    if not start or not dur then return nil end
    if start <= 0 or dur <= 0 then return 0 end
    local left = start + dur - API.Time()
    return left > 0 and left or 0
end

local function frameShown()
    local known = false
    for _, name in ipairs(WINDOWS) do
        local f = rawget(_G, name)
        if type(f) == "table" and type(f.IsShown) == "function" then
            known = true
            local ok, shown = pcall(f.IsShown, f)
            if ok and shown then return true end
        end
    end
    return not known and windowOpen
end

--- The profession line the open window is showing, or nil (shut, linked, guild, NPC view).
local function windowLine()
    if not frameShown() then return nil end
    if not truthy(ts("IsTradeSkillReady")) then return nil end
    if truthy(ts("IsTradeSkillLinked")) or truthy(ts("IsTradeSkillGuild")) or truthy(ts("IsNPCCrafting")) then return nil end
    local base = ts("GetBaseProfessionInfo")
    local line = type(base) == "table" and (lineOf(base.professionID) or lineOf(base.parentProfessionID)) or nil
    if not line then
        local child = ts("GetChildProfessionInfo")
        line = type(child) == "table" and (lineOf(child.parentProfessionID) or lineOf(child.professionID)) or nil
    end
    return line
end

-------------------------------------------------------------------------------
-- Datasets
-------------------------------------------------------------------------------
-- Docs live while their author's profile is fresh (both are only rewritten on change).
local function keepDoc(_, rec)
    if type(rec) ~= "table" or type(rec.a) ~= "string" then return false end
    local p = Store:Rec("profile", rec.a)
    return type(p) == "table" and not p.x and type(p.t) == "number"
        and API.ServerTime() - p.t < KEEP_DAYS * 86400
end

local function ownsId(author, id)
    return type(author) == "string" and type(id) == "string" and id:sub(1, #author + 1) == author .. "|"
end

Store:Define({
    name = "recipes", code = "rc", owner = "player", lazy = 60, keepDays = KEEP_DAYS, keep = keepDoc,
    validate = function(_, d)
        return type(d) == "table" and (d.lines == nil or type(d.lines) == "table") and (d.cd == nil or type(d.cd) == "table")
    end,
})

Store:Define({
    -- batch: each part is ~2 KB on the wire, so 20-doc SU messages would hog the queue
    name = "crafts", code = "cr", owner = "shared", keepDays = KEEP_DAYS, keep = keepDoc, batch = 3,
    canWrite = function(author, id, newData, oldData)
        if not ownsId(author, id) then return false end
        -- a tombstone for a part we never held: the id prefix is the ownership proof.
        -- Rejecting it left the digests mismatched forever (sync churn every SyncNow).
        if newData == nil and oldData == nil then return true end
        local d = newData or oldData
        return type(d) == "table" and d.p == author
    end,
    validate = function(id, d)
        return type(d) == "table" and type(d.p) == "string" and type(d.s) == "number" and type(d.l) == "table"
            and #d.l <= PART_SIZE * 3 and (d.o == nil or type(d.o) == "table") and ownsId(d.p, id)
    end,
})

--- One player's published line, parts merged: { set, list, o, n, complete, h } or nil.
local function storedLine(key, line)
    if type(key) ~= "string" then return nil end
    local first = Store:Get("crafts", partId(key, line, 1))
    local n = type(first) == "table" and type(first.n) == "number" and first.n or nil
    local set, o, found = {}, {}, 0
    for k = 1, MAX_PARTS do
        local d = Store:Get("crafts", partId(key, line, k))
        if type(d) == "table" and d.p == key and type(d.l) == "table" and (not n or k <= n) then
            found = found + 1
            for _, id in ipairs(d.l) do if validId(id) then set[id] = true end end
            if type(d.o) == "table" then
                for id, item in pairs(d.o) do
                    if validId(id) and validId(item) then o[id] = item end
                end
            end
        end
    end
    if found == 0 then return nil end
    local list = sortedKeys(set)
    -- part 1 carries n: without it we can't know how much is still on its way
    return { set = set, list = list, o = o, n = n or found, complete = (n ~= nil and found >= n), h = hashOf(list, o) }
end

local function deleteLine(key, line)
    for k = 1, MAX_PARTS do
        local pid = partId(key, line, k)
        if Store:Get("crafts", pid) then Store:Delete("crafts", pid) end
    end
end

-------------------------------------------------------------------------------
-- Guild index (rebuilt lazily, debounced on store changes)
--   players[key] = { key, t, cd = {[recipe] = readyAt},
--                    lines = {[line] = {line, rank, max, h, list, set, out, count, synced}} }
--   recipes[recipeID] = { recipe, line, item, crafters = {keys}, set = {[key] = true} }
--   items[itemID] = {keys}     catalogue[line] = {[recipeID] = true}
--   lineMembers[line] / lineRecipes[line] = counts, tradies, recipeCount
-------------------------------------------------------------------------------
local function emptyIndex(gen)
    return { gen = gen or 0, players = {}, recipes = {}, items = {}, catalogue = {},
             lineMembers = {}, lineRecipes = {}, tradies = 0, recipeCount = 0 }
end

local idx = emptyIndex()
local dirty = true
local hashCache = {}   -- "key|line" -> { sig = part revisions, h = hash }

local function include(key)
    if type(key) ~= "string" or key == "" then return false end
    if key == API.MyKey() then return true end
    local R = GF.Roster
    if R and R:Count() > 0 then return R:IsMember(key) end
    return true
end

local function docTime(name, key)
    local rec = Store:Rec(name, key)
    return (type(rec) == "table" and not rec.x and type(rec.t) == "number") and rec.t or 0
end

--- Ranks for one player: the newer of their profile doc and their recipes doc wins.
local function ranksOf(key)
    local out = {}
    local prof, rd = Store:Get("profile", key), Store:Get("recipes", key)
    local pf = type(prof) == "table" and type(prof.profs) == "table" and prof.profs or nil
    local rl = type(rd) == "table" and type(rd.lines) == "table" and rd.lines or nil
    if rl and (not pf or docTime("recipes", key) >= docTime("profile", key)) then
        for line, v in pairs(rl) do
            local l = lineOf(line)
            if l and type(v) == "table" and type(v.r) == "number" then
                out[l] = { rank = v.r, max = type(v.m) == "number" and v.m or 0, h = type(v.h) == "string" and v.h or nil }
            end
        end
    elseif pf then
        for line, rank in pairs(pf) do
            local l = lineOf(line)
            if l and type(rank) == "number" then
                local v = rl and rl[line]
                v = type(v) == "table" and v or {}
                out[l] = { rank = rank, max = type(v.m) == "number" and v.m or 0, h = type(v.h) == "string" and v.h or nil }
            end
        end
    end
    return out
end

local function rebuild()
    dirty = false
    local me = API.MyKey()
    local now = API.ServerTime()
    local nx = emptyIndex(idx.gen + 1)
    local players = nx.players

    local function player(key)
        local p = players[key]
        if not p then
            p = { key = key, lines = {}, cd = {}, t = 0 }
            players[key] = p
        end
        return p
    end
    local function pline(p, line)
        local l = p.lines[line]
        if not l then
            l = { line = line, rank = 0, max = 0, list = {}, set = {}, out = {}, count = 0, synced = true }
            p.lines[line] = l
        end
        return l
    end

    -- ranks and cooldowns
    local keys = {}
    for key in pairs(Store:All("profile")) do keys[key] = true end
    for key in pairs(Store:All("recipes")) do keys[key] = true end
    if me then keys[me] = true end
    for key in pairs(keys) do
        if include(key) then
            local ranks = ranksOf(key)
            if key == me and myLinesFinal then
                local live = {}
                for line, v in pairs(myLines) do live[line] = { rank = v.r, max = v.m, h = ranks[line] and ranks[line].h } end
                ranks = live
            end
            for line, v in pairs(ranks) do
                local l = pline(player(key), line)
                l.rank, l.max, l.h = v.rank, v.max, v.h
            end
            local rd = Store:Get("recipes", key)
            if type(rd) == "table" and type(rd.cd) == "table" then
                for id, at in pairs(rd.cd) do
                    if validId(id) and type(at) == "number" then player(key).cd[id] = at end
                end
            end
            if players[key] then players[key].t = math.max(docTime("recipes", key), docTime("profile", key)) end
        end
    end
    if me then
        for id, at in pairs(cdState) do
            if at > now - CD_KEEP then player(me).cd[id] = at end
        end
    end

    -- crafts docs, grouped by player and line
    local groups = {}
    for id, d in pairs(Store:All("crafts")) do
        if type(id) == "string" and type(d) == "table" and type(d.p) == "string" and type(d.l) == "table" then
            local who, s, k = id:match("^(.+)|(%d+)|(%d+)$")
            if not who then
                who, s = id:match("^(.+)|(%d+)$")
                k = "1"
            end
            s, k = tonumber(s), tonumber(k)
            local line = lineOf(s)
            if who == d.p and s == d.s and line and k and k >= 1 and k <= MAX_PARTS and include(who) then
                local gk = who .. "|" .. line
                local g = groups[gk]
                if not g then
                    g = { key = who, line = line, parts = {} }
                    groups[gk] = g
                end
                local rec = Store:Rec("crafts", id)
                g.parts[k] = { d = d, r = type(rec) == "table" and rec.r or 0 }
            end
        end
    end
    for gk, g in pairs(groups) do
        local l = pline(player(g.key), g.line)
        local first = g.parts[1] and g.parts[1].d
        local n = (first and type(first.n) == "number") and first.n or MAX_PARTS
        local sig = {}
        for k = 1, MAX_PARTS do
            local part = g.parts[k]
            if part and k <= n then
                sig[#sig + 1] = k .. ":" .. tostring(part.r)
                for _, id in ipairs(part.d.l) do if validId(id) then l.set[id] = true end end
                if type(part.d.o) == "table" then
                    for id, item in pairs(part.d.o) do
                        if validId(id) and validId(item) then l.out[id] = item end
                    end
                end
            end
        end
        l.list = sortedKeys(l.set)
        l.count = #l.list
        local s = concat(sig, ",")
        local hc = hashCache[gk]
        if not hc or hc.sig ~= s then
            hc = { sig = s, h = hashOf(l.list, l.out) }
            hashCache[gk] = hc
        end
        l.synced = (l.h == nil) or (l.h == hc.h)
    end
    -- a published hash with no list at all yet is the most out-of-sync of the lot
    for key, p in pairs(players) do
        for line, l in pairs(p.lines) do
            if l.h and not groups[key .. "|" .. line] then l.synced = false end
        end
    end

    -- recipes, items, catalogue and counts
    local recipes, items, catalogue = nx.recipes, nx.items, nx.catalogue
    for line, s in pairs(SEED) do
        local c = {}
        for id in pairs(s) do c[id] = true end
        catalogue[line] = c
    end
    for key, p in pairs(players) do
        local any = false
        for line, l in pairs(p.lines) do
            if l.rank > 0 or l.count > 0 then
                any = true
                nx.lineMembers[line] = (nx.lineMembers[line] or 0) + 1
            end
            local cat = catalogue[line] or {}
            catalogue[line] = cat
            for i = 1, l.count do
                local id = l.list[i]
                cat[id] = true
                local e = recipes[id]
                if not e then
                    e = { recipe = id, line = line, crafters = {}, set = {} }
                    recipes[id] = e
                    nx.recipeCount = nx.recipeCount + 1
                    nx.lineRecipes[line] = (nx.lineRecipes[line] or 0) + 1
                end
                if not e.set[key] then
                    e.set[key] = true
                    e.crafters[#e.crafters + 1] = key
                end
                if not e.item and l.out[id] then e.item = l.out[id] end
            end
        end
        if any then nx.tradies = nx.tradies + 1 end
    end
    local seen = {}
    for id, e in pairs(recipes) do
        if not e.item then
            local s = SEED[e.line]
            if s and s[id] then e.item = s[id] end
        end
        sort(e.crafters)
        if e.item then
            local list, set = items[e.item], seen[e.item]
            if not list then
                list, set = {}, {}
                items[e.item], seen[e.item] = list, set
            end
            for _, key in ipairs(e.crafters) do
                if not set[key] then
                    set[key] = true
                    list[#list + 1] = key
                end
            end
        end
    end
    for _, list in pairs(items) do sort(list) end
    idx = nx
end

local function ensure()
    if dirty then GF:Safe("profs:index", rebuild) end
    return idx
end

local function markDirty()
    dirty = true
    GF:Debounce("profs-index", 1.5, function()
        if dirty then GF:Safe("profs:index", rebuild) end
        GF:Fire("GF_PROFS_UPDATED")
    end)
end

-------------------------------------------------------------------------------
-- Publishing my own docs
-------------------------------------------------------------------------------
local function sameRecipesDoc(a, b)
    if type(a) ~= "table" or type(a.lines) ~= "table" or type(a.cd) ~= "table" then return false end
    for line, v in pairs(b.lines) do
        local w = a.lines[line]
        if type(w) ~= "table" or w.r ~= v.r or w.m ~= v.m or w.h ~= v.h then return false end
    end
    for line in pairs(a.lines) do if b.lines[line] == nil then return false end end
    for id, at in pairs(b.cd) do if a.cd[id] ~= at then return false end end
    for id in pairs(a.cd) do if b.cd[id] == nil then return false end end
    return true
end

function Profs:PublishRecipes()
    local me = API.MyKey()
    if not started or not me or not myLinesFinal then return end
    local now = API.ServerTime()
    local doc = { lines = {}, cd = {}, t = now }
    for line, v in pairs(myLines) do
        local cur = storedLine(me, line)
        doc.lines[line] = { r = v.r, m = v.m, h = cur and cur.h or nil }
    end
    for id, at in pairs(cdState) do
        if at > now - CD_KEEP then doc.cd[id] = at end
    end
    local old, rec = Store:Mine("recipes"), Store:Rec("recipes", me)
    if not old and not next(doc.lines) and not next(doc.cd) then return end
    if old and rec and sameRecipesDoc(old, doc) and now - (rec.t or 0) < REFRESH_DOC then return end
    Store:PutMine("recipes", doc)
end

local function schedulePublish()
    GF:Debounce("profs-publish", 3, function() Profs:PublishRecipes() end)
end

local function saveCd()
    local now = API.ServerTime()
    local out = {}
    for id, at in pairs(cdState) do
        if at > now - CD_KEEP then out[id] = at else cdState[id] = nil end
    end
    charDB().cd = out
end

--- First doc for a line from this character: tell them it worked. Lines lodged together
-- (the first catalogue pass can file three or four at once) share one toast.
local lodgedPending = {}
local function lodged(line, count)
    local c = charDB()
    c.lodged = type(c.lodged) == "table" and c.lodged or {}
    if c.lodged[line] then return end
    c.lodged[line] = true
    lodgedPending[line] = count
    GF:Debounce("profs-lodged", 2, function()
        local lines, total = {}, 0
        for l, n in pairs(lodgedPending) do
            lines[#lines + 1] = l
            total = total + n
        end
        lodgedPending = {}
        if #lines == 0 or not (GF.UI and GF.UI.Toast) then return end
        sort(lines)
        local names = {}
        for i, l in ipairs(lines) do names[i] = D.professions[l].name end
        local recipes = U.Plural(total, "recipe")
        local text -- the toast has room for two lines
        if #names == 1 then
            text = ("%d %s %s on the books. Expect a few cheeky whispers."):format(total, names[1], recipes)
        elseif #names <= 3 then
            text = ("%d %s on the books for %s."):format(total, recipes,
                concat(names, ", ", 1, #names - 1) .. " and " .. names[#names])
        else
            text = ("%d %s on the books across %d trades. Expect a few cheeky whispers."):format(total, recipes, #names)
        end
        GF.UI:Toast({
            title = U.Plural(#lines, "Licence lodged", "Licences lodged"),
            text = text,
            icon = #lines == 1 and D.professions[lines[1]].icon or "hammer", style = "green",
            key = "profs-lodged:" .. concat(lines, ","),
        })
    end)
end

local function samePart(d, l, o, n)
    if type(d) ~= "table" or d.n ~= n or type(d.l) ~= "table" or #d.l ~= #l then return false end
    for i = 1, #l do if d.l[i] ~= l[i] then return false end end
    local count = 0
    if type(d.o) == "table" then
        for id, item in pairs(d.o) do
            if o[id] ~= item then return false end
            count = count + 1
        end
    end
    for _ in pairs(o) do count = count - 1 end
    return count == 0
end

--- Merges adds/removes into my published list for a line and writes only the parts that
-- changed. authoritative = it came from an open window: complete and trusted, so it may start
-- a doc straight away and its outputs win; guesses only fill gaps and wait for the sync grace.
local function publishLine(line, adds, removes, outs, authoritative)
    local me = API.MyKey()
    if not me or not D.professions[line] then return false end
    local cur = storedLine(me, line)
    if (not cur or not cur.complete) and not authoritative then
        local wait = SYNC_GRACE - (API.Time() - guildReadyAt)
        if wait > 0 then
            -- our old docs may still be on their way back from guildies; don't trample them
            GF:Debounce("profs-grace", wait + 1, function() Profs:ScanCatalogue(true) end)
            return false
        end
    end
    local set, o = {}, {}
    if cur then
        for id in pairs(cur.set) do set[id] = true end
        for id, item in pairs(cur.o) do o[id] = item end
    end
    if removes then for id in pairs(removes) do set[id], o[id] = nil, nil end end
    if adds then for id in pairs(adds) do set[id] = true end end
    if outs then
        for id, item in pairs(outs) do
            if set[id] and (authoritative or not o[id]) then o[id] = item end
        end
    end
    local list = sortedKeys(set)
    for i = #list, PART_SIZE * MAX_PARTS + 1, -1 do list[i] = nil end
    if #list == 0 then
        if cur then
            deleteLine(me, line)
            schedulePublish()
        end
        return cur ~= nil
    end
    if cur and cur.complete and cur.h == hashOf(list, o) then return false end
    local parts = ceil(#list / PART_SIZE)
    for k = 1, parts do
        local l, po = {}, {}
        for j = (k - 1) * PART_SIZE + 1, min(#list, k * PART_SIZE) do
            local id = list[j]
            l[#l + 1] = id
            if o[id] then po[id] = o[id] end
        end
        local pid = partId(me, line, k)
        if not samePart(Store:Get("crafts", pid), l, po, parts) then
            Store:Put("crafts", pid, { p = me, s = line, l = l, o = po, n = parts })
        end
    end
    for k = parts + 1, MAX_PARTS do
        local pid = partId(me, line, k)
        if Store:Get("crafts", pid) then Store:Delete("crafts", pid) end
    end
    if not cur then lodged(line, #list) end
    schedulePublish()
    return true
end

-------------------------------------------------------------------------------
-- Skill ranks
-------------------------------------------------------------------------------
local function readRanks()
    local out, n = {}, 0
    for _, p in ipairs(API.Professions()) do
        n = n + 1
        local line = lineOf(p.skillLine)
        local r, m = API.CleanNumber(p.rank), API.CleanNumber(p.max)
        if line and r then
            local cur = out[line]
            if not cur or r > cur.r then out[line] = { r = r, m = m or 0 } end
        end
    end
    return out, n
end

local function announce300(line)
    local F = GF.Feed
    local me = API.MyKey()
    if not (F and F.Post and me) then return end
    local text = ("%s is now a fully licensed %s tradie. No ABN required."):format(
        U.ClassName(me, API.UnitClassFile("player")), D.professions[line].name)
    GF:Safe("profs:feed", F.Post, F, "prof", text, { icon = D.professions[line].icon, key = "prof300:" .. me .. ":" .. line })
end

--- Posts the 300 milestone the first time we watch a line cross it.
local function checkMilestones(lines)
    local c = charDB()
    c.maxed = type(c.maxed) == "table" and c.maxed or {}
    c.ranks = type(c.ranks) == "table" and c.ranks or {}
    local doc = Store:Mine("recipes")
    local published = type(doc) == "table" and type(doc.lines) == "table" and doc.lines or {}
    for line, v in pairs(lines) do
        if v.r >= MAX_SKILL and not c.maxed[line] then
            local prev = (myLines[line] and myLines[line].r) or c.ranks[line]
            local pub = published[line]
            if prev == nil and type(pub) == "table" then prev = pub.r end
            if type(prev) == "number" and prev < MAX_SKILL then announce300(line) end
            c.maxed[line] = true
        end
        c.ranks[line] = v.r
    end
end

--- A line I no longer have (and none of whose recipes I still know) comes off the books.
local function dropStaleLines()
    local me = API.MyKey()
    if not me or not myLinesFinal then return end
    for line in pairs(D.professions) do
        if not myLines[line] then
            local cur = storedLine(me, line)
            if cur then
                local stillKnown = false
                for _, id in ipairs(cur.list) do
                    if API.Knows(id) then stillKnown = true break end
                end
                if not stillKnown then deleteLine(me, line) end
            end
        end
    end
end

function Profs:ScanRanks()
    if not started then return end
    if API.InCombat() then deferred.ranks = true return end
    local lines, n = readRanks()
    if n == 0 and retryStep < #RETRIES then
        if not retryPending then
            retryPending = true
            retryStep = retryStep + 1
            GF:After(RETRIES[retryStep], function()
                retryPending = false
                Profs:ScanRanks()
            end)
        end
        return
    end
    if n > 0 then retryStep = 0 end
    local gained, changed = false, not myLinesFinal
    for line, v in pairs(lines) do
        local cur = myLines[line]
        if not cur then gained = true end
        if not cur or cur.r ~= v.r or cur.m ~= v.m then changed = true end
    end
    for line in pairs(myLines) do
        if not lines[line] then changed = true end
    end
    checkMilestones(lines)
    myLines = lines
    myLinesFinal = true
    dropStaleLines()
    -- LEARNED_SPELL_IN_TAB and friends fire for plenty that isn't a skill-up: only a real
    -- change is worth a guild-wide index rebuild and a republish
    if changed then
        markDirty()
        schedulePublish()
    end
    if gained then
        -- a window opened before the ranks answered was skipped; catch it now
        self:ScanWindow()
        self:ScanCatalogue()
    end
end

-------------------------------------------------------------------------------
-- Recipes, window open
-------------------------------------------------------------------------------
--- true learned, false unlearned, nil unknown or not a real recipe.
local function recipeState(id)
    local info = ts("GetRecipeInfo", id)
    if type(info) ~= "table" then return nil end
    if truthy(info.isDummyRecipe) or truthy(info.isRecraft) or truthy(info.isSalvageRecipe) then return nil end
    local learned = API.Clean(info.learned)
    if learned == true then return true end
    if learned == false then return false end
    return nil
end

local function outputItem(id)
    local out = ts("GetRecipeOutputItemData", id)
    if type(out) ~= "table" then return nil end
    local item = API.CleanNumber(out.itemID) or API.ItemID(API.CleanString(out.hyperlink))
    return validId(item) and item or nil
end

--- Recipe IDs from the open window; authoritative when the full list was available.
local function windowRecipeIDs()
    local ids, auth = ts("GetAllRecipeIDs"), true
    if type(ids) ~= "table" or not ids[1] then
        ids, auth = ts("GetFilteredRecipeIDs"), false
    end
    local out = {}
    if type(ids) == "table" then
        for _, v in ipairs(ids) do
            local id = API.CleanNumber(v)
            if validId(id) then out[#out + 1] = id end
        end
    end
    return out, auth
end

function Profs:ScanWindow(force)
    if not started then return end
    if API.InCombat() then deferred.window = true return end
    local line = windowLine()
    if not line or not myLines[line] then return end
    force = force or forceWindow
    local now = API.Time()
    if not force and lastWindowScan[line] and now - lastWindowScan[line] < WINDOW_EVERY then
        GF:Debounce("profs-window", WINDOW_EVERY, function() Profs:ScanWindow() end)
        return
    end
    forceWindow = false
    lastWindowScan[line] = now
    local ids, authoritative = windowRecipeIDs()
    if #ids == 0 then return end
    winGen = winGen + 1
    local gen, i = winGen, 1
    local learned, unlearned, outs = {}, {}, {}
    local function step()
        if gen ~= winGen then return end
        if API.InCombat() then deferred.window = true return end
        if windowLine() ~= line then return end -- shut or switched; the next show rescans
        local stop = min(#ids, i + SLICE - 1)
        for j = i, stop do
            local id = ids[j]
            local st = recipeState(id)
            if st == true then
                learned[id] = true
                outs[id] = outputItem(id)
            elseif st == false and not API.Knows(id) then
                unlearned[id] = true
            end
        end
        i = stop + 1
        if i <= #ids then
            GF:After(0, step)
            return
        end
        local c = charDB()
        c.seen = type(c.seen) == "table" and c.seen or {}
        c.seen[line] = true
        for id in pairs(learned) do pendingNew[id] = nil end
        publishLine(line, learned, unlearned, outs, authoritative)
        markDirty()
    end
    step()
end

-------------------------------------------------------------------------------
-- Recipes, window shut: IsPlayerSpell against the guild catalogue
-------------------------------------------------------------------------------
local function resolveLine(id)
    local e = idx.recipes[id]
    if e then return e.line end
    for line, s in pairs(SEED) do
        if s[id] ~= nil then return line end
    end
    local a, _, c = ts("GetTradeSkillLineForRecipe", id)
    return lineOf(c) or lineOf(a)
end

local function applyGuesses(found)
    if not next(found) then return end -- nothing new: no rebuild, no page refresh
    for line, ids in pairs(found) do
        if myLines[line] then
            local outs = {}
            for id in pairs(ids) do
                local e = idx.recipes[id]
                local item = (e and e.item) or (SEED[line] and SEED[line][id]) or nil
                if item then outs[id] = item end
            end
            if publishLine(line, ids, nil, outs, false) then
                for id in pairs(ids) do pendingNew[id] = nil end
            end
        end
    end
    markDirty()
end

function Profs:ScanCatalogue(force)
    local me = API.MyKey()
    -- until GetProfessions has really answered, every pending recipe would look like it
    -- belongs to a line we don't have and get thrown away (ScanRanks rescans on arrival)
    if not started or not me or not myLinesFinal then return end
    if API.InCombat() then deferred.catalogue = true return end
    local wait = CATALOGUE_EVERY - (API.Time() - lastCatalogue)
    if not force and wait > 0 then
        GF:Debounce("profs-catalogue", wait + 0.5, function() Profs:ScanCatalogue() end)
        return
    end
    lastCatalogue = API.Time()
    local cat = ensure().catalogue
    local work, mine = {}, {}
    for line in pairs(myLines) do
        local cur = storedLine(me, line)
        mine[line] = cur and cur.set or {}
        for id in pairs(cat[line] or {}) do
            if not mine[line][id] then work[#work + 1] = { line, id } end
        end
    end
    for id in pairs(pendingNew) do
        local line = resolveLine(id)
        if not line or not myLines[line] or mine[line][id] then
            pendingNew[id] = nil
        elseif not (cat[line] and cat[line][id]) then
            work[#work + 1] = { line, id }
        end
    end
    if #work == 0 then return end
    catGen = catGen + 1
    local gen, i, found = catGen, 1, {}
    local function step()
        if gen ~= catGen then return end
        if API.InCombat() then deferred.catalogue = true return end
        local stop = min(#work, i + SLICE - 1)
        for j = i, stop do
            local w = work[j]
            if API.Knows(w[2]) then
                found[w[1]] = found[w[1]] or {}
                found[w[1]][w[2]] = true
            else
                pendingNew[w[2]] = nil
            end
        end
        i = stop + 1
        if i <= #work then GF:After(0, step) else applyGuesses(found) end
    end
    step()
end

-------------------------------------------------------------------------------
-- Cooldowns
-------------------------------------------------------------------------------
function Profs:ProbeCooldowns()
    if not started then return end
    if API.InCombat() then deferred.cooldowns = true return end
    local now = API.ServerTime()
    local changed = false
    for _, c in ipairs(COOLDOWNS) do
        if API.Knows(c.id) then
            local left = cooldownLeft(c.id)
            if left and left > 2.5 then -- anything shorter is just the global cooldown
                local at = floor(now + left + 0.5)
                if not cdState[c.id] or abs(cdState[c.id] - at) > 60 then
                    cdState[c.id] = at
                    changed = true
                end
            end
        end
    end
    if changed then
        saveCd()
        markDirty()
        schedulePublish()
    end
end

GF:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID)
    local id = API.CleanNumber(spellID)
    local c = id and COOLDOWN_BY_ID[id]
    if not c then return end
    cdState[id] = API.ServerTime() + c.cd
    saveCd()
    markDirty()
    schedulePublish()
    -- shared category cooldowns (transmutes) show up on the sibling spells a moment later
    GF:After(1.5, function() Profs:ProbeCooldowns() end)
end)

-------------------------------------------------------------------------------
-- Scan orchestration
-------------------------------------------------------------------------------
function Profs:FullScan()
    self:ScanRanks()
    self:ScanWindow(true)
    self:ProbeCooldowns()
    self:ScanCatalogue(true)
end

--- Manual "check my toolbox". Returns "ok", "combat" (queued for after the fight) or "waiting".
function Profs:Rescan()
    if not started then return "waiting" end
    if API.InCombat() then
        deferred.ranks, deferred.window, deferred.cooldowns, deferred.catalogue = true, true, true, true
        return "combat"
    end
    retryStep = 0
    forceWindow = true
    self:ScanRanks()
    self:ScanWindow(true)
    self:ProbeCooldowns()
    self:ScanCatalogue(true)
    return "ok"
end

local function onSkillsChanged()
    if not started then return end
    GF:Debounce("profs-skills", 2, function()
        Profs:ScanRanks()
        Profs:ScanCatalogue()
    end)
end

local function onWindowData()
    if not started then return end
    GF:Debounce("profs-window", 1, function() Profs:ScanWindow() end)
end

GF:RegisterEvent("TRADE_SKILL_SHOW", function()
    windowOpen = true
    forceWindow = true
    onWindowData()
end)
GF:RegisterEvent("TRADE_SKILL_CLOSE", function()
    windowOpen = false
    winGen = winGen + 1
end)
GF:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function()
    windowOpen = true -- the list only refreshes for a shown window (frameShown double-checks)
    onWindowData()
end)
GF:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", onWindowData)
GF:RegisterEvent("SKILL_LINES_CHANGED", onSkillsChanged)
GF:RegisterEvent("LEARNED_SPELL_IN_TAB", onSkillsChanged)
GF:RegisterEvent("CHAT_MSG_SKILL", onSkillsChanged) -- payload may be secret: never read it

GF:RegisterEvent("NEW_RECIPE_LEARNED", function(_, recipeID)
    local id = API.CleanNumber(recipeID)
    if validId(id) then pendingNew[id] = true end
    forceWindow = true
    if not started then return end
    GF:Debounce("profs-learned", 2, function()
        Profs:ScanRanks()
        Profs:ScanWindow(true)
        Profs:ScanCatalogue(true)
    end)
end)

GF:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if not next(deferred) then return end
    local d = deferred
    deferred = {}
    GF:After(1, function()
        if d.ranks then Profs:ScanRanks() end
        if d.window then Profs:ScanWindow(true) end
        if d.cooldowns then Profs:ProbeCooldowns() end
        if d.catalogue then Profs:ScanCatalogue(true) end
    end)
end)

GF:On("GF_GUILD_READY", function()
    started = true
    guildReadyAt = API.Time()
    hashCache = {}
    -- the published doc remembers cooldowns even when this character's SavedVariables don't
    local mine = Store:Mine("recipes")
    if type(mine) == "table" and type(mine.cd) == "table" then
        for id, at in pairs(mine.cd) do
            if validId(id) and type(at) == "number" and at > (cdState[id] or 0) then cdState[id] = at end
        end
    end
    markDirty()
    GF:After(3 + math.random() * 2, function() Profs:FullScan() end)
end)

GF:On("GF_GUILD_CHANGED", function()
    hashCache = {}
    markDirty()
end)

GF:On("GF_STORE_CHANGED", function(name, _, _, _, isRemote)
    if name ~= "crafts" and name ~= "recipes" and name ~= "profile" then return end
    markDirty()
    -- a guildie's list may hold recipes we know but never published
    if name == "crafts" and isRemote and started then
        GF:Debounce("profs-catalogue-remote", 20, function() Profs:ScanCatalogue() end)
    end
end)

GF:On("GF_ROSTER_UPDATED", function()
    local n = GF.Roster:Count()
    if n ~= lastRosterCount then
        lastRosterCount = n
        markDirty()
    end
end)
GF:On("GF_MEMBER_JOINED", markDirty)
GF:On("GF_MEMBER_LEFT", markDirty)

-------------------------------------------------------------------------------
-- Item tooltips: "Guild tradies: A, B, C (+N)"
-------------------------------------------------------------------------------
local function onItemTooltip(tooltip, data)
    if not (GF.db and GF.db.settings) or GF.db.settings.tooltipCrafters == false then return end
    if type(tooltip) ~= "table" or (tooltip.IsForbidden and tooltip:IsForbidden()) then return end
    if tooltip ~= rawget(_G, "GameTooltip") and tooltip ~= rawget(_G, "ItemRefTooltip") then return end
    local id = type(data) == "table" and API.CleanNumber(data.id) or nil
    if not id and type(tooltip.GetItem) == "function" then
        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if ok then id = API.ItemID(API.CleanString(link)) end
    end
    if not validId(id) then return end
    -- the debounced rebuild keeps this fresh; never rebuild on hover
    local keys = idx.items[id]
    if not keys or #keys == 0 then return end
    local list = Profs:OnlineFirst(keys)
    local names = {}
    for i = 1, min(3, #list) do names[i] = GF.Roster:Colored(list[i]) end
    local line = T:Wrap("green", "Guild tradies:") .. " " .. concat(names, ", ")
    if #list > 3 then line = line .. " " .. T:Wrap("faint", "(+" .. (#list - 3) .. ")") end
    tooltip:AddLine(line, 1, 1, 1, true)
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------
function Profs:OnInit()
    local saved = charDB().cd
    if type(saved) == "table" then
        for id, at in pairs(saved) do
            if validId(id) and type(at) == "number" then cdState[id] = at end
        end
    end
end

function Profs:OnLogin()
    API.TooltipPostCall("Item", onItemTooltip)
end

-------------------------------------------------------------------------------
-- Public API (CORE_API.md section 5). Never errors, always returns a safe default.
-------------------------------------------------------------------------------
--- Array of player keys who can craft something that makes itemID (online first).
function Profs:CraftersOf(itemID)
    local id = API.ItemID(API.Clean(itemID))
    if not validId(id) then return {} end
    local list = ensure().items[id]
    if not list then return {} end
    return self:OnlineFirst(list)
end

--- Skill rank of a player in a profession line (child lines accepted), or 0.
function Profs:Skill(key, skillLine)
    local line = lineOf(skillLine)
    if type(key) ~= "string" or not line then return 0 end
    if key == API.MyKey() and myLines[line] then return myLines[line].r or 0 end
    local p = ensure().players[key]
    local l = p and p.lines[line]
    return l and l.rank or 0
end

--- Array of recipe spell IDs a player has shared for a profession line.
function Profs:Recipes(key, skillLine)
    local out = {}
    local line = lineOf(skillLine)
    if type(key) ~= "string" or not line then return out end
    local p = ensure().players[key]
    local l = p and p.lines[line]
    if l then
        for i = 1, l.count do out[i] = l.list[i] end
    end
    return out
end

-------------------------------------------------------------------------------
-- Helpers for the Tradies page
-------------------------------------------------------------------------------
--- The current guild index (read-only; rebuilt when stale).
function Profs:Index() return ensure() end

function Profs:LineName(line)
    local p = D.professions[line]
    return p and p.name or "Unknown trade"
end

function Profs:LineIcon(line)
    local p = D.professions[line]
    return p and p.icon or 134400
end

function Profs:IsSecondary(line)
    local p = D.professions[line]
    return p and p.secondary and true or false
end

--- Localized recipe spell name (cached once the client knows it), or nil.
function Profs:RecipeName(id)
    if not validId(id) then return nil end
    local n = spellNames[id]
    if n then return n end
    n = API.CleanString(API.SpellName(id))
    if n then spellNames[id] = n end
    return n
end

--- Copy of keys sorted online first, then by name.
function Profs:OnlineFirst(keys)
    local out = {}
    if type(keys) ~= "table" then return out end
    local on = {}
    for i = 1, #keys do
        local k = keys[i]
        out[i] = k
        on[k] = GF.Roster:IsOnline(k) and true or false
    end
    sort(out, function(a, b)
        if on[a] ~= on[b] then return on[a] end
        return a < b
    end)
    return out
end

--- My profession lines that nobody can see yet (never shared, window never opened).
function Profs:MissingLines()
    local out = {}
    local me = API.MyKey()
    if not me or not myLinesFinal then return out end
    local seen = type(charDB().seen) == "table" and charDB().seen or {}
    for _, line in ipairs(D.professionOrder) do
        if myLines[line] and not seen[line] and not storedLine(me, line) then out[#out + 1] = line end
    end
    return out
end

--- The cooldown recipe table: { {id, cd, line, order}, ... } (read-only).
function Profs:Cooldowns() return COOLDOWNS end
