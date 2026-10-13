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

-- how many times each board has moved this session. separate from the flag above because it
-- must keep climbing after dirty is drained -- that is what lets PLS_Ranking's cached view
-- tell whether it has been overtaken. runtime only: a restart rebuilds every view.
PLS_State.version = PLS_State.version or {}

-- every score or run that has moved this session, whichever board it was on. PLS_Backup holds
-- this against what it was at the last write, so an idle server rewrites nothing. runtime only.
PLS_State.changes = PLS_State.changes or 0

-- global mod data, never player:getModData(): a client's own mod data is its copy and is never
-- pushed up, so it cannot be trusted with a score.
function PLS_State.ensure()
    if not PLS_State.data then
        PLS_State.data = ModData.getOrCreate(TABLE_NAME)
    end

    local data = PLS_State.data
    data.v = data.v or PLS.SCHEMA_V
    data.players = data.players or {}
    -- who held first at the last announcement, so a restart does not re-announce them.
    data.leaders = data.leaders or {}
    -- the run each player is on, keyed by kind not board: a run feeds the best-life board but
    -- is not itself a score, and keeping it out of players leaves that a flat board -> number
    -- map. persisted on purpose -- a restart must not hand everybody a fresh run.
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

-- reads without creating, unlike scores(). every push looks up every online player, and
-- scores() would leave an empty table in the save for everyone who ever connected.
function PLS_State.get(username, board)
    if not username or not board then return 0 end

    local entry = PLS_State.ensure().players[username]
    return entry and entry[board] or 0
end

function PLS_State.markDirty(board)
    if not board then return end

    PLS_State.dirty[board] = true
    PLS_State.version[board] = (PLS_State.version[board] or 0) + 1
    PLS_State.changes = PLS_State.changes + 1
end

function PLS_State.add(username, board, amount)
    if not username or not board then return 0 end

    amount = tonumber(amount) or 0
    if amount == 0 then return PLS_State.get(username, board) end

    local entry = PLS_State.scores(username)
    local total = (entry[board] or 0) + amount

    -- clamped: a negative would sort above everybody on the wrong comparison.
    if total < 0 then total = 0 end

    entry[board] = total
    PLS_State.markDirty(board)

    return total
end

-- absolute, where add() is a delta. a best-life board is a high-water mark, so only the run
-- that passed it can set it.
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
    PLS_State.changes = PLS_State.changes + 1

    return total
end

-- every kind at once: a death ends the whole life, not one board's part of it. the hours mark
-- carries over -- it says which character this is, not what they scored.
--
-- replaced rather than emptied key by key while iterating: kahlua's traversal rules are not
-- the standard's (see next() in PLS_Ranking), and the table is three numbers wide.
function PLS_State.lifeClear(username)
    if not username then return end

    local data = PLS_State.ensure()
    local run = data.lives[username]
    if not run then return end

    data.lives[username] = { h = run.h }
    PLS_State.changes = PLS_State.changes + 1
end

-- hours survived when last seen. a lower one next time means a different character, which is
-- a death nobody reported.
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

-- one board only, so an admin can start a new zombie season and leave pvp alone.
function PLS_State.resetBoard(board)
    if not board then return end

    local data = PLS_State.ensure()

    for _, entry in pairs(data.players) do
        entry[board] = nil
    end

    -- the run that set a per-life record may still be going. wiping records without wiping
    -- runs would put everybody back at their old score on their next kill.
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
        -- real milliseconds, so the cooldown still throttles while the world runs fast or a
        -- player sleeps.
        at = announcedAt,
    }
end

Events.OnInitGlobalModData.Add(function()
    PLS_State.ensure()
end)
