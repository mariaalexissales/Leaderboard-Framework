----------
--ESTRAL--
----------

PLS = PLS or {}

PLS.MODULE = "PLS"
PLS.SCHEMA_V = 1

PLS.Config = PLS.Config or {
    -- flip if a dedicated server logs a nil attacker on the zombie kill path. the client
    -- reports its own vanilla counter instead: clamped, but cheaper to cheat.
    clientKillReporting = false,

    -- per-kill tracing. off in anything shipped -- a horde is a line a second per player.
    -- turn on when a board is not filling and nothing is logged, which is the shape a scoring
    -- bug takes here: an early return that says nothing on its way out.
    verbose = false,
}

-- server/ lua loads on multiplayer clients too, and isServer() is false in singleplayer.
function PLS.isAuthority()
    return not (isClient() and not isServer())
end

function PLS.hasRemoteServer()
    return isClient() and not isServer()
end

-- the engine ships both spellings -- Role.class has Admin/GM/Moderator, Roles.class has
-- lowercase, and vanilla compares the lowercase one. normalising stops a case-sensitive test
-- being a coin flip.
function PLS.accessLevel(player)
    if not player then return "none" end

    local level = player:getAccessLevel()
    if not level or level == "" then return "none" end

    return string.lower(level)
end

-- the question is "is there no multiplayer at all", which is both flags off. the old test
-- asked for a remote server -- false in the server process too, so on a dedicated server this
-- returned true before looking at a role and handed reset to everybody.
function PLS.isAdmin(player)
    if not isClient() and not isServer() then return true end
    if not player then return false end

    local level = PLS.accessLevel(player)
    return level == "admin" or level == "gm" or level == "moderator"
end

function PLS.warn(message)
    print("[PLS] WARN: " .. tostring(message))
end

-- for the ordinary path, where warn is for the broken one. a kill deliberately not counted is
-- not a fault and must not warn on every swing, but a scoring path that says nothing cannot be
-- told from one that is not running.
function PLS.trace(message)
    if not PLS.Config.verbose then return end
    print("[PLS] " .. tostring(message))
end

-- a handler that throws is just called again next event, so one on a timer or every swing can
-- write a stack trace per call into console.txt all session -- a server left running overnight
-- is the case that hurts. every repeating handler registers through here: the first few
-- failures are logged with the reason, then the handler takes itself off the event.
local GUARD_LIMIT = 3

-- four parameters rather than varargs: no vanilla lua forwards ... into pcall, and kahlua is
-- not a lua to assume things about. anything wider would silently drop later arguments.
function PLS.guard(name, event, fn)
    local failures = 0
    local wrapped

    wrapped = function(a, b, c, d)
        local ok, err = pcall(fn, a, b, c, d)

        if ok then
            -- consecutive, not cumulative: a hiccup should not retire a working handler, and
            -- the failures worth stopping for fail on every call and trip this at once.
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

-- SandboxVars is nil until the world loads, and the client's copy arrives after the lua, so
-- every read goes through here rather than indexing it directly.
function PLS.sandbox(name, fallback)
    local vars = SandboxVars and SandboxVars.PlayerLeaderboardSystem
    if not vars then return fallback end

    local value = vars[name]
    if value == nil then return fallback end
    return value
end

-- how often one player's refresh is answered. read by both ends: the server enforces it, the
-- client paces its asks to match so they are not sent just to be dropped. floored at a second
-- whatever the sandbox says, since every answer is a packet per board.
function PLS.refreshCooldownMs()
    local seconds = tonumber(PLS.sandbox("RefreshCooldownSeconds", 1)) or 1
    if seconds < 1 then seconds = 1 end
    return seconds * 1000
end

-- wall clock, in epoch milliseconds. the in-session cooldowns use getTimestampMs, but a stamp
-- written into the backup by one process is read by another, and only a real calendar time
-- means the same thing in both. falls back rather than failing.
function PLS.now()
    local ok, ms = pcall(function() return Calendar.getInstance():getTimeInMillis() end)
    if ok and type(ms) == "number" and ms > 0 then return ms end

    return getTimestampMs()
end

-- epoch milliseconds to "YYYY-MM-DD HH:MM:SS UTC". only ever read by a human, so being wrong
-- by a timezone matters less than being unable to compute it at all -- hence the arithmetic
-- rather than Calendar's field constants.
function PLS.stampText(ms)
    local secs = math.floor((tonumber(ms) or 0) / 1000)
    local days = math.floor(secs / 86400)
    local rest = secs - days * 86400

    -- days-to-civil, the shift-to-March form: leap years land at the end of the cycle and
    -- stop being a special case.
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
        - math.floor(doe / 146096)) / 365)
    local year = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local day = doy - math.floor((153 * mp + 2) / 5) + 1
    local month = mp + (mp < 10 and 3 or -9)

    if month <= 2 then year = year + 1 end

    return string.format("%04d-%02d-%02d %02d:%02d:%02d UTC", year, month, day,
        math.floor(rest / 3600), math.floor(rest / 60) % 60, rest % 60)
end

-- every score is keyed by this. getUsername is the account name on a server and survives a
-- death, but singleplayer leaves it empty, so a solo game scores per character instead.
local function PLS_characterName(player)
    local descriptor = player:getDescriptor()
    if not descriptor then return nil end

    local forename = descriptor:getForename() or ""
    local surname = descriptor:getSurname() or ""
    local full = (forename .. " " .. surname):gsub("^%s+", ""):gsub("%s+$", "")

    if full == "" then return nil end
    return full
end

function PLS.nameOf(player)
    if not player then return nil end

    -- asked first, not as a fallback: b42 answers getUsername in singleplayer too, with the
    -- names run together -- "JudieHolman" is nobody's name, and it is what used to reach the
    -- board. both flags off is the no-multiplayer test PLS.isAdmin uses, and it covers a
    -- splitscreen second player, who gets their own character's name.
    if not isClient() and not isServer() then
        local character = PLS_characterName(player)
        if character then return character end
    end

    local username = player:getUsername()
    if username and username ~= "" then return username end

    return PLS_characterName(player)
end
