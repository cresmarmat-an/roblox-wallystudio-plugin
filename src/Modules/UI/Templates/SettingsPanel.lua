--!nonstrict
--[[
======================================================================================
	SETTINGS PANEL  -  preferences, diagnostics and the activity log
======================================================================================
	The log lives here rather than in a drawer over the working tabs. Installing is
	mostly uneventful, and a running feed of it would be noise on the tab where the
	work happens; but when something does go wrong — a package with a file type that
	could not be built, a version that failed to download — the detail has to be
	somewhere, and somewhere findable.

	Toasts carry the outcome. This carries the specifics behind it.
======================================================================================
]]

local Constants = require(script.Parent.Parent.Parent.Config.Constants)
local Theme = require(script.Parent.Parent.Parent.Config.Theme)
local Widgets = require(script.Parent.Parent.Components.Widgets)

local SettingsPanel = {}

function SettingsPanel.Mount(context)
	local cleaner = context.Cleaner
	local settings = context.Settings

	local root = context.Root
	Widgets.List(root, Theme.Space.Medium)

	local scroller = Widgets.Scroller(root, Theme.Space.Small)

	local function section(title: string, order: number)
		local card = Widgets.Card({ parent = scroller, order = order, gap = Theme.Space.Small })
		Widgets.SectionTitle(card, title, 1)
		return card
	end

	--------------------------------------------------------------------------------
	-- INSTALL DEFAULTS
	--------------------------------------------------------------------------------
	local installCard = section("Install", 1)

	Widgets.Label({
		parent = installCard,
		text = "Where packages go by default",
		size = Theme.TextSize.Body,
		order = 2,
	})

	local realmOptions = {}
	for _, realm in Constants.REALM_ORDER do
		table.insert(realmOptions, { id = realm, label = Constants.REALMS[realm].label })
	end
	Widgets.SegmentedControl({
		parent = installCard,
		options = realmOptions,
		selected = settings:Get("defaultRealm"),
		cleaner = cleaner,
		order = 3,
		onSelect = function(id)
			settings:Set("defaultRealm", id)
			context.RefreshInstalled()
		end,
	})

	local realmDescription = Widgets.Label({
		parent = installCard,
		text = Constants.REALMS[settings:Get("defaultRealm")].description,
		size = Theme.TextSize.Caption,
		color = Theme.Color.Faint,
		wrap = true,
		order = 4,
	})
	-- Kept in step with the picker above it, since the difference between the realms
	-- is the thing most likely to be unclear.
	local function refreshRealmDescription()
		realmDescription.Text = Constants.REALMS[settings:Get("defaultRealm")].description
	end

	Widgets.Divider(installCard, 5)

	Widgets.Toggle({
		parent = installCard,
		label = "Confirm when a package brings dependencies",
		description = "Shows what else will be installed before it happens.",
		value = settings:Get("confirmDependencies"),
		cleaner = cleaner,
		order = 6,
		onChanged = function(value)
			settings:Set("confirmDependencies", value)
		end,
	})

	--------------------------------------------------------------------------------
	-- DISPLAY
	--------------------------------------------------------------------------------
	local displayCard = section("Display", 2)

	Widgets.Toggle({
		parent = displayCard,
		label = "Show dependencies in the installed list",
		description = "Off by default: the list then shows only what you chose.",
		value = settings:Get("showTransitive"),
		cleaner = cleaner,
		order = 2,
		onChanged = function(value)
			settings:Set("showTransitive", value)
			context.RefreshInstalled()
		end,
	})

	Widgets.Divider(displayCard, 3)

	Widgets.Toggle({
		parent = displayCard,
		label = "Check for updates when the panel opens",
		description = "One registry request per installed package, each time you open it.",
		value = settings:Get("checkUpdatesOnOpen"),
		cleaner = cleaner,
		order = 4,
		onChanged = function(value)
			settings:Set("checkUpdatesOnOpen", value)
		end,
	})

	--------------------------------------------------------------------------------
	-- PROJECT
	--------------------------------------------------------------------------------
	local projectCard = section("Project", 3)
	Widgets.Label({
		parent = projectCard,
		text = "Name written into an exported wally.toml.",
		size = Theme.TextSize.Label,
		color = Theme.Color.Subtext,
		wrap = true,
		order = 2,
	})
	Widgets.Input({
		parent = projectCard,
		text = settings:Get("projectName"),
		placeholder = "your-scope/your-project",
		cleaner = cleaner,
		order = 3,
		onChanged = function(text)
			settings:Set("projectName", text)
		end,
	})

	--------------------------------------------------------------------------------
	-- REGISTRY
	--------------------------------------------------------------------------------
	local registryCard = section("Registry", 4)
	Widgets.Label({
		parent = registryCard,
		text = "The API this plugin talks to. Change it only for a private registry that speaks the same protocol.",
		size = Theme.TextSize.Label,
		color = Theme.Color.Subtext,
		wrap = true,
		order = 2,
	})
	Widgets.Input({
		parent = registryCard,
		text = settings:Get("registryApi"),
		placeholder = Constants.DEFAULT_REGISTRY_API,
		cleaner = cleaner,
		order = 3,
		onSubmit = function(text)
			local trimmed = text:match("^%s*(.-)%s*$") or ""
			if trimmed == "" then
				trimmed = Constants.DEFAULT_REGISTRY_API
			end
			-- Trailing slashes would produce a double slash in every endpoint path.
			trimmed = trimmed:gsub("/+$", "")
			settings:Set("registryApi", trimmed)
			context.Registry.baseUrl = trimmed
			context.Registry:ClearCache()
			context.Notify(`Registry set to {trimmed}.`, "success")
		end,
	})

	local registryActions = Widgets.Row(registryCard, Theme.Space.Small, 4)
	Widgets.Button({
		parent = registryActions,
		text = "Clear cache",
		variant = "secondary",
		cleaner = cleaner,
		order = 1,
		onClick = function()
			context.Registry:ClearCache()
			context.Notify("Cached search results and archives cleared.", "success")
		end,
	})
	Widgets.Button({
		parent = registryActions,
		text = "Reset to default",
		variant = "ghost",
		cleaner = cleaner,
		order = 2,
		onClick = function()
			settings:Set("registryApi", Constants.DEFAULT_REGISTRY_API)
			context.Registry.baseUrl = Constants.DEFAULT_REGISTRY_API
			context.Registry:ClearCache()
			context.Notify("Registry reset.", "success")
			context.Rebuild()
		end,
	})

	--------------------------------------------------------------------------------
	-- ACTIVITY LOG
	--------------------------------------------------------------------------------
	local logCard = section("Activity", 5)

	-- The log reads as a terminal transcript: one mono label per entry, with the
	-- severity tag tinted and the message in plain subtext. A single label cannot
	-- do two colours, so each entry gets its own — bounded at 60 by the log
	-- itself, which keeps this cheap.
	local logList = Instance.new("Frame")
	logList.BackgroundTransparency = 1
	logList.Size = UDim2.new(1, 0, 0, 0)
	logList.AutomaticSize = Enum.AutomaticSize.Y
	logList.LayoutOrder = 2
	logList.Parent = logCard
	Widgets.List(logList, 2)

	local KIND_COLORS = {
		error = Theme.Color.Danger,
		warning = Theme.Color.Warning,
		success = Theme.Color.Success,
		info = Theme.Color.Info,
	}

	local function toHex(color: Color3): string
		local function byte(channel: number): string
			return string.format("%02X", math.floor(math.clamp(channel, 0, 1) * 255 + 0.5))
		end
		return `#{byte(color.R)}{byte(color.G)}{byte(color.B)}`
	end

	local function escapeRich(text: string): string
		text = text:gsub("&", "&amp;")
		text = text:gsub("<", "&lt;")
		text = text:gsub(">", "&gt;")
		text = text:gsub('"', "&quot;")
		return text
	end

	local function paintLog()
		for _, child in logList:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end

		local entries = context.GetLog()
		if #entries == 0 then
			Widgets.Label({
				parent = logList,
				text = "Nothing yet.",
				size = Theme.TextSize.Caption,
				font = Theme.Font.Mono,
				color = Theme.Color.Faint,
				order = 1,
			})
			return
		end
		-- Newest last, so the most recent line sits nearest the buttons below it.
		for index, entry in entries do
			local color = KIND_COLORS[entry.kind] or Theme.Color.Subtext
			local line = Instance.new("TextLabel")
			line.BackgroundTransparency = 1
			line.RichText = true
			line.Text = `<font color="{toHex(color)}">[{escapeRich(entry.kind)}]</font> {escapeRich(entry.text)}`
			line.Font = Theme.Font.Mono
			line.TextSize = Theme.TextSize.Caption
			line.TextColor3 = Theme.Color.Subtext
			line.TextXAlignment = Enum.TextXAlignment.Left
			line.TextYAlignment = Enum.TextYAlignment.Top
			line.TextWrapped = true
			line.Size = UDim2.new(1, 0, 0, 0)
			line.AutomaticSize = Enum.AutomaticSize.Y
			line.LayoutOrder = index
			line.Parent = logList
		end
	end

	paintLog()
	cleaner:Add(context.OnLog(paintLog))

	Widgets.Button({
		parent = logCard,
		text = "Clear log",
		variant = "ghost",
		cleaner = cleaner,
		order = 3,
		onClick = function()
			context.ClearLog()
			paintLog()
		end,
	})

	--------------------------------------------------------------------------------
	-- ABOUT
	--------------------------------------------------------------------------------
	local aboutCard = section("About", 6)

	local aboutRow = Widgets.Row(aboutCard, Theme.Space.Small, 2)
	-- Fixed pixels on purpose: a raster icon is sharpest at its own size, and
	-- resampling it to a panel fraction would only blur it.
	local aboutLogo = Instance.new("ImageLabel")
	aboutLogo.BackgroundTransparency = 1
	aboutLogo.Image = Constants.PLUGIN_ICON
	aboutLogo.Size = UDim2.fromOffset(32, 32)
	aboutLogo.LayoutOrder = 1
	aboutLogo.Parent = aboutRow

	local aboutStack = Instance.new("Frame")
	aboutStack.BackgroundTransparency = 1
	aboutStack.Size = UDim2.new(0, 0, 0, 0)
	aboutStack.AutomaticSize = Enum.AutomaticSize.XY
	aboutStack.LayoutOrder = 2
	aboutStack.Parent = aboutRow
	Widgets.List(aboutStack, 0)

	Widgets.Label({
		parent = aboutStack,
		text = `{Constants.PLUGIN_NAME} {Constants.PLUGIN_VERSION}`,
		size = Theme.TextSize.Body,
		font = Theme.Font.Bold,
		order = 1,
	})
	Widgets.Label({
		parent = aboutStack,
		text = "by the Wally registry, for Studio",
		size = Theme.TextSize.Caption,
		color = Theme.Color.Faint,
		order = 2,
	})
	Widgets.Label({
		parent = aboutCard,
		text = "Installs Wally packages straight into a place, in the same layout `wally install` and Rojo produce — so a place set up here stays compatible with a command-line workflow.",
		size = Theme.TextSize.Label,
		color = Theme.Color.Subtext,
		wrap = true,
		order = 3,
	})
	Widgets.Label({
		parent = aboutCard,
		text = "Packages are unpacked in Studio: the plugin contains its own ZIP reader and DEFLATE decompressor, so nothing outside Studio is needed.",
		size = Theme.TextSize.Caption,
		color = Theme.Color.Faint,
		wrap = true,
		order = 4,
	})

	Widgets.Button({
		parent = aboutCard,
		text = "Reset all settings",
		variant = "danger",
		cleaner = cleaner,
		order = 5,
		onClick = function()
			settings:Reset()
			context.Notify("Settings reset to defaults.", "success")
			context.Rebuild()
		end,
	})

	return {
		Refresh = function()
			refreshRealmDescription()
			paintLog()
		end,
	}
end

return SettingsPanel
