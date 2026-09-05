----------
--ESTRAL--
----------

require "ISUI/ISCollapsableWindow"
require "ISUI/ISModalDialog"
require "PLS_Core"
require "PLS_Boards"
require "PLS_Theme"
require "PLS_Button"
require "PLS_Row"
require "PLS_ClientState"

PLS.players = PLS.players or {}

PLS_Panel = ISCollapsableWindow:derive("PLS_Panel")

local PAD = 8
local GAP = 6
local TAB_HEIGHT = 22
local FOOTER_HEIGHT = 28

function PLS.getWindow(playerNum)
    local data = PLS.players[playerNum]
    return data and data.instance or nil
end

function PLS.isWindowOpen(playerNum)
    return PLS.getWindow(playerNum) ~= nil
end

function PLS_Panel:new(x, y, width, height, player)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.player = player
    o.playerNum = player:getPlayerNum()
    o.title = getText("IGUI_PLS_Title")
    o.tab = nil
    o.rows = {}
    o.revision = -1
    -- a peek closes on key release; a tap pins the window until the next tap.
    o.pinned = true
    o.resizable = true
    o.minimumWidth = 380
    o.minimumHeight = 300

    return o
end

-- one place for the vertical bands so createChildren and onResize cannot drift. a
-- resizable ISCollapsableWindow paints a status bar over its own bottom edge and lays a
-- resize widget across it that swallows clicks, so the footer sits above that.
function PLS_Panel:bands()
    local tabY = self:titleBarHeight() + PAD
    local listY = tabY + TAB_HEIGHT + GAP
    local footerY = self.height - self:resizeWidgetHeight() - FOOTER_HEIGHT
    return tabY, listY, footerY
end

-- the well is drawn to the band, and the scroll view sits one pixel inside it so the
-- frame is not painted over. createChildren and onResize both need that same inset.
function PLS_Panel:listBounds()
    local _, listY, footerY = self:bands()
    return PAD + 1, listY + 1, self.width - PAD * 2 - 2, footerY - listY - GAP - 2
end

-- anchors are applied by instantiate(), so they have to be assigned before it runs.
function PLS_Panel:attach(button, anchors)
    for key, value in pairs(anchors or {}) do button[key] = value end
    button:initialise()
    button:instantiate()
    self:addChild(button)
    return button
end

function PLS_Panel:createChildren()
    ISCollapsableWindow.createChildren(self)

    local tabY, _, footerY = self:bands()

    self.tabs = {}
    local x = PAD

    for _, def in ipairs(PLS_Boards.ordered()) do
        local button = PLS_Button:new(x, tabY, 10, TAB_HEIGHT, getText(def.title), self, PLS_Panel.onTab)
        button:sizeToTitle(28)
        button.board = def.key
        self:attach(button)

        self.tabs[#self.tabs + 1] = button
        x = button:getRight() + 4
    end

    if not self.tab and self.tabs[1] then self.tab = self.tabs[1].board end

    local listX, listTop, listWidth, listHeight = self:listBounds()

    self.list = NIVirtualScrollView:new(listX, listTop, listWidth, listHeight)
    self.list:initialise()
    self.list:instantiate()
    -- setOnCreateItem after instantiate: createChildren already ran initializePool once
    -- with no callback set and quietly did nothing.
    self.list:setOnCreateItem(function()
        local row = PLS_Row:new(0, 0, self.list:getWidth(), PLS_Row.HEIGHT, self)
        -- the pool calls initialise for us but not instantiate.
        row:instantiate()
        return row
    end)
    self.list:setOnUpdateItem(function(widget, data)
        widget:setWidth(self.list:getWidth())
        widget:setRow(data)
    end)
    self.list:setConfig(PLS_Row.HEIGHT, 2)
    self.listHeight = listHeight
    self:addChild(self.list)

    -- refreshBtn, not refresh: PLS_Panel:refresh is a method, and a field of that name on
    -- the instance would shadow it and turn self:refresh() into a call on a button.
    self.refreshBtn = PLS_Button:new(self.width - PAD - 90, footerY + 1, 90, FOOTER_HEIGHT - 4,
        getText("IGUI_PLS_Refresh"), self, PLS_Panel.onRefresh)
    self:attach(self.refreshBtn, { anchorLeft = false, anchorRight = true })

    -- inside the always-visible one, so refresh keeps a fixed spot whoever is looking.
    self.reset = PLS_Button:new(self.refreshBtn:getX() - 4 - 100, footerY + 1, 100, FOOTER_HEIGHT - 4,
        getText("IGUI_PLS_Reset"), self, PLS_Panel.onReset)
    self:attach(self.reset, { anchorLeft = false, anchorRight = true })

    self:refresh()
end

function PLS_Panel:onTab(button)
    self.tab = button.board
    self:refresh()
end

function PLS_Panel:onRefresh()
    PLS_ClientState.rearm()
    PLS_ClientState.requestBoards()
end

function PLS_Panel:onReset()
    if not self.tab then return end

    -- nothing under a modal stops being clickable, so a second press would stack a second
    -- prompt on the first. vanilla guards its sleep dialog the same way.
    if self.resetModal then return end

    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 175, getCore():getScreenHeight() / 2 - 75, 350, 150,
        getText("IGUI_PLS_ResetConfirm"), true, self, PLS_Panel.onConfirmReset,
        self.playerNum, self.tab)

    modal:initialise()
    modal:addToUIManager()
    modal:bringToTop()

    self.resetModal = modal
end

-- the board travels with the modal, so a tab that changes while it is open cannot wipe a
-- different board than the one that was asked about.
function PLS_Panel:onConfirmReset(button, board)
    self.resetModal = nil

    if button.internal ~= "YES" or not board then return end
    PLS_ClientState.reset(board)
end

function PLS_Panel:buildRows()
    local board = PLS_ClientState.board(self.tab)
    if not board then return {} end

    local me = PLS.nameOf(self.player)
    local rows = {}

    for i, row in ipairs(board.rows or {}) do
        rows[i] = { rank = i, name = row.n, score = row.s, me = row.n == me }
    end

    return rows
end

function PLS_Panel:refresh()
    self.rows = self:buildRows()

    -- the scroll view only reassigns data when the visible range moves, so a refresh that
    -- leaves the row count alone has to be forced through.
    if self.list then self.list:setDataSource(self.rows, true) end
end

function PLS_Panel:prerender()
    ISCollapsableWindow.prerender(self)

    local _, listY, footerY = self:bands()
    local listW = self.width - PAD * 2
    local listH = footerY - listY - GAP

    PLS_Theme.fill(self, PAD, listY, listW, listH, PLS_Theme.COL_WELL)
    PLS_Theme.frame(self, PAD, listY, listW, listH, PLS_Theme.COL_FRAME)

    for _, button in ipairs(self.tabs or {}) do
        button.selected = button.board == self.tab
    end

    -- a java call in a per-frame prerender, and it cannot change without a reconnect.
    if self.reset then
        if self.isAdmin == nil then self.isAdmin = PLS.isAdmin(self.player) end
        self.reset:setVisible(self.isAdmin)
    end
end

function PLS_Panel:render()
    ISCollapsableWindow.render(self)

    local font = UIFont.Small
    local _, listY, footerY = self:bands()
    local dim = PLS_Theme.COL_DIM

    if not self.tab then
        self:drawText(getText("IGUI_PLS_NoBoards"), PAD + 10, listY + 10,
            dim.r, dim.g, dim.b, 1, font)
        return
    end

    if #self.rows == 0 then
        local text = PLS_ClientState.isSeen(self.tab) and getText("IGUI_PLS_Empty")
            or getText("IGUI_PLS_Connecting")
        self:drawText(text, PAD + 10, listY + 10, dim.r, dim.g, dim.b, 1, font)
    end

    PLS_Theme.fill(self, PAD, footerY - GAP / 2, self.width - PAD * 2, 1, PLS_Theme.COL_FRAME)

    -- the player's own standing, sent alongside the board, so it is right even when they
    -- are nowhere near the part of it they can see.
    local board = PLS_ClientState.board(self.tab)
    local textY = footerY + math.floor((FOOTER_HEIGHT - getTextManager():getFontHeight(font)) / 2)

    local label = getText("IGUI_PLS_YourStanding")
    self:drawText(label, PAD + 2, textY, dim.r, dim.g, dim.b, 1, font)

    local x = PAD + 2 + getTextManager():MeasureStringX(font, label) + PAD

    local rank = board and board.rank
    local rankText = rank and ("#" .. rank) or getText("IGUI_PLS_Unranked")
    local rankColour = rank and PLS_Theme.COL_ME or dim
    self:drawText(rankText, x, textY, rankColour.r, rankColour.g, rankColour.b, 1, font)

    x = x + getTextManager():MeasureStringX(font, rankText) + PAD
    local score = tostring(board and board.score or 0)
    self:drawText(score, x, textY,
        PLS_Theme.COL_SCORE.r, PLS_Theme.COL_SCORE.g, PLS_Theme.COL_SCORE.b, 1, font)
end

-- rows only ever change when the server pushes a board, and the cache bumps a revision
-- on every one of those, so there is nothing for a tick floor to catch. the footer reads
-- the cache directly in render and is live regardless.
function PLS_Panel:update()
    ISCollapsableWindow.update(self)

    if self.revision == PLS_ClientState.revision then return end

    self.revision = PLS_ClientState.revision
    self:refresh()
end

function PLS_Panel:onResize()
    ISCollapsableWindow.onResize(self)
    if not self.list then return end

    local _, _, footerY = self:bands()
    local _, _, listWidth, listHeight = self:listBounds()

    self.list:setWidth(listWidth)
    self.list:setHeight(listHeight)

    -- setConfig rebuilds the whole widget pool and onResize fires every frame of a drag,
    -- so only reconfigure when the height actually moved.
    if self.listHeight ~= listHeight then
        self.listHeight = listHeight
        self.list:setConfig(PLS_Row.HEIGHT, 2)
    end

    self.list:setDataSource(self.rows, true)

    if self.reset then self.reset:setY(footerY + 1) end
    if self.refreshBtn then self.refreshBtn:setY(footerY + 1) end
end

function PLS_Panel:close()
    local data = PLS.players[self.playerNum]
    if data and data.instance == self then
        data.x = self:getX()
        data.y = self:getY()
        data.instance = nil
    end

    if self.resetModal then
        self.resetModal:removeFromUIManager()
        self.resetModal = nil
    end

    ISCollapsableWindow.close(self)
    self:removeFromUIManager()
end

-- pinned is what the keybind reads to decide whether a key release should close the
-- window: a tap pins it, a hold does not.
function PLS.openPanel(player, pinned)
    if not player then return end

    local playerNum = player:getPlayerNum()
    if playerNum ~= 0 then return end

    -- a join that missed the handshake would otherwise sit on "waiting" until somebody else
    -- scores, so looking at the panel is itself a reason to ask again -- every time, not only
    -- before the first reply ever, or the panel never shows anything newer than what arrived
    -- once. the pacing is in requestOnOpen, because the keybind opens this on every peek.
    PLS_ClientState.requestOnOpen()

    -- NeatUI is declared in mod.info, but a client that has somehow loaded us without it
    -- would otherwise index a nil and take the whole ui down with it.
    if not NIVirtualScrollView then
        PLS.warn("NeatUI Framework is not loaded, so the leaderboard cannot open")
        return
    end

    local data = PLS.players[playerNum]
    if not data then
        data = {}
        PLS.players[playerNum] = data
    end

    if data.instance then
        data.instance.pinned = pinned ~= false
        data.instance:setVisible(true)
        data.instance:bringToTop()
        return
    end

    local width, height = 520, 480
    local x = data.x or (getCore():getScreenWidth() - width) / 2
    local y = data.y or (getCore():getScreenHeight() - height) / 2

    local window = PLS_Panel:new(x, y, width, height, player)
    window.pinned = pinned ~= false
    window:initialise()
    window:instantiate()
    window:addToUIManager()

    data.instance = window
end

function PLS.togglePanel(player)
    local playerNum = player and player:getPlayerNum() or 0

    if PLS.isWindowOpen(playerNum) then
        PLS.getWindow(playerNum):close()
    else
        PLS.openPanel(player, true)
    end
end

Events.OnPlayerDeath.Add(function(player)
    if not player then return end

    local window = PLS.getWindow(player:getPlayerNum())
    if window then window:close() end
end)
