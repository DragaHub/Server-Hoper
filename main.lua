local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")

local RAW_URL = "https://raw.githubusercontent.com/DragaHub/Server-Hoper/main/main.lua"
local SETTINGS_FILE = "ServerFinderConfig.json"
local VISITED_FILE = "ServerFinderVisited.json"

local isHopping = false

local function setQueue()
    local q = queue_on_teleport or (getgenv and getgenv().queue_on_teleport)
    if q then
        pcall(function()
            q(string.format([[
                repeat task.wait() until game:IsLoaded()
                loadstring(game:HttpGet("%s"))()
            ]], RAW_URL))
        end)
    end
end

-- Черный список посещенных серверов
local function loadVisited()
    if isfile and isfile(VISITED_FILE) then
        local success, result = pcall(function()
            return HttpService:JSONDecode(readfile(VISITED_FILE))
        end)
        if success and type(result) == "table" then return result end
    end
    return {}
end

local function saveVisited(data)
    if writefile then
        pcall(function() writefile(VISITED_FILE, HttpService:JSONEncode(data)) end)
    end
end

local visitedServers = loadVisited()
visitedServers[game.JobId] = true

local visitedCount = 0
for _ in pairs(visitedServers) do visitedCount = visitedCount + 1 end
if visitedCount > 150 then visitedServers = {[game.JobId] = true} end
saveVisited(visitedServers)

-- Настройки
local defaultSettings = { AutoHop = false, FilterDonators = true, FilterChat = false }

local function loadSettings()
    if isfile and isfile(SETTINGS_FILE) then
        local success, result = pcall(function()
            return HttpService:JSONDecode(readfile(SETTINGS_FILE))
        end)
        if success and type(result) == "table" then return result end
    end
    return defaultSettings
end

local function saveSettings(cfg)
    if writefile then pcall(function() writefile(SETTINGS_FILE, HttpService:JSONEncode(cfg)) end) end
end

local config = loadSettings()

if CoreGui:FindFirstChild("ClassicServerFinder") then
    CoreGui.ClassicServerFinder:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ClassicServerFinder"
ScreenGui.ResetOnSpawn = false

pcall(function() ScreenGui.Parent = CoreGui end)
if not ScreenGui.Parent then ScreenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end

-- Анимация кнопок (Hover + Click Recoil)
local function setupRetroButton(button)
    local origSize = button.Size

    button.MouseEnter:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.12), {
            BackgroundColor3 = Color3.fromRGB(255, 255, 255),
            TextColor3 = Color3.fromRGB(0, 0, 0)
        }):Play()
    end)

    button.MouseLeave:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.12), {
            BackgroundColor3 = Color3.fromRGB(0, 0, 0),
            TextColor3 = Color3.fromRGB(255, 255, 255)
        }):Play()
    end)

    button.MouseButton1Down:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.05), {
            Size = UDim2.new(origSize.X.Scale, origSize.X.Offset - 4, origSize.Y.Scale, origSize.Y.Offset - 2)
        }):Play()
    end)

    button.MouseButton1Up:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.08, Enum.EasingStyle.Back), {
            Size = origSize
        }):Play()
    end)
end

-- Главное окно
local Main = Instance.new("Frame", ScreenGui)
Main.Size = UDim2.new(0, 330, 0, 480)
Main.Position = UDim2.new(0.5, -165, 0.5, -240)
Main.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
Main.BorderSizePixel = 1
Main.BorderColor3 = Color3.fromRGB(255, 255, 255)
Main.Active = true
Main.Draggable = true
Main.ClipsDescendants = true

-- Плавное появление интерфейса
Main.BackgroundTransparency = 1
TweenService:Create(Main, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
    BackgroundTransparency = 0
}):Play()

-- Пульсация рамки
task.spawn(function()
    while Main and Main.Parent do
        TweenService:Create(Main, TweenInfo.new(1.2, Enum.EasingStyle.Sine), { BorderColor3 = Color3.fromRGB(120, 120, 120) }):Play()
        task.wait(1.2)
        TweenService:Create(Main, TweenInfo.new(1.2, Enum.EasingStyle.Sine), { BorderColor3 = Color3.fromRGB(255, 255, 255) }):Play()
        task.wait(1.2)
    end
end)

local Title = Instance.new("TextLabel", Main)
Title.Size = UDim2.new(1, -70, 0, 30)
Title.Position = UDim2.new(0, 8, 0, 0)
Title.Text = "[ SERVER FINDER ]"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.Font = Enum.Font.Code
Title.TextSize = 12
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.BackgroundTransparency = 1

-- Кнопка INFO [?]
local InfoBtn = Instance.new("TextButton", Main)
InfoBtn.Size = UDim2.new(0, 22, 0, 20)
InfoBtn.Position = UDim2.new(1, -50, 0, 5)
InfoBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
InfoBtn.BorderSizePixel = 1
InfoBtn.BorderColor3 = Color3.fromRGB(255, 255, 255)
InfoBtn.Text = "?"
InfoBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
InfoBtn.Font = Enum.Font.Code
InfoBtn.TextSize = 12
setupRetroButton(InfoBtn)

-- Кнопка CLOSE [X]
local CloseBtn = Instance.new("TextButton", Main)
CloseBtn.Size = UDim2.new(0, 20, 0, 20)
CloseBtn.Position = UDim2.new(1, -25, 0, 5)
CloseBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
CloseBtn.BorderSizePixel = 1
CloseBtn.BorderColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.Text = "X"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.Font = Enum.Font.Code
CloseBtn.TextSize = 12
setupRetroButton(CloseBtn)

CloseBtn.MouseButton1Click:Connect(function()
    config.AutoHop = false
    saveSettings(config)
    ScreenGui:Destroy()
end)

-- Встроенное модальное окно INFO (Оверлей поверх Main)
local InfoOverlay = Instance.new("Frame", Main)
InfoOverlay.Name = "InfoOverlay"
InfoOverlay.Size = UDim2.new(1, 0, 1, 0)
InfoOverlay.Position = UDim2.new(0, 0, 0, 0)
InfoOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
InfoOverlay.BorderSizePixel = 1
InfoOverlay.BorderColor3 = Color3.fromRGB(255, 255, 255)
InfoOverlay.Visible = false
InfoOverlay.ZIndex = 10

local InfoTitle = Instance.new("TextLabel", InfoOverlay)
InfoTitle.Size = UDim2.new(1, -35, 0, 30)
InfoTitle.Position = UDim2.new(0, 8, 0, 0)
InfoTitle.Text = "[ DOCUMENTATION & INFO ]"
InfoTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
InfoTitle.Font = Enum.Font.Code
InfoTitle.TextSize = 11
InfoTitle.TextXAlignment = Enum.TextXAlignment.Left
InfoTitle.BackgroundTransparency = 1
InfoTitle.ZIndex = 11

local InfoClose = Instance.new("TextButton", InfoOverlay)
InfoClose.Size = UDim2.new(0, 20, 0, 20)
InfoClose.Position = UDim2.new(1, -25, 0, 5)
InfoClose.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
InfoClose.BorderSizePixel = 1
InfoClose.BorderColor3 = Color3.fromRGB(255, 255, 255)
InfoClose.Text = "X"
InfoClose.TextColor3 = Color3.fromRGB(255, 255, 255)
InfoClose.Font = Enum.Font.Code
InfoClose.TextSize = 12
InfoClose.ZIndex = 11
setupRetroButton(InfoClose)

local InfoScroll = Instance.new("ScrollingFrame", InfoOverlay)
InfoScroll.Size = UDim2.new(1, -16, 1, -40)
InfoScroll.Position = UDim2.new(0, 8, 0, 35)
InfoScroll.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
InfoScroll.BorderSizePixel = 1
InfoScroll.BorderColor3 = Color3.fromRGB(255, 255, 255)
InfoScroll.ScrollBarThickness = 4
InfoScroll.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
InfoScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
InfoScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
InfoScroll.ZIndex = 11

local InfoTextLabel = Instance.new("TextLabel", InfoScroll)
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
InfoTextLabel.ZIndex = 12
InfoTextLabel.Text = [[
> SCRIPT FUNCTIONALITY:

1. AUTO-HOP LOOP
   Uses queue_on_teleport to re-execute script instantly when joining new servers.

2. DONATORS FILTER
   Scans all server members to detect Roblox Premium / Donator status.

3. ACTIVE CHAT FILTER
   Analyzes live chat messages for 5 seconds after join to ensure active conversation.

4. ANTI-REPEAT SYSTEM
   Tracks up to 150 unique JobIds in 'ServerFinderVisited.json' to prevent server loops.

5. API PAGINATION
   Scans deep into Roblox server list (up to 500 servers) to find unvisited instances.

Developed for ScriptBlox.]]

InfoBtn.MouseButton1Click:Connect(function()
    InfoOverlay.Visible = not InfoOverlay.Visible
end)

InfoClose.MouseButton1Click:Connect(function()
    InfoOverlay.Visible = false
end)

local Line1 = Instance.new("Frame", Main)
Line1.Size = UDim2.new(1, 0, 0, 1)
Line1.Position = UDim2.new(0, 0, 0, 30)
Line1.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
Line1.BorderSizePixel = 0

local function createToggle(text, pos, key)
    local Btn = Instance.new("TextButton", Main)
    Btn.Size = UDim2.new(0.46, 0, 0, 26)
    Btn.Position = pos
    Btn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    Btn.BorderSizePixel = 1
    Btn.BorderColor3 = Color3.fromRGB(255, 255, 255)
    Btn.Font = Enum.Font.Code
    Btn.TextSize = 10
    Btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    setupRetroButton(Btn)

    local function updateText()
        Btn.Text = (config[key] and "[X] " or "[ ] ") .. text
    end
    updateText()

    Btn.MouseButton1Click:Connect(function()
        config[key] = not config[key]
        saveSettings(config)
        updateText()
    end)
end

createToggle("DONATORS", UDim2.new(0, 8, 0, 38), "FilterDonators")
createToggle("ACTIVE CHAT", UDim2.new(0.52, 0, 0, 38), "FilterChat")

local Scroll = Instance.new("ScrollingFrame", Main)
Scroll.Size = UDim2.new(1, -16, 1, -125)
Scroll.Position = UDim2.new(0, 8, 0, 72)
Scroll.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
Scroll.BorderSizePixel = 1
Scroll.BorderColor3 = Color3.fromRGB(255, 255, 255)
Scroll.ScrollBarThickness = 4
Scroll.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)

local UIList = Instance.new("UIListLayout", Scroll)
UIList.Padding = UDim.new(0, 4)

local SearchBtn = Instance.new("TextButton", Main)
SearchBtn.Size = UDim2.new(1, -16, 0, 32)
SearchBtn.Position = UDim2.new(0, 8, 1, -40)
SearchBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
SearchBtn.BorderSizePixel = 1
SearchBtn.BorderColor3 = Color3.fromRGB(255, 255, 255)
SearchBtn.Font = Enum.Font.Code
SearchBtn.TextSize = 11
SearchBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
setupRetroButton(SearchBtn)

local function updateBtnText()
    if config.AutoHop then
        SearchBtn.Text = "[ STOP AUTO-LOOP ]"
    else
        SearchBtn.Text = "[ START AUTO-LOOP ]"
    end
end
updateBtnText()

local chatMessageCount = 0

pcall(function()
    TextChatService.MessageReceived:Connect(function(msg)
        if msg and msg.TextSource then
            chatMessageCount = chatMessageCount + 1
        end
    end)
end)

local function trackPlayer(pl)
    pl.Chatted:Connect(function()
        chatMessageCount = chatMessageCount + 1
    end)
end

for _, pl in ipairs(Players:GetPlayers()) do trackPlayer(pl) end
Players.PlayerAdded:Connect(trackPlayer)

local function renderPlayers()
    for _, v in ipairs(Scroll:GetChildren()) do
        if v:IsA("Frame") then v:Destroy() end
    end

    local playersList = Players:GetPlayers()
    for index, pl in ipairs(playersList) do
        local isDonator = (pl.MembershipType == Enum.MembershipType.Premium)

        local Card = Instance.new("Frame", Scroll)
        Card.Size = UDim2.new(1, -6, 0, 34)
        Card.Position = UDim2.new(-1, 0, 0, 0)
        Card.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        Card.BorderSizePixel = 1
        Card.BorderColor3 = Color3.fromRGB(255, 255, 255)

        local Avatar = Instance.new("ImageLabel", Card)
        Avatar.Size = UDim2.new(0, 26, 0, 26)
        Avatar.Position = UDim2.new(0, 4, 0.5, -13)
        Avatar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        Avatar.BorderSizePixel = 1
        Avatar.BorderColor3 = Color3.fromRGB(255, 255, 255)

        task.spawn(function()
            local content, isReady = Players:GetUserThumbnailAsync(pl.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
            if isReady then Avatar.Image = content end
        end)

        local Info = Instance.new("TextLabel", Card)
        Info.Size = UDim2.new(1, -38, 1, 0)
        Info.Position = UDim2.new(0, 36, 0, 0)
        Info.Text = pl.Name .. (isDonator and " [PREMIUM]" or "")
        Info.TextColor3 = Color3.fromRGB(255, 255, 255)
        Info.Font = Enum.Font.Code
        Info.TextSize = 10
        Info.TextXAlignment = Enum.TextXAlignment.Left
        Info.BackgroundTransparency = 1

        task.delay(index * 0.03, function()
            if Card and Card.Parent then
                TweenService:Create(Card, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                    Position = UDim2.new(0, 0, 0, 0)
                }):Play()
            end
        end)
    end
    Scroll.CanvasSize = UDim2.new(0, 0, 0, #playersList * 38)
end

local function getUnvisitedServer()
    local httpRequest = request or http_request or (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request)
    if not httpRequest then return nil end

    local sortOrders = {"Asc", "Desc"}
    local selectedSort = sortOrders[math.random(1, #sortOrders)]
    local cursor = ""
    local attempts = 0

    while attempts < 5 do
        attempts = attempts + 1
        local url = string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=%s&limit=100%s",
            game.PlaceId,
            selectedSort,
            cursor ~= "" and ("&cursor=" .. cursor) or ""
        )

        local success, res = pcall(function() return httpRequest({Url = url, Method = "GET"}) end)
        if success and res and res.Body then
            local decSuccess, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
            if decSuccess and data and data.data then
                local valid = {}
                for _, s in ipairs(data.data) do
                    if type(s) == "table" and s.playing and s.maxPlayers and s.playing < s.maxPlayers then
                        if s.id ~= game.JobId and not visitedServers[s.id] then
                            table.insert(valid, s.id)
                        end
                    end
                end

                if #valid > 0 then
                    return valid[math.random(1, #valid)]
                end

                if data.nextPageCursor and data.nextPageCursor ~= "" then
                    cursor = data.nextPageCursor
                else
                    break
                end
            else
                break
            end
        else
            break
        end
        task.wait(0.1)
    end
    return nil
end

local function executeHop()
    if isHopping then return end
    isHopping = true

    task.spawn(function()
        local frames = {"[ / ] SEARCHING...", "[ - ] SEARCHING...", "[ \\ ] SEARCHING...", "[ | ] SEARCHING..."}
        local idx = 1
        while isHopping do
            SearchBtn.Text = frames[idx]
            idx = (idx % #frames) + 1
            task.wait(0.12)
        end
    end)

    setQueue()

    local targetServer = getUnvisitedServer()

    if targetServer then
        visitedServers[targetServer] = true
        saveVisited(visitedServers)

        pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, targetServer, Players.LocalPlayer)
        end)

        task.delay(5, function()
            if isHopping then
                pcall(function() TeleportService:Teleport(game.PlaceId, Players.LocalPlayer) end)
            end
        end)
    else
        visitedServers = {[game.JobId] = true}
        saveVisited(visitedServers)
        pcall(function() TeleportService:Teleport(game.PlaceId, Players.LocalPlayer) end)
    end
end

TeleportService.TeleportInitFailed:Connect(function()
    isHopping = false
    task.wait(1.5)
    if config.AutoHop then
        executeHop()
    end
end)

local function evaluateServer()
    if not config.AutoHop then return end

    chatMessageCount = 0
    for i = 5, 1, -1 do
        if not config.AutoHop then updateBtnText() return end
        SearchBtn.Text = string.format("[ ANALYZING (%ds)... ]", i)
        task.wait(1)
    end

    if not config.AutoHop then
        updateBtnText()
        return
    end

    local donatorCount = 0
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= Players.LocalPlayer and pl.MembershipType == Enum.MembershipType.Premium then
            donatorCount = donatorCount + 1
        end
    end

    local passDonators = not config.FilterDonators or (donatorCount >= 1)
    local passChat = not config.FilterChat or (chatMessageCount >= 1)

    if passDonators and passChat then
        SearchBtn.Text = "[ MATCH FOUND! STOPPED ]"
        config.AutoHop = false
        saveSettings(config)
    else
        SearchBtn.Text = "[ NOT MATCHED. NEXT... ]"
        task.wait(0.4)
        executeHop()
    end
end

SearchBtn.MouseButton1Click:Connect(function()
    config.AutoHop = not config.AutoHop
    saveSettings(config)
    updateBtnText()

    if config.AutoHop then
        task.spawn(evaluateServer)
    end
end)

Players.PlayerAdded:Connect(renderPlayers)
Players.PlayerRemoving:Connect(renderPlayers)
renderPlayers()

if config.AutoHop then
    task.spawn(evaluateServer)
end
