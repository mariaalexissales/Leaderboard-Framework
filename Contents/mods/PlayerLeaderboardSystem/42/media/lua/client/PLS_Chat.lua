----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Boards"

PLS_Chat = PLS_Chat or {}

-- gold, so an announcement reads as one against the ordinary chat traffic around it.
local COL_ANNOUNCE = "<RGB:0.98,0.82,0.45>"

-- a notice is the game answering something the player just did, not news about somebody
-- else, so it sits back in the grey rather than competing with an announcement.
local COL_NOTICE = "<RGB:0.66,0.66,0.66>"

-- somebody lost something. the same weight as an announcement, because it is news of the
-- same size, but it must not read gold like a triumph.
local COL_UPSET = "<RGB:0.90,0.45,0.42>"

-- chat is somebody else's window and its tabs come from the server on their own packet, well
-- after OnGameStart. until the first one lands ISChat.instance.chatText is nil, and a board
-- announcement broadcast while somebody is still loading in used to land in that hole. vanilla
-- never hits it because ChatBase.showMessage holds OnAddMessage back until a tab exists;
-- nothing gates a line we write ourselves, so this checks for itself.
local function PLS_chatPanel()
    -- singleplayer has no chat window at all: ISChat.createChat returns early on not isClient.
    if not isClient() then return nil end
    if not ISChat or not ISChat.instance then return nil end

    -- checked rather than assumed, and never falling back to defaultTab: onSetDefaultTab is the
    -- only thing that sets that and nils it in this same window, so it is no better here, and
    -- assigning chatText without vanilla's paired onActivateView leaves the window half built.
    local panel = ISChat.instance.chatText
    if type(panel) ~= "table" then return nil end
    if type(panel.chatTextLines) ~= "table" then return nil end

    return panel
end

-- a joining client is told about a leader change before its chat exists, and losing that is
-- worse than showing it a moment late. bounded, because this is news rather than a log and a
-- client that never gets a window must not grow a list for the rest of the session.
local PENDING_MAX = 8
local pending = {}

-- vanilla's ISChat.addLineInChat wants a java ChatMessage, which lua has no way to build, so
-- the line goes straight into the tab's own backing table the way every other mod that prints
-- to chat does it. this is that function's own body, less the parts that need the message.
local function PLS_paint(panel, text)
    local lines = panel.chatTextLines

    -- checked before the insert: afterwards it is always false.
    local vscroll = panel.vscroll
    local scrolledToBottom = (panel:getScrollHeight() <= panel:getHeight())
        or (vscroll and vscroll.pos == 1)

    if ISChat.maxLine and #lines > ISChat.maxLine then
        table.remove(lines, 1)
    end

    lines[#lines + 1] = text .. " <LINE> "

    local rebuilt = ""
    for i = 1, #lines do
        local line = lines[i]
        if i == #lines then line = string.gsub(line, " <LINE> $", "") end
        rebuilt = rebuilt .. line
    end

    panel.text = rebuilt
    panel:paginate()

    -- only follow the new line down if they were already reading the bottom. yanking the
    -- scroll out from under someone reading back is worse than a missed line.
    if scrolledToBottom then panel:setYScroll(-10000) end
end

local function PLS_write(text)
    local panel = PLS_chatPanel()
    if not panel then return false end

    -- the panel is real, so the line is spoken for either way. a fault inside vanilla's own
    -- rich text panel is not a reason to put it back on the queue and try it forever.
    pcall(PLS_paint, panel, text)
    return true
end

-- Say draws the string as it stands, so the colour markup chat understands would be read out as
-- literal text. the parentheses keep gsub's second return value out of Say's own second argument.
local function PLS_say(text)
    local player = getPlayer()
    if not player then return end

    pcall(function() player:Say((string.gsub(text, "<[^>]*>", ""))) end)
end

function PLS_Chat.line(text)
    if PLS_write(text) then return end

    -- nothing to write to. in singleplayer there never will be, so say it out loud instead; on
    -- a client it is the tabs not having arrived yet, which the flush below is waiting for.
    if not isClient() then
        PLS_say(text)
        return
    end

    if #pending >= PENDING_MAX then table.remove(pending, 1) end
    pending[#pending + 1] = text
end

-- ISChat wires its own OnTabAdded inside createChat, which runs on OnGameStart, later than this
-- file loads. a handler registered here would therefore run before the one that assigns
-- chatText and would still find nothing. the tick is a little late but always right.
local function PLS_flush()
    if #pending == 0 then return end
    if not PLS_chatPanel() then return end

    -- swapped out before any of it is written, so a fault partway through cannot replay lines.
    local held = pending
    pending = {}

    for i = 1, #held do PLS_write(held[i]) end
end

PLS.guard("chat flush", Events.EveryOneMinute, PLS_flush)

-- the announce name, not the tab label: a tab reads "Per Life" because the other half of the
-- row says which kills, and a line in chat stands on its own. an unregistered board still has
-- a key, and printing that beats printing nothing.
local function PLS_boardTitle(board)
    local def = PLS_Boards.get(board)
    return def and getText(def.announce or def.title) or board
end

-- only ever a top three, so three strings rather than a suffix rule: english ordinals do
-- not survive translation as one, and the fourth place this cannot render never arrives.
local ORDINALS = { "IGUI_PLS_Ordinal1st", "IGUI_PLS_Ordinal2nd", "IGUI_PLS_Ordinal3rd" }

local function PLS_ordinal(place)
    local key = ORDINALS[tonumber(place) or 0]
    return key and getText(key) or ("#" .. tostring(place))
end

-- the halo goes to whoever the news is good for, which is not always the name in the line.
local function PLS_halo(name, text)
    local player = getPlayer()
    if not player or not name or PLS.nameOf(player) ~= name then return end
    if not HaloTextHelper or not HaloTextHelper.addGoodText then return end

    pcall(function() HaloTextHelper.addGoodText(player, text) end)
end

-- three kinds now, and an announcement that arrives without one is the leader change this
-- only ever used to carry.
function PLS_Chat.announce(args)
    if not args or not args.name or not args.board then return end

    local def = PLS_Boards.get(args.board)
    local title = PLS_boardTitle(args.board)
    local unit = def and getText(def.unit) or ""
    local score = tostring(args.score or 0)

    if args.kind == "slain" then
        PLS_Chat.line(COL_UPSET .. getText("IGUI_PLS_AnnounceSlain",
            args.name, tostring(args.victim), title))
        -- to the killer. the player this is about is dead and looking at a death screen.
        PLS_halo(args.name, getText("IGUI_PLS_AnnounceSlainHalo"))
        return
    end

    if args.kind == "fallen" then
        PLS_Chat.line(COL_UPSET .. getText("IGUI_PLS_AnnounceFallen",
            PLS_ordinal(args.place), args.name, score, unit, title))
        -- nobody. PLS_Panel closes the window on death, and there is no one here to cheer.
        return
    end

    PLS_Chat.line(COL_ANNOUNCE .. getText("IGUI_PLS_Announce", args.name, title, score, unit))
    PLS_halo(args.name, getText("IGUI_PLS_AnnounceHalo", title))
end

-- the answer to /pls, straight from the server's own copy of the table. grey like a notice,
-- because it is the game answering something this player just typed rather than news.
--
-- untranslated on purpose: these lines get pasted into bug reports, and a stable string is
-- worth more there than a localised one.
function PLS_Chat.dump(args)
    if not args or type(args.lines) ~= "table" then return end

    for _, line in ipairs(args.lines) do
        PLS_Chat.line(COL_NOTICE .. "[PLS] " .. tostring(line))
    end
end

-- the server's acknowledgement of something an admin asked for. only reset today, but the
-- kind is on the wire so a second one does not need a second command.
function PLS_Chat.toast(args)
    if not args or args.kind ~= "reset" or not args.board then return end

    PLS_Chat.line(COL_NOTICE .. getText("IGUI_PLS_ResetDone", PLS_boardTitle(args.board)))
end
