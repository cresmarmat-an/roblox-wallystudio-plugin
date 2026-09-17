--!nonstrict
--[[
======================================================================================
	INSTALLED PANEL  -  what this place has, and what has moved on since
======================================================================================
	Reads its whole picture from the instance tree on every refresh rather than
	holding state. A user can delete a folder in Explorer at any moment, and a list
	that remembered what it saw a minute ago would keep offering to update something
	that is no longer there.

	Direct packages are shown by default and transitive ones are hidden behind a
	toggle. The difference matters: a direct package is a decision the user made and
	can revisit, while a transitive one exists because something else needs it, and
	offering an Update button beside it would invite a combination its dependent never
	declared support for. The count of hidden packages is always visible, so nothing
	is secret — only quiet.

	UPDATES
	Two kinds, deliberately distinguished. A compatible update stays inside the range
	the package was installed under and is safe to take. A newer major version is
	shown as well, but as a separate, plainly labelled choice, because taking it can
	break the code that calls into it.
======================================================================================
]]

local Constants = require(script.Parent.Parent.Parent.Config.Constants)
local Theme = require(script.Parent.Parent.Parent.Config.Theme)
local Widgets = require(script.Parent.Parent.Components.Widgets)
local Project = require(script.Parent.Parent.Parent.Services.Project)
local Resolver = require(script.Parent.Parent.Parent.Services.Resolver)
local Installer = require(script.Parent.Parent.Parent.Services.Installer)

local InstalledPanel = {}

function InstalledPanel.Mount(context)
	local cleaner = context.Cleaner
	local registry = context.Registry

	local root = context.Root
	Widgets.List(root, Theme.Space.Small)

	local currentRealm = context.Settings:Get("defaultRealm")
	-- Keyed by package key; filled by an explicit update check, cleared by anything
	-- that changes the install set.
	local updateInfo: { [string]: any } = {}
	local render

	--------------------------------------------------------------------------------
	-- REALM PICKER
	--------------------------------------------------------------------------------
	local realmOptions = {}
	for _, realm in Constants.REALM_ORDER do
		table.insert(realmOptions, { id = realm, label = Constants.REALMS[realm].label })
	end

	Widgets.SegmentedControl({
		parent = root,
		options = realmOptions,
		selected = currentRealm,
		cleaner = cleaner,
		order = 1,
		onSelect = function(id)
			currentRealm = id
			updateInfo = {}
			render()
		end,
	})

	local list = Instance.new("Frame")
	list.BackgroundTransparency = 1
	list.Size = UDim2.new(1, 0, 1, 0)
	list.LayoutOrder = 2
	list.Parent = root
	local flex = Instance.new("UIFlexItem")
	flex.FlexMode = Enum.UIFlexMode.Fill
	flex.Parent = list

	local scroller = Widgets.Scroller(list, Theme.Space.ExtraSmall)

	local function clear()
		for _, child in scroller:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
	end

	--------------------------------------------------------------------------------
	-- ACTIONS
	--------------------------------------------------------------------------------
	--[[
		Install one package at an exact version, replacing whatever is there.

		Resolution runs again rather than reusing what is installed, because a
		different version of a package generally declares different dependencies.

		Yields, and deliberately does not spawn: "Update all" runs these one after
		another, and installs that overlapped would be writing into the same _Index
		folder at the same time. Callers handling a single button press wrap it in
		context.RunTask themselves.
	]]
	local function installVersion(package, version: string): boolean
		context.SetBusy(true, `Resolving {package.fullName}@{version}`)

		local resolution = Resolver.Resolve(registry, {
			{
				scope = package.scope,
				name = package.name,
				requirement = `={version}`,
				alias = package.alias,
			},
		}, currentRealm, function(message)
			context.SetBusy(true, message)
		end)

		if not resolution.ok then
			context.SetBusy(false)
			context.Notify(Resolver.Explain(resolution), "error")
			return false
		end

		local outcome = Installer.Install({
			registry = registry,
			resolution = resolution,
			realm = currentRealm,
			onProgress = function(message, done, total)
				context.SetBusy(true, message, done / math.max(total, 1))
			end,
		})

		-- The previous version's folder is still sitting in _Index, unreferenced the
		-- moment the link above it was repointed. Sweep it now rather than leaving the
		-- user to notice and run Clean themselves.
		local removed = Installer.Prune(currentRealm, Project.FindOrphans(Project.Scan(currentRealm)))

		context.SetBusy(false)

		if outcome.ok then
			local suffix = #removed > 0 and `, removed {#removed} now unused` or ""
			context.Notify(`{package.fullName} is now {version}{suffix}.`, "success")
		else
			context.Notify(outcome.message or "Update failed.", "error")
		end

		updateInfo[package.key] = nil
		context.RefreshInstalled()
		return outcome.ok
	end

	local function removePackage(package)
		context.RunTask(function()
			context.SetBusy(true, `Removing {package.fullName}`)
			local installed = Project.Scan(currentRealm)
			local outcome = Installer.Uninstall(currentRealm, package.fullName, installed)
			context.SetBusy(false)

			local extra = #outcome.removed - 1
			local suffix = extra > 0 and ` and {extra} package{extra == 1 and "" or "s"} only it needed` or ""
			context.Notify(`Removed {package.fullName}{suffix}.`, "success")

			updateInfo = {}
			context.RefreshInstalled()
		end)
	end

	local function checkUpdates()
		context.RunTask(function()
			local installed = Project.Scan(currentRealm)
			if installed.directCount == 0 then
				context.Notify("Nothing installed here to check.", "info")
				return
			end

			context.SetBusy(true, "Checking for updates")
			local outcome = Project.CheckUpdates(registry, installed, function(message)
				context.SetBusy(true, message)
			end)
			context.SetBusy(false)

			updateInfo = {}
			for _, info in outcome.updates do
				updateInfo[info.package.key] = info
			end

			for _, failure in outcome.failures do
				context.Log(`{failure.fullName}: {failure.message}`, "warning")
			end

			if #outcome.updates == 0 then
				context.Notify("Everything is up to date.", "success")
			else
				context.Notify(
					`{#outcome.updates} package{#outcome.updates == 1 and " has" or "s have"} a newer version.`,
					"info"
				)
			end
			render()
		end)
	end

	--------------------------------------------------------------------------------
	-- ROWS
	--------------------------------------------------------------------------------
	local function renderPackage(package, order: number)
		local info = updateInfo[package.key]

		local row = Widgets.ListRow({ parent = scroller, order = order })

		local titleRow = Widgets.Row(row, Theme.Space.Small, 1)

		local nameStack = Instance.new("Frame")
		nameStack.BackgroundTransparency = 1
		nameStack.Size = UDim2.new(0, 0, 0, 0)
		nameStack.AutomaticSize = Enum.AutomaticSize.XY
		nameStack.LayoutOrder = 1
		nameStack.Parent = titleRow
		Widgets.List(nameStack, 0)

		Widgets.Label({
			parent = nameStack,
			text = package.alias or package.name,
			size = Theme.TextSize.Heading,
			font = Theme.Font.Bold,
			order = 1,
		})
		Widgets.Label({
			parent = nameStack,
			text = package.fullName,
			size = Theme.TextSize.Caption,
			color = Theme.Color.Faint,
			order = 2,
		})

		Widgets.Spacer(titleRow, 2)
		Widgets.Badge(titleRow, package.version, package.direct and Theme.Color.Subtext or Theme.Color.Faint, 3)

		if not package.direct then
			-- Say why it is here, since the user never asked for it.
			local dependents = {}
			for _, other in context.GetInstalled()[currentRealm].packages do
				if table.find(other.dependencyKeys, package.key) then
					table.insert(dependents, other.name)
				end
			end
			table.sort(dependents)
			Widgets.Label({
				parent = row,
				text = #dependents > 0 and `required by {table.concat(dependents, ", ")}` or "not required by anything",
				size = Theme.TextSize.Caption,
				color = Theme.Color.Faint,
				wrap = true,
				order = 2,
			})
			return
		end

		if info then
			local lines = {}
			if info.compatible then
				table.insert(lines, `{info.compatible} is available and compatible.`)
			end
			if info.latest and info.latest ~= info.compatible then
				table.insert(lines, `{info.latest} is the newest, but outside {package.requirement or "this range"}.`)
			end
			Widgets.Label({
				parent = row,
				text = table.concat(lines, " "),
				size = Theme.TextSize.Caption,
				color = info.compatible and Theme.Color.Warning or Theme.Color.Subtext,
				wrap = true,
				order = 2,
			})
		end

		local actions = Widgets.Row(row, Theme.Space.Small, 3)
		local order_ = 1

		if info and info.compatible then
			local button
			button = Widgets.Button({
				parent = actions,
				text = `Update to {info.compatible}`,
				variant = "secondary",
				cleaner = cleaner,
				order = order_,
				onClick = function()
					button.Text = "Working…"
					button.Active = false
					context.RunTask(function()
						installVersion(package, info.compatible)
					end)
				end,
			})
			order_ += 1
		end

		if info and info.latest and info.latest ~= info.compatible and info.latest ~= package.version then
			local button
			button = Widgets.Button({
				parent = actions,
				text = `Take {info.latest}`,
				variant = "secondary",
				cleaner = cleaner,
				order = order_,
				onClick = function()
					button.Text = "Working…"
					button.Active = false
					context.RunTask(function()
						installVersion(package, info.latest)
					end)
				end,
			})
			order_ += 1
		end

		Widgets.Spacer(actions, 40)

		Widgets.Button({
			parent = actions,
			text = "Remove",
			variant = "dangerGhost",
			cleaner = cleaner,
			order = 41,
			onClick = function()
				removePackage(package)
			end,
		})
	end

	--------------------------------------------------------------------------------
	-- RENDER
	--------------------------------------------------------------------------------
	function render()
		clear()

		local installed = Project.Scan(currentRealm)
		context.SetInstalled(currentRealm, installed)

		local definition = Constants.REALMS[currentRealm]

		if installed.totalCount == 0 then
			Widgets.EmptyState(
				scroller,
				`No packages in {definition.label}`,
				`Nothing is installed in {definition.service}.{definition.folder} yet. Find something on the Browse tab.`
			)
			return
		end

		--------------------------------------------------------------------------
		-- SUMMARY
		--------------------------------------------------------------------------
		local summary = Widgets.Card({ parent = scroller, order = 1, gap = Theme.Space.Small })

		-- A hero numeral plus where it lives: "3 direct packages" reads instantly,
		-- and the mono service path says which tree that means without a trip to
		-- Settings.
		local heroRow = Widgets.Row(summary, Theme.Space.Small, 1)
		Widgets.Label({
			parent = heroRow,
			text = `{installed.directCount}`,
			size = Theme.TextSize.Display,
			font = Theme.Font.Bold,
			width = UDim.new(0, 0),
			order = 1,
		}).AutomaticSize = Enum.AutomaticSize.XY

		local heroStack = Instance.new("Frame")
		heroStack.BackgroundTransparency = 1
		heroStack.Size = UDim2.new(0, 0, 0, 0)
		heroStack.AutomaticSize = Enum.AutomaticSize.XY
		heroStack.LayoutOrder = 2
		heroStack.Parent = heroRow
		Widgets.List(heroStack, 0)

		local transitive = installed.totalCount - installed.directCount
		local heroLine = `{installed.directCount} direct`
		if transitive > 0 then
			heroLine ..= `, {transitive} transitive`
		end
		Widgets.Label({
			parent = heroStack,
			text = heroLine,
			size = Theme.TextSize.Body,
			color = Theme.Color.Subtext,
			order = 1,
		})
		Widgets.Label({
			parent = heroStack,
			text = `{definition.service}.{definition.folder}`,
			size = Theme.TextSize.Caption,
			font = Theme.Font.Mono,
			color = Theme.Color.Faint,
			order = 2,
		})

		local pending = 0
		for _ in updateInfo do
			pending += 1
		end
		if pending > 0 then
			Widgets.Spacer(heroRow, 3)
			Widgets.Badge(heroRow, `{pending} update{pending == 1 and "" or "s"}`, Theme.Color.Warning, 4)
		end

		local tools = Widgets.Row(summary, Theme.Space.Small, 2)
		Widgets.Button({
			parent = tools,
			text = "Check for updates",
			variant = "secondary",
			cleaner = cleaner,
			order = 1,
			onClick = checkUpdates,
		})

		if pending > 0 then
			Widgets.Button({
				parent = tools,
				text = "Update all",
				variant = "primary",
				cleaner = cleaner,
				order = 2,
				onClick = function()
					-- Only compatible updates. Taking every major bump at once is
					-- never what "update all" is meant to mean.
					local queue = {}
					for _, info in updateInfo do
						if info.compatible then
							table.insert(queue, info)
						end
					end
					if #queue == 0 then
						context.Notify("The only updates available are major versions. Take those one at a time.", "info")
						return
					end
					context.RunTask(function()
						local updated = 0
						for _, info in queue do
							if installVersion(info.package, info.compatible) then
								updated += 1
							end
						end
						context.Notify(`Updated {updated} of {#queue} packages.`, updated == #queue and "success" or "warning")
					end)
				end,
			})
		end

		local orphans = Project.FindOrphans(installed)
		if #orphans > 0 then
			-- Its own row: three actions never fit one 320px line, and cleanup is
			-- janitorial next to Check/Update, not their peer.
			local cleanRow = Widgets.Row(summary, Theme.Space.Small, 3)
			Widgets.Button({
				parent = cleanRow,
				text = `Clean {#orphans} unused`,
				variant = "ghost",
				cleaner = cleaner,
				order = 1,
				onClick = function()
					local removed = Installer.Prune(currentRealm, orphans)
					context.Notify(`Removed {#removed} unused package{#removed == 1 and "" or "s"}.`, "success")
					context.RefreshInstalled()
				end,
			})
		end

		--------------------------------------------------------------------------
		-- LIST
		--------------------------------------------------------------------------
		local showTransitive = context.Settings:Get("showTransitive")
		local order = 2
		local hidden = 0

		for _, key in installed.order do
			local package = installed.packages[key]
			if package.direct or showTransitive then
				renderPackage(package, order)
				order += 1
			else
				hidden += 1
			end
		end

		if hidden > 0 then
			-- A plain line, not a card: it closes the list rather than joining it.
			local row = Widgets.Row(scroller, Theme.Space.Small, 999)
			Widgets.Label({
				parent = row,
				text = `{hidden} dependenc{hidden == 1 and "y is" or "ies are"} installed for these`,
				size = Theme.TextSize.Label,
				color = Theme.Color.Subtext,
				width = UDim.new(0, 0),
				order = 1,
			}).AutomaticSize = Enum.AutomaticSize.XY
			Widgets.Spacer(row, 2)
			Widgets.Button({
				parent = row,
				text = "Show",
				variant = "ghost",
				cleaner = cleaner,
				order = 3,
				onClick = function()
					context.Settings:Set("showTransitive", true)
					render()
				end,
			})
		elseif showTransitive then
			Widgets.Button({
				parent = scroller,
				text = "Hide dependencies",
				variant = "ghost",
				cleaner = cleaner,
				order = 999,
				onClick = function()
					context.Settings:Set("showTransitive", false)
					render()
				end,
			})
		end
	end

	return {
		Refresh = render,
		CheckUpdates = checkUpdates,
	}
end

return InstalledPanel
