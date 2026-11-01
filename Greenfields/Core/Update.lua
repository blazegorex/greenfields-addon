--[[ Greenfields - Core/Update.lua
     Keeping the street on the same version.

     WoW addons can't download or write files, so the actual update is done outside the
     game by the Greenfields Updater (or an addon manager). This file does the in-game half:
       * notices when any guildie runs a newer version (HELLO messages + profile docs) and
         says so once per version per session: a toast, a header pill, /gf update
       * after an update (not a first install), shows "What's new" from Data/Changelog.lua
       * /gf install: the links and a Discord post, for getting a mate onto it

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

-- a /reload won't find brand-new files, and most updates bring some art
local HOW = "Run Update Greenfields (or update it in your addon app), then restart WoW. Lost it? /gf install has the link."

-- The links never change: every release uploads these two names, and GitHub's "latest" follows along.
-- The harness fails if this stops matching tools/release_config.json.
local REPO = "https://github.com/blazegorex/greenfields-addon"
local UPDATER_LINK = REPO .. "/releases/latest/download/GreenfieldsUpdater.zip"
local ADDON_LINK = REPO .. "/releases/latest/download/Greenfields.zip"
local ADDONS_FOLDER = "World of Warcraft/_forever_/Interface/AddOns"

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
    local where
    if n then
        where = ("Version %s is out (you're on %s) - %s already has it."):format(n.v, GF.VERSION, n.from and U.ShortName(n.from) or "a guildie")
    elseif GF.gateShut then
        where = ("You're on %s. With the gate shut the addon can't hear about newer ones, so run the updater to be sure."):format(GF.VERSION)
    else
        where = ("You're on %s, the newest anyone on the street is running."):format(GF.VERSION)
    end
    GF.UI:Modal({
        title = n and "Update available" or (GF.gateShut and "Updating Greenfields") or "Newest on the street",
        style = n and "yellow" or "green",
        blocks = {
            { kind = "para", text = where, size = 14, font = "ui", color = "wowGold" },
            { kind = "para", text = "To update:", color = "dim", gap = 12 },
            { kind = "step", n = 1, text = "Double-click Update Greenfields (the updater the guild handed out). It finds WoW, grabs the latest and installs it. Lost it? /gf install has the link." },
            { kind = "step", n = 2, text = "Or update Greenfields in your addon app if you got it from one." },
            { kind = "step", n = 3, text = "On a Mac, or doing it by hand: type /gf install for the link, unzip it, and drag the folder with Greenfields.toc directly inside it into " .. ADDONS_FOLDER .. ", replacing the old one." },
            { kind = "step", n = 4, text = "Quit and reopen WoW. A /reload won't find new art." },
        },
        width = 480,
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
            text = "You're on " .. GF.VERSION .. ". Run Update Greenfields, then restart WoW. Click for help.",
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
    if not (GF.UI and GF.UI.Modal) then return false end
    local log = type(GF.Changelog) == "table" and GF.Changelog or {}
    local blocks = {}
    for _, entry in ipairs(log) do
        local v = type(entry) == "table" and entry.v
        if parse(v) and (all or compare(v, since) == 1) and compare(v, GF.VERSION) ~= 1 then
            blocks[#blocks + 1] = { kind = "heading", text = v, meta = type(entry.date) == "string" and entry.date or "" }
            for _, note in ipairs(type(entry.notes) == "table" and entry.notes or {}) do
                if type(note) == "string" and note ~= "" then
                    blocks[#blocks + 1] = { kind = "bullet", text = note }
                end
            end
        end
    end
    if #blocks == 0 then return false end
    GF.UI:Modal({
        title = all and "Greenfields changelog" or ("What's new in Greenfields " .. GF.VERSION),
        blocks = blocks,
        width = 540,
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
            if GF.gateShut then return end
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

GF:RegisterSlash("update", function() Update:ShowHowTo() end, "check for a newer Greenfields and how to update", true)

--- /gf install: one block that's ready to paste. Open with the gate shut, since whoever's locked out
-- of the guild's copy is exactly who's about to ask for the link.
local function installPost()
    return {
        "The street's got an addon. It's free, which makes it the only thing round here that didn't fall off a truck.",
        "",
        "Windows: " .. UPDATER_LINK,
        "Unzip it somewhere permanent and double-click Update Greenfields. It finds WoW and does the rest. If Windows gets funny, right-click the zip > Properties > Unblock, then unzip it again. A blue SmartScreen box goes away with More info > Run anyway.",
        "",
        "Mac, or doing it by hand: " .. ADDON_LINK,
        "Unzip it and drag the folder with Greenfields.toc directly inside it into " .. ADDONS_FOLDER .. ", replacing any old one.",
        "",
        "Restart WoW after either. Residents only: it wakes up once you're in the guild.",
    }
end

GF:RegisterSlash("install", function()
    GF:Safe("install", function()
        local lines = installPost()
        local UI = GF.UI
        local shown = UI and UI.CopyBox and pcall(UI.CopyBox, UI, "Got the link", table.concat(lines, "\n"), nil,
            "Ctrl+C, then paste it in Discord. The links always get the newest version.")
        if not shown then
            for _, l in ipairs(lines) do GF:Print(l) end
        end
    end)
end, "the download links and a post for Discord, for getting a mate set up", true)
GF:RegisterSlash("changelog", function()
    if not whatsNew(nil, true) then GF:Print("No changelog in this build.") end
end, "show the changelog", true)
