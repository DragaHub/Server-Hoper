local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local LocalizationService = game:GetService("LocalizationService")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

if not Players.LocalPlayer then
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
end
local LocalPlayer = Players.LocalPlayer

-- Mirror URLs for self-restart after teleport (setQueue below).
local SETTINGS_FILE = "ServerFinderConfig.json"
local VISITED_FILE = "ServerFinderVisited.json"
local MAX_VISITED = 200
local MAX_API_PAGES = 8
local HTTP_RETRIES = 4
local MAX_COUNTRY_LOOKUPS = 4
local TARGET_CANDIDATES = 60
local TELEPORT_TIMEOUT = 6
local GUI_MIN_SCALE = 0.55
local VERSION = "2.13"

local guiAlive = true
local isHopping = false
local hopToken = 0
local evaluateToken = 0
local minimized = false
local pendingServerId = nil
local sessionStats = {
    hops = 0,
    failures = 0,
}
local RNG = Random.new()

local globalConns = {}
local function rememberConnection(conn)
    table.insert(globalConns, conn)
    return conn
end

local function disconnectConnections(list)
    for _, conn in ipairs(list) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    table.clear(list)
end

local function executorEnvironment()
    if type(getgenv) ~= "function" then return nil end
    local ok, env = pcall(getgenv)
    return ok and type(env) == "table" and env or nil
end

local function setQueue()
    local env = executorEnvironment()
    local q = queue_on_teleport
        or (type(syn) == "table" and syn.queue_on_teleport)
        or (type(fluxus) == "table" and fluxus.queue_on_teleport)
        or (env and env.queue_on_teleport)
    if type(q) ~= "function" then return false end
    local mirrorList = table.concat({
        "\"https://raw.githack.com/DragaHub/Server-Hoper/main/main.lua\"",
        "\"https://raw.githubusercontent.com/DragaHub/Server-Hoper/main/main.lua\"",
        "\"https://github.com/DragaHub/Server-Hoper/raw/main/main.lua\"",
        "\"https://cdn.jsdelivr.net/gh/DragaHub/Server-Hoper@main/main.lua\"",
    }, ", ")
    local ok = pcall(function()
        q(string.format([[
            repeat task.wait() until game:IsLoaded()
            local lp = game:GetService("Players").LocalPlayer
            if not lp then
                game:GetService("Players"):GetPropertyChangedSignal("LocalPlayer"):Wait()
            end
            local urls = { %s }
            for _, u in ipairs(urls) do
                local ok2, body = pcall(function() return game:HttpGet(u) end)
                if ok2 and type(body) == "string" and body ~= "" and body:find('SERVER FINDER', 1, true) then
                    local chunk = loadstring(body)
                    if chunk then
                        chunk()
                        break
                    end
                end
            end
        ]], mirrorList))
    end)
    return ok
end

local function getHttpRequest()
    local env = executorEnvironment()
    return request
        or http_request
        or (type(syn) == "table" and syn.request)
        or (type(http) == "table" and http.request)
        or (type(fluxus) == "table" and fluxus.request)
        or (env and (env.request or env.http_request))
end

local function canReadFile(path)
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return false end
    local ok, exists = pcall(isfile, path)
    return ok and exists == true
end

-- LRU history. The legacy { [jobId] = true } format is migrated safely.
local function visitedTimestamp(value)
    if type(value) == "number" and value == value and value >= 0 then
        return value
    end
    return 0
end

local function pruneVisited(data, keep)
    keep = math.max(1, math.floor(tonumber(keep) or MAX_VISITED))
    local entries = {}
    for id, value in pairs(data) do
        if type(id) == "string" and #id > 0 and #id <= 100 then
            table.insert(entries, { id = id, ts = visitedTimestamp(value) })
        else
            data[id] = nil
        end
    end
    if #entries <= keep then
        return data
    end
    table.sort(entries, function(a, b)
        if a.ts == b.ts then
            return a.id < b.id
        end
        return a.ts < b.ts
    end)
    local overflow = #entries - keep
    for i = 1, overflow do
        data[entries[i].id] = nil
    end
    return data
end

local function loadVisited()
    if canReadFile(VISITED_FILE) then
        local success, result = pcall(function()
            return HttpService:JSONDecode(readfile(VISITED_FILE))
        end)
        if success and type(result) == "table" then
            local clean = {}
            for id, value in pairs(result) do
                if type(id) == "string" and #id > 0 and #id <= 100
                    and (type(value) == "number" or value == true)
                then
                    clean[id] = visitedTimestamp(value)
                end
            end
            return pruneVisited(clean)
        end
    end
    return {}
end

local function saveVisited(data)
    if type(writefile) == "function" then
        pcall(function()
            writefile(VISITED_FILE, HttpService:JSONEncode(data))
        end)
    end
end

local visitedServers = loadVisited()
if type(game.JobId) == "string" and game.JobId ~= "" then
    visitedServers[game.JobId] = os.time()
end
visitedServers = pruneVisited(visitedServers)
saveVisited(visitedServers)

-- Servers that just failed (typically the slot filled up before our
-- teleport landed) are kept out of the candidate pool for a short
-- cooldown. Without this, a rolled-back server is instantly re-selected,
-- fails again, and the hopper looks permanently stuck on a full server.
local failedServers = {}

-- Rate-limit guard for games.roblox.com. Roblox caps how many public
-- server-list requests one IP may send per minute; a 429 means the cap
-- was hit. The cooldown doubles on repeated 429s, is persisted to disk
-- so it survives teleports (every hop runs a fresh script instance) and
-- decays again once the API answers normally.
local RATE_LIMIT_FILE = "ServerFinderRateLimit.json"
local rateLimitBackoff = 8
local rateLimitedUntilEpoch = 0

if canReadFile(RATE_LIMIT_FILE) then
    pcall(function()
        local v = tonumber(HttpService:JSONDecode(readfile(RATE_LIMIT_FILE)))
        if type(v) == "number" and v > 0 then
            rateLimitedUntilEpoch = v
        end
    end)
end

local function rateLimitCooldown()
    return math.max(0, rateLimitedUntilEpoch - os.time())
end

local function noteRateLimited(retryAfter)
    if type(retryAfter) == "number" and retryAfter > 0 then
        rateLimitBackoff = math.min(120, math.max(rateLimitBackoff, retryAfter))
    else
        rateLimitBackoff = math.min(120, rateLimitBackoff * 2)
    end
    rateLimitedUntilEpoch = os.time() + rateLimitBackoff
    pcall(function()
        if type(writefile) == "function" then
            writefile(RATE_LIMIT_FILE, HttpService:JSONEncode(rateLimitedUntilEpoch))
        end
    end)
end

local function noteRateLimitOk()
    if rateLimitedUntilEpoch > os.time() or rateLimitBackoff > 8 then
        if rateLimitBackoff > 8 then
            rateLimitBackoff = math.max(8, math.floor(rateLimitBackoff / 2))
        end
        rateLimitedUntilEpoch = 0
        pcall(function()
            if type(writefile) == "function" then
                writefile(RATE_LIMIT_FILE, HttpService:JSONEncode(0))
            end
        end)
    end
end

-- Persisted candidate pool. After a scan we use only ONE server and
-- stash the rest here, so later hops can pick a server without calling
-- the games API at all. This keeps the 429 rate limit cold. Entries
-- older than a few minutes are dropped on load (they go stale as
-- servers fill up).
local serverPool = {}
pcall(function()
    if canReadFile("ServerFinderPool.json") then
        local ok, data = pcall(function()
            return HttpService:JSONDecode(readfile("ServerFinderPool.json"))
        end)
        if ok and type(data) == "table" then
            for _, s in ipairs(data) do
                if type(s) == "table" and type(s.id) == "string" and s.id ~= ""
                    and #s.id <= 100 and type(s.ts) == "number"
                    and (os.time() - s.ts) <= 300
                then
                    table.insert(serverPool, s)
                end
            end
        end
    end
end)

local function forgetOldestVisited(keep)
    visitedServers = pruneVisited(visitedServers, keep)
    if type(game.JobId) == "string" and game.JobId ~= "" then
        visitedServers[game.JobId] = os.time()
    end
    saveVisited(visitedServers)
end

local function countVisited()
    local n = 0
    for _ in pairs(visitedServers) do
        n = n + 1
    end
    return n
end

-- Settings are whitelisted and normalized so a damaged JSON file cannot break the UI.
-- Theme palette table. Defined before loadSettings so normalizeSettings
-- can validate the persisted theme name against it.
local THEMES = {
    ["SNOW"] = { ink = Color3.fromRGB(255, 255, 255), bg = Color3.fromRGB(0, 0, 0) },
    ["TERMINAL GREEN"] = { ink = Color3.fromRGB(120, 255, 160), bg = Color3.fromRGB(0, 0, 0) },
    ["AMBER"] = { ink = Color3.fromRGB(255, 178, 80), bg = Color3.fromRGB(0, 0, 0) },
    ["CYAN"] = { ink = Color3.fromRGB(90, 220, 255), bg = Color3.fromRGB(0, 0, 0) },
    ["MAGENTA"] = { ink = Color3.fromRGB(255, 110, 235), bg = Color3.fromRGB(0, 0, 0) },
    ["RED"] = { ink = Color3.fromRGB(255, 95, 95), bg = Color3.fromRGB(0, 0, 0) },
    ["BLUE"] = { ink = Color3.fromRGB(110, 150, 255), bg = Color3.fromRGB(0, 0, 0) },
    ["RICK AND MORTY"] = { ink = Color3.fromRGB(163, 255, 71), bg = Color3.fromRGB(8, 22, 12) },
}

local defaultSettings = {
    AutoHop = false,
    FilterDonators = true,
    FilterChat = false,
    MinPlayers = 3,
    MinFreeSlots = 2,
    MinFps = 0,
    AnalyzeSeconds = 8,
    SelectionMode = "SMART",
    MaxPing = 0,
    PeopleRegion = "ANY",
    MinRegionPercent = 35,
    Animations = true,
    AntiAfk = true,
    PortalGate = true,
    Theme = "SNOW",
    MainX = -170,
    MainY = -270,
    Welcomed = false,
}

local VALID_REGIONS = {
    ANY = true, RUSSIAN = true, CIS = true, EUROPE = true,
    ["N.AMERICA"] = true, ["S.AMERICA"] = true, ASIA = true, OCEANIA = true,
}
local VALID_SELECTION_MODES = {
    SMART = true,
    FULL = true,
    ["LOW PING"] = true,
    RANDOM = true,
}
local function copyDefaults()
    local result = {}
    for key, value in pairs(defaultSettings) do
        result[key] = value
    end
    return result
end

local function finiteNumber(value, fallback)
    if type(value) ~= "number" then return fallback end
    if value ~= value or value == math.huge or value == -math.huge then return fallback end
    return value
end

local function normalizeSettings(cfg)
    for _, key in ipairs({ "AutoHop", "FilterDonators", "FilterChat", "Animations", "AntiAfk", "PortalGate", "Welcomed" }) do
        if type(cfg[key]) ~= "boolean" then
            cfg[key] = defaultSettings[key]
        end
    end
    cfg.MinPlayers = math.clamp(math.floor(finiteNumber(cfg.MinPlayers, defaultSettings.MinPlayers)), 1, 100)
    cfg.MinFreeSlots = math.clamp(math.floor(finiteNumber(cfg.MinFreeSlots, defaultSettings.MinFreeSlots)), 1, 20)
    cfg.AnalyzeSeconds = math.clamp(math.floor(finiteNumber(cfg.AnalyzeSeconds, defaultSettings.AnalyzeSeconds)), 2, 20)
    cfg.MaxPing = math.clamp(math.floor(finiteNumber(cfg.MaxPing, defaultSettings.MaxPing)), 0, 500)
    cfg.MinFps = math.clamp(math.floor(finiteNumber(cfg.MinFps, defaultSettings.MinFps)), 0, 60)
    cfg.MinRegionPercent = math.clamp(math.floor(finiteNumber(cfg.MinRegionPercent, defaultSettings.MinRegionPercent)), 10, 100)
    cfg.MainX = math.clamp(math.floor(finiteNumber(cfg.MainX, defaultSettings.MainX)), -5000, 5000)
    cfg.MainY = math.clamp(math.floor(finiteNumber(cfg.MainY, defaultSettings.MainY)), -5000, 5000)
    if type(cfg.PeopleRegion) ~= "string" or not VALID_REGIONS[cfg.PeopleRegion] then
        cfg.PeopleRegion = defaultSettings.PeopleRegion
    end
    if type(cfg.SelectionMode) ~= "string" or not VALID_SELECTION_MODES[cfg.SelectionMode] then
        cfg.SelectionMode = defaultSettings.SelectionMode
    end
    if type(cfg.Theme) ~= "string" or THEMES[cfg.Theme] == nil then
        cfg.Theme = defaultSettings.Theme
    end
    return cfg
end

local function loadSettings()
    local cfg = copyDefaults()
    if canReadFile(SETTINGS_FILE) then
        local success, result = pcall(function()
            return HttpService:JSONDecode(readfile(SETTINGS_FILE))
        end)
        if success and type(result) == "table" then
            for key in pairs(defaultSettings) do
                if result[key] ~= nil then
                    cfg[key] = result[key]
                end
            end
            -- Seamless migration from the old PreferFull toggle.
            if result.SelectionMode == nil and type(result.PreferFull) == "boolean" then
                cfg.SelectionMode = result.PreferFull and "FULL" or "RANDOM"
            end
        end
    end
    return normalizeSettings(cfg)
end

local settingsSaveToken = 0
local function saveSettings(cfg, immediate)
    if type(writefile) ~= "function" then return end
    local snapshot = {}
    for key in pairs(defaultSettings) do snapshot[key] = cfg[key] end
    normalizeSettings(snapshot)
    local encoded, payload = pcall(function() return HttpService:JSONEncode(snapshot) end)
    if not encoded then return end

    settingsSaveToken = settingsSaveToken + 1
    local token = settingsSaveToken
    local function writeNow()
        if token ~= settingsSaveToken then return end
        pcall(writefile, SETTINGS_FILE, payload)
    end
    if immediate then
        writeNow()
    else
        task.delay(0.2, writeNow)
    end
end

local config = loadSettings()

-- Roblox does not publish the physical datacenter region in the public server list.
-- Instead, this filter evaluates the countries/language of players after joining.
local REGION_COUNTRIES = {
    RUSSIAN = { RU=true, BY=true, KZ=true, KG=true },
    CIS = { RU=true, BY=true, KZ=true, KG=true, AM=true, AZ=true, MD=true, TJ=true, TM=true, UZ=true, UA=true },
    EUROPE = { AL=true, AD=true, AT=true, BE=true, BA=true, BG=true, HR=true, CY=true, CZ=true, DK=true, EE=true, FI=true, FR=true, DE=true, GR=true, HU=true, IS=true, IE=true, IT=true, LV=true, LI=true, LT=true, LU=true, MT=true, MC=true, ME=true, NL=true, MK=true, NO=true, PL=true, PT=true, RO=true, SM=true, RS=true, SK=true, SI=true, ES=true, SE=true, CH=true, GB=true, VA=true },
    ["N.AMERICA"] = { US=true, CA=true, MX=true, GT=true, BZ=true, SV=true, HN=true, NI=true, CR=true, PA=true, CU=true, JM=true, HT=true, DO=true, BS=true, BB=true, TT=true },
    ["S.AMERICA"] = { AR=true, BO=true, BR=true, CL=true, CO=true, EC=true, GY=true, PY=true, PE=true, SR=true, UY=true, VE=true },
    ASIA = { CN=true, HK=true, MO=true, JP=true, KR=true, TW=true, IN=true, ID=true, MY=true, PH=true, SG=true, TH=true, VN=true, PK=true, BD=true, LK=true, NP=true, MN=true, AE=true, SA=true, IL=true, TR=true, GE=true },
    OCEANIA = { AU=true, NZ=true, FJ=true, PG=true, WS=true, TO=true },
}

local countryCache = {}
local countryLookupInFlight = {}
local activeCountryLookups = 0

local function countryMatchesRegion(code, region)
    if region == "ANY" then return true end
    code = type(code) == "string" and string.upper(code) or nil
    return code ~= nil and REGION_COUNTRIES[region] ~= nil and REGION_COUNTRIES[region][code] == true
end

local function lookupCountry(pl)
    if not pl or pl == LocalPlayer then return nil end
    local userId = pl.UserId
    local cached = countryCache[userId]
    if cached ~= nil then return cached ~= false and cached or nil end
    if countryLookupInFlight[userId] then return nil end
    countryLookupInFlight[userId] = true

    while guiAlive and pl.Parent and activeCountryLookups >= MAX_COUNTRY_LOOKUPS do
        task.wait(0.08)
    end
    if not guiAlive or not pl.Parent then
        countryLookupInFlight[userId] = nil
        return nil
    end

    activeCountryLookups = activeCountryLookups + 1
    local ok, code = false, nil
    for attempt = 1, 2 do
        ok, code = pcall(function()
            return LocalizationService:GetCountryRegionForPlayerAsync(pl)
        end)
        if ok and type(code) == "string" and #code == 2 then break end
        if not guiAlive or not pl.Parent then break end
        if attempt < 2 then task.wait(0.25) end
    end
    activeCountryLookups = math.max(0, activeCountryLookups - 1)
    countryLookupInFlight[userId] = nil
    if ok and type(code) == "string" and #code == 2 then
        countryCache[userId] = string.upper(code)
        return countryCache[userId]
    end
    -- Cache failures for this server to avoid repeatedly hitting a yielding API.
    countryCache[userId] = false
    return nil
end

pcall(function()
    local g = CoreGui:FindFirstChild("ClassicServerFinder")
    if g then g:Destroy() end
end)
pcall(function()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local g = pg and pg:FindFirstChild("ClassicServerFinder")
    if g then g:Destroy() end
end)

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ClassicServerFinder"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset = true
ScreenGui.DisplayOrder = 999

pcall(function()
    ScreenGui.Parent = CoreGui
end)
if not ScreenGui.Parent then
    ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local chatConns = {}
local playerConns = {}

local function disconnectPlayer(userId)
    local list = playerConns[userId]
    if list then
        disconnectConnections(list)
        playerConns[userId] = nil
    end
end

ScreenGui.Destroying:Connect(function()
    guiAlive = false
    config.AutoHop = false
    hopToken = hopToken + 1
    evaluateToken = evaluateToken + 1
    disconnectConnections(chatConns)
    for _, list in pairs(playerConns) do
        disconnectConnections(list)
    end
    table.clear(playerConns)
    disconnectConnections(globalConns)
end)

local WHITE = Color3.fromRGB(255, 255, 255)
local BLACK = Color3.fromRGB(0, 0, 0)
local DIM = Color3.fromRGB(180, 180, 180)
local MUTED = Color3.fromRGB(120, 120, 120)
local GREEN = Color3.fromRGB(140, 255, 170)
local RED = Color3.fromRGB(255, 135, 135)

-- ============================================================
-- THEME PALETTE (v2.4)
-- A theme is a single "ink" accent colour used for the main text,
-- titles, outlines and separators. Secondary hints (DIM) and muted
-- outlines (MUTED) stay neutral grey. The chosen theme is persisted
-- in settings and survives server hops. Default is SNOW (white).
-- The THEMES table itself is defined earlier (before loadSettings).
-- ============================================================
local currentTheme = (THEMES[config.Theme] and config.Theme) or "SNOW"

-- Live accent colour; all bright text/outlines read from here.
local function P()
    local theme = THEMES[currentTheme]
    return theme and theme.ink or WHITE
end

-- Live panel colour; the RICK AND MORTY theme tints every panel a dark
-- portal-gun green instead of pure black. Other themes keep pure black.
local function BG()
    local theme = THEMES[currentTheme]
    return theme and theme.bg or BLACK
end

-- Numeric colour comparison: robust even on executors where Color3 ==
-- compares by identity rather than by component value.
local function sameColor(a, b)
    return math.abs(a.R - b.R) < 0.01
        and math.abs(a.G - b.G) < 0.01
        and math.abs(a.B - b.B) < 0.01
end

-- Instantly recolour every element that uses the previous accent.
-- Direct assignment makes the switch reliable and cheap (no tween
-- dependency, no half-morphed frames).
local function applyTheme(name, persist)
    local theme = THEMES[name]
    if not theme then
        return
    end
    local ink = theme.ink
    local bg = theme.bg or BLACK
    local old = THEMES[currentTheme] or THEMES["SNOW"]
    local fromInk = old.ink
    local fromBg = old.bg or BLACK
    if sameColor(ink, fromInk) and sameColor(bg, fromBg) then
        currentTheme = name
        return
    end
    currentTheme = name
    if persist ~= false then
        config.Theme = name
        saveSettings(config, true)
    end
    pcall(function()
        for _, instance in ipairs(ScreenGui:GetDescendants()) do
            if instance:IsA("GuiObject") then
                if sameColor(instance.BorderColor3, fromInk) then
                    instance.BorderColor3 = ink
                end
                if sameColor(instance.BackgroundColor3, fromInk) then
                    instance.BackgroundColor3 = ink
                end
                if sameColor(instance.BackgroundColor3, fromBg) then
                    instance.BackgroundColor3 = bg
                end
                if instance:IsA("TextLabel") or instance:IsA("TextButton") then
                    if sameColor(instance.TextColor3, fromInk) then
                        instance.TextColor3 = ink
                    end
                end
                if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
                    if sameColor(instance.ImageColor3, fromInk) then
                        instance.ImageColor3 = ink
                    end
                end
            end
        end
    end)
    if notify then
        notify("Theme: " .. name, ink)
    end
end

local activeTweens = setmetatable({}, { __mode = "k" })
local function tween(instance, info, props)
    if not instance or not instance.Parent then
        return nil
    end
    local keys = {}
    for key in pairs(props) do
        table.insert(keys, key)
    end
    table.sort(keys)
    local channel = table.concat(keys, "+")
    local channels = activeTweens[instance]
    if not channels then
        channels = {}
        activeTweens[instance] = channels
    end
    local previous = channels[channel]
    if previous then
        pcall(function() previous:Cancel() end)
    end
    if not config.Animations then
        for key, value in pairs(props) do
            instance[key] = value
        end
        channels[channel] = nil
        return nil
    end
    local animation = TweenService:Create(instance, info, props)
    channels[channel] = animation
    animation:Play()
    return animation
end

local function setupRetroButton(button)
    local isImage = button:IsA("ImageButton")
    button.ClipsDescendants = true
    local scale = Instance.new("UIScale")
    scale.Scale = 1
    scale.Parent = button

    -- Diagonal light sweep that races across the button on hover.
    local shine = Instance.new("Frame")
    shine.Name = "Shine"
    shine.AnchorPoint = Vector2.new(0.5, 0.5)
    shine.Size = UDim2.new(0, 8, 1.8, 0)
    shine.Position = UDim2.new(-0.15, 0, 0.5, 0)
    shine.Rotation = 14
    shine.BackgroundColor3 = P()
    shine.BackgroundTransparency = 1
    shine.BorderSizePixel = 0
    shine.ZIndex = button.ZIndex + 2
    shine.Parent = button

    local hovered = false

    local function sweepShine()
        if not config.Animations or not button.Parent then return end
        shine.BackgroundTransparency = 0.7
        shine.Position = UDim2.new(-0.15, 0, 0.5, 0)
        tween(shine, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Position = UDim2.new(1.15, 0, 0.5, 0),
        })
        task.delay(0.34, function()
            if shine.Parent then shine.BackgroundTransparency = 1 end
        end)
    end

    -- Rectangular monochrome ripple bursting from the center on click.
    local function ripple()
        if not config.Animations or not button.Parent then return end
        local bg = button.BackgroundColor3
        local bright = (bg.R + bg.G + bg.B) / 3
        local wave = Instance.new("Frame")
        wave.Name = "Ripple"
        wave.AnchorPoint = Vector2.new(0.5, 0.5)
        wave.Position = UDim2.new(0.5, 0, 0.5, 0)
        wave.Size = UDim2.new(0, 6, 0, 6)
        wave.BackgroundColor3 = bright > 0.5 and BLACK or P()
        wave.BackgroundTransparency = 0.55
        wave.BorderSizePixel = 0
        wave.ZIndex = button.ZIndex + 1
        wave.Parent = button
        tween(wave, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Size = UDim2.new(1.8, 0, 3.4, 0),
            BackgroundTransparency = 1,
        })
        task.delay(0.34, function()
            if wave.Parent then wave:Destroy() end
        end)
    end

    local function setHover(state)
        hovered = state
        if not guiAlive or not button.Parent then
            return
        end
        local props = { BackgroundColor3 = state and P() or BLACK }
        if isImage then
            props.ImageColor3 = state and BLACK or P()
        else
            props.TextColor3 = state and BLACK or P()
        end
        tween(button, TweenInfo.new(0.12, Enum.EasingStyle.Quad), props)
    end

    button.MouseEnter:Connect(function()
        setHover(true)
        sweepShine()
        tween(scale, TweenInfo.new(0.1, Enum.EasingStyle.Quad), { Scale = 1.04 })
    end)
    button.MouseLeave:Connect(function()
        setHover(false)
        tween(scale, TweenInfo.new(0.12, Enum.EasingStyle.Back), { Scale = 1 })
    end)
    button.MouseButton1Down:Connect(function()
        ripple()
        tween(scale, TweenInfo.new(0.05, Enum.EasingStyle.Quad), { Scale = 0.92 })
    end)
    button.MouseButton1Up:Connect(function()
        tween(scale, TweenInfo.new(0.14, Enum.EasingStyle.Back), { Scale = hovered and 1.04 or 1 })
    end)
end

local windowZ = 2

local function raiseWindow(frame)
    if not frame or not frame.Parent then
        return
    end
    windowZ = windowZ + 1
    frame.ZIndex = windowZ
end

local function viewportSize()
    local camera = workspace.CurrentCamera
    return camera and camera.ViewportSize or Vector2.new(1280, 720)
end

local function clampToViewport(frame)
    if not frame or not frame.Parent then
        return
    end
    local viewport = viewportSize()
    local absolutePosition = frame.AbsolutePosition
    local absoluteSize = frame.AbsoluteSize
    local margin = 6
    local maxX = math.max(margin, viewport.X - absoluteSize.X - margin)
    local maxY = math.max(margin, viewport.Y - absoluteSize.Y - margin)
    local targetX = math.clamp(absolutePosition.X, margin, maxX)
    local targetY = math.clamp(absolutePosition.Y, margin, maxY)
    local delta = Vector2.new(targetX - absolutePosition.X, targetY - absolutePosition.Y)
    if delta.Magnitude > 0.5 then
        frame.Position = UDim2.new(
            frame.Position.X.Scale,
            frame.Position.X.Offset + delta.X,
            frame.Position.Y.Scale,
            frame.Position.Y.Offset + delta.Y
        )
    end
end

local function makeDraggable(frame, handle, onDrop)
    local dragging = false
    local dragStart = nil
    local startPos = nil
    local dragInput = nil

    handle.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch
        then
            return
        end
        dragging = true
        dragInput = input
        dragStart = input.Position
        startPos = frame.Position
        raiseWindow(frame)
        -- Each drag used to leave a permanent input.Changed connection
        -- behind, slowly leaking listeners over the session. The end
        -- listener now disconnects itself once the input releases.
        local endConnection
        endConnection = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
                dragInput = nil
                clampToViewport(frame)
                if onDrop then onDrop(frame) end
                if endConnection then
                    endConnection:Disconnect()
                    endConnection = nil
                end
            end
        end)
    end)

    rememberConnection(UserInputService.InputChanged:Connect(function(input)
        if not dragging or not guiAlive or not dragInput then
            return
        end
        local validMouse = dragInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseMovement
        local validTouch = dragInput.UserInputType == Enum.UserInputType.Touch and input == dragInput
        if validMouse or validTouch then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end))
end

local function pulseBorder(frame)
    task.spawn(function()
        while guiAlive and frame.Parent do
            if frame.Visible and config.Animations and not isHopping then
                tween(frame, TweenInfo.new(1.2, Enum.EasingStyle.Sine), { BorderColor3 = MUTED })
            end
            task.wait(1.2)
            if not (guiAlive and frame.Parent) then
                break
            end
            if frame.Visible and config.Animations and not isHopping then
                tween(frame, TweenInfo.new(1.2, Enum.EasingStyle.Sine), { BorderColor3 = P() })
            elseif frame.Visible then
                frame.BorderColor3 = P()
            end
            task.wait(1.2)
        end
    end)
end

-- CRT-style scanline that periodically sweeps the frame from top to bottom.
local function attachScanline(frame)
    local line = Instance.new("Frame")
    line.Name = "Scanline"
    line.Size = UDim2.new(1, 0, 0, 1)
    line.Position = UDim2.new(0, 0, 0, -2)
    line.BackgroundColor3 = P()
    line.BackgroundTransparency = 1
    line.BorderSizePixel = 0
    line.ZIndex = 40
    line.Parent = frame
    task.spawn(function()
        while guiAlive and frame.Parent do
            if frame.Visible and config.Animations and not isHopping then
                line.BackgroundTransparency = 0.85
                line.Position = UDim2.new(0, 0, 0, -2)
                tween(line, TweenInfo.new(2.1, Enum.EasingStyle.Linear), {
                    Position = UDim2.new(0, 0, 1, 2),
                })
                task.wait(2.15)
                line.BackgroundTransparency = 1
            else
                line.BackgroundTransparency = 1
            end
            task.wait(RNG:NextNumber(2.2, 3.4))
        end
    end)
    return line
end

-- Occasional multi-frame text corruption for that broken-terminal look.
local function attachTextGlitch(label)
    local GLITCH_CHARS = { "#", "%", "&", "@", "$", "?", "/", "\\", "=", "+", "*", "!", "~" }
    local function scrambleText(original)
        if #original < 1 then return original end
        local chars = {}
        for i = 1, #original do
            chars[i] = string.sub(original, i, i)
        end
        local edits = math.max(1, math.min(#chars, 1 + math.floor(#original / 8)))
        for _ = 1, edits do
            chars[RNG:NextInteger(1, #chars)] = GLITCH_CHARS[RNG:NextInteger(1, #GLITCH_CHARS)]
        end
        if #chars >= 3 and RNG:NextNumber() < 0.4 then
            local startIdx = RNG:NextInteger(1, #chars - 1)
            local len = RNG:NextInteger(1, math.min(3, #chars - startIdx))
            for i = startIdx, startIdx + len do
                chars[i] = GLITCH_CHARS[RNG:NextInteger(1, #GLITCH_CHARS)]
            end
        end
        return table.concat(chars)
    end
    task.spawn(function()
        while guiAlive and label.Parent do
            task.wait(RNG:NextNumber(5, 10))
            if not (guiAlive and label.Parent) then break end
            if config.Animations and label.Visible and not isHopping then
                local original = label.Text
                local frames = RNG:NextInteger(2, 5)
                for i = 1, frames do
                    if not label.Parent then return end
                    label.Text = scrambleText(original)
                    if i == 1 then
                        -- Chromatic hue shift while corrupted.
                        label.TextColor3 = RNG:NextNumber() < 0.5 and MUTED or P()
                        label.Rotation = RNG:NextNumber(-1.6, 1.6)
                    end
                    task.wait(RNG:NextNumber(0.03, 0.06))
                end
                if label.Parent then
                    label.Text = original
                    label.TextColor3 = P()
                    label.Rotation = 0
                end
            end
        end
    end)
end

-- Periodic horizontal jitter: the label slides a few pixels and snaps back.
local function attachGlitchShift(label)
    task.spawn(function()
        while guiAlive and label.Parent do
            task.wait(RNG:NextNumber(7, 15))
            if not (guiAlive and label.Parent) then break end
            if config.Animations and label.Visible and not isHopping then
                local base = label.Position
                local steps = {
                    RNG:NextInteger(2, 6),
                    -RNG:NextInteger(2, 5),
                    RNG:NextInteger(1, 3),
                    0,
                }
                for _, dx in ipairs(steps) do
                    if not label.Parent then return end
                    tween(label, TweenInfo.new(0.03, Enum.EasingStyle.Quad), {
                        Position = UDim2.new(base.X.Scale, base.X.Offset + dx, base.Y.Scale, base.Y.Offset),
                    })
                    task.wait(0.035)
                end
            end
        end
    end)
end

-- Random horizontal bands of static that flicker for a frame or two.
local function attachStaticOverlay(frame)
    local overlay = Instance.new("Frame")
    overlay.Name = "StaticOverlay"
    overlay.Size = UDim2.new(1, 0, 1, 0)
    overlay.BackgroundTransparency = 1
    overlay.BorderSizePixel = 0
    overlay.ZIndex = 60
    overlay.Parent = frame

    local bands = {}
    for i = 1, 7 do
        local band = Instance.new("Frame")
        band.Name = "StaticBand" .. tostring(i)
        band.Size = UDim2.new(1, 0, 0, RNG:NextInteger(2, 6))
        band.Position = UDim2.new(0, 0, RNG:NextNumber(0, 0.9), 0)
        band.BackgroundColor3 = P()
        band.BackgroundTransparency = 1
        band.BorderSizePixel = 0
        band.ZIndex = 61
        band.Parent = overlay
        bands[i] = band
    end

    task.spawn(function()
        while guiAlive and frame.Parent do
            task.wait(RNG:NextNumber(8, 16))
            if not (guiAlive and frame.Parent) then break end
            if config.Animations and frame.Visible and not isHopping then
                local flashes = RNG:NextInteger(1, 3)
                for _ = 1, flashes do
                    local lit = {}
                    for _, band in ipairs(bands) do
                        band.BackgroundColor3 = P()
                        if RNG:NextNumber() < 0.5 then
                            band.BackgroundTransparency = RNG:NextNumber(0.25, 0.55)
                            band.Position = UDim2.new(0, 0, RNG:NextNumber(0, 0.92), 0)
                            table.insert(lit, band)
                        else
                            band.BackgroundTransparency = 1
                        end
                    end
                    task.wait(RNG:NextNumber(0.04, 0.09))
                    for _, band in ipairs(lit) do
                        band.BackgroundTransparency = 1
                    end
                    if flashes > 1 then
                        task.wait(RNG:NextNumber(0.03, 0.07))
                    end
                end
            end
        end
    end)
    return overlay
end

local function createWindow(opts)
    local win = Instance.new("Frame")
    win.Name = opts.Name
    win.Size = opts.Size
    win.Position = opts.Position
    win.BackgroundColor3 = BG()
    win.BorderSizePixel = 1
    win.BorderColor3 = P()
    win.Active = true
    win.Visible = false
    win.ClipsDescendants = true
    win.ZIndex = 2
    win.Parent = ScreenGui

    local windowScaleTarget = 1
    local windowScale = Instance.new("UIScale")
    windowScale.Scale = windowScaleTarget
    windowScale.Parent = win

    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 30)
    titleBar.BackgroundTransparency = 1
    titleBar.Parent = win

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -36, 1, 0)
    title.Position = UDim2.new(0, 8, 0, 0)
    title.Text = opts.Title
    title.TextColor3 = P()
    title.Font = Enum.Font.Code
    title.TextSize = 12
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.BackgroundTransparency = 1
    title.Parent = titleBar

    local close = Instance.new("TextButton")
    close.Size = UDim2.new(0, 20, 0, 20)
    close.Position = UDim2.new(1, -25, 0, 5)
    close.BackgroundColor3 = BG()
    close.BorderSizePixel = 1
    close.BorderColor3 = P()
    close.Text = "X"
    close.TextColor3 = P()
    close.Font = Enum.Font.Code
    close.TextSize = 12
    close.AutoButtonColor = false
    close.Parent = win
    setupRetroButton(close)

    local body = Instance.new("Frame")
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 1, -30)
    body.Position = UDim2.new(0, 0, 0, 30)
    body.BackgroundTransparency = 1
    body.Parent = win

    local line = Instance.new("Frame")
    line.Size = UDim2.new(1, 0, 0, 1)
    line.Position = UDim2.new(0, 0, 0, 0)
    line.BackgroundColor3 = P()
    line.BorderSizePixel = 0
    line.Parent = body

    makeDraggable(win, titleBar)
    pulseBorder(win)
    attachScanline(win)
    attachStaticOverlay(win)
    attachTextGlitch(title)
    attachGlitchShift(title)

    win.InputBegan:Connect(function()
        raiseWindow(win)
    end)

    local visibilityToken = 0
    local function hide()
        visibilityToken = visibilityToken + 1
        local token = visibilityToken
        if not config.Animations then
            win.Visible = false
            return
        end
        tween(windowScale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
            Scale = windowScaleTarget * 0.85,
        })
        tween(win, TweenInfo.new(0.16, Enum.EasingStyle.Quad), {
            BackgroundTransparency = 1,
            Rotation = RNG:NextInteger(0, 1) == 0 and -2.5 or 2.5,
        })
        task.delay(0.16, function()
            if win.Parent and visibilityToken == token then
                win.Visible = false
                win.Rotation = 0
            end
        end)
    end

    close.MouseButton1Click:Connect(hide)

    local function show()
        visibilityToken = visibilityToken + 1
        win.Visible = true
        raiseWindow(win)
        clampToViewport(win)
        if config.Animations then
            win.BackgroundTransparency = 1
            win.Rotation = RNG:NextInteger(0, 1) == 0 and -3 or 3
            windowScale.Scale = windowScaleTarget * 0.8
        end
        tween(win, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            BackgroundTransparency = 0,
            Rotation = 0,
        })
        tween(windowScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Scale = windowScaleTarget,
        })
    end

    return {
        Frame = win,
        Body = body,
        Scale = windowScale,
        setScale = function(value)
            windowScaleTarget = value
            if win.Visible then
                tween(windowScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Scale = value })
            else
                windowScale.Scale = value
            end
        end,
        show = show,
        hide = hide,
        toggle = function()
            if win.Visible then
                hide()
            else
                show()
            end
        end,
    }
end

local EXPANDED_SIZE = UDim2.new(0, 340, 0, 540)
local MINIMIZED_SIZE = UDim2.new(0, 340, 0, 32)

local Main = Instance.new("Frame")
Main.Name = "Main"
Main.Size = EXPANDED_SIZE
Main.Position = UDim2.new(0.5, config.MainX, 0.5, config.MainY)
Main.BackgroundColor3 = BG()
Main.BorderSizePixel = 1
Main.BorderColor3 = P()
Main.Active = true
Main.ClipsDescendants = true
Main.Parent = ScreenGui

local responsiveMainScale = math.clamp(math.min((viewportSize().X - 12) / 340, (viewportSize().Y - 12) / 540), GUI_MIN_SCALE, 1)
local MainScale = Instance.new("UIScale")
MainScale.Scale = config.Animations and responsiveMainScale * 0.94 or responsiveMainScale
MainScale.Parent = Main

Main.BackgroundTransparency = config.Animations and 1 or 0
Main.ZIndex = 1
if config.Animations then
    Main.Rotation = -4
    Main.Position = Main.Position + UDim2.fromOffset(0, 26)
    MainScale.Scale = responsiveMainScale * 0.7
end
tween(Main, TweenInfo.new(0.34, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
    BackgroundTransparency = 0,
    Rotation = 0,
})
tween(Main, TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
    Position = UDim2.new(0.5, config.MainX, 0.5, config.MainY),
})
tween(MainScale, TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
    Scale = responsiveMainScale,
})
pulseBorder(Main)
attachScanline(Main)
attachStaticOverlay(Main)

local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 30)
TitleBar.BackgroundTransparency = 1
TitleBar.Parent = Main
makeDraggable(Main, TitleBar, function(frame)
    config.MainX = frame.Position.X.Offset
    config.MainY = frame.Position.Y.Offset
    saveSettings(config)
end)
Main.InputBegan:Connect(function() raiseWindow(Main) end)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -118, 1, 0)
Title.Position = UDim2.new(0, 8, 0, 0)
Title.Text = "[ SERVER FINDER v" .. VERSION .. " ]"
Title.TextColor3 = P()
Title.Font = Enum.Font.Code
Title.TextSize = 12
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.BackgroundTransparency = 1
Title.Parent = TitleBar

-- Boot-style typewriter reveal for the main title, then occasional glitches.
do
    if config.Animations then
        task.spawn(function()
            local fullTitle = Title.Text
            Title.Text = ""
            task.wait(0.25)
            local visible = ""
            for i = 1, #fullTitle do
                if not (guiAlive and Title.Parent) then return end
                visible = string.sub(fullTitle, 1, i)
                Title.Text = visible .. (i < #fullTitle and "_" or "")
                task.wait(0.022)
            end
            Title.Text = fullTitle
            attachTextGlitch(Title)
            attachGlitchShift(Title)
        end)
    else
        attachTextGlitch(Title)
        attachGlitchShift(Title)
    end
end

local function makeHeaderButton(text, xOffset)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 20, 0, 20)
    btn.Position = UDim2.new(1, xOffset, 0, 5)
    btn.BackgroundColor3 = BG()
    btn.BorderSizePixel = 1
    btn.BorderColor3 = P()
    btn.Text = text
    btn.TextColor3 = P()
    btn.Font = Enum.Font.Code
    btn.TextSize = 12
    btn.AutoButtonColor = false
    btn.Parent = Main
    setupRetroButton(btn)
    return btn
end

local MinBtn = makeHeaderButton("_", -97)
local SettingsBtn = makeHeaderButton("S", -75)
local InfoBtn = makeHeaderButton("?", -50)
local CloseBtn = makeHeaderButton("X", -25)

local Body -- created below; forward-declared for the close animation

local closing = false
CloseBtn.MouseButton1Click:Connect(function()
    if closing then return end
    closing = true
    config.AutoHop = false
    saveSettings(config, true)
    if not config.Animations then
        guiAlive = false
        ScreenGui:Destroy()
        return
    end
    -- CRT power-off: collapse to a horizontal line, then to a dot, then vanish.
    for _, child in ipairs(ScreenGui:GetChildren()) do
        if child:IsA("Frame") and child ~= Main then
            child.Visible = false
        end
    end
    if Body then Body.Visible = false end
    local absPos = Main.AbsolutePosition
    local absSize = Main.AbsoluteSize
    local centerX = absPos.X + absSize.X / 2
    local centerY = absPos.Y + absSize.Y / 2
    tween(Main, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
        Size = UDim2.fromOffset(absSize.X, 2),
        Position = UDim2.fromOffset(absPos.X, centerY),
        BackgroundColor3 = P(),
    })
    task.delay(0.17, function()
        if not Main.Parent then return end
        tween(Main, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Size = UDim2.fromOffset(4, 2),
            Position = UDim2.fromOffset(centerX, centerY),
        })
        task.delay(0.16, function()
            guiAlive = false
            if ScreenGui.Parent then ScreenGui:Destroy() end
        end)
    end)
end)

Body = Instance.new("Frame")
Body.Name = "Body"
Body.Size = UDim2.new(1, 0, 1, -30)
Body.Position = UDim2.new(0, 0, 0, 30)
Body.BackgroundTransparency = 1
Body.Parent = Main

local minimizeToken = 0
MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    minimizeToken = minimizeToken + 1
    local token = minimizeToken
    if minimized then
        Body.Visible = false
        tween(Main, TweenInfo.new(0.24, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Size = MINIMIZED_SIZE })
        MinBtn.Text = "+"
    else
        tween(Main, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = EXPANDED_SIZE })
        MinBtn.Text = "_"
        -- Reveal the body once the frame is mostly unrolled.
        task.delay(config.Animations and 0.12 or 0, function()
            if guiAlive and token == minimizeToken and not minimized then
                Body.Visible = true
            end
        end)
    end
end)

local Line1 = Instance.new("Frame")
Line1.Size = UDim2.new(1, 0, 0, 1)
Line1.Position = UDim2.new(0, 0, 0, 0)
Line1.BackgroundColor3 = P()
Line1.BorderSizePixel = 0
Line1.Parent = Body

local settingRefreshers = {}
local function refreshSettingControls()
    for _, refresh in ipairs(settingRefreshers) do
        refresh()
    end
end

-- Short green border blink confirming that a setting was changed and saved.
local function confirmBlink(instance)
    if not config.Animations or not instance or not instance.Parent then return end
    instance.BorderColor3 = GREEN
    tween(instance, TweenInfo.new(0.45, Enum.EasingStyle.Quad), { BorderColor3 = P() })
end

local function createToggle(parent, text, pos, size, key)
    local btn = Instance.new("TextButton")
    btn.Size = size
    btn.Position = pos
    btn.BackgroundColor3 = BG()
    btn.BorderSizePixel = 1
    btn.BorderColor3 = P()
    btn.Font = Enum.Font.Code
    btn.TextSize = 10
    btn.TextColor3 = P()
    btn.AutoButtonColor = false
    btn.Parent = parent
    setupRetroButton(btn)

    local function updateText()
        if btn.Parent then
            btn.Text = (config[key] and "[X] " or "[ ] ") .. text
        end
    end
    table.insert(settingRefreshers, updateText)
    updateText()

    btn.MouseButton1Click:Connect(function()
        config[key] = not config[key]
        saveSettings(config)
        updateText()
        confirmBlink(btn)
    end)
    return btn
end

local function createStepper(parent, label, pos, size, key, minValue, maxValue, suffix, step)
    local frame = Instance.new("Frame")
    frame.Size = size
    frame.Position = pos
    frame.BackgroundColor3 = BG()
    frame.BorderSizePixel = 1
    frame.BorderColor3 = P()
    frame.Parent = parent

    local caption = Instance.new("TextLabel")
    caption.Size = UDim2.new(1, -52, 1, 0)
    caption.Position = UDim2.new(0, 6, 0, 0)
    caption.BackgroundTransparency = 1
    caption.Font = Enum.Font.Code
    caption.TextSize = 10
    caption.TextColor3 = P()
    caption.TextXAlignment = Enum.TextXAlignment.Left
    caption.Parent = frame

    local function refresh()
        if caption.Parent then
            caption.Text = label .. " " .. tostring(config[key]) .. (suffix or "")
        end
    end
    table.insert(settingRefreshers, refresh)
    refresh()

    local function makeStep(symbol, dx, delta)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 20, 0, 18)
        btn.Position = UDim2.new(1, dx, 0.5, -9)
        btn.BackgroundColor3 = BG()
        btn.BorderSizePixel = 1
        btn.BorderColor3 = P()
        btn.Text = symbol
        btn.TextColor3 = P()
        btn.Font = Enum.Font.Code
        btn.TextSize = 11
        btn.AutoButtonColor = false
        btn.Parent = frame
        setupRetroButton(btn)
        btn.MouseButton1Click:Connect(function()
            local before = config[key]
            config[key] = math.clamp(config[key] + delta, minValue, maxValue)
            saveSettings(config)
            refresh()
            if config[key] ~= before then
                confirmBlink(frame)
                -- Nudge the caption in the direction of the change.
                if config.Animations and caption.Parent then
                    caption.Position = UDim2.new(0, delta > 0 and 10 or 2, 0, 0)
                    tween(caption, TweenInfo.new(0.18, Enum.EasingStyle.Back), {
                        Position = UDim2.new(0, 6, 0, 0),
                    })
                end
            end
        end)
    end

    step = step or 1
    makeStep("-", -44, -step)
    makeStep("+", -22, step)
    return frame
end

local function createSelector(parent, label, pos, size, key, values, labels)
    local btn = Instance.new("TextButton")
    btn.Size = size
    btn.Position = pos
    btn.BackgroundColor3 = BG()
    btn.BorderSizePixel = 1
    btn.BorderColor3 = P()
    btn.Font = Enum.Font.Code
    btn.TextSize = 10
    btn.TextColor3 = P()
    btn.AutoButtonColor = false
    btn.Parent = parent
    setupRetroButton(btn)

    local function refresh()
        if btn.Parent then
            btn.Text = label .. ": <  " .. (labels[config[key]] or config[key]) .. "  >"
        end
    end
    table.insert(settingRefreshers, refresh)
    refresh()

    btn.MouseButton1Click:Connect(function()
        local current = table.find(values, config[key]) or 1
        config[key] = values[(current % #values) + 1]
        saveSettings(config)
        refresh()
        confirmBlink(btn)
    end)
    return btn
end

local function hint(parent, text, pos)
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -16, 0, 14)
    label.Position = pos
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Code
    label.TextSize = 9
    label.TextColor3 = DIM
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text
    label.Parent = parent
    return label
end

local setStatus
local updateStats
local updateBtnText
local notify

local InfoWin = createWindow({
    Name = "InfoWindow",
    Title = "[ DOCUMENTATION & INFO ]",
    Size = UDim2.new(0, 340, 0, 420),
    Position = UDim2.new(0.5, 186, 0.5, -210),
})

local InfoScroll = Instance.new("ScrollingFrame")
InfoScroll.Size = UDim2.new(1, -16, 1, -16)
InfoScroll.Position = UDim2.new(0, 8, 0, 8)
InfoScroll.BackgroundColor3 = BG()
InfoScroll.BorderSizePixel = 1
InfoScroll.BorderColor3 = P()
InfoScroll.ScrollBarThickness = 4
InfoScroll.ScrollBarImageColor3 = P()
InfoScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
InfoScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
InfoScroll.Parent = InfoWin.Body

local InfoTextLabel = Instance.new("TextLabel")
InfoTextLabel.Size = UDim2.new(1, -10, 0, 0)
InfoTextLabel.Position = UDim2.new(0, 5, 0, 5)
InfoTextLabel.BackgroundTransparency = 1
InfoTextLabel.Font = Enum.Font.Code
InfoTextLabel.TextSize = 11
InfoTextLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
InfoTextLabel.TextXAlignment = Enum.TextXAlignment.Left
InfoTextLabel.TextYAlignment = Enum.TextYAlignment.Top
InfoTextLabel.TextWrapped = true
InfoTextLabel.AutomaticSize = Enum.AutomaticSize.Y
InfoTextLabel.Text = [[
> SERVER FINDER v2.13

1. SMART AUTO-HOP
   Scans multiple API pages, scores candidates and
   re-runs after teleport when the executor supports
   queue_on_teleport.

2. SEARCH MODES
   SMART balances occupancy, ping and FPS. FULL,
   LOW PING and RANDOM strategies are also available.

3. SAFE TELEPORTS
   Stale timeout callbacks are cancelled. Servers
   that fill up before we land (full-server race)
   are blacklisted for a short cooldown so the hop
   immediately moves on to another server instead
   of re-selecting the same full one. A watchdog
   guarantees the hopper never freezes mid-hop.
   HTTP 429 rate limits are handled with an
   automatic, doubling back-off that survives
   server hops, so the API is never hammered.

4. FILTERS
   Premium, active chat (checked over a rolling window,
   not just the analyse seconds), minimum players, free
   slots, optional max ping, minimum server FPS and
   audience region.

5. PEOPLE REGION
   Roblox does not expose a physical datacenter in
   the public server API. Region therefore describes
   the detected audience after joining. Unknown
   countries do not count as a mismatch.

6. RUSSIAN DETECTION
   Uses UTF-8 code points rather than byte patterns,
   so Cyrillic and Ukrainian-specific letters are not
   accidentally misclassified.

7. ANTI-REPEAT
   Keeps a validated 200-server LRU history. Use
   CLEAR HISTORY in Settings when you want a reset.

8. PERFORMANCE
   Player cards update in place; avatars/friendship
   are cached, country requests are concurrency-limited,
   chat events are deduplicated and file saves debounced.
   A persisted candidate pool reuses scan results across
   hops so the games API is called far less often.

9. GUI
   Fully animated retro-terminal interface: CRT
   scanlines, random static bands, glitch shift,
   typewriter title, multi-frame text corruption,
   button shine + ripple, sliding toasts with
   lifetime bars, staggered player cards, warp
   strobe + full-screen surge on teleport, error
   shake, match bounce and a CRT power-off close
   animation. Ambient effects pause automatically
   while a hop is running so the search never
   fights the GUI for CPU. Press RightShift to
   hide/show. ANIMATIONS toggle disables it all.

10. THEMES
   Cycle the terminal accent from Settings:
   SNOW (default), TERMINAL GREEN, AMBER, CYAN,
   MAGENTA, RED, BLUE and RICK AND MORTY. The
   accent (plus R&M portal-gun panels) is saved
   and survives server hops.

11. AUTO-LOOP STOP RULES
   The loop stops only when every ACTIVE filter
   is satisfied and at least one stop signal is
   enabled (premium, chat or region). With all
   of those off it keeps hopping for the minimum
   player count until you press STOP.

12. HOP ONCE
   Jumps without changing the saved auto-loop setting.

13. WINDOW POSITION
   Drag the main window anywhere; its position is
   remembered across hops and sessions. RESET in
   Settings returns it to the screen centre.

14. ANTI-AFK
   Keeps the account awake while you are away:
   disables the idle kick where possible, resets
   idle instantly and sends a heartbeat so you are
   never disconnected for standing still. Toggle
   in Settings (default ON).

15. RICK AND MORTY PORTAL
   Pick the RICK AND MORTY theme for the portal
   gun look. Three seconds before a teleport a
   green portal opens in front of you. It is
   built entirely from glowing neon parts - an
   oval rim, a spinning galaxy swirl and a
   counter-rotating inner vortex with an energy
   core - so it always shows on every device,
   even where image textures do not load. The
   portal picture is still added as a bonus
   layer, along with an open flash, glow,
   orbiting sparks, rising embers and a burst
   of neon parts. Your character walks into it
   on its own (PORTAL GATE), the teleport fires
   on time and, on the new server, a portal
   opens behind you and seals itself with a
   particle implosion. No shockwave rings.

Use [?] and the gear for Info / Settings.]]
InfoTextLabel.Parent = InfoScroll

local SettingsWin = createWindow({
    Name = "SettingsWindow",
    Title = "[ SETTINGS ]",
    Size = UDim2.new(0, 310, 0, 460),
    Position = UDim2.new(0.5, -500, 0.5, -230),
})

local SettingsScroll = Instance.new("ScrollingFrame")
SettingsScroll.Size = UDim2.new(1, -12, 1, -12)
SettingsScroll.Position = UDim2.new(0, 6, 0, 6)
SettingsScroll.BackgroundTransparency = 1
SettingsScroll.BorderSizePixel = 0
SettingsScroll.ScrollBarThickness = 3
SettingsScroll.ScrollBarImageColor3 = P()
SettingsScroll.CanvasSize = UDim2.new(0, 0, 0, 700)
SettingsScroll.Parent = SettingsWin.Body

createToggle(SettingsScroll, "DONATORS", UDim2.new(0, 6, 0, 6), UDim2.new(1, -16, 0, 26), "FilterDonators")
hint(SettingsScroll, "need at least 1 premium player", UDim2.new(0, 6, 0, 34))

createToggle(SettingsScroll, "ACTIVE CHAT", UDim2.new(0, 6, 0, 54), UDim2.new(1, -16, 0, 26), "FilterChat")
hint(SettingsScroll, "need a unique message from another player", UDim2.new(0, 6, 0, 82))

createSelector(SettingsScroll, "SEARCH MODE", UDim2.new(0, 6, 0, 102), UDim2.new(1, -16, 0, 26), "SelectionMode", { "SMART", "FULL", "LOW PING", "RANDOM" }, { SMART = "SMART", FULL = "FULL", ["LOW PING"] = "LOW PING", RANDOM = "RANDOM" })
hint(SettingsScroll, "smart balances population, ping and server FPS", UDim2.new(0, 6, 0, 130))

createStepper(SettingsScroll, "MAX PING", UDim2.new(0, 6, 0, 150), UDim2.new(1, -16, 0, 26), "MaxPing", 0, 500, "ms", 25)
hint(SettingsScroll, "0 disables ping filtering; missing API ping is allowed", UDim2.new(0, 6, 0, 178))

createStepper(SettingsScroll, "MIN FPS", UDim2.new(0, 6, 0, 198), UDim2.new(1, -16, 0, 26), "MinFps", 0, 60, "", 5)
hint(SettingsScroll, "0 disables; skip servers below this reported FPS", UDim2.new(0, 6, 0, 226))

createStepper(SettingsScroll, "MIN PLAYERS", UDim2.new(0, 6, 0, 224), UDim2.new(1, -16, 0, 26), "MinPlayers", 1, 100, "")
hint(SettingsScroll, "skip quiet servers below this population", UDim2.new(0, 6, 0, 252))

createStepper(SettingsScroll, "FREE SLOTS", UDim2.new(0, 6, 0, 272), UDim2.new(1, -16, 0, 26), "MinFreeSlots", 1, 20, "")
hint(SettingsScroll, "reduces races with servers that become full", UDim2.new(0, 6, 0, 300))

createStepper(SettingsScroll, "ANALYZE", UDim2.new(0, 6, 0, 320), UDim2.new(1, -16, 0, 26), "AnalyzeSeconds", 2, 20, "s")
hint(SettingsScroll, "seconds to listen and inspect after joining", UDim2.new(0, 6, 0, 348))

createSelector(SettingsScroll, "PEOPLE REGION", UDim2.new(0, 6, 0, 368), UDim2.new(1, -16, 0, 26), "PeopleRegion", { "ANY", "RUSSIAN", "CIS", "EUROPE", "N.AMERICA", "S.AMERICA", "ASIA", "OCEANIA" }, { ANY = "ANY", RUSSIAN = "RUSSIAN", CIS = "RU / CIS", EUROPE = "EUROPE", ["N.AMERICA"] = "N. AMERICA", ["S.AMERICA"] = "S. AMERICA", ASIA = "ASIA", OCEANIA = "OCEANIA" })
hint(SettingsScroll, "audience region, not the physical datacenter", UDim2.new(0, 6, 0, 396))

createStepper(SettingsScroll, "REGION SHARE", UDim2.new(0, 6, 0, 416), UDim2.new(1, -16, 0, 26), "MinRegionPercent", 10, 100, "%", 5)
hint(SettingsScroll, "minimum share among players with known country", UDim2.new(0, 6, 0, 444))

createToggle(SettingsScroll, "ANIMATIONS", UDim2.new(0, 6, 0, 464), UDim2.new(1, -16, 0, 26), "Animations")
hint(SettingsScroll, "disable for the lightest possible GUI", UDim2.new(0, 6, 0, 492))

createToggle(SettingsScroll, "ANTI AFK", UDim2.new(0, 6, 0, 518), UDim2.new(1, -16, 0, 26), "AntiAfk")
hint(SettingsScroll, "auto-reset idle so you can walk away while it works", UDim2.new(0, 6, 0, 546))

createToggle(SettingsScroll, "PORTAL GATE", UDim2.new(0, 6, 0, 570), UDim2.new(1, -16, 0, 26), "PortalGate")
hint(SettingsScroll, "R&M theme: auto-walks you into the portal to teleport", UDim2.new(0, 6, 0, 598))

local ThemeSelectorBtn = Instance.new("TextButton")
ThemeSelectorBtn.Size = UDim2.new(1, -16, 0, 26)
ThemeSelectorBtn.Position = UDim2.new(0, 6, 0, 622)
ThemeSelectorBtn.BackgroundColor3 = BG()
ThemeSelectorBtn.BorderSizePixel = 1
ThemeSelectorBtn.BorderColor3 = P()
ThemeSelectorBtn.Font = Enum.Font.Code
ThemeSelectorBtn.TextSize = 10
ThemeSelectorBtn.TextColor3 = P()
ThemeSelectorBtn.AutoButtonColor = false
ThemeSelectorBtn.Parent = SettingsScroll
setupRetroButton(ThemeSelectorBtn)

local function refreshTheme()
    if ThemeSelectorBtn.Parent then
        ThemeSelectorBtn.Text = "THEME: <  " .. currentTheme .. "  >"
    end
end
table.insert(settingRefreshers, refreshTheme)
refreshTheme()

ThemeSelectorBtn.MouseButton1Click:Connect(function()
    local order = { "SNOW", "TERMINAL GREEN", "AMBER", "CYAN", "MAGENTA", "RED", "BLUE", "RICK AND MORTY" }
    local index = table.find(order, currentTheme) or 1
    applyTheme(order[(index % #order) + 1])
    refreshTheme()
    confirmBlink(ThemeSelectorBtn)
end)
hint(SettingsScroll, "cycle the terminal accent colour", UDim2.new(0, 6, 0, 650))

local ClearHistoryBtn = Instance.new("TextButton")
ClearHistoryBtn.Size = UDim2.new(0.5, -10, 0, 30)
ClearHistoryBtn.Position = UDim2.new(0, 6, 0, 670)
ClearHistoryBtn.BackgroundColor3 = BG()
ClearHistoryBtn.BorderSizePixel = 1
ClearHistoryBtn.BorderColor3 = P()
ClearHistoryBtn.Font = Enum.Font.Code
ClearHistoryBtn.TextSize = 10
ClearHistoryBtn.TextColor3 = P()
ClearHistoryBtn.Text = "[ CLEAR HISTORY ]"
ClearHistoryBtn.AutoButtonColor = false
ClearHistoryBtn.Parent = SettingsScroll
setupRetroButton(ClearHistoryBtn)

local ResetSettingsBtn = Instance.new("TextButton")
ResetSettingsBtn.Size = UDim2.new(0.5, -10, 0, 30)
ResetSettingsBtn.Position = UDim2.new(0.5, 4, 0, 670)
ResetSettingsBtn.BackgroundColor3 = BG()
ResetSettingsBtn.BorderSizePixel = 1
ResetSettingsBtn.BorderColor3 = P()
ResetSettingsBtn.Font = Enum.Font.Code
ResetSettingsBtn.TextSize = 10
ResetSettingsBtn.TextColor3 = P()
ResetSettingsBtn.Text = "[ RESET ]"
ResetSettingsBtn.AutoButtonColor = false
ResetSettingsBtn.Parent = SettingsScroll
setupRetroButton(ResetSettingsBtn)

ClearHistoryBtn.MouseButton1Click:Connect(function()
    table.clear(visitedServers)
    if type(game.JobId) == "string" and game.JobId ~= "" then
        visitedServers[game.JobId] = os.time()
    end
    saveVisited(visitedServers)
    if updateStats then updateStats() end
    if notify then notify("Visited history cleared", GREEN) end
end)

ResetSettingsBtn.MouseButton1Click:Connect(function()
    local keepAutoHop = config.AutoHop
    config = copyDefaults()
    config.AutoHop = keepAutoHop
    saveSettings(config, true)
    refreshSettingControls()
    applyTheme("SNOW", false)
    refreshTheme()
    tween(Main, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = UDim2.new(0.5, -170, 0.5, -270),
    })
    if updateBtnText then updateBtnText() end
    if notify then notify("Settings restored", GREEN) end
end)

local function placeBeside(win, xOffset)
    local mainPos = Main.AbsolutePosition
    -- ScreenGui is a LayerCollector, not a GuiObject; its origin is (0, 0).
    win.Frame.Position = UDim2.fromOffset(mainPos.X + xOffset, mainPos.Y)
end

local function windowWidth(win, fallback)
    local w = win.Frame.AbsoluteSize.X
    if w < 1 then
        return fallback
    end
    return w
end

InfoBtn.MouseButton1Click:Connect(function()
    if not InfoWin.Frame.Visible then
        placeBeside(InfoWin, Main.AbsoluteSize.X + 12)
        InfoWin.show()
    else
        InfoWin.hide()
    end
end)

SettingsBtn.MouseButton1Click:Connect(function()
    if not SettingsWin.Frame.Visible then
        placeBeside(SettingsWin, -(windowWidth(SettingsWin, 310) + 12))
        SettingsWin.show()
    else
        SettingsWin.hide()
    end
end)

local Stats = Instance.new("TextLabel")
Stats.Size = UDim2.new(1, -16, 0, 16)
Stats.Position = UDim2.new(0, 8, 0, 8)
Stats.BackgroundTransparency = 1
Stats.Font = Enum.Font.Code
Stats.TextSize = 10
Stats.TextColor3 = DIM
Stats.TextXAlignment = Enum.TextXAlignment.Left
Stats.TextTruncate = Enum.TextTruncate.AtEnd
Stats.Text = ""
Stats.Parent = Body

local Scroll = Instance.new("ScrollingFrame")
Scroll.Size = UDim2.new(1, -16, 1, -112)
Scroll.Position = UDim2.new(0, 8, 0, 28)
Scroll.BackgroundColor3 = BG()
Scroll.BorderSizePixel = 1
Scroll.BorderColor3 = P()
Scroll.ScrollBarThickness = 4
Scroll.ScrollBarImageColor3 = P()
Scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
Scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
Scroll.Parent = Body

local UIList = Instance.new("UIListLayout")
UIList.Padding = UDim.new(0, 4)
UIList.SortOrder = Enum.SortOrder.LayoutOrder
UIList.Parent = Scroll

local UIPad = Instance.new("UIPadding")
UIPad.PaddingTop = UDim.new(0, 2)
UIPad.PaddingBottom = UDim.new(0, 2)
UIPad.Parent = Scroll

local ProgressTrack = Instance.new("Frame")
ProgressTrack.Size = UDim2.new(1, -16, 0, 3)
ProgressTrack.Position = UDim2.new(0, 8, 1, -77)
ProgressTrack.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
ProgressTrack.BorderSizePixel = 0
ProgressTrack.ClipsDescendants = true
ProgressTrack.Parent = Body

local ProgressFill = Instance.new("Frame")
ProgressFill.Size = UDim2.new(0, 0, 1, 0)
ProgressFill.BackgroundColor3 = P()
ProgressFill.BorderSizePixel = 0
ProgressFill.Parent = ProgressTrack

-- Sliding highlight that keeps the bar alive while work is in progress.
local ProgressGlow = Instance.new("Frame")
ProgressGlow.Size = UDim2.new(0, 26, 1, 0)
ProgressGlow.Position = UDim2.new(-0.12, 0, 0, 0)
ProgressGlow.BackgroundColor3 = P()
ProgressGlow.BackgroundTransparency = 1
ProgressGlow.BorderSizePixel = 0
ProgressGlow.ZIndex = 2
ProgressGlow.Parent = ProgressTrack

task.spawn(function()
    while guiAlive and ProgressTrack.Parent do
        local busy = ProgressFill.Size.X.Scale > 0.001 and ProgressFill.Size.X.Scale < 0.999
        if config.Animations and Main.Visible and not minimized and busy then
            ProgressGlow.BackgroundTransparency = 0.65
            ProgressGlow.Position = UDim2.new(-0.12, 0, 0, 0)
            tween(ProgressGlow, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                Position = UDim2.new(1.02, 0, 0, 0),
            })
            task.wait(0.95)
            ProgressGlow.BackgroundTransparency = 1
            task.wait(0.25)
        else
            ProgressGlow.BackgroundTransparency = 1
            task.wait(0.4)
        end
    end
end)

local function setProgress(value, color, instant)
    value = math.clamp(tonumber(value) or 0, 0, 1)
    ProgressFill.BackgroundColor3 = color or P()
    local target = { Size = UDim2.new(value, 0, 1, 0) }
    if instant then
        local channels = activeTweens[ProgressFill]
        if channels and channels.Size then
            pcall(function() channels.Size:Cancel() end)
            channels.Size = nil
        end
        ProgressFill.Size = target.Size
    else
        tween(ProgressFill, TweenInfo.new(0.18, Enum.EasingStyle.Quad), target)
    end
    -- Completion pulse: the whole track blinks once in the result colour.
    if value >= 1 and config.Animations then
        local blink = color or P()
        ProgressTrack.BackgroundColor3 = blink
        tween(ProgressTrack, TweenInfo.new(0.45, Enum.EasingStyle.Quad), {
            BackgroundColor3 = Color3.fromRGB(35, 35, 35),
        })
    end
end

local Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, -16, 0, 16)
Status.Position = UDim2.new(0, 8, 1, -70)
Status.BackgroundTransparency = 1
Status.Font = Enum.Font.Code
Status.TextSize = 10
Status.TextColor3 = DIM
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.TextTruncate = Enum.TextTruncate.AtEnd
Status.Text = "> idle"
Status.Parent = Body

local HopOnceBtn = Instance.new("TextButton")
HopOnceBtn.Size = UDim2.new(0.46, 0, 0, 32)
HopOnceBtn.Position = UDim2.new(0, 8, 1, -48)
HopOnceBtn.BackgroundColor3 = BG()
HopOnceBtn.BorderSizePixel = 1
HopOnceBtn.BorderColor3 = P()
HopOnceBtn.Font = Enum.Font.Code
HopOnceBtn.TextSize = 10
HopOnceBtn.TextColor3 = P()
HopOnceBtn.Text = "[ HOP ONCE ]"
HopOnceBtn.AutoButtonColor = false
HopOnceBtn.Parent = Body
setupRetroButton(HopOnceBtn)

local SearchBtn = Instance.new("TextButton")
SearchBtn.Size = UDim2.new(0.46, -8, 0, 32)
SearchBtn.Position = UDim2.new(0.52, 0, 1, -48)
SearchBtn.BackgroundColor3 = BG()
SearchBtn.BorderSizePixel = 1
SearchBtn.BorderColor3 = P()
SearchBtn.Font = Enum.Font.Code
SearchBtn.TextSize = 10
SearchBtn.TextColor3 = P()
SearchBtn.AutoButtonColor = false
SearchBtn.Parent = Body
setupRetroButton(SearchBtn)

local ToastHost = Instance.new("Frame")
ToastHost.Name = "Notifications"
ToastHost.Size = UDim2.new(0, 280, 1, -20)
ToastHost.Position = UDim2.new(1, -290, 0, 10)
ToastHost.BackgroundTransparency = 1
ToastHost.ZIndex = 100
ToastHost.Parent = ScreenGui

local ToastList = Instance.new("UIListLayout")
ToastList.Padding = UDim.new(0, 6)
ToastList.HorizontalAlignment = Enum.HorizontalAlignment.Right
ToastList.SortOrder = Enum.SortOrder.LayoutOrder
ToastList.Parent = ToastHost

local toastCounter = 0
notify = function(message, color)
    if not guiAlive or not ToastHost.Parent then
        return
    end
    local existing = {}
    for _, child in ipairs(ToastHost:GetChildren()) do
        if child.Name == "Toast" then table.insert(existing, child) end
    end
    table.sort(existing, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
    while #existing >= 4 do
        existing[1]:Destroy()
        table.remove(existing, 1)
    end
    toastCounter = toastCounter + 1
    local accent = color or P()

    -- Transparent holder keeps its place in the list while the label slides.
    local holder = Instance.new("Frame")
    holder.Name = "Toast"
    holder.Size = UDim2.new(1, 0, 0, 34)
    holder.BackgroundTransparency = 1
    holder.LayoutOrder = toastCounter
    holder.ZIndex = 100
    holder.Parent = ToastHost

    local toast = Instance.new("TextLabel")
    toast.Size = UDim2.new(1, 0, 1, 0)
    toast.Position = config.Animations and UDim2.new(1.1, 0, 0, 0) or UDim2.new(0, 0, 0, 0)
    toast.BackgroundColor3 = BG()
    toast.BackgroundTransparency = 0.08
    toast.BorderSizePixel = 1
    toast.BorderColor3 = accent
    toast.Font = Enum.Font.Code
    toast.TextSize = 10
    toast.TextColor3 = accent
    toast.TextXAlignment = Enum.TextXAlignment.Left
    toast.TextTruncate = Enum.TextTruncate.AtEnd
    toast.Text = "  > " .. tostring(message)
    toast.ZIndex = 100
    toast.ClipsDescendants = true
    toast.Parent = holder

    -- Accent stripe on the left edge that unfolds vertically.
    local stripe = Instance.new("Frame")
    stripe.Size = UDim2.new(0, 3, config.Animations and 0 or 1, 0)
    stripe.Position = UDim2.new(0, 0, 0.5, 0)
    stripe.AnchorPoint = Vector2.new(0, 0.5)
    stripe.BackgroundColor3 = accent
    stripe.BorderSizePixel = 0
    stripe.ZIndex = 101
    stripe.Parent = toast

    -- Lifetime bar draining along the bottom edge.
    local life = Instance.new("Frame")
    life.Size = UDim2.new(1, 0, 0, 1)
    life.Position = UDim2.new(0, 0, 1, -1)
    life.BackgroundColor3 = accent
    life.BackgroundTransparency = 0.35
    life.BorderSizePixel = 0
    life.ZIndex = 101
    life.Parent = toast

    tween(toast, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        Position = UDim2.new(0, 0, 0, 0),
    })
    tween(stripe, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.new(0, 3, 1, 0),
    })
    tween(life, TweenInfo.new(3.2, Enum.EasingStyle.Linear), {
        Size = UDim2.new(0, 0, 0, 1),
    })

    task.delay(3.2, function()
        if not holder.Parent then return end
        tween(toast, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Position = UDim2.new(1.1, 0, 0, 0),
            BackgroundTransparency = 1,
            TextTransparency = 1,
        })
        -- Collapse the holder so remaining toasts glide up smoothly.
        tween(holder, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Size = UDim2.new(1, 0, 0, 0),
        })
        task.wait(config.Animations and 0.24 or 0)
        if holder.Parent then holder:Destroy() end
    end)
end

setStatus = function(text)
    if Status and Status.Parent then
        local newText = "> " .. tostring(text)
        local current = Status.Text
        if string.sub(current, -2) == " _" then
            current = string.sub(current, 1, -3)
        end
        if current ~= newText then
            Status.Text = newText
            -- Quick flash so status changes catch the eye.
            if config.Animations then
                Status.TextColor3 = P()
                tween(Status, TweenInfo.new(0.5, Enum.EasingStyle.Quad), { TextColor3 = DIM })
            end
        end
    end
end

-- Blinking terminal cursor appended to the idle status line.
task.spawn(function()
    local showCursor = false
    while guiAlive and Status.Parent do
        if config.Animations and Main.Visible and not minimized then
            showCursor = not showCursor
            local base = Status.Text
            if string.sub(base, -2) == " _" then
                base = string.sub(base, 1, -3)
            end
            Status.Text = showCursor and (base .. " _") or base
        end
        task.wait(0.55)
    end
end)

updateBtnText = function()
    if config.AutoHop then
        SearchBtn.Text = "[ STOP AUTO-LOOP ]"
    else
        SearchBtn.Text = "[ START AUTO-LOOP ]"
    end
end
updateBtnText()

updateStats = function()
    local n = #Players:GetPlayers()
    local job = tostring(game.JobId or "")
    local shortJob = #job > 8 and (string.sub(job, 1, 8) .. "..") or job
    Stats.Text = string.format(
        "%s | %d here | %d seen | hop %d | fail %d",
        shortJob,
        n,
        countVisited(),
        sessionStats.hops,
        sessionStats.failures
    )
end

local chatMessageCount = 0
local russianChatCount = 0
local uniqueChatters = {}
local recentChat = {}
local chatLog = {}

local RUSSIAN_SPECIFIC = { [0x401] = true, [0x451] = true, [0x42B] = true, [0x44B] = true, [0x42D] = true, [0x44D] = true, [0x42A] = true, [0x44A] = true }
local UKRAINIAN_SPECIFIC = { [0x406] = true, [0x456] = true, [0x407] = true, [0x457] = true, [0x404] = true, [0x454] = true, [0x490] = true, [0x491] = true }

local function looksRussian(text)
    if type(text) ~= "string" or text == "" then return false end
    local hasCyrillic = false
    local hasRussianSpecific = false
    local hasUkrainianSpecific = false
    local ok = pcall(function()
        for _, codepoint in utf8.codes(text) do
            if codepoint >= 0x0400 and codepoint <= 0x052F then
                hasCyrillic = true
            end
            if RUSSIAN_SPECIFIC[codepoint] then hasRussianSpecific = true end
            if UKRAINIAN_SPECIFIC[codepoint] then hasUkrainianSpecific = true end
        end
    end)
    return ok and hasCyrillic and (hasRussianSpecific or not hasUkrainianSpecific)
end

local function bumpChat(userId, text)
    if type(userId) ~= "number" or userId == LocalPlayer.UserId or type(text) ~= "string" then
        return
    end
    -- TextChatService and Player.Chatted can report the same modern-chat message.
    local now = os.clock()
    local previous = recentChat[userId]
    if previous and previous.text == text and now - previous.at < 0.75 then
        return
    end
    recentChat[userId] = { text = text, at = now }
    local ru = looksRussian(text)
    chatMessageCount = chatMessageCount + 1
    uniqueChatters[userId] = true
    if ru then
        russianChatCount = russianChatCount + 1
    end
    -- Rolling log so analysis sees recent activity even when it happened
    -- just before the analyze window started.
    table.insert(chatLog, { at = now, userId = userId, ru = ru })
    if #chatLog > 200 then
        table.remove(chatLog, 1)
    end
end

pcall(function()
    table.insert(chatConns, TextChatService.MessageReceived:Connect(function(msg)
        if msg and msg.TextSource then
            bumpChat(msg.TextSource.UserId, msg.Text)
        end
    end))
end)

local scheduleRender
local playerCards = {}
local friendCache = {}
local friendLookupInFlight = {}

local function playerSortKey(pl)
    return string.lower(pl.Name or "")
end

local function playerLine(pl)
    local isLocal = pl == LocalPlayer
    local cachedCountry = not isLocal and countryCache[pl.UserId] or nil
    local country = cachedCountry ~= false and cachedCountry or nil
    local tags = {}
    if isLocal then table.insert(tags, "YOU") end
    if friendCache[pl.UserId] == true then table.insert(tags, "FRIEND") end
    if pl.MembershipType == Enum.MembershipType.Premium then table.insert(tags, "PREMIUM") end
    if country then table.insert(tags, country) end

    local display = pl.DisplayName
    local username = pl.Name
    local line = display and display ~= "" and display ~= username
        and (display .. " @" .. username) or username
    if #tags > 0 then
        line = line .. " [" .. table.concat(tags, "][") .. "]"
    end
    return line
end

local function refreshCard(pl)
    local record = playerCards[pl.UserId]
    if record and record.info.Parent then
        local line = playerLine(pl)
        if record.info.Text ~= line then
            record.info.Text = line
        end
    end
end

local cardEntryStagger = 0
local function buildCard(pl)
    local card = Instance.new("Frame")
    card.Name = "P_" .. tostring(pl.UserId)
    card.Size = UDim2.new(1, -6, 0, 34)
    card.BackgroundColor3 = BG()
    card.BackgroundTransparency = config.Animations and 1 or 0
    card.BorderSizePixel = 1
    card.BorderColor3 = config.Animations and MUTED or P()
    card.ClipsDescendants = true
    card.Parent = Scroll

    local cardScale = Instance.new("UIScale")
    cardScale.Scale = config.Animations and 0.88 or 1
    cardScale.Parent = card

    local avatar = Instance.new("ImageLabel")
    avatar.Size = UDim2.new(0, 26, 0, 26)
    avatar.Position = UDim2.new(0, 4, 0.5, -13)
    avatar.BackgroundColor3 = BG()
    avatar.BorderSizePixel = 1
    avatar.BorderColor3 = P()
    avatar.ImageTransparency = config.Animations and 1 or 0
    avatar.Parent = card

    local info = Instance.new("TextLabel")
    info.Size = UDim2.new(1, -38, 1, 0)
    info.Position = UDim2.new(0, 36, 0, 0)
    info.Text = playerLine(pl)
    info.TextColor3 = P()
    info.Font = Enum.Font.Code
    info.TextSize = 10
    info.TextXAlignment = Enum.TextXAlignment.Left
    info.TextTruncate = Enum.TextTruncate.AtEnd
    info.BackgroundTransparency = 1
    info.TextTransparency = config.Animations and 1 or 0
    info.Parent = card

    local record = { frame = card, avatar = avatar, info = info, player = pl }
    playerCards[pl.UserId] = record

    -- Staggered entry: each new card pops in slightly after the previous one.
    cardEntryStagger = math.min(cardEntryStagger + 0.03, 0.36)
    local myDelay = cardEntryStagger
    task.delay(config.Animations and myDelay or 0, function()
        cardEntryStagger = math.max(0, cardEntryStagger - 0.03)
        if not card.Parent then return end
        tween(card, TweenInfo.new(0.22, Enum.EasingStyle.Quad), {
            BackgroundTransparency = 0,
            BorderColor3 = P(),
        })
        tween(cardScale, TweenInfo.new(0.28, Enum.EasingStyle.Back), { Scale = 1 })
        tween(info, TweenInfo.new(0.24, Enum.EasingStyle.Quad), { TextTransparency = 0 })
    end)

    -- Subtle hover highlight without stealing input from the scroll frame.
    card.MouseEnter:Connect(function()
        if card.Parent then
            tween(card, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {
                BackgroundColor3 = Color3.fromRGB(26, 26, 26),
            })
            tween(info, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {
                Position = UDim2.new(0, 40, 0, 0),
            })
        end
    end)
    card.MouseLeave:Connect(function()
        if card.Parent then
            tween(card, TweenInfo.new(0.16, Enum.EasingStyle.Quad), { BackgroundColor3 = BG() })
            tween(info, TweenInfo.new(0.16, Enum.EasingStyle.Quad), {
                Position = UDim2.new(0, 36, 0, 0),
            })
        end
    end)

    task.spawn(function()
        local ok, content, isReady = pcall(function()
            return Players:GetUserThumbnailAsync(
                pl.UserId,
                Enum.ThumbnailType.HeadShot,
                Enum.ThumbnailSize.Size100x100
            )
        end)
        if ok and isReady and avatar.Parent then
            avatar.Image = content
            tween(avatar, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { ImageTransparency = 0 })
        elseif avatar.Parent then
            avatar.ImageTransparency = 0
        end
    end)

    if pl ~= LocalPlayer and friendCache[pl.UserId] == nil and not friendLookupInFlight[pl.UserId] then
        friendLookupInFlight[pl.UserId] = true
        task.spawn(function()
            local ok, result = pcall(function()
                return LocalPlayer:IsFriendsWith(pl.UserId)
            end)
            friendLookupInFlight[pl.UserId] = nil
            friendCache[pl.UserId] = ok and result == true
            if guiAlive and pl.Parent then refreshCard(pl) end
        end)
    end
    return record
end

local renderQueued = false
local function renderPlayers()
    if not guiAlive then return end
    local list = Players:GetPlayers()
    local present = {}
    table.sort(list, function(a, b)
        if a == LocalPlayer then return true end
        if b == LocalPlayer then return false end
        return playerSortKey(a) < playerSortKey(b)
    end)

    for index, pl in ipairs(list) do
        present[pl.UserId] = true
        local record = playerCards[pl.UserId] or buildCard(pl)
        record.frame.LayoutOrder = index
        refreshCard(pl)
    end
    for userId, record in pairs(playerCards) do
        if not present[userId] then
            local frame = record.frame
            playerCards[userId] = nil
            if frame.Parent then
                if config.Animations then
                    -- Slide the departing card out to the left and fade its content.
                    local scale = frame:FindFirstChildOfClass("UIScale")
                    tween(frame, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                        BackgroundTransparency = 1,
                        BorderColor3 = BLACK,
                    })
                    if scale then
                        tween(scale, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                            Scale = 0.82,
                        })
                    end
                    if record.info and record.info.Parent then
                        tween(record.info, TweenInfo.new(0.18), { TextTransparency = 1 })
                    end
                    if record.avatar and record.avatar.Parent then
                        tween(record.avatar, TweenInfo.new(0.18), { ImageTransparency = 1 })
                    end
                    task.delay(0.22, function()
                        if frame.Parent then frame:Destroy() end
                    end)
                else
                    frame:Destroy()
                end
            end
        end
    end
    updateStats()
end

scheduleRender = function()
    if renderQueued then return end
    renderQueued = true
    task.defer(function()
        renderQueued = false
        if guiAlive then renderPlayers() end
    end)
end

local function trackPlayer(pl)
    if not pl or playerConns[pl.UserId] then return end
    local conns = {}
    playerConns[pl.UserId] = conns
    if pl ~= LocalPlayer then
        -- Player.Chatted belongs to legacy chat. After the 2025 shutdown
        -- of LegacyChatService it may stop firing or be removed entirely;
        -- TextChatService.MessageReceived covers modern chat, so guard the
        -- connection so a future removal cannot break player tracking.
        pcall(function()
            table.insert(conns, pl.Chatted:Connect(function(message)
                bumpChat(pl.UserId, message)
            end))
        end)
        task.spawn(function()
            local code = lookupCountry(pl)
            if code and scheduleRender then scheduleRender() end
        end)
    end
    table.insert(conns, pl:GetPropertyChangedSignal("DisplayName"):Connect(scheduleRender))
    table.insert(conns, pl:GetPropertyChangedSignal("MembershipType"):Connect(scheduleRender))
    scheduleRender()
end

for _, pl in ipairs(Players:GetPlayers()) do
    trackPlayer(pl)
end
rememberConnection(Players.PlayerAdded:Connect(trackPlayer))
rememberConnection(Players.PlayerRemoving:Connect(function(pl)
    disconnectPlayer(pl.UserId)
    recentChat[pl.UserId] = nil
    countryLookupInFlight[pl.UserId] = nil
    scheduleRender()
end))

local function parseHttpResponse(res)
    if type(res) == "string" then
        return 200, res, nil
    end
    if type(res) ~= "table" then
        return nil, nil, nil
    end
    local status = tonumber(res.StatusCode or res.Status or res.status_code or res.status)
    local body = res.Body or res.body or res.SuccessBody
    local headers = res.Headers or res.headers
    return status, body, headers
end

local function hopStillActive(token)
    return guiAlive and isHopping and token == hopToken
end

local function httpGet(url, token)
    local httpRequest = getHttpRequest()
    local lastError = "http unavailable"

    for attempt = 1, HTTP_RETRIES do
        if not hopStillActive(token) then
            return nil, "stopped"
        end
        -- Minimum gap between requests so bursts never trip the limit.
        local lastAt = sessionStats.lastRequestAt or 0
        local since = os.clock() - lastAt
        if since < 0.35 then
            task.wait(0.35 - since)
        end
        sessionStats.lastRequestAt = os.clock()
        local success, res
        if type(httpRequest) == "function" then
            success, res = pcall(function()
                return httpRequest({
                    Url = url,
                    Method = "GET",
                    Headers = { ["Accept"] = "application/json" },
                })
            end)
        else
            -- Several executors expose game:HttpGet but no request function.
            success, res = pcall(function()
                return game:HttpGet(url)
            end)
        end

        if success then
            local status, body, headers = parseHttpResponse(res)
            if type(body) == "string" and body ~= ""
                and (not status or status == 0 or (status >= 200 and status < 300))
            then
                noteRateLimitOk()
                return body, nil
            end
            if status == 429 then
                local retryAfter = nil
                if type(headers) == "table" then
                    retryAfter = tonumber(headers["Retry-After"] or headers["retry-after"] or headers["retry_after"])
                end
                noteRateLimited(retryAfter)
                return nil, "rate limited"
            end
            if status and status >= 400 and status < 500 then
                return nil, "api http " .. tostring(status)
            end
            lastError = status and ("api http " .. tostring(status)) or "empty http response"
        else
            lastError = "http request failed"
            -- game:HttpGet raises an error string on non-2xx, e.g.
            -- "HTTP 429 (Too Many Requests)". Detect it and back off.
            local errText = tostring(res)
            if errText and errText:find("429", 1, true) then
                noteRateLimited(nil)
                return nil, "rate limited"
            end
        end

        local backoff = math.min(2.5, 0.3 * (2 ^ (attempt - 1))) + RNG:NextNumber(0, 0.15)
        task.wait(backoff)
    end
    return nil, lastError
end

local function candidateScore(server)
    local occupancy = server.maxPlayers > 0 and server.playing / server.maxPlayers or 0
    local pingScore = server.ping and math.clamp(1 - server.ping / 500, 0, 1) or 0.45
    local fpsScore = server.fps and math.clamp(server.fps / 60, 0, 1) or 0.5
    return occupancy * 45 + pingScore * 35 + fpsScore * 20 + RNG:NextNumber(0, 3)
end

local function pickServer(valid)
    if #valid == 0 then return nil end
    local mode = config.SelectionMode
    if mode == "RANDOM" then
        return valid[RNG:NextInteger(1, #valid)]
    end
    if mode == "FULL" then
        table.sort(valid, function(a, b)
            if a.playing == b.playing then return a.id < b.id end
            return a.playing > b.playing
        end)
    elseif mode == "LOW PING" then
        table.sort(valid, function(a, b)
            local aPing = a.ping or math.huge
            local bPing = b.ping or math.huge
            if aPing == bPing then return a.playing > b.playing end
            return aPing < bPing
        end)
    else
        for _, server in ipairs(valid) do
            server.score = candidateScore(server)
        end
        table.sort(valid, function(a, b) return a.score > b.score end)
    end
    -- Add slight diversity while still selecting from the strategy's best results.
    return valid[RNG:NextInteger(1, math.min(6, #valid))]
end

local function getUnvisitedServer(token)
    local function savePool()
        if type(writefile) ~= "function" then return end
        pcall(function()
            writefile("ServerFinderPool.json", HttpService:JSONEncode(serverPool))
        end)
    end

    local function pooledOk(s)
        if type(s) ~= "table" or type(s.id) ~= "string" or s.id == "" then
            return false
        end
        if visitedServers[s.id] or s.id == game.JobId then
            return false
        end
        local failedAt = failedServers[s.id]
        if failedAt and (os.time() - failedAt) < 90 then
            return false
        end
        if type(s.ts) == "number" and (os.time() - s.ts) > 300 then
            return false
        end
        local playing = tonumber(s.playing) or 0
        local maxPlayers = tonumber(s.maxPlayers) or 0
        if playing < config.MinPlayers then return false end
        if maxPlayers > 0 and (maxPlayers - playing) < config.MinFreeSlots then return false end
        if config.MaxPing > 0 and type(s.ping) == "number" and s.ping > config.MaxPing then return false end
        if config.MinFps > 0 and type(s.fps) == "number" and s.fps < config.MinFps then return false end
        return true
    end

    -- Serve from the persisted pool first: zero API calls.
    local pooled = nil
    while #serverPool > 0 and not pooled do
        local s = serverPool[#serverPool]
        serverPool[#serverPool] = nil
        if pooledOk(s) then
            pooled = s
        end
    end
    if pooled then
        savePool()
        setProgress(1, GREEN)
        return {
            id = pooled.id,
            playing = tonumber(pooled.playing) or 0,
            maxPlayers = tonumber(pooled.maxPlayers) or 0,
            ping = pooled.ping,
            fps = pooled.fps,
        }, nil
    end

    local selectedSort = config.SelectionMode == "RANDOM"
        and (RNG:NextInteger(0, 1) == 0 and "Asc" or "Desc") or "Desc"
    local cursor = ""
    local candidates = {}
    local candidateIds = {}
    local targetCount = config.SelectionMode == "FULL" and 24 or TARGET_CANDIDATES

    for page = 1, MAX_API_PAGES do
        if not hopStillActive(token) then return nil, "stopped" end
        setStatus(string.format("scanning API page %d/%d (%d candidates)", page, MAX_API_PAGES, #candidates))
        setProgress((page - 1) / MAX_API_PAGES, P())

        local cursorPart = ""
        if cursor ~= "" then
            local encoded = cursor
            pcall(function() encoded = HttpService:UrlEncode(cursor) end)
            cursorPart = "&cursor=" .. encoded
        end
        local url = string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=%s&excludeFullGames=true&limit=100%s",
            game.PlaceId,
            selectedSort,
            cursorPart
        )
        local body, err = httpGet(url, token)
        if not body then
            if err == "rate limited" and #candidates > 0 then
                -- Keep what we already collected instead of wasting it.
                break
            end
            return nil, err or "api error"
        end

        local decoded, data = pcall(function() return HttpService:JSONDecode(body) end)
        if not (decoded and type(data) == "table" and type(data.data) == "table") then
            -- A 429 response is a JSON error object without a .data array;
            -- surface it as a rate limit so the caller backs off instead
            -- of treating it like a corrupt payload.
            if decoded and type(data) == "table" and type(data.errors) == "table" and data.errors[1] then
                local code = data.errors[1].code
                if code == 429 or code == "429" then
                    noteRateLimited(nil)
                    return nil, "rate limited"
                end
            end
            return nil, "bad api payload"
        end
        for _, server in ipairs(data.data) do
            if type(server) == "table" and type(server.id) == "string" and server.id ~= ""
                and #server.id <= 100 and not candidateIds[server.id]
            then
                local playing = tonumber(server.playing) or 0
                local maxPlayers = tonumber(server.maxPlayers) or 0
                local ping = tonumber(server.ping)
                local fps = tonumber(server.fps)
                local enoughPlayers = playing >= config.MinPlayers
                local enoughSlots = maxPlayers > 0 and maxPlayers - playing >= config.MinFreeSlots
                local pingAllowed = config.MaxPing <= 0 or not ping or ping <= config.MaxPing
                local fpsAllowed = config.MinFps <= 0 or not fps or fps >= config.MinFps
                local failedAt = failedServers[server.id]
                local cooledDown = not failedAt or (os.time() - failedAt) >= 90
                if enoughPlayers and enoughSlots and pingAllowed and fpsAllowed and cooledDown
                    and server.id ~= game.JobId and not visitedServers[server.id]
                then
                    candidateIds[server.id] = true
                    table.insert(candidates, {
                        id = server.id,
                        playing = playing,
                        maxPlayers = maxPlayers,
                        ping = ping,
                        fps = fps,
                    })
                end
            end
        end
        if #candidates >= targetCount then break end
        if type(data.nextPageCursor) ~= "string" or data.nextPageCursor == "" then break end
        cursor = data.nextPageCursor
        task.wait(0.25)
    end

    local chosen = pickServer(candidates)
    if chosen then
        setProgress(1, GREEN)
        for _, c in ipairs(candidates) do
            if c ~= chosen and #serverPool < 60 then
                c.ts = os.time()
                table.insert(serverPool, c)
            end
        end
        savePool()
        return chosen, nil
    end
    return nil, "no unvisited servers"
end

local function recycleVisitedIfStuck()
    local before = countVisited()
    local kept = math.max(1, math.floor(before / 2))
    forgetOldestVisited(kept)
    setStatus("history recycled (" .. tostring(countVisited()) .. " kept)")
    updateStats()
end

local function flashMatch()
    task.spawn(function()
        -- Celebration: border strobes green while the window does a happy bounce.
        if config.Animations and Main.Parent then
            tween(MainScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {
                Scale = responsiveMainScale * 1.03,
            })
            task.delay(0.13, function()
                if guiAlive and Main.Parent then
                    tween(MainScale, TweenInfo.new(0.3, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {
                        Scale = responsiveMainScale,
                    })
                end
            end)
        end
        for _ = 1, 3 do
            if not (guiAlive and Main.Parent) then return end
            tween(Main, TweenInfo.new(0.12), { BorderColor3 = GREEN })
            tween(Title, TweenInfo.new(0.12), { TextColor3 = GREEN })
            task.wait(0.14)
            tween(Main, TweenInfo.new(0.12), { BorderColor3 = P() })
            tween(Title, TweenInfo.new(0.12), { TextColor3 = P() })
            task.wait(0.14)
        end
    end)
end

-- Horizontal error shake so failures are felt, not just read.
local function shakeMain()
    if not config.Animations or not Main.Parent then return end
    task.spawn(function()
        local origin = Main.Position
        local offsets = { 7, -6, 5, -3, 0 }
        for _, dx in ipairs(offsets) do
            if not (guiAlive and Main.Parent) then return end
            tween(Main, TweenInfo.new(0.045, Enum.EasingStyle.Quad), {
                Position = origin + UDim2.fromOffset(dx, 0),
            })
            task.wait(0.05)
        end
        if guiAlive and Main.Parent then
            tween(Main, TweenInfo.new(0.05), { Position = origin })
        end
    end)
end

-- Full-screen pulse fired right before a teleport is issued, so the
-- hop reads as a brief "warp" surge rather than an instant cut.
local function startSearchSpinner(token)
    task.spawn(function()
        local spin = { "/", "-", "\\", "|" }
        local dots = { "   ", ".  ", ".. ", "..." }
        local idx = 0
        while hopStillActive(token) do
            idx = idx + 1
            local s = spin[(idx - 1) % #spin + 1]
            local d = dots[math.floor((idx - 1) / 3) % #dots + 1]
            SearchBtn.Text = "[ " .. s .. " ] SEARCHING" .. d
            task.wait(0.12)
        end
        if guiAlive and token == hopToken then updateBtnText() end
    end)
end

local Portal
local executeHop
local queueWarningShown = false
local queuePrepared = false

-- Handle a server that failed to receive us. It is removed from the
-- persisted history so future sessions may still try it, but blacklisted
-- in this session so we do not immediately re-pick the same full server.
local function markServerFailed(serverId)
    if pendingServerId and pendingServerId == serverId then
        pendingServerId = nil
    end
    if serverId and visitedServers[serverId] ~= nil then
        visitedServers[serverId] = nil
        saveVisited(visitedServers)
    end
    if serverId then
        failedServers[serverId] = os.time()
    end
end

local function retryAuto(token, delaySeconds)
    task.delay(delaySeconds or 1.5, function()
        if guiAlive and config.AutoHop and not isHopping and token == hopToken then
            executeHop("retry")
        end
    end)
end

local function failHop(token, message, serverId)
    if token ~= hopToken then return end
    if Portal then Portal.cleanup() end
    markServerFailed(serverId)
    isHopping = false
    sessionStats.failures = sessionStats.failures + 1
    setProgress(1, RED)
    setStatus(message)
    updateBtnText()
    updateStats()
    notify(message, RED)
    shakeMain()
    retryAuto(token, 1.5)
end

executeHop = function()
    if isHopping or not guiAlive then return end

    -- Respect an active rate-limit cooldown instead of hammering the API
    -- again. Waiting here (rather than during the hop) keeps the
    -- watchdog from interrupting a legitimate cooldown.
    local cooldown = rateLimitCooldown()
    if cooldown > 0 and #serverPool == 0 then
        setStatus(string.format("rate limited; retry in %.0fs", cooldown))
        notify("HTTP 429 — backing off " .. math.floor(cooldown) .. "s", RED)
        if config.AutoHop then
            retryAuto(hopToken, cooldown + 1)
        end
        return
    end

    isHopping = true
    hopToken = hopToken + 1
    local token = hopToken
    sessionStats.lastHopStart = os.clock()
    pendingServerId = nil
    setProgress(0, P(), true)
    startSearchSpinner(token)
    setStatus("searching public servers")

    if not queuePrepared then queuePrepared = setQueue() end
    local queueReady = queuePrepared
    if config.AutoHop and not queueReady and not queueWarningShown then
        queueWarningShown = true
        notify("queue_on_teleport unavailable; auto-loop may not resume", RED)
    end

    local target, err = getUnvisitedServer(token)
    if not hopStillActive(token) then return end

    if not target then
        isHopping = false
        if err == "rate limited" then
            local wait = math.max(rateLimitCooldown(), 2) + 1
            sessionStats.failures = sessionStats.failures + 1
            setStatus(string.format("rate limited; retry in %.0fs", wait))
            notify("HTTP 429 — backing off " .. math.floor(wait) .. "s", RED)
            setProgress(1, RED)
            updateBtnText()
            updateStats()
            shakeMain()
            retryAuto(token, wait)
            return
        end
        if err == "no unvisited servers" then
            recycleVisitedIfStuck()
        else
            sessionStats.failures = sessionStats.failures + 1
            setStatus(err or "no server found")
            notify(err or "No server found", RED)
        end
        setProgress(1, RED)
        updateBtnText()
        updateStats()
        retryAuto(token, 2)
        return
    end

    pendingServerId = target.id
    visitedServers[target.id] = os.time()
    visitedServers = pruneVisited(visitedServers)
    saveVisited(visitedServers)
    sessionStats.hops = sessionStats.hops + 1
    updateStats()

    local details = string.format("%d/%d", target.playing, target.maxPlayers)
    if target.ping then details = details .. string.format(" %dms", math.floor(target.ping)) end
    if target.fps then details = details .. string.format(" %dfps", math.floor(target.fps)) end
    setStatus("teleport " .. string.sub(target.id, 1, 8) .. ".. | " .. details)
    notify("Server selected: " .. details, GREEN)

    -- Warp charge-up: border strobe accelerating before the actual teleport call.
    if config.Animations and Main.Parent then
        task.spawn(function()
            local delays = { 0.16, 0.12, 0.08, 0.05 }
            for _, d in ipairs(delays) do
                if not (guiAlive and Main.Parent) then return end
                tween(Main, TweenInfo.new(d, Enum.EasingStyle.Quad), { BorderColor3 = GREEN })
                task.wait(d)
                tween(Main, TweenInfo.new(d, Enum.EasingStyle.Quad), { BorderColor3 = P() })
                task.wait(d)
            end
        end)
    end

    if config.Animations then
        task.spawn(function()
            local flash = Instance.new("Frame")
            flash.Name = "WarpFlash"
            flash.Size = UDim2.new(1, 0, 1, 0)
            flash.BackgroundColor3 = P()
            flash.BackgroundTransparency = 1
            flash.BorderSizePixel = 0
            flash.ZIndex = 500
            flash.Parent = ScreenGui
            tween(flash, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                BackgroundTransparency = 0.5,
            })
            task.wait(0.16)
            if flash.Parent then
                tween(flash, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                    BackgroundTransparency = 1,
                })
                task.delay(0.42, function()
                    if flash.Parent then flash:Destroy() end
                end)
            end
        end)
    end

    -- Rick and Morty: open the portal three seconds before the jump and
    -- (with PORTAL GATE on) wait for the player to walk through it.
    if Portal then
        Portal.gate(token)
    end
    if not hopStillActive(token) then
        if Portal then Portal.cleanup() end
        return
    end
    sessionStats.lastHopStart = os.clock()

    -- Leave a marker so the next server seals a closing portal behind us.
    if currentTheme == "RICK AND MORTY" and type(writefile) == "function" then
        pcall(function()
            writefile("ServerFinderPortal.json", HttpService:JSONEncode({ ts = os.time() }))
        end)
    end

    local ok, teleportError = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, target.id, LocalPlayer)
    end)
    if not ok then
        failHop(token, "teleport call failed: " .. tostring(teleportError), target.id)
        return
    end

    task.delay(TELEPORT_TIMEOUT, function()
        if hopStillActive(token) then
            failHop(token, "teleport timed out; selecting another server", pendingServerId or target.id)
        end
    end)
end

rememberConnection(TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage)
    if not guiAlive or not isHopping then return end
    -- We only ever initiate teleports for the local player, so a failure
    -- while hopping is ours. Some executors pass nil or a copied Player
    -- here; when the argument can be identified as someone else, skip it.
    if player and player ~= LocalPlayer then
        local okId, userId = pcall(function() return player.UserId end)
        if okId and userId ~= LocalPlayer.UserId then return end
    end
    local token = hopToken
    local message = "teleport failed: " .. tostring(result)
    if type(errorMessage) == "string" and errorMessage ~= "" then
        message = message .. " (" .. string.sub(errorMessage, 1, 80) .. ")"
    end
    failHop(token, message, pendingServerId)
end))

-- Safety watchdog: if a hop ever gets stuck (teleport neither lands nor
-- reports a failure), force-recover so the auto-loop keeps going instead
-- of silently freezing forever.
task.spawn(function()
    while guiAlive do
        if isHopping and (os.clock() - sessionStats.lastHopStart) > (TELEPORT_TIMEOUT + 3) then
            failHop(hopToken, "hop stalled; recovering and retrying", pendingServerId)
        end
        task.wait(1)
    end
end)

-- ============================================================
-- RICK AND MORTY PORTAL (v2.11)
-- A 3D portal built from Parts. Opens in front of the player three
-- seconds before a teleport (open sound, green flash, PointLight glow
-- and a burst of neon part-particles), optionally waits for the player
-- to walk inside, then jumps. On arrival a portal spawns behind the
-- player and seals itself (close sound). No shockwave rings.
-- ============================================================
Portal = (function()
    local IMG = "rbxassetid://104310499688141"
    local OPEN_SOUND = "rbxassetid://1013378689"
    local CLOSE_SOUND = "rbxassetid://79092478163364"
    local GLOW = Color3.fromRGB(140, 255, 96)
    local GLOW_SOFT = Color3.fromRGB(90, 255, 160)
    local ENTER_RADIUS = 5
    local ENTRY_TIMEOUT = 20
    local MIN_OPEN = 3
    local AUTO_WALK_DELAY = 1.2

    local lastPortal = nil
    local lastImages = { front = nil, back = nil }
    local lastAssembly = nil

    local function cleanup()
        if lastPortal and lastPortal.Parent then
            pcall(function() lastPortal:Destroy() end)
        end
        lastPortal = nil
        lastImages.front = nil
        lastImages.back = nil
        lastAssembly = nil
    end

    local function playSound(id, volume, parent)
        pcall(function()
            local s = Instance.new("Sound")
            s.SoundId = id
            s.Volume = volume or 1
            s.Parent = parent or workspace
            s:Play()
            task.delay(6, function()
                if s.Parent then s:Destroy() end
            end)
        end)
    end

    local function root()
        local c = LocalPlayer.Character
        if not c then return nil end
        local hrp = c:FindFirstChild("HumanoidRootPart")
        if hrp then return hrp end
        local hum = c:FindFirstChildOfClass("Humanoid")
        if hum and hum.RootPart then return hum.RootPart end
        return nil
    end

    local function humanoid()
        local c = LocalPlayer.Character
        if c then return c:FindFirstChildOfClass("Humanoid") end
        return nil
    end

    local function forwardVector()
        local look = Vector3.new(0, 0, -1)
        local cam = workspace.CurrentCamera
        if cam then
            pcall(function() look = cam.CFrame.LookVector end)
        end
        look = Vector3.new(look.X, 0, look.Z)
        if look.Magnitude < 0.05 then look = Vector3.new(0, 0, -1) end
        return look.Unit
    end

    -- Small glowing ball helper used by every particle effect.
    local function spawnBall(size, color, transparency)
        local p = Instance.new("Part")
        p.Size = Vector3.new(size, size, size)
        p.Shape = Enum.PartType.Ball
        p.Anchored = true
        p.CanCollide = false
        p.Material = Enum.Material.Neon
        p.Color = color or GLOW
        p.Transparency = transparency or 0
        p.Parent = workspace
        return p
    end

    -- Procedural portal built from glowing neon parts: an oval frame, a
    -- spinning pinwheel vortex and a soft energy core. Parts render on
    -- every device, even where GUI images do not.
    local function buildAssembly(face)
        local mainList = {}
        local innerList = {}

        local function add(list, part, localCFrame)
            table.insert(list, { part = part, cf = localCFrame })
        end

        -- Oval rim of neon balls.
        for i = 1, 28 do
            local a = (i - 1) / 28 * math.pi * 2
            local p = spawnBall(i % 4 == 0 and 0.5 or 0.34)
            p.Color = (i % 4 == 0) and GLOW_SOFT or GLOW
            p.Parent = face
            add(mainList, p, CFrame.new(math.cos(a) * 2.7, math.sin(a) * 4.3, 0))
        end

        -- Spiral arms: a galaxy swirl so the portal reads instantly even
        -- without any image texture.
        for arm = 1, 4 do
            local base = (arm - 1) / 4 * math.pi * 2
            for i = 1, 12 do
                local t = i / 12
                local angle = base + t * 2.6
                local radius = 0.5 + t * 2.55
                local p = spawnBall(0.46 - t * 0.22)
                p.Color = (i % 3 == 0) and GLOW_SOFT or GLOW
                p.Parent = face
                add(mainList, p, CFrame.new(
                    math.cos(angle) * radius,
                    math.sin(angle) * radius * 1.6,
                    0
                ))
            end
        end

        -- Inner counter-swirl for depth.
        for arm = 1, 3 do
            local base = (arm - 1) / 3 * math.pi * 2
            for i = 1, 8 do
                local t = i / 8
                local angle = base + t * 2.2
                local radius = 0.35 + t * 1.5
                local p = spawnBall(0.4 - t * 0.2)
                p.Color = GLOW
                p.Parent = face
                add(innerList, p, CFrame.new(
                    math.cos(angle) * radius,
                    math.sin(angle) * radius * 1.6,
                    0
                ))
            end
        end

        -- Soft energy core disc (flat, faint green haze).
        local core = Instance.new("Part")
        core.Size = Vector3.new(5, 0.2, 5)
        core.Shape = Enum.PartType.Cylinder
        core.Anchored = true
        core.CanCollide = false
        core.Material = Enum.Material.Neon
        core.Color = GLOW
        core.Transparency = 0.8
        core.Parent = face
        add(mainList, core, CFrame.Angles(math.rad(90), 0, 0))

        return { main = mainList, inner = innerList }
    end

    -- Scattering burst of neon parts (opening) or implosion (closing).
    local function burst(center, count, inward)
        for _ = 1, (count or 12) do
            task.spawn(function()
                local p = spawnBall(RNG:NextNumber(0.18, 0.32))
                p.CFrame = center * CFrame.new(
                    RNG:NextNumber(-2.5, 2.5),
                    RNG:NextNumber(-3, 3),
                    RNG:NextNumber(-0.4, 0.4)
                )
                local target = center.Position
                local dir
                if inward then
                    dir = (target - p.Position).Unit
                else
                    dir = Vector3.new(
                        RNG:NextNumber(-1, 1),
                        RNG:NextNumber(-0.3, 1),
                        RNG:NextNumber(-0.5, 0.5)
                    ).Unit
                end
                local step = inward and 0.35 or 0.26
                local t = 0
                while t < 1.15 and p.Parent do
                    t = t + 0.05
                    p.CFrame = p.CFrame * CFrame.new(dir * step)
                    p.Transparency = math.min(1, t / 1.15)
                    task.wait(0.05)
                end
                if p.Parent then p:Destroy() end
            end)
        end
    end

    -- Sparks that orbit the portal while it is open.
    local function orbit(center)
        task.spawn(function()
            local orbiters = {}
            for i = 1, 10 do
                orbiters[i] = {
                    part = spawnBall(0.28),
                    phase = (i - 1) / 10 * math.pi * 2,
                    radius = RNG:NextNumber(4.6, 6.4),
                    height = RNG:NextNumber(-3.2, 3.2),
                    speed = RNG:NextNumber(1.5, 2.5),
                }
            end
            local t = 0
            while t < 2.8 and orbiters[1].part.Parent do
                t = t + 0.05
                for _, o in ipairs(orbiters) do
                    if o.part.Parent then
                        local a = o.phase + t * o.speed
                        o.part.CFrame = CFrame.new(center.Position + Vector3.new(
                            math.cos(a) * o.radius,
                            o.height,
                            math.sin(a) * o.radius
                        ))
                        o.part.Transparency = math.min(1, o.part.Transparency + 0.02)
                    end
                end
                task.wait(0.05)
            end
            for _, o in ipairs(orbiters) do
                if o.part.Parent then o.part:Destroy() end
            end
        end)
    end

    -- Embers rising from the base of the portal.
    local function embers(center)
        for _ = 1, 7 do
            task.spawn(function()
                local p = spawnBall(RNG:NextNumber(0.16, 0.26))
                p.CFrame = center * CFrame.new(
                    RNG:NextNumber(-2.4, 2.4),
                    -4,
                    RNG:NextNumber(-0.3, 0.3)
                )
                local rise = RNG:NextNumber(0.12, 0.22)
                local t = 0
                while t < 1.5 and p.Parent do
                    t = t + 0.04
                    p.CFrame = p.CFrame * CFrame.new(0, rise, 0)
                    p.Transparency = math.min(1, 0.15 + t / 1.5)
                    task.wait(0.04)
                end
                if p.Parent then p:Destroy() end
            end)
        end
    end

    -- Big glowing plate that flares bright green and fades out.
    local function flash(center)
        task.spawn(function()
            local plate = Instance.new("Part")
            plate.Size = Vector3.new(11, 11, 0.3)
            plate.Anchored = true
            plate.CanCollide = false
            plate.Material = Enum.Material.Neon
            plate.Color = GLOW
            plate.Transparency = 1
            plate.CFrame = center
            plate.Parent = workspace
            local light = Instance.new("PointLight")
            light.Color = GLOW
            light.Brightness = 0
            light.Range = 18
            light.Parent = plate
            local t = 0
            while t < 0.55 and plate.Parent do
                t = t + 0.03
                local a = math.clamp(1 - math.abs(t - 0.22) / 0.22, 0, 1)
                plate.Transparency = 1 - a * 0.85
                light.Brightness = a * 6
                task.wait(0.03)
            end
            if plate.Parent then plate:Destroy() end
        end)
    end

    -- Ambient life while the portal is open: the whole neon assembly
    -- spins around the portal axis, the glow breathes, the image shimmers
    -- and embers keep rising.
    local function ambient(face, glow, frontImage, center, assembly)
        task.spawn(function()
            local t = 0
            local spin = 0
            local grow = 0
            local nextEmbers = 0.4
            local function place(list, delta)
                for _, entry in ipairs(list) do
                    if entry.part.Parent then
                        local sc = entry.cf
                        local scaled = CFrame.new(sc.Position * grow) * (sc - sc.Position)
                        entry.part.CFrame = face.CFrame * CFrame.Angles(0, delta, 0) * scaled
                    end
                end
            end
            while face.Parent do
                if config.Animations then
                    t = t + 0.05
                    spin = spin + 0.11
                    grow = math.min(1, grow + 0.055)
                    place(assembly.main, spin)
                    place(assembly.inner, -spin * 1.7)
                    if glow.Parent then
                        glow.Brightness = 4 + math.sin(t * 2.6) * 1.3
                    end
                    if frontImage and frontImage.Parent then
                        frontImage.Transparency = 0.06 + math.sin(t * 5) * 0.06
                    end
                    -- In-plane rotation so the portal image itself spins.
                    face.CFrame = face.CFrame * CFrame.Angles(0, 0, math.rad(1.2))
                    nextEmbers = nextEmbers - 0.05
                    if nextEmbers <= 0 then
                        nextEmbers = RNG:NextNumber(0.6, 1.2)
                        embers(center)
                    end
                end
                task.wait(0.05)
            end
        end)
    end

    local function openPortal(cf, quiet)
        cleanup()
        local face = Instance.new("Part")
        face.Name = "SF_Portal"
        face.Size = Vector3.new(0.3, 0.3, 0.3)
        face.Anchored = true
        face.CanCollide = false
        face.CanQuery = false
        face.Material = Enum.Material.Plastic
        face.Color = Color3.fromRGB(0, 0, 0)
        face.Transparency = 0.99
        face.CFrame = cf
        face.Parent = workspace
        lastPortal = face

        -- The image is a Decal on both faces. The plate stays 99%
        -- transparent (effectively invisible), and that is exactly what
        -- lets Roblox render the decal: a fully transparent part hides
        -- its decals, 0.99 keeps them visible.
        local decalFront = Instance.new("Decal")
        decalFront.Name = "PortalImage"
        decalFront.Texture = IMG
        decalFront.Face = Enum.NormalId.Front
        decalFront.Transparency = 0
        decalFront.Parent = face

        local decalBack = Instance.new("Decal")
        decalBack.Name = "PortalImageBack"
        decalBack.Texture = IMG
        decalBack.Face = Enum.NormalId.Back
        decalBack.Transparency = 0
        decalBack.Parent = face

        lastImages.front = decalFront
        lastImages.back = decalBack

        local glow = Instance.new("PointLight")
        glow.Color = GLOW
        glow.Brightness = 4
        glow.Range = 16
        glow.Parent = face

        local halo = Instance.new("PointLight")
        halo.Color = GLOW_SOFT
        halo.Brightness = 1.5
        halo.Range = 30
        halo.Parent = face

        if not quiet then
            playSound(OPEN_SOUND, 1, face)
            burst(cf, 16)
            flash(cf)
            orbit(cf)
        end

        -- Neon portal frame (always visible) + image as an extra layer.
        lastAssembly = buildAssembly(face)

        -- Opening animation: the plate carrying the image grows from a
        -- point to full size while the neon frame spins up.
        tween(face, TweenInfo.new(0.9, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Size = Vector3.new(5, 8, 0.3),
        })

        ambient(face, glow, lastImages.front, cf, lastAssembly)

        task.delay(12, function()
            if face == lastPortal and face.Parent then
                face:Destroy()
                lastPortal = nil
            end
        end)

        return face
    end

    -- Closing: particles implode, the image fades and the plate collapses.
    local function closePortal(face)
        if not face or not face.Parent then return end
        playSound(CLOSE_SOUND, 1, face)
        burst(face.CFrame, 14, true)
        tween(face, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Size = Vector3.new(0.3, 0.3, 0.3),
        })
        for _, img in pairs({ lastImages.front, lastImages.back }) do
            if img and img.Parent then
                tween(img, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                    Transparency = 1,
                })
            end
        end
        for _, list in ipairs({ lastAssembly and lastAssembly.main or {}, lastAssembly and lastAssembly.inner or {} }) do
            for _, entry in ipairs(list) do
                if entry.part.Parent then
                    tween(entry.part, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                        Transparency = 1,
                    })
                end
            end
        end
        task.delay(0.75, function()
            if face.Parent then face:Destroy() end
            if face == lastPortal then lastPortal = nil end
        end)
    end

    -- Walks the character into the portal so the hop never depends on
    -- the player moving manually.
    local function autoWalk(portalPos)
        local hum = humanoid()
        if not hum or hum.Health <= 0 then return end
        pcall(function()
            hum.Sit = false
            hum.WalkSpeed = math.max(tonumber(hum.WalkSpeed) or 16, 16)
            hum:MoveTo(portalPos)
        end)
    end

    local function gate(token)
        if currentTheme ~= "RICK AND MORTY" then return end
        local base = Vector3.new(0, 12, 0)
        local r = root()
        if r then base = r.Position end
        if not r and workspace.CurrentCamera then
            base = workspace.CurrentCamera.CFrame.Position
        end
        local fwd = forwardVector()
        local pos = base + fwd * 7 + Vector3.new(0, 1.3, 0)
        local cf = CFrame.new(pos, pos + fwd)
        openPortal(cf)
        setStatus("portal open — walk into it")
        notify("Portal open — step inside to jump", GLOW)
        local openedAt = os.clock()
        local entered = false
        local walking = false
        local stuckPos = nil
        local stuckAt = 0
        local lastMoveAt = 0
        if config.PortalGate then
            while hopStillActive(token) and (os.clock() - openedAt) < ENTRY_TIMEOUT do
                sessionStats.lastHopStart = os.clock()
                local rp = root()
                -- Auto-walk assist so the character enters on its own.
                if not entered and not walking and (os.clock() - openedAt) >= AUTO_WALK_DELAY then
                    walking = true
                    stuckPos = rp and rp.Position or nil
                    stuckAt = os.clock()
                    lastMoveAt = os.clock()
                    setStatus("portal open — walking in")
                    autoWalk(pos)
                end
                if walking and rp and (os.clock() - lastMoveAt) > 0.5 then
                    lastMoveAt = os.clock()
                    autoWalk(pos)
                    if stuckPos and (rp.Position - stuckPos).Magnitude < 0.8 and (os.clock() - stuckAt) > 4 then
                        -- Character is wedged; release control and jump anyway.
                        break
                    end
                end
                if rp and (rp.Position - pos).Magnitude < ENTER_RADIUS then
                    entered = true
                    break
                end
                task.wait(0.12)
            end
        end
        if entered then
            setStatus("portal entered — teleporting")
            notify("Portal entered!", GLOW)
            local last = lastPortal
            if last and last.Parent then
                flash(last.CFrame)
                burst(last.CFrame, 10)
            end
        end
        local wait = MIN_OPEN - (os.clock() - openedAt)
        while wait > 0 and hopStillActive(token) do
            sessionStats.lastHopStart = os.clock()
            task.wait(0.1)
            wait = wait - 0.1
        end
        if not hopStillActive(token) then
            cleanup()
        end
    end

    -- Arrival: portal behind the player that seals itself.
    local function sealBehind()
        local base = Vector3.new(0, 12, 0)
        local r = root()
        if r then base = r.Position end
        local behind = -forwardVector()
        local pos = base + behind * 5 + Vector3.new(0, 1.4, 0)
        local cf = CFrame.new(pos, pos + behind)
        local face = openPortal(cf, true)
        orbit(cf)
        task.delay(1.6, function()
            closePortal(face)
        end)
    end

    -- Warm the client image cache so the portal picture is already
    -- downloaded when the portal opens (some devices need a few seconds).
    local function preloadImage()
        pcall(function()
            local warm = Instance.new("ImageLabel")
            warm.Name = "PortalWarm"
            warm.Size = UDim2.fromOffset(1, 1)
            warm.BackgroundTransparency = 1
            warm.Image = IMG
            warm.Visible = false
            warm.Parent = ScreenGui
        end)
        task.spawn(function()
            pcall(function()
                game:GetService("ContentProvider"):PreloadAsync({ IMG })
            end)
        end)
    end
    preloadImage()

    return {
        cleanup = cleanup,
        gate = gate,
        sealBehind = sealBehind,
    }
end)()

local function countDonators()
    local n = 0
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer and pl.MembershipType == Enum.MembershipType.Premium then
            n = n + 1
        end
    end
    return n
end

local function getRegionStats(region)
    if region == "ANY" then return 0, 0, 100 end
    local matched, known = 0, 0
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer then
            local cached = countryCache[pl.UserId]
            local code = cached ~= false and cached or nil
            if code then
                known = known + 1
                if countryMatchesRegion(code, region) then matched = matched + 1 end
            end
        end
    end
    local percent = known > 0 and math.floor((matched / known) * 100 + 0.5) or 0
    return matched, known, percent
end

local function evaluateServer()
    evaluateToken = evaluateToken + 1
    local token = evaluateToken
    if not config.AutoHop or isHopping then return end

    local function chatStats(windowSeconds)
        local total, russian, chatters = 0, 0, {}
        local now = os.clock()
        for _, entry in ipairs(chatLog) do
            if now - entry.at <= windowSeconds then
                total = total + 1
                chatters[entry.userId] = true
                if entry.ru then russian = russian + 1 end
            end
        end
        local unique = 0
        for _ in pairs(chatters) do unique = unique + 1 end
        return total, unique, russian
    end

    local seconds = config.AnalyzeSeconds
    setProgress(0, P(), true)
    for elapsed = 0, seconds - 1 do
        if not guiAlive or not config.AutoHop or token ~= evaluateToken or isHopping then
            if guiAlive then updateBtnText() end
            return
        end
        local remaining = seconds - elapsed
        SearchBtn.Text = string.format("[ ANALYZING (%ds)... ]", remaining)
        setStatus(string.format("listening chat / scanning players (%ds)", remaining))
        setProgress(elapsed / seconds, P())
        task.wait(1)
    end

    if not guiAlive or not config.AutoHop or token ~= evaluateToken or isHopping then
        if guiAlive then updateBtnText() end
        return
    end

    -- Give outstanding country calls a short grace period before rejecting a region.
    local regionDeadline = os.clock() + 3
    while config.PeopleRegion ~= "ANY" and next(countryLookupInFlight) ~= nil and os.clock() < regionDeadline do
        if not guiAlive or not config.AutoHop or token ~= evaluateToken or isHopping then return end
        setStatus("finishing audience region lookup")
        task.wait(0.15)
    end

    local donatorCount = countDonators()
    local playerCount = #Players:GetPlayers()
    local chatWindow = math.max(seconds, 8) + 8
    local chatMessageCount, chatterCount, russianChatCount = chatStats(chatWindow)
    local passDonators = not config.FilterDonators or donatorCount >= 1
    local passChat = not config.FilterChat or chatMessageCount >= 1
    local passPlayers = playerCount >= config.MinPlayers
    local regionMatched, regionKnown, regionPercent = getRegionStats(config.PeopleRegion)
    local passRegion = config.PeopleRegion == "ANY"
        or (regionKnown > 0 and regionMatched > 0 and regionPercent >= config.MinRegionPercent)
        or (config.PeopleRegion == "RUSSIAN" and russianChatCount > 0)

    -- A stop-worthy match must satisfy every active criterion AND carry
    -- at least one real stop signal (premium, chat or region). If all of
    -- those are disabled the loop would otherwise "match" every server
    -- with zero evidence and stop instantly -- so instead it keeps
    -- hopping until the user presses STOP.
    local hasStopSignal = config.FilterDonators or config.FilterChat or config.PeopleRegion ~= "ANY"

    if passDonators and passChat and passPlayers and passRegion and hasStopSignal then
        SearchBtn.Text = "[ MATCH FOUND ]"
        setProgress(1, GREEN)
        local regionText = config.PeopleRegion == "ANY"
            and "ANY"
            or string.format("%d/%d (%d%%)", regionMatched, regionKnown, regionPercent)
        setStatus(string.format(
            "match prem=%s chat=%s ru=%d region=%s",
            config.FilterDonators and tostring(donatorCount) or "-",
            config.FilterChat and string.format("%d/%d", chatMessageCount, chatterCount) or "-",
            russianChatCount,
            regionText
        ))
        config.AutoHop = false
        saveSettings(config, true)
        flashMatch()
        notify("Matching server found", GREEN)
        task.delay(1.4, function()
            if guiAlive and not config.AutoHop and token == evaluateToken then updateBtnText() end
        end)
        return
    end

    local reasons = {}
    if not hasStopSignal then
        table.insert(reasons, "no stop filters (only min players)")
    else
        if not passDonators then table.insert(reasons, "no premium") end
        if not passChat then table.insert(reasons, "silent chat") end
        if not passPlayers then table.insert(reasons, "few players") end
        if not passRegion then table.insert(reasons, "wrong region " .. tostring(regionPercent) .. "%") end
    end
    local why = table.concat(reasons, ", ")
    SearchBtn.Text = "[ NEXT SERVER ]"
    setProgress(1, RED)
    setStatus(string.format(
        "skip (%s) prem=%d chat=%d/%d ru=%d pl=%d",
        why, donatorCount, chatMessageCount, chatterCount, russianChatCount, playerCount
    ))
    task.wait(0.45)
    if config.AutoHop and guiAlive and token == evaluateToken and not isHopping then
        executeHop()
    else
        updateBtnText()
    end
end

SearchBtn.MouseButton1Click:Connect(function()
    config.AutoHop = not config.AutoHop
    saveSettings(config, true)
    updateBtnText()

    if config.AutoHop then
        if isHopping then
            setStatus("auto-loop armed for the next server")
            notify("Auto-loop enabled", GREEN)
        else
            task.spawn(evaluateServer)
        end
    else
        evaluateToken = evaluateToken + 1
        setStatus(isHopping and "auto-loop stopped; current hop continues" or "auto-loop stopped")
        setProgress(0, P())
    end
end)

HopOnceBtn.MouseButton1Click:Connect(function()
    if isHopping then
        setStatus("already hopping")
        return
    end
    evaluateToken = evaluateToken + 1
    task.spawn(executeHop)
end)

renderPlayers()

-- Keep the interface usable on small screens and after a resolution change.
local responsiveUpdateToken = 0
local function updateResponsiveScale()
    responsiveUpdateToken = responsiveUpdateToken + 1
    local token = responsiveUpdateToken
    local viewport = viewportSize()
    responsiveMainScale = math.clamp(math.min((viewport.X - 12) / 340, (viewport.Y - 12) / 540), GUI_MIN_SCALE, 1)
    tween(MainScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Scale = responsiveMainScale })
    InfoWin.setScale(math.clamp(math.min((viewport.X - 12) / 340, (viewport.Y - 12) / 420), GUI_MIN_SCALE, 1))
    SettingsWin.setScale(math.clamp(math.min((viewport.X - 12) / 310, (viewport.Y - 12) / 460), GUI_MIN_SCALE, 1))
    clampToViewport(Main)
    if InfoWin.Frame.Visible then clampToViewport(InfoWin.Frame) end
    if SettingsWin.Frame.Visible then clampToViewport(SettingsWin.Frame) end
    if config.Animations then
        task.delay(0.13, function()
            if guiAlive and token == responsiveUpdateToken then
                clampToViewport(Main)
                if InfoWin.Frame.Visible then clampToViewport(InfoWin.Frame) end
                if SettingsWin.Frame.Visible then clampToViewport(SettingsWin.Frame) end
            end
        end)
    end
end

local cameraViewportConn = nil
local function bindViewportListener()
    if cameraViewportConn then
        pcall(function() cameraViewportConn:Disconnect() end)
        cameraViewportConn = nil
    end
    if workspace.CurrentCamera then
        cameraViewportConn = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveScale)
    end
    task.defer(updateResponsiveScale)
end
bindViewportListener()
rememberConnection(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindViewportListener))
rememberConnection({
    Disconnect = function()
        if cameraViewportConn then cameraViewportConn:Disconnect() end
    end,
})

local interfaceVisible = true
rememberConnection(UserInputService.InputBegan:Connect(function(input, processed)
    if processed or input.KeyCode ~= Enum.KeyCode.RightShift then return end
    interfaceVisible = not interfaceVisible
    if not interfaceVisible then
        InfoWin.Frame.Visible = false
        SettingsWin.Frame.Visible = false
        ToastHost.Visible = false
        if config.Animations then
            tween(MainScale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
                Scale = responsiveMainScale * 0.82,
            })
            tween(Main, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                BackgroundTransparency = 1,
                Rotation = 3,
            })
            task.delay(0.16, function()
                if guiAlive and not interfaceVisible then
                    Main.Visible = false
                    Main.Rotation = 0
                    Main.BackgroundTransparency = 0
                end
            end)
        else
            Main.Visible = false
        end
    else
        Main.Visible = true
        ToastHost.Visible = true
        if config.Animations then
            MainScale.Scale = responsiveMainScale * 0.82
            Main.BackgroundTransparency = 1
            Main.Rotation = -3
        end
        tween(Main, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
            BackgroundTransparency = 0,
            Rotation = 0,
        })
        tween(MainScale, TweenInfo.new(0.26, Enum.EasingStyle.Back), { Scale = responsiveMainScale })
        clampToViewport(Main)
    end
end))

-- First-run hint so new users immediately see the controls.
if not config.Welcomed then
    config.Welcomed = true
    saveSettings(config, true)
    task.delay(1.2, function()
        if guiAlive then
            notify("HOP ONCE = jump now | START AUTO-LOOP = scan | gear = settings | ? = help", P())
        end
    end)
end

-- ============================================================
-- ANTI-AFK
-- Keeps the account awake while the hopper runs so the user can
-- walk away without being kicked for ~20-minute idleness.
--   layer 1: neutralise the idle kick by disabling existing
--             Player.Idled connections (needs getconnections)
--   layer 2: hook Idled and instantly fake a click (resets idle)
--   layer 3: heartbeat fakes input before idle even triggers
-- Toggle: ANTI AFK in Settings (default ON).
-- ============================================================
local VirtualUser = game:GetService("VirtualUser")

local function pokeInput()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
    end)
end

pcall(function()
    if type(getconnections) == "function" and LocalPlayer.Idled then
        for _, conn in pairs(getconnections(LocalPlayer.Idled)) do
            pcall(function()
                conn:Disable()
            end)
        end
    end
end)

local lastAntiAfkNotice = 0
rememberConnection(LocalPlayer.Idled:Connect(function()
    if not config.AntiAfk then return end
    pokeInput()
    if os.time() - lastAntiAfkNotice > 90 then
        lastAntiAfkNotice = os.time()
        notify("Anti-AFK: idle reset", P())
    end
end))

task.spawn(function()
    while guiAlive do
        task.wait(120)
        if guiAlive and config.AntiAfk then
            pokeInput()
        end
    end
end)

-- If we just landed through a portal hop, seal a closing portal behind
-- the player (Rick and Morty theme), then clear the arrival marker.
task.spawn(function()
    if currentTheme ~= "RICK AND MORTY" or not canReadFile("ServerFinderPortal.json") then
        return
    end
    local stale = true
    pcall(function()
        local data = HttpService:JSONDecode(readfile("ServerFinderPortal.json"))
        if type(data) == "table" and (os.time() - (tonumber(data.ts) or 0)) <= 60 then
            stale = false
        end
    end)
    pcall(function() writefile("ServerFinderPortal.json", "") end)
    if not stale then
        task.wait(1)
        if guiAlive and Portal then
            Portal.sealBehind()
        end
    end
end)

if config.AutoHop then
    task.spawn(evaluateServer)
end
