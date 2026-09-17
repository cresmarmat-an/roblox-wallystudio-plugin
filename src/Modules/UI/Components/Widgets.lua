--!nonstrict
--[[
======================================================================================
	WIDGETS  -  the primitives every panel is built from
======================================================================================
	One place for the small decisions that make a panel look considered rather than
	assembled: how far a hover state moves, how thick a border is, how much air sits
	inside a card. Made once here, they are consistent by construction; made at each
	call site, they drift, and the drift is exactly what reads as "unfinished".

	Two conventions run through all of it:

	* Layout is done with UIListLayout and AutomaticSize rather than computed
	  offsets. A package description wraps to a different number of lines for every
	  package, and a card that measures itself is the only kind that stays correct.

	* Colour comes from Theme at build time. A GuiObject keeps the colours it was
	  built with, so switching themes rebuilds the UI rather than repainting it —
	  which is why every builder here takes its colours from Theme directly instead
	  of caching them in a local.
======================================================================================
]]

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Parent.Parent.Config.Theme)

local Widgets = {}

-- Motion comes from Theme so every control answers in the same voice: hovers are
-- Fast, entrances settle at Base, and nothing pressable moves slower than that.
-- ease-out everywhere interactivity is concerned — ease-in starts slow at the exact
-- moment the user is watching most closely, which reads as lag.
local HOVER_TWEEN = TweenInfo.new(Theme.Motion.Fast, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN = TweenInfo.new(Theme.Motion.Instant, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--------------------------------------------------------------------------------------
-- PRIMITIVES
--------------------------------------------------------------------------------------
function Widgets.Corner(instance: Instance, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or Theme.Radius.Medium)
	corner.Parent = instance
	return corner
end

function Widgets.Stroke(instance: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Theme.Color.Border
	stroke.Thickness = thickness or 1
	stroke.Transparency = transparency or 0
	-- Border, not outline: it should sit inside the rounded corner rather than
	-- tracing a square around it.
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = instance
	return stroke
end

function Widgets.Pad(instance: Instance, amount: number | { top: number?, bottom: number?, left: number?, right: number? }): UIPadding
	local padding = Instance.new("UIPadding")
	if type(amount) == "number" then
		padding.PaddingTop = UDim.new(0, amount)
		padding.PaddingBottom = UDim.new(0, amount)
		padding.PaddingLeft = UDim.new(0, amount)
		padding.PaddingRight = UDim.new(0, amount)
	else
		padding.PaddingTop = UDim.new(0, amount.top or 0)
		padding.PaddingBottom = UDim.new(0, amount.bottom or 0)
		padding.PaddingLeft = UDim.new(0, amount.left or 0)
		padding.PaddingRight = UDim.new(0, amount.right or 0)
	end
	padding.Parent = instance
	return padding
end

function Widgets.List(instance: Instance, gap: number?, horizontal: boolean?, align: Enum.HorizontalAlignment?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, gap or Theme.Space.Small)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = align or Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.Parent = instance
	return layout
end

--------------------------------------------------------------------------------------
-- TEXT
--------------------------------------------------------------------------------------
export type LabelProps = {
	parent: Instance?,
	text: string,
	size: number?,
	color: Color3?,
	font: Enum.Font?,
	wrap: boolean?,
	align: Enum.TextXAlignment?,
	order: number?,
	width: UDim?,
	truncate: boolean?,
}

function Widgets.Label(props: LabelProps): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = props.text
	label.TextSize = props.size or Theme.TextSize.Body
	label.TextColor3 = props.color or Theme.Color.Text
	label.Font = props.font or Theme.Font.Regular
	label.TextXAlignment = props.align or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = props.wrap or false
	label.RichText = false
	label.LayoutOrder = props.order or 1
	label.Size = UDim2.new(props.width or UDim.new(1, 0), UDim.new(0, 0))
	-- Height follows the text, which is the only way wrapped copy lays out correctly
	-- inside a list.
	label.AutomaticSize = Enum.AutomaticSize.Y

	if props.truncate then
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.TextWrapped = false
		label.AutomaticSize = Enum.AutomaticSize.None
		label.Size = UDim2.new(props.width or UDim.new(1, 0), UDim.new(0, (props.size or Theme.TextSize.Body) + 6))
	end

	label.Parent = props.parent
	return label
end

--------------------------------------------------------------------------------------
-- BUTTONS
--------------------------------------------------------------------------------------
export type ButtonProps = {
	parent: Instance?,
	text: string,
	variant: string?, -- "primary" | "secondary" | "ghost" | "danger" | "dangerGhost"
	onClick: (() -> ())?,
	order: number?,
	width: UDim?,
	height: number?,
	enabled: boolean?,
	cleaner: any?,
	tooltip: string?,
}

-- Each variant is a triple of (fill, text, border). Keeping them together makes it
-- obvious that a ghost button has no fill of its own and a danger button is the only
-- one that is red before you touch it. dangerGhost is the quiet version of danger:
-- plain red text for row-level destructive actions (Remove), where a full red
-- outline on every row would paint the whole list alarming.
local function variantColors(variant: string)
	if variant == "primary" then
		return Theme.Color.Accent, Theme.ReadableOn(Theme.Color.Accent), nil
	elseif variant == "danger" then
		return Theme.Color.SurfaceAlt, Theme.Color.Danger, Theme.Color.Danger
	elseif variant == "dangerGhost" then
		return nil, Theme.Color.Danger, nil
	elseif variant == "ghost" then
		return nil, Theme.Color.Subtext, nil
	end
	return Theme.Color.SurfaceAlt, Theme.Color.Text, Theme.Color.Border
end

function Widgets.Button(props: ButtonProps): TextButton
	local variant = props.variant or "secondary"
	local fill, textColor, borderColor = variantColors(variant)
	local enabled = props.enabled ~= false

	local button = Instance.new("TextButton")
	button.AutoButtonColor = false
	button.Text = props.text
	button.Font = variant == "primary" and Theme.Font.Bold or Theme.Font.Medium
	button.TextSize = Theme.TextSize.Label
	button.TextColor3 = textColor
	button.BackgroundColor3 = fill or Theme.Color.Surface
	button.BackgroundTransparency = fill and 0 or 1
	button.BorderSizePixel = 0
	button.LayoutOrder = props.order or 1
	button.Size = UDim2.new(props.width or UDim.new(0, 0), UDim.new(0, props.height or Theme.Height.Control))
	button.AutomaticSize = props.width and Enum.AutomaticSize.None or Enum.AutomaticSize.X
	button.Active = enabled
	button.AutoLocalize = false

	Widgets.Corner(button, Theme.Radius.Medium)
	-- Even on all four sides: symmetric padding keeps the label optically centered
	-- instead of drifting toward the thinner edge.
	Widgets.Pad(button, Theme.Space.Small)
	if borderColor then
		Widgets.Stroke(button, borderColor)
	end

	if not enabled then
		button.TextColor3 = Theme.Color.Faint
		button.BackgroundTransparency = fill and 0.6 or 1
	end

	-- Hover is a small, uniform step toward the accent for anything interactive, so
	-- every control in the panel responds the same way to the pointer. Text-only
	-- variants answer through their text instead of their fill.
	local baseFill = button.BackgroundColor3
	local baseTransparency = button.BackgroundTransparency
	local hoverFill = variant == "primary" and Theme.Color.AccentHover
		or (variant == "danger" and Theme.Mix(Theme.Color.SurfaceAlt, Theme.Color.Danger, 0.15))
		or (variant == "dangerGhost" and Theme.Mix(Theme.Color.Surface, Theme.Color.Danger, 0.16))
		or Theme.Mix(baseFill, Theme.Color.Accent, 0.12)
	local hoverTransparency = variant == "dangerGhost" and 0 or baseTransparency
	local hoverText = variant == "ghost" and Theme.Color.Text or textColor

	-- Pressed is the same fill one step darker: the click answers through color,
	-- never through motion. A scale pulse on the highest-frequency interaction in
	-- the panel is decoration pretending to be feedback.
	local pressedFill = Theme.Mix(variant == "dangerGhost" and hoverFill or baseFill, Color3.new(0, 0, 0), 0.15)
	local pressedTransparency = variant == "ghost" and 0.55 or hoverTransparency

	local over = false
	local connections = {}
	if enabled then
		table.insert(
			connections,
			button.MouseEnter:Connect(function()
				over = true
				if variant == "ghost" then
					TweenService:Create(button, HOVER_TWEEN, { TextColor3 = hoverText }):Play()
				else
					TweenService:Create(button, HOVER_TWEEN, {
						BackgroundColor3 = hoverFill,
						BackgroundTransparency = hoverTransparency,
						TextColor3 = hoverText,
					}):Play()
				end
			end)
		)
		table.insert(
			connections,
			button.MouseLeave:Connect(function()
				over = false
				if variant == "ghost" then
					TweenService:Create(button, HOVER_TWEEN, {
						BackgroundColor3 = baseFill,
						BackgroundTransparency = baseTransparency,
						TextColor3 = textColor,
					}):Play()
				else
					TweenService:Create(button, HOVER_TWEEN, {
						BackgroundColor3 = baseFill,
						BackgroundTransparency = baseTransparency,
						TextColor3 = textColor,
					}):Play()
				end
			end)
		)
		-- Down darkens; up settles back to wherever the pointer is. Press tweens
		-- only the fill, never the text — hover owns the text, so the two can
		-- never fight over it mid-click.
		table.insert(
			connections,
			button.MouseButton1Down:Connect(function()
				TweenService:Create(button, PRESS_TWEEN, {
					BackgroundColor3 = pressedFill,
					BackgroundTransparency = pressedTransparency,
				}):Play()
			end)
		)
		table.insert(
			connections,
			button.MouseButton1Up:Connect(function()
				TweenService:Create(button, HOVER_TWEEN, {
					BackgroundColor3 = over and hoverFill or baseFill,
					BackgroundTransparency = over and hoverTransparency or baseTransparency,
				}):Play()
			end)
		)
		if props.onClick then
			table.insert(connections, button.Activated:Connect(props.onClick))
		end
	end

	if props.cleaner then
		for _, connection in connections do
			props.cleaner:Add(connection)
		end
	end

	button.Parent = props.parent
	return button
end

--------------------------------------------------------------------------------------
-- INPUT
--------------------------------------------------------------------------------------
export type InputProps = {
	parent: Instance?,
	placeholder: string?,
	text: string?,
	order: number?,
	height: number?,
	multiline: boolean?,
	cleaner: any?,
	onChanged: ((text: string) -> ())?,
	onSubmit: ((text: string) -> ())?,
}

function Widgets.Input(props: InputProps): TextBox
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Theme.Color.SurfaceAlt
	frame.BorderSizePixel = 0
	frame.LayoutOrder = props.order or 1
	frame.Size = UDim2.new(1, 0, 0, props.height or Theme.Height.Control)
	frame.Parent = props.parent
	Widgets.Corner(frame, Theme.Radius.Medium)
	local stroke = Widgets.Stroke(frame, Theme.Color.Border)
	Widgets.Pad(frame, Theme.Space.Small)

	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.Size = UDim2.fromScale(1, 1)
	box.Text = props.text or ""
	box.PlaceholderText = props.placeholder or ""
	box.PlaceholderColor3 = Theme.Color.Faint
	box.TextColor3 = Theme.Color.Text
	box.Font = props.multiline and Theme.Font.Mono or Theme.Font.Regular
	box.TextSize = Theme.TextSize.Body
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = props.multiline and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
	box.ClearTextOnFocus = false
	box.MultiLine = props.multiline or false
	box.TextWrapped = props.multiline or false
	box.Parent = frame

	-- The border is the focus indicator. Without one, a focused field in a docked
	-- panel is indistinguishable from an unfocused one. The fill lifts at the same
	-- time, so focus reads in peripheral vision too.
	local connections = {
		box.Focused:Connect(function()
			TweenService:Create(stroke, HOVER_TWEEN, { Color = Theme.Color.Accent }):Play()
			TweenService:Create(frame, HOVER_TWEEN, { BackgroundColor3 = Theme.Color.Surface }):Play()
		end),
		box.FocusLost:Connect(function(enterPressed)
			TweenService:Create(stroke, HOVER_TWEEN, { Color = Theme.Color.Border }):Play()
			TweenService:Create(frame, HOVER_TWEEN, { BackgroundColor3 = Theme.Color.SurfaceAlt }):Play()
			if enterPressed and props.onSubmit then
				props.onSubmit(box.Text)
			end
		end),
	}
	if props.onChanged then
		table.insert(
			connections,
			box:GetPropertyChangedSignal("Text"):Connect(function()
				props.onChanged(box.Text)
			end)
		)
	end

	if props.cleaner then
		for _, connection in connections do
			props.cleaner:Add(connection)
		end
	end

	return box
end

--------------------------------------------------------------------------------------
-- CONTAINERS
--------------------------------------------------------------------------------------
export type CardProps = {
	parent: Instance?,
	order: number?,
	padding: number?,
	gap: number?,
	color: Color3?,
	interactive: boolean?,
	cleaner: any?,
	onClick: (() -> ())?,
	-- A 3px severity rail down the left edge (state colour, not decoration). Carries
	-- meaning the way the toast rule does, so an error card reads as one before a
	-- word is parsed.
	accent: Color3?,
}

--[[
	A surface that groups related content and measures itself around it.
]]
function Widgets.Card(props: CardProps): Frame
	local card
	if props.interactive then
		-- A whole card that responds to a click has to be a button, not a frame with
		-- a click detector: only a button gets the pointer cursor.
		card = Instance.new("TextButton")
		card.Text = ""
		card.AutoButtonColor = false
	else
		card = Instance.new("Frame")
	end

	card.BackgroundColor3 = props.color or Theme.Color.Surface
	card.BorderSizePixel = 0
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.LayoutOrder = props.order or 1
	card.Parent = props.parent

	Widgets.Corner(card, Theme.Radius.Large)
	local stroke = Widgets.Stroke(card, Theme.Color.Border)
	local pad = props.padding or Theme.Space.Small
	Widgets.Pad(card, pad)
	Widgets.List(card, props.gap or Theme.Space.ExtraSmall)

	if props.accent then
		local rule = Instance.new("Frame")
		rule.BackgroundColor3 = props.accent
		rule.BorderSizePixel = 0
		rule.AnchorPoint = Vector2.new(0, 0.5)
		rule.Position = UDim2.new(0, -pad + 3, 0.5, 0)
		rule.Size = UDim2.new(0, 3, 1, -Theme.Space.Small)
		rule.Parent = card
		Widgets.Corner(rule, Theme.Radius.Pill)
	end

	if props.interactive then
		local baseColor = props.color or Theme.Color.Surface
		local over = false
		local connections = {
			card.MouseEnter:Connect(function()
				over = true
				TweenService:Create(stroke, HOVER_TWEEN, { Color = Theme.Color.Accent }):Play()
				TweenService:Create(card, HOVER_TWEEN, { BackgroundColor3 = Theme.Color.SurfaceAlt }):Play()
			end),
			card.MouseLeave:Connect(function()
				over = false
				TweenService:Create(stroke, HOVER_TWEEN, { Color = Theme.Color.Border }):Play()
				TweenService:Create(card, HOVER_TWEEN, { BackgroundColor3 = baseColor }):Play()
			end),
			card.MouseButton1Down:Connect(function()
				TweenService:Create(card, PRESS_TWEEN, {
					BackgroundColor3 = Theme.Mix(Theme.Color.SurfaceAlt, Color3.new(0, 0, 0), 0.12),
				}):Play()
			end),
			card.MouseButton1Up:Connect(function()
				TweenService:Create(card, HOVER_TWEEN, {
					BackgroundColor3 = over and Theme.Color.SurfaceAlt or baseColor,
				}):Play()
			end),
		}
		if props.onClick then
			table.insert(connections, card.Activated:Connect(props.onClick))
		end
		if props.cleaner then
			for _, connection in connections do
				props.cleaner:Add(connection)
			end
		end
	end

	return card
end

export type ListRowProps = {
	parent: Instance?,
	order: number?,
	cleaner: any?,
	onClick: (() -> ())?,
}

--[[
	A flat list row: transparent until hovered, divided from the next row by a
	hairline. Cards everywhere is what makes a panel read as generated — a list
	reads as a list when its items share dividers instead of each carrying a
	border and a radius.

	Without onClick the row is static: a hover wash on something unclickable would
	be a lie about affordance.
]]
function Widgets.ListRow(props: ListRowProps): TextButton
	local row = Instance.new("TextButton")
	row.AutoButtonColor = false
	row.Text = ""
	row.BackgroundColor3 = Theme.Color.Surface
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.LayoutOrder = props.order or 1
	row.Parent = props.parent

	Widgets.Pad(row, Theme.Space.Small)
	Widgets.List(row, Theme.Space.ExtraSmall)

	if props.onClick then
		local over = false
		local wash = Theme.Color.Surface
		local pressed = Theme.Mix(Theme.Color.Surface, Color3.new(0, 0, 0), 0.10)
		local connections = {
			row.MouseEnter:Connect(function()
				over = true
				TweenService:Create(row, HOVER_TWEEN, { BackgroundColor3 = wash, BackgroundTransparency = 0 }):Play()
			end),
			row.MouseLeave:Connect(function()
				over = false
				TweenService:Create(row, HOVER_TWEEN, { BackgroundColor3 = wash, BackgroundTransparency = 1 }):Play()
			end),
			row.MouseButton1Down:Connect(function()
				TweenService:Create(row, PRESS_TWEEN, { BackgroundColor3 = pressed, BackgroundTransparency = 0 }):Play()
			end),
			row.MouseButton1Up:Connect(function()
				TweenService:Create(row, HOVER_TWEEN, {
					BackgroundColor3 = wash,
					BackgroundTransparency = over and 0 or 1,
				}):Play()
			end),
			row.Activated:Connect(props.onClick),
		}
		if props.cleaner then
			for _, connection in connections do
				props.cleaner:Add(connection)
			end
		end
	end

	Widgets.Divider(row, 1000)

	return row
end

--[[
	A vertical scrolling region whose canvas grows with its contents.
]]
function Widgets.Scroller(parent: Instance, gap: number?): ScrollingFrame
	local scroller = Instance.new("ScrollingFrame")
	scroller.Size = UDim2.fromScale(1, 1)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 4
	scroller.ScrollBarImageColor3 = Theme.Color.BorderStrong
	scroller.ScrollBarImageTransparency = 0.3
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.ScrollingDirection = Enum.ScrollingDirection.Y
	scroller.ElasticBehavior = Enum.ElasticBehavior.Never
	scroller.Parent = parent

	Widgets.List(scroller, gap or Theme.Space.Small)
	-- Even insets on all sides. The right edge doubles as scrollbar clearance and
	-- the bottom edge keeps the last row off the widget edge.
	Widgets.Pad(scroller, Theme.Space.Small)

	return scroller
end

function Widgets.Row(parent: Instance, gap: number?, order: number?): Frame
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.LayoutOrder = order or 1
	row.Parent = parent
	Widgets.List(row, gap or Theme.Space.Small, true)
	return row
end

function Widgets.Spacer(parent: Instance, order: number?): Frame
	-- Absorbs the leftover width in a horizontal row so what follows sits right.
	local spacer = Instance.new("Frame")
	spacer.BackgroundTransparency = 1
	spacer.Size = UDim2.new(1, -4, 0, 1)
	spacer.LayoutOrder = order or 50
	spacer.Parent = parent

	local flex = Instance.new("UIFlexItem")
	flex.FlexMode = Enum.UIFlexMode.Fill
	flex.Parent = spacer

	return spacer
end

function Widgets.Divider(parent: Instance, order: number?): Frame
	local line = Instance.new("Frame")
	line.BackgroundColor3 = Theme.Color.Border
	line.BorderSizePixel = 0
	line.Size = UDim2.new(1, 0, 0, 1)
	line.LayoutOrder = order or 1
	line.Parent = parent
	return line
end

--------------------------------------------------------------------------------------
-- INDICATORS
--------------------------------------------------------------------------------------
--[[
	A small filled pill carrying one word of state.
]]
function Widgets.Badge(parent: Instance, text: string, color: Color3, order: number?): Frame
	local badge = Instance.new("Frame")
	-- The fill is the state colour at low opacity over the surface, so the badge
	-- reads as tinted rather than as a second button competing for attention.
	badge.BackgroundColor3 = Theme.Mix(Theme.Color.Surface, color, 0.18)
	badge.BorderSizePixel = 0
	badge.Size = UDim2.new(0, 0, 0, 20)
	badge.AutomaticSize = Enum.AutomaticSize.X
	badge.LayoutOrder = order or 1
	badge.Parent = parent

	Widgets.Corner(badge, Theme.Radius.Small)
	Widgets.Stroke(badge, Theme.Mix(Theme.Color.Surface, color, 0.35))
	Widgets.Pad(badge, Theme.Space.ExtraSmall)

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	label.Font = Theme.Font.Medium
	label.TextSize = Theme.TextSize.Caption
	label.TextColor3 = color
	label.Size = UDim2.new(0, 0, 1, 0)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Parent = badge

	return badge
end

--[[
	A determinate progress bar. Returns a setter taking 0..1 and a label string.
]]
function Widgets.ProgressBar(parent: Instance, order: number?): (Frame, (alpha: number, text: string?) -> ())
	local container = Instance.new("Frame")
	container.BackgroundTransparency = 1
	container.Size = UDim2.new(1, 0, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.LayoutOrder = order or 1
	container.Parent = parent
	Widgets.List(container, Theme.Space.ExtraSmall)

	local caption = Widgets.Label({
		parent = container,
		text = "",
		size = Theme.TextSize.Caption,
		color = Theme.Color.Subtext,
		truncate = true,
		order = 1,
	})

	local track = Instance.new("Frame")
	track.BackgroundColor3 = Theme.Color.SurfaceAlt
	track.BorderSizePixel = 0
	track.Size = UDim2.new(1, 0, 0, 4)
	track.LayoutOrder = 2
	track.Parent = container
	Widgets.Corner(track, Theme.Radius.Pill)

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = Theme.Color.Accent
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = track
	Widgets.Corner(fill, Theme.Radius.Pill)

	local function set(alpha: number, text: string?)
		if text then
			caption.Text = text
		end
		TweenService:Create(fill, HOVER_TWEEN, { Size = UDim2.fromScale(math.clamp(alpha, 0, 1), 1) }):Play()
	end

	return container, set
end

--[[
	What a list shows when it has nothing in it.

	Worth building properly rather than leaving blank: an empty list and a broken list
	look identical otherwise, and the empty state is where a first-time user spends
	their first minute.
]]
function Widgets.EmptyState(parent: Instance, title: string, body: string, order: number?): Frame
	local container = Instance.new("Frame")
	container.BackgroundTransparency = 1
	container.Size = UDim2.new(1, 0, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.LayoutOrder = order or 1
	container.Parent = parent
	Widgets.List(container, Theme.Space.ExtraSmall, false, Enum.HorizontalAlignment.Center)
	Widgets.Pad(container, Theme.Space.ExtraLarge)

	Widgets.Label({
		parent = container,
		text = title,
		size = Theme.TextSize.Heading,
		font = Theme.Font.Bold,
		color = Theme.Color.Subtext,
		align = Enum.TextXAlignment.Center,
		wrap = true,
		order = 1,
	})
	Widgets.Label({
		parent = container,
		text = body,
		size = Theme.TextSize.Label,
		color = Theme.Color.Faint,
		align = Enum.TextXAlignment.Center,
		wrap = true,
		order = 2,
	})

	return container
end

--[[
	A section title in the text's own voice: bold, body-size, never uppercased.
	A faint-caps eyebrow over every card is the single most generated-looking habit
	a panel can have — structure should come from hierarchy, not from styling every
	label identically.
]]
function Widgets.SectionTitle(parent: Instance, text: string, order: number?): TextLabel
	return Widgets.Label({
		parent = parent,
		text = text,
		size = Theme.TextSize.Body,
		font = Theme.Font.Bold,
		order = order or 1,
	})
end

--------------------------------------------------------------------------------------
-- SEGMENTED CONTROL
--------------------------------------------------------------------------------------
export type SegmentProps = {
	parent: Instance?,
	options: { { id: string, label: string } },
	selected: string,
	onSelect: ((id: string) -> ())?,
	order: number?,
	cleaner: any?,
}

--[[
	One recessed track with the active segment filled.

	Used for tabs and for the realm picker. Reading as a single object with a
	highlight inside it, rather than as N competing buttons, is what keeps a row of
	four choices from dominating the panel.
]]
function Widgets.SegmentedControl(props: SegmentProps): (Frame, (id: string) -> ())
	local track = Instance.new("Frame")
	track.BackgroundColor3 = Theme.Color.SurfaceAlt
	track.BorderSizePixel = 0
	track.Size = UDim2.new(1, 0, 0, Theme.Height.Tab)
	track.LayoutOrder = props.order or 1
	track.Parent = props.parent
	Widgets.Corner(track, Theme.Radius.Medium)
	Widgets.Stroke(track, Theme.Color.Border)
	Widgets.Pad(track, 3)

	local layout = Widgets.List(track, 2, true)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center

	local count = #props.options
	local buttons: { [string]: TextButton } = {}
	local current = props.selected

	local function paint()
		for id, button in buttons do
			local active = id == current
			button.BackgroundTransparency = active and 0 or 1
			button.TextColor3 = active and Theme.ReadableOn(Theme.Color.Accent) or Theme.Color.Subtext
			button.Font = active and Theme.Font.Bold or Theme.Font.Medium
		end
	end

	for index, option in props.options do
		local button = Instance.new("TextButton")
		button.AutoButtonColor = false
		button.Text = option.label
		button.Font = Theme.Font.Medium
		button.TextSize = Theme.TextSize.Label
		button.TextColor3 = Theme.Color.Subtext
		button.BackgroundColor3 = Theme.Color.Accent
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.LayoutOrder = index
		-- Each segment takes an equal share of the track less the gaps between them.
		button.Size = UDim2.new(1 / count, -(count - 1) * 2 / count, 1, 0)
		button.TextTruncate = Enum.TextTruncate.AtEnd
		button.Parent = track
		Widgets.Corner(button, Theme.Radius.Small)

		buttons[option.id] = button

		local hover = button.MouseEnter:Connect(function()
			if option.id ~= current then
				button.BackgroundTransparency = 0.88
			end
		end)
		local leave = button.MouseLeave:Connect(function()
			if option.id ~= current then
				button.BackgroundTransparency = 1
			end
		end)
		local click = button.Activated:Connect(function()
			if option.id == current then
				return
			end
			current = option.id
			paint()
			if props.onSelect then
				props.onSelect(option.id)
			end
		end)

		if props.cleaner then
			props.cleaner:Add(hover)
			props.cleaner:Add(leave)
			props.cleaner:Add(click)
		end
	end

	paint()

	return track, function(id: string)
		current = id
		paint()
	end
end

--------------------------------------------------------------------------------------
-- TOGGLE
--------------------------------------------------------------------------------------
export type ToggleProps = {
	parent: Instance?,
	label: string,
	description: string?,
	value: boolean,
	onChanged: ((value: boolean) -> ())?,
	order: number?,
	cleaner: any?,
}

--[[
	A labelled switch. The whole row is the target, not just the switch, because a
	14-pixel hit area in a docked panel is a nuisance to hit accurately.
]]
function Widgets.Toggle(props: ToggleProps): (Frame, (value: boolean) -> ())
	local value = props.value

	local row = Instance.new("TextButton")
	row.AutoButtonColor = false
	row.Text = ""
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.LayoutOrder = props.order or 1
	row.Parent = props.parent
	Widgets.List(row, Theme.Space.Small, true)

	local switch = Instance.new("Frame")
	switch.BackgroundColor3 = Theme.Color.SurfaceAlt
	switch.BorderSizePixel = 0
	switch.Size = UDim2.fromOffset(30, 17)
	switch.LayoutOrder = 1
	switch.Parent = row
	Widgets.Corner(switch, Theme.Radius.Pill)
	local switchStroke = Widgets.Stroke(switch, Theme.Color.Border)

	local knob = Instance.new("Frame")
	knob.BackgroundColor3 = Theme.Color.Faint
	knob.BorderSizePixel = 0
	knob.AnchorPoint = Vector2.new(0, 0.5)
	knob.Position = UDim2.new(0, 3, 0.5, 0)
	knob.Size = UDim2.fromOffset(11, 11)
	knob.Parent = switch
	Widgets.Corner(knob, Theme.Radius.Pill)

	local text = Instance.new("Frame")
	text.BackgroundTransparency = 1
	text.Size = UDim2.new(1, -42, 0, 0)
	text.AutomaticSize = Enum.AutomaticSize.Y
	text.LayoutOrder = 2
	text.Parent = row
	Widgets.List(text, 1)

	Widgets.Label({ parent = text, text = props.label, size = Theme.TextSize.Body, order = 1 })
	if props.description then
		Widgets.Label({
			parent = text,
			text = props.description,
			size = Theme.TextSize.Caption,
			color = Theme.Color.Faint,
			wrap = true,
			order = 2,
		})
	end

	local function paint()
		TweenService:Create(switch, HOVER_TWEEN, {
			BackgroundColor3 = value and Theme.Color.Accent or Theme.Color.SurfaceAlt,
		}):Play()
		TweenService:Create(switchStroke, HOVER_TWEEN, {
			Color = value and Theme.Color.Accent or Theme.Color.Border,
		}):Play()
		TweenService:Create(knob, HOVER_TWEEN, {
			Position = UDim2.new(0, value and 16 or 3, 0.5, 0),
			BackgroundColor3 = value and Theme.ReadableOn(Theme.Color.Accent) or Theme.Color.Faint,
		}):Play()
	end

	paint()

	local click = row.Activated:Connect(function()
		value = not value
		paint()
		if props.onChanged then
			props.onChanged(value)
		end
	end)
	if props.cleaner then
		props.cleaner:Add(click)
	end

	return row, function(next: boolean)
		value = next
		paint()
	end
end

--------------------------------------------------------------------------------------
-- DROPDOWN
--------------------------------------------------------------------------------------
export type DropdownProps = {
	parent: Instance?,
	options: { string },
	selected: string?,
	onSelect: ((value: string) -> ())?,
	order: number?,
	width: UDim?,
	cleaner: any?,
	maxVisible: number?,
	-- A full-size frame at the root of the panel. The open menu is parented here
	-- rather than to the dropdown; see below.
	overlay: Instance?,
}

--[[
	A compact picker for version lists.

	The open menu is parented to a panel-wide overlay, not to the dropdown itself,
	because every dropdown in this plugin sits inside a scrolling list. A
	ScrollingFrame clips its descendants — that is what makes it scroll — so a menu
	parented to the button would be cut off at the edge of the visible area, and a
	package with thirty published versions would show two of them. Parenting it to the
	overlay and positioning it from the button's absolute position sidesteps the
	clipping entirely.

	Without an overlay the menu still opens, attached to the dropdown, which is
	correct anywhere that is not inside a scroller.
]]
function Widgets.Dropdown(props: DropdownProps): (Frame, (value: string) -> ())
	local selected = props.selected or props.options[1] or ""

	local container = Instance.new("Frame")
	container.BackgroundTransparency = 1
	container.Size = UDim2.new(props.width or UDim.new(1, 0), UDim.new(0, Theme.Height.Control))
	container.LayoutOrder = props.order or 1
	container.ZIndex = 2
	container.Parent = props.parent

	local button = Instance.new("TextButton")
	button.AutoButtonColor = false
	button.BackgroundColor3 = Theme.Color.SurfaceAlt
	button.BorderSizePixel = 0
	button.Size = UDim2.fromScale(1, 1)
	button.Font = Theme.Font.Medium
	button.TextSize = Theme.TextSize.Label
	button.TextColor3 = Theme.Color.Text
	button.Text = selected
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.ZIndex = 2
	button.Parent = container
	Widgets.Corner(button, Theme.Radius.Medium)
	local buttonStroke = Widgets.Stroke(button, Theme.Color.Border)
	Widgets.Pad(button, Theme.Space.Small)

	local dropPressed = Theme.Mix(Theme.Color.SurfaceAlt, Color3.new(0, 0, 0), 0.12)
	local dropDown = button.MouseButton1Down:Connect(function()
		TweenService:Create(button, PRESS_TWEEN, { BackgroundColor3 = dropPressed }):Play()
	end)
	local dropUp = button.MouseButton1Up:Connect(function()
		TweenService:Create(button, HOVER_TWEEN, { BackgroundColor3 = Theme.Color.SurfaceAlt }):Play()
	end)
	if props.cleaner then
		props.cleaner:Add(dropDown)
		props.cleaner:Add(dropUp)
	end

	-- A plain + when closed, − when open. ASCII by choice: it renders in every
	-- font build, where the old ▾ glyph was a coverage gamble.
	local marker = Instance.new("TextLabel")
	marker.BackgroundTransparency = 1
	marker.Text = "+"
	marker.Font = Theme.Font.Bold
	marker.TextSize = Theme.TextSize.Body
	marker.TextColor3 = Theme.Color.Subtext
	-- Full button height in scale so it tracks the control, not a pixel count.
	marker.Size = UDim2.new(0, 16, 1, 0)
	marker.Position = UDim2.new(1, -18, 0, 0)
	marker.ZIndex = 3
	marker.Parent = container

	-- An invisible catcher behind the menu, so clicking anywhere else closes it. Only
	-- exists while the menu is open, and only when there is an overlay to host it.
	local dismisser: TextButton? = nil

	local menu = Instance.new("Frame")
	menu.BackgroundColor3 = Theme.Color.Elevated
	menu.BorderSizePixel = 0
	menu.Visible = false
	menu.Position = UDim2.new(0, 0, 1, 4)
	menu.Size = UDim2.new(1, 0, 0, 0)
	menu.AutomaticSize = Enum.AutomaticSize.Y
	menu.ZIndex = 20
	menu.Parent = props.overlay or container
	Widgets.Corner(menu, Theme.Radius.Medium)
	Widgets.Stroke(menu, Theme.Color.BorderStrong)
	Widgets.Pad(menu, Theme.Space.ExtraSmall)

	local menuScroll = Instance.new("ScrollingFrame")
	menuScroll.BackgroundTransparency = 1
	menuScroll.BorderSizePixel = 0
	menuScroll.Size = UDim2.new(1, 0, 0, math.min(#props.options, props.maxVisible or 6) * 24)
	menuScroll.CanvasSize = UDim2.new()
	menuScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	menuScroll.ScrollBarThickness = 3
	menuScroll.ScrollBarImageColor3 = Theme.Color.BorderStrong
	menuScroll.ZIndex = 20
	menuScroll.Parent = menu
	Widgets.List(menuScroll, 1)

	local itemButtons: { [string]: TextButton } = {}

	local function setSelected(value: string)
		selected = value
		button.Text = value
		-- The open menu marks the current choice with a check, so a long version
		-- list can be scanned rather than re-read item by item.
		for option, item in itemButtons do
			item.Text = (option == value and "✓  " or "      ") .. option
			item.Font = option == value and Theme.Font.Medium or Theme.Font.Regular
			item.TextColor3 = option == value and Theme.Color.Text or Theme.Color.Subtext
		end
	end

	local function close()
		menu.Visible = false
		marker.Text = "+"
		TweenService:Create(buttonStroke, HOVER_TWEEN, { Color = Theme.Color.Border }):Play()
		if dismisser then
			dismisser:Destroy()
			dismisser = nil
		end
	end

	local function open()
		if props.overlay then
			-- Position under the button in the overlay's own coordinate space. Read
			-- at open time rather than cached: the list underneath scrolls, and a
			-- position measured when the dropdown was built would be stale.
			local overlay = props.overlay :: GuiObject
			local origin = button.AbsolutePosition - overlay.AbsolutePosition
			menu.Position = UDim2.fromOffset(origin.X, origin.Y + button.AbsoluteSize.Y + 4)
			menu.Size = UDim2.fromOffset(button.AbsoluteSize.X, 0)

			dismisser = Instance.new("TextButton")
			local catcher = dismisser :: TextButton
			catcher.Text = ""
			catcher.BackgroundTransparency = 1
			catcher.Size = UDim2.fromScale(1, 1)
			catcher.ZIndex = 19
			catcher.Parent = overlay
			catcher.Activated:Connect(close)
		end
		menu.Visible = true
		marker.Text = "-"
		TweenService:Create(buttonStroke, HOVER_TWEEN, { Color = Theme.Color.Accent }):Play()
	end

	for index, option in props.options do
		local item = Instance.new("TextButton")
		item.AutoButtonColor = false
		item.BackgroundColor3 = Theme.Color.Accent
		item.BackgroundTransparency = 1
		item.BorderSizePixel = 0
		item.Size = UDim2.new(1, 0, 0, 22)
		item.Font = Theme.Font.Regular
		item.TextSize = Theme.TextSize.Label
		item.TextColor3 = Theme.Color.Text
		item.Text = option
		item.TextXAlignment = Enum.TextXAlignment.Left
		item.LayoutOrder = index
		item.ZIndex = 21
		item.Parent = menuScroll
		Widgets.Corner(item, Theme.Radius.Small)
		Widgets.Pad(item, Theme.Space.ExtraSmall)
		itemButtons[option] = item

		local enter = item.MouseEnter:Connect(function()
			item.BackgroundTransparency = 0.85
		end)
		local leave = item.MouseLeave:Connect(function()
			item.BackgroundTransparency = 1
		end)
		local click = item.Activated:Connect(function()
			setSelected(option)
			close()
			if props.onSelect then
				props.onSelect(option)
			end
		end)

		if props.cleaner then
			props.cleaner:Add(enter)
			props.cleaner:Add(leave)
			props.cleaner:Add(click)
		end
	end

	local toggle = button.Activated:Connect(function()
		if menu.Visible then
			close()
		else
			open()
		end
	end)
	if props.cleaner then
		props.cleaner:Add(toggle)
		-- The menu lives on the overlay, outside this container, so destroying the
		-- dropdown would otherwise strand it there.
		props.cleaner:Add(menu)
		props.cleaner:Add(close)
	end

	-- Paint the initial checkmark without notifying: the menu opens already knowing
	-- which version is current.
	setSelected(selected)

	return container, setSelected
end

return Widgets
