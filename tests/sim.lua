-- Offline multi-client simulation of oval.lua with a fake CSP API.
-- Run:  luajit tests/sim.lua   (any Lua 5.1+ works)
-- Every simulated client runs its own copy of the script; ac.OnlineEvent messages travel over a
-- fake bus with latency and the 200 ms rate limit of a vanilla acServer.

local TRACK, DT, LATENCY = 2500, 1 / 30, 0.1
local GREEN, CAUTION = 0, 1

local function frac(x) return x - math.floor(x) end
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end

local W = { t = 0, cars = {}, clients = {}, queue = {}, errors = {} } -- t in seconds

-- ── fake API ─────────────────────────────────────────────────────────────────
local dummy
dummy = setmetatable({}, { __index = function() return dummy end, __call = function() return dummy end, __add = function() return dummy end })
local function noop() end

local function newEnv(client, cfgOverride)
  local car = client.car
  local sim = { carsCount = #W.cars, trackLengthM = TRACK, currentSessionTime = 0, raceSessionType = 3, isOnlineRace = true, isAdmin = client.admin }
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
  if phase == GREEN or car.ignore then return car.cruise end
  local gap, aheadKmh = TRACK, paceKmh
  for _, o in ipairs(W.cars) do
    if o ~= car and o.isConnected and not o.isInPitlane then
      local g = frac(o.splinePosition - car.splinePosition) * TRACK
      if g < gap then gap, aheadKmh = g, o.speedKmh end
    end
  end
  local g = frac(pace - car.splinePosition) * TRACK
  if g < gap then gap, aheadKmh = g, paceKmh end
  local t = paceKmh + 60 * clamp((gap - 30) / 120, 0, 1) - 4
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
      local pace = cl and st.phase == CAUTION and cl.oval.pacePos() or 0
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

-- ── scenario ─────────────────────────────────────────────────────────────────
local function check(cond, msg) if not cond then error('FAIL: ' .. msg, 2) end print('ok   ' .. msg) end

-- 8 cars, 45 m apart at 200 km/h, plus one straggler 600 m back; car 5 is the admin.
for i = 1, 8 do addCar(i, 0.5 - (i - 1) * 45 / TRACK, 200) end
addCar(9, 0.5 - 600 / TRACK, 200)
local byId = {}
for _, c in ipairs(W.cars) do byId[c.sessionID] = c end
local initial = {}
for i, c in ipairs(W.cars) do initial[i] = c end
for _, c in ipairs(initial) do addClient(c, c.sessionID == 5) end
local admin = 5 -- client index equals session id here

run(10)
check(W.clients[1].oval.state().phase == GREEN, 'starts green')

check(W.clients[admin].chat('!yellow') == true, 'admin !yellow is handled (kept out of chat)')
check(W.clients[1].chat('!yellow') == false, 'non-admin !yellow is left alone')
run(1)
local ref = W.clients[1].oval.state()
check(ref.phase == CAUTION and #ref.order == 9, 'caution with 9 cars in order')
for _, cl in ipairs(W.clients) do
  local s = cl.oval.state()
  check(s.seq == ref.seq and s.s0 == ref.s0 and s.tStart == ref.tStart and s.phase == CAUTION and #s.order == 9,
    'client ' .. cl.car.sessionID .. ' shares the same state')
end
for _, cl in ipairs(W.clients) do
  check(math.abs(cl.oval.pacePos() - W.clients[1].oval.pacePos()) < 1e-9, 'pace car position equal on client ' .. cl.car.sessionID)
end

-- obedient field: after the deployment window nobody triggers a warning
byId[3].ignore = true -- a rule breaker
local bad = { speeding = false, passing = false }
local clean = true
for i = 1, math.floor(150 / DT) do
  step()
  if W.t > 22 then
    for _, cl in ipairs(W.clients) do
      local l = cl.oval.local1()
      if cl.car.sessionID == 3 then
        bad.speeding = bad.speeding or l.speeding or false
        bad.passing = bad.passing or l.passing or false
      elseif l.speeding or l.passing then clean = false end
    end
  end
end
check(clean, 'compliant drivers never see SLOW DOWN / DO NOT PASS after the first 10 s')
check(bad.speeding, 'rule breaker gets SLOW DOWN')
check(bad.passing, 'rule breaker gets DO NOT PASS once ahead of the car in front')

-- late joiner receives the current state; the sender leaving does not lose it
local late = addCar(10, 0.2, 100)
disconnect(W.clients[admin])
run(2)
local lateClient = addClient(late, false)
run(1)
check(lateClient.oval.state().phase == CAUTION, 'late joiner gets the caution from a re-announcing controller')
check(lateClient.oval.state().seq > ref.seq, 're-announcement bumped the sequence')

-- admin releases
local admin2 = W.clients[1]
admin2.admin, admin2.sim.isAdmin = true, true
check(admin2.chat('!green') == true, '!green handled')
run(1)
for _, cl in ipairs(W.clients) do
  if cl.connected then check(cl.oval.state().phase == GREEN, 'client ' .. cl.car.sessionID .. ' is green again') end
end

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

check(#W.errors == 0, 'no script errors' .. (W.errors[1] and (': ' .. W.errors[1]) or ''))
print('all good')
