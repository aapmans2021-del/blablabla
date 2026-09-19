-- =====================================================================
-- COMBINED AUTOMATION SCRIPT: UNIFIED UI + FIXED AUTO TOKENS + BOSS DODGE
-- HATCH LOGIC + EGG CHANCE VIEWER + AUTO FARM & PET TRACKER
-- =====================================================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local SettingsFile = "MultiRobloxAccounts_settings.json"
local CurrentThemeName = "Default Dark"
local CurrentKeyName = "LeftControl"
local CurrentToggleStates = {}

local function loadSettings()
    if type(readfile) ~= "function" or type(isfile) ~= "function" or not isfile(SettingsFile) then
        return {}
    end
    local ok, settings = pcall(function()
        return HttpService:JSONDecode(readfile(SettingsFile))
    end)
    return ok and type(settings) == "table" and settings or {}
end

local SavedSettings = loadSettings()

local function saveSettings()
    if type(writefile) ~= "function" then return end
    pcall(function()
        writefile(SettingsFile, HttpService:JSONEncode({
            theme = CurrentThemeName,
            key = CurrentKeyName,
            toggles = CurrentToggleStates,
        }))
    end)
end

-- Auto Farm & Token Variables
local Library = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do
    RunService.Heartbeat:Wait()
end

local AutoFarmRobot = false
local AutoFarmTurkey = false
local AutoTokens = false
local PotatoMode = false
local TokenRemote = nil

local CurrentTarget = nil
local CurrentTargetId = nil
local DamageRemote = ReplicatedStorage:GetChildren()[66]

-- Find token remote on init
for _, obj in ipairs(ReplicatedStorage:GetChildren()) do
    if obj:IsA("RemoteFunction") or obj:IsA("RemoteEvent") then
        local name = obj.Name:lower()
        if name:find("token") or name:find("ability") then
            TokenRemote = obj
            break
        end
    end
end

-- TURKEY DODGE VARIABLES
local TurkeyDodgeActive = false
local IsEvading = false

-- AUTO FARM FUNCTIONS
local function GetAllEquippedPetUIDs()
    local myPets = {}
    local equipped = Library.PetCmds.GetEquipped()
    for uid, petData in pairs(equipped) do
        if type(petData) == "table" and petData.uid then
            table.insert(myPets, petData.uid)
        else
            table.insert(myPets, uid)
        end
    end
    return myPets
end

local function GetNextRobot()
    local coins = Workspace:FindFirstChild("__THINGS") and Workspace.__THINGS:FindFirstChild("Coins")
    if not coins then return nil end
    for _, child in ipairs(coins:GetChildren()) do
        local name = (child:GetAttribute("Name") or child:GetAttribute("Mob") or child.Name):lower()
        if name:find("robot") and not name:find("factory") then
            return child
        end
    end
    return nil
end

local function FindTurkey()
    local coins = Workspace:FindFirstChild("__THINGS") and Workspace.__THINGS:FindFirstChild("Coins")
    if not coins then return nil end
    for _, child in ipairs(coins:GetChildren()) do
        if not child.Parent then continue end
        local name = (child:GetAttribute("Name") or child:GetAttribute("Mob") or child.Name):lower()
        if name:find("turkey") or name:find("autumn") or (name:find("boss") and (name:find("turkey") or name:find("autumn"))) then
            return child
        end
    end
    return nil
end

local function FocusPetsContinuous(coinInstance)
    if not coinInstance or not coinInstance.Parent then return end
    local coinId = coinInstance:GetAttribute("ID")
    local myPets = GetAllEquippedPetUIDs()

    pcall(function()
        Library.Signal.Fire("Select Coin", coinInstance)
    end)

    if coinId and #myPets > 0 then
        for i = 1, 3 do
            pcall(function()
                Library.Network.Invoke("Join Coin", coinId, myPets)
            end)
            pcall(function()
                Library.Network.Fire("Join Coin", coinId, myPets)
            end)
        end
    end
end

-- ABILITY TOKEN COLLECTION (SINGLE-PASS TRACKING PREVENTS DOUBLE TELEPORT)
local ignoreTokens = {}

local function collectAbilityTokens()
    local tokenFolder = Workspace:FindFirstChild("__ABILITYTOKENS")
    if tokenFolder then
        return tokenFolder:GetChildren()
    end
    return {}
end

task.spawn(function()
    while true do
        if AutoTokens and localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart") then
            local tokens = collectAbilityTokens()
            local hrp = localPlayer.Character:FindFirstChild("HumanoidRootPart")
            
            if hrp and #tokens > 0 then
                local savedPos = hrp.CFrame
                local collectedAny = false
                
                for _, token in ipairs(tokens) do
                    if not AutoTokens then break end
                    if not token or not token.Parent or ignoreTokens[token] then continue end
                    
                    local targetPart = nil
                    if token:IsA("BasePart") then
                        targetPart = token
                    elseif token:IsA("Model") then
                        targetPart = token.PrimaryPart or token:FindFirstChildWhichIsA("BasePart", true)
                    elseif token:IsA("Folder") then
                        targetPart = token:FindFirstChildWhichIsA("BasePart", true)
                    end
                    
                    if targetPart then
                        ignoreTokens[token] = true
                        task.delay(4, function() ignoreTokens[token] = nil end)
                        
                        collectedAny = true
                        local tokenCFrame = targetPart.CFrame
                        local tokenPos = targetPart.Position
                        local tokenId = tonumber(token.Name) or token.Name
                        
                        hrp.CFrame = tokenCFrame
                        task.wait(0.08)
                        
                        if TokenRemote then
                            pcall(function()
                                if TokenRemote:IsA("RemoteFunction") then
                                    TokenRemote:InvokeServer(tokenId, tokenPos)
                                else
                                    TokenRemote:FireServer(tokenId, tokenPos)
                                end
                            end)
                        end
                        
                        local waitCount = 0
                        while token.Parent and waitCount < 6 do
                            task.wait(0.04)
                            waitCount += 1
                        end
                    end
                end
                
                if collectedAny and hrp and hrp.Parent then
                    hrp.CFrame = savedPos
                    task.wait(0.1)
                end
            end
        end
        task.wait(0.15)
    end
end)

-- AUTUMN BOSS FX DODGE DETECTION
task.spawn(function()
    while true do
        task.wait(0.05)
        if AutoFarmTurkey and TurkeyDodgeActive then
            local character = localPlayer.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            local fxFolder = Workspace:FindFirstChild("__AUTUMNBOSS_FX")
            
            if hrp then
                if fxFolder and #fxFolder:GetChildren() > 0 then
                    IsEvading = true
                    hrp.CFrame = CFrame.new(535, 16, -1590)
                else
                    if IsEvading then
                        IsEvading = false
                        hrp.CFrame = CFrame.new(147, 114, -1500)
                    end
                end
            end
        end
    end
end)

-- Main Auto Farm Loop
task.spawn(function()
    while true do
        task.wait(0.1)
        if AutoFarmRobot then
            if not CurrentTarget or not CurrentTarget.Parent then
                CurrentTarget = GetNextRobot()
            end
            if CurrentTarget and CurrentTarget.Parent then
                CurrentTargetId = tostring(CurrentTarget:GetAttribute("ID"))
                FocusPetsContinuous(CurrentTarget)
            else
                CurrentTargetId = nil
            end
        else
            if not AutoFarmTurkey then
                CurrentTarget = nil
                CurrentTargetId = nil
            end
        end
        
        if AutoFarmTurkey then
            if not CurrentTarget or not CurrentTarget.Parent then
                CurrentTarget = FindTurkey()
            end
            if CurrentTarget and CurrentTarget.Parent then
                CurrentTargetId = tostring(CurrentTarget:GetAttribute("ID"))
                FocusPetsContinuous(CurrentTarget)
            else
                CurrentTargetId = nil
            end
        else
            if not AutoFarmRobot then
                CurrentTarget = nil
                CurrentTargetId = nil
            end
        end
    end
end)

-- Damage Spam Loop
task.spawn(function()
    while true do
        task.wait(0.01)
        if CurrentTargetId and DamageRemote and (AutoFarmRobot or AutoFarmTurkey) then
            pcall(function()
                DamageRemote:FireServer(CurrentTargetId)
            end)
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(0.015)
        if PotatoMode and (AutoFarmRobot or AutoFarmTurkey) and CurrentTarget and CurrentTarget.Parent then
            FocusPetsContinuous(CurrentTarget)
        end
    end
end)


-- =====================================================================
-- UI, UNIFIED STYLING, HATCH LOGIC & EGG CHANCE VIEWER
-- =====================================================================

local function destroyOldGui(name)
    local old = playerGui:FindFirstChild(name)
    if old then
        old:Destroy()
    end
end

destroyOldGui("CombinedAutomationUI")

task.spawn(function()
    local Save = nil
    local okSave = pcall(function()
        Save = require(ReplicatedStorage:WaitForChild("Library", 2):WaitForChild("Client", 2):WaitForChild("Save", 2))
    end)
    if not okSave then
        pcall(function()
            Save = require(ReplicatedStorage.Library.Client.Save)
        end)
    end

    local PetsDirectory = ReplicatedStorage:FindFirstChild("__DIRECTORY") and ReplicatedStorage.__DIRECTORY:FindFirstChild("Pets")
    local hugeNames, secretNames, titanicNames, gargantuanNames = {}, {}, {}, {}
    local petDisplayNameMap = {}

    local function scanDefs(folder)
        if not folder then return end
        for _, child in ipairs(folder:GetChildren()) do
            if child:IsA("ModuleScript") then
                local ok, data = pcall(require, child)
                if ok and type(data) == "table" then
                    local petName = data.name or child.Name
                    petDisplayNameMap[child.Name] = petName
                    if data.id then
                        petDisplayNameMap[tostring(data.id)] = petName
                        petDisplayNameMap[data.id] = petName
                    end

                    local rarityText = tostring(data.rarity or ""):lower()
                    if data.gargantuan == true or rarityText:find("gargantuan") then
                        gargantuanNames[petName] = true
                        gargantuanNames[child.Name] = true
                        if data.id then gargantuanNames[tostring(data.id)] = true end
                    elseif data.titanic == true or rarityText:find("titanic") then
                        titanicNames[petName] = true
                        titanicNames[child.Name] = true
                        if data.id then titanicNames[tostring(data.id)] = true end
                    elseif data.huge == true or rarityText:find("huge") then
                        hugeNames[petName] = true
                        hugeNames[child.Name] = true
                        if data.id then hugeNames[tostring(data.id)] = true end
                    elseif data.secret == true or rarityText:find("secret") then
                        secretNames[petName] = true
                        secretNames[child.Name] = true
                        if data.id then secretNames[tostring(data.id)] = true end
                    end
                end
            elseif child:IsA("Folder") then
                scanDefs(child)
            end
        end
    end
    scanDefs(PetsDirectory)

    local function getPetDisplayName(pet)
        if type(pet) ~= "table" then return "Unknown" end
        local baseId = pet.id or pet.name
        local displayName
        if baseId then
            local strId = tostring(baseId)
            if petDisplayNameMap[strId] then
                displayName = petDisplayNameMap[strId]
            else
                displayName = strId
            end
        else
            displayName = "Unknown"
        end

        return displayName
    end

    local ui = Instance.new("ScreenGui")
    ui.Name = "CombinedAutomationUI"
    ui.ResetOnSpawn = false
    ui.IgnoreGuiInset = true
    ui.DisplayOrder = 999
    ui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ui.Parent = playerGui

    -- UNTOUCHED HUGES COUNTER TRACKER (PARALLEL ALIGNED)
    local tracker = Instance.new("Frame")
    tracker.Name = "PetCounterTracker"
    tracker.AnchorPoint = Vector2.new(1, 0)
    tracker.Position = UDim2.new(1, -12, 0, 100)
    tracker.Size = UDim2.new(0, 600, 0, 280)
    tracker.BackgroundColor3 = Color3.fromRGB(20, 18, 28)
    tracker.BackgroundTransparency = 0.08
    tracker.BorderSizePixel = 0
    tracker.Active = true
    tracker.Draggable = true
    tracker.Parent = ui

    local trackerCorner = Instance.new("UICorner")
    trackerCorner.CornerRadius = UDim.new(0, 10)
    trackerCorner.Parent = tracker

    local trackerStroke = Instance.new("UIStroke")
    trackerStroke.Color = Color3.fromRGB(170, 170, 170)
    trackerStroke.Thickness = 1.2
    trackerStroke.Transparency = 0.5
    trackerStroke.Parent = tracker

    local trackerToggle = Instance.new("TextButton")
    trackerToggle.Name = "ToggleBtn"
    trackerToggle.Size = UDim2.new(0, 26, 0, 26)
    trackerToggle.Position = UDim2.new(1, -30, 0, 8)
    trackerToggle.Text = "-"
    trackerToggle.BackgroundColor3 = Color3.fromRGB(55, 52, 68)
    trackerToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
    trackerToggle.Font = Enum.Font.GothamBold
    trackerToggle.TextSize = 16
    trackerToggle.Parent = tracker

    local trackerToggleCorner = Instance.new("UICorner")
    trackerToggleCorner.CornerRadius = UDim.new(0, 6)
    trackerToggleCorner.Parent = trackerToggle

    local trackerContainer = Instance.new("Frame")
    trackerContainer.Size = UDim2.new(1, 0, 1, 0)
    trackerContainer.BackgroundTransparency = 1
    trackerContainer.Parent = tracker

    local trackerLayout = Instance.new("UIListLayout")
    trackerLayout.FillDirection = Enum.FillDirection.Horizontal
    trackerLayout.Padding = UDim.new(0, 0)
    trackerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    trackerLayout.Parent = trackerContainer

    local function makeColumn(name, color, order)
        local col = Instance.new("Frame")
        col.Name = name .. "Col"
        col.BackgroundTransparency = 1
        col.Size = UDim2.new(0.25, 0, 1, 0)
        col.LayoutOrder = order
        col.Parent = trackerContainer

        local countText = Instance.new("TextLabel")
        countText.Name = name .. "Count"
        countText.Size = UDim2.new(1, -12, 0, 42)
        countText.Position = UDim2.new(0, 6, 0, 8)
        countText.BackgroundTransparency = 1
        countText.Font = Enum.Font.GothamBold
        countText.TextColor3 = color
        countText.TextScaled = true
        countText.Text = name .. "s: 0"
        countText.TextXAlignment = Enum.TextXAlignment.Left
        countText.Parent = col

        local topLine = Instance.new("Frame")
        topLine.Size = UDim2.new(1, -12, 0, 1)
        topLine.Position = UDim2.new(0, 6, 0, 50)
        topLine.BackgroundColor3 = color
        topLine.BackgroundTransparency = 0.7
        topLine.BorderSizePixel = 0
        topLine.Parent = col

        local recentText = Instance.new("TextLabel")
        recentText.Size = UDim2.new(1, -12, 0, 20)
        recentText.Position = UDim2.new(0, 6, 0, 56)
        recentText.BackgroundTransparency = 1
        recentText.Font = Enum.Font.GothamBold
        recentText.TextColor3 = color
        recentText.TextScaled = true
        recentText.Text = "Recent " .. name .. "s:"
        recentText.TextXAlignment = Enum.TextXAlignment.Left
        recentText.Parent = col

        local list = Instance.new("ScrollingFrame")
        list.Name = name .. "Recent"
        list.Size = UDim2.new(1, -12, 1, -82)
        list.Position = UDim2.new(0, 6, 0, 76)
        list.BackgroundTransparency = 1
        list.BorderSizePixel = 0
        list.ScrollBarThickness = 4
        list.Parent = col

        local listLayout = Instance.new("UIListLayout")
        listLayout.Padding = UDim.new(0, 2)
        listLayout.SortOrder = Enum.SortOrder.LayoutOrder
        listLayout.Parent = list

        return countText, list
    end

    local hugeLabel, hugeList = makeColumn("Huge", Color3.fromRGB(255, 210, 80), 1)
    local secretLabel, secretList = makeColumn("Secret", Color3.fromRGB(180, 120, 255), 3)
    local titanicLabel, titanicList = makeColumn("Titanic", Color3.fromRGB(80, 200, 255), 5)
    local gargantuanLabel, gargantuanList = makeColumn("Gargantuan", Color3.fromRGB(255, 100, 150), 7)

    local div1 = Instance.new("Frame")
    div1.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
    div1.BackgroundTransparency = 0.8
    div1.BorderSizePixel = 0
    div1.Size = UDim2.new(0, 1, 1, -16)
    div1.Position = UDim2.new(0, 0, 0, 8)
    div1.LayoutOrder = 2
    div1.Parent = trackerContainer

    local div2 = Instance.new("Frame")
    div2.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
    div2.BackgroundTransparency = 0.8
    div2.BorderSizePixel = 0
    div2.Size = UDim2.new(0, 1, 1, -16)
    div2.Position = UDim2.new(0, 0, 0, 8)
    div2.LayoutOrder = 4
    div2.Parent = trackerContainer

    local div3 = Instance.new("Frame")
    div3.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
    div3.BackgroundTransparency = 0.8
    div3.BorderSizePixel = 0
    div3.Size = UDim2.new(0, 1, 1, -16)
    div3.Position = UDim2.new(0, 0, 0, 8)
    div3.LayoutOrder = 6
    div3.Parent = trackerContainer

    local minimized = false
    local function updateTrackerState()
        if minimized then
            tracker.Size = UDim2.new(0, 600, 0, 102)
            trackerToggle.Text = "+"
        else
            tracker.Size = UDim2.new(0, 600, 0, 280)
            trackerToggle.Text = "-"
        end
    end

    trackerToggle.MouseButton1Click:Connect(function()
        minimized = not minimized
        updateTrackerState()
    end)

    local function getPetCategory(pet)
        if type(pet) ~= "table" then return nil end
        local baseId = tostring(pet.id or "")
        local custom = tostring(pet.name or pet.id or "")
        local rarity = tostring(pet.rarity or pet.Rarity or ""):lower()
        local text = (baseId .. " " .. custom .. " " .. rarity):lower()
        if pet.gargantuan == true or gargantuanNames[baseId] or gargantuanNames[custom] or text:find("gargantuan") then
            return "Gargantuan"
        elseif pet.titanic == true or titanicNames[baseId] or titanicNames[custom] or text:find("titanic") then
            return "Titanic"
        elseif pet.huge == true or hugeNames[baseId] or hugeNames[custom] or text:find("huge") then
            return "Huge"
        elseif pet.secret == true or secretNames[baseId] or secretNames[custom] or text:find("secret") then
            return "Secret"
        end
        return nil
    end

    local knownPets = {}
    local recentHuges = {}
    local recentSecrets = {}
    local recentTitanics = {}
    local recentGargantuans = {}
    local hatchRareLabels = {}
    local afkRareLabels = {}
    local hatchRecentLists = {}
    local afkRecentLists = {}
    local renderHatchRecent = function() end
    local renderAfkRecent = function() end
    local trackerInitialized = false

    local function renderRecent(listFrame, entries, color)
        for _, child in ipairs(listFrame:GetChildren()) do
            if child:IsA("TextLabel") then
                child:Destroy()
            end
        end
        for i, entryData in ipairs(entries) do
            local label = Instance.new("TextLabel")
            label.BackgroundTransparency = 1
            label.Size = UDim2.new(1, 0, 0, 18)
            label.Font = Enum.Font.Gotham
            label.TextColor3 = color
            label.TextScaled = true
            label.Text = "✓ " .. tostring(entryData.name)
            label.TextXAlignment = Enum.TextXAlignment.Left
            label.LayoutOrder = i
            label.Parent = listFrame
        end
    end

    local function refreshTracker()
        if not Save or not Save.Get then return end
        local ok, pets = pcall(function()
            return Save.Get().Pets
        end)
        if not ok or type(pets) ~= "table" then return end

        local totalHuge, totalSecret, totalTitanic, totalGargantuan = 0, 0, 0, 0

        for _, pet in pairs(pets) do
            if type(pet) == "table" then
                local category = getPetCategory(pet)
                if category then
                    if category == "Huge" then
                        totalHuge += 1
                    elseif category == "Secret" then
                        totalSecret += 1
                    elseif category == "Titanic" then
                        totalTitanic += 1
                    elseif category == "Gargantuan" then
                        totalGargantuan += 1
                    end

                    local uid = tostring(pet.uid or pet.id or (tostring(pet) .. category))
                    if not knownPets[uid] then
                        if trackerInitialized then
                            local displayName = getPetDisplayName(pet)
                            local entry = { name = displayName, uid = uid }

                            if category == "Huge" then
                                table.insert(recentHuges, 1, entry)
                                if #recentHuges > 5 then table.remove(recentHuges, 6) end
                            elseif category == "Secret" then
                                table.insert(recentSecrets, 1, entry)
                                if #recentSecrets > 5 then table.remove(recentSecrets, 6) end
                            elseif category == "Titanic" then
                                table.insert(recentTitanics, 1, entry)
                                if #recentTitanics > 5 then table.remove(recentTitanics, 6) end
                            elseif category == "Gargantuan" then
                                table.insert(recentGargantuans, 1, entry)
                                if #recentGargantuans > 5 then table.remove(recentGargantuans, 6) end
                            end
                        end
                        knownPets[uid] = true
                    end
                end
            end
        end

        hugeLabel.Text = "Huges: " .. totalHuge
        secretLabel.Text = "Secrets: " .. totalSecret
        titanicLabel.Text = "Titanics: " .. totalTitanic
        gargantuanLabel.Text = "Gargantuans: " .. totalGargantuan

        if hatchRareLabels.Huges then hatchRareLabels.Huges.Text = hugeLabel.Text end
        if hatchRareLabels.Secrets then hatchRareLabels.Secrets.Text = secretLabel.Text end
        if hatchRareLabels.Titanics then hatchRareLabels.Titanics.Text = titanicLabel.Text end
        if hatchRareLabels.Gargantuans then hatchRareLabels.Gargantuans.Text = gargantuanLabel.Text end
        if afkRareLabels.Huges then afkRareLabels.Huges.Text = hugeLabel.Text end
        if afkRareLabels.Secrets then afkRareLabels.Secrets.Text = secretLabel.Text end
        if afkRareLabels.Titanics then afkRareLabels.Titanics.Text = titanicLabel.Text end
        if afkRareLabels.Gargantuans then afkRareLabels.Gargantuans.Text = gargantuanLabel.Text end

        if not trackerInitialized then
            trackerInitialized = true
        end

        if tracker.Parent then
            renderRecent(hugeList, recentHuges, Color3.fromRGB(100, 255, 100))
            renderRecent(secretList, recentSecrets, Color3.fromRGB(215, 150, 255))
            renderRecent(titanicList, recentTitanics, Color3.fromRGB(160, 220, 255))
            renderRecent(gargantuanList, recentGargantuans, Color3.fromRGB(255, 180, 200))
        end
        renderHatchRecent()
        renderAfkRecent()
    end

    updateTrackerState()
    tracker:Destroy()
    task.spawn(function()
        while ui.Parent do
            refreshTracker()
            task.wait(1.5)
        end
    end)

    -- AFK OVERLAY (EXPANDED UI ELEMENTS & BIGGER TEXT)
    local afkOverlay = Instance.new("Frame")
    afkOverlay.Name = "AfkOverlay"
    afkOverlay.Size = UDim2.new(1, 0, 1, 0)
    afkOverlay.Position = UDim2.new(0, 0, 0, 0)
    afkOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    afkOverlay.BorderSizePixel = 0
    afkOverlay.Visible = false
    afkOverlay.ZIndex = 100
    afkOverlay.Parent = ui

    local blackFill = Instance.new("Frame")
    blackFill.Size = UDim2.new(1, 0, 1, 0)
    blackFill.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    blackFill.BorderSizePixel = 0
    blackFill.ZIndex = 101
    blackFill.Parent = afkOverlay

    local afkCenter = Instance.new("Frame")
    afkCenter.Size = UDim2.new(0, 950, 0, 780)
    afkCenter.AnchorPoint = Vector2.new(0.5, 0.5)
    afkCenter.Position = UDim2.new(0.5, 0, 0.5, 0)
    afkCenter.BackgroundTransparency = 1
    afkCenter.ZIndex = 102
    afkCenter.Parent = afkOverlay

    local afkTitle = Instance.new("TextLabel")
    afkTitle.Size = UDim2.new(1, 0, 0, 80)
    afkTitle.Text = "AFK MODE ACTIVE"
    afkTitle.TextColor3 = Color3.fromRGB(255, 90, 90)
    afkTitle.Font = Enum.Font.GothamBlack
    afkTitle.TextSize = 64
    afkTitle.BackgroundTransparency = 1
    afkTitle.TextXAlignment = Enum.TextXAlignment.Center
    afkTitle.ZIndex = 102
    afkTitle.Parent = afkCenter

    local afkEggs = Instance.new("TextLabel")
    afkEggs.Size = UDim2.new(1, 0, 0, 50)
    afkEggs.Position = UDim2.new(0, 0, 0, 95)
    afkEggs.Text = "Eggs Hatched: --"
    afkEggs.TextColor3 = Color3.fromRGB(80, 230, 80)
    afkEggs.Font = Enum.Font.GothamSemibold
    afkEggs.TextSize = 42
    afkEggs.BackgroundTransparency = 1
    afkEggs.TextXAlignment = Enum.TextXAlignment.Center
    afkEggs.ZIndex = 102
    afkEggs.Parent = afkCenter

    local afkGems = Instance.new("TextLabel")
    afkGems.Size = UDim2.new(1, 0, 0, 50)
    afkGems.Position = UDim2.new(0, 0, 0, 155)
    afkGems.Text = "Diamonds: --"
    afkGems.TextColor3 = Color3.fromRGB(110, 185, 255)
    afkGems.Font = Enum.Font.GothamSemibold
    afkGems.TextSize = 42
    afkGems.BackgroundTransparency = 1
    afkGems.TextXAlignment = Enum.TextXAlignment.Center
    afkGems.ZIndex = 102
    afkGems.Parent = afkCenter

    local afkExit = Instance.new("TextButton")
    afkExit.Size = UDim2.new(1, 0, 0, 80)
    afkExit.Position = UDim2.new(0, 0, 0, 680)
    afkExit.Text = "Turn Off AFK Mode"
    afkExit.TextColor3 = Color3.fromRGB(255, 255, 255)
    afkExit.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
    afkExit.Font = Enum.Font.GothamSemibold
    afkExit.TextSize = 32
    afkExit.ZIndex = 102
    afkExit.Parent = afkCenter

    local afkExitCorner = Instance.new("UICorner")
    afkExitCorner.CornerRadius = UDim.new(0, 12)
    afkExitCorner.Parent = afkExit

    -- MAIN HUB WINDOW
    local autoHatchMain = Instance.new("Frame")
    autoHatchMain.Name = "AutoHatchMain"
    autoHatchMain.Size = UDim2.new(0, 600, 0, 700)
    autoHatchMain.Position = UDim2.new(0.5, -300, 0.5, -350)
    autoHatchMain.BackgroundColor3 = Color3.fromRGB(20, 21, 26)
    autoHatchMain.BorderSizePixel = 0
    autoHatchMain.Active = true
    autoHatchMain.Draggable = true
    autoHatchMain.Visible = true
    autoHatchMain.Parent = ui

    local autoHatchCorner = Instance.new("UICorner")
    autoHatchCorner.CornerRadius = UDim.new(0, 12)
    autoHatchCorner.Parent = autoHatchMain
    
    local autoHatchShadow = Instance.new("UIStroke")
    autoHatchShadow.Color = Color3.fromRGB(80, 120, 180)
    autoHatchShadow.Thickness = 1.5
    autoHatchShadow.Transparency = 0.5
    autoHatchShadow.Parent = autoHatchMain

    local autoTitle = Instance.new("TextLabel")
    autoTitle.Size = UDim2.new(1, -24, 0, 40)
    autoTitle.Position = UDim2.new(0, 12, 0, 6)
    autoTitle.Text = "⚡ AUTOMATION HUB"
    autoTitle.TextColor3 = Color3.fromRGB(100, 200, 255)
    autoTitle.Font = Enum.Font.GothamBold
    autoTitle.TextSize = 18
    autoTitle.BackgroundTransparency = 1
    autoTitle.TextXAlignment = Enum.TextXAlignment.Left
    autoTitle.Parent = autoHatchMain

    local tabBar = Instance.new("Frame")
    tabBar.Size = UDim2.new(1, -24, 0, 36)
    tabBar.Position = UDim2.new(0, 12, 0, 48)
    tabBar.BackgroundTransparency = 1
    tabBar.Parent = autoHatchMain

    local function createTabButton(text, position)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0.2, -4, 1, 0)
        btn.Position = UDim2.new(position, 0, 0, 0)
        btn.Text = text
        btn.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
        btn.TextColor3 = Color3.fromRGB(180, 180, 180)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 12
        btn.Parent = tabBar
        
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 6)
        corner.Parent = btn

        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(80, 80, 100)
        stroke.Thickness = 1
        stroke.Transparency = 0.8
        stroke.Parent = btn
        
        return btn
    end

    local hatchTab = createTabButton("Hatch", 0)
    local tpTab = createTabButton("Teleport", 0.2)
    local settingsTab = createTabButton("Settings", 0.4)
    local eggTab = createTabButton("Eggs", 0.6)
    local farmTab = createTabButton("Farm", 0.8)

    local hatchFrame = Instance.new("Frame")
    hatchFrame.Size = UDim2.new(1, -24, 1, -96)
    hatchFrame.Position = UDim2.new(0, 12, 0, 90)
    hatchFrame.BackgroundTransparency = 1
    hatchFrame.ClipsDescendants = true
    hatchFrame.Parent = autoHatchMain

    local tpFrame = Instance.new("Frame")
    tpFrame.Size = UDim2.new(1, -24, 1, -96)
    tpFrame.Position = UDim2.new(0, 12, 0, 90)
    tpFrame.BackgroundTransparency = 1
    tpFrame.Visible = false
    tpFrame.Parent = autoHatchMain

    local settingsFrame = Instance.new("Frame")
    settingsFrame.Size = UDim2.new(1, -24, 1, -96)
    settingsFrame.Position = UDim2.new(0, 12, 0, 90)
    settingsFrame.BackgroundTransparency = 1
    settingsFrame.Visible = false
    settingsFrame.Parent = autoHatchMain

    local eggFrame = Instance.new("Frame")
    eggFrame.Size = UDim2.new(1, -24, 1, -96)
    eggFrame.Position = UDim2.new(0, 12, 0, 90)
    eggFrame.BackgroundTransparency = 1
    eggFrame.Visible = false
    eggFrame.Parent = autoHatchMain

    local farmFrame = Instance.new("Frame")
    farmFrame.Size = UDim2.new(1, -24, 1, -96)
    farmFrame.Position = UDim2.new(0, 12, 0, 90)
    farmFrame.BackgroundTransparency = 1
    farmFrame.Visible = false
    farmFrame.Parent = autoHatchMain

    local activeTheme = {
        background = Color3.fromRGB(20, 21, 26),
        panel = Color3.fromRGB(28, 29, 38),
        surface = Color3.fromRGB(32, 32, 42),
        input = Color3.fromRGB(30, 30, 40),
        accent = Color3.fromRGB(60, 140, 220),
        controlOn = Color3.fromRGB(45, 140, 75),
        danger = Color3.fromRGB(200, 50, 50),
        text = Color3.fromRGB(245, 245, 250),
        muted = Color3.fromRGB(180, 180, 190),
        stroke = Color3.fromRGB(80, 80, 100),
    }

    local function switchTab(activeBtn, activeFrame)
        hatchFrame.Visible = false
        tpFrame.Visible = false
        settingsFrame.Visible = false
        eggFrame.Visible = false
        farmFrame.Visible = false
        
        for _, btn in ipairs({hatchTab, tpTab, settingsTab, eggTab, farmTab}) do
            btn.BackgroundColor3 = activeTheme.surface
            btn.TextColor3 = activeTheme.muted
        end

        activeFrame.Visible = true
        activeBtn.BackgroundColor3 = activeTheme.accent
        activeBtn.TextColor3 = activeTheme.text
    end

    hatchTab.MouseButton1Click:Connect(function() switchTab(hatchTab, hatchFrame) end)
    tpTab.MouseButton1Click:Connect(function() switchTab(tpTab, tpFrame) end)
    settingsTab.MouseButton1Click:Connect(function() switchTab(settingsTab, settingsFrame) end)
    eggTab.MouseButton1Click:Connect(function() switchTab(eggTab, eggFrame) end)
    farmTab.MouseButton1Click:Connect(function() switchTab(farmTab, farmFrame) end)

    switchTab(hatchTab, hatchFrame)

    -- UNIFIED TOGGLE GENERATOR HELPER
    local toggleRegistry = {}

    local function createUnifiedToggle(parent, yPos, text, defaultState, callback)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 34)
        btn.Position = UDim2.new(0, 0, 0, yPos)
        btn.BackgroundColor3 = defaultState and activeTheme.controlOn or activeTheme.surface
        btn.Text = text .. (defaultState and ": ON ✓" or ": OFF")
        btn.TextColor3 = defaultState and activeTheme.text or activeTheme.muted
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 13
        btn.Parent = parent

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 6)
        btnCorner.Parent = btn
        
        local btnStroke = Instance.new("UIStroke")
        btnStroke.Color = activeTheme.stroke
        btnStroke.Thickness = 1
        btnStroke.Transparency = 0.7
        btnStroke.Parent = btn

        local state = defaultState
        btn:SetAttribute("ToggleState", state)

        local function updateVisuals(newState)
            state = newState
            btn:SetAttribute("ToggleState", state)
            btn.BackgroundColor3 = state and activeTheme.controlOn or activeTheme.surface
            btn.Text = text .. (state and ": ON ✓" or ": OFF")
            btn.TextColor3 = state and activeTheme.text or activeTheme.muted
        end

        btn.MouseButton1Click:Connect(function()
            local newState = not state
            updateVisuals(newState)
            callback(newState)

            -- Sync all toggles with matching text
            if toggleRegistry[text] then
                for _, syncFunc in ipairs(toggleRegistry[text]) do
                    syncFunc(newState)
                end
            end
        end)

        if not toggleRegistry[text] then
            toggleRegistry[text] = {}
        end
        table.insert(toggleRegistry[text], updateVisuals)

        return btn, updateVisuals
    end

    -- =====================================================================
    -- AUTO FARM TAB UI
    -- =====================================================================
    local farmTitle = Instance.new("TextLabel")
    farmTitle.Size = UDim2.new(1, 0, 0, 24)
    farmTitle.BackgroundTransparency = 1
    farmTitle.Text = "AUTO FARM CONTROLS"
    farmTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
    farmTitle.Font = Enum.Font.GothamBold
    farmTitle.TextSize = 14
    farmTitle.TextXAlignment = Enum.TextXAlignment.Left
    farmTitle.Parent = farmFrame

    createUnifiedToggle(farmFrame, 30, "🤖 Robot Farm", false, function(state) AutoFarmRobot = state end)
    createUnifiedToggle(farmFrame, 72, "🦃 Turkey/Boss Farm", false, function(state) 
        AutoFarmTurkey = state
        TurkeyDodgeActive = state
    end)
    createUnifiedToggle(farmFrame, 114, "⭐ Auto Tokens", false, function(state) AutoTokens = state end)

    local farmStatus = Instance.new("TextLabel")
    farmStatus.Size = UDim2.new(1, 0, 0, 28)
    farmStatus.Position = UDim2.new(0, 0, 0, 160)
    farmStatus.BackgroundTransparency = 1
    farmStatus.Text = "Status: Idle"
    farmStatus.TextColor3 = Color3.fromRGB(180, 180, 180)
    farmStatus.Font = Enum.Font.GothamBold
    farmStatus.TextSize = 13
    farmStatus.TextXAlignment = Enum.TextXAlignment.Left
    farmStatus.Parent = farmFrame

    task.spawn(function()
        while farmFrame.Parent do
            if AutoFarmRobot and CurrentTargetId then
                farmStatus.Text = "Status: 🤖 Farming Robot #" .. CurrentTargetId
                farmStatus.TextColor3 = Color3.fromRGB(100, 255, 100)
            elseif AutoFarmTurkey and CurrentTargetId then
                if IsEvading then
                    farmStatus.Text = "Status: 🦃 DODGING BOSS FX!"
                    farmStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
                else
                    farmStatus.Text = "Status: 🦃 Farming Target #" .. CurrentTargetId
                    farmStatus.TextColor3 = Color3.fromRGB(255, 200, 100)
                end
            elseif AutoFarmTurkey or AutoFarmRobot then
                farmStatus.Text = "Status: ⏳ Searching Target..."
                farmStatus.TextColor3 = Color3.fromRGB(255, 200, 80)
            else
                farmStatus.Text = "Status: Idle"
                farmStatus.TextColor3 = Color3.fromRGB(150, 150, 150)
            end
            task.wait(0.5)
        end
    end)

    -- =====================================================================
    -- EGG CHANCES TAB
    -- =====================================================================
    local function collectEggChanceData()
        local function trim(value)
            return (value:gsub("^%s+", ""):gsub("%s+$", ""))
        end

        local function parseChance(value)
            if type(value) == "number" then return value end
            if type(value) ~= "string" then return nil end
            local text = trim(value):lower()
            if text == "" then return nil end
            local numerator, denominator = text:match("(%d+)%s*/%s*(%d+)")
            if numerator and denominator then
                return tonumber(numerator) / tonumber(denominator)
            end
            local inValue = text:match("(%d+)%s*in%s*%d+")
            if inValue then return tonumber(inValue) end
            local percent = text:match("(%d+%.?%d*)%%")
            if percent then return tonumber(percent) / 100 end
            return tonumber(text)
        end

        local function safeRequire(moduleScript)
            if not moduleScript or not moduleScript:IsA("ModuleScript") then return nil end
            local ok, result = pcall(require, moduleScript)
            return ok and result or nil
        end

        local function isLikelyEggTable(value)
            if type(value) ~= "table" then return false end
            local hasEggKey, hasChance = false, false
            for key, entry in pairs(value) do
                local keyText = tostring(key):lower()
                if keyText:find("egg") or keyText:find("pet") or keyText:find("chance") or keyText:find("odd") or keyText:find("reward") then
                    hasEggKey = true
                end
                if type(entry) == "number" or type(entry) == "string" then
                    hasChance = hasChance or parseChance(entry) ~= nil
                elseif type(entry) == "table" then
                    for innerKey, innerValue in pairs(entry) do
                        local innerText = tostring(innerKey):lower()
                        if innerText:find("chance") or innerText:find("weight") or innerText:find("odd") or innerText:find("rate") then
                            hasChance = true
                            break
                        end
                        if (type(innerValue) == "number" or type(innerValue) == "string") and parseChance(innerValue) then
                            hasChance = true
                            break
                        end
                    end
                end
            end
            return hasEggKey and hasChance
        end

        local function readEggEntries(value)
            local results = {}
            if type(value) ~= "table" then return results end

            for petName, chanceValue in pairs(value) do
                local chance = parseChance(chanceValue)
                if chance and tostring(petName) ~= "__index" and tostring(petName) ~= "__newindex" then
                    table.insert(results, { Name = tostring(petName):gsub("%s+", " "), Chance = chance })
                end
            end

            if #results == 0 then
                for _, entry in ipairs(value) do
                    if type(entry) == "table" then
                        local name = entry.Name or entry.name or entry.Pet or entry.pet or entry.petName or entry.pet_name
                        local chance = entry.Chance or entry.chance or entry.Weight or entry.weight or entry.Odds or entry.odds or entry.Probability or entry.probability or entry.Rate or entry.rate
                        chance = parseChance(chance)
                        if name and chance then
                            table.insert(results, { Name = tostring(name), Chance = chance })
                        end
                    end
                end
            end

            if #results == 0 then
                for key, nested in pairs(value) do
                    local keyText = tostring(key):lower()
                    if type(nested) == "table" and (keyText:find("egg") or keyText:find("pet") or keyText:find("reward")) then
                        for _, entry in ipairs(readEggEntries(nested)) do table.insert(results, entry) end
                    end
                end
            end

            local seen, deduplicated = {}, {}
            for _, entry in ipairs(results) do
                if entry.Name ~= "" and not seen[entry.Name] then
                    seen[entry.Name] = true
                    table.insert(deduplicated, entry)
                end
            end
            return deduplicated
        end

        local function collectEggsFromTable(value, sourceName)
            local found = {}
            local visited = {}
            local function recurse(current, path)
                if type(current) ~= "table" or visited[current] then return end
                visited[current] = true
                if isLikelyEggTable(current) then
                    local pets = readEggEntries(current)
                    if #pets > 0 then
                        table.insert(found, { Name = sourceName or path or "Unknown Egg", Pets = pets })
                    end
                end
                for key, nested in pairs(current) do
                    if type(nested) == "table" then recurse(nested, tostring(key)) end
                end
            end
            recurse(value, sourceName)
            return found
        end

        local function classifyPet(petInfo)
            if type(petInfo) ~= "table" then return nil end
            local rarity = tostring(petInfo.rarity or petInfo.Rarity or ""):lower()
            if petInfo.gargantuan then return "Gargantuan" end
            if petInfo.titanic then return "Titanic" end
            if petInfo.huge or petInfo.gargantuan then return "Huge" end
            if rarity:find("secret", 1, true) then return "Secret" end
            return nil
        end

        local function collectFromLiveDirectory()
            local liveEggs = {}
            local eggCmds = require(ReplicatedStorage.Library.Client.EggCmds)
            local probabilityGetter = eggCmds and eggCmds.GetProbabilityMap
            if type(probabilityGetter) ~= "function" then return liveEggs end

            local directory
            local function consider(candidate)
                if type(candidate) == "table" and type(candidate.Eggs) == "table" and type(candidate.Pets) == "table" then
                    directory = candidate
                end
            end

            for index = 1, 12 do
                local first, second = debug.getupvalue(probabilityGetter, index)
                if first == nil then break end
                consider(first)
                consider(second)
                if directory then break end
            end
            if not directory then return liveEggs end

            for eggName, egg in pairs(directory.Eggs) do
                if type(egg) == "table" and type(egg.drops) == "table" and egg.currency and egg.hatchable ~= false then
                    local label = tostring(egg.displayName or egg._id or eggName)
                    local lowerLabel = label:lower()
                    if not egg.isExclusive and not egg.isGift and not egg.isPremium and not lowerLabel:find("exclusive", 1, true) then
                        local probabilityMap = probabilityGetter(eggName)
                        local pets = {}
                        for _, drop in ipairs(egg.drops) do
                            if type(drop) == "table" and type(drop[1]) == "string" and tonumber(drop[2]) then
                                local chance = tonumber(drop[2])
                                local mapped = type(probabilityMap) == "table" and tonumber(probabilityMap[drop[1]])
                                if mapped then chance = mapped * 100 end
                                table.insert(pets, { Name = drop[1], Chance = chance, Category = classifyPet(directory.Pets[drop[1]]) })
                            end
                        end
                        if #pets > 0 then table.insert(liveEggs, { Name = label, Pets = pets }) end
                    end
                end
            end
            return liveEggs
        end

        local okLive, liveEggs = pcall(collectFromLiveDirectory)
        if okLive and #liveEggs > 0 then return liveEggs end

        local fallback = {}
        local roots = { Workspace, ReplicatedStorage, game:GetService("ServerScriptService"), game:GetService("StarterPlayer"), game:GetService("StarterGui") }
        local visited = {}
        local function inspectObject(object)
            if not object or visited[object] then return end
            visited[object] = true
            if object:IsA("ModuleScript") then
                local moduleData = safeRequire(object)
                for _, egg in ipairs(collectEggsFromTable(moduleData, object.Name)) do table.insert(fallback, egg) end
            end
            for _, child in ipairs(object:GetChildren()) do inspectObject(child) end
        end
        for _, root in ipairs(roots) do inspectObject(root) end

        local deduplicated, seenEggs = {}, {}
        for _, egg in ipairs(fallback) do
            if not seenEggs[egg.Name] then
                seenEggs[egg.Name] = true
                table.insert(deduplicated, egg)
            end
        end
        return deduplicated
    end

    local eggModeBar = Instance.new("Frame")
    eggModeBar.Size = UDim2.new(1, 0, 0, 32)
    eggModeBar.Position = UDim2.new(0, 0, 0, 0)
    eggModeBar.BackgroundTransparency = 1
    eggModeBar.Parent = eggFrame

    local eggSearch = Instance.new("TextBox")
    eggSearch.Size = UDim2.new(1, 0, 0, 30)
    eggSearch.Position = UDim2.new(0, 0, 0, 38)
    eggSearch.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
    eggSearch.Text = ""
    eggSearch.TextColor3 = Color3.fromRGB(255, 255, 255)
    eggSearch.PlaceholderText = "Search egg filter..."
    eggSearch.ClearTextOnFocus = false
    eggSearch.Font = Enum.Font.Gotham
    eggSearch.TextSize = 15
    eggSearch.Parent = eggFrame

    local eggSearchCorner = Instance.new("UICorner")
    eggSearchCorner.CornerRadius = UDim.new(0, 6)
    eggSearchCorner.Parent = eggSearch

    local eggSearchStroke = Instance.new("UIStroke")
    eggSearchStroke.Color = Color3.fromRGB(80, 80, 100)
    eggSearchStroke.Thickness = 1
    eggSearchStroke.Transparency = 0.7
    eggSearchStroke.Parent = eggSearch

    local eggSelect = Instance.new("TextButton")
    eggSelect.Size = UDim2.new(1, 0, 0, 30)
    eggSelect.Position = UDim2.new(0, 0, 0, 74)
    eggSelect.BackgroundColor3 = Color3.fromRGB(35, 35, 48)
    eggSelect.TextColor3 = Color3.fromRGB(255, 255, 255)
    eggSelect.Font = Enum.Font.GothamBold
    eggSelect.TextSize = 15
    eggSelect.Text = "Select Egg Dropdown ▼"
    eggSelect.Parent = eggFrame

    local eggSelectCorner = Instance.new("UICorner")
    eggSelectCorner.CornerRadius = UDim.new(0, 6)
    eggSelectCorner.Parent = eggSelect

    local eggSelectStroke = Instance.new("UIStroke")
    eggSelectStroke.Color = Color3.fromRGB(80, 80, 100)
    eggSelectStroke.Thickness = 1
    eggSelectStroke.Transparency = 0.7
    eggSelectStroke.Parent = eggSelect

    local eggOptions = Instance.new("ScrollingFrame")
    eggOptions.Size = UDim2.new(1, 0, 0, 160)
    eggOptions.Position = UDim2.new(0, 0, 0, 108)
    eggOptions.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
    eggOptions.BorderSizePixel = 0
    eggOptions.ScrollBarThickness = 5
    eggOptions.AutomaticCanvasSize = Enum.AutomaticSize.Y
    eggOptions.Visible = true
    eggOptions.ZIndex = 20
    eggOptions.Parent = eggFrame

    local eggOptionsCorner = Instance.new("UICorner")
    eggOptionsCorner.CornerRadius = UDim.new(0, 6)
    eggOptionsCorner.Parent = eggOptions

    local eggOptionsStroke = Instance.new("UIStroke")
    eggOptionsStroke.Color = Color3.fromRGB(80, 80, 100)
    eggOptionsStroke.Thickness = 1
    eggOptionsStroke.Transparency = 0.6
    eggOptionsStroke.Parent = eggOptions

    local eggOptionsLayout = Instance.new("UIListLayout")
    eggOptionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    eggOptionsLayout.Padding = UDim.new(0, 2)
    eggOptionsLayout.Parent = eggOptions

    local eggResults = Instance.new("ScrollingFrame")
    eggResults.Size = UDim2.new(1, 0, 1, -276)
    eggResults.Position = UDim2.new(0, 0, 0, 276)
    eggResults.BackgroundColor3 = Color3.fromRGB(16, 17, 22)
    eggResults.BorderSizePixel = 0
    eggResults.AutomaticCanvasSize = Enum.AutomaticSize.Y
    eggResults.ScrollBarThickness = 5
    eggResults.Parent = eggFrame

    local eggResultsCorner = Instance.new("UICorner")
    eggResultsCorner.CornerRadius = UDim.new(0, 8)
    eggResultsCorner.Parent = eggResults

    local eggResultsLayout = Instance.new("UIListLayout")
    eggResultsLayout.Padding = UDim.new(0, 4)
    eggResultsLayout.Parent = eggResults

    local chanceEggs = collectEggChanceData()
    local function getEggBestChance(egg)
        local bestChance = 0
        for _, pet in ipairs(egg.Pets or {}) do
            if pet.Category then
                bestChance = math.max(bestChance, tonumber(pet.Chance) or 0)
            end
        end
        if bestChance == 0 then
            for _, pet in ipairs(egg.Pets or {}) do
                bestChance = math.max(bestChance, tonumber(pet.Chance) or 0)
            end
        end
        return bestChance
    end

    local sortedEggs = {}
    for _, egg in ipairs(chanceEggs) do table.insert(sortedEggs, egg) end
    table.sort(sortedEggs, function(a, b)
        return getEggBestChance(a) > getEggBestChance(b)
    end)
    local bestChanceEgg = sortedEggs[1]
    local selectedChanceEgg = bestChanceEgg and bestChanceEgg.Name or nil
    local chanceMode = "Eggs"
    local showingEasiestPets = false
    local subTabButtons = {}

    local function clearEggResults()
        for _, child in ipairs(eggResults:GetChildren()) do
            if child:IsA("Frame") or child:IsA("TextLabel") then child:Destroy() end
        end
    end

    local rarityColors = {
        Huge = Color3.fromRGB(100, 210, 255),
        Secret = Color3.fromRGB(145, 75, 190),
        Titanic = Color3.fromRGB(255, 210, 80),
        Gargantuan = Color3.fromRGB(235, 80, 90),
        Normal = Color3.fromRGB(245, 245, 250),
    }

    local function addChanceRow(name, chance, category)
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -8, 0, 38)
        row.BackgroundColor3 = activeTheme.panel
        row.BorderSizePixel = 0
        row.Parent = eggResults

        local rowCorner = Instance.new("UICorner")
        rowCorner.CornerRadius = UDim.new(0, 4)
        rowCorner.Parent = row

        local petLabel = Instance.new("TextLabel")
        petLabel.Size = UDim2.new(0.45, -8, 1, 0)
        petLabel.Position = UDim2.new(0, 8, 0, 0)
        petLabel.BackgroundTransparency = 1
        petLabel.TextColor3 = activeTheme.text
        petLabel.Font = Enum.Font.Gotham
        petLabel.TextSize = 13
        petLabel.TextTruncate = Enum.TextTruncate.AtEnd
        petLabel.TextWrapped = false
        petLabel.TextXAlignment = Enum.TextXAlignment.Left
        petLabel.Text = tostring(name)
        petLabel.Parent = row

        local rarityName = category or "Normal"
        local rarityLabel = Instance.new("TextLabel")
        rarityLabel.Size = UDim2.new(0.22, -4, 1, 0)
        rarityLabel.Position = UDim2.new(0.45, 0, 0, 0)
        rarityLabel.BackgroundTransparency = 1
        rarityLabel.TextColor3 = rarityColors[rarityName] or rarityColors.Normal
        rarityLabel.Font = rarityName == "Secret" and Enum.Font.Fantasy or Enum.Font.GothamBold
        rarityLabel.TextSize = 12
        rarityLabel.Text = rarityName
        rarityLabel.TextTruncate = Enum.TextTruncate.AtEnd
        rarityLabel.TextWrapped = false
        rarityLabel.TextXAlignment = Enum.TextXAlignment.Left
        rarityLabel:SetAttribute("RareTextColor", true)
        rarityLabel.Parent = row

        local chanceLabel = Instance.new("TextLabel")
        chanceLabel.Size = UDim2.new(0.33, -8, 1, 0)
        chanceLabel.Position = UDim2.new(0.67, 0, 0, 0)
        chanceLabel.BackgroundTransparency = 1
        chanceLabel.TextColor3 = activeTheme.accent
        chanceLabel.Font = Enum.Font.GothamBold
        chanceLabel.TextSize = 12
        chanceLabel.TextTruncate = Enum.TextTruncate.AtEnd
        chanceLabel.TextWrapped = false
        chanceLabel.TextXAlignment = Enum.TextXAlignment.Right
        chanceLabel.Text = string.format("%.4g%% | 1/%.0f", chance, chance > 0 and 100 / chance or 0)
        chanceLabel.Parent = row
    end

    local function renderChanceResults()
        clearEggResults()
        local rows = {}
        if showingEasiestPets then
            local easiestByPet = {}
            for _, egg in ipairs(chanceEggs) do
                for _, pet in ipairs(egg.Pets) do
                    if pet.Category then
                        local key = pet.Category .. ":" .. pet.Name
                        local current = easiestByPet[key]
                        if not current or (tonumber(pet.Chance) or 0) > current.Chance then
                            easiestByPet[key] = {
                                Name = pet.Category .. " | " .. pet.Name .. " | " .. egg.Name,
                                Chance = tonumber(pet.Chance) or 0,
                                Category = pet.Category,
                            }
                        end
                    end
                end
            end
            for _, pet in pairs(easiestByPet) do table.insert(rows, pet) end
        else
            for _, egg in ipairs(chanceEggs) do
                if chanceMode == "Eggs" and egg.Name == selectedChanceEgg then
                    for _, pet in ipairs(egg.Pets) do
                        table.insert(rows, { Name = pet.Name, Chance = pet.Chance, Category = pet.Category })
                    end
                elseif chanceMode ~= "Eggs" then
                    for _, pet in ipairs(egg.Pets) do
                        if pet.Category == chanceMode then
                            table.insert(rows, { Name = pet.Name .. " | " .. egg.Name, Chance = pet.Chance, Category = pet.Category })
                        end
                    end
                end
            end
        end
        table.sort(rows, function(a, b) return (a.Chance or 0) > (b.Chance or 0) end)
        for _, row in ipairs(rows) do addChanceRow(row.Name, row.Chance, row.Category) end
    end

    local function rebuildEggOptions()
        for _, child in ipairs(eggOptions:GetChildren()) do
            if child:IsA("TextButton") then child:Destroy() end
        end

        local query = eggSearch.Text:lower()
        local bestEgg = sortedEggs[1]
        if bestEgg then
            local bestOption = Instance.new("TextButton")
            bestOption.Size = UDim2.new(1, -6, 0, 32)
            bestOption.BackgroundColor3 = activeTheme.accent
            bestOption.TextColor3 = activeTheme.text
            bestOption.Font = Enum.Font.GothamBold
            bestOption.TextSize = 14
            bestOption.TextTruncate = Enum.TextTruncate.AtEnd
            bestOption.TextWrapped = false
            bestOption.Text = string.format("★ Best chance: %s (%.4g%%)", bestEgg.Name, getEggBestChance(bestEgg))
            bestOption.Parent = eggOptions

            local bestCorner = Instance.new("UICorner")
            bestCorner.CornerRadius = UDim.new(0, 4)
            bestCorner.Parent = bestOption

            bestOption.MouseButton1Click:Connect(function()
                showingEasiestPets = false
                selectedChanceEgg = bestEgg.Name
                chanceMode = "Eggs"
                eggSelect.Text = "Selected: " .. bestEgg.Name
                renderChanceResults()
            end)
        end

        for _, egg in ipairs(sortedEggs) do
            if query == "" or egg.Name:lower():find(query, 1, true) then
                local option = Instance.new("TextButton")
                option.Size = UDim2.new(1, -6, 0, 28)
                option.BackgroundColor3 = activeTheme.surface
                option.TextColor3 = activeTheme.text
                option.Font = Enum.Font.Gotham
                option.TextSize = 13
                option.TextTruncate = Enum.TextTruncate.AtEnd
                option.TextWrapped = false
                option.Text = egg.Name
                option.Parent = eggOptions

                local optCorner = Instance.new("UICorner")
                optCorner.CornerRadius = UDim.new(0, 4)
                optCorner.Parent = option

                option.MouseButton1Click:Connect(function()
                    showingEasiestPets = false
                    selectedChanceEgg = egg.Name
                    eggSelect.Text = "Egg: " .. egg.Name
                    eggOptions.Visible = true
                    chanceMode = "Eggs"
                    
                    for modeKey, btnObj in pairs(subTabButtons) do
                        if modeKey == "Eggs" then
                            btnObj.BackgroundColor3 = activeTheme.accent
                            btnObj.TextColor3 = activeTheme.text
                        else
                            btnObj.BackgroundColor3 = activeTheme.surface
                            btnObj.TextColor3 = activeTheme.muted
                        end
                    end
                    renderChanceResults()
                end)
            end
        end
    end

    local function selectEggSubTab(mode, targetBtn)
        showingEasiestPets = false
        chanceMode = mode
        eggOptions.Visible = mode == "Eggs"

        for _, btn in pairs(subTabButtons) do
            btn.BackgroundColor3 = activeTheme.surface
            btn.TextColor3 = activeTheme.muted
        end

        targetBtn.BackgroundColor3 = activeTheme.accent
        targetBtn.TextColor3 = activeTheme.text

        renderChanceResults()
    end

    local function addEggModeButton(text, position, mode)
        local button = Instance.new("TextButton")
        button.Size = UDim2.new(0.2, -4, 1, 0)
        button.Position = UDim2.new(position, 0, 0, 0)
        button.BackgroundColor3 = mode == "Eggs" and activeTheme.accent or activeTheme.surface
        button.TextColor3 = mode == "Eggs" and activeTheme.text or activeTheme.muted
        button.Font = Enum.Font.GothamBold
        button.TextSize = 11
        button.Text = text
        button.Parent = eggModeBar

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 6)
        corner.Parent = button

        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(80, 80, 100)
        stroke.Thickness = 1
        stroke.Transparency = 0.8
        stroke.Parent = button

        subTabButtons[mode] = button

        button.MouseButton1Click:Connect(function()
            selectEggSubTab(mode, button)
        end)
    end

    addEggModeButton("Eggs", 0, "Eggs")
    addEggModeButton("Huges", 0.2, "Huge")
    addEggModeButton("Titanics", 0.4, "Titanic")
    addEggModeButton("Secrets", 0.6, "Secret")
    addEggModeButton("Gargantuans", 0.8, "Gargantuan")

    eggSelect.MouseButton1Click:Connect(function() eggOptions.Visible = not eggOptions.Visible end)
    eggSearch:GetPropertyChangedSignal("Text"):Connect(function()
        rebuildEggOptions()
        eggOptions.Visible = chanceMode == "Eggs"
    end)
    rebuildEggOptions()
    eggSelect.Text = bestChanceEgg and ("Selected: " .. bestChanceEgg.Name) or "Select an egg"
    eggOptions.Visible = true
    renderChanceResults()

    -- =====================================================================
    -- AUTO HATCH TAB UI
    -- =====================================================================
    local function formatNumber(value)
        local text = tostring(value)
        while true do
            local newText, matches = string.gsub(text, "^(-?%d+)(%d%d%d)", "%1,%2")
            if matches == 0 then break end
            text = newText
        end
        return text
    end

    local statsContainer = Instance.new("Frame")
    statsContainer.Size = UDim2.new(1, 0, 0, 142)
    statsContainer.Position = UDim2.new(0, 0, 0, 8)
    statsContainer.BackgroundColor3 = Color3.fromRGB(28, 29, 38)
    statsContainer.Parent = hatchFrame

    local statsCorner = Instance.new("UICorner")
    statsCorner.CornerRadius = UDim.new(0, 6)
    statsCorner.Parent = statsContainer

    local EggsLabel = Instance.new("TextLabel")
    EggsLabel.Size = UDim2.new(1, -20, 0, 22)
    EggsLabel.Position = UDim2.new(0, 10, 0, 0)
    EggsLabel.Text = "Eggs: 0"
    EggsLabel.TextColor3 = Color3.fromRGB(80, 230, 80)
    EggsLabel.Font = Enum.Font.GothamBold
    EggsLabel.TextSize = 13
    EggsLabel.BackgroundTransparency = 1
    EggsLabel.TextXAlignment = Enum.TextXAlignment.Left
    EggsLabel.Parent = statsContainer

    local GemsLabel = Instance.new("TextLabel")
    GemsLabel.Size = UDim2.new(1, -20, 0, 22)
    GemsLabel.Position = UDim2.new(0, 10, 0, 23)
    GemsLabel.Text = "Diamonds: 0"
    GemsLabel.TextColor3 = Color3.fromRGB(110, 185, 255)
    GemsLabel.Font = Enum.Font.GothamBold
    GemsLabel.TextSize = 13
    GemsLabel.BackgroundTransparency = 1
    GemsLabel.TextXAlignment = Enum.TextXAlignment.Left
    GemsLabel.Parent = statsContainer

    local function makeHatchRareLabel(name, position)
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -20, 0, 22)
        label.Position = UDim2.new(0, 10, 0, position)
        label.Text = name .. ": 0"
        label.TextColor3 = Color3.fromRGB(255, 210, 80)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 13
        label.BackgroundTransparency = 1
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = statsContainer
        hatchRareLabels[name] = label
    end

    makeHatchRareLabel("Huges", 46)
    makeHatchRareLabel("Secrets", 69)
    makeHatchRareLabel("Titanics", 92)
    makeHatchRareLabel("Gargantuans", 115)

    local SearchBox = Instance.new("TextBox")
    SearchBox.Size = UDim2.new(1, 0, 0, 30)
    SearchBox.Position = UDim2.new(0, 0, 0, 162)
    SearchBox.PlaceholderText = "Search egg to hatch..."
    SearchBox.Text = ""
    SearchBox.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
    SearchBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    SearchBox.Font = Enum.Font.Gotham
    SearchBox.TextSize = 13
    SearchBox.Parent = hatchFrame

    local searchCorner = Instance.new("UICorner")
    searchCorner.CornerRadius = UDim.new(0, 6)
    searchCorner.Parent = SearchBox

    local searchStroke = Instance.new("UIStroke")
    searchStroke.Color = Color3.fromRGB(80, 80, 100)
    searchStroke.Thickness = 1
    searchStroke.Transparency = 0.7
    searchStroke.Parent = SearchBox

    local SelectedEggLabel = Instance.new("TextLabel")
    SelectedEggLabel.Size = UDim2.new(1, 0, 0, 20)
    SelectedEggLabel.Position = UDim2.new(0, 0, 0, 198)
    SelectedEggLabel.Text = "Selected: Spawn Egg"
    SelectedEggLabel.TextColor3 = Color3.fromRGB(100, 225, 100)
    SelectedEggLabel.Font = Enum.Font.GothamBold
    SelectedEggLabel.TextSize = 12
    SelectedEggLabel.BackgroundTransparency = 1
    SelectedEggLabel.TextXAlignment = Enum.TextXAlignment.Left
    SelectedEggLabel.Parent = hatchFrame

    local DropdownFrame = Instance.new("ScrollingFrame")
    DropdownFrame.Size = UDim2.new(1, 0, 0, 110)
    DropdownFrame.Position = UDim2.new(0, 0, 0, 222)
    DropdownFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
    DropdownFrame.BorderSizePixel = 0
    DropdownFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    DropdownFrame.ScrollBarThickness = 5
    DropdownFrame.Parent = hatchFrame

    local dropdownCorner = Instance.new("UICorner")
    dropdownCorner.CornerRadius = UDim.new(0, 6)
    dropdownCorner.Parent = DropdownFrame

    local dropdownStroke = Instance.new("UIStroke")
    dropdownStroke.Color = Color3.fromRGB(80, 80, 100)
    dropdownStroke.Thickness = 1
    dropdownStroke.Transparency = 0.7
    dropdownStroke.Parent = DropdownFrame

    local dropdownLayout = Instance.new("UIListLayout")
    dropdownLayout.Parent = DropdownFrame
    dropdownLayout.SortOrder = Enum.SortOrder.LayoutOrder
    dropdownLayout.Padding = UDim.new(0, 2)

    local EggList = {
        { ID = "Spawn Egg", Name = "Spawn Egg" },
        { ID = "Fogbound Forest Egg", Name = "Fogbound Forest Egg" },
    }

    pcall(function()
        local Lib = require(ReplicatedStorage.Framework.Library)
        if Lib and Lib.Directory and Lib.Directory.Eggs then
            local list = {}
            for id, data in pairs(Lib.Directory.Eggs) do
                if type(data) == "table" then
                    table.insert(list, { ID = id, Name = data.displayName or id })
                end
            end
            table.sort(list, function(a, b)
                return (a.Name or ""):lower() < (b.Name or ""):lower()
            end)
            EggList = list
        end
    end)

    local SelectedEggId = EggList[1] and EggList[1].ID or "Spawn Egg"
    local function updateDropdown(filter)
        for _, child in ipairs(DropdownFrame:GetChildren()) do
            if child:IsA("TextButton") then child:Destroy() end
        end
        local query = filter:lower()
        local count = 0
        for _, egg in ipairs(EggList) do
            if query == "" or (egg.Name or ""):lower():find(query, 1, true) then
                count += 1
                local button = Instance.new("TextButton")
                button.Size = UDim2.new(1, -6, 0, 24)
                button.BackgroundColor3 = activeTheme.surface
                button.Text = "  " .. egg.Name
                button.TextColor3 = activeTheme.text
                button.Font = Enum.Font.Gotham
                button.TextSize = 12
                button.TextXAlignment = Enum.TextXAlignment.Left
                button.Parent = DropdownFrame

                local optCorner = Instance.new("UICorner")
                optCorner.CornerRadius = UDim.new(0, 4)
                optCorner.Parent = button

                button.MouseButton1Click:Connect(function()
                    SelectedEggId = egg.ID
                    SelectedEggLabel.Text = "Selected: " .. egg.Name
                end)
            end
        end
        DropdownFrame.CanvasSize = UDim2.new(0, 0, 0, math.max(count * 26, 0))
    end

    updateDropdown("")
    SelectedEggLabel.Text = "Selected: " .. (EggList[1] and EggList[1].Name or "None")

    SearchBox.Changed:Connect(function(prop)
        if prop == "Text" then
            updateDropdown(SearchBox.Text)
        end
    end)

    local AutoBuying = false
    local ToggleKey = Enum.KeyCode.LeftControl

    local function setAfkMode(enabled)
        pcall(function()
            if enabled then
                PotatoMode = true
                RunService:Set3dRenderingEnabled(false)
                settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
                Lighting.GlobalShadows = false
                afkOverlay.Visible = true
                autoHatchMain.Visible = false
            else
                PotatoMode = false
                RunService:Set3dRenderingEnabled(true)
                settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic
                Lighting.GlobalShadows = true
                afkOverlay.Visible = false
                autoHatchMain.Visible = true
            end
        end)
    end

    createUnifiedToggle(hatchFrame, 348, "AFK CPU Reducer", false, function(value) setAfkMode(value) end)
    createUnifiedToggle(hatchFrame, 390, "⚡ Auto-Hatch Egg", false, function(value) AutoBuying = value end)

    local recentPanel = Instance.new("Frame")
    recentPanel.Name = "RecentHatchesPanel"
    recentPanel.Size = UDim2.new(1, 0, 0, 160)
    recentPanel.Position = UDim2.new(0, 0, 0, 438)
    recentPanel.BackgroundColor3 = activeTheme.panel
    recentPanel.BorderSizePixel = 0
    recentPanel.Parent = hatchFrame

    local recentPanelCorner = Instance.new("UICorner")
    recentPanelCorner.CornerRadius = UDim.new(0, 8)
    recentPanelCorner.Parent = recentPanel

    local recentPanelStroke = Instance.new("UIStroke")
    recentPanelStroke.Color = activeTheme.stroke
    recentPanelStroke.Transparency = 0.45
    recentPanelStroke.Parent = recentPanel

    local recentTitle = Instance.new("TextLabel")
    recentTitle.Size = UDim2.new(1, -16, 0, 24)
    recentTitle.Position = UDim2.new(0, 8, 0, 5)
    recentTitle.BackgroundTransparency = 1
    recentTitle.Text = "RECENT RARE HATCHES"
    recentTitle.TextColor3 = activeTheme.text
    recentTitle.Font = Enum.Font.GothamBold
    recentTitle.TextSize = 13
    recentTitle.TextXAlignment = Enum.TextXAlignment.Left
    recentTitle.Parent = recentPanel

    local recentCategories = {
        { name = "Huge", entries = recentHuges, color = Color3.fromRGB(100, 255, 100) },
        { name = "Secret", entries = recentSecrets, color = Color3.fromRGB(215, 150, 255) },
        { name = "Titanic", entries = recentTitanics, color = Color3.fromRGB(160, 220, 255) },
        { name = "Gargantuan", entries = recentGargantuans, color = Color3.fromRGB(255, 180, 200) },
    }

    for index, category in ipairs(recentCategories) do
        local column = Instance.new("Frame")
        column.Size = UDim2.new(0.25, -6, 1, -34)
        column.Position = UDim2.new((index - 1) * 0.25, 4, 0, 31)
        column.BackgroundTransparency = 1
        column.Parent = recentPanel

        local header = Instance.new("TextLabel")
        header.Size = UDim2.new(1, -6, 0, 20)
        header.Position = UDim2.new(0, 3, 0, 0)
        header.BackgroundTransparency = 1
        header.Text = category.name
        header.TextColor3 = category.color
        header.Font = Enum.Font.GothamBold
        header.TextSize = 12
        header.TextXAlignment = Enum.TextXAlignment.Left
        header:SetAttribute("RareTextColor", true)
        header.Parent = column

        local list = Instance.new("Frame")
        list.Size = UDim2.new(1, -6, 1, -22)
        list.Position = UDim2.new(0, 3, 0, 22)
        list.BackgroundTransparency = 1
        list.Parent = column
        hatchRecentLists[category.name] = { frame = list, entries = category.entries, color = category.color }
    end

    for index = 1, 3 do
        local divider = Instance.new("Frame")
        divider.Size = UDim2.new(0, 1, 1, -42)
        divider.Position = UDim2.new(index * 0.25, 0, 0, 36)
        divider.BackgroundColor3 = activeTheme.stroke
        divider.BackgroundTransparency = 0.35
        divider.BorderSizePixel = 0
        divider:SetAttribute("ThemeDivider", true)
        divider.Parent = recentPanel
    end

    renderHatchRecent = function()
        for _, category in ipairs(recentCategories) do
            local listData = hatchRecentLists[category.name]
            if listData then
                for _, child in ipairs(listData.frame:GetChildren()) do
                    if child:IsA("TextLabel") then child:Destroy() end
                end
                for entryIndex, entryData in ipairs(listData.entries) do
                    local label = Instance.new("TextLabel")
                    label.Size = UDim2.new(1, 0, 0, 20)
                    label.Position = UDim2.new(0, 0, 0, (entryIndex - 1) * 20)
                    label.BackgroundTransparency = 1
                    label.Text = "✓ " .. tostring(entryData.name)
                    label.TextColor3 = listData.color
                    label.Font = Enum.Font.Gotham
                    label.TextSize = 11
                    label.TextTruncate = Enum.TextTruncate.AtEnd
                    label.TextXAlignment = Enum.TextXAlignment.Left
                    label:SetAttribute("RareTextColor", true)
                    label.Parent = listData.frame
                end
            end
        end
    end
    renderHatchRecent()

    afkExit.MouseButton1Click:Connect(function()
        setAfkMode(false)
        if toggleRegistry["AFK CPU Reducer"] then
            for _, syncFunc in ipairs(toggleRegistry["AFK CPU Reducer"]) do
                syncFunc(false)
            end
        end
    end)

    -- EXPANDED RARE PETS PANEL WITH ENLARGED TEXT & SIZES
    local afkRarePanel = Instance.new("Frame")
    afkRarePanel.Name = "AfkRarePanel"
    afkRarePanel.Size = UDim2.new(1, 0, 0, 440)
    afkRarePanel.Position = UDim2.new(0, 0, 0, 220)
    afkRarePanel.BackgroundColor3 = activeTheme.panel
    afkRarePanel.BorderSizePixel = 0
    afkRarePanel.Parent = afkCenter

    local afkRareCorner = Instance.new("UICorner")
    afkRareCorner.CornerRadius = UDim.new(0, 12)
    afkRareCorner.Parent = afkRarePanel

    local afkRareStroke = Instance.new("UIStroke")
    afkRareStroke.Color = activeTheme.stroke
    afkRareStroke.Transparency = 0.35
    afkRareStroke.Parent = afkRarePanel

    local afkRareTitle = Instance.new("TextLabel")
    afkRareTitle.Size = UDim2.new(1, -20, 0, 45)
    afkRareTitle.Position = UDim2.new(0, 12, 0, 8)
    afkRareTitle.BackgroundTransparency = 1
    afkRareTitle.Text = "RARE PETS"
    afkRareTitle.TextColor3 = activeTheme.text
    afkRareTitle.Font = Enum.Font.GothamBold
    afkRareTitle.TextSize = 28
    afkRareTitle.TextXAlignment = Enum.TextXAlignment.Left
    afkRareTitle.Parent = afkRarePanel

    for index, category in ipairs(recentCategories) do
        local column = Instance.new("Frame")
        column.Size = UDim2.new(0.25, -8, 1, -60)
        column.Position = UDim2.new((index - 1) * 0.25, 4, 0, 55)
        column.BackgroundTransparency = 1
        column.Parent = afkRarePanel

        local countLabel = Instance.new("TextLabel")
        countLabel.Size = UDim2.new(1, -6, 0, 36)
        countLabel.Position = UDim2.new(0, 3, 0, 0)
        countLabel.BackgroundTransparency = 1
        countLabel.Text = category.name .. ": 0"
        countLabel.TextColor3 = category.color
        countLabel.Font = Enum.Font.GothamBold
        countLabel.TextSize = 24
        countLabel.TextXAlignment = Enum.TextXAlignment.Left
        countLabel:SetAttribute("RareTextColor", true)
        countLabel.Parent = column
        afkRareLabels[category.name .. "s"] = countLabel

        local list = Instance.new("Frame")
        list.Size = UDim2.new(1, -6, 1, -40)
        list.Position = UDim2.new(0, 3, 0, 40)
        list.BackgroundTransparency = 1
        list.Parent = column
        afkRecentLists[category.name] = { frame = list, entries = category.entries, color = category.color }
    end

    for index = 1, 3 do
        local divider = Instance.new("Frame")
        divider.Size = UDim2.new(0, 1, 1, -70)
        divider.Position = UDim2.new(index * 0.25, 0, 0, 60)
        divider.BackgroundColor3 = activeTheme.stroke
        divider.BackgroundTransparency = 0.35
        divider.BorderSizePixel = 0
        divider:SetAttribute("ThemeDivider", true)
        divider.Parent = afkRarePanel
    end

    renderAfkRecent = function()
        for _, category in ipairs(recentCategories) do
            local listData = afkRecentLists[category.name]
            if listData then
                for _, child in ipairs(listData.frame:GetChildren()) do
                    if child:IsA("TextLabel") then child:Destroy() end
                end
                for entryIndex, entryData in ipairs(listData.entries) do
                    local label = Instance.new("TextLabel")
                    label.Size = UDim2.new(1, 0, 0, 32)
                    label.Position = UDim2.new(0, 0, 0, (entryIndex - 1) * 34)
                    label.BackgroundTransparency = 1
                    label.Text = "✓ " .. tostring(entryData.name)
                    label.TextColor3 = listData.color
                    label.Font = Enum.Font.Gotham
                    label.TextSize = 19
                    label.TextTruncate = Enum.TextTruncate.AtEnd
                    label.TextXAlignment = Enum.TextXAlignment.Left
                    label:SetAttribute("RareTextColor", true)
                    label.Parent = listData.frame
                end
            end
        end
    end

    local childNodes = ReplicatedStorage:GetChildren()
    renderAfkRecent()
    local BuyEggRemote = nil

    if childNodes[60] and childNodes[60]:IsA("RemoteFunction") then
        BuyEggRemote = childNodes[60]
    else
        for _, obj in ipairs(childNodes) do
            if obj:IsA("RemoteFunction") and (obj.Name:lower():find("egg") or obj.Name:lower():find("buy")) then
                BuyEggRemote = obj
                break
            end
        end
    end

    pcall(function()
        local Lib = require(ReplicatedStorage:WaitForChild("Framework", 2):WaitForChild("Library", 2))
        if Lib then
            if Lib.Variables then
                Lib.Variables.OpeningEgg = 0
            end
            if Lib.EggCmd and type(Lib.EggCmd.Open) == "function" then
                Lib.EggCmd.Open = function() return end
            end
        end
    end)

    if localPlayer then
        local targetGui = localPlayer:WaitForChild("PlayerGui", 2)
        if targetGui then
            for _, gui in ipairs(targetGui:GetChildren()) do
                if gui.Name:lower():find("egg") or gui.Name:lower():find("open") then
                    gui:Destroy()
                end
            end
        end
    end

    local function hookLeaderstats()
        local leaderstats = localPlayer:WaitForChild("leaderstats", 5)
        if not leaderstats then return end

        local eggsStat = leaderstats:FindFirstChild("Eggs Hatched")
        if eggsStat then
            EggsLabel.Text = "Eggs: " .. formatNumber(eggsStat.Value)
            afkEggs.Text = "Eggs Hatched: " .. formatNumber(eggsStat.Value)
            eggsStat.Changed:Connect(function(value)
                EggsLabel.Text = "Eggs: " .. formatNumber(value)
                afkEggs.Text = "Eggs Hatched: " .. formatNumber(value)
            end)
        end

        local gemStat = leaderstats:FindFirstChild("Diamonds")
        if gemStat then
            GemsLabel.Text = "Diamonds: " .. formatNumber(gemStat.Value)
            afkGems.Text = "Diamonds: " .. formatNumber(gemStat.Value)
            gemStat.Changed:Connect(function(value)
                GemsLabel.Text = "Diamonds: " .. formatNumber(value)
                afkGems.Text = "Diamonds: " .. formatNumber(value)
            end)
        end
    end
    task.spawn(hookLeaderstats)

    local BATCH_SIZE = 3
    task.spawn(function()
        while true do
            if AutoBuying and SelectedEggId and BuyEggRemote then
                for i = 1, BATCH_SIZE do
                    task.spawn(function()
                        pcall(function()
                            BuyEggRemote:InvokeServer(SelectedEggId, false, false, true)
                        end)
                    end)
                end
                task.wait(0.01)
            else
                task.wait(0.01)
            end
        end
    end)

    -- =====================================================================
    -- TELEPORT TAB UI
    -- =====================================================================
    local function teleportTo(x, y, z)
        local character = localPlayer.Character
        if character and character:FindFirstChild("HumanoidRootPart") then
            character.HumanoidRootPart.CFrame = CFrame.new(x, y, z)
        end
    end

    local function createTeleportButton(parent, yPos, name, coords)
        local button = Instance.new("TextButton")
        button.Size = UDim2.new(1, 0, 0, 34)
        button.Position = UDim2.new(0, 0, 0, yPos)
        button.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
        button.Text = "📍 Teleport to " .. name
        button.TextColor3 = Color3.fromRGB(255, 255, 255)
        button.Font = Enum.Font.GothamBold
        button.TextSize = 13
        button.Parent = parent

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 6)
        btnCorner.Parent = button

        local btnStroke = Instance.new("UIStroke")
        btnStroke.Color = Color3.fromRGB(80, 80, 100)
        btnStroke.Thickness = 1
        btnStroke.Transparency = 0.7
        btnStroke.Parent = button

        button.MouseButton1Click:Connect(function()
            teleportTo(coords[1], coords[2], coords[3])
        end)
    end

    createTeleportButton(tpFrame, 0, "World 1 Spawn", {267, 98, 238})
    createTeleportButton(tpFrame, 42, "Fantasy Spawn", {-7568, 558, -1683})
    createTeleportButton(tpFrame, 84, "Tech Spawn", {-9977, 16, 9601})
    createTeleportButton(tpFrame, 126, "Last Area", {-7997, 16, 9609})

    -- =====================================================================
    -- SETTINGS TAB UI
    -- =====================================================================
    local keybindLabel = Instance.new("TextLabel")
    keybindLabel.Size = UDim2.new(1, 0, 0, 20)
    keybindLabel.Position = UDim2.new(0, 0, 0, 0)
    keybindLabel.Text = "Toggle Menu Keybind:"
    keybindLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    keybindLabel.Font = Enum.Font.GothamBold
    keybindLabel.TextSize = 13
    keybindLabel.BackgroundTransparency = 1
    keybindLabel.TextXAlignment = Enum.TextXAlignment.Left
    keybindLabel.Parent = settingsFrame

    local keybindBox = Instance.new("TextBox")
    keybindBox.Size = UDim2.new(1, 0, 0, 32)
    keybindBox.Position = UDim2.new(0, 0, 0, 24)
    keybindBox.Text = ToggleKey.Name
    keybindBox.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
    keybindBox.TextColor3 = Color3.fromRGB(100, 225, 100)
    keybindBox.Font = Enum.Font.GothamBold
    keybindBox.TextSize = 13
    keybindBox.Parent = settingsFrame

    local boxCorner = Instance.new("UICorner")
    boxCorner.CornerRadius = UDim.new(0, 6)
    boxCorner.Parent = keybindBox

    local boxStroke = Instance.new("UIStroke")
    boxStroke.Color = Color3.fromRGB(80, 80, 100)
    boxStroke.Thickness = 1
    boxStroke.Transparency = 0.7
    boxStroke.Parent = keybindBox

    keybindBox.FocusLost:Connect(function()
        local inputName = keybindBox.Text:upper()
        pcall(function()
            ToggleKey = Enum.KeyCode[inputName]
            keybindBox.Text = ToggleKey.Name
        end)
    end)

    local ThemeLabel = Instance.new("TextLabel")
    ThemeLabel.Size = UDim2.new(1, 0, 0, 20)
    ThemeLabel.Position = UDim2.new(0, 0, 0, 68)
    ThemeLabel.Text = "Select Theme Style:"
    ThemeLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    ThemeLabel.Font = Enum.Font.GothamBold
    ThemeLabel.TextSize = 13
    ThemeLabel.BackgroundTransparency = 1
    ThemeLabel.TextXAlignment = Enum.TextXAlignment.Left
    ThemeLabel.Parent = settingsFrame

    local function makeTheme(name, background, panel, surface, accent, controlOn, danger)
        return {
            name = name,
            background = background,
            panel = panel,
            surface = surface,
            input = surface,
            accent = accent,
            controlOn = controlOn,
            danger = danger,
            text = Color3.fromRGB(245, 245, 250),
            muted = Color3.fromRGB(185, 190, 205),
            stroke = Color3.fromRGB(100, 105, 125),
        }
    end

    local Themes = {
        makeTheme("Default Dark", Color3.fromRGB(20, 21, 26), Color3.fromRGB(28, 29, 38), Color3.fromRGB(32, 32, 42), Color3.fromRGB(60, 140, 220), Color3.fromRGB(45, 140, 75), Color3.fromRGB(200, 50, 50)),
        makeTheme("Ocean", Color3.fromRGB(10, 30, 45), Color3.fromRGB(15, 49, 68), Color3.fromRGB(20, 65, 86), Color3.fromRGB(35, 170, 210), Color3.fromRGB(35, 145, 105), Color3.fromRGB(210, 70, 80)),
        makeTheme("Cobalt", Color3.fromRGB(13, 22, 50), Color3.fromRGB(20, 34, 75), Color3.fromRGB(27, 48, 98), Color3.fromRGB(75, 135, 255), Color3.fromRGB(50, 165, 115), Color3.fromRGB(220, 75, 90)),
        makeTheme("Forest", Color3.fromRGB(17, 35, 27), Color3.fromRGB(25, 55, 38), Color3.fromRGB(31, 72, 47), Color3.fromRGB(85, 185, 110), Color3.fromRGB(45, 150, 85), Color3.fromRGB(200, 75, 65)),
        makeTheme("Emerald", Color3.fromRGB(9, 38, 35), Color3.fromRGB(14, 62, 54), Color3.fromRGB(20, 82, 69), Color3.fromRGB(35, 205, 155), Color3.fromRGB(45, 160, 100), Color3.fromRGB(220, 75, 100)),
        makeTheme("Sunset", Color3.fromRGB(49, 24, 27), Color3.fromRGB(76, 36, 34), Color3.fromRGB(101, 47, 39), Color3.fromRGB(245, 135, 65), Color3.fromRGB(55, 155, 100), Color3.fromRGB(220, 65, 70)),
        makeTheme("Amber", Color3.fromRGB(46, 34, 14), Color3.fromRGB(76, 55, 20), Color3.fromRGB(98, 70, 24), Color3.fromRGB(245, 180, 55), Color3.fromRGB(55, 155, 90), Color3.fromRGB(215, 65, 55)),
        makeTheme("Rose", Color3.fromRGB(48, 20, 36), Color3.fromRGB(75, 30, 55), Color3.fromRGB(100, 38, 70), Color3.fromRGB(235, 95, 165), Color3.fromRGB(55, 155, 110), Color3.fromRGB(210, 55, 85)),
        makeTheme("Berry", Color3.fromRGB(36, 17, 45), Color3.fromRGB(60, 27, 72), Color3.fromRGB(79, 34, 92), Color3.fromRGB(190, 105, 240), Color3.fromRGB(55, 155, 115), Color3.fromRGB(220, 65, 90)),
        makeTheme("Lavender", Color3.fromRGB(31, 25, 48), Color3.fromRGB(52, 42, 76), Color3.fromRGB(69, 55, 96), Color3.fromRGB(165, 135, 255), Color3.fromRGB(60, 155, 120), Color3.fromRGB(215, 70, 95)),
        makeTheme("Slate", Color3.fromRGB(25, 30, 37), Color3.fromRGB(39, 47, 57), Color3.fromRGB(51, 61, 73), Color3.fromRGB(120, 175, 225), Color3.fromRGB(55, 150, 115), Color3.fromRGB(210, 75, 80)),
        makeTheme("Copper", Color3.fromRGB(43, 29, 23), Color3.fromRGB(70, 44, 31), Color3.fromRGB(91, 56, 37), Color3.fromRGB(220, 125, 70), Color3.fromRGB(55, 150, 95), Color3.fromRGB(210, 65, 55)),
        makeTheme("Arctic", Color3.fromRGB(20, 35, 42), Color3.fromRGB(31, 55, 65), Color3.fromRGB(42, 73, 84), Color3.fromRGB(100, 210, 235), Color3.fromRGB(50, 160, 135), Color3.fromRGB(220, 85, 100)),
        makeTheme("Lime", Color3.fromRGB(25, 39, 18), Color3.fromRGB(43, 65, 24), Color3.fromRGB(57, 82, 28), Color3.fromRGB(165, 220, 65), Color3.fromRGB(55, 155, 85), Color3.fromRGB(215, 70, 60)),
        makeTheme("Plum", Color3.fromRGB(39, 20, 38), Color3.fromRGB(63, 31, 60), Color3.fromRGB(83, 40, 78), Color3.fromRGB(220, 105, 195), Color3.fromRGB(55, 155, 115), Color3.fromRGB(215, 65, 95)),
        makeTheme("Monochrome", Color3.fromRGB(18, 18, 20), Color3.fromRGB(35, 35, 39), Color3.fromRGB(49, 49, 55), Color3.fromRGB(205, 205, 215), Color3.fromRGB(75, 155, 105), Color3.fromRGB(205, 70, 75)),
    }

    local themeButtons = {}
    local function applyTheme(theme)
        activeTheme = theme
        autoHatchMain.BackgroundColor3 = theme.background

        for _, object in ipairs(autoHatchMain:GetDescendants()) do
            if not object:GetAttribute("ThemeButton") then
                if object:IsA("TextButton") then
                    object.BackgroundColor3 = object.Parent == tabBar and theme.surface or theme.surface
                    object.TextColor3 = theme.text
                elseif object:IsA("TextBox") then
                    object.BackgroundColor3 = theme.input
                    object.TextColor3 = theme.text
                elseif object:IsA("TextLabel") and not object:GetAttribute("RareTextColor") then
                    object.TextColor3 = theme.text
                elseif object:IsA("ScrollingFrame") then
                    object.BackgroundColor3 = theme.panel
                elseif object:GetAttribute("ThemeDivider") then
                    object.BackgroundColor3 = theme.stroke
                elseif object:IsA("Frame") and object.BackgroundTransparency < 1 then
                    object.BackgroundColor3 = theme.panel
                elseif object:IsA("UIStroke") then
                    object.Color = theme.stroke
                end
            end
        end

        for _, button in ipairs({hatchTab, tpTab, settingsTab, eggTab, farmTab}) do
            button.BackgroundColor3 = theme.surface
            button.TextColor3 = theme.muted
        end
        if hatchFrame.Visible then hatchTab.BackgroundColor3 = theme.accent end
        if tpFrame.Visible then tpTab.BackgroundColor3 = theme.accent end
        if settingsFrame.Visible then settingsTab.BackgroundColor3 = theme.accent end
        if eggFrame.Visible then eggTab.BackgroundColor3 = theme.accent end
        if farmFrame.Visible then farmTab.BackgroundColor3 = theme.accent end

        afkOverlay.BackgroundColor3 = theme.background
        blackFill.BackgroundColor3 = theme.background
        afkTitle.TextColor3 = theme.accent
        afkEggs.TextColor3 = theme.controlOn
        afkGems.TextColor3 = theme.accent
        afkExit.BackgroundColor3 = theme.danger
        afkExit.TextColor3 = theme.text
        afkRarePanel.BackgroundColor3 = theme.panel
        afkRareStroke.Color = theme.stroke
        afkRareTitle.TextColor3 = theme.text
    end

    local themeY = 92
    for index, theme in ipairs(Themes) do
        local column = (index - 1) % 2
        local row = math.floor((index - 1) / 2)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0.49, 0, 0, 30)
        btn.Position = UDim2.new(column == 0 and 0 or 0.51, 0, 0, themeY + row * 36)
        btn.BackgroundColor3 = theme.accent
        btn.Text = theme.name
        btn.TextColor3 = theme.text
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn:SetAttribute("ThemeButton", true)
        btn.Parent = settingsFrame

        local themeCorner = Instance.new("UICorner")
        themeCorner.CornerRadius = UDim.new(0, 6)
        themeCorner.Parent = btn

        local themeStroke = Instance.new("UIStroke")
        themeStroke.Color = theme.stroke
        themeStroke.Thickness = 1
        themeStroke.Transparency = 0.7
        themeStroke.Parent = btn

        themeButtons[index] = btn
        btn.MouseButton1Click:Connect(function()
            applyTheme(theme)
        end)
    end

    applyTheme(Themes[1])

    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if not gameProcessed and input.KeyCode == ToggleKey then
            autoHatchMain.Visible = not autoHatchMain.Visible
        end
    end)
end)
