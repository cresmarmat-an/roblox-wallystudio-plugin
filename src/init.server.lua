--!nonstrict
--[[
======================================================================================
	STUDIOWALLY  -  plugin entry point
======================================================================================
	A Wally package manager that runs inside Studio. No command line, no Rojo, no
	toolchain: search the registry, pick a package, and it appears in
	ReplicatedStorage.Packages in exactly the layout `wally install` and Rojo would
	have produced.

	Instance tree (built by Rojo from /src):

	  WallyStudio (Script)                   <- this file
	    Modules/
	      Config/   Constants, Theme
	      Core/     Inflate, Zip, Toml, Semver, Cleaner
	      Services/ Registry, Resolver, Installer, Project, Settings
	      UI/
	        Components/ Widgets, Toast
	        Templates/  BrowsePanel, InstalledPanel, ManifestPanel, SettingsPanel

	One toolbar button, one dock widget, four tabs inside it. Every tab is built up
	front and toggled by visibility rather than being rebuilt on each switch, so
	switching back to Browse does not lose the search results that were on it.

	TWO CLEANERS, on purpose:
	  * pluginCleaner lives as long as the plugin — the toolbar, the widget, and the
	    Studio theme subscription.
	  * uiCleaner lives as long as the CURRENT UI. A GuiObject keeps whatever colours
	    it was built from, so following a Studio theme switch means rebuilding rather
	    than repainting, and everything the panels connected has to go with it. The
	    theme subscription must NOT, which is why it is on the other one.

	This file only bootstraps: widget, tabs, the shared context, and cleanup. Every
	feature lives in the modules above.
======================================================================================
]]

local Modules = script:WaitForChild("Modules")

local Constants = require(Modules.Config.Constants)
local Theme = require(Modules.Config.Theme)
local Cleaner = require(Modules.Core.Cleaner)
local Registry = require(Modules.Services.Registry)
local Project = require(Modules.Services.Project)
local SettingsStore = require(Modules.Services.Settings)
local Widgets = require(Modules.UI.Components.Widgets)
local Toast = require(Modules.UI.Components.Toast)
local BrowsePanel = require(Modules.UI.Templates.BrowsePanel)
local InstalledPanel = require(Modules.UI.Templates.InstalledPanel)
local ManifestPanel = require(Modules.UI.Templates.ManifestPanel)
local SettingsPanel = require(Modules.UI.Templates.SettingsPanel)

--------------------------------------------------------------------------------------
-- TOOLBAR + WIDGET
--------------------------------------------------------------------------------------
local toolbar = plugin:CreateToolbar(Constants.PLUGIN_NAME)
local button = toolbar:CreateButton(Constants.PLUGIN_NAME, "Browse and install Wally packages", Constants.PLUGIN_ICON)

local widget = plugin:CreateDockWidgetPluginGui(
	`{Constants.PLUGIN_ID}Widget`,
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 400, 620, 320, 420)
)
widget.Title = Constants.PLUGIN_NAME
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

--------------------------------------------------------------------------------------
-- SHARED STATE
--------------------------------------------------------------------------------------
local pluginCleaner = Cleaner.New()
local uiCleaner = pluginCleaner:Extend()

local settings = SettingsStore.New(plugin)
local registry = Registry.New()
registry.baseUrl = settings:Get("registryApi")

-- What is installed, refreshed from the instance tree rather than remembered. Panels
-- read it through the context so a single scan serves all of them.
local installedByRealm = Project.ScanAll()

-- The activity log. Bounded: a long session installing many packages would otherwise
-- grow it without limit, and only the recent end is ever useful.
local LOG_LIMIT = 60
local logEntries: { { text: string, kind: string } } = {}
local logListeners: { () -> () } = {}

-- Toasts are parented into the UI root, so they die with every rebuild. Services hold
-- this stable wrapper rather than the mount's own closure.
local notifyImpl = function(_text: string, _kind: string?) end

local activeTab = "browse"
local panels = {}
local setBusy
local buildUI

local TABS = {
	{ id = "browse", label = "BROWSE" },
	{ id = "installed", label = "INSTALLED" },
	{ id = "manifest", label = "MANIFEST" },
	{ id = "settings", label = "SETTINGS" },
}

--------------------------------------------------------------------------------------
-- CONTEXT
--------------------------------------------------------------------------------------
local function notify(text: string, kind: string?)
	notifyImpl(text, kind)
end

local function log(text: string, kind: string?)
	table.insert(logEntries, { text = text, kind = kind or "info" })
	while #logEntries > LOG_LIMIT do
		table.remove(logEntries, 1)
	end
	for _, listener in logListeners do
		pcall(listener)
	end
end

--[[
	Run work that yields — anything touching the network — without letting a failure
	take the panel down with it.

	Every install and search goes through here. A plugin that throws inside a button
	handler leaves its UI in whatever half-state the error interrupted, so the busy
	indicator is cleared and the reason is surfaced rather than left in the output
	window where nobody is looking.
]]
local function runTask(body: () -> ())
	task.spawn(function()
		local ok, problem = pcall(body)
		if not ok then
			setBusy(false)
			log(tostring(problem), "error")
			notify(`Something went wrong: {problem}`, "error")
		end
	end)
end

local context
context = {
	Plugin = plugin,
	Registry = registry,
	Settings = settings,
	Notify = notify,
	Log = log,
	RunTask = runTask,

	GetLog = function()
		return logEntries
	end,
	ClearLog = function()
		table.clear(logEntries)
	end,
	OnLog = function(listener: () -> ())
		table.insert(logListeners, listener)
		return function()
			local index = table.find(logListeners, listener)
			if index then
				table.remove(logListeners, index)
			end
		end
	end,

	GetInstalled = function()
		return installedByRealm
	end,
	SetInstalled = function(realm: string, installed)
		installedByRealm[realm] = installed
	end,
	RefreshInstalled = function()
		installedByRealm = Project.ScanAll()
		if panels.installed then
			panels.installed.Refresh()
		end
		if panels.manifest then
			panels.manifest.Refresh()
		end
	end,

	SetBusy = function(...)
		setBusy(...)
	end,
	Rebuild = function()
		-- Deferred so a rebuild is never tearing down the very button whose handler
		-- is still on the stack.
		task.defer(function()
			buildUI(activeTab)
		end)
	end,
}

--[[
	Render a registry failure as something with a next step in it.

	The HTTP case is the one that matters: it is the most common first-run failure,
	it is not the user's mistake in any meaningful sense, and a plugin is allowed to
	fix it where a game script is not. So it gets a button instead of instructions.
]]
function context.ShowRegistryError(parent: Instance, result, order: number)
	local card = Widgets.Card({
		parent = parent,
		order = order,
		gap = Theme.Space.Small,
		color = Theme.Color.SurfaceAlt,
		accent = Theme.Color.Danger,
	})

	Widgets.Label({
		parent = card,
		text = result.kind == "http_disabled" and "HTTP requests are turned off" or "Could not reach the registry",
		size = Theme.TextSize.Heading,
		font = Theme.Font.Bold,
		color = Theme.Color.Danger,
		wrap = true,
		order = 1,
	})

	Widgets.Label({
		parent = card,
		text = result.message or "Unknown error.",
		size = Theme.TextSize.Label,
		color = Theme.Color.Subtext,
		wrap = true,
		order = 2,
	})

	if result.kind == "http_disabled" then
		Widgets.Label({
			parent = card,
			text = "Studio blocks HTTP for this place until it is allowed. This turns on HttpService.HttpEnabled, which is a change to the place itself.",
			size = Theme.TextSize.Caption,
			color = Theme.Color.Faint,
			wrap = true,
			order = 3,
		})
		Widgets.Button({
			parent = card,
			text = "Turn on HTTP requests",
			variant = "primary",
			cleaner = uiCleaner,
			order = 4,
			width = UDim.new(1, 0),
			height = Theme.Height.Tall,
			onClick = function()
				local outcome = registry:EnableHttp()
				if outcome.ok then
					notify("HTTP requests are on. Try that again.", "success")
					card:Destroy()
				else
					notify(outcome.message or "Could not turn on HTTP requests.", "error")
				end
			end,
		})
	end

	return card
end

--------------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------------
function buildUI(startTab: string)
	uiCleaner:Clean()
	for _, child in widget:GetChildren() do
		child:Destroy()
	end
	panels = {}

	-- Opaque on purpose: Studio's own dock chrome would show through a transparent
	-- root instead of our background.
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Theme.Color.Background
	root.BorderSizePixel = 0
	root.Parent = widget

	local column = Instance.new("Frame")
	column.BackgroundTransparency = 1
	column.Size = UDim2.fromScale(1, 1)
	column.Parent = root
	Widgets.Pad(column, Theme.Space.Small)
	Widgets.List(column, Theme.Space.Small)

	------------------------------------------------------------------------------
	-- TAB BAR
	------------------------------------------------------------------------------
	local selectTab
	local _, setTab = Widgets.SegmentedControl({
		parent = column,
		options = TABS,
		selected = startTab,
		cleaner = uiCleaner,
		order = 1,
		onSelect = function(id)
			selectTab(id)
		end,
	})

	Widgets.Divider(column, 2)

	------------------------------------------------------------------------------
	-- BUSY BAR
	------------------------------------------------------------------------------
	local busyHolder = Instance.new("Frame")
	busyHolder.BackgroundTransparency = 1
	busyHolder.Size = UDim2.new(1, 0, 0, 0)
	busyHolder.AutomaticSize = Enum.AutomaticSize.Y
	busyHolder.Visible = false
	busyHolder.LayoutOrder = 3
	busyHolder.Parent = column

	-- A tinted strip with a severity rail, not a bare bar: at a glance it reads as
	-- "working" the way a toast reads as "done", and the message sits beside the
	-- same Info colour it would carry in the log.
	local busyCard = Widgets.Card({
		parent = busyHolder,
		order = 1,
		gap = Theme.Space.ExtraSmall,
		color = Theme.Mix(Theme.Color.Surface, Theme.Color.Info, 0.10),
	})
	local busyCaption = Widgets.Label({
		parent = busyCard,
		text = "Working…",
		size = Theme.TextSize.Label,
		font = Theme.Font.Medium,
		color = Theme.Color.Info,
		truncate = true,
		order = 1,
	})

	local _, setProgress = Widgets.ProgressBar(busyCard, 2)

	function setBusy(active: boolean, message: string?, alpha: number?)
		busyHolder.Visible = active
		if active then
			-- With no fraction to report — resolution, where the total is not known
			-- until it finishes — the bar sits at a third rather than empty, so it
			-- reads as working rather than stalled.
			busyCaption.Text = message or "Working…"
			setProgress(alpha or 0.33)
		end
	end

	------------------------------------------------------------------------------
	-- PANELS
	------------------------------------------------------------------------------
	local content = Instance.new("Frame")
	content.BackgroundTransparency = 1
	content.Size = UDim2.new(1, 0, 1, 0)
	content.LayoutOrder = 4
	content.Parent = column

	local contentFlex = Instance.new("UIFlexItem")
	contentFlex.FlexMode = Enum.UIFlexMode.Fill
	contentFlex.Parent = content

	local frames = {}
	for _, tab in TABS do
		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.fromScale(1, 1)
		frame.Visible = false
		frame.Name = tab.id
		frame.Parent = content
		frames[tab.id] = frame
	end

	-- Anything that has to escape a scrolling list lives here: dropdown menus opened
	-- inside a scroller would otherwise be clipped at the edge of the visible area.
	-- Sits above the panels and below the toasts, and passes clicks through except
	-- where something is actually open.
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.BackgroundTransparency = 1
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = 50
	overlay.Parent = root
	context.Overlay = overlay

	notifyImpl = Toast.Mount(root)

	local function panelContext(frame: Frame)
		local scoped = table.clone(context)
		scoped.Root = frame
		scoped.Cleaner = uiCleaner
		scoped.Overlay = overlay
		return scoped
	end

	panels.browse = BrowsePanel.Mount(panelContext(frames.browse))
	panels.installed = InstalledPanel.Mount(panelContext(frames.installed))
	panels.manifest = ManifestPanel.Mount(panelContext(frames.manifest))
	panels.settings = SettingsPanel.Mount(panelContext(frames.settings))

	------------------------------------------------------------------------------
	-- TAB SWITCHING
	------------------------------------------------------------------------------
	function selectTab(id: string)
		activeTab = id
		for _, tab in TABS do
			frames[tab.id].Visible = tab.id == id
		end
		-- The installed and manifest tabs read the place, which can have changed
		-- while another tab was in front.
		if id == "installed" then
			panels.installed.Refresh()
		elseif id == "manifest" then
			panels.manifest.Refresh()
		elseif id == "settings" then
			panels.settings.Refresh()
		end
	end

	setTab(startTab)
	selectTab(startTab)
end

--------------------------------------------------------------------------------------
-- THEME
--------------------------------------------------------------------------------------
pluginCleaner:Add(Theme.FollowStudio())
pluginCleaner:Add(Theme.OnChanged(function()
	-- Colours are baked into GuiObjects at construction, so following the Studio
	-- theme means rebuilding rather than repainting.
	if widget.Enabled then
		buildUI(activeTab)
	end
end))

buildUI(activeTab)

--------------------------------------------------------------------------------------
-- TOOLBAR TOGGLE
--------------------------------------------------------------------------------------
pluginCleaner:Connect(button.Click, function()
	widget.Enabled = not widget.Enabled
end)

pluginCleaner:Connect(widget:GetPropertyChangedSignal("Enabled"), function()
	button:SetActive(widget.Enabled)
	if not widget.Enabled then
		return
	end

	-- The place can change while the widget is closed.
	context.RefreshInstalled()

	if settings:Get("checkUpdatesOnOpen") and panels.installed then
		runTask(function()
			panels.installed.CheckUpdates()
		end)
	end
end)

button:SetActive(widget.Enabled)

--------------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------------
pluginCleaner:Connect(plugin.Unloading, function()
	pluginCleaner:Destroy()
end)
