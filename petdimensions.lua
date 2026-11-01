-- =====================================================================
-- COMBINED AUTOMATION SCRIPT: UNIFIED UI + FIXED AUTO TOKENS + PET TRACKER
-- HATCH LOGIC + EGG CHANCE VIEWER + AUTO FARM & PET TRACKER
-- =====================================================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local SettingsFile = "MultiRobloxAccounts_settings.json"
local CurrentThemeName = "Default Dark"
local CurrentKeyName = "LeftControl"
local CurrentToggleStates = {}
local PersistedSettings = {
    selectedEgg = nil,
    webhook = {
        url = "",
        enabled = false,
        notify = { Huge = true, Secret = true, Titanic = true, Gargantuan = true }
    },
    -- Free-form bag for every other setting (Anti-AFK interval, ...).
    -- Anything registered through SetSetting below is written
    -- to disk on every change and read back on load, so new settings persist
    -- without touching this table or the loader.
    extra = {},
}

-- ------------------------------------------------------------------
-- Generic auto-saved settings
--
-- Registering a setting makes it load and save for free. `apply` is optional
-- and is used to push the restored value into whatever runtime variable backs
-- it (for example, AntiAFKIntervalMinutes).
-- ------------------------------------------------------------------
local SettingSinks = {}

local function SetSetting(key, value, apply)
    PersistedSettings.extra[key] = value
    if type(apply) == "function" then
        SettingSinks[key] = apply
        pcall(apply, value)
    end
end

local function GetSetting(key, default)
    local v = PersistedSettings.extra[key]
    if v == nil then return default end
    return v
end

local function ApplyAllSinks()
    for key, apply in pairs(SettingSinks) do
        local v = PersistedSettings.extra[key]
        if v ~= nil then pcall(apply, v) end
    end
end

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
if type(SavedSettings.toggles) == "table" then
    CurrentToggleStates = SavedSettings.toggles
end
if SavedSettings.selectedEgg ~= nil then
    PersistedSettings.selectedEgg = tostring(SavedSettings.selectedEgg)
end
if type(SavedSettings.extra) == "table" then
    for k, v in pairs(SavedSettings.extra) do
        PersistedSettings.extra[k] = v
    end
end
if type(SavedSettings.webhook) == "table" then
    PersistedSettings.webhook.url = tostring(SavedSettings.webhook.url or "")
    PersistedSettings.webhook.enabled = SavedSettings.webhook.enabled == true
    if type(SavedSettings.webhook.notify) == "table" then
        for _, key in ipairs({"Huge", "Secret", "Titanic", "Gargantuan"}) do
            if SavedSettings.webhook.notify[key] ~= nil then
                PersistedSettings.webhook.notify[key] = SavedSettings.webhook.notify[key] == true
            end
        end
    end
end

-- Coalesce writes: several settings often change in the same frame (a toggle
-- plus its value box), and every change used to hit the disk immediately.
local savePending = false
local function saveSettings()
    if type(writefile) ~= "function" then return end
    if savePending then return end
    savePending = true
    task.defer(function()
        savePending = false
        pcall(function()
            writefile(SettingsFile, HttpService:JSONEncode({
                version = 3,
                theme = CurrentThemeName,
                key = CurrentKeyName,
                toggles = CurrentToggleStates,
                selectedEgg = PersistedSettings.selectedEgg,
                webhook = PersistedSettings.webhook,
                extra = PersistedSettings.extra,
            }))
        end)
    end)
end

-- Auto Farm & Token Variables
local Library = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
while not Library.Loaded do
    RunService.Heartbeat:Wait()
end

local AutoFarmRobot = false
local AutoTap = false
local AutoTeleportClosestCoin = false
local AntiAFK = false
local AntiAFKIntervalMinutes = 1
local AutoFarmHackerBoss = false
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

-- Hatch state lives at the top level so every loop (including the egg-open
-- cleanup poller, which is created long before the UI thread) reads the SAME
-- variable instead of silently resolving an unrelated global.
local AutoBuying = false
local HatchWatchdogStatus = "Idle"
local HatchLastEgg = 0
local HatchCooldownUntil = 0
local HatchFailures = 0

-- Idle-aware waiting. Every automation loop in this script used to spin at its
-- full attack rate even when its feature was switched off, which burned frame
-- time for nothing. These loops now fall back to a slow tick while idle.
local function idleWait(active, fast, slow)
    task.wait(active and fast or slow)
end

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
            task.wait(0.5)
        else
            task.wait(1)
        end
    end
end)

local CurrentTarget = nil
local CurrentTargetId = nil
local LastPetSendTarget = nil
local CurrentCoinTarget = nil
local CurrentCoinTargetId = nil
local CurrentHackerBoss = nil
local CurrentHackerBossId = nil
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

-- Every attack loop used to rebuild this list from Library.PetCmds.GetEquipped()
-- on each hit, which walks the equipped table at 20-50 Hz. It is cached and
-- refreshed on a timer; changes to equipped pets invalidate it immediately.
local CachedEquippedPets = {}
local CachedPetsRefreshAt = 0
local CachedPetsInterval = 0.5

local function RefreshCachedEquippedPets(force)
    local now = os.clock()
    if not force and now < CachedPetsRefreshAt then
        return CachedEquippedPets
    end

    local pets = {}
    pcall(function()
        pets = GetAllEquippedPetUIDs()
    end)

    CachedEquippedPets = pets or {}
    CachedPetsRefreshAt = now + CachedPetsInterval
    return CachedEquippedPets
end

local function GetCoinRootFromInstance(instance)
    if not instance then return nil end
    local current = instance
    while current and current.Parent do
        if current:GetAttribute("ID") ~= nil then
            return current
        end
        current = current.Parent
    end
    return nil
end

local function GetCoinPosition(coin)
    if not coin then return nil end

    local coinPart = coin:FindFirstChild("Coin", true)
    if coinPart and coinPart:IsA("BasePart") then
        return coinPart.Position
    end

    if coin:IsA("BasePart") then
        return coin.Position
    end

    local ok, pivot = pcall(function() return coin:GetPivot() end)
    if ok and pivot then
        return pivot.Position
    end

    local part = coin:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

-- =====================================================================
-- GENERIC CLOSEST-COIN TARGETING
-- Finds any rendered coin under Workspace.__THINGS.Coins, regardless of
-- coin type. The closest living coin to the player becomes the target.
-- =====================================================================
local function FindClosestCoin(previous)
    local things = Workspace:FindFirstChild("__THINGS")
    local coinsFolder = things and things:FindFirstChild("Coins")
    if not coinsFolder then return nil end

    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end

    local closest, closestDistance = nil, math.huge
    local checked = {}

    -- Normal coins are direct children of __THINGS.Coins, just like the
    for _, coin in ipairs(coinsFolder:GetChildren()) do
        if coin.Parent and not checked[coin] then
            local root = coin:GetAttribute("ID") ~= nil and coin or GetCoinRootFromInstance(coin)
            if root and root.Parent and not checked[root] then
                checked[root] = true
                local id = root:GetAttribute("ID")
                local position = GetCoinPosition(root)
                local health = tonumber(root:GetAttribute("Health"))
                local coinPart = root:FindFirstChild("Coin", true)
                local preventClick = coinPart and coinPart:GetAttribute("PreventClick")

                if id ~= nil and position and not preventClick and (health == nil or health > 0) then
                    local distance = (hrp.Position - position).Magnitude
                    if distance < closestDistance then
                        closestDistance = distance
                        closest = root
                    end
                end
            end
        end
    end

    -- Fallback for coins nested under another container.
    if not closest then
        for _, instance in ipairs(coinsFolder:GetDescendants()) do
            local root = GetCoinRootFromInstance(instance)
            if root and root.Parent and not checked[root] then
                checked[root] = true
                local id = root:GetAttribute("ID")
                local position = GetCoinPosition(root)
                local health = tonumber(root:GetAttribute("Health"))
                local coinPart = root:FindFirstChild("Coin", true)
                local preventClick = coinPart and coinPart:GetAttribute("PreventClick")
                if id ~= nil and position and not preventClick and (health == nil or health > 0) then
                    local distance = (hrp.Position - position).Magnitude
                    if distance < closestDistance then
                        closestDistance = distance
                        closest = root
                    end
                end
            end
        end
    end

    if closest then return closest end
    if previous and previous.Parent and previous:GetAttribute("ID") ~= nil then return previous end
    return nil
end

local function TeleportToClosestCoin(coin)
    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    local position = GetCoinPosition(coin)
    if not hrp or not position then
        return false
    end

    hrp.CFrame = CFrame.new(position + Vector3.new(0, 4, 0))
    return true
end

local function ResetCoinTarget()
    CurrentCoinTarget = nil
    CurrentCoinTargetId = nil
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

-- Locate the live Hacker Prime/Boss coin used by the Hacker Boss farm.
local function FindHackerBoss()
    local things = Workspace:FindFirstChild("__THINGS")
    local coins = things and things:FindFirstChild("Coins")
    if not coins then return nil end

    for _, coin in ipairs(coins:GetChildren()) do
        local rawName = coin:GetAttribute("Name") or coin:GetAttribute("Mob") or coin.Name
        local name = tostring(rawName):lower()
        local isHacker = name:find("hacker", 1, true) ~= nil
        local isPrimeOrBoss = name:find("prime", 1, true) ~= nil
            or name:find("boss", 1, true) ~= nil

        if isHacker and isPrimeOrBoss and coin:GetAttribute("ID") ~= nil then
            return coin
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
            task.wait(0.2)
        else
            task.wait(1)
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
                task.wait(0.05)
            else
                CurrentComet = nil
                CurrentCometId = nil
                task.wait(0.25)
            end
        else
            CurrentComet = nil
            CurrentCometId = nil
            task.wait(0.4)
        end
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

            local pets = RefreshCachedEquippedPets(false)
            for _, petUid in ipairs(pets) do
                pcall(function()
                    Library.Network.Fire("Farm Coin", CurrentCometId, petUid)
                end)
            end
            task.wait(0.05)
        else
            task.wait(0.3)
        end
    end
end)

-- Fast attack loop
task.spawn(function()
    while true do
        if FastAttackSpeed then
            local targetId = nil
            if AutoFarmComet then
                targetId = CurrentCometId
            elseif AutoFarmHackerBoss then
                targetId = CurrentHackerBossId
            elseif AutoFarmRobot then
                targetId = CurrentTargetId
            elseif AutoTap or AutoTeleportClosestCoin then
                targetId = CurrentCoinTargetId
            end

            if targetId then
                if DamageRemote then
                    pcall(function()
                        DamageRemote:FireServer(targetId)
                    end)
                end

                local pets = RefreshCachedEquippedPets(false)
                for _, petUid in ipairs(pets) do
                    pcall(function()
                        Library.Network.Fire("Farm Coin", targetId, petUid)
                    end)
                end
                task.wait(FastAttackInterval)
            else
                task.wait(0.2)
            end
        else
            task.wait(0.25)
        end
    end
end)

    -- REMOVED: the Expedition auto-farm loop and its damage loop.
-- Hacker Boss Auto Farm Loop
-- Uses the same coin selection / Join Coin / Change Pet Target sequence
-- as the other auto farms, targeting the live Hacker Prime boss coin.
task.spawn(function()
    while true do
        task.wait(0.15)

        if AutoFarmHackerBoss then
            if not CurrentHackerBoss or not CurrentHackerBoss.Parent then
                CurrentHackerBoss = FindHackerBoss()
                CurrentHackerBossId = CurrentHackerBoss and tostring(CurrentHackerBoss:GetAttribute("ID")) or nil
            end

            if CurrentHackerBoss and CurrentHackerBoss.Parent then
                CurrentHackerBossId = tostring(CurrentHackerBoss:GetAttribute("ID"))
                FocusPetsContinuous(CurrentHackerBoss)
            else
                CurrentHackerBoss = nil
                CurrentHackerBossId = nil
            end
        else
            CurrentHackerBoss = nil
            CurrentHackerBossId = nil
        end
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
        if CurrentTargetId and DamageRemote and AutoFarmRobot then
            pcall(function()
                DamageRemote:FireServer(CurrentTargetId)
            end)
            task.wait(0.05)
        else
            task.wait(0.3)
        end
    end
end)

-- Hacker Boss damage loop
task.spawn(function()
    while true do
        if AutoFarmHackerBoss and CurrentHackerBossId and DamageRemote then
            pcall(function()
                DamageRemote:FireServer(CurrentHackerBossId)
            end)
            task.wait(0.05)
        else
            task.wait(0.3)
        end
    end
end)

-- GENERIC CLOSEST-COIN FARM
-- Target scanning is deliberately separated from attacking. This keeps the
-- expensive Workspace scan from running at the same rate as the hit remotes.
local ClosestCoinScanInterval = 0.10
local ClosestCoinHitInterval = 0.05
local LastCoinInteractionTarget = nil
local LastCoinTeleportTarget = nil

-- Find and select the target at a lower rate than the actual attack loop.
task.spawn(function()
    while true do
        if AutoTap or AutoTeleportClosestCoin then
            local previous = CurrentCoinTarget
            local target = FindClosestCoin(previous)

            if target and target.Parent then
                local targetId = target:GetAttribute("ID")
                if targetId ~= nil then
                    targetId = tostring(targetId)
                    local changed = target ~= CurrentCoinTarget

                    CurrentCoinTarget = target
                    CurrentCoinTargetId = targetId

                    -- Selection is only sent when the target changes. Sending
                    -- it every frame is unnecessary and causes extra client work.
                    if changed or LastCoinInteractionTarget ~= target then
                        pcall(function()
                            Library.Signal.Fire("Select Coin", target)
                        end)
                        LastCoinInteractionTarget = target

                        if AutoTap then
                            local pets = RefreshCachedEquippedPets(true)
                            if #pets > 0 then
                                pcall(function()
                                    Library.Network.Invoke("Join Coin", targetId, pets)
                                end)

                                for _, petUid in ipairs(pets) do
                                    pcall(function()
                                        Library.Network.Fire("Change Pet Target", petUid, "Coin", targetId)
                                    end)
                                end
                            end
                        end
                    end

                    -- Teleport only when the target changes instead of
                    -- repeatedly setting CFrame every frame.
                    if AutoTeleportClosestCoin and (changed or LastCoinTeleportTarget ~= target) then
                        TeleportToClosestCoin(target)
                        LastCoinTeleportTarget = target
                    elseif not AutoTeleportClosestCoin then
                        LastCoinTeleportTarget = nil
                    end
                else
                    ResetCoinTarget()
                    LastCoinInteractionTarget = nil
                    LastCoinTeleportTarget = nil
                end
            else
                ResetCoinTarget()
                LastCoinInteractionTarget = nil
                LastCoinTeleportTarget = nil
            end
        else
            ResetCoinTarget()
            LastCoinInteractionTarget = nil
            LastCoinTeleportTarget = nil
        end

        task.wait((AutoTap or AutoTeleportClosestCoin) and ClosestCoinScanInterval or 0.4)
    end
end)

-- Dedicated hit loop. It uses the same direct damage/Farm Coin calls as the
-- pet list on every hit.
task.spawn(function()
    while true do
        if AutoTap and CurrentCoinTargetId then
            local targetId = CurrentCoinTargetId
            local pets = RefreshCachedEquippedPets(false)

            if DamageRemote then
                pcall(function()
                    DamageRemote:FireServer(targetId)
                end)
            end

            for _, petUid in ipairs(pets) do
                pcall(function()
                    Library.Network.Fire("Farm Coin", targetId, petUid)
                end)
            end
            task.wait(ClosestCoinHitInterval)
        else
            task.wait(0.25)
        end
    end
end)

-- ANTI-AFK
-- Sends a real Space key press at the user-selected interval (minutes).
task.spawn(function()
    while true do
        if AntiAFK then
            local interval = math.max(0.1, tonumber(AntiAFKIntervalMinutes) or 1) * 60
            local elapsed = 0
            while AntiAFK and elapsed < interval do
                local step = math.min(1, interval - elapsed)
                task.wait(step)
                elapsed += step
            end

            if AntiAFK then
                pcall(function()
                    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                    task.wait(0.1)
                    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
                end)
            end
        else
            task.wait(0.25)
        end
    end
end)

-- Potato Mode Continuous Focus Loop
task.spawn(function()
    while true do
        task.wait(0.1)
        if PotatoMode and AutoFarmRobot and CurrentTarget and CurrentTarget.Parent then
            FocusPetsContinuous(CurrentTarget)
        end
    end
end)


-- =====================================================================
-- EGG OPEN ANIMATION DISABLED COMPLETELY (LOW-LAG)
-- Event-driven cleanup only. Do not scan the entire Camera/Lighting tree
-- every frame, since that causes significant client-side lag.
-- =====================================================================
local function destroyEggAnimationObject(obj)
    if not obj then return end
    pcall(function()
        if obj.Name == "EggOpenAnim_Eggs" or obj.Name == "EggOpenDOF" then
            obj:Destroy()
        end
    end)
end

local function cleanupEggOpeningEffects()
    pcall(function()
        local camera = Workspace.CurrentCamera
        if camera then
            local eggs = camera:FindFirstChild("EggOpenAnim_Eggs")
            if eggs then eggs:Destroy() end
        end

        local dof = Lighting:FindFirstChild("EggOpenDOF")
        if dof then dof:Destroy() end

        local guiEggs = playerGui and playerGui:FindFirstChild("EggOpenAnim_Eggs", true)
        if guiEggs then guiEggs:Destroy() end
        local guiDof = playerGui and playerGui:FindFirstChild("EggOpenDOF", true)
        if guiDof then guiDof:Destroy() end
    end)
end

-- Watch only for newly-created top-level animation containers.
local eggAnimationConnections = {}
local function watchEggAnimationContainer(container)
    if not container then return end
    if eggAnimationConnections[container] then return end

    local ok, connection = pcall(function()
        return container.ChildAdded:Connect(function(child)
            if child.Name == "EggOpenAnim_Eggs" or child.Name == "EggOpenDOF" then
                destroyEggAnimationObject(child)
            end
        end)
    end)

    if ok and connection then
        eggAnimationConnections[container] = connection
    end
end

watchEggAnimationContainer(Workspace.CurrentCamera)
watchEggAnimationContainer(Lighting)
watchEggAnimationContainer(playerGui)

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    watchEggAnimationContainer(Workspace.CurrentCamera)
    cleanupEggOpeningEffects()
end)

-- Keep the egg-open animation from ever starting.
--
-- The previous version hooked `game.__namecall` to swallow
-- `EggOpenPort.PlayTrigger:Fire(...)`. That works, but __namecall is on the hot
-- path of EVERY method call in the entire game - it is a permanent, global tax
-- on the client and it was a large part of the frame drops while hatching.
--
-- The trigger is a plain RemoteEvent with exactly one listener: the Egg Opening
-- Frontend. Detaching that one connection stops the animation before it is ever
-- scheduled - no TweenService work, no DepthOfFieldEffect, no preloaded assets,
-- no EggOpenAnim instances - and costs nothing per frame.
local EggOpenEnv = (type(getgenv) == "function" and getgenv()) or _G

-- How the game plays the animation (read from the live scripts):
--   server -> Network "Eggs_PlayOpenAnimation" -> Game.EggOpenHook
--          -> ReplicatedStorage.EggOpenPort.PlayTrigger:Fire(...)   (BindableEvent)
--          -> ONE listener in "Egg Opening Frontend" that plays the animation,
--             raises Variables.OpeningEgg (which blocks auto-hatch until it ends),
--             then fires "Pets_ClearHidden" and the "CompletedHatching" signal.
--
-- We replace that single listener with a tiny one that skips the animation but
-- still does the bookkeeping. Dropping it entirely would leave new pets flagged
-- hidden. Since OpeningEgg is never raised, auto-hatch is no longer held back by
-- the animation and runs at the server's own cooldown.
local function eggOpenBookkeeping(eggId, pets)
    local uids = {}
    if type(pets) == "table" then
        for uid in pairs(pets) do uids[#uids + 1] = uid end
    end
    task.defer(function()
        pcall(function() Library.Network.Fire("Pets_ClearHidden", uids) end)
        pcall(function() Library.Signal.Fire("CompletedHatching", eggId, uids) end)
    end)
end

-- Undo a previous run of this script so reloads never stack listeners.
pcall(function()
    local previous = EggOpenEnv.PD_EggOpenHook
    if previous then
        if previous.replacement then previous.replacement:Disconnect() end
        if previous.trigger and previous.callback then
            previous.trigger.Event:Connect(previous.callback)
        end
    end
end)
EggOpenEnv.PD_EggOpenHook = nil

local eggOpenDetached = false
task.spawn(function()
    local port = ReplicatedStorage:WaitForChild("EggOpenPort", 15)
    local trigger = port and port:WaitForChild("PlayTrigger", 15)
    if not trigger then return end

    pcall(function()
        local signal = trigger:IsA("BindableEvent") and trigger.Event or trigger.OnClientEvent
        local callback
        for _, connection in ipairs(getconnections(signal)) do
            if connection.Enabled and type(connection.Function) == "function" then
                callback = callback or connection.Function
                connection:Disconnect()
            end
        end
        if callback then
            EggOpenEnv.PD_EggOpenHook = {
                trigger = trigger,
                callback = callback,
                replacement = signal:Connect(eggOpenBookkeeping),
            }
            eggOpenDetached = true
        end
    end)

    -- Fallback only when the listener could not be detached: swallow the
    -- :Fire() with a namecall hook (installed once per session).
    if not eggOpenDetached and not EggOpenEnv.PD_EggOpenNamecallHooked then
        pcall(function()
            if type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" and type(newcclosure) == "function" then
                local oldNamecall
                oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
                    if getnamecallmethod() == "Fire" and typeof(self) == "Instance" and self.Name == "PlayTrigger" then
                        local parent = self.Parent
                        if parent and parent.Name == "EggOpenPort" then
                            eggOpenBookkeeping(...)
                            return nil
                        end
                    end
                    return oldNamecall(self, ...)
                end))
                EggOpenEnv.PD_EggOpenNamecallHooked = true
            end
        end)
    end
end)

-- Small fallback cleanup only while Auto-Hatch is active, and only every 2s.
-- With the listener detached nothing should ever be created, so this is a
-- safety net for leftovers from an animation that was already in flight when
-- the script loaded - not a per-frame tree scan.
task.spawn(function()
    while true do
        if AutoBuying then
            cleanupEggOpeningEffects()
        end
        task.wait(2)
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
    -- The hub is designed around a 680x720 canvas. Instead of using a
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
        local DESIGN_WIDTH = 680
        local DESIGN_HEIGHT = 720
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

    -- Forward declarations used by refreshTracker/applyTheme before the UI
    -- constructors below assign their actual instances.
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
    -- Rainbow/Golden/Shiny subtotals, keyed "<Tier>s" (e.g. "Huges") or
    -- "<Tier>sGolden"/"<Tier>sShiny". Kept per tier so the UI can report which
    -- tier your rainbows actually came from.
    local variantCounts = {}
    local variantLabels = {}
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
    local lastRecentRenderSignature = ""

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

            -- Variant prefix. Rainbow beats Golden beats Shiny, matching the
            -- game's own naming order (Trading Booths checks rainbow first,
            -- then golden). A pet can carry more than one flag.
            local prefix, suffix = "", ""
            if entryData.rainbow then
                prefix = "[Rainbow] "
                label.TextColor3 = Color3.fromRGB(255, 120, 220)
                if entryData.golden then suffix = " +G" elseif entryData.shiny then suffix = " +S" end
            elseif entryData.golden then
                prefix = "[Golden] "
                label.TextColor3 = Color3.fromRGB(255, 200, 70)
                if entryData.shiny then suffix = " +S" end
            elseif entryData.shiny then
                prefix = "[Shiny] "
                label.TextColor3 = Color3.fromRGB(120, 240, 255)
            end
            local nick = ""
            if entryData.nickname and entryData.nickname ~= "" then
                nick = " (" .. tostring(entryData.nickname) .. ")"
            end
            label.Text = "- " .. prefix .. tostring(entryData.name) .. nick .. suffix
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

        for petKey, pet in pairs(pets) do
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

                    -- The inventory table key is the stable instance UID in
                    -- many saves. Species IDs are shared by duplicates, so
                    -- they must never be used as the fallback identity.
                    local uid = tostring(pet.uid or petKey)
                    if not knownPets[uid] then
                        if trackerInitialized then
                            local displayName = getPetDisplayName(pet)
                            -- Rarity flags live directly on the pet record:
                            --   r = Rainbow, g = Golden, sh = Shiny, snk = signed nickname.
                            -- Verified against Save.Get().Pets: r/g/sh are the only
                            -- variant flags the game ever sets on a pet entry.
                            local entry = {
                                name = displayName,
                                uid = uid,
                                rainbow = pet.r == true,
                                golden = pet.g == true,
                                shiny = pet.sh == true,
                                signed = pet.snk == true,
                                nickname = pet.nk,
                            }

                            -- Variant subtotals, tracked separately from the tier
                            -- totals so the UI can show "20 of your Huges are Rainbow".
                            local vKey = category .. "s"
                            if entry.rainbow then
                                variantCounts[vKey] = (variantCounts[vKey] or 0) + 1
                            end
                            if entry.golden then
                                variantCounts[vKey .. "Golden"] = (variantCounts[vKey .. "Golden"] or 0) + 1
                            end
                            if entry.shiny then
                                variantCounts[vKey .. "Shiny"] = (variantCounts[vKey .. "Shiny"] or 0) + 1
                            end

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

        -- Variant totals: one line per tier that actually owns a variant pet.
        -- Rendered dynamically so a tier with zero rainbows costs no label.
        if statsContainer then
            local order = { "Huges", "Titanics", "Gargantuans", "Secrets" }
            local used = 0
            for _, base in ipairs(order) do
                local rb = variantCounts[base] or 0
                local gd = variantCounts[base .. "Golden"] or 0
                local sh = variantCounts[base .. "Shiny"] or 0
                if rb > 0 or gd > 0 or sh > 0 then
                    local key = base
                    local label = variantLabels[key]
                    local text = ("%s  R:%d  G:%d  S:%d"):format(base, rb, gd, sh)
                    if not label then
                        used += 1
                        label = Instance.new("TextLabel")
                        label.Size = UDim2.new(1, -20, 0, 20)
                        label.Position = UDim2.new(0, 10, 0, 142 + (used - 1) * 22)
                        label.BackgroundTransparency = 1
                        label.TextColor3 = Color3.fromRGB(255, 120, 220)
                        label.Font = Enum.Font.GothamBold
                        label.TextSize = 12
                        label.TextXAlignment = Enum.TextXAlignment.Left
                        label:SetAttribute("ThemeLocked", true)
                        label.Parent = statsContainer
                        variantLabels[key] = label
                    end
                    label.Text = text
                end
            end
            for key, label in pairs(variantLabels) do
                local base = key
                local rb = variantCounts[base] or 0
                local gd = variantCounts[base .. "Golden"] or 0
                local sh = variantCounts[base .. "Shiny"] or 0
                if rb == 0 and gd == 0 and sh == 0 then
                    label:Destroy()
                    variantLabels[key] = nil
                end
            end
        end
        if afkRareLabels.Titanics then afkRareLabels.Titanics.Text = titanicLabel.Text end
        if afkSessionActive then
            updateAfkSessionLabels()
        end

        if not trackerInitialized then
            trackerInitialized = true
        end

        -- Only rebuild recent-pet UI when the data actually changed.
        -- The old behavior recreated every TextLabel every 2 seconds even
        -- when nothing had been hatched, which caused unnecessary UI churn.
        local recentSignature = table.concat({
            tostring(totalHuge), tostring(totalSecret), tostring(totalTitanic), tostring(totalGargantuan),
            tostring(recentHuges[1] and recentHuges[1].uid or ""),
            tostring(recentSecrets[1] and recentSecrets[1].uid or ""),
            tostring(recentTitanics[1] and recentTitanics[1].uid or ""),
            tostring(recentGargantuans[1] and recentGargantuans[1].uid or "")
        }, "|")

        if recentSignature ~= lastRecentRenderSignature then
            lastRecentRenderSignature = recentSignature
            if tracker.Parent then
                renderRecent(hugeList, recentHuges, Color3.fromRGB(100, 255, 100))
                renderRecent(secretList, recentSecrets, Color3.fromRGB(215, 150, 255))
                renderRecent(titanicList, recentTitanics, Color3.fromRGB(160, 220, 255))
                renderRecent(gargantuanList, recentGargantuans, Color3.fromRGB(255, 180, 200))
            end
            renderHatchRecent()
            renderAfkRecent()
        end
    end

    updateTrackerState()
    tracker:Destroy()
    task.spawn(function()
        while ui.Parent do
            refreshTracker()
            task.wait(2.5)
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
    autoHatchMain.Size = UDim2.new(0, 680, 0, 720)
    autoHatchMain.Position = UDim2.new(0.5, -340, 0.5, -360)
    autoHatchMain.BackgroundColor3 = Color3.fromRGB(17, 20, 29)
    autoHatchMain.BorderSizePixel = 0
    autoHatchMain.Active = true
    autoHatchMain.Draggable = true
    autoHatchMain.Visible = true
    autoHatchMain.Parent = ui

    local autoHatchCorner = Instance.new("UICorner")
    autoHatchCorner.CornerRadius = UDim.new(0, 16)
    autoHatchCorner.Parent = autoHatchMain

    local autoHatchShadow = Instance.new("UIStroke")
    autoHatchShadow.Color = Color3.fromRGB(60, 140, 220)
    autoHatchShadow.Thickness = 1.2
    autoHatchShadow.Transparency = 0.58
    autoHatchShadow.Parent = autoHatchMain

    local autoTitle = Instance.new("TextLabel")
    autoTitle.Size = UDim2.new(1, -40, 0, 32)
    autoTitle.Position = UDim2.new(0, 20, 0, 12)
    autoTitle.Text = "Pet Dimensions Hub"
    autoTitle.TextColor3 = Color3.fromRGB(60, 140, 220)
    autoTitle.Font = Enum.Font.GothamBold
    autoTitle.TextSize = 21
    autoTitle.BackgroundTransparency = 1
    autoTitle.TextXAlignment = Enum.TextXAlignment.Left
    autoTitle.Parent = autoHatchMain

    local tabBar = Instance.new("Frame")
    tabBar.Name = "TabContainer"
    tabBar.Size = UDim2.new(1, -40, 0, 42)
    tabBar.Position = UDim2.new(0, 20, 0, 74)
    tabBar.BackgroundTransparency = 1
    tabBar.Parent = autoHatchMain

    local TAB_TOTAL = 6
    local function createTabButton(text, index)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1 / 5, -7, 1, 0)
        btn.AnchorPoint = Vector2.new(0.5, 0)
        btn.Position = UDim2.new((index - 0.5) / 5, 0, 0, 0)
        btn.Text = text
        btn.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
        btn.TextColor3 = Color3.fromRGB(160, 171, 193)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 12
        btn.Parent = tabBar

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 9)
        corner.Parent = btn

        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(80, 80, 100)
        stroke.Thickness = 1
        stroke.Transparency = 0.72
        stroke.Parent = btn

        return btn
    end

    local hatchTab = createTabButton("Hatch", 1)
    local tpTab = createTabButton("Teleport", 2)
    local settingsTab = createTabButton("Settings", 3)
    local eggTab = createTabButton("Egg Chances", 4)
    local farmTab = createTabButton("Farm", 5)

    local hatchFrame = Instance.new("ScrollingFrame")
    hatchFrame.Size = UDim2.new(1, -40, 1, -136)
    hatchFrame.Position = UDim2.new(0, 20, 0, 128)
    hatchFrame.BackgroundTransparency = 1
    hatchFrame.BorderSizePixel = 0
    hatchFrame.ClipsDescendants = true
    hatchFrame.ScrollBarThickness = 4
    hatchFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    hatchFrame.CanvasSize = UDim2.new(0, 0, 0, 965)
    hatchFrame.Parent = autoHatchMain

    local tpFrame = Instance.new("Frame")
    tpFrame.Size = UDim2.new(1, -40, 1, -136)
    tpFrame.Position = UDim2.new(0, 20, 0, 128)
    tpFrame.BackgroundTransparency = 1
    tpFrame.Visible = false
    tpFrame.Parent = autoHatchMain

    local settingsFrame = Instance.new("Frame")
    settingsFrame.Size = UDim2.new(1, -40, 1, -136)
    settingsFrame.Position = UDim2.new(0, 20, 0, 128)
    settingsFrame.BackgroundTransparency = 1
    settingsFrame.Visible = false
    settingsFrame.Parent = autoHatchMain

    local eggFrame = Instance.new("Frame")
    eggFrame.Size = UDim2.new(1, -40, 1, -136)
    eggFrame.Position = UDim2.new(0, 20, 0, 128)
    eggFrame.BackgroundTransparency = 1
    eggFrame.Visible = false
    eggFrame.Parent = autoHatchMain

    local farmFrame = Instance.new("ScrollingFrame")
    farmFrame.Name = "FarmScroll"
    farmFrame.Size = UDim2.new(1, -40, 1, -136)
    farmFrame.Position = UDim2.new(0, 20, 0, 128)
    farmFrame.BackgroundTransparency = 1
    farmFrame.BorderSizePixel = 0
    farmFrame.ScrollBarThickness = 5
    farmFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    farmFrame.Visible = false
    farmFrame.Parent = autoHatchMain
    do local _fp = Instance.new("UIPadding") _fp.PaddingBottom = UDim.new(0, 24) _fp.Parent = farmFrame end


    -- =====================================================================
    -- FULL EXTENDED THEMES SYSTEM
    -- =====================================================================
    local function makeTheme(name, background, panel, surface, accent, controlOn, danger, text, muted, stroke)
        -- `input` used to alias `surface`, which made every textbox the same
        -- shade as the button next to it - the field read as part of the
        -- button and looked flat. It is now derived so it is always a step
        -- darker than the surface it sits on, and themes can override it.
        local surface = surface or Color3.fromRGB(32, 32, 42)
        return {
            name = name,
            background = background or Color3.fromRGB(20, 21, 26),
            panel = panel or Color3.fromRGB(28, 29, 38),
            surface = surface,
            input = Color3.fromRGB(
                math.floor(surface.R * 255 * 0.82),
                math.floor(surface.G * 255 * 0.82),
                math.floor(surface.B * 255 * 0.82)
            ),
            accent = accent or Color3.fromRGB(60, 140, 220),
            controlOn = controlOn or Color3.fromRGB(45, 140, 75),
            danger = danger or Color3.fromRGB(200, 50, 50),
            -- Text and muted were accepted but every theme below passed them
            -- positionally after `danger`, and most themes did not pass them
            -- at all - so nearly all of them fell back to the same off-white.
            -- Deriving from `background` keeps contrast correct on light-ish
            -- themes (Solarized, Platinum, Pure Gold) where pure white on a
            -- mid-tone panel was the worst offender.
            text = text or (background and background.R > 0.32
                and Color3.fromRGB(28, 28, 34)
                or Color3.fromRGB(245, 245, 250)),
            muted = muted or (background and background.R > 0.32
                and Color3.fromRGB(70, 70, 80)
                or Color3.fromRGB(168, 168, 180)),
            stroke = stroke or (background and background.R > 0.32
                and Color3.fromRGB(120, 116, 100)
                or Color3.fromRGB(80, 80, 100)),
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
-- ---- newer additions ----
        -- Every one of these passes the full 10-argument set (text, muted and
        -- stroke included), which the older entries above did not - that is what
        -- makes each one read as a distinct theme instead of the same grey
        -- window with a different button colour.
        makeTheme("Obsidian",      Color3.fromRGB(10, 10, 12),  Color3.fromRGB(18, 18, 22),  Color3.fromRGB(26, 26, 32),  Color3.fromRGB(255, 255, 255), Color3.fromRGB(52, 199, 89), Color3.fromRGB(255, 69, 58),  Color3.fromRGB(245, 245, 247), Color3.fromRGB(140, 140, 150), Color3.fromRGB(70, 70, 80)),
        makeTheme("Carbon Rose",   Color3.fromRGB(22, 14, 18),  Color3.fromRGB(34, 21, 27),  Color3.fromRGB(48, 30, 38),  Color3.fromRGB(244, 114, 182), Color3.fromRGB(52, 168, 120), Color3.fromRGB(232, 62, 90), Color3.fromRGB(250, 240, 244), Color3.fromRGB(186, 150, 166), Color3.fromRGB(96, 66, 82)),
        makeTheme("Deep Teal",     Color3.fromRGB(8, 24, 26),   Color3.fromRGB(13, 38, 41),  Color3.fromRGB(19, 54, 58),  Color3.fromRGB(94, 234, 212), Color3.fromRGB(45, 170, 120), Color3.fromRGB(240, 80, 100), Color3.fromRGB(240, 250, 250), Color3.fromRGB(146, 180, 180), Color3.fromRGB(64, 100, 104)),
        makeTheme("Plum Velvet",   Color3.fromRGB(26, 14, 30),  Color3.fromRGB(39, 22, 45),  Color3.fromRGB(54, 31, 63),  Color3.fromRGB(216, 130, 240), Color3.fromRGB(70, 170, 130), Color3.fromRGB(235, 70, 110), Color3.fromRGB(248, 240, 252), Color3.fromRGB(180, 158, 192), Color3.fromRGB(92, 68, 104)),
        makeTheme("Sandstorm",     Color3.fromRGB(44, 36, 24),  Color3.fromRGB(60, 50, 33),  Color3.fromRGB(78, 66, 44),  Color3.fromRGB(230, 176, 90), Color3.fromRGB(120, 160, 80), Color3.fromRGB(200, 80, 60),  Color3.fromRGB(250, 244, 232), Color3.fromRGB(196, 180, 150), Color3.fromRGB(130, 112, 78)),
        makeTheme("Steel Blue",    Color3.fromRGB(18, 22, 28),  Color3.fromRGB(27, 33, 41),  Color3.fromRGB(37, 45, 56),  Color3.fromRGB(126, 176, 214), Color3.fromRGB(60, 150, 110), Color3.fromRGB(214, 82, 88),  Color3.fromRGB(238, 244, 250), Color3.fromRGB(154, 168, 184), Color3.fromRGB(74, 88, 104)),
        makeTheme("Royal Purple",  Color3.fromRGB(20, 12, 34),  Color3.fromRGB(31, 19, 52),  Color3.fromRGB(43, 27, 72),  Color3.fromRGB(170, 120, 255), Color3.fromRGB(60, 175, 120), Color3.fromRGB(230, 65, 100), Color3.fromRGB(246, 240, 255), Color3.fromRGB(172, 156, 200), Color3.fromRGB(88, 70, 130)),
        makeTheme("Blood Moon",    Color3.fromRGB(24, 10, 12),  Color3.fromRGB(36, 15, 18),  Color3.fromRGB(50, 21, 25),  Color3.fromRGB(228, 58, 58), Color3.fromRGB(70, 150, 90),  Color3.fromRGB(255, 60, 60),  Color3.fromRGB(250, 232, 232), Color3.fromRGB(188, 148, 148), Color3.fromRGB(98, 54, 56)),
        makeTheme("Sea Foam",      Color3.fromRGB(12, 30, 34),  Color3.fromRGB(18, 44, 50),  Color3.fromRGB(25, 60, 68),  Color3.fromRGB(120, 220, 200), Color3.fromRGB(60, 170, 130), Color3.fromRGB(230, 80, 100), Color3.fromRGB(238, 248, 250), Color3.fromRGB(148, 178, 186), Color3.fromRGB(66, 104, 112)),
        makeTheme("Gold Leaf",     Color3.fromRGB(30, 26, 14),  Color3.fromRGB(43, 37, 20),  Color3.fromRGB(57, 49, 27),  Color3.fromRGB(233, 196, 106), Color3.fromRGB(150, 165, 80), Color3.fromRGB(210, 90, 70), Color3.fromRGB(252, 246, 230), Color3.fromRGB(198, 184, 148), Color3.fromRGB(120, 104, 62)),
        makeTheme("Orchid",        Color3.fromRGB(28, 16, 34),  Color3.fromRGB(41, 24, 50),  Color3.fromRGB(56, 33, 68),  Color3.fromRGB(198, 120, 235), Color3.fromRGB(70, 175, 135), Color3.fromRGB(232, 68, 118), Color3.fromRGB(248, 240, 252), Color3.fromRGB(180, 156, 194), Color3.fromRGB(94, 68, 110)),
        makeTheme("Slate Blue",    Color3.fromRGB(16, 18, 24),  Color3.fromRGB(24, 27, 35),  Color3.fromRGB(33, 38, 49),  Color3.fromRGB(150, 165, 190), Color3.fromRGB(70, 155, 115), Color3.fromRGB(210, 80, 90),  Color3.fromRGB(236, 240, 248), Color3.fromRGB(158, 168, 186), Color3.fromRGB(72, 80, 96)),
        makeTheme("Sunset Ember",  Color3.fromRGB(34, 14, 18),  Color3.fromRGB(50, 21, 25),  Color3.fromRGB(67, 29, 32),  Color3.fromRGB(255, 130, 70), Color3.fromRGB(80, 170, 120), Color3.fromRGB(235, 70, 70),  Color3.fromRGB(252, 238, 232), Color3.fromRGB(196, 158, 148), Color3.fromRGB(108, 68, 62)),
        makeTheme("Arctic White",  Color3.fromRGB(228, 232, 240),Color3.fromRGB(242, 245, 250),Color3.fromRGB(252, 253, 255),Color3.fromRGB(40, 90, 190), Color3.fromRGB(30, 140, 80),  Color3.fromRGB(210, 40, 50),  Color3.fromRGB(20, 22, 28),   Color3.fromRGB(96, 102, 118),  Color3.fromRGB(196, 202, 216)),
        makeTheme("Paper Light",   Color3.fromRGB(238, 234, 224),Color3.fromRGB(248, 246, 240),Color3.fromRGB(255, 254, 250),Color3.fromRGB(190, 90, 40), Color3.fromRGB(40, 130, 75),  Color3.fromRGB(200, 45, 45),  Color3.fromRGB(28, 26, 24),   Color3.fromRGB(110, 104, 94),  Color3.fromRGB(200, 194, 182)),
        makeTheme("Mono Frost",    Color3.fromRGB(20, 22, 24),  Color3.fromRGB(30, 32, 35),  Color3.fromRGB(41, 44, 48),  Color3.fromRGB(225, 228, 232), Color3.fromRGB(90, 92, 96),   Color3.fromRGB(190, 70, 70),  Color3.fromRGB(242, 244, 247), Color3.fromRGB(160, 164, 172), Color3.fromRGB(88, 92, 100)),
        makeTheme("Deep Forest",   Color3.fromRGB(10, 20, 14),  Color3.fromRGB(16, 32, 22),  Color3.fromRGB(22, 45, 30),  Color3.fromRGB(120, 200, 130), Color3.fromRGB(90, 170, 90),  Color3.fromRGB(215, 85, 75),  Color3.fromRGB(236, 246, 238), Color3.fromRGB(148, 176, 156), Color3.fromRGB(58, 88, 66)),
        makeTheme("Lavender Haze", Color3.fromRGB(24, 20, 36),  Color3.fromRGB(36, 30, 54),  Color3.fromRGB(49, 42, 74),  Color3.fromRGB(180, 168, 240), Color3.fromRGB(80, 165, 140), Color3.fromRGB(225, 90, 130), Color3.fromRGB(242, 240, 252), Color3.fromRGB(168, 164, 196), Color3.fromRGB(82, 76, 112)),
        makeTheme("Sunset Candy",  Color3.fromRGB(40, 16, 30),  Color3.fromRGB(56, 23, 42),  Color3.fromRGB(75, 31, 56),  Color3.fromRGB(255, 140, 190), Color3.fromRGB(70, 180, 140), Color3.fromRGB(240, 70, 100), Color3.fromRGB(252, 238, 246), Color3.fromRGB(196, 158, 182), Color3.fromRGB(112, 64, 90)),
        makeTheme("Mossy Stone",   Color3.fromRGB(26, 26, 22),  Color3.fromRGB(38, 38, 32),  Color3.fromRGB(52, 52, 43),  Color3.fromRGB(178, 186, 120), Color3.fromRGB(90, 160, 95),  Color3.fromRGB(205, 90, 70),  Color3.fromRGB(242, 244, 234), Color3.fromRGB(170, 174, 152), Color3.fromRGB(96, 96, 82)),
        makeTheme("Abyss",         Color3.fromRGB(6, 10, 14),   Color3.fromRGB(11, 17, 23),  Color3.fromRGB(16, 24, 32),  Color3.fromRGB(80, 190, 230), Color3.fromRGB(50, 160, 120), Color3.fromRGB(220, 70, 90),  Color3.fromRGB(234, 244, 250), Color3.fromRGB(140, 164, 180), Color3.fromRGB(48, 68, 82)),
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
        if obj:GetAttribute("ThemePreview") or obj:GetAttribute("ThemeLocked") then return end

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
        -- The title used to be hard-coded blue, so it ignored the theme
        -- entirely and sat oddly against every palette except the default.
        autoTitle.TextColor3 = activeTheme.accent

        for _, btn in ipairs({hatchTab, tpTab, settingsTab, eggTab, farmTab}) do
            if btn == currentTabBtn then
                btn.BackgroundColor3 = activeTheme.accent
                btn.TextColor3 = Color3.fromRGB(255, 255, 255)
            else
                btn.BackgroundColor3 = activeTheme.surface
                btn.TextColor3 = activeTheme.muted
            end
        end

        -- Move the tick and the highlight ring onto the active theme row.
        if themeRows then
            for name, entry in pairs(themeRows) do
                local isActive = (name == themeObj.name)
                if entry.check then entry.check.Visible = isActive end
                if entry.stroke then
                    entry.stroke.Thickness = isActive and 2 or 1
                    entry.stroke.Transparency = isActive and 0 or 0.55
                    entry.stroke.Color = themeObj.accent
                end
            end
        end
        if themeScroll then themeScroll.BackgroundColor3 = activeTheme.panel end
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
    local toggleCallbacks = {}

    local function createUnifiedToggle(parent, yPos, text, defaultState, callback)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 34)
        btn.Position = UDim2.new(0, 0, 0, yPos)
        btn.BackgroundColor3 = defaultState and activeTheme.controlOn or activeTheme.surface
        btn.Text = text .. (defaultState and ": ON" or ": OFF")
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

        -- Toggles that must never come back ON from the saved config. AFK opens the
        -- full-screen overlay and hides the hub, so restoring it made every
        -- execute look broken. Kept in a set so more toggles can be added
        -- later without touching the restore loop.
        local NEVER_RESTORE = {
            ["AFK CPU Reducer"] = true,
        }

        local state = (not NEVER_RESTORE[text]) and CurrentToggleStates[text] == true or defaultState
        if NEVER_RESTORE[text] then
            -- also drop the stale saved value so the button does not light up
            -- green while the feature is actually off
            CurrentToggleStates[text] = false
        end
        btn:SetAttribute("ToggleState", state)
        toggleCallbacks[text] = callback

        local function updateVisuals(newState)
            state = newState
            btn:SetAttribute("ToggleState", state)
            btn.BackgroundColor3 = state and activeTheme.controlOn or activeTheme.surface
            btn.Text = text .. (state and ": ON" or ": OFF")
            btn.TextColor3 = state and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 180, 190)
        end

        btn.MouseButton1Click:Connect(function()
            local newState = not state
            updateVisuals(newState)
            CurrentToggleStates[text] = newState
            saveSettings()
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

    createUnifiedToggle(farmFrame, 32, "Robot Farm", false, function(state) AutoFarmRobot = state end)
    -- shared status-bar and damage branches still read it.
    createUnifiedToggle(farmFrame, 74, "Comet Farm", false, function(state)
        AutoFarmComet = state
        if state then
            CurrentTarget = nil
            CurrentTargetId = nil
        else
            CurrentComet = nil
            CurrentCometId = nil
        end
    end)
    createUnifiedToggle(farmFrame, 116, "Auto Tokens", false, function(state) AutoTokens = state end)
    createUnifiedToggle(farmFrame, 158, "Fast Pet Speed", false, function(state) SetFastPetSpeed(state) end)
    createUnifiedToggle(farmFrame, 200, "Fast Attack", false, function(state) FastAttackSpeed = state end)

    createUnifiedToggle(farmFrame, 242, "Hacker Boss Farm", false, function(state)
        AutoFarmHackerBoss = state
        if not state then
            CurrentHackerBoss = nil
            CurrentHackerBossId = nil
        end
    end)

    -- returned nil every tick and the dodge/attack scheduler never had a
    -- status-bar and damage branches still read it.


    createUnifiedToggle(farmFrame, 326, "Auto Tap", false, function(state)
        AutoTap = state
        if not state then
            ResetCoinTarget()
        end
    end)

    createUnifiedToggle(farmFrame, 368, "Auto Teleport to Closest Coin", false, function(state)
        AutoTeleportClosestCoin = state
        if not state and not AutoTap then
            ResetCoinTarget()
        end
    end)

    createUnifiedToggle(farmFrame, 410, "Anti AFK", false, function(state)
        AntiAFK = state
    end)

    local antiAfkLabel = Instance.new("TextLabel")
    antiAfkLabel.Size = UDim2.new(0.58, 0, 0, 28)
    antiAfkLabel.Position = UDim2.new(0, 0, 0, 452)
    antiAfkLabel.BackgroundTransparency = 1
    antiAfkLabel.Text = "Anti AFK interval (minutes)"
    antiAfkLabel.TextColor3 = Color3.fromRGB(190, 190, 200)
    antiAfkLabel.Font = Enum.Font.GothamBold
    antiAfkLabel.TextSize = 12
    antiAfkLabel.TextXAlignment = Enum.TextXAlignment.Left
    antiAfkLabel.Parent = farmFrame

    local antiAfkBox = Instance.new("TextBox")
    antiAfkBox.Size = UDim2.new(0.32, 0, 0, 28)
    antiAfkBox.Position = UDim2.new(0.68, 0, 0, 452)
    antiAfkBox.BackgroundColor3 = Color3.fromRGB(35, 35, 48)
    antiAfkBox.BorderSizePixel = 0
    antiAfkBox.ClearTextOnFocus = false
    -- Restore the saved interval so it survives a rejoin
    AntiAFKIntervalMinutes = tonumber(GetSetting("antiAfkMinutes", 1)) or 1
    antiAfkBox.Text = tostring(AntiAFKIntervalMinutes)
    antiAfkBox.PlaceholderText = "Minutes"
    antiAfkBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    antiAfkBox.Font = Enum.Font.GothamBold
    antiAfkBox.TextSize = 12
    antiAfkBox.Parent = farmFrame

    local antiAfkCorner = Instance.new("UICorner")
    antiAfkCorner.CornerRadius = UDim.new(0, 6)
    antiAfkCorner.Parent = antiAfkBox

    antiAfkBox.FocusLost:Connect(function()
        local value = tonumber(antiAfkBox.Text)
        if not value then
            value = 1
        end
        value = math.clamp(value, 0.1, 1440)
        AntiAFKIntervalMinutes = value
        antiAfkBox.Text = tostring(value)
        SetSetting("antiAfkMinutes", value)
    end)


    local farmStatus = Instance.new("TextLabel")
    farmStatus.Size = UDim2.new(1, 0, 0, 28)
    farmStatus.Position = UDim2.new(0, 0, 0, 490)
    farmStatus.BackgroundTransparency = 1
    farmStatus.Text = "Status: Idle"
    farmStatus.TextColor3 = Color3.fromRGB(180, 180, 180)
    farmStatus.Font = Enum.Font.GothamBold
    farmStatus.TextSize = 13
    farmStatus.TextXAlignment = Enum.TextXAlignment.Left
    farmStatus.Parent = farmFrame

    task.spawn(function()
        while farmFrame.Parent do
            if AutoBuying then
                farmStatus.Text = "Status: " .. tostring(HatchWatchdogStatus)
                farmStatus.TextColor3 = Color3.fromRGB(120, 255, 180)
            elseif AutoFarmRobot and CurrentTargetId then
                farmStatus.Text = "Status: Farming Robot #" .. CurrentTargetId
                farmStatus.TextColor3 = Color3.fromRGB(100, 255, 100)
            elseif AutoFarmHackerBoss and CurrentHackerBossId then
                farmStatus.Text = "Status: Farming Hacker Prime #" .. CurrentHackerBossId
                farmStatus.TextColor3 = Color3.fromRGB(120, 255, 200)
            elseif AutoFarmComet and CurrentCometId then
                farmStatus.Text = "Status: Farming Comet #" .. CurrentCometId
                farmStatus.TextColor3 = Color3.fromRGB(180, 220, 255)
            elseif (AutoTap or AutoTeleportClosestCoin) and CurrentCoinTargetId then
                if AutoTap and AutoTeleportClosestCoin then
                    farmStatus.Text = "Status: Tapping + teleporting to coin #" .. CurrentCoinTargetId
                elseif AutoTap then
                    farmStatus.Text = "Status: Auto tapping coin #" .. CurrentCoinTargetId
                else
                    farmStatus.Text = "Status: Teleporting to closest coin #" .. CurrentCoinTargetId
                end
                farmStatus.TextColor3 = Color3.fromRGB(120, 220, 255)
            elseif AntiAFK then
                farmStatus.Text = "Status: Anti AFK every " .. tostring(AntiAFKIntervalMinutes) .. " minute(s)"
                farmStatus.TextColor3 = Color3.fromRGB(120, 255, 180)
            elseif AutoFarmRobot then
                farmStatus.Text = "Status: Searching Target..."
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
    eggSelect.Text = "Select Egg Dropdown"
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

    -- Abbreviates odds to the closest whole-ish number with a unit.
    -- 1/250000000 -> "1/250m", 1/1500000 -> "1/1.5m", 1/45000 -> "1/45k".
    -- Under 1,000 stays a plain number. No commas, no percentage.
    local function formatOdds(chance)
        chance = tonumber(chance) or 0
        if chance <= 0 then return "N/A" end

        local odds = 100 / chance
        if odds < 1000 then
            return "1/" .. string.format("%.0f", odds)
        end

        local units = { {1e3, "k"}, {1e6, "m"}, {1e9, "b"}, {1e12, "t"} }
        local index = 1
        for i, unit in ipairs(units) do
            if odds >= unit[1] then index = i end
        end

        local value = tonumber(string.format("%.2f", odds / units[index][1]))
        if value >= 1000 and units[index + 1] then
            index += 1
            value = tonumber(string.format("%.2f", odds / units[index][1]))
        end

        local text = string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", "")
        return "1/" .. text .. units[index][2]
    end

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
        chanceLabel.Text = formatOdds(chance)
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
            bestOption.Text = string.format("Best chance: %s (%.4g%%)", bestEgg.Name, getEggBestChance(bestEgg))
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

    statsContainer = Instance.new("Frame")
    statsContainer.Name = "StatsContainer"
    statsContainer.Size = UDim2.new(1, 0, 0, 232)
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

    -- These Hatch-tab counters keep their fixed colors in every theme.
    local hatchEggsGreen = Color3.fromRGB(80, 230, 80)
    local hatchDiamondsBlue = Color3.fromRGB(110, 185, 255)
    EggsLabel.TextColor3 = hatchEggsGreen
    GemsLabel.TextColor3 = hatchDiamondsBlue
    EggsLabel:SetAttribute("ThemeLocked", true)
    GemsLabel:SetAttribute("ThemeLocked", true)

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

    local SearchBox = Instance.new("TextBox")
    SearchBox.Size = UDim2.new(1, 0, 0, 32)
    SearchBox.Position = UDim2.new(0, 0, 0, 242)
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
    SelectedEggLabel.Position = UDim2.new(0, 0, 0, 280)
    SelectedEggLabel.Text = "Selected: Spawn Egg"
    SelectedEggLabel.TextColor3 = Color3.fromRGB(100, 225, 100)
    SelectedEggLabel.Font = Enum.Font.GothamBold
    SelectedEggLabel.TextSize = 12
    SelectedEggLabel.BackgroundTransparency = 1
    SelectedEggLabel.TextXAlignment = Enum.TextXAlignment.Left
    SelectedEggLabel.Parent = hatchFrame

    local DropdownFrame = Instance.new("ScrollingFrame")
    DropdownFrame.Size = UDim2.new(1, 0, 0, 100)
    DropdownFrame.Position = UDim2.new(0, 0, 0, 306)
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
    if PersistedSettings.selectedEgg then
        for _, egg in ipairs(EggList) do
            if tostring(egg.ID) == PersistedSettings.selectedEgg then
                SelectedEggId = egg.ID
                break
            end
        end
    end
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
                button.TextColor3 = Color3.fromRGB(255, 255, 255)
                button.Font = Enum.Font.Gotham
                button.TextSize = 12
                button.TextXAlignment = Enum.TextXAlignment.Left
                button.Parent = DropdownFrame

                local optCorner = Instance.new("UICorner")
                optCorner.CornerRadius = UDim.new(0, 4)
                optCorner.Parent = button

                button.MouseButton1Click:Connect(function()
                    SelectedEggId = egg.ID
                    PersistedSettings.selectedEgg = tostring(SelectedEggId)
                    saveSettings()
                    SelectedEggLabel.Text = "Selected: " .. egg.Name
                end)
            end
        end
        DropdownFrame.CanvasSize = UDim2.new(0, 0, 0, math.max(count * 26, 0))
    end

    updateDropdown("")
    local selectedEggName = "None"
    for _, egg in ipairs(EggList) do
        if tostring(egg.ID) == tostring(SelectedEggId) then
            selectedEggName = egg.Name
            break
        end
    end
    SelectedEggLabel.Text = "Selected: " .. selectedEggName

    SearchBox.Changed:Connect(function(prop)
        if prop == "Text" then
            updateDropdown(SearchBox.Text)
        end
    end)

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
                afkOverlay.Visible = true
                autoHatchMain.Visible = false
            else
                PotatoMode = false
                afkOverlay.Visible = false
                autoHatchMain.Visible = true
            end
        end)
    end

    createUnifiedToggle(hatchFrame, 416, "AFK CPU Reducer", false, function(value) setAfkMode(value) end)

    -- Wrapped in a block purely to keep its locals out of the UI thread's
    -- register budget (Luau caps a function at 200 registers).
    -- `recentCategories` is declared here, at thread scope, because the hatch
    -- panel, the AFK panel and the webhook module all read it.
    local recentCategories = {
        { name = "Huge", entries = recentHuges, color = Color3.fromRGB(100, 255, 100) },
        { name = "Secret", entries = recentSecrets, color = Color3.fromRGB(215, 150, 255) },
        { name = "Titanic", entries = recentTitanics, color = Color3.fromRGB(160, 220, 255) },
        { name = "Gargantuan", entries = recentGargantuans, color = Color3.fromRGB(255, 180, 200) },
    }
    do
    local recentPanel = Instance.new("Frame")
    recentPanel.Name = "RecentHatchesPanel"
    recentPanel.Size = UDim2.new(1, -6, 0, 150)
    recentPanel.Position = UDim2.new(0, 3, 0, 502)
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
                    local variants = {}
                    if entryData.rainbow then table.insert(variants, "Rainbow") end
                    if entryData.golden then table.insert(variants, "Golden") end
                    if entryData.shiny then table.insert(variants, "Shiny") end
                    local variantPrefix = #variants > 0 and ("[" .. table.concat(variants, " + ") .. "] ") or ""
                    label.Text = "- " .. variantPrefix .. tostring(entryData.name)
                    label.TextColor3 = listData.color
                    if entryData.rainbow then
                        label.TextColor3 = Color3.fromRGB(255, 120, 220)
                    elseif entryData.golden then
                        label.TextColor3 = Color3.fromRGB(255, 200, 70)
                    elseif entryData.shiny then
                        label.TextColor3 = Color3.fromRGB(120, 220, 255)
                    end
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
    end

    -- =====================================================================
    -- ISOLATED WEBHOOK MODULE
    -- This entire feature is protected so a webhook/API/UI error cannot
    -- prevent the main script from loading.
    -- =====================================================================
    pcall(function()
        local WebhookURL = PersistedSettings.webhook.url or ""
        local WebhookEnabled = PersistedSettings.webhook.enabled == true
        local WebhookNotify = {
            Huge = PersistedSettings.webhook.notify.Huge ~= false,
            Secret = PersistedSettings.webhook.notify.Secret ~= false,
            Titanic = PersistedSettings.webhook.notify.Titanic ~= false,
            Gargantuan = PersistedSettings.webhook.notify.Gargantuan ~= false
        }
        local WebhookSending = false
        local WebhookInitialized = false
        local WebhookKnownPets = {}

        local function webhookRequest()
            local env = _G
            pcall(function()
                if type(getgenv) == "function" then env = getgenv() end
            end)
            local fn = nil
            if type(env) == "table" then fn = env.request or env.http_request end
            if type(fn) ~= "function" and type(syn) == "table" then fn = syn.request end
            if type(fn) ~= "function" and type(http) == "table" then fn = http.request end
            return type(fn) == "function" and fn or nil
        end

        local function webhookSend(payload)
            local url = tostring(WebhookURL or ""):match("^%s*(.-)%s*$")
            if url == "" then return false, "Webhook URL is empty" end
            local request = webhookRequest()
            if not request then return false, "request function unavailable" end
            local okEncode, body = pcall(function() return HttpService:JSONEncode(payload) end)
            if not okEncode then return false, "JSON encoding failed" end
            local okRequest, response = pcall(function()
                return request({
                    Url = url,
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = body
                })
            end)
            if not okRequest then return false, tostring(response) end
            if type(response) == "table" then
                local status = tonumber(response.StatusCode or response.Status)
                if status and (status < 200 or status >= 300) then
                    return false, "HTTP " .. tostring(status)
                end
            end
            return true
        end

        -- Use the same category logic as the main tracker so webhook counts
        -- exactly match the numbers already shown in the Hatch stats.
        local function petCategory(pet)
            local ok, result = pcall(function()
                return getPetCategory(pet)
            end)
            return ok and result or nil
        end

        local webhookPanel = Instance.new("Frame")
        webhookPanel.Name = "WebhookPanel"
        webhookPanel.Size = UDim2.new(1, -16, 0, 290)
        webhookPanel.Position = UDim2.new(0, 8, 0, 662)
        webhookPanel.BackgroundColor3 = activeTheme.panel
        webhookPanel.BorderSizePixel = 0
        webhookPanel.Parent = hatchFrame
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 8)
        corner.Parent = webhookPanel

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -24, 0, 24)
        title.Position = UDim2.new(0, 12, 0, 8)
        title.BackgroundTransparency = 1
        title.Text = "WEBHOOK NOTIFICATIONS"
        title.TextColor3 = Color3.fromRGB(255,255,255)
        title.Font = Enum.Font.GothamBold
        title.TextSize = 14
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Parent = webhookPanel

        local box = Instance.new("TextBox")
        box.Size = UDim2.new(1, -24, 0, 34)
        box.Position = UDim2.new(0, 12, 0, 38)
        box.BackgroundColor3 = activeTheme.surface
        box.BorderSizePixel = 0
        box.ClearTextOnFocus = false
        box.PlaceholderText = "Paste Discord webhook URL here..."
        box.Text = WebhookURL
        box.TextColor3 = Color3.fromRGB(255,255,255)
        box.Font = Enum.Font.Gotham
        box.TextSize = 11
        box.Parent = webhookPanel
        local boxCorner = Instance.new("UICorner")
        boxCorner.CornerRadius = UDim.new(0, 6)
        boxCorner.Parent = box

        local status = Instance.new("TextLabel")
        status.Size = UDim2.new(1, -24, 0, 18)
        status.Position = UDim2.new(0, 12, 0, 76)
        status.BackgroundTransparency = 1
        status.Text = "Webhook is OFF"
        status.TextColor3 = activeTheme.muted
        status.Font = Enum.Font.Gotham
        status.TextSize = 10
        status.TextXAlignment = Enum.TextXAlignment.Left
        status.Parent = webhookPanel

        local enable = Instance.new("TextButton")
        enable.Size = UDim2.new(1, -24, 0, 30)
        enable.Position = UDim2.new(0, 12, 0, 98)
        enable.BackgroundColor3 = activeTheme.surface
        enable.BorderSizePixel = 0
        enable.Text = "Webhook: OFF"
        enable.TextColor3 = Color3.fromRGB(255,255,255)
        enable.Font = Enum.Font.GothamBold
        enable.TextSize = 11
        enable.Parent = webhookPanel
        local enableCorner = Instance.new("UICorner")
        enableCorner.CornerRadius = UDim.new(0, 6)
        enableCorner.Parent = enable

        local function updateEnable()
            if WebhookEnabled then
                enable.Text = "Webhook: ON"
                enable.BackgroundColor3 = activeTheme.controlOn
                status.Text = "Webhook is ON"
            else
                enable.Text = "Webhook: OFF"
                enable.BackgroundColor3 = activeTheme.surface
                status.Text = "Webhook is OFF"
            end
        end

        updateEnable()

        enable.MouseButton1Click:Connect(function()
            WebhookURL = tostring(box.Text or ""):match("^%s*(.-)%s*$")
            if not WebhookEnabled and WebhookURL == "" then
                status.Text = "Enter a webhook URL first"
                return
            end
            WebhookEnabled = not WebhookEnabled
            PersistedSettings.webhook.url = WebhookURL
            PersistedSettings.webhook.enabled = WebhookEnabled
            PersistedSettings.webhook.notify = WebhookNotify
            saveSettings()
            updateEnable()
        end)

        local function addToggle(labelText, key, x, y)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(0.47,0,0,28)
            b.Position = UDim2.new(x, x == 0 and 12 or 0, 0, y)
            b.BackgroundColor3 = activeTheme.surface
            b.BorderSizePixel = 0
            b.Font = Enum.Font.GothamSemibold
            b.TextSize = 10
            b.TextColor3 = Color3.fromRGB(255,255,255)
            b.Parent = webhookPanel
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0,6)
            c.Parent = b
            local function redraw()
                b.Text = (WebhookNotify[key] and "ON  -  " or "OFF -  ") .. labelText
            end
            redraw()
            b.MouseButton1Click:Connect(function()
                WebhookNotify[key] = not WebhookNotify[key]
                PersistedSettings.webhook.url = WebhookURL
                PersistedSettings.webhook.enabled = WebhookEnabled
                PersistedSettings.webhook.notify = WebhookNotify
                saveSettings()
                redraw()
            end)
        end
        addToggle("Huges", "Huge", 0, 136)
        addToggle("Secrets", "Secret", 0.53, 136)
        addToggle("Titanics", "Titanic", 0, 168)
        addToggle("Gargantuans", "Gargantuan", 0.53, 168)

        local test = Instance.new("TextButton")
        test.Size = UDim2.new(1,-24,0,34)
        test.Position = UDim2.new(0,12,0,206)
        test.BackgroundColor3 = activeTheme.accent
        test.BorderSizePixel = 0
        test.Text = "Send Test Webhook"
        test.TextColor3 = Color3.fromRGB(255,255,255)
        test.Font = Enum.Font.GothamBold
        test.TextSize = 11
        test.Parent = webhookPanel
        local testCorner = Instance.new("UICorner")
        testCorner.CornerRadius = UDim.new(0,6)
        testCorner.Parent = test

        local function numberText(v)
            return tostring(v or 0)
        end

        local function readCounter(label)
            local text = tostring(label and label.Text or "0")
            local raw = string.match(text, "(%d[%d,]*)") or "0"
            local value = tonumber((string.gsub(raw, ",", ""))) or 0
            return value
        end

        local function getCurrentTotals()
            return {
                Huge = readCounter(hugeLabel),
                Secret = readCounter(secretLabel),
                Titanic = readCounter(titanicLabel),
                Gargantuan = readCounter(gargantuanLabel)
            }
        end

        local function makePayload(testMessage, category, petName, totals, pet)
            local fields = {
                {name="Huges", value="**"..numberText(totals.Huge).."**", inline=true},
                {name="Secrets", value="**"..numberText(totals.Secret).."**", inline=true},
                {name="Titanics", value="**"..numberText(totals.Titanic).."**", inline=true},
                {name="Gargantuans", value="**"..numberText(totals.Gargantuans or totals.Gargantuan).."**", inline=true}
            }

            -- Rarity line. A rainbow pet takes the headline colour, because that
            -- is the hatch you actually care about being pinged for.
            local variantText = nil
            local embedColor = 5793266 -- default green
            if pet then
                local tags = {}
                if pet.rainbow then
                    table.insert(tags, "Rainbow")
                    embedColor = 16711935 -- magenta
                end
                if pet.golden then
                    table.insert(tags, "Golden")
                    if not pet.rainbow then embedColor = 15844367 end
                end
                if pet.shiny then
                    table.insert(tags, "Shiny")
                    if not pet.rainbow and not pet.golden then embedColor = 65495 end
                end
                if #tags > 0 then
                    variantText = table.concat(tags, "  +  ")
                end
            end

            -- Running variant subtotals across every tier, so the embed tells
            -- you "20 rainbow huges owned" and not just this one hatch.
            local vlines = {}
            local order = {
                {"Huges", "Huges"},
                {"Titanics", "Titanics"},
                {"Gargantuans", "Gargantuans"},
                {"Secrets", "Secrets"},
            }
            for _, pair in ipairs(order) do
                local base = pair[1]
                local rb = variantCounts[base] or 0
                local gd = variantCounts[base .. "Golden"] or 0
                local sh = variantCounts[base .. "Shiny"] or 0
                if rb > 0 or gd > 0 or sh > 0 then
                    table.insert(vlines, ("%s â€” R:%d  G:%d  S:%d"):format(pair[2], rb, gd, sh))
                end
            end
            local variantBlock = #vlines > 0 and ("\n\n**Variants owned**\n" .. table.concat(vlines, "\n")) or ""

            local desc = testMessage and "Your rare-pet webhook is connected."
                or ("## " .. tostring(petName or "Unknown Pet"))
            if variantText then
                desc = desc .. "\n" .. variantText
            end
            desc = desc .. variantBlock

            return {
                username="Pet Dimensions Hub",
                embeds={{
                    title=testMessage and "Webhook Test" or ("New "..tostring(category).."!"),
                    description=desc,
                    color=embedColor,
                    fields=fields,
                    footer={text="Pet Dimensions Hub - Rare Hatch Tracker"},
                    timestamp=os.date("!%Y-%m-%dT%H:%M:%SZ")
                }}
            }
        end


        box.FocusLost:Connect(function()
            WebhookURL = tostring(box.Text or ""):match("^%s*(.-)%s*$")
            PersistedSettings.webhook.url = WebhookURL
            PersistedSettings.webhook.enabled = WebhookEnabled
            PersistedSettings.webhook.notify = WebhookNotify
            saveSettings()
        end)

        test.MouseButton1Click:Connect(function()
            if WebhookSending then return end
            WebhookURL = tostring(box.Text or ""):match("^%s*(.-)%s*$")
            PersistedSettings.webhook.url = WebhookURL
            saveSettings()
            if WebhookURL == "" then status.Text="Enter a webhook URL first" return end
            WebhookSending=true
            test.Text="Sending..."
            task.spawn(function()
                local ok, result = pcall(function()
                    return webhookSend(makePayload(true,nil,nil,getCurrentTotals()))
                end)
                WebhookSending=false
                test.Text="Send Test Webhook"
                status.Text=(ok and result==true) and "Test webhook sent successfully" or ("Test failed: "..tostring(result or "unknown error"))
            end)
        end)

        -- Read the full inventory directly. The recent UI lists are capped at
        -- five entries per tier, so a burst of hatches could evict a pet before
        -- the old three-second webhook poll saw it. Inventory keys also avoid
        -- confusing two pets of the same species as one pet.
        local pendingWebhooks = {}
        local function readRareInventory()
            if not Save or type(Save.Get) ~= "function" then return nil end
            local ok, inventory = pcall(function()
                local save = Save.Get()
                return save and save.Pets
            end)
            return ok and type(inventory) == "table" and inventory or nil
        end

        task.spawn(function()
            while ui.Parent do
                local inventory = readRareInventory()
                if inventory then
                    for petKey, pet in pairs(inventory) do
                        if type(pet) == "table" then
                            local category = petCategory(pet)
                            if category then
                                local uid = tostring(pet.uid or petKey)
                                if not WebhookKnownPets[uid] then
                                    WebhookKnownPets[uid] = true
                                    if WebhookInitialized and WebhookEnabled and WebhookNotify[category] then
                                        table.insert(pendingWebhooks, {
                                            category = category,
                                            name = tostring(getPetDisplayName(pet) or "Unknown Pet"),
                                            rainbow = pet.r == true,
                                            golden = pet.g == true,
                                            shiny = pet.sh == true,
                                            nickname = pet.nk,
                                        })
                                    end
                                end
                            end
                        end
                    end
                    WebhookInitialized = true
                end

                -- Drain one event at a time and retain it if delivery fails.
                -- The test button shares this lock to prevent overlapping posts.
                if #pendingWebhooks > 0 and not WebhookSending then
                    local item = pendingWebhooks[1]
                    WebhookSending = true
                    local ok, sent, err = pcall(function()
                        return webhookSend(makePayload(false, item.category, item.name, getCurrentTotals(), item))
                    end)
                    WebhookSending = false
                    if ok and sent then
                        table.remove(pendingWebhooks, 1)
                    else
                        warn("[Pet Hub] Webhook delivery failed: " .. tostring(ok and err or sent))
                        task.wait(5)
                    end
                end
                task.wait(1)
            end
        end)
    end)

    -- Apply saved toggle states only after every toggle has been created.
    -- This is important for AFK CPU Reducer and Auto-Hatch because their
    -- callbacks depend on UI/functions that are created later in the script.
    --
    -- AFK CPU Reducer is deliberately EXEMPT. Restoring it made the script open
    -- straight into the full-screen AFK overlay with the hub hidden, so every
    -- execute looked like it had thrown the UI away. It also resets the
    -- session counters and forces PotatoMode on, which is a behavioural change
    -- you should never inherit silently from a previous run. It still saves
    -- like every other toggle, it just never auto-restores.
    local AFK_TOGGLE = "AFK CPU Reducer"
    for key, callback in pairs(toggleCallbacks) do
        if key ~= AFK_TOGGLE and CurrentToggleStates[key] == true then
            pcall(callback, true)
            if toggleRegistry[key] then
                for _, syncFunc in ipairs(toggleRegistry[key]) do
                    pcall(syncFunc, true)
                end
            end
        end
    end

    afkExit.MouseButton1Click:Connect(function()
        setAfkMode(false)
        if toggleRegistry["AFK CPU Reducer"] then
            for _, syncFunc in ipairs(toggleRegistry["AFK CPU Reducer"]) do
                syncFunc(false)
            end
        end
    end)

    -- AFK RARE PETS PANEL
    do
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
                    label.Text = "- " .. tostring(entryData.name)
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

-- AUTO-HATCH
-- The game already ships a complete auto-hatch driver in
-- `Scripts.Game.Auto Hatch`: it runs on a 0.1s tick, gates on
-- `Library.Variables.OpeningEgg <= 0`, keeps its own 0.8s cooldown and calls
-- `Library.Network.Invoke("BuyX Egg", eggId)` (NOT "Buy Egg"). The old version
-- of this script fired "Buy Egg" every 0.2s *and* set the same variables, so it
-- raced the game's own loop - two concurrent buy requests, "too quickly"
-- rejections, doubled egg-open FX and a frame-rate hit every hatch.
--
-- Now we drive the engine instead of duplicating it:
--   * primary path  - set AutoHatchEnabled / AutoHatchEggId and let the game buy
--   * fallback path - only when the account has no Auto Hatch gamepass, run a
--                     "BuyX Egg" loop with the game's own 0.8s cadence and the
--                     same OpeningEgg gate
--   * watchdog      - re-asserts the variables if anything clears them, and
--                     backs off instead of hammering on hard failures
local function ownsAutoHatchGamepass()
    local ok, pass = pcall(function()
        local entry = Library.Directory.Gamepasses["Auto Hatch"]
        return entry and Library.Gamepasses.Owns(entry.ID)
    end)
    return ok and pass == true
end

local function hatchViaBuyX()
    if os.clock() < HatchCooldownUntil then return end
    if (tonumber(Library.Variables.OpeningEgg) or 0) > 0 then return end
    local ok, canAct = pcall(function() return Library.WorldCmds.CanDoAction() end)
    if ok and canAct == false then return end

    HatchCooldownUntil = os.clock() + 0.8
    local invoked, result, err = pcall(function()
        return Library.Network.Invoke("BuyX Egg", SelectedEggId)
    end)

    if not invoked then
        HatchFailures += 1
    elseif result == true then
        HatchFailures = 0
        HatchLastEgg = os.clock()
        HatchWatchdogStatus = "hatching via BuyX Egg"
    elseif type(err) == "string" and err:find("too quickly") then
        -- Expected back-pressure from the server. Silent, but back off a little
        -- harder so a rejected request cannot snowball into a retry storm.
        HatchCooldownUntil = os.clock() + 1.0
    else
        HatchFailures += 1
        HatchWatchdogStatus = "buy failed: " .. tostring(err)
    end

    if HatchFailures >= 5 then
        HatchCooldownUntil = os.clock() + 10
        HatchFailures = 0
    end
end

local function pushHatchState()
    pcall(function()
        Library.Variables.AutoHatchEggId = SelectedEggId
        Library.Variables.AutoHatchEnabled = true
    end)
end

local function clearHatchState()
    pcall(function()
        Library.Variables.AutoHatchEggId = nil
        Library.Variables.AutoHatchEnabled = false
    end)
end

local ownsPassCached, ownsPassRefreshAt = false, 0
task.spawn(function()
    local wasOn = false
    while true do
        if AutoBuying and SelectedEggId then
            wasOn = true
            pushHatchState()
            if os.clock() >= ownsPassRefreshAt then
                ownsPassCached = ownsAutoHatchGamepass()
                ownsPassRefreshAt = os.clock() + 10
            end
            if ownsPassCached then
                HatchWatchdogStatus = "auto hatch running (engine)"
                task.wait(1)
            else
                -- No gamepass: we are the driver. hatchViaBuyX enforces the
                -- game's 0.8s server cooldown itself, so poll quickly instead
                -- of sleeping a full second between attempts.
                hatchViaBuyX()
                task.wait(0.1)
            end
        else
            -- Only touch the engine state on the transition, so a hatch the
            -- player started from the game's own UI is not fought over.
            if wasOn then
                clearHatchState()
                wasOn = false
            end
            HatchWatchdogStatus = "Idle"
            task.wait(0.5)
        end
    end
end)

-- Keep the toggle in sync with the real engine state so the UI never lies.
task.spawn(function()
    while true do
        if AutoBuying then
            if Library.Variables.AutoHatchEggId ~= SelectedEggId
                or Library.Variables.AutoHatchEnabled ~= true then
                pushHatchState()
            end
        end
        task.wait(3)
    end
end)

local function setAutoHatchState(enabled)
    AutoBuying = enabled
    if enabled then
        pushHatchState()
    else
        clearHatchState()
    end
end


    -- Rebind the toggle to the real hatch state instead of only changing the
    -- custom AutoBuying flag.
    createUnifiedToggle(hatchFrame, 458, "Auto-Hatch Egg", false, function(value)
        setAutoHatchState(value)
    end)

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
    tpTip.Text = "Only teleport to the spots in the same world as you are currently in. It will glitch if you teleport to a different world."
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
        button.Text = "Teleport to " .. name
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
    createTeleportButton(tpScroll, "Tech Last Area", {-5328, 18, 9626})

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

    saveSettings()

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
    themeLabel.Size = UDim2.new(0.6, 0, 0, 20)
    themeLabel.Position = UDim2.new(0, 0, 0, 100)
    themeLabel.BackgroundTransparency = 1
    themeLabel.Text = "Select UI Theme:"
    themeLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    themeLabel.Font = Enum.Font.GothamBold
    themeLabel.TextSize = 13
    themeLabel.TextXAlignment = Enum.TextXAlignment.Left
    themeLabel.Parent = settingsFrame

    -- Row registry + counter, declared before the loop that fills them.
    themeRows = {}
    local themeIndex = 0

    -- Search box. With 56 themes a flat list needs scrolling past half the
    -- alphabet to reach anything.
    local themeSearch = Instance.new("TextBox")
    themeSearch.Size = UDim2.new(1, 0, 0, 30)
    themeSearch.Position = UDim2.new(0, 0, 0, 122)
    themeSearch.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
    themeSearch.BorderSizePixel = 0
    themeSearch.ClearTextOnFocus = false
    themeSearch.Text = ""
    themeSearch.PlaceholderText = "Search themes..."
    themeSearch.TextColor3 = Color3.fromRGB(255, 255, 255)
    themeSearch.Font = Enum.Font.Gotham
    themeSearch.TextSize = 12
    themeSearch.Parent = settingsFrame
    do local _c = Instance.new("UICorner") _c.CornerRadius = UDim.new(0, 6) _c.Parent = themeSearch end
    do local _s = Instance.new("UIStroke") _s.Color = Color3.fromRGB(80, 80, 100) _s.Thickness = 1
        _s.Transparency = 0.7 _s.Parent = themeSearch end

    themeScroll = Instance.new("ScrollingFrame")
    themeScroll.Size = UDim2.new(1, 0, 1, -186)
    themeScroll.Position = UDim2.new(0, 0, 0, 158)
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

    -- Built as its own function, NOT inline at thread scope. The UI thread is
    -- already at Luau's 200-register cap; adding this loop's locals (row,
    -- swatches, chip, tLabel, check, tStroke, ...) at thread scope stops the
    -- entire script from compiling. A `do` block is not enough here - only a
    -- real function body gets its own register budget.
    local function buildThemeRows()
    for _, themeObj in ipairs(Themes) do
        local row = Instance.new("TextButton")
        row.Name = "ThemeRow"
        row.LayoutOrder = themeIndex
        row.Size = UDim2.new(1, -8, 0, 38)
        row.BackgroundColor3 = themeObj.background
        row.Text = ""
        row.TextColor3 = themeObj.text
        row.Font = Enum.Font.GothamBold
        row.TextSize = 12
        row.TextXAlignment = Enum.TextXAlignment.Left
        row:SetAttribute("ThemePreview", true)
        row:SetAttribute("ThemeName", themeObj.name)
        row.Parent = themeScroll

        local rowCorner = Instance.new("UICorner")
        rowCorner.CornerRadius = UDim.new(0, 7)
        rowCorner.Parent = row

        -- Each row is painted with the theme it represents: its own background,
        -- four real colour chips for the palette, and a border in the accent.
        -- That replaces a flat list of grey buttons where every entry looked
        -- identical until you clicked it and the whole window changed.
        local swatches = { "surface", "accent", "controlOn", "danger" }
        for index, key in ipairs(swatches) do
            local chip = Instance.new("Frame")
            chip.Name = "Chip"
            chip.LayoutOrder = index
            chip.Size = UDim2.new(0, 16, 0, 16)
            chip.Position = UDim2.new(0, 8 + (index - 1) * 20, 0.5, -8)
            chip.BackgroundColor3 = themeObj[key]
            chip.BorderSizePixel = 0
            chip.Parent = row
            local chipCorner = Instance.new("UICorner")
            chipCorner.CornerRadius = UDim.new(1, 0)
            chipCorner.Parent = chip
            local chipStroke = Instance.new("UIStroke")
            chipStroke.Color = themeObj.stroke
            chipStroke.Thickness = 1
            chipStroke.Transparency = 0.45
            chipStroke.Parent = chip
        end

        local tLabel = Instance.new("TextLabel")
        tLabel.Name = "Name"
        tLabel.Size = UDim2.new(1, -108, 1, 0)
        tLabel.Position = UDim2.new(0, 98, 0, 0)
        tLabel.BackgroundTransparency = 1
        tLabel.Text = themeObj.name
        tLabel.TextColor3 = themeObj.text
        tLabel.Font = Enum.Font.GothamBold
        tLabel.TextSize = 12
        tLabel.TextXAlignment = Enum.TextXAlignment.Left
        tLabel.TextTruncate = Enum.TextTruncate.AtEnd
        tLabel.Parent = row

        local tStroke = Instance.new("UIStroke")
        tStroke.Name = "Ring"
        tStroke.Color = themeObj.accent
        tStroke.Thickness = 1
        tStroke.Transparency = 0.55
        tStroke.Parent = row

        -- Selected marker, shown only on the active theme.
        local check = Instance.new("TextLabel")
        check.Name = "Check"
        check.Size = UDim2.fromOffset(22, 22)
        check.Position = UDim2.new(1, -28, 0.5, -11)
        check.BackgroundTransparency = 1
        check.Text = "âœ“"
        check.TextColor3 = themeObj.accent
        check.Font = Enum.Font.GothamBold
        check.TextSize = 15
        check.Visible = false
        check.Parent = row

        themeRows[themeObj.name] = { row = row, check = check, stroke = tStroke, label = tLabel }
        themeIndex += 1

        row.MouseButton1Click:Connect(function()
            applyTheme(themeObj)
        end)
        row.MouseEnter:Connect(function()
            tStroke.Transparency = 0.1
            tStroke.Thickness = 1.6
        end)
        row.MouseLeave:Connect(function()
            local isActive = (CurrentThemeName == themeObj.name)
            tStroke.Transparency = isActive and 0 or 0.55
            tStroke.Thickness = isActive and 2 or 1
        end)
    end
    end
    buildThemeRows()

    -- Filter the list by name. Reorders rather than hides-and-reflows so the
    -- row order stays stable while typing.
    local function filterThemes()
        local query = string.lower(tostring(themeSearch.Text or ""))
        query = string.gsub(query, "^%s+", "")
        query = string.gsub(query, "%s+$", "")
        local shown = 0
        local order = 0
        for _, entry in pairs(themeRows) do
            local name = tostring(entry.row:GetAttribute("ThemeName") or "")
            local match = (query == "") or (string.find(string.lower(name), query, 1, true) ~= nil)
            entry.row.Visible = match
            if match then
                order += 1
                entry.row.LayoutOrder = order
                shown += 1
            end
        end
        themeLabel.Text = (query == "")
            and (("%d themes"):format(shown))
            or (("%d / %d"):format(shown, #Themes))
    end
    themeSearch:GetPropertyChangedSignal("Text"):Connect(filterThemes)
    filterThemes()

    -- Apply the saved theme only after every UI element has been created
    -- from the Default Dark base. Non-button/detail elements therefore stay
    -- at their original dark colors instead of inheriting a previous theme.
    --
    -- Wrapped in a function purely for the register budget: this thread is at
    -- Luau's 200-local limit, and even this two-line loop's `themeObj` local
    -- pushed it over. (buildThemeRows has the same reason for being a function.)
    local function applySavedTheme()
        for _, themeObj in ipairs(Themes) do
            if themeObj.name == savedThemeName then
                applyTheme(themeObj)
                return
            end
        end
    end
    applySavedTheme()
	end)


-- AUTO LOOTBAG + ORB PICKUP
-- Uses the existing game network API; loops remain isolated and guarded.
pcall(function()
    local AutoPickupLootbags = Library.Things:FindFirstChild("Lootbags")
    local AutoPickupOrbs = Library.Things:FindFirstChild("Orbs")
    local AutoPickupLootbagSent = {}

    -- Lootbags: use the same network request as the game's Lootbags module.
    task.spawn(function()
        while true do
            if AutoPickupLootbags then
                for _, lootbag in ipairs(AutoPickupLootbags:GetChildren()) do
                    pcall(function()
                        local ready = lootbag:FindFirstChild("ReadyForCollection_Attr")
                        ready = ready and ready.Value or lootbag:GetAttribute("ReadyForCollection")
                        if ready then
                            local idValue = lootbag:FindFirstChild("ID_Attr")
                            local id = idValue and idValue.Value or lootbag:GetAttribute("ID")
                            if id ~= nil and not AutoPickupLootbagSent[lootbag] then
                                AutoPickupLootbagSent[lootbag] = true
                                Library.Network.Fire("Collect Lootbag", id, lootbag.CFrame.Position)
                            end
                        end
                    end)
                end

                for lootbag in pairs(AutoPickupLootbagSent) do
                    if not lootbag or not lootbag.Parent then
                        AutoPickupLootbagSent[lootbag] = nil
                    end
                end
                task.wait(0.2)
            else
                task.wait(1)
            end
        end
    end)

    -- Orbs: send the visible orb IDs in the same batched request used by the
    -- game. Orbs only change on world events, so a 1 Hz poll is plenty and the
    -- old 0.25 s poll was pure overhead.
    task.spawn(function()
        local lastBatch = ""
        while true do
            if AutoPickupOrbs then
                local ids, batch = {}, ""
                for _, orb in ipairs(AutoPickupOrbs:GetChildren()) do
                    if orb and orb.Parent and orb.Name ~= "" then
                        table.insert(ids, orb.Name)
                        batch ..= orb.Name .. ","
                    end
                end
                if #ids > 0 and batch ~= lastBatch then
                    lastBatch = batch
                    pcall(function()
                        Library.Network.Fire("Claim Orbs", ids)
                    end)
                end
                task.wait(1)
            else
                task.wait(1)
            end
        end
    end)
end)




