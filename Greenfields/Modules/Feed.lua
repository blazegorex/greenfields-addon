--[[ Greenfields - Modules/Feed.lua
     The Neighbourhood Watch: the guild's shared activity feed, and its page.

     Every client keeps a ring buffer of the last 300 reports in GF.gdb.feed (per guild,
     oldest first). Feed:Post() appends a report locally and broadcasts op "FD"
       { k = kind, x = text, i = icon, y = dedupeKey, t = serverTime, o = 1 when it asks to toast }
     to the guild. Receivers check everything before it touches the buffer: kind whitelist,
     text capped at 240 bytes with only colour codes and item/spell links surviving (no
     textures, no newlines), a key seen in the last 6 hours is dropped, and so is the same
     text from the same sender inside 2 minutes. The feed is ephemeral: nothing is replayed
     to people who were offline, so the buffer is "what this client saw".

     Auto posts made here (only the client that should speak does, always with a key):
       levels 10/20/30/40/50/60   the player who dinged
       own epic loot              the looter (readable CHAT_MSG_LOOT self lines, plus the
                                  encounter loot event when chat goes secret in raids)
       raid boss kills            the raid leader, or the alphabetically-first officer in the
                                  group running Greenfields when the leader isn't
       members joining/leaving    the alphabetically-first online officer running it
     Funny deaths, titles and badges come from Stats, loot awards from Loot, raid posts from
     Raids/Attendance and 300-skill tradies from Professions.

     Public API (CORE_API section 5): Feed:Post(kind, text, opts), Feed:Recent(n).
     Extras for Modules/Home.lua: Feed.KINDS (kind metadata), Feed:Unread().
     Fires GF_FEED whenever the buffer changes. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c

local Feed = GF:NewModule("Feed")
GF.Feed = Feed

local type, pairs, ipairs, tostring, tonumber, pcall = type, pairs, ipairs, tostring, tonumber, pcall
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local format, sub, find, match, gsub, byte, upper = string.format, string.sub, string.find, string.match, string.gsub, string.byte, string.upper
local tremove, concat, sort = table.remove, table.concat, table.sort
local CleanString, CleanNumber = API.CleanString, API.CleanNumber

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local CAP = 300                 -- reports kept per guild
local MAX_TEXT = 240            -- bytes of text per report
local MAX_WIRE = 1024           -- anything longer on the wire isn't worth parsing
local MAX_KEY = 96
local KEY_TTL = 6 * 3600        -- a dedupe key is remembered this long
local TEXT_TTL = 120            -- same text from the same sender inside this is an echo
local CLOCK_SLACK = 600         -- a sender's timestamp is trusted within this of ours
local TOAST_MAX, TOAST_WINDOW = 5, 60
local SENDER_MAX, SENDER_WINDOW = 20, 60
local MOVE_SETTLE, MOVE_BULK = 6, 5   -- joins/leaves: wait for quiet; more at once is a roster swap
local KILL_DELAY = 3            -- let the encounter lockdown lift before reading the group
local LOOT_TRIES, LOOT_DEDUPE = 5, 5

--- Kind metadata. `toast` kinds pop a sign for receivers; `warn` kinds use the yellow one.
local KINDS = {
    level = { label = "Level up", icon = "star_fill", color = "gold", toast = true, headline = "Ding on the street" },
    loot = { label = "Loot", icon = "bag", color = "purple" },
    kill = { label = "Boss down", icon = "trophy", color = "green", toast = true, headline = "Boss down" },
    wipe = { label = "Wipe", icon = "skull", color = "yellow", warn = true, headline = "Wipe report" },
    title = { label = "New crown", icon = "crown", color = "gold", toast = true, headline = "New crown in town" },
    badge = { label = "Badge", icon = "star", color = "gold", toast = true, headline = "Badge earned" },
    join = { label = "New local", icon = "home", color = "green", toast = true, headline = "New neighbour" },
    leave = { label = "Moved out", icon = "export", color = "dim", headline = "Moving truck spotted" },
    death = { label = "Lie-down", icon = "skull", color = "red", warn = true, headline = "Man down" },
    camp = { label = "Camp", icon = "campfire", color = "yellow" },
    sr = { label = "Soft res", icon = "dice", color = "blue" },
    raid = { label = "Raid", icon = "calendar", color = "blue" },
    prof = { label = "Tradie", icon = "hammer", color = "blue", toast = true, headline = "Fully licensed" },
    misc = { label = "Street talk", icon = "bubble", color = "dim" },
}
Feed.KINDS = KINDS

local MEDIA_ICONS = {}
for name in ("roster calendar dice check clipboard trophy hammer flame campfire eye gear close search "
    .. "chevron_down chevron_right chevron_left plus minus star star_fill crown skull coin sync bubble bell "
    .. "warning shield cross sword bow home filter trash megaphone clock lock export import heart bolt dot "
    .. "ring bag pin"):gmatch("%S+") do
    MEDIA_ICONS[name] = true
end

local LINK_TYPES = { item = true, spell = true, enchant = true, quest = true }

local LEVEL_LINES = {
    [10] = {
        "{name} hit 10. Training wheels off. Mostly.",
        "{name} made level 10. Mum's stuck it on the fridge.",
        "{name} hit 10 and already reckons they own the street.",
    },
    [20] = {
        "{name} hit 20. P-plates on, God help the Kwinana Freeway.",
        "{name} made 20. Old enough to know better, young enough to pull anyway.",
        "{name} hit 20. Still walking everywhere like a legend.",
    },
    [30] = {
        "{name} hit 30. Halfway to a real job.",
        "{name} made 30. Too old for the skate park, too young for lawn bowls.",
        "{name} hit 30. The bin chickens have started showing some respect.",
    },
    [40] = {
        "{name} hit 40. Mount money sorted? Yeah nah, didn't think so.",
        "{name} made 40 and finally has wheels. Like a ute, but with more fur.",
        "{name} hit 40. Midlife-crisis mount incoming.",
    },
    [50] = {
        "{name} hit 50. Close enough to smell the raid loot from here.",
        "{name} made 50. Ten to go. Don't stuff it up now.",
        "{name} hit 50. The servo staff know them by name.",
    },
    [60] = {
        "{name} hit 60. Time to get a real job: raiding.",
        "{name} hit 60. Welcome to the endgame. Bring your own floor mat.",
        "{name} dinged 60. Someone fire up the Bunnings snags.",
    },
}

local EPIC_LINE = "{name} looted {item}. Absolute bin chicken behaviour."
local LEGENDARY_LINE = "{name} looted {item}. LEGENDARY. Somebody ring the Mandurah Mail."
local JOIN_LINE = "Welcome to the street, {name}. Lock ya bikes."
local LEAVE_LINE = "{name} moved out of Greenfields. Probably to Halls Head."

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------
local function fill(line, vars)
    local F = GF.Flavor
    if F and F.Fill then return F.Fill(line, vars) end
    return line
end

--- Capitalises the first letter, so "{boss}" filled with "the boss" still reads as a sentence.
local function sentence(s)
    if type(s) ~= "string" then return "" end
    return (gsub(s, "^%l", upper))
end

local function colored(key)
    local R = GF.Roster
    if R and R.Colored then
        local ok, s = pcall(R.Colored, R, key)
        if ok and type(s) == "string" then return s end
    end
    return U.ShortName(key)
end

local function myColored()
    local key = API.MyKey()
    if not key then return nil end
    return U.ClassName(key, API.UnitClassFile("player"))
end

local function isOfficer(key)
    local R = GF.Roster
    if type(key) ~= "string" or not (R and R.IsOfficer) then return false end
    local ok, r = pcall(R.IsOfficer, R, key)
    return ok and r and true or false
end

--- Has this player's client actually said hello this session?
local function seenThisSession(key)
    local Comm = GF.Comm
    local peer = Comm and type(Comm.peers) == "table" and Comm.peers[key]
    return type(peer) == "table" and peer.version ~= nil
end

--- Is Greenfields running for this player right now (me, a hello this session, or any
-- addon message in the last hour)? Stricter than Comm:HasAddon: someone remembered from
-- last week but not running it today must not be picked as the only announcer.
local function runningNow(key)
    if type(key) ~= "string" then return false end
    if key == API.MyKey() or seenThisSession(key) then return true end
    local Comm = GF.Comm
    local peer = Comm and type(Comm.peers) == "table" and Comm.peers[key]
    return type(peer) == "table" and type(peer.seen) == "number" and API.ServerTime() - peer.seen < 3600
end

--- ENCOUNTER_END's success flag: 1/0 on retail, maybe a boolean here. -> 1, 0 or nil.
local function successFlag(v)
    v = API.Clean(v)
    if v == true then return 1 end
    if v == false then return 0 end
    if v == 1 or v == 0 then return v end
    return nil
end

-------------------------------------------------------------------------------
-- Storage: GF.gdb.feed (array, oldest first) + GF.DB:Local("Feed") bookkeeping
-------------------------------------------------------------------------------
local function feedList()
    local g = GF.gdb
    if type(g) ~= "table" then return nil end
    if type(g.feed) ~= "table" then g.feed = {} end
    return g.feed
end

--- { keys = {[key] = seenAt}, seq = last sequence number, seen = last seq viewed }
local function localState()
    if not (GF.gdb and GF.DB and GF.DB.Local) then return nil end
    local l = GF.DB:Local("Feed")
    if type(l.keys) ~= "table" then l.keys = {} end
    l.seq = tonumber(l.seq) or 0
    l.seen = tonumber(l.seen) or 0
    return l
end

local function valid(e)
    return type(e) == "table" and type(e.text) == "string" and type(e.t) == "number" and KINDS[e.kind] ~= nil
end

--- SavedVariables may hand back holes or junk; rebuild a clean, capped, numbered list.
local function normalize()
    local list, l = feedList(), localState()
    if not list or not l then return end
    local idx = {}
    for i, e in pairs(list) do
        if type(i) == "number" and valid(e) then idx[#idx + 1] = i end
    end
    sort(idx)
    local fresh = {}
    for j = max(1, #idx - CAP + 1), #idx do fresh[#fresh + 1] = list[idx[j]] end
    for _, e in ipairs(fresh) do
        if type(e.n) ~= "number" then
            l.seq = l.seq + 1
            e.n = l.seq
        elseif e.n > l.seq then
            l.seq = e.n
        end
    end
    GF.gdb.feed = fresh
end

-------------------------------------------------------------------------------
-- Validation. Everything here runs on our own posts and on every received one.
-------------------------------------------------------------------------------
--- UTF-8 safe byte cut: never splits a multi-byte character.
local function cut(s, n)
    if #s <= n then return s end
    local i = n
    while i > 0 do
        local b = byte(s, i + 1)
        if not b or b < 128 or b >= 192 then break end
        i = i - 1
    end
    return sub(s, 1, i)
end

--- Text with every escape removed (also the "|cnIQ4:" named colours that modern item
-- links use, which U.StripCodes predates).
local function plain(s)
    return U.StripCodes((gsub(tostring(s or ""), "|cn[%w_]+:", "")))
end

--- Keeps only escapes that are safe to render: |cAARRGGBB, |cnNAME:, |r, ||, and item,
-- spell, enchant and quest links. Textures, atlases, protected strings and |n newlines
-- go; any other stray pipe is dropped.
local function scrub(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local p = find(s, "|", i, true)
        if not p then
            out[#out + 1] = sub(s, i)
            break
        end
        if p > i then out[#out + 1] = sub(s, i, p - 1) end
        local c = sub(s, p + 1, p + 1)
        local named = c == "c" and match(s, "^|cn[%w_]+:", p)
        if c == "|" then
            out[#out + 1] = "||"
            i = p + 2
        elseif c == "c" and find(s, "^%x%x%x%x%x%x%x%x", p + 2) then
            out[#out + 1] = sub(s, p, p + 9)
            i = p + 10
        elseif named then
            out[#out + 1] = named
            i = p + #named
        elseif c == "r" then
            out[#out + 1] = "|r"
            i = p + 2
        elseif c == "H" then
            local data, label, after = match(s, "^|H([^|]*)|h([^|]*)|h()", p)
            if data then
                local kind = match(data, "^(%a+):")
                if kind and LINK_TYPES[kind] then
                    out[#out + 1] = "|H" .. data .. "|h" .. label .. "|h"
                else
                    out[#out + 1] = label
                end
                i = after
            else
                i = p + 2
            end
        elseif c == "T" or c == "A" or c == "K" then
            local close = find(s, "|" .. c:lower(), p + 2, true)
            i = close and close + 2 or n + 1
        elseif c == "n" then
            out[#out + 1] = " "
            i = p + 2
        else
            i = p + 1
        end
    end
    return concat(out)
end

--- sanitize(text) -> safe display text (<= 240 bytes) or nil.
local function sanitize(text)
    text = CleanString(text)
    if not text or #text > MAX_WIRE then return nil end
    text = gsub(text, "%c", " ")
    text = scrub(text)
    text = gsub(text, "%s%s+", " ")
    text = U.Trim(text)
    if text == "" then return nil end
    if #text > MAX_TEXT then
        -- too long to cut safely around links and colours: fall back to plain words
        text = cut(plain(text), MAX_TEXT - 3)
        local pipes = match(text, "(|*)$")
        if #pipes % 2 == 1 then text = sub(text, 1, -2) end
        text = U.Trim(text) .. "..."
    end
    return text
end

local function cleanKey(k)
    k = CleanString(k)
    if not k or k == "" or #k > MAX_KEY or find(k, "%c") then return nil end
    return k
end

local function cleanIcon(icon)
    if type(icon) == "number" then
        icon = CleanNumber(icon)
        if icon and icon > 0 and icon == floor(icon) then return icon end
        return nil
    end
    icon = CleanString(icon)
    if not icon then return nil end
    if MEDIA_ICONS[icon] then return icon end
    if match(icon, "^[Ii]nterface[\\/][Ii][Cc][Oo][Nn][Ss][\\/][%w_%-]+$") then return icon end
    return nil
end

-------------------------------------------------------------------------------
-- Dedupe
-------------------------------------------------------------------------------
local function keySeen(key, now)
    local l = localState()
    if not l or not key then return false end
    local t = l.keys[key]
    return type(t) == "number" and abs(now - t) < KEY_TTL
end

local function markKey(key, now)
    local l = localState()
    if not l or not key then return end
    l.keys[key] = now
    if now - (tonumber(l.pruned) or 0) < 600 then return end
    l.pruned = now
    for k, t in pairs(l.keys) do
        if type(t) ~= "number" or now - t > KEY_TTL then l.keys[k] = nil end
    end
end

local function dupText(from, text, now)
    local list = feedList()
    if not list then return false end
    for i = #list, max(1, #list - 40), -1 do
        local e = list[i]
        if type(e) == "table" and e.from == from and e.text == text and abs(now - (tonumber(e.t) or 0)) <= TEXT_TTL then
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Toasts
-------------------------------------------------------------------------------
local toastTimes = {}

local function toastBudget()
    local now = API.Time()
    local keep = {}
    for _, t in ipairs(toastTimes) do
        if now - t < TOAST_WINDOW then keep[#keep + 1] = t end
    end
    toastTimes = keep
    if #keep >= TOAST_MAX then return false end
    keep[#keep + 1] = now
    return true
end

--- Pops a road sign for a report. `flagged` = the poster asked for one.
local function toast(e, flagged)
    if not (UI and UI.Toast) then return end
    local s = GF.db and GF.db.settings
    if not s or s.feedToasts == false then return end
    local meta = KINDS[e.kind] or KINDS.misc
    if not (meta.toast or flagged) then return end
    -- the report still lands in the feed; nobody needs a sign mid-pull
    if API.InCombat() or not toastBudget() then return end
    local text = e.text
    -- class colours are unreadable on the yellow sign: plain text there
    if meta.warn then text = plain(text) end
    UI:Toast({
        title = meta.headline or "Neighbourhood Watch",
        text = text,
        icon = e.icon or meta.icon,
        style = meta.warn and "yellow" or "green",
        key = "feed:" .. (e.key or ((e.from or "?") .. ":" .. e.text)),
        onClick = function() if UI.OpenMain then UI:OpenMain("feed") end end,
    })
end

-------------------------------------------------------------------------------
-- Core
-------------------------------------------------------------------------------
local function append(e, now)
    local list, l = feedList(), localState()
    if not list or not l then return nil end
    l.seq = l.seq + 1
    e.n = l.seq
    list[#list + 1] = e
    while #list > CAP do tremove(list, 1) end
    if e.key then markKey(e.key, now) end
    GF:Fire("GF_FEED")
    return e
end

local function post(kind, text, opts)
    if type(opts) ~= "table" then opts = {} end
    kind = CleanString(kind)
    if not kind or not KINDS[kind] then kind = "misc" end
    text = sanitize(text)
    if not text then return false end
    local now = API.ServerTime()
    local key = cleanKey(opts.key)
    if key and keySeen(key, now) then return false end
    local me = API.MyKey()
    if dupText(me, text, now) then return false end
    local e = append({ kind = kind, text = text, t = now, from = me, icon = cleanIcon(opts.icon), key = key }, now)
    if not e then return false end
    if opts.localOnly then
        if opts.toast then toast(e, true) end
    elseif GF.Comm and GF.Comm.Guild then
        GF.Comm:Guild("FD", { k = kind, x = text, i = e.icon, y = key, t = now, o = opts.toast and 1 or nil }, "NORMAL")
    end
    return true
end

--- Post(kind, text, opts) -> true when the report was recorded.
-- opts: { icon, toast = bool, localOnly = bool, key = dedupeKey }
function Feed:Post(kind, text, opts)
    local ok, res = GF:Safe("feed:post", post, kind, text, opts)
    return ok and res and true or false
end

--- Recent(n) -> newest first: { kind, text, t, from, icon }
function Feed:Recent(n)
    local out = {}
    local list = feedList()
    if not list then return out end
    n = min(CAP, max(0, floor(tonumber(n) or 20)))
    for i = #list, 1, -1 do
        if #out >= n then break end
        local e = list[i]
        if valid(e) then
            out[#out + 1] = { kind = e.kind, text = e.text, t = e.t, from = e.from, icon = e.icon }
        end
    end
    return out
end

--- Reports from other people since the page was last opened.
function Feed:Unread()
    local l, list = localState(), feedList()
    if not l or not list then return 0 end
    local me, n = API.MyKey(), 0
    for i = #list, 1, -1 do
        local e = list[i]
        if type(e) ~= "table" or (tonumber(e.n) or 0) <= l.seen then break end
        if e.from ~= me then n = n + 1 end
    end
    return n
end

local function markSeen()
    local l = localState()
    if l then l.seen = l.seq end
end

-------------------------------------------------------------------------------
-- Receiving "FD"
-------------------------------------------------------------------------------
local senderLog = {}

local function senderBudget(sender)
    local now = API.Time()
    local log = senderLog[sender]
    if not log or now - log.start > SENDER_WINDOW then
        log = { start = now, n = 0 }
        senderLog[sender] = log
    end
    log.n = log.n + 1
    return log.n <= SENDER_MAX
end

local function trusted(sender)
    local R = GF.Roster
    if not (R and R.Count and R.IsMember) then return true end
    if R:Count() == 0 then return true end
    return R:IsMember(sender)
end

local function onRemote(p, sender, channel)
    if channel ~= "GUILD" or type(p) ~= "table" or type(sender) ~= "string" then return end
    if not trusted(sender) or not senderBudget(sender) then return end
    local kind = type(p.k) == "string" and KINDS[p.k] and p.k
    if not kind or type(p.x) ~= "string" then return end
    local text = sanitize(p.x)
    if not text then return end
    local now = API.ServerTime()
    local key = cleanKey(p.y)
    if key and keySeen(key, now) then return end
    if dupText(sender, text, now) then return end
    local t = tonumber(p.t)
    if not t or abs(t - now) > CLOCK_SLACK then t = now end
    local e = append({ kind = kind, text = text, t = floor(t), from = sender, icon = cleanIcon(p.i), key = key }, now)
    if not e then return end
    -- raiders already got Fun's kill sign; everyone else hears it from the Watch
    if kind == "kill" and GF.Roster and GF.Roster.InGroup and GF.Roster:InGroup(sender) then return end
    toast(e, p.o == 1)
end

GF.Comm:Register("FD", onRemote)

-------------------------------------------------------------------------------
-- Auto posts: levels
-------------------------------------------------------------------------------
local function onLevelUp(_, level)
    level = CleanNumber(level)
    local lines = level and LEVEL_LINES[level]
    local name, key = myColored(), API.MyKey()
    if not lines or not name then return end
    Feed:Post("level", fill(U.Pick(lines), { name = name }), { key = "level:" .. key .. ":" .. level, icon = "star_fill" })
end

-------------------------------------------------------------------------------
-- Auto posts: my own epics
-------------------------------------------------------------------------------
local lootPatterns
local lootSeen = {}

--- "You receive loot: %s." -> anchored Lua pattern; returns pattern and which capture
-- holds format argument 1 (the item link). Handles %s, %d and %1$s style arguments.
local function toPattern(fmt)
    if type(fmt) ~= "string" or fmt == "" or not API.Readable(fmt) then return nil end
    local out, order, pos, seq = {}, {}, 1, 0
    while pos <= #fmt do
        local c = sub(fmt, pos, pos)
        if c == "%" then
            local num, conv, nxt = match(fmt, "^%%(%d)%$([sd])()", pos)
            if not num then
                conv, nxt = match(fmt, "^%%([sd])()", pos)
                if conv then
                    seq = seq + 1
                    num = seq
                end
            end
            if conv then
                order[#order + 1] = tonumber(num)
                out[#out + 1] = conv == "d" and "(%d+)" or "(.+)"
                pos = nxt
            else
                out[#out + 1] = "%%"
                pos = pos + (sub(fmt, pos + 1, pos + 1) == "%" and 2 or 1)
            end
        elseif find(c, "[%^%$%(%)%.%[%]%*%+%-%?]") then
            out[#out + 1] = "%" .. c
            pos = pos + 1
        else
            out[#out + 1] = c
            pos = pos + 1
        end
    end
    for i, argPos in ipairs(order) do
        if argPos == 1 then return { pat = "^" .. concat(out) .. "$", cap = i } end
    end
    return nil
end

local function buildLootPatterns()
    lootPatterns = {}
    -- the multiple-count form first, or "x2" would be swallowed into the link
    for _, name in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF" }) do
        local p = toPattern(rawget(_G, name))
        if p then lootPatterns[#lootPatterns + 1] = p end
    end
    if #lootPatterns == 0 then
        lootPatterns[1] = { pat = "^You receive loot: (.+)x(%d+)%.$", cap = 1 }
        lootPatterns[2] = { pat = "^You receive loot: (.+)%.$", cap = 1 }
    end
end

--- One post per item id per few seconds, whichever loot source saw it first.
local function lootDupe(id)
    local now = API.Time()
    local last = lootSeen[id]
    if last and now - last < LOOT_DEDUPE then return true end
    lootSeen[id] = now
    return false
end

local function postEpic(link, id, tries)
    local q = CleanNumber(API.ItemQuality(link))
    if not q then
        -- uncached: ask the server and look again shortly
        tries = (tries or 0) + 1
        if tries <= LOOT_TRIES then
            API.RequestItem(id)
            GF:After(1.5 * tries, function() postEpic(link, id, tries) end)
        end
        return
    end
    if q < 4 then return end
    local name, key = myColored(), API.MyKey()
    if not name then return end
    Feed:Post("loot", fill(q == 5 and LEGENDARY_LINE or EPIC_LINE, { name = name, item = link }), {
        key = format("epic:%s:%d:%d", key, id, floor(API.ServerTime() / 60)), icon = "bag",
    })
end

local function isItemLink(link)
    return type(link) == "string" and find(link, "|Hitem:", 1, true) ~= nil
end

local function onChatLoot(_, text)
    text = CleanString(text)
    if not text then return end
    if not lootPatterns then buildLootPatterns() end
    for _, p in ipairs(lootPatterns) do
        local caps = { match(text, p.pat) }
        if caps[1] then
            local link = caps[p.cap]
            local id = API.ItemID(link)
            if id and isItemLink(link) and not lootDupe(id) then postEpic(link, id) end
            return
        end
    end
end

--- Fallback for raids, where loot chat can be secret: (encounterID, itemID, itemLink, quantity, playerName, className)
local function onEncounterLoot(_, _, itemID, itemLink, _, playerName)
    local who = API.Key(CleanString(playerName))
    if not who or who ~= API.MyKey() then return end
    local link = CleanString(itemLink)
    local id = CleanNumber(itemID) or API.ItemID(link)
    if not id or not isItemLink(link) or lootDupe(id) then return end
    postEpic(link, id)
end

-------------------------------------------------------------------------------
-- Auto posts: raid boss kills (one announcer per raid, CORE_API rule 14)
-------------------------------------------------------------------------------
local encounter

--- -> announcerKey, leaderKey. The leader if they're running Greenfields, otherwise the
-- alphabetically-first officer in the group who is. Clients that disagree (a hello lost
-- in the instance) both post, but with the same key, so receivers keep only one.
local function killAnnouncer(members)
    local leader
    for _, m in ipairs(members) do
        if m.rank == 2 and type(m.key) == "string" then
            leader = m.key
            break
        end
    end
    if leader and runningNow(leader) then return leader, leader end
    local best
    for _, m in ipairs(members) do
        local k = m.key
        if type(k) == "string" and m.online ~= false and isOfficer(k) and runningNow(k) then
            if not best or k < best then best = k end
        end
    end
    return best, leader
end

local function postKill(encounterID, boss)
    local me = API.MyKey()
    local F = GF.Flavor
    if not me or not (F and F.kills) then return end
    local speaker, leader = killAnnouncer(API.GroupMembers())
    if speaker ~= me then return end
    local tag = encounterID and tostring(encounterID) or (boss or "boss")
    Feed:Post("kill", sentence(fill(U.Pick(F.kills), { boss = boss or "the boss" })), {
        key = "kill:" .. tag .. ":" .. (leader or me) .. ":" .. U.WeekKey(), icon = "trophy", toast = true,
    })
end

local function onEncounterStart(_, encounterID, encounterName)
    encounter = { id = CleanNumber(encounterID), name = CleanString(encounterName) }
end

local function onEncounterEnd(_, encounterID, encounterName, _, _, success)
    local enc = encounter
    encounter = nil
    if successFlag(success) ~= 1 or not API.InRaidInstance() then return end
    local id = CleanNumber(encounterID) or (enc and enc.id)
    local boss = CleanString(encounterName) or (enc and enc.name)
    GF:After(KILL_DELAY, function() postKill(id, boss) end)
end

-------------------------------------------------------------------------------
-- Auto posts: people moving in and out (one officer speaks)
-------------------------------------------------------------------------------
local moves = {}

--- I'm an officer, and no online officer that sorts before me has said hello this session.
local function iAnnounceMoves()
    local me, R = API.MyKey(), GF.Roster
    if not (me and R and R.All) or not isOfficer(me) then return false end
    for key, m in pairs(R:All()) do
        if type(key) == "string" and key < me and type(m) == "table" and m.online
            and isOfficer(key) and seenThisSession(key) then
            return false
        end
    end
    return true
end

local function flushMoves()
    local list = moves
    moves = {}
    -- a whole roster appearing at once is a guild switch, not news
    if #list == 0 or #list > MOVE_BULK or not iAnnounceMoves() then return end
    for _, mv in ipairs(list) do
        local name = colored(mv.key)
        if mv.kind == "join" then
            Feed:Post("join", fill(JOIN_LINE, { name = name }), { key = "join:" .. mv.key, icon = "home" })
        else
            Feed:Post("leave", fill(LEAVE_LINE, { name = name }), { key = "leave:" .. mv.key, icon = "export" })
        end
    end
end

local function queueMove(kind, key)
    key = CleanString(key)
    if not key then return end
    moves[#moves + 1] = { kind = kind, key = key }
    GF:Debounce("feed-moves", MOVE_SETTLE, flushMoves)
end

-------------------------------------------------------------------------------
-- Page: Neighbourhood Watch
-------------------------------------------------------------------------------
local PAGE = "feed"
local ROW_H = 44
local BADGE = 30                -- framed kind icon on each report row
local SIGN_H = 76
local SIGN_CAP = 40             -- texture pixels kept unstretched at each end of the sign
local HAZARD_H = 6
local HAZARD_TILE = 32          -- on-screen size of one 64px hazard tile
local INK = { 0.07, 0.07, 0.05, 1 }     -- road-sign black

local FILTERS = {
    { key = "all", text = "All" },
    { key = "raids", text = "Raids", kinds = { kill = true, wipe = true, raid = true, sr = true, camp = true },
      empty = "No raid news. Either nobody's raiding or nobody's dying. Suspicious either way." },
    { key = "loot", text = "Loot", kinds = { loot = true },
      empty = "No loot yet. The bin chickens are circling." },
    { key = "titles", text = "Titles", kinds = { title = true, badge = true },
      empty = "No crowns have changed hands. The throne's gathering dust." },
    { key = "levels", text = "Levels", kinds = { level = true, prof = true },
      empty = "Nobody's dinged lately. Too busy fishing off the jetty." },
    { key = "locals", text = "Locals", kinds = { join = true, leave = true, death = true, misc = true },
      empty = "No comings or goings. The curtains haven't twitched all week." },
}
local FILTER_BY_KEY = {}
for _, f in ipairs(FILTERS) do FILTER_BY_KEY[f.key] = f end

--- Report kinds worth a light sweep when they're new to you.
local CELEBRATE = { kill = true, title = true, badge = true, level = true, prof = true, join = true }

local SIGN_LINES = {
    "Suspicious behaviour is reported straight to the guild.",
    "Every ding, drop and lie-down gets reported. Lock ya bikes.",
    "Monitored around the clock by the nosy neighbour at number 12.",
    "Curtains twitching 24/7. Smile, you're on the group chat.",
}

local pageDef

local function emptyLine(f)
    if f and f.empty then return f.empty end
    local F = GF.Flavor
    return (F and F.emptyStates and F.emptyStates.feed) or "Quiet on the street tonight. Too quiet."
end

--- Seconds since local midnight, so the plate can count "today" in the player's own day.
local function startOfToday(now)
    local d = rawget(_G, "date")
    if type(d) ~= "function" then return now - 86400 end
    local ok, t = pcall(d, "*t")
    if not ok or type(t) ~= "table" then return now - 86400 end
    return now - ((t.hour or 0) * 3600 + (t.min or 0) * 60 + (t.sec or 0))
end

---------------------------------------------------------------- the sign
local function inkText(parent, size, kind)
    local fs = UI:Text(parent, size, INK, kind)
    fs:SetShadowColor(0, 0, 0, 0)
    return fs
end

local function signPiece(parent, l, r)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture(T.tex.signYellow)
    t:SetTexCoord(l, r, 0, 1)
    return t
end

--- "NEIGHBOURHOOD WATCH AREA": the yellow sign three-sliced across the page so the
-- rounded ends keep their shape, an eye emblem, a black report plate, hazard tape under.
local function buildBanner(page, anchor)
    local b = CreateFrame("Frame", nil, page)
    -- TOPLEFT + TOPRIGHT (a bare RIGHT would pin the vertical centre to the page's and
    -- stretch the sign down half the window)
    b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
    b:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -10)
    b:SetHeight(SIGN_H + 6 + HAZARD_H)

    local edge = SIGN_CAP / 512
    local capW = floor(SIGN_CAP * SIGN_H / 128 + 0.5)
    local left = signPiece(b, 0, edge)
    left:SetSize(capW, SIGN_H)
    left:SetPoint("TOPLEFT")
    local right = signPiece(b, 1 - edge, 1)
    right:SetSize(capW, SIGN_H)
    right:SetPoint("TOPRIGHT")
    local mid = signPiece(b, edge, 1 - edge)
    mid:SetPoint("TOPLEFT", left, "TOPRIGHT")
    mid:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")

    local faceY = -(SIGN_H / 2) + 1     -- the sign's face sits a touch above its shadow
    for _, side in ipairs({ { "LEFT", 11 }, { "RIGHT", -11 } }) do
        local bolt = b:CreateTexture(nil, "ARTWORK", nil, 2)
        bolt:SetTexture(T.tex.circle)
        bolt:SetSize(5, 5)
        bolt:SetVertexColor(0.32, 0.27, 0.10, 0.9)
        bolt:SetPoint("CENTER", b, "TOP" .. side[1], side[2], faceY)
    end

    local emblem = b:CreateTexture(nil, "ARTWORK", nil, 2)
    emblem:SetTexture(T.tex.circle)
    emblem:SetSize(46, 46)
    emblem:SetVertexColor(INK[1], INK[2], INK[3], 1)
    emblem:SetPoint("CENTER", b, "TOPLEFT", 46, faceY)
    local eye = UI:Icon(b, 28, "eye", "OVERLAY", "yellow")
    eye:SetPoint("CENTER", emblem, "CENTER", 0, 0)

    local plate = CreateFrame("Frame", nil, b)
    plate:SetSize(112, 46)
    plate:SetPoint("RIGHT", b, "TOPRIGHT", -24, faceY)
    plate.bg = plate:CreateTexture(nil, "BACKGROUND")
    plate.bg:SetAllPoints()
    UI.Sliced(plate.bg, T.tex.round6, 6)
    plate.bg:SetVertexColor(INK[1], INK[2], INK[3], 1)
    plate.num = UI:Text(plate, 20, "yellow", "num")
    plate.num:SetPoint("TOP", 0, -5)
    plate.num:SetJustifyH("CENTER")
    plate.label = UI:Text(plate, 9, "yellow", "head")
    plate.label:SetPoint("BOTTOM", 0, 7)
    plate.label:SetJustifyH("CENTER")
    plate.label:SetText("REPORTS TODAY")
    plate:EnableMouse(true)
    plate:SetScript("OnEnter", function(self)
        UI:Tip(self, "Reports today", { "Everything this client has seen since midnight.",
            T:Wrap("dim", "The Watch keeps the last " .. CAP .. " reports.") })
    end)
    plate:SetScript("OnLeave", function() UI:HideTip() end)
    b.plate = plate

    -- emblem and plate share a centre line, so their tops line up for the title's corners
    b.title = inkText(b, 24, "head")
    b.title:SetPoint("TOPLEFT", emblem, "TOPRIGHT", 14, -2)
    b.title:SetPoint("TOPRIGHT", plate, "TOPLEFT", -12, -2)
    b.title:SetText("NEIGHBOURHOOD WATCH AREA")
    b.line = inkText(b, 11, "body")
    b.line:SetPoint("TOPLEFT", b.title, "BOTTOMLEFT", 0, -5)
    b.line:SetPoint("TOPRIGHT", b.title, "BOTTOMRIGHT", 0, -5)

    -- hazard tape: Blizzard's backdrop recipe (REPEAT wrap + tiling + explicit repeat count)
    local hz = b:CreateTexture(nil, "ARTWORK")
    hz:SetTexture(T.tex.hazard, "REPEAT", "REPEAT")
    if hz.SetHorizTile then hz:SetHorizTile(true) end
    hz:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 8, 0)
    hz:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -8, 0)
    hz:SetHeight(HAZARD_H)
    for _, point in ipairs({ "TOP", "BOTTOM" }) do
        local edgeLine = b:CreateTexture(nil, "OVERLAY")
        edgeLine:SetColorTexture(0, 0, 0, 0.55)
        edgeLine:SetHeight(1)
        edgeLine:SetPoint(point .. "LEFT", hz, point .. "LEFT")
        edgeLine:SetPoint(point .. "RIGHT", hz, point .. "RIGHT")
    end
    b:SetScript("OnSizeChanged", function(_, w)
        w = tonumber(w) or 0
        hz:SetTexCoord(0, max(1, (w - 16) / HAZARD_TILE), 0, HAZARD_H / HAZARD_TILE)
    end)
    hz:SetTexCoord(0, 20, 0, HAZARD_H / HAZARD_TILE)
    return b
end

---------------------------------------------------------------- filter chips
-- Gold-rimmed filter buttons from the kit's button art: dark when idle, green when picked.
local CHIP_IDLE_LABEL = { C.wowGold[1], C.wowGold[2], C.wowGold[3], 0.85 }
local CHIP_IDLE_COUNT = { 0.75, 0.66, 0.45, 1 }

local function paintChip(chip)
    local label, count
    if chip.selected then
        UI.Sliced(chip.bg, T.tex.btnGreen, 10)
        label, count = { 1, 1, 1, 1 }, { 0.85, 1, 0.9, 0.85 }
    else
        UI.Sliced(chip.bg, T.tex.btnDark, 10)
        if chip.hover then
            label, count = C.wowGold, { 0.95, 0.85, 0.6, 1 }
        else
            label, count = CHIP_IDLE_LABEL, CHIP_IDLE_COUNT
        end
    end
    chip.hl:SetAlpha(chip.hover and 1 or 0)
    chip.label:SetTextColor(label[1], label[2], label[3], label[4] or 1)
    chip.count:SetTextColor(count[1], count[2], count[3], count[4] or 1)
end

local function makeChip(parent, def, onPick)
    local chip = CreateFrame("Button", nil, parent)
    chip:SetHeight(22)
    chip.def = def
    chip.bg = chip:CreateTexture(nil, "BACKGROUND")
    chip.bg:SetAllPoints()
    UI.Sliced(chip.bg, T.tex.btnDark, 10)
    chip.hl = chip:CreateTexture(nil, "ARTWORK", nil, -1)
    chip.hl:SetPoint("TOPLEFT", 3, -3)
    chip.hl:SetPoint("BOTTOMRIGHT", -3, 3)
    chip.hl:SetColorTexture(1, 1, 1, 0.10)
    chip.hl:SetBlendMode("ADD")
    chip.hl:SetAlpha(0)
    chip.label = UI:Text(chip, 11, "wowGold", "ui")
    chip.label:SetPoint("LEFT", 10, 0)
    chip.label:SetText(def.text)
    chip.count = UI:Text(chip, 10, "faint", "num")
    chip.count:SetPoint("LEFT", chip.label, "RIGHT", 5, 0)
    function chip:SetCount(n)
        self.count:SetText(tostring(n or 0))
        self:SetWidth((self.label:GetStringWidth() or 30) + (self.count:GetStringWidth() or 8) + 25)
    end
    chip:SetScript("OnEnter", function(self)
        self.hover = true
        paintChip(self)
    end)
    chip:SetScript("OnLeave", function(self)
        self.hover = false
        paintChip(self)
    end)
    chip:SetScript("OnClick", function(self)
        if UI.Sound then UI.Sound(841) end
        onPick(self.def.key)
    end)
    chip:SetCount(0)
    paintChip(chip)
    return chip
end

local function layoutChips(page)
    local x = 0
    for _, chip in ipairs(page.chips) do
        chip:ClearAllPoints()
        chip:SetPoint("LEFT", page.chipBar, "LEFT", x, 0)
        x = x + chip:GetWidth() + 4
    end
    page.chipBar:SetWidth(max(1, x - 4))
end

---------------------------------------------------------------- report rows
local function whoText(from)
    if type(from) ~= "string" then return T:Wrap("faint", "Someone") end
    return colored(from)
end

local function createRow(row)
    -- the kind's icon in a gold action-button frame (game icons sit in it as they are)
    row.badge = UI:FramedIcon(row, BADGE, "dot")
    row.badge:SetPoint("LEFT", 10, 0)
    row.icon = row.badge.icon
    row.new = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.new:SetColorTexture(C.green[1], C.green[2], C.green[3], 1)
    row.new:SetPoint("TOPLEFT", 0, -6)
    row.new:SetPoint("BOTTOMLEFT", 0, 6)
    row.new:SetWidth(2)
    row.ago = UI:Text(row, 10, "faint", "num")
    row.ago:SetPoint("TOPRIGHT", -10, -8)
    row.ago:SetJustifyH("RIGHT")
    -- corner pairs only: TOPLEFT + RIGHT would pin each line's centre to the row's
    row.text = UI:Text(row, 12, "text")
    row.text:SetPoint("TOPLEFT", row.badge, "TOPRIGHT", 10, 1)
    row.text:SetPoint("TOPRIGHT", row.ago, "TOPLEFT", -12, 2)
    row.meta = UI:Text(row, 10, "faint", "head")
    row.meta:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 0, -5)
    row.meta:SetPoint("TOPRIGHT", row.text, "BOTTOMRIGHT", 0, -5)
    UI:EnableLinks(row)
    if row.GetScript and row:GetScript("OnHyperlinkClick") then
        row:HookScript("OnHyperlinkClick", function(self) self.linkAt = API.Time() end)
    end
end

local function updateRow(page, row, e)
    local meta = KINDS[e.kind] or KINDS.misc
    row.badge:SetIcon(e.icon or meta.icon)
    -- line icons take the kind's colour on the dark well; grey kinds keep the frame's gold
    if not row.icon.isGameIcon and meta.color ~= "dim" then
        local c = UI.col(meta.color)
        row.icon:SetVertexColor(c[1], c[2], c[3], 1)
    end
    row.text:SetText(e.text)
    row.meta:SetText(whoText(e.from) .. T:Wrap("faint", "   \194\183   ") .. T:Wrap("dim", upper(meta.label)))
    row.ago:SetText(U.Ago(e.t))
    local fresh = (tonumber(e.n) or 0) > (page.prevSeen or 0) and e.from ~= API.MyKey()
    row.new:SetShown(fresh)
    -- a fresh ding, crown or kill gets one achievement-style sweep, the first time it's drawn
    local n = tonumber(e.n)
    if fresh and n and CELEBRATE[e.kind] and not page.shone[n] then
        page.shone[n] = true
        UI:Shine(row, 0.9)
    end
end

local function rowTip(row, e)
    local meta = KINDS[e.kind] or KINDS.misc
    local lines = {}
    if row.text.IsTruncated and row.text:IsTruncated() then lines[#lines + 1] = e.text end
    lines[#lines + 1] = { whoText(e.from), U.DateTime(e.t) }
    if type(e.from) == "string" then
        lines[#lines + 1] = T:Wrap("dim", "Click for their profile. Right-click for more.")
    end
    UI:Tip(row, meta.label, lines)
end

local function rowMenu(e)
    local from = type(e.from) == "string" and e.from or nil
    local items = { { text = from and U.ShortName(from) or (KINDS[e.kind] or KINDS.misc).label, title = true } }
    if from then
        items[#items + 1] = { text = "View profile", icon = "roster", func = function()
            if UI.OpenProfile then UI:OpenProfile(from) end
        end }
        if from ~= API.MyKey() then
            items[#items + 1] = { text = "Whisper", icon = "bubble", func = function() UI:Whisper(from) end }
        end
    end
    items[#items + 1] = { text = "Copy text", icon = "export", func = function()
        UI:CopyBox("Neighbourhood Watch", plain(e.text))
    end }
    UI:OpenMenu(nil, items, { width = 170 })
end

local function onRowClick(e, row, button)
    if button == "RightButton" then
        rowMenu(e)
        return
    end
    local clickedAt = API.Time()
    -- a click on an item link belongs to the link (tooltip / shift-link), not the row
    GF:After(0, function()
        if row.linkAt and abs(row.linkAt - clickedAt) < 0.2 then return end
        if type(e.from) == "string" and UI.OpenProfile then UI:OpenProfile(e.from) end
    end)
end

---------------------------------------------------------------- render
local function render(page)
    local list = feedList() or {}
    local active = FILTER_BY_KEY[page.filter] or FILTERS[1]
    local counts = {}
    for _, f in ipairs(FILTERS) do counts[f.key] = 0 end
    local items = {}
    local now = API.ServerTime()
    local today, todayCount = startOfToday(now), 0
    for i = #list, 1, -1 do
        local e = list[i]
        if valid(e) then
            counts.all = counts.all + 1
            if e.t >= today then todayCount = todayCount + 1 end
            for _, f in ipairs(FILTERS) do
                if f.kinds and f.kinds[e.kind] then counts[f.key] = counts[f.key] + 1 end
            end
            if not active.kinds or active.kinds[e.kind] then items[#items + 1] = e end
        end
    end
    for _, chip in ipairs(page.chips) do
        chip.selected = chip.def.key == active.key
        chip:SetCount(counts[chip.def.key])
        paintChip(chip)
    end
    layoutChips(page)
    page.banner.plate.num:SetText(tostring(todayCount))
    local keep = page.renderedFilter == active.key
    page.renderedFilter = active.key
    page.list:SetItems(items, keep)
    local empty = #items == 0
    page.list:SetShown(not empty)
    page.empty:SetShown(empty)
    if empty then page.empty.text:SetText(emptyLine(active)) end
end

local function paintToastButton(btn)
    local on = not (GF.db and GF.db.settings and GF.db.settings.feedToasts == false)
    btn:SetText(on and "Toasts on" or "Toasts off")
    -- a lit green button when the signs are on, the plain gold-rimmed one when they're off
    btn:SetStyle(on and "primary" or "secondary")
end

local function stopClock(page)
    if page.clock then
        page.clock:Cancel()
        page.clock = nil
    end
end

local function startClock(page)
    if page.clock then return end
    -- "5m ago" drifts; repaint the visible rows twice a minute while the page is up
    page.clock = GF:Ticker(30, function()
        if page:IsVisible() then page.list:Refresh() else stopClock(page) end
    end)
end

local function cardEmpty(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", 0, -10)
    f:SetPoint("BOTTOMRIGHT", 0, 10)
    f.icon = UI:Icon(f, 40, "eye", "ARTWORK", { 1, 1, 1, 0.12 })
    f.icon:SetPoint("BOTTOM", f, "CENTER", 0, 8)
    f.text = UI:Text(f, 13, "faint")
    f.text:SetPoint("TOPLEFT", f, "LEFT", 24, -6)
    f.text:SetPoint("TOPRIGHT", f, "RIGHT", -24, -6)
    f.text:SetJustifyH("CENTER")
    f.text:SetWordWrap(true)
    return f
end

local function build(page)
    page.filter = "all"
    page.shone = {}
    local header = UI:PageHeader(page, pageDef.title, pageDef.subtitle)
    page.header = header
    page.toastBtn = header:AddAction(UI:Button(header, "Toasts on", {
        icon = "bell",
        tooltip = { "Watch toasts", { "Pop a road sign when the street has news: level 60s, new crowns, boss kills, new locals.",
            T:Wrap("dim", "Everything still lands in the feed either way.") } },
        onClick = function(self)
            local s = GF.db and GF.db.settings
            if not s then return end
            s.feedToasts = s.feedToasts == false
            paintToastButton(self)
        end,
    }))
    paintToastButton(page.toastBtn)

    page.banner = buildBanner(page, header)

    local card = UI:Card(page, { title = "Latest reports", icon = "eye" })
    card:SetPoint("TOPLEFT", page.banner, "BOTTOMLEFT", 0, -14)
    card:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    page.card = card

    page.chipBar = CreateFrame("Frame", nil, card)
    page.chipBar:SetHeight(22)
    page.chipBar:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -8)
    page.chips = {}
    for _, f in ipairs(FILTERS) do
        page.chips[#page.chips + 1] = makeChip(page.chipBar, f, function(key)
            page.filter = key
            render(page)
        end)
    end

    page.list = UI:List(card.body, {
        rowHeight = ROW_H, spacing = 2,
        createRow = createRow,
        updateRow = function(row, e) updateRow(page, row, e) end,
        onEnter = rowTip,
        onClick = onRowClick,
    })
    page.list:SetAllPoints(card.body)
    page.empty = cardEmpty(card.body)
    page.empty:Hide()
    -- closing the whole window hides the page without an onHide; stop the clock either way
    page:HookScript("OnHide", function() GF:Safe("feed:hide", stopClock, page) end)
end

local function onShow(page)
    local l = localState()
    page.prevSeen = l and l.seen or 0
    markSeen()
    page.banner.line:SetText(U.Pick(SIGN_LINES) or SIGN_LINES[1])
    paintToastButton(page.toastBtn)
    render(page)
    startClock(page)
end

local function onHide(page)
    stopClock(page)
    UI:CloseMenu()
end

pageDef = {
    key = PAGE, title = "Neighbourhood Watch", subtitle = "Curtain-twitching since 2026.",
    icon = "eye", group = "street", order = 2,
    build = build, onShow = onShow, onHide = onHide,
    badge = function()
        local n = Feed:Unread()
        if n <= 0 then return nil end
        return n > 99 and "99+" or n
    end,
}
UI:RegisterPage(pageDef)

-------------------------------------------------------------------------------
-- Wiring
-------------------------------------------------------------------------------
--- Runs fn once, `sec` after the first call of a burst: one live C_Timer however many
-- reports land (GF:Debounce makes a new timer per call; FOREVER_FACTS G18 caps them).
local pending = {}
local function soon(key, sec, fn)
    if pending[key] then return end
    pending[key] = true
    GF:After(sec, function()
        pending[key] = nil
        fn()
    end)
end

GF:On("GF_FEED", function()
    soon("ui", 0.15, function()
        local page = pageDef.frame
        if page and page:IsVisible() then
            markSeen()
            render(page)
        end
        if UI.RefreshNav then UI:RefreshNav() end
    end)
end)

GF:On("GF_GUILD_CHANGED", function()
    moves = {}
    normalize()
    GF:Fire("GF_FEED")
end)

GF:On("GF_ROSTER_UPDATED", function()
    -- names in the rows are class-coloured from the roster
    local page = pageDef.frame
    if page and page:IsVisible() then soon("roster", 1, function() page.list:Refresh() end) end
end)

GF:On("GF_MEMBER_JOINED", function(key) queueMove("join", key) end)
GF:On("GF_MEMBER_LEFT", function(key) queueMove("leave", key) end)

GF:RegisterEvent("PLAYER_LEVEL_UP", onLevelUp, "Feed")
GF:RegisterEvent("CHAT_MSG_LOOT", onChatLoot, "Feed")
GF:RegisterEvent("ENCOUNTER_LOOT_RECEIVED", onEncounterLoot, "Feed")
GF:RegisterEvent("ENCOUNTER_START", onEncounterStart, "Feed")
GF:RegisterEvent("ENCOUNTER_END", onEncounterEnd, "Feed")
