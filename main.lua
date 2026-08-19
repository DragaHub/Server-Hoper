local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

if not Players.LocalPlayer then
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
end
local LocalPlayer = Players.LocalPlayer

local RAW_URL = "https://raw.githubusercontent.com/DragaHub/Server-Hoper/main/main.lua"
local SETTINGS_FILE = "ServerFinderConfig.json"
local VISITED_FILE = "ServerFinderVisited.json"
local MAX_VISITED = 200
local MAX_API_PAGES = 8
local HTTP_RETRIES = 3

local guiAlive = true
local isHopping = false
local evaluateToken = 0
local minimized = false

local function setQueue()
    local q = queue_on_teleport or (getgenv and getgenv().queue_on_teleport)
    if not q then
        return false
    end
    local ok = pcall(function()
        q(string.format([[
            repeat task.wait() until game:IsLoaded()
            local lp = game:GetService("Players").LocalPlayer
            if not lp then
                game:GetService("Players"):GetPropertyChangedSignal("LocalPlayer"):Wait()
            end
            loadstring(game:HttpGet("%s"))()
        ]], RAW_URL))
    end)
    return ok
end

local function getHttpRequest()
    return request
        or http_request
        or (syn and syn.request)
        or (http and http.request)
        or (fluxus and fluxus.request)
        or (getgenv and (getgenv().request or getgenv().http_request))
end

-- Черный список посещенных серверов (LRU по времени, старый формат {id=true} тоже читается)
local function loadVisited()
    if isfile and isfile(VISITED_FILE) then
        local success, result = pcall(function()
            return HttpService:JSONDecode(readfile(VISITED_FILE))
        end)
        if success and type(result) == "table" then
            return result
        end
    end
    return {}
end

local function saveVisited(data)
    if writefile then
        pcall(function()
            writefile(VISITED_FILE, HttpService:JSONEncode(data))
        end)
    end
end

local function visitedTimestamp(value)
    if type(value) == "number" then
        return value
    end
    return 0
end

local function pruneVisited(data, keep)
    keep = keep or MAX_VISITED
    local entries = {}
    for id, value in pairs(data) do
        table.insert(entries, { id = id, ts = visitedTimestamp(value) })
    end
    if #entries <= keep then
        return data
    end
    table.sort(entries, function(a, b)
        return a.ts < b.ts
    end)
    local overflow = #entries - keep
    for i = 1, overflow do
        data[entries[i].id] = nil
    end
    return data
end

local visitedServers = loadVisited()
visitedServers[game.JobId] = os.time()
visitedServers = pruneVisited(visitedServers)
saveVisited(visitedServers)

local function forgetOldestVisited(keep)
    visitedServers = pruneVisited(visitedServers, keep)
    visitedServers[game.JobId] = os.time()
    saveVisited(visitedServers)
end

local function countVisited()
    local n = 0
    for _ in pairs(visitedServers) do
        n = n + 1
    end
    return n
end

-- Настройки: новые ключи подмешиваются к старому файлу
local defaultSettings = {
    AutoHop = false,
    FilterDonators = true,
    FilterChat = false,
    MinPlayers = 3,
    AnalyzeSeconds = 5,
    PreferFull = true,
}

local function loadSettings()
    local cfg = {}
    for k, v in pairs(defaultSettings) do
        cfg[k] = v
    end
    if isfile and isfile(SETTINGS_FILE) then
        local success, result = pcall(function()
            return HttpService:JSONDecode(readfile(SETTINGS_FILE))
        end)
        if success and type(result) == "table" then
            for k, v in pairs(result) do
                if defaultSettings[k] ~= nil then
                    cfg[k] = v
                end
            end
        end
    end
    if type(cfg.MinPlayers) ~= "number" then
        cfg.MinPlayers = defaultSettings.MinPlayers
    end
    cfg.MinPlayers = math.clamp(math.floor(cfg.MinPlayers), 1, 40)
    if type(cfg.AnalyzeSeconds) ~= "number" then
        cfg.AnalyzeSeconds = defaultSettings.AnalyzeSeconds
    end
    cfg.AnalyzeSeconds = math.clamp(math.floor(cfg.AnalyzeSeconds), 2, 15)
    return cfg
end

local function saveSettings(cfg)
    if writefile then
        pcall(function()
            writefile(SETTINGS_FILE, HttpService:JSONEncode(cfg))
        end)
    end
end

local config = loadSettings()

if CoreGui:FindFirstChild("ClassicServerFinder") then
    CoreGui.ClassicServerFinder:Destroy()
end
local existingPlayerGui = LocalPlayer:FindFirstChild("PlayerGui")
if existingPlayerGui and existingPlayerGui:FindFirstChild("ClassicServerFinder") then
    existingPlayerGui.ClassicServerFinder:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ClassicServerFinder"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset = true

pcall(function()
    ScreenGui.Parent = CoreGui
end)
if not ScreenGui.Parent then
    ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local chatConns = {}

local function disconnectChat()
    for _, conn in ipairs(chatConns) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    chatConns = {}
end

ScreenGui.Destroying:Connect(function()
    guiAlive = false
    config.AutoHop = false
    disconnectChat()
end)

local WHITE = Color3.fromRGB(255, 255, 255)
local BLACK = Color3.fromRGB(0, 0, 0)
local DIM = Color3.fromRGB(180, 180, 180)
local MUTED = Color3.fromRGB(120, 120, 120)

local function setupRetroButton(button)
    local origSize = button.Size
    local isImage = button:IsA("ImageButton")

    button.MouseEnter:Connect(function()
        if not guiAlive or not button.Parent then
            return
        end
        local props = { BackgroundColor3 = WHITE }
        if isImage then
            props.ImageColor3 = BLACK
        else
            props.TextColor3 = BLACK
        end
        TweenService:Create(button, TweenInfo.new(0.12), props):Play()
    end)

    button.MouseLeave:Connect(function()
        if not guiAlive or not button.Parent then
            return
        end
        local props = { BackgroundColor3 = BLACK }
        if isImage then
            props.ImageColor3 = WHITE
        else
            props.TextColor3 = WHITE
        end
        TweenService:Create(button, TweenInfo.new(0.12), props):Play()
    end)

    button.MouseButton1Down:Connect(function()
        if not guiAlive or not button.Parent then
            return
        end
        TweenService:Create(button, TweenInfo.new(0.05), {
            Size = UDim2.new(origSize.X.Scale, origSize.X.Offset - 4, origSize.Y.Scale, origSize.Y.Offset - 2),
        }):Play()
    end)

    button.MouseButton1Up:Connect(function()
        if not guiAlive or not button.Parent then
            return
        end
        TweenService:Create(button, TweenInfo.new(0.08, Enum.EasingStyle.Back), {
            Size = origSize,
        }):Play()
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

local function makeDraggable(frame, handle)
    local dragging = false
    local dragStart = nil
    local startPos = nil

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            raiseWindow(frame)
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging or not guiAlive then
            return
        end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)
end

local function pulseBorder(frame)
    task.spawn(function()
        while guiAlive and frame.Parent do
            if frame.Visible then
                TweenService:Create(frame, TweenInfo.new(1.2, Enum.EasingStyle.Sine), { BorderColor3 = MUTED }):Play()
            end
            task.wait(1.2)
            if not (guiAlive and frame.Parent) then
                break
            end
            if frame.Visible then
                TweenService:Create(frame, TweenInfo.new(1.2, Enum.EasingStyle.Sine), { BorderColor3 = WHITE }):Play()
            end
            task.wait(1.2)
        end
    end)
end

local function createWindow(opts)
    local win = Instance.new("Frame")
    win.Name = opts.Name
    win.Size = opts.Size
    win.Position = opts.Position
    win.BackgroundColor3 = BLACK
    win.BorderSizePixel = 1
    win.BorderColor3 = WHITE
    win.Active = true
    win.Visible = false
    win.ClipsDescendants = true
    win.ZIndex = 2
    win.Parent = ScreenGui

    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 30)
    titleBar.BackgroundTransparency = 1
    titleBar.Parent = win

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -36, 1, 0)
    title.Position = UDim2.new(0, 8, 0, 0)
    title.Text = opts.Title
    title.TextColor3 = WHITE
    title.Font = Enum.Font.Code
    title.TextSize = 12
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.BackgroundTransparency = 1
    title.Parent = titleBar

    local close = Instance.new("TextButton")
    close.Size = UDim2.new(0, 20, 0, 20)
    close.Position = UDim2.new(1, -25, 0, 5)
    close.BackgroundColor3 = BLACK
    close.BorderSizePixel = 1
    close.BorderColor3 = WHITE
    close.Text = "X"
    close.TextColor3 = WHITE
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
    line.BackgroundColor3 = WHITE
    line.BorderSizePixel = 0
    line.Parent = body

    makeDraggable(win, titleBar)
    pulseBorder(win)

    win.InputBegan:Connect(function()
        raiseWindow(win)
    end)

    close.MouseButton1Click:Connect(function()
        win.Visible = false
    end)

    local function show()
        win.Visible = true
        raiseWindow(win)
        win.BackgroundTransparency = 1
        TweenService:Create(win, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            BackgroundTransparency = 0,
        }):Play()
    end

    return {
        Frame = win,
        Body = body,
        show = show,
        hide = function()
            win.Visible = false
        end,
        toggle = function()
            if win.Visible then
                win.Visible = false
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
Main.Position = UDim2.new(0.5, -170, 0.5, -270)
Main.BackgroundColor3 = BLACK
Main.BorderSizePixel = 1
Main.BorderColor3 = WHITE
Main.Active = true
Main.ClipsDescendants = true
Main.Parent = ScreenGui

Main.BackgroundTransparency = 1
Main.ZIndex = 1
TweenService:Create(Main, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
    BackgroundTransparency = 0,
}):Play()
pulseBorder(Main)

local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 30)
TitleBar.BackgroundTransparency = 1
TitleBar.Parent = Main
makeDraggable(Main, TitleBar)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -118, 1, 0)
Title.Position = UDim2.new(0, 8, 0, 0)
Title.Text = "[ SERVER FINDER ]"
Title.TextColor3 = WHITE
Title.Font = Enum.Font.Code
Title.TextSize = 12
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.BackgroundTransparency = 1
Title.Parent = TitleBar

local function makeHeaderButton(text, xOffset)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 20, 0, 20)
    btn.Position = UDim2.new(1, xOffset, 0, 5)
    btn.BackgroundColor3 = BLACK
    btn.BorderSizePixel = 1
    btn.BorderColor3 = WHITE
    btn.Text = text
    btn.TextColor3 = WHITE
    btn.Font = Enum.Font.Code
    btn.TextSize = 12
    btn.AutoButtonColor = false
    btn.Parent = Main
    setupRetroButton(btn)
    return btn
end

local function makeHeaderImageButton(imageId, xOffset)
    local btn = Instance.new("ImageButton")
    btn.Size = UDim2.new(0, 20, 0, 20)
    btn.Position = UDim2.new(1, xOffset, 0, 5)
    btn.BackgroundColor3 = BLACK
    btn.BorderSizePixel = 1
    btn.BorderColor3 = WHITE
    btn.Image = "rbxassetid://" .. tostring(imageId)
    btn.ImageColor3 = WHITE
    btn.ScaleType = Enum.ScaleType.Fit
    btn.AutoButtonColor = false
    btn.Parent = Main
    setupRetroButton(btn)
    return btn
end

local MinBtn = makeHeaderButton("_", -97)
local SettingsBtn = makeHeaderImageButton(5912368781, -75)
local InfoBtn = makeHeaderButton("?", -50)
local CloseBtn = makeHeaderButton("X", -25)

CloseBtn.MouseButton1Click:Connect(function()
    config.AutoHop = false
    saveSettings(config)
    guiAlive = false
    ScreenGui:Destroy()
end)

local Body = Instance.new("Frame")
Body.Name = "Body"
Body.Size = UDim2.new(1, 0, 1, -30)
Body.Position = UDim2.new(0, 0, 0, 30)
Body.BackgroundTransparency = 1
Body.Parent = Main

MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    Body.Visible = not minimized
    if minimized then
        TweenService:Create(Main, TweenInfo.new(0.15), { Size = MINIMIZED_SIZE }):Play()
        MinBtn.Text = "+"
    else
        TweenService:Create(Main, TweenInfo.new(0.15), { Size = EXPANDED_SIZE }):Play()
        MinBtn.Text = "_"
    end
end)

local Line1 = Instance.new("Frame")
Line1.Size = UDim2.new(1, 0, 0, 1)
Line1.Position = UDim2.new(0, 0, 0, 0)
Line1.BackgroundColor3 = WHITE
Line1.BorderSizePixel = 0
Line1.Parent = Body

local function createToggle(parent, text, pos, size, key)
    local btn = Instance.new("TextButton")
    btn.Size = size
    btn.Position = pos
    btn.BackgroundColor3 = BLACK
    btn.BorderSizePixel = 1
    btn.BorderColor3 = WHITE
    btn.Font = Enum.Font.Code
    btn.TextSize = 10
    btn.TextColor3 = WHITE
    btn.AutoButtonColor = false
    btn.Parent = parent
    setupRetroButton(btn)

    local function updateText()
        btn.Text = (config[key] and "[X] " or "[ ] ") .. text
    end
    updateText()

    btn.MouseButton1Click:Connect(function()
        config[key] = not config[key]
        saveSettings(config)
        updateText()
    end)
    return btn
end

local function createStepper(parent, label, pos, size, key, minValue, maxValue, suffix)
    local frame = Instance.new("Frame")
    frame.Size = size
    frame.Position = pos
    frame.BackgroundColor3 = BLACK
    frame.BorderSizePixel = 1
    frame.BorderColor3 = WHITE
    frame.Parent = parent

    local caption = Instance.new("TextLabel")
    caption.Size = UDim2.new(1, -52, 1, 0)
    caption.Position = UDim2.new(0, 6, 0, 0)
    caption.BackgroundTransparency = 1
    caption.Font = Enum.Font.Code
    caption.TextSize = 10
    caption.TextColor3 = WHITE
    caption.TextXAlignment = Enum.TextXAlignment.Left
    caption.Parent = frame

    local function refresh()
        caption.Text = label .. " " .. tostring(config[key]) .. (suffix or "")
    end
    refresh()

    local function makeStep(symbol, dx, delta)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 20, 0, 18)
        btn.Position = UDim2.new(1, dx, 0.5, -9)
        btn.BackgroundColor3 = BLACK
        btn.BorderSizePixel = 1
        btn.BorderColor3 = WHITE
        btn.Text = symbol
        btn.TextColor3 = WHITE
        btn.Font = Enum.Font.Code
        btn.TextSize = 11
        btn.AutoButtonColor = false
        btn.Parent = frame
        setupRetroButton(btn)
        btn.MouseButton1Click:Connect(function()
            config[key] = math.clamp(config[key] + delta, minValue, maxValue)
            saveSettings(config)
            refresh()
        end)
    end

    makeStep("-", -44, -1)
    makeStep("+", -22, 1)
    return frame
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

local InfoWin = createWindow({
    Name = "InfoWindow",
    Title = "[ DOCUMENTATION & INFO ]",
    Size = UDim2.new(0, 340, 0, 420),
    Position = UDim2.new(0.5, 186, 0.5, -210),
})

local InfoScroll = Instance.new("ScrollingFrame")
InfoScroll.Size = UDim2.new(1, -16, 1, -16)
InfoScroll.Position = UDim2.new(0, 8, 0, 8)
InfoScroll.BackgroundColor3 = BLACK
InfoScroll.BorderSizePixel = 1
InfoScroll.BorderColor3 = WHITE
InfoScroll.ScrollBarThickness = 4
InfoScroll.ScrollBarImageColor3 = WHITE
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
> SCRIPT FUNCTIONALITY

1. AUTO-HOP LOOP
   queue_on_teleport re-runs the script after each hop.

2. DONATORS FILTER
   Requires at least one Roblox Premium player
   (other than you) on the current server.

3. ACTIVE CHAT FILTER
   Counts live chat from other players during
   the analyze window after join.

4. MIN PLAYERS
   Skip empty / dead servers below the threshold.

5. PREFER FULL
   When picking the next server, bias toward
   fuller rooms instead of a fully random pick.

6. ANTI-REPEAT
   Remembers up to 200 JobIds in
   ServerFinderVisited.json (oldest dropped).
   Failed lookups no longer wipe the list.

7. API PAGINATION
   Walks several pages of the public servers
   API, retries 429/errors, encodes cursors.

8. HOP ONCE
   Jump to another server without enabling
   the auto-loop.

Use [?] and the gear to open Info / Settings
as separate windows.

Developed for personal use / ScriptBlox.]]
InfoTextLabel.Parent = InfoScroll

local SettingsWin = createWindow({
    Name = "SettingsWindow",
    Title = "[ SETTINGS ]",
    Size = UDim2.new(0, 300, 0, 292),
    Position = UDim2.new(0.5, -486, 0.5, -146),
})

createToggle(SettingsWin.Body, "DONATORS", UDim2.new(0, 8, 0, 10), UDim2.new(1, -16, 0, 26), "FilterDonators")
hint(SettingsWin.Body, "need at least 1 premium player", UDim2.new(0, 8, 0, 38))

createToggle(SettingsWin.Body, "ACTIVE CHAT", UDim2.new(0, 8, 0, 58), UDim2.new(1, -16, 0, 26), "FilterChat")
hint(SettingsWin.Body, "need chat from other players", UDim2.new(0, 8, 0, 86))

createToggle(SettingsWin.Body, "PREFER FULL", UDim2.new(0, 8, 0, 106), UDim2.new(1, -16, 0, 26), "PreferFull")
hint(SettingsWin.Body, "pick fuller rooms when hopping", UDim2.new(0, 8, 0, 134))

createStepper(SettingsWin.Body, "MIN PLAYERS", UDim2.new(0, 8, 0, 156), UDim2.new(1, -16, 0, 26), "MinPlayers", 1, 40, "")
hint(SettingsWin.Body, "skip quieter servers below this", UDim2.new(0, 8, 0, 184))

createStepper(SettingsWin.Body, "ANALYZE", UDim2.new(0, 8, 0, 204), UDim2.new(1, -16, 0, 26), "AnalyzeSeconds", 2, 15, "s")
hint(SettingsWin.Body, "seconds to listen after join", UDim2.new(0, 8, 0, 232))

local function placeBeside(win, xOffset)
    local mainPos = Main.AbsolutePosition
    local parentAbs = ScreenGui.AbsolutePosition
    win.Frame.Position = UDim2.new(0, (mainPos.X - parentAbs.X) + xOffset, 0, mainPos.Y - parentAbs.Y)
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
        placeBeside(SettingsWin, -(windowWidth(SettingsWin, 300) + 12))
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
Scroll.BackgroundColor3 = BLACK
Scroll.BorderSizePixel = 1
Scroll.BorderColor3 = WHITE
Scroll.ScrollBarThickness = 4
Scroll.ScrollBarImageColor3 = WHITE
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
HopOnceBtn.BackgroundColor3 = BLACK
HopOnceBtn.BorderSizePixel = 1
HopOnceBtn.BorderColor3 = WHITE
HopOnceBtn.Font = Enum.Font.Code
HopOnceBtn.TextSize = 10
HopOnceBtn.TextColor3 = WHITE
HopOnceBtn.Text = "[ HOP ONCE ]"
HopOnceBtn.AutoButtonColor = false
HopOnceBtn.Parent = Body
setupRetroButton(HopOnceBtn)

local SearchBtn = Instance.new("TextButton")
SearchBtn.Size = UDim2.new(0.46, -8, 0, 32)
SearchBtn.Position = UDim2.new(0.52, 0, 1, -48)
SearchBtn.BackgroundColor3 = BLACK
SearchBtn.BorderSizePixel = 1
SearchBtn.BorderColor3 = WHITE
SearchBtn.Font = Enum.Font.Code
SearchBtn.TextSize = 10
SearchBtn.TextColor3 = WHITE
SearchBtn.AutoButtonColor = false
SearchBtn.Parent = Body
setupRetroButton(SearchBtn)

local function setStatus(text)
    if Status and Status.Parent then
        Status.Text = "> " .. text
    end
end

local function updateBtnText()
    if config.AutoHop then
        SearchBtn.Text = "[ STOP AUTO-LOOP ]"
    else
        SearchBtn.Text = "[ START AUTO-LOOP ]"
    end
end
updateBtnText()

local function updateStats()
    local job = tostring(game.JobId or "")
    local shortJob = #job > 8 and (string.sub(job, 1, 8) .. "..") or job
    local n = #Players:GetPlayers()
    Stats.Text = string.format("job %s  |  %d here  |  visited %d", shortJob, n, countVisited())
end

local chatMessageCount = 0

local function bumpChat(userId)
    if not userId or userId == LocalPlayer.UserId then
        return
    end
    chatMessageCount = chatMessageCount + 1
end

pcall(function()
    table.insert(chatConns, TextChatService.MessageReceived:Connect(function(msg)
        if msg and msg.TextSource then
            bumpChat(msg.TextSource.UserId)
        end
    end))
end)

local function trackPlayer(pl)
    if not pl or pl == LocalPlayer then
        return
    end
    table.insert(chatConns, pl.Chatted:Connect(function()
        bumpChat(pl.UserId)
    end))
end

for _, pl in ipairs(Players:GetPlayers()) do
    trackPlayer(pl)
end
Players.PlayerAdded:Connect(trackPlayer)

local playerCards = {}

local function clearPlayerCards()
    for _, card in pairs(playerCards) do
        if card and card.Parent then
            card:Destroy()
        end
    end
    playerCards = {}
end

local function playerSortKey(pl)
    local name = pl.Name or ""
    return string.lower(name)
end

local function buildCard(pl)
    local isDonator = (pl.MembershipType == Enum.MembershipType.Premium)
    local isLocal = pl == LocalPlayer
    local isFriend = false
    if not isLocal then
        local ok, result = pcall(function()
            return LocalPlayer:IsFriendsWith(pl.UserId)
        end)
        isFriend = ok and result == true
    end

    local card = Instance.new("Frame")
    card.Name = "P_" .. tostring(pl.UserId)
    card.Size = UDim2.new(1, -6, 0, 34)
    card.BackgroundColor3 = BLACK
    card.BorderSizePixel = 1
    card.BorderColor3 = WHITE
    card.LayoutOrder = isLocal and 0 or 1
    card.Parent = Scroll

    local avatar = Instance.new("ImageLabel")
    avatar.Size = UDim2.new(0, 26, 0, 26)
    avatar.Position = UDim2.new(0, 4, 0.5, -13)
    avatar.BackgroundColor3 = BLACK
    avatar.BorderSizePixel = 1
    avatar.BorderColor3 = WHITE
    avatar.Parent = card

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
        end
    end)

    local tags = {}
    if isLocal then
        table.insert(tags, "YOU")
    end
    if isFriend then
        table.insert(tags, "FRIEND")
    end
    if isDonator then
        table.insert(tags, "PREMIUM")
    end

    local display = pl.DisplayName
    local uname = pl.Name
    local line
    if display and display ~= "" and display ~= uname then
        line = display .. " @" .. uname
    else
        line = uname
    end
    if #tags > 0 then
        line = line .. " [" .. table.concat(tags, "][") .. "]"
    end

    local info = Instance.new("TextLabel")
    info.Size = UDim2.new(1, -38, 1, 0)
    info.Position = UDim2.new(0, 36, 0, 0)
    info.Text = line
    info.TextColor3 = WHITE
    info.Font = Enum.Font.Code
    info.TextSize = 10
    info.TextXAlignment = Enum.TextXAlignment.Left
    info.TextTruncate = Enum.TextTruncate.AtEnd
    info.BackgroundTransparency = 1
    info.Parent = card

    return card
end

local renderQueued = false
local function renderPlayers()
    if not guiAlive then
        return
    end
    clearPlayerCards()

    local list = Players:GetPlayers()
    table.sort(list, function(a, b)
        if a == LocalPlayer then
            return true
        end
        if b == LocalPlayer then
            return false
        end
        return playerSortKey(a) < playerSortKey(b)
    end)

    for _, pl in ipairs(list) do
        playerCards[pl.UserId] = buildCard(pl)
    end
    updateStats()
end

local function scheduleRender()
    if renderQueued then
        return
    end
    renderQueued = true
    task.defer(function()
        renderQueued = false
        if guiAlive then
            renderPlayers()
        end
    end)
end

local function parseHttpResponse(res)
    if type(res) ~= "table" then
        return nil, nil
    end
    local status = res.StatusCode or res.Status or res.status_code or res.status
    local body = res.Body or res.body or res.SuccessBody
    return status, body
end

local function httpGet(url)
    local httpRequest = getHttpRequest()
    if not httpRequest then
        return nil, "no executor http"
    end

    for attempt = 1, HTTP_RETRIES do
        if not guiAlive then
            return nil, "stopped"
        end
        local success, res = pcall(function()
            return httpRequest({
                Url = url,
                Method = "GET",
                Headers = { ["Accept"] = "application/json" },
            })
        end)
        if success and res then
            local status, body = parseHttpResponse(res)
            if type(status) == "number" and status == 429 then
                task.wait(0.6 * attempt)
            elseif type(body) == "string" and body ~= "" then
                if (not status) or status == 200 then
                    return body, nil
                end
                task.wait(0.25 * attempt)
            else
                task.wait(0.25 * attempt)
            end
        else
            task.wait(0.25 * attempt)
        end
    end
    return nil, "http failed"
end

local function pickServer(valid)
    if #valid == 0 then
        return nil
    end
    if config.PreferFull then
        table.sort(valid, function(a, b)
            return (a.playing or 0) > (b.playing or 0)
        end)
        local top = math.min(5, #valid)
        return valid[math.random(1, top)].id
    end
    return valid[math.random(1, #valid)].id
end

local function getUnvisitedServer()
    if not getHttpRequest() then
        return nil, "executor has no http request"
    end

    local sortOrders = { "Asc", "Desc" }
    local selectedSort = sortOrders[math.random(1, #sortOrders)]
    local cursor = ""

    for page = 1, MAX_API_PAGES do
        if not guiAlive then
            return nil, "stopped"
        end

        local cursorPart = ""
        if cursor ~= "" then
            local encoded = cursor
            pcall(function()
                encoded = HttpService:UrlEncode(cursor)
            end)
            cursorPart = "&cursor=" .. encoded
        end

        local url = string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=%s&excludeFullGames=true&limit=100%s",
            game.PlaceId,
            selectedSort,
            cursorPart
        )

        local body, err = httpGet(url)
        if not body then
            return nil, err or "api error"
        end

        local decSuccess, data = pcall(function()
            return HttpService:JSONDecode(body)
        end)
        if not (decSuccess and type(data) == "table" and type(data.data) == "table") then
            return nil, "bad api payload"
        end

        local valid = {}
        for _, s in ipairs(data.data) do
            if type(s) == "table" and type(s.id) == "string" then
                local playing = tonumber(s.playing) or 0
                local maxPlayers = tonumber(s.maxPlayers) or 0
                local minNeed = config.MinPlayers or 1
                if playing < maxPlayers and playing >= minNeed then
                    if s.id ~= game.JobId and not visitedServers[s.id] then
                        table.insert(valid, { id = s.id, playing = playing })
                    end
                end
            end
        end

        local chosen = pickServer(valid)
        if chosen then
            return chosen, nil
        end

        if type(data.nextPageCursor) == "string" and data.nextPageCursor ~= "" then
            cursor = data.nextPageCursor
        else
            break
        end
        task.wait(0.12)
    end

    return nil, "no unvisited servers"
end

local function recycleVisitedIfStuck()
    local kept = math.max(20, math.floor(countVisited() / 2))
    forgetOldestVisited(kept)
    setStatus("visited list recycled (" .. tostring(countVisited()) .. " kept)")
    updateStats()
end

local function flashMatch()
    task.spawn(function()
        for _ = 1, 3 do
            if not (guiAlive and Main.Parent) then
                return
            end
            TweenService:Create(Main, TweenInfo.new(0.12), { BorderColor3 = Color3.fromRGB(160, 255, 160) }):Play()
            task.wait(0.14)
            TweenService:Create(Main, TweenInfo.new(0.12), { BorderColor3 = WHITE }):Play()
            task.wait(0.14)
        end
    end)
end

local function startSearchSpinner()
    task.spawn(function()
        local frames = { "[ / ] SEARCHING...", "[ - ] SEARCHING...", "[ \\ ] SEARCHING...", "[ | ] SEARCHING..." }
        local idx = 1
        while isHopping and guiAlive do
            SearchBtn.Text = frames[idx]
            idx = (idx % #frames) + 1
            task.wait(0.12)
        end
        if guiAlive then
            updateBtnText()
        end
    end)
end

local executeHop

executeHop = function()
    if isHopping or not guiAlive then
        return
    end
    isHopping = true
    startSearchSpinner()
    setStatus("searching public servers")

    setQueue()

    local targetServer, err = getUnvisitedServer()

    if not guiAlive then
        isHopping = false
        return
    end

    if targetServer then
        visitedServers[targetServer] = os.time()
        visitedServers = pruneVisited(visitedServers)
        saveVisited(visitedServers)
        updateStats()
        setStatus("teleport " .. string.sub(targetServer, 1, 8) .. "..")

        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, targetServer, LocalPlayer)
        end)
        if not ok then
            setStatus("teleport call failed, retrying place")
        end

        task.delay(6, function()
            if isHopping and guiAlive then
                setStatus("teleport timed out, fallback hop")
                pcall(function()
                    TeleportService:Teleport(game.PlaceId, LocalPlayer)
                end)
            end
        end)
    else
        isHopping = false
        updateBtnText()
        if err == "no unvisited servers" then
            recycleVisitedIfStuck()
        else
            setStatus(err or "no server found")
        end
        if config.AutoHop then
            task.delay(2, function()
                if config.AutoHop and guiAlive and not isHopping then
                    executeHop()
                end
            end)
        end
    end
end

TeleportService.TeleportInitFailed:Connect(function(_, result)
    isHopping = false
    if not guiAlive then
        return
    end
    updateBtnText()
    setStatus("teleport failed: " .. tostring(result))
    task.wait(1.5)
    if config.AutoHop and guiAlive then
        executeHop()
    end
end)

local function countDonators()
    local n = 0
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer and pl.MembershipType == Enum.MembershipType.Premium then
            n = n + 1
        end
    end
    return n
end

local function evaluateServer()
    evaluateToken = evaluateToken + 1
    local token = evaluateToken

    if not config.AutoHop then
        return
    end

    chatMessageCount = 0
    local seconds = config.AnalyzeSeconds or 5
    for i = seconds, 1, -1 do
        if not guiAlive or not config.AutoHop or token ~= evaluateToken then
            if guiAlive then
                updateBtnText()
            end
            return
        end
        SearchBtn.Text = string.format("[ ANALYZING (%ds)... ]", i)
        setStatus(string.format("listening chat / scanning players (%ds)", i))
        task.wait(1)
    end

    if not guiAlive or not config.AutoHop or token ~= evaluateToken then
        if guiAlive then
            updateBtnText()
        end
        return
    end

    local donatorCount = countDonators()
    local playerCount = #Players:GetPlayers()
    local passDonators = (not config.FilterDonators) or (donatorCount >= 1)
    local passChat = (not config.FilterChat) or (chatMessageCount >= 1)
    local passPlayers = playerCount >= (config.MinPlayers or 1)

    if passDonators and passChat and passPlayers then
        SearchBtn.Text = "[ MATCH FOUND ]"
        setStatus(string.format("match  prem=%d  chat=%d  players=%d", donatorCount, chatMessageCount, playerCount))
        config.AutoHop = false
        saveSettings(config)
        flashMatch()
        task.delay(1.4, function()
            if guiAlive and not config.AutoHop then
                updateBtnText()
            end
        end)
    else
        local reasons = {}
        if not passDonators then
            table.insert(reasons, "no premium")
        end
        if not passChat then
            table.insert(reasons, "silent chat")
        end
        if not passPlayers then
            table.insert(reasons, "few players")
        end
        local why = table.concat(reasons, ", ")
        SearchBtn.Text = "[ NEXT SERVER ]"
        setStatus(string.format("skip (%s)  prem=%d chat=%d pl=%d", why, donatorCount, chatMessageCount, playerCount))
        task.wait(0.45)
        if config.AutoHop and guiAlive and token == evaluateToken then
            executeHop()
        else
            updateBtnText()
        end
    end
end

SearchBtn.MouseButton1Click:Connect(function()
    config.AutoHop = not config.AutoHop
    saveSettings(config)
    updateBtnText()

    if config.AutoHop then
        task.spawn(evaluateServer)
    else
        evaluateToken = evaluateToken + 1
        setStatus("auto-loop stopped")
    end
end)

HopOnceBtn.MouseButton1Click:Connect(function()
    if isHopping then
        setStatus("already hopping")
        return
    end
    task.spawn(executeHop)
end)

Players.PlayerAdded:Connect(scheduleRender)
Players.PlayerRemoving:Connect(scheduleRender)
renderPlayers()

if config.AutoHop then
    task.spawn(evaluateServer)
end
