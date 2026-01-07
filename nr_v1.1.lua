-- [ Reactor Control v1.1 by P1KaChU337 ] -- Исправленная версия
-- Улучшенная, стабильная и оптимизированная версия
-- GitHub: https://github.com/P1KaChU337/Reactor-Control-for-OpenComputers
-- Поддержать: https://boosty.to/p1kachu337

-- ====================================================================================================
-- ЗАГРУЗКА МОДУЛЕЙ
-- ====================================================================================================
local computer = require("computer")
local component = require("component")
local fs = require("filesystem")
local event = require("event")
local shell = require("shell")

-- Попробуем загрузить зависимости
local success_image, image = pcall(require, "image")
local success_buffer, buffer = pcall(require, "doubleBuffering")
local success_term, term = pcall(require, "term")

if not success_buffer then
    io.stderr:write("Ошибка: не найден doubleBuffering.lua\n")
    io.stderr:write("Скачайте его или установите OpenOS полностью\n")
    return
end

if not success_image then
    io.stderr:write("Ошибка: не найден image.lua\n")
    return
end

-- ====================================================================================================
-- НАСТРОЙКИ
-- ====================================================================================================
local version = "1.1"
local build = "1"
local progVer = version .. "." .. build

local imagesFolder = "/home/images/"
local dataFolder = "/home/data/"
local configPath = dataFolder .. "config.lua"
local imgPath = imagesFolder .. "reactorGUI.pic"
local imgPathWhite = imagesFolder .. "reactorGUI_white.pic"

-- Создаём папки
if not fs.exists(dataFolder) then fs.makeDirectory(dataFolder) end
if not fs.exists(imagesFolder) then fs.makeDirectory(imagesFolder) end

-- Устанавливаем разрешение
buffer.setResolution(160, 50)
buffer.clear(0x000000)

-- Переменные
local reactors = 0
local work = false
local exit = false
local startTime = computer.uptime()

-- Данные по реакторам
local reactor_work = {}
local temperature = {}
local reactor_type = {}
local reactor_address = {}
local reactors_proxy = {}
local reactor_rf = {}
local reactor_coolantAmount = {}
local reactor_maxcoolant = {}
local reactor_fuelAmount = {}
local reactor_fuelTimeLeft = {}
local reactor_coolantRate = {}

-- Метрики
local consoleLines = {}
local totalCoolantRate = 0
local systemUptime = "0м"

-- UI
local widgetCoords = {
    {10, 6}, {36, 6}, {65, 6}, {91, 6},
    {10, 18}, {36, 18}, {65, 18}, {91, 18},
    {10, 30}, {36, 30}, {65, 30}, {91, 30}
}

local colors = {
    bg = 0x202020,
    bg2 = 0x101010,
    bg3 = 0x3c3c3c,
    bg4 = 0x969696,
    bg5 = 0xff0000,
    textclr = 0xcccccc,
    textbtn = 0xffffff,
    msginfo = 0x61ff52,
    msgwarn = 0xfff700,
    msgerror = 0xff0000,
    whitebtn2 = 0x38afff,
}

-- ====================================================================================================
-- УТИЛИТЫ
-- ====================================================================================================
local function logError(message, context)
    if debugLog then
        local f = io.open("/home/reactor_errors.log", "a")
        if f then
            f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(message) .. "\n")
            if context then f:write("Context: " .. tostring(context) .. "\n") end
            f:write("\n")
            f:close()
        end
    end
end

local function safeCall(proxy, method, default, ...)
    if not proxy or not proxy[method] then return default end
    local ok, result = pcall(proxy[method], proxy, ...)
    if not ok or result == nil then
        logError("safeCall failed: " .. method, { result = result })
        return default
    end
    if type(default) == "number" then
        result = tonumber(result)
        if not result then
            logError("safeCall: not a number: " .. method, { result = result })
            return default
        end
    end
    return result
end

local function formatTime(seconds)
    if seconds < 60 then return "менее минуты" end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return string.format("%dч %dм", hours, minutes)
    else
        return string.format("%dм", minutes)
    end
end

-- ====================================================================================================
-- КОНФИГУРАЦИЯ
-- ====================================================================================================
if not fs.exists(configPath) then
    local file = io.open(configPath, "w")
    file:write("porog = 50000\n")
    file:write("users = {}\n")
    file:write("theme = false\n")
    file:write("updateCheck = true\n")
    file:write("debugLog = false\n")
    file:write("silentMode = false\n")
    file:close()
    -- Открываем редактор
    shell.execute("edit " .. configPath)
end

local ok, config = pcall(dofile, configPath)
if not ok then
    io.stderr:write("Ошибка загрузки config.lua: " .. config .. "\n")
    return
end

-- Дефолтные значения
config.porog = config.porog or 50000
config.users = config.users or {}
config.theme = config.theme == true
config.updateCheck = config.updateCheck ~= false
config.debugLog = config.debugLog == true
config.silentMode = config.silentMode == true

local debugLog = config.debugLog

-- ====================================================================================================
-- ИНИЦИАЛИЗАЦИЯ ПЕРЕМЕННЫХ
-- ====================================================================================================
for i = 1, 12 do
    reactor_work[i] = false
    temperature[i] = 0
    reactor_type[i] = "unknown"
    reactor_rf[i] = 0
    reactor_coolantAmount[i] = 0
    reactor_maxcoolant[i] = 0
    reactor_fuelAmount[i] = 0
    reactor_fuelTimeLeft[i] = 0
    reactor_coolantRate[i] = 0
end

-- ====================================================================================================
-- ИНИЦИАЛИЗАЦИЯ РЕАКТОРОВ
-- ====================================================================================================
local function initReactors()
    for addr in component.list("htc_reactor") do
        if reactors < 12 then
            reactors = reactors + 1
            reactor_address[reactors] = addr
            reactors_proxy[reactors] = component.proxy(addr)
            local proxy = reactors_proxy[reactors]
            local maxCoolant = safeCall(proxy, "getMaxCoolantAmount", 0)
            reactor_type[reactors] = maxCoolant > 0 and "fluid" or "air"
        end
    end
    if reactors == 0 then
        message("❌ Не найдено ни одного реактора!", colors.msgerror)
        return false
    end
    message("✅ Найдено реакторов: " .. reactors, colors.msginfo)
    return true
end

-- ====================================================================================================
-- ПРОВЕРКА ME-СЕТИ (для @coolant)
-- ====================================================================================================
local function getMECoolant()
    local meProxy
    for _, addr in ipairs(component.list("me_controller", true)) do
        meProxy = component.proxy(addr)
        break
    end
    if not meProxy then
        for _, addr in ipairs(component.list("me_interface", true)) do
            meProxy = component.proxy(addr)
            break
        end
    end

    if not meProxy then return nil, "ME-сеть не найдена" end

    local success, storage = pcall(meProxy.getStorage)
    if not success or not storage then return nil, "Не удалось получить данные ME" end

    local coolantName = "Low Temperature Coolant"
    local total = 0
    local max = 0

    for _, item in ipairs(storage) do
        if item.label == coolantName then
            total = total + (item.size or 0)
            max = max + (item.maxSize or 0)
        end
    end

    if max == 0 then max = total * 10 end
    local percent = (total / max) * 100
    return total, max, percent
end

-- ====================================================================================================
-- GUI
-- ====================================================================================================
local guiImage = nil
local picPath = config.theme and imgPathWhite or imgPath

if fs.exists(picPath) then
    local success, img = pcall(image.load, picPath)
    if success then
        guiImage = img
    else
        message("⚠ Не удалось загрузить GUI: " .. picPath, colors.msgwarn)
    end
else
    message("⚠ Файл GUI не найден: " .. picPath, colors.msgwarn)
end

-- Рисуем виджеты
local function drawWidgets()
    if guiImage then
        buffer.drawImage(1, 1, guiImage)
    else
        buffer.clear(colors.bg)
    end

    for i = 1, reactors do
        local x, y = widgetCoords[i][1], widgetCoords[i][2]
        local status = reactor_work[i] and "ВКЛ" or "ВЫКЛ"
        local statusColor = reactor_work[i] and colors.msginfo or colors.msgerror

        buffer.drawText(x, y, colors.textclr, ("Реактор %d"):format(i))
        buffer.drawText(x + 5, y + 1, statusColor, status)
        buffer.drawText(x, y + 2, colors.textclr, ("🔥 %d"):format(temperature[i]))
        buffer.drawText(x, y + 3, colors.textclr, ("⚡ %d RF"):format(reactor_rf[i]))

        if reactor_type[i] == "fluid" and reactor_maxcoolant[i] > 0 then
            local perc = (reactor_coolantAmount[i] / reactor_maxcoolant[i]) * 100
            buffer.drawText(x, y + 4, 0x3399ff, ("💧 %.0f%%"):format(perc))
        end

        if reactor_work[i] and reactor_fuelAmount[i] > 0 then
            buffer.drawText(x, y + 5, colors.msgwarn, "Топливо:")
            buffer.drawText(x, y + 6, colors.msgwarn, formatTime(reactor_fuelTimeLeft[i]))
        end
    end
end

-- Правое меню
local function drawRightMenu()
    local x = 120
    buffer.drawText(x, 2, colors.textclr, "Порог: " .. config.porog)
    buffer.drawText(x, 4, colors.textclr, "Статус: Auto")

    totalCoolantRate = 0
    for i = 1, reactors do
        if reactor_work[i] and reactor_type[i] == "fluid" then
            totalCoolantRate = totalCoolantRate + reactor_coolantRate[i]
        end
    end
    buffer.drawText(x, 7, colors.textclr, "Расход: " .. string.format("%.1fB/с", totalCoolantRate / 1000))

    buffer.drawText(x, 10, colors.textclr, "Время работы:")
    buffer.drawText(x, 11, colors.msginfo, systemUptime)

    for i = 1, 10 do
        local line = consoleLines[i]
        if line then
            buffer.drawText(2, 40 + i, line.color or colors.textclr, line.text)
        end
    end

    buffer.drawChanges()
end

-- ====================================================================================================
-- КОНСОЛЬ
-- ====================================================================================================
local function message(msg, colormsg)
    colormsg = colormsg or colors.textclr
    local limit = 34
    msg = tostring(msg)
    local parts = {}
    while unicode.len(msg) > limit do
        local chunk = unicode.sub(msg, 1, limit)
        local pos = chunk:match(".*%s") or limit
        table.insert(parts, msg:sub(1, pos - 1))
        msg = msg:sub(pos + 1)
    end
    if msg ~= "" then table.insert(parts, msg) end

    for _, part in ipairs(parts) do
        table.remove(consoleLines, 1)
        table.insert(consoleLines, { text = part, color = colormsg })
    end
end

-- ====================================================================================================
-- ЧАТ-СИСТЕМА
-- ====================================================================================================
local isChatBox = component.isAvailable("chat_box")
local chatBox = isChatBox and component.chat_box

local function stripFormatting(s)
    return (s or ""):gsub("§.", "")
end

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

local function hasPermission(nick)
    if not config.users or #config.users == 0 then return true end
    for _, user in ipairs(config.users) do
        if user:lower() == nick:lower() then
            return true
        end
    end
    return false
end

local function say(msg)
    if isChatBox then
        chatBox.say(msg)
    end
end

-- Обработка команд
local function handleChatCommand(nick, cmd, args)
    if not hasPermission(nick) then
        say("§cУ вас нет прав!")
        return
    end

    if cmd == "@help" then
        say("§e@help - помощь")
        say("§a@start - включить всё")
        say("§a@stop - выключить всё")
        say("§a@setporog <число> - порог")
        say("§a@useradd <ник> - добавить")
        say("§a@userdel <ник> - удалить")
        say("§a@exit - выйти")
        say("§b@coolant - уровень хладагента в ME")  -- ← НОВАЯ КОМАНДА

    elseif cmd == "@setporog" then
        local num = tonumber(args)
        if num and num > 0 then
            config.porog = num
            message("⚙ Порог: " .. num, colors.msginfo)
            say("§2Порог: " .. num)
        else
            say("§c@setporog <число>")
        end

    elseif cmd == "@start" then
        work = true
        for i = 1, reactors do
            pcall(reactors_proxy[i].setActive, reactors_proxy[i], true)
            reactor_work[i] = true
        end
        message("✅ Включено", colors.msginfo)
        say("§2Все реакторы включены")

    elseif cmd == "@stop" then
        work = false
        for i = 1, reactors do
            pcall(reactors_proxy[i].setActive, reactors_proxy[i], false)
            reactor_work[i] = false
        end
        message("🔄 Выключено", colors.msgwarn)
        say("§cВсе реакторы остановлены")

    elseif cmd == "@coolant" or cmd == "@fluid" then
        local total, max, percent = getMECoolant()
        if not total then
            say("§c" .. max) -- ошибка
            return
        end
        local color = percent > 50 and "§a" or (percent > 20 and "§e" or "§c")
        say(("§bХладагент: %s%d§r mB / %d mB (%d%%)"):format(color, total, max, percent))

    elseif cmd == "@exit" then
        message("🛑 Выход", colors.msgerror)
        say("§cПрограмма завершена")
        exit = true
        os.exit()

    else
        say("§cКоманда неизвестна. @help")
    end
end

-- Поток чата
local function chatLoop()
    while not exit do
        local _, _, nick, msg = event.pull(0.1, "chat_message")
        if type(msg) == "string" then
            msg = stripFormatting(msg)
            local command = msg:match("^@%S+")
            if command then
                local args = msg:sub(#command + 2)
                handleChatCommand(nick:lower(), command:lower(), trim(args))
            end
        end
    end
end

-- ====================================================================================================
-- ОБНОВЛЕНИЕ
-- ====================================================================================================
local function updateUptime()
    local total = computer.uptime() - startTime
    systemUptime = formatTime(total)
end

local lastCoolant = {}
local lastUpdateTime = {}

local function updateCoolantUsage(i)
    if not reactors_proxy[i] then return end
    local now = computer.uptime()
    local current = safeCall(reactors_proxy[i], "getCoolantAmount", 0)
    reactor_coolantAmount[i] = current

    if lastCoolant[i] == nil then
        lastCoolant[i] = current
        lastUpdateTime[i] = now
        return
    end

    local dt = now - lastUpdateTime[i]
    if dt >= 0.5 then
        local rate = (lastCoolant[i] - current) / dt
        if rate > 0 and rate < 1000000 then
            reactor_coolantRate[i] = rate
        else
            reactor_coolantRate[i] = 0
        end
        lastCoolant[i] = current
        lastUpdateTime[i] = now
    end
end

local function updateFuelStatus(i)
    if not reactors_proxy[i] then return end
    local fuel = safeCall(reactors_proxy[i], "getFuelAmount", 0)
    reactor_fuelAmount[i] = fuel
    if reactor_work[i] and fuel > 0 then
        reactor_fuelTimeLeft[i] = fuel / 0.075
    else
        reactor_fuelTimeLeft[i] = 0
    end
end

-- ====================================================================================================
-- ЗАПУСК
-- ====================================================================================================
if not initReactors() then
    message("❌ Ошибка инициализации", colors.msgerror)
    os.sleep(3)
    return
end

if isChatBox then
    message("💬 Чат активен. Пишите @help", colors.msginfo)
    require("thread").create(chatLoop)
else
    message("ℹ Нет чат-бокса", colors.textclr)
end

-- Прерывание
_G.__NR_ON_INTERRUPT__ = function()
    message("🛑 Прерывание! Выключаю...", colors.msgerror)
    for i = 1, reactors do
        pcall(reactors_proxy[i].setActive, reactors_proxy[i], false)
    end
    os.exit()
end

-- Главный цикл
while not exit do
    updateUptime()

    for i = 1, reactors do
        local proxy = reactors_proxy[i]
        reactor_work[i] = safeCall(proxy, "isActive", false)
        temperature[i] = safeCall(proxy, "getHeat", 0)
        reactor_rf[i] = safeCall(proxy, "getEnergyProducedLastTick", 0)
        reactor_maxcoolant[i] = safeCall(proxy, "getMaxCoolantAmount", 0)
        updateCoolantUsage(i)
        updateFuelStatus(i)
    end

    drawWidgets()
    drawRightMenu()

    os.sleep(0.5)
end
