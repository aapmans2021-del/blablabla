-- =====================================================================
-- COMBINED AUTOMATION SCRIPT: UNIFIED UI + FIXED AUTO TOKENS + PET TRACKER
-- HATCH LOGIC + EGG CHANCE VIEWER + AUTO FARM & PET TRACKER
-- EXECUTOR-NEUTRAL VERSION
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

-- ------------------------------------------------------------------
-- Cross-executor compatibility shims.
-- Every executor exposes task.* or the classic Roblox spawn/wait globals;
-- use a single local wrapper so no feature dies on a missing field.
-- ------------------------------------------------------------------
local TaskLib = type(task) == "table" and task or {}
local taskSpawn = type(TaskLib.spawn) == "function" and TaskLib.spawn or spawn
local taskWait = type(TaskLib.wait) == "function" and TaskLib.wait or wait
local taskDelay = type(TaskLib.delay) == "function" and TaskLib.delay or delay
local defer = type(TaskLib.defer) == "function" and TaskLib.defer or taskSpawn
local taskCancel = type(TaskLib.cancel) == "function" and TaskLib.cancel or function() end

-- A few Luau library helpers are missing on older/Lua 5.1-style executors.
if type(math.clamp) ~= "function" then
    math.clamp = function(value, minValue, maxValue)
        if value < minValue then return minValue end
        if value > maxValue then return maxValue end
        return value
    end
end
if type(table.find) ~= "function" then
    table.find = function(haystack, needle, init)
        local startIndex = tonumber(init) or 1
        if startIndex < 1 then startIndex = 1 end
        for index = startIndex, #haystack do
            if haystack[index] == needle then return index end
        end
        return nil
    end
end

-- Safely obtain an executor environment when one exists, otherwise use the
-- ordinary Lua environment. This avoids assuming a particular executor API.
local function getExecutorEnv()
    if type(getgenv) == "function" then
        local ok, env = pcall(getgenv)
        if ok and type(env) == "table" then
            return env
        end
    end
    return _G
end

-- ------------------------------------------------------------------
-- Touch simulation helper.
-- Executors disagree about firetouchinterest's argument order, and some
-- remove it entirely. Prefer firing the game's Touched handlers directly,
-- then try both firetouchinterest orders, then a TouchInterest object and
-- finally ProximityPrompt. An optional verify callback stops after the first
-- method that actually advances the game state, avoiding double triggers.
-- ------------------------------------------------------------------
local function findTouchInterestObject(part)
    if not part or type(part.GetDescendants) ~= "function" then return nil end
    for _, child in ipairs(part:GetDescendants()) do
        local className = child.ClassName
        if className == "TouchInterest" or className == "TouchTransmitter" then
            return child
        end
    end
    return nil
end

local function connectionHandler(connection)
    if type(connection) ~= "table" and type(connection) ~= "userdata" then return nil end
    if connection.Enabled == false then return nil end
    if type(connection.Function) == "function" then
        return connection.Function
    end
    if type(connection.Fire) == "function" then
        return function(...)
            return connection.Fire(connection, ...)
        end
    end
    return nil
end

local function fireTouchSafe(otherPart, targetPart, verify)
    if not otherPart or not targetPart or not targetPart.Parent then return false end

    local function verified()
        return type(verify) == "function" and verify() == true
    end

    if verified() then return true end

    -- 1. Direct Touched handlers (works even when firetouchinterest is patched).
    if type(getconnections) == "function" then
        local ok, connections = pcall(getconnections, targetPart.Touched)
        if ok and type(connections) == "table" then
            for _, connection in ipairs(connections) do
                local handler = connectionHandler(connection)
                if handler then
                    pcall(handler, otherPart)
                end
            end
            taskWait(0.05)
            if verified() then return true end
        end
    end

    -- 2. Executor firetouchinterest, common order then reversed order.
    local env = getExecutorEnv()
    local fire = (type(firetouchinterest) == "function" and firetouchinterest)
        or (type(env) == "table" and type(env.firetouchinterest) == "function" and env.firetouchinterest)
        or (type(syn) == "table" and type(syn.firetouchinterest) == "function" and syn.firetouchinterest)
        or nil

    local interestObject = findTouchInterestObject(targetPart)
    local targets = { targetPart }
    if interestObject and interestObject ~= targetPart then
        targets[#targets + 1] = interestObject
    end

    if fire then
        for _, target in ipairs(targets) do
            pcall(fire, otherPart, target, 0)
            pcall(fire, otherPart, target, 1)
            taskWait(0.05)
            if verified() then return true end

            -- Some executors use the opposite argument order.
            pcall(fire, target, otherPart, 0)
            pcall(fire, target, otherPart, 1)
            taskWait(0.05)
            if verified() then return true end
        end
    end

    -- 3. ProximityPrompt fallback for games that replaced touch with prompts.
    if type(fireproximityprompt) == "function" then
        for _, child in ipairs(targetPart:GetDescendants()) do
            if child:IsA("ProximityPrompt") then
                pcall(fireproximityprompt, child)
                taskWait(0.05)
                if verified() then return true end
                break
            end
        end
        if targetPart:IsA("ProximityPrompt") then
            pcall(fireproximityprompt, targetPart)
            taskWait(0.05)
            if verified() then return true end
        end
    end

    return false
end

-- =====================================================================
-- EXECUTOR COMPATIBILITY & SAFETY FEATURES
-- =====================================================================
local isExecutorLoaded = false
local scriptCleanupHandlers = {}

local function registerCleanup(handler)
    if type(handler) == "function" then
        table.insert(scriptCleanupHandlers, handler)
    end
end

local function runCleanup()
    pcall(function()
        for _, handler in ipairs(scriptCleanupHandlers) do
            pcall(handler)
        end
    end)
    scriptCleanupHandlers = {}
end

-- Signal for script unload (executor compatibility)
-- BindToClose only exists on the server; calling it from a client script throws
-- and would kill the whole script before the UI is ever built.
pcall(function()
    game:BindToClose(function()
        runCleanup()
    end)
end)

-- Handle script reload in executor environments
local function setupExecutorSignals()
    local signalPath = "PetDimensions_Signal"
    local signal = ReplicatedStorage:FindFirstChild(signalPath)
    if not signal then
        signal = Instance.new("BindableEvent")
        signal.Name = signalPath
        signal.Parent = ReplicatedStorage
    end
    
    local connection
    connection = signal.Event:Connect(function(action)
        if action == "Unload" or action == "Reset" then
            runCleanup()
            if connection then
                connection:Disconnect()
            end
        end
    end)
    
    registerCleanup(function()
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end)
end

setupExecutorSignals()
isExecutorLoaded = true

local SettingsFile = "MultiRobloxAccounts_settings.json"
local CurrentThemeName = "Default Dark"
local CurrentKeyName = "LeftControl"
local CurrentToggleStates = {}
local PersistedSettings = {
    webhook = {
        url = "",
        enabled = false,
        summaryEnabled = false,
        summaryMinutes = 30,
        notify = { Huge = true, Secret = true, Titanic = true, Gargantuan = true },
        userId = ""
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
-- AFK mode is session-only and must never be restored as ON after execution.
CurrentToggleStates["AFK Mode"] = false
if type(SavedSettings.extra) == "table" then
    for k, v in pairs(SavedSettings.extra) do
        PersistedSettings.extra[k] = v
    end
end
if type(SavedSettings.webhook) == "table" then
    PersistedSettings.webhook.url = tostring(SavedSettings.webhook.url or "")
    PersistedSettings.webhook.enabled = SavedSettings.webhook.enabled == true
    if SavedSettings.webhook.summaryEnabled ~= nil then
        PersistedSettings.webhook.summaryEnabled = SavedSettings.webhook.summaryEnabled == true
    end
    if tonumber(SavedSettings.webhook.summaryMinutes) then
        PersistedSettings.webhook.summaryMinutes = math.clamp(tonumber(SavedSettings.webhook.summaryMinutes), 1, 1440)
    end
    if SavedSettings.webhook.userId ~= nil then
        PersistedSettings.webhook.userId = tostring(SavedSettings.webhook.userId or "")
    end
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
    defer(function()
        savePending = false
        pcall(function()
            writefile(SettingsFile, HttpService:JSONEncode({
                version = 3,
                theme = CurrentThemeName,
                key = CurrentKeyName,
                toggles = CurrentToggleStates,
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

-- Directory keys are not consistent: some eggs are keyed by string id, others
-- by numeric id. Resolve both forms so premium/special eggs are detected.
local function eggDefForId(eggId)
    if eggId == nil then return nil end
    local eggs = Library.Directory and Library.Directory.Eggs
    if type(eggs) ~= "table" then return nil end
    local def = eggs[eggId] or eggs[tostring(eggId)]
    if not def then
        local numericId = tonumber(eggId)
        if numericId then def = eggs[numericId] end
    end
    return def
end

-- ---------------------------------------------------------------------
-- Raw remote access
--
-- Library.Network.Invoke / Fire run caller checks (debug.info plus a
-- getfenv sweep for getgenv) and hand back nil to anything injected. The
-- wrappers below reuse the module's own hash/remote resolvers instead, so
-- a call from this script reaches the server exactly like a game script.
-- ---------------------------------------------------------------------
local RawNet = {}

do
    local env = getExecutorEnv()
    local getup = (type(env) == "table" and type(env.getupvalues) == "function" and env.getupvalues)
        or (type(getupvalues) == "function" and getupvalues)
        or nil

    if getup then
        local function findResolvers(fn)
            local ok, upvalues = pcall(getup, fn)
            if not ok or type(upvalues) ~= "table" then return nil end

            for _, candidate in ipairs(upvalues) do
                if type(candidate) == "function" then
                    local ok2, inner = pcall(getup, candidate)
                    if ok2 and type(inner) == "table"
                        and type(inner[1]) == "function"
                        and type(inner[2]) == "function" then
                        local ok3, remoteTable = pcall(getup, inner[1])
                        local ok4, hashTable = pcall(getup, inner[2])
                        if ok3 and ok4
                            and type(remoteTable) == "table" and type(hashTable) == "table"
                            and type(remoteTable[1]) == "table"
                            and type(hashTable[1]) == "table" then
                            return inner[1], inner[2]
                        end
                    end
                end
            end

            return nil
        end

        local getRemote, getHash

        for _, method in ipairs({ "Invoke", "Fire" }) do
            local ok, fn = pcall(function() return Library.Network[method] end)
            if ok and type(fn) == "function" then
                getRemote, getHash = findResolvers(fn)
                if getHash then break end
            end
        end

        if getRemote and getHash then
            local cache = {}

            local function resolve(kind, name)
                local key = kind .. "\0" .. name
                local remote = cache[key]
                if remote and remote.Parent then return remote end

                local ok, hash = pcall(getHash, kind, name)
                if not ok or hash == nil then return nil end

                local ok2, instance = pcall(getRemote, kind, hash)
                if not ok2 or not instance then return nil end

                cache[key] = instance
                return instance
            end

            -- Returns ok, serverSuccess, serverValue / error text.
            RawNet.invoke = function(name, ...)
                local remote = resolve(2, name)
                if not remote then return false, "remote unavailable" end
                return pcall(remote.InvokeServer, remote, ...)
            end

            RawNet.fire = function(name, ...)
                local remote = resolve(1, name)
                if not remote then return false, "remote unavailable" end
                return pcall(remote.FireServer, remote, ...)
            end
        else
            -- Always leave callable wrappers behind. Without this, executors
            -- whose getupvalues is missing turn every remote call into
            -- "attempt to call a nil value" instead of a clean no-op.
            RawNet.invoke = function() return false, "network unavailable" end
            RawNet.fire = function() return false, "network unavailable" end
        end
    end
end

-- Final guard: also covers executors without any getupvalues-style API.
if type(RawNet.invoke) ~= "function" then
    RawNet.invoke = function() return false, "network unavailable" end
end
if type(RawNet.fire) ~= "function" then
    RawNet.fire = function() return false, "network unavailable" end
end

-- BUGFIX (from v3): egg.drops may be a STRING chaining to another egg's
-- drop list instead of a table. Follow the chain (with a loop guard) and
-- return the resolved drop table, or nil if it cannot be resolved.
local function resolveEggDrops(eggDirectory, egg)
    if type(egg) ~= "table" then return nil end
    local drops = egg.drops
    local seen, guard = {}, 0
    while type(drops) == "string" and guard < 10 do
        guard = guard + 1
        if seen[drops] then return nil end
        seen[drops] = true
        local nextEgg = type(eggDirectory) == "table" and eggDirectory[drops] or nil
        drops = nextEgg and nextEgg.drops or nil
    end
    return type(drops) == "table" and drops or nil
end

local AutoFarmRobot = false
local AutoTap = false
local AutoTeleportClosestCoin = false
local AntiAFK = false
local AntiAFKIntervalMinutes = 1
local AutoFarmHackerBoss = false
local AutoTokens = false
local PotatoMode = false
local AutoCollectFreeGifts = false
local AutoFarmComet = false
local FastAttackSpeed = false
local FastAttackInterval = 0.02
local FastPetSpeed = false
-- Auto Diamond Packs state. Lives at the top level so the Farm tab toggle
-- and the buy engine (defined further down) read the same variables.
local AutoDiamondPacks = false
local DiamondPackStatus = "Idle"
local DiamondPackLastStock = -1
local DiamondPackStockText = ""
-- Forward declaration: the "Fast Pet Speed" toggle row is created inside the
-- UI block, which runs BEFORE the Fast Pet Speed engine is defined further
-- down the file. The toggle calls through this slot (nil-safe) so enabling
-- applies instantly and disabling actually restores the real upgrade.
local ApplyFastPetSpeedFn = nil

-- AFK tab state. Kept at the top level because the toggle rows are built
-- inside the UI task while the engines run from other threads; every reader
-- must resolve the same variable.
local AutoGroupRewards = false
local AutoSpinnyWheels = false
local AutoPotionUpgrade = false
local AutoPotionUse = false
local AutoQuests = false
local AutoQuestsSide = false
local AfkGroupStatus = "Idle"
local AfkWheelStatus = "Idle"
local AfkPotionStatus = "Idle"
local AfkPotionUseStatus = "Idle"
local AfkQuestStatus = "Idle"
local AfkSideQuestStatus = "Idle"

-- Quest driver outputs. The auto-farm coin selector reads QuestCoinFilter and
-- the auto-hatch loop reads QuestTargetEggId, so the quest engine can steer the
-- automation that already exists instead of duplicating it.
--
-- QuestAreaFarmWanted is the third output: the quest driver raises it for
-- breakable objectives, and the quest auto-farm manager below responds by
-- turning on the game's OWN Auto Farm (the same engine the Autofarm button in
-- the Tools bar toggles). The player is only ever parked at the area centre -
-- the game's engine walks the pets over every breakable itself.
local QuestCoinFilter = nil
local QuestFarmActive = false
local QuestAreaFarmWanted = false
-- The area the quest driver wants the game's Auto Farm to work. nil means
-- "any area is fine" (the driver has not picked one yet). The manager loop
-- compares it against the engine's own AutoFarmArea and forces a re-capture
-- when they disagree, because the engine only re-captures after a world
-- change - not when the player walks somewhere else.
local QuestAreaFarmTarget = nil
local QuestTargetEggId = nil
local QuestTargetEggLabel = nil
-- Set for hatch objectives that accept any egg ("hatch N eggs"). The steering
-- block then parks the player on the closest egg capsule.
local QuestHatchAnywhere = false
-- True while the quest manager - not the player - is the reason the game's
-- Auto Farm is on, so it is only ever turned back off by the same path.
local QuestOwnedAutoFarm = false

-- Playtime-quest AFK. The AFK tab lets the user pick the area to farm and the
-- egg to hatch; while a PlaytimeSeconds objective is the one the driver is
-- sitting on, the AFK engine loads that area, turns the game's Auto Farm on so
-- the pets break for the whole playtime, and auto-hatches the chosen egg. With
-- no area picked it simply waits the clock out (the old behaviour).
local AfkFarmArea = nil
local AfkFarmEgg = nil
-- Set by the quest driver while a 3-NPC PlaytimeSeconds objective is current,
-- so the playtime engine knows it is allowed to steer the player.
local QuestPlaytimeActive = false
-- Playtime startup is staged: area centre -> settle -> Auto Farm -> settle -> egg.
local QuestPlaytimeFarmReady = false
local QuestPlaytimeFarmTarget = nil

-- Hatch state lives at the top level so every loop (including the egg-open
-- cleanup poller, which is created long before the UI thread) reads the SAME
-- variable instead of silently resolving an unrelated global.
local AutoBuying = false
local HatchWatchdogStatus = "Idle"
local HatchLastEgg = 0
local HatchCooldownUntil = 0
local HatchFailures = 0
-- Egg chosen by the Auto Farm tab; preferred by currentHatchEggId() when its
-- capsule is in the current map. Stays nil when the tab is not being used.
local AutoFarmTabTargetEgg = nil
-- True while the Auto Farm tab is actively driving game auto-farm + hatch.
-- Gates the tab's watchdog thread and currentHatchEggId's egg override.
local AutoFarmTabActive = false

-- Idle-aware waiting. Every automation loop in this script used to spin at its
-- full attack rate even when its feature was switched off, which burned frame
-- time for nothing. These loops now fall back to a slow tick while idle.
local function idleWait(active, fast, slow)
    taskWait(active and fast or slow)
end

local SaveModule = nil
pcall(function()
    SaveModule = require(ReplicatedStorage:WaitForChild("Library"):WaitForChild("Client"):WaitForChild("Save"))
end)




-- BUGFIX (from v3): every remote in this game is generically named
-- (RemoteEvent/RemoteFunction) and resolved through Library.Network hash
-- upvalues, so scanning ReplicatedStorage by NAME never finds the token
-- remote and Auto Tokens silently did nothing. Tokens are now collected
-- through the exact remote the game's own collector uses:
--   Invoke "Ability Token: Collect" (tokenId, position)
-- via the RawNet resolver below.
local CurrentTarget = nil
local CurrentTargetId = nil
local LastPetSendTarget = nil
local CurrentCoinTarget = nil
local CurrentCoinTargetId = nil
local CurrentHackerBoss = nil
local CurrentHackerBossId = nil

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
--
-- When the quest driver is working a breakable objective it publishes a
-- filter in QuestCoinFilter: `kind` matches the coin's directory masteryClass
-- ("Chest", "Present", "Mob", ...), `kindPrefix` matches a masteryClass prefix
-- (used for the family of Lucky * blocks), `name` matches the coin's own
-- directory key, and `lowestHealth` picks the weakest match instead of the
-- nearest one.
-- =====================================================================
local function coinMatchesQuestFilter(root)
    local filter = QuestCoinFilter
    if not filter then return true end

    local attrName = root:GetAttribute("Name")
    local key = attrName ~= nil and tostring(attrName) or nil

    if filter.name and key ~= filter.name then
        return false
    end

    if filter.kind or filter.kindPrefix then
        local def = key and Library.Directory.Coins[key] or nil
        local mc = type(def) == "table" and tostring(def.masteryClass) or ""
        if filter.kind and mc ~= filter.kind then
            return false
        end
        if filter.kindPrefix and mc:sub(1, #filter.kindPrefix) ~= filter.kindPrefix then
            return false
        end
    end

    return true
end


-- Kept at top level so the large Auto Quests/UI closure does not exceed
-- Luau's 200-local-register limit.
local function richestAreaForFilter(filter)
    local things = Workspace:FindFirstChild("__THINGS")
    local coinsFolder = things and things:FindFirstChild("Coins")
    if not coinsFolder or not filter then return nil end
    local counts = {}
    for _, coin in ipairs(coinsFolder:GetChildren()) do
        if coinMatchesQuestFilter(coin) then
            local area = coin:GetAttribute("Area")
            if area ~= nil then
                area = tostring(area)
                counts[area] = (counts[area] or 0) + 1
            end
        end
    end
    local bestArea, bestCount = nil, 0
    for area, count in pairs(counts) do
        if count > bestCount then bestArea, bestCount = area, count end
    end
    return bestArea
end


local function FindClosestCoin(previous)
    local things = Workspace:FindFirstChild("__THINGS")
    local coinsFolder = things and things:FindFirstChild("Coins")
    if not coinsFolder then return nil end

    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end

    local filter = QuestCoinFilter
    local closest, closestDistance = nil, math.huge
    local weakest, weakestHealth = nil, math.huge
    local checked = {}

    local function consider(root)
        if not root or not root.Parent or checked[root] then return end
        checked[root] = true

        local id = root:GetAttribute("ID")
        local position = GetCoinPosition(root)
        local health = tonumber(root:GetAttribute("Health"))
        local coinPart = root:FindFirstChild("Coin", true)
        local preventClick = coinPart and coinPart:GetAttribute("PreventClick")

        if id == nil or not position or preventClick or (health ~= nil and health <= 0) then
            return
        end
        if filter and not coinMatchesQuestFilter(root) then
            return
        end

        local distance = (hrp.Position - position).Magnitude
        if distance < closestDistance then
            closestDistance = distance
            closest = root
        end

        if filter and filter.lowestHealth then
            local value = health or math.huge
            if value < weakestHealth then
                weakestHealth = value
                weakest = root
            end
        end
    end

    -- Normal coins are direct children of __THINGS.Coins.
    for _, coin in ipairs(coinsFolder:GetChildren()) do
        consider(coin:GetAttribute("ID") ~= nil and coin or GetCoinRootFromInstance(coin))
    end

    -- Fallback for coins nested under another container.
    if not closest then
        for _, instance in ipairs(coinsFolder:GetDescendants()) do
            consider(GetCoinRootFromInstance(instance))
        end
    end

    if filter and filter.lowestHealth and weakest then return weakest end
    if closest then return closest end
    if previous and previous.Parent and previous:GetAttribute("ID") ~= nil then
        if not filter or coinMatchesQuestFilter(previous) then
            return previous
        end
    end
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
            RawNet.invoke("Join Coin", coinId, myPets)
        end)

        for _, petUid in ipairs(myPets) do
            pcall(function()
                RawNet.fire("Change Pet Target", petUid, "Coin", coinId)
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
        RawNet.invoke("Join Coin", cometId, pets)
    end)

    for _, petUid in ipairs(pets) do
        pcall(function()
            RawNet.fire("Change Pet Target", petUid, "Coin", cometId)
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

taskSpawn(function()
    while true do
        if AutoTokens and localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart") then
            local tokens = collectAbilityTokens()
            local hrp = localPlayer.Character:FindFirstChild("HumanoidRootPart")

            if hrp and #tokens > 0 then
                for _, token in ipairs(tokens) do
                    if not AutoTokens then break end
                    -- Lua 5.1 has no `continue`, so guard the whole body.
                    if token and token.Parent and not ignoreTokens[token] then
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
                            taskDelay(4, function() ignoreTokens[token] = nil end)

                            local tokenPos = targetPart.Position
                            local tokenId = tonumber(token.Name) or token.Name

                            -- Collect the orb without teleporting the character.
                            -- BUGFIX (from v3): the token remote is resolved by
                            -- Library.Network hash, not by name. Invoke the exact
                            -- remote the game's own collector uses.
                            pcall(function()
                                RawNet.invoke("Ability Token: Collect", tokenId, tokenPos)
                            end)

                            local waitCount = 0
                            while token.Parent and waitCount < 6 do
                                taskWait(0.04)
                                waitCount = waitCount + 1
                            end
                        end
                    end
                end

            end
            taskWait(0.2)
        else
            taskWait(1)
        end
    end
end)

local CurrentComet = nil
local CurrentCometId = nil

taskSpawn(function()
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
                taskWait(0.05)
            else
                CurrentComet = nil
                CurrentCometId = nil
                taskWait(0.25)
            end
        else
            CurrentComet = nil
            CurrentCometId = nil
            taskWait(0.4)
        end
    end
end)

taskSpawn(function()
    while true do
        if AutoFarmComet and CurrentCometId then
            -- BUGFIX (from v3): ReplicatedStorage:GetChildren()[66] resolved
            -- to a RemoteFunction, not the Farm Coin RemoteEvent, so the
            -- direct damage call never worked. All damage goes through
            -- Fire "Farm Coin" per equipped pet.
            local pets = RefreshCachedEquippedPets(false)
            for _, petUid in ipairs(pets) do
                pcall(function()
                    RawNet.fire("Farm Coin", CurrentCometId, petUid)
                end)
            end
            taskWait(0.05)
        else
            taskWait(0.3)
        end
    end
end)

-- Fast attack loop
taskSpawn(function()
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
                -- BUGFIX (from v3): all damage goes through Fire "Farm Coin"
                -- per equipped pet; the old DamageRemote call targeted the
                -- wrong remote type and never did anything.
                local pets = RefreshCachedEquippedPets(false)
                for _, petUid in ipairs(pets) do
                    pcall(function()
                        RawNet.fire("Farm Coin", targetId, petUid)
                    end)
                end
                taskWait(FastAttackInterval)
            else
                taskWait(0.2)
            end
        else
            taskWait(0.25)
        end
    end
end)

    -- REMOVED: the Expedition auto-farm loop and its damage loop.
-- Hacker Boss Auto Farm Loop
-- Uses the same coin selection / Join Coin / Change Pet Target sequence
-- as the other auto farms, targeting the live Hacker Prime boss coin.
taskSpawn(function()
    while true do
        taskWait(0.15)

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
taskSpawn(function()
    while true do
        taskWait(0.15)
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
taskSpawn(function()
    while true do
        if CurrentTargetId and AutoFarmRobot then
            -- BUGFIX (from v3): Fire "Farm Coin" per equipped pet instead of
            -- the broken DamageRemote index hack.
            local pets = RefreshCachedEquippedPets(false)
            for _, petUid in ipairs(pets) do
                pcall(function()
                    RawNet.fire("Farm Coin", CurrentTargetId, petUid)
                end)
            end
            taskWait(0.05)
        else
            taskWait(0.3)
        end
    end
end)

-- Hacker Boss damage loop
taskSpawn(function()
    while true do
        if AutoFarmHackerBoss and CurrentHackerBossId then
            -- BUGFIX (from v3): Fire "Farm Coin" per equipped pet instead of
            -- the broken DamageRemote index hack.
            local pets = RefreshCachedEquippedPets(false)
            for _, petUid in ipairs(pets) do
                pcall(function()
                    RawNet.fire("Farm Coin", CurrentHackerBossId, petUid)
                end)
            end
            taskWait(0.05)
        else
            taskWait(0.3)
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
taskSpawn(function()
    while true do
        if AutoTap or AutoTeleportClosestCoin or QuestFarmActive then
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

                        if AutoTap or QuestFarmActive then
                            local pets = RefreshCachedEquippedPets(true)
                            if #pets > 0 then
                                pcall(function()
                                    RawNet.invoke("Join Coin", targetId, pets)
                                end)

                                for _, petUid in ipairs(pets) do
                                    pcall(function()
                                        RawNet.fire("Change Pet Target", petUid, "Coin", targetId)
                                    end)
                                end
                            end
                        end
                    end

                    -- Teleport only when the target changes instead of
                    -- repeatedly setting CFrame every frame.
                    if (AutoTeleportClosestCoin or QuestFarmActive) and (changed or LastCoinTeleportTarget ~= target) then
                        TeleportToClosestCoin(target)
                        LastCoinTeleportTarget = target
                    elseif not (AutoTeleportClosestCoin or QuestFarmActive) then
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

        taskWait((AutoTap or AutoTeleportClosestCoin or QuestFarmActive) and ClosestCoinScanInterval or 0.4)
    end
end)

-- Dedicated hit loop. It uses the same direct damage/Farm Coin calls as the
-- pet list on every hit.
taskSpawn(function()
    while true do
        if (AutoTap or QuestFarmActive) and CurrentCoinTargetId then
            local targetId = CurrentCoinTargetId
            local pets = RefreshCachedEquippedPets(false)

            -- BUGFIX (from v3): Fire "Farm Coin" per equipped pet instead of
            -- the broken DamageRemote index hack.
            for _, petUid in ipairs(pets) do
                pcall(function()
                    RawNet.fire("Farm Coin", targetId, petUid)
                end)
            end
            taskWait(ClosestCoinHitInterval)
        else
            taskWait(0.25)
        end
    end
end)

-- ANTI-AFK
-- Sends a real Space key press at the user-selected interval (minutes).
taskSpawn(function()
    while true do
        if AntiAFK then
            local interval = math.max(0.1, tonumber(AntiAFKIntervalMinutes) or 1) * 60
            local elapsed = 0
            while AntiAFK and elapsed < interval do
                local step = math.min(1, interval - elapsed)
                taskWait(step)
                elapsed = elapsed + step
            end

            if AntiAFK then
                pcall(function()
                    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                    taskWait(0.1)
                    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
                end)
            end
        else
            taskWait(0.25)
        end
    end
end)

-- AUTO FREE GIFTS
-- Mirrors the game's own readiness rule (FreeGiftsTime >= waitTime and the
-- index is not in FreeGiftsRedeemed) and claims through the same remote the
-- Free Gifts UI uses. A local cooldown keeps the hub from re-sending a claim
-- while the save is still catching up.
local freeGiftClaimAt = {}
local freeGiftRemote = nil

-- The game's Network library runs a caller-script check that silently drops
-- requests made from an executor (it returned nil and never reached the
-- server). Grab the real RemoteFunction out of the Invoke closure's upvalues
-- and call it directly instead.
local function getFreeGiftRemote()
    if freeGiftRemote and freeGiftRemote.Parent then
        return freeGiftRemote
    end
    freeGiftRemote = nil

    local invoke = Library.Network and Library.Network.Invoke
    if type(invoke) ~= "function" then
        return nil
    end

    local env = getExecutorEnv()
    local getter = (type(env) == "table" and type(env.getupvalues) == "function" and env.getupvalues)
        or (type(getupvalues) == "function" and getupvalues)
        or nil
    if not getter and type(debug) == "table" and type(debug.getupvalue) == "function" then
        getter = function(fn)
            local ups, index = {}, 1
            while true do
                local _, value = debug.getupvalue(fn, index)
                if value == nil and debug.getupvalue(fn, index) == nil then break end
                ups[index] = value
                index = index + 1
            end
            return ups
        end
    end

    if type(getter) == "function" then
        local ok, ups = pcall(getter, invoke)
        if ok and type(ups) == "table" then
            for _, up in ipairs(ups) do
                if type(up) == "function" then
                    local ok2, remote = pcall(up, "Redeem Free Gift")
                    if ok2 and typeof(remote) == "Instance" and remote:IsA("RemoteFunction") then
                        freeGiftRemote = remote
                        return remote
                    end
                end
            end
        end
    end

    return nil
end

-- Identifies the newest run so a reloaded hub stops the previous claim loop.
local giftLoopToken = {}
do
    local env = getExecutorEnv()
    if type(env) == "table" then env.__pdhGiftLoopToken = giftLoopToken end
end

taskSpawn(function()
    local function isCurrentRun()
        local env = getExecutorEnv()
        return type(env) ~= "table" or env.__pdhGiftLoopToken == giftLoopToken
    end

    while isCurrentRun() do
        if AutoCollectFreeGifts then
            pcall(function()
                local save = Library.Save.Get()
                local directory = Library.Directory and Library.Directory.FreeGifts
                if not save or not directory or not save.FreeGiftsTime then
                    return
                end

                local redeemed = {}
                if type(save.FreeGiftsRedeemed) == "table" then
                    for _, id in ipairs(save.FreeGiftsRedeemed) do
                        redeemed[id] = true
                    end
                end

                local now = os.clock()
                for index, gift in ipairs(directory) do
                    local waitTime = tonumber(gift.waitTime) or math.huge
                    local lastTry = freeGiftClaimAt[index] or -math.huge
                    if save.FreeGiftsTime >= waitTime
                        and not redeemed[index]
                        and (now - lastTry) >= 5 then
                        freeGiftClaimAt[index] = now
                        local remote = getFreeGiftRemote()
                        if remote then
                            remote:InvokeServer(index)
                        end
                        taskWait(0.2)
                    end
                end
            end)
            taskWait(2)
        else
            taskWait(1)
        end
    end
end)

-- =====================================================================
-- AUTO DIAMOND PACKS
--
-- Buys out every Diamond Pack tier in the Exclusive Shop, paying with each
-- tier's own currency (Rainbow Coins). It reads stock from the same remote
-- the shop UI uses:
--   Invoke "Diamonds Packs: Stock"             -> { [tier] = stock }
--   Invoke "Diamonds Packs", tier, count       -> true on any purchase
-- The server clamps the requested count to both the remaining stock and
-- what the player can afford, so asking for the whole stock in one call is
-- safe and returns true even for a partial fill.
--
-- Behaviour: buys cheapest tier first (so a partial budget still buys the
-- most packs), reports whether it had enough coins to clear everything,
-- records the moment every tier hits 0, and re-buys the instant the daily
-- restock brings stock back above zero.
-- =====================================================================
local function DiamondPackShort(value)
    local shorten = Library.Functions and Library.Functions.NumberShorten
    if type(shorten) == "function" then
        local ok, text = pcall(shorten, value)
        if ok and text ~= nil then return tostring(text) end
    end
    return tostring(math.floor(value))
end

taskSpawn(function()
    while true do
        if AutoDiamondPacks then
            local packs = Library.Shared and Library.Shared.DiamondPacks

            if not RawNet.invoke then
                DiamondPackStatus = "Network unavailable"
            elseif type(packs) ~= "table" then
                DiamondPackStatus = "Waiting for shop data..."
            else
                local okStock, stock = RawNet.invoke("Diamonds Packs: Stock")

                if not okStock or type(stock) ~= "table" then
                    DiamondPackStatus = "Stock unavailable"
                else
                    -- Snapshot the shop: stock, price and currency per tier.
                    local entries, remaining, totalCost = {}, 0, 0
                    local currency = nil

                    for tier, info in pairs(packs) do
                        if type(info) == "table" then
                            local count = math.max(0, math.floor(tonumber(stock[tier]) or 0))
                            local cost = math.max(0, tonumber(info.cost) or 0)
                            currency = currency or info.currency
                            entries[#entries + 1] = { tier = tier, count = count, cost = cost }
                            remaining = remaining + count
                            totalCost = totalCost + count * cost
                        end
                    end

                    -- Cheapest first so a partial budget clears the most packs.
                    table.sort(entries, function(a, b) return a.cost < b.cost end)

                    currency = currency or "Rainbow Coins"

                    local function readCoins()
                        local save = Library.Save and Library.Save.Get and Library.Save.Get()
                        return math.max(0, tonumber(save and save[currency]) or 0)
                    end

                    -- Total packs the game has already recorded as bought today.
                    local function readUsedToday()
                        local save = Library.Save and Library.Save.Get and Library.Save.Get()
                        local record = save and save.DiamondPackDailyStock
                        local used = type(record) == "table" and record.UsedByPack
                        if type(used) ~= "table" then return 0 end
                        local total = 0
                        for _, n in pairs(used) do total = total + math.max(0, tonumber(n) or 0) end
                        return total
                    end

                    -- "Tiny 75  Medium 70  Large 75  ..." for the stock line.
                    local function summarize(key)
                        local parts = {}
                        for _, entry in ipairs(entries) do
                            parts[#parts + 1] = ("%s %d"):format((entry.tier:gsub(" Diamonds$", "")), entry[key] or 0)
                        end
                        return table.concat(parts, "  ")
                    end

                    DiamondPackStockText = summarize("count")

                    -- Restock detection: stock was empty last pass and is not now.
                    if DiamondPackLastStock == 0 and remaining > 0 then
                        print(("[Auto Diamond Packs] Restocked: %d packs back on the shelf"):format(remaining))
                    end
                    DiamondPackLastStock = remaining

                    if remaining <= 0 then
                        local boughtToday = readUsedToday()
                        DiamondPackStatus = boughtToday > 0
                            and ("All packs bought today (%d) - resets daily"):format(boughtToday)
                            or "No stock on the shelf - retrying"
                    else
                        local coinsAtStart = readCoins()
                        local hadEnoughForAll = coinsAtStart >= totalCost

                        for _, entry in ipairs(entries) do
                            if not AutoDiamondPacks then break end
                            if entry.count > 0 and readCoins() >= entry.cost then
                                -- The server clamps the fill to what is affordable
                                -- and to the remaining stock, and reports only
                                -- success, so the real amount bought is read back
                                -- from the stock table below.
                                RawNet.invoke("Diamonds Packs", entry.tier, entry.count)
                                taskWait(0.2)
                            end
                        end

                        -- Re-read stock so the status reflects what actually landed.
                        local okAfter, stockAfter = RawNet.invoke("Diamonds Packs: Stock")
                        local left, missingCost, bought = 0, 0, 0

                        for _, entry in ipairs(entries) do
                            local after = entry.count
                            if okAfter and type(stockAfter) == "table" then
                                after = math.max(0, math.floor(tonumber(stockAfter[entry.tier]) or 0))
                            end
                            entry.after = after
                            left = left + after
                            missingCost = missingCost + after * entry.cost
                            bought = bought + math.max(0, entry.count - after)
                        end

                        DiamondPackLastStock = left
                        DiamondPackStockText = summarize("after")

                        if left <= 0 then
                            DiamondPackStatus = hadEnoughForAll
                                and ("Bought out all packs - had enough " .. currency)
                                or "Bought out all packs"
                            print(("[Auto Diamond Packs] %s (%d packs)"):format(DiamondPackStatus, bought))
                        elseif bought > 0 then
                            local coins = readCoins()
                            DiamondPackStatus = ("Bought %d - %d left, short %s %s")
                                :format(bought, left, DiamondPackShort(math.max(0, missingCost - coins)), currency)
                        else
                            local coins = readCoins()
                            DiamondPackStatus = ("%d left - short %s %s")
                                :format(left, DiamondPackShort(math.max(0, missingCost - coins)), currency)
                        end
                    end
                end
            end
        else
            DiamondPackLastStock = -1
        end

        -- Poll quickly while there is still stock to chase, slowly while sold
        -- out (restocks are daily) or while the feature is off.
        if AutoDiamondPacks then
            taskWait(DiamondPackLastStock > 0 and 2.5 or 5)
        else
            taskWait(1)
        end
    end
end)

-- Potato Mode Continuous Focus Loop
taskSpawn(function()
    while true do
        taskWait(0.1)
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
local eggOpenCleanupActive = true
local function destroyEggAnimationObject(obj)
    if not obj or not eggOpenCleanupActive then return end
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
local EggOpenEnv = getExecutorEnv()
local eggOpenHookCleanup = {}

-- Keep the script executor-neutral. Optional executor APIs are feature-detected
-- at the point of use; no specific executor name is required.
local executorType = "Generic"

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
    defer(function()
        pcall(function() RawNet.fire("Pets_ClearHidden", uids) end)
        pcall(function() Library.Signal.Fire("CompletedHatching", eggId, uids) end)
    end)
end

-- Undo a previous run of this script so reloads never stack listeners.
pcall(function()
    local previous = EggOpenEnv.PD_EggOpenHook
    if previous then
        if previous.replacement then previous.replacement:Disconnect() end
        if previous.signal and previous.callback then
            pcall(function()
                previous.signal:Connect(previous.callback)
            end)
        elseif previous.trigger and previous.callback then
            -- Older hook records stored the Instance instead of its signal.
            pcall(function()
                local oldSignal = previous.trigger:IsA("BindableEvent") and previous.trigger.Event or previous.trigger.OnClientEvent
                if oldSignal then oldSignal:Connect(previous.callback) end
            end)
        end
        if previous.cleanup then
            pcall(previous.cleanup)
        end
    end
end)
EggOpenEnv.PD_EggOpenHook = nil

local eggOpenDetached = false
local eggOpenConnection
taskSpawn(function()
    local port = ReplicatedStorage:WaitForChild("EggOpenPort", 15)
    local trigger = port and port:WaitForChild("PlayTrigger", 15)
    if not trigger then return end

    pcall(function()
        local signal = trigger:IsA("BindableEvent") and trigger.Event or trigger.OnClientEvent
        local callback
        if type(getconnections) ~= "function" then return end
        for _, connection in ipairs(getconnections(signal)) do
            if connection.Enabled and type(connection.Function) == "function" then
                callback = callback or connection.Function
                connection:Disconnect()
            end
        end
        if callback then
            EggOpenEnv.PD_EggOpenHook = {
                trigger = trigger,
                signal = signal,
                callback = callback,
                replacement = signal:Connect(eggOpenBookkeeping),
                cleanup = function()
                    if eggOpenConnection and eggOpenConnection.Connected then
                        eggOpenConnection:Disconnect()
                    end
                end,
            }
            eggOpenDetached = true
            eggOpenConnection = EggOpenEnv.PD_EggOpenHook.replacement
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
                
                -- Register cleanup for namecall hook
                EggOpenEnv.PD_EggOpenNamecallHookCleanup = function()
                    if oldNamecall then
                        hookmetamethod(game, "__namecall", oldNamecall)
                    end
                end
                registerCleanup(function()
                    if EggOpenEnv.PD_EggOpenNamecallHookCleanup then
                        pcall(EggOpenEnv.PD_EggOpenNamecallHookCleanup)
                    end
                end)
            end
        end)
    end
end)

-- Small fallback cleanup only while Auto-Hatch is active, and only every 2s.
-- With the listener detached nothing should ever be created, so this is a
-- safety net for leftovers from an animation that was already in flight when
-- the script loaded - not a per-frame tree scan.
local eggCleanupTask
eggCleanupTask = taskSpawn(function()
    while true do
        if AutoBuying and eggOpenCleanupActive then
            cleanupEggOpeningEffects()
        end
        taskWait(2)
    end
end)

registerCleanup(function()
    eggOpenCleanupActive = false
    if eggCleanupTask then
        taskCancel(eggCleanupTask)
    end
end)

-- =====================================================================
-- QUEST AUTO-FARM MANAGER (the game's own Auto Farm engine)
--
-- Breakable quest objectives used to teleport the player onto every single
-- breakable through the hub's closest-coin farm. That is slow and looks
-- nothing like how the game is meant to be played. The game already ships a
-- full Auto Farm engine - the same one the "Autofarm" button in the Tools bar
-- toggles - which captures the area the player is standing in and walks the
-- equipped pets over every eligible breakable in it.
--
-- The engine is a plain client-side state machine around three things:
--   Library.Variables.AutoFarmEnabled - the on/off switch
--   Library.Variables.AutoFarmArea    - the captured area (set by CaptureArea)
--   the Autofarm GUI button           - colour/animation only, never required
--
-- So the quest driver's whole breakable path is: park the player at the centre
-- of the objective's area, then raise AutoFarmEnabled. CaptureArea() picks the
-- area up on its next tick, and the pets do the rest. The engine turns itself
-- off on world changes and storyline locks, so the manager re-asserts it every
-- cycle while a breakable objective is active.
--
-- The hub's own closest-coin farm stays available for the manual Auto Tap /
-- Auto Teleport toggles, but the quest driver never drives it anymore.
-- =====================================================================

-- Resolve the area an egg capsule stands in. Capsules live under
-- Workspace.__MAP.Eggs.<area>.Eggs, so the parent chain already knows the
-- answer - no position maths needed. Special eggs (Lucky, Storm, Chroma) are
-- models named after themselves rather than "Egg Capsule", so the search
-- matches on the ID attribute instead of the model name.
local function questFindEggCapsule(eggId)
    if not eggId then return nil end
    local map = Workspace:FindFirstChild("__MAP")
    local eggsFolder = map and map:FindFirstChild("Eggs")
    if not eggsFolder then return nil end

    local best, bestDistance = nil, math.huge
    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart") or nil
    for _, model in ipairs(eggsFolder:GetDescendants()) do
        if model:IsA("Model") then
            local id = model:GetAttribute("ID")
            if id ~= nil and tostring(id) == eggId then
                local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
                if part then
                    if hrp then
                        local distance = (hrp.Position - part.Position).Magnitude
                        if distance < bestDistance then
                            bestDistance = distance
                            best = model
                        end
                    else
                        return model
                    end
                end
            end
        end
    end
    return best
end

-- Turn the game's own Auto Farm on or off through the engine's OWN button
-- handler wherever we can reach it.
--
-- WHY THIS IS NOT JUST `Library.Variables.AutoFarmEnabled = true` ANYMORE:
-- the engine only calls CaptureArea() inside its SetEnabled handler (the one
-- wired to the Tools "Autofarm" button). Writing the raw variable makes the
-- Tick loop believe farm is on while AutoFarmArea stays nil, so the pets have
-- no captured area and just stand still until a world change happens to run
-- CaptureArea for them. Driving the real handler captures the area the player
-- is standing in, which is exactly what the button does.
--
-- The handler is a connection on the live button, so it is resolved once
-- through getconnections and cached. Executors without getconnections fall back
-- to the old variable write (still correct for the quest manager, which only
-- ever flips the flag while parked inside the target area).
local questAutoFarmHandlerCache = nil
local questAutoFarmHandlerResolved = false

local function questGameAutoFarmHandler()
    if questAutoFarmHandlerResolved then
        return questAutoFarmHandlerCache
    end

    if type(getconnections) ~= "function" then
        return nil
    end

    local okButton, button = pcall(function()
        return Library.GUI
            and Library.GUI.Main
            and Library.GUI.Main.Left
            and Library.GUI.Main.Left.Tools
            and Library.GUI.Main.Left.Tools:FindFirstChild("Autofarm")
    end)
    if not okButton or not button then return nil end

    local okConns, connections = pcall(getconnections, button.Activated)
    if not okConns or type(connections) ~= "table" then return nil end

    for _, connection in ipairs(connections) do
        if type(connection.Function) == "function" then
            questAutoFarmHandlerCache = connection.Function
            questAutoFarmHandlerResolved = true
            return connection.Function
        end
    end
    -- Do not cache failures: the button connection may be installed later.
    return nil
end

local function questSetGameAutoFarm(enabled)
    local handler = questGameAutoFarmHandler()
    if handler then
        -- The handler toggles from whatever the current state is, so calling it
        -- twice in a row would flip straight back. Only invoke it on a real
        -- state change.
        local okCur, current = pcall(function() return Library.Variables.AutoFarmEnabled end)
        if okCur and current ~= enabled then
            pcall(handler)
        end

        -- The game's own handler is zone-gated: it refuses to start Auto Farm
        -- outside a breakable zone. When it refused, force the variables the
        -- Tick loop reads so the caller's contract is still met (the engine
        -- then farms whatever it can capture from where the player stands).
        -- Without this the manager loop would call the handler every tick
        -- forever, since the state never became what it asked for.
        local okAfter, after = pcall(function() return Library.Variables.AutoFarmEnabled end)
        if okAfter and after == enabled then
            return true
        end
    end

    -- Fallback: no getconnections, or the handler refused. Write the variables
    -- the Tick loop reads and mirror the change onto the button.
    return pcall(function()
        Library.Variables.AutoFarmEnabled = enabled
        if not enabled then
            Library.Variables.AutoFarmArea = nil
        end

        local gui = Library.GUI
            and Library.GUI.Main
            and Library.GUI.Main.Left
            and Library.GUI.Main.Left.Tools
        local button = gui and gui:FindFirstChild("Autofarm")
        if button then
            button.BackgroundColor3 = enabled
                and Color3.fromRGB(103, 255, 103)
                or Color3.fromRGB(255, 255, 255)
            local status = button:FindFirstChild("StatusDisabled")
            if status then
                local red = status:FindFirstChild("RedGradient")
                local green = status:FindFirstChild("GreenGradient")
                if red then red.Enabled = not enabled end
                if green then green.Enabled = enabled end
            end
        end
    end)
end

-- Manager loop. While a breakable objective is active it keeps the game's
-- Auto Farm enabled and re-asserts it after every world change (the engine
-- drops the capture on "World Changed" but leaves the flag on - only the
-- captured area is lost, and CaptureArea() rebuilds it from wherever the
-- player is standing).
taskSpawn(function()
    local recaptureArmed = false
    -- Bounded re-capture. The engine snaps its capture to wherever the player
    -- stood when it enabled, so a mismatch usually means the driver has not
    -- parked yet and one off/on fixes it. But an area the engine can never
    -- capture (an egg whose `area` is not a real area, a world with no
    -- breakable zone) would otherwise make the mismatch permanent and the loop
    -- would toggle Auto Farm off/on forever. After a few tries it gives up and
    -- leaves the farm running on whatever it captured.
    local recaptureTries = 0
    local lastTarget = nil
    while true do
        if QuestAreaFarmWanted and (AutoQuests or AutoQuestsSide)
            and (not QuestPlaytimeActive or QuestPlaytimeFarmReady) then
            local ok, enabled = pcall(function()
                return Library.Variables.AutoFarmEnabled
            end)
            local okArea, capturedArea = pcall(function()
                return Library.Variables.AutoFarmArea
            end)

            if lastTarget ~= QuestAreaFarmTarget then
                lastTarget = QuestAreaFarmTarget
                recaptureTries = 0
            end

            if not ok or enabled ~= true then
                questSetGameAutoFarm(true)
                recaptureArmed = false
            elseif QuestAreaFarmTarget
                and okArea
                and tostring(capturedArea or "") ~= QuestAreaFarmTarget then
                -- The engine captured the wrong area (it snaps to wherever the
                -- player was standing when it first enabled). Turn it off for
                -- a tick so its Tick loop clears the capture, then back on -
                -- it re-captures from wherever the player is standing now,
                -- which the quest driver keeps parked at the target centre.
                if recaptureTries < 4 then
                    if not recaptureArmed then
                        recaptureArmed = true
                        questSetGameAutoFarm(false)
                    else
                        recaptureArmed = false
                        recaptureTries = recaptureTries + 1
                        questSetGameAutoFarm(true)
                    end
                else
                    recaptureArmed = false
                end
            else
                recaptureArmed = false
                recaptureTries = 0
            end
            taskWait(0.6)
        elseif QuestAreaFarmWanted and QuestPlaytimeActive and not QuestPlaytimeFarmReady then
            -- The playtime driver is deliberately handling the ordered startup
            -- (centre, wait, Auto Farm, wait, egg). Do not race it by enabling
            -- Auto Farm here, or by releasing a farm it has just acquired.
            taskWait(0.25)
        else
            if QuestOwnedAutoFarm then
                QuestOwnedAutoFarm = false
                questSetGameAutoFarm(false)
            end
            lastTarget = nil
            recaptureTries = 0
            taskWait(0.5)
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

-- Clean up previous UI instances across executor reloads
pcall(function()
    if playerGui:FindFirstChild("CombinedAutomationUI") then
        playerGui.CombinedAutomationUI:Destroy()
    end
    if playerGui:FindFirstChild("CombinedAutomationAfkUI") then
        playerGui.CombinedAutomationAfkUI:Destroy()
    end
end)

destroyOldGui("CombinedAutomationUI")

taskSpawn(function()
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
    -- The hub is designed around a 1000x760 canvas. Instead of using a
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
        local DESIGN_WIDTH = 1000
        local DESIGN_HEIGHT = 760
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

    do
        local trackerCorner = Instance.new("UICorner")
        trackerCorner.CornerRadius = UDim.new(0, 10)
        trackerCorner.Parent = tracker
    end

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

    do
        local trackerToggleCorner = Instance.new("UICorner")
        trackerToggleCorner.CornerRadius = UDim.new(0, 6)
        trackerToggleCorner.Parent = trackerToggle
    end

    local trackerContainer = Instance.new("Frame")
    trackerContainer.Size = UDim2.new(1, 0, 1, 0)
    trackerContainer.BackgroundTransparency = 1
    trackerContainer.Parent = tracker

    do
        local trackerLayout = Instance.new("UIListLayout")
        trackerLayout.FillDirection = Enum.FillDirection.Horizontal
        trackerLayout.Padding = UDim.new(0, 0)
        trackerLayout.SortOrder = Enum.SortOrder.LayoutOrder
        trackerLayout.Parent = trackerContainer
    end

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

        do
            local topLine = Instance.new("Frame")
            topLine.Size = UDim2.new(1, -12, 0, 1)
            topLine.Position = UDim2.new(0, 6, 0, 50)
            topLine.BackgroundColor3 = color
            topLine.BackgroundTransparency = 0.7
            topLine.BorderSizePixel = 0
            topLine.Parent = col
        end

        do
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
        end

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

    do
        local div1 = Instance.new("Frame")
        div1.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
        div1.BackgroundTransparency = 0.8
        div1.BorderSizePixel = 0
        div1.Size = UDim2.new(0, 1, 1, -16)
        div1.Position = UDim2.new(0, 0, 0, 8)
        div1.LayoutOrder = 2
        div1.Parent = trackerContainer
    end

    do
        local div2 = Instance.new("Frame")
        div2.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
        div2.BackgroundTransparency = 0.8
        div2.BorderSizePixel = 0
        div2.Size = UDim2.new(0, 1, 1, -16)
        div2.Position = UDim2.new(0, 0, 0, 8)
        div2.LayoutOrder = 4
        div2.Parent = trackerContainer
    end

    do
        local div3 = Instance.new("Frame")
        div3.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
        div3.BackgroundTransparency = 0.8
        div3.BorderSizePixel = 0
        div3.Size = UDim2.new(0, 1, 1, -16)
        div3.Position = UDim2.new(0, 0, 0, 8)
        div3.LayoutOrder = 6
        div3.Parent = trackerContainer
    end

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
    -- Variant breakdown for rare pets hatched during the current AFK session.
    -- Rainbow/Golden/Shiny are tracked separately per tier so the AFK panel
    -- never hides the fact that a rare hatch was also a variant.
    local afkSessionVariants = {
        Huges = { R = 0, G = 0, S = 0 },
        Secrets = { R = 0, G = 0, S = 0 },
        Titanics = { R = 0, G = 0, S = 0 },
        Gargantuans = { R = 0, G = 0, S = 0 },
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
    local afkSessionVariantLabels = {}
    local startupLabels = {}
    local hatchRecentLists = {}
    local hatchVariantLabels = {}
    local updateHatchVariantOwned = function() end
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
            label:SetAttribute("ThemeKeepTextColor", true)
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
                        totalHuge = totalHuge + 1
                    elseif category == "Secret" then
                        totalSecret = totalSecret + 1
                    elseif category == "Titanic" then
                        totalTitanic = totalTitanic + 1
                    elseif category == "Gargantuan" then
                        totalGargantuan = totalGargantuan + 1
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
                                local sessionVariants = afkSessionVariants[category .. "s"]
                                if sessionVariants then
                                    if entry.rainbow then sessionVariants.R = sessionVariants.R + 1 end
                                    if entry.golden then sessionVariants.G = sessionVariants.G + 1 end
                                    if entry.shiny then sessionVariants.S = sessionVariants.S + 1 end
                                end
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
            hatchRareLabels.Huges:SetAttribute("ThemeKeepTextColor", true)
        end
        if hatchRareLabels.Secrets then
            hatchRareLabels.Secrets.Text = secretLabel.Text
            hatchRareLabels.Secrets.TextColor3 = Color3.fromRGB(95, 45, 150)
            hatchRareLabels.Secrets:SetAttribute("ThemeKeepTextColor", true)
        end
        if hatchRareLabels.Titanics then
            hatchRareLabels.Titanics.Text = titanicLabel.Text
            hatchRareLabels.Titanics.TextColor3 = Color3.fromRGB(255, 200, 60)
            hatchRareLabels.Titanics:SetAttribute("ThemeKeepTextColor", true)
        end
        if hatchRareLabels.Gargantuans then
            hatchRareLabels.Gargantuans.Text = gargantuanLabel.Text
            hatchRareLabels.Gargantuans.TextColor3 = Color3.fromRGB(150, 35, 35)
            hatchRareLabels.Gargantuans:SetAttribute("ThemeKeepTextColor", true)
        end
        -- The AFK cards show the raw number, not the hatch panel's
        -- "Huges: 12" string, and Gargantuans were never refreshed at all.
        if afkRareLabels.Huges then afkRareLabels.Huges.Text = tostring(totalHuge) end
        if afkRareLabels.Secrets then afkRareLabels.Secrets.Text = tostring(totalSecret) end
        if afkRareLabels.Titanics then afkRareLabels.Titanics.Text = tostring(totalTitanic) end
        if afkRareLabels.Gargantuans then afkRareLabels.Gargantuans.Text = tostring(totalGargantuan) end

        -- Keep Hatch stats variant chips updated cleanly without overlapping rows.
        pcall(updateHatchVariantOwned)
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
    taskSpawn(function()
        while ui.Parent do
            refreshTracker()
            taskWait(2.5)
        end
    end)

    -- Shared visual language for the AFK screen and the recent-hatch cards.
    local Style = {
        surface    = Color3.fromRGB(23, 26, 37),
        surfaceAlt = Color3.fromRGB(17, 19, 28),
        line       = Color3.fromRGB(68, 82, 112),
        muted      = Color3.fromRGB(166, 179, 202),
        text       = Color3.fromRGB(236, 240, 250),
        green      = Color3.fromRGB(52, 211, 153),
        violet     = Color3.fromRGB(167, 139, 250),
        cyan       = Color3.fromRGB(34, 211, 238),
    }

    -- =====================================================================
    -- AFK OVERLAY (Full-Screen Dedicated ScreenGui)
    -- Built inside one function so its ~50 locals stay out of the main UI
    -- thread, which already sits close to Luau's 200-register ceiling.
    -- Uses its own IgnoreGuiInset ScreenGui without UIScale interference
    -- to guarantee complete 100% full-screen coverage.
    -- =====================================================================
    local afkGui = Instance.new("ScreenGui")
    afkGui.Name = "CombinedAutomationAfkUI"
    afkGui.ResetOnSpawn = false
    afkGui.IgnoreGuiInset = true
    afkGui.DisplayOrder = 10000
    afkGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    afkGui.Enabled = false
    afkGui.Parent = playerGui

    local afkOverlay, afkCenter, afkEggs, afkGems, afkExit, afkStartSession = (function()
        local overlay = Instance.new("Frame")
        overlay.Name = "AfkOverlay"
        overlay.Size = UDim2.new(1, 0, 1, 0)
        overlay.Position = UDim2.new(0, 0, 0, 0)
        overlay.BackgroundColor3 = Color3.fromRGB(5, 6, 10)
        overlay.BorderSizePixel = 0
        overlay.Visible = false
        overlay.ZIndex = 100
        overlay.Parent = afkGui

        local backdrop = Instance.new("Frame")
        backdrop.Name = "Backdrop"
        backdrop.Size = UDim2.new(1, 0, 1, 0)
        backdrop.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        backdrop.BorderSizePixel = 0
        backdrop.ZIndex = 101
        backdrop.Parent = overlay

        local backdropGradient = Instance.new("UIGradient")
        backdropGradient.Rotation = 90
        backdropGradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 32, 52)),
            ColorSequenceKeypoint.new(0.55, Color3.fromRGB(11, 13, 21)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(5, 6, 10)),
        })
        backdropGradient.Parent = backdrop

        local glow = Instance.new("Frame")
        glow.Name = "Glow"
        glow.Size = UDim2.new(1, 0, 0.45, 0)
        glow.BackgroundColor3 = Style.violet
        glow.BackgroundTransparency = 0.92
        glow.BorderSizePixel = 0
        glow.ZIndex = 101
        glow.Parent = overlay

        local glowGradient = Instance.new("UIGradient")
        glowGradient.Rotation = 90
        glowGradient.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(1, 1),
        })
        glowGradient.Parent = glow

        local center = Instance.new("Frame")
        center.Name = "Center"
        center.Size = UDim2.new(0.96, 0, 0.94, 0)
        center.AnchorPoint = Vector2.new(0.5, 0.5)
        center.Position = UDim2.new(0.5, 0, 0.5, 0)
        center.BackgroundTransparency = 1
        center.ClipsDescendants = true
        center.ZIndex = 102
        center.Parent = overlay

        -- HEADER -----------------------------------------------------------
        local header = Instance.new("Frame")
        header.Name = "Header"
        header.Size = UDim2.new(1, 0, 0.16, 0)
        header.BackgroundTransparency = 1
        header.ZIndex = 102
        header.Parent = center

        local title = Instance.new("TextLabel")
        title.Name = "Title"
        title.Size = UDim2.new(1, 0, 0.58, 0)
        title.BackgroundTransparency = 1
        title.Text = "AFK MODE"
        title.TextColor3 = Color3.fromRGB(224, 229, 239)
        title.Font = Enum.Font.GothamBlack
        title.TextScaled = true
        title.ZIndex = 103
        title.Parent = header

        local titleGradient = Instance.new("UIGradient")
        titleGradient.Rotation = 0
        titleGradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(205, 213, 229)),
            ColorSequenceKeypoint.new(0.55, Style.violet),
            ColorSequenceKeypoint.new(1, Style.cyan),
        })
        titleGradient.Parent = title

        local pill = Instance.new("Frame")
        pill.Name = "StatusPill"
        pill.Size = UDim2.new(0.58, 0, 0, 26)
        local pillSizeLimit = Instance.new("UISizeConstraint")
        pillSizeLimit.MinSize = Vector2.new(180, 26)
        pillSizeLimit.MaxSize = Vector2.new(236, 26)
        pillSizeLimit.Parent = pill
        pill.AnchorPoint = Vector2.new(0.5, 0)
        pill.Position = UDim2.new(0.5, 0, 0.66, 0)
        pill.BackgroundColor3 = Color3.fromRGB(14, 24, 22)
        pill.BorderSizePixel = 0
        pill.ZIndex = 103
        pill.Parent = header

        do
            local pillCorner = Instance.new("UICorner")
            pillCorner.CornerRadius = UDim.new(1, 0)
            pillCorner.Parent = pill
        end

        do
            local pillStroke = Instance.new("UIStroke")
            pillStroke.Color = Style.green
            pillStroke.Thickness = 1
            pillStroke.Transparency = 0.55
            pillStroke.Parent = pill
        end

        local dot = Instance.new("Frame")
        dot.Size = UDim2.new(0, 7, 0, 7)
        dot.Position = UDim2.new(0, 12, 0.5, -3)
        dot.BackgroundColor3 = Style.green
        dot.BorderSizePixel = 0
        dot.ZIndex = 104
        dot.Parent = pill

        do
            local dotCorner = Instance.new("UICorner")
            dotCorner.CornerRadius = UDim.new(1, 0)
            dotCorner.Parent = dot
        end

        do
            local pillText = Instance.new("TextLabel")
            pillText.Size = UDim2.new(1, -28, 1, 0)
            pillText.Position = UDim2.new(0, 26, 0, 0)
            pillText.BackgroundTransparency = 1
            pillText.Text = "LIVE  ·  PET DIMENSIONS HUB"
            pillText.TextColor3 = Style.green
            pillText.Font = Enum.Font.GothamBold
            pillText.TextSize = 11
            pillText.TextXAlignment = Enum.TextXAlignment.Left
            pillText.ZIndex = 104
            pillText.Parent = pill
        end

        taskSpawn(function()
            local tweenService = game:GetService("TweenService")
            while dot.Parent do
                local fadeOut = tweenService:Create(dot, TweenInfo.new(0.9, Enum.EasingStyle.Sine), { BackgroundTransparency = 0.7 })
                fadeOut:Play()
                fadeOut.Completed:Wait()
                local fadeIn = tweenService:Create(dot, TweenInfo.new(0.9, Enum.EasingStyle.Sine), { BackgroundTransparency = 0 })
                fadeIn:Play()
                fadeIn.Completed:Wait()
            end
        end)

        -- SESSION STATS ----------------------------------------------------
        local statsRow = Instance.new("Frame")
        statsRow.Name = "SessionStats"
        statsRow.Size = UDim2.new(1, 0, 0, 62)
        statsRow.Position = UDim2.new(0, 0, 0.17, 0)
        statsRow.BackgroundTransparency = 1
        statsRow.ZIndex = 102
        statsRow.Parent = center

        local function makeStat(index, caption, value, valueColor)
            local card = Instance.new("Frame")
            card.Size = UDim2.new(1 / 3, -8, 1, 0)
            card.Position = UDim2.new((index - 1) / 3, 4, 0, 0)
            card.BackgroundColor3 = Color3.fromRGB(27, 33, 47)
            card.BackgroundTransparency = 0.02
            card.BorderSizePixel = 0
            card.ZIndex = 103
            card.Parent = statsRow

            local cardCorner = Instance.new("UICorner")
            cardCorner.CornerRadius = UDim.new(0, 12)
            cardCorner.Parent = card

            local cardStroke = Instance.new("UIStroke")
            cardStroke.Color = Color3.fromRGB(91, 105, 128)
            cardStroke.Transparency = 0.68
            cardStroke.Thickness = 1
            cardStroke.Parent = card

            do
                local captionLabel = Instance.new("TextLabel")
                captionLabel.Size = UDim2.new(1, -24, 0, 14)
                captionLabel.Position = UDim2.new(0, 12, 0, 9)
                captionLabel.BackgroundTransparency = 1
                captionLabel.Text = caption
                captionLabel.TextColor3 = Style.muted
                captionLabel.Font = Enum.Font.GothamBold
                captionLabel.TextSize = 10
                captionLabel.TextXAlignment = Enum.TextXAlignment.Left
                captionLabel.ZIndex = 104
                captionLabel.Parent = card
            end

            local valueLabel = Instance.new("TextLabel")
            valueLabel.Size = UDim2.new(1, -24, 0, 26)
            valueLabel.Position = UDim2.new(0, 12, 0, 24)
            valueLabel.BackgroundTransparency = 1
            valueLabel.Text = value
            valueLabel.TextColor3 = valueColor or Style.text
            valueLabel:SetAttribute("ThemeKeepTextColor", valueColor ~= nil)
            valueLabel.Font = Enum.Font.GothamBold
            valueLabel.TextScaled = true
            valueLabel.TextXAlignment = Enum.TextXAlignment.Left
            valueLabel.TextYAlignment = Enum.TextYAlignment.Center
            valueLabel.ZIndex = 104
            valueLabel.Parent = card

            return valueLabel
        end

        local statTime = makeStat(1, "SESSION TIME", "00:00", Style.text)
        local statEggs = makeStat(2, "HATCHED THIS SESSION", "+0", Style.green)
        local statRares = makeStat(3, "RARES THIS SESSION", "+0", Style.violet)

-- Legacy labels the leaderstat hooks still write to. Now visible on the AFK screen.
local totalStatsRow = Instance.new("Frame")
totalStatsRow.Name = "TotalStatsRow"
totalStatsRow.Size = UDim2.new(1, 0, 0, 60)
totalStatsRow.AnchorPoint = Vector2.new(0, 0)
totalStatsRow.Position = UDim2.new(0, 0, 0.265, 0)
totalStatsRow.BackgroundTransparency = 1
totalStatsRow.ZIndex = 103
totalStatsRow.Parent = center

local function makeTotalStat(caption, value, valueColor, isRight)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(0.5, -8, 1, 0)
    card.Position = isRight and UDim2.new(0.5, 4, 0, 0) or UDim2.new(0, 0, 0, 0)
    card.BackgroundColor3 = Color3.fromRGB(27, 33, 47)
    card.BackgroundTransparency = 0.02
    card.BorderSizePixel = 0
    card.ZIndex = 104
    card.Parent = totalStatsRow

    local cardCorner = Instance.new("UICorner")
    cardCorner.CornerRadius = UDim.new(0, 12)
    cardCorner.Parent = card

    local cardStroke = Instance.new("UIStroke")
    cardStroke.Color = Color3.fromRGB(91, 105, 128)
    cardStroke.Transparency = 0.68
    cardStroke.Thickness = 1
    cardStroke.Parent = card

    local captionLabel = Instance.new("TextLabel")
    captionLabel.Size = UDim2.new(1, -20, 0, 14)
    captionLabel.Position = UDim2.new(0, 10, 0, 8)
    captionLabel.BackgroundTransparency = 1
    captionLabel.Text = caption
    captionLabel.TextColor3 = Style.muted
    captionLabel.Font = Enum.Font.GothamBold
    captionLabel.TextSize = 10
    captionLabel.TextXAlignment = Enum.TextXAlignment.Left
    captionLabel.ZIndex = 105
    captionLabel.Parent = card

    local valueLabel = Instance.new("TextLabel")
    valueLabel.Size = UDim2.new(1, -20, 0, 28)
    valueLabel.Position = UDim2.new(0, 10, 0, 22)
    valueLabel.BackgroundTransparency = 1
    valueLabel.Text = value
    valueLabel.TextColor3 = valueColor or Style.text
    valueLabel:SetAttribute("ThemeKeepTextColor", valueColor ~= nil)
    valueLabel.Font = Enum.Font.GothamBold
    valueLabel.TextScaled = true
    valueLabel.TextXAlignment = Enum.TextXAlignment.Left
    valueLabel.TextYAlignment = Enum.TextYAlignment.Center
    valueLabel.ZIndex = 105
    valueLabel.Parent = card

    return valueLabel
end

local eggsLegacy = makeTotalStat("TOTAL EGGS", "0", Color3.fromRGB(80, 230, 80), false)
eggsLegacy.Name = "AfkEggsLabel"
eggsLegacy:SetAttribute("ThemeKeepTextColor", true)

local gemsLegacy = makeTotalStat("TOTAL DIAMONDS", "0", Color3.fromRGB(110, 185, 255), true)
gemsLegacy.Name = "AfkGemsLabel"
gemsLegacy:SetAttribute("ThemeKeepTextColor", true)

        -- EXIT -------------------------------------------------------------
        local exitButton = Instance.new("TextButton")
        exitButton.Name = "ExitAFK"
        exitButton.Size = UDim2.new(0.48, 0, 0, 46)
        exitButton.AnchorPoint = Vector2.new(0.5, 1)
        exitButton.Position = UDim2.new(0.5, 0, 0.975, 0)
        exitButton.BackgroundColor3 = Color3.fromRGB(38, 20, 26)
        exitButton.Text = "TURN OFF AFK MODE"
        exitButton.TextColor3 = Color3.fromRGB(255, 220, 225)
        exitButton.Font = Enum.Font.GothamBold
        exitButton.TextSize = 15
        exitButton.ZIndex = 103
        exitButton.Parent = center

        do
            local exitConstraint = Instance.new("UISizeConstraint")
            exitConstraint.MaxSize = Vector2.new(380, 52)
            exitConstraint.MinSize = Vector2.new(210, 42)
            exitConstraint.Parent = exitButton
        end

        do
            local exitCorner = Instance.new("UICorner")
            exitCorner.CornerRadius = UDim.new(0, 14)
            exitCorner.Parent = exitButton
        end

        local exitStroke = Instance.new("UIStroke")
        exitStroke.Color = Color3.fromRGB(255, 92, 110)
        exitStroke.Transparency = 0.35
        exitStroke.Thickness = 1
        exitStroke.Parent = exitButton

        exitButton.MouseEnter:Connect(function()
            exitButton.BackgroundColor3 = Color3.fromRGB(60, 26, 34)
            exitStroke.Transparency = 0.05
        end)

        exitButton.MouseLeave:Connect(function()
            exitButton.BackgroundColor3 = Color3.fromRGB(38, 20, 26)
            exitStroke.Transparency = 0.35
        end)

        -- Live header refresh ---------------------------------------------
        local sessionStart, baseEggs

        local function readLeaderstat(name)
            if not localPlayer then return nil end
            local stats = localPlayer:FindFirstChild("leaderstats")
            local value = stats and stats:FindFirstChild(name)
            return value and tonumber(value.Value) or nil
        end

        local function refreshHeader()
            local elapsed = sessionStart and (os.clock() - sessionStart) or 0
            statTime.Text = string.format("%02d:%02d", math.floor(elapsed / 60), math.floor(elapsed % 60))

            local eggs = readLeaderstat("Eggs Hatched")
            if eggs and baseEggs then
                statEggs.Text = "+" .. tostring(math.max(eggs - baseEggs, 0))
            else
                statEggs.Text = "+0"
            end

            local rares = 0
            for _, count in pairs(afkSessionCounts) do
                rares = rares + count
            end
            statRares.Text = "+" .. tostring(rares)
        end

        taskSpawn(function()
            while overlay.Parent do
                if overlay.Visible then
                    pcall(refreshHeader)
                end
                taskWait(0.5)
            end
        end)

        return overlay, center, eggsLegacy, gemsLegacy, exitButton, function()
            sessionStart = os.clock()
            baseEggs = readLeaderstat("Eggs Hatched")
            pcall(refreshHeader)
        end
    end)()

    -- MAIN HUB WINDOW
    local autoHatchMain = Instance.new("Frame")
    autoHatchMain.Name = "AutoHatchMain"
    autoHatchMain.Size = UDim2.new(0, 1000, 0, 760)
    autoHatchMain.Position = UDim2.new(0.5, -500, 0.5, -380)
    autoHatchMain.BackgroundColor3 = Color3.fromRGB(16, 24, 40)
    autoHatchMain.BorderSizePixel = 0
    autoHatchMain.Active = true
    autoHatchMain.Draggable = true
    autoHatchMain.Visible = true
    autoHatchMain.Parent = ui

    -- Responsive window sizing: preserve the designed 1000x760 proportions,
    -- but scale the complete hub to the available viewport so headers, pages,
    -- and bottom controls are not pushed off-screen on smaller displays.
    local responsiveScale = Instance.new("UIScale")
    responsiveScale.Name = "ResponsiveUIScale"
    responsiveScale.Scale = 1
    responsiveScale.Parent = autoHatchMain
    local function updateResponsiveScale()
        local camera = workspace.CurrentCamera
        if not camera then return end
        local viewport = camera.ViewportSize
        local fitX = math.max(0.45, (viewport.X - 28) / 1000)
        local fitY = math.max(0.45, (viewport.Y - 28) / 760)
        responsiveScale.Scale = math.min(1, fitX, fitY)
        autoHatchMain.Position = UDim2.new(0.5, -500, 0.5, -380)
    end
    local viewportConnection
    local function bindViewportCamera()
        if viewportConnection then viewportConnection:Disconnect() end
        local camera = workspace.CurrentCamera
        if camera then
            viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveScale)
        end
        updateResponsiveScale()
    end
    workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindViewportCamera)
    bindViewportCamera()

    -- The ScreenGui origin is above the screen while IgnoreGuiInset is on, so
    -- a freshly centred hub lands ~58 px high. Re-centre once the ScreenGui has
    -- reported its real inset (it can be 0 on the first frame).
    defer(function()
        local inset = math.max(0, -ui.AbsolutePosition.Y)
        if inset <= 0 then return end
        if autoHatchMain.Position.Y.Offset == -380 then
            autoHatchMain.Position = UDim2.new(0.5, -500, 0.5, -380 + inset)
        end
    end)

    do
        local autoHatchCorner = Instance.new("UICorner")
        autoHatchCorner.CornerRadius = UDim.new(0, 22)
        autoHatchCorner.Parent = autoHatchMain
    end

    local autoHatchShadow = Instance.new("UIStroke")
    autoHatchShadow.Color = Color3.fromRGB(73, 190, 255)
    autoHatchShadow.Thickness = 2
    autoHatchShadow.Transparency = 0.28
    autoHatchShadow.Parent = autoHatchMain

    -- Soft accent halo + header wash. Both are children with ZIndex 0 so they
    -- stay behind the content without needing another ScreenGui.
    do
        local halo = Instance.new("Frame")
        halo.Name = "WindowHalo"
        halo.Size = UDim2.new(1, 14, 1, 14)
        halo.Position = UDim2.new(0, -7, 0, -7)
        halo.BackgroundColor3 = Color3.fromRGB(60, 140, 220)
        halo.BackgroundTransparency = 0.9
        halo.BorderSizePixel = 0
        halo.ZIndex = 0
        halo.Parent = autoHatchMain

        do
            local haloCorner = Instance.new("UICorner")
            haloCorner.CornerRadius = UDim.new(0, 22)
            haloCorner.Parent = halo
        end

        local headerGlow = Instance.new("Frame")
        headerGlow.Name = "HeaderGlow"
        headerGlow.Size = UDim2.new(1, 0, 0, 118)
        headerGlow.BackgroundColor3 = Color3.fromRGB(60, 140, 220)
        headerGlow.BackgroundTransparency = 0.86
        headerGlow.BorderSizePixel = 0
        headerGlow.ZIndex = 0
        headerGlow.Parent = autoHatchMain

        local glowGradient = Instance.new("UIGradient")
        glowGradient.Rotation = 90
        glowGradient.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(1, 1),
        })
        glowGradient.Parent = headerGlow
    end

    -- NEW SHELL: compact brand header + permanent left navigation rail.
    local autoTitle = Instance.new("TextLabel")
    autoTitle.Name = "BrandTitle"
    autoTitle.Size = UDim2.new(0, 700, 0, 38)
    autoTitle.Position = UDim2.fromOffset(250, 18)
    autoTitle.Text = "PET DIMENSIONS"
    autoTitle.TextColor3 = Color3.fromRGB(105, 215, 255)
    autoTitle.Font = Enum.Font.GothamBlack
    autoTitle.TextSize = 27
    autoTitle.BackgroundTransparency = 1
    autoTitle.TextXAlignment = Enum.TextXAlignment.Left
    autoTitle.Parent = autoHatchMain

    local autoSubtitle = Instance.new("TextLabel")
    autoSubtitle.Name = "BrandSubtitle"
    autoSubtitle.Size = UDim2.new(0, 700, 0, 20)
    autoSubtitle.Position = UDim2.fromOffset(252, 57)
    autoSubtitle.Visible = false
    autoSubtitle.Text = ""

    local brandMark = Instance.new("Frame")
    brandMark.Name = "BrandMark"
    brandMark.Size = UDim2.fromOffset(54, 54)
    brandMark.Position = UDim2.fromOffset(178, 18)
    brandMark.BackgroundColor3 = Color3.fromRGB(36, 143, 220)
    brandMark.BorderSizePixel = 0
    brandMark.Parent = autoHatchMain
    local brandMarkCorner = Instance.new("UICorner")
    brandMarkCorner.CornerRadius = UDim.new(0, 16)
    brandMarkCorner.Parent = brandMark
    local brandMarkGradient = Instance.new("UIGradient")
    brandMarkGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(46, 214, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(105, 92, 255)),
    })
    brandMarkGradient.Rotation = 35
    brandMarkGradient.Parent = brandMark
    local brandMarkText = Instance.new("TextLabel")
    brandMarkText.Size = UDim2.fromScale(1, 1)
    brandMarkText.BackgroundTransparency = 1
    brandMarkText.Text = "PD"
    brandMarkText.TextColor3 = Color3.fromRGB(255, 255, 255)
    brandMarkText.Font = Enum.Font.GothamBlack
    brandMarkText.TextSize = 20
    brandMarkText.Parent = brandMark

    local sidebar = Instance.new("Frame")
    sidebar.Name = "NavigationSidebar"
    sidebar.Position = UDim2.fromOffset(18, 94)
    sidebar.Size = UDim2.new(0, 190, 1, -112)
    sidebar.BackgroundColor3 = Color3.fromRGB(25, 42, 66)
    sidebar.BorderSizePixel = 0
    sidebar.Parent = autoHatchMain
    local sidebarCorner = Instance.new("UICorner")
    sidebarCorner.CornerRadius = UDim.new(0, 18)
    sidebarCorner.Parent = sidebar
    local sidebarStroke = Instance.new("UIStroke")
    sidebarStroke.Color = Color3.fromRGB(73, 145, 205)
    sidebarStroke.Transparency = 0.28
    sidebarStroke.Thickness = 1.4
    sidebarStroke.Parent = sidebar

    local navCaption = Instance.new("TextLabel")
    navCaption.Size = UDim2.new(1, -24, 0, 24)
    navCaption.Position = UDim2.fromOffset(12, 14)
    navCaption.BackgroundTransparency = 1
    navCaption.Text = "WORKSPACE"
    navCaption.TextColor3 = Color3.fromRGB(152, 190, 226)
    navCaption.Font = Enum.Font.GothamBold
    navCaption.TextSize = 10
    navCaption.TextXAlignment = Enum.TextXAlignment.Left
    navCaption.Parent = sidebar

    local tabBar = Instance.new("Frame")
    tabBar.Name = "TabContainer"
    tabBar.Size = UDim2.new(1, -20, 1, -58)
    tabBar.Position = UDim2.fromOffset(10, 48)
    tabBar.BackgroundTransparency = 1
    tabBar.Parent = sidebar

    -- Stack all ten navigation tabs inside the available sidebar height.
    -- Scale-based row heights keep the AFK tab inside the panel on short screens.
    local tabLayout = Instance.new("UIListLayout")
    tabLayout.FillDirection = Enum.FillDirection.Vertical
    tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
    tabLayout.Padding = UDim.new(0, 4)
    tabLayout.Parent = tabBar

    local TAB_TOTAL = { count = 10 }
    local function createTabButton(text, index)
        local btn = Instance.new("TextButton")
        btn.Name = text:gsub("%W", "") .. "NavigationButton"
        btn.Size = UDim2.new(1, 0, 0.1, -4)
        btn.LayoutOrder = index
        btn.Text = string.format("%02d     %s", index, string.upper(text))
        btn.BackgroundColor3 = Color3.fromRGB(48, 70, 99)
        btn.TextColor3 = Color3.fromRGB(237, 246, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 12
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.TextTruncate = Enum.TextTruncate.AtEnd
        btn.AutoButtonColor = false
        btn.Parent = tabBar
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 15)
        pad.Parent = btn
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 12)
        corner.Parent = btn
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(112, 164, 215)
        stroke.Thickness = 1
        stroke.Transparency = 0.42
        stroke.Parent = btn
        return btn
    end

    local hatchTab = createTabButton("Hatch", 1)
    TAB_TOTAL.autoFarmTab = createTabButton("Auto Farm", 2)
    local tpTab = createTabButton("Teleport", 3)
    local settingsTab = createTabButton("Settings", 4)
    local eggTab = createTabButton("Egg Chances", 5)
    local farmTab = createTabButton("Farm", 6)
    TAB_TOTAL.tab = createTabButton("Daycare", 7)
    TAB_TOTAL.indexUI = { tab = createTabButton("Pet Index", 8) }
    TAB_TOTAL.luckyWorld = createTabButton("Lucky World", 9)
    TAB_TOTAL.afk = createTabButton("AFK", 10)

    local pageSurface = Instance.new("Frame")
    pageSurface.Name = "PageSurface"
    pageSurface.Position = UDim2.fromOffset(222, 94)
    pageSurface.Size = UDim2.new(1, -240, 1, -112)
    pageSurface.BackgroundColor3 = Color3.fromRGB(26, 41, 62)
    pageSurface.BorderSizePixel = 0
    pageSurface.ClipsDescendants = true
    pageSurface.Parent = autoHatchMain
    local pageSurfaceCorner = Instance.new("UICorner")
    pageSurfaceCorner.CornerRadius = UDim.new(0, 18)
    pageSurfaceCorner.Parent = pageSurface
    local pageSurfaceStroke = Instance.new("UIStroke")
    pageSurfaceStroke.Color = Color3.fromRGB(73, 145, 205)
    pageSurfaceStroke.Transparency = 0.52
    pageSurfaceStroke.Thickness = 1
    pageSurfaceStroke.Parent = pageSurface

    local pageCaption = Instance.new("TextLabel")
    pageCaption.Name = "PageCaption"
    pageCaption.Position = UDim2.fromOffset(250, 108)
    pageCaption.Size = UDim2.new(1, -280, 0, 26)
    pageCaption.BackgroundTransparency = 1
    pageCaption.Text = "HATCHING"
    pageCaption.TextColor3 = Color3.fromRGB(111, 213, 255)
    pageCaption.Font = Enum.Font.GothamBlack
    pageCaption.TextSize = 16
    pageCaption.TextXAlignment = Enum.TextXAlignment.Left
    pageCaption.Parent = autoHatchMain

    local hatchFrame = Instance.new("ScrollingFrame")
    hatchFrame.Size = UDim2.new(1, -260, 1, -145)
    hatchFrame.Position = UDim2.new(0, 240, 0, 145)
    hatchFrame.BackgroundTransparency = 1
    hatchFrame.BorderSizePixel = 0
    hatchFrame.ClipsDescendants = true
    hatchFrame.ScrollBarThickness = 4
    hatchFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    hatchFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    hatchFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    hatchFrame.ClipsDescendants = true
    hatchFrame.ScrollBarThickness = 5
    do
        local hatchContentPadding = Instance.new("UIPadding")
        hatchContentPadding.Name = "HatchContentPadding"
        hatchContentPadding.PaddingLeft = UDim.new(0, 2)
        hatchContentPadding.PaddingRight = UDim.new(0, 2)
        hatchContentPadding.PaddingTop = UDim.new(0, 8)
        hatchContentPadding.PaddingBottom = UDim.new(0, 18)
        hatchContentPadding.Parent = hatchFrame
    end
    hatchFrame.Parent = autoHatchMain

    local tpFrame = Instance.new("Frame")
    tpFrame.Size = UDim2.new(1, -260, 1, -145)
    tpFrame.Position = UDim2.new(0, 240, 0, 145)
    tpFrame.BackgroundTransparency = 1
    tpFrame.Visible = false
    tpFrame.Parent = autoHatchMain

    local settingsFrame = Instance.new("Frame")
    settingsFrame.Size = UDim2.new(1, -260, 1, -145)
    settingsFrame.Position = UDim2.new(0, 240, 0, 145)
    settingsFrame.BackgroundTransparency = 1
    settingsFrame.Visible = false
    settingsFrame.Parent = autoHatchMain

    local eggFrame = Instance.new("Frame")
    eggFrame.Size = UDim2.new(1, -260, 1, -145)
    eggFrame.Position = UDim2.new(0, 240, 0, 145)
    eggFrame.BackgroundTransparency = 1
    eggFrame.Visible = false
    eggFrame.Parent = autoHatchMain

    local farmFrame = Instance.new("ScrollingFrame")
    farmFrame.Name = "FarmScroll"
    farmFrame.Size = UDim2.new(1, -260, 1, -145)
    farmFrame.Position = UDim2.new(0, 240, 0, 145)
    farmFrame.BackgroundTransparency = 1
    farmFrame.BorderSizePixel = 0
    farmFrame.ScrollBarThickness = 5
    farmFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    farmFrame.Visible = false
    farmFrame.Parent = autoHatchMain
    do local _fp = Instance.new("UIPadding") _fp.PaddingBottom = UDim.new(0, 24) _fp.Parent = farmFrame end

    TAB_TOTAL.indexUI.frame = Instance.new("Frame")
    TAB_TOTAL.indexUI.frame.Name = "IndexFrame"
    TAB_TOTAL.indexUI.frame.Size = UDim2.new(1, -260, 1, -145)
    TAB_TOTAL.indexUI.frame.Position = UDim2.new(0, 240, 0, 145)
    TAB_TOTAL.indexUI.frame.BackgroundTransparency = 1
    TAB_TOTAL.indexUI.frame.Visible = false
    TAB_TOTAL.indexUI.frame.Parent = autoHatchMain

    TAB_TOTAL.indexUI.search = Instance.new("TextBox")
    TAB_TOTAL.indexUI.search.Name = "IndexSearch"
    TAB_TOTAL.indexUI.search.Size = UDim2.new(1, -248, 0, 34)
    TAB_TOTAL.indexUI.search.Position = UDim2.fromOffset(0, 2)
    TAB_TOTAL.indexUI.search.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
    TAB_TOTAL.indexUI.search.TextColor3 = Color3.fromRGB(240, 242, 248)
    TAB_TOTAL.indexUI.search.PlaceholderColor3 = Color3.fromRGB(145, 151, 166)
    TAB_TOTAL.indexUI.search.PlaceholderText = "Search pets..."
    TAB_TOTAL.indexUI.search.Text = ""
    TAB_TOTAL.indexUI.search.ClearTextOnFocus = false
    TAB_TOTAL.indexUI.search.Font = Enum.Font.Gotham
    TAB_TOTAL.indexUI.search.TextSize = 12
    TAB_TOTAL.indexUI.search.Parent = TAB_TOTAL.indexUI.frame
    TAB_TOTAL.indexUI.searchCorner = Instance.new("UICorner")
    TAB_TOTAL.indexUI.searchCorner.CornerRadius = UDim.new(0, 8)
    TAB_TOTAL.indexUI.searchCorner.Parent = TAB_TOTAL.indexUI.search
    TAB_TOTAL.indexUI.searchPadding = Instance.new("UIPadding")
    TAB_TOTAL.indexUI.searchPadding.PaddingLeft = UDim.new(0, 10)
    TAB_TOTAL.indexUI.searchPadding.Parent = TAB_TOTAL.indexUI.search

    TAB_TOTAL.indexUI.refresh = Instance.new("TextButton")
    TAB_TOTAL.indexUI.refresh.Name = "IndexRefresh"
    TAB_TOTAL.indexUI.refresh.Size = UDim2.new(0, 82, 0, 34)
    TAB_TOTAL.indexUI.refresh.Position = UDim2.new(1, -82, 0, 2)
    TAB_TOTAL.indexUI.refresh.BackgroundColor3 = Color3.fromRGB(48, 112, 180)
    TAB_TOTAL.indexUI.refresh.TextColor3 = Color3.fromRGB(255, 255, 255)
    TAB_TOTAL.indexUI.refresh.Text = "Refresh"
    TAB_TOTAL.indexUI.refresh.Font = Enum.Font.GothamBold
    TAB_TOTAL.indexUI.refresh.TextSize = 12
    TAB_TOTAL.indexUI.refresh.Parent = TAB_TOTAL.indexUI.frame
    TAB_TOTAL.indexUI.refreshCorner = Instance.new("UICorner")
    TAB_TOTAL.indexUI.refreshCorner.CornerRadius = UDim.new(0, 8)
    TAB_TOTAL.indexUI.refreshCorner.Parent = TAB_TOTAL.indexUI.refresh

    TAB_TOTAL.indexUI.nearbyToggle = Instance.new("TextButton")
    TAB_TOTAL.indexUI.nearbyToggle.Name = "NearbyEggUIToggle"
    TAB_TOTAL.indexUI.nearbyToggle.Size = UDim2.new(0, 154, 0, 34)
    TAB_TOTAL.indexUI.nearbyToggle.Position = UDim2.new(1, -240, 0, 2)
    TAB_TOTAL.indexUI.nearbyToggle.BackgroundColor3 = Color3.fromRGB(67, 104, 145)
    TAB_TOTAL.indexUI.nearbyToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
    TAB_TOTAL.indexUI.nearbyToggle.Text = "Nearby Egg UI: OFF"
    TAB_TOTAL.indexUI.nearbyToggle:SetAttribute("ThemeRole", "Toggle")
    TAB_TOTAL.indexUI.nearbyToggle:SetAttribute("ToggleState", false)
    TAB_TOTAL.indexUI.nearbyToggle.Font = Enum.Font.GothamBold
    TAB_TOTAL.indexUI.nearbyToggle.TextSize = 11
    TAB_TOTAL.indexUI.nearbyToggle.Parent = TAB_TOTAL.indexUI.frame
    TAB_TOTAL.indexUI.nearbyToggleCorner = Instance.new("UICorner")
    TAB_TOTAL.indexUI.nearbyToggleCorner.CornerRadius = UDim.new(0, 8)
    TAB_TOTAL.indexUI.nearbyToggleCorner.Parent = TAB_TOTAL.indexUI.nearbyToggle

    TAB_TOTAL.indexUI.summary = Instance.new("TextLabel")
    TAB_TOTAL.indexUI.summary.Name = "IndexSummary"
    TAB_TOTAL.indexUI.summary.Size = UDim2.new(1, 0, 0, 22)
    TAB_TOTAL.indexUI.summary.Position = UDim2.fromOffset(0, 42)
    TAB_TOTAL.indexUI.summary.BackgroundTransparency = 1
    TAB_TOTAL.indexUI.summary.TextColor3 = Color3.fromRGB(165, 174, 192)
    TAB_TOTAL.indexUI.summary.TextXAlignment = Enum.TextXAlignment.Left
    TAB_TOTAL.indexUI.summary.Font = Enum.Font.GothamMedium
    TAB_TOTAL.indexUI.summary.TextSize = 11
    TAB_TOTAL.indexUI.summary.Text = "Loading pet index..."
    TAB_TOTAL.indexUI.summary.Parent = TAB_TOTAL.indexUI.frame

    TAB_TOTAL.indexUI.list = Instance.new("ScrollingFrame")
    TAB_TOTAL.indexUI.list.Name = "IndexPetList"
    TAB_TOTAL.indexUI.list.Size = UDim2.new(1, 0, 1, -78)
    TAB_TOTAL.indexUI.list.Position = UDim2.fromOffset(0, 72)
    TAB_TOTAL.indexUI.list.BackgroundTransparency = 1
    TAB_TOTAL.indexUI.list.BorderSizePixel = 0
    TAB_TOTAL.indexUI.list.ScrollBarThickness = 4
    TAB_TOTAL.indexUI.list.CanvasSize = UDim2.new(0, 0, 0, 0)
    TAB_TOTAL.indexUI.list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    TAB_TOTAL.indexUI.list.Parent = TAB_TOTAL.indexUI.frame
    TAB_TOTAL.indexUI.layout = Instance.new("UIListLayout")
    TAB_TOTAL.indexUI.layout.SortOrder = Enum.SortOrder.LayoutOrder
    TAB_TOTAL.indexUI.layout.Padding = UDim.new(0, 5)
    TAB_TOTAL.indexUI.layout.Parent = TAB_TOTAL.indexUI.list
TAB_TOTAL.indexUI.padding = Instance.new("UIPadding")
TAB_TOTAL.indexUI.padding.PaddingBottom = UDim.new(0, 12)
TAB_TOTAL.indexUI.padding.Parent = TAB_TOTAL.indexUI.list

TAB_TOTAL.luckyWorldFrame = Instance.new("Frame")
TAB_TOTAL.luckyWorldFrame.Name = "LuckyWorldFrame"
TAB_TOTAL.luckyWorldFrame.Size = UDim2.new(1, -260, 1, -145)
TAB_TOTAL.luckyWorldFrame.Position = UDim2.new(0, 240, 0, 145)
TAB_TOTAL.luckyWorldFrame.BackgroundTransparency = 1
TAB_TOTAL.luckyWorldFrame.Visible = false
TAB_TOTAL.luckyWorldFrame.Parent = autoHatchMain

TAB_TOTAL.afkFrame = Instance.new("ScrollingFrame")
TAB_TOTAL.afkFrame.Name = "AfkFrame"
TAB_TOTAL.afkFrame.Size = UDim2.new(1, -260, 1, -145)
TAB_TOTAL.afkFrame.Position = UDim2.new(0, 240, 0, 145)
TAB_TOTAL.afkFrame.BackgroundTransparency = 1
TAB_TOTAL.afkFrame.BorderSizePixel = 0
TAB_TOTAL.afkFrame.ScrollBarThickness = 5
TAB_TOTAL.afkFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
TAB_TOTAL.afkFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
TAB_TOTAL.afkFrame.Visible = false
TAB_TOTAL.afkFrame.Parent = autoHatchMain
do local _afkPad = Instance.new("UIPadding") _afkPad.PaddingBottom = UDim.new(0, 24) _afkPad.Parent = TAB_TOTAL.afkFrame end

-- Auto Farm page was referenced by the tab switcher and page container, but
-- its frame was never instantiated. That nil frame stopped the UI build.
-- Use a ScrollingFrame so the dropdowns and helper text remain reachable on
-- shorter windows and lower resolutions.
TAB_TOTAL.autoFarmFrame = Instance.new("ScrollingFrame")
TAB_TOTAL.autoFarmFrame.Name = "AutoFarmFrame"
TAB_TOTAL.autoFarmFrame.Size = UDim2.new(1, -260, 1, -145)
TAB_TOTAL.autoFarmFrame.Position = UDim2.new(0, 240, 0, 145)
TAB_TOTAL.autoFarmFrame.BackgroundTransparency = 1
TAB_TOTAL.autoFarmFrame.BorderSizePixel = 0
TAB_TOTAL.autoFarmFrame.ScrollBarThickness = 5
TAB_TOTAL.autoFarmFrame.ScrollBarImageTransparency = 0.35
TAB_TOTAL.autoFarmFrame.ScrollingDirection = Enum.ScrollingDirection.Y
TAB_TOTAL.autoFarmFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
TAB_TOTAL.autoFarmFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
TAB_TOTAL.autoFarmFrame.Visible = false
TAB_TOTAL.autoFarmFrame.Parent = autoHatchMain
do
    local afPadding = Instance.new("UIPadding")
    afPadding.PaddingRight = UDim.new(0, 8)
    afPadding.PaddingBottom = UDim.new(0, 18)
    afPadding.Parent = TAB_TOTAL.autoFarmFrame
end

TAB_TOTAL.frame = Instance.new("ScrollingFrame")
    TAB_TOTAL.frame.Name = "DaycareScroll"
    TAB_TOTAL.frame.Size = UDim2.new(1, -260, 1, -145)
    TAB_TOTAL.frame.Position = UDim2.new(0, 240, 0, 145)
    TAB_TOTAL.frame.BackgroundTransparency = 1
    TAB_TOTAL.frame.BorderSizePixel = 0
    TAB_TOTAL.frame.ScrollBarThickness = 5
    TAB_TOTAL.frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    TAB_TOTAL.frame.CanvasSize = UDim2.new(0, 0, 0, 0)
    TAB_TOTAL.frame.Visible = false
    TAB_TOTAL.frame.Parent = autoHatchMain
    do local _dp = Instance.new("UIPadding") _dp.PaddingBottom = UDim.new(0, 24) _dp.Parent = TAB_TOTAL.frame end

    -- All tab pages share one clipped viewport inside PageSurface. Previously
    -- they were siblings of the panel and extended below its bottom edge; that
    -- let scrolling content (notably the webhook card) appear outside the page.
    local pageFrames = {
        hatchFrame, TAB_TOTAL.autoFarmFrame, tpFrame, settingsFrame, eggFrame, farmFrame,
        TAB_TOTAL.frame, TAB_TOTAL.indexUI.frame, TAB_TOTAL.luckyWorldFrame,
        TAB_TOTAL.afkFrame,
    }
    for _, page in ipairs(pageFrames) do
        page.Parent = pageSurface
        page.Position = UDim2.fromOffset(18, 51)
        page.Size = UDim2.new(1, -36, 1, -66)
        page.ClipsDescendants = true
        if page:IsA("ScrollingFrame") then
            page.AutomaticCanvasSize = Enum.AutomaticSize.Y
            page.CanvasSize = UDim2.new(0, 0, 0, 0)
        end
    end

    -- =====================================================================
    -- FULL EXTENDED THEMES SYSTEM
    -- =====================================================================
    -- Forward declarations. These were implicit globals before; keeping them
    -- local avoids leaking state into the executor environment and lets
    -- applyTheme see the theme rows/scroll created much later in this builder.
    local themeRows, themeScroll, statsContainer

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
            if obj:IsA("GuiObject") then
                -- Capture even currently-transparent surfaces so a later
                -- transparency change can reveal them in the active palette.
                data.background = obj.BackgroundColor3
            end
            if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                data.text = obj.TextColor3
                data.textStroke = obj.TextStrokeColor3
            end
            if obj:IsA("TextBox") then
                data.placeholder = obj.PlaceholderColor3
            end
            if obj:IsA("ScrollingFrame") then
                data.scrollbar = obj.ScrollBarImageColor3
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
            -- Preserve deliberately saturated text colors. These include
            -- rarity labels (Golden/Rainbow/Shiny), category names and the
            -- green/blue stat values. Only neutral text is remapped to the
            -- active palette, so a theme switch cannot erase rarity meaning.
            if maxc - minc >= 0.18 and bright < 0.94 then
                return original
            end
            if minc > 0.82 then
                return activeTheme.text
            end
            return activeTheme.muted
        end

        if kind == "background" then
            -- State-aware controls are handled by ThemeRole below. All other
            -- decorative/colorful fills follow the active palette; red danger
            -- states retain the theme danger color.
            if r > g * 1.45 and r > b * 1.45 and r > 0.38 then
                return activeTheme.danger
            elseif bright < 0.055 then
                return activeTheme.background
            elseif bright < 0.20 then
                return activeTheme.panel
            elseif bright < 0.42 then
                return activeTheme.surface
            else
                return activeTheme.surface
            end
        end

        return original
    end

    local themeApplying = false
    local themedWatchers = setmetatable({}, { __mode = "k" })

    local function applyThemeToObject(obj)
        if not obj or not obj.Parent then return end
        if obj:GetAttribute("ThemePreview") then return end
        if themeApplying then return end

        local locked = obj:GetAttribute("ThemeLocked") == true
        local keepText = obj:GetAttribute("ThemeKeepTextColor") == true
        local role = obj:GetAttribute("ThemeRole")
        local base = rememberBaseColors(obj)
        themeApplying = true

        -- Rounded surfaces are cards/containers in this UI. Ensure they have
        -- a subtle outline so they remain distinguishable even in themes
        -- whose panel and background colors are very close together.
        if obj:IsA("GuiObject") and obj:FindFirstChildOfClass("UICorner")
            and not obj:FindFirstChildOfClass("UIStroke") then
            local outline = Instance.new("UIStroke")
            outline.Name = "ThemeAutoOutline"
            outline.Color = activeTheme.stroke
            outline.Thickness = 1
            outline.Transparency = 0.42
            outline.Parent = obj
            rememberBaseColors(outline)
        end

        -- Every surface, including AFK cards and overlays, follows the active
        -- palette. ThemeLocked is reserved only for deliberately semantic fills.
        if not locked and base.background and obj:IsA("GuiObject") and obj.BackgroundTransparency < 1 then
            if role == "Toggle" then
                local isOn = obj:GetAttribute("ToggleState") == true
                local isHovered = obj:GetAttribute("ThemeHover") == true
                obj.BackgroundColor3 = isOn and activeTheme.controlOn or (isHovered and activeTheme.accent or activeTheme.surface)
            elseif role == "Tab" then
                local isActive = obj:GetAttribute("TabActive") == true
                local isHovered = obj:GetAttribute("ThemeHover") == true
                obj.BackgroundColor3 = isActive and activeTheme.accent or (isHovered and activeTheme.panel or activeTheme.surface)
            elseif role == "Accent" then
                obj.BackgroundColor3 = activeTheme.accent
            else
                obj.BackgroundColor3 = themeAdaptColor(base.background, "background")
            end
        end

        if base.text and (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) then
            if keepText then
                -- Restore the original semantic color, not the currently
                -- themed color. This matters when a label was first themed
                -- before its rarity/semantic attribute was assigned.
                obj.TextColor3 = base.text
            elseif role == "Toggle" or role == "Tab" then
                local isActive = obj:GetAttribute("ToggleState") == true or obj:GetAttribute("TabActive") == true
                obj.TextColor3 = isActive and activeTheme.text or activeTheme.muted
            else
                obj.TextColor3 = themeAdaptColor(base.text, "text")
            end
        end

        if base.textStroke and (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) then
            obj.TextStrokeColor3 = activeTheme.stroke
        end
        if base.placeholder and obj:IsA("TextBox") then
            obj.PlaceholderColor3 = activeTheme.muted
        end
        if base.scrollbar and obj:IsA("ScrollingFrame") then
            obj.ScrollBarImageColor3 = activeTheme.accent
        end
        if base.stroke and obj:IsA("UIStroke") then
            obj.Color = activeTheme.stroke
            obj.Transparency = math.min(obj.Transparency, 0.42)
        end
        if base.image and (obj:IsA("ImageLabel") or obj:IsA("ImageButton")) then
            obj.ImageColor3 = activeTheme.accent
        end

        -- Repaint gradients too; otherwise the AFK backdrop/title retain the
        -- previous palette even when their parent Frames have been themed.
        if obj:IsA("UIGradient") then
            if obj.Parent and obj.Parent.Name == "Title" then
                obj.Color = ColorSequence.new({
                    ColorSequenceKeypoint.new(0, activeTheme.text),
                    ColorSequenceKeypoint.new(0.55, activeTheme.accent),
                    ColorSequenceKeypoint.new(1, activeTheme.controlOn),
                })
            elseif obj.Parent and obj.Parent.Name == "Backdrop" then
                obj.Color = ColorSequence.new({
                    ColorSequenceKeypoint.new(0, activeTheme.panel),
                    ColorSequenceKeypoint.new(0.55, activeTheme.background),
                    ColorSequenceKeypoint.new(1, activeTheme.background),
                })
            else
                obj.Color = ColorSequence.new(activeTheme.surface, activeTheme.accent)
            end
        end
        themeApplying = false
    end

    local function applyThemeToUI(root)
        if not root then return end
        applyThemeToObject(root)
        for _, obj in ipairs(root:GetDescendants()) do
            applyThemeToObject(obj)
        end
    end

    -- =====================================================================
    -- GLOBAL CONTROL POLISH
    -- One hover treatment for every button that does not already define its
    -- own stroke. This keeps all seven tabs, toggles and generated lists
    -- feeling like the same UI without touching each builder.
    -- =====================================================================
    local polishedStrokes = setmetatable({}, { __mode = "k" })

    local function polishControl(obj)
        if not obj:IsA("TextButton") then return end
        if obj:GetAttribute("PolishDone") then return end
        obj:SetAttribute("PolishDone", true)

        if not obj:FindFirstChildOfClass("UICorner") then
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 8)
            corner.Parent = obj
        end

        if obj:FindFirstChildOfClass("UIStroke") then
            return
        end

        local stroke = Instance.new("UIStroke")
        stroke.Color = activeTheme.stroke
        stroke.Thickness = 1
        stroke.Transparency = 0.85
        stroke.Parent = obj

        obj.MouseEnter:Connect(function()
            stroke.Transparency = 0.35
        end)

        obj.MouseLeave:Connect(function()
            stroke.Transparency = 0.85
        end)

        polishedStrokes[obj] = stroke
    end

    -- Give information groups a consistent visible boundary. Several older
    -- builders used transparent frames, so on low-contrast palettes their
    -- contents visually ran together. Only semantic card/panel/section groups
    -- are normalized; layout-only frames remain untouched.
    local polishedPanels = setmetatable({}, { __mode = "k" })
    local function polishPanel(obj)
        if not obj or not obj:IsA("Frame") or polishedPanels[obj] then return end
        local n = string.lower(obj.Name or "")
        local semanticPanel = n:find("card", 1, true) or n:find("panel", 1, true)
            or n:find("section", 1, true) or n:find("tile", 1, true)
        if not semanticPanel then return end
        polishedPanels[obj] = true
        if obj.BackgroundTransparency >= 0.98 then
            obj.BackgroundTransparency = 0.12
            obj.BackgroundColor3 = activeTheme.panel
        end
        local stroke = obj:FindFirstChildOfClass("UIStroke")
        if not stroke then
            stroke = Instance.new("UIStroke")
            stroke.Name = "ThemePanelStroke"
            stroke.Thickness = 1
            stroke.Transparency = 0.42
            stroke.Color = activeTheme.stroke
            stroke.Parent = obj
        end
        stroke.Color = activeTheme.stroke
    end

    local function applyTheme(themeObj)
        activeTheme = themeObj
        CurrentThemeName = themeObj.name
        saveSettings()

        applyThemeToUI(ui)
        applyThemeToUI(afkGui)

        autoHatchMain.BackgroundColor3 = activeTheme.background
        autoHatchShadow.Color = activeTheme.accent
        -- The title used to be hard-coded blue, so it ignored the theme
        -- entirely and sat oddly against every palette except the default.
        autoTitle.TextColor3 = activeTheme.text

        local halo = autoHatchMain:FindFirstChild("WindowHalo")
        if halo then halo.BackgroundColor3 = activeTheme.accent end
        local headerGlow = autoHatchMain:FindFirstChild("HeaderGlow")
        if headerGlow then headerGlow.BackgroundColor3 = activeTheme.accent end
        local titleAccent = autoHatchMain:FindFirstChild("TitleAccent")
        if titleAccent then titleAccent.BackgroundColor3 = activeTheme.accent end
        trackerStroke.Color = activeTheme.accent
        trackerStroke.Transparency = 0.55

        for _, stroke in pairs(polishedStrokes) do
            if stroke and stroke.Parent then
                stroke.Color = activeTheme.stroke
            end
        end
        for panel in pairs(polishedPanels) do
            if panel and panel.Parent then
                local panelStroke = panel:FindFirstChild("ThemePanelStroke") or panel:FindFirstChildOfClass("UIStroke")
                if panelStroke then panelStroke.Color = activeTheme.stroke end
                if panel.BackgroundTransparency < 0.98 then
                    panel.BackgroundColor3 = activeTheme.panel
                end
            end
        end

        for _, btn in ipairs({hatchTab, tpTab, settingsTab, eggTab, farmTab, TAB_TOTAL.tab, TAB_TOTAL.indexUI.tab, TAB_TOTAL.luckyWorld, TAB_TOTAL.afk}) do
            btn:SetAttribute("ThemeRole", "Tab")
            local tabStroke = btn:FindFirstChildOfClass("UIStroke")
            local isActive = (btn == currentTabBtn)
            btn:SetAttribute("TabActive", isActive)
            if isActive then
                btn.BackgroundColor3 = activeTheme.accent
                btn.TextColor3 = activeTheme.text
                if tabStroke then
                    tabStroke.Color = activeTheme.accent
                    tabStroke.Transparency = 0.08
                end
            else
                btn.BackgroundColor3 = activeTheme.surface
                btn.TextColor3 = activeTheme.muted
                if tabStroke then
                    tabStroke.Color = activeTheme.stroke
                    tabStroke.Transparency = 0.72
                end
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
        -- Re-apply state-aware colors after the theme switch so no toggle keeps
        -- its previous blue/green fill. This also covers generated controls.
        for _, root in ipairs({ui, afkGui}) do
            for _, obj in ipairs(root:GetDescendants()) do
                if obj:GetAttribute("ThemeRole") == "Toggle" then
                    applyThemeToObject(obj)
                end
            end
        end
    end

    -- Instantly theme newly-created UI too. This fixes controls that previously
    -- needed a click/repaint before their new colors became visible.
    local function watchThemeProperties(obj)
        if not obj or themedWatchers[obj] then return end
        themedWatchers[obj] = true
        local function repaint()
            if themeApplying then return end
            defer(function()
                if obj and obj.Parent and not themeApplying then
                    applyThemeToObject(obj)
                end
            end)
        end
        if obj:IsA("GuiObject") then
            obj:GetPropertyChangedSignal("BackgroundColor3"):Connect(repaint)
            obj:GetPropertyChangedSignal("BackgroundTransparency"):Connect(repaint)
        end
        if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
            obj:GetPropertyChangedSignal("TextColor3"):Connect(repaint)
            obj:GetPropertyChangedSignal("TextStrokeColor3"):Connect(repaint)
        end
        if obj:IsA("TextBox") then
            obj:GetPropertyChangedSignal("PlaceholderColor3"):Connect(repaint)
        end
        if obj:IsA("ScrollingFrame") then
            obj:GetPropertyChangedSignal("ScrollBarImageColor3"):Connect(repaint)
        end
        if obj:IsA("UIGradient") then
            obj:GetPropertyChangedSignal("Color"):Connect(repaint)
        end
        if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
            obj:GetPropertyChangedSignal("ImageColor3"):Connect(repaint)
        end
        if obj:IsA("UIStroke") then
            obj:GetPropertyChangedSignal("Color"):Connect(repaint)
        end
    end

    local function onThemedDescendantAdded(obj)
        defer(function()
            if obj and obj.Parent then
                rememberBaseColors(obj)
                watchThemeProperties(obj)
                applyThemeToObject(obj)
                if obj:IsA("TextButton") then
                    polishControl(obj)
                end
                polishPanel(obj)
            end
        end)
    end
    ui.DescendantAdded:Connect(onThemedDescendantAdded)
    afkGui.DescendantAdded:Connect(onThemedDescendantAdded)

    -- Sweep controls that existed before the connection above.
    for _, root in ipairs({ui, afkGui}) do
        for _, obj in ipairs(root:GetDescendants()) do
            rememberBaseColors(obj)
            watchThemeProperties(obj)
            if obj:IsA("TextButton") and root == ui then
                polishControl(obj)
            end
            polishPanel(obj)
        end
    end


    local function switchTab(activeBtn, activeFrame)
    hatchFrame.Visible = false
    TAB_TOTAL.autoFarmFrame.Visible = false
    tpFrame.Visible = false
    settingsFrame.Visible = false
    eggFrame.Visible = false
    farmFrame.Visible = false
    TAB_TOTAL.frame.Visible = false
    TAB_TOTAL.indexUI.frame.Visible = false
    TAB_TOTAL.luckyWorldFrame.Visible = false
    TAB_TOTAL.afkFrame.Visible = false

    for _, btn in ipairs({hatchTab, TAB_TOTAL.autoFarmTab, tpTab, settingsTab, eggTab, farmTab, TAB_TOTAL.tab, TAB_TOTAL.indexUI.tab, TAB_TOTAL.luckyWorld, TAB_TOTAL.afk}) do
            local tabStroke = btn:FindFirstChildOfClass("UIStroke")
            btn:SetAttribute("TabActive", false)
            btn.BackgroundColor3 = activeTheme.surface
            btn.TextColor3 = activeTheme.muted
            if tabStroke then
                tabStroke.Color = activeTheme.stroke
                tabStroke.Transparency = 0.72
            end
            local tabUnderline = btn:FindFirstChild("ActiveUnderline")
            if tabUnderline then
                tabUnderline.Visible = false
            end
        end

        activeFrame.Visible = true
        activeBtn:SetAttribute("TabActive", true)
        activeBtn.BackgroundColor3 = activeTheme.accent
        activeBtn.TextColor3 = activeTheme.text
        local activeStroke = activeBtn:FindFirstChildOfClass("UIStroke")
        if activeStroke then
            activeStroke.Color = activeTheme.accent
            activeStroke.Transparency = 0.08
        end
        currentTabBtn = activeBtn
        currentTabFrame = activeFrame
        if pageCaption then
            pageCaption.Text = string.upper(activeBtn.Text:gsub("^%d+%s+", "")):gsub("%s+", " ")
        end
    end

    -- Tab hover: lifts the fill toward the accent without touching the active
    -- tab. Defined here because it needs activeTheme in scope.
    for _, btn in ipairs({hatchTab, TAB_TOTAL.autoFarmTab, tpTab, settingsTab, eggTab, farmTab, TAB_TOTAL.tab, TAB_TOTAL.indexUI.tab, TAB_TOTAL.luckyWorld, TAB_TOTAL.afk}) do
        local tabStroke = btn:FindFirstChildOfClass("UIStroke")
        btn.MouseEnter:Connect(function()
            if btn:GetAttribute("TabActive") then return end
            btn:SetAttribute("ThemeHover", true)
            btn.BackgroundColor3 = activeTheme.panel
            if tabStroke then tabStroke.Transparency = 0.45 end
        end)
        btn.MouseLeave:Connect(function()
            btn:SetAttribute("ThemeHover", false)
            if btn:GetAttribute("TabActive") then return end
            btn.BackgroundColor3 = activeTheme.surface
            if tabStroke then tabStroke.Transparency = 0.42 end
        end)
    end

    hatchTab.MouseButton1Click:Connect(function() switchTab(hatchTab, hatchFrame) end)
    TAB_TOTAL.autoFarmTab.MouseButton1Click:Connect(function() switchTab(TAB_TOTAL.autoFarmTab, TAB_TOTAL.autoFarmFrame) end)
    tpTab.MouseButton1Click:Connect(function() switchTab(tpTab, tpFrame) end)
    settingsTab.MouseButton1Click:Connect(function() switchTab(settingsTab, settingsFrame) end)
    eggTab.MouseButton1Click:Connect(function() switchTab(eggTab, eggFrame) end)
    farmTab.MouseButton1Click:Connect(function() switchTab(farmTab, farmFrame) end)
    TAB_TOTAL.tab.MouseButton1Click:Connect(function() switchTab(TAB_TOTAL.tab, TAB_TOTAL.frame) end)
TAB_TOTAL.indexUI.tab.MouseButton1Click:Connect(function() switchTab(TAB_TOTAL.indexUI.tab, TAB_TOTAL.indexUI.frame) end)
TAB_TOTAL.luckyWorld.MouseButton1Click:Connect(function() switchTab(TAB_TOTAL.luckyWorld, TAB_TOTAL.luckyWorldFrame) end)
TAB_TOTAL.afk.MouseButton1Click:Connect(function() switchTab(TAB_TOTAL.afk, TAB_TOTAL.afkFrame) end)

switchTab(hatchTab, hatchFrame)

    -- UNIFIED TOGGLE GENERATOR HELPER
    local toggleRegistry = {}
    local toggleCallbacks = {}

    local function createUnifiedToggle(parent, yPos, text, defaultState, callback)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 34)
        btn.Position = UDim2.new(0, 0, 0, yPos)
        btn.BackgroundColor3 = defaultState and Color3.fromRGB(20, 190, 126) or Color3.fromRGB(67, 104, 145)
        btn.Text = text .. (defaultState and ": ON" or ": OFF")
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 13
        btn.Parent = parent

        do
            local btnCorner = Instance.new("UICorner")
            btnCorner.CornerRadius = UDim.new(0, 6)
            btnCorner.Parent = btn
        end

        do
            local btnStroke = Instance.new("UIStroke")
            btnStroke.Color = activeTheme.stroke
            btnStroke.Thickness = 1
            btnStroke.Transparency = 0.7
            btnStroke.Parent = btn
        end

        -- Toggles that must never come back ON from the saved config. AFK opens the
        -- full-screen overlay and hides the hub, so restoring it made every
        -- execute look broken. Kept in a set so more toggles can be added
        -- later without touching the restore loop.
        local NEVER_RESTORE = {
            ["AFK Mode"] = true,
        }

        local state = (not NEVER_RESTORE[text]) and CurrentToggleStates[text] == true or defaultState
        if NEVER_RESTORE[text] then
            -- also drop the stale saved value so the button does not light up
            -- green while the feature is actually off
            CurrentToggleStates[text] = false
        end
        btn:SetAttribute("ToggleState", state)
        btn:SetAttribute("ThemeRole", "Toggle")
        toggleCallbacks[text] = callback

        -- A restored toggle used to show ON without actually running, so the
        -- feature looked enabled until it was clicked twice. Replay the
        -- callback once for restored settings (AFK Mode is excluded above).
        if state and not NEVER_RESTORE[text] then
            pcall(callback, true)
        end

        local hovered = false

        local function updateVisuals(newState)
            state = newState
            btn:SetAttribute("ToggleState", state)
            btn.BackgroundColor3 = state and activeTheme.controlOn or (hovered and activeTheme.accent or activeTheme.surface)
            btn.Text = text .. (state and ": ON" or ": OFF")
            btn.TextColor3 = activeTheme.text
        end

        updateVisuals(state)

        btn.MouseEnter:Connect(function()
            hovered = true
            btn:SetAttribute("ThemeHover", true)
            updateVisuals(state)
        end)

        btn.MouseLeave:Connect(function()
            hovered = false
            btn:SetAttribute("ThemeHover", false)
            updateVisuals(state)
        end)

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
    do
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
    end

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
    createUnifiedToggle(farmFrame, 158, "Fast Attack", false, function(state) FastAttackSpeed = state end)
    createUnifiedToggle(farmFrame, 200, "Fast Pet Speed", false, function(state)
        FastPetSpeed = state
        -- Apply immediately (and restore the real upgrade on OFF) instead of
        -- waiting for the background loop. Nil-safe: the engine is defined
        -- later in the file than this UI block.
        if ApplyFastPetSpeedFn then pcall(ApplyFastPetSpeedFn, state) end
    end)

    createUnifiedToggle(farmFrame, 242, "Hacker Boss Farm", false, function(state)
        AutoFarmHackerBoss = state
        if not state then
            CurrentHackerBoss = nil
            CurrentHackerBossId = nil
        end
    end)

    -- returned nil every tick and the dodge/attack scheduler never had a
    -- status-bar and damage branches still read it.


    createUnifiedToggle(farmFrame, 284, "Auto Free Gifts", false, function(state)
        AutoCollectFreeGifts = state
    end)

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

    -- Buys out every Diamond Pack in the Exclusive Shop with Rainbow Coins and
    -- keeps re-buying as the daily stock restocks.
    createUnifiedToggle(farmFrame, 452, "Auto Diamond Packs", false, function(state)
        AutoDiamondPacks = state
        DiamondPackStatus = state and "Starting..." or "Idle"
        DiamondPackLastStock = -1
        if not state then DiamondPackStockText = "" end
    end)

    do
        local antiAfkLabel = Instance.new("TextLabel")
        antiAfkLabel.Size = UDim2.new(0.58, 0, 0, 28)
        antiAfkLabel.Position = UDim2.new(0, 0, 0, 494)
        antiAfkLabel.BackgroundTransparency = 1
        antiAfkLabel.Text = "Anti AFK interval (minutes)"
        antiAfkLabel.TextColor3 = Color3.fromRGB(190, 190, 200)
        antiAfkLabel.Font = Enum.Font.GothamBold
        antiAfkLabel.TextSize = 12
        antiAfkLabel.TextXAlignment = Enum.TextXAlignment.Left
        antiAfkLabel.Parent = farmFrame
    end

    local antiAfkBox = Instance.new("TextBox")
    antiAfkBox.Size = UDim2.new(0.32, 0, 0, 28)
    antiAfkBox.Position = UDim2.new(0.68, 0, 0, 494)
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

    do
        local antiAfkCorner = Instance.new("UICorner")
        antiAfkCorner.CornerRadius = UDim.new(0, 6)
        antiAfkCorner.Parent = antiAfkBox
    end

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
    farmStatus.Position = UDim2.new(0, 0, 0, 532)
    farmStatus.BackgroundTransparency = 1
    farmStatus.Text = "Status: Idle"
    farmStatus.TextColor3 = Color3.fromRGB(180, 180, 180)
    farmStatus.Font = Enum.Font.GothamBold
    farmStatus.TextSize = 13
    farmStatus.TextXAlignment = Enum.TextXAlignment.Left
    farmStatus.Parent = farmFrame

    -- Per-tier Diamond Pack stock, shown only while Auto Diamond Packs is on so
    -- each tier can be watched draining and the engine's reads confirmed.
    local diamondStock = Instance.new("TextLabel")
    diamondStock.Size = UDim2.new(1, 0, 0, 24)
    diamondStock.Position = UDim2.new(0, 0, 0, 562)
    diamondStock.BackgroundTransparency = 1
    diamondStock.Text = ""
    diamondStock.TextColor3 = Color3.fromRGB(215, 170, 255)
    diamondStock.Font = Enum.Font.GothamBold
    diamondStock.TextSize = 12
    diamondStock.TextXAlignment = Enum.TextXAlignment.Left
    diamondStock.Visible = false
    diamondStock.Parent = farmFrame

    taskSpawn(function()
        while farmFrame.Parent do
            diamondStock.Visible = AutoDiamondPacks
            if AutoDiamondPacks then
                farmStatus.Text = "Status: " .. tostring(DiamondPackStatus)
                farmStatus.TextColor3 = Color3.fromRGB(255, 190, 255)
                diamondStock.Text = "Stock: " .. (DiamondPackStockText ~= "" and DiamondPackStockText or "-")
            elseif AutoBuying then
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
            taskWait(0.5)
        end
    end)

    -- =====================================================================
    -- AFK TAB UI
    -- Unattended chores: group rewards, spinny wheels, potion upgrade/use and
    -- the quest driver. The engines live further down (they need the teleport
    -- helpers), so these rows only flip the shared top-level flags.
    -- =====================================================================
    do
        local afkTitle = Instance.new("TextLabel")
        afkTitle.Size = UDim2.new(1, 0, 0, 24)
        afkTitle.Position = UDim2.new(0, 0, 0, 0)
        afkTitle.BackgroundTransparency = 1
        afkTitle.Text = "AFK AUTOMATION"
        afkTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
        afkTitle.Font = Enum.Font.GothamBold
        afkTitle.TextSize = 14
        afkTitle.TextXAlignment = Enum.TextXAlignment.Left
        afkTitle.Parent = TAB_TOTAL.afkFrame
    end

    do
        local afkSub = Instance.new("TextLabel")
        afkSub.Size = UDim2.new(1, 0, 0, 40)
        afkSub.Position = UDim2.new(0, 0, 0, 26)
        afkSub.BackgroundTransparency = 1
        afkSub.Text = "Claim group rewards, spin the wheels, upgrade and drink max-tier Lucky/Coins/Damage potions. Auto Quests works the BK / PetsGOModder / Zephyrr main line through each quest to the claim, then picks up the next one."
        afkSub.TextColor3 = Color3.fromRGB(190, 190, 200)
        afkSub.Font = Enum.Font.Gotham
        afkSub.TextSize = 11
        afkSub.TextWrapped = true
        afkSub.TextXAlignment = Enum.TextXAlignment.Left
        afkSub.Parent = TAB_TOTAL.afkFrame
    end

    createUnifiedToggle(TAB_TOTAL.afkFrame, 74, "Auto Group Rewards", false, function(state)
        AutoGroupRewards = state
        AfkGroupStatus = state and "Starting..." or "Idle"
    end)

    createUnifiedToggle(TAB_TOTAL.afkFrame, 116, "Auto Spinny Wheels", false, function(state)
        AutoSpinnyWheels = state
        AfkWheelStatus = state and "Starting..." or "Idle"
    end)

    createUnifiedToggle(TAB_TOTAL.afkFrame, 158, "Auto Upgrade Potions", false, function(state)
        AutoPotionUpgrade = state
        AfkPotionStatus = state and "Starting..." or "Idle"
    end)

    createUnifiedToggle(TAB_TOTAL.afkFrame, 200, "Auto Use Max Potions", false, function(state)
        AutoPotionUse = state
        AfkPotionUseStatus = state and "Starting..." or "Idle"
    end)

    -- -----------------------------------------------------------------
    -- Quest section header + the two driver toggles.
    --
    -- These rows used to sit at 242/268, which is only 26px apart while every
    -- other toggle row is 42px and 34px tall, so the two quest buttons overlapped
    -- each other and the status label below cut into the second one.
    --
    -- The header is built inside an immediately-called function so it adds no
    -- local register to this already register-tight UI builder closure.
    -- -----------------------------------------------------------------
    ;(function(frame)
        local questHeader = Instance.new("TextLabel")
        questHeader.Size = UDim2.new(1, 0, 0, 22)
        questHeader.Position = UDim2.new(0, 0, 0, 240)
        questHeader.BackgroundTransparency = 1
        questHeader.Text = "QUEST LINES  (auto-accepts and works them in order)"
        questHeader.TextColor3 = Color3.fromRGB(255, 220, 120)
        questHeader.Font = Enum.Font.GothamBold
        questHeader.TextSize = 11
        questHeader.TextXAlignment = Enum.TextXAlignment.Left
        questHeader.Parent = frame
    end)(TAB_TOTAL.afkFrame)

    -- Forward declaration so quest-toggle callbacks can always stop auto-hatch.
    local setAutoHatchState

    local autoQuestsToggle = createUnifiedToggle(TAB_TOTAL.afkFrame, 264, "Auto Quests (main lines)", false, function(state)
        AutoQuests = state
        AfkQuestStatus = state and "Starting..." or "Idle"
        if not state then
            QuestCoinFilter = nil
            QuestFarmActive = false
            QuestAreaFarmWanted = false
            QuestAreaFarmTarget = nil
            QuestHatchAnywhere = false
            QuestTargetEggId = nil
            QuestTargetEggLabel = nil
            QuestPlaytimeActive = false
            if not AutoQuestsSide and type(setAutoHatchState) == "function" then
                pcall(setAutoHatchState, false)
            end
        end
    end)

    local autoQuestsSideToggle = createUnifiedToggle(TAB_TOTAL.afkFrame, 306, "Auto Side Quests (event lines)", false, function(state)
        AutoQuestsSide = state
        AfkSideQuestStatus = state and "Starting..." or "Idle"
        if not state then
            QuestCoinFilter = nil
            QuestFarmActive = false
            QuestAreaFarmWanted = false
            QuestAreaFarmTarget = nil
            QuestHatchAnywhere = false
            QuestTargetEggId = nil
            QuestTargetEggLabel = nil
            QuestPlaytimeActive = false
            if not AutoQuests and type(setAutoHatchState) == "function" then
                pcall(setAutoHatchState, false)
            end
        end
    end)

    if not autoQuestsToggle or not autoQuestsSideToggle then
        warn("[Pet Dimensions Hub] Auto Quests toggle failed to create")
    end

    ;(function()
        -- -----------------------------------------------------------------
        -- Playtime AFK pickers.
        --
        -- PlaytimeSeconds objectives used to just wait the clock out. These two
        -- dropdowns let the user pick the area to farm and the egg to hatch
        -- while that clock ticks, so the wait also earns breakables and pets.
        -- Both write the top-level AfkFarmArea / AfkFarmEgg the quest driver
        -- reads in applyObjective, and both persist across sessions.
        --
        -- Wrapped in an immediately-called function so this whole widget adds
        -- no live locals to the surrounding register-tight UI builder.
        -- -----------------------------------------------------------------
        local afkPickHeader = Instance.new("TextLabel")
        afkPickHeader.Size = UDim2.new(1, 0, 0, 20)
        afkPickHeader.Position = UDim2.new(0, 0, 0, 352)
        afkPickHeader.BackgroundTransparency = 1
        afkPickHeader.Text = "PLAYTIME AFK  (farm + hatch during Playtime quests)"
        afkPickHeader.TextColor3 = Color3.fromRGB(255, 220, 120)
        afkPickHeader.Font = Enum.Font.GothamBold
        afkPickHeader.TextSize = 11
        afkPickHeader.TextXAlignment = Enum.TextXAlignment.Left
        afkPickHeader.Parent = TAB_TOTAL.afkFrame

        local function makePickerButton(name, y, text)
            local button = Instance.new("TextButton")
            button.Name = name
            button.Size = UDim2.new(1, 0, 0, 34)
            button.Position = UDim2.new(0, 0, 0, y)
            button.BackgroundColor3 = activeTheme.surface
            button.TextColor3 = Color3.fromRGB(235, 238, 245)
            button.Font = Enum.Font.GothamBold
            button.TextSize = 12
            button.TextXAlignment = Enum.TextXAlignment.Left
            button.Text = text
            button.Parent = TAB_TOTAL.afkFrame
            do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = button end
            do local s = Instance.new("UIStroke"); s.Color = activeTheme.stroke; s.Thickness = 1; s.Transparency = 0.7; s.Parent = button end
            do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 10); p.Parent = button end
            return button
        end

        local afkAreaSelect = makePickerButton("AfkAreaSelect", 376, "Farm area: none (pick one)")
        local afkEggSelect = makePickerButton("AfkEggSelect", 434, "Hatch egg: none (pick one)")

        -- Shared dropdown renderer. `names` is the full option list, `onPick`
        -- receives the chosen string. The list rebuilds itself on every open so
        -- newly added areas/eggs show up without a reload.
        local function makePickerList(name, y, height, placeholderText)
            local list = Instance.new("ScrollingFrame")
            list.Name = name
            list.Size = UDim2.new(1, 0, 0, height)
            list.Position = UDim2.new(0, 0, 0, y)
            list.BackgroundColor3 = Color3.fromRGB(30, 34, 44)
            list.BorderSizePixel = 0
            list.ScrollBarThickness = 4
            list.Visible = false
            list.ZIndex = 20
            list.CanvasSize = UDim2.new(0, 0, 0, 0)
            list.AutomaticCanvasSize = Enum.AutomaticSize.Y
            list.Parent = TAB_TOTAL.afkFrame
            local layout = Instance.new("UIListLayout")
            layout.Padding = UDim.new(0, 1)
            layout.SortOrder = Enum.SortOrder.LayoutOrder
            layout.Parent = list

            local search = Instance.new("TextBox")
            search.Name = name .. "Search"
            search.Size = UDim2.new(1, -6, 0, 30)
            search.BackgroundColor3 = activeTheme.surface
            search.TextColor3 = Color3.fromRGB(235, 238, 245)
            search.PlaceholderColor3 = Color3.fromRGB(145, 155, 170)
            search.PlaceholderText = placeholderText
            search.Text = ""
            search.ClearTextOnFocus = false
            search.Font = Enum.Font.Gotham
            search.TextSize = 11
            search.TextXAlignment = Enum.TextXAlignment.Left
            search.LayoutOrder = 0
            search.ZIndex = 21
            search.Parent = list
            do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 5); c.Parent = search end
            do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 8); p.Parent = search end

            return list, search, layout
        end

        local function renderPicker(list, search, layout, names, onPick)
            for _, child in ipairs(list:GetChildren()) do
                if child ~= layout and child ~= search then child:Destroy() end
            end
            local query = search.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
            local shown = 0
            for _, optionName in ipairs(names) do
                if query == "" or optionName:lower():find(query, 1, true) then
                    shown = shown + 1
                    local row = Instance.new("TextButton")
                    row.Size = UDim2.new(1, -6, 0, 26)
                    row.ZIndex = 21
                    row.BackgroundTransparency = 1
                    row.TextColor3 = Color3.fromRGB(230, 233, 240)
                    row.Text = optionName
                    row.Font = Enum.Font.Gotham
                    row.TextSize = 11
                    row.TextXAlignment = Enum.TextXAlignment.Left
                    row.LayoutOrder = shown
                    row.Parent = list
                    row.MouseButton1Click:Connect(function()
                        onPick(optionName)
                        list.Visible = false
                    end)
                end
            end
            if shown == 0 then
                local empty = Instance.new("TextLabel")
                empty.Size = UDim2.new(1, -8, 0, 26)
                empty.BackgroundTransparency = 1
                empty.Text = "No matches"
                empty.TextColor3 = Color3.fromRGB(170, 175, 185)
                empty.Font = Enum.Font.Gotham
                empty.TextSize = 11
                empty.LayoutOrder = 1
                empty.ZIndex = 21
                empty.Parent = list
            end
        end

        local function sortedKeys(t, predicate)
            local names = {}
            if type(t) == "table" then
                for name, def in pairs(t) do
                    if not predicate or predicate(name, def) then
                        names[#names + 1] = tostring(name)
                    end
                end
            end
            table.sort(names)
            return names
        end

        local afkAreaList, afkAreaSearch, afkAreaLayout =
            makePickerList("AfkAreaList", 412, 160, "Search farm area...")
        local afkEggList, afkEggSearch, afkEggLayout =
            makePickerList("AfkEggList", 470, 180, "Search hatch egg...")

        afkAreaSelect.MouseButton1Click:Connect(function()
            afkEggList.Visible = false
            if afkAreaList.Visible then
                afkAreaList.Visible = false
            else
                renderPicker(
                    afkAreaList, afkAreaSearch, afkAreaLayout,
                    sortedKeys(Library.Directory.Areas),
                    function(optionName)
                        AfkFarmArea = optionName
                        afkAreaSelect.Text = "Farm area: " .. optionName
                        SetSetting("afkFarmArea", optionName)
                        saveSettings()
                    end
                )
                afkAreaList.Visible = true
            end
        end)

        afkEggSelect.MouseButton1Click:Connect(function()
            afkAreaList.Visible = false
            if afkEggList.Visible then
                afkEggList.Visible = false
            else
                renderPicker(
                    afkEggList, afkEggSearch, afkEggLayout,
                    sortedKeys(Library.Directory.Eggs, function(_, def)
                        return type(def) == "table" and def.hatchable == true
                    end),
                    function(optionName)
                        AfkFarmEgg = optionName
                        afkEggSelect.Text = "Hatch egg: " .. optionName
                        SetSetting("afkFarmEgg", optionName)
                        saveSettings()
                    end
                )
                afkEggList.Visible = true
            end
        end)

        afkAreaSearch:GetPropertyChangedSignal("Text"):Connect(function()
            if afkAreaList.Visible then
                renderPicker(
                    afkAreaList, afkAreaSearch, afkAreaLayout,
                    sortedKeys(Library.Directory.Areas),
                    function(optionName)
                        AfkFarmArea = optionName
                        afkAreaSelect.Text = "Farm area: " .. optionName
                        SetSetting("afkFarmArea", optionName)
                        saveSettings()
                    end
                )
            end
        end)

        afkEggSearch:GetPropertyChangedSignal("Text"):Connect(function()
            if afkEggList.Visible then
                renderPicker(
                    afkEggList, afkEggSearch, afkEggLayout,
                    sortedKeys(Library.Directory.Eggs, function(_, def)
                        return type(def) == "table" and def.hatchable == true
                    end),
                    function(optionName)
                        AfkFarmEgg = optionName
                        afkEggSelect.Text = "Hatch egg: " .. optionName
                        SetSetting("afkFarmEgg", optionName)
                        saveSettings()
                    end
                )
            end
        end)

        -- Restore the saved picks so a rejoin keeps the same playtime setup.
        local savedAfkArea = GetSetting("afkFarmArea")
        if type(savedAfkArea) == "string" and savedAfkArea ~= "" then
            AfkFarmArea = savedAfkArea
            afkAreaSelect.Text = "Farm area: " .. savedAfkArea
        end
        local savedAfkEgg = GetSetting("afkFarmEgg")
        if type(savedAfkEgg) == "string" and savedAfkEgg ~= "" then
            AfkFarmEgg = savedAfkEgg
            afkEggSelect.Text = "Hatch egg: " .. savedAfkEgg
        end

        local afkPickHint = Instance.new("TextLabel")
        afkPickHint.Size = UDim2.new(1, 0, 0, 32)
        afkPickHint.Position = UDim2.new(0, 0, 0, 494)
        afkPickHint.BackgroundTransparency = 1
        afkPickHint.Text = "While a Playtime quest is active the script parks in the chosen area, runs Auto Farm there and hatches the chosen egg. When both are set the egg decides the spot (its area is farmed); pick only an area to farm it without hatching."
        afkPickHint.TextColor3 = Color3.fromRGB(180, 190, 205)
        afkPickHint.Font = Enum.Font.Gotham
        afkPickHint.TextSize = 11
        afkPickHint.TextWrapped = true
        afkPickHint.TextXAlignment = Enum.TextXAlignment.Left
        afkPickHint.TextYAlignment = Enum.TextYAlignment.Top
        afkPickHint.Parent = TAB_TOTAL.afkFrame
    end)()

    do
        local afkStatus = Instance.new("TextLabel")
        afkStatus.Size = UDim2.new(1, 0, 0, 150)
        afkStatus.Position = UDim2.new(0, 0, 0, 532)
        afkStatus.BackgroundTransparency = 1
        afkStatus.Text = ""
        afkStatus.TextColor3 = Color3.fromRGB(200, 200, 210)
        afkStatus.Font = Enum.Font.Gotham
        afkStatus.TextSize = 12
        afkStatus.TextWrapped = true
        afkStatus.TextXAlignment = Enum.TextXAlignment.Left
        afkStatus.TextYAlignment = Enum.TextYAlignment.Top
        afkStatus.Parent = TAB_TOTAL.afkFrame

        taskSpawn(function()
            while afkStatus.Parent do
                afkStatus.Text = table.concat({
                    "Group rewards: " .. tostring(AfkGroupStatus),
                    "Wheels: " .. tostring(AfkWheelStatus),
                    "Potion upgrade: " .. tostring(AfkPotionStatus),
                    "Potion use: " .. tostring(AfkPotionUseStatus),
                    "Main quests: " .. tostring(AfkQuestStatus),
                    "Side quests: " .. tostring(AfkSideQuestStatus),
                }, "\n")
                taskWait(0.5)
            end
        end)
    end

    -- =====================================================================
    -- LUCKY WORLD TAB
    -- Tile upgrades, boost machine, lucky panel upgrades and boss attacks.
    -- =====================================================================
    local AutoTileUpgrade = false
    local AutoBoostMachine = false
    local AutoLuckyUpgrades = false
    local AutoBossAttack = false
    local AutoMazeEnabled = false

    do
        local luckyTitle = Instance.new("TextLabel")
        luckyTitle.Size = UDim2.new(1, 0, 0, 24)
        luckyTitle.Position = UDim2.new(0, 0, 0, 0)
        luckyTitle.BackgroundTransparency = 1
        luckyTitle.Text = "LUCKY WORLD"
        luckyTitle.TextColor3 = Color3.fromRGB(255, 210, 80)
        luckyTitle.Font = Enum.Font.GothamBold
        luckyTitle.TextSize = 14
        luckyTitle.TextXAlignment = Enum.TextXAlignment.Left
        luckyTitle.Parent = TAB_TOTAL.luckyWorldFrame
    end

    do
        local luckySub = Instance.new("TextLabel")
        luckySub.Size = UDim2.new(1, 0, 0, 40)
        luckySub.Position = UDim2.new(0, 0, 0, 26)
        luckySub.BackgroundTransparency = 1
        luckySub.Text = "Upgrade the tile you land on, keep the boost machine topped up, buy lucky upgrades and send pets at the Lucky Block Boss."
        luckySub.TextColor3 = Color3.fromRGB(190, 190, 200)
        luckySub.Font = Enum.Font.Gotham
        luckySub.TextSize = 11
        luckySub.TextWrapped = true
        luckySub.TextXAlignment = Enum.TextXAlignment.Left
        luckySub.Parent = TAB_TOTAL.luckyWorldFrame
    end

    local tileToggle = createUnifiedToggle(TAB_TOTAL.luckyWorldFrame, 70, "Auto Tile Upgrade", false, function(state)
        AutoTileUpgrade = state
    end)

    local boostToggle = createUnifiedToggle(TAB_TOTAL.luckyWorldFrame, 110, "Auto Boost Machine", false, function(state)
        AutoBoostMachine = state
    end)

    local panelToggle = createUnifiedToggle(TAB_TOTAL.luckyWorldFrame, 150, "Auto Lucky Upgrades", false, function(state)
        AutoLuckyUpgrades = state
    end)

    local bossToggle = createUnifiedToggle(TAB_TOTAL.luckyWorldFrame, 190, "Auto Boss Attack (1 by 1)", false, function(state)
        AutoBossAttack = state
    end)

    local autoMazeToggle = createUnifiedToggle(TAB_TOTAL.luckyWorldFrame, 230, "Auto Maze (Lucky Time Trial)", false, function(state)
        AutoMazeEnabled = state
    end)

    -- createUnifiedToggle restores the saved look without replaying the
    -- callback, so pull the runtime flags back out of the buttons once.
    AutoTileUpgrade = tileToggle:GetAttribute("ToggleState") == true
    AutoBoostMachine = boostToggle:GetAttribute("ToggleState") == true
    AutoLuckyUpgrades = panelToggle:GetAttribute("ToggleState") == true
    AutoBossAttack = bossToggle:GetAttribute("ToggleState") == true

    local luckyStatus = Instance.new("TextLabel")
    luckyStatus.Size = UDim2.new(1, 0, 0, 24)
    luckyStatus.Position = UDim2.new(0, 0, 0, 274)
    luckyStatus.BackgroundTransparency = 1
    luckyStatus.Text = "Status: Idle"
    luckyStatus.TextColor3 = Color3.fromRGB(180, 180, 180)
    luckyStatus.Font = Enum.Font.GothamBold
    luckyStatus.TextSize = 12
    luckyStatus.TextXAlignment = Enum.TextXAlignment.Left
    luckyStatus.Parent = TAB_TOTAL.luckyWorldFrame

    local luckyDetail = Instance.new("TextLabel")
    luckyDetail.Size = UDim2.new(1, 0, 0, 22)
    luckyDetail.Position = UDim2.new(0, 0, 0, 300)
    luckyDetail.BackgroundTransparency = 1
    luckyDetail.Text = "Tile upgrades cost Breakout Bucks - boosts cost Lucky Coins."
    luckyDetail.TextColor3 = Color3.fromRGB(150, 160, 180)
    luckyDetail.Font = Enum.Font.Gotham
    luckyDetail.TextSize = 11
    luckyDetail.TextXAlignment = Enum.TextXAlignment.Left
    luckyDetail.Parent = TAB_TOTAL.luckyWorldFrame

    local autoMazeStatus = Instance.new("TextLabel")
    autoMazeStatus.Name = "AutoMazeStatus"
    autoMazeStatus.Size = UDim2.new(1, 0, 0, 22)
    autoMazeStatus.Position = UDim2.new(0, 0, 0, 326)
    autoMazeStatus.BackgroundTransparency = 1
    autoMazeStatus.Text = "Auto Maze: Off"
    autoMazeStatus.TextColor3 = Color3.fromRGB(150, 160, 180)
    autoMazeStatus.Font = Enum.Font.Gotham
    autoMazeStatus.TextSize = 11
    autoMazeStatus.TextXAlignment = Enum.TextXAlignment.Left
    autoMazeStatus.Parent = TAB_TOTAL.luckyWorldFrame

    -- Lucky World automation logic ----------------------------------------
    local LuckyBoardData = Library.Shared and Library.Shared.LuckyBoard
    local LuckyWorldData = Library.Shared and Library.Shared.LuckyWorld

    local function readCurrency(key)
        local ok, save = pcall(function() return Library.Save.Get() end)
        if ok and type(save) == "table" then
            return tonumber(save[key])
        end
        return nil
    end

    local function getLuckyInfo()
        if not RawNet.invoke then return nil end
        local ok, success, info = RawNet.invoke("Lucky World: Info")
        if ok and success and type(info) == "table" then
            return info
        end
        return nil
    end

    local function getBoardState()
        if not RawNet.invoke then return nil end
        local ok, success, state = RawNet.invoke("Lucky Board: Get")
        if ok and success and type(state) == "table" then
            return state
        end
        return nil
    end

    local function tileMaxTier(tileIndex)
        if not (LuckyBoardData and LuckyBoardData.Layout and LuckyBoardData.Types) then
            return 1
        end
        local typeName = LuckyBoardData.Layout[tileIndex]
        local def = typeName and LuckyBoardData.Types[typeName]
        return def and def.Tiers and #def.Tiers or 1
    end

    local function getLuckyBossCoin()
        local attr
        local ok = pcall(function() attr = ReplicatedStorage:GetAttribute("LuckyBossBlock") end)
        if not ok or type(attr) ~= "string" or attr == "" then return nil end

        local ok2, data = pcall(function() return HttpService:JSONDecode(attr) end)
        if not ok2 or type(data) ~= "table" or data.id == nil then return nil end

        local things = Workspace:FindFirstChild("__THINGS")
        local coins = things and things:FindFirstChild("Coins")
        local coin = coins and coins:FindFirstChild(tostring(data.id))
        if coin and coin.Parent then
            return coin
        end
        return nil
    end

    -- Tile: upgrade once per new tile the player lands on.
    taskSpawn(function()
        local lastTile = nil
        while TAB_TOTAL.luckyWorldFrame.Parent do
            if AutoTileUpgrade and RawNet.invoke then
                local state = getBoardState()
                local tile = state and tonumber(state.t)
                if tile and tile > 0 then
                    local tier = tonumber(state.u and state.u[tostring(tile)]) or 0
                    local maxTier = tileMaxTier(tile)

                    if lastTile ~= tile then
                        lastTile = tile

                        if tier >= maxTier then
                            luckyStatus.Text = ("Status: Tile %d is already maxed"):format(tile)
                            luckyStatus.TextColor3 = Color3.fromRGB(160, 170, 190)
                        else
                            local ok, success, err = RawNet.invoke("Lucky Board: Upgrade", tile, tier + 1)
                            if ok and success then
                                luckyStatus.Text = ("Status: Tile %d upgraded to tier %d"):format(tile, tier + 1)
                                luckyStatus.TextColor3 = Color3.fromRGB(120, 230, 140)
                            elseif ok and type(err) == "string" and err:find("Breakout Bucks") then
                                luckyStatus.Text = ("Status: Tile %d needs more Breakout Bucks"):format(tile)
                                luckyStatus.TextColor3 = Color3.fromRGB(255, 190, 90)
                            else
                                luckyStatus.Text = ("Status: Tile %d upgrade rejected"):format(tile)
                                luckyStatus.TextColor3 = Color3.fromRGB(255, 130, 130)
                            end
                        end
                    end
                end
                taskWait(0.5)
            else
                lastTile = nil
                taskWait(0.7)
            end
        end
    end)

    -- Boost machine: fill each rarity to MaxSeconds using the exact amount
    -- the game's own purchase button would spend.
    taskSpawn(function()
        while TAB_TOTAL.luckyWorldFrame.Parent do
            local boost = LuckyWorldData and LuckyWorldData.Boost
            if AutoBoostMachine and RawNet.invoke and boost then
                local info = getLuckyInfo()
                local coins = readCurrency("Lucky Coins") or 0
                local maxSeconds = tonumber(boost.MaxSeconds) or 21600
                local order = boost.Order or { "Gargantuan", "Titanic", "Huge" }
                local bought = false

                if info and type(info.b) == "table" then
                    for _, rarity in ipairs(order) do
                        local left = math.max(0, tonumber(info.b[rarity]) or 0)
                        local toMax = tonumber(boost.CoinsToMax and boost.CoinsToMax[rarity]) or 0
                        if toMax > 0 and left < maxSeconds - 1 then
                            local cost = (maxSeconds - left) * toMax / maxSeconds
                            local amount = math.floor(math.min(cost, coins))
                            if amount >= 1 then
                                local ok, success, err = RawNet.invoke("Lucky World: Boost", rarity, amount)
                                if ok and success then
                                    luckyStatus.Text = ("Status: Boosted %s with %d Lucky Coins"):format(rarity, amount)
                                    luckyStatus.TextColor3 = Color3.fromRGB(120, 230, 140)
                                else
                                    luckyStatus.Text = ("Status: %s boost failed: %s"):format(rarity, tostring(err))
                                    luckyStatus.TextColor3 = Color3.fromRGB(255, 130, 130)
                                end
                                bought = true
                                break
                            end
                        end
                    end
                end

                if not bought then
                    luckyStatus.Text = "Status: Boost machine maxed"
                    luckyStatus.TextColor3 = Color3.fromRGB(160, 170, 190)
                end

                taskWait(bought and 1.2 or 3)
            else
                taskWait(0.7)
            end
        end
    end)

    -- Lucky panel: buy the cheapest affordable upgrade in the game's own
    -- suggested order (EggTier, Power, Coins, BlockLuck, luck tiers).
    taskSpawn(function()
        while TAB_TOTAL.luckyWorldFrame.Parent do
            local upgrades = LuckyWorldData and LuckyWorldData.Upgrades
            if AutoLuckyUpgrades and RawNet.invoke and type(upgrades) == "table" then
                local info = getLuckyInfo()
                local bucks = readCurrency("Breakout Bucks") or 0
                local bestId, bestCost = nil, math.huge

                if info and type(info.u) == "table" then
                    local order = info.o or {}
                    for _, id in ipairs(order) do
                        local def
                        for _, entry in ipairs(upgrades) do
                            if entry.Id == id then def = entry break end
                        end
                        if def then
                            local tier = tonumber(info.u[id]) or 0
                            local cost = def.Costs and tonumber(def.Costs[tier + 1])
                            if cost and cost <= bucks and cost < bestCost then
                                bestId, bestCost = id, cost
                            end
                        end
                    end
                end

                if bestId then
                    local ok, success = RawNet.invoke("Lucky World: Upgrade", bestId)
                    if ok and success then
                        luckyStatus.Text = ("Status: Bought %s upgrade for %d bucks"):format(bestId, bestCost)
                        luckyStatus.TextColor3 = Color3.fromRGB(120, 230, 140)
                    else
                        luckyStatus.Text = ("Status: %s upgrade rejected"):format(bestId)
                        luckyStatus.TextColor3 = Color3.fromRGB(255, 190, 90)
                    end
                    taskWait(1.2)
                else
                    luckyStatus.Text = "Status: No affordable Lucky Upgrade"
                    luckyStatus.TextColor3 = Color3.fromRGB(160, 170, 190)
                    taskWait(3)
                end
            else
                taskWait(1)
            end
        end
    end)

    -- Boss: the game's Select Coin path assigns one pet per signal, which is
    -- exactly the 1-by-1 pacing wanted. Keep firing while the boss exists.
    taskSpawn(function()
        local lastBoss = nil
        while TAB_TOTAL.luckyWorldFrame.Parent do
            if AutoBossAttack then
                local coin = getLuckyBossCoin()
                if coin then
                    local id = coin:GetAttribute("ID")
                    if id ~= nil then
                        if lastBoss ~= id then
                            lastBoss = id
                            luckyStatus.Text = "Status: Attacking Lucky Block Boss (1 by 1)"
                            luckyStatus.TextColor3 = Color3.fromRGB(255, 210, 80)
                        end
                        pcall(function() Library.Signal.Fire("Select Coin", coin) end)
                        taskWait(0.07)
                    else
                        taskWait(0.4)
                    end
                else
                    if lastBoss ~= nil then
                        luckyStatus.Text = "Status: Boss gone - waiting"
                        luckyStatus.TextColor3 = Color3.fromRGB(160, 170, 190)
                    end
                    lastBoss = nil
                    taskWait(0.5)
                end
            else
                lastBoss = nil
                taskWait(0.5)
            end
        end
    end)

    -- Currency readout for the tab.
    taskSpawn(function()
        while TAB_TOTAL.luckyWorldFrame.Parent do
            if TAB_TOTAL.luckyWorldFrame.Visible then
                local bucks = readCurrency("Breakout Bucks")
                local coins = readCurrency("Lucky Coins")
                luckyDetail.Text = ("Bucks: %s   Lucky Coins: %s"):format(
                    bucks and string.format("%.0f", bucks) or "?",
                    coins and string.format("%.0f", coins) or "?"
                )
            end
            taskWait(1)
        end
    end)


    -- =====================================================================
    -- AUTO MAZE: Lucky Time Trial path runner
    -- Uses the maze route logic from the standalone Auto Maze script.
    -- The feature is controlled exclusively by the Lucky World tab toggle.
    -- =====================================================================
    ;(function()
local MAZE_CONFIG = {
    enabled = false,
    driftTolerance = 0.5,     -- studs of drift before the character is re-seated
    portalEnterDelay = 1.1,   -- wait 1.1 seconds before walking into the exit portal
    portalWalkTimeout = 5,    -- hard cap on the walk into the portal
    portalWalkStep = 0.05,    -- seconds between arrival-distance checks
    portalWalkRadius = 1.5,   -- studs from the portal centre that count as arrived
    portalWalkSpeed = 100,    -- temporary humanoid speed while entering the exit portal
    portalRetryTimeout = 10,  -- seconds to wait for the next maze after the portal
    statusInterval = 0.25,    -- seconds between status line rebuilds
    verbose = true,
}

local MazeEnv = getExecutorEnv()
local MAZE = MazeEnv.__LuckyMazeState or {
    enabled = false,
    mazesDone = 0,
    roomsCleared = 0,
    status = "idle",
    portalBusy = false,
    currentEntrance = nil,
}
MazeEnv.__LuckyMazeState = MAZE

local function mlog(fmt, ...)
    if not MAZE_CONFIG.verbose then
        return
    end
    local ok, line = pcall(string.format, "[AutoMaze] " .. fmt, ...)
    print(ok and line or ("[AutoMaze] " .. fmt))
end

--==========================================================================
-- Maze introspection
--==========================================================================

local function localCharacter()
    local char = localPlayer.Character
    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp and hrp:IsA("BasePart") then
            return char, hrp
        end
    end
    return nil, nil
end

local function inTrial()
    return localPlayer:GetAttribute("InstanceId") == "LuckyTimeTrial"
end

local function mazeModel()
    local things = workspace:FindFirstChild("__THINGS")
    local container = things and things:FindFirstChild("__INSTANCE_CONTAINER")
    local active = container and container:FindFirstChild("Active")
    return active and active:FindFirstChild("LuckyTimeTrial") or nil
end

-- Only real rooms carry RoomRole. Previews and gate frames do not, so they drop
-- out of this list without any extra filtering.
local function builtRooms(model)
    local folder = model and model:FindFirstChild("Rooms")
    if not folder then
        return {}
    end

    local list = {}
    for _, inst in ipairs(folder:GetChildren()) do
        local role = inst:GetAttribute("RoomRole")
        if type(role) == "string" then
            list[#list + 1] = {
                model = inst,
                role = role,
                onPath = inst:GetAttribute("OnPath") == true,
                number = tonumber(inst:GetAttribute("RoomNumber")) or 0,
                cellX = tonumber(inst:GetAttribute("CellX")) or 0,
                cellY = tonumber(inst:GetAttribute("CellY")) or 0,
            }
        end
    end
    return list
end

local function pathOrder(rooms)
    local path = {}
    for _, room in ipairs(rooms) do
        if room.onPath then
            path[#path + 1] = room
        end
    end
    table.sort(path, function(a, b)
        return a.number < b.number
    end)
    return path
end

-- Middle of the room's breakable square, lifted clear of the floor so the
-- character never spawns inside the floor slab.
local function roomSpot(room)
    local model = room.model
    local floor = model:FindFirstChild("Floor")
    local floorTop = floor and floor:IsA("BasePart") and (floor.Position.Y + floor.Size.Y * 0.5) or nil

    local zones = model:FindFirstChild("BREAK_ZONES")
    local zone = zones and zones:FindFirstChild("Zone")
    if zone and zone:IsA("BasePart") then
        return Vector3.new(zone.Position.X, (floorTop or zone.Position.Y) + 3.5, zone.Position.Z)
    end

    if floor and floor:IsA("BasePart") then
        return floor.Position + Vector3.new(0, floor.Size.Y * 0.5 + 3.5, 0)
    end

    return nil
end

local function teleportPart(room)
    for _, inst in ipairs(room.model:GetDescendants()) do
        if inst:IsA("BasePart") and inst.Name == "TeleportPart" then
            return inst
        end
    end
    return nil
end

local function breakablesIn(spot)
    local things = workspace:FindFirstChild("__THINGS")
    local coins = things and things:FindFirstChild("Coins")
    if not coins or not spot then
        return {}
    end

    local out = {}
    for _, coin in ipairs(coins:GetChildren()) do
        local name = coin:GetAttribute("Name")
        if type(name) == "string" and name:sub(1, 5) == "Maze " then
            local marker = coin:FindFirstChild("POS")
            local pos = marker and marker.Position
            if pos and math.abs(pos.X - spot.X) <= 33 and math.abs(pos.Z - spot.Z) <= 33 then
                out[#out + 1] = coin
            end
        end
    end
    return out
end

--==========================================================================
-- Teleport / portal
--==========================================================================

local function seat(hrp, position)
    hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
    hrp.CFrame = CFrame.new(position)
end

-- Poke the trigger directly. Uses the shared cross-executor touch helper so a
-- missing/renamed firetouchinterest cannot break the portal fallback.
local function portalTaken(part, entrance)
    if not part.Parent then
        return true
    end
    local path = pathOrder(builtRooms(mazeModel()))
    return path[1] ~= nil and path[1].model ~= entrance
end

-- Plain humanoid walk. MoveTo is re-issued on a short interval because the
-- humanoid clears its destination whenever it recomputes a path, and the
-- portal trigger only fires once the character actually overlaps it.
local function walkTo(hrp, position, radius, timeout, portalPart, entrance)
    local char = hrp.Parent
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then
        return false
    end

    local originalWalkSpeed = hum.WalkSpeed
    local step = MAZE_CONFIG.portalWalkStep
    local deadline = os.clock() + timeout
    local lastPush = 0

    -- Always cancel the old MoveTo and restore the player's normal speed.
    -- This is especially important when the portal teleports us mid-walk.
    local function stopWalk()
        pcall(function()
            if hum.Parent then
                hum:MoveTo(hrp.Position)
                hum.WalkSpeed = originalWalkSpeed
            end
        end)
    end

    hum.WalkSpeed = MAZE_CONFIG.portalWalkSpeed
    hum:MoveTo(position)

    while os.clock() < deadline do
        if not hrp.Parent or not hum.Parent then
            stopWalk()
            return false
        end

        -- The portal has loaded the next maze (or the trial ended). Do not
        -- keep issuing MoveTo toward the old portal in the newly loaded room.
        if not inTrial() or not portalPart.Parent or portalTaken(portalPart, entrance) then
            stopWalk()
            return true
        end

        local flat = Vector3.new(hrp.Position.X - position.X, 0, hrp.Position.Z - position.Z)
        if flat.Magnitude <= radius then
            stopWalk()
            return true
        end

        if os.clock() - lastPush >= 0.2 then
            lastPush = os.clock()
            hum:MoveTo(position)
        end

        taskWait(step)
    end

    stopWalk()
    return false
end

-- Executor touch helper, used only when the walk never produces a real overlap.
-- The verify callback stops after the first method that actually moves the
-- player into the next maze, so no method is fired twice unnecessarily.
local function forceTouch(hrp, part)
    fireTouchSafe(hrp, part, function()
        return portalTaken(part, MAZE.currentEntrance) or not inTrial()
    end)
end

-- Enter the exit portal so the game's own trigger fires, then fall back to a
-- forced touch if the trigger never registers.
local function walkIntoPortal(room)
    if MAZE.portalBusy then
        return
    end

    local part = teleportPart(room)
    if not part then
        return
    end

    MAZE.portalBusy = true
    MAZE.status = "holding at exit portal"

    taskSpawn(function()
        local entrance = MAZE.currentEntrance
        local enterAt = os.clock() + MAZE_CONFIG.portalEnterDelay

        -- Hold in the portal room for a moment so the run doesn't look like an
        -- instant snap into the exit.
        while os.clock() < enterAt do
            if not part.Parent or portalTaken(part, entrance) then
                break
            end
            local left = enterAt - os.clock()
            MAZE.status = ("portal in %.1fs"):format(math.max(0, left))
            taskWait(0.05)
        end

        if part.Parent and not portalTaken(part, entrance) then
            MAZE.status = "walking to portal"
            local _, hrp = localCharacter()
            if hrp then
                walkTo(hrp, part.Position, MAZE_CONFIG.portalWalkRadius, MAZE_CONFIG.portalWalkTimeout, part, entrance)
            end
        end

        -- The walk can still miss when the trigger needs a fresh overlap, so
        -- poke it directly before giving up.
        local tries = 0
        while part.Parent and not portalTaken(part, entrance) and tries < 3 do
            tries = tries + 1
            MAZE.status = "forcing portal touch"
            local _, hrp = localCharacter()
            forceTouch(hrp, part)
            taskWait(0.15)
        end

        local waitUntil = os.clock() + MAZE_CONFIG.portalRetryTimeout
        while os.clock() < waitUntil do
            if portalTaken(part, entrance) or not inTrial() then
                break
            end
            taskWait(0.05)
        end

        -- Clear any lingering movement command after the portal transition.
        local _, currentRoot = localCharacter()
        local currentCharacter = currentRoot and currentRoot.Parent
        local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
        if currentHumanoid and currentRoot then
            pcall(function()
                currentHumanoid:MoveTo(currentRoot.Position)
            end)
        end

        MAZE.portalBusy = false
    end)
end

--==========================================================================
-- Step
--==========================================================================

local lastStatus = 0

local function step()
    if not MAZE.enabled then
        return
    end

    if not inTrial() then
        if MAZE.status ~= "idle" then
            MAZE.status = "idle"
            MAZE.currentEntrance = nil
        end
        return
    end

    local model = mazeModel()
    if not model then
        MAZE.status = "waiting for maze model"
        return
    end

    local path = pathOrder(builtRooms(model))
    if #path == 0 then
        MAZE.status = "waiting for first room"
        return
    end

    -- A fresh entrance instance means the portal took and a new maze is up.
    local entrance = path[1]
    if entrance.model ~= MAZE.currentEntrance then
        if MAZE.currentEntrance ~= nil then
            MAZE.mazesDone = MAZE.mazesDone + 1
            mlog("maze %d -> maze %d", MAZE.mazesDone, MAZE.mazesDone + 1)
        end
        MAZE.currentEntrance = entrance.model
        MAZE.roomsCleared = 0
    end

    MAZE.roomsCleared = math.max(0, #path - 2)

    local target = path[#path]
    if target.role == "entrance" then
        MAZE.status = "waiting for first gate"
        return
    end

    if target.role == "end" then
        walkIntoPortal(target)
        return
    end

    if MAZE.portalBusy then
        return
    end

    local spot = roomSpot(target)
    if not spot then
        MAZE.status = ("room %d has no floor"):format(target.number)
        return
    end

    local _, hrp = localCharacter()
    if not hrp then
        MAZE.status = "no character"
        return
    end

    if (hrp.Position - spot).Magnitude > MAZE_CONFIG.driftTolerance then
        seat(hrp, spot)
    end

    local now = os.clock()
    if now - lastStatus >= MAZE_CONFIG.statusInterval then
        lastStatus = now
        MAZE.status = ("room %d - %d breakable(s) left"):format(target.number, #breakablesIn(spot))
    end
end

    MAZE.enabled = AutoMazeEnabled
    MAZE.status = AutoMazeEnabled and "armed" or "idle"

    local autoMazeConnection
    autoMazeConnection = RunService.Heartbeat:Connect(function()
        MAZE.enabled = AutoMazeEnabled
        local ok, err = pcall(step)
        if not ok then
            MAZE.status = "error: " .. tostring(err)
        end

        autoMazeStatus.Text = AutoMazeEnabled
            and ("Auto Maze: " .. tostring(MAZE.status))
            or "Auto Maze: Off"
        autoMazeStatus.TextColor3 = AutoMazeEnabled
            and Color3.fromRGB(120, 220, 150)
            or Color3.fromRGB(150, 160, 180)
    end)

    registerCleanup(function()
        if autoMazeConnection and autoMazeConnection.Connected then
            autoMazeConnection:Disconnect()
        end
        MAZE.enabled = false
        MAZE.portalBusy = false
    end)
    end)()

    -- =====================================================================
    do -- Isolate Egg Chances UI locals from the larger hub builder.
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
            local numerator, denominator = text:match("(%d+)%s*/%s*([%d%,%s]+)")
            if numerator and denominator then
                denominator = tonumber((denominator:gsub("[%,%s]", "")))
                if denominator and denominator > 0 then return tonumber(numerator) / denominator end
            end
            -- BUGFIX: "1 in 50000" used to return 1 (treated as 1%). It is an
            -- odds statement, so the chance in percent is 100 / denominator.
            local inNumerator, inDenominator = text:match("(%d+)%s*in%s*([%d%,%s]+)")
            if inNumerator and inDenominator then
                inDenominator = tonumber((inDenominator:gsub("[%,%s]", "")))
                if inDenominator and inDenominator > 0 then return 100 * tonumber(inNumerator) / inDenominator end
            end
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

            -- BUGFIX (chance accuracy): the fallback tables store either raw
            -- weights (25000/5000/1), probability fractions (0.001) or real
            -- percents. formatOdds expects percent, so normalize here:
            --   all values in (0, 1]        -> fractions, scale by 100
            --   all values > 1 and integral -> weights, split by total
            local allFraction, allWeight = #results > 0, #results > 0
            for _, entry in ipairs(results) do
                local chance = entry.Chance
                if not (chance > 0 and chance <= 1) then allFraction = false end
                if not (chance > 1 and chance % 1 == 0) then allWeight = false end
            end
            if allFraction then
                for _, entry in ipairs(results) do entry.Chance = entry.Chance * 100 end
            elseif allWeight then
                local totalWeight = 0
                for _, entry in ipairs(results) do totalWeight = totalWeight + entry.Chance end
                if totalWeight > 0 then
                    for _, entry in ipairs(results) do entry.Chance = entry.Chance / totalWeight * 100 end
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
            if petInfo.gargantuan or rarity:find("gargantuan", 1, true) then return "Gargantuan" end
            if petInfo.titanic or rarity:find("titanic", 1, true) then return "Titanic" end
            -- BUGFIX (from v3): "petInfo.huge or petInfo.gargantuan" never
            -- reached the Huge branch because gargantuan returned earlier.
            if petInfo.huge or rarity:find("huge", 1, true) then return "Huge" end
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
                if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then
                    return liveEggs
                end
                local first, second = debug.getupvalue(probabilityGetter, index)
                if first == nil then break end
                consider(first)
                consider(second)
                if directory then break end
            end
            if not directory then return liveEggs end

            -- BUGFIX (from v3): egg.drops may be a STRING chaining to another
            -- egg's drop list, not a table. resolveEggDrops follows the chain.
            --
            -- BUGFIX (chance accuracy): drop[2] is a raw WEIGHT, not a percent.
            -- Showing it directly produced nonsense like "25000%" / "1/1".
            -- Weights are normalized against the egg's total weight so the
            -- displayed odds always sum to a real 100% split.
            for eggName, egg in pairs(directory.Eggs) do
                if type(egg) == "table" and egg.currency and egg.hatchable ~= false then
                    local drops = resolveEggDrops(directory.Eggs, egg)
                    if type(drops) == "table" then
                        local label = tostring(egg.displayName or egg._id or eggName)
                        local lowerLabel = label:lower()
                        if not egg.isExclusive and not egg.isGift and not egg.isPremium and not lowerLabel:find("exclusive", 1, true) then
                            -- GetProbabilityMap can't be trusted blindly: its
                            -- values may be fractions (0.0001), "1 in N" odds
                            -- (10000) or percents, and guessing the unit wrong
                            -- skews every row by 100x. Weights from the
                            -- directory are deterministic, so they are the
                            -- source of truth; the map is only consulted for
                            -- pets whose weight is missing or zero.
                            local probabilityMap = probabilityGetter(eggName)
                            local mappedFraction = {}
                            if type(probabilityMap) == "table" then
                                for petId, value in pairs(probabilityMap) do
                                    local number = tonumber(value)
                                    if number and number > 0 and number <= 1 then
                                        mappedFraction[petId] = number
                                    end
                                end
                            end

                            local totalWeight = 0
                            for _, drop in ipairs(drops) do
                                if type(drop) == "table" and type(drop[1]) == "string" and tonumber(drop[2]) then
                                    totalWeight = totalWeight + tonumber(drop[2])
                                end
                            end

                            local pets = {}
                            for _, drop in ipairs(drops) do
                                if type(drop) == "table" and type(drop[1]) == "string" then
                                    local weight = tonumber(drop[2])
                                    local chance
                                    if weight and weight > 0 and totalWeight > 0 then
                                        chance = weight / totalWeight * 100
                                    else
                                        local fraction = mappedFraction[drop[1]]
                                        if fraction then chance = fraction * 100 end
                                    end
                                    if chance and chance > 0 then
                                        table.insert(pets, { Name = drop[1], Chance = chance, Category = classifyPet(directory.Pets[drop[1]]) })
                                    end
                                end
                            end
                            if #pets > 0 then table.insert(liveEggs, { Name = label, Pets = pets }) end
                        end
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

    do
        local eggSearchCorner = Instance.new("UICorner")
        eggSearchCorner.CornerRadius = UDim.new(0, 6)
        eggSearchCorner.Parent = eggSearch
    end

    do
        local eggSearchStroke = Instance.new("UIStroke")
        eggSearchStroke.Color = Color3.fromRGB(80, 80, 100)
        eggSearchStroke.Thickness = 1
        eggSearchStroke.Transparency = 0.7
        eggSearchStroke.Parent = eggSearch
    end

    local eggSelect = Instance.new("TextButton")
    eggSelect.Size = UDim2.new(1, 0, 0, 32)
    eggSelect.Position = UDim2.new(0, 0, 0, 78)
    eggSelect.BackgroundColor3 = Color3.fromRGB(35, 35, 48)
    eggSelect.TextColor3 = Color3.fromRGB(255, 255, 255)
    eggSelect.Font = Enum.Font.GothamBold
    eggSelect.TextSize = 13
    eggSelect.Text = "Select Egg Dropdown"
    eggSelect.Parent = eggFrame

    do
        local eggSelectCorner = Instance.new("UICorner")
        eggSelectCorner.CornerRadius = UDim.new(0, 6)
        eggSelectCorner.Parent = eggSelect
    end

    do
        local eggSelectStroke = Instance.new("UIStroke")
        eggSelectStroke.Color = Color3.fromRGB(80, 80, 100)
        eggSelectStroke.Thickness = 1
        eggSelectStroke.Transparency = 0.7
        eggSelectStroke.Parent = eggSelect
    end

    local eggOptions = Instance.new("ScrollingFrame")
    eggOptions.Size = UDim2.new(1, 0, 0, 140)
    eggOptions.Position = UDim2.new(0, 0, 0, 116)
    eggOptions.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
    eggOptions.BorderSizePixel = 0
    eggOptions.ScrollBarThickness = 5
    eggOptions.AutomaticCanvasSize = Enum.AutomaticSize.Y
    eggOptions.Visible = false
    eggOptions.ZIndex = 20
    eggOptions.Parent = eggFrame

    do
        local eggOptionsCorner = Instance.new("UICorner")
        eggOptionsCorner.CornerRadius = UDim.new(0, 6)
        eggOptionsCorner.Parent = eggOptions
    end

    do
        local eggOptionsStroke = Instance.new("UIStroke")
        eggOptionsStroke.Color = Color3.fromRGB(80, 80, 100)
        eggOptionsStroke.Thickness = 1
        eggOptionsStroke.Transparency = 0.6
        eggOptionsStroke.Parent = eggOptions
    end

    do
        local eggOptionsLayout = Instance.new("UIListLayout")
        eggOptionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
        eggOptionsLayout.Padding = UDim.new(0, 2)
        eggOptionsLayout.Parent = eggOptions
    end

    local eggResults = Instance.new("ScrollingFrame")
    eggResults.Name = "EggResults"
    eggResults.Size = UDim2.new(1, 0, 1, -262)
    eggResults.Position = UDim2.new(0, 0, 0, 262)
    eggResults.BackgroundColor3 = Color3.fromRGB(16, 17, 22)
    eggResults.BorderSizePixel = 0
    eggResults.AutomaticCanvasSize = Enum.AutomaticSize.Y
    eggResults.ScrollBarThickness = 5
    eggResults.Parent = eggFrame

    do
        local eggResultsCorner = Instance.new("UICorner")
        eggResultsCorner.CornerRadius = UDim.new(0, 8)
        eggResultsCorner.Parent = eggResults
    end

    do
        local eggResultsLayout = Instance.new("UIListLayout")
        eggResultsLayout.Padding = UDim.new(0, 4)
        eggResultsLayout.Parent = eggResults
    end

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
            index = index + 1
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

        do
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
        end

        local rarityName = category or "Normal"
        do
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
        end

        do
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

            do
                local bestCorner = Instance.new("UICorner")
                bestCorner.CornerRadius = UDim.new(0, 4)
                bestCorner.Parent = bestOption
            end

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
                    eggOptions.Visible = false
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
            eggOptions.Visible = false
            eggResults.Position = UDim2.new(0, 0, 0, 116)
            eggResults.Size = UDim2.new(1, 0, 1, -116)
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
            if eggOptions.Visible then
                eggResults.Position = UDim2.new(0, 0, 0, 262)
                eggResults.Size = UDim2.new(1, 0, 1, -262)
            else
                eggResults.Position = UDim2.new(0, 0, 0, 116)
                eggResults.Size = UDim2.new(1, 0, 1, -116)
            end
        end
    end)

    eggSearch:GetPropertyChangedSignal("Text"):Connect(function()
        rebuildEggOptions()
        eggOptions.Visible = (chanceMode == "Eggs")
    end)

    rebuildEggOptions()
    eggSelect.Text = bestChanceEgg and ("Selected: " .. bestChanceEgg.Name) or "Select an egg"
    selectEggSubTab("Eggs", subTabButtons["Eggs"])
    end -- End Egg Chances local scope.


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
    statsContainer.Size = UDim2.new(1, -6, 0, 232)
    statsContainer.Position = UDim2.new(0, 3, 0, 8)
    statsContainer.BackgroundColor3 = Color3.fromRGB(22, 24, 33)
    statsContainer.Parent = hatchFrame

    do
        local statsCorner = Instance.new("UICorner")
        statsCorner.CornerRadius = UDim.new(0, 14)
        statsCorner.Parent = statsContainer
    end

    do
        local statsStroke = Instance.new("UIStroke")
        statsStroke.Color = activeTheme.stroke
        statsStroke.Transparency = 0.55
        statsStroke.Parent = statsContainer
    end

    do
        local statsTitle = Instance.new("TextLabel")
        statsTitle.Size = UDim2.new(1, -140, 0, 16)
        statsTitle.Position = UDim2.new(0, 14, 0, 10)
        statsTitle.BackgroundTransparency = 1
        statsTitle.Text = "SESSION STATS"
        statsTitle.TextColor3 = Color3.fromRGB(150, 160, 182)
        statsTitle.Font = Enum.Font.GothamBold
        statsTitle.TextSize = 10
        statsTitle.TextXAlignment = Enum.TextXAlignment.Left
        statsTitle.Parent = statsContainer
    end

    do
        local statsHint = Instance.new("TextLabel")
        statsHint.Size = UDim2.new(0, 128, 0, 16)
        statsHint.Position = UDim2.new(1, -142, 0, 10)
        statsHint.BackgroundTransparency = 1
        statsHint.Text = "live from save data"
        statsHint.TextColor3 = Color3.fromRGB(110, 120, 140)
        statsHint.Font = Enum.Font.Gotham
        statsHint.TextSize = 10
        statsHint.TextXAlignment = Enum.TextXAlignment.Right
        statsHint.Parent = statsContainer
    end

    local EggsLabel = Instance.new("TextLabel")
    EggsLabel.Size = UDim2.new(0.5, -19, 0, 46)
    EggsLabel.Position = UDim2.new(0, 14, 0, 32)
    EggsLabel.Text = "Eggs: 0"
    EggsLabel.TextColor3 = Color3.fromRGB(80, 230, 80)
    EggsLabel.BackgroundColor3 = Color3.fromRGB(29, 32, 44)
    EggsLabel.Font = Enum.Font.GothamBold
    EggsLabel.TextSize = 15
    EggsLabel.TextXAlignment = Enum.TextXAlignment.Left
    EggsLabel.TextYAlignment = Enum.TextYAlignment.Center
    EggsLabel.Parent = statsContainer

    local GemsLabel = Instance.new("TextLabel")
    GemsLabel.Size = UDim2.new(0.5, -19, 0, 46)
    GemsLabel.Position = UDim2.new(0.5, 5, 0, 32)
    GemsLabel.Text = "Diamonds: 0"
    GemsLabel.TextColor3 = Color3.fromRGB(110, 185, 255)
    GemsLabel.BackgroundColor3 = Color3.fromRGB(29, 32, 44)
    GemsLabel.Font = Enum.Font.GothamBold
    GemsLabel.TextSize = 15
    GemsLabel.TextXAlignment = Enum.TextXAlignment.Left
    GemsLabel.TextYAlignment = Enum.TextYAlignment.Center
    GemsLabel.Parent = statsContainer

    -- These Hatch-tab counters keep their fixed colors in every theme.
    local hatchEggsGreen = Color3.fromRGB(80, 230, 80)
    local hatchDiamondsBlue = Color3.fromRGB(110, 185, 255)
    EggsLabel.TextColor3 = hatchEggsGreen
    GemsLabel.TextColor3 = hatchDiamondsBlue
    EggsLabel:SetAttribute("ThemeKeepTextColor", true)
    GemsLabel:SetAttribute("ThemeKeepTextColor", true)

    do
        local function cardify(label)
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 10)
            corner.Parent = label

            local padding = Instance.new("UIPadding")
            padding.PaddingLeft = UDim.new(0, 12)
            padding.PaddingRight = UDim.new(0, 8)
            padding.Parent = label

            local stroke = Instance.new("UIStroke")
            stroke.Color = activeTheme.stroke
            stroke.Transparency = 0.35
            stroke.Parent = label
        end

        cardify(EggsLabel)
        cardify(GemsLabel)
    end

    local function makeHatchRareLabel(name, position)
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0.25, -10, 0, 30)
        label.Position = UDim2.new(position, 5, 0, 88)
        label.Text = name .. ": 0"
        label.TextColor3 = Color3.fromRGB(255, 210, 80)
        label.BackgroundColor3 = Color3.fromRGB(27, 30, 41)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 12
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.Parent = statsContainer
        hatchRareLabels[name] = label

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 8)
        corner.Parent = label

        local padding = Instance.new("UIPadding")
        padding.PaddingLeft = UDim.new(0, 10)
        padding.Parent = label
    end

    makeHatchRareLabel("Huges", 0)
    makeHatchRareLabel("Secrets", 0.25)
    makeHatchRareLabel("Titanics", 0.5)
    makeHatchRareLabel("Gargantuans", 0.75)

    do
        local divider = Instance.new("Frame")
        divider.Size = UDim2.new(1, -28, 0, 1)
        divider.Position = UDim2.new(0, 14, 0, 126)
        divider.BackgroundColor3 = activeTheme.stroke
        divider.BackgroundTransparency = 0.5
        divider.BorderSizePixel = 0
        divider.Parent = statsContainer
    end

    -- Variant tallies fill the lower half of the stats card and give the
    -- session an at-a-glance read on how many rares came out Rainbow /
    -- Golden / Shiny. Counted in renderHatchRecent so they stay in sync
    -- with the recent list instead of drifting from it.
    do
        do
            local variantsTitle = Instance.new("TextLabel")
            variantsTitle.Size = UDim2.new(1, -28, 0, 12)
            variantsTitle.Position = UDim2.new(0, 14, 0, 140)
            variantsTitle.BackgroundTransparency = 1
            variantsTitle.Text = "VARIANTS OWNED"
            variantsTitle.TextColor3 = Color3.fromRGB(150, 160, 182)
            variantsTitle.Font = Enum.Font.GothamBold
            variantsTitle.TextSize = 10
            variantsTitle.TextXAlignment = Enum.TextXAlignment.Left
            variantsTitle.Parent = statsContainer
        end

        local variantDefs = {
            { key = "Rainbow", label = "RAINBOW", color = Color3.fromRGB(255, 120, 220) },
            { key = "Golden", label = "GOLDEN", color = Color3.fromRGB(255, 200, 70) },
            { key = "Shiny", label = "SHINY", color = Color3.fromRGB(120, 220, 255) },
        }

        for index, def in ipairs(variantDefs) do
            local chip = Instance.new("TextLabel")
            chip.Name = def.key .. "Chip"
            chip.Size = UDim2.new(1 / 3, -12, 0, 40)
            chip.Position = UDim2.new((index - 1) / 3, 8, 0, 158)
            chip.BackgroundColor3 = Color3.fromRGB(27, 30, 41)
            chip.Text = def.label .. "  0"
            chip.TextColor3 = def.color
            chip.Font = Enum.Font.GothamBold
            chip.TextSize = 11
            chip.TextXAlignment = Enum.TextXAlignment.Left
            chip.TextYAlignment = Enum.TextYAlignment.Center
            chip.Parent = statsContainer

            local chipCorner = Instance.new("UICorner")
            chipCorner.CornerRadius = UDim.new(0, 9)
            chipCorner.Parent = chip

            local chipPadding = Instance.new("UIPadding")
            chipPadding.PaddingLeft = UDim.new(0, 12)
            chipPadding.Parent = chip

            local chipStroke = Instance.new("UIStroke")
            chipStroke.Color = def.color
            chipStroke.Transparency = 0.82
            chipStroke.Parent = chip

            hatchVariantLabels[def.key] = { label = chip, prefix = def.label }
        end

        updateHatchVariantOwned = function()
            local ownedVariants = { Rainbow = 0, Golden = 0, Shiny = 0 }
            pcall(function()
                if Save and Save.Get then
                    local save = Save.Get()
                    local pets = save and save.Pets
                    if type(pets) == "table" then
                        for _, pet in pairs(pets) do
                            if type(pet) == "table" then
                                if pet.r == true then ownedVariants.Rainbow = ownedVariants.Rainbow + 1 end
                                if pet.g == true then ownedVariants.Golden = ownedVariants.Golden + 1 end
                                if pet.sh == true then ownedVariants.Shiny = ownedVariants.Shiny + 1 end
                            end
                        end
                    end
                end
            end)
            for key, data in pairs(hatchVariantLabels) do
                if data.label and data.label.Parent then
                    data.label.Text = data.prefix .. "  " .. tostring(ownedVariants[key] or 0)
                end
            end
        end
        pcall(updateHatchVariantOwned)
    end

    -- Egg selection UI removed - auto-hatch uses closest egg automatically
    -- The hatch frame now starts at y=242 instead of y=340 to fill the gap

    local ToggleKey = Enum.KeyCode[CurrentKeyName] or Enum.KeyCode.LeftControl

    updateAfkSessionLabels = function()
        local sessionLabels = {
            Huges = afkSessionLabels.Huges,
            Secrets = afkSessionLabels.Secrets,
            Titanics = afkSessionLabels.Titanics,
            Gargantuans = afkSessionLabels.Gargantuans,
        }
        local sessionVariantLabels = {
            Huges = afkSessionVariantLabels.Huges,
            Secrets = afkSessionVariantLabels.Secrets,
            Titanics = afkSessionVariantLabels.Titanics,
            Gargantuans = afkSessionVariantLabels.Gargantuans,
        }
        local startupLabelSet = {
            Huges = startupLabels.Huges,
            Secrets = startupLabels.Secrets,
            Titanics = startupLabels.Titanics,
            Gargantuans = startupLabels.Gargantuans,
        }

        for key, label in pairs(sessionLabels) do
            if label then
                label.Text = "+" .. tostring(afkSessionCounts[key] or 0) .. " this session"
            end
        end
        for key, label in pairs(sessionVariantLabels) do
            if label then
                local variants = afkSessionVariants[key] or {}
                label.Text = ("R %d   G %d   S %d"):format(
                    tonumber(variants.R) or 0,
                    tonumber(variants.G) or 0,
                    tonumber(variants.S) or 0
                )
            end
        end
        for key, label in pairs(startupLabelSet) do
            if label then
                label.Text = "+" .. tostring(startupCounts[key] or 0) .. " since launch"
            end
        end
    end

    local function resetAfkSessionCounts()
        afkSessionCounts.Huges = 0
        afkSessionCounts.Secrets = 0
        afkSessionCounts.Titanics = 0
        afkSessionCounts.Gargantuans = 0
        for _, variants in pairs(afkSessionVariants) do
            variants.R = 0
            variants.G = 0
            variants.S = 0
        end
        updateAfkSessionLabels()
    end

    local afkToggleBtn = nil

    local function updateAfkToggleVisual(enabled)
        if not afkToggleBtn or not afkToggleBtn.Parent then return end
        enabled = enabled == true
        afkToggleBtn:SetAttribute("ToggleState", enabled)
        afkToggleBtn.BackgroundColor3 = enabled and activeTheme.controlOn or activeTheme.surface
        afkToggleBtn.Text = "AFK Mode: " .. (enabled and "ON" or "OFF")
        afkToggleBtn.TextColor3 = activeTheme.text
    end

    local function setAfkMode(enabled)
        enabled = enabled == true
        pcall(function()
            afkSessionActive = enabled
            CurrentToggleStates["AFK Mode"] = enabled
            updateAfkToggleVisual(enabled)
            saveSettings()
            resetAfkSessionCounts()

            if enabled then
                afkGui.Enabled = true
                afkOverlay.Visible = true
                autoHatchMain.Visible = false
                afkStartSession()
                -- Render recent rare hatches immediately so the AFK panel
                -- shows hatches from before the session started, not just
                -- ones that hatch while AFK is active.
                pcall(renderAfkRecent)
            else
                afkOverlay.Visible = false
                afkGui.Enabled = false
                autoHatchMain.Visible = true
            end
        end)
    end

    -- CONTROL SECTION --------------------------------------------------------
    local controlPanel = Instance.new("Frame")
    controlPanel.Name = "ControlPanel"
    controlPanel.Size = UDim2.new(1, -6, 0, 90)
    controlPanel.Position = UDim2.new(0, 3, 0, 250)
    controlPanel.BackgroundColor3 = activeTheme.panel
    controlPanel.BorderSizePixel = 0
    controlPanel.Parent = hatchFrame

    do
        local controlCorner = Instance.new("UICorner")
        controlCorner.CornerRadius = UDim.new(0, 12)
        controlCorner.Parent = controlPanel
    end

    do
        local controlStroke = Instance.new("UIStroke")
        controlStroke.Color = activeTheme.stroke
        controlStroke.Transparency = 0.4
        controlStroke.Parent = controlPanel
    end

    do
        local controlTitle = Instance.new("TextLabel")
        controlTitle.Size = UDim2.new(1, -24, 0, 20)
        controlTitle.Position = UDim2.new(0, 12, 0, 8)
        controlTitle.BackgroundTransparency = 1
        controlTitle.Text = "CONTROLS"
        controlTitle.TextColor3 = Color3.fromRGB(167, 139, 250)
        controlTitle.Font = Enum.Font.GothamBold
        controlTitle.TextSize = 11
        controlTitle.TextXAlignment = Enum.TextXAlignment.Left
        controlTitle.Parent = controlPanel
    end

    -- Create AFK Mode toggle inside control panel
    afkToggleBtn = Instance.new("TextButton")
    afkToggleBtn.Size = UDim2.new(0.5, -8, 0, 34)
    afkToggleBtn.Position = UDim2.new(0, 8, 0, 36)
    afkToggleBtn.BackgroundColor3 = Color3.fromRGB(67, 104, 145)
    afkToggleBtn.Text = "AFK Mode: OFF"
    afkToggleBtn:SetAttribute("ToggleState", false)
    afkToggleBtn:SetAttribute("ThemeRole", "Toggle")
    afkToggleBtn.TextColor3 = activeTheme.text
    afkToggleBtn.Font = Enum.Font.GothamBold
    afkToggleBtn.TextSize = 13
    afkToggleBtn.Parent = controlPanel

    do
        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 6)
        btnCorner.Parent = afkToggleBtn
    end

    do
        local btnStroke = Instance.new("UIStroke")
        btnStroke.Color = activeTheme.stroke
        btnStroke.Thickness = 1
        btnStroke.Transparency = 0.7
        btnStroke.Parent = afkToggleBtn
    end

    afkToggleBtn.MouseButton1Click:Connect(function()
        setAfkMode(not afkSessionActive)
    end)

    -- Create Auto-Hatch Egg toggle inside control panel
    local hatchToggleBtn = Instance.new("TextButton")
    hatchToggleBtn.Size = UDim2.new(0.5, -8, 0, 34)
    hatchToggleBtn.Position = UDim2.new(0.5, 0, 0, 36)
    hatchToggleBtn.BackgroundColor3 = Color3.fromRGB(67, 104, 145)
    hatchToggleBtn.Text = "Auto-Hatch Egg: OFF"
    hatchToggleBtn:SetAttribute("ToggleState", false)
    hatchToggleBtn:SetAttribute("ThemeRole", "Toggle")
    hatchToggleBtn.TextColor3 = activeTheme.text
    hatchToggleBtn.Font = Enum.Font.GothamBold
    hatchToggleBtn.TextSize = 13
    hatchToggleBtn.Parent = controlPanel

    do
        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 6)
        btnCorner.Parent = hatchToggleBtn
    end

    do
        local btnStroke = Instance.new("UIStroke")
        btnStroke.Color = activeTheme.stroke
        btnStroke.Thickness = 1
        btnStroke.Transparency = 0.7
        btnStroke.Parent = hatchToggleBtn
    end

    hatchToggleBtn.MouseButton1Click:Connect(function()
        -- setAutoHatchState is assigned later in the load sequence; guard the
        -- callback so an early click cannot call a nil value.
        if type(setAutoHatchState) == "function" then
            pcall(setAutoHatchState, not AutoBuying)
        end
    end)

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
    recentPanel.Size = UDim2.new(1, -6, 0, 194)
    recentPanel.Position = UDim2.new(0, 3, 0, 350)
    recentPanel.BackgroundColor3 = activeTheme.panel
    recentPanel.BorderSizePixel = 0
    recentPanel.Parent = hatchFrame

    do
        local recentPanelCorner = Instance.new("UICorner")
        recentPanelCorner.CornerRadius = UDim.new(0, 12)
        recentPanelCorner.Parent = recentPanel
    end

    do
        local recentPanelStroke = Instance.new("UIStroke")
        recentPanelStroke.Color = activeTheme.stroke
        recentPanelStroke.Transparency = 0.4
        recentPanelStroke.Parent = recentPanel
    end

    local recentDot = Instance.new("Frame")
    recentDot.Size = UDim2.new(0, 6, 0, 6)
    recentDot.Position = UDim2.new(0, 12, 0, 12)
    recentDot.BackgroundColor3 = Color3.fromRGB(167, 139, 250)
    recentDot.BorderSizePixel = 0
    recentDot.Parent = recentPanel

    do
        local recentDotCorner = Instance.new("UICorner")
        recentDotCorner.CornerRadius = UDim.new(1, 0)
        recentDotCorner.Parent = recentDot
    end

    do
        local recentTitle = Instance.new("TextLabel")
        recentTitle.Size = UDim2.new(1, -110, 0, 22)
        recentTitle.Position = UDim2.new(0, 24, 0, 4)
        recentTitle.BackgroundTransparency = 1
        recentTitle.Text = "RECENT RARE HATCHES"
        recentTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
        recentTitle.Font = Enum.Font.GothamBold
        recentTitle.TextSize = 12
        recentTitle.TextXAlignment = Enum.TextXAlignment.Left
        recentTitle.Parent = recentPanel
    end

    do
        local recentHint = Instance.new("TextLabel")
        recentHint.Size = UDim2.new(0, 80, 0, 22)
        recentHint.Position = UDim2.new(1, -88, 0, 4)
        recentHint.BackgroundTransparency = 1
        recentHint.Text = "live"
        recentHint.TextColor3 = Color3.fromRGB(132, 142, 165)
        recentHint.Font = Enum.Font.Gotham
        recentHint.TextSize = 11
        recentHint.TextXAlignment = Enum.TextXAlignment.Right
        recentHint.Parent = recentPanel
    end
    for index, category in ipairs(recentCategories) do
        local column = Instance.new("Frame")
        column.Size = UDim2.new(0.25, -8, 0, 102)
        column.Position = UDim2.new((index - 1) * 0.25, 4, 0, 36)
        column.BackgroundColor3 = activeTheme.surface
        column.BackgroundTransparency = 0.45
        column.BorderSizePixel = 0
        column.Parent = recentPanel

        do
            local columnCorner = Instance.new("UICorner")
            columnCorner.CornerRadius = UDim.new(0, 9)
            columnCorner.Parent = column
        end

        local columnDot = Instance.new("Frame")
        columnDot.Size = UDim2.new(0, 5, 0, 5)
        columnDot.Position = UDim2.new(0, 8, 0, 8)
        columnDot.BackgroundColor3 = category.color
        columnDot.BorderSizePixel = 0
        columnDot.Parent = column

        do
            local columnDotCorner = Instance.new("UICorner")
            columnDotCorner.CornerRadius = UDim.new(1, 0)
            columnDotCorner.Parent = columnDot
        end

        local header = Instance.new("TextLabel")
        header.Size = UDim2.new(1, -20, 0, 18)
        header.Position = UDim2.new(0, 17, 0, 1)
        header.BackgroundTransparency = 1
        header.Text = category.name:upper()
        header.TextColor3 = category.color
        header.Font = Enum.Font.GothamBold
        header.TextSize = 10
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.Parent = column

        local list = Instance.new("ScrollingFrame")
        list.Size = UDim2.new(1, -8, 1, -24)
        list.Position = UDim2.new(0, 4, 0, 20)
        list.BackgroundTransparency = 1
        list.BorderSizePixel = 0
        list.ScrollBarThickness = 2
        list.CanvasSize = UDim2.new(0, 0, 0, 0)
        list.AutomaticCanvasSize = Enum.AutomaticSize.Y
        list.Parent = column

        local listPadding = Instance.new("UIPadding")
        listPadding.PaddingLeft = UDim.new(0, 4)
        listPadding.PaddingRight = UDim.new(0, 2)
        listPadding.Parent = list

        local listLayout = Instance.new("UIListLayout")
        listLayout.SortOrder = Enum.SortOrder.LayoutOrder
        listLayout.Padding = UDim.new(0, 2)
        listLayout.Parent = list

        hatchRecentLists[category.name] = { frame = list, entries = category.entries, color = category.color }
    end

    -- Moved variants hatched under recent hatches
    local recentHatchedSection = Instance.new("Frame")
    recentHatchedSection.Name = "RecentHatchedVariants"
    recentHatchedSection.Size = UDim2.new(1, -8, 0, 44)
    recentHatchedSection.Position = UDim2.new(0, 4, 0, 144)
    recentHatchedSection.BackgroundTransparency = 1
    recentHatchedSection.Parent = recentPanel

    do
        local recentHatchedTitle = Instance.new("TextLabel")
        recentHatchedTitle.Size = UDim2.new(1, 0, 0, 12)
        recentHatchedTitle.Position = UDim2.new(0, 4, 0, 0)
        recentHatchedTitle.BackgroundTransparency = 1
        recentHatchedTitle.Text = "VARIANTS HATCHED (RECENT)"
        recentHatchedTitle.TextColor3 = Color3.fromRGB(150, 160, 182)
        recentHatchedTitle.Font = Enum.Font.GothamBold
        recentHatchedTitle.TextSize = 9
        recentHatchedTitle.TextXAlignment = Enum.TextXAlignment.Left
        recentHatchedTitle.Parent = recentHatchedSection
    end

    local recentHatchChips = {}
    local recentVariantDefs = {
        { key = "Rainbow", label = "RAINBOW", color = Color3.fromRGB(255, 120, 220) },
        { key = "Golden", label = "GOLDEN", color = Color3.fromRGB(255, 200, 70) },
        { key = "Shiny", label = "SHINY", color = Color3.fromRGB(120, 220, 255) },
    }

    for index, def in ipairs(recentVariantDefs) do
        local chip = Instance.new("TextLabel")
        chip.Name = def.key .. "HatchedChip"
        chip.Size = UDim2.new(1 / 3, -8, 0, 26)
        chip.Position = UDim2.new((index - 1) / 3, 4, 0, 14)
        chip.BackgroundColor3 = Color3.fromRGB(27, 30, 41)
        chip.Text = def.label .. "  0"
        chip.TextColor3 = def.color
        chip.Font = Enum.Font.GothamBold
        chip.TextSize = 10
        chip.TextXAlignment = Enum.TextXAlignment.Left
        chip.TextYAlignment = Enum.TextYAlignment.Center
        chip.Parent = recentHatchedSection

        local chipCorner = Instance.new("UICorner")
        chipCorner.CornerRadius = UDim.new(0, 6)
        chipCorner.Parent = chip

        do
            local chipPadding = Instance.new("UIPadding")
            chipPadding.PaddingLeft = UDim.new(0, 8)
            chipPadding.Parent = chip
        end

        local chipStroke = Instance.new("UIStroke")
        chipStroke.Color = def.color
        chipStroke.Transparency = 0.82
        chipStroke.Parent = chip

        recentHatchChips[def.key] = { label = chip, prefix = def.label }
    end

    renderHatchRecent = function()
        local variantTotals = { Rainbow = 0, Golden = 0, Shiny = 0 }
        for _, category in ipairs(recentCategories) do
            local listData = hatchRecentLists[category.name]
            if listData then
                for _, child in ipairs(listData.frame:GetChildren()) do
                    if child:IsA("TextLabel") then child:Destroy() end
                end
                for entryIndex, entryData in ipairs(listData.entries) do
                    local label = Instance.new("TextLabel")
                    label.Size = UDim2.new(1, 0, 0, 18)
                    label.BackgroundTransparency = 1
                    local variants = {}
                    if entryData.rainbow then
                        table.insert(variants, "Rainbow")
                        variantTotals.Rainbow = variantTotals.Rainbow + 1
                    end
                    if entryData.golden then
                        table.insert(variants, "Golden")
                        variantTotals.Golden = variantTotals.Golden + 1
                    end
                    if entryData.shiny then
                        table.insert(variants, "Shiny")
                        variantTotals.Shiny = variantTotals.Shiny + 1
                    end
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
                    label.TextSize = 11
                    label.TextTruncate = Enum.TextTruncate.AtEnd
                    label.TextXAlignment = Enum.TextXAlignment.Left
                    label.LayoutOrder = entryIndex
                    label.Parent = listData.frame
                end
            end
        end

        for key, data in pairs(recentHatchChips) do
            if data.label and data.label.Parent then
                data.label.Text = data.prefix .. "  " .. tostring(variantTotals[key] or 0)
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
        local WebhookAccountName = (localPlayer and (localPlayer.Name or localPlayer.DisplayName)) or "Unknown"
        local WebhookSummaryEnabled = PersistedSettings.webhook.summaryEnabled == true
        local WebhookSummaryMinutes = math.clamp(tonumber(PersistedSettings.webhook.summaryMinutes) or 30, 1, 1440)
        local WebhookSummaryLastSent = os.clock()
        local WebhookUserId = PersistedSettings.webhook.userId or ""

        local function webhookRequest()
            local env = getExecutorEnv()
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
        webhookPanel.Size = UDim2.new(1, -6, 0, 344)
        webhookPanel.Position = UDim2.new(0, 3, 0, 548)
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
        do
            local boxCorner = Instance.new("UICorner")
            boxCorner.CornerRadius = UDim.new(0, 6)
            boxCorner.Parent = box
        end

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
        enable.BackgroundColor3 = Color3.fromRGB(67, 104, 145)
        enable:SetAttribute("ThemeRole", "Toggle")
        enable:SetAttribute("ToggleState", WebhookEnabled == true)
        enable.BorderSizePixel = 0
        enable.Text = "Webhook: OFF"
        enable.TextColor3 = Color3.fromRGB(255,255,255)
        enable.Font = Enum.Font.GothamBold
        enable.TextSize = 11
        enable.Parent = webhookPanel
        do
            local enableCorner = Instance.new("UICorner")
            enableCorner.CornerRadius = UDim.new(0, 6)
            enableCorner.Parent = enable
        end

        local function updateEnable()
            if WebhookEnabled then
                enable.Text = "Webhook: ON"
                enable:SetAttribute("ToggleState", true)
                enable.BackgroundColor3 = activeTheme.controlOn
                status.Text = "Webhook is ON"
            else
                enable.Text = "Webhook: OFF"
                enable:SetAttribute("ToggleState", false)
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
            b.BackgroundColor3 = WebhookNotify[key] and Color3.fromRGB(20, 190, 126) or Color3.fromRGB(67, 104, 145)
            b:SetAttribute("ThemeRole", "Toggle")
            b:SetAttribute("ToggleState", WebhookNotify[key] == true)
            b.BorderSizePixel = 0
            b.Font = Enum.Font.GothamSemibold
            b.TextSize = 10
            b.TextColor3 = Color3.fromRGB(255,255,255)
            b.Parent = webhookPanel
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0,6)
            c.Parent = b
            local function redraw()
                b:SetAttribute("ToggleState", WebhookNotify[key] == true)
                b.Text = (WebhookNotify[key] and "ON  -  " or "OFF -  ") .. labelText
                b.BackgroundColor3 = WebhookNotify[key] and activeTheme.controlOn or activeTheme.surface
                b.TextColor3 = activeTheme.text
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
        addToggle("Secrets", "Secret", 0.5, 136)
        addToggle("Titanics", "Titanic", 0, 168)
        addToggle("Gargantuans", "Gargantuan", 0.5, 168)

        -- User ID input
        do
            local userIdLabel = Instance.new("TextLabel")
            userIdLabel.Size = UDim2.new(1, -24, 0, 18)
            userIdLabel.Position = UDim2.new(0, 12, 0, 200)
            userIdLabel.BackgroundTransparency = 1
            userIdLabel.Text = "Your Discord User ID (for pings):"
            userIdLabel.TextColor3 = activeTheme.muted
            userIdLabel.Font = Enum.Font.Gotham
            userIdLabel.TextSize = 10
            userIdLabel.TextXAlignment = Enum.TextXAlignment.Left
            userIdLabel.Parent = webhookPanel
        end

        local userIdBox = Instance.new("TextBox")
        userIdBox.Size = UDim2.new(1, -24, 0, 30)
        userIdBox.Position = UDim2.new(0, 12, 0, 220)
        userIdBox.BackgroundColor3 = activeTheme.surface
        userIdBox.BorderSizePixel = 0
        userIdBox.ClearTextOnFocus = false
        userIdBox.PlaceholderText = "123456789012345678"
        userIdBox.Text = WebhookUserId
        userIdBox.TextColor3 = Color3.fromRGB(255,255,255)
        userIdBox.Font = Enum.Font.Gotham
        userIdBox.TextSize = 11
        userIdBox.Parent = webhookPanel
        do
            local userIdCorner = Instance.new("UICorner")
            userIdCorner.CornerRadius = UDim.new(0, 6)
            userIdCorner.Parent = userIdBox
        end

        userIdBox.FocusLost:Connect(function()
            WebhookUserId = tostring(userIdBox.Text or ""):match("^%s*(.-)%s*$")
            PersistedSettings.webhook.userId = WebhookUserId
            PersistedSettings.webhook.url = WebhookURL
            PersistedSettings.webhook.enabled = WebhookEnabled
            PersistedSettings.webhook.notify = WebhookNotify
            saveSettings()
        end)

        local summaryToggle = Instance.new("TextButton")
        summaryToggle.Size = UDim2.new(0.54, -12, 0, 26)
        summaryToggle.Position = UDim2.new(0, 12, 0, 262)
        summaryToggle.BackgroundColor3 = Color3.fromRGB(67, 104, 145)
        summaryToggle:SetAttribute("ThemeRole", "Toggle")
        summaryToggle:SetAttribute("ToggleState", WebhookSummaryEnabled == true)
        summaryToggle.BorderSizePixel = 0
        summaryToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
        summaryToggle.Font = Enum.Font.GothamSemibold
        summaryToggle.TextSize = 10
        summaryToggle.Parent = webhookPanel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = summaryToggle
        end

        local summaryBox = Instance.new("TextBox")
        summaryBox.Size = UDim2.new(0.16, 0, 0, 26)
        summaryBox.Position = UDim2.new(0.56, 0, 0, 262)
        summaryBox.BackgroundColor3 = activeTheme.surface
        summaryBox.BorderSizePixel = 0
        summaryBox.ClearTextOnFocus = false
        summaryBox.Text = tostring(WebhookSummaryMinutes)
        summaryBox.PlaceholderText = "Min"
        summaryBox.TextColor3 = Color3.fromRGB(255, 255, 255)
        summaryBox.Font = Enum.Font.GothamBold
        summaryBox.TextSize = 11
        summaryBox.Parent = webhookPanel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = summaryBox
        end

        do
            local summarySuffix = Instance.new("TextLabel")
            summarySuffix.Size = UDim2.new(0.23, -6, 0, 26)
            summarySuffix.Position = UDim2.new(0.74, 0, 0, 262)
            summarySuffix.BackgroundTransparency = 1
            summarySuffix.Text = "minutes"
            summarySuffix.TextColor3 = activeTheme.muted
            summarySuffix.Font = Enum.Font.Gotham
            summarySuffix.TextSize = 10
            summarySuffix.TextXAlignment = Enum.TextXAlignment.Left
            summarySuffix.Parent = webhookPanel
        end

        local function updateSummary()
            summaryToggle:SetAttribute("ToggleState", WebhookSummaryEnabled == true)
            summaryToggle.Text = WebhookSummaryEnabled and "Summary every: ON" or "Summary every: OFF"
            summaryToggle.BackgroundColor3 = WebhookSummaryEnabled and activeTheme.controlOn or activeTheme.surface
            summaryToggle.TextColor3 = activeTheme.text
        end
        updateSummary()

        local function persistWebhookSettings()
            PersistedSettings.webhook.url = WebhookURL
            PersistedSettings.webhook.enabled = WebhookEnabled
            PersistedSettings.webhook.notify = WebhookNotify
            PersistedSettings.webhook.summaryEnabled = WebhookSummaryEnabled
            PersistedSettings.webhook.summaryMinutes = WebhookSummaryMinutes
            PersistedSettings.webhook.userId = WebhookUserId
            saveSettings()
        end

        summaryToggle.MouseButton1Click:Connect(function()
            WebhookSummaryEnabled = not WebhookSummaryEnabled
            WebhookSummaryLastSent = os.clock()
            persistWebhookSettings()
            updateSummary()
        end)

        summaryBox.FocusLost:Connect(function()
            local value = tonumber(summaryBox.Text)
            if not value then value = 30 end
            value = math.clamp(value, 1, 1440)
            WebhookSummaryMinutes = value
            summaryBox.Text = tostring(value)
            WebhookSummaryLastSent = os.clock()
            persistWebhookSettings()
        end)

        local test = Instance.new("TextButton")
        test.Size = UDim2.new(1,-24,0,32)
        test.Position = UDim2.new(0,12,0,298)
        test.BackgroundColor3 = activeTheme.accent
        test.BorderSizePixel = 0
        test.Text = "Send Test Webhook"
        test.TextColor3 = Color3.fromRGB(255,255,255)
        test.Font = Enum.Font.GothamBold
        test.TextSize = 11
        test.Parent = webhookPanel
        do
            local testCorner = Instance.new("UICorner")
            testCorner.CornerRadius = UDim.new(0,6)
            testCorner.Parent = test
        end

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

        -- Live account values for the periodic summary. leaderstats is the
        -- source of truth; the Hatch labels are only a fallback because they
        -- are repainted by the leaderstat hooks a fraction later.
        local function getAccountStats()
            local eggs, diamonds = 0, 0
            pcall(function()
                local leaderstats = localPlayer and localPlayer:FindFirstChild("leaderstats")
                if not leaderstats then return end
                local eggStat = leaderstats:FindFirstChild("Eggs Hatched")
                local gemStat = leaderstats:FindFirstChild("Diamonds")
                eggs = tonumber(eggStat and eggStat.Value) or eggs
                diamonds = tonumber(gemStat and gemStat.Value) or diamonds
            end)
            if eggs == 0 then eggs = readCounter(EggsLabel) end
            if diamonds == 0 then diamonds = readCounter(GemsLabel) end
            return eggs, diamonds
        end

        local function makeSummaryPayload()
            local totals = getCurrentTotals()
            local eggs, diamonds = getAccountStats()
            local fields = {
                {name="Account", value="**"..WebhookAccountName.."**", inline=true},
                {name="Eggs Hatched", value="**"..formatNumber(eggs).."**", inline=true},
                {name="Diamonds", value="**"..formatNumber(diamonds).."**", inline=true},
                {name="Huges", value="**"..numberText(totals.Huge).."**", inline=true},
                {name="Secrets", value="**"..numberText(totals.Secret).."**", inline=true},
                {name="Titanics", value="**"..numberText(totals.Titanic).."**", inline=true},
                {name="Gargantuans", value="**"..numberText(totals.Gargantuan).."**", inline=true}
            }

            local vlines = {}
            for _, base in ipairs({ "Huges", "Titanics", "Gargantuans", "Secrets" }) do
                local rb = variantCounts[base] or 0
                local gd = variantCounts[base .. "Golden"] or 0
                local sh = variantCounts[base .. "Shiny"] or 0
                if rb > 0 or gd > 0 or sh > 0 then
                    table.insert(vlines, ("%s - R:%d  G:%d  S:%d"):format(base, rb, gd, sh))
                end
            end

            local desc = ("Periodic account summary for **%s**."):format(WebhookAccountName)
            if #vlines > 0 then
                desc = desc .. "\n\n**Variants owned**\n" .. table.concat(vlines, "\n")
            end

            return {
                username = "Pet Dimensions Hub",
                embeds = {{
                    title = "Account Summary",
                    description = desc,
                    color = 5793266,
                    fields = fields,
                    footer = { text = "Pet Dimensions Hub - " .. WebhookAccountName },
                    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
                }}
            }
        end

        local function makePayload(testMessage, category, petName, totals, pet)
            local fields = {
                {name="Account", value="**"..WebhookAccountName.."**", inline=true},
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

            local content = ""
            if WebhookUserId ~= "" then
                content = "<@" .. WebhookUserId .. "> "
            end
            
            return {
                username="Pet Dimensions Hub",
                content=content,
                allowed_mentions={parse={"users"}},
                embeds={{
                    title=testMessage and "Webhook Test" or ("New "..tostring(category).."!"),
                    description=desc,
                    color=embedColor,
                    fields=fields,
                    footer={text="Pet Dimensions Hub - Rare Hatch Tracker | "..WebhookAccountName},
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
            WebhookUserId = tostring(userIdBox.Text or ""):match("^%s*(.-)%s*$")
            PersistedSettings.webhook.url = WebhookURL
            PersistedSettings.webhook.userId = WebhookUserId
            saveSettings()
            if WebhookURL == "" then status.Text="Enter a webhook URL first" return end
            WebhookSending=true
            test.Text="Sending..."
            taskSpawn(function()
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

        taskSpawn(function()
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
                        taskWait(5)
                    end
                end

                -- Periodic account summary. Runs on its own clock and only when
                -- the master webhook switch and the summary switch are both on.
                if WebhookEnabled and WebhookSummaryEnabled and not WebhookSending
                    and tostring(WebhookURL or ""):match("%S") then
                    local interval = math.max(60, WebhookSummaryMinutes * 60)
                    if os.clock() - WebhookSummaryLastSent >= interval then
                        WebhookSending = true
                        local ok, sent, err = pcall(function()
                            return webhookSend(makeSummaryPayload())
                        end)
                        WebhookSending = false
                        if ok and sent then
                            WebhookSummaryLastSent = os.clock()
                            status.Text = "Summary sent (" .. tostring(WebhookSummaryMinutes) .. " min interval)"
                        else
                            warn("[Pet Hub] Summary webhook failed: " .. tostring(ok and err or sent))
                            -- Retry in 30 seconds instead of waiting another full
                            -- interval after a transient failure.
                            WebhookSummaryLastSent = os.clock() - interval + 30
                        end
                    end
                end
                taskWait(1)
            end
        end)
    end)

    -- =====================================================================
    -- DAYCARE TAB
    --
    -- Strongest-first enrolment with a permanent shield on the three most
    -- powerful pets the account owns. Locked, equipped, trading-booth,
    -- huge/titanic and banned-rarity pets are still skipped, so the protected
    -- three are the only thing that changes relative to the game's defaults.
    --
    -- The whole feature is wrapped in pcall because a missing Daycare module
    -- or a changed remote signature must never take the hub down with it.
    -- =====================================================================
    pcall(function()
        local daycareFrame = TAB_TOTAL.frame
        if not daycareFrame then return end

        local DaycareModule = Library.Modules and Library.Modules.Daycare
        local Network = Library.Network
        local Signal = Library.Signal
        local Shared = Library.Shared
        local Directory = Library.Directory

        local BANNED_RARITIES = {
            Exclusive = true,
            Secret = true,
            Quest = true,
            ["No rarity yet"] = true,
        }
        local PROTECTED_COUNT = 3
        local INTERVAL = 6
        local running = false
        local busy = false
        local pendingFill = false
        local pendingClaim = false
        local lastStatus = "Idle"
        local nextPassAt = 0
        local blockedCache = {}
        local lastListRefresh = 0

        local function invoke(name, ...)
            if not Network or type(Network.Invoke) ~= "function" then
                return false, "network unavailable"
            end

            local genv = getExecutorEnv()
            if type(genv) ~= "table" then
                local ok, a, b, c = pcall(Network.Invoke, name, ...)
                if not ok then return false, tostring(a) end
                return a, b, c
            end

            -- The framework refuses calls from executors when it can see these
            -- two globals. Hide them only for the duration of the request.
            local savedGetgenv = rawget(genv, "getgenv")
            local savedSettings = rawget(genv, "settings")
            rawset(genv, "getgenv", nil)
            rawset(genv, "settings", nil)

            local ok, a, b, c = pcall(Network.Invoke, name, ...)

            rawset(genv, "getgenv", savedGetgenv)
            rawset(genv, "settings", savedSettings)

            if not ok then return false, tostring(a) end
            return a, b, c
        end

        local function isBlocked(pet)
            if type(pet) ~= "table" or type(pet.uid) ~= "string" then return true end
            local cached = blockedCache[pet.uid]
            local now = os.clock()
            if cached and (now - cached.at) < 30 then return cached.value end

            local ok, result = pcall(function()
                return Signal.Invoke("Is Trading Booth Pet", pet.uid)
            end)
            local value = ok and result == true
            blockedCache[pet.uid] = { value = value, at = now }
            return value
        end

        local function isEligible(pet)
            if type(pet) ~= "table" or type(pet.uid) ~= "string" then return false end
            if pet.l then return false end

            local definition = Directory and Directory.Pets and Directory.Pets[pet.id]
            if not definition then return false end
            if definition.huge or definition.titanic then return false end
            if BANNED_RARITIES[tostring(definition.rarity)] then return false end
            return true
        end

        local function getCapacity(save)
            if not DaycareModule then return 0 end
            local maxSlots = tonumber(DaycareModule.SLOTS_MAX) or 0
            local freeSlots = tonumber(DaycareModule.SLOTS_FREE) or 0
            local tierBonus = 0
            if (tonumber(save.DaycareTier) or 0) > 0 then
                tierBonus = maxSlots - freeSlots
            end
            local vouchers = math.min(
                tonumber(save.DaycareSlotVouchers) or 0,
                tonumber(DaycareModule.VOUCHER_SLOTS_MAX) or 0
            )
            return math.min(maxSlots, freeSlots + tierBonus + vouchers)
        end

        local function queueEntries(save)
            local entries = {}
            local queue = save and save.DaycareQueue
            if type(queue) ~= "table" then return entries end
            for _, entry in ipairs(queue) do
                if type(entry) == "table" then table.insert(entries, entry) end
            end
            for _, entry in pairs(queue) do
                if type(entry) == "table" and not table.find(entries, entry) then
                    table.insert(entries, entry)
                end
            end
            return entries
        end

        local function getEnrolled(save)
            local enrolled = {}
            for _, entry in ipairs(queueEntries(save)) do
                if type(entry.Pet) == "table" and entry.Pet.uid then
                    enrolled[entry.Pet.uid] = true
                end
            end
            return enrolled
        end

        local function getEquipped(save)
            local equipped = {}
            for _, pet in pairs(save.PetsEquipped or {}) do
                if type(pet) == "table" and pet.uid then equipped[pet.uid] = true end
            end
            pcall(function()
                local live = Library.PetCmds.GetEquipped()
                for uid, petData in pairs(live or {}) do
                    if type(petData) == "table" and petData.uid then
                        equipped[petData.uid] = true
                    elseif type(uid) == "string" then
                        equipped[uid] = true
                    end
                end
            end)
            return equipped
        end

        local function ownedPets(save)
            local pets, seen = {}, {}
            local source = save and save.Pets
            if type(source) ~= "table" then return pets end

            for _, pet in ipairs(source) do
                if type(pet) == "table" and type(pet.uid) == "string" and not seen[pet] then
                    seen[pet] = true
                    table.insert(pets, pet)
                end
            end
            for _, pet in pairs(source) do
                if type(pet) == "table" and type(pet.uid) == "string" and not seen[pet] then
                    seen[pet] = true
                    table.insert(pets, pet)
                end
            end
            return pets
        end

        -- Exact requested policy: sort every owned pet by power descending,
        -- permanently skip the three strongest, then take the rest in order.
        local function pickPets(save, amount)
            local enrolled = getEnrolled(save)
            local equipped = getEquipped(save)
            local allPets = ownedPets(save)

            table.sort(allPets, function(a, b)
                local strengthA = tonumber(a.s) or 0
                local strengthB = tonumber(b.s) or 0
                if strengthA ~= strengthB then
                    return strengthA > strengthB
                end
                return a.uid < b.uid
            end)

            local picked = {}
            for index = PROTECTED_COUNT + 1, #allPets do
                if #picked >= amount then break end

                local pet = allPets[index]
                if isEligible(pet)
                    and not enrolled[pet.uid]
                    and not equipped[pet.uid]
                    and not isBlocked(pet) then
                    table.insert(picked, pet.uid)
                end
            end
            return picked
        end

        local function resolveEntryPet(save, entry)
            if type(entry) ~= "table" then return nil end
            if type(entry.Pet) == "table" then return entry.Pet end

            local uid = entry.uid or entry.UID or entry.Uid or entry.petUid
            if type(uid) ~= "string" or type(save.Pets) ~= "table" then return nil end
            for _, pet in ipairs(save.Pets) do
                if type(pet) == "table" and pet.uid == uid then return pet end
            end
            for _, pet in pairs(save.Pets) do
                if type(pet) == "table" and pet.uid == uid then return pet end
            end
            return nil
        end

        local function readyCount(save)
            local ready = 0
            if not Shared or type(Shared.DaycareComputeRemainingTime) ~= "function" then
                return ready
            end
            for _, entry in ipairs(queueEntries(save)) do
                local ok, remaining = pcall(Shared.DaycareComputeRemainingTime, save, entry)
                if ok and type(remaining) == "number" and remaining <= 0 then
                    ready = ready + 1
                end
            end
            return ready
        end

        local function claimNow()
            local save = Save and Save.Get and Save.Get()
            if not save then return false, "save not loaded" end

            local ready = readyCount(save)
            if ready <= 0 then return false, "nothing ready" end

            local success, message = invoke("Daycare: Claim")
            if success then
                return true, ("claimed %d pet(s)"):format(ready)
            end
            return false, tostring(message)
        end

        local function fillNow()
            local save = Save and Save.Get and Save.Get()
            if not save then return false, "save not loaded" end

            local capacity = getCapacity(save)
            if capacity <= 0 then return false, "daycare module unavailable" end

            local entries = queueEntries(save)
            local free = capacity - #entries
            if free <= 0 then return false, "daycare full" end

            local picked = pickPets(save, free)
            if #picked == 0 then return false, "no eligible pets" end

            local success, message = invoke("Daycare: Enroll", picked)

            -- The server rejects the whole batch when it is one too large.
            if not success and type(message) == "string" then
                local holds = tonumber(message:match("holds (%d+) pets"))
                if holds then
                    local retry = holds - #queueEntries(save)
                    if retry > 0 then
                        local trimmed = {}
                        for index = 1, math.min(retry, #picked) do
                            trimmed[index] = picked[index]
                        end
                        success, message = invoke("Daycare: Enroll", trimmed)
                        if success then
                            return true, ("enrolled %d pet(s)"):format(#trimmed)
                        end
                    end
                end
            end

            if success then
                return true, ("enrolled %d pet(s)"):format(#picked)
            end
            return false, tostring(message)
        end

        local function formatDuration(seconds)
            seconds = math.max(0, math.floor(tonumber(seconds) or 0))
            local hours = math.floor(seconds / 3600)
            local minutes = math.floor((seconds % 3600) / 60)
            local secs = seconds % 60
            if hours > 0 then
                return ("%dh %dm %ds"):format(hours, minutes, secs)
            elseif minutes > 0 then
                return ("%dm %ds"):format(minutes, secs)
            end
            return ("%ds"):format(secs)
        end

        local function variantText(pet)
            local tags = {}
            if type(pet) == "table" then
                if pet.r == true then table.insert(tags, "R") end
                if pet.g == true then table.insert(tags, "G") end
                if pet.sh == true then table.insert(tags, "S") end
            end
            return #tags > 0 and ("[" .. table.concat(tags, "+") .. "] ") or ""
        end

        -- ------------------------------------------------------------------
        -- UI
        -- ------------------------------------------------------------------
        do
            local title = Instance.new("TextLabel")
            title.Size = UDim2.new(1, 0, 0, 24)
            title.Position = UDim2.new(0, 0, 0, 0)
            title.BackgroundTransparency = 1
            title.Text = "DAYCARE AUTOMATION"
            title.TextColor3 = Color3.fromRGB(224, 229, 239)
            title.Font = Enum.Font.GothamBold
            title.TextSize = 14
            title.TextXAlignment = Enum.TextXAlignment.Left
            title.Parent = daycareFrame
        end

        createUnifiedToggle(daycareFrame, 32, "Auto Daycare", false, function(value)
            running = value
            if value then
                pendingFill = true
                pendingClaim = true
                lastStatus = "starting..."
            else
                pendingFill = false
                pendingClaim = false
                lastStatus = "Idle"
            end
        end)

        local statusPanel = Instance.new("Frame")
        statusPanel.Size = UDim2.new(1, 0, 0, 190)
        statusPanel.Position = UDim2.new(0, 0, 0, 76)
        statusPanel.BackgroundColor3 = activeTheme.panel
        statusPanel.BorderSizePixel = 0
        statusPanel.Parent = daycareFrame
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = statusPanel
            local s = Instance.new("UIStroke")
            s.Color = activeTheme.stroke
            s.Transparency = 0.45
            s.Parent = statusPanel
        end

        local function makeStatusLabel(y, color, size)
            local label = Instance.new("TextLabel")
            label.Size = UDim2.new(1, -20, 0, 22)
            label.Position = UDim2.new(0, 10, 0, y)
            label.BackgroundTransparency = 1
            label.Text = ""
            label.TextColor3 = color
            label.Font = Enum.Font.GothamBold
            label.TextSize = size or 13
            label.TextXAlignment = Enum.TextXAlignment.Left
            label.Parent = statusPanel
            return label
        end

        local statusLabel = makeStatusLabel(8, Color3.fromRGB(120, 255, 180))
        local slotsLabel = makeStatusLabel(32, Color3.fromRGB(190, 190, 200))
        local petsLabel = makeStatusLabel(56, Color3.fromRGB(190, 190, 200))
        local powerLabel = makeStatusLabel(80, Color3.fromRGB(255, 210, 80))
        local timeLabel = makeStatusLabel(104, Color3.fromRGB(110, 185, 255))
        local policyLabel = makeStatusLabel(128, Color3.fromRGB(160, 160, 175), 11)
        policyLabel.Text = "Policy: top 3 power protected, rest strongest-first"

        local fillButton = Instance.new("TextButton")
        fillButton.Size = UDim2.new(0.48, 0, 0, 32)
        fillButton.Position = UDim2.new(0, 0, 0, 276)
        fillButton.BackgroundColor3 = activeTheme.accent
        fillButton.Text = "Fill Now"
        fillButton.TextColor3 = Color3.fromRGB(255, 255, 255)
        fillButton.Font = Enum.Font.GothamBold
        fillButton.TextSize = 12
        fillButton.Parent = daycareFrame
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = fillButton
        end
        fillButton.MouseButton1Click:Connect(function()
            pendingFill = true
        end)

        local claimButton = Instance.new("TextButton")
        claimButton.Size = UDim2.new(0.48, 0, 0, 32)
        claimButton.Position = UDim2.new(0.52, 0, 0, 276)
        claimButton.BackgroundColor3 = activeTheme.controlOn
        claimButton.Text = "Claim Ready"
        claimButton.TextColor3 = Color3.fromRGB(255, 255, 255)
        claimButton.Font = Enum.Font.GothamBold
        claimButton.TextSize = 12
        claimButton.Parent = daycareFrame
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = claimButton
        end
        claimButton.MouseButton1Click:Connect(function()
            pendingClaim = true
        end)

        do
            local listTitle = Instance.new("TextLabel")
            listTitle.Size = UDim2.new(1, 0, 0, 20)
            listTitle.Position = UDim2.new(0, 0, 0, 320)
            listTitle.BackgroundTransparency = 1
            listTitle.Text = "PETS IN DAYCARE"
            listTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
            listTitle.Font = Enum.Font.GothamBold
            listTitle.TextSize = 13
            listTitle.TextXAlignment = Enum.TextXAlignment.Left
            listTitle.Parent = daycareFrame
        end

        local list = Instance.new("ScrollingFrame")
        list.Size = UDim2.new(1, 0, 0, 240)
        list.Position = UDim2.new(0, 0, 0, 344)
        list.BackgroundColor3 = activeTheme.panel
        list.BackgroundTransparency = 0.25
        list.BorderSizePixel = 0
        list.ScrollBarThickness = 4
        list.CanvasSize = UDim2.new(0, 0, 0, 0)
        list.AutomaticCanvasSize = Enum.AutomaticSize.Y
        list.Parent = daycareFrame
        do
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0, 8)
                c.Parent = list
            end
            local p = Instance.new("UIPadding")
            p.PaddingLeft = UDim.new(0, 8)
            p.PaddingRight = UDim.new(0, 8)
            p.PaddingTop = UDim.new(0, 6)
            p.Parent = list
            local layout = Instance.new("UIListLayout")
            layout.SortOrder = Enum.SortOrder.LayoutOrder
            layout.Padding = UDim.new(0, 2)
            layout.Parent = list
        end

        local function updateStatus()
            local save = Save and Save.Get and Save.Get()
            if not save then
                statusLabel.Text = "Status: save not loaded"
                slotsLabel.Text = "Slots: --"
                petsLabel.Text = "Pets in daycare: --"
                powerLabel.Text = "Total power: --"
                timeLabel.Text = "Next ready: --"
                return
            end

            local entries = queueEntries(save)
            local capacity = getCapacity(save)
            local totalPower = 0
            local nextRemaining = nil
            local rows = {}

            for _, entry in ipairs(entries) do
                local pet = resolveEntryPet(save, entry)
                local power = math.floor(tonumber(pet and pet.s) or 0)
                totalPower = totalPower + power

                local remaining = nil
                if Shared and type(Shared.DaycareComputeRemainingTime) == "function" then
                    local ok, value = pcall(Shared.DaycareComputeRemainingTime, save, entry)
                    if ok and type(value) == "number" then
                        remaining = value
                    end
                end
                if remaining then
                    nextRemaining = nextRemaining and math.min(nextRemaining, remaining) or remaining
                end

                local name = pet and getPetDisplayName(pet) or "Unknown Pet"
                local timeText = remaining and (remaining <= 0 and "ready" or formatDuration(remaining)) or "--"
                table.insert(rows, {
                    text = ("- %s%s  |  %s power  |  %s"):format(
                        variantText(pet),
                        tostring(name),
                        formatNumber(power),
                        timeText
                    ),
                    rainbow = pet and pet.r == true,
                    golden = pet and pet.g == true,
                    shiny = pet and pet.sh == true,
                })
            end

            local ready = readyCount(save)
            statusLabel.Text = "Status: " .. tostring(lastStatus)
            slotsLabel.Text = ("Slots: %d / %d"):format(#entries, capacity)
            petsLabel.Text = ("Pets in daycare: %d"):format(#entries)
            powerLabel.Text = ("Total power: %s"):format(formatNumber(totalPower))

            if ready > 0 then
                timeLabel.Text = ("Ready now: %d pet(s)"):format(ready)
            elseif nextRemaining then
                timeLabel.Text = "Next ready in: " .. formatDuration(nextRemaining)
            else
                timeLabel.Text = "Next ready: --"
            end

            local now = os.clock()
            if now - lastListRefresh >= 5 then
                lastListRefresh = now
                for _, child in ipairs(list:GetChildren()) do
                    if child:IsA("TextLabel") then child:Destroy() end
                end
                for index, row in ipairs(rows) do
                    local label = Instance.new("TextLabel")
                    label.Size = UDim2.new(1, -6, 0, 22)
                    label.BackgroundTransparency = 1
                    label.Text = row.text
                    label.TextColor3 = Color3.fromRGB(190, 190, 200)
                    if row.rainbow then
                        label.TextColor3 = Color3.fromRGB(255, 120, 220)
                    elseif row.golden then
                        label.TextColor3 = Color3.fromRGB(255, 200, 70)
                    elseif row.shiny then
                        label.TextColor3 = Color3.fromRGB(120, 220, 255)
                    end
                    label.Font = Enum.Font.Gotham
                    label.TextSize = 12
                    label.TextXAlignment = Enum.TextXAlignment.Left
                    label.TextTruncate = Enum.TextTruncate.AtEnd
                    label.LayoutOrder = index
                    label.Parent = list
                end
                if #rows == 0 then
                    local empty = Instance.new("TextLabel")
                    empty.Size = UDim2.new(1, -6, 0, 22)
                    empty.BackgroundTransparency = 1
                    empty.Text = "No pets enrolled."
                    empty.TextColor3 = activeTheme.muted
                    empty.Font = Enum.Font.Gotham
                    empty.TextSize = 12
                    empty.TextXAlignment = Enum.TextXAlignment.Left
                    empty.Parent = list
                end
            end
        end

        local function performPass()
            if busy then return end
            busy = true

            -- Manual presses always report back. The auto loop stays quiet on
            -- the two expected no-ops so the status line does not flicker
            -- between "daycare full" and the last real result every 6 s.
            local manualClaim = pendingClaim
            local manualFill = pendingFill
            local doClaim = manualClaim or running
            local doFill = manualFill or running
            pendingClaim = false
            pendingFill = false

            if doClaim then
                local ok, message = claimNow()
                if ok then
                    lastStatus = message
                elseif message ~= "nothing ready" or manualClaim then
                    lastStatus = tostring(message)
                end
            end

            if doFill then
                local ok, message = fillNow()
                if ok then
                    lastStatus = message
                elseif (message ~= "daycare full" and message ~= "no eligible pets") or manualFill then
                    lastStatus = tostring(message)
                end
            end

            busy = false
        end

        taskSpawn(function()
            while daycareFrame.Parent do
                updateStatus()

                local now = os.clock()
                local wants = running or pendingFill or pendingClaim
                if wants and not busy and (pendingFill or pendingClaim or now >= nextPassAt) then
                    performPass()
                    nextPassAt = os.clock() + INTERVAL
                end

                taskWait(1)
            end
        end)
    end)

    -- Apply saved toggle states only after every toggle has been created.
    -- This is important for AFK Mode and Auto-Hatch because their callbacks
    -- depend on UI/functions that are created later in the script.
    --
    -- AFK Mode is deliberately EXEMPT. Restoring it made the script open
    -- straight into the full-screen AFK overlay with the hub hidden, so every
    -- execute looked like it had thrown the UI away. It still saves like
    -- every other toggle, it just never auto-restores.
    local AFK_TOGGLE = "AFK Mode"
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
        -- setAfkMode also resets the visible hatch-tab toggle and saved state.
        setAfkMode(false)
    end)

    -- =====================================================================
    -- AFK RARE PANEL
    -- Tier cards with live totals, session deltas, variant chips and the
    -- recent hatches for the current session. This panel used to be built
    -- with Visible = false and never re-shown, which is why the AFK screen
    -- stopped reporting rare hatches entirely.
    -- =====================================================================
    local function buildAfkRarePanel()
        local panel = Instance.new("Frame")
        panel.Name = "AfkRarePanel"
        panel.Size = UDim2.new(1, -12, 0.49, 0)
        panel.Position = UDim2.new(0, 6, 0.38, 0)
        panel.BackgroundColor3 = Color3.fromRGB(19, 25, 37)
        panel.BackgroundTransparency = 0.02
        panel.BorderSizePixel = 0
        panel.ClipsDescendants = false
        panel.Visible = true
        panel.ZIndex = 103
        panel.Parent = afkCenter

        do
            local panelCorner = Instance.new("UICorner")
            panelCorner.CornerRadius = UDim.new(0, 16)
            panelCorner.Parent = panel
        end

        do
            local panelStroke = Instance.new("UIStroke")
            panelStroke.Color = Color3.fromRGB(91, 105, 128)
            panelStroke.Transparency = 0.62
            panelStroke.Thickness = 1
            panelStroke.Parent = panel
        end

        local header = Instance.new("Frame")
        header.Name = "Header"
        header.Size = UDim2.new(1, 0, 0, 40)
        header.BackgroundTransparency = 1
        header.ZIndex = 104
        header.Parent = panel

        local headerDot = Instance.new("Frame")
        headerDot.Size = UDim2.new(0, 7, 0, 7)
        headerDot.Position = UDim2.new(0, 16, 0.5, -3)
        headerDot.BackgroundColor3 = Style.violet
        headerDot.BorderSizePixel = 0
        headerDot.ZIndex = 105
        headerDot.Parent = header

        do
            local headerDotCorner = Instance.new("UICorner")
            headerDotCorner.CornerRadius = UDim.new(1, 0)
            headerDotCorner.Parent = headerDot
        end

        do
            local headerTitle = Instance.new("TextLabel")
            headerTitle.Size = UDim2.new(0.62, -30, 1, 0)
            headerTitle.Position = UDim2.new(0, 30, 0, 0)
            headerTitle.BackgroundTransparency = 1
            headerTitle.Text = "RECENT RARE HATCHES"
            headerTitle.TextColor3 = Style.text
            headerTitle.Font = Enum.Font.GothamBold
            headerTitle.TextSize = 13
            headerTitle.TextXAlignment = Enum.TextXAlignment.Left
            headerTitle.ZIndex = 105
            headerTitle.Parent = header
        end

        do
            local headerHint = Instance.new("TextLabel")
            headerHint.Size = UDim2.new(0.30, -16, 1, 0)
            headerHint.Position = UDim2.new(0.68, 0, 0, 0)
            headerHint.BackgroundTransparency = 1
            headerHint.Text = "this AFK session"
            headerHint.TextColor3 = Style.muted
            headerHint.Font = Enum.Font.Gotham
            headerHint.TextSize = 10
            headerHint.TextXAlignment = Enum.TextXAlignment.Right
            headerHint.ZIndex = 105
            headerHint.Parent = header
        end

        do
            local headerLine = Instance.new("Frame")
            headerLine.Size = UDim2.new(1, -32, 0, 1)
            headerLine.Position = UDim2.new(0, 16, 0, 40)
            headerLine.BackgroundColor3 = Style.line
            headerLine.BackgroundTransparency = 0.55
            headerLine.BorderSizePixel = 0
            headerLine.ZIndex = 104
            headerLine.Parent = panel
        end

        local afkCategoryLabelColors = {
            Color3.fromRGB(151, 181, 207),
            Color3.fromRGB(151, 190, 171),
            Color3.fromRGB(177, 164, 204),
            Color3.fromRGB(202, 163, 169),
        }

        for index, category in ipairs(recentCategories) do
            local card = Instance.new("Frame")
            card.Name = category.name .. "Card"
            card.Size = UDim2.new(0.25, -14, 1, -50)
            card.Position = UDim2.new((index - 1) * 0.25, 7, 0, 45)
            card.BackgroundColor3 = Color3.fromRGB(28, 34, 47)
            card.BackgroundTransparency = 0.02
            card.ClipsDescendants = false
            card.BorderSizePixel = 0
            card.ZIndex = 104
            card.Parent = panel

            local cardCorner = Instance.new("UICorner")
            cardCorner.CornerRadius = UDim.new(0, 12)
            cardCorner.Parent = card

            do
                local cardStroke = Instance.new("UIStroke")
                cardStroke.Color = Color3.fromRGB(91, 105, 128)
                cardStroke.Transparency = 0.72
                cardStroke.Thickness = 1
                cardStroke.Parent = card
            end

            local accent = Instance.new("Frame")
            accent.Size = UDim2.new(1, -28, 0, 2)
            accent.Position = UDim2.new(0, 14, 0, 10)
            accent:SetAttribute("ThemeRole", "Accent")
            accent.BackgroundColor3 = activeTheme.accent
            accent.BackgroundTransparency = 0.15
            accent.BorderSizePixel = 0
            accent.ZIndex = 105
            accent.Parent = card

            do
                local accentCorner = Instance.new("UICorner")
                accentCorner.CornerRadius = UDim.new(1, 0)
                accentCorner.Parent = accent
            end

            local nameLabel = Instance.new("TextLabel")
            nameLabel.Size = UDim2.new(1, -28, 0, 16)
            nameLabel.Position = UDim2.new(0, 14, 0, 20)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = category.name:upper()
            nameLabel.TextColor3 = afkCategoryLabelColors[index] or Color3.fromRGB(174, 183, 199)
            nameLabel.Font = Enum.Font.GothamBold
            nameLabel.TextSize = 10
            nameLabel.TextXAlignment = Enum.TextXAlignment.Left
            nameLabel.ZIndex = 105
            nameLabel.Parent = card

            local countLabel = Instance.new("TextLabel")
            countLabel.Size = UDim2.new(1, -28, 0, 36)
            countLabel.Position = UDim2.new(0, 14, 0, 40)
            countLabel.BackgroundTransparency = 1
            countLabel.Text = "0"
            countLabel.TextColor3 = Color3.fromRGB(218, 224, 236)
            countLabel.Font = Enum.Font.GothamBold
            countLabel.TextSize = 27
            countLabel.TextXAlignment = Enum.TextXAlignment.Left
            countLabel.ZIndex = 105
            countLabel.Parent = card
            afkRareLabels[category.name .. "s"] = countLabel

            local sessionLabel = Instance.new("TextLabel")
            sessionLabel.Size = UDim2.new(1, -28, 0, 15)
            sessionLabel.Position = UDim2.new(0, 14, 0, 80)
            sessionLabel.BackgroundTransparency = 1
            sessionLabel.Text = "+0 this session"
            sessionLabel.TextColor3 = Color3.fromRGB(174, 183, 199)
            sessionLabel.Font = Enum.Font.GothamBold
            sessionLabel.TextSize = 11
            sessionLabel.TextXAlignment = Enum.TextXAlignment.Left
            sessionLabel.ZIndex = 105
            sessionLabel.Parent = card
            afkSessionLabels[category.name .. "s"] = sessionLabel

            local variantLabel = Instance.new("TextLabel")
            variantLabel.Size = UDim2.new(1, -28, 0, 14)
            variantLabel.Position = UDim2.new(0, 14, 0, 100)
            variantLabel.BackgroundTransparency = 1
            variantLabel.Text = "R 0   G 0   S 0"
            variantLabel.TextColor3 = Style.muted
            variantLabel.Font = Enum.Font.GothamSemibold
            variantLabel.TextSize = 10
            variantLabel.TextXAlignment = Enum.TextXAlignment.Left
            variantLabel.ZIndex = 105
            variantLabel.Parent = card
            afkSessionVariantLabels[category.name .. "s"] = variantLabel

            local startupLabel = Instance.new("TextLabel")
            startupLabel.Size = UDim2.new(1, -28, 0, 14)
            startupLabel.Position = UDim2.new(0, 14, 0, 118)
            startupLabel.BackgroundTransparency = 1
            startupLabel.Text = "+0 since launch"
            startupLabel.TextColor3 = Style.muted
            startupLabel.Font = Enum.Font.Gotham
            startupLabel.TextSize = 10
            startupLabel.TextXAlignment = Enum.TextXAlignment.Left
            startupLabel.ZIndex = 105
            startupLabel.Parent = card
            startupLabels[category.name .. "s"] = startupLabel

            do
                local divider = Instance.new("Frame")
                divider.Size = UDim2.new(1, -28, 0, 1)
                divider.Position = UDim2.new(0, 14, 0, 140)
                divider.BackgroundColor3 = Style.line
                divider.BackgroundTransparency = 0.45
                divider.BorderSizePixel = 0
                divider.ZIndex = 105
                divider.Parent = card
            end

            local list = Instance.new("ScrollingFrame")
            list.Name = category.name .. "Recent"
            list.Size = UDim2.new(1, -20, 1, -154)
            list.Position = UDim2.new(0, 10, 0, 148)
            list.BackgroundTransparency = 1
            list.BorderSizePixel = 0
            list.ScrollBarThickness = 3
            list.CanvasSize = UDim2.new(0, 0, 0, 0)
            list.AutomaticCanvasSize = Enum.AutomaticSize.Y
            list.ZIndex = 105
            list.Parent = card

            do
                local listPadding = Instance.new("UIPadding")
                listPadding.PaddingLeft = UDim.new(0, 4)
                listPadding.PaddingRight = UDim.new(0, 6)
                listPadding.PaddingTop = UDim.new(0, 4)
                listPadding.PaddingBottom = UDim.new(0, 6)
                listPadding.Parent = list
            end

            do
                local listLayout = Instance.new("UIListLayout")
                listLayout.SortOrder = Enum.SortOrder.LayoutOrder
                listLayout.Padding = UDim.new(0, 3)
                listLayout.Parent = list
            end

            afkRecentLists[category.name] = { frame = list, entries = category.entries, color = category.color }
        end

        renderAfkRecent = function()
            for _, category in ipairs(recentCategories) do
                local listData = afkRecentLists[category.name]
                if listData then
                    for _, child in ipairs(listData.frame:GetChildren()) do
                        if child:IsA("TextLabel") then child:Destroy() end
                    end

                    if #listData.entries == 0 then
                        do
                            local empty = Instance.new("TextLabel")
                            empty.Size = UDim2.new(1, 0, 0, 16)
                            empty.BackgroundTransparency = 1
                            empty.Text = "nothing hatched yet"
                            empty.TextColor3 = Style.muted
                            empty.Font = Enum.Font.Gotham
                            empty.TextSize = 10
                            empty.TextXAlignment = Enum.TextXAlignment.Left
                            empty.TextTransparency = 0.12
                            empty.Parent = listData.frame
                        end
                    end

                    for entryIndex, entryData in ipairs(listData.entries) do
                        local label = Instance.new("TextLabel")
                        label.Size = UDim2.new(1, 0, 0, 16)
                        label.BackgroundTransparency = 1

                        local variants = {}
                        if entryData.rainbow then table.insert(variants, "R") end
                        if entryData.golden then table.insert(variants, "G") end
                        if entryData.shiny then table.insert(variants, "S") end
                        local variantPrefix = #variants > 0 and ("[" .. table.concat(variants, "+") .. "] ") or ""
                        label.Text = "- " .. variantPrefix .. tostring(entryData.name)

                        label.TextColor3 = listData.color
                        if entryData.rainbow then
                            label.TextColor3 = Color3.fromRGB(255, 130, 225)
                        elseif entryData.golden then
                            label.TextColor3 = Color3.fromRGB(255, 205, 85)
                        elseif entryData.shiny then
                            label.TextColor3 = Color3.fromRGB(125, 225, 255)
                        end

                        label.Font = Enum.Font.GothamMedium
                        label.TextSize = 11
                        label.TextTruncate = Enum.TextTruncate.AtEnd
                        label.TextXAlignment = Enum.TextXAlignment.Left
                        label.LayoutOrder = entryIndex
                        label.Parent = listData.frame
                    end
                end
            end
        end
    end
    buildAfkRarePanel()

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
            afkEggs.Text = formatNumber(eggsStat.Value)
            eggsStat.Changed:Connect(function(value)
                EggsLabel.Text = "Eggs: " .. formatNumber(value)
                afkEggs.Text = "Total Eggs: " .. formatNumber(value)
            end)
        end

        local gemStat = leaderstats:FindFirstChild("Diamonds")
        if gemStat then
            GemsLabel.Text = "Diamonds: " .. formatNumber(gemStat.Value)
            afkGems.Text = formatNumber(gemStat.Value)
            gemStat.Changed:Connect(function(value)
                GemsLabel.Text = "Diamonds: " .. formatNumber(value)
                afkGems.Text = "Total Diamonds: " .. formatNumber(value)
            end)
        end
    end
    taskSpawn(hookLeaderstats)

-- AUTO-HATCH
-- The game already ships a complete auto-hatch driver in
-- `Scripts.Game.Auto Hatch`: it runs on a 0.1s tick, gates on
-- `Library.Variables.OpeningEgg <= 0`. Now we drive the engine instead of
-- duplicating it:
--   * primary path  - set AutoHatchEnabled / AutoHatchEggId and let the game buy
--   * fallback path - only when the account has no Auto Hatch gamepass, run a
--                     "BuyX Egg" loop with a 0.25s server cooldown (tested safe)
--   * watchdog      - re-asserts the variables if anything clears them, and
--                     backs off instead of hammering on hard failures
-- Auto-hatch uses closest egg only - no manual egg selection dropdown anymore.
local function ownsAutoHatchGamepass()
    local ok, pass = pcall(function()
        local entry = Library.Directory.Gamepasses["Auto Hatch"]
        return entry and Library.Gamepasses.Owns(entry.ID)
    end)
    return ok and pass == true
end

local function eggCostsDiamonds(eggId)
    local def = eggDefForId(eggId)
    return type(def) == "table" and tostring(def.currency) == "Diamonds"
end

local function selectedQuestDiamondEgg(eggId)
    -- Quest automation may spend Diamonds only on an egg the user explicitly
    -- chose in one of the egg dropdowns.
    return eggId ~= nil and (eggId == AfkFarmEgg or eggId == AutoFarmTabTargetEgg)
end

-- Eggs are not all named "Egg Capsule": Lucky / Storm / Chroma and other
-- special eggs are models named after themselves. Match on the ID attribute
-- instead, exactly like the quest capsule resolver does.
local function findClosestEggId(allowDiamonds)
    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end

    local map = Workspace:FindFirstChild("__MAP")
    local eggsFolder = map and map:FindFirstChild("Eggs")
    if not eggsFolder then return nil end

    local bestId, bestDistance = nil, math.huge
    for _, model in ipairs(eggsFolder:GetDescendants()) do
        if model:IsA("Model") then
            local id = model:GetAttribute("ID")
            local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
            if id ~= nil and part and (allowDiamonds ~= false or not eggCostsDiamonds(tostring(id))) then
                local distance = (hrp.Position - part.Position).Magnitude
                if distance < bestDistance then
                    bestDistance = distance
                    bestId = tostring(id)
                end
            end
        end
    end

    return bestId
end

-- Auto-hatch normally uses the closest egg only. While the quest driver is
-- working an egg objective it publishes QuestTargetEggId, and that egg wins as
-- long as its capsule is streamed in - so the moment the objective clears (or
-- the player leaves the area) the loop falls back to the closest egg.
local function eggCapsuleExists(eggId)
    if eggId == nil then return false end
    local map = Workspace:FindFirstChild("__MAP")
    local eggsFolder = map and map:FindFirstChild("Eggs")
    if not eggsFolder then return false end
    local wanted = tostring(eggId)
    for _, model in ipairs(eggsFolder:GetDescendants()) do
        if model:IsA("Model") then
            local id = model:GetAttribute("ID")
            if id ~= nil and tostring(id) == wanted then
                return true
            end
        end
    end
    return false
end

local function currentHatchEggId()
    local questMode = AutoQuests or AutoQuestsSide
    local target = QuestTargetEggId
    if target and (not questMode or not eggCostsDiamonds(target) or selectedQuestDiamondEgg(target))
        and eggCapsuleExists(target) then
        return target
    end
    -- Playtime AFK's dropdown is an explicit user selection, so a Diamond egg
    -- selected there is allowed even while quest automation owns auto-hatch.
    if QuestPlaytimeActive and AfkFarmEgg and eggDefForId(AfkFarmEgg)
        and (not questMode or not eggCostsDiamonds(AfkFarmEgg) or selectedQuestDiamondEgg(AfkFarmEgg)) then
        return AfkFarmEgg
    end
    -- Auto Farm tab dropdown is also an explicit selection.
    if type(AutoFarmTabTargetEgg) == "string" and eggDefForId(AutoFarmTabTargetEgg)
        and (not questMode or not eggCostsDiamonds(AutoFarmTabTargetEgg) or selectedQuestDiamondEgg(AutoFarmTabTargetEgg))
        and eggCapsuleExists(AutoFarmTabTargetEgg) then
        return AutoFarmTabTargetEgg
    end
    -- Quest-driven hatch must never silently spend Diamonds on the nearest
    -- capsule. Standalone Auto Hatch intentionally supports Diamond eggs.
    return findClosestEggId(not questMode)
end

local function hatchViaBuyX()
    if os.clock() < HatchCooldownUntil then return end
    if (tonumber(Library.Variables.OpeningEgg) or 0) > 0 then return end
    local ok, canAct = pcall(function() return Library.WorldCmds.CanDoAction() end)
    if ok and canAct == false then return end

    local eggId = currentHatchEggId()
    if not eggId then return end
    if not RawNet.invoke then
        HatchWatchdogStatus = "network unavailable"
        return
    end

    HatchCooldownUntil = os.clock() + 0.25
    local invoked, result, err = RawNet.invoke("BuyX Egg", eggId)

    if not invoked then
        HatchFailures = HatchFailures + 1
    elseif result == true then
        HatchFailures = 0
        HatchLastEgg = os.clock()
        HatchWatchdogStatus = "hatching " .. tostring(eggId)
    elseif type(err) == "string" and err:find("too quickly") then
        -- Expected back-pressure from the server. Back off a little harder so
        -- a rejected request cannot snowball into a retry storm.
        HatchCooldownUntil = os.clock() + 0.5
    elseif type(err) == "string" and err:find("too far") then
        HatchWatchdogStatus = "closest egg out of range"
        HatchCooldownUntil = os.clock() + 1.0
    else
        HatchFailures = HatchFailures + 1
        HatchWatchdogStatus = "buy failed: " .. tostring(err)
    end

    if HatchFailures >= 5 then
        HatchCooldownUntil = os.clock() + 5
        HatchFailures = 0
    end
end

local function pushHatchState()
    local eggId = currentHatchEggId()
    pcall(function()
        Library.Variables.AutoHatchEggId = eggId
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
taskSpawn(function()
    local wasOn = false
    while true do
        if AutoBuying then
            wasOn = true

            -- Repoint the engine at the closest egg every tick, so walking to
            -- a different egg area retargets auto-hatch automatically.
            local eggId = currentHatchEggId()
            if eggId then
                pcall(function()
                    if Library.Variables.AutoHatchEggId ~= eggId then
                        Library.Variables.AutoHatchEggId = eggId
                    end
                    Library.Variables.AutoHatchEnabled = true
                end)
            end

            if os.clock() >= ownsPassRefreshAt then
                ownsPassCached = ownsAutoHatchGamepass()
                ownsPassRefreshAt = os.clock() + 10
            end

            local selectedEgg = currentHatchEggId()
            local diamondEgg = selectedEgg and eggCostsDiamonds(selectedEgg)
            if diamondEgg then
                -- Keep the built-in engine from competing with the explicit
                -- BuyX request for premium-currency eggs.
                pcall(function() Library.Variables.AutoHatchEnabled = false end)
            end
            if ownsPassCached and not diamondEgg then
                HatchWatchdogStatus = "auto hatch running (engine) -> " .. tostring(eggId)
                taskWait(1)
            else
                -- No gamepass: we drive it. hatchViaBuyX enforces a 0.25s
                -- server cooldown (tested safe), so poll at 0.1s.
                hatchViaBuyX()
                taskWait(0.1)
            end
        else
            -- Only touch the engine state on the transition, so a hatch the
            -- player started from the game's own UI is not fought over.
            if wasOn then
                clearHatchState()
                wasOn = false
            end
            HatchWatchdogStatus = "Idle"
            taskWait(0.5)
        end
    end
end)

setAutoHatchState = function(enabled)
    enabled = enabled == true
    AutoBuying = enabled
    if enabled then
        pushHatchState()
    else
        clearHatchState()
    end

    -- Keep the visible control synchronized with the actual automation state.
    if hatchToggleBtn and hatchToggleBtn.Parent then
        hatchToggleBtn:SetAttribute("ToggleState", enabled)
        hatchToggleBtn:SetAttribute("ThemeRole", "Toggle")
        hatchToggleBtn.BackgroundColor3 = enabled and activeTheme.controlOn or activeTheme.surface
        hatchToggleBtn.Text = "Auto-Hatch Egg: " .. (enabled and "ON" or "OFF")
        hatchToggleBtn.TextColor3 = activeTheme.text
    end
end


    -- Auto-Hatch Egg toggle is already provided inside ControlPanel (hatchToggleBtn);
    -- sync its state here and keep hatchFrame CanvasSize clear of overlaps.
    if toggleRegistry["Auto-Hatch Egg"] then
        table.insert(toggleRegistry["Auto-Hatch Egg"], function(value)
            hatchToggleBtn:SetAttribute("ToggleState", value == true)
            hatchToggleBtn.BackgroundColor3 = value and activeTheme.controlOn or activeTheme.surface
            hatchToggleBtn.Text = "Auto-Hatch Egg: " .. (value and "ON" or "OFF")
            hatchToggleBtn.TextColor3 = activeTheme.text
        end)
    end
    hatchFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    hatchFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y

    -- Shared teleport primitives. The teleport workflow needs to move the
    -- player to the area whose egg drops a missing pet, so the world-load and
    -- area-center helpers live at this scope instead of inside the teleport
    -- tab block only. Assigned by buildTeleportTab(); no-ops until then.
    local sharedGetCharacterRoot = nil
    local sharedGetAreaCenter = nil
    local sharedLoadWorldSafely = nil
    local sharedIsTeleportBusy = function() return false end

    -- =====================================================================
    -- TELEPORT TAB UI
    -- =====================================================================
    do
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
    end

    do
        local tpTip = Instance.new("TextLabel")
        tpTip.Size = UDim2.new(1, 0, 0, 42)
        tpTip.Position = UDim2.new(0, 0, 0, 24)
        tpTip.BackgroundTransparency = 1
        tpTip.Text = "Click a world to expand it. Every teleport drops you in the middle of the area, 5 studs above the ground."
        tpTip.TextColor3 = Color3.fromRGB(255, 190, 80)
        tpTip.Font = Enum.Font.GothamSemibold
        tpTip.TextSize = 11
        tpTip.TextWrapped = true
        tpTip.TextXAlignment = Enum.TextXAlignment.Left
        tpTip.TextYAlignment = Enum.TextYAlignment.Center
        tpTip.Parent = tpFrame
    end

    -- Scrolling keeps the teleport list usable on smaller resolutions.
    local tpScroll = Instance.new("ScrollingFrame")
    tpScroll.Size = UDim2.new(1, 0, 1, -96)
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

    -- The teleport tab is self-contained so it does not eat into the
    -- local register budget of the rest of the UI builder.
    local function buildTeleportTab()
        -- Status line under the list. Every teleport reports here so a world that
        -- refuses to load never looks like the script froze.
        local tpStatus = Instance.new("TextLabel")
        tpStatus.Size = UDim2.new(1, 0, 0, 20)
        tpStatus.Position = UDim2.new(0, 0, 1, -24)
        tpStatus.BackgroundTransparency = 1
        tpStatus.Text = "Ready."
        tpStatus.TextColor3 = Color3.fromRGB(170, 175, 185)
        tpStatus.Font = Enum.Font.GothamSemibold
        tpStatus.TextSize = 11
        tpStatus.TextXAlignment = Enum.TextXAlignment.Left
        tpStatus.TextTruncate = Enum.TextTruncate.AtEnd
        tpStatus.Parent = tpFrame

        local TP_OK_COLOR = Color3.fromRGB(120, 220, 150)
        local TP_WARN_COLOR = Color3.fromRGB(255, 170, 70)

        local function setTeleportStatus(text, color)
            tpStatus.Text = text
            tpStatus.TextColor3 = color or Color3.fromRGB(170, 175, 185)
        end

        -- Executor helpers are looked up through getgenv because this environment
        -- does not expose them as plain globals.
        local executorGetUpvalues = nil
        local executorSetupValue = nil
        do
            local env = getExecutorEnv()
            if type(env) == "table" then
                if type(env.getupvalues) == "function" then
                    executorGetUpvalues = env.getupvalues
                end
                if type(env.setupvalue) == "function" then
                    executorSetupValue = env.setupvalue
                end
            end
            if type(executorGetUpvalues) ~= "function" then
                local okFn, fn = pcall(function() return getupvalues end)
                if okFn and type(fn) == "function" then
                    executorGetUpvalues = fn
                end
            end
            if type(executorSetupValue) ~= "function" then
                local okFn, fn = pcall(function() return setupvalue end)
                if okFn and type(fn) == "function" then
                    executorSetupValue = fn
                end
            end
        end

        local function getCharacterRoot()
            local character = localPlayer.Character
            if not character then return nil, nil end
            local root = character:FindFirstChild("HumanoidRootPart")
            if not root then return character, nil end
            return character, root
        end

        -- Exposed for the teleport workflow (see sharedGetCharacterRoot above).
        sharedGetCharacterRoot = getCharacterRoot

        -- Area centre resolution, in order of reliability:
        --   1. the game's own spawn regions (flat pads sitting on the walkable floor)
        --   2. the game's teleport pad for the area
        --   3. the union of every part inside the area folder
        -- The result is always 5 studs above the surface being used.
        local function getAreaCenter(areaName)
            local okRegions, regions = pcall(function()
                return Library.WorldCmds.GetAreaSpawnRegions(areaName)
            end)
            if okRegions and type(regions) == "table" and #regions > 0 then
                local minX, maxX, maxY, minZ, maxZ
                local found = false
                for _, region in ipairs(regions) do
                    local cf, size = region.cframe, region.size
                    if typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
                        local p = cf.Position
                        local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
                        local x1, x2 = p.X - hx, p.X + hx
                        local y2 = p.Y + hy
                        local z1, z2 = p.Z - hz, p.Z + hz
                        minX = minX and math.min(minX, x1) or x1
                        maxX = maxX and math.max(maxX, x2) or x2
                        maxY = maxY and math.max(maxY, y2) or y2
                        minZ = minZ and math.min(minZ, z1) or z1
                        maxZ = maxZ and math.max(maxZ, z2) or z2
                        found = true
                    end
                end
                if found then
                    return Vector3.new((minX + maxX) * 0.5, maxY + 5, (minZ + maxZ) * 0.5)
                end
            end

            local map = workspace:FindFirstChild("__MAP")
            if not map then return nil end

            local pads = map:FindFirstChild("Teleports")
            local pad = pads and pads:FindFirstChild(areaName)
            if pad then
                local okPad, padCf, padSize = pcall(function() return pad:GetBoundingBox() end)
                if okPad and typeof(padCf) == "CFrame" and typeof(padSize) == "Vector3" then
                    local p = padCf.Position
                    return Vector3.new(p.X, p.Y + padSize.Y * 0.5 + 5, p.Z)
                end
            end

            local areas = map:FindFirstChild("Areas")
            local areaFolder = areas and areas:FindFirstChild(areaName)
            if areaFolder then
                local minX, maxX, minY, minZ, maxZ
                local found = false
                for _, part in ipairs(areaFolder:GetDescendants()) do
                    if part:IsA("BasePart") then
                        local p = part.Position
                        minX = minX and math.min(minX, p.X) or p.X
                        maxX = maxX and math.max(maxX, p.X) or p.X
                        minY = minY and math.min(minY, p.Y) or p.Y
                        minZ = minZ and math.min(minZ, p.Z) or p.Z
                        maxZ = maxZ and math.max(maxZ, p.Z) or p.Z
                        found = true
                    end
                end
                if found then
                    return Vector3.new((minX + maxX) * 0.5, minY + 5, (minZ + maxZ) * 0.5)
                end
            end

            return nil
        end

        -- WorldCmds.Load sends "Request World" through Network.Invoke, which is
        -- hard-coded to ignore executor callers. Only that single upvalue inside
        -- loadWorldInner gets swapped for a proxy that calls the raw RemoteFunction,
        -- then it is put straight back. Nothing global is touched.
        local function loadWorldSafely(worldName)
            if type(executorGetUpvalues) ~= "function" or type(executorSetupValue) ~= "function" then
                return false
            end

            local okInner, inner = pcall(function()
                return executorGetUpvalues(Library.WorldCmds.Load)[1]
            end)
            if not okInner or type(inner) ~= "function" then
                return false
            end

            local okNet, networkTable = pcall(function()
                return executorGetUpvalues(inner)[10]
            end)
            if not okNet or type(networkTable) ~= "table" then
                return false
            end

            local originalInvoke = networkTable.Invoke
            if type(originalInvoke) ~= "function" then
                return false
            end

            local proxy = setmetatable({}, {
                __index = function(_, key)
                    if key == "Invoke" then
                        return function(name, argument)
                            if name ~= "Request World" then
                                return originalInvoke(name, argument)
                            end
                            local okRemote, remote = pcall(function()
                                return executorGetUpvalues(originalInvoke)[2](name)
                            end)
                            if not okRemote or typeof(remote) ~= "Instance" then
                                return false
                            end
                            local okCall, result = pcall(function()
                                return remote:InvokeServer(argument)
                            end)
                            if not okCall then return false end
                            return result
                        end
                    end
                    return networkTable[key]
                end,
            })

            local patched = pcall(executorSetupValue, inner, 10, proxy)
            local okLoad, result = pcall(Library.WorldCmds.Load, worldName)
            if patched then
                pcall(executorSetupValue, inner, 10, networkTable)
            end

            if not okLoad then
                return false
            end
            return result == true
        end

        -- Exposed for the teleport workflow (see sharedLoadWorldSafely above).
        sharedGetAreaCenter = getAreaCenter
        sharedLoadWorldSafely = loadWorldSafely

        local teleportBusy = false
        sharedIsTeleportBusy = function() return teleportBusy end

        local function waitForAreaCenter(areaName, timeout)
            local deadline = os.clock() + (timeout or 10)
            while os.clock() < deadline do
                local center = getAreaCenter(areaName)
                if center then return center end
                taskWait(0.25)
            end
            return nil
        end

        local function teleportToArea(areaName)
            if teleportBusy then
                setTeleportStatus("A teleport is already running...", TP_WARN_COLOR)
                return
            end

            local areaData = Library.Directory.Areas and Library.Directory.Areas[areaName]
            local targetWorld = type(areaData) == "table" and areaData.world or nil
            local currentWorld = nil
            pcall(function() currentWorld = Library.WorldCmds.Get() end)

            local _, root = getCharacterRoot()
            if not root then
                setTeleportStatus("Character is not loaded yet.", TP_WARN_COLOR)
                return
            end

            -- Same world: just move, the map is already streamed in.
            if not targetWorld or targetWorld == currentWorld then
                local center = getAreaCenter(areaName)
                if not center then
                    setTeleportStatus("Could not locate " .. areaName .. " in this world.", TP_WARN_COLOR)
                    return
                end
                pcall(function() root.CFrame = CFrame.new(center) end)
                setTeleportStatus("Teleported to " .. areaName .. ".", TP_OK_COLOR)
                return
            end

            -- Loading a disabled world would silently dump the player into Spawn,
            -- so refuse up front instead of yanking them across the map.
            local worldData = Library.Directory.Worlds and Library.Directory.Worlds[targetWorld]
            if type(worldData) ~= "table" or worldData.disabled == true or worldData.releasedToPlayers == false then
                setTeleportStatus(tostring(targetWorld) .. " is disabled in-game right now.", TP_WARN_COLOR)
                return
            end

            teleportBusy = true
            setTeleportStatus("Loading " .. tostring(targetWorld) .. " for " .. areaName .. "...", activeTheme.accent)

            taskSpawn(function()
                local okRun, runError = pcall(function()
                    local loaded = loadWorldSafely(targetWorld)
                    local landedWorld = nil
                    pcall(function() landedWorld = Library.WorldCmds.Get() end)

                    if not loaded or landedWorld ~= targetWorld then
                        teleportBusy = false
                        setTeleportStatus(tostring(targetWorld) .. " is not available right now.", TP_WARN_COLOR)
                        return
                    end

                    local center = waitForAreaCenter(areaName, 10)
                    taskWait(0.35)

                    local _, newRoot = getCharacterRoot()
                    if not newRoot then
                        teleportBusy = false
                        setTeleportStatus("Character is still respawning. Try again.", TP_WARN_COLOR)
                        return
                    end

                    if not center then
                        teleportBusy = false
                        setTeleportStatus("Loaded " .. tostring(targetWorld) .. ", but " .. areaName .. " has no spawn point.", TP_WARN_COLOR)
                        return
                    end

                    pcall(function() newRoot.CFrame = CFrame.new(center) end)
                    teleportBusy = false
                    setTeleportStatus("Teleported to " .. areaName .. " in " .. tostring(targetWorld) .. ".", TP_OK_COLOR)
                end)

                -- Never leave the busy flag stuck if something upstream throws.
                if not okRun then
                    teleportBusy = false
                    setTeleportStatus("Teleport failed: " .. tostring(runError), TP_WARN_COLOR)
                end
            end)
        end

        -- Build the world -> areas table straight from the game's directory so the
        -- list is complete and stays correct if the game adds areas later.
        local groupedAreas = {}
        local sortedWorlds = {}
        do
            local directory = Library.Directory
            local directoryAreas = directory and directory.Areas
            if type(directoryAreas) == "table" then
                for areaName, areaData in pairs(directoryAreas) do
                    if type(areaName) == "string"
                        and type(areaData) == "table"
                        and type(areaData.world) == "string" then
                        local list = groupedAreas[areaData.world]
                        if not list then
                            list = {}
                            groupedAreas[areaData.world] = list
                            table.insert(sortedWorlds, areaData.world)
                        end
                        table.insert(list, areaName)
                    end
                end
            end

            local function worldOrder(worldName)
                local data = Library.Directory.Worlds and Library.Directory.Worlds[worldName]
                local id = type(data) == "table" and tonumber(data.id) or nil
                if id then return id end
                return 999
            end

            local function areaOrder(areaName)
                local data = directoryAreas[areaName]
                local order = type(data) == "table" and tonumber(data.luckyOrder or data.id) or nil
                if order then return order end
                return 9999
            end

            table.sort(sortedWorlds, function(a, b)
                local oa, ob = worldOrder(a), worldOrder(b)
                if oa ~= ob then return oa < ob end
                return a < b
            end)

            for _, worldName in ipairs(sortedWorlds) do
                table.sort(groupedAreas[worldName], function(a, b)
                    local oa, ob = areaOrder(a), areaOrder(b)
                    if oa ~= ob then return oa < ob end
                    return a < b
                end)
            end
        end

        local expandedWorld = nil
        do
            local okWorld, world = pcall(function() return Library.WorldCmds.Get() end)
            if okWorld and type(world) == "string" then
                expandedWorld = world
            end
        end

        local function styleTeleportRow(row)
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 6)
            corner.Parent = row

            local stroke = Instance.new("UIStroke")
            stroke.Color = activeTheme.stroke
            stroke.Thickness = 1
            stroke.Transparency = 0.7
            stroke.Parent = row

            local baseColor = row.BackgroundColor3
            local hoverColor = baseColor:Lerp(activeTheme.accent, 0.14)

            row.MouseEnter:Connect(function()
                if row:GetAttribute("RowActive") then return end
                row.BackgroundColor3 = hoverColor
            end)
            row.MouseLeave:Connect(function()
                if row:GetAttribute("RowActive") then return end
                row.BackgroundColor3 = baseColor
            end)

            return stroke
        end

        -- Rebuilding the list on expand/collapse keeps the layout exact and avoids
        -- invisible rows still taking up space.
        local function renderTeleportList()
            for _, child in ipairs(tpScroll:GetChildren()) do
                if child ~= tpLayout and child ~= tpPadding then
                    child:Destroy()
                end
            end

            local order = 0
            for _, worldName in ipairs(sortedWorlds) do
                local areaNames = groupedAreas[worldName]
                local isOpen = expandedWorld == worldName

                order = order + 1

                local header = Instance.new("TextButton")
                header.Size = UDim2.new(1, -8, 0, 32)
                header.BackgroundColor3 = isOpen and activeTheme.controlOn or activeTheme.surface
                header.TextColor3 = Color3.fromRGB(255, 255, 255)
                header.Text = (isOpen and "[-]  " or "[+]  ") .. worldName .. "   (" .. #areaNames .. " areas)"
                header.Font = Enum.Font.GothamBold
                header.TextSize = 13
                header.TextXAlignment = Enum.TextXAlignment.Left
                header.LayoutOrder = order
                header:SetAttribute("RowActive", isOpen)
                header.Parent = tpScroll

                do
                    local headerPadding = Instance.new("UIPadding")
                    headerPadding.PaddingLeft = UDim.new(0, 10)
                    headerPadding.Parent = header
                end

                local headerStroke = styleTeleportRow(header)
                if isOpen then
                    headerStroke.Transparency = 0.3
                end

                header.MouseButton1Click:Connect(function()
                    -- Clicking the open world again collapses it.
                    if expandedWorld == worldName then
                        expandedWorld = nil
                    else
                        expandedWorld = worldName
                    end
                    defer(renderTeleportList)
                end)

                if isOpen then
                    for _, areaName in ipairs(areaNames) do
                        order = order + 1

                        local areaButton = Instance.new("TextButton")
                        areaButton.Size = UDim2.new(1, -22, 0, 30)
                        areaButton.BackgroundColor3 = activeTheme.surface
                        areaButton.TextColor3 = Color3.fromRGB(225, 228, 235)
                        areaButton.Text = areaName
                        areaButton.TextXAlignment = Enum.TextXAlignment.Left
                        areaButton.Font = Enum.Font.GothamSemibold
                        areaButton.TextSize = 12
                        areaButton.LayoutOrder = order
                        areaButton.Parent = tpScroll

                        do
                            local areaPadding = Instance.new("UIPadding")
                            areaPadding.PaddingLeft = UDim.new(0, 14)
                            areaPadding.Parent = areaButton
                        end

                        styleTeleportRow(areaButton)

                        areaButton.MouseButton1Click:Connect(function()
                            teleportToArea(areaName)
                        end)
                    end
                end
            end

            if #sortedWorlds == 0 then
                do
                    local emptyLabel = Instance.new("TextLabel")
                    emptyLabel.Size = UDim2.new(1, -8, 0, 24)
                    emptyLabel.BackgroundTransparency = 1
                    emptyLabel.Text = "World list unavailable."
                    emptyLabel.TextColor3 = TP_WARN_COLOR
                    emptyLabel.Font = Enum.Font.GothamSemibold
                    emptyLabel.TextSize = 12
                    emptyLabel.TextXAlignment = Enum.TextXAlignment.Left
                    emptyLabel.Parent = tpScroll
                end
            end
        end

        renderTeleportList()
    end

    buildTeleportTab()

    -- =====================================================================
    -- AUTO FARM TAB
    -- Teleports to a chosen area, switches on the game's own Auto Farm, then
    -- auto-hatches the chosen egg. The driver loop re-asserts both whenever
    -- the engine drops them (world change / re-capture).
    --
    -- Wrapped in a named function because Luau caps a function at 200
    -- registers; the UI thread that builds every tab already sits near the
    -- cap and this tab's own frame/dropdown construction pushes it over.
    -- =====================================================================
    TAB_TOTAL.buildAutoFarm = function()
        -- Local alias for the shared frame; keeps this function's body
        -- readable without polluting the UI thread's register budget.
        local autoFarmFrame = TAB_TOTAL.autoFarmFrame
        local afStatus = Instance.new("TextLabel")
        afStatus.Size = UDim2.new(1, 0, 0, 20)
        afStatus.Position = UDim2.fromOffset(0, 608)
        afStatus.BackgroundTransparency = 1
        afStatus.Text = "Ready."
        afStatus.TextColor3 = Color3.fromRGB(170, 175, 185)
        afStatus.Font = Enum.Font.GothamSemibold
        afStatus.TextSize = 11
        afStatus.TextXAlignment = Enum.TextXAlignment.Left
        afStatus.TextTruncate = Enum.TextTruncate.AtEnd
        afStatus.Parent = autoFarmFrame

        local AF_OK = Color3.fromRGB(120, 220, 150)
        local AF_WARN = Color3.fromRGB(255, 170, 70)
        local AF_ACCENT = Color3.fromRGB(120, 205, 255)

        local function setAfStatus(text, color)
            afStatus.Text = text
            afStatus.TextColor3 = color or Color3.fromRGB(170, 175, 185)
        end

        -- Area dropdown state. Populated from the live directory each time the
        -- tab is opened so new worlds show up without a reload.
        local afAreaOptions = nil -- { names = {..}, frames = {..} }, rebuilt on open
        local afAreaSelect
        local afAreaList

        local function buildAreaOptions()
            if afAreaList then
                for _, child in ipairs(afAreaList:GetChildren()) do
                    if child:IsA("TextButton") then child:Destroy() end
                end
            end
            local names = {}
            local areas = Library.Directory.Areas
            if type(areas) == "table" then
                for name in pairs(areas) do names[#names + 1] = tostring(name) end
            end
            table.sort(names)
            afAreaOptions = { names = names }
        end

        -- Egg dropdown state. Only hatchable eggs (engine can actually buy
        -- them), sorted alphabetically.
        local afEggOptions = nil
        local afEggSelect
        local afEggList

        local function buildEggOptions()
            if afEggList then
                for _, child in ipairs(afEggList:GetChildren()) do
                    if child:IsA("TextButton") then child:Destroy() end
                end
            end
            local names = {}
            local eggs = Library.Directory.Eggs
            if type(eggs) == "table" then
                for name, def in pairs(eggs) do
                    if type(def) == "table" and def.hatchable == true then
                        names[#names + 1] = tostring(name)
                    end
                end
            end
            table.sort(names)
            afEggOptions = { names = names }
        end

        -- Shared helpers may not exist yet if something re-runs before the
        -- teleport tab builds; guard every use.
        local function afGetRoot()
            if sharedGetCharacterRoot then
                local _, root = sharedGetCharacterRoot()
                if root then return root end
            end
            local character = localPlayer.Character
            return character and character:FindFirstChild("HumanoidRootPart")
        end

        local function afCurrentWorld()
            local ok, world = pcall(function() return Library.WorldCmds.Get() end)
            return ok and world or nil
        end

        local function afWorldForArea(areaName)
            local areas = Library.Directory.Areas
            local def = type(areas) == "table" and areas[areaName] or nil
            return type(def) == "table" and def.world or nil
        end

        -- Teleport to the area center, loading its world first if needed.
        local function afSteerToArea(areaName)
            if not areaName then return false end
            local root = afGetRoot()
            if not root then return false end

            local targetWorld = afWorldForArea(areaName)
            local currentWorld = afCurrentWorld()

            if targetWorld and currentWorld and targetWorld ~= currentWorld then
                if not sharedLoadWorldSafely then return false end
                local ok, loaded = pcall(sharedLoadWorldSafely, targetWorld)
                if not ok or loaded ~= true then return false end
                taskWait(1.5)
                root = afGetRoot()
                if not root then return false end
            end

            if sharedGetAreaCenter then
                local center = sharedGetAreaCenter(areaName)
                if center then
                    pcall(function() root.CFrame = CFrame.new(center) end)
                    return true
                end
            end
            return false
        end

        -- Teleport to the chosen egg's capsule. Capsules live under
        -- Workspace.__MAP.Eggs.<area>.Eggs, so questFindEggCapsule (which
        -- matches on the ID attribute) returns the model and we park the
        -- player a few studs above it - the same offset the quest driver
        -- uses. Returns false when the capsule is not streamed in yet so
        -- the caller can retry it inside the watchdog loop.
        local function afSteerToEgg(eggName)
            if not eggName then return false end
            local capsule = questFindEggCapsule(eggName)
            if not capsule then return false end
            local part = capsule.PrimaryPart or capsule:FindFirstChildWhichIsA("BasePart")
            local root = afGetRoot()
            if not part or not root then return false end
            pcall(function()
                root.CFrame = CFrame.new(part.Position + Vector3.new(0, 5, 0))
            end)
            return true
        end

        -- Enable the game's own Auto Farm via the shared manager so the
        -- engine's Tick loop captures the current area on its next tick.
        local function afEnableGameFarm()
            local ok, enabled = pcall(function() return Library.Variables.AutoFarmEnabled end)
            if ok and enabled == true then return true end
            local res = questSetGameAutoFarm(true)
            return res == true
        end

        local function afDisableGameFarm()
            local ok, enabled = pcall(function() return Library.Variables.AutoFarmEnabled end)
            if ok and enabled == false then return end
            questSetGameAutoFarm(false)
        end

        -- Driver state
        local afRunning = false
        local afSelectedArea = nil
        local afSelectedEgg = nil
        local afToggleBtn = nil

        -- Rebuild the two dropdown lists each time the toggle flips on, so the
        -- freshest area/egg sets are always used.
        local function afRefreshLists()
            buildAreaOptions()
            buildEggOptions()
        end

        -- The main workflow, run once per toggle-on.
        local function afStart()
            afRunning = true
            local area = afSelectedArea
            local egg = afSelectedEgg

            if not area then
                setAfStatus("Pick an area first.", AF_WARN)
                afRunning = false
                AutoFarmTabActive = false
                if afToggleBtn then
                    afToggleBtn:SetAttribute("ToggleState", false)
                    afToggleBtn.BackgroundColor3 = Color3.fromRGB(67, 104, 145)
                    afToggleBtn.Text = "AUTO FARM: OFF"
                end
                return
            end

            -- 1. Teleport to the area.
            setAfStatus("Teleporting to " .. area .. "...", AF_ACCENT)
            local moved = afSteerToArea(area)
            if not moved then
                setAfStatus("Teleport to " .. area .. " failed.", AF_WARN)
                afRunning = false
                AutoFarmTabActive = false
                if afToggleBtn then
                    afToggleBtn:SetAttribute("ToggleState", false)
                    afToggleBtn.BackgroundColor3 = Color3.fromRGB(67, 104, 145)
                    afToggleBtn.Text = "AUTO FARM: OFF"
                end
                return
            end

            -- 2. Let the character and area finish loading before Auto Farm
            --    captures its area. The player is still at the area's centre.
            setAfStatus("Settling in " .. area .. " (3 seconds)...", AF_ACCENT)
            taskWait(3)
            if not afRunning or not AutoFarmTabActive then return end

            -- Force a clean capture of the selected area, then enable the
            -- game's Auto Farm from the centre of that area.
            setAfStatus("Enabling Auto Farm in " .. area .. "...", AF_ACCENT)
            if type(questSetGameAutoFarm) == "function" then
                pcall(questSetGameAutoFarm, false)
                taskWait(0.6)
            end
            local farmOk = afEnableGameFarm()
            if not farmOk then
                setAfStatus("Could not enable Auto Farm.", AF_WARN)
            end

            -- Keep the player at the area centre for a few seconds after
            -- Auto Farm is enabled so its capture/engine can initialize.
            setAfStatus("Auto Farm starting in " .. area .. " (3 seconds)...", AF_ACCENT)
            taskWait(3)
            if not afRunning or not AutoFarmTabActive then return end

            -- 3. Target the chosen egg for auto-hatch.
            if egg then
                AutoFarmTabTargetEgg = egg
                setAfStatus("Auto Farm on in " .. area .. " | hatching " .. egg, AF_OK)
            else
                AutoFarmTabTargetEgg = nil
                setAfStatus("Auto Farm on in " .. area, AF_OK)
            end

            -- 3b. Teleport onto the chosen egg capsule now that auto farm is
            --     running in the area, so hatching happens at the egg itself.
            --     If the capsule is not streamed in yet, the watchdog below
            --     keeps retrying until it is.
            if egg then
                setAfStatus("Teleporting to " .. egg .. "...", AF_ACCENT)
                local eggMoved = afSteerToEgg(egg)
                taskWait(0.6)
                if not eggMoved then
                    setAfStatus("Waiting for " .. egg .. " capsule...", AF_WARN)
                end
            end

            -- setAutoHatchState is the canonical toggle for the engine-driven
            -- auto-hatch loop; never fall back to mutating AutoBuying directly
            -- because that local lives at script scope and the watchdog loop
            -- is the only safe writer outside setAutoHatchState.
            if type(setAutoHatchState) == "function" then
                pcall(setAutoHatchState, true)
            end

            -- 4. Watchdog. Re-assert farm + hatch target while the toggle is on.
            taskSpawn(function()
                local recaptureLeft = 3
                local lastFlipAt = 0
                while afRunning do
                    if not AutoFarmTabActive or afRunning ~= true then break end
                    local ok, enabled = pcall(function() return Library.Variables.AutoFarmEnabled end)
                    if not ok or enabled ~= true then
                        questSetGameAutoFarm(true)
                    else
                        -- The engine only re-captures after a world change, so
                        -- when the player moved to a different area it keeps its
                        -- stale capture. Flip off one tick to clear it, then on
                        -- again to re-capture at the new location. Bounded so an
                        -- area with no breakable zones cannot jitter forever.
                        local okArea, captured = pcall(function() return Library.Variables.AutoFarmArea end)
                        if okArea and recaptureLeft > 0
                            and captured and tostring(captured) ~= area then
                            if os.clock() - lastFlipAt > 3 then
                                lastFlipAt = os.clock()
                                recaptureLeft = recaptureLeft - 1
                                questSetGameAutoFarm(false)
                                taskWait(0.5)
                                questSetGameAutoFarm(true)
                            end
                        end
                    end
                    if egg and AutoFarmTabTargetEgg ~= egg then
                        AutoFarmTabTargetEgg = egg
                    end
                    -- Keep the player parked on the chosen egg capsule so
                    -- auto-hatch stays in buy range even if the area's Auto
                    -- Farm, world changes or the anti-AFK jog nudged them off.
                    if egg then
                        local capsule = questFindEggCapsule(egg)
                        if capsule then
                            local part = capsule.PrimaryPart or capsule:FindFirstChildWhichIsA("BasePart")
                            local root = afGetRoot()
                            if part and root and (root.Position - part.Position).Magnitude > 20 then
                                pcall(function()
                                    root.CFrame = CFrame.new(part.Position + Vector3.new(0, 5, 0))
                                end)
                            end
                        else
                            -- Capsule not streamed in: re-park once more now
                            -- instead of waiting for the next watchdog tick.
                            afSteerToEgg(egg)
                        end
                    end
                    if type(setAutoHatchState) == "function" and not AutoBuying then
                        pcall(setAutoHatchState, true)
                    end
                    taskWait(1.5)
                end
            end)
        end

        local function afStop()
            afRunning = false
            AutoFarmTabActive = false
            AutoFarmTabTargetEgg = nil
            if type(setAutoHatchState) == "function" then
                pcall(setAutoHatchState, false)
            end
            afDisableGameFarm()
            setAfStatus("Stopped.", Color3.fromRGB(170, 175, 185))
        end

        -- Toggle lives near the top of the tab.
        afToggleBtn = Instance.new("TextButton")
        afToggleBtn.Name = "AutoFarmToggle"
        afToggleBtn.Size = UDim2.new(1, 0, 0, 42)
        afToggleBtn.Position = UDim2.new(0, 0, 0, 8)
        afToggleBtn.BackgroundColor3 = Color3.fromRGB(67, 104, 145)
        afToggleBtn.Text = "AUTO FARM: OFF"
        afToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        afToggleBtn.Font = Enum.Font.GothamBold
        afToggleBtn.TextSize = 14
        afToggleBtn:SetAttribute("ThemeRole", "Toggle")
        afToggleBtn:SetAttribute("ToggleState", false)
        afToggleBtn.Parent = autoFarmFrame

        do
            local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = afToggleBtn
        end
        do
            local s = Instance.new("UIStroke"); s.Color = activeTheme.stroke; s.Thickness = 1; s.Transparency = 0.7; s.Parent = afToggleBtn
        end

        -- Auto Farm tab active flag, so the watchdog only runs while the tab
        -- is driving (also gates currentHatchEggId's override).
        AutoFarmTabActive = false

        afToggleBtn.MouseButton1Click:Connect(function()
            if afRunning then
                afStop()
                local on = false
                afToggleBtn.BackgroundColor3 = on and Color3.fromRGB(20, 190, 126) or Color3.fromRGB(67, 104, 145)
                afToggleBtn.Text = "AUTO FARM: " .. (on and "ON" or "OFF")
                afToggleBtn:SetAttribute("ToggleState", on)
                AutoFarmTabActive = on
                SetSetting("autoFarmOn", false)
                saveSettings()
            else
                -- Flip state immediately so the button reflects that a run
                -- started, then drive the (slow) teleport workflow off-thread.
                afRunning = true
                AutoFarmTabActive = true
                local on = true
                afToggleBtn.BackgroundColor3 = on and Color3.fromRGB(20, 190, 126) or Color3.fromRGB(67, 104, 145)
                afToggleBtn.Text = "AUTO FARM: " .. (on and "ON" or "OFF")
                afToggleBtn:SetAttribute("ToggleState", on)
                afRefreshLists()
                -- Remember the run (toggle + chosen area + chosen egg) so a
                -- rejoin restores the exact same farm setup automatically.
                SetSetting("autoFarmOn", true)
                SetSetting("autoFarmArea", afSelectedArea)
                SetSetting("autoFarmEgg", afSelectedEgg)
                saveSettings()
                taskSpawn(function()
                    pcall(afStart)
                end)
            end
        end)

        -- Area select label (opens the dropdown list)
        do
            local afAreaLabel = Instance.new("TextLabel")
            afAreaLabel.Size = UDim2.new(1, 0, 0, 20)
            afAreaLabel.Position = UDim2.new(0, 0, 0, 62)
            afAreaLabel.BackgroundTransparency = 1
            afAreaLabel.Text = "FARM AREA"
            afAreaLabel.TextColor3 = Color3.fromRGB(190, 200, 215)
            afAreaLabel.Font = Enum.Font.GothamBold
            afAreaLabel.TextSize = 11
            afAreaLabel.TextXAlignment = Enum.TextXAlignment.Left
            afAreaLabel.Parent = autoFarmFrame

            afAreaSelect = Instance.new("TextButton")
            afAreaSelect.Name = "AutoFarmAreaSelect"
            afAreaSelect.Size = UDim2.new(1, 0, 0, 34)
            afAreaSelect.Position = UDim2.new(0, 0, 0, 84)
            afAreaSelect.BackgroundColor3 = activeTheme.surface
            afAreaSelect.TextColor3 = Color3.fromRGB(235, 238, 245)
            afAreaSelect.Font = Enum.Font.GothamBold
            afAreaSelect.TextSize = 12
            afAreaSelect.TextXAlignment = Enum.TextXAlignment.Left
            afAreaSelect.Text = "Select area..."
            afAreaSelect.Parent = autoFarmFrame
            do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = afAreaSelect end
            do local s = Instance.new("UIStroke"); s.Color = activeTheme.stroke; s.Thickness = 1; s.Transparency = 0.7; s.Parent = afAreaSelect end
            local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.Parent = afAreaSelect
        end

        -- Area dropdown list (hidden until the select is clicked)
        afAreaList = Instance.new("ScrollingFrame")
        afAreaList.Name = "AutoFarmAreaList"
        afAreaList.Size = UDim2.new(1, 0, 0, 160)
        afAreaList.Position = UDim2.new(0, 0, 0, 120)
        afAreaList.BackgroundColor3 = Color3.fromRGB(30, 34, 44)
        afAreaList.BorderSizePixel = 0
        afAreaList.ScrollBarThickness = 4
        afAreaList.Visible = false
        afAreaList.ZIndex = 20
        afAreaList.CanvasSize = UDim2.new(0, 0, 0, 0)
        afAreaList.AutomaticCanvasSize = Enum.AutomaticSize.Y
        afAreaList.Parent = autoFarmFrame
        local afAreaListLayout = Instance.new("UIListLayout")
        afAreaListLayout.Padding = UDim.new(0, 1)
        afAreaListLayout.SortOrder = Enum.SortOrder.LayoutOrder
        afAreaListLayout.Parent = afAreaList

        local afAreaSearch = Instance.new("TextBox")
        afAreaSearch.Name = "FarmAreaSearch"
        afAreaSearch.Size = UDim2.new(1, -6, 0, 30)
        afAreaSearch.BackgroundColor3 = activeTheme.surface
        afAreaSearch.TextColor3 = Color3.fromRGB(235, 238, 245)
        afAreaSearch.PlaceholderColor3 = Color3.fromRGB(145, 155, 170)
        afAreaSearch.PlaceholderText = "Search farm area..."
        afAreaSearch.Text = ""
        afAreaSearch.ClearTextOnFocus = false
        afAreaSearch.Font = Enum.Font.Gotham
        afAreaSearch.TextSize = 11
        afAreaSearch.TextXAlignment = Enum.TextXAlignment.Left
        afAreaSearch.LayoutOrder = 0
        afAreaSearch.ZIndex = 21
        afAreaSearch.Parent = afAreaList
        do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 5); c.Parent = afAreaSearch end
        do local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 8); pad.Parent = afAreaSearch end

        local function renderAreaList()
            for _, child in ipairs(afAreaList:GetChildren()) do
                if child ~= afAreaListLayout and child ~= afAreaSearch then child:Destroy() end
            end
            if not afAreaOptions then buildAreaOptions() end
            local query = afAreaSearch.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
            local shown = 0
            for i, name in ipairs(afAreaOptions.names) do
                if query == "" or name:lower():find(query, 1, true) then
                    shown = shown + 1
                    local row = Instance.new("TextButton")
                    row.Size = UDim2.new(1, -6, 0, 26)
                    row.ZIndex = 21
                    row.BackgroundTransparency = 1
                    row.TextColor3 = Color3.fromRGB(230, 233, 240)
                    row.Text = name
                    row.Font = Enum.Font.Gotham
                    row.TextSize = 11
                    row.TextXAlignment = Enum.TextXAlignment.Left
                    row.LayoutOrder = shown
                    row.Parent = afAreaList

                    row.MouseButton1Click:Connect(function()
                        afSelectedArea = name
                        afAreaSelect.Text = "Area: " .. name
                        afAreaList.Visible = false
                        SetSetting("autoFarmArea", name)
                        saveSettings()
                    end)
                end
            end
            if shown == 0 then
                local empty = Instance.new("TextLabel")
                empty.Size = UDim2.new(1, -8, 0, 26)
                empty.BackgroundTransparency = 1
                empty.Text = "No matching areas"
                empty.TextColor3 = Color3.fromRGB(170, 175, 185)
                empty.Font = Enum.Font.Gotham
                empty.TextSize = 11
                empty.LayoutOrder = 1
                empty.ZIndex = 21
                empty.Parent = afAreaList
            end
        end

        afAreaSearch:GetPropertyChangedSignal("Text"):Connect(function()
            if afAreaList.Visible then renderAreaList() end
        end)

        afAreaSelect.MouseButton1Click:Connect(function()
            afEggList.Visible = false
            if afAreaList.Visible then
                afAreaList.Visible = false
            else
                if not afAreaOptions then afRefreshLists() end
                renderAreaList()
                afAreaList.Visible = true
            end
        end)

        -- Egg select label + dropdown
        do
            local afEggLabel = Instance.new("TextLabel")
            afEggLabel.Size = UDim2.new(1, 0, 0, 20)
            afEggLabel.Position = UDim2.new(0, 0, 0, 302)
            afEggLabel.BackgroundTransparency = 1
            afEggLabel.Text = "HATCH TARGET (EGG)"
            afEggLabel.TextColor3 = Color3.fromRGB(190, 200, 215)
            afEggLabel.Font = Enum.Font.GothamBold
            afEggLabel.TextSize = 11
            afEggLabel.TextXAlignment = Enum.TextXAlignment.Left
            afEggLabel.Parent = autoFarmFrame

            afEggSelect = Instance.new("TextButton")
            afEggSelect.Name = "AutoFarmEggSelect"
            afEggSelect.Size = UDim2.new(1, 0, 0, 34)
            afEggSelect.Position = UDim2.new(0, 0, 0, 324)
            afEggSelect.BackgroundColor3 = activeTheme.surface
            afEggSelect.TextColor3 = Color3.fromRGB(235, 238, 245)
            afEggSelect.Font = Enum.Font.GothamBold
            afEggSelect.TextSize = 12
            afEggSelect.TextXAlignment = Enum.TextXAlignment.Left
            afEggSelect.Text = "Select egg..."
            afEggSelect.Parent = autoFarmFrame
            do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = afEggSelect end
            do local s = Instance.new("UIStroke"); s.Color = activeTheme.stroke; s.Thickness = 1; s.Transparency = 0.7; s.Parent = afEggSelect end
            local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.Parent = afEggSelect
        end

        afEggList = Instance.new("ScrollingFrame")
        afEggList.Name = "AutoFarmEggList"
        afEggList.Size = UDim2.new(1, 0, 0, 180)
        afEggList.Position = UDim2.new(0, 0, 0, 360)
        afEggList.BackgroundColor3 = Color3.fromRGB(30, 34, 44)
        afEggList.BorderSizePixel = 0
        afEggList.ScrollBarThickness = 4
        afEggList.Visible = false
        afEggList.ZIndex = 20
        afEggList.CanvasSize = UDim2.new(0, 0, 0, 0)
        afEggList.AutomaticCanvasSize = Enum.AutomaticSize.Y
        afEggList.Parent = autoFarmFrame
        local afEggListLayout = Instance.new("UIListLayout")
        afEggListLayout.Padding = UDim.new(0, 1)
        afEggListLayout.SortOrder = Enum.SortOrder.LayoutOrder
        afEggListLayout.Parent = afEggList

        local afEggSearch = Instance.new("TextBox")
        afEggSearch.Name = "HatchTargetEggSearch"
        afEggSearch.Size = UDim2.new(1, -6, 0, 30)
        afEggSearch.BackgroundColor3 = activeTheme.surface
        afEggSearch.TextColor3 = Color3.fromRGB(235, 238, 245)
        afEggSearch.PlaceholderColor3 = Color3.fromRGB(145, 155, 170)
        afEggSearch.PlaceholderText = "Search hatch target egg..."
        afEggSearch.Text = ""
        afEggSearch.ClearTextOnFocus = false
        afEggSearch.Font = Enum.Font.Gotham
        afEggSearch.TextSize = 11
        afEggSearch.TextXAlignment = Enum.TextXAlignment.Left
        afEggSearch.LayoutOrder = 0
        afEggSearch.ZIndex = 21
        afEggSearch.Parent = afEggList
        do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 5); c.Parent = afEggSearch end
        do local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 8); pad.Parent = afEggSearch end

        local function renderEggList()
            for _, child in ipairs(afEggList:GetChildren()) do
                if child ~= afEggListLayout and child ~= afEggSearch then child:Destroy() end
            end
            if not afEggOptions then buildEggOptions() end
            local query = afEggSearch.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
            local shown = 0
            for i, name in ipairs(afEggOptions.names) do
                if query == "" or name:lower():find(query, 1, true) then
                    shown = shown + 1
                    local row = Instance.new("TextButton")
                    row.Size = UDim2.new(1, -6, 0, 26)
                    row.ZIndex = 21
                row.BackgroundTransparency = 1
                row.TextColor3 = Color3.fromRGB(230, 233, 240)
                    row.Text = name
                    row.Font = Enum.Font.Gotham
                    row.TextSize = 11
                    row.TextXAlignment = Enum.TextXAlignment.Left
                    row.LayoutOrder = shown
                    row.Parent = afEggList

                    row.MouseButton1Click:Connect(function()
                        afSelectedEgg = name
                        afEggSelect.Text = "Egg: " .. name
                        afEggList.Visible = false
                        SetSetting("autoFarmEgg", name)
                        saveSettings()
                    end)
                end
            end
            if shown == 0 then
                local empty = Instance.new("TextLabel")
                empty.Size = UDim2.new(1, -8, 0, 26)
                empty.BackgroundTransparency = 1
                empty.Text = "No matching eggs"
                empty.TextColor3 = Color3.fromRGB(170, 175, 185)
                empty.Font = Enum.Font.Gotham
                empty.TextSize = 11
                empty.LayoutOrder = 1
                empty.ZIndex = 21
                empty.Parent = afEggList
            end
        end

        afEggSearch:GetPropertyChangedSignal("Text"):Connect(function()
            if afEggList.Visible then renderEggList() end
        end)

        afEggSelect.MouseButton1Click:Connect(function()
            afAreaList.Visible = false
            if afEggList.Visible then
                afEggList.Visible = false
            else
                if not afEggOptions then afRefreshLists() end
                renderEggList()
                afEggList.Visible = true
            end
        end)

        -- Status hint block
        do
            local afHint = Instance.new("TextLabel")
            afHint.Size = UDim2.new(1, 0, 0, 44)
            afHint.Position = UDim2.new(0, 0, 0, 556)
            afHint.BackgroundTransparency = 1
            afHint.Text = "Pick an area and an egg, then toggle Auto Farm. The script teleports to the area, turns on the game's Auto Farm, and hatches your chosen egg."
            afHint.TextColor3 = Color3.fromRGB(180, 190, 205)
            afHint.Font = Enum.Font.GothamSemibold
            afHint.TextSize = 11
            afHint.TextWrapped = true
            afHint.TextXAlignment = Enum.TextXAlignment.Left
            afHint.TextYAlignment = Enum.TextYAlignment.Top
            afHint.Parent = autoFarmFrame
        end

        -- Stop the watchdog when the tab is closed. The toggle itself lives on
        -- the frame, so users can flip it back on from the tab again.
        autoFarmFrame.AncestryChanged:Connect(function()
            if not autoFarmFrame.Parent then
                AutoFarmTabActive = false
            end
        end)

        -- =====================================================================
        -- PERSISTENCE ACROSS REJOINS
        -- The Auto Farm toggle, chosen area and chosen egg are written to the
        -- settings file every time they change. On load they are restored here:
        -- the dropdowns repopulate, the toggle lights back up, and if it was
        -- ON last time the script starts the whole farm workflow automatically
        -- (area teleport -> auto farm -> egg teleport -> hatch).
        -- =====================================================================
        local savedArea = GetSetting("autoFarmArea")
        local savedEgg = GetSetting("autoFarmEgg")
        local savedOn = GetSetting("autoFarmOn", false)

        if type(savedArea) == "string" and savedArea ~= "" then
            afSelectedArea = savedArea
            afAreaSelect.Text = "Area: " .. savedArea
        end
        if type(savedEgg) == "string" and savedEgg ~= "" then
            afSelectedEgg = savedEgg
            afEggSelect.Text = "Egg: " .. savedEgg
        end

        if savedOn == true then
            -- Restore the button to its ON look immediately. The actual run
            -- starts shortly after so the map and capsule have time to load.
            afToggleBtn.BackgroundColor3 = Color3.fromRGB(20, 190, 126)
            afToggleBtn.Text = "AUTO FARM: ON"
            afToggleBtn:SetAttribute("ToggleState", true)
            afRunning = true
            AutoFarmTabActive = true
            setAfStatus("Restoring auto farm...", AF_ACCENT)
            taskSpawn(function()
                local waited = 0
                while waited < 15 do
                    taskWait(0.5)
                    waited = waited + 0.5
                    if afGetRoot() then break end
                end
                pcall(afStart)
            end)
        end
    end

    TAB_TOTAL.buildAutoFarm()

    -- =====================================================================
    -- AFK ENGINES
-- Group rewards, spinny wheels, potion upgrading/usage and the quest
-- driver. They live inside the UI task (not at the top level) because the
-- quest driver moves the player with the same world-load / area-centre
-- helpers the teleport tab just built.
-- =====================================================================
do
        local function getPlayerRoot()
            if sharedGetCharacterRoot then
                local _, root = sharedGetCharacterRoot()
                if root then return root end
            end
            local character = localPlayer.Character
            return character and character:FindFirstChild("HumanoidRootPart")
        end

        local function getCurrentWorld()
            local ok, world = pcall(function() return Library.WorldCmds.Get() end)
            return ok and world or nil
        end

        local function worldForArea(areaName)
            local areas = Library.Directory.Areas
            local def = type(areas) == "table" and areas[areaName] or nil
            return type(def) == "table" and def.world or nil
        end

        -- Move the player to an area centre, loading its world first when the
        -- area lives somewhere else. Returns true once the move was issued.
        local function steerToArea(areaName)
            if not areaName then return false end
            local root = getPlayerRoot()
            if not root then return false end

            local targetWorld = worldForArea(areaName)
            local currentWorld = getCurrentWorld()

            if targetWorld and currentWorld and targetWorld ~= currentWorld then
                if not sharedLoadWorldSafely then return false end
                local ok, loaded = pcall(sharedLoadWorldSafely, targetWorld)
                if not ok or loaded ~= true then return false end
                taskWait(1.5)
                root = getPlayerRoot()
                if not root then return false end
            end

            if sharedGetAreaCenter then
                local center = sharedGetAreaCenter(areaName)
                if center then
                    pcall(function() root.CFrame = CFrame.new(center) end)
                    return true
                end
            end
            return false
        end

        -- -----------------------------------------------------------------
        -- Auto Group Rewards
        -- The client only claims while standing on the pad, so walk onto it
        -- first, then fire the claim. The pad lives in Spawn/Town (and Fantasy
        -- Isle), so Spawn is loaded when the current map has no pad.
        -- -----------------------------------------------------------------
        taskSpawn(function()
            local function findPad()
                local ok, map = pcall(function() return Library.WorldCmds.GetMap() end)
                if not ok or not map then return nil end
                local interactive = map:FindFirstChild("Interactive")
                if not interactive then return nil end
                local machine = interactive:FindFirstChild("GroupRewards", true)
                if not machine then return nil end
                local pad = machine:FindFirstChild("Pad", true)
                if pad and pad:IsA("BasePart") then return pad end
                return machine:FindFirstChildWhichIsA("BasePart", true)
            end

            while true do
                if not AutoGroupRewards then
                    AfkGroupStatus = "Idle"
                    taskWait(0.5)
                else
                    local ok, state = false, nil
                    if RawNet.invoke then
                        ok, state = RawNet.invoke("Group Rewards: State")
                    end

                    if not ok or type(state) ~= "table" then
                        AfkGroupStatus = "state unavailable"
                        taskWait(5)
                    elseif state.ready then
                        local pad = findPad()
                        if not pad then
                            AfkGroupStatus = "loading Spawn for the pad..."
                            local moved = false
                            if sharedLoadWorldSafely then
                                local okLoad, loaded = pcall(sharedLoadWorldSafely, "Spawn")
                                moved = okLoad and loaded == true
                            end
                            taskWait(moved and 2 or 5)
                        else
                            local root = getPlayerRoot()
                            if not root then
                                AfkGroupStatus = "character not loaded"
                                taskWait(1)
                            else
                                local padPos = pad.Position
                                pcall(function()
                                    root.CFrame = CFrame.new(padPos + Vector3.new(0, pad.Size.Y * 0.5 + 3, 0))
                                end)
                                taskWait(0.4)
                                local okClaim, claimed, message = RawNet.invoke("Group Rewards: Claim")
                                if okClaim and claimed then
                                    AfkGroupStatus = "claimed"
                                else
                                    AfkGroupStatus = "claim failed: " .. tostring(message)
                                end
                                taskWait(3)
                            end
                        end
                    else
                        AfkGroupStatus = "ready in " .. tostring(state.secondsLeft or "?") .. "s"
                        taskWait(15)
                    end
                end
            end
        end)

        -- -----------------------------------------------------------------
        -- Auto Spinny Wheels
        -- One spin per ticket held, per wheel, read straight from the wheel
        -- definition's TicketStat.
        -- -----------------------------------------------------------------
        taskSpawn(function()
            local wheelIds = {}
            for id in pairs(Library.Directory.SpinnyWheels or {}) do
                wheelIds[#wheelIds + 1] = tostring(id)
            end
            table.sort(wheelIds)

            while true do
                if not AutoSpinnyWheels or #wheelIds == 0 then
                    AfkWheelStatus = #wheelIds == 0 and "no wheels in directory" or "Idle"
                    taskWait(0.5)
                else
                    local save = nil
                    pcall(function() save = Library.Save.Get() end)

                    local parts, spun = {}, false
                    for _, wheelId in ipairs(wheelIds) do
                        local def = Library.Directory.SpinnyWheels[wheelId]
                        local stat = type(def) == "table" and def.TicketStat or nil
                        local tickets = 0
                        if stat and type(save) == "table" then
                            tickets = tonumber(save[stat]) or 0
                        end
                        parts[#parts + 1] = string.format("%s:%d", wheelId, tickets)

                        if tickets >= 1 and RawNet.invoke then
                            local ok, result = RawNet.invoke("Spinny Wheel: Request Spin", wheelId)
                            if ok and result ~= nil and result ~= false then
                                spun = true
                            end
                            taskWait(0.35)
                        end
                    end

                    AfkWheelStatus = table.concat(parts, "  ")
                    taskWait(spun and 0.5 or 5)
                end
            end
        end)

        -- -----------------------------------------------------------------
        -- Auto Upgrade Potions
        -- Reads the machine's own config so "needs N to make one" and the
        -- per-press cap always track the live build. Upgrades every family;
        -- only the max tier is ever drunk (see below).
        -- -----------------------------------------------------------------
        local function buildUpgradePlan()
            local machine = Library.Shared and Library.Shared.PotionUpgradeMachine
            if type(machine) ~= "table" then return {} end

            local okSave, save = pcall(function() return Library.Save.Get() end)
            if not okSave or type(save) ~= "table" or type(save.Items) ~= "table" then return {} end

            local directory = Library.Directory.Items
            local familyTiers = {}
            for key, def in pairs(directory) do
                if type(def) == "table" and def.potion and tonumber(def.tier) then
                    local family = familyTiers[def.potion]
                    if not family then family = {}; familyTiers[def.potion] = family end
                    family[tonumber(def.tier)] = key
                end
            end

            local excluded = machine.ExcludedFamilies
            local perTier = machine.PerTier or {}
            local plan = {}
            for key, count in pairs(save.Items) do
                local def = directory[key]
                if type(def) == "table" and def.potion and tonumber(def.tier) then
                    local tier = tonumber(def.tier)
                    local family = familyTiers[def.potion]
                    local nextKey = family and family[tier + 1]
                    local need = perTier[tier]
                    local blocked = type(excluded) == "table" and excluded[def.potion]
                    if nextKey and need and not blocked then
                        local upgrades = math.floor((tonumber(count) or 0) / need)
                        if upgrades > 0 then
                            plan[#plan + 1] = { key = key, upgrades = upgrades }
                        end
                    end
                end
            end
            return plan
        end

        taskSpawn(function()
            while true do
                if not AutoPotionUpgrade then
                    AfkPotionStatus = "Idle"
                    taskWait(0.5)
                else
                    local plan = buildUpgradePlan()
                    if #plan == 0 then
                        AfkPotionStatus = "nothing to upgrade"
                        taskWait(10)
                    else
                        local cap = tonumber(Library.Shared.PotionUpgradeMachine.MaxUpgradesPerPress) or 500
                        local parts, upgraded = {}, false
                        for _, entry in ipairs(plan) do
                            local batch = math.min(entry.upgrades, cap)
                            if batch > 0 and RawNet.invoke then
                                local ok, result = RawNet.invoke(
                                    "UpgradePotionsMachine_ActivateBulk",
                                    { [entry.key] = batch }
                                )
                                if ok and result then upgraded = true end
                                parts[#parts + 1] = string.format("%s x%d", entry.key, batch)
                                taskWait(0.4)
                            end
                        end
                        AfkPotionStatus = #parts > 0 and ("upgraded " .. table.concat(parts, ", ")) or "nothing to upgrade"
                        taskWait(upgraded and 2 or 15)
                    end
                end
            end
        end)

        -- -----------------------------------------------------------------
        -- Auto Use Max Potions
        -- Only the highest tier of the Lucky Eggs / Coins / Damage families is
        -- drunk, and the game's own 0.4s Use Item guard is respected.
        -- -----------------------------------------------------------------
        local USE_FAMILIES = {
            ["Potion | Lucky"] = true,
            ["Potion | Coins"] = true,
            ["Potion | Damage"] = true,
        }

        local function maxTierKeyByFamily()
            local best = {}
            for key, def in pairs(Library.Directory.Items) do
                if type(def) == "table" and USE_FAMILIES[def.potion] and tonumber(def.tier) then
                    local tier = tonumber(def.tier)
                    local current = best[def.potion]
                    if not current or tier > current.tier then
                        best[def.potion] = { key = key, tier = tier }
                    end
                end
            end
            return best
        end

        taskSpawn(function()
            while true do
                if not AutoPotionUse then
                    AfkPotionUseStatus = "Idle"
                    taskWait(0.5)
                else
                    local best = maxTierKeyByFamily()
                    local okSave, save = pcall(function() return Library.Save.Get() end)
                    local items = okSave and type(save) == "table" and save.Items or nil
                    local drank = false
                    if type(items) == "table" and RawNet.fire then
                        for _, entry in pairs(best) do
                            local owned = tonumber(items[entry.key]) or 0
                            if owned > 0 then
                                RawNet.fire("Use Item", entry.key, owned)
                                AfkPotionUseStatus = string.format("drank %s x%d", entry.key, owned)
                                drank = true
                                taskWait(0.45)
                            end
                        end
                    end
                    if not drank then
                        AfkPotionUseStatus = "no max-tier potions held"
                    end
                    taskWait(drank and 1 or 10)
                end
            end
        end)

        -- -----------------------------------------------------------------
        -- Isolate quest-controller helpers from the large UI-builder closure.
        -- Luau allows at most 200 local registers in a function.
        taskSpawn(function()
        -- -----------------------------------------------------------------
        -- Auto Quests
        -- Reads the live quest state, accepts unaccepted quests, steers the
        -- existing farm/hatch automation at the current objective and claims
        -- finished quests.
        --
        -- The game's Save.Questline tracks each line separately:
        --   save.Questline.claimed        -> how many quests are finished on the
        --                                    MAIN line (FreeBkPros/Zephyrr/
        --                                    PetsGOModder share it).
        --   save.Questline.tracks[Name]   -> per-line {accepted, active, claimed}
        --                                    for every other NPC.
        -- Library.Network's caller check blocks injected code, so all of this is
        -- read through the RawNet resolver built at the top of the file.
        --
        -- Two toggles drive it:
        --   AutoQuests     - the story lines: BK/Zeph (main), The Robot,
        --                    Farmer and Deadpool. These are the "main quest
        --                    lines" the player asked the driver to carry.
        --   AutoQuestsSide - the event / side lines: Lucky BK, Old Feller
        --                    (RainyFarmer) and the Arcade Robot.
        -- -----------------------------------------------------------------
        local MAIN_QUEST_NPCS = {
            FreeBkPros = true,
            Zephyrr = true,
            PetsGOModder = true,
        }
        -- Only the three NPCs the player asked for are worked: BK (FreeBkPros),
        -- PetsGOModder and Zephyrr. Every one of their quests lives on the single
        -- shared root "main" line in save.Questline, so there is exactly one
        -- track to drive. The Robot / Farmer / Deadpool and the event lines
        -- (Lucky BK, Old Feller, Arcade Robot) are deliberately left alone.
        local MAIN_QUEST_TRACKS = { "main" }
        local SIDE_QUEST_TRACKS = {}

        -- Build the text -> stat lookup from the LIVE quest state, which already
        -- carries the true `stat` field on every objective. This is primary
        -- because the directory is a worst-case fallback that can hold more than
        -- one objective with the same text.
        local function readSaveQuestline()
            if type(SaveModule) ~= "table" or type(SaveModule.Get) ~= "function" then
                return nil
            end
            local ok, save = pcall(SaveModule.Get)
            if ok and type(save) == "table" and type(save.Questline) == "table" then
                return save.Questline
            end
            return nil
        end

        local questStatByText = nil
        local function getQuestStatMap()
            if questStatByText then return questStatByText end
            local map = {}
            for _, cfg in pairs(Library.Directory.Quests) do
                if type(cfg) == "table" and type(cfg.objectives) == "table" then
                    for _, objective in ipairs(cfg.objectives) do
                        if type(objective) == "table" and objective.text and objective.stat then
                            map[tostring(objective.text)] = tostring(objective.stat)
                        end
                    end
                end
            end
            questStatByText = map
            return map
        end

        -- Resolve the objective's stat from the objective itself first, then the
        -- live-state text map, and only then the directory. A stat of "nil" (the
        -- string) is what a client-built objective table ends up with, so it is
        -- treated as missing.
        local function statForObjective(objective)
            if type(objective) ~= "table" then return nil end
            local direct = objective.stat
            if direct ~= nil and tostring(direct) ~= "nil" then return tostring(direct) end
            local text = objective.text ~= nil and tostring(objective.text) or nil
            if text then return getQuestStatMap()[text] end
            return nil
        end

        local function petIsHuge(petDef)
            if type(petDef) ~= "table" then return false end
            if petDef.huge == true or petDef.titanic == true or petDef.gargantuan == true then return true end
            local rarity = tostring(petDef.rarity):lower()
            return rarity:find("huge") ~= nil or rarity:find("titanic") ~= nil or rarity:find("gargantuan") ~= nil
        end

        local function eachEggDrop(eggDef, fn)
            local drops = type(eggDef) == "table" and eggDef.drops or nil
            if type(drops) ~= "table" then return end
            for _, drop in ipairs(drops) do
                if type(drop) == "table" then
                    local petId = drop[1] or drop.pet or drop.id
                    local weight = tonumber(drop[2]) or tonumber(drop.weight) or tonumber(drop.chance) or tonumber(drop.w)
                    if petId and weight then fn(petId, weight) end
                end
            end
        end

        -- Best hatchable, non-exclusive egg by a scoring function. Diamond eggs
        -- are skipped unless allowDiamonds is set, so the driver never burns
        -- gems when a coin egg can do the job.
        local function bestEggFor(scoreFn, allowDiamonds)
            local best, bestScore = nil, 0
            for name, def in pairs(Library.Directory.Eggs) do
                if type(def) == "table" and def.hatchable and not tostring(name):find("Exclusive Egg") then
                    local currency = tostring(def.currency)
                    if allowDiamonds or (currency ~= "Diamonds" and currency ~= "nil") then
                        local score = scoreFn(tostring(name), def)
                        if score and score > bestScore then
                            bestScore = score
                            best = tostring(name)
                        end
                    end
                end
            end
            return best
        end

        local function hugeEggScore(_, def)
            local total, huge = 0, 0
            eachEggDrop(def, function(petId, weight)
                total = total + weight
                if petIsHuge(Library.Directory.Pets[petId]) then huge = huge + weight end
            end)
            if total <= 0 or huge <= 0 then return 0 end
            -- Cheaper eggs win ties so the same huge chance is bought cheaply.
            local cost = tonumber(def.cost) or math.huge
            return (huge / total) * 1e6 + (1 / (1 + cost / 1e6))
        end

        local function rarityEggScore(rarity, _, def)
            local total, wanted = 0, 0
            eachEggDrop(def, function(petId, weight)
                total = total + weight
                local petDef = Library.Directory.Pets[petId]
                if type(petDef) == "table" and tostring(petDef.rarity) == rarity then
                    wanted = wanted + weight
                end
            end)
            if total <= 0 or wanted <= 0 then return 0 end
            return wanted / total
        end

        local function resolveEggIdByName(name)
            local target = tostring(name):lower()
            for eggName, def in pairs(Library.Directory.Eggs) do
                if tostring(eggName):lower() == target then return tostring(eggName) end
                if type(def) == "table" then
                    if tostring(def.name):lower() == target or tostring(def.displayName):lower() == target then
                        return tostring(eggName)
                    end
                end
            end
            return nil
        end


        -- Progress of one line, straight out of Save.Questline. `main` is the
        -- shared root record (FreeBkPros/Zephyrr/PetsGOModder); every other NPC
        -- has its own entry in .tracks. A line that is not present yet has never
        -- been started and reads as claimed = 0 / accepted = false.
        --
        -- `total` is how many quests the line holds in the directory, so the
        -- driver can tell a finished line from one that has merely been started.
        local function trackQuestTotal(track)
            local total = 0
            for _, cfg in ipairs(Library.Directory.Quests) do
                if type(cfg) == "table" then
                    local cfgTrack = cfg.track ~= nil and tostring(cfg.track) or nil
                    if track == "main" then
                        -- The shared root line holds FreeBkPros/Zephyrr/
                        -- PetsGOModder quests (save.Questline.claimed counts
                        -- them). Scope the total to exactly those three NPCs so
                        -- a stray root quest from another NPC cannot stop the
                        -- line from ever reading as done.
                        if cfgTrack == nil and MAIN_QUEST_NPCS[tostring(cfg.npc)] then
                            total = total + 1
                        end
                    elseif cfgTrack == track or tostring(cfg.npc) == track then
                        total = total + 1
                    end
                end
            end
            return total
        end

        local function questlineInfo(track)
            local ql = readSaveQuestline()
            local raw
            if track == "main" then
                raw = type(ql) == "table" and ql or nil
            else
                raw = type(ql) == "table" and ql.tracks and ql.tracks[track] or nil
            end
            local accepted = type(raw) == "table" and raw.accepted == true or false
            local claimed = type(raw) == "table" and (tonumber(raw.claimed) or 0) or 0
            local total = trackQuestTotal(track)
            return {
                accepted = accepted,
                claimed = claimed,
                total = total,
                done = total > 0 and claimed >= total,
            }
        end

        -- The driver turns on the sub-automations an objective needs and
        -- remembers which ones it started, so switching Auto Quests off puts
        -- the account back exactly as it was. `gameAutoFarm` covers the
        -- game's own Auto Farm engine, which the manager above toggles.
        local questOwned = {
            hatch = false, potionUse = false, wheels = false, gifts = false,
            tokens = false, gameAutoFarm = false,
        }
        local function questAcquire(kind)
            if kind == "hatch" and not AutoBuying then
                questOwned.hatch = true
                if type(setAutoHatchState) == "function" then
                    pcall(setAutoHatchState, true)
                else
                    AutoBuying = true
                end
            elseif kind == "gameAutoFarm" then
                -- Re-raise "wanted" on every acquire, not just the first one.
                -- applyObjective resets QuestAreaFarmWanted at the top of every
                -- driver pass (~every 3s), so the old "only when not owned" guard
                -- left the farm switching itself back off mid-objective once the
                -- flag was cleared but ownership was still set.
                questOwned.gameAutoFarm = true
                QuestOwnedAutoFarm = true
                QuestAreaFarmWanted = true
            elseif kind == "potionUse" and not AutoPotionUse then
                questOwned.potionUse = true
                AutoPotionUse = true
            elseif kind == "wheels" and not AutoSpinnyWheels then
                questOwned.wheels = true
                AutoSpinnyWheels = true
            elseif kind == "gifts" and not AutoCollectFreeGifts then
                questOwned.gifts = true
                AutoCollectFreeGifts = true
            elseif kind == "tokens" and not AutoTokens then
                questOwned.tokens = true
                AutoTokens = true
            end
        end

        local function questReleaseAll()
            if not AutoQuests and not AutoQuestsSide then
                if type(setAutoHatchState) == "function" then
                    pcall(setAutoHatchState, false)
                else
                    AutoBuying = false
                    pcall(function()
                        Library.Variables.AutoHatchEggId = nil
                        Library.Variables.AutoHatchEnabled = false
                    end)
                end
            elseif questOwned.hatch and type(setAutoHatchState) == "function" then
                pcall(setAutoHatchState, false)
            end
            if questOwned.potionUse then AutoPotionUse = false end
            if questOwned.wheels then AutoSpinnyWheels = false end
            if questOwned.gifts then AutoCollectFreeGifts = false end
            if questOwned.tokens then AutoTokens = false end
            if questOwned.gameAutoFarm then
                QuestAreaFarmWanted = false
                QuestAreaFarmTarget = nil
                QuestOwnedAutoFarm = false
            end
            questOwned = {
                hatch = false, potionUse = false, wheels = false, gifts = false,
                tokens = false, gameAutoFarm = false,
            }
        end

        -- Point the shared state at the given objective stat. Breakable
        -- objectives now route through the game's own Auto Farm (via
        -- QuestAreaFarmWanted) instead of the hub's per-coin teleport farm,
        -- so the player is parked once at the area centre and the game's
        -- engine does the walking.
        local function applyObjective(stat)
            local wasPlaytimeActive = QuestPlaytimeActive
            QuestCoinFilter = nil
            QuestFarmActive = false
            QuestAreaFarmWanted = false
            QuestAreaFarmTarget = nil
            QuestHatchAnywhere = false
            QuestTargetEggId = nil
            QuestTargetEggLabel = nil
            QuestPlaytimeActive = false

            if stat ~= "PlaytimeSeconds" then
                QuestPlaytimeFarmReady = false
                QuestPlaytimeFarmTarget = nil
            end
            if not stat then return "objective has no stat" end

            -- Breakables ---------------------------------------------------
            if stat == "Breakables" then
                questAcquire("gameAutoFarm")
                QuestAreaFarmTarget = nil
                return "auto-farming breakables"
            end
            if stat:sub(1, 14) == "BreakableKind:" then
                local kind = stat:sub(15)
                -- The game's Auto Farm takes every breakable in the captured
                -- area. A kind-restricted objective still farms the whole area
                -- - the pets hit whatever is there, and the quest counts only
                -- the kind it asked for. Chests are the one exception worth
                -- steering for: they are rare, so the hub's targeted farm
                -- (which teleports to the weakest chest specifically) beats
                -- waiting for the game's engine to wander onto one.
                if kind == "Chest" or kind == "Crystal Chest" then
                    QuestCoinFilter = { kind = kind, lowestHealth = true }
                    QuestFarmActive = true
                    return "hunting " .. kind:lower() .. "s"
                end
                questAcquire("gameAutoFarm")
                QuestAreaFarmTarget = nil
                return "auto-farming " .. kind .. "s"
            end
            if stat == "CrystalChests" then
                QuestCoinFilter = { kind = "Crystal Chest", lowestHealth = true }
                QuestFarmActive = true
                return "hunting crystal chests"
            end
            if stat:sub(1, 10) == "Breakable:" then
                local name = stat:sub(11)
                QuestCoinFilter = { name = name, lowestHealth = true }
                QuestFarmActive = true
                return "breaking " .. name
            end
            if stat:sub(1, 17) == "WorldBreakables:" then
                questAcquire("gameAutoFarm")
                QuestAreaFarmTarget = stat:sub(18)
                return "auto-farming in " .. stat:sub(18)
            end
            if stat == "LuckyBlocks" then
                questAcquire("gameAutoFarm")
                QuestAreaFarmTarget = nil
                return "auto-farming Lucky blocks"
            end
            if stat == "MobsDefeated" or stat == "BossDefeats" then
                questAcquire("gameAutoFarm")
                QuestAreaFarmTarget = nil
                return "auto-farming mobs"
            end

            -- Eggs ---------------------------------------------------------
            if stat == "Eggs" then
                questAcquire("hatch")
                QuestHatchAnywhere = true
                return "hatching (auto-hatch)"
            end
            if stat == "ExclusiveEggs" then
                questAcquire("hatch")
                local id = bestEggFor(function(_, def)
                    return tostring(def.currency) == "Diamonds" and 1 or 0
                end, true)
                QuestTargetEggId = id
                QuestTargetEggLabel = id
                return id and ("hatching " .. id) or "no exclusive egg found"
            end
            if stat == "LuckyEggs" then
                questAcquire("hatch")
                local id = resolveEggIdByName("Lucky Egg")
                QuestTargetEggId = id
                QuestTargetEggLabel = id
                return "hatching Lucky Egg"
            end
            if stat:sub(1, 8) == "AreaEgg:" then
                questAcquire("hatch")
                local area = stat:sub(9)
                local id = bestEggFor(function(_, def)
                    return tostring(def.area) == area and 1 or 0
                end, true)
                QuestTargetEggId = id
                QuestTargetEggLabel = id
                return id and ("hatching " .. id .. " (" .. area .. ")") or ("no egg in " .. area)
            end
            if stat:sub(1, 4) == "Egg:" then
                questAcquire("hatch")
                local id = resolveEggIdByName(stat:sub(5))
                QuestTargetEggId = id
                QuestTargetEggLabel = id
                return id and ("hatching " .. id) or ("egg " .. stat:sub(5) .. " not found")
            end
            if stat == "HugePets" or stat == "BountyHuges" then
                questAcquire("hatch")
                local id = bestEggFor(hugeEggScore, false)
                QuestTargetEggId = id
                QuestTargetEggLabel = id
                return id and ("hunting huges in " .. id) or "no coin egg drops huges"
            end
            local RARITY_STATS = {
                LegendaryPets = "Legendary",
                MythicalPets = "Mythical",
                SecretPets = "Secret",
                ExclusivePets = "Exclusive",
            }
            if RARITY_STATS[stat] then
                questAcquire("hatch")
                local rarity = RARITY_STATS[stat]
                local id = bestEggFor(function(_, def) return rarityEggScore(rarity, _, def) end, false)
                QuestTargetEggId = id
                QuestTargetEggLabel = id
                return id and ("hatching " .. id .. " for " .. rarity) or ("no coin egg for " .. rarity)
            end
            -- Modifier pets (golden/rainbow/shiny/dark matter) can come out of
            -- any egg, so the easiest path is just to keep hatching.
            if stat == "GoldenPets" or stat == "RainbowPets" or stat == "ShinyPets"
                or stat == "ShinyGoldenPets" or stat == "ShinyRainbowPets" or stat == "DarkMatterPets" then
                questAcquire("hatch")
                QuestHatchAnywhere = true
                return "hatching for " .. stat
            end

            -- Chores -------------------------------------------------------
            if stat == "PotionsUsed" then
                questAcquire("potionUse")
                return "drinking potions"
            end
            if stat == "WheelSpins" then
                questAcquire("wheels")
                return "spinning wheels"
            end
            if stat == "FreeGifts" or stat == "Giftboxes" then
                questAcquire("gifts")
                return "collecting free gifts"
            end
            if stat == "AbilityTokens" then
                questAcquire("tokens")
                return "collecting tokens"
            end
            if stat == "EnchantUpgrades" then
                return "enchant upgrades (run the machine)"
            end

            -- Passive ------------------------------------------------------
            if stat:sub(1, 9) == "Currency:" or stat:sub(1, 5) == "Rank:" then
                QuestFarmActive = true
                return "farming for " .. stat
            end
            if stat == "PlaytimeSeconds" then
                -- The clock just ticks, so put the wait to work: farm the AFK
                -- area the user picked and/or hatch the egg they picked until
                -- the objective completes. With neither picked it stays a
                -- plain wait, which is the old behaviour.
                --
                -- The selected AFK farm area takes priority. If no area was
                -- selected, fall back to the chosen egg's area. The startup
                -- sequence always captures Auto Farm at the area centre first,
                -- then moves to the egg capsule for hatching.
                local eggDef = AfkFarmEgg and Library.Directory and Library.Directory.Eggs
                    and Library.Directory.Eggs[AfkFarmEgg] or nil
                local eggArea = type(eggDef) == "table" and eggDef.area or nil

                if AfkFarmEgg then
                    questAcquire("hatch")
                    QuestTargetEggId = AfkFarmEgg
                    QuestTargetEggLabel = AfkFarmEgg
                end

                -- Use the user's selected farm area first. When none was
                -- selected, use the chosen egg's area if it is a real
                -- Directory.Areas entry; unusual egg/world labels are ignored.
                local farmArea = AfkFarmArea
                if not farmArea and AfkFarmEgg
                    and eggArea and Library.Directory.Areas[eggArea] ~= nil then
                    farmArea = eggArea
                end

                -- Farm only when there is something to farm: a picked area or a
                -- picked egg. With neither, the objective degrades to the old
                -- plain wait instead of farming wherever the player stands.
                if farmArea or AfkFarmEgg then
                    questAcquire("gameAutoFarm")
                    QuestAreaFarmTarget = farmArea
                end

                -- Reset the staged startup only when entering a new playtime
                -- objective or changing its selected farm area. Repeated quest
                -- driver passes must not restart the waits.
                if not wasPlaytimeActive or QuestPlaytimeFarmTarget ~= farmArea then
                    QuestPlaytimeFarmReady = false
                    QuestPlaytimeFarmTarget = farmArea
                end
                QuestPlaytimeActive = true

                local bits = {}
                if farmArea then bits[#bits + 1] = "farming " .. farmArea end
                if AfkFarmEgg then bits[#bits + 1] = "hatching " .. AfkFarmEgg end
                return #bits > 0 and ("playtime: " .. table.concat(bits, " + "))
                    or "waiting (playtime)"
            end

            return "unsupported: " .. stat
        end

        while true do
                -- Release everything when neither quest toggle is on.
                if not AutoQuests and not AutoQuestsSide then
                    if QuestFarmActive or QuestCoinFilter or QuestTargetEggId
                        or QuestAreaFarmWanted or QuestHatchAnywhere or QuestPlaytimeActive then
                        questReleaseAll()
                        QuestCoinFilter = nil
                        QuestFarmActive = false
                        QuestAreaFarmWanted = false
                        QuestAreaFarmTarget = nil
                        QuestHatchAnywhere = false
                        QuestTargetEggId = nil
                        QuestTargetEggLabel = nil
                        QuestPlaytimeActive = false
                        QuestPlaytimeFarmReady = false
                        QuestPlaytimeFarmTarget = nil
                    end
                    AfkQuestStatus = "Idle"
                    AfkSideQuestStatus = "Idle"
                    taskWait(0.5)
                else
                    local ok, all = false, nil
                    if RawNet.invoke then
                        ok, all = RawNet.invoke("Questline: GetAll")
                    end

                    if not ok or type(all) ~= "table" then
                        AfkQuestStatus = "quest state unavailable"
                        AfkSideQuestStatus = "quest state unavailable"
                        taskWait(5)
                    else
                        -- Walk the enabled lines in a fixed order. An already
                        -- accepted line always wins, then the first line that
                        -- has not finished its current quest. A line is only
                        -- skipped once save.Questline says it is fully done, so
                        -- the driver keeps working (and auto-accepting) every
                        -- main quest instead of stopping at the first claim.
                        local function buildTracks()
                            local list = {}
                            if AutoQuests then
                                for _, t in ipairs(MAIN_QUEST_TRACKS) do list[#list + 1] = t end
                            end
                            if AutoQuestsSide then
                                for _, t in ipairs(SIDE_QUEST_TRACKS) do list[#list + 1] = t end
                            end
                            return list
                        end

                        local chosen, chosenState, chosenInfo = nil, nil, nil
                        local statusByTrack = {}
                        for _, track in ipairs(buildTracks()) do
                            local state = all[track]
                            local info = questlineInfo(track)
                            statusByTrack[track] = info
                            if type(state) == "table" and not info.done then
                                if info.accepted then
                                    chosen, chosenState, chosenInfo = track, state, info
                                    break
                                elseif not chosen then
                                    chosen, chosenState, chosenInfo = track, state, info
                                end
                            end
                        end

                        -- Status summary per enabled toggle: the line being
                        -- worked first, then how many of its lines are still
                        -- open, so the AFK pane shows real progress.
                        local function describe(prefixTracks)
                            local open, total = 0, 0
                            for _, track in ipairs(prefixTracks) do
                                total = total + 1
                                if not statusByTrack[track] or not statusByTrack[track].done then
                                    open = open + 1
                                end
                            end
                            if total == 0 then return "idle" end
                            if open == 0 then return string.format("all %d lines done", total) end
                            return string.format("%d/%d lines open", open, total)
                        end

                        local mainSummary = AutoQuests and describe(MAIN_QUEST_TRACKS) or "idle"
                        local sideSummary = AutoQuestsSide and describe(SIDE_QUEST_TRACKS) or "idle"

                        if not chosenState then
                            AfkQuestStatus = mainSummary
                            AfkSideQuestStatus = sideSummary
                            taskWait(15)
                        elseif not chosenInfo.accepted then
                            -- The server rejects Accept handled by another line's
                            -- NPC, so only accept when the track we picked really
                            -- is that NPC's own line.
                            local acceptOk = RawNet.invoke("Questline: Accept", chosen)
                            if acceptOk then
                                AfkQuestStatus = "accepted " .. tostring(chosenState.title) .. " [" .. chosen .. "]"
                                AfkSideQuestStatus = AfkQuestStatus
                            else
                                AfkQuestStatus = "accept failed [" .. chosen .. "]"
                                AfkSideQuestStatus = AfkQuestStatus
                            end
                            taskWait(1.5)
                        else
                            local objective = nil
                            if type(chosenState.objectives) == "table" then
                                for _, ob in ipairs(chosenState.objectives) do
                                    if (tonumber(ob.have) or 0) < (tonumber(ob.need) or 0) then
                                        objective = ob
                                        break
                                    end
                                end
                            end

                            if chosenState.complete == true or objective == nil then
                                local okClaim, claimed, message = RawNet.invoke("Questline: Claim", chosen)
                                if okClaim and claimed then
                                    AfkQuestStatus = "claimed " .. tostring(chosenState.title)
                                else
                                    AfkQuestStatus = "claim failed: " .. tostring(message)
                                end
                                AfkSideQuestStatus = AfkQuestStatus
                                taskWait(2)
                            else
                                local stat = statForObjective(objective)

                                local label = applyObjective(stat)
                                local have = tonumber(objective.have) or 0
                                local need = tonumber(objective.need) or 0
                                local statusText = string.format(
                                    "%s [%s] - %s (%d/%d) [%s]",
                                    tostring(chosenState.title or chosen), chosen, label, have, need, tostring(stat or "?")
                                )
                                if chosenInfo and MAIN_QUEST_NPCS[tostring(chosenState.npc)] then
                                    AfkQuestStatus = statusText
                                    AfkSideQuestStatus = sideSummary
                                else
                                    AfkSideQuestStatus = statusText
                                    AfkQuestStatus = mainSummary
                                end

                                -- Steer movement for area-bound objectives.
                                if QuestAreaFarmWanted then
                                    -- Breakable/playtime objective: park inside
                                    -- the objective's own area and let the game's
                                    -- own Auto Farm (manager loop above) walk the
                                    -- pets over everything in range. The hub's
                                    -- per-coin teleport farm is NOT used here.
                                    local root = getPlayerRoot()

                                    -- WorldBreakables:<world> names a world,
                                    -- not an area - load it first.
                                    if QuestAreaFarmTarget
                                        and Library.WorldCmds.HasArea(QuestAreaFarmTarget) == false then
                                        if sharedLoadWorldSafely then
                                            pcall(sharedLoadWorldSafely, QuestAreaFarmTarget)
                                            taskWait(1.5)
                                            root = getPlayerRoot()
                                        end
                                    end

                                    -- Park target: the objective's own area when
                                    -- it named a real one (playtime area pick,
                                    -- WorldBreakables area), otherwise the
                                    -- richest area that holds a matching
                                    -- breakable. The old code ignored
                                    -- QuestAreaFarmTarget here, so a playtime
                                    -- area pick was never actually steered to.
                                    local parkArea = QuestAreaFarmTarget
                                    if not parkArea or Library.WorldCmds.HasArea(parkArea) == false then
                                        parkArea = richestAreaForFilter(QuestCoinFilter or {})
                                    end

                                    if QuestPlaytimeActive then
                                        -- Playtime with an AFK egg must start at
                                        -- the centre of the selected farm area.
                                        -- Let the world settle there before
                                        -- enabling Auto Farm, then give its
                                        -- capture a few seconds before moving to
                                        -- the egg capsule for hatching.
                                        -- Only park at the area centre during startup.
                                        -- Once the farm has been enabled and the player
                                        -- has moved to the egg, never steer back to the
                                        -- centre on subsequent quest-driver passes.
                                        if not QuestPlaytimeFarmReady and parkArea then
                                            local centre = sharedGetAreaCenter and sharedGetAreaCenter(parkArea) or nil
                                            if root and centre and (root.Position - centre).Magnitude > 25 then
                                                steerToArea(parkArea)
                                                taskWait(0.5)
                                                root = getPlayerRoot()
                                            elseif not root then
                                                steerToArea(parkArea)
                                                taskWait(0.5)
                                                root = getPlayerRoot()
                                            end
                                        end

                                        if not QuestPlaytimeFarmReady then
                                            taskWait(3)
                                            if QuestPlaytimeActive and (AutoQuests or AutoQuestsSide) then
                                                -- Clear any stale capture first so
                                                -- Auto Farm records this area centre.
                                                questSetGameAutoFarm(false)
                                                taskWait(0.6)
                                                questSetGameAutoFarm(true)
                                                taskWait(3)
                                                if QuestPlaytimeActive and (AutoQuests or AutoQuestsSide) then
                                                    QuestPlaytimeFarmReady = true
                                                end
                                            end
                                        end

                                        if QuestPlaytimeFarmReady and QuestTargetEggId then
                                            local capsule = questFindEggCapsule(QuestTargetEggId)
                                            local part = capsule
                                                and (capsule.PrimaryPart or capsule:FindFirstChildWhichIsA("BasePart"))
                                            if part and root then
                                                if (root.Position - part.Position).Magnitude > 15 then
                                                    pcall(function()
                                                        root.CFrame = CFrame.new(part.Position + Vector3.new(0, 5, 0))
                                                    end)
                                                    taskWait(0.5)
                                                end
                                            -- If the capsule is not currently streamed in,
                                            -- stay where we are; do not bounce back to the
                                            -- farm centre. The next pass will retry the egg.
                                            end
                                        end
                                    elseif QuestTargetEggId then
                                        -- Non-playtime egg objectives still go
                                        -- directly to their capsule.
                                        local capsule = questFindEggCapsule(QuestTargetEggId)
                                        local part = capsule
                                            and (capsule.PrimaryPart or capsule:FindFirstChildWhichIsA("BasePart"))
                                        if part and root then
                                            if (root.Position - part.Position).Magnitude > 15 then
                                                pcall(function()
                                                    root.CFrame = CFrame.new(part.Position + Vector3.new(0, 5, 0))
                                                end)
                                                taskWait(0.5)
                                            end
                                        elseif parkArea then
                                            steerToArea(parkArea)
                                        end
                                    elseif parkArea then
                                        if root then
                                            local centre = sharedGetAreaCenter and sharedGetAreaCenter(parkArea) or nil
                                            if centre and (root.Position - centre).Magnitude > 25 then
                                                steerToArea(parkArea)
                                            end
                                        else
                                            steerToArea(parkArea)
                                        end
                                    end
                                elseif QuestCoinFilter then
                                    -- Kind/name-restricted breakables (chests
                                    -- and named breakables) still use the hub's
                                    -- targeted farm, because the game's engine
                                    -- would hit everything in the area instead.
                                    local root = getPlayerRoot()
                                    local nearMatch = false
                                    if root then
                                        local things = Workspace:FindFirstChild("__THINGS")
                                        local coinsFolder = things and things:FindFirstChild("Coins")
                                        if coinsFolder then
                                            for _, coin in ipairs(coinsFolder:GetChildren()) do
                                                if coinMatchesQuestFilter(coin) then
                                                    local pos = GetCoinPosition(coin)
                                                    if pos and (root.Position - pos).Magnitude < 200 then
                                                        nearMatch = true
                                                        break
                                                    end
                                                end
                                            end
                                        end
                                    end
                                    if not nearMatch then
                                        steerToArea(richestAreaForFilter(QuestCoinFilter))
                                    end
                                elseif QuestTargetEggId then
                                    -- Egg objective: teleport to the egg
                                    -- capsule itself, not just the middle of
                                    -- its area. Auto-hatch (driven by
                                    -- QuestTargetEggId above) does the rest.
                                    local capsule = questFindEggCapsule(QuestTargetEggId)
                                    if capsule then
                                        local part = capsule.PrimaryPart
                                            or capsule:FindFirstChildWhichIsA("BasePart")
                                        local root = getPlayerRoot()
                                        if part and root then
                                            local distance = (root.Position - part.Position).Magnitude
                                            if distance > 15 then
                                                pcall(function()
                                                    root.CFrame = CFrame.new(part.Position + Vector3.new(0, 5, 0))
                                                end)
                                                taskWait(0.5)
                                            end
                                        end
                                    else
                                        -- Capsule not streamed in: fall back to
                                        -- the egg's area centre until it is.
                                        local eggDef = Library.Directory and Library.Directory.Eggs
                                            and Library.Directory.Eggs[QuestTargetEggId] or nil
                                        local area = type(eggDef) == "table" and eggDef.area or nil
                                        if area then steerToArea(area) end
                                    end
                                elseif QuestHatchAnywhere then
                                    -- "Hatch N eggs" accepts any egg: park on
                                    -- whatever capsule is closest.
                                    local closestId = findClosestEggId()
                                    if closestId then
                                        local capsule = questFindEggCapsule(closestId)
                                        if capsule then
                                            local part = capsule.PrimaryPart
                                                or capsule:FindFirstChildWhichIsA("BasePart")
                                            local root = getPlayerRoot()
                                            if part and root and (root.Position - part.Position).Magnitude > 15 then
                                                pcall(function()
                                                    root.CFrame = CFrame.new(part.Position + Vector3.new(0, 5, 0))
                                                end)
                                            end
                                        end
                                    end
                                end

                                taskWait(3)
                            end
                        end
                    end
                end
            end
        end)
    end

    -- =====================================================================
    -- SETTINGS TAB UI & EXTENDED THEME SWITCHER
    -- =====================================================================
    do
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
    end

    do
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
    end

    local keybindBtn = Instance.new("TextButton")
    keybindBtn.Size = UDim2.new(1, 0, 0, 34)
    keybindBtn.Position = UDim2.new(0, 0, 0, 56)
    keybindBtn.BackgroundColor3 = activeTheme.surface
    keybindBtn.Text = "Current Key: " .. CurrentKeyName
    keybindBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    keybindBtn.Font = Enum.Font.GothamBold
    keybindBtn.TextSize = 13
    keybindBtn.Parent = settingsFrame

    do
        local keybindCorner = Instance.new("UICorner")
        keybindCorner.CornerRadius = UDim.new(0, 6)
        keybindCorner.Parent = keybindBtn
    end

    do
        local keybindStroke = Instance.new("UIStroke")
        keybindStroke.Color = activeTheme.stroke
        keybindStroke.Thickness = 1
        keybindStroke.Transparency = 0.7
        keybindStroke.Parent = keybindBtn
    end

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

    do
        local mobileToggleCorner = Instance.new("UICorner")
        mobileToggleCorner.CornerRadius = UDim.new(1, 0)
        mobileToggleCorner.Parent = mobileToggle
    end

    do
        local mobileToggleStroke = Instance.new("UIStroke")
        mobileToggleStroke.Thickness = 2
        mobileToggleStroke.Transparency = 0.25
        mobileToggleStroke.Parent = mobileToggle
    end

    local function toggleMainUI()
        -- Only the active AFK screen should block the hotkey. Checking the
        -- ScreenGui as well keeps a stale overlay property from swallowing
        -- the very first keypress on a fresh execute.
        if afkGui.Enabled and afkOverlay.Visible then
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
        elseif input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == ToggleKey then
            -- Deliberately ignore gameProcessed here: games that sink a key
            -- through ContextActionService would otherwise eat the hotkey.
            toggleMainUI()
        end
    end)

    ;(function()
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

    do
        local themeScrollCorner = Instance.new("UICorner")
        themeScrollCorner.CornerRadius = UDim.new(0, 6)
        themeScrollCorner.Parent = themeScroll
    end

    do
        local themeScrollLayout = Instance.new("UIListLayout")
        themeScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
        themeScrollLayout.Padding = UDim.new(0, 4)
        themeScrollLayout.Parent = themeScroll
    end

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

        do
            local rowCorner = Instance.new("UICorner")
            rowCorner.CornerRadius = UDim.new(0, 7)
            rowCorner.Parent = row
        end

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
            do
                local chipCorner = Instance.new("UICorner")
                chipCorner.CornerRadius = UDim.new(1, 0)
                chipCorner.Parent = chip
            end
            do
                local chipStroke = Instance.new("UIStroke")
                chipStroke.Color = themeObj.stroke
                chipStroke.Thickness = 1
                chipStroke.Transparency = 0.45
                chipStroke.Parent = chip
            end
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
        check.Text = "✓"
        check.TextColor3 = themeObj.accent
        check.Font = Enum.Font.GothamBold
        check.TextSize = 15
        check.Visible = false
        check.Parent = row

        themeRows[themeObj.name] = { row = row, check = check, stroke = tStroke, label = tLabel }
        themeIndex = themeIndex + 1

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
                order = order + 1
                entry.row.LayoutOrder = order
                shown = shown + 1
            end
        end
        themeLabel.Text = (query == "")
            and (("Select UI Theme (%d)"):format(shown))
            or (("Select UI Theme (%d / %d)"):format(shown, #Themes))
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
    end)()

    taskSpawn(function()
        -- PET INDEX: integrated into the existing hub and tab switcher.
        local variantNames = { [1] = "Base", [2] = "Golden", [3] = "Rainbow" }
        local variantColors = {
            [1] = Color3.fromRGB(150, 158, 176),
            [2] = Color3.fromRGB(236, 186, 66),
            [3] = Color3.fromRGB(226, 84, 164),
        }
        local indexQuery = ""
        local lastIndexRenderSignature = nil
        local searchRefreshQueued = false
        local cachedIndexCollectables = nil
        local indexCardPool = {}
        local indexEmptyLabel = nil

        -- Optional floating nearby-egg panel. Its proximity test follows the
        -- working EggDex script: find each egg's Center part, measure distance
        -- to the egg model's bounding box, and select the closest egg in range.
        local nearbyPanelEnabled = false
        local NEARBY_PANEL_RADIUS = 5
        local NEARBY_PANEL_TICK = 0.15
        local NEARBY_PANEL_OWNED_TICK = 0.60
        local NEARBY_PANEL_EGG_SWEEP = 8
        local nearbyEggList = {}
        local nearbyEggLastId = nil
        local nearbyEggRows = {}
        local nearbyEggOwned = {}
        local nearbyEggHasSave = false
        local nearbyEggOwnedSignature = nil
        local nearbyEggOwnedAcc = 0
        local cachedGcCollectionSave = nil
        local nextGcCollectionScanAt = 0
        local nearbyEggSweepAcc = NEARBY_PANEL_EGG_SWEEP
        local nearbyEggTickAcc = 0
        local nearbyPanelLastRender = nil
        local hiddenNearbyBillboards = setmetatable({}, { __mode = "k" })
        local readIndexOwned

        local nearbyPanel = Instance.new("Frame")
        nearbyPanel.Name = "NearbyEggMissingPetsPanel"
        nearbyPanel.AnchorPoint = Vector2.new(0, 0.5)
        nearbyPanel.Position = UDim2.new(0, 18, 0.5, 0)
        nearbyPanel.Size = UDim2.fromOffset(392, 486)
        nearbyPanel.BackgroundColor3 = activeTheme.panel
        nearbyPanel.BackgroundTransparency = 0.06
        nearbyPanel.BorderSizePixel = 0
        nearbyPanel.Visible = false
        nearbyPanel.ZIndex = 150
        nearbyPanel.Parent = ui
        do
            local nearbyPanelCorner = Instance.new("UICorner")
            nearbyPanelCorner.CornerRadius = UDim.new(0, 10)
            nearbyPanelCorner.Parent = nearbyPanel
        end
        do
            local nearbyPanelStroke = Instance.new("UIStroke")
            nearbyPanelStroke.Color = activeTheme.stroke
            nearbyPanelStroke.Thickness = 1
            nearbyPanelStroke.Transparency = 0.25
            nearbyPanelStroke.Parent = nearbyPanel
        end

        do
            local nearbyPanelAccent = Instance.new("Frame")
            nearbyPanelAccent.Size = UDim2.new(1, 0, 0, 3)
            nearbyPanelAccent.BackgroundColor3 = activeTheme.accent
            nearbyPanelAccent.BorderSizePixel = 0
            nearbyPanelAccent.ZIndex = 151
            nearbyPanelAccent.Parent = nearbyPanel
        end

        local nearbyPanelTitle = Instance.new("TextLabel")
        nearbyPanelTitle.Position = UDim2.fromOffset(14, 14)
        nearbyPanelTitle.Size = UDim2.new(1, -28, 0, 20)
        nearbyPanelTitle.BackgroundTransparency = 1
        nearbyPanelTitle.Font = Enum.Font.GothamBold
        nearbyPanelTitle.TextSize = 16
        nearbyPanelTitle.TextColor3 = activeTheme.text
        nearbyPanelTitle.TextXAlignment = Enum.TextXAlignment.Left
        nearbyPanelTitle.Text = "Nearby Egg"
        nearbyPanelTitle.ZIndex = 152
        nearbyPanelTitle.Parent = nearbyPanel

        local nearbyPanelSub = Instance.new("TextLabel")
        nearbyPanelSub.Position = UDim2.fromOffset(14, 34)
        nearbyPanelSub.Size = UDim2.new(1, -28, 0, 14)
        nearbyPanelSub.BackgroundTransparency = 1
        nearbyPanelSub.Font = Enum.Font.GothamMedium
        nearbyPanelSub.TextSize = 11
        nearbyPanelSub.TextColor3 = activeTheme.muted
        nearbyPanelSub.TextXAlignment = Enum.TextXAlignment.Left
        nearbyPanelSub.Text = "Move within 5 studs of an egg"
        nearbyPanelSub.ZIndex = 152
        nearbyPanelSub.Parent = nearbyPanel

        do
            local nearbyPanelDivider = Instance.new("Frame")
            nearbyPanelDivider.Position = UDim2.fromOffset(14, 54)
            nearbyPanelDivider.Size = UDim2.new(1, -28, 0, 1)
            nearbyPanelDivider.BackgroundColor3 = activeTheme.stroke
            nearbyPanelDivider.BorderSizePixel = 0
            nearbyPanelDivider.ZIndex = 151
            nearbyPanelDivider.Parent = nearbyPanel
        end

        local nearbyPanelList = Instance.new("ScrollingFrame")
        nearbyPanelList.Position = UDim2.fromOffset(10, 62)
        nearbyPanelList.Size = UDim2.new(1, -20, 1, -72)
        nearbyPanelList.BackgroundTransparency = 1
        nearbyPanelList.BorderSizePixel = 0
        nearbyPanelList.CanvasSize = UDim2.new()
        nearbyPanelList.AutomaticCanvasSize = Enum.AutomaticSize.Y
        nearbyPanelList.ScrollBarThickness = 4
        nearbyPanelList.ScrollBarImageColor3 = activeTheme.stroke
        nearbyPanelList.ZIndex = 152
        nearbyPanelList.Parent = nearbyPanel
        do
            local nearbyPanelLayout = Instance.new("UIListLayout")
            nearbyPanelLayout.Padding = UDim.new(0, 4)
            nearbyPanelLayout.SortOrder = Enum.SortOrder.LayoutOrder
            nearbyPanelLayout.Parent = nearbyPanelList
        end

        local nearbyPanelEmpty = Instance.new("TextLabel")
        nearbyPanelEmpty.Name = "EmptyMessage"
        nearbyPanelEmpty.Size = UDim2.new(1, 0, 0, 40)
        nearbyPanelEmpty.BackgroundTransparency = 1
        nearbyPanelEmpty.Font = Enum.Font.GothamMedium
        nearbyPanelEmpty.TextSize = 12
        nearbyPanelEmpty.TextColor3 = activeTheme.muted
        nearbyPanelEmpty.Text = ""
        nearbyPanelEmpty.Visible = false
        nearbyPanelEmpty.ZIndex = 153
        nearbyPanelEmpty.Parent = nearbyPanelList

        local function nearbyAsset(id)
            if type(id) ~= "string" or id == "" then return nil end
            if id:match("^rbx") then return id end
            return "rbxassetid://" .. id
        end

        local function nearbyFormatChance(value)
            value = tonumber(value) or 0
            if value <= 0 then return "?" end
            if value >= 1 then return ("%d%%"):format(value) end
            if value >= 0.1 then return ("%.1f%%"):format(value) end
            if value >= 0.01 then return ("%.2f%%"):format(value) end
            return ("%.6f"):format(value):gsub("0+$", ""):gsub("%.$", "") .. "%"
        end

        local function scanNearbyPanelEggs()
            local nextEggs = {}
            local seen = {}
            local map = Workspace:FindFirstChild("__MAP")
            local eggsRoot = map and map:FindFirstChild("Eggs")
            local eggDirectory = Library.Directory and Library.Directory.Eggs
            if not eggsRoot or type(eggDirectory) ~= "table" then
                nearbyEggList = nextEggs
                return
            end

            for _, part in ipairs(eggsRoot:GetDescendants()) do
                if part.Name == "Center" and part:IsA("BasePart") then
                    local model = part.Parent
                    while model and not model:IsA("Model") do
                        model = model.Parent
                    end
                    local id = model and model:GetAttribute("ID")
                    local cfg = id and (eggDirectory[id] or eggDirectory[tostring(id)])
                    -- BUGFIX (from v3): accept eggs whose drops are a string
                    -- chain by resolving them before the table check.
                    if cfg and type(resolveEggDrops(eggDirectory, cfg) or nil) == "table" and not seen[part] then
                        seen[part] = true
                        local ok, cf, size = pcall(function()
                            local boxCF, boxSize = model:GetBoundingBox()
                            return boxCF, boxSize
                        end)
                        if ok and cf and size then
                            nextEggs[#nextEggs + 1] = {
                                id = tostring(id),
                                part = part,
                                cfg = cfg,
                                cf = cf,
                                size = size,
                            }
                        end
                    end
                end
            end
            nearbyEggList = nextEggs
        end

        local function getNearestNearbyPanelEgg()
            local character = localPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if not root then return nil end
            local origin = root.Position
            local best, bestDistance
            for _, egg in ipairs(nearbyEggList) do
                if egg.part and egg.part.Parent then
                    local relative = egg.cf:PointToObjectSpace(origin)
                    local half = egg.size / 2
                    local clamped = Vector3.new(
                        math.clamp(relative.X, -half.X, half.X),
                        math.clamp(relative.Y, -half.Y, half.Y),
                        math.clamp(relative.Z, -half.Z, half.Z)
                    )
                    local distance = (relative - clamped).Magnitude
                    if distance <= NEARBY_PANEL_RADIUS and (not bestDistance or distance < bestDistance) then
                        best = egg
                        bestDistance = distance
                    end
                end
            end
            return best, bestDistance
        end

        local function hideNearbyGameEggInfo(deep)
            local function disableBillboard(item)
                if item and item:IsA("BillboardGui") then
                    if hiddenNearbyBillboards[item] == nil then
                        hiddenNearbyBillboards[item] = item.Enabled
                    end
                    item.Enabled = false
                end
            end
            for _, item in ipairs(playerGui:GetChildren()) do
                if item:IsA("BillboardGui") then
                    local frame = item:FindFirstChild("Frame")
                    if item.Name:find("EggInfo") or (frame and frame:FindFirstChild("EggNameTitle")) then
                        disableBillboard(item)
                    end
                end
            end
            if deep then
                for _, item in ipairs(playerGui:GetDescendants()) do
                    if item:IsA("BillboardGui") and item.Name:find("EggInfo") then
                        disableBillboard(item)
                    end
                end
            end
        end

        local function restoreNearbyGameEggInfo()
            for billboard, wasEnabled in pairs(hiddenNearbyBillboards) do
                if billboard and billboard.Parent then
                    billboard.Enabled = wasEnabled
                end
                hiddenNearbyBillboards[billboard] = nil
            end
        end

        local function buildNearbyPanelRows(cfg, owned)
            local rows = {}
            local variants = {}
            local eggDirectory = Library.Directory and Library.Directory.Eggs or {}
            local collectables = cachedIndexCollectables
            if not collectables then
                local ok, result = pcall(function()
                    return Library.Shared.GetAllCollectablePets()
                end)
                if ok and type(result) == "table" then
                    cachedIndexCollectables = result
                    collectables = result
                end
            end
            if type(collectables) ~= "table" then return rows end

            for _, entry in ipairs(collectables) do
                local petId = tostring(entry.petId)
                local set = variants[petId] or {}
                variants[petId] = set
                if entry.isGolden then
                    set.golden = true
                elseif entry.isRainbow then
                    set.rainbow = true
                elseif not entry.isDarkMatter then
                    set.base = true
                end
            end

            local function addPet(petId, variant, chance)
                local set = variants[petId]
                -- readIndexOwned uses the same numeric variant IDs as the
                -- Index tab: #1 = Base, #2 = Golden, #3 = Rainbow.
                -- Convert the panel's text variant name before checking it;
                -- comparing #base/#golden/#rainbow against #1/#2/#3 meant
                -- owned variants were never recognized and all were shown.
                local variantId = variant == "base" and 1
                    or variant == "golden" and 2
                    or variant == "rainbow" and 3
                if not set or not set[variant] or (variantId and owned[petId .. "#" .. variantId]) then return end
                local petDirectory = Library.Directory and Library.Directory.Pets
                local pet = (petDirectory and (petDirectory[petId] or petDirectory[tostring(petId)])) or {}
                rows[#rows + 1] = {
                    name = tostring(pet.displayName or pet.name or petId),
                    pet = pet,
                    rarity = tostring(pet.rarity or "Basic"),
                    chance = tonumber(chance) or 0,
                    variant = variant,
                }
            end

            -- BUGFIX (from v3): drops may be a string chain to another egg;
            -- resolve it before iterating.
            local drops = resolveEggDrops(eggDirectory, cfg) or {}
            for _, drop in ipairs(drops) do
                local petId, chance
                if type(drop) == "table" then
                    petId = drop.petName or drop[1]
                    chance = tonumber(drop.chance or drop[2]) or 0
                else
                    petId = drop
                    chance = 0
                end
                if type(petId) == "string" then
                    if cfg.isGolden then
                        addPet(petId, "golden", chance)
                        if not cfg.disableRainbow then addPet(petId, "rainbow", chance) end
                    elseif cfg.disableModifiers then
                        addPet(petId, "base", chance)
                    else
                        addPet(petId, "base", chance)
                        if not cfg.disableGold then addPet(petId, "golden", chance) end
                        if not cfg.disableRainbow then addPet(petId, "rainbow", chance) end
                    end
                end
            end

            table.sort(rows, function(a, b)
                local rarityNumbers = Library.Shared.PetRarityNumbers
                local ra = rarityNumbers[a.rarity] or 0
                local rb = rarityNumbers[b.rarity] or 0
                if ra ~= rb then return ra > rb end
                if a.chance ~= b.chance then return a.chance > b.chance end
                if a.name ~= b.name then return a.name < b.name end
                local order = { base = 1, golden = 2, rainbow = 3 }
                return order[a.variant] < order[b.variant]
            end)
            return rows
        end

        -- Reuse nearby-panel cards instead of destroying and recreating every
        -- Frame/TextLabel/ImageLabel when ownership changes. Rebuilding dozens
        -- of Instances in one frame was the main source of UI hitching.
        local nearbyPanelCards = {}
        local nearbyVariantInfo = {
            base = { label = "Base", width = 38, color = Color3.fromRGB(126, 134, 152) },
            golden = { label = "Golden", width = 50, color = Color3.fromRGB(224, 172, 48) },
            rainbow = { label = "Rainbow", width = 58, color = Color3.fromRGB(226, 84, 164) },
        }
        local nearbyRarityColors = {
            Basic = Color3.fromRGB(166, 172, 186), Rare = Color3.fromRGB(92, 166, 255),
            Epic = Color3.fromRGB(176, 108, 255), Legendary = Color3.fromRGB(255, 172, 64),
            Mythical = Color3.fromRGB(255, 92, 92), Secret = Color3.fromRGB(255, 68, 96),
            Event = Color3.fromRGB(255, 126, 200), Exclusive = Color3.fromRGB(255, 214, 92),
            Exotic = Color3.fromRGB(64, 226, 192), Godly = Color3.fromRGB(255, 244, 160),
        }

        local function createNearbyPanelCard()
            local card = Instance.new("Frame")
            card.Size = UDim2.new(1, -4, 0, 40)
            card.BackgroundColor3 = activeTheme.surface
            card.BackgroundTransparency = 0.35
            card.BorderSizePixel = 0
            card.ZIndex = 153
            do
                local cardCorner = Instance.new("UICorner")
                cardCorner.CornerRadius = UDim.new(0, 6)
                cardCorner.Parent = card
            end

            local icon = Instance.new("ImageLabel")
            icon.Position = UDim2.fromOffset(5, 5)
            icon.Size = UDim2.fromOffset(30, 30)
            icon.BackgroundColor3 = Color3.fromRGB(22, 25, 33)
            icon.BorderSizePixel = 0
            icon.ZIndex = 154
            icon.Parent = card
            do
                local iconCorner = Instance.new("UICorner")
                iconCorner.CornerRadius = UDim.new(0, 5)
                iconCorner.Parent = icon
            end

            local badge = Instance.new("TextLabel")
            badge.AnchorPoint = Vector2.new(1, 0.5)
            badge.Position = UDim2.new(1, -6, 0.5, 0)
            badge.BackgroundTransparency = 0.15
            badge.BorderSizePixel = 0
            badge.Font = Enum.Font.GothamBold
            badge.TextSize = 10
            badge.TextColor3 = Color3.new(1, 1, 1)
            badge.ZIndex = 155
            badge.Parent = card
            do
                local badgeCorner = Instance.new("UICorner")
                badgeCorner.CornerRadius = UDim.new(0, 4)
                badgeCorner.Parent = badge
            end

            local nameLabel = Instance.new("TextLabel")
            nameLabel.Position = UDim2.fromOffset(42, 3)
            nameLabel.Size = UDim2.new(0.65, 0, 0, 17)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Font = Enum.Font.GothamBold
            nameLabel.TextSize = 13
            nameLabel.TextColor3 = activeTheme.text
            nameLabel.TextXAlignment = Enum.TextXAlignment.Left
            nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
            nameLabel.ZIndex = 154
            nameLabel.Parent = card

            local detail = Instance.new("TextLabel")
            detail.Position = UDim2.fromOffset(42, 20)
            detail.Size = UDim2.new(0.65, 0, 0, 14)
            detail.BackgroundTransparency = 1
            detail.Font = Enum.Font.GothamMedium
            detail.TextSize = 11
            detail.RichText = true
            detail.TextXAlignment = Enum.TextXAlignment.Left
            detail.ZIndex = 154
            detail.Parent = card
            return { frame = card, icon = icon, badge = badge, name = nameLabel, detail = detail }
        end

        local function renderNearbyPanel(egg, distance, rows)
            local cfg = egg.cfg
            nearbyPanelTitle.Text = cfg.displayName or cfg.name or egg.id
            nearbyPanelTitle.TextColor3 = cfg.isGolden and Color3.fromRGB(236, 186, 66) or activeTheme.text
            local petCount, seenPets = 0, {}
            for _, row in ipairs(rows) do
                if not seenPets[row.name] then
                    seenPets[row.name] = true
                    petCount = petCount + 1
                end
            end
            nearbyPanelSub.Text = ("%d missing variants · %d pets · %.1f studs"):format(#rows, petCount, distance)

            if #rows == 0 then
                nearbyPanelEmpty.Text = nearbyEggHasSave
                    and "Every variant from this egg is collected"
                    or "Waiting for pet collection data..."
                nearbyPanelEmpty.Visible = true
            else
                nearbyPanelEmpty.Visible = false
            end

            for order, row in ipairs(rows) do
                local cardData = nearbyPanelCards[order]
                if not cardData then
                    cardData = createNearbyPanelCard()
                    nearbyPanelCards[order] = cardData
                end
                local info = nearbyVariantInfo[row.variant] or nearbyVariantInfo.base
                local rarityColor = nearbyRarityColors[row.rarity] or nearbyRarityColors.Basic
                local thumbnail = row.variant == "golden"
                    and (row.pet.goldenThumbnail or row.pet.thumbnail)
                    or (row.pet.thumbnail or row.pet.goldenThumbnail)

                cardData.frame.LayoutOrder = order
                cardData.frame.Visible = true
                cardData.frame.Parent = nearbyPanelList
                cardData.icon.Image = nearbyAsset(thumbnail) or ""
                cardData.badge.Size = UDim2.fromOffset(info.width, 18)
                cardData.badge.BackgroundColor3 = info.color
                cardData.badge.Text = info.label
                cardData.name.Size = UDim2.new(1 - (44 + info.width + 12) / 392, 0, 0, 17)
                cardData.name.Text = row.name
                cardData.name.TextColor3 = activeTheme.text
                cardData.detail.Size = UDim2.new(1 - (44 + info.width + 12) / 392, 0, 0, 14)
                cardData.detail.Text = ('<font color="#%s">%s</font><font color="#%s"> · %s</font>'):format(
                    rarityColor:ToHex(), row.rarity, activeTheme.muted:ToHex(), nearbyFormatChance(row.chance)
                )
            end

            for index = #rows + 1, #nearbyPanelCards do
                nearbyPanelCards[index].frame.Visible = false
            end
        end

        local function readNearbyPanelOwned()
            local owned, hasSave = readIndexOwned()

            -- Order-independent collection fingerprint. Avoid allocating and
            -- sorting a second array of every owned pet key on each poll.
            local hashA, hashB, keyCount = 0, 0, 0
            if hasSave then
                for key in pairs(owned) do
                    local keyHash = 2166136261
                    for index = 1, #key do
                        keyHash = bit32.band(bit32.bxor(keyHash, string.byte(key, index)) * 16777619, 0x7fffffff)
                    end
                    hashA = (hashA + keyHash) % 2147483647
                    hashB = (hashB + (keyHash * keyHash) % 2147483647) % 2147483647
                    keyCount = keyCount + 1
                end
            end
            local signature = table.concat({ hasSave and "ready" or "unavailable", keyCount, hashA, hashB }, "|")
            local changed = signature ~= nearbyEggOwnedSignature
            nearbyEggOwnedSignature = signature
            nearbyEggOwned = hasSave and owned or {}
            nearbyEggHasSave = hasSave == true
            return changed, nearbyEggHasSave
        end

        local function updateNearbyPanelToggle()
            TAB_TOTAL.indexUI.nearbyToggle.Text = nearbyPanelEnabled and "Nearby Egg UI: ON" or "Nearby Egg UI: OFF"
            TAB_TOTAL.indexUI.nearbyToggle:SetAttribute("ToggleState", nearbyPanelEnabled)
            TAB_TOTAL.indexUI.nearbyToggle.BackgroundColor3 = nearbyPanelEnabled and activeTheme.controlOn or activeTheme.surface
            TAB_TOTAL.indexUI.nearbyToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
        end
        TAB_TOTAL.indexUI.nearbyToggle.MouseButton1Click:Connect(function()
            nearbyPanelEnabled = not nearbyPanelEnabled
            updateNearbyPanelToggle()
            if not nearbyPanelEnabled then
                nearbyPanel.Visible = false
                restoreNearbyGameEggInfo()
            else
                nearbyEggSweepAcc = NEARBY_PANEL_EGG_SWEEP
                nearbyEggOwnedAcc = NEARBY_PANEL_OWNED_TICK
                nearbyEggLastId = nil
                nearbyPanelLastRender = nil
                scanNearbyPanelEggs()
                readNearbyPanelOwned()
            end
        end)
        updateNearbyPanelToggle()

        -- Nearby-egg detection is deliberately throttled and only checks the
        -- egg folder's direct children. It never scans the whole Workspace.
        local INDEX_EGG_RANGE = 10
        local EGG_SCAN_INTERVAL = 0.35
        local cachedNearbyEgg = nil
        local nextEggScanAt = 0

        local function getEggWorldPosition(instance)
            if not instance then return nil end
            if instance:IsA("BasePart") then return instance.Position end
            local ok, pivot = pcall(function() return instance:GetPivot() end)
            if ok and pivot then return pivot.Position end
            local part = instance:FindFirstChildWhichIsA("BasePart", true)
            return part and part.Position or nil
        end

        local function resolveEggDirectoryEntry(instance, eggDirectory)
            if not instance or type(eggDirectory) ~= "table" then return nil, nil end
            local possibleIds = {
                instance:GetAttribute("EggId"),
                instance:GetAttribute("EggID"),
                instance:GetAttribute("ID"),
                instance:GetAttribute("id"),
                instance:GetAttribute("Egg"),
                instance.Name,
            }
            for _, rawId in pairs(possibleIds) do
                if rawId ~= nil then
                    local id = tostring(rawId)
                    local entry = eggDirectory[rawId] or eggDirectory[id]
                    -- BUGFIX (from v3): accept eggs whose drops are a string
                    -- chain by resolving them before the table check.
                    if type(entry) == "table" and type(resolveEggDrops(eggDirectory, entry) or nil) == "table" then
                        return id, entry
                    end
                    -- Also support physical egg models named by display name.
                    local lowered = id:lower()
                    for directoryId, candidate in pairs(eggDirectory) do
                        if type(candidate) == "table" and type(resolveEggDrops(eggDirectory, candidate) or nil) == "table" then
                            local display = tostring(candidate.displayName or candidate.name or directoryId):lower()
                            if display == lowered then
                                return tostring(directoryId), candidate
                            end
                        end
                    end
                end
            end
            return nil, nil
        end

        local function getNearbyEggPetIds()
            local now = os.clock()
            if now < nextEggScanAt then return cachedNearbyEgg end
            nextEggScanAt = now + EGG_SCAN_INTERVAL
            cachedNearbyEgg = nil

            local character = localPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local eggDirectory = Library.Directory and Library.Directory.Eggs
            if not root or type(eggDirectory) ~= "table" then return nil end

            local things = Workspace:FindFirstChild("__THINGS")
            local eggFolder = (things and things:FindFirstChild("Eggs"))
                or Workspace:FindFirstChild("Eggs")
            if not eggFolder then return nil end

            local closestDistance = INDEX_EGG_RANGE + 0.001
            local closestId, closestEntry = nil, nil
            for _, instance in ipairs(eggFolder:GetChildren()) do
                if instance and instance.Parent then
                    local position = getEggWorldPosition(instance)
                    if position then
                        local distance = (root.Position - position).Magnitude
                        if distance <= INDEX_EGG_RANGE and distance < closestDistance then
                            local eggId, eggEntry = resolveEggDirectoryEntry(instance, eggDirectory)
                            if eggEntry then
                                closestDistance = distance
                                closestId = eggId
                                closestEntry = eggEntry
                            end
                        end
                    end
                end
            end

            if closestEntry then
                local petIds = {}
                -- BUGFIX (from v3): drops may be a string chain to another
                -- egg; resolve it before iterating.
                local drops = resolveEggDrops(eggDirectory, closestEntry) or {}
                for _, drop in ipairs(drops) do
                    if type(drop) == "table" and drop[1] ~= nil then
                        petIds[tostring(drop[1])] = true
                    end
                end
                cachedNearbyEgg = {
                    id = closestId,
                    name = tostring(closestEntry.displayName or closestEntry.name or closestId),
                    distance = closestDistance,
                    petIds = petIds,
                }
            end
            return cachedNearbyEgg
        end

        readIndexOwned = function()
            local save
            pcall(function()
                if SaveModule and type(SaveModule.Get) == "function" then
                    save = SaveModule.Get()
                end
            end)

            -- Match the working standalone EggDex script: some game versions
            -- expose the live save through the GC even when SaveModule.Get()
            -- is unavailable or returns an incomplete table. Scanned with
            -- filtergc (native table matcher) instead of a full heap dump: a
            -- full heap materialisation freezes the client's Luau VM.
            if type(save) ~= "table" or type(save.Collection) ~= "table" or next(save.Collection) == nil then
                local stats = localPlayer:FindFirstChild("leaderstats")
                local diamonds = stats and stats:FindFirstChild("Diamonds")
                if diamonds and type(filtergc) == "function" then
                    local targetDiamonds = diamonds.Value
                    if type(cachedGcCollectionSave) == "table"
                        and type(cachedGcCollectionSave.Collection) == "table"
                        and cachedGcCollectionSave.Diamonds == targetDiamonds then
                        save = cachedGcCollectionSave
                    elseif os.clock() >= nextGcCollectionScanAt then
                        nextGcCollectionScanAt = os.clock() + 2
                        pcall(function()
                            local match = filtergc("table", function(candidate)
                                if type(candidate) == "table"
                                    and type(candidate.Collection) == "table"
                                    and type(candidate.Diamonds) == "number"
                                    and candidate.Diamonds == targetDiamonds then
                                    return true
                                end
                                return false
                            end, true)
                            if type(match) == "table" then
                                cachedGcCollectionSave = match
                                save = match
                            end
                        end)
                    end
                end
            end

            if type(save) ~= "table" or type(save.Collection) ~= "table" then
                return {}, false
            end

            local owned = {}
            for _, key in pairs(save.Collection) do
                if type(key) == "string" then
                    local petId, suffix = key:match("^(.*)%-(%d+)$")
                    local variantId = tonumber(suffix)
                    if petId and variantNames[variantId] then
                        owned[petId .. "#" .. variantId] = true
                    end
                end
            end
            return owned, true
        end

        local function refreshIndex()
            local nearbyEgg = getNearbyEggPetIds()
            local owned, hasSave = readIndexOwned()
            local directory = Library.Directory and Library.Directory.Pets
            if type(directory) ~= "table" then
                TAB_TOTAL.indexUI.summary.Text = "Game pet directory is not available."
                return
            end

            if not cachedIndexCollectables then
                local ok, result = pcall(function()
                    return Library.Shared.GetAllCollectablePets()
                end)
                if ok and type(result) == "table" then
                    cachedIndexCollectables = result
                end
            end
            local collectables = cachedIndexCollectables
            if type(collectables) ~= "table" then
                TAB_TOTAL.indexUI.summary.Text = "Could not read the game's collectable pet list."
                return
            end

            local rows, seen = {}, {}
            local totalOwned, totalVariants = 0, 0

            for _, entry in ipairs(collectables) do
                local petId = entry.petId
                local variantId
                if entry.isGolden then
                    variantId = 2
                elseif entry.isRainbow then
                    variantId = 3
                elseif not entry.isDarkMatter then
                    variantId = 1
                end

                if petId ~= nil and variantId then
                    local id = tostring(petId)
                    local key = id .. "#" .. variantId
                    if not seen[key] then
                        seen[key] = true
                        local pet = directory[petId] or directory[id] or {}
                        local isOwned = owned[key] == true
                        local isForNearbyEgg = not nearbyEgg or nearbyEgg.petIds[id] == true
                        -- When standing beside an egg, show only missing index
                        -- variants obtainable from that egg. Outside its range
                        -- the normal complete index remains visible.
                        if isForNearbyEgg and (not nearbyEgg or not isOwned) then
                            totalVariants = totalVariants + 1
                            if isOwned then totalOwned = totalOwned + 1 end

                            local name = tostring(pet.displayName or pet.name or id)
                            local rarity = tostring(pet.rarity or "Unknown")
                            local search = (name .. " " .. rarity .. " " .. variantNames[variantId]):lower()
                            if indexQuery == "" or search:find(indexQuery, 1, true) then
                                rows[#rows + 1] = {
                                    name = name,
                                    rarity = rarity,
                                    variantId = variantId,
                                    owned = isOwned,
                                }
                            end
                        end
                    end
                end
            end

            table.sort(rows, function(a, b)
                if a.owned ~= b.owned then return not a.owned end
                if a.name ~= b.name then return a.name:lower() < b.name:lower() end
                return a.variantId < b.variantId
            end)

            -- Avoid destroying/recreating hundreds of UI instances on every
            -- proximity poll. Rebuild only when the actual displayed rows change.
            local signatureParts = { nearbyEgg and nearbyEgg.id or "all", indexQuery }
            for _, row in ipairs(rows) do
                signatureParts[#signatureParts + 1] = row.name .. "#" .. row.variantId .. (row.owned and "1" or "0")
            end
            local renderSignature = table.concat(signatureParts, "|")
            if renderSignature ~= lastIndexRenderSignature then
                lastIndexRenderSignature = renderSignature
                local function createIndexCard()
                    local card = Instance.new("Frame")
                    card.Name = "IndexPetCard"
                    card.Size = UDim2.new(1, -6, 0, 48)
                    card.BackgroundColor3 = activeTheme.surface
                    card.BackgroundTransparency = 0.12
                    card.BorderSizePixel = 0
                    do
                        local corner = Instance.new("UICorner")
                        corner.CornerRadius = UDim.new(0, 7)
                        corner.Parent = card
                    end
                    do
                        local stroke = Instance.new("UIStroke")
                        stroke.Color = activeTheme.stroke
                        stroke.Transparency = 0.65
                        stroke.Parent = card
                    end

                    local nameLabel = Instance.new("TextLabel")
                    nameLabel.Position = UDim2.fromOffset(10, 5)
                    nameLabel.Size = UDim2.new(1, -112, 0, 19)
                    nameLabel.BackgroundTransparency = 1
                    nameLabel.TextColor3 = activeTheme.text
                    nameLabel.Font = Enum.Font.GothamBold
                    nameLabel.TextSize = 12
                    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
                    nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
                    nameLabel.Parent = card

                    local detail = Instance.new("TextLabel")
                    detail.Position = UDim2.fromOffset(10, 25)
                    detail.Size = UDim2.new(1, -112, 0, 15)
                    detail.BackgroundTransparency = 1
                    detail.Font = Enum.Font.Gotham
                    detail.TextSize = 10
                    detail.TextXAlignment = Enum.TextXAlignment.Left
                    detail.Parent = card

                    local status = Instance.new("TextLabel")
                    status.AnchorPoint = Vector2.new(1, 0.5)
                    status.Position = UDim2.new(1, -8, 0.5, 0)
                    status.Size = UDim2.fromOffset(76, 24)
                    status.BorderSizePixel = 0
                    status.TextColor3 = Color3.new(1, 1, 1)
                    status.Font = Enum.Font.GothamBold
                    status.TextSize = 10
                    status.Parent = card
                    do
                        local statusCorner = Instance.new("UICorner")
                        statusCorner.CornerRadius = UDim.new(0, 5)
                        statusCorner.Parent = status
                    end
                    return { frame = card, name = nameLabel, detail = detail, status = status }
                end

                for order, row in ipairs(rows) do
                    local cardData = indexCardPool[order]
                    if not cardData then
                        cardData = createIndexCard()
                        indexCardPool[order] = cardData
                    end
                    local card = cardData.frame
                    card.LayoutOrder = order
                    card.Visible = true
                    card.Parent = TAB_TOTAL.indexUI.list
                    cardData.name.Text = row.name
                    cardData.name.TextColor3 = activeTheme.text
                    cardData.detail.Text = row.rarity .. "  •  " .. variantNames[row.variantId]
                    cardData.detail.TextColor3 = variantColors[row.variantId]
                    cardData.status.BackgroundColor3 = row.owned
                        and Color3.fromRGB(45, 145, 92) or Color3.fromRGB(100, 105, 120)
                    cardData.status.BackgroundTransparency = row.owned and 0.12 or 0.35
                    cardData.status.Text = row.owned and "OWNED" or "MISSING"
                end
                for index = #rows + 1, #indexCardPool do
                    indexCardPool[index].frame.Visible = false
                end

                if #rows == 0 then
                    if not indexEmptyLabel then
                        indexEmptyLabel = Instance.new("TextLabel")
                        indexEmptyLabel.Name = "IndexEmpty"
                        indexEmptyLabel.Size = UDim2.new(1, -6, 0, 42)
                        indexEmptyLabel.BackgroundTransparency = 1
                        indexEmptyLabel.TextColor3 = activeTheme.muted
                        indexEmptyLabel.Font = Enum.Font.Gotham
                        indexEmptyLabel.TextSize = 12
                    end
                    indexEmptyLabel.Text = nearbyEgg and "You own every indexed pet from this egg." or (indexQuery == "" and "No index entries found." or "No pets match that search.")
                    indexEmptyLabel.Visible = true
                    indexEmptyLabel.Parent = TAB_TOTAL.indexUI.list
                elseif indexEmptyLabel then
                    indexEmptyLabel.Visible = false
                end
            end

            if nearbyEgg then
                TAB_TOTAL.indexUI.summary.Text = ("%s  •  %.1f studs  •  %d missing variants"):format(
                    nearbyEgg.name, nearbyEgg.distance, #rows
                )
            else
                local percent = totalVariants > 0 and math.floor(totalOwned / totalVariants * 100 + 0.5) or 0
                TAB_TOTAL.indexUI.summary.Text = ("%d / %d variants collected (%d%%)  •  %d shown%s"):format(
                    totalOwned, totalVariants, percent, #rows, hasSave and "" or "  •  save unavailable"
                )
            end

        end

        TAB_TOTAL.indexUI.search:GetPropertyChangedSignal("Text"):Connect(function()
            indexQuery = TAB_TOTAL.indexUI.search.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
            if not searchRefreshQueued then
                searchRefreshQueued = true
                taskDelay(0.2, function()
                    searchRefreshQueued = false
                    if ui.Parent then refreshIndex() end
                end)
            end
        end)
        TAB_TOTAL.indexUI.refresh.MouseButton1Click:Connect(refreshIndex)
        taskSpawn(function()
            while ui.Parent do
                if TAB_TOTAL.indexUI.frame.Visible then refreshIndex() end
                taskWait(1.25)
            end
        end)
        refreshIndex()

        -- Keep the floating missing-pets panel independent from the normal
        -- Index list. Ownership is polled every 0.60 seconds for near-real-time
        -- updates; the heavier egg hierarchy sweep runs only every 8 seconds.
        taskSpawn(function()
            local previousTick = os.clock()
            while ui.Parent do
                local now = os.clock()
                local elapsed = math.min(now - previousTick, 0.5)
                previousTick = now
                if nearbyPanelEnabled then
                    nearbyEggTickAcc = nearbyEggTickAcc + elapsed
                    nearbyEggOwnedAcc = nearbyEggOwnedAcc + elapsed
                    nearbyEggSweepAcc = nearbyEggSweepAcc + elapsed

                    if nearbyEggSweepAcc >= NEARBY_PANEL_EGG_SWEEP then
                        nearbyEggSweepAcc = 0
                        scanNearbyPanelEggs()
                        hideNearbyGameEggInfo(true)
                    end

                    if nearbyEggTickAcc >= NEARBY_PANEL_TICK then
                        nearbyEggTickAcc = 0

                        if nearbyEggOwnedAcc >= NEARBY_PANEL_OWNED_TICK then
                            nearbyEggOwnedAcc = 0
                            if readIndexOwned then
                                local ownershipChanged = readNearbyPanelOwned()
                                if ownershipChanged then
                                    nearbyPanelLastRender = nil
                                end
                            end
                        end

                        local egg, distance = getNearestNearbyPanelEgg()
                        if not egg then
                            nearbyPanel.Visible = false
                            nearbyEggLastId = nil
                            nearbyEggRows = {}
                        else
                            nearbyPanel.Visible = true
                            if egg.id ~= nearbyEggLastId or nearbyPanelLastRender == nil then
                                nearbyEggLastId = egg.id
                                nearbyEggRows = nearbyEggHasSave and buildNearbyPanelRows(egg.cfg, nearbyEggOwned) or {}
                                renderNearbyPanel(egg, distance, nearbyEggRows)
                                nearbyPanelLastRender = egg.id .. "|" .. tostring(#nearbyEggRows)
                            else
                                local petCount, seen = 0, {}
                                for _, row in ipairs(nearbyEggRows) do
                                    if not seen[row.name] then
                                        seen[row.name] = true
                                        petCount = petCount + 1
                                    end
                                end
                                nearbyPanelSub.Text = ("%d missing variants · %d pets · %.1f studs"):format(
                                    #nearbyEggRows, petCount, distance
                                )
                            end
                        end
                    end
                elseif nearbyPanel.Visible then
                    nearbyPanel.Visible = false
                end
                taskWait(NEARBY_PANEL_TICK)
            end
        end)
    end)

    end)


-- =====================================================================
-- FAST PET SPEED (speed-multiplier hook)
--
-- How pet speed actually works in this game (read from the live scripts):
-- pets are NOT Humanoid-driven. PetRendering actors move each pet using
--   speed = petSpeed * petSpeedMult
-- where petSpeedMult comes from PlayerPet:CalculateSpeedMultiplier()
-- (base 2, +0.2 per "Pet Walkspeed" upgrade tier while farming, plus
-- Happy/Royalty/enchant/token buffs). PlayerPet has its own 1-second
-- loop that recalculates every pet's multiplier and Broadcast()s it to
-- the renderer, so hooking CalculateSpeedMultiplier is the single
-- override point: the game then spreads the speed itself.
--
-- The previous approach (writing save.Upgrades["Pet Walkspeed"] and
-- pushing Humanoid.WalkSpeed) did nothing: UpgradesPurchased is the
-- table the game reads (tier booleans I..V), and pets have no usable
-- Humanoid movement.
-- =====================================================================
-- Clamp: this is a speed MULTIPLIER (pets move at petSpeed * mult), not a
-- WalkSpeed. Old sessions persisted 100000, which would fling pets.
local FastPetSpeedValue = math.clamp(tonumber(GetSetting("FastPetSpeedValue", 50)) or 50, 1, 1000)
local FastPetSpeedApplied = false
local OriginalCalculateSpeedMultiplier = nil
local PlayerPetModule = nil

local function applyFastPetSpeed(enabled)
    FastPetSpeed = enabled == true

    if not enabled then
        -- Restore the game's own function; its 1-second recalc loop then
        -- puts every pet back on its real multiplier.
        pcall(function()
            if OriginalCalculateSpeedMultiplier and PlayerPetModule then
                PlayerPetModule.CalculateSpeedMultiplier = OriginalCalculateSpeedMultiplier
            end
        end)
        OriginalCalculateSpeedMultiplier = nil
        FastPetSpeedApplied = false
        return
    end

    pcall(function()
        PlayerPetModule = PlayerPetModule or require(ReplicatedStorage.Library.Client.PlayerPet)
        if type(PlayerPetModule) ~= "table" or type(PlayerPetModule.CalculateSpeedMultiplier) ~= "function" then
            return
        end

        local minimum = math.max(1, tonumber(FastPetSpeedValue) or 50)

        if not FastPetSpeedApplied then
            OriginalCalculateSpeedMultiplier = PlayerPetModule.CalculateSpeedMultiplier
            FastPetSpeedApplied = true
        end

        PlayerPetModule.CalculateSpeedMultiplier = function(self, ...)
            local okMult, mult = pcall(OriginalCalculateSpeedMultiplier, self, ...)
            if okMult and type(mult) == "number" then
                return math.max(mult, minimum)
            end
            return minimum
        end
    end)
end

-- The toggle row lives in the UI block above, which runs before this engine
-- is defined; publish the function through the forward slot so enable/disable
-- applies instantly (and OFF restores the real upgrade + humanoid speeds).
ApplyFastPetSpeedFn = applyFastPetSpeed

SetSetting("FastPetSpeedValue", FastPetSpeedValue, function(v)
    FastPetSpeedValue = tonumber(v) or 50
    -- Re-apply immediately when the value changes while the feature is on.
    if FastPetSpeed then
        pcall(applyFastPetSpeed, true)
    end
end)

registerCleanup(function()
    -- Restore the game's own speed calculation on unload, even if the flag
    -- was already cleared by the UI toggle.
    if FastPetSpeed or FastPetSpeedApplied then
        pcall(applyFastPetSpeed, false)
        FastPetSpeed = false
    end
end)

-- AUTO LOOTBAG PICKUP
-- Uses the existing game network API; loop remains isolated and guarded.
pcall(function()
    local AutoPickupLootbags = Library.Things:FindFirstChild("Lootbags")
    local AutoPickupLootbagSent = {}

    -- Lootbags: use the same network request as the game's Lootbags module.
    taskSpawn(function()
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
                                RawNet.fire("Collect Lootbag", id, lootbag.CFrame.Position)
                            end
                        end
                    end)
                end

                for lootbag in pairs(AutoPickupLootbagSent) do
                    if not lootbag or not lootbag.Parent then
                        AutoPickupLootbagSent[lootbag] = nil
                    end
                end
                taskWait(0.2)
            else
                taskWait(1)
            end
        end
    end)
end)

-- =====================================================================
-- EXECUTOR COMPATIBILITY - CLEANUP & RELOAD HANDLING
-- =====================================================================
-- Add cleanup function to the cleanup handlers list
registerCleanup(function()
    -- Stop all background tasks
    AutoFarmRobot = false
    AutoTap = false
    AutoTeleportClosestCoin = false
    AntiAFK = false
    AutoFarmHackerBoss = false
    AutoTokens = false
    PotatoMode = false
    AutoCollectFreeGifts = false
    AutoFarmComet = false
    FastAttackSpeed = false
    FastPetSpeed = false
    AutoBuying = false
    AutoGroupRewards = false
    AutoSpinnyWheels = false
    AutoPotionUpgrade = false
    AutoPotionUse = false
    AutoQuests = false
    AutoQuestsSide = false
    QuestCoinFilter = nil
    QuestFarmActive = false
    QuestAreaFarmWanted = false
    QuestHatchAnywhere = false
    QuestTargetEggId = nil
    QuestTargetEggLabel = nil
    QuestPlaytimeActive = false
    QuestOwnedAutoFarm = false
    AutoFarmTabActive = false
    AutoFarmTabTargetEgg = nil
    pcall(function()
        Library.Variables.AutoFarmEnabled = false
        Library.Variables.AutoFarmArea = nil
    end)
    
    -- Clean up UI elements
    pcall(function()
        if playerGui:FindFirstChild("CombinedAutomationUI") then
            playerGui.CombinedAutomationUI:Destroy()
        end
        if playerGui:FindFirstChild("CombinedAutomationAfkUI") then
            playerGui.CombinedAutomationAfkUI:Destroy()
        end
    end)
    
    -- Clean up egg open hook
    pcall(function()
        local previous = EggOpenEnv.PD_EggOpenHook
        if previous then
            if previous.replacement and previous.replacement.Connected then
                previous.replacement:Disconnect()
            end
            if previous.signal and previous.callback then
                pcall(function()
                    previous.signal:Connect(previous.callback)
                end)
            elseif previous.trigger and previous.callback then
                pcall(function()
                    local oldSignal = previous.trigger:IsA("BindableEvent") and previous.trigger.Event or previous.trigger.OnClientEvent
                    if oldSignal then oldSignal:Connect(previous.callback) end
                end)
            end
        end
    end)
    
    -- Reset globals
    EggOpenEnv.PD_EggOpenHook = nil
    EggOpenEnv.PD_EggOpenNamecallHooked = nil
    if EggOpenEnv.PD_EggOpenNamecallHookCleanup then
        EggOpenEnv.PD_EggOpenNamecallHookCleanup = nil
    end
end)

-- Script fully loaded indicator
do
    local env = getExecutorEnv()
    if type(env) == "table" then
        env.PetDimensionsLoaded = true
        env.PetDimensionsVersion = "ExecutorNeutral_v3+autoFarming"
    end
end

return {
    cleanup = runCleanup,
    isLoaded = function() return isExecutorLoaded end,
    executorType = executorType,
}

