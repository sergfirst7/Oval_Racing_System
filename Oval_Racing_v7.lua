-- DRS World: KMR Visualizer (Oval Racing v7.0)
-- 100% Client-Side UI driven by KissMyRank chat messages.

local VERSION = "KMR VISUALIZER v7.0"
local STATE = { GREEN = 1, CAUTION = 2, PENALTY = 3 }
local currentFlag = STATE.GREEN
local currentSpeedLimit = 0
local restartTimer = 0
local penaltyBoxTimer = 0
local lastError = "None"
local isOvalSystemActive = true
local debugSessionType = "Unknown"

-- Управление сессией: визуализатор работает только в гонке
local function checkSession()
    local ok, err = pcall(function()
        local s = ac.getSim()
        if not s then return end
        
        local sess = ac.getSession(s.currentSessionIndex)
        if sess then
            debugSessionType = tostring(sess.type) .. " | " .. tostring(sess.name)
            local sname = sess.name and sess.name:lower() or ""
            if sname:find("qual") or sname:find("prac") then
                isOvalSystemActive = false
            elseif sess.type == ac.SessionType.Race or sess.type == 2 or sname:find("race") then
                isOvalSystemActive = true
            else
                isOvalSystemActive = false
            end
        else
            local maxLaps = s.maxLaps or 0
            debugSessionType = "Fallback | Laps: " .. tostring(maxLaps)
            isOvalSystemActive = (maxLaps > 0)
        end
    end)
    if not ok then lastError = tostring(err) end
end

function script.update(dt)
    if restartTimer > 0 then restartTimer = restartTimer - dt end
    if penaltyBoxTimer > 0 then penaltyBoxTimer = penaltyBoxTimer - dt end
    
    -- Проверка сессии каждый кадр (или раз в секунду)
    if math.random() < 0.05 then
        checkSession()
    end
end

-- Основная логика: слушаем чат от KMR
ac.onChatMessage(function(msg, senderID)
    if not isOvalSystemActive then return end
    
    local text = msg:lower()
    
    -- Ловим начало VSC и лимит скорости (из KMR или от админа)
    if text:find("virtual safety car") or text:find("virtual_safety_car_deploy") then 
        currentFlag = STATE.CAUTION
        
        -- Попытка вытянуть лимит скорости, например "speed over 120" или "deploy 120"
        local speedMatch = text:match("speed over (%d+)")
        if not speedMatch then speedMatch = text:match("deploy (%d+)") end
        
        if speedMatch then
            currentSpeedLimit = tonumber(speedMatch)
        end
    end
    
    -- Ловим конец VSC
    if text:find("penalties have been cleared") or text:find("go go go") or text:find("virtual_safety_car_deploy 0") then 
        currentFlag = STATE.GREEN 
        restartTimer = 3.0 -- Зеленый флаг висит 3 секунды
    end
    
    -- Ловим выдачу штрафа (наш локальный)
    if text:find("penalty") and (text:find("drive%-through") or text:find("time penalty")) then
        penaltyBoxTimer = 10.0 -- Показываем огромное окно штрафа на 10 секунд
    end

    -- Ручной override для админов (на всякий случай)
    if text:find("!yellow") then currentFlag = STATE.CAUTION end
    if text:find("!green") then currentFlag = STATE.GREEN; restartTimer = 3.0 end
end)

function script.drawUI()
    local me = ac.getCar(0)
    if not me then return end
    
    local mySpeed = math.floor(me.speedKmh)
    
    -- ДИАГНОСТИЧЕСКАЯ ПАНЕЛЬ (Можно закомментировать для релиза)
    ui.setCursor(vec2(10, 10))
    ui.textColored(VERSION .. " | Flag: " .. currentFlag .. " | VSC Limit: " .. currentSpeedLimit, rgbm(1, 1, 1, 1))
    ui.setCursor(vec2(10, 25))
    ui.textColored("Session: " .. debugSessionType .. (isOvalSystemActive and " (ACTIVE)" or " (DISABLED)"), rgbm(1, 0.5, 0, 1))
    ui.setCursor(vec2(10, 40))
    ui.textColored("Err: " .. lastError, rgbm(1, 0, 0, 1))

    if not isOvalSystemActive then return end

    pcall(function()
        local centerX = ui.windowSize().x / 2
        local showBlock = (currentFlag == STATE.CAUTION) or (restartTimer > 0)
        
        -- Главное окно флагов
        if showBlock then
            local boxW = 320
            local boxH = (currentFlag == STATE.GREEN) and 60 or 120
            local bgColor = (currentFlag == STATE.GREEN) and rgbm(0, 0.8, 0, 1) or rgbm(1, 1, 0, 1)
            local boxY = 60
            
            ui.drawRectFilled(vec2(centerX - boxW/2, boxY), vec2(centerX + boxW/2, boxY + boxH), bgColor, 12)
            
            local title = "VIRTUAL SAFETY CAR"
            if currentFlag == STATE.GREEN then title = "GREEN FLAG / GO!" end
            
            ui.pushFont(ui.Font.Title)
            local titleSize = ui.measureText(title)
            ui.setCursor(vec2(centerX - titleSize.x/2, boxY + 8))
            ui.textColored(title, rgbm(0, 0, 0, 1))
            ui.popFont()
            
            if currentFlag == STATE.CAUTION then
                ui.setCursor(vec2(centerX - ui.measureText("SPEED LIMIT").x/2, boxY + 40))
                ui.textColored("SPEED LIMIT", rgbm(0, 0, 0, 1))
                
                ui.pushFont(ui.Font.Title)
                local sText = (currentSpeedLimit > 0) and (currentSpeedLimit .. " KM/H") or "SLOW DOWN"
                ui.setCursor(vec2(centerX - ui.measureText(sText).x/2, boxY + 70))
                ui.textColored(sText, (mySpeed > currentSpeedLimit and currentSpeedLimit > 0) and rgbm(1, 0, 0, 1) or rgbm(0, 0, 0, 1))
                ui.popFont()
            end
        end

        -- Окно штрафа (Drive-Through)
        if penaltyBoxTimer > 0 then
            local cx = ui.windowSize().x / 2
            local cy = ui.windowSize().y / 2
            
            ui.drawRectFilled(vec2(cx - 200, cy - 60), vec2(cx + 200, cy + 60), rgbm(1, 0, 0, 0.9), 10)
            
            ui.pushFont(ui.Font.Title)
            local warnText = "DRIVE-THROUGH PENALTY!"
            ui.setCursor(vec2(cx - ui.measureText(warnText).x/2, cy - 30))
            ui.textColored(warnText, rgbm(1, 1, 1, 1))
            
            local subText = "PLEASE SERVE YOUR PENALTY"
            ui.setCursor(vec2(cx - ui.measureText(subText).x/2, cy + 10))
            ui.textColored(subText, rgbm(1, 1, 0, 1))
            ui.popFont()
        end
    end)
end
