-- DRS World: Oval Racing System v1.2
-- Virtual Safety Car + Overtake Penalties

local STATE = { GREEN = 1, CAUTION = 2, ONE_TO_GREEN = 3 }
local currentFlag = STATE.GREEN
local targetCarID = -1
local targetCarName = ""
local message = ""
local messageTimer = 0

-- Safety Car Logic
local scPos = 0 -- Позиция сейфти-кара на сплайне (0-1)
local scSpeed = 80 / 3.6 -- 80 км/ч в м/с
local trackLength = ac.getSim().trackLengthM

-- Penalty Logic
local overtakeTimer = 0
local penaltyIssued = false

local function safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then ac.log("DRS Oval Error: " .. tostring(err)) end
    end
end

-- Расчет текущего порядка
local function getRaceOrder()
    local order = {}
    for i = 0, ac.getSim().carsCount - 1 do
        local car = ac.getCar(i)
        if car and car.isConnected then
            table.insert(order, {
                id = i,
                name = car.driverName,
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
    
    if currentFlag ~= STATE.GREEN then
        -- Двигаем виртуальный сейфти-кар
        scPos = (scPos + (scSpeed * dt) / trackLength) % 1
        
        -- Логика штрафов (только если есть цель)
        if targetCarID ~= -1 then
            local me = ac.getCar(0)
            local target = ac.getCar(targetCarID)
            
            -- Если мы впереди цели (учитываем переход через 0/1 сплайна)
            local distDiff = me.splinePosition - target.splinePosition
            if distDiff < -0.5 then distDiff = distDiff + 1 end
            if distDiff > 0.5 then distDiff = distDiff - 1 end
            
            if distDiff > 0.005 then -- Обогнали более чем на 5 метров
                overtakeTimer = overtakeTimer + dt
                if overtakeTimer > 2.0 and not penaltyIssued then
                    ac.sendChatMessage("PENALTY: " .. me.driverName .. " ILLEGAL OVERTAKE!")
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
        
        -- Находим цель
        local order = getRaceOrder()
        for i, entry in ipairs(order) do
            if entry.id == 0 then
                if i > 1 then 
                    targetCarID = order[i-1].id
                    targetCarName = order[i-1].name
                else 
                    targetCarID = -1
                    targetCarName = "SAFETY CAR"
                    -- Лидер привязывается к сейфти-кару
                    scPos = entry.spline + 0.02 -- Сейфти-кар в 2% трассы перед лидером
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
    
    -- 1. Flag HUD
    if currentFlag ~= STATE.GREEN then
        local color = currentFlag == STATE.CAUTION and rgbm(1, 1, 0, 1) or rgbm(1, 0.5, 0, 1)
        ui.drawRectFilled(vec2(centerX - 160, 40), vec2(centerX + 160, 110), color, 5)
        
        ui.setCursor(vec2(centerX - 110, 55))
        ui.pushFont(ui.Font.Title)
        ui.textColored(" YELLOW FLAG", rgbm(0, 0, 0, 1))
        ui.popFont()
        
        ui.setCursor(vec2(centerX - 140, 90))
        ui.textColored("FOLLOW: " .. targetCarName, rgbm(0, 0, 0, 1))
        
        -- Штрафное предупреждение
        if overtakeTimer > 0 then
            ui.setCursor(vec2(centerX - 120, 120))
            ui.textColored("!!! GIVE BACK POSITION !!!", rgbm(1, 0, 0, 1))
            ui.drawRectFilled(vec2(centerX - 130, 115), vec2(centerX + 130, 145), rgbm(0, 0, 0, 0.5), 3)
        end
    end
    
    -- 2. 3D Маркер Сейфти-кара (только для лидера или если близко)
    if currentFlag ~= STATE.GREEN and targetCarName == "SAFETY CAR" then
        local scWorldPos = ac.getTrackFullSpline():posAt(scPos)
        local screenPos = ac.worldToScreen(scWorldPos)
        
        if screenPos.z > 0 then
            ui.setCursor(vec2(screenPos.x - 50, screenPos.y - 100))
            ui.drawRectFilled(vec2(screenPos.x - 60, screenPos.y - 110), vec2(screenPos.x + 60, screenPos.y - 70), rgbm(1, 0.8, 0, 0.8), 10)
            ui.textColored("SAFETY CAR", rgbm(0, 0, 0, 1))
        end
    end
end
