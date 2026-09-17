--!nonstrict
--[[
======================================================================================
	BROWSE PANEL  -  find a package and install it
======================================================================================
	Two views in one tab: a result list, and a detail view for one package. They share
	the tab rather than opening a window, because a docked panel is narrow and a modal
	over 380 pixels leaves nothing visible behind it to return to.

	THE INSTALL CONFIRMATION
	Installing one package routinely installs six. Knit brings Comm, Promise, Option
	and Signal, none of which the user named, and all of which appear in their
	ReplicatedStorage afterwards. So the button resolves first, and when the closure
	is larger than what was asked for it turns into a confirmation naming exactly what
	will be added, in place, where the button was.

	Doing it inline rather than as a dialog matters: the answer to "do you want these
	five as well" is usually yes, and a dialog makes the common case slower while an
	inline strip makes the surprising case visible.
======================================================================================
]]

local Constants = require(script.Parent.Parent.Parent.Config.Constants)
local Theme = require(script.Parent.Parent.Parent.Config.Theme)
local Widgets = require(script.Parent.Parent.Components.Widgets)
local Registry = require(script.Parent.Parent.Parent.Services.Registry)
local Resolver = require(script.Parent.Parent.Parent.Services.Resolver)
local Installer = require(script.Parent.Parent.Parent.Services.Installer)

local BrowsePanel = {}

--[[
	Mount the browse tab into `context.Root`.

	`context` carries the shared services and the callbacks the panel needs to reach
	the rest of the app: see init.server.lua, which builds it.
]]
function BrowsePanel.Mount(context)
	local cleaner = context.Cleaner
	local registry = context.Registry

	local root = context.Root
	Widgets.List(root, Theme.Space.Small)

	--------------------------------------------------------------------------------
	-- SEARCH BAR
	--------------------------------------------------------------------------------
	local searchRow = Widgets.Row(root, Theme.Space.Small, 1)

	local searchBox
	local resultsArea
	local detailArea

	-- Every search increments this. A response whose token is stale is discarded, so
	-- a slow request for "ro" cannot overwrite the results for "roact" typed after it.
	local searchToken = 0
	local lastQuery = ""

	local function setView(showDetail: boolean)
		resultsArea.Visible = not showDetail
		detailArea.Visible = showDetail
	end

	local runSearch

	searchBox = Widgets.Input({
		parent = searchRow,
		placeholder = "Search packages, or paste scope/name@1.2.3",
		height = Theme.Height.Tall,
		cleaner = cleaner,
		order = 1,
		onChanged = function(text)
			runSearch(text, true)
		end,
		onSubmit = function(text)
			runSearch(text, false)
		end,
	})
	-- The input builder returns the TextBox; the frame around it is what sits in the
	-- row, and that is what has to stretch to fill it.
	local searchFlex = Instance.new("UIFlexItem")
	searchFlex.FlexMode = Enum.UIFlexMode.Fill
	searchFlex.Parent = searchBox.Parent

	-- One quiet line under the search field that narrates the list below it:
	-- result counts, searching state, nothing-found. Without it the list swaps
	-- content with no acknowledgement, which reads as flicker.
	local meta = Widgets.Label({
		parent = root,
		text = "",
		size = Theme.TextSize.Label,
		color = Theme.Color.Subtext,
		truncate = true,
		order = 2,
	})

	--------------------------------------------------------------------------------
	-- VIEWS
	--------------------------------------------------------------------------------
	local body = Instance.new("Frame")
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 1, 0)
	body.LayoutOrder = 3
	body.Parent = root
	local bodyFlex = Instance.new("UIFlexItem")
	bodyFlex.FlexMode = Enum.UIFlexMode.Fill
	bodyFlex.Parent = body

	resultsArea = Instance.new("Frame")
	resultsArea.BackgroundTransparency = 1
	resultsArea.Size = UDim2.fromScale(1, 1)
	resultsArea.Parent = body

	detailArea = Instance.new("Frame")
	detailArea.BackgroundTransparency = 1
	detailArea.Size = UDim2.fromScale(1, 1)
	detailArea.Visible = false
	detailArea.Parent = body

	local results = Widgets.Scroller(resultsArea, Theme.Space.ExtraSmall)
	local detail = Widgets.Scroller(detailArea, Theme.Space.Small)

	local function clear(container: Instance)
		for _, child in container:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
	end

	--------------------------------------------------------------------------------
	-- INSTALL
	--------------------------------------------------------------------------------
	--[[
		Resolve, optionally confirm, then install.

		`onDone` is called with a boolean so the calling card can put its own button
		back however the attempt turned out.
	]]
	local function performInstall(scope: string, name: string, version: string, realm: string, mount: Frame, onDone)
		local roots = { {
			scope = scope,
			name = name,
			requirement = `={version}`,
			alias = Registry.DefaultAlias(name),
		} }

		context.SetBusy(true, `Resolving {scope}/{name}`)

		local resolution = Resolver.Resolve(registry, roots, realm, function(message)
			context.SetBusy(true, message)
		end)

		if not resolution.ok then
			context.SetBusy(false)
			context.Notify(Resolver.Explain(resolution), "error")
			onDone(false)
			return
		end

		local installed = context.GetInstalled()[realm]
		local difference = Resolver.Diff(resolution, installed and installed.packages or {})
		local extra = #difference.added + #difference.changed

		local function runInstall()
			context.SetBusy(true, `Installing {scope}/{name}`)
			local outcome = Installer.Install({
				registry = registry,
				resolution = resolution,
				realm = realm,
				onProgress = function(message, done, total)
					context.SetBusy(true, message, done / math.max(total, 1))
				end,
			})
			context.SetBusy(false)

			if outcome.ok then
				local target = Constants.REALMS[realm]
				context.Notify(
					`Installed {#outcome.installed} package{#outcome.installed == 1 and "" or "s"} into {target.service}.{target.folder}`,
					"success"
				)
			else
				context.Notify(outcome.message or "Install failed.", "error")
				for _, failure in outcome.failed do
					context.Log(`{failure.fullName}: {failure.reason}`, "error")
				end
			end

			for _, skipped in outcome.skipped do
				context.Log(`skipped {skipped.path} — {skipped.reason}`, "warning")
			end

			context.RefreshInstalled()
			onDone(outcome.ok)
		end

		-- Nothing to do: the exact set is already present.
		if extra == 0 then
			context.SetBusy(false)
			context.Notify(`{scope}/{name}@{version} is already installed.`, "info")
			onDone(true)
			return
		end

		local bringsExtras = #resolution.order > 1
		if not (context.Settings:Get("confirmDependencies") and bringsExtras) then
			runInstall()
			return
		end

		context.SetBusy(false)

		-- Inline confirmation, in place of the button that started this. Tinted so it
		-- reads as "a decision is waiting here" rather than as another card that
		-- drifted into the list.
		local confirm = Widgets.Card({
			parent = mount,
			color = Theme.Mix(Theme.Color.Surface, Theme.Color.Accent, 0.08),
			order = 90,
			gap = Theme.Space.Small,
		})

		local heading = #difference.changed > 0
				and `Installs {#difference.added} and updates {#difference.changed} package{#difference.changed == 1 and "" or "s"}:`
			or `Installs {#difference.added} package{#difference.added == 1 and "" or "s"}:`
		Widgets.Label({
			parent = confirm,
			text = heading,
			size = Theme.TextSize.Label,
			font = Theme.Font.Bold,
			wrap = true,
			order = 1,
		})

		local names = {}
		for _, package in difference.added do
			table.insert(names, `{package.fullName}@{package.version}`)
		end
		for _, change in difference.changed do
			table.insert(names, `{change.package.fullName} {change.from} → {change.package.version}`)
		end

		-- A big closure can name thirty packages. The full list is one tap away,
		-- but the confirmation itself stays five lines tall so it never shoves the
		-- decision buttons off the bottom of the panel.
		local COLLAPSED_LINES = 5
		local expanded = false
		local listLabel = Widgets.Label({
			parent = confirm,
			text = "",
			size = Theme.TextSize.Caption,
			color = Theme.Color.Subtext,
			font = Theme.Font.Mono,
			wrap = true,
			order = 2,
		})
		local function paintList()
			if expanded or #names <= COLLAPSED_LINES then
				listLabel.Text = table.concat(names, "\n")
			else
				local shown = {}
				for index = 1, COLLAPSED_LINES do
					table.insert(shown, names[index])
				end
				table.insert(shown, `… and {#names - COLLAPSED_LINES} more`)
				listLabel.Text = table.concat(shown, "\n")
			end
		end
		paintList()

		if #names > COLLAPSED_LINES then
			local expander
			expander = Widgets.Button({
				parent = confirm,
				text = `Show all {#names}`,
				variant = "ghost",
				cleaner = cleaner,
				order = 3,
				onClick = function()
					expanded = not expanded
					paintList()
					expander.Text = expanded and "Show less" or `Show all {#names}`
				end,
			})
		end

		local actions = Widgets.Row(confirm, Theme.Space.Small, 4)
		Widgets.Button({
			parent = actions,
			text = `Install all {#resolution.order}`,
			variant = "primary",
			cleaner = cleaner,
			order = 1,
			onClick = function()
				confirm:Destroy()
				runInstall()
			end,
		})
		Widgets.Button({
			parent = actions,
			text = "Cancel",
			variant = "ghost",
			cleaner = cleaner,
			order = 2,
			onClick = function()
				confirm:Destroy()
				onDone(false)
			end,
		})
	end

	--------------------------------------------------------------------------------
	-- DETAIL VIEW
	--------------------------------------------------------------------------------
	local function showDetail(entry)
		setView(true)
		clear(detail)

		Widgets.Button({
			parent = detail,
			text = "← Back to results",
			variant = "ghost",
			cleaner = cleaner,
			order = 1,
			onClick = function()
				setView(false)
			end,
		})

		local loading = Widgets.Label({
			parent = detail,
			text = `Loading {entry.scope}/{entry.name}…`,
			size = Theme.TextSize.Label,
			color = Theme.Color.Subtext,
			order = 2,
		})

		context.RunTask(function()
			local metadata = registry:FetchMetadata(entry.scope, entry.name)
			if loading.Parent then
				loading:Destroy()
			end
			if not detailArea.Visible then
				return
			end

			if not metadata.ok then
				context.ShowRegistryError(detail, metadata, 2)
				return
			end

			local data = metadata.data
			local versions = data.versionList
			local selectedVersion = versions[1]
			local selectedRealm = context.Settings:Get("defaultRealm")

			-- One key per fact row, one value beside it. The old newline blob ran
			-- every fact together in a single faint paragraph nobody scanned; a
			-- two-column grid reads like the registry page it mirrors.
			local function factRow(parent: Instance, key: string, value: string, order: number)
				local row = Widgets.Row(parent, Theme.Space.Small, order)
				Widgets.Label({
					parent = row,
					text = key,
					size = Theme.TextSize.Caption,
					font = Theme.Font.Bold,
					color = Theme.Color.Faint,
					width = UDim.new(0.24, 0),
					wrap = true,
					order = 1,
				})
				local answer = Widgets.Label({
					parent = row,
					text = value,
					size = Theme.TextSize.Caption,
					color = Theme.Color.Subtext,
					wrap = true,
					order = 2,
				})
				local flex = Instance.new("UIFlexItem")
				flex.FlexMode = Enum.UIFlexMode.Fill
				flex.Parent = answer
			end

			local hero = Widgets.Card({ parent = detail, order = 2, gap = Theme.Space.Small })
			local heroRow = Widgets.Row(hero, Theme.Space.Small, 1)

			local heroStack = Instance.new("Frame")
			heroStack.BackgroundTransparency = 1
			heroStack.Size = UDim2.new(0, 0, 0, 0)
			heroStack.AutomaticSize = Enum.AutomaticSize.XY
			heroStack.LayoutOrder = 1
			heroStack.Parent = heroRow
			Widgets.List(heroStack, 1)

			Widgets.Label({
				parent = heroStack,
				text = data.name,
				size = Theme.TextSize.Title,
				font = Theme.Font.Bold,
				order = 1,
			})
			Widgets.Label({
				parent = heroStack,
				text = `by {data.scope}`,
				size = Theme.TextSize.Label,
				color = Theme.Color.Subtext,
				order = 2,
			})

			Widgets.Spacer(heroRow, 2)
			Widgets.Badge(heroRow, selectedVersion, Theme.Color.Subtext, 3)

			local newest = data.byVersion[selectedVersion]
			if newest and newest.description then
				Widgets.Label({
					parent = hero,
					text = newest.description,
					size = Theme.TextSize.Body,
					color = Theme.Color.Subtext,
					wrap = true,
					order = 2,
				})
			end

			-- Facts worth knowing before installing something into your game.
			if newest then
				Widgets.Divider(hero, 3)
				local factOrder = 4
				if newest.license then
					factRow(hero, "LICENSE", newest.license, factOrder)
					factOrder += 1
				end
				if #newest.authors > 0 then
					factRow(hero, "AUTHORS", table.concat(newest.authors, ", "), factOrder)
					factOrder += 1
				end
				if newest.repository then
					factRow(hero, "SOURCE", newest.repository, factOrder)
					factOrder += 1
				end
				factRow(hero, "REALM", newest.realm, factOrder)
				factOrder += 1
				factRow(hero, "VERSIONS", `{#versions} published`, factOrder)
			end

			--------------------------------------------------------------------
			-- INSTALL CONTROLS
			--------------------------------------------------------------------
			-- One choice per row, one wide primary action: at 320px the old
			-- side-by-side dropdown plus 150px realm picker truncated both, and the
			-- install button deserved more weight than a row slot.
			local installCard = Widgets.Card({ parent = detail, order = 3, gap = Theme.Space.Small })
			Widgets.SectionTitle(installCard, "Install", 1)

			Widgets.Dropdown({
				parent = installCard,
				options = versions,
				selected = selectedVersion,
				width = UDim.new(1, 0),
				cleaner = cleaner,
				order = 2,
				-- The version list opens inside a scroller, so its menu has to be
				-- hosted above the clipping.
				overlay = context.Overlay,
				onSelect = function(value)
					selectedVersion = value
				end,
			})

			local realmOptions = {}
			for _, realm in Constants.REALM_ORDER do
				table.insert(realmOptions, { id = realm, label = Constants.REALMS[realm].label })
			end

			local destination = Widgets.Label({
				parent = installCard,
				text = "",
				size = Theme.TextSize.Caption,
				color = Theme.Color.Faint,
				align = Enum.TextXAlignment.Center,
				wrap = true,
				order = 5,
			})
			local function paintDestination()
				destination.Text = `Goes to {Constants.REALMS[selectedRealm].service}.{Constants.REALMS[selectedRealm].folder}`
			end
			paintDestination()

			Widgets.SegmentedControl({
				parent = installCard,
				options = realmOptions,
				selected = selectedRealm,
				cleaner = cleaner,
				order = 3,
				onSelect = function(id)
					selectedRealm = id
					-- The destination line names the realm, so it follows the picker.
					paintDestination()
				end,
			})

			local installButton
			installButton = Widgets.Button({
				parent = installCard,
				text = "Install",
				variant = "primary",
				cleaner = cleaner,
				order = 4,
				width = UDim.new(1, 0),
				height = Theme.Height.Tall,
				onClick = function()
					installButton.Text = "Working…"
					installButton.Active = false
					context.RunTask(function()
						performInstall(
							data.scope,
							data.name,
							selectedVersion,
							selectedRealm,
							installCard,
							function()
								if installButton.Parent then
									installButton.Text = "Install"
									installButton.Active = true
								end
							end
						)
					end)
				end,
			})

			--------------------------------------------------------------------
			-- DEPENDENCIES
			--------------------------------------------------------------------
			if newest then
				local dependencyNames = {}
				for alias, specifier in newest.dependencies do
					table.insert(dependencyNames, `{alias} = {specifier}`)
				end
				table.sort(dependencyNames)

				local card = Widgets.Card({ parent = detail, order = 4, gap = Theme.Space.ExtraSmall })
				Widgets.SectionTitle(card, `Dependencies ({#dependencyNames})`, 1)
				Widgets.Label({
					parent = card,
					text = #dependencyNames > 0 and table.concat(dependencyNames, "\n")
						or "None — this package stands alone.",
					size = Theme.TextSize.Caption,
					font = #dependencyNames > 0 and Theme.Font.Mono or Theme.Font.Regular,
					color = Theme.Color.Subtext,
					wrap = true,
					order = 2,
				})
			end

			--------------------------------------------------------------------
			-- VERSION HISTORY
			--------------------------------------------------------------------
			local history = Widgets.Card({ parent = detail, order = 5, gap = Theme.Space.ExtraSmall })
			Widgets.SectionTitle(history, "Version history", 1)
			local shown = {}
			for index = 1, math.min(#versions, 12) do
				table.insert(shown, versions[index])
			end
			if #versions > 12 then
				table.insert(shown, `… and {#versions - 12} more`)
			end
			Widgets.Label({
				parent = history,
				text = table.concat(shown, "   "),
				size = Theme.TextSize.Caption,
				font = Theme.Font.Mono,
				color = Theme.Color.Subtext,
				wrap = true,
				order = 2,
			})
		end)
	end

	--------------------------------------------------------------------------------
	-- RESULT CARDS
	--------------------------------------------------------------------------------
	--[[
		A grey placeholder row while the registry answers. Static bars, no shimmer
		loop: a shimmer needs a heartbeat the headless harness cannot run, and a
		loading state that lies about progress is worse than a quiet one.
	]]
	local function showLoading(count: number)
		for index = 1, count do
			local ghost = Widgets.Card({ parent = results, order = index })

			local stack = Instance.new("Frame")
			stack.BackgroundTransparency = 1
			stack.Size = UDim2.new(1, 0, 0, 0)
			stack.AutomaticSize = Enum.AutomaticSize.Y
			stack.LayoutOrder = 1
			stack.Parent = ghost
			Widgets.List(stack, Theme.Space.ExtraSmall)

			for line, width in ipairs({ 0.85, 0.6 }) do
				local bar = Instance.new("Frame")
				bar.BackgroundColor3 = Theme.Color.SurfaceAlt
				bar.BorderSizePixel = 0
				bar.Size = UDim2.new(width, 0, 0, 12)
				bar.LayoutOrder = line
				bar.Parent = stack
				Widgets.Corner(bar, Theme.Radius.Small)
			end
		end
	end

	local function renderResult(entry, order: number)
		local row = Widgets.ListRow({
			parent = results,
			order = order,
			cleaner = cleaner,
			onClick = function()
				showDetail(entry)
			end,
		})

		-- Names and version: the row scans as one package instead of loose labels
		-- that happen to share a container.
		local topRow = Widgets.Row(row, Theme.Space.Small, 1)

		local titleStack = Instance.new("Frame")
		titleStack.BackgroundTransparency = 1
		titleStack.Size = UDim2.new(0, 0, 0, 0)
		titleStack.AutomaticSize = Enum.AutomaticSize.XY
		titleStack.LayoutOrder = 1
		titleStack.Parent = topRow
		Widgets.List(titleStack, 1)

		Widgets.Label({
			parent = titleStack,
			text = entry.name,
			size = Theme.TextSize.Heading,
			font = Theme.Font.Bold,
			order = 1,
		})
		Widgets.Label({
			parent = titleStack,
			text = entry.scope,
			size = Theme.TextSize.Caption,
			color = Theme.Color.Faint,
			order = 2,
		})

		Widgets.Spacer(topRow, 2)

		if entry.latest then
			-- Neutral by choice: a version number is information, not a state and
			-- not an action, so it gets no accent and no warning colour.
			Widgets.Badge(topRow, entry.latest, Theme.Color.Subtext, 3)
		end

		if entry.description then
			Widgets.Label({
				parent = row,
				text = entry.description,
				size = Theme.TextSize.Label,
				color = Theme.Color.Subtext,
				wrap = true,
				order = 2,
			})
		end

		local actions = Widgets.Row(row, Theme.Space.Small, 3)
		local quickInstall
		quickInstall = Widgets.Button({
			parent = actions,
			text = "Install",
			variant = "secondary",
			cleaner = cleaner,
			order = 1,
			onClick = function()
				if not entry.latest then
					return
				end
				quickInstall.Text = "Working…"
				quickInstall.Active = false
				context.RunTask(function()
					performInstall(
						entry.scope,
						entry.name,
						entry.latest,
						context.Settings:Get("defaultRealm"),
						row,
						function()
							if quickInstall.Parent then
								quickInstall.Text = "Install"
								quickInstall.Active = true
							end
						end
					)
				end)
			end,
		})

		Widgets.Button({
			parent = actions,
			text = "Details",
			variant = "ghost",
			cleaner = cleaner,
			order = 2,
			onClick = function()
				showDetail(entry)
			end,
		})
	end

	--------------------------------------------------------------------------------
	-- SEARCH
	--------------------------------------------------------------------------------
	local function showResults(list, query: string)
		clear(results)

		if #list == 0 then
			meta.Text = `No results for "{query}"`
			Widgets.EmptyState(
				results,
				"Nothing found",
				`No package matches "{query}". Wally names look like scope/name — try the scope on its own.`
			)
			return
		end

		meta.Text = `{#list} result{#list == 1 and "" or "s"} for "{query}"`
		for index, entry in list do
			renderResult(entry, index)
		end
	end

	function runSearch(query: string, debounce: boolean)
		local trimmed = query:match("^%s*(.-)%s*$") or ""
		if trimmed == lastQuery and debounce then
			return
		end
		lastQuery = trimmed

		searchToken += 1
		local token = searchToken

		if trimmed == "" then
			clear(results)
			meta.Text = ""
			Widgets.EmptyState(
				results,
				"Search the Wally registry",
				"Type a package name, or paste something like sleitnick/knit@1.7.0 to jump straight to it."
			)
			return
		end

		-- Answer the keystroke immediately with placeholders, then replace them when
		-- the registry answers. A list that sits unchanged for a second after typing
		-- reads as ignoring input.
		clear(results)
		meta.Text = "Searching the registry…"
		showLoading(3)

		context.RunTask(function()
			if debounce then
				task.wait(Constants.SEARCH_DEBOUNCE_SECONDS)
				-- Another keystroke landed while waiting; that search will run instead.
				if token ~= searchToken then
					return
				end
			end

			-- A full specifier is a request for one package, not a search phrase.
			local specifier = Registry.ParseSpecifier(trimmed)
			if specifier then
				local metadata = registry:FetchMetadata(specifier.scope, specifier.name)
				if token ~= searchToken then
					return
				end
				if metadata.ok then
					showResults({
						{
							scope = metadata.data.scope,
							name = metadata.data.name,
							fullName = metadata.data.fullName,
							description = metadata.data.versions[1] and metadata.data.versions[1].description,
							versions = metadata.data.versionList,
							latest = specifier.requirement or metadata.data.versionList[1],
						},
					}, trimmed)
					return
				end
				-- Not a known package; fall through and search for the text instead.
			end

			local outcome = registry:Search(trimmed)
			if token ~= searchToken then
				return
			end

			if not outcome.ok then
				clear(results)
				meta.Text = "The registry did not answer"
				context.ShowRegistryError(results, outcome, 1)
				return
			end

			showResults(outcome.data, trimmed)
		end)
	end

	-- Opening state.
	Widgets.EmptyState(
		results,
		"Search the Wally registry",
		"Type a package name, or paste something like sleitnick/knit@1.7.0 to jump straight to it."
	)

	return {
		Refresh = function()
			if lastQuery ~= "" then
				runSearch(lastQuery, false)
			end
		end,
	}
end

return BrowsePanel
