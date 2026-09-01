--!strict
-- Lightweight in-process event helper for Controller/Service internal use
-- (not a replacement for RemoteEvents, which cross the client/server
-- boundary -- see Modules/RemotesSetup).

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type Signal<T...> = typeof(setmetatable(
	{} :: {
		_handlers: { (T...) -> () },
	},
	Signal
))

function Signal.new<T...>(): Signal<T...>
	return setmetatable({
		_handlers = {},
	}, Signal) :: any
end

function Signal.Connect<T...>(self: Signal<T...>, handler: (T...) -> ()): Connection
	table.insert(self._handlers, handler)

	local connection = {
		Connected = true,
	}

	local connectionMt = {}
	connectionMt.__index = connectionMt
	function connectionMt.Disconnect(conn)
		if not conn.Connected then
			return
		end
		conn.Connected = false
		local index = table.find(self._handlers, handler)
		if index then
			table.remove(self._handlers, index)
		end
	end

	return setmetatable(connection, connectionMt) :: any
end

function Signal.Fire<T...>(self: Signal<T...>, ...: T...)
	for _, handler in self._handlers do
		task.spawn(handler, ...)
	end
end

function Signal.DisconnectAll<T...>(self: Signal<T...>)
	table.clear(self._handlers)
end

return Signal
