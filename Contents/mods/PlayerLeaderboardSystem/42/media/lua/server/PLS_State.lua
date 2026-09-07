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
    -- kills on the life a player is on right now, keyed by kind rather than by board. a run
    -- feeds the best-life board but is not itself a score, and keeping it out of data.players
    -- keeps that table the flat board -> number map the ranking loop expects. persisted on
    -- purpose: a restart must not hand everybody a fresh run.
    --   username -> { zombie = n, pvp = n, h = hours survived when last seen }
    data.lives = data.lives or {}

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
    if not board then return end

    PLS_State.dirty[board] = true
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

-- an absolute write, where add() is a delta. a best-life board is a high-water mark rather
-- than a running total, so the only thing that can set it is the run that passed it.
function PLS_State.set(username, board, value)
    if not username or not board then return 0 end

    value = tonumber(value) or 0
    if value < 0 then value = 0 end

    PLS_State.scores(username)[board] = value
    PLS_State.markDirty(board)

    return value
end

-- ----------------------------------------------------------------------------
-- the life in progress
-- ----------------------------------------------------------------------------

-- reads without creating, for the same reason get() does.
function PLS_State.lifeGet(username, kind)
    if not username or not kind then return 0 end

    local run = PLS_State.ensure().lives[username]
    return run and run[kind] or 0
end

function PLS_State.lifeAdd(username, kind, amount)
    if not username or not kind then return 0 end

    amount = tonumber(amount) or 0
    if amount == 0 then return PLS_State.lifeGet(username, kind) end

    local data = PLS_State.ensure()
    local run = data.lives[username]

    if not run then
        run = {}
        data.lives[username] = run
    end

    local total = (run[kind] or 0) + amount
    if total < 0 then total = 0 end

    run[kind] = total
    return total
end

-- every kind at once, because a death ends the whole life and not one board's part of it.
-- the hours mark is carried over: it says which character this is, not what they scored.
--
-- replaced rather than emptied key by key while iterating it. kahlua is not a lua this mod
-- gets to assume the standard's traversal rules from -- PLS_Ranking says the same about
-- next() -- and the table is three numbers wide.
function PLS_State.lifeClear(username)
    if not username then return end

    local data = PLS_State.ensure()
    local run = data.lives[username]
    if not run then return end

    data.lives[username] = { h = run.h }
end

-- the hours survived this account was last seen on. a lower one next time means a different
-- character, which is a death nobody reported.
function PLS_State.lifeHours(username)
    if not username then return nil end

    local run = PLS_State.ensure().lives[username]
    return run and run.h or nil
end

function PLS_State.setLifeHours(username, hours)
    if not username then return end

    local data = PLS_State.ensure()
    local run = data.lives[username]

    if not run then
        run = {}
        data.lives[username] = run
    end

    run.h = tonumber(hours) or 0
end

-- wipes one board without touching the others, so an admin can start a new zombie season
-- and leave the pvp standings alone.
function PLS_State.resetBoard(board)
    if not board then return end

    local data = PLS_State.ensure()

    for _, entry in pairs(data.players) do
        entry[board] = nil
    end

    -- a per-life board is a record of runs, and the run that set one may still be going. wiping
    -- the records without wiping those would put everybody back on the board at their old score
    -- with their very next kill.
    local def = PLS_Boards.get(board)
    if def and def.scope == "life" then
        for _, run in pairs(data.lives) do
            run[def.group] = nil
        end
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
