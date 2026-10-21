--[[ tools/harness/wow_mock_scene.lua  --  exports for run.py / render.py.

     MOCK.ExportScene(rootOrNil) -> JSON-able table describing everything the client would
     draw right now:

       scene.screen = { w, h, origin = "top-left", yDown = true, units = "px" }
       scene.items  = draw list, ALREADY SORTED back-to-front:
                      strata (BACKGROUND < LOW < MEDIUM < HIGH < DIALOG < FULLSCREEN <
                      FULLSCREEN_DIALOG < TOOLTIP), frame level, draw layer (BACKGROUND <
                      BORDER < ARTWORK < OVERLAY; HIGHLIGHT is skipped), sublevel, creation order
       scene.frames = every visible frame (metadata: type, name, where, rect, strata, level,
                      backdrop, clips) -- not drawn, used for cropping / toast detection

     COORDINATES: screen pixels, origin at the TOP-LEFT of the 1920x1080 screen, y grows
     DOWN (PIL convention). rect = { x, y, w, h } where (x, y) is the top-left corner. All
     sizes (font sizes, shadow offsets, slice margins on screen) are already multiplied by
     the region's effective scale. WoW's own coordinates are bottom-left/y-up; the
     conversion is y = SCREEN_H - (bottom + height).

     Item kinds:
       texture  { rect, alpha, clip, tex = { file, fileID, atlas, atlasFile, atlasCoords,
                  color, vc, coords[8], gradient, rotation, slice, sliceMode, htile, vtile,
                  wrapH, wrapV, blend, desat, masks = { {file, rect} } } }
       font     { rect, alpha, clip, font = { text (raw, with |c colour codes), file, size,
                  flags, color, justifyH, justifyV, wrap, constrained, maxLines, spacing,
                  shadow = { color, offset = {x, y} } } }
       line     { p1, p2, thickness, color, alpha, clip }
     Button state textures are resolved (Normal/Pushed/Disabled/Checked); StatusBar fill
     and Slider thumb positions are applied; EditBox text becomes a font item.

     Also here: MOCK.SerializeSV (SavedVariables writer + problem detection) and
     MOCK.Report() (everything run.py puts in the per-client report). ]]

local MOCK = ...
local R = MOCK.R
local type, pairs, ipairs, tostring, tonumber = R.type, R.pairs, R.ipairs, R.tostring, R.tonumber
local floor, max, min = R.floor, R.max, R.min
local format, sub, find, gsub, rep = R.format, R.sub, R.find, R.gsub, R.rep
local concat, sort = R.concat, R.sort
local S = MOCK.S
local isSecret = MOCK.IsSecret

local SW, SH = MOCK.SCREEN_W, MOCK.SCREEN_H
local STRATA_ORDER = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6,
    FULLSCREEN_DIALOG = 7, TOOLTIP = 8, BLIZZARD = 9 }
local LAYER_ORDER = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }

local function r2(v) return floor(v * 100 + 0.5) / 100 end

--- top-left/y-down screen rect of a region (incl. animation offsets) or nil
local function screenRect(obj)
    local l, b, w, h = MOCK.ScreenRect(obj)
    if not l then return nil end
    return l, SH - (b + h), w, h
end
MOCK.SceneRect = function(obj)
    local x, y, w, h = screenRect(obj)
    if not x then return nil end
    return { r2(x), r2(y), r2(w), r2(h) }
end

local function intersect(a, b)
    if not a then return b end
    if not b then return a end
    local x1, y1 = max(a[1], b[1]), max(a[2], b[2])
    local x2, y2 = min(a[1] + a[3], b[1] + b[3]), min(a[2] + a[4], b[2] + b[4])
    return { x1, y1, max(0, x2 - x1), max(0, y2 - y1) }
end

local function colorOf(c) if not c then return nil end return { r2(c[1] or 1), r2(c[2] or 1), r2(c[3] or 1), r2(c[4] or 1) } end

local function ownerFrame(obj)
    local st = S[obj]
    if st.isFrame then return obj end
    return st.parent
end

-------------------------------------------------------------------------------
-- Export
-------------------------------------------------------------------------------
function MOCK.ExportScene(root)
    local items, frames = {}, {}
    local clipCache = {}
    local function clipOf(frame)
        if frame == nil then return nil end
        local c = clipCache[frame]
        if c ~= nil then return c or nil end
        local st = S[frame]
        local pc = st.parent and clipOf(st.parent) or nil
        local own
        if st.clips or st.otype == "ScrollFrame" then
            local x, y, w, h = screenRect(frame)
            if x then own = { x, y, w, h } end
        end
        local res = intersect(pc, own)
        clipCache[frame] = res or false
        return res
    end
    local function underRoot(obj)
        if not root then return true end
        local o = obj
        while o do
            if o == root then return true end
            o = S[o] and S[o].parent
        end
        return false
    end
    local function base(obj, st, owner, kind)
        local ost = owner and S[owner]
        local x, y, w, h = screenRect(obj)
        if not x then return nil end
        local e = {
            kind = kind, id = st.id, name = st.name, rect = { r2(x), r2(y), r2(w), r2(h) },
            alpha = r2(MOCK.EffectiveAlpha(obj)),
            strata = owner and MOCK.StrataOf(owner) or "MEDIUM",
            level = owner and MOCK.LevelOf(owner) or 0,
            layer = st.layer or "ARTWORK", sublevel = st.sublevel or 0,
            frame = ost and ost.id or 0,
        }
        local c = owner and clipOf(owner)
        if c then e.clip = { r2(c[1]), r2(c[2]), r2(c[3]), r2(c[4]) } end
        if st.fx and st.fx.vc then e.fxvc = colorOf(st.fx.vc) end
        return e
    end

    local function buttonSkip(st, owner)
        local slot = st.buttonSlot
        if not slot or not owner then return false end
        local ost = S[owner]
        if slot == "HighlightTexture" then return true end
        local function has(s2) return ost[s2] and S[ost[s2]] and (S[ost[s2]].tex.file or S[ost[s2]].tex.atlas) end
        local disabled = ost.enabled == false
        local pushed = ost.buttonState == "PUSHED"
        if slot == "PushedTexture" then return not pushed or disabled end
        if slot == "DisabledTexture" then return not disabled end
        if slot == "NormalTexture" then
            if disabled and has("DisabledTexture") then return true end
            if pushed and has("PushedTexture") then return true end
            return false
        end
        if slot == "CheckedTexture" then return not ost.checked end
        if slot == "DisabledCheckedTexture" then return not (ost.checked and disabled) end
        return false
    end

    local function textureItem(obj, st, owner)
        if st.layer == "HIGHLIGHT" then return nil end
        if buttonSkip(st, owner) then return nil end
        local tx = st.tex
        if tx.file == nil and tx.atlas == nil and tx.color == nil then return nil end
        if tx.file == "" and not tx.atlas then return nil end
        local e = base(obj, st, owner, "texture")
        if not e then return nil end
        local t = {}
        if type(tx.file) == "number" then t.fileID = tx.file
        elseif type(tx.file) == "string" then t.file = tx.file end
        if tx.atlas then
            t.atlas = tx.atlas
            local a = MOCK.atlases[tx.atlas] or MOCK.atlases[R.lower(tx.atlas)]
            if a then
                t.atlasFile = a.filename or a.file
                t.atlasCoords = { a.leftTexCoord, a.rightTexCoord, a.topTexCoord, a.bottomTexCoord }
            end
        end
        t.color = colorOf(tx.color)
        t.vc = colorOf(st.vc)
        if e.fxvc then t.vc = e.fxvc end
        if tx.coords then
            local c = {}
            for i = 1, 8 do c[i] = tx.coords[i] end
            t.coords = c
        end
        if tx.gradient then
            t.gradient = { orientation = tx.gradient[1], min = colorOf(tx.gradient[2]), max = colorOf(tx.gradient[3]) }
        end
        if tx.rotation and tx.rotation ~= 0 then t.rotation = tx.rotation end
        if tx.slice then
            local s = MOCK.EffectiveScale(obj)
            t.slice = { tx.slice[1], tx.slice[2], tx.slice[3], tx.slice[4] }
            t.sliceScale = s
            t.sliceMode = tx.sliceMode or 0
        end
        t.htile = tx.htile or nil
        t.vtile = tx.vtile or nil
        t.wrapH = tx.wrapH
        t.wrapV = tx.wrapV
        t.blend = tx.blend
        if (tx.desat or 0) > 0 then t.desat = tx.desat end
        if st.masks then
            local m = {}
            for _, mask in ipairs(st.masks) do
                local mst = S[mask]
                local mx, my, mw, mh = screenRect(mask)
                if mx and MOCK.IsVisible(mask) then
                    m[#m + 1] = { file = mst.tex.file, rect = { r2(mx), r2(my), r2(mw), r2(mh) } }
                end
            end
            if #m > 0 then t.masks = m end
        end
        -- StatusBar fill
        if st.statusBar and S[st.statusBar] then
            local bst = S[st.statusBar]
            local lo, hi, v = bst.minV or 0, bst.maxV or 1, bst.value or 0
            local frac = hi > lo and max(0, min(1, (v - lo) / (hi - lo))) or 0
            local rct = e.rect
            if (bst.orientation or "HORIZONTAL") == "VERTICAL" then
                local nh = rct[4] * frac
                rct[2] = rct[2] + (rct[4] - nh)
                rct[4] = r2(nh)
                t.coords = { 0, 1 - frac, 0, 1, 1, 1 - frac, 1, 1 }
            else
                local nw = rct[3] * frac
                if bst.reverseFill then rct[1] = rct[1] + (rct[3] - nw) end
                rct[3] = r2(nw)
                t.coords = bst.reverseFill and { 1 - frac, 0, 1 - frac, 1, 1, 0, 1, 1 } or { 0, 0, 0, 1, frac, 0, frac, 1 }
            end
            if frac <= 0 then return nil end
        end
        -- Slider thumb
        if st.buttonSlot == "ThumbTexture" and owner and S[owner].otype == "Slider" then
            local sst = S[owner]
            local sx, sy, sw, sh = screenRect(owner)
            if not sx then return nil end
            local s = MOCK.EffectiveScale(obj)
            local tw, th = (st.width or 16) * s, (st.height or 16) * s
            local lo, hi, v = sst.minV or 0, sst.maxV or 0, sst.value or 0
            local frac = hi > lo and max(0, min(1, (v - lo) / (hi - lo))) or 0
            if (sst.orientation or "HORIZONTAL") == "VERTICAL" then
                e.rect = { r2(sx + (sw - tw) / 2), r2(sy + frac * (sh - th)), r2(tw), r2(th) }
            else
                e.rect = { r2(sx + frac * (sw - tw)), r2(sy + (sh - th) / 2), r2(tw), r2(th) }
            end
        end
        if e.rect[3] <= 0 or e.rect[4] <= 0 then return nil end
        e.tex = t
        return e
    end

    local function lineItem(obj, st, owner)
        local ln = st.line
        if not (ln and ln.Start and ln.End) then return nil end
        local function pt(p)
            local rel = p.rel or st.parent
            local x, y, w, h = screenRect(rel)
            if not x then return nil end
            local f = MOCK.POINTS[p.point]
            local s = MOCK.EffectiveScale(obj)
            return { r2(x + w * f[1] + p.x * s), r2(y + h * (1 - f[2]) - p.y * s) }
        end
        local p1, p2 = pt(ln.Start), pt(ln.End)
        if not (p1 and p2) then return nil end
        local ost = owner and S[owner]
        local tx = st.tex
        local color = tx.color or { 1, 1, 1, 1 }
        local vc = st.vc or { 1, 1, 1, 1 }
        local e = {
            kind = "line", id = st.id, p1 = p1, p2 = p2, thickness = r2((st.thickness or 1) * MOCK.EffectiveScale(obj)),
            color = { r2(color[1] * vc[1]), r2(color[2] * vc[2]), r2(color[3] * vc[3]), r2((color[4] or 1) * (vc[4] or 1)) },
            alpha = r2(MOCK.EffectiveAlpha(obj)), strata = owner and MOCK.StrataOf(owner) or "MEDIUM",
            level = owner and MOCK.LevelOf(owner) or 0, layer = st.layer or "ARTWORK", sublevel = st.sublevel or 0,
            frame = ost and ost.id or 0,
        }
        local c = owner and clipOf(owner)
        if c then e.clip = { r2(c[1]), r2(c[2]), r2(c[3]), r2(c[4]) } end
        return e
    end

    local function fontInfo(st, obj, textOverride)
        local path, size, flags = MOCK.FontOf(st)
        if not path then return nil end
        local text = textOverride or st.text
        if text == nil then return nil end
        if isSecret(text) then text = "<secret>" end
        if type(text) ~= "string" then text = tostring(text) end
        if text == "" then return nil end
        local s = MOCK.EffectiveScale(obj)
        local tc = MOCK.ResolveFontField(st, "textColor") or { 1, 1, 1, 1 }
        local sc = MOCK.ResolveFontField(st, "shadowColor") or { 0, 0, 0, 1 }
        local so = MOCK.ResolveFontField(st, "shadowOffset") or { 0, 0 }
        local f = {
            text = text, file = path, size = r2(size * (st.textScale or 1) * s), flags = flags or "",
            color = colorOf(tc), justifyH = MOCK.ResolveFontField(st, "justifyH") or "CENTER",
            justifyV = MOCK.ResolveFontField(st, "justifyV") or "MIDDLE",
            wrap = st.wordWrap ~= false, nonSpaceWrap = st.nonSpaceWrap or nil,
            maxLines = (st.maxLines and st.maxLines > 0) and st.maxLines or nil,
            spacing = r2((MOCK.ResolveFontField(st, "spacing") or 0) * s),
        }
        if (so[1] ~= 0 or so[2] ~= 0) and (sc[4] or 1) > 0 then
            f.shadow = { color = colorOf(sc), offset = { r2(so[1] * s), r2(so[2] * s) } }
        end
        return f
    end

    local function fontItem(obj, st, owner)
        if st.layer == "HIGHLIGHT" then return nil end
        local f = fontInfo(st, obj)
        if not f then return nil end
        -- button fonts follow the button state
        if owner and S[owner].isButton and S[owner].FontString == obj then
            local ost = S[owner]
            if ost.enabled == false and ost.disabledFont then
                local c = MOCK.ResolveFontField(S[ost.disabledFont], "textColor")
                if c then f.color = colorOf(c) end
            end
        end
        local e = base(obj, st, owner, "font")
        if not e then return nil end
        f.constrained = MOCK.ConstrainedWidth(obj, st) ~= nil
        e.font = f
        if e.rect[3] <= 0 and e.rect[4] <= 0 then return nil end
        return e
    end

    local function editBoxItem(obj, st)
        if not st.text or st.text == "" then return nil end
        local text = st.text
        if isSecret(text) then text = "<secret>" end
        if st.password then text = rep("*", MOCK.utf8len(text)) end
        local f = fontInfo(st, obj, text)
        if not f then return nil end
        local x, y, w, h = screenRect(obj)
        if not x then return nil end
        local s = MOCK.EffectiveScale(obj)
        local ins = st.insets or { 0, 0, 0, 0 }
        local rx, ry = x + ins[1] * s, y + ins[3] * s
        local rw, rh = max(0, w - (ins[1] + ins[2]) * s), max(0, h - (ins[3] + ins[4]) * s)
        f.justifyH = st.justifyH or "LEFT"
        f.justifyV = st.multiLine and "TOP" or (st.justifyV or "MIDDLE")
        f.wrap = st.multiLine and true or false
        f.constrained = true
        local e = {
            kind = "font", id = st.id, rect = { r2(rx), r2(ry), r2(rw), r2(rh) }, alpha = r2(MOCK.EffectiveAlpha(obj)),
            strata = MOCK.StrataOf(obj), level = MOCK.LevelOf(obj), layer = "OVERLAY", sublevel = 7, frame = st.id,
            font = f, editBox = true,
        }
        local c = clipOf(obj)
        if c then e.clip = { r2(c[1]), r2(c[2]), r2(c[3]), r2(c[4]) } end
        return e
    end

    for _, obj in ipairs(MOCK.objects) do
        local st = S[obj]
        if st and st.isRegionLike and not st.isScreenRoot and underRoot(obj) and MOCK.IsVisible(obj) then
            local owner = ownerFrame(obj)
            local item
            if st.isFrame then
                local x, y, w, h = screenRect(obj)
                if x then
                    local fr = {
                        id = st.id, type = st.otype, name = st.name, where = st.where, rect = { r2(x), r2(y), r2(w), r2(h) },
                        strata = MOCK.StrataOf(obj), level = MOCK.LevelOf(obj), alpha = r2(MOCK.EffectiveAlpha(obj)),
                        parent = st.parent and S[st.parent].id or 0, clips = st.clips or nil, mouse = st.mouse or nil,
                    }
                    local bi = R.rawget(obj, "backdropInfo")
                    if type(bi) == "table" then
                        local center, edge = R.rawget(obj, "Center"), R.rawget(obj, "TopEdge")
                        fr.backdrop = {
                            bgFile = bi.bgFile, edgeFile = bi.edgeFile, edgeSize = bi.edgeSize,
                            bg = center and S[center] and colorOf(S[center].vc) or nil,
                            edge = edge and S[edge] and colorOf(S[edge].vc) or nil,
                        }
                    end
                    frames[#frames + 1] = fr
                    if st.isEditBox then item = editBoxItem(obj, st) end
                end
            elseif st.isMask then
                item = nil
            elseif st.isLine then
                item = lineItem(obj, st, owner)
            elseif st.isFontString then
                item = fontItem(obj, st, owner)
            elseif st.tex then
                item = textureItem(obj, st, owner)
            end
            if item and item.alpha > 0.003 then items[#items + 1] = item end
        end
    end

    sort(items, function(a, b)
        local sa, sb = STRATA_ORDER[a.strata] or 3, STRATA_ORDER[b.strata] or 3
        if sa ~= sb then return sa < sb end
        if a.level ~= b.level then return a.level < b.level end
        local la, lb = LAYER_ORDER[a.layer] or 3, LAYER_ORDER[b.layer] or 3
        if la ~= lb then return la < lb end
        if a.sublevel ~= b.sublevel then return a.sublevel < b.sublevel end
        return a.id < b.id
    end)
    for i, it in ipairs(items) do it.z = i end
    return {
        screen = { w = SW, h = SH, origin = "top-left", yDown = true, units = "px" },
        time = MOCK.uptime, client = MOCK.clientName,
        items = MOCK.Array(items), frames = MOCK.Array(frames),
    }
end

-------------------------------------------------------------------------------
-- SavedVariables writer (the client's format) + problems it would hit
-------------------------------------------------------------------------------
local function svKey(k)
    if type(k) == "string" then return format("[%q]", k) end
    return "[" .. tostring(k) .. "]"
end
function MOCK.SerializeSV(name, value)
    local out, problems, seen = {}, {}, {}
    local function problem(path, what)
        if #problems < 60 then problems[#problems + 1] = path .. ": " .. what end
    end
    local function val(v, path, indent)
        local t = R.type(v)
        if t == "string" then out[#out + 1] = format("%q", v)
        elseif t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then problem(path, "non-finite number"); out[#out + 1] = "0"
            elseif v == floor(v) and v > -1e15 and v < 1e15 then out[#out + 1] = format("%d", v)
            else out[#out + 1] = format("%.17g", v) end
        elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
        elseif t == "table" then
            if seen[v] then problem(path, "table appears twice (shared/recursive reference)"); out[#out + 1] = "nil" return end
            seen[v] = true
            if R.getmetatable(v) ~= nil and S[v] then problem(path, "a widget/frame is stored in SavedVariables") end
            out[#out + 1] = "{\n"
            local keys = {}
            for k in R.pairs(v) do keys[#keys + 1] = k end
            sort(keys, function(a, b)
                local ta, tb = R.type(a), R.type(b)
                if ta ~= tb then return ta < tb end
                if ta == "number" or ta == "string" then return a < b end
                return R.tostring(a) < R.tostring(b)
            end)
            for _, k in ipairs(keys) do
                local kt = R.type(k)
                if kt ~= "string" and kt ~= "number" and kt ~= "boolean" then
                    problem(path, "key of type " .. (isSecret(k) and "secret" or kt) .. " is dropped")
                else
                    out[#out + 1] = indent .. "\t" .. svKey(k) .. " = "
                    val(R.rawget(v, k), path .. "." .. tostring(k), indent .. "\t")
                    out[#out + 1] = ",\n"
                end
            end
            out[#out + 1] = indent .. "}"
        elseif t == "nil" then out[#out + 1] = "nil"
        else
            problem(path, (isSecret(v) and "secret value" or t) .. " cannot be saved")
            out[#out + 1] = "nil"
        end
    end
    out[#out + 1] = name .. " = "
    val(value, name, "")
    out[#out + 1] = "\n"
    return concat(out), problems
end

--- Resolves the rect of every visible region and records the ones whose anchors invert
-- the rect (negative width/height; e.g. TOPLEFT + RIGHT pins the vertical centre, so a
-- region anchored below a sibling ends up with its bottom above its top). Only settled
-- layouts are checked (run.py calls this after a page has been shown for a second).
function MOCK.CheckLayout()
    local n = 0
    for _, obj in ipairs(MOCK.objects) do
        local st = S[obj]
        if st and st.isRegionLike and not st.isScreenRoot and MOCK.IsVisible(obj) then
            local l, b, w, h = MOCK.RectOf(obj)
            n = n + 1
            if l and (w < -0.5 or h < -0.5) and not MOCK.layoutIssues[obj] and MOCK.EffectiveAlpha(obj) > 0.01 then
                local desc = {}
                for _, p in ipairs(st.points or {}) do desc[#desc + 1] = p.point .. "->" .. p.relPoint end
                MOCK.layoutIssues[obj] = { id = st.id, where = st.where or "?", w = w, h = h, otype = st.otype,
                    anchors = concat(desc, ","), anchoredAt = st.anchoredAt, scenario = MOCK.scenario,
                    text = st.isFontString and type(st.text) == "string" and sub(st.text, 1, 60) or nil }
            end
            -- Text overflow: an unbounded FontString whose text runs past its parent frame
            -- (WoW only truncates text that has a width; unbounded text just spills out).
            if l and w >= 0 and st.isFontString and type(st.text) == "string" and st.text ~= ""
                and not MOCK.layoutIssues[obj] and MOCK.EffectiveAlpha(obj) > 0.01
                and not MOCK.ConstrainedWidth(obj, st) and st.parent and S[st.parent] then
                local pl, _, pw = MOCK.RectOf(st.parent)
                local tw = obj:GetUnboundedStringWidth()
                if pl and pw and pw >= 24 and tw > 0 then
                    local over = (l + tw) - (pl + pw)
                    local rightAnchored = false
                    for _, p in ipairs(st.points or {}) do if find(p.point, "RIGHT", 1, true) then rightAnchored = true end end
                    -- text that grows rightwards and ends within 3px of the edge clips on a real
                    -- client (its fonts run wider than our stand-ins); right-anchored text ends
                    -- at its anchor by construction, so only a real spill counts there
                    if (not rightAnchored and over > -3) or over > 2 or l < pl - 2 then
                        local desc = {}
                        for _, p in ipairs(st.points or {}) do desc[#desc + 1] = p.point .. "->" .. p.relPoint end
                        MOCK.layoutIssues[obj] = { id = st.id, where = st.where or "?", w = tw, h = h, otype = "FontString",
                            anchors = concat(desc, ","), anchoredAt = st.anchoredAt, scenario = MOCK.scenario,
                            overflow = floor(over + 0.5), parentW = floor(pw + 0.5), text = sub(st.text, 1, 60) }
                    end
                end
            end
        end
    end
    return n
end

-------------------------------------------------------------------------------
-- Per-client report
-------------------------------------------------------------------------------
local function sortedMap(map, fields)
    local keys = {}
    for k in pairs(map) do keys[#keys + 1] = k end
    sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
        local v = map[k]
        local e = { name = k }
        if type(v) == "table" then for _, f in ipairs(fields) do e[f] = v[f] end else e.where = v end
        out[#out + 1] = e
    end
    return MOCK.Array(out)
end

function MOCK.Report()
    local GF = R.rawget(_G, "Greenfields")
    local named = {}
    for _, obj in ipairs(MOCK.objects) do
        local st = S[obj]
        if st and st.name and type(st.where) == "string" and find(st.where, "^Greenfields/") then
            named[#named + 1] = { name = st.name, type = st.otype, where = st.where,
                                  allowed = sub(st.name, 1, 11) == "Greenfields" }
        end
    end
    local sv = {}
    for _, n in ipairs({ "GreenfieldsDB", "GreenfieldsCharDB" }) do
        local v = R.rawget(_G, n)
        local text, problems = MOCK.SerializeSV(n, v)
        sv[n] = { bytes = #text, problems = MOCK.Array(problems) }
    end
    local addonErrors = {}
    if type(GF) == "table" and type(GF.errors) == "table" then
        for _, e in ipairs(GF.errors) do
            addonErrors[#addonErrors + 1] = { label = tostring(e.label), err = isSecret(e.err) and "<secret>" or tostring(e.err), time = e.time }
        end
    end
    local sounds = {}
    for k, v in pairs(MOCK.sounds or {}) do sounds[#sounds + 1] = { id = tostring(k), count = v } end
    sort(sounds, function(a, b) return a.id < b.id end)
    local events = {}
    for k, v in pairs(MOCK.eventsFired) do events[#events + 1] = { event = k, count = v } end
    sort(events, function(a, b) return a.event < b.event end)
    local registered = {}
    for ev, list in pairs(MOCK.eventReg) do if #list > 0 then registered[#registered + 1] = ev end end
    sort(registered)
    local peakBy = {}
    for where, n in pairs(MOCK.peakTimers or {}) do peakBy[#peakBy + 1] = { where = where, live = n } end
    sort(peakBy, function(a, b) if a.live ~= b.live then return a.live > b.live end return a.where < b.where end)
    peakBy = MOCK.Array(peakBy)
    local layout, lkeys = {}, {}
    local recs = {}
    for _, rec in pairs(MOCK.layoutIssues or {}) do recs[#recs + 1] = rec end
    sort(recs, function(a, b) return a.id < b.id end)      -- deterministic (the table is keyed by object)
    for _, rec in ipairs(recs) do
        local k = tostring(rec.anchoredAt or rec.where) .. "|" .. tostring(rec.anchors)
        local e = layout[k]
        if not e then
            e = { where = rec.where, anchoredAt = rec.anchoredAt, anchors = rec.anchors, otype = rec.otype, w = r2(rec.w),
                  h = r2(rec.h), count = 0, scenario = rec.scenario, text = rec.text, overflow = rec.overflow, parentW = rec.parentW }
            layout[k] = e
            lkeys[#lkeys + 1] = k
        end
        e.count = e.count + 1
    end
    sort(lkeys)
    local layoutList = {}
    for _, k in ipairs(lkeys) do layoutList[#layoutList + 1] = layout[k] end
    return {
        client = MOCK.clientName,
        errors = MOCK.Array(MOCK.errors), warnings = MOCK.Array(MOCK.warnings),
        addonErrors = MOCK.Array(addonErrors),
        globalReads = sortedMap(MOCK.globalReads, { "count", "where", "trace", "scenario" }),
        rawgetMisses = sortedMap(MOCK.rawgetMisses, { "count", "where", "scenario" }),
        globalWrites = sortedMap(MOCK.globalWrites, { "count", "where", "allowed", "scenario" }),
        mockGlobalReads = sortedMap(MOCK.mockGlobalReads, {}),
        namedGlobals = MOCK.Array(named),
        unknownEvents = sortedMap(MOCK.unknownEvents, { "count", "where" }),
        forbidden = MOCK.Array(MOCK.forbidden), taint = MOCK.Array(MOCK.taint),
        chatLog = MOCK.Array(MOCK.chatLog), prints = MOCK.Array(MOCK.printLog),
        sounds = MOCK.Array(sounds), eventsFired = MOCK.Array(events), registeredEvents = MOCK.Array(registered),
        timers = { live = MOCK.liveTimers, max = MOCK.maxLiveTimers, peakAt = MOCK.peakTimersAt, peakBy = peakBy },
        commStats = MOCK.commStats, sv = sv, objects = #MOCK.objects, layoutIssues = MOCK.Array(layoutList),
    }
end
