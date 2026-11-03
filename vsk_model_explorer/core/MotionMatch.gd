extends Node
# M walks the open rigged model like a character controller. Keyboard: W A S D move (relative to
# the camera), Shift runs, C crouches, Z crawls (each again to stand), Space jumps, M stops.
# Mouse or touch: click or tap the floor and the model walks there; a double click or double tap
# runs there. A ring marks the point until the model arrives; any move key or the stick cancels it.
# Gamepad: left stick moves, right stick turns the camera, A jumps, B crouches, Y crawls, the right
# trigger runs, Start stops. Motion matching picks the motion: mm.elf
# (interactor-motion-matching-guest, a port of godot-motion-matching) holds a pose database built
# from Kimodo clips and the O3DE MotionMatching gem's clips (SOMA skeleton, res://motion/mm/),
# predicts where the input takes the character, and every 0.1 s picks the clip frame whose next
# second fits best, among poses of the asked kind (standing, crouching or crawling; a jump picks a
# take-off and plays through to the landing). The same clips are moved onto the model's rig once
# by skintokens.elf ("whole": every frame, root travel kept) and played here by Godot's own
# animation nodes: an AnimationTree whose root is MotionMatchNode (an AnimationNodeExtension that
# steps mm.elf and blends the picked clips). Before that, each clip's floor travel moves from the
# hips to a root track (the tree's root motion track, as Godot's root motion expects), and every
# track uses Godot's makima interpolation.
# Test mode: `-- <rigged.glb> --move-quit` opens the moves, walks forward, turns and runs,
# checks how far and which way the model went, then quits with 0, or 1 on any failure.

signal moves_made(path: String)

const Motion = preload("res://vsk_model_explorer/core/Motion.gd")
const MotionMatchNode = preload("res://vsk_model_explorer/core/MotionMatchNode.gd")
const Bintr = preload("res://vsk_model_explorer/core/Bintr.gd")
const AutoRig = preload("res://vsk_model_explorer/core/AutoRig.gd")
const MM_ELF := "res://mm.elf"
const RIG_ELF := "res://skintokens.elf"
const DIR := "res://motion/mm"
const PREFIX := "mm_"
const ROOT := "MMRoot"
const STAND := 0
const CROUCH := 1
const CRAWL := 2
const MODE_NAMES := ["standing", "crouching", "crawling"]
# Walk to a point: a press and release closer than TAP_SLOP pixels is a tap (a drag is not).
# The model stops within ARRIVE SOMA metres of the point.
const TAP_SLOP := 12.0
const ARRIVE := 0.3
# mm.elf's velocity spring (mm_core Settings.halflife): after the asked speed drops to zero the
# body still travels speed * SPRING_HALFLIFE / ln 2. Walking to a point eases the asked speed
# down over that distance on a makima curve, which bends without going past its keys.
const SPRING_HALFLIFE := 0.27
var _approach: Animation
# The controls card rows this adds; the status line repeats them while walking.
# Keyboard and gamepad on one row each.
const CARD_ROWS := [
	["keys", ["M"], "M or Start", "Walk mode"],
	["keys", ["W"], "WASD or stick", "Walk"],
	["mouse", "left", "Tap or click floor", "Walk there, 2x run"],
	["keys", ["Shift"], "Shift or RT", "Run"],
	["keys", ["C"], "C or pad B", "Crouch"],
	["keys", ["Z"], "Z or pad Y", "Crawl"],
	["keys", ["Space"], "Space or A", "Jump"],
	["keys", ["O"], "O", "Obstacle course"],
]
# Short lines: one long line is wider than a 1280 px window and the card cuts it off.
const HELP := (
	"W A S D or click the floor: walk.   Double click: run there.   Shift: run.\n"
	+ "C: crouch.   Z: crawl.   Space: jump.   M: stop.\n"
	+ "Gamepad: stick, RT, B, Y, A, Start."
)

var source := ""
var busy := false
var on := false
var status := Callable()
var _helper: Node
var _mm: Node
var _scene: Node3D
var _player: AnimationPlayer
var _tree: AnimationTree
var _node: MotionMatchNode
var _skeleton: Skeleton3D
var _keys: PackedStringArray = []
var _hips_track := -1
var _hips_path := ""
var _scale := 1.0
var _phi := 0.0
var _walk_speed := 1.3
var _run_speed := 3.5
var _mode_speed := [1.3, 0.8, 0.4]
var _mode := STAND
var _jump_pressed := false
var _pad_prev := {}
var _origin := Vector3.ZERO
var _cam_before := {}  # the camera as it was before the walk: pos, yaw, scale, pitch
const WALK_CAM_DISTANCE := 4.5  # metres from the middle of the body in walk mode
const WALK_CAM_PITCH := -40.0  # degrees: looking down on the character
var _clip := -1
var _last_world := Vector3.ZERO
# How far the course's walls have held the model back from where root motion put it.
var _push := Vector3.ZERO
var _test := false
var _test_opened := false
var _test_input := Vector2.ZERO
var _test_run := false
var _test_mode := STAND
var _test_jump := false
var _start_after_load := false
var _jumping := false
var _kind := 0
var _target := Vector3.ZERO
var _has_target := false
var _target_run := false
var _press_pos := Vector2.ZERO
var _press_down := false
var _press_run := false
var _marker: MeshInstance3D
var _last_status := ""
# The auto-rig of the viewer. M on a model with no skin rigs it first, then walks the result.
var auto_rig: Node
var _walk_after_rig := false
var _keys_testing := false
var _space_jumps := 0
var _trace := OS.get_environment("MOVE_TRACE") != ""
var course: ObstacleCourse
# --orbit-video: the view circles the model at ORBIT_DEG_S while the walk keeps the input frame
# of the camera it started with, so the walk goes where the test asks and only the view moves.
const ORBIT_DEG_S := 24.0
var _orbit := false
var _orbit_cam: Camera3D
var _input_cam: Camera3D
var _orbit_rel := Transform3D.IDENTITY
var _orbit_a := 0.0


func _ready() -> void:
	_test = "--move-quit" in OS.get_cmdline_user_args()
	_orbit = "--orbit-video" in OS.get_cmdline_user_args()
	course = ObstacleCourse.new()
	course.name = "ObstacleCourse"
	get_parent().add_child.call_deferred(course)
	get_parent().gltf_is_loaded.connect(_on_loaded)
	_helper = Motion.new()
	_helper.status = func(t): say(t)
	add_child(_helper)


func available() -> bool:
	return FileAccess.file_exists(MM_ELF) and FileAccess.file_exists(DIR.path_join("clips.tsv"))


func say(text: String) -> void:
	if text != "":
		_last_status = text
	if status.is_valid():
		status.call(text)
	if _test and (text.begins_with("Move failed") or text.begins_with("Motion failed")):
		printerr("MOVE-FAIL ", text)


# The walk keys. In walk mode they belong to the walk: no other part of the viewer gets them.
const WALK_KEYS := [KEY_W, KEY_A, KEY_S, KEY_D, KEY_SHIFT, KEY_C, KEY_Z, KEY_SPACE]


# _input runs before the GUI and before _unhandled_key_input, so a focused button or list does
# not take Space or a letter, and C does not also open the colour chart.
func _input(event: InputEvent) -> void:
	if on and event is InputEventJoypadButton:
		# The pad is read by polling; a focused button must not take A as "press".
		get_viewport().set_input_as_handled()
		return
	var k := event as InputEventKey
	if not k:
		return
	if k.keycode == KEY_M and not _typing():
		get_viewport().set_input_as_handled()
		if k.pressed and not k.echo:
			toggle()
		return
	if not on or not k.keycode in WALK_KEYS:
		return
	get_viewport().set_input_as_handled()
	if not k.pressed or k.echo:
		return
	if k.keycode == KEY_C:
		_mode = STAND if _mode == CROUCH else CROUCH
	elif k.keycode == KEY_Z:
		_mode = STAND if _mode == CRAWL else CRAWL
	elif k.keycode == KEY_SPACE:
		_jump_pressed = true
		_space_jumps += 1


# A text box has the keyboard: M is a letter there, not walk mode.
func _typing() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit


# A click or tap on the floor (mouse, or touch through Godot's mouse emulation) sets the point.
func _unhandled_input(event: InputEvent) -> void:
	var b := event as InputEventMouseButton
	if not on or b == null or b.button_index != MOUSE_BUTTON_LEFT:
		return
	if b.pressed:
		_press_pos = b.position
		_press_run = b.double_click
		_press_down = true
	elif _press_down:
		_press_down = false
		if (
			b.position.distance_to(_press_pos) <= TAP_SLOP
			and walk_to_screen(b.position, _press_run)
		):
			get_viewport().set_input_as_handled()


# The floor point under a screen position: where the camera ray meets the floor the model
# stands on. False when the ray does not reach the floor (pointing at the sky).
func walk_to_screen(pos: Vector2, run: bool) -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false
	var hit = Plane(Vector3.UP, _origin.y).intersects_ray(
		cam.project_ray_origin(pos), cam.project_ray_normal(pos)
	)
	if hit == null:
		return false
	walk_to(hit, run)
	return true


func walk_to(point: Vector3, run: bool) -> void:
	_target = Vector3(point.x, _origin.y, point.z)
	_has_target = true
	_target_run = run
	if _marker == null:
		_marker = MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.12
		ring.outer_radius = 0.16
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.78, 0.35)
		ring.material = mat
		_marker.mesh = ring
		get_parent().add_child(_marker)
	_marker.scale = Vector3.ONE * _scale
	_marker.position = _target + Vector3.UP * 0.01 * _scale
	_marker.visible = true


func _clear_target() -> void:
	_has_target = false
	if _marker:
		_marker.visible = false


func toggle() -> void:
	if on:
		stop()
	else:
		start()


# Gamepad buttons on the frame they go down.
func _pad_down(button: JoyButton) -> bool:
	var now := Input.is_joy_button_pressed(0, button)
	var was: bool = _pad_prev.get(button, false)
	_pad_prev[button] = now
	return now and not was


func _pad() -> void:
	if _pad_down(JOY_BUTTON_START):
		toggle()
	if not on:
		return
	if _pad_down(JOY_BUTTON_A):
		_jump_pressed = true
	if _pad_down(JOY_BUTTON_B):
		_mode = STAND if _mode == CROUCH else CROUCH
	if _pad_down(JOY_BUTTON_Y):
		_mode = STAND if _mode == CRAWL else CRAWL


func _on_loaded(ok: bool, scene: Node) -> void:
	stop()
	_scene = scene as Node3D if ok else null
	if _test and not ok:
		printerr("MOVE-FAIL the model did not open")
		get_tree().quit(1)
		return
	if _walk_after_rig and ok:
		# The auto-rig result just opened: make its moves.
		_walk_after_rig = false
		start.call_deferred()
	elif _start_after_load and ok:
		# The moves file just opened.
		_start_after_load = false
		if _test:
			_run_test.call_deferred()
		else:
			start.call_deferred()
	elif _test and not _test_opened:
		_test_opened = true
		if _has_moves():
			_run_test.call_deferred()
		else:
			start.call_deferred()


# 1. The moves file: every database clip on this rig. 2. The database in mm.elf.
func start() -> void:
	if busy or _scene == null:
		return
	if not available():
		return say("Move needs mm.elf and the clips in res://motion/mm.")
	if not _has_moves():
		# A .vrm is a .glb file with a rig.
		if source == "" or not source.get_extension().to_lower() in ["glb", "vrm"]:
			_fail("Move needs an open .glb or .vrm file with a rig.")
			if _test:
				get_tree().quit(1)
			return
		if not AutoRig.has_skin(source):
			await _rig_first()
			return
		# The rig program reads VRM 1.0 Humanoid roles only (VRMC_vrm, or KHR_character_skeleton_mapping's
		# vrm1_humanoid set). A VRM 0.x is saved as VRM 1.0 first; the walk uses that file.
		if (
			source.get_extension().to_lower() == "vrm"
			and auto_rig != null
			and not auto_rig.is_vrm1(source)
		):
			_vrm1_first()
			return
		busy = true
		var out := await _make_moves()
		busy = false
		if out != "":
			_start_after_load = true
			moves_made.emit(out)
		elif _test:
			printerr("MOVE-FAIL making the moves: ", _last_status)
			get_tree().quit(1)
		return
	if not _bake():
		return
	_begin()


# Save the open VRM 0.x as VRM 1.0 (godot-vrm turns it to face +Z) in the user folder, open that
# file, and start() runs again on it. The moves file is then named after <name>.vrm1.
func _vrm1_first() -> void:
	say("Move: the model is VRM 0.x, so it is saved as VRM 1.0 first.")
	var out := OS.get_user_data_dir().path_join(source.get_file().get_basename() + ".vrm1.vrm")
	# GLTFDocument writes binary glTF for a .glb name only: write that, then name it .vrm.
	var glb := out.get_basename() + ".glb"
	var why: String = auto_rig.save_vrm1(source, glb)
	if why == "" and DirAccess.rename_absolute(glb, out) != OK:
		why = "cannot rename %s" % glb
	if why != "":
		_fail("cannot save the model as VRM 1.0: %s" % why)
		if _test:
			get_tree().quit(1)
		return
	print("MOVE-VRM1 %s" % out)
	_walk_after_rig = true
	moves_made.emit(out)


# The open model has no skin, so skintokens.elf cannot put the clips on it. On the desktop with
# the rig weights, auto-rig it; the rigged file opens and start() runs again on it.
func _rig_first() -> void:
	if OS.has_feature("web") or auto_rig == null or not auto_rig.available():
		var how := (
			"rig it with the Auto-rig button on the page"
			if OS.has_feature("web")
			else "the SkinTokens viewer rigs it with R"
		)
		_fail("the model has no rig: %s, then press M." % how)
		if _test:
			get_tree().quit(1)
		return
	say("Move: the model has no rig, so it is auto-rigged first.")
	_walk_after_rig = true
	busy = true
	# The rigged file opens on a worker thread, after start() returns: watch the signal instead.
	var got := [false]
	var mark := func(_path: String) -> void: got[0] = true
	auto_rig.rigged.connect(mark, CONNECT_ONE_SHOT)
	await auto_rig.start()
	if auto_rig.rigged.is_connected(mark):
		auto_rig.rigged.disconnect(mark)
	busy = false
	if not got[0]:
		# The auto-rig made no rigged file; its own message stays on screen.
		_walk_after_rig = false
		if _test:
			printerr("MOVE-FAIL the auto-rig gave no rigged file: ", _last_status)
			get_tree().quit(1)


func stop() -> void:
	if not on:
		return
	on = false
	_clear_target()
	remove_from_group("walk_mode")
	_restore_camera()
	if is_instance_valid(_tree):
		_tree.active = false
	if _player:
		_player.active = true
		_player.stop()
	if is_instance_valid(_scene):
		if OS.get_environment("MOVE_PLANT") == "reset-on-stop":
			# Planted fault for the test itself: the old jump back to where the walk started.
			_scene.transform = Transform3D.IDENTITY
		elif _skeleton:
			_stay()
	say("")


# The camera back where it was before the walk, moved by how far the character walked.
func _restore_camera() -> void:
	if _cam_before.is_empty():
		return
	var cc := get_parent().get_node_or_null("CamController") as Node3D
	var rot := get_parent().get_node_or_null("CamController/CamRotHelper") as Node3D
	if cc and rot:
		cc.rotation.y = _cam_before["yaw"]
		cc.scale = _cam_before["scale"]
		rot.rotation.x = _cam_before["pitch"]
		cc.position = _cam_before["pos"] + (cc.position - _cam_before["pos"]) * Vector3(1, 0, 1)  # keep where it walked, on the floor plane
	_cam_before = {}


# M off: the model stays where the walk left it, facing the way it faced. The pose goes back to
# rest, so turn the scene until the rest forward points where the posed hips pointed.
func _stay() -> void:
	var face := _hips_forward()
	var rest := _to_scene(_skeleton).basis * Vector3.BACK
	var yaw := atan2(face.x, face.z) - atan2(rest.x, rest.z)
	_scene.transform = Transform3D(
		Basis(Vector3.UP, yaw), Vector3(_last_world.x, _origin.y, _last_world.z)
	)


func _has_moves() -> bool:
	_player = null
	for p in _scene.find_children("*", "AnimationPlayer", true, false):
		if (p as AnimationPlayer).has_animation(PREFIX + "walk"):
			_player = p
	return _player != null


static func clip_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for line in FileAccess.get_file_as_string(DIR.path_join("clips.tsv")).split("\n", false):
		out.append(line.split("	")[0])
	return out


# Which clips are loops: a steady gait cut to whole strides has "loop" in clips.tsv's second
# column (its loop.txt in the clip data). Every other clip is a one-shot.
static func clip_loops() -> Dictionary:
	var out := {}
	for line in FileAccess.get_file_as_string(DIR.path_join("clips.tsv")).split("\n", false):
		var w := line.split("	")
		out[w[0]] = w.size() > 1 and w[1] == "loop"
	return out


static func _soma() -> Dictionary:
	var names := FileAccess.get_file_as_string(DIR.path_join("skeleton.txt")).strip_edges()
	var parents := PackedInt32Array()
	for p in FileAccess.get_file_as_string(DIR.path_join("parents.txt")).split("\n", false):
		parents.append(int(p))
	return {names = names, parents = parents}


func _make_moves() -> String:
	var t0 := Time.get_ticks_msec()
	var keys := clip_keys()
	var soma := _soma()
	var dir := OS.get_user_data_dir().path_join("moves")
	DirAccess.make_dir_recursive_absolute(dir)
	var out := dir.path_join(source.get_file().get_basename() + ".moves.glb")
	# One guest for every clip: its arena is the whole memory cost, so it stays the same for 72
	# clips as for one. (A guest per clip, freed at the end of a frame, kept all 72 arenas alive.)
	var rig: Node = _helper._sandbox(RIG_ELF, "skintokens_motion_start")
	if rig == null:
		return _fail("skintokens.elf has no motion step")
	var glb: PackedByteArray
	if rig.has_function("skintokens_motions_add"):
		glb = await _all_clips_at_once(rig, keys, soma, t0)
	else:
		glb = await _clip_by_clip(rig, keys, soma, t0, out)
	_helper._free(rig)
	if glb.is_empty():
		return ""
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return _fail("cannot save %s" % out)
	f.store_buffer(glb)
	f.close()
	print("MOVE-MADE %s clips=%d ms=%d" % [out, keys.size(), Time.get_ticks_msec() - t0])
	say("")
	return out


# Every clip in one job: the rig file is read and the moves file written once, so the guest holds
# the rig, the clips and one result. Adding clip by clip rewrote a file that grew with each clip.
func _all_clips_at_once(
	rig: Node, keys: PackedStringArray, soma: Dictionary, t0: int
) -> PackedByteArray:
	var label := "Move: putting %d clips on the rig" % keys.size()
	say(label)
	rig.vmcall("skintokens_motions_begin", soma.names, soma.parents, 30.0)
	for i in keys.size():
		var k := keys[i]
		var xf := FileAccess.get_file_as_bytes(DIR.path_join(k + ".f32")).to_float32_array()
		var added := str(rig.vmcall("skintokens_motions_add", PREFIX + k, xf))
		if not added.begins_with("OK"):
			_fail(added)
			return PackedByteArray()
		# Each add is a blocking call: say how far it is and let the window draw, or it looks stuck.
		say("%s (clip %d of %d)" % [label, i + 1, keys.size()])
		if i % 4 == 3:
			await get_tree().process_frame
	var started := str(rig.vmcall("skintokens_motions_start", source))
	if not started.begins_with("STARTED"):
		_fail(started)
		return PackedByteArray()
	if not await _helper._drive(rig, "skintokens_pump", label, t0):
		return PackedByteArray()
	var glb := _result(rig)
	_helper._close_files()
	return glb


# An older skintokens.elf without the one-job step: one clip per job, each on the file so far.
func _clip_by_clip(
	rig: Node, keys: PackedStringArray, soma: Dictionary, t0: int, out: String
) -> PackedByteArray:
	var cur := source
	var glb := PackedByteArray()
	for i in keys.size():
		var label := "Move: putting %s on the rig (%d of %d)" % [keys[i], i + 1, keys.size()]
		say(label)
		var xf := FileAccess.get_file_as_bytes(DIR.path_join(keys[i] + ".f32")).to_float32_array()
		var started := str(
			rig.vmcall(
				"skintokens_motion_start",
				cur,
				PREFIX + keys[i],
				"whole",
				soma.names,
				soma.parents,
				xf,
				30.0
			)
		)
		if not started.begins_with("STARTED"):
			_fail(started)
			return PackedByteArray()
		if not await _helper._drive(rig, "skintokens_pump", label, t0):
			return PackedByteArray()
		glb = _result(rig)
		_helper._close_files()
		if glb.is_empty():
			return glb
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f == null:
			_fail("cannot save %s" % out)
			return PackedByteArray()
		f.store_buffer(glb)
		f.close()
		cur = out
	return glb


func _result(rig: Node) -> PackedByteArray:
	var glb := PackedByteArray()
	var size := int(rig.vmcall("skintokens_result_size"))
	while glb.size() < size:
		var chunk: PackedByteArray = rig.vmcall(
			"skintokens_result_chunk", glb.size(), min(size - glb.size(), 8 << 20)
		)
		if chunk.is_empty():
			_fail("the result did not read back")
			return PackedByteArray()
		glb.append_array(chunk)
	return glb


func _fail(why: String) -> String:
	busy = false
	say("Move failed: " + why)
	return ""


func _bake() -> bool:
	if _mm == null:
		_mm = Bintr.make(self, MM_ELF, 512, 4096)
		if not _mm.has_function("mm_step"):
			_fail("mm.elf did not load")
			return false
	_mm.vmcall("mm_clear")
	_keys = clip_keys()
	var loops := clip_loops()
	var soma := _soma()
	for k in _keys:
		var xf := FileAccess.get_file_as_bytes(DIR.path_join(k + ".f32")).to_float32_array()
		var r := str(
			_mm.vmcall("mm_add_clip", k, soma.names, soma.parents, xf, 30.0, 1 if loops[k] else 0)
		)
		if not r.begins_with("ADDED"):
			_fail(r)
			return false
		# The clip's learned gait phase, when the package has one.
		var ph_path := DIR.path_join(k + ".phase.f32")
		if FileAccess.file_exists(ph_path):
			var ph := FileAccess.get_file_as_bytes(ph_path).to_float32_array()
			r = str(_mm.vmcall("mm_clip_phase", _keys.find(k), ph))
			if not r.begins_with("PHASE"):
				_fail(r)
				return false
	var baked := str(_mm.vmcall("mm_bake"))
	print("MOVE-BAKE ", baked)
	if not baked.begins_with("BAKED"):
		_fail(baked)
		return false
	# Walk at the walk clip's usual speed; run at the usual top speed of the running clips.
	var tops := []
	for line in str(_mm.vmcall("mm_clips")).split("\n", false):
		var w := line.split(" ")
		if w.size() < 8:
			continue
		if w[0] == "walk":
			_walk_speed = float(w[6])
		elif "run" in w[0] or "jog" in w[0] or "sprint" in w[0]:
			tops.append(float(w[7]))
	if not tops.is_empty():
		tops.sort()
		_run_speed = tops[tops.size() / 2]
	_mode_speed = [_walk_speed, 0.0, 0.0]
	var modes := str(_mm.vmcall("mm_modes"))
	for line in modes.split("\n", false):
		var w := line.split(" ")
		if w[0] == "crouch":
			_mode_speed[CROUCH] = float(w[2])
		elif w[0] == "crawl":
			_mode_speed[CRAWL] = float(w[2])
	print(
		(
			"MOVE-SPEEDS walk=%.2f run=%.2f crouch=%.2f crawl=%.2f m/s | %s"
			% [
				_walk_speed,
				_run_speed,
				_mode_speed[CROUCH],
				_mode_speed[CRAWL],
				modes.replace("\n", "; ")
			]
		)
	)
	return _calibrate() and _prepare_clips() and _make_tree()


# The rig's clips are the database clips moved onto the rig: the root travels the same path,
# scaled by the rig's height and turned to the rig's forward. Measure both from the walk.
func _calibrate() -> bool:
	_skeleton = null
	var walk := _player.get_animation(PREFIX + "walk")
	if walk.has_meta("mm_calibration"):
		# The clips are already prepared: their hips no longer travel.
		var c: Array = walk.get_meta("mm_calibration")
		_scale = c[0]
		_phi = c[1]
		_hips_path = c[2]
		_hips_track = walk.find_track(NodePath(_hips_path), Animation.TYPE_POSITION_3D)
		_skeleton = (
			_player.get_node(_player.root_node).get_node_or_null(
				NodePath(_hips_path.get_slice(":", 0))
			)
			as Skeleton3D
		)
		return true
	var best := 0.0
	for t in walk.get_track_count():
		if walk.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		var a := walk.position_track_interpolate(t, 0.0)
		var b := walk.position_track_interpolate(t, walk.length)
		var d := Vector2(b.x - a.x, b.z - a.z).length()
		if d > best:
			best = d
			_hips_track = t
	if _hips_track < 0:
		_fail("the walk clip has no root travel")
		return false
	_hips_path = str(walk.track_get_path(_hips_track))
	var node := _player.get_node(_player.root_node).get_node_or_null(
		NodePath(_hips_path.get_slice(":", 0))
	)
	_skeleton = node as Skeleton3D
	var rig_d := _root_model(walk, walk.length) - _root_model(walk, 0.0)
	var soma := _mm_root("walk")
	if soma.length() < 1e-3 or Vector2(rig_d.x, rig_d.z).length() < 1e-6:
		_fail("the walk clip does not travel")
		return false
	_scale = Vector2(rig_d.x, rig_d.z).length() / Vector2(soma.x, soma.z).length()
	_phi = atan2(rig_d.x, rig_d.z) - atan2(soma.x, soma.z)
	print(
		"MOVE-CALIBRATE scale=%.4f turn=%.1f deg hips=%s" % [_scale, rad_to_deg(_phi), _hips_path]
	)
	_space_arms()
	walk.set_meta("mm_calibration", [_scale, _phi, _hips_path])
	return true


# Godot's root motion wants the floor travel on its own track: move it from the hips to a root
# track on the MMRoot node (the hips keep their height and sway), and use makima interpolation
# on every track.
func _prepare_clips() -> bool:
	var root_owner := _player.get_node(_player.root_node)
	if root_owner.get_node_or_null(ROOT) == null:
		var n := Node3D.new()
		n.name = ROOT
		root_owner.add_child(n)
	var to_scene := _to_scene(_skeleton) if _skeleton else Transform3D.IDENTITY
	if _skeleton:
		var bone := _skeleton.find_bone(_hips_path.get_slice(":", 1))
		var parent := _skeleton.get_bone_parent(bone) if bone >= 0 else -1
		if parent >= 0:
			to_scene = to_scene * _skeleton.get_bone_global_rest(parent)
	var from_scene := to_scene.affine_inverse()
	var owner_from_scene := (
		_to_scene(root_owner).affine_inverse() if root_owner is Node3D else Transform3D.IDENTITY
	)
	var interp := interpolation()
	var loops := clip_loops()
	var n_loop := 0
	for k in _keys:
		var anim := _player.get_animation(PREFIX + k)
		if anim == null:
			return _fail("the moves file has no clip %s" % k) != ""
		# A loop plays on through its seam (mm.elf wraps its time; a cross-fade out of it keeps
		# cycling, and makima reads its keys across the seam). A one-shot holds its last frame.
		anim.loop_mode = Animation.LOOP_LINEAR if loops.get(k, false) else Animation.LOOP_NONE
		n_loop += 1 if loops.get(k, false) else 0
		if anim.has_meta("mm_root"):
			continue
		var h := anim.find_track(NodePath(_hips_path), Animation.TYPE_POSITION_3D)
		if h < 0:
			return _fail("clip %s has no hips track" % k) != ""
		var rt := anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(rt, NodePath(ROOT))
		for i in anim.track_get_key_count(h):
			var p := to_scene * (anim.track_get_key_value(h, i) as Vector3)
			var ground := Vector3(p.x, 0, p.z)
			anim.track_set_key_value(h, i, from_scene * (p - ground))
			anim.position_track_insert_key(
				rt, anim.track_get_key_time(h, i), owner_from_scene * ground
			)
		for t in anim.get_track_count():
			match anim.track_get_type(t):
				Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D, Animation.TYPE_BLEND_SHAPE:
					anim.track_set_interpolation_type(t, interp)
		anim.set_meta("mm_root", true)
	print("MOVE-INTERP %s" % ("makima" if interp != Animation.INTERPOLATION_CUBIC else "cubic"))
	print("MOVE-LOOPS loops=%d one-shots=%d" % [n_loop, _keys.size() - n_loop])
	return true


# Share of full speed to ask for with dist scene metres left to the point: 0 at the arrive
# ring, 1 once the point is two stopping distances out (keys at 0, 1 and 2 stopping distances).
func _approach_share(dist: float) -> float:
	if _approach == null:
		_approach = Animation.new()
		var t := _approach.add_track(Animation.TYPE_VALUE)
		var it := interpolation()
		_approach.track_set_interpolation_type(
			t, it if it != Animation.INTERPOLATION_CUBIC else Animation.INTERPOLATION_LINEAR
		)
		for k in [[0.0, 0.0], [1.0, 1.0], [2.0, 1.0]]:
			_approach.track_insert_key(t, k[0], k[1])
		_approach.length = 2.0
	var top: float = _run_speed if _target_run else _walk_speed
	var stop_m := top * _scale * SPRING_HALFLIFE / log(2.0)
	var x: float = clamp((dist - ARRIVE * _scale) / max(stop_m, 1e-6), 0.0, 2.0)
	return clamp(float(_approach.value_track_interpolate(0, x)), 0.0, 1.0)


# Godot's makima track interpolation (engines from 2026-09-29 on); cubic on an older engine.
static func interpolation() -> Animation.InterpolationType:
	if ClassDB.class_has_integer_constant("Animation", "INTERPOLATION_MAKIMA"):
		return (
			ClassDB.class_get_integer_constant("Animation", "INTERPOLATION_MAKIMA")
			as Animation.InterpolationType
		)
	return Animation.INTERPOLATION_CUBIC


# The AnimationTree: Godot plays and blends the clips; MotionMatchNode picks them.
func _make_tree() -> bool:
	if not is_instance_valid(_tree):
		_tree = AnimationTree.new()
		_tree.name = "MMTree"
		_player.get_parent().add_child(_tree)
		_tree.anim_player = _tree.get_path_to(_player)
		_tree.root_node = _tree.get_path_to(_player.get_node(_player.root_node))
		_tree.root_motion_track = NodePath(ROOT)
		_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	if _node == null:
		_node = MotionMatchNode.new()
	_node.mm = _mm
	_node.names = PackedStringArray()
	_node.lengths = PackedFloat32Array()
	_node.loops = PackedByteArray()
	for k in _keys:
		_node.names.append(PREFIX + k)
		var anim := _player.get_animation(PREFIX + k)
		_node.lengths.append(anim.length)
		_node.loops.append(1 if anim.loop_mode == Animation.LOOP_LINEAR else 0)
	# AnimationNodeExtension is not a root node: it sits in a blend tree that feeds the output.
	var blend := AnimationNodeBlendTree.new()
	blend.add_node("motion_matching", _node)
	blend.connect_node("output", 0, "motion_matching")
	_tree.tree_root = blend
	return true


# Arm spacing. The clips are human: arms that hang close to a slim body. Copied onto a wide body
# (a big belly, wide hips, short arms) the same angles put the forearms and hands inside it. For
# each arm, find how far from straight down the arm must hang to clear the body at rest (mesh),
# take away how far the clips' idle already holds it out, and turn the upper arm out by the rest in
# every mm_ clip, about the body's forward axis (Mixamo's "arm spacing").
func _space_arms() -> void:
	if _skeleton == null or not _player.has_animation(PREFIX + "idle"):
		return
	var idle := _player.get_animation(PREFIX + "idle")
	if idle.has_meta("arm_spacing"):
		return
	var arms := _arm_chains()
	if arms.size() != 2:
		print("MOVE-ARMS none (no two arm chains)")
		return
	var mesh := _rest_mesh()
	var report := []
	for chain in arms:
		var need := _clear_angle(chain, mesh)
		var held := _idle_spread(chain, idle)
		var turn: float = max(0.0, need - held)
		report.append(
			(
				"%s need=%.1f held=%.1f turn=%.1f"
				% [
					_skeleton.get_bone_name(chain[1]),
					rad_to_deg(need),
					rad_to_deg(held),
					rad_to_deg(turn)
				]
			)
		)
		if turn > 0.0:
			_turn_arm(chain, turn)
	idle.set_meta("arm_spacing", true)
	print("MOVE-ARMS ", "; ".join(report))


# [shoulder, upper arm, forearm, hand, ... tip] for each arm: the chains from the bone with the
# most children above the hips (the chest) that end farthest to the side.
func _arm_chains() -> Array:
	var n := _skeleton.get_bone_count()
	var hips := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	var chest := -1
	for b in n:
		if _skeleton.get_bone_children(b).size() >= 3 and b != hips:
			if chest < 0 or _rest(b).origin.y > _rest(chest).origin.y:
				chest = b
	if chest < 0:
		return []
	var out := []
	for c in _skeleton.get_bone_children(chest):
		var chain := [c]
		while _skeleton.get_bone_children(chain[-1]).size() > 0:
			var best := -1
			for k in _skeleton.get_bone_children(chain[-1]):
				if best < 0 or _side(k) > _side(best):
					best = k
			chain.append(best)
		if chain.size() >= 4 and _side(chain[-1]) > 2.0 * _side(c):
			out.append(chain)
	if out.size() > 2:
		out.sort_custom(func(a, b): return _side(a[-1]) > _side(b[-1]))
		out = out.slice(0, 2)
	return out


func _rest(b: int) -> Transform3D:
	return _to_scene(_skeleton) * _skeleton.get_bone_global_rest(b)


# How far a bone sits to the side of the hips, in the floor plane.
func _side(b: int) -> float:
	var hips := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	var d := _rest(b).origin - _rest(hips).origin
	return Vector2(d.x, d.z).length()


# Rest mesh in scene space: positions and each vertex's heaviest bone.
func _rest_mesh() -> Dictionary:
	var pos := PackedVector3Array()
	var bone := PackedInt32Array()
	for mi in _scene.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or m.skin == null:
			continue
		var xf := _to_scene(m)
		for s in m.mesh.get_surface_count():
			var a := m.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var bi = a[Mesh.ARRAY_BONES]
			var bw = a[Mesh.ARRAY_WEIGHTS]
			if bi == null or bw == null or v.is_empty():
				continue
			var per := int(bi.size() / v.size())
			for i in v.size():
				var top := 0
				for k in per:
					if bw[i * per + k] > bw[i * per + top]:
						top = k
				var bind := int(bi[i * per + top])
				var sb := m.skin.get_bind_bone(bind)
				if sb < 0:
					sb = _skeleton.find_bone(m.skin.get_bind_name(bind))
				pos.append(xf * v[i])
				bone.append(sb)
	return {pos = pos, bone = bone}


func _axis(chain: Array) -> Vector3:
	var hips := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	var side := _rest(chain[1]).origin - _rest(hips).origin
	side.y = 0
	return Vector3.DOWN.cross(side.normalized()).normalized()


# Smallest angle out from straight down at which the whole arm (shoulder joint to tip, as a
# segment half again as thick as the arm) misses every body vertex below the shoulder.
func _clear_angle(chain: Array, mesh: Dictionary) -> float:
	var arm := {}
	for b in chain.slice(1):
		arm[b] = true
	var s := _rest(chain[1]).origin
	var length := 0.0
	for i in range(1, chain.size() - 1):
		length += _rest(chain[i]).origin.distance_to(_rest(chain[i + 1]).origin)
	# Arm thickness: median distance of upper arm and forearm vertices from their bones.
	var radii := []
	var body := PackedVector3Array()
	var p: PackedVector3Array = mesh.pos
	var bo: PackedInt32Array = mesh.bone
	for i in p.size():
		var b := bo[i]
		if b == chain[1] or b == chain[2]:
			var a := _rest(b).origin
			var e := _rest(chain[chain.find(b) + 1]).origin
			radii.append(Geometry3D.get_closest_point_to_segment(p[i], a, e).distance_to(p[i]))
		elif not arm.has(b) and b != chain[0] and p[i].y < s.y - 0.1 * length:
			body.append(p[i])
	if radii.is_empty() or body.is_empty():
		return 0.0
	radii.sort()
	var r: float = radii[radii.size() / 2]
	# A few thousand body points are enough to find the gap, and keep this quick on big meshes.
	if body.size() > 4000:
		var few := PackedVector3Array()
		var step := body.size() / 4000.0
		for i in 4000:
			few.append(body[int(i * step)])
		body = few
	var ax := _axis(chain)
	for deg in range(0, 61):
		var tip := s + Vector3.DOWN.rotated(ax, deg_to_rad(deg)) * length
		var clear := INF
		for q in body:
			clear = min(clear, Geometry3D.get_closest_point_to_segment(q, s, tip).distance_to(q))
		# Half an arm more than touching: the forearm swings in while walking. Measured on
		# SK_CharacterMedium: arm vertices inside the body fell from 26-38% to 1.5-2.4% (idle, walk,
		# run, turn); touching (1.0) left 5-15%.
		if clear >= 1.5 * r:
			return deg_to_rad(deg)
	return deg_to_rad(60.0)


# How far out from straight down the idle clip holds the arm (shoulder joint to wrist), median.
func _idle_spread(chain: Array, idle: Animation) -> float:
	var vals := []
	var ax := _axis(chain)
	var steps := 20
	for i in steps:
		var t := idle.length * float(i) / steps
		var g := {}
		var place := func(b: int) -> Transform3D:
			var local := _skeleton.get_bone_rest(b)
			var tr := idle.find_track(
				NodePath("%s:%s" % [_hips_path.get_slice(":", 0), _skeleton.get_bone_name(b)]),
				Animation.TYPE_ROTATION_3D
			)
			if tr >= 0:
				local.basis = Basis(idle.rotation_track_interpolate(tr, t)).scaled(
					local.basis.get_scale()
				)
			return local
		# Pose relative to the chest at rest, so only the arm's own angles count.
		var xf := _rest(_skeleton.get_bone_parent(chain[0]))
		for b in chain.slice(0, 4):
			xf = xf * place.call(b)
			g[b] = xf.origin
		var d: Vector3 = g[chain[3]] - g[chain[1]]
		# Angle out from straight down within the plane across the body.
		var side := ax.cross(Vector3.DOWN)
		vals.append(atan2(d.dot(side), -d.y))
	vals.sort()
	return max(0.0, vals[vals.size() / 2])


func _turn_arm(chain: Array, angle: float) -> void:
	var parent_rest := _rest(chain[0]).basis.get_rotation_quaternion()
	var spin := Quaternion(parent_rest.inverse() * _axis(chain), angle)
	var path := NodePath(
		"%s:%s" % [_hips_path.get_slice(":", 0), _skeleton.get_bone_name(chain[1])]
	)
	for anim_name in _player.get_animation_list():
		if not anim_name.begins_with(PREFIX):
			continue
		var anim := _player.get_animation(anim_name)
		var tr := anim.find_track(path, Animation.TYPE_ROTATION_3D)
		if tr < 0:
			continue
		for k in anim.track_get_key_count(tr):
			var q: Quaternion = anim.track_get_key_value(tr, k)
			anim.track_set_key_value(tr, k, (spin * q).normalized())


# The SOMA root travel of a clip, first frame to last, from mm.elf's clip table.
func _mm_root(key: String) -> Vector3:
	var lines := str(_mm.vmcall("mm_clips")).split("\n", false)
	for line in lines:
		var w := line.split(" ")
		if w[0] == key and w.size() >= 6:
			return Vector3(float(w[4]), 0, float(w[5]))
	return Vector3.ZERO


# Where the clip's hips are on the floor at time t, in the model's space.
func _root_model(anim: Animation, t: float) -> Vector3:
	var local := anim.position_track_interpolate(_hips_track, t)
	var p := local
	if _skeleton:
		var bone := _skeleton.find_bone(_hips_path.get_slice(":", 1))
		var parent := _skeleton.get_bone_parent(bone) if bone >= 0 else -1
		if parent >= 0:
			p = _skeleton.get_bone_global_rest(parent) * local
		p = _to_scene(_skeleton) * p
	return Vector3(p.x, 0, p.z)


func _to_scene(n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur and cur != _scene:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


func _begin() -> void:
	# Start from where the model stands and the way it faces (a second M goes on from there).
	_mm.vmcall("mm_reset", 0.0, 0.0, _scene.rotation.y, max(0, _keys.find("idle")))
	_player.stop()
	_player.active = false
	_node.reset()
	_tree.active = true
	_clip = -1
	_mode = STAND
	_jump_pressed = false
	_clear_target()
	_origin = _scene.position
	# Third person, high and behind, looking down at the character like a Blue Archive field: the camera
	# sits WALK_CAM_DISTANCE metres from the middle of the body, pitched WALK_CAM_PITCH degrees down, behind
	# the way the character faces. The floor fills the view, so a click or tap reaches it easily. stop() puts
	# the camera back as it was.
	var cc0 := get_parent().get_node_or_null("CamController") as Node3D
	var rot := get_parent().get_node_or_null("CamController/CamRotHelper") as Node3D
	var eye_cam := get_parent().get_node_or_null("CamController/CamRotHelper/Camera3D") as Node3D
	if cc0 and rot and eye_cam:
		_cam_before = {
			"pos": cc0.position, "yaw": cc0.rotation.y, "scale": cc0.scale, "pitch": rot.rotation.x
		}
		var facing := _scene.global_transform.basis.z  # a model faces +Z
		facing.y = 0.0
		if facing.length() > 0.01:
			cc0.rotation.y = atan2(-facing.x, -facing.z)  # the camera looks along the character's facing
		rot.rotation.x = deg_to_rad(WALK_CAM_PITCH)
		cc0.scale = Vector3.ONE * (WALK_CAM_DISTANCE / eye_cam.position.z)
		if cc0.has_method("_cog"):
			var middle: Vector3 = cc0._cog(_scene, cc0._bounds(_scene))  # the hips: the middle of the body
			cc0.position = Vector3(_origin.x, middle.y, _origin.z)
	on = true
	add_to_group("walk_mode")
	_last_world = _origin
	_push = Vector3.ZERO
	if course:
		var vc := _view_cam()
		course.place(_origin, -vc.global_transform.basis.z if vc else Vector3(0, 0, -1), _scale)
	say(HELP)


func _input_dir() -> Vector2:
	if _test:
		return _test_input
	var v := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_LEFT_X), -Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	)
	if v.length() < 0.2:
		v = Vector2.ZERO
	elif v.length() > 1.0:
		v = v.normalized()
	if Input.is_key_pressed(KEY_W):
		v.y += 1
	if Input.is_key_pressed(KEY_S):
		v.y -= 1
	if Input.is_key_pressed(KEY_A):
		v.x -= 1
	if Input.is_key_pressed(KEY_D):
		v.x += 1
	return v.normalized() if v.length() > 1.0 else v


func _process(delta: float) -> void:
	if not _test:
		_pad()
	if not on or _mm == null:
		return
	# Step the controller by the real frame time. A floor here (it was 1/240 s) made the
	# character move faster than the clock above 240 fps, for example with no vsync.
	if delta <= 0.0:
		return
	var dt: float = min(delta, 1.0 / 20.0)
	var input := _input_dir()
	var running := (
		_test_run
		if _test
		else (
			Input.is_key_pressed(KEY_SHIFT) or Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) > 0.5
		)
	)
	if _test and not _keys_testing:
		_mode = _test_mode
		_jump_pressed = _jump_pressed or _test_jump
		_test_jump = false
	# The right stick turns the camera.
	# Walk to the tapped point unless a move key or the stick takes over.
	var steer := Vector3.ZERO
	var brake := 1.0
	if input != Vector2.ZERO:
		_clear_target()
	elif _has_target:
		var to := _target - _last_world
		to.y = 0.0
		if to.length() < ARRIVE * _scale:
			_clear_target()
		else:
			steer = to.normalized()
			running = running or _target_run
			brake = _approach_share(to.length())
	var cc0 := get_parent().get_node_or_null("CamController") as Node3D
	var rx := Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
	if cc0 and abs(rx) > 0.2 and not _test:
		cc0.rotate_y(-rx * 2.0 * dt)
	# Clip speeds are SOMA metres a second; the scene is the rig's size. Only standing runs.
	var base: float = (
		_mode_speed[_mode] if _mode != STAND else (_run_speed if running else _walk_speed)
	)
	var speed := base * _scale * (1.0 if steer != Vector3.ZERO else input.length())
	speed *= brake
	# Camera-relative input in the scene: forward is away from the camera, on the floor.
	var cam := _view_cam()
	var fwd := Vector3(0, 0, -1)
	var right := Vector3(1, 0, 0)
	# The test goes through the camera too, so it checks what a player sees.
	if cam:
		fwd = -cam.global_transform.basis.z
		fwd.y = 0
		fwd = fwd.normalized() if fwd.length() > 1e-4 else Vector3(0, 0, -1)
		right = Vector3(-fwd.z, 0, fwd.x)
	var want := (
		(fwd * input.y + right * input.x).normalized() * speed if speed > 0 else Vector3.ZERO
	)
	if steer != Vector3.ZERO:
		want = steer * speed
	# Scene to SOMA: undo the rig's turn and scale.
	var soma_v := want.rotated(Vector3.UP, -_phi) / _scale
	_node.velocity = Vector2(soma_v.x, soma_v.z)
	_node.mode = _mode
	_node.jump = _jump_pressed
	_jump_pressed = false
	# MotionMatchNode steps mm.elf and Godot blends the clips it picks.
	_tree.advance(dt)
	var r := _node.result
	if r.size() < 15:
		return
	_jumping = r[14] > 0.5
	_kind = int(r[13])
	_clip = _node.clip
	# The root motion track holds the floor travel, so the model's origin is the character.
	var turn: float = float(r[4]) - float(r[7])
	var char_scene := Vector3(r[2], 0, r[3]).rotated(Vector3.UP, _phi) * _scale + _origin
	# On the obstacle course the model stands on what is under it: up a step at once, down at a
	# rate, so it drops off a ledge over a few frames rather than in one.
	if course and course.visible:
		# Walls block: the move slides along anything taller than a step, for the mode's height.
		var raw := char_scene
		char_scene = course.slide(_last_world, raw + _push, _mode, _scale)
		_push = Vector3(char_scene.x - raw.x, 0, char_scene.z - raw.z)
		var gy := course.ground(Vector3(char_scene.x, _last_world.y, char_scene.z), _origin.y)
		char_scene.y = (
			gy if gy >= _last_world.y else lerp(_last_world.y, gy, 1.0 - exp(-dt * 12.0))
		)
	_scene.transform = Transform3D(Basis(Vector3.UP, turn), char_scene)
	if _trace:
		var hb := _skeleton.find_bone(_hips_path.get_slice(":", 1))
		var hw := (_skeleton.global_transform * _skeleton.get_bone_global_pose(hb)).origin
		print(
			(
				"MOVE-TRACE %d %s t=%.3f hips=%.3f,%.3f char=%.3f,%.3f"
				% [
					Engine.get_process_frames(),
					_node.names[_clip] if _clip >= 0 and _clip < _node.names.size() else "",
					_node.time,
					hw.x,
					hw.z,
					char_scene.x,
					char_scene.z
				]
			)
		)
	# The camera follows.
	var cc := get_parent().get_node_or_null("CamController") as Node3D
	if cc:
		cc.position += char_scene - _last_world
	_last_world = char_scene
	# The floor's grid balls (GizmoPlane) fade around the character.
	var balls := get_parent().get_node_or_null("GizmoPlane")
	if balls and balls.has_method("set_focus"):
		balls.set_focus(char_scene)
	if _orbit_cam and cc:
		_orbit_a += deg_to_rad(ORBIT_DEG_S) * dt
		var c := cc.global_transform
		_orbit_cam.global_transform = (
			Transform3D(Basis(Vector3.UP, _orbit_a), c.origin)
			* Transform3D(c.basis, Vector3.ZERO)
			* _orbit_rel
		)
	var label := "Walk mode, %s%s\n%s" % [MODE_NAMES[_mode], ", jumping" if _jumping else "", HELP]
	if status.is_valid():
		status.call(label)


# x: the largest angle in radians between a bone's pose and the picked clip at the node's time.
# y: how far the hips are from the character on the floor.
func _pose_error() -> Vector2:
	if not _node or _node.clip < 0 or not _skeleton:
		return Vector2(-1, -1)
	var hips := _skeleton.to_global(
		_skeleton.get_bone_global_pose(_skeleton.find_bone(_hips_path.get_slice(":", 1))).origin
	)
	var off := Vector2(hips.x - _last_world.x, hips.z - _last_world.z).length()
	var anim := _player.get_animation(PREFIX + _keys[_node.clip])
	var worst := 0.0
	for t in anim.get_track_count():
		if anim.track_get_type(t) != Animation.TYPE_ROTATION_3D:
			continue
		var bone := _skeleton.find_bone(str(anim.track_get_path(t)).get_slice(":", 1))
		if bone < 0:
			continue
		var want := anim.rotation_track_interpolate(t, _node.time)
		worst = max(worst, want.angle_to(_skeleton.get_bone_pose_rotation(bone)))
	return Vector2(worst, off)


func _run_test() -> void:
	if not _has_moves():
		printerr("MOVE-FAIL the opened file has no moves")
		get_tree().quit(1)
		return
	if not _bake():
		get_tree().quit(1)
		return
	_begin()
	if OS.get_environment("MOVE_PLANT") == "wrong-clip":
		# Planted fault for the test itself: the tree plays the next clip, not the picked one.
		var shifted := _node.names.slice(1)
		shifted.append(_node.names[0])
		_node.names = shifted
	# MOVE_STEPS=walk,turn,run plays only those steps (for a video) and skips the key and tap
	# tests; the run is then not judged as a whole.
	var only := OS.get_environment("MOVE_STEPS")
	var keys_ok := true if only != "" else await _key_test()
	if _orbit:
		_start_orbit()
	var shots := OS.get_environment("MOVE_SHOT")
	var cc := get_parent().get_node_or_null("CamController") as Node3D
	if shots != "" and cc:
		# Step back so the whole model is in the pictures.
		cc.scale *= 2.0
	# [name, input, run, seconds, heading in degrees (0 = away from the camera, 90 = right)]
	# [name, input, run, seconds, heading in degrees (0 = away from the camera, 90 = right),
	#  mode, jump]
	var plan := [
		["idle", Vector2.ZERO, false, 2.0, 0.0, STAND, false],
		["walk", Vector2(0, 1), false, 5.0, 0.0, STAND, false],
		["turn", Vector2(1, 0), false, 4.0, 90.0, STAND, false],
		["run", Vector2(1, 0), true, 4.0, 90.0, STAND, false],
		["jump", Vector2(1, 0), false, 3.0, 90.0, STAND, true],
		["crouch", Vector2(0, 1), false, 5.0, 0.0, CROUCH, false],
		["crawl", Vector2(0, 1), false, 6.0, 0.0, CRAWL, false],
		["stand", Vector2.ZERO, false, 3.0, 0.0, STAND, false],
	]
	# MOVE_STEPS=course: run straight down the obstacle course (with --obstacle-course).
	if only == "course":
		plan = [["course", Vector2(0, 1), true, 26.0, 0.0, STAND, false]]
	# MOVE_STEPS=course-stages: the course in stages, each ending when the hips reach its stop distance (metres from
	# the start, in the scaled course; 0.851 of the course's own metres for the 1.75 m person), with the pose kind the
	# station asks for: crouch under the bar, crawl through the tunnel, jump the gap.
	var stage_stop := {}
	if only == "course-stages":
		plan = [
			["approach", Vector2(0, 1), true, 60.0, 0.0, STAND, false],
			["duck", Vector2(0, 1), false, 20.0, 0.0, CROUCH, false],
			["stand_up", Vector2(0, 1), false, 10.0, 0.0, STAND, false],
			["crawl", Vector2(0, 1), false, 20.0, 0.0, CRAWL, false],
			["to_gap", Vector2(0, 1), true, 20.0, 0.0, STAND, false],
			["jump", Vector2(0, 1), true, 10.0, 0.0, STAND, true],
			["finish", Vector2(0, 1), true, 20.0, 0.0, STAND, false],
		]
		stage_stop = {"approach": 33.2, "duck": 35.0, "stand_up": 35.8, "crawl": 38.6, "to_gap": 40.6, "jump": 42.2, "finish": 44.8}
	var ok := keys_ok and _test_loops()
	for step in plan:
		if only != "" and only != "course-stages" and not step[0] in only.split(","):
			continue
		_test_input = step[1]
		_test_run = step[2]
		_test_mode = step[5]
		_test_jump = step[6]
		if step[5] != STAND and _mode_speed[step[5]] <= 0.0:
			print("MOVE-STEP %s SKIP no poses of that kind" % step[0])
			continue
		var seen := {}
		var t := 0.0
		var kind_ok := 0.0
		var kind_all := 0.0
		var air := 0.0
		var jumped := false
		var pose_err := 0.0
		var hips_off := 0.0
		var measured := 0
		# The body must not leap: in one frame the hips may move at most 1.5 times what running
		# does in the longest frame (a clip switch used to throw them metres, then back).
		var hips_prev := _hips_world()
		var leap := 0.0
		# Judge the second half of each step: the first half is the change of direction.
		var p0 := _last_world
		var faces: Array[Vector2] = []
		var face_at: Array = []
		var step_frames := 0
		var chk_head := -INF  # highest head bone, tallest back point, lowest-bone height and lowest ground in the stage
		var chk_back := -INF
		var chk_low := -INF
		var chk_ground := INF
		while t < step[3] and not (stage_stop.has(step[0]) and _last_world.z >= stage_stop[step[0]]):
			await get_tree().process_frame
			var dt := get_process_delta_time()
			t += dt
			step_frames += 1
			seen[_keys[_clip]] = true
			jumped = jumped or _jumping
			var hw := _hips_world()
			# Counted from the step's start, so two runs print the same frames.
			if step[0] == "course" and course and step_frames % 36 == 0:
				var lc := course.to_local(_last_world)
				print(
					(
						"COURSE-AT t=%.2f along=%.4f m height=%.4f m held=%.4f m"
						% [t, -lc.z, lc.y, _push.length() / _scale]
					)
				)
			var step_m := Vector2(hw.x - hips_prev.x, hw.z - hips_prev.z).length()
			# In units of the longest honest frame step: running for the 1/20 s frame cap.
			leap = max(leap, step_m / (_run_speed * _scale / 20.0))
			hips_prev = hw
			if stage_stop.has(step[0]):
				var hd := _skeleton.find_bone("J_Bip_C_Head")
				if hd >= 0:
					chk_head = max(chk_head, (_skeleton.global_transform * _skeleton.get_bone_global_pose(hd)).origin.y)
				chk_back = max(chk_back, hw.y)
				chk_low = max(chk_low, _lowest_bone_y())
				chk_ground = min(chk_ground, _last_world.y)
			if stage_stop.has(step[0]) and Engine.get_process_frames() % 12 == 0:
				var bw := {}
				for bn in ["J_Bip_C_Head", "J_Bip_L_Hand", "J_Bip_R_Hand", "J_Bip_L_Foot", "J_Bip_R_Foot", "J_Bip_L_LowerLeg"]:
					var bi := _skeleton.find_bone(bn)
					bw[bn] = snappedf((_skeleton.global_transform * _skeleton.get_bone_global_pose(bi)).origin.y, 0.001) if bi >= 0 else -9.0
				print("STAGE-BONES %s scene_y=%.3f origin_y=%.3f scale=%.3f %s" % [step[0], _scene.global_transform.origin.y, _origin.y, _scale, str(bw)])
				print("STAGE-FLOOR %s z=%.2f lowest_bone_y=%.3f char_y=%.3f hips_y=%.3f kind=%d clip=%s" % [step[0], _last_world.z, _lowest_bone_y(), _last_world.y, hw.y, _kind, str(_keys[_clip])])
			if _kind == 4:
				air += dt
			var e := _pose_error()
			if e.x >= 0.0:
				measured += 1
				pose_err = max(pose_err, e.x)
				hips_off = max(hips_off, e.y)
			if t < step[3] * 0.5:
				p0 = _last_world
			else:
				kind_all += dt
				kind_ok += dt if _kind == step[5] else 0.0
				var f := _hips_forward()
				faces.append(Vector2(f.x, f.z).normalized() * dt)
				face_at.append([t, str(_keys[_clip])])
		if stage_stop.has(step[0]):
			var reached: bool = _last_world.z >= stage_stop[step[0]]
			var verdict := reached
			var detail := ""
			var lim := _course_limits()
			var head_top := 0.19 * _scale  # the head bone to the top of the head
			match step[0]:
				"duck":
					var room: float = lim.bar * _scale - (chk_head + head_top)
					verdict = verdict and room >= 0.0
					detail = "head_top %.3f bar_underside %.3f room %.3f" % [chk_head + head_top, lim.bar * _scale, room]
				"crawl":
					var room: float = lim.roof * _scale - (chk_head + head_top)
					verdict = verdict and room >= 0.0 and chk_low < lim.roof * _scale
					detail = "head_top %.3f roof_underside %.3f room %.3f lowest_bone_max %.3f" % [chk_head + head_top, lim.roof * _scale, room, chk_low]
				"jump":
					verdict = verdict and air >= 0.2 and chk_ground >= 0.5 * lim.plat * _scale
					detail = "air %.2f s lowest_ground %.3f platform %.3f" % [air, chk_ground, lim.plat * _scale]
			print("COURSE-CHECK %s pass=%d reached=%d %s" % [step[0], 1 if verdict else 0, 1 if reached else 0, detail])
		if stage_stop.has(step[0]):
			print("COURSE-STAGE %s reached=%d z=%.2f stop=%.1f t=%.1f kind=%d" % [step[0], 1 if _last_world.z >= stage_stop[step[0]] else 0, _last_world.z, stage_stop[step[0]], t, _kind])
		var moved: Vector3 = _last_world - p0
		var secs: float = step[3] * 0.5
		var speed: float = Vector2(moved.x, moved.z).length() / secs
		var want: float = 0.0
		if step[1] != Vector2.ZERO:
			var base: float = _mode_speed[step[5]]
			if step[5] == STAND:
				base = _run_speed if step[2] else _walk_speed
			want = base * _scale
		# Heading as the player sees it: 0 = away from the camera, 90 = to its right.
		var cam := _view_cam()
		var cf := -cam.global_transform.basis.z if cam else Vector3(0, 0, -1)
		cf = Vector3(cf.x, 0, cf.z).normalized()
		var cr := Vector3(-cf.z, 0, cf.x)
		var heading: float = rad_to_deg(atan2(moved.dot(cr), moved.dot(cf)))
		# Facing: the model's own forward (rest +Z turned by the scene) against the way it went.
		# The hips carry the clip's own turn (root motion moves only the floor travel), so read
		# the forward off the posed hips: the rest forward in the hips' frame, turned by the pose.
		# A stride swings the hips, so one frame depends on where the frame falls in the stride:
		# judge the time-weighted mean over the judged half, and print the worst frame as well.
		var mean_face := Vector2.ZERO
		var face_worst := 0.0
		var way := Vector2(moved.x, moved.z)
		var worst_at := [0.0, ""]
		for i in faces.size():
			var f: Vector2 = faces[i]
			mean_face += f
			if way.length() > 0.01 and f.length() > 0.0:
				var a: float = abs(rad_to_deg(way.angle_to(f)))
				if a > face_worst:
					face_worst = a
					worst_at = face_at[i]
		if step[0] == "run":
			print(
				(
					"MOVE-FACE run worst=%.0f at=%.3fs of %.1fs clip=%s"
					% [face_worst, worst_at[0], step[3], worst_at[1]]
				)
			)
			for i in range(0, faces.size(), max(1, faces.size() / 24)):
				print(
					(
						"MOVE-FACE t=%.3f off=%.0f clip=%s"
						% [face_at[i][0], rad_to_deg(way.angle_to(faces[i])), face_at[i][1]]
					)
				)
		var face_off: float = (
			rad_to_deg(way.angle_to(mean_face))
			if moved.length() > 0.01 and mean_face.length() > 0.0
			else 0.0
		)
		var off: float = abs(wrapf(heading - step[4], -180.0, 180.0))
		var share: float = kind_ok / kind_all if kind_all > 0.0 else 0.0
		# Too fast fails too: a controller step that does not follow the frame time overshoots
		# at high frame rates (seen: 5.0 for 1.76 on Windows with no vsync).
		var good: bool = (
			speed < 0.2 * _scale
			if want == 0.0
			else (
				speed > 0.6 * want and speed < 1.25 * want and off < 25.0 and abs(face_off) < 60.0
			)
		)
		if step[6]:
			good = jumped and air > 0.1
		elif step[5] != STAND:
			good = good and share >= 0.7
		# The skeleton shows the picked clip (the tree plays it), and the hips stand over the
		# character (the root motion track took the floor travel).
		good = good and measured > 0 and pose_err < 0.02 and hips_off < 0.01 * _scale and leap < 1.5
		print(
			(
				"MOVE-STEP %s speed=%.2f want=%.2f heading=%.0f facing_off=%.0f facing_worst=%.0f leap=%.2f kind_share=%.2f air=%.2f pose_err=%.4f hips_off=%.4f clips=%s %s"
				% [
					step[0],
					speed,
					want,
					heading,
					face_off,
					face_worst,
					leap,
					share,
					air,
					pose_err,
					hips_off,
					",".join(seen.keys()),
					"ok" if good else "BAD"
				]
			)
		)
		if shots != "":
			get_viewport().get_texture().get_image().save_png(shots + "-%s.png" % step[0])
		ok = ok and good
	if only != "":
		_print_card()
		print("MOVE-SEAMS %d" % _node.seams)
		print("MOVE-VIDEO-DONE steps=%s" % only)
		get_tree().quit(0)
		return
	# Walk to a point: a real left click on the floor, sent through the input queue, then a double
	# click to run. Pass = the model gets there and stops there.
	var walked := 0.0
	for tap in [["tap-walk", false], ["tap-run", true]]:
		var took: float = await _test_tap(tap[0], tap[1])
		# Running there must be clearly quicker than walking the same distance.
		var good: bool = took > 0.0 and (not tap[1] or took < 0.8 * walked)
		if tap[1]:
			print(
				(
					"MOVE-STEP tap-quicker run=%.2fs walk=%.2fs %s"
					% [took, walked, "ok" if good else "BAD"]
				)
			)
		walked = took if not tap[1] else walked
		if shots != "":
			get_viewport().get_texture().get_image().save_png(shots + "-%s.png" % tap[0])
		ok = ok and good
	ok = await _test_stay() and ok
	print("MOVE-SEAMS %d" % _node.seams)
	print("MOVE-OK" if ok else "MOVE-FAIL")
	get_tree().quit(0 if ok else 1)


# Loops and one-shots are told apart: every clip clips.tsv marks "loop" plays as a loop
# (LOOP_LINEAR) and every other as a one-shot (LOOP_NONE), and the package has both kinds. A
# package built from clip data without loop.txt files has no loops and fails here.
func _test_loops() -> bool:
	var loops := clip_loops()
	var want := 0
	var wrong := PackedStringArray()
	for k in _keys:
		var is_loop: bool = loops.get(k, false)
		want += 1 if is_loop else 0
		var anim := _player.get_animation(PREFIX + k)
		var mode := Animation.LOOP_LINEAR if is_loop else Animation.LOOP_NONE
		if anim == null or anim.loop_mode != mode:
			wrong.append(k)
	var good := want > 0 and want < _keys.size() and wrong.is_empty()
	print(
		(
			"MOVE-STEP loops loops=%d one-shots=%d wrong=%s %s"
			% [want, _keys.size() - want, ",".join(wrong), "ok" if good else "BAD"]
		)
	)
	return good


# M off leaves the model where it stopped, facing the same way, and the next M goes on from there.
func _test_stay() -> bool:
	_test_input = Vector2(1, 0)
	for i in 60:
		await get_tree().process_frame
	_test_input = Vector2.ZERO
	for i in 30:
		await get_tree().process_frame
	var here := _last_world
	var face := _hips_forward()
	stop()
	for i in 3:
		await get_tree().process_frame
	var rest := _scene.global_transform.basis * (_to_scene(_skeleton).basis * Vector3.BACK)
	var moved: float = Vector2(_scene.position.x - here.x, _scene.position.z - here.z).length()
	var turned: float = rad_to_deg(abs(Vector2(face.x, face.z).angle_to(Vector2(rest.x, rest.z))))
	_begin()
	for i in 30:
		await get_tree().process_frame
	var again: float = Vector2(_last_world.x - here.x, _last_world.z - here.z).length()
	var face2 := _hips_forward()
	var turned2: float = rad_to_deg(
		abs(Vector2(face.x, face.z).angle_to(Vector2(face2.x, face2.z)))
	)
	var good: bool = (
		moved < 0.05 * _scale and turned < 20.0 and again < 0.1 * _scale and turned2 < 25.0
	)
	print(
		(
			"MOVE-STEP stay off_moved=%.3f off_turned=%.0f on_moved=%.3f on_turned=%.0f %s"
			% [moved, turned, again, turned2, "ok" if good else "BAD"]
		)
	)
	return good


# Seconds to get to a clicked point and stop there, or -1 on a failure.
func _test_tap(name: String, run: bool) -> float:
	var cam := get_viewport().get_camera_3d()
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := Vector3(-fwd.z, 0, fwd.x)
	var goal := _last_world + (fwd * 2.5 + right * 0.5) * _scale
	var pos := cam.unproject_position(goal)
	if cam.is_position_behind(goal) or not get_viewport().get_visible_rect().has_point(pos):
		print("MOVE-STEP %s BAD the point is off screen" % name)
		return -1.0
	_test_input = Vector2.ZERO
	_test_run = false
	_test_mode = STAND
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.double_click = run and pressed
		e.position = pos
		e.global_position = pos
		Input.parse_input_event(e)
		await get_tree().process_frame
	if not _has_target:
		print("MOVE-STEP %s BAD the click set no point" % name)
		return -1.0
	var set_err := Vector2(_target.x - goal.x, _target.z - goal.z).length()
	var t := 0.0
	var arrived := -1.0
	while t < 8.0:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		t += dt
		if arrived < 0.0 and not _has_target:
			arrived = t
		if arrived >= 0.0 and t > arrived + 2.0:
			break
	var off := Vector2(_last_world.x - goal.x, _last_world.z - goal.z).length() / _scale
	var good := arrived >= 0.0 and off < 2.0 * ARRIVE and set_err < 0.05 * _scale
	print(
		(
			"MOVE-STEP %s arrived=%.2fs off=%.2fm set_err=%.3fm %s"
			% [name, arrived, off, set_err / _scale, "ok" if good else "BAD"]
		)
	)
	return arrived if good else -1.0


func _hips_forward() -> Vector3:
	var hb := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	var at_rest := _skeleton.global_transform * _skeleton.get_bone_global_rest(hb)
	var posed := _skeleton.global_transform * _skeleton.get_bone_global_pose(hb)
	var rest_fwd := _scene.global_transform.basis * (_to_scene(_skeleton).basis * Vector3.BACK)
	var local := at_rest.basis.orthonormalized().inverse() * rest_fwd
	return posed.basis.orthonormalized() * local


# The camera the walk input and the heading are measured against: the starting camera while an
# orbit video circles the view, else the current one.
func _view_cam() -> Camera3D:
	return _input_cam if _input_cam else get_viewport().get_camera_3d()


# The course's clear heights, in course metres, read from colliders.json: the crouch bar's underside, the tunnel roof's
# underside and the platforms' height.
func _course_limits() -> Dictionary:
	var out := {"bar": INF, "roof": INF, "plat": 0.0}
	var cols: Array = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("COURSE_COLLIDERS") if OS.get_environment("COURSE_COLLIDERS") != "" else "res://vsk_model_explorer/course/colliders.json")).colliders
	for c in cols:
		var p: Array = c.prim
		var n: String = c.name
		if n.begins_with("Beam") and p[2] > 1.0:
			out.bar = min(out.bar, p[2] - p[5])
		elif n.begins_with("Tunnel") and int(p[0]) == 2:
			out.roof = min(out.roof, p[2] - p[5])
		elif n.begins_with("PlatformNear"):
			out.plat = p[2] + p[5]
	return out


func _lowest_bone_y() -> float:
	var y := INF
	if _skeleton:
		for b in _skeleton.get_bone_count():
			y = min(y, (_skeleton.global_transform * _skeleton.get_bone_global_pose(b)).origin.y)
	return y


func _start_orbit() -> void:
	var cc := get_parent().get_node_or_null("CamController") as Node3D
	_input_cam = get_viewport().get_camera_3d()
	if cc == null or _input_cam == null:
		return
	var at := Transform3D(cc.global_transform.basis, cc.global_position)
	_orbit_rel = at.affine_inverse() * _input_cam.global_transform
	# Step back so the whole model and a few metres of grid are in view, and look down a bit more.
	_orbit_rel.origin *= 2.5
	_orbit_rel = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-10.0)), Vector3.ZERO) * _orbit_rel
	# The movie is the project's viewport size; a window whose title bar takes part of that gets
	# scaled up and cropped at the sides (the help card lost its left edge). A borderless window
	# of exactly the movie size records 1:1.
	var w := get_window()
	w.borderless = true
	w.size = Vector2i(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height")
	)
	# The video shows the scene only: hide the panels and cards.
	for n in get_parent().find_children("*", "Control", true, false):
		if not n.get_parent() is Control:
			(n as Control).visible = false
	_orbit_cam = Camera3D.new()
	_orbit_cam.fov = _input_cam.fov
	_orbit_cam.far = _input_cam.far
	get_parent().add_child(_orbit_cam)
	_orbit_cam.make_current()


func _hips_world() -> Vector3:
	var b := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	return (_skeleton.global_transform * _skeleton.get_bone_global_pose(b)).origin


# Walk keys go to the walk only: with the Loop toggle focused, Space jumps and does not flip the
# toggle, and C crouches and does not show the colour chart. Sends real key events.
func _key_test() -> bool:
	var chart := get_tree().root.find_child("ColorCharts", true, false) as Node3D
	var toggle_btn: CheckButton = null
	for b in get_tree().root.find_children("*", "CheckButton", true, false):
		if (b as CheckButton).text == "Loop":
			toggle_btn = b
	var chart_was: bool = chart.visible if chart else false
	var loop_was: bool = toggle_btn.button_pressed if toggle_btn else false
	_keys_testing = true
	var jumps0 := _space_jumps
	if toggle_btn:
		toggle_btn.grab_focus()
	for key in [KEY_C, KEY_SPACE]:
		for down in [true, false]:
			var e := InputEventKey.new()
			e.keycode = key
			e.physical_keycode = key
			e.pressed = down
			Input.parse_input_event(e)
			await get_tree().process_frame
	await get_tree().process_frame
	var crouched := _mode == CROUCH
	var jumped := _space_jumps > jumps0
	_keys_testing = false
	_jump_pressed = false
	var chart_same: bool = chart == null or chart.visible == chart_was
	var loop_same: bool = toggle_btn == null or toggle_btn.button_pressed == loop_was
	_mode = STAND
	if toggle_btn:
		toggle_btn.release_focus()
	var good := (
		crouched and jumped and chart_same and loop_same and chart != null and toggle_btn != null
	)
	print(
		(
			"MOVE-STEP keys crouched=%s jumped=%s chart_unchanged=%s loop_unchanged=%s found=%s,%s %s"
			% [
				crouched,
				jumped,
				chart_same,
				loop_same,
				chart != null,
				toggle_btn != null,
				"ok" if good else "BAD"
			]
		)
	)
	return good


# Where the help card sits: CARD-OK when all of it is inside the window, else CARD-CLIPPED.
func _print_card() -> void:
	var ar = status.get_object() if status.is_valid() else null
	if ar == null or not ar.has_method("card_rect"):
		return
	var r: Rect2 = ar.card_rect()
	var win := get_viewport().get_visible_rect()
	print("%s rect=%s window=%s" % ["CARD-OK" if win.encloses(r) else "CARD-CLIPPED", r, win.size])
