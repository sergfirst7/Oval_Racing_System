-- DRS World: Oval Racing System v3.1 (DEBUG EDITION)
-- Robust Session Check | Forced UI on !yellow

local STATE = { GREEN = 1, CAUTION = 2, ONE_TO_GREEN = 3, STARTING = 4 }
local currentFlag = STATE.STARTING
local targetCarID = -1
local targetCarName = "NONE"
local restartTimer = 0

-- Caution & Penalties
local yellowCooldown = 60
local slowTimers = {}
local cautionStartLap = 0
local overtakeTimer = 0
local penaltyAppliedTimer = 0
local sessionStartTimer = 0
local initializedSC = false
local forceUI = false -- Принудительный показ UI

-- Track info
local trackLength = ac.getSim().trackLengthM
local scPos = 0 
local scSpeed = 120 / 3.6

-- УЛУЧШЕННАЯ ПРОВЕРКА СЕССИИ
local function isRaceSession()
    if forceUI then return true end
    local sim = ac.getSim()
    if not sim then return false end
    
    local isRace = false
    -- Способ 1: По типу (2 = Race)
    pcall(function() if sim.sessionType == 2 then isRace = true end end)
    
    -- Способ 2: По имени
    pcall(function() 
        if sim.sessionName and string.find(sim.sessionName:lower(), "race") then 
            isRace = true 
        end 
    end)
    
    return isRace
end

local function safeName(id)
    local name = ac.getDriverName(id)
    return (name and name ~= "") and name or "Driver #"..id
end

local function applyRealPenalty(id, seconds)
    ac.sendChatMessage("!penalty #" .. id .. " " .. seconds)
    penaltyAppliedTimer = 5.0
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

local function initTarget()
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
                scPos = (entry.spline + 80/trackLength) % 1
            end
            break
        end
    end
end

local function triggerCaution()
    if not isRaceSession() or currentFlag ~= STATE.GREEN then return end
    currentFlag = STATE.CAUTION
    restartTimer = 0
    cautionStartLap = ac.getCar(0).lapCount
    initTarget()
end

function script.update(dt)
    if not isRaceSession() then return end

    sessionStartTimer = sessionStartTimer + dt
    if restartTimer > 0 then restartTimer = restartTimer - dt end
    if yellowCooldown > 0 then yellowCooldown = yellowCooldown - dt end
    if penaltyAppliedTimer > 0 then penaltyAppliedTimer = penaltyAppliedTimer - dt end
    
    local me = ac.getCar(0)

    if not initializedSC then
        initTarget()
        initializedSC = true
    end

    if currentFlag == STATE.GREEN and yellowCooldown <= 0 and sessionStartTimer > 40 then
        for i = 0, ac.getSim().carsCount - 1 do
            local car = ac.getCar(i)
            if car and car.isConnected and not car.isInPitlane and car.speedKmh < 40 then
                slowTimers[i] = (slowTimers[i] or 0) + dt
                if slowTimers[i] > 4.0 then
                    ac.sendChatMessage("CAUTION: Incident! !yellow")
                    triggerCaution()
                    yellowCooldown = 60
                    break
                end
            else
                slowTimers[i] = 0
            end
        end
    end

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

        if distToTarget < -3 then
            overtakeTimer = overtakeTimer + dt
            if overtakeTimer > 1.0 then
                applyRealPenalty(0, 10)
                overtakeTimer = -10
            end
        else
            overtakeTimer = math.max(0, overtakeTimer - dt)
        end

        if currentFlag ~= STATE.STARTING then
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
end

ac.onChatMessage(function(msg, senderID)
    local text = msg:lower()
    if string.find(text, "!yellow") then 
        forceUI = true
        triggerCaution()
    elseif string.find(text, "!green") then 
        currentFlag = STATE.GREEN 
        restartTimer = 5.0
    end
end)

function script.drawUI()
    if not isRaceSession() then return end

    local centerX = ui.windowSize().x / 2
    local showBlock = (currentFlag ~= STATE.GREEN) or (restartTimer > 0)
    
    if showBlock then
        local boxW = 380
        local boxH = 142
        local bgColor = currentFlag == STATE.GREEN and rgbm(0, 0.8, 0, 1) or rgbm(1, 1, 0, 1)
        
        ui.drawRectFilled(vec2(centerX - boxW/2, 40), vec2(centerX + boxW/2, 40 + boxH), bgColor, 12)
        
        local title = "YELLOW FLAG"
        if currentFlag == STATE.GREEN then title = "GREEN FLAG / GO!" 
        elseif currentFlag == STATE.STARTING then title = "ROLLING START"
        elseif currentFlag == STATE.ONE_TO_GREEN then title = "ONE TO GREEN" end
        
        ui.pushFont(ui.Font.Title)
        local titleSize = ui.measureText(title)
        ui.setCursor(vec2(centerX - titleSize.x/2, 48))
        ui.textColored(title, rgbm(0, 0, 0, 1))
        ui.popFont()
        
        if currentFlag ~= STATE.GREEN then
            local followText = "FOLLOW: " .. targetCarName
            local followSize = ui.measureText(followText)
            ui.setCursor(vec2(centerX - followSize.x/2, 82))
            ui.textColored(followText, rgbm(0, 0, 0, 1))
            
            local sideText = getSideText(0)
            local sideSize = ui.measureText(sideText)
            ui.setCursor(vec2(centerX - sideSize.x/2, 102))
            ui.textColored(sideText, rgbm(0, 0.2, 0.8, 1))
            
            local me = ac.getCar(0)
            local dist = targetCarID == -1 and (scPos - me.splinePosition) * trackLength or (ac.getCar(targetCarID).splinePosition - me.splinePosition) * trackLength
            if dist < -trackLength/2 then dist = dist + trackLength end

            ui.pushFont(ui.Font.Title)
            local dText = math.floor(dist) .. "m"
            local dSize = ui.measureText(dText)
            local dColor = (dist < 10 or dist > 50) and rgbm(1, 0, 0, 1) or rgbm(0, 0, 0, 1)
            ui.setCursor(vec2(centerX - dSize.x/2, 118))
            ui.textColored(dText, dColor)
            ui.popFont()
        end
    end

    if penaltyAppliedTimer > 0 then
        ui.drawRectFilled(vec2(centerX - 250, 210), vec2(centerX + 250, 260), rgbm(1, 0, 0, 1), 8)
        ui.setCursor(vec2(centerX - 235, 220))
        ui.pushFont(ui.Font.Title)
        ui.textColored("REAL PENALTY APPLIED: +10s", rgbm(1, 1, 1, 1))
        ui.popFont()
    end
    
    -- Debug Info
    ui.setCursor(vec2(10, 10))
    local sType = -1
    pcall(function() sType = ac.getSim().sessionType end)
    ui.text("v3.1 | Type: " .. sType .. " | Race: " .. tostring(isRaceSession()))
end
