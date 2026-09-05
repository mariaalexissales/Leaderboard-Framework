----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Net"
require "PLS_Boards"
require "PLS_State"

if not PLS.isAuthority() then return end

PLS_Ranking = PLS_Ranking or {}

-- a horde is a kill every second or so per player. without this the board would be
-- rebuilt and pushed to everyone on every one of them. it is kept even though the pump
-- now runs on EveryOneMinute rather than every tick, because that event runs on game time
-- and sprints while a player sleeps; the real clock is what holds the cadence steady.
local RECOMPUTE_MS = 3000

local lastRecompute = 0

local function PLS_eachPlayer(fn)
    if not isServer() then
        local player = getPlayer()
        if player then fn(player) end
        return
    end

    local players = getOnlinePlayers()
    if not players then return end

    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player then fn(player) end
    end
end

-- the whole board, in order, not just the part that gets sent. a player outside the top
-- ten still has to be told their own rank, and that number only exists here.
function PLS_Ranking.ranked(board)
    local data = PLS_State.ensure()
    local floor = tonumber(PLS.sandbox("MinScoreToRank", 1)) or 1
    local rows = {}

    for username, entry in pairs(data.players) do
        local score = entry[board]
        if score and score >= floor then
            rows[#rows + 1] = { name = username, score = score }
        end
    end

    table.sort(rows, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        -- ties broken by name so the order is fixed. two players sitting on the same
        -- score must not be able to trade first place back and forth between sorts.
        return a.name < b.name
    end)

    return rows
end

-- dense from 1 and short keys: this goes over the wire on every recompute, to everybody.
-- BoardSize is read here rather than passed in, so the two callers cannot disagree.
local function PLS_wire(ranked)
    local limit = tonumber(PLS.sandbox("BoardSize", 10)) or 10
    local rows = {}
    for i = 1, math.min(#ranked, limit) do
        rows[i] = { n = ranked[i].name, s = ranked[i].score }
    end
    return rows
end

function PLS_Ranking.send(player, board, ranked, rows)
    if not player then return end

    local me = PLS.nameOf(player)
    local rank = nil

    if me then
        for i, row in ipairs(ranked) do
            if row.name == me then
                rank = i
                break
            end
        end
    end

    PLS_Net.toClient(player, "board", {
        board = board,
        rows = rows,
        total = #ranked,
        -- the player's own standing rides along, so the footer strip is right even when
        -- they are nowhere near the part of the board they can see.
        rank = rank,
        score = me and PLS_State.get(me, board) or 0,
    })
end

-- announce only a genuine change of first place. a leader change is recorded either way,
-- so the next comparison is against what is actually on the board.
local function PLS_checkLeader(board, ranked)
    local top = ranked[1]
    if not top then return end

    local previous = PLS_State.leader(board)
    local now = getTimestampMs()

    if previous and previous.name == top.name then
        -- same player, higher score. keep the record current without saying anything.
        PLS_State.setLeader(board, top.name, top.score, previous.at)
        return
    end

    local previousScore = previous and previous.score or 0
    local lastAt = previous and previous.at or 0

    -- strictly ahead, not merely level. someone who climbs into a tie and wins the
    -- alphabetical tie-break has not taken first place off anybody.
    local announce = top.score > previousScore
        and PLS.sandbox("AnnounceFirstPlace", true) == true

    if announce and lastAt > 0 then
        local cooldown = (tonumber(PLS.sandbox("AnnounceCooldownMinutes", 5)) or 5) * 60000
        if now - lastAt < cooldown then announce = false end
    end

    PLS_State.setLeader(board, top.name, top.score, announce and now or lastAt)

    if announce then
        PLS_Net.toAll("announce", { board = board, name = top.name, score = top.score })
    end
end

function PLS_Ranking.recompute(board)
    -- cleared here rather than only in the pump, so a direct call from a command does not
    -- leave a flag behind for the pump to redo three seconds later.
    PLS_State.dirty[board] = nil

    if not PLS_Boards.enabled(board) then return end

    local ranked = PLS_Ranking.ranked(board)
    local rows = PLS_wire(ranked)

    PLS_checkLeader(board, ranked)

    PLS_eachPlayer(function(player)
        PLS_Ranking.send(player, board, ranked, rows)
    end)
end

-- one player, every board. this is the handshake reply.
function PLS_Ranking.sendAll(player)
    if not player then return end

    for _, def in ipairs(PLS_Boards.ordered()) do
        local ranked = PLS_Ranking.ranked(def.key)
        PLS_Ranking.send(player, def.key, ranked, PLS_wire(ranked))
    end
end

local function PLS_pump()
    -- table.isempty, not next(): kahlua's BaseLib does not register next at all, so
    -- calling it is a call on a nil value. vanilla uses table.isempty for this.
    if table.isempty(PLS_State.dirty) then return end

    local now = getTimestampMs()
    if now - lastRecompute < RECOMPUTE_MS then return end
    lastRecompute = now

    local boards = {}
    for board in pairs(PLS_State.dirty) do boards[#boards + 1] = board end
    PLS_State.dirty = {}

    for _, board in ipairs(boards) do
        local ok, err = pcall(PLS_Ranking.recompute, board)
        if not ok then PLS.warn("recompute of " .. tostring(board) .. " failed: " .. tostring(err)) end
    end
end

-- EveryOneMinute, not OnTick. this is about one call a second at default day length
-- instead of sixty. GameTime fires it, so it runs on a dedicated server.
PLS.guard("board pump", Events.EveryOneMinute, PLS_pump)
