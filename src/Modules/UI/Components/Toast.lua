--!nonstrict
--[[
======================================================================================
	TOAST  -  transient messages, stacked at the bottom of the panel
======================================================================================
	Installs are long enough that the user looks away, so the outcome has to be
	visible when they look back — but not so intrusive that a successful install
	interrupts them. Toasts stack upward from the bottom, newest last, and time out on
	their own.

	Errors do not time out. A failed install is the one message a user has to be able
	to read at their own pace, and it is dismissed by clicking it.
======================================================================================
]]

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Parent.Parent.Config.Theme)
local Widgets = require(script.Parent.Widgets)

local Toast = {}

local SLIDE = TweenInfo.new(Theme.Motion.Base, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LIFETIME = 4
local MAX_VISIBLE = 3

--[[
	Mount the toast stack into `parent` and return a function for posting to it.

	The returned function takes (text, kind) where kind is "info", "success",
	"warning" or "error".
]]
function Toast.Mount(parent: Instance): (text: string, kind: string?) -> ()
	local stack = Instance.new("Frame")
	stack.BackgroundTransparency = 1
	stack.AnchorPoint = Vector2.new(0.5, 1)
	stack.Position = UDim2.new(0.5, 0, 1, -Theme.Space.Medium)
	stack.Size = UDim2.fromScale(0.94, 0)
	stack.AutomaticSize = Enum.AutomaticSize.Y
	-- Above every panel, so a message during an install is never behind a card.
	stack.ZIndex = 100
	stack.Parent = parent

	local layout = Widgets.List(stack, Theme.Space.Small)
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom

	local live: { Frame } = {}
	-- LayoutOrder is an integer, and it only has to increase: newest sits at the
	-- bottom of the stack.
	local posted = 0

	local function colorFor(kind: string?): Color3
		if kind == "success" then
			return Theme.Color.Success
		elseif kind == "warning" then
			return Theme.Color.Warning
		elseif kind == "error" then
			return Theme.Color.Danger
		end
		return Theme.Color.Info
	end

	return function(text: string, kind: string?)
		local accent = colorFor(kind)

		local toast = Instance.new("TextButton")
		toast.AutoButtonColor = false
		toast.Text = ""
		toast.BackgroundColor3 = Theme.Color.Surface
		toast.BorderSizePixel = 0
		toast.Size = UDim2.new(1, 0, 0, 0)
		toast.AutomaticSize = Enum.AutomaticSize.Y
		toast.ZIndex = 101
		posted += 1
		toast.LayoutOrder = posted
		toast.Parent = stack
		Widgets.Corner(toast, Theme.Radius.Medium)
		Widgets.Stroke(toast, Theme.Mix(Theme.Color.Border, accent, 0.45))
		Widgets.Pad(toast, Theme.Space.Small)

		-- Plain text only. Severity still shows in the tinted border, which reads
		-- at a glance without any icon competing with the message.
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Text = text
		label.Font = Theme.Font.Medium
		label.TextSize = Theme.TextSize.Label
		label.TextColor3 = Theme.Color.Text
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.TextWrapped = true
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.ZIndex = 102
		label.Parent = toast

		-- Enter and exit through transparency only: no motion on the highest-frequency
		-- feedback in the panel, just a 180ms fade that never disturbs layout.
		toast.BackgroundTransparency = 1
		label.TextTransparency = 1
		TweenService:Create(toast, SLIDE, { BackgroundTransparency = 0 }):Play()
		TweenService:Create(label, SLIDE, { TextTransparency = 0 }):Play()

		table.insert(live, toast)

		local function dismiss()
			local index = table.find(live, toast)
			if not index then
				return
			end
			table.remove(live, index)
			local fade = TweenService:Create(toast, SLIDE, { BackgroundTransparency = 1 })
			TweenService:Create(label, SLIDE, { TextTransparency = 1 }):Play()
			fade:Play()
			fade.Completed:Once(function()
				toast:Destroy()
			end)
		end

		toast.Activated:Connect(dismiss)

		-- Older toasts give way rather than letting the stack grow past the panel.
		while #live > MAX_VISIBLE do
			local oldest = table.remove(live, 1)
			if oldest then
				oldest:Destroy()
			end
		end

		-- Errors stay until dismissed; see the header note.
		if kind ~= "error" then
			task.delay(LIFETIME, dismiss)
		end
	end
end

return Toast
