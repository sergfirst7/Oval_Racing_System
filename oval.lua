-- Oval Racing System: virtual pace car for oval races (CSP online script).
-- One file, the same code runs on every client. State is shared with ac.OnlineEvent,
-- the pace car position is computed from the synced session clock. See README.md.

local VERSION = 'Oval 8.0'
local sim = ac.getSim()

-- Every value can be overridden in the [SCRIPT_x] section of the server's CSP extra options.
local cfg = ac.configValues({
  paceKmh = 100,       -- pace car speed
  speedTolKmh = 8,     -- speed above the limit that still counts as fine
  catchupKmh = 60,     -- extra speed allowed while closing a big gap to the car ahead
  bunchGapM = 30,      -- gap to keep to the car ahead (or to the pace car)
  paceLeadM = 300,     -- how far ahead of the race leader the pace car appears
  everySession = 0,    -- 1: run in every session, not only in races (testing)
  debug = 0,           -- 1: show the debug panel
})

local GREEN, CAUTION, ONE_TO_GO = 0, 1, 2
local NONE, ORDER_MAX, STOP_KMH = 255, 48, 25

local function frac(x) return x - math.floor(x) end
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end
local function trackLen() local l = sim.trackLengthM; return (l and l > 100) and l or 1000 end
local function clock() return sim.currentSessionTime end -- ms, synced across clients

local function activeCars() -- sessionID -> car
  local m = {}
  for i = 0, sim.carsCount - 1 do
    local c = ac.getCar(i)
    if c and c.isConnected and c.isActive then m[c.sessionID] = c end
  end
  return m
end

-- ── shared state ─────────────────────────────────────────────────────────────
-- order: sessionIDs, closest behind the pace car first (the physical order at deployment)
local function freshState() return { seq = 0, from = NONE, phase = GREEN, reason = 0, cause = NONE, tStart = 0, s0 = 0, kmh = 0, order = {} } end
local S = freshState()
local L1 = {} -- rule state of the local car
local function resetLocal() L1 = {} end

local sendEvent, accessEvent, outbox
local function onState(sender, d)
  if not sender then return end -- only clients talk to us
  local from = sender.sessionID
  if d.seq < S.seq or (d.seq == S.seq and from >= S.from) then return end -- older, or our own echo
  if d.tStart > clock() + 3000 then return end -- stale message from a previous session
  local order = {}
  for i = 0, math.min(d.n, ORDER_MAX) - 1 do order[#order + 1] = d.order[i] end
  S = { seq = d.seq, from = from, phase = d.phase, reason = d.reason, cause = d.cause, tStart = d.tStart, s0 = d.s0, kmh = d.kmh, order = order }
  resetLocal()
end

local ok, s, a = pcall(ac.OnlineEvent, {
  ac.StructItem.key('ovalState8'),
  seq = ac.StructItem.int32(),
  tStart = ac.StructItem.int32(),
  s0 = ac.StructItem.float(),
  kmh = ac.StructItem.uint16(),
  phase = ac.StructItem.uint8(),
  reason = ac.StructItem.uint8(),
  cause = ac.StructItem.uint8(),
  n = ac.StructItem.uint8(),
  order = ac.StructItem.array(ac.StructItem.uint8(), ORDER_MAX),
}, onState)
if ok then sendEvent, accessEvent = s, a else ac.log('Oval: online events unavailable: ' .. tostring(s)) end

-- Makes a new state current here and queues it for everybody else.
local function commit(phase, reason, cause, tStart, s0, order)
  S = { seq = S.seq + 1, from = ac.getCar(0).sessionID, phase = phase, reason = reason, cause = cause, tStart = math.floor(tStart), s0 = s0, kmh = cfg.paceKmh, order = order }
  resetLocal()
  if not accessEvent then return end
  local p = accessEvent() -- fill every field: the buffer is reused
  p.seq, p.tStart, p.s0, p.kmh, p.phase, p.reason, p.cause, p.n = S.seq, S.tStart, s0, S.kmh, phase, reason, cause, #order
  for i = 0, ORDER_MAX - 1 do p.order[i] = order[i + 1] or NONE end
  outbox = true
end

local function pacePos() return frac(S.s0 + S.kmh / 3.6 * (clock() - S.tStart) / 1000 / trackLen()) end

local function ahead(a, b) -- is car a ahead of car b in the race
  if a.racePosition > 0 and b.racePosition > 0 and a.racePosition ~= b.racePosition then return a.racePosition < b.racePosition end
  return a.lapCount + a.splinePosition > b.lapCount + b.splinePosition
end

local function deploy(reason, cause)
  local cars, head = activeCars(), nil
  for _, c in pairs(cars) do
    if not c.isInPitlane and (not head or ahead(c, head)) then head = c end
  end
  if not head then return end
  local s0, list = frac(head.splinePosition + cfg.paceLeadM / trackLen()), {}
  for _, c in pairs(cars) do
    if not c.isInPitlane and not c.isRetired then list[#list + 1] = c end
  end
  table.sort(list, function(x, y) return frac(s0 - x.splinePosition) < frac(s0 - y.splinePosition) end)
  local order = {}
  for i = 1, math.min(#list, ORDER_MAX) do order[i] = list[i].sessionID end
  commit(CAUTION, reason, cause, clock(), s0, order)
end

local function release() commit(GREEN, 0, NONE, clock(), 0, {}) end

-- ── rules for the local car ──────────────────────────────────────────────────
-- Tracks the signed distance to the car we must follow (rel > 0: it is ahead). It is integrated
-- frame by frame, because on a ring "ahead by 0.95 lap" and "behind by 0.05 lap" look the same.
local function localCheck(cars)
  local me = ac.getCar(0)
  if S.phase == GREEN or me.isInPitlane then return resetLocal() end
  local idx
  for i, id in ipairs(S.order) do if id == me.sessionID then idx = i break end end
  if not idx then return resetLocal() end

  local ref, key, refPos
  for j = idx - 1, 1, -1 do -- nearest car ahead that is on track and moving
    local c = cars[S.order[j]]
    if c and not c.isInPitlane and c.speedKmh > STOP_KMH then ref, key, refPos = c, c.sessionID, c.splinePosition break end
  end
  if not ref and S.phase == CAUTION then key, refPos = 'pace', pacePos() end
  if not refPos then L1.rel = nil return end -- leader with the pace car gone

  local len, raw = trackLen(), refPos - me.splinePosition
  if L1.key ~= key or not L1.rel then
    L1.rel = frac(raw) * len -- first sight: the reference is ahead by definition of the order
  else
    local d = raw - L1.raw
    L1.rel = L1.rel + (d - math.floor(d + 0.5)) * len
  end
  L1.key, L1.raw, L1.ref = key, raw, ref

  local speed = me.speedKmh
  L1.allowed = cfg.paceKmh + clamp((L1.rel - cfg.bunchGapM) / (4 * cfg.bunchGapM), 0, 1) * cfg.catchupKmh
  L1.speeding = speed > L1.allowed + cfg.speedTolKmh
  L1.passing = L1.rel < -3
  L1.lagging = L1.rel > 4 * cfg.bunchGapM and speed < cfg.paceKmh - 20
end

-- ── entry points ─────────────────────────────────────────────────────────────
local uiTime, lastClock, lastError = 0, 0, nil
local function guard(fn)
  return function(...)
    local good, err = pcall(fn, ...)
    if not good and err ~= lastError then lastError = err; ac.log('Oval error: ' .. tostring(err)) end
  end
end

local function isActive() return cfg.everySession == 1 or sim.raceSessionType == ac.SessionType.Race end
local function reset() S = freshState(); resetLocal() end
ac.onSessionStart(reset)

-- Admin commands typed in chat: !yellow, !green
ac.onOutgoingChatMessage(function(msg)
  local cmd = msg:lower():match('^%s*!(%a+)%s*$')
  if (cmd ~= 'yellow' and cmd ~= 'green') or not isActive() then return false end
  if sim.isOnlineRace and not sim.isAdmin then return false end
  if cmd == 'yellow' then deploy(0, NONE) else release() end
  return true
end)

function script.update(dt)
  guard(function()
    uiTime = uiTime + dt
    local now = clock()
    if now < lastClock - 5000 then reset() end -- session restarted
    lastClock = now
    if outbox and sendEvent and sendEvent(nil, true) then outbox = false end -- rate limited, retried next frame
    if not isActive() then if S.seq > 0 then reset() end return end

    local cars, me = activeCars(), ac.getCar(0)
    local controller = NONE
    for id in pairs(cars) do if id < controller then controller = id end end
    if controller == me.sessionID and S.phase ~= GREEN and not cars[S.from] then
      commit(S.phase, S.reason, S.cause, S.tStart, S.s0, S.order) -- the sender left: re-announce, late joiners need it
    end
    localCheck(cars)
  end)()
end

-- ── HUD ──────────────────────────────────────────────────────────────────────
local YELLOW, GREENC, RED, BLACK = rgbm(1, 0.82, 0, 0.95), rgbm(0.1, 0.75, 0.2, 0.95), rgbm(0.9, 0.1, 0.1, 0.95), rgbm(0, 0, 0, 1)

local function centered(text, size, cx, y, color)
  ui.dwriteDrawText(text, size, vec2(cx - ui.measureDWriteText(text, size).x / 2, y), color)
end

function script.drawUI()
  guard(function()
    local win = ui.windowSize()
    if uiTime < 8 then ui.dwriteDrawText(VERSION .. ' loaded', 14, vec2(12, 8), rgbm(1, 1, 1, 0.8)) end
    if cfg.debug == 1 then
      local o = table.concat(S.order, ',')
      ui.dwriteDrawText(string.format('seq %d from %d phase %d n %d rel %s allowed %s %s', S.seq, S.from, S.phase, #S.order,
        L1.rel and math.floor(L1.rel) or '-', L1.allowed and math.floor(L1.allowed) or '-', lastError or ''), 13, vec2(12, 26), rgbm(1, 1, 0.4, 1))
      ui.dwriteDrawText('order ' .. o, 13, vec2(12, 42), rgbm(1, 1, 0.4, 1))
    end
    if not isActive() then return end
    local showGreen = S.phase == GREEN and S.seq > 0 and clock() - S.tStart < 5000
    if S.phase == GREEN and not showGreen then return end

    local k, cx, y = win.y / 1080, win.x / 2, 50 * win.y / 1080
    local title, bg = 'GREEN FLAG', GREENC
    if S.phase == CAUTION then title, bg = 'CAUTION', YELLOW elseif S.phase == ONE_TO_GO then title, bg = 'ONE TO GO', YELLOW end
    local rows = showGreen and 1 or 3
    ui.drawRectFilled(vec2(cx - 230 * k, y), vec2(cx + 230 * k, y + (44 + 30 * (rows - 1)) * k), bg, 10 * k)
    centered(title, 30 * k, cx, y + 6 * k, BLACK)
    if showGreen then return end

    local follow = L1.ref and ac.getDriverName(L1.ref.index) or 'PACE CAR'
    centered('FOLLOW  ' .. follow, 18 * k, cx, y + 44 * k, BLACK)
    if L1.rel then
      local bad = L1.speeding or L1.passing
      centered(string.format('%d m     %d / %d km/h', math.floor(math.max(L1.rel, 0) + 0.5), math.floor(ac.getCar(0).speedKmh), math.floor(L1.allowed + 0.5)),
        22 * k, cx, y + 72 * k, bad and RED or BLACK)
    end
    local warn = L1.passing and 'DO NOT PASS - DROP BACK' or L1.speeding and 'SLOW DOWN' or L1.lagging and 'CLOSE THE GAP'
    if warn then
      ui.drawRectFilled(vec2(cx - 230 * k, y + 108 * k), vec2(cx + 230 * k, y + 148 * k), RED, 10 * k)
      centered(warn, 24 * k, cx, y + 114 * k, rgbm(1, 1, 1, 1))
    end
  end)()
end

function script.draw3D()
  guard(function()
    if S.phase ~= CAUTION or not isActive() then return end
    local p = ac.trackCoordinateToWorld(vec3(0, 0, pacePos()))
    render.debugArrow(p + vec3(0, 14, 0), p + vec3(0, 2, 0), 1.5, YELLOW)
    render.debugText(p + vec3(0, 16, 0), 'PACE CAR', YELLOW, 2)
  end)()
end

-- Offline tests load this file with a fake `ac` and read the internals from here.
if OVAL_TEST then return { state = function() return S end, local1 = function() return L1 end, pacePos = pacePos, lastError = function() return lastError end } end
