extends Node
## Runtime MCP bridge — the SAME MCP server as the editor plugin (mcp_bridge.gd),
## but running INSIDE the deployed game (e.g. on the Quest 3) over its live
## SceneTree instead of the editor. Reach it over `adb forward`. Editor-only
## commands return an error; scene/node/eval/screenshot/performance work on the
## running game.
##
## One MCPProtocol, every transport the platform has:
## - HTTP on 127.0.0.1: streamable HTTP at /mcp and the 2024-11-05 HTTP+SSE pair at /sse and
##   /messages, on one port.
## A web export serves nothing: a page cannot listen.
##
## A game trims and extends the tool list in Project Settings, without code:
## - vsekai_godot_mcp/allow (PackedStringArray): built-in tools to keep; empty keeps all.
## - vsekai_godot_mcp/providers (PackedStringArray): scripts whose new() gives an object with
##   tool_defs() and call_tool(name, args) (see mcp_protocol.gd). A Node provider is added as a
##   child of this node, so it can reach the scene tree. A provider with scene_root() picks the
##   node the built-in tools treat as the scene.
## - vsekai_godot_mcp/server_name, server_title, instructions: what initialize reports.
## - vsekai_godot_mcp/listen_by_default (bool, default true): when false, HTTP listens only
##   when --mcp-port= or GODOT_MCP_PORT asks for it.
const MCPCommandsLib = preload("mcp_commands.gd")
const MCPProtocolLib = preload("mcp_protocol.gd")
const MCPHttpServerLib = preload("mcp_http_server.gd")

const HOST := "127.0.0.1"  # adb forward reaches the device loopback
const SETTINGS := "vsekai_godot_mcp/"

## Not 8788. The editor plugin listens there, and the ordinary way to run a game is to press
## play in an editor that is already open — so sharing the number meant the runtime bridge lost
## the bind every time it was most wanted, and said only "listen failed" while an MCP client
## went on talking to the editor and believing it was talking to the game.
const HTTP_PORT_DEFAULT := 8789


## `--mcp-port=NNNN` after `--`, or GODOT_MCP_PORT. Two games at once need two ports, and a
## device reached over `adb forward` may have neither free. 0 turns HTTP off; -1 = not asked.
static func _resolve_port() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mcp-port="):
			return int(arg.split("=", true, 1)[1])
	var env := OS.get_environment("GODOT_MCP_PORT")
	if not env.is_empty():
		return int(env)
	return -1


## Whether this build may run the MCP server at all. Always yes in the editor (so dev work and
## `mcp_switch_check.tscn`/`mcp_check.py`, which run the editor binary, keep working unchanged),
## and whenever `--mcp-port=` names a port on the command line (an explicit opt-in on any shipped
## viewer). No package variant ships it on by default: skintokens-viewer, walk-mode-viewer and
## kimodo-motion-viewer all start with the server off and the slider (McpSwitch.gd) hidden; reach
## it with e.g. `skintokens-viewer -- --mcp-port=8789` from the command line.
static func build_enabled() -> bool:
	return OS.has_feature("editor") or _resolve_port() >= 0


var _cmds = MCPCommandsLib.new()
var protocol = MCPProtocolLib.new()
var _http = null


func _ready() -> void:
	protocol.commands = _cmds
	_configure()
	if OS.has_feature("web") or not build_enabled():
		return
	_start_http()
	set_process(true)


func _configure() -> void:
	protocol.allow = PackedStringArray(
		ProjectSettings.get_setting(SETTINGS + "allow", PackedStringArray())
	)
	for key in ["server_name", "server_title", "instructions"]:
		var v = ProjectSettings.get_setting(SETTINGS + key, "")
		if String(v) != "":
			protocol.set(key, String(v))
	for path in ProjectSettings.get_setting(SETTINGS + "providers", PackedStringArray()):
		var script = load(path)
		if script == null or not script.can_instantiate():
			push_error("[godot_mcp] provider did not load: " + path)
			continue
		var p = script.new()
		if p is Node:
			add_child(p)
		protocol.providers.append(p)


var _port := 0  # the port the server last listened on


## Whether the runtime server is accepting connections now.
func is_listening() -> bool:
	return _http != null and _http.is_listening()


## The URL a client connects to while it listens, else "".
func url() -> String:
	return "http://%s:%d/mcp" % [HOST, _port] if is_listening() else ""


## Switch the server on or off while the game runs (the viewer's slider). Returns whether it listens
## afterwards: off on the web, and off when the port is taken.
func set_listening(on: bool) -> bool:
	if OS.has_feature("web") or not build_enabled():
		return false
	if on:
		if _http == null:
			_start_http(true)
		elif not _http.is_listening():
			_http.start(_port, HOST)
	elif _http != null:
		_http.stop()
	return is_listening()


## asked: the viewer's slider asked for the server, so listen_by_default (the start-up choice) does not apply.
func _start_http(asked := false) -> void:
	var port := _resolve_port()
	if port < 0:
		if not asked and not ProjectSettings.get_setting(SETTINGS + "listen_by_default", true):
			return
		port = HTTP_PORT_DEFAULT
	if port == 0:
		return
	_http = MCPHttpServerLib.new()
	_http.protocol = protocol
	_port = port
	if _http.start(port, HOST) == OK:
		printerr("[godot_mcp] RUNTIME MCP on http://%s:%d/mcp (and /sse)" % [HOST, port])
	else:
		# Say what is probably holding it. A bare "listen failed" sent everyone to the firewall,
		# and it was almost always the editor plugin or a previous run of the same game.
		push_error(
			(
				"[godot_mcp] runtime HTTP listen failed on :%d — something else holds it" % port
				+ " (the editor plugin uses 8788). Set --mcp-port= or GODOT_MCP_PORT."
			)
		)
		_http = null


func _process(_delta: float) -> void:
	_cmds.editor = null
	_cmds.root = _scene_root()
	if _http:
		_http.poll()


## The node the built-in tools treat as the scene: the first provider's scene_root() when it has
## one (a game that builds its scene under an autoload), else the current scene.
func _scene_root() -> Node:
	for p in protocol.providers:
		if p.has_method("scene_root"):
			var r = p.scene_root()
			if r is Node:
				return r
	return get_tree().current_scene if get_tree().current_scene else get_tree().root


func _exit_tree() -> void:
	if _http:
		_http.stop()
