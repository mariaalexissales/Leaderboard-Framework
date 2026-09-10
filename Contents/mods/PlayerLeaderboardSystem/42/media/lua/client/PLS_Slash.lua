----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Net"
require "PLS_Chat"

-- a chat command, because the alternatives need what an admin on somebody else's server has
-- not got: the debug mod data viewer needs -debug, a console print needs the console.
--
-- vanilla hands any unrecognised slash command to the server's java parser
-- (ISChat.onCommandEntered), and lua cannot add a case to it, so ours is caught on this side
-- before that line runs.

PLS_Slash = PLS_Slash or {}

local PREFIX = "/pls"

local USAGE = {
    "/pls dump          - is the table there, and how much of it",
    "/pls dump <name>   - one player's scores and their run right now",
    "/pls me            - your own row",
    "/pls backup        - write the score backup file now",
    "/pls restore       - load the backup file over the live scores",
}

-- everything after the prefix, split on whitespace.
local function PLS_words(text)
    local words = {}
    for word in string.gmatch(text, "%S+") do words[#words + 1] = word end
    return words
end

local function PLS_say(lines)
    for _, line in ipairs(lines) do PLS_Chat.line("[PLS] " .. line) end
end

-- checked as a whole word, so another mod's command that merely starts with the same letters
-- is left alone.
function PLS_Slash.claims(text)
    if type(text) ~= "string" then return false end

    local head = string.lower(text):match("^(%S+)")
    return head == PREFIX
end

-- anything starting /pls is answered here whatever it says. a typo that fell through would
-- come back "unknown command", which reads like the mod is missing rather than a typo.
function PLS_Slash.run(text)
    local words = PLS_words(text)
    local verb = words[2] and string.lower(words[2]) or nil

    if verb == "dump" then
        PLS_Net.toServer("dump", { who = words[3] })
        return
    end

    if verb == "backup" then
        PLS_Net.toServer("backup", {})
        return
    end

    if verb == "restore" then
        PLS_Net.toServer("restore", {})
        return
    end

    if verb == "me" then
        -- no name on the wire: the server reads it off the connection, which is what lets this one
        -- be open to everybody.
        PLS_Net.toServer("dump", { own = true })
        return
    end

    PLS_say(USAGE)
end

-- ISChat.createChat copies this into its text entry by reference on OnGameStart, so wrapping
-- any later than file load leaves the entry holding the original and the command silently
-- never fires. vanilla client lua loads first, so ISChat is here and createChat has not run.
if ISChat and ISChat.onCommandEntered then
    local PLS_previous = ISChat.onCommandEntered

    function ISChat:onCommandEntered()
        local entry = ISChat.instance and ISChat.instance.textEntry
        local text = entry and entry:getText() or ""

        if PLS_Slash.claims(text) then
            -- vanilla's housekeeping for a consumed command: history puts it back under the up arrow,
            -- and unfocus empties the box.
            ISChat.instance:logChatCommand(text)
            ISChat.instance:unfocus()

            -- a fault in here must not eat the keystroke or leave the box focused.
            local ok, err = pcall(PLS_Slash.run, text)
            if not ok then PLS.warn("chat command failed: " .. tostring(err)) end
            return
        end

        -- everything else goes on to whoever had this before us, likely another mod's wrapper.
        -- there is no registry to defer to, so chaining is the whole contract.
        return PLS_previous(self)
    end
else
    PLS.warn("ISChat was not loaded, so the /pls chat command is not available")
end
