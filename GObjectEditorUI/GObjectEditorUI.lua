local ADDON_PREFIX = "GE"
local ACCESS_REQUEST = "HELLO:GOBJECT_EDITOR_ACCESS"
local ACCESS_VERIFIED = "HELLO:GOBJECT_EDITOR_ACCESS_VERIFIED"

local ROW_HEIGHT = 20
local VISIBLE_ROWS = 7
local SEARCH_VISIBLE_ROWS = 12
local UpdateSelectedText
local UpdateCompactStatus

local state = {
    access = false,
    selectedGuid = nil,
    selectedKind = nil,
    selectedObject = nil,
    restoreAvailable = false,
    objects = {},
    rows = {},
    undoSteps = 0,
    searchResults = {},
    searchRows = {},
    selectedTemplate = nil,
    lastPlacedCreatureGuid = nil,
    lastPlacedCreatureEntry = nil,
    lastPlacedCreatureName = nil,
    searchMode = "GOBJECT",
    moveMode = "PLAYER",
    searchPreviewFacing = 0.35,
    searchPreviewScale = 1.0,
    searchPreviewYOffset = 0.0,
}

local controlledButtons = {}
local selectionButtons = {}

local function SendGE(payload)
    SendAddonMessage(ADDON_PREFIX, payload, "WHISPER", UnitName("player"))
end

local function SetText(fs, text)
    if fs then
        fs:SetText(text or "")
    end
end

local function PlayEditorClickSound()
    if PlaySoundFile then
        pcall(PlaySoundFile, "Interface\\AddOns\\GObjectEditorUI\\Sounds\\ButtonClick.ogg")
    end
end

local function SafeName(value)
    if value == nil or value == "" then
        return "Unknown"
    end
    return value
end

local function NumberOr(text, fallback)
    local value = tonumber(text)
    if not value or value <= 0 then
        return fallback
    end
    return value
end

local function FormatNumber(value)
    local n = tonumber(value)
    if not n then
        return "-"
    end
    return string.format("%.4f", n)
end

local function FormatCompactNumber(value)
    local n = tonumber(value)
    if not n then
        return "-"
    end
    return string.format("%.3f", n)
end

local function AddTooltip(btn, text)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text or "", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

local function AttachDecimalOnly(editBox, fallbackText)
    editBox._geSanitizing = false

    editBox:SetScript("OnTextChanged", function(self)
        if self._geSanitizing then
            return
        end

        local text = self:GetText() or ""
        local cleaned = ""
        local hasDot = false

        for i = 1, string.len(text) do
            local c = string.sub(text, i, i)
            if string.match(c, "%d") then
                cleaned = cleaned .. c
            elseif c == "." and not hasDot then
                cleaned = cleaned .. c
                hasDot = true
            end
        end

        if cleaned ~= text then
            self._geSanitizing = true
            self:SetText(cleaned)
            self:SetCursorPosition(string.len(cleaned))
            self._geSanitizing = false
        end
    end)

    editBox:SetScript("OnEditFocusLost", function(self)
        local value = tonumber(self:GetText())
        if not value or value <= 0 then
            self:SetText(fallbackText or "0.10")
            self:SetCursorPosition(0)
        end
    end)
end

local frame = CreateFrame("Frame", "GObjectEditorUIFrame", UIParent)
frame:SetSize(880, 560)
frame:SetPoint("CENTER")
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
frame:SetBackdropColor(0.02, 0.025, 0.03, 0.96)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
frame.title:SetPoint("TOP", frame, "TOP", 0, -14)
frame.title:SetText("Game Object Editor")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)

local function MakePanel(parent, name)
    local panel = CreateFrame("Frame", name, parent)
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    panel:SetBackdropColor(0.015, 0.025, 0.035, 0.55)
    panel:SetBackdropBorderColor(0.45, 0.35, 0.18, 0.95)
    return panel
end

local function MakeLabel(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    return fs
end

local function MakeEditBox(parent, text, width)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(width or 70, 24)
    eb:SetAutoFocus(false)
    eb:SetText(text or "")
    eb:SetCursorPosition(0)
    return eb
end

local function MakeButton(parent, text, width, height, onClick, tooltip)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width or 120, height or 30)
    btn:SetText(text or "")
    btn:SetScript("OnClick", function(self, button)
        PlayEditorClickSound()
        if onClick then
            onClick(self, button)
        end
    end)

    local fs = btn:GetFontString()
    if fs then
        fs:SetFontObject(GameFontHighlightSmall)
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
        fs:SetJustifyH("CENTER")
        fs:SetWidth((width or 120) - 8)
    end

    if tooltip then
        AddTooltip(btn, tooltip)
    end

    return btn
end

local NPC_ROTATION_UNSUPPORTED_STATUS = "Status: NPCs do not support rotation buttons. Face your character before placing an NPC."
local NPC_ROTATION_UNSUPPORTED_TOOLTIP = "GameObjects only. NPCs do not support rotation buttons.\nFor NPC facing, turn your character before placing the NPC."
local GOBJ_YAW_LEFT_TOOLTIP = "GameObjects: yaw left by the current Step value in degrees.\nNPCs: rotation buttons are not supported."
local GOBJ_YAW_RIGHT_TOOLTIP = "GameObjects: yaw right by the current Step value in degrees.\nNPCs: rotation buttons are not supported."
local GOBJ_PITCH_FORWARD_TOOLTIP = "GameObjects: pitch forward by the current Step value in degrees.\nNPCs: rotation buttons are not supported."
local GOBJ_PITCH_BACK_TOOLTIP = "GameObjects: pitch backward by the current Step value in degrees.\nNPCs: rotation buttons are not supported."
local GOBJ_ROLL_LEFT_TOOLTIP = "GameObjects: roll left by the current Step value in degrees.\nNPCs: rotation buttons are not supported."
local GOBJ_ROLL_RIGHT_TOOLTIP = "GameObjects: roll right by the current Step value in degrees.\nNPCs: rotation buttons are not supported."

local function SetButtonListEnabled(buttons, enabled)
    for _, btn in ipairs(buttons) do
        if enabled then
            btn:Enable()
        else
            btn:Disable()
        end
    end
end

local function RefreshEnabledState()
    SetButtonListEnabled(controlledButtons, state.access)

    local hasSelection = state.selectedGuid ~= nil
    local gobjectSelected = hasSelection and state.selectedKind ~= "NPC"
    local npcSelected = hasSelection and state.selectedKind == "NPC"
    SetButtonListEnabled(selectionButtons, state.access and gobjectSelected)

    local canDelete = state.access and (hasSelection or state.lastPlacedCreatureGuid ~= nil)
    if frame.deleteButton then
        if canDelete then
            frame.deleteButton:Enable()
        else
            frame.deleteButton:Disable()
        end
    end
    if frame.controlsOnlyDeleteButton then
        if canDelete then
            frame.controlsOnlyDeleteButton:Enable()
        else
            frame.controlsOnlyDeleteButton:Disable()
        end
    end

    local canResetOriginal = state.access and ((gobjectSelected and (tonumber(state.undoSteps) or 0) > 0) or npcSelected)
    if frame.resetButton then
        if canResetOriginal then
            frame.resetButton:Enable()
        else
            frame.resetButton:Disable()
        end
    end
    if frame.controlsOnlyResetButton then
        if canResetOriginal then
            frame.controlsOnlyResetButton:Enable()
        else
            frame.controlsOnlyResetButton:Disable()
        end
    end

    if frame.undoButton then
        if state.access and hasSelection then
            frame.undoButton:Enable()
        else
            frame.undoButton:Disable()
        end
    end
    if frame.controlsOnlyUndoButton then
        if state.access and hasSelection then
            frame.controlsOnlyUndoButton:Enable()
        else
            frame.controlsOnlyUndoButton:Disable()
        end
    end
    if frame.saveButton then
        if state.access and hasSelection then
            frame.saveButton:Enable()
        else
            frame.saveButton:Disable()
        end
    end
    if frame.restoreButton then
        if state.access and hasSelection and state.restoreAvailable then
            frame.restoreButton:Enable()
        else
            frame.restoreButton:Disable()
        end
    end

    -- Movement works for both GameObjects and NPCs.
    -- Rotation buttons are GameObject-only; NPC facing is controlled by player orientation when placing.
    local canMoveOrRotate = state.access and hasSelection
    local movementRotationButtons = {
        frame.forwardButton, frame.backButton, frame.upButton, frame.leftButton, frame.rightButton, frame.downButton,
        frame.yawLeftButton, frame.yawRightButton, frame.pitchForwardButton, frame.pitchBackButton, frame.rollLeftButton, frame.rollRightButton,
        frame.coForwardButton, frame.coBackButton, frame.coUpButton, frame.coLeftButton, frame.coRightButton, frame.coDownButton,
        frame.coYawLeftButton, frame.coYawRightButton, frame.coPitchForwardButton, frame.coPitchBackButton, frame.coRollLeftButton, frame.coRollRightButton,
    }
    SetButtonListEnabled(movementRotationButtons, canMoveOrRotate)
end

local function CurrentRadius()
    return NumberOr(frame.radiusBox and frame.radiusBox:GetText(), 5)
end

local function CurrentStep()
    return NumberOr(frame.stepBox and frame.stepBox:GetText(), 0.10)
end

local function MoveModeDisplayName()
    if state.moveMode == "OBJECT" then
        return "Object"
    end
    return "Player"
end

local function CurrentMoveMode()
    if state.moveMode == "OBJECT" then
        return "OBJECT"
    end
    return "PLAYER"
end

local function UpdateMoveModeControls()
    local checked = state.moveMode == "OBJECT"
    if frame.objectMoveCheck then
        frame.objectMoveCheck:SetChecked(checked)
    end
    if frame.controlsOnlyObjectMoveCheck then
        frame.controlsOnlyObjectMoveCheck:SetChecked(checked)
    end
end

local function ToggleMoveMode()
    if state.moveMode == "OBJECT" then
        state.moveMode = "PLAYER"
    else
        state.moveMode = "OBJECT"
    end

    UpdateMoveModeControls()
    SetText(frame.status, "Status: move mode set to " .. MoveModeDisplayName())
    if frame.controlsOnlyStatus and frame.controlsOnlyFrame and frame.controlsOnlyFrame:IsShown() then
        UpdateCompactStatus()
    end
end

local function Nudge(dir)
    if state.selectedGuid and state.selectedKind == "NPC" then
        SetText(frame.status, "Status: moving NPC GUID " .. tostring(state.selectedGuid) .. "...")
        SendGE("NUDGE_CREATURE:" .. tostring(state.selectedGuid) .. ":" .. dir .. ":" .. tostring(CurrentStep()) .. ":" .. CurrentMoveMode())
        return
    end

    SendGE("NUDGE:" .. dir .. ":" .. tostring(CurrentStep()) .. ":" .. CurrentMoveMode())
end

local function Rotate(axis, sign)
    if state.selectedGuid and state.selectedKind == "NPC" then
        SetText(frame.status, NPC_ROTATION_UNSUPPORTED_STATUS)
        if frame.controlsOnlyStatus and frame.controlsOnlyFrame and frame.controlsOnlyFrame:IsShown() then
            frame.controlsOnlyStatus:SetText("NPC rotation is not supported. Face before placing.")
        end
        return
    end

    SendGE("ROTATE:" .. axis .. ":" .. tostring(sign * CurrentStep()))
end

local function DeleteSelectedObject()
    if state.selectedGuid and state.selectedKind == "NPC" then
        SetText(frame.status, "Status: deleting NPC GUID " .. tostring(state.selectedGuid) .. "...")
        SendGE("DELETE_CREATURE_SELECTED:" .. tostring(state.selectedGuid))
        return
    end

    if state.selectedGuid then
        SetText(frame.status, "Status: deleting GameObject GUID " .. tostring(state.selectedGuid) .. "...")
        SendGE("DELETE_SELECTED:" .. tostring(state.selectedGuid))
        return
    end

    if state.lastPlacedCreatureGuid then
        SetText(frame.status, "Status: deleting last placed NPC GUID " .. tostring(state.lastPlacedCreatureGuid) .. "...")
        SendGE("DELETE_CREATURE_SELECTED:" .. tostring(state.lastPlacedCreatureGuid))
        return
    end

    SetText(frame.status, "Status: no selected object or NPC to delete")
end

local function UndoSelectedPosition()
    if state.selectedGuid and state.selectedKind == "NPC" then
        SetText(frame.status, "Status: undoing NPC movement for GUID " .. tostring(state.selectedGuid) .. "...")
        SendGE("UNDO_CREATURE:" .. tostring(state.selectedGuid))
        return
    end

    SendGE("UNDO")
end

local function SaveSelectedPosition()
    if state.selectedGuid and state.selectedKind == "NPC" then
        SetText(frame.status, "Status: marking NPC restore position for GUID " .. tostring(state.selectedGuid) .. "...")
        SendGE("SAVE_CREATURE:" .. tostring(state.selectedGuid))
        return
    end

    SendGE("SAVE")
end

local function RestoreSelectedPosition()
    if state.selectedGuid and state.selectedKind == "NPC" then
        SetText(frame.status, "Status: restoring NPC saved position for GUID " .. tostring(state.selectedGuid) .. "...")
        SendGE("RESTORE_CREATURE_POSITION:" .. tostring(state.selectedGuid))
        return
    end

    SendGE("RESTORE_SAVED_POSITION")
end

local function ResetToOriginalPosition()
    if state.selectedGuid and state.selectedKind == "NPC" then
        SetText(frame.status, "Status: resetting selected NPC to original position...")
        SendGE("RESET_CREATURE_TO_ORIGINAL:" .. tostring(state.selectedGuid))
        return
    end

    if state.selectedGuid and state.selectedKind ~= "NPC" then
        SetText(frame.status, "Status: resetting selected GameObject to original position...")
        SendGE("RESET_TO_ORIGINAL")
        return
    end

    SetText(frame.status, "Status: no selected object or NPC reset available")
end

local function BuildCompactStatusText()
    local obj = state.selectedObject
    if not obj then
        return "Selected: -"
    end

    local label = state.selectedKind == "NPC" and "[NPC]" or "[GOBJ]"

    return label .. " " .. tostring(obj.guid or "-") ..
        "  X:" .. FormatCompactNumber(obj.x) .. " Y:" .. FormatCompactNumber(obj.y) .. "\n" ..
        "Z:" .. FormatCompactNumber(obj.z) .. "  O:" .. FormatCompactNumber(obj.o)
end
UpdateCompactStatus = function()
    if frame and frame.controlsOnlyStatus then
        frame.controlsOnlyStatus:SetText(BuildCompactStatusText())
    end
end

-- Main fixed layout sections. These are intentionally fixed-size first.
frame.leftPanel = MakePanel(frame, "GObjectEditorUILeftPanel")
frame.leftPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -44)
frame.leftPanel:SetSize(145, 496)

frame.centerPanel = MakePanel(frame, "GObjectEditorUICenterPanel")
frame.centerPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 177, -44)
frame.centerPanel:SetSize(510, 496)

frame.rightPanel = MakePanel(frame, "GObjectEditorUIRightPanel")
frame.rightPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 699, -44)
frame.rightPanel:SetSize(161, 496)

-- Session / actions
frame.sessionTitle = MakeLabel(frame.leftPanel, "SESSION", "GameFontNormal")
frame.sessionTitle:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 12, -10)

frame.status = MakeLabel(frame.leftPanel, "Status: Checking GM access...", "GameFontNormalSmall")
frame.status:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 12, -34)
frame.status:SetWidth(121)

frame.searchButton = MakeButton(frame.leftPanel, "Search", 115, 30, function()
    frame.searchPlaceFrame:SetFrameStrata("DIALOG")
    frame.searchPlaceFrame:SetFrameLevel(frame:GetFrameLevel() + 50)
    frame.searchPlaceFrame:Show()
    frame.searchPlaceFrame:Raise()
    SetText(frame.status, "Status: search window opened")
end, "Open the Search / Place window.")
frame.searchButton:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 15, -82)

frame.deleteButton = MakeButton(frame.leftPanel, "Delete", 115, 30, function()
    DeleteSelectedObject()
end, "Delete the selected [GOBJ] or [NPC] from Objects in View.")
frame.deleteButton:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 15, -120)

frame.undoButton = MakeButton(frame.leftPanel, "Undo", 115, 30, function()
    UndoSelectedPosition()
end, "Undo the last movement step for the selected [GOBJ] or [NPC].")
frame.undoButton:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 15, -158)

frame.resetButton = MakeButton(frame.leftPanel, "Reset", 115, 30, function()
    ResetToOriginalPosition()
end, "Jump the selected [GOBJ] or [NPC] back to the original selected/scanned position.")
frame.resetButton:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 15, -196)

frame.faceButton = MakeButton(frame.leftPanel, "Face Me", 115, 30, function()
    SendGE("FACE_ME")
end, "Face the selected preview object toward your character.")
frame.faceButton:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 15, -234)

frame.saveButton = MakeButton(frame.leftPanel, "Save to DB", 115, 30, function()
    SaveSelectedPosition()
end, "GameObjects: save preview to DB.\nNPCs: mark current position as the restore point.")
frame.saveButton:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 15, -272)

frame.restoreButton = MakeButton(frame.leftPanel, "Restore\nSaved Position", 115, 42, function()
    RestoreSelectedPosition()
end, "Restore the selected [GOBJ] or [NPC] to its saved position from this session.")
frame.restoreButton:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 15, -310)

frame.undoStatusText = MakeLabel(frame.leftPanel, "At original position", "GameFontNormalSmall")
frame.undoStatusText:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 12, -381)
frame.undoStatusText:SetWidth(121)

frame.restoreText = MakeLabel(frame.leftPanel, "No session restore position available.", "GameFontDisableSmall")
frame.restoreText:SetPoint("TOPLEFT", frame.leftPanel, "TOPLEFT", 12, -406)
frame.restoreText:SetWidth(121)

-- Center panel
frame.centerTitle = MakeLabel(frame.centerPanel, "SCAN / OBJECT SELECTION", "GameFontNormal")
frame.centerTitle:SetPoint("TOPLEFT", frame.centerPanel, "TOPLEFT", 12, -10)

frame.radiusLabel = MakeLabel(frame.centerPanel, "Radius", "GameFontNormalSmall")
frame.radiusLabel:SetPoint("TOPLEFT", frame.centerPanel, "TOPLEFT", 14, -38)

frame.radiusBox = MakeEditBox(frame.centerPanel, "5", 52)
frame.radiusBox:SetPoint("LEFT", frame.radiusLabel, "RIGHT", 8, 0)
AttachDecimalOnly(frame.radiusBox, "5")

local function ExecuteRadiusScan()
    if frame.radiusBox then
        frame.radiusBox:ClearFocus()
    end

    local d = CurrentRadius()
    state.objects = {}
    state.selectedGuid = nil
    state.selectedKind = nil
    state.selectedObject = nil
    state.restoreAvailable = false
    state.undoSteps = 0
    FauxScrollFrame_SetOffset(frame.objectScrollFrame, 0)
    SetText(frame.undoStatusText, "At original position")
    SetText(frame.restoreText, "No session restore position available.")
    UpdateCompactStatus()
    SendGE("SCAN:" .. tostring(d))
    RefreshEnabledState()
    SetText(frame.status, "Status: scanning radius...")
end

frame.scanButton = MakeButton(frame.centerPanel, "Scan Radius", 112, 24, function()
    ExecuteRadiusScan()
end, "Scan nearby gameobjects and NPCs within the selected radius.")
frame.scanButton:SetPoint("LEFT", frame.radiusBox, "RIGHT", 14, 0)
frame.radiusBox:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    ExecuteRadiusScan()
end)
frame.radiusBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)

frame.refreshPreviewButton = MakeButton(frame.centerPanel, "Refresh Preview", 130, 24, function()
    SendGE("REFRESH_PREVIEW")
end, "Respawn the temporary Selection Preview clone at the current preview position.")
frame.refreshPreviewButton:SetPoint("LEFT", frame.scanButton, "RIGHT", 8, 0)

-- Object list
frame.objectsPanel = MakePanel(frame.centerPanel, "GObjectEditorUIObjectsPanel")
frame.objectsPanel:SetPoint("TOPLEFT", frame.centerPanel, "TOPLEFT", 10, -74)
frame.objectsPanel:SetSize(490, 216)

frame.objectsTitle = MakeLabel(frame.objectsPanel, "Objects in View", "GameFontNormal")
frame.objectsTitle:SetPoint("TOPLEFT", frame.objectsPanel, "TOPLEFT", 10, -8)

frame.guidHeader = MakeLabel(frame.objectsPanel, "GUID", "GameFontNormalSmall")
frame.guidHeader:SetPoint("TOPLEFT", frame.objectsPanel, "TOPLEFT", 10, -32)

frame.entryHeader = MakeLabel(frame.objectsPanel, "Entry", "GameFontNormalSmall")
frame.entryHeader:SetPoint("TOPLEFT", frame.objectsPanel, "TOPLEFT", 110, -32)

frame.nameHeader = MakeLabel(frame.objectsPanel, "Name", "GameFontNormalSmall")
frame.nameHeader:SetPoint("TOPLEFT", frame.objectsPanel, "TOPLEFT", 178, -32)

frame.distHeader = MakeLabel(frame.objectsPanel, "Dist", "GameFontNormalSmall")
frame.distHeader:SetPoint("TOPRIGHT", frame.objectsPanel, "TOPRIGHT", -38, -32)

frame.objectScrollFrame = CreateFrame("ScrollFrame", "GObjectEditorUIObjectScrollFrame", frame.objectsPanel, "FauxScrollFrameTemplate")
frame.objectScrollFrame:SetPoint("TOPLEFT", frame.objectsPanel, "TOPLEFT", 8, -52)
frame.objectScrollFrame:SetPoint("BOTTOMRIGHT", frame.objectsPanel, "BOTTOMRIGHT", -26, 24)

frame.objectsCount = MakeLabel(frame.objectsPanel, "0 object(s) shown", "GameFontDisableSmall")
frame.objectsCount:SetPoint("BOTTOMLEFT", frame.objectsPanel, "BOTTOMLEFT", 10, 7)

-- Controls
frame.controlsPanel = MakePanel(frame.centerPanel, "GObjectEditorUIControlsPanel")
frame.controlsPanel:SetPoint("TOPLEFT", frame.centerPanel, "TOPLEFT", 10, -300)
frame.controlsPanel:SetSize(490, 184)

frame.stepLabel = MakeLabel(frame.controlsPanel, "Step", "GameFontNormalSmall")
frame.stepLabel:SetPoint("TOPLEFT", frame.controlsPanel, "TOPLEFT", 10, -8)

frame.stepBox = MakeEditBox(frame.controlsPanel, "0.10", 56)
frame.stepBox:SetPoint("LEFT", frame.stepLabel, "RIGHT", 8, 0)
AttachDecimalOnly(frame.stepBox, "0.10")
frame.stepBox:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
end)
frame.stepBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)

frame.objectMoveCheck = CreateFrame("CheckButton", nil, frame.controlsPanel, "UICheckButtonTemplate")
frame.objectMoveCheck:SetPoint("LEFT", frame.stepBox, "RIGHT", 12, 0)
frame.objectMoveCheck:SetSize(22, 22)
frame.objectMoveCheck:SetChecked(state.moveMode == "OBJECT")
AddTooltip(frame.objectMoveCheck, "Unchecked: movement uses your character facing.\nChecked: movement uses the selected GameObject or NPC orientation.")
frame.objectMoveCheckLabel = frame.controlsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.objectMoveCheckLabel:SetPoint("LEFT", frame.objectMoveCheck, "RIGHT", 1, 0)
frame.objectMoveCheckLabel:SetText("Object Move")
frame.objectMoveCheck:SetScript("OnClick", function(self)
    PlayEditorClickSound()
    state.moveMode = self:GetChecked() and "OBJECT" or "PLAYER"
    UpdateMoveModeControls()
    SetText(frame.status, "Status: move mode set to " .. MoveModeDisplayName())
    if frame.controlsOnlyStatus and frame.controlsOnlyFrame and frame.controlsOnlyFrame:IsShown() then
        UpdateCompactStatus()
    end
end)

frame.controlsOnlyCheck = CreateFrame("CheckButton", nil, frame.controlsPanel, "UICheckButtonTemplate")
frame.controlsOnlyCheck:SetPoint("TOPRIGHT", frame.controlsPanel, "TOPRIGHT", -14, -4)
frame.controlsOnlyCheck:SetSize(22, 22)
frame.controlsOnlyCheckText = frame.controlsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.controlsOnlyCheckText:SetPoint("RIGHT", frame.controlsOnlyCheck, "LEFT", -2, 0)
frame.controlsOnlyCheckText:SetText("Controls Only")
frame.controlsOnlyCheck:SetScript("OnClick", function(self)
    PlayEditorClickSound()
    if self:GetChecked() then
        frame:Hide()
        frame.controlsOnlyFrame:Show()
        UpdateCompactStatus()
    end
end)

frame.movementLabel = MakeLabel(frame.controlsPanel, "Movement", "GameFontNormal")
frame.movementLabel:SetPoint("TOPLEFT", frame.controlsPanel, "TOPLEFT", 10, -34)

local buttonW = 148
local buttonH = 23
local buttonGap = 8
local gridX = 10

local function PlaceGridButton(btn, col, row, startY)
    btn:SetPoint("TOPLEFT", frame.controlsPanel, "TOPLEFT", gridX + ((col - 1) * (buttonW + buttonGap)), startY - ((row - 1) * 27))
end

frame.forwardButton = MakeButton(frame.controlsPanel, "Forward", buttonW, buttonH, function() Nudge("FORWARD") end)
PlaceGridButton(frame.forwardButton, 1, 1, -56)

frame.backButton = MakeButton(frame.controlsPanel, "Back", buttonW, buttonH, function() Nudge("BACK") end)
PlaceGridButton(frame.backButton, 2, 1, -56)

frame.upButton = MakeButton(frame.controlsPanel, "Up", buttonW, buttonH, function() Nudge("UP") end)
PlaceGridButton(frame.upButton, 3, 1, -56)

frame.leftButton = MakeButton(frame.controlsPanel, "Left", buttonW, buttonH, function() Nudge("LEFT") end)
PlaceGridButton(frame.leftButton, 1, 2, -56)

frame.rightButton = MakeButton(frame.controlsPanel, "Right", buttonW, buttonH, function() Nudge("RIGHT") end)
PlaceGridButton(frame.rightButton, 2, 2, -56)

frame.downButton = MakeButton(frame.controlsPanel, "Down", buttonW, buttonH, function() Nudge("DOWN") end)
PlaceGridButton(frame.downButton, 3, 2, -56)

frame.rotationLabel = MakeLabel(frame.controlsPanel, "Rotation", "GameFontNormal")
frame.rotationLabel:SetPoint("TOPLEFT", frame.controlsPanel, "TOPLEFT", 10, -106)

frame.yawLeftButton = MakeButton(frame.controlsPanel, "Yaw Left", buttonW, buttonH, function() Rotate("YAW", -1) end, GOBJ_YAW_LEFT_TOOLTIP)
PlaceGridButton(frame.yawLeftButton, 1, 1, -126)

frame.yawRightButton = MakeButton(frame.controlsPanel, "Yaw Right", buttonW, buttonH, function() Rotate("YAW", 1) end, GOBJ_YAW_RIGHT_TOOLTIP)
PlaceGridButton(frame.yawRightButton, 2, 1, -126)

frame.pitchForwardButton = MakeButton(frame.controlsPanel, "Pitch Forward", buttonW, buttonH, function() Rotate("PITCH", 1) end, GOBJ_PITCH_FORWARD_TOOLTIP)
PlaceGridButton(frame.pitchForwardButton, 3, 1, -126)

frame.pitchBackButton = MakeButton(frame.controlsPanel, "Pitch Back", buttonW, buttonH, function() Rotate("PITCH", -1) end, GOBJ_PITCH_BACK_TOOLTIP)
PlaceGridButton(frame.pitchBackButton, 1, 2, -126)

frame.rollLeftButton = MakeButton(frame.controlsPanel, "Roll Left", buttonW, buttonH, function() Rotate("ROLL", -1) end, GOBJ_ROLL_LEFT_TOOLTIP)
PlaceGridButton(frame.rollLeftButton, 2, 2, -126)

frame.rollRightButton = MakeButton(frame.controlsPanel, "Roll Right", buttonW, buttonH, function() Rotate("ROLL", 1) end, GOBJ_ROLL_RIGHT_TOOLTIP)
PlaceGridButton(frame.rollRightButton, 3, 2, -126)

-- Right panel / selected object
frame.previewTitle = MakeLabel(frame.rightPanel, "SELECTION PREVIEW", "GameFontNormal")
frame.previewTitle:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 10, -10)
frame.previewTitle:Hide()

frame.previewBox = MakePanel(frame.rightPanel, "GObjectEditorUIPreviewBox")
frame.previewBox:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 10, -36)
frame.previewBox:Hide()
frame.previewBox:SetSize(141, 86)

frame.previewBoxText = MakeLabel(frame.previewBox, "No selection", "GameFontDisableSmall")
frame.previewBoxText:SetPoint("CENTER", frame.previewBox, "CENTER", 0, 0)
frame.previewBoxText:Hide()
frame.previewBoxText:SetJustifyH("CENTER")
frame.previewBoxText:SetWidth(126)

frame.detailsTitle = MakeLabel(frame.rightPanel, "SELECTED OBJECT", "GameFontNormal")
frame.detailsTitle:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 10, -22)

frame.selectedGuidLabel = MakeLabel(frame.rightPanel, "GUID:", "GameFontNormalSmall")
frame.selectedGuidLabel:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 10, -55)
frame.selectedGuidValue = MakeLabel(frame.rightPanel, "-", "GameFontHighlightSmall")
frame.selectedGuidValue:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 76, -55)
frame.selectedGuidValue:SetWidth(78)

frame.selectedEntryLabel = MakeLabel(frame.rightPanel, "Entry:", "GameFontNormalSmall")
frame.selectedEntryLabel:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 10, -83)
frame.selectedEntryValue = MakeLabel(frame.rightPanel, "-", "GameFontHighlightSmall")
frame.selectedEntryValue:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 76, -83)
frame.selectedEntryValue:SetWidth(78)

frame.selectedNameLabel = MakeLabel(frame.rightPanel, "Name:", "GameFontNormalSmall")
frame.selectedNameLabel:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 10, -111)
frame.selectedNameValue = MakeLabel(frame.rightPanel, "-", "GameFontHighlightSmall")
frame.selectedNameValue:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 76, -111)
frame.selectedNameValue:SetWidth(78)

frame.selectedDistanceLabel = MakeLabel(frame.rightPanel, "Distance:", "GameFontNormalSmall")
frame.selectedDistanceLabel:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 10, -139)
frame.selectedDistanceValue = MakeLabel(frame.rightPanel, "-", "GameFontHighlightSmall")
frame.selectedDistanceValue:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 76, -139)
frame.selectedDistanceValue:SetWidth(78)

frame.positionLabel = MakeLabel(frame.rightPanel, "Position:", "GameFontNormalSmall")
frame.positionLabel:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 10, -184)
frame.positionValue = MakeLabel(frame.rightPanel, "X: -\nY: -\nZ: -", "GameFontHighlightSmall")
frame.positionValue:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 76, -184)
frame.positionValue:SetWidth(78)

frame.rotationLabelRight = MakeLabel(frame.rightPanel, "Rotation:", "GameFontNormalSmall")
frame.rotationLabelRight:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 10, -282)
frame.rotationValue = MakeLabel(frame.rightPanel, "Orientation: -", "GameFontHighlightSmall")
frame.rotationValue:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 76, -282)
frame.rotationValue:SetWidth(78)

frame.previewText = MakeLabel(frame.rightPanel, "No Selection Preview active.", "GameFontNormalSmall")
frame.previewText:SetPoint("TOPLEFT", frame.rightPanel, "TOPLEFT", 10, -340)
frame.previewText:SetWidth(141)


frame.versionText = MakeLabel(frame.rightPanel, "Version: 0.3.2", "GameFontDisableSmall")
frame.versionText:SetPoint("BOTTOMLEFT", frame.rightPanel, "BOTTOMLEFT", 10, 10)
frame.versionText:SetWidth(141)


-- Compact controls-only popout. Same footprint as the existing controls section.
frame.controlsOnlyFrame = MakePanel(UIParent, "GObjectEditorUIControlsOnlyFrame")
frame.controlsOnlyFrame:SetSize(490, 210)
frame.controlsOnlyFrame:SetPoint("CENTER")
frame.controlsOnlyFrame:SetMovable(true)
frame.controlsOnlyFrame:EnableMouse(true)
frame.controlsOnlyFrame:RegisterForDrag("LeftButton")
frame.controlsOnlyFrame:SetScript("OnDragStart", frame.controlsOnlyFrame.StartMoving)
frame.controlsOnlyFrame:SetScript("OnDragStop", frame.controlsOnlyFrame.StopMovingOrSizing)
frame.controlsOnlyFrame:Hide()

frame.controlsOnlyStepLabel = MakeLabel(frame.controlsOnlyFrame, "Step", "GameFontNormalSmall")
frame.controlsOnlyStepLabel:SetPoint("TOPLEFT", frame.controlsOnlyFrame, "TOPLEFT", 10, -8)

frame.controlsOnlyStepBox = MakeEditBox(frame.controlsOnlyFrame, "0.10", 56)
frame.controlsOnlyStepBox:SetPoint("LEFT", frame.controlsOnlyStepLabel, "RIGHT", 8, 0)
AttachDecimalOnly(frame.controlsOnlyStepBox, "0.10")
frame.controlsOnlyStepBox:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
end)
frame.controlsOnlyStepBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)

frame.controlsOnlyObjectMoveCheck = CreateFrame("CheckButton", nil, frame.controlsOnlyFrame, "UICheckButtonTemplate")
frame.controlsOnlyObjectMoveCheck:SetPoint("TOPLEFT", frame.controlsOnlyFrame, "TOPLEFT", 6, -31)
frame.controlsOnlyObjectMoveCheck:SetSize(22, 22)
frame.controlsOnlyObjectMoveCheck:SetChecked(state.moveMode == "OBJECT")
AddTooltip(frame.controlsOnlyObjectMoveCheck, "Unchecked: movement uses your character facing.\nChecked: movement uses the selected GameObject or NPC orientation.")
frame.controlsOnlyObjectMoveCheckLabel = frame.controlsOnlyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.controlsOnlyObjectMoveCheckLabel:SetPoint("LEFT", frame.controlsOnlyObjectMoveCheck, "RIGHT", 1, 0)
frame.controlsOnlyObjectMoveCheckLabel:SetText("Object Move")
frame.controlsOnlyObjectMoveCheck:SetScript("OnClick", function(self)
    PlayEditorClickSound()
    state.moveMode = self:GetChecked() and "OBJECT" or "PLAYER"
    UpdateMoveModeControls()
    SetText(frame.status, "Status: move mode set to " .. MoveModeDisplayName())
    if frame.controlsOnlyStatus and frame.controlsOnlyFrame and frame.controlsOnlyFrame:IsShown() then
        UpdateCompactStatus()
    end
end)

frame.controlsOnlyStatus = MakeLabel(frame.controlsOnlyFrame, "Selected: -", "GameFontNormalSmall")
frame.controlsOnlyStatus:SetPoint("TOPLEFT", frame.controlsOnlyFrame, "TOPLEFT", 210, -7)
frame.controlsOnlyStatus:SetWidth(134)

frame.controlsOnlyUndoButton = MakeButton(frame.controlsOnlyFrame, "Undo", 54, 22, function()
    UndoSelectedPosition()
end)
frame.controlsOnlyUndoButton:SetPoint("TOPLEFT", frame.controlsOnlyFrame, "TOPLEFT", 350, -7)

frame.controlsOnlyDeleteButton = MakeButton(frame.controlsOnlyFrame, "Delete", 54, 22, function()
    DeleteSelectedObject()
end)
frame.controlsOnlyDeleteButton:SetPoint("TOPLEFT", frame.controlsOnlyFrame, "TOPLEFT", 350, -34)

frame.controlsOnlyResetButton = MakeButton(frame.controlsOnlyFrame, "Reset", 54, 22, function()
    ResetToOriginalPosition()
end)
frame.controlsOnlyResetButton:SetPoint("TOPLEFT", frame.controlsOnlyFrame, "TOPLEFT", 410, -34)

frame.fullEditorCheck = CreateFrame("CheckButton", nil, frame.controlsOnlyFrame, "UICheckButtonTemplate")
frame.fullEditorCheck:SetPoint("TOPLEFT", frame.controlsOnlyFrame, "TOPLEFT", 410, -7)
frame.fullEditorCheck:SetSize(22, 22)
frame.fullEditorCheckText = frame.controlsOnlyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.fullEditorCheckText:SetPoint("LEFT", frame.fullEditorCheck, "RIGHT", 0, 0)
frame.fullEditorCheckText:SetText("Full")
frame.fullEditorCheck:SetScript("OnClick", function(self)
    PlayEditorClickSound()
    if self:GetChecked() then
        self:SetChecked(false)
        frame.controlsOnlyCheck:SetChecked(false)
        frame.controlsOnlyFrame:Hide()
        frame:Show()
        UpdateCompactStatus()
    end
end)

local function CurrentControlsOnlyStep()
    return NumberOr(frame.controlsOnlyStepBox and frame.controlsOnlyStepBox:GetText(), 0.10)
end

local function ControlsOnlyNudge(dir)
    if state.selectedGuid and state.selectedKind == "NPC" then
        SetText(frame.status, "Status: moving NPC GUID " .. tostring(state.selectedGuid) .. "...")
        SendGE("NUDGE_CREATURE:" .. tostring(state.selectedGuid) .. ":" .. dir .. ":" .. tostring(CurrentControlsOnlyStep()) .. ":" .. CurrentMoveMode())
        return
    end

    SendGE("NUDGE:" .. dir .. ":" .. tostring(CurrentControlsOnlyStep()) .. ":" .. CurrentMoveMode())
end

local function ControlsOnlyRotate(axis, sign)
    if state.selectedGuid and state.selectedKind == "NPC" then
        SetText(frame.status, NPC_ROTATION_UNSUPPORTED_STATUS)
        if frame.controlsOnlyStatus then
            frame.controlsOnlyStatus:SetText("NPC rotation is not supported. Face before placing.")
        end
        return
    end

    SendGE("ROTATE:" .. axis .. ":" .. tostring(sign * CurrentControlsOnlyStep()))
end

frame.controlsOnlyMovementLabel = MakeLabel(frame.controlsOnlyFrame, "Movement", "GameFontNormal")
frame.controlsOnlyMovementLabel:SetPoint("TOPLEFT", frame.controlsOnlyFrame, "TOPLEFT", 10, -58)

local coButtonW = 148
local coButtonH = 23
local coButtonGap = 8
local coGridX = 10

local function PlaceControlsOnlyGridButton(btn, col, row, startY)
    btn:SetPoint("TOPLEFT", frame.controlsOnlyFrame, "TOPLEFT", coGridX + ((col - 1) * (coButtonW + coButtonGap)), startY - ((row - 1) * 27))
end

frame.coForwardButton = MakeButton(frame.controlsOnlyFrame, "Forward", coButtonW, coButtonH, function() ControlsOnlyNudge("FORWARD") end)
PlaceControlsOnlyGridButton(frame.coForwardButton, 1, 1, -78)

frame.coBackButton = MakeButton(frame.controlsOnlyFrame, "Back", coButtonW, coButtonH, function() ControlsOnlyNudge("BACK") end)
PlaceControlsOnlyGridButton(frame.coBackButton, 2, 1, -78)

frame.coUpButton = MakeButton(frame.controlsOnlyFrame, "Up", coButtonW, coButtonH, function() ControlsOnlyNudge("UP") end)
PlaceControlsOnlyGridButton(frame.coUpButton, 3, 1, -78)

frame.coLeftButton = MakeButton(frame.controlsOnlyFrame, "Left", coButtonW, coButtonH, function() ControlsOnlyNudge("LEFT") end)
PlaceControlsOnlyGridButton(frame.coLeftButton, 1, 2, -78)

frame.coRightButton = MakeButton(frame.controlsOnlyFrame, "Right", coButtonW, coButtonH, function() ControlsOnlyNudge("RIGHT") end)
PlaceControlsOnlyGridButton(frame.coRightButton, 2, 2, -78)

frame.coDownButton = MakeButton(frame.controlsOnlyFrame, "Down", coButtonW, coButtonH, function() ControlsOnlyNudge("DOWN") end)
PlaceControlsOnlyGridButton(frame.coDownButton, 3, 2, -78)

frame.controlsOnlyRotationLabel = MakeLabel(frame.controlsOnlyFrame, "Rotation", "GameFontNormal")
frame.controlsOnlyRotationLabel:SetPoint("TOPLEFT", frame.controlsOnlyFrame, "TOPLEFT", 10, -132)

frame.coYawLeftButton = MakeButton(frame.controlsOnlyFrame, "Yaw Left", coButtonW, coButtonH, function() ControlsOnlyRotate("YAW", -1) end, GOBJ_YAW_LEFT_TOOLTIP)
PlaceControlsOnlyGridButton(frame.coYawLeftButton, 1, 1, -152)

frame.coYawRightButton = MakeButton(frame.controlsOnlyFrame, "Yaw Right", coButtonW, coButtonH, function() ControlsOnlyRotate("YAW", 1) end, GOBJ_YAW_RIGHT_TOOLTIP)
PlaceControlsOnlyGridButton(frame.coYawRightButton, 2, 1, -152)

frame.coPitchForwardButton = MakeButton(frame.controlsOnlyFrame, "Pitch Forward", coButtonW, coButtonH, function() ControlsOnlyRotate("PITCH", 1) end, GOBJ_PITCH_FORWARD_TOOLTIP)
PlaceControlsOnlyGridButton(frame.coPitchForwardButton, 3, 1, -152)

frame.coPitchBackButton = MakeButton(frame.controlsOnlyFrame, "Pitch Back", coButtonW, coButtonH, function() ControlsOnlyRotate("PITCH", -1) end, GOBJ_PITCH_BACK_TOOLTIP)
PlaceControlsOnlyGridButton(frame.coPitchBackButton, 1, 2, -152)

frame.coRollLeftButton = MakeButton(frame.controlsOnlyFrame, "Roll Left", coButtonW, coButtonH, function() ControlsOnlyRotate("ROLL", -1) end, GOBJ_ROLL_LEFT_TOOLTIP)
PlaceControlsOnlyGridButton(frame.coRollLeftButton, 2, 2, -152)

frame.coRollRightButton = MakeButton(frame.controlsOnlyFrame, "Roll Right", coButtonW, coButtonH, function() ControlsOnlyRotate("ROLL", 1) end, GOBJ_ROLL_RIGHT_TOOLTIP)
PlaceControlsOnlyGridButton(frame.coRollRightButton, 3, 2, -152)



frame.searchPlaceFrame = MakePanel(UIParent, "GObjectEditorUISearchPlaceFrame")
frame.searchPlaceFrame:SetFrameStrata("DIALOG")
frame.searchPlaceFrame:SetFrameLevel(frame:GetFrameLevel() + 50)
frame.searchPlaceFrame:SetBackdropColor(0.015, 0.025, 0.035, 1.0)
frame.searchPlaceFrame:SetSize(620, 500)
frame.searchPlaceFrame:SetPoint("CENTER")
frame.searchPlaceFrame:SetMovable(true)
frame.searchPlaceFrame:EnableMouse(true)
frame.searchPlaceFrame:RegisterForDrag("LeftButton")
frame.searchPlaceFrame:SetScript("OnDragStart", frame.searchPlaceFrame.StartMoving)
frame.searchPlaceFrame:SetScript("OnDragStop", frame.searchPlaceFrame.StopMovingOrSizing)
frame.searchPlaceFrame:Hide()

frame.searchPlaceTitle = frame.searchPlaceFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
frame.searchPlaceTitle:SetPoint("TOP", frame.searchPlaceFrame, "TOP", 0, -14)
frame.searchPlaceTitle:SetText("Search & Place GameObject / NPC")

frame.searchPlaceClose = CreateFrame("Button", nil, frame.searchPlaceFrame, "UIPanelCloseButton")
frame.searchPlaceClose:SetPoint("TOPRIGHT", frame.searchPlaceFrame, "TOPRIGHT", -6, -6)
frame.searchPlaceClose:SetScript("OnClick", function()
    PlayEditorClickSound()
    frame.searchPlaceFrame:Hide()
end)

frame.searchPlaceLabel = MakeLabel(frame.searchPlaceFrame, "Search", "GameFontNormalSmall")
frame.searchPlaceLabel:SetPoint("TOPLEFT", frame.searchPlaceFrame, "TOPLEFT", 18, -52)

frame.searchPlaceEditBox = MakeEditBox(frame.searchPlaceFrame, "", 260)
frame.searchPlaceEditBox:SetPoint("LEFT", frame.searchPlaceLabel, "RIGHT", 12, 0)

local function ExecuteTemplateSearch()
    if frame.searchPlaceEditBox then
        frame.searchPlaceEditBox:ClearFocus()
    end

    local text = frame.searchPlaceEditBox and frame.searchPlaceEditBox:GetText() or ""
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")

    local isNumericSearch = string.find(text, "^%d+$") ~= nil
    if text == "" or ((not isNumericSearch) and string.len(text) < 2) then
        SetText(frame.searchPlaceStatus, "Enter an entry number or at least 2 characters to search templates.")
        return
    end

    local searchNpcs = frame.searchNpcCheckButton and frame.searchNpcCheckButton:GetChecked()
    state.searchMode = searchNpcs and "NPC" or "GOBJECT"
    state.searchResults = {}
    state.selectedTemplate = nil
    if frame.searchTemplateScrollFrame then
        FauxScrollFrame_SetOffset(frame.searchTemplateScrollFrame, 0)
    end
    SetText(frame.searchSelectedEntryValue, "-")
    SetText(frame.searchSelectedNameValue, "-")
    SetText(frame.searchSelectedTypeValue, "-")
    SetText(frame.searchPreviewText, "Waiting for search results...")

    if searchNpcs then
        SetText(frame.searchPlaceStatus, "Searching NPC templates for: " .. text)
        SendGE("SEARCH_CREATURE_TEMPLATE:" .. text)
    else
        SetText(frame.searchPlaceStatus, "Searching GameObject templates for: " .. text)
        SendGE("SEARCH_TEMPLATE:" .. text)
    end
end

frame.searchPlaceButton = MakeButton(frame.searchPlaceFrame, "Search", 100, 26, function()
    ExecuteTemplateSearch()
end, "Search gameobject templates or NPC templates by database name or entry.")
frame.searchPlaceButton:SetPoint("LEFT", frame.searchPlaceEditBox, "RIGHT", 14, 0)
frame.searchPlaceEditBox:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    ExecuteTemplateSearch()
end)
frame.searchPlaceEditBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)

frame.searchNpcCheckButton = CreateFrame("CheckButton", "GObjectEditorUISearchNpcCheckButton", frame.searchPlaceFrame, "UICheckButtonTemplate")
frame.searchNpcCheckButton:SetPoint("LEFT", frame.searchPlaceButton, "RIGHT", 8, 0)
frame.searchNpcCheckButton:SetSize(22, 22)
frame.searchNpcCheckButton:SetChecked(false)
AddTooltip(frame.searchNpcCheckButton, "Checked: search creature_template NPCs. Unchecked: search gameobject_template GameObjects.")

frame.searchNpcCheckLabel = MakeLabel(frame.searchPlaceFrame, "Search NPCs", "GameFontNormalSmall")
frame.searchNpcCheckLabel:SetPoint("LEFT", frame.searchNpcCheckButton, "RIGHT", 2, 0)
frame.searchNpcCheckLabel:SetWidth(86)
frame.searchNpcCheckLabel:SetJustifyH("LEFT")

frame.searchPlaceResultsPanel = MakePanel(frame.searchPlaceFrame, "GObjectEditorUISearchResultsPanel")
frame.searchPlaceResultsPanel:SetPoint("TOPLEFT", frame.searchPlaceFrame, "TOPLEFT", 18, -88)
frame.searchPlaceResultsPanel:SetSize(350, 330)
frame.searchPlaceResultsPanel:SetBackdropColor(0.015, 0.025, 0.035, 1.0)

frame.searchResultsTitle = MakeLabel(frame.searchPlaceResultsPanel, "Results", "GameFontNormal")
frame.searchResultsTitle:SetPoint("TOPLEFT", frame.searchPlaceResultsPanel, "TOPLEFT", 12, -10)

frame.searchEntryHeader = MakeLabel(frame.searchPlaceResultsPanel, "Entry", "GameFontNormalSmall")
frame.searchEntryHeader:SetPoint("TOPLEFT", frame.searchPlaceResultsPanel, "TOPLEFT", 12, -38)

frame.searchNameHeader = MakeLabel(frame.searchPlaceResultsPanel, "Name", "GameFontNormalSmall")
frame.searchNameHeader:SetPoint("TOPLEFT", frame.searchPlaceResultsPanel, "TOPLEFT", 86, -38)

frame.searchTypeHeader = MakeLabel(frame.searchPlaceResultsPanel, "Type", "GameFontNormalSmall")
frame.searchTypeHeader:SetPoint("TOPRIGHT", frame.searchPlaceResultsPanel, "TOPRIGHT", -26, -38)

frame.searchResultsEmpty = MakeLabel(frame.searchPlaceResultsPanel, "Search results will appear here.", "GameFontDisableSmall")
frame.searchResultsEmpty:SetPoint("CENTER", frame.searchPlaceResultsPanel, "CENTER", 0, 0)
frame.searchResultsEmpty:SetJustifyH("CENTER")

frame.searchTemplateScrollFrame = CreateFrame("ScrollFrame", "GObjectEditorUISearchTemplateScrollFrame", frame.searchPlaceResultsPanel, "FauxScrollFrameTemplate")
frame.searchTemplateScrollFrame:SetPoint("TOPLEFT", frame.searchPlaceResultsPanel, "TOPLEFT", 8, -58)
frame.searchTemplateScrollFrame:SetPoint("BOTTOMRIGHT", frame.searchPlaceResultsPanel, "BOTTOMRIGHT", -26, 22)

local function ParseTemplatePayload(parts)
    local modelPath = parts[5] or ""
    local nameStart = 6

    -- Backward compatibility with the older 4-field payload:
    -- GOBJECT_TEMPLATE:<entry>:<type>:<displayId>:<name>
    if #parts == 5 then
        modelPath = ""
        nameStart = 5
    end

    return {
        kind = "GOBJECT",
        entry = tonumber(parts[2]) or parts[2],
        type = tonumber(parts[3]) or parts[3],
        displayId = tonumber(parts[4]) or parts[4],
        modelPath = modelPath,
        name = table.concat(parts, ":", nameStart),
    }
end

local function ParseNpcDisplayIds(displayIdText)
    local displayIds = {}
    displayIdText = tostring(displayIdText or "")

    for idText in string.gmatch(displayIdText, "([^,]+)") do
        local id = tonumber(idText)
        if id and id > 0 then
            table.insert(displayIds, id)
        end
    end

    return displayIds
end

local function ParseCreatureTemplatePayload(parts)
    local primaryDisplayId = tonumber(parts[4]) or 0
    local displayIdText = tostring(parts[5] or "")
    local nameStart = 6

    -- Backward compatibility with older payload:
    -- CREATURE_TEMPLATE:<entry>:<type>:<displayId>:<name>
    if #parts == 5 then
        displayIdText = tostring(parts[4] or "")
        nameStart = 5
    end

    local displayIds = ParseNpcDisplayIds(displayIdText)
    if #displayIds == 0 and primaryDisplayId > 0 then
        table.insert(displayIds, primaryDisplayId)
    end

    return {
        kind = "NPC",
        entry = tonumber(parts[2]) or parts[2],
        type = tonumber(parts[3]) or parts[3],
        displayId = primaryDisplayId,
        displayIds = displayIds,
        displayIdText = displayIdText,
        modelPath = "",
        name = table.concat(parts, ":", nameStart),
    }
end

local function ApplySearchPreviewTransform()
    if not frame.searchPreviewModel then
        return
    end

    if frame.searchPreviewModel.SetCamDistanceScale then
        pcall(function() frame.searchPreviewModel:SetCamDistanceScale(1.0) end)
    end

    if frame.searchPreviewModel.SetPosition then
        -- PlayerModel axes are not intuitive here: the third argument moves
        -- the rendered preview vertically inside the frame.
        pcall(function() frame.searchPreviewModel:SetPosition(0, 0, state.searchPreviewYOffset or 0) end)
    end

    if frame.searchPreviewModel.SetFacing then
        pcall(function() frame.searchPreviewModel:SetFacing(state.searchPreviewFacing or 0.35) end)
    elseif frame.searchPreviewModel.SetRotation then
        pcall(function() frame.searchPreviewModel:SetRotation(state.searchPreviewFacing or 0.35) end)
    end

    if frame.searchPreviewModel.SetModelScale then
        pcall(function() frame.searchPreviewModel:SetModelScale(state.searchPreviewScale or 1.0) end)
    end
end

local function AdjustSearchPreviewFacing(delta)
    state.searchPreviewFacing = (state.searchPreviewFacing or 0.35) + delta
    ApplySearchPreviewTransform()
end

local function AdjustSearchPreviewScale(delta)
    local scale = (state.searchPreviewScale or 1.0) + delta
    if scale < 0.3 then
        scale = 0.3
    elseif scale > 3.0 then
        scale = 3.0
    end

    state.searchPreviewScale = scale
    ApplySearchPreviewTransform()
end

local function SetSearchPreviewYOffset(value, fromSlider)
    local offset = tonumber(value) or 0
    if offset < -1.5 then
        offset = -1.5
    elseif offset > 1.5 then
        offset = 1.5
    end

    state.searchPreviewYOffset = offset

    if frame.searchPreviewYOffsetSlider and not fromSlider then
        frame.searchPreviewYOffsetSlider:SetValue(offset)
    end

    ApplySearchPreviewTransform()
end

local function ResetSearchPreviewTransform()
    state.searchPreviewFacing = 0.35
    state.searchPreviewScale = 1.0
    state.searchPreviewYOffset = 0.0

    if frame.searchPreviewYOffsetSlider then
        frame.searchPreviewYOffsetSlider:SetValue(0)
    end

    ApplySearchPreviewTransform()
end

local npcPreviewRetryFrame = CreateFrame("Frame")
npcPreviewRetryFrame:Hide()

local function GetNpcPreviewDisplayId(template)
    if not template then
        return 0, 1, 1
    end

    -- Use the primary display ID returned by the backend. Do not
    -- automatically switch to alternate creature_template_model rows;
    -- those can represent random variants and may show the wrong model.
    local primaryId = tonumber(template.displayId) or 0
    if primaryId > 0 then
        return primaryId, 1, 1
    end

    local displayIds = template.displayIds or {}
    local id = tonumber(displayIds[1]) or 0
    return id, 1, 1
end


local function TryLoadNpcSearchPreview(template)
    if not frame.searchPreviewModel or not template then
        return false
    end

    if frame.searchPreviewModel.ClearModel then
        frame.searchPreviewModel:ClearModel()
    end

    frame.searchPreviewModel:Show()

    local loaded = false
    local entry = tonumber(template.entry) or 0
    local displayId, displayIndex, displayCount = GetNpcPreviewDisplayId(template)

    if entry > 0 and displayId > 0 and frame.searchPreviewModel.SetCreature then
        -- Match the proven Dual Pet preview path first. Some 3.3.5 clients
        -- load creature geometry but not textures when using SetCreature(entry)
        -- alone, so prefer the explicit entry + displayId call.
        loaded = pcall(function()
            frame.searchPreviewModel:SetCreature(entry, displayId)
        end)
    end

    if (not loaded) and entry > 0 and frame.searchPreviewModel.SetCreature then
        loaded = pcall(function()
            frame.searchPreviewModel:SetCreature(entry)
        end)
    end

    if (not loaded) and displayId > 0 and frame.searchPreviewModel.SetDisplayInfo then
        loaded = pcall(function()
            frame.searchPreviewModel:SetDisplayInfo(displayId)
        end)
    end

    if loaded then
        ApplySearchPreviewTransform()
        local modelText = "NPC DisplayID: " .. tostring(displayId > 0 and displayId or "-")
        if displayCount and displayCount > 1 then
            modelText = modelText .. "\nModel " .. tostring(displayIndex) .. "/" .. tostring(displayCount)
        end
        SetText(frame.searchPreviewText, modelText)
        return true
    end

    frame.searchPreviewModel:Hide()
    local modelText = "NPC preview unavailable\nDisplayID: " .. tostring(displayId > 0 and displayId or "-")
    if displayCount and displayCount > 1 then
        modelText = modelText .. "\nModel " .. tostring(displayIndex) .. "/" .. tostring(displayCount)
    end
    SetText(frame.searchPreviewText, modelText)
    return false
end

local function ScheduleNpcSearchPreviewRetry(template)
    if not template then
        return
    end

    npcPreviewRetryFrame._geTemplate = template
    npcPreviewRetryFrame._geElapsed = 0
    npcPreviewRetryFrame:SetScript("OnUpdate", function(self, elapsed)
        self._geElapsed = (self._geElapsed or 0) + elapsed
        if self._geElapsed < 0.45 then
            return
        end

        self:SetScript("OnUpdate", nil)
        self:Hide()

        if state.selectedTemplate == self._geTemplate then
            TryLoadNpcSearchPreview(self._geTemplate)
        end
    end)
    npcPreviewRetryFrame:Show()
end

local function UpdateSearchPreviewModel(template)
    if not frame.searchPreviewModel then
        return
    end

    npcPreviewRetryFrame:SetScript("OnUpdate", nil)
    npcPreviewRetryFrame:Hide()

    if frame.searchPreviewModel.ClearModel then
        frame.searchPreviewModel:ClearModel()
    end

    if not template then
        frame.searchPreviewModel:Hide()
        SetText(frame.searchPreviewText, "Select a result\nto preview")
        return
    end

    local displayId = tonumber(template.displayId) or 0
    local modelPath = tostring(template.modelPath or "")

    if template.kind == "NPC" then
        local entry = tonumber(template.entry) or 0
        local npcDisplayId, npcDisplayIndex, npcDisplayCount = GetNpcPreviewDisplayId(template)
        if entry > 0 then
            SendGE("PREVIEW_CREATURE_CACHE:" .. tostring(entry))
            local modelText = "Loading NPC preview...\nDisplayID: " .. tostring(npcDisplayId > 0 and npcDisplayId or "-")
            if npcDisplayCount and npcDisplayCount > 1 then
                modelText = modelText .. "\nModel " .. tostring(npcDisplayIndex) .. "/" .. tostring(npcDisplayCount)
            end
            SetText(frame.searchPreviewText, modelText)
            ScheduleNpcSearchPreviewRetry(template)
        end

        TryLoadNpcSearchPreview(template)
        return
    end

    if modelPath == "" then
        frame.searchPreviewModel:Hide()
        SetText(frame.searchPreviewText, "No model path\nDisplayID: " .. tostring(displayId > 0 and displayId or "-"))
        return
    end

    frame.searchPreviewModel:Show()

    local loaded = true
    if frame.searchPreviewModel.SetModel then
        loaded = pcall(function()
            frame.searchPreviewModel:SetModel(modelPath)
        end)
    else
        loaded = false
    end

    if not loaded then
        frame.searchPreviewModel:Hide()
        SetText(frame.searchPreviewText, "Preview load failed\nDisplayID: " .. tostring(displayId > 0 and displayId or "-"))
        return
    end

    ApplySearchPreviewTransform()

    SetText(frame.searchPreviewText, "DisplayID: " .. tostring(displayId))
end

local function UpdateSelectedTemplate(template)
    state.selectedTemplate = template

    if not template then
        SetText(frame.searchSelectedEntryValue, "-")
        SetText(frame.searchSelectedNameValue, "-")
        SetText(frame.searchSelectedTypeValue, "-")
        UpdateSearchPreviewModel(nil)
        return
    end

    SetText(frame.searchSelectedEntryValue, tostring(template.entry or "-"))
    SetText(frame.searchSelectedNameValue, SafeName(template.name))
    SetText(frame.searchSelectedTypeValue, tostring(template.type or "-"))
    UpdateSearchPreviewModel(template)
    local label = template.kind == "NPC" and "NPC" or "GameObject"
    if template.kind == "NPC" then
        SetText(frame.searchPlaceStatus, "Selected NPC template entry " .. tostring(template.entry or "-") .. ". Some NPC textures may not load in preview.")
    else
        SetText(frame.searchPlaceStatus, "Selected GameObject template entry " .. tostring(template.entry or "-"))
    end
end

local function ClearSearchRows()
    for _, row in ipairs(state.searchRows) do
        row.dataIndex = nil
        row.selected = false
        row.bg:SetTexture(0.12, 0.12, 0.12, 0.28)
        row.bg:Hide()
        row.entryText:SetText("")
        row.nameText:SetText("")
        row.typeText:SetText("")
        row:Hide()
    end
end

local function RefreshSearchRows()
    ClearSearchRows()

    local offset = FauxScrollFrame_GetOffset(frame.searchTemplateScrollFrame) or 0

    for i = 1, SEARCH_VISIBLE_ROWS do
        local row = state.searchRows[i]
        local dataIndex = offset + i
        local template = state.searchResults[dataIndex]

        if row and template then
            row.dataIndex = dataIndex
            row.entryText:SetText(tostring(template.entry or ""))
            row.nameText:SetText(SafeName(template.name))
            row.typeText:SetText(tostring(template.type or ""))
            row:Show()

            if state.selectedTemplate and tostring(state.selectedTemplate.entry or "") == tostring(template.entry or "") and tostring(state.selectedTemplate.kind or "GOBJECT") == tostring(template.kind or "GOBJECT") then
                row.selected = true
                row.bg:SetTexture(0.85, 0.62, 0.12, 0.72)
                row.bg:Show()
            end
        end
    end

    FauxScrollFrame_Update(frame.searchTemplateScrollFrame, #state.searchResults, SEARCH_VISIBLE_ROWS, ROW_HEIGHT)

    if #state.searchResults > 0 then
        frame.searchResultsEmpty:Hide()
    else
        frame.searchResultsEmpty:Show()
    end
end

for i = 1, SEARCH_VISIBLE_ROWS do
    local row = CreateFrame("Button", nil, frame.searchPlaceResultsPanel)
    row.index = i
    row:SetSize(310, 18)
    row:SetPoint("TOPLEFT", frame.searchPlaceResultsPanel, "TOPLEFT", 12, -58 - ((i - 1) * ROW_HEIGHT))

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetTexture(0.12, 0.12, 0.12, 0.28)
    row.bg:Hide()

    row.entryText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.entryText:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.entryText:SetWidth(70)
    row.entryText:SetJustifyH("LEFT")

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", row, "LEFT", 74, 0)
    row.nameText:SetWidth(175)
    row.nameText:SetJustifyH("LEFT")

    row.typeText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.typeText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.typeText:SetWidth(44)
    row.typeText:SetJustifyH("RIGHT")

    row:SetScript("OnEnter", function(self)
        if not self.selected then
            self.bg:SetTexture(0.18, 0.22, 0.30, 0.55)
            self.bg:Show()
        end
    end)

    row:SetScript("OnLeave", function(self)
        if not self.selected then
            self.bg:Hide()
        end
    end)

    row:SetScript("OnClick", function(self)
        PlayEditorClickSound()
        local template = state.searchResults[self.dataIndex or 0]
        if template then
            UpdateSelectedTemplate(template)
            RefreshSearchRows()
        end
    end)

    state.searchRows[i] = row
end

frame.searchTemplateScrollFrame:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshSearchRows)
end)

frame.searchPreviewPanel = MakePanel(frame.searchPlaceFrame, "GObjectEditorUISearchPreviewPanel")
frame.searchPreviewPanel:SetPoint("TOPLEFT", frame.searchPlaceFrame, "TOPLEFT", 384, -88)
frame.searchPreviewPanel:SetSize(218, 150)
frame.searchPreviewPanel:SetBackdropColor(0.015, 0.025, 0.035, 1.0)

frame.searchPreviewTitle = MakeLabel(frame.searchPreviewPanel, "Preview", "GameFontNormal")
frame.searchPreviewTitle:SetPoint("TOPLEFT", frame.searchPreviewPanel, "TOPLEFT", 12, -10)

local activePreviewHoldControl = nil

local function StopPreviewHold(control)
    if control and control._geHoldTicker then
        control._geHoldTicker:SetScript("OnUpdate", nil)
    end
    if activePreviewHoldControl == control then
        activePreviewHoldControl = nil
    end
end

local function StartPreviewHold(control, action)
    if not control or not action then
        return
    end

    if activePreviewHoldControl and activePreviewHoldControl ~= control then
        StopPreviewHold(activePreviewHoldControl)
    end

    activePreviewHoldControl = control
    control._geHoldElapsed = 0
    action()

    if not control._geHoldTicker then
        control._geHoldTicker = CreateFrame("Frame")
    end

    control._geHoldTicker:SetScript("OnUpdate", function(self, elapsed)
        if activePreviewHoldControl ~= control then
            self:SetScript("OnUpdate", nil)
            return
        end

        control._geHoldElapsed = (control._geHoldElapsed or 0) + elapsed
        while control._geHoldElapsed >= 0.05 do
            control._geHoldElapsed = control._geHoldElapsed - 0.05
            action()
        end
    end)
end

local function MakePreviewTextControl(parent, label, width, action, tooltip, isSymbol, repeatWhileHeld)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width, 18)

    btn.text = btn:CreateFontString(nil, "OVERLAY", isSymbol and "GameFontNormalLarge" or "GameFontNormalSmall")
    btn.text:SetPoint("CENTER")
    btn.text:SetText(label)
    btn.text:SetTextColor(1, 1, 1, 1)

    if isSymbol and btn.text.SetFont then
        local font, size = btn.text:GetFont()
        if font then
            btn.text:SetFont(font, 16, "OUTLINE")
        end
    end

    btn:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 0.82, 0, 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tooltip or "", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function(self)
        StopPreviewHold(self)
        self.text:SetTextColor(1, 1, 1, 1)
        GameTooltip:Hide()
    end)

    btn:SetScript("OnMouseDown", function(self)
        self.text:SetTextColor(1, 0.9, 0.35, 1)
        PlayEditorClickSound()
        if repeatWhileHeld then
            StartPreviewHold(self, action)
        end
    end)

    btn:SetScript("OnMouseUp", function(self)
        StopPreviewHold(self)
        if self.IsMouseOver and self:IsMouseOver() then
            self.text:SetTextColor(1, 0.82, 0, 1)
        else
            self.text:SetTextColor(1, 1, 1, 1)
        end
    end)

    btn:SetScript("OnHide", function(self)
        StopPreviewHold(self)
    end)

    if not repeatWhileHeld then
        btn:SetScript("OnClick", function(self)
            if action then
                action()
            end
        end)
    end

    return btn
end

frame.searchPreviewRotateLeftButton = MakePreviewTextControl(frame.searchPreviewPanel, "<", 16, function()
    AdjustSearchPreviewFacing(0.25)
end, "Rotate preview left.", true, true)
frame.searchPreviewRotateLeftButton:SetPoint("TOPLEFT", frame.searchPreviewPanel, "TOPLEFT", 72, -7)

frame.searchPreviewRotateRightButton = MakePreviewTextControl(frame.searchPreviewPanel, ">", 16, function()
    AdjustSearchPreviewFacing(-0.25)
end, "Rotate preview right.", true, true)
frame.searchPreviewRotateRightButton:SetPoint("LEFT", frame.searchPreviewRotateLeftButton, "RIGHT", 6, 0)

frame.searchPreviewZoomInButton = MakePreviewTextControl(frame.searchPreviewPanel, "+", 16, function()
    AdjustSearchPreviewScale(0.1)
end, "Zoom preview in.", true, true)
frame.searchPreviewZoomInButton:SetPoint("LEFT", frame.searchPreviewRotateRightButton, "RIGHT", 8, 0)

frame.searchPreviewZoomOutButton = MakePreviewTextControl(frame.searchPreviewPanel, "-", 16, function()
    AdjustSearchPreviewScale(-0.1)
end, "Zoom preview out.", true, true)
frame.searchPreviewZoomOutButton:SetPoint("LEFT", frame.searchPreviewZoomInButton, "RIGHT", 8, 0)

frame.searchPreviewResetButton = MakePreviewTextControl(frame.searchPreviewPanel, "Reset", 42, function()
    ResetSearchPreviewTransform()
end, "Reset preview rotation, zoom, and vertical position.", false)
frame.searchPreviewResetButton:SetPoint("LEFT", frame.searchPreviewZoomOutButton, "RIGHT", 8, 0)

frame.searchPreviewYOffsetSlider = CreateFrame("Slider", "GObjectEditorUISearchPreviewYOffsetSlider", frame.searchPreviewPanel, "OptionsSliderTemplate")
frame.searchPreviewYOffsetSlider:SetOrientation("VERTICAL")
frame.searchPreviewYOffsetSlider:SetMinMaxValues(-1.5, 1.5)
frame.searchPreviewYOffsetSlider:SetValueStep(0.05)
frame.searchPreviewYOffsetSlider:SetValue(0)
frame.searchPreviewYOffsetSlider:SetSize(14, 88)
frame.searchPreviewYOffsetSlider:SetPoint("TOPRIGHT", frame.searchPreviewPanel, "TOPRIGHT", -8, -36)
frame.searchPreviewYOffsetSlider:SetScript("OnValueChanged", function(self, value)
    SetSearchPreviewYOffset(value, true)
end)
frame.searchPreviewYOffsetSlider:SetScript("OnMouseDown", function()
    PlayEditorClickSound()
end)
local yOffsetSliderText = _G["GObjectEditorUISearchPreviewYOffsetSliderText"]
local yOffsetSliderLow = _G["GObjectEditorUISearchPreviewYOffsetSliderLow"]
local yOffsetSliderHigh = _G["GObjectEditorUISearchPreviewYOffsetSliderHigh"]
if yOffsetSliderText then yOffsetSliderText:SetText("") end
if yOffsetSliderLow then yOffsetSliderLow:SetText("") end
if yOffsetSliderHigh then yOffsetSliderHigh:SetText("") end
AddTooltip(frame.searchPreviewYOffsetSlider, "Move the preview model up or down.")

frame.searchPreviewModel = CreateFrame("PlayerModel", "GObjectEditorUISearchPreviewModel", frame.searchPreviewPanel)
frame.searchPreviewModel:SetPoint("TOPLEFT", frame.searchPreviewPanel, "TOPLEFT", 6, -26)
frame.searchPreviewModel:SetSize(190, 94)
frame.searchPreviewModel:SetFrameLevel(frame.searchPreviewPanel:GetFrameLevel() + 2)
frame.searchPreviewModel:Hide()

frame.searchPreviewText = MakeLabel(frame.searchPreviewPanel, "Select a result\nto preview", "GameFontDisableSmall")
frame.searchPreviewText:SetPoint("BOTTOM", frame.searchPreviewPanel, "BOTTOM", 0, 10)
frame.searchPreviewText:SetJustifyH("CENTER")
frame.searchPreviewText:SetWidth(174)

frame.searchDetailsPanel = MakePanel(frame.searchPlaceFrame, "GObjectEditorUISearchDetailsPanel")
frame.searchDetailsPanel:SetPoint("TOPLEFT", frame.searchPlaceFrame, "TOPLEFT", 384, -250)
frame.searchDetailsPanel:SetSize(218, 168)
frame.searchDetailsPanel:SetBackdropColor(0.015, 0.025, 0.035, 1.0)

frame.searchDetailsTitle = MakeLabel(frame.searchDetailsPanel, "Selected Result", "GameFontNormal")
frame.searchDetailsTitle:SetPoint("TOPLEFT", frame.searchDetailsPanel, "TOPLEFT", 12, -10)

frame.searchSelectedEntryLabel = MakeLabel(frame.searchDetailsPanel, "Entry:", "GameFontNormalSmall")
frame.searchSelectedEntryLabel:SetPoint("TOPLEFT", frame.searchDetailsPanel, "TOPLEFT", 12, -42)
frame.searchSelectedEntryValue = MakeLabel(frame.searchDetailsPanel, "-", "GameFontHighlightSmall")
frame.searchSelectedEntryValue:SetPoint("TOPLEFT", frame.searchDetailsPanel, "TOPLEFT", 72, -42)
frame.searchSelectedEntryValue:SetWidth(126)

frame.searchSelectedNameLabel = MakeLabel(frame.searchDetailsPanel, "Name:", "GameFontNormalSmall")
frame.searchSelectedNameLabel:SetPoint("TOPLEFT", frame.searchDetailsPanel, "TOPLEFT", 12, -70)
frame.searchSelectedNameValue = MakeLabel(frame.searchDetailsPanel, "-", "GameFontHighlightSmall")
frame.searchSelectedNameValue:SetPoint("TOPLEFT", frame.searchDetailsPanel, "TOPLEFT", 72, -70)
frame.searchSelectedNameValue:SetWidth(126)

frame.searchSelectedTypeLabel = MakeLabel(frame.searchDetailsPanel, "Type:", "GameFontNormalSmall")
frame.searchSelectedTypeLabel:SetPoint("TOPLEFT", frame.searchDetailsPanel, "TOPLEFT", 12, -98)
frame.searchSelectedTypeValue = MakeLabel(frame.searchDetailsPanel, "-", "GameFontHighlightSmall")
frame.searchSelectedTypeValue:SetPoint("TOPLEFT", frame.searchDetailsPanel, "TOPLEFT", 72, -98)
frame.searchSelectedTypeValue:SetWidth(126)

frame.searchPlaceStatus = MakeLabel(frame.searchPlaceFrame, "Search gameobject_template by default. Check Search NPCs to search creature_template.", "GameFontDisableSmall")
frame.searchPlaceStatus:SetPoint("BOTTOMLEFT", frame.searchPlaceFrame, "BOTTOMLEFT", 18, 18)
frame.searchPlaceStatus:SetWidth(370)

frame.placeButton = MakeButton(frame.searchPlaceFrame, "Place", 94, 28, function()
    if not state.selectedTemplate then
        SetText(frame.searchPlaceStatus, "Select a template first.")
        return
    end

    local entry = tonumber(state.selectedTemplate.entry)
    if not entry or entry <= 0 then
        SetText(frame.searchPlaceStatus, "Selected template has an invalid entry.")
        return
    end

    if state.selectedTemplate.kind == "NPC" then
        SetText(frame.searchPlaceStatus, "Placing NPC template entry " .. tostring(entry) .. "...")
        SendGE("PLACE_CREATURE_TEMPLATE:" .. tostring(entry))
    else
        SetText(frame.searchPlaceStatus, "Placing GameObject template entry " .. tostring(entry) .. "...")
        SendGE("PLACE_TEMPLATE:" .. tostring(entry))
    end
end, "Place selected GameObject or NPC two yards in front of your character.")
frame.placeButton:SetPoint("BOTTOMRIGHT", frame.searchPlaceFrame, "BOTTOMRIGHT", -122, 16)

frame.searchWindowCloseButton = MakeButton(frame.searchPlaceFrame, "Close", 94, 28, function()
    frame.searchPlaceFrame:Hide()
end)
frame.searchWindowCloseButton:SetPoint("BOTTOMRIGHT", frame.searchPlaceFrame, "BOTTOMRIGHT", -18, 16)


local function ClearRows()
    for _, row in ipairs(state.rows) do
        row.dataIndex = nil
        row.selected = false
        row.bg:SetTexture(0.12, 0.12, 0.12, 0.28)
        row.bg:Hide()
        row.guidText:SetText("")
        row.entryText:SetText("")
        row.nameText:SetText("")
        row.distText:SetText("")
        row:Hide()
    end
end

local function RefreshRows()
    ClearRows()

    local offset = FauxScrollFrame_GetOffset(frame.objectScrollFrame) or 0

    for i = 1, VISIBLE_ROWS do
        local row = state.rows[i]
        local dataIndex = offset + i
        local obj = state.objects[dataIndex]

        if row and obj then
            row.dataIndex = dataIndex
            local label = obj.kind == "NPC" and "[NPC]" or "[GOBJ]"
            row.guidText:SetText(label .. " " .. tostring(obj.guid or ""))
            row.entryText:SetText(tostring(obj.entry or ""))
            row.nameText:SetText(SafeName(obj.name))
            row.distText:SetText(string.format("%.1f", tonumber(obj.distance) or 0))
            row:Show()

            if tostring(state.selectedGuid or "") == tostring(obj.guid or "") and tostring(state.selectedKind or "GOBJ") == tostring(obj.kind or "GOBJ") then
                row.selected = true
                row.bg:SetTexture(0.85, 0.62, 0.12, 0.72)
                row.bg:Show()
            end
        end
    end

    FauxScrollFrame_Update(frame.objectScrollFrame, #state.objects, VISIBLE_ROWS, ROW_HEIGHT)
    frame.objectsCount:SetText(tostring(#state.objects) .. " object(s)/NPC(s) shown")
end

for i = 1, VISIBLE_ROWS do
    local row = CreateFrame("Button", nil, frame.objectsPanel)
    row.index = i
    row:SetSize(450, 18)
    row:SetPoint("TOPLEFT", frame.objectsPanel, "TOPLEFT", 10, -52 - ((i - 1) * ROW_HEIGHT))

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetTexture(0.12, 0.12, 0.12, 0.28)
    row.bg:Hide()

    row.guidText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.guidText:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.guidText:SetWidth(118)
    row.guidText:SetJustifyH("LEFT")

    row.entryText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.entryText:SetPoint("LEFT", row, "LEFT", 120, 0)
    row.entryText:SetWidth(62)
    row.entryText:SetJustifyH("LEFT")

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", row, "LEFT", 184, 0)
    row.nameText:SetWidth(202)
    row.nameText:SetJustifyH("LEFT")

    row.distText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.distText:SetPoint("RIGHT", row, "RIGHT", -12, 0)
    row.distText:SetWidth(50)
    row.distText:SetJustifyH("RIGHT")

    row:SetScript("OnEnter", function(self)
        if not self.selected then
            self.bg:SetTexture(0.18, 0.22, 0.30, 0.55)
            self.bg:Show()
        end
    end)

    row:SetScript("OnLeave", function(self)
        if not self.selected then
            self.bg:Hide()
        end
    end)

    row:SetScript("OnClick", function(self)
        PlayEditorClickSound()
        local obj = state.objects[self.dataIndex or 0]
        if obj then
            if obj.kind == "NPC" then
                state.selectedGuid = obj.guid
                state.selectedKind = "NPC"
                state.selectedObject = obj
                state.restoreAvailable = false
                state.undoSteps = 0
                SetText(frame.undoStatusText, "At original position")
                SetText(frame.restoreText, "No session restore position available.")
                UpdateSelectedText(obj)
                UpdateCompactStatus()
                RefreshRows()
                RefreshEnabledState()
                SetText(frame.status, "Status: selected NPC GUID " .. tostring(obj.guid))
            else
                SendGE("SELECT:" .. tostring(obj.guid))
                SetText(frame.status, "Status: selecting GameObject GUID " .. tostring(obj.guid) .. "...")
            end
        end
    end)

    state.rows[i] = row
end

frame.objectScrollFrame:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshRows)
end)

UpdateSelectedText = function(obj)
    if not obj then
        frame.selectedGuidValue:SetText("-")
        frame.selectedEntryValue:SetText("-")
        frame.selectedNameValue:SetText("-")
        frame.selectedDistanceValue:SetText("-")
        frame.positionValue:SetText("X: -\nY: -\nZ: -")
        frame.rotationValue:SetText("Orientation: -")
        frame.previewText:SetText("No Selection Preview active.")
        return
    end

    frame.selectedGuidValue:SetText(tostring(obj.guid or "-"))
    frame.selectedEntryValue:SetText(tostring(obj.entry or "-"))
    frame.selectedNameValue:SetText(SafeName(obj.name))
    frame.selectedDistanceValue:SetText(string.format("%.1f", tonumber(obj.distance) or 0))
    frame.positionValue:SetText(
        "X: " .. FormatNumber(obj.x) .. "\n" ..
        "Y: " .. FormatNumber(obj.y) .. "\n" ..
        "Z: " .. FormatNumber(obj.z)
    )
    frame.rotationValue:SetText("Orientation: " .. FormatNumber(obj.o))
    frame.previewText:SetText("Preview active.\nOriginal object is unchanged until saved.")
end

local function ResetSessionState()
    state.selectedGuid = nil
    state.selectedKind = nil
    state.restoreAvailable = false
    state.objects = {}
    state.undoSteps = 0
    state.searchResults = {}
    state.selectedTemplate = nil
    state.lastPlacedCreatureGuid = nil
    state.lastPlacedCreatureEntry = nil
    state.lastPlacedCreatureName = nil

    if frame.objectScrollFrame then
        FauxScrollFrame_SetOffset(frame.objectScrollFrame, 0)
    end

    SetText(frame.undoStatusText, "At original position")
    SetText(frame.restoreText, "No session restore position available.")
end

local function CloseEditor()
    if state.selectedGuid ~= nil then
        SendGE("CLEAR")
    end

    ResetSessionState()
    ClearRows()
    if ClearSearchRows then
        ClearSearchRows()
    end
    UpdateSelectedTemplate(nil)
    UpdateSelectedText(nil)
    RefreshEnabledState()
    if frame.controlsOnlyCheck then
        frame.controlsOnlyCheck:SetChecked(false)
    end
    if frame.controlsOnlyFrame then
        frame.controlsOnlyFrame:Hide()
    end
    if frame.searchPlaceFrame then
        frame.searchPlaceFrame:Hide()
    end
    frame:Hide()
end

close:SetScript("OnClick", function()
    PlayEditorClickSound()
    CloseEditor()
end)

local function ParseObjectPayload(parts)
    return {
        kind = parts[1] == "NPC" and "NPC" or "GOBJ",
        guid = tonumber(parts[2]) or parts[2],
        entry = tonumber(parts[3]),
        map = tonumber(parts[4]),
        x = tonumber(parts[5]),
        y = tonumber(parts[6]),
        z = tonumber(parts[7]),
        o = tonumber(parts[8]),
        distance = tonumber(parts[9]),
        name = table.concat(parts, ":", 10),
    }
end

controlledButtons = {
    frame.scanButton,
    frame.searchButton,
    frame.deleteButton,
    frame.resetButton,
    frame.searchPlaceButton,
    frame.refreshPreviewButton,
    frame.undoButton,
    frame.faceButton,
    frame.saveButton,
    frame.restoreButton,
    frame.forwardButton,
    frame.backButton,
    frame.upButton,
    frame.leftButton,
    frame.rightButton,
    frame.downButton,
    frame.yawLeftButton,
    frame.yawRightButton,
    frame.pitchForwardButton,
    frame.pitchBackButton,
    frame.rollLeftButton,
    frame.rollRightButton,
    frame.controlsOnlyUndoButton,
    frame.controlsOnlyDeleteButton,
    frame.controlsOnlyResetButton,
    frame.coForwardButton,
    frame.coBackButton,
    frame.coUpButton,
    frame.coLeftButton,
    frame.coRightButton,
    frame.coDownButton,
    frame.coYawLeftButton,
    frame.coYawRightButton,
    frame.coPitchForwardButton,
    frame.coPitchBackButton,
    frame.coRollLeftButton,
    frame.coRollRightButton,
}

selectionButtons = {
    frame.deleteButton,
    frame.resetButton,
    frame.refreshPreviewButton,
    frame.undoButton,
    frame.faceButton,
    frame.saveButton,
    frame.forwardButton,
    frame.backButton,
    frame.upButton,
    frame.leftButton,
    frame.rightButton,
    frame.downButton,
    frame.yawLeftButton,
    frame.yawRightButton,
    frame.pitchForwardButton,
    frame.pitchBackButton,
    frame.rollLeftButton,
    frame.rollRightButton,
    frame.controlsOnlyUndoButton,
    frame.controlsOnlyResetButton,
    frame.coForwardButton,
    frame.coBackButton,
    frame.coUpButton,
    frame.coLeftButton,
    frame.coRightButton,
    frame.coDownButton,
    frame.coYawLeftButton,
    frame.coYawRightButton,
    frame.coPitchForwardButton,
    frame.coPitchBackButton,
    frame.coRollLeftButton,
    frame.coRollRightButton,
}

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        if RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(ADDON_PREFIX)
        end

        RefreshEnabledState()
        SetText(frame.status, "Status: checking GM access...")
        SendGE(ACCESS_REQUEST)
        return
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message = ...
        if prefix ~= ADDON_PREFIX then
            return
        end

        if message == ACCESS_VERIFIED then
            state.access = true
            SetText(frame.status, "Status: access verified")
            RefreshEnabledState()
            return
        end

        if string.find(message, "HELLO:GOBJECT_EDITOR_ACCESS_DENIED", 1, true) == 1 then
            state.access = false
            SetText(frame.status, "Status: access denied")
            RefreshEnabledState()
            return
        end

        local parts = { strsplit(":", message) }
        local opcode = parts[1]

        if opcode == "SCAN_BEGIN" then
            state.objects = {}
            state.selectedGuid = nil
            state.selectedKind = nil
            state.selectedObject = nil
            state.restoreAvailable = false
            state.undoSteps = 0
            FauxScrollFrame_SetOffset(frame.objectScrollFrame, 0)
            SetText(frame.undoStatusText, "At original position")
            UpdateSelectedText(nil)
            RefreshEnabledState()
            ClearRows()
            SetText(frame.status, "Status: receiving scan...")
        elseif opcode == "OBJ" or opcode == "NPC" then
            table.insert(state.objects, ParseObjectPayload(parts))
            RefreshRows()
        elseif opcode == "SCAN_END" then
            SetText(frame.status, "Status: scan complete, " .. tostring(#state.objects) .. " shown")
            RefreshRows()
        elseif opcode == "GOBJECT_SEARCH_BEGIN" then
            state.searchMode = "GOBJECT"
            state.searchResults = {}
            state.selectedTemplate = nil
            if frame.searchTemplateScrollFrame then
                FauxScrollFrame_SetOffset(frame.searchTemplateScrollFrame, 0)
            end
            UpdateSelectedTemplate(nil)
            ClearSearchRows()
            SetText(frame.searchPlaceStatus, "Receiving GameObject template search results...")
        elseif opcode == "GOBJECT_TEMPLATE" then
            table.insert(state.searchResults, ParseTemplatePayload(parts))
            RefreshSearchRows()
        elseif opcode == "GOBJECT_SEARCH_END" then
            RefreshSearchRows()
            SetText(frame.searchPlaceStatus, "GameObject search complete, " .. tostring(#state.searchResults) .. " template(s) shown")
        elseif opcode == "CREATURE_SEARCH_BEGIN" then
            state.searchMode = "NPC"
            state.searchResults = {}
            state.selectedTemplate = nil
            if frame.searchTemplateScrollFrame then
                FauxScrollFrame_SetOffset(frame.searchTemplateScrollFrame, 0)
            end
            UpdateSelectedTemplate(nil)
            ClearSearchRows()
            SetText(frame.searchPlaceStatus, "Receiving NPC template search results...")
        elseif opcode == "CREATURE_TEMPLATE" then
            table.insert(state.searchResults, ParseCreatureTemplatePayload(parts))
            RefreshSearchRows()
        elseif opcode == "CREATURE_SEARCH_END" then
            RefreshSearchRows()
            SetText(frame.searchPlaceStatus, "NPC search complete, " .. tostring(#state.searchResults) .. " template(s) shown")
        elseif opcode == "SELECTED" or opcode == "UPDATED" then
            local obj = ParseObjectPayload(parts)
            state.selectedGuid = obj.guid
            state.selectedKind = "GOBJ"
            state.selectedObject = obj
            UpdateSelectedText(obj)
            UpdateCompactStatus()
            RefreshRows()
            RefreshEnabledState()
            SetText(frame.status, opcode == "SELECTED" and "Status: selected" or "Status: preview updated")
        elseif opcode == "NPC_UPDATED" then
            local obj = ParseObjectPayload(parts)
            obj.kind = "NPC"
            state.selectedGuid = obj.guid
            state.selectedKind = "NPC"
            state.selectedObject = obj
            for i, existing in ipairs(state.objects or {}) do
                if tostring(existing.guid or "") == tostring(obj.guid or "") and tostring(existing.kind or "GOBJ") == "NPC" then
                    state.objects[i] = obj
                    break
                end
            end
            UpdateSelectedText(obj)
            UpdateCompactStatus()
            RefreshRows()
            RefreshEnabledState()
            SetText(frame.status, "Status: NPC updated")
        elseif opcode == "NUDGE_CREATURE_FAIL" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "NPC move failed: " .. errorText)
        elseif opcode == "ROTATE_CREATURE_FAIL" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "NPC rotate failed: " .. errorText)
        elseif opcode == "ROTATE_CREATURE_UNSUPPORTED" then
            local axis = parts[2] or "axis"
            SetText(frame.status, NPC_ROTATION_UNSUPPORTED_STATUS)
        elseif opcode == "UNDO_CREATURE_FAIL" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "NPC undo failed: " .. errorText)
        elseif opcode == "SAVE_CREATURE_FAIL" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "NPC save failed: " .. errorText)
        elseif opcode == "RESTORE_CREATURE_FAIL" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "NPC restore failed: " .. errorText)
        elseif opcode == "RESET_CREATURE_FAIL" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "NPC reset failed: " .. errorText)
        elseif opcode == "CREATURE_UNDONE" then
            SetText(frame.status, "Status: undone NPC movement for GUID " .. tostring(parts[2]))
        elseif opcode == "CREATURE_SAVED" then
            SetText(frame.status, "Status: marked NPC restore position for GUID " .. tostring(parts[2]))
        elseif opcode == "CREATURE_RESTORED" then
            SetText(frame.status, "Status: restored NPC saved position for GUID " .. tostring(parts[2]))
        elseif opcode == "CREATURE_RESET_ORIGINAL" then
            SetText(frame.status, "Status: reset NPC to original position for GUID " .. tostring(parts[2]))
        elseif opcode == "CREATURE_RESTORE" then
            if tostring(state.selectedGuid or "") == tostring(parts[3] or "") then
                if parts[2] == "AVAILABLE" then
                    state.restoreAvailable = true
                    frame.restoreText:SetText("NPC restore position available this session.")
                else
                    state.restoreAvailable = false
                    frame.restoreText:SetText("No session restore position available.")
                end
                RefreshEnabledState()
            end
        elseif opcode == "CREATURE_UNDO_STATUS" then
            if tostring(state.selectedGuid or "") == tostring(parts[3] or "") then
                if parts[2] == "AVAILABLE" then
                    local count = tonumber(parts[4]) or 0
                    state.undoSteps = count
                    frame.undoStatusText:SetText("Undo: " .. tostring(count) .. " NPC step(s) available")
                else
                    state.undoSteps = 0
                    frame.undoStatusText:SetText("At original position")
                end
                RefreshEnabledState()
            end
        elseif opcode == "PLACE_OK" then
            local guid = parts[2] or "-"
            local entry = parts[3] or "-"
            local name = table.concat(parts, ":", 4)
            local text = "Placed " .. SafeName(name) .. " entry " .. tostring(entry) .. " as GUID " .. tostring(guid)
            SetText(frame.status, "Status: " .. text)
            if frame.searchPlaceFrame and frame.searchPlaceFrame:IsShown() then
                SetText(frame.searchPlaceStatus, text)
            end
            RefreshEnabledState()
        elseif opcode == "PLACE_FAIL" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "Place failed: " .. errorText)
            if frame.searchPlaceFrame and frame.searchPlaceFrame:IsShown() then
                SetText(frame.searchPlaceStatus, "Place failed: " .. errorText)
            end
        elseif opcode == "PLACE_CREATURE_OK" then
            local guid = parts[2] or "-"
            local entry = parts[3] or "-"
            local name = table.concat(parts, ":", 4)
            state.lastPlacedCreatureGuid = tonumber(guid)
            state.lastPlacedCreatureEntry = tonumber(entry)
            state.lastPlacedCreatureName = SafeName(name)
            local text = "Placed NPC " .. SafeName(name) .. " entry " .. tostring(entry) .. " as GUID " .. tostring(guid)
            SetText(frame.status, "Status: " .. text)
            if frame.searchPlaceFrame and frame.searchPlaceFrame:IsShown() then
                SetText(frame.searchPlaceStatus, text)
            end
            RefreshEnabledState()
        elseif opcode == "PLACE_CREATURE_FAIL" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "NPC place failed: " .. errorText)
            if frame.searchPlaceFrame and frame.searchPlaceFrame:IsShown() then
                SetText(frame.searchPlaceStatus, "NPC place failed: " .. errorText)
            end
        elseif opcode == "DELETE_CREATURE_OK" then
            local guid = parts[2] or "-"
            local name = table.concat(parts, ":", 3)
            if tostring(state.lastPlacedCreatureGuid or "") == tostring(guid) then
                state.lastPlacedCreatureGuid = nil
                state.lastPlacedCreatureEntry = nil
                state.lastPlacedCreatureName = nil
            end
            if tostring(state.selectedGuid or "") == tostring(guid) and state.selectedKind == "NPC" then
                state.selectedGuid = nil
                state.selectedKind = nil
                state.selectedObject = nil
                state.restoreAvailable = false
                state.undoSteps = 0
                SetText(frame.undoStatusText, "At original position")
                SetText(frame.restoreText, "No session restore position available.")
                UpdateSelectedText(nil)
                UpdateCompactStatus()
            end
            SetText(frame.status, "Status: deleted NPC GUID " .. tostring(guid) .. " " .. SafeName(name))
            if frame.searchPlaceFrame and frame.searchPlaceFrame:IsShown() then
                SetText(frame.searchPlaceStatus, "Deleted NPC GUID " .. tostring(guid) .. " " .. SafeName(name))
            end
            RefreshEnabledState()
            SendGE("SCAN:" .. tostring(CurrentRadius()))
        elseif opcode == "DELETE_CREATURE_FAIL" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "NPC delete failed: " .. errorText)
            if frame.searchPlaceFrame and frame.searchPlaceFrame:IsShown() then
                SetText(frame.searchPlaceStatus, "NPC delete failed: " .. errorText)
            end
        elseif opcode == "DELETE_OK" then
            local guid = parts[2] or "-"
            local name = table.concat(parts, ":", 3)
            state.selectedGuid = nil
            state.selectedKind = nil
            state.selectedObject = nil
            state.restoreAvailable = false
            state.undoSteps = 0
            SetText(frame.undoStatusText, "At original position")
            SetText(frame.restoreText, "No session restore position available.")
            UpdateSelectedText(nil)
            UpdateCompactStatus()
            RefreshEnabledState()
            SetText(frame.status, "Status: deleted GUID " .. tostring(guid) .. " " .. SafeName(name))
            SendGE("SCAN:" .. tostring(CurrentRadius()))
        elseif opcode == "DELETE_FAIL" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "Delete failed: " .. errorText)
        elseif opcode == "SAVED" then
            SetText(frame.status, "Status: saved GUID " .. tostring(parts[2]))
        elseif opcode == "RESTORED" then
            SetText(frame.status, "Status: restored saved position for GUID " .. tostring(parts[2]))
        elseif opcode == "RESET_ORIGINAL" then
            SetText(frame.status, "Status: reset selected GameObject to original position for GUID " .. tostring(parts[2]))
        elseif opcode == "RESTORE" then
            if parts[2] == "AVAILABLE" then
                state.restoreAvailable = true
                frame.restoreText:SetText("Restore available during this session only.")
            else
                state.restoreAvailable = false
                frame.restoreText:SetText("No session restore position available.")
            end
            RefreshEnabledState()
        elseif opcode == "UNDO_STATUS" then
            if parts[2] == "AVAILABLE" then
                local count = tonumber(parts[3]) or 0
                state.undoSteps = count
                frame.undoStatusText:SetText("Undo: " .. tostring(count) .. " step(s) available")
            else
                state.undoSteps = 0
                frame.undoStatusText:SetText("At original position")
            end
        elseif opcode == "PREVIEW" then
            if parts[2] == "ACTIVE" then
                SetText(frame.status, "Status: Selection Preview active for GUID " .. tostring(parts[3]))
            elseif parts[2] == "ERROR" then
                SetText(frame.status, "Preview error: " .. table.concat(parts, ":", 3))
            end
        elseif opcode == "CLEARED" then
            ResetSessionState()
            ClearRows()
            ClearSearchRows()
            UpdateSelectedTemplate(nil)
            UpdateSelectedText(nil)
            RefreshEnabledState()
            SetText(frame.status, "Status: session cleared")
        elseif opcode == "ERROR" then
            local errorText = table.concat(parts, ":", 2)
            SetText(frame.status, "Error: " .. errorText)
            if frame.searchPlaceFrame and frame.searchPlaceFrame:IsShown() then
                SetText(frame.searchPlaceStatus, "Error: " .. errorText)
            end
        elseif opcode == "WARN" then
            SetText(frame.status, "Warning: " .. table.concat(parts, ":", 2))
        end
    end
end)

local function ToggleEditor()
    if frame:IsShown() or (frame.controlsOnlyFrame and frame.controlsOnlyFrame:IsShown()) then
        CloseEditor()
    else
        frame:Show()

        if not state.access then
            SetText(frame.status, "Status: checking GM access...")
            SendGE(ACCESS_REQUEST)
        end
    end
end

local MINIMAP_BUTTON_ICON = "Interface\\AddOns\\GObjectEditorUI\\Textures\\GObjectEditorIcon"
local minimapButtonAngle = 225

local function MinimapButtonAtan2(y, x)
    if math.atan2 then
        return math.atan2(y, x)
    end

    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 and y >= 0 then
        return math.atan(y / x) + math.pi
    elseif x < 0 and y < 0 then
        return math.atan(y / x) - math.pi
    elseif x == 0 and y > 0 then
        return math.pi / 2
    elseif x == 0 and y < 0 then
        return -math.pi / 2
    end

    return 0
end

local function UpdateMinimapButtonPosition(angle)
    minimapButtonAngle = angle or minimapButtonAngle

    if not GObjectEditorUIMinimapButton then
        return
    end

    local radius = ((Minimap:GetWidth() or 140) / 2) + 2
    local radians = math.rad(minimapButtonAngle)
    local x = math.cos(radians) * radius
    local y = math.sin(radians) * radius

    GObjectEditorUIMinimapButton:ClearAllPoints()
    GObjectEditorUIMinimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local minimapButton = CreateFrame("Button", "GObjectEditorUIMinimapButton", Minimap)
minimapButton:SetSize(31, 31)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetMovable(false)
minimapButton:EnableMouse(true)
minimapButton:RegisterForClicks("LeftButtonUp")
minimapButton:RegisterForDrag("LeftButton")

minimapButton.icon = minimapButton:CreateTexture(nil, "BACKGROUND")
minimapButton.icon:SetTexture(MINIMAP_BUTTON_ICON)
minimapButton.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
minimapButton.icon:SetAllPoints(minimapButton)

minimapButton.border = minimapButton:CreateTexture(nil, "OVERLAY")
minimapButton.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
minimapButton.border:SetSize(52, 52)
minimapButton.border:SetPoint("TOPLEFT", minimapButton, "TOPLEFT", 0, 0)

minimapButton.highlight = minimapButton:CreateTexture(nil, "HIGHLIGHT")
minimapButton.highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
minimapButton.highlight:SetBlendMode("ADD")
minimapButton.highlight:SetAllPoints(minimapButton)

minimapButton:SetScript("OnClick", function()
    PlayEditorClickSound()
    ToggleEditor()
end)

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Game Object Editor", 1, 0.82, 0, 1, true)
    GameTooltip:AddLine("Left-click to toggle the editor.", 1, 1, 1, true)
    GameTooltip:AddLine("Drag to move this button.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

minimapButton:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local centerX, centerY = Minimap:GetCenter()
        local cursorX, cursorY = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale() or 1

        if not centerX or not centerY or not cursorX or not cursorY or scale == 0 then
            return
        end

        cursorX = cursorX / scale
        cursorY = cursorY / scale

        local angle = math.deg(MinimapButtonAtan2(cursorY - centerY, cursorX - centerX))
        if angle < 0 then
            angle = angle + 360
        end

        UpdateMinimapButtonPosition(angle)
    end)
end)

minimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)

    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale() or 1

    if centerX and centerY and cursorX and cursorY and scale ~= 0 then
        cursorX = cursorX / scale
        cursorY = cursorY / scale
        local angle = math.deg(MinimapButtonAtan2(cursorY - centerY, cursorX - centerX))
        if angle < 0 then
            angle = angle + 360
        end
        UpdateMinimapButtonPosition(angle)
    end
end)

UpdateMinimapButtonPosition(minimapButtonAngle)

SLASH_GOBJECTEDITORUI1 = "/gobedit"
SlashCmdList["GOBJECTEDITORUI"] = ToggleEditor

UpdateSelectedText(nil)
UpdateSelectedTemplate(nil)
RefreshSearchRows()
RefreshEnabledState()
