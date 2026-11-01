--[[ Greenfields - UI/Theme.lua
     The look: Greenfields after dark. Midnight panels under a night sky, old gold and bronze
     for the metalwork, road-sign green for what you can press, warm white for reading,
     class colours for people. ]]

local _, GF = ...

local T = {}
GF.Theme = T

local MEDIA = "Interface\\AddOns\\Greenfields\\Media\\"
T.MEDIA = MEDIA

T.tex = {
    white = "Interface\\Buttons\\WHITE8X8",
    glow = MEDIA .. "glow",
    shadow = MEDIA .. "shadow",
    noise = MEDIA .. "noise",
    hazard = MEDIA .. "hazard",
    round6 = MEDIA .. "round6",
    circle = MEDIA .. "circle",
    logo = MEDIA .. "logo",
    welcome = MEDIA .. "welcome",
    minimap = MEDIA .. "minimap",
    signGreen = MEDIA .. "sign_green",
    signYellow = MEDIA .. "sign_yellow",
    signRed = MEDIA .. "sign_red",
    signBlue = MEDIA .. "sign_blue",
    -- Warcraft chrome (tools/make_chrome.py)
    leather = MEDIA .. "leather",
    parchment = MEDIA .. "parchment",
    frameCorners = MEDIA .. "frame_corners",
    gemGreen = MEDIA .. "gem_green",
    iconFrame = MEDIA .. "icon_frame",
    iconFrameGold = MEDIA .. "icon_frame_gold",
    iconFrameWhite = MEDIA .. "icon_frame_white",
    ringMetal = MEDIA .. "ring_metal",
    shine = MEDIA .. "shine",
    toggleOn = MEDIA .. "toggle_on",
    toggleOff = MEDIA .. "toggle_off",
    knobOn = MEDIA .. "toggle_knob_on",
    knobOff = MEDIA .. "toggle_knob_off",
    barFill = MEDIA .. "bar_fill",
    windowBg = MEDIA .. "window_bg",
    circleMask = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
}

--- Icon("trophy") -> path to Media/icon_trophy.tga (white; tint with SetVertexColor)
function T.Icon(name) return MEDIA .. "icon_" .. name end

--- Double-density sliced art, cut by UI:Nine (UI/Widgets.lua). size and margin are in texels,
-- texel is UI units per texel, and outset is how far past its frame the art hangs (its shadow).
T.nine = {
    window = { path = MEDIA .. "frame_window", size = 256, margin = 64, texel = 0.5, outset = 6, hollow = true },
    card = { path = MEDIA .. "panel_card", size = 128, margin = 40, texel = 0.5, outset = 6 },
    gold = { path = MEDIA .. "panel_gold", size = 256, margin = 64, texel = 0.5, outset = 7 },
    inset = { path = MEDIA .. "panel_inset", size = 64, margin = 16, texel = 0.5, outset = 0 },
    paperEdge = { path = MEDIA .. "paper_edge", size = 64, margin = 16, texel = 0.5, outset = 1, hollow = true },
    btnGreen = { path = MEDIA .. "btn_green", size = 64, margin = 16, texel = 0.5 },
    btnDark = { path = MEDIA .. "btn_dark", size = 64, margin = 16, texel = 0.5 },
    btnRed = { path = MEDIA .. "btn_red", size = 64, margin = 16, texel = 0.5 },
    btnGold = { path = MEDIA .. "btn_gold", size = 64, margin = 16, texel = 0.5 },
    btnHl = { path = MEDIA .. "btn_hl", size = 64, margin = 16, texel = 0.5 },
    tag = { path = MEDIA .. "tag", size = 64, margin = 16, texel = 0.5 },
    pill = { path = MEDIA .. "pill", size = 64, margin = 16, texel = 0.5 },
    groove = { path = MEDIA .. "bar_track", size = 64, margin = 16, texel = 0.25 },
}

T.c = {
    bg0 = { 0.035, 0.047, 0.075, 0.98 },   -- window
    bg1 = { 0.043, 0.055, 0.082, 1 },      -- sidebar, header
    bg2 = { 0.071, 0.090, 0.125, 1 },      -- cards
    bg3 = { 0.102, 0.125, 0.165, 1 },      -- hover / inputs
    bg4 = { 0.145, 0.165, 0.212, 1 },      -- pressed / selected
    line = { 0.255, 0.216, 0.161, 1 },     -- worn bronze hairline
    lineSoft = { 0.255, 0.216, 0.161, 0.55 },
    text = { 0.957, 0.937, 0.890, 1 },     -- warm white, easy reading on midnight
    dim = { 0.745, 0.729, 0.690, 1 },
    faint = { 0.569, 0.561, 0.541, 1 },
    green = { 0.337, 0.863, 0.525, 1 },    -- lit sign green
    greenDim = { 0.337, 0.863, 0.525, 0.16 },
    sign = { 0.039, 0.478, 0.267, 1 },     -- road sign green
    yellow = { 1.000, 0.800, 0.102, 1 },
    yellowDim = { 1.000, 0.800, 0.102, 0.16 },
    red = { 1.000, 0.388, 0.361, 1 },
    redDim = { 1.000, 0.388, 0.361, 0.16 },
    pink = { 1.000, 0.333, 0.600, 1 },
    blue = { 0.439, 0.698, 1.000, 1 },
    blueDim = { 0.439, 0.698, 1.000, 0.16 },
    gold = { 1.000, 0.835, 0.353, 1 },
    wowGold = { 1.000, 0.820, 0.000, 1 },  -- the game's own heading gold
    bronze = { 0.757, 0.612, 0.396, 1 },
    purple = { 0.690, 0.310, 0.960, 1 },
    black = { 0, 0, 0, 1 },
}

T.hex = {
    green = "56dc86", yellow = "ffcc1a", red = "ff635c", pink = "ff5599", blue = "70b2ff",
    gold = "ffd55a", dim = "bebab0", faint = "918f8a", text = "f4efe3", purple = "b04ff5",
}

-- Forever's Fonts folder is archive-only; these paths are known to resolve.
-- ui = Friz Quadrata (the game's own UI face) for chrome labels and card titles;
-- title = Morpheus (quest-title face) for page titles; head = Arial Narrow for dense labels.
T.fonts = {
    body = "Fonts\\FRIZQT__.TTF",
    ui = "Fonts\\FRIZQT__.TTF",
    head = "Fonts\\ARIALN.TTF",
    num = "Fonts\\ARIALN.TTF",
    title = "Fonts\\MORPHEUS.TTF",
    fancy = "Fonts\\MORPHEUS.TTF",
}

--- Game icons for the sidebar (classic-era icon files, present in every client).
T.navArt = {
    home = "Interface\\Icons\\INV_Misc_Map_01",
    feed = "Interface\\Icons\\INV_Misc_Spyglass_03",
    raids = "Interface\\Icons\\INV_Misc_Head_Dragon_Black",
    softres = "Interface\\Icons\\INV_Misc_Coin_01",
    loot = "Interface\\Icons\\INV_Misc_Bag_10",
    attendance = "Interface\\Icons\\INV_Scroll_03",
    buffs = "Interface\\Icons\\Spell_Fire_Fire",
    roster = "Interface\\Icons\\INV_Banner_02",
    fame = "Interface\\Icons\\INV_Crown_01",
    tradies = "Interface\\Icons\\Trade_BlackSmithing",
    settings = "Interface\\Icons\\Trade_Engineering",
}

local LOCALE_FALLBACK = { koKR = true, zhCN = true, zhTW = true, ruRU = true }

--- Font(fontString, kind, size, flags): sets a font, falling back to the standard game
-- font for locales whose glyphs our faces don't carry. Never leaves a FontString fontless.
function T:Font(fs, kind, size, flags)
    local path = self.fonts[kind or "body"] or self.fonts.body
    local loc = GetLocale and GetLocale()
    if loc and LOCALE_FALLBACK[loc] and STANDARD_TEXT_FONT then path = STANDARD_TEXT_FONT end
    local ok, res = pcall(fs.SetFont, fs, path, size or 12, flags or "")
    if not ok or res == false then
        if GameFontHighlight then fs:SetFontObject(GameFontHighlight) end
    end
    if fs.SetShadowOffset then
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 0.75)
    end
end

function T:Color(name) return unpack(self.c[name] or self.c.text) end

--- "|cffxxxxxx" .. s .. "|r"
function T:Wrap(colorName, s) return "|cff" .. (self.hex[colorName] or "ffffff") .. tostring(s) .. "|r" end

--- Role metadata (custom icons from Media)
T.roles = {
    tank = { label = "Tank", icon = "shield", color = { 0.33, 0.62, 1 } },
    healer = { label = "Healer", icon = "cross", color = { 0.24, 0.86, 0.47 } },
    melee = { label = "Melee", icon = "sword", color = { 1, 0.55, 0.30 } },
    ranged = { label = "Ranged", icon = "bow", color = { 0.85, 0.55, 1 } },
}
T.roleOrder = { "tank", "healer", "melee", "ranged" }

--- Signup status metadata
T.status = {
    yes = { label = "Yeah", long = "Locked in", color = "green", icon = "check" },
    late = { label = "Late", long = "Running late", color = "yellow", icon = "clock" },
    maybe = { label = "Maybe", long = "Nah yeah... maybe", color = "blue", icon = "dot" },
    bench = { label = "Bench", long = "On the bench", color = "dim", icon = "minus" },
    no = { label = "Nah", long = "Yeah nah", color = "red", icon = "close" },
}
T.statusOrder = { "yes", "late", "maybe", "bench", "no" }
