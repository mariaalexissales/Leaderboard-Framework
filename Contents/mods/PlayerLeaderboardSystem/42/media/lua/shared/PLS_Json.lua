----------
--ESTRAL--
----------

require "PLS_Core"

-- the game ships no json for lua. the .json files under Translate are read by java, not by
-- anything reachable from here, so both halves of this are ours.
--
-- the reader is a real parser rather than a pattern match on purpose. fixing somebody's score
-- by hand is half the reason the backup is json at all, and a hand-edited file comes back
-- with whitespace, a different key order and escapes we never wrote.

PLS_Json = PLS_Json or {}

-- ----------------------------------------------------------------------------
-- writing
-- ----------------------------------------------------------------------------

-- only what json actually requires: the quote, the backslash and the control characters.
-- everything else goes out as raw utf-8, which is valid and leaves a non-ascii name readable
-- to whoever opens the file.
local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\",
    ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function PLS_escape(text)
    local out = string.gsub(text, '[%c"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
    end)
    return out
end

-- lua prints whole numbers as 8412.0 through %s once they have been through arithmetic, and
-- a score is a count. anything genuinely fractional -- hours survived -- keeps its point.
local function PLS_number(value)
    if value ~= value or value == math.huge or value == -math.huge then return "0" end
    if value == math.floor(value) and math.abs(value) < 1e15 then
        return string.format("%d", value)
    end
    return tostring(value)
end

-- sorted keys, so two saves of the same table are the same bytes and a diff of the file says
-- something. tables are written as objects whatever their keys: nothing here is an array.
local function PLS_encode(value, indent, out)
    local kind = type(value)

    if kind == "number" then
        out[#out + 1] = PLS_number(value)
        return
    end

    if kind == "string" then
        out[#out + 1] = '"' .. PLS_escape(value) .. '"'
        return
    end

    if kind == "boolean" then
        out[#out + 1] = value and "true" or "false"
        return
    end

    if kind ~= "table" then
        out[#out + 1] = "null"
        return
    end

    -- the keys themselves, not their names: a numeric key stringified for sorting would no
    -- longer index the table it came from. sorted so two saves of one table are the same
    -- bytes and a diff of the file says something.
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    if #keys == 0 then
        out[#out + 1] = "{}"
        return
    end

    local inner = indent .. "  "
    out[#out + 1] = "{\n"

    for i, key in ipairs(keys) do
        out[#out + 1] = inner .. '"' .. PLS_escape(tostring(key)) .. '": '
        PLS_encode(value[key], inner, out)
        out[#out + 1] = (i < #keys) and ",\n" or "\n"
    end

    out[#out + 1] = indent .. "}"
end

function PLS_Json.encode(value)
    local out = {}
    PLS_encode(value, "", out)
    return table.concat(out)
end

-- ----------------------------------------------------------------------------
-- reading
-- ----------------------------------------------------------------------------

local UNESCAPES = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

-- a codepoint back to utf-8, for the \uXXXX a hand editor or another tool might leave behind.
-- we never write these ourselves.
local function PLS_utf8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    end
    if cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40))
    end
    -- four bytes, for anything past the basic plane. an emoji in a username lands here.
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40))
end

local Parser = {}
Parser.__index = Parser

function Parser.new(text)
    return setmetatable({ text = text, pos = 1, len = #text }, Parser)
end

function Parser:fail(message)
    error("[PLS_Json] " .. message .. " at character " .. self.pos, 0)
end

function Parser:skip()
    local _, stop = string.find(self.text, "^[ \t\r\n]*", self.pos)
    self.pos = stop + 1
end

function Parser:peek()
    return string.sub(self.text, self.pos, self.pos)
end

function Parser:expect(char)
    if self:peek() ~= char then self:fail("expected " .. char) end
    self.pos = self.pos + 1
end

function Parser:readString()
    self:expect('"')

    local parts = {}
    while true do
        if self.pos > self.len then self:fail("unterminated string") end

        local char = string.sub(self.text, self.pos, self.pos)
        self.pos = self.pos + 1

        if char == '"' then break end

        if char ~= "\\" then
            parts[#parts + 1] = char
        else
            local code = string.sub(self.text, self.pos, self.pos)
            self.pos = self.pos + 1

            if code == "u" then
                local hex = string.sub(self.text, self.pos, self.pos + 3)
                if not string.match(hex, "^%x%x%x%x$") then self:fail("bad \\u escape") end
                self.pos = self.pos + 4

                local cp = tonumber(hex, 16)

                -- a high surrogate is only half a character. json has no other way to write
                -- a codepoint past the basic plane, so an emoji in a username arrives as a
                -- pair, and decoding the halves apart gives two invalid three-byte sequences
                -- where one four-byte character belongs.
                if cp >= 0xD800 and cp <= 0xDBFF
                    and string.sub(self.text, self.pos, self.pos + 1) == "\\u" then
                    local tail = string.sub(self.text, self.pos + 2, self.pos + 5)
                    local low = string.match(tail, "^%x%x%x%x$") and tonumber(tail, 16) or nil

                    if low and low >= 0xDC00 and low <= 0xDFFF then
                        self.pos = self.pos + 6
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
                    end
                end

                parts[#parts + 1] = PLS_utf8(cp)
            elseif UNESCAPES[code] then
                parts[#parts + 1] = UNESCAPES[code]
            else
                self:fail("bad escape \\" .. tostring(code))
            end
        end
    end

    return table.concat(parts)
end

function Parser:readNumber()
    local _, stop = string.find(self.text, "^%-?%d+%.?%d*[eE]?[%+%-]?%d*", self.pos)
    if not stop then self:fail("bad number") end

    local raw = string.sub(self.text, self.pos, stop)
    local value = tonumber(raw)
    if not value then self:fail("bad number " .. raw) end

    self.pos = stop + 1
    return value
end

function Parser:readValue()
    self:skip()

    local char = self:peek()

    if char == "" then self:fail("unexpected end of input") end
    if char == '"' then return self:readString() end
    if char == "{" then return self:readObject() end
    if char == "[" then return self:readArray() end

    if string.sub(self.text, self.pos, self.pos + 3) == "true" then
        self.pos = self.pos + 4
        return true
    end
    if string.sub(self.text, self.pos, self.pos + 4) == "false" then
        self.pos = self.pos + 5
        return false
    end
    -- null comes back as a marker, not nil: assigning nil into a table is the same as never
    -- having had the key, and a caller checking for the key would be told a lie.
    if string.sub(self.text, self.pos, self.pos + 3) == "null" then
        self.pos = self.pos + 4
        return PLS_Json.NULL
    end

    return self:readNumber()
end

function Parser:readObject()
    self:expect("{")
    local out = {}

    self:skip()
    if self:peek() == "}" then
        self.pos = self.pos + 1
        return out
    end

    while true do
        self:skip()
        local key = self:readString()

        self:skip()
        self:expect(":")

        out[key] = self:readValue()

        self:skip()
        local char = self:peek()

        if char == "," then
            self.pos = self.pos + 1
        elseif char == "}" then
            self.pos = self.pos + 1
            return out
        else
            self:fail("expected , or } in object")
        end
    end
end

-- nothing we write is an array, but a hand-edited or externally generated file may contain
-- one and choking on it would be worse than carrying it.
function Parser:readArray()
    self:expect("[")
    local out = {}

    self:skip()
    if self:peek() == "]" then
        self.pos = self.pos + 1
        return out
    end

    while true do
        out[#out + 1] = self:readValue()

        self:skip()
        local char = self:peek()

        if char == "," then
            self.pos = self.pos + 1
        elseif char == "]" then
            self.pos = self.pos + 1
            return out
        else
            self:fail("expected , or ] in array")
        end
    end
end

-- a distinct value for json null, so a key that is present but null can be told from one that
-- is absent. compared by identity, never written back out.
PLS_Json.NULL = PLS_Json.NULL or setmetatable({}, { __tostring = function() return "null" end })

-- returns the value, or nil and a reason. a corrupt backup has to degrade to "no backup" --
-- taking the server down over a file that is only ever a second copy would be the worse bug.
function PLS_Json.decode(text)
    if type(text) ~= "string" or text == "" then return nil, "empty input" end

    local parser = Parser.new(text)

    local ok, result = pcall(function()
        local value = parser:readValue()
        parser:skip()
        if parser.pos <= parser.len then parser:fail("trailing content") end
        return value
    end)

    if not ok then return nil, tostring(result) end
    return result
end
