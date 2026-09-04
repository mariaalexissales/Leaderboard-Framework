----------
--ESTRAL--
----------

require "LBF_Core"

LBF = LBF or {}
LBF_Net = LBF_Net or {}

function LBF_Net.hasRemoteServer()
    return LBF.hasRemoteServer()
end

-- looked up at call time: shared/ loads before client/ and server/, so neither dispatcher
-- exists yet when this file runs.
local function LBF_serverHandler(command)
    return LBF_Commands and LBF_Commands.handlers and LBF_Commands.handlers[command]
end

local function LBF_clientHandler()
    return LBF_ClientState and LBF_ClientState.onCommand
end

-- with no remote server the send is a direct call into the handler that would have
-- received it, so singleplayer runs the same scoring, ranking and broadcast code the
-- server does.
function LBF_Net.toServer(command, args)
    args = args or {}

    if LBF_Net.hasRemoteServer() then
        sendClientCommand(getPlayer(), LBF.MODULE, command, args)
        return
    end

    local handler = LBF_serverHandler(command)
    if not handler then
        LBF.warn("no server handler for " .. tostring(command))
        return
    end

    local ok, err = pcall(handler, getPlayer(), args)
    if not ok then LBF.warn("server handler " .. tostring(command) .. " failed: " .. tostring(err)) end
end

function LBF_Net.toClient(player, command, args)
    args = args or {}

    if isServer() then
        sendServerCommand(player, LBF.MODULE, command, args)
        return
    end

    local handler = LBF_clientHandler()
    if not handler then return end

    local ok, err = pcall(handler, LBF.MODULE, command, args)
    if not ok then LBF.warn("client handler " .. tostring(command) .. " failed: " .. tostring(err)) end
end

function LBF_Net.toAll(command, args)
    args = args or {}

    if isServer() then
        sendServerCommand(LBF.MODULE, command, args)
        return
    end

    local handler = LBF_clientHandler()
    if not handler then return end

    local ok, err = pcall(handler, LBF.MODULE, command, args)
    if not ok then LBF.warn("client handler " .. tostring(command) .. " failed: " .. tostring(err)) end
end
