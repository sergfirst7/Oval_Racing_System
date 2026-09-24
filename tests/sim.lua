-- Offline multi-client simulation of oval.lua with a fake CSP API.
-- Run:  luajit tests/sim.lua   (any Lua 5.1+ works)
-- Every simulated client runs its own copy of the script; ac.OnlineEvent messages travel over a
-- fake bus with latency and the 200 ms rate limit of a vanilla acServer.

local TRACK, DT, LATENCY = 2500, 1 / 30, 0.1
local GREEN, CAUTION, ONE_TO_GO = 0, 1, 2

local function frac(x) return x - math.floor(x) end
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end

local W = { t = 0, cars = {}, clients = {}, queue = {}, errors = {}, logs = {}, oldApi = {} } -- t in seconds
local function resetWorld() W.t, W.cars, W.clients, W.queue, W.catchup, W.hold, W.defaults, W.tts, W.clockOffset, W.modelFails, W.ray, W.penaltyFails = 0, {}, {}, {}, 60, false, { rolling = 0 }, true, 0, false, 'ok', false end

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
    PenaltyType = { None = 0, MandatoryPits = 1, TeleportToPits = 2, SlowDown = 3, BlackFlag = 4, ReleaseBlackFlag = 5 },
    setMessage = function(title, why) client.messages[#client.messages + 1] = title .. ' / ' .. why end,
    getSession = function() return { type = W.sessionType or 3 } end,
    onChatMessage = function(cb) client.incoming = cb end,
    onOutgoingChatMessage = function(cb) client.chat = cb end,
    getDriverName = function(i) return 'car' .. i end,
    log = function(m) m = tostring(m); W.logs[#W.logs + 1] = m; if m:find('rror') then W.errors[#W.errors + 1] = m end end,
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
  for k in pairs(W.oldApi) do env.ac[k] = nil end -- pretend to be a CSP that lacks these functions
  if W.oldApi.structArray then StructItem.array = nil end
  client.texts, client.messages, client.penalties = {}, {}, {}
  local gfx = { loads = {}, lights = {}, meshes = {} }
  client.gfx = gfx
  local function node()
    local n = {}
    function n:setVisible(v) self.visible = v; return self end
    function n:setPosition(p) self.pos = p; return self end
    function n:setOrientation(look, up) self.look, self.up = look, up; return self end
    function n:loadKN5Async(path, cb) gfx.loads[#gfx.loads + 1] = path; if W.modelFails then cb('no such file') else
      cb(nil, { findMeshes = function(_, name)
        local m = gfx.meshes[name]
        if not m then
          m = { name = name, emissive = { r = 0 } }
          function m:ensureUniqueMaterials() self.unique = true; return self end
          function m:setMaterialProperty(prop, v) self.prop, self.emissive = prop, v; return self end
          gfx.meshes[name] = m
        end
        return m
      end })
    end end
    return n
  end
  env.ac.findNodes = function() return { createBoundingSphereNode = function() gfx.node = node(); return gfx.node end } end
  env.ac.LightType = { Regular = 1 }
  env.ac.LightSource = function() local l = { color = { r = 0 } }; gfx.lights[#gfx.lights + 1] = l; return l end
  env.ac.trackCoordinateToWorld = roadPoint
  env.physics = { setCarPenalty = function(kind, param)
    if W.penaltyFails then error('physics not available') end
    local name = kind == 1 and 'MandatoryPits' or kind == 3 and 'SlowDown' or kind == 5 and 'ReleaseBlackFlag' or tostring(kind)
    client.penalties[#client.penalties + 1] = { kind = name, param = param, t = W.t }
    car.currentPenaltyType, car.currentPenaltyParameter = kind, param -- what the game reports back (fields of the car)
  end, raycastTrack = function(pos, _, _, hit, normal) -- the asphalt lies 1 m below the height of the spline
    if W.ray == 'error' then error('physics not available') end
    if W.ray == 'miss' then return -1 end
    hit.x, hit.y, hit.z = pos.x, -1, pos.z
    normal.x, normal.y, normal.z = 0, 1, 0
    return pos.y + 1
  end }
  env.render = setmetatable({ calls = {}, BlendMode = { BlendAdd = 4, AlphaBlend = 1 } }, { __index = function(tt, k) return function() tt.calls[k] = (tt.calls[k] or 0) + 1 end end })
  local uiStub = setmetatable({ dwriteDrawText = function(text) client.texts[#client.texts + 1] = tostring(text) end, windowSize = function() return { x = 1920, y = 1080 } end, measureDWriteText = function() return { x = 100, y = 20 } end },
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
  if car.hold then return car.hold end
  if phase == ONE_TO_GO then return paceKmh - 4 + (car.over or 0) end
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
  return t + (car.over or 0)
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
  for _, cl in ipairs(W.clients) do if cl.connected then cl.texts = {}; cl.env.script.update(DT); cl.env.script.drawUI(); cl.env.script.draw3D() end end
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
  local known = true
  for _, cl in ipairs(W.clients) do
    local n = 0
    for _ in pairs(cl.oval.presence()) do n = n + 1 end
    known = known and n == 9
  end
  check(known, 'every client has heard from all nine script users (the greetings)')
  check(W.clients[2].oval.stats().sent >= 1 and W.clients[2].oval.stats().got >= 9, 'and counts what it sent and received')
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
  for _, cl in ipairs(W.clients) do check(#cl.penalties == 0, 'client ' .. cl.car.sessionID .. ' was not penalised in the whole caution') end
  check(not watch.dirty, 'compliant drivers were never warned during the whole caution' .. (watch.dirty and (': ' .. watch.dirty) or ''))
  local greenAt = W.t
  byId[5].stopped = true -- stops again right after the restart
  run(2)
  everyone(GREEN, 'stays green during the short cooldown although a car is standing')
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the next caution')
  check(W.clients[1].oval.state().cause == 5 and W.t - greenAt > 4, 'the next caution comes after the cooldown (' .. string.format('%.1f', W.t - greenAt) .. ' s)')
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
  print('== a wreck calls the caution at once, a scrape or hard braking does not')
  local byId = field(8, 45, 250)
  run(30)
  byId[5].speedKmh = 235; W.clients[5].hitcb(0) -- brushes the wall and keeps going
  run(5)
  everyone(GREEN, 'a scrape that costs 15 km/h is no wreck')
  byId[5].speedKmh, byId[5].cruise = 250, 190 -- braking hard for something: 60 km/h in under two seconds
  run(6)
  everyone(GREEN, 'hard braking is no wreck')
  byId[5].cruise = 250
  run(8)
  byId[5].speedKmh = 210 -- a jolt of 40 km/h without any contact event
  run(3)
  everyone(GREEN, 'a 40 km/h jolt without a contact is no wreck')
  byId[5].speedKmh = 250; W.clients[5].hitcb(0)
  byId[5].speedKmh, byId[5].cruise = 140, 140 -- a hard hit that leaves the car rolling at 140 km/h
  local t0 = W.t
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 5, 'the wreck caution')
  local st = W.clients[1].oval.state()
  check(st.reason == 3 and st.cause == 5 and st.from == 5 and W.t - t0 < 1.5, 'a hit that keeps the car at 140 km/h is a wreck, reported by the car itself (' .. string.format('%.1f', W.t - t0) .. ' s)')

  print('== the contact event is not needed')
  byId = field(8, 45, 250)
  run(30)
  byId[4].speedKmh, byId[4].cruise = 120, 120 -- 130 km/h lost in a moment, no contact callback at all
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 5, 'the caution without a contact event')
  check(W.clients[1].oval.state().reason == 3 and W.clients[1].oval.state().cause == 4, 'a sudden loss of speed alone is enough')

  print('== a limping car')
  byId = field(8, 45, 250)
  run(30)
  byId[6].cruise = 90 -- dragging along the wall at 90 km/h
  local t1 = W.t
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution for the limping car')
  check(W.clients[1].oval.state().reason == 1 and W.clients[1].oval.state().cause == 6, 'a car far below its own speed is stopped, not only one that stands (' .. string.format('%.1f', W.t - t1) .. ' s)')

  print('== a wreck right after the green flag')
  byId = field(8, 45, 250, nil, 1)
  run(30)
  W.clients[1].chat('!yellow')
  run(2)
  W.clients[1].chat('!green')
  local greenAt = W.t
  for _, c in pairs(byId) do c.cruise = 250 end
  run(5) -- the cooldown is 4 s
  byId[3].speedKmh, byId[3].cruise = 90, 90
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 5, 'the caution right after the restart')
  check(W.clients[1].oval.state().reason == 3 and W.t - greenAt < 8, 'a wreck a few seconds after the green flag is covered too (' .. string.format('%.1f', W.t - greenAt) .. ' s)')
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
  run(1)
  byId[3].speedKmh = 40 -- cars jump to the grid at the start of the session: a speed spike, not a start
  run(4.5)
  everyone(GREEN, 'the field waits while the lights count down, a speed spike from the grid teleport is no start')
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
  for _, cl in ipairs(W.clients) do check(#cl.penalties == 0, 'client ' .. cl.car.sessionID .. ' was not penalised at the start') end
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
  print('== pace car model: its own light bar flashes, it stands on the asphalt')
  field(6, 45, 200, nil, 1)
  run(5)
  check(#W.clients[2].gfx.loads == 0, 'nothing is loaded while the race is green')
  W.clients[1].chat('!yellow')
  run(0.5)
  local gfx, ov = W.clients[2].gfx, W.clients[2].oval
  check(#gfx.loads == 1 and gfx.loads[1]:find('aston_vantage2018.kn5', 1, true), 'the Aston Martin model is loaded once, when the first pace car appears')
  check(gfx.node.visible == true, 'and shown')
  local A, B = gfx.meshes['g_safety_red'], gfx.meshes['g_safety_yellow']
  check(A and B and A.unique and B.unique and A ~= B, 'the two lenses of the model own light bar are found and get materials of their own')
  local seenA, seenB, dark, both, worst = false, false, false, false, { up = 1, fwd = 1, pos = 0, y = 0 }
  local lightsFollow = true
  for _ = 1, math.floor(3 / DT) do
    step()
    local a1, b1 = A.emissive.r > 1, B.emissive.r > 1
    seenA, seenB, dark, both = seenA or (a1 and not b1), seenB or (b1 and not a1), dark or (not a1 and not b1), both or (a1 and b1)
    lightsFollow = lightsFollow and ((gfx.lights[1].color.r > 0) == a1) and ((gfx.lights[2].color.r > 0) == b1)
    local n, s = gfx.node, ov.pacePos()
    local want = roadPoint(vec3(0, 0, s))
    local a2 = 2 * math.pi * s
    local tangent = vec3(-math.sin(a2), 0, math.cos(a2))
    worst.pos = math.max(worst.pos, math.abs(n.pos.x - want.x) + math.abs(n.pos.z - want.z))
    worst.y = math.max(worst.y, math.abs(n.pos.y - (-1)))
    worst.up = math.min(worst.up, n.up.y)
    worst.fwd = math.min(worst.fwd, dot(n.look, tangent))
  end
  check(worst.pos < 1e-6, 'the model stands on the synced pace car position')
  check(worst.y < 1e-9, 'and on the asphalt found by the ray, not at the spline height (1 m above it here)')
  check(worst.up > 0.999 and worst.fwd > 0.999, 'it points along the road and stands upright (up ' .. string.format('%.4f', worst.up) .. ', forward ' .. string.format('%.4f', worst.fwd) .. ')')
  check(seenA and seenB and dark and not both, 'the two lenses flash in turns and are dark in between, never both at once')
  check(lightsFollow, 'the light sources glow exactly when their lens does')
  check((W.clients[2].env.render.calls.rectangle or 0) == 0, 'no glow squares are drawn any more')
  check(#gfx.loads == 1, 'the model was not loaded again')
  W.clients[1].chat('!green')
  run(1)
  check(gfx.node.visible == false and A.emissive.r == 0 and B.emissive.r == 0 and gfx.lights[1].color.r == 0 and gfx.lights[2].color.r == 0, 'model hidden, lenses and lights dark on green')

  for _, mode in ipairs({ 'miss', 'error' }) do
    print('== the ground ray ' .. (mode == 'miss' and 'hits nothing' or 'is not available'))
    field(6, 45, 200, nil, 1)
    W.ray = mode
    run(5)
    W.clients[1].chat('!yellow')
    run(2)
    check(math.abs(W.clients[2].gfx.node.pos.y) < 1e-9, 'the model falls back to the spline height')
  end
  W.ray = 'ok'

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

local function scenarioOldCsp()
  print('== an old CSP that lacks some functions')
  W.oldApi = { onOutgoingChatMessage = true, onSessionStart = true, configValues = true, getPatchVersionCode = true, onCarCollision = true }
  local byId = field(6, 45, 200)
  W.oldApi = {}
  local before = #W.logs
  run(30)
  byId[3].stopped = true
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution')
  check(W.clients[1].oval.state().cause == 3 and #W.errors == 0, 'the script loads and works, only the missing features are gone')
  local said = table.concat(W.logs, ' ', 1, #W.logs)
  check(said:find('chat commands unavailable', 1, true) and said:find('session start events unavailable', 1, true), 'and the log says which ones')
  check(W.clients[1].chat == nil, 'no chat commands then')
  check(W.clients[1].oval.local1() ~= nil, 'the rules still run')

  print('== old CSP: commands come back through the incoming chat')
  W.oldApi = { onOutgoingChatMessage = true }
  field(4, 45, 200, nil, 2)
  W.oldApi = {}
  run(5)
  W.clients[2].incoming('!yellow', 3)
  W.clients[1].incoming('!yellow', 0)
  run(1)
  everyone(GREEN, 'a message of another player, or of a player who is no admin, is no command')
  W.clients[2].incoming('!yellow', 0)
  run(1)
  check(W.clients[1].oval.state().phase == CAUTION, 'the admin\'s own message coming back calls the caution')

  print('== old CSP: no arrays in the event layout')
  W.oldApi = { structArray = true }
  field(4, 45, 200)
  W.oldApi = {}
  run(2)
  local warned2 = false
  for _, tx in ipairs(W.clients[1].texts) do warned2 = warned2 or tx:find('no online events', 1, true) ~= nil end
  check(warned2 and #W.errors == 0, 'the script loads, tells the player, and does not fail')

  print('== old CSP: the session type comes from the session')
  local old = field(4, 45, 200)
  for _, cl in ipairs(W.clients) do cl.sim.raceSessionType = nil end
  run(30)
  old[2].stopped = true
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution')
  check(true, 'a race is recognised without sim.raceSessionType')
  W.sessionType = 2
  old = field(4, 45, 200)
  for _, cl in ipairs(W.clients) do cl.sim.raceSessionType = nil end
  run(30)
  old[2].stopped = true
  run(20)
  everyone(GREEN, 'and qualifying is recognised as well')
  W.sessionType = nil

  print('== an error is shown on the screen')
  local cl = W.clients[1]
  cl.sim.carsCount = 'boom'
  cl.env.script.update(DT)
  cl.texts = {}
  cl.env.script.drawUI()
  local shown = false
  for _, tx in ipairs(cl.texts) do shown = shown or tx:find('OVAL error', 1, true) ~= nil end
  check(shown, 'the player and whoever looks at his screen can read what failed')
  W.errors = {} -- that error was on purpose

  print('== no online events at all')
  W.oldApi = { OnlineEvent = true }
  field(4, 45, 200)
  W.oldApi = {}
  run(2)
  local warned = false
  for _, tx in ipairs(W.clients[1].texts) do warned = warned or tx:find('no online events', 1, true) ~= nil end
  check(warned, 'the player is told that the flag cannot reach him')
end

local function kinds(cl) local a = {} for _, p in ipairs(cl.penalties) do a[#a + 1] = p.kind end return table.concat(a, ',') end
local function noteOf(cl) local n = cl.oval.note(); return n and n.title or '' end

local function speeder(cfg, admin)
  local byId = field(8, 45, 200, cfg, admin or 1)
  run(10)
  W.clients[1].chat('!yellow')
  run(1)
  byId[5].over = 25 -- 25 km/h above the limit, but keeps the order
  return byId
end

local function scenarioPenalties()
  print('== penalties: warning, gas cut, drive-through after the green flag (penalty = drive)')
  local byId = speeder({ penalty = 'drive' })
  local y = W.t
  run(45)
  local me = W.clients[5]
  check(kinds(me):sub(1, 8) == 'SlowDown' and me.penalties[1].t - y > 14 and me.penalties[1].param == 5, 'first a warning (no game penalty), then a gas cut of 5 s (' .. kinds(me) .. ')')
  check(not kinds(me):find('MandatoryPits', 1, true) and me.oval.pen().owed == true, 'the third violation does not hand out a drive-through now (the caution is over before it can be served): it is put on the account')
  local shown = false
  for _, tx in ipairs(me.texts) do shown = shown or tx:find('DRIVE-THROUGH DUE AFTER THE GREEN FLAG', 1, true) ~= nil end
  check(shown, 'and the driver is told about it on the screen')
  for id, cl in ipairs(W.clients) do if id ~= 5 then check(#cl.penalties == 0, 'client ' .. id .. ' followed the rules and was not punished') end end
  W.clients[1].chat('!green')
  run(4)
  local last = me.penalties[#me.penalties]
  check(last.kind == 'MandatoryPits' and last.param == 3 and me.oval.pen().driving == true and not me.oval.pen().owed, 'the green flag hands it out: 3 laps to serve')
  shown = false
  for _, tx in ipairs(me.texts) do shown = shown or tx:find('DRIVE-THROUGH: ENTER THE PIT LANE', 1, true) ~= nil end
  check(shown, 'and the screen says what to do')
  byId[5].isInPitlane = true; run(3); byId[5].isInPitlane = false; run(1)
  check(me.oval.pen().driving == false, 'a drive-through is served after a run through the pit lane')

  print('== a black flag for an unserved drive-through is released')
  W.logs = {}
  speeder({ penalty = 'drive' })
  local loaded = false
  for _, m in ipairs(W.logs) do loaded = loaded or m:find('Oval: session laps=', 1, true) ~= nil end
  check(loaded, 'the length of the race (laps or minutes) is logged when the script loads')
  run(45)
  W.clients[1].chat('!green')
  W.logs = {}
  run(4)
  local cl, other = W.clients[5], W.clients[6]
  local seen, where = false, false
  for _, m in ipairs(W.logs) do
    seen = seen or m:find('game penalty 1/3 lap', 1, true) ~= nil
    where = where or m:find('handed out after the green flag (lap ', 1, true) ~= nil
  end
  check(cl.oval.pen().driving == true and seen and where, 'what the game says about the drive-through, and where it was handed out, is in the log')
  cl.car.currentPenaltyType, other.car.currentPenaltyType = 4, 4 -- the game loses patience with both
  run(3)
  check(kinds(cl):sub(-16) == 'ReleaseBlackFlag' and cl.oval.pen().driving == false and noteOf(cl) == 'BLACK FLAG RELEASED', 'the driver of the drive-through is set free again')
  local releases = 0
  for _, p in ipairs(cl.penalties) do if p.kind == 'ReleaseBlackFlag' then releases = releases + 1 end end
  check(releases == 1 and kinds(other) == '', 'once, and a black flag that is not ours is left alone')

  print('== gas cuts do not pile up')
  speeder({ penalty = 'slow', slowSec = 30 })
  run(45)
  local cuts = 0
  for _, p in ipairs(W.clients[5].penalties) do if p.kind == 'SlowDown' then cuts = cuts + 1 end end
  check(cuts == 1 and noteOf(W.clients[5]):find('ALREADY ACTIVE', 1, true), 'a gas cut that is still running is not extended by the next violation (' .. cuts .. ' cut, note: ' .. noteOf(W.clients[5]) .. ')')

  print('== penalty = off: warnings only')
  speeder({ penalty = 'off' })
  run(45)
  check(#W.clients[5].penalties == 0 and noteOf(W.clients[5]):find('WARNING', 1, true), 'nothing is applied to the car, the driver is only warned')

  print('== the default: never more than a gas cut')
  speeder()
  run(45)
  check(kinds(W.clients[5]):find('SlowDown', 1, true) and not kinds(W.clients[5]):find('MandatoryPits', 1, true), 'only gas cuts (' .. kinds(W.clients[5]) .. ')')

  print('== passing the pace car counts double')
  local b2 = field(8, 45, 200, { paceLeadM = 20 }, 1)
  run(10)
  W.clients[1].chat('!yellow')
  b2[1].hold = 106 -- the leader keeps just under the limit and creeps past the pace car
  run(30)
  check(kinds(W.clients[1]):sub(1, 8) == 'SlowDown' and W.clients[1].messages[1]:find('Passed the pace car', 1, true), 'a gas cut at the very first violation: ' .. (W.clients[1].messages[1] or '-'))

  print('== being pushed is no fault')
  speeder()
  local mine = W.clients[5]
  for _ = 1, 25 do W.clients[5].hitcb(0); run(1) end
  check(#mine.penalties == 0 and mine.oval.note() == nil, 'nobody is punished for what happens within three seconds of a contact')
  run(20)
  check(mine.oval.note() ~= nil, 'but the rules apply again when the contacts stop')

  print('== the pit lane is exempt')
  local b3 = speeder()
  b3[5].isInPitlane = true
  run(40)
  check(#W.clients[5].penalties == 0 and W.clients[5].oval.note() == nil, 'nothing happens to a car in the pit lane')

  print('== the game refuses the penalty')
  W.penaltyFails = true
  speeder()
  W.penaltyFails = true
  run(45)
  check(#W.errors == 0 and noteOf(W.clients[5]):find('NOT ENFORCED', 1, true), 'no script error, and the driver is told that it is not enforced')
  W.penaltyFails = false

  print('== jumping the restart')
  local b4 = field(8, 45, 200, { penalty = 'drive' }, 1)
  run(10)
  W.clients[1].chat('!yellow')
  untilTrue(function() return W.clients[2].oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  b4[4].ignore = true
  run(20)
  local jumped = false
  for _, m in ipairs(W.clients[4].messages) do jumped = jumped or m:find('Jumped the restart', 1, true) ~= nil end
  check(jumped and not kinds(W.clients[4]):find('MandatoryPits', 1, true) and W.clients[4].oval.pen().owed == true, 'a warning for the speed, then a drive-through on the account for jumping the restart: ' .. table.concat(W.clients[4].messages, ' | '))
  W.clients[1].chat('!green')
  run(4)
  check(kinds(W.clients[4]):find('MandatoryPits', 1, true) ~= nil, 'and it is handed out as soon as the flag is green')
end

local function scenarioNoScript()
  print('== the lowest session id has no script')
  local byId = field(8, 45, 200, nil, nil, { [1] = true })
  run(30)
  byId[4].stopped = true
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution')
  check(W.clients[1].oval.state().from == 4, 'the caution comes although the controller-to-be runs nothing')
  local pr = W.clients[1].oval.presence()
  check(pr[1] == nil and pr[2] and pr[8], 'the client without the script is not on the list of script users')
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
scenarioPenalties()
scenarioGrid()
scenarioRolling(true)
scenarioRolling(false)
scenarioNotARace()
scenarioLeaderless()
scenarioOldCsp()
scenarioNoScript()
scenarioAuto()
scenarioGiveUp()
scenarioStraggler()
check(#W.errors == 0, 'no script errors' .. (W.errors[1] and (': ' .. W.errors[1]) or ''))
print('all good')
