extends Node3D

signal gltf_start_to_load
signal gltf_is_loaded(success: bool, gltf: Node)
signal fbx_start_to_load
signal fbx_is_loaded(success: bool, fbx: Node)

const Worker = preload("res://vsk_model_explorer/core/Worker.gd")
var worker: Worker

const CardStyle = preload("res://vsk_model_explorer/core/CardStyle.gd")
const BuildConsts = preload("res://addons/vsk_version/build_constants.gd")
const gltf_vrm_extension_const = preload("res://addons/vrm/vrm_extension.gd")
const ControlsCard = preload("res://vsk_model_explorer/core/ControlsCard.gd")
const AutoRig = preload("res://vsk_model_explorer/core/AutoRig.gd")
const Bintr = preload("res://vsk_model_explorer/core/Bintr.gd")
const UsdImport = preload("res://vsk_model_explorer/core/UsdImport.gd")
const USD_EXTENSIONS := ["usd", "usda", "usdc", "usdz"]
var auto_rig: Node
const Motion = preload("res://vsk_model_explorer/core/Motion.gd")
const ColorChart = preload("res://vsk_model_explorer/core/ColorChart.gd")
var color_chart: Node3D
var motion: Node
const Flex = preload("res://vsk_model_explorer/core/Flex.gd")
var flex: Node
const MotionMatch = preload("res://vsk_model_explorer/core/MotionMatch.gd")
var move: Node
# The clip the motion step just added: the animation list plays it once the file reopens.
var play_after_load := ""

var gltf_doc = GLTFDocument.new()
var gltf_vrm_extension = gltf_vrm_extension_const.new()

var fbx_doc: Object = null
var controls_card: Control
var version_card: PanelContainer
var version_label: Label


# Called when the node enters the scene tree for the first time.
func _ready():
	if not OS.has_feature("web"):
		Bintr.setup()
		if "--bintr-emit" in OS.get_cmdline_user_args():
			Bintr.emit(self)
			return
	get_viewport().files_dropped.connect(_on_file_dropped)
	# The controls card, bottom right on top of the 3D view; H shows or hides it.
	_ensure_controls_card()
	# F plays the 20-minute flex motion on the open model (every build, web too).
	flex = Flex.new()
	add_child(flex)
	add_control_row(["keys", ["F"], "F", "Flex 20 min"])
	# The colour chart beside the model: hidden at start, C shows or hides it.
	color_chart = ColorChart.new()
	add_child(color_chart)
	add_control_row(["keys", ["C"], "C", "Colour chart"])
	gltf_is_loaded.connect(_place_color_chart.unbind(2))
	fbx_is_loaded.connect(_place_color_chart.unbind(2))
	if OS.has_feature("web"):
		# The page rigs the model; here R saves a rigged .glb or a .vrm as a VRM 1.0 file.
		auto_rig = AutoRig.new()
		add_child(auto_rig)
		auto_rig.rigged.connect(_load_file)
		add_control_row(["keys", ["R"], "R", "Save as .vrm"])
	else:
		# One pck, two desktop viewers: each feature is on when its weights are in the w folder.
		# SkinTokens ships the rig weights; Kimodo motion ships the Kimodo weights.
		auto_rig = AutoRig.new()
		add_child(auto_rig)
		auto_rig.rigged.connect(_load_file)
		var rig_on: bool = auto_rig.available()
		if rig_on:
			add_control_row(["keys", ["R"], "R", "Auto-rig a .glb"])
		motion = Motion.new()
		var motion_on: bool = motion.available()
		var args := OS.get_cmdline_user_args()
		var motion_test := false
		for a in args:
			motion_test = motion_test or a.begins_with("--motion-quit=")
		if motion_on or motion_test:
			add_child(motion)
			motion.status = auto_rig.show_status
			motion.made.connect(_on_motion_made)
		else:
			motion.free()
			motion = null
		if "--features-quit" in args:
			print("VIEWER-FEATURES rig=%s motion=%s" % [rig_on, motion_on])
			get_tree().quit(0)
	# M: the open rig walks like a character controller (motion matching on mm.elf), on the
	# desktop and on the web.
	move = MotionMatch.new()
	if move.available() or "--move-quit" in OS.get_cmdline_user_args():
		add_child(move)
		move.status = auto_rig.show_status
		move.auto_rig = auto_rig
		move.moves_made.connect(_load_file)
		for row in MotionMatch.CARD_ROWS:
			add_control_row(row)
	else:
		move.free()
		move = null
	if ClassDB.get_class_list().find("FBXDocument") != -1:
		fbx_doc = ClassDB.instantiate("FBXDocument")

	# --load-time-quit: print the time from engine start to the first drawn frame that shows the
	# opened model (or the empty stage when no file is given), then quit. The release's load check
	# reads the LOAD-MS line.
	if "--load-time-quit" in OS.get_cmdline_user_args():
		_report_load_time()

	# Check for command-line arguments (files opened via file association)
	call_deferred("_check_command_line_args")


func _check_command_line_args():
	# Get command-line arguments (excludes engine-specific args)
	var args = OS.get_cmdline_user_args()

	# Also check all command-line args in case user args don't capture it
	if args.is_empty():
		var all_args = OS.get_cmdline_args()
		for arg in all_args:
			# Skip engine-specific arguments
			if arg.begins_with("--") or arg.begins_with("-"):
				continue
			# Remove quotes that might wrap file paths
			var clean_arg = arg.strip_edges().trim_prefix('"').trim_suffix('"')
			# Check if it's a file path
			if FileAccess.file_exists(clean_arg):
				args.append(clean_arg)
				break

	# Process the first valid file argument
	for arg in args:
		# Remove quotes that might wrap file paths
		var file_path = arg.strip_edges().trim_prefix('"').trim_suffix('"')

		# Convert to absolute path if needed
		if not file_path.is_absolute_path():
			file_path = ProjectSettings.globalize_path(file_path)

		# Verify the file exists and has a supported extension
		if FileAccess.file_exists(file_path):
			var ext = file_path.get_extension().to_lower()
			if ext in ["glb", "gltf", "vrm", "fbx"] or ext in USD_EXTENSIONS:
				_load_file(file_path)
				break


func _report_load_time() -> void:
	var opens_file := false
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--") and FileAccess.file_exists(a):
			opens_file = true
	var ok := true
	if opens_file:
		var got = await gltf_is_loaded
		ok = got[0]
	# Two drawn frames: the first one after the load can still show the stage without the model.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	print("LOAD-MS %d ok=%s file=%s" % [Time.get_ticks_msec(), ok, opens_file])
	get_tree().quit(0 if ok else 1)


func _place_color_chart() -> void:
	# A frame later: the model's transforms settle after the load signal.
	await get_tree().process_frame
	var models: Array = get_tree().get_nodes_in_group("gltf group")
	models.append_array(get_tree().get_nodes_in_group("fbx group"))
	color_chart.place(ColorChart.model_box_of(models))


func _on_file_dropped(files: PackedStringArray):
	if files.size() == 1:
		_load_file(files[0])


func _load_file(file_path: String):
	# Normalize the file path
	var normalized_path = file_path
	if not normalized_path.is_absolute_path():
		normalized_path = ProjectSettings.globalize_path(normalized_path)

	# Verify file exists
	if not FileAccess.file_exists(normalized_path):
		printerr("File not found: ", normalized_path)
		return

	var ext = normalized_path.get_extension().to_lower()
	if OS.has_feature("web") and not normalized_path.begins_with(OS.get_user_data_dir()):
		# The browser deletes a dropped file when files_dropped returns: keep a copy for R.
		var keep := OS.get_user_data_dir().path_join("dropped")
		DirAccess.make_dir_recursive_absolute(keep)
		keep = keep.path_join(normalized_path.get_file())
		if DirAccess.copy_absolute(normalized_path, keep) == OK:
			normalized_path = keep
	if auto_rig:
		auto_rig.source = normalized_path
		auto_rig.output_base = ""

	if ext in USD_EXTENSIONS and OS.has_feature("web"):
		# Web: this script is a guest, and a guest cannot enter a second guest (usd.elf). The
		# plain-GDScript UsdImport converts on the next frame, outside this call, then opens the GLB.
		var usd := UsdImport.new()
		add_child(usd)
		usd.converted.connect(_on_usd_converted)
		var dir := OS.get_user_data_dir().path_join("usd")
		DirAccess.make_dir_recursive_absolute(dir)
		usd.convert_later(
			normalized_path, dir.path_join(normalized_path.get_file().get_basename() + ".glb")
		)
		return
	if ext in USD_EXTENSIONS:
		# OpenUSD (usd.elf) makes a GLB in the user folder; the viewer opens it, and the auto-rig
		# reads it and saves its result beside the USD file.
		var glb := _usd_to_glb(normalized_path)
		if glb == "":
			gltf_is_loaded.emit(false, null)
			return
		if auto_rig:
			auto_rig.source = glb
			auto_rig.output_base = normalized_path.get_basename()
		normalized_path = glb
		ext = "glb"

	if motion:
		motion.source = normalized_path
	if move:
		move.source = normalized_path

	if ext == "glb" or ext == "gltf" or ext == "vrm":
		gltf_start_to_load.emit()

		# unload previous loaded scene
		var loaded_nodes = []
		loaded_nodes.append_array(get_tree().get_nodes_in_group(GlobalSignal.GLTF_GROUP))
		loaded_nodes.append_array(get_tree().get_nodes_in_group(GlobalSignal.FBX_GROUP))
		for n in loaded_nodes:
			n.queue_free()

		if OS.has_feature("web"):
			# On the web the dropped file is deleted when files_dropped returns, and a guest
			# script cannot be entered from a second thread, so load here, on this thread.
			_load_gltf(normalized_path)
		else:
			worker = Worker.new(Callable(self, "_load_gltf").bind(normalized_path))
			worker.start()

		gltf_start_to_load.emit()
	elif ext == "fbx":
		if ClassDB.get_class_list().find("FBXDocument") == -1:
			printerr("Use the godot-ufbx branch of Godot Engine for the new FBX Importer.")
			return
		fbx_start_to_load.emit()

		# unload previous loaded scene
		var loaded_nodes = []
		loaded_nodes.append_array(get_tree().get_nodes_in_group(GlobalSignal.GLTF_GROUP))
		loaded_nodes.append_array(get_tree().get_nodes_in_group(GlobalSignal.FBX_GROUP))
		for n in loaded_nodes:
			n.queue_free()

		var fbx_state: Object = ClassDB.instantiate("FBXState")
		var handle_binary_image_enum: StringName = ClassDB.class_get_integer_constant_enum(
			"FBXState", "HANDLE_BINARY_EMBED_AS_UNCOMPRESSED"
		)
		fbx_state.set("handle_binary_image", handle_binary_image_enum)
		var err = ERR_FILE_CANT_OPEN

		err = fbx_doc.append_from_file(normalized_path, fbx_state)

		var fbx: Node = null

		if err == OK:
			fbx = fbx_doc.generate_scene(fbx_state)
			if fbx != null:
				fbx.add_to_group(GlobalSignal.FBX_GROUP)
				add_child.call_deferred(fbx)
				_emit_fbx_load.call_deferred(fbx)
			else:
				_emit_fbx_load_failed.call_deferred()
		else:
			_emit_fbx_load_failed.call_deferred()

		fbx_start_to_load.emit()
	else:
		printerr("Unsupported file format: ", ext)


func _on_usd_converted(source: String, glb: String, why: String) -> void:
	if why != "":
		printerr("USD-FAIL ", why)
		if auto_rig:
			auto_rig.show_status(why)
		gltf_is_loaded.emit(false, null)
		return
	print("USD-OK %s -> %s" % [source, glb])
	_load_file(glb)
	if auto_rig:
		auto_rig.output_base = source.get_basename()


func _usd_to_glb(path: String) -> String:
	var dir := OS.get_user_data_dir().path_join("usd")
	DirAccess.make_dir_recursive_absolute(dir)
	var out := dir.path_join(path.get_file().get_basename() + ".glb")
	var t0 := Time.get_ticks_msec()
	var usd := UsdImport.new()
	add_child(usd)
	var why := usd.to_glb(path, out)
	usd.queue_free()
	if why != "":
		printerr("USD-FAIL ", why)
		if auto_rig:
			auto_rig.show_status(why)
		return ""
	print("USD-OK %s -> %s ms=%d" % [path, out, Time.get_ticks_msec() - t0])
	return out


func _emit_fbx_load(fbx) -> void:
	fbx_is_loaded.emit(true, fbx)


func _emit_fbx_load_failed() -> void:
	fbx_is_loaded.emit(false, null)


# The name of the bone a VRM file gives a humanoid role such as "hips" or "head" (VRM 1.0 or 0.x), or ""
# for a file that does not say. Flex.gd uses the hips (the nodes above them, root motion and the centre
# of gravity, are not the body); CamController.gd uses the head to find eye level.
func _humanoid_name(json: Dictionary, role: String) -> String:
	var ext: Dictionary = json.get("extensions", {})
	var idx := -1
	if ext.has("VRMC_vrm"):
		idx = int(ext["VRMC_vrm"].get("humanoid", {}).get("humanBones", {}).get(role, {}).get("node", -1))
	elif ext.has("VRM"):
		for hb in ext["VRM"].get("humanoid", {}).get("humanBones", []):
			if hb.get("bone", "") == role:
				idx = int(hb.get("node", -1))
	var nodes: Array = json.get("nodes", [])
	return str(nodes[idx].get("name", "")) if idx >= 0 and idx < nodes.size() else ""


# The names of all the bones a VRM file gives a humanoid role (empty for a file that does not say):
# Flex.gd moves only these on a humanoid, so hair, skirt and face joints stay still.
func _humanoid_names(json: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var ext: Dictionary = json.get("extensions", {})
	var nodes: Array = json.get("nodes", [])
	var indices := []
	if ext.has("VRMC_vrm"):
		for v in ext["VRMC_vrm"].get("humanoid", {}).get("humanBones", {}).values():
			indices.append(int(v.get("node", -1)))
	elif ext.has("VRM"):
		for hb in ext["VRM"].get("humanoid", {}).get("humanBones", []):
			indices.append(int(hb.get("node", -1)))
	for i in indices:
		if i >= 0 and i < nodes.size():
			out.append(str(nodes[i].get("name", "")))
	return out


func _load_gltf(file: String):
	var gltf_state: GLTFState = GLTFState.new()
	gltf_state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	var err = ERR_FILE_CANT_OPEN
	if file.ends_with("vrm"):
		GLTFDocument.register_gltf_document_extension(gltf_vrm_extension, true)

	err = gltf_doc.append_from_file(file, gltf_state)

	var gltf: Node = null

	if err == OK:
		gltf = gltf_doc.generate_scene(gltf_state)
		gltf.set_meta("hips_bone", _humanoid_name(gltf_state.get_json(), "hips"))
		gltf.set_meta("head_bone", _humanoid_name(gltf_state.get_json(), "head"))
		gltf.set_meta("humanoid_bones", _humanoid_names(gltf_state.get_json()))
		gltf.add_to_group(GlobalSignal.GLTF_GROUP)
		add_child.call_deferred(gltf)
		_emit_gltf_load.call_deferred(gltf)
	else:
		_emit_gltf_load_failed.call_deferred()


func _emit_gltf_load(gltf) -> void:
	gltf_is_loaded.emit(true, gltf)


func _emit_gltf_load_failed() -> void:
	gltf_is_loaded.emit(false, null)


func _exit_tree():
	GLTFDocument.unregister_gltf_document_extension(gltf_vrm_extension)


# A row on the controls card for a control that one build adds, such as the web viewer's chart.
# Callable before _ready: a build may add its row before this node enters the tree.
func _on_motion_made(path: String, clip: String) -> void:
	play_after_load = clip
	_load_file(path)


func add_control_row(row: Array) -> void:
	_ensure_controls_card()
	controls_card.add_row(row)


func _ensure_controls_card() -> void:
	if controls_card:
		return
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	controls_card = ControlsCard.new()
	layer.add_child(controls_card)
	_add_version_label(layer)


func _add_version_label(layer: CanvasLayer) -> void:
	# A small version card in the top-right corner: the info panel owns the left, the
	# controls card the bottom-right, so top-right is free. Ink text on the light card is
	# readable over the 3D view. Two lines: the build date and the build label that the
	# build bakes into build_constants.gd.
	var bg := PanelContainer.new()
	bg.theme = CardStyle.make_theme()
	var label := Label.new()
	label.text = BuildConsts.BUILD_DATE_STR + "\n" + BuildConsts.BUILD_LABEL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(label)
	layer.add_child(bg)
	version_card = bg
	version_label = label
	get_viewport().size_changed.connect(_on_version_resized)
	call_deferred("_fit_version_label", bg, label)


func _on_version_resized() -> void:
	_fit_version_label(version_card, version_label)


func _fit_version_label(bg: PanelContainer, label: Label) -> void:
	# Card padding is double the content margin; size the card, pin top-right.
	var pw: float = label.get_theme_font("font").get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
	var ph: float = label.get_theme_font("font").get_height(label.get_theme_font_size("font_size"))
	var pad: float = CardStyle.PAD * 2.0
	var cw: float = pw + pad
	var ch: float = ph + pad
	bg.custom_minimum_size = Vector2(cw, ch)
	var m: float = CardStyle.MARGIN
	var vp: Vector2 = get_viewport().size
	bg.position.x = vp.x - cw - m
	bg.position.y = m
