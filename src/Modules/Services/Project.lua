--!nonstrict
--[[
======================================================================================
	PROJECT  -  what is installed in this place, and the manifest for it
======================================================================================
	A Studio place has no wally.toml and no wally.lock. The only thing that survives
	between sessions is the instance tree itself, so the tree has to be readable as
	the record of what is installed — which it is, because the layout already encodes
	everything needed:

	  _Index/roblox_roact@1.4.4     the package and its exact version
	  Packages/Roact                a link at the top level means "asked for by name"
	  _Index/sleitnick_knit@1.7.0/Comm   a link inside a package is a dependency edge

	Reading the graph back out of the links rather than from a stored manifest means
	the plugin stays correct when someone edits the tree by hand, deletes a folder, or
	installs from Rojo instead. Attributes are written during install and read as a
	convenience, but nothing here depends on them being present.

	MANIFEST
	Export produces a real wally.toml, so a place that started in Studio can move to
	a Rojo workflow without re-picking every package by hand. Import goes the other
	way, taking a manifest from an existing project and installing what it names.
	Neither direction is a lock file: versions are re-resolved on import, exactly as
	`wally install` would.
======================================================================================
]]

local Constants = require(script.Parent.Parent.Config.Constants)
local Semver = require(script.Parent.Parent.Core.Semver)
local Toml = require(script.Parent.Parent.Core.Toml)
local Registry = require(script.Parent.Registry)

local Project = {}

export type InstalledPackage = {
	key: string,
	fullName: string,
	scope: string,
	name: string,
	version: string,
	realm: string,
	direct: boolean,
	alias: string?,
	requirement: string?,
	folder: Folder,
	instance: Instance?,
	link: ModuleScript?,
	dependencyKeys: { string },
	dependencyAliases: { [string]: string },
}

export type Installed = {
	realm: string,
	root: Folder?,
	index: Folder?,
	packages: { [string]: InstalledPackage },
	order: { string },
	directCount: number,
	totalCount: number,
	-- Index folders holding a second copy of a package at a different version. Not
	-- the same thing as Project.FindOrphans, which reports packages nothing depends
	-- on; this is the narrower case of the index disagreeing with itself.
	duplicates: { string },
}

-- Both link forms name their target the same way, so one pattern reads either:
--   return require(script.Parent._Index["scope_name@1.0.0"]["name"])
--   return require(script.Parent.Parent["scope_name@1.0.0"]["name"])
local LINK_PATTERN = '%[%s*"([^"]+)"%s*%]'

local function parseIndexKey(folderName: string): (string?, string?, string?)
	-- Scope and package names are lowercase alphanumeric with hyphens, so the first
	-- underscore is unambiguously the separator wally inserted.
	local scope, name, version = folderName:match("^(.-)_(.+)@(.+)$")
	if not scope or scope == "" or name == "" then
		return nil, nil, nil
	end
	return scope, name, version
end

-- The _Index folder a link points at, or nil when the script is not a link.
local function linkTarget(script: ModuleScript): string?
	local ok, source = pcall(function()
		return script.Source
	end)
	if not ok or type(source) ~= "string" then
		return nil
	end
	if not source:find("require", 1, true) then
		return nil
	end
	local target = source:match(LINK_PATTERN)
	return target
end

--------------------------------------------------------------------------------------
-- SCAN
--------------------------------------------------------------------------------------
--[[
	Read the install set for one realm out of the place.

	Never creates anything: opening the plugin in a place with no packages must not
	leave an empty Packages folder behind in it.
]]
function Project.Scan(realm: string): Installed
	local definition = Constants.REALMS[realm] or Constants.REALMS.shared
	local installed: Installed = {
		realm = realm,
		root = nil,
		index = nil,
		packages = {},
		order = {},
		directCount = 0,
		totalCount = 0,
		duplicates = {},
	}

	local service = game:FindService(definition.service)
	if not service then
		return installed
	end

	local root = service:FindFirstChild(definition.folder)
	if not root or not root:IsA("Folder") then
		return installed
	end
	installed.root = root

	local index = root:FindFirstChild(Constants.INDEX_FOLDER)
	if not index or not index:IsA("Folder") then
		return installed
	end
	installed.index = index

	-- Pass one: every package in the index.
	local byFolderName: { [string]: InstalledPackage } = {}
	for _, folder in index:GetChildren() do
		if not folder:IsA("Folder") then
			continue
		end
		local scope, name, version = parseIndexKey(folder.Name)
		if not scope then
			continue
		end

		local key = (`{scope}/{name}`):lower()
		local instance = folder:FindFirstChild(name)

		local package: InstalledPackage = {
			key = key,
			fullName = `{scope}/{name}`,
			scope = scope,
			name = name,
			version = version :: string,
			realm = realm,
			direct = false,
			alias = nil,
			requirement = nil,
			folder = folder,
			instance = instance,
			link = nil,
			dependencyKeys = {},
			dependencyAliases = {},
		}

		-- A package folder can only hold one version of a given package, but the
		-- index can hold two folders for the same package at different versions if
		-- something went wrong. Keep the newer and report the other as an orphan.
		local existing = installed.packages[key]
		if existing then
			local keepNew = Semver.Compare(
				Semver.Parse(version) or { major = 0, minor = 0, patch = 0 },
				Semver.Parse(existing.version) or { major = 0, minor = 0, patch = 0 }
			) > 0
			if keepNew then
				table.insert(installed.duplicates, `{existing.fullName}@{existing.version}`)
				installed.packages[key] = package
			else
				table.insert(installed.duplicates, `{package.fullName}@{package.version}`)
			end
		else
			installed.packages[key] = package
		end
		byFolderName[folder.Name] = installed.packages[key]
	end

	-- Pass two: dependency edges, read from the link scripts beside each package.
	for _, folder in index:GetChildren() do
		local package = byFolderName[folder.Name]
		if not package then
			continue
		end
		for _, child in folder:GetChildren() do
			if child:IsA("ModuleScript") then
				local target = linkTarget(child)
				if target then
					local scope, name = parseIndexKey(target)
					if scope then
						local dependencyKey = (`{scope}/{name}`):lower()
						if not table.find(package.dependencyKeys, dependencyKey) then
							table.insert(package.dependencyKeys, dependencyKey)
						end
						package.dependencyAliases[child.Name] = dependencyKey
					end
				end
			end
		end
	end

	-- Pass three: top-level links mark the packages the user asked for by name.
	for _, child in root:GetChildren() do
		if child:IsA("ModuleScript") then
			local target = linkTarget(child)
			if target then
				local scope, name = parseIndexKey(target)
				if scope then
					local package = installed.packages[(`{scope}/{name}`):lower()]
					if package then
						package.direct = true
						package.alias = child.Name
						package.link = child
						package.requirement = child:GetAttribute(Constants.ATTR_REQUIREMENT)
					end
				end
			end
		end
	end

	for key, package in installed.packages do
		table.insert(installed.order, key)
		installed.totalCount += 1
		if package.direct then
			installed.directCount += 1
		end
	end
	table.sort(installed.order)

	return installed
end

--[[
	Every realm at once, for the summary the Installed tab opens on.
]]
function Project.ScanAll(): { [string]: Installed }
	local result = {}
	for _, realm in Constants.REALM_ORDER do
		result[realm] = Project.Scan(realm)
	end
	return result
end

--[[
	Packages in the index that nothing depends on and that were never asked for by
	name. These accumulate when a package is removed by hand, and are safe to delete.
]]
function Project.FindOrphans(installed: Installed): { InstalledPackage }
	local reachable: { [string]: boolean } = {}

	local function walk(key: string)
		if reachable[key] then
			return
		end
		reachable[key] = true
		local package = installed.packages[key]
		if package then
			for _, dependencyKey in package.dependencyKeys do
				walk(dependencyKey)
			end
		end
	end

	for key, package in installed.packages do
		if package.direct then
			walk(key)
		end
	end

	local orphans = {}
	for key, package in installed.packages do
		if not reachable[key] then
			table.insert(orphans, package)
		end
	end
	table.sort(orphans, function(left, right)
		return left.fullName < right.fullName
	end)
	return orphans
end

--------------------------------------------------------------------------------------
-- UPDATES
--------------------------------------------------------------------------------------
export type UpdateInfo = {
	package: InstalledPackage,
	-- Newest version still inside the range the package was installed under.
	compatible: string?,
	-- Newest version published at all, whether or not it is a compatible upgrade.
	latest: string?,
	-- True when `latest` is outside the recorded range: a deliberate decision rather
	-- than a routine update, because it can break the code that uses it.
	major: boolean,
}

--[[
	Check the registry for newer versions of every directly installed package.

	Only direct packages are checked. Transitive ones move when the package that
	depends on them moves, and offering to update one on its own would produce a
	combination its dependent never declared support for.

	Yields.
]]
function Project.CheckUpdates(registry: any, installed: Installed, onProgress: ((string) -> ())?): {
	updates: { UpdateInfo },
	failures: { { fullName: string, message: string } },
}
	local updates: { UpdateInfo } = {}
	local failures = {}

	for _, key in installed.order do
		local package = installed.packages[key]
		if not package.direct then
			continue
		end

		if onProgress then
			onProgress(`Checking {package.fullName}`)
		end

		local metadata = registry:FetchMetadata(package.scope, package.name)
		if not metadata.ok then
			table.insert(failures, { fullName = package.fullName, message = metadata.message or "lookup failed" })
			continue
		end

		-- Without a recorded requirement — an install from Rojo, or one predating
		-- the attribute — assume the caret range wally would have written.
		local requirement = package.requirement or Semver.CaretFor(package.version)
		local compatible = Semver.MaxSatisfying(metadata.data.versionList, requirement)
		local latest = Semver.Latest(metadata.data.versionList)

		local hasCompatible = compatible ~= nil and compatible ~= package.version
		local hasMajor = latest ~= nil and latest ~= package.version and latest ~= compatible

		if hasCompatible or hasMajor then
			table.insert(updates, {
				package = package,
				compatible = hasCompatible and compatible or nil,
				latest = latest,
				major = hasMajor and not hasCompatible,
			})
		end
	end

	return { updates = updates, failures = failures }
end

--------------------------------------------------------------------------------------
-- MANIFEST
--------------------------------------------------------------------------------------
--[[
	Write a wally.toml describing what is installed.

	Only direct packages are listed, with caret requirements, which is what a
	hand-written manifest looks like — transitive packages are wally's business and
	listing them would pin versions the user never chose.
]]
function Project.ExportManifest(byRealm: { [string]: Installed }, projectName: string?): string
	local sections = {}

	table.insert(
		sections,
		Toml.EncodeSection("package", {
			name = projectName or "your-scope/your-project",
			version = "0.1.0",
			registry = Constants.DEFAULT_REGISTRY_INDEX,
			realm = "shared",
		}, { "name", "version", "registry", "realm" })
	)

	local sectionForRealm = {
		shared = "dependencies",
		server = "server-dependencies",
		dev = "dev-dependencies",
	}

	for _, realm in Constants.REALM_ORDER do
		local installed = byRealm[realm]
		if not installed then
			continue
		end

		local entries: { [string]: string } = {}
		local aliases = {}
		for _, key in installed.order do
			local package = installed.packages[key]
			if package.direct then
				local alias = package.alias or Registry.DefaultAlias(package.name)
				entries[alias] = `{package.fullName}@{package.requirement or Semver.CaretFor(package.version)}`
				table.insert(aliases, alias)
			end
		end

		if #aliases > 0 then
			table.sort(aliases)
			table.insert(sections, Toml.EncodeSection(sectionForRealm[realm], entries, aliases))
		end
	end

	return table.concat(sections, "\n\n") .. "\n"
end

export type ManifestImport = {
	ok: boolean,
	roots: { [string]: { Registry.ParsedSpecifier } },
	packageName: string?,
	problems: { string },
	message: string?,
}

--[[
	Read a wally.toml and return the packages it asks for, grouped by realm.

	Entries that cannot be understood are collected rather than fatal: a manifest with
	one malformed line should still offer to install the other nine.
]]
function Project.ParseManifest(text: string): ManifestImport
	local document, problem = Toml.Parse(text)
	if not document then
		return {
			ok = false,
			roots = {},
			problems = {},
			message = `This does not parse as TOML — {problem}`,
		}
	end

	local sectionForRealm = {
		shared = "dependencies",
		server = "server-dependencies",
		dev = "dev-dependencies",
	}

	local roots = { shared = {}, server = {}, dev = {} }
	local problems = {}
	local found = 0

	for realm, section in sectionForRealm do
		local dependencies = document[section]
		if type(dependencies) ~= "table" then
			continue
		end
		for alias, specifier in dependencies do
			if type(specifier) ~= "string" then
				table.insert(problems, `{alias}: expected a package string`)
				continue
			end
			local parsed = Registry.ParseSpecifier(specifier)
			if not parsed then
				table.insert(problems, `{alias}: "{specifier}" is not a scope/name specifier`)
				continue
			end
			parsed.alias = alias
			table.insert(roots[realm], parsed)
			found += 1
		end
	end

	if found == 0 then
		return {
			ok = false,
			roots = roots,
			problems = problems,
			message = "That manifest has no dependencies to install.",
		}
	end

	local packageName = nil
	if type(document.package) == "table" and type(document.package.name) == "string" then
		packageName = document.package.name
	end

	return { ok = true, roots = roots, packageName = packageName, problems = problems }
end

return Project
