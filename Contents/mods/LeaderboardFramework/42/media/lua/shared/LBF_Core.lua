----------
--ESTRAL--
----------

LBF = LBF or {}

LBF.MODULE = "LBF"
LBF.SCHEMA_V = 1

LBF.Config = LBF.Config or {
    -- flip this if a dedicated server logs a nil attacker on the zombie kill path. the
    -- client reports its own vanilla kill counter instead, which is clamped but cheaper
    -- to cheat.
    clientKillReporting = false,
}

-- server/ lua loads on multiplayer clients too, and isServer() is false in singleplayer.
function LBF.isAuthority()
    return not (isClient() and not isServer())
end

function LBF.hasRemoteServer()
    return isClient() and not isServer()
end

function LBF.isAdmin(player)
    if not LBF.hasRemoteServer() then return true end
    if not player then return false end

    local level = player:getAccessLevel()
    return level == "Admin" or level == "GM" or level == "Moderator"
end

function LBF.log(message)
    print("[LBF] " .. tostring(message))
end

function LBF.warn(message)
    print("[LBF] WARN: " .. tostring(message))
end

-- getText on a missing key returns the key, which would print IGUI_LBF_BoardPvP in the UI.
function LBF.text(key, fallback)
    local value = getTextOrNull(key)
    if value and value ~= "" then return value end
    return fallback or key
end

-- SandboxVars is nil until the world loads, and the client's copy arrives a little after
-- the lua does, so every read goes through here rather than indexing it directly.
function LBF.sandbox(name, fallback)
    local vars = SandboxVars and SandboxVars.LeaderboardFramework
    if not vars then return fallback end

    local value = vars[name]
    if value == nil then return fallback end
    return value
end

-- every score is keyed by this. getUsername is the account name on a server and is what
-- has to survive a death, but singleplayer leaves it empty, so a solo game falls back to
-- the character's own name and scores per character instead.
function LBF.nameOf(player)
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
