-- Chess! Stockfish move overlay - diagnostics v4
-- This message MUST appear as soon as this exact version runs.
print("[Stockfish v4] SCRIPT STARTED - GitHub test.lua is loading")
warn("[Stockfish v4] Startup diagnostics enabled")
-- Replace the API key below with your Railway API_KEY value.
local API_URL = "https://stockfish-api22-production.up.railway.app/api/analyze"
local API_KEY = "4b534n6234243b62436g436246b43624fkm756b32b343b46n3"

local STRENGTH = "high"
local PLAY_AS = "White"
local SCAN_DELAY = 0.1
local RETRY_SECONDS = 6

-- Stop a previous copy of THIS version when reloading.
-- An older version without this hook still requires rejoining the game.
if _G.__ChessStockfishStop then
    pcall(_G.__ChessStockfishStop)
end
local running = true

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local board, piecesFolder
for try = 1, 60 do
    if try == 1 or try % 10 == 0 then
        print("[Stockfish v4] Waiting for workspace.Board / workspace.Pieces, check", try)
    end
    board = workspace:FindFirstChild("Board")
    piecesFolder = workspace:FindFirstChild("Pieces")
    if board and piecesFolder then break end
    task.wait(0.5)
end

if not board or not piecesFolder then
    warn("[Stockfish v4] Board missing:", tostring(not board), "Pieces missing:", tostring(not piecesFolder))
    error("Workspace chess board not found. Expected workspace.Board and workspace.Pieces")
end
print("[Stockfish v4] Found board and pieces folder. Piece models:", #piecesFolder:GetChildren())

local arrows = {}
local arrowFrom, arrowTo
local previous, previousTypes = {}, {}
local whiteToMove = true
local newGameRequested = false
local playAsChanged = false
local requestVersion = 0
local renderConnection
local lastSuccessfulFen = nil
local lastAttemptedFen = nil
local lastAttemptTime = -math.huge

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

-- Compare board contents rather than model identity; a game may replace
-- model instances without changing the position.
local function boardSignature(snapshot, types)
    local entries = {}
    for token, square in pairs(snapshot) do
        entries[#entries + 1] = square .. ":" .. (types[token] or "Unknown")
    end
    table.sort(entries)
    return table.concat(entries, "|")
end

local function samePosition(s1, t1, s2, t2)
    return boardSignature(s1, t1) == boardSignature(s2, t2)
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

_G.__ChessStockfishStop = function()
    running = false
    requestVersion += 1
    if renderConnection then
        pcall(function() renderConnection:Disconnect() end)
    end
    clearArrow()
    print("[Stockfish] Previous overlay stopped.")
end

-- Draw the move arrow using the current camera. No custom WorldToScreen required.
renderConnection = RunService.RenderStepped:Connect(function()
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
        if string.lower(name) == string.lower(tostring(value)) then return i - 1 end
    end
    return 0
end

local function normalizeChoice(options, value)
    if type(value) == "number" then
        return options[value + 1]  -- zero-based choices used by this UI
    end
    for _, option in ipairs(options) do
        if string.lower(option) == string.lower(tostring(value)) then
            return option
        end
    end
    return nil
end

local forceAnalyze = false
if UI and UI.AddTab then
    UI.AddTab("Chess AI", function(tab)
        local settings = tab:Section("Game Settings", "Left")
        settings:Combo("chess_play_as", "Play as", PLAY_OPTIONS,
            optionIndex(PLAY_OPTIONS, PLAY_AS), function(_, value)
                local chosen = normalizeChoice(PLAY_OPTIONS, value)
                if chosen and chosen ~= PLAY_AS then
                    PLAY_AS = chosen
                    playAsChanged = true
                    invalidateRecommendation()
                    print("[Stockfish] Selected side:", PLAY_AS)
                elseif not chosen then
                    warn("[Stockfish] Unrecognized Play as option:", tostring(value))
                end
            end)

        settings:Combo("chess_strength", "Strength", STRENGTH_OPTIONS,
            optionIndex(STRENGTH_OPTIONS, STRENGTH), function(_, value)
                local chosen = normalizeChoice(STRENGTH_OPTIONS, value)
                if chosen then
                    STRENGTH = string.lower(chosen)
                    playAsChanged = true
                    invalidateRecommendation()
                end
            end)

        settings:Button("New Game", function()
            newGameRequested = true
            invalidateRecommendation()
        end)

        settings:Button("Sync Turn to My Color", function()
            if PLAY_AS == "White" or PLAY_AS == "Black" then
                whiteToMove = PLAY_AS == "White"
                playAsChanged = true
                invalidateRecommendation()
                print("[Stockfish] Turn synced to:", PLAY_AS)
            end
        end)

        settings:Button("Analyze Now", function()
            forceAnalyze = true
            invalidateRecommendation()
        end)
        settings:Text("Green arrow = recommended move")
    end)
else
    warn("[Stockfish] UI.AddTab not found; default selected side is " .. PLAY_AS)
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

-- Detect movement from actual occupied squares, even when the game replaces
-- piece models. A capture removes the victim but adds no victim piece, so it
-- cannot be mistaken for a second turn.
local function detectMovedSide(before, beforeTypes, after, afterTypes)
    local oldAt, newAt = {}, {}
    for token, square in pairs(before) do oldAt[square] = beforeTypes[token] end
    for token, square in pairs(after) do newAt[square] = afterTypes[token] end

    local removed = {White = 0, Black = 0}
    local added = {White = 0, Black = 0}
    for square, piece in pairs(oldAt) do
        if newAt[square] ~= piece then
            local color = piece and piece:match("^(%a+) ")
            if removed[color] then removed[color] += 1 end
        end
    end
    for square, piece in pairs(newAt) do
        if oldAt[square] ~= piece then
            local color = piece and piece:match("^(%a+) ")
            if added[color] then added[color] += 1 end
        end
    end

    if removed.White > 0 and added.White > 0
        and added.Black == 0 then return "White" end
    if removed.Black > 0 and added.Black > 0
        and added.White == 0 then return "Black" end
    return nil
end

local function recommend(snapshot, types)
    if not running then return false end
    local fen = makeFen(snapshot, types)
    local expected = whiteToMove and "White" or "Black"
    local body = HttpService:JSONEncode({fen = fen, strength = STRENGTH})
    requestVersion += 1
    local myVersion = requestVersion

    print("[Stockfish] Analyzing", expected, "| selected:", PLAY_AS, "| FEN:", fen)

    local result
    for attempt = 1, 2 do
        if not running or requestVersion ~= myVersion then return false end
        local posted, raw = pcall(function()
            return httppost(API_URL, body, "application/json", {
                ["Content-Type"] = "application/json",
                ["x-api-key"] = API_KEY
            })
        end)
        local response
        if posted and type(raw) == "table" then
            print("[Stockfish] HTTP status:", raw.StatusCode or raw.status or "unknown")
            response = raw.Body or raw.body or HttpService:JSONEncode(raw)
        else
            response = tostring(raw)
        end
        if not running or requestVersion ~= myVersion then return false end

        local decoded, parsed = pcall(function()
            return HttpService:JSONDecode(response)
        end)
        if decoded and type(parsed) == "table" and parsed.bestmove then
            result = parsed
            break
        end
        warn("[Stockfish] Analysis attempt " .. attempt .. " failed: " .. response)
        if attempt < 2 then task.wait(0.35) end
    end

    if not running or requestVersion ~= myVersion then return false end
    if not result then
        warn("[Stockfish] No bestmove returned; Analyze Now retries the same position.")
        return false
    end

    -- Use board content, not unstable instance identity, to reject stale moves.
    local scanOK, live, liveTypes = pcall(scan)
    if not scanOK or not samePosition(snapshot, types, live, liveTypes) then
        warn("[Stockfish] Position changed during analysis; waiting for it to settle.")
        return false
    end

    local uci = tostring(result.bestmove):match("([a-h][1-8][a-h][1-8][qrbn]?)")
    if not uci then
        warn("[Stockfish] Invalid bestmove: " .. tostring(result.bestmove))
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
    if moving:sub(1, #expected) ~= expected then
        warn("[Stockfish] Rejected " .. uci .. " for " .. moving ..
            ", expected " .. expected .. ". Use Sync Turn to My Color if necessary.")
        return false
    end
    setArrow(fromSquare, toSquare)
    print("[Stockfish] Arrow:", fromSquare, "->", toSquare, "(", moving, ")")
    return true
end

print("[Stockfish v4] UI initialized, scan starting. API:", API_URL)
local ok, current, types = pcall(scan)
assert(ok, current)

local lastScanWarning = -math.huge
while running and not usableSnapshot(current, types) do
    if os.clock() - lastScanWarning >= 3 then
        local n, white, black = 0, 0, 0
        for token in pairs(current) do
            n += 1
            if types[token] == "White King" then white += 1 end
            if types[token] == "Black King" then black += 1 end
        end
        warn("[Stockfish v4] SCAN BLOCKED: pieces=" .. n ..
            " whiteKings=" .. white .. " blackKings=" .. black)
        local samples = {}
        for token, square in pairs(current) do
            samples[#samples+1] = tostring(types[token]) .. "@" .. tostring(square)
            if #samples >= 8 then break end
        end
        print("[Stockfish v4] Detected piece examples: " .. table.concat(samples, ", "))
        lastScanWarning = os.clock()
    end
    task.wait(0.5)
    local nextOK, nextSnapshot, nextTypes = pcall(scan)
    if nextOK then current, types = nextSnapshot, nextTypes end
end
if not running then return end

print("[Stockfish v4] Scan passed; both kings detected. Tracking turns.")
previous, previousTypes = current, types
local initialTurn = detectOpeningTurn(current, types)
if initialTurn ~= nil then
    whiteToMove = initialTurn
else
    warn("[Stockfish] Midgame start: turn cannot be inferred from pieces alone.")
    warn("[Stockfish] Select your color and click Sync Turn to My Color.")
end

local function isMyTurn()
    return PLAY_AS == "Any"
        or (PLAY_AS == "White" and whiteToMove)
        or (PLAY_AS == "Black" and not whiteToMove)
end

local function maybeAnalyze(snapshot, snapshotTypes, force)
    if not usableSnapshot(snapshot, snapshotTypes) then return end
    if not isMyTurn() then return end
    local fen = makeFen(snapshot, snapshotTypes)
    if not force and fen == lastSuccessfulFen then return end
    if not force and fen == lastAttemptedFen
        and (os.clock() - lastAttemptTime) < RETRY_SECONDS then return end

    lastAttemptedFen = fen
    lastAttemptTime = os.clock()
    if recommend(snapshot, snapshotTypes) then
        lastSuccessfulFen = fen
    end
end

print("[Stockfish] Detected turn:", whiteToMove and "White" or "Black", "| selected:", PLAY_AS)
if isMyTurn() then
    maybeAnalyze(current, types, true)
else
    print("[Stockfish] Waiting for selected side's turn. Change Play as if necessary.")
end

local candidateSignature = boardSignature(previous, previousTypes)
local candidateSince = os.clock()
while running do
    task.wait(SCAN_DELAY)
    local scanOK, nextSnapshot, nextTypes = pcall(scan)
    if not scanOK then
        warn("[Stockfish] Scanner error:", tostring(nextSnapshot))
        continue
    end

    if newGameRequested then
        newGameRequested = false
        previous, previousTypes = nextSnapshot, nextTypes
        candidateSignature = boardSignature(nextSnapshot, nextTypes)
        candidateSince = os.clock()
        lastSuccessfulFen = nil
        lastAttemptedFen = nil
        local turn = detectOpeningTurn(nextSnapshot, nextTypes)
        if turn ~= nil then whiteToMove = turn end
        invalidateRecommendation()
        print("[Stockfish] New Game; turn:", whiteToMove and "White" or "Black")
        maybeAnalyze(nextSnapshot, nextTypes, true)
        continue
    end

    if playAsChanged then
        playAsChanged = false
        invalidateRecommendation()
        print("[Stockfish] Selection updated; turn:", whiteToMove and "White" or "Black",
            "| playing:", PLAY_AS)
        maybeAnalyze(nextSnapshot, nextTypes, true)
        continue
    end

    if forceAnalyze then
        forceAnalyze = false
        invalidateRecommendation()
        maybeAnalyze(nextSnapshot, nextTypes, true)
        continue
    end

    if not usableSnapshot(nextSnapshot, nextTypes) then
        continue  -- transient animations can remove a model temporarily
    end

    local liveSignature = boardSignature(nextSnapshot, nextTypes)
    if liveSignature ~= candidateSignature then
        candidateSignature = liveSignature
        candidateSince = os.clock()
    end

    if not samePosition(previous, previousTypes, nextSnapshot, nextTypes) then
        -- Allow the position to remain still before treating it as a move.
        if os.clock() - candidateSince < 0.35 then continue end

        local movedSide = detectMovedSide(previous, previousTypes, nextSnapshot, nextTypes)
        if not movedSide then
            -- Don't flip the turn on an uncertain/capture-animation state.
            -- This warning only repeats if an unresolved board change persists.
            if os.clock() - lastScanWarning > 5 then
                warn("[Stockfish] Board changed but moving side is unclear. Use Sync Turn to My Color.")
                lastScanWarning = os.clock()
            end
            continue
        end

        previous, previousTypes = nextSnapshot, nextTypes
        whiteToMove = movedSide == "Black"
        invalidateRecommendation()
        print("[Stockfish] Moved:", movedSide, "| now:", whiteToMove and "White" or "Black")
        maybeAnalyze(nextSnapshot, nextTypes, true)
    else
        -- Retry a failed/stale API request on an unchanged position.
        maybeAnalyze(nextSnapshot, nextTypes, false)
    end
end
