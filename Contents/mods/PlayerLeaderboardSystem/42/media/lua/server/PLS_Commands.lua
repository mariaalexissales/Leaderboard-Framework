----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Net"
require "PLS_Boards"
require "PLS_State"
require "PLS_Kills"
require "PLS_Ranking"

if not PLS.isAuthority() then return end

PLS_Commands = PLS_Commands or {}

PLS_Commands.handlers = {}

-- hello rebuilds every board, and it is on a button now, so it is worth a floor.
local HELLO_COOLDOWN_MS = 1000

-- neither lastHello nor the debug table has a disconnect event to be cleared by -- b42 has
-- no server-side one -- so they are swept against the online list instead. hello is where
-- new names appear, so it is where the sweep belongs, and this floor keeps a room full of
-- refresh buttons from walking the player list.
local SWEEP_COOLDOWN_MS = 60000

local lastHello = {}
local lastSweep = 0

local function PLS_sweep(now)
    -- one player leaks nothing, and getOnlinePlayers is a server call.
    if not isServer() then return end
    if now - lastSweep < SWEEP_COOLDOWN_MS then return end
    lastSweep = now

    local players = getOnlinePlayers()
    if not players then return end

    local online = {}
    for i = 0, players:size() - 1 do
        local name = PLS.nameOf(players:get(i))
        if name then online[name] = true end
    end

    for name in pairs(lastHello) do
        if not online[name] then lastHello[name] = nil end
    end

    PLS_Kills.forgetOffline(online)
end

function PLS_Commands.handlers.hello(player, args)
    local name = player and PLS.nameOf(player)
    if not name then return end

    local now = getTimestampMs()

    -- swept before this call writes its own name, so a player the online list has not caught
    -- up with cannot be forgotten by their own hello.
    PLS_sweep(now)

    -- recorded above the floor below, so a client that refreshes twice inside a second still
    -- has its second packet's word for what mode it is in, even though that packet is not
    -- worth a set of boards back.
    PLS_Kills.setDebug(name, args and args.debug)

    if now - (lastHello[name] or 0) < HELLO_COOLDOWN_MS then return end
    lastHello[name] = now

    PLS_Ranking.sendAll(player)
end

function PLS_Commands.handlers.hit(player, args)
    PLS_Kills.onHit(player, args)
end

function PLS_Commands.handlers.death(player, args)
    PLS_Kills.onDeath(player, args)
end

function PLS_Commands.handlers.kills(player, args)
    PLS_Kills.onReported(player, args)
end

function PLS_Commands.handlers.reset(player, args)
    -- the button is only drawn for admins, but the client draws the button.
    if not PLS.isAdmin(player) then
        PLS.warn(tostring(PLS.nameOf(player)) .. " asked to reset a board without permission")
        return
    end

    local board = args and args.board
    if not PLS_Boards.get(board) then return end

    PLS_State.resetBoard(board)
    PLS_Ranking.recompute(board)

    PLS_Net.toClient(player, "toast", { kind = "reset", board = board })
end

local function PLS_onClientCommand(module, command, player, args)
    if module ~= PLS.MODULE then return end

    local handler = PLS_Commands.handlers[command]
    if not handler then return end

    local ok, err = pcall(handler, player, args)
    if not ok then PLS.warn("command " .. tostring(command) .. " failed: " .. tostring(err)) end
end

Events.OnClientCommand.Add(PLS_onClientCommand)
