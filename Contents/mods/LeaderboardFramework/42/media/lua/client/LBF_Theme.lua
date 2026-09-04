----------
--ESTRAL--
----------

LBF = LBF or {}
LBF_Theme = LBF_Theme or {}

-- NeatUI's end caps take a tint and the body does not, so state is carried by tinting
-- the caps and filling the body behind them.
LBF_Theme.STATES = {
    disabled = { cap = { 0.45, 0.45, 0.45 }, alpha = 0.45, fill = nil,
                 text = { 0.42, 0.42, 0.42 } },
    normal   = { cap = { 0.72, 0.72, 0.72 }, alpha = 0.85, fill = { 1, 1, 1, 0.03 },
                 text = { 0.84, 0.84, 0.84 } },
    hover    = { cap = { 1.00, 1.00, 1.00 }, alpha = 1.00, fill = { 1, 1, 1, 0.10 },
                 text = { 1.00, 1.00, 1.00 } },
    pressed  = { cap = { 0.85, 0.85, 0.85 }, alpha = 1.00, fill = { 0, 0, 0, 0.25 },
                 text = { 0.92, 0.92, 0.92 } },
    selected = { cap = { 0.98, 0.82, 0.45 }, alpha = 1.00, fill = { 0.98, 0.82, 0.45, 0.12 },
                 text = { 1.00, 0.93, 0.74 } },
}

LBF_Theme.COL_FRAME = { r = 1, g = 1, b = 1, a = 0.09 }
LBF_Theme.COL_WELL = { r = 0, g = 0, b = 0, a = 0.25 }

LBF_Theme.COL_TITLE = { r = 0.90, g = 0.91, b = 0.90 }
LBF_Theme.COL_TEXT = { r = 0.68, g = 0.68, b = 0.68 }
LBF_Theme.COL_DIM = { r = 0.50, g = 0.50, b = 0.50 }
LBF_Theme.COL_SCORE = { r = 0.80, g = 0.74, b = 0.50 }

-- the top three read at a glance from the accent bar alone, which is the only thing
-- separating a leaderboard from a list of names.
LBF_Theme.COL_FIRST = { r = 0.98, g = 0.82, b = 0.45 }
LBF_Theme.COL_SECOND = { r = 0.78, g = 0.80, b = 0.84 }
LBF_Theme.COL_THIRD = { r = 0.80, g = 0.58, b = 0.38 }
LBF_Theme.COL_REST = { r = 0.38, g = 0.38, b = 0.38 }

LBF_Theme.COL_ME = { r = 0.55, g = 0.80, b = 0.95 }

function LBF_Theme.rankColour(rank)
    if rank == 1 then return LBF_Theme.COL_FIRST end
    if rank == 2 then return LBF_Theme.COL_SECOND end
    if rank == 3 then return LBF_Theme.COL_THIRD end
    return LBF_Theme.COL_REST
end

local TEXTURES = nil

function LBF_Theme.textures()
    if TEXTURES == nil then
        TEXTURES = {
            left = getTexture("media/ui/NeatUI/Button/Button_FULL_L.png"),
            middle = getTexture("media/ui/NeatUI/Button/Button_FULL_M.png"),
            right = getTexture("media/ui/NeatUI/Button/Button_FULL_R.png"),
        }
    end
    return TEXTURES
end

-- NeatUI fails silently when it has not loaded, so nothing calls truncateText directly.
function LBF_Theme.truncate(text, maxWidth, font)
    if NeatTool and type(NeatTool.truncateText) == "function" then
        return NeatTool.truncateText(text, maxWidth, font or UIFont.Small)
    end
    return text
end
