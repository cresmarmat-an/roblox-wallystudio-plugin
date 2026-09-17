--!strict
--[[
======================================================================================
	SEMVER  -  version parsing and Cargo-style requirement matching
======================================================================================
	Wally states dependencies the way Cargo does, because it is written in Rust and
	uses the same `semver` crate. That means a bare "1.2.3" is NOT an exact pin — it
	means ^1.2.3 — and the registry hands back already-expanded ranges like
	">=1.0.0, <2.0.0" in package metadata while a hand-written wally.toml usually
	says "^1". Both forms have to resolve to the same set of versions, or the plugin
	picks a different dependency than the CLI would for the same manifest.

	The caret rule is the one worth stating outright, because it is not "same major":
	it is "do not change the leftmost non-zero component". So ^1.2.3 allows <2.0.0,
	^0.2.3 allows only <0.3.0, and ^0.0.3 allows only <0.0.4. Pre-1.0 packages are
	common in this ecosystem, so getting that wrong would break a great many of them.

	Prereleases follow the same crate's rule: 2.0.0-beta does not satisfy ^1, and it
	does not satisfy >=1.0.0 either. A prerelease is only ever offered when the
	requirement itself names a prerelease on the same major.minor.patch, which keeps
	"install the latest" from ever handing someone an alpha.
======================================================================================
]]

local Semver = {}

export type Version = {
	major: number,
	minor: number,
	patch: number,
	prerelease: string?,
	build: string?,
	raw: string,
}

export type Comparator = {
	operator: string,
	version: Version,
}

export type Requirement = {
	comparators: { Comparator },
	raw: string,
}

--[[
	Parse a full "1.2.3", "1.2.3-rc.1" or "1.2.3+build" version. Returns nil rather
	than raising, since version strings routinely arrive from the network.
]]
function Semver.Parse(text: string): Version?
	if type(text) ~= "string" then
		return nil
	end
	local trimmed = text:match("^%s*(.-)%s*$") :: string
	if trimmed:sub(1, 1) == "v" then
		trimmed = trimmed:sub(2)
	end

	local major, minor, patch, rest = trimmed:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
	if not major then
		return nil
	end

	local prerelease: string? = nil
	local build: string? = nil

	if rest ~= "" then
		-- Build metadata is stripped before the prerelease is read, because "+" can
		-- follow a prerelease and never the other way round.
		local body, buildPart = (rest :: string):match("^(.-)%+(.*)$")
		if body then
			rest = body
			build = buildPart
		end
		if rest ~= "" then
			local pre = (rest :: string):match("^%-(.+)$")
			if not pre then
				return nil
			end
			prerelease = pre
		end
	end

	return {
		major = tonumber(major) :: number,
		minor = tonumber(minor) :: number,
		patch = tonumber(patch) :: number,
		prerelease = prerelease,
		build = build,
		raw = trimmed,
	}
end

-- Prerelease identifiers compare per semver rule 11: dot-separated, numeric ones
-- numerically and below alphanumeric ones, and a longer list wins ties.
local function comparePrerelease(left: string, right: string): number
	local leftParts = left:split(".")
	local rightParts = right:split(".")
	local count = math.max(#leftParts, #rightParts)

	for i = 1, count do
		local a = leftParts[i]
		local b = rightParts[i]
		if a == nil then
			return -1
		end
		if b == nil then
			return 1
		end
		if a ~= b then
			local numberA = tonumber(a)
			local numberB = tonumber(b)
			if numberA and numberB then
				return numberA < numberB and -1 or 1
			end
			-- A numeric identifier always ranks below an alphanumeric one.
			if numberA then
				return -1
			end
			if numberB then
				return 1
			end
			return a < b and -1 or 1
		end
	end
	return 0
end

--[[
	Order two versions: -1 if `left` is older, 1 if newer, 0 if equal. Build metadata
	is ignored, as the spec requires.
]]
function Semver.Compare(left: Version, right: Version): number
	if left.major ~= right.major then
		return left.major < right.major and -1 or 1
	end
	if left.minor ~= right.minor then
		return left.minor < right.minor and -1 or 1
	end
	if left.patch ~= right.patch then
		return left.patch < right.patch and -1 or 1
	end

	-- 1.0.0-rc.1 precedes 1.0.0; a release always outranks its own prereleases.
	if left.prerelease and not right.prerelease then
		return -1
	end
	if right.prerelease and not left.prerelease then
		return 1
	end
	if left.prerelease and right.prerelease then
		return comparePrerelease(left.prerelease, right.prerelease)
	end
	return 0
end

function Semver.Equals(left: Version, right: Version): boolean
	return Semver.Compare(left, right) == 0
end

-- Requirements may name only some components ("^1", "~1.2", "1.*"). Missing ones are
-- reported so caret and tilde can expand to the right upper bound.
local function parsePartial(text: string): (Version?, number)
	local cleaned = text:match("^%s*(.-)%s*$") :: string
	if cleaned:sub(1, 1) == "v" then
		cleaned = cleaned:sub(2)
	end
	if cleaned == "" or cleaned == "*" then
		return { major = 0, minor = 0, patch = 0, raw = "*" }, 0
	end

	local numbers = {}
	local prerelease: string? = nil
	local build: string? = nil

	local body, buildPart = cleaned:match("^(.-)%+(.*)$")
	if body then
		cleaned = body
		build = buildPart
	end
	local head, pre = cleaned:match("^(.-)%-(.+)$")
	if head then
		cleaned = head
		prerelease = pre
	end

	local specified = 0
	for part in cleaned:gmatch("[^%.]+") do
		if part == "*" or part == "x" or part == "X" then
			break
		end
		local value = tonumber(part)
		if not value or value < 0 or value % 1 ~= 0 then
			return nil, 0
		end
		specified += 1
		numbers[specified] = value
		if specified == 3 then
			break
		end
	end

	if specified == 0 then
		return { major = 0, minor = 0, patch = 0, raw = "*" }, 0
	end

	return {
		major = numbers[1],
		minor = numbers[2] or 0,
		patch = numbers[3] or 0,
		prerelease = prerelease,
		build = build,
		raw = cleaned,
	},
		specified
end

-- Expand caret/tilde/wildcard shorthand into explicit bounds, so matching only ever
-- deals with >=, >, <, <= and =.
local function expand(operator: string, version: Version, specified: number): { Comparator }
	local function upperBound(major: number, minor: number, patch: number): Comparator
		return { operator = "<", version = { major = major, minor = minor, patch = patch, raw = "" } }
	end

	if operator == "^" then
		local lower: Comparator = { operator = ">=", version = version }
		-- "Do not change the leftmost non-zero component" — see the header note.
		-- When every component is zero there is no non-zero one to hold, and the
		-- bound falls on the last component the requirement actually named: ^0.0.3
		-- allows only 0.0.3, ^0.0 allows all of 0.0.x, and ^0 allows all of 0.x.
		if version.major ~= 0 then
			return { lower, upperBound(version.major + 1, 0, 0) }
		elseif version.minor ~= 0 then
			return { lower, upperBound(0, version.minor + 1, 0) }
		elseif specified >= 3 then
			return { lower, upperBound(0, 0, version.patch + 1) }
		elseif specified == 2 then
			return { lower, upperBound(0, 1, 0) }
		else
			return { lower, upperBound(1, 0, 0) }
		end
	elseif operator == "~" then
		local lower: Comparator = { operator = ">=", version = version }
		if specified >= 2 then
			return { lower, upperBound(version.major, version.minor + 1, 0) }
		end
		return { lower, upperBound(version.major + 1, 0, 0) }
	elseif operator == "=" then
		-- A partial "=1.2" pins the components that were given and leaves the rest
		-- free, rather than demanding 1.2.0 exactly.
		if specified >= 3 then
			return { { operator = "=", version = version } }
		end
		local lower: Comparator = { operator = ">=", version = version }
		if specified == 2 then
			return { lower, upperBound(version.major, version.minor + 1, 0) }
		end
		return { lower, upperBound(version.major + 1, 0, 0) }
	end

	return { { operator = operator, version = version } }
end

--[[
	Parse a requirement such as "^1", ">=1.0.0, <2.0.0", "1.2.3" or "*".

	A bare version is a caret requirement, matching Cargo and therefore Wally.
]]
function Semver.ParseRequirement(text: string): Requirement?
	if type(text) ~= "string" then
		return nil
	end
	local trimmed = text:match("^%s*(.-)%s*$") :: string
	if trimmed == "" or trimmed == "*" then
		return { comparators = {}, raw = "*" }
	end

	local comparators: { Comparator } = {}
	for piece in trimmed:gmatch("[^,]+") do
		local part = piece:match("^%s*(.-)%s*$") :: string
		if part ~= "" then
			-- Two-character operators must be tried first, or ">=1" reads as ">".
			local operator = part:match("^([<>]=)") or part:match("^([%^~=<>])")
			local rest = part
			if operator then
				rest = part:sub(#operator + 1)
			else
				operator = "^"
			end

			local version, specified = parsePartial(rest)
			if not version then
				return nil
			end
			if version.raw == "*" and specified == 0 then
				-- "*" alone constrains nothing; anything paired with it still does.
				continue
			end
			for _, comparator in expand(operator, version, specified) do
				table.insert(comparators, comparator)
			end
		end
	end

	return { comparators = comparators, raw = trimmed }
end

local function satisfiesComparator(version: Version, comparator: Comparator): boolean
	local order = Semver.Compare(version, comparator.version)
	local operator = comparator.operator
	if operator == ">=" then
		return order >= 0
	elseif operator == ">" then
		return order > 0
	elseif operator == "<" then
		return order < 0
	elseif operator == "<=" then
		return order <= 0
	elseif operator == "=" then
		return order == 0
	end
	return false
end

--[[
	Does `version` satisfy `requirement`? Both may be given as strings for
	convenience; an unparseable input is treated as not matching rather than raising,
	since these come from package metadata written by third parties.
]]
function Semver.Satisfies(version: Version | string, requirement: Requirement | string): boolean
	local parsedVersion: Version?
	if type(version) == "string" then
		parsedVersion = Semver.Parse(version)
	else
		parsedVersion = version
	end

	local parsedRequirement: Requirement?
	if type(requirement) == "string" then
		parsedRequirement = Semver.ParseRequirement(requirement)
	else
		parsedRequirement = requirement
	end

	if not parsedVersion or not parsedRequirement then
		return false
	end

	for _, comparator in parsedRequirement.comparators do
		if not satisfiesComparator(parsedVersion, comparator) then
			return false
		end
	end

	-- A prerelease is only ever eligible when the requirement asked for one on the
	-- same major.minor.patch. Without this, ">=1.0.0" would happily select
	-- 2.0.0-alpha and hand an unfinished package to someone who asked for a stable
	-- range.
	if parsedVersion.prerelease then
		local invited = false
		for _, comparator in parsedRequirement.comparators do
			local target = comparator.version
			if
				target.prerelease
				and target.major == parsedVersion.major
				and target.minor == parsedVersion.minor
				and target.patch == parsedVersion.patch
			then
				invited = true
				break
			end
		end
		if not invited then
			return false
		end
	end

	return true
end

--[[
	Highest version in `versions` satisfying `requirement`, or nil. Inputs are raw
	strings as they arrive from the registry; unparseable entries are skipped.
]]
function Semver.MaxSatisfying(versions: { string }, requirement: Requirement | string): string?
	local parsedRequirement: Requirement?
	if type(requirement) == "string" then
		parsedRequirement = Semver.ParseRequirement(requirement)
	else
		parsedRequirement = requirement
	end
	if not parsedRequirement then
		return nil
	end

	local best: Version? = nil
	for _, candidate in versions do
		local parsed = Semver.Parse(candidate)
		if parsed and Semver.Satisfies(parsed, parsedRequirement) then
			if not best or Semver.Compare(parsed, best) > 0 then
				best = parsed
			end
		end
	end
	return best and best.raw or nil
end

--[[
	Sort raw version strings newest first. Used for version pickers, where the
	registry's own ordering is not guaranteed.
]]
function Semver.SortDescending(versions: { string }): { string }
	local parsed = {}
	for _, raw in versions do
		local version = Semver.Parse(raw)
		if version then
			table.insert(parsed, version)
		end
	end
	table.sort(parsed, function(left, right)
		return Semver.Compare(left, right) > 0
	end)

	local result = {}
	for _, version in parsed do
		table.insert(result, version.raw)
	end
	return result
end

--[[
	Newest non-prerelease version, falling back to the newest prerelease when a
	package has only ever published those — which is common for young packages.
]]
function Semver.Latest(versions: { string }): string?
	local sorted = Semver.SortDescending(versions)
	for _, raw in sorted do
		local parsed = Semver.Parse(raw)
		if parsed and not parsed.prerelease then
			return raw
		end
	end
	return sorted[1]
end

--[[
	The caret requirement that `wally install` would write for a given version, used
	when exporting a manifest.
]]
function Semver.CaretFor(version: string): string
	return `^{version}`
end

return Semver
