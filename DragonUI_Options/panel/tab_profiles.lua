--[[
================================================================================
DragonUI Options Panel - Profiles Tab
================================================================================
Profile management using AceDB-3.0 API directly.
Provides: select profile, copy, delete, reset.
================================================================================
]]

local addon = DragonUI
if not addon then return end

local LO = addon.LO
local AceGUI = LibStub("AceGUI-3.0")
local C = addon.PanelControls
local Panel = addon.OptionsPanel

-- ============================================================================
-- PROFILES TAB BUILDER
-- ============================================================================

local function BuildProfilesTab(scroll)
    local db = addon.db
    if not db then
        C:AddLabel(scroll, "|cFFFF0000" .. LO["Database not available."] .. "|r")
        return
    end

    C:AddLabel(scroll, "|cffFFD700" .. LO["Profiles"] .. "|r", { color = C.Theme.textGold })
    C:AddDescription(scroll, LO["Save and switch between different configurations per character."])
    C:AddSpacer(scroll)

    -- ====================================================================
    -- CURRENT PROFILE
    -- ====================================================================
    local current = C:AddSection(scroll, LO["Current Profile"])

    local currentProfile = db:GetCurrentProfile()
    C:AddLabel(current, LO["Active: "] .. "|cff2dd4bf" .. currentProfile .. "|r")

    -- ====================================================================
    -- PROFILE ACTION HELPERS
    -- ====================================================================
    -- AceGUI fires widget callbacks through safecall, so any exception raised
    -- here is swallowed and looks like "nothing happened". Run every DB
    -- mutation under pcall and surface failures to chat instead.
    local function SafeProfileCall(fn, successMsg)
        local ok, err = pcall(fn)
        if ok then
            if successMsg then addon:Print(successMsg) end
            return true
        end
        addon:Error((LO["Profile operation failed."] or "Profile operation failed: ") .. tostring(err))
        return false
    end

    -- Rebuilding the tab synchronously from inside a dropdown's own
    -- OnValueChanged releases the very widget that is still dispatching the
    -- click. Defer the rebuild until the click fully unwinds, then offer the
    -- reload so the new profile name shows even if "Not Now" is chosen.
    local function FinishProfileAction(successMsg)
        if successMsg then addon:Print(successMsg) end
        addon.core:ScheduleTimer(function()
            if addon.OptionsPanel and addon.OptionsPanel.SelectTab then
                addon.OptionsPanel:SelectTab("profiles")
            end
        end, 0.1)
        StaticPopup_Show("DRAGONUI_RELOAD_UI")
    end

    -- ====================================================================
    -- SELECT / CREATE PROFILE
    -- ====================================================================
    local selectSection = C:AddSection(scroll, LO["Switch or Create Profile"])

    -- Build profile list for dropdown
    local function GetProfileList()
        local profiles = {}
        for _, name in ipairs(db:GetProfiles()) do
            profiles[name] = name
        end
        return profiles
    end

    -- Copying a profile into itself is an error in AceDB, so it never makes
    -- sense to offer the active profile as a copy source.
    local function GetCopyProfiles()
        local profiles = {}
        local current = db:GetCurrentProfile()
        for _, name in ipairs(db:GetProfiles()) do
            if name ~= current then
                profiles[name] = name
            end
        end
        return profiles
    end

    C:AddDropdown(selectSection, {
        label = LO["Select Profile"],
        getFunc = function() return db:GetCurrentProfile() end,
        setFunc = function(val)
            if not val or val == "" then return end
            if val == db:GetCurrentProfile() then return end
            if SafeProfileCall(function()
                db:SetProfile(val)
            end) then
                FinishProfileAction()
            end
        end,
        values = GetProfileList(),
    })

    -- New profile input
    local newName = AceGUI:Create("EditBox")
    newName:SetLabel(LO["New Profile Name"])
    newName:SetWidth(250)
    newName:SetCallback("OnEnterPressed", function(widget, event, text)
        if text and text ~= "" then
            if SafeProfileCall(function()
                db:SetProfile(text)
            end) then
                widget:SetText("")
                FinishProfileAction()
            end
        end
    end)
    selectSection:AddChild(newName)

    -- ====================================================================
    -- COPY FROM
    -- ====================================================================
    local copySection = C:AddSection(scroll, LO["Copy From"])

    C:AddDescription(copySection, (LO["Copies all settings from the selected profile into your current one. Switch to the target profile first to push your current settings into another profile."] or LO["Copies all settings from the selected profile into your current one."]))

    C:AddDropdown(copySection, {
        label = LO["Copy From"],
        getFunc = function() return nil end,
        setFunc = function(val)
            if not val or val == "" then return end
            if val == db:GetCurrentProfile() then
                addon:Print(LO["Warning:"] .. " " .. (LO["Cannot copy a profile into itself."] or "Cannot copy a profile into itself."))
                return
            end
            if SafeProfileCall(function()
                db:CopyProfile(val)
            end, (LO["Copied profile: "] or "Copied profile: ") .. val) then
                FinishProfileAction()
            end
        end,
        values = GetCopyProfiles(),
    })

    -- ====================================================================
    -- DELETE
    -- ====================================================================
    local deleteSection = C:AddSection(scroll, LO["Delete Profile"])

    C:AddDescription(deleteSection, "|cffFF6600" .. LO["Warning:"] .. "|r " .. LO["Warning: Deleting a profile is permanent and cannot be undone."])

    -- Build list excluding current
    local function GetDeletableProfiles()
        local profiles = {}
        local current = db:GetCurrentProfile()
        for _, name in ipairs(db:GetProfiles()) do
            if name ~= current then
                profiles[name] = name
            end
        end
        return profiles
    end

    C:AddDropdown(deleteSection, {
        label = LO["Delete"],
        getFunc = function() return nil end,
        setFunc = function(val)
            if val then
                local dialog = StaticPopup_Show("DRAGONUI_DELETE_PROFILE", val)
                if dialog then
                    dialog.data = val
                end
            end
        end,
        values = GetDeletableProfiles(),
    })

    -- ====================================================================
    -- RESET
    -- ====================================================================
    local resetSection = C:AddSection(scroll, LO["Reset Current Profile"])

    C:AddDescription(resetSection, LO["Restores the current profile to its defaults. This cannot be undone."])

    C:AddButton(resetSection, {
        label = LO["Reset Profile"],
        width = 160,
        callback = function()
            local function FinishProfileReset(extraMessage)
                local msg = LO["Profile reset to defaults."]
                if extraMessage and extraMessage ~= "" then
                    msg = msg .. " " .. extraMessage
                end
                addon:Print(msg)
                ReloadUI()
            end

            local function AskDeletePositionPresets()
                local positionPresets = addon.db and addon.db.profile and addon.db.profile.positionPresets
                if not positionPresets or not next(positionPresets) then
                    FinishProfileReset()
                    return
                end

                StaticPopupDialogs["DRAGONUI_RESET_POSITION_PRESETS"] = StaticPopupDialogs["DRAGONUI_RESET_POSITION_PRESETS"] or {
                    text = LO["Also delete all saved position presets?"],
                    button1 = LO["Yes"],
                    button2 = LO["No"],
                    OnAccept = function()
                        if addon.db and addon.db.profile then
                            addon.db.profile.positionPresets = {}
                        end
                        FinishProfileReset()
                    end,
                    OnCancel = function()
                        FinishProfileReset(LO["Position presets kept."] or LO["Presets kept."] or "Position presets kept.")
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = false,
                    preferredIndex = 3,
                }
                StaticPopup_Show("DRAGONUI_RESET_POSITION_PRESETS")
            end

            local function AskDeleteLayoutPresets()
                local presets = addon.db and addon.db.profile and addon.db.profile.presets
                if presets and next(presets) then
                    StaticPopupDialogs["DRAGONUI_RESET_PRESETS"] = StaticPopupDialogs["DRAGONUI_RESET_PRESETS"] or {
                        text = LO["Also delete all saved layout presets?"],
                        button1 = LO["Yes"],
                        button2 = LO["No"],
                        OnAccept = function()
                            if addon.db and addon.db.profile then
                                addon.db.profile.presets = {}
                            end
                            AskDeletePositionPresets()
                        end,
                        OnCancel = function()
                            local positionPresets = addon.db and addon.db.profile and addon.db.profile.positionPresets
                            if positionPresets and next(positionPresets) then
                                AskDeletePositionPresets()
                            else
                                FinishProfileReset(LO["Presets kept."] or "Presets kept.")
                            end
                        end,
                        timeout = 0,
                        whileDead = true,
                        hideOnEscape = false,
                        preferredIndex = 3,
                    }
                    StaticPopup_Show("DRAGONUI_RESET_PRESETS")
                else
                    AskDeletePositionPresets()
                end
            end

            -- Show confirmation dialog before resetting
            StaticPopupDialogs["DRAGONUI_RESET_PROFILE"] = StaticPopupDialogs["DRAGONUI_RESET_PROFILE"] or {
                text = LO["All changes will be lost and the UI will be reloaded.\nAre you sure you want to reset your profile?"],
                button1 = LO["Yes"],
                button2 = LO["No"],
                OnAccept = function()
                    if not addon.db then return end

                    local savedPresets = addon.db.profile.presets
                    local savedPositionPresets = addon.db.profile.positionPresets
                    if savedPresets then
                        savedPresets = addon.DeepCopy(savedPresets)
                    end
                    if savedPositionPresets then
                        savedPositionPresets = addon.DeepCopy(savedPositionPresets)
                    end

                    addon.db:ResetProfile()

                    if savedPresets then
                        addon.db.profile.presets = savedPresets
                    end
                    if savedPositionPresets then
                        addon.db.profile.positionPresets = savedPositionPresets
                    end

                    AskDeleteLayoutPresets()
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
            StaticPopup_Show("DRAGONUI_RESET_PROFILE")
        end,
    })
end

-- Register the tab
Panel:RegisterTab("profiles", LO["Profiles"], BuildProfilesTab, 99)
