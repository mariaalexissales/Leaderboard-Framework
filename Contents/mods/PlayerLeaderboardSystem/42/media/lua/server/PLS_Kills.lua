----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Net"
require "PLS_Boards"
require "PLS_State"
require "PLS_Ranking"

if not PLS.isAuthority() then return end

PLS_Kills = PLS_Kills or {}

-- a client reporting its own zombie kills is trusted only this far in one go. anything
-- past it is a broken client or somebody editing their counter.
local MAX_PER_FLUSH = 40

-- username -> whether that client said it was in debug mode when it last said hello. runtime
-- only, like the hit ledger further down: a fact about a connection, not a score, with no
-- business surviving a restart or sitting in the world save.
local debugMode = {}

-- username -> whether the console has already been told this player's kills are being
-- dropped. same lifetime as debugMode above, and swept with it.
local warned = {}

-- the client's own word for it and nothing more. this process cannot see a remote one's
-- launch flags, and a modified client can simply not send it. what it buys is a staff
-- member's spawn-and-slaughter session staying off the board; it is not a barrier against
-- anyone who wants to be on it, which is why nothing destructive hangs off it. a client that
-- turns debug on mid-session likewise keeps scoring until it next says hello.
--
-- the engine only lets an account holding the ConnectWithDebug capability -- role admin, by
-- default -- join with -debug at all, so in practice this can only ever describe staff.
function PLS_Kills.setDebug(username, value)
    if not username then return end

    value = value == true

    -- a player who has been out of debug mode and gone back into it is worth saying again.
    -- without this the console gets one line per session no matter how the flag moves.
    if debugMode[username] ~= value then warned[username] = nil end

    debugMode[username] = value
end

-- b42 has no server-side disconnect event, so names are swept against who is actually online
-- instead. one that comes back says hello again and is recorded again.
function PLS_Kills.forgetOffline(online)
    if not online then return end

    for username in pairs(debugMode) do
        if not online[username] then
            debugMode[username] = nil
            warned[username] = nil
        end
    end

    for username in pairs(PLS_Kills.lastUpset) do
        if not online[username] then PLS_Kills.lastUpset[username] = nil end
    end
end

-- nil, not false, for a name whose hello has not landed. a kill can beat the handshake --
-- PLS_ClientState says how easily that one gets lost -- and reading "not told yet" as debug
-- would empty a board for anyone whose hello was still in flight.
local function PLS_inDebug(username)
    -- inside the authority process, not isServer() is singleplayer. nobody is reporting
    -- because there is nobody to report, so our own flag is the answer, and it covers a
    -- second splitscreen player, who never sends a hello of their own.
    if not isServer() then return getCore():getDebug() == true end
    if not username then return false end

    return debugMode[username] == true
end

-- opt-in, and off by default. a leaderboard whose shipped settings quietly discard kills is
-- a worse failure than a staff member's spawn-and-slaughter session turning up on a board,
-- and it is the one that actually happened: every board sat empty for anyone playing with
-- -debug, and nothing was logged to say so.
function PLS_Kills.shouldCount(player)
    if not player then return false end
    if PLS.sandbox("IgnoreDebugKills", false) ~= true then return true end

    local username = PLS.nameOf(player)
    if not PLS_inDebug(username) then return true end

    -- once per player, not once per kill. a silently dropped kill looks exactly like a mod
    -- that is not loaded, and telling those two apart from the console without reading the
    -- lua is the whole job of this line.
    if username and not warned[username] then
        warned[username] = true
        PLS.warn(username .. " is in debug mode and IgnoreDebugKills is on,"
            .. " so their kills are not being counted")
    end

    PLS.trace("dropped a kill by " .. tostring(username) .. ": debug mode")
    return false
end

-- one kill, every enabled board for its kind. the best-life board is a high-water mark raised
-- as the run passes it rather than banked when the run ends, so a player who has not died in a
-- month still shows the run they are actually on.
function PLS_Kills.credit(username, kind, amount)
    if not username or not kind then return end

    amount = amount or 1

    local account = PLS_Boards.find(kind, "account")
    if account and PLS_Boards.enabled(account) then
        PLS_State.add(username, account, amount)
        PLS.trace("credited " .. username .. " with " .. tostring(amount) .. " on " .. account)
    end

    local life = PLS_Boards.find(kind, "life")
    if life and PLS_Boards.enabled(life) then
        local run = PLS_State.lifeAdd(username, kind, amount)

        if run > PLS_State.get(username, life) then
            PLS_State.set(username, life, run)
            PLS.trace(username .. " set a new " .. life .. " record of " .. tostring(run))
        end
    end
end

function PLS_Kills.creditZombie(username, amount)
    if not username then return end
    if not PLS_Boards.tracked("zombie") then return end

    PLS_Kills.credit(username, "zombie", amount or 1)
end

local function PLS_onZombieDead(zombie)
    if PLS.Config.clientKillReporting then return end
    if not zombie then return end

    -- OnZombieDead passes the zombie and nothing else, so the killer comes off the zombie.
    -- nil for fire, falls and cars, and anything that is not a player has no username.
    local attacker = zombie:getAttackedBy()
    if not attacker or not instanceof(attacker, "IsoPlayer") then return end
    if not PLS_Kills.shouldCount(attacker) then return end

    PLS_Kills.creditZombie(PLS.nameOf(attacker), 1)
end

PLS.guard("zombie kill credit", Events.OnZombieDead, PLS_onZombieDead)

-- the fallback path, off unless PLS.Config.clientKillReporting is set. some dedicated
-- servers hand back a nil attacker on every kill, which leaves the board permanently
-- empty; a client diffing its own vanilla kill counter at least fills it. the count is
-- all the server takes, and it is clamped.
function PLS_Kills.onReported(player, args)
    if not PLS.Config.clientKillReporting then return end
    if not player or not args then return end
    if not PLS_Kills.shouldCount(player) then return end

    local count = tonumber(args.n) or 0
    if count < 1 then return end

    local username = PLS.nameOf(player)
    if not username then return end

    if count > MAX_PER_FLUSH then
        PLS.warn(username .. " reported " .. count
            .. " zombie kills in one flush, clamped to " .. MAX_PER_FLUSH)
        count = MAX_PER_FLUSH
    end

    PLS_Kills.creditZombie(username, count)
end

-- ----------------------------------------------------------------------------
-- player kills
-- ----------------------------------------------------------------------------
--
-- combat is resolved on the attacking client, so the server never sees the swing that
-- landed. it is told about the kill twice instead, from both ends, and only credits one
-- when the two agree:
--
--   the attacker's client reports "i hit this player" and the server writes that into a
--   short-lived ledger. the victim's client reports "i died, and this is who did it".
--
-- the credit is taken from the ledger, not from the victim's claim. so a victim cannot
-- hand first place to a friend who never touched them, and an attacker cannot credit
-- themselves without a real hit landing on someone who really died.

local HIT_WINDOW_MS = 30000
local DEATH_COOLDOWN_MS = 3000

-- runtime only, both of them. a thirty second ledger and a rate limit have no business
-- surviving a restart or sitting in the world save.
local hits = {}
local lastDeath = {}

local function PLS_prune(now)
    for victim, byAttacker in pairs(hits) do
        for attacker, at in pairs(byAttacker) do
            if now - at > HIT_WINDOW_MS then byAttacker[attacker] = nil end
        end
        if table.isempty(byAttacker) then hits[victim] = nil end
    end
end

-- player is the attacker, handed over by the engine. args.victim is the only part a
-- client chose, and the worst it can do is put a name in a ledger that is then only
-- spent if that name actually dies.
function PLS_Kills.onHit(player, args)
    if not PLS_Boards.tracked("pvp") then return end
    if not player or not args then return end
    -- filtered here rather than at the death, because the credit is spent by name and the
    -- player object is only in hand on this side of it. a client in debug never enters the
    -- ledger, so no kill can be credited to them; being killed by one still counts.
    if not PLS_Kills.shouldCount(player) then return end

    local attacker = PLS.nameOf(player)
    if not attacker then return end

    local victim = args.victim
    if type(victim) ~= "string" or victim == "" or victim == attacker then return end

    local now = getTimestampMs()
    PLS_prune(now)

    hits[victim] = hits[victim] or {}
    hits[victim][attacker] = now
end

-- ----------------------------------------------------------------------------
-- the two announcements a death is worth
-- ----------------------------------------------------------------------------
--
-- both read the per-life boards and nothing else. an all-time board is cumulative, so a
-- death costs whoever tops it exactly nothing, and saying otherwise in chat would be a lie
-- everyone can check.

local ANNOUNCE_TOP = 3

-- username -> when an upset was last announced about them. runtime only, like the ledger and
-- the debug map above, and swept with them. on the table rather than a local so the sweep,
-- which runs further up this file, can reach it.
PLS_Kills.lastUpset = PLS_Kills.lastUpset or {}

-- the enabled per-life boards, in registry order.
local function PLS_lifeBoards()
    local list = {}

    for _, def in ipairs(PLS_Boards.ordered()) do
        if def.scope == "life" then list[#list + 1] = def end
    end

    return list
end

-- keyed by group, because that is what a run is counted under.
--
-- the board list is passed in rather than asked for. a death used to call PLS_lifeBoards three
-- times over, and each call reads the sandbox once per registered board and sorts the result.
local function PLS_runsOf(victim, boards)
    local runs = {}

    for _, def in ipairs(boards) do
        runs[def.group] = PLS_State.lifeGet(victim, def.group)
    end

    return runs
end

-- whether an upset about this player is wanted and due. the stamp is spent by the caller and
-- only once something is actually said, so a quiet death does not burn the window.
local function PLS_upsetReady(victim, now)
    if PLS.sandbox("AnnounceUpsets", true) ~= true then return false end

    local cooldown = (tonumber(PLS.sandbox("AnnounceUpsetCooldownMinutes", 5)) or 5) * 60000
    return now - (PLS_Kills.lastUpset[victim] or 0) >= cooldown
end

-- the first per-life board this player is top of, or nil. read before the kill is credited:
-- the credit can push the killer past the very record they just ended, and asking afterwards
-- would find the killer at the top and nobody who had been first place a moment ago.
local function PLS_toppedBoard(victim, boards)
    for _, def in ipairs(boards) do
        -- topOf rather than the whole board sorted so that its first row can be read and the
        -- rest thrown away.
        local name, score = PLS_Ranking.topOf(def.key)
        -- registry order, so somebody holding both is announced once and for the same board
        -- every time rather than whichever way a pairs() loop happened to fall.
        if name == victim then return def, score end
    end

    return nil
end

-- a run that would have placed in the top three has ended in a horde.
--
-- the question is asked of the run, not of the record behind it. a board like this ranks
-- somebody's best ever life, and a record holder dying on a fresh three-kill one has lost
-- nothing worth saying out loud -- while a run that places is exactly what it cost them.
local function PLS_announceFallen(victim, runs, now, boards)
    if not PLS_upsetReady(victim, now) then return end

    local best, bestPlace, bestRun

    for _, def in ipairs(boards) do
        local run = runs[def.group] or 0

        if run > 0 then
            local place = PLS_Ranking.placeOf(def.key, run)

            -- the board it placed highest on. somebody caught mid-rampage reports whichever
            -- of their runs was worth more, which is the honest answer to what they lost.
            if place <= ANNOUNCE_TOP and (not bestPlace or place < bestPlace) then
                best, bestPlace, bestRun = def, place, run
            end
        end
    end

    if not best then return end

    PLS_Kills.lastUpset[victim] = now
    PLS_Net.toAll("announce", {
        kind = "fallen",
        board = best.key,
        name = victim,
        score = bestRun,
        place = bestPlace,
    })
end

-- somebody took the top of a per-life board off the player who held it. called after the
-- credit, with the board that was captured before it.
local function PLS_announceSlain(victim, killer, board, score, now)
    if not board or not killer then return end
    if not PLS_upsetReady(victim, now) then return end

    PLS_Kills.lastUpset[victim] = now
    PLS_Net.toAll("announce", {
        kind = "slain",
        board = board.key,
        name = killer,
        victim = victim,
        score = score,
    })
end

-- a death ends every kind's run at once. gated on there being a per-life board to end one
-- for, so a server running account boards alone keeps no life state at all.
function PLS_Kills.endLife(username)
    if not username then return end
    if not PLS_Boards.anyLife() then return end

    PLS_State.lifeClear(username)
    PLS.trace("ended the life of " .. username)
end

-- player is the victim, handed over by the engine, never read out of args.
--
-- both halves of a death go through here rather than through two command handlers, because
-- the cooldown below has to be spent once. two handlers reading it would mean whichever ran
-- first silently ate the other.
function PLS_Kills.onDeath(player, args)
    if not player then return end

    local victim = PLS.nameOf(player)
    if not victim then return end

    local now = getTimestampMs()
    if now - (lastDeath[victim] or 0) < DEATH_COOLDOWN_MS then return end
    lastDeath[victim] = now

    -- once, and handed to each of the three below. this used to be three separate calls.
    local boards = PLS_lifeBoards()

    -- both read before anything below changes them: endLife wipes the runs, and crediting
    -- the kill can move the top of a board.
    local runs = PLS_runsOf(victim, boards)
    local topped, toppedScore = PLS_toppedBoard(victim, boards)

    -- first, and whatever comes of the ledger below: the run is over however it ended, and
    -- most deaths are not pvp at all. a client can send a death it did not have, and all
    -- that buys is resetting its own run, whose record is already banked on the board.
    PLS_Kills.endLife(victim)

    -- a horde landing the final blow on somebody a player had been working on will spend the
    -- cooldown here and leave the slain line below unsaid. one death is worth one line, and
    -- of the two this is the one that describes what actually killed them.
    if args and args.cause == "zombie" then
        PLS_announceFallen(victim, runs, now, boards)
    end

    if not PLS_Boards.tracked("pvp") then return end

    PLS_prune(now)

    local ledger = hits[victim]
    -- nobody hit them inside the window, so this was a zombie, a fall, a fire or hunger.
    if not ledger then return end

    -- one death spends the whole ledger, whatever comes of it, so a body cannot be
    -- cashed in twice.
    hits[victim] = nil

    -- the victim's claim is a hint. it is honoured only where the ledger already agrees,
    -- and otherwise the most recent attacker takes it.
    local claimed = args and args.killer
    local killer = nil

    if type(claimed) == "string" and ledger[claimed] then
        killer = claimed
    else
        local latest = 0
        for attacker, at in pairs(ledger) do
            if at > latest then
                killer, latest = attacker, at
            end
        end
    end

    if not killer or killer == victim then return end

    PLS_Kills.credit(killer, "pvp", 1)
    PLS_announceSlain(victim, killer, topped, toppedScore, now)
end
