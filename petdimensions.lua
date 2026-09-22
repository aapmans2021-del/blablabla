-- =====================================================================
-- COMBINED AUTOMATION SCRIPT: UNIFIED UI + FIXED AUTO TOKENS + BOSS DODGE
-- EGG CHANCE VIEWER + AUTO FARM & PET TRACKER + EXTENDED THEMES
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
if SavedSettings.theme then CurrentThemeName = SavedSettings.theme end
if SavedSettings.key then CurrentKeyName = SavedSettings.key end

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
local AutoFarmComet = false
local FastPetSpeed = false
local FastAttackSpeed = false
local FastPetSpeedApplied = false
local OriginalPetWalkspeedUpgrade = nil
local PetWalkspeedUpgradeWasPresent = false
local FastPetSpeedValue = 100000
local FastAttackInterval = 0.02
local TokenRemote = nil

local SaveModule = nil
pcall(function()
    SaveModule = require(ReplicatedStorage:WaitForChild("Library"):WaitForChild("Client"):WaitForChild("Save"))
end)

local function SetFastPetSpeed(enabled)
    FastPetSpeed = enabled
    if not SaveModule or not SaveModule.Get then
        return
    end

    pcall(function()
        local save = SaveModule.Get()
        if not save then return end
        save.Upgrades = save.Upgrades or {}

        if enabled then
            if not FastPetSpeedApplied then
                PetWalkspeedUpgradeWasPresent = save.Upgrades["Pet Walkspeed"] ~= nil
                OriginalPetWalkspeedUpgrade = save.Upgrades["Pet Walkspeed"]
                FastPetSpeedApplied = true
            end
            save.Upgrades["Pet Walkspeed"] = FastPetSpeedValue
        else
            if FastPetSpeedApplied then
                if PetWalkspeedUpgradeWasPresent then
                    save.Upgrades["Pet Walkspeed"] = OriginalPetWalkspeedUpgrade
                else
                    save.Upgrades["Pet Walkspeed"] = nil
                end
                FastPetSpeedApplied = false
            end
        end
    end)
end

task.spawn(function()
    while true do
        if FastPetSpeed then
            SetFastPetSpeed(true)
        end
        task.wait(0.5)
    end
end)


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
        pcall(function()
            Library.Network.Invoke("Join Coin", coinId, myPets)
        end)

        for _, petUid in ipairs(myPets) do
            pcall(function()
                Library.Network.Fire("Change Pet Target", petUid, "Coin", coinId)
            end)
        end
    end
end

local function IsCometCoin(coinInstance)
    if not coinInstance or not coinInstance.Parent then
        return false
    end

    local coinPart = coinInstance:FindFirstChild("Coin")
    local isComet = coinInstance:GetAttribute("Comet") == true
        or (coinPart and coinPart:GetAttribute("Comet") == true)

    if not isComet then
        return false
    end

    local area = coinInstance:GetAttribute("Area")
    if area ~= nil then
        local ok, available = pcall(function()
            return Library.WorldCmds.HasArea(area)
        end)
        if not ok or not available then
            return false
        end
    end

    if coinPart and coinPart:GetAttribute("PreventClick") then
        return false
    end

    return coinInstance:GetAttribute("ID") ~= nil
end

local function FindCurrentComet()
    local things = Workspace:FindFirstChild("__THINGS")
    local coins = things and things:FindFirstChild("Coins")
    if not coins then
        return nil
    end

    for _, coin in ipairs(coins:GetChildren()) do
        if IsCometCoin(coin) then
            return coin
        end
    end

    return nil
end

local function FocusCometFast(comet)
    if not IsCometCoin(comet) then
        return false
    end

    local cometId = comet:GetAttribute("ID")
    local pets = GetAllEquippedPetUIDs()
    if not cometId or #pets == 0 then
        return false
    end

    pcall(function()
        Library.Signal.Fire("Select Coin", comet)
    end)

    pcall(function()
        Library.Network.Invoke("Join Coin", cometId, pets)
    end)

    for _, petUid in ipairs(pets) do
        pcall(function()
            Library.Network.Fire("Change Pet Target", petUid, "Coin", cometId)
        end)
    end

    return true
end


-- ABILITY TOKEN COLLECTION
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
        task.wait(0.2)
    end
end)

-- AUTUMN BOSS FX DODGE DETECTION
task.spawn(function()
    while true do
        task.wait(0.1)
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

local CurrentComet = nil
local CurrentCometId = nil

task.spawn(function()
    while true do
        if AutoFarmComet then
            local comet = CurrentComet
            if not IsCometCoin(comet) then
                comet = FindCurrentComet()
                CurrentComet = comet
                CurrentCometId = comet and tostring(comet:GetAttribute("ID")) or nil
            end

            if comet and IsCometCoin(comet) then
                if CurrentCometId ~= tostring(comet:GetAttribute("ID")) then
                    CurrentCometId = tostring(comet:GetAttribute("ID"))
                end
                FocusCometFast(comet)
            else
                CurrentComet = nil
                CurrentCometId = nil
            end
        else
            CurrentComet = nil
            CurrentCometId = nil
        end

        task.wait(0.05)
    end
end)

task.spawn(function()
    while true do
        if AutoFarmComet and CurrentCometId then
            pcall(function()
                if DamageRemote then
                    DamageRemote:FireServer(CurrentCometId)
                end
            end)

            local pets = GetAllEquippedPetUIDs()
            for _, petUid in ipairs(pets) do
                pcall(function()
                    Library.Network.Fire("Farm Coin", CurrentCometId, petUid)
                end)
            end
        end
        task.wait(0.05)
    end
end)

-- Fast attack loop
task.spawn(function()
    while true do
        if FastAttackSpeed then
            local targetId = nil
            if AutoFarmComet then
                targetId = CurrentCometId
            elseif AutoFarmRobot or AutoFarmTurkey then
                targetId = CurrentTargetId
            end

            if targetId then
                if DamageRemote then
                    pcall(function()
                        DamageRemote:FireServer(targetId)
                    end)
                end

                local pets = GetAllEquippedPetUIDs()
                for _, petUid in ipairs(pets) do
                    pcall(function()
                        Library.Network.Fire("Farm Coin", targetId, petUid)
                    end)
                end
            end
        end
        task.wait(FastAttackInterval)
    end
end)

-- Main Auto Farm Loop
task.spawn(function()
    while true do
        task.wait(0.15)
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
        task.wait(0.05)
        if CurrentTargetId and DamageRemote and (AutoFarmRobot or AutoFarmTurkey) then
            pcall(function()
                DamageRemote:FireServer(CurrentTargetId)
            end)
        end
    end
end)

-- Potato Mode Continuous Focus Loop
task.spawn(function()
    while true do
        task.wait(0.1)
        if PotatoMode and (AutoFarmRobot or AutoFarmTurkey) and CurrentTarget and CurrentTarget.Parent then
            FocusPetsContinuous(CurrentTarget)
        end
    end
end)


-- =====================================================================
-- EGG OPEN ANIMATION DISABLED COMPLETELY
-- The game's hatch result/network flow is left alone. We only suppress the
-- client-side PlayTrigger used by EggOpenAnim so eggs never play their
-- opening animation/effects.
-- =====================================================================
local function cleanupEggOpeningEffects()
    pcall(function()
        local camera = Workspace.CurrentCamera
        if camera then
            local animatedEggs = camera:FindFirstChild("EggOpenAnim_Eggs")
            if animatedEggs then animatedEggs:Destroy() end
        end
        local dof = Lighting:FindFirstChild("EggOpenDOF")
        if dof then dof:Destroy() end
    end)
end

-- EggOpenHook ultimately calls EggOpenPort.PlayTrigger:Fire(...) to start
-- the visual egg-opening sequence. Block only that client-side trigger.
pcall(function()
    if type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" then
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if method == "Fire" and self and self.Name == "PlayTrigger" then
                local parent = self.Parent
                if parent and parent.Name == "EggOpenPort" then
                    cleanupEggOpeningEffects()
                    return nil
                end
            end
            return oldNamecall(self, ...)
        end))
    end
end)

-- Also keep cleaning up any animation container that may have been created
-- by another client-side path.
task.spawn(function()
    while true do
        cleanupEggOpeningEffects()
        task.wait(0.1)
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

    -- =====================================================================
    -- RESPONSIVE / MOBILE UI SCALING
    -- The original UI is designed around a 620x710 hub. Instead of using a
    -- fixed 16:9 scale (which overflows on phones), scale from the actual
    -- viewport and leave a small safe margin on every side. This keeps the
    -- entire hub on-screen in portrait, landscape, tablets, laptops and
    -- ultrawide displays.
    -- =====================================================================
    local uiScale = Instance.new("UIScale")
    uiScale.Scale = 1
    uiScale.Parent = ui

    local function updateUIScale()
        local camera = Workspace.CurrentCamera
        if not camera then return end

        local viewport = camera.ViewportSize
        if viewport.X <= 1 or viewport.Y <= 1 then return end

        -- Scale against the MAIN HUB, not the AFK overlay.  The AFK overlay
        -- is full-screen and has its own responsive controls below.
        -- This keeps the normal UI usable on phones instead of making it
        -- unnecessarily tiny while still guaranteeing it fits.
        local safeWidth = math.max(viewport.X - 16, 1)
        local safeHeight = math.max(viewport.Y - 16, 1)
        local DESIGN_WIDTH = 620
        local DESIGN_HEIGHT = 710
        local scaleX = safeWidth / DESIGN_WIDTH
        local scaleY = safeHeight / DESIGN_HEIGHT
        local scale = math.min(scaleX, scaleY, 1)

        -- Never let a minimum scale force the UI outside the viewport.
        uiScale.Scale = math.max(scale, 0.05)
    end

    local function hookCamera(camera)
        if not camera then return end
        updateUIScale()
        camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateUIScale)
    end

    hookCamera(Workspace.CurrentCamera)
    Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        hookCamera(Workspace.CurrentCamera)
    end)

    -- UNTOUCHED HUGES COUNTER TRACKER
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
        countText.TextSize = 16
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
        recentText.TextSize = 13
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
    local afkSessionActive = false
    local afkSessionCounts = {
        Huges = 0,
        Secrets = 0,
        Titanics = 0,
        Gargantuans = 0,
    }
    local startupCounts = {
        Huges = 0,
        Secrets = 0,
        Titanics = 0,
        Gargantuans = 0,
    }
    local recentHuges = {}
    local recentSecrets = {}
    local recentTitanics = {}
    local recentGargantuans = {}
    local hatchRareLabels = {}
    local afkRareLabels = {}
    local afkSessionLabels = {}
    local startupLabels = {}
    local hatchRecentLists = {}
    local afkRecentLists = {}
    local renderHatchRecent = function() end
    local renderAfkRecent = function() end
    local updateAfkSessionLabels = function() end
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
            label.Size = UDim2.new(1, -2, 0, 20)
            label.Font = Enum.Font.Gotham
            label.TextColor3 = color
            label.TextSize = 12
            label.TextWrapped = true
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

                            -- Only count newly discovered rare pets while AFK mode is active.
                            startupCounts[category .. "s"] = (startupCounts[category .. "s"] or 0) + 1
                            if afkSessionActive then
                                afkSessionCounts[category .. "s"] = (afkSessionCounts[category .. "s"] or 0) + 1
                            end

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

        if hatchRareLabels.Huges then
            hatchRareLabels.Huges.Text = hugeLabel.Text
            hatchRareLabels.Huges.TextColor3 = Color3.fromRGB(120, 205, 255)
            hatchRareLabels.Huges:SetAttribute("ThemeLocked", true)
        end
        if hatchRareLabels.Secrets then
            hatchRareLabels.Secrets.Text = secretLabel.Text
            hatchRareLabels.Secrets.TextColor3 = Color3.fromRGB(95, 45, 150)
            hatchRareLabels.Secrets:SetAttribute("ThemeLocked", true)
        end
        if hatchRareLabels.Titanics then
            hatchRareLabels.Titanics.Text = titanicLabel.Text
            hatchRareLabels.Titanics.TextColor3 = Color3.fromRGB(255, 200, 60)
            hatchRareLabels.Titanics:SetAttribute("ThemeLocked", true)
        end
        if hatchRareLabels.Gargantuans then
            hatchRareLabels.Gargantuans.Text = gargantuanLabel.Text
            hatchRareLabels.Gargantuans.TextColor3 = Color3.fromRGB(150, 35, 35)
            hatchRareLabels.Gargantuans:SetAttribute("ThemeLocked", true)
        end
        if afkRareLabels.Huges then afkRareLabels.Huges.Text = hugeLabel.Text end
        if afkRareLabels.Secrets then afkRareLabels.Secrets.Text = secretLabel.Text end
        if afkRareLabels.Titanics then afkRareLabels.Titanics.Text = titanicLabel.Text end
        if afkSessionActive then
            updateAfkSessionLabels()
        end

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
            task.wait(2)
        end
    end)

    -- AFK OVERLAY
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
    afkCenter.Size = UDim2.new(0.94, 0, 0.90, 0)
    afkCenter.AnchorPoint = Vector2.new(0.5, 0.5)
    afkCenter.Position = UDim2.new(0.5, 0, 0.46, 0)
    afkCenter.BackgroundTransparency = 1
    afkCenter.ZIndex = 102
    afkCenter.Parent = afkOverlay

    local afkTitle = Instance.new("TextLabel")
    afkTitle.Size = UDim2.new(1, 0, 0, 70)
    afkTitle.Text = "AFK MODE ACTIVE"
    afkTitle.TextColor3 = Color3.fromRGB(255, 90, 90)
    afkTitle.Font = Enum.Font.GothamBlack
    afkTitle.TextSize = 64
    afkTitle.TextScaled = true
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
    afkEggs.TextScaled = true
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
    afkGems.TextScaled = true
    afkGems.BackgroundTransparency = 1
    afkGems.TextXAlignment = Enum.TextXAlignment.Center
    afkGems.ZIndex = 102
    afkGems.Parent = afkCenter

    local afkExit = Instance.new("TextButton")
    -- This button is anchored to the actual screen, not the old 950x780
    -- design canvas, so it is ALWAYS reachable on a phone.
    afkExit.Size = UDim2.new(0.72, 0, 0, 64)
    afkExit.AnchorPoint = Vector2.new(0.5, 1)
    afkExit.Position = UDim2.new(0.5, 0, 0.96, 0)
    afkExit.Text = "Turn Off AFK Mode"
    afkExit.TextColor3 = Color3.fromRGB(255, 255, 255)
    afkExit.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
    afkExit.Font = Enum.Font.GothamSemibold
    afkExit.TextSize = 32
    afkExit.TextScaled = true
    afkExit.ZIndex = 102
    afkExit.Parent = afkCenter

    local afkExitCorner = Instance.new("UICorner")
    afkExitCorner.CornerRadius = UDim.new(0, 12)
    afkExitCorner.Parent = afkExit

    -- MAIN HUB WINDOW
    local autoHatchMain = Instance.new("Frame")
    autoHatchMain.Name = "AutoHatchMain"
    autoHatchMain.Size = UDim2.new(0, 620, 0, 710)
    autoHatchMain.Position = UDim2.new(0.5, -310, 0.5, -355)
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
    autoHatchShadow.Color = Color3.fromRGB(60, 140, 220)
    autoHatchShadow.Thickness = 1.8
    autoHatchShadow.Transparency = 0.4
    autoHatchShadow.Parent = autoHatchMain

    local autoTitle = Instance.new("TextLabel")
    autoTitle.Size = UDim2.new(1, -24, 0, 36)
    autoTitle.Position = UDim2.new(0, 12, 0, 8)
    autoTitle.Text = "Pet Dimensions Hub"
    autoTitle.TextColor3 = Color3.fromRGB(60, 140, 220)
    autoTitle.Font = Enum.Font.GothamBold
    autoTitle.TextSize = 18
    autoTitle.BackgroundTransparency = 1
    autoTitle.TextXAlignment = Enum.TextXAlignment.Left
    autoTitle.Parent = autoHatchMain

    local tabBar = Instance.new("Frame")
    tabBar.Name = "TabContainer"
    tabBar.Size = UDim2.new(1, -24, 0, 36)
    tabBar.Position = UDim2.new(0, 12, 0, 48)
    tabBar.BackgroundTransparency = 1
    tabBar.Parent = autoHatchMain

    local function createTabButton(text, position)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0.192, 0, 1, 0)
        btn.Position = UDim2.new(position, 0, 0, 0)
        btn.Text = text
        btn.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
        btn.TextColor3 = Color3.fromRGB(180, 180, 190)
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

    local hatchTab = createTabButton("Stats", 0)
    local tpTab = createTabButton("Teleport", 0.202)
    local settingsTab = createTabButton("Settings", 0.404)
    local eggTab = createTabButton("Egg Chances", 0.606)
    local farmTab = createTabButton("Farm", 0.808)

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

    -- =====================================================================
    -- FULL EXTENDED THEMES SYSTEM
    -- =====================================================================
    local function makeTheme(name, background, panel, surface, accent, controlOn, danger, text, muted, stroke)
        return {
            name = name,
            background = background or Color3.fromRGB(20, 21, 26),
            panel = panel or Color3.fromRGB(28, 29, 38),
            surface = surface or Color3.fromRGB(32, 32, 42),
            input = surface or Color3.fromRGB(30, 30, 40),
            accent = accent or Color3.fromRGB(60, 140, 220),
            controlOn = controlOn or Color3.fromRGB(45, 140, 75),
            danger = danger or Color3.fromRGB(200, 50, 50),
            text = text or Color3.fromRGB(245, 245, 250),
            muted = muted or Color3.fromRGB(180, 180, 190),
            stroke = stroke or Color3.fromRGB(80, 80, 100),
        }
    end

    local Themes = {
        makeTheme("Default Dark",    Color3.fromRGB(20, 21, 26),  Color3.fromRGB(28, 29, 38),  Color3.fromRGB(32, 32, 42),  Color3.fromRGB(60, 140, 220), Color3.fromRGB(45, 140, 75), Color3.fromRGB(200, 50, 50)),
        makeTheme("Pure Gold",       Color3.fromRGB(32, 26, 10),  Color3.fromRGB(48, 38, 14),  Color3.fromRGB(64, 52, 18),  Color3.fromRGB(255, 215, 0),  Color3.fromRGB(212, 175, 55),Color3.fromRGB(220, 60, 60), Color3.fromRGB(255, 248, 220), Color3.fromRGB(200, 180, 120), Color3.fromRGB(180, 140, 40)),
        makeTheme("Sleek Silver",    Color3.fromRGB(28, 30, 34),  Color3.fromRGB(40, 42, 48),  Color3.fromRGB(52, 55, 62),  Color3.fromRGB(192, 192, 200),Color3.fromRGB(120, 180, 140),Color3.fromRGB(210, 70, 70), Color3.fromRGB(245, 245, 250), Color3.fromRGB(170, 175, 185), Color3.fromRGB(130, 135, 145)),
        makeTheme("Platinum Shine",  Color3.fromRGB(30, 32, 38),  Color3.fromRGB(46, 50, 58),  Color3.fromRGB(62, 68, 78),  Color3.fromRGB(225, 230, 240),Color3.fromRGB(90, 180, 150), Color3.fromRGB(220, 70, 80)),
        makeTheme("Bronze & Copper", Color3.fromRGB(32, 20, 14),  Color3.fromRGB(48, 30, 20),  Color3.fromRGB(62, 40, 26),  Color3.fromRGB(211, 123, 70), Color3.fromRGB(160, 130, 60), Color3.fromRGB(200, 60, 60)),
        makeTheme("Ocean Depth",     Color3.fromRGB(10, 30, 45),  Color3.fromRGB(15, 49, 68),  Color3.fromRGB(20, 65, 86),  Color3.fromRGB(35, 170, 210), Color3.fromRGB(35, 145, 105), Color3.fromRGB(210, 70, 80)),
        makeTheme("Cobalt Blue",     Color3.fromRGB(13, 22, 50),  Color3.fromRGB(20, 34, 75),  Color3.fromRGB(27, 48, 98),  Color3.fromRGB(75, 135, 255), Color3.fromRGB(50, 165, 115), Color3.fromRGB(220, 75, 90)),
        makeTheme("Forest Canopy",   Color3.fromRGB(17, 35, 27),  Color3.fromRGB(25, 55, 38),  Color3.fromRGB(31, 72, 47),  Color3.fromRGB(85, 185, 110), Color3.fromRGB(45, 150, 85),  Color3.fromRGB(200, 75, 65)),
        makeTheme("Emerald Gem",     Color3.fromRGB(9, 38, 35),   Color3.fromRGB(14, 62, 54),  Color3.fromRGB(20, 82, 69),  Color3.fromRGB(35, 205, 155), Color3.fromRGB(45, 160, 100), Color3.fromRGB(220, 75, 100)),
        makeTheme("Sunset Blaze",    Color3.fromRGB(49, 24, 27),  Color3.fromRGB(76, 36, 34),  Color3.fromRGB(101, 47, 39), Color3.fromRGB(245, 135, 65), Color3.fromRGB(55, 155, 100), Color3.fromRGB(220, 65, 70)),
        makeTheme("Amber Glow",      Color3.fromRGB(46, 34, 14),  Color3.fromRGB(76, 55, 20),  Color3.fromRGB(98, 70, 24),  Color3.fromRGB(245, 180, 55), Color3.fromRGB(55, 155, 90),  Color3.fromRGB(215, 65, 55)),
        makeTheme("Velvet Rose",     Color3.fromRGB(48, 20, 36),  Color3.fromRGB(75, 30, 55),  Color3.fromRGB(100, 38, 72), Color3.fromRGB(245, 95, 150), Color3.fromRGB(60, 160, 110), Color3.fromRGB(230, 60, 80)),
        makeTheme("Amethyst Dreams", Color3.fromRGB(30, 18, 48),  Color3.fromRGB(50, 28, 78),  Color3.fromRGB(68, 38, 105), Color3.fromRGB(175, 90, 255), Color3.fromRGB(55, 160, 120), Color3.fromRGB(225, 60, 90)),
        makeTheme("Midnight Void",   Color3.fromRGB(10, 10, 14),  Color3.fromRGB(18, 18, 24),  Color3.fromRGB(26, 26, 36),  Color3.fromRGB(140, 150, 175),Color3.fromRGB(45, 140, 90),  Color3.fromRGB(210, 55, 65)),
        makeTheme("Cyberpunk 2077",  Color3.fromRGB(22, 12, 38),  Color3.fromRGB(38, 18, 62),  Color3.fromRGB(56, 24, 88),  Color3.fromRGB(255, 220, 30), Color3.fromRGB(0, 230, 180),  Color3.fromRGB(255, 40, 110)),
        makeTheme("Neon Mint",      Color3.fromRGB(15, 25, 25),  Color3.fromRGB(22, 40, 40),  Color3.fromRGB(30, 55, 55),  Color3.fromRGB(40, 245, 180), Color3.fromRGB(35, 185, 130), Color3.fromRGB(240, 70, 90)),
        makeTheme("Crimson Ruby",   Color3.fromRGB(35, 10, 15),  Color3.fromRGB(58, 15, 24),  Color3.fromRGB(82, 20, 33),  Color3.fromRGB(255, 45, 75),  Color3.fromRGB(50, 160, 95),  Color3.fromRGB(200, 30, 45)),
        makeTheme("Dracula Dark",    Color3.fromRGB(24, 25, 38),  Color3.fromRGB(33, 34, 52),  Color3.fromRGB(44, 45, 68),  Color3.fromRGB(189, 147, 249),Color3.fromRGB(80, 250, 123),Color3.fromRGB(255, 85, 85)),
        makeTheme("Nordic Frost",   Color3.fromRGB(23, 27, 36),  Color3.fromRGB(32, 38, 50),  Color3.fromRGB(43, 51, 68),  Color3.fromRGB(136, 192, 208),Color3.fromRGB(163, 190, 140),Color3.fromRGB(191, 97, 106)),
        makeTheme("Monokai Pro",    Color3.fromRGB(28, 29, 23),  Color3.fromRGB(40, 41, 33),  Color3.fromRGB(54, 55, 44),  Color3.fromRGB(255, 216, 102),Color3.fromRGB(166, 226, 46), Color3.fromRGB(255, 97, 136)),
        makeTheme("Tokyo Night",    Color3.fromRGB(26, 27, 38),  Color3.fromRGB(36, 37, 52),  Color3.fromRGB(48, 50, 70),  Color3.fromRGB(122, 162, 247),Color3.fromRGB(158, 206, 106),Color3.fromRGB(247, 118, 142)),
        makeTheme("Catppuccin Mocha",Color3.fromRGB(30, 30, 46), Color3.fromRGB(45, 45, 67),  Color3.fromRGB(58, 58, 80),  Color3.fromRGB(203, 166, 247),Color3.fromRGB(166, 227, 161),Color3.fromRGB(243, 139, 168)),
        makeTheme("Rose Pine",      Color3.fromRGB(25, 23, 36),  Color3.fromRGB(38, 35, 53),  Color3.fromRGB(52, 47, 71),  Color3.fromRGB(235, 188, 186),Color3.fromRGB(49, 116, 143), Color3.fromRGB(235, 111, 146)),
        makeTheme("Synthwave '84",   Color3.fromRGB(36, 27, 47),  Color3.fromRGB(52, 38, 68),  Color3.fromRGB(70, 50, 90),  Color3.fromRGB(255, 126, 219),Color3.fromRGB(0, 242, 254),   Color3.fromRGB(255, 56, 100)),
        makeTheme("Solarized Dark",  Color3.fromRGB(7, 54, 66),   Color3.fromRGB(0, 43, 54),   Color3.fromRGB(10, 65, 78),  Color3.fromRGB(181, 137, 0),  Color3.fromRGB(133, 153, 0), Color3.fromRGB(220, 50, 47)),
        makeTheme("Aurora Borealis", Color3.fromRGB(8, 28, 35),   Color3.fromRGB(12, 48, 52),  Color3.fromRGB(18, 68, 68),  Color3.fromRGB(65, 245, 190), Color3.fromRGB(120, 230, 110), Color3.fromRGB(255, 85, 125)),
        makeTheme("Electric Violet", Color3.fromRGB(23, 10, 42),  Color3.fromRGB(39, 16, 70),  Color3.fromRGB(58, 22, 96),  Color3.fromRGB(205, 70, 255), Color3.fromRGB(75, 230, 170), Color3.fromRGB(255, 65, 110)),
        makeTheme("Toxic Lime",      Color3.fromRGB(15, 28, 10),  Color3.fromRGB(25, 48, 14),  Color3.fromRGB(37, 68, 18),  Color3.fromRGB(170, 255, 45), Color3.fromRGB(75, 220, 105), Color3.fromRGB(255, 70, 75)),
        makeTheme("Galaxy",          Color3.fromRGB(15, 12, 35),  Color3.fromRGB(27, 20, 58),  Color3.fromRGB(42, 29, 82),  Color3.fromRGB(115, 95, 255), Color3.fromRGB(55, 220, 175), Color3.fromRGB(255, 75, 150)),
        makeTheme("Icefire",         Color3.fromRGB(12, 24, 38),  Color3.fromRGB(20, 42, 62),  Color3.fromRGB(28, 62, 86),  Color3.fromRGB(85, 220, 255), Color3.fromRGB(65, 205, 145), Color3.fromRGB(255, 90, 80)),
        makeTheme("Volcanic",        Color3.fromRGB(38, 12, 8),   Color3.fromRGB(65, 20, 10),  Color3.fromRGB(92, 30, 12),  Color3.fromRGB(255, 100, 35), Color3.fromRGB(255, 190, 45), Color3.fromRGB(255, 50, 60)),
        makeTheme("Candy Dream",      Color3.fromRGB(42, 18, 42),  Color3.fromRGB(68, 27, 65),  Color3.fromRGB(92, 36, 88),  Color3.fromRGB(255, 120, 205),Color3.fromRGB(100, 235, 185),Color3.fromRGB(255, 90, 120)),
        makeTheme("Matrix Green",     Color3.fromRGB(5, 20, 10),   Color3.fromRGB(8, 35, 17),   Color3.fromRGB(12, 52, 24),  Color3.fromRGB(45, 255, 95), Color3.fromRGB(80, 220, 110), Color3.fromRGB(255, 70, 70)),
        makeTheme("Arctic Aurora",    Color3.fromRGB(15, 30, 42),  Color3.fromRGB(24, 48, 62),  Color3.fromRGB(34, 68, 82),  Color3.fromRGB(90, 230, 210), Color3.fromRGB(120, 220, 150),Color3.fromRGB(240, 90, 110)),
        makeTheme("Deep Space",       Color3.fromRGB(8, 9, 20),    Color3.fromRGB(16, 17, 35),  Color3.fromRGB(25, 27, 52),  Color3.fromRGB(90, 125, 255), Color3.fromRGB(60, 210, 170), Color3.fromRGB(255, 70, 130)),
    }

    -- Always build the UI from the original Default Dark colors first.
    -- The saved/selected theme is applied only after the UI is fully created.
    -- This prevents non-themed UI elements from inheriting the last theme
    -- (for example amber colors from Amber Glow) at launch.
    local savedThemeName = CurrentThemeName
    local activeTheme = Themes[1]

    local currentTabBtn = hatchTab
    local currentTabFrame = hatchFrame

    -- Theme-aware color memory. Each UI object keeps its original/base color so
    -- switching themes never compounds the previous theme's colors.
    local themeBaseColors = setmetatable({}, { __mode = "k" })
    local THEME_LOCKED = "ThemeLocked"

    local function rememberBaseColors(obj)
        if not obj or themeBaseColors[obj] then return themeBaseColors[obj] end
        local data = {}
        pcall(function()
            if obj:IsA("GuiObject") and obj.BackgroundTransparency < 1 then
                data.background = obj.BackgroundColor3
            end
            if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                data.text = obj.TextColor3
            end
            if obj:IsA("UIStroke") then
                data.stroke = obj.Color
            end
            if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
                data.image = obj.ImageColor3
            end
        end)
        themeBaseColors[obj] = data
        return data
    end

    local function themeAdaptColor(original, kind)
        local r, g, b = original.R, original.G, original.B
        local maxc = math.max(r, g, b)
        local minc = math.min(r, g, b)
        local bright = (r + g + b) / 3

        if kind == "stroke" then
            return activeTheme.stroke
        end

        if kind == "text" then
            if minc > 0.82 then
                return activeTheme.text
            elseif maxc - minc < 0.10 then
                return activeTheme.muted
            elseif r > g * 1.35 and r > b * 1.35 then
                return activeTheme.danger
            elseif g > r * 1.30 and g > b * 1.15 then
                return activeTheme.controlOn
            end
            return activeTheme.accent
        end

        if kind == "background" then
            if r > g * 1.45 and r > b * 1.45 and r > 0.45 then
                return activeTheme.danger
            elseif g > r * 1.35 and g > b * 1.15 and g > 0.35 then
                return activeTheme.controlOn
            elseif bright < 0.16 then
                return activeTheme.background
            elseif bright < 0.30 then
                return activeTheme.panel
            else
                return activeTheme.surface
            end
        end

        return original
    end

    local function applyThemeToObject(obj)
        if not obj or not obj.Parent then return end
        if obj:GetAttribute("ThemePreview") or obj:GetAttribute(THEME_LOCKED) then return end

        -- Themes only recolor actual/full button boxes. Text, search fields,
        -- thin divider/line frames, labels, and strokes keep their original colors.
        if obj:IsA("TextButton") then
            local base = rememberBaseColors(obj)
            if base.background and obj.BackgroundTransparency < 1 then
                obj.BackgroundColor3 = themeAdaptColor(base.background, "background")
            end
        end
    end

    local function applyThemeToUI(root)
        if not root then return end
        applyThemeToObject(root)
        for _, obj in ipairs(root:GetDescendants()) do
            applyThemeToObject(obj)
        end
    end

    local function applyTheme(themeObj)
        activeTheme = themeObj
        CurrentThemeName = themeObj.name
        saveSettings()

        applyThemeToUI(autoHatchMain)

        autoHatchMain.BackgroundColor3 = activeTheme.background
        autoHatchShadow.Color = activeTheme.accent
        autoTitle.TextColor3 = Color3.fromRGB(60, 140, 220)

        for _, btn in ipairs({hatchTab, tpTab, settingsTab, eggTab, farmTab}) do
            if btn == currentTabBtn then
                btn.BackgroundColor3 = activeTheme.accent
                btn.TextColor3 = Color3.fromRGB(255, 255, 255)
            else
                btn.BackgroundColor3 = activeTheme.surface
                btn.TextColor3 = Color3.fromRGB(180, 180, 190)
            end
        end
    end

    -- Instantly theme newly-created UI too. This fixes controls that previously
    -- needed a click/repaint before their new colors became visible.
    ui.DescendantAdded:Connect(function(obj)
        task.defer(function()
            if obj and obj.Parent then
                applyThemeToObject(obj)
            end
        end)
    end)


    local function switchTab(activeBtn, activeFrame)
        hatchFrame.Visible = false
        tpFrame.Visible = false
        settingsFrame.Visible = false
        eggFrame.Visible = false
        farmFrame.Visible = false
        
        for _, btn in ipairs({hatchTab, tpTab, settingsTab, eggTab, farmTab}) do
            btn.BackgroundColor3 = activeTheme.surface
            btn.TextColor3 = Color3.fromRGB(180, 180, 190)
        end

        activeFrame.Visible = true
        activeBtn.BackgroundColor3 = activeTheme.accent
        activeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        currentTabBtn = activeBtn
        currentTabFrame = activeFrame
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
        btn.TextColor3 = defaultState and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 180, 190)
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
            btn.TextColor3 = state and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 180, 190)
        end

        btn.MouseButton1Click:Connect(function()
            local newState = not state
            updateVisuals(newState)
            callback(newState)

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
    farmTitle.Position = UDim2.new(0, 0, 0, 0)
    farmTitle.BackgroundTransparency = 1
    farmTitle.Text = "AUTO FARM CONTROLS"
    farmTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
    farmTitle.Font = Enum.Font.GothamBold
    farmTitle.TextSize = 14
    farmTitle.TextXAlignment = Enum.TextXAlignment.Left
    farmTitle.Parent = farmFrame

    createUnifiedToggle(farmFrame, 32, "🤖 Robot Farm", false, function(state) AutoFarmRobot = state end)
    createUnifiedToggle(farmFrame, 74, "🦃 Turkey/Boss Farm", false, function(state) 
        AutoFarmTurkey = state
        TurkeyDodgeActive = state
    end)
    createUnifiedToggle(farmFrame, 116, "☄️ Comet Farm", false, function(state)
        AutoFarmComet = state
        if state then
            CurrentTarget = nil
            CurrentTargetId = nil
        else
            CurrentComet = nil
            CurrentCometId = nil
        end
    end)
    createUnifiedToggle(farmFrame, 158, "⭐ Auto Tokens", false, function(state) AutoTokens = state end)
    createUnifiedToggle(farmFrame, 200, "⚡ Fast Pet Speed", false, function(state) SetFastPetSpeed(state) end)
    createUnifiedToggle(farmFrame, 242, "⚔️ Fast Attack", false, function(state) FastAttackSpeed = state end)

    local farmStatus = Instance.new("TextLabel")
    farmStatus.Size = UDim2.new(1, 0, 0, 28)
    farmStatus.Position = UDim2.new(0, 0, 0, 286)
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
            elseif AutoFarmComet and CurrentCometId then
                farmStatus.Text = "Status: ☄️ Farming Comet #" .. CurrentCometId
                farmStatus.TextColor3 = Color3.fromRGB(180, 220, 255)
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
    eggSearch.Size = UDim2.new(1, 0, 0, 32)
    eggSearch.Position = UDim2.new(0, 0, 0, 40)
    eggSearch.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
    eggSearch.Text = ""
    eggSearch.TextColor3 = Color3.fromRGB(255, 255, 255)
    eggSearch.PlaceholderText = "Search egg filter..."
    eggSearch.ClearTextOnFocus = false
    eggSearch.Font = Enum.Font.Gotham
    eggSearch.TextSize = 13
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
    eggSelect.Size = UDim2.new(1, 0, 0, 32)
    eggSelect.Position = UDim2.new(0, 0, 0, 78)
    eggSelect.BackgroundColor3 = Color3.fromRGB(35, 35, 48)
    eggSelect.TextColor3 = Color3.fromRGB(255, 255, 255)
    eggSelect.Font = Enum.Font.GothamBold
    eggSelect.TextSize = 13
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
    eggOptions.Size = UDim2.new(1, 0, 0, 140)
    eggOptions.Position = UDim2.new(0, 0, 0, 116)
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
    eggResults.Name = "EggResults"
    eggResults.Size = UDim2.new(1, 0, 1, -262)
    eggResults.Position = UDim2.new(0, 0, 0, 262)
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
        petLabel.Size = UDim2.new(0.52, -8, 1, 0)
        petLabel.Position = UDim2.new(0, 8, 0, 0)
        petLabel.BackgroundTransparency = 1
        petLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        petLabel.Font = Enum.Font.GothamBold
        petLabel.TextSize = 13
        petLabel.TextWrapped = true
        petLabel.TextXAlignment = Enum.TextXAlignment.Left
        petLabel.Text = tostring(name)
        petLabel.Parent = row

        local rarityName = category or "Normal"
        local rarityLabel = Instance.new("TextLabel")
        rarityLabel.Size = UDim2.new(0.18, -4, 1, 0)
        rarityLabel.Position = UDim2.new(0.52, 0, 0, 0)
        rarityLabel.BackgroundTransparency = 1
        rarityLabel.TextColor3 = rarityColors[rarityName] or rarityColors.Normal
        rarityLabel.Font = rarityName == "Secret" and Enum.Font.Fantasy or Enum.Font.GothamBold
        rarityLabel.TextSize = 12
        rarityLabel.Text = rarityName
        rarityLabel.TextWrapped = true
        rarityLabel.TextXAlignment = Enum.TextXAlignment.Left
        rarityLabel.Parent = row

        local chanceLabel = Instance.new("TextLabel")
        chanceLabel.Size = UDim2.new(0.30, -8, 1, 0)
        chanceLabel.Position = UDim2.new(0.70, 0, 0, 0)
        chanceLabel.BackgroundTransparency = 1
        chanceLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        chanceLabel.Font = Enum.Font.GothamBold
        chanceLabel.TextSize = 12
        chanceLabel.TextWrapped = true
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
            bestOption.Size = UDim2.new(1, -6, 0, 30)
            bestOption.BackgroundColor3 = activeTheme.accent
            bestOption.TextColor3 = Color3.fromRGB(255, 255, 255)
            bestOption.Font = Enum.Font.GothamBold
            bestOption.TextSize = 13
            bestOption.TextWrapped = true
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
                option.TextColor3 = Color3.fromRGB(255, 255, 255)
                option.Font = Enum.Font.Gotham
                option.TextSize = 12
                option.TextWrapped = true
                option.Text = "  " .. egg.Name
                option.TextXAlignment = Enum.TextXAlignment.Left
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
                            btnObj.TextColor3 = Color3.fromRGB(255, 255, 255)
                        else
                            btnObj.BackgroundColor3 = activeTheme.surface
                            btnObj.TextColor3 = Color3.fromRGB(180, 180, 190)
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

        -- Hide search and dropdown for all non-Egg tabs and reposition results frame directly below mode bar
        if mode == "Eggs" then
            eggSearch.Visible = true
            eggSelect.Visible = true
            eggOptions.Visible = true
            eggResults.Position = UDim2.new(0, 0, 0, 262)
            eggResults.Size = UDim2.new(1, 0, 1, -262)
        else
            eggSearch.Visible = false
            eggSelect.Visible = false
            eggOptions.Visible = false
            eggResults.Position = UDim2.new(0, 0, 0, 40)
            eggResults.Size = UDim2.new(1, 0, 1, -40)
        end

        for _, btn in pairs(subTabButtons) do
            btn.BackgroundColor3 = activeTheme.surface
            btn.TextColor3 = Color3.fromRGB(180, 180, 190)
        end

        targetBtn.BackgroundColor3 = activeTheme.accent
        targetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

        renderChanceResults()
    end

    local function addEggModeButton(text, position, mode)
        local button = Instance.new("TextButton")
        button.Size = UDim2.new(0.192, 0, 1, 0)
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
    addEggModeButton("Huges", 0.202, "Huge")
    addEggModeButton("Titanics", 0.404, "Titanic")
    addEggModeButton("Secrets", 0.606, "Secret")
    addEggModeButton("Gargantuans", 0.808, "Gargantuan")

    eggSelect.MouseButton1Click:Connect(function() 
        if chanceMode == "Eggs" then
            eggOptions.Visible = not eggOptions.Visible 
        end
    end)
    
    eggSearch:GetPropertyChangedSignal("Text"):Connect(function()
        rebuildEggOptions()
        eggOptions.Visible = (chanceMode == "Eggs")
    end)
    
    rebuildEggOptions()
    eggSelect.Text = bestChanceEgg and ("Selected: " .. bestChanceEgg.Name) or "Select an egg"
    selectEggSubTab("Eggs", subTabButtons["Eggs"])

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
    statsContainer.Name = "StatsContainer"
    statsContainer.Size = UDim2.new(1, 0, 0, 136)
    statsContainer.Position = UDim2.new(0, 0, 0, 0)
    statsContainer.BackgroundColor3 = Color3.fromRGB(28, 29, 38)
    statsContainer.Parent = hatchFrame

    local statsCorner = Instance.new("UICorner")
    statsCorner.CornerRadius = UDim.new(0, 6)
    statsCorner.Parent = statsContainer

    local EggsLabel = Instance.new("TextLabel")
    EggsLabel.Size = UDim2.new(1, -20, 0, 20)
    EggsLabel.Position = UDim2.new(0, 10, 0, 6)
    EggsLabel.Text = "Eggs: 0"
    EggsLabel.TextColor3 = Color3.fromRGB(80, 230, 80)
    EggsLabel.Font = Enum.Font.GothamBold
    EggsLabel.TextSize = 13
    EggsLabel.BackgroundTransparency = 1
    EggsLabel.TextXAlignment = Enum.TextXAlignment.Left
    EggsLabel.Parent = statsContainer

    local GemsLabel = Instance.new("TextLabel")
    GemsLabel.Size = UDim2.new(1, -20, 0, 20)
    GemsLabel.Position = UDim2.new(0, 10, 0, 28)
    GemsLabel.Text = "Diamonds: 0"
    GemsLabel.TextColor3 = Color3.fromRGB(110, 185, 255)
    GemsLabel.Font = Enum.Font.GothamBold
    GemsLabel.TextSize = 13
    GemsLabel.BackgroundTransparency = 1
    GemsLabel.TextXAlignment = Enum.TextXAlignment.Left
    GemsLabel.Parent = statsContainer

    -- These Stats-tab counters keep their fixed colors in every theme.
    local hatchEggsGreen = Color3.fromRGB(80, 230, 80)
    local hatchDiamondsBlue = Color3.fromRGB(110, 185, 255)
    EggsLabel.TextColor3 = hatchEggsGreen
    GemsLabel.TextColor3 = hatchDiamondsBlue
    EggsLabel:SetAttribute(THEME_LOCKED, true)
    GemsLabel:SetAttribute(THEME_LOCKED, true)

    local function makeHatchRareLabel(name, position)
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -20, 0, 20)
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

    makeHatchRareLabel("Huges", 50)
    makeHatchRareLabel("Secrets", 72)
    makeHatchRareLabel("Titanics", 94)
    makeHatchRareLabel("Gargantuans", 116)

    local ToggleKey = Enum.KeyCode[CurrentKeyName] or Enum.KeyCode.LeftControl

    updateAfkSessionLabels = function()
        local sessionLabels = {
            Huges = afkSessionLabels.Huges,
            Secrets = afkSessionLabels.Secrets,
            Titanics = afkSessionLabels.Titanics,
            Gargantuans = afkSessionLabels.Gargantuans,
        }
        local startupLabelSet = {
            Huges = startupLabels.Huges,
            Secrets = startupLabels.Secrets,
            Titanics = startupLabels.Titanics,
            Gargantuans = startupLabels.Gargantuans,
        }

        for key, label in pairs(sessionLabels) do
            if label then
                label.Text = "+" .. tostring(afkSessionCounts[key] or 0) .. " (this AFK session)"
            end
        end
        for key, label in pairs(startupLabelSet) do
            if label then
                label.Text = "+" .. tostring(startupCounts[key] or 0) .. " (since startup)"
            end
        end
    end

    local function resetAfkSessionCounts()
        afkSessionCounts.Huges = 0
        afkSessionCounts.Secrets = 0
        afkSessionCounts.Titanics = 0
        afkSessionCounts.Gargantuans = 0
        updateAfkSessionLabels()
    end

    local function setAfkMode(enabled)
        pcall(function()
            afkSessionActive = enabled
            resetAfkSessionCounts()

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

    createUnifiedToggle(hatchFrame, 144, "AFK CPU Reducer", false, function(value) setAfkMode(value) end)
    local autoHatchTip = Instance.new("TextLabel")
autoHatchTip.Size = UDim2.new(1, -20, 0, 38)
autoHatchTip.Position = UDim2.new(0, 10, 0, 184)
autoHatchTip.BackgroundTransparency = 1
autoHatchTip.Text = "Tip: Use the game's built-in Auto Hatch for automatic hatching. This script only removes egg-opening animations. Turn off Stop on failure in Hatch settings."
autoHatchTip.TextColor3 = Color3.fromRGB(180, 190, 205)
autoHatchTip.Font = Enum.Font.Gotham
autoHatchTip.TextSize = 13
autoHatchTip.TextWrapped = true
autoHatchTip.TextXAlignment = Enum.TextXAlignment.Left
autoHatchTip.Parent = hatchFrame

    local recentPanel = Instance.new("Frame")
    recentPanel.Name = "RecentHatchesPanel"
    recentPanel.Size = UDim2.new(1, -6, 0, 150)
    recentPanel.Position = UDim2.new(0, 3, 0, 230)
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
    recentTitle.Position = UDim2.new(0, 8, 0, 6)
    recentTitle.BackgroundTransparency = 1
    recentTitle.Text = "RECENT RARE HATCHES"
    recentTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
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
        column.Position = UDim2.new((index - 1) * 0.25, 3, 0, 32)
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
        header.Parent = column

        local list = Instance.new("ScrollingFrame")
        list.Size = UDim2.new(1, -4, 1, -22)
        list.Position = UDim2.new(0, 2, 0, 22)
        list.BackgroundTransparency = 1
        list.BorderSizePixel = 0
        list.ScrollBarThickness = 2
        list.CanvasSize = UDim2.new(0, 0, 0, 0)
        list.AutomaticCanvasSize = Enum.AutomaticSize.Y
        list.Parent = column

        local listLayout = Instance.new("UIListLayout")
        listLayout.SortOrder = Enum.SortOrder.LayoutOrder
        listLayout.Padding = UDim.new(0, 2)
        listLayout.Parent = list

        hatchRecentLists[category.name] = { frame = list, entries = category.entries, color = category.color }
    end

    for index = 1, 3 do
        local divider = Instance.new("Frame")
        divider.Size = UDim2.new(0, 1, 1, -42)
        divider.Position = UDim2.new(index * 0.25, 0, 0, 34)
        divider.BackgroundColor3 = activeTheme.stroke
        divider.BackgroundTransparency = 0.35
        divider.BorderSizePixel = 0
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
                    label.Size = UDim2.new(1, -2, 0, 20)
                    label.BackgroundTransparency = 1
                    label.Text = "✓ " .. tostring(entryData.name)
                    label.TextColor3 = listData.color
                    label.Font = Enum.Font.GothamMedium
                    label.TextSize = 12
                    label.TextWrapped = true
                    label.AutomaticSize = Enum.AutomaticSize.Y
                    label.TextXAlignment = Enum.TextXAlignment.Left
                    label.LayoutOrder = entryIndex
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

    -- AFK RARE PETS PANEL
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
    afkRareTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
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
        countLabel.Size = UDim2.new(1, -6, 0, 34)
        countLabel.Position = UDim2.new(0, 3, 0, 0)
        countLabel.BackgroundTransparency = 1
        countLabel.Text = category.name .. ": 0"
        countLabel.TextColor3 = category.color
        countLabel.Font = Enum.Font.GothamBold
        countLabel.TextSize = 24
        countLabel.TextXAlignment = Enum.TextXAlignment.Left
        countLabel.Parent = column
        afkRareLabels[category.name .. "s"] = countLabel

        local sessionLabel = Instance.new("TextLabel")
        sessionLabel.Size = UDim2.new(1, -6, 0, 28)
        sessionLabel.Position = UDim2.new(0, 3, 0, 32)
        sessionLabel.BackgroundTransparency = 1
        sessionLabel.Text = "+0 (this AFK session)"
        sessionLabel.TextColor3 = category.color
        sessionLabel.Font = Enum.Font.GothamBold
        sessionLabel.TextSize = 20
        sessionLabel.TextXAlignment = Enum.TextXAlignment.Left
        sessionLabel.Parent = column
        afkSessionLabels[category.name .. "s"] = sessionLabel

        local startupLabel = Instance.new("TextLabel")
        startupLabel.Size = UDim2.new(1, -6, 0, 28)
        startupLabel.Position = UDim2.new(0, 3, 0, 58)
        startupLabel.BackgroundTransparency = 1
        startupLabel.Text = "+0 (since startup)"
        startupLabel.TextColor3 = category.color
        startupLabel.Font = Enum.Font.GothamBold
        startupLabel.TextSize = 20
        startupLabel.TextXAlignment = Enum.TextXAlignment.Left
        startupLabel.Parent = column
        startupLabels[category.name .. "s"] = startupLabel

        local list = Instance.new("Frame")
        list.Size = UDim2.new(1, -6, 1, -94)
        list.Position = UDim2.new(0, 3, 0, 90)
        list.BackgroundTransparency = 1
        list.Parent = column
        afkRecentLists[category.name] = { frame = list, entries = category.entries, color = category.color }
    end

    for index = 1, 3 do
        local divider = Instance.new("Frame")
        divider.Size = UDim2.new(0, 1, 1, -100)
        divider.Position = UDim2.new(index * 0.25, 0, 0, 90)
        divider.BackgroundColor3 = activeTheme.stroke
        divider.BackgroundTransparency = 0.35
        divider.BorderSizePixel = 0
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
                    label.Parent = listData.frame
                end
            end
        end
    end

    renderAfkRecent()

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

    -- =====================================================================
    -- TELEPORT TAB UI
    -- =====================================================================
    local tpTitle = Instance.new("TextLabel")
    tpTitle.Size = UDim2.new(1, 0, 0, 24)
    tpTitle.Position = UDim2.new(0, 0, 0, 0)
    tpTitle.BackgroundTransparency = 1
    tpTitle.Text = "TELEPORT LOCATIONS"
    tpTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
    tpTitle.Font = Enum.Font.GothamBold
    tpTitle.TextSize = 14
    tpTitle.TextXAlignment = Enum.TextXAlignment.Left
    tpTitle.Parent = tpFrame

    local tpTip = Instance.new("TextLabel")
    tpTip.Size = UDim2.new(1, 0, 0, 42)
    tpTip.Position = UDim2.new(0, 0, 0, 24)
    tpTip.BackgroundTransparency = 1
    tpTip.Text = "⚠ Only teleport to the spots in the same world as you are currently in. It will glitch if you teleport to a different world."
    tpTip.TextColor3 = Color3.fromRGB(255, 190, 80)
    tpTip.Font = Enum.Font.GothamSemibold
    tpTip.TextSize = 11
    tpTip.TextWrapped = true
    tpTip.TextXAlignment = Enum.TextXAlignment.Left
    tpTip.TextYAlignment = Enum.TextYAlignment.Center
    tpTip.Parent = tpFrame

    -- Scrolling keeps the teleport list usable on smaller resolutions.
    local tpScroll = Instance.new("ScrollingFrame")
    tpScroll.Size = UDim2.new(1, 0, 1, -72)
    tpScroll.Position = UDim2.new(0, 0, 0, 72)
    tpScroll.BackgroundTransparency = 1
    tpScroll.BorderSizePixel = 0
    tpScroll.ScrollBarThickness = 5
    tpScroll.ScrollBarImageTransparency = 0.35
    tpScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    tpScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    tpScroll.ScrollingDirection = Enum.ScrollingDirection.Y
    tpScroll.Parent = tpFrame

    local tpLayout = Instance.new("UIListLayout")
    tpLayout.SortOrder = Enum.SortOrder.LayoutOrder
    tpLayout.Padding = UDim.new(0, 6)
    tpLayout.Parent = tpScroll

    local tpPadding = Instance.new("UIPadding")
    tpPadding.PaddingBottom = UDim.new(0, 8)
    tpPadding.Parent = tpScroll

    local function teleportTo(x, y, z)
        local character = localPlayer.Character
        if character and character:FindFirstChild("HumanoidRootPart") then
            character.HumanoidRootPart.CFrame = CFrame.new(x, y, z)
        end
    end

    local function createTeleportSection(parent, name)
        local section = Instance.new("TextLabel")
        section.Size = UDim2.new(1, -8, 0, 24)
        section.BackgroundTransparency = 1
        section.Text = name
        section.TextColor3 = activeTheme.accent
        section.Font = Enum.Font.GothamBold
        section.TextSize = 13
        section.TextXAlignment = Enum.TextXAlignment.Left
        section.LayoutOrder = #parent:GetChildren() + 1
        section.Parent = parent
        return section
    end

    local function createTeleportButton(parent, name, coords)
        local button = Instance.new("TextButton")
        button.Size = UDim2.new(1, -8, 0, 34)
        button.BackgroundColor3 = activeTheme.surface
        button.Text = "📍 Teleport to " .. name
        button.TextColor3 = Color3.fromRGB(255, 255, 255)
        button.Font = Enum.Font.GothamBold
        button.TextSize = 13
        button.TextScaled = false
        button.LayoutOrder = #parent:GetChildren() + 1
        button.Parent = parent

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 6)
        btnCorner.Parent = button

        local btnStroke = Instance.new("UIStroke")
        btnStroke.Color = activeTheme.stroke
        btnStroke.Thickness = 1
        btnStroke.Transparency = 0.7
        btnStroke.Parent = button

        button.MouseButton1Click:Connect(function()
            teleportTo(coords[1], coords[2], coords[3])
        end)
    end

    -- World 1
    createTeleportSection(tpScroll, "World 1")
    createTeleportButton(tpScroll, "World 1 Spawn", {267, 98, 238})
    createTeleportButton(tpScroll, "World 1 Last Area", {-3691, 142, 232})

    -- Fantasy World
    createTeleportSection(tpScroll, "Fantasy World")
    createTeleportButton(tpScroll, "Fantasy Spawn", {-7568, 558, -1683})
    createTeleportButton(tpScroll, "Moon Egg", {-7765, 639, -1247})
    createTeleportButton(tpScroll, "Crystal Chest", {-5283, 583, -2271})
    createTeleportButton(tpScroll, "Fantasy Last Area", {-4857, 558, -1679})

    -- Tech World
    createTeleportSection(tpScroll, "Tech World")
    createTeleportButton(tpScroll, "Tech Spawn", {-9977, 16, 9601})
    createTeleportButton(tpScroll, "Tech Last Area", {-7997, 16, 9609})

    -- =====================================================================
    -- SETTINGS TAB UI & EXTENDED THEME SWITCHER
    -- =====================================================================
    local settingsTitle = Instance.new("TextLabel")
    settingsTitle.Size = UDim2.new(1, 0, 0, 24)
    settingsTitle.Position = UDim2.new(0, 0, 0, 0)
    settingsTitle.BackgroundTransparency = 1
    settingsTitle.Text = "SETTINGS & KEYBINDS"
    settingsTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
    settingsTitle.Font = Enum.Font.GothamBold
    settingsTitle.TextSize = 14
    settingsTitle.TextXAlignment = Enum.TextXAlignment.Left
    settingsTitle.Parent = settingsFrame

    local keybindLabel = Instance.new("TextLabel")
    keybindLabel.Size = UDim2.new(1, 0, 0, 20)
    keybindLabel.Position = UDim2.new(0, 0, 0, 32)
    keybindLabel.BackgroundTransparency = 1
    keybindLabel.Text = "Toggle UI Keybind:"
    keybindLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    keybindLabel.Font = Enum.Font.GothamBold
    keybindLabel.TextSize = 13
    keybindLabel.TextXAlignment = Enum.TextXAlignment.Left
    keybindLabel.Parent = settingsFrame

    local keybindBtn = Instance.new("TextButton")
    keybindBtn.Size = UDim2.new(1, 0, 0, 34)
    keybindBtn.Position = UDim2.new(0, 0, 0, 56)
    keybindBtn.BackgroundColor3 = activeTheme.surface
    keybindBtn.Text = "Current Key: " .. CurrentKeyName
    keybindBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    keybindBtn.Font = Enum.Font.GothamBold
    keybindBtn.TextSize = 13
    keybindBtn.Parent = settingsFrame

    local keybindCorner = Instance.new("UICorner")
    keybindCorner.CornerRadius = UDim.new(0, 6)
    keybindCorner.Parent = keybindBtn

    local keybindStroke = Instance.new("UIStroke")
    keybindStroke.Color = activeTheme.stroke
    keybindStroke.Thickness = 1
    keybindStroke.Transparency = 0.7
    keybindStroke.Parent = keybindBtn

    -- MOBILE UI TOGGLE
    -- Phones do not have the configured keyboard key, so provide a large
    -- touch button that remains available even when the main UI is hidden.
    local mobileToggle = Instance.new("TextButton")
    mobileToggle.Name = "MobileUIToggle"
    mobileToggle.Size = UDim2.new(0, 58, 0, 58)
    mobileToggle.AnchorPoint = Vector2.new(1, 1)
    mobileToggle.Position = UDim2.new(1, -12, 1, -12)
    mobileToggle.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
    mobileToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
    mobileToggle.Text = "UI"
    mobileToggle.Font = Enum.Font.GothamBold
    mobileToggle.TextSize = 18
    mobileToggle.ZIndex = 1000
    mobileToggle.AutoButtonColor = true
    mobileToggle.Parent = ui

    local mobileToggleCorner = Instance.new("UICorner")
    mobileToggleCorner.CornerRadius = UDim.new(1, 0)
    mobileToggleCorner.Parent = mobileToggle

    local mobileToggleStroke = Instance.new("UIStroke")
    mobileToggleStroke.Thickness = 2
    mobileToggleStroke.Transparency = 0.25
    mobileToggleStroke.Parent = mobileToggle

    local function toggleMainUI()
        if afkOverlay.Visible then
            return
        end
        autoHatchMain.Visible = not autoHatchMain.Visible
        mobileToggle.Text = autoHatchMain.Visible and "UI" or "OPEN"
    end

    mobileToggle.Activated:Connect(toggleMainUI)

    -- Hide the touch button while AFK is active; the dedicated AFK exit
    -- button remains visible and reachable.
    afkOverlay:GetPropertyChangedSignal("Visible"):Connect(function()
        mobileToggle.Visible = not afkOverlay.Visible
    end)

    local listeningForKey = false
    keybindBtn.MouseButton1Click:Connect(function()
        listeningForKey = true
        keybindBtn.Text = "Press any key..."
    end)

    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if listeningForKey and input.UserInputType == Enum.UserInputType.Keyboard then
            listeningForKey = false
            CurrentKeyName = input.KeyCode.Name
            ToggleKey = input.KeyCode
            keybindBtn.Text = "Current Key: " .. CurrentKeyName
            saveSettings()
        elseif not gameProcessed and input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == ToggleKey then
            toggleMainUI()
        end
    end)

    local themeLabel = Instance.new("TextLabel")
    themeLabel.Size = UDim2.new(1, 0, 0, 20)
    themeLabel.Position = UDim2.new(0, 0, 0, 102)
    themeLabel.BackgroundTransparency = 1
    themeLabel.Text = "Select UI Theme:"
    themeLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    themeLabel.Font = Enum.Font.GothamBold
    themeLabel.TextSize = 13
    themeLabel.TextXAlignment = Enum.TextXAlignment.Left
    themeLabel.Parent = settingsFrame

    local themeScroll = Instance.new("ScrollingFrame")
    themeScroll.Size = UDim2.new(1, 0, 1, -130)
    themeScroll.Position = UDim2.new(0, 0, 0, 126)
    themeScroll.BackgroundColor3 = activeTheme.panel
    themeScroll.BorderSizePixel = 0
    themeScroll.ScrollBarThickness = 5
    themeScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    themeScroll.Parent = settingsFrame

    local themeScrollCorner = Instance.new("UICorner")
    themeScrollCorner.CornerRadius = UDim.new(0, 6)
    themeScrollCorner.Parent = themeScroll

    local themeScrollLayout = Instance.new("UIListLayout")
    themeScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
    themeScrollLayout.Padding = UDim.new(0, 4)
    themeScrollLayout.Parent = themeScroll

    for _, themeObj in ipairs(Themes) do
        local tBtn = Instance.new("TextButton")
        tBtn.Size = UDim2.new(1, -8, 0, 30)
        tBtn.BackgroundColor3 = themeObj.surface
        tBtn.Text = "  " .. themeObj.name
        tBtn.TextColor3 = themeObj.text
        tBtn.Font = Enum.Font.GothamBold
        tBtn.TextSize = 12
        tBtn.TextXAlignment = Enum.TextXAlignment.Left
        tBtn:SetAttribute("ThemePreview", true)
        tBtn.Parent = themeScroll

        local tCorner = Instance.new("UICorner")
        tCorner.CornerRadius = UDim.new(0, 4)
        tCorner.Parent = tBtn

        local tStroke = Instance.new("UIStroke")
        tStroke.Color = themeObj.accent
        tStroke.Thickness = 1
        tStroke.Transparency = 0.5
        tStroke.Parent = tBtn

        tBtn.MouseButton1Click:Connect(function()
            applyTheme(themeObj)
        end)
    end

    -- Apply the saved theme only after every UI element has been created
    -- from the Default Dark base. Non-button/detail elements therefore stay
    -- at their original dark colors instead of inheriting a previous theme.
    for _, themeObj in ipairs(Themes) do
        if themeObj.name == savedThemeName then
            applyTheme(themeObj)
            break
        end
    end
end)
