-- =====================================================================
-- COMBINED AUTOMATION SCRIPT: UNIFIED UI + FIXED AUTO TOKENS + BOSS DODGE
-- HATCH LOGIC + EGG CHANCE VIEWER + AUTO FARM & PET TRACKER + EXTENDED THEMES
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
    }
}

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

local function saveSettings()
    if type(writefile) ~= "function" then return end
    pcall(function()
        writefile(SettingsFile, HttpService:JSONEncode({
            version = 2,
            theme = CurrentThemeName,
            key = CurrentKeyName,
            toggles = CurrentToggleStates,
            selectedEgg = PersistedSettings.selectedEgg,
            webhook = PersistedSettings.webhook,
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
local AutoFarmExpedition = false
local AutoTap = false
local AutoTeleportClosestCoin = false
local AntiAFK = false
local AntiAFKIntervalMinutes = 1
local AutoFarmHackerBoss = false
local AutoTokens = false
local PotatoMode = false
local AutoFarmComet = false
local AutoTrickOrTreat = false
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
local LastPetSendTarget = nil
local CurrentExpeditionTarget = nil
local CurrentExpeditionTargetId = nil
local LastExpeditionPetSendTarget = nil
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

-- TURKEY DODGE VARIABLES
local TurkeyDodgeActive = false
local IsEvading = false

-- EXPEDITION DODGE VARIABLES
local ExpeditionDodgeEnabled = true
local ExpeditionDodgeActive = false
local ExpeditionDodgeSavedCFrame = nil
local ExpeditionDodgeUntil = 0
local ExpeditionAttackSequence = 0
local ExpeditionActiveAttacks = {}
local ExpeditionCombatRadius = 10.5
local ExpeditionDodgeMargin = 1.75
local ExpeditionFloorHeight = 3

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
    -- targets used by the Expedition and Turkey farms.
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

local function FindHackerBoss()
    local coins = Workspace:FindFirstChild("__THINGS") and Workspace.__THINGS:FindFirstChild("Coins")
    if not coins then return nil end

    for _, child in ipairs(coins:GetChildren()) do
        if child.Parent then
            local name = tostring(child:GetAttribute("Name") or child:GetAttribute("Mob") or child.Name):lower()
            if name == "hacker prime" or name == "hacker boss" or name:find("hacker prime", 1, true) then
                local id = child:GetAttribute("ID")
                if id ~= nil then
                    return child
                end
            end
        end
    end

    return nil
end
-- Expedition mobs live in the same Coins container while an expedition is
-- running. Unlike robots/turkey, there is no fixed mob name to rely on, so
-- choose randomly from the currently spawned expedition coins.
local function IsExpeditionMob(coin)
    if not coin or not coin.Parent then return false end
    if not localPlayer:GetAttribute("ExpeditionRun") then return false end

    local id = coin:GetAttribute("ID")
    if id == nil then return false end

    -- Expedition coins should have health and a rendered Coin part.
    -- Ignore non-mob/placeholder objects that happen to be in Coins.
    local health = coin:GetAttribute("Health")
    local coinPart = coin:FindFirstChild("Coin")
    if health == nil or not coinPart then return false end

    if coinPart:GetAttribute("PreventClick") then return false end
    return true
end

local function FindRandomExpeditionMob(previous)
    local coinsFolder = Workspace:FindFirstChild("__THINGS")
        and Workspace.__THINGS:FindFirstChild("Coins")
    if not coinsFolder or not localPlayer:GetAttribute("ExpeditionRun") then
        return nil
    end

    local candidates = {}
    for _, coin in ipairs(coinsFolder:GetChildren()) do
        if IsExpeditionMob(coin) and coin ~= previous then
            table.insert(candidates, coin)
        end
    end

    -- If only one mob is alive, allow it to be selected again after the
    -- previous target disappears/reappears.
    if #candidates == 0 and previous and IsExpeditionMob(previous) then
        table.insert(candidates, previous)
    end

    if #candidates == 0 then return nil end
    return candidates[math.random(1, #candidates)]
end
-- EXPEDITION ATTACK DODGE
-- Uses the same attack event consumed by the AutumnBoss client controller.
-- We do not rely on __AUTUMNBOSS_FX, because the attack event contains the
-- actual telegraph parameters and some attacks can exist without visible FX.
local function GetExpeditionCombatPosition()
    local target = CurrentExpeditionTarget
    if target and target.Parent then
        local coinPart = target:FindFirstChild("Coin")
        if coinPart and coinPart:IsA("BasePart") then
            return coinPart.Position
        end
        return target:GetPivot().Position
    end

    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position or nil
end

local function ExpeditionGroundedPosition(position, character)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {
        character,
        Workspace:FindFirstChild("__THINGS"),
        Workspace:FindFirstChild("__DEBRIS"),
    }
    rayParams.IgnoreWater = true

    local origin = position + Vector3.new(0, 60, 0)
    local hit = Workspace:Raycast(origin, Vector3.new(0, -140, 0), rayParams)
    if not hit then
        return nil
    end

    return hit.Position + Vector3.new(0, ExpeditionFloorHeight, 0)
end

local function NormalizeAngle(angle)
    local twoPi = math.pi * 2
    angle = angle % twoPi
    if angle < 0 then
        angle += twoPi
    end
    return angle
end

local function AngleOnArc(angle, startAngle, arcAngle)
    if arcAngle >= math.pi * 2 - 0.001 then
        return true
    end

    local delta = NormalizeAngle(angle - startAngle)
    return delta <= arcAngle
end

local function IsPointInSweep(point, attack, now)
    local at = attack.at
    if typeof(at) ~= "Vector3" then
        return false
    end

    local length = tonumber(attack.length) or 100
    local width = tonumber(attack.width) or 6
    local clear = tonumber(attack.clear) or 0
    local startAngle = math.rad(tonumber(attack.start) or 0)
    local arc = math.rad(tonumber(attack.arc) or 360)
    local windup = tonumber(attack.windup) or 1
    local seconds = math.max(0.05, tonumber(attack.seconds) or 2)

    local elapsed = now - attack.started
    if elapsed < windup then
        return false
    end

    local progress = math.clamp((elapsed - windup) / seconds, 0, 1)
    local currentAngle = startAngle + arc * progress

    local dx = point.X - at.X
    local dz = point.Z - at.Z
    local distance = math.sqrt(dx * dx + dz * dz)
    if distance < clear or distance > length then
        return false
    end

    local direction = Vector3.new(math.cos(currentAngle), 0, math.sin(currentAngle))
    local relative = Vector3.new(dx, 0, dz)
    local forward = relative:Dot(direction)
    local sideways = math.abs(relative:Cross(direction).Y)

    return forward >= clear and forward <= length and sideways <= width
end

local function IsPointDangerous(point, now)
    for _, attack in ipairs(ExpeditionActiveAttacks) do
        if attack and attack.expires > now then
            if attack.kind == "slam" or attack.kind == "barrage" or attack.kind == "leap" or attack.kind == "land" then
                local at = attack.at
                local radius = tonumber(attack.radius) or 0
                if typeof(at) == "Vector3" then
                    local dx = point.X - at.X
                    local dz = point.Z - at.Z
                    if math.sqrt(dx * dx + dz * dz) <= radius + ExpeditionDodgeMargin then
                        return true
                    end
                end
            elseif attack.kind == "sweep" and IsPointInSweep(point, attack, now) then
                return true
            end
        end
    end

    return false
end

local function GetSafeExpeditionDodgeCFrame(character, now)
    local combatCenter = GetExpeditionCombatPosition()
    if not combatCenter then
        return nil
    end

    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then
        return nil
    end

    local current = hrp.Position
    local candidates = {}

    -- Try the current position first if the attack has not reached it yet.
    table.insert(candidates, Vector3.new(current.X, combatCenter.Y, current.Z))

    -- Sample the entire local combat ring. This keeps the player inside the
    -- Expedition arena while looking for a point outside the attack shape.
    for i = 0, 47 do
        local angle = (math.pi * 2) * (i / 48)
        local radius = ExpeditionCombatRadius
        table.insert(candidates, combatCenter + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))

        local innerRadius = math.max(3, ExpeditionCombatRadius - 2.5)
        table.insert(candidates, combatCenter + Vector3.new(math.cos(angle) * innerRadius, 0, math.sin(angle) * innerRadius))
    end

    local best = nil
    local bestScore = math.huge

    for _, candidate in ipairs(candidates) do
        local horizontal = Vector3.new(candidate.X - combatCenter.X, 0, candidate.Z - combatCenter.Z)
        if horizontal.Magnitude <= ExpeditionCombatRadius + 0.01 then
            local grounded = ExpeditionGroundedPosition(candidate, character)
            if grounded then
                if not IsPointDangerous(grounded, now) then
                    local moveDistance = (grounded - current).Magnitude
                    if moveDistance < bestScore then
                        best = grounded
                        bestScore = moveDistance
                    end
                end
            end
        end
    end

    if not best then
        return nil
    end

    return CFrame.lookAt(
        best,
        Vector3.new(combatCenter.X, best.Y, combatCenter.Z)
    )
end

local function BeginExpeditionDodge()
    if ExpeditionDodgeActive then
        return
    end

    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then
        return
    end

    local safe = GetSafeExpeditionDodgeCFrame(character, os.clock())
    if not safe then
        return
    end

    ExpeditionDodgeSavedCFrame = hrp.CFrame
    ExpeditionDodgeActive = true
    hrp.CFrame = safe
end

local function EndExpeditionDodge()
    if not ExpeditionDodgeActive then
        return
    end

    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")

    if hrp and ExpeditionDodgeSavedCFrame then
        hrp.CFrame = ExpeditionDodgeSavedCFrame
    end

    ExpeditionDodgeActive = false
    ExpeditionDodgeSavedCFrame = nil
end

-- The boss client uses this exact event to receive the attack parameters.
-- Expedition reuses the same Autumn attack system.
pcall(function()
    Library.Network.Fired("Autumn Boss: Attack"):Connect(function(attack)
        if not ExpeditionDodgeEnabled or not AutoFarmExpedition then
            return
        end
        if type(attack) ~= "table" or not attack.kind then
            return
        end

        local kind = tostring(attack.kind)
        if kind ~= "slam" and kind ~= "barrage" and kind ~= "sweep" and kind ~= "leap" and kind ~= "land" then
            return
        end

        local now = os.clock()
        local windup = tonumber(attack.windup) or 0
        local duration

        if kind == "sweep" then
            duration = windup + math.max(0.05, tonumber(attack.seconds) or 2) + 0.35
        elseif kind == "leap" then
            duration = windup + math.max(0, tonumber(attack.air) or 1) + 0.7
        elseif kind == "land" then
            duration = 0.9
        else
            duration = windup + 0.8
        end

        ExpeditionAttackSequence += 1
        table.insert(ExpeditionActiveAttacks, {
            kind = kind,
            at = attack.at,
            radius = attack.radius,
            length = attack.length,
            width = attack.width,
            clear = attack.clear,
            start = attack.start,
            arc = attack.arc,
            windup = windup,
            seconds = attack.seconds,
            started = now,
            expires = now + duration,
            sequence = ExpeditionAttackSequence,
        })
        ExpeditionDodgeUntil = math.max(ExpeditionDodgeUntil, now + duration)
    end)
end)

-- Continuously maintain the safe position while an attack is active. This
-- is intentionally independent from the visible FX folder.
task.spawn(function()
    while true do
        task.wait(0.025)

        local now = os.clock()
        for i = #ExpeditionActiveAttacks, 1, -1 do
            local attack = ExpeditionActiveAttacks[i]
            if not attack or attack.expires <= now then
                table.remove(ExpeditionActiveAttacks, i)
            end
        end

        if not AutoFarmExpedition or not ExpeditionDodgeEnabled or #ExpeditionActiveAttacks == 0 then
            if ExpeditionDodgeActive then
                EndExpeditionDodge()
            end
            continue
        end

        local character = localPlayer.Character
        local hrp = character and character:FindFirstChild("HumanoidRootPart")
        if not hrp then
            EndExpeditionDodge()
            continue
        end

        -- Before the telegraph resolves, we can wait. Once the player's
        -- current position becomes dangerous, move immediately to a safe
        -- point inside the combat radius.
        if not IsPointDangerous(hrp.Position, now) then
            if ExpeditionDodgeActive and now >= ExpeditionDodgeUntil then
                EndExpeditionDodge()
            end
            continue
        end

        if not ExpeditionDodgeActive then
            BeginExpeditionDodge()
        else
            -- Recalculate while a sweep is rotating or another attack is
            -- layered on top, preventing the player from walking back into it.
            local safe = GetSafeExpeditionDodgeCFrame(character, now)
            if safe then
                hrp.CFrame = safe
            end
        end
    end
end)

localPlayer.CharacterAdded:Connect(function()
    ExpeditionDodgeActive = false
    ExpeditionDodgeSavedCFrame = nil
    table.clear(ExpeditionActiveAttacks)
end)
local function FocusPetsContinuous(coinInstance)
    if not coinInstance or not coinInstance.Parent then return end

    local coinId = coinInstance:GetAttribute("ID")
    if not coinId then return end

    -- Keep the original Select Coin behavior.
    pcall(function()
        Library.Signal.Fire("Select Coin", coinInstance)
    end)

    -- Send pets using the ORIGINAL sequence, but only once for this
    -- individual robot/turkey.  Do not mark it as sent until the calls
    -- below have actually been attempted.
    if LastPetSendTarget ~= coinInstance then
        local myPets = GetAllEquippedPetUIDs()
        if #myPets == 0 then return end

        pcall(function()
            Library.Network.Invoke("Join Coin", coinId, myPets)
        end)

        for _, petUid in ipairs(myPets) do
            pcall(function()
                Library.Network.Fire("Change Pet Target", petUid, "Coin", coinId)
            end)
        end

        LastPetSendTarget = coinInstance
    end
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
            elseif AutoFarmHackerBoss then
                targetId = CurrentHackerBossId
            elseif AutoFarmExpedition then
                targetId = CurrentExpeditionTargetId
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

-- Expedition Auto Farm Loop
-- Picks a random living expedition mob, selects/taps it, and sends the
-- equipped pets once. Damage/Fast Attack can then keep hitting the target.
task.spawn(function()
    while true do
        task.wait(0.15)

        if AutoFarmExpedition and localPlayer:GetAttribute("ExpeditionRun") then
            if not CurrentExpeditionTarget or not IsExpeditionMob(CurrentExpeditionTarget) then
                CurrentExpeditionTarget = FindRandomExpeditionMob(CurrentExpeditionTarget)
                CurrentExpeditionTargetId = CurrentExpeditionTarget
                    and tostring(CurrentExpeditionTarget:GetAttribute("ID"))
                    or nil
                LastExpeditionPetSendTarget = nil
            end

            if CurrentExpeditionTarget and IsExpeditionMob(CurrentExpeditionTarget) then
                local targetId = tostring(CurrentExpeditionTarget:GetAttribute("ID"))
                CurrentExpeditionTargetId = targetId

                pcall(function()
                    Library.Signal.Fire("Select Coin", CurrentExpeditionTarget)
                end)

                -- Same original pet-send sequence as robots/turkey, once per
                -- individual expedition mob.
                if LastExpeditionPetSendTarget ~= CurrentExpeditionTarget then
                    local myPets = GetAllEquippedPetUIDs()
                    if #myPets > 0 then
                        pcall(function()
                            Library.Network.Invoke("Join Coin", targetId, myPets)
                        end)

                        for _, petUid in ipairs(myPets) do
                            pcall(function()
                                Library.Network.Fire("Change Pet Target", petUid, "Coin", targetId)
                            end)
                        end

                        LastExpeditionPetSendTarget = CurrentExpeditionTarget
                    end
                end
            else
                CurrentExpeditionTarget = nil
                CurrentExpeditionTargetId = nil
                LastExpeditionPetSendTarget = nil
            end
        else
            CurrentExpeditionTarget = nil
            CurrentExpeditionTargetId = nil
            LastExpeditionPetSendTarget = nil
        end
    end
end)

-- Expedition damage uses the same target as the normal mob farm.
task.spawn(function()
    while true do
        task.wait(0.05)
        if AutoFarmExpedition and CurrentExpeditionTargetId
            and localPlayer:GetAttribute("ExpeditionRun") then
            pcall(function()
                if DamageRemote then
                    DamageRemote:FireServer(CurrentExpeditionTargetId)
                end
            end)
        end
    end
end)

-- EXPEDITION ATTACK DODGE
-- Keep the player close enough that expedition mobs can still target them.
-- The expedition source does not expose a numeric arena radius, so the dodge
-- uses a conservative target-relative radius instead of making large jumps.
local function GetSafeExpeditionDodgeCFrame(hrp, targetPosition)
    local offset = hrp.Position - targetPosition
    local flatOffset = Vector3.new(offset.X, 0, offset.Z)

    if flatOffset.Magnitude < 0.5 then
        flatOffset = Vector3.new(hrp.CFrame.RightVector.X, 0, hrp.CFrame.RightVector.Z)
    end

    if flatOffset.Magnitude < 0.05 then
        flatOffset = Vector3.new(1, 0, 0)
    end

    local radial = flatOffset.Unit
    local perpendicular = Vector3.new(-radial.Z, 0, radial.X)

    -- Alternate sides so repeated attacks do not send the player farther away.
    if math.random(0, 1) == 0 then
        perpendicular = -perpendicular
    end

    local candidate = targetPosition + perpendicular * ExpeditionDodgeRadius

    -- Put the player on actual ground. This prevents the dodge from placing
    -- the HumanoidRootPart in mid-air and falling through the expedition map.
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {localPlayer.Character, CurrentExpeditionTarget}
    rayParams.IgnoreWater = true

    local rayOrigin = candidate + Vector3.new(0, 60, 0)
    local rayResult = Workspace:Raycast(rayOrigin, Vector3.new(0, -140, 0), rayParams)
    if rayResult then
        candidate = rayResult.Position + Vector3.new(0, 3, 0)
    else
        -- If no floor was found, do not perform the teleport at all.
        return nil
    end

    -- Final safety check: never place the player farther than the combat radius.
    local finalOffset = Vector3.new(candidate.X - targetPosition.X, 0, candidate.Z - targetPosition.Z)
    if finalOffset.Magnitude > ExpeditionMaxCombatRadius then
        candidate = targetPosition + finalOffset.Unit * ExpeditionMaxCombatRadius
        local floorCheck = Workspace:Raycast(candidate + Vector3.new(0, 60, 0), Vector3.new(0, -140, 0), rayParams)
        if not floorCheck then
            return nil
        end
        candidate = floorCheck.Position + Vector3.new(0, 3, 0)
    end

    return CFrame.new(candidate, Vector3.new(targetPosition.X, candidate.Y, targetPosition.Z))
end

task.spawn(function()
    while true do
        task.wait(0.05)

        if AutoFarmExpedition then
            local character = localPlayer.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            local fxFolder = Workspace:FindFirstChild("__AUTUMNBOSS_FX")

            if hrp and CurrentExpeditionTarget and CurrentExpeditionTarget.Parent and fxFolder and #fxFolder:GetChildren() > 0 then
                if not ExpeditionIsEvading then
                    local targetPart = CurrentExpeditionTarget:FindFirstChild("Coin")
                    local targetPosition = targetPart and targetPart.Position or CurrentExpeditionTarget:GetPivot().Position
                    local safeDodge = GetSafeExpeditionDodgeCFrame(hrp, targetPosition)

                    if safeDodge then
                        ExpeditionIsEvading = true
                        ExpeditionSavedCFrame = hrp.CFrame
                        hrp.CFrame = safeDodge
                    end
                end
            elseif ExpeditionIsEvading and hrp then
                ExpeditionIsEvading = false
                if ExpeditionSavedCFrame then
                    hrp.CFrame = ExpeditionSavedCFrame
                end
                ExpeditionSavedCFrame = nil
            end
        elseif ExpeditionIsEvading then
            local character = localPlayer.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            if hrp and ExpeditionSavedCFrame then
                hrp.CFrame = ExpeditionSavedCFrame
            end
            ExpeditionIsEvading = false
            ExpeditionSavedCFrame = nil
        end
    end
end)


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

-- Hacker Boss damage loop
task.spawn(function()
    while true do
        task.wait(0.05)
        if AutoFarmHackerBoss and CurrentHackerBossId and DamageRemote then
            pcall(function()
                DamageRemote:FireServer(CurrentHackerBossId)
            end)
        end
    end
end)

-- GENERIC CLOSEST-COIN FARM
-- Target scanning is deliberately separated from attacking. This keeps the
-- expensive Workspace scan from running at the same rate as the hit remotes.
local ClosestCoinScanInterval = 0.10
local ClosestCoinHitInterval = 0.05
local CachedEquippedPets = {}
local CachedPetsRefreshAt = 0
local LastCoinInteractionTarget = nil
local LastCoinTeleportTarget = nil

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
    CachedPetsRefreshAt = now + 0.50
    return CachedEquippedPets
end

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

        task.wait(ClosestCoinScanInterval)
    end
end)

-- Dedicated hit loop. It uses the same direct damage/Farm Coin calls as the
-- existing Expedition/Turkey/Comet attack paths, but avoids rebuilding the
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
        end

        task.wait(ClosestCoinHitInterval)
    end
end)

-- AUTO TRICK OR TREAT
-- Visits every current child under workspace.__TrickOrTreat, presses E once
-- at each location, waits 5 seconds between locations, then waits for the
-- remainder of the 60-second cycle before starting over. The 60-second timer
-- starts when the first teleport/E action of a cycle occurs.
local TrickOrTreatDelay = 5
local TrickOrTreatCycle = 65

local function GetTrickOrTreatPosition(instance)
    if not instance or not instance.Parent then
        return nil
    end

    if instance:IsA("BasePart") then
        return instance.Position
    end

    local ok, pivot = pcall(function()
        return instance:GetPivot()
    end)
    if ok and pivot then
        return pivot.Position
    end

    local part = instance:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

local function TeleportAndPressE(position)
    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp or not position then
        return false
    end

    hrp.CFrame = CFrame.new(position + Vector3.new(0, 3, 0))
    task.wait(1)

    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
        task.wait(0.1)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)

    return true
end

task.spawn(function()
    while true do
        if not AutoTrickOrTreat then
            task.wait(0.25)
        else
            local cycleStart = nil
            local folder = Workspace:FindFirstChild("__TrickOrTreat")

            if folder then
                local children = folder:GetChildren()

                for index, child in ipairs(children) do
                    if not AutoTrickOrTreat then
                        break
                    end

                    local position = GetTrickOrTreatPosition(child)
                    if position then
                        if not cycleStart then
                            cycleStart = os.clock()
                        end

                        TeleportAndPressE(position)

                        if index < #children and AutoTrickOrTreat then
                            local waited = 0
                            while AutoTrickOrTreat and waited < TrickOrTreatDelay do
                                local step = math.min(0.25, TrickOrTreatDelay - waited)
                                task.wait(step)
                                waited = waited + step
                            end
                        end
                    end
                end

                if cycleStart and AutoTrickOrTreat then
                    local remaining = TrickOrTreatCycle - (os.clock() - cycleStart)
                    while AutoTrickOrTreat and remaining > 0 do
                        local step = math.min(0.25, remaining)
                        task.wait(step)
                        remaining = TrickOrTreatCycle - (os.clock() - cycleStart)
                    end
                end
            else
                task.wait(0.5)
            end
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
        if PotatoMode and (AutoFarmRobot or AutoFarmTurkey) and CurrentTarget and CurrentTarget.Parent then
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

-- Keep the known local trigger blocked. This prevents the animation from
-- starting in executors that support metamethod hooks.
pcall(function()
    if type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" and type(newcclosure) == "function" then
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if method == "Fire" and self and self.Name == "PlayTrigger" then
                local parent = self.Parent
                if parent and parent.Name == "EggOpenPort" then
                    return nil
                end
            end
            return oldNamecall(self, ...)
        end))
    end
end)

-- Small fallback cleanup only while Auto-Hatch is active. This runs at 4 Hz
-- instead of every frame and avoids expensive GetDescendants scans.
task.spawn(function()
    while true do
        if AutoBuying then
            cleanupEggOpeningEffects()
            task.wait(0.25)
        else
            task.wait(0.5)
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

    local hatchTab = createTabButton("Hatch", 0)
    local tpTab = createTabButton("Teleport", 0.202)
    local settingsTab = createTabButton("Settings", 0.404)
    local eggTab = createTabButton("Egg Chances", 0.606)
    local farmTab = createTabButton("Farm", 0.808)

    local hatchFrame = Instance.new("ScrollingFrame")
    hatchFrame.Size = UDim2.new(1, -24, 1, -96)
    hatchFrame.Position = UDim2.new(0, 12, 0, 90)
    hatchFrame.BackgroundTransparency = 1
    hatchFrame.BorderSizePixel = 0
    hatchFrame.ClipsDescendants = true
    hatchFrame.ScrollBarThickness = 5
    hatchFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    hatchFrame.CanvasSize = UDim2.new(0, 0, 0, 875)
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
    local toggleCallbacks = {}

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

        local state = CurrentToggleStates[text] == true and true or defaultState
        btn:SetAttribute("ToggleState", state)
        toggleCallbacks[text] = callback

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

    createUnifiedToggle(farmFrame, 326, "💻 Hacker Boss Farm", false, function(state)
        AutoFarmHackerBoss = state
        if not state then
            CurrentHackerBoss = nil
            CurrentHackerBossId = nil
        end
    end)

    createUnifiedToggle(farmFrame, 368, "🍂 Expedition Farm", false, function(state)
        AutoFarmExpedition = state
        if not state then
            CurrentExpeditionTarget = nil
            CurrentExpeditionTargetId = nil
            LastExpeditionPetSendTarget = nil
            ExpeditionActiveAttacks = {}
            ExpeditionDodgeActive = false
            ExpeditionDodgeSavedCFrame = nil
        end
    end)

    createUnifiedToggle(farmFrame, 410, "🎃 Auto Trick or Treating", false, function(state)
        AutoTrickOrTreat = state
    end)

    createUnifiedToggle(farmFrame, 452, "👆 Auto Tap", false, function(state)
        AutoTap = state
        if not state then
            ResetCoinTarget()
        end
    end)

    createUnifiedToggle(farmFrame, 452, "📍 Auto Teleport to Closest Coin", false, function(state)
        AutoTeleportClosestCoin = state
        if not state and not AutoTap then
            ResetCoinTarget()
        end
    end)

    createUnifiedToggle(farmFrame, 494, "🛡️ Anti AFK", false, function(state)
        AntiAFK = state
    end)

    local antiAfkLabel = Instance.new("TextLabel")
    antiAfkLabel.Size = UDim2.new(0.58, 0, 0, 28)
    antiAfkLabel.Position = UDim2.new(0, 0, 0, 578)
    antiAfkLabel.BackgroundTransparency = 1
    antiAfkLabel.Text = "Anti AFK interval (minutes)"
    antiAfkLabel.TextColor3 = Color3.fromRGB(190, 190, 200)
    antiAfkLabel.Font = Enum.Font.GothamBold
    antiAfkLabel.TextSize = 12
    antiAfkLabel.TextXAlignment = Enum.TextXAlignment.Left
    antiAfkLabel.Parent = farmFrame

    local antiAfkBox = Instance.new("TextBox")
    antiAfkBox.Size = UDim2.new(0.32, 0, 0, 28)
    antiAfkBox.Position = UDim2.new(0.68, 0, 0, 578)
    antiAfkBox.BackgroundColor3 = Color3.fromRGB(35, 35, 48)
    antiAfkBox.BorderSizePixel = 0
    antiAfkBox.ClearTextOnFocus = false
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
    end)

    local farmStatus = Instance.new("TextLabel")
    farmStatus.Size = UDim2.new(1, 0, 0, 28)
    farmStatus.Position = UDim2.new(0, 0, 0, 616)
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
            elseif AutoFarmHackerBoss and CurrentHackerBossId then
                farmStatus.Text = "Status: 💻 Farming Hacker Prime #" .. CurrentHackerBossId
                farmStatus.TextColor3 = Color3.fromRGB(120, 255, 200)
            elseif AutoFarmExpedition and CurrentExpeditionTargetId then
                if ExpeditionDodgeActive then
                    farmStatus.Text = "Status: 🍂 DODGING EXPEDITION ATTACK!"
                    farmStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
                else
                    farmStatus.Text = "Status: 🍂 Farming Expedition Mob #" .. CurrentExpeditionTargetId
                    farmStatus.TextColor3 = Color3.fromRGB(255, 170, 100)
                end
            elseif AutoFarmComet and CurrentCometId then
                farmStatus.Text = "Status: ☄️ Farming Comet #" .. CurrentCometId
                farmStatus.TextColor3 = Color3.fromRGB(180, 220, 255)
            elseif (AutoTap or AutoTeleportClosestCoin) and CurrentCoinTargetId then
                if AutoTap and AutoTeleportClosestCoin then
                    farmStatus.Text = "Status: 👆📍 Tapping + teleporting to coin #" .. CurrentCoinTargetId
                elseif AutoTap then
                    farmStatus.Text = "Status: 👆 Auto tapping coin #" .. CurrentCoinTargetId
                else
                    farmStatus.Text = "Status: 📍 Teleporting to closest coin #" .. CurrentCoinTargetId
                end
                farmStatus.TextColor3 = Color3.fromRGB(120, 220, 255)
            elseif AntiAFK then
                farmStatus.Text = "Status: 🛡️ Anti AFK every " .. tostring(AntiAFKIntervalMinutes) .. " minute(s)"
                farmStatus.TextColor3 = Color3.fromRGB(120, 255, 180)
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
    statsContainer.Size = UDim2.new(1, 0, 0, 142)
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

    local SearchBox = Instance.new("TextBox")
    SearchBox.Size = UDim2.new(1, 0, 0, 32)
    SearchBox.Position = UDim2.new(0, 0, 0, 152)
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
    SelectedEggLabel.Position = UDim2.new(0, 0, 0, 190)
    SelectedEggLabel.Text = "Selected: Spawn Egg"
    SelectedEggLabel.TextColor3 = Color3.fromRGB(100, 225, 100)
    SelectedEggLabel.Font = Enum.Font.GothamBold
    SelectedEggLabel.TextSize = 12
    SelectedEggLabel.BackgroundTransparency = 1
    SelectedEggLabel.TextXAlignment = Enum.TextXAlignment.Left
    SelectedEggLabel.Parent = hatchFrame

    local DropdownFrame = Instance.new("ScrollingFrame")
    DropdownFrame.Size = UDim2.new(1, 0, 0, 100)
    DropdownFrame.Position = UDim2.new(0, 0, 0, 216)
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

    local AutoBuying = false
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

    createUnifiedToggle(hatchFrame, 326, "AFK CPU Reducer", false, function(value) setAfkMode(value) end)
    local recentPanel = Instance.new("Frame")
    recentPanel.Name = "RecentHatchesPanel"
    recentPanel.Size = UDim2.new(1, -6, 0, 150)
    recentPanel.Position = UDim2.new(0, 3, 0, 412)
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
        webhookPanel.Position = UDim2.new(0, 8, 0, 572)
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

        local function makePayload(testMessage, category, petName, totals)
            local fields = {
                {name="🐯 Huges", value="**"..numberText(totals.Huge).."**", inline=true},
                {name="🌌 Secrets", value="**"..numberText(totals.Secret).."**", inline=true},
                {name="🚢 Titanics", value="**"..numberText(totals.Titanic).."**", inline=true},
                {name="👑 Gargantuans", value="**"..numberText(totals.Gargantuan).."**", inline=true}
            }
            return {
                username="Pet Dimensions Hub",
                embeds={{
                    title=testMessage and "🧪 Webhook Test" or ("✨ New "..tostring(category).."!"),
                    description=testMessage and "Your rare-pet webhook is connected." or ("## "..tostring(petName or "Unknown Pet")),
                    color=5793266,
                    fields=fields,
                    footer={text="Pet Dimensions Hub • Rare Hatch Tracker"},
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

        -- Observe the existing recent-pet lists instead of scanning the entire
        -- inventory again. This avoids a second Save.Get()/pairs() pass every 2s.
        local function collectRecentEntries()
            local result = {}
            local lists = {
                { category = "Huge", entries = recentHuges },
                { category = "Secret", entries = recentSecrets },
                { category = "Titanic", entries = recentTitanics },
                { category = "Gargantuan", entries = recentGargantuans }
            }
            for _, data in ipairs(lists) do
                for _, entry in ipairs(data.entries or {}) do
                    if entry and entry.uid then
                        result[tostring(entry.uid)] = {
                            category = data.category,
                            name = entry.name
                        }
                    end
                end
            end
            return result
        end

        task.spawn(function()
            while ui.Parent do
                task.wait(3)
                local current = collectRecentEntries()
                local additions = {}

                for uid, entry in pairs(current) do
                    if not WebhookKnownPets[uid] then
                        WebhookKnownPets[uid] = true
                        if WebhookInitialized and WebhookEnabled then
                            local category = entry.category
                            if category and WebhookNotify[category] then
                                table.insert(additions, {
                                    category = category,
                                    name = tostring(entry.name or "Unknown Pet")
                                })
                            end
                        end
                    end
                end

                if not WebhookInitialized then
                    WebhookInitialized = true
                end

                if #additions > 0 and not WebhookSending then
                    task.spawn(function()
                        for _, item in ipairs(additions) do
                            if WebhookEnabled and WebhookNotify[item.category] then
                                WebhookSending = true
                                local totals = getCurrentTotals()
                                pcall(function()
                                    webhookSend(makePayload(false, item.category, item.name, totals))
                                end)
                                WebhookSending = false
                                task.wait(0.15)
                            end
                        end
                    end)
                end
            end
        end)
    end)

    -- Apply saved toggle states only after every toggle has been created.
    -- This is important for AFK CPU Reducer and Auto-Hatch because their
    -- callbacks depend on UI/functions that are created later in the script.
    for key, callback in pairs(toggleCallbacks) do
        if CurrentToggleStates[key] == true then
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
    -- Match the game's own Eggs controller: it uses the Library network
    -- endpoint "Buy Egg" and passes the multi/triple flags as the final
    -- arguments. The custom toggle below drives this directly so it does not
    -- depend on a ReplicatedStorage child index or on the visual auto-hatch UI.
    local HatchBusy = false

    local function getHatchMode()
        local triple = false
        local multi = false

        pcall(function()
            local save = Library.Save.Get()
            if not save then return end

            local multiHatch = tonumber(save.MultiHatch) or 1
            local ownsOctuple = save.OwnsOctupleEggs == true

            -- Mirror the game's available hatch-slot calculation. If the
            -- account has multi/extra hatch capacity, request multi-hatch;
            -- otherwise request one egg, which the server always accepts
            -- when the selected egg itself is valid/affordable.
            if multiHatch > 1 or ownsOctuple then
                multi = true
            end
        end)

        return triple, multi
    end

    local function hatchSelectedEgg()
        if HatchBusy or not AutoBuying or not SelectedEggId then
            return false
        end

        HatchBusy = true
        local success = false

        pcall(function()
            local triple, multi = getHatchMode()

            -- This is the exact network endpoint used by the game's Eggs
            -- controller (Eggs source: Library.Network.Invoke("Buy Egg", ...)).
            local result, err = Library.Network.Invoke(
                "Buy Egg",
                SelectedEggId,
                triple,
                false,
                multi
            )

            if result == true then
                success = true
            end

            -- If multi-hatch was rejected/unavailable, retry exactly once as
            -- a normal single egg. This keeps auto-hatch working regardless of
            -- the account's current hatch entitlement.
            if not success and multi and AutoBuying and SelectedEggId then
                local singleResult = Library.Network.Invoke(
                    "Buy Egg",
                    SelectedEggId,
                    false,
                    false,
                    false
                )
                success = singleResult == true
            end
        end)

        HatchBusy = false
        return success
    end

    -- Keep the game's auto-hatch variables synchronized as well. The actual
    -- purchase is still performed through the same Buy Egg endpoint above.
    local function setAutoHatchState(enabled)
        AutoBuying = enabled
        pcall(function()
            Library.Variables.AutoHatchEggId = enabled and SelectedEggId or nil
            Library.Variables.AutoHatchEnabled = enabled
        end)
    end

    -- Rebind the toggle to the real hatch state instead of only changing the
    -- custom AutoBuying flag.
    createUnifiedToggle(hatchFrame, 368, "⚡ Auto-Hatch Egg", false, function(value)
        setAutoHatchState(value)
    end)

    task.spawn(function()
        while true do
            if AutoBuying and SelectedEggId then
                hatchSelectedEgg()
                task.wait(0.20)
            else
                task.wait(0.10)
            end
        end
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
		-- ======================================================================
-- 🎃 HALLOWEEN MAZE TAB (v3 + fast pathing) -- paste this block into the hub script,
-- on its own lines, directly ABOVE the very last `end)` of the file.
-- It runs inside its own task.spawn closure, so it adds no locals to the hub's scope.
-- ======================================================================
task.spawn(function()
local env = (getgenv and getgenv()) or _G
if env.HMV2 and env.HMV2.Destroy then pcall(env.HMV2.Destroy) end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local COL = {
	luck = Color3.fromRGB(255, 215, 0), egg = Color3.fromRGB(0, 255, 100),
        exit = Color3.fromRGB(255, 135, 85), scare = Color3.fromRGB(245, 105, 95),
        path = Color3.fromRGB(75, 180, 220), candy = Color3.fromRGB(255, 220, 110),
        bg = Color3.fromRGB(18, 27, 26), card = Color3.fromRGB(31, 44, 40), white = Color3.new(1, 1, 1),
}
local AVOID_R, HUNT_R = 5, 7
local EXIT_STOP, CANDY_STOP = 3, 3.5

-- ───────── state ─────────
local running, moveToken, jobRunning = true, 0, false
local avoidOn, candyFirst, candyEsp, autoOn = true, true, true, false
local hatchOn, escapeOn, scoutOn = true, true, true
local pathVisible, minimapWhenHidden = true, false
local minLuck, hatchSeconds = 10, 60 -- hatchSeconds 0 = until the lucky eggs run out
local eggSel, eggNames = {}, {}
local eggSettings = {}
local savedEggSettings = {}
local rejected = setmetatable({}, {__mode = "k"})
local hatchOwned = false
local conns, esp, pools, ddLists = {}, {}, {}, {}
local lastRoute, lastRouteFloor, preview = nil, nil, nil
local Common, Client, modInst
local setStatus = function() end
local updateMinimapAttachment
local Lib; pcall(function() Lib = require(RS.Framework.Library) end)

local function bind(sig, fn) local c = sig:Connect(fn); conns[#conns + 1] = c; return c end
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end
local function corner(o, r) new("UICorner", {CornerRadius = UDim.new(0, r or 8)}, o) end

-- ───────── game access ─────────
local function getCfg()
	local c = Lib and Lib.Shared and Lib.Shared.HalloweenMaze
	return type(c) == "table" and c or {}
end
local desiredSpeed = tonumber(getCfg().PlayerSpeed) or 20
do
	local seen = {}
	for _, tier in ipairs(getCfg().EggTable or {}) do
		for _, e in ipairs(tier.Eggs or {}) do
			if not seen[e[1]] then seen[e[1]] = true; eggNames[#eggNames + 1] = e[1] end
		end
	end
	if #eggNames == 0 then eggNames = {"Pumpkin Patch Egg", "Crypt Egg", "Haunted Manor Egg", "Nightmare Egg"} end
	for _, n in ipairs(eggNames) do eggSel[n] = true end
end

-- ───────── saved settings ─────────
local SFILE = "HMV2_settings.json"
local zoomOn = false
do
	local ok, s = pcall(function() return isfile and isfile(SFILE) and HttpService:JSONDecode(readfile(SFILE)) end)
	if ok and type(s) == "table" then
		if s.avoid ~= nil then avoidOn = s.avoid == true end
		if s.candyFirst ~= nil then candyFirst = s.candyFirst == true end
		if s.candyEsp ~= nil then candyEsp = s.candyEsp == true end
		if s.hatchOn ~= nil then hatchOn = s.hatchOn == true end
		if s.escapeOn ~= nil then escapeOn = s.escapeOn == true end
		if s.scoutOn ~= nil then scoutOn = s.scoutOn == true end
        if s.pathVisible ~= nil then pathVisible = s.pathVisible == true end
        if s.minimapWhenHidden ~= nil then minimapWhenHidden = s.minimapWhenHidden == true end
		if s.zoom ~= nil then zoomOn = s.zoom == true end
		minLuck = tonumber(s.minLuck) or minLuck
		hatchSeconds = tonumber(s.hatchSeconds) or hatchSeconds
		desiredSpeed = tonumber(s.speed) or desiredSpeed
		if type(s.eggSel) == "table" then
			for n in pairs(eggSel) do if s.eggSel[n] ~= nil then eggSel[n] = s.eggSel[n] == true end end
		end
        if type(s.eggSettings) == "table" then savedEggSettings = s.eggSettings end
	end
end
for _, name in ipairs(eggNames) do
    local saved = savedEggSettings[name]
    local enabled = eggSel[name] ~= false
    if type(saved) == "table" and saved.enabled ~= nil then enabled = saved.enabled == true end
    eggSettings[name] = {
        enabled = enabled,
        minLuck = type(saved) == "table" and (tonumber(saved.minLuck) or minLuck) or minLuck,
        hatchSeconds = type(saved) == "table" and (tonumber(saved.hatchSeconds) or hatchSeconds) or hatchSeconds,
    }
end
local function saveSettings()
	pcall(function()
		if writefile then
			writefile(SFILE, HttpService:JSONEncode({speed = desiredSpeed, avoid = avoidOn, candyFirst = candyFirst,
				candyEsp = candyEsp, zoom = zoomOn, hatchOn = hatchOn, escapeOn = escapeOn, scoutOn = scoutOn,
                pathVisible = pathVisible, minimapWhenHidden = minimapWhenHidden,
                minLuck = minLuck, hatchSeconds = hatchSeconds, eggSel = eggSel, eggSettings = eggSettings}))
		end
	end)
end
local function settingsForEgg(name)
    local settings = eggSettings[name]
    if not settings then
        settings = {enabled = true, minLuck = minLuck, hatchSeconds = hatchSeconds}
        eggSettings[name] = settings
    end
    return settings
end

local function getMaze()
	local t = workspace:FindFirstChild("__THINGS")
	local ic = t and t:FindFirstChild("__INSTANCE_CONTAINER")
	local a = ic and ic:FindFirstChild("Active")
	return a and a:FindFirstChild("HalloweenMaze")
end
local function ensureModules()
	local mz = getMaze()
	if not mz then Common, Client, modInst = nil, nil, nil; return false end
	if mz == modInst and Common and Client then return true end
	local c, cl = mz:FindFirstChild("Common"), mz:FindFirstChild("ClientModule")
	if not (c and cl) then return false end
	local ok1, a = pcall(require, c)
	local ok2, b = pcall(require, cl)
	if ok1 and ok2 and type(a) == "table" and type(b) == "table" then Common, Client, modInst = a, b, mz; return true end
	return false
end
local function upv(f, i)
	if not (debug and debug.getupvalue) then return nil end
	local ok, a, b = pcall(debug.getupvalue, f, i)
	if not ok then return nil end
	if type(a) == "string" and b ~= nil then return b end
	return a
end
local function getState()
	if not ensureModules() then return nil end
	local st = upv(Client.GetSafetyPosition, 1)
	if type(st) == "table" and type(st.walls) == "string" and st.n and st.cs and st.origin and st.exit then return st end
end
local function getMonsterState()
	if not Client then return nil end
	for i = 1, 3 do
		local t = upv(Client.Networking.Monster, i)
		if type(t) == "table" and t.from then return t end
	end
end

local function getRoot() local c = Player.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local function getHum() local c = Player.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function hdist(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude end
local function anyPart(i)
	if not i then return nil end
	if i:IsA("BasePart") then return i end
	if i:IsA("Model") and i.PrimaryPart then return i.PrimaryPart end
	return i:FindFirstChildWhichIsA("BasePart", true)
end
local function posOf(i)
	if i:IsA("Model") then return i:GetPivot().Position end
	local p = anyPart(i); return p and p.Position
end
local function getEggs()
	local ok, f = pcall(function() return workspace.__MAP.Eggs.__HMAZE.Eggs end)
	return (ok and f) and f:GetChildren() or {}
end
local function candyModels()
	local mz = getMaze(); local fl = mz and mz:FindFirstChild("MazeFloor"); local out = {}
	if fl then for _, c in ipairs(fl:GetChildren()) do if c.Name:sub(1, 6) == "Candy " then out[#out + 1] = c end end end
	return out
end
local function eggLuck(st, egg)
	local id = egg.Name:match("Maze Egg (.+)")
	if st and id and st.eggs then
		for _, e in ipairs(st.eggs) do
			if e.id == id then return tonumber(e.mult) or 0, e.left, e.egg end
		end
	end
	return 0, nil, nil
end

-- ───────── geometry ─────────
local gridCache = {}
local function grid(st)
	if gridCache.s ~= st.walls or gridCache.n ~= st.n then
		local w = table.create(#st.walls)
		for i = 1, #st.walls do w[i] = string.byte(st.walls, i) - 48 end
		-- nb = neighbour lists, bf = BFS maps per source, dmc = merged scarecrow maps, sight = line-of-sight cells
		gridCache = {s = st.walls, n = st.n, g = {n = st.n, walls = w, nb = {}, bf = {}, bfN = 0, dmc = {}, dmcN = 0, sight = {}}}
	end
	return gridCache.g
end
-- FAST: neighbour lists are computed once per cell per maze instead of allocated on every call
local function nbrs(g, c)
	local t = g.nb[c]
	if not t then t = Common.Neighbors(g, c); g.nb[c] = t end
	return t
end
local function bfs(g, src)
	local dist, q, h = {[src] = 0}, {src}, 1
	while q[h] do
		local c = q[h]; h += 1
		local d = dist[c] + 1
		for _, nb in ipairs(nbrs(g, c)) do
			if dist[nb] == nil then dist[nb] = d; q[#q + 1] = nb end
		end
	end
	return dist
end
local function bfsCached(g, src) -- read-only result
	local r = g.bf[src]
	if not r then
		if g.bfN > 64 then g.bf, g.bfN = {}, 0 end
		r = bfs(g, src); g.bf[src] = r; g.bfN += 1
	end
	return r
end
local function cellPos(st, i)
	local x, z = Common.CellXZ(st.n, i)
	return st.origin + Vector3.new(x * st.cs, 0, z * st.cs)
end
local function posCell(st, p)
	return Common.CellAt(st.n, (p.X - st.origin.X) / st.cs, (p.Z - st.origin.Z) / st.cs)
end
-- cells with a straight, wall-free line to `cell` (an egg's luck is only revealed from such a spot)
-- returns vis[cell] = distance in cells, order = cells nearest first per direction (cached per maze)
local function sightCells(st, g, cell)
	local cached = g.sight[cell]
	if cached then return cached[1], cached[2] end
	local vis, order = {[cell] = 0}, {cell}
	local x0, z0 = Common.CellXZ(st.n, cell)
	for _, first in ipairs(nbrs(g, cell)) do
		local fx, fz = Common.CellXZ(st.n, first)
		local dx, dz = fx - x0, fz - z0
		local cur, cx, cz, k = first, fx, fz, 1
		while cur do
			if vis[cur] == nil then vis[cur] = k; order[#order + 1] = cur end
			local nxt, nxx, nxz
			for _, nb in ipairs(nbrs(g, cur)) do
				local nx, nz = Common.CellXZ(st.n, nb)
				if math.abs(nx - cx - dx) < 1e-3 and math.abs(nz - cz - dz) < 1e-3 then nxt, nxx, nxz = nb, nx, nz; break end
			end
			cur, cx, cz, k = nxt, nxx, nxz, k + 1
		end
	end
	g.sight[cell] = {vis, order}
	return vis, order
end

-- ───────── scarecrow (server timeline, same maths as the game's own render) ─────────
local scareSeen = {}
local function monsterInfo(st)
	local mon = getMonsterState()
	if mon and mon.from and mon.to then
		local a, b = cellPos(st, mon.from), cellPos(st, mon.to)
		local now = workspace:GetServerTimeNow()
		local t0, t1 = tonumber(mon.t0) or 0, tonumber(mon.t1) or 0
		local f = (t1 <= t0) and (t1 <= now and 1 or 0) or math.clamp((now - t0) / (t1 - t0), 0, 1)
		local dt, cells = t1 - t0, hdist(a, b) / st.cs
		if dt > 0.05 and cells > 0.5 then
			if scareSeen.floor ~= st.floor then scareSeen = {floor = st.floor} end
			local v = cells / dt
			local k = mon.hunting == true and "hunt" or "walk"
			if v < 30 then scareSeen[k] = math.max(scareSeen[k] or 0, v) end
		end
        local direction = b - a
        if direction.Magnitude > 0.01 then direction = direction.Unit else direction = nil end
        return a:Lerp(b, f), mon.from, mon.to, mon.hunting == true, direction
	end
	local mz = getMaze(); local sc = mz and mz:FindFirstChild("Scarecrow")
    if sc then return sc:GetPivot().Position, nil, nil, false, nil end
end

-- ───────── planning ─────────
-- FAST: binary-heap Dijkstra (was an O(n^2) linear scan of the open list)
local function dijkstra(g, src, dm, hard, R)
	local dist, prev = {[src] = 0}, {}
	local hk, hv, hn = {0}, {src}, 1
	while hn > 0 do
		local bd, bc = hk[1], hv[1]
		hk[1], hv[1] = hk[hn], hv[hn]; hk[hn], hv[hn] = nil, nil; hn -= 1
		local i = 1
		while true do
			local l = i * 2
			if l > hn then break end
			local r = l + 1
			local m = (r <= hn and hk[r] < hk[l]) and r or l
			if hk[m] < hk[i] then
				hk[i], hk[m] = hk[m], hk[i]; hv[i], hv[m] = hv[m], hv[i]; i = m
			else break end
		end
		if bd <= dist[bc] then
			for _, nb in ipairs(nbrs(g, bc)) do
				local cost = 1
				if dm then
					local d = dm[nb] or 99
                    if hard and d == 0 then cost = nil
					elseif d < R then cost = 1 + (R - d) ^ 2 * 0.6 end
				end
				if cost then
					local nd = bd + cost
					local od = dist[nb]
					if od == nil or nd < od then
						dist[nb] = nd; prev[nb] = bc
						hn += 1; hk[hn], hv[hn] = nd, nb
						local j = hn
						while j > 1 do
							local p = j // 2
							if hk[p] > hk[j] then
								hk[p], hk[j] = hk[j], hk[p]; hv[p], hv[j] = hv[j], hv[p]; j = p
							else break end
						end
					end
				end
			end
		end
	end
	return dist, prev
end
local function pathTo(prev, src, dst)
	if src == dst then return {src} end
	if prev[dst] == nil then return nil end
	local r, c = {}, dst
	while c ~= nil do table.insert(r, 1, c); if c == src then return r end; c = prev[c] end
	return nil
end
-- graph distance from the scarecrow (both ends of its current segment) to every cell (cached per cell triple)
local function danger(st, g)
    local p, a, b, hunting, direction = monsterInfo(st)
	if not p then return nil end
	local mc = posCell(st, p) or a
	if not mc then return nil end
	local key = tostring(mc) .. ":" .. tostring(a) .. ":" .. tostring(b)
	local dm = g.dmc[key]
	if not dm then
		local base = bfsCached(g, mc)
		local extras = {}
		for _, extra in ipairs({a, b}) do
			if extra and extra ~= mc then extras[#extras + 1] = bfsCached(g, extra) end
		end
		if #extras == 0 then
			dm = base
		else
			dm = table.clone(base)
			for _, d2 in ipairs(extras) do
				for c, d in pairs(d2) do if d < (dm[c] or 99) then dm[c] = d end end
			end
		end
        if direction then
            local directional = table.clone(dm)
            for cell, distance in pairs(dm) do
                local behind = -(cellPos(st, cell) - p):Dot(direction) / st.cs
                if behind > 0.25 then directional[cell] = distance + math.min(2, behind * 0.6) end
            end
            dm = directional
        end
		if g.dmcN > 48 then g.dmc, g.dmcN = {}, 0 end
		g.dmc[key] = dm; g.dmcN += 1
	end
	return dm, hunting, mc
end
-- player and scarecrow speeds in cells/sec (scarecrow = worst case from what it has been seen doing)
local function speeds(st, hunting, dme)
	local sP = math.max(desiredSpeed / st.cs * 0.92, 0.2)
	local sw, sh = scareSeen.walk, scareSeen.hunt
	local sS
	if hunting or (dme or 99) <= 3 then sS = sh or (sw and sw * 1.3) or sP * 1.05
	else sS = (sw and sw * 1.15) or sP * 0.8 end
	return sP, math.max(sS, 0.2)
end
-- earliest-arrival BFS over every alternative route
local function racePath(g, me, goal, dm, sP, sS, margin)
	local steps, prev, q, h = {[me] = 0}, {}, {me}, 1
	while q[h] do
		local c = q[h]; h += 1
		if c == goal then break end
		local s = steps[c] + 1
		for _, nb in ipairs(nbrs(g, c)) do
			if steps[nb] == nil and (dm[nb] or 99) / sS - s / sP >= margin then
				steps[nb] = s; prev[nb] = c; q[#q + 1] = nb
			end
		end
	end
	if steps[goal] == nil then return nil, steps, prev end
	return pathTo(prev, me, goal), steps[goal]
end
-- does a route from cell c to goal exist that avoids the scarecrow's shortest path to c?
local function altExists(g, dm, c, goal)
	local blocked, cur = {}, c
	while (dm[cur] or 0) > 0 do
		blocked[cur] = true
		local nxt
		for _, nb in ipairs(nbrs(g, cur)) do
			if dm[nb] == dm[cur] - 1 then nxt = nb; break end
		end
		if not nxt then break end
		cur = nxt
	end
	local seen, q, h = {[c] = true}, {c}, 1
	while q[h] do
		local x = q[h]; h += 1
		if x == goal then return true end
		for _, nb in ipairs(nbrs(g, x)) do
			if not seen[nb] and not blocked[nb] then seen[nb] = true; q[#q + 1] = nb end
		end
	end
	return false
end
-- retreat target
local function safeFlee(g, me, dm, sP, sS, goal, prevTarget)
	for _, m in ipairs({1.0, 0.5, 0, -0.5}) do
		local steps, prev, q, h = {[me] = 0}, {}, {me}, 1
		while q[h] do
			local c = q[h]; h += 1
			if steps[c] < 18 then
				local s = steps[c] + 1
				for _, nb in ipairs(nbrs(g, c)) do
					if steps[nb] == nil and (dm[nb] or 99) / sS - s / sP > m then
						steps[nb] = s; prev[nb] = c; q[#q + 1] = nb
					end
				end
			end
		end
        if prevTarget and prevTarget ~= me and steps[prevTarget] then
            return pathTo(prev, me, prevTarget), prevTarget
        end
		local cand = {}
		for c, s in pairs(steps) do
			if c ~= me then
				local deg = #nbrs(g, c)
				local slack = ((dm[c] or 99) / sS - s / sP) * sP
				local sc = slack + (deg >= 3 and 3 or 0) - (deg == 1 and 6 or 0) - s * 0.15 + (c == prevTarget and 2 or 0)
				cand[#cand + 1] = {c, sc}
			end
		end
		if #cand > 0 then
			table.sort(cand, function(a, b) return a[2] > b[2] end)
			local best, bs
			for i = 1, math.min(5, #cand) do
				local sc = cand[i][2] + ((goal and altExists(g, dm, cand[i][1], goal)) and 8 or 0)
				if not bs or sc > bs then best, bs = cand[i][1], sc end
			end
			return pathTo(prev, me, best), best
		end
	end
	return nil
end
local function plan(st, g, me, goal, ps, pursueGoal)
	local dm, hunting
	if avoidOn then dm, hunting = danger(st, g) end
	if not dm then
        ps.fleeTo, ps.advanceTo, ps.approachTo = nil, nil, nil
		local _, prev = dijkstra(g, me, nil, false, 0)
		return pathTo(prev, me, goal), "normal", nil
	end
    if pursueGoal then
        ps.fleeTo, ps.advanceTo, ps.approachTo = nil, nil, nil
        local _, prev = dijkstra(g, me, dm, false, hunting and HUNT_R or AVOID_R)
        return pathTo(prev, me, goal), "egg pursuit", dm[me] or 99
    end
    local routeGoal = goal
    if (dm[goal] or 99) == 0 then
        local approachDist = dijkstra(g, me, dm, true, AVOID_R)
        local best, bestScore
        for _, cell in ipairs(nbrs(g, goal)) do
            local d = dm[cell] or 99
            if d > 0 and approachDist[cell] then
                local score = approachDist[cell] - math.min(d, 12) * 0.05
                if not bestScore or score < bestScore then best, bestScore = cell, score end
            end
        end
        local previous = ps.approachTo
        local previousAdjacent = false
        if previous then
            for _, cell in ipairs(nbrs(g, goal)) do
                if cell == previous then previousAdjacent = true; break end
            end
        end
        if previousAdjacent and (dm[previous] or 0) > 0 and approachDist[previous] then
            local previousScore = approachDist[previous] - math.min(dm[previous] or 99, 12) * 0.05
            if not bestScore or previousScore <= bestScore + 3 then best = previous end
        end
        ps.approachTo = best
        if best then routeGoal = best end
    else
        ps.approachTo = nil
    end
	local dme = dm[me] or 99
	local sP, sS = speeds(st, hunting, dme)
	-- 1) can we get to the goal (by any route) staying ahead of the scarecrow? re-checked every tick
    local route, rsteps, rprev = racePath(g, me, routeGoal, dm, sP, sS, (hunting and 0.8 or 0.4) / sP)
	if route then
        ps.waitSince = nil; ps.fleeTo = nil; ps.advanceTo = nil
		return route, dme <= 10 and "racing" or "normal", dme
	end
	-- 2) can't win the race: scarecrow close -> retreat to a safe cell that lures it off the goal path
	local function flee()
        local r, t = safeFlee(g, me, dm, sP, sS, routeGoal, ps.fleeTo)
        if r then ps.fleeTo = t; ps.advanceTo = nil end
		return r
	end
    if dme / sS <= (hunting and 1.6 or 1.1) then
		local r = flee(); if r then return r, "FLEEING", dme end
	end
	-- 2b) NEW: scarecrow near the route but not on top of us -> don't stand still, walk to the safe cell
	-- (one we still reach before it) that is closest to the goal. Re-planned every tick, so it keeps
	-- advancing as the scarecrow moves off the route.
	if type(rsteps) == "table" then
        local gd = bfsCached(g, routeGoal)
		local bestC, bestD, bestS = nil, gd[me] or 1e9, nil
        if ps.advanceTo and ps.advanceTo ~= me and rsteps[ps.advanceTo] then
            bestC = ps.advanceTo
        else
            for c, s in pairs(rsteps) do
                local d = gd[c]
                if d and c ~= me and (d < bestD or (d == bestD and bestC and s < bestS)) then bestC, bestD, bestS = c, d, s end
            end
		end
		if bestC then
			local r = pathTo(rprev, me, bestC)
            if r then ps.advanceTo = bestC; ps.waitSince = nil; ps.fleeTo = nil; return r, "advancing", dme end
		end
	end
	-- 3) NEW: never stand still. No fully safe route and nothing better to advance to -> take the
	-- soft-cost route (penalises cells near the scarecrow) immediately; re-planned every tick, and the
	-- flee check above takes over the moment the scarecrow gets close.
    ps.fleeTo, ps.advanceTo = nil, nil
	local R = hunting and HUNT_R or AVOID_R
	local _, p2 = dijkstra(g, me, dm, true, R) -- cells right next to the scarecrow blocked
    local r2 = pathTo(p2, me, routeGoal)
	if not r2 then
		_, p2 = dijkstra(g, me, dm, false, R)
        r2 = pathTo(p2, me, routeGoal)
	end
	if r2 then return r2, "cautious", dme end
	return nil, "no route", dme
end

-- ───────── blue path (pooled) ─────────
local pathFolder = new("Folder", {Name = "HMV2_Path"}, workspace)
local segs = {}
local activeSegmentCount = 0
local function refreshPathVisibility()
    for i, segment in ipairs(segs) do
        segment.Transparency = pathVisible and i <= activeSegmentCount and 0 or 1
    end
end
local function clearPath()
	for _, s in ipairs(segs) do s.Transparency = 1 end
    activeSegmentCount = 0
	lastRoute = nil
end
local function drawRoute(st, route, tp, y, firstIndex)
	local pts = {}
	local root = getRoot()
	if root then pts[1] = Vector3.new(root.Position.X, y, root.Position.Z) end
    for i = firstIndex or 1, #route do
        local p = cellPos(st, route[i]); pts[#pts + 1] = Vector3.new(p.X, y, p.Z)
    end
	if tp then pts[#pts + 1] = Vector3.new(tp.X, y, tp.Z) end
	local k = 0
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local d = (b - a).Magnitude
		if d > 0.05 then
			k += 1
			local p = segs[k]
			if not p then
				p = new("Part", {Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
					CastShadow = false, Material = Enum.Material.Neon, Color = COL.path}, pathFolder)
				segs[k] = p
			end
            p.Transparency = pathVisible and 0 or 1
            p.Size = Vector3.new(0.6, 0.6, d); p.CFrame = CFrame.lookAt((a + b) / 2, b)
		end
	end
	for i = k + 1, #segs do segs[i].Transparency = 1 end
    activeSegmentCount = k
	lastRoute, lastRouteFloor = route, st.floor
end

-- ───────── ESP ─────────
local function espSet(inst, adornee, text, color, w, h)
	if not adornee then return end
	local e = esp[inst]
	if not e then
		local b = new("BillboardGui", {Name = "HMV2_ESP", AlwaysOnTop = true, Size = UDim2.fromOffset(w, h),
			StudsOffset = Vector3.new(0, 3, 0), MaxDistance = 1e5}, PlayerGui)
		local t = new("TextLabel", {Name = "L", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
			TextStrokeTransparency = 0, TextScaled = true, Font = Enum.Font.GothamBold}, b)
		e = {gui = b, label = t}; esp[inst] = e
	end
	e.gui.Adornee = adornee; e.label.Text = text; e.label.TextColor3 = color; e.seen = true
end
local function espSweep()
	for inst, e in pairs(esp) do
		if not e.seen or not inst.Parent then e.gui:Destroy(); esp[inst] = nil else e.seen = false end
	end
end
local scareText = ""
local function luckText(mult, left)
	local s = mult > 0 and (" x" .. mult) or " x?"
	if left then s ..= (" (%d left)"):format(left) end
	return s
end
local function refreshESP()
	local st, mz = getState(), getMaze()
	if not (st and mz) then espSweep(); return end
	for _, egg in ipairs(getEggs()) do
		local mult, left, name = eggLuck(st, egg)
		espSet(egg, anyPart(egg), "🥚 " .. tostring(name or egg:GetAttribute("ID") or "Egg") .. luckText(mult, left),
			mult >= 100 and COL.luck or COL.egg, 200, 36)
	end
	local fl = mz:FindFirstChild("MazeFloor"); local ex = fl and fl:FindFirstChild("Exit")
	if ex then espSet(ex, anyPart(ex), "🚪 EXIT", COL.exit, 120, 30) end
	local sc = mz:FindFirstChild("Scarecrow")
	if sc then espSet(sc, anyPart(sc), "🎃 SCARECROW" .. scareText, COL.scare, 200, 34) end
	if candyEsp then
		for _, c in ipairs(candyModels()) do espSet(c, anyPart(c), "🍬", COL.candy, 26, 26) end
	end
	espSweep()
end

-- ───────── movement ─────────
local function aimPoint(st, route, root, tp, routeIndex)
    local first = routeIndex or 1
    if #route - first < 1 then
        local targetCell = posCell(st, tp)
        local p = targetCell == route[first] and tp or cellPos(st, route[first])
        return Vector3.new(p.X, root.Position.Y, p.Z)
    end
    local nextIndex = first + 1
    local direction = route[nextIndex] - route[first]
    local targetIndex = nextIndex
    for i = nextIndex + 1, math.min(#route, nextIndex + 7) do
        if route[i] - route[i - 1] ~= direction then break end
        targetIndex = i
    end
    if targetIndex == #route and posCell(st, tp) == route[targetIndex] then
        return Vector3.new(tp.X, root.Position.Y, tp.Z)
    end
    local p = cellPos(st, route[targetIndex])
    if targetIndex > nextIndex then
        local lateral = (math.abs(direction) == 1) and math.abs(root.Position.Z - p.Z) or math.abs(root.Position.X - p.X)
        local laneMargin = math.max(st.cs * 0.5 - 2.25, 0.5)
        if lateral <= laneMargin then
            if math.abs(direction) == 1 then p = Vector3.new(p.X, p.Y, root.Position.Z)
            else p = Vector3.new(root.Position.X, p.Y, p.Z) end
        end
    end
    return Vector3.new(p.X, root.Position.Y, p.Z)
end

local function sameCellTarget(st, root, target)
    local targetCell = posCell(st, target)
    return targetCell ~= nil and posCell(st, root.Position) == targetCell
end

    local function routeIndexFor(route, cell, firstIndex)
        for i = firstIndex or 1, #route do
            local routeCell = route[i]
        if routeCell == cell then return i end
    end
    return nil
end

-- returns "arrived" | "lost" | "cancelled" | "floor"
local function walk(token, getTarget, stop, label, shouldInterrupt, pursueGoal)
    local s0 = getState()
    local floor0 = s0 and s0.floor
    local ps, lastPos, lastT = {}, nil, os.clock()
    local route, plannedAt, plannedGoal, plannedTarget, activeAim
    local routeCursor = 1
    local lastInterruptCheck = 0
    while running and token == moveToken do
        local st, root, hum = getState(), getRoot(), getHum()
        if not (st and root and hum) then task.wait(0.15); continue end
        if st.floor ~= floor0 then return "floor" end
        local tp = getTarget(st)
        if not tp then return "lost" end
        local arrived
        if type(stop) == "function" then arrived = stop(st, root, tp)
        else arrived = hdist(root.Position, tp) <= stop end
        if arrived then hum:MoveTo(root.Position); return "arrived" end
        local g = grid(st)
        local me, goal = posCell(st, root.Position), posCell(st, tp)
        if not (me and goal) then task.wait(0.15); continue end
        local now = os.clock()
        if shouldInterrupt and now - lastInterruptCheck >= 0.3 then
            lastInterruptCheck = now
            if shouldInterrupt(st, root) then
                hum:MoveTo(root.Position)
                return "reconsider"
            end
        end
        local routeIndex = route and routeIndexFor(route, me, routeCursor)
        local activeCell = activeAim and posCell(st, activeAim)
        local activeBlocked = false
        if avoidOn and activeCell then
            local monsterPosition = monsterInfo(st)
            local monsterCell = monsterPosition and posCell(st, monsterPosition)
            activeBlocked = monsterCell == activeCell
        end
        local routeInvalid = route ~= nil and routeIndex == nil
        local replanInterval = pursueGoal and 0.75 or 0.35
        local needsPlan = not plannedAt or now - plannedAt >= replanInterval or goal ~= plannedGoal
            or routeInvalid or not plannedTarget or hdist(tp, plannedTarget) >= 0.75
        local mode, dme
        if needsPlan then
            route, mode, dme = plan(st, g, me, goal, ps, pursueGoal)
            plannedAt, plannedGoal, plannedTarget = now, goal, tp
            routeCursor = 1
            routeIndex = route and routeIndexFor(route, me, routeCursor)
        end
        if not route or not routeIndex then
            if activeAim then hum:MoveTo(root.Position); activeAim = nil end
            setStatus("⏳ " .. tostring(mode or "no route")); task.wait(0.12); continue
        end
        routeCursor = routeIndex
        local movementTarget = pursueGoal and cellPos(st, goal) or tp
        if needsPlan then
            drawRoute(st, route, movementTarget, root.Position.Y, routeIndex)
            setStatus(("→ %s  [%s%s]"):format(label, mode, dme and (" · scarecrow " .. dme) or ""))
        end
        if hum.WalkSpeed ~= desiredSpeed then hum.WalkSpeed = desiredSpeed end
        local aim = aimPoint(st, route, root, movementTarget, routeIndex)
        local activeIndex = activeCell and routeIndexFor(route, activeCell, routeIndex)
        local activeStillValid = activeAim and activeIndex and activeIndex > routeIndex
            and hdist(root.Position, activeAim) > st.cs * 0.35 and not activeBlocked
        if activeStillValid then aim = activeAim end
        if not activeAim or (aim - activeAim).Magnitude >= 0.75 then
            hum:MoveTo(aim); activeAim = aim
        end
        if os.clock() - lastT > 1.2 then
            if lastPos and hdist(root.Position, lastPos) < 1 and activeAim and not activeBlocked then
                hum:MoveTo(activeAim)
            end
            lastPos, lastT = root.Position, os.clock()
        end
        task.wait(0.08)
    end
    return "cancelled"
end

local candyIgnore = setmetatable({}, {__mode = "k"})
local function nearestCandy(st, g, me)
	local dm, hunting
	if avoidOn then dm, hunting = danger(st, g) end
	local dist = dijkstra(g, me, dm, dm ~= nil, hunting and HUNT_R or AVOID_R)
	local best, bd
	for _, c in ipairs(candyModels()) do
		if not candyIgnore[c] then
			local p = posOf(c); local cell = p and posCell(st, p)
			local d = cell and dist[cell]
			if d and (not dm or (dm[cell] or 99) >= 3) and (not bd or d < bd) then best, bd = c, d end
		end
	end
	return best
end
local function collectCandy(token)
	local tries, idleSince = {}, nil
	while running and token == moveToken do
		local st, root = getState(), getRoot()
		local me = st and root and posCell(st, root.Position)
		if not me then task.wait(0.2); continue end
		local c = nearestCandy(st, grid(st), me)
		if not c then
			if #candyModels() == 0 then return "done" end
			idleSince = idleSince or os.clock()
			if os.clock() - idleSince > 6 then return "skipped" end
			setStatus("⏳ candy near scarecrow..."); task.wait(0.3); continue
		end
		idleSince = nil
		local r = walk(token, function() if c.Parent then return posOf(c) end end, CANDY_STOP, "Candy")
		if r == "cancelled" or r == "floor" then return r end
		if r == "arrived" then
			tries[c] = (tries[c] or 0) + 1
			if tries[c] >= 3 then candyIgnore[c] = true end
			task.wait(0.25)
		end
	end
	return "cancelled"
end

-- ───────── egg hatching ─────────
local function setAutoHatch(on, name)
	if not Lib then return false end
	if not on and not hatchOwned then return true end
	local ok = pcall(function()
		Lib.Variables.AutoHatchEggId = on and name or nil
		Lib.Variables.AutoHatchEnabled = on and true or false
	end)
	hatchOwned = (on and ok) and true or false
	return ok
end
local function autoHatchOn(name)
	if not Lib then return false end
	local ok, r = pcall(function() return Lib.Variables.AutoHatchEnabled == true and Lib.Variables.AutoHatchEggId == name end)
	return ok and r
end

local function escape(token)
	local t0 = os.clock()
	local ps = {}
    local route, fleeGoal, plannedAt, routeCursor, activeAim
    routeCursor = 1
	while running and token == moveToken and os.clock() - t0 < 40 do
		local st, root, hum = getState(), getRoot(), getHum()
		local me = st and root and posCell(st, root.Position)
		if not (me and hum) then task.wait(0.2); continue end
		local g = grid(st)
        local dm, hunting = danger(st, g)
		if not dm then return true end
		if (dm[me] or 99) >= (hunting and 10 or 8) then return true end
        local now = os.clock()
        local routeIndex = route and routeIndexFor(route, me, routeCursor)
        local activeCell = activeAim and posCell(st, activeAim)
        local activeBlocked = activeCell and (dm[activeCell] or 99) == 0
        local needsPlan = not plannedAt or now - plannedAt >= 0.3 or not routeIndex or activeBlocked
        if needsPlan then
            local sP, sS = speeds(st, hunting, dm[me])
            local nextRoute, best = safeFlee(g, me, dm, sP, sS, nil, ps.fleeTo)
            if not nextRoute then
                local dist, prev = dijkstra(g, me, dm, false, hunting and HUNT_R or AVOID_R)
                local bestScore
                if ps.fleeTo and ps.fleeTo ~= me and dist[ps.fleeTo] and dist[ps.fleeTo] <= 18 then
                    best = ps.fleeTo
                    bestScore = (dm[best] or 99) - dist[best] * 0.3
                end
                for cell, distance in pairs(dist) do
                    if distance <= 18 then
                        local score = (dm[cell] or 99) - distance * 0.3
                        if not bestScore or score > bestScore then best, bestScore = cell, score end
                    end
                end
                nextRoute = (best and best ~= me) and pathTo(prev, me, best) or nil
            end
            route, fleeGoal, plannedAt = nextRoute, best, now
            routeCursor = 1
            routeIndex = route and routeIndexFor(route, me, routeCursor)
            if route and fleeGoal then ps.fleeTo = fleeGoal end
        end
        if not route or not routeIndex or not fleeGoal then
            if activeAim then hum:MoveTo(root.Position); activeAim = nil end
            task.wait(0.1); continue
        end
        routeCursor = routeIndex
        local tp = cellPos(st, fleeGoal)
        local aim = aimPoint(st, route, root, tp, routeIndex)
        local activeIndex = activeCell and routeIndexFor(route, activeCell, routeIndex)
        local activeStillValid = activeAim and activeIndex and activeIndex > routeIndex
            and hdist(root.Position, activeAim) > st.cs * 0.35 and not activeBlocked
        if activeStillValid then aim = activeAim end
        if hum.WalkSpeed ~= desiredSpeed then hum.WalkSpeed = desiredSpeed end
        if needsPlan then
            drawRoute(st, route, tp, root.Position.Y, routeIndex)
            setStatus("🏃 escaping scarecrow · " .. (dm[me] or 99) .. " cells")
        end
        if not activeAim or (aim - activeAim).Magnitude >= 0.75 then
            hum:MoveTo(aim); activeAim = aim
        end
        task.wait(0.08)
	end
	return false
end

-- returns "done" | "rejected" | "failed" | "gone" | "cancelled" | "floor" | "lost"
local function hatchAt(token, egg, force)
	local name = egg:GetAttribute("ID")
	if not name then return "gone" end
    local eggConfig = settingsForEgg(name)
	local st0 = getState(); local floor0 = st0 and st0.floor
	local tHatch, reasserts, last = 0, 0, os.clock()
	local result = "cancelled"
	while running and token == moveToken do
		if not egg.Parent then result = "gone"; break end
		local st, root = getState(), getRoot()
		if not (st and root) then task.wait(0.2); last = os.clock(); continue end
		if st.floor ~= floor0 then result = "floor"; break end
		local ep = posOf(egg)
		if not ep then result = "gone"; break end
        if not sameCellTarget(st, root, ep) then
			setAutoHatch(false)
            local r = walk(token, function() if egg.Parent then return posOf(egg) end end, sameCellTarget, "Egg", nil, true)
			if r ~= "arrived" then result = r; break end
			last = os.clock()
			continue
		end
		local now = os.clock(); local dt = now - last; last = now
		local mult, left = eggLuck(st, egg)
		if not force then
            if mult > 0 and mult < eggConfig.minLuck then rejected[egg] = ("x%d below x%d"):format(mult, eggConfig.minLuck); result = "rejected"; break end
            if mult == 0 and eggConfig.minLuck > 1 and tHatch > 20 then rejected[egg] = "luck unknown"; result = "rejected"; break end
		end
		if left and left <= 0 then rejected[egg] = "empty"; result = "done"; break end
		local g = grid(st)
		local me = posCell(st, root.Position)
		local dm, hunting
		if avoidOn and escapeOn then dm, hunting = danger(st, g) end
		if dm and me and (dm[me] or 99) <= (hunting and 5 or 4) then
			setAutoHatch(false)
			escape(token)
			local eggCell = posCell(st, ep)
			local w = os.clock()
			while running and token == moveToken and os.clock() - w < 25 do
				local s2 = getState()
				local d2 = s2 and danger(s2, grid(s2))
				if not d2 or (eggCell and (d2[eggCell] or 99) >= 7) then break end
				setStatus("⏳ waiting for scarecrow to leave the egg")
				task.wait(0.3)
			end
			reasserts = 0; last = os.clock()
			continue
		end
		if not autoHatchOn(name) then
			reasserts += 1
			if reasserts > 6 then rejected[egg] = "auto hatch refused"; result = "failed"; break end
			setAutoHatch(true, name)
		end
		tHatch += dt
        setStatus(("🥚 hatching %s%s  [%ds%s]"):format(name, luckText(mult, left), tHatch,
            eggConfig.hatchSeconds > 0 and ("/" .. eggConfig.hatchSeconds) or ""))
        if eggConfig.hatchSeconds > 0 and tHatch >= eggConfig.hatchSeconds then rejected[egg] = "done"; result = "done"; break end
		task.wait(0.2)
	end
	setAutoHatch(false)
	return result
end

local function pickEgg(st, g, me, allowUnknown)
	local dm, hunting
	if avoidOn then dm, hunting = danger(st, g) end
    local dist = dijkstra(g, me, dm, false, hunting and HUNT_R or AVOID_R)
	local best, bs
	for _, egg in ipairs(getEggs()) do
		local name = egg:GetAttribute("ID")
        local eggConfig = name and settingsForEgg(name)
        if name and eggConfig.enabled and not rejected[egg] then
			local mult, left = eggLuck(st, egg)
            local oddsKnown = mult > 0
            if (allowUnknown or oddsKnown or eggConfig.minLuck <= 1)
                and not ((oddsKnown and mult < eggConfig.minLuck) or (left and left <= 0)) then
				local p = posOf(egg); local cell = p and posCell(st, p)
				local d = cell and dist[cell]
				if d then
					local s = (mult > 0 and mult * 1000 or 0) - d
					if not bs or s > bs then best, bs = egg, s end
				end
			end
		end
	end
	return best
end

local function hasEligibleEgg(st)
    for _, egg in ipairs(getEggs()) do
        local name = egg:GetAttribute("ID")
        local config = name and settingsForEgg(name)
        if name and config.enabled and not rejected[egg] then
            local mult, left = eggLuck(st, egg)
            if not ((mult > 0 and mult < config.minLuck) or (left and left <= 0)) then
                return true
            end
        end
    end
    return false
end

-- ───────── egg scouting ─────────
local scoutTried = setmetatable({}, {__mode = "k"})
local function scoutEggs(token)
	local s0 = getState(); local floor0 = s0 and s0.floor
	while running and token == moveToken do
		local st, root = getState(), getRoot()
		local me = st and root and posCell(st, root.Position)
		if not me then task.wait(0.2); continue end
		if st.floor ~= floor0 then return "floor" end
		local g = grid(st)
		local dm, hunting
		if avoidOn then dm, hunting = danger(st, g) end
		local dist = dijkstra(g, me, dm, dm ~= nil, hunting and HUNT_R or AVOID_R)
		local bEgg, bCell, bScore
		for _, egg in ipairs(getEggs()) do
			local name = egg:GetAttribute("ID")
            if name and settingsForEgg(name).enabled and not rejected[egg] and eggLuck(st, egg) == 0 then
				local p = posOf(egg); local ec = p and posCell(st, p)
				local tried = scoutTried[egg]
				if not tried then tried = {n = 0}; scoutTried[egg] = tried end
				if ec and tried.n < 4 then
					local vis, order = sightCells(st, g, ec)
					for _, c in ipairs(order) do
						local d = dist[c]
						if d and not tried[c] then
							local s = d + vis[c] * 0.6
							if not bScore or s < bScore then bScore, bEgg, bCell = s, egg, c end
						end
					end
				end
			end
		end
		if not bEgg then return "done" end
		local r = walk(token, function(s)
			if not bEgg.Parent or eggLuck(s, bEgg) > 0 then return nil end
			return cellPos(s, bCell)
		end, st.cs * 0.3, "Scout")
		if r == "cancelled" or r == "floor" then return r end
        if r == "lost" and bEgg.Parent then
            local latestState = getState()
            if latestState and eggLuck(latestState, bEgg) > 0 then return "scouted" end
        end
		if r == "arrived" then
			local t = os.clock()
			while os.clock() - t < 0.7 and bEgg.Parent do
				local s2 = getState()
				if s2 and eggLuck(s2, bEgg) > 0 then break end
				task.wait(0.1)
			end
			local tried = scoutTried[bEgg]
			tried[bCell] = true; tried.n += 1
            return "scouted"
		end
	end
	return "cancelled"
end

local function exitTarget(st) local p = cellPos(st, st.exit); return p + Vector3.new(0, 6, 0) end
local function autoLoop(token)
	while running and token == moveToken and autoOn do
		local st = getState()
		if not st then task.wait(0.3); continue end
		local floor = st.floor
		if candyFirst then
            local root = getRoot()
            local me = root and posCell(st, root.Position)
            local pendingEgg = hatchOn and me and pickEgg(st, grid(st), me, true)
            if not pendingEgg and collectCandy(token) == "cancelled" then return end
		end
		if hatchOn then
			while running and token == moveToken and autoOn do
				local s2, root = getState(), getRoot()
				local me = s2 and root and posCell(s2, root.Position)
				if not me or s2.floor ~= floor then break end
                local egg = pickEgg(s2, grid(s2), me, not scoutOn)
                if egg then
                    local r = hatchAt(token, egg, false)
                    if r == "cancelled" then return end
                    if r == "floor" then break end
                    if r == "lost" or r == "gone" or r == "failed" then rejected[egg] = rejected[egg] or r end
                elseif scoutOn then
                    local result = scoutEggs(token)
                    if result == "cancelled" then return end
                    if result == "scouted" then continue end
                    break
                else
                    break
                end
			end
		end
		if token ~= moveToken or not autoOn then return end
        local r = walk(token, exitTarget, EXIT_STOP, "EXIT", function(state)
            return hatchOn and hasEligibleEgg(state)
        end)
		if r == "cancelled" then return end
        if r == "reconsider" then continue end
		local t = os.clock()
        local eggsAppeared = false
		while running and token == moveToken do
			local s3 = getState()
			if not s3 or s3.floor ~= floor or os.clock() - t > 8 then break end
            if hatchOn and hasEligibleEgg(s3) then eggsAppeared = true; break end
			setStatus("✅ at exit, waiting for next floor..."); task.wait(0.2)
		end
        if eggsAppeared then continue end
		task.wait(0.5)
	end
end

-- ───────── job control ─────────
local autoBtn
local function refreshAutoBtn()
	if autoBtn then
		autoBtn.Text = autoOn and "AUTO: ON" or "AUTO: OFF"
		autoBtn.BackgroundColor3 = autoOn and Color3.fromRGB(45, 110, 65) or Color3.fromRGB(70, 60, 90)
	end
end
local function stopMotion()
	local hum, root = getHum(), getRoot()
	if hum and root then hum:MoveTo(root.Position) end
end
local function stopAll(msg)
	moveToken += 1; autoOn = false; jobRunning = false; preview = nil
	setAutoHatch(false)
	refreshAutoBtn(); stopMotion(); clearPath(); setStatus(msg or "🛑 Stopped")
end
local function startJob(fn)
	moveToken += 1
	local t = moveToken
	jobRunning = true; preview = nil
	task.spawn(function()
		local ok, err = pcall(fn, t)
		if not ok then warn("[HMV2] " .. tostring(err)) end
		if t == moveToken then
			jobRunning = false; autoOn = false; setAutoHatch(false); refreshAutoBtn(); stopMotion(); clearPath(); setStatus("Idle")
		end
	end)
end
local function moveEgg(egg)
	startJob(function(t)
        local r = walk(t, function() if egg.Parent then return posOf(egg) end end, sameCellTarget, "Egg", nil, true)
		if r == "arrived" and hatchOn then hatchAt(t, egg, true) end
	end)
end
local function moveExit() startJob(function(t) walk(t, exitTarget, EXIT_STOP, "EXIT") end) end
local function pathEgg(egg) preview = {get = function() if egg.Parent then return posOf(egg) end end} end
local function pathExit() preview = {get = function(st) return exitTarget(st) end} end

-- ───────── UI ─────────
local old = PlayerGui:FindFirstChild("HalloweenMazeUI"); if old then old:Destroy() end

-- dock into the hub (it already exists when merged; the wait only matters if the hub is still building)
local hubGui, hubMain, hubTabs
for _ = 1, 30 do
	hubGui = PlayerGui:FindFirstChild("CombinedAutomationUI")
	hubMain = hubGui and hubGui:FindFirstChild("AutoHatchMain")
	hubTabs = hubMain and hubMain:FindFirstChild("TabContainer")
	local n = 0
	if hubTabs then for _, c in ipairs(hubTabs:GetChildren()) do if c:IsA("TextButton") then n += 1 end end end
	if n >= 5 then break end
	hubGui, hubMain, hubTabs = nil, nil, nil
	task.wait(0.2)
end

local W, H = 596, 614
local ownGui, Root, Win, titleBar
local ddParent
if hubMain then
	ddParent = hubGui
	Root = new("Frame", {Name = "MazeTab", Size = UDim2.new(1, -24, 1, -96), Position = UDim2.fromOffset(12, 90),
		BackgroundTransparency = 1, Visible = false}, hubMain)
else
	ownGui = new("ScreenGui", {Name = "HalloweenMazeUI", ResetOnSpawn = false, IgnoreGuiInset = true}, PlayerGui)
	ddParent = ownGui
	Win = new("Frame", {Size = UDim2.fromOffset(W + 24, H + 50), Position = UDim2.new(0, 20, 0.5, -(H + 50) / 2),
		BackgroundColor3 = COL.bg, BorderSizePixel = 0}, ownGui)
	corner(Win, 12)
	titleBar = new("Frame", {Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, Active = true}, Win)
	Root = new("Frame", {Position = UDim2.fromOffset(12, 38), Size = UDim2.fromOffset(W, H), BackgroundTransparency = 1}, Win)
end

local function label(parent, text, size, color, ts, align)
	return new("TextLabel", {Text = text, Size = size, BackgroundTransparency = 1, TextColor3 = color or COL.white,
		TextSize = ts or 14, Font = Enum.Font.GothamBold, TextXAlignment = align or Enum.TextXAlignment.Left,
		TextWrapped = true}, parent)
end
local function button(parent, text, size, color, cb)
	local b = new("TextButton", {Text = text, Size = size, BackgroundColor3 = color, TextColor3 = COL.white,
		Font = Enum.Font.GothamBold, TextSize = 12, BorderSizePixel = 0}, parent)
	b:SetAttribute("ThemeLocked", true) -- keep the maze tab's own colours when the hub re-themes buttons
	corner(b, 6); bind(b.MouseButton1Click, cb); return b
end

local pageNav = new("Frame", {Name = "MazePages", Size = UDim2.fromOffset(340, 30), BackgroundTransparency = 1}, Root)
local overviewTab = button(pageNav, "OVERVIEW", UDim2.new(0.5, -2, 1, 0), Color3.fromRGB(48, 105, 83), function() end)
local eggSettingsTab = button(pageNav, "EGG SETTINGS", UDim2.new(0.5, -2, 1, 0), Color3.fromRGB(38, 49, 46), function() end)
eggSettingsTab.Position = UDim2.new(0.5, 2, 0, 0)

local Content = new("Frame", {Name = "Content", Position = UDim2.fromOffset(0, 34), Size = UDim2.new(0, 340, 1, -34),
	BackgroundTransparency = 1}, Root)
new("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder}, Content)
local eggSettingsPage = new("Frame", {Name = "EggSettingsPage", Position = UDim2.fromOffset(0, 34), Size = UDim2.new(0, 340, 1, -34),
    BackgroundTransparency = 1, Visible = false}, Root)
local eggConfigScroll = new("ScrollingFrame", {Name = "EggConfigList", Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4, CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y}, eggSettingsPage)
new("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, eggConfigScroll)
new("UIPadding", {PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 4)}, eggConfigScroll)
local function showEggSettings(show)
    Content.Visible = not show
    eggSettingsPage.Visible = show
    overviewTab.BackgroundColor3 = show and Color3.fromRGB(38, 49, 46) or Color3.fromRGB(48, 105, 83)
    eggSettingsTab.BackgroundColor3 = show and Color3.fromRGB(48, 105, 83) or Color3.fromRGB(38, 49, 46)
end
bind(overviewTab.MouseButton1Click, function() showEggSettings(false) end)
bind(eggSettingsTab.MouseButton1Click, function() showEggSettings(true) end)
local order = 0
local function row(h, horizontal)
	order += 1
	local f = new("Frame", {Size = UDim2.new(1, 0, 0, h), BackgroundTransparency = 1, LayoutOrder = order}, Content)
	if horizontal then new("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4),
		VerticalAlignment = Enum.VerticalAlignment.Center}, f) end
	return f
end
local function card(h)
    local f = row(h); f.BackgroundTransparency = 0; f.BackgroundColor3 = COL.card; corner(f, 8)
    new("UIStroke", {Color = Color3.fromRGB(100, 145, 125), Thickness = 1, Transparency = 0.78}, f)
    return f
end

local openList
local function closeDD() if openList then openList.Visible = false; openList = nil end end
local function dropdown(parent, size, getText, getItems, onPick, multi)
	local btn = button(parent, "", size, Color3.fromRGB(55, 50, 75), function() end)
	btn.TextSize = 11
	local list = new("Frame", {Size = UDim2.fromOffset(180, 0), AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(28, 28, 34), BorderSizePixel = 0, Visible = false, ZIndex = 60}, ddParent)
	ddLists[#ddLists + 1] = list
	corner(list, 6)
	new("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder}, list)
	local function rebuild()
		for _, c in ipairs(list:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
		for i, it in ipairs(getItems()) do
			local mark = multi and (it.checked and "☑ " or "☐ ") or (it.checked and "● " or "   ")
			local b = new("TextButton", {Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = Color3.fromRGB(42, 42, 50),
				Text = mark .. it.text, TextColor3 = COL.white, Font = Enum.Font.GothamBold, TextSize = 12,
				BorderSizePixel = 0, ZIndex = 61, LayoutOrder = i, TextXAlignment = Enum.TextXAlignment.Left}, list)
			b:SetAttribute("ThemeLocked", true)
			bind(b.MouseButton1Click, function()
				onPick(it.key); btn.Text = getText()
				if multi then rebuild() else closeDD() end
			end)
		end
	end
	bind(btn.MouseButton1Click, function()
		if openList == list then closeDD(); return end
		closeDD(); rebuild()
		local us = ddParent:FindFirstChildOfClass("UIScale")
		local sc = us and us.Scale or 1
		local ap, as = btn.AbsolutePosition, btn.AbsoluteSize
		list.Position = UDim2.fromOffset(ap.X / sc, (ap.Y + as.Y + 2) / sc)
		list.Size = UDim2.fromOffset(math.max(as.X / sc, 170), 0)
		list.Visible = true; openList = list
	end)
	btn.Text = getText()
	return btn
end

-- window chrome (standalone only) / hub tab (docked)
local tabBtn, hubBtns, origTab = nil, {}, {}
local selColor, unselColor = Color3.fromRGB(60, 140, 220), Color3.fromRGB(32, 32, 42)
if ownGui then
	label(titleBar, "🎃 HALLOWEEN MAZE v3", UDim2.new(1, -80, 1, 0), COL.white, 17).Position = UDim2.fromOffset(10, 0)
	local minimized = false
	button(titleBar, "–", UDim2.fromOffset(26, 24), Color3.fromRGB(60, 60, 70), function()
		closeDD()
		minimized = not minimized
		Root.Visible = not minimized
		Win.Size = minimized and UDim2.fromOffset(W + 24, 36) or UDim2.fromOffset(W + 24, H + 50)
	end).Position = UDim2.new(1, -62, 0, 6)
	button(titleBar, "✕", UDim2.fromOffset(26, 24), Color3.fromRGB(120, 45, 45), function() env.HMV2.Destroy() end).Position = UDim2.new(1, -32, 0, 6)
	local dragging, dragStart, startPos
	bind(titleBar.InputBegan, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			closeDD(); dragging, dragStart, startPos = true, i.Position, Win.Position
		end
	end)
	bind(UIS.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			Win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	bind(UIS.InputEnded, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end)
else
	for _, c in ipairs(hubTabs:GetChildren()) do if c:IsA("TextButton") then hubBtns[#hubBtns + 1] = c end end
	table.sort(hubBtns, function(a, b) return a.Position.X.Scale < b.Position.X.Scale end)
	local n = #hubBtns + 1
	for i, b in ipairs(hubBtns) do
		origTab[b] = {size = b.Size, pos = b.Position}
		b.Size = UDim2.new(1 / n - 0.006, 0, 1, 0)
		b.Position = UDim2.new((i - 1) / n, 0, 0, 0)
	end
	tabBtn = new("TextButton", {Name = "MazeTabButton", Size = UDim2.new(1 / n - 0.006, 0, 1, 0),
		Position = UDim2.new((n - 1) / n, 0, 0, 0), Text = "🎃 Maze", BackgroundColor3 = unselColor,
		TextColor3 = Color3.fromRGB(180, 180, 190), Font = Enum.Font.GothamBold, TextSize = 12}, hubTabs)
	corner(tabBtn, 6)
	new("UIStroke", {Color = Color3.fromRGB(80, 80, 100), Thickness = 1, Transparency = 0.8}, tabBtn)

	local function hubColors()
		local sel, unsel
		for _, b in ipairs(hubBtns) do
			if b.TextColor3 == Color3.fromRGB(255, 255, 255) then sel = sel or b.BackgroundColor3
			else unsel = unsel or b.BackgroundColor3 end
		end
		return sel, unsel
	end
	do local s, u = hubColors(); selColor, unselColor = s or selColor, u or unselColor end
	local function hubFrames()
		local out = {}
		for _, c in ipairs(hubMain:GetChildren()) do
			if c ~= Root and (c:IsA("Frame") or c:IsA("ScrollingFrame")) and c.Position.Y.Offset == 90 then out[#out + 1] = c end
		end
		return out
	end
	bind(tabBtn.MouseButton1Click, function()
		closeDD()
		local s, u = hubColors()
		selColor, unselColor = s or selColor, u or unselColor
		for _, f in ipairs(hubFrames()) do f.Visible = false end
		for _, b in ipairs(hubBtns) do b.BackgroundColor3 = unselColor; b.TextColor3 = Color3.fromRGB(180, 180, 190) end
		tabBtn.BackgroundColor3 = selColor; tabBtn.TextColor3 = Color3.new(1, 1, 1)
		Root.Visible = true
	end)
	for _, b in ipairs(hubBtns) do
		bind(b.MouseButton1Click, function()
			closeDD(); Root.Visible = false
			local _, u = hubColors()
			tabBtn.BackgroundColor3 = u or unselColor; tabBtn.TextColor3 = Color3.fromRGB(180, 180, 190)
		end)
	end
end

-- info
local info = card(78)
new("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder}, info)
new("UIPadding", {PaddingLeft = UDim.new(0, 8), PaddingTop = UDim.new(0, 2)}, info)
local floorLbl = label(info, "Floor: -", UDim2.new(1, -8, 0, 22), COL.white, 14)
local luckLbl = label(info, "🍀 Luck: -", UDim2.new(1, -8, 0, 28), COL.luck, 13)
local scareLbl = label(info, "🎃 Scarecrow: -", UDim2.new(1, -8, 0, 22), COL.scare, 14)
local statusLbl = label(row(22), "Idle", UDim2.fromScale(1, 1), Color3.fromRGB(150, 210, 255), 13)
statusLbl.Name = "Status"
local minimapStatusLbl
setStatus = function(t)
    if statusLbl and statusLbl.Parent then statusLbl.Text = t end
    if minimapStatusLbl and minimapStatusLbl.Parent then minimapStatusLbl.Text = t end
end

-- speed
local sp = row(30, true)
label(sp, "Speed", UDim2.fromOffset(50, 28), COL.white, 14)
local speedBox = new("TextBox", {Size = UDim2.fromOffset(60, 28), Text = tostring(desiredSpeed), BackgroundColor3 = Color3.fromRGB(25, 25, 30),
	TextColor3 = COL.white, Font = Enum.Font.Gotham, TextSize = 14, ClearTextOnFocus = false, BorderSizePixel = 0}, sp)
corner(speedBox, 6)
local function applySpeed()
	local v = tonumber(speedBox.Text)
	if v and v > 0 then desiredSpeed = math.clamp(v, 1, 100) end
	speedBox.Text = tostring(desiredSpeed)
	saveSettings()
end
button(sp, "SET", UDim2.fromOffset(50, 28), Color3.fromRGB(60, 80, 60), applySpeed)
bind(speedBox.FocusLost, function() applySpeed() end)
label(sp, "(game: " .. tostring(getCfg().PlayerSpeed or 20) .. ")", UDim2.fromOffset(90, 28), Color3.fromRGB(170, 170, 170), 12)

-- toggles
local function toggle(parent, text, default, cb, width)
	local state = default
	local b
	local function paint() b.Text = text .. (state and ": ON" or ": OFF"); b.BackgroundColor3 = state and Color3.fromRGB(45, 105, 65) or Color3.fromRGB(80, 45, 45) end
	b = button(parent, text, width or UDim2.new(0.25, -3, 1, 0), COL.card, function() state = not state; paint(); cb(state) end)
	b.TextSize = 11; paint(); return b
end
local function setZoom(v)
	zoomOn = v
	pcall(function() Player.CameraMaxZoomDistance = v and 120 or (tonumber(getCfg().CameraMaxZoom) or 22) end)
end
local tg = row(28, true)
toggle(tg, "AVOID", avoidOn, function(v) avoidOn = v; saveSettings() end)
toggle(tg, "CANDY1ST", candyFirst, function(v) candyFirst = v; saveSettings() end)
toggle(tg, "🍬ESP", candyEsp, function(v) candyEsp = v; saveSettings() end)
toggle(tg, "ZOOM", zoomOn, function(v) setZoom(v); saveSettings() end)
if zoomOn then setZoom(true) end
local tg2 = row(28, true)
local third = UDim2.new(1 / 3, -3, 1, 0)
toggle(tg2, "HATCH", hatchOn, function(v) hatchOn = v; saveSettings() end, third)
toggle(tg2, "ESCAPE", escapeOn, function(v) escapeOn = v; saveSettings() end, third)
toggle(tg2, "SCOUT", scoutOn, function(v) scoutOn = v; saveSettings() end, third)
local tg3 = row(28, true)
local half = UDim2.new(0.5, -3, 1, 0)
toggle(tg3, "PATH", pathVisible, function(v)
    pathVisible = v
    refreshPathVisibility()
    saveSettings()
end, half)
toggle(tg3, "PIN MAP", minimapWhenHidden, function(v)
    minimapWhenHidden = v
    saveSettings()
    if updateMinimapAttachment then updateMinimapAttachment() end
end, half)

-- Per-egg configuration options
local luckOptions = {}
do
	local seen = {}
	for _, t in ipairs(getCfg().LuckTable or {}) do
		local m = tonumber(t.Mult)
		if m and not seen[m] then seen[m] = true; luckOptions[#luckOptions + 1] = m end
	end
	if #luckOptions == 0 then luckOptions = {1, 2, 5, 10, 100, 1000} end
	table.sort(luckOptions)
end
local timeOptions = {{15, "15 seconds"}, {30, "30 seconds"}, {60, "1 minute"}, {120, "2 minutes"}, {300, "5 minutes"},
	{600, "10 minutes"}, {0, "Until lucky eggs run out"}}
local function timeLabel(seconds)
    for _, option in ipairs(timeOptions) do
        if option[1] == seconds then
            return seconds == 0 and "∞" or option[2]:gsub(" seconds", "s"):gsub(" minutes?", "m")
        end
    end
    return tostring(seconds) .. "s"
end
label(eggConfigScroll, "EGG TARGETS  /  individual automation rules", UDim2.new(1, -4, 0, 26), COL.luck, 12)
local function addEggConfig(name, index)
    local config = settingsForEgg(name)
    local frame = new("Frame", {Name = "EggConfig_" .. tostring(index), Size = UDim2.new(1, -8, 0, 60),
        BackgroundColor3 = COL.card, BorderSizePixel = 0, LayoutOrder = index}, eggConfigScroll)
    corner(frame, 6)
    new("UIStroke", {Color = Color3.fromRGB(100, 145, 125), Thickness = 1, Transparency = 0.82}, frame)
    local nameLabel = label(frame, name, UDim2.new(1, -10, 0, 21), COL.white, 11)
    nameLabel.Position = UDim2.fromOffset(6, 1)
    local enabledButton
    local function paintEnabled()
        enabledButton.Text = config.enabled and "ON" or "OFF"
        enabledButton.BackgroundColor3 = config.enabled and Color3.fromRGB(45, 110, 78) or Color3.fromRGB(82, 55, 49)
    end
    enabledButton = button(frame, "", UDim2.fromOffset(50, 26), COL.card, function()
        config.enabled = not config.enabled
        paintEnabled(); saveSettings()
    end)
    enabledButton.Position = UDim2.fromOffset(6, 28)
    paintEnabled()
    local luckButton = dropdown(frame, UDim2.fromOffset(100, 26),
        function() return ("LUCK x%d+ ▼"):format(config.minLuck) end,
        function()
            local items = {}
            for _, value in ipairs(luckOptions) do
                items[#items + 1] = {key = value, text = "x" .. value .. " or better", checked = config.minLuck == value}
            end
            return items
        end,
        function(value) config.minLuck = value; saveSettings() end, false)
    luckButton.Position = UDim2.fromOffset(62, 28)
    local durationButton = dropdown(frame, UDim2.fromOffset(162, 26),
        function() return "TIME " .. timeLabel(config.hatchSeconds) .. " ▼" end,
        function()
            local items = {}
            for _, option in ipairs(timeOptions) do
                items[#items + 1] = {key = option[1], text = option[2], checked = config.hatchSeconds == option[1]}
            end
            return items
        end,
        function(value) config.hatchSeconds = value; saveSettings() end, false)
    durationButton.Position = UDim2.fromOffset(166, 28)
end
for index, name in ipairs(eggNames) do addEggConfig(name, index) end

-- actions
local ac = row(32, true)
button(ac, "🍬 CANDY", third, Color3.fromRGB(110, 90, 30), function() startJob(collectCandy) end)
button(ac, "🚪 EXIT", third, Color3.fromRGB(110, 55, 40), moveExit)
button(ac, "PATH EXIT", third, Color3.fromRGB(30, 80, 130), pathExit)
local ac2 = row(32, true)
autoBtn = button(ac2, "AUTO: OFF", third, Color3.fromRGB(70, 60, 90), function()
	if autoOn then stopAll("Auto stopped"); return end
	startJob(function(t) autoOn = true; refreshAutoBtn(); autoLoop(t) end)
end)
button(ac2, "🔍 SCOUT", third, Color3.fromRGB(60, 80, 110), function() startJob(scoutEggs) end)
button(ac2, "🛑 STOP (X)", third, Color3.fromRGB(120, 45, 45), function() stopAll() end)

-- eggs
label(row(22), "🥚 EGGS  (MOVE = walk + hatch)", UDim2.fromScale(1, 1), COL.egg, 14)
local eggScroll = new("ScrollingFrame", {Name = "EggList", Size = UDim2.new(1, 0, 0, 200), BackgroundColor3 = Color3.fromRGB(25, 25, 30),
	BorderSizePixel = 0, ScrollBarThickness = 5, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, LayoutOrder = 100}, Content)
corner(eggScroll, 8)
new("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}, eggScroll)
local eggRows = {}
local function refreshEggList()
	local st = getState()
	local seen = {}
	for idx, egg in ipairs(getEggs()) do
		seen[egg] = true
		local mult, left, name = eggLuck(st, egg)
		local text = ("%s%s"):format(tostring(name or egg:GetAttribute("ID") or "Egg"), luckText(mult, left))
		if rejected[egg] then text ..= "  ✖ " .. rejected[egg] end
		local r = eggRows[egg]
		if not r then
			local f = new("Frame", {Size = UDim2.new(1, -8, 0, 34), BackgroundColor3 = COL.card, BorderSizePixel = 0, LayoutOrder = idx}, eggScroll)
			corner(f, 6)
			local l = label(f, text, UDim2.new(1, -140, 1, 0), COL.egg, 11); l.Position = UDim2.fromOffset(6, 0)
			local m = button(f, "MOVE", UDim2.fromOffset(60, 26), Color3.fromRGB(50, 80, 60), function() if egg.Parent then moveEgg(egg) end end)
			m.Position = UDim2.new(1, -130, 0.5, -13)
			local p = button(f, "PATH", UDim2.fromOffset(60, 26), Color3.fromRGB(30, 80, 130), function() if egg.Parent then pathEgg(egg) end end)
			p.Position = UDim2.new(1, -66, 0.5, -13)
			r = {frame = f, lbl = l}; eggRows[egg] = r
		end
		r.lbl.Text = text; r.lbl.TextColor3 = mult >= 100 and COL.luck or COL.egg; r.frame.LayoutOrder = idx
	end
	for egg, r in pairs(eggRows) do
		if not seen[egg] then r.frame:Destroy(); eggRows[egg] = nil end
	end
end

-- minimap + speed readout (right column)
local MM = new("Frame", {Name = "Minimap", Position = UDim2.fromOffset(346, 0), Size = UDim2.fromOffset(250, 292), BackgroundColor3 = COL.bg, BorderSizePixel = 0}, Root)
corner(MM, 12)
label(MM, "🗺 MINIMAP   ⚪you 🔴scarecrow 🟠exit 🟡candy 🟢egg", UDim2.new(1, -10, 0, 40), COL.white, 11).Position = UDim2.fromOffset(8, 0)
local canvas = new("Frame", {Position = UDim2.fromOffset(5, 44), Size = UDim2.fromOffset(240, 240),
	BackgroundColor3 = Color3.fromRGB(12, 12, 16), BorderSizePixel = 0, ClipsDescendants = true}, MM)
local wallLayer = new("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1}, canvas)
local dotLayer = new("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 5}, canvas)
local speedCard = new("Frame", {Position = UDim2.fromOffset(346, 300), Size = UDim2.fromOffset(250, 96), BackgroundColor3 = COL.card, BorderSizePixel = 0}, Root)
corner(speedCard, 10)
local speedLbl = label(speedCard, "⚙ Speeds: -", UDim2.new(1, -16, 1, -12), Color3.fromRGB(190, 200, 215), 12)
speedLbl.Position = UDim2.fromOffset(8, 6); speedLbl.TextYAlignment = Enum.TextYAlignment.Top
local mapOverlayGui = new("ScreenGui", {Name = "HMV2_MinimapOverlay", ResetOnSpawn = false,
    IgnoreGuiInset = true, DisplayOrder = 1000, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = false}, PlayerGui)
local mapOverlayScale = new("UIScale", {Scale = 1}, mapOverlayGui)
local mapOverlayRoot = new("Frame", {Name = "Overlay", Size = UDim2.fromOffset(250, 450), AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -12, 0, 12), BackgroundTransparency = 1}, mapOverlayGui)
local miniStatusCard = new("Frame", {Name = "NavigationStatus", Position = UDim2.fromOffset(0, 402),
    Size = UDim2.fromOffset(250, 48), BackgroundColor3 = COL.card, BorderSizePixel = 0}, mapOverlayRoot)
corner(miniStatusCard, 8)
minimapStatusLbl = label(miniStatusCard, "Idle", UDim2.new(1, -16, 1, -8), Color3.fromRGB(150, 210, 255), 13)
minimapStatusLbl.Position = UDim2.fromOffset(8, 4)
minimapStatusLbl.TextYAlignment = Enum.TextYAlignment.Center
local mapDetached = false
local function mazeUiVisible()
    local current = Root
    while current and current:IsA("GuiObject") do
        if not current.Visible then return false end
        current = current.Parent
    end
    return true
end
local function updateMapOverlayScale()
    local camera = Workspace.CurrentCamera
    if not camera then return end
    local viewport = camera.ViewportSize
    local scale = math.min((viewport.X - 24) / 250, (viewport.Y - 24) / 450, 1)
    mapOverlayScale.Scale = math.max(scale, 0.35)
end
local overlayCameraConnection
local function hookMapOverlayCamera()
    if overlayCameraConnection then overlayCameraConnection:Disconnect() end
    local camera = Workspace.CurrentCamera
    if camera then
        overlayCameraConnection = bind(camera:GetPropertyChangedSignal("ViewportSize"), updateMapOverlayScale)
    end
    updateMapOverlayScale()
end
updateMinimapAttachment = function()
    local detached = minimapWhenHidden and not mazeUiVisible()
    if detached ~= mapDetached then
        mapDetached = detached
        if detached then
            MM.Parent = mapOverlayRoot
            MM.Position = UDim2.fromOffset(0, 0)
            speedCard.Parent = mapOverlayRoot
            speedCard.Position = UDim2.fromOffset(0, 300)
        else
            MM.Parent = Root
            MM.Position = UDim2.fromOffset(346, 0)
            speedCard.Parent = Root
            speedCard.Position = UDim2.fromOffset(346, 300)
        end
    end
    mapOverlayGui.Enabled = detached
    if detached then updateMapOverlayScale() end
end
local visibilityAncestor = Root
while visibilityAncestor and visibilityAncestor:IsA("GuiObject") do
    bind(visibilityAncestor:GetPropertyChangedSignal("Visible"), updateMinimapAttachment)
    visibilityAncestor = visibilityAncestor.Parent
end
bind(Workspace:GetPropertyChangedSignal("CurrentCamera"), hookMapOverlayCamera)
hookMapOverlayCamera()
updateMinimapAttachment()
local mmKey
local function rebuildMinimap(st, g)
	wallLayer:ClearAllChildren()
	local cp = 240 / st.n
	for _, r in ipairs(Common.WallRuns(g)) do
		local x1, y1, x2, y2 = r[1], r[2], r[3], r[4]
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0; f.BackgroundColor3 = Color3.fromRGB(150, 150, 170)
		if y1 == y2 then
			f.Position = UDim2.fromOffset(x1 * cp, y1 * cp - 1); f.Size = UDim2.fromOffset((x2 - x1) * cp, 2)
		else
			f.Position = UDim2.fromOffset(x1 * cp - 1, y1 * cp); f.Size = UDim2.fromOffset(2, (y2 - y1) * cp)
		end
		f.Parent = wallLayer
	end
end
local function dots(name, count, color, size, z)
	local p = pools[name]; if not p then p = {}; pools[name] = p end
	for i = #p + 1, count do
		p[i] = new("Frame", {BackgroundColor3 = color, Size = UDim2.fromOffset(size, size), AnchorPoint = Vector2.new(0.5, 0.5),
			BorderSizePixel = 0, ZIndex = z}, dotLayer)
	end
	for i = 1, #p do p[i].Visible = i <= count end
	return p
end
local function updateMinimap()
    if not mazeUiVisible() and not mapOverlayGui.Enabled then return end
	local st = getState(); if not st then return end
	local g = grid(st)
	local key = st.walls .. ":" .. tostring(st.floor)
	if key ~= mmKey then mmKey = key; rebuildMinimap(st, g) end
	local cp = 240 / st.n
	local function xy(p) return UDim2.fromOffset((p.X - st.origin.X) / st.cs * cp, (p.Z - st.origin.Z) / st.cs * cp) end
	local rt = (lastRoute and lastRouteFloor == st.floor) and lastRoute or {}
    local rd = dots("route", pathVisible and #rt or 0, COL.path, 4, 1)
    if pathVisible then
        for i, c in ipairs(rt) do rd[i].Position = xy(cellPos(st, c)) end
    end
	local cm = candyModels()
	local cd = dots("candy", #cm, COL.candy, 5, 2)
	for i, c in ipairs(cm) do local p = posOf(c); if p then cd[i].Position = xy(p) end end
	local eg = getEggs()
	local ed = dots("egg", #eg, COL.egg, 8, 3)
	for i, e in ipairs(eg) do local p = posOf(e); if p then ed[i].Position = xy(p) end end
	dots("exit", 1, COL.exit, 10, 3)[1].Position = xy(cellPos(st, st.exit))
	local mp = monsterInfo(st)
	local sd = dots("scare", mp and 1 or 0, Color3.fromRGB(255, 50, 50), 10, 6)
	if mp and sd[1] then sd[1].Position = xy(mp) end
	local root = getRoot()
	local pd = dots("me", root and 1 or 0, COL.white, 8, 7)
	if root and pd[1] then pd[1].Position = xy(root.Position) end
end

-- ───────── loops ─────────
local function onUpdateInfo()
	local st = getState()
	if not st then
		floorLbl.Text = "Floor: - (enter the Halloween maze)"; luckLbl.Text = "🍀 Luck: -"; scareLbl.Text = "🎃 Scarecrow: -"; scareText = ""
		speedLbl.Text = "⚙ Speeds: -"
		return
	end
	floorLbl.Text = ("Floor %d  ·  Best %d  ·  %dx%d  ·  🍬 %d left"):format(st.floor or 0, st.best or 0, st.n, st.n, #candyModels())
	local parts = {}
	for _, e in ipairs(st.eggs or {}) do
		parts[#parts + 1] = ("%s%s"):format((tostring(e.egg or "?")):gsub(" Egg", ""), luckText(tonumber(e.mult) or 0, e.left))
	end
	luckLbl.Text = "🍀 " .. (#parts > 0 and table.concat(parts, "  |  ") or "no eggs")
	local g = grid(st)
	local root = getRoot()
	local me = root and posCell(st, root.Position)
	local dm, hunting = danger(st, g)
	if dm and me then
		local d = dm[me] or 99
		scareText = (" %d%s"):format(d, hunting and " HUNT" or "")
		scareLbl.Text = ("🎃 Scarecrow: %d cells away%s"):format(d, hunting and "  ⚠ HUNTING" or "")
		scareLbl.TextColor3 = d <= 3 and Color3.fromRGB(255, 80, 80) or COL.scare
		local sP, sS = speeds(st, hunting, d)
		speedLbl.Text = ("⚙ You: %.1f cells/s\n🎃 Scarecrow now: %.1f cells/s\n   seen walk %s · hunt %s\n🔍 Unknown-luck eggs: %d"):format(
			sP, sS, scareSeen.walk and ("%.1f"):format(scareSeen.walk) or "?", scareSeen.hunt and ("%.1f"):format(scareSeen.hunt) or "?",
			(function() local n = 0; for _, e in ipairs(getEggs()) do if eggLuck(st, e) == 0 then n += 1 end end; return n end)())
	else
		scareText = ""; scareLbl.Text = "🎃 Scarecrow: not found"; scareLbl.TextColor3 = COL.scare
		speedLbl.Text = "⚙ Speeds: scarecrow not found"
	end
end

local function loop(dt, fn)
	task.spawn(function()
		while running do
			local ok, err = pcall(fn)
			if not ok then warn("[HMV2] " .. tostring(err)) end
			task.wait(dt)
		end
	end)
end
loop(0.25, onUpdateInfo)
loop(0.5, refreshESP)
loop(1, refreshEggList)
loop(0.25, updateMinimap)
loop(0.25, function() -- blue path preview while idle
	if preview and not jobRunning then
		local st, root = getState(), getRoot()
		local tp = st and preview.get(st)
		local me = st and root and posCell(st, root.Position)
		local goal = tp and posCell(st, tp)
		if me and goal then
			local route, mode = plan(st, grid(st), me, goal, {})
			if route then drawRoute(st, route, tp, root.Position.Y); setStatus("PATH preview [" .. mode .. "]") end
		end
	end
end)
bind(UIS.InputBegan, function(i, gp)
	if not gp and i.KeyCode == Enum.KeyCode.X then stopAll() end
end)
bind(RunService.Heartbeat, function()
	local hum = getHum()
	if hum and hum.WalkSpeed ~= desiredSpeed then hum.WalkSpeed = desiredSpeed end
end)
bind(Player.CharacterAdded, function() stopAll("Respawned") end)

local function destroy()
	running = false; moveToken += 1; autoOn = false
	setAutoHatch(false)
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	for _, e in pairs(esp) do pcall(function() e.gui:Destroy() end) end
	for _, l in ipairs(ddLists) do pcall(function() l:Destroy() end) end
    pcall(function() mapOverlayGui:Destroy() end)
	if ownGui then pcall(function() ownGui:Destroy() end) end
	if hubMain then
		local wasOpen = Root.Visible
		pcall(function() Root:Destroy() end)
		pcall(function() tabBtn:Destroy() end)
		for b, o in pairs(origTab) do pcall(function() b.Size = o.size; b.Position = o.pos end) end
		if wasOpen then
			pcall(function()
				for _, c in ipairs(hubMain:GetChildren()) do
					if c:IsA("ScrollingFrame") and c.Position.Y.Offset == 90 then c.Visible = true end
				end
				if hubBtns[1] then hubBtns[1].BackgroundColor3 = selColor; hubBtns[1].TextColor3 = Color3.new(1, 1, 1) end
			end)
		end
	end
	pcall(function() pathFolder:Destroy() end)
	if env.HMV2 and env.HMV2.Destroy == destroy then env.HMV2 = nil end
end
env.HMV2 = {Destroy = destroy, GetState = getState,
	Test = function()
		local st, root = getState(), getRoot()
		if not (st and root) then return "no state" end
		local me = posCell(st, root.Position)
		local route, mode, dme = plan(st, grid(st), me, st.exit, {})
		local dm, hunting = danger(st, grid(st))
		local sP, sS
		if dm then sP, sS = speeds(st, hunting, dm[me]) end
		return {floor = st.floor, n = st.n, me = me, exit = st.exit, len = route and #route, mode = mode, scareDist = dme,
			playerCellsPerSec = sP, scareCellsPerSec = sS, seen = scareSeen, candies = #candyModels(), eggs = #getEggs(),
			docked = hubMain ~= nil}
	end,
	HatchNearest = function(sec)
		local st, root = getState(), getRoot()
		if not (st and root) then return "no state" end
		local best, bd
		for _, e in ipairs(getEggs()) do
			local p = posOf(e); local d = p and hdist(root.Position, p)
			if d and (not bd or d < bd) then best, bd = e, d end
		end
		if not best then return "no egg" end
        local eggConfig = settingsForEgg(best:GetAttribute("ID"))
        eggConfig.hatchSeconds = sec or eggConfig.hatchSeconds
		startJob(function(t)
            local r = walk(t, function() if best.Parent then return posOf(best) end end, sameCellTarget, "Egg", nil, true)
			if r == "arrived" then hatchAt(t, best, true) end
		end)
		return "started " .. tostring(best:GetAttribute("ID"))
	end}
print("🎃 Halloween Maze v3 loaded" .. (hubMain and " (docked into the hub)" or ""))
end)
end)
