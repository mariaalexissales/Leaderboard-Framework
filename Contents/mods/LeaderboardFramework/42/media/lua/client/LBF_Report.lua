----------
--ESTRAL--
----------

require "LBF_Core"
require "LBF_Net"
require "LBF_Boards"

LBF = LBF or {}
LBF_Report = LBF_Report or {}

-- the server ledger only cares that a hit happened recently, not how many landed, so a
-- flurry of swings on one victim is worth exactly one packet.
local HIT_THROTTLE_MS = 2000
local KILL_POLL_MS = 2000

local lastHit = {}

local function LBF_onWeaponHitCharacter(wielder, character, weapon, damage)
    if not LBF_Boards.enabled("pvp") then return end
    if not wielder or not character then return end
    if not instanceof(wielder, "IsoPlayer") or not instanceof(character, "IsoPlayer") then return end

    -- a client sees other people's swings too, and reporting those would put hits in the
    -- ledger that this machine has no business vouching for.
    local me = getPlayer()
    if not me or wielder ~= me then return end

    local mine = LBF.nameOf(me)
    local victim = LBF.nameOf(character)
    if not mine or not victim or victim == mine then return end

    local now = getTimestampMs()
    if now - (lastHit[victim] or 0) < HIT_THROTTLE_MS then return end
    lastHit[victim] = now

    LBF_Net.toServer("hit", { victim = victim })
end

local function LBF_onPlayerDeath(player)
    if not LBF_Boards.enabled("pvp") then return end
    if not player or not player:isLocalPlayer() then return end

    -- sent even when this comes back nil: the server still has its ledger, and a death
    -- with no claim attached is the honest shape of being shot from off screen.
    local killer = nil
    local attacker = player:getAttackedBy()
    if attacker and instanceof(attacker, "IsoPlayer") then
        killer = LBF.nameOf(attacker)
    end

    LBF_Net.toServer("death", { killer = killer })
end

-- the fallback for servers that hand back a nil attacker on OnZombieDead. off unless
-- LBF.Config.clientKillReporting is set, and the server clamps whatever arrives.
local lastPoll = 0
local lastKills = nil

local function LBF_pollZombieKills()
    if not LBF.Config.clientKillReporting then return end

    local player = getPlayer()
    if not player then return end

    -- EveryOneMinute runs on game time, which sprints when the player sleeps, so the real
    -- clock is what actually paces this.
    local now = getTimestampMs()
    if now - lastPoll < KILL_POLL_MS then return end
    lastPoll = now

    local total = player:getZombieKills() or 0

    -- nil on the first pass, and lower than last time after a death started a new
    -- character. both just reset the baseline rather than reporting anything.
    if lastKills == nil or total < lastKills then
        lastKills = total
        return
    end

    if total == lastKills then return end

    local delta = total - lastKills
    lastKills = total

    LBF_Net.toServer("kills", { n = delta })
end

-- the two that repeat go behind the guard: a swing connects several times a second in a
-- horde, and the poll is on a timer. a death is a one-off and is left alone, so a fault
-- there still surfaces the ordinary way.
LBF.guard("pvp hit report", Events.OnWeaponHitCharacter, LBF_onWeaponHitCharacter)
LBF.guard("zombie kill poll", Events.EveryOneMinute, LBF_pollZombieKills)
Events.OnPlayerDeath.Add(LBF_onPlayerDeath)
