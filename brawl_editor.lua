-- Brawl: the host's fight-area editor in the lobby (client, the host's machine only). Included by brawl.lua (no
-- #version line); only GLOBALS are shared. It works in the lobby's cross-section view (brawl_view.lua: the camera
-- straight down from under the cut, WASD / wheel / Q E R there); corner handles to drag (LMB), RMB on an edge's
-- middle marker adds a corner, RMB on a corner removes it (3 at least). Done sends the polygon to the server
-- (server.brawlSetArea, re-sent until shared.brawl.editAck shows it). Interface:
--   brawlEditorOpen(areaStr, hostPos)   start editing: the current area's corners (baEditorCorners) or a 12 m square
--   brawlEditorActive() -> bool
--   brawlEditorTick(dt)                 client.tick: the live outline, re-sending
--   brawlEditorDraw()                   client.draw (instead of the lobby): handles, mouse, the Done/Cancel/Reset bar
--   brawlEditorSend(str)                send an area to the server ("" = drop the host's edit), re-sent until acked

BE = {on = false, pts = {}, start = {}, floor = 0, drag = nil, dirty = true, outline = nil, seq = 0, pending = nil,
	sentT = -100, firstT = -100}

BE_SQUARE = 12          -- m: the starting square when there is no area yet
BE_PICK = 16            -- px: how near the cursor must be to a handle
BE_BAR_H = 96           -- px: the button bar at the top

function brawlEditorActive() return BE.on end

local function ground(x, z, fromY)
	local hit, d = QueryRaycast(Vec(x, fromY, z), Vec(0, -1, 0), 400)
	if hit then return fromY - d end
	return BE.floor
end

local function camPos() return brawlViewCamPos() end

function brawlEditorOpen(areaStr, hostPos)
	local shapes = baParse(areaStr or "")
	local corners = baEditorCorners(shapes)
	local top
	if corners then
		for _, s in ipairs(shapes) do top = math.max(top or -math.huge, baTop(s)) end
	else
		local h = hostPos or Vec()
		local r = BE_SQUARE / 2
		corners = {{h[1] - r, h[3] - r}, {h[1] + r, h[3] - r}, {h[1] + r, h[3] + r}, {h[1] - r, h[3] + r}}
	end
	local cx, cz, lo = 0, 0, math.huge
	for _, c in ipairs(corners) do cx, cz = cx + c[1] / #corners, cz + c[2] / #corners end
	if not BV.inited then brawlViewReset(Vec(cx, hostPos and hostPos[2] or 0, cz)) end
	brawlViewCentre(cx, cz)
	-- each corner on the floor (the view's ground: under a roof too), else under the area's top
	local from = (BV.cut or top or ((hostPos and hostPos[2] or 0) + 60)) - 0.2
	BE.pts = {}
	for i, c in ipairs(corners) do
		local y = bvGroundAt(c[1], c[2]) or ground(c[1], c[2], from)
		BE.pts[i] = Vec(c[1], y, c[2])
		lo = math.min(lo, y)
	end
	BE.start = {}
	for i, p in ipairs(BE.pts) do BE.start[i] = VecCopy(p) end
	BE.floor = lo
	BE.drag, BE.dirty, BE.on = nil, true, true
end

function brawlEditorSend(str, how)
	BE.seq = BE.seq + 1
	BE.pending = {seq = BE.seq, str = str, how = how or "drawn"}
	BE.sentT, BE.firstT = -100, GetTime()
end

local function resend()
	local p = BE.pending
	if not p then return end
	local b = shared.brawl
	if (b and b.editAck == p.seq) or GetTime() - BE.firstT > 6 then BE.pending = nil; return end
	if GetTime() - BE.sentT > 0.6 then
		BE.sentT = GetTime()
		ServerCall("server.brawlSetArea", GetLocalPlayer(), p.seq, p.str, p.how)
	end
end

function brawlEditorTick(dt)
	resend()
	if not BE.on then return end
	if BE.dirty then
		local hi, lo = -math.huge, math.huge
		for _, p in ipairs(BE.pts) do hi, lo = math.max(hi, p[2]), math.min(lo, p[2]) end
		local loop = {}
		for i, p in ipairs(BE.pts) do loop[i] = {p[1], p[3]} end
		BE.outline = baBuildLoopOutline(loop, hi + 1.5, lo - 2)
		BE.dirty = false
	end
	baDrawOutline(BE.outline, 0.15, 0.85, 1.0)
end

-- the ground under the cursor (the camera's ray through the pixel; what lies above the host's cut - hidden - is passed:
-- the camera may be high over a roof)
function brawlCursorGround(mx, my)
	local dir = UiPixelToWorld(mx, my)
	if not dir then return nil end
	local o, left = camPos(), 1000
	for _ = 1, 24 do
		local hit, d = QueryRaycast(o, dir, left)
		if not hit then return nil end
		local p = VecAdd(o, VecScale(dir, d))
		if not BV.cut or p[2] < BV.cut then return p end
		o, left = VecAdd(p, VecScale(dir, 0.1)), left - d - 0.1
	end
	return nil
end

local function nearest(list, mx, my)
	local best, bd = nil, BE_PICK
	for i, s in ipairs(list) do
		if s[3] > 0 then
			local d = math.sqrt((s[1] - mx) ^ 2 + (s[2] - my) ^ 2)
			if d < bd then best, bd = i, d end
		end
	end
	return best
end

-- a plain button that fires on the press (the skill: UiBlankButton fires on release and missed clicks in-game)
local function button(label, w, h, enabled)
	UiPush()
	local over = UiIsMouseInRect(w, h)
	UiColor(0, 0, 0, 0.55)
	if over and enabled then UiColor(0.35, 0.35, 0.35, 0.8) end
	UiRect(w, h)
	UiColor(1, 1, 1, enabled and 1 or 0.4)
	UiTranslate(w / 2, h / 2)
	UiAlign("center middle")
	UiFont("bold.ttf", 22)
	UiText(label)
	UiPop()
	return enabled and over and InputPressed("lmb")
end

function brawlEditorDraw()
	if not BE.on then return end
	UiMakeInteractive()
	SetBool("game.disablemap", true)
	brawlViewApply()
	local mx, my = UiGetMousePos()
	-- screen positions: corners and edge middles
	local cs, ms = {}, {}
	local n = #BE.pts
	for i, p in ipairs(BE.pts) do
		local x, y, dist = UiWorldToPixel(p)
		cs[i] = {x, y, dist}
		local q = BE.pts[i % n + 1]
		local m = VecLerp(p, q, 0.5)
		local x2, y2, d2 = UiWorldToPixel(m)
		ms[i] = {x2, y2, d2}
	end
	local overBar = my < BE_BAR_H
	if not overBar then
		local ci, mi = nearest(cs, mx, my), nearest(ms, mx, my)
		if InputPressed("lmb") then
			if ci then BE.drag = ci
			elseif mi and n < BA_MAX_CORNERS then
				table.insert(BE.pts, mi + 1, VecLerp(BE.pts[mi], BE.pts[mi % n + 1], 0.5))
				BE.drag, BE.dirty = mi + 1, true
			end
		elseif InputPressed("rmb") then
			if ci and n > 3 then table.remove(BE.pts, ci); BE.dirty = true
			elseif mi and not ci and n < BA_MAX_CORNERS then
				table.insert(BE.pts, mi + 1, VecLerp(BE.pts[mi], BE.pts[mi % n + 1], 0.5)); BE.dirty = true
			end
		end
	end
	if BE.drag and InputDown("lmb") then
		local g = brawlCursorGround(mx, my)
		if g and BE.pts[BE.drag] then BE.pts[BE.drag] = g; BE.dirty = true end
	elseif not InputDown("lmb") then
		BE.drag = nil
	end
	-- the handles
	for i, s in ipairs(ms) do
		if s[3] > 0 then
			UiPush(); UiTranslate(s[1], s[2]); UiAlign("center middle"); UiColor(1, 1, 1, 0.55); UiRect(10, 10); UiPop()
		end
	end
	for i, s in ipairs(cs) do
		if s[3] > 0 then
			UiPush()
			UiTranslate(s[1], s[2])
			UiAlign("center middle")
			UiColor(0, 0, 0, 0.8); UiRect(22, 22)
			if BE.drag == i then UiColor(1, 0.85, 0.2, 1) else UiColor(0.15, 0.85, 1, 1) end
			UiRect(16, 16)
			UiPop()
		end
	end
	-- the bar
	UiPush()
	UiColor(0, 0, 0, 0.6)
	UiRect(UiWidth(), BE_BAR_H)
	UiTranslate(30, 30)
	UiAlign("left middle")
	UiFont("bold.ttf", 24)
	UiColor(1, 1, 1, 1)
	UiText("FIGHT AREA - drag a corner (LMB). RMB: add a corner on an edge marker / remove a corner.")
	UiTranslate(0, 34)
	UiFont("bold.ttf", 18)
	UiColor(0.85, 0.85, 0.85, 1)
	local lo, hi = math.huge, -math.huge
	for _, p in ipairs(BE.pts) do lo, hi = math.min(lo, p[2]), math.max(hi, p[2]) end
	UiText(string.format("%s   %d corners   every floor inside counts", brawlViewHint(), n))
	UiPop()
	local b = shared.brawl
	brawlDrawHeightBar(b and b.src ~= "none" and b.area or "")     -- (the cut, at the right edge)
	UiPush()
	UiTranslate(UiWidth() - 3 * 150 - 30, 24)
	local done = button("Done", 140, 48, true)
	UiTranslate(150, 0)
	local cancel = button("Cancel", 140, 48, true)
	UiTranslate(150, 0)
	local reset = button("Reset", 140, 48, true)
	UiPop()
	if done then
		brawlEditorSend(baZoneString(BE.pts))                     -- (no height limit: every floor inside counts)
		BE.on = false
	elseif cancel then
		BE.on = false
	elseif reset then
		BE.pts = {}
		for i, p in ipairs(BE.start) do BE.pts[i] = VecCopy(p) end
		BE.drag, BE.dirty = nil, true
	end
end

----- dragging the whole fight area in the lobby's view (the host; the user: "when hosts clicks and drags inside the
----- fight zone, they could move the whole thing around") -----
-- LMB pressed with the cursor's ground point (the camera's ray, passing what lies above the cut) inside the area's
-- x/z footprint, not over a UI panel (overUI) and not while the editor is open: every part follows the cursor in x/z
-- (a box stays a box, a cylinder a cylinder); on release the heights shift by the ground under the new centre minus the
-- ground under the old one (bvGroundAt: floors, not bars) and the moved area goes to the server like the editor's
-- (brawlEditorSend, how "moved": re-sent until confirmed). A press without a move changes nothing.
--   brawlMoveDraw(b, overUI)        client.draw in the lobby (the host): hover, press, drag, release
--   brawlMoveOutline() -> shapes|nil  the area to draw cyan instead of the published one (dragging, or sent and waiting)
--   brawlMoveHover() -> bool        the cursor is over the area (the "Drag to move" hint)

BM = {drag = false, hover = false, g0 = nil, orig = nil, dx = 0, dz = 0, sent = nil, sentSeq = nil, sentT = -100}

function brawlMoveHover() return BM.hover or BM.drag end

function brawlMoveOutline()
	if BM.drag then return baTranslate(BM.orig, BM.dx, 0, BM.dz) end
	if BM.sent then
		local b = shared.brawl
		if (b and b.areaSeq ~= BM.sentSeq) or GetTime() - BM.sentT > 6 then BM.sent = nil else return BM.sent end
	end
	return nil
end

function brawlMoveDraw(b, overUI)
	BM.hover = false
	if not IsPlayerHost(GetLocalPlayer()) or not b or b.src == "none" or brawlEditorActive() then BM.drag = false; return end
	local mx, my = UiGetMousePos()
	local g = brawlCursorGround(mx, my)
	if not BM.drag then
		if g and not overUI(mx, my) then
			local shapes = baParse(b.area)
			if baInsideXZ(shapes, g[1], g[3]) then
				BM.hover = true
				if InputPressed("lmb") then BM.drag, BM.g0, BM.orig, BM.dx, BM.dz = true, g, shapes, 0, 0 end
			end
		end
		return
	end
	if InputDown("lmb") then
		if g then BM.dx, BM.dz = g[1] - BM.g0[1], g[3] - BM.g0[3] end
		return
	end
	BM.drag = false                                                  -- released
	if math.abs(BM.dx) + math.abs(BM.dz) < 0.05 then return end
	local c0 = baCentre(BM.orig)
	local gOld = bvGroundAt(c0[1], c0[3]) or c0[2]
	local gNew = bvGroundAt(c0[1] + BM.dx, c0[3] + BM.dz) or gOld
	local moved = baTranslate(BM.orig, BM.dx, gNew - gOld, BM.dz)
	BM.sent, BM.sentSeq, BM.sentT = moved, b.areaSeq, GetTime()
	brawlEditorSend(baAreaString(moved), "moved")
end
