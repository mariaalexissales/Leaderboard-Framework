----------
--ESTRAL--
----------

require "LBF_Core"
require "LBF_Net"
require "LBF_Boards"
require "LBF_Chat"

LBF = LBF or {}
LBF_ClientState = LBF_ClientState or {}

-- board key -> { rows = { { n = name, s = score } }, total, rank, score }
LBF_ClientState.boards = LBF_ClientState.boards or {}
LBF_ClientState.ready = false
LBF_ClientState.revision = 0
LBF_ClientState.lastToast = nil

local function LBF_touch()
    LBF_ClientState.revision = LBF_ClientState.revision + 1
end

LBF_ClientState.touch = LBF_touch

local handlers = {}

function handlers.board(args)
    if not args or not args.board then return end

    LBF_ClientState.boards[args.board] = {
        rows = args.rows or {},
        total = args.total or 0,
        rank = args.rank,
        score = args.score or 0,
    }

    LBF_ClientState.ready = true
    LBF_touch()
end

function handlers.announce(args)
    LBF_Chat.announce(args)
end

function handlers.toast(args)
    LBF_ClientState.lastToast = args
    LBF_touch()
end

function LBF_ClientState.onCommand(module, command, args)
    if module ~= LBF.MODULE then return end

    local handler = handlers[command]
    if not handler then return end

    local ok, err = pcall(handler, args)
    if not ok then LBF.warn("client command " .. tostring(command) .. " failed: " .. tostring(err)) end
end

function LBF_ClientState.board(key)
    return key and LBF_ClientState.boards[key] or nil
end

function LBF_ClientState.reset(key)
    LBF_Net.toServer("reset", { board = key })
end

Events.OnServerCommand.Add(LBF_ClientState.onCommand)

-- OnCreatePlayer, not OnGameStart: the handshake needs a player on both ends.
Events.OnCreatePlayer.Add(function(playerNum)
    if playerNum ~= 0 then return end
    LBF_Net.toServer("hello", {})
end)
