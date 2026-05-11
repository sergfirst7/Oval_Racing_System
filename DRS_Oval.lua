-- DRS World: Oval Racing System v2.2 (COMPACT)
-- Tight UI + Same Logic

local STATE = { GREEN = 1, CAUTION = 2, ONE_TO_GREEN = 3 }
local currentFlag = STATE.GREEN
local targetCarID = -1
local targetCarName = "NONE"
local restartTimer = 0

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
    restartTimer = 0
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
    if restartTimer > 0 then restartTimer = restartTimer - dt end
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

    -- ЛОГИКА РЕСТАРТА
    if currentFlag ~= STATE.GREEN then
        scPos = (scPos + (scSpeed * dt) / trackLength) % 1
        
        local lapsPassed = me.lapCount - cautionStartLap
        if lapsPassed >= 2 then
            currentFlag = STATE.GREEN
            targetCarID = -1
            restartTimer = 5.0
            ac.sendChatMessage("GREEN FLAG! GO! !green")
        elseif lapsPassed >= 1.5 and currentFlag == STATE.CAUTION then
            currentFlag = STATE.ONE_TO_GREEN
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
        restartTimer = 5.0
    end
end)

function script.drawUI()
    local centerX = ui.windowSize().x / 2
    local showBlock = (currentFlag ~= STATE.GREEN) or (restartTimer > 0)
    
    if showBlock then
        local boxW = 360 -- Уменьшено
        local boxH = 125 -- Уменьшено
        local bgColor = currentFlag == STATE.GREEN and rgbm(0, 0.8, 0, 1) or rgbm(1, 1, 0, 1)
        
        ui.drawRectFilled(vec2(centerX - boxW/2, 40), vec2(centerX + boxW/2, 40 + boxH), bgColor, 12)
        
        local title = "YELLOW FLAG"
        if currentFlag == STATE.GREEN then title = "GREEN FLAG / GO!" 
        elseif currentFlag == STATE.ONE_TO_GREEN then title = "ONE TO GREEN" end
        
        ui.pushFont(ui.Font.Title)
        local titleSize = ui.measureText(title)
        ui.setCursor(vec2(centerX - titleSize.x/2, 48))
        ui.textColored(title, rgbm(0, 0, 0, 1))
        ui.popFont()
        
        if currentFlag ~= STATE.GREEN then
            local followText = "FOLLOW: " .. targetCarName
            local followSize = ui.measureText(followText)
            ui.setCursor(vec2(centerX - followSize.x/2, 85))
            ui.textColored(followText, rgbm(0, 0, 0, 1))
            
            if targetCarName == "SAFETY CAR" then
                local me = ac.getCar(0)
                local distToSC = (scPos - me.splinePosition) * trackLength
                if distToSC < -trackLength/2 then distToSC = distToSC + trackLength end
                
                local dText = "DISTANCE: " .. math.floor(distToSC) .. "m"
                local dColor = (distToSC < 15 or distToSC > 60) and rgbm(1, 0, 0, 1) or rgbm(0, 0.5, 0, 1)
                
                ui.pushFont(ui.Font.Title)
                local dSize = ui.measureText(dText)
                ui.setCursor(vec2(centerX - dSize.x/2, 100))
                ui.textColored(dText, dColor)
                ui.popFont()
                
                -- Таймер штрафа (чуть выше, чтобы не вылезал)
                if scOvertakeTimer > 0 then
                    ui.drawRectFilled(vec2(centerX - 250, 170), vec2(centerX + 250, 220), rgbm(1, 0, 0, 0.9), 5)
                    ui.setCursor(vec2(centerX - 230, 180))
                    ui.pushFont(ui.Font.Title)
                    ui.textColored("REDUCE SPEED! PENALTY: " .. string.format("%.1f", 3.0 - scOvertakeTimer) .. "s", rgbm(1, 1, 1, 1))
                    ui.popFont()
                end
            end
        end
    end
    
    ui.setCursor(vec2(10, 10))
    ui.text("DRS Oval v2.2")
end
