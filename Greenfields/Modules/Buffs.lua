--[[ Greenfields - Modules/Buffs.lua
     The brains behind the Buff Check page: who brings which raid buff, what the camp has
     to cover, and who's on camp duty. Presentation lives in Modules/BuffsUI.lua.

       Self capabilities  profile.caps = buff categories this character can cast (proven
                          with IsPlayerSpell, class + level as the fallback) and
                          profile.camp = { c = known object recipes, k = kits in bags,
                          cd = when the shared 1-hour camp cooldown is up, f = campfire
                          recipes, fk = campfire kits, ck = Cooking rank }
       Analyser           Buffs:Analyze(members [, { at = serverTime }]) grades the nine core
                          categories class / camp / missing / na, does the paladin blessing
                          maths and builds a camp plan: campfire tier + cook, one object per
                          player (greedy by scarcity, then augmenting paths for coverage)
       Providers          Buffs:Providers(key) -> category keys that player can cast
       Live scan          Buffs:Scan(cb) reads every group member's buffs out of combat,
                          10 units a frame; camp components come from self-reports ("BQ")
       Camp pings         "CP" whispers an assignee a road-sign toast, "CA" acknowledges it

     Forever rules this leans on: camp objects are weaker, mutually exclusive copies of a
     class buff; all of a player's camp objects share one 1-hour cooldown and a player puts
     down one object per fire; fires can't go down in instances or cities; Kings and Divine
     Spirit are baseline; Greater Blessings stay class-targeted (each paladin gives each
     class one blessing). Class is never inferred from faction.
     Fires GF_BUFFS_UPDATED(what) when "self", "scan", "report", "ping" or "ack" data changes. ]]

local _, GF = ...
local API, U, UI = GF.API, GF.Util, GF.UI
local D = GF.BuffData

local Buffs = GF:NewModule("Buffs")
GF.Buffs = Buffs

local type, pairs, ipairs, tostring, tonumber, next, rawget, pcall = type, pairs, ipairs, tostring, tonumber, next, rawget, pcall
local floor, ceil, max, min, random = math.floor, math.ceil, math.max, math.min, math.random
local sort, concat = table.sort, table.concat

-------------------------------------------------------------------------------
-- Tables
-------------------------------------------------------------------------------
-- who benefits: the hybrids (Druid, Shaman, Paladin) count as mana users AND physical
local MANA = { PRIEST = true, MAGE = true, WARLOCK = true, DRUID = true, SHAMAN = true, PALADIN = true }
local PHYSICAL = { WARRIOR = true, ROGUE = true, HUNTER = true, DRUID = true, SHAMAN = true, PALADIN = true }

-- trainer levels used to guess what a player without Greenfields can cast (Classic values;
-- the data file's minLevel wins where it has one)
local LEARN = {
    stamina = 1, wild = 1, kings = 20, intellect = 1, spirit = 30, wisdom = 14, might = 4,
    strength = 10, crit = 40, lotp = 40, battleshout = 1, trueshot = 40, grace = 42,
    windfury = 32, manaspring = 26, bloodpact = 4, salvation = 26, light = 40,
    shadowprot = 30, aura = 1, wildres = 46,
}

-- how much each core buff matters to the score (scaled by how many people it helps)
local WEIGHT = { stamina = 1.2, wild = 1.1, kings = 1.3, intellect = 0.9, spirit = 0.6,
                 wisdom = 0.8, might = 1.0, strength = 0.8, crit = 0.7 }
local CREDIT = { class = 1, camp = 0.7 }   -- camp buffs are the weaker copy
local PARTIAL = 0.35                        -- a maybe-talent, or a camp object still on cooldown

local SHORT = {
    stamina = "Fort", wild = "MotW", kings = "Kings", intellect = "Int", spirit = "Spirit",
    wisdom = "Wisdom", might = "Might", strength = "SoE", crit = "Crit", lotp = "LotP",
    battleshout = "Shout", trueshot = "Trueshot", grace = "Grace", windfury = "Windfury",
    manaspring = "Mana Spring", bloodpact = "Blood Pact", salvation = "Salv", light = "Light",
    shadowprot = "Shadow Prot", aura = "Aura", wildres = "Nature Res",
}
local WHO = { all = "everyone", mana = "mana users", physical = "physical damage" }
local BLESS = { kings = true, might = true, wisdom = true, light = true }

local UNITS_PER_FRAME = 10
local REPORT_TTL = 4200       -- camp self-reports outlive the 1-hour buff a little (Permanence)
local MAX_NOTES = 8
local PING_SOUND = 8959       -- SOUNDKIT.RAID_WARNING

Buffs.SHORT, Buffs.WHO = SHORT, WHO

local CORE, EXTRA = {}, {}
for _, c in ipairs(D.categories) do
    if c.core then CORE[#CORE + 1] = c else EXTRA[#EXTRA + 1] = c end
end

local FIRES = {}
for _, f in ipairs(D.campfires) do FIRES[f.key] = f end

local CLASS_SET = {}
for _, c in ipairs(API.CLASSES) do CLASS_SET[c] = true end

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------
local function now() return API.ServerTime() end

--- Trailing debounce on a single live timer: call(sec) runs fn `sec` after the latest call,
-- but never later than maxWait after the first. (GF:Debounce arms a timer per call, and
-- bag/aura storms would pile them up against the client's timer budget.)
local function coalesce(fn, maxWait)
    local due, first, pending = 0, 0, false
    local function fire()
        local wait = min(due, first + maxWait) - API.Time()
        if wait > 0.05 then
            GF:After(wait, fire)
            return
        end
        pending = false
        fn()
    end
    return function(sec)
        local t = API.Time()
        if pending then
            due = max(due, t + sec)
            return
        end
        pending, first, due = true, t, t + sec
        GF:After(sec, fire)
    end
end
Buffs.Coalesce = coalesce

local function cleanKey(k)
    k = API.CleanString(k)
    if k and k ~= "" then return k end
    return nil
end

local function validClass(c)
    c = API.CleanString(c)
    return (c and CLASS_SET[c]) and c or nil
end

local function learnLevel(cat) return cat.minLevel or LEARN[cat.key] or 1 end

--- Does a member of this class gain anything from the category?
local function benefits(cat, class)
    if cat.who == "mana" then return class ~= nil and MANA[class] == true end
    if cat.who == "physical" then return class ~= nil and PHYSICAL[class] == true end
    return true
end
Buffs.Benefits = benefits

local function profileOf(key)
    local P = GF.Profile
    if not key or not (P and P.Get) then return nil end
    local ok, doc = pcall(P.Get, P, key)
    return (ok and type(doc) == "table") and doc or nil
end

local function anyKnown(ids)
    if type(ids) ~= "table" then return false end
    for _, id in ipairs(ids) do
        if API.Knows(id) then return true end
    end
    return false
end

local function anyExists(ids)
    if type(ids) ~= "table" then return false end
    for _, id in ipairs(ids) do
        if API.SpellName(id) then return true end
    end
    return false
end

--- Can this client answer "is this spell known" at all?
local function canProbe()
    if type(rawget(_G, "IsPlayerSpell")) == "function" then return true end
    local CSB = rawget(_G, "C_SpellBook")
    if type(CSB) == "table" and type(CSB.IsSpellKnown) == "function" then return true end
    return type(rawget(_G, "IsSpellKnown")) == "function"
end

local function keysOf(list)
    local out = {}
    for i, v in ipairs(list or {}) do out[i] = v.key end
    return out
end

local function objName(objKey)
    local o = objKey and D.campByKey[objKey]
    return o and o.name or "camp object"
end

local function catLabel(catKey)
    local c = catKey and D.byKey[catKey]
    return c and c.label or "buffs"
end

--- Bare name for chat text (U.ShortName marks other realms with a "*", which reads oddly in chat).
local function bareName(key)
    return type(key) == "string" and key:match("^([^%-]+)") or "mate"
end

--- s cut to at most n bytes without splitting a UTF-8 character (chat drops broken ones).
local function cutUTF8(s, n)
    if #s <= n then return s end
    local i = n
    while i > 0 do
        local b = s:byte(i + 1)
        if not b or b < 128 or b >= 192 then break end
        i = i - 1
    end
    return s:sub(1, i)
end

-------------------------------------------------------------------------------
-- Self capabilities (published on my profile)
-------------------------------------------------------------------------------
local mine = { caps = nil, camp = nil, sig = nil, pending = false }

local function computeCaps()
    local class = validClass(API.UnitClassFile("player"))
    local level = API.UnitLevel("player")
    local probe = canProbe()
    local out = {}
    for _, cat in ipairs(D.categories) do
        local has = probe and (anyKnown(cat.probe) or anyKnown(cat.ids))
        if not has and not cat.talent and class and cat.classes and cat.classes[class] and level >= learnLevel(cat) then
            -- the client can't answer for this one (no probe API, or the IDs moved): trust class + level
            has = (not probe) or not (anyExists(cat.probe) or anyExists(cat.ids))
        end
        if has then out[#out + 1] = cat.key end
    end
    return out
end

local function lastPlaced()
    local c = GF.cdb and GF.cdb.buffs
    return (type(c) == "table" and type(c.placed) == "number") and c.placed or 0
end

local function bagCount(id) return API.CleanNumber(API.ItemCount(id)) or 0 end
local function cooldownLeft(id) return API.CleanNumber(API.ItemCooldownLeft(id)) or 0 end

local function cookingRank()
    local best = 0
    for _, p in ipairs(API.Professions()) do
        local line = API.CleanNumber(p.skillLine)
        if line then line = D.childSkillLines[line] or line end
        if line == 185 then best = max(best, API.CleanNumber(p.rank) or 0) end
    end
    return best
end

local function computeCamp()
    local known, kits, fires, fireKits = {}, {}, {}, {}
    local held, left = 0, 0
    for _, o in ipairs(D.camp) do
        if anyKnown(o.recipes) then known[#known + 1] = o.key end
        local n = 0
        for _, id in ipairs(o.items or {}) do
            n = n + bagCount(id)
            left = max(left, cooldownLeft(id))
        end
        if n > 0 then
            kits[o.key] = n
            held = held + n
        end
    end
    for _, f in ipairs(D.campfires) do
        if API.Knows(f.recipe) then fires[#fires + 1] = f.key end
        local n = bagCount(f.item)
        if n > 0 then fireKits[f.key] = n end
    end
    local t = now()
    local readyAt = left > 0 and (t + left) or 0
    -- no kit to read a cooldown from: fall back to the last placement we saw ourselves
    if held == 0 then readyAt = max(readyAt, lastPlaced() + (D.CAMP_COOLDOWN or 3600)) end
    -- rounded to the minute so the published doc doesn't wobble every refresh
    readyAt = (readyAt > t) and (ceil(readyAt / 60) * 60) or 0
    return {
        c = known[1] and known or nil,
        k = next(kits) and kits or nil,
        cd = readyAt,
        f = fires[1] and fires or nil,
        fk = next(fireKits) and fireKits or nil,
        ck = cookingRank(),
    }
end

local function refreshSelf()
    if API.InCombat() and mine.caps then
        mine.pending = true
        return
    end
    mine.pending = false
    mine.caps = computeCaps()
    mine.camp = computeCamp()
    local ok, sig = pcall(GF.Serialize.Encode, { mine.caps, mine.camp })
    sig = ok and sig or nil
    if sig ~= mine.sig then
        mine.sig = sig
        if GF.Profile and GF.Profile.Touch then GF.Profile:Touch() end
        GF:Fire("GF_BUFFS_UPDATED", "self")
    end
end

local selfSoon = coalesce(refreshSelf, 10)
local function queueSelf(sec) selfSoon(sec or 2) end

function Buffs:SelfCaps()
    if not mine.caps then refreshSelf() end
    return U.Copy(mine.caps or {})
end

function Buffs:SelfCamp()
    if not mine.camp then refreshSelf() end
    return U.Copy(mine.camp)
end

GF.Profile:Contribute("caps", function() return Buffs:SelfCaps() end)
GF.Profile:Contribute("camp", function() return Buffs:SelfCamp() end)

-- Placing an object starts the shared cooldown. Item-use spells are only known for a few
-- objects, so the rest match by name; recipe and campfire spells never count.
local PLACE = { [1307229] = true, [1307230] = true }
local NOT_PLACE = {}
for _, o in ipairs(D.camp) do
    for _, id in ipairs(o.recipes or {}) do NOT_PLACE[id] = true end
end
for _, f in ipairs(D.campfires) do
    NOT_PLACE[f.recipe] = true
    for _, id in ipairs(f.useSpells or {}) do NOT_PLACE[id] = true end
end
local objNames

local function isPlacement(id)
    if PLACE[id] then return true end
    if NOT_PLACE[id] then return false end
    -- the kits' own use spells: tier 2/3 objects (Fermenter, Anvil...) aren't named after
    -- the tier-1 object, so learn them from the items (only runs once per new spell ID)
    for _, o in ipairs(D.camp) do
        for _, item in ipairs(o.items or {}) do
            local _, sid = API.ItemSpell(item)
            if sid and not NOT_PLACE[sid] then PLACE[sid] = true end
        end
    end
    if PLACE[id] then return true end
    local n = API.CleanString(API.SpellName(id))
    if n then
        if not objNames then
            objNames = {}
            for _, o in ipairs(D.camp) do objNames[o.name:lower()] = true end
        end
        if objNames[n:lower()] then
            PLACE[id] = true
            return true
        end
    end
    NOT_PLACE[id] = true
    return false
end

-------------------------------------------------------------------------------
-- Member model: what one person brings (profile caps for Greenfields users, a class +
-- level guess for everyone else)
-------------------------------------------------------------------------------
local function toSet(list, valid)
    local s = {}
    if type(list) == "table" then
        for _, k in ipairs(list) do
            if type(k) == "string" and valid[k] then s[k] = true end
        end
    end
    return s
end

local function countMap(t, valid)
    local out = {}
    if type(t) == "table" then
        for k, n in pairs(t) do
            if type(k) == "string" and valid[k] and type(n) == "number" and n > 0 then out[k] = n end
        end
    end
    return out
end

local function normCamp(c)
    if type(c) ~= "table" then return nil end
    return {
        known = toSet(c.c, D.campByKey), kits = countMap(c.k, D.campByKey),
        fires = toSet(c.f, FIRES), fireKits = countMap(c.fk, FIRES),
        cd = type(c.cd) == "number" and c.cd or 0,
        cook = type(c.ck) == "number" and c.ck or 0,
    }
end

--- Older profiles without a camp field: recipe knowledge from the Professions module.
local function profsCamp(key, prof)
    local cook = prof and type(prof.profs) == "table" and tonumber(prof.profs[185]) or 0
    local out = { known = {}, kits = {}, fires = {}, fireKits = {}, cd = 0, cook = cook or 0 }
    local any = (cook or 0) > 0
    local P = GF.Profs
    if P and type(P.Recipes) == "function" then
        local cache = {}
        local function recipes(line)
            if cache[line] == nil then
                local set = {}
                local ok, list = GF:Safe("buffs:profs", P.Recipes, P, key, line)
                if ok and type(list) == "table" then
                    for _, id in ipairs(list) do
                        if type(id) == "number" then set[id] = true end
                    end
                end
                cache[line] = set
            end
            return cache[line]
        end
        for _, o in ipairs(D.camp) do
            if o.buff and o.prof then
                local set = recipes(o.prof)
                for _, id in ipairs(o.recipes or {}) do
                    if set[id] then
                        out.known[o.key] = true
                        any = true
                        break
                    end
                end
            end
        end
        local set = recipes(185)
        for _, f in ipairs(D.campfires) do
            if set[f.recipe] then
                out.fires[f.key] = true
                any = true
            end
        end
    end
    return any and out or nil
end

--- noCamp: skip the camp model (Providers only needs the class side).
local function memberInfo(key, m, noCamp)
    local R = GF.Roster
    local isMe = key == API.MyKey()
    local prof = profileOf(key)
    local info = { key = key, me = isMe }
    info.class = (m and validClass(m.class)) or validClass(R:Class(key)) or (prof and validClass(prof.class))
    if isMe then info.class = info.class or validClass(API.UnitClassFile("player")) end
    local lvl = m and API.CleanNumber(m.level)
    if not lvl or lvl <= 0 then lvl = API.CleanNumber(R:Level(key)) end
    if (not lvl or lvl <= 0) and prof then lvl = API.CleanNumber(prof.level) end
    if isMe and (not lvl or lvl <= 0) then lvl = API.UnitLevel("player") end
    -- unknown level: planning is for raids, so assume max level
    info.level = (lvl and lvl > 0) and lvl or 60
    if isMe then
        info.caps = toSet(Buffs:SelfCaps(), D.byKey)
        if not noCamp then info.camp = normCamp(Buffs:SelfCamp()) end
    else
        if prof and type(prof.caps) == "table" then info.caps = toSet(prof.caps, D.byKey) end
        if not noCamp then info.camp = normCamp(prof and prof.camp) or profsCamp(key, prof) end
    end
    info.online = isMe or (R:IsOnline(key) and true or false)
    info.inGroup = R:InGroup(key) and true or false
    info.addon = isMe or prof ~= nil or (GF.Comm and GF.Comm:HasAddon(key) ~= nil) or false
    return info
end

--- "yes" (casts it), "maybe" (needs a talent we can't see) or nil.
local function canProvide(info, cat)
    if info.caps then return info.caps[cat.key] and "yes" or nil end
    local cls = info.class
    if not cls or not cat.classes or not cat.classes[cls] then return nil end
    if info.level < learnLevel(cat) then return nil end
    return cat.talent and "maybe" or "yes"
end

local function presence(info) return (info.inGroup and 2 or 0) + (info.online and 1 or 0) end

local function byPresence(a, b)
    local pa, pb = presence(a), presence(b)
    if pa ~= pb then return pa > pb end
    return a.key < b.key
end

--- Everyone who could put this object down: knows a recipe (any tier) or holds a kit.
local function campCandidates(infos, obj, at)
    local out = {}
    for _, info in ipairs(infos) do
        local c = info.camp
        if c then
            local kits = c.kits[obj.key] or 0
            if kits > 0 or c.known[obj.key] then
                local readyAt = c.cd or 0
                local ready = readyAt <= at
                out[#out + 1] = {
                    info = info, key = info.key, kits = kits, ready = ready, readyAt = readyAt,
                    pref = (ready and 8 or 0) + (kits > 0 and 4 or 0) + presence(info),
                }
            end
        end
    end
    sort(out, function(a, b)
        if a.pref ~= b.pref then return a.pref > b.pref end
        return a.key < b.key
    end)
    return out
end

-------------------------------------------------------------------------------
-- Blessings: each paladin gives each class one Greater Blessing
-------------------------------------------------------------------------------
local function planBlessings(ctx, kingsFromCamp)
    local pals = {}
    for _, info in ipairs(ctx.infos) do
        local p = { key = info.key, info = info }
        local any = false
        for k in pairs(BLESS) do
            local cat = D.byKey[k]
            if cat and canProvide(info, cat) == "yes" then
                p[k] = true
                if k ~= "light" then any = true end
            end
        end
        if any then pals[#pals + 1] = p end
    end
    sort(pals, function(a, b) return byPresence(a.info, b.info) end)
    local wantKings = (ctx.need.kings or 0) > 0
    local wantPhys = (ctx.need.might or 0) > 0
    local wantMana = (ctx.need.wisdom or 0) > 0
    local P = #pals
    local kingsPal, mwPal
    if P == 1 then
        local p = pals[1]
        local canMW = (p.might and wantPhys) or (p.wisdom and wantMana)
        if p.kings and wantKings and not (canMW and kingsFromCamp) then
            kingsPal = p
        elseif canMW then
            mwPal = p
        end
    elseif P >= 2 then
        if wantKings then
            for _, p in ipairs(pals) do
                if p.kings then kingsPal = p break end
            end
        end
        for _, p in ipairs(pals) do
            if p ~= kingsPal and ((p.might and wantPhys) or (p.wisdom and wantMana)) then mwPal = p break end
        end
    end

    local cover, duty, list = {}, {}, {}
    local function give(catKey, p)
        local t = cover[catKey] or {}
        t[#t + 1] = p.key
        cover[catKey] = t
    end
    if kingsPal then
        give("kings", kingsPal)
        duty[kingsPal.key] = "Greater Kings on everyone"
        list[#list + 1] = { key = kingsPal.key, text = "Greater Kings on everyone", short = "Kings on all" }
    end
    if mwPal then
        local long, brief = {}, {}
        if mwPal.might and wantPhys then
            give("might", mwPal)
            long[#long + 1] = "Greater Might on the physical classes"
            brief[#brief + 1] = "Might on physical"
        end
        if mwPal.wisdom and wantMana then
            give("wisdom", mwPal)
            long[#long + 1] = "Greater Wisdom on the casters"
            brief[#brief + 1] = "Wisdom on casters"
        end
        duty[mwPal.key] = concat(long, ", ")
        list[#list + 1] = { key = mwPal.key, text = concat(long, ", "), short = concat(brief, " / ") }
    end
    -- a spare paladin hands out Light
    if (ctx.need.light or 0) > 0 then
        for _, p in ipairs(pals) do
            if p ~= kingsPal and p ~= mwPal and p.light then
                give("light", p)
                duty[p.key] = "Greater Light (spare paladin)"
                list[#list + 1] = { key = p.key, text = "Greater Light (spare paladin)", short = "Light" }
                break
            end
        end
    end
    return { pals = pals, P = P, cover = cover, duty = duty, list = list, kingsPal = kingsPal, mwPal = mwPal }
end

-------------------------------------------------------------------------------
-- Camp assignment: one object per player. Greedy by scarcity (fewest candidates, most
-- valuable first), then augmenting paths so nobody useful is left on the bench.
-------------------------------------------------------------------------------
local function matchCamp(pending)
    sort(pending, function(a, b)
        local na, nb = #a.cands, #b.cands
        if na ~= nb then return na < nb end
        if a.value ~= b.value then return a.value > b.value end
        return a.cat.order < b.cat.order
    end)
    local owner = {}
    for _, p in ipairs(pending) do
        for _, c in ipairs(p.cands) do
            if not owner[c.key] then
                owner[c.key] = p
                p.pick = c
                break
            end
        end
    end
    local function augment(p, seen)
        for _, c in ipairs(p.cands) do
            if not seen[c.key] then
                seen[c.key] = true
                local cur = owner[c.key]
                if not cur or augment(cur, seen) then
                    owner[c.key] = p
                    p.pick = c
                    return true
                end
            end
        end
        return false
    end
    for _, p in ipairs(pending) do
        if not p.pick and #p.cands > 0 then augment(p, {}) end
    end
end

-------------------------------------------------------------------------------
-- Campfire: tier by object count, cook by reach, rank and kit
-------------------------------------------------------------------------------
local function lightScore(info, fire)
    local c = info.camp
    if not c then return nil end
    local kits = c.fireKits[fire.key] or 0
    if kits <= 0 and not c.fires[fire.key] then return nil end
    local rankOK = (c.cook or 0) >= (fire.cooking or 1) or kits > 0
    return presence(info) * 100000 + (rankOK and 10000 or 0) + (c.cook or 0) * 2 + (kits > 0 and 1 or 0), kits
end

local function bestCook(ctx, fire, exclude)
    local pick, best, pickKits
    for _, info in ipairs(ctx.infos) do
        if info.key ~= exclude then
            local s, kits = lightScore(info, fire)
            if s and (not best or s > best) then best, pick, pickKits = s, info, kits end
        end
    end
    return pick, pickKits
end

local function planFire(ctx, assignments)
    local plan = { assignments = assignments, fires = 0 }
    local n = #assignments
    if n == 0 then return plan end
    local nf = #D.campfires
    local want = n <= 3 and 1 or (n <= 5 and 2 or 3)
    want = min(want, nf)
    plan.want = D.campfires[want].key
    -- the tier we want, then bigger fires, then smaller ones (and a second fire)
    local order = { want }
    for t = want + 1, nf do order[#order + 1] = t end
    for t = want - 1, 1, -1 do order[#order + 1] = t end
    for _, tier in ipairs(order) do
        local fire = D.campfires[tier]
        local cook, kits = bestCook(ctx, fire)
        if cook then
            plan.fire, plan.cook, plan.cookRank, plan.cookKits = fire.key, cook.key, cook.camp.cook, kits
            plan.rankShort = (cook.camp.cook or 0) < (fire.cooking or 1) and (kits or 0) <= 0
            break
        end
    end
    plan.fire = plan.fire or plan.want
    local slots = FIRES[plan.fire].slots or 3
    plan.slots = slots
    plan.fires = ceil(n / slots)
    if plan.fires > 1 then
        for t = nf, 1, -1 do
            local other = bestCook(ctx, D.campfires[t], plan.cook)
            if other then
                plan.extraCook, plan.extraFire = other.key, D.campfires[t].key
                break
            end
        end
    end
    return plan
end

-------------------------------------------------------------------------------
-- Scoring and notes
-------------------------------------------------------------------------------
local function scoreOf(cats)
    local sumW, got = 0, 0
    for _, cat in ipairs(CORE) do
        local e = cats[cat.key]
        if e and e.status ~= "na" then
            local w = (WEIGHT[cat.key] or 1) * (e.need or 0)
            local credit = CREDIT[e.status] or 0
            if e.status == "missing" and (e.cooldown or (e.maybe and e.maybe[1])) then credit = PARTIAL end
            sumW = sumW + w
            got = got + w * credit
        end
    end
    if sumW <= 0 then return 0 end
    return floor(got * 100 / sumW + 0.5)
end

local function joinNames(list, word)
    local n = #list
    if n <= 1 then return list[1] or "" end
    return concat(list, ", ", 1, n - 1) .. " " .. (word or "and") .. " " .. list[n]
end

local function buildNotes(ctx, res)
    local notes = {}
    local function add(s)
        if s and #notes < MAX_NOTES then notes[#notes + 1] = s end
    end
    local function nm(key)
        local info = ctx.byKey[key]
        return U.ClassName(key, info and info.class)
    end
    local function names(keys, cap, word)
        local out = {}
        for i, k in ipairs(keys or {}) do
            if cap and i > cap then break end
            out[#out + 1] = nm(k)
        end
        return joinNames(out, word)
    end
    local cats, plan, bl = res.cats, res.plan, res.bless
    local as = plan.assignments
    local function statusOf(k) return cats[k] and cats[k].status end

    -- blessings first: the paladins need to know what's theirs
    if bl.P == 1 and (bl.kingsPal or bl.mwPal) then
        if bl.mwPal then
            local s = "Only one paladin, so " .. nm(bl.mwPal.key) .. " does " .. (bl.duty[bl.mwPal.key] or "the blessings")
            if statusOf("kings") == "camp" then s = s .. " - a Fish Bowl covers Kings" end
            add(s .. ".")
        else
            local fill = {}
            if statusOf("might") == "camp" then fill[#fill + 1] = "Lodestone" end
            if statusOf("wisdom") == "camp" then fill[#fill + 1] = "Mana Well" end
            local s = "Only one paladin, so " .. nm(bl.kingsPal.key) .. " does Greater Kings on everyone"
            if fill[1] then s = s .. " - " .. joinNames(fill) .. " fill in the rest" end
            add(s .. ".")
        end
    elseif bl.P >= 2 and bl.list[1] then
        local parts = {}
        for _, b in ipairs(bl.list) do parts[#parts + 1] = nm(b.key) .. ": " .. b.text end
        add("Blessings - " .. concat(parts, ". ") .. ".")
    end

    if #as > 0 then
        add("Fires can't go down inside instances or cities - set up at the raid entrance before the pull.")
        add("Sit by the fire for about a minute and the lot rolls into one Camp Benefits buff (1 hour).")
        local fire = FIRES[plan.fire]
        if not plan.cook then
            local s = "Nobody's carrying a campfire. Any cook can make a Basic Campfire Kit (Flint and Tinder + Simple Wood)"
            if plan.want ~= "basic" then s = s .. ", but this many objects wants a " .. FIRES[plan.want].name end
            add(s .. ".")
        elseif plan.rankShort and fire then
            add(nm(plan.cook) .. " knows the " .. fire.name .. " but might need " .. fire.cooking .. " Cooking to light it.")
        end
        if plan.fires > 1 then
            local s = ("That's %d objects and a %s holds %d"):format(#as, fire and fire.name or "fire", plan.slots or 3)
            if plan.extraCook then
                s = s .. " - " .. nm(plan.extraCook) .. " lights a second fire about 100 yd away."
            else
                s = s .. " - you'll want a second fire about 100 yd away."
            end
            add(s)
        end
    end

    local crit = cats.crit
    if crit and crit.status == "camp" then
        if crit.maybe[1] then
            add("Camp Chair and Moonkin Aura don't stack - if " .. names(crit.maybe, 3, "or") .. " is Balance, skip the chair.")
        else
            add("Camp Chair stands in for Moonkin Aura. They don't stack, so a Boomkin makes it redundant.")
        end
    elseif crit and crit.status == "missing" and crit.maybe[1] then
        add("No confirmed Boomkin. If " .. names(crit.maybe, 3, "or") .. " is Balance, spell crit's sorted.")
    end

    local craft = {}
    for _, a in ipairs(as) do
        if a.object == "faction_banner" then add("Faction Banner only buffs your own faction.") end
        if a.state == "cooldown" then
            add(nm(a.player) .. "'s camp cooldown is up in " .. U.Duration(a.readyAt - now()) .. ".")
        elseif a.state == "craft" then
            craft[#craft + 1] = a
        end
    end
    if #craft == 1 then
        add(nm(craft[1].player) .. " knows the " .. objName(craft[1].object) .. " but has no kit on them - craft one before the raid.")
    elseif #craft > 1 then
        add(#craft .. " of the camp crew need to craft their kits before the raid.")
    end
    for _, u in ipairs(res.unassigned) do
        if u.reason == "busy" then
            add("Nobody spare for the " .. objName(u.object) .. " - " .. names(u.cands, 3) .. " can only drop one object each.")
        end
    end
    if #as > 0 then
        add("Camp buffs are weaker copies of the class buffs and don't stack with them. Class buffs win where you've got them.")
    end
    return notes
end

local function buildPeople(ctx, res)
    local people = {}
    local assigned = {}
    for _, a in ipairs(res.plan.assignments) do assigned[a.player] = a end
    for _, info in ipairs(ctx.infos) do
        local p = {
            class = info.class, level = info.level, addon = info.addon, online = info.online,
            inGroup = info.inGroup, me = info.me, guessed = info.caps == nil, provides = {}, maybe = {},
        }
        for _, cat in ipairs(D.categories) do
            local v = canProvide(info, cat)
            if v == "yes" then
                p.provides[#p.provides + 1] = cat.key
            elseif v == "maybe" then
                p.maybe[#p.maybe + 1] = cat.key
            end
        end
        local a = assigned[info.key]
        local c = info.camp
        if a then p.campObj, p.assigned = a.object, a.object end
        if c then
            if not p.campObj then
                -- the best object they could drop: a kit in the bags beats a recipe
                for _, cat in ipairs(CORE) do
                    if cat.camp and (c.kits[cat.camp] or 0) > 0 then p.campObj = cat.camp break end
                end
                if not p.campObj then
                    for _, cat in ipairs(CORE) do
                        if cat.camp and c.known[cat.camp] then p.campObj = cat.camp break end
                    end
                end
            end
            if p.campObj then p.campKits = c.kits[p.campObj] or 0 end
            p.campReadyAt = c.cd or 0
            p.campReady = (c.cd or 0) <= ctx.at
            p.cooking = c.cook
        end
        local duty = {}
        if res.bless.duty[info.key] then duty[#duty + 1] = res.bless.duty[info.key] end
        if a then duty[#duty + 1] = "drop a " .. objName(a.object) end
        if res.plan.cook == info.key then
            p.cook = true
            duty[#duty + 1] = "light the " .. (FIRES[res.plan.fire] and FIRES[res.plan.fire].name or "fire")
        elseif res.plan.extraCook == info.key then
            p.cook = true
            duty[#duty + 1] = "light the second fire"
        end
        p.duty = duty[1] and concat(duty, "; ") or nil
        people[info.key] = p
    end
    return people
end

-------------------------------------------------------------------------------
-- Analyse
-------------------------------------------------------------------------------
local function solve(ctx, kingsFromCamp)
    local bl = planBlessings(ctx, kingsFromCamp)
    local cats, pending = {}, {}
    for _, cat in ipairs(D.categories) do
        local key = cat.key
        local e = {
            status = nil, providers = {}, camp = {}, need = ctx.need[key] or 0,
            capable = keysOf(ctx.yes[key]), maybe = keysOf(ctx.maybe[key]),
        }
        if e.need == 0 then
            e.status = "na"
        elseif BLESS[key] then
            if bl.cover[key] then
                e.status = "class"
                e.providers = bl.cover[key]
            end
        elseif e.capable[1] then
            e.status = "class"
            e.providers = keysOf(ctx.yes[key])
        end
        if not e.status then
            local obj = cat.core and cat.camp and D.campByKey[cat.camp]
            if obj then
                pending[#pending + 1] = { cat = cat, obj = obj, cands = ctx.cands[obj.key] or {}, e = e,
                                          value = (WEIGHT[key] or 1) * e.need }
            else
                e.status = "missing"
            end
        end
        cats[key] = e
    end

    matchCamp(pending)
    local assignments, unassigned = {}, {}
    for _, p in ipairs(pending) do
        local e, c = p.e, p.pick
        local camp = {}
        if c then camp[1] = c.key end
        for _, cand in ipairs(p.cands) do
            if cand ~= c then camp[#camp + 1] = cand.key end
        end
        e.camp = camp
        if c then
            e.assigned = c.key
            if c.ready then
                e.status = "camp"
            else
                e.status = "missing"
                e.cooldown = c.readyAt
            end
            assignments[#assignments + 1] = {
                player = c.key, object = p.obj.key, buff = p.cat.key,
                state = c.ready and (c.kits > 0 and "ready" or "craft") or "cooldown",
                kits = c.kits, readyAt = c.readyAt, online = c.info.online, inGroup = c.info.inGroup,
                addon = c.info.addon, class = c.info.class,
            }
        else
            e.status = "missing"
            e.blocked = p.cands[1] ~= nil
            unassigned[#unassigned + 1] = {
                object = p.obj.key, buff = p.cat.key, cands = keysOf(p.cands),
                reason = p.cands[1] and "busy" or "nobody",
            }
        end
    end
    sort(assignments, function(a, b) return D.byKey[a.buff].order < D.byKey[b.buff].order end)
    sort(unassigned, function(a, b) return D.byKey[a.buff].order < D.byKey[b.buff].order end)

    local res = { cats = cats, bless = bl, unassigned = unassigned }
    res.plan = planFire(ctx, assignments)
    res.score = scoreOf(cats)
    res.people = buildPeople(ctx, res)
    res.notes = buildNotes(ctx, res)
    return res
end

local function emptyReport()
    local cats = {}
    for _, cat in ipairs(D.categories) do
        cats[cat.key] = { status = "na", providers = {}, camp = {}, capable = {}, maybe = {}, need = 0 }
    end
    return { cats = cats, plan = { assignments = {}, fires = 0 }, score = 0, missing = {}, notes = {},
             people = {}, blessings = {}, unassigned = {}, count = 0, addon = 0, at = now() }
end

local function analyze(members, opts)
    local t = now()
    local at = type(opts) == "table" and API.CleanNumber(opts.at) or nil
    if not at or at < t then at = t end
    local ctx = { infos = {}, byKey = {}, at = at, need = {}, yes = {}, maybe = {}, cands = {} }
    local n = type(members) == "table" and #members or 0
    for i = 1, n do
        local m = members[i]
        local key = (type(m) == "table" and cleanKey(m.key or m.name)) or cleanKey(m)
        if key and not ctx.byKey[key] then
            local info = memberInfo(key, type(m) == "table" and m or nil)
            ctx.infos[#ctx.infos + 1] = info
            ctx.byKey[key] = info
        end
    end
    if not ctx.infos[1] then return emptyReport() end

    for _, cat in ipairs(D.categories) do
        local need, yes, maybe = 0, {}, {}
        for _, info in ipairs(ctx.infos) do
            if benefits(cat, info.class) then need = need + 1 end
            local v = canProvide(info, cat)
            if v == "yes" then
                yes[#yes + 1] = info
            elseif v == "maybe" then
                maybe[#maybe + 1] = info
            end
        end
        sort(yes, byPresence)
        sort(maybe, byPresence)
        ctx.need[cat.key], ctx.yes[cat.key], ctx.maybe[cat.key] = need, yes, maybe
    end
    for _, o in ipairs(D.camp) do
        if o.buff then ctx.cands[o.key] = campCandidates(ctx.infos, o, at) end
    end

    -- One paladin: Might/Wisdom from them and Kings from a Fish Bowl when a fisher's ready,
    -- otherwise Kings from them. If the bowl gets squeezed out, keep whichever scores better.
    local fishOK = false
    for _, c in ipairs(ctx.cands.fish_bowl or {}) do
        if c.ready then fishOK = true break end
    end
    local best = solve(ctx, fishOK)
    local pal = best.bless.pals[1]
    local kings = best.cats.kings
    if fishOK and best.bless.P == 1 and pal and pal.kings and (pal.might or pal.wisdom) and kings and kings.status ~= "camp" then
        local alt = solve(ctx, false)
        if alt.score > best.score then best = alt end
    end

    local addon = 0
    for _, info in ipairs(ctx.infos) do
        if info.addon then addon = addon + 1 end
    end
    local rep = {
        cats = best.cats, plan = best.plan, score = best.score, missing = {}, notes = best.notes,
        people = best.people, blessings = best.bless.list, unassigned = best.unassigned,
        paladins = best.bless.P, count = #ctx.infos, addon = addon, at = at,
    }
    for _, cat in ipairs(CORE) do
        if rep.cats[cat.key].status == "missing" then rep.missing[#rep.missing + 1] = cat.key end
    end
    return rep
end

--- Analyze(members [, opts]) -> report (see CORE_API.md section 5). Never raises.
-- members: array of { key, class, level }. opts.at: when the raid happens (server time),
-- so camp cooldowns that are up by then count as ready.
function Buffs:Analyze(members, opts)
    local ok, rep = GF:Safe("buffs:analyze", analyze, members, opts)
    if ok and type(rep) == "table" then return rep end
    return emptyReport()
end

--- Providers(key) -> array of category keys that player can cast (class buffs only).
function Buffs:Providers(key)
    local ok, out = GF:Safe("buffs:providers", function()
        local list = {}
        local k = cleanKey(key)
        if not k then return list end
        local info = memberInfo(k, nil, true)
        for _, cat in ipairs(D.categories) do
            if canProvide(info, cat) == "yes" then list[#list + 1] = cat.key end
        end
        return list
    end)
    return (ok and type(out) == "table") and out or {}
end

--- CampOf(key) -> { objects = {objKeys}, kits = {[obj] = n}, readyAt, cooking, fires = {fireKeys} } or nil.
function Buffs:CampOf(key)
    local ok, out = GF:Safe("buffs:campof", function()
        local k = cleanKey(key)
        if not k then return nil end
        local c = memberInfo(k, nil).camp
        if not c then return nil end
        local objs, fires = {}, {}
        for _, o in ipairs(D.camp) do
            if c.known[o.key] or (c.kits[o.key] or 0) > 0 then objs[#objs + 1] = o.key end
        end
        for _, f in ipairs(D.campfires) do
            if c.fires[f.key] or (c.fireKits[f.key] or 0) > 0 then fires[#fires + 1] = f.key end
        end
        return { objects = objs, kits = U.Copy(c.kits), readyAt = c.cd, cooking = c.cook, fires = fires }
    end)
    return (ok and type(out) == "table") and out or nil
end

function Buffs:CoreCategories() return CORE end
function Buffs:ClassCategories() return EXTRA end

--- The current group as Analyze input (plus unit, subgroup, online, role).
function Buffs:GroupInput()
    local out = {}
    local list = GF.Roster:Group()
    if type(list) ~= "table" or not list[1] then list = API.GroupMembers() end
    for _, g in ipairs(list) do
        if g.key then
            out[#out + 1] = { key = g.key, class = g.class, level = g.level, group = g.subgroup,
                              unit = g.unit, online = g.online, role = g.role }
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Live buff scan (out of combat only; buffs read as secret otherwise)
-------------------------------------------------------------------------------
local live = { t = nil, stale = false, running = false, started = 0, units = {} }
local waiting = {}
local scanGen = 0
local reports = {}          -- key -> { cb, o = {[objKey] = true} | nil, u, t } from "BQ"
local cbName
local requestReports

local function campBenefitsName()
    if not cbName then cbName = API.CleanString(API.SpellName(D.CAMP_BENEFITS)) end
    return cbName or "Camp Benefits"
end

--- My own camp state: Camp Benefits plus whichever hidden components the client shows.
local function selfCampState()
    if API.InCombat() or API.AurasSecret() then return nil end
    local cb = API.PlayerHasAura(D.CAMP_BENEFITS)
    if not cb then
        local nm = campBenefitsName()
        API.ForEachBuff("player", function(_, name)
            if name == nm then
                cb = true
                return true
            end
        end)
    end
    local o
    for _, obj in ipairs(D.camp) do
        if obj.aura and obj.buff and API.PlayerHasAura(obj.aura) then
            o = o or {}
            o[#o + 1] = obj.key
        end
    end
    return { cb = cb and true or false, o = o }
end

local function readUnit(entry)
    local unit = entry.unit
    if type(unit) ~= "string" then return nil end
    local isMe = entry.key == API.MyKey()
    if not isMe and (not entry.online or entry.dead or not API.UnitIsVisible(unit)) then
        return { skipped = true }
    end
    local cats, cb, comps = {}, false, nil
    local cbn = campBenefitsName()
    local readable = API.ForEachBuff(unit, function(sid, name)
        local cat = D:CategoryOf(sid, name)
        if cat then cats[cat] = true end
        if sid == D.CAMP_BENEFITS or name == cbn then cb = true end
        local buff = D.campAuraToBuff and D.campAuraToBuff[sid]
        local obj = buff and D.campByBuff[buff]
        if obj then
            comps = comps or {}
            comps[obj.key] = true
        end
    end)
    if not readable then return nil end
    if isMe then
        local st = selfCampState()
        if st then
            cb = cb or st.cb
            for _, k in ipairs(st.o or {}) do
                comps = comps or {}
                comps[k] = true
            end
        end
    end
    return { cats = cats, cb = cb, comps = comps }
end

local function finishScan(ok)
    live.running = false
    local list = waiting
    waiting = {}
    GF:Fire("GF_BUFFS_UPDATED", "scan")
    for _, fn in ipairs(list) do GF:Safe("buffs:scan-cb", fn, ok) end
end

--- Scan([cb(ok)]): reads everyone's buffs, 10 units a frame. Returns false (and marks the
-- last scan stale) when buffs can't be read right now.
function Buffs:Scan(cb)
    if type(cb) == "function" then waiting[#waiting + 1] = cb end
    if live.running and API.Time() - live.started < 5 then return true end
    if API.InCombat() or API.AurasSecret() then
        live.stale = true
        finishScan(false)
        return false
    end
    scanGen = scanGen + 1
    local gen = scanGen
    local list = API.GroupMembers()
    local results, i = {}, 1
    live.running, live.started = true, API.Time()
    requestReports()
    local function step()
        if gen ~= scanGen then return end
        if API.InCombat() or API.AurasSecret() then
            live.stale = true
            finishScan(false)
            return
        end
        local n = 0
        while i <= #list and n < UNITS_PER_FRAME do
            local e = list[i]
            if e.key then
                local r = readUnit(e)
                if r then results[e.key] = r end
            end
            i = i + 1
            n = n + 1
        end
        if i <= #list then
            GF:After(0, step)
            return
        end
        live.units, live.t, live.stale = results, now(), false
        finishScan(true)
    end
    step()
    return true
end

--- Live() -> { t = last scan (server time) or nil, stale = bool, running = bool }
function Buffs:Live()
    return { t = live.t, stale = live.stale, running = live.running }
end

--- LiveFor(key) -> { scanned, skipped, cats = set, cb = bool, comps = set|nil } or nil.
function Buffs:LiveFor(key)
    if type(key) ~= "string" then return nil end
    local u = live.units[key]
    local r = reports[key]
    if r and now() - r.t > REPORT_TTL then
        reports[key] = nil
        r = nil
    end
    if not u and not r then return nil end
    if not u or u.skipped then
        return { scanned = false, skipped = u ~= nil, cats = {}, cb = r and r.cb or false, comps = r and r.o or nil }
    end
    -- a fresh scan wins; the self-report only fills in the hidden components
    local comps = u.comps
    if not comps and u.cb and r and r.cb then comps = r.o end
    return { scanned = true, cats = u.cats or {}, cb = u.cb and true or false, comps = comps }
end

--- HasBuff(live, catKey, report): present as the class buff, or as its camp component.
function Buffs:HasBuff(lv, catKey, rep)
    local cat = D.byKey[catKey]
    if type(lv) ~= "table" or not cat then return false end
    if lv.cats and lv.cats[catKey] then return true end
    local obj = cat.camp
    if obj then
        if lv.comps and lv.comps[obj] then return true end
        -- Camp Benefits with unreadable components: trust the plan
        local e = rep and rep.cats and rep.cats[catKey]
        if lv.cb and not lv.comps and e and e.status == "camp" then return true end
    end
    return false
end

--- MissingFor(key, report) -> core category keys this scanned member lacks that the raid
-- can actually provide (class or camp), or nil when they weren't scanned.
function Buffs:MissingFor(key, rep)
    local lv = self:LiveFor(key)
    if not lv or not lv.scanned or type(rep) ~= "table" or type(rep.cats) ~= "table" then return nil end
    local person = rep.people and rep.people[key]
    local class = (person and person.class) or validClass(GF.Roster:Class(key))
    local out = {}
    for _, cat in ipairs(CORE) do
        local e = rep.cats[cat.key]
        if e and (e.status == "class" or e.status == "camp") and benefits(cat, class) then
            if not self:HasBuff(lv, cat.key, rep) then out[#out + 1] = cat.key end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Camp self-reports ("BQ"): { q = 1 } asks the group, { r = 1, k, cb, o, u } answers.
-- Camp Benefits itself shows in a normal scan; only its components are hidden, so only
-- people actually camped answer a request (plus one "gone" message when the buff drops).
-------------------------------------------------------------------------------
local lastAsk, lastTell, tellQueued, lastCB = -600, -600, false, false
local ASK_EVERY, TELL_EVERY = 60, 30

local function tell(st)
    if not API.GroupChannel() then return end
    st = st or selfCampState()
    if not st then return end
    lastTell, lastCB = API.Time(), st.cb
    GF.Comm:Group("BQ", { r = 1, k = API.MyKey(), cb = st.cb and 1 or 0, o = st.o,
                          u = (st.cb and not st.o) and 1 or nil }, "NORMAL")
end

local function tellSoon()
    if tellQueued or API.Time() - lastTell < TELL_EVERY then return end
    tellQueued = true
    GF:After(0.5 + random() * 2.5, function()
        tellQueued = false
        local st = selfCampState()
        if st and st.cb then tell(st) end
    end)
end

requestReports = function()
    if not API.GroupChannel() or API.Time() - lastAsk < ASK_EVERY then return end
    lastAsk = API.Time()
    GF.Comm:Group("BQ", { q = 1 }, "NORMAL")
end

GF.Comm:Register("BQ", function(p, sender)
    if type(p) ~= "table" then return end
    local R = GF.Roster
    if not (R:InGroup(sender) or R:IsMember(sender)) then return end
    if p.q then
        tellSoon()
        return
    end
    if not p.r then return end
    local o
    if type(p.o) == "table" then
        for _, k in ipairs(p.o) do
            if type(k) == "string" and D.campByKey[k] then
                o = o or {}
                o[k] = true
            end
        end
    end
    reports[sender] = { cb = p.cb == 1 or p.cb == true, o = o, u = p.u and true or nil, t = now() }
    GF:Fire("GF_BUFFS_UPDATED", "report")
end)

-------------------------------------------------------------------------------
-- Camp pings ("CP" -> assignee, "CA" <- ack)
-------------------------------------------------------------------------------
local pings = {}            -- key -> { o, b, sent, how = "addon"|"whisper", ack, off }

--- PingState(key) -> { o, b, sent, how, ack, off } or nil
function Buffs:PingState(key) return key and pings[key] or nil end

--- Leaders, assists and officers can send camp pings.
function Buffs:CanPing()
    return GF.Roster:CanManage(API.MyKey()) or API.CanLeadGroup()
end

function Buffs:HasAddon(key)
    if not key then return false end
    if GF.Comm:HasAddon(key) then return true end
    return profileOf(key) ~= nil
end

--- Ping(key, objKey, buffKey) -> "addon" (sent), "whisper" (no addon: caller offers a
-- whisper from a click), or false.
function Buffs:Ping(key, objKey, buffKey)
    key = cleanKey(key)
    local obj = objKey and D.campByKey[objKey]
    if not key or not obj or key == API.MyKey() then return false end
    -- whispering someone offline only earns a "No player named..." system line
    if not GF.Roster:IsOnline(key) then return false end
    if not self:HasAddon(key) then return "whisper" end
    local ok = GF.Comm:Whisper(key, "CP", { o = obj.key, b = buffKey or obj.buff, from = API.MyKey() }, "ALERT")
    if not ok then return false end
    pings[key] = { o = obj.key, b = buffKey or obj.buff, sent = now(), how = "addon" }
    GF:Fire("GF_BUFFS_UPDATED", "ping")
    return "addon"
end

function Buffs:WhisperText(key, objKey, buffKey)
    local obj = objKey and D.campByKey[objKey]
    local line = U.Pick(GF.Flavor.campPing) or "{name}, the raid needs your {object}."
    local text = GF.Flavor.Fill(line, {
        name = bareName(key), object = obj and obj.name or "camp object",
        buff = catLabel(buffKey or (obj and obj.buff)),
    })
    return U.ChatSafe(text)
end

--- Whisper(key, objKey, buffKey [, text]) -> ok, err. Button clicks only (chat rule);
-- pass the text you previewed so the whisper matches it.
function Buffs:Whisper(key, objKey, buffKey, text)
    key = cleanKey(key)
    if not key or key == API.MyKey() then return false end
    if type(text) ~= "string" or text == "" then text = self:WhisperText(key, objKey, buffKey) end
    local ok, err = API.SendChat(text, "WHISPER", key)
    if ok then
        pings[key] = { o = objKey, b = buffKey, sent = now(), how = "whisper" }
        GF:Fire("GF_BUFFS_UPDATED", "ping")
    end
    return ok, err
end

-- only people who could reasonably be running the raid may put a sign on my screen
local function trustedLeader(sender)
    local R = GF.Roster
    if R:CanManage(sender) then return true end
    return R:Count() == 0 and R:InGroup(sender)
end

GF.Comm:Register("CP", function(p, sender)
    if type(p) ~= "table" or not trustedLeader(sender) then return end
    local obj = type(p.o) == "string" and D.campByKey[p.o]
    if not obj then return end
    local s = GF.db and GF.db.settings or {}
    if s.campPings == false then
        GF.Comm:Whisper(sender, "CA", { o = obj.key, off = 1 })
        return
    end
    local buff = (type(p.b) == "string" and D.byKey[p.b]) and p.b or obj.buff
    local line = GF.Flavor.Random(GF.Flavor.campPing, {
        name = U.ShortName(API.MyKey() or "mate"), object = obj.name, buff = catLabel(buff),
    })
    UI:Toast({
        title = "Camp duty from " .. U.ShortName(sender), text = line, icon = "campfire",
        style = "yellow", duration = 12, sound = false, force = true, key = "camp-ping:" .. obj.key,
        onClick = function() UI:OpenMain("buffs") end,
    })
    if s.toastSounds ~= false then API.PlaySound(PING_SOUND) end
    GF.Comm:Whisper(sender, "CA", { o = obj.key })
end)

GF.Comm:Register("CA", function(p, sender)
    if type(p) ~= "table" then return end
    -- only an answer to a ping we actually sent counts
    local st = pings[sender]
    if not st or st.how ~= "addon" then return end
    st.ack = now()
    st.off = p.off and true or nil
    if type(p.o) == "string" and D.campByKey[p.o] then st.o = p.o end
    pings[sender] = st
    GF:Fire("GF_BUFFS_UPDATED", "ack")
end)

--- PlanLines(report) -> short chat lines for "Post plan" (blessings, fire, objects).
function Buffs:PlanLines(rep)
    local out = {}
    if type(rep) ~= "table" or type(rep.plan) ~= "table" then return out end
    local function nm(k) return U.ChatSafe(bareName(k)) end
    local bl = rep.blessings or {}
    if bl[1] then
        local parts = {}
        for _, b in ipairs(bl) do parts[#parts + 1] = nm(b.key) .. " " .. b.short end
        out[#out + 1] = "Blessings: " .. concat(parts, " | ")
    end
    local plan = rep.plan
    local as = plan.assignments or {}
    if as[1] then
        local fire = plan.fire and FIRES[plan.fire]
        local head = "Camp at the entrance: " .. (fire and fire.name or "a campfire")
        if plan.cook then head = head .. " from " .. nm(plan.cook) end
        if (plan.fires or 1) > 1 then
            head = head .. (plan.extraCook and (", second fire from " .. nm(plan.extraCook)) or ", plus a second fire") .. " 100yd away"
        end
        out[#out + 1] = head .. ". Sit 1 min for Camp Benefits."
        local line = {}
        for _, a in ipairs(as) do
            line[#line + 1] = objName(a.object) .. " (" .. (SHORT[a.buff] or catLabel(a.buff)) .. "): " .. nm(a.player)
            if #line == 3 then
                out[#out + 1] = concat(line, " | ")
                line = {}
            end
        end
        if line[1] then out[#out + 1] = concat(line, " | ") end
    end
    for i, l in ipairs(out) do out[i] = cutUTF8(l, 250) end
    return out
end

-------------------------------------------------------------------------------
-- Ready check: leaders get a one-glance summary
-------------------------------------------------------------------------------
local lastReadyCheck = -60

local function readyCheckToast()
    local members = Buffs:GroupInput()
    if not members[1] then return end
    local rep = Buffs:Analyze(members)
    local counts, scanned = {}, 0
    for _, m in ipairs(members) do
        local miss = Buffs:MissingFor(m.key, rep)
        if miss then
            scanned = scanned + 1
            for _, k in ipairs(miss) do counts[k] = (counts[k] or 0) + 1 end
        end
    end
    if scanned == 0 then return end
    local list = {}
    for _, cat in ipairs(CORE) do
        if counts[cat.key] then list[#list + 1] = { key = cat.key, n = counts[cat.key], order = cat.order } end
    end
    sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.order < b.order
    end)
    if not list[1] then
        UI:Toast({ title = "Buff check", text = "Everyone's got the lot. Beauty.", icon = "check",
                   style = "green", key = "buff-check", onClick = function() UI:OpenMain("buffs") end })
        return
    end
    local parts = {}
    for i = 1, min(4, #list) do parts[i] = (SHORT[list[i].key] or list[i].key) .. " (" .. list[i].n .. ")" end
    local text = "Missing " .. concat(parts, ", ")
    if #list > 4 then text = text .. " +" .. (#list - 4) .. " more" end
    UI:Toast({ title = "Buff check", text = text .. ".", icon = "campfire", style = "yellow",
               key = "buff-check", onClick = function() UI:OpenMain("buffs") end })
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local auraQueued, auraDirty = false, false

-- Camp Benefits came or went: tell the group (rate-limited, out of combat only)
local function auraCheck()
    auraQueued = false
    if API.InCombat() then
        auraDirty = true
        return
    end
    if not API.InGroup() then return end
    local st = selfCampState()
    if not st or st.cb == lastCB then return end
    local wait = 15 - (API.Time() - lastTell)
    if wait <= 0 then
        tell(st)
    else
        -- rate-limited: look again when the window opens, or the change is lost until the
        -- next UNIT_AURA (which may never come once everyone's sat down)
        auraQueued = true
        GF:After(wait + 0.5, auraCheck)
    end
end

GF:RegisterUnitEvent("UNIT_AURA", "player", function()
    if API.InCombat() then
        auraDirty = true
        return
    end
    if not auraQueued then
        auraQueued = true
        GF:After(2, auraCheck)
    end
end)

GF:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID)
    local id = API.CleanNumber(spellID)
    if not id or not GF.cdb or not isPlacement(id) then return end
    GF.cdb.buffs = type(GF.cdb.buffs) == "table" and GF.cdb.buffs or {}
    GF.cdb.buffs.placed = now()
    queueSelf(1.5)
end)

GF:On("GF_GUILD_READY", function()
    GF:After(2, refreshSelf)
    -- the client can answer professions/spells empty at login: look again shortly
    GF:After(15, function() queueSelf(0.1) end)
    GF:After(60, function() queueSelf(0.1) end)
end)

GF:RegisterEvent("BAG_UPDATE_DELAYED", function() queueSelf(5) end)
GF:RegisterEvent("SKILL_LINES_CHANGED", function() queueSelf(2) end)
GF:RegisterEvent("LEARNED_SPELL_IN_TAB", function() queueSelf(2) end)
GF:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE", function() queueSelf(2) end)   -- the 11.x+ name
GF:RegisterEvent("NEW_RECIPE_LEARNED", function() queueSelf(2) end)
GF:RegisterEvent("PLAYER_LEVEL_UP", function() queueSelf(2) end)
-- Moonkin Aura, Leader of the Pack and Trueshot are talents: re-prove caps on a respec
for _, ev in ipairs({ "PLAYER_TALENT_UPDATE", "TRAIT_CONFIG_UPDATED", "CHARACTER_POINTS_CHANGED",
                      "ACTIVE_TALENT_GROUP_CHANGED" }) do
    GF:RegisterEvent(ev, function() queueSelf(2) end)
end

GF:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if mine.pending then queueSelf(1) end
    if auraDirty then
        auraDirty = false
        if not auraQueued then
            auraQueued = true
            GF:After(2, auraCheck)
        end
    end
end)

GF:RegisterEvent("READY_CHECK", function()
    if not API.CanLeadGroup() or API.Time() - lastReadyCheck < 20 then return end
    lastReadyCheck = API.Time()
    Buffs:Scan(function(ok) if ok then readyCheckToast() end end)
end)
