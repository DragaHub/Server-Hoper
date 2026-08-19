-- Конфигурация через файлы экзекутора
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local CoreGui = game:GetService("CoreGui")

local SETTINGS_FILE = "ServerFinderConfig.json"

local defaultSettings = {
    AutoHop = false,
    FilterDonators = true,
    FilterChat = false
}

-- Функция чтения настроек из файла
local function loadSettings()
    if isfile and isfile(SETTINGS_FILE) then
        local success, result = pcall(function()
            return HttpService:JSONDecode(readfile(SETTINGS_FILE))
        end)
        if success and type(result) == "table" then
            return result
        end
    end
    return defaultSettings
end

-- Функция сохранения настроек в файл
local function saveSettings(cfg)
    if writefile then
        pcall(function()
            writefile(SETTINGS_FILE, HttpService:JSONEncode(cfg))
        end)
    end
end

local config = loadSettings()

-- Защита от дублирования интерфейса
if CoreGui:FindFirstChild("ClassicServerFinder") then
    CoreGui.ClassicServerFinder:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ClassicServerFinder"
ScreenGui.ResetOnSpawn = false

pcall(function() ScreenGui.Parent = CoreGui end)
if not ScreenGui.Parent then ScreenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end

-- Главная панель в строго классическом стиле
local Main = Instance.new("Frame", ScreenGui)
Main.Size = UDim2.new(0, 330, 0, 480)
Main.Position = UDim2.new(0.5, -165, 0.5, -240)
Main.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
Main.BorderSizePixel = 1
Main.BorderColor3 = Color3.fromRGB(255, 255, 255)
Main.Active = true
Main.Draggable = true

local Title = Instance.new("TextLabel", Main)
Title.Size = UDim2.new(1, -35, 0, 30)
Title.Position = UDim2.new(0, 8, 0, 0)
Title.Text = "[ AUTOEXEC SERVER FINDER ]"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.Font = Enum.Font.Code
Title.TextSize = 12
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.BackgroundTransparency = 1

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
CloseBtn.MouseButton1Click:Connect(function()
    config.AutoHop = false
    saveSettings(config)
    ScreenGui:Destroy()
end)

local Line1 = Instance.new("Frame", Main)
Line1.Size = UDim2.new(1, 0, 0, 1)
Line1.Position = UDim2.new(0, 0, 0, 30)
Line1.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
Line1.BorderSizePixel = 0

-- Чекбоксы
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

local function updateBtnText()
    if config.AutoHop then
        SearchBtn.Text = "[ STOP AUTO-LOOP ]"
    else
        SearchBtn.Text = "[ START AUTO-LOOP ]"
    end
end
updateBtnText()

-- Отслеживание сообщений
local chatMessageCount = 0
pcall(function()
    TextChatService.MessageReceived:Connect(function() chatMessageCount = chatMessageCount + 1 end)
end)
for _, pl in ipairs(Players:GetPlayers()) do
    pl.Chatted:Connect(function() chatMessageCount = chatMessageCount + 1 end)
end
Players.PlayerAdded:Connect(function(pl)
    pl.Chatted:Connect(function() chatMessageCount = chatMessageCount + 1 end)
end)

-- Рендер игроков
local function renderPlayers()
    for _, v in ipairs(Scroll:GetChildren()) do
        if v:IsA("Frame") then v:Destroy() end
    end

    for _, pl in ipairs(Players:GetPlayers()) do
        local isDonator = (pl.MembershipType == Enum.MembershipType.Premium)

        local Card = Instance.new("Frame", Scroll)
        Card.Size = UDim2.new(1, -6, 0, 34)
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
    end
    Scroll.CanvasSize = UDim2.new(0, 0, 0, UIList.AbsoluteContentSize.Y + 6)
end

-- Логика перехода
local function executeHop()
    local httpRequest = request or http_request or (syn and syn.request) or (http and http.request)
    if not httpRequest then return end

    local url = string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100", game.PlaceId)
    local success, res = pcall(function() return httpRequest({Url = url, Method = "GET"}) end)

    if success and res and res.Body then
        local data = HttpService:JSONDecode(res.Body)
        if data and data.data then
            local valid = {}
            for _, s in ipairs(data.data) do
                if s.playing < s.maxPlayers and s.id ~= game.JobId then
                    table.insert(valid, s.id)
                end
            end
            if #valid > 0 then
                TeleportService:TeleportToPlaceInstance(game.PlaceId, valid[math.random(1, #valid)], Players.LocalPlayer)
            else
                task.wait(3)
                executeHop()
            end
        end
    else
        task.wait(3)
        executeHop()
    end
end

-- Проверка сервера при заходе
local function evaluateServer()
    if not config.AutoHop then return end

    SearchBtn.Text = "[ ANALYZING (5s)... ]"
    chatMessageCount = 0
    task.wait(5)

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
        task.wait(1)
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
