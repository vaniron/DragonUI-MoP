--[[
    DragonUI MicroMenu Module
    Refactored version maintaining all functionality with better organization
    Now with module enable/disable system

    -- MODULAR VERSION FOR VANILLA & ASCENSION --
]]
local addon = select(2, ...);
local config = addon.config;
local L = addon.L

-- ============================================================================
-- SERVER DETECTION & MODULE STATE
-- ============================================================================

local MicromenuModule = {
    initialized = false,
    applied = false,
    originalStates = {}, -- Store original states for restoration
    registeredEvents = {}, -- Track registered events
    hooks = {}, -- Track hooked functions
    stateDrivers = {}, -- Track state drivers
    frames = {}, -- Track created frames
    originalHandlers = {}, -- Store original button handlers
    originalSetPoints = {}, -- Store original SetPoint functions
    originalCVars = {}, -- Store original CVar values
    eventFrames = {} -- Track event handler frames
}

-- Map native micro buttons to our secure replacement buttons. Declared early so
-- functions defined before the secure-replacement section (e.g. portrait updates)
-- can still reference it.
local replacementButtons = {}
MicromenuModule.replacementButtons = replacementButtons

-- Anchors the dungeon/queue eye (QueueStatusMinimapButton) at the left end of
-- the micromenu row. Declared early so LayoutMicroButtons can call it; assigned
-- in the LFG section below.
local AnchorLFGEye
local ReleaseLFGEyeLocks

-- Register with ModuleRegistry (if available)
if addon.RegisterModule then
    addon:RegisterModule("micromenu", MicromenuModule,
        addon.L["Micro Menu"],
        addon.L["Micro menu and bags system styling and positioning"])
end

-- ============================================================================
-- CONFIGURATION FUNCTIONS
-- ============================================================================

local function IsModuleEnabled()
    return addon:IsModuleEnabled("micromenu")
end

local function GetLFGTooltipPosition()
    local pos = addon.db and addon.db.profile and addon.db.profile.widgets and addon.db.profile.widgets.lfgframe
        and addon.db.profile.widgets.lfgframe.tooltip_position
    if pos == "TOP" or pos == "BOTTOM" or pos == "LEFT" or pos == "RIGHT" then
        return pos
    end
    return "TOP"
end

local function GetLFDStatusAnchorSpec(position)
    if position == "BOTTOM" then
        return "TOP", "BOTTOM", 0, -30
    elseif position == "LEFT" then
        return "RIGHT", "LEFT", -24, 0
    elseif position == "RIGHT" then
        return "LEFT", "RIGHT", 24, 0
    end

    -- Default/current behavior.
    return "BOTTOM", "TOP", 0, 30
end

-- ============================================================================
-- SECTION 1: LOCALS AND CONSTANTS
-- ============================================================================

local pairs = pairs;
local gsub = string.gsub;
local UIParent = UIParent;
local hooksecurefunc = hooksecurefunc;
local _G = _G;

-- Performance constants
local PERFORMANCEBAR_LOW_LATENCY = 200;
local PERFORMANCEBAR_MEDIUM_LATENCY = 300;

-- Frame references
local MainMenuBarBackpackButton = _G.MainMenuBarBackpackButton;
local MainMenuMicroButton = _G.MainMenuMicroButton;
local KeyRingButton = _G.KeyRingButton;

-- Button collections (MoP 5.4.8)
-- Button names are resolved at runtime because some MoP clients create the
-- buttons lazily or use different names (e.g. Companions instead of Collections).
local MICRO_BUTTON_NAMES = {
    "CharacterMicroButton",
    "SpellbookMicroButton",
    "TalentMicroButton",
    "AchievementMicroButton",
    "QuestLogMicroButton",
    "GuildMicroButton",         -- Native guild/social button on MoP
    "LFDMicroButton",
    "CompanionsMicroButton",    -- Collections on some MoP clients
    "EJMicroButton",            -- Encounter Journal (MoP)
    "PVPMicroButton",           -- Native PVP button on this MoP client
    "StoreMicroButton",         -- Store (MoP)
    "MainMenuMicroButton",      -- MainMenu/GameMenu on some MoP clients
}
addon.MicroMenuButtonNames = MICRO_BUTTON_NAMES

-- Map each styled micro button to the function that opens its panel. Calling
-- these global UI functions from our own normal Button frames avoids tainting
-- the native micro buttons and the panels they open.
local MICRO_BUTTON_OPENERS = {
    character = function()
        if ToggleCharacter then ToggleCharacter("PaperDollFrame")
        elseif CharacterFrame then ToggleFrame(CharacterFrame) end
    end,
    spellbook = function() ToggleSpellBook("spellBook") end,
    talent = function() ToggleTalentFrame() end,
    achievement = function() ToggleAchievementFrame() end,
    questlog = function() ToggleQuestLog() end,
    guild = function() ToggleGuildFrame() end,
    socials = function() ToggleGuildFrame() end,
    lfd = function() ToggleLFDParentFrame() end,
    collections = function() ToggleCollectionsJournal(1) end,
    companions = function() ToggleCollectionsJournal(1) end,
    ej = function() ToggleEncounterJournal() end,
    pvp = function()
        if TogglePVPUI then TogglePVPUI()
        elseif PVPFrame then ToggleFrame(PVPFrame) end
    end,
    store = function() if ToggleStoreUI then ToggleStoreUI() end end,
    mainmenu = function()
        if ToggleGameMenu then ToggleGameMenu()
        elseif GameMenuFrame then ToggleFrame(GameMenuFrame) end
    end,
    help = function() ToggleHelpFrame() end,
}

-- Buttons whose native frame has no OnClick script (they are secure native
-- frames). SecureActionButtonTemplate's "/click Name" cannot fire them while
-- they are hidden, so we open their panel directly from a plain Button instead.
-- None of these are protected actions except MainMenu (Game Menu); the Game Menu
-- popup is suppressed separately (see the StaticPopup_Show hook below).
local DIRECT_OPEN_BUTTONS = {
    character = true,
    pvp = true,
    mainmenu = true,
}

-- Some MOP 5.4.8 clients (or load orders) call micro-button update globals
-- from inside Blizzard panel addons before those globals are defined. Stubbing
-- them prevents nil-call errors when opening achievements/talents/etc.
local MICRO_BUTTON_UPDATE_STUBS = {
    "AchievementMicroButton_Update",
    "TalentMicroButton_Update",
    "SpellbookMicroButton_Update",
    "LFDMicroButton_Update",
    "GuildMicroButton_Update",
    "EJMicroButton_Update",
    "CollectionsMicroButton_Update",
    "StoreMicroButton_Update",
    "HelpMicroButton_Update",
    "MainMenuMicroButton_Update",
}
for _, name in ipairs(MICRO_BUTTON_UPDATE_STUBS) do
    if not _G[name] then
        _G[name] = function() end
    end
end

-- The Game Menu (MainMenu) opens via ToggleGameMenu() from a plain Button, which
-- taints GameMenuFrame and triggers Blizzard's "addon blocked" popup. Suppress
-- that popup by hiding it the instant Blizzard shows it. We use hooksecurefunc
-- (NOT a replacement of StaticPopup_Show), so this does not taint globally and
-- protected actions like changing talents/glyphs keep working.
hooksecurefunc("StaticPopup_Show", function(which)
    if which == "ADDON_ACTION_BLOCKED" or which == "ADDON_ACTION_FORBIDDEN" then
        StaticPopup_Hide(which)
    end
end)

-- Buttons that DragonUI does NOT style but may have touched indirectly (or that
-- existed in a previous config) must still be restored to their original state
-- when the module is disabled/reset.
local RESTORE_ONLY_BUTTON_NAMES = {
    "FriendsMicroButton",
    "HelpMicroButton",
}

local function GetMicroButtons()
    local buttons = {}
    for _, name in ipairs(MICRO_BUTTON_NAMES) do
        local btn = _G[name]
        if btn then
            buttons[#buttons + 1] = btn
        end
    end
    return buttons
end


local bagslots = {_G.CharacterBag0Slot, _G.CharacterBag1Slot, _G.CharacterBag2Slot, _G.CharacterBag3Slot};

-- State tracking
local originalBlizzardHandlers = {}
local MainMenuMicroButtonMixin = {};

-- ============================================================================
-- SECTION 2: ATLAS COORDINATES
-- ============================================================================

local MicromenuAtlas = {
    ["UI-HUD-MicroMenu-Achievements-Disabled"] = {0.000976562, 0.0634766, 0.00195312, 0.162109},
    ["UI-HUD-MicroMenu-Achievements-Down"] = {0.000976562, 0.0634766, 0.166016, 0.326172},
    ["UI-HUD-MicroMenu-Achievements-Mouseover"] = {0.000976562, 0.0634766, 0.330078, 0.490234},
    ["UI-HUD-MicroMenu-Achievements-Up"] = {0.000976562, 0.0634766, 0.494141, 0.654297},

    ["UI-HUD-MicroMenu-GameMenu-Disabled"] = {0.129883, 0.192383, 0.330078, 0.490234},
    ["UI-HUD-MicroMenu-GameMenu-Down"] = {0.129883, 0.192383, 0.494141, 0.654297},
    ["UI-HUD-MicroMenu-GameMenu-Mouseover"] = {0.129883, 0.192383, 0.658203, 0.818359},
    ["UI-HUD-MicroMenu-GameMenu-Up"] = {0.129883, 0.192383, 0.822266, 0.982422},

    ["UI-HUD-MicroMenu-Groupfinder-Disabled"] = {0.194336, 0.256836, 0.00195312, 0.162109},
    ["UI-HUD-MicroMenu-Groupfinder-Down"] = {0.194336, 0.256836, 0.166016, 0.326172},
    ["UI-HUD-MicroMenu-Groupfinder-Mouseover"] = {0.194336, 0.256836, 0.330078, 0.490234},
    ["UI-HUD-MicroMenu-Groupfinder-Up"] = {0.194336, 0.256836, 0.494141, 0.654297},

    ["UI-HUD-MicroMenu-GuildCommunities-Disabled"] = {0.194336, 0.256836, 0.658203, 0.818359},
    ["UI-HUD-MicroMenu-GuildCommunities-Down"] = {0.194336, 0.256836, 0.822266, 0.982422},
    ["UI-HUD-MicroMenu-GuildCommunities-Mouseover"] = {0.258789, 0.321289, 0.658203, 0.818359},
    ["UI-HUD-MicroMenu-GuildCommunities-Up"] = {0.258789, 0.321289, 0.822266, 0.982422},

    ["UI-HUD-MicroMenu-Questlog-Disabled"] = {0.323242, 0.385742, 0.494141, 0.654297},
    ["UI-HUD-MicroMenu-Questlog-Down"] = {0.323242, 0.385742, 0.658203, 0.818359},
    ["UI-HUD-MicroMenu-Questlog-Mouseover"] = {0.323242, 0.385742, 0.822266, 0.982422},
    ["UI-HUD-MicroMenu-Questlog-Up"] = {0.387695, 0.450195, 0.00195312, 0.162109},

    ["UI-HUD-MicroMenu-SpecTalents-Disabled"] = {0.387695, 0.450195, 0.822266, 0.982422},
    ["UI-HUD-MicroMenu-SpecTalents-Down"] = {0.452148, 0.514648, 0.00195312, 0.162109},
    ["UI-HUD-MicroMenu-SpecTalents-Mouseover"] = {0.452148, 0.514648, 0.166016, 0.326172},
    ["UI-HUD-MicroMenu-SpecTalents-Up"] = {0.452148, 0.514648, 0.330078, 0.490234},

    ["UI-HUD-MicroMenu-SpellbookAbilities-Disabled"] = {0.452148, 0.514648, 0.494141, 0.654297},
    ["UI-HUD-MicroMenu-SpellbookAbilities-Down"] = {0.452148, 0.514648, 0.658203, 0.818359},
    ["UI-HUD-MicroMenu-SpellbookAbilities-Mouseover"] = {0.452148, 0.514648, 0.822266, 0.982422},
    ["UI-HUD-MicroMenu-SpellbookAbilities-Up"] = {0.516602, 0.579102, 0.00195312, 0.162109},

    ["UI-HUD-MicroMenu-Shop-Disabled"] = {0.387695, 0.450195, 0.166016, 0.326172},
    ["UI-HUD-MicroMenu-Shop-Down"] = {0.387695, 0.450195, 0.494141, 0.654297},
    ["UI-HUD-MicroMenu-Shop-Mouseover"] = {0.387695, 0.450195, 0.330078, 0.490234},
    ["UI-HUD-MicroMenu-Shop-Up"] = {0.387695, 0.450195, 0.658203, 0.818359}
}

-- Collections atlas (always present in MoP)
MicromenuAtlas["UI-HUD-MicroMenu-Collections-Disabled"] = {0.0654297, 0.12793, 0.658203, 0.818359}
MicromenuAtlas["UI-HUD-MicroMenu-Collections-Down"] = {0.0654297, 0.12793, 0.822266, 0.982422}
MicromenuAtlas["UI-HUD-MicroMenu-Collections-Mouseover"] = {0.129883, 0.192383, 0.00195312, 0.162109}
MicromenuAtlas["UI-HUD-MicroMenu-Collections-Up"] = {0.129883, 0.192383, 0.166016, 0.326172}

-- Encounter Journal (Dungeon Journal) — real atlas coordinates.
MicromenuAtlas["UI-HUD-MicroMenu-EncounterJournal-Disabled"] = {0.000976562, 0.0634766, 0.658203, 0.818359}
MicromenuAtlas["UI-HUD-MicroMenu-EncounterJournal-Down"] = {0.000976562, 0.0634766, 0.822266, 0.982422}
MicromenuAtlas["UI-HUD-MicroMenu-EncounterJournal-Mouseover"] = {0.0654297, 0.12793, 0.00195312, 0.162109}
MicromenuAtlas["UI-HUD-MicroMenu-EncounterJournal-Up"] = {0.0654297, 0.12793, 0.166016, 0.326172}


-- ============================================================================
-- SECTION 3: UTILITY FUNCTIONS (ALL ORIGINAL CODE PRESERVED)
-- ============================================================================

-- Database persistence helpers
local function GetBagCollapseState()
    if addon.db and addon.db.profile and addon.db.profile.micromenu then
        return addon.db.profile.micromenu.bags_collapsed
    end
    return false
end

local function SetBagCollapseState(collapsed)
    if addon.db and addon.db.profile and addon.db.profile.micromenu then
        addon.db.profile.micromenu.bags_collapsed = collapsed
    end
end

local function ShouldForceCollapsedSecondaryInvisible()
    local actionbars = addon.db and addon.db.profile and addon.db.profile.actionbars
    if not actionbars then
        return false
    end

    local visibilityEnabled = actionbars.bag_show_on_hover or actionbars.bag_show_in_combat
    if not visibilityEnabled then
        return false
    end

    local hiddenAlpha = actionbars.bag_visibility_hidden_alpha
    if hiddenAlpha == nil then
        hiddenAlpha = actionbars.visibility_hidden_alpha
    end

    return (tonumber(hiddenAlpha) or 0) > 0
end

-- Bag icon refresh helper.
-- In 3.3.5a, item textures can be temporarily unavailable right after reload;
-- avoid clearing/hiding valid icon data on transient nil returns.
local function RefreshBagSlotIcons()
    local collapsed = GetBagCollapseState()
    local forceHideCollapsed = collapsed and ShouldForceCollapsedSecondaryInvisible()
    for _, bagButton in pairs(bagslots) do
        if bagButton then
            local icon = _G[bagButton:GetName() .. 'IconTexture']
            if icon then
                local inventorySlot = bagButton:GetID()
                local bagLink = GetInventoryItemLink("player", inventorySlot)
                local itemTexture = GetInventoryItemTexture("player", inventorySlot)

                if bagLink then
                    if itemTexture then
                        icon:SetTexture(itemTexture)
                    end

                    icon:Show()
                    icon:SetAlpha(forceHideCollapsed and 0 or 1)
                    pcall(function()
                        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    end)
                else
                    icon:SetTexture("Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
                    icon:Show()
                    icon:SetAlpha(0)
                end
            end
        end
    end
end

local function ScheduleBagSlotIconRefreshes()
    RefreshBagSlotIcons()

    if addon.core and addon.core.ScheduleTimer then
        addon.core:ScheduleTimer(function()
            if IsModuleEnabled() then
                RefreshBagSlotIcons()
            end
        end, 0.2)

        addon.core:ScheduleTimer(function()
            if IsModuleEnabled() then
                RefreshBagSlotIcons()
            end
        end, 1.0)
    end
end

-- Adjusts icon alpha for all bag slots to reflect empty/filled state.
-- Blizzard's default handler already updates IconTexture on BAG_UPDATE, so
-- only the alpha fade needs to be applied here.
local PAPERDOLL_BAG_PLACEHOLDER = "interface\\paperdoll\\ui-paperdoll-slot-bag"
local function UpdateBagSlotAlpha()
    local collapsed = GetBagCollapseState()
    local forceHideCollapsed = collapsed and ShouldForceCollapsedSecondaryInvisible()
    for i = 1, #bagslots do
        local bagButton = bagslots[i]
        if bagButton then
            local normalTexture = bagButton:GetNormalTexture()
            if normalTexture then
                normalTexture:SetAlpha(0)
                normalTexture:Hide()
            end

            local icon = _G[bagButton:GetName() .. 'IconTexture']
            if icon then
                local inventorySlot = bagButton:GetID()
                local bagLink = inventorySlot and GetInventoryItemLink("player", inventorySlot) or nil
                local tex = icon:GetTexture()
                local texPath = tex and tostring(tex):lower() or nil
                -- Primary source of truth: equipped bag link.
                -- Texture path is a fallback signal for placeholder visuals.
                local isEmpty = (not bagLink)
                if not isEmpty and texPath and texPath:find(PAPERDOLL_BAG_PLACEHOLDER, 1, true) then
                    isEmpty = true
                end

                if not isEmpty then
                    icon:SetAlpha(forceHideCollapsed and 0 or 1)
                else
                    icon:SetAlpha(0)
                end
            end
        end
    end
end

local collapsedSecondaryFadeDriver

local function StopCollapsedSecondaryFade()
    if collapsedSecondaryFadeDriver then
        collapsedSecondaryFadeDriver:SetScript("OnUpdate", nil)
    end
end

local function ApplyCollapsedSecondaryAlpha(alpha)
    alpha = tonumber(alpha) or 0
    if alpha < 0 then
        alpha = 0
    elseif alpha > 1 then
        alpha = 1
    end

    for i = 1, #bagslots do
        local bags = bagslots[i]
        if bags then
            bags:SetAlpha(alpha)

            if bags.customBorder then
                bags.customBorder:SetAlpha(alpha)
            end
            if bags.background then
                bags.background:SetAlpha(alpha)
            end

            local icon = _G[bags:GetName() .. 'IconTexture']
            if icon then
                local inventorySlot = bags:GetID()
                local bagLink = inventorySlot and GetInventoryItemLink("player", inventorySlot) or nil
                icon:SetAlpha(bagLink and alpha or 0)
            end
        end
    end
end

function addon.RefreshCollapsedSecondaryBagsVisibility(shouldShow)
    if not IsModuleEnabled() then
        return
    end

    local actionbars = addon.db and addon.db.profile and addon.db.profile.actionbars
    if not actionbars or not GetBagCollapseState() then
        StopCollapsedSecondaryFade()
        return
    end

    local visibilityEnabled = actionbars.bag_show_on_hover or actionbars.bag_show_in_combat
    local hiddenAlpha = actionbars.bag_visibility_hidden_alpha
    if hiddenAlpha == nil then
        hiddenAlpha = actionbars.visibility_hidden_alpha
    end
    hiddenAlpha = tonumber(hiddenAlpha) or 0

    if (not visibilityEnabled) or hiddenAlpha > 0 then
        StopCollapsedSecondaryFade()
        return
    end

    if not shouldShow then
        StopCollapsedSecondaryFade()
        ApplyCollapsedSecondaryAlpha(0)
        return
    end

    local startAlpha = 0
    if bagslots[1] and bagslots[1].GetAlpha then
        startAlpha = bagslots[1]:GetAlpha() or 0
    end
    if startAlpha >= 0.99 then
        StopCollapsedSecondaryFade()
        ApplyCollapsedSecondaryAlpha(1)
        return
    end

    if not collapsedSecondaryFadeDriver then
        collapsedSecondaryFadeDriver = CreateFrame("Frame")
    end

    local elapsed = 0
    local duration = 2
    collapsedSecondaryFadeDriver:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        local progress = elapsed / duration

        if progress >= 1 then
            ApplyCollapsedSecondaryAlpha(1)
            StopCollapsedSecondaryFade()
            return
        end

        local alpha = startAlpha + ((1 - startAlpha) * progress)
        ApplyCollapsedSecondaryAlpha(alpha)
    end)
end

-- Atlas helpers
local function GetAtlasKey(buttonName)
    local buttonMap = {
        character = nil, -- Uses portrait
        spellbook = "UI-HUD-MicroMenu-SpellbookAbilities",
        talent = "UI-HUD-MicroMenu-SpecTalents",
        achievement = "UI-HUD-MicroMenu-Achievements",
        questlog = "UI-HUD-MicroMenu-Questlog",
        guild = "UI-HUD-MicroMenu-GuildCommunities",
        socials = "UI-HUD-MicroMenu-GuildCommunities", -- fallback on clients with Socials instead of Guild
        dragonuiguild = "UI-HUD-MicroMenu-GuildCommunities", -- legacy custom button name
        lfd = "UI-HUD-MicroMenu-Groupfinder",
        collections = "UI-HUD-MicroMenu-Collections",
        companions = "UI-HUD-MicroMenu-Collections",
        ej = "UI-HUD-MicroMenu-EncounterJournal",    -- placeholder
        store = "UI-HUD-MicroMenu-Shop",
        mainmenu = "UI-HUD-MicroMenu-GameMenu"
    }
    return buttonMap[buttonName]
end

-- Grayscale atlas names use a fixed prefix; custom button names must map to
-- the canonical atlas name (e.g. DragonUIGuild -> guild).
local function GetGrayscaleAtlasName(buttonName)
    local map = {
        dragonuiguild = "guildcommunities",
        guild = "guildcommunities",
        socials = "guildcommunities",
        companions = "collections",
    }
    return map[buttonName] or buttonName
end

local function GetColoredTextureCoords(buttonName, textureType)
    local atlasKey = GetAtlasKey(buttonName)
    if not atlasKey then
        return nil
    end

    local coordsKey = atlasKey .. "-" .. textureType
    local coords = MicromenuAtlas[coordsKey]
    if coords and type(coords) == "table" and #coords >= 4 then
        return coords
    end
    return nil
end

-- Handler management
local function CaptureOriginalHandlers(button)
    local buttonName = button:GetName()
    if not originalBlizzardHandlers[buttonName] then
        originalBlizzardHandlers[buttonName] = {
            OnEnter = button:GetScript('OnEnter'),
            OnLeave = button:GetScript('OnLeave')
        }
    end
end

local function RestoreOriginalHandlers(button)
    local buttonName = button:GetName()
    local handlers = originalBlizzardHandlers[buttonName]
    if handlers then
        if handlers.OnEnter then
            button:SetScript('OnEnter', handlers.OnEnter)
        end
        if handlers.OnLeave then
            button:SetScript('OnLeave', handlers.OnLeave)
        end
    end
end

-- Loot animation helper
local function EnsureLootAnimationToMainBag()
    -- Simple approach: when bags are hidden, WoW should naturally redirect loot to main bag
end

-- Check whether any of the given frames is currently shown.
local function IsAnyShown(...)
    for i = 1, select("#", ...) do
        local f = select(i, ...)
        if f then
            -- pcall: some panels (e.g. StoreFrame) are forbidden frames and
            -- error if addon-tainted code calls methods on them.
            local ok, shown = pcall(f.IsShown, f)
            if ok and shown then
                return true
            end
        end
    end
    return false
end

-- Like IsAnyShown, but uses IsVisible so a container whose own shown flag stays
-- set (e.g. LFDParentFrame inside PVEFrame) is not treated as open.
local function IsAnyVisible(...)
    for i = 1, select("#", ...) do
        local f = select(i, ...)
        if f then
            local ok, visible = pcall(f.IsVisible, f)
            if ok and visible then
                return true
            end
        end
    end
    return false
end

-- GetButtonState/GetChecked are unreliable for micro buttons; use panel visibility.
local function IsSpecialMicroButtonActive(button, buttonName)
    if not button then return false end

    local key = string.lower(buttonName or "")

    if key == "character" then
        return IsAnyShown(_G.CharacterFrame, _G.PaperDollFrame)
    elseif key == "spellbook" then
        return IsAnyShown(_G.SpellBookFrame)
    elseif key == "talent" then
        return IsAnyShown(_G.PlayerTalentFrame, _G.TalentFrame)
    elseif key == "achievement" then
        return IsAnyShown(_G.AchievementFrame)
    elseif key == "questlog" then
        return IsAnyShown(_G.QuestLogFrame, _G.QuestFrame)
    elseif key == "guild" or key == "socials" then
        return IsAnyShown(_G.GuildFrame)
    elseif key == "lfd" then
        -- PVEFrame is the real MoP window; LFDParentFrame is an internal
        -- container whose IsShown() stays true even when the window is closed.
        return IsAnyVisible(_G.PVEFrame, _G.LFDParentFrame)
    elseif key == "collections" or key == "companions" then
        return IsAnyShown(_G.CollectionsJournal)
    elseif key == "ej" then
        return IsAnyShown(_G.EncounterJournal)
    elseif key == "store" then
        -- StoreFrame is a forbidden frame; don't query it (no safe API in MoP).
        return false
    elseif key == "mainmenu" then
        return IsAnyShown(_G.GameMenuFrame)
    elseif key == "pvp" then
        -- GetChecked is the PvP flag, not panel-open; use effective visibility
        -- on the real MoP window (PVPUIFrame) plus legacy fallbacks.
        return IsAnyVisible(_G.PVPUIFrame, _G.PVPFrame, _G.PVPParentFrame)
    end

    return button.GetButtonState and button:GetButtonState() == "PUSHED"
end

local function ApplyMicroButtonPushed(button, pushed)
    if not MicromenuModule.applied or not IsModuleEnabled() then
        return
    end
    if not button or not button.dragonUIState or button.dragonUILastState == pushed then
        return
    end

    button.dragonUILastState = pushed
    button.dragonUIState.pushed = pushed
    if button.HandleDragonUIState then
        button.HandleDragonUIState()
    end
end

local function SyncSpecialMicroButtonState(button, buttonName)
    if button and button.dragonUIState then
        local active = IsSpecialMicroButtonActive(button, buttonName) and true or false
        if addon.debugMode and button.dragonUILastState ~= active then
            addon:Print('DragonUI micromenu state: ' .. tostring(buttonName) .. ' -> ' .. tostring(active))
        end
        ApplyMicroButtonPushed(button, active)
    end
end

-- Recompute the active/pushed state for every replacement micro button. Called
-- from the UpdateMicroButtons hook and from the panel open/close hooks so
-- closing a panel (Dungeon Finder, PvP, ...) always returns its button to
-- normal. `tag` is optional and only used for debug logging.
local DEBUG_STATE_KEYS = { lfd = true, pvp = true, talent = true }
local function RefreshAllSpecialMicroButtonStates(tag)
    if not MicromenuModule.applied or not IsModuleEnabled() then return end
    for _, nativeButton in ipairs(GetMicroButtons()) do
        local replacement = replacementButtons[nativeButton]
        if replacement then
            local key = replacement._dragonUIButtonKey
            if tag and addon.debugMode and key and DEBUG_STATE_KEYS[key] then
                addon:Print('DragonUI micromenu refresh [' .. tostring(tag) .. '] '
                    .. tostring(key) .. ' active=' .. tostring(IsSpecialMicroButtonActive(replacement, key))
                    .. ' last=' .. tostring(replacement.dragonUILastState))
            end
            SyncSpecialMicroButtonState(replacement, key)
        end
    end
end

local function UpdateCharacterPortraitVisibility()
    if not MicromenuModule.applied or not IsModuleEnabled() then
        return
    end

    local useGrayscale = addon and addon.db and addon.db.profile and addon.db.profile.micromenu and addon.db.profile.micromenu.grayscale_icons
    local charBtn = _G.CharacterMicroButton
    local rep = charBtn and replacementButtons[charBtn]

    if not rep then return end

    -- Manage our own portrait texture on the replacement button.
    -- Do NOT call SetPortraitTexture here: this runs every UpdateMicroButtons
    -- (every frame) and recreating the 3D model each pass causes flicker.
    -- The portrait is set once in SetupCharacterButton and refreshed on
    -- UNIT_PORTRAIT_UPDATE instead.
    if rep.DragonUICharPortrait then
        if useGrayscale then
            rep.DragonUICharPortrait:Hide()
            rep.DragonUICharPortrait:SetAlpha(0)
        else
            rep.DragonUICharPortrait:Show()
        end
    end

    -- Kill template textures on the replacement every pass.
    if not useGrayscale then
        local nt = rep:GetNormalTexture()
        if nt then nt:SetTexture(nil) end
        local pt = rep:GetPushedTexture()
        if pt then pt:SetTexture(nil) end
        local ht = rep:GetHighlightTexture()
        if ht then ht:SetTexture(nil) end
    end

    -- Refresh character highlight so it stays in sync.
    if not useGrayscale and rep.DragonUICharHighlight and rep.DragonUICharPortrait then
        rep.DragonUICharHighlight:SetTexCoord(rep.DragonUICharPortrait:GetTexCoord())
        rep.DragonUICharHighlight:SetBlendMode('ADD')
        rep.DragonUICharHighlight:SetAlpha(0.5)
        rep.DragonUICharHighlight:SetAllPoints(rep.DragonUICharPortrait)
    end

    if rep.DragonUIBackground then
        local microTexture = 'Interface\\AddOns\\DragonUI\\Textures\\Micromenu\\uimicromenu2x'

        rep.DragonUIBackground:SetTexture(microTexture)
        rep.DragonUIBackground:SetTexCoord(0.0654297, 0.12793, 0.330078, 0.490234)
        if rep.DragonUIBackgroundPushed then
            rep.DragonUIBackgroundPushed:SetTexture(microTexture)
            rep.DragonUIBackgroundPushed:SetTexCoord(0.0654297, 0.12793, 0.494141, 0.654297)
        end

        if useGrayscale then
            rep.DragonUIBackground:Hide()
            if rep.DragonUIBackgroundPushed then
                rep.DragonUIBackgroundPushed:Hide()
            end
        else
            if rep.dragonUIState and rep.dragonUIState.pushed and rep.DragonUIBackgroundPushed then
                rep.DragonUIBackground:Hide()
                rep.DragonUIBackgroundPushed:Show()
            else
                rep.DragonUIBackground:Show()
                if rep.DragonUIBackgroundPushed then
                    rep.DragonUIBackgroundPushed:Hide()
                end
            end
        end
    end
end
-- ============================================================================
-- APPLY/RESTORE SYSTEM
-- ============================================================================

local function StoreOriginalMicroButtonStates()
    -- Store original positions and parents for all micro buttons
    for _, button in ipairs(GetMicroButtons()) do
        if button then -- Check if button exists (some custom clients may omit buttons)
            local buttonName = button:GetName()
            if not MicromenuModule.originalStates[buttonName] then
                MicromenuModule.originalStates[buttonName] = {
                    parent = button:GetParent(),
                    points = {},
                    size = {button:GetSize()},
                    scripts = {
                        OnEnter = button:GetScript('OnEnter'),
                        OnLeave = button:GetScript('OnLeave'),
                        OnClick = button:GetScript('OnClick'),
                        OnUpdate = button:GetScript('OnUpdate')
                    },
                    textures = {
                        normal = button:GetNormalTexture() and button:GetNormalTexture():GetTexture(),
                        pushed = button:GetPushedTexture() and button:GetPushedTexture():GetTexture(),
                        highlight = button:GetHighlightTexture() and button:GetHighlightTexture():GetTexture(),
                        disabled = button:GetDisabledTexture() and button:GetDisabledTexture():GetTexture()
                    },
                    SetPoint = button.SetPoint
                }
                -- Store all anchor points
                for i = 1, button:GetNumPoints() do
                    local point, relativeTo, relativePoint, x, y = button:GetPoint(i)
                    table.insert(MicromenuModule.originalStates[buttonName].points, {point, relativeTo, relativePoint, x, y})
                end
            end
        end
    end

    -- Also store state for buttons we do NOT style but may have touched previously
    -- (e.g. FriendsMicroButton, HelpMicroButton) so they can return to their native position.
    for _, name in ipairs(RESTORE_ONLY_BUTTON_NAMES) do
        local button = _G[name]
        if button and not MicromenuModule.originalStates[name] then
            MicromenuModule.originalStates[name] = {
                parent = button:GetParent(),
                points = {},
                size = {button:GetSize()},
                scripts = {
                    OnEnter = button:GetScript('OnEnter'),
                    OnLeave = button:GetScript('OnLeave'),
                    OnClick = button:GetScript('OnClick'),
                    OnUpdate = button:GetScript('OnUpdate')
                },
                textures = {
                    normal = button:GetNormalTexture() and button:GetNormalTexture():GetTexture(),
                    pushed = button:GetPushedTexture() and button:GetPushedTexture():GetTexture(),
                    highlight = button:GetHighlightTexture() and button:GetHighlightTexture():GetTexture(),
                    disabled = button:GetDisabledTexture() and button:GetDisabledTexture():GetTexture()
                },
                SetPoint = button.SetPoint
            }
            for i = 1, button:GetNumPoints() do
                local point, relativeTo, relativePoint, x, y = button:GetPoint(i)
                table.insert(MicromenuModule.originalStates[name].points, {point, relativeTo, relativePoint, x, y})
            end
        end
    end

    -- Store bag button states
    MicromenuModule.originalStates.MainMenuBarBackpackButton = {
        parent = MainMenuBarBackpackButton:GetParent(),
        points = {},
        size = {MainMenuBarBackpackButton:GetSize()},
        SetPoint = MainMenuBarBackpackButton.SetPoint
    }
    for i = 1, MainMenuBarBackpackButton:GetNumPoints() do
        local point, relativeTo, relativePoint, x, y = MainMenuBarBackpackButton:GetPoint(i)
        table.insert(MicromenuModule.originalStates.MainMenuBarBackpackButton.points,
            {point, relativeTo, relativePoint, x, y})
    end

    -- Store bag slots states
    for idx, bagSlot in pairs(bagslots) do
        local slotName = bagSlot:GetName()
        MicromenuModule.originalStates[slotName] = {
            parent = bagSlot:GetParent(),
            points = {},
            size = {bagSlot:GetSize()}
        }
        for i = 1, bagSlot:GetNumPoints() do
            local point, relativeTo, relativePoint, x, y = bagSlot:GetPoint(i)
            table.insert(MicromenuModule.originalStates[slotName].points, {point, relativeTo, relativePoint, x, y})
        end
    end

    -- Store KeyRingButton state
    if KeyRingButton then
        MicromenuModule.originalStates.KeyRingButton = {
            parent = KeyRingButton:GetParent(),
            points = {},
            size = {KeyRingButton:GetSize()}
        }
        for i = 1, KeyRingButton:GetNumPoints() do
            local point, relativeTo, relativePoint, x, y = KeyRingButton:GetPoint(i)
            table.insert(MicromenuModule.originalStates.KeyRingButton.points, {point, relativeTo, relativePoint, x, y})
        end
    end

    -- Store LFG frame states (WotLK or MoP)
    local lfgFrame = MiniMapLFGFrame or QueueStatusMinimapButton
    if lfgFrame then
        local frameName = MiniMapLFGFrame and "MiniMapLFGFrame" or "QueueStatusMinimapButton"
        MicromenuModule.originalStates[frameName] = {
            parent = lfgFrame:GetParent(),
            points = {},
            scale = lfgFrame:GetScale()
        }
        for i = 1, lfgFrame:GetNumPoints() do
            local point, relativeTo, relativePoint, x, y = lfgFrame:GetPoint(i)
            table.insert(MicromenuModule.originalStates[frameName].points, {point, relativeTo, relativePoint, x, y})
        end
    end

    -- Store LFG queue status frame state (QueueStatusFrame in MoP, LFDSearchStatus in WotLK)
    local queueStatusFrame = QueueStatusFrame or LFDSearchStatus
    if queueStatusFrame then
        MicromenuModule.originalStates.QueueStatusFrame = {
            parent = queueStatusFrame:GetParent(),
            points = {}
        }
        for i = 1, queueStatusFrame:GetNumPoints() do
            local point, relativeTo, relativePoint, x, y = queueStatusFrame:GetPoint(i)
            table.insert(MicromenuModule.originalStates.QueueStatusFrame.points, {point, relativeTo, relativePoint, x, y})
        end
    end
end

local function RestoreMicromenuSystem()
    if not MicromenuModule.applied then
        return
    end

    -- Unregister all state drivers
    for name, data in pairs(MicromenuModule.stateDrivers) do
        if data.frame then
            if InCombatLockdown() then
                if addon.CombatQueue then
                    addon.CombatQueue:Add("micromenu_restore_state_driver_" .. tostring(name), function()
                        if data.frame and data.state then
                            UnregisterStateDriver(data.frame, data.state)
                        end
                    end)
                end
            else
                UnregisterStateDriver(data.frame, data.state)
            end
        end
    end
    MicromenuModule.stateDrivers = {}

    -- Restore micro buttons to original state (styled + restore-only)
    local buttonsToRestore = GetMicroButtons()
    for _, name in ipairs(RESTORE_ONLY_BUTTON_NAMES) do
        local btn = _G[name]
        if btn then
            buttonsToRestore[#buttonsToRestore + 1] = btn
        end
    end
    for _, button in ipairs(buttonsToRestore) do
        if button then
            local buttonName = button:GetName()
            local original = MicromenuModule.originalStates[buttonName]

            if original then
                -- Restore SetPoint function if it was nooped
                if original.SetPoint then
                    button.SetPoint = original.SetPoint
                end

                -- Restore parent
                if original.parent then
                    button:SetParent(original.parent)
                end

                -- Clear and restore points
                button:ClearAllPoints()
                for _, pointData in ipairs(original.points) do
                    local point, relativeTo, relativePoint, x, y = unpack(pointData)
                    if relativeTo then
                        button:SetPoint(point, relativeTo, relativePoint, x, y)
                    else
                        button:SetPoint(point, relativePoint, x, y)
                    end
                end

                -- Restore size
                if original.size then
                    button:SetSize(unpack(original.size))
                end

                -- Restore textures
                if original.textures then
                    if original.textures.normal and button:GetNormalTexture() then
                        button:GetNormalTexture():SetTexture(original.textures.normal)
                    end
                    if original.textures.pushed and button:GetPushedTexture() then
                        button:GetPushedTexture():SetTexture(original.textures.pushed)
                    end
                    if original.textures.highlight and button:GetHighlightTexture() then
                        button:GetHighlightTexture():SetTexture(original.textures.highlight)
                    end
                    if original.textures.disabled and button:GetDisabledTexture() then
                        button:GetDisabledTexture():SetTexture(original.textures.disabled)
                    end
                end

                -- Restore scripts
                if original.scripts then
                    for scriptName, scriptFunc in pairs(original.scripts) do
                        button:SetScript(scriptName, scriptFunc)
                    end
                end

                -- Clean up DragonUI custom textures
                if button.DragonUIBackground then
                    button.DragonUIBackground:Hide()
                    button.DragonUIBackground = nil
                end
                if button.DragonUIBackgroundPushed then
                    button.DragonUIBackgroundPushed:Hide()
                    button.DragonUIBackgroundPushed = nil
                end
                if button.DragonUICharHighlight then
                    button.DragonUICharHighlight:Hide()
                    button.DragonUICharHighlight = nil
                end
                if button.DragonUICharPortrait then
                    button.DragonUICharPortrait:Hide()
                    button.DragonUICharPortrait = nil
                end
                if button.DragonUIPVPIcon then
                    button.DragonUIPVPIcon:Hide()
                    button.DragonUIPVPIcon = nil
                end

                if button == _G.CharacterMicroButton and MicroButtonPortrait then
                    MicroButtonPortrait:Show()
                    MicroButtonPortrait:SetAlpha(1)
                end

                -- Make sure the native button is visible and interactive again
                ShowNativeMicroButton(button)

                button.dragonUIState = nil
                button.dragonUIPanelPushed = nil
                button.dragonUILastState = nil
                button.HandleDragonUIState = nil
            end
        end
    end

    -- Restore MainMenuBarBackpackButton
    if MicromenuModule.originalStates.MainMenuBarBackpackButton then
        local original = MicromenuModule.originalStates.MainMenuBarBackpackButton

        if original.SetPoint then
            MainMenuBarBackpackButton.SetPoint = original.SetPoint
        end

        if original.parent then
            MainMenuBarBackpackButton:SetParent(original.parent)
        end

        MainMenuBarBackpackButton:ClearAllPoints()
        for _, pointData in ipairs(original.points) do
            local point, relativeTo, relativePoint, x, y = unpack(pointData)
            if relativeTo then
                MainMenuBarBackpackButton:SetPoint(point, relativeTo, relativePoint, x, y)
            else
                MainMenuBarBackpackButton:SetPoint(point, relativePoint, x, y)
            end
        end

        if original.size then
            MainMenuBarBackpackButton:SetSize(unpack(original.size))
        end
    end

    -- Restore bag slots
    for idx, bagSlot in pairs(bagslots) do
        local slotName = bagSlot:GetName()
        local original = MicromenuModule.originalStates[slotName]

        if original then
            if original.parent then
                bagSlot:SetParent(original.parent)
            end

            bagSlot:ClearAllPoints()
            for _, pointData in ipairs(original.points) do
                local point, relativeTo, relativePoint, x, y = unpack(pointData)
                if relativeTo then
                    bagSlot:SetPoint(point, relativeTo, relativePoint, x, y)
                else
                    bagSlot:SetPoint(point, relativePoint, x, y)
                end
            end

            if original.size then
                bagSlot:SetSize(unpack(original.size))
            end
        end
    end

    -- Restore KeyRingButton
    if KeyRingButton and MicromenuModule.originalStates.KeyRingButton then
        local original = MicromenuModule.originalStates.KeyRingButton

        if original.parent then
            KeyRingButton:SetParent(original.parent)
        end

        KeyRingButton:ClearAllPoints()
        for _, pointData in ipairs(original.points) do
            local point, relativeTo, relativePoint, x, y = unpack(pointData)
            if relativeTo then
                KeyRingButton:SetPoint(point, relativeTo, relativePoint, x, y)
            else
                KeyRingButton:SetPoint(point, relativePoint, x, y)
            end
        end

        if original.size then
            KeyRingButton:SetSize(unpack(original.size))
        end
    end

    -- Restore LFG frame (WotLK or MoP)
    local lfgFrame = MiniMapLFGFrame or QueueStatusMinimapButton
    local frameName = MiniMapLFGFrame and "MiniMapLFGFrame" or "QueueStatusMinimapButton"
    if lfgFrame and MicromenuModule.originalStates[frameName] then
        local original = MicromenuModule.originalStates[frameName]

        if original.parent then
            lfgFrame:SetParent(original.parent)
        end
        lfgFrame:ClearAllPoints()
        for _, pointData in ipairs(original.points) do
            local point, relativeTo, relativePoint, x, y = unpack(pointData)
            if relativeTo then
                lfgFrame:SetPoint(point, relativeTo, relativePoint, x, y)
            else
                lfgFrame:SetPoint(point, relativePoint, x, y)
            end
        end

        if original.scale then
            lfgFrame:SetScale(original.scale)
        end

        -- Restore border
        if MiniMapLFGFrameBorder then
            MiniMapLFGFrameBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        end
        local lfgBorder = QueueStatusMinimapButton and QueueStatusMinimapButton.Border
        if lfgBorder and lfgBorder.SetTexture then
            lfgBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        end
    end

    -- When this module is disabled, release the eye and let the minimap module
    -- (if enabled) anchor it again to its minimap holder.
    if lfgFrame then
        ReleaseLFGEyeLocks(lfgFrame)
        if addon.MinimapModule then
            addon.MinimapModule.lfgFrameAnchored = false
        end
        if addon.RefreshMinimapSystem then
            addon:RefreshMinimapSystem()
        end
    end

    -- Restore LFG queue status frame
    local queueStatusFrame = QueueStatusFrame or LFDSearchStatus
    if queueStatusFrame and MicromenuModule.originalStates.QueueStatusFrame then
        local original = MicromenuModule.originalStates.QueueStatusFrame

        if original.parent then
            queueStatusFrame:SetParent(original.parent)
        end

        queueStatusFrame:ClearAllPoints()
        for _, pointData in ipairs(original.points) do
            local point, relativeTo, relativePoint, x, y = unpack(pointData)
            if relativeTo then
                queueStatusFrame:SetPoint(point, relativeTo, relativePoint, x, y)
            else
                queueStatusFrame:SetPoint(point, relativePoint, x, y)
            end
        end
    end

    -- Hide custom frames
    if _G.pUiMicroMenu then
        _G.pUiMicroMenu:Hide()
    end
    if _G.pUiBagsBar then
        _G.pUiBagsBar:Hide()
    end
    if addon.pUiArrowManager then
        addon.pUiArrowManager:Hide()
    end

    -- Unregister all event frames
    for _, frame in pairs(MicromenuModule.eventFrames) do
        if frame and frame.UnregisterAllEvents then
            frame:UnregisterAllEvents()
        end
    end
    MicromenuModule.eventFrames = {}

    -- Hide cancels the latency AceTimer via OnHide before we drop the ref.
    local latencyBar = MicromenuModule.frames.latencyIndicator
    if latencyBar then
        latencyBar:Hide()
    end

    MicromenuModule.frames = {}
    MicromenuModule.hooks = {}
    MicromenuModule.applied = false
    addon.ReanchorLFDSearchStatus = nil

    -- Restore the native Guild button if we hid it.
    local nativeGuild = _G.GuildMicroButton
    if nativeGuild then
        nativeGuild.DragonUI_HiddenByMicroMenu = nil
        nativeGuild:Show()
    end

    -- Stop the guild hide scheduler and event frame.
    guildHideTimer = nil
    if MicromenuModule.guildEventFrame then
        MicromenuModule.guildEventFrame:UnregisterAllEvents()
        MicromenuModule.guildEventFrame:SetScript("OnEvent", nil)
        MicromenuModule.guildEventFrame = nil
    end

    -- Hide our secure replacement buttons and clean up portrait event frame.
    HideReplacementMicroButtons()
    if MicromenuModule.charPortraitEventFrame then
        MicromenuModule.charPortraitEventFrame:UnregisterAllEvents()
        MicromenuModule.charPortraitEventFrame:SetScript("OnEvent", nil)
        MicromenuModule.charPortraitEventFrame = nil
    end

    if UpdateMicroButtons then
        UpdateMicroButtons()
    end
end

-- WeakAuras/PlayerModel init can invalidate MicroButtonPortrait; re-apply on Blizzard refresh.
if UpdateMicroButtons then
    hooksecurefunc("UpdateMicroButtons", function()
        RefreshAllSpecialMicroButtonStates()
        UpdateCharacterPortraitVisibility()
    end)
end

-- Opening/closing a panel must always refresh the micro button states. Some
-- MoP clients do not route every panel (Dungeon Finder, PvP) through
-- UpdateMicroButtons on hide, which used to leave those buttons stuck active.
if ShowUIPanel then
    hooksecurefunc("ShowUIPanel", function() RefreshAllSpecialMicroButtonStates("ShowUIPanel") end)
end
if HideUIPanel then
    hooksecurefunc("HideUIPanel", function() RefreshAllSpecialMicroButtonStates("HideUIPanel") end)
end

-- The panels that were getting stuck are opened/closed through their own toggle
-- functions, not ShowUIPanel/HideUIPanel. Refresh after the visibility change.
do
    local toggleNames = {
        "ToggleLFDParentFrame",
        "TogglePVPUI",
        "TogglePVPFrame",
        "ToggleTalentFrame",
        "ToggleCharacter",
        "ToggleSpellBook",
        "ToggleEncounterJournal",
    }
    for _, name in ipairs(toggleNames) do
        if type(_G[name]) == "function" then
            hooksecurefunc(name, function()
                local tag = name
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, function() RefreshAllSpecialMicroButtonStates(tag) end)
                else
                    RefreshAllSpecialMicroButtonStates(tag)
                end
            end)
        end
    end
end



-- ============================================================================
-- MICRO MENU INTERNALS
-- ============================================================================
-- Frames and per-login state are created by ApplyMicromenuSystem(); they are declared
-- here so the functions below close over them at file scope.

local hidePendingTime = nil
local charPushHooksRegistered = false
local MICRO_LAYOUT_BASE_Y = 55
local hideFramesScheduler, pUiBagsBar, eventFrame3

local function HideUnwantedBagFrames()
    -- Process all secondary bag slots
    for i, bags in pairs(bagslots) do
        local bagName = bags:GetName()

        local possibleFrames = {bagName .. "Background", bagName .. "Border", bagName .. "Frame",
                                bagName .. "Texture", bagName .. "NormalTexture", bagName .. "Highlight", bagName .. "Glow", bagName .. "Green",
                                bagName .. "NormalTexture2", bagName .. "IconBorder", bagName .. "Flash",
                                bagName .. "NewItemTexture", bagName .. "Shine", bagName .. "NewItemGlow"}

        for _, frameName in pairs(possibleFrames) do
            local frame = _G[frameName]
            if frame and frame.Hide then
                frame:Hide()
                if frame.SetAlpha then
                    frame:SetAlpha(0)
                end
            end
        end

        local normalTexture = bags:GetNormalTexture()
        if normalTexture then
            normalTexture:SetAlpha(0)
            normalTexture:Hide()
        end

        -- Hide problematic texture regions
        local numRegions = bags:GetNumRegions()
        for j = 1, numRegions do
            local region = select(j, bags:GetRegions())
            if region and region:GetObjectType() == "Texture" then
                -- Keep DragonUI managed textures visible; only suppress
                -- Blizzard default layers.
                if region == bags.customBorder or region == bags.background then
                    region:Show()
                    if region.SetAlpha then
                        region:SetAlpha(1)
                    end
                else
                local texture = region:GetTexture()
                if texture then
                    local textureLower = tostring(texture):lower()
                    
                    -- Skip item icons - don't hide them
                    if textureLower:find("interface\\icons\\") then
                        -- This is an item icon - don't hide it
                    else
                        -- Hide only UI elements, not icons
                        if textureLower:find("background") or textureLower:find("border") or textureLower:find("frame") or
                            textureLower:find("highlight") or textureLower:find("green") or textureLower:find("glow") or
                            textureLower:find("flash") or textureLower:find("shine") then
                            region:Hide()
                            if region.SetAlpha then
                                region:SetAlpha(0)
                            end
                        end
                    end
                end
                end
            end
        end
    end

    -- Handle KeyRing with same approach
    if KeyRingButton then
        local keyRingName = KeyRingButton:GetName()
        local possibleFrames = {keyRingName .. "Background", keyRingName .. "Border", keyRingName .. "Frame",
                                keyRingName .. "Texture", keyRingName .. "Highlight", keyRingName .. "Glow",
                                keyRingName .. "Green", keyRingName .. "NormalTexture2",
                                keyRingName .. "IconBorder", keyRingName .. "Flash", keyRingName .. "Shine",
                                keyRingName .. "NewItemGlow"}

        for _, frameName in pairs(possibleFrames) do
            local frame = _G[frameName]
            if frame and frame.Hide then
                frame:Hide()
                if frame.SetAlpha then
                    frame:SetAlpha(0)
                end
            end
        end
    end
end

local function ScheduleHideFrames(delay)
    local target = GetTime() + (delay or 0)
    if hidePendingTime and hidePendingTime <= target then
        return -- an earlier execution is already pending
    end
    hidePendingTime = target

    if not hideFramesScheduler:GetScript("OnUpdate") then
        hideFramesScheduler:SetScript("OnUpdate", function(self)
            if hidePendingTime and GetTime() >= hidePendingTime then
                HideUnwantedBagFrames()
                hidePendingTime = nil
                self:SetScript("OnUpdate", nil)
            end
        end)
    end
end

local guildHideTimer

local function HideNativeGuildButton()
    local nativeGuild = _G.GuildMicroButton
    if not nativeGuild then
        return
    end
    nativeGuild:Hide()
    nativeGuild.DragonUI_HiddenByMicroMenu = true
    if not nativeGuild.DragonUI_ShowHooked then
        nativeGuild:HookScript("OnShow", function(self)
            if IsModuleEnabled() then
                self:Hide()
            end
        end)
        nativeGuild.DragonUI_ShowHooked = true
    end
end

local function StartGuildHideScheduler()
    if guildHideTimer then
        return
    end
    local count = 0
    local function tick()
        if not IsModuleEnabled() then
            guildHideTimer = nil
            return
        end
        HideNativeGuildButton()
        count = count + 1
        if count < 10 then
            guildHideTimer = addon.core:ScheduleTimer(tick, 0.2)
        else
            guildHideTimer = nil
        end
    end
    tick()
end

local function AddSocialsMicroButtonIfNeeded()
    -- MoP 5.4.8 uses GuildMicroButton, but some clients/private servers still
    -- expose the old SocialsMicroButton. If the native guild button is missing,
    -- replace SocialsMicroButton in the same slot instead of creating a custom
    -- duplicate that would leave the native Socials button visible behind it.
    if _G.GuildMicroButton or not _G.SocialsMicroButton then
        return
    end

    for _, name in ipairs(MICRO_BUTTON_NAMES) do
        if name == "SocialsMicroButton" then
            return
        end
    end

    local insertIndex = #MICRO_BUTTON_NAMES + 1
    for i, name in ipairs(MICRO_BUTTON_NAMES) do
        if name == "QuestLogMicroButton" then
            insertIndex = i + 1
            break
        end
    end
    table.insert(MICRO_BUTTON_NAMES, insertIndex, "SocialsMicroButton")

    -- Capture the original state now so RestoreMicromenuSystem can put the
    -- native button back where it belongs when the module is disabled.
    StoreOriginalMicroButtonStates()
end

local function CreateGuildMicroButton()
    -- No longer creates a custom DragonUI guild button. We either use the
    -- native GuildMicroButton (preferred on MoP) or fall back to the native
    -- SocialsMicroButton. This avoids a duplicate guild/social icon on screen.
    AddSocialsMicroButtonIfNeeded()
end

local function SetupPVPButton(button)
    -- Mirror the Character button pattern:
    -- Instead of fighting WoW's internal NormalTexture alpha management,
    -- we create our own ARTWORK texture (DragonUIPVPIcon) that we control
    -- exclusively, just like Character uses MicroButtonPortrait.
    local microTexture = 'Interface\\AddOns\\DragonUI\\Textures\\Micromenu\\micropvp'
    local englishFaction = UnitFactionGroup('player')
    local backgroundTexture = 'Interface\\AddOns\\DragonUI\\Textures\\Micromenu\\uimicromenu2x'
    local buttonWidth, buttonHeight = button:GetSize()
    local dx, dy = -1, 1
    local offX, offY = button:GetPushedTextOffset()
    local sizeX, sizeY = buttonWidth, buttonHeight

    -- ---- Icon layer: our own ARTWORK texture, never touched by WoW's button system ----
    if not button.DragonUIPVPIcon then
        local icon = button:CreateTexture(nil, 'ARTWORK')
        button.DragonUIPVPIcon = icon
    end

    local icon = button.DragonUIPVPIcon
    if englishFaction == 'Alliance' then
        icon:SetTexture(microTexture)
        icon:SetTexCoord(0, 118 / 256, 0, 151 / 256)
    elseif englishFaction == 'Horde' then
        icon:SetTexture(microTexture)
        icon:SetTexCoord(118 / 256, 236 / 256, 0, 151 / 256)
    else
        -- Faction unknown: use atlas grayscale fallback
        icon:set_atlas('ui-hud-micromenu-pvp-up-2x')
    end
    icon:ClearAllPoints()
    icon:SetPoint('CENTER', button, 'CENTER', 0, 0)
    icon:SetSize(buttonWidth, buttonHeight)
    icon:SetAlpha(1.0)
    icon:Show()

    -- ---- Hover highlight: reuse GetHighlightTexture() with faction texture + BlendMode ADD
    -- WoW shows/hides this automatically on mouse enter/leave.
    local highlightTexture = button:GetHighlightTexture()
    if highlightTexture then
        if englishFaction == 'Alliance' then
            highlightTexture:SetTexture(microTexture)
            highlightTexture:SetTexCoord(0, 118 / 256, 0, 151 / 256)
        elseif englishFaction == 'Horde' then
            highlightTexture:SetTexture(microTexture)
            highlightTexture:SetTexCoord(118 / 256, 236 / 256, 0, 151 / 256)
        else
            highlightTexture:set_atlas('ui-hud-micromenu-pvp-mouseover-2x')
        end
        highlightTexture:ClearAllPoints()
        highlightTexture:SetAllPoints(button)
        highlightTexture:SetBlendMode('ADD')
        highlightTexture:SetAlpha(0.5)
    end

    -- ---- Background slot texture ----
    if not button.DragonUIBackground then
        local bg = button:CreateTexture(nil, 'BACKGROUND')
        bg:SetTexture(backgroundTexture)
        bg:SetSize(sizeX, sizeY + 1)
        bg:SetTexCoord(0.0654297, 0.12793, 0.330078, 0.490234)
        bg:SetPoint('CENTER', dx, dy)
        button.DragonUIBackground = bg

        local bgPushed = button:CreateTexture(nil, 'BACKGROUND')
        bgPushed:SetTexture(backgroundTexture)
        bgPushed:SetSize(sizeX, sizeY + 1)
        bgPushed:SetTexCoord(0.0654297, 0.12793, 0.494141, 0.654297)
        bgPushed:SetPoint('CENTER', dx + offX, dy + offY)
        bgPushed:Hide()
        button.DragonUIBackgroundPushed = bgPushed
    else
        button.DragonUIBackground:SetTexture(backgroundTexture)
        button.DragonUIBackground:SetTexCoord(0.0654297, 0.12793, 0.330078, 0.490234)
        button.DragonUIBackground:ClearAllPoints()
        button.DragonUIBackground:SetPoint('CENTER', dx, dy)
        button.DragonUIBackground:SetSize(sizeX, sizeY + 1)

        if button.DragonUIBackgroundPushed then
            button.DragonUIBackgroundPushed:SetTexture(backgroundTexture)
            button.DragonUIBackgroundPushed:SetTexCoord(0.0654297, 0.12793, 0.494141, 0.654297)
            button.DragonUIBackgroundPushed:ClearAllPoints()
            button.DragonUIBackgroundPushed:SetPoint('CENTER', dx + offX, dy + offY)
            button.DragonUIBackgroundPushed:SetSize(sizeX, sizeY + 1)
        end
    end

    -- ---- State tracking ----
    button.dragonUIState = button.dragonUIState or {}
    button.dragonUIState.pushed = IsSpecialMicroButtonActive(button, "PVP")
    button.dragonUILastState = button.dragonUIState.pushed

    -- ---- State handler: only manipulates DragonUIPVPIcon ----
    button.HandleDragonUIState = function()
        local pvpIcon = button.DragonUIPVPIcon
        local state = button.dragonUIState
        local hlTex = button:GetHighlightTexture()
        if state and state.pushed then
            if pvpIcon then
                pvpIcon:ClearAllPoints()
                pvpIcon:SetPoint('CENTER', button, 'CENTER', offX, offY)
                pvpIcon:SetAlpha(0.7)
            end
            if button.DragonUIBackground then
                button.DragonUIBackground:Hide()
            end
            if button.DragonUIBackgroundPushed then
                button.DragonUIBackgroundPushed:Show()
            end
            -- Shift highlight to match icon pushed displacement
            if hlTex then
                hlTex:ClearAllPoints()
                hlTex:SetPoint('TOPLEFT', button, 'TOPLEFT', offX, offY)
                hlTex:SetPoint('BOTTOMRIGHT', button, 'BOTTOMRIGHT', offX, offY)
            end
        else
            if pvpIcon then
                pvpIcon:ClearAllPoints()
                pvpIcon:SetPoint('CENTER', button, 'CENTER', 0, 0)
                pvpIcon:SetAlpha(1.0)
            end
            if button.DragonUIBackground then
                button.DragonUIBackground:Show()
            end
            if button.DragonUIBackgroundPushed then
                button.DragonUIBackgroundPushed:Hide()
            end
            if hlTex then
                hlTex:ClearAllPoints()
                hlTex:SetAllPoints(button)
            end
        end
    end

    -- ---- Mouse feedback (immediate response on click) ----
    if not button.DragonUIStateHooks then
        button:HookScript('OnMouseDown', function(self)
            if self.dragonUIState then
                self.dragonUIState.pushed = true
            end
            if self.HandleDragonUIState then
                self.HandleDragonUIState()
            end
        end)
        button:HookScript('OnMouseUp', function(self)
            local currentState = IsSpecialMicroButtonActive(self, "PVP")
            self.dragonUILastState = currentState
            if self.dragonUIState then
                self.dragonUIState.pushed = currentState
            end
            if self.HandleDragonUIState then
                self.HandleDragonUIState()
            end
        end)
        button.DragonUIStateHooks = true
    end

    -- Apply initial state
    button.HandleDragonUIState()
end

local function SetupCharacterButton(button)
    -- STEP 1: Create our own portrait texture on the replacement button.
    -- The native MicroButtonPortrait belongs to the hidden native button, so
    -- we cannot rely on it for the visible replacement.
    if not button.DragonUICharPortrait then
        local portrait = button:CreateTexture(nil, "ARTWORK")
        portrait:SetPoint('CENTER', button, 'CENTER', 0, -0.5)
        portrait:SetSize(18, 24)
        portrait:SetAlpha(1)
        button.DragonUICharPortrait = portrait
    end
    local portraitTexture = button.DragonUICharPortrait
    SetPortraitTexture(portraitTexture, "player")

    -- Hide Blizzard's native normal/pushed/highlight textures so they
    -- don't bleed through as a background after /reload.
    local nt = button:GetNormalTexture()
    if nt then nt:SetTexture(nil) end
    local pt = button:GetPushedTexture()
    if pt then pt:SetTexture(nil) end
    local ht = button:GetHighlightTexture()
    if ht then ht:SetTexture(nil) end
    local dt = button:GetDisabledTexture()
    if dt then dt:SetTexture(nil) end

    -- STEP 2: Hover highlight — OVERLAY with ADD blend.
    local function RefreshCharHighlight(btn)
        local hl = btn.DragonUICharHighlight
        local port = btn.DragonUICharPortrait
        if not hl or not port then return end
        SetPortraitTexture(hl, "player")
        hl:SetTexCoord(port:GetTexCoord())
        hl:SetBlendMode('ADD')
        hl:SetAlpha(1)
        hl:SetAllPoints(port)
    end

    if not button.DragonUICharHighlight then
        local hl = button:CreateTexture(nil, 'OVERLAY')
        hl:SetAllPoints(portraitTexture)
        hl:Hide()
        button.DragonUICharHighlight = hl

        button:HookScript('OnEnter', function(self)
            if self.DragonUICharHighlight then
                RefreshCharHighlight(self)
                self.DragonUICharHighlight:Show()
            end
        end)
        button:HookScript('OnLeave', function(self)
            if self.DragonUICharHighlight then
                self.DragonUICharHighlight:Hide()
            end
        end)
    end

    -- Global function hooks: sync highlight TexCoord and force portrait alpha.
    if not charPushHooksRegistered then
        hooksecurefunc('CharacterMicroButton_SetPushed', function()
            if not MicromenuModule.applied or not IsModuleEnabled() then
                return
            end

            local isGS = addon and addon.db and addon.db.profile
                and addon.db.profile.micromenu and addon.db.profile.micromenu.grayscale_icons
            if isGS then return end
            local rep = replacementButtons[CharacterMicroButton]
            if not rep then return end
            if rep.DragonUICharPortrait then rep.DragonUICharPortrait:SetAlpha(0.7) end
            local nt = rep:GetNormalTexture()
            if nt then nt:SetTexture(nil) end
            local pt = rep:GetPushedTexture()
            if pt then pt:SetTexture(nil) end
            local hl = rep.DragonUICharHighlight
            if hl and hl:IsShown() and rep.DragonUICharPortrait then
                hl:SetTexCoord(rep.DragonUICharPortrait:GetTexCoord())
            end
        end)
        hooksecurefunc('CharacterMicroButton_SetNormal', function()
            if not MicromenuModule.applied or not IsModuleEnabled() then
                return
            end

            local isGS = addon and addon.db and addon.db.profile
                and addon.db.profile.micromenu and addon.db.profile.micromenu.grayscale_icons
            if isGS then return end
            local rep = replacementButtons[CharacterMicroButton]
            if not rep then return end
            if rep.DragonUICharPortrait then rep.DragonUICharPortrait:SetAlpha(1) end
            local nt = rep:GetNormalTexture()
            if nt then nt:SetTexture(nil) end
            local pt = rep:GetPushedTexture()
            if pt then pt:SetTexture(nil) end
            local hl = rep.DragonUICharHighlight
            if hl and hl:IsShown() and rep.DragonUICharPortrait then
                hl:SetTexCoord(rep.DragonUICharPortrait:GetTexCoord())
            end
        end)
        charPushHooksRegistered = true
    end
    RefreshCharHighlight(button)
    button.DragonUICharHighlight:Hide()

    -- Keep highlight in sync when portrait model updates.
    if not MicromenuModule.charPortraitEventFrame then
        local f = CreateFrame("Frame")
        MicromenuModule.charPortraitEventFrame = f
        f:RegisterEvent("UNIT_PORTRAIT_UPDATE")
        f:SetScript("OnEvent", function(self, event, unit)
            if event ~= "UNIT_PORTRAIT_UPDATE" or unit ~= "player" then return end
            if not MicromenuModule.applied or not IsModuleEnabled() then return end
            local isGrayscale = addon and addon.db and addon.db.profile
                and addon.db.profile.micromenu and addon.db.profile.micromenu.grayscale_icons
            if isGrayscale then return end
            local rep = replacementButtons[CharacterMicroButton]
            if rep then
                if rep.DragonUICharPortrait then
                    SetPortraitTexture(rep.DragonUICharPortrait, "player")
                end
                RefreshCharHighlight(rep)
            end
        end)
    end

    -- STEP 3: Background only (like other buttons)
    if not button.DragonUIBackground then
        local microTexture = 'Interface\\AddOns\\DragonUI\\Textures\\Micromenu\\uimicromenu2x'
        local dx, dy = -1, 1
        local offX, offY = button:GetPushedTextOffset()
        local sizeX, sizeY = button:GetSize()

        local bg = button:CreateTexture(nil, 'BACKGROUND')
        bg:SetTexture(microTexture)
        bg:SetSize(sizeX, sizeY + 1)
        bg:SetTexCoord(0.0654297, 0.12793, 0.330078, 0.490234)
        bg:SetPoint('CENTER', dx, dy)
        button.DragonUIBackground = bg

        local bgPushed = button:CreateTexture(nil, 'BACKGROUND')
        bgPushed:SetTexture(microTexture)
        bgPushed:SetSize(sizeX, sizeY + 1)
        bgPushed:SetTexCoord(0.0654297, 0.12793, 0.494141, 0.654297)
        bgPushed:SetPoint('CENTER', dx + offX, dy + offY)
        bgPushed:Hide()
        button.DragonUIBackgroundPushed = bgPushed

        button.dragonUIState = {
            pushed = IsSpecialMicroButtonActive(button, "Character")
        }
        button.dragonUILastState = button.dragonUIState.pushed

        button.HandleDragonUIState = function()
            local state = button.dragonUIState
            if state and state.pushed then
                if button.DragonUICharPortrait then button.DragonUICharPortrait:SetAlpha(0.7) end
                bg:Hide()
                bgPushed:Show()
            else
                if button.DragonUICharPortrait then button.DragonUICharPortrait:SetAlpha(1) end
                bg:Show()
                bgPushed:Hide()
            end
        end

        button.HandleDragonUIState()
    else
        -- Re-apply geometry/visibility every pass to survive late Blizzard updates.
        local microTexture = 'Interface\\AddOns\\DragonUI\\Textures\\Micromenu\\uimicromenu2x'
        local dx, dy = -1, 1
        local offX, offY = button:GetPushedTextOffset()
        local sizeX, sizeY = button:GetSize()

        button.DragonUIBackground:SetTexture(microTexture)
        button.DragonUIBackground:SetTexCoord(0.0654297, 0.12793, 0.330078, 0.490234)
        button.DragonUIBackground:ClearAllPoints()
        button.DragonUIBackground:SetPoint('CENTER', dx, dy)
        button.DragonUIBackground:SetSize(sizeX, sizeY + 1)

        if button.DragonUIBackgroundPushed then
            button.DragonUIBackgroundPushed:SetTexture(microTexture)
            button.DragonUIBackgroundPushed:SetTexCoord(0.0654297, 0.12793, 0.494141, 0.654297)
            button.DragonUIBackgroundPushed:ClearAllPoints()
            button.DragonUIBackgroundPushed:SetPoint('CENTER', dx + offX, dy + offY)
            button.DragonUIBackgroundPushed:SetSize(sizeX, sizeY + 1)
        end

        button.dragonUIState = button.dragonUIState or { pushed = false }

        if button.HandleDragonUIState then
            button.HandleDragonUIState()
        end
    end
end

function MainMenuMicroButtonMixin:bagbuttons_setup()
    MicromenuModule.hooks = MicromenuModule.hooks or {}

    -- Setup main backpack button
    MainMenuBarBackpackButton:SetSize(50, 50)
    MainMenuBarBackpackButton:SetNormalTexture(nil)
    MainMenuBarBackpackButton:SetPushedTexture(nil)
    MainMenuBarBackpackButton:SetHighlightTexture ''
    MainMenuBarBackpackButton:SetCheckedTexture ''
    do
        local ht = MainMenuBarBackpackButton:GetHighlightTexture()
        ht:SetAllPoints()
        ht:SetBlendMode('ADD')
        ht:set_atlas('bag-main-highlight-2x')
        local ct = MainMenuBarBackpackButton:GetCheckedTexture()
        ct:SetAllPoints()
        ct:SetBlendMode('ADD')
        ct:SetDrawLayer('OVERLAY', 7)
        ct:set_atlas('bag-main-highlight-2x')
    end
    MainMenuBarBackpackButtonIconTexture:set_atlas('bag-main-2x')

    -- Backpack position is owned by the overlay; anchoring it here would fight it.
    MainMenuBarBackpackButtonCount:SetClearPoint('CENTER', MainMenuBarBackpackButton, 'BOTTOM', 0, 14)
    CharacterBag0Slot:SetClearPoint('RIGHT', MainMenuBarBackpackButton, 'LEFT', -14, -2)

    -- Setup KeyRingButton (WotLK only; key ring removed in MoP)
    if KeyRingButton then
        KeyRingButton:SetSize(34, 34)
        KeyRingButton:SetClearPoint('RIGHT', CharacterBag3Slot, 'LEFT', -4, 0)
        KeyRingButton:SetNormalTexture ''
        KeyRingButton:SetPushedTexture(nil)
        KeyRingButton:SetHighlightTexture ''
        KeyRingButton:SetCheckedTexture ''

        local highlight = KeyRingButton:GetHighlightTexture();
        highlight:SetAllPoints();
        highlight:SetBlendMode('ADD');
        highlight:SetAlpha(.4);
        highlight:set_atlas('bag-border-highlight-2x', true)
        KeyRingButton:GetNormalTexture():set_atlas('bag-reagent-border-2x')
        do
            local ct = KeyRingButton:GetCheckedTexture()
            ct:SetAllPoints()
            ct:SetBlendMode('ADD')
            ct:SetDrawLayer('OVERLAY', 7)
            ct:set_atlas('bag-border-highlight-2x')
        end
        -- Bagster replaces ContainerFrame_OnShow checked sync; highlight backpack/bag slots instead
        local function SyncKeyRingButton()
            if addon.BagsterModule and addon.BagsterModule.BagsterModule
                and addon.BagsterModule.BagsterModule.applied
                and addon.BagsterHighlightMainMenuBags then
                addon.BagsterHighlightMainMenuBags()
                return
            end
            if KeyRingButton then
                KeyRingButton:SetChecked(IsBagOpen(-2) and 1 or nil)
            end
        end

        if not MicromenuModule.hooks.KeyRingSyncHooks then
            hooksecurefunc("ToggleKeyRing", SyncKeyRingButton)
            hooksecurefunc("CloseAllBags", function()
                if addon.BagsterModule and addon.BagsterModule.BagsterModule
                    and addon.BagsterModule.BagsterModule.applied
                    and addon.BagsterHighlightMainMenuBags then
                    addon.BagsterHighlightMainMenuBags()
                    return
                end
                if KeyRingButton then
                    KeyRingButton:SetChecked(nil)
                end
            end)
            hooksecurefunc("ContainerFrame_OnHide", SyncKeyRingButton)
            MicromenuModule.hooks.KeyRingSyncHooks = true
        end

        local keyringIcon = KeyRingButtonIconTexture
        if keyringIcon then
            keyringIcon:ClearAllPoints()
            keyringIcon:SetPoint('TOPRIGHT', KeyRingButton, 'TOPRIGHT', -5, -2.9);
            keyringIcon:SetPoint('BOTTOMLEFT', KeyRingButton, 'BOTTOMLEFT', 2.9, 5);
            pcall(function()
                keyringIcon:SetTexCoord(.08, .92, .08, .92)
            end)
        end

        if KeyRingButtonCount then
            KeyRingButtonCount:SetClearPoint('CENTER', KeyRingButton, 'CENTER', 0, -10);
            KeyRingButtonCount:SetDrawLayer('OVERLAY')
        end
    end

    -- Setup individual bag slots
    for _, bags in pairs(bagslots) do
        bags:SetHighlightTexture ''
        bags:SetCheckedTexture ''
        bags:SetPushedTexture(nil)
        bags:SetNormalTexture ''
        bags:SetSize(28, 28)

        local normalTexture = bags:GetNormalTexture()
        if normalTexture then
            normalTexture:SetAlpha(0)
            normalTexture:Hide()
        end

        bags:GetCheckedTexture():SetAllPoints()
        bags:GetCheckedTexture():SetBlendMode('ADD')
        bags:GetCheckedTexture():SetDrawLayer('OVERLAY', 7)
        bags:GetCheckedTexture():set_atlas('bag-border-highlight-2x')

        local highlight = bags:GetHighlightTexture();
        highlight:SetAllPoints();
        highlight:SetBlendMode('ADD');
        highlight:SetAlpha(.4);
        highlight:set_atlas('bag-border-highlight-2x', true)

        local icon = _G[bags:GetName() .. 'IconTexture']
        if icon then
            icon:ClearAllPoints()
            icon:SetPoint('TOPRIGHT', bags, 'TOPRIGHT', -5, -2.9);
            icon:SetPoint('BOTTOMLEFT', bags, 'BOTTOMLEFT', 2.9, 5);
            pcall(function()
                icon:SetTexCoord(.08, .92, .08, .92)
            end)
        end

        if not bags.customBorder then
            bags.customBorder = bags:CreateTexture(nil, 'OVERLAY')
            bags.customBorder:SetPoint('CENTER')
            bags.customBorder:set_atlas('bag-border-2x', true)
        end
        bags.customBorder:Show()
        bags.customBorder:SetAlpha(1)

        local w, h = bags.customBorder:GetSize()
        if not bags.background then
            bags.background = bags:CreateTexture(nil, 'BACKGROUND')
            bags.background:SetSize(w, h)
            bags.background:SetPoint('CENTER')
            bags.background:SetTexture(addon._dir .. 'Bags\\bagslots2x')
            bags.background:SetTexCoord(295 / 512, 356 / 512, 64 / 128, 125 / 128)
        end
        bags.background:Show()
        bags.background:SetAlpha(1)

        local count = _G[bags:GetName() .. 'Count']
        count:SetClearPoint('CENTER', 0, -10);
        count:SetDrawLayer('OVERLAY')
    end

    if not pUiBagsBar.registeredInEditor then
        -- Calculate overlay size to exactly match the visible bag elements.
        -- Layout (right to left from backpack right edge):
        --   Backpack(50) + gap(14) + 4xBag(28)+3xgap(4) = 188
        --   + KeyRing gap(4) + KeyRing(34) = 226
        -- Keep the editor frame at max width so gaining the keyring after
        -- a reload does not shift center-anchored saved positions.
        local bagsOverlayWidth = 226
        local bagsOverlayHeight = 54

        -- Create container frame using the standard system
        local bagsFrame = addon.CreateUIFrame(bagsOverlayWidth, bagsOverlayHeight, "BagsBar")

        -- Apply position from database or use default
        local bagsConfig = addon.db and addon.db.profile.widgets and addon.db.profile.widgets.bagsbar
        if bagsConfig and bagsConfig.anchor then
            bagsFrame:SetPoint(bagsConfig.anchor or "BOTTOMRIGHT", UIParent, bagsConfig.anchor or "BOTTOMRIGHT",
                bagsConfig.posX or -3, bagsConfig.posY or 45)
        else
            bagsFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -3, 45)
        end

        -- Anchor backpack to the RIGHT edge of the overlay.
        -- The backpack is 50px wide; anchoring its RIGHT to the frame's
        -- RIGHT edge aligns it flush.  All other bags chain LEFT of the
        -- backpack, so the whole row fits perfectly inside the frame.
        MainMenuBarBackpackButton:SetParent(UIParent)
        MainMenuBarBackpackButton:ClearAllPoints()
        MainMenuBarBackpackButton:SetPoint("RIGHT", bagsFrame, "RIGHT", 0, 0)

        -- Hook so bags follow the container when it moves
        bagsFrame:HookScript("OnDragStop", function(self)
            MainMenuBarBackpackButton:ClearAllPoints()
            MainMenuBarBackpackButton:SetPoint("RIGHT", self, "RIGHT", 0, 0)
        end)

        bagsFrame:HookScript("OnShow", function(self)
            MainMenuBarBackpackButton:ClearAllPoints()
            MainMenuBarBackpackButton:SetPoint("RIGHT", self, "RIGHT", 0, 0)
        end)

        -- Defensive maintenance hook. Throttled to avoid per-frame work when the
        -- backpack button is already anchored correctly.
        bagsFrame._duiBackpackCheckElapsed = 0
        bagsFrame:HookScript("OnUpdate", function(self, elapsed)
            self._duiBackpackCheckElapsed = self._duiBackpackCheckElapsed + elapsed
            if self._duiBackpackCheckElapsed < 0.2 then
                return
            end

            self._duiBackpackCheckElapsed = 0
            if not MainMenuBarBackpackButton:GetPoint() then
                MainMenuBarBackpackButton:ClearAllPoints()
                MainMenuBarBackpackButton:SetPoint("RIGHT", self, "RIGHT", 0, 0)
            end
        end)

        addon:RegisterEditableFrame({
            name = "bagsbar",
            frame = bagsFrame,
            blizzardFrame = MainMenuBarBackpackButton,
            configPath = {"widgets", "bagsbar"},
            module = addon.BagsModule or {}
        })

        pUiBagsBar.registeredInEditor = true

    end

    EnsureLootAnimationToMainBag()
    HideUnwantedBagFrames()
    -- A single deferred pass handles any late-created child textures
    -- (e.g. addons styling bag slots after us). The debounced scheduler
    -- collapses any additional calls to a single execution.
    ScheduleHideFrames(1.0)
end

function MainMenuMicroButtonMixin:bagbuttons_reposition()
    local bagScale = addon.db and addon.db.profile and addon.db.profile.bags and addon.db.profile.bags.scale or 1.0
    MainMenuBarBackpackButton:SetScale(bagScale)

    CharacterBag0Slot:SetClearPoint('RIGHT', MainMenuBarBackpackButton, 'LEFT', -14, -2)

    if not GetBagCollapseState() then
        StopCollapsedSecondaryFade()
        -- Expanded state
        for i, bags in pairs(bagslots) do
            bags:Show()
            bags:SetAlpha(1)
            bags:SetFrameLevel(MainMenuBarBackpackButton:GetFrameLevel())
            bags:SetScale(1.0)
            bags:SetSize(28, 28)

            if i == 1 then
                -- Already positioned above
            elseif i == 2 then
                bags:SetClearPoint('RIGHT', CharacterBag0Slot, 'LEFT', -4, 0)
            elseif i == 3 then
                bags:SetClearPoint('RIGHT', CharacterBag1Slot, 'LEFT', -4, 0)
            elseif i == 4 then
                bags:SetClearPoint('RIGHT', CharacterBag2Slot, 'LEFT', -4, 0)
            end

            if bags.customBorder then
                bags.customBorder:SetAlpha(1)
            end
            if bags.background then
                bags.background:SetAlpha(1)
            end
        end

        if KeyRingButton then
            KeyRingButton:SetClearPoint('RIGHT', CharacterBag3Slot, 'LEFT', -4, 0)
            KeyRingButton:SetFrameLevel(MainMenuBarBackpackButton:GetFrameLevel())
            KeyRingButton:SetScale(1.0)
            KeyRingButton:SetSize(34, 34)
        end
    else
        -- Collapsed state - bags behind main bag
        local forceHideCollapsed = ShouldForceCollapsedSecondaryInvisible()
        if forceHideCollapsed then
            StopCollapsedSecondaryFade()
        end
        for i, bags in pairs(bagslots) do
            bags:Show()
            bags:SetAlpha(forceHideCollapsed and 0 or 1)
            bags:ClearAllPoints()
            bags:SetPoint('CENTER', MainMenuBarBackpackButton, 'CENTER', 0, 0)
            bags:SetFrameLevel(MainMenuBarBackpackButton:GetFrameLevel() - 1)

            if bags.customBorder then
                bags.customBorder:SetAlpha(forceHideCollapsed and 0 or 1)
            end
            if bags.background then
                bags.background:SetAlpha(forceHideCollapsed and 0 or 1)
            end

            local icon = _G[bags:GetName() .. 'IconTexture']
            if icon then
                icon:SetAlpha(forceHideCollapsed and 0 or 1)
            end
        end

        if KeyRingButton then
            KeyRingButton:ClearAllPoints()
            KeyRingButton:SetPoint('CENTER', MainMenuBarBackpackButton, 'CENTER', 0, 0)
            KeyRingButton:SetFrameLevel(MainMenuBarBackpackButton:GetFrameLevel() - 1)
        end

        if not forceHideCollapsed and addon.RefreshCollapsedSecondaryBagsVisibility and _G.pUiBagsBar then
            addon.RefreshCollapsedSecondaryBagsVisibility((_G.pUiBagsBar:GetAlpha() or 1) > 0.01)
        end
    end

end

function MainMenuMicroButtonMixin:bagbuttons_refresh()
    if _G.pUiBagsBar then
        for _, bags in pairs(bagslots) do
            if bags:GetParent() ~= _G.pUiBagsBar then
                bags:SetParent(_G.pUiBagsBar);
            end
        end
    end

    self:bagbuttons_setup();

    if KeyRingButton then
        if HasKey() then
            KeyRingButton:Show();
        else
            KeyRingButton:Hide();
        end
    end

    -- Update bag slot icons with delayed stabilization for reload timing.
    ScheduleBagSlotIconRefreshes()

    HideUnwantedBagFrames()
end

local function MigrateMicroIconSpacingToPadding()
    local mm = addon.db and addon.db.profile and addon.db.profile.micromenu
    if not mm or mm.spacing_is_padding then
        return
    end
    mm.spacing_is_padding = true
    -- Old values were origin-to-origin stride; convert once to edge padding.
    if mm.grayscale and mm.grayscale.icon_spacing ~= nil then
        mm.grayscale.icon_spacing = mm.grayscale.icon_spacing - 14
    end
    if mm.normal and mm.normal.icon_spacing ~= nil then
        mm.normal.icon_spacing = mm.normal.icon_spacing - 32
    end
end

local function CollectPresentMicroButtons()
    return GetMicroButtons()
end

local function GetMicroLayoutMetrics(config, useGrayscale, numButtons)
    local buttonWidth = useGrayscale and 14 or 32
    local buttonHeight = useGrayscale and 19 or 40
    local pad = tonumber(config.icon_spacing)
    if pad == nil then
        pad = useGrayscale and 1 or -6
    end
    local hStep = buttonWidth + pad
    local vStep = buttonHeight + pad
    local columns = math.floor(tonumber(config.columns) or 12)
    if columns < 1 then
        columns = 1
    end
    if numButtons < 1 then
        return buttonWidth, buttonHeight, hStep, vStep, 1, 1, buttonWidth, buttonHeight
    end
    if columns > numButtons then
        columns = numButtons
    end
    local rows = math.ceil(numButtons / columns)
    local totalWidth = columns * buttonWidth + (columns - 1) * pad
    local totalHeight = rows * buttonHeight + (rows - 1) * pad
    return buttonWidth, buttonHeight, hStep, vStep, columns, rows, totalWidth, totalHeight
end

local function LayoutMicroButtons()
    local menu = _G.pUiMicroMenu
    if not menu or not addon.db or not addon.db.profile or not addon.db.profile.micromenu then
        return
    end

    MigrateMicroIconSpacingToPadding()

    local useGrayscale = addon.db.profile.micromenu.grayscale_icons
    local config = addon.db.profile.micromenu[useGrayscale and "grayscale" or "normal"]
    if not config then
        return
    end

    local buttons = CollectPresentMicroButtons()
    local numButtons = #buttons
    if config.invert_order and numButtons > 1 then
        local reversed = {}
        for i = numButtons, 1, -1 do
            reversed[#reversed + 1] = buttons[i]
        end
        buttons = reversed
    end

    local _, _, hStep, vStep, columns, _, totalWidth, totalHeight =
        GetMicroLayoutMetrics(config, useGrayscale, numButtons)

    local inCombat = InCombatLockdown()
    for i = 1, numButtons do
        local nativeButton = buttons[i]
        local replacement = nativeButton and replacementButtons[nativeButton]
        local idx = i - 1
        local x = (idx % columns) * hStep
        local y = MICRO_LAYOUT_BASE_Y + math.floor(idx / columns) * vStep

        if replacement and not inCombat then
            replacement:ClearAllPoints()
            replacement:SetPoint("BOTTOMLEFT", menu, "BOTTOMRIGHT", x, y)
        end
    end

    local menuScale = config.scale_menu or 1
    local overlayWidth = (totalWidth + 10) * menuScale
    local overlayHeight = (totalHeight + 10) * menuScale
    local menuOffX = -(totalWidth / 2)
    local menuOffY = -(MICRO_LAYOUT_BASE_Y + totalHeight / 2)

    menu.editorOffX = menuOffX
    menu.editorOffY = menuOffY

    if menu.editorFrame and not InCombatLockdown() then
        menu.editorFrame:SetSize(overlayWidth, overlayHeight)
        menu:ClearAllPoints()
        menu:SetPoint("BOTTOMRIGHT", menu.editorFrame, "CENTER", menuOffX, menuOffY)
    end
end

function addon.RefreshMicroMenuReplacementButtons()
    -- Re-run layout and refresh fade registration so replacement buttons are
    -- picked up after a profile change or module toggle.
    if not IsModuleEnabled() or not _G.pUiMicroMenu then return end
    LayoutMicroButtons()
    AnchorLFGEye()
    UpdateCharacterPortraitVisibility()
    if addon.RefreshActionBarVisibility then
        addon.RefreshActionBarVisibility()
    end
end

-- ============================================================================
-- MICRO-BUTTON REPLACEMENTS
-- Native Blizzard micro buttons are secure frames. Tainting them by replacing
-- SetPoint, reparenting, or overriding scripts causes "Interface action failed"
-- errors when the player later interacts with protected panels such as talents
-- or glyphs. To keep DragonUI styling while leaving the native buttons intact,
-- we create invisible replacement buttons using SecureActionButtonTemplate.
-- Each replacement forwards the click to its native button by name (type="click"
-- + clickbutton), so the panel opens through a clean, protected code path.
-- ============================================================================

local function IsCustomDragonUIButton(button)
    local name = button and button:GetName() or ""
    return name:find("^DragonUI") ~= nil
end

local function GetReplacementMicroButton(nativeButton, buttonKey)
    if not nativeButton then return nil end
    if replacementButtons[nativeButton] then
        return replacementButtons[nativeButton]
    end

    -- Custom DragonUI buttons (e.g. the Guild replacement) are already ours;
    -- use them directly instead of wrapping them in another proxy.
    if IsCustomDragonUIButton(nativeButton) then
        replacementButtons[nativeButton] = nativeButton
        return nativeButton
    end

    local nativeName = nativeButton:GetName() or "UnknownMicroButton"
    local replacementName = "DragonUI_" .. nativeName

    local menu = _G.pUiMicroMenu or UIParent
    local replacement
    if DIRECT_OPEN_BUTTONS[buttonKey] then
        -- Native frame has no OnClick script (secure native button), so "/click"
        -- cannot fire it while hidden. Open the panel directly from a plain Button.
        replacement = CreateFrame("Button", replacementName, menu)
        replacement:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local nativeOnClick = nativeButton:GetScript("OnClick")
        replacement:SetScript("OnClick", function(self, mouseButton)
            -- Prefer the native OnClick handler when it exists (e.g. Companions),
            -- and fall back to the direct opener otherwise (secure native buttons).
            local native = self._dragonUINativeButton
            local oc = nativeOnClick
            if native then
                oc = oc or native:GetScript("OnClick")
            end
            if oc then
                local ok = pcall(oc, native, mouseButton)
                if ok then return end
            end
            local opener = buttonKey and MICRO_BUTTON_OPENERS[buttonKey]
            if opener then
                pcall(opener)
            end
        end)
    else
        replacement = CreateFrame("Button", replacementName, menu, "SecureActionButtonTemplate")
        replacement:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- Redirect the click to the native button via a secure macro. The macro runs
        -- in SecureActionButtonTemplate's protected context, so "/click Name" fires
        -- the native OnClick without tainting the panel it opens.
        replacement:SetAttribute("type", "macro")
        replacement:SetAttribute("macrotext", "/click " .. nativeName)
    end
    replacement:SetHitRectInsets(0, 0, 0, 0)
    replacement:EnableMouse(true)

    replacement._dragonUINativeButton = nativeButton
    replacement._dragonUIButtonKey = buttonKey

    -- Attach tooltip scripts. Prefer the native button's text fields so the
    -- tooltip is anchored to our replacement and matches Blizzard's wording.
    local tooltipText = nativeButton.tooltipText
    local newbieText = nativeButton.newbieText
    if tooltipText or newbieText then
        replacement:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if tooltipText then
                GameTooltip:SetText(tooltipText, 1, 1, 1)
            end
            if newbieText then
                GameTooltip:AddLine(newbieText, 0.7, 0.7, 0.7, true)
            end
            GameTooltip:Show()
        end)
        replacement:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)
    end

    replacementButtons[nativeButton] = replacement
    return replacement
end

local function HideNativeMicroButton(nativeButton)
    if not nativeButton or IsCustomDragonUIButton(nativeButton) then return end
    -- Only hide/alpha the native button. Do NOT replace SetPoint, reparent, or
    -- override scripts — any of those taints the secure frame and causes
    -- "Interface action failed" errors later.
    nativeButton:Hide()
    nativeButton:SetAlpha(0)
end

local function ShowNativeMicroButton(nativeButton)
    if not nativeButton or IsCustomDragonUIButton(nativeButton) then return end
    nativeButton:Show()
    nativeButton:SetAlpha(1)
end

local function HideReplacementMicroButtons()
    for _, replacement in pairs(replacementButtons) do
        replacement:Hide()
    end
end

local function ShowReplacementMicroButtons()
    for _, replacement in pairs(replacementButtons) do
        replacement:Show()
    end
end

function addon.GetMicroMenuReplacementButton(nativeButton)
    return nativeButton and replacementButtons[nativeButton]
end

function addon.GetMicroMenuReplacementButtons()
    local list = {}
    for _, replacement in pairs(replacementButtons) do
        table.insert(list, replacement)
    end
    return list
end

local function setupMicroButtons(xOffset)
    MigrateMicroIconSpacingToPadding()

    local useGrayscale = addon.db.profile.micromenu.grayscale_icons
    local configMode = useGrayscale and "grayscale" or "normal"
    local config = addon.db.profile.micromenu[configMode]

    local menuScale = config.scale_menu

    local menu = _G.pUiMicroMenu
    if not menu then
        menu = CreateFrame('Frame', 'pUiMicroMenu', UIParent)
    end
    menu:SetScale(menuScale)
    menu:SetSize(10, 10)

    local presentButtons = CollectPresentMicroButtons()
    local numButtons = #presentButtons
    local _, _, _, _, _, _, totalWidth, totalHeight =
        GetMicroLayoutMetrics(config, useGrayscale, numButtons)

    local overlayWidth = (totalWidth + 10) * menuScale
    local overlayHeight = (totalHeight + 10) * menuScale

    -- Offsets must stay unscaled: WoW multiplies SetPoint by the frame's own scale.
    local menuOffX = -(totalWidth / 2)
    local menuOffY = -(MICRO_LAYOUT_BASE_Y + totalHeight / 2)

    if not menu.registeredInEditor then
        -- PATTERN: Overlay = position anchor, real UI anchored TO overlay
        -- Same as PlayerFrame, TargetFrame, CastBar, etc.
        local microMenuFrame = addon.CreateUIFrame(overlayWidth, overlayHeight, "MicroMenu")

        -- Position the OVERLAY from saved config or defaults
        local microMenuConfig = addon.db and addon.db.profile.widgets and addon.db.profile.widgets.micromenu
        if microMenuConfig and microMenuConfig.posX and microMenuConfig.posY then
            microMenuFrame:SetPoint(microMenuConfig.anchor or "BOTTOMRIGHT", UIParent,
                microMenuConfig.anchor or "BOTTOMRIGHT",
                microMenuConfig.posX, microMenuConfig.posY)
        else
            microMenuFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT",
                xOffset + config.x_position, config.y_position)
        end

        -- Anchor the REAL menu TO the overlay (fixed offset based on button geometry)
        menu:SetParent(UIParent)
        menu:ClearAllPoints()
        menu:SetPoint("BOTTOMRIGHT", microMenuFrame, "CENTER", menuOffX, menuOffY)

        -- Store reference and offsets for re-anchoring
        menu.editorFrame = microMenuFrame
        menu.editorOffX = menuOffX
        menu.editorOffY = menuOffY

        addon:RegisterEditableFrame({
            name = "micromenu",
            frame = microMenuFrame,
            blizzardFrame = menu,
            configPath = {"widgets", "micromenu"},
            module = addon.MicroMenuModule or {},
            onHide = function()
                -- Re-anchor menu when leaving editor mode (overlay may have been dragged)
                menu:ClearAllPoints()
                menu:SetPoint("BOTTOMRIGHT", microMenuFrame, "CENTER",
                    menu.editorOffX or menuOffX, menu.editorOffY or menuOffY)
            end
        })

        menu.registeredInEditor = true
    else
        -- Subsequent calls: re-anchor to existing overlay
        if menu.editorFrame then
            menu:ClearAllPoints()
            menu:SetPoint("BOTTOMRIGHT", menu.editorFrame, "CENTER", menuOffX, menuOffY)
            menu.editorFrame:SetSize(overlayWidth, overlayHeight)
            menu.editorOffX = menuOffX
            menu.editorOffY = menuOffY
        end
    end

    local function EnsureButtonTexture(btn, getter, setter, layer)
        local tex = getter(btn)
        if not tex then
            tex = btn:CreateTexture(nil, layer or "ARTWORK")
            if setter then setter(btn, tex) end
        end
        return tex
    end

    for _, nativeButton in ipairs(GetMicroButtons()) do
        if nativeButton then
            local buttonName = nativeButton:GetName():gsub('MicroButton', '')
            local name = string.lower(buttonName)

            -- Create a secure replacement button that clicks the native button
            -- without tainting it.
            local replacement = GetReplacementMicroButton(nativeButton, name)
            if not replacement then return end

            HideNativeMicroButton(nativeButton)

            replacement:Show()
            replacement:SetParent(menu)
            replacement:SetFrameStrata(menu:GetFrameStrata())
            replacement:SetFrameLevel((menu:GetFrameLevel() or 1) + 5)
            replacement:SetHitRectInsets(0, 0, 0, 0)

            local isPVPButton = (buttonName == "PVP")
            local isCharacterButton = (buttonName == "Character")
            local upCoords = not isCharacterButton and GetColoredTextureCoords(name, "Up") or nil
            -- PVP uses its own custom texture (SetupPVPButton), so don't fall
            -- back to grayscale sizing just because it lacks a colored atlas.
            local hasCustomArt = isPVPButton
            local shouldUseGrayscale = useGrayscale or (not upCoords and not isCharacterButton and not hasCustomArt)

            if shouldUseGrayscale then
                replacement:SetSize(14, 19)
            else
                replacement:SetSize(32, 40)
            end

            replacement:texture_strip()

            -- Ensure state textures exist on the replacement
            EnsureButtonTexture(replacement, replacement.GetNormalTexture, replacement.SetNormalTexture, "ARTWORK")
            EnsureButtonTexture(replacement, replacement.GetPushedTexture, replacement.SetPushedTexture, "ARTWORK")
            EnsureButtonTexture(replacement, replacement.GetHighlightTexture, replacement.SetHighlightTexture, "HIGHLIGHT")
            EnsureButtonTexture(replacement, replacement.GetDisabledTexture, replacement.SetDisabledTexture, "ARTWORK")

            if isPVPButton then
                if replacement.Flash then
                    replacement.Flash:Hide()
                end
                SetupPVPButton(replacement)
            elseif isCharacterButton then
                SetupCharacterButton(replacement)
            else
                -- Grayscale or colored icons
                local microTexture = 'Interface\\AddOns\\DragonUI\\Textures\\Micromenu\\uimicromenu2x'

                if shouldUseGrayscale then
                    -- Grayscale icons
                    local atlasName = GetGrayscaleAtlasName(name)
                    local normalTexture = replacement:GetNormalTexture()
                    local pushedTexture = replacement:GetPushedTexture()
                    local disabledTexture = replacement:GetDisabledTexture()
                    local highlightTexture = replacement:GetHighlightTexture()

                    if normalTexture then
                        normalTexture:set_atlas('ui-hud-micromenu-' .. atlasName .. '-up-2x')
                    end
                    if pushedTexture then
                        pushedTexture:set_atlas('ui-hud-micromenu-' .. atlasName .. '-down-2x')
                    end
                    if disabledTexture then
                        disabledTexture:set_atlas('ui-hud-micromenu-' .. atlasName .. '-disabled-2x')
                    end
                    if highlightTexture then
                        highlightTexture:set_atlas('ui-hud-micromenu-' .. atlasName .. '-mouseover-2x')
                    end
                else
                    -- Colored icons
                    local downCoords = GetColoredTextureCoords(name, "Down")
                    local disabledCoords = GetColoredTextureCoords(name, "Disabled")
                    local mouseoverCoords = GetColoredTextureCoords(name, "Mouseover")

                    if upCoords and #upCoords >= 4 then
                        local tex = replacement:GetNormalTexture()
                        tex:SetTexture(microTexture)
                        tex:SetTexCoord(upCoords[1], upCoords[2], upCoords[3], upCoords[4])
                        tex:ClearAllPoints()
                        tex:SetAllPoints(replacement)
                    end

                    if downCoords and #downCoords >= 4 then
                        local tex = replacement:GetPushedTexture()
                        tex:SetTexture(microTexture)
                        tex:SetTexCoord(downCoords[1], downCoords[2], downCoords[3], downCoords[4])
                        tex:ClearAllPoints()
                        tex:SetAllPoints(replacement)
                    end

                    if disabledCoords and #disabledCoords >= 4 then
                        local tex = replacement:GetDisabledTexture()
                        tex:SetTexture(microTexture)
                        tex:SetTexCoord(disabledCoords[1], disabledCoords[2], disabledCoords[3], disabledCoords[4])
                        tex:ClearAllPoints()
                        tex:SetAllPoints(replacement)
                    end

                    if mouseoverCoords and #mouseoverCoords >= 4 then
                        local tex = replacement:GetHighlightTexture()
                        tex:SetTexture(microTexture)
                        tex:SetTexCoord(mouseoverCoords[1], mouseoverCoords[2], mouseoverCoords[3], mouseoverCoords[4])
                        tex:ClearAllPoints()
                        tex:SetAllPoints(replacement)
                    end
                end

                -- Add/update background
                if not replacement.DragonUIBackground then
                    local backgroundTexture = 'Interface\\AddOns\\DragonUI\\Textures\\Micromenu\\uimicromenu2x'
                    local dx, dy = -1, 1
                    local offX, offY = replacement:GetPushedTextOffset()
                    local sizeX, sizeY = replacement:GetSize()

                    local bg = replacement:CreateTexture(nil, 'BACKGROUND')
                    bg:SetTexture(backgroundTexture)
                    bg:SetSize(sizeX, sizeY + 1)
                    bg:SetTexCoord(0.0654297, 0.12793, 0.330078, 0.490234)
                    bg:SetPoint('CENTER', dx, dy)
                    replacement.DragonUIBackground = bg

                    local bgPushed = replacement:CreateTexture(nil, 'BACKGROUND')
                    bgPushed:SetTexture(backgroundTexture)
                    bgPushed:SetSize(sizeX, sizeY + 1)
                    bgPushed:SetTexCoord(0.0654297, 0.12793, 0.494141, 0.654297)
                    bgPushed:SetPoint('CENTER', dx + offX, dy + offY)
                    bgPushed:Hide()
                    replacement.DragonUIBackgroundPushed = bgPushed

                    local pushedNow = false
                    replacement.dragonUIState = {
                        pushed = pushedNow
                    }
                    replacement.dragonUILastState = pushedNow
                    replacement.dragonUIPanelPushed = pushedNow

                    replacement.HandleDragonUIState = function()
                        local state = replacement.dragonUIState
                        local hlTex = replacement:GetHighlightTexture()
                        local normalTex = replacement:GetNormalTexture()
                        local pushed = state and state.pushed
                        if normalTex then
                            if shouldUseGrayscale then
                                local atlasName = GetGrayscaleAtlasName(name)
                                normalTex:set_atlas('ui-hud-micromenu-' .. atlasName .. (pushed and '-down-2x' or '-up-2x'))
                            else
                                local coords = GetColoredTextureCoords(name, pushed and "Down" or "Up")
                                if coords and #coords >= 4 then
                                    normalTex:SetTexture(microTexture)
                                    normalTex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                                end
                            end
                        end
                        if pushed then
                            replacement.DragonUIBackground:Hide()
                            replacement.DragonUIBackgroundPushed:Show()
                            if hlTex then
                                hlTex:ClearAllPoints()
                                hlTex:SetPoint('TOPLEFT', replacement, 'TOPLEFT', offX, offY)
                                hlTex:SetPoint('BOTTOMRIGHT', replacement, 'BOTTOMRIGHT', offX, offY)
                            end
                        else
                            replacement.DragonUIBackground:Show()
                            replacement.DragonUIBackgroundPushed:Hide()
                            if hlTex then
                                hlTex:ClearAllPoints()
                                hlTex:SetAllPoints(replacement)
                            end
                        end
                    end
                    replacement.HandleDragonUIState()

                    if not replacement.DragonUIStateHooks then
                        replacement:HookScript("OnMouseDown", function(self)
                            ApplyMicroButtonPushed(self, true)
                        end)
                        replacement:HookScript("OnMouseUp", function(self)
                            local active = IsSpecialMicroButtonActive(self, self._dragonUIButtonKey) and true or false
                            ApplyMicroButtonPushed(self, active)
                        end)
                        replacement.DragonUIStateHooks = true
                    end

                    if not replacement.DragonUISetButtonStateHooked then
                        hooksecurefunc(replacement, "SetButtonState", function(self, state)
                            self.dragonUIPanelPushed = (state == "PUSHED")
                            -- Keep the pressed look while the mouse is down, and keep it
                            -- pressed when the associated panel is open.
                            local pushed = (state == "PUSHED")
                                or (IsSpecialMicroButtonActive(self, self._dragonUIButtonKey) and true or false)
                            ApplyMicroButtonPushed(self, pushed)
                        end)
                        replacement.DragonUISetButtonStateHooked = true
                    end
                else
                    -- Re-apply background geometry in case size changed
                    local backgroundTexture = 'Interface\\AddOns\\DragonUI\\Textures\\Micromenu\\uimicromenu2x'
                    local dx, dy = -1, 1
                    local offX, offY = replacement:GetPushedTextOffset()
                    local sizeX, sizeY = replacement:GetSize()
                    replacement.DragonUIBackground:SetTexture(backgroundTexture)
                    replacement.DragonUIBackground:SetTexCoord(0.0654297, 0.12793, 0.330078, 0.490234)
                    replacement.DragonUIBackground:ClearAllPoints()
                    replacement.DragonUIBackground:SetPoint('CENTER', dx, dy)
                    replacement.DragonUIBackground:SetSize(sizeX, sizeY + 1)
                    replacement.DragonUIBackground:Show()

                    replacement.DragonUIBackgroundPushed:SetTexture(backgroundTexture)
                    replacement.DragonUIBackgroundPushed:SetTexCoord(0.0654297, 0.12793, 0.494141, 0.654297)
                    replacement.DragonUIBackgroundPushed:ClearAllPoints()
                    replacement.DragonUIBackgroundPushed:SetPoint('CENTER', dx + offX, dy + offY)
                    replacement.DragonUIBackgroundPushed:SetSize(sizeX, sizeY + 1)
                    if replacement.dragonUIState and replacement.dragonUIState.pushed then
                        replacement.DragonUIBackground:Hide()
                        replacement.DragonUIBackgroundPushed:Show()
                    else
                        replacement.DragonUIBackgroundPushed:Hide()
                    end
                end

                local highlightTexture = replacement:GetHighlightTexture()
                if highlightTexture then
                    highlightTexture:SetBlendMode('ADD')
                    highlightTexture:SetAlpha(1)
                end
            end

            replacement:EnableMouse(true)
        end
    end
    LayoutMicroButtons()
    UpdateCharacterPortraitVisibility()

    -- Hook Blizzard's UpdateMicroButtons to keep native buttons hidden and our
    -- replacements positioned. We no longer touch native textures/methods.
    if not MicromenuModule.updateMicroButtonsHooked then
        hooksecurefunc("UpdateMicroButtons", function()
            if not MicromenuModule.applied or not IsModuleEnabled() then return end

            for _, nativeButton in ipairs(GetMicroButtons()) do
                if nativeButton and nativeButton:IsShown() then
                    HideNativeMicroButton(nativeButton)
                end
            end
            LayoutMicroButtons()
            UpdateCharacterPortraitVisibility()
        end)
        MicromenuModule.updateMicroButtonsHooked = true
    end

    -- Latency strip on MainMenu replacement button: green / yellow / red from GetNetStats.
    local showLatency = addon.db.profile.micromenu.show_latency_indicator
    local mainMenuReplacement = MainMenuMicroButton and replacementButtons[MainMenuMicroButton]
    if showLatency and mainMenuReplacement then
        if not MicromenuModule.frames.latencyIndicator then
            local latencyBar = CreateFrame("StatusBar", "DragonUIPerformanceBar", mainMenuReplacement)

            latencyBar:SetStatusBarTexture(addon._dir .. "Micromenu\\ui-mainmenubar-performancebar")
            latencyBar:SetStatusBarColor(0, 1, 0)
            latencyBar:GetStatusBarTexture():SetBlendMode("ADD")
            latencyBar:GetStatusBarTexture():SetDrawLayer("OVERLAY")

            latencyBar:EnableMouse(true)
            latencyBar:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                local _, _, latency = GetNetStats()
                latency = latency or 0
                GameTooltip:AddLine(L and L["Network"] or "Network", 1, 1, 1)
                GameTooltip:AddDoubleLine(L and L["Latency"] or "Latency", latency .. " ms", 1, 1, 1, 1, 1, 0)
                GameTooltip:Show()
            end)
            latencyBar:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            local function UpdateLatencyColor(self)
                local _, _, latency = GetNetStats()
                latency = latency or 0
                if latency > PERFORMANCEBAR_MEDIUM_LATENCY then
                    self:SetStatusBarColor(1, 0, 0)
                elseif latency > PERFORMANCEBAR_LOW_LATENCY then
                    self:SetStatusBarColor(1, 1, 0)
                else
                    self:SetStatusBarColor(0, 1, 0)
                end
            end

            latencyBar:SetScript("OnShow", function(self)
                UpdateLatencyColor(self)
                if not self.duiLatencyTimer and addon.core then
                    self.duiLatencyTimer = addon.core:ScheduleRepeatingTimer(UpdateLatencyColor,
                        PERFORMANCEBAR_UPDATE_INTERVAL or 10, self)
                end
            end)
            latencyBar:SetScript("OnHide", function(self)
                if self.duiLatencyTimer and addon.core then
                    addon.core:CancelTimer(self.duiLatencyTimer, true)
                    self.duiLatencyTimer = nil
                end
            end)

            -- Created shown; Hide so the Show() below fires OnShow and starts the timer.
            latencyBar:Hide()

            MicromenuModule.frames.latencyIndicator = latencyBar
        end

        local bar = MicromenuModule.frames.latencyIndicator
        bar:SetParent(mainMenuReplacement)
        bar:SetFrameStrata(mainMenuReplacement:GetFrameStrata())
        bar:SetFrameLevel(math.max(1, mainMenuReplacement:GetFrameLevel() - 1))

        local barW, barH, offX, offY
        if useGrayscale then
            barW, barH = 13, 36
            offX, offY = 0, -3
        else
            barW, barH = 22, 60
            offX, offY = 1, -6.5
        end

        bar:ClearAllPoints()
        bar:SetSize(barW, barH)
        bar:SetPoint("BOTTOM", mainMenuReplacement, "BOTTOM", offX, offY)

        bar:Show()
    elseif MicromenuModule.frames.latencyIndicator then
        MicromenuModule.frames.latencyIndicator:Hide()
    end

    -- Refresh fade registration now that replacement buttons exist.
    addon.RefreshMicroMenuReplacementButtons()
end

local function updateMicroButtonSpacing()
    LayoutMicroButtons()
end

function addon.RefreshMicromenuSpacing()
    updateMicroButtonSpacing()
end

function addon.RefreshMicromenuPosition()
if not _G.pUiMicroMenu then
    return
end

local menu = _G.pUiMicroMenu
local frameInfo = addon:GetEditableFrameInfo("micromenu")
if frameInfo and frameInfo.frame then
    -- Position the OVERLAY from saved config or defaults
    local microMenuConfig = addon.db and addon.db.profile.widgets and addon.db.profile.widgets.micromenu

    if microMenuConfig and microMenuConfig.posX and microMenuConfig.posY then
        frameInfo.frame:ClearAllPoints()
        frameInfo.frame:SetPoint(microMenuConfig.anchor or "BOTTOMRIGHT", UIParent,
            microMenuConfig.anchor or "BOTTOMRIGHT",
            microMenuConfig.posX, microMenuConfig.posY)
    else
        local useGrayscale = addon.db.profile.micromenu.grayscale_icons
        local configMode = useGrayscale and "grayscale" or "normal"
        local config = addon.db.profile.micromenu[configMode]
        local xOffset = IsAddOnLoaded('ezCollections') and -180 or -166

        frameInfo.frame:ClearAllPoints()
        frameInfo.frame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT",
            xOffset + config.x_position, config.y_position)
    end

    -- Re-anchor menu TO the overlay using stored offsets (unscaled; WoW applies frame scale automatically)
    local offX = menu.editorOffX or -(159)
    local offY = menu.editorOffY or -(75)
    menu:ClearAllPoints()
    menu:SetPoint("BOTTOMRIGHT", frameInfo.frame, "CENTER", offX, offY)
else
    -- Fallback: no editor frame registered yet
    local useGrayscale = addon.db.profile.micromenu.grayscale_icons
    local configMode = useGrayscale and "grayscale" or "normal"
    local config = addon.db.profile.micromenu[configMode]

    menu:SetScale(config.scale_menu)
    local xOffset = IsAddOnLoaded('ezCollections') and -180 or -166
    menu:ClearAllPoints()
    menu:SetPoint('BOTTOMLEFT', UIParent, 'BOTTOMRIGHT',
        xOffset + config.x_position, config.y_position)
end

updateMicroButtonSpacing()
end

function addon.RefreshBagsPosition()
    if not _G.pUiBagsBar then
        return
    end

    local scale = addon.db and addon.db.profile and addon.db.profile.bags and addon.db.profile.bags.scale
    if scale then
        _G.pUiBagsBar:SetScale(scale)
        MainMenuBarBackpackButton:SetScale(scale)
    end

    local frameInfo = addon:GetEditableFrameInfo("bagsbar")
    if frameInfo and frameInfo.frame then
        -- Apply position from database or use default
        local bagsConfig = addon.db and addon.db.profile.widgets and addon.db.profile.widgets.bagsbar
        if bagsConfig and bagsConfig.anchor then
            frameInfo.frame:ClearAllPoints()
            frameInfo.frame:SetPoint(bagsConfig.anchor or "BOTTOMRIGHT", UIParent,
                bagsConfig.anchor or "BOTTOMRIGHT", bagsConfig.posX or -3, bagsConfig.posY or 45)
        else
            frameInfo.frame:ClearAllPoints()
            frameInfo.frame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -3, 45)
        end

        -- Ensure bags follow the container — backpack flush to the
        -- RIGHT edge, all other bags chain leftward from it.
        MainMenuBarBackpackButton:ClearAllPoints()
        MainMenuBarBackpackButton:SetPoint("RIGHT", frameInfo.frame, "RIGHT", 0, 0)
    else
        -- Fallback to previous method if no container
        if not addon.db or not addon.db.profile or not addon.db.profile.bags then
            return
        end

        local bagsConfig = addon.db.profile.bags
        _G.pUiBagsBar:SetScale(bagsConfig.scale)

        local originalSetPoint = MainMenuBarBackpackButton.SetPoint
        if MainMenuBarBackpackButton.SetPoint == addon._noop then
            MainMenuBarBackpackButton.SetPoint = UIParent.SetPoint
        end

        MainMenuBarBackpackButton:ClearAllPoints()
        MainMenuBarBackpackButton:SetPoint('BOTTOMRIGHT', UIParent, 'BOTTOMRIGHT', bagsConfig.x_position,
            bagsConfig.y_position)

        if originalSetPoint == addon._noop then
            MainMenuBarBackpackButton.SetPoint = originalSetPoint
        end
    end
end

function addon.RefreshMicromenuVehicle()
    if not _G.pUiMicroMenu then
        return
    end

    if InCombatLockdown() then
        if addon.CombatQueue then
            addon.CombatQueue:Add("micromenu_refresh_vehicle", addon.RefreshMicromenuVehicle)
        end
        return
    end

    if addon.db.profile.micromenu.hide_on_vehicle then
        RegisterStateDriver(_G.pUiMicroMenu, 'visibility', '[vehicleui] hide;show')
    else
        UnregisterStateDriver(_G.pUiMicroMenu, 'visibility')
    end
end

function addon.RefreshBagsVehicle()
    if not _G.pUiBagsBar then
        return
    end

    if InCombatLockdown() then
        if addon.CombatQueue then
            addon.CombatQueue:Add("micromenu_refresh_bags_vehicle", addon.RefreshBagsVehicle)
        end
        return
    end

    if addon.db.profile.micromenu.hide_on_vehicle then
        RegisterStateDriver(_G.pUiBagsBar, 'visibility', '[vehicleui] hide;show')
    else
        UnregisterStateDriver(_G.pUiBagsBar, 'visibility')
    end
end

function addon.RefreshMicromenuIcons()
    -- Icon refresh handled in main setup
end

function addon.RefreshMicromenu()
if not addon.db or not addon.db.profile or not addon.db.profile.micromenu then
    return
end

if not _G.pUiMicroMenu then
    return
end

local useGrayscale = addon.db.profile.micromenu.grayscale_icons
local configMode = useGrayscale and "grayscale" or "normal"
local config = addon.db.profile.micromenu[configMode]

-- FIXED: Only apply scale, NOT position (editor handles that)
_G.pUiMicroMenu:SetScale(config.scale_menu)

-- REMOVED: Don't overwrite editor position
-- _G.pUiMicroMenu:ClearAllPoints()
-- _G.pUiMicroMenu:SetPoint('BOTTOMLEFT', UIParent, 'BOTTOMRIGHT', xOffset + config.x_position, config.y_position)

addon.RefreshMicromenuIcons()

LayoutMicroButtons()

addon.RefreshMicromenuVehicle()
UpdateCharacterPortraitVisibility()
end

function addon.RefreshBags()
    if not _G.pUiBagsBar then
        return
    end

    addon.RefreshBagsPosition();

    if MainMenuMicroButtonMixin.bagbuttons_refresh then
        MainMenuMicroButtonMixin:bagbuttons_refresh();
    end

    if addon.pUiArrowManager then
        local arrow = addon.pUiArrowManager
        local isCollapsed = GetBagCollapseState()
        local normal = arrow:GetNormalTexture()
        local pushed = arrow:GetPushedTexture()
        local highlight = arrow:GetHighlightTexture()

        local atlas = isCollapsed and 'bag-arrow-2x' or 'bag-arrow-invert-2x'
        if normal and normal.set_atlas then
            normal:set_atlas(atlas)
        end
        if pushed and pushed.set_atlas then
            pushed:set_atlas(atlas)
        end
        if highlight and highlight.set_atlas then
            highlight:set_atlas(atlas)
        end
        arrow:SetChecked(isCollapsed and true or nil)
    end

    MainMenuMicroButtonMixin:bagbuttons_reposition()
    addon.RefreshBagsVehicle();
end

local function ApplyLFGFrameStyle()
    -- WotLK 3.3.5a fallback
    if MiniMapLFGFrameIcon then
        MiniMapLFGFrameIcon:SetScale(1.5)
    end
    if MiniMapLFGFrameBorder then
        MiniMapLFGFrameBorder:SetTexture(nil)
    end
    if MiniMapLFGFrame and MiniMapLFGFrame.eye and MiniMapLFGFrame.eye.texture then
        MiniMapLFGFrame.eye.texture:SetTexture(addon._dir .. 'Micromenu\\uigroupfinderflipbookeye.tga')
    end

    -- MoP 5.4.8: QueueStatusMinimapButton
    -- The minimap module now styles and positions this button; the micromenu
    -- only keeps its native border hidden.
    local lfgBtn = QueueStatusMinimapButton
    if lfgBtn then
        local border = lfgBtn.Border or QueueStatusMinimapButtonBorder
        if border and border.SetTexture then
            border:SetTexture(nil)
        end
    end
end

local function ReanchorLFDStatus()
    local lfgFrame = MiniMapLFGFrame or QueueStatusMinimapButton
    local statusFrame = QueueStatusFrame or LFDSearchStatus
    if not statusFrame or not lfgFrame then
        return
    end
    local point, relativePoint, xOff, yOff = GetLFDStatusAnchorSpec(GetLFGTooltipPosition())
    statusFrame:ClearAllPoints()
    statusFrame:SetPoint(point, lfgFrame, relativePoint, xOff, yOff)
end

-- ============================================================================
-- DUNGEON/QUEUE EYE (QueueStatusMinimapButton) ON THE MICROMENU
-- The minimap module normally anchors this eye to the minimap. When the
-- micromenu module is active we own it instead: parent it under pUiMicroMenu
-- (so it follows the menu position, scale and editor) and anchor it at the
-- left end of the button row. Native OnClick/visibility are left untouched.
-- ============================================================================

local LFG_EYE_GAP = 6   -- px between the eye and the first micro button
local LFG_EYE_SIZE = 64 -- desired on-screen size of the eye (px)

local function GetLFGEye()
    return _G.QueueStatusMinimapButton or _G.MiniMapLFGFrame
end

-- Undo the SetPoint/ClearAllPoints locks the minimap module installed so the
-- eye can be moved here (and so Blizzard can still reparent/reposition it).
ReleaseLFGEyeLocks = function(eye)
    if eye.DragonUI_OrigSetPoint then
        eye.SetPoint = eye.DragonUI_OrigSetPoint
        eye.DragonUI_OrigSetPoint = nil
    end
    if eye.DragonUI_OrigClearAllPoints then
        eye.ClearAllPoints = eye.DragonUI_OrigClearAllPoints
        eye.DragonUI_OrigClearAllPoints = nil
    end
    eye.DragonUI_Locked = false
end

-- Leftmost visible replacement micro button, used to anchor the eye at the
-- start of the row regardless of invert_order / column settings.
local function GetLeftmostReplacement()
    local best, bestLeft
    for _, rep in pairs(replacementButtons) do
        if rep and rep.IsShown and rep:IsShown() and rep.GetLeft then
            local l = rep:GetLeft()
            if l and (not bestLeft or l < bestLeft) then
                best, bestLeft = rep, l
            end
        end
    end
    return best
end

AnchorLFGEye = function()
    if not IsModuleEnabled() then return end
    local ok, err = pcall(function()
        local menu = _G.pUiMicroMenu
        local eye = GetLFGEye()
        if not menu or not eye then return end

        ReleaseLFGEyeLocks(eye)

        -- Re-anchor the moment the eye is shown (queued) so it never flashes at
        -- its old minimap position.
        if not eye._duiMicromenuEyeHooked then
            eye._duiMicromenuEyeHooked = true
            eye:HookScript("OnShow", function()
                if IsModuleEnabled() then AnchorLFGEye() end
            end)
        end

        if eye:GetParent() ~= menu then
            eye:SetParent(menu)
        end

        -- Option A: never scale the frame (scaling it makes the dropdown menu
        -- and hover tooltip huge). Keep scale 1 and resize the button/icon.
        if eye.SetScale then eye:SetScale(1) end
        if eye.SetSize then eye:SetSize(LFG_EYE_SIZE, LFG_EYE_SIZE) end
        local icon = eye.Eye or eye.Icon or _G.QueueStatusMinimapButtonIcon
        if icon and icon.SetSize then
            icon:SetSize(LFG_EYE_SIZE, LFG_EYE_SIZE)
        end

        -- Extreme left of the micro button row: just before the leftmost
        -- button, vertically centered with it. Falls back to menu bottom-right.
        local first = GetLeftmostReplacement()
        eye:ClearAllPoints()
        if first then
            eye:SetPoint("RIGHT", first, "LEFT", -LFG_EYE_GAP, 0)
        else
            eye:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -LFG_EYE_GAP, MICRO_LAYOUT_BASE_Y)
        end
    end)
    if not ok and addon.debugMode then
        addon:Print('DragonUI AnchorLFGEye error: ' .. tostring(err))
    end
end


local function ApplyMicromenuSystem()
    if MicromenuModule.applied or not IsModuleEnabled() then
        return
    end

    -- Store original states first
    StoreOriginalMicroButtonStates()

    -- Create custom Guild micro button for this MoP client. The native
    -- GuildMicroButton has special visibility/alpha behavior that conflicts
    -- with DragonUI styling, so we replace it with a normal button.
    CreateGuildMicroButton()

    -- Ensure the native Guild button stays hidden while this module is active.
    -- The native button may be created lazily, so we hide it now, hook its
    -- OnShow, and run a short scheduler to catch late creation.
    HideNativeGuildButton()
    StartGuildHideScheduler()

    -- Event frame to keep the native Guild button hidden across guild state
    -- changes and reloads.
    if not MicromenuModule.guildEventFrame then
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_ENTERING_WORLD")
        f:RegisterEvent("GUILD_ROSTER_UPDATE")
        f:RegisterEvent("PLAYER_GUILD_UPDATE")
        f:SetScript("OnEvent", function(self, event)
            if IsModuleEnabled() then
                HideNativeGuildButton()
                StartGuildHideScheduler()
            end
        end)
        MicromenuModule.guildEventFrame = f
    end

    -- ============================================================================
    -- SECTION 4: BAG FRAME CLEANUP
    -- ============================================================================

    -- Frame cleanup scheduler (debounced).
    -- Collapses multiple calls within a burst into a single execution at the
    -- earliest requested time. Prevents redundant region scans when several
    -- callers schedule cleanup in quick succession.
    hideFramesScheduler = CreateFrame("Frame")

    -- ============================================================================
    -- SECTION 5: SPECIALIZED BUTTON SETUP
    -- ============================================================================

    -- Local flag: reset on every /reload (Lua state is wiped).
    -- Frame properties survive reload, but hooksecurefunc on globals don't.

    -- ============================================================================
    -- SECTION 6: MAIN SETUP FUNCTIONS
    -- ============================================================================

    -- Create global bags bar
    _G.pUiBagsBar = CreateFrame('Frame', 'pUiBagsBar', UIParent);
    pUiBagsBar = _G.pUiBagsBar;
    -- DON'T parent automatically - will be done in setup when necessary
    if KeyRingButton then
        KeyRingButton:SetParent(_G.CharacterBag3Slot);
    end

    -- Buttons layout as a grid; hover/combat visibility stays on pUiMicroMenu.

    -- ============================================================================
    -- SECTION 7: REFRESH FUNCTIONS
    -- ============================================================================

    -- ============================================================================
    -- SECTION 8: SPECIAL UI ELEMENTS
    -- ============================================================================

    -- Collapse arrow
    do
        local arrow = CreateFrame('CheckButton', 'pUiArrowManager', MainMenuBarBackpackButton)
        addon.pUiArrowManager = arrow
        arrow:SetSize(12, 18)
        arrow:SetPoint('RIGHT', MainMenuBarBackpackButton, 'LEFT', 0, -2)
        arrow:SetNormalTexture ''
        arrow:SetPushedTexture ''
        arrow:SetHighlightTexture ''
        arrow:RegisterForClicks('LeftButtonUp')

        local normal = arrow:GetNormalTexture()
        local pushed = arrow:GetPushedTexture()
        local highlight = arrow:GetHighlightTexture()

        arrow:SetScript('OnClick', function(self)
            local checked = self:GetChecked();
            if checked then
                normal:set_atlas('bag-arrow-2x')
                pushed:set_atlas('bag-arrow-2x')
                highlight:set_atlas('bag-arrow-2x')
                SetBagCollapseState(true)
                MainMenuMicroButtonMixin:bagbuttons_reposition()
            else
                normal:set_atlas('bag-arrow-invert-2x')
                pushed:set_atlas('bag-arrow-invert-2x')
                highlight:set_atlas('bag-arrow-invert-2x')
                SetBagCollapseState(false)
                MainMenuMicroButtonMixin:bagbuttons_reposition()
                UpdateBagSlotAlpha()
                ScheduleBagSlotIconRefreshes()
            end
        end)
    end

    -- LFG Frame customization
    -- Only refresh visual style here. The click handler is owned by minimap.lua
    -- (StyleQueueStatusButton) to avoid overwriting the proper BG/LFG dropdown
    -- behaviour on MoP 5.4.8.
    ApplyLFGFrameStyle()
    AnchorLFGEye()

    -- Keep Blizzard's LFD status text/layout ownership intact. We only
    -- re-anchor around the eye and avoid reparenting to prevent text regressions.

    addon.ReanchorLFDSearchStatus = ReanchorLFDStatus

    ReanchorLFDStatus()
    local updateFunc = (type(QueueStatusFrame_Update) == "function") and "QueueStatusFrame_Update"
                      or (type(LFDSearchStatus_Update) == "function") and "LFDSearchStatus_Update"
                      or nil
    if updateFunc and not MicromenuModule.hooks[updateFunc] then
        hooksecurefunc(updateFunc, function()
            ReanchorLFDStatus()
            AnchorLFGEye()
        end)
        MicromenuModule.hooks[updateFunc] = true
    end

    -- Blizzard reparents/repositions the queue eye on queue/BG state changes;
    -- re-anchor it to the micromenu whenever that can happen.
    if not MicromenuModule.eventFrames.lfgEye then
        local f = CreateFrame("Frame")
        f:RegisterEvent("LFG_QUEUE_STATUS_UPDATE")
        f:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
        f:RegisterEvent("PLAYER_ENTERING_WORLD")
        f:RegisterEvent("WORLD_MAP_UPDATE")
        f:SetScript("OnEvent", function()
            if IsModuleEnabled() then
                AnchorLFGEye()
                ReanchorLFDStatus()
            end
        end)
        MicromenuModule.eventFrames.lfgEye = f
    end

    -- ============================================================================
    -- SECTION 9: EVENT HANDLERS
    -- ============================================================================

    addon.package:RegisterEvents(function(self, event)
        if not IsModuleEnabled() then return end

        if event == 'BAG_UPDATE' then
            -- BAG_UPDATE fires frequently (e.g. every time ammo is consumed).
            -- Blizzard updates IconTexture automatically; only toggle KeyRing
            -- visibility and refresh slot alpha here.
            if KeyRingButton then
                if HasKey() then
                    if not KeyRingButton:IsShown() then
                        KeyRingButton:Show();
                    end
                else
                    if KeyRingButton:IsShown() then
                        KeyRingButton:Hide();
                    end
                end
            end

            UpdateBagSlotAlpha()
        end
    end, 'BAG_UPDATE');

    addon.package:RegisterEvents(function(self, event)
        if not IsModuleEnabled() then return end

        ScheduleBagSlotIconRefreshes()

        if KeyRingButton and HasKey() then
            KeyRingButton:Show()
        end

        HideUnwantedBagFrames()
    end, 'PLAYER_ENTERING_WORLD');

    -- NOTE: equipped-bag slot icons do not change when bag contents change;
    -- PLAYER_EQUIPMENT_CHANGED handles real bag swaps and triggers the full
    -- icon refresh there. The BAG_UPDATE handler above is intentionally
    -- lightweight to avoid unnecessary work on frequent inventory events.

    addon.package:RegisterEvents(function()
        local xOffset
        if IsAddOnLoaded('ezCollections') then
            xOffset = -180
            if _G.CollectionsMicroButton then
                _G.CollectionsMicroButton:UnregisterEvent('UPDATE_BINDINGS')
            end
        else
            xOffset = -166
        end

        setupMicroButtons(xOffset);

        if addon.RefreshBags then
            addon.RefreshBags();
        end

        addon.core:ScheduleTimer(function()
            -- Check if frames need to be registered
            if _G.pUiMicroMenu and not _G.pUiMicroMenu.registeredInEditor then
                -- Force re-setup to register frames
                setupMicroButtons(xOffset)
            end

            if _G.pUiBagsBar and not _G.pUiBagsBar.registeredInEditor then
                -- Force bags setup
                if MainMenuMicroButtonMixin.bagbuttons_setup then
                    MainMenuMicroButtonMixin:bagbuttons_setup()
                end
            end
        end, 0.5)
    end, 'PLAYER_LOGIN');

    -- Mark as applied
    MicromenuModule.applied = true

    -- Execute setup immediately only after login; pre-login passes can produce transient bad geometry.
    if IsLoggedIn() then
        local xOffset
        if IsAddOnLoaded('ezCollections') then
            xOffset = -180
            if _G.CollectionsMicroButton then
                _G.CollectionsMicroButton:UnregisterEvent('UPDATE_BINDINGS')
            end
        else
            xOffset = -166
        end

        setupMicroButtons(xOffset)

        if MainMenuMicroButtonMixin.bagbuttons_setup then
            MainMenuMicroButtonMixin:bagbuttons_setup()
        end

        if addon.RefreshBags then
            addon.RefreshBags()
        end

        if addon.RefreshMicromenu then
            addon.RefreshMicromenu()
        end

        -- Late stabilization pass for startup race conditions.
        addon.core:ScheduleTimer(function()
            if IsModuleEnabled() then
                setupMicroButtons(xOffset)
                if addon.RefreshMicromenu then addon.RefreshMicromenu() end
                if addon.RefreshBags then addon.RefreshBags() end
            end
        end, 0.2)
    end

    -- Setup all hooks
    -- WotLK 3.3.5a only: MoP 5.4.8 does not have MiniMapLFG_UpdateIsShown.
    if not MicromenuModule.hooks.MiniMapLFG_UpdateIsShown and type(MiniMapLFG_UpdateIsShown) == "function" then
        MicromenuModule.hooks.MiniMapLFG_UpdateIsShown = true
        hooksecurefunc('MiniMapLFG_UpdateIsShown', function()
            if IsModuleEnabled() then
                ApplyLFGFrameStyle()
            end
        end)
    end

    -- Keep native micro buttons hidden and our replacements positioned after
    -- Blizzard reorganizes the micro menu (e.g. when opening/closing the world map).
    if not MicromenuModule.hooks.UpdateMicroButtons and type(UpdateMicroButtons) == "function" then
        MicromenuModule.hooks.UpdateMicroButtons = true
        hooksecurefunc("UpdateMicroButtons", function()
            if not IsModuleEnabled() or not _G.pUiMicroMenu then return end
            for _, nativeButton in ipairs(CollectPresentMicroButtons()) do
                if nativeButton and nativeButton:IsShown() then
                    HideNativeMicroButton(nativeButton)
                end
                -- Re-apply PVP custom state to the replacement if Blizzard refreshed.
                local btnName = nativeButton and nativeButton:GetName()
                if btnName == "PVPMicroButton" then
                    local rep = nativeButton and replacementButtons[nativeButton]
                    if rep then SetupPVPButton(rep) end
                end
            end
            LayoutMicroButtons()
            UpdateCharacterPortraitVisibility()
            -- Keep the native Guild button hidden while DragonUI micromenu is active.
            -- The native button may be created lazily, so hide it unconditionally.
            HideNativeGuildButton()
        end)
    end

    -- Register all events
    -- NOTE: BAG_UPDATE is handled in SECTION 9 above. A second registration
    -- for the same event is intentionally omitted here to avoid duplicate
    -- work per inventory event.

    eventFrame3 = MicromenuModule.eventFrames.playerEquipmentChanged or CreateFrame("Frame")
    MicromenuModule.eventFrames.playerEquipmentChanged = eventFrame3
    addon.package:RegisterEvents(function(self, event, slotID)
        if not IsModuleEnabled() then return end

        -- Bag slot swaps (equipped container changes) must refresh icons explicitly.
        -- Container 0 is the backpack (no inventory slot); equipped bags are 1-4.
        if slotID and slotID >= ContainerIDToInventoryID(1) and slotID <= ContainerIDToInventoryID(4) then
            if MainMenuMicroButtonMixin.bagbuttons_setup then
                MainMenuMicroButtonMixin:bagbuttons_setup()
            end
            RefreshBagSlotIcons()
            UpdateBagSlotAlpha()
            HideUnwantedBagFrames()
        end
    end, 'PLAYER_EQUIPMENT_CHANGED')
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function addon.RefreshMicromenuSystem()
    if IsModuleEnabled() then
        if not MicromenuModule.applied then
            ApplyMicromenuSystem()
        end
        -- Refresh settings if already applied
        if addon.RefreshMicromenu then
            addon.RefreshMicromenu()
        end
        if addon.RefreshBags then
            addon.RefreshBags()
        end
    else
        if addon:ShouldDeferModuleDisable("micromenu", MicromenuModule) then
            return
        end
        RestoreMicromenuSystem()
    end
end

-- Keep all the existing refresh functions as they are
-- They will only work when the module is enabled
-- ============================================================================
-- Function to load default widget settings
-- ============================================================================

local function LoadDefaultWidgetSettings()
    -- Ensure widget configuration exists
    if not addon.db.profile.widgets then
        addon.db.profile.widgets = {}
    end

    if not addon.db.profile.widgets.micromenu then
        -- Calculate default position based on current configuration
        local useGrayscale = addon.db.profile.micromenu and addon.db.profile.micromenu.grayscale_icons
        local configMode = useGrayscale and "grayscale" or "normal"
        local config = addon.db.profile.micromenu and addon.db.profile.micromenu[configMode]

        if config then
            local xOffset = IsAddOnLoaded('ezCollections') and -180 or -166
            addon.db.profile.widgets.micromenu = {
                anchor = "BOTTOMRIGHT",
                posX = xOffset + config.x_position,
                posY = config.y_position
            }
        else
            -- Absolute fallback
            addon.db.profile.widgets.micromenu = {
                anchor = "BOTTOMRIGHT",
                posX = -166,
                posY = 4
            }
        end
    end
end
-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local function Initialize()
    if MicromenuModule.initialized then
        return
    end

    -- Ensure default widget coordinates exist before module setup runs.
    LoadDefaultWidgetSettings()

    -- Only apply if module is enabled
    if IsModuleEnabled() then
        -- Wait for PLAYER_LOGIN to apply system
        addon.package:RegisterEvents(function()
            ApplyMicromenuSystem()
        end, 'PLAYER_LOGIN')
    end

    MicromenuModule.initialized = true
end

-- Auto-initialize when addon loads
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, addonName)
    if addonName == "DragonUI" then
        Initialize()
        self:UnregisterAllEvents()
    end
end)
