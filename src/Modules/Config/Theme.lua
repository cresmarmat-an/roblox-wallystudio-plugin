--!nonstrict
--[[
======================================================================================
	THEME  -  palette, spacing and type scale
======================================================================================
	Studio plugins that invent their own colours look pasted on, and plugins that only
	read Studio's theme colours look like a settings dialog. This sits between:
	surfaces and text follow Studio's light/dark setting so the panel belongs in the
	window, while state colours and the accent are ours and stay constant across both
	themes so "outdated" means the same thing wherever you are.

	Colour carries meaning in a package manager, and the meanings must not collide:

	  Accent   orange   an action you can take (a deeper orange while hovered)
	  Success  green    installed and current
	  Warning  gold     an update is available
	  Danger   red      a failure, or something destructive

	That is why the warning leans gold rather than orange — orange is spoken for
	by the accent, and an accent that shares a colour with a state makes every
	button look like a warning.

	WHY COLOURS LIVE UNDER Theme.Color
	They used to be flattened onto Theme itself, which put the palette and the type
	scale in one namespace — and the palette had a key named `text` while the type
	scale was a table named `text`. Applying a palette overwrote the scale with a
	Color3, so every `Theme.text.Body` read blew up with "Body is not a valid member
	of Color3", and the whole panel failed to build on the first control it tried to
	make.

	Nesting the palette one level down is what actually fixes that: `Apply` writes
	into Theme.Color, so a palette key can never land on a scale table no matter what
	it is called. A guard test would only have caught the one collision that existed;
	this makes the entire class of them impossible.

	Tables are mutated in place rather than replaced, so a module can capture
	`Theme.Color` once at require time and still see a theme switch. Colours already
	baked into existing GuiObjects do not update themselves, so switching still
	rebuilds the UI — `Theme.OnChanged` is what tells it to.
======================================================================================
]]

local Theme = {}

--------------------------------------------------------------------------------------
-- SCALES
--------------------------------------------------------------------------------------
-- One spacing scale, used everywhere. Arbitrary per-element padding is what makes a
-- panel look untidy even when every individual piece is fine.
Theme.Space = {
	ExtraSmall = 4,
	Small = 6,
	Medium = 10,
	Large = 14,
	ExtraLarge = 20,
}

Theme.Radius = {
	Small = 4,
	Medium = 6,
	Large = 10,
	Pill = 999,
}

Theme.TextSize = {
	-- Display is for hero numerals only (counts, stats) — never for prose, which
	-- tops out at Title. One step larger than Title keeps the docked panel quiet.
	Display = 18,
	Title = 15,
	Heading = 13,
	Body = 12,
	Label = 11,
	Caption = 10,
}

Theme.Font = {
	Regular = Enum.Font.Gotham,
	Medium = Enum.Font.GothamMedium,
	Bold = Enum.Font.GothamBold,
	Mono = Enum.Font.RobotoMono,
}

-- Control heights. Kept here so a list, a button and an input line up without each
-- panel picking its own number.
Theme.Height = {
	Control = 28,
	-- Tall is for the moments that deserve weight: the search field and the one
	-- primary action per card. Everything else stays at Control.
	Tall = 34,
	Tab = 30,
}

--------------------------------------------------------------------------------------
-- MOTION
--------------------------------------------------------------------------------------
-- Seconds, not styles: every tween in the UI takes its duration from here so motion
-- stays in one family. Hover answers fast, entrances settle at Base, and nothing
-- interactive ever crosses Slow — a 180ms dropdown feels responsive, a 400ms one
-- feels broken, and the number is the difference.
Theme.Motion = {
	Instant = 0.08,
	Fast = 0.12,
	Base = 0.18,
	Slow = 0.30,
}

--------------------------------------------------------------------------------------
-- PALETTES
--------------------------------------------------------------------------------------
-- State colours are chosen to hold their meaning against both backgrounds, which is
-- why they are not simply the same hex in each palette: the light theme needs deeper
-- variants to keep contrast against white.
local DARK_PALETTE = {
	Background = Color3.fromRGB(30, 32, 38),
	Surface = Color3.fromRGB(38, 40, 48),
	SurfaceAlt = Color3.fromRGB(45, 48, 57),
	Elevated = Color3.fromRGB(52, 55, 66),
	Border = Color3.fromRGB(58, 62, 74),
	BorderStrong = Color3.fromRGB(78, 83, 98),

	Text = Color3.fromRGB(233, 236, 244),
	Subtext = Color3.fromRGB(155, 162, 180),
	Faint = Color3.fromRGB(112, 119, 136),

	Accent = Color3.fromRGB(232, 118, 43),
	AccentHover = Color3.fromRGB(198, 90, 24),

	Success = Color3.fromRGB(63, 185, 80),
	Warning = Color3.fromRGB(217, 165, 20),
	Danger = Color3.fromRGB(248, 81, 73),
	Info = Color3.fromRGB(88, 166, 255),
}

local LIGHT_PALETTE = {
	Background = Color3.fromRGB(245, 246, 249),
	Surface = Color3.fromRGB(255, 255, 255),
	SurfaceAlt = Color3.fromRGB(239, 241, 245),
	Elevated = Color3.fromRGB(255, 255, 255),
	Border = Color3.fromRGB(219, 222, 229),
	BorderStrong = Color3.fromRGB(190, 195, 205),

	Text = Color3.fromRGB(28, 31, 38),
	Subtext = Color3.fromRGB(96, 103, 118),
	Faint = Color3.fromRGB(140, 147, 162),

	Accent = Color3.fromRGB(194, 90, 29),
	AccentHover = Color3.fromRGB(150, 66, 18),

	Success = Color3.fromRGB(31, 136, 61),
	Warning = Color3.fromRGB(154, 103, 0),
	Danger = Color3.fromRGB(207, 34, 46),
	Info = Color3.fromRGB(9, 105, 218),
}

-- Every colour the UI is allowed to use. Populated by ApplyPalette below; declared
-- here so the table identity never changes and callers can hold a reference to it.
Theme.Color = {}

Theme.IsDark = true

local changeListeners: { (isDark: boolean) -> () } = {}

local function ApplyPalette(palette: { [string]: Color3 })
	for name, color in palette do
		Theme.Color[name] = color
	end
end

ApplyPalette(DARK_PALETTE)

--[[
	Switch palettes and notify listeners. Returns true when the theme actually
	changed, so callers can skip a rebuild that would only recreate identical UI.
]]
function Theme.SetDark(isDark: boolean): boolean
	if isDark == Theme.IsDark then
		return false
	end
	Theme.IsDark = isDark
	ApplyPalette(isDark and DARK_PALETTE or LIGHT_PALETTE)

	for _, listener in changeListeners do
		local ok, problem = pcall(listener, isDark)
		if not ok then
			warn(`[Wally Studio] theme listener failed: {problem}`)
		end
	end
	return true
end

--[[
	Subscribe to theme switches. Returns a function that unsubscribes.
]]
function Theme.OnChanged(listener: (isDark: boolean) -> ()): () -> ()
	table.insert(changeListeners, listener)
	return function()
		local index = table.find(changeListeners, listener)
		if index then
			table.remove(changeListeners, index)
		end
	end
end

--[[
	Follow Studio's own light/dark setting, and keep following it. Returns a function
	that stops following.

	Studio exposes more than two themes through the API surface, but in practice the
	name is "Dark" or "Light"; anything unrecognised is treated as dark, which is the
	overwhelmingly common case and the safer guess for a docked panel.
]]
function Theme.FollowStudio(): () -> ()
	local studio = settings().Studio

	local function Sync()
		local ok, studioTheme = pcall(function()
			return studio.Theme
		end)
		if ok and studioTheme then
			Theme.SetDark(studioTheme.Name ~= "Light")
		end
	end

	Sync()
	local connection = studio.ThemeChanged:Connect(Sync)
	return function()
		connection:Disconnect()
	end
end

--------------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------------
--[[
	Black or white, whichever stays readable on `background`.

	Uses perceived luminance rather than a plain average: the eye is far more
	sensitive to green than to blue, so averaging the channels calls a saturated blue
	"light" and puts black text on it.
]]
function Theme.ReadableOn(background: Color3): Color3
	local luminance = 0.299 * background.R + 0.587 * background.G + 0.114 * background.B
	return luminance > 0.6 and Color3.fromRGB(24, 26, 31) or Color3.fromRGB(255, 255, 255)
end

--[[
	Blend two colours. Used for hover and pressed states so they stay a fixed step
	from whatever the base colour is, in either palette.
]]
function Theme.Mix(from: Color3, to: Color3, alpha: number): Color3
	return from:Lerp(to, alpha)
end

--[[
	The colour that means this install state. Kept in one place so a badge, a row
	highlight and a summary line can never disagree about what "outdated" looks like.

	An unrecognised status falls back to Subtext rather than raising: a status string
	is only ever used to pick a colour, and a wrong colour is a far better outcome
	than a panel that fails to draw.
]]
function Theme.StatusColor(status: string): Color3
	if status == "current" then
		return Theme.Color.Success
	elseif status == "outdated" then
		return Theme.Color.Warning
	elseif status == "major" then
		-- Current within its range, but a new major exists. Informational, not a
		-- warning: there is nothing here the user has to act on.
		return Theme.Color.Info
	elseif status == "failed" or status == "missing" then
		return Theme.Color.Danger
	elseif status == "installing" then
		return Theme.Color.Info
	end
	return Theme.Color.Subtext
end

return Theme
