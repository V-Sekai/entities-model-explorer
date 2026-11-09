@tool
extends RefCounted
## A tool result that is not ready yet. A tool that takes frames (an auto-rig, a download)
## returns one of these from call_tool() and calls finish() later; MCPProtocol.handle_rpc()
## then returns an MCPPending that finishes with the whole JSON-RPC response. handle_rpc() stays
## synchronous, so only the transports wait: `var resp = await MCPPending.settle(resp)`.

signal done(result)

var result = null
var finished := false


func finish(value) -> void:
	if finished:
		return
	result = value
	finished = true
	done.emit(value)


## A pending that finishes with f(value) when this one finishes.
func then(f: Callable):
	var next = get_script().new()
	if finished:
		next.finish(f.call(result))
	else:
		done.connect(func(v): next.finish(f.call(v)), CONNECT_ONE_SHOT)
	return next


## Wait for a value that may be pending, or an Array (a batch) that may hold pending items.
static func settle(value):
	if value is Array:
		var out := []
		for v in value:
			out.append(await settle(v))
		return out
	if value != null and value is Object and value.has_method("then") and value.has_signal("done"):
		if not value.finished:
			await value.done
		return value.result
	return value
