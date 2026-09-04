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

PLS = PLS or {}
PLS_Commands = PLS_Commands or {}

PLS_Commands.handlers = {}

function PLS_Commands.handlers.hello(player)
    if not player or not PLS.nameOf(player) then return end
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
