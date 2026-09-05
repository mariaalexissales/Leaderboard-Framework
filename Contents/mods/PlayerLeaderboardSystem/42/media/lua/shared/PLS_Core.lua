----------
--ESTRAL--
----------

PLS = PLS or {}

PLS.MODULE = "PLS"
PLS.SCHEMA_V = 1

PLS.Config = PLS.Config or {
    -- flip this if a dedicated server logs a nil attacker on the zombie kill path. the
    -- client reports its own vanilla kill counter instead, which is clamped but cheaper
    -- to cheat.
    clientKillReporting = false,

    -- per-kill tracing. off in anything shipped: a horde is a line a second per player.
    -- turn it on when a board is not filling and nothing is being logged, which is the
    -- shape a scoring bug takes here -- an early return that says nothing on its way out.
    verbose = false,
}

-- server/ lua loads on multiplayer clients too, and isServer() is false in singleplayer.
function PLS.isAuthority()
    return not (isClient() and not isServer())
end

function PLS.hasRemoteServer()
    return isClient() and not isServer()
end

-- the engine ships both spellings: Role.class has Admin/GM/Moderator, Roles.class has
-- admin/gm/moderator, and vanilla lua compares the lowercase one. normalising here stops a
-- case-sensitive test being a coin flip.
function PLS.accessLevel(player)
    if not player then return "none" end

    local level = player:getAccessLevel()
    if not level or level == "" then return "none" end

    return string.lower(level)
end

-- "may this player press the admin button". the old test asked whether there was a remote
-- server, which is false in the server process too, so on a dedicated server this returned
-- true before it ever looked at a role and handed the reset command to everybody. the
-- question is really "is there no multiplayer at all", and that is both flags off.
function PLS.isAdmin(player)
    if not isClient() and not isServer() then return true end
    if not player then return false end

    local level = PLS.accessLevel(player)
    return level == "admin" or level == "gm" or level == "moderator"
end

function PLS.warn(message)
    print("[PLS] WARN: " .. tostring(message))
end

-- the counterpart to warn, for the ordinary path rather than the broken one. a kill that is
-- deliberately not counted is not a fault and must not warn on every swing, but a scoring
-- path that says nothing at all cannot be told apart from one that is not running.
function PLS.trace(message)
    if not PLS.Config.verbose then return end
    print("[PLS] " .. tostring(message))
end

-- a handler that throws is simply called again on the next event, so one that fires on a
-- timer or on every swing can write a stack trace per call into console.txt for the rest
-- of the session. a server left running overnight is the case that hurts.
--
-- every repeating handler is registered through here instead. the first few failures are
-- logged with the actual reason, and then the handler takes itself back off the event.
-- a broken handler costs four lines and stops; the rest of the mod carries on.
local GUARD_LIMIT = 3

-- four parameters rather than varargs, because no vanilla lua forwards ... into pcall and
-- kahlua is not a lua this mod gets to assume things about. that covers every event we
-- guard; anything wider would silently drop its later arguments.
function PLS.guard(name, event, fn)
    local failures = 0
    local wrapped

    wrapped = function(a, b, c, d)
        local ok, err = pcall(fn, a, b, c, d)

        if ok then
            -- consecutive, not cumulative. an occasional hiccup should not retire a
            -- handler that works, and the failures worth stopping for -- a nil global, a
            -- bad field -- fail on every single call and trip this immediately.
            failures = 0
            return
        end

        failures = failures + 1
        PLS.warn(name .. " failed: " .. tostring(err))

        if failures >= GUARD_LIMIT then
            PLS.warn(name .. " has failed " .. GUARD_LIMIT
                .. " times in a row and is stopped for the rest of this session")
            event.Remove(wrapped)
        end
    end

    event.Add(wrapped)
    return wrapped
end

-- SandboxVars is nil until the world loads, and the client's copy arrives a little after
-- the lua does, so every read goes through here rather than indexing it directly.
function PLS.sandbox(name, fallback)
    local vars = SandboxVars and SandboxVars.PlayerLeaderboardSystem
    if not vars then return fallback end

    local value = vars[name]
    if value == nil then return fallback end
    return value
end

-- every score is keyed by this. getUsername is the account name on a server and is what
-- has to survive a death, but singleplayer leaves it empty, so a solo game falls back to
-- the character's own name and scores per character instead.
function PLS.nameOf(player)
    if not player then return nil end

    local username = player:getUsername()
    if username and username ~= "" then return username end

    local descriptor = player:getDescriptor()
    if descriptor then
        local forename = descriptor:getForename() or ""
        local surname = descriptor:getSurname() or ""
        local full = (forename .. " " .. surname):gsub("^%s+", ""):gsub("%s+$", "")
        if full ~= "" then return full end
    end

    return nil
end
