local addon = select(2, ...)

-- ============================================================================
-- DragonUI - Blizzard Panel Skin (BlizzardArt)
-- Re-skins vanilla Blizzard frames with the same metal-chrome kit used by the
-- DragonUI bags. Technique inspired by ElvUI's skins: strip the vanilla art
-- first, then apply our own backdrop/chrome and restyle controls.
--
-- MVP target: SpellBookFrame.
-- ============================================================================

local BlizzardArt = {
    applied = false,
    hooksInstalled = false,
}

local InCombatLockdown = InCombatLockdown

local function IsModuleEnabled()
    local cfg = addon.GetModuleConfig and addon:GetModuleConfig("blizzardart")
    if cfg == nil then
        -- Default-on when the profile key is missing (fresh installs without a bump).
        return addon.IsModuleEnabled and addon:IsModuleEnabled("blizzardart") or true
    end
    return cfg.enabled ~= false
end

local function GetModuleConfig()
    return (addon.GetModuleConfig and addon:GetModuleConfig("blizzardart")) or {}
end

-- ============================================================================
-- ASSETS (same kit the bags use; independent of the bagster module)
-- ============================================================================

local UI = "Interface\\AddOns\\DragonUI\\Textures\\UI\\"
local TEX = {
    metal   = UI .. "uiframemetal2x",
    metalH  = UI .. "uiframemetalhorizontal2x",
    metalV  = UI .. "uiframemetalvertical2x",
    bg      = UI .. "ui-background-rock",
    close   = UI .. "redbutton2x",
    tabs    = UI .. "uiframetabs",
    sidetab = UI .. "sidetab",
    hilight = UI .. "buttonhilight-square",
}

-- ============================================================================
-- TAB TWEAK CONSTANTS (edit here to tune)
-- ============================================================================

local TAB_TEXT_SIZE = 10 -- tab label font height (px)
local TAB_PAD_H     = 10 -- horizontal padding inside each tab (px, per side)
local TAB_GAP       = 6  -- spacing between consecutive tabs (px)
local TAB_MIN_WIDTH = 40 -- tabs never get narrower than this
local SIDE_TAB_DX   = 12 -- side-tab border offset X (px, + right)
local SIDE_TAB_DY   = -6 -- side-tab border offset Y (px, - down)

-- Sub-tab variant for nested rows with little vertical room (e.g. the Friends
-- header tabs, the Guild "Info" sub-tabs). Option A first: COMPACT_SUBTABS
-- stays false so the rows are skinned at the normal size; flip to true for the
-- reduced art + smaller font if the content header does not fit them.
local COMPACT_SUBTABS  = false -- true: nested/sub tabs use reduced art+font
local SUB_TAB_H        = 27    -- compact piece height (normal is 36)
local SUB_TAB_FONT     = 9     -- compact tab font height (normal is TAB_TEXT_SIZE)

-- Isolation toggles (default off: back to the pre-test state with native frames).
local HIDE_VANILLA_FRAME_ART = false -- hide the vanilla ButtonFrameTemplate chrome

local tabFontNormal
local tabFontHighlight
local tabSubFontNormal
local tabSubFontHighlight

local function EnsureTabFonts()
    if tabFontNormal then return end
    local path = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    tabFontNormal = CreateFont("DragonUITabFontNormal")
    tabFontNormal:SetFont(path, TAB_TEXT_SIZE, "")
    tabFontNormal:SetTextColor(1, 209 / 255, 0) -- #FFD100 (inactive)
    tabFontHighlight = CreateFont("DragonUITabFontHighlight")
    tabFontHighlight:SetFont(path, TAB_TEXT_SIZE, "")
    tabFontHighlight:SetTextColor(1, 1, 1) -- active
end

local function EnsureTabSubFonts()
    if tabSubFontNormal then return end
    local path = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    tabSubFontNormal = CreateFont("DragonUITabSubFontNormal")
    tabSubFontNormal:SetFont(path, SUB_TAB_FONT, "")
    tabSubFontNormal:SetTextColor(1, 209 / 255, 0)
    tabSubFontHighlight = CreateFont("DragonUITabSubFontHighlight")
    tabSubFontHighlight:SetFont(path, SUB_TAB_FONT, "")
    tabSubFontHighlight:SetTextColor(1, 1, 1)
end

-- ============================================================================
-- STRIP VANILLA ART (ElvUI approach: remove, then skin)
-- ============================================================================

local function StripFrameTextures(frame)
    if not frame then return end
    local num = frame.GetNumRegions and frame:GetNumRegions()
    if not num or num <= 0 then return end
    for i = 1, num do
        local region = select(i, frame:GetRegions())
        if region and region.IsObjectType and region:IsObjectType("Texture") then
            if region.SetTexture then
                region:SetTexture(nil)
            end
            region:Hide()
        end
    end
end

-- ============================================================================
-- PANEL CHROME (metal ring + rock background; added after the art is stripped)
-- ============================================================================

local function AddPanelChrome(frame, opts)
    if not frame or frame._duiPanelSkin then return end
    if not frame.CreateTexture then return end

    opts = opts or {}
    local chrome = {}
    frame._duiPanelSkin = chrome
    chrome.frame = frame

    local function MakeTexture(parent, layer)
        local t = parent:CreateTexture(nil, layer)
        t:Hide()
        return t
    end

    chrome.TopLeftCorner     = MakeTexture(frame, 'OVERLAY')
    chrome.TopRightCorner    = MakeTexture(frame, 'OVERLAY')
    chrome.BottomLeftCorner  = MakeTexture(frame, 'OVERLAY')
    chrome.BottomRightCorner = MakeTexture(frame, 'OVERLAY')
    chrome.TopEdge           = MakeTexture(frame, 'OVERLAY')
    chrome.BottomEdge        = MakeTexture(frame, 'OVERLAY')
    chrome.LeftEdge          = MakeTexture(frame, 'OVERLAY')
    chrome.RightEdge         = MakeTexture(frame, 'OVERLAY')

    local bg = CreateFrame('Frame', nil, frame)
    bg:SetFrameLevel(0)
    bg:SetPoint('TOPLEFT', frame, 'TOPLEFT', 2, -18)
    bg:SetPoint('BOTTOMRIGHT', frame, 'BOTTOMRIGHT', -3, 3)
    local bgTex = bg:CreateTexture(nil, 'BACKGROUND')
    bgTex:SetTexture(TEX.bg)
    bgTex:SetAllPoints(bg)
    bgTex:SetAlpha(opts.bgAlpha or 0.85)
    chrome.Bg = bg
    chrome.BgTex = bgTex
    if opts.noBg then
        bg:Hide()
        bgTex:Hide()
    end

    local tlc = chrome.TopLeftCorner
    tlc:SetTexture(TEX.metal)
    -- Top-left corner with the portrait ring baked in (bag-style chrome).
    tlc:SetTexCoord(0.00195312, 0.294922, 0.298828, 0.591797)
    tlc:SetSize(75, 75)
    tlc:SetPoint('TOPLEFT', opts.tlX or -13, opts.tlY or 16)

    local trc = chrome.TopRightCorner
    trc:SetTexture(TEX.metal)
    trc:SetTexCoord(0.298828, 0.591797, 0.00195312, 0.294922)
    trc:SetSize(75, 75)
    trc:SetPoint('TOPRIGHT', opts.trX or 4, opts.trY or 16)

    local blc = chrome.BottomLeftCorner
    blc:SetTexture(TEX.metal)
    blc:SetTexCoord(0.298828, 0.423828, 0.298828, 0.423828)
    blc:SetSize(32, 32)
    blc:SetPoint('BOTTOMLEFT', opts.blX or -13, opts.blY or -3)

    local brc = chrome.BottomRightCorner
    brc:SetTexture(TEX.metal)
    brc:SetTexCoord(0.427734, 0.552734, 0.298828, 0.423828)
    brc:SetSize(32, 32)
    brc:SetPoint('BOTTOMRIGHT', opts.brX or 4, opts.brY or -3)

    local te = chrome.TopEdge
    te:SetTexture(TEX.metalH)
    te:SetTexCoord(0, 1, 0.00390625, 0.589844)
    te:SetSize(32, 75)
    te:SetPoint('TOPLEFT', tlc, 'TOPRIGHT', -4, 0)
    te:SetPoint('TOPRIGHT', trc, 'TOPLEFT', 4, 0)

    local be = chrome.BottomEdge
    be:SetTexture(TEX.metalH)
    be:SetTexCoord(0, 0.5, 0.597656, 0.847656)
    be:SetSize(16, 32)
    be:SetPoint('TOPLEFT', blc, 'TOPRIGHT', 0, 0)
    be:SetPoint('TOPRIGHT', brc, 'TOPLEFT', 0, 0)

    local le = chrome.LeftEdge
    le:SetTexture(TEX.metalV)
    le:SetTexCoord(0.00195312, 0.294922, 0, 1)
    le:SetSize(75, 16)
    le:SetPoint('TOPLEFT', tlc, 'BOTTOMLEFT', 0, 0)
    le:SetPoint('BOTTOMLEFT', blc, 'TOPLEFT', 0, 0)

    local re = chrome.RightEdge
    re:SetTexture(TEX.metalV)
    re:SetTexCoord(0.298828, 0.591797, 0, 1)
    re:SetSize(75, 16)
    re:SetPoint('TOPRIGHT', trc, 'BOTTOMRIGHT', 0, 0)
    re:SetPoint('BOTTOMRIGHT', brc, 'TOPRIGHT', 0, 0)

    for _, t in pairs({ tlc, trc, blc, brc, te, be, le, re }) do
        t:Show()
    end

    local closeName = frame:GetName() and frame:GetName() .. 'CloseButton' or nil
    local closeBtn = (closeName and _G[closeName]) or frame.CloseButton
    if closeBtn and closeBtn.SetNormalTexture then
        closeBtn:SetSize(24, 24)
        local nt = closeBtn:GetNormalTexture()
        if nt then
            nt:SetTexture(TEX.close)
            nt:SetTexCoord(0.152344, 0.292969, 0.0078125, 0.304688)
        end
        local pt = closeBtn:GetPushedTexture()
        if pt then
            pt:SetTexture(TEX.close)
            pt:SetTexCoord(0.152344, 0.292969, 0.320312, 0.617188)
        end
        local ht = closeBtn:GetHighlightTexture()
        if ht then
            ht:SetTexture(TEX.hilight)
            ht:SetBlendMode('ADD')
        end
    end

    return chrome
end

-- ============================================================================
-- TAB SKIN (retail tab art, same pieces as the DragonUI bag tabs)
-- ============================================================================

-- (Re)applies the DragonUI tab art and configured dimensions. Idempotent: it
-- can run again to restore the height/width after Blizzard re-lays the row
-- (e.g. the Pet tab appearing/disappearing).
local function ApplyTabArt(btn, compact)
    if not btn or not btn.GetName then return false end
    local name = btn:GetName()
    if not name then return false end

    local left   = _G[name .. 'Left']
    local right  = _G[name .. 'Right']
    local middle = _G[name .. 'Middle']
    if not (left and right and middle) then return false end

    local h, hD = 36, 42 -- normal piece heights (active / disabled)
    if compact then
        EnsureTabSubFonts()
        h, hD = SUB_TAB_H, SUB_TAB_H + 4
    end

    EnsureTabFonts()
    if compact then
        btn:SetNormalFontObject(tabSubFontNormal)
        btn:SetHighlightFontObject(tabSubFontHighlight)
    else
        btn:SetNormalFontObject(tabFontNormal)
        btn:SetHighlightFontObject(tabFontHighlight)
    end

    left:ClearAllPoints()
    left:SetSize(26, h)
    left:SetTexture(TEX.tabs)
    left:SetTexCoord(0.015625, 0.5625, 0.816406, 0.957031)
    left:SetPoint('TOPLEFT', -2, 0)

    right:ClearAllPoints()
    right:SetSize(28, h)
    right:SetTexture(TEX.tabs)
    right:SetTexCoord(0.015625, 0.59375, 0.667969, 0.808594)
    right:SetPoint('TOPRIGHT', 5, 0)

    middle:ClearAllPoints()
    middle:SetSize(1, h)
    middle:SetTexture(TEX.tabs)
    middle:SetTexCoord(0, 0.015625, 0.175781, 0.316406)
    middle:SetPoint('TOPLEFT', left, 'TOPRIGHT')
    middle:SetPoint('TOPRIGHT', right, 'TOPLEFT')

    local leftD   = _G[name .. 'LeftDisabled']
    local rightD  = _G[name .. 'RightDisabled']
    local middleD = _G[name .. 'MiddleDisabled']
    if leftD and rightD and middleD then
        leftD:ClearAllPoints()
        leftD:SetSize(26, hD)
        leftD:SetTexture(TEX.tabs)
        leftD:SetTexCoord(0.015625, 0.5625, 0.496094, 0.660156)
        leftD:SetPoint('TOPLEFT', 0, 0)

        rightD:ClearAllPoints()
        rightD:SetSize(28, hD)
        rightD:SetTexture(TEX.tabs)
        rightD:SetTexCoord(0.015625, 0.59375, 0.324219, 0.488281)
        rightD:SetPoint('TOPRIGHT', 6, 0)

        middleD:ClearAllPoints()
        middleD:SetSize(1, hD)
        middleD:SetTexture(TEX.tabs)
        middleD:SetTexCoord(0, 0.015625, 0.00390625, 0.167969)
        middleD:SetPoint('TOPLEFT', leftD, 'TOPRIGHT')
        middleD:SetPoint('TOPRIGHT', rightD, 'TOPLEFT')
    end

    -- No art hover effects: only the text reacts on hover (minimal look).
    local ht = btn:GetHighlightTexture()
    if ht then ht:Hide() end

    -- Fixed-width tab: text width + configured side padding.
    local textW = btn.GetTextWidth and btn:GetTextWidth() or 0
    if textW and textW > 0 then
        btn:SetWidth(math.max(textW + TAB_PAD_H * 2, TAB_MIN_WIDTH))
    end

    return true
end

-- One-time skin: bump the frame level once, then (re)apply the art. Safe to
-- call repeatedly: already-skinned tabs just get their dimensions restored.
local function SkinTab(btn, compact)
    if not btn or not btn.GetName then return false end
    if not ApplyTabArt(btn, compact) then return false end
    if not btn._duiTabSkins then
        btn._duiTabSkins = true
        btn:SetFrameLevel(btn:GetFrameLevel() + 4)
    end
    return true
end

local function SkinSpellBookBottomTabs()
    -- MoP spells book: bottom "All Spells / Profession / ..." tabs (ElvUI names).
    local skinned = 0
    for i = 1, 5 do
        local btn = _G['SpellBookFrameTabButton' .. i]
        if btn and btn.IsObjectType and btn:IsObjectType('Button') then
            local ok, err = pcall(SkinTab, btn)
            if ok then
                skinned = skinned + 1
            elseif addon.Debug then
                addon:Debug('blizzardart tab skin failed for SpellBookFrameTabButton' .. i .. ': ' .. tostring(err))
            end
        end
    end
    return skinned
end

-- Vertical skill-line tabs (class/profession icons on the side of the book):
-- keep the icon Blizzard assigns and wrap it with the retail side-tab art plus
-- a square hover/selected highlight. Content/behavior untouched.
local function SkinSpellBookSideTabs()
    local maxTabs = MAX_SKILLLINE_TABS or 3
    local skinned = 0
    for i = 1, maxTabs do
        local tab = _G['SpellBookSkillLineTab' .. i]
        if tab and tab.IsObjectType and tab:IsObjectType('Button') and not tab._duiSideTab then
            local ok, err = pcall(function()
                tab._duiSideTab = true

                local border = tab:CreateTexture(nil, 'BORDER')
                border:SetTexture(TEX.sidetab)
                border:SetSize(64, 64)
                -- Align to the icon (the tab's normal texture), not the button,
                -- so the ring follows Blizzard's icon position. Offsets tunable.
                local icon = tab:GetNormalTexture()
                if icon then
                    border:SetPoint('CENTER', icon, 'CENTER', SIDE_TAB_DX, SIDE_TAB_DY)
                else
                    border:SetPoint('CENTER', tab, 'CENTER', SIDE_TAB_DX, SIDE_TAB_DY)
                end
                border:Show()
                tab._duiSideBorder = border

                local ht = tab:GetHighlightTexture()
                if ht then
                    ht:SetTexture(TEX.hilight)
                    ht:SetBlendMode('ADD')
                end
                -- Active (selected) state keeps the vanilla checked art (native gold).

                local flash = _G['SpellBookSkillLineTab' .. i .. 'Flash']
                if flash then flash:Hide() end
            end)
            if ok then
                skinned = skinned + 1
            elseif addon.Debug then
                addon:Debug('blizzardart side tab skin failed for SpellBookSkillLineTab' .. i .. ': ' .. tostring(err))
            end
        end
    end
    return skinned
end

-- Core Abilities spec tabs are created dynamically (no global name) inside
-- SpellBookCoreAbilitiesFrame.SpecTabs. Give them the same DragonUI side-tab
-- frame (with the calibrated offsets); states/icons stay native.
local function SkinCoreSpecTabs()
    local frame = _G.SpellBookCoreAbilitiesFrame
    if not frame or not frame.SpecTabs then return 0 end
    local skinned = 0
    for i = 1, #frame.SpecTabs do
        local tab = frame.SpecTabs[i]
        if tab and tab.IsObjectType and tab:IsObjectType('Button') and not tab._duiCoreSpecTab then
            local ok, err = pcall(function()
                tab._duiCoreSpecTab = true

                local border = tab:CreateTexture(nil, 'BORDER')
                border:SetTexture(TEX.sidetab)
                border:SetSize(64, 64)
                local icon = tab:GetNormalTexture()
                if icon then
                    border:SetPoint('CENTER', icon, 'CENTER', SIDE_TAB_DX, SIDE_TAB_DY)
                else
                    border:SetPoint('CENTER', tab, 'CENTER', SIDE_TAB_DX, SIDE_TAB_DY)
                end
                border:Show()
                tab._duiCoreSpecBorder = border

                local flash = tab.Flash or (tab.GetName and _G[tab:GetName() .. 'Flash'])
                if flash and flash.Hide then flash:Hide() end
            end)
            if ok then
                skinned = skinned + 1
            elseif addon.Debug then
                addon:Debug('blizzardart core spec tab skin failed #' .. i .. ': ' .. tostring(err))
            end
        end
    end
    return skinned
end

-- Fixed-width tab: text width + configured side padding. Only meaningful once
-- the tab actually has its label set (guarded by textW > 0).
local function ApplyTabPaddingWidth(btn)
    if not btn or not btn.SetWidth then return end
    local textW = btn.GetTextWidth and btn:GetTextWidth() or 0
    if textW and textW > 0 then
        btn:SetWidth(math.max(textW + TAB_PAD_H * 2, TAB_MIN_WIDTH))
    end
end

-- Chain the visible bottom tabs left-to-right with TAB_GAP spacing and keep
-- TAB_PAD_H applied. Runs on every apply/show/update so Blizzard re-layouts
-- never clump the tabs or reset the width again.
local function RepositionSpellBookTabs()
    local frame = _G.SpellBookFrame
    if not frame then return end
    local previous
    for i = 1, 5 do
        local btn = _G['SpellBookFrameTabButton' .. i]
        if btn and btn.SetPoint then
            ApplyTabPaddingWidth(btn)
            -- Only chain visible tabs (hidden ones would leave a gap).
            if not (btn.IsShown and not btn:IsShown()) then
                if previous then
                    btn:ClearAllPoints()
                    btn:SetPoint('LEFT', previous, 'RIGHT', TAB_GAP, 0)
                end
                previous = btn
            end
        end
    end
end

-- Hide the vanilla ButtonFrameTemplate chrome (borders/corners) so our metal
-- ring is not drawn over a duplicate frame. The interior rock background and
-- the content pages are kept untouched.
local function HideVanillaFrameArt(frame)
    if not frame or frame._duiVanillaArtHidden then return end
    frame._duiVanillaArtHidden = true

    local num = frame.GetNumRegions and frame:GetNumRegions() or 0
    for i = 1, num do
        local region = select(i, frame:GetRegions())
        if region and region.IsObjectType and region:IsObjectType('Texture') then
            local tex = region.GetTexture and region:GetTexture()
            if type(tex) == 'string'
                and tex:find('Interface\\FrameGeneral\\', 1, true)
                and not tex:find('UI-Background-Rock', 1, true) then
                region:Hide()
            end
        end
    end
end

-- ============================================================================
-- DEBUG TEXTURE INVENTORY (with /dragonui debug on)
-- ============================================================================

local function DumpFrameTextures(frame, indent)
    indent = indent or ''
    if not frame then return end
    local num = frame.GetNumRegions and frame:GetNumRegions()
    if num and num > 0 then
        addon:Print(indent .. tostring(frame:GetName() or '?') .. ' regions:')
        for i = 1, num do
            local region = select(i, frame:GetRegions())
            if region and region.IsObjectType and region:IsObjectType('Texture') then
                local tex = region.GetTexture and region:GetTexture() or ''
                local w, h = '', ''
                if region.GetWidth and region.GetHeight then
                    w, h = region:GetWidth(), region:GetHeight()
                end
                local pts = {}
                local np = region.GetNumPoints and region:GetNumPoints() or 0
                for p = 1, np do
                    local ok, pt, rel, rpt, x, y = pcall(region.GetPoint, region, p)
                    if ok and pt then
                        pts[#pts + 1] = ('%s:%s:%s,%s,%s'):format(
                            tostring(pt),
                            tostring(rel and rel:GetName() or 'nil'),
                            tostring(rpt or 'nil'),
                            tostring(x or 0),
                            tostring(y or 0))
                    end
                end
                addon:Print(indent .. '  #' .. i
                    .. ' layer=' .. tostring(region.GetDrawLayer and region:GetDrawLayer())
                    .. ' tex=' .. tostring(tex or 'nil')
                    .. ' size=' .. tostring(w) .. 'x' .. tostring(h)
                    .. (pts[1] and (' pt=' .. table.concat(pts, ' | ')) or ''))
            end
        end
    end
end

-- ============================================================================
-- SPELLBOOK SKIN
-- ============================================================================

local function ApplySpellBook()
    local frame = _G.SpellBookFrame
    if not frame then
        return false
    end
    if InCombatLockdown() then
        return false
    end

    -- Re-apply tab spacing on every pass (cheap), even when already skinned.
    RepositionSpellBookTabs()
    SkinCoreSpecTabs()

    -- Dump on every open while debug is on, so tuning data is available even
    -- after the frame was already skinned earlier in the session.
    if addon.debugMode then
        DumpFrameTextures(frame)
    end

    if frame._duiSpellBookSkinned then
        return true
    end

    local ok, err = pcall(function()
        -- Content stays 100% native Blizzard: only the metal frame ring and the
        -- bottom tabs are re-styled. No StripTextures and no background fill.
        AddPanelChrome(frame, {
            noBg = true,
        })

        -- Close button flush with the top-right corner (DF reference placement).
        local closeBtn = _G.SpellBookCloseButton or frame.CloseButton
        if closeBtn and closeBtn.ClearAllPoints and closeBtn.SetPoint then
            closeBtn:ClearAllPoints()
            closeBtn:SetPoint('TOPRIGHT', frame, 'TOPRIGHT', 1, 0)
        end
        if closeBtn and closeBtn.SetNormalTexture then
            closeBtn:SetSize(24, 24)
            local nt = closeBtn:GetNormalTexture()
            if nt then
                nt:SetTexture(TEX.close)
                nt:SetTexCoord(0.152344, 0.292969, 0.0078125, 0.304688)
            end
            local pt = closeBtn:GetPushedTexture()
            if pt then
                pt:SetTexture(TEX.close)
                pt:SetTexCoord(0.152344, 0.292969, 0.320312, 0.617188)
            end
            local ht = closeBtn:GetHighlightTexture()
            if ht then
                ht:SetTexture(TEX.hilight)
                ht:SetBlendMode('ADD')
            end
        end

        -- Remove the native frame chrome underneath our metal ring (keeps the
        -- interior rock background and the content pages).
        if HIDE_VANILLA_FRAME_ART then
            HideVanillaFrameArt(frame)
        end

        SkinSpellBookBottomTabs()
        SkinSpellBookSideTabs()

        frame._duiSpellBookSkinned = true

        if addon.debugMode then
            DumpFrameTextures(frame)
        end
    end)
    if not ok then
        addon:Error('BlizzardArt skin failed: ' .. tostring(err))
        return false
    end
    return true
end

-- ============================================================================
-- TALENTS (N) — chrome + close + tuning dump. Bottom/side tabs and the
-- portrait get their DragonUI treatment once their exact names are confirmed
-- via the debug inventory (PlayerTalentFrame / TalentFrame).
-- ============================================================================

local TALENT_FRAME_NAMES = { 'PlayerTalentFrame', 'TalentFrame' }

local function FindTalentFrame()
    for _, n in ipairs(TALENT_FRAME_NAMES) do
        local f = _G[n]
        if f and f.IsShown and f:IsShown() then
            return f, n
        end
    end
    for _, n in ipairs(TALENT_FRAME_NAMES) do
        if _G[n] then return _G[n], n end
    end
    return nil
end

local function SkinTalentFrameExplicit(f, name)
    if not f or not f.CreateTexture then return false end

    local ok, err = pcall(function()
        AddPanelChrome(f, {
            noBg = true,
        })

        -- Close button flush with the top-right corner.
        local closeName = name and (name .. 'CloseButton') or nil
        local closeBtn = (closeName and _G[closeName]) or f.CloseButton
        if closeBtn and closeBtn.ClearAllPoints and closeBtn.SetPoint then
            closeBtn:ClearAllPoints()
            closeBtn:SetPoint('TOPRIGHT', f, 'TOPRIGHT', 1, 0)
        end

        f._duiTalentSkinned = true
    end)
    if not ok then
        addon:Error('BlizzardArt talent skin failed: ' .. tostring(err))
    end
    return ok
end

-- Enumerate child frames of a frame (capped to avoid iterator-form artifacts).
local function GetChildFrames(frame)
    local children = {}
    if not frame or not frame.GetChildren then return children end
    for i = 1, 50 do
        local child = select(i, frame:GetChildren())
        if not child then break end
        if child ~= true then
            children[#children + 1] = child
        end
    end
    return children
end

-- Generic Talent tab skin: text buttons get the DragonUI bottom-tab look
-- (only when they expose the Left/Middle/Right pieces), icon-only buttons get
-- the side-tab sidetab frame. Guarded per button; anything unrecognized is left
-- untouched.
local function SkinTalentTabs(f)
    if not f then return end
    for _, child in ipairs(GetChildFrames(f)) do
        if child.IsObjectType and child:IsObjectType('Button') then
            local cname = child.GetName and child:GetName()
            local isClose = cname and cname:match('CloseButton$')
            if not isClose then
                local hasText = child.GetText and child:GetText()
                if hasText and hasText ~= '' then
                    -- Text tab: apply the bottom-tab look once and always keep
                    -- the same width as the SpellBook tabs (recompute each Show).
                    if not child._duiTalentChild then
                        local ok, res = pcall(SkinTab, child)
                        child._duiTalentChild = ok and res
                    elseif child._duiTabSkins then
                        ApplyTabArt(child)
                    end
                    ApplyTabPaddingWidth(child)
                elseif child.GetNormalTexture and child:GetNormalTexture() then
                    if not child._duiTalentChild then
                        local ok, err = pcall(function()
                            child._duiTalentChild = true
                            local border = child:CreateTexture(nil, 'BORDER')
                            border:SetTexture(TEX.sidetab)
                            border:SetSize(64, 64)
                            local icon = child:GetNormalTexture()
                            if icon then
                                border:SetPoint('CENTER', icon, 'CENTER', SIDE_TAB_DX, SIDE_TAB_DY)
                            else
                                border:SetPoint('CENTER', child, 'CENTER', SIDE_TAB_DX, SIDE_TAB_DY)
                            end
                            border:Show()
                            child._duiTalentSideBorder = border
                            local flash = child.Flash or (child.GetName and _G[child:GetName() .. 'Flash'])
                            if flash and flash.Hide then flash:Hide() end
                        end)
                        if not ok and addon.Debug then
                            addon:Debug('blizzardart talent child icon tab skin failed: ' .. tostring(err))
                        end
                    end
                end
            end
        end
    end
end

-- Re-apply the DragonUI width and spacing after Blizzard's own talent tab
-- layout (PlayerTalentFrame_UpdateTabs), same as the SpellBook post-update hook.
local function RefreshTalentTabWidths()
    local previous
    for i = 1, 8 do
        local tab = _G['PlayerTalentFrameTab' .. i]
        if tab and tab.IsObjectType and tab:IsObjectType('Button') then
            ApplyTabPaddingWidth(tab)
            -- Only chain visible tabs (hidden ones would leave a gap).
            if not (tab.IsShown and not tab:IsShown()) then
                if previous then
                    tab:ClearAllPoints()
                    tab:SetPoint('LEFT', previous, 'RIGHT', TAB_GAP, 0)
                end
                previous = tab
            end
        end
    end
end

local function ApplyTalentFrame()
    local f, name = FindTalentFrame()
    if not f or InCombatLockdown() then return false end
    if not f._duiTalentSkinned then
        SkinTalentFrameExplicit(f, name)
    end
    -- Re-run on every Show so tabs created later also get the DragonUI look.
    SkinTalentTabs(f)
    RefreshTalentTabWidths()
    return true
end

-- Exposed debug entry point: /dragonui panel <FrameName>
-- Safe inventory of a frame (regions + bounded children) for skinning new windows.
function addon.BlizzardArtDumpPanel(arg)
    local name = arg and arg:match('^%s*(%S+)') or ''
    local f = name ~= '' and _G[name]
    if not f then
        addon:Print('BlizzardArt: frame not found: ' .. tostring(name))
        return
    end
    addon:Print('--- BlizzardArt dump ' .. name .. ' ---')
    DumpFrameTextures(f)

    local count = 0
    local function Walk(frame, depth)
        if count > 200 then return end
        for _, child in ipairs(GetChildFrames(frame)) do
            count = count + 1
            local cn = child.GetName and child:GetName() or '?'
            local ct = child.GetObjectType and child:GetObjectType() or '?'
            local txt = ''
            if child.GetText then txt = child:GetText() or '' end
            addon:Print(('  '):rep(depth) .. tostring(cn) .. ' [' .. tostring(ct) .. '] text=' .. tostring(txt))
            if depth < 2 then
                Walk(child, depth + 1)
            end
        end
    end
    Walk(f, 1)
end

-- Exposed debug entry point: /dragonui talent
function addon.BlizzardArtDebugTalent()
    local f = _G.PlayerTalentFrame or _G.TalentFrame
    if not f then
        addon:Print('BlizzardArt: PlayerTalentFrame not found')
        return
    end
    if addon.debugMode then
        DumpFrameTextures(f)
        -- Also list direct child buttons (names/types/text) for tuning.
        for _, child in ipairs(GetChildFrames(f)) do
            local label = ''
            if child.GetText then label = child:GetText() or '' end
            addon:Print('  child ' .. tostring(child:GetName() or '?') .. ' [' .. child:GetObjectType() .. '] text=' .. tostring(label))
        end
    end
    SkinTalentFrameExplicit(f, f:GetName() or 'TalentFrame')
    SkinTalentTabs(f)
end

-- ============================================================================
-- CHARACTER (C) — CharacterFrame (Paperdoll/Pet/Reputation/Currency tabs)
-- ============================================================================

local function RefreshCharacterTabs()
    local previous
    for i = 1, 8 do
        local tab = _G['CharacterFrameTab' .. i]
        if tab and tab.IsObjectType and tab:IsObjectType('Button') then
            ApplyTabPaddingWidth(tab)
            -- Only chain visible tabs; hidden tabs (e.g. Pet without a pet)
            -- would otherwise leave a gap in the row.
            if not (tab.IsShown and not tab:IsShown()) then
                if previous then
                    tab:ClearAllPoints()
                    tab:SetPoint('LEFT', previous, 'RIGHT', TAB_GAP, 0)
                end
                previous = tab
            end
        end
    end
end

local function SkinCharacterTabs()
    local frame = _G.CharacterFrame
    if not frame then return end
    for i = 1, 8 do
        local tab = _G['CharacterFrameTab' .. i]
        if tab and tab.IsObjectType and tab:IsObjectType('Button') then
            if not tab._duiCharTab then
                local ok, res = pcall(SkinTab, tab)
                tab._duiCharTab = ok and res
            elseif tab._duiTabSkins then
                ApplyTabArt(tab)
            end
            if not tab._duiCharClick then
                tab._duiCharClick = true
                tab:HookScript('OnClick', function()
                    RefreshCharacterTabs()
                end)
            end
            ApplyTabPaddingWidth(tab)
        end
    end
    RefreshCharacterTabs()
end

local function ApplyCharacterFrame()
    local f = _G.CharacterFrame
    if not f or InCombatLockdown() then return false end

    if not f._duiCharSkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })

            local closeBtn = _G.CharacterFrameCloseButton or f.CloseButton
            if closeBtn and closeBtn.ClearAllPoints and closeBtn.SetPoint then
                closeBtn:ClearAllPoints()
                closeBtn:SetPoint('TOPRIGHT', f, 'TOPRIGHT', 1, 0)
            end

            f._duiCharSkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt character skin failed: ' .. tostring(err))
            return false
        end
    end

    SkinCharacterTabs()
    return true
end

-- ============================================================================
-- TAB LAYOUT RE-APPLY (pet appear/disappear, Blizzard tab re-layouts)
-- ============================================================================

-- Re-applies the configured tab width, art height and spacing across the
-- Character, Spellbook and Talent windows. Cheap and idempotent; runs after
-- Blizzard touches the tabs so its own resize never wins.
local function ReapplyTabLayouts()
    if InCombatLockdown() then return end

    SkinCharacterTabs()
    RepositionSpellBookTabs()
    SkinSpellBookBottomTabs()
    SkinCoreSpecTabs()

    local f = FindTalentFrame()
    if f then
        SkinTalentTabs(f)
        RefreshTalentTabWidths()
    end
end

local reapplyScheduled = false
local function ScheduleReapplyTabLayouts()
    if reapplyScheduled then return end
    reapplyScheduled = true

    local function run()
        reapplyScheduled = false
        ReapplyTabLayouts()
    end

    if addon.core and addon.core.ScheduleTimer then
        addon.core:ScheduleTimer(run, 0)
    else
        run()
    end
end

-- ============================================================================
-- QUEST LOG (L) — QuestLogFrame (no tabs; chrome + close only)
-- ============================================================================

local function ApplyQuestLogFrame()
    local f = _G.QuestLogFrame
    if not f or InCombatLockdown() then return false end

    if not f._duiQuestSkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })

            local closeBtn = _G.QuestLogFrameCloseButton or f.CloseButton
            if closeBtn and closeBtn.ClearAllPoints and closeBtn.SetPoint then
                closeBtn:ClearAllPoints()
                closeBtn:SetPoint('TOPRIGHT', f, 'TOPRIGHT', 1, 0)
            end

            f._duiQuestSkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt quest log skin failed: ' .. tostring(err))
            return false
        end
    end
    return true
end

-- ============================================================================
-- PVE / DUNGEON FINDER (i) — the visible window is PVEFrame (title bar,
-- portrait area and close button live here). Content stays native: the blue
-- sidebar GroupFinderFrame + its subpanels (LFDParentFrame / RaidFinderFrame /
-- ScenarioFinderFrame / FlexRaidFrame) and the paginated panels. Only the
-- metal chrome, the close button and the dynamic text tabs (PVEFrameTab1..N,
-- e.g. "Dungeon Finder" / "Challenges") are re-styled.
-- ============================================================================

local function StyleCloseButton(btn, host)
    if not btn then return end
    if btn.ClearAllPoints and btn.SetPoint then
        btn:ClearAllPoints()
        btn:SetPoint('TOPRIGHT', host, 'TOPRIGHT', 1, 0)
    end
    if btn.SetSize then btn:SetSize(24, 24) end
    if btn.SetNormalTexture then
        local nt = btn:GetNormalTexture()
        if nt then
            nt:SetTexture(TEX.close)
            nt:SetTexCoord(0.152344, 0.292969, 0.0078125, 0.304688)
        end
        local pt = btn:GetPushedTexture()
        if pt then
            pt:SetTexture(TEX.close)
            pt:SetTexCoord(0.152344, 0.292969, 0.320312, 0.617188)
        end
        local ht = btn:GetHighlightTexture()
        if ht then
            ht:SetTexture(TEX.hilight)
            ht:SetBlendMode('ADD')
        end
    end
end

local function FindCloseButton(f)
    local name = f and f.GetName and f:GetName() or ''
    for _, n in ipairs({ name .. 'CloseButton', 'PVEFrameCloseButton' }) do
        local b = _G[n]
        if b and b.IsObjectType and b:IsObjectType('Button') then return b end
    end
    if f and f.CloseButton and f.CloseButton.IsObjectType
        and f.CloseButton:IsObjectType('Button') then return f.CloseButton end
    local function Rec(node, depth)
        if depth > 5 or not node.GetChildren then return nil end
        for _, ch in ipairs(GetChildFrames(node)) do
            if ch.IsObjectType and ch:IsObjectType('Button') then
                local nm = ch.GetName and ch:GetName() or ''
                if nm:match('CloseButton$') then return ch end
            end
            local r = Rec(ch, depth + 1)
            if r then return r end
        end
    end
    return f and Rec(f, 1)
end

-- Dynamic text tabs: PVEFrameTab1..N. Each tab is styled once (SkinTab) and its
-- width + spacing re-applied on every pass; only visible tabs are chained so
-- new tabs (e.g. future categories) adopt the DragonUI look automatically.
local function SkinPVEFrameTabs()
    local previous
    for i = 1, 20 do
        local tab = _G['PVEFrameTab' .. i]
        if tab and tab.IsObjectType and tab:IsObjectType('Button') then
            if tab._duiTabSkins == nil then
                pcall(SkinTab, tab)
            end
            pcall(ApplyTabPaddingWidth, tab)
            if not (tab.IsShown and not tab:IsShown()) then
                if previous then
                    pcall(function()
                        tab:ClearAllPoints()
                        tab:SetPoint('LEFT', previous, 'RIGHT', TAB_GAP, 0)
                    end)
                end
                previous = tab
            end
        end
    end
end

local function ApplyPVEFrame()
    local f = _G.PVEFrame
    if not f or InCombatLockdown() then return false end

    if not f._duiPVESkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })
            StyleCloseButton(FindCloseButton(f), f)
            f._duiPVESkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt PVEFrame skin failed: ' .. tostring(err))
            return false
        end
    end

    SkinPVEFrameTabs()
    return true
end

local pveShowHooked

-- PVE / Dungeon Finder (i): hook Show when the frame exists (retried from
-- StartTalentRetry).
local function HookPVEFrameShow()
    local f = _G.PVEFrame
    if f and f.Show and not pveShowHooked and hooksecurefunc then
        pveShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- ============================================================================
-- PVP (H) — PVPUIFrame is the visible window (same template as PVEFrame:
-- portrait, blue sidebar art, close button). Navigation is the native blue
-- sidebar (PVPQueueFrameCategoryButton1..3 switching Honor/Conquest/WarGames)
-- and there are NO text tabs; only chrome + close are re-styled.
-- ============================================================================

local pvpShowHooked
local HookPVPUIFrameShow

local function ApplyPVPUIFrame()
    local f = _G.PVPUIFrame
    if not f or InCombatLockdown() then return false end

    -- Defensive: if this apply pass runs before the lazy Show hook was ever
    -- installed (late-loaded frame), install it now so future Show calls are
    -- covered too.
    HookPVPUIFrameShow()

    if not f._duiPVPUISkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })
            StyleCloseButton(FindCloseButton(f), f)
            f._duiPVPUISkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt PVPUIFrame skin failed: ' .. tostring(err))
            return false
        end
    end
    return true
end

-- PVP (H): hook Show when the frame exists (retried from StartTalentRetry).
HookPVPUIFrameShow = function()
    local f = _G.PVPUIFrame
    if f and f.Show and not pvpShowHooked and hooksecurefunc then
        pvpShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- ============================================================================
-- PET JOURNAL (pet key / companion) — PetJournalParent is the visible window
-- (standard template). Two dynamic text tabs: "Mounts" (MountJournal) and
-- "Pet Journal" (PetJournal). Chrome + close + tabs; content stays native.
-- ============================================================================

local petShowHooked
local HookPetJournalShow

local function SkinPetJournalTabs()
    local previous
    for i = 1, 20 do
        local tab = _G['PetJournalParentTab' .. i]
        if tab and tab.IsObjectType and tab:IsObjectType('Button') then
            if tab._duiTabSkins == nil then
                pcall(SkinTab, tab)
            end
            pcall(ApplyTabPaddingWidth, tab)
            if not (tab.IsShown and not tab:IsShown()) then
                if previous then
                    pcall(function()
                        tab:ClearAllPoints()
                        tab:SetPoint('LEFT', previous, 'RIGHT', TAB_GAP, 0)
                    end)
                end
                previous = tab
            end
        end
    end
end

local function ApplyPetJournal()
    local f = _G.PetJournalParent
    if not f or InCombatLockdown() then return false end

    HookPetJournalShow()

    if not f._duiPetJournalSkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })
            StyleCloseButton(FindCloseButton(f), f)
            f._duiPetJournalSkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt PetJournalParent skin failed: ' .. tostring(err))
            return false
        end
    end

    SkinPetJournalTabs()
    return true
end

-- Pet Journal: hook Show when the frame exists (retried from StartTalentRetry).
HookPetJournalShow = function()
    local f = _G.PetJournalParent
    if f and f.Show and not petShowHooked and hooksecurefunc then
        petShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- ============================================================================
-- GUILD (G) — GuildFrame is the visible window (standard template; the guild
-- emblem is the top-left portrait). Only the five bottom window tabs
-- GuildFrameTab1..5 get the DragonUI look; nested Info sub-tabs
-- (GuildInfoFrameTab1..3) and content (roster/news/rewards/popups) stay native.
-- ============================================================================

local guildShowHooked
local HookGuildFrameShow

local function SkinNamedTabsRun(prefix, compact)
    local previous
    for i = 1, 20 do
        local tab = _G[prefix .. i]
        if tab and tab.IsObjectType and tab:IsObjectType('Button') then
            if tab._duiTabSkins == nil then
                pcall(SkinTab, tab, compact)
            end
            pcall(ApplyTabPaddingWidth, tab)
            if not (tab.IsShown and not tab:IsShown()) then
                if previous then
                    pcall(function()
                        tab:ClearAllPoints()
                        tab:SetPoint('LEFT', previous, 'RIGHT', TAB_GAP, 0)
                    end)
                end
                previous = tab
            end
        end
    end
end

local function SkinGuildTabs()
    SkinNamedTabsRun('GuildFrameTab')
end

local function ApplyGuildFrame()
    local f = _G.GuildFrame
    if not f or InCombatLockdown() then return false end

    HookGuildFrameShow()

    if not f._duiGuildSkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })
            StyleCloseButton(FindCloseButton(f), f)
            f._duiGuildSkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt GuildFrame skin failed: ' .. tostring(err))
            return false
        end
    end

    SkinGuildTabs()
    return true
end

-- Guild (G): hook Show when the frame exists (retried from StartTalentRetry).
HookGuildFrameShow = function()
    local f = _G.GuildFrame
    if f and f.Show and not guildShowHooked and hooksecurefunc then
        guildShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- ============================================================================
-- SOCIAL / FRIENDS (O) — FriendsFrame is the visible window (standard
-- template; the portrait is the Battlenet portrait). Only the four bottom
-- window tabs FriendsFrameTab1..4 get the DragonUI look; header sub-tabs
-- (FriendsTabHeaderTab1..3) and content (lists, scrolls, dropdowns, channel
-- popup) stay native.
-- ============================================================================

local friendsShowHooked
local HookFriendsFrameShow

local function SkinFriendsTabs()
    SkinNamedTabsRun('FriendsFrameTab')
end

local function ApplyFriendsFrame()
    local f = _G.FriendsFrame
    if not f or InCombatLockdown() then return false end

    HookFriendsFrameShow()

    if not f._duiFriendsSkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })
            StyleCloseButton(FindCloseButton(f), f)
            f._duiFriendsSkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt FriendsFrame skin failed: ' .. tostring(err))
            return false
        end
    end

    SkinFriendsTabs()
    return true
end

-- Social / Friends (O): hook Show when the frame exists (retried from
-- StartTalentRetry).
HookFriendsFrameShow = function()
    local f = _G.FriendsFrame
    if f and f.Show and not friendsShowHooked and hooksecurefunc then
        friendsShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- ============================================================================
-- MAILBOX (mail icon) — MailFrame is the visible window (standard template;
-- the portrait is the Mail-Icon). Two bottom text tabs MailFrameTab1..2
-- (Inbox / Send Mail). Chrome + close + tabs; the mail content (InboxFrame,
-- SendMailFrame and their buttons/attachments) stays native.
-- ============================================================================

local mailShowHooked
local HookMailFrameShow

local function ApplyMailFrame()
    local f = _G.MailFrame
    if not f or InCombatLockdown() then return false end

    HookMailFrameShow()

    if not f._duiMailSkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })
            StyleCloseButton(FindCloseButton(f), f)
            f._duiMailSkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt MailFrame skin failed: ' .. tostring(err))
            return false
        end
    end

    SkinNamedTabsRun('MailFrameTab')
    return true
end

-- Mailbox (mail icon): hook Show when the frame exists (retried from
-- StartTalentRetry).
HookMailFrameShow = function()
    local f = _G.MailFrame
    if f and f.Show and not mailShowHooked and hooksecurefunc then
        mailShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- ============================================================================
-- ENCOUNTER JOURNAL / GUIDES (J) — EncounterJournal is the visible window
-- (standard template, no window-level text tabs). Only chrome + close are
-- restyled; the instance selector (Dungeons/Raids segmented bar), the boss
-- sidebar and all content stay native.
-- ============================================================================

local journalShowHooked
local HookEncounterJournalShow

local function ApplyEncounterJournal()
    local f = _G.EncounterJournal
    if not f or InCombatLockdown() then return false end

    HookEncounterJournalShow()

    if not f._duiJournalSkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })
            StyleCloseButton(FindCloseButton(f), f)
            f._duiJournalSkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt EncounterJournal skin failed: ' .. tostring(err))
            return false
        end
    end

    return true
end

-- Encounter Journal (J): hook Show when the frame exists (retried from
-- StartTalentRetry).
HookEncounterJournalShow = function()
    local f = _G.EncounterJournal
    if f and f.Show and not journalShowHooked and hooksecurefunc then
        journalShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- ============================================================================
-- MACRO (M) — MacroFrame is the visible window (standard template; portrait is
-- the MacroFrame-Icon). Chrome + close only; window/roll tabs and all macro
-- content stay native (per policy, internal tabs are not skinned).
-- ============================================================================

local macroShowHooked
local HookMacroFrameShow

local function ApplyMacroFrame()
    local f = _G.MacroFrame
    if not f or InCombatLockdown() then return false end

    HookMacroFrameShow()

    if not f._duiMacroSkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })
            StyleCloseButton(FindCloseButton(f), f)
            f._duiMacroSkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt MacroFrame skin failed: ' .. tostring(err))
            return false
        end
    end
    return true
end

-- Macro (M): hook Show when the frame exists (retried from StartTalentRetry).
HookMacroFrameShow = function()
    local f = _G.MacroFrame
    if f and f.Show and not macroShowHooked and hooksecurefunc then
        macroShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- ============================================================================
-- INSPECT (right-click -> Inspect) — InspectFrame mirrors the Character window
-- (standard template with its own portrait). Chrome + close + the four bottom
-- window tabs InspectFrameTab1..4 (Character/PvP/Talents/Guild); content
-- (paperdoll, model, pvp/talents/guild views) stays native.
-- ============================================================================

local inspectShowHooked
local HookInspectFrameShow

local function ApplyInspectFrame()
    local f = _G.InspectFrame
    if not f or InCombatLockdown() then return false end

    HookInspectFrameShow()

    if not f._duiInspectSkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })
            StyleCloseButton(FindCloseButton(f), f)
            f._duiInspectSkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt InspectFrame skin failed: ' .. tostring(err))
            return false
        end
    end

    SkinNamedTabsRun('InspectFrameTab')
    return true
end

-- Inspect (right-click -> Inspect): hook Show when the frame exists (retried
-- from StartTalentRetry; ADDON_LOADED covers late creation via Blizzard_InspectUI).
HookInspectFrameShow = function()
    local f = _G.InspectFrame
    if f and f.Show and not inspectShowHooked and hooksecurefunc then
        inspectShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- ============================================================================
-- PROFESSIONS (open a profession) — TradeSkillFrame is the visible window
-- (standard template) with NO window tabs. Only chrome + close; recipe list,
-- detail pane, search/filter, craft buttons and the View Crafters popup
-- (TradeSkillGuildFrame) stay native.
-- ============================================================================

local tradeskillShowHooked
local HookTradeSkillShow

local function ApplyTradeSkillFrame()
    local f = _G.TradeSkillFrame
    if not f or InCombatLockdown() then return false end

    HookTradeSkillShow()

    if not f._duiTradeSkillSkinned then
        local ok, err = pcall(function()
            AddPanelChrome(f, {
                noBg = true,
            })
            StyleCloseButton(FindCloseButton(f), f)
            f._duiTradeSkillSkinned = true
        end)
        if not ok then
            addon:Error('BlizzardArt TradeSkillFrame skin failed: ' .. tostring(err))
            return false
        end
    end
    return true
end

-- Professions: hook Show when the frame exists (retried from StartTalentRetry).
HookTradeSkillShow = function()
    local f = _G.TradeSkillFrame
    if f and f.Show and not tradeskillShowHooked and hooksecurefunc then
        tradeskillShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- ============================================================================
-- LIFECYCLE
-- ============================================================================

function BlizzardArt:Apply()
    if not IsModuleEnabled() then return end
    -- Spellbook stays the current focus; Apply() also re-runs tab spacing.
    ApplySpellBook()
    ApplyTalentFrame()
    ApplyCharacterFrame()
    ApplyQuestLogFrame()
    ApplyPVEFrame()
    ApplyPVPUIFrame()
    ApplyPetJournal()
    ApplyGuildFrame()
    ApplyFriendsFrame()
    ApplyMailFrame()
    ApplyEncounterJournal()
    ApplyMacroFrame()
    ApplyInspectFrame()
    ApplyTradeSkillFrame()
    BlizzardArt.applied = true
end

function BlizzardArt:Restore()
    -- Load-once style module: disabling takes effect on next reload.
end

-- Apply on login and re-apply on every Show; keep tab spacing after Blizzard
-- re-lays the tabs. Hooks are installed once the frames actually exist.
local eventFrame = CreateFrame('Frame')
local showHooked, updateHooked, coreUpdateHooked
local talentShowHooked, talentToggleHooked, talentUpdateHooked
local charShowHooked, questShowHooked
local tabResizeHooked, tabUpdateHooked
local charUpdateHooked, spellUpdateHooked
local HookTalentTabUpdates

-- Declared above via `local HookTalentTabUpdates`; assigned here.
HookTalentTabUpdates = function()
    if talentUpdateHooked or not _G.PlayerTalentFrame_UpdateTabs or not hooksecurefunc then return end
    talentUpdateHooked = true
    hooksecurefunc('PlayerTalentFrame_UpdateTabs', function()
        if not InCombatLockdown() then
            RefreshTalentTabWidths()
        end
    end)
end

-- Talents: the frame may not exist at PLAYER_LOGIN, so hook it lazily.
local function HookTalentFrameShow()
    local f = _G.PlayerTalentFrame or _G.TalentFrame
    if f and f.Show and not talentShowHooked and hooksecurefunc then
        talentShowHooked = true
        hooksecurefunc(f, 'Show', function()
            if addon.debugMode then DumpFrameTextures(f) end
            BlizzardArt:Apply()
        end)
        if HookTalentTabUpdates then
            HookTalentTabUpdates()
        end
        return true
    end
    return false
end

-- Character (C): hook Show when the frame exists (retried from StartTalentRetry).
local function HookCharacterFrameShow()
    local f = _G.CharacterFrame
    if f and f.Show and not charShowHooked and hooksecurefunc then
        charShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

-- Quest Log (L): hook Show when the frame exists.
local function HookQuestLogFrameShow()
    local f = _G.QuestLogFrame
    if f and f.Show and not questShowHooked and hooksecurefunc then
        questShowHooked = true
        hooksecurefunc(f, 'Show', function()
            BlizzardArt:Apply()
        end)
        return true
    end
    return false
end

local talentRetryFrame = CreateFrame('Frame')
local talentRetryTicks = 0

local function StartTalentRetry()
    talentRetryTicks = 0
    talentRetryFrame:SetScript('OnUpdate', function(self)
        talentRetryTicks = talentRetryTicks + 1
        if (HookTalentFrameShow() or HookCharacterFrameShow() or HookQuestLogFrameShow() or HookPVEFrameShow() or HookPVPUIFrameShow() or HookPetJournalShow() or HookGuildFrameShow() or HookFriendsFrameShow() or HookMailFrameShow() or HookEncounterJournalShow() or HookMacroFrameShow() or HookInspectFrameShow() or HookTradeSkillShow()) or talentRetryTicks > 60 then
            self:Hide()
            self:SetScript('OnUpdate', nil)
        end
    end)
    talentRetryFrame:Show()
end

local function HookTalentToggle()
    if talentToggleHooked or not _G.ToggleTalentFrame or not hooksecurefunc then return end
    talentToggleHooked = true
    hooksecurefunc('ToggleTalentFrame', function()
        if addon.core and addon.core.ScheduleTimer then
            addon.core:ScheduleTimer(function()
                HookTalentFrameShow()
                BlizzardArt:Apply()
            end, 0)
        else
            HookTalentFrameShow()
            BlizzardArt:Apply()
        end
    end)
end

-- Hook the OnShow/OnHide of a family of tab buttons (CharacterFrameTab1..N,
-- SpellBookFrameTabButton1..N, PlayerTalentFrameTab1..N) so a tab becoming
-- visible/hidden (e.g. the Pet tab when mounting) re-applies the row layout.
local function HookTabVisibility(prefix, maxTabs)
    for i = 1, maxTabs do
        local tab = _G[prefix .. i]
        if tab and tab.HookScript and not tab._duiTabVisHooked then
            tab._duiTabVisHooked = true
            tab:HookScript('OnShow', ScheduleReapplyTabLayouts)
            tab:HookScript('OnHide', ScheduleReapplyTabLayouts)
        end
    end
end

local function InstallFrameHooks()
    if not showHooked and _G.SpellBookFrame and hooksecurefunc then
        showHooked = true
        hooksecurefunc(_G.SpellBookFrame, 'Show', function()
            BlizzardArt:Apply()
        end)
    end
    if not updateHooked and _G.SpellBookFrame_Update and hooksecurefunc then
        updateHooked = true
        hooksecurefunc('SpellBookFrame_Update', function()
            if not InCombatLockdown() then
                RepositionSpellBookTabs()
                SkinCoreSpecTabs()
            end
        end)
    end
    -- Core Abilities rebuilds its spec tabs without a full frame update.
    if not coreUpdateHooked and _G.SpellBook_UpdateCoreAbilitiesTab and hooksecurefunc then
        coreUpdateHooked = true
        hooksecurefunc('SpellBook_UpdateCoreAbilitiesTab', function()
            if not InCombatLockdown() then
                SkinCoreSpecTabs()
            end
        end)
    end
    -- Blizzard re-lays the tab row on resize/update (e.g. the Pet tab
    -- appearing/disappearing): re-apply our width/height/spacing afterwards.
    if not tabResizeHooked and _G.PanelTemplates_TabResize and hooksecurefunc then
        tabResizeHooked = true
        hooksecurefunc('PanelTemplates_TabResize', ScheduleReapplyTabLayouts)
    end
    if not tabUpdateHooked and _G.PanelTemplates_UpdateTabs and hooksecurefunc then
        tabUpdateHooked = true
        hooksecurefunc('PanelTemplates_UpdateTabs', ScheduleReapplyTabLayouts)
    end
    if not charUpdateHooked and _G.CharacterFrame_UpdateTabs and hooksecurefunc then
        charUpdateHooked = true
        hooksecurefunc('CharacterFrame_UpdateTabs', ScheduleReapplyTabLayouts)
    end
    if not spellUpdateHooked and _G.SpellBookFrame_UpdateTabs and hooksecurefunc then
        spellUpdateHooked = true
        hooksecurefunc('SpellBookFrame_UpdateTabs', ScheduleReapplyTabLayouts)
    end

    HookTabVisibility('CharacterFrameTab', 8)
    HookTabVisibility('SpellBookFrameTabButton', 5)
    HookTabVisibility('PlayerTalentFrameTab', 8)

    -- Talents (N): lazy Show hook + opener hook so the chrome applies without
    -- the manual /dragonui talent command.
    HookTalentFrameShow()
    HookTalentToggle()
    HookCharacterFrameShow()
    HookQuestLogFrameShow()
    HookPVEFrameShow()
    HookPVPUIFrameShow()
    HookPetJournalShow()
    HookGuildFrameShow()
    HookFriendsFrameShow()
    HookMailFrameShow()
    HookEncounterJournalShow()
    HookMacroFrameShow()
    HookInspectFrameShow()
    HookTradeSkillShow()
end

eventFrame:RegisterEvent('PLAYER_LOGIN')
eventFrame:RegisterEvent('ADDON_LOADED')
eventFrame:RegisterEvent('UNIT_PET')
eventFrame:RegisterEvent('PET_BAR_UPDATE')
eventFrame:RegisterEvent('PLAYER_REGEN_ENABLED')
eventFrame:SetScript('OnEvent', function(self, event)
    if event == 'PLAYER_LOGIN' then
        InstallFrameHooks()
        StartTalentRetry()
        BlizzardArt:Apply()
    elseif event == 'ADDON_LOADED' then
        -- Late-loaded Blizzard frames (e.g. the PvP window, loaded on demand
        -- when pressing H) may not exist when PLAYER_LOGIN ran. Re-install the
        -- lazy hooks (idempotent) and apply so such a frame gets its skin the
        -- moment it becomes available - without needing another DragonUI window
        -- to be opened first.
        InstallFrameHooks()
        if not InCombatLockdown() then
            BlizzardArt:Apply()
        end
    elseif event == 'UNIT_PET' or event == 'PET_BAR_UPDATE' or event == 'PLAYER_REGEN_ENABLED' then
        -- Pet appearing/disappearing (mount/fly/land) re-lays the Pet tab;
        -- re-apply our configured tab dimensions once Blizzard is done.
        ScheduleReapplyTabLayouts()
    end
end)

-- Register last, after all methods exist, mirroring the proven darkmode call.
local regOk, regErr = pcall(addon.RegisterModule, addon, "blizzardart", BlizzardArt,
    "Blizzard Panels Skin",
    "Replaces vanilla Blizzard panel chrome with the DragonUI metal kit.")
if not regOk then
    addon:Error("BlizzardArt registration failed: " .. tostring(regErr))
end

BlizzardArt.hooksInstalled = true
