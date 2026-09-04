----------
--ESTRAL--
----------

require "ISUI/ISPanel"
require "PLS_Theme"

PLS_Row = ISPanel:derive("PLS_Row")
PLS_Row.HEIGHT = 26

local PAD = 8
local ACCENT = 2
local RANK_W = 26

function PLS_Row:new(x, y, width, height, panel)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.panel = panel
    o.row = nil
    o.backgroundColor = { r = 1, g = 1, b = 1, a = 0.03 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    -- nothing on a row is clickable, and an ISPanel will otherwise drag the window about
    -- when someone puts the cursor down on one.
    o.moveWithMouse = false

    return o
end

function PLS_Row:setRow(row)
    self.row = row
end

function PLS_Row:prerender()
    -- no hover state: there is nothing to click, and lighting up under the cursor would
    -- promise otherwise.
    self.backgroundColor.a = (self.row and self.row.me) and 0.09 or 0.03
    ISPanel.prerender(self)
end

function PLS_Row:render()
    ISPanel.render(self)

    local row = self.row
    if not row then return end

    local font = UIFont.Small
    local textY = math.floor((self.height - getTextManager():getFontHeight(font)) / 2)

    local accent = PLS_Theme.rankColour(row.rank)
    self:drawRect(0, 0, ACCENT, self.height, 0.85, accent.r, accent.g, accent.b)

    -- rank right-aligned in its own gutter so the numbers line up on the units column
    -- whether the board runs to one digit or three.
    local rankRight = ACCENT + PAD + RANK_W
    self:drawTextRight(tostring(row.rank), rankRight, textY,
        accent.r, accent.g, accent.b, 1, font)

    local score = tostring(row.score or 0)
    local scoreWidth = getTextManager():MeasureStringX(font, score)
    self:drawTextRight(score, self.width - PAD, textY,
        PLS_Theme.COL_SCORE.r, PLS_Theme.COL_SCORE.g, PLS_Theme.COL_SCORE.b, 1, font)

    local nameX = rankRight + PAD
    local nameColour = row.me and PLS_Theme.COL_ME or PLS_Theme.COL_TITLE
    local name = PLS_Theme.truncate(row.name or "?",
        self.width - PAD - scoreWidth - PAD - nameX, font)

    self:drawText(name, nameX, textY, nameColour.r, nameColour.g, nameColour.b, 1, font)
end
