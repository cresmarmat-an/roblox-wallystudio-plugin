--!strict
--[[
======================================================================================
	INFLATE  -  DEFLATE (RFC 1951) decompressor
======================================================================================
	Wally serves packages as .zip archives, and the large majority of entries in a
	typical one are DEFLATE-compressed. Studio has no unzip, so the whole codec has
	to live here in Luau for the plugin to install anything at all.

	This runs on `buffer` rather than strings. The obvious Lua approach — build the
	output with string.char and table.concat — allocates a Lua string per byte and
	lands the GC in the middle of a 300 KB package. A buffer is a flat block of
	memory written into and resized by doubling, which is what keeps an install
	inside a couple of frames instead of visibly locking Studio up.

	DECODING STRATEGY
	Huffman codes here are canonical, so they can be decoded a bit at a time by
	walking code lengths (the classic "puff" method) with no tables at all. That is
	simple and correct but costs a loop iteration per bit, and the literal tree is
	hit once per output byte. So each tree also gets a ROOT_BITS-wide lookup table:
	peek 9 bits, and if the code starting there is 9 bits or shorter, the symbol and
	its true length come back in a single index. Longer codes are rare by
	construction — Huffman spends short codes on common symbols — so they fall back
	to the bit-at-a-time walk and cost nothing in the common case.

	Everything here is plain Luau with no Roblox API, which is deliberate: it lets
	tests/CodecTest.luau run this exact file under Lune against real archives
	downloaded from the registry.
======================================================================================
]]

local Inflate = {}

-- Longest legal Huffman code in DEFLATE. Bit reads are sized against this.
local MAX_BITS = 15
-- Width of the fast lookup table. 9 bits = 512 entries per tree: wide enough to
-- catch nearly every code, narrow enough that building one per dynamic block stays
-- cheap. Raising it grows build cost faster than it saves lookup time.
local ROOT_BITS = 9
local FAST_SIZE = 512

-- Powers of two, indexed 0..32, so the bit reader shifts by multiplying rather
-- than paying a bit32 call in its hottest loop.
local POW2 = {}
for i = 0, 32 do
	POW2[i] = 2 ^ i
end

-- RFC 1951 section 3.2.5. Length symbols 257..285 map to a base length plus a
-- count of extra bits read from the stream; distance symbols 0..29 likewise.
local LENGTH_BASE =
	{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LENGTH_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = {
	1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
	1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
}
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }

-- The code-length alphabet is itself Huffman-coded, and its 19 lengths arrive in
-- this order rather than symbol order — the trailing entries are the ones most
-- likely to be zero, so a truncated list drops the useless ones first.
local CLEN_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

type Huffman = {
	counts: { number },
	symbols: { number },
	fast: { number },
}

-- Huffman codes are written most-significant-bit-first but the stream is read
-- least-significant-bit-first, so the fast table has to be indexed by the code with
-- its bits reversed. Only ever called while building a table.
local function reverseBits(value: number, width: number): number
	local result = 0
	for _ = 1, width do
		result = result * 2 + value % 2
		value = (value - value % 2) / 2
	end
	return result
end

-- Turn a list of code lengths into a decodable tree. `lengths` is 1-based but the
-- symbols it describes are 0-based, which is why symbol values come out as i - 1.
local function buildHuffman(lengths: { number }, count: number): Huffman
	local counts = {}
	for length = 0, MAX_BITS do
		counts[length] = 0
	end
	for i = 1, count do
		local length = lengths[i]
		counts[length] = counts[length] + 1
	end

	-- Where each length's block of symbols starts inside the flat `symbols` array.
	local starts = {}
	local accumulated = 0
	for length = 1, MAX_BITS do
		starts[length] = accumulated
		accumulated += counts[length]
	end

	-- Symbols sorted by (length, symbol) — exactly the order canonical codes are
	-- assigned in, so a symbol's position within its block IS its code offset.
	local cursor = table.clone(starts)
	local symbols = {}
	for i = 1, count do
		local length = lengths[i]
		if length ~= 0 then
			cursor[length] += 1
			symbols[cursor[length]] = i - 1
		end
	end

	-- First code of each length, per the canonical construction in RFC 1951 3.2.2.
	local nextCode = {}
	local code = 0
	local previous = 0
	for length = 1, MAX_BITS do
		code = (code + previous) * 2
		nextCode[length] = code
		previous = counts[length]
	end

	-- A zero entry means "no code of ROOT_BITS or fewer starts with these bits",
	-- which is an unambiguous miss: a real entry is symbol * 16 + length, and length
	-- is never 0, so a real entry is never 0 either.
	local fast = table.create(FAST_SIZE, 0)
	for length = 1, ROOT_BITS do
		local total = counts[length]
		local step = POW2[length]
		for offset = 0, total - 1 do
			local symbol = symbols[starts[length] + 1 + offset]
			local entry = symbol * 16 + length
			-- Every index whose low `length` bits match this code decodes to it,
			-- whatever the higher bits happen to be.
			local slot = reverseBits(nextCode[length] + offset, length)
			while slot < FAST_SIZE do
				fast[slot + 1] = entry
				slot += step
			end
		end
	end

	return { counts = counts, symbols = symbols, fast = fast }
end

-- The fixed trees of RFC 1951 3.2.6 never change, so they are built once at load
-- rather than per block.
local FIXED_LITERAL: Huffman
local FIXED_DISTANCE: Huffman
do
	local literal = {}
	for i = 1, 144 do
		literal[i] = 8
	end
	for i = 145, 256 do
		literal[i] = 9
	end
	for i = 257, 280 do
		literal[i] = 7
	end
	for i = 281, 288 do
		literal[i] = 8
	end
	FIXED_LITERAL = buildHuffman(literal, 288)

	local distance = {}
	for i = 1, 32 do
		distance[i] = 5
	end
	FIXED_DISTANCE = buildHuffman(distance, 32)
end

--[[
	Decompress a raw DEFLATE stream.

	`source` holds the compressed bytes. `sizeHint` is the expected output size when
	it is known — the ZIP central directory records it — which lets the output be
	allocated once at the right size instead of doubling its way there.

	Returns the decompressed buffer. Raises on malformed input.
]]
function Inflate.Decompress(source: buffer, sizeHint: number?): buffer
	local sourceLength = buffer.len(source)
	local position = 0

	-- `hold` is a bit reservoir filled a byte at a time from the low end; `held`
	-- counts the valid bits in it. It never exceeds 24 bits, so the arithmetic stays
	-- exact in a double and needs no bit32.
	local hold = 0
	local held = 0

	local output = buffer.create(math.max(sizeHint or 0, 1024))
	local outputLength = 0
	local capacity = buffer.len(output)

	local function reserve(extra: number)
		local required = outputLength + extra
		if required <= capacity then
			return
		end
		local grown = capacity * 2
		while grown < required do
			grown *= 2
		end
		local bigger = buffer.create(grown)
		buffer.copy(bigger, 0, output, 0, outputLength)
		output = bigger
		capacity = grown
	end

	-- Reads past the end yield zero bits rather than erroring. A well-formed stream
	-- ends on an end-of-block symbol, and peeking ROOT_BITS to decode that symbol
	-- legitimately runs a byte or two past the last one. Real truncation is caught
	-- after the block loop, where the overrun is far larger than that.
	local function need(bits: number)
		while held < bits do
			local byte = 0
			if position < sourceLength then
				byte = buffer.readu8(source, position)
			end
			position += 1
			hold += byte * POW2[held]
			held += 8
		end
	end

	local function takeBits(bits: number): number
		if bits == 0 then
			return 0
		end
		need(bits)
		local divisor = POW2[bits]
		local value = hold % divisor
		hold = (hold - value) / divisor
		held -= bits
		return value
	end

	local function decode(tree: Huffman): number
		need(ROOT_BITS)
		local entry = tree.fast[hold % FAST_SIZE + 1]
		if entry ~= 0 then
			local length = entry % 16
			local divisor = POW2[length]
			hold = (hold - hold % divisor) / divisor
			held -= length
			return (entry - length) / 16
		end

		-- Longer than ROOT_BITS: walk the lengths, consuming a bit per step, and
		-- stop as soon as the code so far falls inside the range of codes of that
		-- length. `first` tracks the first code of the current length, `index` the
		-- start of that length's symbol block.
		local counts = tree.counts
		local symbols = tree.symbols
		local code = 0
		local first = 0
		local index = 0
		for length = 1, MAX_BITS do
			code += takeBits(1)
			local total = counts[length]
			if code - first < total then
				return symbols[index + (code - first) + 1]
			end
			index += total
			first = (first + total) * 2
			code *= 2
		end
		error("Inflate: invalid Huffman code")
	end

	local function inflateStored()
		-- Stored blocks restart on a byte boundary; drop the partial byte.
		local partial = held % 8
		if partial > 0 then
			takeBits(partial)
		end

		local length = takeBits(16)
		local inverse = takeBits(16)
		if length + inverse ~= 0xFFFF then
			error("Inflate: stored block length check failed")
		end

		reserve(length)
		-- Whole bytes may already be sitting in the reservoir from an earlier
		-- refill, so drain those before touching the source buffer again.
		while length > 0 and held >= 8 do
			buffer.writeu8(output, outputLength, hold % 256)
			hold = (hold - hold % 256) / 256
			held -= 8
			outputLength += 1
			length -= 1
		end
		if length > 0 then
			if position + length > sourceLength then
				error("Inflate: stored block runs past end of data")
			end
			buffer.copy(output, outputLength, source, position, length)
			outputLength += length
			position += length
		end
	end

	local function inflateBlock(literalTree: Huffman, distanceTree: Huffman)
		while true do
			local symbol = decode(literalTree)

			if symbol < 256 then
				reserve(1)
				buffer.writeu8(output, outputLength, symbol)
				outputLength += 1
			elseif symbol == 256 then
				return
			else
				local lengthCode = symbol - 256
				if lengthCode > 29 then
					error("Inflate: invalid length symbol")
				end
				local length = LENGTH_BASE[lengthCode] + takeBits(LENGTH_EXTRA[lengthCode])

				local distanceCode = decode(distanceTree) + 1
				if distanceCode > 30 then
					error("Inflate: invalid distance symbol")
				end
				local distance = DIST_BASE[distanceCode] + takeBits(DIST_EXTRA[distanceCode])
				if distance > outputLength then
					error("Inflate: distance reaches back before start of output")
				end

				reserve(length)
				local from = outputLength - distance
				if distance >= length then
					-- Source and destination do not overlap, so this is a straight
					-- block move.
					buffer.copy(output, outputLength, output, from, length)
				else
					-- Overlapping by design: the match reads bytes this very copy is
					-- still writing, which is how DEFLATE encodes a repeated run. It
					-- has to stay byte-at-a-time for that to come out right.
					for i = 0, length - 1 do
						buffer.writeu8(output, outputLength + i, buffer.readu8(output, from + i))
					end
				end
				outputLength += length
			end
		end
	end

	local function inflateDynamic()
		local literalCount = takeBits(5) + 257
		local distanceCount = takeBits(5) + 1
		local codeLengthCount = takeBits(4) + 4

		local codeLengths = {}
		for i = 1, 19 do
			codeLengths[i] = 0
		end
		for i = 1, codeLengthCount do
			codeLengths[CLEN_ORDER[i] + 1] = takeBits(3)
		end
		local codeLengthTree = buildHuffman(codeLengths, 19)

		-- Literal and distance lengths arrive as one run-length-encoded sequence and
		-- are only split apart afterwards.
		local total = literalCount + distanceCount
		local lengths = {}
		local i = 1
		while i <= total do
			local symbol = decode(codeLengthTree)
			if symbol < 16 then
				lengths[i] = symbol
				i += 1
			else
				local repeated, value
				if symbol == 16 then
					if i == 1 then
						error("Inflate: repeat with no previous length")
					end
					value = lengths[i - 1]
					repeated = 3 + takeBits(2)
				elseif symbol == 17 then
					value = 0
					repeated = 3 + takeBits(3)
				else
					value = 0
					repeated = 11 + takeBits(7)
				end
				if i + repeated - 1 > total then
					error("Inflate: code length repeat overflows")
				end
				for _ = 1, repeated do
					lengths[i] = value
					i += 1
				end
			end
		end

		local literalLengths = table.move(lengths, 1, literalCount, 1, {})
		local distanceLengths = table.move(lengths, literalCount + 1, total, 1, {})

		inflateBlock(buildHuffman(literalLengths, literalCount), buildHuffman(distanceLengths, distanceCount))
	end

	repeat
		local isFinal = takeBits(1)
		local blockType = takeBits(2)

		if blockType == 0 then
			inflateStored()
		elseif blockType == 1 then
			inflateBlock(FIXED_LITERAL, FIXED_DISTANCE)
		elseif blockType == 2 then
			inflateDynamic()
		else
			error("Inflate: reserved block type")
		end
	until isFinal == 1

	-- Peeking legitimately overruns by a byte or two (see `need`); anything past
	-- that means the stream ended mid-block.
	if position > sourceLength + 4 then
		error("Inflate: compressed data ended early")
	end

	-- Trim to the exact length, since everything downstream reads buffer.len().
	local trimmed = buffer.create(outputLength)
	buffer.copy(trimmed, 0, output, 0, outputLength)
	return trimmed
end

return Inflate
