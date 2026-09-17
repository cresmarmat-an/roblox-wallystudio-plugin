--!nonstrict
--[[
======================================================================================
	SETTINGS  -  per-user plugin preferences
======================================================================================
	Backed by plugin:SetSetting, which is stored against the installed plugin rather
	than the place — so a preference set while working on one game applies to all of
	them, which is what a user expects from a tool's own settings.

	Values are validated on read rather than trusted. Plugin settings survive plugin
	updates, so a key whose meaning changed between versions can come back as the
	wrong type, and a nil default is indistinguishable from "never set".
======================================================================================
]]

local Constants = require(script.Parent.Parent.Config.Constants)

local Settings = {}
Settings.__index = Settings

local PREFIX = `{Constants.PLUGIN_ID}_`

-- Defaults double as the schema: a stored value is only used when its type matches
-- the default's.
local DEFAULTS = {
	-- Where a package goes when the user has not said otherwise.
	defaultRealm = "shared",
	-- Show transitive dependencies in the installed list, not just what was asked for
	-- by name. Off by default: the list is much shorter and matches what the user
	-- chose, and the count is shown either way.
	showTransitive = false,
	-- Check for updates when the panel opens. Off by default because it is a burst of
	-- registry requests on a window that may just be being glanced at.
	checkUpdatesOnOpen = false,
	-- Ask before installing when the resolution pulled in more than the packages
	-- named. Dependency counts in this ecosystem can be surprising.
	confirmDependencies = true,
	-- Name written into an exported manifest's [package] section.
	projectName = "",
	registryApi = Constants.DEFAULT_REGISTRY_API,
}

Settings.DEFAULTS = DEFAULTS

export type Settings = typeof(setmetatable({} :: { _plugin: Plugin, _cache: { [string]: any } }, Settings))

function Settings.New(plugin: Plugin): Settings
	return setmetatable({ _plugin = plugin, _cache = {} }, Settings)
end

function Settings.Get(self: Settings, key: string): any
	if self._cache[key] ~= nil then
		return self._cache[key]
	end

	local default = DEFAULTS[key]
	local ok, stored = pcall(function()
		return self._plugin:GetSetting(PREFIX .. key)
	end)

	local value = default
	if ok and stored ~= nil and type(stored) == type(default) then
		value = stored
	end

	-- A realm that no longer exists would send installs to a folder nothing reads.
	if key == "defaultRealm" and not Constants.REALMS[value] then
		value = DEFAULTS.defaultRealm
	end

	self._cache[key] = value
	return value
end

function Settings.Set(self: Settings, key: string, value: any)
	self._cache[key] = value
	pcall(function()
		self._plugin:SetSetting(PREFIX .. key, value)
	end)
end

function Settings.Reset(self: Settings)
	for key, default in DEFAULTS do
		self:set(key, default)
	end
end

return Settings
