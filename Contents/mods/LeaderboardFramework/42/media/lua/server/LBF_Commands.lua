----------
--ESTRAL--
----------

require "LBF_Core"
require "LBF_Net"
require "LBF_Boards"
require "LBF_State"
require "LBF_Kills"
require "LBF_Ranking"

if not LBF.isAuthority() then return end

LBF = LBF or {}
LBF_Commands = LBF_Commands or {}

LBF_Commands.handlers = {}

function LBF_Commands.handlers.hello(player)
    if not player or not LBF.nameOf(player) then return end
    LBF_Ranking.sendAll(player)
end

function LBF_Commands.handlers.hit(player, args)
    LBF_Kills.onHit(player, args)
end

function LBF_Commands.handlers.death(player, args)
    LBF_Kills.onDeath(player, args)
end

function LBF_Commands.handlers.kills(player, args)
    LBF_Kills.onReported(player, args)
end

function LBF_Commands.handlers.reset(player, args)
    -- the button is only drawn for admins, but the client draws the button.
    if not LBF.isAdmin(player) then
        LBF.warn(tostring(LBF.nameOf(player)) .. " asked to reset a board without permission")
        return
    end

    local board = args and args.board
    if not LBF_Boards.get(board) then return end

    LBF_State.resetBoard(board)
    LBF_Ranking.recompute(board)

    LBF_Net.toClient(player, "toast", { kind = "reset", board = board })
end

local function LBF_onClientCommand(module, command, player, args)
    if module ~= LBF.MODULE then return end

    local handler = LBF_Commands.handlers[command]
    if not handler then return end

    local ok, err = pcall(handler, player, args)
    if not ok then LBF.warn("command " .. tostring(command) .. " failed: " .. tostring(err)) end
end

Events.OnClientCommand.Add(LBF_onClientCommand)
