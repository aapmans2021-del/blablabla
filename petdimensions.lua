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
    },
    -- Free-form bag for every other setting (Daycare fields, Anti-AFK
    -- interval, ...). Anything registered through SetSetting below is written
    -- to disk on every change and read back on load, so new settings persist
    -- without touching this table or the loader.
    extra = {},
}

-- ------------------------------------------------------------------
-- Generic auto-saved settings
--
-- Registering a setting makes it load and save for free. `apply` is optional
-- and is used to push the restored value into whatever runtime variable backs
-- it (Daycare.Protect, AntiAFKIntervalMinutes, ...).
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
-- REMOVED: AutoTrickOrTreat (feature deleted, see the note where its engine was).
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

-- =====================================================================
-- DAYCARE: automatic pet-team management
-- ---------------------------------------------------------------------
-- The server keeps `save.PetsEquipped` as { [slotIndex] = { uid = <uid>, ... } }
-- and every pet carries a `s` field (its size / growth score) plus `idt` and
-- `uid`. Equipping is `Library.Network.Invoke("Equip Pet", uid)` and
-- `Library.Network.Invoke("Unequip Pet", uid)` - the exact endpoints the game's
-- own Inventory GUI uses.
--
-- Daycare fills every available slot with the strongest pets you own while
-- permanently protecting the very best one (and any extra you ask it to keep),
-- so the number one pet never gets dragged into a hatch team.
-- =====================================================================
local Daycare = {
    -- ---- team management (equips the strongest pets, protects the best) ----
    Auto = false,
    Protect = 1,          -- how many top-ranked pets must NEVER be equipped
    SlotOverride = 0,     -- 0 = use save.MaxEquipped
    MinSize = 0,          -- skip pets below this power
    Interval = 10,
    -- ---- daycare queue (enroll / claim) ----
    AutoClaim = false,    -- claim every finished slot. Safe: it never enrolls.
    AutoEnroll = false,   -- permanently trash eligible pets. Irreversible!
    DryRun = true,        -- enroll does NOTHING while this is true
    ExcludeText = "",     -- comma-separated substrings to KEEP, never trash
    KeepPower = 0,        -- never auto-enroll a pet at or above this power
    EnrollBatch = 5,      -- max pets enrolled per pass
    QueueInterval = 10,
    -- ---- shared ----
    Busy = false,
    Snapshot = nil,
    LastRun = 0,
    LastQueueRun = 0,
    LastResult = "Idle",
    TopPets = {},
    EligibleCount = 0,
    EligibleSample = {},
    FreeSlots = 0,
    Queued = 0,
}

local function saveData()
    if not SaveModule or not SaveModule.Get then return nil end
    local ok, data = pcall(function() return SaveModule.Get() end)
    return (ok and type(data) == "table") and data or nil
end

local function shortNumber(value)
    value = tonumber(value) or 0
    if value >= 1e12 then return string.format("%.2fT", value / 1e12) end
    if value >= 1e9 then return string.format("%.2fB", value / 1e9) end
    if value >= 1e6 then return string.format("%.2fM", value / 1e6) end
    if value >= 1e3 then return string.format("%.2fK", value / 1e3) end
    return string.format("%.0f", value)
end

local function equippedUidSet(save)
    local set = {}
    if not save or type(save.PetsEquipped) ~= "table" then return set end
    for _, entry in pairs(save.PetsEquipped) do
        if type(entry) == "table" then
            if entry.uid then set[tostring(entry.uid)] = true end
            if entry.targetUID then set[tostring(entry.targetUID)] = true end
            if entry.euid then set[tostring(entry.euid)] = true end
        elseif type(entry) == "string" then
            set[entry] = true
        end
    end
    return set
end

-- =====================================================================
-- PET DIRECTORY
-- Rarity and the size-class flags are NOT in the save. They are only
-- published by requiring the game's own definition modules under
-- ReplicatedStorage.__DIRECTORY.Pets, each of which exposes .rarity,
-- .huge, .titanic, .gargantuan, .secret and .strengthMax.
-- Verified: 1104 definitions load on this account.
-- =====================================================================
local defCache = setmetatable({}, { __mode = "k" })

local function indexDefs()
    local petsDir = ReplicatedStorage:FindFirstChild("__DIRECTORY")
        and ReplicatedStorage.__DIRECTORY:FindFirstChild("Pets")
    if not petsDir then return 0 end
    local function walk(folder)
        for _, child in ipairs(folder:GetChildren()) do
            if child:IsA("ModuleScript") then
                if defCache[child] == nil then
                    local ok, def = pcall(require, child)
                    defCache[child] = (ok and type(def) == "table") and def or false
                end
            elseif child:IsA("Folder") then
                walk(child)
            end
        end
    end
    walk(petsDir)
    local n = 0
    for _, def in pairs(defCache) do if def then n += 1 end end
    return n
end

local defCacheNames = setmetatable({}, { __mode = "k" })
local function defForName(id)
    local name = tostring(id or "")
    local cached = defCacheNames[name]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    local petsDir = ReplicatedStorage:FindFirstChild("__DIRECTORY")
        and ReplicatedStorage.__DIRECTORY:FindFirstChild("Pets")
    local found = nil
    if petsDir then
        local stack = { petsDir }
        while #stack > 0 and not found do
            local folder = table.remove(stack)
            for _, child in ipairs(folder:GetChildren()) do
                if child:IsA("Folder") then
                    stack[#stack + 1] = child
                elseif child:IsA("ModuleScript") and child.Name == name then
                    local ok, def = pcall(require, child)
                    if ok and type(def) == "table" then found = def end
                    break
                end
            end
        end
    end
    defCacheNames[name] = found or false
    return found
end

-- Higher = more valuable. Size flags always outrank a plain rarity band.
local RARITY_RANK = {
    Basic = 1, Common = 2, Uncommon = 3, Rare = 4, Epic = 5, Legendary = 6,
    Mythical = 7, Eternal = 8, Divine = 9, Secret = 10, Mysterious = 11,
    Exclusive = 12, Supreme = 13, Ultimate = 14,
}

local function rarityRank(pet)
    local def = defForName(pet.id)
    local base = 1
    if def then
        base = RARITY_RANK[tostring(def.rarity or "")] or 1
        if def.gargantuan then base = math.max(base, 15) end
        if def.titanic then base = math.max(base, 14) end
        if def.huge then base = math.max(base, 13) end
        if def.secret then base = math.max(base, 12) end
    else
        local id = string.lower(tostring(pet.id or ""))
        if id:find("gargantuan") then base = 15
        elseif id:find("titanic") then base = 14
        elseif id:find("huge") then base = 13
        elseif id:find("secret") then base = 12 end
    end
    return base
end

-- A "power pet" is a base-rarity pet that actually carries abilities. Huge,
-- Secret, Titanic and Gargantuan pets are excluded: they cannot be equipped
-- through the normal team flow, so including them just starved the real team.
local function isPowerPet(pet)
    if type(pet) ~= "table" or not pet.uid then return false end
    local def = defForName(pet.id)
    if def and (def.huge or def.secret or def.titanic or def.gargantuan) then
        return false
    end
    local powers = pet.powers
    if type(powers) ~= "table" or next(powers) == nil then return false end
    return true
end

-- Ranking of every equipable power pet, strongest first.
-- `s` is the growth/power score; `idt` breaks ties so the order is stable.
local function rankPets()
    local save = saveData()
    if not save or type(save.Pets) ~= "table" then return {}, 0 end
    local eq = equippedUidSet(save)

    local ranked = {}
    for index, pet in pairs(save.Pets) do
        if isPowerPet(pet) then
            ranked[#ranked + 1] = {
                uid = pet.uid,
                index = tostring(index),
                id = tostring(pet.id or "?"),
                nick = tostring(pet.nk or ""),
                size = tonumber(pet.s) or 0,
                template = tonumber(pet.idt) or 0,
                equipped = eq[pet.uid] == true,
            }
        end
    end

    table.sort(ranked, function(a, b)
        if a.size ~= b.size then return a.size > b.size end
        if a.template ~= b.template then return a.template > b.template end
        return a.index < b.index
    end)

    return ranked, tonumber(save.MaxEquipped) or 0
end

local function saveTeam()
    local save = saveData()
    if not save then return false end
    Daycare.Snapshot = {}
    for uid in pairs(equippedUidSet(save)) do
        Daycare.Snapshot[#Daycare.Snapshot + 1] = uid
    end
    return #Daycare.Snapshot > 0
end

-- One re-equip pass. Only the delta is sent, so an already-correct team costs
-- zero network traffic and re-running the loop every few seconds is free.
local function applyDaycare(quiet)
    if Daycare.Busy then return false end
    local save = saveData()
    if not save or type(save.PetsEquipped) ~= "table" then return false end

    local ranked, maxEquipped = rankPets()
    if #ranked == 0 then
        Daycare.LastResult = "no pets"
        return false
    end

    local slots = Daycare.SlotOverride > 0 and Daycare.SlotOverride or maxEquipped
    slots = math.max(0, math.min(slots, maxEquipped > 0 and maxEquipped or slots))
    local protect = math.max(0, math.floor(Daycare.Protect))

    Daycare.TopPets = {}
    for i = 1, math.min(6, #ranked) do Daycare.TopPets[i] = ranked[i] end

    -- Skip the protected head of the list entirely, then take the strongest
    -- of everything below it.
    local wanted, wantedOrder = {}, {}
    for i = protect + 1, #ranked do
        local pet = ranked[i]
        if slots <= 0 or #wantedOrder < slots then
            if Daycare.MinSize <= 0 or pet.size >= Daycare.MinSize then
                wanted[pet.uid] = pet
                wantedOrder[#wantedOrder + 1] = pet
            end
        end
    end

    if #wantedOrder == 0 then
        Daycare.LastResult = "nothing eligible"
        return false
    end

    local current = equippedUidSet(save)
    local toRemove, toAdd = {}, {}
    for uid in pairs(current) do
        if not wanted[uid] then toRemove[#toRemove + 1] = uid end
    end
    for _, pet in ipairs(wantedOrder) do
        if not current[pet.uid] then toAdd[#toAdd + 1] = pet end
    end

    if #toRemove == 0 and #toAdd == 0 then
        Daycare.LastResult = string.format("ok (%d equipped, top %d protected)", #wantedOrder, protect)
        Daycare.LastRun = os.clock()
        return true
    end

    Daycare.Busy = true
    task.spawn(function()
        local removed, added = 0, 0
        -- Free slots first, then fill them. Throttling keeps the game's own
        -- inventory replication from spiking on accounts with thousands of pets.
        for _, uid in ipairs(toRemove) do
            local ok, res = pcall(function() return Library.Network.Invoke("Unequip Pet", uid) end)
            if ok and res ~= false then removed += 1 end
            task.wait(0.04)
        end
        for _, pet in ipairs(toAdd) do
            local ok, res = pcall(function() return Library.Network.Invoke("Equip Pet", pet.uid) end)
            if ok and res ~= false then added += 1 end
            task.wait(0.04)
        end

        Daycare.Busy = false
        Daycare.LastRun = os.clock()
        Daycare.LastResult = string.format("equipped %d, unequipped %d", added, removed)
        CachedPetsRefreshAt = 0
        if not quiet then print("[Daycare] " .. Daycare.LastResult) end
    end)

    return true
end

local function restoreDaycareTeam(quiet)
    if not Daycare.Snapshot or #Daycare.Snapshot == 0 then
        Daycare.LastResult = "no saved team"
        return false
    end
    local save = saveData()
    if not save then return false end

    local current = equippedUidSet(save)
    local wanted = {}
    for _, uid in ipairs(Daycare.Snapshot) do wanted[uid] = true end

    local toRemove, toAdd = {}, {}
    for uid in pairs(current) do
        if not wanted[uid] then toRemove[#toRemove + 1] = uid end
    end
    for _, uid in ipairs(Daycare.Snapshot) do
        if not current[uid] then toAdd[#toAdd + 1] = uid end
    end

    if #toRemove == 0 and #toAdd == 0 then
        Daycare.LastResult = "original team already active"
        return true
    end

    Daycare.Busy = true
    task.spawn(function()
        local removed, added = 0, 0
        for _, uid in ipairs(toRemove) do
            local ok, res = pcall(function() return Library.Network.Invoke("Unequip Pet", uid) end)
            if ok and res ~= false then removed += 1 end
            task.wait(0.04)
        end
        for _, uid in ipairs(toAdd) do
            local ok, res = pcall(function() return Library.Network.Invoke("Equip Pet", uid) end)
            if ok and res ~= false then added += 1 end
            task.wait(0.04)
        end
        Daycare.Busy = false
        Daycare.LastResult = string.format("restored: +%d / -%d", added, removed)
        CachedPetsRefreshAt = 0
        if not quiet then print("[Daycare] " .. Daycare.LastResult) end
    end)
    return true
end

-- =====================================================================
-- DAYCARE QUEUE: auto-claim and auto-enroll
--
-- Server routes, read out of Scripts.GUIs.Daycare:
--   Library.Network.Invoke("Daycare: Claim", indexOrNil)   nil = claim all
--   Library.Network.Invoke("Daycare: Compute Loot", queue)
--   Library.Network.Invoke("Daycare: Enroll", arrayOfPetUIDs)
--
-- State the server owns:
--   save.DaycareQueue / save.DaycareHardcoreQueue
--   Library.Shared.IsHardcore                  picks which queue is live
--   Library.Shared.DaycareComputeSlotsForTier(save)  -> slot budget
--
-- Enrolling is NOT reversible from this side: the game itself warns
-- "Put these pets in daycare? They cannot be taken out early!". So the
-- filter is deny-by-default and conservative. Claiming is safe, so it is a
-- separate toggle.
-- =====================================================================
local function activeQueue()
    local save = saveData()
    if type(save) ~= "table" then return nil, 0 end
    local hardcore = false
    pcall(function() hardcore = Library.Shared.IsHardcore == true end)
    local q = (hardcore and save.DaycareHardcoreQueue or save.DaycareQueue)
    if type(q) ~= "table" then return nil, 0 end
    return q, #q
end

local function freeSlots()
    local save = saveData()
    if type(save) ~= "table" then return 0 end
    local slots = 0
    pcall(function() slots = Library.Shared.DaycareComputeSlotsForTier(save) or 0 end)
    local _, used = activeQueue()
    return math.max(0, slots - used)
end

-- The exclusion bar. Comma or newline separated substrings, matched against
-- pet id, nickname AND rarity, so "wolf", "rainbow" and "legendary" all work.
local function excludedTerms()
    local terms = {}
    for piece in string.gmatch(tostring(Daycare.ExcludeText or ""), "[^,\n]+") do
        local t = string.lower(piece:match("^%s*(.-)%s*$"))
        if t ~= "" then terms[#terms + 1] = t end
    end
    return terms
end

local function isExcluded(pet, terms)
    if #terms == 0 then return false end
    local def = defForName(pet.id)
    local haystack = string.lower(
        tostring(pet.id or "") .. " " .. tostring(pet.nk or "") .. " "
        .. tostring(def and def.rarity or "")
    )
    for _, t in ipairs(terms) do
        if string.find(haystack, t, 1, true) then return true end
    end
    return false
end

-- Pets that may be permanently trashed. Everything else is kept.
--
-- This is deny-by-default and has FOUR hard guards, because enrollment cannot
-- be undone ("They cannot be taken out early!"):
--   1. equipped pets          - never touched
--   2. locked pets           - the server refuses them anyway
--   3. non-power pets         - a pet with no `powers` carries no stats, so
--                                trashing it loses nothing
--   4. non-basic-rarity pets  - this is the important one. Huge, Titanic,
--                                Gargantuan and Secret CANNOT be used in Daycare
--                                at all (the game will not accept them), and
--                                every Exclusive/Supreme/Ultimate pet is also
--                                unusable there. An earlier version only blocked
--                                rank >= 13, which let 821 Exclusive pets
--                                through and would have permanently destroyed
--                                them. Anything above Basic rarity is now
--                                refused outright.
local BASIC_RARITIES = {
    Basic = true, Common = true, Uncommon = true, Rare = true,
    Epic = true, Legendary = true, Mythical = true, Eternal = true,
}

local function petIsBasicRarity(pet)
    local def = defForName(pet.id)
    if not def then
        -- Unknown definition: refuse. Better to keep a pet than destroy one.
        return false, "unknown definition"
    end
    -- A size-class flag always means it is not a normal team pet.
    if def.huge or def.titanic or def.gargantuan or def.secret then
        return false, "size class"
    end
    local rarity = tostring(def.rarity or "")
    if rarity == "" then
        return false, "no rarity"
    end
    if not BASIC_RARITIES[rarity] then
        return false, "rarity " .. rarity
    end
    return true
end

local function petHasPowers(pet)
    local powers = pet.powers
    return type(powers) == "table" and next(powers) ~= nil
end

local function buildCandidates()
    local save = saveData()
    if type(save) ~= "table" or type(save.Pets) ~= "table" then
        return {}, "Save not ready"
    end

    local keepPower = tonumber(Daycare.KeepPower) or 0
    local terms = excludedTerms()
    local eq = equippedUidSet(save)

    local out = {}
    for _, pet in pairs(save.Pets) do
        if type(pet) == "table" and pet.uid and not eq[tostring(pet.uid)] then
            local power = tonumber(pet.s) or 0
            local rank = rarityRank(pet)
            local keep = nil

            local basic, why = petIsBasicRarity(pet)

            if pet.l then
                keep = "locked"
            elseif not basic then
                keep = "not a daycare-able rarity (" .. tostring(why) .. ")"
            elseif not petHasPowers(pet) then
                keep = "no stat powers"
            elseif #terms > 0 and isExcluded(pet, terms) then
                keep = "excluded"
            elseif keepPower > 0 and power >= keepPower then
                keep = "power >= floor"
            end

            if not keep then
                out[#out + 1] = {
                    uid = pet.uid,
                    id = tostring(pet.id or "?"),
                    nk = tostring(pet.nk or ""),
                    power = power,
                    rank = rank,
                    rainbow = pet.r == true,
                    golden = pet.g == true,
                    shiny = pet.sh == true,
                }
            end
        end
    end

    -- STRONGEST first. Enrollment is permanent, so the batch should always
    -- spend its slots on the best pets that pass the filter: if the exclude
    -- bar or the power floor is what saved your good pets, this ordering means
    -- the ones that get trashed are the weakest survivors, never the top of
    -- the list. Rarity band outranks raw power, because a Mythical is worth
    -- more than a high-power Common.
    table.sort(out, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        if a.power ~= b.power then return a.power > b.power end
        return tostring(a.uid) > tostring(b.uid)
    end)
    return out, nil
end

local function daycareClaim()
    local q, count = activeQueue()
    if count == 0 then
        Daycare.LastResult = "Queue empty"
        return false
    end
    local ok, res, err = pcall(function()
        return Library.Network.Invoke("Daycare: Claim", nil)
    end)
    if ok and res == true then
        Daycare.LastResult = string.format("Claimed %d finished slot(s)", count)
        return true
    end
    Daycare.LastResult = "Claim failed: " .. tostring(err or res or "unknown")
    return false
end

local function daycareEnroll()
    local cands, err = buildCandidates()
    if err then
        Daycare.LastResult = err
        return false
    end
    Daycare.EligibleCount = #cands

    -- Preview the TAIL of the list, because that is what a capped batch would
    -- actually consume. Matches daycareEnroll's backwards walk exactly.
    local sample = {}
    for i = 0, math.min(#cands, 8) - 1 do
        local c = cands[#cands - i]
        sample[#sample + 1] = ("%s%s  %s  %s"):format(
            c.rainbow and "[R] " or (c.golden and "[G] " or (c.shiny and "[S] " or "")),
            c.id, c.nk, shortNumber(c.power))
    end
    Daycare.EligibleSample = sample

    if #cands == 0 then
        Daycare.LastResult = "Nothing eligible to enroll"
        return false
    end

    local free = freeSlots()
    Daycare.FreeSlots = free
    if free <= 0 then
        Daycare.LastResult = "Daycare is full"
        return false
    end

    if Daycare.DryRun then
        Daycare.LastResult = string.format(
            "Dry run: %d eligible, %d free, enrolling %d (DRY RUN ON)",
            #cands, free, math.min(free, Daycare.EnrollBatch))
        return false
    end

    local n = math.min(free, math.max(1, math.floor(Daycare.EnrollBatch)), #cands)
    local uids = {}
    local names = {}
    -- `cands` is sorted STRONGEST first, so the pets we actually want to
    -- trash are at the TAIL. Walk backwards from the end of the list, or this
    -- would enroll the very best pets the filter let through.
    for i = 0, n - 1 do
        local c = cands[#cands - i]
        uids[i + 1] = c.uid
        names[i + 1] = c.id
    end

    local ok, res, err2 = pcall(function()
        return Library.Network.Invoke("Daycare: Enroll", uids)
    end)
    if ok and res == true then
        Daycare.LastResult = string.format("Enrolled %d: %s", n, table.concat(names, ", ", 1, 3))
        return true
    end
    Daycare.LastResult = "Enroll failed: " .. tostring(err2 or res or "unknown")
    return false
end

-- One combined pass used by both the manual button and the auto loop.
local function daycareQueuePass()
    local _, queued = activeQueue()
    Daycare.Queued = queued
    Daycare.FreeSlots = freeSlots()

    if Daycare.AutoClaim and queued > 0 then
        daycareClaim()
        task.wait(1.5) -- let the server settle the save before re-checking
        Daycare.Queued = select(2, activeQueue())
        Daycare.FreeSlots = freeSlots()
    end

    if Daycare.AutoEnroll and Daycare.FreeSlots > 0 then
        daycareEnroll()
    end

    Daycare.LastQueueRun = os.clock()
end

-- REMOVED: the Giant Pumpkin / Magic Wand block (auto feed, auto open, auto
-- upgrades). It was built against routes that return no values through this
-- executor, so nothing it did could be confirmed. Removed rather than left as
-- three toggles that appear to work and do nothing.

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

-- Daycare keeps the hatch team at its optimum. Hatching grows every equipped
-- pet, which reshuffles the size ranking, so the team is re-evaluated on a slow
-- interval instead of once - the delta-only apply makes a no-op pass free.
task.spawn(function()
    while true do
        if Daycare.Auto then
            local now = os.clock()
            if now - Daycare.LastRun >= math.max(2, Daycare.Interval) then
                pcall(applyDaycare, true)
            end
            task.wait(2)
        else
            task.wait(0.5)
        end
    end
end)

-- Daycare QUEUE loop: auto-claim finished slots and auto-enroll eligible pets.
-- Kept separate from the team loop because the two use different intervals and
-- the claim/enroll pass makes network calls. Claiming is safe; enrolling is
-- gated behind Daycare.DryRun, which defaults to true.
task.spawn(function()
    while true do
        if Daycare.AutoClaim or Daycare.AutoEnroll then
            local now = os.clock()
            if now - Daycare.LastQueueRun >= math.max(3, Daycare.QueueInterval) then
                pcall(daycareQueuePass)
            end
            task.wait(2)
        else
            -- Keep the readouts (queued / free slots) fresh even when idle.
            local _, queued = activeQueue()
            Daycare.Queued = queued
            Daycare.FreeSlots = freeSlots()
            task.wait(1)
        end
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

-- Every attack loop used to rebuild this list from Library.PetCmds.GetEquipped()
-- on each hit, which walks the equipped table at 20-50 Hz. It is cached and
-- refreshed on a timer; a Daycare re-equip invalidates it immediately.
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
        local now = os.clock()
        for i = #ExpeditionActiveAttacks, 1, -1 do
            local attack = ExpeditionActiveAttacks[i]
            if not attack or attack.expires <= now then
                table.remove(ExpeditionActiveAttacks, i)
            end
        end

        local engaged = AutoFarmExpedition and ExpeditionDodgeEnabled and #ExpeditionActiveAttacks > 0
        if not engaged then
            if ExpeditionDodgeActive then
                EndExpeditionDodge()
            end
            -- Nothing to react to: 40 Hz buys nothing, so drop to a slow tick.
            task.wait(0.4)
            continue
        end

        local character = localPlayer.Character
        local hrp = character and character:FindFirstChild("HumanoidRootPart")
        if not hrp then
            EndExpeditionDodge()
            task.wait(0.1)
            continue
        end

        -- Before the telegraph resolves, we can wait. Once the player's
        -- current position becomes dangerous, move immediately to a safe
        -- point inside the combat radius.
        if not IsPointDangerous(hrp.Position, now) then
            if ExpeditionDodgeActive and now >= ExpeditionDodgeUntil then
                EndExpeditionDodge()
            end
            task.wait(0.025)
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

        task.wait(0.025)
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

-- AUTUMN BOSS FX DODGE DETECTION
task.spawn(function()
    while true do
        if AutoFarmTurkey and TurkeyDodgeActive then
            task.wait(0.1)
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
        else
            if IsEvading then
                IsEvading = false
                pcall(function()
                    local character = localPlayer.Character
                    local hrp = character and character:FindFirstChild("HumanoidRootPart")
                    if hrp then hrp.CFrame = CFrame.new(147, 114, -1500) end
                end)
            end
            task.wait(0.4)
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
            elseif AutoFarmExpedition then
                targetId = CurrentExpeditionTargetId
            elseif AutoFarmRobot or AutoFarmTurkey then
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
        if AutoFarmExpedition and CurrentExpeditionTargetId
            and localPlayer:GetAttribute("ExpeditionRun") then
            pcall(function()
                if DamageRemote then
                    DamageRemote:FireServer(CurrentExpeditionTargetId)
                end
            end)
            task.wait(0.05)
        else
            task.wait(0.3)
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
        if CurrentTargetId and DamageRemote and (AutoFarmRobot or AutoFarmTurkey) then
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

        task.wait(AutoTap or AutoTeleportClosestCoin and ClosestCoinScanInterval or 0.4)
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
            task.wait(ClosestCoinHitInterval)
        else
            task.wait(0.25)
        end
    end
end)

-- AUTO TRICK OR TREAT
-- REMOVED: the Trick-or-Treat engine (config reader, house walker, the KnockHouse
-- routine and its polling loop). The route itself was real and worked - a walk to a
-- house then Invoke("TrickOrTreat: Knock", houseId) paid out candy - but the server
-- enforces MaxTravelStudsPerSecond, so any teleport to a house trips "Trick or Treat
-- paused for you" and every later knock is refused. It only ever worked at walking
-- pace, which is no faster than playing it by hand.

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
        do
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
                        label:SetAttribute(THEME_LOCKED, true)
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

    local TAB_TOTAL = 6
    local function createTabButton(text, index)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1 / TAB_TOTAL - 0.004, 0, 1, 0)
        btn.Position = UDim2.new((index - 1) / TAB_TOTAL, 0, 0, 0)
        btn.Text = text
        btn.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
        btn.TextColor3 = Color3.fromRGB(180, 180, 190)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
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

    local hatchTab = createTabButton("Hatch", 1)
    local tpTab = createTabButton("Teleport", 2)
    local settingsTab = createTabButton("Settings", 3)
    local eggTab = createTabButton("Egg Chances", 4)
    local farmTab = createTabButton("Farm", 5)
    local daycareTab = createTabButton("Daycare", 6)

    local hatchFrame = Instance.new("ScrollingFrame")
    hatchFrame.Size = UDim2.new(1, -24, 1, -96)
    hatchFrame.Position = UDim2.new(0, 12, 0, 90)
    hatchFrame.BackgroundTransparency = 1
    hatchFrame.BorderSizePixel = 0
    hatchFrame.ClipsDescendants = true
    hatchFrame.ScrollBarThickness = 5
    hatchFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    hatchFrame.CanvasSize = UDim2.new(0, 0, 0, 965)
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

    local farmFrame = Instance.new("ScrollingFrame")
    farmFrame.Name = "FarmScroll"
    farmFrame.Size = UDim2.new(1, -24, 1, -96)
    farmFrame.Position = UDim2.new(0, 12, 0, 90)
    farmFrame.BackgroundTransparency = 1
    farmFrame.BorderSizePixel = 0
    farmFrame.ScrollBarThickness = 5
    farmFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    farmFrame.Visible = false
    farmFrame.Parent = autoHatchMain
    do local _fp = Instance.new("UIPadding") _fp.PaddingBottom = UDim.new(0, 24) _fp.Parent = farmFrame end

    local daycareFrame = Instance.new("Frame")
    daycareFrame.Name = "DaycareFrame"
    daycareFrame.Size = UDim2.new(1, -24, 1, -96)
    daycareFrame.Position = UDim2.new(0, 12, 0, 90)
    daycareFrame.BackgroundTransparency = 1
    daycareFrame.Visible = false
    daycareFrame.Parent = autoHatchMain

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
-- ---- Halloween set ----
        -- Kept as its own group so the list reads as a collection rather than 77
        -- unrelated rows. Each one passes the full 10-argument set.
        makeTheme("Jack O'Lantern", Color3.fromRGB(26, 14, 8),   Color3.fromRGB(40, 22, 10),  Color3.fromRGB(55, 31, 14),  Color3.fromRGB(255, 150, 40), Color3.fromRGB(120, 180, 70), Color3.fromRGB(220, 60, 50),  Color3.fromRGB(255, 244, 230), Color3.fromRGB(214, 178, 138), Color3.fromRGB(140, 86, 36)),
        makeTheme("Ghostly",Color3.fromRGB(20, 20, 26),  Color3.fromRGB(30, 30, 38),  Color3.fromRGB(42, 42, 54),  Color3.fromRGB(235, 238, 255), Color3.fromRGB(150, 120, 200), Color3.fromRGB(200, 80, 100), Color3.fromRGB(248, 248, 255), Color3.fromRGB(178, 178, 198), Color3.fromRGB(96, 96, 120)),
        makeTheme("Witch's Brew",   Color3.fromRGB(16, 22, 14),  Color3.fromRGB(24, 34, 20),  Color3.fromRGB(33, 47, 27),  Color3.fromRGB(140, 230, 90), Color3.fromRGB(110, 170, 80), Color3.fromRGB(190, 70, 120), Color3.fromRGB(238, 248, 232), Color3.fromRGB(160, 186, 152), Color3.fromRGB(70, 96, 60)),
        makeTheme("Vampire Blood", Color3.fromRGB(20, 6, 8),    Color3.fromRGB(31, 9, 12),   Color3.fromRGB(43, 13, 16),  Color3.fromRGB(200, 30, 45), Color3.fromRGB(120, 40, 60),  Color3.fromRGB(240, 50, 60),  Color3.fromRGB(250, 232, 234), Color3.fromRGB(196, 150, 156), Color3.fromRGB(96, 34, 40)),
        makeTheme("Cauldron",      Color3.fromRGB(18, 20, 14),  Color3.fromRGB(28, 30, 21),  Color3.fromRGB(39, 42, 29),  Color3.fromRGB(180, 255, 90), Color3.fromRGB(120, 200, 90), Color3.fromRGB(210, 70, 80),  Color3.fromRGB(244, 250, 232), Color3.fromRGB(172, 182, 150), Color3.fromRGB(84, 92, 62)),
        makeTheme("Candy Corn",    Color3.fromRGB(30, 26, 18),  Color3.fromRGB(44, 38, 26),  Color3.fromRGB(60, 52, 34),  Color3.fromRGB(255, 210, 110), Color3.fromRGB(200, 170, 80), Color3.fromRGB(220, 70, 70),  Color3.fromRGB(255, 250, 238), Color3.fromRGB(212, 196, 164), Color3.fromRGB(126, 110, 76)),
        makeTheme("Cobweb",Color3.fromRGB(14, 14, 18),  Color3.fromRGB(22, 22, 28),  Color3.fromRGB(31, 31, 40),  Color3.fromRGB(190, 190, 205), Color3.fromRGB(120, 130, 170), Color3.fromRGB(190, 70, 90),  Color3.fromRGB(238, 238, 246), Color3.fromRGB(164, 164, 180), Color3.fromRGB(74, 74, 92)),
        makeTheme("Bone & Dust",   Color3.fromRGB(24, 22, 18),  Color3.fromRGB(37, 34, 28),  Color3.fromRGB(51, 47, 38),  Color3.fromRGB(226, 216, 190), Color3.fromRGB(150, 120, 80),  Color3.fromRGB(200, 80, 70),  Color3.fromRGB(248, 244, 234), Color3.fromRGB(190, 182, 164), Color3.fromRGB(98, 92, 76)),
        makeTheme("Fog Cemetery",  Color3.fromRGB(12, 16, 16),  Color3.fromRGB(20, 26, 26),  Color3.fromRGB(28, 36, 36),  Color3.fromRGB(150, 190, 180), Color3.fromRGB(90, 160, 120), Color3.fromRGB(200, 80, 90),  Color3.fromRGB(234, 242, 240), Color3.fromRGB(152, 174, 172), Color3.fromRGB(62, 80, 80)),
        makeTheme("Black Cat",     Color3.fromRGB(12, 10, 16),  Color3.fromRGB(20, 17, 26),  Color3.fromRGB(28, 24, 36),  Color3.fromRGB(190, 90, 240), Color3.fromRGB(120, 170, 110), Color3.fromRGB(225, 60, 100), Color3.fromRGB(244, 238, 252), Color3.fromRGB(176, 166, 194), Color3.fromRGB(74, 66, 92)),
        makeTheme("Pumpkin Spice", Color3.fromRGB(28, 18, 12),  Color3.fromRGB(42, 27, 17),  Color3.fromRGB(58, 38, 23),  Color3.fromRGB(240, 140, 60), Color3.fromRGB(140, 170, 90), Color3.fromRGB(210, 70, 60),  Color3.fromRGB(252, 240, 228), Color3.fromRGB(206, 180, 156), Color3.fromRGB(112, 84, 60)),
        makeTheme("Midnight Harvest", Color3.fromRGB(10, 12, 10),Color3.fromRGB(17, 20, 16),  Color3.fromRGB(25, 30, 23),  Color3.fromRGB(160, 230, 110), Color3.fromRGB(110, 180, 80),  Color3.fromRGB(215, 75, 85),  Color3.fromRGB(238, 246, 234), Color3.fromRGB(160, 180, 152), Color3.fromRGB(64, 78, 58)),
        makeTheme("Haunted Manor", Color3.fromRGB(16, 14, 20),  Color3.fromRGB(25, 22, 32),  Color3.fromRGB(35, 30, 45),  Color3.fromRGB(215, 90, 240), Color3.fromRGB(100, 160, 120), Color3.fromRGB(225, 70, 110), Color3.fromRGB(246, 240, 252), Color3.fromRGB(178, 170, 196), Color3.fromRGB(80, 72, 100)),
        makeTheme("Sour Candy",    Color3.fromRGB(20, 26, 16),  Color3.fromRGB(30, 39, 22),  Color3.fromRGB(42, 54, 30),  Color3.fromRGB(190, 255, 70), Color3.fromRGB(255, 90, 190), Color3.fromRGB(90, 190, 255), Color3.fromRGB(244, 252, 236), Color3.fromRGB(174, 196, 160), Color3.fromRGB(78, 98, 66)),
        makeTheme("Graveyard",     Color3.fromRGB(12, 14, 18),  Color3.fromRGB(20, 23, 29),  Color3.fromRGB(28, 33, 41),  Color3.fromRGB(130, 200, 210), Color3.fromRGB(100, 165, 115), Color3.fromRGB(200, 75, 90),  Color3.fromRGB(234, 242, 246), Color3.fromRGB(154, 172, 184), Color3.fromRGB(64, 76, 92)),
        makeTheme("Moonlit",       Color3.fromRGB(12, 14, 26),  Color3.fromRGB(20, 23, 40),  Color3.fromRGB(28, 33, 56),  Color3.fromRGB(190, 200, 255), Color3.fromRGB(120, 160, 210), Color3.fromRGB(210, 80, 100), Color3.fromRGB(242, 244, 255), Color3.fromRGB(166, 174, 202), Color3.fromRGB(70, 78, 110)),
        makeTheme("Scarecrow",     Color3.fromRGB(28, 22, 12),  Color3.fromRGB(42, 34, 19),  Color3.fromRGB(58, 47, 26),  Color3.fromRGB(235, 190, 80), Color3.fromRGB(130, 170, 80),  Color3.fromRGB(205, 75, 70),  Color3.fromRGB(252, 244, 226), Color3.fromRGB(206, 186, 150), Color3.fromRGB(116, 98, 60)),
        makeTheme("Torchlight",    Color3.fromRGB(20, 14, 10),  Color3.fromRGB(31, 22, 14),  Color3.fromRGB(43, 31, 19),  Color3.fromRGB(255, 140, 50), Color3.fromRGB(120, 165, 80),  Color3.fromRGB(215, 70, 60),  Color3.fromRGB(252, 238, 222), Color3.fromRGB(204, 172, 140), Color3.fromRGB(100, 74, 48)),
        makeTheme("Full Moon",     Color3.fromRGB(10, 12, 20),  Color3.fromRGB(17, 20, 32),  Color3.fromRGB(24, 28, 44),  Color3.fromRGB(215, 225, 245), Color3.fromRGB(120, 150, 190), Color3.fromRGB(205, 75, 95),  Color3.fromRGB(244, 246, 255), Color3.fromRGB(162, 170, 196), Color3.fromRGB(66, 74, 100)),
        makeTheme("Hex & Potions", Color3.fromRGB(16, 14, 24),  Color3.fromRGB(25, 22, 37),  Color3.fromRGB(35, 31, 52),  Color3.fromRGB(160, 120, 255), Color3.fromRGB(90, 175, 130), Color3.fromRGB(220, 70, 120), Color3.fromRGB(244, 240, 255), Color3.fromRGB(174, 166, 198), Color3.fromRGB(76, 68, 104)),
        makeTheme("Necromancer",   Color3.fromRGB(14, 10, 18),  Color3.fromRGB(22, 16, 29),  Color3.fromRGB(31, 23, 41),  Color3.fromRGB(150, 90, 255), Color3.fromRGB(100, 170, 120), Color3.fromRGB(215, 65, 105), Color3.fromRGB(242, 236, 250), Color3.fromRGB(170, 162, 194), Color3.fromRGB(70, 62, 96)),
        makeTheme("Pumpkin King",  Color3.fromRGB(22, 12, 8),   Color3.fromRGB(34, 19, 11),  Color3.fromRGB(47, 27, 15),  Color3.fromRGB(255, 130, 30), Color3.fromRGB(200, 90, 40),  Color3.fromRGB(230, 60, 50),  Color3.fromRGB(255, 238, 220), Color3.fromRGB(210, 176, 148), Color3.fromRGB(112, 72, 42)),
        makeTheme("Poison Brew",   Color3.fromRGB(14, 20, 12),  Color3.fromRGB(21, 31, 17),  Color3.fromRGB(30, 44, 24),  Color3.fromRGB(150, 255, 60), Color3.fromRGB(190, 210, 70),  Color3.fromRGB(210, 60, 90),  Color3.fromRGB(240, 252, 230), Color3.fromRGB(168, 190, 146), Color3.fromRGB(70, 92, 54)),
        makeTheme("Bat's Nest",    Color3.fromRGB(14, 12, 14),  Color3.fromRGB(23, 20, 23),  Color3.fromRGB(32, 28, 32),  Color3.fromRGB(175, 130, 200), Color3.fromRGB(110, 155, 110), Color3.fromRGB(205, 70, 90),  Color3.fromRGB(240, 236, 244), Color3.fromRGB(172, 168, 180), Color3.fromRGB(70, 66, 78)),
        makeTheme("Spooky Candy Apple", Color3.fromRGB(26, 12, 16), Color3.fromRGB(40, 18, 24), Color3.fromRGB(55, 25, 33),  Color3.fromRGB(235, 70, 90),  Color3.fromRGB(90, 175, 130),  Color3.fromRGB(240, 60, 80),  Color3.fromRGB(252, 232, 238), Color3.fromRGB(204, 158, 170), Color3.fromRGB(104, 54, 66)),
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
        -- The title used to be hard-coded blue, so it ignored the theme
        -- entirely and sat oddly against every palette except the default.
        autoTitle.TextColor3 = activeTheme.accent

        for _, btn in ipairs({hatchTab, tpTab, settingsTab, eggTab, farmTab, daycareTab}) do
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
        daycareFrame.Visible = false

        for _, btn in ipairs({hatchTab, tpTab, settingsTab, eggTab, farmTab, daycareTab}) do
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
    daycareTab.MouseButton1Click:Connect(function() switchTab(daycareTab, daycareFrame) end)

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
    -- REMOVED: "Turkey/Boss Farm". The Pilgrim Turkey is Autumn-only boss
    -- content (Mobs.Autumn.Boss). Verified live: the Coins container holds only
    -- Halloween content (Giant Pumpkin, Large/Small Coins, Safe, Vault), so
    -- FindTurkey() matched 0 of 5 distinct coin names and the toggle could never
    -- acquire a target. AutoFarmTurkey stays declared-but-false because the
    -- shared status-bar and damage branches still read it.
    createUnifiedToggle(farmFrame, 116, "Comet Farm", false, function(state)
        AutoFarmComet = state
        if state then
            CurrentTarget = nil
            CurrentTargetId = nil
        else
            CurrentComet = nil
            CurrentCometId = nil
        end
    end)
    createUnifiedToggle(farmFrame, 158, "Auto Tokens", false, function(state) AutoTokens = state end)
    createUnifiedToggle(farmFrame, 200, "Fast Pet Speed", false, function(state) SetFastPetSpeed(state) end)
    createUnifiedToggle(farmFrame, 242, "Fast Attack", false, function(state) FastAttackSpeed = state end)

    createUnifiedToggle(farmFrame, 326, "Hacker Boss Farm", false, function(state)
        AutoFarmHackerBoss = state
        if not state then
            CurrentHackerBoss = nil
            CurrentHackerBossId = nil
        end
    end)

    -- REMOVED: "Expedition Farm". The seven Expedition mobs
    -- (Mobs.Autumn.Expedition) only spawn during an expedition run, gated on
    -- localPlayer:GetAttribute("ExpeditionRun"). Verified live: that attribute
    -- is nil and the Autumn mobs are absent, so FindRandomExpeditionMob
    -- returned nil every tick and the dodge/attack scheduler never had a
    -- target. AutoFarmExpedition stays declared-but-false because the
    -- status-bar and damage branches still read it.


    -- REMOVED: "Auto Giant Pumpkin", "Auto Open Pumpkin" and "Auto Wand Upgrades".
    -- Their routes (HalloweenPumpkin: Feed/Open/Upgrade) return no values through
    -- this executor, so none of them could be confirmed working. Removed instead
    -- of shipping toggles that look live and do nothing.

    -- REMOVED: "Auto Trick or Treating". It reached the pumpkin houses but the
    -- server answered "Trick or Treat paused for you", which is a movement check
    -- on travel speed - it only worked when walked at under the published cap.
    createUnifiedToggle(farmFrame, 452, "Auto Tap", false, function(state)
        AutoTap = state
        if not state then
            ResetCoinTarget()
        end
    end)

    createUnifiedToggle(farmFrame, 452, "Auto Teleport to Closest Coin", false, function(state)
        AutoTeleportClosestCoin = state
        if not state and not AutoTap then
            ResetCoinTarget()
        end
    end)

    createUnifiedToggle(farmFrame, 494, "Anti AFK", false, function(state)
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


    -- REMOVED: the pumpkin control panel (protect-N box, wand-reserve box and the
    -- pumpkin status readout). Gone with the feature.
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
            if AutoBuying then
                farmStatus.Text = "Status: " .. tostring(HatchWatchdogStatus)
                farmStatus.TextColor3 = Color3.fromRGB(120, 255, 180)
            elseif AutoFarmRobot and CurrentTargetId then
                farmStatus.Text = "Status: Farming Robot #" .. CurrentTargetId
                farmStatus.TextColor3 = Color3.fromRGB(100, 255, 100)
            elseif AutoFarmTurkey and CurrentTargetId then
                if IsEvading then
                    farmStatus.Text = "Status: DODGING BOSS FX!"
                    farmStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
                else
                    farmStatus.Text = "Status: Farming Target #" .. CurrentTargetId
                    farmStatus.TextColor3 = Color3.fromRGB(255, 200, 100)
                end
            elseif AutoFarmHackerBoss and CurrentHackerBossId then
                farmStatus.Text = "Status: Farming Hacker Prime #" .. CurrentHackerBossId
                farmStatus.TextColor3 = Color3.fromRGB(120, 255, 200)
            elseif AutoFarmExpedition and CurrentExpeditionTargetId then
                if ExpeditionDodgeActive then
                    farmStatus.Text = "Status: DODGING EXPEDITION ATTACK!"
                    farmStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
                else
                    farmStatus.Text = "Status: Farming Expedition Mob #" .. CurrentExpeditionTargetId
                    farmStatus.TextColor3 = Color3.fromRGB(255, 170, 100)
                end
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
            elseif AutoFarmTurkey or AutoFarmRobot then
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
    -- DAYCARE TAB UI
    -- =====================================================================
    -- Built inside its own function: the main UI thread was already close to
    -- Luau's 200-register-per-function limit, and hoisting this block's locals
local function buildDaycareUI()
    local daycareTitle = Instance.new("TextLabel")
    daycareTitle.Size = UDim2.new(1, 0, 0, 24)
    daycareTitle.Position = UDim2.new(0, 0, 0, 0)
    daycareTitle.BackgroundTransparency = 1
    daycareTitle.Text = "AUTO PET TEAM MANAGER"
    daycareTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
    daycareTitle.Font = Enum.Font.GothamBold
    daycareTitle.TextSize = 14
    daycareTitle.TextXAlignment = Enum.TextXAlignment.Left
    daycareTitle.Parent = daycareFrame

    local daycareHint = Instance.new("TextLabel")
    daycareHint.Size = UDim2.new(1, 0, 0, 52)
    daycareHint.Position = UDim2.new(0, 0, 0, 24)
    daycareHint.BackgroundTransparency = 1
    daycareHint.Text = "TEAM: fills every slot with your strongest pets. QUEUE: claims finished slots and enrolls spare pets - only Basic-Common-Uncommon-Rare-Epic-Legendary-Mythical-Eternal pets that actually carry powers. Huge, Titanic, Gargantuan, Secret and ALL Exclusive pets can never be used in Daycare and are never touched."
    daycareHint.TextColor3 = Color3.fromRGB(190, 190, 200)
    daycareHint.Font = Enum.Font.Gotham
    daycareHint.TextSize = 11
    daycareHint.TextWrapped = true
    daycareHint.TextXAlignment = Enum.TextXAlignment.Left
    daycareHint.TextYAlignment = Enum.TextYAlignment.Top
    daycareHint.Parent = daycareFrame

    local daycareStats = Instance.new("TextLabel")
    daycareStats.Size = UDim2.new(1, 0, 0, 62)
    daycareStats.Position = UDim2.new(0, 0, 0, 78)
    daycareStats.BackgroundColor3 = activeTheme.panel
    daycareStats.BorderSizePixel = 0
    daycareStats.TextColor3 = Color3.fromRGB(190, 210, 235)
    daycareStats.Font = Enum.Font.GothamBold
    daycareStats.TextSize = 11
    daycareStats.TextWrapped = true
    daycareStats.TextXAlignment = Enum.TextXAlignment.Left
    daycareStats.TextYAlignment = Enum.TextYAlignment.Top
    daycareStats.Text = "Loading pets..."
    daycareStats.Parent = daycareFrame
    do local _c = Instance.new("UICorner") _c.CornerRadius = UDim.new(0, 8) _c.Parent = daycareStats end

    local function daycareInput(labelText, y, default, boxWidth)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(0.46, 0, 0, 28)
        lbl.Position = UDim2.new(0, 0, 0, y)
        lbl.BackgroundTransparency = 1
        lbl.Text = labelText
        lbl.TextColor3 = Color3.fromRGB(190, 190, 200)
        lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 11
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = daycareFrame

        local box = Instance.new("TextBox")
        box.Size = UDim2.new(boxWidth or 0.26, 0, 0, 28)
        box.Position = UDim2.new(0.46, 0, 0, y)
        box.BackgroundColor3 = Color3.fromRGB(35, 35, 48)
        box.BorderSizePixel = 0
        box.ClearTextOnFocus = false
        box.Text = tostring(default)
        box.PlaceholderText = "0 = off"
        box.TextColor3 = Color3.fromRGB(255, 255, 255)
        box.Font = Enum.Font.GothamBold
        box.TextSize = 12
        box.Parent = daycareFrame
        do local _c = Instance.new("UICorner") _c.CornerRadius = UDim.new(0, 6) _c.Parent = box end
        return box
    end

    -- ---- team row ----
    local protectBox = daycareInput("Protect best N pets", 148, Daycare.Protect)
    local slotsBox = daycareInput("Slots to fill (0 = max)", 180, Daycare.SlotOverride)
    local minSizeBox = daycareInput("Min power for team", 212, Daycare.MinSize)
    local intervalBox = daycareInput("Team re-check (s)", 244, Daycare.Interval)

    -- ---- exclusion bar ----
    local excludeLbl = Instance.new("TextLabel")
    excludeLbl.Size = UDim2.new(1, 0, 0, 16)
    excludeLbl.Position = UDim2.new(0, 0, 0, 280)
    excludeLbl.BackgroundTransparency = 1
    excludeLbl.Text = "EXCLUDE PETS (comma separated - these are NEVER trashed)"
    excludeLbl.TextColor3 = Color3.fromRGB(255, 150, 150)
    excludeLbl.Font = Enum.Font.GothamBold
    excludeLbl.TextSize = 10
    excludeLbl.TextXAlignment = Enum.TextXAlignment.Left
    excludeLbl.Parent = daycareFrame

    local excludeBox = Instance.new("TextBox")
    excludeBox.Size = UDim2.new(1, 0, 0, 30)
    excludeBox.Position = UDim2.new(0, 0, 0, 298)
    excludeBox.BackgroundColor3 = Color3.fromRGB(35, 35, 48)
    excludeBox.BorderSizePixel = 0
    excludeBox.ClearTextOnFocus = false
    excludeBox.Text = Daycare.ExcludeText
    excludeBox.PlaceholderText = "wolf, rainbow, legendary, my best pet name..."
    excludeBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    excludeBox.Font = Enum.Font.Gotham
    excludeBox.TextSize = 11
    excludeBox.Parent = daycareFrame
    do local _c = Instance.new("UICorner") _c.CornerRadius = UDim.new(0, 6) _c.Parent = excludeBox end

    local excludeCount = Instance.new("TextLabel")
    excludeCount.Size = UDim2.new(1, 0, 0, 16)
    excludeCount.Position = UDim2.new(0, 0, 0, 330)
    excludeCount.BackgroundTransparency = 1
    excludeCount.Text = ""
    excludeCount.TextColor3 = Color3.fromRGB(150, 200, 255)
    excludeCount.Font = Enum.Font.Gotham
    excludeCount.TextSize = 10
    excludeCount.TextXAlignment = Enum.TextXAlignment.Left
    excludeCount.Parent = daycareFrame

    -- ---- queue inputs ----
    local keepPowerBox = daycareInput("Keep power >= (0 = any)", 352, Daycare.KeepPower)
    local batchBox = daycareInput("Enroll batch size", 384, Daycare.EnrollBatch)
    local qIntervalBox = daycareInput("Queue check (s)", 416, Daycare.QueueInterval)

    local function readNumber(box, fallback)
        local value = tonumber(box.Text)
        if not value then
            box.Text = tostring(fallback)
            return fallback
        end
        return value
    end

    protectBox.FocusLost:Connect(function()
        Daycare.Protect = math.clamp(math.floor(readNumber(protectBox, Daycare.Protect)), 0, 200)
        protectBox.Text = tostring(Daycare.Protect)
        SetSetting("daycareProtect", Daycare.Protect)
    end)
    slotsBox.FocusLost:Connect(function()
        Daycare.SlotOverride = math.max(0, math.floor(readNumber(slotsBox, Daycare.SlotOverride)))
        slotsBox.Text = tostring(Daycare.SlotOverride)
        SetSetting("daycareSlots", Daycare.SlotOverride)
    end)
    minSizeBox.FocusLost:Connect(function()
        Daycare.MinSize = math.max(0, readNumber(minSizeBox, Daycare.MinSize))
        minSizeBox.Text = tostring(Daycare.MinSize)
        SetSetting("daycareMinPower", Daycare.MinSize)
    end)
    intervalBox.FocusLost:Connect(function()
        Daycare.Interval = math.clamp(readNumber(intervalBox, Daycare.Interval), 2, 600)
        intervalBox.Text = tostring(Daycare.Interval)
        SetSetting("daycareInterval", Daycare.Interval)
    end)
    excludeBox:GetPropertyChangedSignal("Text"):Connect(function()
        Daycare.ExcludeText = tostring(excludeBox.Text or "")
        SetSetting("daycareExclude", Daycare.ExcludeText)
    end)
    keepPowerBox.FocusLost:Connect(function()
        Daycare.KeepPower = math.max(0, readNumber(keepPowerBox, Daycare.KeepPower))
        keepPowerBox.Text = tostring(Daycare.KeepPower)
        SetSetting("daycareKeepPower", Daycare.KeepPower)
    end)
    batchBox.FocusLost:Connect(function()
        Daycare.EnrollBatch = math.clamp(math.floor(readNumber(batchBox, Daycare.EnrollBatch)), 1, 50)
        batchBox.Text = tostring(Daycare.EnrollBatch)
        SetSetting("daycareBatch", Daycare.EnrollBatch)
    end)
    qIntervalBox.FocusLost:Connect(function()
        Daycare.QueueInterval = math.clamp(readNumber(qIntervalBox, Daycare.QueueInterval), 3, 600)
        qIntervalBox.Text = tostring(Daycare.QueueInterval)
        SetSetting("daycareQueueInterval", Daycare.QueueInterval)
    end)

    -- Restore the Daycare values and repaint the boxes. Registered as sinks so
    -- a later SetSetting also pushes straight into the UI.
    local DAYCARE_FIELDS = {
        { key = "daycareProtect",      field = "Protect",       box = protectBox },
        { key = "daycareSlots",        field = "SlotOverride",  box = slotsBox },
        { key = "daycareMinPower",     field = "MinSize",       box = minSizeBox },
        { key = "daycareInterval",     field = "Interval",      box = intervalBox },
        { key = "daycareKeepPower",    field = "KeepPower",     box = keepPowerBox },
        { key = "daycareBatch",        field = "EnrollBatch",   box = batchBox },
        { key = "daycareQueueInterval", field = "QueueInterval", box = qIntervalBox },
    }
    for _, entry in ipairs(DAYCARE_FIELDS) do
        local v = GetSetting(entry.key, nil)
        if v ~= nil then
            Daycare[entry.field] = v
            entry.box.Text = tostring(v)
        end
    end
    local savedExclude = GetSetting("daycareExclude", nil)
    if type(savedExclude) == "string" then
        Daycare.ExcludeText = savedExclude
        excludeBox.Text = savedExclude
    end

    -- ---- toggles ----
    createUnifiedToggle(daycareFrame, 448, "Daycare Auto (Team)", false, function(state)
        Daycare.Auto = state
        if state then
            Daycare.LastRun = 0
            pcall(applyDaycare, true)
        end
    end)

    createUnifiedToggle(daycareFrame, 490, "Auto Claim Daycare", false, function(state)
        Daycare.AutoClaim = state
        Daycare.LastQueueRun = 0
    end)

    createUnifiedToggle(daycareFrame, 532, "Auto Enroll Pets", false, function(state)
        Daycare.AutoEnroll = state
        Daycare.LastQueueRun = 0
    end)

    createUnifiedToggle(daycareFrame, 574, "Enroll Dry Run", true, function(state)
        Daycare.DryRun = state
    end)

    -- ---- manual buttons ----
    local function daycareActionButton(text, y, x, color, callback)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0.31, -4, 0, 34)
        btn.Position = UDim2.new(x, 0, 0, y)
        btn.BackgroundColor3 = color
        btn.Text = text
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 10
        btn.TextWrapped = true
        btn.BorderSizePixel = 0
        btn.Parent = daycareFrame
        do local _c = Instance.new("UICorner") _c.CornerRadius = UDim.new(0, 6) _c.Parent = btn end
        btn.MouseButton1Click:Connect(callback)
        return btn
    end

    local daycareStatus = Instance.new("TextLabel")
    daycareStatus.Size = UDim2.new(1, 0, 0, 34)
    daycareStatus.Position = UDim2.new(0, 0, 0, 616)
    daycareStatus.BackgroundTransparency = 1
    daycareStatus.Text = "Ready"
    daycareStatus.TextColor3 = Color3.fromRGB(180, 180, 190)
    daycareStatus.Font = Enum.Font.GothamBold
    daycareStatus.TextSize = 11
    daycareStatus.TextWrapped = true
    daycareStatus.TextXAlignment = Enum.TextXAlignment.Left
    daycareStatus.Parent = daycareFrame

    daycareActionButton("SAVE TEAM", 656, 0, Color3.fromRGB(55, 55, 78), function()
        if saveTeam() then
            daycareStatus.Text = "Team snapshot saved."
            daycareStatus.TextColor3 = Color3.fromRGB(120, 255, 180)
        else
            daycareStatus.Text = "Could not read equipped pets."
            daycareStatus.TextColor3 = Color3.fromRGB(255, 120, 120)
        end
    end)

    daycareActionButton("APPLY TEAM", 656, 0.345, Color3.fromRGB(45, 105, 65), function()
        if applyDaycare() then
            daycareStatus.Text = "Applying best-pets team..."
            daycareStatus.TextColor3 = Color3.fromRGB(120, 255, 180)
        else
            daycareStatus.Text = "Apply failed: " .. tostring(Daycare.LastResult)
            daycareStatus.TextColor3 = Color3.fromRGB(255, 120, 120)
        end
    end)

    daycareActionButton("RESTORE TEAM", 656, 0.69, Color3.fromRGB(120, 70, 45), function()
        if restoreDaycareTeam() then
            daycareStatus.Text = "Restoring saved team..."
            daycareStatus.TextColor3 = Color3.fromRGB(255, 200, 120)
        else
            daycareStatus.Text = "Nothing saved to restore."
            daycareStatus.TextColor3 = Color3.fromRGB(255, 200, 120)
        end
    end)

    daycareActionButton("CLAIM NOW", 696, 0, Color3.fromRGB(50, 90, 130), function()
        Daycare.LastQueueRun = 0
        local ok = daycareClaim()
        daycareStatus.Text = ok and "Claimed." or ("Claim: " .. tostring(Daycare.LastResult))
        daycareStatus.TextColor3 = ok and Color3.fromRGB(120, 255, 180) or Color3.fromRGB(255, 160, 120)
    end)

    daycareActionButton("ENROLL NOW", 696, 0.345, Color3.fromRGB(130, 70, 30), function()
        local ok = daycareEnroll()
        daycareStatus.Text = tostring(Daycare.LastResult)
        daycareStatus.TextColor3 = ok and Color3.fromRGB(120, 255, 180) or Color3.fromRGB(255, 200, 120)
    end)

    daycareActionButton("REFRESH", 696, 0.69, Color3.fromRGB(60, 60, 75), function()
        Daycare.LastQueueRun = 0
        Daycare.LastRun = 0
        local cands = buildCandidates()
        Daycare.EligibleCount = #cands
        daycareStatus.Text = ("%d eligible, %d queued, %d free"):format(
            #cands, Daycare.Queued, Daycare.FreeSlots)
        daycareStatus.TextColor3 = Color3.fromRGB(180, 200, 230)
    end)

    -- ---- eligibility preview ----
    local previewTitle = Instance.new("TextLabel")
    previewTitle.Size = UDim2.new(1, 0, 0, 20)
    previewTitle.Position = UDim2.new(0, 0, 0, 740)
    previewTitle.BackgroundTransparency = 1
    previewTitle.Text = "NEXT PETS THAT WOULD BE ENROLLED (lowest ranked first)"
    previewTitle.TextColor3 = Color3.fromRGB(255, 200, 120)
    previewTitle.Font = Enum.Font.GothamBold
    previewTitle.TextSize = 11
    previewTitle.TextXAlignment = Enum.TextXAlignment.Left
    previewTitle.Parent = daycareFrame

    local protectedList = Instance.new("TextLabel")
    protectedList.Size = UDim2.new(1, 0, 0, 170)
    protectedList.Position = UDim2.new(0, 0, 0, 762)
    protectedList.BackgroundColor3 = activeTheme.panel
    protectedList.BorderSizePixel = 0
    protectedList.TextColor3 = Color3.fromRGB(200, 200, 215)
    protectedList.Font = Enum.Font.Gotham
    protectedList.TextSize = 10
    protectedList.TextWrapped = true
    protectedList.TextXAlignment = Enum.TextXAlignment.Left
    protectedList.TextYAlignment = Enum.TextYAlignment.Top
    protectedList.Text = ""
    protectedList.Parent = daycareFrame
    do local _c = Instance.new("UICorner") _c.CornerRadius = UDim.new(0, 8) _c.Parent = protectedList end

    local topList = Instance.new("TextLabel")
    topList.Size = UDim2.new(1, 0, 0, 130)
    topList.Position = UDim2.new(0, 0, 0, 940)
    topList.BackgroundColor3 = activeTheme.panel
    topList.BorderSizePixel = 0
    topList.TextColor3 = Color3.fromRGB(200, 220, 240)
    topList.Font = Enum.Font.Gotham
    topList.TextSize = 10
    topList.TextWrapped = true
    topList.TextXAlignment = Enum.TextXAlignment.Left
    topList.TextYAlignment = Enum.TextYAlignment.Top
    topList.Text = ""
    topList.Parent = daycareFrame
    do local _c = Instance.new("UICorner") _c.CornerRadius = UDim.new(0, 8) _c.Parent = topList end

    -- The Daycare tab needs to scroll: the controls alone exceed the frame.
    if not daycareFrame:FindFirstChild("Scroll") then
        local scroll = Instance.new("ScrollingFrame")
        scroll.Name = "Scroll"
        scroll.Size = UDim2.new(1, 0, 1, 0)
        scroll.Position = UDim2.new(0, 0, 0, 0)
        scroll.BackgroundTransparency = 1
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 5
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.ZIndex = 1
        scroll.Parent = daycareFrame
        local pad = Instance.new("UIPadding")
        pad.PaddingBottom = UDim.new(0, 20)
        pad.Parent = scroll
        -- reparent everything we already built into the scroller
        for _, child in ipairs(daycareFrame:GetChildren()) do
            if child ~= scroll and not child:IsA("UIPadding") then
                child.Parent = scroll
            end
        end
    end

    -- Ranking + eligibility readout. Runs at 3 Hz and only rebuilds on change.
    task.spawn(function()
        local lastSignature
        while daycareFrame and daycareFrame.Parent do
            local ok, ranked, maxEquipped = pcall(rankPets)
            if ok and type(ranked) == "table" then
                local save = saveData()
                local equipped = 0
                if save then for _ in pairs(equippedUidSet(save)) do equipped += 1 end end

                local top = {}
                for i = 1, math.min(6, #ranked) do
                    local pet = ranked[i]
                    local tag = (i <= Daycare.Protect) and " [PROTECTED]" or ""
                    top[#top + 1] = ("%d. %s%s - %s"):format(i, pet.id, tag, shortNumber(pet.size))
                end

                local cands = buildCandidates()
                Daycare.EligibleCount = #cands
                local terms = excludedTerms()
                local excludedCount = 0
                if save and #terms > 0 then
                    for _, pet in pairs(save.Pets or {}) do
                        if type(pet) == "table" and isExcluded(pet, terms) then
                            excludedCount += 1
                        end
                    end
                end
                if #terms > 0 then
                    excludeCount.Text = ("%d pet(s) match the exclude bar and are protected.")
                        :format(excludedCount)
                else
                    excludeCount.Text = "No exclusions set. Type names to protect them."
                end

                local sample = {}
                -- Mirror daycareEnroll: walk from the TAIL, because the
                -- candidate list is sorted strongest-first.
                for i = 0, math.min(#cands, 8) - 1 do
                    local c = cands[#cands - i]
                    sample[#sample + 1] = ("%s%s  %s  %s"):format(
                        c.rainbow and "[R] " or (c.golden and "[G] " or (c.shiny and "[S] " or "")),
                        c.id, c.nk, shortNumber(c.power))
                end

                local signature = table.concat({
                    tostring(#ranked), tostring(equipped), tostring(maxEquipped),
                    tostring(Daycare.Protect), tostring(Daycare.Auto), tostring(Daycare.LastResult),
                    tostring(#cands), tostring(excludedCount), tostring(Daycare.Queued),
                    tostring(Daycare.FreeSlots), tostring(Daycare.DryRun),
                    top[1] or "", top[2] or "", sample[1] or ""
                }, "|")

                if signature ~= lastSignature then
                    lastSignature = signature
                    daycareStats.Text = ("Pets: %d  |  Equipped: %d / %s  |  Eligible: %d  |  Queued: %d  |  Free: %d")
                        :format(#ranked, equipped, tostring(maxEquipped), #cands,
                            Daycare.Queued, Daycare.FreeSlots)
                    protectedList.Text = #sample > 0
                        and ("WOULD ENROLL (dry run " .. (Daycare.DryRun and "ON" or "OFF") .. "):\n"
                            .. table.concat(sample, "\n"))
                        or "No pets match the current filter."
                    topList.Text = "STRONGEST TEAM PETS (highest first)\n" .. table.concat(top, "\n")
                end
            end
            task.wait(0.33)
        end
    end)
    end
    buildDaycareUI()

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

    local statsContainer = Instance.new("Frame")
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
                    label.Text = "- " .. tostring(entryData.name)
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
                    table.insert(vlines, ("%s — R:%d  G:%d  S:%d"):format(pair[2], rb, gd, sh))
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
                            name = entry.name,
                            -- carry the rarity flags through so the webhook can
                            -- report Rainbow/Golden/Shiny instead of a bare name
                            rainbow = entry.rainbow == true,
                            golden = entry.golden == true,
                            shiny = entry.shiny == true,
                            nickname = entry.nickname,
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
                                    name = tostring(entry.name or "Unknown Pet"),
                                    rainbow = entry.rainbow == true,
                                    golden = entry.golden == true,
                                    shiny = entry.shiny == true,
                                    nickname = entry.nickname,
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
                                    webhookSend(makePayload(false, item.category, item.name, totals, item))
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
    local themeRows = {}
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

    local themeScroll = Instance.new("ScrollingFrame")
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
        check.Text = "✓"
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

	--
--  HALLOWEEN MAZE v4  (self-contained; docks into the Pet Dimensions Hub as a "Maze" tab)
--   * time-aware scarecrow planner: it treats the scarecrow as a 1-cell hitbox and only enters a cell
--     if it can be in AND out of it before the scarecrow could get within one cell of it
--   * hatching is part of the same walk loop, so fleeing / waiting / re-entering the egg is one state machine
--   * PIN MAP is polled (not event driven) so it can't desync from the hub's minimise button
-- Embedded in the combined hub script; this section runs after the hub UI is built.
--
task.spawn(function()
local env = _G
if type(getgenv) == "function" then
    local ok, executorEnv = pcall(getgenv)
    if ok and type(executorEnv) == "table" then env = executorEnv end
end
if env.HMV2 and env.HMV2.Destroy then pcall(env.HMV2.Destroy) end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local COL = {
	luck = Color3.fromRGB(255, 215, 0), egg = Color3.fromRGB(0, 255, 100), exit = Color3.fromRGB(255, 135, 85),
	scare = Color3.fromRGB(245, 105, 95), path = Color3.fromRGB(75, 180, 220), candy = Color3.fromRGB(255, 220, 110),
	bg = Color3.fromRGB(18, 27, 26), card = Color3.fromRGB(31, 44, 40), white = Color3.new(1, 1, 1),
}
-- tuning ---------------------------------------------------------------------------------------
local TURN_PENALTY = 1.12  -- real walking is slower than cellSize/speed (corners, acceleration)
local SAFETY_BUF = 0.25    -- extra seconds of margin
local STAY_SLACK = 1.5     -- seconds of spare time we need to keep standing on a cell
local ENTER_SLACK = 4.0    -- seconds of spare time we need before walking back into the egg cell (hysteresis)
local EGG_REACH = 9        -- studs from the egg centre (the game's Buy prompt is 15)
local EXIT_STOP, CANDY_STOP = 3, 3.5

-- state ----------------------------------------------------------------------------------------
local running, moveToken, jobRunning, autoOn = true, 0, false, false
local O = {slip = true, avoid = true, candyFirst = true, candyEsp = true, hatch = true, escape = true, scout = true,
	path = true, pin = false, zoom = false, minLuck = 10, hatchSeconds = 60, speed = 20}
local eggNames, eggSettings, savedEggSettings = {}, {}, {}
local rejected = setmetatable({}, {__mode = "k"})
local hatchOwned = false
local conns, esp, pools, ddLists = {}, {}, {}, {}
local lastRoute, lastRouteFloor, preview = nil, nil, nil
local Common, Client, modInst
local setStatus = function() end
local Lib; pcall(function() Lib = require(RS.Framework.Library) end)

local function bind(sig, fn) local c = sig:Connect(fn); conns[#conns + 1] = c; return c end
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end
local function corner(o, r) new("UICorner", {CornerRadius = UDim.new(0, r or 8)}, o) end

local function getCfg()
	local c = Lib and Lib.Shared and Lib.Shared.HalloweenMaze
	return type(c) == "table" and c or {}
end
O.speed = tonumber(getCfg().PlayerSpeed) or 20
do
	local seen = {}
	for _, tier in ipairs(getCfg().EggTable or {}) do
		for _, e in ipairs(tier.Eggs or {}) do
			if not seen[e[1]] then seen[e[1]] = true; eggNames[#eggNames + 1] = e[1] end
		end
	end
	if #eggNames == 0 then eggNames = {"Pumpkin Patch Egg", "Crypt Egg", "Haunted Manor Egg", "Nightmare Egg"} end
end

-- saved settings (same file / keys as v3) -------------------------------------------------------
local SFILE = "HMV2_settings.json"
do
	local okRead, s = pcall(function() return isfile and isfile(SFILE) and HttpService:JSONDecode(readfile(SFILE)) end)
	if okRead and type(s) == "table" then
		local map = {avoid = "avoid", candyFirst = "candyFirst", candyEsp = "candyEsp", hatchOn = "hatch", escapeOn = "escape",
			scoutOn = "scout", pathVisible = "path", minimapWhenHidden = "pin", zoom = "zoom"}
		for jsonKey, key in pairs(map) do if s[jsonKey] ~= nil then O[key] = s[jsonKey] == true end end
		O.minLuck = tonumber(s.minLuck) or O.minLuck
		O.hatchSeconds = tonumber(s.hatchSeconds) or O.hatchSeconds
		O.speed = tonumber(s.speed) or O.speed
		if type(s.eggSettings) == "table" then savedEggSettings = s.eggSettings end
	end
	for _, name in ipairs(eggNames) do
		local sv = savedEggSettings[name]
		sv = type(sv) == "table" and sv or {}
		eggSettings[name] = {enabled = sv.enabled ~= false, minLuck = tonumber(sv.minLuck) or O.minLuck,
			hatchSeconds = tonumber(sv.hatchSeconds) or O.hatchSeconds}
	end
end
local function saveSettings()
	pcall(function()
		if writefile then
			writefile(SFILE, HttpService:JSONEncode({speed = O.speed, avoid = O.avoid, candyFirst = O.candyFirst,
				candyEsp = O.candyEsp, zoom = O.zoom, hatchOn = O.hatch, escapeOn = O.escape, scoutOn = O.scout,
				pathVisible = O.path, minimapWhenHidden = O.pin, minLuck = O.minLuck, hatchSeconds = O.hatchSeconds,
				eggSettings = eggSettings}))
		end
	end)
end
local function settingsForEgg(name)
	local s = eggSettings[name]
	if not s then s = {enabled = true, minLuck = O.minLuck, hatchSeconds = O.hatchSeconds}; eggSettings[name] = s end
	return s
end

-- game access ----------------------------------------------------------------------------------
local function getMaze()
	local t = Workspace:FindFirstChild("__THINGS")
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
	local ok, f = pcall(function() return Workspace.__MAP.Eggs.__HMAZE.Eggs end)
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

-- geometry -------------------------------------------------------------------------------------
local gridCache = {}
local function grid(st)
	if gridCache.s ~= st.walls or gridCache.n ~= st.n then
		local w = table.create(#st.walls)
		for i = 1, #st.walls do w[i] = string.byte(st.walls, i) - 48 end
		gridCache = {s = st.walls, n = st.n, g = {n = st.n, walls = w, nb = {}, bf = {}, bfN = 0, sight = {}}}
	end
	return gridCache.g
end
local function nbrs(g, c)
	local t = g.nb[c]
	if not t then t = Common.Neighbors(g, c); g.nb[c] = t end
	return t
end
local function bfsPrev(g, src)
	local dist, prev, q, h = {[src] = 0}, {}, {src}, 1
	while q[h] do
		local c = q[h]; h += 1
		for _, nb in ipairs(nbrs(g, c)) do
			if dist[nb] == nil then dist[nb] = dist[c] + 1; prev[nb] = c; q[#q + 1] = nb end
		end
	end
	return dist, prev
end
local function bfsCached(g, src) -- read-only
	local r = g.bf[src]
	if not r then
		if g.bfN > 80 then g.bf, g.bfN = {}, 0 end
		r = (bfsPrev(g, src)); g.bf[src] = r; g.bfN += 1
	end
	return r
end
local function pathTo(prev, src, dst)
	if src == dst then return {src} end
	if prev[dst] == nil then return nil end
	local r, c = {}, dst
	while c ~= nil do table.insert(r, 1, c); if c == src then return r end; c = prev[c] end
	return nil
end
-- CellXZ is called thousands of times per plan (every neighbour lookup, every
-- sight ray, every aim point). It is pure for a given grid size, so it is
-- memoised here instead of recomputed on each BFS expansion.
local xzCache = {}
local function cellXZ(n, cell)
	local key = n
	local row = xzCache[key]
	if not row then
		row = table.create(1024)
		xzCache[key] = row
	end
	local pair = row[cell]
	if not pair then
		local x, z = Common.CellXZ(n, cell)
		pair = {x, z}
		row[cell] = pair
	end
	return pair[1], pair[2]
end
local function cellPos(st, i)
	local x, z = cellXZ(st.n, i)
	return st.origin + Vector3.new(x * st.cs, 0, z * st.cs)
end
local function posCell(st, p)
	return Common.CellAt(st.n, (p.X - st.origin.X) / st.cs, (p.Z - st.origin.Z) / st.cs)
end
-- cells that belong to dead-end branches (leaf pruning). Fleeing INTO one of these traps us.
local function dangling(g)
	if g.dang then return g.dang end
	local deg, dang, q = {}, {}, {}
	for c = 1, g.n * g.n do
		deg[c] = #nbrs(g, c)
		if deg[c] <= 1 then q[#q + 1] = c end
	end
	local h = 1
	while q[h] do
		local c = q[h]; h += 1
		dang[c] = true
		for _, nb in ipairs(nbrs(g, c)) do
			if not dang[nb] then
				deg[nb] -= 1
				if deg[nb] == 1 then q[#q + 1] = nb end
			end
		end
	end
	g.dang = dang
	return dang
end
-- cells with a straight wall-free line to `cell` (an egg's luck is only revealed from such a spot)
local function sightCells(st, g, cell)
	local cached = g.sight[cell]
	if cached then return cached[1], cached[2] end
	local vis, order = {[cell] = 0}, {cell}
	local x0, z0 = cellXZ(st.n, cell)
	for _, first in ipairs(nbrs(g, cell)) do
		local fx, fz = cellXZ(st.n, first)
		local dx, dz = fx - x0, fz - z0
		local cur, cx, cz, k = first, fx, fz, 1
		while cur do
			if vis[cur] == nil then vis[cur] = k; order[#order + 1] = cur end
			local nxt, nxx, nxz
			for _, nb in ipairs(nbrs(g, cur)) do
				local nx, nz = cellXZ(st.n, nb)
				if math.abs(nx - cx - dx) < 1e-3 and math.abs(nz - cz - dz) < 1e-3 then nxt, nxx, nxz = nb, nx, nz; break end
			end
			cur, cx, cz, k = nxt, nxx, nxz, k + 1
		end
	end
	g.sight[cell] = {vis, order}
	return vis, order
end

-- scarecrow model ------------------------------------------------------------------------------
-- The server sends one segment at a time (cell a -> cell b, t0..t1). It can only change direction on a
-- cell centre, so for the next `tb` seconds its future is known; after that it is "anywhere within reach".
local scareSeen = {}
local function monsterModel(st)
	local mon = getMonsterState()
	local now = Workspace:GetServerTimeNow()
	if mon and mon.from and mon.to then
		local a, b = cellPos(st, mon.from), cellPos(st, mon.to)
		local t0, t1 = tonumber(mon.t0) or 0, tonumber(mon.t1) or 0
		local seg = math.max(t1 - t0, 0)
		local f = seg <= 0 and (t1 <= now and 1 or 0) or math.clamp((now - t0) / seg, 0, 1)
		if seg > 0.05 and mon.from ~= mon.to then
			if scareSeen.floor ~= st.floor then scareSeen = {floor = st.floor} end
			local v = (hdist(a, b) / st.cs) / seg
			local k = mon.hunting == true and "hunt" or "walk"
			if v < 30 then scareSeen[k] = math.max(scareSeen[k] or 0, v) end
		end
		return {pos = a:Lerp(b, f), a = mon.from, b = mon.to, f = f, tb = math.max(0, t1 - now), seg = seg, hunting = mon.hunting == true}
	end
	local mz = getMaze(); local sc = mz and mz:FindFirstChild("Scarecrow")
	if sc then
		local p = sc:GetPivot().Position
		local c = posCell(st, p)
		if c then return {pos = p, a = c, b = c, f = 1, tb = 0, seg = 0, hunting = false} end
	end
end
-- worst-case scarecrow speed in cells/sec: the game's own formula, or the fastest we've actually seen
local function scareCps(st, hunting)
	local c = getCfg().Monster or {}
	local now = Workspace:GetServerTimeNow()
	local mins = math.max(0, (now - (tonumber(st.runStartedAt) or now)) / 60)
	local base = math.min(tonumber(c.SpeedMax) or 1.25, (tonumber(c.SpeedStart) or 0.5) + (tonumber(c.SpeedPerMinute) or 0.05) * mins)
	local seen = hunting and scareSeen.hunt or scareSeen.walk
	local v = math.max(base, seen or 0)
	if hunting and not scareSeen.hunt then v *= 1.25 end
	return math.max(v * 1.08, 0.3)
end

--  v5 scarecrow avoidance
local MARGIN_BASE, MARGIN_FACING = 1.0, 1.2 -- cells we keep from the scarecrow; larger if it faces / heads for us
local FACE_SIGN = 1                          -- verified: the client pivots the model with lookAt(pos, pos+heading), so LookVector = facing
local BLOCK_HIDE = 25                     -- seconds we hide out of sight before creeping back to slip past
local SLIP_LANE, SLIP_AFTER = 5.9, 3          -- game: CatchRadius 5, corridor half-width 7 (cell 16, wall 2) -> only a lane ~5.9 studs off-centre clears it
local function scareMargin(st, m, me)
	if m.hunting then return MARGIN_FACING end
	local mp, pp = m.pos, cellPos(st, me)
	local to = Vector3.new(pp.X - mp.X, 0, pp.Z - mp.Z)
	if to.Magnitude < 1e-3 then return MARGIN_FACING end
	to = to.Unit
	local a, b = cellPos(st, m.a), cellPos(st, m.b)
	local hd = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	if hd.Magnitude > 1e-3 and hd.Unit:Dot(to) > 0.3 then return MARGIN_FACING end
	local mz = getMaze(); local sc = mz and mz:FindFirstChild("Scarecrow")
	if sc then
		local lv = sc:GetPivot().LookVector * FACE_SIGN
		lv = Vector3.new(lv.X, 0, lv.Z)
		if lv.Magnitude > 1e-3 and lv.Unit:Dot(to) > 0.5 then return MARGIN_FACING end
	end
	return MARGIN_BASE
end
local function dangerCtx(st, g)
	if not O.avoid then return nil end
	local m, root = monsterModel(st), getRoot()
	if not m then return nil end
	local b = m.b or posCell(st, m.pos)
	local me = root and posCell(st, root.Position)
	if not (b and me) then return nil end
	local mt = 1 / scareCps(st, m.hunting)
	local ct = st.cs / math.max(O.speed, 1) * TURN_PENALTY
	local clearA = 0
	if m.a ~= m.b and m.f < 0.8 then clearA = (0.8 - m.f) * math.max(m.seg, mt) end
	local margin = scareMargin(st, m, me)
	local cfgM = getCfg().Monster or {}
	local mins = math.max(0, (Workspace:GetServerTimeNow() - (tonumber(st.runStartedAt) or Workspace:GetServerTimeNow())) / 60)
	local los = not m.hunting -- wandering: only being SEEN (straight wall-free line, within sense range) matters; hunting: it knows where we are
	return {m = m, st = st, g = g, dist = bfsCached(g, b), a = m.a, b = b, tb = m.tb, mt = mt, ct = ct, clearA = clearA, vd = {}, los = los,
		margin = margin, S = (tonumber(cfgM.SenseStart) or 2) + (tonumber(cfgM.SensePerMinute) or 0.6) * math.min(mins, 20) + 2,
		pad = los and (0.5 * ct + SAFETY_BUF) or (0.5 * ct + margin * mt + SAFETY_BUF), hunting = m.hunting, face = margin > MARGIN_BASE}
end
local LOS_NEAR = 3 -- cells: unseen but this close, it can still walk into us
local function eta(ctx, c) -- earliest time (s from now) cell c becomes unsafe
	local d = ctx.dist[c]
	if not ctx.los then
		if d == nil then return 1e9 end
		return ctx.tb + d * ctx.mt
	end
	local e = ctx.vd[c]
	if e == nil then
		e = 1e9
		if d ~= nil and d <= LOS_NEAR then e = ctx.tb + (d - ctx.margin) * ctx.mt end
		for x, k in pairs((sightCells(ctx.st, ctx.g, c))) do
			local dx = ctx.dist[x]
			if dx and k <= ctx.S then
				local tv = ctx.tb + dx * ctx.mt
				if tv < e then e = tv end
			end
		end
		ctx.vd[c] = e
	end
	return e
end
local function slack(ctx, c, t)
	if c == ctx.a and ctx.a ~= ctx.b and t < ctx.clearA + ctx.pad * 0.6 then return -1 end
	return eta(ctx, c) - t - ctx.pad
end
local function safeSearch(g, me, ctx, maxSteps)
	local steps, prev, order, h = {[me] = 0}, {}, {me}, 1
	while order[h] do
		local c = order[h]; h += 1
		local s = steps[c] + 1
		if s <= maxSteps then
			for _, nb in ipairs(nbrs(g, c)) do
				if steps[nb] == nil and slack(ctx, nb, s * ctx.ct) >= 0 then steps[nb] = s; prev[nb] = c; order[#order + 1] = nb end
			end
		end
	end
	return steps, prev
end

-- How many moves from `cell` to the nearest cell with 3+ exits. Standing deep
-- in a corridor is what gets you cornered, so refuge scoring now uses the
-- actual junction distance instead of a boolean "is this a dead end".
local function junctionDepth(g, cell)
	g.jd = g.jd or {}
	local d = g.jd[cell]
	if d then return d end
	local seen, q, h = {[cell] = 0}, {cell}, 1
	local best = 99
	while q[h] do
		local c = q[h]; h += 1
		local step = seen[c]
		if step > 0 and #nbrs(g, c) >= 3 then best = step; break end
		for _, nb in ipairs(nbrs(g, c)) do
			if seen[nb] == nil then seen[nb] = step + 1; q[#q + 1] = nb end
		end
	end
	g.jd[cell] = best
	return best
end
-- dead-end branch info: returns mouth cell (first junction outside the branch) and depth, or nil if `cell` is not in a dead end
local function branchInfo(g, cell)
	g.trap = g.trap or {}
	local t = g.trap[cell]
	if t == nil then
		t = false
		if dangling(g)[cell] then
			local dang, seen, q, h = dangling(g), {[cell] = 0}, {cell}, 1
			while q[h] and not t do
				local c = q[h]; h += 1
				for _, nb in ipairs(nbrs(g, c)) do
					if not dang[nb] then t = {nb, seen[c] + 1}; break end
					if seen[nb] == nil then seen[nb] = seen[c] + 1; q[#q + 1] = nb end
				end
			end
		end
		g.trap[cell] = t
	end
	if t then return t[1], t[2] end
end
-- cells where a chaser can be side-stepped: corners (2) and 2-long hallways (1.5); never dead ends
local function dodgeShape(g, c)
	if dangling(g)[c] then return 0 end
	local n = nbrs(g, c)
	if #n ~= 2 then return 0 end
	local x0, z0 = cellXZ(g.n, c)
	local x1, z1 = cellXZ(g.n, n[1])
	local x2, z2 = cellXZ(g.n, n[2])
	if math.abs(x1 + x2 - 2 * x0) > 1e-3 or math.abs(z1 + z2 - 2 * z0) > 1e-3 then return 2 end
	if #nbrs(g, n[1]) == 2 or #nbrs(g, n[2]) == 2 then return 1.5 end
	return 0
end
local function pickRefuge(g, me, ctx, steps, prevTarget, gd)
	local dang = dangling(g)
	local best, bs
	for c, s in pairs(steps) do
		if c ~= me then
			local sc = math.min(slack(ctx, c, s * ctx.ct), 8) + math.min(ctx.dist[c] or 20, 14) * 0.5 - s * 0.2 + dodgeShape(g, c) * 1.5
			if dang[c] then sc -= 12 end
			if #nbrs(g, c) >= 3 then sc += 1.5 end
			local jd = junctionDepth(g, c)
			if jd >= 99 then sc -= 8 elseif jd <= 1 then sc += 2 end
			if gd and gd[c] then sc -= gd[c] * 0.15 end
			if c == prevTarget then sc += 2.5 end
			if not bs or sc > bs then best, bs = c, sc end
		end
	end
	return best
end

-- decisive escape when no cell is "safe": best cell within 10 steps, only ever moving away from the scarecrow
local function escapePath(g, me, ctx)
	local dang = dangling(g)
	local depth, prev, order, h = {[me] = 0}, {}, {me}, 1
	local best, bs
	while order[h] do
		local c = order[h]; h += 1
		local d = depth[c]
		if c ~= me then
			local sc = math.min(ctx.dist[c] or 20, 16) - d * 0.4 + dodgeShape(g, c) - (dang[c] and 10 or 0)
			if not bs or sc > bs then best, bs = c, sc end
		end
		if d < 10 then
			for _, nb in ipairs(nbrs(g, c)) do
				if depth[nb] == nil and (ctx.dist[nb] or 99) >= (ctx.dist[c] or 99) and (ctx.dist[nb] or 99) > 0 then
					depth[nb] = d + 1; prev[nb] = c; order[#order + 1] = nb
				end
			end
		end
	end
	if best then return pathTo(prev, me, best) end
end

-- hallway zone: the corridor (chain of cells with <=2 exits) around a cell, up to and including the junctions at its ends
local function zoneOf(g, c)
	g.zone = g.zone or {}
	local z = g.zone[c]
	if z then return z end
	z = {[c] = true}
	if #nbrs(g, c) <= 2 then
		local q, h = {c}, 1
		while q[h] do
			local x = q[h]; h += 1
			for _, nb in ipairs(nbrs(g, x)) do
				if not z[nb] then
					z[nb] = true
					if #nbrs(g, nb) <= 2 then q[#q + 1] = nb end
				end
			end
		end
	end
	g.zone[c] = z
	return z
end
-- is the scarecrow anywhere in a hallway our route needs? (unless it hunts us from behind while we run away from it)
local function routeBlocked(g, route, ctx, me)
	if ctx.hunting and route[2] and (ctx.dist[route[2]] or 0) > (ctx.dist[me] or 0) then return false end
	local z, z2 = zoneOf(g, ctx.b), zoneOf(g, ctx.a)
	for i = 2, #route do
		local c = route[i]
		if z[c] or z2[c] then return true end
	end
	return false
end

-- returns route (starting at `me`), mode, spare seconds on our own cell, ctx
local function bfsAvoid(g, me, bad)
	local prev, depth, q, h = {}, {[me] = 0}, {me}, 1
	while q[h] do
		local c = q[h]; h += 1
		for _, nb in ipairs(nbrs(g, c)) do
			if depth[nb] == nil and not bad(nb) then depth[nb] = depth[c] + 1; prev[nb] = c; q[#q + 1] = nb end
		end
	end
	return prev, depth
end
-- simple + fast: walk the shortest route that avoids a small bubble around the scarecrow; break away if inside it
local function decide(st, g, me, goal, ps, opts)
	local ctx = dangerCtx(st, g)
	if not ctx then
		ps.blocked = nil
		local _, p = bfsPrev(g, me)
		return pathTo(p, me, goal), "clear", nil, nil
	end
	local now = os.clock()

	-- PANIC: our own cell is already unsafe (or about to be). No objective
	-- matters right now, so drop everything and run. This check comes before
	-- every other branch because it is the only one that is time-critical.
	if slack(ctx, me, 0) < 0.25 then
		local ep = O.escape and escapePath(g, me, ctx) or nil
		if ep and #ep > 1 then return ep, "ESCAPING", nil, ctx end
		if not O.escape then
			local bd = d[me]
			return {me}, "trapped", nil, ctx
		end
		return {me}, "trapped", nil, ctx
	end

	local d = ctx.dist

	-- Preferred route: a time-aware search. Unlike the bubble below it only
	-- rejects a cell when the scarecrow could actually reach us by the time we
	-- would be standing there, which lets it use long safe corridors the bubble
	-- would refuse, and refuses cells the bubble would happily walk into.
	local safeSteps, safePrev = safeSearch(g, me, ctx, math.min(g.n * g.n, 900))
	if safeSteps[goal] then
		ps.blocked = nil
		local route = pathTo(safePrev, me, goal)
		if route and #route > 1 and not routeBlocked(g, route, ctx, me) then
			return route, "go", slack(ctx, goal, (#route - 1) * ctx.ct), ctx
		end
	end

	-- Fallback: hard bubble around the scarecrow, shrunk once we have been
	-- stuck for a while so we never sit and wait indefinitely.
	local R = ctx.hunting and 3 or (ctx.face and 2.2 or 2)
	if ps.blocked and now - ps.blocked > 5 then R = math.min(R, 1.2) end
	local function bad(c) return (d[c] or 99) <= R end
	if O.escape and bad(me) then
		local ep = escapePath(g, me, ctx)
		if ep and #ep > 1 then return ep, "ESCAPING", nil, ctx end
	end

	local mouth, depth = branchInfo(g, goal)
	local trapBad = mouth and ctx.hunting and goal ~= me and (d[mouth] or 99) <= depth + 4
	local prev, dep = bfsAvoid(g, me, bad)
	if not trapBad and dep[goal] ~= nil then
		ps.blocked = nil
		return pathTo(prev, me, goal), "go", nil, ctx
	end

	-- No route to the goal at all: retreat to the best reachable refuge,
	-- scored with the same time-aware slack the main search uses.
	ps.blocked = ps.blocked or now
	local refugeSteps, refugePrev = safeSearch(g, me, ctx, 24)
	local best = pickRefuge(g, me, ctx, refugeSteps, ps.retreat, nil)
	if best and best ~= me then
		ps.retreat = best
		local rp = pathTo(refugePrev, me, best)
		if rp and #rp > 1 then return rp, "BACKING OFF", nil, ctx end
	end

	local dang, best2, bs = dangling(g), nil, nil
	for c, n in pairs(dep) do
		local sc = math.min(d[c] or 20, 8) - n * 0.3 + dodgeShape(g, c) - (dang[c] and 8 or 0) + (c == me and 2 or 0) + (c == ps.retreat and 3 or 0)
		if not bs or sc > bs then best2, bs = c, sc end
	end
	ps.retreat = best2
	if best2 and best2 ~= me then return pathTo(prev, me, best2), "BACKING OFF", nil, ctx end
	return {me}, "waiting", nil, ctx
end
-- cells we can walk to (plain BFS; the scarecrow bubble only matters for the main route)
local function reachSteps(st, g, me)
	return bfsCached(g, me), dangerCtx(st, g)
end
-- sprint lane: while passing the scarecrow, run the far-wall lane (>5 studs from its path = outside CatchRadius), at full speed
local function slipAim(st, aim, root)
	local m = monsterModel(st)
	if not m or hdist(root.Position, m.pos) > 2.2 * st.cs then return aim end
	local d = Vector3.new(aim.X - root.Position.X, 0, aim.Z - root.Position.Z)
	if d.Magnitude < 1e-3 then return aim end
	d = d.Unit
	local perp = Vector3.new(-d.Z, 0, d.X)
	local side = perp:Dot(Vector3.new(m.pos.X - root.Position.X, 0, m.pos.Z - root.Position.Z)) >= 0 and -1 or 1
	local c = cellPos(st, posCell(st, root.Position))
	local lat = perp:Dot(Vector3.new(root.Position.X - c.X, 0, root.Position.Z - c.Z))
	return aim + perp * (side * SLIP_LANE - lat)
end
-- blue path (pooled) ---------------------------------------------------------------------------
local pathFolder = new("Folder", {Name = "HMV2_Path"}, Workspace)
local segs, activeSegmentCount = {}, 0
local function refreshPathVisibility()
	for i, s in ipairs(segs) do s.Transparency = (O.path and i <= activeSegmentCount) and 0 or 1 end
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
	local startAt = firstIndex or 2
	local lastPx, lastPz
	for i = startAt, #route do
		local p = cellPos(st, route[i])
		local px, pz = cellXZ(st.n, route[i])
    local isTurn = i == startAt or i == #route
        if not isTurn and lastPx then
            local prev = route[i - 1]
            local ppx, ppz = cellXZ(st.n, prev)
            local nextC = route[i + 1]
            local npx, npz = cellXZ(st.n, nextC)

			if (npx - px) ~= (px - ppx) or (npz - pz) ~= (pz - ppz) then isTurn = true end
		end
		if isTurn then
			pts[#pts + 1] = Vector3.new(p.X, y, p.Z)
			lastPx, lastPz = px, pz
		end
	end
	if tp and #route <= 1 then pts[#pts + 1] = Vector3.new(tp.X, y, tp.Z) end
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
			p.Transparency = O.path and 0 or 1
			p.Size = Vector3.new(0.6, 0.6, d); p.CFrame = CFrame.lookAt((a + b) / 2, b)
		end
	end
	for i = k + 1, #segs do segs[i].Transparency = 1 end
	activeSegmentCount = k
	lastRoute, lastRouteFloor = route, st.floor
end

-- ESP ------------------------------------------------------------------------------------------
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
		espSet(egg, anyPart(egg), "Egg: " .. tostring(name or egg:GetAttribute("ID") or "Egg") .. luckText(mult, left),
			mult >= 100 and COL.luck or COL.egg, 200, 36)
	end
	local fl = mz:FindFirstChild("MazeFloor"); local ex = fl and fl:FindFirstChild("Exit")
	if ex then espSet(ex, anyPart(ex), "EXIT", COL.exit, 120, 30) end
	local sc = mz:FindFirstChild("Scarecrow")
	if sc then espSet(sc, anyPart(sc), "SCARECROW" .. scareText, COL.scare, 200, 34) end
	if O.candyEsp then
		for _, c in ipairs(candyModels()) do espSet(c, anyPart(c), " ", COL.candy, 26, 26) end
	end
	espSweep()
end

-- movement -------------------------------------------------------------------------------------
-- aim at the end of the straight run that starts at route[1]; re-centre first if we hug a wall
local function aimPoint(st, route, root, tp, routeIndex)
    local first = routeIndex or 1
    if #route - first < 1 then return Vector3.new(tp.X, root.Position.Y, tp.Z) end
    local nextIndex = first + 1
    local x0, z0 = cellXZ(st.n, route[first])
    local x1, z1 = cellXZ(st.n, route[nextIndex])
	local dx, dz = x1 - x0, z1 - z0
    local last = nextIndex
    for i = nextIndex + 1, #route do
		local px, pz = cellXZ(st.n, route[i - 1])
		local cx, cz = cellXZ(st.n, route[i])
		if math.abs(cx - px - dx) > 1e-3 or math.abs(cz - pz - dz) > 1e-3 then break end
		last = i
	end
	local p = cellPos(st, route[last])
	if last == #route and posCell(st, tp) == route[last] then p = tp end
    if last > nextIndex then
		local horizontal = math.abs(dx) > 1e-3
		local lateral = horizontal and math.abs(root.Position.Z - p.Z) or math.abs(root.Position.X - p.X)
		if lateral <= math.max(st.cs * 0.5 - 2.5, 0.5) then
			if horizontal then p = Vector3.new(p.X, p.Y, root.Position.Z) else p = Vector3.new(root.Position.X, p.Y, p.Z) end
		else
			p = cellPos(st, route[nextIndex])
		end
	end
	return Vector3.new(p.X, root.Position.Y, p.Z)
end

local function routeIndexFor(route, cell, firstIndex)
    for i = firstIndex or 1, #route do
        if route[i] == cell then return i end
    end
    return nil
end

-- returns "arrived" | "lost" | "cancelled" | "floor" | "reconsider" | "timeout" | whatever opts.onHold returns
-- opts: stay/enter (spare seconds), onHold(st, root) -> terminal result or nil, onMove(), interrupt(st, root), timeout
local function walk(token, getTarget, stop, label, opts)
	opts = opts or {}
	local s0 = getState()
	local floor0 = s0 and s0.floor
	local ps, lastPos, lastT, lastInt, lastDraw, waitStart = {}, nil, os.clock(), 0, 0, os.clock()
    local route, routeMode, routeSpare, plannedGoal, plannedAt, routeCursor, activeAim
    routeCursor = 1
	while running and token == moveToken do
		local st, root, hum = getState(), getRoot(), getHum()
		if not (st and root and hum) then task.wait(0.15); continue end
		if st.floor ~= floor0 then return "floor" end
		local tp = getTarget(st)
		if not tp then return "lost" end
		local g = grid(st)
		local me, goal = posCell(st, root.Position), posCell(st, tp)
		if not (me and goal) then task.wait(0.1); continue end
        local now = os.clock()
        if opts.interrupt and now - lastInt >= 0.3 then
			lastInt = now
			if opts.interrupt(st, root) then hum:MoveTo(root.Position); return "reconsider" end
		end
		local atGoal
		if type(stop) == "function" then atGoal = stop(st, root, tp) else atGoal = hdist(root.Position, tp) <= stop end
		if atGoal and not opts.onHold then hum:MoveTo(root.Position); return "arrived" end
        local routeIndex = route and routeIndexFor(route, me, routeCursor)
        if not routeIndex and route then
            routeIndex = routeIndexFor(route, me, 1)
        end
        if routeIndex then routeCursor = routeIndex end
        -- Holding a position is a stable state: there is no point burning a
        -- planning pass and a MoveTo every 80ms while we stand on an egg.
        local holding = atGoal and opts.onHold and (goal == me or not route or #route - routeCursor <= 0)
        local replanInterval = holding and 0.5 or 0.35
        local needsPlan = not plannedAt or now - plannedAt >= replanInterval or goal ~= plannedGoal
            or (route and not routeIndex)
        if needsPlan then
            route, routeMode, routeSpare = decide(st, g, me, goal, ps, opts)
            plannedGoal, plannedAt, routeCursor = goal, now, 1
            routeIndex = route and routeIndexFor(route, me, 1)
        end
		if not route then
            if activeAim then hum:MoveTo(root.Position); activeAim = nil end
            setStatus("no route"); task.wait(0.25); continue
        end
        if not routeIndex then
            if activeAim then hum:MoveTo(root.Position); activeAim = nil end
            setStatus("replanning route"); task.wait(0.15); continue
		end
		if hum.WalkSpeed ~= O.speed then hum.WalkSpeed = O.speed end
        local mode, s0v = routeMode, routeSpare
		if holding then
			waitStart = now
			hum:MoveTo(root.Position)
			if lastRoute then clearPath() end
			local res = opts.onHold(st, root)
			if res then return res end
			task.wait(0.1); continue
		end
		if opts.onMove then opts.onMove() end
		if opts.timeout and now - waitStart > opts.timeout then hum:MoveTo(root.Position); return "timeout" end
		local aim
        local movementTarget = tp
        if #route - routeCursor >= 1 then aim = aimPoint(st, route, root, movementTarget, routeCursor)
		elseif mode == "waiting" or mode == "trapped" or mode == "hiding" or mode == "waiting for hallway" then aim = nil
        else aim = Vector3.new(movementTarget.X, root.Position.Y, movementTarget.Z) end
        if aim and ps.slip then aim = slipAim(st, aim, root) end
        local activeCell = activeAim and posCell(st, activeAim)
        local activeIndex = activeCell and routeIndexFor(route, activeCell, routeCursor)
        local activeStillValid = activeAim and activeIndex and activeIndex > routeCursor
            and hdist(root.Position, activeAim) > st.cs * 0.35
        if activeStillValid then aim = activeAim end
        if aim then
            if not activeAim or (aim - activeAim).Magnitude >= 0.75 then
                hum:MoveTo(aim); activeAim = aim
            end
        elseif activeAim then
            hum:MoveTo(root.Position); activeAim = nil
        end
        if needsPlan and now - lastDraw >= 0.2 then
			lastDraw = now
            drawRoute(st, route, movementTarget, root.Position.Y, routeCursor)
			setStatus(("-> %s  [%s%s]"):format(label, mode, s0v and (" spare %.1fs"):format(s0v) or ""))
		end
		if aim and now - lastT > 1.2 then
            if lastPos and hdist(root.Position, lastPos) < 1 and activeAim then hum:MoveTo(activeAim) end
			lastPos, lastT = root.Position, now
		end
		task.wait((not aim or mode == "waiting" or mode == "trapped") and 0.15 or 0.08)
	end
	return "cancelled"
end


local eggWork
local candyIgnore = setmetatable({}, {__mode = "k"})
local function nearestCandy(st, g, me)
	local steps, ctx = reachSteps(st, g, me)
	local best, bd
	for _, c in ipairs(candyModels()) do
		if not candyIgnore[c] then
			local p = posOf(c); local cell = p and posCell(st, p)
			local s = cell and steps[cell]
			if s and (not ctx or (ctx.dist[cell] or 99) > 3) and (not bd or s < bd) then best, bd = c, s end
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
			setStatus("candy near scarecrow..."); task.wait(0.3); continue
		end
		idleSince = nil
		local r = walk(token, function() if c.Parent then return posOf(c) end end, CANDY_STOP, "Candy", {timeout = 25, interrupt = function(s) return autoOn and eggWork(s) end})
		if r == "reconsider" then return r end
		if r == "cancelled" or r == "floor" then return r end
		if r == "arrived" or r == "timeout" then
			tries[c] = (tries[c] or 0) + 1
			if tries[c] >= 3 or r == "timeout" then candyIgnore[c] = true end
			task.wait(0.25)
		end
	end
	return "cancelled"
end

-- egg hatching ---------------------------------------------------------------------------------
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

-- returns "done" | "rejected" | "failed" | "gone" | "lost" | "timeout" | "cancelled" | "floor"
local function hatchAt(token, egg, force)
	local name = egg:GetAttribute("ID")
	if not name then return "gone" end
	local cfg = settingsForEgg(name)
	local tHatch, reasserts, last = 0, 0, os.clock()
	local opts = {
		stay = 0, enter = 0, timeout = 150, directGoal = true,
		onMove = function() setAutoHatch(false); last = os.clock() end,
	}
	opts.onHold = function(st)
		if not egg.Parent then return "gone" end
		local now = os.clock(); local dt = math.min(now - last, 0.6); last = now
		local mult, left = eggLuck(st, egg)
		if not force then
			if mult > 0 and mult < cfg.minLuck then rejected[egg] = ("x%d below x%d"):format(mult, cfg.minLuck); return "rejected" end
			if mult == 0 and cfg.minLuck > 1 and tHatch > 20 then rejected[egg] = "luck unknown"; return "rejected" end
		end
		if left and left <= 0 then rejected[egg] = "empty"; return "done" end
		if autoHatchOn(name) then reasserts = 0
		else
			reasserts += 1
			if reasserts > 8 then rejected[egg] = "auto hatch refused"; return "failed" end
			setAutoHatch(true, name)
		end
		tHatch += dt
		setStatus(("hatching %s%s  [%ds%s]"):format(name, luckText(mult, left), tHatch, cfg.hatchSeconds > 0 and ("/" .. cfg.hatchSeconds) or ""))
		if cfg.hatchSeconds > 0 and tHatch >= cfg.hatchSeconds then rejected[egg] = "done"; return "done" end
	end
	local r = walk(token, function() if egg.Parent then return posOf(egg) end end,
		EGG_REACH, "Egg", opts)
	setAutoHatch(false)
	if r == "arrived" then r = "done" end
	if r == "timeout" then rejected[egg] = rejected[egg] or "unreachable (scarecrow)" end
	return r
end

local function pickEgg(st, g, me, allowUnknown)
	local dist = bfsCached(g, me)
	local best, bs
	for _, egg in ipairs(getEggs()) do
		local name = egg:GetAttribute("ID")
		local cfg = name and settingsForEgg(name)
		if name and cfg.enabled and not rejected[egg] then
			local mult, left = eggLuck(st, egg)
			local known = mult > 0
			if (allowUnknown or known or cfg.minLuck <= 1) and not ((known and mult < cfg.minLuck) or (left and left <= 0)) then
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
		local cfg = name and settingsForEgg(name)
		if name and cfg.enabled and not rejected[egg] then
			local mult, left = eggLuck(st, egg)
			if not ((mult > 0 and mult < cfg.minLuck) or (left and left <= 0)) then return true end
		end
	end
	return false
end

-- egg scouting: an egg's luck is only revealed from a cell with a straight line of sight to it
local scoutTried = setmetatable({}, {__mode = "k"})
local function scoutEggs(token)
	local s0 = getState(); local floor0 = s0 and s0.floor
	while running and token == moveToken do
		local st, root = getState(), getRoot()
		local me = st and root and posCell(st, root.Position)
		if not me then task.wait(0.2); continue end
		if st.floor ~= floor0 then return "floor" end
		local g = grid(st)
		local dist = bfsCached(g, me)
		local bEgg, bCell, bScore
		for _, egg in ipairs(getEggs()) do
			local name = egg:GetAttribute("ID")
			if name and settingsForEgg(name).enabled and not rejected[egg] and eggLuck(st, egg) == 0 then
				local p = posOf(egg); local ec = p and posCell(st, p)
				local tried = scoutTried[egg]
				if not tried then tried = {n = 0}; scoutTried[egg] = tried end
				if ec and tried.n < 2 then
					local d = dist[ec]
					if d and (not bScore or d < bScore) then bScore, bEgg, bCell = d, egg, ec end
				end
			end
		end
		if not bEgg then return "done" end
		local r = walk(token, function(s)
			if not bEgg.Parent or eggLuck(s, bEgg) > 0 then return nil end
			return cellPos(s, bCell)
		end, st.cs * 0.3, "Scout", {timeout = 40})
		if r == "cancelled" or r == "floor" then return r end
		local tried = scoutTried[bEgg]
		if r == "lost" and bEgg.Parent then
			local latest = getState()
			if latest and eggLuck(latest, bEgg) > 0 then return "scouted" end
		end
		if r == "arrived" then
			local t = os.clock()
			while os.clock() - t < 0.7 and bEgg.Parent do
				local s2 = getState()
				if s2 and eggLuck(s2, bEgg) > 0 then break end
				task.wait(0.1)
			end
			tried[bCell] = true; tried.n += 1
			return "scouted"
		end
		if r == "timeout" then tried[bCell] = true; tried.n += 1 end
	end
	return "cancelled"
end

-- true while there is egg work to do (a hatchable egg, or one we can still scout) - checked constantly while walking
eggWork = function(st)
	if not O.hatch then return false end
	local rt = getRoot(); local me = rt and posCell(st, rt.Position)
	if not me then return false end
	local g = grid(st)
	if pickEgg(st, g, me, not O.scout) then return true end
	if O.scout then
		local dist = bfsCached(g, me)
		for _, egg in ipairs(getEggs()) do
			local name = egg:GetAttribute("ID")
			if name and settingsForEgg(name).enabled and not rejected[egg] and eggLuck(st, egg) == 0 then
				local p = posOf(egg); local ec = p and posCell(st, p)
				local t = scoutTried[egg]
				if ec and dist[ec] and (not t or t.n < 2) then return true end
			end
		end
	end
	return false
end
local function exitTarget(st) local p = cellPos(st, st.exit); return p + Vector3.new(0, 6, 0) end
local function autoLoop(token)
	while running and token == moveToken and autoOn do
		local st = getState()
		if not st then task.wait(0.3); continue end
		local floor = st.floor
		local newFloor, startEggs = false, {}
		for _, e in ipairs(getEggs()) do startEggs[e] = true end
		if O.candyFirst then
			local root = getRoot()
			local me = root and posCell(st, root.Position)
			local pendingEgg = O.hatch and me and pickEgg(st, grid(st), me, true)
			if not pendingEgg and collectCandy(token) == "cancelled" then return end
		end
		if O.hatch then
			while running and token == moveToken and autoOn do
				local s2, root = getState(), getRoot()
				local me = s2 and root and posCell(s2, root.Position)
				if not me then break end
				if s2.floor ~= floor then newFloor = true; break end
				local egg = pickEgg(s2, grid(s2), me, not O.scout)
				if egg then
					local r = hatchAt(token, egg, false)
					if r == "cancelled" then return end
					if r == "floor" then newFloor = true; break end
					if r == "lost" or r == "gone" or r == "failed" then rejected[egg] = rejected[egg] or r end
				elseif O.scout then
					local result = scoutEggs(token)
					if result == "cancelled" then return end
					if result == "floor" then newFloor = true end
					if result ~= "scouted" then break end
				else
					break
				end
			end
		end
		if newFloor then -- we crossed the exit (or the floor changed) mid-egg-work: wait for the new eggs, then scout/hatch again
			local t0 = os.clock()
			while running and token == moveToken and autoOn and os.clock() - t0 < 8 do
				local fresh = false
				for _, e in ipairs(getEggs()) do if not startEggs[e] then fresh = true; break end end
				if fresh then break end
				setStatus("new floor - waiting for eggs"); task.wait(0.2)
			end
			task.wait(0.4)
			continue
		end
		if token ~= moveToken or not autoOn then return end
		local eggsBefore = {}
		for _, e in ipairs(getEggs()) do eggsBefore[e] = true end
		local r = walk(token, exitTarget, EXIT_STOP, "EXIT", {interrupt = eggWork})
		if r == "cancelled" then return end
		if r == "reconsider" then task.wait(0.3); continue end
		local t = os.clock()
		local eggsAppeared = false
		while running and token == moveToken do
			local s3 = getState()
			if not s3 then break end
			if s3.floor ~= floor then
				local t2 = os.clock()
				while running and token == moveToken and os.clock() - t2 < 8 do
					local list = getEggs()
					local fresh = false
					for _, e in ipairs(list) do
						if not eggsBefore[e] then fresh = true; break end
					end
					if not fresh and next(eggsBefore) == nil and #list > 0 then fresh = true end
					if fresh then break end
					setStatus("waiting for eggs to refresh"); task.wait(0.2)
				end
				task.wait(0.3)
				eggsAppeared = true
				break
			end
			if os.clock() - t > 8 then break end

			setStatus("at exit, waiting for next floor..."); task.wait(0.2)
		end
		if eggsAppeared then continue end
		task.wait(0.5)
	end
end

-- job control ----------------------------------------------------------------------------------
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
	refreshAutoBtn(); stopMotion(); clearPath(); setStatus(msg or "Stopped")
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
local function moveEgg(egg) startJob(function(t) hatchAt(t, egg, true) end) end
local function moveExit() startJob(function(t) walk(t, exitTarget, EXIT_STOP, "EXIT") end) end
local function pathEgg(egg) preview = {get = function() if egg.Parent then return posOf(egg) end end} end
local function pathExit() preview = {get = function(st) return exitTarget(st) end} end

--
-- UI
--
local old = PlayerGui:FindFirstChild("HalloweenMazeUI"); if old then old:Destroy() end
local oldPin = PlayerGui:FindFirstChild("HMV2_Pin"); if oldPin then oldPin:Destroy() end

-- dock into the hub (wait for it if it is still building)
local hubGui, hubMain, hubTabs
for _ = 1, 30 do
	hubGui = PlayerGui:FindFirstChild("CombinedAutomationUI")
	hubMain = hubGui and hubGui:FindFirstChild("AutoHatchMain")
	hubTabs = hubMain and hubMain:FindFirstChild("TabContainer")
	local n = 0
	if hubTabs then for _, c in ipairs(hubTabs:GetChildren()) do if c:IsA("TextButton") and c.Name ~= "MazeTabButton" then n += 1 end end end
	if n >= 5 then break end
	hubGui, hubMain, hubTabs = nil, nil, nil
	task.wait(0.2)
end

local W, H = 596, 614
local ownGui, Root, Win, titleBar, ddParent
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
		TextSize = ts or 14, Font = Enum.Font.GothamBold, TextXAlignment = align or Enum.TextXAlignment.Left, TextWrapped = true}, parent)
end
local function button(parent, text, size, color, cb)
	local b = new("TextButton", {Text = text, Size = size, BackgroundColor3 = color, TextColor3 = COL.white,
		Font = Enum.Font.GothamBold, TextSize = 12, BorderSizePixel = 0}, parent)
	b:SetAttribute("ThemeLocked", true)
	corner(b, 6); bind(b.MouseButton1Click, cb); return b
end

local overviewTab, eggSettingsTab, Content, eggSettingsPage, eggConfigScroll
do
	local pageNav = new("Frame", {Name = "MazePages", Size = UDim2.fromOffset(340, 30), BackgroundTransparency = 1}, Root)
	overviewTab = button(pageNav, "OVERVIEW", UDim2.new(0.5, -2, 1, 0), Color3.fromRGB(48, 105, 83), function() end)
	eggSettingsTab = button(pageNav, "EGG SETTINGS", UDim2.new(0.5, -2, 1, 0), Color3.fromRGB(38, 49, 46), function() end)
	eggSettingsTab.Position = UDim2.new(0.5, 2, 0, 0)
	Content = new("Frame", {Name = "Content", Position = UDim2.fromOffset(0, 34), Size = UDim2.new(0, 340, 1, -34), BackgroundTransparency = 1}, Root)
	new("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder}, Content)
	eggSettingsPage = new("Frame", {Name = "EggSettingsPage", Position = UDim2.fromOffset(0, 34), Size = UDim2.new(0, 340, 1, -34),
		BackgroundTransparency = 1, Visible = false}, Root)
	eggConfigScroll = new("ScrollingFrame", {Name = "EggConfigList", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
		BorderSizePixel = 0, ScrollBarThickness = 4, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y}, eggSettingsPage)
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
end

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
local function dropdown(parent, size, getText, getItems, onPick)
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
			local b = new("TextButton", {Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = Color3.fromRGB(42, 42, 50),
				Text = (it.checked and "[*] " or "[ ] ") .. it.text, TextColor3 = COL.white, Font = Enum.Font.GothamBold, TextSize = 12,
				BorderSizePixel = 0, ZIndex = 61, LayoutOrder = i, TextXAlignment = Enum.TextXAlignment.Left}, list)
			b:SetAttribute("ThemeLocked", true)
			bind(b.MouseButton1Click, function() onPick(it.key); btn.Text = getText(); closeDD() end)
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

-- window chrome (standalone) / hub tab (docked)
local tabBtn, hubBtns, origTab = nil, {}, {}
local selColor, unselColor = Color3.fromRGB(60, 140, 220), Color3.fromRGB(32, 32, 42)
if ownGui then
	label(titleBar, "HALLOWEEN MAZE v4", UDim2.new(1, -80, 1, 0), COL.white, 17).Position = UDim2.fromOffset(10, 0)
	local minimized = false
	button(titleBar, " ", UDim2.fromOffset(26, 24), Color3.fromRGB(60, 60, 70), function()
		closeDD(); minimized = not minimized
		Root.Visible = not minimized
		Win.Size = minimized and UDim2.fromOffset(W + 24, 36) or UDim2.fromOffset(W + 24, H + 50)
	end).Position = UDim2.new(1, -62, 0, 6)
	button(titleBar, " ", UDim2.fromOffset(26, 24), Color3.fromRGB(120, 45, 45), function() env.HMV2.Destroy() end).Position = UDim2.new(1, -32, 0, 6)
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
	for _, c in ipairs(hubTabs:GetChildren()) do if c:IsA("TextButton") and c.Name ~= "MazeTabButton" then hubBtns[#hubBtns + 1] = c end end
	table.sort(hubBtns, function(a, b) return a.Position.X.Scale < b.Position.X.Scale end)
	local n = #hubBtns + 1
	for i, b in ipairs(hubBtns) do
		origTab[b] = {size = b.Size, pos = b.Position}
		b.Size = UDim2.new(1 / n - 0.006, 0, 1, 0)
		b.Position = UDim2.new((i - 1) / n, 0, 0, 0)
	end
	tabBtn = new("TextButton", {Name = "MazeTabButton", Size = UDim2.new(1 / n - 0.006, 0, 1, 0),
		Position = UDim2.new((n - 1) / n, 0, 0, 0), Text = "Maze", BackgroundColor3 = unselColor,
		TextColor3 = Color3.fromRGB(180, 180, 190), Font = Enum.Font.GothamBold, TextSize = 12}, hubTabs)
	corner(tabBtn, 6)
	new("UIStroke", {Color = Color3.fromRGB(80, 80, 100), Thickness = 1, Transparency = 0.8}, tabBtn)
	local function hubColors()
		local sel, unsel
		for _, b in ipairs(hubBtns) do
			if b.TextColor3 == Color3.fromRGB(255, 255, 255) then sel = sel or b.BackgroundColor3 else unsel = unsel or b.BackgroundColor3 end
		end
		return sel, unsel
	end
	do local s, u = hubColors(); selColor, unselColor = s or selColor, u or unselColor end
	bind(tabBtn.MouseButton1Click, function()
		closeDD()
		local s, u = hubColors()
		selColor, unselColor = s or selColor, u or unselColor
		for _, c in ipairs(hubMain:GetChildren()) do
			if c ~= Root and (c:IsA("Frame") or c:IsA("ScrollingFrame")) and c.Position.Y.Offset == 90 then c.Visible = false end
		end
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

-- info card
local floorLbl, luckLbl, scareLbl, statusLbl, minimapStatusLbl
do
	local info = card(78)
	new("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder}, info)
	new("UIPadding", {PaddingLeft = UDim.new(0, 8), PaddingTop = UDim.new(0, 2)}, info)
	floorLbl = label(info, "Floor: -", UDim2.new(1, -8, 0, 22), COL.white, 14)
	luckLbl = label(info, "Luck: -", UDim2.new(1, -8, 0, 28), COL.luck, 13)
	scareLbl = label(info, "Scarecrow: -", UDim2.new(1, -8, 0, 22), COL.scare, 14)
	statusLbl = label(row(22), "Idle", UDim2.fromScale(1, 1), Color3.fromRGB(150, 210, 255), 13)
	setStatus = function(t)
		if statusLbl and statusLbl.Parent then statusLbl.Text = t end
		if minimapStatusLbl and minimapStatusLbl.Parent then minimapStatusLbl.Text = t end
	end
end

-- speed + toggles
local setZoom = function(v)
	O.zoom = v
	pcall(function() Player.CameraMaxZoomDistance = v and 120 or (tonumber(getCfg().CameraMaxZoom) or 22) end)
end
do
	local sp = row(30, true)
	label(sp, "Speed", UDim2.fromOffset(50, 28), COL.white, 14)
	local speedBox = new("TextBox", {Size = UDim2.fromOffset(60, 28), Text = tostring(O.speed), BackgroundColor3 = Color3.fromRGB(25, 25, 30),
		TextColor3 = COL.white, Font = Enum.Font.Gotham, TextSize = 14, ClearTextOnFocus = false, BorderSizePixel = 0}, sp)
	corner(speedBox, 6)
	local function applySpeed()
		local v = tonumber(speedBox.Text)
		if v and v > 0 then O.speed = math.clamp(v, 1, 100) end
		speedBox.Text = tostring(O.speed)
		saveSettings()
	end
	button(sp, "SET", UDim2.fromOffset(50, 28), Color3.fromRGB(60, 80, 60), applySpeed)
	bind(speedBox.FocusLost, applySpeed)
	label(sp, "(game: " .. tostring(getCfg().PlayerSpeed or 20) .. ")", UDim2.fromOffset(90, 28), Color3.fromRGB(170, 170, 170), 12)

	local function toggle(parent, text, key, cb, width)
		local b
		local function paint()
			b.Text = text .. (O[key] and ": ON" or ": OFF")
			b.BackgroundColor3 = O[key] and Color3.fromRGB(45, 105, 65) or Color3.fromRGB(80, 45, 45)
		end
		b = button(parent, text, width, COL.card, function() O[key] = not O[key]; paint(); saveSettings(); if cb then cb(O[key]) end end)
		b.TextSize = 11; paint(); return b
	end
	local quarter, third, half = UDim2.new(0.25, -3, 1, 0), UDim2.new(1 / 3, -3, 1, 0), UDim2.new(0.5, -3, 1, 0)
	local tg = row(28, true)
	toggle(tg, "AVOID", "avoid", nil, quarter)
	toggle(tg, "CANDY1ST", "candyFirst", nil, quarter)
	toggle(tg, "ESP", "candyEsp", nil, quarter)
	toggle(tg, "ZOOM", "zoom", setZoom, quarter)
	if O.zoom then setZoom(true) end
	local tg2 = row(28, true)
	toggle(tg2, "HATCH", "hatch", nil, third)
	toggle(tg2, "ESCAPE", "escape", nil, third)
	toggle(tg2, "SCOUT", "scout", nil, third)
	local tg3 = row(28, true)
	toggle(tg3, "PATH", "path", refreshPathVisibility, half)
	toggle(tg3, "MAP WHEN HIDDEN", "pin", nil, half)

	local ac = row(32, true)
	button(ac, "CANDY", third, Color3.fromRGB(110, 90, 30), function() startJob(collectCandy) end)
	button(ac, " EXIT", third, Color3.fromRGB(110, 55, 40), moveExit)
	button(ac, "PATH EXIT", third, Color3.fromRGB(30, 80, 130), pathExit)
	local ac2 = row(32, true)
	autoBtn = button(ac2, "AUTO: OFF", third, Color3.fromRGB(70, 60, 90), function()
		if autoOn then stopAll("Auto stopped"); return end
		startJob(function(t) autoOn = true; refreshAutoBtn(); autoLoop(t) end)
	end)
	button(ac2, "SCOUT", third, Color3.fromRGB(60, 80, 110), function() startJob(scoutEggs) end)
	button(ac2, "STOP (X)", third, Color3.fromRGB(120, 45, 45), function() stopAll() end)
end

-- egg settings page
do
	local luckOptions, seenL = {}, {}
	for _, t in ipairs(getCfg().LuckTable or {}) do
		local m = tonumber(t.Mult)
		if m and not seenL[m] then seenL[m] = true; luckOptions[#luckOptions + 1] = m end
	end
	if #luckOptions == 0 then luckOptions = {1, 2, 5, 10, 100, 1000} end
	table.sort(luckOptions)
	local timeOptions = {{15, "15 seconds"}, {30, "30 seconds"}, {60, "1 minute"}, {120, "2 minutes"}, {300, "5 minutes"},
		{600, "10 minutes"}, {0, "Until lucky eggs run out"}}
	local function timeLabel(seconds)
		for _, o in ipairs(timeOptions) do
			if o[1] == seconds then return seconds == 0 and "forever" or (o[2]:gsub(" seconds", "s"):gsub(" minutes?", "m")) end
		end
		return tostring(seconds) .. "s"
	end
	label(eggConfigScroll, "EGG TARGETS  /  individual automation rules", UDim2.new(1, -4, 0, 26), COL.luck, 12)
	for index, name in ipairs(eggNames) do
		local cfg = settingsForEgg(name)
		local frame = new("Frame", {Size = UDim2.new(1, -8, 0, 60), BackgroundColor3 = COL.card, BorderSizePixel = 0, LayoutOrder = index}, eggConfigScroll)
		corner(frame, 6)
		label(frame, name, UDim2.new(1, -10, 0, 21), COL.white, 11).Position = UDim2.fromOffset(6, 1)
		local enabledButton
		local function paintEnabled()
			enabledButton.Text = cfg.enabled and "ON" or "OFF"
			enabledButton.BackgroundColor3 = cfg.enabled and Color3.fromRGB(45, 110, 78) or Color3.fromRGB(82, 55, 49)
		end
		enabledButton = button(frame, "", UDim2.fromOffset(50, 26), COL.card, function() cfg.enabled = not cfg.enabled; paintEnabled(); saveSettings() end)
		enabledButton.Position = UDim2.fromOffset(6, 28)
		paintEnabled()
		dropdown(frame, UDim2.fromOffset(100, 26),
			function() return ("LUCK x%d+"):format(cfg.minLuck) end,
			function()
				local items = {}
				for _, v in ipairs(luckOptions) do items[#items + 1] = {key = v, text = "x" .. v .. " or better", checked = cfg.minLuck == v} end
				return items
			end,
			function(v) cfg.minLuck = v; saveSettings() end).Position = UDim2.fromOffset(62, 28)
		dropdown(frame, UDim2.fromOffset(162, 26),
			function() return "TIME " .. timeLabel(cfg.hatchSeconds) .. ") " end,
			function()
				local items = {}
				for _, o in ipairs(timeOptions) do items[#items + 1] = {key = o[1], text = o[2], checked = cfg.hatchSeconds == o[1]} end
				return items
			end,
			function(v) cfg.hatchSeconds = v; saveSettings() end).Position = UDim2.fromOffset(166, 28)
	end
end

-- eggs list
local refreshEggList
do
	label(row(22), "EGGS  (MOVE = walk + hatch)", UDim2.fromScale(1, 1), COL.egg, 14)
	local eggScroll = new("ScrollingFrame", {Name = "EggList", Size = UDim2.new(1, 0, 0, 200), BackgroundColor3 = Color3.fromRGB(25, 25, 30),
		BorderSizePixel = 0, ScrollBarThickness = 5, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, LayoutOrder = 100}, Content)
	corner(eggScroll, 8)
	new("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}, eggScroll)
	local eggRows = {}
	refreshEggList = function()
		local st = getState()
		local seen = {}
		for idx, egg in ipairs(getEggs()) do
			seen[egg] = true
			local mult, left, name = eggLuck(st, egg)
			local text = ("%s%s"):format(tostring(name or egg:GetAttribute("ID") or "Egg"), luckText(mult, left))
			if rejected[egg] then text ..= "  [x] " .. rejected[egg] end
			local r = eggRows[egg]
			if not r then
				local f = new("Frame", {Size = UDim2.new(1, -8, 0, 34), BackgroundColor3 = COL.card, BorderSizePixel = 0, LayoutOrder = idx}, eggScroll)
				corner(f, 6)
				local l = label(f, text, UDim2.new(1, -140, 1, 0), COL.egg, 11); l.Position = UDim2.fromOffset(6, 0)
				button(f, "MOVE", UDim2.fromOffset(60, 26), Color3.fromRGB(50, 80, 60), function() if egg.Parent then moveEgg(egg) end end).Position = UDim2.new(1, -130, 0.5, -13)
				button(f, "PATH", UDim2.fromOffset(60, 26), Color3.fromRGB(30, 80, 130), function() if egg.Parent then pathEgg(egg) end end).Position = UDim2.new(1, -66, 0.5, -13)
				r = {frame = f, lbl = l}; eggRows[egg] = r
			end
			r.lbl.Text = text; r.lbl.TextColor3 = mult >= 100 and COL.luck or COL.egg; r.frame.LayoutOrder = idx
		end
		for egg, r in pairs(eggRows) do
			if not seen[egg] then r.frame:Destroy(); eggRows[egg] = nil end
		end
	end
end

-- minimap + speed card (right column) and the pinned overlay ------------------------------------
local MM, speedCard, speedLbl, mapOverlayGui, mapOverlayRoot, canvas, wallLayer, dotLayer
do
	MM = new("Frame", {Name = "Minimap", Position = UDim2.fromOffset(346, 0), Size = UDim2.fromOffset(250, 292), BackgroundColor3 = COL.bg, BorderSizePixel = 0}, Root)
	corner(MM, 12)
	label(MM, "MINIMAP   you / scarecrow / exit / candy / egg", UDim2.new(1, -10, 0, 40), COL.white, 11).Position = UDim2.fromOffset(8, 0)
	canvas = new("Frame", {Position = UDim2.fromOffset(5, 44), Size = UDim2.fromOffset(240, 240), BackgroundColor3 = Color3.fromRGB(12, 12, 16),
		BorderSizePixel = 0, ClipsDescendants = true}, MM)
	wallLayer = new("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1}, canvas)
	dotLayer = new("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 5}, canvas)
	speedCard = new("Frame", {Position = UDim2.fromOffset(346, 300), Size = UDim2.fromOffset(250, 122), BackgroundColor3 = COL.card, BorderSizePixel = 0}, Root)
	corner(speedCard, 10)
	speedLbl = label(speedCard, "Speeds: -", UDim2.new(1, -16, 1, -12), Color3.fromRGB(190, 200, 215), 12)
	speedLbl.Position = UDim2.fromOffset(8, 6); speedLbl.TextYAlignment = Enum.TextYAlignment.Top

	mapOverlayGui = new("ScreenGui", {Name = "HMV2_Pin", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = false}, PlayerGui)
	local overlayScale = new("UIScale", {Scale = 1}, mapOverlayGui)
	mapOverlayRoot = new("Frame", {Name = "Overlay", Size = UDim2.fromOffset(250, 476), AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12), BackgroundTransparency = 1, Active = true}, mapOverlayGui)
	local statusCard = new("Frame", {Name = "NavigationStatus", Position = UDim2.fromOffset(0, 428), Size = UDim2.fromOffset(250, 48),
		BackgroundColor3 = COL.card, BorderSizePixel = 0}, mapOverlayRoot)
	corner(statusCard, 8)
	minimapStatusLbl = label(statusCard, "Idle", UDim2.new(1, -16, 1, -8), Color3.fromRGB(150, 210, 255), 13)
	minimapStatusLbl.Position = UDim2.fromOffset(8, 4)
	minimapStatusLbl.TextYAlignment = Enum.TextYAlignment.Center

	local function rescale()
		local cam = Workspace.CurrentCamera
		if not cam then return end
		local v = cam.ViewportSize
		overlayScale.Scale = math.max(math.min((v.X - 24) / 250, (v.Y - 24) / 476, 1), 0.35)
	end
	rescale()
	bind(Workspace:GetPropertyChangedSignal("CurrentCamera"), rescale)
	local cam = Workspace.CurrentCamera
	if cam then bind(cam:GetPropertyChangedSignal("ViewportSize"), rescale) end

	-- drag the pinned map by its status bar
	local dragging, dragStart, startPos
	bind(statusCard.InputBegan, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, i.Position, mapOverlayRoot.Position
		end
	end)
	bind(UIS.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = (i.Position - dragStart) / overlayScale.Scale
			mapOverlayRoot.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	bind(UIS.InputEnded, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end)
end

-- true while the maze tab is actually on screen (every ancestor visible, and its ScreenGui enabled)
local function mazeUiVisible()
	local cur = Root
	while cur and cur:IsA("GuiObject") do
		if not cur.Visible then return false end
		cur = cur.Parent
	end
	return cur ~= nil and (not cur:IsA("ScreenGui") or cur.Enabled)
end
local mapDetached = false
local function updatePin()
	local detach = O.pin and not mazeUiVisible()
	if detach ~= mapDetached then
		mapDetached = detach
		if detach then
			MM.Parent, MM.Position = mapOverlayRoot, UDim2.fromOffset(0, 0)
			speedCard.Parent, speedCard.Position = mapOverlayRoot, UDim2.fromOffset(0, 300)
		else
			MM.Parent, MM.Position = Root, UDim2.fromOffset(346, 0)
			speedCard.Parent, speedCard.Position = Root, UDim2.fromOffset(346, 300)
		end
	end
	mapOverlayGui.Enabled = detach
end

local mmKey
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
	if key ~= mmKey then
		mmKey = key
		wallLayer:ClearAllChildren()
		local cp = 240 / st.n
		for _, r in ipairs(Common.WallRuns(g)) do
			local x1, y1, x2, y2 = r[1], r[2], r[3], r[4]
			local f = Instance.new("Frame")
			f.BorderSizePixel = 0; f.BackgroundColor3 = Color3.fromRGB(150, 150, 170)
			if y1 == y2 then f.Position = UDim2.fromOffset(x1 * cp, y1 * cp - 1); f.Size = UDim2.fromOffset((x2 - x1) * cp, 2)
			else f.Position = UDim2.fromOffset(x1 * cp - 1, y1 * cp); f.Size = UDim2.fromOffset(2, (y2 - y1) * cp) end
			f.Parent = wallLayer
		end
	end
	local cp = 240 / st.n
	local function xy(p) return UDim2.fromOffset((p.X - st.origin.X) / st.cs * cp, (p.Z - st.origin.Z) / st.cs * cp) end
	local rt = (lastRoute and lastRouteFloor == st.floor) and lastRoute or {}
	local rd = dots("route", O.path and #rt or 0, COL.path, 4, 1)
	if O.path then for i, c in ipairs(rt) do rd[i].Position = xy(cellPos(st, c)) end end
	local cm = candyModels()
	local cd = dots("candy", #cm, COL.candy, 5, 2)
	for i, c in ipairs(cm) do local p = posOf(c); if p then cd[i].Position = xy(p) end end
	local eg = getEggs()
	local ed = dots("egg", #eg, COL.egg, 8, 3)
	for i, e in ipairs(eg) do local p = posOf(e); if p then ed[i].Position = xy(p) end end
	dots("exit", 1, COL.exit, 10, 3)[1].Position = xy(cellPos(st, st.exit))
	local m = monsterModel(st)
	local sd = dots("scare", m and 1 or 0, Color3.fromRGB(255, 50, 50), 10, 6)
	if m and sd[1] then sd[1].Position = xy(m.pos) end
	local root = getRoot()
	local pd = dots("me", root and 1 or 0, COL.white, 8, 7)
	if root and pd[1] then pd[1].Position = xy(root.Position) end
end

-- loops ----------------------------------------------------------------------------------------
local function onUpdateInfo()
	local st = getState()
	if not st then
		floorLbl.Text = "Floor: - (enter the Halloween maze)"; luckLbl.Text = "Luck: -"; scareLbl.Text = "Scarecrow: -"; scareText = ""
		speedLbl.Text = "Speeds: -"
		return
	end
	floorLbl.Text = ("Floor %d  |  Best %d  |  %dx%d  |  %d left"):format(st.floor or 0, st.best or 0, st.n, st.n, #candyModels())
	local parts = {}
	for _, e in ipairs(st.eggs or {}) do
		parts[#parts + 1] = ("%s%s"):format((tostring(e.egg or "?")):gsub(" Egg", ""), luckText(tonumber(e.mult) or 0, e.left))
	end
	luckLbl.Text = "" .. (#parts > 0 and table.concat(parts, "  |  ") or "no eggs")
	local g = grid(st)
	local root = getRoot()
	local me = root and posCell(st, root.Position)
	local m = monsterModel(st)
	if m and me then
		local b = m.b or posCell(st, m.pos)
		local d = b and (bfsCached(g, me)[b] or 99) or 99
		scareText = ("  %d%s"):format(d, m.hunting and " HUNT" or "")
		scareLbl.Text = ("Scarecrow: %d cells away%s"):format(d, m.hunting and " | HUNTING" or "")
		scareLbl.TextColor3 = d <= 3 and Color3.fromRGB(255, 80, 80) or COL.scare
		local unknown = 0
		for _, e in ipairs(getEggs()) do if eggLuck(st, e) == 0 then unknown += 1 end end
		speedLbl.Text = ("You: %.2f cells/s\nScarecrow (worst case): %.2f cells/s\n  seen walk %s  hunt %s\nUnknown-luck eggs: %d\nLuck: %s"):format(
			O.speed / st.cs, scareCps(st, m.hunting), scareSeen.walk and ("%.2f"):format(scareSeen.walk) or "?",
			scareSeen.hunt and ("%.2f"):format(scareSeen.hunt) or "?", unknown,
			#parts > 0 and table.concat(parts, " | ") or "no eggs")
	else
		scareText = ""; scareLbl.Text = "Scarecrow: not found"; scareLbl.TextColor3 = COL.scare
		speedLbl.Text = "Speeds: scarecrow not found"
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
loop(0.2, updateMinimap)
loop(0.2, updatePin)
loop(0.25, function() -- blue path preview while idle
	if preview and not jobRunning then
		local st, root = getState(), getRoot()
		local tp = st and preview.get(st)
		local me = st and root and posCell(st, root.Position)
		local goal = tp and posCell(st, tp)
		if me and goal then
			local route, mode = decide(st, grid(st), me, goal, {}, {})
			if route then drawRoute(st, route, tp, root.Position.Y); setStatus("PATH preview [" .. mode .. "]") end
		end
	end
end)
bind(UIS.InputBegan, function(i, gp)
	if not gp and i.KeyCode == Enum.KeyCode.X then stopAll() end
end)
bind(RunService.Heartbeat, function()
	local hum = getHum()
	if hum and hum.WalkSpeed ~= O.speed and (jobRunning or autoOn) then hum.WalkSpeed = O.speed end
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
env.HMV2 = {Destroy = destroy, GetState = getState, Opt = O,
	Test = function()
		local st, root = getState(), getRoot()
		if not (st and root) then return "no state" end
		local me = posCell(st, root.Position)
		local route, mode, spare = decide(st, grid(st), me, st.exit, {}, {})
		return {floor = st.floor, n = st.n, me = me, exit = st.exit, len = route and #route, mode = mode, spare = spare,
			seen = scareSeen, candies = #candyModels(), eggs = #getEggs(), docked = hubMain ~= nil}
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
		settingsForEgg(best:GetAttribute("ID")).hatchSeconds = sec or settingsForEgg(best:GetAttribute("ID")).hatchSeconds
		moveEgg(best)
		return "started " .. tostring(best:GetAttribute("ID"))
	end}
-- =====================================================================
-- AUTO LOOTBAG + ORB PICKUP
-- Isolated addition: does not modify any existing automation/UI logic.
-- =====================================================================
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

print("Halloween Maze v4 loaded" .. (hubMain and " (docked into the hub)" or ""))
end)
