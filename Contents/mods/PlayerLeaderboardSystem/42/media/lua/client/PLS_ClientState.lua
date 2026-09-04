----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Net"
require "PLS_Boards"
require "PLS_Chat"

PLS = PLS or {}
PLS_ClientState = PLS_ClientState or {}

-- board key -> { rows = { { n = name, s = score } }, total, rank, score }
PLS_ClientState.boards = PLS_ClientState.boards or {}
PLS_ClientState.ready = false
PLS_ClientState.revision = 0
PLS_ClientState.lastToast = nil

local function PLS_touch()
    PLS_ClientState.revision = PLS_ClientState.revision + 1
end

PLS_ClientState.touch = PLS_touch

local handlers = {}

function handlers.board(args)
    if not args or not args.board then return end

    PLS_ClientState.boards[args.board] = {
        rows = args.rows or {},
        total = args.total or 0,
        rank = args.rank,
        score = args.score or 0,
    }

    PLS_ClientState.ready = true
    PLS_touch()
end

function handlers.announce(args)
    PLS_Chat.announce(args)
end

function handlers.toast(args)
    PLS_ClientState.lastToast = args
    PLS_touch()
end

function PLS_ClientState.onCommand(module, command, args)
    if module ~= PLS.MODULE then return end

    local handler = handlers[command]
    if not handler then return end

    local ok, err = pcall(handler, args)
    if not ok then PLS.warn("client command " .. tostring(command) .. " failed: " .. tostring(err)) end
end

function PLS_ClientState.board(key)
    return key and PLS_ClientState.boards[key] or nil
end

function PLS_ClientState.reset(key)
    PLS_Net.toServer("reset", { board = key })
end

-- the handshake gets lost on a multiplayer client: OnCreatePlayer fires before the local
-- player is necessarily assigned. nothing re-sends a board unless somebody scores, so on a
-- quiet server one lost packet leaves the panel on "waiting" for good.
local HELLO_RETRY_MS = 3000
local HELLO_ATTEMPTS = 10

local helloAt = 0
local helloTries = 0

function PLS_ClientState.requestBoards()
    helloAt = getTimestampMs()
    helloTries = helloTries + 1
    PLS_Net.toServer("hello", {})
end

-- puts the retry back on the clock. the refresh button and opening the panel both call it.
function PLS_ClientState.rearm()
    helloAt = 0
    helloTries = 0
end

local function PLS_helloTick()
    if PLS_ClientState.ready then return end
    -- bounded: a server that is never going to answer should not be asked forever. the
    -- refresh button is the way back after this gives up.
    if helloTries >= HELLO_ATTEMPTS then return end

    if getTimestampMs() - helloAt < HELLO_RETRY_MS then return end

    PLS_ClientState.requestBoards()
end

Events.OnServerCommand.Add(PLS_ClientState.onCommand)
PLS.guard("board handshake", Events.EveryOneMinute, PLS_helloTick)

-- OnCreatePlayer, not OnGameStart: the handshake needs a player on both ends.
Events.OnCreatePlayer.Add(function(playerNum)
    if playerNum ~= 0 then return end
    PLS_ClientState.rearm()
    PLS_ClientState.requestBoards()
end)
