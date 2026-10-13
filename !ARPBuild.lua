script_name("ARPBuild")
script_version("1.1")

require "lib.moonloader"

local dlstatus = require("moonloader").download_status
local imgui    = require "mimgui"
local encoding = require "encoding"
local ffi      = require "ffi"

encoding.default = "CP1251"
local u8 = encoding.UTF8


local REPO            = "fydami/arp-build-releases"
local RELEASE_API     = "https://api.github.com/repos/" .. REPO .. "/releases/latest"
local RELEASES_PAGE   = "https://github.com/" .. REPO .. "/releases/"
local AUTHOR_NAME     = "puppy femboy"

-- Автообновление самого скрипта ARPBuild.lua (не путать с обновлением сборки выше).
-- В репозитории (ветка SELF_UPDATE_BRANCH) должны лежать два файла:
--   update.json   -> { "version": "1.2", "url": "<прямая ссылка на ARPBuild.lua>", "notes": "что изменилось" }
--   ARPBuild.lua  -> новая версия скрипта (в нём script_version должен совпадать с "version" из update.json)
local SELF_UPDATE_BRANCH  = "main"
local SELF_UPDATE_JSON    = "https://raw.githubusercontent.com/" .. REPO .. "/" .. SELF_UPDATE_BRANCH .. "/update.json"
local SELF_UPDATE_PREFIX  = "https://raw.githubusercontent.com/" .. REPO .. "/"   -- ссылка из манифеста обязана начинаться с этого
local SELF_UPDATE_TIMEOUT = 30        -- секунд на каждую загрузку
local SELF_UPDATE_MAX     = 2 * 1024 * 1024
local SELF_UPDATE_INTERVAL = 1800     -- секунд между повторными проверками во время игры

local ACCENT      = "{00BFFF}"
local CHAT_PREFIX = ACCENT .. "[ARPBuild] {FFFFFF}"

local REPORT_URL         = "https://reports.arp-build.workers.dev/"
local REPORT_KEY         = "z3rUKbMo9PXfydAQgCilaNHp5xmB26tn"
local REPORT_COOLDOWN    = 300
local REPORT_MIN_TEXT    = 10
local REPORT_MAX_LOG     = 256 * 1024
local REPORT_MAX_LOGS    = 9

local GAME_DIR        = getGameDirectory()
local VERSION_FILE    = getWorkingDirectory() .. "\\resource\\ARPBuild\\version.txt"
local CONFIG_DIR      = getWorkingDirectory() .. "\\config\\ARPBuild"
local STATE_FILE      = CONFIG_DIR .. "\\state.json"
local RESPONSE_FILE   = os.getenv("TEMP") .. "\\ARPBuild_latest_release.json"
local REPORT_DIR      = os.getenv("TEMP") .. "\\ARPBuild_report"
local SELF_JSON_FILE  = os.getenv("TEMP") .. "\\ARPBuild_self_update.json"
local SELF_LUA_FILE   = os.getenv("TEMP") .. "\\ARPBuild_self_update.lua"


local COMMANDS = {
    { mod = "ARPBuild", list = {
        { "/arpbuild", "это окно: команды модов, что нового, частые вопросы, связь с разработчиком" },
    } },
    { mod = "AdBlock", list = {
        { "/ads",  "меню AdBlock" },
        { "/tads", "включить или выключить фильтр рекламы" },
    } },
    { mod = "Emergency Services Overhaul", list = {
        { "/esohelp",        "меню и справка ESO" },
        { "X",               "включить сирену" },
    } },
    { mod = "Damage Informer", list = {
        { "/dmgmenu",  "меню Damage Informer" },
    } },
    { mod = "SAPatcher", list = {
        { "/sapatcher", "настройки SAPatcher" },
    } },
}

local FAQ = {
    { "Как вернуть игру, какой она была до установки сборки?",
      "Установщик не удаляет старую игру, а переносит её в папку _backups внутри папки с игрой; у каждой установки своя папка с датой. " ..
      "Закройте игру и лаунчер, удалите из папки с игрой всё, кроме _backups, и перенесите туда файлы из нужной резервной копии." },
    { "Куда ставить свои моды?",
      "В папку modloader\\UserMods: каждая папка внутри - отдельный мод, файлы сборки при этом не заменяются. " ..
      "Установщик ставит игру начисто, поэтому после обновления сборки свои моды нужно перенести заново из папки _backups." },
    { "После обновления пропали мои настройки модов",
      "Установщик переносит настройки, которые вы меняли. Если новая сборка изменила тот же файл, остаётся версия сборки, " ..
      "а ваша лежит в резервной копии в папке _backups по тому же пути." },
    { "Почему отключены плагины и моды лаунчера?",
      "Чтобы они не конфликтовали с модами сборки. Плагин голосового чата можно включить обратно, " ..
      "а CEF со сборкой не проверялся - если включите его, работа сборки не гарантируется." },
    { "Как поставить FBI Helper, если отказался при установке?",
      "Скопируйте содержимое папки \"Опциональные моды\\FBI Helper\" из архива сборки в папку с игрой или запустите установщик ещё раз." },
}


local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function parseVersion(s)
    return type(s) == "string" and s:match("^%s*(%d%d%d%d%d%d%d%d_%d%d%d%d)%s*$") or nil
end

local function listFiles(mask)
    local names = {}
    local handle, name = findFirstFile(mask)
    if handle then
        while name do
            if name ~= "." and name ~= ".." then table.insert(names, name) end
            name = findNextFile(handle)
        end
        findClose(handle)
    end
    return names
end

local function chat(text)
    if isSampAvailable() then
        sampAddChatMessage(CHAT_PREFIX .. text, -1)
    end
end


for _, decl in ipairs({
    "void* __stdcall ShellExecuteA(void* hwnd, const char* op, const char* file, const char* params, const char* dir, int show);",
    [[typedef struct {
        uint32_t cb; void* lpReserved; void* lpDesktop; void* lpTitle;
        uint32_t dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        uint16_t wShowWindow, cbReserved2; void* lpReserved2; void* hStdInput; void* hStdOutput; void* hStdError;
    } ARPB_STARTUPINFOW;]],
    "typedef struct { void* hProcess; void* hThread; uint32_t dwProcessId; uint32_t dwThreadId; } ARPB_PROCESS_INFORMATION;",
    "int __stdcall CreateProcessW(const uint16_t* app, uint16_t* cmd, void* pa, void* ta, int inherit, uint32_t flags, void* env, const uint16_t* dir, ARPB_STARTUPINFOW* si, ARPB_PROCESS_INFORMATION* pi);",
    "uint32_t __stdcall WaitForSingleObject(void* h, uint32_t ms);",
    "int __stdcall GetExitCodeProcess(void* h, uint32_t* code);",
    "int __stdcall TerminateProcess(void* h, uint32_t code);",
    "int __stdcall CloseHandle(void* h);",
    "int __stdcall MultiByteToWideChar(uint32_t cp, uint32_t flags, const char* s, int n, uint16_t* w, int wn);",
}) do
    pcall(ffi.cdef, decl)
end

local shell32 = ffi.load("shell32")
local CREATE_NO_WINDOW = 0x08000000

local function openUrl(url)
    shell32.ShellExecuteA(nil, "open", url, nil, nil, 1)
end

local function toWide(s)
    local n = ffi.C.MultiByteToWideChar(0, 0, s, -1, nil, 0)
    local buf = ffi.new("uint16_t[?]", n)
    ffi.C.MultiByteToWideChar(0, 0, s, -1, buf, n)
    return buf
end

local function runHidden(args, timeoutSec)
    local quoted = {}
    for i, a in ipairs(args) do quoted[i] = '"' .. a .. '"' end

    local si = ffi.new("ARPB_STARTUPINFOW")
    si.cb = ffi.sizeof(si)
    local pi = ffi.new("ARPB_PROCESS_INFORMATION")
    if ffi.C.CreateProcessW(nil, toWide(table.concat(quoted, " ")), nil, nil, 0, CREATE_NO_WINDOW, nil, nil, si, pi) == 0 then
        return nil
    end
    ffi.C.CloseHandle(pi.hThread)

    local deadline = os.clock() + timeoutSec
    while ffi.C.WaitForSingleObject(pi.hProcess, 0) ~= 0 do
        if os.clock() > deadline then
            ffi.C.TerminateProcess(pi.hProcess, 1)
            ffi.C.CloseHandle(pi.hProcess)
            return nil
        end
        wait(200)
    end

    local code = ffi.new("uint32_t[1]")
    ffi.C.GetExitCodeProcess(pi.hProcess, code)
    ffi.C.CloseHandle(pi.hProcess)
    return code[0]
end


local state = {}

local function loadState()
    local ok, t = pcall(decodeJson, readFile(STATE_FILE) or "")
    state = (ok and type(t) == "table") and t or {}
end

local function saveState()
    if not doesDirectoryExist(CONFIG_DIR) then createDirectory(CONFIG_DIR) end
    writeFile(STATE_FILE, encodeJson(state))
end


local function parseChangelog(text)
    local lines = {}
    for line in (text:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("`", "")
        local header = line:match("^##%s+(.+)")
        local item = line:match("^%s*[%-%*]%s+(.+)")
        if header then
            table.insert(lines, { kind = "header", text = header })
        elseif line:match("^%-%-%-%-") then
            table.insert(lines, { kind = "separator" })
        elseif item then
            table.insert(lines, { kind = "item", text = item })
        elseif line:match("%S") then
            table.insert(lines, { kind = "text", text = line })
        end
    end
    return lines
end

local function loadInstalledChanges()
    local best
    for _, name in ipairs(listFiles(GAME_DIR .. "\\#*.md")) do
        if parseVersion(name:match("^#(.+)%.md$")) and (not best or name > best) then best = name end
    end
    local text = best and readFile(GAME_DIR .. "\\" .. best)
    if not text then return nil end

    local section = { title = nil, lines = {} }
    for _, line in ipairs(parseChangelog(text)) do
        if line.kind == "header" then
            if section.title then break end
            section.title = line.text
        elseif line.kind == "separator" then
            break
        else
            table.insert(section.lines, line)
        end
    end
    return section
end


local installed = parseVersion(readFile(VERSION_FILE))
local update    = nil
local check     = { running = false, done = false, result = nil }

local function checkForUpdate()
    if not installed or check.running then return end
    check.running, check.done, check.result = true, false, nil
    if doesFileExist(RESPONSE_FILE) then os.remove(RESPONSE_FILE) end

    downloadUrlToFile(RELEASE_API .. "?t=" .. os.time(), RESPONSE_FILE, function(id, status)
        if status ~= dlstatus.STATUSEX_ENDDOWNLOAD then return end
        check.running, check.done = false, true

        local data = readFile(RESPONSE_FILE)
        os.remove(RESPONSE_FILE)
        local ok, release = pcall(decodeJson, data or "")
        local latest = ok and type(release) == "table" and parseVersion(release.tag_name)
        if not latest then
            check.result = "error"
            return
        end
        if latest <= installed then
            check.result, update = "latest", nil
            return
        end

        local url = RELEASES_PAGE .. "tag/" .. latest
        local downloadPrefix = RELEASES_PAGE .. "download/" .. latest .. "/"
        for _, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
            local link = asset.browser_download_url
            if type(link) == "string" and link:sub(1, #downloadPrefix) == downloadPrefix and not link:find("[%s\"]") then
                url = link
                break
            end
        end

        check.result = "available"
        update = { version = latest, url = url, lines = parseChangelog(type(release.body) == "string" and release.body or "") }
    end)
end


-- ===== Автообновление самого скрипта =====

local selfUpdate = {
    status    = "idle",   -- idle | checking | available | downloading | ready | latest | error | updated
    info      = nil,      -- { version, url, notes }
    message   = nil,
    startedAt = 0,
    auto      = imgui.new.bool(true),
}

local function versionParts(v)
    local parts = {}
    for n in tostring(v or ""):gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
    return parts
end

-- true, если a новее b
local function isNewerVersion(a, b)
    local pa, pb = versionParts(a), versionParts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local function selfFail(text)
    selfUpdate.status, selfUpdate.message = "error", text
    if doesFileExist(SELF_JSON_FILE) then os.remove(SELF_JSON_FILE) end
    if doesFileExist(SELF_LUA_FILE) then os.remove(SELF_LUA_FILE) end
end

local function checkSelfUpdate()
    if selfUpdate.status == "checking" or selfUpdate.status == "downloading" then return end
    selfUpdate.status, selfUpdate.message, selfUpdate.startedAt = "checking", nil, os.clock()
    if doesFileExist(SELF_JSON_FILE) then os.remove(SELF_JSON_FILE) end

    downloadUrlToFile(SELF_UPDATE_JSON .. "?t=" .. os.time(), SELF_JSON_FILE, function(id, status)
        if status ~= dlstatus.STATUSEX_ENDDOWNLOAD then return end
        if selfUpdate.status ~= "checking" then return end

        local data = readFile(SELF_JSON_FILE)
        os.remove(SELF_JSON_FILE)
        local ok, manifest = pcall(decodeJson, data or "")
        if not ok or type(manifest) ~= "table" or type(manifest.version) ~= "string" or type(manifest.url) ~= "string" then
            return selfFail("Не удалось прочитать данные об обновлении скрипта.")
        end
        if manifest.url:sub(1, #SELF_UPDATE_PREFIX) ~= SELF_UPDATE_PREFIX or manifest.url:find("[%s\"]") then
            return selfFail("Ссылка на обновление скрипта указывает не на репозиторий сборки. Обновление отменено.")
        end
        if not isNewerVersion(manifest.version, thisScript().version) then
            selfUpdate.status, selfUpdate.info = "latest", nil
            return
        end
        selfUpdate.status = "available"
        selfUpdate.info = { version = manifest.version, url = manifest.url, notes = type(manifest.notes) == "string" and manifest.notes or "" }
    end)
end

local function downloadSelfUpdate()
    local info = selfUpdate.info
    if selfUpdate.status ~= "available" or not info then return end
    selfUpdate.status, selfUpdate.startedAt = "downloading", os.clock()
    if doesFileExist(SELF_LUA_FILE) then os.remove(SELF_LUA_FILE) end

    downloadUrlToFile(info.url .. "?t=" .. os.time(), SELF_LUA_FILE, function(id, status)
        if status ~= dlstatus.STATUSEX_ENDDOWNLOAD then return end
        if selfUpdate.status ~= "downloading" then return end

        local data = readFile(SELF_LUA_FILE)
        if not data or #data < 200 or #data > SELF_UPDATE_MAX then
            return selfFail("Скачанный файл обновления пустой или слишком большой.")
        end
        -- это должен быть именно наш скрипт нужной версии, а не страница ошибки
        if not data:find('script_name%("ARPBuild"%)') then
            return selfFail("Скачанный файл не похож на скрипт ARPBuild. Обновление отменено.")
        end
        local newVersion = data:match('script_version%("([^"]+)"%)')
        if newVersion ~= info.version then
            return selfFail("Версия в скачанном файле не совпадает с update.json. Обновление отменено.")
        end
        -- синтаксис проверяем до замены, чтобы не сломать рабочий скрипт
        local compiled, err = loadstring(data, "=ARPBuild_update")
        if not compiled then
            return selfFail("Скачанный файл содержит ошибку, обновление отменено: " .. tostring(err))
        end
        selfUpdate.status = "ready"
    end)
end

-- Заменяет файл скрипта и перезагружает его. Вызывается только из основного потока.
local function applySelfUpdate()
    local info = selfUpdate.info
    local path = thisScript().path
    local data = readFile(SELF_LUA_FILE)
    local old = readFile(path)
    if not (info and data and old) then
        return selfFail("Не удалось прочитать файлы для замены скрипта.")
    end

    local backup = path .. ".bak"
    writeFile(backup, old)

    if not writeFile(path, data) then
        writeFile(path, old)
        return selfFail("Не удалось записать новый файл скрипта. Старая версия сохранена.")
    end
    os.remove(SELF_LUA_FILE)

    state.updatedFrom, state.updatedTo = thisScript().version, info.version
    saveState()
    chat("Скрипт обновляется до версии " .. ACCENT .. info.version .. "{FFFFFF}, перезагрузка...")
    wait(300)
    thisScript():reload()
end

local function selfUpdateWatchdog()
    local s = selfUpdate.status
    if (s == "checking" or s == "downloading") and os.clock() - selfUpdate.startedAt > SELF_UPDATE_TIMEOUT then
        selfFail("Сервер обновлений не ответил вовремя. Попробуйте позже.")
    end
end

-- Работает в отдельном потоке с самого запуска: не ждёт спавна игрока и проверки сборки.
local function selfUpdateLoop()
    local announced, lastCheck = nil, os.clock()

    while true do
        wait(500)
        selfUpdateWatchdog()
        local s = selfUpdate.status

        if s == "available" and selfUpdate.info then
            if announced ~= selfUpdate.info.version then
                announced = selfUpdate.info.version
                if selfUpdate.auto[0] then
                    downloadSelfUpdate()
                else
                    chat("Доступна новая версия скрипта: " .. ACCENT .. selfUpdate.info.version .. "{FFFFFF}. Установить: /arpbuild")
                end
            end
        elseif s == "ready" then
            applySelfUpdate()
        elseif selfUpdate.auto[0] and (s == "idle" or s == "latest" or s == "error")
               and os.clock() - lastCheck > SELF_UPDATE_INTERVAL then
            lastCheck = os.clock()
            checkSelfUpdate()
        end
    end
end


local report = {
    buf      = imgui.new.char[2048](),
    contact  = imgui.new.char[128](),
    sending  = false,
    status   = nil,
    ok       = false,
    lastSent = 0,
}

local function clearReportDir()
    if not doesDirectoryExist(REPORT_DIR) then
        createDirectory(REPORT_DIR)
        return
    end
    for _, name in ipairs(listFiles(REPORT_DIR .. "\\*")) do
        os.remove(REPORT_DIR .. "\\" .. name)
    end
end

local LOG_DIRS = { "", "moonloader", "SAMPFUNCS", "modloader", "CLEO" }

local function collectLogs()
    local files = {}
    for _, sub in ipairs(LOG_DIRS) do
        local dir = sub == "" and GAME_DIR or (GAME_DIR .. "\\" .. sub)
        for _, name in ipairs(listFiles(dir .. "\\*.log")) do
            if #files >= REPORT_MAX_LOGS then return files end
            local data = readFile(dir .. "\\" .. name)
            if data and #data > 0 then
                if #data > REPORT_MAX_LOG then data = data:sub(-REPORT_MAX_LOG) end
                local copy = REPORT_DIR .. "\\" .. (sub == "" and "" or (sub .. "_")) .. name
                if writeFile(copy, data) then table.insert(files, copy) end
            end
        end
    end
    return files
end

local function playerInfo()
    local nick, server = "?", "?"
    if isSampAvailable() then
        local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        if ok then nick = sampGetPlayerNickname(id) end
        local ip, port = sampGetCurrentServerAddress()
        server = sampGetCurrentServerName() .. " (" .. tostring(ip) .. ":" .. tostring(port) .. ")"
    end
    return u8(nick), u8(server)
end

local function finishReport(ok, text)
    report.sending, report.ok, report.status = false, ok, u8(text)
end

local function sendReport(message, contact)
    report.sending, report.status = true, nil
    clearReportDir()

    local nick, server = playerInfo()
    local fields = {
        message = message,
        contact = contact,
        nick    = nick,
        server  = server,
        version = installed or "?",
    }

    local args = { "curl.exe", "-s", "-S", "--max-time", "90",
        "-H", "X-ARPBuild-Key: " .. REPORT_KEY,
        "-D", REPORT_DIR .. "\\headers.txt",
        "-o", REPORT_DIR .. "\\response.txt" }
    for name, value in pairs(fields) do
        local path = REPORT_DIR .. "\\" .. name .. ".txt"
        writeFile(path, value)
        table.insert(args, "-F")
        table.insert(args, name .. "=<" .. path)
    end
    for i, path in ipairs(collectLogs()) do
        table.insert(args, "-F")
        table.insert(args, "log" .. i .. "=@" .. path)
    end
    table.insert(args, REPORT_URL)

    local exitCode = runHidden(args, 120)
    local httpStatus
    for s in (readFile(REPORT_DIR .. "\\headers.txt") or ""):gmatch("HTTP/[%d%.]+%s+(%d+)") do
        httpStatus = tonumber(s)
    end
    local accepted = (readFile(REPORT_DIR .. "\\response.txt") or ""):find('"ok"%s*:%s*true') ~= nil
    clearReportDir()

    if exitCode == nil and not httpStatus then
        finishReport(false, "Не удалось отправить: не найден curl.exe (нужна Windows 10 1803 или новее) или сервер не ответил вовремя.")
    elseif httpStatus == 200 and not accepted then
        finishReport(false, "Сервер приёма сообщений настроен неверно. Попробуйте позже.")
    elseif httpStatus == 200 then
        report.lastSent = os.time()
        report.buf[0] = 0
        finishReport(true, "Сообщение отправлено. Разработчик свяжется с вами по указанному контакту.")
    elseif httpStatus == 429 then
        finishReport(false, "Слишком частые сообщения. Попробуйте через несколько минут.")
    elseif httpStatus then
        finishReport(false, "Сервер отклонил сообщение (код " .. httpStatus .. "). Попробуйте позже.")
    else
        finishReport(false, "Не удалось связаться с сервером. Проверьте интернет и попробуйте позже.")
    end
end


local PAGE_HOME, PAGE_COMMANDS, PAGE_CHANGELOG, PAGE_FAQ, PAGE_REPORT = 1, 2, 3, 4, 5
local PAGES = { "Главная", "Команды", "Что нового", "Частые вопросы", "Связь с разработчиком" }

local readme = { show = imgui.new.bool(false), page = PAGE_HOME, changes = nil }

local function openReadme(page)
    if page then readme.page = page end
    readme.show[0] = true
end

local accentColor, okColor, errorColor, dimColor

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    accentColor = imgui.ImVec4(0.0, 0.75, 1.0, 1.0)
    okColor     = imgui.ImVec4(0.4, 0.9, 0.4, 1.0)
    errorColor  = imgui.ImVec4(1.0, 0.45, 0.4, 1.0)
    dimColor    = imgui.ImVec4(0.65, 0.65, 0.65, 1.0)
end)

local function text(s) imgui.TextUnformatted(s) end

local function wrapped(s)
    imgui.PushTextWrapPos(0)
    imgui.TextUnformatted(s)
    imgui.PopTextWrapPos()
end

local function colored(color, s, wrap)
    imgui.PushStyleColor(imgui.Col.Text, color)
    if wrap then wrapped(s) else text(s) end
    imgui.PopStyleColor(1)
end

local function validDiscord(name)
    return #name >= 2 and #name <= 32 and name:match("^[a-z0-9_.]+$") ~= nil and not name:find("..", 1, true)
end

local function button(label, size, enabled)
    if enabled then return imgui.Button(label, size) end
    local color = imgui.GetStyle().Colors[imgui.Col.Button]
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, 0.4)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, color)
    imgui.PushStyleColor(imgui.Col.ButtonActive, color)
    imgui.Button(label, size)
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(1)
    return false
end

local function centerNextWindow(w, h)
    local io = imgui.GetIO()
    imgui.SetNextWindowPos(imgui.ImVec2(io.DisplaySize.x / 2, io.DisplaySize.y / 2), imgui.Cond.Appearing, imgui.ImVec2(0.5, 0.5))
    if w then imgui.SetNextWindowSize(imgui.ImVec2(w, h), imgui.Cond.Appearing) end
end

local drawSelfUpdate

local function drawHome()
    colored(accentColor, u8"Сборка модов ARPBuild для Advance RP")
    text(u8("Установленная версия: " .. (installed or "неизвестна")))
    imgui.Spacing()
    wrapped(u8"Здесь собрано всё о сборке: команды модов, список изменений, ответы на частые вопросы и связь с разработчиком. " ..
            u8"Открыть это окно снова можно командой /arpbuild.")

    imgui.Spacing(); imgui.Separator(); imgui.Spacing()
    text(u8("Автор сборки: " .. AUTHOR_NAME))
    imgui.Spacing()
    colored(dimColor, u8"Скачивайте сборку только со страницы релизов на GitHub: копии с других сайтов могут быть изменены.", true)
    if imgui.Button(u8"Открыть страницу релизов") then openUrl(RELEASES_PAGE) end

    imgui.Spacing(); imgui.Separator(); imgui.Spacing()
    if not installed then
        colored(dimColor, u8"Проверка обновлений недоступна: версия сборки неизвестна.", true)
        drawSelfUpdate()
        return
    end
    if check.running then
        text(u8"Проверка обновлений...")
    elseif imgui.Button(u8"Проверить обновления") then
        checkForUpdate()
    end
    if check.done then
        if check.result == "available" and update then
            colored(okColor, u8("Доступна новая версия: " .. update.version))
            imgui.SameLine()
            if imgui.Button(u8"Подробнее") then readme.page = PAGE_CHANGELOG end
        elseif check.result == "latest" then
            colored(okColor, u8"Установлена последняя версия.")
        else
            colored(errorColor, u8"Не удалось проверить обновления. Попробуйте позже.")
        end
    end
    drawSelfUpdate()
end

function drawSelfUpdate()
    imgui.Spacing(); imgui.Separator(); imgui.Spacing()
    colored(accentColor, u8"Обновление скрипта")
    text(u8("Версия скрипта: " .. thisScript().version))

    local s = selfUpdate.status
    if s == "checking" then
        text(u8"Проверка обновлений скрипта...")
    elseif s == "downloading" then
        text(u8"Загрузка обновления...")
    elseif s == "available" and selfUpdate.info then
        colored(okColor, u8("Доступна новая версия скрипта: " .. selfUpdate.info.version))
        if selfUpdate.info.notes ~= "" then wrapped(selfUpdate.info.notes) end
        if imgui.Button(u8"Обновить скрипт") then downloadSelfUpdate() end
    elseif s == "ready" then
        text(u8"Обновление загружено, применяется...")
    else
        if imgui.Button(u8"Проверить обновление скрипта") then checkSelfUpdate() end
        if s == "latest" then
            imgui.SameLine()
            colored(okColor, u8"Установлена последняя версия скрипта.")
        end
    end
    if s == "error" and selfUpdate.message then
        colored(errorColor, u8(selfUpdate.message), true)
    end

    imgui.Spacing()
    colored(dimColor, u8"Скрипт обновляется автоматически при запуске игры и каждые 30 минут.", true)
end

local function drawCommands()
    for i, group in ipairs(COMMANDS) do
        if i > 1 then imgui.Spacing() end
        colored(accentColor, u8(group.mod))
        for _, cmd in ipairs(group.list) do
            text(u8(cmd[1]))
            imgui.SameLine(170)
            wrapped(u8(cmd[2]))
        end
    end
end

local function drawChangeLines(lines)
    for _, line in ipairs(lines) do
        if line.kind == "header" then
            imgui.Spacing()
            colored(accentColor, line.text)
        elseif line.kind == "separator" then
            imgui.Separator()
        elseif line.kind == "item" then
            imgui.Bullet()
            imgui.SameLine()
            wrapped(line.text)
        else
            wrapped(line.text)
        end
    end
end

local function drawChangelog()
    if update then
        colored(okColor, u8("Доступна новая версия сборки: " .. update.version))
        imgui.Spacing()
        if #update.lines > 0 then
            drawChangeLines(update.lines)
        else
            colored(dimColor, u8"Описание изменений не указано.")
        end

        imgui.Spacing(); imgui.Separator(); imgui.Spacing()
        if imgui.Button(u8"Скачать", imgui.ImVec2(140, 0)) then
            openUrl(update.url)
            chat("Ссылка на новую версию открыта в браузере.")
        end
        imgui.SameLine()
        if update.version == state.skippedVersion then
            colored(dimColor, u8"Напоминания об этой версии отключены.")
        elseif imgui.Button(u8"Не напоминать об этой версии") then
            state.skippedVersion = update.version
            saveState()
        end
        return
    end

    if not readme.changes then readme.changes = loadInstalledChanges() or { lines = {} } end
    if readme.changes.title then
        colored(accentColor, u8"Изменения в версии " .. readme.changes.title)
        imgui.Spacing()
    end
    if #readme.changes.lines > 0 then
        drawChangeLines(readme.changes.lines)
    else
        colored(dimColor, u8"Список изменений не найден.")
    end
end

local function drawFaq()
    for _, item in ipairs(FAQ) do
        if imgui.CollapsingHeader(u8(item[1])) then
            imgui.Indent()
            wrapped(u8(item[2]))
            imgui.Unindent()
            imgui.Spacing()
        end
    end
end

local function drawReport()
    if REPORT_URL == "" then
        wrapped(u8"Отправка сообщений пока не настроена.")
        return
    end

    wrapped(u8"Вопрос, предложение или проблема со сборкой - напишите, и разработчик свяжется с вами. " ..
            u8"Если игра вылетает, опишите, что вы делали перед вылетом.")
    imgui.Spacing()

    text(u8"Ваш Discord:")
    imgui.PushItemWidth(-1)
    imgui.InputText("##contact", report.contact, ffi.sizeof(report.contact))
    imgui.PopItemWidth()

    imgui.Spacing()
    text(u8"Сообщение:")
    imgui.InputTextMultiline("##report", report.buf, ffi.sizeof(report.buf), imgui.ImVec2(-1, 150))

    imgui.Spacing()
    colored(dimColor, u8"Вместе с сообщением отправятся ваш ник, сервер, версия сборки, логи MoonLoader, SAMPFUNCS, modloader " ..
                      u8"и другие .log-файлы из папки игры. Чатлог и личные переписки не отправляются.", true)
    imgui.Spacing()

    local function length(s) return #s:gsub("[\128-\191]", "") end
    local message = ffi.string(report.buf)
    local contact = ffi.string(report.contact):match("^%s*@?(.-)%s*$"):lower()
    local cooldown = report.lastSent + REPORT_COOLDOWN - os.time()

    local reason
    if report.sending then
        reason = "Отправка..."
    elseif cooldown > 0 then
        reason = ("Следующее сообщение можно отправить через %d:%02d"):format(math.floor(cooldown / 60), cooldown % 60)
    elseif contact == "" then
        reason = "Укажите свой Discord."
    elseif not validDiscord(contact) then
        reason = "Discord-ник: латинские буквы, цифры, _ и точка, от 2 до 32 символов."
    elseif length(message) < REPORT_MIN_TEXT then
        reason = "Сообщение должно быть не короче " .. REPORT_MIN_TEXT .. " символов."
    end

    if button(u8"Отправить", imgui.ImVec2(140, 0), reason == nil) then
        lua_thread.create(sendReport, message, contact)
    end
    if reason then
        imgui.SameLine()
        imgui.AlignTextToFramePadding()
        colored(dimColor, u8(reason))
    end

    if report.status then
        imgui.Spacing()
        colored(report.ok and okColor or errorColor, report.status, true)
    end
end

local PAGE_DRAW = { drawHome, drawCommands, drawChangelog, drawFaq, drawReport }

local readmeFrame = imgui.OnFrame(function() return readme.show[0] end, function()
    centerNextWindow(780, 500)
    imgui.Begin("ARPBuild", readme.show, imgui.WindowFlags.NoCollapse)

    imgui.BeginChild("nav", imgui.ImVec2(180, 0), true)
    for i, name in ipairs(PAGES) do
        if imgui.Selectable(u8(name), readme.page == i) then readme.page = i end
    end
    imgui.EndChild()

    imgui.SameLine()
    imgui.BeginChild("page", imgui.ImVec2(0, 0), true)
    PAGE_DRAW[readme.page]()
    imgui.EndChild()

    imgui.End()
end)
readmeFrame.LockPlayer = true


function main()
    loadState()
    selfUpdate.auto[0] = true
    checkForUpdate()
    if selfUpdate.auto[0] then checkSelfUpdate() end
	lua_thread.create(selfUpdateLoop)

    if isSampLoaded() then
        while not isSampAvailable() do wait(100) end
        sampRegisterChatCommand("arpbuild", function()
            readme.show[0] = not readme.show[0]
        end)
        while not sampIsLocalPlayerSpawned() do wait(100) end
    end

    chat("Сборка " .. ACCENT .. (installed or "") .. "{FFFFFF} загружена. Помощь и команды модов: " .. ACCENT .. "/arpbuild")

    local function freshUpdate()
        return update ~= nil and update.version ~= state.skippedVersion
    end

    local current = installed or "unknown"
    local announced = freshUpdate()
    if announced then
        chat("Доступна новая версия сборки: " .. ACCENT .. update.version)
        openReadme(PAGE_CHANGELOG)
    elseif not state.seenVersion then
        openReadme(PAGE_HOME)
    elseif state.seenVersion ~= current then
        openReadme(PAGE_CHANGELOG)
    end
    if state.seenVersion ~= current then
        state.seenVersion = current
        saveState()
    end

    if not announced then
        while installed and not check.done do wait(500) end
        if freshUpdate() then
            chat("Доступна новая версия сборки: " .. ACCENT .. update.version)
            if not readme.show[0] then openReadme(PAGE_CHANGELOG) end
        end
    end

    if state.updatedTo then
        if state.updatedTo == thisScript().version then
            chat("Скрипт обновлён: " .. (state.updatedFrom or "?") .. " -> " .. ACCENT .. state.updatedTo)
        end
        state.updatedFrom, state.updatedTo = nil, nil
        saveState()
    end

    wait(-1)
end
