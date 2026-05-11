-- DRS World: Oval Racing System (CSP Online Script) v1.1
-- Fixed onCollision error by removing physics hooks not supported in Online Scripts

local STATE = { GREEN = 1, CAUTION = 2, ONE_TO_GREEN = 3 }
local currentFlag = STATE.GREEN
local targetCarName = ""
local message = ""
local messageTimer = 0

-- Config
local CAUTION_SPEED = 80

-- Safe Wrapper
local function safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then ac.log("DRS Oval Error: " .. tostring(err)) end
    end
end

-- Logic: Get race order based on distance
local function getRaceOrder()
    local order = {}
    for i = 0, ac.getSim().carsCount - 1 do
        local car = ac.getCar(i)
        if car and car.isConnected then
            table.insert(order, {
                id = i,
                name = car.driverName,
                dist = car.lapCount + car.splinePosition
            })
        end
    end
    table.sort(order, function(a, b) return a.dist > b.dist end)
    return order
end

function script.update(dt)
    if messageTimer > 0 then messageTimer = messageTimer - dt end
end

-- Chat Sync
ac.onChatMessage(safe(function(msg, senderID)
    local text = msg:lower()
    if string.find(text, "!yellow") or string.find(msg:upper(), "YELLOW FLAG") then
        currentFlag = STATE.CAUTION
        message = "YELLOW FLAG - CAUTION"
        messageTimer = 5
        
        local order = getRaceOrder()
        for i, entry in ipairs(order) do
            if entry.id == 0 then
                if i > 1 then targetCarName = order[i-1].name
                else targetCarName = "PACE CAR" end
                break
            end
        end
    elseif string.find(text, "!green") or string.find(msg:upper(), "GREEN FLAG") then
        currentFlag = STATE.GREEN
        targetCarName = ""
        message = "GREEN FLAG! GO!"
        messageTimer = 3
    elseif string.find(text, "!one") or string.find(msg:upper(), "ONE TO GREEN") then
        currentFlag = STATE.ONE_TO_GREEN
        message = "ONE TO GREEN - PREPARE"
        messageTimer = 5
    end
end))

-- UI Implementation
function script.drawUI()
    local centerX = ui.windowSize().x / 2
    
    if currentFlag ~= STATE.GREEN then
        local color = currentFlag == STATE.CAUTION and rgbm(1, 1, 0, 1) or rgbm(1, 0.5, 0, 1)
        ui.drawRectFilled(vec2(centerX - 150, 40), vec2(centerX + 150, 95), color, 5)
        
        ui.setCursor(vec2(centerX - 110, 55))
        ui.pushFont(ui.Font.Title)
        ui.textColored(currentFlag == STATE.CAUTION and " YELLOW FLAG" or "ONE TO GREEN", rgbm(0, 0, 0, 1))
        ui.popFont()
        
        if targetCarName ~= "" then
            ui.setCursor(vec2(centerX - 100, 105))
            ui.text("STAY BEHIND: " .. targetCarName)
        end
    end
    
    if messageTimer > 0 then
        local tSize = ui.measureText(message)
        ui.setCursor(vec2(centerX - tSize.x/2, 200))
        ui.pushFont(ui.Font.Title)
        ui.text(message)
        ui.popFont()
    end
end
