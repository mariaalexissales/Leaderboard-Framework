----------
--ESTRAL--
----------

require "LBF_Core"
require "LBF_Boards"

if not LBF.isAuthority() then return end

LBF = LBF or {}
LBF_State = LBF_State or {}

local TABLE_NAME = "LBF_Scores"

LBF_State.data = LBF_State.data or nil

-- boards whose standings have moved since the last recompute. LBF_Ranking drains this.
LBF_State.dirty = LBF_State.dirty or {}

-- keyed by username in global mod data, never player:getModData(). a client's own mod data
-- is that client's copy and is never pushed up, so it cannot be trusted with a score.
function LBF_State.ensure()
    if not LBF_State.data then
        LBF_State.data = ModData.getOrCreate(TABLE_NAME)
    end

    local data = LBF_State.data
    data.v = data.v or LBF.SCHEMA_V
    data.players = data.players or {}
    -- who held first place at the last announcement, so a restart does not re-announce
    -- whoever was already sitting on top.
    data.leaders = data.leaders or {}

    return data
end

function LBF_State.scores(username)
    if not username then return nil end

    local data = LBF_State.ensure()
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
function LBF_State.get(username, board)
    if not username or not board then return 0 end

    local entry = LBF_State.ensure().players[username]
    return entry and entry[board] or 0
end

function LBF_State.markDirty(board)
    if board then LBF_State.dirty[board] = true end
end

function LBF_State.add(username, board, amount)
    if not username or not board then return 0 end

    amount = tonumber(amount) or 0
    if amount == 0 then return LBF_State.get(username, board) end

    local entry = LBF_State.scores(username)
    local total = (entry[board] or 0) + amount

    -- a board is a race to the top; nothing here has any business going backwards past
    -- zero, and a negative would sort above everybody on the wrong comparison.
    if total < 0 then total = 0 end

    entry[board] = total
    LBF_State.markDirty(board)

    return total
end

-- wipes one board without touching the others, so an admin can start a new zombie season
-- and leave the pvp standings alone.
function LBF_State.resetBoard(board)
    if not board then return end

    local data = LBF_State.ensure()

    for _, entry in pairs(data.players) do
        entry[board] = nil
    end

    data.leaders[board] = nil
    LBF_State.markDirty(board)
end

function LBF_State.leader(board)
    if not board then return nil end
    return LBF_State.ensure().leaders[board]
end

function LBF_State.setLeader(board, name, score, announcedAt)
    if not board then return end

    LBF_State.ensure().leaders[board] = {
        name = name,
        score = score,
        -- real milliseconds, so the announce cooldown still throttles while the world is
        -- running fast or a player is asleep.
        at = announcedAt,
    }
end

Events.OnInitGlobalModData.Add(function()
    LBF_State.ensure()
end)
