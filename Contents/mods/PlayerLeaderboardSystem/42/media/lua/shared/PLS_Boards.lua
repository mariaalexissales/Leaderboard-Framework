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
--   key        the name the score is stored under. must be unique.
--   order      left-to-right tab position.
--   title      IGUI_ translation key for the tab.
--   unit       IGUI_ translation key for what the number counts.
--   sandbox    option name under SandboxVars.PlayerLeaderboardSystem that gates the board.
--              omit it and the board is always on.
--
-- the panel draws one row of tabs, kill type on the left and scope on the right, so a board
-- also says where it sits in it:
--
--   group      which left-hand tab the board belongs to. defaults to the key, which makes a
--              board registered without one a group of itself and draws it as the single
--              tab it has always been.
--   groupTitle IGUI_ key for that left-hand tab. taken from the group's first board.
--   scope      which right-hand tab, within the group. "life" or "account" here; only
--              meaningful once a group holds more than one board.
--   announce   IGUI_ key for the board's full name in chat, where a tab label like
--              "Per Life" says nothing on its own. defaults to title.
--   requires   a second sandbox option that must also be on. a per-life board rides on its
--              kind being tracked at all.
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
    def.group = def.group or def.key
    def.announce = def.announce or def.title

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

    -- checked before the board's own switch, so a server that has turned player kills off
    -- cannot be handed a player kills board back through the per-life door.
    if def.requires and PLS.sandbox(def.requires, false) ~= true then return false end

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

-- the left-hand tabs: one entry per group, in the order of its earliest board. ordered() is
-- already sorted, so first appearance is lowest order and there is nothing to sort again.
function PLS_Boards.groups()
    local seen = {}
    local list = {}

    for _, def in ipairs(PLS_Boards.ordered()) do
        if not seen[def.group] then
            seen[def.group] = true
            list[#list + 1] = { key = def.group, title = def.groupTitle or def.title }
        end
    end

    return list
end

-- the right-hand tabs: the enabled boards inside one group, in order. a group holding one
-- board draws no scope tab at all, which is what a third-party board gets.
function PLS_Boards.scopes(group)
    local list = {}

    for _, def in ipairs(PLS_Boards.ordered()) do
        if def.group == group then list[#list + 1] = def end
    end

    return list
end

-- a group and a scope back to the board key they name, enabled or not. the credit path
-- leans on this as much as the panel does: a kill's kind is its group, so one kill can find
-- both of its boards without either key being written down a second time.
function PLS_Boards.find(group, scope)
    if not group or not scope then return nil end

    for key, def in pairs(PLS_Boards.defs) do
        if def.group == group and def.scope == scope then return key end
    end

    return nil
end

-- whether a group has any board left switched on. what a kill of that kind is worth asking
-- before it is worth counting, and the reason it is a group rather than a key: turning the
-- account board off must not quietly take the per-life one down with it.
function PLS_Boards.tracked(group)
    if not group then return false end

    for key, def in pairs(PLS_Boards.defs) do
        if def.group == group and PLS_Boards.enabled(key) then return true end
    end

    return false
end

-- whether anything at all is keeping a per-life count. the death packet is gated on this at
-- both ends, and the test lives here so the client and the server ask one question.
function PLS_Boards.anyLife()
    for key, def in pairs(PLS_Boards.defs) do
        if def.scope == "life" and PLS_Boards.enabled(key) then return true end
    end

    return false
end

-- per life sits left of all time in both groups, so the panel opens on the board that
-- rewards the run somebody is on rather than the one a thousand hours already decided.
PLS_Boards.register({
    key = "zombieLife",
    order = 1,
    group = "zombie",
    groupTitle = "IGUI_PLS_BoardZombie",
    scope = "life",
    title = "IGUI_PLS_ScopeLife",
    announce = "IGUI_PLS_BoardZombieLife",
    unit = "IGUI_PLS_UnitKills",
    sandbox = "TrackZombieKillsPerLife",
    requires = "TrackZombieKills",
})

PLS_Boards.register({
    key = "zombie",
    order = 2,
    group = "zombie",
    groupTitle = "IGUI_PLS_BoardZombie",
    scope = "account",
    title = "IGUI_PLS_ScopeAccount",
    announce = "IGUI_PLS_BoardZombie",
    unit = "IGUI_PLS_UnitKills",
    sandbox = "TrackZombieKills",
})

PLS_Boards.register({
    key = "pvpLife",
    order = 3,
    group = "pvp",
    groupTitle = "IGUI_PLS_BoardPvP",
    scope = "life",
    title = "IGUI_PLS_ScopeLife",
    announce = "IGUI_PLS_BoardPvPLife",
    unit = "IGUI_PLS_UnitKills",
    sandbox = "TrackPlayerKillsPerLife",
    requires = "TrackPlayerKills",
})

PLS_Boards.register({
    key = "pvp",
    order = 4,
    group = "pvp",
    groupTitle = "IGUI_PLS_BoardPvP",
    scope = "account",
    title = "IGUI_PLS_ScopeAccount",
    announce = "IGUI_PLS_BoardPvP",
    unit = "IGUI_PLS_UnitKills",
    sandbox = "TrackPlayerKills",
})
