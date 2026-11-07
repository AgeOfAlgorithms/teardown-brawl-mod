-- Brawl: the lobby's map view - a top-down CROSS-SECTION. Included by brawl.lua (no #version line); only GLOBALS are
-- shared. The area editor (brawl_editor.lua) uses the same camera.
--   The CAMERA (every machine its own): straight down from BV_ZOOM m over the ground under the view's centre (the
--   wheel: BV_ZOOM_MIN..BV_ZOOM_MAX), FOV BV_FOV; WASD / arrows pan. It may be far above the roofs: the user could not
--   see through a roof without zooming in too close when the camera had to go under it.
--   The CUT (the host's, for everyone): every static level shape lying wholly above it (its bounds' bottom >= the cut)
--   is hidden - tagged "invisible" by the SERVER (client scripts may not touch server-authored entities: the client's
--   own tagging was refused in-game and the user saw the roof). Shapes across the cut (walls floor to roof) stay: from
--   above they read as wall outlines. Auto cut (default), every BV_SAMPLE s: at the view's centre and 4 points
--   BV_SPREAD m round it, the ground (the first floor under the top surface with room above it: a roof, a storey's slab
--   are passed) and the first ceiling over that ground + 1.5 m; cut = the LOWEST ceiling - 0.3 m (no ceiling anywhere:
--   open sky, nothing hidden). A ceiling / roof / floor must be a wide shape (BV_MIN_W both ways: a truss, a lamp's rod
--   are passed) and a surface (the hit goes on BV_PATCH m to all 4 sides: a rope, a bar's edge are passed). Hysteresis:
--   the cut (and the camera's ground) changes only by more than BV_HYST m seen in BV_HYST_N samples in a row; the
--   camera's height eases (BV_EASE). Q / E: Manual, the cut 0.5 m lower / higher; R: Auto. The host's client sends its
--   cut (server.brawlCut, on a change of 0.25 m or more, at most 4 a second); the other clients show "Cut set by the
--   host" and their cut keys do nothing. The server tags in batches (BV_TAG_BATCH a tick) over +-BV_HIDE_R m round the
--   host's view, only static shapes (no dynamic body, no vehicle), never one the map itself tagged invisible (it
--   remembers its own), and removes every tag of its own when the round starts or the mode ends.
-- Interface (client):
--   brawlViewReset(centre)              centre the view on a point (the area's middle, the player), Auto
--   brawlViewCentre(x, z)               move the view (the editor opening on the area)
--   brawlViewTick(dt, keys)             client.tick in the lobby: keys (when keys), the cut (the host), the camera
--   brawlViewApply()                    set the camera again (client.draw, after mplib's lobby)
--   brawlViewLeave()                    the lobby is over on this machine
--   brawlViewCamPos() -> Vec            the camera (the editor's rays start there)
--   brawlViewHint() -> text             "Cut 9.7 m (auto) - Q/E: lower/raise, R: auto ..." / "Cut 9.7 m - set by the host"
--   bvGroundAt(x, z), bvCeilingAbove(x, g, z), bvAutoCut(x, z) -> cut | nil (open), ground   (tests)
-- Interface (server):
--   server.brawlCut(p, cut, x, z)       the host's cut (cut < -1000: open sky, nothing hidden) and view centre
--   bvServerTick(lobby)                 server.tick: the tags in batches; not the lobby: every tag of ours removed
--   bvServerClear()                     every tag of ours removed at once (the round starts, the mode ends)

BV_SAMPLE = 0.2           -- s between Auto samples
BV_EASE = 0.1             -- s: the camera height's time constant (~95 % in 0.3 s)
BV_ZOOM = 25              -- m: the camera over the ground (the wheel: BV_ZOOM_MIN..BV_ZOOM_MAX)
BV_ZOOM_MIN, BV_ZOOM_MAX = 10, 80
BV_FOV = 70
BV_HEAD = 1.5             -- m over the ground where the ray up starts
BV_GAP = 0.3              -- m: the cut under the ceiling
BV_ROOM = 2.0             -- m of room over a floor for it to be the ground under a roof / slab
BV_SLAB = 0.4             -- m under a surface where the next ray down starts
BV_MIN_W = 1.5            -- m: a shape narrower than this EITHER way is no roof / ceiling / floor (a truss, a lamp's
                          --  rod: the ring's trusses, 16.8 x 0.4 m, flipped the cut 8.3 <-> 9.7 in-game)
BV_PATCH = 0.3            -- m: a hit counts only where the surface goes on this far to all 4 sides (not a rope, a bar)
BV_FLAT = 0.15            -- m: ... within this height
BV_SPREAD = 3             -- m: the 4 extra samples round the view's centre (fixed: a spread from the camera's height
                          --  fed the cut back into itself - the view zoomed in and out on its own, in-game)
BV_HYST = 0.6             -- m: Auto moves the cut / the ground only for a change bigger than this ...
BV_HYST_N = 2             -- ... seen in this many samples in a row
BV_STEP = 0.5             -- m per Q / E
BV_TOP = 500              -- m: the first ray down starts this high
BV_OPEN = -9999           -- the cut sent for open sky
BV_SEND_MIN = 0.25        -- m: the host's cut is sent on a change this big ...
BV_SEND_GAP = 0.25        -- s: ... at most this often
BV_HIDE_R = 60            -- m round the host's view the server hides in
BV_TAG_BATCH = 500        -- tag changes per server tick at most

BV = {inited = false, x = 0, z = 0, mode = "auto", cut = nil, ground = 0, camY = nil, zoom = BV_ZOOM,
	sampleT = -100, fresh = true, cutN = 0, groundN = 0, sentCut = nil, sentT = -100, sentX = 0, sentZ = 0}

local function wide(shape)
	if not shape or shape == 0 then return true end
	local lo, hi = GetShapeBounds(shape)
	if not lo then return true end
	return math.min(hi[1] - lo[1], hi[3] - lo[3]) >= BV_MIN_W
end

-- is the hit at (x, y, z) a surface: rays BV_PATCH m to all four sides find it too, within BV_FLAT (a rope, a bar's
-- edge, a post's top: no)
local function surface(x, y, z, up)
	local d = up and Vec(0, 1, 0) or Vec(0, -1, 0)
	local from = y - d[2] * 0.2
	for _, o in ipairs({{BV_PATCH, 0}, {-BV_PATCH, 0}, {0, BV_PATCH}, {0, -BV_PATCH}}) do
		local hit, t = QueryRaycast(Vec(x + o[1], from, z + o[2]), d, 0.4)
		if not hit or math.abs(from + d[2] * t - y) > BV_FLAT then return false end
	end
	return true
end

-- the first surface of a wide shape along a vertical ray (narrow shapes and bars passed); its y, or nil
local function bigHit(o, up, dist)
	local d = up and Vec(0, 1, 0) or Vec(0, -1, 0)
	for _ = 1, 24 do
		if dist <= 0 then return nil end
		local hit, t, _, shape = QueryRaycast(o, d, dist)
		if not hit then return nil end
		local y = o[2] + d[2] * t
		local w = wide(shape)
		if w and surface(o[1], y, o[3], up) then return y end
		local step = t + 0.1
		if not w then
			-- a narrow shape: go on from just past its far side (in-game: the ray started inside the ring's spotlight
			-- rod, 1 m long, and 0.05 m steps gave up inside it: the roof became the ground)
			local lo, hi = nil, nil
			if shape and shape ~= 0 then lo, hi = GetShapeBounds(shape) end
			if lo then
				local past = up and (hi[2] + 0.05 - o[2]) or (o[2] - (lo[2] - 0.05))
				if past > step then step = past end
			end
		end
		o = VecAdd(o, VecScale(d, step))
		dist = dist - step
	end
	return nil
end

-- the ground at (x, z): the top surface, unless there is a floor under it with room above (an inside)
function bvGroundAt(x, z)
	local top = bigHit(Vec(x, BV_TOP, z), false, BV_TOP + 300)
	if not top then return nil end
	local g = top
	for _ = 1, 10 do
		local start = g - BV_SLAB
		local below = bigHit(Vec(x, start, z), false, 300)
		if not below then break end
		if start - below >= BV_ROOM then return below end
		g = below
	end
	return top
end

-- the first ceiling over a ground y (nil: open sky, or the ray starts inside something)
function bvCeilingAbove(x, g, z)
	local from = g + BV_HEAD
	local c = bigHit(Vec(x, from, z), true, 400)
	if c and c - from < 0.05 then return nil end
	return c
end

function bvAutoCut(x, z)
	local q = BV_SPREAD
	local g0 = bvGroundAt(x, z) or BV.ground
	local lowest
	for _, p in ipairs({{x, z}, {x + q, z}, {x - q, z}, {x, z + q}, {x, z - q}}) do
		local g = bvGroundAt(p[1], p[2]) or g0
		local c = bvCeilingAbove(p[1], g, p[2])
		if c and (not lowest or c < lowest) then lowest = c end
	end
	if lowest then return math.max(lowest - BV_GAP, g0 + 1.2), g0 end
	return nil, g0
end

----- client -----

function brawlViewCamPos() return Vec(BV.x, BV.camY or (BV.ground + BV.zoom), BV.z) end

function brawlViewApply()
	if not BV.inited then return end
	SetCameraTransform(Transform(brawlViewCamPos(), QuatEuler(-90, 0, 0)), BV_FOV)   -- (straight down; screen up = -z)
end

function brawlViewReset(centre)
	centre = centre or Vec()
	BV.x, BV.z, BV.mode, BV.camY, BV.zoom, BV.sampleT, BV.inited = centre[1], centre[3], "auto", nil, BV_ZOOM, -100, true
	BV.ground, BV.fresh, BV.cutN, BV.groundN = centre[2], true, 0, 0
	BV.offX, BV.offZ, BV.frame = 0, 0, nil
end

-- frame an area in the band above mplib's "Join a team" boxes (they start ~314 px down a 1080 screen): its centre
-- BV_FRAME_Y px from the top, the camera high enough that it fits BV_FRAME_HALF px up and down (BV_FRAME_HALF_W across)
BV_FRAME_Y = 160
BV_FRAME_HALF = 130
BV_FRAME_HALF_W = 340     -- (clear of the Brawl panel and mplib's settings drawer on the left, up to x ~600)
BV_FRAME_TRIES = 40       -- frames the framing is corrected by measuring the real projection
BV_FRAME_PAD = 1.5        -- m round the area kept in the band too
function brawlViewFrame(shapes)
	local c = baCentre(shapes)
	if not c then return end
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for _, s in ipairs(shapes) do
		local lo, hi = baBounds(s)
		x0, z0, x1, z1 = math.min(x0, lo[1]), math.min(z0, lo[3]), math.max(x1, hi[1]), math.max(z1, hi[3])
	end
	local hx, hz = math.max(0.5, (x1 - x0) / 2), math.max(0.5, (z1 - z0) / 2)
	-- the plain framing: the camera over the area's centre, high enough for the area (a horizontal 70-degree FOV
	-- assumed) - kept as the fallback
	local t = math.tan(math.rad(BV_FOV) / 2)
	local h = math.max(hz * 960 / (BV_FRAME_HALF * t), hx * 960 / (BV_FRAME_HALF_W * t))
	h = math.max(BV_ZOOM_MIN, math.min(BV_ZOOM_MAX, h))
	BV.zoom = h
	BV.x, BV.z, BV.offX, BV.offZ = c[1], c[3], 0, 0
	BV.sampleT, BV.fresh, BV.camY = -100, true, nil
	-- then brawlViewRefine measures the real projection (UiWorldToPixel, in client.draw) and moves the VIEW so the
	-- area lands in the band above the team boxes; the cut and the ground are still sampled at the area (the focus)
	BV.frame = {c = c, floor = baAreaFloor(shapes), hx = hx, hz = hz, n = BV_FRAME_TRIES, h0 = h, err = math.huge}
end

-- the plain framing again (a measurement went wrong)
local function plainFrame(f)
	BV.x, BV.z, BV.offX, BV.offZ = f.c[1], f.c[3], 0, 0
	BV.zoom = f.h0
	BV.camY = nil
	BV.frame = nil
end

local function bad(x) return x ~= x or x == math.huge or x == -math.huge end

-- (client.draw, after the camera is set) one step of the framing: the area's centre to the middle of the band above
-- mplib's team boxes (they start UiMiddle() - 226 px down), its extent inside the band and right of the left panels
-- (to ~620 px), measured with UiWorldToPixel (whatever the engine's FOV and the window's shape: a tall window showed
-- grey with an earlier version that assumed a 1920 x 1080 UI); a reading behind the camera is ignored; the view is
-- kept within a few area sizes of the area; after BV_FRAME_TRIES steps a framing still off falls back to the plain one
function brawlViewRefine()
	local f = BV.frame
	if not f or not BV.inited then return end
	f.n = f.n - 1
	if f.n < 0 then
		if f.err > 40 then plainFrame(f) else BV.frame = nil end
		return
	end
	local c = Vec(f.c[1], f.floor, f.c[3])
	local x0, y0, d0 = UiWorldToPixel(c)
	local x1, y1, d1 = UiWorldToPixel(VecAdd(c, Vec(0, 0, 1)))
	if not d0 or not d1 or d0 <= 0 or d1 <= 0 or bad(x0) or bad(y0) or bad(y1) then return end
	local ppm = math.abs(y1 - y0)
	if ppm < 1e-3 or bad(ppm) then return end
	local W, H = UiWidth(), UiHeight()
	-- the band: 40 px under the screen's top to 20 px over mplib's team boxes; the area padded BV_FRAME_PAD m round
	-- (what stands round it - a ring's apron - showed clipped at the top in-game at 16:9)
	local bottom = H / 2 - 226 - 20
	local yT = (40 + bottom) / 2
	local halfY = math.max(30, (bottom - 40) / 2)
	local xT = W / 2
	local halfX = math.max(100, xT - 620)
	local want = math.min(halfY / (f.hz + BV_FRAME_PAD), halfX / (f.hx + BV_FRAME_PAD))
	local ratio = ppm / want
	local ex, ey = x0 - xT, y0 - yT
	f.err = math.max(math.abs(ex), math.abs(ey), math.abs(ratio - 1) * halfY)
	if math.abs(ratio - 1) < 0.02 and math.abs(ey) < 3 and math.abs(ex) < 3 then BV.frame = nil; return end
	BV.zoom = math.max(BV_ZOOM_MIN, math.min(BV_ZOOM_MAX, BV.zoom * ratio))
	local lim = math.max(f.hx, f.hz) * 3 + 40
	BV.x = math.max(f.c[1] - lim, math.min(f.c[1] + lim, BV.x + ex / ppm))
	BV.z = math.max(f.c[3] - lim, math.min(f.c[3] + lim, BV.z + ey / ppm))
	BV.offX, BV.offZ = BV.x - f.c[1], BV.z - f.c[3]
	if bad(BV.x) or bad(BV.z) or bad(BV.zoom) then plainFrame(f); return end
	BV.camY = BV.ground + BV.zoom                                    -- (no easing while framing)
	brawlViewApply()
end

function brawlViewCentre(x, z)
	BV.x, BV.z, BV.sampleT, BV.fresh, BV.offX, BV.offZ = x, z, -100, true, 0, 0
end

-- the point the view is about (sampled for the cut and the ground; sent to the server for the hiding): the view's
-- centre, or the framed area's centre while the view is shifted to show it above the team boxes
local function focus() return BV.x - (BV.offX or 0), BV.z - (BV.offZ or 0) end

local function differs(a, b) if a == nil or b == nil then return a ~= b end return math.abs(a - b) > BV_HYST end

local function sample()
	local fx, fz = focus()
	local c, g = bvAutoCut(fx, fz)
	if BV.fresh then
		BV.ground, BV.groundN = g, 0
		if BV.mode == "auto" then BV.cut, BV.cutN = c, 0 end
		BV.fresh = false
		return
	end
	if differs(g, BV.ground) then                                   -- (the ground: the camera's height)
		BV.groundN = BV.groundN + 1
		if BV.groundN >= BV_HYST_N then BV.ground, BV.groundN = g, 0 end
	else BV.groundN = 0 end
	if BV.mode ~= "auto" then return end
	if differs(c, BV.cut) then
		BV.cutN = BV.cutN + 1
		if BV.cutN >= BV_HYST_N then BV.cut, BV.cutN = c, 0 end
	else BV.cutN = 0 end
end

-- the host's cut to the server: on a change of BV_SEND_MIN m or more (or the view 10 m away), at most every BV_SEND_GAP s
local function sendCut(now)
	local cut = BV.cut or BV_OPEN
	local fx, fz = focus()
	local moved = math.abs(fx - BV.sentX) + math.abs(fz - BV.sentZ)
	if BV.sentCut and math.abs(cut - BV.sentCut) < BV_SEND_MIN and moved < 10 then return end
	if now - BV.sentT < BV_SEND_GAP then return end
	BV.sentCut, BV.sentT, BV.sentX, BV.sentZ = cut, now, fx, fz
	ServerCall("server.brawlCut", GetLocalPlayer(), cut, fx, fz)
end

function brawlViewTick(dt, keys)
	if not BV.inited then return end
	local now = GetTime()
	local host = IsPlayerHost(GetLocalPlayer())
	if keys then
		local speed = math.max(4, BV.zoom * 1.1 + 4)
		local dx, dz = 0, 0
		if InputDown("w") or InputDown("uparrow") then dz = dz - 1 end
		if InputDown("s") or InputDown("downarrow") then dz = dz + 1 end
		if InputDown("a") or InputDown("leftarrow") then dx = dx - 1 end
		if InputDown("d") or InputDown("rightarrow") then dx = dx + 1 end
		BV.x, BV.z = BV.x + dx * speed * dt, BV.z + dz * speed * dt
		local wheel = InputValue("mousewheel")
		if dx ~= 0 or dz ~= 0 or wheel ~= 0 then BV.frame = nil end   -- (the player moves the view: the framing stops)
		if wheel ~= 0 then BV.zoom = math.max(BV_ZOOM_MIN, math.min(BV_ZOOM_MAX, BV.zoom * (1 - 0.12 * wheel))) end
		if host and (InputPressed("q") or InputPressed("e")) then
			BV.mode = "manual"
			BV.cut = (BV.cut or (BV.ground + 10)) + (InputPressed("e") and BV_STEP or -BV_STEP)
		end
		if host and InputPressed("r") and BV.mode ~= "auto" then BV.mode, BV.sampleT, BV.fresh = "auto", -100, true end
	end
	if now - BV.sampleT >= BV_SAMPLE then
		BV.sampleT = now
		sample()
	end
	local target = BV.ground + BV.zoom
	if not BV.camY then BV.camY = target
	else BV.camY = BV.camY + (target - BV.camY) * (1 - math.exp(-dt / BV_EASE)) end
	brawlViewApply()
	if host then sendCut(now) end
end

function brawlViewLeave()
	BV.inited, BV.sentCut = false, nil
end

function brawlViewHint()
	return "WASD: move   Wheel: zoom"
end

-- the cut as this machine knows it: the host's own, else the host's from shared (nil: open sky)
function brawlViewCut()
	if IsPlayerHost(GetLocalPlayer()) then return BV.cut end
	local c = shared.brawlCut
	return (c and c.cut and c.cut > BV_OPEN + 1) and c.cut or nil
end

----- the height bar (the user: "a height bar to the right so that user can easily see what the current height is?
----- the Q/E hint should also belong there"), the lobby view and the editor, every machine -----
-- A panel at the right edge (clear of mplib's team boxes, which end ~330 px in from the edge of a 1920 UI): a scale
-- from 2 m under the lowest of the area's floor and the ground under the view to BV_BAR_SPAN m over it, a tick every
-- metre, a label every 5 m; the cut as a bright marker with its height and "auto" / "manual" (a client: "set by the
-- host"); faint marks for the area's floor (green) and a map area's top (green), the camera's height (grey); under it
-- the host's keys "Q / E  lower / raise", "R  auto". BRAWL_HBAR (the tests read it) holds what was drawn.
BV_BAR_SPAN = 32          -- m the scale covers
BV_BAR_W = 170            -- px: the panel's width (UI units)
BV_BAR_TOP = 140          -- px from the top
local barFloor = {}

local function areaMarks(areaStr)
	local m = barFloor[areaStr]
	if m then return m end
	local shapes = baParse(areaStr or "")
	m = {}
	if #shapes > 0 then
		m.floor = baAreaFloor(shapes)
		if not baUnbounded(shapes) then
			local top = -math.huge
			for _, s in ipairs(shapes) do top = math.max(top, baTop(s)) end
			m.top = top
		end
	end
	barFloor = {[areaStr] = m}                                     -- (one area cached)
	return m
end

function brawlDrawHeightBar(areaStr)
	if not BV.inited then return end
	local W, H = UiWidth(), UiHeight()
	local host = IsPlayerHost(GetLocalPlayer())
	local marks = areaMarks(areaStr or "")
	local lo = math.floor(math.min(marks.floor or BV.ground, BV.ground) - 2)
	local hi = lo + BV_BAR_SPAN
	local x0 = W - BV_BAR_W - 20
	local top = BV_BAR_TOP
	local bot = math.max(top + 200, math.min(H - 220, top + 640))
	local barX = x0 + BV_BAR_W - 46
	local function yOf(h) return bot - (math.max(lo, math.min(hi, h)) - lo) / (hi - lo) * (bot - top) end
	local cut = brawlViewCut()
	local mode = host and BV.mode or "set by the host"
	local keys = host and {"Q / E  lower / raise", "R  auto"} or {}
	local h = (bot - top) + 70 + 44 + #keys * 22 + 20
	-- (the player's words: "Hide above" - the user asked what "cut: auto" meant)
	local modeText = (not host) and "set by the host" or (BV.mode == "auto" and "auto: under the ceiling" or "manual")
	BRAWL_HBAR = {x = x0, y = top - 40, w = BV_BAR_W, h = h, lo = lo, hi = hi, top = top, bot = bot,
		cut = cut, markerY = cut and yOf(cut) or nil, cutText = cut and string.format("%.1f m", cut) or "off", mode = mode, keys = keys,
		modeText = modeText, title = "Hide above: " .. (cut and string.format("%.1f m", cut) or "off")}
	BV.barRect = {x0, top - 40, BV_BAR_W, h}
	UiPush()
	UiTranslate(x0, top - 40)
	UiAlign("left top")
	UiColor(0, 0, 0, 0.55)
	UiRoundedRect(BV_BAR_W, h, 10)
	UiTranslate(14, 10)
	UiFont("bold.ttf", 18)
	UiColor(1, 1, 1, 0.9)
	UiText("HEIGHT")
	UiPop()
	-- the scale
	UiPush()
	UiTranslate(barX, top)
	UiAlign("left top")
	UiColor(1, 1, 1, 0.18)
	UiRect(10, bot - top)
	UiPop()
	local cutY = cut and yOf(cut) or top
	BRAWL_HBAR.labels = {}
	for m = math.ceil(lo), math.floor(hi) do
		local y = yOf(m)
		local major = m % 5 == 0
		local labelled = major and math.abs(y - cutY) >= 22         -- (no tick label under the cut's own label)
		if labelled then BRAWL_HBAR.labels[#BRAWL_HBAR.labels + 1] = {m = m, y = y} end
		UiPush()
		UiTranslate(barX - (major and 8 or 4), y)
		UiAlign("left middle")
		UiColor(1, 1, 1, major and 0.7 or 0.35)
		UiRect(major and 18 or 10, major and 2 or 1)
		if labelled then
			UiTranslate(-6, 0)
			UiAlign("right middle")
			UiFont("bold.ttf", 15)
			UiText(m .. " m")
		end
		UiPop()
	end
	local function mark(hgt, r, g, b, a, wdt)
		if not hgt then return end
		UiPush()
		UiTranslate(barX - 2, yOf(hgt))
		UiAlign("left middle")
		UiColor(r, g, b, a)
		UiRect(wdt or 14, 3)
		UiPop()
	end
	mark(marks.floor, 0.3, 1, 0.4, 0.6)                              -- (the area's floor)
	mark(marks.top, 0.3, 1, 0.4, 0.45)                               -- (a map area's top)
	mark(BV.camY, 0.7, 0.7, 0.7, 0.6, 8)                             -- (the camera)
	-- the cut: a bright marker, its height, the mode
	UiPush()
	UiTranslate(barX - 12, cut and yOf(cut) or top)
	UiAlign("left middle")
	UiColor(1, 0.55, 0.1, 1)
	UiRect(34, 5)
	UiTranslate(-8, 0)
	UiAlign("right middle")
	UiFont("bold.ttf", 20)
	UiText(BRAWL_HBAR.cutText)
	UiPop()
	UiPush()
	UiTranslate(x0 + 14, bot + 22)
	UiAlign("left top")
	UiFont("bold.ttf", 16)
	UiColor(1, 0.7, 0.3, 1)
	UiText(BRAWL_HBAR.title)
	UiTranslate(0, 22)
	UiFont("bold.ttf", 13)
	UiColor(1, 0.8, 0.5, 0.9)
	UiText(modeText)
	UiFont("bold.ttf", 15)
	UiColor(0.9, 0.9, 0.9, 0.9)
	for _, k in ipairs(keys) do
		UiTranslate(0, 24)
		UiText(k)
	end
	UiPop()
end

----- server: hiding what lies above the host's cut -----

BVS = {cut = nil, x = 0, z = 0, dirty = false, tagged = {}, queue = {}, n = 0}

function server.brawlCut(p, cut, x, z)
	if not IsPlayerHost(p) then return end
	cut, x, z = tonumber(cut), tonumber(x) or 0, tonumber(z) or 0
	if not cut or cut ~= cut or x ~= x or z ~= z then return end
	if cut < BV_OPEN + 1 then cut = nil end
	BVS.cut, BVS.x, BVS.z, BVS.dirty = cut, x, z, true
	BVS.n = BVS.n + 1
	shared.brawlCut = {cut = cut or BV_OPEN, n = BVS.n}
end

-- only the level's static shapes: no dynamic body (players' gear, loose props, ragdolls), no vehicle, not one the map
-- (or another mod) already made invisible
local function hideable(sh)
	local b = GetShapeBody(sh)
	if b and b ~= 0 and (IsBodyDynamic(b) or GetBodyVehicle(b) ~= 0) then return false end
	return not HasTag(sh, "invisible")
end

function bvServerClear()
	for sh in pairs(BVS.tagged) do
		if IsHandleValid(sh) then RemoveTag(sh, "invisible") end
	end
	BVS.tagged, BVS.queue, BVS.dirty = {}, {}, BVS.cut ~= nil
end

function bvServerTick(lobby)
	if not lobby then
		if next(BVS.tagged) then bvServerClear() end
		BVS.queue = {}
		return
	end
	if BVS.dirty then
		BVS.dirty = false
		local q, cut = {}, BVS.cut
		for sh in pairs(BVS.tagged) do                                  -- (under the cut now, or no cut: shown again)
			local lo = IsHandleValid(sh) and GetShapeBounds(sh) or nil
			if not cut or not lo or lo[2] < cut then q[#q + 1] = {sh, false} end
		end
		if cut then
			local r = BV_HIDE_R
			for _, sh in ipairs(QueryAabbShapes(Vec(BVS.x - r, cut, BVS.z - r), Vec(BVS.x + r, cut + 400, BVS.z + r)) or {}) do
				if not BVS.tagged[sh] then
					local lo = GetShapeBounds(sh)
					if lo and lo[2] >= cut and hideable(sh) then q[#q + 1] = {sh, true} end
				end
			end
		end
		BVS.queue = q
	end
	local n = 0
	while #BVS.queue > 0 and n < BV_TAG_BATCH do
		local it = table.remove(BVS.queue)
		local sh = it[1]
		if IsHandleValid(sh) then
			if it[2] then
				if not BVS.tagged[sh] and not HasTag(sh, "invisible") then SetTag(sh, "invisible"); BVS.tagged[sh] = true end
			elseif BVS.tagged[sh] then
				RemoveTag(sh, "invisible")
			end
		end
		if not it[2] then BVS.tagged[sh] = nil end
		n = n + 1
	end
end
