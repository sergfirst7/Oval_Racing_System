-- Oval Racing System: virtual pace car for oval races (CSP online script).
-- One file, the same code runs on every client. State is shared with ac.OnlineEvent,
-- the pace car position is computed from the synced session clock. See README.md.

local VERSION = 'Oval 11.0'
local sim = ac.getSim()

-- Every value can be overridden in the [SCRIPT_x] section of the server's CSP extra options.
local cfgDefaults = {
  paceKmh = 140,       -- pace car speed (100 made a caution on a 4 km oval last 5.5..8 minutes)
  speedTolKmh = 8,     -- speed above the target that still counts as fine
  catchupKmh = 60,     -- extra speed allowed while closing a big gap to your place in the line
  gapSec = 0.6,        -- gap between two places in the line at the pace speed, seconds (the leader keeps it to the pace car)
  limiter = 1,         -- 1: the gas is cut above the target speed of your place (like a pit limiter), 0: off
  offPaceSec = 3,      -- a car below 70 % of the pace for this long leaves the line, it rejoins where it is when back up to speed
  paceLeadM = 300,     -- the pace car appears at least this far ahead of the race leader, and never close in front of a fast car
  autoCaution = 1,     -- 1: a wreck with another car, or a car stopped on the road, calls the caution automatically
  slowKmh = 40,        -- below this speed a car counts as stopped
  limpRatio = 0.5,     -- a car that stays below this share of its own top speed (and under 110 km/h) counts as stopped, 0 = off
  wreckDropKmh = 60,   -- losing this much speed within 0.4 s (35 within a second of a contact) is a wreck
  offRoadM = 2,        -- a car this far beyond the edge of the road endangers nobody: a crash on its own that ends there calls no caution
  stopSec = 3,         -- how long a car must stay that slow on the road to count as an incident
  raceKmh = 80,        -- a car only counts after it has been this fast since the last green
  cooldownSec = 4,     -- no automatic caution in the first seconds after a green flag
  penalty = 'slow',    -- what breaking the pace rules costs: 'off' (warnings only), 'slow' (a gas cut; never a drive-through or a black flag)
  graceSec = 10,       -- time to slow down after the pace car appears before violations count
  speedSec = 4,        -- being too fast for this long is a violation
  passSec = 1.2,       -- being ahead of the car in front for this long is a violation
  strikeGapSec = 8,    -- the same violation is counted at most once per this many seconds
  slowSec = 5,         -- length of the gas cut penalty
  rolling = 1,         -- 1: the race starts behind the pace car (rolling start); 0: standing start
  formationLaps = 1,   -- pace laps of the rolling start before the field may go green
  startLeadM = 40,     -- how far ahead of pole position the pace car starts
  cautionLaps = 2,     -- the shortest caution, pace laps: green at the line after 1.5..2.5 laps at least. The pit lane is
                       -- closed until the pace car has passed the pit entry, then open for the cars on the lead lap, from
                       -- its next pass for everybody; the last lap only comes after that (2.3..3.3 laps on an oval).
                       -- On the last lap the lucky dog and the wave-arounds go round the field, the line doubles up.
  oneToGoAt = 0.75,    -- the pace car leaves in the last quarter of a lap (track position 0..1), green at the line
  paceModel = 'content/cars/aston_vantage2018/aston_vantage2018.kn5', -- 3D model of the pace car, '' for the arrow marker only
  paceFlip = 0,        -- 1: turn the model around if it drives backwards
  paceWheelSpin = 1,   -- -1: if the wheels of the model turn backwards
  paceLightA = 'g_safety_red',    -- meshes of the model's own light bar that flash (the first one, then...
  paceLightB = 'g_safety_yellow', -- ...the second one)
  everySession = 0,    -- 1: run in every session, not only in races (testing)
  debug = 0,           -- 1: show the debug panel (chat command !ovaldebug toggles it for you)
}
local okCfg, cfgRead = pcall(ac.configValues, cfgDefaults)
local cfg = okCfg and cfgRead or cfgDefaults

local GREEN, CAUTION, ONE_TO_GO = 0, 1, 2
local NONE, ORDER_MAX, STOP_KMH, RANK_DELAY = 255, 48, 25, 0.4
local TITLES = { [0] = 'ЖОВТИЙ ПРАПОР', [1] = 'ЖОВТИЙ ПРАПОР - МАШИНА СТОЇТЬ', [2] = 'РОЛІНГ-СТАРТ', [3] = 'ЖОВТИЙ ПРАПОР - АВАРІЯ' }
local LAPPED = ' (ВІДСТАЄ НА КОЛО)'
local function lapsWord(n) -- 1 коло, 2 кола, 5 кіл
  local d, h = n % 10, n % 100
  return d == 1 and h ~= 11 and 'КОЛО' or d >= 2 and d <= 4 and (h < 12 or h > 14) and 'КОЛА' or 'КІЛ'
end

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
-- one pace car deployment: what each car said about itself (flags: 'tail' = restarts at the back, 'wave' = goes
-- round the field), who has been in the pit lane, the leader when it began, and what the local car did
local function freshDep() return { flags = {}, n = 0, pitted = {}, leader = nil, me = {} } end
local dep = freshDep()
local uiTime, lastClock, lastError, hudCars, hudRank, debugOn, greeted = 0, 0, nil, {}, 0, cfg.debug == 1, false
local infoNote, followKey = nil, nil -- yellow pop-up (whom to follow now), the car we were last told to follow
local offPace, slowT, fastT = {}, {}, {} -- cars that fell out of the line (too slow for too long), how long each one has been slow / back up to speed

local function adopt(new) -- local state survives order updates of the same deployment
  if new.phase ~= S.phase or new.tStart ~= S.tStart then L1, watch, ctl = {}, {}, {} end
  if new.phase == GREEN then offPace, slowT, fastT, followKey = {}, {}, {}, nil end
  if new.seq ~= S.seq or new.from ~= S.from then
    ac.log(string.format('Oval: state seq=%d from=%d phase=%d reason=%d cause=%d cars=%d clock=%d', new.seq, new.from, new.phase, new.reason, new.cause, #new.order, math.floor(clock())))
  end
  if new.phase == CAUTION and S.phase == GREEN or new.phase == GREEN and S.phase ~= GREEN then -- a new deployment, or the end of one: a clean sheet
    pen.strikes, pen.last, dep = 0, {}, freshDep()
  end
  S = new
  if S.phase == CAUTION and S.reason ~= 2 and not dep.leader then dep.leader = S.order[1] end
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
    ac.StructItem.key('ovalState9'),
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

-- What a car says about itself in this deployment: 1 = it restarts at the back of the line (it went into a
-- closed pit lane), 2 = it goes round the field (lucky dog, wave-around) and is out of the line until it
-- gets to the back of it. Every client keeps the list; the client that orders the line puts the cars there.
local TAIL, WAVE = 1, 2
local function onFlag(sender, d)
  if not sender or S.phase == GREEN then return end
  local id, f = sender.sessionID, dep.flags[sender.sessionID]
  if f and f.kind == d.kind then return end
  dep.n = dep.n + 1
  dep.flags[id] = { kind = d.kind, n = dep.n }
  ac.log(string.format('Oval: car %d flag %d', id, d.kind))
end
local okFlag, sendFlag, accessFlag = pcall(function() return ac.OnlineEvent({ ac.StructItem.key('ovalCar9'), kind = ac.StructItem.uint8() }, onFlag) end)
if not okFlag then ac.log('Oval: car flags unavailable: ' .. tostring(sendFlag)); sendFlag, accessFlag = nil, nil end
local flagOut
local function flagMe(kind) -- set here at once, sent to the others as soon as the rate limit lets it go
  local id = ac.getCar(0).sessionID
  if dep.flags[id] and dep.flags[id].kind == kind then return end
  dep.n = dep.n + 1
  dep.flags[id], flagOut = { kind = kind, n = dep.n }, kind
  ac.log(string.format('Oval: my flag %d', kind))
end

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

local function paceRun() return S.s0 + S.kmh / 3.6 * (clock() - S.tStart) / 1000 / trackLen() end -- laps, from the deployment point
local function pacePos() return frac(paceRun()) end
local function progress(c) return (c.lapCount or 0) + c.splinePosition end -- race distance in laps

-- "a is ahead of b in the race" for sorting: the game's race position (lapped cars included) when
-- every car has one, else laps + track position (one rule for all, a sort needs a consistent order)
local function raceOrder(cars)
  for _, c in pairs(cars) do
    if (c.racePosition or 0) <= 0 then return function(a, b) return progress(a) > progress(b) end end
  end
  return function(a, b) return a.racePosition < b.racePosition end
end

-- Metres behind the pace car along the road. Under a caution the whole field is behind it, so there
-- is no "0.95 lap ahead or 0.05 lap behind" question; the slack covers a car that edged past it.
local SLACK = 150
local function behindPace(c)
  local len = trackLen()
  return frac(pacePos() + SLACK / len - c.splinePosition) * len - SLACK
end

-- the pace car's crossings of the line so far, and the crossing that brings the green flag: the first
-- one of a rolling start; under a caution the one after 1.5..2.5 laps (cautionLaps = 2), but never before
-- the pit cycle is through: the last lap begins after the pit lane has opened for everybody (pitWindow)
local pit, goAt -- the pit lane, read from the track (below)
local function greenLine()
  local crossed = math.floor(paceRun())
  if S.reason == 2 then return crossed, math.max(1, math.ceil(S.s0 + cfg.formationLaps - 0.5)) end
  local e, first = pit and pit.inS or goAt(), S.s0 + 0.25
  local everybody = first + frac(e - first) + 1 -- the pace car's second counted pass of the pit entry
  return crossed, math.max(1, math.ceil(S.s0 + cfg.cautionLaps - 0.5), math.ceil(everybody) + 1)
end

-- ── the pit lane ─────────────────────────────────────────────────────────────
-- The track's own AI line of the pit lane (ai/pit_lane.ai: a header of 4 int32, then per point
-- x, y, z, distance along the line as floats and an int32 id), read once. The pit lane proper is
-- the longest stretch where that line runs more than 8 m outside the edge of the road.
local function i32(s, i) local a, b, c, d = s:byte(i, i + 3); local n = a + b * 256 + c * 65536 + d * 16777216; return n >= 2147483648 and n - 4294967296 or n end
local function f32(s, i) -- little-endian IEEE 754
  local a, b, c, d = s:byte(i, i + 3)
  local exp, mant = (d % 128) * 2 + math.floor(c / 128), ((c % 128) * 256 + b) * 256 + a
  local x = exp == 0 and mant * 2 ^ -149 or (1 + mant / 8388608) * 2 ^ (exp - 127)
  return d >= 128 and -x or x
end

-- pit: nil: not read yet, false: none, else { pts, a, b (pit lane proper), inI (where the pace car turns in), exitS, inS }
local function loadPit()
  pit = false
  local good, data = pcall(function() return io.load((ac.getTrackDataFilename('x'):gsub('data[/\\]x$', 'ai/pit_lane.ai'))) end)
  if not good or type(data) ~= 'string' or #data < 36 then ac.log('Oval: no pit lane line, the pace car appears on the road (' .. tostring(data) .. ')') return end
  local n = i32(data, 5)
  if n < 10 or #data < 16 + n * 20 then ac.log('Oval: pit lane line unreadable, ' .. n .. ' points') return end
  local pts, a, b, run = {}, nil, nil, nil
  for i = 1, n + 1 do
    if i <= n then
      local o = 17 + (i - 1) * 20
      local p = vec3(f32(data, o), f32(data, o + 4), f32(data, o + 8))
      local t = ac.worldCoordinateToTrack(p)
      local sides = ac.getTrackAISplineSides(t.z)
      pts[i] = { p = p, d = f32(data, o + 12), s = t.z, off = (math.abs(t.x) - 1) * (sides.x + sides.y) / 2 }
    end
    if i <= n and pts[i].off > 8 then run = run or i
    elseif run then
      if not a or i - 1 - run > b - a then a, b = run, i - 1 end
      run = nil
    end
  end
  if not a or pts[b].d - pts[a].d < 100 then ac.log('Oval: the pit lane line never leaves the road, the pace car appears on the road') return end
  local inI = a -- the pace car turns in 150 m before the pit lane proper, where the line is still on the road
  while inI > 1 and pts[a].d - pts[inI].d < 150 do inI = inI - 1 end
  pit = { pts = pts, a = a, b = b, inI = inI, exitS = pts[b].s, inS = pts[inI].s }
  ac.log(string.format('Oval: pit lane %d m long, in at %.3f, out at %.3f of the lap', math.floor(pts[b].d - pts[a].d), pit.inS, pit.exitS))
end

-- where the pace car leaves the road for good (one to go): at the pit lane, if it is in the second half of the lap
function goAt() return pit and pit.inS > 0.5 and pit.inS < 0.97 and pit.inS or cfg.oneToGoAt end

local function ahead(a, b) -- is car a ahead of car b in the race
  local pa, pb = a.racePosition or 0, b.racePosition or 0
  if pa > 0 and pb > 0 and pa ~= pb then return pa < pb end
  if S.seq == 0 and a.lapCount == 0 and b.lapCount == 0 then return frac(-a.splinePosition) < frac(-b.splinePosition) end -- on the grid: closest before the line
  return a.lapCount + a.splinePosition > b.lapCount + b.splinePosition
end

-- metres a car needs to slow down from its speed to the pace gently (3 m/s2), plus a margin
local function brakeRoom(c)
  local v, p = c.speedKmh / 3.6, cfg.paceKmh / 3.6
  return (v > p and (v * v - p * p) / 6 or 0) + 50
end

-- The pace car never pops up in front of a fast car: it appears at the first point from `from` on that has
-- every car (not in the pits) at least its braking room behind it. The pit exit is better when it is such a
-- point and not much further: there the pace car comes out of the pit lane. Nowhere clear: `from`.
local function clearPoint(cars, headS, from)
  local len = trackLen()
  local function blocker(p)
    for _, c in pairs(cars) do
      if not c.isInPitlane and frac(p - c.splinePosition) * len < brakeRoom(c) then return c end
    end
  end
  local p, moved = from, 0
  for _ = 1, 2 * ORDER_MAX do
    local c = blocker(p)
    if not c then
      if pit and not blocker(pit.exitS) and frac(pit.exitS - headS) <= frac(p - headS) + 0.25 then return pit.exitS end
      return p
    end
    local nextP = frac(c.splinePosition + (brakeRoom(c) + 1) / len)
    moved = moved + frac(nextP - p)
    if moved >= 1 then break end
    p = nextP
  end
  ac.log('Oval: no clear stretch of road for the pace car, it appears ahead of the leader')
  return from
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
  if reason ~= 2 then s0 = clearPoint(cars, head.splinePosition, s0) end
  for _, c in pairs(cars) do
    if not c.isInPitlane and not c.isRetired then list[#list + 1] = c end
  end
  if reason == 2 then -- the grid order
    table.sort(list, function(x, y) return frac(s0 - x.splinePosition) < frac(s0 - y.splinePosition) end)
  else -- the race order: lapped cars go to the back of the line, so the line says who is ahead in the race
    table.sort(list, raceOrder(list))
  end
  local order = {}
  for i = 1, math.min(#list, ORDER_MAX) do order[i] = list[i].sessionID end
  commit(CAUTION, reason, cause, clock(), s0, order)
end

local function release() commit(GREEN, 0, NONE, clock(), 0, {}) end

-- ── penalties ────────────────────────────────────────────────────────────────
-- Every client judges its own car. Violations are counted per pace car deployment: the first one
-- is a warning, from the second on the gas is cut. Passing the pace car and jumping the restart count
-- double. Nothing the script does ends a race: no drive-through, no black flag.
local function setPenalty(kind, param)
  local good, err = pcall(function() physics.setCarPenalty(ac.PenaltyType[kind], param) end)
  if not good then ac.log('Oval: penalty ' .. kind .. ' could not be applied: ' .. tostring(err)) end
  return good
end

-- The gas cut is done by the script itself, not with the game's SlowDown penalty: that one adds
-- penalty time (log: `Adding penalty PT`) which was never served, and at the next lap completed
-- the car got the black flag and ended up in the pits.
local function cutGas(seconds)
  local good, err = pcall(function() physics.forceUserThrottleFor(seconds, 0) end)
  if not good then ac.log('Oval: gas cut could not be applied: ' .. tostring(err)) end
  return good
end

local function penalize(why, weight)
  if uiTime - (pen.last[why] or -100) < cfg.strikeGapSec then return end -- the same offence at most once per gap
  pen.last[why], pen.strikes = uiTime, pen.strikes + weight
  local level, title, applied = pen.strikes, 'ПОПЕРЕДЖЕННЯ', true
  if cfg.penalty ~= 'off' and level >= 2 then
    if uiTime - (pen.slowAt or -100) < cfg.slowSec + 3 then
      title = 'ВІДСІЧКА ГАЗУ (ВЖЕ ДІЄ)' -- a running gas cut is not extended
    else
      title = 'ВІДСІЧКА ГАЗУ ' .. cfg.slowSec .. ' С'
      applied = cutGas(cfg.slowSec)
      if applied then pen.slowAt = uiTime end
    end
  end
  if not applied then title = title .. ' (НЕ ЗАСТОСОВАНО)' end
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
    penalize(S.phase == ONE_TO_GO and 'Завелика швидкість перед зеленим прапором' or 'Перевищення швидкості за safety car', 1)
  end
  if L1.passT >= cfg.passSec then
    L1.passT = 0
    local pace, restart = L1.key == 'pace', S.phase == ONE_TO_GO
    penalize(pace and 'Обгін safety car' or restart and 'Фальстарт на рестарті' or 'Обгін під жовтим прапором', (pace or restart) and 2 or 1)
  end
end

-- What the game itself does with penalties goes to the log (type / parameter / lap / pit lane). A black
-- flag (a disqualification) is taken back at once, whatever gave it: in an oval race the worst is a gas
-- cut. Tried again after a few seconds if the game keeps it, three times per black flag.
local gamePen, blackAt, blackTries = '', -100, 0
local function watchGamePenalty(me)
  local good, kind, param = pcall(function() return me.currentPenaltyType, me.currentPenaltyParameter end) -- fields of the car, not of ac.getSim()
  if not good then return end
  local key = string.format('%s/%s lap %s pit %s', tostring(kind), tostring(param), tostring(me.lapCount), tostring(me.isInPitlane))
  if key ~= gamePen then gamePen = key; ac.log('Oval: game penalty ' .. key) end
  local black = ac.PenaltyType and ac.PenaltyType.BlackFlag
  if not black or kind ~= black then blackTries = 0 return end
  if uiTime - blackAt < 3 or blackTries > 3 then return end
  blackAt, blackTries = uiTime, blackTries + 1
  local applied = blackTries <= 3 and setPenalty('ReleaseBlackFlag')
  penNote = applied and { title = 'ЧОРНИЙ ПРАПОР ЗНЯТО', why = 'Дискваліфікації на овалі немає', untilT = uiTime + 7 }
    or { title = 'ЧОРНИЙ ПРАПОР НЕ ЗНЯТО', why = 'Гра не дає його зняти, клич адміна', untilT = uiTime + 7 }
  pcall(ac.setMessage, penNote.title, penNote.why, 'illegal', 7)
  ac.log(string.format('Oval: black flag, release try %d (applied=%s)', blackTries, tostring(applied)))
end

-- ── rules for the local car ──────────────────────────────────────────────────
-- Like the formation lap of ACC: every place in the line is a point that moves with the pace car
-- (single file under a caution, two abreast after the grid). The target speed brings you to your
-- point, not to the car ahead, so one car that slows down does not slow the whole field down.
local function offPaceKmh() return 0.7 * cfg.paceKmh end
local function gapM() return cfg.gapSec * cfg.paceKmh / 3.6 end
local rowGap = { t = nil, m = 16 } -- metres between two rows of the rolling start, measured on the grid

-- the last lap of a caution: from the pace car's last crossing of the line before the green flag
local function finalLap()
  if S.phase == ONE_TO_GO then return true end
  if S.phase ~= CAUTION or S.reason == 2 then return false end
  local crossed, at = greenLine()
  return crossed >= at - 1
end
local function doubleFile() return S.reason == 2 or finalLap() end -- two abreast: the start, and every restart

local function slotDistance(idx)
  if S.reason == 2 then return cfg.startLeadM + math.floor((idx - 1) / 2) * rowGap.m end
  if doubleFile() then return (1 + math.floor((idx - 1) / 2)) * gapM() end
  return idx * gapM()
end

-- The pit lane under a caution: closed until the pace car has passed the pit entry (a quarter of a lap
-- after it appeared at the earliest), then open for the cars on the lead lap, from its next pass for everybody.
local function pitWindow() -- 0 closed, 1 lead lap only, 2 open
  if S.phase ~= CAUTION or S.reason == 2 then return 2 end
  local e = pit and pit.inS or goAt()
  return clamp(math.floor(paceRun() - e) - math.floor(S.s0 + 0.25 - e), 0, 2)
end

local function lapsDown(c, cars)
  local lead = 0
  for _, o in pairs(cars) do lead = math.max(lead, progress(o)) end
  return math.floor(lead - progress(c))
end

local function localCheck(cars, dt)
  local me = ac.getCar(0)
  if S.phase == GREEN or me.isInPitlane then L1 = {} return end
  local at = {}
  for i, id in ipairs(S.order) do at[id] = i end
  local idx = at[me.sessionID]
  if not idx then L1 = { out = true } return end -- out of the line: too slow (rejoins when back up to speed), or going round it

  local launching = S.reason == 2 and clock() - S.tStart < 15000 -- cars still accelerate from the grid
  if S.reason == 2 and S.phase == CAUTION and rowGap.t ~= S.tStart then
    local first, last, rows = cars[S.order[1]], cars[S.order[#S.order]], math.ceil(#S.order / 2) - 1
    rowGap.t, rowGap.m = S.tStart, 16
    if first and last and rows > 0 and clock() - S.tStart < 3000 then rowGap.m = clamp((behindPace(last) - behindPace(first)) / rows, 8, 40) end
  end
  local ref
  for j = idx - 1, 1, -1 do -- nearest car ahead in the line that keeps the pace (a slow one may be passed)
    local c = cars[S.order[j]]
    if c and not c.isInPitlane and (c.speedKmh > offPaceKmh() or launching) then ref = c break end
  end
  local key = ref and ref.sessionID or 'pace'
  if L1.key ~= key then L1 = { key = key } end
  local myD = behindPace(me)
  local rel = myD - (ref and behindPace(ref) or 0) -- > 0: the car (or pace car) we follow is ahead
  if L1.rel and math.abs(rel - L1.rel) > 200 then L1.seenAhead = nil end -- a jump: it went round the pace car, it did not pass us
  if rel > 0 then L1.seenAhead = true end -- only a car we have been behind can be passed

  local double = doubleFile()
  local mate = double and idx % 2 == 0 and S.order[idx - 1] or nil -- the row mate on the start and the restart
  local mateBehind = double and idx % 2 == 1 and S.order[idx + 1] or nil -- beside us, a few metres ahead is no car to pass
  -- within 150 m: the nearest car ahead of us on the road and in the line that we must not run into, the
  -- nearest one to pass (behind us in the line, or too slow: we go round it, braking for it is what makes
  -- the whole field pile up) and the nearest one to let by (ahead of us in the line but behind on the road)
  local block, passIt, letIt, dBlock, dPass, dLet = nil, nil, nil, 150, 150, 150
  for id, c in pairs(cars) do
    local i = at[id]
    if i and id ~= me.sessionID and not c.isInPitlane then
      local d = myD - behindPace(c) -- > 0: it is ahead of us on the road
      local slow = not launching and c.speedKmh < offPaceKmh()
      if i < idx and not slow and d > 0 and d < dBlock and id ~= mate then block, dBlock = c, d end
      if (i > idx or slow) and d > 0 and d < dPass and not (id == mateBehind and d < 12) then passIt, dPass = c, d end
      if i < idx and d < 0 and -d < dLet and (c ~= ref or not L1.seenAhead) then letIt, dLet = c, -d end
    end
  end

  local gap, speed = gapM(), me.speedKmh
  local err = myD - slotDistance(idx) -- > 0: behind our place
  local target = cfg.paceKmh + (err > 0 and clamp(err / (4 * gap), 0, 1) * cfg.catchupKmh or clamp(err / gap, -1, 0) * 20)
  if block then -- never into the car ahead: slow down early and gently (3 m/s2), not at the last moment
    local keep = S.reason == 2 and 0.6 * rowGap.m or 0.75 * gap
    target = math.min(target, block.speedKmh + 3.6 * math.sqrt(6 * math.max(0, dBlock - keep)))
  end
  local tol = double and -12 or -3 -- two abreast, a few metres either way are fine
  local leaderGo = not ref and S.phase == ONE_TO_GO -- the pace car is gone, the leader holds the pace to the line

  L1.ref, L1.place, L1.count, L1.rel, L1.err, L1.beside = ref, idx, #S.order, rel, err, ref ~= nil and ref.sessionID == mate
  L1.lane = double and (idx % 2 == 1 and 'in' or 'out') or nil
  L1.target, L1.allowed = target, target + cfg.speedTolKmh
  L1.speeding = speed > L1.allowed
  L1.passing = not leaderGo and L1.seenAhead == true and rel < tol
  L1.passIt, L1.letIt = passIt, not L1.passing and letIt or nil
  L1.tooClose = block ~= nil and S.reason ~= 2 and dBlock < 0.4 * gap
  L1.lagging = not launching and err > 2 * gap and speed < target - 15
  L1.down, L1.refDown = lapsDown(me, cars), ref and lapsDown(ref, cars) or 0
  if key ~= followKey then -- say it loud whenever the car to follow changes
    followKey = key
    local name = ref and ac.getDriverName(ref.index) .. (L1.refDown > 0 and LAPPED or '')
    infoNote = { title = name and 'ЇДЬ ЗА ' .. name or leaderGo and 'ТИ ВЕДЕШ КОЛОНУ' or 'ЇДЬ ЗА SAFETY CAR', why = string.format('ТВОЄ МІСЦЕ В КОЛОНІ: %d З %d', idx, #S.order), place = idx, count = #S.order, untilT = uiTime + 6 }
  end
  judge(dt)
end

-- Who has been in the pit lane in this deployment (the wave-around needs to know whether the leader came in),
-- and the pit entry of the local car: going in while the pit lane is closed for it costs the place in the
-- line (it restarts at the back), nothing else. Already in the pit lane when the caution came: no fault.
local function watchPits(me, cars)
  if S.phase == GREEN or S.reason == 2 then return end
  for id, c in pairs(cars) do if c.isInPitlane then dep.pitted[id] = true end end
  local was = dep.me.inPit
  dep.me.inPit = me.isInPitlane
  if was ~= false or not me.isInPitlane then return end
  local w = pitWindow()
  if w == 0 or (w == 1 and lapsDown(me, cars) >= 1) then
    flagMe(TAIL)
    penNote = { title = 'ПІТ-ЛЕЙН ЗАКРИТО', why = 'Рестарт з кінця колони', untilT = uiTime + 7 }
    pcall(ac.setMessage, penNote.title, penNote.why, 'illegal', 7)
    ac.log(string.format('Oval: into a closed pit lane (window %d), to the back of the line', w))
  end
end

-- The lucky dog (the first car a lap down, unless it caused the caution) and the wave-arounds (cars a lap
-- or more down that stay out while the leader pits) go round the field: past the line and the pace car, a
-- lap at speed, to the back of the line. That gives them their lap back. They go about two laps before the
-- green flag: the lucky dog when the pit lane opens for the lead lap, a wave-around when the leader comes in.
-- One lap is too short: to gain a lap in one pace lap a car needs twice the pace (280 km/h behind a pace
-- car at 140). A car that goes into the pit lane after all gets no lap back and lines up by the race order.
local function watchWave(me, cars)
  local m = dep.me
  if S.phase ~= CAUTION or S.reason == 2 then return end
  if m.wave and not m.joined and me.isInPitlane then
    ac.log('Oval: ' .. m.wave .. ' called off, the car went into the pit lane')
    m.wave, m.off = nil, true
    local mine = dep.flags[me.sessionID]
    if mine and mine.kind == WAVE then flagMe(0) end -- a closed pit lane (TAIL, just set) stays as it is
  end
  if m.wave or m.off or me.isInPitlane or finalLap() or pitWindow() < 1 then return end
  local down = lapsDown(me, cars)
  if down < 1 then return end
  if m.luckyJudged == nil then -- once, when the pit lane opens: the line is the race order, a lapped car ahead of me is the lucky dog
    m.luckyJudged = me.sessionID ~= S.cause
    for _, id in ipairs(S.order) do
      if id == me.sessionID then break end
      if cars[id] and lapsDown(cars[id], cars) >= 1 then m.luckyJudged = false break end
    end
  end
  local wave = not dep.pitted[me.sessionID] and dep.leader ~= nil and dep.pitted[dep.leader] == true
  if not m.luckyJudged and not wave then return end
  m.wave, m.down = m.luckyJudged and 'LUCKY DOG' or 'WAVE AROUND', down
  flagMe(WAVE)
  infoNote = { title = m.wave, why = 'ОБ\'ЇДЬ КОЛОНУ І SAFETY CAR, НАЗДОЖЕНИ КОЛОНУ ЗЗАДУ', untilT = uiTime + 8 }
  ac.log('Oval: ' .. m.wave)
end

local function watchJoin(me, cars)
  local m = dep.me
  if S.phase == GREEN or S.reason == 2 then return end
  if m.wave and not m.joined then -- past the leader (the lap is back), then up to the last car of the line from behind
    local d, last = behindPace(me), cars[S.order[#S.order]]
    if lapsDown(me, cars) < m.down and last and d > behindPace(last) and d - behindPace(last) < 100 then
      m.joined = true
      flagMe(TAIL)
    end
  end
end

-- The limiter cuts the gas while the car is faster than the target of its place (works on the
-- script's own throttle override, like the gas cut penalty). A running penalty gas cut is left alone.
local limitLogged = false
local function limit(me)
  if cfg.limiter ~= 1 or not L1.target or me.isInPitlane or uiTime - (pen.slowAt or -100) < cfg.slowSec then return end
  L1.limiting = me.speedKmh > L1.target + 2
  if not L1.limiting then return end
  local good, err = pcall(function() physics.forceUserThrottleFor(0.15, 0) end)
  if not good and not limitLogged then limitLogged = true; ac.log('Oval: limiter unavailable: ' .. tostring(err)) end
end

-- ── incidents: every client watches its own car ──────────────────────────────
-- Own data is the only reliable data. A wreck is a sudden loss of speed (with or without a contact
-- event), a car that stays slow on the road for stopSec is stopped: standing, or limping below limpRatio
-- of the speed it was doing. A wreck with another car calls the caution at once. A crash on its own does
-- not: only if the car then stays slow or stands on the road, where others come. Remote cars are not
-- watched: their data is late and the owner knows best.
local okHit, errHit = pcall(ac.onCarCollision, 0, function()
  lastContact = uiTime
  local me = ac.getCar(0)
  local withCar = me.collidedWith ~= 0 -- 0: a wall or the track; unknown (old CSP): counted as a car, as before
  if withCar then watch.carHit = uiTime end
  local peak = watch.peak or 0
  if uiTime - (watch.hitLog or -5) > 2 then
    watch.hitLog = uiTime
    ac.log(string.format('Oval: contact with %s, speed=%d peak=%d', withCar and 'a car' or 'the track', math.floor(me.speedKmh), math.floor(peak)))
  end
  if peak > 100 then watch.hit = { t = uiTime, peak = peak } end
end)
if not okHit then ac.log('Oval: contact events unavailable: ' .. tostring(errHit)) end

-- metres the car is beyond the edge of the road (0 on the road); unknown: on the road
local function offRoad(c)
  local good, m = pcall(function()
    local t = ac.worldCoordinateToTrack(c.position)
    local sides = ac.getTrackAISplineSides(t.z)
    return math.max(0, (math.abs(t.x) - 1) * (t.x < 0 and sides.x or sides.y))
  end)
  return good and m or 0
end

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
  if not watch.solo and (lost(0.4) >= cfg.wreckDropKmh or (recent and lost(1) >= 35) or (hit and speed < hit.peak * 0.35)) then
    local withCar = uiTime - (watch.carHit or -100) < 3
    ac.log(string.format('Oval: wreck, speed=%d lost=%d contact=%s with a car=%s', math.floor(speed), math.floor(lost(1)), tostring(hit ~= nil), tostring(withCar)))
    if withCar then return deploy(3, me.sessionID) end
    watch.solo = uiTime -- on its own: a caution only if it stays on the road slow (below)
  end
  if watch.solo and uiTime - watch.solo > 10 and speed > cfg.raceKmh then watch.solo = nil end -- back racing
  local off = offRoad(me)
  if off >= cfg.offRoadM then watch.offAt = uiTime end
  -- off the road a car endangers nobody; back on it after a trip off, it gets a few seconds to get up to
  -- speed before slow counts (standing still always counts)
  local rejoining = uiTime - (watch.offAt or -100) < 8
  local slow = off < cfg.offRoadM and (speed < cfg.slowKmh or (not rejoining and cfg.limpRatio > 0 and speed < cfg.limpRatio * watch.top and speed < 110))
  watch.slow = slow and (watch.slow or 0) + dt or 0
  if watch.slow >= cfg.stopSec then
    ac.log(string.format('Oval: stopped car on the road, speed=%d top=%d off=%.1f m after a crash on its own=%s', math.floor(speed), math.floor(watch.top), off, tostring(watch.solo ~= nil)))
    deploy(1, me.sessionID)
  end
end

-- ── restart handling: every client computes it, the lowest session ID acts first ─────────
-- A client only acts after `rank * RANK_DELAY` seconds without a newer state, so a car whose
-- driver has no script cannot stall the flow: the next one takes over.
local pend, lastLeader = { key = nil }, nil
local start = {}
local function due(key, rank)
  if pend.key ~= key or pend.seq ~= S.seq or uiTime - pend.last > 0.5 then pend = { key = key, seq = S.seq, at = uiTime } end
  pend.last = uiTime
  return uiTime - pend.at >= rank * RANK_DELAY
end

local function moving(c) return not c.isInPitlane and not c.isRetired and c.speedKmh > STOP_KMH end

-- A car below 70 % of the pace for offPaceSec (stopped, wrecked, limping) leaves the line, so
-- the cars behind it pass it and keep the pace. Back up to speed for offPaceSec, it rejoins where
-- it is (not at once: a car going just about that speed would jump in and out of the line).
local function watchPace(cars, dt)
  local launching = S.reason == 2 and clock() - S.tStart < 15000
  for id, c in pairs(cars) do
    local slow = not launching and not c.isInPitlane and not c.isRetired and c.speedKmh < offPaceKmh()
    slowT[id] = slow and (slowT[id] or 0) + dt or 0
    fastT[id] = not slow and (fastT[id] or 0) + dt or 0
    if slowT[id] >= cfg.offPaceSec then offPace[id] = true elseif fastT[id] >= cfg.offPaceSec then offPace[id] = nil end
  end
end

-- Cars in the pits or out of the line drop out of the order; cars that come back (or join) take
-- their place by the race order (by the road on the rolling start), so nobody gains places by
-- pitting or by stopping. Cars sent to the back (a closed pit lane, back from going round the field)
-- line up at the end in the order they were sent there; a car going round the field is not in the line.
-- nil: nothing changed.
local function desiredOrder(cars)
  local order, seen, tail = {}, {}, {}
  local function inLine(id, c) return not c.isInPitlane and not c.isRetired and not offPace[id] and not (dep.flags[id] and dep.flags[id].kind == WAVE) end
  local function atTail(id) return dep.flags[id] and dep.flags[id].kind == TAIL end
  local before = S.reason == 2 and function(a, b) return behindPace(a) < behindPace(b) end or raceOrder(cars)
  for _, id in ipairs(S.order) do
    local c = cars[id]
    if c and inLine(id, c) and not atTail(id) then order[#order + 1] = id; seen[id] = true end
  end
  for id, c in pairs(cars) do
    if inLine(id, c) and atTail(id) then tail[#tail + 1] = id
    elseif not seen[id] and inLine(id, c) then
      local at = #order + 1
      for i, other in ipairs(order) do if before(c, cars[other]) then at = i break end end
      table.insert(order, at, id)
    end
  end
  table.sort(tail, function(a, b) return dep.flags[a].n < dep.flags[b].n end)
  for _, id in ipairs(tail) do order[#order + 1] = id end
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

-- The line is put in order by one client only: the lowest session ID among the clients that run the
-- script. Two clients that see a slow car a little differently would otherwise take turns changing it
-- (seen in a race: 25 orders in 15 s, the places and "follow" on everybody's screen jumping).
local function orderer(cars, me)
  for id in pairs(presence) do if id < me.sessionID and cars[id] then return false end end
  return true
end

local function control(cars, dt, rank)
  if S.phase == GREEN then lastLeader = nil return end
  watchPace(cars, dt)
  if not cars[S.from] then -- the sender is gone: say it again, late joiners need it
    if due('announce', rank) then commit(S.phase, S.reason, S.cause, S.tStart, S.s0, S.order) end
    return
  end
  local order = orderer(cars, ac.getCar(0)) and desiredOrder(cars)
  if order and due('order', 0) then return commit(S.phase, S.reason, S.cause, S.tStart, S.s0, order) end

  local len = trackLen()
  if S.phase == CAUTION then
    -- a fixed length: neither a car standing on track nor a gap in the line makes the caution longer
    local crossed, greenAt = greenLine()
    local pos = pacePos()
    if crossed >= greenAt - 1 and pos >= goAt() and due('one', rank) then -- the pace car pulls off into the pit lane before the line
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
local function reset()
  S, L1, watch, ctl, start, greeted, pen, penNote = freshState(), {}, {}, {}, {}, false, { strikes = 0, last = {} }, nil
  infoNote, followKey, offPace, slowT, fastT, dep, flagOut = nil, nil, {}, {}, {}, freshDep(), nil
end
try('session start events', ac.onSessionStart, reset)

-- Chat commands: !ovaldebug and !hud (anyone, only for yourself), !yellow / !green (admin)
local hudEdit = false -- the boxes can be dragged with the mouse
local function command(msg)
  local cmd = msg:lower():match('^%s*!(%a+)%s*$')
  if cmd == 'ovaldebug' then debugOn = not debugOn return true end
  if cmd == 'hud' then hudEdit = not hudEdit return true end
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
      -- wheels (the usual node names of AC cars) turn around their own axle; the blurred rims show at speed
      car3d.wheels, car3d.rims, car3d.blurs, car3d.spin = {}, {}, {}, 0
      for _, w in ipairs({ 'LF', 'RF', 'LR', 'RR' }) do
        local node = model:findNodes('WHEEL_' .. w)
        local raw = node:size() > 0 and node:getTransformationRaw()
        if raw then car3d.wheels[#car3d.wheels + 1] = { raw = raw, base = raw:clone(), sign = raw.side.x < 0 and -1 or 1 } end -- right wheels are mirrored
        car3d.rims[#car3d.rims + 1], car3d.blurs[#car3d.blurs + 1] = model:findAny('RIM_' .. w), model:findAny('RIM_BLUR_' .. w)
      end
      car3d.root, car3d.state = root, 'ready'
      ac.log('Oval: pace car model loaded: ' .. cfg.paceModel .. ', wheels ' .. #car3d.wheels)
    end)()
  end)
end

-- position on the road and the direction of travel
local function roadFrame(s)
  local p = ac.trackCoordinateToWorld(vec3(0, 0, s))
  return p, (ac.trackCoordinateToWorld(vec3(0, 0, frac(s + 4 / trackLen()))) - p):normalize()
end

-- a point of the pit lane line `dist` metres along it, and the direction there
local function pitPoint(dist)
  local pts, lo = pit.pts, 1
  local hi = #pts
  while hi - lo > 1 do
    local m = math.floor((lo + hi) / 2)
    if pts[m].d <= dist then lo = m else hi = m end
  end
  local a, b = pts[lo], pts[hi]
  local k = clamp((dist - a.d) / math.max(b.d - a.d, 0.001), 0, 1)
  return a.p + (b.p - a.p) * k, (b.p - a.p):normalize()
end

-- Where the pace car is drawn. The rules only know its synced point on the road; the picture adds
-- the pit lane. Out (when it starts at the pit exit): it comes out of the end of the pit lane at full
-- pace and joins the road. In (one to go): from the turn-in point it slows down to a stop in the middle
-- of the pit lane. 2.5 s of lane change join the two lines. Anywhere else it is simply on the road.
-- Returns the position, the direction, the speed in m/s and "still in the pits" (nothing: not shown).
local BLEND = 2.5
local function paceVisual()
  local v, len = S.kmh / 3.6, trackLen()
  local p, fwd = roadFrame(pacePos())
  if S.phase == CAUTION then
    -- the rolling start begins on the grid; a start away from the pit exit is on the road (s0 came as a float)
    if not pit or S.reason == 2 or math.abs(frac(S.s0 - pit.exitS + 0.5) - 0.5) > 1e-5 then return p, fwd, v, false end
    local pts = pit.pts
    local out = (pts[pit.b].d - pts[pit.a].d) / 2
    local left = (S.tStart + (frac(pit.exitS - S.s0 + 0.5) - 0.5) * len / v * 1000 - clock()) / 1000 -- seconds to the pit exit (about 0)
    if left > 0 then
      local T = 2 * out / v -- from a stop to the pace over the second half of the pit lane
      local tau = math.min(left, T)
      local q, dir = pitPoint(pts[pit.b].d - v * tau + v / T / 2 * tau * tau)
      return q, dir, v * (1 - tau / T), true
    end
    if -left >= BLEND then return p, fwd, v, false end
    local q, dir = pitPoint(pts[pit.b].d - v * left)
    local k = -left / BLEND
    return q + (p - q) * k, (dir + (fwd - dir) * k):normalize(), v, false
  end
  if S.phase ~= ONE_TO_GO or not pit or goAt() ~= pit.inS then return end
  local pts, since = pit.pts, (clock() - S.tStart) / 1000
  local T = 2 * ((pts[pit.a].d + pts[pit.b].d) / 2 - pts[pit.inI].d) / v
  if since >= T then return end
  local late = frac(S.s0 - pit.inS) -- the flag came a little after the turn-in point
  local q, dir = pitPoint(pts[pit.inI].d + (late < 0.5 and late * len or 0) + v * since - v / T / 2 * since * since)
  local k = math.min(since / BLEND, 1)
  return p + (q - p) * k, (fwd + (dir - fwd) * k):normalize(), v * (1 - since / T), k >= 1
end

-- The height of a line is not always the height of the asphalt (banking!): ask the physics of the
-- track for the real surface under that point, the line is the fallback.
local function grounded(p, fwd)
  local up, hit, normal = vec3(0, 1, 0), vec3(0, 0, 0), vec3(0, 0, 0)
  local ok, dist = pcall(function() return physics.raycastTrack(p + vec3(0, 4, 0), vec3(0, -1, 0), 12, hit, normal) end)
  if ok and dist and dist > 0 then
    p = hit
    if normal.y > 0.5 then up = normal:clone():normalize() end
  elseif not car3d.rayLogged then
    car3d.rayLogged = true
    ac.log('Oval: no ground ray (' .. tostring(dist) .. '), the pace car follows the height of the line')
  end
  return p, up
end

local function setLens(lens, key, on, color)
  if car3d[key] == on then return end
  car3d[key] = on
  lens:setMaterialProperty('ksEmissive', on and color or DARK)
end

local WHEEL_R = 0.34 -- metres, a sports car wheel
local function updatePaceCar(dt)
  local p, fwd, speed
  if isActive() and S.phase ~= GREEN then p, fwd, speed = paceVisual() end
  local show = p ~= nil
  car3d.frame = show and { p = p, up = vec3(0, 1, 0) } or nil
  if show and car3d.state == 'idle' and cfg.paceModel ~= '' then loadPaceCar() end
  if car3d.state ~= 'ready' then return end
  if car3d.visible ~= show then car3d.visible = show; car3d.root:setVisible(show) end

  local onA, onB = false, false
  if show then
    local up
    p, up = grounded(p, fwd)
    local mf = cfg.paceFlip == 1 and -1 or 1 -- the model's forward relative to the travel direction
    car3d.root:setPosition(p):setOrientation(fwd * mf, up)
    car3d.frame.p, car3d.frame.up = p, up
    car3d.spin = (car3d.spin + speed * dt / WHEEL_R) % (2 * math.pi)
    for _, w in ipairs(car3d.wheels) do w.raw:set(mat4x4.rotation(car3d.spin * w.sign * mf * cfg.paceWheelSpin, vec3(1, 0, 0)):mul(w.base)) end
    local blur = speed > 15
    if car3d.blur ~= blur then
      car3d.blur = blur
      for i = 1, #car3d.rims do car3d.rims[i]:setVisible(not blur); car3d.blurs[i]:setVisible(blur) end
    end
    local step = math.floor(uiTime * 10) % 6 -- double flash: the first lens, then the second, dark in between
    onA, onB = step == 0 or step == 2, step == 3 or step == 5
    local bar = p + up * BAR[2] + fwd * (BAR[3] * mf)
    car3d.lights[1].position, car3d.lights[2].position = bar, bar
  end
  setLens(car3d.lensA, 'onA', onA, RED_ON)
  setLens(car3d.lensB, 'onB', onB, AMBER_ON)
  car3d.lights[1].color = onA and rgb(9, 0.4, 0) or DARK
  car3d.lights[2].color = onB and rgb(9, 4.5, 0) or DARK
end

local function drawPaceCar()
  local f = car3d.frame
  if f and car3d.state ~= 'ready' then -- no model: an arrow and a label
    render.debugArrow(f.p + vec3(0, 14, 0), f.p + vec3(0, 2, 0), 1.5, YELLOW)
    render.debugText(f.p + vec3(0, 16, 0), 'SAFETY CAR', YELLOW, 2)
  elseif f then
    render.debugText(f.p + f.up * 3.6, 'SAFETY CAR', YELLOW, 1.5)
  end
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
    if flagOut and sendFlag and not outbox then -- the state goes first, the flag in a later frame (rate limit)
      accessFlag().kind = flagOut
      if sendFlag(nil, false) then flagOut = nil end
    end
    if not isActive() then if S.seq > 0 then reset() end return end
    if pit == nil then loadPit() end

    local cars, me = activeCars(), ac.getCar(0)
    -- a client that has left is no script user any more: its session ID may go to a player without the script
    for id in pairs(presence) do if not cars[id] then presence[id] = nil end end
    local rank = 0
    for id in pairs(cars) do if id < me.sessionID then rank = rank + 1 end end
    hudCars, hudRank = cars, rank
    if S.phase == GREEN then startRace(cars, rank, now); watchSelf(dt, now) end
    control(cars, dt, rank)
    watchPits(me, cars)
    watchWave(me, cars)
    watchJoin(me, cars)
    localCheck(cars, dt)
    limit(me)
    watchGamePenalty(me)
    updatePaceCar(dt)
  end)()
end

-- ── HUD ──────────────────────────────────────────────────────────────────────
local GREENC, RED, BLACK, BLUE = rgbm(0.1, 0.75, 0.2, 0.95), rgbm(0.9, 0.1, 0.1, 0.95), rgbm(0, 0, 0, 1), rgbm(0.1, 0.35, 0.9, 0.95)

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
  local flags = {}
  for id, f in pairs(dep.flags) do flags[#flags + 1] = id .. ':' .. f.kind end
  ui.dwriteDrawText(string.format('penalty %s  strikes %d  pit window %d  flags %s  wave %s  server penalties %s', cfg.penalty, pen.strikes, S.phase == GREEN and -1 or pitWindow(), table.concat(flags, ' '), tostring(dep.me.wave), tostring(sim.penaltiesEnabled)), 13, vec2(12, 90), yel)
  ui.dwriteDrawText(string.format('CSP %s  race %s  direct %s  sent %d got %d stale %d  script on: %s', tostring(build), tostring(sessionType()), tostring(sim.directMessagingAvailable),
    stats.sent, stats.got, stats.stale, table.concat(ids, ',')), 13, vec2(12, 74), yel)
end

-- Where the boxes stand (share of the screen: middle of a box, its top). The player drags them with the mouse
-- after !hud or from the online extras of the chat app; ac.storage keeps them on his PC.
local HUD_DEFAULT = { topX = 0.5, topY = 50 / 1080, noteX = 0.5, noteY = 0.3 }
local okHud, hud = pcall(ac.storage, HUD_DEFAULT, 'ovalHud.')
if not okHud or type(hud) ~= 'table' then hud = {}; for key, v in pairs(HUD_DEFAULT) do hud[key] = v end end
local toolSeen, drag, boxes = -100, nil, {}
try('online extras', function()
  ui.registerOnlineExtra(ui.Icons.Settings, 'Плашки овалу', nil, function()
    toolSeen = uiTime
    ui.text('Перетягни плашки мишею.')
    if ui.button('Скинути') then for key, v in pairs(HUD_DEFAULT) do hud[key] = v end end
  end, nil, ui.OnlineExtraFlags.Tool)
end)
local function editing() return hudEdit or uiTime - toolSeen < 0.5 end

-- a box that can be dragged: where it is this frame, and a frame around it while the player arranges them
local function box(key, x1, y1, x2, y2, edit)
  boxes[key] = { x1, y1, x2, y2 }
  if edit then ui.drawRect(vec2(x1 - 4, y1 - 4), vec2(x2 + 4, y2 + 4), rgbm(1, 1, 1, 1), 12, nil, 3) end
end

local function dragBoxes(win)
  local m = ui.mousePos()
  if ui.mouseClicked(0) then
    drag = nil
    for key, b in pairs(boxes) do if m.x >= b[1] and m.x <= b[3] and m.y >= b[2] and m.y <= b[4] then drag = key end end
  end
  if not ui.mouseDown(0) then drag = nil end
  if drag then
    local d = ui.mouseDelta()
    hud[drag .. 'X'] = clamp(hud[drag .. 'X'] + d.x / win.x, 0, 1)
    hud[drag .. 'Y'] = clamp(hud[drag .. 'Y'] + d.y / win.y, 0, 0.95)
  end
  ui.dwriteDrawText('ПЛАШКИ: ПЕРЕТЯГНИ МИШЕЮ.  ГОТОВО: !hud АБО ЗАКРИЙ ВІКНО', 20, vec2(12, win.y - 44), rgbm(1, 1, 1, 1))
end

-- A line is a list of parts { text, size[, color] } side by side: the numbers and the names that matter are bigger.
local function widthOf(parts, k)
  local w = 0
  for _, p in ipairs(parts) do w = w + ui.measureDWriteText(p[1], p[2] * k).x end
  return w
end

-- half the width of a box: at least `min`, wider when a line needs it (a Ukrainian line or a long name never sticks out)
local function halfW(k, min, list)
  local w = min * k
  for _, parts in ipairs(list) do w = math.max(w, widthOf(parts, k) + 40 * k) end
  return w / 2
end

local function lineHeight(parts)
  local top = 0
  for _, p in ipairs(parts) do top = math.max(top, p[2]) end
  return top
end

-- draws a line centred on cx, the bottoms of the parts in line
local function rich(parts, k, cx, y, color)
  local x, top = cx - widthOf(parts, k) / 2, lineHeight(parts)
  for _, p in ipairs(parts) do
    ui.dwriteDrawText(p[1], p[2] * k, vec2(x, y + (top - p[2]) * k * 0.8), p[3] or color)
    x = x + ui.measureDWriteText(p[1], p[2] * k).x
  end
end

local DEMO_NOTE = { title = 'ЇДЬ ЗА Ivanov', place = 3, count = 8 }

function script.drawUI()
  guard(function()
    local win = ui.windowSize()
    local edit = editing()
    if edit then dragBoxes(win) end
    boxes = {}
    if uiTime < 20 then ui.dwriteDrawText(string.format('%s завантажено (CSP %s)', VERSION, tostring(build)), 14, vec2(12, 8), rgbm(1, 1, 1, 0.8)) end
    if lastError then
      ui.dwriteDrawText(('OVAL помилка: ' .. tostring(lastError)):sub(1, 200), 14, vec2(12, 48), rgbm(1, 0.3, 0.3, 1))
    end
    if not sendEvent and isActive() then
      ui.dwriteDrawText('OVAL: немає online events, прапор до тебе не дійде. Онови Custom Shaders Patch.', 16, vec2(12, 30), rgbm(1, 0.3, 0.3, 1))
    end
    if debugOn then drawDebug() end
    if not isActive() and not edit then return end
    local k = win.y / 1080
    local pn = penNote and uiTime < penNote.untilT and penNote or nil
    local info = not pn and infoNote and uiTime < infoNote.untilT and infoNote or nil
    if edit and not pn and not info then info = DEMO_NOTE end
    local cx, y0 = hud.noteX * win.x, hud.noteY * win.y
    if pn then
      local hw = halfW(k, 640, { { { pn.title, 40 } }, { { pn.why, 22 } } })
      ui.drawRectFilled(vec2(cx - hw, y0), vec2(cx + hw, y0 + 130 * k), RED, 12 * k)
      box('note', cx - hw, y0, cx + hw, y0 + 130 * k, edit)
      centered(pn.title, 40 * k, cx, y0 + 12 * k, rgbm(1, 1, 1, 1))
      centered(pn.why, 22 * k, cx, y0 + 78 * k, rgbm(1, 1, 0.7, 1))
    elseif info then -- whom to follow, in big letters
      local why = info.place and { { 'ТВОЄ МІСЦЕ В КОЛОНІ:  ', 22 }, { tostring(info.place), 40 }, { '  З ' .. info.count, 22 } } or { { info.why, 22 } }
      local hw = halfW(k, 640, { { { info.title, 36 } }, why })
      ui.drawRectFilled(vec2(cx - hw, y0), vec2(cx + hw, y0 + 112 * k), YELLOW, 12 * k)
      box('note', cx - hw, y0, cx + hw, y0 + 112 * k, edit)
      centered(info.title, 36 * k, cx, y0 + 8 * k, BLACK)
      rich(why, k, cx, y0 + 56 * k, BLACK)
    end
    local showGreen = S.phase == GREEN and S.seq > 0 and clock() - S.tStart < 5000
    local demo = edit and (not isActive() or S.phase == GREEN and not showGreen)
    if S.phase == GREEN and not showGreen and not demo then return end

    cx = hud.topX * win.x
    local y = hud.topY * win.y
    local title, bg, lines = 'ЗЕЛЕНИЙ ПРАПОР', GREENC, {}
    local function add(text) lines[#lines + 1] = { { text, 18 } } end
    if demo then
      title, bg, showGreen = TITLES[0], YELLOW, false
      lines = { { { 'МІСЦЕ  ', 18 }, { '3', 30 }, { '  З 8 У КОЛОНІ', 18 } }, { { 'ЇДЬ ЗА  ', 18 }, { 'Ivanov', 26 } } }
    elseif S.phase == ONE_TO_GO then
      title, bg = 'ОДНЕ КОЛО ДО ЗЕЛЕНОГО', YELLOW
      add('ЗЕЛЕНИЙ НА ЛІНІЇ СТАРТ/ФІНІШ')
    elseif S.phase == CAUTION then
      title, bg = TITLES[S.reason] or TITLES[0], YELLOW
      local who = hudCars[S.cause]
      if S.reason == 2 then add('ТРИМАЙ СВІЙ РЯД - ЗЕЛЕНИЙ НА ЛІНІЇ') elseif who then add(ac.getDriverName(who.index)) end
      if S.reason ~= 2 then
        local w, lapped = pitWindow(), L1.down and L1.down > 0
        add(w == 0 and 'ПІТ-ЛЕЙН ЗАКРИТО' or w == 1 and (lapped and 'ПІТ-ЛЕЙН ЛИШЕ ДЛЯ ЛІДЕРСЬКОГО КОЛА - ТОБІ ЩЕ ЗАКРИТО' or 'ПІТ-ЛЕЙН ВІДКРИТО ДЛЯ ЛІДЕРСЬКОГО КОЛА') or 'ПІТ-ЛЕЙН ВІДКРИТО')
        if finalLap() then add('ОСТАННЄ КОЛО: ШИКУЙТЕСЬ У ДВА РЯДИ') end
      end
    end
    if not showGreen and not demo then
      local mine = dep.flags[ac.getCar(0).sessionID]
      if dep.me.wave and not dep.me.joined then
        lines[#lines + 1] = { { dep.me.wave, 30 } }
        add('ОБ\'ЇДЬ КОЛОНУ І SAFETY CAR, НАЗДОЖЕНИ КОЛОНУ ЗЗАДУ')
      elseif L1.out then
        add('ТИ ПОЗА КОЛОНОЮ: НАБЕРИ ШВИДКІСТЬ')
      elseif L1.place then
        if mine and mine.kind == TAIL and not dep.me.joined then add('РЕСТАРТ З КІНЦЯ КОЛОНИ (ПІТ-ЛЕЙН БУВ ЗАКРИТИЙ)') end
        local place = {}
        if L1.lane then
          place = { { 'РЯД  ', 18 }, { tostring(math.ceil(L1.place / 2)), 30 }, { L1.lane == 'in' and '  ВНУТРІШНІЙ     ' or '  ЗОВНІШНІЙ     ', 18 } }
        end
        place[#place + 1] = { 'МІСЦЕ  ', 18 }
        place[#place + 1] = { tostring(L1.place), 30 }
        place[#place + 1] = { '  З ' .. L1.count .. ' У КОЛОНІ', 18 }
        if S.phase == CAUTION then
          local crossed, at = greenLine()
          place[#place + 1] = { '     ЗЕЛЕНИЙ ЧЕРЕЗ  ', 18 }
          place[#place + 1] = { tostring(at - crossed), 30 }
          place[#place + 1] = { '  ' .. lapsWord(at - crossed), 18 }
        end
        lines[#lines + 1] = place
        if L1.ref then
          lines[#lines + 1] = { { L1.beside and 'ПОРУЧ З  ' or 'ЇДЬ ЗА  ', 18 }, { ac.getDriverName(L1.ref.index), 26 }, { L1.refDown > 0 and LAPPED or '', 18 } }
        else
          add(S.phase == ONE_TO_GO and 'ТИ ЛІДЕР: ТРИМАЙ ТЕМП, ГАЗ НА ЛІНІЇ' or 'ЇДЬ ЗА SAFETY CAR')
        end
        if L1.passIt then add('ОБЖЕНИ  ' .. ac.getDriverName(L1.passIt.index) .. (L1.passIt.speedKmh < offPaceKmh() and '  (ЗАНАДТО ПОВІЛЬНИЙ)' or '  (ПОЗАДУ ТЕБЕ В КОЛОНІ)')) end
      end
    end
    local bar = not showGreen and not demo and L1.target ~= nil
    local barLine
    if bar then
      local err = L1.err
      barLine = err > 10 and { { 'ДОДАЙ  ', 20 }, { math.floor(err + 0.5) .. ' м', 32 } } or err < -10 and { { 'СКИНЬ  ', 20 }, { math.floor(-err + 0.5) .. ' м', 32 } } or { { 'НА МІСЦІ', 20 } }
      barLine[#barLine + 1] = { '      ', 20 }
      barLine[#barLine + 1] = { tostring(math.floor(ac.getCar(0).speedKmh)), 32 }
      barLine[#barLine + 1] = { ' / ' .. math.floor(L1.target + 0.5) .. ' км/год' .. (L1.limiting and '  ОБМЕЖУВАЧ' or ''), 20 }
    end
    local warn, wbg = nil, RED
    if L1.passing then warn = 'НЕ ОБГАНЯЙ - ПОВЕРНИСЬ НАЗАД'
    elseif L1.letIt then warn, wbg = 'ПРОПУСТИ ' .. ac.getDriverName(L1.letIt.index) .. ' - ВІН ПОПЕРЕДУ ТЕБЕ В КОЛОНІ', BLUE
    elseif L1.tooClose then warn = 'ЗАБЛИЗЬКО - ЗБІЛЬШ ДИСТАНЦІЮ'
    elseif L1.speeding then warn = 'ЗБАВ ШВИДКІСТЬ'
    elseif L1.lagging then warn = 'ДОДАЙ - СКОРОТИ ВІДСТАНЬ' end
    if showGreen or demo then warn = nil end

    local sized = { { { title, 30 } } }
    local h = 44
    for _, line in ipairs(lines) do sized[#sized + 1] = line; h = h + lineHeight(line) + 6 end
    if barLine then sized[#sized + 1] = barLine; h = h + 24 + lineHeight(barLine) + 8 end
    if warn then sized[#sized + 1] = { { warn, 24 } } end
    local hw = halfW(k, 640, sized)
    ui.drawRectFilled(vec2(cx - hw, y), vec2(cx + hw, y + h * k), bg, 10 * k)
    centered(title, 30 * k, cx, y + 6 * k, BLACK)
    if not showGreen then
      local yy = y + 44 * k
      for _, line in ipairs(lines) do rich(line, k, cx, yy, BLACK); yy = yy + (lineHeight(line) + 6) * k end
      if bar then -- where we are against our place: the marker right of the middle = ahead of it
        local half, err = 200 * k, L1.err
        local mx = cx + clamp(-err, -60, 60) / 60 * half
        ui.drawRectFilled(vec2(cx - half, yy + 2 * k), vec2(cx + half, yy + 14 * k), rgbm(0, 0, 0, 0.6), 4 * k)
        ui.drawRectFilled(vec2(cx - half / 6, yy + 2 * k), vec2(cx + half / 6, yy + 14 * k), GREENC, 4 * k) -- +-10 m
        ui.drawRectFilled(vec2(mx - 4 * k, yy - 2 * k), vec2(mx + 4 * k, yy + 18 * k), math.abs(err) <= 10 and BLACK or RED, 2 * k)
        rich(barLine, k, cx, yy + 22 * k, (L1.speeding or L1.passing) and RED or BLACK)
      end
    end
    local bottom = y + h * k
    if warn then
      ui.drawRectFilled(vec2(cx - hw, bottom + 6 * k), vec2(cx + hw, bottom + 46 * k), wbg, 10 * k)
      centered(warn, 24 * k, cx, bottom + 12 * k, rgbm(1, 1, 1, 1))
      bottom = bottom + 46 * k
    end
    box('top', cx - hw, y, cx + hw, bottom, edit)
  end)()
end

function script.draw3D()
  guard(drawPaceCar)()
end

pcall(function() ac.log(string.format('Oval: %s loaded, CSP %s, me=%d cars=%d raceType=%s clock=%s events=%s penalty=%s', VERSION, tostring(build), ac.getCar(0).sessionID, sim.carsCount, tostring(sessionType()), tostring(clock()), tostring(sendEvent ~= nil), cfg.penalty)) end)
-- a timed race has no lap count, which may be why the game cannot count the laps of a drive-through
pcall(function() local s = ac.getSession(sim.currentSessionIndex); ac.log(string.format('Oval: session laps=%s timed=%s minutes=%s', tostring(s.laps), tostring(s.isTimedRace), tostring(s.durationMinutes))) end)

-- Offline tests load this file with a fake `ac` and read the internals from here.
if OVAL_TEST then return { state = function() return S end, local1 = function() return L1 end, watch = function() return watch end, pacePos = pacePos, lastError = function() return lastError end, presence = function() return presence end, pen = function() return pen end, note = function() return penNote end, info = function() return infoNote end, stats = function() return stats end, hud = function() return hud end, dep = function() return dep end, pitWindow = pitWindow } end
