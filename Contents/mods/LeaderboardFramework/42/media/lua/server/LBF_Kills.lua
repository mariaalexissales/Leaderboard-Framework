----------
--ESTRAL--
----------

require "LBF_Core"
require "LBF_Boards"
require "LBF_State"

if not LBF.isAuthority() then return end

LBF = LBF or {}
LBF_Kills = LBF_Kills or {}

-- a client reporting its own zombie kills is trusted only this far in one go. anything
-- past it is a broken client or somebody editing their counter.
local MAX_PER_FLUSH = 40

function LBF_Kills.creditZombie(username, amount)
    if not username then return end
    if not LBF_Boards.enabled("zombie") then return end

    LBF_State.add(username, "zombie", amount or 1)
end

local function LBF_onZombieDead(zombie)
    if LBF.Config.clientKillReporting then return end
    if not zombie then return end

    -- OnZombieDead passes the zombie and nothing else, so the killer comes off the zombie.
    -- nil for fire, falls and cars, and anything that is not a player has no username.
    local attacker = zombie:getAttackedBy()
    if not attacker or not instanceof(attacker, "IsoPlayer") then return end

    LBF_Kills.creditZombie(LBF.nameOf(attacker), 1)
end

Events.OnZombieDead.Add(LBF_onZombieDead)

-- the fallback path, off unless LBF.Config.clientKillReporting is set. some dedicated
-- servers hand back a nil attacker on every kill, which leaves the board permanently
-- empty; a client diffing its own vanilla kill counter at least fills it. the count is
-- all the server takes, and it is clamped.
function LBF_Kills.onReported(player, args)
    if not LBF.Config.clientKillReporting then return end
    if not player or not args then return end

    local count = tonumber(args.n) or 0
    if count < 1 then return end

    local username = LBF.nameOf(player)
    if not username then return end

    if count > MAX_PER_FLUSH then
        LBF.warn(username .. " reported " .. count
            .. " zombie kills in one flush, clamped to " .. MAX_PER_FLUSH)
        count = MAX_PER_FLUSH
    end

    LBF_Kills.creditZombie(username, count)
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

local function LBF_prune(now)
    for victim, byAttacker in pairs(hits) do
        for attacker, at in pairs(byAttacker) do
            if now - at > HIT_WINDOW_MS then byAttacker[attacker] = nil end
        end
        if next(byAttacker) == nil then hits[victim] = nil end
    end
end

-- player is the attacker, handed over by the engine. args.victim is the only part a
-- client chose, and the worst it can do is put a name in a ledger that is then only
-- spent if that name actually dies.
function LBF_Kills.onHit(player, args)
    if not LBF_Boards.enabled("pvp") then return end
    if not player or not args then return end

    local attacker = LBF.nameOf(player)
    if not attacker then return end

    local victim = args.victim
    if type(victim) ~= "string" or victim == "" or victim == attacker then return end

    local now = getTimestampMs()
    LBF_prune(now)

    hits[victim] = hits[victim] or {}
    hits[victim][attacker] = now
end

-- player is the victim, handed over by the engine, never read out of args.
function LBF_Kills.onDeath(player, args)
    if not LBF_Boards.enabled("pvp") then return end
    if not player then return end

    local victim = LBF.nameOf(player)
    if not victim then return end

    local now = getTimestampMs()
    if now - (lastDeath[victim] or 0) < DEATH_COOLDOWN_MS then return end
    lastDeath[victim] = now

    LBF_prune(now)

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

    LBF_State.add(killer, "pvp", 1)
end
