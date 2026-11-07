-- Brawl: what healing looks like on every machine (client). Included by brawl.lua (no #version line); only GLOBALS
-- are shared. The server's state: shared.brawl.healing = {[p] = true} while a fighter's health is going up (brawl.lua).
--   The aura: a soft white glow (MOD/gfx/heal_aura.png, an upright ellipse: tools/make_cross.py; additive, depth-
--   tested, HEAL_AURA_BACK m behind the body as the camera sees it, so the body hides its middle and it shows round
--   the silhouette) breathing slowly,
--   fading in and out over HEAL_FADE s; a few faint white motes drifting up. Hidden for yourself in first person (the
--   camera at your eyes: it would wash over your view) - your own crosses still rise around you.
--   The crosses: MOD/gfx/heal_cross.png (tools/make_cross.py) billboards, one every HEAL_CROSS_EVERY s per healing
--   player at a random angle round the body, rising HEAL_CROSS_RISE m/s and fading over HEAL_CROSS_LIFE s.
-- Interface:
--   bhClientTick(dt)              the aura and the crosses (DrawSprite: from client.tick)
--   bhCrossCount() -> n           (tests) crosses alive on this machine

HEAL_FADE = 0.4           -- s the aura takes to fade in / out
HEAL_AURA_A = 0.3         -- the aura's alpha (subtle: additive white; 0.13 was lost on the spotlit canvas)
HEAL_AURA_BACK = 0.4      -- m the aura sits behind the body (from the camera): through the body it lit half of it
HEAL_CROSS_EVERY = 0.28   -- s between two crosses round one player
HEAL_CROSS_LIFE = 1.5     -- s a cross lives
HEAL_CROSS_RISE = 0.55    -- m/s it rises
HEAL_CROSS_SIZE = 0.13    -- m
HEAL_CROSS_A = 0.75

BH = {aura = {}, crosses = {}, nextCross = {}}

function bhCrossCount() return #BH.crosses end

local function healingList()
	local b = shared.brawl
	if type(b) == "table" and type(b.healing) == "table" then return b.healing end
	return {}
end

local function billboard(pos, cam) return Transform(pos, QuatLookAt(pos, cam)) end

function bhClientTick(dt)
	if not BH.glare then
		BH.glare = LoadSprite("MOD/gfx/heal_aura.png")
		BH.cross = LoadSprite("MOD/gfx/heal_cross.png")
	end
	local now = GetTime()
	local heal = healingList()
	local me = GetLocalPlayer()
	local cam = GetCameraTransform().pos
	local firstPerson = not GetBool("game.thirdperson")                   -- (and the camera at your own eyes: not a
		and VecLength(VecSub(cam, GetPlayerEyeTransform(me).pos)) < 0.5   --  spectator's or a scripted one)
	for p in pairs(heal) do if BH.aura[p] == nil then BH.aura[p] = 0 end end
	for p, a in pairs(BH.aura) do
		local on = heal[p] and IsPlayerValid(p) and GetPlayerHealth(p) > 0
		a = math.max(0, math.min(1, a + (on and 1 or -1) * dt / HEAL_FADE))
		BH.aura[p] = a
		if a <= 0 and not on then
			BH.aura[p], BH.nextCross[p] = nil, nil
		elseif IsPlayerValid(p) then
			local feet = GetPlayerTransform(p).pos
			if not (p == me and firstPerson) then
				local breathe = 0.85 + 0.15 * math.sin(now * 3 + p)
				local c = VecAdd(feet, Vec(0, 0.95, 0))
				local away = VecSub(c, cam)                            -- (behind the body as seen from the camera:
				away[2] = 0                                            --  a halo round it, not a pane through it)
				if VecLength(away) > 0.01 then c = VecAdd(c, VecScale(VecNormalize(away), HEAL_AURA_BACK)) end
				DrawSprite(BH.glare, billboard(c, cam), 1.4, 2.4, 1, 1, 1, HEAL_AURA_A * a * breathe, true, true)
				if a >= 1 and math.random() < dt * 6 then              -- (faint motes drifting up)
					local ang = math.random() * 6.283
					ParticleReset()
					ParticleType("plain")
					ParticleColor(1, 1, 1)
					ParticleRadius(0.015, 0.005)
					ParticleAlpha(0.7, 0)
					ParticleEmissive(4, 0)
					ParticleGravity(0)
					ParticleDrag(0)
					ParticleCollide(0)
					SpawnParticle(VecAdd(feet, Vec(math.cos(ang) * 0.4, 0.2 + math.random() * 1.2, math.sin(ang) * 0.4)),
						Vec(0, 0.35, 0), 1.2)
				end
			end
			if on and now >= (BH.nextCross[p] or 0) then
				BH.nextCross[p] = now + HEAL_CROSS_EVERY * (0.8 + 0.4 * math.random())
				local ang = math.random() * 6.283
				local r = 0.42 + math.random() * 0.15
				BH.crosses[#BH.crosses + 1] = {p = p, t0 = now, dx = math.cos(ang) * r, dz = math.sin(ang) * r,
					y = 0.25 + math.random() * 1.1, s = HEAL_CROSS_SIZE * (0.8 + 0.4 * math.random())}
			end
		end
	end
	-- the crosses: following their player sideways (they rise around a moving fighter), rising, fading out
	local keep = {}
	for _, c in ipairs(BH.crosses) do
		local age = now - c.t0
		if age < HEAL_CROSS_LIFE and IsPlayerValid(c.p) then
			keep[#keep + 1] = c
			local feet = GetPlayerTransform(c.p).pos
			local pos = VecAdd(feet, Vec(c.dx, c.y + age * HEAL_CROSS_RISE, c.dz))
			local fade = math.min(1, age / 0.2) * math.min(1, (HEAL_CROSS_LIFE - age) / 0.6)
			DrawSprite(BH.cross, billboard(pos, cam), c.s, c.s, 1, 1, 1, HEAL_CROSS_A * fade, true, true)
		end
	end
	BH.crosses = keep
end
