--[[ Greenfields - Core/Store.lua
     Replicated datasets shared across the guild (eventually consistent).

     A dataset is a table of documents keyed by id. Each document record is
       { r = rev, a = authorKey, t = serverTime, d = data, x = deleted? }
     Higher rev wins; equal revs are broken by author key. Deletes are tombstones.

     Two ownership models:
       owner = "player"  the doc id IS a player key and only that player writes it
                         (profiles, stats, professions). Relayed copies are accepted
                         when the author field matches the id.
       owner = "shared"  anyone passing def.canWrite(authorKey, id, data, oldData) may
                         write (events, attendance, loot history, SR...).

     Sync protocol (ops on the Comm layer):
       SU  {c=code, l={{id,rev,author,time,data,deleted},...}}  updates (GUILD broadcast or WHISPER)
       SD  {h={[code]={hash,count,maxRev}}}                        digest (GUILD, or WHISPER reply)
       SQ  {c={code,...}}                                          "send me your index for these"
       SX  {c=code, x={[id]=rev}}                                  index reply
       SG  {c=code, i={id,...}}                                    "send me these docs"

     API
       Store:Define{ name=, code=, owner="player"|"shared", canWrite=fn, lazy=sec, mirrorGroup=bool,
                     keepDays=, onChange=fn(id, data, rec, remote) }
       Store:Get(name, id) -> data | nil        Store:Rec(name, id) -> record | nil
       Store:All(name) -> { [id] = data }       Store:Put(name, id, data) -> ok, err
       Store:Delete(name, id)                   Store:Mine(name) -> my player-owned doc
       Store:PutMine(name, data)                Store:SyncNow()
     Fires GF_STORE_CHANGED(name, id, data, rec, remote) on every change. ]]

local _, GF = ...

local Store = {}
GF.Store = Store

local API, U, Ser, Comm = GF.API, GF.Util, GF.Serialize, GF.Comm
local type, pairs, ipairs, tostring, max = type, pairs, ipairs, tostring, math.max

Store.defs = {}
Store.byCode = {}
local digestCache = {}
local dirty = {}            -- name -> { [id]=true } pending broadcast
local lastSync = {}         -- code -> time we last pulled an index
local SYNC_COOLDOWN = 45

-------------------------------------------------------------------------------
-- Definition & storage
-------------------------------------------------------------------------------
function Store:Define(def)
    assert(type(def.name) == "string" and type(def.code) == "string", "Store:Define needs name+code")
    def.owner = def.owner or "shared"
    def.keepDays = def.keepDays or 120
    self.defs[def.name] = def
    self.byCode[def.code] = def
    return def
end

local function data(name)
    local s = GF.gdb and GF.gdb.store
    if not s then return {} end
    local t = s[name]
    if not t then t = {}; s[name] = t end
    return t
end
Store._data = data

function Store:Rec(name, id)
    if id == nil then return nil end
    return data(name)[id]
end

function Store:Get(name, id)
    local rec = self:Rec(name, id)
    if rec and not rec.x then return rec.d end
    return nil
end

function Store:All(name)
    local out = {}
    for id, rec in pairs(data(name)) do
        if not rec.x then out[id] = rec.d end
    end
    return out
end

function Store:Count(name)
    local n = 0
    for _, rec in pairs(data(name)) do if not rec.x then n = n + 1 end end
    return n
end

function Store:Mine(name) return self:Get(name, API.MyKey()) end

-------------------------------------------------------------------------------
-- Permission
-------------------------------------------------------------------------------
local function allowed(def, author, id, newData, oldData)
    if type(author) ~= "string" then return false end
    if def.owner == "player" then
        return author == id
    end
    if def.canWrite then
        local ok, r = pcall(def.canWrite, author, id, newData, oldData)
        return ok and r and true or false
    end
    return true
end

function Store:CanWrite(name, id, newData)
    local def = self.defs[name]
    if not def then return false end
    local old = self:Get(name, id)
    return allowed(def, API.MyKey(), id, newData, old)
end

-------------------------------------------------------------------------------
-- Applying records
-------------------------------------------------------------------------------
local function newer(a, b) -- is record a newer than b?
    if not b then return true end
    if a.r ~= b.r then return a.r > b.r end
    return tostring(a.a) > tostring(b.a)
end

local function changed(def, id, rec, remote)
    digestCache[def.name] = nil
    if def.onChange then GF:Safe("store:" .. def.name, def.onChange, id, (not rec.x) and rec.d or nil, rec, remote) end
    GF:Fire("GF_STORE_CHANGED", def.name, id, (not rec.x) and rec.d or nil, rec, remote)
end

--- Apply a remote record. Returns true when it was accepted.
local function applyRemote(def, id, rec)
    if id == nil or type(rec) ~= "table" or type(rec.r) ~= "number" then return false end
    local t = data(def.name)
    local cur = t[id]
    if not newer(rec, cur) then return false end
    local oldData = cur and not cur.x and cur.d or nil
    if not allowed(def, rec.a, id, rec.d, oldData) then return false end
    if def.validate and not rec.x then
        local ok, valid = pcall(def.validate, id, rec.d)
        if not ok or not valid then return false end
    end
    t[id] = rec
    changed(def, id, rec, true)
    return true
end

local function nextRev(cur)
    local now = API.ServerTime()
    return max(now, (cur and cur.r or 0) + 1)
end

local function markDirty(def, id)
    dirty[def.name] = dirty[def.name] or {}
    dirty[def.name][id] = true
    if def.lazy then return end
    GF:Debounce("store-flush:" .. def.name, 1.5, function() Store:Flush(def.name) end)
end

--- Put(name, id, data) -> ok, err. Local write: bumps rev and broadcasts.
function Store:Put(name, id, newData)
    local def = self.defs[name]
    if not def then return false, "unknown dataset " .. tostring(name) end
    if id == nil then return false, "nil id" end
    local me = API.MyKey()
    if not me then return false, "no identity yet" end
    local t = data(name)
    local cur = t[id]
    local oldData = cur and not cur.x and cur.d or nil
    if not allowed(def, me, id, newData, oldData) then return false, "not allowed" end
    local rec = { r = nextRev(cur), a = me, t = API.ServerTime(), d = newData }
    t[id] = rec
    changed(def, id, rec, false)
    markDirty(def, id)
    return true
end

function Store:PutMine(name, newData) return self:Put(name, API.MyKey(), newData) end

function Store:Delete(name, id)
    local def = self.defs[name]
    if not def then return false end
    local me = API.MyKey()
    local t = data(name)
    local cur = t[id]
    if not cur or cur.x then return false end
    if not allowed(def, me, id, nil, cur.d) then return false, "not allowed" end
    local rec = { r = nextRev(cur), a = me, t = API.ServerTime(), x = true }
    t[id] = rec
    changed(def, id, rec, false)
    markDirty(def, id)
    return true
end

-------------------------------------------------------------------------------
-- Wire format helpers
-------------------------------------------------------------------------------
local function packRec(id, rec)
    return { id, rec.r, rec.a, rec.t, rec.d, rec.x and 1 or nil }
end

local function unpackRec(e)
    if type(e) ~= "table" then return nil end
    local id, r, a, t, d, x = e[1], e[2], e[3], e[4], e[5], e[6]
    if id == nil or type(r) ~= "number" or type(a) ~= "string" then return nil end
    return id, { r = r, a = a, t = t or 0, d = (not x) and d or nil, x = x and true or nil }
end

--- Broadcast pending local changes for a dataset (or all).
function Store:Flush(name)
    local names = {}
    if name then names[1] = name else for n in pairs(dirty) do names[#names + 1] = n end end
    for _, n in ipairs(names) do
        local ids = dirty[n]
        local def = self.defs[n]
        if ids and def then
            dirty[n] = nil
            local list = {}
            for id in pairs(ids) do
                local rec = data(n)[id]
                if rec then list[#list + 1] = packRec(id, rec) end
            end
            if #list > 0 then
                -- batches of 20 keep any single message reasonably sized
                local per = def.batch or 20
                for i = 1, #list, per do
                    local batch = {}
                    for j = i, math.min(#list, i + per - 1) do batch[#batch + 1] = list[j] end
                    Comm:Guild("SU", { c = def.code, l = batch }, "NORMAL")
                    if def.mirrorGroup and API.GroupChannel() then
                        Comm:Group("SU", { c = def.code, l = batch }, "NORMAL")
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Digests
-------------------------------------------------------------------------------
function Store:Digest(name)
    local d = digestCache[name]
    if d then return d end
    local ids, maxRev, count = {}, 0, 0
    for id, rec in pairs(data(name)) do
        ids[#ids + 1] = tostring(id) .. ":" .. rec.r .. (rec.x and "x" or "")
        if rec.r > maxRev then maxRev = rec.r end
        count = count + 1
    end
    table.sort(ids)
    d = { Ser.Hash(table.concat(ids, ",")), count, maxRev }
    digestCache[name] = d
    return d
end

local function myDigests()
    local h = {}
    for name, def in pairs(Store.defs) do
        if not def.localOnly then h[def.code] = Store:Digest(name) end
    end
    return h
end

function Store:SyncNow()
    Comm:Guild("SD", { h = myDigests() }, "BULK")
end

-------------------------------------------------------------------------------
-- Handlers
-------------------------------------------------------------------------------
-- Only guildies (or people in our group) may feed us data, once the roster is known.
local function trusted(sender)
    local R = GF.Roster
    if R and R.Count and R:Count() > 0 then
        return R:IsMember(sender) or R:InGroup(sender)
    end
    return true
end

Comm:Register("SU", function(p, sender)
    if not trusted(sender) then return end
    if type(p) ~= "table" or type(p.l) ~= "table" then return end
    local def = Store.byCode[p.c]
    if not def then return end
    local accepted = 0
    for _, e in ipairs(p.l) do
        local id, rec = unpackRec(e)
        if id ~= nil and applyRemote(def, id, rec) then accepted = accepted + 1 end
    end
    if accepted > 0 then GF:Debug("store %s: +%d from %s", def.name, accepted, sender) end
end)

Comm:Register("SD", function(p, sender, channel)
    if not trusted(sender) then return end
    if type(p) ~= "table" or type(p.h) ~= "table" then return end
    local want = {}
    local theyAreBehind = false
    local now = API.Time()
    for code, theirs in pairs(p.h) do
        local def = Store.byCode[code]
        if def and type(theirs) == "table" then
            local mine = Store:Digest(def.name)
            if mine[1] ~= theirs[1] then
                local tc, tr = tonumber(theirs[2]) or 0, tonumber(theirs[3]) or 0
                local theyHaveMore = tr > mine[3] or tc > mine[2]
                local tie = tr == mine[3] and tc == mine[2]
                if theyHaveMore or (tie and tostring(API.MyKey()) < tostring(sender)) then
                    if not lastSync[code] or now - lastSync[code] > SYNC_COOLDOWN then
                        lastSync[code] = now
                        want[#want + 1] = code
                    end
                else
                    theyAreBehind = true
                end
            end
        end
    end
    if #want > 0 then
        GF:After(0.5 + math.random() * 3, function() Comm:Whisper(sender, "SQ", { c = want }, "BULK") end)
    end
    -- A broadcast digest from someone who is behind: a few of us answer with our own
    -- digest so they can pull from us. Probability keeps the guild from dog-piling.
    if theyAreBehind and channel == "GUILD" then
        local p2 = 3 / math.max(3, Comm:OnlinePeers())
        if math.random() < p2 then
            GF:After(2 + math.random() * 10, function()
                Comm:Whisper(sender, "SD", { h = myDigests() }, "BULK")
            end)
        end
    end
end)

Comm:Register("SQ", function(p, sender)
    if not trusted(sender) then return end
    if type(p) ~= "table" or type(p.c) ~= "table" then return end
    for _, code in ipairs(p.c) do
        local def = Store.byCode[code]
        if def then
            local idx = {}
            for id, rec in pairs(data(def.name)) do idx[id] = rec.r end
            Comm:Whisper(sender, "SX", { c = code, x = idx }, "BULK")
        end
    end
end)

Comm:Register("SX", function(p, sender)
    if not trusted(sender) then return end
    if type(p) ~= "table" or type(p.x) ~= "table" then return end
    local def = Store.byCode[p.c]
    if not def then return end
    local mine = data(def.name)
    local want, push = {}, {}
    for id, rev in pairs(p.x) do
        local cur = mine[id]
        if type(rev) == "number" and (not cur or rev > cur.r) then want[#want + 1] = id end
    end
    for id, rec in pairs(mine) do
        local theirs = p.x[id]
        if theirs == nil or rec.r > theirs then push[#push + 1] = packRec(id, rec) end
    end
    for i = 1, #want, 40 do
        local ids = {}
        for j = i, math.min(#want, i + 39) do ids[#ids + 1] = want[j] end
        Comm:Whisper(sender, "SG", { c = p.c, i = ids }, "BULK")
    end
    local per = def.batch or 20
    for i = 1, #push, per do
        local batch = {}
        for j = i, math.min(#push, i + per - 1) do batch[#batch + 1] = push[j] end
        Comm:Whisper(sender, "SU", { c = p.c, l = batch }, "BULK")
    end
end)

Comm:Register("SG", function(p, sender)
    if not trusted(sender) then return end
    if type(p) ~= "table" or type(p.i) ~= "table" then return end
    local def = Store.byCode[p.c]
    if not def then return end
    local mine = data(def.name)
    local list = {}
    for _, id in ipairs(p.i) do
        local rec = mine[id]
        if rec then list[#list + 1] = packRec(id, rec) end
    end
    local per = def.batch or 20
    for i = 1, #list, per do
        local batch = {}
        for j = i, math.min(#list, i + per - 1) do batch[#batch + 1] = list[j] end
        Comm:Whisper(sender, "SU", { c = p.c, l = batch }, "BULK")
    end
end)

-------------------------------------------------------------------------------
-- Housekeeping: prune old tombstones and stale docs
-------------------------------------------------------------------------------
function Store:Prune()
    local now = API.ServerTime()
    for name, def in pairs(self.defs) do
        local t = data(name)
        for id, rec in pairs(t) do
            local age = now - (rec.t or 0)
            if rec.x and age > 30 * 86400 then
                t[id] = nil
            elseif def.keepDays and age > def.keepDays * 86400 then
                local ok, keepIt = true, false
                if def.keep then ok, keepIt = pcall(def.keep, id, rec) end
                if not (ok and keepIt) then t[id] = nil end
            end
        end
        digestCache[name] = nil
        GF:Fire("GF_STORE_PRUNED", name)
    end
end

GF:On("GF_GUILD_CHANGED", function()
    for k in pairs(digestCache) do digestCache[k] = nil end
end)

GF:On("GF_LOGIN", function()
    GF:After(20 + math.random() * 20, function()
        Store:Prune()
        Store:SyncNow()
    end)
    GF:Ticker(900 + math.random() * 120, function() Store:SyncNow() end)
    -- lazy datasets flush on their own cadence
    GF:Ticker(60, function()
        local now = API.Time()
        for name, def in pairs(Store.defs) do
            if def.lazy and dirty[name] then
                def._lastFlush = def._lastFlush or 0
                if now - def._lastFlush >= def.lazy then
                    def._lastFlush = now
                    Store:Flush(name)
                end
            end
        end
    end)
end)

GF:RegisterSlash("sync", function()
    Store:Flush()
    Store:SyncNow()
    GF:Print("Syncing with the neighbourhood...")
end, "force a data sync with guildies")
