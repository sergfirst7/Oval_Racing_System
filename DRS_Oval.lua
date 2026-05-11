-- DRS World: Oval Racing System v1.7 (ROCK SOLID)
-- Switched to ac.getDriverName() for stability

local STATE = { GREEN = 1, CAUTION = 2, ONE_TO_GREEN = 3 }
local currentFlag = STATE.GREEN
local targetCarID = -1
local targetCarName = "NONE"
local message = ""
local messageTimer = 0

-- Slow Car Detection
local slowTimers = {}
local yellowCooldown = 0

-- Safety Car Logic
local scPos = 0 
local scSpeed = 80 / 3.6
local trackLength = ac.getSim().trackLengthM

-- Безопасное получение имени
local function safeName(id)
    local name = ac.getDriverName(id)
    return (name and name ~= "") and name or "Driver #"..id
end

local function triggerCaution()
    if currentFlag ~= STATE.GREEN then return end
    currentFlag = STATE.CAUTION
    message = "YELLOW FLAG - CAUTION"
    messageTimer = 5
    
    local order = {}
    local sim = ac.getSim()
    for i = 0, sim.carsCount - 1 do
        local car = ac.getCar(i)
        if car and car.isConnected then
            table.insert(order, {
                id = i, 
                name = safeName(i), 
                dist = car.lapCount + car.splinePosition, 
                spline = car.splinePosition
            })
        end
    end
    table.sort(order, function(a,b) return a.dist > b.dist end)
    
    targetCarName = "SAFETY CAR"
    targetCarID = -1
    
    for i, entry in ipairs(order) do
        if entry.id == 0 then
            if i > 1 then 
                targetCarID = order[i-1].id
                targetCarName = order[i-1].name
            else 
                scPos = (entry.spline + 50/trackLength) % 1
            end
            break
        end
    end
end

function script.update(dt)
    if messageTimer > 0 then messageTimer = messageTimer - dt end
    if yellowCooldown > 0 then yellowCooldown = yellowCooldown - dt end
    
    if currentFlag == STATE.GREEN and yellowCooldown <= 0 then
        local sim = ac.getSim()
        for i = 0, sim.carsCount - 1 do
            local car = ac.getCar(i)
            if car and car.isConnected and not car.isInPitlane and car.speedKmh < 40 and car.speedKmh > 5 then
                slowTimers[i] = (slowTimers[i] or 0) + dt
                if slowTimers[i] > 3.0 then
                    ac.sendChatMessage("CAUTION: Incident detected! !yellow")
                    triggerCaution()
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
    end
end

ac.onChatMessage(function(msg, senderID)
    local text = msg:lower()
    if string.find(text, "!yellow") then
        triggerCaution()
    elseif string.find(text, "!green") then
        currentFlag = STATE.GREEN
        targetCarID = -1
        targetCarName = "NONE"
    end
end)

function script.drawUI()
    local centerX = ui.windowSize().x / 2
    if currentFlag ~= STATE.GREEN then
        ui.drawRectFilled(vec2(centerX - 160, 40), vec2(centerX + 160, 115), rgbm(1, 1, 0, 1), 5)
        ui.setCursor(vec2(centerX - 110, 55))
        ui.pushFont(ui.Font.Title)
        ui.textColored(" YELLOW FLAG", rgbm(0, 0, 0, 1))
        ui.popFont()
        ui.setCursor(vec2(centerX - 140, 90))
        ui.textColored("FOLLOW: " .. targetCarName, rgbm(0, 0, 0, 1))
        
        if targetCarName == "SAFETY CAR" then
            local me = ac.getCar(0)
            local distToSC = (scPos - me.splinePosition) * trackLength
            if distToSC < -trackLength/2 then distToSC = distToSC + trackLength end
            ui.setCursor(vec2(centerX - 140, 120))
            ui.textColored("SC DISTANCE: " .. math.floor(distToSC) .. "m", rgbm(0,0,0,1))
        end
    end
    ui.setCursor(vec2(10, 10))
    ui.text("DRS Oval v1.7")
end
