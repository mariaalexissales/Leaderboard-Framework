----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Net"
require "PLS_Chat"

-- a chat command, because the alternatives need things an admin on somebody else's server does
-- not have. the debug mod data viewer needs a client launched with -debug, and a print to the
-- server console needs the server console. a line typed into chat needs neither.
--
-- vanilla hands any slash command it does not recognise to the server's java parser
-- (ISChat.onCommandEntered, "SendCommandToServer(command)"), and lua cannot add a case to that.
-- so ours has to be caught on this side, before that line runs.

PLS_Slash = PLS_Slash or {}

local PREFIX = "/pls"

local USAGE = {
    "/pls dump          - is the table there, and how much of it",
    "/pls dump <name>   - one player's scores and their run right now",
    "/pls me            - your own row",
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

-- true if this line is ours to deal with. checked as a whole word so a command belonging to
-- some other mod that merely starts with the same letters is left alone.
function PLS_Slash.claims(text)
    if type(text) ~= "string" then return false end

    local head = string.lower(text):match("^(%S+)")
    return head == PREFIX
end

-- anything starting /pls is answered here whatever it says. a typo that fell through would be
-- posted to the server parser and come back "unknown command", which reads like the mod is
-- missing rather than like a typo.
function PLS_Slash.run(text)
    local words = PLS_words(text)
    local verb = words[2] and string.lower(words[2]) or nil

    if verb == "dump" then
        PLS_Net.toServer("dump", { who = words[3] })
        return
    end

    if verb == "me" then
        -- no name on the wire. the server reads it off the connection, which is what lets
        -- this one be open to everybody.
        PLS_Net.toServer("dump", { own = true })
        return
    end

    PLS_say(USAGE)
end

-- ISChat.createChat copies this function into its text entry by reference, and it runs on
-- OnGameStart. wrapping any later than file load would leave the text entry holding the
-- original, and the command would silently never fire. vanilla client lua is loaded before
-- mod client lua, so ISChat is already here and createChat has not run yet.
if ISChat and ISChat.onCommandEntered then
    local PLS_previous = ISChat.onCommandEntered

    function ISChat:onCommandEntered()
        local entry = ISChat.instance and ISChat.instance.textEntry
        local text = entry and entry:getText() or ""

        if PLS_Slash.claims(text) then
            -- vanilla's own housekeeping for a command it has consumed: the history entry
            -- puts it back under the up arrow, and unfocus empties the box for us.
            ISChat.instance:logChatCommand(text)
            ISChat.instance:unfocus()

            -- a fault in here must not eat the keystroke or leave the box focused.
            local ok, err = pcall(PLS_Slash.run, text)
            if not ok then PLS.warn("chat command failed: " .. tostring(err)) end
            return
        end

        -- everything else goes on to whoever had this before us, which may well be another
        -- mod's wrapper. there is no registry to defer to, so chaining is the whole contract.
        return PLS_previous(self)
    end
else
    PLS.warn("ISChat was not loaded, so the /pls chat command is not available")
end
