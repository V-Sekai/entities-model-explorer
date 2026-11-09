@tool
extends RefCounted
class_name MCPProtocol
## Pure MCP / JSON-RPC 2.0 handler — no transport, no HTTP. Turns a decoded
## JSON-RPC request into a response Dictionary (or null for notifications),
## dispatching tools/call to MCPCommands. This lets the Godot addon BE the MCP
## server with no external process; mcp_http_server.gd (streamable HTTP and the
## 2024-11-05 HTTP+SSE transport) carries it.
## Unit-tested headless (tests/test_protocol.gd).
##
## Two ways to change the tool list, so a game can ship a short one:
## - `allow`: names of built-in tools to keep (empty keeps all of them).
## - `providers`: objects with tool_defs() -> Array of MCP tool dictionaries and
##   call_tool(name, args) -> value. A provider tool hides a built-in of the same name.
## A tool value is JSON-able data (sent as text, and as structuredContent when it is a
## Dictionary), {"__error__": true, "msg": ...}, {"__content__": [MCP content blocks]},
## or an MCPPending that finishes later with one of those.

## Newest first. Two eras (see 2026-07-28 basic/versioning):
## - Legacy (2025-11-25 and earlier): an initialize handshake picks the version. initialize
##   answers with the client's version when it is one of LEGACY_VERSIONS, else the newest of them.
## - Modern (2026-07-28): no handshake. Every request names its version in
##   params._meta["io.modelcontextprotocol/protocolVersion"]; results carry resultType and the
##   server's identity in _meta; server/discover lists the versions; ping is gone.
## One server answers both, request by request.
const MODERN_VERSIONS := ["2026-07-28"]
const LEGACY_VERSIONS := ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
const SUPPORTED_VERSIONS := ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
const PROTOCOL_VERSION := "2025-11-25"
const META_VERSION := "io.modelcontextprotocol/protocolVersion"
const META_SERVER := "io.modelcontextprotocol/serverInfo"
## MCP error codes (2026-07-28 schema).
const HEADER_MISMATCH := -32020
const UNSUPPORTED_PROTOCOL_VERSION := -32022
## How long a client may keep tools/list and server/discover (2026-07-28 CacheableResult).
## The list never changes while the program runs, and it holds nothing per user.
const LIST_TTL_MS := 300000
const SERVER_NAME := "vsekai-godot-mcp"
const SERVER_VERSION := "0.2.0"

# Relative preload (not the class_name global) so this resolves headless and
# wherever the addon is installed.
const MCPCommandsLib = preload("mcp_commands.gd")
const PendingLib = preload("mcp_pending.gd")

var commands = null  # MCPCommands instance
var allow := PackedStringArray()
var providers: Array = []
var server_name := SERVER_NAME
var server_version := SERVER_VERSION
var server_title := ""
var instructions := ""
## The version the last initialize agreed on.
var negotiated := PROTOCOL_VERSION
var _rpc := JSONRPC.new()  # Godot's built-in JSON-RPC envelope helper


func _init() -> void:
	if commands == null:
		commands = MCPCommandsLib.new()


# --- JSON-RPC entry ----------------------------------------------------------


## Returns a JSON-RPC response Dictionary, an Array for a batch, null when the
## message needs no reply (a notification, or a response to us), or an MCPPending
## when a tool finishes later (see MCPPending.settle).
func handle_rpc(req) -> Variant:
	if typeof(req) == TYPE_ARRAY:
		return _handle_batch(req)
	if typeof(req) != TYPE_DICTIONARY:
		return _error(null, -32600, "invalid request")
	# A JSON-RPC message with no "method" is a response (to a server->client
	# request). We issue no server requests, so accept it with no reply (the
	# transport answers 202). Per spec these need no response.
	if not req.has("method"):
		return null
	var id = json_id(req.get("id", null))
	var method := String(req.get("method", ""))
	var version := request_version(req)
	if version != "" and not (version in SUPPORTED_VERSIONS):
		if id == null:
			return null
		return unsupported_version(id, version)
	var modern := version in MODERN_VERSIONS
	match method:
		"initialize":
			return _result(id, _initialize_result(req.get("params", {})))
		"notifications/initialized", "notifications/cancelled", "initialized":
			return null
		"server/discover":
			return _result(id, _modern_result(_discover_result(), true))
		"ping":
			if modern:
				return _error(id, -32601, "method not found: ping (removed in 2026-07-28)")
			return _result(id, {})
		"tools/list":
			var listed := {"tools": tool_schemas()}
			return _result(id, _modern_result(listed, true) if modern else listed)
		"tools/call":
			var r = _call_tool(id, req.get("params", {}))
			if modern and r is PendingLib:
				return r.then(func(resp): return _modern_response(resp))
			return _modern_response(r) if modern else r
		_:
			if id == null:
				return null  # unknown notification: ignore
			return _error(id, -32601, "method not found: " + method)


## Godot's JSON parser reads every number as a float, so an id of 1 would go back as 1.0, which
## strict clients (the Python SDK) refuse to match. A whole-number id goes back as an integer.
static func json_id(id):
	if (
		typeof(id) == TYPE_FLOAT
		and is_finite(id)
		and id == floorf(id)
		and absf(id) < 9007199254740992.0
	):
		return int(id)
	return id


## The version a modern request names in its _meta, or "" for a legacy request.
static func request_version(req) -> String:
	if typeof(req) != TYPE_DICTIONARY:
		return ""
	var params = req.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		return ""
	var meta = params.get("_meta", {})
	if typeof(meta) != TYPE_DICTIONARY:
		return ""
	return String(meta.get(META_VERSION, ""))


func unsupported_version(id, requested: String) -> Dictionary:
	var e := _error(id, UNSUPPORTED_PROTOCOL_VERSION, "Unsupported protocol version")
	e.error["data"] = {"supported": SUPPORTED_VERSIONS.duplicate(), "requested": requested}
	return e


func server_info() -> Dictionary:
	var info := {"name": server_name, "version": server_version}
	if server_title != "":
		info["title"] = server_title
	return info


func _capabilities() -> Dictionary:
	return {"tools": {"listChanged": false}}


func _discover_result() -> Dictionary:
	var out := {
		"supportedVersions": SUPPORTED_VERSIONS.duplicate(), "capabilities": _capabilities()
	}
	if instructions != "":
		out["instructions"] = instructions
	return out


## A 2026-07-28 result: resultType, the server's identity in _meta, and cache hints on lists.
func _modern_result(result, cacheable := false):
	if typeof(result) != TYPE_DICTIONARY:
		return result
	var r: Dictionary = result.duplicate()
	r["resultType"] = "complete"
	var meta: Dictionary = r.get("_meta", {})
	meta[META_SERVER] = server_info()
	r["_meta"] = meta
	if cacheable:
		r["ttlMs"] = LIST_TTL_MS
		r["cacheScope"] = "public"
	return r


func _modern_response(resp):
	if resp is Dictionary and resp.has("result"):
		resp["result"] = _modern_result(resp["result"])
	return resp


## JSON-RPC 2.0 batch (MCP 2025-03-26 allows them; later versions dropped them, and
## answering one anyway costs nothing). Notifications get no entry; an empty batch is
## an invalid request; a batch of only notifications gets no reply.
func _handle_batch(batch: Array):
	if batch.is_empty():
		return _error(null, -32600, "invalid request: empty batch")
	var out := []
	for item in batch:
		var r = (
			handle_rpc(item)
			if typeof(item) == TYPE_DICTIONARY
			else _error(null, -32600, "invalid request")
		)
		if r != null:
			out.append(r)
	return null if out.is_empty() else out


func _initialize_result(params) -> Dictionary:
	var asked := ""
	if typeof(params) == TYPE_DICTIONARY:
		asked = String(params.get("protocolVersion", ""))
	negotiated = asked if asked in LEGACY_VERSIONS else PROTOCOL_VERSION
	var out := {
		"protocolVersion": negotiated,
		"capabilities": _capabilities(),
		"serverInfo": server_info(),
	}
	if instructions != "":
		out["instructions"] = instructions
	return out


func _result(id, value) -> Dictionary:
	return _rpc.make_response(value, id)


func _error(id, code: int, msg: String) -> Dictionary:
	return _rpc.make_response_error(code, msg, id)


## JSON-RPC error with a null id — for transport-level failures (parse error
## -32700, unsupported protocol version) before/without a request id.
func parse_error_response(code: int, msg: String) -> Dictionary:
	return _rpc.make_response_error(code, msg, null)


# --- tools/call --------------------------------------------------------------


func _call_tool(id, params) -> Variant:
	if typeof(params) != TYPE_DICTIONARY:
		return _error(id, -32602, "invalid params")
	var name := String(params.get("name", ""))
	var args = params.get("arguments", {})
	if typeof(args) != TYPE_DICTIONARY:
		args = {}
	var out = null
	var provider = _provider_for(name)
	if provider != null:
		out = provider.call_tool(name, args)
	elif _builtin_names().has(name):
		out = commands.dispatch(name, args)
	else:
		return _error(id, -32602, "unknown tool: " + name)
	if out is PendingLib:
		return out.then(func(v): return _result(id, tool_result(v)))
	return _result(id, tool_result(out))


## The MCP CallToolResult for a tool value. Tool errors are reported in-band
## (isError), not as JSON-RPC errors.
static func tool_result(out) -> Dictionary:
	if out is Dictionary and out.get("__error__", false):
		return {
			"content": [{"type": "text", "text": JSON.stringify(out.get("msg", "error"))}],
			"isError": true
		}
	if out is Dictionary and out.has("__content__"):
		return {"content": out["__content__"], "isError": bool(out.get("isError", false))}
	var r := {"content": [{"type": "text", "text": JSON.stringify(out)}], "isError": false}
	if out is Dictionary:
		r["structuredContent"] = out
	return r


func _provider_for(name: String):
	for p in providers:
		for t in p.tool_defs():
			if t.get("name", "") == name:
				return p
	return null


# --- tool registry -----------------------------------------------------------
# Tool name == MCPCommands dispatch command; arguments pass straight through.


func _tool_defs() -> Array:
	return [
		["ping", "Check the bridge; returns the Godot engine version.", {}],
		["get_scene_tree", "Dump the edited scene's node tree.", {"max_depth": "integer"}],
		["get_node", "Get a node and its editor properties.", {"path": "string"}],
		[
			"get_property",
			"Read any property of a node by name.",
			{"path": "string", "property": "string"}
		],
		[
			"set_property",
			"Set any property of a node by name.",
			{"path": "string", "property": "string", "value": "any"}
		],
		[
			"call_method",
			"Call any method on a node by name.",
			{"path": "string", "method": "string", "args": "array"}
		],
		["list_methods", "List a node's callable methods.", {"path": "string"}],
		["list_properties", "List a node's editor properties.", {"path": "string"}],
		[
			"create_node",
			"Create a node of a class under a parent.",
			{"parent": "string", "type": "string", "name": "string"}
		],
		["delete_node", "Delete a node (not the root).", {"path": "string"}],
		[
			"reparent_node",
			"Move a node under a new parent.",
			{"path": "string", "new_parent": "string"}
		],
		[
			"set_script",
			"Attach a script (res://…) to a node.",
			{"path": "string", "script": "string"}
		],
		["run_script", "Run a GDScript snippet (body of run(editor, root)).", {"source": "string"}],
		["open_scene", "Open a scene by res:// path.", {"path": "string"}],
		["save_scene", "Save the edited scene.", {}],
		["get_open_scene", "Path + root of the edited scene.", {}],
		["list_scenes", "List all res:// .tscn scenes.", {}],
		["play_scene", "Run the current (or given) scene.", {"path": "string"}],
		["play_main", "Run the project's main scene.", {}],
		["stop", "Stop the running scene.", {}],
		["is_playing", "Whether a scene is playing.", {}],
		[
			"get_performance",
			"Godot Performance monitors (fps, memory, draw calls…).",
			{"monitors": "array"}
		],
		["read_log", "Read the editor Output console (best-effort).", {"lines": "integer"}],
		["screenshot", "Capture the editor viewport to a PNG.", {"path": "string"}],
		# profiling / diagnostics
		["list_monitors", "List available Performance monitor keys.", {}],
		["get_memory_info", "Static memory usage + peak.", {}],
		["get_os_info", "OS name/model/locale/processor/threads.", {}],
		["get_video_info", "Video adapter name/vendor/API.", {}],
		["get_render_info", "RenderingServer frame stats (objects/primitives/draw calls/mem).", {}],
		["copy_file", "Copy a file.", {"from": "string", "to": "string"}],
		["move_file", "Move/rename a file.", {"from": "string", "to": "string"}],
		["make_dir", "Create a directory (recursive).", {"path": "string"}],
		[
			"create_resource",
			"Create + save a Resource of a class.",
			{"class": "string", "path": "string"}
		],
		# project / assets
		["read_file", "Read a text file (res:// or user://).", {"path": "string"}],
		["write_file", "Write text to a file.", {"path": "string", "text": "string"}],
		["file_exists", "Whether a file or dir exists.", {"path": "string"}],
		["delete_file", "Delete a file.", {"path": "string"}],
		["list_dir", "List files + subdirs of a directory.", {"path": "string"}],
		[
			"find_files",
			"Recursively find files by extension under a root.",
			{"root": "string", "ext": "string"}
		],
		["create_script", "Write a new GDScript file.", {"path": "string", "source": "string"}],
		[
			"create_scene",
			"Create + save a new .tscn with a typed root.",
			{"path": "string", "root_type": "string", "root_name": "string"}
		],
		[
			"instance_scene",
			"Instance a PackedScene under a parent.",
			{"scene": "string", "parent": "string"}
		],
		[
			"save_branch_as_scene",
			"Pack a node subtree and save it as a .tscn.",
			{"path": "string", "scene": "string"}
		],
		[
			"reimport_asset",
			"Reimport one or more assets after their source changed on disk (EditorFileSystem.reimport_files) — the analogue of Unity-MCP's asset refresh. Pass a single 'path' or a 'paths' array of res:// paths.",
			{"path": "string", "paths": "array"}
		],
		[
			"rescan_filesystem",
			"Rescan the project filesystem for added/removed/changed files (EditorFileSystem.scan).",
			{}
		],
		["get_project_setting", "Read a ProjectSettings value.", {"setting": "string"}],
		[
			"set_project_setting",
			"Set a ProjectSettings value.",
			{"setting": "string", "value": "any"}
		],
		# scene / hierarchy
		["duplicate_node", "Duplicate a node under its parent.", {"path": "string"}],
		[
			"move_child",
			"Reorder a node among its siblings.",
			{"path": "string", "to_index": "integer"}
		],
		["add_to_group", "Add a node to a group.", {"path": "string", "group": "string"}],
		["remove_from_group", "Remove a node from a group.", {"path": "string", "group": "string"}],
		["get_nodes_in_group", "Paths of nodes in a group.", {"group": "string"}],
		[
			"find_nodes",
			"Find nodes by name pattern and/or type.",
			{"name": "string", "type": "string"}
		],
		["get_node_count", "Count nodes under the scene root.", {}],
		# spatial: transforms / bounds / skeleton (geometry diagnosis)
		[
			"get_transform",
			"Get a Node3D's local and global Transform3D plus world position, rotation (degrees) and scale. Transforms come back as Godot-native JSON (JSON.from_native).",
			{"path": "string"}
		],
		[
			"get_aabb",
			"World-space bounding box (min/max/size/center) merged over every VisualInstance3D in a node's subtree (default: whole scene). Use it to frame a camera or spot a mesh that is offset/splayed out of place.",
			{"path": "string"}
		],
		[
			"get_bone_poses",
			"Dump a Skeleton3D's bones — name, parent index, rest, local pose and global pose transforms (Godot-native JSON). Use to diagnose skeletal offsets, e.g. a shoulder/clavicle bone whose bind or rest transform is wrong. Optional 'bones' filters to specific bone names.",
			{"path": "string", "bones": "array"}
		],
		# reflection: ClassDB / signals / singletons
		["class_exists", "Whether a Godot class exists.", {"class": "string"}],
		[
			"get_class_methods",
			"Methods of a class (ClassDB).",
			{"class": "string", "no_inheritance": "boolean"}
		],
		[
			"get_class_properties",
			"Properties of a class (ClassDB).",
			{"class": "string", "no_inheritance": "boolean"}
		],
		["list_signals", "Signals of a node.", {"path": "string"}],
		[
			"emit_signal",
			"Emit a node signal.",
			{"path": "string", "signal": "string", "args": "array"}
		],
		[
			"connect_signal",
			"Connect a node signal to a target method.",
			{"path": "string", "signal": "string", "target": "string", "method": "string"}
		],
		[
			"call_singleton",
			"Call a method on an Engine singleton (Input, OS…).",
			{"singleton": "string", "method": "string", "args": "array"}
		],
		["get_editor_setting", "Read an EditorSettings value.", {"setting": "string"}],
	]


## Built-in tool names after the `allow` trim.
func _builtin_names() -> PackedStringArray:
	var names := PackedStringArray()
	for t in _tool_defs():
		if allow.is_empty() or allow.has(t[0]):
			names.append(t[0])
	return names


# MCP REQUIRES inputSchema to be a JSON Schema (clients validate tool arguments
# against it) — JSON-LD is not accepted here, so JSON Schema is the only correct
# choice for the tool surface. (A JSON-LD @context could annotate the avatar/USD
# *domain* separately, but not the MCP inputSchema.)
const _OPTIONAL_PARAMS := [
	"max_depth", "name", "args", "monitors", "default", "no_inheritance", "lines", "bones", "paths"
]
const _ALL_OPTIONAL_TOOLS := [
	"play_scene",
	"screenshot",
	"get_performance",
	"find_nodes",
	"read_log",
	"get_aabb",
	"reimport_asset"
]

## Built-in tools that only read. Clients show the hint; a page can list only these.
const READ_ONLY := [
	"ping",
	"get_scene_tree",
	"get_node",
	"get_property",
	"list_methods",
	"list_properties",
	"get_open_scene",
	"list_scenes",
	"is_playing",
	"get_performance",
	"read_log",
	"list_monitors",
	"get_memory_info",
	"get_os_info",
	"get_video_info",
	"get_render_info",
	"read_file",
	"file_exists",
	"list_dir",
	"find_files",
	"get_project_setting",
	"get_nodes_in_group",
	"find_nodes",
	"get_node_count",
	"get_transform",
	"get_aabb",
	"get_bone_poses",
	"class_exists",
	"get_class_methods",
	"get_class_properties",
	"list_signals",
	"get_editor_setting"
]


## tools/list: provider tools first, then the built-ins they do not hide.
func tool_schemas() -> Array:
	var out := []
	var taken := {}
	for p in providers:
		for t in p.tool_defs():
			if not taken.has(t.get("name", "")):
				taken[t.get("name", "")] = true
				out.append(t)
	var keep := _builtin_names()
	for t in _tool_defs():
		if taken.has(t[0]) or not keep.has(t[0]):
			continue
		var props := {}
		var required := []
		for pname in t[2]:
			var ptype: String = t[2][pname]
			props[pname] = {} if ptype == "any" else {"type": ptype}
			if not (t[0] in _ALL_OPTIONAL_TOOLS) and not (pname in _OPTIONAL_PARAMS):
				required.append(pname)
		var schema := {"type": "object", "properties": props, "additionalProperties": false}
		if not required.is_empty():
			schema["required"] = required
		var tool := {"name": t[0], "description": t[1], "inputSchema": schema}
		if t[0] in READ_ONLY:
			tool["annotations"] = {"readOnlyHint": true}
		out.append(tool)
	return out
