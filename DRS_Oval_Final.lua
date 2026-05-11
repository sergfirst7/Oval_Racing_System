-- DRS World: Oval Racing System v3.9 (SESSION MASTER)
-- Auto Reset on Session Change | Compact UI | No Version on HUD

local STATE = { GREEN = 1, CAUTION = 2, ONE_TO_GREEN = 3, STARTING = 4 }
local currentFlag = STATE.STARTING
local rollingStartDone = false
local lastSessionIndex = -1
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
local forceUI = false

-- Track info
local sim = ac.getSim()
local trackLength = sim and sim.trackLengthM or 1000
local scPos = 0 
local scSpeed = 120 / 3.6

local function isRaceSession()
    if forceUI then return true end
    local s = ac.getSim()
    if not s then return false end
    if s.sessionType == 0 or s.sessionType == 1 then return false end
    return true
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
                scPos = (entry.spline + 100/trackLength) % 1
            end
            break
        end
    end
end

function script.update(dt)
    pcall(function()
        local s = ac.getSim()
        if not s then return end

        -- СБРОС ПРИ СМЕНЕ СЕССИИ (Практика -> Гонка)
        if s.sessionIndex ~= lastSessionIndex then
            lastSessionIndex = s.sessionIndex
            currentFlag = STATE.STARTING
            rollingStartDone = false
            initializedSC = false
            sessionStartTimer = 0
            yellowCooldown = 60
        end

        if not isRaceSession() then return end

        sessionStartTimer = sessionStartTimer + dt
        if restartTimer > 0 then restartTimer = restartTimer - dt end
        if yellowCooldown > 0 then yellowCooldown = yellowCooldown - dt end
        if penaltyAppliedTimer > 0 then penaltyAppliedTimer = penaltyAppliedTimer - dt end
        
        local me = ac.getCar(0)
        if not me then return end

        if not initializedSC then
            initTarget()
            initializedSC = true
        end

        -- Авто-Зеленый
        if currentFlag == STATE.STARTING and me.splinePosition > 0.5 then
            currentFlag = STATE.GREEN
            rollingStartDone = true
            ac.sendChatMessage("GREEN FLAG! GO! !green")
            restartTimer = 5.0
        end

        -- Авто-Желтый
        if currentFlag == STATE.GREEN and rollingStartDone and yellowCooldown <= 0 and sessionStartTimer > 60 then
            for i = 0, ac.getSim().carsCount - 1 do
                local car = ac.getCar(i)
                if car and car.isConnected and not car.isInPitlane and car.speedKmh < 40 then
                    slowTimers[i] = (slowTimers[i] or 0) + dt
                    if slowTimers[i] > 4.0 then
                        ac.sendChatMessage("CAUTION! !yellow")
                        currentFlag = STATE.CAUTION
                        cautionStartLap = me.lapCount
                        initTarget()
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
                if tCar then
                    distToTarget = (tCar.splinePosition - me.splinePosition) * trackLength
                end
            end
            if distToTarget < -trackLength/2 then distToTarget = distToTarget + trackLength end

            if distToTarget < -3 and sessionStartTimer > 10 then
                overtakeTimer = overtakeTimer + dt
                if overtakeTimer > 1.5 then
                    applyRealPenalty(0, 10)
                    overtakeTimer = -10
                end
            else
                overtakeTimer = math.max(0, overtakeTimer - dt)
            end

            if currentFlag == STATE.CAUTION or currentFlag == STATE.ONE_TO_GREEN then
                local lapsPassed = me.lapCount - cautionStartLap
                if lapsPassed >= 2 then
                    currentFlag = STATE.GREEN
                    targetCarID = -1
                    restartTimer = 5.0
                elseif lapsPassed >= 1.5 then
                    currentFlag = STATE.ONE_TO_GREEN
                end
            end
        end
    end)
end

ac.onChatMessage(function(msg, senderID)
    local text = msg:lower()
    if string.find(text, "!yellow") then 
        forceUI = true
        currentFlag = STATE.CAUTION
        cautionStartLap = ac.getCar(0).lapCount
        initTarget()
    elseif string.find(text, "!green") then 
        currentFlag = STATE.GREEN 
        rollingStartDone = true
        restartTimer = 5.0
    end
end)

function script.drawUI()
    pcall(function()
        if not isRaceSession() then return end

        local centerX = ui.windowSize().x / 2
        local showBlock = (currentFlag ~= STATE.GREEN) or (restartTimer > 0)
        
        if showBlock then
            local boxW = 320
            local boxH = (currentFlag == STATE.GREEN) and 60 or 120 -- Компактнее
            local bgColor = (currentFlag == STATE.GREEN) and rgbm(0, 0.8, 0, 1) or rgbm(1, 1, 0, 1)
            local boxY = 40
            
            ui.drawRectFilled(vec2(centerX - boxW/2, boxY), vec2(centerX + boxW/2, boxY + boxH), bgColor, 12)
            
            local title = "YELLOW FLAG"
            if currentFlag == STATE.GREEN then title = "GREEN FLAG / GO!" 
            elseif currentFlag == STATE.STARTING then title = "ROLLING START"
            elseif currentFlag == STATE.ONE_TO_GREEN then title = "ONE TO GREEN" end
            
            ui.pushFont(ui.Font.Title)
            local titleSize = ui.measureText(title)
            ui.setCursor(vec2(centerX - titleSize.x/2, boxY + 8))
            ui.textColored(title, rgbm(0, 0, 0, 1))
            ui.popFont()
            
            if currentFlag ~= STATE.GREEN then
                -- Компактные отступы (сузил)
                ui.setCursor(vec2(centerX - ui.measureText("FOLLOW: " .. targetCarName).x/2, boxY + 40))
                ui.textColored("FOLLOW: " .. targetCarName, rgbm(0, 0, 0, 1))
                
                local side = getSideText(0)
                ui.setCursor(vec2(centerX - ui.measureText(side).x/2, boxY + 58))
                ui.textColored(side, rgbm(0, 0.2, 0.8, 1))
                
                local me = ac.getCar(0)
                local dist = targetCarID == -1 and (scPos - me.splinePosition) * trackLength or (ac.getCar(targetCarID).splinePosition - me.splinePosition) * trackLength
                if dist < -trackLength/2 then dist = dist + trackLength end

                ui.pushFont(ui.Font.Title)
                local dText = math.floor(dist) .. "m"
                ui.setCursor(vec2(centerX - ui.measureText(dText).x/2, boxY + 78))
                ui.textColored(dText, (dist < 10 or dist > 50) and rgbm(1, 0, 0, 1) or rgbm(0, 0, 0, 1))
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
    end)
end
