--!nonstrict
--[[
======================================================================================
	RESOLVER  -  turns requested packages into a flat, installable set
======================================================================================
	Wally flattens: one version of each package, shared by everything that depends on
	it, rather than a nested tree with a private copy per dependent. That is not a
	simplification made here — it is forced by the link format. A package's
	dependency link reads

	    require(script.Parent.Parent["evaera_promise@4.0.0"]["promise"])

	which reaches sideways into the _Index folder it already lives in. Two copies of
	promise in the same folder would need two different folder names, and the link
	names the version, so the only way for two dependents to disagree is for one of
	them to be pointed at a version it did not ask for.

	The same fact settles where dependencies are installed: everything a root package
	pulls in must land in the same Packages folder as the root, because the links are
	relative to it. Installing into the shared and server folders therefore resolves
	as two independent closures, which is exactly what `wally install` does.

	RESOLUTION
	Constraints accumulate per package, and a package is re-picked whenever a new
	constraint arrives that its current choice fails. Re-picking can change that
	package's own dependencies, so its subtree is re-expanded; the worklist runs to a
	fixed point. Package graphs in this ecosystem are small and shallow, so this
	converges in a handful of passes.

	When no version satisfies every constraint, the failure names each requirement
	and who asked for it. "Cannot resolve promise" is not something a user can act
	on; "knit wants ^4, matter wants ^3" is.
======================================================================================
]]

local Constants = require(script.Parent.Parent.Config.Constants)
local Semver = require(script.Parent.Parent.Core.Semver)
local Registry = require(script.Parent.Registry)

local Resolver = {}

export type Root = {
	scope: string,
	name: string,
	requirement: string,
	alias: string?,
}

export type ResolvedPackage = {
	scope: string,
	name: string,
	fullName: string,
	version: string,
	alias: string?,
	direct: boolean,
	realm: string,
	info: any,
	-- Every requirement placed on this package, and by whom. Kept after resolution
	-- because it is what makes a later conflict or an update explainable.
	constraints: { { requirement: string, source: string } },
}

export type Resolution = {
	ok: boolean,
	packages: { [string]: ResolvedPackage },
	order: { string },
	conflicts: { { fullName: string, constraints: { { requirement: string, source: string } }, available: { string } } },
	message: string?,
	kind: string?,
}

--[[
	Resolve `roots` into a complete, flat install set.

	`onProgress(label)` is called as each lookup starts; resolution is network-bound
	and a user watching a spinner deserves to know which package it is waiting on.

	Yields.
]]
function Resolver.Resolve(registry: any, roots: { Root }, realm: string, onProgress: ((string) -> ())?): Resolution
	local packages: { [string]: ResolvedPackage } = {}
	local constraintsByPackage: { [string]: { { requirement: string, source: string } } } = {}
	local metadataCache: { [string]: any } = {}
	local conflicts = {}

	local function report(label: string)
		if onProgress then
			onProgress(label)
		end
	end

	-- One metadata fetch per package for the whole resolution, however many times it
	-- is reconsidered.
	local function metadataFor(scope: string, name: string): (any?, string?, string?)
		local key = (`{scope}/{name}`):lower()
		if metadataCache[key] then
			return metadataCache[key], nil, nil
		end
		report(`Looking up {scope}/{name}`)
		local result = registry:FetchMetadata(scope, name)
		if not result.ok then
			return nil, result.kind, result.message
		end
		metadataCache[key] = result.data
		return result.data, nil, nil
	end

	-- Packages whose dependencies still need expanding.
	local pending: { string } = {}
	local function enqueue(fullName: string)
		if not table.find(pending, fullName) then
			table.insert(pending, fullName)
		end
	end

	--[[
		Record a requirement on a package and pick a version that satisfies every
		requirement recorded so far. Returns false when nothing does.
	]]
	local function require_(
		scope: string,
		name: string,
		requirement: string,
		source: string,
		direct: boolean,
		alias: string?
	): (boolean, string?, string?)
		local key = (`{scope}/{name}`):lower()

		local list = constraintsByPackage[key]
		if not list then
			list = {}
			constraintsByPackage[key] = list
		end

		-- The same dependent asking for the same range twice is not a new constraint.
		local alreadyRecorded = false
		for _, constraint in list do
			if constraint.requirement == requirement and constraint.source == source then
				alreadyRecorded = true
				break
			end
		end
		if not alreadyRecorded then
			table.insert(list, { requirement = requirement, source = source })
		end

		local current = packages[key]
		if current and Semver.Satisfies(current.version, requirement) then
			-- Already resolved to something acceptable. Only the bookkeeping changes.
			if direct then
				current.direct = true
				current.alias = alias or current.alias
			end
			current.constraints = list
			return true, nil, nil
		end

		local metadata, kind, message = metadataFor(scope, name)
		if not metadata then
			return false, kind, message
		end

		-- Highest version satisfying every constraint at once.
		local candidates = metadata.versionList
		local chosen: string? = nil
		for _, candidate in candidates do
			local satisfiesAll = true
			for _, constraint in list do
				if not Semver.Satisfies(candidate, constraint.requirement) then
					satisfiesAll = false
					break
				end
			end
			if satisfiesAll then
				-- versionList is already newest-first, so the first hit is the best.
				chosen = candidate
				break
			end
		end

		if not chosen then
			table.insert(conflicts, {
				fullName = metadata.fullName,
				constraints = list,
				available = candidates,
			})
			return false, "conflict", nil
		end

		if current and current.version == chosen then
			current.constraints = list
			return true, nil, nil
		end

		local info = metadata.byVersion[chosen]
		packages[key] = {
			scope = metadata.scope,
			name = metadata.name,
			fullName = metadata.fullName,
			version = chosen,
			alias = alias or (current and current.alias),
			direct = direct or (current ~= nil and current.direct),
			realm = realm,
			info = info,
			constraints = list,
		}

		-- A changed version brings a different dependency list with it, so this
		-- package has to be expanded again even if it was expanded before.
		enqueue(key)
		return true, nil, nil
	end

	--------------------------------------------------------------------------------
	-- ROOTS
	--------------------------------------------------------------------------------
	for _, root in roots do
		local success, kind, message = require_(
			root.scope,
			root.name,
			root.requirement,
			"this project",
			true,
			root.alias or Registry.DefaultAlias(root.name)
		)
		if not success and kind ~= "conflict" then
			return {
				ok = false,
				packages = packages,
				order = {},
				conflicts = conflicts,
				kind = kind,
				message = message,
			}
		end
	end

	--------------------------------------------------------------------------------
	-- TRANSITIVE CLOSURE
	--------------------------------------------------------------------------------
	local passes = 0
	while #pending > 0 do
		passes += 1
		if passes > Constants.MAX_RESOLVE_DEPTH * 4 then
			return {
				ok = false,
				packages = packages,
				order = {},
				conflicts = conflicts,
				kind = "cycle",
				message = "Dependency resolution did not settle. The package graph may contain a cycle.",
			}
		end

		local key = table.remove(pending, 1) :: string
		local package = packages[key]
		if package then
			-- Only `dependencies` are followed. A package's dev-dependencies are for
			-- building and testing it, not for using it, and `wally install` does not
			-- pull them in for a consumer either.
			for _, specifier in package.info.dependencies do
				local parsed = Registry.ParseSpecifier(specifier)
				if parsed then
					local success, kind, message = require_(
						parsed.scope,
						parsed.name,
						parsed.requirement or "*",
						`{package.fullName}@{package.version}`,
						false,
						nil
					)
					if not success and kind ~= "conflict" then
						return {
							ok = false,
							packages = packages,
							order = {},
							conflicts = conflicts,
							kind = kind,
							message = message,
						}
					end
				end
			end
		end
	end

	if #conflicts > 0 then
		return {
			ok = false,
			packages = packages,
			order = {},
			conflicts = conflicts,
			kind = "conflict",
			message = "Some packages could not be resolved to a single version.",
		}
	end

	--------------------------------------------------------------------------------
	-- ORDER
	--------------------------------------------------------------------------------
	-- Alphabetical, so an install log and a wally.lock read the same way every time.
	-- Dependency order is irrelevant here: links are created as instances and only
	-- resolve when something is required at runtime, by which point the whole set is
	-- in place.
	local order = {}
	for key in packages do
		table.insert(order, key)
	end
	table.sort(order)

	return {
		ok = true,
		packages = packages,
		order = order,
		conflicts = {},
	}
end

--[[
	Human-readable explanation of a failed resolution, ready to show as-is.

	A conflict is reported as the full list of who wants what, because the fix is
	always a change to one of those requirements and the user needs to see which ones
	are in play to choose.
]]
function Resolver.Explain(resolution: Resolution): string
	if resolution.ok then
		return ""
	end

	if resolution.kind == "conflict" and #resolution.conflicts > 0 then
		local lines = {}
		for _, conflict in resolution.conflicts do
			table.insert(lines, `{conflict.fullName} has no version satisfying every requirement:`)
			for _, constraint in conflict.constraints do
				table.insert(lines, `    {constraint.requirement}  (required by {constraint.source})`)
			end
			local newest = conflict.available[1]
			if newest then
				table.insert(lines, `    latest published is {newest}`)
			end
		end
		return table.concat(lines, "\n")
	end

	return resolution.message or "Resolution failed."
end

--[[
	The packages in `resolution` that are not already installed at the same version,
	given the current install set. Used to show what an install will actually change
	before it runs.
]]
function Resolver.Diff(resolution: Resolution, installed: { [string]: { version: string } }): {
	added: { ResolvedPackage },
	changed: { { package: ResolvedPackage, from: string } },
	unchanged: { ResolvedPackage },
}
	local added, changed, unchanged = {}, {}, {}

	for _, key in resolution.order do
		local package = resolution.packages[key]
		local current = installed[key]
		if not current then
			table.insert(added, package)
		elseif current.version ~= package.version then
			table.insert(changed, { package = package, from = current.version })
		else
			table.insert(unchanged, package)
		end
	end

	return { added = added, changed = changed, unchanged = unchanged }
end

return Resolver
