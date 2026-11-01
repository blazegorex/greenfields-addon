--[[ Greenfields - Core/Doctor.lua
     /gf doctor: probes every client API the addon is unsure about on Forever and prints a
     report. The same report is kept in GreenfieldsDB.doctor so it can be read from the
     SavedVariables file after a /reload. Run it out of combat in the open world, then
     again inside a raid. A probe that fails says "untested", which never means "no".

     /gf report: everything a guildie needs to send Spencer, in one copy box.
     /gf mic: posts one test line to the group and reads one /roll back. ]]

local _, GF = ...

local API = GF.API

local function has(path)
    local cur = _G
    for part in path:gmatch("[^%.]+") do
        if type(cur) ~= "table" then return false end
        cur = rawget(cur, part)
        if cur == nil then return false end
    end
    return true
end

-- API name -> what depends on it
local PROBES = {
    { "C_GuildInfo.GuildRoster", "roster refresh" },
    { "GetGuildRosterInfo", "Residents" },
    { "C_ChatInfo.SendAddonMessage", "all syncing" },
    { "C_ChatInfo.InChatMessagingLockdown", "comm lockdown detection" },
    { "C_ChatInfo.SendChatMessage", "raid/guild announcements" },
    { "C_EncodingUtil.CompressString", "smaller sync messages" },
    { "C_TradeSkillUI.GetAllRecipeIDs", "Tradies recipe scan" },
    { "C_TradeSkillUI.GetRecipeOutputItemData", "Tradies item outputs" },
    { "IsPlayerSpell", "recipe + buff capability checks" },
    { "C_UnitAuras.GetBuffDataByIndex", "Buff Check live scan" },
    { "C_UnitAuras.GetPlayerAuraBySpellID", "camp buff detection" },
    { "C_Secrets.ShouldAurasBeSecret", "aura secrecy check" },
    { "GetLootMethod", "master loot (old API)" },
    { "C_PartyInfo.GetLootMethod", "master loot (new API)" },
    { "GetMasterLootCandidate", "Loot Desk award" },
    { "GiveMasterLoot", "Loot Desk award" },
    { "GetLootRollItemLink", "SR need/pass popups" },
    { "SetRaidSubgroup", "Apply groups" },
    { "C_PartyInfo.InviteUnit", "Invite signed" },
    { "UnitIsAFK", "Durry Break stat" },
    { "JumpOrAscendStart", "Been Up Since Tuesday stat" },
    { "DoEmote", "Doof Doof stat" },
    { "IsFishingLoot", "Blue Manna Crabber stat" },
    { "GetRepairAllCost", "Panel Beater stat" },
    { "UnitOnTaxi", "Uber Eats stat" },
    { "GetPVPLifetimeStats", "honor kills stat" },
    { "C_Container.GetContainerItemInfo", "consumables + camp kits" },
    { "TooltipDataProcessor.AddTooltipPostCall", "tooltip lines" },
    { "Settings.RegisterCanvasLayoutCategory", "game Settings entry" },
}

-- Getters from the forever-branch API docs that take no arguments, so asking can't change anything.
-- Only these get called (C_DamageMeter also holds a reset). The rest of the table just gets listed.
local ASK_APIS = {
    { "Meter API", "C_DamageMeter", { "IsDamageMeterAvailable", "GetAvailableCombatSessions" } },
    { "Loot history API", "C_LootHistory", { "GetLootHistoryTime", "GetAllEncounterInfos" } },
}
local RESTRICTIONS = { "Chat", "Combat", "Encounter", "Map", "PvPMatch", "ChallengeMode" }

--- The first line of whatever a failed pcall handed back.
local function why(err)
    if not API.Readable(err) then return "the game hid the error" end
    return tostring(err):match("^[^\n]*") or "?"
end

-- Each probe answers for itself: when one dies it says "untested" and the rest still run.
local DOCTOR = {
    { "Client", function(add)
        local version, build, _, toc = "?", "?", nil, 0
        if GetBuildInfo then version, build, _, toc = GetBuildInfo() end
        add("Client %s (%s), TOC %s, project %s, Forever=%s, unique names=%s",
            tostring(version), tostring(build), tostring(toc), tostring(rawget(_G, "WOW_PROJECT_ID")),
            tostring(API.IsForever()), tostring(API.UniqueNames()))
    end },
    { "Me", function(add)
        add("Me: %s  guild: %s  partition: %s", tostring(API.MyKey()), tostring((API.GuildInfo())), tostring(GF.gdbKey))
    end },
    { "Comm", function(add)
        add("Comm: deflate %s, peers online %d, queued %d, sent %d, received %d, throttled %d",
            API.CanCompress() and "on" or "off", GF.Comm:OnlinePeers(), GF.Comm:QueueSize(),
            GF.Comm.stats.sent, GF.Comm.stats.recv, GF.Comm.stats.throttled)
    end },
    { "Roster", function(add)
        add("Roster: %d members, %d online; officer rank <= %d", GF.Roster:Count(), GF.Roster:OnlineCount(), GF.Roster:Config().officerRank)
        add("Roster rows hidden at last scan: %d; read in full this session: %s", GF.Roster:HiddenRows(), tostring(GF.Roster:ReadAll()))
    end },
    { "Guild lock", function(add)
        add("Guild lock: %s", GF.Gate and GF.Gate:Status() or "not loaded (restart WoW)")
    end },
    -- guild + identity: is the data partition the real guild, and do names line up?
    { "Guild", function(add)
        local gname, rankName, rankIndex = API.GuildInfo()
        add("Guild: %s (rank %s/%s), partition %s, ready %s", tostring(gname), tostring(rankName), tostring(rankIndex),
            tostring(GF.gdbKey), tostring(GF.guildReady))
    end },
    { "My raw name", function(add)
        local first, surname = API.FullName("player")
        add("My raw name %q -> key %q; full name says %q + surname %q", tostring(API.UnitName("player")), tostring(API.MyKey()),
            tostring(first), tostring(surname))
    end },
    { "Roster sample", function(add)
        local sample = {}
        for _, m in ipairs(API.GuildMembers()) do
            if #sample < 3 then sample[#sample + 1] = ("%q->%s"):format(m.name, tostring(m.key)) end
        end
        add("Roster sample: %s", #sample > 0 and table.concat(sample, ", ") or "empty")
    end },
    { "Emote hook", function(add)
        local h = GF.Stats:EmoteHook()
        if not h.fn then return add("Emote hook: hasn't fired yet. Type /dance, open the map, ask again.") end
        local function show(v) return API.Readable(v) and tostring(v) or "hidden" end
        add("Emote hook: last %s(%s, %s, %s), counted %d, ignored %d", h.fn, show(h.token), show(h.unit), show(h.third), h.counted, h.ignored)
    end },
    { "Addon senders seen", function(add)
        local senders = {}
        for raw, s in pairs(GF.Comm.senders) do
            senders[#senders + 1] = ("%q->%s[%s]%s"):format(raw, s.key, s.channel, GF.Roster:IsMember(s.key) and "" or " NOT-IN-ROSTER")
        end
        add("Addon senders seen: %s", #senders > 0 and table.concat(senders, ", ") or "none (no Greenfields messages received)")
    end },
    { "Sender naming", function(add)
        local bare, realm, surname, others, strangers = 0, 0, 0, 0, 0
        local me = API.MyKey()
        for raw, s in pairs(GF.Comm.senders) do
            if raw:find(" ", 1, true) then surname = surname + 1
            elseif raw:find("-", 1, true) then realm = realm + 1
            else bare = bare + 1 end
            if s.key ~= me then others = others + 1 end
            if not GF.Roster:IsMember(s.key) then strangers = strangers + 1 end
        end
        if others == 0 then
            add("Sender naming: untested (nobody else's messages seen yet)")
        else
            add("Sender naming: %d as Name, %d as Name-Suffix, %d as Name Surname. Not on the roster: %d", bare, realm, surname, strangers)
        end
    end },
    { "Repeated first names", function(add)
        local members, hidden = API.GuildMembers()
        if #members == 0 then
            add("Repeated first names: untested (no roster rows read)")
            return
        end
        local byKey, rows, clashes = {}, {}, {}
        for _, m in ipairs(members) do
            if m.key and not rows[m.name] then
                rows[m.name] = true
                byKey[m.key] = byKey[m.key] or {}
                table.insert(byKey[m.key], m.name)
            end
        end
        for key, names in pairs(byKey) do
            if #names > 1 then clashes[#clashes + 1] = ("%s x%d (%s)"):format(key, #names, table.concat(names, ", ")) end
        end
        -- held over from a scan that could see the pair, when this one can't
        for key, names in pairs(GF.Roster:Clashes()) do
            if #(byKey[key] or {}) < 2 then clashes[#clashes + 1] = ("%s x%d (%s, from an earlier scan)"):format(key, #names, table.concat(names, ", ")) end
        end
        table.sort(clashes)
        local note = (hidden or 0) > 0 and (", but %d rows were hidden"):format(hidden) or ""
        local warn = #clashes > 0 and ". WARNING: no officer or GM rights, whispers or invites on those names until one's gone" or ""
        add("Repeated first names: %s%s%s", #clashes > 0 and table.concat(clashes, "; ") or ("none in %d rows"):format(#members), note, warn)
    end },
    { "Sync data ignored", function(add)
        local rej = {}
        for k, n in pairs(GF.Store.rejected) do rej[#rej + 1] = k .. " x" .. n end
        add("Sync data ignored (not a guildie): %s", #rej > 0 and table.concat(rej, ", ") or "none")
    end },
    { "Whisper bounces", function(add)
        local pattern = GF.Comm:BouncePattern()
        add("Whisper bounces: %s", pattern and ("not-found pattern built: " .. pattern)
            or "no not-found pattern, so an addon whisper to someone who's just left shows in chat")
    end },
    { "Addon messages ignored", function(add)
        local ign = {}
        for k, n in pairs(GF.Comm.ignored) do ign[#ign + 1] = k .. " x" .. n end
        add("Addon messages ignored (never on the roster): %s", #ign > 0 and table.concat(ign, ", ") or "none")
    end },
    { "Synced docs", function(add)
        local counts = {}
        for _, ds in ipairs({ "profile", "stats", "recipes", "crafts", "events", "signups" }) do
            counts[#counts + 1] = ds .. "=" .. GF.Store:Count(ds)
        end
        add("Synced docs here: %s", table.concat(counts, " "))
    end },
    { "API probes", function(add)
        local missing = {}
        for _, p in ipairs(PROBES) do
            if not has(p[1]) then missing[#missing + 1] = p[1] .. " (" .. p[2] .. ")" end
        end
        if #missing == 0 then
            add("All %d probed APIs present.", #PROBES)
        else
            add("Missing (%d/%d): %s", #missing, #PROBES, table.concat(missing, ", "))
        end
    end },
    { "Loot methods", function(add)
        local known = API.EnumNames("LootMethod")
        add("Loot methods the client lists: %s. Now: %s. Can set: %s",
            known and table.concat(known, ", ") or "untested (no list)",
            not API.InGroup() and "solo" or API.LootMethodNow() or "untested (no answer)",
            (has("C_PartyInfo.SetLootMethod") or has("SetLootMethod")) and "yes" or "no API")
    end },
    { "Restrictions", function(add)
        local out, kinds, seen = {}, {}, {}
        for _, kind in ipairs(RESTRICTIONS) do kinds[#kinds + 1] = kind; seen[kind] = true end
        -- the six are read off CVar names, so anything else the client calls one gets asked about too
        for _, kind in ipairs(API.EnumNames("AddOnRestrictionType") or {}) do
            if not seen[kind] then kinds[#kinds + 1] = kind end
        end
        for _, kind in ipairs(kinds) do
            local on = API.RestrictionActive(kind)
            out[#out + 1] = kind .. "=" .. (on == nil and "untested" or on and "on" or "off")
        end
        add("Restrictions: %s", table.concat(out, " "))
    end },
    { "Meter and loot history", function(add)
        for _, a in ipairs(ASK_APIS) do
            local funcs = API.ClientFunctions(a[2])
            if not funcs then
                add("%s: %s isn't on this client", a[1], a[2])
            else
                local said = {}
                for _, fn in ipairs(a[3]) do
                    local state, text = API.Ask(a[2] .. "." .. fn)
                    if state == "ok" then said[#said + 1] = fn .. " says " .. text
                    elseif state == "failed" then said[#said + 1] = fn .. " untested (" .. why(text) .. ")" end
                end
                add("%s: %s has %d functions (%s). %s", a[1], a[2], #funcs, table.concat(funcs, ", ", 1, math.min(#funcs, 12)),
                    #said > 0 and table.concat(said, "; ") or "None of the calls we know are there: untested")
            end
        end
    end },
    { "Guild location", function(add)
        local state, text = API.Ask("C_GuildInfo.GetPreferredPlaySettings")
        if state == "missing" then
            add("Guild location: the client has no such setting")
        elseif state == "failed" then
            add("Guild location: untested (%s)", why(text))
        else
            local fstate, ftext = API.Ask("C_GuildInfo.GetPreferredPlaySettingsFeatures")
            -- no table here: the docs have these as plain returns, in this order
            add("Guild location (loaded, locale, data centre, locale changed, data centre changed, cooldown days): %s", text)
            add("Guild location, can change (locale, data centre): %s", fstate == "ok" and ftext or "untested")
        end
    end },
    -- camp spell IDs resolve?
    { "Camp spells", function(add)
        local camp = {}
        for _, id in ipairs({ GF.BuffData.CAMP_BENEFITS, GF.BuffData.WELCOMING_CAMPFIRE, 818, 1229737 }) do
            camp[#camp + 1] = id .. "=" .. tostring(API.SpellName(id))
        end
        add("Camp spells: %s", table.concat(camp, "  "))
        add("Camp Benefits on me: %s; auras secret now: %s", tostring(API.PlayerHasAura(GF.BuffData.CAMP_BENEFITS)), tostring(API.AurasSecret()))
    end },
    { "Professions", function(add)
        local profs = {}
        for _, p in ipairs(API.Professions()) do profs[#profs + 1] = ("%s(%s) %d/%d"):format(p.name, tostring(p.skillLine), p.rank or 0, p.max or 0) end
        add("Professions: %s", #profs > 0 and table.concat(profs, ", ") or "none read")
    end },
    { "Instance", function(add)
        local inst = API.InstanceInfo()
        add("Instance: %s (%s), in raid %s, chat lockdown %s, in combat %s",
            tostring(inst.name), tostring(inst.type), tostring(API.InRaid()), tostring(API.ChatLockdown()), tostring(API.InCombat()))
    end },
    { "Errors", function(add)
        add("Errors captured so far: %d (/gf errors), %d in the Black Box (/gf report)", #GF.errors, #GF:BlackBox())
    end },
}

local function run()
    local lines = {}
    local function add(fmt, ...) lines[#lines + 1] = select("#", ...) > 0 and fmt:format(...) or fmt end
    for _, probe in ipairs(DOCTOR) do
        local ok, err = pcall(probe[2], add)
        if not ok then add("%s: untested (%s)", probe[1], why(err)) end
    end
    local saved = type(GF.db) == "table"
    if saved then GF.db.doctor = { t = API.ServerTime(), lines = lines } end
    GF:Print("Doctor's report:")
    for _, l in ipairs(lines) do GF:Print("  " .. l) end
    if saved then GF:Print("Saved to SavedVariables (GreenfieldsDB.doctor) - /reload to write it to disk.") end
end

GF:RegisterSlash("doctor", function() GF:Safe("doctor", run) end, "check which Forever APIs this client supports", true)

-------------------------------------------------------------------------------
-- /gf report: one block of text to paste to Spencer. Saved data can be missing or left over from
-- an older version, so every part checks what it's reading and answers for itself.
-------------------------------------------------------------------------------
local REPORT_ERR_LINES, REPORT_ERR_TEXT = 6, 600

local function plain(s)
    return (GF.Util.StripCodes(s):gsub("|", "/"))
end

local function errorBlock(text)
    local out = {}
    for line in tostring(text):sub(1, REPORT_ERR_TEXT):gmatch("[^\n]+") do
        if #out >= REPORT_ERR_LINES then break end
        out[#out + 1] = (#out == 0 and "  " or "    ") .. line
    end
    return out
end

local REPORT = {
    { "Who", function(add)
        add("Greenfields %s, %s", tostring(GF.VERSION), GF.Util.DateTime(API.ServerTime(), true))
        local version, build, _, toc = "?", "?", nil, 0
        if GetBuildInfo then version, build, _, toc = GetBuildInfo() end
        add("Client %s (%s), TOC %s, Forever=%s", tostring(version), tostring(build), tostring(toc), tostring(API.IsForever()))
        add("Me: %s  guild: %s", tostring(API.MyKey()), tostring((API.GuildInfo())))
    end },
    { "Guild lock", function(add)
        add("Guild lock: %s", GF.Gate and GF.Gate:Status() or "not loaded (restart WoW)")
    end },
    { "Events", function(add)
        local failed = {}
        for event in pairs(GF.failedEvents) do failed[#failed + 1] = event end
        table.sort(failed)
        add("Game events that wouldn't register: %s", #failed > 0 and table.concat(failed, ", ") or "none")
    end },
    { "Errors", function(add)
        local box = GF:BlackBox()
        add("Errors this session: %d. In the Black Box: %d.", #GF.errors, #box)
        for _, b in ipairs(box) do
            add("[%s %s%s] %s", tostring(b.v or "?"), type(b.t) == "number" and GF.Util.DateTime(b.t) or "?",
                (tonumber(b.n) or 1) > 1 and (", " .. tostring(b.n) .. " sessions") or "", tostring(b.label or "?"))
            for _, line in ipairs(errorBlock(b.err)) do add(line) end
        end
        -- no saved variables to keep them in: this session's are still here
        if type(GF.db) ~= "table" then
            for _, e in ipairs(GF.errors) do
                add("[this session] %s", tostring(e.label))
                for _, line in ipairs(errorBlock(e.err)) do add(line) end
            end
        end
    end },
    { "Mic check", function(add)
        local m = type(GF.db) == "table" and GF.db.mic
        if type(m) ~= "table" or type(m.lines) ~= "table" then return add("Mic check: not run") end
        add("Mic check, %s:", type(m.t) == "number" and GF.Util.Ago(m.t) or "?")
        for _, l in ipairs(m.lines) do add("  " .. tostring(l)) end
    end },
    { "Doctor", function(add)
        local d = type(GF.db) == "table" and GF.db.doctor
        if type(d) ~= "table" or type(d.lines) ~= "table" then return add("Doctor: not run (/gf doctor, then /gf report again)") end
        add("Doctor, %s:", type(d.t) == "number" and GF.Util.Ago(d.t) or "?")
        for _, l in ipairs(d.lines) do add("  " .. tostring(l)) end
    end },
}

local function buildReport()
    local lines = {}
    local function add(fmt, ...) lines[#lines + 1] = plain(select("#", ...) > 0 and fmt:format(...) or fmt) end
    for _, part in ipairs(REPORT) do
        local ok, err = pcall(part[2], add)
        if not ok then lines[#lines + 1] = part[1] .. ": untested (" .. plain(why(err)) .. ")" end
    end
    return lines
end

GF:RegisterSlash("report", function(arg)
    GF:Safe("report", function()
        if arg == "clear" then
            if type(GF.db) == "table" then GF.db.blackBox = nil end
            GF:Print("Black Box emptied.")
            return
        end
        local lines = buildReport()
        local UI = GF.UI
        local shown = UI and UI.CopyBox and pcall(UI.CopyBox, UI, "Black Box", table.concat(lines, "\n"), nil,
            "Ctrl+C, then paste it to Spencer. Add a screenshot if something looks wrong. /gf report clear starts it fresh.")
        if not shown then
            for _, l in ipairs(lines) do GF:Print(l) end
        end
    end)
end, "[clear] - errors and details to copy and paste to Spencer", true)

-------------------------------------------------------------------------------
-- /gf mic: can we talk to the group and read a /roll off the system channel? One line goes out, and
-- nobody gets pinged again. What it sees only ever goes in GreenfieldsDB.mic for /gf report: the Loot
-- Desk never looks at it, and it won't start with a roll on at the desk, since that /roll would count.
-------------------------------------------------------------------------------
local MIC_WAIT = 60
local MIC_LINE = "Greenfields mic check from the back of the servo, one two. Someone type /roll."
local mic

local function micFinish()
    local m = mic
    if not m then return end
    mic = nil
    local lines = {}
    if m.blocked then
        lines[#lines + 1] = ("Line: the game blocked it (%s)."):format(m.blocked)
    elseif not m.posted then
        lines[#lines + 1] = ("Line: not posted (%s), so untested. Try again out of the fight."):format(why(m.failed or "no answer"))
    elseif m.echoFrom then
        lines[#lines + 1] = ("Line: posted to %s and it came back, sent by %q, which we key as %s."):format(m.channel, m.echoFrom, tostring(API.Key(m.echoFrom)))
    elseif m.echo then
        lines[#lines + 1] = ("Line: posted to %s and it came back, but the game hid who sent it."):format(m.channel)
    elseif m.echoHidden > 0 then
        lines[#lines + 1] = ("Line: posted to %s. The game hid the text of %d group line(s), so we can't say it came back."):format(m.channel, m.echoHidden)
    else
        lines[#lines + 1] = ("Line: posted to %s, and we never saw it come back."):format(m.channel)
    end
    if m.roll then
        lines[#lines + 1] = ("/roll: read %q. %s rolled %d (%d-%d), in the group: %s."):format(m.roll.line, tostring(m.roll.key), m.roll.value, m.roll.lo, m.roll.hi,
            tostring(m.roll.key == API.MyKey() or GF.Roster:InGroup(m.roll.key)))
    elseif m.hidden > 0 then
        lines[#lines + 1] = ("/roll: untested. The game hid %d system line(s) that could have been one."):format(m.hidden)
    else
        lines[#lines + 1] = ("/roll: untested. Nobody rolled in %d seconds."):format(MIC_WAIT)
    end
    if type(GF.db) == "table" then GF.db.mic = { t = API.ServerTime(), lines = lines } end
    GF:Print("Mic check:")
    for _, l in ipairs(lines) do GF:Print("  " .. l) end
end

local function micStart()
    if mic then
        GF:Print("Still listening for a /roll. %d seconds left.", math.max(0, math.ceil(mic.ends - API.Time())))
        return
    end
    local channel = API.GroupChannel()
    if not channel then
        GF:Print("Nobody to test on. Get in a party, then /gf mic.")
        return
    end
    local deskRoll = GF.Loot and GF.Loot.CurrentRoll and GF.Loot:CurrentRoll()
    if deskRoll and not deskRoll.done then
        GF:Print("There's a roll on at the Loot Desk. Try again once it's done.")
        return
    end
    local m = { channel = channel, ends = API.Time() + MIC_WAIT, echoHidden = 0, hidden = 0 }
    mic = m
    local ok, err = API.SendChat(MIC_LINE, channel)
    m.posted, m.failed = ok, err
    GF:Print("Mic check: listening for a /roll for %d seconds. Yours counts, a mate's tells us more.", MIC_WAIT)
    GF:After(MIC_WAIT, function()
        if mic == m then micFinish() end
    end)
end

local function micHeardGroup(_, text, sender)
    local m = mic
    if not m or GF.gateShut then return end
    text = API.CleanString(text)
    if not text then
        m.echoHidden = m.echoHidden + 1
    elseif text == MIC_LINE then
        m.echo = true
        m.echoFrom = API.CleanString(sender)
    end
end

for _, event in ipairs({ "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
                         "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER" }) do
    GF:RegisterEvent(event, micHeardGroup)
end

GF:RegisterEvent("CHAT_MSG_SYSTEM", function(_, msg)
    local m = mic
    if not m or GF.gateShut then return end
    msg = API.CleanString(msg)
    if not msg then
        m.hidden = m.hidden + 1
        return
    end
    local name, value, lo, hi = msg:match(GF.Loot and GF.Loot.RollPattern and GF.Loot.RollPattern() or "^(.+) rolls (%d+) %((%d+)%-(%d+)%)$")
    value, lo, hi = tonumber(value), tonumber(lo), tonumber(hi)
    if not name or not value or not lo or not hi then return end
    m.roll = { line = msg, key = API.Key(name), value = value, lo = lo, hi = hi }
    micFinish()
end)

local function micBlocked(_, addon, fn)
    if not mic then return end
    if API.CleanString(addon) == GF.ADDON then mic.blocked = API.CleanString(fn) or "something" end
end
GF:RegisterEvent("ADDON_ACTION_BLOCKED", micBlocked)
GF:RegisterEvent("ADDON_ACTION_FORBIDDEN", micBlocked)

-- Runs in the keypress, not a tick later: the client can insist a key was pressed before it posts.
GF:RegisterSlash("mic", function() GF:Safe("mic", micStart) end, "post one test line to your group and read a /roll back", false, true)
