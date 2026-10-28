--!strict
--[[
======================================================================================
	CONSTANTS  -  registry endpoints, install locations, file mapping rules
======================================================================================
	Everything here is either dictated by the Wally registry's API or by the on-disk
	layout `wally install` produces, which this plugin reproduces as instances. The
	layout in particular is not a design choice: matching it exactly is what lets a
	place installed from here stay interchangeable with one synced by Rojo from a
	real Packages folder.
======================================================================================
]]

local Constants = {}

-- Shown to the user: toolbar, widget title, the About section.
Constants.PLUGIN_NAME = "Wally Studio"

-- The same name with no space, for places a name has to be an identifier rather than
-- a label: the dock widget's saved-state key, the settings prefix, the HTTP
-- User-Agent. Changing this orphans a user's saved dock position and preferences, so
-- it is deliberately separate from the display name and should stay put.
Constants.PLUGIN_ID = "WallyStudio"
Constants.PLUGIN_VERSION = "1.0.0"

-- The plugin's logo, shown on the toolbar button and the About card.
Constants.PLUGIN_ICON = "rbxassetid://90326243977151"

--------------------------------------------------------------------------------------
-- REGISTRY
--------------------------------------------------------------------------------------
Constants.DEFAULT_REGISTRY_API = "https://api.wally.run"
Constants.DEFAULT_REGISTRY_INDEX = "https://github.com/UpliftGames/wally-index"

-- The package-contents endpoint answers 426 Upgrade Required to any request without
-- this header, so it is not optional. The value is the wally release whose API
-- behaviour this client matches, not the plugin's own version.
Constants.WALLY_VERSION_HEADER = "0.3.2"

Constants.ENDPOINT_SEARCH = "/v1/package-search"
Constants.ENDPOINT_METADATA = "/v1/package-metadata"
Constants.ENDPOINT_CONTENTS = "/v1/package-contents"

-- Registry responses are cached for the session. Package versions are immutable
-- once published, so only search results and the version list can go stale, and
-- neither is worth a round trip on every keystroke.
Constants.METADATA_CACHE_SECONDS = 300
Constants.SEARCH_CACHE_SECONDS = 120
Constants.SEARCH_DEBOUNCE_SECONDS = 0.35

--------------------------------------------------------------------------------------
-- INSTALL LAYOUT
--------------------------------------------------------------------------------------
-- Wally sorts packages into three trees by realm. The shared realm replicates to
-- clients; the server realm must not, which is why it cannot simply live alongside.
-- Dev dependencies are test-only and never belong in a shipped place.
Constants.REALMS = {
	shared = {
		id = "shared",
		label = "Shared",
		service = "ReplicatedStorage",
		folder = "Packages",
		description = "Replicated to clients. The default for most packages.",
	},
	server = {
		id = "server",
		label = "Server",
		service = "ServerStorage",
		folder = "ServerPackages",
		description = "Server-only. Never replicated.",
	},
	dev = {
		id = "dev",
		label = "Dev",
		service = "ServerStorage",
		folder = "DevPackages",
		description = "Test-only dependencies, kept out of shipped places.",
	},
}

Constants.REALM_ORDER = { "shared", "server", "dev" }

-- The folder every package's real contents live under, and the one name a package
-- alias can never take.
Constants.INDEX_FOLDER = "_Index"

-- Attributes stamped on installed instances. These are how the plugin recognises its
-- own work on a later session: the instance tree is the only state that survives, so
-- it has to carry enough to rebuild the full picture without a manifest.
Constants.ATTR_PACKAGE = "WallyPackage" -- "scope/name"
Constants.ATTR_VERSION = "WallyVersion" -- "1.2.3"
Constants.ATTR_REALM = "WallyRealm" -- "shared" | "server" | "dev"
Constants.ATTR_DIRECT = "WallyDirect" -- true when the user asked for it by name
Constants.ATTR_REQUIREMENT = "WallyRequirement" -- the range that selected it, e.g. "^1.4.4"
Constants.ATTR_INSTALLED_BY = "WallyInstalledBy"

--------------------------------------------------------------------------------------
-- FILE MAPPING
--------------------------------------------------------------------------------------
-- How archive entries become instances. These follow Rojo's conventions, because the
-- packages were authored to be synced by Rojo and their internal requires assume that
-- shape — a file named init.lua is the folder it sits in, not a child of it.
Constants.SCRIPT_EXTENSIONS = { ".luau", ".lua" }

-- Suffix before the extension selects the class. Order matters: ".server" has to be
-- tested before the bare case.
Constants.SCRIPT_KINDS = {
	{ suffix = ".server", className = "Script" },
	{ suffix = ".client", className = "LocalScript" },
	{ suffix = "", className = "ModuleScript" },
}

-- Plain text becomes a StringValue, as it would under Rojo.
Constants.TEXT_EXTENSIONS = { [".txt"] = true }

-- Files that describe the build rather than belonging to it. They are read for their
-- meaning where relevant and never turned into instances.
Constants.PROJECT_FILE = "default.project.json"
Constants.IGNORED_FILES = {
	["wally.toml"] = true,
	["wally.lock"] = true,
	["wally_bundle.toml"] = true,
	["rokit.toml"] = true,
	["aftman.toml"] = true,
	["foreman.toml"] = true,
	["selene.toml"] = true,
	["rotriever.toml"] = true,
	["testez.toml"] = true,
	["mkdocs.yml"] = true,
	[".gitignore"] = true,
	[".gitattributes"] = true,
}

-- Directories that are never part of any package's tree. Deliberately short: a
-- blocklist of plausible-sounding names like "docs" or "bin" would eventually drop a
-- real module from a package that happened to use the name for source. Bulk is
-- handled instead by mapping only the file types Rojo maps and then pruning the
-- folders that end up empty, which drops a documentation tree without ever having to
-- guess what a folder is for.
Constants.IGNORED_DIRECTORIES = {
	[".git"] = true,
	[".github"] = true,
	["node_modules"] = true,
}

-- File types Rojo maps to instances but this plugin cannot build. They are counted
-- and reported after an install rather than passed over in silence, so a package that
-- genuinely needs one does not look like it installed cleanly.
Constants.UNSUPPORTED_EXTENSIONS = {
	[".rbxm"] = "binary model",
	[".rbxmx"] = "model",
	[".csv"] = "localization table",
	[".json"] = "JSON module",
}

--------------------------------------------------------------------------------------
-- LIMITS
--------------------------------------------------------------------------------------
-- Guards against a dependency cycle in published metadata, which the registry does
-- not itself prevent.
Constants.MAX_RESOLVE_DEPTH = 32
Constants.MAX_SEARCH_RESULTS = 50

return Constants
