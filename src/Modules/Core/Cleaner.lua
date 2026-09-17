--!strict
--[[
======================================================================================
	CLEANER  -  scoped teardown for connections, instances and callbacks
======================================================================================
	A plugin outlives every UI it builds. Changing the theme or re-rendering a list
	throws away GuiObjects, and every connection made while building them has to go
	at the same moment — a leaked RenderStepped handler on a destroyed frame keeps
	running for the rest of the Studio session.

	Scopes nest through Extend(): the plugin owns one Cleaner for things that live as
	long as it does (toolbar, widget, registry cache), and the UI owns a child that
	is emptied on every rebuild. Cleaning the parent cleans the children with it.

	Written here rather than pulled from the registry on purpose. A plugin whose job
	is installing Wally packages should not itself need `wally install` before it can
	be built.
======================================================================================
]]

local Cleaner = {}
Cleaner.__index = Cleaner

export type Task = RBXScriptConnection | Instance | () -> () | Cleaner

export type Cleaner = typeof(setmetatable(
	{} :: {
		_tasks: { Task },
		_children: { Cleaner },
		_destroyed: boolean,
	},
	Cleaner
))

function Cleaner.New(): Cleaner
	return setmetatable({
		_tasks = {},
		_children = {},
		_destroyed = false,
	}, Cleaner) :: any
end

--[[
	Hand something over to be cleaned up later: a connection, an instance, or a
	function to call. Returns what it was given, so it can wrap an expression.
]]
function Cleaner.Add<T>(self: Cleaner, item: T & Task): T
	if self._destroyed then
		-- Adding to a dead scope would leak silently, since nothing will ever clean
		-- it. Clean it immediately instead, which is what the caller meant.
		local kind = typeof(item)
		if kind == "RBXScriptConnection" then
			(item :: any):Disconnect()
		elseif kind == "Instance" then
			(item :: any):Destroy()
		elseif kind == "function" then
			(item :: any)()
		end
		return item
	end

	table.insert(self._tasks, item)
	return item
end

--[[
	Connect to a signal and hand the connection over in one step. This is the common
	case by a wide margin, and doing it in two steps is how connections get missed.
]]
function Cleaner.Connect(self: Cleaner, signal: RBXScriptSignal, handler: (...any) -> ()): RBXScriptConnection
	return self:Add(signal:Connect(handler))
end

--[[
	A child scope that dies with this one but can also be cleaned on its own.
]]
function Cleaner.Extend(self: Cleaner): Cleaner
	local child = Cleaner.New()
	table.insert(self._children, child)
	return child
end

--[[
	Run every pending task and empty the scope, leaving it reusable.
]]
function Cleaner.Clean(self: Cleaner)
	for _, child in self._children do
		child:Clean()
	end
	table.clear(self._children)

	-- Reverse order, so anything built on top of an earlier task is torn down before
	-- the thing it depends on.
	local tasks = self._tasks
	self._tasks = {}
	for index = #tasks, 1, -1 do
		local item = tasks[index]
		local kind = typeof(item)
		if kind == "RBXScriptConnection" then
			(item :: any):Disconnect()
		elseif kind == "Instance" then
			(item :: any):Destroy()
		elseif kind == "function" then
			-- One failing teardown must not strand the rest of the list.
			local ok, problem = pcall(item :: any)
			if not ok then
				warn(`[Wally Studio] cleanup task failed: {problem}`)
			end
		elseif kind == "table" then
			(item :: any):Clean()
		end
	end
end

--[[
	Clean, then refuse further work. Used when the plugin unloads.
]]
function Cleaner.Destroy(self: Cleaner)
	self:Clean()
	self._destroyed = true
end

return Cleaner
