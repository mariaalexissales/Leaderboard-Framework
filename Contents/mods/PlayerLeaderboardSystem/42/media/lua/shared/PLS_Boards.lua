----------
--ESTRAL--
----------

require "PLS_Core"

PLS_Boards = PLS_Boards or {}

PLS_Boards.defs = PLS_Boards.defs or {}

-- another mod can call this from its own shared/ file to add a board. it gets a column in
-- the panel and a first-place broadcast for free; all it has to do afterwards is call
-- PLS_State.add(username, key, n) on the server when its own thing happens.
--
--   key      the name the score is stored under. must be unique.
--   order    left-to-right tab position.
--   title    IGUI_ translation key for the tab.
--   unit     IGUI_ translation key for what the number counts.
--   sandbox  option name under SandboxVars.PlayerLeaderboardSystem that gates the board.
--            omit it and the board is always on.
function PLS_Boards.register(def)
    if not def or not def.key then
        PLS.warn("a board was registered without a key")
        return
    end

    if PLS_Boards.defs[def.key] then
        PLS.warn("board " .. def.key .. " is already registered, ignoring the second one")
        return
    end

    def.order = def.order or 100
    def.title = def.title or ("IGUI_PLS_Board_" .. def.key)
    def.unit = def.unit or "IGUI_PLS_UnitKills"

    PLS_Boards.defs[def.key] = def
end

function PLS_Boards.get(key)
    return key and PLS_Boards.defs[key] or nil
end

-- read at call time, never cached: SandboxVars is nil while lua is still loading, and on a
-- client it arrives a beat after that.
function PLS_Boards.enabled(key)
    local def = PLS_Boards.get(key)
    if not def then return false end
    if not def.sandbox then return true end

    return PLS.sandbox(def.sandbox, false) == true
end

local function PLS_byOrder(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.key < b.key
end

-- only the boards the sandbox has switched on. the panel draws these.
function PLS_Boards.ordered()
    local list = {}
    for key, def in pairs(PLS_Boards.defs) do
        if PLS_Boards.enabled(key) then list[#list + 1] = def end
    end
    table.sort(list, PLS_byOrder)
    return list
end

PLS_Boards.register({
    key = "zombie",
    order = 1,
    title = "IGUI_PLS_BoardZombie",
    unit = "IGUI_PLS_UnitKills",
    sandbox = "TrackZombieKills",
})

PLS_Boards.register({
    key = "pvp",
    order = 2,
    title = "IGUI_PLS_BoardPvP",
    unit = "IGUI_PLS_UnitKills",
    sandbox = "TrackPlayerKills",
})
