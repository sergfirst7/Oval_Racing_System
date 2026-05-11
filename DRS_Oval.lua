-- DRS World: Oval Racing System v1.9 (FINALE)
-- Perfect UI Centering + Auto-Restart (2 Laps)

local STATE = { GREEN = 1, CAUTION = 2, ONE_TO_GREEN = 3 }
local currentFlag = STATE.GREEN
local targetCarID = -1
local targetCarName = "NONE"
local message = ""
local messageTimer = 0

-- Caution Tracking
local yellowCooldown = 0
local slowTimers = {}
local cautionStartLap = 0

-- Safety Car Logic
local scPos = 0 
local scSpeed = 80 / 3.6
local trackLength = ac.getSim().trackLengthM
local scOvertakeTimer = 0

local function safeName(id)
    local name = ac.getDriverName(id)
    return (name and name ~= "") and name or "Driver #"..id
end

local function triggerCaution()
    if currentFlag ~= STATE.GREEN then return end
    currentFlag = STATE.CAUTION
    message = "YELLOW FLAG"
    messageTimer = 5
    cautionStartLap = ac.getCar(0).lapCount
    
    local order = {}
    for i = 0, ac.getSim().carsCount - 1 do
        local car = ac.getCar(i)
        if car and car.isConnected then
            table.insert(order, {id=i, name=safeName(i), dist=car.lapCount + car.splinePosition, spline=car.splinePosition})
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
                scPos = (entry.spline + 60/trackLength) % 1
            end
            break
        end
    end
end

function script.update(dt)
    if messageTimer > 0 then messageTimer = messageTimer - dt end
    if yellowCooldown > 0 then yellowCooldown = yellowCooldown - dt end
    
    local me = ac.getCar(0)
    
    -- АВТО-ДЕТЕКТОР
    if currentFlag == STATE.GREEN and yellowCooldown <= 0 then
        for i = 0, ac.getSim().carsCount - 1 do
            local car = ac.getCar(i)
            if car and car.isConnected and not car.isInPitlane and car.speedKmh < 40 then
                slowTimers[i] = (slowTimers[i] or 0) + dt
                if slowTimers[i] > 3.0 then
                    ac.sendChatMessage("CAUTION: Incident detected! !yellow")
                    triggerCaution()
                    yellowCooldown = 60
                    break
                end
            else
                slowTimers[i] = 0
            end
        end
    end

    -- ЛОГИКА РЕСТАРТА (2 круга)
    if currentFlag ~= STATE.GREEN then
        scPos = (scPos + (scSpeed * dt) / trackLength) % 1
        
        local lapsPassed = me.lapCount - cautionStartLap
        if lapsPassed >= 2 and currentFlag ~= STATE.GREEN then
            currentFlag = STATE.GREEN
            targetCarID = -1
            message = "GREEN FLAG! GO!"
            messageTimer = 5
            ac.sendChatMessage("GREEN FLAG! GO! !green")
        elseif lapsPassed >= 1.5 and currentFlag == STATE.CAUTION then
            currentFlag = STATE.ONE_TO_GREEN
            ac.sendChatMessage("ONE TO GREEN - PREPARE!")
        end

        -- Овертейк
        if targetCarName == "SAFETY CAR" then
            local distToSC = (scPos - me.splinePosition) * trackLength
            if distToSC < -trackLength/2 then distToSC = distToSC + trackLength end
            if distToSC < -2 then
                scOvertakeTimer = scOvertakeTimer + dt
                if scOvertakeTimer > 3.0 then
                    ac.sendChatMessage("PENALTY: " .. safeName(0) .. " OVERTOOK SAFETY CAR!")
                    scOvertakeTimer = -10
                end
            else
                scOvertakeTimer = math.max(0, scOvertakeTimer - dt)
            end
        end
    end
end

ac.onChatMessage(function(msg, senderID)
    local text = msg:lower()
    if string.find(text, "!yellow") then triggerCaution()
    elseif string.find(text, "!green") then 
        currentFlag = STATE.GREEN 
        message = "GREEN FLAG! GO!"
        messageTimer = 5
    end
end)

function script.drawUI()
    local centerX = ui.windowSize().x / 2
    
    if currentFlag ~= STATE.GREEN then
        local boxW = 400
        ui.drawRectFilled(vec2(centerX - boxW/2, 40), vec2(centerX + boxW/2, 145), rgbm(1, 1, 0, 1), 12)
        
        -- Центрированный заголовок
        local title = currentFlag == STATE.ONE_TO_GREEN and "ONE TO GREEN" or "YELLOW FLAG"
        local titleSize = ui.measureText(title)
        ui.setCursor(vec2(centerX - titleSize.x/2, 50))
        ui.pushFont(ui.Font.Main)
        ui.textColored(title, rgbm(0, 0, 0, 1))
        ui.popFont()
        
        -- Центрированный Follow
        local followText = "FOLLOW: " .. targetCarName
        local followSize = ui.measureText(followText)
        ui.setCursor(vec2(centerX - followSize.x/2, 75))
        ui.textColored(followText, rgbm(0, 0, 0, 1))
        
        -- Дистанция
        if targetCarName == "SAFETY CAR" then
            local me = ac.getCar(0)
            local distToSC = (scPos - me.splinePosition) * trackLength
            if distToSC < -trackLength/2 then distToSC = distToSC + trackLength end
            
            local dText = "DISTANCE: " .. math.floor(distToSC) .. "m"
            ui.setCursor(vec2(centerX - 100, 105))
            ui.pushFont(ui.Font.Title)
            local dColor = (distToSC < 15 or distToSC > 60) and rgbm(1, 0, 0, 1) or rgbm(0, 0.6, 0, 1)
            ui.textColored(dText, dColor)
            ui.popFont()
            
            if scOvertakeTimer > 0 then
                ui.drawRectFilled(vec2(centerX - 250, 155), vec2(centerX + 250, 205), rgbm(1, 0, 0, 0.9), 5)
                ui.setCursor(vec2(centerX - 230, 165))
                ui.pushFont(ui.Font.Title)
                ui.textColored("REDUCE SPEED! PENALTY: " .. string.format("%.1f", 3.0 - scOvertakeTimer) .. "s", rgbm(1, 1, 1, 1))
                ui.popFont()
            end
        end
    end
    
    if messageTimer > 0 then
        local mSize = ui.measureText(message)
        ui.setCursor(vec2(centerX - mSize.x/2, 220))
        ui.pushFont(ui.Font.Title)
        ui.textColored(message, rgbm(0, 1, 0, 1))
        ui.popFont()
    end
end
