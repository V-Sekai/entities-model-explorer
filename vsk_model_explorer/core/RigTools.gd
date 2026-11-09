extends Node
# The desktop viewer's MCP tools (addons/vsekai_godot_mcp, provider in project.godot): an MCP
# client opens a model, auto-rigs it and takes the result. Rigging is the R key's work
# (AutoRig.gd): it runs on the local GPU with the weights in `w`; these tools wait for it and
# report the result. The web build leaves the server out (guest/build.py).
# The built-in tools that stay (project.godot vsekai_godot_mcp/allow) only read the scene.

const PendingLib = preload("res://addons/vsekai_godot_mcp/mcp_pending.gd")
const AUTO_RIG := "res://vsk_model_explorer/core/AutoRig.gd"
const PERSONA := "res://vsk_model_explorer/core/Persona.gd"
const MODEL_EXTENSIONS := ["glb", "gltf", "vrm", "fbx", "usd", "usda", "usdc", "usdz"]
# get_file sends a file as base64 in one message; larger files are refused.
const MAX_FILE_BYTES := 64 << 20
const LOAD_SECONDS := 180.0
const RIG_SECONDS := 1800.0

var last_result := ""
var _auto_rig: Node
var _persona: RefCounted


func tool_defs() -> Array:
	return [
		_tool(
			"status",
			"What the viewer has open, whether it can rig here, and the last result.",
			{},
			[],
			true
		),
		_tool(
			"load_model",
			"Open a model in the viewer: .glb, .gltf, .vrm, .fbx or OpenUSD. Give one of path (a file on this computer), url (https), or data_base64 with name.",
			{
				"path": {"type": "string"},
				"url": {"type": "string"},
				"data_base64": {"type": "string"},
				"name":
				{"type": "string", "description": "File name with its extension, for data_base64."}
			},
			[],
			false
		),
		_tool(
			"auto_rig",
			"Auto-rig the open model (or first open path/url/data_base64). A model that has the shape of a person is saved as a VRM 1.0 file (.vrm) with a .unitypackage; any other rig as .rigged.glb. A .vrm input is put in a T-pose. The viewer then shows the result. Takes seconds to minutes.",
			{
				"path": {"type": "string"},
				"url": {"type": "string"},
				"data_base64": {"type": "string"},
				"name": {"type": "string"},
				"skip_rig":
				{
					"type": "boolean",
					"description":
					"Keep the .glb's own skeleton and weights and only make the .vrm."
				}
			},
			[],
			false
		),
		_tool(
			"get_file",
			"Send a file back as an embedded resource (base64). Default: the last auto_rig result.",
			{"path": {"type": "string"}},
			[],
			true
		),
		_tool(
			"screenshot",
			"A PNG of the viewer as it is now.",
			{
				"max_width":
				{"type": "integer", "description": "Scale down to this width (default 1024)."}
			},
			[],
			true
		),
		_tool(
			"persona_ask",
			"Ask the persona for a plan: a domain and a goal in, an exact plan out, with no weights and no sampling. An empty goal means the domain's own default. Answers the plan as JSON, or the refusal by name.",
			{"goal": {"type": "string"}},
			[],
			true
		),
	]


func _tool(
	name: String, description: String, props: Dictionary, required: Array, read_only: bool
) -> Dictionary:
	var schema := {"type": "object", "properties": props, "additionalProperties": false}
	if not required.is_empty():
		schema["required"] = required
	return {
		"name": name,
		"description": description,
		"inputSchema": schema,
		"annotations": {"readOnlyHint": read_only, "openWorldHint": false}
	}


func call_tool(name: String, args: Dictionary):
	match name:
		"status":
			return _status()
		"get_file":
			return _get_file(args)
		"load_model":
			return _later(_load_model, args)
		"auto_rig":
			return _later(_rig, args)
		"screenshot":
			return _later(_screenshot, args)
		"persona_ask":
			return _persona_ask(args)
	return _err("unknown tool " + name)


# The scene the built-in read tools see: Model Explorer itself.
func scene_root():
	var ar := _rig_node()
	return ar.get_parent() if ar else null


static func _err(msg: String) -> Dictionary:
	return {"__error__": true, "msg": msg}


func _later(f: Callable, args: Dictionary):
	var p = PendingLib.new()
	_run.call_deferred(f, args, p)
	return p


func _run(f: Callable, args: Dictionary, p) -> void:
	p.finish(await f.call(args))


func _rig_node() -> Node:
	if is_instance_valid(_auto_rig):
		return _auto_rig
	_auto_rig = _find(get_tree().root)
	return _auto_rig


func _find(n: Node) -> Node:
	var s: Script = n.get_script()
	if s and s.resource_path == AUTO_RIG:
		return n
	for c in n.get_children():
		var r := _find(c)
		if r:
			return r
	return null


func _status() -> Dictionary:
	var ar := _rig_node()
	if ar == null:
		return _err("the viewer is still starting")
	return {
		"can_rig": ar.available(),
		"busy": ar.busy,
		"open_model": ar.source,
		"last_result": last_result,
		"message": ar._label.text if ar._label else "",
	}


# --- persona_ask ------------------------------------------------------------------------------


# The persona's own answer: a plan, or a refusal by name. No model is involved and nothing
# in the scene changes, so the call is read-only and immediate.
func _persona_ask(args: Dictionary) -> Dictionary:
	if _persona == null:
		_persona = load(PERSONA).new()
	var answer: Dictionary = _persona.ask(self, String(args.get("goal", "")))
	if answer.has("error"):
		return _err(answer["error"])
	return answer


# --- load_model -------------------------------------------------------------------------------


func _load_model(args: Dictionary):
	var ar := _rig_node()
	if ar == null:
		return _err("the viewer is still starting")
	var path = await _fetch_input(args)
	if path is Dictionary:
		return path
	var why = await _open(path)
	if why != "":
		return _err(why)
	return {"open_model": ar.source, "file": path.get_file()}


# A local path for the model given by path, url or data_base64; an error Dictionary otherwise.
func _fetch_input(args: Dictionary):
	var dir := OS.get_user_data_dir().path_join("mcp")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := String(args.get("path", ""))
	if args.has("data_base64"):
		var name := String(args.get("name", "")).get_file()
		if not name.get_extension().to_lower() in MODEL_EXTENSIONS:
			return _err("name needs one of the extensions " + ", ".join(MODEL_EXTENSIONS))
		path = dir.path_join(name)
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return _err("cannot write " + path)
		f.store_buffer(Marshalls.base64_to_raw(String(args.data_base64)))
		f.close()
	elif args.has("url"):
		var url := String(args.url)
		var name := String(args.get("name", url.get_file().split("?")[0]))
		if not name.get_extension().to_lower() in MODEL_EXTENSIONS:
			return _err(
				"the url (or name) needs one of the extensions " + ", ".join(MODEL_EXTENSIONS)
			)
		path = dir.path_join(name.get_file())
		var why = await _download(url, path)
		if why != "":
			return _err(why)
	if path == "":
		return _err("give path, url or data_base64")
	if path.begins_with("res://") or path.begins_with("user://"):
		path = ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(path):
		return _err("no file at " + path)
	if not path.get_extension().to_lower() in MODEL_EXTENSIONS:
		return _err("the viewer opens " + ", ".join(MODEL_EXTENSIONS))
	return path


func _download(url: String, path: String) -> String:
	var req := HTTPRequest.new()
	req.download_file = path
	req.max_redirects = 8
	add_child(req)
	if req.request(url) != OK:
		req.queue_free()
		return "cannot request " + url
	var r: Array = await req.request_completed
	req.queue_free()
	if r[0] != HTTPRequest.RESULT_SUCCESS or r[1] >= 400:
		return "download failed: result %d, HTTP %d" % [r[0], r[1]]
	return ""


# Opens a file in the viewer and waits until its scene is in the tree. "" when it is.
func _open(path: String) -> String:
	var explorer: Node = _rig_node().get_parent()
	var before := _models()
	var failed := [false]
	var on_fail := func(ok: bool, _n): failed[0] = failed[0] or not ok
	for s in ["gltf_is_loaded", "fbx_is_loaded"]:
		if explorer.has_signal(s):
			explorer.connect(s, on_fail)
	explorer.call("_load_file", path)
	var why = await _wait_new_model(before, path, failed)
	for s in ["gltf_is_loaded", "fbx_is_loaded"]:
		if explorer.has_signal(s) and explorer.is_connected(s, on_fail):
			explorer.disconnect(s, on_fail)
	return why


# Waits until a model scene that was not in `before` is in the tree. "" when one is.
func _wait_new_model(before: Array, path: String, failed := [false]) -> String:
	var t0 := Time.get_ticks_msec()
	while true:
		await get_tree().process_frame
		if failed[0]:
			return "the viewer could not open " + path.get_file()
		for n in _models():
			if not before.has(n) and n.is_inside_tree() and not n.is_queued_for_deletion():
				return ""
		if Time.get_ticks_msec() - t0 > LOAD_SECONDS * 1000.0:
			return "the viewer did not open %s in %d s" % [path.get_file(), LOAD_SECONDS]
	return ""


func _models() -> Array:
	var out: Array = get_tree().get_nodes_in_group("gltf group")
	out.append_array(get_tree().get_nodes_in_group("fbx group"))
	return out


# --- auto_rig ---------------------------------------------------------------------------------


func _rig(args: Dictionary):
	var ar := _rig_node()
	if ar == null:
		return _err("the viewer is still starting")
	if ar.busy:
		return _err("the viewer is rigging already")
	if args.has("path") or args.has("url") or args.has("data_base64"):
		var opened = await _load_model(args)
		if opened.get("__error__", false):
			return opened
	if ar.source == "":
		return _err("open a model first (load_model)")
	var ext: String = ar.source.get_extension().to_lower()
	if ext != "glb" and ext != "vrm":
		return _err(
			"auto_rig reads .glb and .vrm files (a USD file is rigged from its GLB: open it first)"
		)
	var t0 := Time.get_ticks_msec()
	var out
	if bool(args.get("skip_rig", false)) and ext == "glb":
		out = await _vrm_only(ar)
	else:
		out = await _rig_desktop(ar)
	if out is Dictionary:
		return out
	last_result = out
	var result := {
		"result": out,
		"file": out.get_file(),
		"vrm": out.ends_with(".vrm"),
		"seconds": (Time.get_ticks_msec() - t0) / 1000.0
	}
	if out.ends_with(".vrm") and ar.package_path != "":
		result["unitypackage"] = ar.package_path
	return result


func _rig_desktop(ar: Node):
	if not ar.available():
		return _err("this download has no rig weights (w folder); the SkinTokens viewer has them")
	var got := [""]
	var on_rigged := func(p: String): got[0] = p
	ar.rigged.connect(on_rigged, CONNECT_ONE_SHOT)
	var before := _models()
	await ar.start()
	if ar.rigged.is_connected(on_rigged):
		ar.rigged.disconnect(on_rigged)
	if got[0] == "":
		return _err(
			ar._label.text if ar._label and ar._label.text != "" else "the rig did not finish"
		)
	# rigged told the viewer to open the result; wait until it shows.
	var why = await _wait_new_model(before, got[0])
	if why != "":
		return _err(why)
	return got[0]


# skip_rig: the .glb's own rig becomes a .vrm beside it when it passes the humanoid gates.
func _vrm_only(ar: Node):
	var source: String = ar.source
	if not ar.has_skin(source):
		return _err(source.get_file() + " has no skin: run auto_rig without skip_rig")
	var stem := source.get_basename().trim_suffix(".rigged").trim_suffix("-rigged")
	ar.busy = true
	var out: String = await ar.rigged_to_vrm(source, stem)
	ar.busy = false
	if out == "":
		return _err(
			"this rig does not have the shape of a person, so it is not saved as a .vrm file"
		)
	var why = await _open(out)
	if why != "":
		return _err(why)
	ar.show_saved.call_deferred(out.get_file())
	return out


# --- get_file, screenshot ---------------------------------------------------------------------


func _get_file(args: Dictionary):
	var path := String(args.get("path", last_result))
	if path == "":
		return _err("no result yet: run auto_rig, or give path")
	if path.begins_with("res://") or path.begins_with("user://"):
		path = ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(path):
		return _err("no file at " + path)
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() > MAX_FILE_BYTES:
		return _err(
			(
				"%s is %d MB; get_file sends up to %d MB"
				% [path.get_file(), bytes.size() >> 20, MAX_FILE_BYTES >> 20]
			)
		)
	var mime: String = (
		{
			"vrm": "model/gltf-binary",
			"glb": "model/gltf-binary",
			"gltf": "model/gltf+json",
			"unitypackage": "application/gzip",
			"png": "image/png",
		}
		. get(path.get_extension().to_lower(), "application/octet-stream")
	)
	return {
		"__content__":
		[
			{
				"type": "text",
				"text":
				JSON.stringify({"file": path.get_file(), "bytes": bytes.size(), "mimeType": mime})
			},
			{
				"type": "resource",
				"resource":
				{
					"uri": "file://" + path.uri_encode().replace("%2F", "/"),
					"mimeType": mime,
					"blob": Marshalls.raw_to_base64(bytes)
				}
			},
		]
	}


func _screenshot(args: Dictionary):
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		return _err("the viewport gave no image")
	var w := int(args.get("max_width", 1024))
	if w > 0 and img.get_width() > w:
		img.resize(w, int(img.get_height() * float(w) / img.get_width()), Image.INTERPOLATE_LANCZOS)
	return {
		"__content__":
		[
			{
				"type": "image",
				"data": Marshalls.raw_to_base64(img.save_png_to_buffer()),
				"mimeType": "image/png"
			},
		]
	}
