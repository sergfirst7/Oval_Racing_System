-- Offline multi-client simulation of oval.lua with a fake CSP API.
-- Run:  luajit tests/sim.lua   (any Lua 5.1+ works)
-- Every simulated client runs its own copy of the script; ac.OnlineEvent messages travel over a
-- fake bus with latency and the 200 ms rate limit of a vanilla acServer.

local TRACK, DT, LATENCY = 2500, 1 / 30, 0.1
local GREEN, CAUTION, ONE_TO_GO = 0, 1, 2

local function frac(x) return x - math.floor(x) end
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end

local W = { t = 0, cars = {}, clients = {}, queue = {}, errors = {}, logs = {}, oldApi = {} } -- t in seconds
local function resetWorld() W.t, W.cars, W.clients, W.queue, W.catchup, W.hold, W.defaults, W.tts, W.clockOffset, W.modelFails, W.ray, W.penaltyFails, W.pitLane = 0, {}, {}, {}, 60, false, { rolling = 0, paceKmh = 100 }, true, 0, false, 'ok', false, nil end

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
local function trackPoint(p) -- world -> track coordinates, the inverse of roadPoint
  return vec3((math.sqrt(p.x ^ 2 + p.z ^ 2) - R) / 10, p.y, frac((math.atan2 or math.atan)(p.z, p.x) / (2 * math.pi)))
end

-- The AI line of a pit lane like the one of an oval (ai/pit_lane.ai): on the road from 0.80, inside the
-- road (30 m from its middle) from 0.87 over the line to 0.08, back on the road at 0.10, ends at 0.15.
local function pitLaneFile()
  local pts, d, prev = {}, 0, nil
  for s = 0.80, 1.15, 2 / TRACK do
    local x = s < 0.85 and 0 or s < 0.87 and -3 * (s - 0.85) / 0.02 or s < 1.08 and -3 or s < 1.10 and -3 * (1.10 - s) / 0.02 or 0
    local p = roadPoint(vec3(x, 0, frac(s)))
    if prev then d = d + math.sqrt((p.x - prev.x) ^ 2 + (p.z - prev.z) ^ 2) end
    pts[#pts + 1], prev = string.pack('<fffff', p.x, p.y, p.z, d, 0), p
  end
  return string.pack('<i4i4i4i4', 7, #pts, 0, 0) .. table.concat(pts)
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
    -- hitcb(other): a contact with car `other` (0 or nil: a wall), as CSP reports it in car.collidedWith
    onCarCollision = function(_, cb) client.hitcb = function(other) car.collidedWith = other or 0; cb(0) end end,
    OnlineEvent = function(layout, cb) -- every key is an event of its own, one rate limit per client
      local key, buf = layout[1], { order = {} }
      client.cbs = client.cbs or {}
      client.cbs[key] = cb
      local function send(_, repeatForNew)
        if W.t - (client.lastSend or -1) < 0.2 then return false end -- vanilla acServer rate limit
        client.lastSend = W.t
        W.sends = (W.sends or 0) + 1
        if key == 'ovalCar9' then W.flagSends = (W.flagSends or 0) + 1 end
        local msg = { order = {} }
        for k, v in pairs(buf) do if k ~= 'order' then msg[k] = v end end
        for i = 0, 47 do msg.order[i] = buf.order[i] end
        if repeatForNew then client.repeatMsg = { key = key, msg = msg } end
        for _, other in ipairs(W.clients) do
          if other.cbs and other.cbs[key] and other.connected then W.queue[#W.queue + 1] = { at = W.t + LATENCY, to = other, from = car, key = key, msg = msg } end
        end
        return true
      end
      return send, function() return buf end
    end,
  }
  for k in pairs(W.oldApi) do env.ac[k] = nil end -- pretend to be a CSP that lacks these functions
  if W.oldApi.structArray then StructItem.array = nil end
  client.texts, client.messages, client.penalties = {}, {}, {}
  local gfx = { loads = {}, lights = {}, meshes = {}, wheels = {}, parts = {} }
  client.gfx = gfx
  local function node()
    local n = {}
    function n:setVisible(v) self.visible = v; return self end
    function n:setPosition(p) self.pos = p; return self end
    function n:setOrientation(look, up) self.look, self.up = look, up; return self end
    function n:loadKN5Async(path, cb) gfx.loads[#gfx.loads + 1] = path; if W.modelFails then cb('no such file') else
      cb(nil, { findNodes = function(_, name) -- the wheels: the right ones are mirrored in the model
        local w = name:match('^WHEEL_(%u%u)$')
        if not w then return { size = function() return 0 end } end
        local raw = { side = { x = w:sub(1, 1) == 'R' and -1 or 1 } }
        function raw:clone() return { side = self.side } end
        function raw:set(m) self.angle = m.angle end
        gfx.wheels[w] = raw
        return { size = function() return 1 end, getTransformationRaw = function() return raw end }
      end, findAny = function(_, name)
        local n = { name = name, visible = true }
        function n:setVisible(v) self.visible = v; return self end
        gfx.parts[name] = n
        return n
      end, findMeshes = function(_, name)
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
  env.ac.worldCoordinateToTrack = trackPoint
  env.ac.getTrackAISplineSides = function() return { x = 10, y = 10 } end -- the road is 20 m wide
  env.ac.getTrackDataFilename = function(name) return 'C:/ac/content/tracks/oval/data/' .. name end
  env.io = { load = function(f) if f == 'C:/ac/content/tracks/oval/ai/pit_lane.ai' then return W.pitLane end end }
  env.mat4x4 = { rotation = function(angle) return { angle = angle, mul = function(self) return self end } end }
  env.physics = { forceUserThrottleFor = function(time, level) -- the script's own gas cut (a penalty), or the limiter (short pulses)
    if W.penaltyFails then error('physics not available') end
    if time < 1 then client.limited = (client.limited or 0) + 1 return end
    client.penalties[#client.penalties + 1] = { kind = 'GasCut', param = time, level = level, t = W.t }
  end, setCarPenalty = function(kind, param)
    if W.penaltyFails then error('physics not available') end
    local name = kind == 1 and 'MandatoryPits' or kind == 3 and 'SlowDown' or kind == 5 and 'ReleaseBlackFlag' or tostring(kind)
    if kind == 3 then error('the game SlowDown penalty must not be used any more') end
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
    if other ~= client and other.repeatMsg and other.connected then W.queue[#W.queue + 1] = { at = W.t + LATENCY, to = client, from = other.car, key = other.repeatMsg.key, msg = other.repeatMsg.msg } end
  end
  return client
end

local function disconnect(client) client.connected, client.car.isConnected, client.car.isActive = false, false, false end

-- A driver who follows the rules: drives a little under the target speed on the HUD and does not
-- run into the car ahead of him in the line (he drives around a car that belongs behind him).
local function target(car, phase, pace, paceKmh, st, l1)
  if car.stopped or (W.hold and W.t < 0) then return 0 end
  if phase == GREEN or car.ignore then return car.cruise end
  if car.hold then return car.hold end
  if car.limp then return car.limp end
  local t = l1 and l1.target and l1.target - 3 or paceKmh - 4
  local ahead, prev = {}, nil
  for _, id in ipairs(st.order) do if id == car.sessionID then break end ahead[id], prev = true, id end
  if l1 and l1.lane == 'out' and prev then ahead[prev] = nil end -- two abreast: he drives up beside his row mate (one lane in this world)
  local gap, aheadKmh = TRACK, paceKmh
  for _, o in ipairs(W.cars) do
    if ahead[o.sessionID] and o.isConnected and not o.isInPitlane and o.speedKmh > 70 then -- a slow car he drives around
      local g = frac(o.splinePosition - car.splinePosition) * TRACK
      if g < gap then gap, aheadKmh = g, o.speedKmh end
    end
  end
  local g = pace and frac(pace - car.splinePosition) * TRACK or TRACK
  if g < gap then gap, aheadKmh = g, paceKmh end
  if gap < 10 then t = math.min(t, aheadKmh - 10) end -- a car is 5 m long, the line runs 0.6 s (17 m) apart
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
    if m.at <= W.t then if m.to.cbs[m.key] then m.to.cbs[m.key](m.from, m.msg) end else rest[#rest + 1] = m end
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
      local want = target(c, st.phase, pace, 100, st, cl.car == c and cl.oval.local1() or nil) / 3.6
      local v = c.speedKmh / 3.6
      v = v < want and math.min(want, v + 5 * DT) or math.max(want, v - 10 * DT)
      c.speedKmh = v * 3.6
      local s = c.splinePosition + v * DT / TRACK
      if s >= 1 then s, c.lapCount = s - 1, c.lapCount + 1 end
      c.splinePosition = s
    end
    c.position = roadPoint(vec3(c.x or 0, 0, c.splinePosition)) -- c.x: across the road, 1 = its right edge (10 m)
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

local function inRaceOrder(order, byId) -- leaders first, by laps and track position
  for i = 2, #order do
    local a, b = byId[order[i - 1]], byId[order[i]]
    if a.lapCount + a.splinePosition < b.lapCount + b.splinePosition then
      print(string.format('     not in race order: %d at %.4f before %d at %.4f', order[i - 1], a.lapCount + a.splinePosition, order[i], b.lapCount + b.splinePosition))
      return false
    end
  end
  return true
end

local function shown(cl, text) -- is the text on the client's screen this frame
  for _, tx in ipairs(cl.texts) do if tx:find(text, 1, true) then return true end end
  return false
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
      if W.t - state.since[id] > 1.5 then state.dirty = state.dirty or string.format('client %d warned for over 1.5 s at t=%d (speeding %s passing %s rel %.0f err %.0f speed %.0f target %.0f ref %s)',
        id, math.floor(W.t), tostring(l.speeding), tostring(l.passing), l.rel or -1, l.err or -1, cl.car.speedKmh, l.target or -1, tostring(l.key)) end
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
  check(not table.concat(W.clients[1].oval.state().order, ','):find('4', 1, true), 'the car standing on track has left the line, the others go on without it')
  local passer = W.clients[5].oval.local1()
  check(passer.key == 3 and #W.clients[5].penalties == 0, 'the car behind it now follows the car ahead of it, unpunished for passing the stopped one')
  byId[4].isInPitlane = true -- it was recovered
  runClean(10)
  byId[6].isInPitlane = true -- another car pits and comes back
  runClean(10)
  byId[6].isInPitlane = false
  runClean(4)
  local sixFlag = W.clients[1].oval.dep().flags[6]
  for _, cl in ipairs(W.clients) do
    local o, rest = cl.oval.state().order, {}
    for _, id in ipairs(o) do if not (sixFlag and id == 6) then rest[#rest + 1] = id end end
    check(#o == 9 and not table.concat(o, ','):find('4', 1, true) and inRaceOrder(rest, byId) and (not sixFlag or o[#o] == 6),
      'client ' .. cl.car.sessionID .. ' order: recovered car dropped, returned car back by the race order, or last if it went into a closed pit lane (' .. table.concat(o, ',') .. (sixFlag and ', car 6 was in a closed pit lane' or '') .. ')')
  end
  check(W.clients[3].oval.state().from == 1, 'the line is ordered by the lowest session id only (last order from ' .. W.clients[3].oval.state().from .. ')')

  local sends0 = W.sends
  untilTrue(function() return W.clients[1].oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  local order, prev, worst = W.clients[1].oval.state().order, nil, 0
  for _, id in ipairs(order) do
    if prev then worst = math.max(worst, math.abs(frac(prev.splinePosition - byId[id].splinePosition + 0.5) - 0.5) * TRACK) end -- two abreast: the row mate may be a metre ahead
    prev = byId[id]
  end
  print(string.format('     one to go after %.0f s of caution, widest gap in the pack %.0f m', W.t - cautionAt, worst))
  -- green after the pit cycle and one more lap: 2.3..3.3 pace laps of 90 s, one to go a quarter of a lap before that
  check(W.t - cautionAt > 180 and W.t - cautionAt < 280, 'two to three pace laps, although a car stood on track: one to go after ' .. string.format('%.0f', W.t - cautionAt) .. ' s')
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
  print('== the restart does not wait for a straggler, he is told to speed up')
  local byId = field(8, 45, 200, { catchupKmh = 20 })
  local straggler = addCar(9, 0.5 - 8 * 45 / TRACK - 1200 / TRACK, 200)
  local sc = addClient(straggler, false, { catchupKmh = 20 })
  run(30)
  byId[1].stopped = true
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution')
  local at = W.t
  byId[1].isInPitlane = true
  run(20)
  check(shown(sc, 'ДОДАЙ') and sc.oval.local1().target > 115, 'the straggler sees SPEED UP and a target above the pace (' .. math.floor(sc.oval.local1().target) .. ' km/h)')
  untilTrue(function() return W.clients[2].oval.state().phase == GREEN end, 400, 'the green flag')
  print(string.format('     green after %.0f s of caution', W.t - at))
  check(W.t - at < 250, 'green after at most 2.5 pace laps, although the straggler is still far back')
end

local function scenarioGiveUp()
  print('== a car that never moves again does not make the caution longer')
  local byId = field(6, 45, 200)
  run(30)
  byId[3].stopped = true
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 30, 'the caution')
  local at = W.t
  run(10)
  check(W.clients[3].oval.local1().out == true and shown(W.clients[3], 'ПОЗА КОЛОНОЮ'), 'the stopped car is out of the line and its driver is told so')
  untilTrue(function() return W.clients[1].oval.state().phase == GREEN end, 400, 'the green flag')
  check(W.t - at > 130 and W.t - at < 250, 'green after about two pace laps (' .. math.floor(W.t - at) .. ' s), the car is still standing')
  byId[3].stopped = false
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
  byId[5].speedKmh = 250; W.clients[5].hitcb(4)
  byId[5].speedKmh, byId[5].cruise = 140, 140 -- a hard hit by car 4 that leaves the car rolling at 140 km/h
  local t0 = W.t
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 5, 'the wreck caution')
  local st = W.clients[1].oval.state()
  check(st.reason == 3 and st.cause == 5 and st.from == 5 and W.t - t0 < 1.5, 'a hit by another car is a wreck at once, reported by the car itself (' .. string.format('%.1f', W.t - t0) .. ' s)')

  print('== a crash on its own')
  byId = field(8, 45, 250)
  run(30)
  W.clients[4].hitcb(0); byId[4].speedKmh, byId[4].cruise = 120, 120 -- into the wall, 130 km/h lost, goes on at 120
  run(15)
  everyone(GREEN, 'a car that hits the wall on its own and drives on calls no caution')
  byId[4].cruise = 250
  run(10)
  W.clients[4].hitcb(0); byId[4].speedKmh, byId[4].x, byId[4].stopped = 60, 1.5, true -- spins off and stops 5 m beyond the edge of the road
  run(25)
  everyone(GREEN, 'off the road, where it endangers nobody, it calls no caution however long it stands')
  byId[4].x = 0.9 -- now it rolls back down onto the road and stands there
  local t2 = W.t
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 15, 'the caution for the car on the road')
  st = W.clients[1].oval.state()
  check(st.reason == 1 and st.cause == 4 and W.t - t2 > 2, 'standing on the road it calls the caution after stopSec (' .. string.format('%.1f', W.t - t2) .. ' s)')

  print('== a crash on its own that stops on the road')
  byId = field(8, 45, 250)
  run(30)
  byId[3].speedKmh, byId[3].stopped = 100, true -- spins on the road, no contact at all
  t2 = W.t
  untilTrue(function() return W.clients[1].oval.state().phase == CAUTION end, 15, 'the caution for the spun car')
  check(W.clients[1].oval.state().cause == 3 and W.t - t2 > 2, 'no caution at the spin itself, but once it stands on the road (' .. string.format('%.1f', W.t - t2) .. ' s)')

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
  W.clients[3].hitcb(2); byId[3].speedKmh, byId[3].cruise = 90, 90
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

local function scenarioPitLane()
  print('== the pace car comes out of the pit lane when the pit exit is clear ahead, and goes back in, its wheels turn')
  resetWorld()
  W.pitLane = pitLaneFile()
  for i = 1, 6 do addCar(i, 0.88 - (i - 1) * 45 / TRACK, 200) end -- the leader at 0.90 at the yellow: the pit exit (0.088) 470 m ahead, past his braking room
  local cars = {}
  for i, c in ipairs(W.cars) do cars[i] = c end
  for _, c in ipairs(cars) do addClient(c, c.sessionID == 1) end
  run(1)
  local said = table.concat(W.logs, ' ')
  check(said:find('Oval: pit lane', 1, true) ~= nil, 'the pit lane is found in the track files: ' .. (said:match('Oval: pit lane[^O]*') or '-'))
  local cl = W.clients[2]
  W.clients[1].chat('!yellow')
  run(0.3)
  local gfx, node = cl.gfx, function() return cl.gfx.node end
  local function offRoad() local t = trackPoint(node().pos); return math.abs(t.x) * 10 end -- metres from the middle of the road
  check(math.abs(cl.oval.state().s0 - 0.088) < 0.005, string.format('it starts at the pit exit (%.3f)', cl.oval.state().s0))
  check(node().visible and offRoad() > 10, 'it comes out of the end of the pit lane, beyond the edge of the road (' .. math.floor(offRoad()) .. ' m from the middle of the road)')
  local w = gfx.wheels
  local seenSpin = false
  untilTrue(function()
    local a = w.LF.angle
    step()
    seenSpin = seenSpin or (w.LF.angle ~= a and (w.LF.angle > 0) ~= (w.RF.angle > 0))
    return offRoad() < 1
  end, 4, 'the pace car on the road')
  check(seenSpin, 'and joins the road with turning wheels (the mirrored right ones the other way round in the model)')
  check((cl.env.render.calls.debugArrow or 0) == 0 and not shown(cl, 'БОКСІВ'), 'no arrow and no "out of the pits" text: the SAFETY CAR label over the car is all')
  check(gfx.parts.RIM_BLUR_LF.visible and not gfx.parts.RIM_LF.visible, 'at speed the blurred rims are shown')
  run(5)
  local s = cl.oval.pacePos()
  check(math.abs(trackPoint(node().pos).z - s) < 1e-3 and offRoad() < 0.5, 'then it drives on its synced point on the road')
  untilTrue(function() return cl.oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  local st = cl.oval.state()
  check(math.abs(st.s0 - 0.80) < 0.01, string.format('one to go when it gets to the pit entry, not at 0.75 of the lap (%.3f)', st.s0))
  local inPit = false
  untilTrue(function() inPit = inPit or (node().visible and offRoad() > 25); return not node().visible end, 120, 'the pace car gone')
  check(inPit, 'it turns into the pit lane and is gone once it has stopped there')
  check(#W.errors == 0, 'no script errors' .. (W.errors[1] and (': ' .. W.errors[1]) or ''))

  print('== the pit exit is too far ahead: the pace car is on the road at once')
  resetWorld()
  W.pitLane = pitLaneFile()
  for i = 1, 6 do addCar(i, 0.55 - (i - 1) * 45 / TRACK, 200) end
  for _, c in ipairs({ table.unpack(W.cars) }) do addClient(c, c.sessionID == 1) end
  run(1)
  W.clients[1].chat('!yellow')
  run(0.3)
  cl = W.clients[2]
  check(cl.gfx.node.visible and math.abs(trackPoint(cl.gfx.node.pos).x) < 0.05 and math.abs(trackPoint(cl.gfx.node.pos).z - cl.oval.pacePos()) < 1e-3, 'it stands on its point on the road, not in the pit lane')
end

-- metres a car needs to slow down to the pace at 3 m/s2, plus 50 (the rule of the script)
local function brakeRoom(kmh) local v, p = kmh / 3.6, 100 / 3.6; return (v > p and (v * v - p * p) / 6 or 0) + 50 end

local function scenarioClearRoad()
  print('== the pace car never appears close in front of a fast car')
  resetWorld()
  for i = 1, 6 do addCar(i, 0.5 - (i - 1) * 45 / TRACK, 250) end
  addCar(7, 0.5 + 300 / TRACK, 250, { lapCount = -1 }) -- a lapped car 300 m ahead of the leader on the road, where the pace car used to appear
  addCar(8, 0.5 + 700 / TRACK, 240, { lapCount = -1 })
  for _, c in ipairs({ table.unpack(W.cars) }) do addClient(c, c.sessionID == 1) end
  run(2)
  local speeds = {}
  for _, c in ipairs(W.cars) do speeds[c.sessionID] = c.speedKmh end
  W.clients[1].chat('!yellow')
  local s0 = W.clients[1].oval.state().s0
  local worst, who = 1e9, nil
  for _, c in ipairs(W.cars) do
    local room = frac(s0 - c.splinePosition) * TRACK - brakeRoom(speeds[c.sessionID])
    if room < worst then worst, who = room, c.sessionID end
  end
  check(worst >= 0, string.format('every car has its braking room behind the pace car (tightest: car %d, %.0f m to spare)', who, worst))
  check(frac(s0 - 0.5) * TRACK > 700, 'it appears past both lapped cars (' .. math.floor(frac(s0 - 0.5) * TRACK) .. ' m ahead of the leader)')
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
  for _, tx in ipairs(W.clients[1].texts) do warned2 = warned2 or tx:find('немає online events', 1, true) ~= nil end
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
  for _, tx in ipairs(cl.texts) do shown = shown or tx:find('OVAL помилка', 1, true) ~= nil end
  check(shown, 'the player and whoever looks at his screen can read what failed')
  W.errors = {} -- that error was on purpose

  print('== no online events at all')
  W.oldApi = { OnlineEvent = true }
  field(4, 45, 200)
  W.oldApi = {}
  run(2)
  local warned = false
  for _, tx in ipairs(W.clients[1].texts) do warned = warned or tx:find('немає online events', 1, true) ~= nil end
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
  print('== penalties (the defaults): a warning, then gas cuts, never a drive-through')
  local byId = speeder()
  local y = W.t
  run(45)
  local me = W.clients[5]
  check(kinds(me):sub(1, 6) == 'GasCut' and me.penalties[1].t - y > 8 and me.penalties[1].param == 5 and me.penalties[1].level == 0, 'first a warning, then a gas cut: the throttle forced to 0 for 5 s (' .. kinds(me) .. string.format(', first after %.1f s', (me.penalties[1] or { t = 0 }).t - y) .. ', ' .. table.concat(me.messages, ' | ') .. ')')
  check(me.oval.pen().strikes >= 3 and not kinds(me):find('MandatoryPits', 1, true) and not kinds(me):find('BlackFlag', 1, true), 'three violations and more: still only gas cuts (' .. kinds(me) .. ')')
  for id, cl in ipairs(W.clients) do if id ~= 5 then check(#cl.penalties == 0, 'client ' .. id .. ' followed the rules and was not punished') end end
  check((me.limited or 0) > 30, 'the limiter cut the gas of the car that was too fast (' .. (me.limited or 0) .. ' pulses)')
  W.clients[1].chat('!green')
  run(1)
  local pulses = me.limited
  run(5)
  check(me.limited == pulses and not kinds(me):find('MandatoryPits', 1, true), 'and lets go of it on the green flag, nothing is handed out after it')

  print('== a black flag is taken back at once, whatever gave it')
  W.logs = {}
  speeder({ penalty = 'drive' }) -- an old server config: the same as slow now
  local loaded = false
  for _, m in ipairs(W.logs) do loaded = loaded or m:find('Oval: session laps=', 1, true) ~= nil end
  check(loaded, 'the length of the race (laps or minutes) is logged when the script loads')
  run(45)
  check(not kinds(W.clients[5]):find('MandatoryPits', 1, true), 'penalty = drive from an old config hands out no drive-through')
  W.clients[1].chat('!green')
  run(2)
  local cl, other = W.clients[5], W.clients[6]
  cl.car.currentPenaltyType, other.car.currentPenaltyType = 4, 4 -- the game shows the black flag to two cars
  W.logs = {}
  run(3)
  local seen = false
  for _, m in ipairs(W.logs) do seen = seen or m:find('game penalty 4/', 1, true) ~= nil end
  check(seen, 'what the game says about penalties is in the log')
  check(kinds(cl):sub(-16) == 'ReleaseBlackFlag' and kinds(other) == 'ReleaseBlackFlag' and noteOf(other) == 'ЧОРНИЙ ПРАПОР ЗНЯТО', 'both are set free and told so: ' .. kinds(other))
  local releases = 0
  for _, p in ipairs(other.penalties) do if p.kind == 'ReleaseBlackFlag' then releases = releases + 1 end end
  check(releases == 1, 'once, the flag is gone then')

  print('== gas cuts do not pile up')
  speeder({ penalty = 'slow', slowSec = 30 })
  run(40) -- the first cut comes after 10 s, it runs for 30
  local cuts = 0
  for _, p in ipairs(W.clients[5].penalties) do if p.kind == 'GasCut' then cuts = cuts + 1 end end
  check(cuts == 1 and noteOf(W.clients[5]):find('ВЖЕ ДІЄ', 1, true), 'a gas cut that is still running is not extended by the next violation (' .. cuts .. ' cut, note: ' .. noteOf(W.clients[5]) .. ')')

  print('== penalty = off: warnings only')
  speeder({ penalty = 'off' })
  run(45)
  check(#W.clients[5].penalties == 0 and noteOf(W.clients[5]):find('ПОПЕРЕДЖЕННЯ', 1, true), 'nothing is applied to the car, the driver is only warned')

  print('== penalty = slow: never more than a gas cut')
  speeder({ penalty = 'slow' })
  run(45)
  check(kinds(W.clients[5]):find('GasCut', 1, true) and not kinds(W.clients[5]):find('MandatoryPits', 1, true), 'only gas cuts (' .. kinds(W.clients[5]) .. ')')

  print('== passing the pace car counts double')
  local b2 = field(8, 45, 100, { paceLeadM = 20 }, 1) -- at the pace speed: the pace car appears 50 m ahead
  run(10)
  W.clients[1].chat('!yellow')
  b2[1].hold = 125 -- the leader drives past the pace car while the others still slow down
  run(30)
  check(kinds(W.clients[1]):sub(1, 6) == 'GasCut' and W.clients[1].messages[1]:find('Обгін safety car', 1, true), 'a gas cut at the very first violation: ' .. (W.clients[1].messages[1] or '-'))

  print('== being pushed is no fault')
  speeder()
  local mine = W.clients[5]
  for _ = 1, 25 do W.clients[5].hitcb(0); run(1) end
  check(#mine.penalties == 0 and mine.oval.note() == nil, 'nobody is punished for what happens within three seconds of a contact')
  run(20)
  check(mine.oval.note() ~= nil, 'but the rules apply again when the contacts stop')

  print('== the pit lane is exempt from the pace rules')
  local b3 = speeder()
  b3[5].isInPitlane = true
  run(40)
  check(#W.clients[5].penalties == 0 and noteOf(W.clients[5]) ~= '' and not noteOf(W.clients[5]):find('ПОПЕРЕДЖЕННЯ', 1, true) and W.clients[5].oval.pen().strikes == 0,
    'no strike and no gas cut for a car in the pit lane (only the closed pit lane note: ' .. noteOf(W.clients[5]) .. ')')

  print('== the game refuses the penalty')
  W.penaltyFails = true
  speeder()
  W.penaltyFails = true
  run(45)
  check(#W.errors == 0 and noteOf(W.clients[5]):find('НЕ ЗАСТОСОВАНО', 1, true), 'no script error, and the driver is told that it is not enforced')
  W.penaltyFails = false

  print('== jumping the restart')
  local b4 = field(8, 45, 200, { penalty = 'drive' }, 1)
  run(10)
  W.clients[1].chat('!yellow')
  untilTrue(function() return W.clients[2].oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  b4[4].ignore = true
  run(20)
  local jumped = false
  for _, m in ipairs(W.clients[4].messages) do jumped = jumped or m:find('Фальстарт на рестарті', 1, true) ~= nil end
  check(jumped and kinds(W.clients[4]):find('GasCut', 1, true) and not kinds(W.clients[4]):find('MandatoryPits', 1, true), 'jumping the restart costs a gas cut, nothing more: ' .. table.concat(W.clients[4].messages, ' | '))
end

local function lineOnRoad(order, byId) -- every car of the line is behind the one before it on the road
  for i = 2, #order do
    local d = frac(byId[order[i - 1]].splinePosition - byId[order[i]].splinePosition + 0.5) - 0.5
    if d * TRACK < -12 then return false end -- two abreast: the row mate may be a few metres ahead
  end
  return true
end

local function scenarioLapped()
  print('== a lapped car goes to the back of the line, everybody is told whom to pass and whom to let by')
  local byId = field(6, 45, 200, nil, 1)
  byId[7] = addCar(7, 0.5 - 2.5 * 45 / TRACK, 200, { lapCount = -1 }) -- between cars 3 and 4 on the road, a lap down
  local lc = addClient(byId[7], false)
  run(10)
  W.clients[1].chat('!yellow')
  run(1)
  local o = W.clients[1].oval.state().order
  check(table.concat(o, ',') == '1,2,3,4,5,6,7', 'the line is the race order, the lapped car last (' .. table.concat(o, ',') .. ')')
  check(lc.oval.local1().place == 7 and lc.oval.info().why:find('7 З 7', 1, true), 'the lapped driver is told his place: ' .. lc.oval.info().why)
  check(W.clients[4].oval.info().title == 'ЇДЬ ЗА car3', 'and the others whom to follow: ' .. W.clients[4].oval.info().title)
  local passSeen, letSeen = false, false
  for _ = 1, math.floor(30 / DT) do
    step()
    passSeen = passSeen or shown(W.clients[4], 'ОБЖЕНИ  car7')
    letSeen = letSeen or shown(lc, 'ПРОПУСТИ car4')
  end
  check(passSeen and letSeen, 'car 4 is told to pass the lapped car, the lapped car to let it by')
  untilTrue(function() return W.clients[1].oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  check(lineOnRoad(o, byId), 'at one to go the cars stand on the road in the order of the line')
  for _, cl in ipairs(W.clients) do check(#cl.penalties == 0, 'client ' .. cl.car.sessionID .. ' was not penalised for the reshuffle') end
end

local function scenarioDomino()
  print('== one car brakes in the line: no pile-up behind it')
  for _, slowTo in ipairs({ 40, 80 }) do
    local byId = field(8, 45, 200, nil, 1)
    run(10)
    W.clients[1].chat('!yellow')
    run(60)
    local o = W.clients[1].oval.state().order
    byId[3].limp = slowTo
    local minSpeed, minGap = 999, 999
    for _ = 1, math.floor(8 / DT) do
      step()
      for i = 4, 8 do minSpeed = math.min(minSpeed, byId[o[i]].speedKmh) end
      for i = 2, #o do
        local a, b = byId[o[i - 1]], byId[o[i]]
        if a.speedKmh > 70 and b.speedKmh > 70 then minGap = math.min(minGap, frac(a.splinePosition - b.splinePosition) * TRACK) end
      end
    end
    byId[3].limp = nil
    print(string.format('     car 3 at %d km/h: the cars behind it never below %.0f km/h, closest gap %.0f m', slowTo, minSpeed, minGap))
    check(minSpeed > slowTo - 5 and minSpeed > 65 and minGap > 8, 'nobody behind it brakes hard or runs into the next car (car 3 at ' .. slowTo .. ' km/h)')
  end
end

local function lappedField(pitLane) -- six cars on the lead lap, two a lap down at the back; car 1 is the admin
  resetWorld()
  W.pitLane = pitLane and pitLaneFile() or nil
  local byId = {}
  for i = 1, 6 do byId[i] = addCar(i, 0.40 - (i - 1) * 45 / TRACK, 200) end
  byId[7] = addCar(7, 0.40 - 6 * 45 / TRACK, 200, { lapCount = -1 })
  byId[8] = addCar(8, 0.40 - 7 * 45 / TRACK, 200, { lapCount = -1 })
  for i = 1, 8 do addClient(byId[i], i == 1) end
  run(2)
  W.clients[1].chat('!yellow')
  run(1)
  return byId
end
local function flagOf(cl, id) local f = W.clients[cl].oval.dep().flags[id]; return f and f.kind or 0 end

local function scenarioPitRules()
  print('== the pit lane under a caution: closed, then open for the lead lap, then for everybody')
  local byId = lappedField(true)
  local cl = W.clients[1]
  check(cl.oval.pitWindow() == 0 and shown(W.clients[3], 'ПІТ-ЛЕЙН ЗАКРИТО'), 'closed when the pace car comes out, and the HUD says so')
  byId[3].isInPitlane = true -- dives in at once
  run(1)
  check(flagOf(3, 3) == 1 and noteOf(W.clients[3]) == 'ПІТ-ЛЕЙН ЗАКРИТО' and #W.clients[3].penalties == 0, 'a car that goes into the closed pit lane is sent to the back of the line, nothing else')
  run(5); byId[3].isInPitlane = false
  run(3)
  for _, c in ipairs(W.clients) do
    local o = c.oval.state().order
    check(o[#o] == 3 and flagOf(c.car.sessionID, 3) == 1, 'client ' .. c.car.sessionID .. ' has it at the back, behind the lapped cars (' .. table.concat(o, ',') .. ')')
  end
  check(shown(W.clients[3], 'РЕСТАРТ З КІНЦЯ КОЛОНИ'), 'and its driver is told why')
  untilTrue(function() return cl.oval.pitWindow() == 1 end, 200, 'the pit lane open for the lead lap')
  check(shown(W.clients[2], 'ПІТ-ЛЕЙН ВІДКРИТО ДЛЯ ЛІДЕРСЬКОГО КОЛА') and shown(W.clients[7], 'ТОБІ ЩЕ ЗАКРИТО'), 'the HUD says who may come in')
  byId[2].isInPitlane, byId[8].isInPitlane = true, true
  run(1)
  check(flagOf(2, 2) == 0 and flagOf(8, 8) == 1, 'a car on the lead lap may come in now, a lapped car may not')
  byId[2].isInPitlane, byId[8].isInPitlane = false, false
  untilTrue(function() return cl.oval.pitWindow() == 2 end, 200, 'the pit lane open for everybody')
  byId[7].isInPitlane = true
  run(1)
  check(flagOf(7, 7) == 0 and shown(W.clients[7], 'ПІТ-ЛЕЙН ВІДКРИТО'), 'then the lapped cars may come in too')
  byId[7].isInPitlane = false
  untilTrue(function() return cl.oval.state().phase == GREEN end, 300, 'the green flag')
  for _, c in ipairs(W.clients) do check(#c.penalties == 0, 'client ' .. c.car.sessionID .. ' got no penalty') end
  check(next(cl.oval.dep().flags) == nil, 'the green flag clears the list')
end

local function scenarioWave()
  print('== the last lap: the lucky dog and a wave-around go round the field, the line doubles up')
  local byId = lappedField(false)
  local cl = W.clients[1]
  untilTrue(function() return cl.oval.pitWindow() == 1 end, 200, 'the pit lane open for the lead lap')
  byId[1].isInPitlane = true -- the leader pits, the lapped cars stay out
  run(4); byId[1].isInPitlane = false
  check(W.clients[2].oval.local1().lane == nil, 'single file before the last lap')
  untilTrue(function() return W.clients[7].oval.dep().me.wave ~= nil end, 300, 'the last lap')
  run(0.5)
  check(W.clients[7].oval.dep().me.wave == 'LUCKY DOG' and W.clients[8].oval.dep().me.wave == 'WAVE AROUND', 'the first lapped car is the lucky dog, the other one stayed out while the leader pitted: a wave-around')
  check(W.clients[6].oval.dep().me.wave == nil and shown(W.clients[7], 'LUCKY DOG'), 'a car on the lead lap does not go, the lucky dog is told to')
  run(1)
  for _, c in ipairs(W.clients) do
    local o = table.concat(c.oval.state().order, ',')
    check(not o:find('7', 1, true) and not o:find('8', 1, true), 'client ' .. c.car.sessionID .. ': both are out of the line while they go round (' .. o .. ')')
  end
  check(W.clients[2].oval.local1().lane == 'out' and W.clients[3].oval.local1().lane == 'in', 'the line doubles up: odd places inside, even places outside')
  for _, id in ipairs({ 7, 8 }) do byId[id].ignore, byId[id].cruise = true, 230 end -- flat out round the track
  local o7 = byId[7].lapCount + byId[7].splinePosition
  untilTrue(function() return flagOf(1, 7) == 1 and flagOf(1, 8) == 1 end, 120, 'both back at the end of the line')
  for _, id in ipairs({ 7, 8 }) do byId[id].ignore = false end
  check(byId[7].lapCount + byId[7].splinePosition - o7 > 1, 'the lucky dog drove a lap more than the field: its lap is back')
  run(1)
  local o = cl.oval.state().order
  check(o[#o - 1] == 7 and o[#o] == 8, 'they line up at the very end, in the order they came (' .. table.concat(o, ',') .. ')')
  untilTrue(function() return cl.oval.state().phase == ONE_TO_GO end, 120, 'one to go')
  o = cl.oval.state().order
  local function apart(a, b) return math.abs(frac(byId[a].splinePosition - byId[b].splinePosition + 0.5) - 0.5) * TRACK end
  check(apart(o[1], o[2]) < 12 and apart(o[3], o[4]) < 12, string.format('two abreast at one to go (rows %.0f m and %.0f m)', apart(o[1], o[2]), apart(o[3], o[4])))
  untilTrue(function() return cl.oval.state().phase == GREEN end, 120, 'the green flag')
  for _, c in ipairs(W.clients) do check(#c.penalties == 0, 'client ' .. c.car.sessionID .. ' got no penalty for the wave or the rows') end
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
  local o = W.clients[1].oval.state().order
  check(#o == 7 and not table.concat(o, ','):find('4', 1, true) and inRaceOrder(o, byId), 'the order is kept up by the next client in line (' .. table.concat(o, ',') .. ')')
  untilTrue(function() return W.clients[1].oval.state().phase == ONE_TO_GO end, 400, 'one to go')
  untilTrue(function() return W.clients[1].oval.state().phase == GREEN end, 200, 'the green flag')
  check(true, 'one to go and green happen too')
end

local function scenarioHud()
  print('== the player drags the boxes (!hud)')
  field(4, 45, 200, nil, 1)
  run(2)
  local cl = W.clients[2]
  check(cl.chat('!hud') == true, '!hud is handled (kept out of chat)')
  local ui = cl.env.ui
  ui.mousePos = function() return { x = 960, y = 150 } end -- inside the top panel
  ui.mouseClicked = function() return true end
  ui.mouseDown = function() return true end
  ui.mouseDelta = function() return { x = 19.2, y = 10.8 } end
  run(0.5)
  local hud = cl.oval.hud()
  check(hud.topX > 0.52 and hud.topY > 50 / 1080 + 0.02 and hud.noteX == 0.5 and hud.noteY == 0.3,
    string.format('the top panel follows the mouse, the other boxes stay (top %.3f %.3f)', hud.topX, hud.topY))
  check(shown(cl, 'ПЕРЕТЯГНИ МИШЕЮ') and shown(cl, 'ЇДЬ ЗА Ivanov') and shown(cl, 'МІСЦЕ  '), 'the hint and a sample of every box are shown')
  ui.mouseDown = function() return false end
  local x = hud.topX
  run(0.5)
  check(hud.topX == x, 'released: the panel stays where it was put')
  cl.chat('!hud')
  ui.mousePos, ui.mouseClicked, ui.mouseDown, ui.mouseDelta = nil, nil, nil, nil
  run(0.5)
  check(not shown(cl, 'ПЕРЕТЯГНИ МИШЕЮ') and not shown(cl, 'ЇДЬ ЗА Ivanov'), '!hud again: the samples are gone')
end

scenarioManual()
scenarioWreck()
scenarioModel()
scenarioPitLane()
scenarioClearRoad()
scenarioPitRules()
scenarioWave()
scenarioPenalties()
scenarioGrid()
scenarioRolling(true)
scenarioRolling(false)
scenarioNotARace()
scenarioLeaderless()
scenarioOldCsp()
scenarioNoScript()
scenarioAuto()
scenarioLapped()
scenarioDomino()
scenarioGiveUp()
scenarioStraggler()
scenarioHud()
check(#W.errors == 0, 'no script errors' .. (W.errors[1] and (': ' .. W.errors[1]) or ''))
print('all good')
