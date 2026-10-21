--[[ Greenfields - Core/Comm.lua
     Addon-channel messaging: serialization, optional deflate, chunking, a throttled
     priority queue, lockdown deferral and reassembly.

       GF.Comm:Register(op, fn(payload, senderKey, channel), { self = bool })
       GF.Comm:Send(op, payload, channel, target, prio)   channel: GUILD|GROUP|RAID|PARTY|WHISPER
       GF.Comm:Guild(op, payload, prio)
       GF.Comm:Group(op, payload, prio)
       GF.Comm:Whisper(targetKey, op, payload, prio)
     prio: "ALERT" > "NORMAL" (default) > "BULK"

     Wire: every addon message = 1 header char + body.
       "1" whole message  "2" first chunk  "3" middle chunk  "4" last chunk
     Whole message = encoding char + data:  "r" serialized | "z" base64(deflate(serialized))
     serialized = Serialize({ op, payload, PROTOCOL }) ]]

local _, GF = ...

local Comm = {}
GF.Comm = Comm

local API, U, Ser = GF.API, GF.Util, GF.Serialize
local type, pairs, ipairs, tostring, sub, concat, min, max = type, pairs, ipairs, tostring, string.sub, table.concat, math.min, math.max

Comm.PREFIX = "GRNFLDS"
local CHUNK = 250
local COMPRESS_OVER = 160      -- only bother compressing payloads bigger than this
local BUCKET_MAX = 8           -- burst
local REFILL = 0.45            -- seconds per message token
local REASSEMBLY_TTL = 90

Comm.handlers = {}
Comm.senders, Comm.senderCount = {}, 0   -- raw sender -> {key, channel} (diagnostics)
Comm.peers = {}                -- key -> { version=, proto=, seen= }
Comm.stats = { sent = 0, recv = 0, bytesOut = 0, dropped = 0, throttled = 0 }

local queues = { ALERT = {}, NORMAL = {}, BULK = {} }
local PRIOS = { "ALERT", "NORMAL", "BULK" }
local inflight = {}            -- streamKey -> message being chunked out
local tokens = BUCKET_MAX
local pausedUntil = 0
local buffers = {}             -- sender..channel -> { parts, t }

-------------------------------------------------------------------------------
-- Registration
-------------------------------------------------------------------------------
function Comm:Register(op, fn, opts)
    self.handlers[op] = { fn = fn, self = opts and opts.self or false }
end

-------------------------------------------------------------------------------
-- Encoding
-------------------------------------------------------------------------------
local function encode(op, payload)
    local s = Ser.Encode({ op, payload, GF.PROTOCOL })
    if #s > COMPRESS_OVER and API.CanCompress() then
        local z = API.Compress(s)
        if z and #z + 1 < #s then return "z" .. z end
    end
    return "r" .. s
end

local function decode(full)
    local enc, data = sub(full, 1, 1), sub(full, 2)
    if enc == "z" then
        data = API.Decompress(data)
        if not data then return nil end
    elseif enc ~= "r" then
        return nil
    end
    local ok, msg = Ser.Decode(data)
    if not ok or type(msg) ~= "table" or type(msg[1]) ~= "string" then return nil end
    return msg[1], msg[2], tonumber(msg[3]) or 0
end

local function chunk(full)
    if #full <= CHUNK then return { "1" .. full } end
    local parts = {}
    local n = math.ceil(#full / CHUNK)
    for i = 1, n do
        local piece = sub(full, (i - 1) * CHUNK + 1, i * CHUNK)
        local h = (i == 1) and "2" or (i == n and "4" or "3")
        parts[i] = h .. piece
    end
    return parts
end

-------------------------------------------------------------------------------
-- Sending
-------------------------------------------------------------------------------
local function resolveChannel(channel)
    if channel == "GROUP" then return API.GroupChannel() end
    if channel == "GUILD" then return API.InGuild() and "GUILD" or nil end
    if channel == "RAID" then return API.InRaid() and "RAID" or API.GroupChannel() end
    if channel == "PARTY" then return API.InGroup() and "PARTY" or nil end
    return channel
end

--- Send(op, payload, channel, target, prio) -> true when queued
function Comm:Send(op, payload, channel, target, prio)
    channel = resolveChannel(channel)
    if not channel then return false end
    if channel == "WHISPER" and (type(target) ~= "string" or target == "") then return false end
    local ok, full = pcall(encode, op, payload)
    if not ok then
        GF:Debug("comm encode failed for %s: %s", tostring(op), tostring(full))
        return false
    end
    local q = queues[prio or "NORMAL"] or queues.NORMAL
    q[#q + 1] = {
        parts = chunk(full), idx = 1, channel = channel, target = target,
        stream = channel .. ":" .. (target or ""), op = op,
    }
    Comm:Pump()
    return true
end

function Comm:Guild(op, payload, prio) return self:Send(op, payload, "GUILD", nil, prio) end
function Comm:Group(op, payload, prio) return self:Send(op, payload, "GROUP", nil, prio) end
function Comm:Whisper(target, op, payload, prio)
    if target == API.MyKey() then return false end
    return self:Send(op, payload, "WHISPER", target, prio)
end

function Comm:QueueSize()
    local n = 0
    for _, p in ipairs(PRIOS) do n = n + #queues[p] end
    for _ in pairs(inflight) do n = n + 1 end
    return n
end

local function nextMessage()
    -- finish any message already partly on the wire first (keeps chunk streams whole)
    for key, m in pairs(inflight) do return m, key end
    for _, p in ipairs(PRIOS) do
        local q = queues[p]
        if #q > 0 then
            local m = table.remove(q, 1)
            -- don't start a second multipart message on a stream that is mid-message
            if inflight[m.stream] then
                table.insert(q, 1, m)
            else
                return m, nil
            end
        end
    end
    return nil
end

local pumping = false
local lastRefill = 0

function Comm:Pump()
    if pumping then return end
    pumping = true
    local now = API.Time()
    if lastRefill == 0 then lastRefill = now end
    local gained = (now - lastRefill) / REFILL
    if gained >= 1 then
        tokens = min(BUCKET_MAX, tokens + math.floor(gained))
        lastRefill = now
    end
    while tokens >= 1 and now >= pausedUntil do
        local m, key = nextMessage()
        if not m then break end
        if API.ChatLockdown() then
            -- the client is holding chat (encounter lockdown); try again later
            if not key then table.insert(queues.NORMAL, 1, m) end
            pausedUntil = now + 3
            break
        end
        local part = m.parts[m.idx]
        local ok, why = API.SendAddon(Comm.PREFIX, part, m.channel, m.target)
        if ok then
            tokens = tokens - 1
            Comm.stats.sent = Comm.stats.sent + 1
            Comm.stats.bytesOut = Comm.stats.bytesOut + #part
            m.idx = m.idx + 1
            if m.idx > #m.parts then
                if key then inflight[key] = nil end
            elseif not key then
                inflight[m.stream] = m
            end
        elseif why == "throttle" or why == "lockdown" then
            Comm.stats.throttled = Comm.stats.throttled + 1
            if not key then table.insert(queues.NORMAL, 1, m) end
            pausedUntil = now + (why == "lockdown" and 3 or 1.2)
            break
        else
            -- hard failure (not in guild/group any more, bad target): drop the message
            Comm.stats.dropped = Comm.stats.dropped + 1
            if key then inflight[key] = nil end
        end
    end
    pumping = false
end

-------------------------------------------------------------------------------
-- Receiving
-------------------------------------------------------------------------------
local function deliver(full, senderKey, channel)
    local op, payload, proto = decode(full)
    if not op then
        GF:Debug("comm: undecodable message from %s", tostring(senderKey))
        return
    end
    if senderKey ~= API.MyKey() then
        local peer = Comm.peers[senderKey]
        if not peer then
            peer = {}
            Comm.peers[senderKey] = peer
        end
        peer.seen = API.ServerTime()
        peer.proto = proto
    end
    local h = Comm.handlers[op]
    if not h then return end
    if senderKey == API.MyKey() and not h.self then return end
    Comm.stats.recv = Comm.stats.recv + 1
    GF:Safe("comm:" .. op, h.fn, payload, senderKey, channel)
end

local function onAddonMessage(_, prefix, text, channel, sender)
    if prefix ~= Comm.PREFIX then return end
    if not API.Readable(text) or not API.Readable(sender) or type(text) ~= "string" then return end
    local key = API.Key(sender)
    if not key then return end
    -- diagnostics for /gf doctor: the raw sender format Forever uses, and what we keyed it as
    if not Comm.senders[sender] and Comm.senderCount < 20 then
        Comm.senderCount = Comm.senderCount + 1
        Comm.senders[sender] = { key = key, channel = tostring(channel) }
    end
    local h, body = sub(text, 1, 1), sub(text, 2)
    local bkey = key .. "\031" .. tostring(channel)
    if h == "1" then
        deliver(body, key, channel)
    elseif h == "2" then
        buffers[bkey] = { parts = { body }, t = API.Time() }
    elseif h == "3" then
        local b = buffers[bkey]
        if b then b.parts[#b.parts + 1] = body; b.t = API.Time() end
    elseif h == "4" then
        local b = buffers[bkey]
        if b then
            b.parts[#b.parts + 1] = body
            buffers[bkey] = nil
            deliver(concat(b.parts), key, channel)
        end
    end
end

-------------------------------------------------------------------------------
-- Presence: HELLO carries our version; peers track who runs Greenfields.
-------------------------------------------------------------------------------
local function versionNumber(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    if not a then return 0 end
    return tonumber(a) * 10000 + tonumber(b) * 100 + (tonumber(c) or 0)
end
Comm.VersionNumber = versionNumber

function Comm:SendHello(channel, target)
    self:Send("HI", { v = GF.VERSION, p = GF.PROTOCOL, c = API.UnitClassFile("player"), l = API.UnitLevel("player") },
        channel or "GUILD", target, "NORMAL")
end

Comm:Register("HI", function(p, sender, channel)
    if type(p) ~= "table" then return end
    local peer = Comm.peers[sender] or {}
    Comm.peers[sender] = peer
    local v = type(p.v) == "string" and p.v or ""
    peer.version = (#v <= 16 and v:match("^[%w%.%-]+$")) and v or "?"
    peer.class = (type(p.c) == "string" and #p.c <= 16 and p.c:match("^%u+$")) and p.c or nil
    peer.level = type(p.l) == "number" and p.l or nil
    peer.seen = API.ServerTime()
    local known = GF.DB and GF.gdb and GF.DB:Local("comm")
    if known then
        known.peers = known.peers or {}
        known.peers[sender] = { v = peer.version, t = peer.seen }
    end
    -- answer a guild hello once, so the newcomer learns who has the addon
    if channel == "GUILD" and not p.r then
        GF:After(1 + math.random() * 6, function()
            Comm:Send("HI", { v = GF.VERSION, p = GF.PROTOCOL, r = 1, c = API.UnitClassFile("player"), l = API.UnitLevel("player") },
                "WHISPER", sender, "BULK")
        end)
    end
    GF:Fire("GF_PEER_SEEN", sender, peer)
end)

--- HasAddon(key) -> version string or nil (seen this session or remembered from before).
function Comm:HasAddon(key)
    if key == API.MyKey() then return GF.VERSION end
    local p = self.peers[key]
    if p and p.version then return p.version end
    local known = GF.gdb and GF.gdb["local"] and GF.gdb["local"].comm
    known = known and known.peers and known.peers[key]
    return known and known.v or nil
end

function Comm:OnlinePeers()
    local n, now = 0, API.ServerTime()
    for _, p in pairs(self.peers) do
        if p.seen and now - p.seen < 3600 then n = n + 1 end
    end
    return n
end

-------------------------------------------------------------------------------
-- Boot
-------------------------------------------------------------------------------
GF:On("GF_INIT", function()
    API.RegisterPrefix(Comm.PREFIX)
end)

GF:RegisterEvent("CHAT_MSG_ADDON", onAddonMessage)
GF:RegisterEvent("CHAT_MSG_ADDON_LOGGED", onAddonMessage)

GF:On("GF_LOGIN", function()
    GF:Ticker(0.25, function()
        if Comm:QueueSize() > 0 then Comm:Pump() end
        -- expire stale reassembly buffers
        local now = API.Time()
        for k, b in pairs(buffers) do
            if now - b.t > REASSEMBLY_TTL then buffers[k] = nil end
        end
    end)
    GF:After(8 + math.random() * 6, function() Comm:SendHello("GUILD") end)
    GF:Ticker(1800, function() Comm:SendHello("GUILD") end)
end)

GF:RegisterSlash("comm", function()
    local s = Comm.stats
    GF:Print("comm: sent %d, received %d, %s out, queued %d, throttled %d, dropped %d, peers online %d, deflate %s",
        s.sent, s.recv, U.Short(s.bytesOut) .. "B", Comm:QueueSize(), s.throttled, s.dropped, Comm:OnlinePeers(),
        API.CanCompress() and "on" or "off")
end, "addon-channel diagnostics")
