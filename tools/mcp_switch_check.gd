extends Node


# Run: godot --headless --path . res://tools/mcp_switch_check.tscn (the MCP autoload needs a scene run).
# The viewer starts with the server off (project setting listen_by_default=false, no --mcp-port). The slider's
# set_listening(true) must then turn it on; before the fix it returned false because _start_http() read the same
# setting and went back.
func _ready() -> void:
	var mcp := get_node("/root/MCP")
	var fails := 0
	if mcp.is_listening():
		printerr("FAIL the server was already on at start")
		fails += 1
	var on: bool = mcp.set_listening(true)
	if not on or not mcp.is_listening() or mcp.url() == "":
		printerr("FAIL set_listening(true) left the server off")
		fails += 1
	var off: bool = mcp.set_listening(false)
	if off or mcp.is_listening():
		printerr("FAIL set_listening(false) left the server on")
		fails += 1
	print("MCP-SWITCH-CHECK ", "FAIL" if fails else "OK")
	get_tree().quit(1 if fails else 0)
