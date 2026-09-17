--!nonstrict
--[[
======================================================================================
	INSTALLER  -  archive in, instance tree out
======================================================================================
	Reproduces, as instances, exactly what `wally install` writes to disk and Rojo
	then syncs into a place:

	    Packages/
	      Roact                       ModuleScript, one line, forwards into _Index
	      _Index/
	        roblox_roact@1.4.4/
	          roact                   the package itself
	        sleitnick_knit@1.7.0/
	          knit
	          Comm                    link to a sibling in _Index
	          Promise

	Matching that layout is the whole point. A place installed from here can be handed
	to someone using Rojo and a real Packages folder, and neither of them has to know
	the difference — the require paths are identical.

	WHAT GOES WHERE
	Deciding what an archive should become is not done here — Core.PackageLayout does
	it, and does it without touching a Roblox API so the rules can be tested against
	real published archives outside Studio. That separation is deliberate: working out
	that Roact's library lives under src/ while its documentation does not is the part
	most likely to be subtly wrong, and it is the part hardest to check by eye.

	This module takes the plan that comes back and creates the instances, then builds
	the _Index folders and link scripts around them.

======================================================================================
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")

local Constants = require(script.Parent.Parent.Config.Constants)
local Zip = require(script.Parent.Parent.Core.Zip)
local Registry = require(script.Parent.Registry)
local PackageLayout = require(script.Parent.Parent.Core.PackageLayout)

local Installer = {}

export type FileReport = {
	created: number,
	skipped: { { path: string, reason: string } },
}

--------------------------------------------------------------------------------------
-- PACKAGE BUILD
--------------------------------------------------------------------------------------
-- What an archive should become is decided by Core.PackageLayout, which is free of
-- Roblox APIs so the rules can be tested against real archives outside Studio. This
-- only walks the plan it returns and makes the instances.
local function realise(node: any, archive: any): Instance
	local instance = Instance.new(node.className)
	instance.Name = node.name

	if node.entry then
		local contents = buffer.tostring(archive:Read(node.entry))
		if node.className == "StringValue" then
			(instance :: any).Value = contents
		else
			(instance :: any).Source = contents
		end
	end

	for _, child in node.children do
		realise(child, archive).Parent = instance
	end

	return instance
end

--[[
	Build the instance for one package from its archive.

	The returned instance is named with the package's own lowercase name, which is
	what the link scripts index by, and is not yet parented.
]]
function Installer.BuildPackage(archiveData: buffer, packageName: string): (Instance?, FileReport, string?)
	local report: FileReport = { created = 0, skipped = {} }

	local readOk, archive = pcall(Zip.Read, archiveData)
	if not readOk then
		return nil, report, tostring(archive)
	end

	local planOk, plan = pcall(PackageLayout.BuildPlan, archive, function(source: string)
		return HttpService:JSONDecode(source)
	end, packageName)
	if not planOk then
		return nil, report, tostring(plan)
	end

	report.skipped = plan.skipped
	report.created = plan.fileCount

	if not plan.root then
		local where = plan.prefix ~= "" and plan.prefix or "the archive root"
		return nil, report, `there are no scripts under {where}`
	end

	local buildOk, instance = pcall(realise, plan.root, archive)
	if not buildOk then
		local message = tostring(instance)
		-- Setting Source is a protected API. Studio asks the user to allow script
		-- injection the first time a plugin tries it, and this is what a refusal
		-- looks like from here.
		if message:find("lacking permission") or message:find("Script Injection") then
			return nil,
				report,
				"Studio blocked this plugin from creating scripts. Allow script injection for Wally Studio in Plugin Management, then try again."
		end
		return nil, report, message
	end

	return instance, report, nil
end

--------------------------------------------------------------------------------------
-- LINK SCRIPTS
--------------------------------------------------------------------------------------
-- The exact text `wally install` writes. Reproduced rather than approximated: these
-- files are what makes an install interchangeable with a Rojo-synced Packages folder.
local function indexKey(scope: string, name: string, version: string): string
	return `{scope}_{name}@{version}`
end

local function makeRootLink(alias: string, scope: string, name: string, version: string): ModuleScript
	local link = Instance.new("ModuleScript")
	link.Name = alias
	link.Source = `return require(script.Parent._Index["{indexKey(scope, name, version)}"]["{name}"])\n`
	return link
end

local function makeDependencyLink(alias: string, scope: string, name: string, version: string): ModuleScript
	local link = Instance.new("ModuleScript")
	link.Name = alias
	-- One level further up: a dependency link sits inside a package's own _Index
	-- folder and reaches across to a sibling entry.
	link.Source = `return require(script.Parent.Parent["{indexKey(scope, name, version)}"]["{name}"])\n`
	return link
end

Installer.IndexKey = indexKey

--------------------------------------------------------------------------------------
-- TARGET FOLDERS
--------------------------------------------------------------------------------------
--[[
	The Packages folder for a realm, created if it is not there yet.
]]
function Installer.EnsureTarget(realm: string): (Folder, Folder)
	local definition = Constants.REALMS[realm] or Constants.REALMS.shared
	local service = game:GetService(definition.service :: any)

	local root = service:FindFirstChild(definition.folder)
	if not root or not root:IsA("Folder") then
		root = Instance.new("Folder")
		root.Name = definition.folder
		root.Parent = service
	end

	local index = root:FindFirstChild(Constants.INDEX_FOLDER)
	if not index or not index:IsA("Folder") then
		index = Instance.new("Folder")
		index.Name = Constants.INDEX_FOLDER
		index.Parent = root
	end

	return root :: Folder, index :: Folder
end

--------------------------------------------------------------------------------------
-- INSTALL
--------------------------------------------------------------------------------------
export type InstallOptions = {
	registry: any,
	resolution: any,
	realm: string,
	onProgress: ((message: string, done: number, total: number) -> ())?,
}

export type InstallResult = {
	ok: boolean,
	installed: { string },
	failed: { { fullName: string, reason: string } },
	skipped: { { path: string, reason: string } },
	message: string?,
}

--[[
	Download, unpack and place every package in a resolution.

	Runs as one undo step, so a mistaken install is one Ctrl+Z rather than a manual
	hunt through ReplicatedStorage. Yields between packages to keep Studio painting.
]]
function Installer.Install(options: InstallOptions): InstallResult
	local registry = options.registry
	local resolution = options.resolution
	local realm = options.realm
	local onProgress = options.onProgress

	local result: InstallResult = { ok = true, installed = {}, failed = {}, skipped = {} }

	local recording = nil
	local recordingOk = pcall(function()
		recording = ChangeHistoryService:TryBeginRecording(`Install Wally packages`)
	end)

	local root, index = Installer.EnsureTarget(realm)

	local total = #resolution.order
	local done = 0

	for _, key in resolution.order do
		local package = resolution.packages[key]
		done += 1

		local function progress(message: string)
			if onProgress then
				onProgress(message, done, total)
			end
		end

		progress(`Downloading {package.fullName}@{package.version}`)
		local contents = registry:FetchContents(package.scope, package.name, package.version)
		if not contents.ok then
			table.insert(result.failed, { fullName = package.fullName, reason = contents.message or "download failed" })
			result.ok = false
			continue
		end

		progress(`Unpacking {package.fullName}@{package.version}`)
		local instance, report, problem = Installer.BuildPackage(contents.data, package.name)
		if not instance then
			table.insert(result.failed, { fullName = package.fullName, reason = problem or "could not unpack" })
			result.ok = false
			continue
		end

		for _, entry in report.skipped do
			table.insert(result.skipped, { path = `{package.fullName}/{entry.path}`, reason = entry.reason })
		end

		-- Replace any existing entry for this exact version, so reinstalling is
		-- idempotent rather than producing a second copy beside the first.
		local folderName = indexKey(package.scope, package.name, package.version)
		local existing = index:FindFirstChild(folderName)
		if existing then
			existing:Destroy()
		end

		local packageFolder = Instance.new("Folder")
		packageFolder.Name = folderName
		instance.Parent = packageFolder

		instance:SetAttribute(Constants.ATTR_PACKAGE, package.fullName)
		instance:SetAttribute(Constants.ATTR_VERSION, package.version)
		instance:SetAttribute(Constants.ATTR_REALM, realm)
		instance:SetAttribute(Constants.ATTR_DIRECT, package.direct)
		instance:SetAttribute(Constants.ATTR_INSTALLED_BY, Constants.PLUGIN_NAME)

		-- Every dependency this package declares gets a link beside it, named with
		-- the alias the package's own source requires by.
		for alias, specifier in package.info.dependencies do
			local parsed = Registry.ParseSpecifier(specifier)
			if parsed then
				local dependency = resolution.packages[(`{parsed.scope}/{parsed.name}`):lower()]
				if dependency then
					local link = makeDependencyLink(alias, dependency.scope, dependency.name, dependency.version)
					link.Parent = packageFolder
				end
			end
		end

		packageFolder.Parent = index

		-- Direct packages get their alias at the top of the Packages folder; the rest
		-- are reachable only through the package that depends on them, which is what
		-- keeps the folder readable.
		if package.direct and package.alias then
			local previous = root:FindFirstChild(package.alias)
			if previous then
				previous:Destroy()
			end
			local link = makeRootLink(package.alias, package.scope, package.name, package.version)
			link:SetAttribute(Constants.ATTR_PACKAGE, package.fullName)
			link:SetAttribute(Constants.ATTR_VERSION, package.version)
			link:SetAttribute(Constants.ATTR_REALM, realm)
			link:SetAttribute(Constants.ATTR_DIRECT, true)

			local constraint = package.constraints and package.constraints[1]
			if constraint then
				link:SetAttribute(Constants.ATTR_REQUIREMENT, constraint.requirement)
			end
			link.Parent = root
		end

		table.insert(result.installed, `{package.fullName}@{package.version}`)

		-- Unpacking a large package is several hundred milliseconds of work. Without
		-- this, Studio stops redrawing for the whole install and looks hung.
		task.wait()
	end

	if recordingOk and recording then
		pcall(function()
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end)
	end

	if #result.failed > 0 then
		result.message = `{#result.failed} of {total} packages failed to install.`
	end

	return result
end

--------------------------------------------------------------------------------------
-- UNINSTALL
--------------------------------------------------------------------------------------
--[[
	Delete index folders nothing reaches any more.

	Updating a package leaves its previous version behind, because the folder name
	carries the version and the new install writes a new folder beside the old one.
	That old folder is unreferenced the moment the top-level link is repointed, and
	this is what actually removes it. Also cleans up after a package deleted by hand.

	`orphans` comes from Project.FindOrphans, which decides reachability by walking
	the link scripts.
]]
function Installer.Prune(realm: string, orphans: { any }): { string }
	if #orphans == 0 then
		return {}
	end

	local recording = nil
	local recordingOk = pcall(function()
		recording = ChangeHistoryService:TryBeginRecording("Remove unused Wally packages")
	end)

	local removed = {}
	for _, package in orphans do
		if package.folder and package.folder.Parent then
			table.insert(removed, `{package.fullName}@{package.version}`)
			package.folder:Destroy()
		end
		if package.link and package.link.Parent then
			package.link:Destroy()
		end
	end

	if recordingOk and recording then
		pcall(function()
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end)
	end

	return removed
end

--[[
	Remove a direct package, then everything that was only there for it.

	The sweep matters: uninstalling Knit without it would leave Comm, Promise, Option
	and Signal behind with nothing referring to them, and no way for the user to tell
	which of the folders in _Index are still needed.
]]
function Installer.Uninstall(realm: string, fullName: string, installed: any): { removed: { string } }
	local removed = {}

	local recording = nil
	local recordingOk = pcall(function()
		recording = ChangeHistoryService:TryBeginRecording(`Uninstall {fullName}`)
	end)

	local root, index = Installer.EnsureTarget(realm)

	local target = installed.packages[fullName:lower()]
	if target then
		if target.link then
			target.link:Destroy()
		end
		if target.folder then
			target.folder:Destroy()
		end
		table.insert(removed, `{target.fullName}@{target.version}`)
	end

	-- Anything now unreachable from a remaining direct package is an orphan.
	local reachable: { [string]: boolean } = {}
	local function walk(key: string)
		if reachable[key] then
			return
		end
		reachable[key] = true
		local package = installed.packages[key]
		if not package then
			return
		end
		for _, dependencyKey in package.dependencyKeys do
			walk(dependencyKey)
		end
	end

	for key, package in installed.packages do
		if package.direct and key ~= fullName:lower() and package.folder and package.folder.Parent then
			walk(key)
		end
	end

	for key, package in installed.packages do
		if not reachable[key] and package.folder and package.folder.Parent then
			table.insert(removed, `{package.fullName}@{package.version}`)
			package.folder:Destroy()
			if package.link then
				package.link:Destroy()
			end
		end
	end

	-- Leave the place tidy when the last package goes.
	if #index:GetChildren() == 0 then
		index:Destroy()
	end
	if #root:GetChildren() == 0 then
		root:Destroy()
	end

	if recordingOk and recording then
		pcall(function()
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end)
	end

	return { removed = removed }
end

return Installer
