--[[ Greenfields - UI/Theme.lua
     The look: night-time Greenfields under a green Aussie road sign. Charcoal panels,
     sign-green accents, hazard yellow for warnings, class colours for people. ]]

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
    bar = MEDIA .. "bar",
    round6 = MEDIA .. "round6",
    round6edge = MEDIA .. "round6_edge",
    round10 = MEDIA .. "round10",
    round10edge = MEDIA .. "round10_edge",
    circle = MEDIA .. "circle",
    pill = MEDIA .. "pill",
    logo = MEDIA .. "logo",
    welcome = MEDIA .. "welcome",
    minimap = MEDIA .. "minimap",
    signGreen = MEDIA .. "sign_green",
    signYellow = MEDIA .. "sign_yellow",
    signRed = MEDIA .. "sign_red",
    signBlue = MEDIA .. "sign_blue",
    -- Warcraft chrome (tools/make_chrome.py)
    stone = MEDIA .. "stone",
    leather = MEDIA .. "leather",
    parchment = MEDIA .. "parchment",
    frameGold = MEDIA .. "frame_gold",
    frameBronze = MEDIA .. "frame_bronze",
    cornerGold = MEDIA .. "corner_gold",
    dividerGold = MEDIA .. "divider_gold",
    gemGreen = MEDIA .. "gem_green",
    iconFrame = MEDIA .. "icon_frame",
    shine = MEDIA .. "shine",
    btnGreen = MEDIA .. "btn_green",
    btnDark = MEDIA .. "btn_dark",
    btnRed = MEDIA .. "btn_red",
    btnGold = MEDIA .. "btn_gold",
    circleMask = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
}

--- Icon("trophy") -> path to Media/icon_trophy.tga (white; tint with SetVertexColor)
function T.Icon(name) return MEDIA .. "icon_" .. name end

T.c = {
    bg0 = { 0.039, 0.051, 0.043, 0.97 },   -- window
    bg1 = { 0.059, 0.075, 0.065, 1 },      -- sidebar, header
    bg2 = { 0.082, 0.102, 0.090, 1 },      -- cards
    bg3 = { 0.110, 0.137, 0.122, 1 },      -- hover / inputs
    bg4 = { 0.145, 0.180, 0.160, 1 },      -- pressed / selected
    line = { 0.157, 0.200, 0.176, 1 },
    lineSoft = { 0.157, 0.200, 0.176, 0.6 },
    text = { 0.925, 0.957, 0.937, 1 },
    dim = { 0.600, 0.667, 0.627, 1 },
    faint = { 0.400, 0.455, 0.424, 1 },
    green = { 0.239, 0.859, 0.471, 1 },    -- neon sign green
    greenDim = { 0.239, 0.859, 0.471, 0.16 },
    sign = { 0.039, 0.478, 0.267, 1 },     -- road sign green
    yellow = { 1.000, 0.800, 0.000, 1 },
    yellowDim = { 1.000, 0.800, 0.000, 0.16 },
    red = { 1.000, 0.333, 0.333, 1 },
    redDim = { 1.000, 0.333, 0.333, 0.16 },
    pink = { 1.000, 0.243, 0.541, 1 },
    blue = { 0.329, 0.620, 1.000, 1 },
    blueDim = { 0.329, 0.620, 1.000, 0.16 },
    gold = { 1.000, 0.820, 0.250, 1 },
    wowGold = { 1.000, 0.820, 0.000, 1 },  -- the game's own heading gold
    bronze = { 0.588, 0.424, 0.227, 1 },
    purple = { 0.640, 0.210, 0.930, 1 },
    black = { 0, 0, 0, 1 },
}

T.hex = {
    green = "3ddb78", yellow = "ffcc00", red = "ff5555", pink = "ff3e8a", blue = "549eff",
    gold = "ffd140", dim = "99aaa0", faint = "667468", text = "ecf4ef", purple = "a335ee",
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
