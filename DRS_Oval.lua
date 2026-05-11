-- DRS World: Oval Racing System v2.4 (REAL PENALTIES)
-- Race Only + Rolling Start + Real Server Penalties

local STATE = { GREEN = 1, CAUTION = 2, ONE_TO_GREEN = 3 }
local currentFlag = STATE.GREEN
local targetCarID = -1
local targetCarName = "NONE"
local restartTimer = 0

-- Caution & Penalties
local yellowCooldown = 0
local slowTimers = {}
local cautionStartLap = 0
local overtakeTimer = 0
local penaltyAppliedTimer = 0 -- Для уведомления на экране

-- Track info
local trackLength = ac.getSim().trackLengthM
local scPos = 0 
local scSpeed = 80 / 3.6

local function safeName(id)
    local name = ac.getDriverName(id)
    return (name and name ~= "") and name or "Driver #"..id
end

-- Применение реального штрафа через серверную команду
local function applyRealPenalty(id, seconds)
    ac.sendChatMessage("!penalty #" .. id .. " " .. seconds)
    penaltyAppliedTimer = 5.0 -- Показываем уведомление на экране 5 секунд
end

local function getSideText(id)
    local order = {}
    for i = 0, ac.getSim().carsCount - 1 do
        local car = ac.getCar(i)
        if car and car.isConnected then
            table.insert(order, {id=i, dist=car.lapCount + car.splinePosition})
        end
    end
    table.sort(order, function(a,b) return a.dist > b.dist end)
    
    for i, entry in ipairs(order) do
        if entry.id == id then
            if i % 2 == 1 then return "STAY LEFT (Inside)"
            else return "STAY RIGHT (Outside)" end
        end
    end
    return ""
end

local function triggerCaution()
    if ac.getSim().sessionType ~= ac.SessionType.Race then return end
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
    local sim = ac.getSim()
    if sim.sessionType ~= ac.SessionType.Race then return end

    if restartTimer > 0 then restartTimer = restartTimer - dt end
    if yellowCooldown > 0 then yellowCooldown = yellowCooldown - dt end
    if penaltyAppliedTimer > 0 then penaltyAppliedTimer = penaltyAppliedTimer - dt end
    
    local me = ac.getCar(0)
    
    -- Детектор аварий
    if currentFlag == STATE.GREEN and yellowCooldown <= 0 then
        for i = 0, sim.carsCount - 1 do
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

    -- Судейство под желтым флагом
    if currentFlag ~= STATE.GREEN then
        scPos = (scPos + (scSpeed * dt) / trackLength) % 1
        
        local distToTarget = 0
        if targetCarID == -1 then
            distToTarget = (scPos - me.splinePosition) * trackLength
        else
            local tCar = ac.getCar(targetCarID)
            distToTarget = (tCar.splinePosition - me.splinePosition) * trackLength
        end
        if distToTarget < -trackLength/2 then distToTarget = distToTarget + trackLength end

        if distToTarget < -2 then
            overtakeTimer = overtakeTimer + dt
            if overtakeTimer > 3.0 then
                applyRealPenalty(0, 10) -- РЕАЛЬНЫЙ ШТРАФ
                overtakeTimer = -10
            end
        else
            overtakeTimer = math.max(0, overtakeTimer - dt)
        end

        local lapsPassed = me.lapCount - cautionStartLap
        if lapsPassed >= 2 then
            currentFlag = STATE.GREEN
            targetCarID = -1
            restartTimer = 5.0
            ac.sendChatMessage("GREEN FLAG! GO! !green")
        elseif lapsPassed >= 1.5 and currentFlag == STATE.CAUTION then
            currentFlag = STATE.ONE_TO_GREEN
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
    local sim = ac.getSim()
    if sim.sessionType ~= ac.SessionType.Race then return end

    local centerX = ui.windowSize().x / 2
    local showBlock = (currentFlag ~= STATE.GREEN) or (restartTimer > 0)
    
    if showBlock then
        local boxW = 380
        local boxH = 155
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
            
            local sideText = getSideText(0)
            local sideSize = ui.measureText(sideText)
            ui.setCursor(vec2(centerX - sideSize.x/2, 105))
            ui.textColored(sideText, rgbm(0, 0, 0, 1))
            
            local me = ac.getCar(0)
            local dist = targetCarID == -1 and (scPos - me.splinePosition) * trackLength or (ac.getCar(targetCarID).splinePosition - me.splinePosition) * trackLength
            if dist < -trackLength/2 then dist = dist + trackLength end

            ui.pushFont(ui.Font.Title)
            local dText = math.floor(dist) .. "m"
            local dSize = ui.measureText(dText)
            local dColor = (dist < 10 or dist > 50) and rgbm(1, 0, 0, 1) or rgbm(0, 0.5, 0, 1)
            ui.setCursor(vec2(centerX - dSize.x/2, 125))
            ui.textColored(dText, dColor)
            ui.popFont()
        end
    end

    -- Уведомление о примененном штрафе
    if penaltyAppliedTimer > 0 then
        ui.drawRectFilled(vec2(centerX - 250, 200), vec2(centerX + 250, 250), rgbm(1, 0, 0, 0.95), 8)
        ui.setCursor(vec2(centerX - 230, 210))
        ui.pushFont(ui.Font.Title)
        ui.textColored("REAL PENALTY APPLIED: +10s", rgbm(1, 1, 1, 1))
        ui.popFont()
    end
    
    ui.setCursor(vec2(10, 10))
    ui.text("DRS Oval v2.4 REAL-TIME")
end
