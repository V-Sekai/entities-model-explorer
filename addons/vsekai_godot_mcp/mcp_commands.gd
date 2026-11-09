@tool
extends RefCounted
class_name MCPCommands
## Pure command logic for the Godot MCP bridge — transport-free so it can be
## unit-tested headless (see addons/vsekai_godot_mcp/tests/). The EditorPlugin
## (mcp_bridge.gd) injects `root` (the edited scene root) and `editor` (the
## EditorInterface, or null in tests) per request and calls dispatch().
##
## Returns plain JSON-able values; an error is the dict {"__error__": true,
## "msg": ...} which the transport turns into {"ok": false, "error": ...}.

var root: Node = null  # scene root the commands operate on
var editor = null  # EditorInterface (null in headless tests)


func dispatch(cmd: String, a: Dictionary):
	match cmd:
		"ping":
			return {"pong": true, "engine": Engine.get_version_info()}
		"get_scene_tree":
			return _cmd_get_scene_tree(a)
		"get_node":
			return _cmd_get_node(a)
		"get_property":
			return _cmd_get_property(a)
		"set_property":
			return _cmd_set_property(a)
		"call_method":
			return _cmd_call_method(a)
		"list_methods":
			return _cmd_list_members(a, true)
		"list_properties":
			return _cmd_list_members(a, false)
		"create_node":
			return _cmd_create_node(a)
		"delete_node":
			return _cmd_delete_node(a)
		"reparent_node":
			return _cmd_reparent_node(a)
		"set_script":
			return _cmd_set_script(a)
		"run_script":
			return _cmd_run_script(a)
		"list_scenes":
			return {"scenes": _scan_ext("res://", ".tscn")}
		# --- editor-only (require EditorInterface) ---
		"open_scene":
			return (
				_need_editor()
				if editor == null
				else _ok(editor.open_scene_from_path(String(a.get("path", ""))))
			)
		"save_scene":
			return _need_editor() if editor == null else _ok(editor.save_scene())
		"reimport_asset":
			return _cmd_reimport(a)
		"rescan_filesystem":
			return _cmd_rescan(a)
		"get_open_scene":
			if editor == null:
				return _need_editor()
			var r = editor.get_edited_scene_root()
			return {"path": r.scene_file_path if r else "", "root": _node_brief(r) if r else null}
		"play_scene":
			if editor == null:
				return _need_editor()
			if a.has("path") and String(a["path"]) != "":
				editor.play_custom_scene(String(a["path"]))
			else:
				editor.play_current_scene()
			return {"playing": true}
		"play_main":
			if editor == null:
				return _need_editor()
			editor.play_main_scene()
			return {"playing": true}
		"stop":
			if editor == null:
				return _need_editor()
			editor.stop_playing_scene()
			return {"playing": false}
		"is_playing":
			if editor == null:
				return _need_editor()
			return {"playing": editor.is_playing_scene()}
		"read_log":
			return _cmd_read_log(a)
		"screenshot":
			return _cmd_screenshot(a)
		# --- profiling / diagnostics ---
		"get_performance":
			return _cmd_get_performance(a)
		"list_monitors":
			return {
				"monitors":
				[
					"fps",
					"frame_time",
					"physics_frame_time",
					"static_memory",
					"object_count",
					"node_count",
					"resource_count",
					"draw_calls",
					"video_memory"
				]
			}
		"get_memory_info":
			return {
				"static": OS.get_static_memory_usage(),
				"static_peak": OS.get_static_memory_peak_usage()
			}
		"get_os_info":
			return {
				"name": OS.get_name(),
				"model": OS.get_model_name(),
				"locale": OS.get_locale(),
				"processor": OS.get_processor_name(),
				"threads": OS.get_processor_count()
			}
		"get_video_info":
			return {
				"adapter": RenderingServer.get_video_adapter_name(),
				"vendor": RenderingServer.get_video_adapter_vendor(),
				"api": RenderingServer.get_video_adapter_api_version()
			}
		"get_render_info":
			return _cmd_get_render_info(a)
		"copy_file":
			return _cmd_copy_file(a)
		"move_file":
			return _cmd_move_file(a)
		"make_dir":
			return _cmd_make_dir(a)
		"create_resource":
			return _cmd_create_resource(a)
		# --- project / assets ---
		"read_file":
			return _cmd_read_file(a)
		"write_file":
			return _cmd_write_file(a)
		"file_exists":
			return {
				"exists":
				(
					FileAccess.file_exists(String(a.get("path", "")))
					or DirAccess.dir_exists_absolute(
						ProjectSettings.globalize_path(String(a.get("path", "")))
					)
				)
			}
		"delete_file":
			return _cmd_delete_file(a)
		"list_dir":
			return _cmd_list_dir(a)
		"find_files":
			return {"files": _scan_ext(String(a.get("root", "res://")), String(a.get("ext", "")))}
		"create_script":
			return _cmd_create_script(a)
		"create_scene":
			return _cmd_create_scene(a)
		"instance_scene":
			return _cmd_instance_scene(a)
		"save_branch_as_scene":
			return _cmd_save_branch_as_scene(a)
		"get_project_setting":
			return {
				"value":
				_to_json(
					ProjectSettings.get_setting(String(a.get("setting", "")), a.get("default"))
				)
			}
		"set_project_setting":
			ProjectSettings.set_setting(
				String(a.get("setting", "")), _coerce(a.get("value"), TYPE_NIL)
			)
			return {"ok": true}
		# --- scene / hierarchy ---
		"duplicate_node":
			return _cmd_duplicate_node(a)
		"move_child":
			return _cmd_move_child(a)
		"add_to_group":
			return _cmd_group(a, true)
		"remove_from_group":
			return _cmd_group(a, false)
		"get_nodes_in_group":
			return _cmd_get_nodes_in_group(a)
		"find_nodes":
			return _cmd_find_nodes(a)
		"get_node_count":
			return {"count": _count_descendants(root)}
		# --- spatial: transforms / bounds / skeleton (geometry diagnosis) ---
		"get_transform":
			return _cmd_get_transform(a)
		"get_aabb":
			return _cmd_get_aabb(a)
		"get_bone_poses":
			return _cmd_get_bone_poses(a)
		# --- scripting / reflection (ClassDB + signals + singletons) ---
		"class_exists":
			return {"exists": ClassDB.class_exists(String(a.get("class", "")))}
		"get_class_methods":
			return _cmd_class_members(a, true)
		"get_class_properties":
			return _cmd_class_members(a, false)
		"list_signals":
			return _cmd_list_signals(a)
		"emit_signal":
			return _cmd_emit_signal(a)
		"connect_signal":
			return _cmd_connect_signal(a)
		"call_singleton":
			return _cmd_call_singleton(a)
		"get_editor_setting":
			if editor == null:
				return _need_editor()
			return {
				"value":
				_to_json(editor.get_editor_settings().get_setting(String(a.get("setting", ""))))
			}
		_:
			return _err("unknown cmd: " + cmd)


# --- helpers: errors ---------------------------------------------------------


func _err(msg: String) -> Dictionary:
	return {"__error__": true, "msg": msg}


func _need_editor() -> Dictionary:
	return _err("EditorInterface not available in this context")


func _ok(_v = null) -> Dictionary:
	return {"ok": true}


# --- scene tree / nodes ------------------------------------------------------


func _resolve(path: String) -> Node:
	if root == null:
		return null
	if path == "" or path == "." or path == "/root" or path == root.name:
		return root
	return root.get_node_or_null(NodePath(path))


func _cmd_get_scene_tree(a: Dictionary):
	if root == null:
		return _err("no scene root")
	return _node_tree(root, root, clampi(int(a.get("max_depth", 64)), 0, 256))


func _node_tree(n: Node, r: Node, depth: int) -> Dictionary:
	var d := _node_brief(n)
	d["path"] = String(r.get_path_to(n)) if n != r else "."
	var kids := []
	if depth > 0:
		for child in n.get_children():
			kids.append(_node_tree(child, r, depth - 1))
	d["children"] = kids
	return d


func _node_brief(n: Node) -> Dictionary:
	if n == null:
		return {}
	return {
		"name": String(n.name),
		"type": n.get_class(),
		"script": n.get_script().resource_path if n.get_script() else ""
	}


func _cmd_get_node(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found: " + String(a.get("path", "")))
	var props := {}
	for p in n.get_property_list():
		if int(p.usage) & PROPERTY_USAGE_EDITOR:
			props[p.name] = _to_json(n.get(p.name))
	var brief := _node_brief(n)
	brief["properties"] = props
	return brief


func _cmd_create_node(a: Dictionary):
	var parent := _resolve(String(a.get("parent", "")))
	if parent == null:
		return _err("parent not found: " + String(a.get("parent", "")))
	var type := String(a.get("type", "Node"))
	if not ClassDB.class_exists(type) or not ClassDB.can_instantiate(type):
		return _err("cannot instantiate type: " + type)
	if not ClassDB.is_parent_class(type, "Node"):
		return _err("type is not a Node: " + type)
	var node: Node = ClassDB.instantiate(type)
	node.name = String(a.get("name", type))
	parent.add_child(node)
	node.owner = root
	return {"created": String(root.get_path_to(node))}


func _cmd_delete_node(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	if n == root:
		return _err("refusing to delete the scene root")
	n.get_parent().remove_child(n)
	n.queue_free()
	return {"deleted": true}


func _cmd_reparent_node(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	var new_parent := _resolve(String(a.get("new_parent", "")))
	if n == null or new_parent == null:
		return _err("node or new_parent not found")
	if n is Node3D and bool(a.get("keep_global_transform", true)):
		n.reparent(new_parent, true)
	else:
		n.get_parent().remove_child(n)
		new_parent.add_child(n)
		n.owner = root
	return {"reparented": String(root.get_path_to(n))}


func _cmd_set_script(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	var res := load(String(a.get("script", "")))
	if res == null:
		return _err("could not load script: " + String(a.get("script", "")))
	n.set_script(res)
	return {"ok": true}


# --- reflection --------------------------------------------------------------


func _cmd_get_property(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	return {"value": _to_json(n.get(String(a.get("property", ""))))}


func _cmd_set_property(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	var prop := String(a.get("property", ""))
	n.set(prop, _coerce(a.get("value"), typeof(n.get(prop))))
	return {"value": _to_json(n.get(prop))}


const _BLOCKED_METHODS := ["free", "queue_free", "set_owner"]


func _cmd_call_method(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	var method := String(a.get("method", ""))
	if method in _BLOCKED_METHODS:
		return _err("method '%s' is blocked via call_method (use delete_node)" % method)
	if not n.has_method(method):
		return _err("no such method: " + method)
	var raw = a.get("args", [])
	var call_args := []
	if raw is Array:
		for v in raw:
			call_args.append(_coerce(v, TYPE_NIL))
	return {"value": _to_json(n.callv(method, call_args))}


func _cmd_list_members(a: Dictionary, methods: bool):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	var out := []
	if methods:
		for m in n.get_method_list():
			out.append({"name": m.name, "args": m.args.size()})
	else:
		for p in n.get_property_list():
			if int(p.usage) & PROPERTY_USAGE_EDITOR:
				out.append({"name": p.name, "type": p.type})
	return {"members": out}


func _cmd_run_script(a: Dictionary):
	var indented := ""
	for ln in String(a.get("source", "")).split("\n"):
		indented += "\t" + ln + "\n"
	var src := "extends RefCounted\nfunc run(editor, root):\n" + indented + "\tpass\n"
	var gd := GDScript.new()
	gd.source_code = src
	var perr := gd.reload()
	if perr != OK:
		return _err("GDScript compile failed (err %d)" % perr)
	var inst = gd.new()
	return {"value": _to_json(inst.call("run", editor, root))}


# --- profiling (parity with Unity-MCP diagnostics) --------------------------


func _cmd_get_performance(a: Dictionary):
	# Expose Godot's Performance monitors (fps, mem, draw calls, object counts…).
	var names := {
		"fps": Performance.TIME_FPS,
		"frame_time": Performance.TIME_PROCESS,
		"physics_frame_time": Performance.TIME_PHYSICS_PROCESS,
		"static_memory": Performance.MEMORY_STATIC,
		"object_count": Performance.OBJECT_COUNT,
		"node_count": Performance.OBJECT_NODE_COUNT,
		"resource_count": Performance.OBJECT_RESOURCE_COUNT,
		"draw_calls": Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME,
		"video_memory": Performance.RENDER_VIDEO_MEM_USED,
	}
	var out := {}
	var want = a.get("monitors", [])
	for key in names:
		if typeof(want) == TYPE_ARRAY and want.size() > 0 and not (key in want):
			continue
		out[key] = Performance.get_monitor(names[key])
	return {"monitors": out}


# --- project / assets -------------------------------------------------------


func _cmd_read_file(a: Dictionary):
	var path := String(a.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err("file not found: " + path)
	return {"text": FileAccess.open(path, FileAccess.READ).get_as_text()}


func _cmd_write_file(a: Dictionary):
	var f := FileAccess.open(String(a.get("path", "")), FileAccess.WRITE)
	if f == null:
		return _err("cannot open for write: " + String(a.get("path", "")))
	f.store_string(String(a.get("text", "")))
	f.close()
	return {"ok": true}


func _cmd_delete_file(a: Dictionary):
	var g := ProjectSettings.globalize_path(String(a.get("path", "")))
	var err := DirAccess.remove_absolute(g)
	return {"ok": true} if err == OK else _err("delete failed (%d)" % err)


func _cmd_list_dir(a: Dictionary):
	var path := String(a.get("path", "res://"))
	var d := DirAccess.open(path)
	if d == null:
		return _err("cannot open dir: " + path)
	var files := []
	var dirs := []
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if n != "." and n != "..":
			if d.current_is_dir():
				dirs.append(n)
			else:
				files.append(n)
		n = d.get_next()
	d.list_dir_end()
	return {"files": files, "dirs": dirs}


func _cmd_create_script(a: Dictionary):
	var path := String(a.get("path", ""))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _err("cannot write script: " + path)
	f.store_string(String(a.get("source", "extends Node\n")))
	f.close()
	return {"created": path}


func _cmd_create_scene(a: Dictionary):
	var type := String(a.get("root_type", "Node"))
	if not ClassDB.can_instantiate(type) or not ClassDB.is_parent_class(type, "Node"):
		return _err("cannot instantiate as a Node: " + type)
	var r: Node = ClassDB.instantiate(type)
	r.name = String(a.get("root_name", type))
	var ps := PackedScene.new()
	if ps.pack(r) != OK:
		r.free()
		return _err("pack failed")
	var werr := ResourceSaver.save(ps, String(a.get("path", "")))
	r.free()
	return {"created": String(a.get("path", ""))} if werr == OK else _err("save failed (%d)" % werr)


func _cmd_instance_scene(a: Dictionary):
	if root == null:
		return _err("no scene root")
	var scene = load(String(a.get("scene", "")))
	if scene == null or not (scene is PackedScene):
		return _err("not a PackedScene: " + String(a.get("scene", "")))
	var parent := _resolve(String(a.get("parent", ".")))
	if parent == null:
		return _err("parent not found")
	var inst: Node = scene.instantiate()
	parent.add_child(inst)
	inst.owner = root
	return {"instanced": String(root.get_path_to(inst))}


func _cmd_save_branch_as_scene(a: Dictionary):
	var n := _resolve(String(a.get("path", ".")))
	if n == null:
		return _err("node not found")
	var ps := PackedScene.new()
	if ps.pack(n) != OK:
		return _err("pack failed")
	var werr := ResourceSaver.save(ps, String(a.get("scene", "")))
	return {"saved": String(a.get("scene", ""))} if werr == OK else _err("save failed (%d)" % werr)


func _cmd_get_render_info(_a: Dictionary):
	var R := RenderingServer
	return {
		"objects": R.get_rendering_info(R.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"primitives": R.get_rendering_info(R.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"draw_calls": R.get_rendering_info(R.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"texture_mem": R.get_rendering_info(R.RENDERING_INFO_TEXTURE_MEM_USED),
		"buffer_mem": R.get_rendering_info(R.RENDERING_INFO_BUFFER_MEM_USED),
		"video_mem": R.get_rendering_info(R.RENDERING_INFO_VIDEO_MEM_USED),
	}


func _cmd_copy_file(a: Dictionary):
	var err := DirAccess.copy_absolute(
		ProjectSettings.globalize_path(String(a.get("from", ""))),
		ProjectSettings.globalize_path(String(a.get("to", "")))
	)
	return {"ok": true} if err == OK else _err("copy failed (%d)" % err)


func _cmd_move_file(a: Dictionary):
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(String(a.get("from", ""))),
		ProjectSettings.globalize_path(String(a.get("to", "")))
	)
	return {"ok": true} if err == OK else _err("move failed (%d)" % err)


func _cmd_make_dir(a: Dictionary):
	var err := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(String(a.get("path", "")))
	)
	return {"ok": true} if err == OK else _err("mkdir failed (%d)" % err)


func _cmd_create_resource(a: Dictionary):
	var cls := String(a.get("class", ""))
	if (
		not ClassDB.class_exists(cls)
		or not ClassDB.can_instantiate(cls)
		or not ClassDB.is_parent_class(cls, "Resource")
	):
		return _err("not an instantiable Resource: " + cls)
	var res = ClassDB.instantiate(cls)
	var werr := ResourceSaver.save(res, String(a.get("path", "")))
	return {"created": String(a.get("path", ""))} if werr == OK else _err("save failed (%d)" % werr)


# --- scene / hierarchy (more) -----------------------------------------------


func _cmd_duplicate_node(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	if n == root:
		return _err("cannot duplicate the scene root")
	var dup := n.duplicate()
	n.get_parent().add_child(dup)
	dup.owner = root
	return {"duplicated": String(root.get_path_to(dup))}


func _cmd_move_child(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	var parent := n.get_parent()
	if parent == null:
		return _err("node has no parent")
	var idx := clampi(int(a.get("to_index", 0)), 0, max(0, parent.get_child_count() - 1))
	parent.move_child(n, idx)
	return {"index": n.get_index()}


func _cmd_group(a: Dictionary, add: bool):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	if add:
		n.add_to_group(String(a.get("group", "")), true)
	else:
		n.remove_from_group(String(a.get("group", "")))
	return {"ok": true}


func _cmd_get_nodes_in_group(a: Dictionary):
	if root == null:
		return _err("no scene root")
	var g := String(a.get("group", ""))
	var out := []
	if root.is_in_group(g):
		out.append(".")
	for n in root.find_children("*", "", true, false):
		if n.is_in_group(g):
			out.append(String(root.get_path_to(n)))
	return {"nodes": out}


func _cmd_find_nodes(a: Dictionary):
	if root == null:
		return _err("no scene root")
	var pat := String(a.get("name", "*"))
	if pat == "":
		pat = "*"
	var out := []
	for n in root.find_children(pat, String(a.get("type", "")), true, false):
		out.append(
			{"path": String(root.get_path_to(n)), "type": n.get_class(), "name": String(n.name)}
		)
	return {"nodes": out}


func _count_descendants(n) -> int:
	if n == null:
		return 0
	var c := 1
	for ch in n.get_children():
		c += _count_descendants(ch)
	return c


# --- reflection: ClassDB / signals / singletons -----------------------------


func _cmd_class_members(a: Dictionary, methods: bool):
	var cls := String(a.get("class", ""))
	if not ClassDB.class_exists(cls):
		return _err("no such class: " + cls)
	var out := []
	var no_inherit := bool(a.get("no_inheritance", false))
	if methods:
		for m in ClassDB.class_get_method_list(cls, no_inherit):
			out.append(m.name)
	else:
		for p in ClassDB.class_get_property_list(cls, no_inherit):
			out.append(p.name)
	return {"members": out}


func _cmd_list_signals(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	var out := []
	for s in n.get_signal_list():
		out.append(s.name)
	return {"signals": out}


func _cmd_emit_signal(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	var args := [String(a.get("signal", ""))]
	var raw = a.get("args", [])
	if raw is Array:
		for v in raw:
			args.append(_coerce(v, TYPE_NIL))
	n.callv("emit_signal", args)
	return {"ok": true}


func _cmd_connect_signal(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	var target := _resolve(String(a.get("target", "")))
	if n == null or target == null:
		return _err("node or target not found")
	var err := n.connect(String(a.get("signal", "")), Callable(target, String(a.get("method", ""))))
	return {"ok": true} if err == OK else _err("connect failed (%d)" % err)


func _cmd_call_singleton(a: Dictionary):
	var sname := String(a.get("singleton", ""))
	if not Engine.has_singleton(sname):
		return _err("no such singleton: " + sname)
	var s = Engine.get_singleton(sname)
	var method := String(a.get("method", ""))
	if not s.has_method(method):
		return _err("singleton has no method: " + method)
	var args := []
	var raw = a.get("args", [])
	if raw is Array:
		for v in raw:
			args.append(_coerce(v, TYPE_NIL))
	return {"value": _to_json(s.callv(method, args))}


# --- logs / screenshot (need editor) ----------------------------------------


func _cmd_read_log(a: Dictionary):
	var n := int(a.get("lines", 100))
	if editor != null:
		var rtl := _find_editor_log_richtext(editor.get_base_control())
		if rtl != null:
			var text: String = (
				rtl.get_parsed_text()
				if rtl.has_method("get_parsed_text")
				else String(rtl.get("text"))
			)
			var lines := text.split("\n")
			return {
				"source": "editor_output",
				"lines": lines.slice(max(0, lines.size() - n), lines.size())
			}
	var path := "user://logs/godot.log"
	if FileAccess.file_exists(path):
		var all := FileAccess.open(path, FileAccess.READ).get_as_text().split("\n")
		return {"source": "log_file", "lines": all.slice(max(0, all.size() - n), all.size())}
	return {"lines": [], "note": "no EditorLog and file logging disabled"}


func _find_editor_log_richtext(node: Node) -> RichTextLabel:
	if node.get_class() == "EditorLog":
		var r := _first_richtext(node)
		if r != null:
			return r
	for child in node.get_children():
		var found := _find_editor_log_richtext(child)
		if found != null:
			return found
	return null


func _first_richtext(node: Node) -> RichTextLabel:
	if node is RichTextLabel:
		return node
	for child in node.get_children():
		var r := _first_richtext(child)
		if r != null:
			return r
	return null


func _cmd_screenshot(a: Dictionary):
	var vp: Viewport = null
	if editor != null:
		vp = editor.get_base_control().get_viewport()
	elif root != null:
		vp = root.get_viewport()  # runtime: capture the live game viewport
	if vp == null:
		return _err("no viewport to capture")
	var img: Image = vp.get_texture().get_image()
	if img == null:
		return _err("could not capture viewport")
	var path := String(a.get("path", "user://godot_mcp_screenshot.png"))
	if img.save_png(path) != OK:
		return _err("save_png failed")
	return {
		"path": ProjectSettings.globalize_path(path),
		"width": img.get_width(),
		"height": img.get_height()
	}


# --- spatial: transforms / bounds / skeleton --------------------------------


func _cmd_get_transform(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	if not (n is Node3D):
		return _err("node is not a Node3D: " + n.get_class())
	var n3 := n as Node3D
	return {
		"local": _to_json(n3.transform),
		"global": _to_json(n3.global_transform),
		"global_position": _to_json(n3.global_position),
		"global_rotation_deg": _to_json(n3.global_rotation_degrees),
		"scale": _to_json(n3.scale),
	}


func _cmd_get_aabb(a: Dictionary):
	var n := _resolve(String(a.get("path", ".")))
	if n == null:
		return _err("node not found")
	# Merge the world-space AABB of every VisualInstance3D in the subtree.
	var result := AABB()
	var have := false
	var stack: Array = [n]
	while not stack.is_empty():
		var node = stack.pop_back()
		if node is VisualInstance3D:
			var wa: AABB = node.global_transform * (node as VisualInstance3D).get_aabb()
			if not have:
				result = wa
				have = true
			else:
				result = result.merge(wa)
		for c in node.get_children():
			stack.append(c)
	if not have:
		return _err("no VisualInstance3D under: " + String(a.get("path", ".")))
	return {
		"min": _to_json(result.position),
		"max": _to_json(result.end),
		"size": _to_json(result.size),
		"center": _to_json(result.get_center()),
	}


func _cmd_get_bone_poses(a: Dictionary):
	var n := _resolve(String(a.get("path", "")))
	if n == null:
		return _err("node not found")
	if not (n is Skeleton3D):
		return _err("node is not a Skeleton3D: " + n.get_class())
	var sk := n as Skeleton3D
	var only = a.get("bones", null)  # optional: array of bone names to filter
	var bones := []
	for i in range(sk.get_bone_count()):
		var bname := sk.get_bone_name(i)
		if only is Array and only.size() > 0 and not (bname in only):
			continue
		(
			bones
			. append(
				{
					"index": i,
					"name": bname,
					"parent": sk.get_bone_parent(i),
					"rest": _to_json(sk.get_bone_rest(i)),
					"pose_local": _to_json(sk.get_bone_pose(i)),
					"global_pose": _to_json(sk.get_bone_global_pose(i)),
				}
			)
		)
	return {"skeleton": String(sk.name), "bone_count": sk.get_bone_count(), "bones": bones}


# --- asset reimport (parity with Unity-MCP assets-refresh) ------------------


func _cmd_reimport(a: Dictionary):
	if editor == null:
		return _need_editor()
	var paths := PackedStringArray()
	var raw = a.get("paths", [])
	if raw is Array:
		for p in raw:
			paths.append(String(p))
	if a.has("path") and String(a["path"]) != "":
		paths.append(String(a["path"]))
	if paths.is_empty():
		return _err("no paths given (use 'path' or 'paths')")
	editor.get_resource_filesystem().reimport_files(paths)
	return {"reimported": Array(paths)}


func _cmd_rescan(_a: Dictionary):
	if editor == null:
		return _need_editor()
	editor.get_resource_filesystem().scan()
	return {"ok": true}


# --- scan + JSON (de)serialization + coercion -------------------------------


func _scan_ext(
	dir_path: String, ext: String, out: PackedStringArray = PackedStringArray()
) -> PackedStringArray:
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name != "." and name != "..":
			var full := dir_path.path_join(name)
			if d.current_is_dir():
				_scan_ext(full, ext, out)
			elif name.ends_with(ext):
				out.append(full)
		name = d.get_next()
	d.list_dir_end()
	return out


func _to_json(v, depth: int = 0):
	if depth > 32:
		return "<max-depth>"
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return String(v)
		TYPE_VECTOR2:
			return {"__t__": "Vector2", "x": v.x, "y": v.y}
		TYPE_VECTOR3:
			return {"__t__": "Vector3", "x": v.x, "y": v.y, "z": v.z}
		TYPE_VECTOR4:
			return {"__t__": "Vector4", "x": v.x, "y": v.y, "z": v.z, "w": v.w}
		TYPE_COLOR:
			return {"__t__": "Color", "r": v.r, "g": v.g, "b": v.b, "a": v.a}
		TYPE_QUATERNION:
			return {"__t__": "Quaternion", "x": v.x, "y": v.y, "z": v.z, "w": v.w}
		TYPE_VECTOR2I:
			return {"__t__": "Vector2i", "x": v.x, "y": v.y}
		TYPE_VECTOR3I:
			return {"__t__": "Vector3i", "x": v.x, "y": v.y, "z": v.z}
		# Matrix / bounds types: Godot-native, lossless Variant<->JSON via
		# JSON.from_native (Godot 4.3+), reversed in _coerce by JSON.to_native —
		# no hand-rolled layout to drift. Emits {"type":..., "args":[...]}.
		TYPE_BASIS, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_AABB, TYPE_PLANE, TYPE_RECT2, TYPE_PROJECTION:
			return JSON.from_native(v)
		TYPE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var arr := []
			for e in v:
				arr.append(_to_json(e, depth + 1))
			return arr
		TYPE_DICTIONARY:
			var dd := {}
			for k in v:
				dd[String(k)] = _to_json(v[k], depth + 1)
			return dd
		TYPE_OBJECT:
			if v == null:
				return null
			if v is Node:
				return {
					"__t__": "Node",
					"path": String(root.get_path_to(v)) if root else "",
					"class": v.get_class()
				}
			if v is Resource:
				return {"__t__": "Resource", "path": v.resource_path, "class": v.get_class()}
			return {"__t__": "Object", "class": v.get_class()}
		_:
			return str(v)


func _coerce(v, target_type: int):
	if typeof(v) == TYPE_DICTIONARY and v.has("__t__"):
		match String(v["__t__"]):
			"Vector2":
				return Vector2(v.get("x", 0), v.get("y", 0))
			"Vector3":
				return Vector3(v.get("x", 0), v.get("y", 0), v.get("z", 0))
			"Vector4":
				return Vector4(v.get("x", 0), v.get("y", 0), v.get("z", 0), v.get("w", 0))
			"Color":
				return Color(v.get("r", 0), v.get("g", 0), v.get("b", 0), v.get("a", 1))
			"Quaternion":
				return Quaternion(v.get("x", 0), v.get("y", 0), v.get("z", 0), v.get("w", 1))
			"Vector2i":
				return Vector2i(int(v.get("x", 0)), int(v.get("y", 0)))
			"Vector3i":
				return Vector3i(int(v.get("x", 0)), int(v.get("y", 0)), int(v.get("z", 0)))
	# Godot-native JSON payloads (Transform3D / Basis / AABB / Plane / …) emitted
	# by _to_json via JSON.from_native — rebuild the engine Variant losslessly.
	if typeof(v) == TYPE_DICTIONARY and v.has("type") and v.has("args"):
		return JSON.to_native(v)
	if typeof(v) == TYPE_ARRAY:
		if target_type == TYPE_VECTOR3 and v.size() == 3:
			return Vector3(v[0], v[1], v[2])
		if target_type == TYPE_VECTOR2 and v.size() == 2:
			return Vector2(v[0], v[1])
		if target_type == TYPE_COLOR and v.size() >= 3:
			return Color(v[0], v[1], v[2], v[3] if v.size() > 3 else 1.0)
	return v
