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
