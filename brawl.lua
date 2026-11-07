#version 2
#include "script/include/player.lua"
#include "mplib/hud.lua"
#include "mplib/teams.lua"
#include "mplib/util.lua"
#include "mplib/spectate.lua"
#include "brawl_area.lua"
#include "brawl_view.lua"
#include "brawl_editor.lua"
#include "brawl_knock.lua"
#include "brawl_heal.lua"

-- Brawl: a team fist-fight game mode for any map (gamemodes.txt). With the Combat System mod (Workshop 3822172014,
-- tool "content_combat") enabled everyone fights with bare hands; without it, with weapons (a host setting).
-- Damage counts only inside the fight area (brawl_area.lua: the registry's brawl.area from a map or mod, the map's
-- brawl_area triggers, or the polygon the host draws in the lobby - brawl_editor.lua; none: the whole map): any hit
-- on a player outside, or from an attacker outside, is undone the same tick (a killing blow: respawned on the spot
-- with the old health); so is a hit by a shooter who fired from outside in the last SHOT_FLIGHT s (a projectile in the
-- air). Everyone starts a round at START_HEALTH: after HEAL_DELAY s inside the area without damage, health comes back
-- slowly to full; outside it never rises.
-- Lobby (mplib): 2-4 teams (host), round length, friendly fire, the weapons loadout. Everyone spawns OUTSIDE the
-- area, each team on its own side. Health at 0 inside the area (the fight): KNOCKED DOWN, kneeling in place with chicks
-- circling the head for KNOCK_TIME s, no moving, no tool, a second smaller bar (KNOCK_HP) that only hits drain; it
-- empties: ELIMINATED for the round (spectating); it holds: up again with GETUP_HEALTH. A knockdown scores for the
-- attacker's team, an elimination once more. The round ends when one team (or none) has fighters left, else at the
-- time: the most health left (the summed health of the fighters still in; a knocked one counts 0), then knockdowns,
-- then damage. Combos: 3+ hits by one attacker on one victim, each within
-- COMBO_GAP s. Tab: scoreboard. Results: the teams, the top fighter.
-- Healing shows on every machine: a soft white aura and white crosses rising round the fighter (brawl_heal.lua).
-- Published for maps (host registry): brawl.active, brawl.phase, the event ring brawl.event.* (PROJECT.md).
-- (Every script below only shares GLOBALS with its includes: an included file's locals are its own.)

START_HEALTH = 0.8        -- health at the round's start (the user: an incentive to get in and heal)
HEAL_DELAY = 5            -- s inside the area (in the fight) and without damage before healing starts
HEAL_RATE = 0.04          -- health per second while healing (1 = full)
SHOT_FLIGHT = 3           -- s after a ranged shot fired from OUTSIDE the area during which that shooter's hits (and
                          -- unattributed ones) don't count: a rocket fired outside must not land once they step in
KNOCK_TIME = 10           -- s a knocked-down fighter kneels (the user)
KNOCK_HP = 1.0            -- the knock bar: as big as the health bar (the user; it was 0.35)
GETUP_HEALTH = 1 / 3      -- health when they get up (the user: a third)
KNOCK_EXIT = 0.4          -- s out of the pose before the death (a ragdoll started from the pose was flung: HvC)
KNOCK_PUB = 0.1           -- s between knock-state publishes (shared.brawlKnock)
SPAWN_SIDE = 1.2          -- m between teammates at a spawn
CHICKS = 3                -- chicks round a knocked player's head
CHICK_R = 0.3             -- m: their circle's radius ...
CHICK_UP = 0.3            -- ... this far over the head
CHICK_TURN = 1            -- turns a second
COMBO_GAP = 1.5           -- s at most between two hits of a combo
COMBO_MIN = 3             -- hits that make a combo
VOLLEY = 0.05             -- s: hits closer than this (a shotgun's pellets) are one hit for the combo count
READY_TIME = 3            -- s countdown before the fight (frozen)
GRACE = 0.5               -- s after a respawn / revive: health re-applied, no death detection (the engine reads 0 a frame)
STRIP_EVERY = 2           -- s between tool strips (Combat System on)
COMBAT_TOOL = "content_combat"
RANGED = {sledge = false, [COMBAT_TOOL] = false}   -- tools whose use from outside is NOT a shot (anything else is)
EYE = 0.5                 -- m above the feet: the point tested against the area
TEAMS_OWN_CAMERA = true     -- (mplib/teams.lua: its orbiting lobby camera off - the lobby shows brawl_view.lua's
                             --  cross-section instead)
HUD_SCOREBOARD_KEY = "tab"   -- (mplib/hud.lua: the scoreboard on Tab - the game's "scoreboard" is Shift, the Combat
                             --  System's sprint)
EVENT_RING = 16

TEAM_NAMES = {"Red", "Blue", "Green", "Gold"}
TEAM_COLORS = {{0.92, 0.22, 0.16}, {0.22, 0.48, 0.98}, {0.25, 0.82, 0.32}, {0.98, 0.76, 0.12}}
AREA_COLOR = {1.0, 0.5, 0.05}     -- the fight area's outline: glowing orange (the host's live edit: cyan)

LOADOUTS = {
	guns = {{"sledge", 0}, {"gun", 12}, {"shotgun", 6}},
	sledge = {{"sledge", 0}},
}

TEAMS_KEY = "savegame.mod.brawl.teams"
ROUND_KEY = "savegame.mod.brawl.roundsec"
FF_KEY = "savegame.mod.brawl.ff"
LOADOUT_KEY = "savegame.mod.brawl.loadout"
EDIT_KEY = "brawl.edited"         -- (host registry, not savegame: the host's polygon for this session, with the level)

local function clockLabel(v) return string.format("%d:%02d", math.floor(v / 60), v % 60) end

-- the host's settings for mplib's drawer: with the Combat System on, the Weapons row shows one fixed value, "Bare
-- hands" (the user: choosing guns there was "an illusion of choice"; they picked showing the row over hiding it) - on
-- its own key, so the stored weapons choice stays for a session without the Combat System. mplib reads the items
-- every frame (a key it hasn't seen gets its first option)
BAREHANDS_KEY = "savegame.mod.brawl.barehands"
local settingsCombat
function brawlSettings(combat)
	if not combat then return SETTINGS end
	if not settingsCombat then
		local items = {}
		for _, it in ipairs(SETTINGS[1].items) do
			if it.key == LOADOUT_KEY then
				items[#items + 1] = {key = BAREHANDS_KEY, label = it.label,
					info = "The Combat System mod is on: everyone fights with bare hands",
					options = {{label = "Bare hands", value = "barehands"}}}
			else
				items[#items + 1] = it
			end
		end
		settingsCombat = {{title = SETTINGS[1].title, items = items}}
	end
	return settingsCombat
end

SETTINGS = {
	{
		title = "",
		items = {
			{key = TEAMS_KEY, label = "Teams", info = "How many teams players can join",
				options = {{label = "4", value = 4}, {label = "2", value = 2}, {label = "3", value = 3}}},
			{key = ROUND_KEY, label = "Round time", info = "At 0:00 the team with the most of its full health left wins",
				options = {{label = clockLabel(300), value = 300}, {label = clockLabel(480), value = 480}, {label = clockLabel(600), value = 600},
					{label = clockLabel(120), value = 120}, {label = clockLabel(180), value = 180}}},
			{key = FF_KEY, label = "Friendly fire", info = "Off: hits between teammates do nothing",
				options = {{label = "Off", value = "off"}, {label = "On", value = "on"}}},
			{key = LOADOUT_KEY, label = "Weapons", info = "Only without the Combat System mod. Guns: sledge, gun, shotgun. Own tools: nothing taken or given",
				options = {{label = "Guns", value = "guns"}, {label = "Sledge", value = "sledge"}, {label = "Own tools", value = "keep"}}},
		},
	},
}

----- server -----

local G = {phase = "lobby", t = 0, roundTime = 300, ff = false, loadout = "guns", combat = false, frame = 0,
	area = {src = "none", shapes = {}, str = "", seq = 0, bad = 0}, editStr = "", editAck = 0, areaT = -100,
	kos = {}, knocks = {}, elims = {}, dmg = {}, teamKOs = {}, teamElims = {}, contested = false, knockPubT = -100, fighters = {}, combos = {}, seen = {}, feed = {}, winner = 0,
	top = 0, pubT = -100, nTeams = 4, spawns = {}}
BRAWL_G = G                                                        -- (the offline tests read it)
local publish                                                      -- (below: resolveArea publishes a change at once)

local function teamCount()
	local n = math.floor(tonumber(GetString(TEAMS_KEY)) or 4)
	return math.max(2, math.min(4, n))
end

local function levelKey() return GetString("game.levelid") .. "@" .. GetString("game.levelpath") end

-- (both) is the Combat System running: its tool's registry keys (it registers in its own init - another mod's init may
-- run after ours: checked every second), or the tool enabled / held by any player (it enables its tool for everyone
-- every tick). Once seen it stays seen for the session (the user's 4-player test: the tool worked in the fight while
-- the lobby panel said "not enabled")
local combatSeen = false
function brawlCombatPresent()
	if combatSeen then return true end
	local found = HasKey("game.tool." .. COMBAT_TOOL) or GetBool("game.tool." .. COMBAT_TOOL .. ".enabled")
		or GetString("game.tool." .. COMBAT_TOOL .. ".name") ~= ""
	if not found then
		for _, id in ipairs(ListKeys("game.tool") or {}) do if id == COMBAT_TOOL then found = true end end
	end
	if not found then
		for _, p in ipairs(GetAllPlayers() or {}) do
			if IsToolEnabled(COMBAT_TOOL, p) or GetPlayerTool(p) == COMBAT_TOOL then found = true end
		end
	end
	if found then combatSeen = true end
	return found
end
local function combatPresent() return brawlCombatPresent() end

-- the area: the host's edit wins, then brawl.area (a map's or a mod's), then the map's brawl_area triggers, else none
local function resolveArea(force)
	local src, shapes, bad = "none", {}, 0
	if G.editStr ~= "" then
		shapes = baParse(G.editStr); src = "host"
	end
	if #shapes == 0 then
		local s = GetString("brawl.area")
		if s ~= "" then
			shapes, bad = baParse(s)
			src = #shapes > 0 and "map" or "none"
		end
	end
	if #shapes == 0 then
		for _, h in ipairs(FindTriggers("brawl_area", true) or {}) do
			local lo, hi = GetTriggerBounds(h)
			shapes[#shapes + 1] = {kind = "trigger", h = h, x0 = lo[1], y0 = lo[2], z0 = lo[3], x1 = hi[1], y1 = hi[2], z1 = hi[3]}
		end
		if #shapes > 0 then src = "trigger" end
	end
	local str = baAreaString(shapes)
	if force or str ~= G.area.str or src ~= G.area.src or bad ~= G.area.bad then
		G.area = {src = src, shapes = shapes, str = str, seq = G.area.seq + 1, bad = bad}
		local c = baCentre(shapes)
		if c and G.phase == "lobby" then shared._camTarget = c end   -- (the lobby's orbiting camera circles the area)
		if shared._teamState then publish(true) end
	else
		G.area.shapes = shapes                                       -- (fresh trigger handles)
	end
end

function brawlInside(p)
	if G.area.src == "none" then return true end
	return baInside(G.area.shapes, VecAdd(GetPlayerTransform(p).pos, Vec(0, EYE, 0)))
end

local function teamOf(p) return teamsGetTeamId(p) end

publish = function(force)
	local now = GetTime()
	if not force and now - G.pubT < 0.2 then return end
	G.pubT = now
	local copy = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
	local inside, out, late, healing = {}, {}, {}, {}
	for p, F in pairs(G.fighters) do
		inside[p] = F.inside ~= false
		if F.healing then healing[p] = true end
		if F.out then out[p] = true end
		if F.late then late[p] = true end
	end
	local feed = {}
	for i, e in ipairs(G.feed) do feed[i] = copy(e) end
	shared.brawl = {phase = G.phase, t = G.t, clock = now, roundTime = G.roundTime, combat = G.combat, ff = G.ff,
		loadout = G.loadout, nTeams = #shared._teamState.teams, src = G.area.src, area = G.area.str, areaSeq = G.area.seq,
		areaBad = G.area.bad, editAck = G.editAck, editHow = G.editHow or "drawn", kos = copy(G.kos), knocks = copy(G.knocks), elims = copy(G.elims),
		dmg = copy(G.dmg), teamKOs = copy(G.teamKOs), teamElims = copy(G.teamElims), inside = inside, out = out, late = late,
		healing = healing, feed = feed, winner = G.winner, top = G.top, contested = G.contested, winWhy = G.winWhy or "",
		teamHP = (G.phase == "fight" or G.phase == "over") and brawlTeamHP() or {},
		teamPct = (G.phase == "fight" or G.phase == "over") and brawlTeamPct() or {}}
end

-- the knocked (for every machine's pose, chicks and bars), KNOCK_PUB s apart and at once on a change of who:
-- shared.brawlKnock = {n = seq, k = {[p] = {left = s, bar = 0..1}}} (a fighter on the way out - dieAt - not in it)
local function publishKnock(force)
	local now = GetTime()
	local k, who = {}, ""
	for p, F in pairs(G.fighters) do
		local K = F.knocked
		if K and not K.dieAt then
			k[p] = {left = math.max(0, KNOCK_TIME - (now - K.t0)), bar = math.max(0, K.bar / KNOCK_HP)}
			who = who .. p .. ","
		end
	end
	if not force and who == G.knockWho and now - G.knockPubT < KNOCK_PUB then return end
	G.knockPubT, G.knockWho = now, who
	G.knockN = (G.knockN or 0) + 1
	shared.brawlKnock = {n = G.knockN, k = k}
end

-- the event ring for maps: fields first, the counter last (a reader in another script reads n = seen+1 .. last)
local function event(kind, victim, attacker, team, hits)
	local n = GetInt("brawl.event.last") + 1
	local k = "brawl.event." .. (n % EVENT_RING)
	SetString(k .. ".kind", kind)
	SetInt(k .. ".victim", victim or 0)
	SetInt(k .. ".attacker", attacker or 0)
	SetInt(k .. ".team", team or 0)
	SetInt(k .. ".hits", hits or 0)
	SetFloat(k .. ".time", GetTime())
	SetInt("brawl.event.last", n)
	table.insert(G.feed, {n = n, kind = kind, v = victim or 0, k = attacker or 0, team = team or 0, hits = hits or 0, at = GetTime()})
	while #G.feed > 6 do table.remove(G.feed, 1) end
	publish(true)
end

local function setPhase(phase)
	G.phase = phase
	SetString("brawl.phase", phase)
	SetBool("brawl.active", phase == "ready" or phase == "fight")
end

function server.init()
	G.spawns = utilLoadLevelPlayerSpawns()
	if #G.spawns == 0 then G.spawns = utilGenerateSpawnPoints(32) end
	hudInit(true)
	G.nTeams = teamCount()
	teamsInit(G.nTeams)
	teamsSetNames({unpack(TEAM_NAMES, 1, G.nTeams)})
	teamsSetColors({unpack(TEAM_COLORS, 1, G.nTeams)})
	local saved, lk = GetString(EDIT_KEY), levelKey() .. "|"
	if saved:sub(1, #lk) == lk then                               -- (the host's polygon survives Play Again on this map)
		G.editStr = baValidateArea(saved:sub(#lk + 1)) or ""
		G.editHow = GetString(EDIT_KEY .. ".how") == "moved" and "moved" or "drawn"
	end
	G.combat = combatPresent()
	for p in Players() do SetBool("brawl.knocked." .. p, false) end
	setPhase("lobby")
	resolveArea(true)
	publish(true)
end

function server.destroy()
	bvServerClear()
	for p in Players() do SetBool("brawl.knocked." .. p, false) end
	SetBool("brawl.active", false)
	SetString("brawl.phase", "")
	for p in Players() do SetPlayerParam("healthRegeneration", true, p) end
end

-- the host's Start (hudDrawGameSetup)
function server.start(settings)
	G.roundTime = tonumber(settings.roundTime) or 300
	G.ff = settings.ff == "on"
	G.loadout = LOADOUTS[settings.loadout] and settings.loadout or (settings.loadout == "keep" and "keep" or "guns")
	teamsStart(false)
end

-- the host's area (client -> server, re-sent until shared.brawl.editAck shows seq): a polygon from the editor (how
-- "drawn") or the area dragged to another place (how "moved": its own parts, moved); "" drops it
function server.brawlSetArea(p, seq, str, how)
	seq = tonumber(seq) or 0
	if not IsPlayerHost(p) then return end
	if seq == G.editAck then publish(true); return end             -- (a re-send of the one just taken)
	G.editAck = seq
	G.editErr = nil
	if G.phase ~= "lobby" or teamsIsSetup() then
		G.editErr = "only in the lobby"
	elseif str == "" then
		G.editStr = ""
		ClearKey(EDIT_KEY)
		ClearKey(EDIT_KEY .. ".how")
	else
		local clean, err = baValidateArea(str)
		if clean then
			G.editStr = clean
			G.editHow = how == "moved" and "moved" or "drawn"
			SetString(EDIT_KEY, levelKey() .. "|" .. clean)
			SetString(EDIT_KEY .. ".how", G.editHow)
		else
			G.editErr = err
		end
	end
	resolveArea(true)
	publish(true)
end

-- the host's team count (lobby only, before the countdown): teams added or removed, the players of a removed team
-- moved to the smallest of those left
local function syncTeamCount()
	local ts = shared._teamState
	if not ts or ts.state ~= _WAITING then return end
	local n = teamCount()
	if #ts.teams == n then return end
	local teams, orphans = {}, {}
	for i = 1, math.max(n, #ts.teams) do
		local old = ts.teams[i]
		if i <= n then
			local players = {}
			if old then for _, p in ipairs(old.players) do players[#players + 1] = p end end
			teams[i] = {name = TEAM_NAMES[i], color = TEAM_COLORS[i], players = players}
		elseif old then
			for _, p in ipairs(old.players) do orphans[#orphans + 1] = p end
		end
	end
	for _, p in ipairs(orphans) do
		local best = 1
		for i = 2, n do if #teams[i].players < #teams[best].players then best = i end end
		teams[best].players[#teams[best].players + 1] = p
	end
	ts.teams = teams
	shared._teamState = ts
	G.nTeams = n
end

-- a player arriving in the lobby joins the smallest team at once (listed at once), once only
local autoJoined = {}
local function lobbyAutoJoin()
	if teamsIsSetup() then return end
	local ts = shared._teamState
	if not ts or ts.state ~= _WAITING then return end
	local counts
	for p in Players() do
		if not autoJoined[p] then
			autoJoined[p] = true
			if teamsGetTeamId(p) == 0 then
				if not counts then                                 -- (the joins land in teamsTick: count them here)
					counts = {}
					for i = 1, #ts.teams do counts[i] = #ts.teams[i].players end
				end
				local best = 1
				for i = 2, #ts.teams do if counts[i] < counts[best] then best = i end end
				counts[best] = counts[best] + 1
				server._teamsJoinTeam(p, best)
			end
		end
	end
end

-- tools: with the Combat System only its tool (the others stripped every STRIP_EVERY s, it re-selected); without
-- it the loadout setting
local function giveLoadout(p)
	local all = ListKeys("game.tool") or {}
	if G.combat then
		for _, id in ipairs(all) do if id ~= COMBAT_TOOL then SetToolEnabled(id, false, p) end end
		SetToolEnabled(COMBAT_TOOL, true, p)
		if GetToolAmmo(COMBAT_TOOL, p) < 1 then SetToolAmmo(COMBAT_TOOL, 1, p) end   -- (selectable; its count isn't shown)
		SetPlayerTool(COMBAT_TOOL, p)
		return
	end
	local list = LOADOUTS[G.loadout]
	if not list then return end                                  -- ("keep": their own tools)
	for _, id in ipairs(all) do SetToolEnabled(id, false, p); SetToolAmmo(id, 0, p) end
	for _, it in ipairs(list) do SetToolEnabled(it[1], true, p); SetToolAmmo(it[1], it[2], p) end
	SetPlayerTool(list[1][1], p)
end

local function keepTools(p, F, now)
	if not G.combat then return end
	if now >= (F.nextStrip or 0) then
		F.nextStrip = now + STRIP_EVERY
		for _, id in ipairs(ListKeys("game.tool") or {}) do
			if id ~= COMBAT_TOOL and IsToolEnabled(id, p) then SetToolEnabled(id, false, p) end
		end
		if not IsToolEnabled(COMBAT_TOOL, p) then SetToolEnabled(COMBAT_TOOL, true, p) end
	end
	if now >= (F.nextSel or 0) then
		F.nextSel = now + 0.25
		if GetPlayerTool(p) ~= COMBAT_TOOL and GetPlayerVehicle(p) == 0 then SetPlayerTool(COMBAT_TOOL, p) end
	end
end

-- every spawn the mode does is OUTSIDE the fight area (the user): each team on its own side (team k at k * 360 / teams
-- degrees round the area's centre), teammates side by side SPAWN_SIDE m apart, facing the centre; else the map's own
-- spawns outside the area, else a point further out; no area: the map's spawns
local function spawnTransform(p, avoid)
	local pos
	if G.area.src ~= "none" then
		local team, n = math.max(1, teamOf(p)), math.max(1, #shared._teamState.teams)
		local list, idx = teamsGetTeamPlayers(team), 1
		for i, q in ipairs(list) do if q == p then idx = i end end
		local lateral = (idx - (#list + 1) / 2) * SPAWN_SIDE
		pos = baOutsideSpot(G.area.shapes, (team - 1) * 360 / n, lateral, avoid)
		if not pos then
			for _, t in ipairs(G.spawns) do
				if not baInside(G.area.shapes, VecAdd(t.pos, Vec(0, 0.5, 0))) and not baInsideXZ(G.area.shapes, t.pos[1], t.pos[3]) then
					local far = true
					for _, q in ipairs(avoid or {}) do if (q[1] - t.pos[1]) ^ 2 + (q[3] - t.pos[3]) ^ 2 < 0.8 then far = false end end
					if far then pos = VecCopy(t.pos); break end
				end
			end
		end
		if not pos then                                          -- (further out, wherever the floor is)
			local c, span = baCentre(G.area.shapes)
			local a = math.rad((team - 1) * 360 / n)
			local x, z = c[1] + math.cos(a) * (span + 8), c[3] + math.sin(a) * (span + 8)
			local hit, d = QueryRaycast(Vec(x, c[2] + 20, z), Vec(0, -1, 0), 60)
			pos = Vec(x, hit and (c[2] + 20 - d) or c[2], z)
		end
	end
	if not pos then
		local t = G.spawns[GetRandomInt(1, math.max(1, #G.spawns))]
		if not t then return nil end
		return t
	end
	local c = baCentre(G.area.shapes) or pos
	local dx, dz = c[1] - pos[1], c[3] - pos[3]
	local yaw = (dx * dx + dz * dz > 0.01) and math.deg(math.atan2(-dx, -dz)) or math.random() * 360
	return Transform(pos, QuatEuler(0, yaw, 0))                    -- (facing the middle of the area)
end

local function newFighter() return {H = START_HEALTH, lastHurt = -100, inside = false, grace = 0} end

local function respawnFighter(p, F, avoid)
	local now = GetTime()
	local t = spawnTransform(p, avoid)
	if t then RespawnPlayerAtTransform(t, p) else RespawnPlayer(p) end
	giveLoadout(p)
	SetPlayerHealth(START_HEALTH, p)
	F.H, F.out, F.knocked, F.grace, F.lastHurt, F.killer, F.diedBy, F.pend = START_HEALTH, nil, nil, now + GRACE, -100, nil, nil, nil
	F.inside, F.inAt, F.shotOut = false, nil, nil
	F.nextStrip, F.nextSel = now + 0.3, now + 0.1
	return t
end

-- back on the spot at once, with the old health (a killing blow that must not count)
local function revive(p, F, hp)
	RespawnPlayerAtTransform(GetPlayerTransform(p), p)
	hp = math.max(0.01, math.min(1, hp or F.H))
	SetPlayerHealth(hp, p)
	F.H, F.grace, F.killer, F.diedBy, F.pend = hp, GetTime() + GRACE, nil, nil, nil
	F.nextSel = GetTime() + 0.1
end

local function combo(k, v, now)
	local key = k .. ":" .. v
	local c = G.combos[key]
	if c and now - c.t < VOLLEY then c.t = now; return end
	if c and now - c.t <= COMBO_GAP then c.n = c.n + 1 else c = {n = 1}; G.combos[key] = c end
	c.t = now
	if c.n >= COMBO_MIN then event("combo", v, k, teamOf(k), c.n) end
end

-- a hit counts only from an attacker standing inside who hasn't fired from outside in the last SHOT_FLIGHT s; one
-- with no attacker (the world: a fall, an unowned explosion) only while nobody's outside shot can still be in the air
local function attackerOk(k, v)
	local now = GetTime()
	if not k or k == 0 or not IsPlayerValid(k) then return now - (G.shotOut or -100) >= SHOT_FLIGHT end
	if k == v then return true end                                           -- (yourself)
	local A = G.fighters[k]
	if not A or A.out or A.late then return false end                        -- (someone not in the fight)
	if not brawlInside(k) then return false end
	if now - (A.shotOut or -100) < SHOT_FLIGHT then return false end         -- (their shot from outside, landing now)
	return G.ff or teamOf(k) ~= teamOf(v)
end

local function enemy(k, p) return k and k ~= 0 and k ~= p and G.fighters[k] ~= nil and teamOf(k) ~= teamOf(p) end

-- knocked down (a killing blow inside, in the fight): back on the spot at once (the engine can't survive a hit - Humans
-- vs Clickers' verified way), kneeling KNOCK_TIME s; the engine's health held at 1, hits go to the knock bar instead
local function knock(p, F, k, now)
	local t = GetPlayerTransform(p)
	RespawnPlayerAtTransform(Transform(t.pos, t.rot), p)
	SetPlayerHealth(1, p)
	k = k or 0
	F.H, F.pend, F.killer, F.diedBy, F.grace = 1, nil, nil, nil, now + GRACE
	F.knocked = {t0 = now, bar = KNOCK_HP, by = k, last = enemy(k, p) and k or 0}
	G.knocks[p] = (G.knocks[p] or 0) + 1
	local team = 0
	if enemy(k, p) then
		G.kos[k] = (G.kos[k] or 0) + 1
		team = teamOf(k)
		G.teamKOs[team] = (G.teamKOs[team] or 0) + 1
	end
	G.combos[k .. ":" .. p] = nil
	SetBool("brawl.knocked." .. p, true)
	event("knockdown", p, k, team)
end

-- out of the round: the bar emptied (or the engine killed them while knocked); they spectate until the round ends
local function eliminate(p, F)
	local K = F.knocked or {}
	F.knocked, F.out = nil, true
	if GetPlayerHealth(p) > 0 then SetPlayerHealth(0, p) end
	local k = (K.last and K.last ~= 0) and K.last or (K.by or 0)
	local team = 0
	if enemy(k, p) then
		G.elims[k] = (G.elims[k] or 0) + 1
		team = teamOf(k)
		G.teamElims[team] = (G.teamElims[team] or 0) + 1
	else
		k = 0
	end
	SetBool("brawl.knocked." .. p, false)
	event("eliminated", p, k, team)
end

local function getUp(p, F, now)
	F.knocked = nil
	F.H, F.lastHurt = GETUP_HEALTH, now                           -- (healing again HEAL_DELAY s from now)
	SetPlayerHealth(GETUP_HEALTH, p)
	if G.combat then F.nextSel = 0
	elseif F.tool and F.tool ~= "" and F.tool ~= "none" then SetPlayerTool(F.tool, p) end
	SetBool("brawl.knocked." .. p, false)
	event("getup", p, 0, teamOf(p))
end

local function handleHurt(v, b, a, k, now)
	local F = G.fighters[v]
	if F and (F.out or F.late or F.pend) then return end         -- (out, or already dying: nothing to count or undo)
	local valid = G.phase == "fight" and F ~= nil and brawlInside(v) and attackerOk(k, v)
	if F and F.knocked then                                       -- knocked: hits go to the knock bar
		local K = F.knocked
		if K.dieAt then return end
		if valid then
			K.bar = K.bar - (b - a)
			if enemy(k, v) then
				K.last = k
				G.dmg[k] = (G.dmg[k] or 0) + (b - a)
			end
			if a <= 0 then eliminate(v, F); return end            -- (the engine killed them anyway: the bar is empty)
		end
		if GetPlayerHealth(v) <= 0 then revive(v, F, 1)            -- (a blow that doesn't count: still kneeling)
		else SetPlayerHealth(1, v) end
		return
	end
	if valid then
		F.lastHurt = now
		if k and k ~= 0 and k ~= v and IsPlayerValid(k) then
			G.dmg[k] = (G.dmg[k] or 0) + (b - a)
			if teamOf(k) ~= teamOf(v) then combo(k, v, now) end
		end
		if a <= 0 then knock(v, F, k, now) end                   -- (the killing blow inside: down, at once)
		return
	end
	if not F then return end                                     -- (not a fighter: the lobby - nothing to undo)
	local cur = GetPlayerHealth(v)
	if cur <= 0 then revive(v, F, b)
	else SetPlayerHealth(math.min(1, cur + (b - a)), v) end
end

-- every playerhurt event once (they are read from tick and postUpdate, and may show in more than one frame: a key per
-- event - victim, health before and after, attacker - remembered 3 frames; the Combat System does the same with 2)
function brawlProcessHurt()
	local now = GetTime()
	local n = GetEventCount("playerhurt")
	for i = 1, n do
		local v, b, a, k = GetEvent("playerhurt", i)
		if v and b and a and a < b then
			local key = v .. ":" .. b .. ":" .. a .. ":" .. tostring(k or 0)
			local f = G.seen[key]
			if not f or G.frame - f > 2 then
				G.seen[key] = G.frame
				handleHurt(v, b, a, k, now)
			end
		end
	end
end

local function processDied()
	for i = 1, GetEventCount("playerdied") do
		local v, k = GetEvent("playerdied", i)
		local F = v and G.fighters[v]
		if F and k and k ~= 0 then F.diedBy = k end
	end
end

-- a knocked fighter, every tick: kneeling in place (no walking, no jump, no sideways motion, no tool), the engine's
-- health held at 1 (hits drain the knock bar in handleHurt; the bar does NOT drain by time); KNOCK_TIME s with some
-- bar left: up with a third of their health; the bar empty: out of the pose first, dead KNOCK_EXIT s later (a ragdoll
-- started from the pose was flung - Humans vs Clickers)
local function knockTick(p, F, now)
	local K = F.knocked
	SetPlayerParam("walkingSpeed", 0, p)
	SetPlayerParam("jumpSpeed", 0, p)
	local v = GetPlayerVelocity(p)
	if math.abs(v[1]) + math.abs(v[3]) > 0.01 or v[2] > 0 then SetPlayerVelocity(Vec(0, math.min(v[2], 0), 0), p) end
	if GetPlayerTool(p) ~= "none" then SetPlayerTool("none", p) end
	if K.dieAt then
		if now >= K.dieAt then eliminate(p, F) end
		return
	end
	local cur = GetPlayerHealth(p)
	if now >= F.grace then
		if cur <= 0 then eliminate(p, F); return end              -- (killed with no event to read: the bar is gone)
		if cur < 1 - 1e-4 then K.bar = K.bar - (1 - cur) end      -- (damage without an event: off the bar too)
	end
	if math.abs(cur - 1) > 1e-4 then SetPlayerHealth(1, p) end
	if K.bar <= 0 then
		K.bar, K.dieAt = 0, now + KNOCK_EXIT
	elseif now - K.t0 >= KNOCK_TIME then
		getUp(p, F, now)
	end
end

-- each fighter's health, every tick: inside (fight) it only goes down by damage and up by our healing; outside, and
-- before the fight, it is held where it was (no damage, no healing - the engine's regeneration off besides)
local function fighters(dt, now)
	local present = {}
	for p in Players() do
		present[p] = true
		local F = G.fighters[p]
		if teamsGetTeamId(p) == 0 then                            -- (joined mid-round: the smallest team, for next round)
			local ts, best = shared._teamState, 1
			for i = 2, #ts.teams do if #ts.teams[i].players < #ts.teams[best].players then best = i end end
			ts.teams[best].players[#ts.teams[best].players + 1] = p
		end
		if not F then                                             -- (joined mid-round: spectating until the next round -
			F = newFighter()                                      --  with eliminations, placing them would be unfair)
			F.late = G.phase ~= "over"
			G.fighters[p] = F
		end
		if now >= (F.nextRegen or 0) then
			F.nextRegen = now + 0.5
			SetPlayerParam("healthRegeneration", false, p)
		end
		local cur = GetPlayerHealth(p)
		local wasHealing = F.healing
		F.healing = false
		if F.late then
			DisablePlayer(p)                                      -- (no body: watching)
			if cur > 0 then SetPlayerHealth(0, p) end
		elseif F.out then
			if cur > 0 then SetPlayerHealth(0, p) end             -- (out: dead, spectating)
		elseif F.knocked then
			knockTick(p, F, now)
		elseif now < F.grace then
			if math.abs(cur - F.H) > 1e-3 then SetPlayerHealth(F.H, p) end
			keepTools(p, F, now)
		elseif cur <= 0 then
			if not F.pend then F.pend = G.frame
			elseif G.frame - F.pend >= 2 then                     -- (two frames: an undo by a late event comes first)
				if G.phase == "fight" and F.inside and attackerOk(F.diedBy, p) then knock(p, F, F.diedBy or 0, now)
				else revive(p, F, F.H) end
			end
		else
			F.pend = nil
			F.inside = brawlInside(p)
			local tool = GetPlayerTool(p)
			if tool ~= "none" and tool ~= "" then F.tool = tool end
			if not F.inside and G.phase == "fight" and RANGED[tool] ~= false and tool ~= "none" and tool ~= ""
				and (InputDown("usetool", p) or InputPressed("usetool", p)) then
				F.shotOut, G.shotOut = now, now                             -- (fired from outside: see attackerOk)
			end
			keepTools(p, F, now)
			if G.phase == "fight" and F.inside then
				F.inAt = F.inAt or now
				if cur < F.H - 1e-4 then F.H, F.lastHurt = cur, now
				elseif cur > F.H + 1e-4 then SetPlayerHealth(F.H, p) end   -- (no other healing)
				if now - math.max(F.lastHurt, F.inAt) >= HEAL_DELAY and F.H < 1 then   -- (HEAL_DELAY s in, unhurt)
					F.H = math.min(1, F.H + HEAL_RATE * dt)
					SetPlayerHealth(F.H, p)
					F.healing = true
				end
			else
				F.inAt = nil                                               -- (the time inside starts again)
				if math.abs(cur - F.H) > 1e-4 then SetPlayerHealth(F.H, p) end   -- (held: outside, or not fighting yet)
			end
		end
		if F.healing ~= (wasHealing or false) then G.healChanged = true end
	end
	for p in pairs(G.fighters) do if not present[p] then G.fighters[p] = nil; SetBool("brawl.knocked." .. p, false) end end
end

-- the teams still in (a fighter not out, present); the early end needs a round that began with 2 teams or more
local function teamsIn()
	local alive, n, last = {}, 0, 0
	for p, F in pairs(G.fighters) do
		if not F.out and not F.late then
			local t = teamOf(p)
			if t ~= 0 then
				if not alive[t] then n, last = n + 1, t end
				alive[t] = (alive[t] or 0) + 1
			end
		end
	end
	return alive, n, last
end

local function beginRound()
	SetInt("savegame.mod.brawl.rounds", GetInt("savegame.mod.brawl.rounds") + 1)
	math.randomseed(math.floor(GetTime() * 1000) % 1000000 + GetInt("savegame.mod.brawl.rounds") * 7919)
	for _ = 1, 5 do math.random() end
	G.combat = combatPresent()
	resolveArea(false)
	for p in pairs(G.fighters) do SetBool("brawl.knocked." .. p, false) end
	G.kos, G.knocks, G.elims, G.dmg, G.combos, G.feed, G.fighters, G.winner, G.top = {}, {}, {}, {}, {}, {}, {}, 0, 0
	G.teamKOs, G.teamElims, G.winWhy, G.shotOut = {}, {}, "", nil
	for i = 1, #shared._teamState.teams do G.teamKOs[i], G.teamElims[i] = 0, 0 end
	local placed = {}
	for p in Players() do
		local F = newFighter()
		G.fighters[p] = F
		SetBool("brawl.knocked." .. p, false)
		local t = respawnFighter(p, F, placed)
		if t then placed[#placed + 1] = t.pos end
	end
	local _, n = teamsIn()
	G.contested = n >= 2
	G.startN = {}                                                -- (each team's fighters at the start: its 100 %;
	for p in pairs(G.fighters) do                                --  late joiners don't change it)
		local t = teamOf(p)
		if t ~= 0 then G.startN[t] = (G.startN[t] or 0) + 1 end
	end
	setPhase("ready")
	G.t = READY_TIME
	publish(true)
end

-- the winner: the last team standing (an early end); on time-out the team with the most of its starting health left,
-- as a share (the user: "decided by the percentage of HP left from their initial total team HP, so that it's more
-- fair for teams with less players"): its health left / (its fighters at the round's start x 1.0), then knockdowns,
-- then damage dealt (all equal: a draw)
-- each team's health left: the summed current health of its fighters still in (a knocked fighter: 0 - the knock bar
-- doesn't count; the eliminated and late joiners: nothing)
function brawlTeamHP()
	local hp = {}
	for i = 1, #shared._teamState.teams do hp[i] = 0 end
	for p, F in pairs(G.fighters) do
		local t = teamOf(p)
		if t ~= 0 and not F.out and not F.late and not F.knocked and IsPlayerValid(p) then
			hp[t] = (hp[t] or 0) + math.max(0, GetPlayerHealth(p))
		end
	end
	return hp
end

-- the share of each team's full health left, 0..1: its fighters at the start x 1.0 (they start at START_HEALTH, so a
-- round opens at 80 % for every team; a team that started with nobody: 0)
function brawlTeamPct()
	local hp, pct = brawlTeamHP(), {}
	for i = 1, #shared._teamState.teams do
		local n = (G.startN or {})[i] or 0
		pct[i] = n > 0 and math.min(1, (hp[i] or 0) / n) or 0
	end
	return pct
end

local function ranking()
	local alive = teamsIn()
	local pct = brawlTeamPct()
	local dmgT = {}
	for p, d in pairs(G.dmg) do local t = teamOf(p); if t ~= 0 then dmgT[t] = (dmgT[t] or 0) + d end end
	local function key(t) return {math.floor((pct[t] or 0) * 1000 + 0.5) / 1000, G.teamKOs[t] or 0, dmgT[t] or 0} end
	local function better(a, b)
		for i = 1, 3 do if math.abs(a[i] - b[i]) > 1e-6 then return a[i] > b[i] and 1 or -1 end end
		return 0
	end
	local best, tie = 0, false
	for t = 1, #shared._teamState.teams do
		if best == 0 then best = t
		else
			local c = better(key(t), key(best))
			if c > 0 then best, tie = t, false elseif c == 0 then tie = true end
		end
	end
	-- why (the results say it): the top two teams' shares
	local order = {}
	for t = 1, #shared._teamState.teams do order[#order + 1] = t end
	table.sort(order, function(a, b) return better(key(a), key(b)) > 0 end)
	local t1, t2 = order[1], order[2]
	local p1, p2 = math.floor((pct[t1] or 0) * 100 + 0.5), math.floor((pct[t2] or 0) * 100 + 0.5)
	local vs = string.format("%s %d %% vs %s %d %%", TEAM_NAMES[t1] or "?", p1, TEAM_NAMES[t2] or "?", p2)
	local why
	if tie then why = "time up: a draw (health left " .. vs .. ", knockdowns and damage equal)"
	elseif key(t1)[1] ~= key(t2)[1] then why = "time up: most health left: " .. vs
	elseif (G.teamKOs[t1] or 0) ~= (G.teamKOs[t2] or 0) then why = "time up: health left equal (" .. vs .. "), more knockdowns"
	else why = "time up: health left and knockdowns equal (" .. vs .. "), more damage dealt" end
	return tie and 0 or best, alive, why
end

local function endRound(winner)
	local alive, why
	if winner == nil then winner, alive, why = ranking()
	else why = winner ~= 0 and "last team standing" or "no team left" end
	G.winner, G.winWhy = winner, why
	G.t = 0
	local top, tk, td = 0, -1, -1                                   -- the top fighter: knockdowns, then damage dealt
	for p in Players() do
		local k, d = G.kos[p] or 0, G.dmg[p] or 0
		if k > tk or (k == tk and d > td) then top, tk, td = p, k, d end
	end
	G.top = top
	setPhase("over")
	G.t = 0
	for p, F in pairs(G.fighters) do                              -- (nobody lies down under the results)
		if F.knocked then SetBool("brawl.knocked." .. p, false) end
		F.knocked = nil
		if F.late then F.late = nil end
		if F.out or GetPlayerHealth(p) <= 0 then respawnFighter(p, F) end
	end
	event("round_end", 0, 0, G.winner)
	publish(true)
end

-- Proximity Comms (if the host runs it): everyone hears everyone in the lobby and on the results; pings to your team
local function chatKeys()
	local open = G.phase == "lobby" or G.phase == "over"
	SetBool("proxchat.lobby", open)
	for p in Players() do
		SetString("proxchat.team." .. p, "brawl" .. teamOf(p))
		local F = G.fighters[p]                                     -- (the eliminated and late joiners: the dead's channel)
		SetString("proxchat.channel." .. p, (not open and F and (F.out or F.late)) and "dead" or "")
	end
end

function server.tick(dt)
	G.frame = G.frame + 1
	local now = GetTime()
	for key, f in pairs(G.seen) do if G.frame - f > 3 then G.seen[key] = nil end end
	if now - G.areaT >= 1 then
		G.areaT = now
		G.combat = combatPresent()
		resolveArea(false)
	end
	lobbyAutoJoin()
	syncTeamCount()
	if teamsTick(dt) then beginRound() end
	chatKeys()
	bvServerTick(not teamsIsSetup())                             -- (the lobby view: what lies above the host's cut hidden)
	if not teamsIsSetup() then
		for p in Players() do DisablePlayer(p) end
		publish(false)
		return
	end
	processDied()
	brawlProcessHurt()
	if G.phase == "ready" then
		G.t = G.t - dt
		for p in Players() do DisablePlayerInput(p) end
		fighters(dt, now)
		if G.t <= 0 then
			setPhase("fight")
			G.t = G.roundTime
			event("round_start", 0, 0, 0)
		end
	elseif G.phase == "fight" then
		G.t = G.t - dt
		fighters(dt, now)
		local _, teamsLeft, last = teamsIn()
		if G.contested and teamsLeft <= 1 then endRound(teamsLeft == 1 and last or 0)   -- (the last team standing)
		elseif G.t <= 0 then endRound() end
	elseif G.phase == "over" then
		for p in Players() do DisablePlayerInput(p) end
		fighters(dt, now)
	end
	publish(G.healChanged == true)                               -- (at once when someone starts / stops healing)
	G.healChanged = false
	publishKnock(false)
end

function server.postUpdate()
	if teamsIsSetup() then brawlProcessHurt() end                 -- (damage dealt after tick: physics, other scripts)
end

----- client -----

local C = {outlineSeq = -1, outline = nil, fightT = -100, lastPhase = "", viewSeq = nil}

function client.init()
end

function client.destroy()
	brawlViewLeave()
	SetBool("level.hidenameplates", false)
end

-- (the host's "Use the map's area") the host's edit dropped, the map's area framed again when it arrives
function brawlUseMapArea()
	brawlEditorSend("")
	C.frameNext = true
end

local function clock(t)
	t = math.max(0, math.ceil(t))
	return string.format("%d:%02d", math.floor(t / 60), t % 60)
end

local function bigText(y, size, text, r, g, b, a)
	UiPush()
	UiTranslate(UiCenter(), y)
	UiAlign("center middle")
	UiFont("bold.ttf", size)
	UiColor(r, g, b, a or 1)
	UiText(text)
	UiPop()
end

local function teamName(i) return TEAM_NAMES[i] or ("Team " .. tostring(i)) end
local function teamColor(i) return TEAM_COLORS[i] or {1, 1, 1} end

-- the lobby's cross-section view (brawl_view.lua) on every machine: centred on the area (again when it changes to a
-- place out of view, unless the host is editing it), else on this player; WASD / wheel / Q E R unless typing in the chat. Off once the round runs.
local function lobbyView(dt, b)
	if teamsIsSetup() then
		if BV.inited then brawlViewLeave() end
		return
	end
	local seq = b and b.areaSeq
	if not BV.inited or (seq ~= C.viewSeq and not brawlEditorActive()) then
		C.viewSeq = seq
		local shapes = b and b.src ~= "none" and baParse(b.area) or nil
		local c = shapes and baCentre(shapes) or nil
		if not c then
			c = GetPlayerTransform(GetLocalPlayer()).pos
			if VecLength(c) < 0.01 and shared._camTarget then c = shared._camTarget end
		end
		-- the area framed in the band above mplib's team boxes (entering the lobby, "Use the map's area", a new area out
		-- of view - not after a drag nearby)
		local far = 1.5 * BV.zoom * math.tan(math.rad(BV_FOV) / 2)
		local reframe = not BV.inited or C.frameNext or (c[1] - BV.x) ^ 2 + (c[3] - BV.z) ^ 2 > far * far
		if not BV.inited then brawlViewReset(c) end
		if reframe then
			if shapes then brawlViewFrame(shapes) else brawlViewCentre(c[1], c[3]) end
		end
		C.frameNext = false
	end
	brawlViewTick(dt, not GetBool("proxchat.typing." .. GetLocalPlayer()))
end

function client.tick(dt)
	hudTick(dt)
	teamsSetTags()
	brawlEditorTick(dt)
	local b = shared.brawl
	lobbyView(dt, b)
	if not b then return end
	if b.phase ~= C.lastPhase then
		if b.phase == "fight" then C.fightT = GetTime() end
		C.lastPhase = b.phase
	end
	local moving = not teamsIsSetup() and brawlMoveOutline() or nil
	if moving then                                               -- (the host dragging it: cyan, live)
		local key = baAreaString(moving)
		if key ~= C.moveKey then C.moveKey, C.moveOutline = key, baBuildOutline(moving) end
		baDrawOutline(C.moveOutline, 0.15, 0.85, 1.0)
	elseif not brawlEditorActive() and b.src ~= "none" then      -- the fight area, for everyone, lobby and round
		if b.areaSeq ~= C.outlineSeq then
			C.outlineSeq = b.areaSeq
			C.outline = baBuildOutline(baParse(b.area))
		end
		baDrawOutline(C.outline, AREA_COLOR[1], AREA_COLOR[2], AREA_COLOR[3])
	end
	if b.phase == "ready" or b.phase == "fight" or b.phase == "over" then
		SetBool("game.disablemap", true)                         -- (Tab is the scoreboard)
	end
	bkClientTick(dt)                                             -- (the knocked: kneeling, chicks)
	bhClientTick(dt)                                             -- (the healing: aura, rising crosses)
	brawlSpectateTick(b, GetLocalPlayer())
end

local function chatAlive() return GetFloat("proxchat.alive") > GetTime() - 2 end
local function chatTyping() return GetBool("proxchat.typing." .. GetLocalPlayer()) end
local function lobbyChatOpening() return chatAlive() and not chatTyping() and InputPressed("return") end
local function chattingNote()
	bigText(60, 22, "Chatting - Enter: send, Esc: close", 1, 1, 1, 0.8)
end

-- a plain button that fires on the press (UiBlankButton fires on release and missed clicks in-game - the skill)
local function button(label, w, h)
	UiPush()
	local over = UiIsMouseInRect(w, h)
	UiColor(1, 1, 1, over and 0.25 or 0.12)
	UiRoundedRect(w, h, 6)
	UiColor(1, 1, 1, 1)
	UiTranslate(w / 2, h / 2)
	UiAlign("center middle")
	UiFont("bold.ttf", 20)
	UiText(label)
	UiPop()
	return over and InputPressed("lmb")
end

-- a line cut into pieces no wider than maxW at the current font (whole words; a word wider than maxW stands alone)
function brawlWrap(text, maxW)
	local out, cur = {}, ""
	for word in tostring(text):gmatch("%S+") do
		local try = cur == "" and word or (cur .. " " .. word)
		if cur ~= "" and UiGetTextSize(try) > maxW then
			out[#out + 1] = cur
			cur = word
		else
			cur = try
		end
	end
	if cur ~= "" then out[#out + 1] = cur end
	return out
end

local SRC_TEXT = {
	host = "Fight area: drawn by the host",
	map = "Fight area: set by the map",
	trigger = "Fight area: the map's brawl_area zones",
	none = "No fight area: the whole map counts",
}

BRAWL_LOBBY_LINES = {}                                           -- (the offline tests read what the panel said)

-- the Brawl panel in the lobby (top left): the Combat System, the area, the host's area buttons
local function drawLobbyPanel(b)
	local me = GetLocalPlayer()
	local host = IsPlayerHost(me)
	local lines = {}
	local combat = b.combat or brawlCombatPresent()                 -- (the server's word, or this machine's own look)
	lines[1] = combat and {"Bare hands: Combat System found", 0.5, 1, 0.5}
		or {"Combat System not enabled: weapons", 1, 0.75, 0.3}
	lines[2] = {(b.src == "host" and b.editHow == "moved") and "Fight area: moved by the host" or (SRC_TEXT[b.src] or SRC_TEXT.none), 1, 0.6, 0.15}
	if b.src == "host" and baUnbounded(baParse(b.area)) then lines[2][1] = lines[2][1] .. " - every floor counts" end
	if (b.areaBad or 0) > 0 then lines[#lines + 1] = {"(brawl.area: " .. b.areaBad .. " part(s) could not be read)", 1, 0.4, 0.4} end
	lines[#lines + 1] = {"You start at " .. math.floor(START_HEALTH * 100 + 0.5) .. " % health. Damage counts only inside the area,"
		.. " and you heal only there: after " .. HEAL_DELAY .. " s inside without a hit.", 0.85, 0.85, 0.85}
	lines[#lines + 1] = {"At 0 health: knocked down " .. KNOCK_TIME .. " s - hit them again to knock them out of the round.", 0.85, 0.85, 0.85}
	BRAWL_LOBBY_LINES = {}
	for i, l in ipairs(lines) do BRAWL_LOBBY_LINES[i] = l[1] end
	local w = 560
	UiPush()
	UiFont("bold.ttf", 20)
	local rows = {}                                                -- (each line wrapped to the panel's width)
	for _, l in ipairs(lines) do
		for _, piece in ipairs(brawlWrap(l[1], w - 36)) do rows[#rows + 1] = {piece, l[2], l[3], l[4]} end
	end
	UiPop()
	local h = 26 + #rows * 26 + (host and 56 or 0)
	C.panelRect = {40, 40, w, h}
	BRAWL_PANEL = {x = 40, y = 40, w = w, h = h, rows = #rows, btnY = 40 + 14 + #rows * 26 + 6}
	UiPush()
	UiTranslate(40, 40)
	UiAlign("left top")
	UiColor(0, 0, 0, 0.6)
	UiRoundedRect(w, h, 10)
	UiTranslate(18, 14)
	for _, l in ipairs(rows) do
		UiFont("bold.ttf", 20)
		UiColor(l[2], l[3], l[4], 1)
		UiText(l[1])
		UiTranslate(0, 26)
	end
	if host then
		UiTranslate(0, 6)
		if button("Edit fight area", 240, 40) then
			local at = GetPlayerTransform(me).pos                   -- (where the host stands; else the lobby camera's target)
			if VecLength(at) < 0.01 and shared._camTarget then at = shared._camTarget end
			brawlEditorOpen(b.area, at)
		end
		if b.src == "host" then
			UiTranslate(256, 0)
			if button("Use the map's area", 260, 40) then brawlUseMapArea() end
		end
	end
	UiPop()
end

-- is a lobby UI panel under the cursor (a press there is the panel's, not a drag of the area): the Brawl panel, the
-- cut hint line, mplib's team boxes (as teamsDraw lays them out), its host menu and the settings drawer
function overLobbyUI(mx, my)
	local function inside(r) return r and mx >= r[1] and mx <= r[1] + r[3] and my >= r[2] and my <= r[2] + r[4] end
	if inside(C.panelRect) then return true end
	if inside({30, UiHeight() - 90, 980, 40}) then return true end
	if BV.barRect and inside(BV.barRect) then return true end
	local n = shared._teamState and #shared._teamState.teams or 2
	local tw, th = 20 + 292 * n + 20 * (n - 1) + 10, 452
	if inside({UiCenter() - tw / 2, UiMiddle() - th / 2, tw, th}) then return true end
	if inside({UiCenter() - 220, UiMiddle() + 270, 440, 210}) then return true end   -- (its status line, the host menu)
	if _hud.settings and _hud.settings.visible and inside({0, 0, 600, UiHeight()}) then return true end
	return false
end

local function drawLobby(b, dt)
	local typing = chatAlive() and chatTyping()
	if typing then chattingNote(); return end
	if brawlEditorActive() then brawlEditorDraw(); return end
	local opening = lobbyChatOpening()
	UiPush()
	if opening then UiDisableInput() end
	teamsDraw(dt)
	brawlViewApply()                                             -- (after mplib's lobby: our camera)
	brawlViewRefine()                                            -- (the framing, measured)
	UiPush()
	UiTranslate(40, UiHeight() - 70)
	UiAlign("left middle")
	UiFont("bold.ttf", 20)
	UiColor(1, 1, 1, 0.85)
	UiText(brawlViewHint())
	UiPop()
	brawlDrawHeightBar(b and b.src ~= "none" and b.area or "")     -- (the cut, at the right edge)
	C.panelRect = nil
	if b and not (_hud.settings and _hud.settings.visible) then drawLobbyPanel(b) end
	if not hudGameIsSetup() then
		if hudDrawGameSetup(brawlSettings(b and b.combat or brawlCombatPresent())) and not opening then
			ServerCall("server.start", {roundTime = GetFloat(ROUND_KEY), ff = GetString(FF_KEY), loadout = GetString(LOADOUT_KEY)})
		end
	end
	if not opening then brawlMoveDraw(b, overLobbyUI) end        -- (the host drags the area round)
	if brawlMoveHover() then
		local mx, my = UiGetMousePos()
		UiPush()
		UiTranslate(mx + 22, my + 22)
		UiAlign("left top")
		UiFont("bold.ttf", 18)
		local tw = UiGetTextSize("Drag to move the fight area")
		UiColor(0, 0, 0, 0.6)
		UiRect(tw + 16, 26)
		UiTranslate(8, 3)
		UiColor(0.6, 0.95, 1, 1)
		UiText("Drag to move the fight area")
		UiPop()
	end
	UiPop()
	if opening then SetBool("proxchat.open", true) end
end

-- (both) the fighters of a team still in the round (not eliminated, not a late joiner)
local function teamIn(b, i)
	local n = 0
	for _, p in ipairs(teamsGetTeamPlayers(i)) do
		if IsPlayerValid(p) and not (b.out or {})[p] and not (b.late or {})[p] then n = n + 1 end
	end
	return n
end

local function sortedTeams(b)
	local l = {}
	for i = 1, b.nTeams or 2 do l[i] = i end
	table.sort(l, function(x, y)
		local a, c = teamIn(b, x), teamIn(b, y)
		if a ~= c then return a > c end
		a, c = (b.teamKOs or {})[x] or 0, (b.teamKOs or {})[y] or 0
		if a ~= c then return a > c end
		return x < y
	end)
	return l
end

local COLUMNS = {{name = "KOs", align = "center"}, {name = "Elims", align = "center"}, {name = "Damage", align = "center"},
	{name = "Status", align = "center"}}

local function status(b, p)
	if (b.late or {})[p] then return "joined late" end
	if (b.out or {})[p] then return "out" end
	if bkKnocked()[p] then return "knocked" end
	return "in"
end

local function scoreGroups(b, results)
	local groups, byTeam = {}, {}
	for _, i in ipairs(sortedTeams(b)) do
		local g = {name = string.format("%s  -  %d in, %d KOs", teamName(i), teamIn(b, i), (b.teamKOs or {})[i] or 0),
			color = teamColor(i), rows = {}, outline = results}
		groups[#groups + 1] = g
		byTeam[i] = g
	end
	for p in Players() do
		local g = byTeam[teamsGetTeamId(p)]
		if g then
			local k, d = (b.kos or {})[p] or 0, (b.dmg or {})[p] or 0
			g.rows[#g.rows + 1] = {player = p, k = k, d = d,
				columns = {tostring(k), tostring((b.elims or {})[p] or 0), tostring(math.floor(d * 100 + 0.5)), status(b, p)}}
		end
	end
	for _, g in ipairs(groups) do
		table.sort(g.rows, function(x, y) if x.k ~= y.k then return x.k > y.k end return x.d > y.d end)
	end
	return groups
end

-- a box per team under the timer: its fighters still in (big), its knockdowns (small)
local function drawTeamScores(b)
	local n = b.nTeams or 2
	local w = 96
	UiPush()
	UiTranslate(UiCenter() - (n * w + (n - 1) * 10) / 2, 96)
	UiAlign("left top")
	for i = 1, n do
		local c = teamColor(i)
		UiPush()
		UiColor(c[1], c[2], c[3], teamsGetTeamId(GetLocalPlayer()) == i and 0.95 or 0.6)
		UiRoundedRect(w, 52, 6)
		UiTranslate(w / 2, 20)
		UiAlign("center middle")
		UiFont("bold.ttf", 30)
		UiColor(1, 1, 1, 1)
		UiText(tostring(teamIn(b, i)))
		UiTranslate(0, 22)
		UiFont("bold.ttf", 14)
		UiText(((b.teamKOs or {})[i] or 0) .. " KOs")
		UiTranslate(0, 22)
		UiColor(c[1], c[2], c[3], 1)
		UiText(string.format("%s %d %%", teamName(i), math.floor(((b.teamPct or {})[i] or 0) * 100 + 0.5)))
		UiPop()
		UiTranslate(w + 10, 0)
	end
	UiPop()
end

local FEED_KINDS = {knockdown = true, eliminated = true, combo = true, getup = true}

local function drawFeed(b)
	local y = 180
	for i = #(b.feed or {}), 1, -1 do
		local e = b.feed[i]
		local age = (b.clock or 0) - e.at
		if age < 4 and FEED_KINDS[e.kind] then
			local a = math.min(1, (4 - age) / 0.8)
			local by = e.k ~= 0 and e.k ~= e.v
			local text
			if e.kind == "knockdown" then
				text = by and (GetPlayerName(e.k) .. "  knocked down  " .. GetPlayerName(e.v)) or (GetPlayerName(e.v) .. " is down")
			elseif e.kind == "eliminated" then
				text = GetPlayerName(e.v) .. " is OUT" .. (by and ("  (" .. GetPlayerName(e.k) .. ")") or "")
			elseif e.kind == "getup" then
				text = GetPlayerName(e.v) .. " is back up"
			else
				text = GetPlayerName(e.k) .. "  COMBO x" .. e.hits .. "  on  " .. GetPlayerName(e.v)
			end
			local c = e.team ~= 0 and teamColor(e.team) or {1, 1, 1}
			bigText(y, (e.kind == "knockdown" or e.kind == "eliminated") and 26 or 20, text, c[1], c[2], c[3], a)
			y = y + 32
		end
	end
end

local function drawNames(me)
	local mine = teamsGetTeamId(me)
	local b = shared.brawl or {}
	for i = 1, (b.nTeams or 2) do
		local list = {}
		for _, p in ipairs(teamsGetTeamPlayers(i)) do
			if p ~= me and not (b.out or {})[p] and not (b.late or {})[p] then list[#list + 1] = p end
		end
		if #list > 0 then hudDrawPlayerWorldMarkers(list, i ~= mine, i == mine and 9999 or 40, teamColor(i)) end
	end
end

-- your own knockdown: the time left and the small second bar (a third of the width of a full bar)
-- (the game's own health bar: data/ui/hud.lua drawHealth - 110 x 20, rounded 10, bottom right, "HEALTH" before it;
--  it hides at full health, and a knocked player's engine health is held at 1 - the knock bar takes its place)
KNOCK_BAR_W, KNOCK_BAR_H = 110, 20
function brawlKnockBarRect() return UiWidth() - 144 + 10, UiHeight() - 44 + 4, KNOCK_BAR_W, KNOCK_BAR_H end

local function drawKnocked(s)
	bigText(UiMiddle() - 120, 44, string.format("KNOCKED DOWN - %.1f s", s.left or 0), 1, 0.85, 0.3)
	bigText(UiMiddle() - 76, 18, "Hold on: up again when the time runs out - if the red bar lasts", 0.9, 0.9, 0.9, 0.85)
	local x, y, w, h = brawlKnockBarRect()
	local k = math.max(0, math.min(1, s.bar or 0))
	UiPush()
	UiTranslate(x - 10, y + 18)
	UiAlign("right")
	UiFont("bold.ttf", 24)
	UiColor(1, 0.2, 0.15, 1)
	UiText("KNOCKED")
	UiPop()
	UiPush()
	UiTranslate(x, y)
	UiAlign("left top")
	UiColor(0, 0, 0, 0.5)
	UiRoundedRect(w, h, 10)
	if k > 0 then
		UiTranslate(3, 3)
		UiColor(0.95, 0.15, 0.1, 1)
		UiRoundedRect(math.max(12, (w - 6) * k), h - 6, 7)
	end
	UiPop()
	BRAWL_KNOCK_BAR = {w = w, h = h, fill = k}                    -- (the offline tests read it)
end

local function spectating(b, me)
	return (b.phase == "fight" or b.phase == "ready") and ((b.out or {})[me] or (b.late or {})[me])
end

local function drawSpectate(b, me)
	if (b.late or {})[me] then
		bigText(110, 28, "Spectating - joins next round", 0.85, 0.85, 0.9, 0.9)
		bigText(145, 18, "You joined mid-round: you play from the next one (" .. teamName(teamsGetTeamId(me)) .. ")", 0.75, 0.75, 0.75, 0.85)
	else
		bigText(110, 30, "ELIMINATED - spectating", 1, 0.4, 0.35, 0.9)
	end
	spectateDraw()
	local actions = inputActionsCreate()
	spectateAppendInputActions(actions)
	hudDrawInputActions(actions)
end

-- the round's clock on this machine: the server's time left (5 a second) run down locally between updates, so it
-- reaches 0:00 exactly when the round ends
function roundClock(b)
	if b.clock ~= C.tClock then C.tClock, C.tVal, C.tAt = b.clock, b.t, GetTime() end
	return math.max(0, (C.tVal or b.t) - (GetTime() - (C.tAt or GetTime())))
end

local function drawFight(b, me, dt)
	hudDrawTimer(math.max(0, roundClock(b) - 0.999), 1)          -- (whole seconds left, floored: 0:00 in the last one -
	                                                             --  at the round's end; mplib's timer rounds up)
	drawTeamScores(b)
	drawNames(me)
	bkDrawBars(me)
	drawFeed(b)
	local since = GetTime() - C.fightT
	if since < 1.4 then bigText(UiMiddle() - 80, 90, "FIGHT!", 1, 0.85, 0.3, math.min(1, (1.4 - since) / 0.4)) end
	local mine = bkKnocked()[me]
	if spectating(b, me) then
		drawSpectate(b, me)
	elseif mine then
		drawKnocked(mine)
	elseif b.src ~= "none" and b.inside and b.inside[me] == false then
		bigText(UiHeight() - 170, 30, "Outside the fight area: no damage", 1, 0.55, 0.1, 0.6 + 0.4 * math.abs(math.sin(GetTime() * 3)))
	end
	hudDrawDamageIndicators(dt)
	hudDrawScoreboard(hudIsScoreboardRequested(), "Brawl", COLUMNS, scoreGroups(b, false))
end

local function drawReady(b, me)
	drawTeamScores(b)
	local mine = teamsGetTeamId(me)
	local c = teamColor(mine)
	if (b.late or {})[me] then                                   -- (joined in the countdown: watching already)
		hudDrawTimer(math.max(0, (b.roundTime or 0) - 0.999), 1)
		drawSpectate(b, me)
		return
	end
	bigText(UiMiddle() - 150, 30, "You fight for " .. teamName(mine), c[1], c[2], c[3])
	bigText(UiMiddle() - 40, 120, tostring(math.max(1, math.ceil(b.t))), 1, 1, 1)
	bigText(UiMiddle() + 60, 22, (b.combat and "Bare hands (Combat System)" or "Weapons") .. " - into the ring!", 0.85, 0.85, 0.85)
end

local function drawResults(b)
	local groups = scoreGroups(b, true)
	local banner, color
	if (b.winner or 0) == 0 then
		banner, color = "DRAW", {0, 0, 0, 0.75}
		for _, g in ipairs(groups) do g.dim = false end
	else
		local c = teamColor(b.winner)
		banner, color = string.upper(teamName(b.winner)) .. " WINS", {c[1], c[2], c[3], 0.75}
		for i, g in ipairs(groups) do                              -- (the winner first)
			if g.name:sub(1, #teamName(b.winner)) == teamName(b.winner) and i > 1 then table.remove(groups, i); table.insert(groups, 1, g); break end
		end
	end
	-- the board's title is the why (mplib widens the board to its title: kept short); the top fighter on a line of
	-- its own over the board
	local title = (b.winWhy and b.winWhy ~= "") and b.winWhy or "Brawl"
	local top = ""
	if (b.top or 0) ~= 0 then
		top = string.format("Top fighter: %s - %d KOs, %d elims, %d damage", GetPlayerName(b.top), (b.kos or {})[b.top] or 0,
			(b.elims or {})[b.top] or 0, math.floor(((b.dmg or {})[b.top] or 0) * 100 + 0.5))
	end
	BRAWL_RESULTS_TITLE, BRAWL_RESULTS_TOP = title, top              -- (the offline tests read them)
	local _, bh, param = hudDrawResults(banner, color, title, COLUMNS, groups)
	if top ~= "" and bh and bh > 0 then
		bigText(UiMiddle() - bh / 2 - 26, 24, top, 1, 0.9, 0.5, math.min(1, param or 1))
	end
end

function client.draw(dt)
	local b = shared.brawl
	if not teamsIsSetup() then
		drawLobby(b, dt)
		hudDrawFade(dt)
		return
	end
	if not b then return end
	local me = GetLocalPlayer()
	if b.phase == "ready" then drawReady(b, me)
	elseif b.phase == "fight" then drawFight(b, me, dt)
	elseif b.phase == "over" then
		local typing = chatAlive() and chatTyping()
		local opening = lobbyChatOpening()
		if typing then chattingNote()
		else
			UiPush()
			if opening then UiDisableInput() end
			drawResults(b)
			UiPop()
			if opening then SetBool("proxchat.open", true) end
		end
	end
	hudDrawFade(dt)
end

-- the eliminated and late joiners watch the fighters still in (the game's spectate: starting on someone, not your body)
function brawlSpectateTick(b, me)
	if not spectating(b, me) then C.specStarted = false; return false end
	local list = {}
	for p in Players() do
		if p ~= me and not (b.out or {})[p] and not (b.late or {})[p] and GetPlayerHealth(p) > 0 then list[#list + 1] = p end
	end
	spectateTick(list)
	if not C.specStarted and list[1] and _spectateState and _spectateState.currPlayer == me then
		_setCurrentPlayer(list[1])
		C.specStarted = true
	end
	return true
end

function client.postUpdate(dt)
	bkClientPostUpdate(dt)
end

function client.render(dt)
	local b = shared.brawl
	if b and spectating(b, GetLocalPlayer()) then spectateRender(dt) end
end
