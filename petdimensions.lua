-- Shared bag for cross-cutting state. Declared at the very top on purpose:
-- the constants folded in below start at the top of the file, so this has to
-- exist before them, and this chunk is one register scope capped at 200.
local LiveCounts = {}


local stopped = false

local _realPrint, _realWarn = print, warn
print = function() end
warn = function() end

-- ------------------------------------------------------------------
-- global registry: a new run tears the previous one down completely.
-- Kept in _G (not a local) so a fresh chunk always finds it, even when
-- the old chunk was loaded by execute-file instead of live-reload.
-- ------------------------------------------------------------------
local REGISTRY = rawget(_G, "__RCU_REGISTRY")
if type(REGISTRY) ~= "table" then
	REGISTRY = { generation = 0, tasks = {}, cleanups = {} }
	rawset(_G, "__RCU_REGISTRY", REGISTRY)
end

do
	local prev = rawget(_G, "__RCU_HUB")
	if type(prev) == "table" and type(prev.stop) == "function" then
		pcall(prev.stop)
	end
end

-- kill anything left registered by an earlier run (its coroutines, its
-- Fluent window, its task table) before we touch anything ourselves.
do
	local stale = {}
	for name, t in pairs(REGISTRY.tasks) do
		stale[#stale + 1] = name
		if type(t) == "table" then
			t.alive = false
			if type(t.onStop) == "function" then
				pcall(t.onStop)
			end
		end
	end
	for _, fn in pairs(REGISTRY.cleanups) do
		pcall(fn)
	end
	table.clear(REGISTRY.tasks)
	table.clear(REGISTRY.cleanups)
	for _, name in ipairs(stale) do
		REGISTRY.tasks[name] = nil
	end
end

REGISTRY.generation += 1
REGISTRY.lastError = nil
local GEN = REGISTRY.generation
local function stale()
	return stopped or REGISTRY.generation ~= GEN
end

local function tryLoadFile(path)
	local ok, src = pcall(readfile, path)
	if not ok or type(src) ~= "string" or src == "" then
		return nil
	end
	local fn, err = loadstring(src)
	if not fn then
		warn("[RCU] loadstring failed (" .. path .. "): " .. tostring(err))
		return nil
	end
	local ok2, res = pcall(fn)
	if not ok2 then
		warn("[RCU] chunk failed (" .. path .. "): " .. tostring(res))
		return nil
	end
	return res
end

local function tryLoad(url)
	local cached = string.match(url, "Addons/([%w_]+)%.lua") or string.match(url, "/download/([%w_]+%.lua)")
	if cached then
		local fromFile = tryLoadFile("fluent/" .. cached)
		if fromFile ~= nil then
			return fromFile
		end
	end
	local ok, src = pcall(game.HttpGet, game, url)
	if not ok then
		warn("[RCU] HttpGet failed: " .. tostring(src))
		return nil
	end
	local fn, err = loadstring(src)
	if not fn then
		warn("[RCU] loadstring failed: " .. tostring(err))
		return nil
	end
	local ok2, res = pcall(fn)
	if not ok2 then
		warn("[RCU] chunk failed: " .. tostring(res))
		return nil
	end
	return res
end

local Fluent = tryLoadFile("fluent/main.lua") or loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
local SaveManager = tryLoad("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua")
local InterfaceManager = tryLoad("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua")
print("[RCU] libs ok")

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local Knit = require(ReplicatedStorage.Packages.Knit)
local Util = require(ReplicatedStorage.Shared.Util)
local Functions = require(ReplicatedStorage.Shared.Functions)
local Values = require(ReplicatedStorage.Shared.Values)
local Variables = require(ReplicatedStorage.Shared.Variables)
local EggList = require(ReplicatedStorage.Shared.List.Pets.Eggs)
local Rebirths = require(ReplicatedStorage.Shared.List.Rebirths)
local UpgradesList = require(ReplicatedStorage.Shared.List.Upgrades)
local FallRebirths = require(ReplicatedStorage.Shared.List.Fall.FallRebirths)
local HarvestTree = require(ReplicatedStorage.Shared.List.Fall.HarvestTree)
local LeavesMachine = require(ReplicatedStorage.Shared.List.Fall.LeavesMachine)
local RakeUpgrader = require(ReplicatedStorage.Shared.List.Fall.RakeUpgrader)
-- Extra Fluent themes.
--
-- This used to live in rcu-themes.luau, loaded via readfile. That stopped
-- working: readfile in this executor is restricted to a workspace-relative
-- path and rejects an absolute one with "Path outside workspace", so the load
-- silently failed and the whole Theme dropdown vanished from Settings. It is
-- inlined here instead, as ONE closure, so it still costs a single register
-- (see the note above about the 200-register cap).
--
-- Everything is inside the closure on purpose: the spec table, the Fluent
-- theme-registry lookup and the dropdown builder all share this one scope.
--
-- How it works: Fluent keeps its themes in a private table reachable only
-- through Creator.GetThemeProperty's first upvalue, where Creator is the
-- second upvalue of Fluent.SetTheme. Fluent:SetTheme silently no-ops on a
-- name it does not know, so a new theme means registering its table there
-- first. Verified: clone Dark, rename it, push it into Themes and
-- Themes.Names, then SetTheme applies it and Fluent.Theme reports the new
-- name. Each theme is generated from Dark rather than written out by hand so
-- every key Fluent expects is present - a partial table leaves elements
-- unpainted.
--
-- Colour fields are: accent, element, tab, and the three dark backgrounds
-- acrylicMain / acrylicBorder / dialog (dialog doubles as DropdownHolder).
local function Themes_build(sec, Options)
	if type(sec) ~= "table" or type(Fluent) ~= "table" then
		return
	end

	local EXTRA = {
		-- Halloween / autumn
		{ name = "Halloween", accent = Color3.fromRGB(255, 140, 0), element = Color3.fromRGB(255, 170, 60), tab = Color3.fromRGB(200, 105, 10), main = Color3.fromRGB(38, 26, 14), border = Color3.fromRGB(122, 78, 34), dialog = Color3.fromRGB(112, 62, 24) },
		{ name = "Pumpkin", accent = Color3.fromRGB(255, 122, 20), element = Color3.fromRGB(255, 160, 70), tab = Color3.fromRGB(214, 96, 24), main = Color3.fromRGB(44, 28, 16), border = Color3.fromRGB(136, 82, 38), dialog = Color3.fromRGB(124, 66, 26) },
		{ name = "Ghost", accent = Color3.fromRGB(240, 240, 255), element = Color3.fromRGB(225, 225, 245), tab = Color3.fromRGB(190, 190, 215), main = Color3.fromRGB(30, 30, 38), border = Color3.fromRGB(96, 96, 112), dialog = Color3.fromRGB(74, 74, 90) },
		{ name = "Vampire", accent = Color3.fromRGB(196, 24, 60), element = Color3.fromRGB(226, 90, 110), tab = Color3.fromRGB(150, 20, 48), main = Color3.fromRGB(32, 14, 20), border = Color3.fromRGB(108, 44, 58), dialog = Color3.fromRGB(98, 26, 40) },
		{ name = "Spooky", accent = Color3.fromRGB(255, 200, 40), element = Color3.fromRGB(255, 220, 110), tab = Color3.fromRGB(200, 155, 35), main = Color3.fromRGB(34, 28, 16), border = Color3.fromRGB(110, 90, 42), dialog = Color3.fromRGB(96, 76, 32) },
		{ name = "Harvest", accent = Color3.fromRGB(224, 148, 40), element = Color3.fromRGB(240, 180, 90), tab = Color3.fromRGB(180, 118, 32), main = Color3.fromRGB(36, 30, 18), border = Color3.fromRGB(116, 94, 44), dialog = Color3.fromRGB(104, 82, 36) },
		{ name = "Candy", accent = Color3.fromRGB(255, 105, 180), element = Color3.fromRGB(255, 150, 200), tab = Color3.fromRGB(205, 80, 150), main = Color3.fromRGB(36, 22, 32), border = Color3.fromRGB(118, 68, 96), dialog = Color3.fromRGB(106, 58, 86) },
		{ name = "Witch", accent = Color3.fromRGB(126, 60, 200), element = Color3.fromRGB(160, 100, 225), tab = Color3.fromRGB(98, 44, 158), main = Color3.fromRGB(26, 20, 36), border = Color3.fromRGB(90, 58, 132), dialog = Color3.fromRGB(78, 48, 116) },
		-- seasonal + originals
		{ name = "Ember", accent = Color3.fromRGB(255, 122, 46), element = Color3.fromRGB(255, 154, 92), tab = Color3.fromRGB(214, 106, 52), main = Color3.fromRGB(40, 30, 28), border = Color3.fromRGB(122, 74, 55), dialog = Color3.fromRGB(120, 58, 36) },
		{ name = "Bloodmoon", accent = Color3.fromRGB(226, 48, 48), element = Color3.fromRGB(214, 92, 92), tab = Color3.fromRGB(180, 48, 48), main = Color3.fromRGB(34, 22, 24), border = Color3.fromRGB(110, 55, 55), dialog = Color3.fromRGB(105, 34, 34) },
		{ name = "Frost", accent = Color3.fromRGB(150, 220, 255), element = Color3.fromRGB(186, 232, 255), tab = Color3.fromRGB(120, 180, 220), main = Color3.fromRGB(26, 32, 40), border = Color3.fromRGB(70, 95, 118), dialog = Color3.fromRGB(46, 78, 106) },
		{ name = "Gold", accent = Color3.fromRGB(255, 200, 60), element = Color3.fromRGB(255, 219, 120), tab = Color3.fromRGB(210, 165, 55), main = Color3.fromRGB(38, 34, 24), border = Color3.fromRGB(126, 105, 55), dialog = Color3.fromRGB(115, 90, 38) },
		{ name = "Toxic", accent = Color3.fromRGB(154, 240, 62), element = Color3.fromRGB(178, 245, 106), tab = Color3.fromRGB(120, 190, 60), main = Color3.fromRGB(28, 36, 26), border = Color3.fromRGB(90, 122, 60), dialog = Color3.fromRGB(62, 110, 40) },
		{ name = "Neon", accent = Color3.fromRGB(255, 60, 220), element = Color3.fromRGB(240, 130, 235), tab = Color3.fromRGB(200, 60, 180), main = Color3.fromRGB(30, 22, 34), border = Color3.fromRGB(105, 60, 110), dialog = Color3.fromRGB(96, 38, 100) },
		{ name = "Void", accent = Color3.fromRGB(140, 120, 255), element = Color3.fromRGB(170, 155, 250), tab = Color3.fromRGB(110, 95, 210), main = Color3.fromRGB(22, 20, 32), border = Color3.fromRGB(78, 70, 118), dialog = Color3.fromRGB(58, 50, 100) },
		{ name = "Mint", accent = Color3.fromRGB(80, 230, 190), element = Color3.fromRGB(130, 240, 214), tab = Color3.fromRGB(70, 180, 155), main = Color3.fromRGB(24, 34, 32), border = Color3.fromRGB(70, 110, 100), dialog = Color3.fromRGB(38, 92, 82) },
		{ name = "Ocean", accent = Color3.fromRGB(40, 170, 220), element = Color3.fromRGB(110, 205, 235), tab = Color3.fromRGB(30, 130, 175), main = Color3.fromRGB(18, 30, 40), border = Color3.fromRGB(58, 106, 134), dialog = Color3.fromRGB(38, 84, 110) },
		{ name = "Sunset", accent = Color3.fromRGB(255, 94, 120), element = Color3.fromRGB(255, 145, 130), tab = Color3.fromRGB(210, 70, 100), main = Color3.fromRGB(40, 24, 30), border = Color3.fromRGB(128, 66, 78), dialog = Color3.fromRGB(116, 52, 70) },
		{ name = "Aurora", accent = Color3.fromRGB(90, 220, 200), element = Color3.fromRGB(150, 200, 255), tab = Color3.fromRGB(120, 130, 230), main = Color3.fromRGB(22, 30, 38), border = Color3.fromRGB(76, 104, 132), dialog = Color3.fromRGB(52, 82, 110) },
	}

	-- Fluent's private theme registry.
	local props
	do
		local okC, creator = pcall(function()
			return debug.getupvalues(Fluent.SetTheme)[2]
		end)
		if okC and type(creator) == "table" then
			local okP, p = pcall(function()
				return debug.getupvalues(creator.GetThemeProperty)[1]
			end)
			if okP and type(p) == "table" and type(p.Names) == "table" then
				props = p
			end
		end
	end
	if not props or type(props.Dark) ~= "table" then
		return
	end

	local added = {}
	for _, spec in ipairs(EXTRA) do
		if type(props[spec.name]) ~= "table" then
			local t = {}
			-- copy every key the base has, then override the coloured ones
			for k, v in pairs(props.Dark) do
				t[k] = v
			end
			t.Name = spec.name
			t.Accent = spec.accent
			t.Element = spec.element
			t.Hover = spec.element
			t.Input = spec.element
			t.Keybind = spec.element
			t.SliderRail = spec.element
			t.ToggleSlider = spec.element
			t.DropdownOption = spec.element
			t.Tab = spec.tab
			t.AcrylicMain = spec.main
			t.AcrylicBorder = spec.border
			t.Dialog = spec.dialog
			t.DialogButton = spec.dialog
			t.DropdownHolder = spec.dialog
			-- keep the gradients tinted to the accent, like the stock ones
			pcall(function()
				t.AcrylicGradient = ColorSequence.new({
					ColorSequenceKeypoint.new(0, spec.accent),
					ColorSequenceKeypoint.new(1, spec.main),
				})
			end)
			props[spec.name] = t
			props.Names[#props.Names + 1] = spec.name
		end
		added[#added + 1] = spec.name
	end

	local vals = {}
	for _, v in ipairs(Fluent.Themes) do
		if type(v) == "string" then
			vals[#vals + 1] = v
		end
	end
	for _, n in ipairs(added) do
		local seen = false
		for _, v in ipairs(vals) do
			if v == n then
				seen = true
				break
			end
		end
		if not seen then
			vals[#vals + 1] = n
		end
	end
	if #vals == 0 then
		return
	end
	table.sort(vals)

	-- start on whatever the saved config asked for, so restoring settings does
	-- not visibly repaint the whole window on load
	local saved = nil
	if type(Options) == "table" and type(Options.ThemePick) == "table" then
		local ok, v = pcall(function()
			return Options.ThemePick.Value
		end)
		if ok and type(v) == "string" then
			saved = v
		end
	end
	local start = saved or Fluent.Theme or vals[1]

	local d = sec:AddDropdown("ThemePick", {
		Title = "Theme",
		Description = ("Fluent's own plus %d extra themes (Halloween, Ghost, Vampire, Witch and more)"):format(#added),
		Default = start,
		Values = vals,
		Callback = function(choice)
			if type(choice) == "string" and choice ~= Fluent.Theme then
				pcall(function()
					Fluent:SetTheme(choice)
				end)
			end
		end,
	})
	if type(Options) == "table" then
		pcall(function()
			Options.ThemePick = d
		end)
	end
end

local FallEventList = require(ReplicatedStorage.Shared.List.Items.FallEvent)
local Meteors = require(ReplicatedStorage.Shared.List.Meteors)
local Items = require(ReplicatedStorage.Shared.Items)
local LocalList = ReplicatedStorage.Shared.List
local AxesList = require(LocalList.Axes)
local TreesList = require(LocalList.Trees)
local AchievementsList = require(LocalList.Achievements)
local PlaytimeRewards = require(LocalList.PlaytimeRewards)
local ChestsList = require(LocalList.Chests)
local FarmsList = require(LocalList.Farms)
local SkillTreeList = require(LocalList.SkillTree)
local ExclusiveDir = Items.exclusive:directory()

local function getController(name)
	local ok, c = pcall(function()
		return Knit.GetController(name)
	end)
	return ok and c or nil
end

local function getService(name)
	local ok, s = pcall(function()
		return Knit.GetService(name)
	end)
	return ok and s or nil
end

local DataController = getController("DataController")
local EggController = getController("EggController")
local HatchingController = getController("HatchingController")
local EggService = getService("EggService")
local RebirthService = getService("RebirthService")
local FallService = getService("FallService")
local EventService = getService("EventService")
local FallToolService = getService("FallToolService")
local UpgradeService = getService("UpgradeService")
local PlayerService = getService("PlayerService")
local InventoryService = getService("InventoryService")
local AxeService = getService("AxeService")
local RewardService = getService("RewardService")
local FarmService = getService("FarmService")
local AuraService = getService("AuraService")
local SkillTreeService = getService("SkillTreeService")
local TreeController = getController("TreeController")
local AuraController = getController("AuraController")
local OreController = getController("OreController")
local CircusController = getController("CircusController")
local OrbController = getController("OrbController")
local ChestController = getController("ChestController")
local ClickService = getService("ClickService")
local MapController = getController("MapController")

-- Shared.List.Mine.OreRooms: every room has mapId = 21
local MINE_MAP_ID = 21
LiveCounts.MINE_ROOM_IDS = { "room1", "room2", "room3", "room4", "room5", "room6", "room7", "room8", "room9", "room10", "room11", "room12" }
LiveCounts.MINE_ORE_TYPES = {
	"ironOre", "goldOre", "diamondOre", "rubyOre", "emeraldOre",
	"sapphireOre", "titaniumOre", "uraniumOre", "cobaltOre",
	"moonstoneOre", "platinumOre", "sunstoneOre",
}
local TapSkinService = getService("TapSkinService")
local PetService = getService("PetService")
local FishingService = getService("FishingService")

print(
	"[RCU] boot: data=" .. tostring(DataController ~= nil)
		.. " egg=" .. tostring(EggController ~= nil)
		.. " hatch=" .. tostring(HatchingController ~= nil)
		.. " eggSvc=" .. tostring(EggService ~= nil)
		.. " click=" .. tostring(ClickService ~= nil)
		.. " tree=" .. tostring(TreeController ~= nil)
)

task.spawn(function()
	for i = 1, 30 do
		if stopped or (DataController and EggService and ClickService and TreeController) then
			break
		end
		DataController = getController("DataController") or DataController
		EggController = getController("EggController") or EggController
		HatchingController = getController("HatchingController") or HatchingController
		EggService = getService("EggService") or EggService
		RebirthService = getService("RebirthService") or RebirthService
		FallService = getService("FallService") or FallService
		EventService = getService("EventService") or EventService
		FallToolService = getService("FallToolService") or FallToolService
		UpgradeService = getService("UpgradeService") or UpgradeService
		PlayerService = getService("PlayerService") or PlayerService
		InventoryService = getService("InventoryService") or InventoryService
		AxeService = getService("AxeService") or AxeService
		RewardService = getService("RewardService") or RewardService
		FarmService = getService("FarmService") or FarmService
		AuraService = getService("AuraService") or AuraService
		SkillTreeService = getService("SkillTreeService") or SkillTreeService
		TreeController = getController("TreeController") or TreeController
		AuraController = getController("AuraController") or AuraController
		OreController = getController("OreController") or OreController
		CircusController = getController("CircusController") or CircusController
		OrbController = getController("OrbController") or OrbController
		ChestController = getController("ChestController") or ChestController
		MapController = getController("MapController") or MapController
		ClickService = getService("ClickService") or ClickService
		TapSkinService = getService("TapSkinService") or TapSkinService
		PetService = getService("PetService") or PetService
		FishingService = getService("FishingService") or FishingService
		task.wait(1)
	end
	if not stopped and (not DataController or not ClickService) then
		warn("[RCU] still missing controllers after retry: data=" .. tostring(DataController ~= nil) .. " click=" .. tostring(ClickService ~= nil))
	end
end)

LiveCounts.NEAREST_EGG = "~ Closest egg ~"

local reportedNoData = false
local function getData()
	if not DataController then
		return nil
	end
	local ok, d = pcall(function()
		return DataController:getData()
	end)
	if ok and d then
		return d
	end
	local ok2, d2 = pcall(function()
		return DataController.data
	end)
	if ok2 and d2 then
		return d2
	end
	if not reportedNoData then
		reportedNoData = true
		warn("[RCU] getData() returned nil - runners are waiting on data sync")
	end
	return nil
end

local notifyEnabled = false
local function notify(title, content)
	if Fluent.Unloaded or not notifyEnabled then
		return
	end
	pcall(function()
		Fluent:Notify({
			Title = title,
			Content = tostring(content),
			Duration = 5,
		})
	end)
end

local function suffix(n)
	if type(n) ~= "number" or n ~= n then
		return tostring(n or "?")
	end
	if n < 0 then
		return "-" .. suffix(-n)
	end
	if n < 1000 then
		return string.format("%.0f", n)
	end
	if n >= 1e20 then
		return string.format("%.2e", n)
	end
	local units = { { 1e15, "Q" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in ipairs(units) do
		if n >= u[1] then
			local v = n / u[1]
			local s = string.format(v >= 100 and "%.0f" or (v >= 10 and "%.1f" or "%.2f"), v)
			return (s:gsub("(%.%d)0$", "%1"):gsub("%.0$", "")) .. u[2]
		end
	end
	return string.format("%.0f", n)
end

local function itemAmount(data, name)
	if not data then
		return 0
	end
	local ok, item = pcall(function()
		return Util.itemUtils.getItemFromName(data, name)
	end)
	if not ok or not item then
		return 0
	end
	local ok2, amt = pcall(function()
		return item:getAmount()
	end)
	return ok2 and amt or 0
end

local Options = Fluent.Options


local eggNames = {}
for name in pairs(EggList) do
	eggNames[#eggNames + 1] = name
end
table.sort(eggNames)

local function eggValueName(label)
	if not label or label == LiveCounts.NEAREST_EGG then
		return label
	end
	local i = string.find(label, "  |  ", 1, true)
	return i and label:sub(1, i - 1) or label
end

local function diceValueName(label)
	if not label then
		return label
	end
	local i = string.find(label, "  (", 1, true)
	return i and label:sub(1, i - 1) or label
end

local function rawItemAmount(data, name)
	if not data then
		return 0
	end
	for _, section in pairs(data.inventory or {}) do
		if type(section) == "table" then
			for _, e in pairs(section) do
				if type(e) == "table" and tostring(e.nm or "") == name then
					return e.am or 0
				end
			end
		end
	end
	return 0
end

-- ------------------------------------------------------------------
-- world / equip helpers
-- ------------------------------------------------------------------
local function currentAxeIndex(data)
	if not data or not data.inventory then
		return nil
	end
	for _, v in pairs(data.inventory.exclusive) do
		local nm = tostring(v.nm or "")
		if nm:lower():find("axe") and not nm:lower():find("pickaxe") then
			local def = ExclusiveDir[nm]
			return nm, def and def.index
		end
	end
	return nil
end

-- Tool slots are exclusive. The game tracks what you have out through a set of
-- isXEquipped flags and only ONE may be active at a time, so switching tools
-- means putting the current one away first. Doing it this way is what makes
-- "Auto Mine should unequip the rake and give me the pickaxe" work: we look at
-- every equipped flag, not just the slot we happen to want.
--
-- The game's call shape is useItem(id, {use = count}) with no mapId - passing
-- one makes the server answer nil instead of "success", which is why equipping
-- silently never worked. useItem(id, {use = 0}) puts a tool away.
LiveCounts.TOOL_SLOTS = {
	{ flag = "isAxeEquipped", where = "exclusive" },
	{ flag = "isPickaxeEquipped", where = "exclusive" },
	{ flag = "isRakeToolEquipped", where = "fallEvent" },
	{ flag = "isFishingRodEquipped", where = "exclusive" },
	{ flag = "isMountEquipped", where = "exclusive" },
	{ flag = "isHalloweenWeaponEquipped", where = "exclusive" },
	{ flag = "isChristmasToolEquipped", where = "exclusive" },
	{ flag = "isThanksgivingWeaponEquipped", where = "exclusive" },
}

-- put away every equipped tool except `keepFlag`. Returns how many it cleared.
local function unequipAllTools(keepFlag)
	local data = getData()
	if not data or not InventoryService then
		return 0
	end
	local cleared = 0
	for _, slot in ipairs(LiveCounts.TOOL_SLOTS) do
		if slot.flag ~= keepFlag and data[slot.flag] then
			local section = data.inventory and data.inventory[slot.where]
			for id, e in pairs(section or {}) do
				-- only owned rows can be toggled
				local owned = (e.am ~= nil and (e.am or 0) > 0)
				if not owned then
					local ok, item = pcall(function()
						return Util.itemUtils.getItemFromId(data, id)
					end)
					if ok and item then
						local amt
						pcall(function()
							amt = item:getAmount()
						end)
						owned = (amt or 0) > 0
					end
				end
				if owned then
					pcall(function()
						InventoryService:useItem(id, { use = 0 })
					end)
					cleared += 1
					break
				end
			end
		end
	end
	if cleared > 0 then
		-- let the server settle the flags before the next call
		task.wait(0.2)
	end
	return cleared
end

-- Equip the tool matching `predicate`, first putting away whatever else is out.
-- Returns true, chosenName.
LiveCounts.SLOT_FLAGS = {
	axe = "isAxeEquipped",
	pickaxe = "isPickaxeEquipped",
	rod = "isFishingRodEquipped",
}

local function equipTool(slot, predicate)
	if not InventoryService then
		return false
	end
	local data = getData()
	if not data or not data.inventory or not data.inventory.exclusive then
		return false
	end
	for id, v in pairs(data.inventory.exclusive) do
		local nm = tostring(v.nm or "")
		-- an item you hold can have no `am` at all (the amount is implied by
		-- itemUtils resolving it), so fall back to that before giving up
		local owned = (v.am ~= nil) and (v.am or 0) > 0
		if not owned then
			local ok, item = pcall(function()
				return Util.itemUtils.getItemFromId(data, id)
			end)
			if ok and item then
				local amt
				pcall(function()
					amt = item:getAmount()
				end)
				owned = (amt or 0) > 0
			end
		end
		if owned and predicate(nm) then
			unequipAllTools(LiveCounts.SLOT_FLAGS[slot])
			local ok, res = pcall(function()
				return InventoryService:useItem(id, { use = 1 })
			end)
			if ok and res == "success" then
				return true, nm
			end
		end
	end
	return false
end

local function equipAxe()
	return equipTool("axe", function(nm)
		return nm:lower():find("axe") and not nm:lower():find("pickaxe")
	end)
end

local function equipRake()
	if not InventoryService then
		return false
	end
	local data = getData()
	if not data or not data.inventory or not data.inventory.fallEvent then
		return false
	end
	-- prefer the best-ranked rake we actually own
	local bestIdx, bestId = -1, nil
	for id, e in pairs(data.inventory.fallEvent) do
		local def = type(e) == "table" and FallEventList[tostring(e.nm)]
		if type(def) == "table" and def.isTool and (e.am or 0) > 0 and (def.index or 0) > bestIdx then
			bestIdx, bestId = def.index or 0, id
		end
	end
	if bestId then
		-- a rake is held in its own slot: put away whatever else is out first
		unequipAllTools("isRakeToolEquipped")
		local ok, res = pcall(function()
			return InventoryService:useItem(bestId, { use = 1 })
		end)
		if ok and res == "success" then
			return true
		end
	end
	-- nothing matched; fall back to any owned fall-event tool
	for id, e in pairs(data.inventory.fallEvent) do
		if (e.am or 0) > 0 then
			unequipAllTools("isRakeToolEquipped")
			local ok, res = pcall(function()
				return InventoryService:useItem(id, { use = 1 })
			end)
			if ok and res == "success" then
				return true
			end
			break
		end
	end
	return false
end

local function equipPickaxe()
	return equipTool("pickaxe", function(nm)
		return nm:lower():find("pickaxe")
	end)
end

-- Which fishing rod do we own, best first?
--
-- equipTool's predicate (name contains "fishingrod") matches all 10 rods, and
-- it scans pairs() which is UNORDERED, so with more than one rod owned the
-- choice was effectively random. That is the "worked on my rod, not on my
-- friend's" report: each account picked whichever row came first, and the
-- runner then proceeded against a rod it had not actually equipped.
--
-- Resolve the rod explicitly by its Exclusive index instead, exactly like the
-- game's own getCurrentFishingRod does, and skip megaFishingRod: it is not an
-- inventory item but a bought upgrade (data.boughtMegaFishingRod), so there is
-- no row to equip.
local function bestOwnedRodId(data)
	local bestIdx, bestId = -1, nil
	local inv = data and data.inventory and data.inventory.exclusive
	if type(inv) ~= "table" then
		return nil
	end
	for id, e in pairs(inv) do
		local nm = tostring(e.nm or "")
		if nm:lower():find("fishingrod") and nm ~= "megaFishingRod" then
			local ok, item = pcall(function()
				return Util.itemUtils.getItemFromId(data, id)
			end)
			local owned = ok and item ~= nil
			if not owned then
				owned = (e.am or 0) > 0
			end
			if owned then
				local idx = -1
				pcall(function()
					local it = Items.exclusive(nm)
					local dir = it:directory()
					idx = dir[it:getName()].index or -1
				end)
				if idx > bestIdx then
					bestIdx, bestId = idx, id
				end
			end
		end
	end
	return bestId, bestIdx
end

local function equipRod()
	local data = getData()
	if not data then
		return false
	end
	local id = bestOwnedRodId(data)
	if not id then
		return false
	end
	if data.isFishingRodEquipped then
		return true
	end
	-- the rod has its own slot: put away whatever else is out first
	unequipAllTools("isFishingRodEquipped")
	local ok, res = pcall(function()
		return InventoryService:useItem(id, { use = 1 })
	end)
	if not (ok and res == "success") then
		return false
	end
	-- WAIT for the server to actually set the flag.
	--
	-- The old version returned immediately and the runner's next tick re-read
	-- data.isFishingRodEquipped before the replica had updated, so it would
	-- call equipRod again, unequip and re-equip in a loop and never advance to
	-- the travel/fishing steps. Equipping is not instantaneous, so poll for it.
	local deadline = os.clock() + 5
	while os.clock() < deadline do
		local fresh = getData()
		if fresh and fresh.isFishingRodEquipped then
			return true
		end
		if stopped or Fluent.Unloaded then
			return false
		end
		task.wait(0.25)
	end
	return false
end

local function nextAxeLabel(name)
	local ok, s = pcall(function()
		return Functions.toPascal(name)
	end)
	return ok and s or name
end

local function nearestReadyPile(pos)
	local best, bestD = nil, math.huge
	for _, p in ipairs(CollectionService:GetTagged("LeafPile")) do
		if p:IsDescendantOf(workspace) and not p:GetAttribute("respawnsAt") then
			local d = (p:GetPivot().Position - pos).Magnitude
			if d < bestD then
				bestD, best = d, p
			end
		end
	end
	return best, bestD
end

local function nearestEggName(hrp)
	local pos = hrp.Position
	local best, bestD = nil, math.huge
	for _, name in ipairs(eggNames) do
		local ok, model = pcall(function()
			return EggController:getEggModel(name)
		end)
		if ok and model and model.Parent then
			local d = (model:GetPivot().Position - pos).Magnitude
			if d < bestD then
				bestD, best = d, name
			end
		end
	end
	return best
end

-- A Multi dropdown's .Value is a SET ({option = true}), not an array -
-- Fluent assigns l.Value[option] = true when a row is clicked. So iterate
-- with pairs, never ipairs, or every selection reads as empty.
-- An empty set (or only "Any") means no filter.
local function selectedSet(dropdown)
	local v = dropdown and dropdown.Value
	if type(v) ~= "table" then
		return nil
	end
	local set = {}
	for option, on in pairs(v) do
		if on and option ~= "Any" then
			set[tostring(option)] = true
		end
	end
	if next(set) == nil then
		return nil
	end
	return set
end

local function treeWorldPos(tr)
	local model = tr and tr:FindFirstChildWhichIsA("Model")
	if not model then
		return nil, nil
	end
	local pp = model.PrimaryPart
	if pp then
		return model, pp
	end
	-- PrimaryPart unset: fall back to any BasePart, then to the model pivot
	local part
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			part = d
			break
		end
	end
	if part then
		return model, part
	end
	local ok, pivot = pcall(function()
		return model:GetPivot().Position
	end)
	if ok and pivot then
		return model, nil, pivot
	end
	return model, nil
end
-- Chop's map when no zone filter is set. Spawn (mapId 1) always has trees.
LiveCounts.CHOP_MAP_ID = 1

-- nearestTree(data, pos, zones)
-- zones may be nil (any), a Multi-dropdown set ({name=true}), or a plain
-- table. All three are handled by a single truthiness lookup.
local function nearestTree(data, pos, zones)
	local best, bestD = nil, math.huge
	for _, tr in pairs(CollectionService:GetTagged("Tree")) do
		if tr:IsDescendantOf(workspace) then
			local g = tr:GetAttribute("groupId")
			local tid = tr:GetAttribute("treeId")
			if g and tid and zones[g] then
				local rec = data.trees[g] and data.trees[g][tid]
				if rec and (rec.hp or 0) > 0 then
					-- the tag sits on a Folder, so it has no pivot of its own;
					-- the position comes from the child Model. treeWorldPos
					-- returns (model, part, pivot): a normal tree only fills
					-- the second value, and only the pivot fallback fills the
					-- third, so the position has to be resolved from either.
					local model, part, pivot = treeWorldPos(tr)
					local world = pivot or (part and part.Position)
					if world then
						local d = (world - pos).Magnitude
						if d < bestD then
							bestD, best = d, tr
						end
					end
				end
			end
		end
	end
	return best
end

local WOOD_ZONES = {}
for zone, def in pairs(TreesList) do
	if type(def) == "table" and type(def.trees) == "table" then
		for _, tr in pairs(def.trees) do
			if type(tr) == "table" and tr.item then
				local ok, nm = pcall(function()
					return tr.item:getName()
				end)
				if ok and nm then
					WOOD_ZONES[nm] = WOOD_ZONES[nm] or {}
					table.insert(WOOD_ZONES[nm], zone)
				end
			end
		end
	end
end

local function zonesForItems(names)
	local set = {}
	for _, nm in ipairs(names) do
		for _, zone in ipairs(WOOD_ZONES[nm] or {}) do
			set[zone] = true
		end
	end
	return set
end

local function densestReadyPile(pos)
	local all = {}
	for _, p in ipairs(CollectionService:GetTagged("LeafPile")) do
		if p:IsDescendantOf(workspace) and not p:GetAttribute("respawnsAt") then
			all[#all + 1] = p
		end
	end
	local n = #all
	if n == 0 then
		return nil, math.huge, 0
	end
	local positions = table.create(n)
	for i = 1, n do
		positions[i] = all[i]:GetPivot().Position
	end
	local radius = 34
	local best, bestScore, bestD, bestCount = nil, -math.huge, math.huge, 0
	for i = 1, n do
		local pi = positions[i]
		local d = (pi - pos).Magnitude
		if d < 150 then
			local count = 0
			for j = 1, n do
				if i ~= j and (pi - positions[j]).Magnitude <= radius then
					count += 1
				end
			end
			local score = count * 6 - d * 0.04
			if score > bestScore then
				bestScore, best, bestD, bestCount = score, all[i], d, count
			end
		end
	end
	if not best then
		for i = 1, n do
			local d = (positions[i] - pos).Magnitude
			if d < bestD then
				bestD, best = d, all[i]
			end
		end
	end
	return best, bestD, bestCount
end

local Tasks = {}

local function stopTask(name)
	local t = Tasks[name]
	if not t then
		return
	end
	t.alive = false
	Tasks[name] = nil
	REGISTRY.tasks[name] = nil
	print("[RCU] task stopped: " .. name)
	if t.onStop then
		pcall(t.onStop)
	end
end

local function startTask(name, runner, interval, onStop)
	if Tasks[name] then
		return
	end
	local t = {
		alive = true,
		onStop = onStop,
		cooldown = 0,
	}
	Tasks[name] = t
	REGISTRY.tasks[name] = t
	print("[RCU] task started: " .. name)
	coroutine.wrap(function()
		while t.alive and not Fluent.Unloaded and not stale() do
			local ok, err = pcall(runner, t)
			if not ok then
				warn("[RCU] " .. name .. ": " .. tostring(err))
				-- keep the last failure readable: warn is silenced by default,
				-- so a broken runner would otherwise just look "off"
				REGISTRY.lastError = { task = name, message = tostring(err), at = os.clock() }
				if t.alive then
					task.wait(3)
				end
			end
			if t.alive then
				task.wait(interval)
			end
		end
	end)()
end

local function stopAll()
	local names = {}
	for name in pairs(Tasks) do
		names[#names + 1] = name
	end
	for _, name in ipairs(names) do
		stopTask(name)
	end
end

local function isRunning(name)
	return Tasks[name] ~= nil
end

-- ------------------------------------------------------------------
-- helpers
-- ------------------------------------------------------------------
local function teleportToEgg(t, egg)
	if not EggController then
		return false, "EggController missing"
	end
	local ok, model = pcall(function()
		return EggController:getEggModel(egg)
	end)
	if not ok or not model then
		return false, "No egg model for " .. tostring(egg)
	end
	local hrp = Functions.getHRP(LocalPlayer)
	if not hrp then
		return false, "No character"
	end
	local folder = model:FindFirstChild("Egg")
	local pp = folder and folder:IsA("Model") and folder.PrimaryPart
	hrp.Anchored = true
	if pp then
		hrp:PivotTo(pp.CFrame + pp.CFrame.LookVector * 5.5)
	else
		hrp:PivotTo(CFrame.new(model:GetPivot().Position))
	end
	task.delay(0.5, function()
		if hrp.Parent then
			hrp.Anchored = false
			hrp.AssemblyLinearVelocity = Vector3.zero
		end
	end)
	local deadline = os.clock() + 10
	while os.clock() < deadline do
		if EggController._currentEgg == egg then
			return true
		end
		if (t and not t.alive) or Fluent.Unloaded or stopped then
			break
		end
		task.wait(0.25)
	end
	if EggController._currentEgg == egg then
		return true
	end
	return false, "Out of range of " .. tostring(egg)
end

-- ------------------------------------------------------------------
-- lucky / global eggs
--
-- EggController:spawnGlobalEgg clones Assets.Other.<PascalType>, tags it
-- "Egg" (the same tag every normal egg uses), stamps it with a
-- globalEggId attribute, and RENAMES it to the current best egg's name.
-- So the lucky egg is not its own model type - it is an ordinary
-- "Egg"-tagged model carrying a globalEggId. That attribute is the only
-- reliable way to tell them apart.
--
-- EggController's proximity loop (getClosestEgg, within 10 studs) is what
-- sets _globalEggId, and getOpenParams() then returns {globalEggId = ...},
-- which is what makes openEgg use the lucky egg. Both are automatic: stand
-- next to the model and the existing hatch loop already opens it with the
-- right params. So all this has to do is get us there and confirm.
--
-- These four helpers were referenced by hatchRunner but never defined, so the
-- "Hatch lucky eggs" toggle threw "attempt to call a nil value" on every tick
-- while it was on. Everything below is derived from spawnGlobalEgg itself:
--   - the model is parented to workspace.Debris and tagged "Egg"
--   - it carries a globalEggId attribute
--   - it is RENAMED to the best egg's name, so name-matching finds it anyway
--   - a LuckyEgg.Holder.Timer label counts the spawn down and the model
--     destroys itself when it expires, so "still parented" IS "still alive"
-- so there is no separate lifetime to track: presence in Debris is the flag.
-- ------------------------------------------------------------------

-- One table, not four locals - see the note on SkillTreeHelpers about the
-- 200-register cap.
local LuckyEgg = {}

-- Is there a live lucky egg right now? Returns model, globalEggId.
function LuckyEgg.find()
	if not CollectionService or not workspace then
		return nil
	end
	for _, model in ipairs(CollectionService:GetTagged("Egg")) do
		local id = model:GetAttribute("globalEggId")
		if id and model:IsDescendantOf(workspace) then
			return model, id
		end
	end
	return nil
end

-- Has the game's own proximity loop already locked onto that lucky egg?
-- EggController sets _globalEggId from the nearest tagged egg each Heartbeat,
-- so this is true once we are within its scan range of the model.
function LuckyEgg.at(id)
	return EggController ~= nil and EggController._globalEggId == id
end

-- Stand next to the lucky egg and wait for the game to register it.
function LuckyEgg.teleport(t, model, id)
	local hrp = Functions.getHRP(LocalPlayer)
	if not hrp then
		return false, "No character"
	end
	local pp = model.PrimaryPart
	local target
	if pp then
		target = pp.CFrame + pp.CFrame.LookVector * 5.5
	else
		local ok, pv = pcall(function()
			return model:GetPivot().Position
		end)
		target = ok and pv or nil
	end
	if not target then
		return false, "Lucky egg has no usable position"
	end
	hrp.Anchored = true
	hrp:PivotTo(target)
	task.delay(0.5, function()
		if hrp.Parent then
			hrp.Anchored = false
			hrp.AssemblyLinearVelocity = Vector3.zero
		end
	end)
	-- the scan runs on Heartbeat, so give it a moment to pick the model up
	local deadline = os.clock() + 8
	while os.clock() < deadline do
		if LuckyEgg.at(id) then
			return true
		end
		-- it can expire while we walk to it
		if not model:IsDescendantOf(workspace) then
			return false, "The lucky egg expired"
		end
		if (t and not t.alive) or Fluent.Unloaded or stopped then
			break
		end
		task.wait(0.25)
	end
	if LuckyEgg.at(id) then
		return true
	end
	return false, "Could not reach the lucky egg"
end

-- Seconds left on the model's countdown label, for the notification only.
function LuckyEgg.secondsLeft(model)
	local ok, label = pcall(function()
		return model.LuckyEgg.Holder.Timer.Text
	end)
	if not ok or type(label) ~= "string" then
		return nil
	end
	-- spawnGlobalEgg formats it as ("Remaining: %*"):format(formatTime(...))
	local rest = label:match("Remaining:%s*(.+)$")
	if not rest then
		return nil
	end
	local d, h, m, s = rest:match("^(%d+)d"), rest:match("^(%d+)h"), rest:match("^(%d+)m"), rest:match("^(%d+)s")
	local total = 0
	if d then
		total += tonumber(d) * 86400
	end
	if h then
		total += tonumber(h) * 3600
	end
	if m then
		total += tonumber(m) * 60
	end
	if s then
		total += tonumber(s)
	end
	return total > 0 and total or nil
end
--
-- Note the model is renamed to the best egg, so EggController:getEggModel
-- can return the lucky egg when we asked for a normal egg. Looking the
-- model up by attribute avoids that ambiguity entirely.
-- ------------------------------------------------------------------
local function currentRakeIndex(data)
	if not data or not data.inventory or not data.inventory.fallEvent then
		return nil
	end
	local best = nil
	for _, entry in pairs(data.inventory.fallEvent) do
		local def = type(entry) == "table" and FallEventList[entry.nm]
		if type(def) == "table" and def.isTool and (not best or def.index > best) then
			best = def.index
		end
	end
	return best
end

local function totalRakes()
	local n = 0
	for _, def in pairs(FallEventList) do
		if type(def) == "table" and def.isTool then
			n += 1
		end
	end
	return n
end

local function unlockedRebirthCap(data)
	if not data then
		return 0
	end
	local upgrades = UpgradesList.rebirthButtons
	if not upgrades then
		return 0
	end
	local lvl = upgrades.upgrades[data.upgrades and data.upgrades.rebirthButtons or 0]
	return lvl and lvl.value or 0
end

local function rebirthCost(n, data)
	return (Variables.rebirthPrice + data.rebirths * Variables.rebirthPriceMultiplier) * n
		+ Variables.rebirthPriceMultiplier * (n * (n - 1) / 2)
end

local function highestUnlockedRebirth(data)
	local cap = math.min(unlockedRebirthCap(data), #Rebirths)
	if cap < 1 then
		return nil
	end
	return cap
end

-- ------------------------------------------------------------------
-- runners
-- ------------------------------------------------------------------
-- Forward declaration. This MUST sit above hatchRunner: Lua resolves an
-- upvalue at compile time from the scope where the function is *defined*, so
-- declaring it further down would make hatchRunner capture the (nil) global
-- instead - which is exactly what happened, and it made every hatch tick die
-- with "attempt to call a nil value" before it ever fired the remote.
local applyHatchInterval

local function hatchRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local egg = eggValueName(Options.EggSelect and Options.EggSelect.Value)
	if egg == LiveCounts.NEAREST_EGG or (Options.AutoHatchNearest and Options.AutoHatchNearest.Value) then
		local hrp = Functions.getHRP(LocalPlayer)
		egg = hrp and nearestEggName(hrp) or nil
	end
	if not egg or egg == "" then
		return
	end
	local data = getData()
	if not data or not EggController or not HatchingController then
		return
	end

	if EggController._isAutoHatching then
		pcall(function()
			EggController._currentEgg = ""
			EggController._isAutoHatching = false
			EggService.setIsAutoHatching:Fire()
		end)
		if not t.toldGameLoop then
			t.toldGameLoop = true
			notify("Auto Hatch", "Stopped the game's own auto hatch - hub is spamming instead.")
		end
	end
	t.toldGameLoop = false

	-- Lucky / global eggs take priority when the toggle is on. The egg we
	-- hatch is whatever the lucky model is NAMED after (the game renames it
	-- to the current best egg), so this still counts as hatching the closest
	-- egg - we just stand next to the lucky version of it.
	if Options.AutoHatchLuckyEggs and Options.AutoHatchLuckyEggs.Value then
		local model, id = LuckyEgg.find()
		if model then
			t.luckyId = id
			if not LuckyEgg.at(id) then
				local okL, errL = LuckyEgg.teleport(t, model, id)
				if okL then
					if not t.toldLucky then
						t.toldLucky = true
						local secs = LuckyEgg.secondsLeft(model)
						notify("Auto Hatch", "At a lucky egg" .. (secs and (" (" .. math.floor(secs / 60) .. "m left)") or ""))
					end
					return
				end
				if not t.toldLuckyFail then
					t.toldLuckyFail = true
					notify("Auto Hatch", errL or "Could not reach the lucky egg")
				end
				return
			end
			t.toldLuckyFail = false
			-- standing on it: open under its name so getOpenParams() picks up
			-- the globalEggId the game just registered for us
			egg = tostring(model.Name)
		else
			t.toldLucky = false
			t.luckyId = nil
		end
	end

	if EggController._currentEgg ~= egg then
		local ok, err = teleportToEgg(t, egg)
		if not ok then
			if not t.toldRange then
				t.toldRange = true
				notify("Auto Hatch", err or "Could not reach egg")
			end
			return
		end
		t.toldRange = false
	end

	local params = (EggController:getOpenParams())
	local enough = true
	local okA, amount = pcall(function()
		return Util.eggUtils.getAmountFromOpenType(LocalPlayer, data, egg, 2, params)
	end)
	if okA then
		local okB, has = pcall(function()
			return Util.eggUtils.hasEnoughToOpen(data, egg, amount, params)
		end)
		if okB then
			enough = has
		end
	end

	if not enough then
		notify("Auto Hatch", "Out of currency for " .. tostring(egg) .. ", stopping.")
		Options.AutoHatch:SetValue(false)
		return
	end

	-- openType 2 = "as many as the batch allows", which is the game's own max
	-- (Values.MaxEggs, 24 on this account). The amount the server actually
	-- spends comes from getAmountFromOpenType below, so no amount is sent here.
	pcall(function()
		EggService.openEgg:Fire(egg, 2, params)
	end)

	-- applyHatchInterval reads the speed through Values itself
	applyHatchInterval(t)
end

local function rebirthRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local data = getData()
	if not data then
		return
	end
	local idx = highestUnlockedRebirth(data)
	if not idx then
		return
	end
	local n = Rebirths[idx]
	if not n or data.clicks < rebirthCost(n, data) then
		return
	end
	local ok, res = pcall(function()
		return RebirthService:rebirth(idx)
	end)
	if ok and res == "success" then
		t.cooldown = os.clock() + 0.15
		notify("Auto Rebirth", "Rebirth #" .. idx .. " done")
	end
end

local function fallRebirthRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local data = getData()
	if not data then
		return
	end
	local tier = FallRebirths[(data.fallRebirths or 0) + 1]
	if not tier then
		if not t.maxed then
			t.maxed = true
			notify("Fall", "Every fall rebirth tier is done")
		end
		return
	end
	if itemAmount(data, "acorns") < (tier.acorns or 0) then
		return
	end
	for _, req in pairs(tier.required or {}) do
		local need = req:getAmount()
		if itemAmount(data, req:getName()) < need then
			return
		end
	end
	local ok, res = pcall(function()
		return FallService:fallRebirth()
	end)
	if ok and res == "success" then
		t.maxed = false
		t.cooldown = os.clock() + 3
		notify("Fall", "Fall rebirth #" .. ((data.fallRebirths or 0) + 1) .. " done")
	end
end

local function treeRebirthRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local data = getData()
	if not data then
		return
	end
	local okLevel, level = pcall(function()
		return Util.fallUtils.getLevelFromXp(data.fallHarvestTreeXp or 0)
	end)
	if not okLevel then
		return
	end
	local idx = math.min((data.fallHarvestTreeRebirths or 0) + 1, #HarvestTree.rebirths)
	local tier = HarvestTree.rebirths[idx]
	if not tier then
		return
	end
	if level < tier.maxLevel then
		return
	end
	local ok, res = pcall(function()
		return FallService:fallTreeRebirth()
	end)
	if ok and (res == true or res == "success") then
		t.cooldown = os.clock() + 3
		notify("Fall", "Tree rebirth #" .. ((data.fallHarvestTreeRebirths or 0) + 1) .. " done")
	elseif ok and type(res) == "string" then
		t.cooldown = os.clock() + 10
	end
end

local function applyRakeSpeed(on)
	local ok, hum = pcall(function()
		return Functions.getHumanoid(LocalPlayer)
	end)
	if not ok or not hum then
		return
	end
	if on then
		local speed = (Options.RakeSpeed and tonumber(Options.RakeSpeed.Value)) or 24
		hum.WalkSpeed = speed
	else
		pcall(function()
			hum.WalkSpeed = 16
		end)
	end
end

-- Probe for an exposed per-pile rake remote (Knit services are tables, and
-- fall tools aren't real Tools in the character, so this usually stays nil and
-- the hub falls back to the snap-to-pile + activity re-grab path below).
-- Ground Y of a model's footprint so teleports drop on solid ground, never
-- below the floor or floating in the air.
local function modelBaseY(m)
	if not m then
		return nil
	end
	-- GetBoundingBox returns a CFrame, which has no Size; the model's real
	-- extent comes from GetExtentsSize. Reading box.Size here used to throw
	-- "Size is not a valid member of CFrame" and take every runner with it.
	local ok, box = pcall(function()
		return m:GetBoundingBox()
	end)
	if ok and box then
		local okExt, ext = pcall(function()
			return m:GetExtentsSize()
		end)
		if okExt and ext then
			return box.Position.Y - ext.Y / 2
		end
	end
	local ok2, pv = pcall(function()
		if m:IsA("BasePart") then
			return m.Position.Y
		end
		return m:GetPivot().Position.Y
	end)
	if ok2 and pv then
		return pv
	end
	return nil
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = false

local function standLift(hrp)
	-- CFrame has no Size member, so GetBoundingBox cannot be used for the
	-- character's height. GetExtentsSize is the supported way.
	local char = LocalPlayer and LocalPlayer.Character
	if char then
		local ok, lift = pcall(function()
			local extents = char:GetExtentsSize()
			local height = extents and extents.Y or 0
			if height <= 0 then
				return nil
			end
			return hrp.Position.Y - (hrp.Position.Y - height / 2)
		end)
		if ok and lift and lift > 0.5 and lift < 12 then
			return lift
		end
	end
	return math.max(2.5, (hrp and hrp.Size and hrp.Size.Y or 5) / 2)
end

-- Ground height at (x,z) close to refY.
--
-- The probe has to start only a little above the reference height and stop
-- soon below it. Casting from refY+300 down for 1400 studs reaches terrain
-- hundreds of studs up - the Skylands floating islands sit directly above the
-- volcano and above the mine - so a caller standing beside a tree on a lower
-- map gets placed on the island overhead: correct X/Z, wildly wrong Y. That
-- is what left chop "teleported but doing nothing".
local function groundY(x, z, refY, exclude)
	local list = {}
	if LocalPlayer and LocalPlayer.Character then
		list[#list + 1] = LocalPlayer.Character
	end
	if exclude then
		list[#list + 1] = exclude
	end
	groundParams.FilterDescendantsInstances = list
	local hit = workspace:Raycast(Vector3.new(x, refY + 25, z), Vector3.new(0, -70, 0), groundParams)
	return hit and hit.Position.Y or nil
end

local function groundStand(x, z, refY, exclude, hrp)
	local ref = refY or (hrp and hrp.Position.Y) or 0
	local y = groundY(x, z, ref, exclude)
	if not y then
		-- nothing in range: probe from the reference itself, then settle for
		-- standing at the reference height rather than at the character's
		y = groundY(x, z, ref + 2, exclude) or ref
	end
	return Vector3.new(x, y + standLift(hrp), z)
end

-- ------------------------------------------------------------------
-- rake: drive FallService.damageLeafPiles directly.
--
-- The in-game auto rake is the slow path: it walks to a pile with MoveTo,
-- then sleeps 1.5s before looking for the next one, so you spend most of
-- the time travelling instead of hitting. The remote it ends up firing is
-- FallService.damageLeafPiles(n), where n is how many piles in range the
-- server should hit.
--
-- Measured on this account: the server caps throughput at ~26 leaves/s and
-- that cap is the same at a 0.02s or a 0.001s gap, so firing faster buys
-- nothing. What matters is never idling between piles, and sending n equal
-- to the tool's range (range 1 -> 6/s, 2 -> 13/s, 4 -> 26/s, 8 -> 22/s,
-- i.e. over-firing gets rejected). So: stand once in the densest live
-- cluster, hold fire at 0.02s, and only re-target when that cluster dies.
-- ------------------------------------------------------------------
-- Constants kept on LiveCounts rather than as top-level locals: this file sits
-- at Luau's 200-register cap, and each one here is a register the hub needs.
LiveCounts.RAKE_CLUSTER_RADIUS = 26
-- Leaf piles live on the Fall Event map, which is mapId 0 in Shared.List.Maps
local FALL_MAP_ID = 0

-- keep-out zones: anything named "part2" is the part 2 event portal, and
-- snapping into it starts/triggers the event. Never target near one.
LiveCounts.KEEPOUT_RADIUS = 90
local keepoutPoints = nil
local function keepoutList()
	if keepoutPoints then
		return keepoutPoints
	end
	local list = {}
	local ok, res = pcall(function()
		local fallback = workspace:FindFirstChild("Game", true)
		local root = fallback and fallback:FindFirstChild("Maps", true) or workspace
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("Model") then
				local n = string.lower(d.Name)
				if n:find("part2") or n:find("part 2") or n:find("parttwo") then
					local okp, p = pcall(function()
						return d:GetPivot().Position
					end)
					if okp and p then
						list[#list + 1] = p
					end
				end
			end
		end
	end)
	keepoutPoints = (ok and type(res) == "table") and list or {}
	return keepoutPoints
end

local function nearKeepout(pos)
	for _, p in ipairs(keepoutList()) do
		local dx, dz = pos.X - p.X, pos.Z - p.Z
		if (dx * dx + dz * dz) < (LiveCounts.KEEPOUT_RADIUS * LiveCounts.KEEPOUT_RADIUS) then
			return true, p
		end
	end
	return false
end

-- best standing spot for raking: the live pile inside the largest tight
-- cluster, ignoring any cluster that sits near the part 2 portal
local function bestRakeSpot(pos)
	local live = {}
	for _, p in ipairs(CollectionService:GetTagged("LeafPile")) do
		if p:IsDescendantOf(workspace) and not p:GetAttribute("respawnsAt") then
			live[#live + 1] = p
		end
	end
	local n = #live
	if n == 0 then
		return nil
	end
	local pts = table.create(n)
	for i = 1, n do
		pts[i] = live[i]:GetPivot().Position
	end
	local best, bestScore, bestD = nil, -math.huge, math.huge
	local r2 = LiveCounts.RAKE_CLUSTER_RADIUS * LiveCounts.RAKE_CLUSTER_RADIUS
	for i = 1, n do
		local d = (pts[i] - pos).Magnitude
		if d > 1200 then
			continue
		end
		if not nearKeepout(pts[i]) then
			local count = 0
			for j = 1, n do
				if i ~= j then
					local dx, dz = pts[i].X - pts[j].X, pts[i].Z - pts[j].Z
					if (dx * dx + dz * dz) <= r2 then
						count += 1
					end
				end
			end
			-- prefer dense, and prefer near, but never trade density for the
			-- part 2 portal - that is a hard veto above, not a penalty
			local score = count * 10 - d * 0.02
			if score > bestScore then
				bestScore, best, bestD = score, live[i], d
			end
		end
	end
	if not best then
		-- everything is either gone or inside a keep-out: fall back to the
		-- nearest legal pile, which may be far away but is never the portal
		for i = 1, n do
			local d = (pts[i] - pos).Magnitude
			if not nearKeepout(pts[i]) and d < bestD then
				bestD, best = d, live[i]
			end
		end
	end
	return best
end

-- how many piles one hit is allowed to claim: the tool's own range
local function rakeHitCount(data)
	local ok, n = pcall(function()
		local bestIdx = -1
		for _, e in pairs(data.inventory and data.inventory.fallEvent or {}) do
			local def = type(e) == "table" and FallEventList[e.nm]
			if type(def) == "table" and def.isTool and (def.index or 0) > bestIdx then
				bestIdx = def.index or 0
			end
		end
		if bestIdx < 0 then
			return 1
		end
		local range = 1
		for key, def in pairs(FallEventList) do
			if type(def) == "table" and def.isTool and def.index == bestIdx then
				local toolOk, tool = pcall(function()
					return Items.fallEvent(key)
				end)
				if toolOk and tool then
					local d = tool:directory()[tool:getName()]
					if type(d) == "table" and type(d.range) == "number" then
						range = d.range
					end
				end
				break
			end
		end
		local extra = 0
		local rakeOk, v = pcall(function()
			return Values.rakeRange(LocalPlayer, data)
		end)
		if rakeOk and type(v) == "number" then
			extra = v
		end
		return math.max(1, math.floor(range + extra))
	end)
	return (ok and type(n) == "number" and n > 0) and n or 1
end

local function humHipHeight()
	local ok, hum = pcall(function()
		return Functions.getHumanoid(LocalPlayer)
	end)
	if ok and hum and hum.HipHeight then
		return hum.HipHeight
	end
	return 0
end

local function rakeFarmRunner(t)
	local data = getData()
	if not data or not FallService then
		return
	end

	-- Leaf piles only exist on the Fall Event map (mapId 0). Without this the
	-- runner happily fires the remote from whatever map you are standing on
	-- and the server pays nothing, which looks exactly like "it raked once".
	if MapController == nil then
		MapController = getController("MapController")
	end
	if MapController then
		local ok, onMap = pcall(function()
			return MapController._currentMapId == FALL_MAP_ID
		end)
		if ok and not onMap then
			t.traveling = true
			pcall(function()
				MapController:setCurrentMap(FALL_MAP_ID)
			end)
			return
		end
		t.traveling = false
	end

	if not data.isRakeToolEquipped then
		local okRake = equipRake()
		if not okRake and not t.toldNoRake then
			t.toldNoRake = true
			notify("Auto Rake", "No rake owned - buy one first.")
		end
		return
	end
	t.toldNoRake = false
	applyRakeSpeed(true)
	local hrp = Functions.getHRP(LocalPlayer)
	if not hrp then
		return
	end

	-- Re-anchor is the expensive half (it walks every live pile), so it runs
	-- on its own slow cadence. Firing happens every tick, which is what
	-- actually earns leaves.
	local now = os.clock()
	if now >= (t.rakeScanAt or 0) then
		t.rakeScanAt = now + 0.4
		t.rakeRange = rakeHitCount(data)
		-- the shrink animation length the game uses: 0.5 / (toolSpeed + upgrade)
		pcall(function()
			local item
			for _, e in pairs(data.inventory and data.inventory.fallEvent or {}) do
				local def = type(e) == "table" and FallEventList[tostring(e.nm)]
				if type(def) == "table" and def.isTool and (def.index or 0) > (t.rakeToolIdx or -1) then
					t.rakeToolIdx = def.index
				end
			end
			if t.rakeToolIdx then
				for key, def in pairs(FallEventList) do
					if type(def) == "table" and def.isTool and def.index == t.rakeToolIdx then
						local okT, tool = pcall(function()
							return Items.fallEvent(key)
						end)
						if okT and tool then
							local d = tool:directory()[tool:getName()]
							if type(d) == "table" and type(d.speed) == "number" then
								item = d.speed
							end
						end
					end
				end
			end
			t.rakeToolSpeed = (item or 1) + (Values.rakeSpeed(LocalPlayer, data) or 0)
		end)

		local anchor = t.rakeAnchor
		local settled = false
		if anchor and anchor:IsDescendantOf(workspace) and not anchor:GetAttribute("respawnsAt") then
			if (anchor:GetPivot().Position - hrp.Position).Magnitude <= LiveCounts.RAKE_CLUSTER_RADIUS + 8 then
				settled = true
			end
		end

		if not settled then
			local pile = bestRakeSpot(hrp.Position)
			if pile then
				t.idleTime = 0
				t.rakeAnchor = pile
				local pp = pile:GetPivot().Position
				-- groundStand raycasts down and adds the hip lift, so the
				-- stand point is always on real floor - never under the map
				local off = pp - hrp.Position
				off = off.Magnitude > 0.001 and off.Unit or Vector3.new(1, 0, 0)
				local want = pp - off * 3
				local stand = groundStand(want.X, want.Z, modelBaseY(pile), pile, hrp)
				hrp.CFrame = CFrame.lookAt(stand, Vector3.new(pp.X, stand.Y, pp.Z))
				pcall(function()
					hrp.AssemblyLinearVelocity = Vector3.zero
				end)
			elseif (t.idleTime or 0) + 30 < now then
				t.idleTime = now
				notify("Auto Rake", "All piles cleared - waiting for respawns")
			end
		end
	end

	-- never fire from inside the part 2 portal keep-out
	if nearKeepout(hrp.Position) then
		return
	end

	local n = t.rakeRange or 1

	-- The pile bookkeeping the game's own onClick does, which we have to
	-- mirror. Reading LeafRakeController: each hit sets `damage` +1, and
	-- updateLeafPiles() tweens the pile down by Y * (damage/7) so it visibly
	-- shrinks; at damage 7 it sets `respawnsAt = os.time() + respawnDelay`,
	-- which is what finally removes it from play. Without this the piles never
	-- change at all and the cluster we are parked on looks frozen.
	--
	-- (An earlier version of this file skipped this as "poisoning the server".
	-- That was a misdiagnosis: the 0/s reading that prompted it was taken before
	-- the map-travel fix, when there were no piles in range at all. The server
	-- picks its own targets; these attributes are purely the client view.)
	local origin = hrp.Position - Vector3.new(0, humHipHeight(), 0) + hrp.CFrame.LookVector * 3
	local reach = (n + 3) * 1.5
	local respawnDelay = 35
	pcall(function()
		respawnDelay = Values.leavesSpawnDuration(LocalPlayer, data) or 35
	end)

	local inRange = {}
	for _, pile in pairs(CollectionService:GetTagged("LeafPile")) do
		if not pile:GetAttribute("respawnsAt") then
			local ok, pv = pcall(function()
				return pile:GetPivot().Position
			end)
			if ok and (pv - origin).Magnitude < reach then
				inRange[#inRange + 1] = { pile = pile, pos = pv }
			end
		end
	end
	-- nearest first, exactly like the game's own loop over the tagged list
	table.sort(inRange, function(a, b)
		return (a.pos - origin).Magnitude < (b.pos - origin).Magnitude
	end)

	local hits = math.min(#inRange, n)
	for i = 1, hits do
		local pile = inRange[i].pile
		local dmg = (pile:GetAttribute("damage") or 0) + 1
		pile:SetAttribute("damage", dmg)
		if dmg >= 7 then
			pile:SetAttribute("respawnsAt", os.time() + respawnDelay)
		elseif not pile:GetAttribute("lastDamage") or pile:GetAttribute("lastDamage") ~= dmg then
			-- same shrink tween as updateLeafPiles, so the pile visibly sinks
			local pivot = pile:GetAttribute("pivot")
			local part = pile.PrimaryPart
			if part and not pile:GetAttribute("isTweening") then
				if not pivot then
					pcall(function()
						pile:SetAttribute("pivot", pile:GetPivot())
					end)
					pivot = pile:GetAttribute("pivot")
				end
				if pivot then
					local sizeY = part.Size.Y
					local target = pivot * CFrame.new(0, -(sizeY * (dmg / 7)) - 0.01, 0)
					local dur = 0.5 / ((t.rakeToolSpeed or 1) + 1)
					pcall(function()
						TweenService:Create(pile, TweenInfo.new(dur), {
							finalCFrame = target,
						}):Play()
					end)
					pile:SetAttribute("lastDamage", dmg)
					pile:SetAttribute("isTweening", true)
					task.delay(dur, function()
						pile:SetAttribute("isTweening", nil)
					end)
				end
			end
		end
	end
	t.lastHits = hits
	t.lastPileCount = #inRange

	pcall(function()
		FallService.damageLeafPiles:Fire(n)
	end)
end

-- ------------------------------------------------------------------
-- auto meteor destroying
--
-- Meteors (Meteorite Shower) are tagged "Meteor" and carry meteorId /
-- meteorType / damage. EventController:onClickMeteor() is the whole game
-- behaviour: for every meteor within 25 studs of the HRP, fire
-- EventService.damageMeteorFastDenRiktiga with its meteorId. So this is the
-- same remote-fire shape as the rake - walk within 25 studs, then spam.
--
-- One remote is named "jag känner en bot..." in Swedish. It is still just a
-- RemoteWrapper with Fire(), reached as EventService.damageMeteorFastDenRiktiga,
-- so the odd name costs us nothing.
-- ------------------------------------------------------------------
LiveCounts.METEOR_HIT_RANGE = 25
LiveCounts.METEOR_STAND_RANGE = 18

local function meteorRef()
	EventService = EventService or getService("EventService")
	return EventService
end

local function meteorHealth(meteor)
	local ok, def = pcall(function()
		return Meteors[meteor:GetAttribute("meteorType")]
	end)
	if ok and type(def) == "table" and type(def.health) == "number" then
		return def.health
	end
	return nil
end

local function meteorRunner(t)
	local es = meteorRef()
	local hrp = Functions.getHRP(LocalPlayer)
	if not es or not es.damageMeteorFastDenRiktiga or not hrp then
		return
	end

	local here, nearest, nearestDist = {}, nil, math.huge
	for _, meteor in pairs(CollectionService:GetTagged("Meteor")) do
		local part = meteor.PrimaryPart
		if part then
			local d = (part.Position - hrp.Position).Magnitude
			if d < LiveCounts.METEOR_HIT_RANGE then
				here[#here + 1] = meteor
			end
			if d < nearestDist then
				nearest, nearestDist = meteor, d
			end
		end
	end

	if #here == 0 then
		if nearest and nearestDist > LiveCounts.METEOR_STAND_RANGE then
			-- nothing in reach: close on the nearest meteor. Anchor the stand
			-- point off its own pivot so we never end up inside the rock.
			local pp = nearest:GetPivot().Position
			local to = pp - hrp.Position
			to = to.Magnitude > 0.001 and to.Unit or Vector3.new(1, 0, 0)
			local stand = groundStand((pp - to * LiveCounts.METEOR_STAND_RANGE).X, (pp - to * LiveCounts.METEOR_STAND_RANGE).Z, modelBaseY(nearest), nearest, hrp)
			hrp.CFrame = CFrame.lookAt(stand, Vector3.new(pp.X, stand.Y, pp.Z))
			pcall(function()
				hrp.AssemblyLinearVelocity = Vector3.zero
			end)
		end
		t.lastHits = 0
		t.lastMeteors = 0
		if (t.idleTime or 0) + 30 < os.clock() and not t.toldIdle then
			t.toldIdle = true
			t.idleTime = os.clock()
			notify("Auto Meteor", "No meteor in range yet")
		end
		return
	end
	t.toldIdle = false

	-- nearest first, and report which one we are working on
	table.sort(here, function(a, b)
		return (a.PrimaryPart.Position - hrp.Position).Magnitude < (b.PrimaryPart.Position - hrp.Position).Magnitude
	end)

	local best = here[1]
	local hp = meteorHealth(best)
	local dmg = best:GetAttribute("damage") or 0
	t.lastHits = #here
	t.lastMeteors = #CollectionService:GetTagged("Meteor")
	t.targetType = best:GetAttribute("meteorType")
	if hp then
		t.targetDesc = ("%s %d/%d (%d in range)"):format(tostring(t.targetType), hp - dmg, hp, #here)
	else
		t.targetDesc = ("%s %d dmg (%d in range)"):format(tostring(t.targetType), dmg, #here)
	end

	-- the server owns the health attribute; we only fire
	for _, meteor in ipairs(here) do
		local id = meteor:GetAttribute("meteorId")
		if id then
			pcall(function()
				es.damageMeteorFastDenRiktiga:Fire(id)
			end)
		end
	end
end

local function meteorStop(t)
	t.lastHits = nil
	t.lastMeteors = nil
end

-- ------------------------------------------------------------------
-- auto pet crafting: golden -> toxic -> galaxy -> rainbow
--
-- The four machines share one component (CraftMachineFrame) and one call:
--   PetService:craft(itemIds, craftAll, amount)
-- where itemIds are the inventory ids of the pets to consume. Verified on
-- this account: craft({id}, false, 1) returns "success" in ~60ms and
-- consumes exactly 5 copies of that pet to make one at the next tier.
-- craftAll = true means "craft as many as the stack allows" and is what we
-- want, since it consumes everything rather than leaving a remainder of 4.
-- ------------------------------------------------------------------
local PET_TIERS = { golden = 2, toxic = 3, galaxy = 4, rainbow = 5 }
local PET_TIER_NAMES = { golden = "Golden", toxic = "Toxic", galaxy = "Galaxy", rainbow = "Rainbow" }

local function petServiceRef()
	PetService = PetService or getService("PetService")
	return PetService
end

-- Craft machine reference behaviour, verified against the live account.
--
-- Two things made every craft toggle a no-op:
--
-- 1) craft(ids, craftAll, amount) answers "isNotSame" unless EVERY id in the
--    call refers to the SAME pet descriptor. Verified: passing three different
--    tier-1 ids returned "isNotSame"; passing one id returned "success". The
--    old petIdsForTier collected every eligible id in the tier into a single
--    call, so with more than one pet type in the inventory it always failed.
--    petIdGroupsForTier now groups ids BY DESCRIPTOR and the caller makes one
--    call per group. The game's own craft-all does exactly this - see
--    CraftMachineFrame:invokeCraftAllPets, which walks the inventory and
--    groups by petUtils.getPetDescriptor.
--
-- 2) TiersList is keyed by NUMBER 1..5, not by name. TiersList["golden"] is
--    nil, so canAffordCraft's lookup silently found no definition and every
--    shard gate was skipped. Only tier 5 (Rainbow) has a craftPrice at all,
--    and its currency is rainbowShard.
--
-- Group every craftable id under `tier` by pet descriptor.
-- Returns an array of {desc = ..., ids = {...}}, one entry per distinct pet.
local function petIdGroupsForTier(data, tier)
	local groups, order = {}, {}
	if not data.inventory or not data.inventory.pet then
		return groups
	end
	for id, entry in pairs(data.inventory.pet) do
		if type(entry) == "table" and (entry.ti or 1) == tier - 1 and (entry.am or 0) >= 5 then
			local ok, item = pcall(function()
				return Util.itemUtils.getItemFromId(data, id)
			end)
			local usable = ok and item ~= nil
			-- the game's own gate: the pet must actually be craftable to the
			-- target tier (no image at that tier, etc)
			if usable then
				local okC, canCraft = pcall(function()
					return Util.petUtils.canCraftToTier(item, tier)
				end)
				usable = okC and canCraft ~= false and canCraft ~= nil
			end
			-- an evolved pet is excluded by CraftMachineFrame:createPetUI
			if usable then
				local okE, evo = pcall(function()
					return item:getEvolution()
				end)
				usable = not (okE and evo)
			end
			if usable then
				local okL, lk = pcall(function()
					return item:getLocked()
				end)
				usable = not (okL and lk)
			end
			-- favourites are protected by the game's own craft-all path
			if usable and data.favorites and data.favorites[id] then
				usable = false
			end
			if usable then
				local okD, desc = pcall(function()
					return Util.petUtils.getPetDescriptor(item)
				end)
				if okD and desc then
					if not groups[desc] then
						groups[desc] = {}
						order[#order + 1] = desc
					end
					table.insert(groups[desc], id)
				end
			end
		end
	end
	local out = {}
	for _, desc in ipairs(order) do
		out[#out + 1] = { desc = desc, ids = groups[desc] }
	end
	-- deterministic order so the same pet is worked on first each pass
	table.sort(out, function(a, b)
		return a.desc < b.desc
	end)
	return out
end

local TiersList = require(ReplicatedStorage.Shared.List.Pets.Tiers)

-- how many copies of tier-1-below exist, used only to report progress
local function countCraftable(data, tier)
	local n = 0
	if not data.inventory.pet then
		return 0
	end
	for _, entry in pairs(data.inventory.pet) do
		if type(entry) == "table" and (entry.ti or 1) == tier - 1 then
			n += (entry.am or 0)
		end
	end
	return n
end

-- currency gate: Tiers[tier].craftPrice names the currency and per-rarity cost
-- Shard gate. Only Rainbow (tier 5) has a craftPrice - verified: tiers 1-4
-- have none. Its shape is {currency = <item name>, rarities = {<rarity> = n}},
-- so the cheapest possible craft is the lowest rarity cost. Keyed by NUMBER,
-- which is why the old TiersList["golden"] lookup found nothing.
local function canAffordCraft(data, tier)
	local def = TiersList[tier]
	if not def or type(def) ~= "table" or type(def.craftPrice) ~= "table" then
		return true
	end
	local price = def.craftPrice
	local have = 0
	local okCur, cur = pcall(function()
		return Util.itemUtils.getItemFromName(data, price.currency)
	end)
	if okCur and cur then
		pcall(function()
			have = cur:getAmount()
		end)
	end
	local cheapest = math.huge
	for _, cost in pairs(price.rarities or {}) do
		if type(cost) == "number" and cost < cheapest then
			cheapest = cost
		end
	end
	if cheapest == math.huge then
		return true
	end
	return have >= cheapest
end

local function craftPetsTier(t, tierKey)
	local svc = petServiceRef()
	if not svc then
		return
	end
	local tier = PET_TIERS[tierKey]
	if not tier then
		return
	end
	local data = getData()
	if not data then
		return
	end
	if not canAffordCraft(data, tier) then
		-- only tier 5 can ever land here; do not nag on every tick
		if not t.toldNoShards then
			t.toldNoShards = true
			local curName = TiersList[tier] and TiersList[tier].craftPrice
				and TiersList[tier].craftPrice.currency or "shards"
			notify("Pet Craft", ("Out of %s - Rainbow craft skipped."):format(tostring(curName)))
		end
		return
	end
	t.toldNoShards = false

	local groups = petIdGroupsForTier(data, tier)
	if #groups == 0 then
		return
	end

	-- ONE CALL PER DISTINCT PET, sweeping EVERY group every pass.
	--
	-- craftAll = true spends the whole stack rather than leaving a remainder of
	-- 4, and one call per descriptor is required because the server answers
	-- "isNotSame" if the ids are not all the same pet (verified).
	--
	-- Why it used to crawl: the loop broke out the moment t.cooldown was in the
	-- future, which was true for every tick after the first craft, so it did at
	-- most one craft per 0.4s tick and stopped dead at a 40-attempt cap. Now the
	-- whole sweep runs in one pass with no in-loop cooldown break, and each
	-- group is measured individually so the progress count is real.
	local made, attempts, lastRes = 0, 0, nil
	for _, group in ipairs(groups) do
		attempts += 1
		-- a generous ceiling purely as a runaway guard; a full sweep of a large
		-- account is well under this
		if attempts > 500 then
			break
		end
		-- fresh data per group: the tier-N-below pool shrinks as we go, and a
		-- stale snapshot makes countCraftable report phantom progress
		local fresh = getData() or data
		local before = countCraftable(fresh, tier)
		-- count this group's own stack specifically, since the pool total also
		-- moves when other pets are crafted
		local ok, res = pcall(function()
			return svc:craft(group.ids, true, math.huge)
		end)
		lastRes = res
		if ok and res == "success" then
			local after = countCraftable(getData() or fresh, tier)
			-- anything consumed beyond this group's own share came from other
			-- stacks, but every success is still one pet made
			local dropped = (before - after) or 0
			made += math.max(dropped > 0 and math.floor(dropped / 5) or 1, 1)
		elseif ok then
			-- per-pet rejection: keep going, the next pet may well work. A
			-- shard shortfall will not improve, so stop on that one.
			t.lastReject = tostring(res)
			if res == "notEnoughShards" or res == "notEnoughCurrency" then
				break
			end
		else
			t.lastReject = tostring(res)
		end
	end
	t.swept = attempts
	t.lastRes = lastRes

	t.crafted = (t.crafted or 0) + made
	if made > 0 then
		-- the whole sweep already ran this pass, so the next one can start as
		-- soon as the server has caught up. 0.15s keeps it near the server's
		-- own round-trip without hammering it.
		t.cooldown = os.clock() + 0.15
		t.toldRes = false
		t.toldNoShards = false
		if notifyEnabled and (t.crafted % 50) < made then
			local nxt = ({ golden = "toxic", toxic = "galaxy", galaxy = "rainbow" })[tierKey]
			notify(
				"Pet Craft",
				("%s: %s -> %s (%d crafted so far)"):format(
					tierKey:upper(),
					(PET_TIER_NAMES[tierKey] or "?"),
					(PET_TIER_NAMES[nxt] or "?"),
					t.crafted
				)
			)
		end
	elseif lastRes ~= nil and lastRes ~= "success" then
		t.cooldown = os.clock() + 2
		-- surfaced once rather than every pass, so a rejected call is
		-- diagnosable instead of looking like a silent no-op
		if notifyEnabled and not t.toldRes then
			t.toldRes = true
			notify("Pet Craft", ("Server said %s"):format(tostring(lastRes)))
		end
	else
		-- nothing craftable right now: back off so we are not re-walking the
		-- whole inventory every 1.5s for no reason
		t.cooldown = os.clock() + 3
	end
end

-- ------------------------------------------------------------------
-- equip best pets
--
-- Mirrors the game's own "Equip Best" button (InventoryFrame), which:
--   1. collects every pet from data.inventory.pet
--   2. sorts by getMultiplier(data, {ignoreServer = true,
--      averageMultiplier = petUtils.getAverageMultiplier(data)})
--      descending - the average matters because a stack's multiplier is
--      shared across the copies
--   3. expands each stack one id per copy until the equip slots are full
--   4. unequips everything currently equipped, then equips that list
-- via PetService:unequipPet(ids, opts) / PetService:equipPet(ids, opts)
-- ------------------------------------------------------------------
local function petSortKey(data, item)
	local ok, mult = pcall(function()
		local avg = Util.petUtils.getAverageMultiplier(data)
		return item:getMultiplier(data, { ignoreServer = true, averageMultiplier = avg })
	end)
	if ok and type(mult) == "number" then
		return mult
	end
	local ok2, m2 = pcall(function()
		return item:getMultiplier()
	end)
	return (ok2 and type(m2) == "number") and m2 or 0
end

local function equipBestPets()
	local svc = petServiceRef()
	if not svc then
		return false, "PetService missing"
	end
	local data = getData()
	if not data or not data.inventory.pet then
		return false, "no pets"
	end

	-- how many slots we actually have. petsEquipped lives on Values, not Util
	local slots = 0
	local okSlots, v = pcall(function()
		return Values.petsEquipped(LocalPlayer, data)
	end)
	if okSlots and type(v) == "number" then
		slots = v
	end
	if slots <= 0 then
		slots = data.upgrades and data.upgrades.petEquip or 3
	end

	-- skip anything the player has explicitly locked or favourited
	local candidates = {}
	for id in pairs(data.inventory.pet) do
		local ok, item = pcall(function()
			return Util.itemUtils.getItemFromId(data, id)
		end)
		if ok and item then
			local skip = false
			pcall(function()
				if item:getLocked() then
					skip = true
				end
			end)
			if data.favorites and data.favorites[id] then
				skip = true
			end
			if not skip then
				table.insert(candidates, { id = id, item = item, key = petSortKey(data, item) })
			end
		end
	end
	if #candidates == 0 then
		return false, "no eligible pets"
	end

	table.sort(candidates, function(a, b)
		return a.key > b.key
	end)

	-- expand stacks: one entry per copy, filling the slots
	local best = {}
	for _, c in ipairs(candidates) do
		if #best >= slots then
			break
		end
		local copies = 1
		pcall(function()
			copies = math.max(1, c.item:getAmount())
		end)
		for _ = 1, copies do
			if #best >= slots then
				break
			end
			best[#best + 1] = c.id
		end
	end
	if #best == 0 then
		return false, "nothing to equip"
	end

	-- what is equipped now
	local currently = {}
	for id in pairs(data.equippedPets or {}) do
		currently[#currently + 1] = id
	end

	-- equippedPets is keyed by pet descriptor, not inventory id, so its keys
	-- will never match the id list we just built and an id-by-id diff would
	-- re-equip on every single tick. Instead compare strength: only act when
	-- the best multiplier on offer beats the best one we last equipped.
	local strongestNow = 0
	for _, c in ipairs(candidates) do
		if c.key > strongestNow then
			strongestNow = c.key
		end
	end
	local weakestChosen = math.huge
	for _, id in ipairs(best) do
		for _, c in ipairs(candidates) do
			if c.id == id and c.key < weakestChosen then
				weakestChosen = c.key
			end
		end
	end
	if weakestChosen == math.huge then
		weakestChosen = 0
	end

	local okU, resU = pcall(function()
		return svc:unequipPet(currently, {})
	end)
	if not (okU and resU == "success") then
		return false, "unequip failed"
	end
	local okE, resE = pcall(function()
		return svc:equipPet(best, {})
	end)
	if okE and resE == "success" then
		return true, #best
	end
	return false, "equip failed"
end

local function equipBestRunner(t)
	if (t.cooldown or 0) > os.clock() then
		return
	end
	-- cheap gate: only run the full sort when the inventory actually changed
	local data = getData()
	if not data or not data.inventory.pet then
		return
	end
	local fingerprint = 0
	local count = 0
	for id, e in pairs(data.inventory.pet) do
		fingerprint += #id + (e.am or 0)
		count += 1
	end
	if t.petPrint == fingerprint then
		return
	end
	local ok, made = equipBestPets()
	t.petPrint = fingerprint
	t.cooldown = os.clock() + 2
	if ok then
		t.equipped = (t.equipped or 0) + 1
		notify("Equip Best", ("Equipped %d stronger pet%s"):format(made, made == 1 and "" or "s"))
	end
end

local function petCraftRunner(t, tierKey)
	if (t.cooldown or 0) > os.clock() then
		return
	end
	craftPetsTier(t, tierKey)
end

-- ------------------------------------------------------------------
-- Auto Index (rcu-egg-index.luau)
--
-- Kept in its own file because this chunk is one register scope capped at 200
-- and the feature carries a lot of helpers. Inlined here it tipped the hub over
-- the limit and nothing loaded at all.
--
-- NOTE: it is passed in as SOURCE, not loaded with loadstring, for the same
-- reason readfile is not used anywhere else in this file - the executor
-- rejects absolute paths with "Path outside workspace", so a load attempt
-- would silently fail and the feature would just vanish again. The MCP writes
-- the source next to the hub and injects it here instead.
-- ------------------------------------------------------------------
local AutoIndex = nil
do
	-- Auto Index module, embedded verbatim.
	--
	-- This used to be injected from OUTSIDE via _G.__RCU_EGG_INDEX_SRC, which
	-- only worked when I set that global before loading. Loaded the normal way
	-- (loadstring of a GitHub raw URL) the global is absent, AutoIndex stayed
	-- nil, and the next statement -- "AutoIndex.hatchEgg = ..." -- threw
	-- "attempt to index nil with 'hatchEgg'", killing the hub before the window
	-- opened. Embedding the source as a string constant makes the file
	-- self-contained, and a string costs no local registers.
	local src = [==[-- rcu-egg-index.luau - Auto Index.
--
-- Lives in its own file because rcu-hub.luau's main chunk is a single register
-- scope and Luau caps it at 200; this is a big feature with a lot of helpers,
-- and inlining it tipped the hub over the limit. A separate file gets its own
-- scope, so none of this costs the hub anything.
--
-- Returns Build(sec, Options, ctx) which adds the toggles + dropdowns and
-- registers the runner. ctx carries the hub's services and helpers.
--
-- ---------------------------------------------------------------------------
-- What it does
--
-- You pick rarities (and optionally the shiny variant) in a dropdown. The
-- feature works out every pet in the game at those rarities that you have NOT
-- unlocked yet, finds an egg that can drop one of them, teleports there and
-- hatches at the normal legal rate until they are all unlocked.
--
-- It does not force a variant and does not touch the odds. It only chooses
-- WHICH EGG to open and when to stop. Hatching is the game's own loop at the
-- game's own speed; we just point it at an egg and watch the collection.
--
-- If a wanted pet is craftable (canCraftToTier), it hands the job to the
-- craft machine instead of hatching - verified below.
--
-- ---------------------------------------------------------------------------
-- Game data, all verified against the live account
--
-- Shared.List.Pets.Eggs[name] = { cost, currency, pets, requiredMap }
--   pets is a MAP of petName -> chance (a number, not an array). 74 eggs.
--
-- Shared.List.Pets.Pets[name] = { rarity, multiplier, indexCategory, ... }
--   1403 pets. rarity is a NAME string, one of the 13 in Rarities (1..13):
--   Common, Uncommon, Rare, Epic, Legendary, Mythical, Eternal, Secret,
--   Divine, Mysterious, Exclusive, Supreme, Ultimate.
--
-- Shared.List.Pets.Tiers[i] = { name, ... } keyed by NUMBER 1..5:
--   Normal, Golden, Toxic, Galaxy, Rainbow. Only Rainbow has canIndex=false.
--
-- Ownership is read with Util.petUtils.getPetDescriptor(item), which returns
-- "name:tier" or "name:tier:s". Verified: the trailing "s" is exactly
-- item:isShiny() - 79 of 226 owned descriptors ended in "s" and all 79 were
-- isShiny() == true, with zero false positives among the rest. So a shiny pet
-- is a genuinely separate unlock, and the variant dropdown has something real
-- to select.
-- ---------------------------------------------------------------------------

return function(REPO)
	local RS = REPO.RS
	local Knit = REPO.Knit
	local Util = REPO.Util
	local PetsList = REPO.PetsList
	local RaritiesList = REPO.RaritiesList
	local EggList = REPO.EggList

	-- Rarities split into two groups, because the user asked for Eternal+ to
	-- have its own dropdown: those are much harder to actually land, so they
	-- want to opt into that chase separately from the common grind.
	local ETERNAL_PLUS = { Eternal = true, Secret = true, Divine = true, Mysterious = true, Supreme = true, Ultimate = true }

	local ALL_RARITIES = {}
	for _, def in pairs(RaritiesList) do
		if type(def) == "table" and def.name then
			ALL_RARITIES[#ALL_RARITIES + 1] = tostring(def.name)
		end
	end
	table.sort(ALL_RARITIES)

	local normalRarities, highRarities = {}, {}
	for _, r in ipairs(ALL_RARITIES) do
		if ETERNAL_PLUS[r] then
			highRarities[#highRarities + 1] = r
		else
			normalRarities[#normalRarities + 1] = r
		end
	end

	-- ------------------------------------------------------------------
	-- helpers
	-- ------------------------------------------------------------------

-- What the game considers unlocked.
	--
	-- Read data.index, NOT the inventory. These are NOT the same thing and
	-- using the inventory gives wrong answers in both directions: measured on
	-- this account at one Epic tier, 59 pets were in data.index with no
	-- inventory row at all, and 74 were in the inventory but not in data.index.
	-- data.index is the persistent collection the server owns and the same set
	-- IndexUtils.hasIndex reads, so it is the only correct source.
	--
	-- Shiny is handled exactly as the game does it - hasIndex is
	--   index[desc] or index[desc .. ":s"]
	-- so either form marks the base pet done, and the shiny form is its own
	-- entry. Shiny is therefore part of the index, but it is not a "variant"
	-- choice: it arrives from the same hatch, so it is never gated separately.
	local function isUnlocked(data, key)
		local idx = data.index
		if type(idx) ~= "table" then
			return false
		end
		return (idx[key] == nil) and (idx[key .. ":s"] == nil)
	end

	-- normalise a pet name to the lowercase form a descriptor uses
	-- ("Petal Deer" -> "petaldeer")
	local function descName(name)
		return (tostring(name):lower():gsub("[%s%-']", ""))
	end

-- What is still missing from ONE specific egg, recomputed from scratch.
	--
	-- Deliberately independent of buildEggPlan's tables. The plan entries are
	-- shared objects held in the runner, and writing the recomputed list back
	-- onto them was corrupting the very list the next pass read, which made the
	-- runner think the current egg had nothing left after one tick and skipped
	-- straight past it. Computing from EggList + data.index only means there is
	-- no shared state to go stale.
	--
	-- Returns a list of {pet, tier, rarity} plus a count and the odds.
	local function eggMissingList(data, eggName, wantRarities, tiers)
		local egg = EggList[eggName]
		local out, count = {}, 0
		if type(egg) ~= "table" or type(egg.pets) ~= "table" then
			return out, 0, 0
		end
		local raritySet, tierSet = {}, {}
		for _, r in ipairs(wantRarities or {}) do
			raritySet[r] = true
		end
		for _, n in ipairs(tiers or {}) do
			tierSet[n] = true
		end
		local anyTier = next(tierSet) == nil

		local bestChance, total = 0, 0
		for petName, chance in pairs(egg.pets) do
			local def = PetsList[petName]
			if type(chance) == "number" and type(def) == "table" and raritySet[def.rarity] then
				local base = descName(petName)
				for tier = 1, 4 do
					if anyTier or tierSet[tier] then
						if isUnlocked(data, base .. ":" .. tier) then
							out[#out + 1] = { pet = petName, tier = tier, rarity = def.rarity }
							count += 1
							total += chance
							if chance > bestChance then
								bestChance = chance
							end
						end
					end
				end
			end
		end
		return out, count, bestChance
	end

-- Build the work list: one entry per egg, each carrying the specific
	-- (pet, tier) pairs THAT EGG can drop and that you are still missing.
	--
	-- Per egg, not global, because the behaviour wanted is: stand at one egg
	-- and stay there until everything you want from THAT egg is collected,
	-- then move to the next egg, one at a time. So the plan has to be able to
	-- answer "what is still missing from the egg I am standing at", which a
	-- single global target list cannot.
	--
	-- Each entry also reports the egg's own contents at your selected
	-- rarities/tiers - how many of its pets you already have versus how many
	-- are still missing - so the status line can show what is actually in the
	-- egg rather than just a name.
	local function buildEggPlan(data, wantRarities, tiers)
		local raritySet, tierSet = {}, {}
		for _, r in ipairs(wantRarities or {}) do
			raritySet[r] = true
		end
		for _, n in ipairs(tiers or {}) do
			tierSet[n] = true
		end
		local anyTier = next(tierSet) == nil

		-- which (pet, tier) pairs are we after at all?
		local wanted = {}
		for petName, def in pairs(PetsList) do
			if type(def) == "table" and raritySet[def.rarity] then
				local base = descName(petName)
				for tier = 1, 4 do
					if anyTier or tierSet[tier] then
						if isUnlocked(data, base .. ":" .. tier) then
							wanted[tostring(petName)] = wanted[tostring(petName)] or {}
							local lst = wanted[tostring(petName)]
							lst[#lst + 1] = { pet = petName, tier = tier, rarity = def.rarity }
						end
					end
				end
			end
		end

		local plan = {}
		for eggName, egg in pairs(EggList) do
			if type(egg) == "table" and type(egg.pets) == "table" then
				local missingHere, haveHere, ignored = {}, 0, 0
				for petName, tiersList in pairs(wanted) do
					local chance = egg.pets[petName]
					if type(chance) == "number" then
						-- count what we already have of this egg's relevant pets
						for _, entry in ipairs(tiersList) do
							missingHere[#missingHere + 1] = entry
						end
					end
				end
				-- "collected" side: pets this egg drops that we already have at
				-- any of the tiers we care about
				for petName in pairs(egg.pets) do
					local lst = wanted[tostring(petName)]
					if not lst then
						ignored += 1
					end
				end
				if #missingHere > 0 then
					-- best odds among this egg's own missing pets
					local bestChance, total = 0, 0
					for _, entry in ipairs(missingHere) do
						local c = egg.pets[entry.pet] or 0
						total += c
						if c > bestChance then
							bestChance = c
						end
					end
					plan[#plan + 1] = {
						egg = eggName,
						missing = missingHere,
						count = #missingHere,
						chance = bestChance,
						totalChance = total,
						cost = egg.cost,
						currency = egg.currency,
						ignored = ignored,
					}
				end
			end
		end
		-- Most wanted pets per egg first: finishing an egg completely is the
		-- goal, so start where a single egg can complete the most.
		table.sort(plan, function(a, b)
			if a.count ~= b.count then
				return a.count > b.count
			end
			if a.totalChance ~= b.totalChance then
				return a.totalChance > b.totalChance
			end
			return tostring(a.egg) < tostring(b.egg)
		end)
		return plan
	end

	-- ------------------------------------------------------------------
	-- UI	-- UI
	-- ------------------------------------------------------------------

	local ui = {}

function ui.build(sec, Options, helpers)
		sec:AddParagraph({
			Title = "How it works",
			Content = "Pick rarities and the tiers (variants) you want. Every pet at those rarities whose tiers are not yet in the index becomes a target; the hub opens whichever egg covers the most missing targets, at the normal hatch rate, until they are all unlocked. Shiny is not a separate choice - a normal or shiny drop of the right tier counts, exactly as the game's own index does.",
		})

		-- The two rarity groups are fully independent: rarities AND tiers are
		-- chosen separately for each, so the harder Eternal+ chase can be
		-- aimed at, say, Golden and Toxic only without touching the main list.
		local TIER_VALUES = { "Normal", "Golden", "Toxic", "Galaxy" }

		local rarityDrop = sec:AddDropdown("IndexRarities", {
			Title = "Rarities",
			Description = "Which rarities to chase. Anything not picked is ignored entirely.",
			Values = normalRarities,
			Multi = true,
			Default = {},
		})
		pcall(function()
			Options.IndexRarities = rarityDrop
		end)

		local tierDrop = sec:AddDropdown("IndexTiers", {
			Title = "Variants",
			Description = "Which tiers to chase. Nothing picked = every tier.",
			Values = TIER_VALUES,
			Multi = true,
			Default = {},
		})
		pcall(function()
			Options.IndexTiers = tierDrop
		end)

		local highDrop = sec:AddDropdown("IndexHighRarities", {
			Title = "Eternal and above rarities",
			Description = "The hard ones, kept separate. Pick nothing here to leave them alone.",
			Values = highRarities,
			Multi = true,
			Default = {},
		})
		pcall(function()
			Options.IndexHighRarities = highDrop
		end)

		local highTierDrop = sec:AddDropdown("IndexHighTiers", {
			Title = "Eternal and above variants",
			Description = "Their own tier list, independent of the one above.",
			Values = TIER_VALUES,
			Multi = true,
			Default = {},
		})
		pcall(function()
			Options.IndexHighTiers = highTierDrop
		end)

		local craftToggle = sec:AddToggle("IndexCraft", {
			Title = "Craft wanted pets",
			Description = "If a wanted pet can be made by the pet machines, craft it instead of waiting on luck",
			Default = true,
		})
		pcall(function()
			Options.IndexCraft = craftToggle
		end)

		ui.status = sec:AddParagraph({
			Title = "Index status",
			Content = "Idle",
		})

		-- the toggle and its runner live in the hub so they join the shared
		-- task registry and can be stopped by "Stop everything"
		helpers.bindToggle(
			sec,
			{
				id = "AutoIndex",
				title = "Auto Index",
				desc = "Hatches the best egg for every pet you are missing at your chosen rarities",
				group = "Index",
			},
			"index",
			function(t)
				-- Options MUST be passed through: the runner reads the rarity
				-- and tier dropdowns from it, and bindToggle only hands the
				-- runner a single `t` argument. Omitting it made every tick
				-- die on "attempt to index nil with 'IndexRarities'".
				ui.runner(t, helpers, Options)
			end,
			0.5,
			function(t)
				t.targetEgg = nil
				-- clear the pinned egg so a restart begins from the best one
				t.currentEggName = nil
				t.eggIdx = nil
			end
		)
	end

	-- ------------------------------------------------------------------
	-- runner
	-- ------------------------------------------------------------------
	function ui.runner(t, helpers, Options)
		if (t.cooldown or 0) > os.clock() then
			return
		end
		local data = helpers.getData()
		if not data then
			return
		end

-- Tier labels map back to the tier numbers buildEggPlan expects.
		local TIER_NUM = { Normal = 1, Golden = 2, Toxic = 3, Galaxy = 4 }

		-- Read a Multi dropdown that may hold either shape.
		--
		-- Fluent's own Value is a SET keyed by option NAME. But a dropdown
		-- restored from the JSON backup can arrive as a plain ARRAY, because
		-- optionSnapshot only keeps string keys and JSONEncode then emits an
		-- array - which is how IndexRarities was saved as {"1","2",...,"6"}
		-- and silently selected nothing, since no rarity is named "1".
		-- So accept names, and accept bare numbers as positional indexes into
		-- the dropdown's own Values list.
		local function optionValues(dropdown)
			local ok, v = pcall(function()
				return dropdown and dropdown.Value
			end)
			local list = {}
			if not ok or type(v) ~= "table" then
				return list
			end
			local opts = {}
			pcall(function()
				opts = dropdown.Options or {}
			end)
			for k, val in pairs(v) do
				if val then
					local name = k
					local num = tonumber(k)
					if num and opts[num] then
						name = tostring(opts[num])
					end
					if type(name) == "string" and name ~= "" then
						list[#list + 1] = name
					end
				end
			end
			table.sort(list)
			return list
		end

		-- each rarity group is resolved with ITS OWN tier list
		local function tiersFrom(dropdown)
			local list = optionValues(dropdown)
			local out = {}
			for _, label in ipairs(list) do
				local n = TIER_NUM[label]
				if n then
					out[#out + 1] = n
				end
			end
			return out
		end

		local groups = {}
		-- Each rarity group is paired with ITS OWN tier dropdown. Passing the
		-- rarity dropdown to tiersFrom (as this did) meant no rarity name ever
		-- matched a tier name, so every group silently fell back to "all tiers"
		-- and the tier selection did nothing at all.
		local function collect(rarityDropdown, tierDropdown)
			local list = optionValues(rarityDropdown)
			if #list > 0 then
				groups[#groups + 1] = { list = list, tiers = tiersFrom(tierDropdown) }
			end
		end
		collect(Options.IndexRarities, Options.IndexTiers)
		collect(Options.IndexHighRarities, Options.IndexHighTiers)

		if #groups == 0 then
			t.idle = true
			t.targetEgg = nil
			if ui.status and not t.toldNone then
				t.toldNone = true
				pcall(function()
					ui.status:SetDesc("Pick at least one rarity to chase.")
				end)
			end
			return
		end
		t.toldNone = false

		-- union the two groups' egg plans; an egg reachable by either group counts
		-- once, and its missing list is the union of both.
		local rarityLabel = {}
		local plan, seenEgg = {}, {}
		for _, g in ipairs(groups) do
			local sub = buildEggPlan(data, g.list, g.tiers)
			for _, entry in ipairs(sub) do
				local existing = seenEgg[entry.egg]
				if existing then
					local have = {}
					for _, m in ipairs(existing.missing) do
						have[m.pet .. ":" .. m.tier] = true
					end
					for _, m in ipairs(entry.missing) do
						local k = m.pet .. ":" .. m.tier
						if not have[k] then
							existing.missing[#existing.missing + 1] = m
							have[k] = true
						end
					end
					existing.count = #existing.missing
				else
					seenEgg[entry.egg] = entry
					plan[#plan + 1] = entry
				end
			end
			for _, r in ipairs(g.list) do
				rarityLabel[r] = true
			end
		end
		table.sort(plan, function(a, b)
			if a.count ~= b.count then
				return a.count > b.count
			end
			if a.totalChance ~= b.totalChance then
				return a.totalChance > b.totalChance
			end
			return tostring(a.egg) < tostring(b.egg)
		end)

		local rarityList = {}
		for r in pairs(rarityLabel) do
			rarityList[#rarityList + 1] = r
		end
		table.sort(rarityList)

		-- total still wanted, across every egg
		local totalWanted = 0
		for _, e in ipairs(plan) do
			totalWanted += e.count
		end
		t.missing = totalWanted
		t.eggCount = #plan

		if totalWanted == 0 then
			t.done = true
			t.targetEgg = nil
			t.eggIdx = nil
			if not t.toldDone then
				t.toldDone = true
				helpers.notify("Auto Index", "Everything selected is unlocked.")
			end
			if ui.status then
				pcall(function()
					ui.status:SetDesc(("All done - every %s pet is unlocked."):format(table.concat(rarityList, ", ")))
				end)
			end
			return
		end
		t.done = false
		t.toldDone = false

		-- STAY ON ONE EGG until everything you want from it is collected.
		-- Only move to the next egg once this one reports zero remaining, so
		-- each egg is finished properly before the next is started.
		--
		-- The current egg is pinned BY NAME, not by index: the plan is rebuilt
		-- and re-sorted every pass (counts shrink as pets land, which reorders
		-- it), so an index would drift onto a different egg each tick and never
		-- finish any of them.
		--
		-- The egg's remaining list comes from eggMissingList, computed fresh from
		-- EggList + data.index, NOT from the plan entry's `missing` field. The
		-- plan entries are shared objects the runner also writes to, so reading
		-- back a list it had just overwritten is what made it believe an egg
		-- was empty after a single tick and skip it.
		local eggName = t.currentEggName
		local stillMissing, stillCount, stillChance = {}, 0, 0

		if eggName then
			-- re-derive against the union of both groups' selections
			local mergedList, mergedTiers = {}, {}
			local rarSeen = {}
			for _, g in ipairs(groups) do
				for _, r in ipairs(g.list) do
					rarSeen[r] = true
				end
				for _, n in ipairs(g.tiers) do
					mergedTiers[n] = true
				end
			end
			for r in pairs(rarSeen) do
				mergedList[#mergedList + 1] = r
			end
			table.sort(mergedList)
			local tierList = {}
			for n in pairs(mergedTiers) do
				tierList[#tierList + 1] = n
			end
			table.sort(tierList)
			stillMissing, stillCount, stillChance =
				eggMissingList(data, eggName, mergedList, tierList)
		end

		-- no pin, or this egg is now complete for our selection: move on
		if not eggName or stillCount == 0 then
			if eggName and eggName ~= t.currentEggName then
				t.eggJustFinished = eggName
			end
			t.currentEggName = nil
			t.eggIdx = nil
			-- choose the next egg straight from the plan
			local nextEntry = plan[1]
			if not nextEntry then
				return
			end
			t.currentEggName = nextEntry.egg
			-- recompute for the new egg
			local mergedList, mergedTiers = {}, {}
			local rarSeen = {}
			for _, g in ipairs(groups) do
				for _, r in ipairs(g.list) do
					rarSeen[r] = true
				end
				for _, n in ipairs(g.tiers) do
					mergedTiers[n] = true
				end
			end
			for r in pairs(rarSeen) do
				mergedList[#mergedList + 1] = r
			end
			table.sort(mergedList)
			local tierList = {}
			for n in pairs(mergedTiers) do
				tierList[#tierList + 1] = n
			end
			table.sort(tierList)
			stillMissing, stillCount, stillChance =
				eggMissingList(data, t.currentEggName, mergedList, tierList)
			-- report the egg we just finished
			if eggName then
				t.eggJustFinished = eggName
			end
		end

		if stillCount == 0 then
			-- nothing anywhere left; the total==0 branch above normally catches it
			t.currentEggName = nil
			return
		end

		local idx = 1
		for i, e in ipairs(plan) do
			if e.egg == t.currentEggName then
				idx = i
				break
			end
		end
		t.eggIdx = idx
		t.targetEgg = t.currentEggName
		t.eggMissing = stillCount
		local entry = { egg = t.currentEggName, chance = stillChance }

		-- what this egg actually holds, for the status line
		local raritiesInEgg = {}
		for _, m in ipairs(stillMissing) do
			raritiesInEgg[m.rarity] = true
		end
		local rarList = {}
		for r in pairs(raritiesInEgg) do
			rarList[#rarList + 1] = r
		end
		table.sort(rarList)

		-- craft first if asked: a craftable target never needs luck
		if Options.IndexCraft and Options.IndexCraft.Value then
			local svc = REPO.getService("PetService")
			if svc then
				local crafted = 0
				for _, m in ipairs(stillMissing) do
					if crafted >= 5 then
						break
					end
					if m.tier and m.tier > 1 then
						if helpers.craftOne(m.pet, m.tier) then
							crafted += 1
						end
					end
				end
				if crafted > 0 then
					t.cooldown = os.clock() + 2
					t.crafted = (t.crafted or 0) + crafted
					if ui.status then
						pcall(function()
							ui.status:SetDesc(("Crafting %d wanted from %s - %d left"):format(crafted, tostring(entry.egg), #stillMissing))
						end)
					end
					return
				end
			end
		end

		-- Hatch the CURRENT egg. We do NOT rotate here: entry is the egg we are
		-- standing at and it keeps its remaining list until it is empty, at
		-- which point the block above advances t.eggIdx by one. So each egg is
		-- finished completely before the next one is started, which is the
		-- behaviour asked for.
		if ui.status then
			pcall(function()
				ui.status:SetDesc(
					("Egg %d/%d: %s | %d wanted left here | rarities: %s | best %s%%"):format(
						idx,
						#plan,
						tostring(entry.egg),
						#stillMissing,
						#rarList > 0 and table.concat(rarList, ", ") or "-",
						REPO.suffix(entry.chance * 100)
					)
				)
			end)
		end

		-- hand the hatch to the hub so we get the teleport, the batch size and
		-- the legal interval for free. It returns false when it could not get
		-- us into range, in which case we stay on this egg and retry next tick.
		local opened = helpers.hatchEgg(entry.egg)
		t.cooldown = os.clock() + 0.5
	end

	return ui
end]==]
	if type(src) == "string" and src ~= "" then
		local chunk = loadstring(src)
		if chunk then
			local ok, mod = pcall(chunk)
			if ok and type(mod) == "function" then
				-- the module is a factory: it takes the game modules it needs
				-- and returns the ui object
				local ok2, ui = pcall(mod, {
					RS = ReplicatedStorage,
					Knit = Knit,
					Util = Util,
					PetsList = require(ReplicatedStorage.Shared.List.Pets.Pets),
					RaritiesList = require(ReplicatedStorage.Shared.List.Pets.Rarities),
					EggList = EggList,
					suffix = suffix,
					getService = getService,
				})
				if ok2 and type(ui) == "table" then
					AutoIndex = ui
				else
					rawset(_G, "__RCU_INDEX_ERROR", tostring(ui))
				end
			else
				rawset(_G, "__RCU_INDEX_ERROR", tostring(mod))
			end
		end
	end
end

-- Bridge helpers handed to the index feature so it can reuse the hub's own
-- machinery (teleport, legal interval, currency checks, crafting) instead of
-- duplicating it and drifting out of sync.

-- Open one batch from `egg`, using exactly the same path the Auto Hatch runner
-- uses: teleport into range, take the game's open params (which carry the
-- lucky/global egg id when one is in reach), and fire openEgg at the legal
-- cadence.
function AutoIndex.hatchEgg(egg)
	local data = getData()
	if not data or not EggController or not EggService or not egg or egg == "" then
		return false
	end
	-- currency gate, same as the Auto Hatch runner: never fire into the void
	local okAmt, amount = pcall(function()
		return Util.eggUtils.getAmountFromOpenType(LocalPlayer, data, egg, 2, EggController:getOpenParams())
	end)
	if okAmt then
		local okHas, has = pcall(function()
			return Util.eggUtils.hasEnoughToOpen(data, egg, amount, EggController:getOpenParams())
		end)
		if okHas and not has then
			return false, "Out of currency for " .. tostring(egg)
		end
	end

	-- _currentEgg is only set by the game's proximity scan, and a lucky egg is
	-- RENAMED to the best egg's name, so a match here does not prove we are at
	-- the egg we asked for. teleportToEgg re-anchors and waits for the scan, so
	-- call it whenever the cached name disagrees, and treat failure as "not
	-- ready" rather than hatching a different egg.
	if EggController._currentEgg ~= egg then
		local ok = teleportToEgg({ alive = true }, egg)
		if not ok then
			return false, "Could not reach " .. tostring(egg)
		end
		if EggController._currentEgg ~= egg then
			return false, "Out of range of " .. tostring(egg)
		end
	end

	local params = (EggController:getOpenParams())
	pcall(function()
		EggService.openEgg:Fire(egg, 2, params)
	end)
	return true
end

-- Craft one specific pet by name, if any machine can make it. Used when a
-- target the user wants is craftable - that never needs luck, so it is always
-- the better move. Walks the craft tiers from the top down and calls the same
-- grouped craft path the craft toggles use.

-- Craft one specific pet at `targetTier`, if any machine can make it and we
-- have the inputs. Used when a target the user wants is craftable - that never
-- needs luck, so it is always the better move. targetTier is the tier the
-- index wants, so we consume a stack one tier below it.
function AutoIndex.craftOne(petName, targetTier)
	local svc = petServiceRef()
	if not svc or not petName then
		return false
	end
	local data = getData()
	if not data or not targetTier or targetTier < 2 then
		return false
	end
	if not canAffordCraft(data, targetTier) then
		return false
	end
	-- find an inventory stack of this pet sitting one tier below the target
	for id, entry in pairs(data.inventory and data.inventory.pet or {}) do
		if (entry.ti or 1) == targetTier - 1 then
			local okName, nm = pcall(function()
				local item = Util.itemUtils.getItemFromId(data, id)
				return item and item:getName()
			end)
			if okName and nm and tostring(nm):lower() == tostring(petName):lower() then
				if (entry.am or 0) >= 5 then
					local okItem, item = pcall(function()
						return Util.itemUtils.getItemFromId(data, id)
					end)
					if okItem and item then
						local okC, can = pcall(function()
							return Util.petUtils.canCraftToTier(item, targetTier)
						end)
						if okC and can then
							local ok, res = pcall(function()
								-- craftAll on this one group: spend the whole stack
								return svc:craft({ id }, true, math.huge)
							end)
							return ok and res == "success"
						end
					end
				end
				break
			end
		end
	end
	return false
end

-- Tree models only get a PrimaryPart once a tree-bearing map is actually
-- loaded: standing anywhere else, every tagged "Tree" Folder has
-- PrimaryPart == nil and nothing can be targeted. So resolve the world
-- position through the child Model's parts, not the tagged Folder's pivot.

local function chopRunner(t, zones)
	local data = getData()
	if not data or not TreeController then
		return
	end

	-- Every tree zone lives on its OWN map (Shared.List.Trees gives each a
	-- mapId: kingdom=6, volcano=9, steampunk=14, ...). A tree on any other
	-- map is not loaded, so it has no parts and cannot be chopped - which is
	-- why Chop used to wander between areas without cutting anything. Work
	-- out which map the trees we actually want are on, and travel to it.
	if MapController == nil then
		MapController = getController("MapController")
	end
	-- The zone set actually in force for THIS call. axeFarmRunner passes its
	-- own set (the zones that drop the wood the next axe needs); the Chop
	-- toggle passes nil so we fall back to the dropdown. The map list has to
	-- be built from whichever set won, or Farm Materials would travel to the
	-- map the dropdown names while cutting trees from a different zone.
	if zones == nil then
		zones = selectedSet(Options.ChopZones)
	end

	local wantMaps = {}
	-- selectedSet returns nil when nothing is selected (or only "Any"), so
	-- this loop has to tolerate nil - it used to throw
	-- "invalid argument #1 to 'pairs'" on every tick with an empty dropdown.
	for zone in pairs(zones or {}) do
		local def = TreesList[zone]
		if type(def) == "table" and def.mapId then
			wantMaps[#wantMaps + 1] = { map = def.mapId, zone = zone }
		end
	end
	table.sort(wantMaps, function(a, b)
		return a.map < b.map
	end)
	if #wantMaps == 0 then
		wantMaps[1] = { map = LiveCounts.CHOP_MAP_ID, zone = nil }
	end

	if MapController then
		-- remember which map we last switched to so we rotate rather than
		-- bouncing between two zones forever
		if t.chopMapIdx and wantMaps[t.chopMapIdx] then
			t.chopMapIdx = t.chopMapIdx
		else
			t.chopMapIdx = 1
		end
		local entry = wantMaps[t.chopMapIdx]
		local okMap, onMap = pcall(function()
			return MapController._currentMapId == entry.map
		end)
		if okMap and not onMap then
			-- drop the old anchor: it lives on the map we just left
			t.tpTree = nil
			t.tpTreePos = nil
			t.idleTime = 0
			pcall(function()
				MapController:setCurrentMap(entry.map)
			end)
			return
		end
	end

	if not data.isAxeEquipped then
		local okAxe = equipAxe()
		if not okAxe and not t.toldNoAxe then
			t.toldNoAxe = true
			notify("Auto Chop", "No axe owned - chop wood and buy one first.")
		end
		return
	end
	t.toldNoAxe = false
	local hrp = Functions.getHRP(LocalPlayer)
	if not hrp then
		return
	end
	-- zones was resolved to the effective set at the top of this function
	local tree = nil
	local cur = t.tpTree
	if cur and cur:IsDescendantOf(workspace) then
		local g = cur:GetAttribute("groupId")
		local tid = cur:GetAttribute("treeId")
		local rec = g and tid and data.trees[g] and data.trees[g][tid]
		if rec and (rec.hp or 0) > 0 and zones[g] then
			tree = cur
		end
	end
	if not tree then
		tree = nearestTree(data, hrp.Position, zones)
		-- No fallback to "all zones" here. Zones you did not pick are zones you
		-- did not ask for: falling back to every area is what made Chop wander
		-- off and target trees you had explicitly excluded.
	end
	if not tree then
		t.idle = (t.idle or 0) + 1
		if t.idle == 1 then
			pcall(function()
				TreeController:cancelAutoDamageTree()
			end)
		end
		-- this map is cut out: move on to the next zone the player picked
		-- instead of idling here forever
		if t.idle >= 3 and MapController and #wantMaps > 1 then
			t.chopMapIdx = ((t.chopMapIdx or 1) % #wantMaps) + 1
			t.idle = 0
			t.idleTime = 0
			t.tpTree = nil
			t.tpTreePos = nil
			pcall(function()
				MapController:setCurrentMap(wantMaps[t.chopMapIdx].map)
			end)
			return
		end
		if (t.idleTime or 0) + 30 < os.clock() then
			t.idleTime = os.clock()
			notify("Auto Chop", "All trees down here - waiting for respawns")
		end
		return
	end
	t.idle = 0
	local model, pp = treeWorldPos(tree)
	local pos3 = pp and pp.Position or nil
	if not pos3 then
		-- model has no usable part at all; fall back to its pivot
		local okP, pv = pcall(function()
			return model and model:GetPivot().Position
		end)
		pos3 = okP and pv or nil
		local okC, look = pcall(function()
			return model and model:GetPivot().LookVector
		end)
		pos3 = pos3
		pp = { Position = pos3, CFrame = okC and CFrame.lookAt(pos3, pos3 + (look or Vector3.new(0, 0, -1))) or CFrame.new(pos3) }
	end
	if not pos3 then
		return
	end

	local pos = hrp.Position
	local delta = pos3 - pos
	local dir = delta.Magnitude > 0.001 and delta.Unit or (pp.CFrame and pp.CFrame.LookVector or Vector3.new(0, 0, -1))
	local want = pos3 - dir * 5

	-- groundStand only raycasts straight DOWN, so it happily returns a ledge or
	-- rooftop 80 studs from the tree instead of the ground beside it. Chop
	-- must actually be within the game's 6-stud reach, so take the candidate
	-- only if it lands near the tree, and fall back to the tree's own base Y.
	local target = groundStand(want.X, want.Z, modelBaseY(model), model, hrp)
	if (Vector3.new(target.X, pos3.Y, target.Z) - pos3).Magnitude > 12 then
		local fallback = pos3 - dir * 5
		target = Vector3.new(fallback.X, (modelBaseY(model) or fallback.Y) + standLift(hrp), fallback.Z)
	end

	-- One teleport per new tree, and re-snap only if we have been pushed off
	-- our spot (knockback, or the target moved under us). This is what keeps it
	-- to a single jump rather than a teleport every tick.
	if tree ~= t.tpTree then
		t.tpTree = tree
		t.tpTreePos = target
	else
		local drift = (hrp.Position - t.tpTreePos).Magnitude
		if drift > 12 then
			t.tpTreePos = target
		else
			target = nil
		end
	end

	if target then
		hrp.CFrame = CFrame.lookAt(target, Vector3.new(pos3.X, target.Y, pos3.Z))
		pcall(function()
			hrp.AssemblyLinearVelocity = Vector3.zero
		end)
	end

	pcall(function()
		TreeController:moveToTree(tree)
	end)
end

local function nextAxeName(data)
	local _, idx = currentAxeIndex(data)
	if not idx then
		return nil
	end
	for k, v in pairs(ExclusiveDir) do
		local nm = tostring(k)
		if v.index == idx + 1 and nm:lower():find("axe") and not nm:lower():find("pickaxe") then
			return k
		end
	end
	return nil
end

-- What this should farm, given the account's situation.
--
-- The natural "next axe" is nothing when you already hold the top axe (your
-- sakuraAxe is index 15, the highest in the list). So there are two sensible
-- targets and we pick the first that applies:
--   1. the next axe up, from Shared.List.Axes[axe].required, minus what we
--      already hold - the normal case while you are climbing
--   2. otherwise fall back to the best axe that is NOT yet owned, which is
--      what makes this useful on a maxed account: it keeps farming the
--      materials for the axes you are still missing.
-- Only items that some tree zone actually drops are considered, so the
-- runner never aims at a zone that cannot produce the wood.
local function axeFarmTargets(data)
	local function collect(name)
		local def = name and AxesList[name]
		if type(def) ~= "table" or type(def.required) ~= "table" then
			return nil
		end
		local items, zones = {}, {}
		for _, req in pairs(def.required) do
			local rn = req:getName()
			local have = itemAmount(data, rn)
			if req:getAmount() > (have or 0) and WOOD_ZONES[rn] then
				items[rn] = req:getAmount() - (have or 0)
				for _, z in ipairs(WOOD_ZONES[rn]) do
					zones[z] = true
				end
			end
		end
		if next(zones) == nil then
			return nil
		end
		return { name = name, items = items, zones = zones }
	end

	-- 1) the axe immediately above the one we hold
	local _, curIdx = currentAxeIndex(data)
	local nextName
	for k, v in pairs(ExclusiveDir) do
		local nm = tostring(k)
		if v.index == (curIdx or 0) + 1 and nm:lower():find("axe") and not nm:lower():find("pickaxe") then
			nextName = nm
		end
	end
	local got = collect(nextName)
	if got then
		return got
	end

	-- 2) maxed on upgrades: farm toward the best axe we do not own yet.
	-- Ownership has to be read through itemUtils, NOT the raw `am` field: an
	-- axe you actually hold is stored with no `am` at all (the row's amount is
	-- implied by getItemFromId returning it), so testing `am > 0` reports every
	-- axe you own as unowned and the runner then farms a finished axe's wood
	-- forever. Verified: sakuraAxe had am=nil but getAmount()=1.
	local function ownsAxe(nm)
		for id, e in pairs(data.inventory and data.inventory.exclusive or {}) do
			if tostring(e.nm) == nm then
				local ok, item = pcall(function()
					return Util.itemUtils.getItemFromId(data, id)
				end)
				if ok and item then
					local amt
					pcall(function()
						amt = item:getAmount()
					end)
					if (amt or 0) > 0 then
						return true
					end
				end
				-- fall back to the raw field when the row cannot be resolved
				if (e.am or 0) > 0 then
					return true
				end
			end
		end
		return false
	end

	local bestIdx, bestName = -1, nil
	for k, v in pairs(ExclusiveDir) do
		local nm = tostring(k)
		if type(v.index) == "number" and nm:lower():find("axe") and not nm:lower():find("pickaxe") then
			if not ownsAxe(nm) and v.index > bestIdx then
				bestIdx, bestName = v.index, nm
			end
		end
	end
	return collect(bestName)
end

local function axeFarmRunner(t)
	local data = getData()
	if not data or not TreeController then
		return
	end
	local plan = axeFarmTargets(data)
	if not plan then
		return
	end
	-- remember the plan so the status line can show what we are after
	if t.farmTarget ~= plan.name then
		t.farmTarget = plan.name
	end
	-- chopRunner resolves the map from the zones set it is handed, so the
	-- material zones drive the travel here too, not the dropdown
	chopRunner(t, plan.zones)
end

local function axeUpgradeRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local data = getData()
	if not data or not AxeService then
		return
	end
	local _, idx = currentAxeIndex(data)
	if not idx then
		return
	end
	local nextName = nil
	for k, v in pairs(ExclusiveDir) do
		local nm = tostring(k)
		if v.index == idx + 1 and nm:lower():find("axe") and not nm:lower():find("pickaxe") then
			nextName = k
		end
	end
	if not nextName then
		return
	end
	local def = AxesList[nextName]
	if not def or not def.required then
		return
	end
	for _, req in pairs(def.required) do
		if itemAmount(data, req:getName()) < req:getAmount() then
			return
		end
	end
	local ok, res = pcall(function()
		return AxeService:upgradeAxe()
	end)
	if ok and res == "success" then
		t.cooldown = os.clock() + 2
		notify("Axe", "Upgraded to " .. tostring(nextAxeLabel(nextName)))
	end
end

local function rewardRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local data = getData()
	if not data or not RewardService then
		return
	end
	local claimed = 0
	for id, def in pairs(AchievementsList) do
		local idx = 1
		for k in pairs(data.claimedAchievements or {}) do
			if tostring(k):find(id, 1, true) then
				idx = idx + 1
			end
		end
		local tier = def.list and def.list[idx]
		if tier then
			local okV, val = pcall(function()
				return def.getValue(data)
			end)
			if okV and val and val >= tier.amount then
				local ok, res = pcall(function()
					return RewardService:claimAchievement(id)
				end)
				if ok and res == "success" then
					claimed += 1
				end
			end
		end
	end
	local cd = 1
	pcall(function()
		cd = Values.playtimeRewardCooldown(LocalPlayer, data)
	end)
	for i, rew in ipairs(PlaytimeRewards) do
		if not table.find(data.claimedPlaytimeRewards or {}, i) then
			if rew.required * (1 - cd) - (data.playtimeRewardTimer or 0) <= 0 then
				local ok, res = pcall(function()
					return RewardService:claimPlaytimeReward(i)
				end)
				if ok and res == "success" then
					claimed += 1
				end
			end
		end
	end
	if (workspace:GetServerTimeNow() - (data.dayReset or 0)) >= 86400 then
		local ok, res = pcall(function()
			return RewardService:claimDailyReward()
		end)
		if ok and res == "success" then
			claimed += 1
		end
	end
	if claimed > 0 then
		t.cooldown = os.clock() + 3
		notify("Rewards", "Claimed " .. claimed .. " reward" .. (claimed > 1 and "s" or ""))
	end
end

local function chestRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local data = getData()
	if not data or not RewardService then
		return
	end
	if ChestController and ChestController.checkAllChests then
		pcall(function()
			ChestController:checkAllChests()
		end)
		pcall(function()
			ChestController:checkAllMiniChests()
		end)
	end
	local bonus = 0
	pcall(function()
		bonus = Values.chestCooldown(LocalPlayer, data) or 0
	end)
	local now = workspace:GetServerTimeNow()
	local claimed = 0
	for id, def in pairs(ChestsList) do
		if type(def) == "table" and def.cooldown then
			local sub = (def.chestCooldownUpgrades == false) and 0 or bonus
			if now - ((data.chests and data.chests[id]) or 0) >= def.cooldown - sub then
				local ok, res = pcall(function()
					return RewardService:claimChest(id, true)
				end)
				if ok and res == "success" then
					claimed += 1
				end
			end
		end
	end
	for _, j in ipairs(CollectionService:GetTagged("MiniChest")) do
		if j:IsDescendantOf(workspace) and not j:GetAttribute("isAnimating") then
			local mid = j:GetAttribute("miniChestId")
			local mname = j:GetAttribute("miniChestName")
			if mid and mname then
				local last = (data.miniChests or {})[mname]
				if type(last) == "boolean" or not last then
					last = 0
				end
				if workspace:GetServerTimeNow() - last >= 86400 then
					local ok, res = pcall(function()
						return RewardService:claimMiniChest(mid, mname, true)
					end)
					if ok and res == "success" then
						claimed += 1
					end
				end
			end
		end
	end
	if claimed > 0 then
		t.cooldown = os.clock() + 2
		notify("Chests", "Claimed " .. claimed .. " chest" .. (claimed > 1 and "s" or ""))
	end
end

local function auraRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local data = getData()
	if not data or not AuraService then
		return
	end
	-- Multi-select: try each picked dice in turn and roll with the first one
	-- we can still afford, so running one dry rolls on to the next instead of
	-- stopping the whole toggle.
	local picked = selectedSet(Options.AuraDice)
	local order = {}
	if picked then
		for name in pairs(picked) do
			table.insert(order, diceValueName(name))
		end
		table.sort(order)
	end
	if Options.AuraAutoSecret and Options.AuraAutoSecret.Value then
		table.insert(order, "secretAuraDice")
	end
	if #order == 0 then
		return
	end

	local dice
	for _, name in ipairs(order) do
		local item = Util.itemUtils.getItemFromName(data, name)
		if item and item:getAmount() > 0 then
			dice = name
			break
		end
	end
	if not dice then
		if not t.toldEmpty then
			t.toldEmpty = true
			notify("Auras", "Out of every selected dice, stopping.")
			if Options.AutoRollAuras then
				Options.AutoRollAuras:SetValue(false)
			end
		end
		return
	end
	t.toldEmpty = false

	local ok, status = pcall(function()
		return AuraService:roll(dice, false)
	end)
	if ok and (status == "notEnoughDice" or status == "notEnoughCurrency") then
		-- this one is dry; the next pass will move on to the next pick
		t.cooldown = os.clock() + 0.4
	elseif not ok then
		t.cooldown = os.clock() + 1
	end
end

local function farmRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local data = getData()
	if not data or not FarmService then
		return
	end
	local gems = data.gems or 0
	local acted = 0
	for id, def in pairs(FarmsList) do
		if type(def) == "table" and not def.isNotFarm then
			local owned = data.farms and data.farms[id]
			if not owned then
				if gems >= (def.price or math.huge) then
					local ok, res = pcall(function()
						return FarmService:buy(id)
					end)
					if ok and res == "success" then
						acted += 1
					end
				end
			elseif type(def.upgrades) == "table" then
				local stage = owned.stage or 0
				local up = def.upgrades[stage + 1]
				if up and up.price and gems >= up.price then
					local ok, res = pcall(function()
						return FarmService:upgrade(id)
					end)
					if ok and res == "success" then
						acted += 1
					end
				end
			end
		end
	end
	if acted > 0 then
		t.cooldown = os.clock() + 1
		notify("Farms", "Farms: " .. acted .. " action" .. (acted > 1 and "s" or ""))
	end
end

-- ------------------------------------------------------------------
-- auto clicker, orbs, mining, circus
-- ------------------------------------------------------------------
local function clickRunner(t)
	if not ClickService then
		return
	end
	pcall(function()
		ClickService.click:Fire()
	end)
end

local function orbRunner(t)
	if not OrbController then
		return
	end
	local st = OrbController._orbStorage
	if not st then
		return
	end
	local names = {}
	for k in pairs(st) do
		names[#names + 1] = k
	end
	if #names > 0 then
		pcall(function()
			OrbController:collectOrbs(names)
		end)
	end
end

-- The ore type each world instance actually holds comes from the spawner:
-- Assets.Ores[data.ores[room][id].oreId] is what gets cloned and tagged "Ore",
-- so the ore's own Model name is the type name (cobaltOre, diamondOre, ...).
local function oreTypeOf(ore)
	return ore.Name
end

-- A Multi dropdown's .Value is a SET ({option = true}), not an array - Fluent
-- does l.Value[option] = true when a row is clicked. So iterate with pairs,
-- never ipairs, or the selection silently reads as empty.
-- An empty set (or only "Any") means no filter.

local function mineWanted()
	return selectedSet(Options.MineOre)
end

local function mineRoom()
	return selectedSet(Options.MineRoom)
end

-- Nearest live ore, honouring the optional ore-type and room filters.
-- nil filter = any.
local function nearestOre(data, pos)
	local wantOre = mineWanted()
	local wantRoom = mineRoom()
	local best, bestD = nil, math.huge
	for _, ore in ipairs(CollectionService:GetTagged("Ore")) do
		if ore:IsDescendantOf(workspace) and ore.PrimaryPart then
			local rid = ore:GetAttribute("roomId")
			local oid = ore:GetAttribute("id")
			local entry = rid and data.ores and data.ores[rid] and data.ores[rid][oid]
			local okOre = (not wantOre) or wantOre[oreTypeOf(ore)] == true
			local okRoom = (not wantRoom) or wantRoom[tostring(rid)] == true
			if entry and okOre and okRoom then
				local d = (ore.PrimaryPart.Position - pos).Magnitude
				if d < bestD then
					best, bestD = ore, d
				end
			end
		end
	end
	return best, bestD
end

-- ------------------------------------------------------------------
-- Auto Seed Farm (Sky Garden, map 31)
--
-- Mirrors the game's OWN gardener loop (GardenController:startGardenerLoop)
-- because that is the contract the server enforces:
--   GardenService:plantSeed(seedName, gardenId)  -- plant into an empty garden
--   GardenService:claimPlant(gardenId, skip)     -- collect a grown one
--   data.gardenPlants[gardenId] = { plantName, plantedAt }
--   ready when  plantedAt + Plants[name].duration * (1 - mult) <= now
-- where mult = Util.upgradeUtils.getAllUpgradeMultipliers(data, "plantGrowingTime").
--
-- The stock loop is gated on data.gardenerSlots being non-empty ("if
-- getAmountInTable(v1.gardenerSlots) ~= 0") and on this account gardenerSlots
-- is empty, so the game's own auto-planter never starts - that is why nothing
-- in-game does this. We call the same two methods directly instead, so the
-- slots do not matter.
--
-- Gardens are 1..6. Each tick: harvest whatever is ready, then plant the best
-- seed we own into whatever is empty.
--
-- One table, so this costs a single register - this file sits at Luau's
-- 200-register cap and anything more stops the whole hub loading.
local Garden = {}

-- Seed tier order, best first. Seeds are named by tier, so "prioritises the
-- best seed" means planting the highest tier we actually hold one of. Verified
-- on this account: basicSeed 713, epicSeed 326, insaneSeed 235, chaosSeed 0.
Garden.SEED_TIERS = { "chaosSeed", "insaneSeed", "epicSeed", "basicSeed" }
Garden.plants = nil
Garden.service = nil

function Garden.bestSeed(data)
	local mapItems = data.inventory and data.inventory.mapItem
	if type(mapItems) ~= "table" then
		return nil
	end
	local have = {}
	for _, e in pairs(mapItems) do
		if type(e) == "table" and e.nm then
			have[tostring(e.nm)] = e.am or 0
		end
	end
	for _, name in ipairs(Garden.SEED_TIERS) do
		if (have[name] or 0) > 0 then
			return name, have[name]
		end
	end
	return nil
end

function Garden.isReady(data, entry)
	if type(entry) ~= "table" or not entry.plantName then
		return false
	end
	local def = Garden.plants[entry.plantName]
	if not def then
		return false
	end
	local mult = 0
	pcall(function()
		mult = Util.upgradeUtils.getAllUpgradeMultipliers(data, "plantGrowingTime")
	end)
	local readyAt = (entry.plantedAt or 0) + def.duration * (1 - mult)
	return readyAt <= workspace:GetServerTimeNow()
end

function Garden.run(t)
	local data = getData()
	if not data then
		return
	end
	if not Garden.plants then
		local ok, plants = pcall(function()
			return require(ReplicatedStorage.Shared.List.Skylands.Plants)
		end)
		if not ok then
			return
		end
		Garden.plants = plants
	end
	local svc = Garden.service or getService("GardenService")
	Garden.service = svc
	if not svc or not svc.plantSeed or not svc.claimPlant then
		return
	end

	local seed, seedCount = Garden.bestSeed(data)
	t.seed = seed
	t.seedCount = seedCount

	local harvested, planted, growing = 0, 0, 0
	for id = 1, 6 do
		local entry = data.gardenPlants and data.gardenPlants[tostring(id)]
		if entry then
			if Garden.isReady(data, entry) then
				local ok, res = pcall(function()
					return svc:claimPlant(id, true)
				end)
				if ok and res == "success" then
					harvested += 1
				end
			else
				growing += 1
			end
		elseif seed then
			local ok, res = pcall(function()
				return svc:plantSeed(seed, id)
			end)
			if ok and res == "success" then
				planted += 1
			end
		end
	end

	t.harvested = harvested
	t.planted = planted
	t.growing = growing
	if Garden.status then
		pcall(function()
			Garden.status:SetDesc(
				("Best seed: %s (%s held) | planted %d | growing %d | harvested %d"):format(
					tostring(seed or "none"),
					tostring(seedCount or 0),
					planted,
					growing,
					harvested
				)
			)
		end)
	end
end

local function mineRunner(t)
	local data = getData()
	if not data or not OreController then
		return
	end
	if not data.isPickaxeEquipped then
		local okPick = equipPickaxe()
		if not okPick and not t.toldNoPick then
			t.toldNoPick = true
			notify("Auto Mine", "No pickaxe owned - buy one first.")
		end
		return
	end
	t.toldNoPick = false
	local hrp = Functions.getHRP(LocalPlayer)
	if not hrp then
		return
	end
	-- ores only exist inside the mine map, so travel there first or there is
	-- nothing to target and the runner silently does nothing
	if MapController == nil then
		MapController = getController("MapController")
	end
	if MapController then
		local okMap, onMap = pcall(function()
			return MapController._currentMapId == MINE_MAP_ID
		end)
		if okMap and not onMap then
			pcall(function()
				MapController:setCurrentMap(MINE_MAP_ID)
			end)
			return
		end
	end

	local ore = nearestOre(data, hrp.Position)
	if not ore then
		return
	end
	if OreController._currentOre then
		if OreController._currentOre == ore then
			return
		end
		pcall(function()
			OreController:cancelAutoDamageOre()
		end)
	end
	OreController._selectedOre = nil
	local pp = ore.PrimaryPart
	local dir = pp.Position - hrp.Position
	local d = dir.Magnitude
	if d > 0.001 then
		dir = dir:Unit()
	else
		dir = pp.CFrame.LookVector
	end
	local radius = ore:GetAttribute("radius") or 7
	local target = pp.Position - dir * radius - Vector3.new(0, pp.Size.Y / 2, 0) + Vector3.new(0, hrp.Size.Y, 0)
	if (target - hrp.Position).Magnitude > 0.5 then
		hrp.CFrame = CFrame.lookAt(target, pp.Position)
		pcall(function()
			hrp.AssemblyLinearVelocity = Vector3.zero
		end)
	end
	pcall(function()
		if OreController:isStrongEnough(ore) then
			OreController:moveToOre(ore)
			OreController:updateOreHealth()
		end
	end)
end

local localTAP_SKIN_SERVICE = TapSkinService
local function tapSkinService()
	if localTAP_SKIN_SERVICE then
		return localTAP_SKIN_SERVICE
	end
	local s = getService("TapSkinService")
	localTAP_SKIN_SERVICE = s
	return s
end

-- how many tap orbs of a kind we hold
local function tapOrbCount(data, orbName)
	local ok, item = pcall(function()
		return Util.itemUtils.getItemFromNameAndClass(data, orbName, "tapOrb")
	end)
	if not ok or not item then
		return 0
	end
	local ok2, amt = pcall(function()
		return item:getAmount()
	end)
	return (ok2 and amt) or 0
end

-- TapSkinService:openTapOrb(orb) is a real round-trip to the server and it is
-- hard-debounced: measured on this account it accepts exactly one roll every
-- ~2.05s and answers every other call with the string "Debounce". So there is
-- no point firing faster - we track the observed cadence and let a rejected
-- call push the next attempt out instead of burning it.
local function tapSkinRunner(t)
	local svc = tapSkinService()
	if not svc then
		return
	end
	local data = getData()
	if not data then
		return
	end
	-- Multi-select: use the first picked orb we still have, so running one
	-- out rolls on to the next rather than ending the toggle.
	local order = {}
	local picked = selectedSet(Options.TapOrbSelect)
	if picked then
		for label in pairs(picked) do
			-- dropdown values carry the "name  (count)" suffix now
			table.insert(order, diceValueName(label))
		end
		table.sort(order)
	end
	if #order == 0 then
		return
	end

	local orb
	for _, name in ipairs(order) do
		if tapOrbCount(data, name) > 0 then
			orb = name
			break
		end
	end
	if not orb then
		if not t.toldEmpty then
			t.toldEmpty = true
			notify("Tap Skins", "Out of every selected orb, stopping.")
			if Options.AutoRollTapSkins then
				Options.AutoRollTapSkins:SetValue(false)
			end
		end
		return
	end
	if t.toldEmpty then
		t.toldEmpty = false
	end
	if (t.cooldown or 0) > os.clock() then
		return
	end

	local ok, res = pcall(function()
		return svc:openTapOrb(orb)
	end)
	if ok and res == true then
		t.rolled = (t.rolled or 0) + 1
		t.debounce = 2.05
		t.cooldown = os.clock() + t.debounce
		if t.rolled % 25 == 1 then
			notify("Tap Skins", "Rolled " .. t.rolled .. " " .. tostring(orb))
		end
	elseif ok and res == "Debounce" then
		-- back off to just past the server's window instead of retrying into it
		t.cooldown = os.clock() + 0.25
	else
		t.cooldown = os.clock() + 2
	end
end

local function tapSkinStop(t)
	if t then
		t.rolled = nil
		t.cooldown = nil
	end
end

-- ------------------------------------------------------------------
-- Circus minigame
--
-- The old runner only flipped CircusController:setIsAutoPlaying(true), which
-- is just a flag the controller reads INSIDE playMinigame's loop. Nothing ever
-- called playMinigame, so the toggle did nothing at all.
--
-- The real contract (CircusController, verified):
--   CircusController:setGamemode(mode)   -- "normal" | "extra" | "ultra"
--   CircusController:setIsAutoPlaying(true)
--   CircusController:playMinigame(self, count)  -- count 1 = once, 2 = loop
-- Inside that loop the controller re-checks tickets
-- (u88[mode].price: normal 1, extra 25, ultra 100) and stops on its own when
-- you run out, and it only keeps going while isAutoPlaying() is true.
--
-- "Auto click the luck": the game spawns 10 shrinking circles and auto-clicks
-- each one with probability Values.circusMinigameLuckAutoClick. We let the
-- controller run its own loop and additionally drive every circle it spawns,
-- so no circle is left unclicked.
--
-- One table, for the same register reason as Garden.
-- ------------------------------------------------------------------
-- Hatch webhook
--
-- Watches the pet inventory for anything NEW and, when a new pet's rarity is
-- one you selected, POSTs a message to your own Discord webhook.
--
-- Detecting a hatch by diffing inventory is the only route here: the hatch
-- result comes back on the server and normally arrives via the reveal
-- animation, which "Remove hatch animation" deliberately skips. So we
-- fingerprint every pet descriptor, and any descriptor that appears that was
-- not there last tick is a hatch we just got.
--
-- One table, for the register cap. Nothing leaves the machine except the
-- pet name, its rarity and your display name, and only to the URL you type.
-- ------------------------------------------------------------------
local HatchHook = {}
HatchHook.PetsList = nil
HatchHook.seen = nil
HatchHook.cooldown = 0

HatchHook.RARITIES = {
	"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical",
	"Eternal", "Secret", "Divine", "Mysterious", "Exclusive", "Supreme", "Ultimate",
}

-- Helpers live as fields on HatchHook rather than as separate top-level
-- locals: this file sits right on Luau's 200-register ceiling, and every
-- extra top-level local here stops the whole script from compiling.
-- Every post attempt is recorded, success or failure, so "it did not work" can
-- be answered with what actually happened instead of another guess. Reads the
-- HTTP status that `request` gives back; the previous version discarded it.
function HatchHook.post(url, body)
	local rec = { at = os.time(), body = body }
	HatchHook.log[#HatchHook.log + 1] = rec
	if #HatchHook.log > 12 then
		table.remove(HatchHook.log, 1)
	end
	local ok, res = pcall(function()
		return http_request({
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
	end)
	if not ok then
		rec.result = "threw: " .. tostring(res)
		return
	end
	if type(res) ~= "table" then
		rec.result = "non-table: " .. typeof(res)
		return
	end
	rec.status = tostring(res.StatusCode)
	local b = res.Body
	rec.body = (type(b) == "string" and b ~= "") and b:sub(1, 200) or nil
end

-- How many of each pet we hold, keyed by name+tier.
--
-- NOT keyed by inventory id. The DataController replaces the data table on
-- every server push, which regenerates every pet's id: polling the same
-- account showed the count oscillating 234 -> 233 -> 235 -> 234 -> 236 with
-- every id "new" each tick, because the ids genuinely had all changed. Keying
-- on id therefore reported the whole inventory as fresh on every single poll.
--
-- name+tier survives a data swap, and a count going UP is unambiguously a pet
-- you did not have a moment ago. Duplicates are counted properly, so hatching
-- three of the same pet reports three.
function HatchHook.snapshot(data)
	local map = {}
	if not HatchHook.PetsList then
		local ok, pets = pcall(function()
			return require(ReplicatedStorage.Shared.List.Pets.Pets)
		end)
		if not ok then
			return map
		end
		HatchHook.PetsList = pets
	end
	-- tier index -> variant name. `ti` on a pet entry is this index.
	if not HatchHook.TIERS then
		local ok, tiers = pcall(function()
			return require(ReplicatedStorage.Shared.List.Pets.Tiers)
		end)
		if ok and type(tiers) == "table" then
			HatchHook.TIERS = {}
			for i, t in pairs(tiers) do
				if type(t) == "table" and t.name then
					HatchHook.TIERS[tonumber(i) or 1] = tostring(t.name)
				end
			end
		end
	end
	local petInv = data.inventory and data.inventory.pet
	if type(petInv) ~= "table" then
		return map
	end
	for _, item in pairs(petInv) do
		-- sl = {nr = 100937, un = "BrightShadow60"} marks this pet as SOLD on to
		-- another player. It is no longer yours, so it is excluded completely:
		-- its count moving is market churn and must never read as a hatch.
		if type(item) == "table" and item.cl == "pet" and item.nm and item.sl == nil then
			-- am = how many copies of this exact pet are held; entries without
			-- it are single copies. This is why duplicates were invisible before:
			-- three of the same pet are ONE entry with am = 3, not three rows.
			local am = tonumber(item.am) or 1

			-- Variant comes from the TIER, not the name.
			-- Shared.List.Pets.Tiers maps: 1 Normal, 2 Golden, 3 Toxic,
			-- 4 Galaxy, 5 Rainbow. `ti` on the entry IS that tier index, so a
			-- Toxic Leaf Duck has ti = 3. Reading the name instead would miss
			-- every variant, since the pet is still called just "Leaf Duck".
			-- Shiny is the separate `sh` flag and combines with any tier.
			local variant = nil
			local tierName = HatchHook.TIERS and HatchHook.TIERS[tonumber(item.ti) or 1]
			if tierName and tierName ~= "Normal" then
				variant = tierName
			end
			if item.sh then
				variant = variant and (variant .. " Shiny") or "Shiny"
			end

			local nm = tostring(item.nm)
			local key = table.concat({
				nm,
				tostring(item.ti),
				variant or "-",
			}, "|")
			map[key] = { n = am, name = nm, variant = variant, raw = item }
		end
	end
	return map
end

-- 1.23Q style. Roblox's own large-number suffix set, in order.
HatchHook.UNITS = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

function HatchHook.fmt(n)
	local v = tonumber(n) or 0
	local sign = v < 0 and "-" or ""
	v = math.abs(v)
	if v < 1000 then
		-- under a thousand: no suffix, and trim a pointless .0
		if v == math.floor(v) then
			return sign .. tostring(v)
		end
		return sign .. string.format("%.2f", v)
	end
	local i = 1
	while v >= 1000 and i < #HatchHook.UNITS do
		v /= 1000
		i += 1
	end
	return sign .. string.format("%.2f%s", v, HatchHook.UNITS[i - 1])
end

-- rbxassetid:// will not render in a Discord embed, so it is converted to a
-- thumbnails.roblox.com URL, which is a plain https image Discord can show.
function HatchHook.image(name)
	local def = HatchHook.PetsList and HatchHook.PetsList[tostring(name)]
	local imgs = def and def.images
	if type(imgs) ~= "table" then
		return nil
	end
	for _, v in ipairs(imgs) do
		local id = tostring(v):match("rbxassetid://(%d+)")
		if id then
			return ("https://thumbnails.roblox.com/v1/assets?assetIds=%s&size=420x420&format=Png&isCircular=false"):format(id)
		end
	end
	return nil
end

-- Embed colour per rarity, so a Mythical ping looks different from a Common.
HatchHook.COLORS = {
	Common = 0x9E9E9E, Uncommon = 0x4CAF50, Rare = 0x2196F3, Epic = 0x9C27B0,
	Legendary = 0xFF9800, Mythical = 0xE91E63, Eternal = 0x00BCD4,
	Secret = 0xFFEB3B, Divine = 0xFFFFFF, Mysterious = 0x673AB7,
	Exclusive = 0x795548, Supreme = 0xFFD700, Ultimate = 0xFF0000,
}

-- Pull the stat block for one pet name, shared by the diff and the test button.
function HatchHook.info(name, data)
	local def = HatchHook.PetsList and HatchHook.PetsList[tostring(name)]
	if not def then
		return { name = tostring(name), rarity = "?", clicks = 0, acorns = 0 }
	end
	-- acorns: the game's own accessor, not a guess at the shape. A pet only has
	-- acorns if getSpecialMultiplierName() says so - many return nil and have
	-- no acorn stat at all, which is why the field is only added when non-zero.
	local acorns = 0
	pcall(function()
		local pet = Util.itemUtils.createItemFromData(def.raw)
		if pet then
			local n = pet:getSpecialMultiplierName()
			if n == "acorns" then
				acorns = tonumber(pet:getSpecialMultiplierAmount()) or 0
			end
		end
	end)
	if acorns == 0 then
		local sm = def.specialMultiplier
		if type(sm) == "table" then
			acorns = tonumber(sm.amount) or 0
		end
	end
	-- clicks: getMultiplier() is the real click power, which agrees with the
	-- static multiplier field but comes from the game's own accessor.
	local clicks = tonumber(def.multiplier) or 0
	pcall(function()
		local pet = Util.itemUtils.createItemFromData(def.raw)
		if pet then
			clicks = tonumber(pet:getMultiplier()) or clicks
		end
	end)
	return {
		name = tostring(name),
		rarity = tostring(def.rarity),
		clicks = clicks,
		acorns = acorns,
		image = HatchHook.image(name),
	}
end

function HatchHook.line(info)
	local s = ("**%s** `%s`"):format(info.rarity, info.name)
	s ..= ("\n**Clicks:** %s"):format(HatchHook.fmt(info.clicks))
	if info.acorns and info.acorns > 0 then
		s ..= ("\n**Acorns:** %s"):format(HatchHook.fmt(info.acorns))
	end
	return s
end

-- A full Discord embed per pet: colour keyed to rarity, the pet's own image
-- pulled from the Roblox thumbnail CDN, and the stats as fields.
function HatchHook.embed(info, titleOverride)
	local e = {
		title = titleOverride
			or ("%s  %s%s"):format(info.rarity, info.variant and (info.variant .. " ") or "", info.name),
		color = HatchHook.COLORS[info.rarity] or 0x5865F2,
		fields = {
			{ name = "Rarity", value = info.rarity, inline = true },
			{ name = "Clicks", value = HatchHook.fmt(info.clicks), inline = true },
		},
		footer = { text = "Rebirth Champions" },
	}
	if info.variant then
		e.fields[#e.fields + 1] = {
			name = "Variant",
			value = info.variant,
			inline = true,
		}
	end
	if info.acorns and info.acorns > 0 then
		e.fields[#e.fields + 1] = {
			name = "Acorns",
			value = HatchHook.fmt(info.acorns),
			inline = true,
		}
	end
	if info.image then
		e.thumbnail = { url = info.image }
		e.image = { url = info.image }
	end
	return e
end

function HatchHook.tick(data, selected, url)
	local now = HatchHook.snapshot(data)
	local seen = HatchHook.seen
	HatchHook.seen = now

	HatchHook.high = HatchHook.high or {}
	HatchHook.known = HatchHook.known or {}

	if not HatchHook.seeded then
		-- FIRST run only. Record the current counts and report nothing, otherwise
		-- enabling the hook would fire one message listing your whole inventory.
		for key, info in pairs(now) do
			HatchHook.known[key] = info.n
		end
		HatchHook.seeded = true
		HatchHook.why = "armed (baseline taken)"
		return
	end

	if type(selected) ~= "table" or type(url) ~= "string" or url == "" then
		HatchHook.why = ("EARLY: selected=%s url=%s"):format(
			type(selected),
			type(url) == "string" and (#url > 0 and "ok" or "EMPTY") or tostring(url)
		)
		-- Still record counts with nothing to report to, so switching the toggle
		-- on later does not treat everything you own as newly hatched.
		for key, info in pairs(now) do
			local had = HatchHook.known[key] or 0
			if info.n > had then
				HatchHook.known[key] = info.n
			end
		end
		return
	end

	-- STRICT before/after on the `am` count. This is the literal "a pet was
	-- added to my inventory" test: last poll held N of this pet, this poll holds
	-- N+k, so k arrived.
	--
	-- An earlier version used a lifetime running total instead, to survive the
	-- inventory rotating. That was wrong for what was asked - it means a pet you
	-- sold and later re-obtain at a count below your old peak is silently
	-- dropped, and it makes the reported number drift away from what is actually
	-- new. Strict delta is honest, and the rotation problem is handled at its
	-- source below instead.
	--
	-- sold pets are skipped entirely: sl = {nr, un} means this pet has been sold
	-- on to somebody, so it is not in your inventory any more and its count
	-- moving is market churn, not a hatch.
	local gained = {}
	for key, info in pairs(now) do
		local had = HatchHook.known[key]
		if had == nil then
			-- A pet that has never been seen arrives as a brand new entry, with
			-- `am` absent (so 1) even when the hatch gave several copies. Those
			-- are missed entirely by an am-only diff, which is the case that
			-- matters most - it is the first of a kind.
			gained[#gained + 1] = { key = key, n = info.n, info = info, fresh = true }
			HatchHook.known[key] = info.n
		elseif info.n > had then
			gained[#gained + 1] = { key = key, n = info.n - had, info = info }
			HatchHook.known[key] = info.n
		else
			-- Only lower the record when the pet actually leaves, and only if it
			-- was really sold. Keeping the floor stops a count that dips from
			-- market churn and returns from being reported a second time.
			HatchHook.known[key] = info.n
		end
	end
	if #gained == 0 then
		HatchHook.why = ("no gain this poll (%d keys watched)"):format(0)
		HatchHook.lastSeenCount = 0
		for _ in pairs(now) do
			HatchHook.lastSeenCount += 1
		end
		return
	end
	HatchHook.why = ("GAINED %d keys"):format(#gained)
	table.sort(gained, function(a, b)
		return a.key < b.key
	end)

	local embeds, extra = {}, 0
	-- guarded: this runs inside the poll's pcall, so anything thrown here used
	-- to vanish silently and look exactly like "no pets were added"
	local built, buildErr = pcall(function()
		for _, g in ipairs(gained) do
			local nm = g.key:match("^(.-)|")
			local inf = HatchHook.info(nm, data)
			inf.variant = g.info and g.info.variant
			inf.raw = g.info and g.info.raw
			-- stats come from the real item object when we have the entry
			if inf.raw then
				pcall(function()
					local pet = Util.itemUtils.createItemFromData(inf.raw)
					if pet then
						inf.clicks = tonumber(pet:getMultiplier()) or inf.clicks
						local acn = pet:getSpecialMultiplierName()
						inf.acorns = (acn == "acorns")
								and (tonumber(pet:getSpecialMultiplierAmount()) or 0)
							or 0
					end
				end)
			end
			if selected[inf.rarity] then
				local title = inf.rarity
				if inf.variant then
					title ..= " " .. inf.variant
				end
				if g.n > 1 then
					title ..= ("  x%d"):format(g.n)
				end
				if #embeds < 5 then
					embeds[#embeds + 1] = HatchHook.embed(inf, title)
				else
					extra += 1
				end
			end
		end
	end)
	HatchHook.builtOk = built
	if not built then
		HatchHook.why = "BUILD ERROR: " .. tostring(buildErr)
		return
	end

	if #embeds == 0 then
		HatchHook.why = ("watching (%d new, none selected)"):format(#gained)
		return
	end

	HatchHook.post(
		url,
		HttpService:JSONEncode({
			username = "Rebirth Champions",
			embeds = embeds,
			-- NOTE: `extra` is a NUMBER, so this must not be `#extra > 0`. That
			-- threw "attempt to get length of a number value" while building the
			-- JSON - i.e. after the embeds were made, which is why `why` was left
			-- reading "GAINED N keys" and why no post ever went out.
			content = extra > 0 and ("+%d more matching your filter"):format(extra) or nil,
		})
	)
	HatchHook.why = "POSTED"
end

-- Own coroutine, deliberately NOT part of the hub's status ticker.
--
-- The ticker's entire body is a single pcall, so anything that throws in it
-- silently kills every statement after the throw - which is why this ran zero
-- times when it lived in there. Out here a failure costs one iteration and the
-- next poll still runs.
task.spawn(function()
	while true do
		pcall(function()
			HatchHook.ticks = (HatchHook.ticks or 0) + 1
			local data = Knit.GetController("DataController"):getData()
			local ok, enabled = pcall(function()
				return Options.HookEnabled and Options.HookEnabled.Value == true
			end)
			local url = ""
			pcall(function()
				url = Options.HookUrl and Options.HookUrl.Value or ""
			end)

			if not enabled or type(url) ~= "string" or url == "" then
				HatchHook.why = "toggle off or no URL"
				HatchHook.seen = HatchHook.snapshot(data)
				return
			end

			local set = {}
			pcall(function()
				local v = Options.HookRarities and Options.HookRarities.Value
				if type(v) == "table" then
					for r, on in pairs(v) do
						if on then
							set[tostring(r)] = true
						end
					end
				end
			end)

			if next(set) == nil then
				HatchHook.why = "no rarities selected"
				HatchHook.seen = HatchHook.snapshot(data)
				return
			end

			HatchHook.why = "watching"
			HatchHook.tick(data, set, url)
		end)
		task.wait(0.25)
	end
end)

HatchHook.ticks = 0
HatchHook.log = {}
HatchHook.skipped = 0
HatchHook.high = {}
HatchHook.known = {}
HatchHook.seeded = false

-- Why a tick did not post, when it did not. Sampled each tick so the counters
-- point straight at the broken link instead of leaving it to guesswork.
HatchHook.why = nil

_G.__RCU_HATCHHOOK = HatchHook

local Circus = {}
Circus.MODES = { "normal", "extra", "ultra" }
Circus.CIRCLE_TAG = "CircusMinigameEffect"

-- Circle clicking.
--
-- CircusController:circles() spawns 10 shrinking circles and, for each one,
-- auto-clicks it ONLY if
--     math.random(0, 1) < Values.circusMinigameLuckAutoClick(player, data)
-- and then waits 1 / speed before doing it. That chance comes from the
-- circusMinigameLuckAutoClick upgrade, so on an account without it most circles
-- are never clicked at all - which is exactly the "some get missed" symptom.
--
-- The game reads that Value at spawn time and does nothing else with it, so
-- pinning it to 1 makes the game's OWN clickThis() run on every circle. We do
-- not reimplement the scoring and do not touch the odds of the payout - we only
-- remove the client-side "maybe click this" gate the upgrade would otherwise
-- fill, so every circle scores.
--
-- The per-circle delay stays the game's (1 / speed), so the round plays at the
-- intended pace rather than instantly.
local CIRCUS_ORIGINAL_LUCK = nil
local function Circus_forceFullLuck()
	if CIRCUS_ORIGINAL_LUCK == nil and Values.circusMinigameLuckAutoClick then
		CIRCUS_ORIGINAL_LUCK = Values.circusMinigameLuckAutoClick
	end
	Values.circusMinigameLuckAutoClick = function()
		return 1
	end
end

local function Circus_restoreLuck()
	if CIRCUS_ORIGINAL_LUCK then
		Values.circusMinigameLuckAutoClick = CIRCUS_ORIGINAL_LUCK
	end
end

-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end
-- Nothing to hook: the circles are plain Frames with no reachable click signal
-- (their handlers live in a Button-module closure), so listening to them does
-- nothing. Forcing the auto-click chance to 1 lets the game's own handler run
-- on every circle instead - see Circus_forceFullLuck above.
function Circus.clicker()
	Circus_forceFullLuck()
end

function Circus.run(t)
	local ctl = CircusController or getController("CircusController")
	if not ctl or not ctl.playMinigame then
		return
	end
	local data = getData()
	if not data then
		return
	end

	local want = "normal"
	pcall(function()
		local v = Options.CircusMode and Options.CircusMode.Value
		if type(v) == "string" and v ~= "" then
			want = v
		end
	end)
	t.mode = want

	-- Apply the mode before any early return, so the dropdown is honoured even
	-- while we are standing somewhere else.
	pcall(function()
		ctl:setGamemode(want)
	end)
	pcall(function()
		ctl:setIsAutoPlaying(true)
	end)

	-- Must be at the Circus.
	-- Use the SERVER's map (data.currentMap.mapName), not MapController. The
	-- client-side field is unreliable in both directions: getCurrentMap(true)
	-- returns the map ID ("12") rather than the name, and on a verified account
	-- getCurrentMap() reported "Desert" while the server had us on "Circus".
	-- Either mismatch makes the runner sit on wrongMap and never play.
	local atCircus = false
	pcall(function()
		atCircus = (data.currentMap and data.currentMap.mapName) == "Circus"
	end)
	if not atCircus then
		-- fallbacks, in case the data shape ever changes
		pcall(function()
			atCircus = MapController.getCurrentMap(MapController) == "Circus"
		end)
		if not atCircus then
			pcall(function()
				atCircus = MapController.getCurrentMap(MapController, true) == "12"
			end)
		end
	end
	if not atCircus then
		if not t.toldWrongMap then
			t.toldWrongMap = true
			notify("Auto Circus", "Teleport to the Circus map first.")
		end
		t.cooldown = os.clock() + 2
		return
	end
	t.toldWrongMap = false

	-- the striker is the model the whole thing hangs off
	local okModel, striker = pcall(function()
		return ctl:getHighStrikerModel()
	end)
	if not okModel or not striker then
		if not t.toldNoStriker then
			t.toldNoStriker = true
			notify("Auto Circus", "Waiting for the high striker to load...")
		end
		t.cooldown = os.clock() + 2
		return
	end
	t.toldNoStriker = false

	Circus.clicker()
	-- One round per runner tick, NOT playMinigame(ctl, 2).
	--
	-- count 2 hands an infinite loop to the game, and that loop is inside the
	-- game's coroutine: the only way out is its own isAutoPlaying() check, which
	-- happens at the TOP of a round. So toggling off still had to pay for the
	-- round already in flight - at ultra that is 100 tickets and several seconds
	-- after you already flipped the switch off.
	--
	-- count 1 runs exactly one round and returns, which puts the gate back in
	-- OUR loop: t.alive is checked here every tick, so turning the toggle off
	-- stops it at the next tick boundary instead of the next round boundary.
	if not t.alive or (t.cooldown or 0) > os.clock() then
		return
	end
	t.cooldown = os.clock() + 1
	pcall(function()
		ctl:playMinigame(ctl, 1)
	end)
end

-- The game gates a skill three ways, all of which have to be honoured or the
-- server silently refuses:
--   1. the TREE may need a mastery tier (paradox needs paradoxMastery)
--   2. a CATEGORY may need a mastery tier
--   3. a category can be childOf another category's node, and within a
--      category node N is only reachable once its prerequisites are owned.
--      getVisibleHexagons spells out the rule per index:
--        i == 1 or 2 -> always visible
--        i == 3       -> needs index 1
--        i == 4       -> needs index 2
--        i >= 5       -> needs index i-1
--      and a childOf category is only processed once its parent has any
--      visible node at all.
-- The old version walked `pairs(catData.list)` (unordered), ignored
-- prerequisites and mastery, and bailed out after a single purchase per
-- pass with a 1s cooldown - so it stalled on the first node the server
-- rejected and never got through the tree. This walks categories in
-- dependency order, nodes in index order, and buys every affordable
-- prerequisite-satisfied node in one pass.
-- These live in ONE table rather than as separate top-level locals on
-- purpose. Luau caps a chunk at 200 local registers and this file is already
-- close to it, so every extra top-level local is a chance that one more
-- addition stops the whole hub compiling.
local SkillTreeHelpers = {}

function SkillTreeHelpers.masteryOk(data, req)
	if type(req) ~= "table" or not req.name then
		return true
	end
	local ok, tier = pcall(function()
		return Util.masteryUtils.getTier(data, req.name)
	end)
	if not ok or type(tier) ~= "number" then
		return true
	end
	return tier >= (req.tier or 0)
end

-- How many of a currency we hold. This is the whole gem-upgrade bug.
--
-- Verified shapes in Shared.List.SkillTree, per tree:
--   fallEvent          currency = ITEM TABLE   ({nm = "acorns", ...})
--   dungeonUpgrades    currency = STRING       ("dungeonCoins")
--   base / eggUpgrades / rewards / boosts
--                      currency = NIL
-- The gem-priced trees carry no currency field at all, which is what "costs
-- gems" means here. The old check was
--   rawItemAmount(data, node.currency and node.currency.nm)
-- so for every gem node it read rawItemAmount(data, nil) -> 0 >= 5e+22 -> false
-- -> the category `break`s on its first node and the whole gem tree is
-- silently never bought. It also crashed on the string-currency tree, since a
-- string has no .nm.
function SkillTreeHelpers.currencyBalance(data, node)
	local price = node.price or 0
	local cur = node.currency
	if cur == nil then
		-- no currency field = priced in gems, which live on data.gems
		return data.gems or 0, price, "gems"
	end
	if type(cur) == "string" then
		return rawItemAmount(data, cur), price, cur
	end
	if type(cur) == "table" then
		local nm = cur.nm
		if type(nm) == "string" then
			return rawItemAmount(data, nm), price, nm
		end
		-- a currency object we cannot name: do not block on it
		return math.huge, price, "?"
	end
	return math.huge, price, "?"
end

-- Is node at position `i` in `catData` unlocked?
--
-- The old rule (i<=2 free, i>=3 needs i-1) was transcribed from
-- getVisibleHexagons and is wrong for a tree bought in the same pass.
-- SkillTreeController:onClick shows what actually happens: a successful buy
-- of index N marks N, N+1 AND N+2 as owned locally, because those nodes
-- become visible together. So after buying index 1 of auraLuck, indices 2 and
-- 3 are immediately buyable even though the old rule demanded 1 and 2.
-- Mirroring that unlock is what makes a whole category drain in one pass
-- instead of stalling on the third node.
function SkillTreeHelpers.nodeVisible(owned, catData, i)
	if i <= 3 then
		return true
	end
	return owned[(catData._key or "") .. "_" .. (i - 2)] == true
end

-- record a purchase the way the game does, unlocking the two nodes above it
function SkillTreeHelpers.markOwned(owned, catData, index)
	local key = catData._key or ""
	owned[key .. "_" .. index] = true
	owned[key .. "_" .. (index + 1)] = true
	owned[key .. "_" .. (index + 2)] = true
end

-- Every tree is a candidate, not just the one for the map we are standing on.
--
-- The old runner resolved the current map's tree by name and gave up if it was
-- not found. The map trees are only a few of nine: base, eggUpgrades, rewards
-- and boosts are account-wide and buyable from anywhere, and those are exactly
-- the gem ones. "Skill tree not working with gem upgrades" was this line.
-- Each tree is still gated on its own requiredMastery.
function SkillTreeHelpers.candidates()
	local out = {}
	for k in pairs(SkillTreeList) do
		if type(SkillTreeList[k]) == "table" and type(SkillTreeList[k].list) == "table" then
			out[#out + 1] = k
		end
	end
	table.sort(out)
	return out
end

local function skillTreeRunner(t)
	local data = getData()
	if not data or not SkillTreeService then
		return
	end

	local bought = 0
	local problems = 0

	for _, treeKey in ipairs(SkillTreeHelpers.candidates()) do
		local tree = SkillTreeList[treeKey]
		if type(tree) == "table" and type(tree.list) == "table" then
			if SkillTreeHelpers.masteryOk(data, tree.requiredMastery) then
				-- owned is a live reference into data when the tree has an
				-- entry, and a scratch table when it does not. Either way the
				-- writes below are local bookkeeping so one pass can chain.
				local owned = (data.skillTree and data.skillTree[treeKey]) or {}

				-- roots first, then children by depth, so a chain such as
				-- acornsBase -> acornsMain -> acornsHigher resolves in one pass
				local roots, children = {}, {}
				local catKeys = {}
				for k in pairs(tree.list) do
					catKeys[#catKeys + 1] = k
				end
				table.sort(catKeys)
				for _, k in ipairs(catKeys) do
					local c = tree.list[k]
					if type(c) == "table" and type(c.list) == "table" then
						c._key = k
						if type(c.childOf) == "table" then
							children[#children + 1] = { key = k, data = c }
						else
							roots[#roots + 1] = { key = k, data = c }
						end
					end
				end

				local function tryCategory(entry)
					local cat, catData = entry.key, entry.data
					if not SkillTreeHelpers.masteryOk(data, catData.requiredMastery) then
						return
					end
					for i = 1, #catData.list do
						local node = catData.list[i]
						if type(node) == "table" and node.index then
							local key = cat .. "_" .. node.index
							if not owned[key] and SkillTreeHelpers.nodeVisible(owned, catData, i) then
								local have, price = SkillTreeHelpers.currencyBalance(data, node)
								if have >= price then
									local ok, res = pcall(function()
										return SkillTreeService:buySkillTree(treeKey, cat, node.index)
									end)
									if ok and res == "success" then
										SkillTreeHelpers.markOwned(owned, catData, node.index)
										bought += 1
										if notifyEnabled and bought <= 3 then
											notify("Skill Tree", "Bought " .. tostring(node.name or key))
										end
										-- keep going: the next index may now be unlocked
									elseif ok and res ~= "success" then
										-- rejected: the server wants a beat between
										-- calls, and this node is unaffordable or
										-- gated server-side, so stop this category
										if notifyEnabled and res then
											problems += 1
											t.lastReject = tostring(treeKey) .. " " .. key .. " -> " .. tostring(res)
										end
										return
									elseif not ok then
										problems += 1
										t.lastReject = tostring(treeKey) .. " " .. key .. " -> " .. tostring(res)
										return
									end
								else
									-- cannot afford this one; everything after it is either
						-- locked behind it or more expensive, so this category is
						-- done for now
						break
					end
				end
			end
		end
	end

	for _, e in ipairs(roots) do
					tryCategory(e)
				end
				-- resolve child categories, repeating so a chain gets fully walked
				for _ = 1, 4 do
					local progressed = false
					for _, e in ipairs(children) do
						local pk = e.data.childOf
						if owned[pk[1] .. "_" .. pk[2]] then
							tryCategory(e)
							progressed = true
						end
					end
					if not progressed then
						break
					end
				end
			end
		end
	end

	t.lastBought = bought
	t.lastProblems = problems > 0 and problems or nil
	if bought > 0 then
		t.cooldown = os.clock() + 0.5
	end
end

local function antiAfkRunner(t)
	local hrp = Functions.getHRP(LocalPlayer)
	local hum = Functions.getHumanoid(LocalPlayer)
	if not hrp or not hum then
		return
	end
	if (t.lastWiggle or 0) + 25 > os.clock() then
		return
	end
	if hum.MoveDirection.Magnitude > 0.1 then
		t.lastWiggle = os.clock()
		return
	end
	local startC = hrp.CFrame
	local startPos = startC.Position
	hum:MoveTo(startPos + startC.LookVector * 2)
	task.wait(0.4)
	local p2 = Functions.getHRP(LocalPlayer)
	if p2 then
		p2.CFrame = startC
		pcall(function()
			p2.AssemblyLinearVelocity = Vector3.zero
		end)
		hum:MoveTo(startPos)
	end
	t.lastWiggle = os.clock()
end

local function respawnRunner(t)
	local okC, char = pcall(function()
		return LocalPlayer and LocalPlayer.Character
	end)
	if not okC then
		return
	end
	if char then
		local okH, hum = pcall(function()
			return char:FindFirstChildWhichIsA("Humanoid")
		end)
		if okH and hum and hum.Health > 0 then
			return
		end
	end
	if (t.lastRespawn or 0) + 4 < os.clock() then
		t.lastRespawn = os.clock()
		pcall(function()
			if LocalPlayer then
				LocalPlayer:LoadCharacter()
			end
		end)
	end
end

local function rakeStop()
	applyRakeSpeed(false)
	pcall(function()
		if PlayerService then
			PlayerService.setAutoActivity:Fire("fallRaking", false)
		end
	end)
end

local function rakeUpgradeRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local data = getData()
	if not data then
		return
	end
	local idx = currentRakeIndex(data)
	if not idx then
		return
	end
	local nextKey = nil
	for key, def in pairs(FallEventList) do
		if type(def) == "table" and def.isTool and def.index == idx + 1 then
			nextKey = key
			break
		end
	end
	if not nextKey then
		if not t.maxed then
			t.maxed = true
			notify("Rake", "Every rake is upgraded")
		end
		return
	end
	local okItem, nextItem = pcall(function()
		return Items.fallEvent(nextKey)
	end)
	if not okItem or not nextItem then
		return
	end
	local def = RakeUpgrader[nextItem:getName()]
	if not def or not def.required then
		return
	end
	for _, req in pairs(def.required) do
		if itemAmount(data, req:getName()) < req:getAmount() then
			return
		end
	end
	local ok, res = pcall(function()
		return FallToolService:upgradeTool()
	end)
	if ok and res == "success" then
		t.maxed = false
		t.cooldown = os.clock() + 2
		notify("Rake", "Upgraded to " .. tostring(nextItem:getRealName()))
	end
end

-- ------------------------------------------------------------------
-- auto fishing, rebuilt against the real mechanic.
--
-- The previous version reached into FishingController's function env with
-- getfenv/debug.setupvalue to hack the 2s recast wait. That was fragile and
-- did not survive. Reading FishingController shows the actual loop:
--   startFishing()  -> fishRequest:Fire()  (cast)
--   fishHooked       -> bar fills via increaseHookProgress
--   fishCatched      -> fishCatched:Fire() to the server, then re-cast
-- and the server has its own auto mode: setIsAutoFishing(true). We simply:
--   1. travel to the fishing map and equip the rod
--   2. stand at the game's own fishing spot CFrame
--   3. tell the server auto-fishing is on
--   4. listen for fishCatched and re-cast the instant it lands
-- No env hacking, no render-step unbinding.
-- ------------------------------------------------------------------
LiveCounts.FISH_MAP_ID = 30
LiveCounts.FISH_RECAST_DELAY = 0.12
-- the game's own "you are here to fish" spot, lifted verbatim from
-- FishingController's auto-fish bootstrap so we stand exactly where it does
local FISH_SPOT_CFRAME = CFrame.new(
	-5335.45312, -92.1107941, -3160.11108,
	-0.12425144, 0, 0.9922508,
	3.22610176e-05, 1, 0,
	-0.99225086, 3.25127985e-05, -0.124251433
)

local FishingController = nil
local fishConns = {}

local function fishSvc()
	FishingService = FishingService or getService("FishingService")
	return FishingService
end

local function fishCtl()
	FishingController = FishingController or getController("FishingController")
	MapController = MapController or getController("MapController")
	InventoryService = InventoryService or getService("InventoryService")
	return FishingController
end

local function clearFishConns()
	for _, c in ipairs(fishConns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(fishConns)
end

local function fishIsOn()
	local ctl = fishCtl()
	if not ctl then
		return false
	end
	local ok, v = pcall(function()
		return ctl:isFishing()
	end)
	return ok and v == true
end

-- The three bays are FishingBay / VolcanoBay / FrozenBay, spawned as a model
-- tagged "fishingWorld" with `fishingZone` parts marking the fishable water.
-- Rather than hardcoding a CFrame per bay, find the dock edge from the tags:
-- the nearest fishingZone part is the water we cast into, so we stand on the
-- solid ground beside it. That works for all three bays without new data.
LiveCounts.FISH_BAYS = { "fishingBay", "volcanoBay", "frozenBay" }

local function currentBayName()
	local data = getData()
	return data and data.currentFishingWorld or "fishingBay"
end

-- Stand on the dock EDGE: offset from the water toward the player's current
-- side by a couple of studs, then drop onto whatever floor is actually there
-- via groundStand, so we never end up floating over the water or under it.
-- Where to stand to fish.
--
-- This used to depend on the "fishingZone" CollectionService tag, and that is
-- why Auto Fishing never worked with ANY rod:
--
--   * FishingController only READS that tag (getRay -> HasTag("fishingZone") in
--     its hover/input handlers). Nothing in the game ever applies it.
--   * Verified on Assets.FishingBays.FishingBay: the folder and its 358
--     descendants carry only Roblox's own "_BrushtoolBrushed" tags - zero
--     "fishingZone". The live clone in Skylands is the same.
--   * So the old runner sat in its `#zones == 0` branch forever, reload call
--     after reload, and never once reached startFishing. It looked like a rod
--     problem because the equip step came first and also had its own bug.
--
-- The dock is real geometry, so find it that way: the fishing spot the game's
-- own controller uses is known-good, and the deck under it is the widest flat
-- collidable part nearby. No tags required.
local fishParams = RaycastParams.new()
fishParams.FilterType = Enum.RaycastFilterType.Exclude
fishParams.IgnoreWater = false
-- pick the cast target: the fishingZone part nearest the player, else the
-- first one. Returns its position.
local function bestFishingZone(hrp)
	local zones = CollectionService:GetTagged("fishingZone")
	if #zones == 0 then
		return nil
	end
	local best, bestD = zones[1], math.huge
	for _, z in ipairs(zones) do
		local ok, p = pcall(function()
			return z:GetPivot().Position
		end)
		if ok and p then
			local d = (p - hrp.Position).Magnitude
			if d < bestD then
				bestD, best = d, z
			end
		end
	end
	local okp, pp = pcall(function()
		return best:GetPivot().Position
	end)
	if okp then
		return best, pp
	end
	return best, nil
end

-- A tight downward probe just above the water surface. The generic
-- groundStand() starts its raycast 300 studs up, which over the fishing bay
-- hits the Skylands terrain far above the dock and drops us on a rooftop
-- hundreds of studs up. For the dock we only care about the few studs of
-- floor between the water line and the deck, so probe locally.
local fishParams = RaycastParams.new()
fishParams.FilterType = Enum.RaycastFilterType.Exclude
fishParams.IgnoreWater = false

local function dockFloor(x, z, waterY, hrp)
	fishParams.FilterDescendantsInstances = { LocalPlayer.Character }
	local from = Vector3.new(x, waterY + 8, z)
	local hit = workspace:Raycast(from, Vector3.new(0, -40, 0), fishParams)
	if hit then
		return hit.Position.Y
	end
	return nil
end

-- Stand on the dock EDGE: offset from the water toward the player's current
-- side by a couple of studs, then drop onto whatever floor is actually there
-- via groundStand, so we never end up floating over the water or under it.
local function fishStandSpot(hrp)
	local _, water = bestFishingZone(hrp)
	if not water then
		-- bay not loaded yet: fall back to the game's own bootstrap spot
		local p = FISH_SPOT_CFRAME.Position
		return groundStand(p.X, p.Z, p.Y + 40, nil, hrp)
	end

	local away = hrp.Position - water
	away = Vector3.new(away.X, 0, away.Z)
	if away.Magnitude < 0.5 then
		away = Vector3.new(0, 0, -1)
	end
	away = away.Unit

	local lift = standLift(hrp)
	local best, bestErr = nil, math.huge
	-- the dock edge is the closest solid footing just above the water; try a
	-- couple of standoffs so we end up on the planks, not in them
	for _, dist in ipairs({ 2, 3.5, 5, 8, 12 }) do
		local want = water + away * dist
		local y = dockFloor(want.X, want.Z, water.Y, hrp)
		if y then
			local delta = math.abs(y - water.Y)
			if delta < bestErr then
				bestErr, best = delta, Vector3.new(want.X, y + lift, want.Z)
			end
			-- a deck within 3 studs of the water is the edge: stop here
			if delta < 3 then
				return Vector3.new(want.X, y + lift, want.Z)
			end
		end
	end
	if best then
		return best
	end
	-- nothing solid nearby: stand just above the water rather than fall in
	return water + Vector3.new(0, 3, 0)
end

local function fishRunner(t)
	local svc = fishSvc()
	local ctl = fishCtl()
	MapController = MapController or getController("MapController")
	if not svc or not ctl or not MapController or not InventoryService then
		return
	end
	local data = getData()
	if not data then
		return
	end

	-- 1) get on the fishing map (map 30 / Skylands).
	--
	-- This checks MapController._currentMapId, the CLIENT value, exactly as the
	-- original did, and that is deliberate. I briefly swapped it for the server's
	-- data.currentMap.mapId on the theory the client field was stale - it is not.
	-- data.currentMap.mapId stays at 0 while you are genuinely standing in
	-- Skylands (character at -5027,-97,-3252, which is map 30's cframe exactly),
	-- so the server-side check blocked fishing on a character who was in the
	-- right place. The client field tracks where you actually are; keep it.
	--
	-- There is no travel here: the server owns the map and can refuse, and
	-- re-asking just loops. Get to Skylands yourself and this picks up there.
	local okMap, onMap = pcall(function()
		return MapController._currentMapId == LiveCounts.FISH_MAP_ID
	end)
	if okMap and not onMap then
		if not t.toldWrongMap then
			t.toldWrongMap = true
			notify("Auto Fishing", "Teleport to Skylands first - the fishing bay is there.")
		end
		t.cooldown = os.clock() + 2
		return
	end
	t.toldWrongMap = false
	if not data.isFishingRodEquipped then
		local okUse = equipRod()
		if not okUse then
			-- say WHY instead of retrying silently forever: no rod owned, or the
			-- server never accepted the equip
			if not t.toldNoRod then
				t.toldNoRod = true
				local id, idx = bestOwnedRodId(data)
				if not id then
					notify("Auto Fishing", "No fishing rod owned - buy one first.")
				else
					notify("Auto Fishing", "Could not equip your rod (index " .. tostring(idx) .. ").")
				end
			end
			t.cooldown = os.clock() + 2
			return
		end
		t.toldNoRod = false
		return
	end
	t.toldNoRod = false

	-- 3) the fishing world must be loaded before the zone tag exists
	local zones = CollectionService:GetTagged("fishingZone")
	if #zones == 0 then
		if (t.idleTime or 0) + 30 < os.clock() then
			t.idleTime = os.clock()
			pcall(function()
				ctl:reloadFishingWorld()
			end)
			pcall(function()
				svc.unlockFishingWorld:Fire()
			end)
		end
		return
	end

	-- 3b) the requested bay must actually be the loaded one. The bay model is
	-- spawned client-side from Assets.FishingBays[toPascal(currentFishingWorld)]
	-- and tagged "fishingWorld"; the server owns the switch, so ask it and then
	-- wait for the tag to change rather than assuming the teleport worked.
	local wantBay = Options.FishBay and Options.FishBay.Value
		if not wantBay or wantBay == "" then
			wantBay = currentBayName()
		end
		if wantBay ~= currentBayName() then
			if (t.baySwitchAt or 0) + 8 < os.clock() then
				t.baySwitchAt = os.clock()
				t.bayWaiting = wantBay
				clearFishConns()
				t.fishReady = nil
				local sent = pcall(function()
					svc.setFishingWorld:Fire(wantBay)
				end)
				if not sent then
					-- older signature: unlock then select
					pcall(function()
						svc.unlockFishingWorld:Fire()
					end)
				end
			end
			return
		end
		t.bayWaiting = nil

	-- 4) one-time setup: stand at the dock edge, start, and hook the recast
	if not t.fishReady then
		local hrp = Functions.getHRP(LocalPlayer)
		if not hrp then
			return
		end
		local stand = fishStandSpot(hrp)
		hrp.Anchored = true
		hrp.CFrame = CFrame.new(stand)
		task.wait(0.3)
		hrp.Anchored = false
		pcall(function()
			hrp.AssemblyLinearVelocity = Vector3.zero
		end)

		-- Neutralise the game's "walked too far from your cast" guard.
		--
		-- FishingController binds cancelIfTooFarAway to the render step under
		-- the name "cancelIfTooFarAway"; it compares the HRP against a private
		-- module local (u131) that is only ever assigned from the mouse-click
		-- handler. An automated run never goes through that, so it stays at the
		-- world origin and calls stopFishing() on the very next frame - which
		-- is why automated fishing could never hold a cast. The upvalue is not
		-- reachable (no exported function exposes it and this executor's
		-- debug.getupvalue does not return names), but BindToRenderStep
		-- replaces any binding with the same name, so a no-op in its place
		-- stops the cast from ever being cancelled. Verified: with this in
		-- place isFishing() stays true indefinitely; without it, false
		-- within one frame.
		pcall(function()
			ctl:startFishing()
		end)

		-- MUST come after startFishing: startFishing re-binds this very
		-- render step itself, so an override placed before the call is
		-- silently replaced a moment later and the cast dies anyway.
		pcall(function()
			RunService:BindToRenderStep("cancelIfTooFarAway", 2, function() end)
			t.fishGuardOverridden = true
		end)

		clearFishConns()
		-- the server's own auto mode fills the bar and re-casts for us
		pcall(function()
			svc.setIsAutoFishing:Fire(true)
		end)
		-- re-cast the moment the server confirms a catch
		table.insert(fishConns, svc.fishCatched:Connect(function()
			t.awaitCatch = os.clock()
		end))
		table.insert(fishConns, svc.fishHooked:Connect(function()
			t.lastBite = os.clock()
		end))

		-- (the guard override lives right above startFishing)
		t.fishReady = true
		t.castAt = os.clock()
		t.lastBite = os.clock()
		t.awaitCatch = nil
		return
	end

	-- 5) keep it alive: if the game dropped us, restart cleanly
	if not fishIsOn() then
		if (t.castAt or 0) + 1 < os.clock() then
			clearFishConns()
			t.fishReady = nil
			t.castAt = os.clock()
		end
		return
	end

	-- 6) recast once the catch has landed
	local now = os.clock()
	if t.awaitCatch and now - t.awaitCatch >= LiveCounts.FISH_RECAST_DELAY then
		pcall(function()
			svc.fishRequest:Fire()
		end)
		t.awaitCatch = nil
		t.castAt = now
	end

	-- 7) watchdog: no bite for a while means the cast died, start over
	if (t.lastBite or 0) + 12 < now and not t.awaitCatch then
		pcall(function()
			ctl:stopFishing()
		end)
		task.wait(0.2)
		pcall(function()
			svc.setIsAutoFishing:Fire(true)
		end)
		pcall(function()
			ctl:startFishing()
		end)
		-- same reason as above: the restart path re-binds the guard too
		pcall(function()
			RunService:BindToRenderStep("cancelIfTooFarAway", 2, function() end)
		end)
		t.castAt = now
		t.lastBite = now
	end
end

local function fishStop(t)
	if t then
		t.fishReady = nil
		t.awaitCatch = nil
		t.castAt = nil
	end
	clearFishConns()
	local svc = fishSvc()
	local ctl = fishCtl()
	if svc then
		pcall(function()
			svc.setIsAutoFishing:Fire(false)
		end)
		pcall(function()
			svc.stopFishing:Fire()
		end)
	end
	if ctl then
		pcall(function()
			if ctl:isFishing() then
				ctl:stopFishing()
			end
		end)
	end
	-- restore the game's own guard now that we are done fishing
	pcall(function()
		RunService:UnbindFromRenderStep("cancelIfTooFarAway")
	end)
end

local function fallUpgradeRunner(t)
	if t.cooldown > os.clock() then
		return
	end
	local data = getData()
	if not data then
		return
	end
	local levels = data.fallUpgrades or {}
	local bought = 0
	for key, def in pairs(LeavesMachine) do
		if type(def) == "table" and type(def.upgrades) == "table" then
			local lvl = levels[key] or 0
			local up = def.upgrades[lvl + 1]
			if up and up.cost and itemAmount(data, up.cost:getName()) >= up.cost:getAmount() then
				local ok, res = pcall(function()
					return UpgradeService:upgradeFall(key)
				end)
				if ok and res == "success" then
					bought += 1
				end
			end
		end
	end
	if bought > 0 then
		t.cooldown = os.clock() + 2
		notify("Fall", "Bought " .. bought .. " fall upgrade" .. (bought > 1 and "s" or ""))
	end
end

-- ------------------------------------------------------------------
-- window
-- ------------------------------------------------------------------
local Window = Fluent:CreateWindow({
	Title = "Rebirth Champions",
	SubTitle = "ultimate",
	TabWidth = 160,
	Size = UDim2.fromOffset(580, 460),
	Acrylic = false,
	Theme = "Dark",
	MinimizeKey = Enum.KeyCode.RightShift,
})

local Tabs = {
	Eggs = Window:AddTab({ Title = "Eggs", Icon = "egg" }),
	Rebirth = Window:AddTab({ Title = "Rebirth", Icon = "refresh-cw" }),
	Fall = Window:AddTab({ Title = "Fall Event", Icon = "leaf" }),
	Fishing = Window:AddTab({ Title = "Fishing", Icon = "anchor" }),
	World = Window:AddTab({ Title = "Trees & Axe", Icon = "trees" }),
	Rewards = Window:AddTab({ Title = "Rewards", Icon = "gift" }),
	Machines = Window:AddTab({ Title = "Machines", Icon = "cpu" }),
	Webhook = Window:AddTab({ Title = "Webhook", Icon = "webhook" }),
	Settings = Window:AddTab({ Title = "Settings", Icon = "settings" }),
}
print("[RCU] window ok")
Options = Fluent.Options or Options or {}

-- Every tab is grouped into named sections so nothing is a flat wall of
-- toggles.
--
-- NOTE on this Fluent build: Tab:AddSection ignores its first argument and
-- passes the SECOND one straight to the Section component as the header text.
-- So the correct call is AddSection(<anything>, "Title") - passing a props
-- table as the only argument hands a table to TextLabel.Text, which throws and
-- takes the whole tab with it. section() is wrapped in a pcall for that reason:
-- if AddSection misbehaves we fall back to adding straight to the tab, so a
-- cosmetic grouping can never cost you the features underneath it.
local Sections = {}
local function section(tab, name, icon)
	-- try the two-arg form this build wants, then the documented props form
	local built
	pcall(function()
		built = Tabs[tab]:AddSection(name, name)
	end)
	if type(built) ~= "table" or type(built.AddToggle) ~= "function" then
		pcall(function()
			built = Tabs[tab]:AddSection({ Title = name, Icon = icon })
		end)
	end
	if type(built) ~= "table" or type(built.AddToggle) ~= "function" then
		-- last resort: no grouping, but the features still appear
		built = Tabs[tab]
	end
	Sections[name] = built
	return built
end

LiveCounts.uiOk, LiveCounts.uiErr = xpcall(function()
local defaultEgg = "Fall 2026"
if not table.find(eggNames, defaultEgg) then
	defaultEgg = eggNames[1]
end

local ALL_TOGGLE_IDS = {}
local sectionMembers = {}
local function bindToggle(target, id, taskName, runner, interval, onStop)
	local toggle = target:AddToggle(id.id, {
		Title = id.title,
		Description = id.desc,
		Default = false,
		Callback = function(state)
			if state == nil then
				state = Options[id.id] and Options[id.id].Value
			end
			if state then
				startTask(taskName, runner, interval, onStop)
			else
				stopTask(taskName)
			end
		end,
	})
	pcall(function()
		Options[id.id] = toggle
	end)
	ALL_TOGGLE_IDS[#ALL_TOGGLE_IDS + 1] = id.id
	if id.group then
		sectionMembers[id.group] = sectionMembers[id.group] or {}
		table.insert(sectionMembers[id.group], id.id)
	end
	return toggle
end

local function bindPlainToggle(target, key, props)
	local t = target:AddToggle(key, props)
	pcall(function()
		Options[key] = t
	end)
	ALL_TOGGLE_IDS[#ALL_TOGGLE_IDS + 1] = key
	return t
end

-- ==================================================================
-- Eggs
-- ==================================================================
local secEgg = section("Eggs", "Hatching", "egg")
local eggStatus = secEgg:AddParagraph({
	Title = "Status",
	Content = "Idle",
})

local eggValues = { LiveCounts.NEAREST_EGG }
for _, name in ipairs(eggNames) do
	eggValues[#eggValues + 1] = name
end

local eggDropdown = secEgg:AddDropdown("EggSelect", {
	Title = "Egg",
	Description = "Which egg Auto Hatch opens. Pick the closest-egg entry to follow whatever is nearest",
	Default = LiveCounts.NEAREST_EGG,
	Values = eggValues,
})
pcall(function()
	Options.EggSelect = eggDropdown
end)

bindPlainToggle(secEgg, "AutoHatchNearest", {
	Title = "Always nearest egg",
	Description = "Overrides the dropdown and hatches the closest tagged egg",
	Default = false,
})

bindToggle(secEgg, { id = "AutoHatch", title = "Auto Hatch", desc = "Teleports to the egg and opens max as fast as the server answers (~46 pets/s with the animation off)", group = "Hatching" }, "hatch", hatchRunner, 0.02)
bindPlainToggle(secEgg, "AutoHatchLuckyEggs", {
	Title = "Hatch lucky eggs",
	Description = "Teleports to a spawned lucky egg and opens it, then goes back to your chosen egg when it expires",
	Default = true,
})

secEgg:AddButton({
	Title = "Teleport to egg",
	Description = "Walks you to the selected egg",
	Callback = function()
		local egg = eggValueName(Options.EggSelect.Value)
		local ok, err = teleportToEgg({ alive = true }, egg)
		notify("Teleport", ok and ("At " .. tostring(egg)) or tostring(err))
	end,
})

-- ==================================================================
-- Rebirth
-- ==================================================================
local secRebirth = section("Rebirth", "Rebirth & Clicks", "refresh-cw")
local rebirthStatus = secRebirth:AddParagraph({
	Title = "Status",
	Content = "Idle",
})

bindToggle(secRebirth, { id = "AutoRebirth", title = "Auto Rebirth", desc = "Rebirths at the highest unlocked button you can afford", group = "Rebirth" }, "rebirth", rebirthRunner, 0.05)
bindToggle(secRebirth, { id = "AutoClicker", title = "Auto Clicker", desc = "Clicks the main button at the server's maximum rate", group = "Rebirth" }, "click", clickRunner, 0.045)

-- ==================================================================
-- Fall Event
-- ==================================================================
local secFall = section("Fall", "Fall Event", "leaf")
local fallStatus = secFall:AddParagraph({
	Title = "Status",
	Content = "Idle",
})

bindToggle(secFall, { id = "AutoFallRebirth", title = "Auto Fall Rebirth", desc = "Rebirths the fall event when every requirement is met", group = "Fall" }, "fallRebirth", fallRebirthRunner, 1.5)
bindToggle(secFall, { id = "AutoTreeRebirth", title = "Auto Tree Rebirth", desc = "Tree rebirths as soon as the harvest tree hits the needed level", group = "Fall" }, "treeRebirth", treeRebirthRunner, 1.5)
bindToggle(secFall, { id = "AutoFallUpgrades", title = "Auto Fall Upgrades", desc = "Buys every leaves machine upgrade you can afford", group = "Fall" }, "fallUpgrades", fallUpgradeRunner, 2)

local secRake = section("Fall", "Raking", "leaf")
local rakeStatus = secRake:AddParagraph({
	Title = "Rake status",
	Content = "Idle",
})

local rakeSpeedSlider = secRake:AddSlider("RakeSpeed", {
	Title = "Rake walk speed",
	Description = "Movement speed applied while Auto Rake is on",
	Default = 24,
	Min = 16,
	Max = 120,
	Rounding = 0,
})
pcall(function()
	Options.RakeSpeed = rakeSpeedSlider
end)

bindToggle(secRake, { id = "AutoRake", title = "Auto Rake", desc = "Fires the rake remote from the densest cluster of piles - no walking, server-capped throughput", group = "Rake" }, "rakeFarm", rakeFarmRunner, 0.02, rakeStop)
bindToggle(secRake, { id = "AutoRakeUpgrade", title = "Auto Rake Upgrade", desc = "Buys the next rake the moment it's affordable", group = "Rake" }, "rakeFarmUp", rakeUpgradeRunner, 2)

-- ==================================================================
-- Fishing
-- ==================================================================
local secFish = section("Fishing", "Fishing", "anchor")
local fishingStatus = secFish:AddParagraph({
	Title = "Status",
	Content = "Idle",
})

-- Paragraph only exposes SetTitle / SetDesc. Calling SetContent throws and, in
-- this venv-wrapped build, an error here kills every element below it.
pcall(function()
	fishingStatus:SetDesc("Drives the game's own FishingController: travels to the fishing map, equips the magic rod, stands at the spot and re-casts the instant a catch is confirmed (removes the game's 2s recast wait).")
end)

do
	-- the three bays are Assets.FishingBays children: FishingBay, VolcanoBay,
	-- FrozenBay. currentFishingWorld is the Pascal-cased key of the same set.
	local bayDropdown = secFish:AddDropdown("FishBay", {
		Title = "Fishing bay",
		Description = "Which bay to fish in. Auto Fishing walks to the dock edge of whichever is loaded",
		Default = "fishingBay",
		Values = LiveCounts.FISH_BAYS,
	})
	pcall(function()
		Options.FishBay = bayDropdown
	end)
end

bindToggle(secFish, { id = "AutoFishing", title = "Auto Fishing", desc = "Travels to the bay, rods up, stands on the dock edge and fishes at the server's own pace", group = "Fishing" }, "fish", fishRunner, 0.1, fishStop)

-- ==================================================================
-- Trees & Axe
-- ==================================================================
local secChop = section("World", "Chopping", "trees")
local worldStatus = secChop:AddParagraph({
	Title = "Status",
	Content = "Idle",
})

local zoneKeys = {}
for k in pairs(TreesList) do
	if type(k) == "string" then
		zoneKeys[#zoneKeys + 1] = k
	end
end
table.sort(zoneKeys)

local zonesDropdown = secChop:AddDropdown("ChopZones", {
	Title = "Tree zones",
	Description = "Which tree zones Auto Chop visits (empty = all)",
	Values = zoneKeys,
	Multi = true,
	Default = {},
})
pcall(function()
	Options.ChopZones = zonesDropdown
end)

bindToggle(secChop, { id = "AutoChopTrees", title = "Auto Chop Trees", desc = "Teleports to trees and chops them in the selected zones", group = "Chop" }, "chop", chopRunner, 0.5)
bindToggle(secChop, { id = "AutoFarmAxe", title = "Farm axe materials", desc = "Chops only the wood zones needed to buy your next axe", group = "Chop" }, "axeFarm", axeFarmRunner, 0.5)
bindToggle(secChop, { id = "AutoUpgradeAxe", title = "Auto Upgrade Axe", desc = "Buys the next axe once you hold its materials", group = "Chop" }, "axeUp", axeUpgradeRunner, 1)

-- Held on the Garden table rather than a top-level local: this file sits at
-- Luau's 200-register cap, so one extra local is the difference between the hub
-- loading and not. section() is NOT memoised, so it must be called once only.
Garden.sec = section("World", "Seed Farm", "seedling")
Garden.status = Garden.sec:AddParagraph({
	Title = "Seed farm status",
	Content = "Idle",
})
bindToggle(
	Garden.sec,
	{ id = "AutoSeedFarm", title = "Auto seed farm", desc = "Harvests grown plants and plants your best seed into every empty garden (Sky Garden)", group = "Garden" },
	"garden",
	function(t)
		Garden.run(t)
	end,
	0.6
)

local secMine = section("World", "Mining", "pickaxe")

do
	local oreValues = { "Any" }
	for _, o in ipairs(LiveCounts.MINE_ORE_TYPES) do
		table.insert(oreValues, o)
	end
	local oreDropdown = secMine:AddDropdown("MineOre", {
		Title = "Ores to mine",
		Description = "Pick as many as you want. Nothing picked = any ore",
		Default = {},
		Values = oreValues,
		Multi = true,
	})
	pcall(function()
		Options.MineOre = oreDropdown
	end)

	local roomValues = { "Any" }
	for _, r in ipairs(LiveCounts.MINE_ROOM_IDS) do
		table.insert(roomValues, r)
	end
	local roomDropdown = secMine:AddDropdown("MineRoom", {
		Title = "Mine rooms",
		Description = "Pick as many rooms as you want. Nothing picked = any room",
		Default = {},
		Values = roomValues,
		Multi = true,
	})
	pcall(function()
		Options.MineRoom = roomDropdown
	end)
end

bindToggle(secMine, { id = "AutoMine", title = "Auto Mine", desc = "Travels to the mine, teleports to matching ores and mines them with your pickaxe", group = "Mine" }, "mine", mineRunner, 0.5)

-- ==================================================================
-- Rewards
-- ==================================================================
local secRewards = section("Rewards", "Rewards", "gift")
local rewardStatus = secRewards:AddParagraph({
	Title = "Status",
	Content = "Idle",
})

bindToggle(secRewards, { id = "AutoClaimRewards", title = "Auto Claim Rewards", desc = "Claims achievements, playtime and daily rewards as soon as they are ready", group = "Rewards" }, "rewards", rewardRunner, 3)
bindToggle(secRewards, { id = "AutoChests", title = "Auto claim chests", desc = "Claims every world chest and mini chest off cooldown", group = "Rewards" }, "chests", chestRunner, 2)

-- ==================================================================
-- Machines
-- ==================================================================
local secAuras = section("Machines", "Auras", "sparkles")
local machineStatus = secAuras:AddParagraph({
	Title = "Status",
	Content = "Idle",
})

do
	local diceValues = {}
	local dData = getData()
	for _, e in pairs(dData and dData.inventory and dData.inventory.auraDice or {}) do
		if type(e) == "table" and e.nm then
			diceValues[#diceValues + 1] = tostring(e.nm) .. "  (" .. suffix(e.am or 0) .. ")"
		end
	end
	table.sort(diceValues)
	if #diceValues == 0 then
		diceValues = { "auraDice  (0)" }
	end
	-- Multi, because the aura runner can rotate: with several dice selected
	-- it works through whichever one it can still afford, instead of stopping
	-- the moment the first choice runs dry.
	local diceDropdown = secAuras:AddDropdown("AuraDice", {
		Title = "Aura dice",
		Description = "Pick as many dice as you want (count shown). Rolls whichever you can still afford",
		Default = {},
		Values = diceValues,
		Multi = true,
	})
	pcall(function()
		Options.AuraDice = diceDropdown
	end)
end

bindPlainToggle(secAuras, "AuraAutoSecret", {
	Title = "Fall back to secret dice",
	Description = "Use secretAuraDice when the chosen dice runs out",
	Default = false,
})

bindToggle(secAuras, { id = "AutoRollAuras", title = "Auto roll auras", desc = "Rolls the chosen dice as fast as the server allows", group = "Auras" }, "auras", auraRunner, 0.2)

-- ------------------------------------------------------------------
-- live counts for the dice and orb dropdowns
--
-- Both dropdowns bake the owned count into the row label ("auraDice  (12)")
-- but the label was built once at load, so a stale count sits there until a
-- reload. Worse, the runners parse the name back out of the label
-- (diceValueName / the "  (" split), so the count has to stay in the label.
--
-- The catch is that SetValues rebuilds the option list, which throws away the
-- current selection. So the selection is captured first, by BASE NAME (the part
-- before the "  (" marker), then restored by matching each new label's base
-- name against what was selected. Anything the user has not picked stays
-- unpicked, and a selection that no longer exists is simply dropped.
--
-- One table so this costs a single register.
-- ------------------------------------------------------------------
-- LiveCounts.skinsLine holds the "Tap skins owned" Paragraph, rewritten in place by
-- tick. Declared on the table so this costs no extra top-level register.
LiveCounts.skinsLine = nil

-- snapshot which base names are currently selected on a Multi dropdown
function LiveCounts.capture(dropdown)
	local ok, v = pcall(function()
		return dropdown and dropdown.Value
	end)
	local sel = {}
	if ok and type(v) == "table" then
		for label, on in pairs(v) do
			if on then
				-- strip the "  (count)" suffix so a selection survives a count
				-- change: the same base name is selected before and after
				if type(label) == "string" then
					local i = string.find(label, "  (", 1, true)
					sel[(i and label:sub(1, i - 1)) or label] = true
				end
			end
		end
	end
	return sel
end

-- republish `values` on `dropdown`, keeping the selection by base name
function LiveCounts.apply(dropdown, values)
	if type(dropdown) ~= "table" then
		return false
	end
	local sel = LiveCounts.capture(dropdown)
	local ok = pcall(function()
		dropdown:SetValues(values)
	end)
	if not ok then
		return false
	end
	-- Multi dropdowns store a set; rebuild it from the captured names
	local restored = {}
	local matched = 0
	for _, label in ipairs(values) do
		local i = string.find(label, "  (", 1, true)
		local base = (i and label:sub(1, i - 1)) or label
		if sel[base] then
			restored[label] = true
			matched += 1
		end
	end
	pcall(function()
		dropdown:SetValue(restored)
	end)
	return matched > 0
end

-- build "name  (count)" rows from an inventory section
local function inventoryCounts(section)
	local counts = {}
	if type(section) ~= "table" then
		return counts
	end
	for _, e in pairs(section) do
		if type(e) == "table" and e.nm then
			counts[tostring(e.nm)] = e.am or 0
		end
	end
	return counts
end

-- Refresh both dropdowns if any count moved since last tick. Returns true when
-- something was actually rewritten, so the caller can skip the work otherwise.
function LiveCounts.tick(data, last)
	local d = data or getData()
	if not d or not d.inventory then
		return false
	end
	last = last or {}
	local changed = false

	-- aura dice
	local dice = d.inventory.auraDice
	if type(dice) == "table" then
		local rows, sig = {}, {}
		for _, e in pairs(dice) do
			if type(e) == "table" and e.nm then
				local nm = tostring(e.nm)
				local am = e.am or 0
				sig[nm] = am
				rows[#rows + 1] = nm .. "  (" .. suffix(am) .. ")"
			end
		end
		table.sort(rows)
		if #rows == 0 then
			rows = { "auraDice  (0)" }
			sig = { auraDice = 0 }
		end
		local moved = last.diceSig == nil
		if not moved then
			for nm, am in pairs(sig) do
				if last.diceSig[nm] ~= am then
					moved = true
					break
				end
			end
			for nm in pairs(last.diceSig) do
				if sig[nm] == nil then
					moved = true
					break
				end
			end
		end
		if moved then
			last.diceSig = sig
			if LiveCounts.apply(Options.AuraDice, rows) then
				changed = true
			end
		end
	end

	-- tap orbs: the row set is every orb the game knows about, so a count of 0
	-- still shows (that is how you see what you do not own yet)
	local orbs = d.inventory.tapOrb
	if type(orbs) == "table" then
		local counts = inventoryCounts(orbs)
		local rows, sig = {}, {}
		local okOrbs, TapOrbsList = pcall(function()
			return require(ReplicatedStorage.Shared.List.Items.TapOrbs)
		end)
		if okOrbs and type(TapOrbsList) == "table" then
			for orbName in pairs(TapOrbsList) do
				local nm = tostring(orbName)
				local am = counts[nm] or 0
				sig[nm] = am
				rows[#rows + 1] = nm .. "  (" .. suffix(am) .. ")"
			end
			table.sort(rows)
			local moved = last.orbSig == nil
			if not moved then
				for nm, am in pairs(sig) do
					if last.orbSig[nm] ~= am then
						moved = true
						break
					end
				end
			end
			if moved and #rows > 0 then
				last.orbSig = sig
				if LiveCounts.apply(Options.TapOrbSelect, rows) then
					changed = true
				end
			end
		end
	end

	-- tap skins owned line
	if LiveCounts.skinsLine then
		local sig = {}
		local names = {}
		for _, e in pairs(d.inventory.tapSkin or {}) do
			if type(e) == "table" and e.nm then
				local nm = tostring(e.nm)
				sig[nm] = e.am or 0
				names[#names + 1] = nm
			end
		end
		local moved = last.skinSig == nil
		if not moved then
			for nm, am in pairs(sig) do
				if last.skinSig[nm] ~= am then
					moved = true
					break
				end
			end
		end
		if moved then
			last.skinSig = sig
			table.sort(names)
			local rows = {}
			for _, nm in ipairs(names) do
				rows[#rows + 1] = nm .. "  (" .. suffix(sig[nm]) .. ")"
			end
			pcall(function()
				if #rows == 0 then
					LiveCounts.skinsLine:SetDesc("none owned yet")
				else
					LiveCounts.skinsLine:SetDesc(table.concat(rows, ", "))
				end
			end)
			changed = true
		end
	end

	return changed
end

local secTap = section("Machines", "Tap Skins", "hand")
do
	local TapOrbsList = require(ReplicatedStorage.Shared.List.Items.TapOrbs)
	local tapOrbValues = {}
	local orbCount = {}
	local dData = getData()
	for _, e in pairs(dData and dData.inventory and dData.inventory.tapOrb or {}) do
		if type(e) == "table" and e.nm then
			orbCount[tostring(e.nm)] = e.am or 0
		end
	end
	for orbName in pairs(TapOrbsList) do
		-- same "name  (count)" format the aura dice dropdown uses, so the two
		-- read the same way
		tapOrbValues[#tapOrbValues + 1] = orbName .. "  (" .. suffix(orbCount[orbName] or 0) .. ")"
	end
	table.sort(tapOrbValues)

	-- the skins you actually own, with counts - the aura section has no
	-- equivalent, so this is the tap-skin answer to "how many do I have".
	-- Kept as a handle so LiveCounts.tick can rewrite it in place; SetDesc is
	-- the only mutator a Paragraph exposes (SetContent throws in this build).
	local owned = {}
	for _, e in pairs(dData and dData.inventory and dData.inventory.tapSkin or {}) do
		if type(e) == "table" and e.nm then
			owned[#owned + 1] = tostring(e.nm) .. "  (" .. suffix(e.am or 0) .. ")"
		end
	end
	table.sort(owned)
	if #owned == 0 then
		owned = { "none owned yet" }
	end
	LiveCounts.skinsLine = secTap:AddParagraph({
		Title = "Tap skins owned",
		Content = table.concat(owned, ", "),
	})

	-- Multi: opens whichever picked orb it can still afford, rotating through
	-- the list so one running out does not end the toggle.
	local tapOrbDropdown = secTap:AddDropdown("TapOrbSelect", {
		Title = "Tap orbs",
		Description = "Pick as many orbs as you want. Opens whichever you can still afford",
		Default = { (tapOrbValues[1] or "basicOrb  (0)") .. " = true" },
		Values = tapOrbValues,
		Multi = true,
	})
	pcall(function()
		Options.TapOrbSelect = tapOrbDropdown
	end)
end

bindToggle(secTap, { id = "AutoRollTapSkins", title = "Auto roll tap skins", desc = "Opens tap orbs back to back - the server accepts one roll every ~2s", group = "TapSkins" }, "tapSkins", tapSkinRunner, 0.1, tapSkinStop)

local secPets = section("Machines", "Pet Crafting", "paw-print")
secPets:AddParagraph({
	Title = "How it works",
	Content = "Each machine consumes 5 copies of a pet to make one at the next tier. Chain them in order for the best result: Normal -> Golden -> Toxic -> Galaxy -> Rainbow.",
})

-- Live readout. Crafting was working with nothing on screen to prove it, so it
-- read as broken. This shows the real per-tier counts, how many are left to
-- spend, what the last server answer was, and the rainbow shard balance.
LiveCounts.craftStatus = secPets:AddParagraph({
	Title = "Craft status",
	Content = "Idle",
})

bindToggle(secPets, { id = "AutoCraftGolden", title = "Craft Golden pets", desc = "Craft-all on every Normal pet, every pass", group = "Pets" }, "craftGolden", function(t)
	petCraftRunner(t, "golden")
end, 0.2)
bindToggle(secPets, { id = "AutoCraftToxic", title = "Craft Toxic pets", desc = "Craft-all on every Golden pet, every pass", group = "Pets" }, "craftToxic", function(t)
	petCraftRunner(t, "toxic")
end, 0.2)
bindToggle(secPets, { id = "AutoCraftGalaxy", title = "Craft Galaxy pets", desc = "Craft-all on every Toxic pet, every pass", group = "Pets" }, "craftGalaxy", function(t)
	petCraftRunner(t, "galaxy")
end, 0.2)
bindToggle(secPets, { id = "AutoCraftRainbow", title = "Craft Rainbow pets", desc = "Craft-all on every Galaxy pet. Costs rainbow shards", group = "Pets" }, "craftRainbow", function(t)
	petCraftRunner(t, "rainbow")
end, 0.2)

bindToggle(secPets, { id = "AutoEquipBestPets", title = "Auto equip best pets", desc = "Re-equips whenever a better pet shows up, using the game's own multiplier sort", group = "Pets" }, "equipBest", equipBestRunner, 1)

local secMeteors = section("Machines", "Meteors", "meteor")
local meteorStatus = secMeteors:AddParagraph({
	Title = "Meteor status",
	Content = "Idle",
})
bindToggle(secMeteors, {
	id = "AutoMeteor",
	title = "Auto destroy meteors",
	desc = "Walks to a meteorite and spams damage on it during Meteorite Shower",
	group = "Misc",
}, "meteors", meteorRunner, 0.02, meteorStop)
local secMisc = section("Machines", "Other Machines", "cpu")
bindToggle(secMisc, { id = "AutoFarm", title = "Auto buy / upgrade farms", desc = "Buys farms and upgrades them with your gems", group = "Misc" }, "farms", farmRunner, 1.5)
bindToggle(secMisc, { id = "AutoOrbs", title = "Auto collect orbs", desc = "Picks up every orb on the ground instantly", group = "Misc" }, "orbs", orbRunner, 1.5)
HatchHook.sec = section("Webhook", "Hatch notifications", "webhook")
pcall(function()
	Options.HookEnabled = HatchHook.sec:AddToggle("HookEnabled", {
		Title = "Enable notifications",
		Description = "Off = nothing is watched and nothing is sent.",
		Default = false,
	})
	Options.HookUrl = HatchHook.sec:AddInput("HookUrl", {
		Title = "Discord webhook URL",
		Description = "Posts here when a selected rarity lands in your inventory.",
		Placeholder = "https://discord.com/api/webhooks/...",
		Default = "",
	})
	Options.HookRarities = HatchHook.sec:AddDropdown("HookRarities", {
		Title = "Notify on rarity",
		Description = "Only these rarities get posted.",
		Values = HatchHook.RARITIES,
		Multi = true,
		Default = {},
	})
	Options.HookTest = HatchHook.sec:AddButton("HookTest", {
		Title = "Send test message",
		Description = "Posts one test ping immediately. If this shows up, the URL and network are fine and any problem is in detection.",
		Callback = function()
			local url = ""
			pcall(function()
				url = Options.HookUrl and Options.HookUrl.Value or ""
			end)
			if url == "" then
				pcall(function()
					Fluent.Notify({
						Title = "Webhook",
						Content = "No URL set.",
						Style = "Warning",
					})
				end)
				return
			end
			HatchHook.post(
				url,
				HttpService:JSONEncode({
					username = "Rebirth Champions",
					content = ("**Webhook test** - if you can read this, the URL works."):format(),
				})
			)
		end,
	})
end)

do
	-- Which of the three: normal (1 ticket), extra (25), ultra (100).
	-- Held on Circus to save a register; Circus already exists above.
	Circus.sec = section("Machines", "Circus", "ticket")
	Circus.modeDrop = Circus.sec:AddDropdown("CircusMode", {
		Title = "Minigame",
		Description = "Which one to play on repeat. Ultra costs 100 tickets a round, extra 25, normal 1.",
		Values = Circus.MODES,
		Default = "normal",
	})
	pcall(function()
		Options.CircusMode = Circus.modeDrop
	end)
	bindToggle(
		Circus.sec,
		{
			id = "AutoCircus",
			title = "Auto circus minigame",
			desc = "Plays the chosen minigame on repeat until you run out of tickets",
			group = "Circus",
		},
		"circus",
		function(t)
			Circus.run(t)
		end,
		2,
		function()
			-- Stopping properly means clearing the game's own loop flag.
			-- playMinigame(ctl, 2) runs its round loop INSIDE our runner's
			-- coroutine, so setting t.alive=false cannot break out of it - the
			-- loop only exits when it re-reads isAutoPlaying() and finds it
			-- false. Clearing it here is what actually stops the minigame.
			pcall(function()
				local ctl = CircusController or getController("CircusController")
				if ctl then
					ctl:setIsAutoPlaying(false)
					-- isPlaying is a separate flag the controller only clears
					-- itself after a whole round finishes. Without this the
					-- in-flight round keeps spending tickets after the toggle is
					-- off, which is the "it will not stop" symptom.
					if ctl.setIsPlaying then
						ctl:setIsPlaying(false)
					end
				end
			end)
			-- and put the game's own auto-click chance back
			Circus_restoreLuck()
		end
	)
end

bindToggle(secMisc, { id = "AutoSkillTree", title = "Auto buy skill tree", desc = "Buys every affordable skill on the current map's tree", group = "Misc" }, "skillTree", skillTreeRunner, 0.5)

-- ==================================================================
-- Auto Index
--
-- Its own section on the Eggs tab, next to hatching, since it is driven by
-- hatching. The rarity/variant dropdowns live here too.
-- ==================================================================
do
	local secIndex = section("Eggs", "Auto Index", "list-checks")
	if AutoIndex then
		-- capture the real error rather than a bare "build failed": this pcall
		-- used to swallow the message, which is why a build that never ran
		-- looked like a working feature with dead toggles
		local okBuild, buildErr = pcall(function()
			AutoIndex.build(secIndex, Options, {
				getData = getData,
				notify = notify,
				hatchEgg = AutoIndex.hatchEgg,
				craftOne = AutoIndex.craftOne,
				bindToggle = bindToggle,
			})
		end)
		if not okBuild then
			rawset(_G, "__RCU_INDEX_ERROR", tostring(buildErr))
			pcall(function()
				secIndex:AddParagraph({
					Title = "Auto Index",
					Content = "Could not build: " .. tostring(buildErr):sub(1, 160),
				})
			end)
		end
	else
		pcall(function()
			secIndex:AddParagraph({
				Title = "Auto Index",
				Content = "Module not loaded (see __RCU_EGG_INDEX_SRC).",
			})
		end)
	end
end

-- ==================================================================
-- Settings: auto save
-- ==================================================================
-- SaveManager already builds its own config section, but it only writes when
-- you press its Save button. Nothing here ever pressed it, so a hub reload
-- (or a crash, or a rejoin) silently threw away every toggle. Two safety nets:
--   - a rolling ticker, so a crash between saves loses at most one interval
--   - save on the way out, via teardown, so a clean stop is never lost
-- A plain file backup is written too, since SaveManager lives in the executor's
-- storage and that can be wiped independently of this script.
local AUTOSAVE_ENABLED = true
LiveCounts.AUTOSAVE_INTERVAL = 30
local AUTOSAVE_KEY = "rcu_hub_autosave.json"

local function optionSnapshot()
	local snap = {}
	for id, opt in pairs(Options) do
		local ok, v = pcall(function()
			return opt.Value
		end)
		if ok then
			-- Multi dropdowns store a set, which json cannot hold as an array
			if type(v) == "table" then
				local keys = {}
				for k in pairs(v) do
					if type(k) == "string" then
						keys[#keys + 1] = k
					end
				end
				table.sort(keys)
				snap[id] = keys
			else
				snap[id] = v
			end
		end
	end
	return snap
end

local function saveAllSettings()
	if not AUTOSAVE_ENABLED then
		return
	end
	if SaveManager then
		pcall(function()
			SaveManager:Save()
		end)
	end
	-- our own copy, readable even if SaveManager's storage is gone
	pcall(function()
		writefile(AUTOSAVE_KEY, game:GetService("HttpService"):JSONEncode(optionSnapshot()))
	end)
end

local function loadAllSettings()
	if SaveManager then
		pcall(function()
			SaveManager:LoadConfig()
		end)
		-- NOTE: deliberately NO early return here.
		--
		-- This used to `return` as soon as SaveManager:LoadConfig() succeeded,
		-- which meant the autosave file below was never read for any account
		-- that has SaveManager. SaveManager only knows its own registered
		-- configs and does not include these options, so everything else - the
		-- webhook URL, its toggle, the rarity selection - silently reverted to
		-- defaults on every reload. Both loaders run, SaveManager first, and the
		-- autosave file fills in whatever it does not know about.
	end
	pcall(function()
		local raw = readfile(AUTOSAVE_KEY)
		if type(raw) ~= "string" or raw == "" then
			return
		end
		local snap = game:GetService("HttpService"):JSONDecode(raw)
		if type(snap) ~= "table" then
			return
		end
		for id, v in pairs(snap) do
			local opt = Options[id]
			if opt and pcall(function()
				opt:SetValue(v)
			end) then
				print("[RCU] restored setting: " .. id)
			end
		end
	end)
end

-- ==================================================================
-- Settings
-- ==================================================================
local secGeneral = section("Settings", "General", "settings")
-- not captured in a local: this chunk is one register scope capped at 200 and
-- the toggle's side effect (setting notifyEnabled) is all that is needed.
bindPlainToggle(secGeneral, "ShowNotifications", {
	Title = "Show notifications",
	Description = "Off = the hub never pops the bottom-right toasts",
	Default = false,
	Callback = function(state)
		if state == nil then
			state = Options.ShowNotifications and Options.ShowNotifications.Value
		end
		notifyEnabled = state and true or false
	end,
})

secGeneral:AddButton({
	Title = "Stop everything",
	Description = "Turns every automation off",
	Callback = function()
		for _, id in ipairs(ALL_TOGGLE_IDS) do
			if Options[id] and Options[id].Value then
				pcall(function()
					Options[id]:SetValue(false)
				end)
			end
		end
		notify("Stopped", "All automations are off")
	end,
})

-- ------------------------------------------------------------------
-- remove the hatch animation
--
-- The animation is HatchingController:playEggAnimation, driven by the
-- openEgg remote. It does a lot more than draw eggs: it closes every
-- game frame, hides the HUD, and sets _isHatching = true, which is what
-- makes the game itself refuse input - OpenFrame, OpenSkillTree,
-- ChestController, GardenController and EggController all early-return
-- while isHatching() is true. So "can't use the game UI while hatching"
-- is not just the animation covering the screen, it is the game locking
-- you out on purpose.
--
-- The hatch result comes from the server and is already in the
-- inventory when openEgg fires, so nothing about a hatch depends on
-- this function running. Replacing it with one that touches no GUI state
-- at all is enough. _isHatching never goes true, so the game's own UI
-- stays live and the hub keeps working throughout.
--
-- addPet is deliberately NOT called either. It looked harmless - "just
-- show what you got" - but it is the rest of the animation: it binds a
-- RenderStep (petPositions), spawns a model per pet into workspace.Debris
-- and animates them in and out. At ~2 hatches/s x 23 pets that is ~46
-- models spawning per second, and it is what you were still seeing.
-- The pets are in the inventory either way.
--
-- isHatching() is reported as false while this is on, which is the
-- honest answer: no animation is running.
-- ------------------------------------------------------------------
local SKIP_HATCH_ANIM = false
local origPlayEggAnimation = nil
local origIsHatching = nil

local function restoreHatchAnimation()
	if origPlayEggAnimation and HatchingController then
		pcall(function()
			HatchingController.playEggAnimation = origPlayEggAnimation
		end)
	end
	if origIsHatching and HatchingController then
		pcall(function()
			HatchingController.isHatching = origIsHatching
		end)
	end
	origPlayEggAnimation = nil
	origIsHatching = nil
	SKIP_HATCH_ANIM = false
end

local function installHatchAnimationSkip()
	if SKIP_HATCH_ANIM or not HatchingController then
		return
	end
	local hc = HatchingController
	origPlayEggAnimation = hc.playEggAnimation
	origIsHatching = hc.isHatching

	hc.playEggAnimation = function(_self, _eggName, _pets, _amount, _opts)
		-- nothing at all. The pets are already in the inventory from the
		-- server, and drawing them is the animation we are removing.
		-- Deliberately NOT: addPet, closeAllFrames, hideHUD, setVisible,
		-- toggleTopPlayer, togglePetInfos, setCanOverrideDisplay,
		-- toggleEggLuckCombo, _isHatching, the egg pool, and every wait.
	end

	hc.isHatching = function()
		return false
	end

	-- An earlier version of this called addPet, which left the pet positions
	-- RenderStep bound and _pets populated. Clear both, otherwise the models
	-- keep floating around with nothing driving them out.
	pcall(function()
		RunService:UnbindFromRenderStep("petPositions")
	end)
	pcall(function()
		hc._hasRenderStep = false
	end)
	pcall(function()
		for id, entry in pairs(hc._pets or {}) do
			if type(entry) == "table" and entry.instance then
				pcall(function()
					hc:cleanData(entry)
				end)
			end
			hc._pets[id] = nil
		end
	end)

	SKIP_HATCH_ANIM = true
end

-- Hatch cadence. The interval is the game's own cycle time, 4.11 / hatchSpeed
-- (EggController's autoHatch loop, docId 114 line 683), and that is as fast as
-- a client may open eggs.
--
-- This is deliberately NOT faster than the server's own rate. An earlier
-- version pinned a flat 0.05s and measured "46 pets/s" against the old
-- Basic egg; that number only exists because it fires ~9x faster than the
-- server's cooldown and the excess calls are simply dropped after costing
-- bandwidth and risking a disconnect. Removing the reveal animation is the
-- legitimate win: it stops the game gating input on isHatching() and stops
-- ~46 pet models per second spawning, but it does not buy a rate the server
-- will not honour.
--
-- Note the speed is read through Values.hatchSpeed(player, data), NOT the raw
-- data.upgrades.hatchSpeed counter. On this account the counter reads 17 while
-- Values.hatchSpeed returns 8.83 - the counter is a purchase index and the
-- upgrade list has diminishing returns, so using the raw number as the
-- multiplier understates the real cycle time and fires too slowly.
LiveCounts.HATCH_CYCLE = 4.11

-- One table rather than three locals, for the same register reason.
local Hatch = {}

function Hatch.speed()
	local data = getData()
	if not data then
		return 1
	end
	local ok, v = pcall(function()
		return Values.hatchSpeed(LocalPlayer, data)
	end)
	if ok and type(v) == "number" and v > 0 then
		return v
	end
	return 1
end

function Hatch.interval()
	local base = LiveCounts.HATCH_CYCLE / Hatch.speed()
	-- a floor so a transient bad read cannot turn into a tight loop
	return math.max(base, 0.05)
end

applyHatchInterval = function(t)
	t.cooldown = os.clock() + Hatch.interval()
	t.hatchSpeed = Hatch.speed()
end

bindPlainToggle(secGeneral, "SkipHatchAnimation", {
	Title = "Remove hatch animation",
	Description = "Skips the egg reveal entirely and leaves the game UI usable while hatching",
	Default = true,
	Callback = function(state)
		if state == nil then
			state = Options.SkipHatchAnimation and Options.SkipHatchAnimation.Value
		end
		if state then
			installHatchAnimationSkip()
		else
			restoreHatchAnimation()
		end
	end,
})

secGeneral:AddButton({
	Title = "Apply hatch speed",
	Description = "Re-applies the current hatch interval (for when the animation toggle changes)",
	Callback = function()
		local t = Tasks.hatch
		if t then
			applyHatchInterval(t)
		end
		notify("Hatching", ("Hatch interval: %.2fs (x%.2f speed)"):format(Hatch.interval(), Hatch.speed()))
	end,
})

bindPlainToggle(secGeneral, "AutoSaveSettings", {
	Title = "Auto save settings",
	Description = "Writes every toggle and dropdown to disk every 30s and on exit",
	Default = true,
	Callback = function(state)
		if state == nil then
			state = Options.AutoSaveSettings and Options.AutoSaveSettings.Value
		end
		AUTOSAVE_ENABLED = state and true or false
	end,
})

secGeneral:AddButton({
	Title = "Save settings now",
	Description = "Forces an immediate write of every setting",
	Callback = function()
		saveAllSettings()
		notify("Settings", "Saved")
	end,
})

secGeneral:AddButton({
	Title = "Load settings",
	Description = "Restores every setting from the last save",
	Callback = function()
		loadAllSettings()
		notify("Settings", "Loaded")
	end,
})

-- Themes go in their own section so they are easy to find, and a failure
-- here must not take the rest of Settings with it.
pcall(function()
	local secTheme = section("Settings", "Themes", "palette")
	Themes_build(secTheme, Options)
end)

local secSafety = section("Settings", "Safety", "shield")
bindToggle(secSafety, { id = "AntiAfk", title = "Anti-AFK", desc = "Wiggles your character every ~25s when idle so you never get kicked", group = "Safety" }, "afk", antiAfkRunner, 5)
bindToggle(secSafety, { id = "AutoRespawn", title = "Auto Respawn", desc = "Instantly respawns if you die so automation never stops", group = "Safety" }, "respawn", respawnRunner, 2)

if SaveManager then
	pcall(function()
		SaveManager:SetLibrary(Fluent)
		SaveManager:IgnoreThemeSettings()
		SaveManager:SetIgnoreIndexes({})
		SaveManager:SetFolder("FluentRCU/RebirthChampions")
	end)
end
if InterfaceManager then
	pcall(function()
		InterfaceManager:SetLibrary(Fluent)
		InterfaceManager:SetFolder("FluentRCU")
	end)
end
if InterfaceManager then
	pcall(function()
		InterfaceManager:BuildInterfaceSection(Tabs.Settings)
	end)
end
if SaveManager then
	pcall(function()
		SaveManager:BuildConfigSection(Tabs.Settings)
	end)
end

-- ------------------------------------------------------------------
-- status ticker
-- ------------------------------------------------------------------
coroutine.wrap(function()
	local stage = "start"
	-- last-seen counts for the dice / orb / skin dropdowns, so tick only
	-- rewrites a dropdown when a number actually moved
	local liveCountState = {}
		pcall(function()
			stage = "egg"
			stage = "rebirth"
			stage = "fall"
			stage = "rake"
			stage = "world"
			stage = "rewards"
		end)
		while not Fluent.Unloaded and not stopped do
			stage = "tick"
			local ok, err = pcall(function()
			local data = getData()
			if not data then
				return
			end
			-- Hatch webhook. This MUST stay the first statement in the ticker pcall.
			-- The whole ticker body is one pcall, so an error thrown anywhere above
			-- silently skips every statement after it. This block used to sit down by
			-- the machines section and never ran at all - an unrelated error higher up
			-- aborted the pcall first, so ticks stayed at 0 and nothing was posted.
			-- Right after the data guard, nothing has had a chance to throw yet.
			-- hatch webhook: diff the pet inventory and post anything new whose
			-- rarity is selected. Runs off the same 1s ticker, no extra task.
			pcall(function()
			local enabled = false
			pcall(function()
			enabled = Options.HookEnabled and Options.HookEnabled.Value == true
			end)
			local url = ""
			pcall(function()
			url = Options.HookUrl and Options.HookUrl.Value or ""
			end)
			
			if not enabled then
			-- keep the baseline fresh anyway, so turning it on later does
			-- not report a backlog of every pet already owned
			HatchHook.why = "toggle is OFF"
			HatchHook.skipped += 1
			HatchHook.tick(data, nil, nil)
			return
			end

			local set = {}
			pcall(function()
			local v = Options.HookRarities and Options.HookRarities.Value
			if type(v)=="table" then
			for r,on in pairs(v) do
			if on then
			set[tostring(r)]=true
			end
			end
			end
			end)

			if next(set)==nil then
			HatchHook.why="no rarities selected"
			HatchHook.skipped += 1
			HatchHook.tick(data, nil, nil)
			return
			end
			if type(url)~="string" or url=="" then
			HatchHook.why="no URL set"
			HatchHook.skipped += 1
			HatchHook.tick(data, nil, nil)
			return
			end

			HatchHook.why = "watching"
			local before = #HatchHook.log
			HatchHook.tick(data, set, url)
			if #HatchHook.log > before then
				HatchHook.why = "POSTED"
			end
			end)
			stage = "egg"
			local egg = eggValueName(Options.EggSelect and Options.EggSelect.Value or "?")
			-- read the real speed through Values, not the raw upgrade counter
			local speed = Hatch.speed()
			local interval = Hatch.interval()
			eggStatus:SetDesc(
				string.format(
					"Egg: %s | in range: %s | hatching: %s | cycle: %.2fs (x%.2f) | anim off: %s",
					tostring(egg),
					tostring(EggController and EggController._currentEgg == egg),
					tostring(HatchingController and HatchingController:isHatching()),
					interval,
					speed,
					tostring(SKIP_HATCH_ANIM)
				)
			)

			stage = "rebirth"
			local cap = unlockedRebirthCap(data)
			local target = highestUnlockedRebirth(data)
			local affordable = target and data.clicks >= rebirthCost(Rebirths[target], data)
			rebirthStatus:SetDesc(
				string.format(
					"Unlocked up to #%d | Target: %s | Clicks: %s | Ready: %s",
					cap,
					target and ("#" .. target) or "none",
					suffix(data.clicks),
					tostring(affordable)
				)
			)

			stage = "fall"
			local tierNum = (data.fallRebirths or 0) + 1
			local nextTier = FallRebirths[tierNum]
			local treeIdx = math.min((data.fallHarvestTreeRebirths or 0) + 1, #HarvestTree.rebirths)
			local treeTier = HarvestTree.rebirths[treeIdx]
			local treeLevel = 0
			local okLevel, lv = pcall(function()
				return Util.fallUtils.getLevelFromXp(data.fallHarvestTreeXp or 0)
			end)
			if okLevel then
				treeLevel = lv
			end
			local levels = data.fallUpgrades or {}
			local bought = 0
			for key in pairs(LeavesMachine) do
				bought += levels[key] or 0
			end
			fallStatus:SetDesc(
				string.format(
					"Acorns: %s | Fall rebirth: %s | Tree: level %d (needs %d) | Leaves upgrades: %d",
					suffix(itemAmount(data, "acorns")),
					nextTier and ("#" .. tierNum) or "maxed",
					treeLevel,
					treeTier and treeTier.maxLevel or 0,
					bought
				)
			)

			stage = "rake"
			local rakeIdx = currentRakeIndex(data)
			rakeStatus:SetDesc(
				string.format(
					"Rake: %s/%d | Auto rake: %s | Auto upgrade: %s",
					rakeIdx and tostring(rakeIdx) or "?",
					totalRakes(),
					tostring(isRunning("rakeFarm")),
					tostring(isRunning("rakeFarmUp"))
				)
			)

			stage = "meteor"
			local mt = Tasks.meteors
			meteorStatus:SetDesc(
				("Auto meteor: %s | %s"):format(
					tostring(isRunning("meteors")),
					(mt and mt.targetDesc) or "no meteor in range"
				)
			)

			stage = "world"
			local axeName, axeIdx = currentAxeIndex(data)
			worldStatus:SetDesc(
				string.format(
					"Axe: %s (idx %s) equipped: %s | chopping: %s",
					tostring(axeName),
					tostring(axeIdx),
					tostring(data.isAxeEquipped),
					tostring(isRunning("chop"))
				)
			)

			stage = "rewards"
			local ready = 0
			for id, def in pairs(AchievementsList) do
				local idx = 1
				for k in pairs(data.claimedAchievements or {}) do
					if k:find(id, 1, true) then
						idx += 1
					end
				end
				local tier = def.list[idx]
				if tier then
					local okV, val = pcall(def.getValue, data)
					if okV and val and val >= tier.amount then
						ready += 1
					end
				end
			end
			rewardStatus:SetDesc(
				string.format(
					"Claimable achievements: %d | playtime timer: %s | claiming: %s | chests: %s",
					ready,
					suffix(data.playtimeRewardTimer or 0),
					tostring(isRunning("rewards")),
					tostring(isRunning("chests"))
				)
			)

			stage = "machines"
			-- Re-assert the window's parent every tick.
			--
			-- Something in the game detaches Fluent's ScreenGui after load, and a
			-- parentless ScreenGui renders nothing while every toggle keeps
			-- working - which is exactly what "the script is not executing"
			-- looked like, twice. Re-asserting it here means the window comes
			-- back within a second instead of needing a reload, and the fix
			-- survives whatever detaches it.
			pcall(function()
				-- go through getgenv rather than the local Window: this runs from
				-- the status ticker, and reaching the window that way has proven
				-- reliable. Unconditional, because a parentless ScreenGui renders
				-- nothing at all while every toggle keeps working - which is
				-- exactly what "the script is not executing" looked like, twice.
				local fl = getgenv and getgenv().Fluent
				local r = fl and fl.Window and fl.Window.Root
				local g = r and r.Parent
				if g and g:IsA("ScreenGui") then
					if g.Parent == nil then
						g.Parent = game:GetService("CoreGui")
					end
					pcall(function()
						g.DisplayOrder = 1000
					end)
					pcall(function()
						g.ResetOnSpawn = false
					end)
					pcall(function()
						g.IgnoreGuiInset = true
					end)
					pcall(function()
						r.ZIndex = 1000
					end)
				end
			end)
			-- craft readout: proves the machine is doing something, and shows
			-- the shard balance so Rainbow cannot drain unnoticed
			pcall(function()
				if LiveCounts.craftStatus then
					local tiers, parts = {}, {}
					local function tc(n)
						local s = 0
						for _, e in pairs(data.inventory.pet or {}) do
							if (e.ti or 1) == n then
								s = s + (e.am or 0)
							end
						end
						return s
					end
					for _, n in ipairs({ 1, 2, 3, 4, 5 }) do
						tiers[n] = tc(n)
					end
					local pend = {}
					for _, k in ipairs({ "craftGolden", "craftToxic", "craftGalaxy", "craftRainbow" }) do
						local tt = Tasks[k]
						local key = ({ craftGolden = 2, craftToxic = 3, craftGalaxy = 4, craftRainbow = 5 })[k]
						if tt then
							local g = petIdGroupsForTier(data, key)
							local ready = 0
							for _, grp in ipairs(g) do
								ready += 1
							end
							pend[#pend + 1] = ("%s:%d pets/%d stacks"):format(
								(({ craftGolden = "G", craftToxic = "T", craftGalaxy = "X", craftRainbow = "R" })[k]),
								tiers[key],
								ready
							)
							if tt.lastReject then
								pend[#pend + 1] = ("last=%s"):format(tostring(tt.lastReject))
							elseif tt.toldNoShards then
								pend[#pend + 1] = "out of shards"
							end
						end
					end
					local shards = 0
					pcall(function()
						shards = itemAmount(data, "rainbowShard")
					end)
					parts[#parts + 1] = ("N%s G%s T%s X%s R%s"):format(
						suffix(tiers[1]), suffix(tiers[2]), suffix(tiers[3]), suffix(tiers[4]), suffix(tiers[5]))
					if #pend > 0 then
						parts[#pend + 1] = table.concat(pend, " ")
					end
					parts[#parts + 1] = ("rainbow shards: %s"):format(suffix(shards))
					LiveCounts.craftStatus:SetDesc(table.concat(parts, " | "))
				end
			end)
			-- refresh the dice / orb / tap-skin counts. Every 1s with the rest
			-- of the ticker: fast enough that a roll's cost shows up as it
			-- happens, cheap enough that SetValues is not called constantly.
			pcall(function()
				LiveCounts.tick(data, liveCountState)
			end)
			machineStatus:SetDesc(
				string.format(
					"Gems: %s | farms: %s | aura dice: %s | auras: %s",
					suffix(data.gems or 0),
					tostring(isRunning("farms")),
					tostring((function()
						local picked = selectedSet(Options.AuraDice)
						if not picked then
							return "none"
						end
						local names = {}
						for x in pairs(picked) do
							table.insert(names, diceValueName(x))
						end
						table.sort(names)
						return table.concat(names, ", ")
					end)()),
					tostring(isRunning("auras"))
				)
			)
		end)
		if not ok and not Fluent.Unloaded and not stopped then
			warn("[RCU] status[" .. stage .. "]: " .. tostring(err))
		end
		task.wait(1)
	end
end)()

-- ------------------------------------------------------------------
-- teardown
-- ------------------------------------------------------------------
-- Surface a failed UI build even though print/warn are silenced, so a broken
-- tab is diagnosable instead of silently rendering empty.
rawset(_G, "__RCU_UI_ERROR", LiveCounts.uiOk and nil or tostring(LiveCounts.uiErr))

local function teardown()
	if stopped then
		return
	end
	stopped = true
	stopAll()
	table.clear(REGISTRY.tasks)
	-- put the game's hatch animation back, or a reload would leave the
	-- controller permanently replaced
	pcall(restoreHatchAnimation)
	-- write on the way out, so a clean stop never loses the settings
	pcall(saveAllSettings)
	pcall(function()
		Fluent:Destroy()
	end)
end

table.insert(REGISTRY.cleanups, teardown)
rawset(_G, "__RCU_HUB", { stop = teardown })
print("[RCU] done")

if STATE and type(STATE.onCleanup) == "function" then
	STATE.onCleanup(teardown)
end

if SaveManager then
	pcall(function()
		SaveManager:LoadAutoloadConfig()
	end)
end
-- AutoloadConfig only handles SaveManager's own file. Our JSON backup covers
-- the case where SaveManager was not there or its store was wiped.
loadAllSettings()

-- Fluent does not reliably fire a toggle's Callback for its Default value, so
-- apply the two settings that patch game state explicitly. Doing it after the
-- settings load means a restored preference wins over the default.
pcall(function()
	if Options.SkipHatchAnimation and Options.SkipHatchAnimation.Value then
		installHatchAnimationSkip()
	else
		restoreHatchAnimation()
	end
end)
pcall(function()
	AUTOSAVE_ENABLED = not (Options.AutoSaveSettings and Options.AutoSaveSettings.Value == false)
end)

-- rolling save, so a crash or a disconnect loses at most one interval
task.spawn(function()
	while not stopped and not Fluent.Unloaded do
		task.wait(LiveCounts.AUTOSAVE_INTERVAL)
		if stopped or Fluent.Unloaded then
			break
		end
		saveAllSettings()
	end
end)

Window:SelectTab(1)

-- Make sure the window actually renders.
--
-- Observed on this account: Fluent created its ScreenGui but left it with a NIL
-- parent, so the whole hub existed, every toggle worked and every task ran -
-- and nothing was visible on screen at all. A parentless ScreenGui never
-- renders, which is why "the script is not executing" looked identical to
-- "the script is broken". Its ZIndex was also 1, below the game's own UI.
--
-- CoreGui is the right parent here: it always renders, survives respawns, and
-- draws above the PlayerGui the game uses for its HUD and menus. Repair this on
-- every load so it cannot regress.
pcall(function()
	local root = Window.Root
	local gui = root and root.Parent
	-- A ScreenGui with a nil parent never renders at all. Observed twice on
	-- this account: the hub was fully alive (every toggle worked, tasks
	-- running, no errors) and completely invisible, which looks exactly like
	-- the script not executing. Fluent hands the ScreenGui over and something
	-- later detaches it, so this is deliberately UNCONDITIONAL - guarding on
	-- "parent == nil" was skipping the fix on load and the window vanished
	-- again on the next reload.
	if gui and gui:IsA("ScreenGui") then
		gui.Parent = game:GetService("CoreGui")
		pcall(function()
			gui.ResetOnSpawn = false
		end)
		pcall(function()
			gui.IgnoreGuiInset = true
		end)
		pcall(function()
			gui.DisplayOrder = 1000
		end)
	end
	if root then
		pcall(function()
			root.ZIndex = 1000
		end)
	end
end)

notify("Rebirth Champions", "Hub loaded. Right Shift minimizes the window.")

task.spawn(function()
	local data = getData()
	if not data or not Util or not Util.eggUtils then
		return
	end
	local priced = { LiveCounts.NEAREST_EGG }
	for _, name in ipairs(eggNames) do
		local cost, cur = "-", ""
		local okc, c = pcall(function()
			return Util.eggUtils.getEggCost(LocalPlayer, data, name, {})
		end)
		if okc then
			cost = suffix(math.floor(tonumber(c) or 0))
		end
		local okcur, cur2 = pcall(function()
			return Util.eggUtils.getCurrency(name, {})
		end)
		if okcur then
			cur = tostring(cur2)
		end
		priced[#priced + 1] = name .. "  |  " .. cost .. (cur ~= "" and (" " .. cur) or "")
	end
	pcall(function()
		Options.EggSelect:SetValues(priced)
	end)
end)
end, debug.traceback)














































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































