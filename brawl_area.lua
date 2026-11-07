-- Brawl: the fight area - reading the API strings, inside tests, random points, the drawn outline.
-- Included by brawl.lua (no #version line); only GLOBALS are shared with it. Interface:
--   baParse(str) -> shapes, bad          the area string (brawl.area / the host's edit): parts separated by ';'
--                                        "box x0 y0 z0 x1 y1 z1"   axis-aligned world box (metres, any corner order)
--                                        "cyl x y z radius height"  vertical cylinder from y up to y + height
--                                        "poly y0 y1 x1 z1 x2 z2 x3 z3 ..."  vertical prism: polygon in x/z, y0..y1
--                                        "zone floor x1 z1 x2 z2 x3 z3 ..."  a polygon with NO height limit: every
--                                          floor inside its outline counts (the host's drawn areas - the user: "let's
--                                          allow fighting it on every floor vertically in the area"); `floor` is its
--                                          reference floor (the lowest drawn corner's) for the outline and the spawns
--                                        shapes: {kind = "box"|"cyl"|"poly"|"zone"|"trigger", ...}; bad = parts not read
--   baShapeString(s)                     one shape back as an API string (a trigger as its bounding box)
--   baAreaString(shapes)                 all of them, ';'-separated
--   baContains(s, p) / baInside(shapes, p)   is world point p inside (a trigger: IsPointInTrigger)
--   baBounds(s) -> min, max              world bounds (a cylinder's box, a polygon's)
--   baTop(s), baBottom(s)                its height range
--   baCentre(shapes) -> Vec, span        bounding-box centre (at the lowest floor) and the larger x/z extent
--   baRandomPoint(shapes, avoid, minGap) a random ground point inside (raycast down, under roofs too), or nil
--   baOutsideSpot(shapes, angle, lateral, avoid) -> Vec | nil   a spawn spot 2-5 m outside the area (on its floor's level)
--   baAreaFloor(shapes), baInsideXZ(shapes, x, z)
--   baValidatePoly(str) -> clean | nil, err   the host's polygon: 3-BA_MAX_CORNERS corners, finite numbers, y0 < y1
--   baPolyString(pts)                    corners {x, y, z} -> "poly y0 y1 ..." (y0 = lowest - 1 m, y1 = highest + BA_HEADROOM)
--   baZoneString(pts)                    corners {x, y, z} -> "zone floor ..." (floor = the lowest corner's y)
--   baUnbounded(shapes) -> bool          any part without a height limit (a zone)
--   baEditorCorners(shapes) -> {{x, z}}  the editor's starting corners: a polygon's own, a cylinder's octagon,
--                                        otherwise the bounding box of all parts (nil: no area)
--   baBuildOutline(shapes) -> outline    ground-following segments + corner posts (raycasts: build it once per
--   baBuildLoopOutline(pts, top, bottom)  change, never per frame)
--   baDrawOutline(outline, r, g, b)      draw it (client, every frame): glowing ribbons + posts

BA_MAX_CORNERS = 32
BA_SAMPLE = 0.5            -- m between the outline's ground samples
BA_POST_H = 2.2            -- m: the corner posts
BA_DRAW_RANGE = 160        -- m: segments farther from the camera are skipped
BA_HEADROOM = 5           -- m above the highest corner: a drawn polygon's top (+8 could take in a warehouse roof: spawns up there)

local function finite(x) return type(x) == "number" and x == x and x > -100000 and x < 100000 end

local function nums(rest)
	local l = {}
	for w in rest:gmatch("%S+") do
		local v = tonumber(w)
		if not finite(v) then return nil end
		l[#l + 1] = v
	end
	return l
end

local function parsePart(part)
	local kind, rest = part:match("^%s*(%a+)%s*(.-)%s*$")
	if not kind then return nil end
	kind = kind:lower()
	local n = nums(rest)
	if not n then return nil end
	if kind == "box" and #n == 6 then
		return {kind = "box", x0 = math.min(n[1], n[4]), y0 = math.min(n[2], n[5]), z0 = math.min(n[3], n[6]),
			x1 = math.max(n[1], n[4]), y1 = math.max(n[2], n[5]), z1 = math.max(n[3], n[6])}
	elseif kind == "cyl" and #n == 5 and n[4] > 0 and n[5] > 0 then
		return {kind = "cyl", x = n[1], y = n[2], z = n[3], r = n[4], h = n[5]}
	elseif kind == "poly" and #n >= 8 and #n % 2 == 0 and n[2] > n[1] then
		local pts = {}
		for i = 3, #n, 2 do pts[#pts + 1] = {n[i], n[i + 1]} end
		if #pts > BA_MAX_CORNERS then return nil end
		return {kind = "poly", y0 = n[1], y1 = n[2], pts = pts}
	elseif kind == "zone" and #n >= 7 and #n % 2 == 1 then
		local pts = {}
		for i = 2, #n, 2 do pts[#pts + 1] = {n[i], n[i + 1]} end
		if #pts > BA_MAX_CORNERS then return nil end
		-- (y0 / y1: only the band where its outline and its floor are looked for; the inside test ignores the height)
		return {kind = "zone", floor = n[1], y0 = n[1] - 1, y1 = n[1] + 1.5, pts = pts}
	end
	return nil
end

function baParse(str)
	local shapes, bad = {}, 0
	if type(str) ~= "string" then return shapes, 0 end
	for part in (str .. ";"):gmatch("([^;]*);") do
		if part:match("%S") then
			local s = parsePart(part)
			if s then shapes[#shapes + 1] = s else bad = bad + 1 end
		end
	end
	return shapes, bad
end

local function f2(x) return string.format("%.2f", x) end

function baShapeString(s)
	if s.kind == "box" or s.kind == "trigger" then
		return "box " .. table.concat({f2(s.x0), f2(s.y0), f2(s.z0), f2(s.x1), f2(s.y1), f2(s.z1)}, " ")
	elseif s.kind == "cyl" then
		return "cyl " .. table.concat({f2(s.x), f2(s.y), f2(s.z), f2(s.r), f2(s.h)}, " ")
	elseif s.kind == "poly" then
		local l = {"poly", f2(s.y0), f2(s.y1)}
		for _, p in ipairs(s.pts) do l[#l + 1] = f2(p[1]); l[#l + 1] = f2(p[2]) end
		return table.concat(l, " ")
	elseif s.kind == "zone" then
		local l = {"zone", f2(s.floor)}
		for _, p in ipairs(s.pts) do l[#l + 1] = f2(p[1]); l[#l + 1] = f2(p[2]) end
		return table.concat(l, " ")
	end
	return ""
end

function baAreaString(shapes)
	local l = {}
	for _, s in ipairs(shapes) do l[#l + 1] = baShapeString(s) end
	return table.concat(l, ";")
end

-- even-odd test of (x, z) against the polygon's x/z corners (concave shapes too)
local function inPoly(pts, x, z)
	local inside, j = false, #pts
	for i = 1, #pts do
		local xi, zi, xj, zj = pts[i][1], pts[i][2], pts[j][1], pts[j][2]
		if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then inside = not inside end
		j = i
	end
	return inside
end

local function inXZ(s, x, z)
	if s.kind == "box" or s.kind == "trigger" then return x >= s.x0 and x <= s.x1 and z >= s.z0 and z <= s.z1
	elseif s.kind == "cyl" then local dx, dz = x - s.x, z - s.z; return dx * dx + dz * dz <= s.r * s.r
	elseif s.kind == "poly" or s.kind == "zone" then return inPoly(s.pts, x, z) end
	return false
end

function baBottom(s)
	if s.kind == "cyl" then return s.y end
	return s.y0
end

function baTop(s)
	if s.kind == "cyl" then return s.y + s.h end
	return s.y1
end

function baContains(s, p)
	if s.kind == "trigger" then return IsPointInTrigger(s.h, p) end
	if s.kind == "zone" then return inXZ(s, p[1], p[3]) end      -- (every floor counts)
	if p[2] < baBottom(s) or p[2] > baTop(s) then return false end
	return inXZ(s, p[1], p[3])
end

function baInside(shapes, p)
	for _, s in ipairs(shapes) do if baContains(s, p) then return true end end
	return false
end

function baBounds(s)
	if s.kind == "box" or s.kind == "trigger" then return Vec(s.x0, s.y0, s.z0), Vec(s.x1, s.y1, s.z1)
	elseif s.kind == "cyl" then return Vec(s.x - s.r, s.y, s.z - s.r), Vec(s.x + s.r, s.y + s.h, s.z + s.r) end
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ipairs(s.pts) do
		x0, x1, z0, z1 = math.min(x0, p[1]), math.max(x1, p[1]), math.min(z0, p[2]), math.max(z1, p[2])
	end
	return Vec(x0, s.y0, z0), Vec(x1, s.y1, z1)
end

local function allBounds(shapes)
	local lo, hi
	for _, s in ipairs(shapes) do
		local a, b = baBounds(s)
		if not lo then lo, hi = a, b
		else
			lo = Vec(math.min(lo[1], a[1]), math.min(lo[2], a[2]), math.min(lo[3], a[3]))
			hi = Vec(math.max(hi[1], b[1]), math.max(hi[2], b[2]), math.max(hi[3], b[3]))
		end
	end
	return lo, hi
end

function baCentre(shapes)
	local lo, hi = allBounds(shapes)
	if not lo then return nil, 0 end
	return Vec((lo[1] + hi[1]) / 2, lo[2], (lo[3] + hi[3]) / 2), math.max(hi[1] - lo[1], hi[3] - lo[3])
end

-- the first floor under (x, z) from the top of s down to its bottom that is inside s (under a roof too: a hit that
-- is not inside - a roof, a beam - the ray goes on below it)
local function groundIn(s, x, z)
	local top, bottom = baTop(s), baBottom(s)
	local o = Vec(x, top, z)
	local left = top - bottom + 0.6
	for _ = 1, 6 do
		if left <= 0 then return nil end
		local hit, d = QueryRaycast(o, Vec(0, -1, 0), left)
		if not hit then return nil end
		local g = Vec(x, o[2] - d, z)
		if baContains(s, VecAdd(g, Vec(0, 0.5, 0))) then return g end
		o = Vec(x, g[2] - 0.15, z)
		left = left - d - 0.15
	end
	return nil
end

-- room to stand: no static shape in a slim box over the point (the ring's ropes, a wall)
local function standable(g)
	for _, sh in ipairs(QueryAabbShapes(VecAdd(g, Vec(-0.3, 0.3, -0.3)), VecAdd(g, Vec(0.3, 1.8, 0.3))) or {}) do
		local b = GetShapeBody(sh)
		if b ~= 0 and not IsBodyDynamic(b) then return false end
	end
	return true
end

function baRandomPoint(shapes, avoid, minGap)
	if #shapes == 0 then return nil end
	local weights, total = {}, 0
	for i, s in ipairs(shapes) do
		local a, b = baBounds(s)
		weights[i] = math.max(1, (b[1] - a[1]) * (b[3] - a[3]))
		total = total + weights[i]
	end
	local fallback
	for attempt = 1, 48 do
		local pick, w = shapes[#shapes], math.random() * total
		for i, s in ipairs(shapes) do
			w = w - weights[i]
			if w <= 0 then pick = s; break end
		end
		local a, b = baBounds(pick)
		local x, z = a[1] + math.random() * (b[1] - a[1]), a[3] + math.random() * (b[3] - a[3])
		if inXZ(pick, x, z) then
			local g = groundIn(pick, x, z)
			if g then
				local far = true
				if avoid and attempt <= 32 then
					for _, q in ipairs(avoid) do
						local dx, dz = q[1] - g[1], q[3] - g[3]
						if dx * dx + dz * dz < (minGap or 1.5) ^ 2 then far = false end
					end
				end
				if far and standable(g) then return g end
				fallback = fallback or g
			end
		end
	end
	return fallback
end

----- spawning OUTSIDE the area (the user: "players should always spawn outside of the fight zone") -----

BA_OUT_MIN, BA_OUT_MAX = 2, 5     -- m outside the boundary (along the team's direction from the centre)
BA_OUT_FLOOR = 1.5                -- m: the spot's floor within this of the area's floor (no roofs, no pits)
BA_OUT_GAP = 0.9                  -- m at least between two spots

function baUnbounded(shapes)
	for _, s in ipairs(shapes) do if s.kind == "zone" then return true end end
	return false
end

function baInsideXZ(shapes, x, z)
	for _, s in ipairs(shapes) do if inXZ(s, x, z) then return true end end
	return false
end

-- the area's floor: the first floor inside it under its centre (else its lowest bottom)
function baAreaFloor(shapes)
	local c = baCentre(shapes)
	if not c then return 0 end
	for _, s in ipairs(shapes) do if s.kind == "zone" then return s.floor end end   -- (its reference floor)
	local lo = math.huge
	for _, s in ipairs(shapes) do
		if inXZ(s, c[1], c[3]) then
			local g = groundIn(s, c[1], c[3])
			if g then return g[2] end
		end
		lo = math.min(lo, baBottom(s))
	end
	return lo
end

-- a floor, not a bar's top or a rope: rays 0.3 m to all four sides find it within 0.15 m
local function floorAt(x, y, z)
	for _, o in ipairs({{0.3, 0}, {-0.3, 0}, {0, 0.3}, {0, -0.3}}) do
		local hit, t = QueryRaycast(Vec(x + o[1], y + 0.2, z + o[2]), Vec(0, -1, 0), 0.4)
		if not hit or math.abs(y + 0.2 - t - y) > 0.15 then return false end
	end
	return true
end

-- room for a player: nothing within 0.3 m of the points 0.9 and 1.6 m over the feet
local function headroom(g)
	for _, h in ipairs({0.9, 1.6}) do
		if QueryClosestPoint(VecAdd(g, Vec(0, h, 0)), 0.3) then return false end
	end
	return true
end

-- a spawn spot BA_OUT_MIN..BA_OUT_MAX m outside the area along the direction `angle` (degrees, from the area's
-- centre in x/z), shifted `lateral` m sideways (teammates side by side), on a floor within BA_OUT_FLOOR m of the
-- area's floor, not inside any part (1 m clear of it), with headroom, BA_OUT_GAP from the `avoid` points; tried at
-- the angle and up to 36 degrees either side. nil: none found
function baOutsideSpot(shapes, angle, lateral, avoid)
	local c = baCentre(shapes)
	if not c then return nil end
	local floor = baAreaFloor(shapes)
	for _, da in ipairs({0, 12, -12, 24, -24, 36, -36}) do
		local a = math.rad(angle + da)
		local dx, dz = math.cos(a), math.sin(a)
		local bx, bz = c[1] - dz * (lateral or 0), c[3] + dx * (lateral or 0)
		local r = 0
		while r < 300 and baInsideXZ(shapes, bx + dx * r, bz + dz * r) do r = r + 0.25 end
		for off = BA_OUT_MIN, BA_OUT_MAX + 0.01, 0.5 do
			local x, z = bx + dx * (r + off), bz + dz * (r + off)
			if not baInsideXZ(shapes, x, z) and not baInsideXZ(shapes, x - dx, z - dz) then
				local o, left = Vec(x, floor + BA_OUT_FLOOR + 1.5, z), 2 * BA_OUT_FLOOR + 1.5
				for _ = 1, 6 do
					local hit, t = QueryRaycast(o, Vec(0, -1, 0), left)
					if not hit then break end
					local g = Vec(x, o[2] - t, z)
					if math.abs(g[2] - floor) <= BA_OUT_FLOOR and floorAt(x, g[2], z) and headroom(g)
						and not baInside(shapes, VecAdd(g, Vec(0, 0.5, 0))) then
						local far = true
						for _, q in ipairs(avoid or {}) do
							if (q[1] - x) ^ 2 + (q[3] - z) ^ 2 < BA_OUT_GAP ^ 2 then far = false end
						end
						if far then return g end
					end
					o = Vec(x, g[2] - 0.15, z)
					left = left - t - 0.15
					if left <= 0 then break end
				end
			end
		end
	end
	return nil
end

-- any area the host sends (a drawn polygon, a moved box / cylinder / several parts): every part readable, 1-8 parts
BA_MAX_PARTS = 8
function baValidateArea(str)
	if type(str) ~= "string" or #str > 4000 then return nil, "too long" end
	local shapes, bad = baParse(str)
	if bad > 0 or #shapes == 0 or #shapes > BA_MAX_PARTS then return nil, "not an area" end
	for _, s in ipairs(shapes) do if (s.kind == "poly" or s.kind == "zone") and #s.pts < 3 then return nil, "fewer than 3 corners" end end
	return baAreaString(shapes)
end

-- every part moved by (dx, dy, dz) - a copy
function baTranslate(shapes, dx, dy, dz)
	local out = {}
	for i, s in ipairs(shapes) do
		local c = {}
		for k, v in pairs(s) do c[k] = v end
		if s.kind == "box" or s.kind == "trigger" then
			c.kind, c.h = "box", nil
			c.x0, c.x1, c.y0, c.y1, c.z0, c.z1 = s.x0 + dx, s.x1 + dx, s.y0 + dy, s.y1 + dy, s.z0 + dz, s.z1 + dz
		elseif s.kind == "cyl" then
			c.x, c.y, c.z = s.x + dx, s.y + dy, s.z + dz
		elseif s.kind == "poly" or s.kind == "zone" then
			c.y0, c.y1, c.pts = s.y0 + dy, s.y1 + dy, {}
			if s.floor then c.floor = s.floor + dy end
			for j, p in ipairs(s.pts) do c.pts[j] = {p[1] + dx, p[2] + dz} end
		end
		out[i] = c
	end
	return out
end

function baValidatePoly(str)
	if type(str) ~= "string" or #str > 4000 then return nil, "too long" end
	local shapes, bad = baParse(str)
	if bad > 0 or #shapes ~= 1 or shapes[1].kind ~= "poly" then return nil, "not a polygon" end
	local s = shapes[1]
	if #s.pts < 3 then return nil, "fewer than 3 corners" end
	return baShapeString(s)
end

function baZoneString(pts)
	local lo = math.huge
	for _, p in ipairs(pts) do lo = math.min(lo, p[2]) end
	local l = {"zone", f2(lo)}
	for _, p in ipairs(pts) do l[#l + 1] = f2(p[1]); l[#l + 1] = f2(p[3]) end
	return table.concat(l, " ")
end

function baPolyString(pts)
	local lo, hi = math.huge, -math.huge
	for _, p in ipairs(pts) do lo, hi = math.min(lo, p[2]), math.max(hi, p[2]) end
	local l = {"poly", f2(lo - 1), f2(hi + BA_HEADROOM)}
	for _, p in ipairs(pts) do l[#l + 1] = f2(p[1]); l[#l + 1] = f2(p[3]) end
	return table.concat(l, " ")
end

function baEditorCorners(shapes)
	if #shapes == 0 then return nil end
	local s = shapes[1]
	if #shapes == 1 and (s.kind == "poly" or s.kind == "zone") then
		local l = {}
		for i, p in ipairs(s.pts) do l[i] = {p[1], p[2]} end
		return l
	elseif #shapes == 1 and s.kind == "cyl" then
		local l = {}
		for i = 0, 7 do
			local a = (i + 0.5) / 8 * 2 * math.pi
			l[#l + 1] = {s.x + math.cos(a) * s.r, s.z + math.sin(a) * s.r}
		end
		return l
	end
	local lo, hi = allBounds(shapes)
	return {{lo[1], lo[3]}, {hi[1], lo[3]}, {hi[1], hi[3]}, {lo[1], hi[3]}}
end

----- the outline (client) -----

local function groundAt(x, z, top, bottom)
	local hit, d = QueryRaycast(Vec(x, top, z), Vec(0, -1, 0), top - bottom + 0.5)
	if hit then return top - d end
	return bottom
end

-- a closed loop of x/z corners -> {segs = {{a, b}...}, posts = {Vec...}}; samples every BA_SAMPLE m dropped onto the
-- ground, straight runs merged into one segment (a flat floor: one segment per edge)
function baBuildLoopOutline(pts, top, bottom, out)
	out = out or {segs = {}, posts = {}}
	local n = #pts
	if n < 2 then return out end
	for i = 1, n do
		local a, b = pts[i], pts[i % n + 1]
		local len = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
		local steps = math.max(1, math.ceil(len / BA_SAMPLE))
		local samples = {}
		for k = 0, steps do
			local t = k / steps
			local x, z = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
			samples[#samples + 1] = Vec(x, groundAt(x, z, top, bottom) + 0.06, z)
		end
		out.posts[#out.posts + 1] = samples[1]
		local s0 = 1
		for k = 2, #samples do
			local last = k == #samples
			local bend = false
			if not last then                                   -- (would the run s0..k+1 still be straight?)
				local p0, p1 = samples[s0], samples[k + 1]
				for m = s0 + 1, k do
					local t = (m - s0) / (k + 1 - s0)
					if math.abs(samples[m][2] - (p0[2] + (p1[2] - p0[2]) * t)) > 0.05 then bend = true; break end
				end
			end
			if last or bend then
				out.segs[#out.segs + 1] = {samples[s0], samples[k]}
				s0 = k
			end
		end
	end
	return out
end

function baBuildOutline(shapes)
	local out = {segs = {}, posts = {}}
	for _, s in ipairs(shapes) do
		local top, bottom = baTop(s), baBottom(s)
		if s.kind == "box" or s.kind == "trigger" then
			baBuildLoopOutline({{s.x0, s.z0}, {s.x1, s.z0}, {s.x1, s.z1}, {s.x0, s.z1}}, top, bottom, out)
		elseif s.kind == "cyl" then
			local n = 8 * math.ceil(math.max(16, math.min(64, math.ceil(2 * math.pi * s.r / 1.5))) / 8)
			local pts = {}
			for i = 0, n - 1 do
				local a = i / n * 2 * math.pi
				pts[#pts + 1] = {s.x + math.cos(a) * s.r, s.z + math.sin(a) * s.r}
			end
			local before = #out.posts
			baBuildLoopOutline(pts, top, bottom, out)
			for i = #out.posts, before + 1, -1 do                -- (8 posts round a circle, not one per facet)
				if (i - before - 1) % (n / 8) ~= 0 then table.remove(out.posts, i) end
			end
		elseif s.kind == "poly" or s.kind == "zone" then
			baBuildLoopOutline(s.pts, top, bottom, out)
		end
	end
	return out
end

-- a glowing ribbon from a to b that always faces the camera (the game's own laser sprite trick, script_defs
-- QuatAlignXZ example): a hot core and a wider soft glow, additive, hidden behind walls
local function ribbon(sprite, a, b, cam, core, glow, r, g, bl)
	local d = VecSub(b, a)
	local len = VecLength(d)
	if len < 0.01 then return end
	local mid = VecLerp(a, b, 0.5)
	local t = Transform(mid, QuatAlignXZ(VecScale(d, 1 / len), VecNormalize(VecSub(mid, cam))))
	DrawSprite(sprite, t, len, glow, r, g, bl, 0.55, true, true)
	DrawSprite(sprite, t, len, core, r * 4, g * 4, bl * 4, 1, true, true)
end

local sprite = nil

function baDrawOutline(outline, r, g, b)
	if not outline then return end
	if not sprite then sprite = LoadSprite("gfx/laser.png") end
	local cam = GetCameraTransform().pos
	local range2 = BA_DRAW_RANGE * BA_DRAW_RANGE
	for _, s in ipairs(outline.segs) do
		local m = VecLerp(s[1], s[2], 0.5)
		local dx, dy, dz = m[1] - cam[1], m[2] - cam[2], m[3] - cam[3]
		if dx * dx + dy * dy + dz * dz < range2 then
			ribbon(sprite, s[1], s[2], cam, 0.06, 0.32, r, g, b)
			DrawLine(s[1], s[2], r, g, b, 1)
		end
	end
	for _, p in ipairs(outline.posts) do
		local dx, dz = p[1] - cam[1], p[3] - cam[3]
		if dx * dx + dz * dz < range2 then
			ribbon(sprite, p, VecAdd(p, Vec(0, BA_POST_H, 0)), cam, 0.08, 0.36, r, g, b)
		end
	end
end
