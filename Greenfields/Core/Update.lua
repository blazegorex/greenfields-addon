--[[ Greenfields - Core/Update.lua
     Keeping the street on the same version.

     WoW addons can't download or write files, so the actual update is done outside the
     game by the Greenfields Updater (or an addon manager). This file does the in-game half:
       * notices when any guildie runs a newer version (HELLO messages + profile docs) and
         says so once per version per session: a toast, a header pill, /gf update
       * after an update (not a first install), shows "What's new" from Data/Changelog.lua

     Versions are "major.minor.patch" with an optional "-suffix": 1.0.10 > 1.0.9 and
     1.0.2-beta < 1.0.2. Only plain releases are announced, so a guildie trying a beta or
     dev build doesn't send the whole street off to the updater for nothing.

       Update:Newest() -> { v, n, from } or nil (only when newer than ours)
       Update.Compare(a, b) -> -1 / 0 / 1, or nil when either isn't a version ]]

local _, GF = ...

local Update = {}
GF.Update = Update

local API, U = GF.API, GF.Util

local newest
local toasted = {}
-- forget a newer version we heard about if nobody has mentioned it for this long
local REMEMBER = 21 * 86400
-- rough height budget for the What's New popup (wrapped lines), so it stays on screen
local MAX_LINES, WRAP = 26, 70

local HOW = "Run Update Greenfields on your desktop (or update it in your addon app), then /reload."

--- "1.2.3" / "1.2.3-beta" -> { 1, 2, 3, pre = "beta" } or nil.
local function parse(v)
    v = API.CleanString(v)
    if not v or #v > 24 then return nil end
    local a, b, c, rest = v:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a or #a > 6 or #b > 6 or #c > 6 then return nil end
    local pre
    if rest ~= "" then
        pre = rest:match("^%-([%w%.%-]+)$")
        if not pre then return nil end
    end
    return { tonumber(a), tonumber(b), tonumber(c), pre = pre }
end

local function compare(a, b)
    local x, y = parse(a), parse(b)
    if not x or not y then return nil end
    for i = 1, 3 do
        if x[i] ~= y[i] then return x[i] < y[i] and -1 or 1 end
    end
    if x.pre == y.pre then return 0 end
    if not x.pre then return 1 end   -- a release beats its own betas
    if not y.pre then return -1 end
    return x.pre < y.pre and -1 or 1
end
Update.Compare = compare

function Update:Newest() return newest end

function Update:ShowHowTo()
    if not (GF.UI and GF.UI.Modal) then return end
    local n = newest
    local lines = {}
    if n then
        lines[#lines + 1] = ("Version %s is out (you're on %s) - %s already has it."):format(n.v, GF.VERSION, n.from and U.ShortName(n.from) or "a guildie")
    else
        lines[#lines + 1] = ("You're on %s, the newest anyone on the street is running."):format(GF.VERSION)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "To update:"
    lines[#lines + 1] = "1. Double-click Update Greenfields (the updater the guild handed out). It finds WoW, grabs the latest and installs it."
    lines[#lines + 1] = "2. Or update Greenfields in your addon app if you got it from one."
    lines[#lines + 1] = "3. Back in game: /reload. If something looks missing, restart WoW."
    GF.UI:Modal({
        title = n and "Update available" or "You're up to date",
        style = n and "yellow" or "green",
        text = table.concat(lines, "\n"),
        width = 460,
        buttons = { { text = "Sweet", style = "primary" } },
    })
end

local function announce()
    local n = newest
    if not n or toasted[n.v] then return end
    toasted[n.v] = true
    GF:Print("Greenfields %s is out (you're on %s). %s Type /gf update for help.", n.v, GF.VERSION, HOW)
    if GF.UI and GF.UI.Toast then
        GF.UI:Toast({
            title = "Update available: " .. n.v,
            text = "You're on " .. GF.VERSION .. ". Run Update Greenfields, then /reload. Click for help.",
            icon = "import", style = "yellow", duration = 12, key = "update:" .. n.v,
            onClick = function() Update:ShowHowTo() end,
        })
    end
end

--- Remember the newest version heard of (re-stamped while people keep running it).
local function state()
    if type(GF.db) ~= "table" then return nil end
    if type(GF.db.update) ~= "table" then GF.db.update = {} end
    return GF.db.update
end

local function remember(v)
    local st = state()
    if not st then return end
    if type(st.newest) ~= "string" or compare(v, st.newest) ~= -1 then
        st.newest, st.newestT = v, API.ServerTime()
    end
end

--- Consider a version string reported by `from` (nil = remembered from an earlier session).
local function consider(v, from, fromMemory)
    local key = parse(v)
    if not key or key.pre then return end            -- not a version, or a beta/dev build
    if compare(v, GF.VERSION) ~= 1 then return end    -- not newer than ours
    if not fromMemory then remember(v) end
    if newest and compare(v, newest.v) ~= 1 then return end
    newest = { v = v, n = key[1] * 1000000 + key[2] * 1000 + key[3], from = API.CleanString(from) }
    if GF.UI and GF.UI.UpdateChrome then GF:Safe("update:chrome", GF.UI.UpdateChrome, GF.UI) end
    -- a short delay so a burst of hellos at login produces one toast for the newest
    GF:Debounce("update-announce", 4, announce)
end

GF:On("GF_PEER_SEEN", function(key, peer)
    if type(peer) == "table" then consider(peer.version, key) end
end)

GF:On("GF_STORE_CHANGED", function(name, id, data)
    if name == "profile" and type(data) == "table" and id ~= API.MyKey() then consider(data.v, id) end
end)

-------------------------------------------------------------------------------
-- What's new (after an update)
-------------------------------------------------------------------------------
--- Shows the changelog entries newer than `since` (all of them when `all`) up to ours.
-- Returns true if there was anything to show.
local function whatsNew(since, all)
    if not (GF.UI and GF.UI.Modal and GF.Theme) then return false end
    local T = GF.Theme
    local log = type(GF.Changelog) == "table" and GF.Changelog or {}
    local lines, used, cut = {}, 0, false
    for _, entry in ipairs(log) do
        local v = type(entry) == "table" and entry.v
        if parse(v) and (all or compare(v, since) == 1) and compare(v, GF.VERSION) ~= 1 then
            local date = type(entry.date) == "string" and entry.date ~= "" and T:Wrap("faint", "  " .. entry.date) or ""
            local block, h = { T:Wrap("green", v) .. date }, 1
            for _, note in ipairs(type(entry.notes) == "table" and entry.notes or {}) do
                if type(note) == "string" and note ~= "" then
                    block[#block + 1] = "  - " .. note
                    h = h + math.ceil((#note + 4) / WRAP)
                end
            end
            if used > 0 and used + h > MAX_LINES then cut = true break end
            for i = 1, #block do lines[#lines + 1] = block[i] end
            lines[#lines + 1] = ""
            used = used + h + 1
        end
    end
    if #lines == 0 then return false end
    if cut then
        lines[#lines + 1] = T:Wrap("faint", all and "(older versions left off)" or "More in /gf changelog.")
    end
    GF.UI:Modal({
        title = all and "Greenfields changelog" or ("What's new in Greenfields " .. GF.VERSION),
        text = table.concat(lines, "\n"),
        width = 480,
        buttons = { { text = "Choice", style = "primary" } },
    })
    return true
end

GF:On("GF_LOGIN", function()
    local st = state()
    if not st then return end
    -- a real upgrade only: a first install (no lastVersion) or a downgrade shows nothing
    if compare(st.lastVersion, GF.VERSION) == -1 then st.whatsNewSince = st.lastVersion end
    st.lastVersion = GF.VERSION
    if st.whatsNewSince ~= nil then
        -- kept until it has been shown, so a /reload within the delay doesn't lose it
        GF:After(9, function()
            local s = state()
            local since = s and s.whatsNewSince
            if since == nil then return end
            s.whatsNewSince = nil
            if compare(since, GF.VERSION) == -1 then whatsNew(since) end
        end)
    end
    -- still behind a version we heard about recently?
    if st.newest ~= nil then
        if type(st.newestT) ~= "number" then st.newestT = API.ServerTime() end
        if compare(st.newest, GF.VERSION) ~= 1 or API.ServerTime() - st.newestT > REMEMBER then
            st.newest, st.newestT = nil, nil   -- caught up, or nobody runs it any more
        else
            consider(st.newest, nil, true)
        end
    end
end)

GF:RegisterSlash("update", function() Update:ShowHowTo() end, "check for a newer Greenfields and how to update")
GF:RegisterSlash("changelog", function()
    if not whatsNew(nil, true) then GF:Print("No changelog in this build.") end
end, "show the changelog")
