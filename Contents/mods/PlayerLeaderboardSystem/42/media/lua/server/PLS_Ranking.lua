----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Net"
require "PLS_Boards"
require "PLS_State"

if not PLS.isAuthority() then return end

PLS_Ranking = PLS_Ranking or {}

-- a horde is a kill a second per player, and every one would rebuild and push the board.
-- EveryOneMinute runs on game time and sprints while a player sleeps, so the real clock holds
-- the cadence, not the event.
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
-- one board, sorted, answering every question asked of it at once: the top rows, a player's
-- rank, who is first, where a score would place. only the top rows need an ordering, and each
-- used to re-sort the whole table for itself.
--
-- sorts names, not {name, score} rows, so a rebuild allocates a handful of tables rather than
-- one per ranked player. everything else reads score[name].
local cache = {}

local function PLS_build(board)
    -- read before the work: the view must be stamped with the version it was built from.
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
        -- ties broken by name, so two players on the same score cannot trade places
        -- between sorts.
        return a < b
    end)

    -- built once here instead of rediscovered by walking this list for every online player
    -- on every push, which was the cost of a board update on a busy server.
    local rankOf = {}
    for i = 1, #names do rankOf[names[i]] = i end

    -- dense from 1, short keys: this goes over the wire to everybody. BoardSize is read here
    -- so the two callers cannot disagree.
    local limit = tonumber(PLS.sandbox("BoardSize", 10)) or 10
    local rows = {}
    for i = 1, math.min(#names, limit) do
        rows[i] = { n = names[i], s = score[names[i]] }
    end

    return { at = at, names = names, score = score, rankOf = rankOf, rows = rows, total = #names }
end

-- rebuilt only when the standings actually moved. markDirty's counter keeps climbing after the
-- dirty flag is drained, which is what lets a view tell whether it has been overtaken.
local function PLS_view(board)
    local view = cache[board]
    if view and view.at == (PLS_State.version[board] or 0) then return view end

    view = PLS_build(board)
    cache[board] = view

    return view
end

-- who is first right now. PLS_State.leader is a different question: who was last announced.
function PLS_Ranking.topOf(board)
    local view = PLS_view(board)

    local name = view.names[1]
    if not name then return nil end

    return name, view.score[name]
end

-- where a score would place: one past everyone strictly above it.
--
-- strictly matters. a player dying on the run that set their record sits on the board equal to
-- it, and must place at their own rank rather than one below.
function PLS_Ranking.placeOf(board, score)
    score = tonumber(score) or 0

    local view = PLS_view(board)
    local names, by = view.names, view.score

    -- already ordered, so this is a search not a count. lo settles on the first entry not
    -- strictly above us; one past the end when everybody is, which is also right.
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
        -- their own standing rides along, so the footer is right even when they are nowhere
        -- near the visible part. nil when they are not on the board.
        rank = me and view.rankOf[me],
        -- read past the view: someone under MinScoreToRank is off the board but still owed
        -- the number they have.
        score = me and PLS_State.get(me, board) or 0,
    })
end

-- announce only a genuine change of first place. the change is recorded either way, so the
-- next comparison is against what is actually on the board.
local function PLS_checkLeader(board, view)
    local topName = view.names[1]
    if not topName then return end

    local topScore = view.score[topName]

    local previous = PLS_State.leader(board)
    local now = getTimestampMs()

    if previous and previous.name == topName then
        -- same player, higher score. keep the record current, say nothing.
        PLS_State.setLeader(board, topName, topScore, previous.at)
        return
    end

    local previousScore = previous and previous.score or 0
    local lastAt = previous and previous.at or 0

    -- strictly ahead, not level: winning the alphabetical tie-break takes first place off
    -- nobody.
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
    -- cleared here, not only in the pump, so a direct call from a command leaves no flag
    -- behind for the pump to redo.
    PLS_State.dirty[board] = nil

    if not PLS_Boards.enabled(board) then return end

    -- built once for everybody, so the wire rows and every player's rank cannot disagree.
    local view = PLS_view(board)

    PLS_checkLeader(board, view)

    PLS_eachPlayer(function(player)
        PLS_Ranking.send(player, board, view)
    end)
end

-- the handshake reply. answered out of the cache, so nothing here sorts. ordered() has already
-- dropped the boards that are switched off.
function PLS_Ranking.sendAll(player)
    if not player then return end

    for _, def in ipairs(PLS_Boards.ordered()) do
        PLS_Ranking.send(player, def.key, PLS_view(def.key))
    end
end

local function PLS_pump()
    -- table.isempty, not next(): kahlua's BaseLib does not register next at all, so calling
    -- it is a call on a nil value.
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

-- EveryOneMinute, not OnTick: about one call a second at default day length instead of sixty.
-- GameTime fires it, so it runs on a dedicated server.
PLS.guard("board pump", Events.EveryOneMinute, PLS_pump)
