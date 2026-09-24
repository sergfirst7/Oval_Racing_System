-- Offline multi-client simulation of oval.lua with a fake CSP API.
-- Run:  luajit tests/sim.lua   (any Lua 5.1+ works)
-- Every simulated client runs its own copy of the script; ac.OnlineEvent messages travel over a
-- fake bus with latency and the 200 ms rate limit of a vanilla acServer.

local TRACK, DT, LATENCY = 2500, 1 / 30, 0.1
local GREEN, CAUTION, ONE_TO_GO = 0, 1, 2

local function frac(x) return x - math.floor(x) end
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end

local W = { t = 0, cars = {}, clients = {}, queue = {}, errors = {} } -- t in seconds
local function resetWorld() W.t, W.cars, W.clients, W.queue, W.catchup, W.hold, W.defaults, W.tts, W.clockOffset, W.modelFails = 0, {}, {}, {}, 60, false, { rolling = 0 }, true, 0, false end

-- ── fake API ─────────────────────────────────────────────────────────────────
local V = {}
V.__index = V
local function vec3(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
V.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__mul = function(a, k) if type(a) == 'number' then a, k = k, a end return vec3(a.x * k, a.y * k, a.z * k) end
function V:clone() return vec3(self.x, self.y, self.z) end
function V:normalize() local l = math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2); self.x, self.y, self.z = self.x / l, self.y / l, self.z / l; return self end
function V:cross(o) local x, y, z = self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x; self.x, self.y, self.z = x, y, z; return self end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local R = TRACK / (2 * math.pi)
local function roadPoint(v) -- track coordinates -> world: a circle, x is the distance to the right (outwards)
  local a = 2 * math.pi * v.z
  return vec3((R + v.x * 10) * math.cos(a), v.y, (R + v.x * 10) * math.sin(a))
end
local dummy
dummy = setmetatable({}, { __index = function() return dummy end, __call = function() return dummy end, __add = function() return dummy end })
local function noop() end

local function newEnv(client, cfgOverride)
  local car = client.car
  local sim = { carsCount = #W.cars, trackLengthM = TRACK, currentSessionTime = 0, raceSessionType = 3, isSessionStarted = true, timeToSessionStart = -1, isOnlineRace = true, isAdmin = client.admin }
  client.sim = sim
  local env = setmetatable({ OVAL_TEST = true, script = {}, math = math, string = string, table = table, pairs = pairs, ipairs = ipairs,
    pcall = pcall, tostring = tostring, type = type, next = next, setmetatable = setmetatable }, { __index = function(_, k) return rawget(_G, k) end })
  local StructItem = { key = function(k) return k end, array = function() return 'array' end }
  for _, n in ipairs { 'int32', 'uint8', 'uint16', 'float' } do StructItem[n] = function() return n end end
  env.ac = {
    getSim = function() return sim end,
    configValues = function(layout)
      local c = {}
      for k, v in pairs(layout) do
        local o = cfgOverride and cfgOverride[k]
        if o == nil then o = W.defaults[k] end -- tests start standing unless a scenario asks for a rolling start
        if o == nil then o = v end
        c[k] = o
      end
      return c
    end,
    getCar = function(i)
      if i == 0 then return car end
      local n = 0
      for _, c in ipairs(W.cars) do
        if c ~= car then n = n + 1; if n == i then return c end end
      end
    end,
    SessionType = { Race = 3 },
    StructItem = StructItem,
    onSessionStart = noop,
    onOutgoingChatMessage = function(cb) client.chat = cb end,
    getDriverName = function(i) return 'car' .. i end,
    log = function(m) if tostring(m):find('rror') or tostring(m):find('unavailable') then W.errors[#W.errors + 1] = tostring(m) end end,
    onCarCollision = function(_, cb) client.hitcb = cb end,
    OnlineEvent = function(_, cb)
      local buf = { order = {} }
      client.cb = cb
      local function send(_, repeatForNew)
        if W.t - (client.lastSend or -1) < 0.2 then return false end -- vanilla acServer rate limit
        client.lastSend = W.t
        W.sends = (W.sends or 0) + 1
        local msg = { order = {} }
        for k, v in pairs(buf) do if k ~= 'order' then msg[k] = v end end
        for i = 0, 47 do msg.order[i] = buf.order[i] end
        client.repeatMsg = repeatForNew and msg or nil
        for _, other in ipairs(W.clients) do
          if other.cb and other.connected then W.queue[#W.queue + 1] = { at = W.t + LATENCY, to = other, from = car, msg = msg } end
        end
        return true
      end
      return send, function() return buf end
    end,
  }
  local gfx = { loads = {}, lights = {} }
  client.gfx = gfx
  local function node()
    local n = {}
    function n:setVisible(v) self.visible = v; return self end
    function n:setPosition(p) self.pos = p; return self end
    function n:setOrientation(look, up) self.look, self.up = look, up; return self end
    function n:loadKN5Async(path, cb) gfx.loads[#gfx.loads + 1] = path; if W.modelFails then cb('no such file') else cb(nil, {}) end end
    return n
  end
  env.ac.findNodes = function() return { createBoundingSphereNode = function() gfx.node = node(); return gfx.node end } end
  env.ac.LightType = { Regular = 1 }
  env.ac.LightSource = function() local l = { color = { r = 0 } }; gfx.lights[#gfx.lights + 1] = l; return l end
  env.ac.trackCoordinateToWorld = roadPoint
  env.render = setmetatable({ calls = {}, BlendMode = { BlendAdd = 4, AlphaBlend = 1 } }, { __index = function(tt, k) return function() tt.calls[k] = (tt.calls[k] or 0) + 1 end end })
  local uiStub = setmetatable({ windowSize = function() return { x = 1920, y = 1080 } end, measureDWriteText = function() return { x = 100, y = 20 } end },
    { __index = function() return noop end })
  env.ui, env.vec2, env.vec3, env.rgbm = uiStub, dummy, vec3, dummy
  env.rgb = function(r, g, b) return { r = r, g = g, b = b } end
  return env
end

local function loadScript(env)
  local src = OVAL_SRC or io.open('oval.lua'):read('*a') -- OVAL_SRC: for runtimes without io
  local fn, err
  if setfenv then fn, err = loadstring(src, 'oval.lua'); if fn then setfenv(fn, env) end
  else fn, err = load(src, 'oval.lua', 't', env) end
  assert(fn, err)
  return fn()
end

-- ── world ────────────────────────────────────────────────────────────────────
local function addCar(id, spline, kmh, opts)
  local c = { sessionID = id, index = id, isConnected = true, isActive = true, isInPitlane = false, isRetired = false,
    speedKmh = kmh, cruise = kmh, splinePosition = spline, lapCount = 0, racePosition = 0, ignore = false }
  for k, v in pairs(opts or {}) do c[k] = v end
  W.cars[#W.cars + 1] = c
  return c
end

local function addClient(car, admin, cfgOverride)
  local client = { car = car, admin = admin, connected = true }
  W.clients[#W.clients + 1] = client
  client.env = newEnv(client, cfgOverride)
  client.oval = loadScript(client.env)
  for _, other in ipairs(W.clients) do -- messages flagged for repeat reach new connections
    if other ~= client and other.repeatMsg and other.connected then W.queue[#W.queue + 1] = { at = W.t + LATENCY, to = client, from = other.car, msg = other.repeatMsg } end
  end
  return client
end

local function disconnect(client) client.connected, client.car.isConnected, client.car.isActive = false, false, false end

-- A driver who follows the rules: closes gaps like a human would, never above the limit.
local function target(car, phase, pace, paceKmh)
  if car.stopped or (W.hold and W.t < 0) then return 0 end
  if phase == GREEN or car.ignore then return car.cruise end
  if phase == ONE_TO_GO then return paceKmh - 4 end
  local gap, aheadKmh = TRACK, paceKmh
  for _, o in ipairs(W.cars) do
    if o ~= car and o.isConnected and not o.isInPitlane then
      local g = frac(o.splinePosition - car.splinePosition) * TRACK
      if g < gap then gap, aheadKmh = g, o.speedKmh end
    end
  end
  local g = pace and frac(pace - car.splinePosition) * TRACK or TRACK
  if g < gap then gap, aheadKmh = g, paceKmh end
  local t = paceKmh + W.catchup * clamp((gap - 30) / 120, 0, 1) - 4
  if gap < 20 then t = math.min(t, aheadKmh - 10) end
  return t
end

local function step()
  W.t = W.t + DT
  local ms = W.t * 1000
  for _, cl in ipairs(W.clients) do
    cl.sim.currentSessionTime, cl.sim.carsCount = ms + W.clockOffset * 1000, #W.cars
    cl.sim.timeToSessionStart = W.tts and math.max(-1, -ms) or -1 -- the game's countdown, -1 when it is not available
  end
  -- deliver messages
  local rest = {}
  for _, m in ipairs(W.queue) do
    if m.at <= W.t then m.to.cb(m.from, m.msg) else rest[#rest + 1] = m end
  end
  W.queue = rest
  -- physics (each driver looks at the phase its own client believes in)
  local phaseOf = {}
  for _, cl in ipairs(W.clients) do phaseOf[cl.car] = cl end
  for _, c in ipairs(W.cars) do
    if c.isConnected then
      local cl = phaseOf[c] or W.clients[1] -- a car without the script still obeys what its driver sees
      local st = cl.oval.state()
      local pace = st.phase == CAUTION and cl.oval.pacePos() or nil
      local want = target(c, st.phase, pace, 100) / 3.6
      local v = c.speedKmh / 3.6
      v = v < want and math.min(want, v + 5 * DT) or math.max(want, v - 10 * DT)
      c.speedKmh = v * 3.6
      local s = c.splinePosition + v * DT / TRACK
      if s >= 1 then s, c.lapCount = s - 1, c.lapCount + 1 end
      c.splinePosition = s
    end
  end
  table.sort(W.cars, function(a, b) return a.lapCount + a.splinePosition > b.lapCount + b.splinePosition end)
  for i, c in ipairs(W.cars) do c.racePosition = i end
  for _, cl in ipairs(W.clients) do if cl.connected then cl.env.script.update(DT); cl.env.script.drawUI(); cl.env.script.draw3D() end end
end

local function run(sec) for _ = 1, math.floor(sec / DT) do step() end end

-- ── scenarios ────────────────────────────────────────────────────────────────
local function check(cond, msg) if not cond then error('FAIL: ' .. msg, 2) end print('ok   ' .. msg) end

local function field(n, gap, kmh, cfgOverride, adminId, noScript) -- n cars `gap` metres apart, one client per car
  resetWorld()
  for i = 1, n do addCar(i, 0.5 - (i - 1) * gap / TRACK, kmh) end
  local byId, initial = {}, {}
  for i, c in ipairs(W.cars) do initial[i], byId[c.sessionID] = c, c end
  for _, c in ipairs(initial) do
    if not (noScript and noScript[c.sessionID]) then addClient(c, c.sessionID == adminId, cfgOverride) end
  end
  return byId
end

local function untilTrue(cond, maxSec, msg)
  for _ = 1, math.floor(maxSec / DT) do
    if cond() then return end
    step()
  end
  error('FAIL: timed out waiting for ' .. msg, 2)
end

local function everyone(phase, msg)
  for _, cl in ipairs(W.clients) do
    if cl.connected then check(cl.oval.state().phase == phase, 'client ' .. cl.car.sessionID .. ' ' .. msg) end
  end
end

-- Compliant drivers may see a warning for a moment (a car merged in front of them) but never for
-- longer than they need to react: this is the window a penalty rule would allow.
local function watchClean(state, sinceSec)
  state.since = state.since or {}
  for _, cl in ipairs(W.clients) do
    local l, id = cl.oval.local1(), cl.car.sessionID
    if cl.connected and W.t > sinceSec and (l.speeding or l.passing) and not cl.car.ignore then
      state.since[id] = state.since[id] or W.t
      if W.t - state.since[id] > 1.5 then state.dirty = state.dirty or ('client ' .. id .. ' warned for over 1.5 s at t=' .. math.floor(W.t)) end
    else
      state.since[id] = nil
    end
  end
end

local function scenarioManual()
  print('== manual flags')
  local noRestart = { cautionLaps = 99, maxCautionLaps = 99 }
  -- 8 cars 45 m apart at 200 km/h plus a straggler 600 m back; car 5 is the admin.
  local byId = field(8, 45, 200, noRestart, 5)
  local straggler = addCar(9, 0.5 - 600 / TRACK, 200)
  addClient(straggler, false, noRestart)
  local admin = 5
  run(10)
  check(W.clients[1].oval.state().phase == GREEN, 'starts green')
  check(W.clients[admin].chat('!yellow') == true, 'admin !yellow is handled (kept out of chat)')
  check(W.clients[1].chat('!yellow') == false, 'non-admin !yellow is left alone')
  run(1)
  local ref = W.clients[1].oval.state()
  check(ref.phase == CAUTION and #ref.order == 9, 'caution with 9 cars in order')
  for _, cl in ipairs(W.clients) do
    local st = cl.oval.state()
    check(st.seq == ref.seq and st.s0 == ref.s0 and st.tStart == ref.tStart and st.phase == CAUTION and #st.order == 9,
      'client ' .. cl.car.sessionID .. ' shares the same state')
    check(math.abs(cl.oval.pacePos() - W.clients[1].oval.pacePos()) < 1e-9, 'pace car position equal on client ' .. cl.car.sessionID)
  end

  byId[3].ignore = true -- a rule breaker
  local bad, watch = { speeding = false, passing = false }, {}
  for _ = 1, math.floor(150 / DT) do
    step()
    watchClean(watch, 22)
    local l = W.clients[3].oval.local1()
    bad.speeding, bad.passing = bad.speeding or l.speeding or false, bad.passing or l.passing or false
  end
  check(not watch.dirty, 'compliant drivers never see SLOW DOWN / DO NOT PASS after the first 10 s' .. (watch.dirty and (': ' .. watch.dirty) or ''))
  check(bad.speeding, 'rule breaker gets SLOW DOWN')
  check(bad.passing, 'rule breaker gets DO NOT PASS once ahead of the car in front')

  -- a late joiner still gets the state after the sender has left
  local late = addCar(10, 0.2, 100)
  disconnect(W.clients[admin])
  run(2)
  local lateClient = addClient(late, false, noRestart)
  run(1)
  check(lateClient.oval.state().phase == CAUTION, 'late joiner gets the caution from a re-announcing controller')
  check(lateClient.oval.state().seq > ref.seq, 're-announcement bumped the sequence')

  W.clients[1].admin, W.clients[1].sim.isAdmin = true, true
  check(W.clients[1].chat('!green') == true, '!green handled')
  run(1)
  everyone(GREEN, 'is green again')

  -- two admins call a caution at the very same moment: everybody must end up with one state
  W.clients[6].admin, W.clients[6].sim.isAdmin = true, true
  W.clients[1].chat('!yellow'); W.clients[6].chat('!yellow')
  run(1)
  local first
  for _, cl in ipairs(W.clients) do
    if cl.connected then
      local st = cl.oval.state()
      first = first or st
      check(st.seq == first.seq and st.from == first.from and st.phase == CAUTION, 'client ' .. cl.car.sessionID .. ' converged after a simultaneous call')
    end
  end
  check(first.from == 1, 'the lowest session id wins the tie')
end

local function scenarioAuto()
  print('== automatic caution, bunching, restart')
  local byId = field(10, 45, 200)
  run(30)
  everyone(GREEN, 'stays green while everybody races')

  byId[4].stopped = true
  local t0 = W.t
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution')
  local st = W.clients[1].oval.state()
  check(st.reason == 1 and st.cause == 4 and st.from == 4, 'a car standing still calls the caution itself and is named as the cause')
  check(W.t - t0 > 3 and W.t - t0 < 15, 'the caution comes after stopSec, not instantly (' .. string.format('%.1f', W.t - t0) .. ' s)')
  run(1)
  everyone(CAUTION, 'agrees on the caution')

  local watch, cautionAt = {}, W.t
  local function runClean(sec) for _ = 1, math.floor(sec / DT) do step(); watchClean(watch, cautionAt + 12) end end
  runClean(15)
  check(W.clients[1].oval.state().phase == CAUTION, 'no restart while the stopped car is still on track')
  byId[4].isInPitlane = true -- it was recovered
  runClean(10)
  byId[6].isInPitlane = true -- another car pits and comes back
  runClean(10)
  byId[6].isInPitlane = false
  runClean(4)
  for _, cl in ipairs(W.clients) do
    local o = cl.oval.state().order
    check(table.concat(o, ',') == '1,2,3,5,6,7,8,9,10', 'client ' .. cl.car.sessionID .. ' order: recovered car dropped, returned car back in its own place (' .. table.concat(o, ',') .. ')')
  end

  local sends0 = W.sends
  untilTrue(function() return W.clients[1].oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  local order, prev, worst = W.clients[1].oval.state().order, nil, 0
  for _, id in ipairs(order) do
    if prev then worst = math.max(worst, frac(prev.splinePosition - byId[id].splinePosition) * TRACK) end
    prev = byId[id]
  end
  print(string.format('     one to go after %.0f s of caution, widest gap in the pack %.0f m', W.t - cautionAt, worst))
  check(W.t - cautionAt > 85 and W.t - cautionAt < 160, 'one pace lap, not three: one to go after ' .. string.format('%.0f', W.t - cautionAt) .. ' s')
  check(worst < 60, 'the field is bunched when one to go is shown')
  runClean(1)
  everyone(ONE_TO_GO, 'shows one to go')

  untilTrue(function() return W.clients[1].oval.state().phase == GREEN end, 200, 'the green flag')
  local leaderSpline
  leaderSpline = byId[order[1]].splinePosition
  check(leaderSpline < 0.1, 'green comes when the leader crosses the line (spline ' .. string.format('%.3f', leaderSpline) .. ')')
  run(1)
  everyone(GREEN, 'is green')
  check(W.sends - sends0 <= 6, 'the whole restart took ' .. (W.sends - sends0) .. ' messages, not one per client')
  check(not watch.dirty, 'compliant drivers were never warned during the whole caution' .. (watch.dirty and (': ' .. watch.dirty) or ''))
  byId[5].stopped = true -- stops again right after the restart
  run(18)
  everyone(GREEN, 'stays green during the cooldown although a car is standing')
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the next caution')
  check(W.clients[1].oval.state().cause == 5, 'the next caution comes after the cooldown')
end

local function scenarioStraggler()
  print('== the restart waits for the field to bunch up')
  local byId = field(8, 45, 200, { cautionLaps = 1, catchupKmh = 20 })
  W.catchup = 20
  local straggler = addCar(9, 0.5 - 8 * 45 / TRACK - 1200 / TRACK, 200)
  addClient(straggler, false, { cautionLaps = 1, catchupKmh = 20 })
  run(30)
  byId[1].stopped = true
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution')
  local at = W.t
  byId[1].isInPitlane = true
  untilTrue(function() return W.clients[2].oval.state().phase == ONE_TO_GO end, 900, 'one to go')
  local prev, worst = nil, 0
  for _, id in ipairs(W.clients[2].oval.state().order) do
    local c = id == 9 and straggler or byId[id]
    if prev then worst = math.max(worst, frac(prev.splinePosition - c.splinePosition) * TRACK) end
    prev = c
  end
  print(string.format('     one to go after %.0f s of caution, widest gap %.0f m', W.t - at, worst))
  check(W.t - at > 220 and worst < 90, 'one to go only after the straggler caught up, although one pace lap had passed long before')
end

local function scenarioGiveUp()
  print('== a hazard that never clears')
  local byId = field(6, 45, 200, { cautionLaps = 1, maxCautionLaps = 2 })
  run(30)
  byId[3].stopped = true
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution')
  local at = W.t
  untilTrue(function() return W.clients[1].oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  check(W.t - at > 170, 'a car standing on track holds the restart until maxCautionLaps (' .. math.floor(W.t - at) .. ' s)')
  untilTrue(function() return W.clients[1].oval.state().phase == GREEN end, 200, 'the green flag')
  check(true, 'and the flag turns green')
end

local function scenarioWreck()
  print('== a wreck calls the caution at once, a scrape does not')
  local byId = field(8, 45, 200)
  run(30)
  byId[5].speedKmh = 185; W.clients[5].hitcb(0) -- brushes the wall and keeps going
  run(5)
  everyone(GREEN, 'a scrape that costs 15 km/h is no wreck')
  byId[5].speedKmh = 185; W.clients[5].hitcb(0)
  byId[5].speedKmh = 45 -- the same hit, but the car is nearly stopped
  local t0 = W.t
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 5, 'the wreck caution')
  local st = W.clients[1].oval.state()
  check(st.reason == 3 and st.cause == 5 and st.from == 5 and W.t - t0 < 1.5, 'the wreck is reported by the car itself within a moment (' .. string.format('%.1f', W.t - t0) .. ' s)')
end

local function scenarioGrid()
  print('== a car that never got up to speed is no incident')
  local byId = field(6, 20, 0)
  for _, c in pairs(byId) do c.stopped = true end -- everybody sits on the grid past the grace time
  run(45)
  everyone(GREEN, 'a whole grid standing still calls no caution')
  for _, c in pairs(byId) do c.stopped, c.cruise = false, 150 end
  run(20)
  byId[3].stopped = true
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution after the start')
  check(W.clients[1].oval.state().cause == 3, 'but a car that stops after racing does')
end

local function grid(n)
  local byId, initial = {}, {}
  for i = 1, n do -- two abreast, rows 20 m apart, the outside car 8 m behind its row mate
    byId[i] = addCar(i, 0.999 - (math.ceil(i / 2) - 1) * 20 / TRACK - (i % 2 == 0 and 8 or 0) / TRACK, 0, { cruise = 200 })
    initial[i] = byId[i]
  end
  for _, c in ipairs(initial) do addClient(c, false) end
  return byId
end

local function scenarioRolling(useCountdown)
  print(useCountdown and '== rolling start on the countdown signal' or '== rolling start when the countdown is not available')
  resetWorld()
  W.defaults.rolling, W.hold, W.tts, W.clockOffset = 1, true, useCountdown, 6 -- the session clock is already running during the lights
  local byId = grid(10)
  W.t = -6
  run(5.5)
  everyone(GREEN, 'the field waits while the lights count down, the pace car does not leave early')
  check(W.clients[1].oval.state().seq == 0, 'nothing was sent during the countdown')
  local watch = {}
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 6, 'the rolling start')
  local st = W.clients[1].oval.state()
  local delay = W.t
  check(st.reason == 2 and st.from == 1 and delay >= 0 and delay < (useCountdown and 0.6 or 3), 'the pace car is released when the lights go out (' .. string.format('%.1f', delay) .. ' s after)')
  check(table.concat(st.order, ',') == '1,2,3,4,5,6,7,8,9,10', 'the order is the grid order (' .. table.concat(st.order, ',') .. ')')
  local started = W.t
  run(3)
  local one, two = byId[1], byId[2] -- the outside car of the first row edges 8 m ahead of its row mate while launching
  two.splinePosition = one.splinePosition + 8 / TRACK
  run(0.5)
  check(not W.clients[2].oval.local1().passing, 'a row mate 8 m ahead on the launch is not yet a pass')
  two.splinePosition = one.splinePosition - 8 / TRACK
  for _ = 1, math.floor(300 / DT) do
    step(); watchClean(watch, started + 25)
    if W.clients[1].oval.state().phase == GREEN and W.t > started + 20 then break end
  end
  local g = W.clients[1].oval.state()
  local took = W.t - started
  check(g.phase == GREEN and g.reason == 0 and g.seq > st.seq and took > 85 and took < 135, 'one pace lap, then the start: green after ' .. string.format('%.0f', took) .. ' s')
  check(g.seq == st.seq + 2, 'the pace car left on the last part of that lap: exactly two messages (one to go, green), not an extra lap')
  check(not watch.dirty, 'nobody who followed the rules was warned' .. (watch.dirty and (': ' .. watch.dirty) or ''))
  run(40)
  everyone(GREEN, 'the race goes on green, no automatic caution right after the start')
end

local function scenarioNotARace()
  print('== practice and qualifying: nothing happens')
  resetWorld()
  W.defaults.rolling, W.hold, W.clockOffset = 1, true, 6
  local byId = grid(6)
  for _, cl in ipairs(W.clients) do cl.sim.raceSessionType = 2 end
  W.t = -6
  run(10)
  W.clients[3].hitcb(0); byId[3].speedKmh = 20 -- a wreck
  byId[4].stopped = true -- and a car that stops
  run(30)
  for _, cl in ipairs(W.clients) do check(cl.oval.state().seq == 0, 'client ' .. cl.car.sessionID .. ' saw no pace car in qualifying') end
  check(W.clients[1].chat('!yellow') == false, 'even !yellow is not handled outside a race')
end

local function scenarioLeaderless()
  print('== nobody is left to cross the line')
  local byId = field(6, 45, 200, { cautionLaps = 1 })
  run(30)
  byId[3].stopped = true
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution')
  byId[3].isInPitlane = true
  untilTrue(function() return W.clients[1].oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  for _, c in pairs(byId) do c.isInPitlane = true end -- everybody dives into the pits
  local at = W.t
  untilTrue(function() return W.clients[1].oval.state().phase == GREEN end, 200, 'the green flag')
  check(W.t - at < 150, 'the flag turns green by itself after 1.5 laps (' .. string.format('%.0f', W.t - at) .. ' s)')
end

local function scenarioModel()
  print('== pace car model with a strobe bar')
  field(6, 45, 200, nil, 1)
  run(5)
  check(#W.clients[2].gfx.loads == 0, 'nothing is loaded while the race is green')
  W.clients[1].chat('!yellow')
  run(0.5)
  local gfx, ov = W.clients[2].gfx, W.clients[2].oval
  check(#gfx.loads == 1 and gfx.loads[1]:find('aston_vantage2018.kn5', 1, true), 'the Aston Martin model is loaded once, when the first pace car appears')
  check(gfx.node.visible == true, 'and shown')
  local left, right, off, both, worst = false, false, false, false, { up = 1, fwd = 1, pos = 0 }
  for _ = 1, math.floor(3 / DT) do
    step()
    local a, b = gfx.lights[1].color.r > 0, gfx.lights[2].color.r > 0
    left, right, off, both = left or (a and not b), right or (b and not a), off or (not a and not b), both or (a and b)
    local n, s = gfx.node, ov.pacePos()
    local want = roadPoint(vec3(0, 0, s))
    local a2 = 2 * math.pi * s
    local tangent = vec3(-math.sin(a2), 0, math.cos(a2))
    worst.pos = math.max(worst.pos, math.abs(n.pos.x - want.x) + math.abs(n.pos.z - want.z))
    worst.up = math.min(worst.up, n.up.y)
    worst.fwd = math.min(worst.fwd, dot(n.look, tangent))
  end
  check(worst.pos < 1e-6, 'the model stands on the synced pace car position')
  check(worst.up > 0.999 and worst.fwd > 0.999, 'it points along the road and stands upright (up ' .. string.format('%.4f', worst.up) .. ', forward ' .. string.format('%.4f', worst.fwd) .. ')')
  check(left and right and off and not both, 'the two lights flash in turns and are dark in between, never both at once')
  check((W.clients[2].env.render.calls.rectangle or 0) > 10, 'the strobe glow is drawn')
  check(W.clients[2].env.render.calls.setBlendMode % 2 == 0, 'the blend mode is always put back')
  check(#gfx.loads == 1, 'the model was not loaded again')
  W.clients[1].chat('!green')
  run(1)
  check(gfx.node.visible == false and gfx.lights[1].color.r == 0 and gfx.lights[2].color.r == 0, 'model hidden and lights off on green')

  print('== the model cannot be loaded')
  field(6, 45, 200, nil, 1)
  W.modelFails = true
  run(5)
  W.clients[1].chat('!yellow')
  run(3)
  local c = W.clients[2]
  check(#c.gfx.loads == 1 and (c.env.render.calls.debugArrow or 0) > 10, 'one attempt, then the arrow marker')
  W.modelFails = false

  print('== the model is switched off')
  field(6, 45, 200, { paceModel = '' }, 1)
  run(5)
  W.clients[1].chat('!yellow')
  run(3)
  check(#W.clients[2].gfx.loads == 0 and (W.clients[2].env.render.calls.debugArrow or 0) > 10, 'paceModel = empty: no model, arrow only')
end

local function scenarioNoScript()
  print('== the lowest session id has no script')
  local byId = field(8, 45, 200, nil, nil, { [1] = true })
  run(30)
  byId[4].stopped = true
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution')
  check(W.clients[1].oval.state().from == 4, 'the caution comes although the controller-to-be runs nothing')
  byId[4].isInPitlane = true
  byId[6].isInPitlane = true
  run(6)
  byId[6].isInPitlane = false
  run(6)
  check(table.concat(W.clients[1].oval.state().order, ',') == '1,2,3,5,6,7,8', 'the order is kept up by the next client in line (' .. table.concat(W.clients[1].oval.state().order, ',') .. ')')
  untilTrue(function() return W.clients[1].oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  untilTrue(function() return W.clients[1].oval.state().phase == GREEN end, 200, 'the green flag')
  check(true, 'one to go and green happen too')
end

scenarioManual()
scenarioWreck()
scenarioModel()
scenarioGrid()
scenarioRolling(true)
scenarioRolling(false)
scenarioNotARace()
scenarioLeaderless()
scenarioNoScript()
scenarioAuto()
scenarioGiveUp()
scenarioStraggler()
check(#W.errors == 0, 'no script errors' .. (W.errors[1] and (': ' .. W.errors[1]) or ''))
print('all good')
