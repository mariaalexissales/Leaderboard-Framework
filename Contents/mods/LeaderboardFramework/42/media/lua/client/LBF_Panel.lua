----------
--ESTRAL--
----------

require "ISUI/ISCollapsableWindow"
require "ISUI/ISModalDialog"
require "LBF_Core"
require "LBF_Boards"
require "LBF_Theme"
require "LBF_Button"
require "LBF_Row"
require "LBF_ClientState"

LBF = LBF or {}
LBF.players = LBF.players or {}

LBF_Panel = ISCollapsableWindow:derive("LBF_Panel")

local PAD = 8
local GAP = 6
local TAB_HEIGHT = 22
local FOOTER_HEIGHT = 28
local REFRESH_TICKS = 30

function LBF.getWindow(playerNum)
    local data = LBF.players[playerNum]
    return data and data.instance or nil
end

function LBF.isWindowOpen(playerNum)
    return LBF.getWindow(playerNum) ~= nil
end

function LBF_Panel:new(x, y, width, height, player)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.player = player
    o.playerNum = player:getPlayerNum()
    o.title = getText("IGUI_LBF_Title")
    o.tab = nil
    o.rows = {}
    o.ticks = 0
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
function LBF_Panel:bands()
    local tabY = self:titleBarHeight() + PAD
    local listY = tabY + TAB_HEIGHT + GAP
    local footerY = self.height - self:resizeWidgetHeight() - FOOTER_HEIGHT
    return tabY, listY, footerY
end

-- anchors are applied by instantiate(), so they have to be assigned before it runs.
function LBF_Panel:attach(button, anchors)
    for key, value in pairs(anchors or {}) do button[key] = value end
    button:initialise()
    button:instantiate()
    self:addChild(button)
    return button
end

function LBF_Panel:createChildren()
    ISCollapsableWindow.createChildren(self)

    local tabY, listY, footerY = self:bands()

    self.tabs = {}
    local x = PAD

    for _, def in ipairs(LBF_Boards.ordered()) do
        local button = LBF_Button:new(x, tabY, 10, TAB_HEIGHT, getText(def.title), self, LBF_Panel.onTab)
        button:sizeToTitle(28)
        button.board = def.key
        self:attach(button)

        self.tabs[#self.tabs + 1] = button
        x = button:getRight() + 4
    end

    if not self.tab and self.tabs[1] then self.tab = self.tabs[1].board end

    local listHeight = footerY - listY - GAP - 2

    self.list = NIVirtualScrollView:new(PAD + 1, listY + 1, self.width - PAD * 2 - 2, listHeight)
    self.list:initialise()
    self.list:instantiate()
    -- setOnCreateItem after instantiate: createChildren already ran initializePool once
    -- with no callback set and quietly did nothing.
    self.list:setOnCreateItem(function()
        local row = LBF_Row:new(0, 0, self.list:getWidth(), LBF_Row.HEIGHT, self)
        -- the pool calls initialise for us but not instantiate.
        row:instantiate()
        return row
    end)
    self.list:setOnUpdateItem(function(widget, data)
        widget:setWidth(self.list:getWidth())
        widget:setRow(data)
    end)
    self.list:setConfig(LBF_Row.HEIGHT, 2)
    self.listHeight = listHeight
    self:addChild(self.list)

    self.reset = LBF_Button:new(self.width - PAD - 100, footerY + 1, 100, FOOTER_HEIGHT - 4,
        getText("IGUI_LBF_Reset"), self, LBF_Panel.onReset)
    self:attach(self.reset, { anchorLeft = false, anchorRight = true })

    self:refresh()
end

function LBF_Panel:onTab(button)
    self.tab = button.board
    self:refresh()
end

function LBF_Panel:onReset()
    if not self.tab then return end

    -- nothing under a modal stops being clickable, so a second press would stack a second
    -- prompt on the first. vanilla guards its sleep dialog the same way.
    if self.resetModal then return end

    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 175, getCore():getScreenHeight() / 2 - 75, 350, 150,
        getText("IGUI_LBF_ResetConfirm"), true, self, LBF_Panel.onConfirmReset,
        self.playerNum, self.tab)

    modal:initialise()
    modal:addToUIManager()
    modal:bringToTop()

    self.resetModal = modal
end

-- the board travels with the modal, so a tab that changes while it is open cannot wipe a
-- different board than the one that was asked about.
function LBF_Panel:onConfirmReset(button, board)
    self.resetModal = nil

    if button.internal ~= "YES" or not board then return end
    LBF_ClientState.reset(board)
end

function LBF_Panel:buildRows()
    local board = LBF_ClientState.board(self.tab)
    if not board then return {} end

    local me = LBF.nameOf(self.player)
    local rows = {}

    for i, row in ipairs(board.rows or {}) do
        rows[i] = { rank = i, name = row.n, score = row.s, me = row.n == me }
    end

    return rows
end

function LBF_Panel:refresh()
    self.rows = self:buildRows()

    -- the scroll view only reassigns data when the visible range moves, so a refresh that
    -- leaves the row count alone has to be forced through.
    if self.list then self.list:setDataSource(self.rows, true) end
end

function LBF_Panel:prerender()
    ISCollapsableWindow.prerender(self)

    local _, listY, footerY = self:bands()
    local listW = self.width - PAD * 2

    self:drawRect(PAD, listY, listW, footerY - listY - GAP,
        LBF_Theme.COL_WELL.a, LBF_Theme.COL_WELL.r, LBF_Theme.COL_WELL.g, LBF_Theme.COL_WELL.b)
    self:drawRectBorder(PAD, listY, listW, footerY - listY - GAP,
        LBF_Theme.COL_FRAME.a, LBF_Theme.COL_FRAME.r, LBF_Theme.COL_FRAME.g, LBF_Theme.COL_FRAME.b)

    for _, button in ipairs(self.tabs or {}) do
        button.selected = button.board == self.tab
    end

    -- a java call in a per-frame prerender, and it cannot change without a reconnect.
    if self.reset then
        if self.isAdmin == nil then self.isAdmin = LBF.isAdmin(self.player) end
        self.reset:setVisible(self.isAdmin)
    end
end

function LBF_Panel:render()
    ISCollapsableWindow.render(self)

    local font = UIFont.Small
    local _, listY, footerY = self:bands()
    local dim = LBF_Theme.COL_DIM

    if not self.tab then
        self:drawText(getText("IGUI_LBF_NoBoards"), PAD + 10, listY + 10,
            dim.r, dim.g, dim.b, 1, font)
        return
    end

    if #self.rows == 0 then
        local text = LBF_ClientState.ready and getText("IGUI_LBF_Empty")
            or getText("IGUI_LBF_Connecting")
        self:drawText(text, PAD + 10, listY + 10, dim.r, dim.g, dim.b, 1, font)
    end

    self:drawRect(PAD, footerY - GAP / 2, self.width - PAD * 2, 1,
        LBF_Theme.COL_FRAME.a, LBF_Theme.COL_FRAME.r, LBF_Theme.COL_FRAME.g, LBF_Theme.COL_FRAME.b)

    -- the player's own standing, sent alongside the board, so it is right even when they
    -- are nowhere near the part of it they can see.
    local board = LBF_ClientState.board(self.tab)
    local textY = footerY + math.floor((FOOTER_HEIGHT - getTextManager():getFontHeight(font)) / 2)

    local label = getText("IGUI_LBF_YourStanding")
    self:drawText(label, PAD + 2, textY, dim.r, dim.g, dim.b, 1, font)

    local x = PAD + 2 + getTextManager():MeasureStringX(font, label) + PAD

    local rank = board and board.rank
    local rankText = rank and ("#" .. rank) or getText("IGUI_LBF_Unranked")
    local rankColour = rank and LBF_Theme.COL_ME or dim
    self:drawText(rankText, x, textY, rankColour.r, rankColour.g, rankColour.b, 1, font)

    x = x + getTextManager():MeasureStringX(font, rankText) + PAD
    local score = tostring(board and board.score or 0)
    self:drawText(score, x, textY,
        LBF_Theme.COL_SCORE.r, LBF_Theme.COL_SCORE.g, LBF_Theme.COL_SCORE.b, 1, font)
end

function LBF_Panel:update()
    ISCollapsableWindow.update(self)

    -- the cache bumps a revision on anything from the server; the tick floor only
    -- backstops whatever moves without it.
    self.ticks = self.ticks + 1

    if self.revision ~= LBF_ClientState.revision then
        self.revision = LBF_ClientState.revision
        self.ticks = 0
        self:refresh()
    elseif self.ticks >= REFRESH_TICKS then
        self.ticks = 0
        self:refresh()
    end
end

function LBF_Panel:onResize()
    ISCollapsableWindow.onResize(self)
    if not self.list then return end

    local _, listY, footerY = self:bands()
    local listHeight = footerY - listY - GAP - 2

    self.list:setWidth(self.width - PAD * 2 - 2)
    self.list:setHeight(listHeight)

    -- setConfig rebuilds the whole widget pool and onResize fires every frame of a drag,
    -- so only reconfigure when the height actually moved.
    if self.listHeight ~= listHeight then
        self.listHeight = listHeight
        self.list:setConfig(LBF_Row.HEIGHT, 2)
    end

    self.list:setDataSource(self.rows, true)

    if self.reset then self.reset:setY(footerY + 1) end
end

function LBF_Panel:close()
    local data = LBF.players[self.playerNum]
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
function LBF.openPanel(player, pinned)
    if not player then return end

    local playerNum = player:getPlayerNum()
    if playerNum ~= 0 then return end

    -- NeatUI is declared in mod.info, but a client that has somehow loaded us without it
    -- would otherwise index a nil and take the whole ui down with it.
    if not NIVirtualScrollView then
        LBF.warn("NeatUI Framework is not loaded, so the leaderboard cannot open")
        return
    end

    local data = LBF.players[playerNum]
    if not data then
        data = {}
        LBF.players[playerNum] = data
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

    local window = LBF_Panel:new(x, y, width, height, player)
    window.pinned = pinned ~= false
    window:initialise()
    window:instantiate()
    window:addToUIManager()

    data.instance = window
end

function LBF.closePanel(player)
    local window = LBF.getWindow(player and player:getPlayerNum() or 0)
    if window then window:close() end
end

function LBF.togglePanel(player)
    local playerNum = player and player:getPlayerNum() or 0

    if LBF.isWindowOpen(playerNum) then
        LBF.getWindow(playerNum):close()
    else
        LBF.openPanel(player, true)
    end
end

Events.OnPlayerDeath.Add(function(player)
    if not player then return end

    local window = LBF.getWindow(player:getPlayerNum())
    if window then window:close() end
end)
