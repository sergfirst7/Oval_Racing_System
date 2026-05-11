-- DRS World: Oval Racing System v1.8 (PRO)
-- Improved Auto-Caution + SC Overtake Penalty + Better UI

local STATE = { GREEN = 1, CAUTION = 2, ONE_TO_GREEN = 3 }
local currentFlag = STATE.GREEN
local targetCarID = -1
local targetCarName = "NONE"
local message = ""
local messageTimer = 0

-- Slow Car Detection
local slowTimers = {}
local yellowCooldown = 0

-- Safety Car / Penalty
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
    
    local order = {}
    local sim = ac.getSim()
    for i = 0, sim.carsCount - 1 do
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
    
    -- АВТО-ДЕТЕКТОР (теперь ловит и 0 км/ч)
    if currentFlag == STATE.GREEN and yellowCooldown <= 0 then
        local sim = ac.getSim()
        for i = 0, sim.carsCount - 1 do
            local car = ac.getCar(i)
            if car and car.isConnected and not car.isInPitlane and car.speedKmh < 40 then
                slowTimers[i] = (slowTimers[i] or 0) + dt
                if slowTimers[i] > 3.0 then
                    ac.sendChatMessage("CAUTION: Incident on track! !yellow")
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
        
        -- Логика штрафа за обгон SC (для лидера)
        if targetCarName == "SAFETY CAR" then
            local me = ac.getCar(0)
            local distToSC = (scPos - me.splinePosition) * trackLength
            if distToSC < -trackLength/2 then distToSC = distToSC + trackLength end
            
            if distToSC < -2 then -- Если мы впереди SC более чем на 2 метра
                scOvertakeTimer = scOvertakeTimer + dt
                if scOvertakeTimer > 3.0 then
                    ac.sendChatMessage("PENALTY: " .. safeName(0) .. " OVERTOOK SAFETY CAR!")
                    scOvertakeTimer = -10 -- Кулдаун штрафа
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
    elseif string.find(text, "!green") then currentFlag = STATE.GREEN end
end)

function script.drawUI()
    local centerX = ui.windowSize().x / 2
    
    if currentFlag ~= STATE.GREEN then
        -- Основной блок
        ui.drawRectFilled(vec2(centerX - 200, 40), vec2(centerX + 200, 130), rgbm(1, 1, 0, 1), 10)
        
        ui.setCursor(vec2(centerX - 100, 50))
        ui.pushFont(ui.Font.Main)
        ui.textColored("--- YELLOW FLAG ---", rgbm(0, 0, 0, 1))
        ui.setCursor(vec2(centerX - 140, 75))
        ui.textColored("FOLLOW: " .. targetCarName, rgbm(0, 0, 0, 1))
        ui.popFont()
        
        -- Дистанция до SC (Жирно и крупно)
        if targetCarName == "SAFETY CAR" then
            local me = ac.getCar(0)
            local distToSC = (scPos - me.splinePosition) * trackLength
            if distToSC < -trackLength/2 then distToSC = distToSC + trackLength end
            
            local dColor = (distToSC < 15 or distToSC > 60) and rgbm(1, 0, 0, 1) or rgbm(0, 0.6, 0, 1)
            ui.setCursor(vec2(centerX - 150, 100))
            ui.pushFont(ui.Font.Title)
            ui.textColored("DISTANCE: " .. math.floor(distToSC) .. "m", dColor)
            ui.popFont()
            
            -- Таймер штрафа
            if scOvertakeTimer > 0 then
                ui.drawRectFilled(vec2(centerX - 250, 140), vec2(centerX + 250, 190), rgbm(1, 0, 0, 0.8), 5)
                ui.setCursor(vec2(centerX - 230, 150))
                ui.pushFont(ui.Font.Title)
                ui.textColored("REDUCE SPEED! PENALTY: " .. string.format("%.1f", 3.0 - scOvertakeTimer) .. "s", rgbm(1, 1, 1, 1))
                ui.popFont()
            end
        end
    end
    
    ui.setCursor(vec2(10, 10))
    ui.text("DRS Oval v1.8 PRO")
end
