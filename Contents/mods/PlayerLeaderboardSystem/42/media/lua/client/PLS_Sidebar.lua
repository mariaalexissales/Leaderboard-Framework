----------
--ESTRAL--
----------

require "PLS_Panel"
require "PLS_Theme"

-- ISEquippedItem keeps TEXTURE_WIDTH file-local, so work it out again here. size 6 means
-- "match the font size" and resolves through a different option.
local function PLS_textureWidth()
    local size = getCore():getOptionSidebarSize()
    if size == 6 then
        size = getCore():getOptionFontSizeReal() - 1
    end

    if size == 2 then return 64 end
    if size == 3 then return 80 end
    if size == 4 then return 96 end
    if size == 5 then return 128 end
    return 48
end

-- the sidebar is rebuilt whole when the size option changes, and the old panel lives on for
-- a frame or two. touching a stale one wrecks the live panel's geometry.
local function PLS_isCurrentPanel(panel)
    if not panel or not panel.playerNum then return false end

    local playerData = getPlayerData(panel.playerNum)
    if playerData and playerData.equipped and playerData.equipped ~= panel then
        return false
    end

    return true
end

-- every button the sidebar can build, for the fallback below. half are conditional, and
-- adminBtn and warManagerBtn are built for every mp player but hidden for most.
local BUTTONS = {
    "invBtn", "healthBtn", "craftingBtn", "buildBtn", "movableBtn", "searchBtn",
    "zoneBtn", "mapBtn", "debugBtn", "arfBtn", "safetyBtn", "clientBtn",
    "adminBtn", "warManagerBtn",
}

-- mapBtn only exists when ISWorldMap.IsAllowed(), so a server with the map switched off flies
-- out of the lowest button actually on screen instead. visibility is the test, not existence,
-- or we would hang off a button nobody can see.
local function PLS_anchor(panel)
    if panel.mapBtn then return panel.mapBtn end

    local lowest, bottom = nil, -1
    for _, name in ipairs(BUTTONS) do
        local button = panel[name]
        if button and button:isVisible() and button:getBottom() > bottom then
            lowest, bottom = button, button:getBottom()
        end
    end

    return lowest
end

-- vanilla's map flyout is two cells wide, so start after it. measured, not assumed: it is
-- only built when ISMiniMap.IsAllowed().
local function PLS_cellOffset(panel, anchor, textureWidth)
    local cells = 1

    if anchor == panel.mapBtn and panel.mapPopup and panel.mapPopup.getWidth then
        local width = panel.mapPopup:getWidth() or 0
        cells = math.max(cells, math.ceil(width / textureWidth))
    end

    return cells
end

-- the other cells that fly out of the map button: Quest System Framework's, then zBay's
-- after it. both go where ours would, on the end of vanilla's flyout, and neither knows
-- about us, so ours goes after the pair of them whichever loaded first.
local NEIGHBOURS = { "QSF_popup", "zBay_popup" }

-- how far along the row they push us. off the map button only: the fallback anchor has no
-- row of theirs to share.
local function PLS_neighbourWidth(panel, anchor)
    if anchor ~= panel.mapBtn then return 0 end

    local width = 0
    for _, name in ipairs(NEIGHBOURS) do
        local cell = panel[name]
        if cell and cell.getWidth then width = width + (cell:getWidth() or 0) end
    end

    return width
end

local function PLS_overNeighbour(panel, anchor)
    if anchor ~= panel.mapBtn then return false end

    for _, name in ipairs(NEIGHBOURS) do
        local cell = panel[name]
        if cell and cell.isMouseOver and cell:isMouseOver() then return true end
    end

    return false
end

PLS_Popup = ISPanel:derive("PLS_Popup")

function PLS_Popup:new(x, y, width, height, chr)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.chr = chr
    o.playerNum = chr:getPlayerNum()
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }

    return o
end

function PLS_Popup:setTextures(textureWidth)
    if self.textureWidth == textureWidth then return end

    self.textureWidth = textureWidth
    local base = "media/ui/Sidebar/" .. textureWidth .. "/Leaderboard_"
    self.iconOff = getTexture(base .. "Off_" .. textureWidth .. ".png")
    self.iconOn = getTexture(base .. "On_" .. textureWidth .. ".png")
end

-- second, first, third: a podium reads left to right in that order.
local PODIUM = { PLS_Theme.COL_SECOND, PLS_Theme.COL_FIRST, PLS_Theme.COL_THIRD }
local PODIUM_SCALE = { 0.55, 0.85, 0.40 }

-- stands in until there is art at the paths in setTextures. three bars in the medal colours
-- the theme already carries, so it scales to any sidebar size for free.
function PLS_Popup:drawPodium(lit)
    local alpha = lit and 1 or 0.6
    local pad = math.max(2, math.floor(self.width * 0.16))
    local gap = math.max(1, math.floor(self.width * 0.06))
    local barWidth = math.max(1, math.floor((self.width - pad * 2 - gap * 2) / 3))
    local tallest = self.height - pad * 2
    local floorY = self.height - pad

    for i = 1, 3 do
        local colour = PODIUM[i]
        local height = math.max(1, math.floor(tallest * PODIUM_SCALE[i]))
        local x = pad + (i - 1) * (barWidth + gap)
        self:drawRect(x, floorY - height, barWidth, height, alpha, colour.r, colour.g, colour.b)
    end
end

function PLS_Popup:render()
    local open = PLS.isWindowOpen(self.playerNum)
    local texture = open and (self.iconOn or self.iconOff) or self.iconOff
    local over = self:isMouseOver()

    -- the backing and hover wash vanilla's flyouts draw, so the cell reads as one of them.
    self:drawRect(0, 0, self.width, self.height, 0.80, 0, 0, 0)
    if over then
        self:drawRect(0, 0, self.width, self.height, 0.15, 1, 1, 1)
    end

    -- a missing texture should cost us the icon, not the whole sidebar render pass.
    if texture then
        self:drawTexture(texture, 0, 0, 1, 1, 1, 1)
        return
    end

    self:drawPodium(open or over)
end

function PLS_Popup:onMouseMove(dx, dy)
    self:showTooltip(getText("IGUI_PLS_PanelTooltip"))
    return true
end

function PLS_Popup:onMouseMoveOutside(dx, dy)
    self:hideTooltip()
    return true
end

function PLS_Popup:onMouseDown(x, y)
    self:hideTooltip()

    PLS.togglePanel(self.chr)

    return true
end

function PLS_Popup:showTooltip(text)
    if not text then return end

    if not self.tooltip then
        self.tooltip = ISToolTip:new()
        self.tooltip:initialise()
        self.tooltip:instantiate()
        self.tooltip:setOwner(self)
    end

    self.tooltip:setName(text)
    self.tooltip:setVisible(true)
    self.tooltip:addToUIManager()
    self.tooltip:bringToTop()
end

function PLS_Popup:hideTooltip()
    if self.tooltip and self.tooltip:isVisible() then
        self.tooltip:removeFromUIManager()
        self.tooltip:setVisible(false)
    end
end

local function PLS_ensurePopup(panel)
    if not panel or not panel.chr or panel.chr:getPlayerNum() ~= 0 then return end
    if not PLS_isCurrentPanel(panel) then return end

    local anchor = PLS_anchor(panel)
    if not anchor then return end

    local textureWidth = PLS_textureWidth()
    local textureHeight = textureWidth * 0.75

    if not panel.PLS_popup then
        panel.PLS_popup = PLS_Popup:new(0, 0, textureWidth, textureHeight, panel.chr)
        panel.PLS_popup.owner = panel
        panel.PLS_popup:addToUIManager()
        panel.PLS_popup:setVisible(false)

        -- vanilla's flyout is always on top and its black box runs wider than its two cells
        -- at the smallest sidebar size. ours is added after it, so this keeps us above the box.
        panel.PLS_popup:setAlwaysOnTop(true)
    end

    local offset = PLS_cellOffset(panel, anchor, textureWidth)
    panel.PLS_popup:setX(panel:getAbsoluteX() + anchor:getX() + offset * textureWidth
        + PLS_neighbourWidth(panel, anchor))
    panel.PLS_popup:setY(panel:getAbsoluteY() + anchor:getY())
    panel.PLS_popup:setWidth(textureWidth)
    panel.PLS_popup:setHeight(textureHeight)
    panel.PLS_popup:setTextures(textureWidth)

    -- kept so visibility reads the button the cell was placed against, even if the fallback
    -- anchor moves between frames.
    panel.PLS_popup.anchor = anchor
end

-- up only while the cursor is on the way to it, like vanilla's own flyouts. a hidden cell
-- takes no clicks, so nothing of ours sits on the column.
local function PLS_updateVisibility(panel)
    if not panel or not panel.PLS_popup then return end
    if not PLS_isCurrentPanel(panel) then return end

    local popup = panel.PLS_popup
    local anchor = popup.anchor

    -- the world map check is vanilla's: the button still reads as hovered for a frame after
    -- the click that opened the map.
    local show = anchor ~= nil and anchor:isMouseOver()
        and not (ISWorldMap_instance and ISWorldMap_instance:isVisible())

    -- travelling right from the map button crosses vanilla's View Map / Toggle Minimap
    -- flyout, and without this the cursor loses us halfway.
    if not show and panel.mapPopup then
        show = panel.mapPopup:isMouseOver()
    end

    -- and then the quest cell and zBay's, where they are installed: the way across to ours.
    if not show then
        show = PLS_overNeighbour(panel, anchor)
    end

    -- a hidden element never reads as hovered, so this holds the cell open but cannot open it.
    if not show then
        show = popup:isMouseOver()
    end

    if "Tutorial" == getCore():getGameMode() then
        show = false
    end

    popup:setVisible(show)

    if not show then
        popup:hideTooltip()
    end
end

local function PLS_patchSidebar()
    if not ISEquippedItem then
        require "ISUI/ISEquippedItem"
    end
    if not ISEquippedItem or ISEquippedItem.PLS_PatchApplied then return end

    ISEquippedItem.PLS_PatchApplied = true
    local originalInitialise = ISEquippedItem.initialise
    local originalPrerender = ISEquippedItem.prerender
    local originalRemove = ISEquippedItem.removeFromUIManager
    local originalCheckSize = ISEquippedItem.checkSidebarSizeOption

    function ISEquippedItem:initialise()
        if originalInitialise then originalInitialise(self) end
        PLS_ensurePopup(self)
    end

    -- vanilla runs first, so a fault in here costs us our cell rather than the player's whole
    -- sidebar.
    function ISEquippedItem:prerender()
        if originalPrerender then originalPrerender(self) end
        if not PLS_isCurrentPanel(self) then return end

        PLS_ensurePopup(self)
        PLS_updateVisibility(self)
    end

    function ISEquippedItem:removeFromUIManager()
        if self.PLS_popup then
            self.PLS_popup:hideTooltip()
            self.PLS_popup:removeFromUIManager()
            self.PLS_popup = nil
        end

        if originalRemove then
            originalRemove(self)
        else
            ISPanel.removeFromUIManager(self)
        end
    end

    function ISEquippedItem:checkSidebarSizeOption()
        if originalCheckSize then originalCheckSize(self) end
        if PLS_isCurrentPanel(self) then PLS_ensurePopup(self) end
    end
end

-- wrapping the sidebar while the UI is still booting can leave it half-built.
Events.OnGameStart.Add(PLS_patchSidebar)
