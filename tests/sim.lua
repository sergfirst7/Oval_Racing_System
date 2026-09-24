-- Offline multi-client simulation of oval.lua with a fake CSP API.
-- Run:  luajit tests/sim.lua   (any Lua 5.1+ works)
-- Every simulated client runs its own copy of the script; ac.OnlineEvent messages travel over a
-- fake bus with latency and the 200 ms rate limit of a vanilla acServer.

local TRACK, DT, LATENCY = 2500, 1 / 30, 0.1
local GREEN, CAUTION, ONE_TO_GO = 0, 1, 2

local function frac(x) return x - math.floor(x) end
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end

local W = { t = 0, cars = {}, clients = {}, queue = {}, errors = {} } -- t in seconds
local function resetWorld() W.t, W.cars, W.clients, W.queue, W.catchup = 0, {}, {}, {}, 60 end

-- ── fake API ─────────────────────────────────────────────────────────────────
local dummy
dummy = setmetatable({}, { __index = function() return dummy end, __call = function() return dummy end, __add = function() return dummy end })
local function noop() end

local function newEnv(client, cfgOverride)
  local car = client.car
  local sim = { carsCount = #W.cars, trackLengthM = TRACK, currentSessionTime = 0, raceSessionType = 3, isSessionStarted = true, isOnlineRace = true, isAdmin = client.admin }
  client.sim = sim
  local env = setmetatable({ OVAL_TEST = true, script = {}, math = math, string = string, table = table, pairs = pairs, ipairs = ipairs,
    pcall = pcall, tostring = tostring, type = type, next = next, setmetatable = setmetatable }, { __index = function(_, k) return rawget(_G, k) end })
  local StructItem = { key = function(k) return k end, array = function() return 'array' end }
  for _, n in ipairs { 'int32', 'uint8', 'uint16', 'float' } do StructItem[n] = function() return n end end
  env.ac = {
    getSim = function() return sim end,
    configValues = function(layout)
      local c = {}
      for k, v in pairs(layout) do c[k] = (cfgOverride and cfgOverride[k]) or v end
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
    trackCoordinateToWorld = function() return dummy end,
    log = function(m) W.errors[#W.errors + 1] = tostring(m) end,
    OnlineEvent = function(_, cb)
      local buf = { order = {} }
      client.cb = cb
      local function send(_, repeatForNew)
        if W.t - (client.lastSend or -1) < 0.2 then return false end -- vanilla acServer rate limit
        client.lastSend = W.t
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
  local uiStub = setmetatable({ windowSize = function() return { x = 1920, y = 1080 } end, measureDWriteText = function() return { x = 100, y = 20 } end },
    { __index = function() return noop end })
  env.ui, env.render, env.vec2, env.vec3, env.rgbm = uiStub, dummy, dummy, dummy, dummy
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
  if car.stopped then return 0 end
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
  for _, cl in ipairs(W.clients) do cl.sim.currentSessionTime, cl.sim.carsCount = ms, #W.cars end
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
      local cl = phaseOf[c]
      local st = cl and cl.oval.state() or { phase = GREEN }
      local pace = cl and st.phase == CAUTION and cl.oval.pacePos() or nil
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

local function field(n, gap, kmh, cfgOverride, adminId) -- n cars `gap` metres apart, one client per car
  resetWorld()
  for i = 1, n do addCar(i, 0.5 - (i - 1) * gap / TRACK, kmh) end
  local byId, initial = {}, {}
  for i, c in ipairs(W.cars) do initial[i], byId[c.sessionID] = c, c end
  for _, c in ipairs(initial) do addClient(c, c.sessionID == adminId, cfgOverride) end
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
  check(st.reason == 1 and st.cause == 4, 'a car standing still calls the caution and is named as the cause')
  check(W.t - t0 > 4 and W.t - t0 < 15, 'the caution comes after stopSec, not instantly (' .. string.format('%.1f', W.t - t0) .. ' s)')
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

  untilTrue(function() return W.clients[1].oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  local order, prev, worst = W.clients[1].oval.state().order, nil, 0
  for _, id in ipairs(order) do
    if prev then worst = math.max(worst, frac(prev.splinePosition - byId[id].splinePosition) * TRACK) end
    prev = byId[id]
  end
  print(string.format('     one to go after %.0f s of caution, widest gap in the pack %.0f m', W.t - cautionAt, worst))
  check(W.t - cautionAt > 100, 'at least cautionLaps pace laps first')
  check(worst < 60, 'the field is bunched when one to go is shown')
  runClean(1)
  everyone(ONE_TO_GO, 'shows one to go')

  untilTrue(function() return W.clients[1].oval.state().phase == GREEN end, 200, 'the green flag')
  local leaderSpline
  leaderSpline = byId[order[1]].splinePosition
  check(leaderSpline < 0.1, 'green comes when the leader crosses the line (spline ' .. string.format('%.3f', leaderSpline) .. ')')
  run(1)
  everyone(GREEN, 'is green')
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

scenarioManual()
scenarioAuto()
scenarioGiveUp()
scenarioStraggler()
check(#W.errors == 0, 'no script errors' .. (W.errors[1] and (': ' .. W.errors[1]) or ''))
print('all good')
