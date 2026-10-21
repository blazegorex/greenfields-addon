--[[ Greenfields - Core/Doctor.lua
     /gf doctor: probes every client API the addon is unsure about on Forever and prints a
     report. The same report is kept in GreenfieldsDB.doctor so it can be read from the
     SavedVariables file after a /reload. Run it out of combat in the open world, then
     again inside a raid. ]]

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
    { "JumpOrAscendStart", "Skippy stat" },
    { "DoEmote", "Doof Doof stat" },
    { "IsFishingLoot", "Blue Manna Crabber stat" },
    { "GetRepairAllCost", "Panel Beater stat" },
    { "UnitOnTaxi", "Uber Eats stat" },
    { "GetPVPLifetimeStats", "honor kills stat" },
    { "C_Container.GetContainerItemInfo", "consumables + camp kits" },
    { "TooltipDataProcessor.AddTooltipPostCall", "tooltip lines" },
    { "Settings.RegisterCanvasLayoutCategory", "game Settings entry" },
}

local function run()
    local lines = {}
    local function add(fmt, ...) lines[#lines + 1] = select("#", ...) > 0 and fmt:format(...) or fmt end

    local version, build, _, toc = "?", "?", nil, 0
    if GetBuildInfo then version, build, _, toc = GetBuildInfo() end
    add("Client %s (%s), TOC %s, project %s, Forever=%s, unique names=%s",
        tostring(version), tostring(build), tostring(toc), tostring(rawget(_G, "WOW_PROJECT_ID")),
        tostring(API.IsForever()), tostring(API.UniqueNames()))
    add("Me: %s  guild: %s  partition: %s", tostring(API.MyKey()), tostring((API.GuildInfo())), tostring(GF.gdbKey))
    add("Comm: deflate %s, peers online %d, queued %d, sent %d, received %d, throttled %d",
        API.CanCompress() and "on" or "off", GF.Comm:OnlinePeers(), GF.Comm:QueueSize(),
        GF.Comm.stats.sent, GF.Comm.stats.recv, GF.Comm.stats.throttled)
    add("Roster: %d members, %d online; officer rank <= %d", GF.Roster:Count(), GF.Roster:OnlineCount(), GF.Roster:Config().officerRank)

    -- guild + identity: is the data partition the real guild, and do names line up?
    local gname, rankName, rankIndex = API.GuildInfo()
    add("Guild: %s (rank %s/%s), partition %s, ready %s", tostring(gname), tostring(rankName), tostring(rankIndex),
        tostring(GF.gdbKey), tostring(GF.guildReady))
    add("My raw name %q -> key %q", tostring(API.UnitName("player")), tostring(API.MyKey()))
    local sample = {}
    for _, m in ipairs(API.GuildMembers()) do
        if #sample < 3 then sample[#sample + 1] = ("%q->%s"):format(m.name, tostring(m.key)) end
    end
    add("Roster sample: %s", #sample > 0 and table.concat(sample, ", ") or "empty")
    local senders = {}
    for raw, s in pairs(GF.Comm.senders) do
        senders[#senders + 1] = ("%q->%s[%s]%s"):format(raw, s.key, s.channel, GF.Roster:IsMember(s.key) and "" or " NOT-IN-ROSTER")
    end
    add("Addon senders seen: %s", #senders > 0 and table.concat(senders, ", ") or "none (no Greenfields messages received)")
    local rej = {}
    for k, n in pairs(GF.Store.rejected) do rej[#rej + 1] = k .. " x" .. n end
    add("Sync data ignored (not a guildie): %s", #rej > 0 and table.concat(rej, ", ") or "none")
    local counts = {}
    for _, ds in ipairs({ "profile", "stats", "recipes", "crafts", "events", "signups" }) do
        counts[#counts + 1] = ds .. "=" .. GF.Store:Count(ds)
    end
    add("Synced docs here: %s", table.concat(counts, " "))

    local missing = {}
    for _, p in ipairs(PROBES) do
        if not has(p[1]) then missing[#missing + 1] = p[1] .. " (" .. p[2] .. ")" end
    end
    if #missing == 0 then
        add("All %d probed APIs present.", #PROBES)
    else
        add("Missing (%d/%d): %s", #missing, #PROBES, table.concat(missing, ", "))
    end

    -- camp spell IDs resolve?
    local camp = {}
    for _, id in ipairs({ GF.BuffData.CAMP_BENEFITS, GF.BuffData.WELCOMING_CAMPFIRE, 818, 1229737 }) do
        camp[#camp + 1] = id .. "=" .. tostring(API.SpellName(id))
    end
    add("Camp spells: %s", table.concat(camp, "  "))
    add("Camp Benefits on me: %s; auras secret now: %s", tostring(API.PlayerHasAura(GF.BuffData.CAMP_BENEFITS)), tostring(API.AurasSecret()))

    local profs = {}
    for _, p in ipairs(API.Professions()) do profs[#profs + 1] = ("%s(%s) %d/%d"):format(p.name, tostring(p.skillLine), p.rank or 0, p.max or 0) end
    add("Professions: %s", #profs > 0 and table.concat(profs, ", ") or "none read")

    local inst = API.InstanceInfo()
    add("Instance: %s (%s), in raid %s, chat lockdown %s, in combat %s",
        tostring(inst.name), tostring(inst.type), tostring(API.InRaid()), tostring(API.ChatLockdown()), tostring(API.InCombat()))
    add("Errors captured so far: %d (/gf errors)", #GF.errors)

    GF.db.doctor = { t = API.ServerTime(), lines = lines }
    GF:Print("Doctor's report:")
    for _, l in ipairs(lines) do GF:Print("  " .. l) end
    GF:Print("Saved to SavedVariables (GreenfieldsDB.doctor) - /reload to write it to disk.")
end

GF:RegisterSlash("doctor", function() GF:Safe("doctor", run) end, "check which Forever APIs this client supports")
