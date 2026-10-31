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

-- hello resends every board, and it is on a button, so it is worth a floor. the length is
-- PLS.refreshCooldownMs, read per packet so a sandbox change needs no restart.

-- b42 has no server-side disconnect event, so lastHello and the debug table are swept against
-- the online list instead. hello is where new names appear, so it is where the sweep belongs,
-- and the floor keeps a room full of refresh buttons off the player list.
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

-- backup for the death event in PLS_Kills, which should already have ended the run. a run
-- that outlived its character inflates the best-life board on the next character's first kill.
local function PLS_checkLife(player, name, args)
    if not PLS_Boards.anyLife() then return end

    -- a run only counts this character's kills, so it can never be higher than the character's
    -- own count. if it is, the character it belonged to is dead. the count is the client's word,
    -- but the most a client can do with it is end its own run, like a made-up death packet.
    local kills = args and tonumber(args.kills)
    if kills and PLS_State.lifeGet(name, "zombie") > kills then
        PLS.trace(name .. " said hello with fewer kills than their run, so the old life is over")
        PLS_Kills.endLife(name)
    end

    -- hours survived going backwards is a character this account has not been seen on. this
    -- one still covers a run of player kills alone.

    -- through pcall: not every build answers this, and a handshake is a bad place to take
    -- the mod down over a stat nobody is ranked on.
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

    -- swept before this writes its own name, so a player the online list has not caught up
    -- with cannot be forgotten by their own hello.
    PLS_sweep(now)

    -- above the floor, so a client refreshing twice in a second still has its second packet's
    -- word for what mode it is in, even though that packet earns no boards back.
    PLS_Kills.setDebug(name, args and args.debug)

    -- above the floor too: a rejoin is what this exists for, and must not be missed because
    -- the player pressed refresh on the way in.
    PLS_checkLife(player, name, args)

    if now - (lastHello[name] or 0) < PLS.refreshCooldownMs() then return end
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
-- no vanilla console command reads global mod data, and the debug viewer needs a client
-- launched with -debug. an admin on somebody else's server has neither, so the only way to
-- answer "is this score actually in there" is to ask the server and read it in chat.
--
-- deliberately untranslated: these get pasted into bug reports, where a stable greppable
-- string beats a localised one.

-- a reply is a few lines by construction, since the health form counts rather than lists.
-- the cap only stops a pathological number of registered boards flooding chat.
local DUMP_MAX_LINES = 12

local function PLS_dumpHealth()
    local data = PLS_State.ensure()
    local lines = {}

    local players = 0
    for _ in pairs(data.players) do players = players + 1 end

    lines[#lines + 1] = "PLS_Scores v" .. tostring(data.v) .. " - " .. players .. " players"

    -- every registered board, not just enabled ones: a board switched off still has its
    -- scores sitting there, and seeing that is the point of asking when one goes blank.
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

    -- whether a second copy is being written at all, and how old the one on disk is. with the
    -- restore manual, "is my backup working" is the question this has to answer.
    --
    -- guarded, because this is the command somebody runs when things are already wrong. a
    -- missing backup module should cost the report one line, not all of it.
    if not PLS_Backup then
        lines[#lines + 1] = "  backup: module not loaded"
        return lines
    end

    if not PLS_Backup.enabled() then
        lines[#lines + 1] = "  backup: switched off in the sandbox options"
        return lines
    end

    local parsed, from = PLS_Backup.read()

    if not parsed then
        lines[#lines + 1] = "  backup: none at " .. PLS_Backup.shownPath()
    else
        lines[#lines + 1] = "  backup: " .. PLS_Backup.shownPath(from) .. " "
            .. PLS.stampText(tonumber(parsed.savedAt) or 0)
    end

    return lines
end

local function PLS_dumpPlayer(username)
    local data = PLS_State.ensure()
    local entry = data.players[username]

    -- no row and a row of zeroes are different answers, and telling them apart is most of
    -- what the asker needs.
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
        -- taken from the player the engine handed us, never from args. that is what keeps
        -- this open to everyone: a client cannot ask about somebody else by putting their
        -- name in the packet.
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

    -- to the console too. the asker cannot see it, but anyone reading the server log after
    -- can, which is the case this command exists for.
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

    local ok, count, from = PLS_Backup.load()

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

    -- straight to disk. the file is whole-table, so a wipe that only lived in memory leaves a
    -- stale backup that the next /pls restore would put right back.
    if PLS_Backup.enabled() then PLS_Backup.save() end

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
