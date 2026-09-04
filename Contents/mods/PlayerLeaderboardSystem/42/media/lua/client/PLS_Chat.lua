----------
--ESTRAL--
----------

require "PLS_Core"
require "PLS_Boards"

PLS = PLS or {}
PLS_Chat = PLS_Chat or {}

-- gold, so an announcement reads as one against the ordinary chat traffic around it.
local COLOUR = "<RGB:0.98,0.82,0.45>"

-- vanilla's ISChat.addLineInChat wants a java ChatMessage, which lua has no way to build,
-- so the line goes straight into the tab's own backing table the way every other mod that
-- prints to chat does it. wrapped whole: chat is somebody else's window and its internals
-- move between builds, and a broken announcement must not take the game down with it.
function PLS_Chat.line(text)
    local ok = pcall(function()
        if not ISChat or not ISChat.instance then error() end

        local chatText = ISChat.instance.chatText
        if not chatText then
            chatText = ISChat.instance.defaultTab
            if not chatText then error() end
            ISChat.instance.chatText = chatText
        end

        if not chatText.chatTextLines then error() end

        -- checked before the insert: afterwards it is always false.
        local vscroll = chatText.vscroll
        local scrolledToBottom = (chatText:getScrollHeight() <= chatText:getHeight())
            or (vscroll and vscroll.pos == 1)

        if ISChat.maxLine and #chatText.chatTextLines > ISChat.maxLine then
            table.remove(chatText.chatTextLines, 1)
        end

        table.insert(chatText.chatTextLines, text .. " <LINE> ")

        local rebuilt = ""
        for i, line in ipairs(chatText.chatTextLines) do
            if i == #chatText.chatTextLines then
                line = string.gsub(line, " <LINE> $", "")
            end
            rebuilt = rebuilt .. line
        end

        chatText.text = rebuilt
        chatText:paginate()

        -- only follow the new line down if they were already reading the bottom. yanking
        -- the scroll out from under someone reading back is worse than a missed line.
        if scrolledToBottom then chatText:setYScroll(-10000) end
    end)

    if not ok then
        local player = getPlayer()
        if player then pcall(function() player:Say(text) end) end
    end
end

function PLS_Chat.announce(args)
    if not args or not args.name or not args.board then return end

    local def = PLS_Boards.get(args.board)
    local title = def and getText(def.title) or args.board
    local unit = def and getText(def.unit) or ""

    PLS_Chat.line(COLOUR .. getText("IGUI_PLS_Announce",
        args.name, title, tostring(args.score or 0), unit))

    local player = getPlayer()
    if not player or PLS.nameOf(player) ~= args.name then return end

    if HaloTextHelper and HaloTextHelper.addGoodText then
        pcall(function()
            HaloTextHelper.addGoodText(player, getText("IGUI_PLS_AnnounceHalo", title))
        end)
    end
end
