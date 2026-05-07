local folder, core = ...

local P
local playerGUID
local Debug = core.Debug
local guidBuffs = core.guidBuffs
local nametoGUIDs = core.nametoGUIDs
local _

local bit_band = bit.band
local GetTime = GetTime
local table_insert = table.insert
local table_remove = table.remove

local GetSpellInfo = GetSpellInfo
local UnitGUID = UnitGUID
local wipe = core.wipe
local acquireTable = core.acquireTable

local COMBATLOG_OBJECT_TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x00000400
local COMBATLOG_OBJECT_REACTION_FRIENDLY = COMBATLOG_OBJECT_REACTION_FRIENDLY or 0x00000010
local COMBATLOG_OBJECT_REACTION_HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x00000040

local iconCache = {}
local function GetCleanIcon(texture)
	if not texture then return "" end
	local cached = iconCache[texture]
	if cached then
		return cached
	end
	local cleaned = texture:upper():gsub("INTERFACE\\ICONS\\", "")
	iconCache[texture] = cleaned
	return cleaned
end

local LibAI = LibStub("LibAuraInfo-1.0", true)
if not LibAI then
	error(folder .. " requires LibAuraInfo-1.0.")
	return
end

do
	local UnitGUID = UnitGUID
	local prev_OnEnable = core.OnEnable
	function core:OnEnable()
		prev_OnEnable(self)
		P = self.db.profile
		playerGUID = UnitGUID("player")
		core:RegisterLibAuraInfo()
	end
end

do
	local CombatLogClearEntries = CombatLogClearEntries
	function core:RegisterLibAuraInfo()
		LibAI.UnregisterAllCallbacks(self)
		if P.watchCombatlog == true then
			LibAI.RegisterCallback(self, "LibAuraInfo_AURA_APPLIED")
			LibAI.RegisterCallback(self, "LibAuraInfo_AURA_REMOVED")
			LibAI.RegisterCallback(self, "LibAuraInfo_AURA_REFRESH")
			LibAI.RegisterCallback(self, "LibAuraInfo_AURA_APPLIED_DOSE")
			LibAI.RegisterCallback(self, "LibAuraInfo_AURA_CLEAR")

			CombatLogClearEntries()
		end
	end
end

do
	local prev_OnDisable = core.OnDisable
	function core:OnDisable(...)
		if prev_OnDisable then
			prev_OnDisable(self, ...)
		end
		LibAI.UnregisterAllCallbacks(self)
	end
end

function core:FlagIsPlayer(flags)
	return (bit_band(flags, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0)
end

function core:FlagIsFriendly(flags)
	return (bit_band(flags, COMBATLOG_OBJECT_REACTION_FRIENDLY) ~= 0)
end

function core:FlagIsHostle(flags)
	return (bit_band(flags, COMBATLOG_OBJECT_REACTION_HOSTILE) ~= 0)
end

function core:ForceNameplateUpdate(dstGUID)
	if not self:UpdateTargetPlate(dstGUID) and not self:UpdatePlateByGUID(dstGUID) then
		-- We can't find a nameplate that matches that GUID.
		-- Lets check if the GUID is a player, if so find a
		-- nameplate that matches the player's name.
		local dstName, dstFlags = LibAI:GetGUIDInfo(dstGUID)
		if dstFlags and self:FlagIsPlayer(dstFlags) then
			local shortName = self:RemoveServerName(dstName) -- Nameplates don't have server names.
			nametoGUIDs[shortName] = dstGUID
			self:UpdatePlateByName(shortName)
		end
	end
end

function core:AddSpellToGUID(dstGUID, spellID, srcName, spellName, spellTexture, duration, srcGUID, isDebuff, debuffType, expires, stackCount)
	guidBuffs[dstGUID] = guidBuffs[dstGUID] or {}
	if #guidBuffs[dstGUID] > 0 then
		self:RemoveOldSpells(dstGUID)
	end

	local getTime = GetTime()
	local count = #guidBuffs[dstGUID]

	local playerCast = srcGUID == playerGUID and 1
	local expTime = expires or 0 - 0.1
	local durationVal = duration or 0
	local stackVal = stackCount or 0

	if count == 0 then
		local t = acquireTable()
		t.name = spellName
		t.icon = spellTexture
		t.duration = durationVal
		t.playerCast = playerCast
		t.stackCount = stackVal
		t.startTime = getTime
		t.expirationTime = expTime
		t.sID = spellID
		t.caster = srcName

		if isDebuff then
			t.isDebuff = true
			t.debuffType = debuffType or "none"
		end

		table_insert(guidBuffs[dstGUID], t)
		return true
	else
		for i = 1, count do
			if
				guidBuffs[dstGUID][i].sID == spellID and
					(not guidBuffs[dstGUID][i].caster or guidBuffs[dstGUID][i].caster == srcName)
			 then
				guidBuffs[dstGUID][i].expirationTime = expTime
				guidBuffs[dstGUID][i].startTime = getTime
				return true
			elseif i == count then
				local t = acquireTable()
				t.name = spellName
				t.icon = spellTexture
				t.duration = durationVal
				t.playerCast = playerCast
				t.stackCount = stackVal
				t.startTime = getTime
				t.expirationTime = expTime
				t.sID = spellID
				t.caster = srcName

				if isDebuff then
					t.isDebuff = true
					t.debuffType = debuffType or "none"
				end

				table_insert(guidBuffs[dstGUID], t)
				return true
			end
		end
	end
	return false
end

do
	local function CheckFilter(tip, spelllist)
		if tip == "BUFF" then
			return not (spelllist and P.defaultBuffShow == 4)
		elseif tip == "DEBUFF" then
			return not (spelllist and P.defaultDebuffShow == 4)
		end
		return nil
	end

	function core:LibAuraInfo_AURA_APPLIED(event, dstGUID, spellID, srcGUID, spellSchool, auraType)
		if dstGUID == playerGUID then return end

		local found, stackCount, debuffType, duration, expires, isDebuff, casterGUID = LibAI:GUIDAuraID(dstGUID, spellID)

		local spellName, _, spellTexture = GetSpellInfo(spellID)
		local dstName, dstFlags = LibAI:GetGUIDInfo(dstGUID)

		if found then
			spellTexture = GetCleanIcon(spellTexture)

			local updateBars = false
			local srcInfo = LibAI:GetGUIDInfo(srcGUID)
			local spellOpts = core:HaveSpellOpts(spellName, spellID)

			if spellOpts and spellOpts.show and CheckFilter(auraType, true) then
				if
					P.spellOpts[spellName].show == 1 or
					(P.spellOpts[spellName].show == 2 and srcGUID == playerGUID) or
					(P.spellOpts[spellName].show == 4 and core:FlagIsFriendly(dstFlags)) or
					(P.spellOpts[spellName].show == 5 and core:FlagIsHostle(dstFlags))
				then
					updateBars = self:AddSpellToGUID(dstGUID, spellID, srcInfo, spellName, spellTexture, duration, srcGUID, isDebuff, debuffType, expires, stackCount)
				end
			else
				if
					(auraType == "BUFF" and P.defaultBuffShow == 1) or
					((P.defaultBuffShow == 2 and srcGUID == playerGUID) or (P.defaultBuffShow == 4 and srcGUID == playerGUID)) or
					(auraType == "DEBUFF" and P.defaultDebuffShow == 1) or
					((P.defaultDebuffShow == 2 and srcGUID == playerGUID) or (P.defaultDebuffShow == 4 and srcGUID == playerGUID))
				then
					updateBars = self:AddSpellToGUID(dstGUID, spellID, srcInfo, spellName, spellTexture, duration, srcGUID, isDebuff, debuffType, expires, stackCount)
				end
			end

			if updateBars then
				core:ForceNameplateUpdate(dstGUID)
			end
		end
	end
end

function core:LibAuraInfo_AURA_REMOVED(event, dstGUID, spellID, srcGUID, spellSchool, auraType)
	if guidBuffs[dstGUID] and dstGUID ~= playerGUID then
		local srcName = LibAI:GetGUIDInfo(srcGUID)
		for i = #guidBuffs[dstGUID], 1, -1 do
			if guidBuffs[dstGUID][i].sID == spellID and (not guidBuffs[dstGUID][i].caster or guidBuffs[dstGUID][i].caster == srcName) then
				table_remove(guidBuffs[dstGUID], i)
				self:ForceNameplateUpdate(dstGUID)
				return
			end
		end
	end
end

function core:LibAuraInfo_AURA_REFRESH(event, dstGUID, spellID, srcGUID, spellSchool, auraType, expirationTime)
	if dstGUID == playerGUID then return end

	if guidBuffs[dstGUID] then
		local srcName = LibAI:GetGUIDInfo(srcGUID)
		local now = GetTime()
		for i = #guidBuffs[dstGUID], 1, -1 do
			if guidBuffs[dstGUID][i].sID == spellID and (not guidBuffs[dstGUID][i].caster or guidBuffs[dstGUID][i].caster == srcName) then
				guidBuffs[dstGUID][i].startTime = now
				guidBuffs[dstGUID][i].expirationTime = expirationTime
				self:ForceNameplateUpdate(dstGUID)
				return
			end
		end
	end

	local spellName = GetSpellInfo(spellID)
	local dstName = LibAI:GetGUIDInfo(dstGUID)
	if not LibAI:GUIDAuraID(dstGUID, spellID) then
		Debug("SPELL_AURA_REFRESH", LibAI:GUIDAuraID(dstGUID, spellID), dstName, spellName, "passing to SPELL_AURA_APPLIED")
	end
	self:LibAuraInfo_AURA_APPLIED(event, dstGUID, spellID, srcGUID, spellSchool, auraType)
end

function core:LibAuraInfo_AURA_APPLIED_DOSE(event, dstGUID, spellID, srcGUID, spellSchool, auraType, stackCount, expirationTime)
	if guidBuffs[dstGUID] then
		local srcName = LibAI:GetGUIDInfo(srcGUID)
		local now = GetTime()
		for i = #guidBuffs[dstGUID], 1, -1 do
			if guidBuffs[dstGUID][i].sID == spellID and (not guidBuffs[dstGUID][i].caster or guidBuffs[dstGUID][i].caster == srcName) then
				guidBuffs[dstGUID][i].stackCount = stackCount
				guidBuffs[dstGUID][i].startTime = now
				guidBuffs[dstGUID][i].expirationTime = expirationTime
				self:ForceNameplateUpdate(dstGUID)
				return
			end
		end
	end

	local spellName = GetSpellInfo(spellID)
	local dstName = LibAI:GetGUIDInfo(dstGUID)
	if not LibAI:GUIDAuraID(dstGUID, spellID) then
		Debug("LAURA_APPLIED_DOSE", dstName, spellName, "passing to SPELL_AURA_APPLIED")
	end
	self:LibAuraInfo_AURA_APPLIED(event, dstGUID, spellID, srcGUID, spellSchool, auraType)
end

function core:LibAuraInfo_AURA_CLEAR(event, dstGUID)
	if guidBuffs[dstGUID] and dstGUID ~= playerGUID then
		-- Remove all known buffs for that person.
		-- Maybe we're in a BG and don't need their old buffs on our plates.
		wipe(guidBuffs[dstGUID])
		self:ForceNameplateUpdate(dstGUID)
	end
end
