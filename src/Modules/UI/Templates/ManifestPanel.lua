--!nonstrict
--[[
======================================================================================
	MANIFEST PANEL  -  wally.toml in, wally.toml out
======================================================================================
	The tab that keeps this plugin from being a one-way door.

	Export writes a real manifest for what is installed, so a project that started in
	Studio can move to a Rojo and command-line workflow without anyone re-picking
	every package by hand. Import reads one, so a project that already has a manifest
	can be brought into a place without retyping it.

	Only direct packages are written, with caret requirements — the same thing a
	person would write. Listing the transitive ones would pin versions the user never
	chose and turn a manifest into a lock file, which it is not.

	Studio has no clipboard API, so export offers the text for selection and, more
	usefully, a button that stores it in the place as a StringValue. That copy travels
	with the place file and is where an external tool can find it.
======================================================================================
]]

local ServerStorage = game:GetService("ServerStorage")
local Selection = game:GetService("Selection")

local Constants = require(script.Parent.Parent.Parent.Config.Constants)
local Theme = require(script.Parent.Parent.Parent.Config.Theme)
local Widgets = require(script.Parent.Parent.Components.Widgets)
local Project = require(script.Parent.Parent.Parent.Services.Project)
local Resolver = require(script.Parent.Parent.Parent.Services.Resolver)
local Installer = require(script.Parent.Parent.Parent.Services.Installer)

local ManifestPanel = {}

local STORED_NAME = "wally.toml"

function ManifestPanel.Mount(context)
	local cleaner = context.Cleaner
	local root = context.Root
	Widgets.List(root, Theme.Space.Medium)

	local scroller = Widgets.Scroller(root, Theme.Space.Small)
	local exportBox
	local importBox
	local loadRow: Frame? = nil
	local render

	--[[
		Rebuild the "load from" buttons: the stored value if present, plus whatever
		StringValue is currently selected in the Explorer. Runs on render and on
		every SelectionChanged, and only ever touches its own row — a selection
		change must never wipe text already pasted into the import box, so this
		deliberately does not re-render the card.
	]]
	local function refreshLoaders()
		local row = loadRow
		if not row or not row.Parent then
			return
		end
		for _, child in row:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
		local slot = 1

		local stored = ServerStorage:FindFirstChild(STORED_NAME)
		if stored and stored:IsA("StringValue") then
			local value = stored :: StringValue
			Widgets.Button({
				parent = row,
				text = `Load ServerStorage.{STORED_NAME}`,
				variant = "ghost",
				cleaner = cleaner,
				order = slot,
				onClick = function()
					importBox.Text = value.Value
					context.Notify("Loaded. Review it, then install.", "info")
				end,
			})
			slot += 1
		end

		local picked: Instance? = nil
		for _, instance in Selection:Get() do
			if instance:IsA("StringValue") then
				picked = instance
				break
			end
		end
		if picked then
			local target = picked :: StringValue
			Widgets.Button({
				parent = row,
				text = `Load selected "{target.Name}"`,
				variant = "secondary",
				cleaner = cleaner,
				order = slot,
				onClick = function()
					importBox.Text = target.Value
					context.Notify(`Loaded "{target.Name}". Review it, then install.`, "info")
				end,
			})
			slot += 1
		end

		local shown = 0
		for _, child in row:GetChildren() do
			if not child:IsA("UIListLayout") then
				shown += 1
			end
		end
		row.Visible = shown > 0
	end

	-- Connected once per mount, not per render: render() reassigns loadRow, and
	-- this closure always follows the current one.
	cleaner:Add(Selection.SelectionChanged:Connect(refreshLoaders))

	--------------------------------------------------------------------------------
	-- IMPORT
	--------------------------------------------------------------------------------
	local function runImport(text: string)
		local parsed = Project.ParseManifest(text)
		if not parsed.ok then
			context.Notify(parsed.message or "That manifest could not be read.", "error")
			return
		end

		for _, problem in parsed.problems do
			context.Log(`manifest: {problem}`, "warning")
		end

		context.RunTask(function()
			local installedTotal = 0
			local failed = 0

			-- Each realm is its own closure: dependency links are relative to the
			-- Packages folder they live in, so the shared and server sets cannot be
			-- resolved together. See the note in Resolver.
			for _, realm in Constants.REALM_ORDER do
				local roots = parsed.roots[realm]
				if not roots or #roots == 0 then
					continue
				end

				local resolverRoots = {}
				for _, entry in roots do
					table.insert(resolverRoots, {
						scope = entry.scope,
						name = entry.name,
						requirement = entry.requirement or "*",
						alias = entry.alias,
					})
				end

				context.SetBusy(true, `Resolving {Constants.REALMS[realm].label} dependencies`)
				local resolution = Resolver.Resolve(context.Registry, resolverRoots, realm, function(message)
					context.SetBusy(true, message)
				end)

				if not resolution.ok then
					context.SetBusy(false)
					context.Notify(Resolver.Explain(resolution), "error")
					failed += 1
					continue
				end

				local outcome = Installer.Install({
					registry = context.Registry,
					resolution = resolution,
					realm = realm,
					onProgress = function(message, done, total)
						context.SetBusy(true, message, done / math.max(total, 1))
					end,
				})

				installedTotal += #outcome.installed
				if not outcome.ok then
					failed += #outcome.failed
					for _, failure in outcome.failed do
						context.Log(`{failure.fullName}: {failure.reason}`, "error")
					end
				end
			end

			context.SetBusy(false)

			if failed > 0 then
				context.Notify(`Installed {installedTotal} package(s); {failed} failed. See the log.`, "warning")
			else
				context.Notify(`Installed {installedTotal} package(s) from the manifest.`, "success")
			end

			context.RefreshInstalled()
			render()
		end)
	end

	--------------------------------------------------------------------------------
	-- RENDER
	--------------------------------------------------------------------------------
	function render()
		for _, child in scroller:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end

		local byRealm = context.GetInstalled()
		local total = 0
		for _, installed in byRealm do
			total += installed.directCount
		end

		----------------------------------------------------------------------------
		-- EXPORT
		----------------------------------------------------------------------------
		local exportCard = Widgets.Card({ parent = scroller, order = 1, gap = Theme.Space.Small })
		Widgets.SectionTitle(exportCard, "Export", 1)
		Widgets.Label({
			parent = exportCard,
			text = total > 0
					and `A wally.toml for the {total} package{total == 1 and "" or "s"} installed here. Select the text to copy it, or store it in the place.`
				or "Nothing is installed yet, so there is nothing to export.",
			size = Theme.TextSize.Label,
			color = Theme.Color.Subtext,
			wrap = true,
			order = 2,
		})

		if total > 0 then
			local manifest = Project.ExportManifest(byRealm, context.Settings:Get("projectName") ~= "" and context.Settings:Get("projectName") or nil)
			local lineCount = 1
			for _ in manifest:gmatch("\n") do
				lineCount += 1
			end

			exportBox = Widgets.Input({
				parent = exportCard,
				text = manifest,
				multiline = true,
				height = 150,
				cleaner = cleaner,
				order = 3,
			})
			exportBox.TextEditable = false

			Widgets.Label({
				parent = exportCard,
				text = `{lineCount} lines, {#manifest} chars`,
				size = Theme.TextSize.Caption,
				font = Theme.Font.Mono,
				color = Theme.Color.Faint,
				align = Enum.TextXAlignment.Right,
				order = 4,
			})

			Widgets.Button({
				parent = exportCard,
				text = `Store as {STORED_NAME} in ServerStorage`,
				variant = "secondary",
				cleaner = cleaner,
				order = 5,
				width = UDim.new(1, 0),
				onClick = function()
					local existing = ServerStorage:FindFirstChild(STORED_NAME)
					if existing and not existing:IsA("StringValue") then
						context.Notify(`Something else is already called {STORED_NAME} in ServerStorage.`, "error")
						return
					end
					local value = existing or Instance.new("StringValue")
					value.Name = STORED_NAME
					value.Value = manifest
					value.Parent = ServerStorage
					context.Notify(`Saved to ServerStorage.{STORED_NAME}.`, "success")
				end,
			})
		end

		----------------------------------------------------------------------------
		-- IMPORT
		----------------------------------------------------------------------------
		local importCard = Widgets.Card({ parent = scroller, order = 2, gap = Theme.Space.Small })
		Widgets.SectionTitle(importCard, "Import", 1)
		Widgets.Label({
			parent = importCard,
			text = "Paste a wally.toml to install everything it lists — or select a stored value in the Explorer and load it below. Versions are resolved against the registry, exactly as `wally install` would: this is not a lock file.",
			size = Theme.TextSize.Label,
			color = Theme.Color.Subtext,
			wrap = true,
			order = 2,
		})

		importBox = Widgets.Input({
			parent = importCard,
			placeholder = "[dependencies]\nRoact = \"roblox/roact@^1.4.4\"",
			multiline = true,
			height = 120,
			cleaner = cleaner,
			order = 3,
		})

		Widgets.Button({
			parent = importCard,
			text = "Install from manifest",
			variant = "primary",
			cleaner = cleaner,
			order = 4,
			width = UDim.new(1, 0),
			height = Theme.Height.Tall,
			onClick = function()
				local text = importBox.Text
				if text:match("^%s*$") then
					context.Notify("Paste a manifest first.", "info")
					return
				end
				runImport(text)
			end,
		})

		-- Load-from row: the stored value and the Explorer selection share one row
		-- so the choice reads as "import from where" rather than scattered buttons.
		loadRow = Widgets.Row(importCard, Theme.Space.Small, 5)
		refreshLoaders()
	end

	render()

	return { Refresh = render }
end

return ManifestPanel
