----------
--ESTRAL--
----------

require "LBF_Core"

LBF = LBF or {}
LBF_Boards = LBF_Boards or {}

LBF_Boards.defs = LBF_Boards.defs or {}

-- another mod can call this from its own shared/ file to add a board. it gets a column in
-- the panel and a first-place broadcast for free; all it has to do afterwards is call
-- LBF_State.add(username, key, n) on the server when its own thing happens.
--
--   key      the name the score is stored under. must be unique.
--   order    left-to-right tab position.
--   title    IGUI_ translation key for the tab.
--   unit     IGUI_ translation key for what the number counts.
--   sandbox  option name under SandboxVars.LeaderboardFramework that gates the board.
--            omit it and the board is always on.
function LBF_Boards.register(def)
    if not def or not def.key then
        LBF.warn("a board was registered without a key")
        return
    end

    if LBF_Boards.defs[def.key] then
        LBF.warn("board " .. def.key .. " is already registered, ignoring the second one")
        return
    end

    def.order = def.order or 100
    def.title = def.title or ("IGUI_LBF_Board_" .. def.key)
    def.unit = def.unit or "IGUI_LBF_UnitKills"

    LBF_Boards.defs[def.key] = def
end

function LBF_Boards.get(key)
    return key and LBF_Boards.defs[key] or nil
end

-- read at call time, never cached: SandboxVars is nil while lua is still loading, and on a
-- client it arrives a beat after that.
function LBF_Boards.enabled(key)
    local def = LBF_Boards.get(key)
    if not def then return false end
    if not def.sandbox then return true end

    return LBF.sandbox(def.sandbox, false) == true
end

local function LBF_byOrder(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.key < b.key
end

-- every board, gate or no gate. the server scores into these.
function LBF_Boards.all()
    local list = {}
    for _, def in pairs(LBF_Boards.defs) do list[#list + 1] = def end
    table.sort(list, LBF_byOrder)
    return list
end

-- only the boards the sandbox has switched on. the panel draws these.
function LBF_Boards.ordered()
    local list = {}
    for key, def in pairs(LBF_Boards.defs) do
        if LBF_Boards.enabled(key) then list[#list + 1] = def end
    end
    table.sort(list, LBF_byOrder)
    return list
end

LBF_Boards.register({
    key = "zombie",
    order = 1,
    title = "IGUI_LBF_BoardZombie",
    unit = "IGUI_LBF_UnitKills",
    sandbox = "TrackZombieKills",
})

LBF_Boards.register({
    key = "pvp",
    order = 2,
    title = "IGUI_LBF_BoardPvP",
    unit = "IGUI_LBF_UnitKills",
    sandbox = "TrackPlayerKills",
})
