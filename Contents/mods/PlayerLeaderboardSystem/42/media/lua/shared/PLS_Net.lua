----------
--ESTRAL--
----------

require "PLS_Core"

PLS = PLS or {}
PLS_Net = PLS_Net or {}

function PLS_Net.hasRemoteServer()
    return PLS.hasRemoteServer()
end

-- looked up at call time: shared/ loads before client/ and server/, so neither dispatcher
-- exists yet when this file runs.
local function PLS_serverHandler(command)
    return PLS_Commands and PLS_Commands.handlers and PLS_Commands.handlers[command]
end

local function PLS_clientHandler()
    return PLS_ClientState and PLS_ClientState.onCommand
end

-- with no remote server the send is a direct call into the handler that would have
-- received it, so singleplayer runs the same scoring, ranking and broadcast code the
-- server does.
function PLS_Net.toServer(command, args)
    args = args or {}

    if PLS_Net.hasRemoteServer() then
        -- nil this early on a multiplayer client, and handing nil to sendClientCommand
        -- loses the packet without a word. say so, and let the caller retry.
        local player = getPlayer()
        if not player then
            PLS.warn("no local player yet, dropped " .. tostring(command))
            return
        end

        sendClientCommand(player, PLS.MODULE, command, args)
        return
    end

    local handler = PLS_serverHandler(command)
    if not handler then
        PLS.warn("no server handler for " .. tostring(command))
        return
    end

    local ok, err = pcall(handler, getPlayer(), args)
    if not ok then PLS.warn("server handler " .. tostring(command) .. " failed: " .. tostring(err)) end
end

function PLS_Net.toClient(player, command, args)
    args = args or {}

    if isServer() then
        sendServerCommand(player, PLS.MODULE, command, args)
        return
    end

    local handler = PLS_clientHandler()
    if not handler then return end

    local ok, err = pcall(handler, PLS.MODULE, command, args)
    if not ok then PLS.warn("client handler " .. tostring(command) .. " failed: " .. tostring(err)) end
end

function PLS_Net.toAll(command, args)
    args = args or {}

    if isServer() then
        sendServerCommand(PLS.MODULE, command, args)
        return
    end

    local handler = PLS_clientHandler()
    if not handler then return end

    local ok, err = pcall(handler, PLS.MODULE, command, args)
    if not ok then PLS.warn("client handler " .. tostring(command) .. " failed: " .. tostring(err)) end
end
