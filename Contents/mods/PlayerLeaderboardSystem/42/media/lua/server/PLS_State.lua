----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Boards"

if not PLS.isAuthority() then return end

PLS_State = PLS_State or {}

local TABLE_NAME = "PLS_Scores"

PLS_State.data = PLS_State.data or nil

-- boards whose standings have moved since the last recompute. PLS_Ranking drains this.
PLS_State.dirty = PLS_State.dirty or {}

-- keyed by username in global mod data, never player:getModData(). a client's own mod data
-- is that client's copy and is never pushed up, so it cannot be trusted with a score.
function PLS_State.ensure()
    if not PLS_State.data then
        PLS_State.data = ModData.getOrCreate(TABLE_NAME)
    end

    local data = PLS_State.data
    data.v = data.v or PLS.SCHEMA_V
    data.players = data.players or {}
    -- who held first place at the last announcement, so a restart does not re-announce
    -- whoever was already sitting on top.
    data.leaders = data.leaders or {}

    return data
end

function PLS_State.scores(username)
    if not username then return nil end

    local data = PLS_State.ensure()
    local entry = data.players[username]

    if not entry then
        entry = {}
        data.players[username] = entry
    end

    return entry
end

-- reads without creating, unlike scores(). every board push looks up the standing of
-- every online player, and going through scores() would leave an empty table in the save
-- for everyone who has ever connected without scoring.
function PLS_State.get(username, board)
    if not username or not board then return 0 end

    local entry = PLS_State.ensure().players[username]
    return entry and entry[board] or 0
end

function PLS_State.markDirty(board)
    if board then PLS_State.dirty[board] = true end
end

function PLS_State.add(username, board, amount)
    if not username or not board then return 0 end

    amount = tonumber(amount) or 0
    if amount == 0 then return PLS_State.get(username, board) end

    local entry = PLS_State.scores(username)
    local total = (entry[board] or 0) + amount

    -- a board is a race to the top; nothing here has any business going backwards past
    -- zero, and a negative would sort above everybody on the wrong comparison.
    if total < 0 then total = 0 end

    entry[board] = total
    PLS_State.markDirty(board)

    return total
end

-- wipes one board without touching the others, so an admin can start a new zombie season
-- and leave the pvp standings alone.
function PLS_State.resetBoard(board)
    if not board then return end

    local data = PLS_State.ensure()

    for _, entry in pairs(data.players) do
        entry[board] = nil
    end

    data.leaders[board] = nil
    PLS_State.markDirty(board)
end

function PLS_State.leader(board)
    if not board then return nil end
    return PLS_State.ensure().leaders[board]
end

function PLS_State.setLeader(board, name, score, announcedAt)
    if not board then return end

    PLS_State.ensure().leaders[board] = {
        name = name,
        score = score,
        -- real milliseconds, so the announce cooldown still throttles while the world is
        -- running fast or a player is asleep.
        at = announcedAt,
    }
end

Events.OnInitGlobalModData.Add(function()
    PLS_State.ensure()
end)
