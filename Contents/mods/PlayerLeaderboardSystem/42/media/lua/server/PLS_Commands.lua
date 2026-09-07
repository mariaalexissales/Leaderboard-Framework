----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Net"
require "PLS_Boards"
require "PLS_State"
require "PLS_Kills"
require "PLS_Ranking"
require "PLS_Backup"

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

-- the only way a best-life score can be inflated is a client that never sends its death
-- packet, keeping one run alive across every death. this is the cheap cover for that: the
-- engine puts a dead player back at the main menu, so a rejoin nearly always follows, and
-- hours survived that have gone backwards mean a character this account has not been seen
-- on before. costs one call on a handshake that already runs.
local function PLS_checkLife(player, name)
    if not PLS_Boards.anyLife() then return end

    -- through pcall: not every build of every character class answers this, and a handshake
    -- is a bad place to take the whole mod down over a stat nobody is ranked on.
    local ok, hours = pcall(function() return player:getHoursSurvived() end)
    if not ok or type(hours) ~= "number" then return end

    local last = PLS_State.lifeHours(name)
    if last and hours < last then
        PLS.trace(name .. " said hello on a newer character, so the old life is over")
        PLS_Kills.endLife(name)
    end

    PLS_State.setLifeHours(name, hours)
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

    -- above the floor for the same reason: a rejoin is the case this exists for, and it must
    -- not be missed because the player pressed refresh on their way in.
    PLS_checkLife(player, name)

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

-- ----------------------------------------------------------------------------
-- reading the table back out
-- ----------------------------------------------------------------------------
--
-- there is no vanilla console command for global mod data, and the debug viewer needs a
-- client launched with -debug. an admin on somebody else's server has neither, so the only
-- way to answer "is this player's score actually in there" is to ask the server for it and
-- have the answer arrive in chat.
--
-- the lines are deliberately not translated. they are diagnostics that end up pasted into
-- bug reports, and a stable greppable string is worth more there than a localised one.

-- a reply is a handful of lines by construction: the health form counts rather than lists.
-- the cap is only here so a pathological number of registered boards cannot flood chat.
local DUMP_MAX_LINES = 12

local function PLS_dumpHealth()
    local data = PLS_State.ensure()
    local lines = {}

    local players = 0
    for _ in pairs(data.players) do players = players + 1 end

    lines[#lines + 1] = "PLS_Scores v" .. tostring(data.v) .. " - " .. players .. " players"

    -- every registered board, not just the enabled ones. a board switched off in sandbox
    -- still has its scores sitting there, and seeing that is the entire point of asking
    -- when a board has gone blank.
    local counts = {}
    for key in pairs(PLS_Boards.defs) do
        local n = 0
        for _, entry in pairs(data.players) do
            if entry[key] then n = n + 1 end
        end
        counts[#counts + 1] = key .. " " .. n .. (PLS_Boards.enabled(key) and "" or " (off)")
    end
    table.sort(counts)
    lines[#lines + 1] = "  " .. table.concat(counts, " | ")

    local leaders = {}
    for key in pairs(PLS_Boards.defs) do
        local leader = PLS_State.leader(key)
        if leader then
            leaders[#leaders + 1] = key .. "=" .. tostring(leader.name)
                .. "(" .. tostring(leader.score) .. ")"
        end
    end
    table.sort(leaders)
    lines[#lines + 1] = "  leaders: " .. (#leaders > 0 and table.concat(leaders, " ") or "none")

    local runs = 0
    for _ in pairs(data.lives) do runs = runs + 1 end
    lines[#lines + 1] = "  lives tracked: " .. runs

    -- whether the second copy exists and which way round the two are. one line, and it is
    -- the line that answers "is my backup actually working" without disk access.
    --
    -- guarded, because this is the command somebody runs when things are already wrong. a
    -- missing backup module should cost the report one line, not all of it.
    if not PLS_Backup then
        lines[#lines + 1] = "  backup: module not loaded"
        return lines
    end

    local path = PLS_Backup.path()
    local parsed, from = PLS_Backup.read()

    if not parsed then
        lines[#lines + 1] = "  backup: none at " .. PLS_Backup.shownPath(path)
    else
        local fileAt = tonumber(parsed.savedAt) or 0
        local liveAt = tonumber(data.savedAt) or 0
        lines[#lines + 1] = "  backup: " .. PLS_Backup.shownPath(from) .. " " .. PLS.stampText(fileAt)
        lines[#lines + 1] = "    live table " .. (liveAt > fileAt and "is newer"
            or (liveAt < fileAt and "is OLDER - a restart would restore" or "matches"))
    end

    return lines
end

local function PLS_dumpPlayer(username)
    local data = PLS_State.ensure()
    local entry = data.players[username]

    -- a name with no row at all and a row of zeroes are different answers, and telling them
    -- apart is most of what somebody asking this question needs to know.
    if not entry then
        return { tostring(username) .. " - no entry" }
    end

    local scores = {}
    for key in pairs(PLS_Boards.defs) do
        if entry[key] then scores[#scores + 1] = key .. " " .. tostring(entry[key]) end
    end
    table.sort(scores)

    local lines = {
        tostring(username) .. " - " .. (#scores > 0 and table.concat(scores, ", ") or "no scores"),
    }

    local runs = {}
    for _, def in pairs(PLS_Boards.defs) do
        if def.scope == "life" then
            runs[def.group] = PLS_State.lifeGet(username, def.group)
        end
    end

    local parts = {}
    for group, n in pairs(runs) do parts[#parts + 1] = group .. " " .. tostring(n) end
    table.sort(parts)

    local hours = PLS_State.lifeHours(username)
    lines[#lines + 1] = "  run now: " .. (#parts > 0 and table.concat(parts, ", ") or "none")
        .. " | hours " .. (hours and string.format("%.1f", hours) or "?")

    return lines
end

function PLS_Commands.handlers.dump(player, args)
    if not player then return end

    local lines

    if args and args.own then
        -- the name is taken from the player the engine handed us and never from args, which
        -- is what keeps this open to everyone: a client asking about itself cannot ask about
        -- somebody else by putting their name in the packet.
        local me = PLS.nameOf(player)
        if not me then return end
        lines = PLS_dumpPlayer(me)
    else
        if not PLS.isAdmin(player) then
            PLS.warn(tostring(PLS.nameOf(player)) .. " asked to dump the table without permission")
            return
        end

        local who = args and args.who
        lines = type(who) == "string" and who ~= "" and PLS_dumpPlayer(who) or PLS_dumpHealth()
    end

    while #lines > DUMP_MAX_LINES do table.remove(lines) end

    -- to the console as well. whoever asked cannot see it, but anyone reading the server log
    -- afterwards can, and that is the case this whole command exists because of.
    for _, line in ipairs(lines) do print("[PLS] " .. line) end

    PLS_Net.toClient(player, "dump", { lines = lines })
end

function PLS_Commands.handlers.backup(player, args)
    if not PLS.isAdmin(player) then
        PLS.warn(tostring(PLS.nameOf(player)) .. " asked to write a backup without permission")
        return
    end

    local ok, path = PLS_Backup.save()
    local data = PLS_State.ensure()

    local n = 0
    for _ in pairs(data.players) do n = n + 1 end

    PLS_Net.toClient(player, "dump", {
        lines = { ok and ("wrote " .. n .. " players to " .. PLS_Backup.shownPath(path))
            or "the backup could not be written, see the server log" },
    })
end

function PLS_Commands.handlers.restore(player, args)
    if not PLS.isAdmin(player) then
        PLS.warn(tostring(PLS.nameOf(player)) .. " asked to restore a backup without permission")
        return
    end

    -- forced: an admin typing this has decided the file is right, whatever the stamps say.
    local ok, count, from = PLS_Backup.load(true)

    -- pushed now rather than left to the pump, so whoever typed this sees the boards change
    -- rather than wondering whether it took.
    if ok then
        for _, def in ipairs(PLS_Boards.ordered()) do
            PLS_Ranking.recompute(def.key)
        end
    end

    PLS_Net.toClient(player, "dump", {
        lines = { ok and ("restored " .. tostring(count) .. " players from "
            .. PLS_Backup.shownPath(from))
            or "nothing to restore, see the server log" },
    })
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

    -- straight to disk. the backup is whole-table and newest-wins, so a wipe that only lived
    -- in memory would be undone by the very next restart.
    PLS_Backup.save()

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
