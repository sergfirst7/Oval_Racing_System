-- DRS World: Oval Racing System v1.4 (FIXED)
-- Fixed driverName function error

local STATE = { GREEN = 1, CAUTION = 2, ONE_TO_GREEN = 3 }
local currentFlag = STATE.GREEN
local targetCarID = -1
local targetCarName = ""
local message = ""
local messageTimer = 0

-- Slow Car Detection
local slowTimers = {}
local yellowCooldown = 0

-- Safety Car / Penalty Logic
local scPos = 0
local scSpeed = 80 / 3.6
local trackLength = ac.getSim().trackLengthM
local overtakeTimer = 0
local penaltyIssued = false

-- Helper to get driver name safely
local function getDriverName(car)
    if not car then return "Unknown" end
    local name = car.driverName
    if type(name) == "function" then return name() end
    return tostring(name)
end

local function safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then ac.log("DRS Oval Error: " .. tostring(err)) end
    end
end

local function getRaceOrder()
    local order = {}
    for i = 0, ac.getSim().carsCount - 1 do
        local car = ac.getCar(i)
        if car and car.isConnected then
            table.insert(order, {
                id = i,
                name = getDriverName(car),
                dist = car.lapCount + car.splinePosition,
                spline = car.splinePosition
            })
        end
    end
    table.sort(order, function(a, b) return a.dist > b.dist end)
    return order
end

function script.update(dt)
    if messageTimer > 0 then messageTimer = messageTimer - dt end
    if yellowCooldown > 0 then yellowCooldown = yellowCooldown - dt end
    
    if currentFlag == STATE.GREEN and yellowCooldown <= 0 then
        for i = 0, ac.getSim().carsCount - 1 do
            local car = ac.getCar(i)
            if car.isConnected and not car.isInPitlane and car.speedKmh < 40 and car.speedKmh > 2 then
                slowTimers[i] = (slowTimers[i] or 0) + dt
                if slowTimers[i] > 3.0 then
                    ac.sendChatMessage("CAUTION: Slow car detected (" .. getDriverName(car) .. ") !yellow")
                    yellowCooldown = 30
                    break
                end
            else
                slowTimers[i] = 0
            end
        end
    end

    if currentFlag ~= STATE.GREEN then
        scPos = (scPos + (scSpeed * dt) / trackLength) % 1
        if targetCarID ~= -1 then
            local me = ac.getCar(0)
            local target = ac.getCar(targetCarID)
            local distDiff = me.splinePosition - target.splinePosition
            if distDiff < -0.5 then distDiff = distDiff + 1 end
            if distDiff > 0.5 then distDiff = distDiff - 1 end
            
            if distDiff > 0.005 then
                overtakeTimer = overtakeTimer + dt
                if overtakeTimer > 2.0 and not penaltyIssued then
                    ac.sendChatMessage("PENALTY: " .. getDriverName(me) .. " ILLEGAL OVERTAKE!")
                    penaltyIssued = true
                end
            else
                overtakeTimer = 0
                penaltyIssued = false
            end
        end
    end
end

ac.onChatMessage(safe(function(msg, senderID)
    local text = msg:lower()
    if string.find(text, "!yellow") then
        currentFlag = STATE.CAUTION
        message = "YELLOW FLAG - CAUTION"
        messageTimer = 5
        penaltyIssued = false
        
        local order = getRaceOrder()
        for i, entry in ipairs(order) do
            if entry.id == 0 then
                if i > 1 then 
                    targetCarID = order[i-1].id
                    targetCarName = order[i-1].name
                else 
                    targetCarID = -1
                    targetCarName = "SAFETY CAR"
                    scPos = entry.spline + 0.02
                end
                break
            end
        end
    elseif string.find(text, "!green") then
        currentFlag = STATE.GREEN
        targetCarID = -1
        message = "GREEN FLAG! GO!"
        messageTimer = 3
    end
end))

function script.drawUI()
    local centerX = ui.windowSize().x / 2
    if currentFlag ~= STATE.GREEN then
        local color = currentFlag == STATE.CAUTION and rgbm(1, 1, 0, 1) or rgbm(1, 0.5, 0, 1)
        ui.drawRectFilled(vec2(centerX - 160, 40), vec2(centerX + 160, 110), color, 5)
        ui.setCursor(vec2(centerX - 110, 55))
        ui.pushFont(ui.Font.Title)
        ui.textColored(" YELLOW FLAG", rgbm(0, 0, 0, 1))
        ui.popFont()
        ui.setCursor(vec2(centerX - 140, 90))
        ui.textColored("FOLLOW: " .. targetCarName, rgbm(0, 0, 0, 1))
    end
end
