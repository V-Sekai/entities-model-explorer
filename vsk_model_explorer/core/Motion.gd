extends Node
# Desktop motion: makes one clip of the set in res://motion/clips.tsv for the open rigged model.
# motion.elf runs Kimodo (text to motion on the SOMA skeleton) on a local RenderingDevice; the
# text input of each clip is made beforehand (res://motion/<key>.f32), because Kimodo's text
# encoder is too large to ship. skintokens.elf then cuts the clip into a loop or a one-shot,
# moves it onto the model's rig and adds it to the file, first, with RESET kept. The weights are
# w/Kimodo-SOMA-RP-v1.1-gguf/ beside the program.
# Test mode: `-- <rigged.glb> --motion-quit=<key>` makes that clip once the file is open, opens
# the result, then quits with 0, or with 1 on any failure.

signal made(path: String, clip: String)

const Bintr = preload("res://vsk_model_explorer/core/Bintr.gd")
const CLIPS := "res://motion/clips.tsv"
const MOTION_ELF := "res://motion.elf"
const RIG_ELF := "res://skintokens.elf"
const KIMODO := "Kimodo-SOMA-RP-v1.1-gguf/kimodo-soma-rp-v1.1.gguf"
const WAIT_GPU := 1
const READ := 2
const UPLOAD := 3
const COOP := 4
const DONE := 5
const ERROR := 6
const UPLOAD_CHUNK := 32 << 20
const STEPS := 50
const SEED := 1171

var source := ""
var busy := false
var status := Callable()  # show_status(text) of the auto-rig's message card
var _motion: Node
var _rig: Node
var _rd: RenderingDevice
var _files := {}
var _test_clip := ""
var _test_made := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--motion-quit="):
			_test_clip = a.trim_prefix("--motion-quit=")
	if _test_clip != "":
		get_parent().gltf_is_loaded.connect(_on_test_loaded)


# The clip set: [key, "loop"|"once", seconds, prompt] per line.
static func clips() -> Array:
	var out := []
	if not FileAccess.file_exists(CLIPS):
		return out
	for line in FileAccess.get_file_as_string(CLIPS).split("\n", false):
		var w := line.split("\t")
		if w.size() == 4:
			out.append([w[0], w[1], float(w[2]), w[3]])
	return out


func weights_dir() -> String:
	var base := OS.get_executable_path().get_base_dir()
	if OS.has_feature("editor"):
		base = ProjectSettings.globalize_path("res://")
	elif OS.get_name() == "macOS":
		# Inside a .app bundle the executable lives in Contents/MacOS, but the weights
		# (non-Mach-O .gguf files) ship in Contents/Resources instead: Apple's codesign
		# and notarization reject a non-Mach-O file sitting loose next to the executable
		# ("non Mach-O file with a nested rule"), so the packager places them one level
		# up, in Contents/Resources/w (see tools/package_desktop.exs, place_binary("Mac", ...)).
		base = base.path_join("../Resources")
	return base.path_join("w")


# The Kimodo weights are in this viewer's w folder (the SkinTokens viewer ships without them).
func available() -> bool:
	return FileAccess.file_exists(weights_dir().path_join(KIMODO))


func say(text: String) -> void:
	if status.is_valid():
		status.call(text)
	if _test_clip != "" and text.begins_with("Motion failed"):
		printerr("MOTION-FAIL ", text)


func _on_test_loaded(ok: bool, _gltf: Node) -> void:
	if not ok:
		printerr("MOTION-FAIL the model did not open")
		get_tree().quit(1)
	elif _test_made:
		print("MOTION-OPENED ", source)
		get_tree().quit(0)
	else:
		await make(_test_clip)
		if not _test_made:
			get_tree().quit(1)


func make(key: String) -> void:
	if busy:
		return
	var clip := []
	for c in clips():
		if c[0] == key:
			clip = c
	if clip.is_empty():
		return say("Motion failed: no clip %s" % key)
	if source == "" or source.get_extension().to_lower() != "glb":
		return say("Motion needs an open .glb file with a rig.")
	if not FileAccess.file_exists(weights_dir().path_join(KIMODO)):
		return say("Motion needs %s in %s." % [KIMODO, weights_dir()])
	if not ClassDB.class_exists("Sandbox"):
		return say("Motion needs the godot-sandbox library beside the program.")
	busy = true
	var out := await run(clip)
	busy = false
	if out != "":
		_test_made = true
		made.emit(out, key)


func run(clip: Array) -> String:
	var t0 := Time.get_ticks_msec()
	var key: String = clip[0]
	var label := "Motion %s" % key
	say(label + ": starting...")
	if _rd == null:
		_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return _fail("this renderer gives no local RenderingDevice")
	# 1. Kimodo on motion.elf. A generate job also retargets to the avatar it knows, so it gets a
	# small T-pose humanoid; that output is not used (skintokens.elf moves the clip onto the rig).
	_motion = _sandbox(MOTION_ELF, "motion_generate")
	if _motion == null:
		return _fail("motion.elf did not load")
	var opened := str(_motion.vmcall("motion_open", _rd, 4096, weights_dir()))
	if not opened.begins_with("OPEN"):
		return _fail(opened)
	_motion.vmcall("motion_env", "KIMODO_STEPS=%d MOTION_GAS=0" % STEPS)
	var av := _avatar()
	_motion.vmcall("motion_avatar", av.names, av.parents, av.rest_global, av.rest_local, av.roles)
	var emb := FileAccess.get_file_as_bytes("res://motion/%s.f32" % key)
	if emb.size() != 4096 * 4:
		return _fail("no text input for %s" % key)
	_motion.vmcall("motion_prompt_embedding", clip[3], emb.to_float32_array())
	# 6 s for every clip: at 3 s a one-shot such as wave has no time to come back to its start pose.
	var made_s := 6.0
	var q := str(_motion.vmcall("motion_generate", "kimodo_soma", clip[3], made_s, SEED))
	if not q.begins_with("QUEUED"):
		return _fail(q)
	var id := int(q.split(" ")[1])
	if not await _drive(_motion, "motion_pump", label + ": Kimodo", t0):
		return ""
	var st := str(_motion.vmcall("motion_status", id))
	if not st.begins_with("DONE"):
		return _fail(st)
	var res: Dictionary = _motion.vmcall("motion_result", id)
	_free(_motion)
	_motion = null
	# 2. Cut, move onto the rig and add the clip, on skintokens.elf (no GPU).
	_rig = _sandbox(RIG_ELF, "skintokens_motion_start")
	if _rig == null:
		return _fail("skintokens.elf has no motion step")
	var started := str(
		_rig.vmcall(
			"skintokens_motion_start",
			source,
			key,
			"%s %s" % [clip[1], clip[2]],
			str(res.joint_names),
			res.parents,
			res.transforms,
			float(res.fps)
		)
	)
	if not started.begins_with("STARTED"):
		return _fail(started)
	if not await _drive(_rig, "skintokens_pump", label + ": fitting", t0):
		return ""
	var glb := PackedByteArray()
	var size := int(_rig.vmcall("skintokens_result_size"))
	while glb.size() < size:
		var chunk: PackedByteArray = _rig.vmcall(
			"skintokens_result_chunk", glb.size(), min(size - glb.size(), 8 << 20)
		)
		if chunk.is_empty():
			return _fail("the result did not read back")
		glb.append_array(chunk)
	print("MOTION-LOG ", str(_rig.vmcall("skintokens_output")).strip_edges())
	_free(_rig)
	_rig = null
	_close_files()
	# The clip goes into the open file when it is a rig result, else into <name>.rigged.glb.
	var out := source
	if not source.ends_with(".rigged.glb"):
		out = source.get_basename() + ".rigged.glb"
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		out = OS.get_user_data_dir().path_join(out.get_file())
		f = FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return _fail("cannot save the result")
	f.store_buffer(glb)
	f.close()
	print("MOTION-OK %s %s bytes=%d ms=%d" % [key, out, glb.size(), Time.get_ticks_msec() - t0])
	say("Motion %s saved in %s" % [key, out])
	return out


func _sandbox(elf: String, needs: String) -> Node:
	# wasm32 cannot reserve 2048 MiB (std::bad_alloc): 512 on the web.
	var sb: Node = Bintr.make(self, elf, 512 if OS.has_feature("web") else 2048, 65536)
	if not sb.has_function(needs):
		_free(sb)
		return null
	return sb


func _free(sb: Node) -> void:
	if sb:
		remove_child(sb)
		# Free the arena now, on every platform. A queued free waits for the end of the frame, and a
		# CPU-only job (the moves: 72 clips) never yields one, so every 2 GiB arena stayed alive at
		# once: 140 GB private memory on Windows, which commits each arena.
		sb.free()


# Runs the started job on `pump` to the end, answering its file reads and weight uploads.
func _drive(sb: Node, pump: String, label: String, t0: int) -> bool:
	var feed := PackedByteArray()
	while true:
		var r = sb.vmcall(pump, feed)
		feed = PackedByteArray()
		if typeof(r) != TYPE_ARRAY or r.size() < 3:
			_fail("the program stopped")
			return false
		var hdr: PackedInt64Array = r[0]
		match hdr[0]:
			DONE:
				return true
			ERROR:
				_fail(str(r[1]).strip_edges())
				return false
			WAIT_GPU, COOP:
				say("%s, %d s" % [label, (Time.get_ticks_msec() - t0) / 1000])
				await get_tree().process_frame
			READ:
				feed = _read(str(r[1]), hdr[1], hdr[2] if hdr[2] > 0 else 1 << 40)
			UPLOAD:
				var done := 0
				while done < hdr[2]:
					var n: int = min(hdr[2] - done, UPLOAD_CHUNK)
					var b := _read(str(r[1]), hdr[1] + done, n)
					if b.size() != n or _rd.buffer_update(r[2], hdr[3] + done, n, b) != OK:
						_fail("could not load the weights to the GPU")
						return false
					done += n
			_:
				_fail("unknown request %d" % hdr[0])
				return false
	return false


func _read(path: String, offset: int, n: int) -> PackedByteArray:
	if not _files.has(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			return PackedByteArray()
		_files[path] = f
	var file: FileAccess = _files[path]
	file.seek(offset)
	return file.get_buffer(min(n, file.get_length() - offset))


func _close_files() -> void:
	for f in _files.values():
		f.close()
	_files.clear()


func _fail(why: String) -> String:
	_free(_motion)
	_free(_rig)
	_motion = null
	_rig = null
	_close_files()
	say("Motion failed: " + why)
	return ""


# A small T-pose humanoid (motion-guest tests' avatar): motion.elf's generate job needs one.
static func _avatar() -> Dictionary:
	var bones := [
		["Hips", -1, Vector3(0, 1.0, 0), "Hips"],
		["Spine", 0, Vector3(0, 1.1, 0), "Spine"],
		["Chest", 1, Vector3(0, 1.3, 0), "Chest"],
		["Neck", 2, Vector3(0, 1.5, 0), "Neck"],
		["Head", 3, Vector3(0, 1.62, 0), "Head"],
		["L_Arm", 2, Vector3(0.18, 1.45, 0), "LeftUpperArm"],
		["L_Elbow", 5, Vector3(0.46, 1.45, 0), "LeftLowerArm"],
		["L_Hand", 6, Vector3(0.72, 1.45, 0), "LeftHand"],
		["R_Arm", 2, Vector3(-0.18, 1.45, 0), "RightUpperArm"],
		["R_Elbow", 8, Vector3(-0.46, 1.45, 0), "RightLowerArm"],
		["R_Hand", 9, Vector3(-0.72, 1.45, 0), "RightHand"],
		["L_Leg", 0, Vector3(0.1, 0.95, 0), "LeftUpperLeg"],
		["L_Knee", 11, Vector3(0.1, 0.52, 0), "LeftLowerLeg"],
		["L_Foot", 12, Vector3(0.1, 0.08, 0), "LeftFoot"],
		["L_Toes", 13, Vector3(0.1, 0.02, 0.13), "LeftToes"],
		["R_Leg", 0, Vector3(-0.1, 0.95, 0), "RightUpperLeg"],
		["R_Knee", 15, Vector3(-0.1, 0.52, 0), "RightLowerLeg"],
		["R_Foot", 16, Vector3(-0.1, 0.08, 0), "RightFoot"],
		["R_Toes", 17, Vector3(-0.1, 0.02, 0.13), "RightToes"],
	]
	var names := ""
	var roles := ""
	var parents := PackedInt32Array()
	var rg := PackedFloat32Array()
	var rl := PackedFloat32Array()
	for b in bones:
		names += b[0] + "\n"
		roles += b[3] + "\n"
		parents.append(b[1])
		var t: Vector3 = b[2] - (bones[b[1]][2] if b[1] >= 0 else Vector3.ZERO)
		rg.append_array([1, 0, 0, 0, 1, 0, 0, 0, 1, b[2].x, b[2].y, b[2].z])
		rl.append_array([1, 0, 0, 0, 1, 0, 0, 0, 1, t.x, t.y, t.z])
	return {names = names, roles = roles, parents = parents, rest_global = rg, rest_local = rl}
