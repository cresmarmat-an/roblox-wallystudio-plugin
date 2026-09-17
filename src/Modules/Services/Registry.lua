--!nonstrict
--[[
======================================================================================
	REGISTRY  -  Wally registry HTTP client
======================================================================================
	Three endpoints, all unauthenticated:

	  /v1/package-search?query=       list packages matching a phrase
	  /v1/package-metadata/scope/name every published version and its dependencies
	  /v1/package-contents/.../version the package archive

	The contents endpoint answers 426 to a request without a Wally-Version header, so
	that header goes on every request rather than being remembered as a special case
	for one of them.

	Every call returns a result table instead of raising. Network failure is an
	ordinary outcome here — the whole feature is unreachable without HTTP — and it
	needs to reach the UI as something explainable with a next step, not as an error
	string from three frames down. `kind` is what the UI switches on; `message` is
	what it shows.

	CACHING
	A published version is immutable, so its metadata and archive can be cached for
	as long as Studio is open. Only the search index and the list of versions can
	change under us, and those get short time-to-live rather than none: typing in the
	search box would otherwise fire a request per keystroke.
======================================================================================
]]

local HttpService = game:GetService("HttpService")

local Constants = require(script.Parent.Parent.Config.Constants)
local Semver = require(script.Parent.Parent.Core.Semver)

local Registry = {}
Registry.__index = Registry

export type Result<T> = {
	ok: boolean,
	data: T?,
	kind: string?,
	message: string?,
}

export type SearchResult = {
	scope: string,
	name: string,
	fullName: string,
	description: string?,
	versions: { string },
	latest: string?,
}

export type VersionInfo = {
	version: string,
	realm: string,
	description: string?,
	license: string?,
	authors: { string },
	homepage: string?,
	repository: string?,
	dependencies: { [string]: string },
	serverDependencies: { [string]: string },
	devDependencies: { [string]: string },
}

export type Metadata = {
	scope: string,
	name: string,
	fullName: string,
	versions: { VersionInfo },
	byVersion: { [string]: VersionInfo },
	versionList: { string },
}

export type ParsedSpecifier = {
	scope: string,
	name: string,
	requirement: string?,
	alias: string?,
}

local function ok<T>(data: T): Result<T>
	return { ok = true, data = data }
end

local function err(kind: string, message: string): Result<any>
	return { ok = false, kind = kind, message = message }
end

function Registry.New(): Registry
	return setmetatable({
		baseUrl = Constants.DEFAULT_REGISTRY_API,
		_cache = {},
		_httpBlocked = false,
	}, Registry)
end

export type Registry = typeof(setmetatable(
	{} :: {
		baseUrl: string,
		_cache: { [string]: { at: number, value: any } },
		_httpBlocked: boolean,
	},
	Registry
))

--------------------------------------------------------------------------------------
-- CACHE
--------------------------------------------------------------------------------------
function Registry.ClearCache(self: Registry)
	table.clear(self._cache)
	self._httpBlocked = false
end

local function cached(self: Registry, key: string, lifetime: number): any?
	local entry = self._cache[key]
	if not entry then
		return nil
	end
	-- A lifetime of zero means "immutable, keep for the session".
	if lifetime > 0 and os.clock() - entry.at > lifetime then
		self._cache[key] = nil
		return nil
	end
	return entry.value
end

local function store(self: Registry, key: string, value: any): any
	self._cache[key] = { at = os.clock(), value = value }
	return value
end

--------------------------------------------------------------------------------------
-- TRANSPORT
--------------------------------------------------------------------------------------
--[[
	One request, with the registry's required header and uniform error mapping.

	Yields. Callers run inside task.spawn.
]]
local function request(self: Registry, url: string): Result<{ body: string, headers: { [string]: string } }>
	local success, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "GET",
			-- Only Wally-Version. Roblox locks a handful of headers — User-Agent among
			-- them — and setting a locked one makes RequestAsync fail outright rather
			-- than dropping the header, which looks exactly like the registry being
			-- unreachable. Identifying the client politely is not worth breaking every
			-- request for; Roblox sets its own User-Agent anyway.
			Headers = {
				["Wally-Version"] = Constants.WALLY_VERSION_HEADER,
			},
		})
	end)

	if not success then
		local message = tostring(response)
		-- Studio reports this as a plain error rather than a status code, and it is
		-- the single most common first-run failure, so it gets its own kind — the UI
		-- offers to fix it rather than showing the raw text.
		if message:find("Http requests are not enabled") or message:find("HttpEnabled") then
			self._httpBlocked = true
			return err("http_disabled", "HTTP requests are turned off for this place.")
		end
		-- A rejected header is a bug in this plugin, not a permission the user can
		-- grant, and it has to be told apart from one — Roblox phrases both with
		-- "not allowed". Conflating them once sent someone to enable a setting that
		-- was already on, because the message told them the request had been blocked.
		if message:find("Header") and message:find("not allowed") then
			return err(
				"bad_header",
				`This plugin sent a header Roblox rejects, so the request never left Studio. {message}`
			)
		end
		if message:find("trust check") or message:find("not allowed") then
			return err(
				"http_blocked",
				"Studio blocked the request to the Wally registry. Allow api.wally.run and try again."
			)
		end
		return err("network", `Could not reach the registry: {message}`)
	end

	self._httpBlocked = false

	if response.StatusCode == 404 then
		return err("not_found", "That package is not in the registry.")
	elseif response.StatusCode == 426 then
		-- Only reachable if the registry raises its minimum client version.
		return err("outdated_client", "The registry rejected this plugin's Wally version. The plugin needs an update.")
	elseif response.StatusCode == 429 then
		return err("rate_limited", "The registry is rate limiting requests. Wait a moment and try again.")
	elseif response.StatusCode < 200 or response.StatusCode >= 300 then
		return err("server", `The registry returned {response.StatusCode} {response.StatusMessage}.`)
	end

	return ok({ body = response.Body, headers = response.Headers })
end

--[[
	True when the last failure was Studio's HTTP switch rather than the network. The
	UI uses this to offer the one-click fix.
]]
function Registry.IsHttpBlocked(self: Registry): boolean
	return self._httpBlocked
end

--[[
	Turn HTTP requests on for this place.

	A plugin may set this where a game script may not, so the fix is a button rather
	than instructions for the command bar. It is a change to the user's place, so the
	UI asks before calling it.
]]
function Registry.EnableHttp(self: Registry): Result<boolean>
	local success, problem = pcall(function()
		HttpService.HttpEnabled = true
	end)
	if not success then
		return err("http_disabled", `Could not enable HTTP requests: {problem}`)
	end
	self._httpBlocked = false
	return ok(true)
end

--------------------------------------------------------------------------------------
-- SEARCH
--------------------------------------------------------------------------------------
--[[
	Packages matching a phrase, newest version first in each entry.
]]
function Registry.Search(self: Registry, query: string): Result<{ SearchResult }>
	local trimmed = query:match("^%s*(.-)%s*$") or ""
	if trimmed == "" then
		return ok({})
	end

	local key = `search:{trimmed:lower()}`
	local hit = cached(self, key, Constants.SEARCH_CACHE_SECONDS)
	if hit then
		return ok(hit)
	end

	local url = `{self.baseUrl}{Constants.ENDPOINT_SEARCH}?query={HttpService:UrlEncode(trimmed)}`
	local response = request(self, url)
	if not response.ok then
		return response :: any
	end

	local decoded
	local parsed = pcall(function()
		decoded = HttpService:JSONDecode(response.data.body)
	end)
	if not parsed or type(decoded) ~= "table" then
		return err("parse", "The registry sent a search response this plugin could not read.")
	end

	local results: { SearchResult } = {}
	for _, entry in decoded do
		if type(entry) == "table" and entry.scope and entry.name then
			local versions = Semver.SortDescending(entry.versions or {})
			table.insert(results, {
				scope = entry.scope,
				name = entry.name,
				fullName = `{entry.scope}/{entry.name}`,
				-- Most packages in the registry have no description at all, and the
				-- field arrives as JSON null when they do not.
				description = type(entry.description) == "string" and entry.description or nil,
				versions = versions,
				latest = Semver.Latest(versions),
			})
		end
		if #results >= Constants.MAX_SEARCH_RESULTS then
			break
		end
	end

	return ok(store(self, key, results))
end

--------------------------------------------------------------------------------------
-- METADATA
--------------------------------------------------------------------------------------
local function readDependencies(source: any): { [string]: string }
	local result: { [string]: string } = {}
	if type(source) == "table" then
		for alias, specifier in source do
			if type(alias) == "string" and type(specifier) == "string" then
				result[alias] = specifier
			end
		end
	end
	return result
end

local function readStringList(source: any): { string }
	local result: { string } = {}
	if type(source) == "table" then
		for _, item in source do
			if type(item) == "string" then
				table.insert(result, item)
			end
		end
	end
	return result
end

--[[
	Every published version of a package, with the dependencies each one declares.

	This is the authoritative source for dependency resolution — more so than the
	wally.toml inside the archive, which is only what the author wrote and may name a
	range the registry has since resolved differently.
]]
function Registry.FetchMetadata(self: Registry, scope: string, name: string): Result<Metadata>
	local fullName = (`{scope}/{name}`):lower()
	local key = `meta:{fullName}`
	local hit = cached(self, key, Constants.METADATA_CACHE_SECONDS)
	if hit then
		return ok(hit)
	end

	local url = `{self.baseUrl}{Constants.ENDPOINT_METADATA}/{scope:lower()}/{name:lower()}`
	local response = request(self, url)
	if not response.ok then
		return response :: any
	end

	local decoded
	local parsed = pcall(function()
		decoded = HttpService:JSONDecode(response.data.body)
	end)
	if not parsed or type(decoded) ~= "table" or type(decoded.versions) ~= "table" then
		return err("parse", `The registry sent metadata for {fullName} this plugin could not read.`)
	end

	local versions: { VersionInfo } = {}
	local byVersion: { [string]: VersionInfo } = {}

	for _, entry in decoded.versions do
		local package = type(entry) == "table" and entry.package
		if type(package) == "table" and type(package.version) == "string" then
			local info: VersionInfo = {
				version = package.version,
				realm = type(package.realm) == "string" and package.realm or "shared",
				description = type(package.description) == "string" and package.description or nil,
				license = type(package.license) == "string" and package.license or nil,
				authors = readStringList(package.authors),
				homepage = type(package.homepage) == "string" and package.homepage or nil,
				repository = type(package.repository) == "string" and package.repository or nil,
				dependencies = readDependencies(entry.dependencies),
				serverDependencies = readDependencies(entry["server-dependencies"]),
				devDependencies = readDependencies(entry["dev-dependencies"]),
			}
			table.insert(versions, info)
			byVersion[info.version] = info
		end
	end

	if #versions == 0 then
		return err("not_found", `{fullName} has no published versions.`)
	end

	local versionList = {}
	for _, info in versions do
		table.insert(versionList, info.version)
	end
	versionList = Semver.SortDescending(versionList)

	-- Registry order is not guaranteed; present them newest first everywhere.
	table.sort(versions, function(left, right)
		local a, b = Semver.Parse(left.version), Semver.Parse(right.version)
		if not a or not b then
			return false
		end
		return Semver.Compare(a, b) > 0
	end)

	local metadata: Metadata = {
		scope = scope,
		name = name,
		fullName = `{scope}/{name}`,
		versions = versions,
		byVersion = byVersion,
		versionList = versionList,
	}

	return ok(store(self, key, metadata))
end

--------------------------------------------------------------------------------------
-- CONTENTS
--------------------------------------------------------------------------------------
--[[
	The archive for one published version, as a buffer.

	Cached for the session: versions are immutable, and re-downloading the same
	archive to reinstall or to read a README is pure latency. Cache entries are
	dropped oldest-first past a small cap, because a package archive can be a
	megabyte and holding every one visited in a long session is real memory.
]]
function Registry.FetchContents(self: Registry, scope: string, name: string, version: string): Result<buffer>
	local key = `zip:{scope:lower()}/{name:lower()}@{version}`
	local hit = cached(self, key, 0)
	if hit then
		return ok(hit)
	end

	local url = `{self.baseUrl}{Constants.ENDPOINT_CONTENTS}/{scope:lower()}/{name:lower()}/{version}`
	local response = request(self, url)
	if not response.ok then
		return response :: any
	end

	local body = response.data.body
	if type(body) ~= "string" or #body == 0 then
		return err("parse", `The registry returned an empty archive for {scope}/{name}@{version}.`)
	end

	-- Trim the archive cache before adding to it.
	local archives = {}
	for cacheKey, entry in self._cache do
		if cacheKey:sub(1, 4) == "zip:" then
			table.insert(archives, { key = cacheKey, at = entry.at })
		end
	end
	if #archives >= 8 then
		table.sort(archives, function(left, right)
			return left.at < right.at
		end)
		for index = 1, #archives - 7 do
			self._cache[archives[index].key] = nil
		end
	end

	return ok(store(self, key, buffer.fromstring(body)))
end

--------------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------------
--[[
	Split "scope/name", "scope/name@^1.2.3" or "Alias = scope/name@1.0.0" into parts.

	Accepting all three matters because people paste whichever they have to hand: a
	line copied out of a wally.toml, a name from the website, or something typed from
	memory. Returns nil when there is no scope/name in the text at all.
]]
function Registry.ParseSpecifier(text: string): ParsedSpecifier?
	local working = text:match("^%s*(.-)%s*$") or ""
	if working == "" then
		return nil
	end

	-- A leading "Alias =" is how the line appears in a manifest.
	local alias, rest = working:match("^([%w_%-]+)%s*=%s*(.+)$")
	if alias then
		working = rest
		-- Strip surrounding quotes left over from the manifest line.
		working = working:match('^"(.*)"$') or working:match("^'(.*)'$") or working
	end

	local body, requirement = working:match("^(.-)@(.+)$")
	if not body then
		body = working
	end

	local scope, name = body:match("^([%w_%-%.]+)/([%w_%-%.]+)$")
	if not scope then
		return nil
	end

	return {
		scope = scope,
		name = name,
		requirement = requirement,
		alias = alias,
	}
end

--[[
	The alias `wally install` would give a package: its name in PascalCase.

	"roact" becomes "Roact", "table-util" becomes "TableUtil". This only supplies a
	default — the user can rename it, and an existing install keeps whatever name it
	already has.
]]
function Registry.DefaultAlias(name: string): string
	local pieces = {}
	for piece in name:gmatch("[^%-_%.]+") do
		table.insert(pieces, piece:sub(1, 1):upper() .. piece:sub(2))
	end
	return table.concat(pieces)
end

return Registry
