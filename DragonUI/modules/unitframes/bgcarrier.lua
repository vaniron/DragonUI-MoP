--[[
  DragonUI - Battleground Carrier Frames (bgcarrier.lua)

  MoP 5.4.8 reuses the native ArenaEnemyFrame1-5 (unit tokens arena1..arena5) to
  show battleground flag/orb/cart carriers. Those frames live in the lazy-loaded
  Blizzard_ArenaUI addon and their subframe layout differs from the boss frames,
  so reskinning them from boss.lua never worked.

  This module hides the native frames (showArenaEnemyFrames CVar) and draws its
  own compact enemy bars driven by arena1..arena5 + ARENA_OPPONENT_UPDATE. It only
  shows in battlegrounds (instanceType == "pvp"), not in arenas.

  Config: addon.db.profile.unitframe.bgcarrier
]]

local _, addon = ...
local L = addon.L
local UF = addon.UF
if not UF then return end

local Module = UF.CreateModule("bgcarrier")
Module.carrierFrames = {}
Module.configured = false
Module.nativeHidden = false

if addon.RegisterModule then
    addon:RegisterModule("bgcarrier", Module,
        L["Battleground Carriers"],
        L["Enemy battleground flag/orb/cart carrier frames"])
end

local TEXTURES = UF.TEXTURES.targetStyle
local PORTRAIT_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local NUM_CARRIERS = 5
local FRAME_WIDTH = 232
local FRAME_HEIGHT = 75
local FRAME_SPACING = 2

-- Faction-colored name-background gradient (same texture + texcoords as the
-- target frame): green for allies, red for enemies, yellow for neutral.
local NAME_BG_PTR_TEXTURE = "Interface\\AddOns\\DragonUI\\Textures\\UnitFrames\\Target\\UIUnitFrame2x_PTR"
local NAME_BG_TEX_COORDS = {
    green = { 536 / 1024, 804 / 1024, 135 / 512, 166 / 512 },
    red   = { 536 / 1024, 804 / 1024, 168 / 512, 199 / 512 },
    yellow = { 266 / 1024, 534 / 1024, 201 / 512, 232 / 512 },
}
local NAME_BG_COLOR_PALETTE = {
    green = { 0.0, 1.0, 0.0 },
    red   = { 1.0, 0.0, 0.0 },
    yellow = { 1.0, 1.0, 0.0 },
}

local function ResolveNameBackgroundColorKey(r, g, b)
    if not r or not g or not b then
        return "yellow"
    end

    local bestKey, bestDist = "yellow", 10
    for key, p in pairs(NAME_BG_COLOR_PALETTE) do
        local dr = r - p[1]
        local dg = g - p[2]
        local db = b - p[3]
        local dist = dr * dr + dg * dg + db * db
        if dist < bestDist then
            bestDist = dist
            bestKey = key
        end
    end

    return bestKey
end

-- Common MoP PvP crowd-control / loss-of-control spell IDs (matched against
-- the spellId returned by UnitAura on the carrier's debuffs).
-- Extended with the LoseControl spell list (CC, Silence, Disarm and Root).
local CC_SPELLS = {
    -- Death Knight
    [108194] = true,   -- Asphyxiate
    [115001] = true,   -- Remorseless Winter (stun)
    [47476] = true,    -- Strangulate (silence)
    [96294] = true,    -- Chains of Ice - Chilblains (root)
    [91800] = true,    -- Gnaw (ghoul)
    [91797] = true,    -- Monstrous Blow (Dark Transformation)
    [91807] = true,    -- Shambling Rush (root)
    -- Druid
    [113801] = true,   -- Bash (Force of Nature treants)
    [102795] = true,   -- Bear Hug
    [33786] = true,    -- Cyclone
    [99] = true,       -- Disorienting Roar
    [2637] = true,     -- Hibernate
    [22570] = true,    -- Maim
    [5211] = true,     -- Mighty Bash
    [9005] = true,     -- Pounce
    [102546] = true,   -- Pounce (Incarnation)
    [114238] = true,   -- Fae Silence
    [81261] = true,    -- Solar Beam (silence)
    [78675] = true,    -- Solar Beam (silence)
    [339] = true,      -- Entangling Roots
    [113770] = true,   -- Entangling Roots (Balance treants)
    [19975] = true,    -- Entangling Roots (Nature's Grasp)
    [45334] = true,    -- Immobilized (Wild Charge - Bear)
    [102359] = true,   -- Mass Entanglement
    -- Druid Symbiosis
    [110698] = true,   -- Hammer of Justice (symbiosis)
    [113004] = true,   -- Intimidating Roar [Fleeing] (symbiosis)
    [113056] = true,   -- Intimidating Roar [Cowering] (symbiosis)
    [126458] = true,   -- Grapple Weapon (disarm, symbiosis)
    [110693] = true,   -- Frost Nova (root, symbiosis)
    -- Hunter
    [117526] = true,   -- Binding Shot
    [3355] = true,     -- Freezing Trap
    [1513] = true,     -- Scare Beast
    [19503] = true,    -- Scatter Shot
    [19386] = true,    -- Wyvern Sting
    [34490] = true,    -- Silencing Shot
    [19185] = true,    -- Entrapment (root)
    [64803] = true,    -- Entrapment (root)
    [128405] = true,   -- Narrow Escape (root)
    -- Hunter Pets
    [90337] = true,    -- Bad Manner (Monkey)
    [24394] = true,    -- Intimidation
    [126246] = true,   -- Lullaby (Crane)
    [126355] = true,   -- Paralyzing Quill (Porcupine)
    [126423] = true,   -- Petrifying Gaze (Basilisk)
    [50519] = true,    -- Sonic Blast (Bat)
    [56626] = true,    -- Sting (Wasp)
    [96201] = true,    -- Web Wrap (Shale Spider)
    [50541] = true,    -- Clench (disarm, Scorpid)
    [91644] = true,    -- Snatch (disarm, Bird of Prey)
    [90327] = true,    -- Lock Jaw (root, Dog)
    [50245] = true,    -- Pin (root, Crab)
    [54706] = true,    -- Venom Web Spray (root, Silithid)
    [4167] = true,     -- Web (root, Spider)
    -- Mage
    [118271] = true,   -- Combustion Impact
    [44572] = true,    -- Deep Freeze
    [31661] = true,    -- Dragon's Breath
    [118] = true,      -- Polymorph
    [61305] = true,    -- Polymorph: Black Cat
    [28272] = true,    -- Polymorph: Pig
    [61721] = true,    -- Polymorph: Rabbit
    [61780] = true,    -- Polymorph: Turkey
    [28271] = true,    -- Polymorph: Turtle
    [82691] = true,    -- Ring of Frost
    [102051] = true,   -- Frostjaw (silence)
    [55021] = true,    -- Silenced - Improved Counterspell
    [122] = true,      -- Frost Nova (root)
    [111340] = true,   -- Ice Ward (root)
    -- Mage Water Elemental
    [33395] = true,    -- Freeze (root)
    -- Monk
    [123393] = true,   -- Breath of Fire (Glyph of Breath of Fire)
    [126451] = true,   -- Clash
    [122242] = true,   -- Clash
    [119392] = true,   -- Charging Ox Wave
    [120086] = true,   -- Fists of Fury
    [119381] = true,   -- Leg Sweep
    [115078] = true,   -- Paralysis
    [117368] = true,   -- Grapple Weapon (disarm)
    [140023] = true,   -- Ring of Peace (disarm)
    [137461] = true,   -- Disarmed (Ring of Peace)
    [137460] = true,   -- Silenced (Ring of Peace)
    [116709] = true,   -- Spear Hand Strike (silence)
    [116706] = true,   -- Disable (root)
    [113275] = true,   -- Entangling Roots (symbiosis, root)
    [123407] = true,   -- Spinning Fire Blossom (root)
    -- Paladin
    [105421] = true,   -- Blinding Light
    [115752] = true,   -- Blinding Light (Glyph of Blinding Light)
    [105593] = true,   -- Fist of Justice
    [853] = true,      -- Hammer of Justice
    [119072] = true,   -- Holy Wrath
    [20066] = true,    -- Repentance
    [10326] = true,    -- Turn Evil
    [145067] = true,   -- Turn Evil (Evil is a Point of View)
    [31935] = true,    -- Avenger's Shield (silence)
    -- Priest
    [113506] = true,   -- Cyclone (symbiosis)
    [605] = true,      -- Dominate Mind
    [88625] = true,    -- Holy Word: Chastise
    [64044] = true,    -- Psychic Horror
    [8122] = true,     -- Psychic Scream
    [113792] = true,   -- Psychic Terror (Psyfiend)
    [9484] = true,     -- Shackle Undead
    [87204] = true,    -- Sin and Punishment
    [15487] = true,    -- Silence
    [64058] = true,    -- Psychic Horror (disarm)
    [87194] = true,    -- Glyph of Mind Blast (root)
    [114404] = true,   -- Void Tendril's Grasp (root)
    -- Rogue
    [2094] = true,     -- Blind
    [1833] = true,     -- Cheap Shot
    [1776] = true,     -- Gouge
    [408] = true,      -- Kidney Shot
    [113953] = true,   -- Paralysis (Paralytic Poison)
    [6770] = true,     -- Sap
    [1330] = true,     -- Garrote - Silence
    [51722] = true,    -- Dismantle
    [115197] = true,   -- Partial Paralysis (root)
    -- Shaman
    [76780] = true,    -- Bind Elemental
    [77505] = true,    -- Earthquake
    [51514] = true,    -- Hex
    [118905] = true,   -- Static Charge (Capacitor Totem)
    [113287] = true,   -- Solar Beam (symbiosis, silence)
    [64695] = true,    -- Earthgrab (root)
    [63685] = true,    -- Freeze (Frozen Power, root)
    [118345] = true,   -- Pulverize (Primal Earth Elemental)
    -- Warlock
    [710] = true,      -- Banish
    [137143] = true,   -- Blood Horror
    [54786] = true,    -- Demonic Leap (Metamorphosis)
    [5782] = true,     -- Fear
    [118699] = true,   -- Fear
    [130616] = true,   -- Fear (Glyph of Fear)
    [5484] = true,     -- Howl of Terror
    [22703] = true,    -- Infernal Awakening
    [6789] = true,     -- Mortal Coil
    [132412] = true,   -- Seduction (Grimoire of Sacrifice)
    [30283] = true,    -- Shadowfury
    [104045] = true,   -- Sleep (Metamorphosis)
    [132409] = true,   -- Spell Lock (Grimoire of Sacrifice, silence)
    [31117] = true,    -- Unstable Affliction (silence)
    -- Warlock Pets
    [89766] = true,    -- Axe Toss (Felguard/Wrathguard)
    [115268] = true,   -- Mesmerize (Shivarra)
    [6358] = true,     -- Seduction (Succubus)
    [115782] = true,   -- Optical Blast (Observer, silence)
    [24259] = true,    -- Spell Lock (Felhunter, silence)
    [118093] = true,   -- Disarm (Voidwalker/Voidlord)
    -- Warrior
    [7922] = true,     -- Charge Stun
    [118895] = true,   -- Dragon Roar
    [5246] = true,     -- Intimidating Shout (aoe)
    [20511] = true,    -- Intimidating Shout (targeted)
    [46968] = true,    -- Shockwave
    [132168] = true,   -- Shockwave
    [107570] = true,   -- Storm Bolt
    [132169] = true,   -- Storm Bolt
    [18498] = true,    -- Silenced - Gag Order
    [676] = true,      -- Disarm
    [107566] = true,   -- Staggering Shout (root)
    [105771] = true,   -- Warbringer (root)
    -- Other / racials / items
    [30217] = true,    -- Adamantite Grenade
    [67769] = true,    -- Cobalt Frag Bomb
    [30216] = true,    -- Fel Iron Bomb
    [107079] = true,   -- Quaking Palm
    [13327] = true,    -- Reckless Charge
    [20549] = true,    -- War Stomp
    [25046] = true,    -- Arcane Torrent (Energy, silence)
    [28730] = true,    -- Arcane Torrent (Mana, silence)
    [50613] = true,    -- Arcane Torrent (Runic Power, silence)
    [69179] = true,    -- Arcane Torrent (Rage, silence)
    [80483] = true,    -- Arcane Torrent (Focus, silence)
    [129597] = true,   -- Arcane Torrent (Chi, silence)
    [39965] = true,    -- Frost Grenade (root)
    [55536] = true,    -- Frostweave Net (root)
    [13099] = true,    -- Net-o-Matic (root)
}

local function GetConfig()
    return UF.GetConfig("bgcarrier")
end

local function IsEnabled()
    return UF.IsEnabled("bgcarrier")
end

local function IsBattleground()
    local _, instanceType = IsInInstance()
    return instanceType == "pvp"
end

-- ============================================================================
-- STATUS BAR (manual fill: full-size gradient cropped via texcoord)
-- ============================================================================

local function CreateStatusBar(parent, texturePath)
    local bar = CreateFrame("Frame", nil, parent)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetTexture(0, 0, 0, 0.5)

    local fill = bar:CreateTexture(nil, "ARTWORK")
    -- Anchor left/top/bottom only (never RIGHT) so SetWidth can shrink the fill.
    fill:SetPoint("LEFT", bar, "LEFT", 0, 0)
    fill:SetPoint("TOP", bar, "TOP", 0, 0)
    fill:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
    fill:SetTexture(texturePath)
    fill:SetVertexColor(1, 1, 1, 1)

    bar.fill = fill

    bar.SetValue = function(self, value, max)
        if max and max > 0 and value then
            local frac = value / max
            if frac < 0 then frac = 0 end
            if frac > 1 then frac = 1 end
            -- Crop the source texture and shrink the quad so the fill depletes
            -- right-to-left instead of squishing the full-width gradient.
            self.fill:SetTexCoord(0, frac, 0, 1)
            self.fill:SetWidth(self:GetWidth() * frac)
            self.fill:Show()
        else
            self.fill:Hide()
        end
    end

    bar.SetTexture = function(self, path)
        self.fill:SetTexture(path)
    end

    bar.SetColor = function(self, r, g, b)
        self.fill:SetVertexColor(r, g, b, 1)
    end

    return bar
end

-- Switches the health fill between the baked-color "Health" texture and the
-- neutral "Health-Status" texture, applying the unit's class color on the latter.
-- The colored "Health" texture is not white, so a vertex-color tint over it would
-- be muddy instead of a clean class color.
local function ApplyHealthBarStyle(frame, unit, config)
    local normalPath = TEXTURES.BAR_PREFIX .. "Health"
    local statusPath = TEXTURES.BAR_PREFIX .. "Health-Status"

    if config and config.classColorHealth then
        if frame.healthBar.fill:GetTexture() ~= statusPath then
            frame.healthBar:SetTexture(statusPath)
        end
        local _, class = UnitClass(unit)
        local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if color then
            frame.healthBar:SetColor(color.r, color.g, color.b)
        else
            frame.healthBar:SetColor(1, 1, 1)
        end
    else
        if frame.healthBar.fill:GetTexture() ~= normalPath then
            frame.healthBar:SetTexture(normalPath)
        end
        frame.healthBar:SetColor(1, 1, 1)
    end
end

-- Colors the name-background gradient by the carrier's reaction: green for
-- allies, red for enemies, yellow for neutral. Mirrors the target frame.
local function ApplyNameBGFaction(frame, unit)
    if not frame or not frame.nameBG or not unit then return end

    local r, g, b = UnitSelectionColor(unit)
    local colorKey = ResolveNameBackgroundColorKey(r, g, b)
    local coords = NAME_BG_TEX_COORDS[colorKey] or NAME_BG_TEX_COORDS.yellow

    frame.nameBG:SetTexCoord(unpack(coords))
end

-- ============================================================================
-- FRAME CONSTRUCTION
-- ============================================================================

local function CreateCarrierFrame(index)
    local carrier = CreateFrame("Button", nil, UIParent, "SecureUnitButtonTemplate")
    carrier:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    carrier:SetFrameStrata("MEDIUM")
    carrier:RegisterForClicks("AnyUp")
    carrier:SetAttribute("unit", "arena" .. index)
    carrier:SetAttribute("*type1", "target")
    carrier:SetAttribute("*type2", "togglemenu")

    -- Frame background (dark panel) — same anchor/offset as boss.lua
    local background = carrier:CreateTexture(nil, "BACKGROUND", nil, -7)
    background:SetTexture(TEXTURES.BACKGROUND)
    background:SetPoint("TOPLEFT", carrier, "TOPLEFT", 0, -8)

    -- Border on its own frame above the bars
    local borderFrame = CreateFrame("Frame", nil, carrier)
    borderFrame:SetAllPoints(carrier)
    borderFrame:SetFrameLevel(carrier:GetFrameLevel() + 2)
    borderFrame:EnableMouse(false)

    local border = borderFrame:CreateTexture(nil, "OVERLAY", nil, 5)
    border:SetTexture(TEXTURES.BORDER)
    border:SetPoint("TOPLEFT", background, "TOPLEFT", 0, 0)

    -- Portrait (class icon) + circular mask
    local portrait = carrier:CreateTexture(nil, "ARTWORK")
    portrait:SetSize(56, 56)
    portrait:SetPoint("TOPRIGHT", carrier, "TOPRIGHT", -47, -15)

    local portraitMask = carrier:CreateTexture(nil, "BACKGROUND", nil, 1)
    portraitMask:SetTexture(PORTRAIT_MASK)
    portraitMask:SetVertexColor(0, 0, 0, 1)
    portraitMask:SetSize(56, 56)
    portraitMask:SetPoint("CENTER", portrait, "CENTER", 0, 0)

    -- Health bar
    local healthBar = CreateStatusBar(carrier, TEXTURES.BAR_PREFIX .. "Health")
    healthBar:SetSize(125, 20)
    healthBar:SetPoint("RIGHT", portrait, "LEFT", -1, 0)
    healthBar:SetFrameLevel(carrier:GetFrameLevel() + 1)

    local healthText = healthBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    healthText:SetPoint("CENTER")

    -- Power bar
    local powerBar = CreateStatusBar(carrier, TEXTURES.BAR_PREFIX .. "Mana")
    powerBar:SetSize(132, 9)
    powerBar:SetPoint("RIGHT", portrait, "LEFT", 6.5, -16.5)
    powerBar:SetFrameLevel(carrier:GetFrameLevel() + 1)

    local powerText = powerBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    powerText:SetPoint("CENTER")

    -- Name background
    local nameBG = carrier:CreateTexture(nil, "BORDER", nil, 1)
    nameBG:SetTexture(NAME_BG_PTR_TEXTURE)
    nameBG:SetBlendMode("ADD")
    nameBG:SetSize(135, 18)
    nameBG:SetPoint("BOTTOMLEFT", healthBar, "TOPLEFT", -2, -5)

    -- Name text
    local nameText = carrier:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("BOTTOM", healthBar, "TOP", 4, 1)

    -- Faction icon (top-right, next to the portrait)
    local factionIcon = carrier:CreateTexture(nil, "OVERLAY", nil, 7)
    factionIcon:SetSize(48, 48)
    factionIcon:SetPoint("TOPRIGHT", carrier, "TOPRIGHT", -4, -8)

    -- Crowd-control indicator (icon + cooldown sweep, overlaid on the portrait)
    local ccIcon = carrier:CreateTexture(nil, "OVERLAY", nil, 7)
    ccIcon:SetSize(56, 56)
    ccIcon:SetPoint("CENTER", portrait, "CENTER", 0, 0)
    ccIcon:Hide()

    local ccCooldown = CreateFrame("Cooldown", nil, carrier, "CooldownFrameTemplate")
    ccCooldown:ClearAllPoints()
    ccCooldown:SetSize(56, 56)
    ccCooldown:SetPoint("CENTER", portrait, "CENTER", 0, 0)
    ccCooldown:SetFrameLevel(carrier:GetFrameLevel() + 8)
    ccCooldown:Hide()

    carrier.background = background
    carrier.border = border
    carrier.portrait = portrait
    carrier.portraitMask = portraitMask
    carrier.factionIcon = factionIcon
    carrier.ccIcon = ccIcon
    carrier.ccCooldown = ccCooldown
    carrier.nameText = nameText
    carrier.nameBG = nameBG
    carrier.healthBar = healthBar
    carrier.healthText = healthText
    carrier.powerBar = powerBar
    carrier.powerText = powerText

    return carrier
end

-- Masks the CC icon and the Cooldown sweep to the circular portrait shape so
-- their square corners don't escape the portrait's round border. The Cooldown
-- widget creates its sweep texture lazily on the first SetCooldown, so this is
-- re-applied after each update as well.
local function ApplyCCMask(frame)
    if not frame then return end

    local icon = frame.ccIcon
    if icon and icon.SetMaskTexture then
        icon:SetMaskTexture(PORTRAIT_MASK)
    end

    local cooldown = frame.ccCooldown
    if cooldown and cooldown.GetRegions then
        for _, region in ipairs({ cooldown:GetRegions() }) do
            if region and region.SetMaskTexture then
                region:SetMaskTexture(PORTRAIT_MASK)
            end
        end
    end
end

-- ============================================================================
-- UPDATE LOGIC
-- ============================================================================

-- Collapses a TextSystem.FormatStatusText result into a single line for the
-- single FontString used by the carrier bars. The "both" format returns a
-- { left = "74%", right = "624.0k" } table, rendered here as "624.0k (74%)".
local function FormatSingleLine(formatted, textFormat)
    if type(formatted) == "table" then
        return (formatted.right or "") .. " (" .. (formatted.left or "") .. ")"
    end
    return formatted or ""
end

local function UnitToIndex(unit)
    if not unit then return nil end
    local idx = unit:match("^arena(%d+)$")
    return idx and tonumber(idx)
end

local function UpdateCarrierCC(index)
    local frame = Module.carrierFrames[index]
    if not frame or not frame:IsShown() then return end

    local unit = "arena" .. index
    if not UnitExists(unit) then return end

    local ccIcon, ccDuration, ccExpiration
    for i = 1, 40 do
        local _, _, icon, _, _, duration, expirationTime, _, _, _, spellId = UnitAura(unit, i, "HARMFUL")
        if not icon then break end
        if spellId and CC_SPELLS[spellId] then
            ccIcon = icon
            ccDuration = duration
            ccExpiration = expirationTime
            break
        end
    end

    if ccIcon then
        if SetPortraitToTexture then
            local ok = pcall(SetPortraitToTexture, frame.ccIcon, ccIcon)
            if ok then
                frame.ccIcon:SetTexCoord(0, 1, 0, 1)
            else
                frame.ccIcon:SetTexture(ccIcon)
                frame.ccIcon:SetTexCoord(0, 1, 0, 1)
            end
        else
            frame.ccIcon:SetTexture(ccIcon)
            frame.ccIcon:SetTexCoord(0, 1, 0, 1)
        end
        frame.ccIcon:Show()
        if ccDuration and ccDuration > 0 and ccExpiration then
            frame.ccCooldown:SetCooldown(ccExpiration - ccDuration, ccDuration)
            frame.ccCooldown:Show()
        else
            frame.ccCooldown:Hide()
        end
        ApplyCCMask(frame)
    else
        frame.ccIcon:Hide()
        frame.ccCooldown:Hide()
    end
end

local function UpdateCarrierBars(index)
    local frame = Module.carrierFrames[index]
    if not frame or not frame:IsShown() then return end

    local unit = "arena" .. index
    if not UnitExists(unit) then return end

    -- Health
    local hp, hpMax = UnitHealth(unit), UnitHealthMax(unit)
    hpMax = hpMax and hpMax > 0 and hpMax or 1
    frame.healthBar:SetValue(hp or 0, hpMax)

    local config = GetConfig()
    ApplyHealthBarStyle(frame, unit, config)

    local showText = config and config.showHealthText
    local textFormat = (config and config.textFormat) or "both"
    local breakUp = config and config.breakUpLargeNumbers

    -- Health text. The "Dead" label only appears when the numeric health value
    -- isn't visible (showHealthText off); with it on, the formatted value stays
    -- visible even while dead, matching the target/party text system.
    local dead = UnitIsDeadOrGhost(unit)
    if showText then
        local healthFormatted = addon.TextSystem.FormatStatusText(hp, hpMax, textFormat, breakUp)
        frame.healthText:SetText(FormatSingleLine(healthFormatted, textFormat))
        frame.healthText:SetTextColor(1, 1, 1, 1)
        frame.healthText:Show()
    elseif dead then
        frame.healthText:SetText(DEAD)
        frame.healthText:SetTextColor(1, 0, 0, 1)
        frame.healthText:Show()
    else
        frame.healthText:Hide()
    end

    -- Power
    local powerType = UnitPowerType(unit)
    local powerName = UF.POWER_MAP[powerType] or "Mana"
    frame.powerBar:SetTexture(TEXTURES.BAR_PREFIX .. powerName)
    local pw = UnitPower(unit, powerType) or 0
    local pwMax = UnitPowerMax(unit, powerType) or 1
    if pwMax <= 0 then pwMax = 1 end
    frame.powerBar:SetValue(pw, pwMax)

    if showText then
        local powerFormatted = addon.TextSystem.FormatStatusText(pw, pwMax, textFormat, breakUp)
        frame.powerText:SetText(FormatSingleLine(powerFormatted, textFormat))
        frame.powerText:SetTextColor(1, 1, 1, 1)
        frame.powerText:Show()
    else
        frame.powerText:Hide()
    end

    UpdateCarrierCC(index)
end

local function UpdateCarrier(index)
    local frame = Module.carrierFrames[index]
    if not frame then return end

    local unit = "arena" .. index
    if not UnitExists(unit) then
        frame:Hide()
        return
    end

    frame:Show()

    -- Portrait (class icon)
    if not UF.ApplyClassPortraitToTexture(unit, frame.portrait, false) then
        frame.portrait:SetTexture(nil)
    end

    -- Name (class color or yellow, like target/player frames)
    local name = UnitName(unit) or UNKNOWN
    frame.nameText:SetText(name)
    local config = GetConfig()
    if config and config.classColor then
        local _, class = UnitClass(unit)
        local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if color then
            frame.nameText:SetTextColor(color.r, color.g, color.b, 1)
        else
            frame.nameText:SetTextColor(1, 0.82, 0, 1)
        end
    else
        frame.nameText:SetTextColor(1, 0.82, 0, 1)
    end
    ApplyNameBGFaction(frame, unit)
    frame.nameBG:Show()

    -- Faction icon (carriers are always enemy faction in BG)
    local factionGroup = UnitFactionGroup(unit)
    if factionGroup and factionGroup ~= "Neutral" then
        frame.factionIcon:SetTexture("Interface\\TargetingFrame\\UI-PVP-" .. factionGroup)
        frame.factionIcon:Show()
    else
        frame.factionIcon:Hide()
    end

    UpdateCarrierBars(index)
end

local function UpdateAllCarriers()
    if not IsEnabled() then
        for i = 1, NUM_CARRIERS do
            if Module.carrierFrames[i] then Module.carrierFrames[i]:Hide() end
        end
        return
    end

    if not IsBattleground() then
        for i = 1, NUM_CARRIERS do
            if Module.carrierFrames[i] then Module.carrierFrames[i]:Hide() end
        end
        return
    end

    local numOpponents = GetNumArenaOpponents() or 0
    for i = 1, NUM_CARRIERS do
        if i <= numOpponents then
            UpdateCarrier(i)
        else
            if Module.carrierFrames[i] then Module.carrierFrames[i]:Hide() end
        end
    end
end

-- ============================================================================
-- POSITIONING
-- ============================================================================

local function PositionFrames()
    if not Module.overlay then return end
    local config = GetConfig()
    local scale = config.scale or 1.0

    for i = 1, NUM_CARRIERS do
        local frame = Module.carrierFrames[i]
        if frame then
            frame:SetScale(scale)
            frame:ClearAllPoints()
            if i == 1 then
                frame:SetPoint("TOP", Module.overlay, "TOP", 0, 0)
            else
                frame:SetPoint("TOP", Module.carrierFrames[i - 1], "BOTTOM", 0, -FRAME_SPACING)
            end
        end
    end
end

local function ApplyOverlayPosition()
    if not Module.overlay then return end
    local config = GetConfig()

    if config and config.override then
        if addon.db and addon.db.profile and addon.db.profile.widgets then
            local widgetConfig = addon.db.profile.widgets.bgcarrier
            if widgetConfig and widgetConfig.posX and widgetConfig.posY then
                local anchor = widgetConfig.anchor or "CENTER"
                Module.overlay:ClearAllPoints()
                Module.overlay:SetPoint(anchor, UIParent, anchor, widgetConfig.posX, widgetConfig.posY)
                return
            end
        end
    end

    Module.overlay:ClearAllPoints()
    Module.overlay:SetPoint(
        config.anchor or "TOPRIGHT",
        UIParent,
        config.anchorParent or "TOPRIGHT",
        config.x or -85,
        config.y or -180
    )
end

-- ============================================================================
-- HIDE / RESTORE NATIVE ARENA ENEMY FRAMES
-- ============================================================================

local function HideNativeArenaFrames()
    if Module.nativeHidden then return end
    if SetCVar and GetCVarBool and GetCVarBool("showArenaEnemyFrames") then
        SetCVar("showArenaEnemyFrames", "0")
    end
    Module.nativeHidden = true
end

local function RestoreNativeArenaFrames()
    if not Module.nativeHidden then return end
    if SetCVar then
        SetCVar("showArenaEnemyFrames", "1")
    end
    Module.nativeHidden = false
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local function InitializeFrames()
    if Module.configured then return end
    if InCombatLockdown() then return end
    if not IsEnabled() then return end

    for i = 1, NUM_CARRIERS do
        Module.carrierFrames[i] = CreateCarrierFrame(i)
    end

    PositionFrames()
    HideNativeArenaFrames()
    UpdateAllCarriers()

    Module.configured = true
    Module.applied = true
end

-- ============================================================================
-- EDITOR MODE
-- ============================================================================

local function SetupEditorMode()
    if Module.overlay then return end

    local totalHeight = NUM_CARRIERS * FRAME_HEIGHT + (NUM_CARRIERS - 1) * FRAME_SPACING
    Module.overlay = addon.CreateUIFrame(FRAME_WIDTH, totalHeight, "bgcarrier")

    if Module.overlay.editorText then
        Module.overlay.editorText:SetText(
            (L and (L["bgcarrier"] or L["Battleground Carriers"])) or "Battleground Carriers"
        )
    end

    Module.overlay:ClearAllPoints()
    Module.overlay:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -85, -180)

    Module.overlay:HookScript("OnDragStop", function(self)
        self.DragonUI_WasDragged = true
    end)

    addon:RegisterEditableFrame({
        name = "bgcarrier",
        frame = Module.overlay,
        configPath = {"widgets", "bgcarrier"},
        hasTarget = function()
            return true
        end,
        showTest = function()
            if Module.overlay then Module.overlay:Show() end
            for i = 1, NUM_CARRIERS do
                local frame = Module.carrierFrames[i]
                if frame then
                    frame.portrait:SetTexture(nil)
                    UF.ApplyClassPortraitToTexture("player", frame.portrait, false)
                    frame.nameText:SetText(UnitName("player") or "Player")
                    local cfg = GetConfig()
                    if cfg and cfg.classColor then
                        local _, class = UnitClass("player")
                        local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
                        if color then
                            frame.nameText:SetTextColor(color.r, color.g, color.b, 1)
                        else
                            frame.nameText:SetTextColor(1, 0.82, 0, 1)
                        end
                    else
                        frame.nameText:SetTextColor(1, 0.82, 0, 1)
                    end
                    frame.nameBG:SetTexCoord(unpack(NAME_BG_TEX_COORDS.green))
                    frame.nameBG:Show()
                    frame.factionIcon:SetTexture("Interface\\TargetingFrame\\UI-PVP-Horde")
                    frame.factionIcon:Show()
                    frame.healthBar:SetValue(70, 100)
                    ApplyHealthBarStyle(frame, "player", cfg)
                    if cfg and cfg.showHealthText then
                        local textFormat = (cfg and cfg.textFormat) or "both"
                        local breakUp = cfg and cfg.breakUpLargeNumbers
                        frame.healthText:SetText(FormatSingleLine(
                            addon.TextSystem.FormatStatusText(70, 100, textFormat, breakUp), textFormat))
                        frame.healthText:SetTextColor(1, 1, 1, 1)
                        frame.healthText:Show()
                    else
                        frame.healthText:Hide()
                    end
                    frame.powerBar:SetValue(50, 100)
                    if cfg and cfg.showHealthText then
                        local textFormat = (cfg and cfg.textFormat) or "both"
                        local breakUp = cfg and cfg.breakUpLargeNumbers
                        frame.powerText:SetText(FormatSingleLine(
                            addon.TextSystem.FormatStatusText(50, 100, textFormat, breakUp), textFormat))
                        frame.powerText:SetTextColor(1, 1, 1, 1)
                        frame.powerText:Show()
                    else
                        frame.powerText:Hide()
                    end
                    frame:Show()
                end
            end
        end,
        hideTest = function()
            UpdateAllCarriers()
        end,
        onHide = function()
            if Module.overlay and Module.overlay.DragonUI_WasDragged then
                local config = GetConfig()
                if config then config.override = true end
                ApplyOverlayPosition()
                Module.overlay.DragonUI_WasDragged = nil
            end
        end,
        module = Module
    })
end

-- ============================================================================
-- EVENT HANDLING
-- ============================================================================

local eventsFrame = CreateFrame("Frame")
Module.eventsFrame = eventsFrame

eventsFrame:SetScript("OnEvent", function(self, event, ...)
    if not IsEnabled() then return end

    if event == "ADDON_LOADED" then
        local name = ...
        if name == "DragonUI" then
            SetupEditorMode()
            ApplyOverlayPosition()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        InitializeFrames()
        PositionFrames()
        HideNativeArenaFrames()
        UpdateAllCarriers()

    elseif event == "PLAYER_REGEN_ENABLED" then
        if not Module.configured then
            InitializeFrames()
        end
        PositionFrames()
        UpdateAllCarriers()

    elseif event == "ARENA_OPPONENT_UPDATE" then
        UpdateAllCarriers()

    elseif event == "PLAYER_ENTERING_BATTLEGROUND" or event == "UPDATE_BATTLEFIELD_SCORE" or event == "ZONE_CHANGED_NEW_AREA" then
        InitializeFrames()
        UpdateAllCarriers()

    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" or event == "UNIT_NAME_UPDATE" or event == "UNIT_FACTION" or event == "UNIT_DISPLAYPOWER" then
        local unit = ...
        local idx = UnitToIndex(unit)
        if idx then UpdateCarrier(idx) end

    elseif event == "UNIT_POWER" or event == "UNIT_MAXPOWER" then
        local unit = ...
        local idx = UnitToIndex(unit)
        if idx then UpdateCarrier(idx) end
    end
end)

eventsFrame:RegisterEvent("ADDON_LOADED")
eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventsFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventsFrame:RegisterEvent("ARENA_OPPONENT_UPDATE")
eventsFrame:RegisterEvent("PLAYER_ENTERING_BATTLEGROUND")
eventsFrame:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
eventsFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventsFrame:RegisterEvent("UNIT_HEALTH")
eventsFrame:RegisterEvent("UNIT_MAXHEALTH")
eventsFrame:RegisterEvent("UNIT_NAME_UPDATE")
eventsFrame:RegisterEvent("UNIT_FACTION")
eventsFrame:RegisterEvent("UNIT_DISPLAYPOWER")
eventsFrame:RegisterEvent("UNIT_POWER")
eventsFrame:RegisterEvent("UNIT_MAXPOWER")

-- ============================================================================
-- HEALTH/POWER POLLING
-- ============================================================================
-- UNIT_HEALTH/UNIT_MAXHEALTH do not fire for arena/carrier units in BGs (they
-- are remote "seen" units), so poll UnitHealth/UnitPower like the native
-- arena frame's UnitFrameHealthBar_OnUpdate frequentUpdates path.

local pollFrame = CreateFrame("Frame")
pollFrame.elapsed = 0
pollFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < 0.1 then return end
    self.elapsed = 0

    if not IsEnabled() or not IsBattleground() then return end

    for i = 1, NUM_CARRIERS do
        UpdateCarrierBars(i)
    end
end)

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function addon.RefreshBgCarrierFrames()
    if not IsEnabled() then
        RestoreNativeArenaFrames()
        if not Module.configured then return end
        for i = 1, NUM_CARRIERS do
            if Module.carrierFrames[i] then Module.carrierFrames[i]:Hide() end
        end
        return
    end

    if not Module.configured then
        SetupEditorMode()
        InitializeFrames()
    end

    ApplyOverlayPosition()
    PositionFrames()
    HideNativeArenaFrames()
    UpdateAllCarriers()
end

addon.BgCarrierModule = Module

-- Profile change callbacks
local function OnProfileChanged()
    if addon.RefreshBgCarrierFrames then
        addon.RefreshBgCarrierFrames()
    end
end

local profileFrame = CreateFrame("Frame")
profileFrame:RegisterEvent("PLAYER_LOGIN")
profileFrame:SetScript("OnEvent", function(self, event)
    if addon.db and addon.db.RegisterCallback then
        addon.db.RegisterCallback(Module, "OnProfileChanged", OnProfileChanged)
        addon.db.RegisterCallback(Module, "OnProfileCopied", OnProfileChanged)
        addon.db.RegisterCallback(Module, "OnProfileReset", OnProfileChanged)
    end
    self:UnregisterAllEvents()
end)
