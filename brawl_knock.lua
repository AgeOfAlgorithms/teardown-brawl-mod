-- Brawl: what a knockdown looks like on every machine (client). Included by brawl.lua (no #version line); only GLOBALS
-- are shared. The server's state: shared.brawlKnock = {n, k = {[p] = {left = s, bar = 0..1}}} (brawl.lua).
--   The pose: kneeling, upright, dazed - the game's crouch_idle clip through the locomotion override
--   (game.override.animation.<p>, client.tick) and, from client.postUpdate (the only callback where posing another
--   player's character takes: Humans vs Clickers, verified), the feet IK'd 0.45 m behind the hips on the ground so
--   the knees are down, the head drooping and swaying a little (small angles, inside the joint limits).
--   Your own view: lowered KNOCK_CAM_DROP m with a slow dizzy roll.
--   The chicks: CHICKS client-spawned static bodies (MOD/vox/chick.vox, scale 0.5, no collision) per knocked player
--   circling CHICK_R m round a point CHICK_UP m over the head bone (else the feet + 1.25 m), CHICK_TURN turns a
--   second, each facing along its path, bobbing; deleted when the knockdown ends; your own hidden in first person.
-- Interface:
--   bkKnocked() -> {[p] = {left, bar}}      the knocked, as last published
--   bkClientTick(dt)                         the pose clip, your camera, spawning / deleting the chicks
--   bkClientPostUpdate(dt)                   the kneel IK, the head, the chicks' flight
--   bkDrawBars(me)                           the small bar over each other knocked player's head
--   bkChickCount() -> n                      (tests) chick bodies alive on this machine

KNOCK_CAM_DROP = 0.6      -- m your own view goes down while knocked
CHICK_XML = "<body tags='brawlchick'><vox file='MOD/vox/chick.vox' scale='0.5' collide='false'/></body>"

BK = {posed = {}, chicks = {}}

function bkKnocked()
	local t = shared.brawlKnock
	if type(t) == "table" and type(t.k) == "table" then return t.k end
	return {}
end

local function spawnChicks()
	local list = {}
	for _ = 1, CHICKS do
		for _, e in ipairs(Spawn(CHICK_XML, Transform(Vec(0, -500, 0)), true) or {}) do
			if GetEntityType(e) == "body" then
				list[#list + 1] = e
				for _, sh in ipairs(GetBodyShapes(e) or {}) do SetShapeCollisionFilter(sh, 128, 0) end
			end
		end
	end
	return list
end

local function deleteChicks(q)
	for _, b in ipairs(BK.chicks[q] or {}) do Delete(b) end
	BK.chicks[q] = nil
end

function bkChickCount()
	local n = 0
	for _, l in pairs(BK.chicks) do n = n + #l end
	return n
end

function bkClientTick(dt)
	local k = bkKnocked()
	local me = GetLocalPlayer()
	for q in pairs(BK.posed) do
		if not k[q] then
			BK.posed[q] = nil
			SetString("game.override.animation." .. q, "")
			SetFloat("game.override.animation." .. q .. ".weight", 0)
		end
	end
	for q in pairs(k) do
		if IsPlayerValid(q) then
			BK.posed[q] = true
			SetString("game.override.animation." .. q, "crouch_idle")
			SetFloat("game.override.animation." .. q .. ".weight", 1)
		end
	end
	if k[me] then
		local t = GetTime()
		SetPlayerCameraOffsetTransform(Transform(Vec(0, -KNOCK_CAM_DROP, 0), QuatEuler(0, 0, 5 * math.sin(t * 1.3))))
	end
	local firstPerson = not GetBool("game.thirdperson")
	for q in pairs(BK.chicks) do
		if not k[q] or not IsPlayerValid(q) or (q == me and firstPerson) then deleteChicks(q) end
	end
	for q in pairs(k) do
		if IsPlayerValid(q) and not BK.chicks[q] and not (q == me and firstPerson) then BK.chicks[q] = spawnChicks() end
	end
end

local function headOf(q, anim)
	if anim and anim ~= 0 then
		local h = GetBoneWorldTransform(anim, "head")
		if h and h.pos and VecLength(h.pos) > 0.001 then return h.pos end
	end
	return VecAdd(GetPlayerTransform(q).pos, Vec(0, 1.25, 0))
end

function bkClientPostUpdate(dt)
	local k = bkKnocked()
	local t = GetTime()
	for q in pairs(k) do
		if IsPlayerValid(q) and GetPlayerHealth(q) > 0 then
			local anim = GetPlayerAnimator(q)
			if anim and anim ~= 0 then                                -- kneeling: knees on the ground, the head dazed
				local pt = GetPlayerTransform(q)
				local fwd = TransformToParentVec(pt, Vec(0, 0, -1))
				fwd[2] = 0
				fwd = VecNormalize(fwd)
				local g = pt.pos[2]
				for _, s in ipairs({"l", "r"}) do
					local hip = GetBoneWorldTransform(anim, "leg_upper_" .. s)
					if hip then
						local foot = VecAdd(Vec(hip.pos[1], g + 0.08, hip.pos[3]), VecScale(fwd, -0.45))
						SetAnimatorTransformIK(anim, "leg_upper_" .. s, "foot_" .. s, Transform(foot, pt.rot), 1.0, 0.0, false, true)
					end
				end
				local sway = math.sin(t * 1.7 + q)
				RotateBone(anim, "chest", QuatEuler(sway * 4, 0, 0))
				RotateBone(anim, "neck", QuatEuler(sway * 8, 0, 10 + 4 * math.sin(t * 1.1 + q)))   -- (+z: forward)
				RotateBone(anim, "head", QuatEuler(sway * 10, 0, 8))
			end
			local list = BK.chicks[q]
			if list then
				local c = VecAdd(headOf(q, anim), Vec(0, CHICK_UP, 0))
				for i, b in ipairs(list) do
					local a = t * 2 * math.pi * CHICK_TURN + (i - 1) * 2 * math.pi / math.max(1, #list)
					local p = VecAdd(c, Vec(math.cos(a) * CHICK_R, 0.03 * math.sin(t * 6 + i), math.sin(a) * CHICK_R))
					local along = Vec(-math.sin(a), 0, math.cos(a))          -- (the way it flies: the model faces -z)
					SetBodyTransform(b, Transform(p, QuatLookAt(p, VecAdd(p, along))))
				end
			end
		end
	end
end

-- (the size of mplib's health bars over players: hud.lua's world markers, 91 x 12, rounded 6)
BK_BAR_W, BK_BAR_H = 91, 12
function bkDrawBars(me)
	for q, s in pairs(bkKnocked()) do
		if q ~= me and IsPlayerValid(q) then
			local x, y, dist = UiWorldToPixel(VecAdd(GetPlayerTransform(q).pos, Vec(0, 2.1, 0)))
			if dist and dist > 0 and dist < 60 then
				local k = math.max(0, math.min(1, s.bar or 0))
				UiPush()
				UiTranslate(x - BK_BAR_W / 2, y)
				UiAlign("left middle")
				UiColor(0, 0, 0, 0.75)
				UiRoundedRect(BK_BAR_W, BK_BAR_H, 6)
				if k > 0 then
					UiTranslate(2, 0)
					UiColor(0.95, 0.15, 0.1, 1)
					UiRoundedRect(math.max(12, (BK_BAR_W - 4) * k), BK_BAR_H - 4, 4)
				end
				UiPop()
			end
		end
	end
end
