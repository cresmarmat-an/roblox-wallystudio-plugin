--!strict
--[[
======================================================================================
	ZIP  -  archive reader for the registry's package downloads
======================================================================================
	Reads a .zip from the central directory backwards, which is the only correct way
	to do it: the local headers scattered through the file can disagree with the
	directory (streamed writers leave sizes as zero there and put the real values in
	a trailing data descriptor), and the directory is authoritative.

	Entries are decompressed lazily. A package archive is frequently the whole source
	repository — Roact ships its docs, benchmarks and CI config — and the installer
	only ever wants the handful of files under the project's source directory, so
	inflating all 147 entries up front would be mostly wasted work.

	Every extracted entry is checked against the CRC-32 in its directory record. A
	truncated HTTP response otherwise turns into a ModuleScript full of garbage that
	fails at require time with nothing pointing back at the download.

	Plain Luau, no Roblox API, so tests/CodecTest.luau can run it under Lune.
======================================================================================
]]

local Inflate = require(script.Parent.Inflate)

local Zip = {}

local SIGNATURE_EOCD = 0x06054B50
local SIGNATURE_CENTRAL = 0x02014B50
local SIGNATURE_LOCAL = 0x04034B50

local METHOD_STORE = 0
local METHOD_DEFLATE = 8

-- A zip comment can be 64 KB, so the end-of-central-directory record is not
-- necessarily the last 22 bytes; it can sit that far back from the end.
local MAX_COMMENT = 0xFFFF

-- Sizes are 32-bit fields. This sentinel means "the real value lives in a Zip64
-- extra field", which the registry has never produced for a package.
local ZIP64_SENTINEL = 0xFFFFFFFF

export type Entry = {
	name: string,
	isDirectory: boolean,
	method: number,
	crc: number,
	compressedSize: number,
	uncompressedSize: number,
	headerOffset: number,
}

export type Archive = {
	Entries: { Entry },
	ByName: { [string]: Entry },
	Read: (self: Archive, entry: Entry) -> buffer,
	ReadString: (self: Archive, name: string) -> string?,
}

-- Standard CRC-32 (the one zip uses), reflected, polynomial 0xEDB88320. The table
-- is built once at load — 256 entries, cheaper than recomputing per byte.
local CRC_TABLE = buffer.create(256 * 4)
do
	for i = 0, 255 do
		local value = i
		for _ = 1, 8 do
			if value % 2 == 1 then
				value = bit32.bxor(bit32.rshift(value, 1), 0xEDB88320)
			else
				value = bit32.rshift(value, 1)
			end
		end
		buffer.writeu32(CRC_TABLE, i * 4, value)
	end
end

local function crc32(data: buffer): number
	local crc = 0xFFFFFFFF
	local length = buffer.len(data)
	for i = 0, length - 1 do
		local index = bit32.band(bit32.bxor(crc, buffer.readu8(data, i)), 0xFF)
		crc = bit32.bxor(bit32.rshift(crc, 8), buffer.readu32(CRC_TABLE, index * 4))
	end
	return bit32.bxor(crc, 0xFFFFFFFF)
end

Zip.Crc32 = crc32

-- Scan backwards for the end-of-central-directory signature. Searching from the end
-- rather than the start matters when a package's own files happen to contain the
-- signature bytes, which is possible in compressed data.
local function findEndOfCentralDirectory(data: buffer): number
	local length = buffer.len(data)
	if length < 22 then
		error("Zip: file is too small to be an archive")
	end
	local earliest = math.max(0, length - MAX_COMMENT - 22)
	for offset = length - 22, earliest, -1 do
		if buffer.readu32(data, offset) == SIGNATURE_EOCD then
			return offset
		end
	end
	error("Zip: no end-of-central-directory record (not a zip file, or the download was truncated)")
end

--[[
	Parse an archive's directory. Entry data is not decompressed until `read` asks
	for it.
]]
function Zip.Read(data: buffer): Archive
	local endOffset = findEndOfCentralDirectory(data)
	local entryCount = buffer.readu16(data, endOffset + 10)
	local directoryOffset = buffer.readu32(data, endOffset + 16)

	if directoryOffset == ZIP64_SENTINEL then
		error("Zip: Zip64 archives are not supported")
	end

	local entries: { Entry } = {}
	local byName: { [string]: Entry } = {}
	local cursor = directoryOffset

	for _ = 1, entryCount do
		if buffer.readu32(data, cursor) ~= SIGNATURE_CENTRAL then
			error("Zip: corrupt central directory")
		end

		local method = buffer.readu16(data, cursor + 10)
		local crc = buffer.readu32(data, cursor + 16)
		local compressedSize = buffer.readu32(data, cursor + 20)
		local uncompressedSize = buffer.readu32(data, cursor + 24)
		local nameLength = buffer.readu16(data, cursor + 28)
		local extraLength = buffer.readu16(data, cursor + 30)
		local commentLength = buffer.readu16(data, cursor + 32)
		local headerOffset = buffer.readu32(data, cursor + 42)
		local name = buffer.readstring(data, cursor + 46, nameLength)

		if compressedSize == ZIP64_SENTINEL or uncompressedSize == ZIP64_SENTINEL then
			error(`Zip: entry "{name}" needs Zip64, which is not supported`)
		end

		local entry: Entry = {
			name = name,
			-- Directory entries are recorded with a trailing slash and no data. The
			-- installer builds its folders from the paths it actually needs, so these
			-- are kept only so callers can skip them.
			isDirectory = name:sub(-1) == "/",
			method = method,
			crc = crc,
			compressedSize = compressedSize,
			uncompressedSize = uncompressedSize,
			headerOffset = headerOffset,
		}

		table.insert(entries, entry)
		byName[name] = entry

		cursor += 46 + nameLength + extraLength + commentLength
	end

	local archive = {} :: Archive
	archive.Entries = entries
	archive.ByName = byName

	function archive.Read(_self: Archive, entry: Entry): buffer
		if entry.isDirectory then
			return buffer.create(0)
		end
		if buffer.readu32(data, entry.headerOffset) ~= SIGNATURE_LOCAL then
			error(`Zip: entry "{entry.name}" has no local header`)
		end

		-- The local header's own name and extra lengths are what position the data,
		-- and its extra field is routinely a different size from the copy in the
		-- central directory. Reading these from the directory record instead is the
		-- classic way to end up decompressing from a few bytes off.
		local nameLength = buffer.readu16(data, entry.headerOffset + 26)
		local extraLength = buffer.readu16(data, entry.headerOffset + 28)
		local dataOffset = entry.headerOffset + 30 + nameLength + extraLength

		if dataOffset + entry.compressedSize > buffer.len(data) then
			error(`Zip: entry "{entry.name}" extends past the end of the archive`)
		end

		local raw = buffer.create(entry.compressedSize)
		buffer.copy(raw, 0, data, dataOffset, entry.compressedSize)

		local result: buffer
		if entry.method == METHOD_STORE then
			result = raw
		elseif entry.method == METHOD_DEFLATE then
			result = Inflate.Decompress(raw, entry.uncompressedSize)
		else
			error(`Zip: entry "{entry.name}" uses unsupported compression method {entry.method}`)
		end

		if buffer.len(result) ~= entry.uncompressedSize then
			error(`Zip: entry "{entry.name}" decompressed to the wrong size`)
		end
		if crc32(result) ~= entry.crc then
			error(`Zip: entry "{entry.name}" failed its checksum — the download is corrupt`)
		end

		return result
	end

	function archive.ReadString(self: Archive, name: string): string?
		local entry = byName[name]
		if not entry or entry.isDirectory then
			return nil
		end
		return buffer.tostring(self:Read(entry))
	end

	return archive
end

return Zip
