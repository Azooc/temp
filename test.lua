-- Chess! Stockfish move overlay
-- Replace the API key below with your Railway API_KEY value.
local API_URL = "https://stockfish-api22-production.up.railway.app/api/analyze"
local API_KEY = "4b534n6234243b62436g436246b43624fkm756b32b343b46n3"

local STRENGTH = "high"
local PLAY_AS = "White"
local SCAN_DELAY = 0.1

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local board, piecesFolder
for _ = 1, 60 do
    board = workspace:FindFirstChild("Board")
    piecesFolder = workspace:FindFirstChild("Pieces")
    if board and piecesFolder then break end
    task.wait(0.5)
end

if not board or not piecesFolder then
    error("Workspace chess board not found. Expected workspace.Board and workspace.Pieces")
end

local arrows = {}
local arrowFrom, arrowTo
local previous, previousTypes = {}, {}
local whiteToMove = true
local newGameRequested = false
local playAsChanged = false
local lastSentFen = nil
local requestVersion = 0

local PLAY_OPTIONS = {"White", "Black", "Any"}
local STRENGTH_OPTIONS = {"Low", "Medium", "High"}

local function squareName(file, rank)
    return string.char(96 + file) .. tostring(rank)
end

local function positionToSquare(position)
    local first = board:FindFirstChild("1,1")
    local filePart = board:FindFirstChild("2,1")
    local rankPart = board:FindFirstChild("1,2")
    if not first or not filePart or not rankPart then return nil end

    local fileStep = filePart.Position.X - first.Position.X
    local rankStep = rankPart.Position.Z - first.Position.Z
    if math.abs(fileStep) < 0.01 or math.abs(rankStep) < 0.01 then return nil end

    local file = math.floor((position.X - first.Position.X) / fileStep + 0.5) + 1
    local rank = math.floor((position.Z - first.Position.Z) / rankStep + 0.5) + 1
    if file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end
    return squareName(file, rank)
end

local function pieceType(model)
    local mesh = model:FindFirstChild("Mesh")
    if not mesh then return nil end

    -- Roblox Color3 channels run from 0 to 1, not 0 to 255.
    local side = mesh.Color.R > 0.5 and "White" or "Black"
    local kind = model.Name
    if kind ~= "Pawn" and kind ~= "Knight" and kind ~= "Bishop"
        and kind ~= "Rook" and kind ~= "Queen" and kind ~= "King" then
        return nil
    end
    return side .. " " .. kind
end

local function scan()
    local result, types = {}, {}
    for _, model in ipairs(piecesFolder:GetChildren()) do
        local mesh = model:FindFirstChild("Mesh")
        local square = mesh and positionToSquare(mesh.Position)
        local kind = pieceType(model)
        if square and kind then
            -- Reuse a supplied piece address if available; otherwise use the instance.
            local addressOK, address = pcall(function() return model.Address end)
            local token = (addressOK and address) or model
            result[token] = square
            types[token] = kind
        end
    end
    return result, types
end

local function sameSnapshot(a, b)
    for token, square in pairs(a) do
        if b[token] ~= square then return false end
    end
    for token in pairs(b) do
        if a[token] == nil then return false end
    end
    return true
end

local function usableSnapshot(snapshot, types)
    local count, whiteKing, blackKing = 0, false, false
    for token in pairs(snapshot) do
        count += 1
        if types[token] == "White King" then whiteKing = true end
        if types[token] == "Black King" then blackKing = true end
    end
    return count >= 4 and whiteKing and blackKing
end

local function makeFen(snapshot, types)
    local boardMap = {}
    local codes = {Pawn="p", Knight="n", Bishop="b", Rook="r", Queen="q", King="k"}

    for token, square in pairs(snapshot) do
        local color, kind = types[token]:match("^(%a+) (.+)$")
        local code = codes[kind]
        if code then
            boardMap[square] = color == "White" and string.upper(code) or code
        end
    end

    local rows = {}
    for rank = 8, 1, -1 do
        local row, empty = "", 0
        for file = 1, 8 do
            local code = boardMap[squareName(file, rank)]
            if code then
                if empty > 0 then row, empty = row .. empty, 0 end
                row = row .. code
            else
                empty += 1
            end
        end
        if empty > 0 then row ..= empty end
        rows[#rows + 1] = row
    end

    -- The scanned board supplies piece placement. Move history such as
    -- castling/en-passant is not available from this game's workspace.
    return table.concat(rows, "/") .. " " .. (whiteToMove and "w" or "b") .. " - - 0 1"
end

local function clearArrow()
    for _, arrow in ipairs(arrows) do
        pcall(function() arrow.line:Remove() end)
        pcall(function() arrow.head:Remove() end)
    end
    arrows = {}
    arrowFrom, arrowTo = nil, nil
end

local function invalidateRecommendation()
    -- Prevent an in-flight HTTP response from redrawing a stale arrow.
    requestVersion += 1
    clearArrow()
end

local function setArrow(fromSquare, toSquare)
    clearArrow()
    arrowFrom, arrowTo = fromSquare, toSquare
end

-- Draw the move arrow using the current camera. No custom WorldToScreen required.
RunService.RenderStepped:Connect(function()
    if not arrowFrom or not arrowTo then return end

    for _, arrow in ipairs(arrows) do
        arrow.line:Remove()
        arrow.head:Remove()
    end
    arrows = {}

    local camera = workspace.CurrentCamera
    if not camera then return end

    local function screen(square)
        local file = string.byte(square:sub(1, 1)) - 96
        local rank = tonumber(square:sub(2, 2))
        local part = board:FindFirstChild(tostring(file) .. "," .. tostring(rank))
        if not part then return nil end

        local point, visible = camera:WorldToViewportPoint(part.Position + Vector3.new(0, 1, 0))
        return visible and Vector2.new(point.X, point.Y) or nil
    end

    local fromPoint, toPoint = screen(arrowFrom), screen(arrowTo)
    if not fromPoint or not toPoint then return end

    local dx, dy = toPoint.X - fromPoint.X, toPoint.Y - fromPoint.Y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1 then return end

    local ux, uy = dx / length, dy / length
    local px, py = -uy, ux

    local line = Drawing.new("Line")
    line.From = fromPoint
    line.To = Vector2.new(toPoint.X - ux * 8, toPoint.Y - uy * 8)
    line.Color = Color3.fromRGB(40, 220, 80)
    line.Thickness = 4
    line.Visible = true

    local head = Drawing.new("Triangle")
    head.PointA = toPoint
    head.PointB = Vector2.new(toPoint.X - ux * 18 + px * 9, toPoint.Y - uy * 18 + py * 9)
    head.PointC = Vector2.new(toPoint.X - ux * 18 - px * 9, toPoint.Y - uy * 18 - py * 9)
    head.Color = Color3.fromRGB(40, 220, 80)
    head.Filled = true
    head.Visible = true

    arrows[1] = {line = line, head = head}
end)

local function optionIndex(options, value)
    for i, name in ipairs(options) do
        if string.lower(name) == string.lower(value) then return i - 1 end
    end
    return 0
end

if UI and UI.AddTab then
    UI.AddTab("Chess AI", function(tab)
        local settings = tab:Section("Game Settings", "Left")

        settings:Combo("chess_play_as", "Play as", PLAY_OPTIONS,
            optionIndex(PLAY_OPTIONS, PLAY_AS), function(_, value)
                if value and value ~= PLAY_AS then
                    PLAY_AS = value
                    playAsChanged = true
                    invalidateRecommendation()
                end
            end)

        settings:Combo("chess_strength", "Strength", STRENGTH_OPTIONS,
            optionIndex(STRENGTH_OPTIONS, STRENGTH), function(_, value)
                if value then
                    STRENGTH = string.lower(value)
                    playAsChanged = true
                    invalidateRecommendation()
                end
            end)

        settings:Button("New Game", function()
            newGameRequested = true
            invalidateRecommendation()
        end)

        -- Useful when starting midway through a match; the board alone
        -- cannot reveal whose turn it is after both sides have moved.
        settings:Button("Sync Turn to My Color", function()
            if PLAY_AS == "White" or PLAY_AS == "Black" then
                whiteToMove = PLAY_AS == "White"
                playAsChanged = true
                invalidateRecommendation()
            end
        end)

        settings:Text("Green arrow = recommended move")
    end)
end

-- Detect a fresh board, or a board immediately after the opening move.
local function detectOpeningTurn(snapshot, types)
    local occupied = {}
    for token, square in pairs(snapshot) do
        occupied[square] = types[token]
    end

    local backRank = {"Rook", "Knight", "Bishop", "Queen", "King", "Bishop", "Knight", "Rook"}
    local whiteMoved, blackMoved = false, false

    for i = 1, 8 do
        local file = string.char(96 + i)
        if occupied[file .. "1"] ~= "White " .. backRank[i]
            or occupied[file .. "2"] ~= "White Pawn" then
            whiteMoved = true
        end
        if occupied[file .. "8"] ~= "Black " .. backRank[i]
            or occupied[file .. "7"] ~= "Black Pawn" then
            blackMoved = true
        end
    end

    if not whiteMoved and not blackMoved then return true end
    if whiteMoved and not blackMoved then return false end
    if blackMoved and not whiteMoved then return true end
    return nil
end

-- Identify the color of the actual moved piece rather than blindly
-- toggling on every change. This avoids capture-removal false turns.
local function detectMovedSide(before, beforeTypes, after, afterTypes)
    local mover

    for token, newSquare in pairs(after) do
        local oldSquare = before[token]
        if oldSquare and oldSquare ~= newSquare then
            local kind = afterTypes[token] or beforeTypes[token]
            local color = kind and kind:match("^(%a+) ")
            if color == "White" or color == "Black" then
                if mover and mover ~= color then return nil end
                mover = color
            end
        end
    end

    if mover then return mover end

    -- Fallback for games that replace the moving model instead of moving it.
    local added, removed = {White = 0, Black = 0}, {White = 0, Black = 0}
    for token in pairs(after) do
        if before[token] == nil then
            local kind = afterTypes[token]
            local color = kind and kind:match("^(%a+) ")
            if added[color] then added[color] += 1 end
        end
    end
    for token in pairs(before) do
        if after[token] == nil then
            local kind = beforeTypes[token]
            local color = kind and kind:match("^(%a+) ")
            if removed[color] then removed[color] += 1 end
        end
    end

    if added.White > 0 and removed.White > 0 and added.Black == 0 then return "White" end
    if added.Black > 0 and removed.Black > 0 and added.White == 0 then return "Black" end
    return nil
end

local function recommend(snapshot, types)
    local fen = makeFen(snapshot, types)
    local body = HttpService:JSONEncode({fen = fen, strength = STRENGTH})
    requestVersion += 1
    local myVersion = requestVersion
    local result

    for _ = 1, 2 do
        if requestVersion ~= myVersion then return false end

        local posted, raw = pcall(function()
            return httppost(API_URL, body, "application/json", {
                ["Content-Type"] = "application/json",
                ["x-api-key"] = API_KEY
            })
        end)

        local response
        if posted and type(raw) == "table" then
            response = raw.Body or raw.body or HttpService:JSONEncode(raw)
        else
            response = tostring(raw)
        end

        if requestVersion ~= myVersion then return false end

        local decoded, parsed = pcall(function()
            return HttpService:JSONDecode(response)
        end)

        if decoded and type(parsed) == "table" and parsed.bestmove then
            result = parsed
            break
        end

        warn("[Stockfish] API request failed: " .. response)
        task.wait(0.35)
    end

    if requestVersion ~= myVersion then return false end
    if not result then
        warn("[Stockfish] Failed to get a move.")
        return false
    end

    -- A move may have occurred while the HTTP request was running.
    local scanOk, live = pcall(scan)
    if not scanOk or not sameSnapshot(snapshot, live) then
        warn("[Stockfish] Board changed during analysis; ignoring stale move.")
        return false
    end

    local uci = tostring(result.bestmove):match("([a-h][1-8][a-h][1-8][qrbn]?)")
    if not uci then
        warn("[Stockfish] Invalid move: " .. tostring(result.bestmove))
        return false
    end

    local fromSquare, toSquare = uci:sub(1, 2), uci:sub(3, 4)
    local moving = "Unknown piece"
    for token, square in pairs(snapshot) do
        if square == fromSquare then
            moving = types[token] or moving
            break
        end
    end

    -- If the service recommends a piece of the wrong color, don't draw it.
    local expected = whiteToMove and "White" or "Black"
    if moving:sub(1, #expected) ~= expected then
        warn("[Stockfish] Ignored move for " .. moving .. "; expected " .. expected)
        return false
    end

    setArrow(fromSquare, toSquare)
    print("[Stockfish] " .. expected .. " move " .. fromSquare .. " -> " .. toSquare)
    return true
end

local ok, current, types = pcall(scan)
assert(ok, current)

while not usableSnapshot(current, types) do
    task.wait(0.5)
    local retryOk, retryCurrent, retryTypes = pcall(scan)
    if retryOk then
        current, types = retryCurrent, retryTypes
    end
end

previous, previousTypes = current, types
local initialTurn = detectOpeningTurn(current, types)
if initialTurn ~= nil then
    whiteToMove = initialTurn
else
    warn("[Stockfish] Started in the middle of a game; use Sync Turn to My Color if needed.")
end

local function isMyTurn()
    return PLAY_AS == "Any"
        or (PLAY_AS == "White" and whiteToMove)
        or (PLAY_AS == "Black" and not whiteToMove)
end

if isMyTurn() then recommend(current, types) end

while true do
    task.wait(SCAN_DELAY)

    local success, nextSnapshot, nextTypes = pcall(scan)
    if not success then continue end

    if newGameRequested then
        previous, previousTypes = nextSnapshot, nextTypes
        lastSentFen = nil
        whiteToMove = detectOpeningTurn(nextSnapshot, nextTypes)
        if whiteToMove == nil then whiteToMove = true end
        newGameRequested = false
        invalidateRecommendation()
        if usableSnapshot(nextSnapshot, nextTypes) and isMyTurn() then
            recommend(nextSnapshot, nextTypes)
        end
        continue
    end

    if playAsChanged then
        playAsChanged = false
        invalidateRecommendation()
        if usableSnapshot(nextSnapshot, nextTypes) and isMyTurn() then
            recommend(nextSnapshot, nextTypes)
        end
        continue
    end

    if not usableSnapshot(nextSnapshot, nextTypes) then
        invalidateRecommendation()
        continue
    end

    if not sameSnapshot(previous, nextSnapshot) then
        invalidateRecommendation()

        -- Wait for animations, captures, and piece placement to settle.
        task.wait(0.1)
        local stable, confirmed = pcall(scan)
        if not stable or not sameSnapshot(nextSnapshot, confirmed) then continue end

        task.wait(0.1)
        local stableAgain, settled, settledTypes = pcall(scan)
        if not stableAgain or not sameSnapshot(confirmed, settled) then continue end

        local movedSide = detectMovedSide(previous, previousTypes, settled, settledTypes)
        if not movedSide then
            -- A piece may have been removed before the moving piece changed square.
            -- Don't advance turns until a real move is detected.
            continue
        end

        previous, previousTypes = settled, settledTypes
        whiteToMove = movedSide == "Black"

        local settledFen = makeFen(settled, settledTypes)
        if settledFen ~= lastSentFen then
            lastSentFen = settledFen
            if isMyTurn() then
                recommend(settled, settledTypes)
            end
        end
    end
end
