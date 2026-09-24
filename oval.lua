-- Oval Racing System: virtual pace car for oval races (CSP online script).
-- One file, the same code runs on every client. State is shared with ac.OnlineEvent,
-- the pace car position is computed from the synced session clock. See README.md.

local VERSION = 'Oval 9.1'
local sim = ac.getSim()

-- Every value can be overridden in the [SCRIPT_x] section of the server's CSP extra options.
local cfgDefaults = {
  paceKmh = 100,       -- pace car speed
  speedTolKmh = 8,     -- speed above the limit that still counts as fine
  catchupKmh = 60,     -- extra speed allowed while closing a big gap to the car ahead
  bunchGapM = 30,      -- gap to keep to the car ahead (or to the pace car)
  paceLeadM = 300,     -- how far ahead of the race leader the pace car appears
  autoCaution = 1,     -- 1: a wreck or a car stopped on track calls the caution automatically
  slowKmh = 40,        -- below this speed a car counts as stopped
  limpRatio = 0.5,     -- a car that stays below this share of its own top speed (and under 110 km/h) counts as stopped, 0 = off
  wreckDropKmh = 60,   -- losing this much speed within 0.4 s (35 within a second of a contact) is a wreck
  stopSec = 3,         -- how long a car must stay that slow to count as an incident
  raceKmh = 80,        -- a car only counts after it has been this fast since the last green
  cooldownSec = 4,     -- no automatic caution in the first seconds after a green flag
  penalty = 'drive',   -- what breaking the pace rules costs: 'off' (warnings only), 'slow' (up to a gas cut), 'drive' (up to a drive-through)
  graceSec = 6,        -- time to slow down after the pace car appears before violations count
  speedSec = 4,        -- being too fast for this long is a violation
  passSec = 1.2,       -- being ahead of the car in front for this long is a violation
  strikeGapSec = 8,    -- the same violation is counted at most once per this many seconds
  slowSec = 5,         -- length of the gas cut penalty
  driveLaps = 3,       -- laps the game gives to serve a drive-through (it counts them from the green flag, when it is handed out)
  rolling = 1,         -- 1: the race starts behind the pace car (rolling start); 0: standing start
  formationLaps = 1,   -- pace laps of the rolling start before the field may go green
  startLeadM = 40,     -- how far ahead of pole position the pace car starts
  cautionLaps = 1,     -- pace laps before the field may be sent back to green
  maxCautionLaps = 4,  -- restart anyway after this many pace laps
  oneToGoAt = 0.75,    -- the pace car leaves in the last quarter of a lap (track position 0..1), green at the line
  paceModel = 'content/cars/aston_vantage2018/aston_vantage2018.kn5', -- 3D model of the pace car, '' for the arrow marker only
  paceFlip = 0,        -- 1: turn the model around if it drives backwards
  paceLightA = 'g_safety_red',    -- meshes of the model's own light bar that flash (the first one, then...
  paceLightB = 'g_safety_yellow', -- ...the second one)
  everySession = 0,    -- 1: run in every session, not only in races (testing)
  debug = 0,           -- 1: show the debug panel (chat command !ovaldebug toggles it for you)
}
local okCfg, cfgRead = pcall(ac.configValues, cfgDefaults)
local cfg = okCfg and cfgRead or cfgDefaults

local GREEN, CAUTION, ONE_TO_GO = 0, 1, 2
local NONE, ORDER_MAX, STOP_KMH, RANK_DELAY = 255, 48, 25, 0.4
local TITLES = { [0] = 'CAUTION', [1] = 'CAUTION - CAR STOPPED', [2] = 'ROLLING START', [3] = 'CAUTION - WRECK' }

local function try(what, fn, ...) -- a missing feature costs that feature, not the whole script
  local good, err = pcall(fn, ...)
  if not good then ac.log('Oval: ' .. what .. ' unavailable: ' .. tostring(err)) end
  return good
end
local RACE = ac.SessionType and ac.SessionType.Race or 3
local okBuild, build = pcall(ac.getPatchVersionCode)
build = okBuild and build or '?'

local function frac(x) return x - math.floor(x) end
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end
local function trackLen() local l = sim.trackLengthM; return (l and l > 100) and l or 1000 end
local function clock() return sim.currentSessionTime end -- ms, synced across clients

local function activeCars() -- sessionID -> car
  local m = {}
  for i = 0, sim.carsCount - 1 do
    local c = ac.getCar(i)
    if c and c.isConnected and c.isActive ~= false then m[c.sessionID] = c end
  end
  return m
end

-- ── shared state ─────────────────────────────────────────────────────────────
-- order: sessionIDs, closest behind the pace car first (the physical order at deployment)
local function freshState() return { seq = 0, from = NONE, phase = GREEN, reason = 0, cause = NONE, tStart = 0, s0 = 0, kmh = 0, order = {} } end
local S = freshState()
local L1, watch, ctl = {}, {}, {} -- rules of the local car / incident watch of the local car / restart bookkeeping
local pen, penNote, lastContact = { strikes = 0, last = {} }, nil, -100 -- penalties of the local car, the message about the last one, last contact
local uiTime, lastClock, lastError, hudCars, hudRank, debugOn, greeted = 0, 0, nil, {}, 0, cfg.debug == 1, false

local function adopt(new) -- local state survives order updates of the same deployment
  if new.phase ~= S.phase or new.tStart ~= S.tStart then L1, watch, ctl = {}, {}, {} end
  if new.seq ~= S.seq or new.from ~= S.from then
    ac.log(string.format('Oval: state seq=%d from=%d phase=%d reason=%d cause=%d cars=%d clock=%d', new.seq, new.from, new.phase, new.reason, new.cause, #new.order, math.floor(clock())))
  end
  if new.phase == CAUTION and S.phase == GREEN then pen.strikes, pen.last = 0, {} end -- a new deployment: a clean sheet
  S = new
end

local sendEvent, accessEvent, outbox
local presence, stats = {}, { sent = 0, got = 0, stale = 0 } -- clients that run the script, message counters
local function onState(sender, d)
  if not sender then return end -- only clients talk to us
  local from = sender.sessionID
  stats.got = stats.got + 1
  if not presence[from] then
    presence[from] = true
    ac.log(string.format('Oval: script seen on client %d (seq=%d)', from, d.seq))
  end
  if d.seq == 0 then return end -- a greeting, not a state
  if d.seq < S.seq or (d.seq == S.seq and from >= S.from) then return end -- older, or our own echo
  if d.tStart > clock() + 3000 then -- stale message from a previous session
    stats.stale = stats.stale + 1
    ac.log(string.format('Oval: ignored a stale message seq=%d from=%d tStart=%d clock=%d', d.seq, from, d.tStart, math.floor(clock())))
    return
  end
  local order = {}
  for i = 0, math.min(d.n, ORDER_MAX) - 1 do order[#order + 1] = d.order[i] end
  adopt({ seq = d.seq, from = from, phase = d.phase, reason = d.reason, cause = d.cause, tStart = d.tStart, s0 = d.s0, kmh = d.kmh, order = order })
end

local ok, s, a = pcall(function()
  return ac.OnlineEvent({
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
end)
if ok then sendEvent, accessEvent = s, a else ac.log('Oval: online events unavailable: ' .. tostring(s)) end

-- Puts a message into the shared buffer and queues it for everybody else.
local outboxAt
local function queue(seq, tStart, s0, kmh, phase, reason, cause, order)
  if not accessEvent then return end
  local p = accessEvent() -- fill every field: the buffer is reused
  p.seq, p.tStart, p.s0, p.kmh, p.phase, p.reason, p.cause, p.n = seq, tStart, s0, kmh, phase, reason, cause, #order
  for i = 0, ORDER_MAX - 1 do p.order[i] = order[i + 1] or NONE end
  outbox, outboxAt = true, outboxAt or uiTime
end

-- Makes a new state current here and queues it for everybody else.
local function commit(phase, reason, cause, tStart, s0, order)
  adopt({ seq = S.seq + 1, from = ac.getCar(0).sessionID, phase = phase, reason = reason, cause = cause, tStart = math.floor(tStart), s0 = s0, kmh = cfg.paceKmh, order = order })
  queue(S.seq, S.tStart, s0, S.kmh, phase, reason, cause, order)
end

local function pacePos() return frac(S.s0 + S.kmh / 3.6 * (clock() - S.tStart) / 1000 / trackLen()) end

local function ahead(a, b) -- is car a ahead of car b in the race
  local pa, pb = a.racePosition or 0, b.racePosition or 0
  if pa > 0 and pb > 0 and pa ~= pb then return pa < pb end
  if S.seq == 0 and a.lapCount == 0 and b.lapCount == 0 then return frac(-a.splinePosition) < frac(-b.splinePosition) end -- on the grid: closest before the line
  return a.lapCount + a.splinePosition > b.lapCount + b.splinePosition
end

-- reason: 0 admin, 1 stopped car, 2 rolling start, 3 wreck
local function deploy(reason, cause)
  local cars, head = activeCars(), nil
  for _, c in pairs(cars) do
    if not c.isInPitlane and (not head or ahead(c, head)) then head = c end
  end
  if not head then return end
  local lead = reason == 2 and cfg.startLeadM or cfg.paceLeadM
  local s0, list = frac(head.splinePosition + lead / trackLen()), {}
  for _, c in pairs(cars) do
    if not c.isInPitlane and not c.isRetired then list[#list + 1] = c end
  end
  table.sort(list, function(x, y) return frac(s0 - x.splinePosition) < frac(s0 - y.splinePosition) end)
  local order = {}
  for i = 1, math.min(#list, ORDER_MAX) do order[i] = list[i].sessionID end
  commit(CAUTION, reason, cause, clock(), s0, order)
end

local function release() commit(GREEN, 0, NONE, clock(), 0, {}) end

-- ── penalties ────────────────────────────────────────────────────────────────
-- Every client judges its own car. Violations are counted per pace car deployment: the first one
-- is a warning, the second cuts the gas, from the third on a drive-through is due (unless one is
-- still pending). Passing the pace car and jumping the restart count double.
local function setPenalty(kind, param)
  local good, err = pcall(function() physics.setCarPenalty(ac.PenaltyType[kind], param) end)
  if not good then ac.log('Oval: penalty ' .. kind .. ' could not be applied: ' .. tostring(err)) end
  return good
end

local function penalize(why, weight)
  if uiTime - (pen.last[why] or -100) < cfg.strikeGapSec then return end -- the same offence at most once per gap
  pen.last[why], pen.strikes = uiTime, pen.strikes + weight
  local level, title, applied = pen.strikes, 'WARNING', true
  if cfg.penalty ~= 'off' and level >= 2 then
    if cfg.penalty == 'drive' and level >= 3 and not pen.owed and not pen.driving then
      -- The game counts the laps to serve it from the moment it is handed out, and a caution is over
      -- in about a lap: handed out then, it would run out before the field can serve it (black flag,
      -- teleport to the pits). So it is handed out when the race is green again.
      title, pen.owed = 'DRIVE-THROUGH AFTER THE GREEN', true
    elseif uiTime - (pen.slowAt or -100) < cfg.slowSec + 3 then
      title = 'GAS CUT (ALREADY ACTIVE)' -- a running gas cut is not extended
    else
      title = 'GAS CUT ' .. cfg.slowSec .. ' S'
      applied = setPenalty('SlowDown', cfg.slowSec)
      if applied then pen.slowAt = uiTime end
    end
  end
  if not applied then title = title .. ' (NOT ENFORCED)' end
  penNote = { title = title, why = why, untilT = uiTime + 7 }
  pcall(ac.setMessage, title, why, 'illegal', 7)
  ac.log(string.format('Oval: %s - %s (strikes %d)', title, why, level))
end

-- being too fast or ahead of the car in front counts only when it lasts, and not right after
-- the pace car appeared, not in the pits and not right after a contact (we may have been pushed)
local function judge(dt)
  local grace = S.phase == CAUTION and (S.reason == 2 and 15 or cfg.graceSec) or 0
  local free = clock() - S.tStart < grace * 1000 or uiTime - lastContact < 3
  L1.speedT = L1.speeding and not free and (L1.speedT or 0) + dt or 0
  L1.passT = L1.passing and not free and (L1.passT or 0) + dt or 0
  if L1.speedT >= cfg.speedSec then
    L1.speedT = 0
    penalize(S.phase == ONE_TO_GO and 'Too fast before the green flag' or 'Speeding behind the pace car', 1)
  end
  if L1.passT >= cfg.passSec then
    L1.passT = 0
    local pace, restart = L1.key == 'pace', S.phase == ONE_TO_GO
    penalize(pace and 'Passed the pace car' or restart and 'Jumped the restart' or 'Passed under caution', (pace or restart) and 2 or 1)
  end
end

-- a drive-through that is due is handed out once the race is green again
local function handOutOwed()
  if not pen.owed or pen.driving or S.phase ~= GREEN or clock() - S.tStart < 2000 then return end
  pen.owed = false
  local applied = setPenalty('MandatoryPits', cfg.driveLaps)
  if applied then pen.driving, pen.pitSeen = true, false end
  local title = 'DRIVE-THROUGH PENALTY' .. (applied and '' or ' (NOT ENFORCED)')
  penNote = { title = title, why = 'Enter the pit lane now', untilT = uiTime + 7 }
  pcall(ac.setMessage, title, 'Enter the pit lane now', 'illegal', 7)
  ac.log('Oval: ' .. title .. ' handed out after the green flag')
end

-- a drive-through is served once the car has been through the pit lane
local function servePenalty(me)
  if not pen.driving then return end
  if me.isInPitlane then pen.pitSeen = true
  elseif pen.pitSeen then pen.driving = false; ac.log('Oval: drive-through served') end
end

-- ── rules for the local car ──────────────────────────────────────────────────
-- Tracks the signed distance to the car we must follow (rel > 0: it is ahead). It is integrated
-- frame by frame, because on a ring "ahead by 0.95 lap" and "behind by 0.05 lap" look the same.
local function localCheck(cars, dt)
  local me = ac.getCar(0)
  if S.phase == GREEN or me.isInPitlane then L1 = {} return end
  local idx
  for i, id in ipairs(S.order) do if id == me.sessionID then idx = i break end end
  if not idx then L1 = {} return end

  local launching = S.reason == 2 and clock() - S.tStart < 15000 -- cars still accelerate from the grid
  local ref, key, refPos
  for j = idx - 1, 1, -1 do -- nearest car ahead that is on track and moving
    local c = cars[S.order[j]]
    if c and not c.isInPitlane and (c.speedKmh > STOP_KMH or launching) then ref, key, refPos = c, c.sessionID, c.splinePosition break end
  end
  if not ref and S.phase == CAUTION then key, refPos = 'pace', pacePos() end
  if not refPos then -- leader after the pace car has left: hold the pace until the green flag
    L1.rel, L1.passing, L1.lagging, L1.allowed = nil, false, false, cfg.paceKmh
    L1.speeding = me.speedKmh > L1.allowed + cfg.speedTolKmh
    return judge(dt)
  end

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
  L1.passing = L1.rel < (S.reason == 2 and -12 or -3) -- the grid is two abreast, a few metres either way are fine
  L1.lagging = L1.rel > 4 * cfg.bunchGapM and speed < cfg.paceKmh - 20
  judge(dt)
end

-- ── incidents: every client watches its own car ──────────────────────────────
-- Own data is the only reliable data. A wreck is a sudden loss of speed (with or without a contact
-- event), a car that stays slow for stopSec is stopped: standing, or limping below limpRatio of the
-- speed it was doing. Remote cars are not watched: their data is late and the owner knows best.
local okHit, errHit = pcall(ac.onCarCollision, 0, function()
  lastContact = uiTime
  local peak = watch.peak or 0
  if uiTime - (watch.hitLog or -5) > 2 then
    watch.hitLog = uiTime
    ac.log(string.format('Oval: contact, speed=%d peak=%d', math.floor(ac.getCar(0).speedKmh), math.floor(peak)))
  end
  if peak > 100 then watch.hit = { t = uiTime, peak = peak } end
end)
if not okHit then ac.log('Oval: contact events unavailable: ' .. tostring(errHit)) end

local function watchSelf(dt, now)
  local me = ac.getCar(0)
  local speed = me.speedKmh
  watch.peak = math.max(speed, (watch.peak or 0) - 150 * dt) -- speed of the last second or so
  watch.top = math.max(speed, (watch.top or 0) - 3 * dt) -- the speed we were doing, forgotten slowly
  local h = watch.hist or {}
  watch.hist = h
  h[#h + 1] = { t = uiTime, v = speed }
  while uiTime - h[1].t > 1 do table.remove(h, 1) end
  local function lost(window) -- speed lost within the last `window` seconds
    local top = speed
    for _, x in ipairs(h) do if uiTime - x.t <= window and x.v > top then top = x.v end end
    return top - speed
  end

  if speed > cfg.raceKmh then watch.fast = true end
  if cfg.autoCaution ~= 1 or not watch.fast or me.isInPitlane or me.isRetired or (S.seq > 0 and now - S.tStart < cfg.cooldownSec * 1000) then
    watch.slow, watch.hit = 0, nil
    return
  end
  local hit = watch.hit
  if hit and uiTime - hit.t > 2.5 then hit = nil; watch.hit = nil end
  local recent = hit and uiTime - hit.t < 1
  if lost(0.4) >= cfg.wreckDropKmh or (recent and lost(1) >= 35) or (hit and speed < hit.peak * 0.35) then
    ac.log(string.format('Oval: wreck, speed=%d lost=%d contact=%s', math.floor(speed), math.floor(lost(1)), tostring(hit ~= nil)))
    return deploy(3, me.sessionID)
  end
  local slow = speed < cfg.slowKmh or (cfg.limpRatio > 0 and speed < cfg.limpRatio * watch.top and speed < 110)
  watch.slow = slow and (watch.slow or 0) + dt or 0
  if watch.slow >= cfg.stopSec then
    ac.log(string.format('Oval: stopped car, speed=%d top=%d', math.floor(speed), math.floor(watch.top)))
    deploy(1, me.sessionID)
  end
end

-- ── restart handling: every client computes it, the lowest session ID acts first ─────────
-- A client only acts after `rank * RANK_DELAY` seconds without a newer state, so a car whose
-- driver has no script cannot stall the flow: the next one takes over.
local pend, lastLeader, bunchT = { key = nil }, nil, 0
local start = {}
local function due(key, rank)
  if pend.key ~= key or pend.seq ~= S.seq or uiTime - pend.last > 0.5 then pend = { key = key, seq = S.seq, at = uiTime } end
  pend.last = uiTime
  return uiTime - pend.at >= rank * RANK_DELAY
end

local function stoppedOnTrack(c) return not c.isInPitlane and not c.isRetired and c.speedKmh < STOP_KMH end
local function moving(c) return not c.isInPitlane and not c.isRetired and c.speedKmh > STOP_KMH end

local function hazard(cars)
  for _, c in pairs(cars) do if stoppedOnTrack(c) then return true end end
end

-- every moving car within 2 gaps of the one ahead, the leader within 3 gaps of the pace car
local function bunched(cars)
  local len, prev, limit = trackLen(), pacePos(), 3 * cfg.bunchGapM
  for _, id in ipairs(S.order) do
    local c = cars[id]
    if c and moving(c) then
      if frac(prev - c.splinePosition) * len > limit then return false end
      prev, limit = c.splinePosition, 2 * cfg.bunchGapM
    end
  end
  return true
end

-- Cars that left for the pits drop out of the order; cars that come back (or join) take the
-- place where they rejoined the pack, so nobody can gain places by pitting. nil: nothing changed.
local function desiredOrder(cars)
  local order, seen, p = {}, {}, pacePos()
  local function behind(c) return frac(p - c.splinePosition) end
  for _, id in ipairs(S.order) do
    local c = cars[id]
    if c and not c.isInPitlane and not c.isRetired then order[#order + 1] = id; seen[id] = true end
  end
  for id, c in pairs(cars) do
    if not seen[id] and not c.isInPitlane and not c.isRetired then
      local at = #order + 1
      for i, other in ipairs(order) do if behind(cars[other]) > behind(c) then at = i break end end
      table.insert(order, at, id)
    end
  end
  while #order > ORDER_MAX do order[#order] = nil end
  if #order ~= #S.order then return order end
  for i = 1, #order do if order[i] ~= S.order[i] then return order end end
end

-- true when the first moving car of the order crosses the start/finish line
local function leaderCrossed(cars)
  for _, id in ipairs(S.order) do
    local c = cars[id]
    if c and moving(c) then
      local crossed = lastLeader and lastLeader.id == id and lastLeader.s > 0.9 and c.splinePosition < 0.1
      lastLeader = { id = id, s = c.splinePosition }
      return crossed
    end
  end
  lastLeader = nil
end

local function control(cars, dt, rank)
  if S.phase == GREEN then lastLeader, bunchT = nil, 0 return end
  if not cars[S.from] then -- the sender is gone: say it again, late joiners need it
    if due('announce', rank) then commit(S.phase, S.reason, S.cause, S.tStart, S.s0, S.order) end
    return
  end
  local order = desiredOrder(cars)
  if order and due('order', rank) then return commit(S.phase, S.reason, S.cause, S.tStart, S.s0, order) end

  local len = trackLen()
  if S.phase == CAUTION then
    local laps = S.kmh / 3.6 * (clock() - S.tStart) / 1000 / len
    local need = S.reason == 2 and cfg.formationLaps or cfg.cautionLaps
    if bunched(cars) and not hazard(cars) then bunchT = bunchT + dt else bunchT = 0 end
    local pos = pacePos()
    -- laps counted up to the line where the flag will turn green; a tenth of a lap of slack for the head start
    local ready = laps >= cfg.maxCautionLaps or (laps + 1 - pos >= need - 0.1 and bunchT > 1.5)
    if ready and pos >= cfg.oneToGoAt and due('one', rank) then -- the pace car pulls off before the last turns
      commit(ONE_TO_GO, S.reason, S.cause, clock(), pos, S.order)
    end
    return
  end
  -- one to go: green when the leader crosses the line; after 1.5 laps in any case (nobody left to cross it)
  if leaderCrossed(cars) then ctl.cross = uiTime end
  local late = clock() - S.tStart > 1500 * len / (S.kmh / 3.6)
  if (late or (ctl.cross and uiTime - ctl.cross < 2.5 + rank * RANK_DELAY)) and due('green', rank) then release() end
end

-- ── entry points ─────────────────────────────────────────────────────────────
local function guard(fn)
  return function(...)
    local good, err = pcall(fn, ...)
    if not good and err ~= lastError then lastError = err; ac.log('Oval error: ' .. tostring(err)) end
  end
end

local function sessionType()
  local t = sim.raceSessionType
  if t ~= nil then return t end
  local good, sess = pcall(ac.getSession, sim.currentSessionIndex) -- older CSP: ask the session itself
  return good and sess and sess.type or nil
end
local function isActive() return cfg.everySession == 1 or sessionType() == RACE end
local function reset() S, L1, watch, ctl, start, greeted, pen, penNote = freshState(), {}, {}, {}, {}, false, { strikes = 0, last = {} }, nil end
try('session start events', ac.onSessionStart, reset)

-- Chat commands: !ovaldebug (anyone, only for yourself), !yellow / !green (admin)
local function command(msg)
  local cmd = msg:lower():match('^%s*!(%a+)%s*$')
  if cmd == 'ovaldebug' then debugOn = not debugOn return true end
  if (cmd ~= 'yellow' and cmd ~= 'green') or not isActive() then return false end
  if sim.isOnlineRace and not sim.isAdmin then return false end
  if cmd == 'yellow' then deploy(0, NONE) else release() end
  return true
end
if not try('chat commands', ac.onOutgoingChatMessage, command) then
  -- older CSP cannot intercept what we type: react to our own message when it comes back (it stays visible in the chat)
  try('chat commands from the incoming chat', ac.onChatMessage, function(msg, sender) if sender == 0 then command(msg) end end)
end

-- The session clock starts at 0 when the session is created, 30 s before the lights go out, so it
-- says nothing about the start. Signals: the countdown of the game (timeToSessionStart) has run
-- out, or the field that stood on the grid has started to move.
local function lightsOut(cars, now)
  local tts, fast = sim.timeToSessionStart, 0
  for _, c in pairs(cars) do fast = math.max(fast, c.speedKmh) end
  if tts and tts > 1000 then start.armed = true end
  if fast < 15 and now < 120000 then start.grid = true end -- has seen the whole field standing
  if start.grid and not start.done and uiTime - (start.logAt or -10) > 5 then
    start.logAt = uiTime
    ac.log(string.format('Oval: waiting for the lights, tts=%s started=%s clock=%d fast=%d', tostring(tts), tostring(sim.isSessionStarted), math.floor(now), math.floor(fast)))
  end
  -- the countdown decides; movement counts only when the game gives no countdown (cars jump to the grid at the start of a session)
  local ended = start.armed and (tts or -1) <= 0
  local moved = not start.armed and now > 3000 and fast > 15
  return start.grid and (ended or moved)
end

local function startRace(cars, rank, now) -- lights out: the field follows the pace car instead of racing away
  if S.seq > 0 then start.done = true end
  if cfg.rolling ~= 1 or start.done or not lightsOut(cars, now) or not due('start', rank) then return end
  local list = {}
  for id, c in pairs(cars) do list[#list + 1] = string.format('%d:p%d:%.4f', id, c.racePosition or 0, c.splinePosition) end
  deploy(2, NONE)
  if S.seq > 0 then
    start.done = true
    ac.log(string.format('Oval: lights out (tts=%s clock=%d), rolling start, grid %s', tostring(sim.timeToSessionStart), math.floor(now), table.concat(list, ' ')))
  end
end

-- ── the pace car on the road ─────────────────────────────────────────────────
-- A car model from the game folder is put on the track every frame at the synced position. The
-- model has its own light bar (safety car): its lenses flash by their own emissive, and two light
-- sources light up the surroundings. Anything that fails leaves the arrow.
local car3d = { state = 'idle' } -- idle / loading / ready / failed
local YELLOW = rgbm(1, 0.82, 0, 0.95)
local RED_ON, AMBER_ON, DARK = rgb(14, 0.6, 0), rgb(14, 7, 0), rgb(0, 0, 0)
local BAR = { 0, 1.45, -1.08 } -- centre of the light bar in the model (right, up, forward), read from the model file

local function loadPaceCar()
  car3d.state = 'loading'
  local root = ac.findNodes('carsRoot:yes'):createBoundingSphereNode('OvalPaceCar', 8)
  if not root then car3d.state = 'failed' return end
  root:setVisible(false)
  root:loadKN5Async(cfg.paceModel, function(err, model)
    guard(function()
      if not model then
        car3d.state = 'failed'
        ac.log('Oval: pace car model failed: ' .. tostring(err))
        return
      end
      -- each lens gets its own material, the two of them share one in the model
      car3d.lensA = model:findMeshes(cfg.paceLightA):ensureUniqueMaterials()
      car3d.lensB = model:findMeshes(cfg.paceLightB):ensureUniqueMaterials()
      car3d.lights = {}
      for i = 1, 2 do
        local l = ac.LightSource(ac.LightType.Regular)
        l.range, l.color = 14, DARK
        car3d.lights[i] = l
      end
      car3d.root, car3d.state = root, 'ready'
      ac.log('Oval: pace car model loaded: ' .. cfg.paceModel)
    end)()
  end)
end

-- position on the road, the direction of travel, the way up (follows banking) and to the right
local function roadFrame(s)
  local len = trackLen()
  local p = ac.trackCoordinateToWorld(vec3(0, 0, s))
  local fwd = (ac.trackCoordinateToWorld(vec3(0, 0, frac(s + 4 / len))) - p):normalize()
  local side = (ac.trackCoordinateToWorld(vec3(1, 0, s)) - ac.trackCoordinateToWorld(vec3(-1, 0, s))):normalize()
  local up = side:clone():cross(fwd):normalize()
  if up.y < 0 then up = up * -1 end
  return p, fwd, up, side
end

-- The height along the spline is not always the height of the asphalt (banking!): ask the physics
-- of the track for the real surface under that point, the spline is the fallback.
local function groundedFrame(s)
  local p, fwd, up, side = roadFrame(s)
  local hit, normal = vec3(0, 0, 0), vec3(0, 0, 0)
  local ok, dist = pcall(function() return physics.raycastTrack(p + vec3(0, 4, 0), vec3(0, -1, 0), 12, hit, normal) end)
  if ok and dist and dist > 0 then
    p = hit
    if normal.y > 0.5 then up = normal:clone():normalize() end
  elseif not car3d.rayLogged then
    car3d.rayLogged = true
    ac.log('Oval: no ground ray (' .. tostring(dist) .. '), the pace car follows the spline height')
  end
  return p, fwd, up, side
end

local function setLens(lens, key, on, color)
  if car3d[key] == on then return end
  car3d[key] = on
  lens:setMaterialProperty('ksEmissive', on and color or DARK)
end

local function updatePaceCar()
  local show = S.phase == CAUTION and isActive()
  if show and car3d.state == 'idle' and cfg.paceModel ~= '' then loadPaceCar() end
  if car3d.state ~= 'ready' then return end
  if car3d.visible ~= show then car3d.visible = show; car3d.root:setVisible(show) end

  local onA, onB = false, false
  if show then
    local p, fwd, up, side = groundedFrame(pacePos())
    local mf = cfg.paceFlip == 1 and -1 or 1 -- the model's forward relative to the travel direction
    car3d.root:setPosition(p):setOrientation(fwd * mf, up)
    car3d.frame = { p = p, up = up }
    local step = math.floor(uiTime * 10) % 6 -- double flash: the first lens, then the second, dark in between
    onA, onB = step == 0 or step == 2, step == 3 or step == 5
    local bar = p + side * BAR[1] + up * BAR[2] + fwd * (BAR[3] * mf)
    car3d.lights[1].position, car3d.lights[2].position = bar, bar
  end
  setLens(car3d.lensA, 'onA', onA, RED_ON)
  setLens(car3d.lensB, 'onB', onB, AMBER_ON)
  car3d.lights[1].color = onA and rgb(9, 0.4, 0) or DARK
  car3d.lights[2].color = onB and rgb(9, 4.5, 0) or DARK
end

local function drawPaceCar()
  if S.phase ~= CAUTION or not isActive() then return end
  if car3d.state ~= 'ready' then -- no model: an arrow and a label
    local p = ac.trackCoordinateToWorld(vec3(0, 0, pacePos()))
    render.debugArrow(p + vec3(0, 14, 0), p + vec3(0, 2, 0), 1.5, YELLOW)
    render.debugText(p + vec3(0, 16, 0), 'PACE CAR', YELLOW, 2)
    return
  end
  local f = car3d.frame
  if f then render.debugText(f.p + f.up * 3.6, 'PACE CAR', YELLOW, 1.5) end
end

function script.update(dt)
  guard(function()
    uiTime = uiTime + dt
    local now = clock()
    if now < lastClock - 5000 then reset() end -- session restarted
    lastClock = now
    if not greeted and accessEvent and uiTime > 1 and S.seq == 0 then -- tell the others that this client runs the script
      greeted = true
      queue(0, 0, 0, 0, GREEN, 0, NONE, {})
    end
    if outbox and sendEvent then
      if sendEvent(nil, true) then -- rate limited: retried next frame
        outbox, outboxAt, stats.sent, stats.warned = false, nil, stats.sent + 1, false
      elseif outboxAt and uiTime - outboxAt > 5 and not stats.warned then
        stats.warned = true
        ac.log('Oval: a message has not gone out for 5 s (rate limit, or the server does not pass client messages)')
      end
    end
    if not isActive() then if S.seq > 0 then reset() end return end

    local cars, me = activeCars(), ac.getCar(0)
    local rank = 0
    for id in pairs(cars) do if id < me.sessionID then rank = rank + 1 end end
    hudCars, hudRank = cars, rank
    if S.phase == GREEN then startRace(cars, rank, now); watchSelf(dt, now) end
    control(cars, dt, rank)
    localCheck(cars, dt)
    servePenalty(me)
    handOutOwed()
    updatePaceCar()
  end)()
end

-- ── HUD ──────────────────────────────────────────────────────────────────────
local GREENC, RED, BLACK = rgbm(0.1, 0.75, 0.2, 0.95), rgbm(0.9, 0.1, 0.1, 0.95), rgbm(0, 0, 0, 1)

local function centered(text, size, cx, y, color)
  ui.dwriteDrawText(text, size, vec2(cx - ui.measureDWriteText(text, size).x / 2, y), color)
end

local function drawDebug()
  local c, yel = ac.getCar(0), rgbm(1, 1, 0.4, 1)
  ui.dwriteDrawText(string.format('%s  me %d rank %d  clock %d  seq %d from %d phase %d reason %d', VERSION, c.sessionID, hudRank, math.floor(clock()), S.seq, S.from, S.phase, S.reason), 13, vec2(12, 26), yel)
  ui.dwriteDrawText(string.format('speed %d fast %s slow %.1f peak %d hit %s  rel %s allowed %s  %s', math.floor(c.speedKmh), tostring(watch.fast), watch.slow or 0, math.floor(watch.peak or 0),
    tostring(watch.hit ~= nil), L1.rel and math.floor(L1.rel) or '-', L1.allowed and math.floor(L1.allowed) or '-', lastError or ''), 13, vec2(12, 42), yel)
  ui.dwriteDrawText('order ' .. table.concat(S.order, ','), 13, vec2(12, 58), yel)
  local ids = {}
  for id in pairs(presence) do ids[#ids + 1] = id end
  table.sort(ids)
  ui.dwriteDrawText(string.format('penalty %s  strikes %d  drive-through due %s pending %s  server penalties %s', cfg.penalty, pen.strikes, tostring(pen.owed == true), tostring(pen.driving == true), tostring(sim.penaltiesEnabled)), 13, vec2(12, 90), yel)
  ui.dwriteDrawText(string.format('CSP %s  race %s  direct %s  sent %d got %d stale %d  script on: %s', tostring(build), tostring(sessionType()), tostring(sim.directMessagingAvailable),
    stats.sent, stats.got, stats.stale, table.concat(ids, ',')), 13, vec2(12, 74), yel)
end

function script.drawUI()
  guard(function()
    local win = ui.windowSize()
    if uiTime < 20 then ui.dwriteDrawText(string.format('%s loaded (CSP %s)', VERSION, tostring(build)), 14, vec2(12, 8), rgbm(1, 1, 1, 0.8)) end
    if lastError then
      ui.dwriteDrawText(('OVAL error: ' .. tostring(lastError)):sub(1, 200), 14, vec2(12, 48), rgbm(1, 0.3, 0.3, 1))
    end
    if not sendEvent and isActive() then
      ui.dwriteDrawText('OVAL: no online events, the flag will not reach you. Update Custom Shaders Patch.', 16, vec2(12, 30), rgbm(1, 0.3, 0.3, 1))
    end
    if debugOn then drawDebug() end
    if not isActive() then return end
    if penNote and uiTime < penNote.untilT then
      local k0, w, h = win.y / 1080, 640, 130
      local x0, y0 = win.x / 2 - w * k0 / 2, win.y * 0.3
      ui.drawRectFilled(vec2(x0, y0), vec2(x0 + w * k0, y0 + h * k0), RED, 12 * k0)
      centered(penNote.title, 40 * k0, win.x / 2, y0 + 12 * k0, rgbm(1, 1, 1, 1))
      centered(penNote.why, 22 * k0, win.x / 2, y0 + 78 * k0, rgbm(1, 1, 0.7, 1))
    end
    local debt = pen.driving and 'DRIVE-THROUGH: ENTER THE PIT LANE' or pen.owed and 'DRIVE-THROUGH DUE AFTER THE GREEN FLAG'
    if debt then
      local k1 = win.y / 1080
      ui.drawRectFilled(vec2(win.x / 2 - 300 * k1, win.y * 0.8), vec2(win.x / 2 + 300 * k1, win.y * 0.8 + 44 * k1), RED, 10 * k1)
      centered(debt, 22 * k1, win.x / 2, win.y * 0.8 + 8 * k1, rgbm(1, 1, 1, 1))
    end
    local showGreen = S.phase == GREEN and S.seq > 0 and clock() - S.tStart < 5000
    if S.phase == GREEN and not showGreen then return end

    local k, cx, y = win.y / 1080, win.x / 2, 50 * win.y / 1080
    local title, note, bg = 'GREEN FLAG', nil, GREENC
    if S.phase == ONE_TO_GO then
      title, note, bg = 'ONE TO GO', 'GREEN AT THE START/FINISH LINE', YELLOW
    elseif S.phase == CAUTION then
      title, bg = TITLES[S.reason] or 'CAUTION', YELLOW
      local who = hudCars[S.cause]
      note = S.reason == 2 and 'HOLD YOUR POSITION - GREEN AT THE LINE' or who and ac.getDriverName(who.index)
    end
    local h = 44 + (note and 24 or 0) + (showGreen and 0 or 28 + (L1.allowed and 32 or 0))
    ui.drawRectFilled(vec2(cx - 250 * k, y), vec2(cx + 250 * k, y + h * k), bg, 10 * k)
    centered(title, 30 * k, cx, y + 6 * k, BLACK)
    if showGreen then return end

    local yy = y + 44 * k
    if note then centered(note, 17 * k, cx, yy, BLACK); yy = yy + 24 * k end
    local follow = L1.ref and 'FOLLOW  ' .. ac.getDriverName(L1.ref.index) or S.phase == ONE_TO_GO and 'YOU SET THE PACE' or 'FOLLOW  PACE CAR'
    centered(follow, 18 * k, cx, yy, BLACK)
    if L1.allowed then
      local gap = L1.rel and string.format('%d m     ', math.floor(math.max(L1.rel, 0) + 0.5)) or ''
      centered(string.format('%s%d / %d km/h', gap, math.floor(ac.getCar(0).speedKmh), math.floor(L1.allowed + 0.5)),
        22 * k, cx, yy + 28 * k, (L1.speeding or L1.passing) and RED or BLACK)
    end
    local warn = L1.passing and 'DO NOT PASS - DROP BACK' or L1.speeding and 'SLOW DOWN' or L1.lagging and 'CLOSE THE GAP'
    if warn then
      ui.drawRectFilled(vec2(cx - 250 * k, y + (h + 6) * k), vec2(cx + 250 * k, y + (h + 46) * k), RED, 10 * k)
      centered(warn, 24 * k, cx, y + (h + 12) * k, rgbm(1, 1, 1, 1))
    end
  end)()
end

function script.draw3D()
  guard(drawPaceCar)()
end

pcall(function() ac.log(string.format('Oval: %s loaded, CSP %s, me=%d cars=%d raceType=%s clock=%s events=%s penalty=%s', VERSION, tostring(build), ac.getCar(0).sessionID, sim.carsCount, tostring(sessionType()), tostring(clock()), tostring(sendEvent ~= nil), cfg.penalty)) end)

-- Offline tests load this file with a fake `ac` and read the internals from here.
if OVAL_TEST then return { state = function() return S end, local1 = function() return L1 end, watch = function() return watch end, pacePos = pacePos, lastError = function() return lastError end, presence = function() return presence end, pen = function() return pen end, note = function() return penNote end, stats = function() return stats end } end
