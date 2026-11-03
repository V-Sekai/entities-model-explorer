extends PanelContainer
# A slider that turns the viewer's MCP server on and off while it runs. Bottom right, left of the ?
# button. It shows what the server is doing now (on while it listens), the address in its tooltip, and
# the choice is remembered (ViewerSettings "mcp"). A server started by `-- --mcp-port=N` stays as asked:
# the saved choice does not override a port named on the command line.
const CardStyle = preload("res://vsk_model_explorer/core/CardStyle.gd")
const ViewerSettings = preload("res://vsk_model_explorer/core/ViewerSettings.gd")
const HEIGHT := 48.0
var _switch: CheckButton
var _mcp: Node


func _ready() -> void:
	_mcp = get_node_or_null("/root/MCP")
	if _mcp == null or not _mcp.has_method("set_listening"):
		queue_free()   # no server in this build (the web export has none)
		return
	theme = CardStyle.make_theme()
	add_theme_stylebox_override("panel", CardStyle.card_box())
	var row := HBoxContainer.new()
	add_child(row)
	var label := Label.new()
	label.text = "MCP"
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(label)
	_switch = CheckButton.new()
	_switch.focus_mode = Control.FOCUS_NONE
	row.add_child(_switch)
	custom_minimum_size = Vector2(0, HEIGHT)
	var named_port := false
	for arg in OS.get_cmdline_user_args():
		named_port = named_port or arg.begins_with("--mcp-port=")
	if not named_port and ViewerSettings.has_key("mcp"):
		_mcp.set_listening(ViewerSettings.get_bool("mcp", true))
	_switch.set_pressed_no_signal(_mcp.is_listening())
	_switch.toggled.connect(_on_toggled)


func _on_toggled(on: bool) -> void:
	var now: bool = _mcp.set_listening(on)
	_switch.set_pressed_no_signal(now)   # off again if the port was taken
	ViewerSettings.set_bool("mcp", now)


func _process(_delta: float) -> void:
	# Bottom right, left of the ? button; placed from the window and the card's own size.
	var window := get_viewport_rect().size
	position = Vector2(
		window.x - CardStyle.MARGIN - 48.0 - 8.0 - size.x, window.y - CardStyle.MARGIN - HEIGHT
	)
	_switch.set_pressed_no_signal(_mcp.is_listening())
	tooltip_text = _mcp.url() if _mcp.is_listening() else "MCP server off"
