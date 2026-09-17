--!strict
--[[
======================================================================================
	PACKAGE LAYOUT  -  decides what a package archive becomes
======================================================================================
	The rules that turn a published .zip into a tree of instances, kept separate from
	the code that creates them. This is the part most likely to be quietly wrong — a
	package whose source sits somewhere unexpected, a file named in a way that changes
	what class it becomes — and separating it means it can be tested against real
	archives outside Studio, which tests/LayoutTest.luau does.

	It produces a plan, not instances: a nested description of what to create. The
	installer walks the plan and makes it real.

	THE PROJECT PATH
	Wally publishes the whole repository. Roact's archive contains its documentation,
	its benchmarks and its CI config alongside the library. What separates the library
	from the rest is default.project.json — Rojo does not sync a directory containing
	one as a directory, it syncs the project that file describes, and Roact's points
	at src. So the plan starts from there, and everything beside it never becomes an
	instance at all. A package published from its repository root with no project file
	starts from the root.

	FILE NAMING
	Rojo's conventions, because the packages were written for Rojo and their own
	`require` calls assume them:

	  init.luau / init.lua      the folder becomes this ModuleScript
	  init.server.luau          the folder becomes a Script
	  init.client.luau          the folder becomes a LocalScript
	  Thing.luau                a ModuleScript named Thing
	  Thing.server.luau         a Script named Thing
	  Thing.client.luau         a LocalScript named Thing
	  Thing.txt                 a StringValue named Thing

	Anything else — Markdown, images, licences — is not something Rojo maps either,
	and is dropped. Folders left empty as a result are pruned, which is what removes a
	documentation tree without ever having to guess from a folder's name what it is
	for.
======================================================================================
]]

local Constants = require(script.Parent.Parent.Config.Constants)

local PackageLayout = {}

export type PlanNode = {
	name: string,
	className: string,
	-- The archive entry holding this node's source, if it has one. Folders do not.
	entry: any?,
	children: { PlanNode },
}

export type Skipped = {
	path: string,
	reason: string,
}

export type Plan = {
	root: PlanNode?,
	prefix: string,
	skipped: { Skipped },
	fileCount: number,
}

--------------------------------------------------------------------------------------
-- NAMES
--------------------------------------------------------------------------------------
--[[
	Split a script file name into its instance name and class.

	Returns nil for anything that is not a script. The kind suffix sits between the
	name and the extension, and its absence means ModuleScript — which is why the
	empty suffix has to be tested last.
]]
function PackageLayout.ClassifyScript(fileName: string): (string?, string?)
	for _, extension in Constants.SCRIPT_EXTENSIONS do
		if fileName:sub(-#extension) == extension then
			local stem = fileName:sub(1, -#extension - 1)
			for _, kind in Constants.SCRIPT_KINDS do
				if kind.suffix == "" then
					return stem, kind.className
				end
				if stem:sub(-#kind.suffix) == kind.suffix then
					return stem:sub(1, -#kind.suffix - 1), kind.className
				end
			end
		end
	end
	return nil, nil
end

function PackageLayout.ExtensionOf(fileName: string): string
	local dot = fileName:match("^.*()%.")
	return dot and fileName:sub(dot):lower() or ""
end

--[[
	Is this a build or tooling file rather than package content?

	Distinguished from "unsupported" on purpose. Both are dropped, but an unsupported
	file is one the package meant to ship and this plugin could not build, which the
	user should hear about; a metadata file is one that was never going to become an
	instance under Rojo either.
]]
function PackageLayout.IsMetadata(fileName: string): boolean
	if Constants.IGNORED_FILES[fileName] then
		return true
	end
	-- Rojo's own sidecar formats: a project file (already consumed to find the source
	-- directory) and a meta file describing properties of the file beside it.
	return fileName:match("%.project%.json$") ~= nil or fileName:match("%.meta%.json$") ~= nil
end

--------------------------------------------------------------------------------------
-- PROJECT PATH
--------------------------------------------------------------------------------------
--[[
	Where the package's source starts inside the archive, as a prefix to strip from
	every entry path — "src/" for Roact, "" for a package published from its root.

	`decodeJson` is passed in rather than required, so this module stays free of
	Roblox APIs and can run under a plain Luau runtime in tests. It must raise or
	return a non-table on malformed input.
]]
function PackageLayout.ProjectPath(archive: any, decodeJson: (string) -> any): string
	local source = archive:ReadString(Constants.PROJECT_FILE)
	if not source then
		return ""
	end

	local ok, decoded = pcall(decodeJson, source)
	if not ok or type(decoded) ~= "table" or type(decoded.tree) ~= "table" then
		return ""
	end

	local path = decoded.tree["$path"]
	if type(path) ~= "string" or path == "" or path == "." then
		-- A project whose tree is described inline rather than pointed at a
		-- directory. Rare for a published package, and there is nothing to redirect
		-- to, so the archive root stands.
		return ""
	end

	local normalized = path:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
	if normalized == "" then
		return ""
	end
	return normalized .. "/"
end

--------------------------------------------------------------------------------------
-- FILE TREE
--------------------------------------------------------------------------------------
type Node = {
	folders: { [string]: Node },
	files: { [string]: any },
}

local function newNode(): Node
	return { folders = {}, files = {} }
end

-- Zip entries carry a full path each and arrive in no guaranteed order, so the
-- directory structure has to be rebuilt rather than read.
local function buildFileTree(archive: any, prefix: string): Node
	local root = newNode()
	local prefixLength = #prefix

	for _, entry in archive.Entries do
		if not entry.isDirectory then
			local include = prefix == "" or entry.name:sub(1, prefixLength) == prefix
			if include then
				local relative = entry.name:sub(prefixLength + 1)
				if relative ~= "" then
					local parts = relative:split("/")
					local node = root
					local skip = false

					for index = 1, #parts - 1 do
						local part = parts[index]
						if Constants.IGNORED_DIRECTORIES[part] then
							skip = true
							break
						end
						local child = node.folders[part]
						if not child then
							child = newNode()
							node.folders[part] = child
						end
						node = child
					end

					if not skip then
						node.files[parts[#parts]] = entry
					end
				end
			end
		end
	end

	return root
end

--------------------------------------------------------------------------------------
-- PLAN
--------------------------------------------------------------------------------------
local function planNode(node: Node, name: string, path: string, skipped: { Skipped }, counter: { n: number }): PlanNode?
	local className = "Folder"
	local initFile: string? = nil

	-- The init file decides what this folder even is, so it is found first.
	for fileName in node.files do
		local stem, kind = PackageLayout.ClassifyScript(fileName)
		if stem == "init" and kind then
			initFile = fileName
			className = kind
			break
		end
	end

	local plan: PlanNode = {
		name = name,
		className = className,
		entry = initFile and node.files[initFile] or nil,
		children = {},
	}
	counter.n += 1

	-- Sorted so a plan is deterministic; two runs over the same archive must produce
	-- the same tree, and pairs() order is not stable.
	local fileNames = {}
	for fileName in node.files do
		table.insert(fileNames, fileName)
	end
	table.sort(fileNames)

	for _, fileName in fileNames do
		if fileName ~= initFile then
			local entry = node.files[fileName]
			local stem, kind = PackageLayout.ClassifyScript(fileName)
			if stem and kind then
				table.insert(plan.children, { name = stem, className = kind, entry = entry, children = {} })
				counter.n += 1
			else
				local extension = PackageLayout.ExtensionOf(fileName)
				if Constants.TEXT_EXTENSIONS[extension] then
					table.insert(plan.children, {
						name = fileName:sub(1, -#extension - 1),
						className = "StringValue",
						entry = entry,
						children = {},
					})
					counter.n += 1
				elseif PackageLayout.IsMetadata(fileName) then
					-- Build configuration and Rojo metadata. Dropped in silence,
					-- because reporting default.project.json as an unsupported JSON
					-- module would be reporting a file we deliberately read and acted
					-- on as though it had failed.
				elseif Constants.UNSUPPORTED_EXTENSIONS[extension] then
					table.insert(skipped, {
						path = path .. fileName,
						reason = `{Constants.UNSUPPORTED_EXTENSIONS[extension]} files are not supported`,
					})
				end
			end
		end
	end

	local folderNames = {}
	for folderName in node.folders do
		table.insert(folderNames, folderName)
	end
	table.sort(folderNames)

	for _, folderName in folderNames do
		local child = planNode(node.folders[folderName], folderName, `{path}{folderName}/`, skipped, counter)
		if child then
			table.insert(plan.children, child)
		end
	end

	-- Prune: a folder that produced nothing held documentation or metadata. Scripts
	-- are kept even when empty, since a package may ship a stub on purpose.
	if className == "Folder" and #plan.children == 0 then
		counter.n -= 1
		return nil
	end

	return plan
end

--[[
	Work out everything an archive should become.

	`rootName` is the name the package's own link scripts index by — its lowercase
	package name.
]]
function PackageLayout.BuildPlan(archive: any, decodeJson: (string) -> any, rootName: string): Plan
	local prefix = PackageLayout.ProjectPath(archive, decodeJson)
	local tree = buildFileTree(archive, prefix)
	local skipped: { Skipped } = {}
	local counter = { n = 0 }

	local root = planNode(tree, rootName, "", skipped, counter)

	return {
		root = root,
		prefix = prefix,
		skipped = skipped,
		fileCount = counter.n,
	}
end

--[[
	Every instance path a plan would create, as "a/b/c" strings.

	Only used by tests and diagnostics, but it is the clearest way to state what a
	plan actually means.
]]
function PackageLayout.Paths(plan: Plan): { string }
	local result = {}

	local function walk(node: PlanNode, prefix: string)
		local path = prefix == "" and node.name or `{prefix}/{node.name}`
		table.insert(result, `{path} [{node.className}]`)
		for _, child in node.children do
			walk(child, path)
		end
	end

	if plan.root then
		walk(plan.root, "")
	end
	table.sort(result)
	return result
end

return PackageLayout
