----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Net"
require "PLS_Boards"
require "PLS_Chat"

PLS_ClientState = PLS_ClientState or {}

-- board key -> { rows = { { n = name, s = score } }, total, rank, score }
PLS_ClientState.boards = PLS_ClientState.boards or {}
-- board key -> true once that board has arrived at least once. per board, not one flag for
-- all of them: sendAll pushes each board as its own packet, so losing one of two used to
-- leave that tab empty for good behind a flag the other packet had already set.
PLS_ClientState.seen = PLS_ClientState.seen or {}
PLS_ClientState.revision = 0

local function PLS_touch()
    PLS_ClientState.revision = PLS_ClientState.revision + 1
end

local handlers = {}

function handlers.board(args)
    if not args or not args.board then return end

    PLS_ClientState.boards[args.board] = {
        rows = args.rows or {},
        total = args.total or 0,
        rank = args.rank,
        score = args.score or 0,
    }

    PLS_ClientState.seen[args.board] = true
    PLS_touch()
end

function handlers.announce(args)
    PLS_Chat.announce(args)
end

function handlers.toast(args)
    PLS_Chat.toast(args)
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

function PLS_ClientState.isSeen(key)
    return key ~= nil and PLS_ClientState.seen[key] == true
end

-- has the handshake finished: true only once every board the sandbox has switched on has
-- arrived. the panel asks isSeen about one tab instead, because this one sorts.
function PLS_ClientState.isReady()
    local boards = PLS_Boards.ordered()

    -- an empty list this early is SandboxVars not having landed rather than a server with no
    -- boards -- enabled() fails closed until it does -- and calling that ready would retire
    -- the retry before the first reply ever arrived.
    if #boards == 0 then return false end

    for _, def in ipairs(boards) do
        if not PLS_ClientState.seen[def.key] then return false end
    end

    return true
end

function PLS_ClientState.reset(key)
    PLS_Net.toServer("reset", { board = key })
end

-- the handshake gets lost on a multiplayer client: OnCreatePlayer fires before the local
-- player is necessarily assigned. nothing re-sends a board unless somebody scores, so on a
-- quiet server one lost packet leaves the panel on "waiting" for good.
local HELLO_RETRY_MS = 3000
local HELLO_ATTEMPTS = 10

-- opening the panel is a reason to ask again, but the keybind opens it on every peek and the
-- server floors hello at a second, so the ask is paced here rather than sent to be dropped.
-- above the server's floor on purpose: an ask that gets through beats an ask that is on time.
local OPEN_REQUEST_MS = 2000

local helloAt = 0
local helloTries = 0
local openAt = 0

function PLS_ClientState.requestBoards()
    helloAt = getTimestampMs()
    helloTries = helloTries + 1

    -- the server cannot read a remote client's launch flags, so the client says. what it says
    -- gates scoring and nothing else, and PLS_Kills.setDebug is where how far it is trusted is
    -- written down. it rides on hello because the main scoring path, OnZombieDead on the
    -- server, has no packet of its own to ride on.
    PLS_Net.toServer("hello", { debug = getCore():getDebug() == true })
end

-- puts the retry back on the clock. seen goes with it: a refresh the server swallows on its
-- own cooldown gets no reply, and boards left marked as seen would leave nothing to notice
-- that with. the cached rows stay, so only the empty-state string flickers back to waiting.
function PLS_ClientState.rearm()
    helloAt = 0
    helloTries = 0
    PLS_ClientState.seen = {}
end

-- what opening the panel calls. the refresh button does not come through here: an explicit
-- press should always try, and the rearm above is what has it retried if the server drops it.
function PLS_ClientState.requestOnOpen()
    local now = getTimestampMs()
    if now - openAt < OPEN_REQUEST_MS then return end
    openAt = now

    PLS_ClientState.rearm()
    PLS_ClientState.requestBoards()
end

local function PLS_helloTick()
    -- bounded: a server that is never going to answer should not be asked forever. opening
    -- the panel or pressing refresh is the way back after this gives up.
    if helloTries >= HELLO_ATTEMPTS then return end
    -- the two cheap clock compares first, so isReady's sort runs once a retry window rather
    -- than once a tick.
    if getTimestampMs() - helloAt < HELLO_RETRY_MS then return end
    if PLS_ClientState.isReady() then return end

    PLS_ClientState.requestBoards()
end

Events.OnServerCommand.Add(PLS_ClientState.onCommand)

-- game time, so this is roughly every 2.5 real seconds at default day length but once a real
-- minute on a real-time one, which stretches the ten attempts over ten real minutes. left as
-- it is: it only runs at all when a handshake packet was lost, and opening the panel or
-- pressing refresh recovers that in one go on any day length.
PLS.guard("board handshake", Events.EveryOneMinute, PLS_helloTick)

-- OnCreatePlayer, not OnGameStart: the handshake needs a player on both ends.
Events.OnCreatePlayer.Add(function(playerNum)
    if playerNum ~= 0 then return end
    PLS_ClientState.rearm()
    PLS_ClientState.requestBoards()
end)
