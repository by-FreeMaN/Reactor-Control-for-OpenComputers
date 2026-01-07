-- Reactor Control — Smart Updater
-- Проверяет version.txt, обновляет main.lua и GUI
-- Автор: GigaCode (для OpenComputers)

-- ==================================================================
-- НАСТРОЙКИ
-- ==================================================================

-- 🔧 Замените на ссылку вашего репозитория
local REPO = "https://raw.githubusercontent.com/by-FreeMaN/Reactor-Control-for-OpenComputers/main/"

-- Файл с актуальной версией
local VERSION_URL = REPO .. "version.txt"

-- Где хранится текущая версия (локально)
local OLD_VERSION_FILE = "/home/data/oldVersion.txt"

-- Перезагружать после обновления?
local AUTO_REBOOT = true

-- Файлы для обновления
local filesToDownload = {
    { url = REPO .. "home/main.lua",                path = "/home/main.lua" },
    { url = REPO .. "home/images/reactorGUI.pic",   path = "/home/images/reactorGUI.pic" },
    { url = REPO .. "home/images/reactorGUI_white.pic", path = "/home/images/reactorGUI_white.pic" },
}

-- ==================================================================
-- ОСТАЛЬНОЙ КОД (не нужно менять)
-- ==================================================================
local component = require("component")
local gpu = component.gpu
local term = require("term")
local event = require("event")
local shell = require("shell")
local fs = require("filesystem")
local internet = require("internet")

local sw, sh = gpu.getResolution()
local oldBG, oldFG = gpu.getBackground(), gpu.getForeground()

-- Цвета
local COL_BG     = 0x0A0F0A
local COL_FRAME  = 0x0F1F0F
local COL_TEXT   = 0xDDFFDD
local COL_DIM    = 0x99CC99
local COL_WARN   = 0xFFD37F
local COL_ERR    = 0xFF6B6B
local COL_OK     = 0x7CFF7C
local COL_BARBG  = 0x123312
local COL_BAR    = 0x22FF88

local function safeSetBG(c) gpu.setBackground(c) end
local function safeSetFG(c) gpu.setForeground(c) end

local function fill(x, y, w, h, bg)
    safeSetBG(bg); gpu.fill(x, y, w, h, " ")
end

local function text(x, y, str, fg)
    if fg then safeSetFG(fg) end
    gpu.set(x, y, str)
end

local function centerX(w) return math.floor((sw - w) / 2) + 1 end
local function centerY(h) return math.floor((sh - h) / 2) + 1 end

local function frame(x, y, w, h)
    safeSetFG(COL_DIM)
    gpu.set(x, y, "┌" .. string.rep("─", w - 2) .. "┐")
    for i = 1, h - 2 do
        gpu.set(x, y + i, "│" .. string.rep(" ", w - 2) .. "│")
    end
    gpu.set(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘")
end

-- UI
local W, H = 70, 22
local X, Y = centerX(W), centerY(H)

local function drawChrome(title)
    term.clear()
    safeSetBG(COL_BG); fill(1, 1, sw, sh, COL_BG)
    fill(X, Y, W, H, COL_FRAME)
    frame(X, Y, W, H)
    text(X + 2, Y, "┤ " .. (title or "Updater") .. " ├", COL_TEXT)
    text(X + W - 15, Y + 1, "☢ UPDATE", COL_WARN)
end

local function log(msg, color)
    local logTop = Y + 10
    local logHeight = H - 11
    local logLines = {}
    
    if #logLines >= logHeight then table.remove(logLines, 1) end
    table.insert(logLines, msg:sub(1, W - 6))

    for i = 1, logHeight do
        fill(X + 2, logTop + i - 1, W - 4, 1, COL_FRAME)
        local ln = logLines[i]
        if ln then text(X + 2, logTop + i - 1, ln, color or COL_TEXT) end
    end
end

local function writeStatus(msg, color)
    fill(X + 2, Y + 3, W - 4, 2, COL_FRAME)
    text(X + 2, Y + 3, msg:sub(1, W - 6), color or COL_TEXT)
end

local function progressBar(ratio)
    local x, y, w = X + 2, Y + 7, W - 4
    local full = math.floor(w * ratio)
    fill(x, y, w, 1, COL_BARBG)
    fill(x, y, full, 1, COL_BAR)
end

-- Загрузка файла
local function download(url, path)
    writeStatus("Downloading: " .. path:match("[^/]+$"), COL_TEXT)
    log("GET " .. url:sub(1, 40) .. "...", COL_DIM)

    local ok, response = pcall(internet.request, url .. "?ignore_cert=true")
    if not ok or not response then
        log("❌ Failed: " .. url:match("[^/]+/$") .. "...", COL_ERR)
        return false
    end

    local data = ""
    repeat
        local chunk = response.read(2048)
        if chunk then data = data .. chunk end
        os.sleep(0)
    until not chunk

    pcall(function() response:close() end)

    local dir = path:match("(.+)/")
    if dir and not fs.exists(dir) then
        shell.execute("mkdir -p " .. dir)
    end

    local file = io.open(path, "wb")
    if not file then
        log("❌ Cannot write: " .. path, COL_ERR)
        return false
    end
    file:write(data)
    file:close()

    log("✅ OK: " .. path, COL_OK)
    return true
end

-- Получить текущую версию
local function getCurrentVersion()
    if fs.exists(OLD_VERSION_FILE) then
        local f = io.open(OLD_VERSION_FILE, "r")
        local ver = f:read("*l")
        f:close()
        return ver or "1.0"
    end
    return "1.0"
end

-- Получить последнюю версию
local function getLatestVersion()
    local ok, response = pcall(internet.request, VERSION_URL .. "?ignore_cert=true")
    if not ok or not response then
        return nil, "❌ Не удалось подключиться к серверу"
    end

    local data = ""
    repeat
        local chunk = response.read(1024)
        if chunk then data = data .. chunk end
    until not chunk
    pcall(function() response:close() end)

    local latest = data:match("%S+")
    if not latest then
        return nil, "❌ Версия не найдена в version.txt"
    end

    return latest
end

-- Основной процесс
local function update()
    drawChrome("Updater v1.2")

    local currentVer = getCurrentVersion()
    writeStatus("Проверка обновлений...", COL_DIM)
    log("Текущая версия: " .. currentVer, COL_TEXT)

    local latestVer, err = getLatestVersion()
    if not latestVer then
        writeStatus(err, COL_ERR)
        log("URL: " .. VERSION_URL, COL_DIM)
        return false
    end

    log("Найдена версия: v" .. latestVer, COL_OK)

    if currentVer == latestVer then
        writeStatus("✅ У вас актуальная версия!", COL_OK)
        log("Обновление не требуется.", COL_DIM)
        return true
    end

    writeStatus("Обновление: v" .. currentVer .. " → v" .. latestVer, COL_WARN)
    log("Начинаем загрузку...", COL_TEXT)

    local total = #filesToDownload
    local okCount, failCount = 0, 0

    for i, f in ipairs(filesToDownload) do
        if download(f.url, f.path) then
            okCount = okCount + 1
        else
            failCount = failCount + 1
        end
        progressBar(i / total)
        text(X + 2, Y + 8, ("Прогресс: %d%% | OK:%d Fail:%d"):format((i / total) * 100, okCount, failCount), COL_DIM)
    end

    -- Сохраняем новую версию
    local f = io.open(OLD_VERSION_FILE, "w")
    if f then
        f:write(latestVer .. "\n")
        f:close()
    end

    -- .shrc
    local shrc = io.open("/home/.shrc", "w")
    if shrc then
        shrc:write("main.lua\n")
        shrc:close()
    end

    if failCount == 0 then
        writeStatus("✅ Обновление v" .. latestVer .. " установлено!", COL_OK)
    else
        writeStatus("⚠ Установлено с ошибками", COL_WARN)
    end

    if AUTO_REBOOT then
        for n = 5, 1, -1 do
            text(X + W - 20, Y + H - 2, ("Перезагрузка через %d..."):format(n), COL_TEXT)
            os.sleep(1)
        end
        shell.execute("reboot")
    else
        text(X + 2, Y + H - 2, "Нажмите Enter...", COL_TEXT)
        event.pull("key_down")
    end

    return true
end

-- Запуск
local ok, err = pcall(update)
safeSetBG(oldBG)
safeSetFG(oldFG)
if not ok then
    term.clear()
    print("❌ Ошибка обновления:")
    print(err)
    print("Нажмите Enter...")
    event.pull("key_down")
end

