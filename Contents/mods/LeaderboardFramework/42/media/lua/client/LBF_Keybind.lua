----------
--ESTRAL--
----------

require "LBF_Panel"

local BIND = "Toggle Leaderboard"

-- under this and it was a tap, over it and it was a hold. the same threshold vanilla's
-- emote radial uses to tell a shout from a menu.
local HOLD_MS = 250

keyBinding = keyBinding or {}
table.insert(keyBinding, { value = "[Leaderboard]" })
table.insert(keyBinding, { value = BIND, key = Keyboard.KEY_TAB })

local pressedMS = nil

local function LBF_boundKey()
    local key = getCore():getKey(BIND)
    -- unbound comes back as KEY_NONE, and matching that would fire on every stray key.
    if not key or key == Keyboard.KEY_NONE then return nil end
    return key
end

-- tab already carries two vanilla binds: "Toggle mode" while a cursor is up, and
-- "Switch chat stream" while the chat entry has focus. both of those only matter in a
-- state we can see from here, so the leaderboard stands aside in exactly those two
-- rather than taking the key off them outright.
local function LBF_blocked()
    if ISChat and ISChat.focused then return true end

    local cell = getCell()
    if cell and cell:getDrag(0) then return true end

    return false
end

local function LBF_onKeyStartPressed(key)
    if key ~= LBF_boundKey() then return end
    if LBF_blocked() then return end

    local player = getSpecificPlayer(0)
    if not player or player:isDead() then return end

    pressedMS = getTimestampMs()

    -- already open, so this press belongs to the release: it either taps the window shut
    -- or holds it where it is. opening it again here would only reset the pin.
    if LBF.isWindowOpen(0) then return end

    -- unpinned, because we do not know yet whether this is a tap or a hold. the release
    -- decides, and until then it is a peek.
    LBF.openPanel(player, false)
end

-- OnKeyPressed is the release, not the press.
local function LBF_onKeyReleased(key)
    if key ~= LBF_boundKey() then return end

    local at = pressedMS
    pressedMS = nil
    if not at then return end

    local window = LBF.getWindow(0)
    if not window then return end

    if getTimestampMs() - at < HOLD_MS then
        -- a tap. it pins a peek open, and closes a window that was already pinned.
        if window.pinned then
            window:close()
        else
            window.pinned = true
        end
        return
    end

    -- a hold, which was only ever a peek. a window that was already pinned before the key
    -- went down stays where it is; holding the key over it should not shut it.
    if not window.pinned then window:close() end
end

Events.OnKeyStartPressed.Add(LBF_onKeyStartPressed)
Events.OnKeyPressed.Add(LBF_onKeyReleased)
