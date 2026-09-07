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

-- ----------------------------------------------------------------------------
-- the view
-- ----------------------------------------------------------------------------
--
-- one board, sorted, with everything anybody asks of it worked out at the same time.
--
-- four questions used to each rebuild and re-sort the whole table for themselves: the top ten,
-- one player's rank, who is first, and where a score would place. only the first of those needs
-- an ordering at all, and none of them needed a copy of their own -- on a full server that was a
-- sort per death, per join, and per push, plus a scan of every player for every player.
--
-- the sort is over an array of names rather than one of {name, score} rows, so a rebuild
-- allocates a handful of tables instead of one per ranked player. everything reads score[name].
local cache = {}

local function PLS_build(board)
    -- read before the work, not after: the number this view is answered against has to be the
    -- one that was current when it was built.
    local at = PLS_State.version[board] or 0

    local data = PLS_State.ensure()
    local floor = tonumber(PLS.sandbox("MinScoreToRank", 1)) or 1

    local names, score = {}, {}

    for username, entry in pairs(data.players) do
        local value = entry[board]
        if value and value >= floor then
            names[#names + 1] = username
            score[username] = value
        end
    end

    table.sort(names, function(a, b)
        local sa, sb = score[a], score[b]
        if sa ~= sb then return sa > sb end
        -- ties broken by name so the order is fixed. two players sitting on the same
        -- score must not be able to trade first place back and forth between sorts.
        return a < b
    end)

    -- rank by name, built once here rather than rediscovered by walking this list for every
    -- online player on every push. that walk was the cost of a board update on a busy server:
    -- one pass here replaces one pass per player.
    local rankOf = {}
    for i = 1, #names do rankOf[names[i]] = i end

    -- dense from 1 and short keys: this goes over the wire on every recompute, to everybody.
    -- BoardSize is read here rather than passed in, so the two callers cannot disagree.
    local limit = tonumber(PLS.sandbox("BoardSize", 10)) or 10
    local rows = {}
    for i = 1, math.min(#names, limit) do
        rows[i] = { n = names[i], s = score[names[i]] }
    end

    return { at = at, names = names, score = score, rankOf = rankOf, rows = rows, total = #names }
end

-- rebuilt only when the board's standings have actually moved. PLS_State.markDirty counts those
-- moves, and the count keeps climbing after the dirty flag has been drained, which is what lets
-- a view built at any point still tell whether it has been overtaken.
local function PLS_view(board)
    local view = cache[board]
    if view and view.at == (PLS_State.version[board] or 0) then return view end

    view = PLS_build(board)
    cache[board] = view

    return view
end

-- who is first as the standings stand. PLS_State.leader is a different question -- it is the
-- record of who was last announced -- so this is topOf rather than leader.
function PLS_Ranking.topOf(board)
    local view = PLS_view(board)

    local name = view.names[1]
    if not name then return nil end

    return name, view.score[name]
end

-- where a score of this size would sit on a board, without it having to be anybody's. one
-- past everyone strictly above it.
--
-- strictly is the whole of it. a player dying on the very run that set their record has an
-- entry on the board equal to that run, and must place at their own rank rather than one
-- below it -- which is also why "the run that just ended places top three" is a tighter
-- question than "this player is top three", and the one worth announcing.
function PLS_Ranking.placeOf(board, score)
    score = tonumber(score) or 0

    local view = PLS_view(board)
    local names, by = view.names, view.score

    -- the list is in order already, so this is a search and not a count. lo settles on the
    -- first entry not strictly above us, and that index is the place we take -- one past the
    -- end when everybody is above, which is the right answer too.
    local lo, hi = 1, #names + 1

    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if by[names[mid]] > score then lo = mid + 1 else hi = mid end
    end

    return lo
end

function PLS_Ranking.send(player, board, view)
    if not player then return end

    local me = PLS.nameOf(player)

    PLS_Net.toClient(player, "board", {
        board = board,
        rows = view.rows,
        total = view.total,
        -- the player's own standing rides along, so the footer strip is right even when
        -- they are nowhere near the part of the board they can see. nil when they are not on
        -- the board at all, exactly as the scan it replaces left it.
        rank = me and view.rankOf[me],
        -- their real score, read past the view rather than out of it: somebody under
        -- MinScoreToRank is not on the board but is still owed the number they have.
        score = me and PLS_State.get(me, board) or 0,
    })
end

-- announce only a genuine change of first place. a leader change is recorded either way,
-- so the next comparison is against what is actually on the board.
local function PLS_checkLeader(board, view)
    local topName = view.names[1]
    if not topName then return end

    local topScore = view.score[topName]

    local previous = PLS_State.leader(board)
    local now = getTimestampMs()

    if previous and previous.name == topName then
        -- same player, higher score. keep the record current without saying anything.
        PLS_State.setLeader(board, topName, topScore, previous.at)
        return
    end

    local previousScore = previous and previous.score or 0
    local lastAt = previous and previous.at or 0

    -- strictly ahead, not merely level. someone who climbs into a tie and wins the
    -- alphabetical tie-break has not taken first place off anybody.
    local announce = topScore > previousScore
        and PLS.sandbox("AnnounceFirstPlace", true) == true

    if announce and lastAt > 0 then
        local cooldown = (tonumber(PLS.sandbox("AnnounceCooldownMinutes", 5)) or 5) * 60000
        if now - lastAt < cooldown then announce = false end
    end

    PLS_State.setLeader(board, topName, topScore, announce and now or lastAt)

    if announce then
        PLS_Net.toAll("announce", { board = board, name = topName, score = topScore })
    end
end

function PLS_Ranking.recompute(board)
    -- cleared here rather than only in the pump, so a direct call from a command does not
    -- leave a flag behind for the pump to redo three seconds later.
    PLS_State.dirty[board] = nil

    if not PLS_Boards.enabled(board) then return end

    -- built once for everybody. the rows on the wire and every player's own rank come out of
    -- the same view, so they cannot disagree and it cannot be sorted twice.
    local view = PLS_view(board)

    PLS_checkLeader(board, view)

    PLS_eachPlayer(function(player)
        PLS_Ranking.send(player, board, view)
    end)
end

-- one player, every board. this is the handshake reply, and on a server that has been up a
-- while it is answered entirely out of the cache: nothing here has to sort anything.
-- ordered() has already dropped the boards that are switched off.
function PLS_Ranking.sendAll(player)
    if not player then return end

    for _, def in ipairs(PLS_Boards.ordered()) do
        PLS_Ranking.send(player, def.key, PLS_view(def.key))
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
