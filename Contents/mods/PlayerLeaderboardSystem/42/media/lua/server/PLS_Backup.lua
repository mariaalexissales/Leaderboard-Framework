----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Json"
require "PLS_Boards"
require "PLS_State"

if not PLS.isAuthority() then return end

PLS_Backup = PLS_Backup or {}

-- the scores live in global mod data, which the engine writes into global_mod_data.bin inside
-- the world save. that is the whole problem this file exists for:
--
--   a process killed rather than shut down never writes it, so a session's scoring is lost
--   a rollback restores the save, and takes the leaderboard back with it
--
-- neither is fixable from inside the save, so this keeps a second copy outside it. reading it
-- back is an admin typing /pls restore, never automatic: nothing here compares the file
-- against the live table, which is what lets the scores stay free of a per-kill clock.

local FILE_V = 1

-- the text of the file as it stands on disk, carried since boot so the rotation does not have
-- to read it back before overwriting.
local lastText = nil

-- when the file was last written, and what PLS_State.changes was then.
local savedAt = nil
local savedChanges = nil

-- off unless a server owner asks for it. read per call rather than cached, so the option can
-- be flipped mid-session. the two admin commands deliberately do not consult this: somebody
-- typing /pls backup wants the file written.
function PLS_Backup.enabled()
    return PLS.sandbox("BackupEnabled", false) == true
end

-- ----------------------------------------------------------------------------
-- the file
-- ----------------------------------------------------------------------------

-- a relative path here lands in Zomboid/Lua, not the Zomboid root -- that is where the lua
-- file api puts things. FOLDER below is only ever for saying so out loud; the api takes the
-- bare name.
--
-- what matters is that it is not inside the save folder. a backup kept there is rolled back
-- with the very thing it is supposed to survive. named by world so two of them on one host
-- cannot overwrite each other, and sanitised because that name becomes a filename.
function PLS_Backup.world()
    local ok, name = pcall(function() return getWorld():getWorld() end)
    if ok and type(name) == "string" and name ~= "" then return name end

    return "world"
end

local function PLS_stem()
    return "pls_scores_" .. string.gsub(PLS_Backup.world(), "[^%w%-_]", "_")
end

function PLS_Backup.path()
    return PLS_stem() .. ".json"
end

-- the copy before this one. a second .json and not a .bak: the file api only opens ini, cfg,
-- txt, log and json, and asked for anything else it hands back nothing and logs nothing.
function PLS_Backup.sparePath()
    return PLS_stem() .. "_prev.json"
end

-- where that path actually resolves to, for a human being told about it. never passed to the
-- file api, which would then create a Lua/Lua folder.
PLS_Backup.FOLDER = "Zomboid/Lua/"

function PLS_Backup.shownPath(path)
    return PLS_Backup.FOLDER .. (path or PLS_Backup.path())
end

local function PLS_read(path)
    -- false, so a missing file comes back nil instead of being created empty.
    local reader = getFileReader(path, false)
    if not reader then return nil end

    local lines = {}
    local ok = pcall(function()
        local line = reader:readLine()
        while line do
            lines[#lines + 1] = line
            line = reader:readLine()
        end
    end)

    pcall(function() reader:close() end)

    if not ok then return nil end
    return table.concat(lines, "\n")
end

local function PLS_write(path, text)
    local writer = getFileWriter(path, true, false)
    if not writer then return false end

    local ok = pcall(function() writer:write(text) end)
    pcall(function() writer:close() end)

    return ok
end

-- ----------------------------------------------------------------------------
-- writing
-- ----------------------------------------------------------------------------

function PLS_Backup.snapshot()
    local data = PLS_State.ensure()
    local now = PLS.now()

    return {
        v = FILE_V,
        world = PLS_Backup.world(),
        savedAt = now,
        -- for whoever opens the file. never read back.
        savedAtText = PLS.stampText(now),
        players = data.players,
        lives = data.lives,
        leaders = data.leaders,
    }
end

function PLS_Backup.save()
    local path = PLS_Backup.path()

    local ok, text = pcall(PLS_Json.encode, PLS_Backup.snapshot())
    if not ok or type(text) ~= "string" then
        PLS.warn("could not encode the score backup: " .. tostring(text))
        return false
    end

    -- the previous payload goes to the spare before the main file is touched. a process
    -- killed between these two writes -- the exact failure this file exists for -- leaves the
    -- spare whole and only the main file torn, which is what read() below is prepared for.
    if lastText then PLS_write(PLS_Backup.sparePath(), lastText) end

    if not PLS_write(path, text) then
        PLS.warn("could not write the score backup to " .. path)
        return false
    end

    lastText = text
    savedAt = getTimestampMs()
    savedChanges = PLS_State.changes

    return true, path
end

-- a dedicated server has no save event to hang this on: OnSave is fired by the client's own
-- save and by nothing in the server's, which writes the world without a word to lua. left to
-- OnSave alone the file was written at boot and never again. so the clock keeps it current,
-- and only when a score has moved since the last write.
local BACKUP_MS = 5 * 60000

function PLS_Backup.tick()
    if not PLS_Backup.enabled() then return end
    if savedChanges == PLS_State.changes then return end

    local now = getTimestampMs()
    if savedAt and now - savedAt < BACKUP_MS then return end

    -- stamped before the write, so a file that cannot be written is tried again in five
    -- minutes and not on every tick.
    savedAt = now
    PLS_Backup.save()
end

-- ----------------------------------------------------------------------------
-- reading
-- ----------------------------------------------------------------------------

local function PLS_count(players)
    local n = 0
    for _ in pairs(players) do n = n + 1 end
    return n
end

-- the file, or the spare if the file is gone or unreadable. returns the parsed table, which
-- of the two it came from, and the text it was parsed from.
function PLS_Backup.read()
    local path = PLS_Backup.path()

    local text = PLS_read(path)
    if text then
        local parsed, err = PLS_Json.decode(text)
        if parsed then return parsed, path, text end

        PLS.warn("the score backup at " .. path .. " could not be read ("
            .. tostring(err) .. "), falling back to the previous one")
    end

    local spare = PLS_Backup.sparePath()
    local backup = PLS_read(spare)
    if not backup then return nil end

    local parsed, err = PLS_Json.decode(backup)
    if parsed then return parsed, spare, backup end

    PLS.warn("the previous score backup could not be read either: " .. tostring(err))
    return nil
end

-- unconditional. nothing calls this on its own: whoever did has decided the file is the truth.
function PLS_Backup.load()
    local parsed, from, text = PLS_Backup.read()
    if not parsed then return false end

    -- a file of the right syntax but the wrong shape is not a backup. better to keep whatever
    -- the world save had than to replace it with nothing.
    if type(parsed.players) ~= "table" then
        PLS.warn("the score backup at " .. tostring(from) .. " has no players table, ignoring it")
        return false
    end

    -- remembered even when the write is off, so the first rotation preserves what was already
    -- on disk rather than dropping it.
    lastText = text

    local data = PLS_State.ensure()

    data.players = parsed.players
    data.lives = type(parsed.lives) == "table" and parsed.lives or {}
    data.leaders = type(parsed.leaders) == "table" and parsed.leaders or {}

    -- every board, so the next pump pushes corrected standings to anyone already connected.
    for key in pairs(PLS_Boards.defs) do PLS_State.markDirty(key) end

    PLS.warn(string.format("restored %d players from %s, written %s",
        PLS_count(data.players), from, PLS.stampText(parsed.savedAt)))

    return true, PLS_count(data.players), from
end

-- ----------------------------------------------------------------------------
-- when it happens
-- ----------------------------------------------------------------------------

Events.OnInitGlobalModData.Add(function()
    PLS_State.ensure()

    if not PLS_Backup.enabled() then return end

    -- read before the first write, so the rotation has the old payload rather than throwing
    -- it away. nothing is restored from it -- that is what /pls restore is for.
    local _, _, text = PLS_Backup.read()
    lastText = text

    -- once at boot: it creates the file on a server that has never had one, and surfaces a
    -- permissions problem now rather than at the shutdown it was supposed to cover.
    PLS_Backup.save()
end)

-- singleplayer: OnSave fires on quit and on the periodic world save, so there the file keeps
-- pace with the save it is backing up.
if Events.OnSave then
    PLS.guard("score backup on save", Events.OnSave, function()
        if PLS_Backup.enabled() then PLS_Backup.save() end
    end)
end

-- everywhere else, the clock. EveryOneMinute is only what wakes it: the five minutes are
-- counted on the real clock, as PLS_Ranking's pump counts its three seconds.
PLS.guard("score backup clock", Events.EveryOneMinute, PLS_Backup.tick)
