----------
--ESTRAL--
----------

require "PLS_Panel"

local BIND = "Toggle Leaderboard"

-- vanilla's Q radial splits a tap from a hold at the same figure. matching it means the
-- two do not ask for different timing from the same finger.
local HOLD_MS = 250

keyBinding = keyBinding or {}
table.insert(keyBinding, { value = "[Leaderboard]" })
table.insert(keyBinding, { value = BIND, key = Keyboard.KEY_RCONTROL })

local pressedMS = nil

local function PLS_boundKey()
    local key = getCore():getKey(BIND)
    -- unbound comes back as KEY_NONE, and matching that would fire on every stray key.
    if not key or key == Keyboard.KEY_NONE then return nil end
    return key
end

-- a bound key still reaches this handler while chat has focus, so without it somebody
-- typing into a message would have the panel opening underneath them.
local function PLS_blocked()
    if ISChat and ISChat.focused then return true end
    return false
end

local function PLS_onKeyStartPressed(key)
    if key ~= PLS_boundKey() then return end
    if PLS_blocked() then return end

    local player = getSpecificPlayer(0)
    if not player or player:isDead() then return end

    pressedMS = getTimestampMs()

    -- already open, so this press belongs to the release: it either taps the window shut
    -- or holds it where it is. opening it again here would only reset the pin.
    if PLS.isWindowOpen(0) then return end

    -- unpinned, because we do not know yet whether this is a tap or a hold. the release
    -- decides, and until then it is a peek.
    PLS.openPanel(player, false)
end

-- OnKeyPressed is the release, not the press.
local function PLS_onKeyReleased(key)
    if key ~= PLS_boundKey() then return end

    local at = pressedMS
    pressedMS = nil
    if not at then return end

    local window = PLS.getWindow(0)
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

Events.OnKeyStartPressed.Add(PLS_onKeyStartPressed)
Events.OnKeyPressed.Add(PLS_onKeyReleased)
