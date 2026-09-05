----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Boards"
require "PLS_State"

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

function PLS_Kills.creditZombie(username, amount)
    if not username then return end
    if not PLS_Boards.enabled("zombie") then return end

    PLS_State.add(username, "zombie", amount or 1)
    PLS.trace("credited " .. username .. " with " .. tostring(amount or 1) .. " on zombie")
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
    if not PLS_Boards.enabled("pvp") then return end
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

-- player is the victim, handed over by the engine, never read out of args.
function PLS_Kills.onDeath(player, args)
    if not PLS_Boards.enabled("pvp") then return end
    if not player then return end

    local victim = PLS.nameOf(player)
    if not victim then return end

    local now = getTimestampMs()
    if now - (lastDeath[victim] or 0) < DEATH_COOLDOWN_MS then return end
    lastDeath[victim] = now

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

    PLS_State.add(killer, "pvp", 1)
end
