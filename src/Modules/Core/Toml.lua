--!strict
--[[
======================================================================================
	TOML  -  parser and writer for wally.toml manifests
======================================================================================
	Enough TOML to read and write a Wally manifest faithfully, and no more. That
	covers table headers, bare and quoted keys, basic and literal strings (including
	the triple-quoted forms descriptions sometimes use), integers, floats, booleans,
	arrays spanning multiple lines, and inline tables.

	Deliberately left out: dates and times, which no manifest field uses. They parse
	as their raw text rather than erroring, so a manifest carrying one somewhere
	unexpected still loads instead of refusing the whole file over a field nothing
	reads.

	Parsing returns (value, nil) or (nil, message). Manifests routinely arrive pasted
	in by hand, so a bad one is an ordinary outcome to show in the UI, not an
	exception to trap at every call site.
======================================================================================
]]

local Toml = {}

local ESCAPES = {
	b = "\b",
	t = "\t",
	n = "\n",
	f = "\f",
	r = "\r",
	['"'] = '"',
	["\\"] = "\\",
}

type Parser = {
	text: string,
	position: number,
	length: number,
}

local function fail(parser: Parser, message: string): string
	-- Report a line number: the input is usually a file the user can go and look at.
	local line = 1
	for _ in parser.text:sub(1, parser.position):gmatch("\n") do
		line += 1
	end
	return `line {line}: {message}`
end

local function peek(parser: Parser, offset: number?): string
	local at = parser.position + (offset or 0)
	return parser.text:sub(at, at)
end

local function skipSpaces(parser: Parser)
	while parser.position <= parser.length do
		local character = peek(parser)
		if character == " " or character == "\t" or character == "\r" then
			parser.position += 1
		else
			break
		end
	end
end

-- Skip whitespace, newlines and comments. Used between array elements, where TOML
-- allows the value list to be spread across lines with comments between them.
local function skipTrivia(parser: Parser)
	while parser.position <= parser.length do
		local character = peek(parser)
		if character == " " or character == "\t" or character == "\r" or character == "\n" then
			parser.position += 1
		elseif character == "#" then
			while parser.position <= parser.length and peek(parser) ~= "\n" do
				parser.position += 1
			end
		else
			break
		end
	end
end

local function parseBasicString(parser: Parser): (string?, string?)
	local multiline = parser.text:sub(parser.position, parser.position + 2) == '"""'
	parser.position += multiline and 3 or 1

	-- A newline immediately after the opening delimiter is not part of the value.
	if multiline and peek(parser) == "\n" then
		parser.position += 1
	end

	local pieces = {}
	while true do
		if parser.position > parser.length then
			return nil, fail(parser, "unterminated string")
		end
		local character = peek(parser)

		if multiline and parser.text:sub(parser.position, parser.position + 2) == '"""' then
			parser.position += 3
			break
		elseif not multiline and character == '"' then
			parser.position += 1
			break
		elseif not multiline and character == "\n" then
			return nil, fail(parser, "unterminated string")
		elseif character == "\\" then
			local escape = peek(parser, 1)
			if ESCAPES[escape] then
				table.insert(pieces, ESCAPES[escape])
				parser.position += 2
			elseif escape == "u" or escape == "U" then
				local width = escape == "u" and 4 or 8
				local digits = parser.text:sub(parser.position + 2, parser.position + 1 + width)
				local codepoint = tonumber(digits, 16)
				if not codepoint or #digits < width then
					return nil, fail(parser, "invalid unicode escape")
				end
				table.insert(pieces, utf8.char(codepoint))
				parser.position += 2 + width
			elseif multiline and (escape == "\n" or escape == "\r" or escape == " " or escape == "\t") then
				-- A backslash at end of line in a multi-line string swallows the
				-- newline and the indentation that follows it.
				parser.position += 1
				skipTrivia(parser)
			else
				return nil, fail(parser, `unknown escape "\\{escape}"`)
			end
		else
			table.insert(pieces, character)
			parser.position += 1
		end
	end

	return table.concat(pieces), nil
end

local function parseLiteralString(parser: Parser): (string?, string?)
	local multiline = parser.text:sub(parser.position, parser.position + 2) == "'''"
	parser.position += multiline and 3 or 1
	if multiline and peek(parser) == "\n" then
		parser.position += 1
	end

	local closing = multiline and "'''" or "'"
	local start = parser.position
	while true do
		if parser.position > parser.length then
			return nil, fail(parser, "unterminated string")
		end
		if parser.text:sub(parser.position, parser.position + #closing - 1) == closing then
			break
		end
		if not multiline and peek(parser) == "\n" then
			return nil, fail(parser, "unterminated string")
		end
		parser.position += 1
	end

	local value = parser.text:sub(start, parser.position - 1)
	parser.position += #closing
	return value, nil
end

local parseValue: (Parser) -> (any, string?)

local function parseArray(parser: Parser): (any, string?)
	parser.position += 1
	local items = {}
	while true do
		skipTrivia(parser)
		if parser.position > parser.length then
			return nil, fail(parser, "unterminated array")
		end
		if peek(parser) == "]" then
			parser.position += 1
			break
		end

		local value, error = parseValue(parser)
		if error then
			return nil, error
		end
		table.insert(items, value)

		skipTrivia(parser)
		if peek(parser) == "," then
			parser.position += 1
		elseif peek(parser) == "]" then
			parser.position += 1
			break
		else
			return nil, fail(parser, "expected , or ] in array")
		end
	end
	return items, nil
end

local function parseKey(parser: Parser): ({ string }?, string?)
	local parts = {}
	while true do
		skipSpaces(parser)
		local character = peek(parser)
		local part: string?

		if character == '"' then
			local value, error = parseBasicString(parser)
			if error then
				return nil, error
			end
			part = value
		elseif character == "'" then
			local value, error = parseLiteralString(parser)
			if error then
				return nil, error
			end
			part = value
		else
			local start = parser.position
			while parser.position <= parser.length and peek(parser):match("[%w_%-]") do
				parser.position += 1
			end
			if parser.position == start then
				return nil, fail(parser, "expected a key")
			end
			part = parser.text:sub(start, parser.position - 1)
		end

		table.insert(parts, part :: string)
		skipSpaces(parser)
		if peek(parser) == "." then
			parser.position += 1
		else
			break
		end
	end
	return parts, nil
end

local function parseInlineTable(parser: Parser): (any, string?)
	parser.position += 1
	local result = {}
	skipSpaces(parser)
	if peek(parser) == "}" then
		parser.position += 1
		return result, nil
	end

	while true do
		skipSpaces(parser)
		local key, keyError = parseKey(parser)
		if keyError then
			return nil, keyError
		end

		skipSpaces(parser)
		if peek(parser) ~= "=" then
			return nil, fail(parser, "expected = in inline table")
		end
		parser.position += 1

		local value, valueError = parseValue(parser)
		if valueError then
			return nil, valueError
		end

		local target = result
		local path = key :: { string }
		for i = 1, #path - 1 do
			target[path[i]] = target[path[i]] or {}
			target = target[path[i]]
		end
		target[path[#path]] = value

		skipSpaces(parser)
		if peek(parser) == "," then
			parser.position += 1
		elseif peek(parser) == "}" then
			parser.position += 1
			break
		else
			return nil, fail(parser, "expected , or } in inline table")
		end
	end
	return result, nil
end

function parseValue(parser: Parser): (any, string?)
	skipSpaces(parser)
	local character = peek(parser)

	if character == '"' then
		return parseBasicString(parser)
	elseif character == "'" then
		return parseLiteralString(parser)
	elseif character == "[" then
		return parseArray(parser)
	elseif character == "{" then
		return parseInlineTable(parser)
	end

	-- Everything else runs to the end of the value: a comma, a closing bracket, a
	-- comment or the end of the line.
	local start = parser.position
	while parser.position <= parser.length do
		local at = peek(parser)
		if at == "," or at == "]" or at == "}" or at == "\n" or at == "#" then
			break
		end
		parser.position += 1
	end
	local raw = parser.text:sub(start, parser.position - 1):match("^%s*(.-)%s*$") :: string

	if raw == "" then
		return nil, fail(parser, "expected a value")
	end
	if raw == "true" then
		return true, nil
	end
	if raw == "false" then
		return false, nil
	end

	-- TOML allows underscores as digit separators; Lua's tonumber does not.
	local numeric = tonumber((raw:gsub("_", "")))
	if numeric then
		return numeric, nil
	end

	-- Dates and anything else unrecognised survive as text rather than failing the
	-- whole manifest over a field nothing here reads.
	return raw, nil
end

--[[
	Parse a TOML document. Returns (table, nil) or (nil, message).
]]
function Toml.Parse(text: string): ({ [string]: any }?, string?)
	local parser: Parser = { text = text, position = 1, length = #text }
	local root: { [string]: any } = {}
	local current = root

	while parser.position <= parser.length do
		skipTrivia(parser)
		if parser.position > parser.length then
			break
		end

		if peek(parser) == "[" then
			local isArrayOfTables = peek(parser, 1) == "["
			parser.position += isArrayOfTables and 2 or 1

			local path, pathError = parseKey(parser)
			if pathError then
				return nil, pathError
			end

			skipSpaces(parser)
			local expected = isArrayOfTables and "]]" or "]"
			if parser.text:sub(parser.position, parser.position + #expected - 1) ~= expected then
				return nil, fail(parser, "expected " .. expected .. " after table header")
			end
			parser.position += #expected

			local target = root
			local parts = path :: { string }
			for i = 1, #parts - 1 do
				if type(target[parts[i]]) ~= "table" then
					target[parts[i]] = {}
				end
				target = target[parts[i]]
			end

			local final = parts[#parts]
			if isArrayOfTables then
				if type(target[final]) ~= "table" then
					target[final] = {}
				end
				local entry = {}
				table.insert(target[final], entry)
				current = entry
			else
				if type(target[final]) ~= "table" then
					target[final] = {}
				end
				current = target[final]
			end
		else
			local key, keyError = parseKey(parser)
			if keyError then
				return nil, keyError
			end

			skipSpaces(parser)
			if peek(parser) ~= "=" then
				return nil, fail(parser, "expected = after key")
			end
			parser.position += 1

			local value, valueError = parseValue(parser)
			if valueError then
				return nil, valueError
			end

			local target = current
			local parts = key :: { string }
			for i = 1, #parts - 1 do
				if type(target[parts[i]]) ~= "table" then
					target[parts[i]] = {}
				end
				target = target[parts[i]]
			end
			target[parts[#parts]] = value
		end

		-- Trailing comment or blank space after a statement.
		skipSpaces(parser)
		if peek(parser) == "#" then
			while parser.position <= parser.length and peek(parser) ~= "\n" do
				parser.position += 1
			end
		end
	end

	return root, nil
end

-- Bare keys avoid quoting; anything else has to be quoted to round-trip. Wally
-- aliases are usually bare, but nothing stops someone using a dot or a space.
local function encodeKey(key: string): string
	if key:match("^[%w_%-]+$") then
		return key
	end
	return '"' .. key:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function encodeValue(value: any): string
	local kind = type(value)
	if kind == "string" then
		local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t")
		return '"' .. escaped .. '"'
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "number" then
		-- Whole numbers must not pick up a ".0", which would make them floats.
		if value % 1 == 0 and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return tostring(value)
	elseif kind == "table" then
		local pieces = {}
		for _, item in value do
			table.insert(pieces, encodeValue(item))
		end
		return "[" .. table.concat(pieces, ", ") .. "]"
	end
	return '""'
end

Toml.EncodeKey = encodeKey
Toml.EncodeValue = encodeValue

--[[
	Write a `[section]` with its keys in the given order.

	Order is an explicit argument rather than something inferred, because a manifest
	is a file a person reads and diffs. Lua's pair order would reshuffle the fields
	on every export and make every re-export look like a change.
]]
function Toml.EncodeSection(name: string, values: { [string]: any }, order: { string }?): string
	local lines = { `[{name}]` }
	local written: { [string]: boolean } = {}

	if order then
		for _, key in order do
			if values[key] ~= nil then
				table.insert(lines, `{encodeKey(key)} = {encodeValue(values[key])}`)
				written[key] = true
			end
		end
	end

	-- Anything not named in the order still gets written, alphabetically, so no
	-- field can be silently dropped on a round trip.
	local remaining = {}
	for key in values do
		if not written[key] then
			table.insert(remaining, key)
		end
	end
	table.sort(remaining)
	for _, key in remaining do
		table.insert(lines, `{encodeKey(key)} = {encodeValue(values[key])}`)
	end

	return table.concat(lines, "\n")
end

return Toml
