extends Node
# F plays a 20-minute flex motion on the open model: the joints (every one except the roots) take
# turns, one at a time. Each swings once about its own random axis, up to 60 degrees each way, in
# an equal share of the 20 minutes, and is back at rest before the next begins. It is the motion of
# skin-tokens-ggml's skin check (tools/skin_stress.cpp), made one joint at a time so a torn or
# stretched patch of skin can be traced to the joint that moved. The motion is computed for each
# frame from the time; nothing is saved and no clip is added to the file. F again stops it and puts
# the pose it started from back. The viewer's own animations pause while it plays.
# It starts from a standing idle: when the model has an animation named like "idle", that
# animation's first frame is the pose every joint swings out of and returns to. A model with no
# idle animation starts from its rest pose.
#
# Test mode: `-- <file.glb> --flex-quit` starts the motion once the file is open, checks that the
# joints moved, jumps to the end, checks that the rest pose came back, then quits.
const CardStyle = preload("res://vsk_model_explorer/core/CardStyle.gd")
const LENGTH := 1200.0
const DEGREES := 60.0
const SEED := 1

var time := 0.0
var playing := false
# [skeleton, bone, rest rotation, axis, hz, phase]
var _joints: Array = []
var _scene: Node
var _paused: Array = []
var _label: Label
var idle_used := ""   # the animation the swing started from, or "" for the rest pose
var _slot := 1.0   # seconds each joint has
var _last := -1    # the joint moved last frame
var _test := false


func _ready() -> void:
	_test = "--flex-quit" in OS.get_cmdline_user_args()
	get_parent().gltf_is_loaded.connect(_on_loaded)
	var layer := CanvasLayer.new()
	layer.layer = 11
	add_child(layer)
	var panel := PanelContainer.new()
	panel.theme = CardStyle.make_theme()
	panel.add_theme_stylebox_override("panel", CardStyle.card_box())
	# Top middle: the information panel is on the left and the auto-rig status top left.
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.offset_top = 16
	_label = Label.new()
	panel.add_child(_label)
	layer.add_child(panel)
	panel.visible = false


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.keycode == KEY_F:
		if playing:
			stop()
		else:
			start()


func _on_loaded(ok: bool, scene: Node) -> void:
	stop()
	_scene = scene if ok else null
	if _test:
		_run_test.call_deferred()


# Pick each joint's axis, rate and phase. The same file gives the same motion every time.
func _collect() -> void:
	_joints.clear()
	if _scene == null or not is_instance_valid(_scene):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for node in _scene.find_children("*", "Skeleton3D", true, false):
		var sk := node as Skeleton3D
		for b in sk.get_bone_count():
			if sk.get_bone_parent(b) < 0:
				continue
			var axis := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
			if axis.length() < 1.0e-6:
				axis = Vector3.UP
			var hz := 0.15 + 0.75 * rng.randf()
			var phase := TAU * rng.randf()
			_joints.append(
				[
					sk,
					b,
					sk.get_bone_rest(b).basis.get_rotation_quaternion(),
					axis.normalized(),
					hz,
					phase
				]
			)


func start() -> bool:
	_collect()
	if _joints.is_empty():
		_show("Flex: open a model with a skeleton first")
		return false
	_paused.clear()
	for node in _scene.find_children("*", "AnimationPlayer", true, false):
		var ap := node as AnimationPlayer
		if ap.is_playing():
			ap.pause()
			_paused.append(ap)
	idle_used = _use_idle()
	_slot = LENGTH / _joints.size()
	_last = -1
	time = 0.0
	playing = true
	_apply()
	return true


# Put the model in its idle animation's first frame and take that as every joint's starting pose.
func _use_idle() -> String:
	for node in _scene.find_children("*", "AnimationPlayer", true, false):
		var ap := node as AnimationPlayer
		for name in ap.get_animation_list():
			if String(name).to_lower().contains("idle"):
				ap.play(name)
				ap.seek(0.0, true)
				ap.pause()
				for j in _joints:
					j[2] = j[0].get_bone_pose_rotation(j[1])
				return String(name)
	return ""


func stop() -> void:
	if not playing:
		return
	playing = false
	for j in _joints:
		var sk: Skeleton3D = j[0]
		if is_instance_valid(sk):
			sk.set_bone_pose_rotation(j[1], j[2])
	for ap in _paused:
		if is_instance_valid(ap):
			ap.play()
	_paused.clear()
	_show("")


func _process(delta: float) -> void:
	if not playing:
		return
	time += delta
	if time >= LENGTH:
		stop()
		return
	_apply()


func _apply() -> void:
	var i := mini(int(time / _slot), _joints.size() - 1)
	if _last >= 0 and _last != i:
		var old: Array = _joints[_last]
		if is_instance_valid(old[0]):
			old[0].set_bone_pose_rotation(old[1], old[2])   # the joint that had its turn goes back to rest
	var j: Array = _joints[i]
	var sk: Skeleton3D = j[0]
	if is_instance_valid(sk):
		var u := time / _slot - i   # 0 to 1 across this joint's turn
		sk.set_bone_pose_rotation(j[1], j[2] * Quaternion(j[3], deg_to_rad(DEGREES) * sin(TAU * u)))
	_last = i
	var t := int(time)
	var left := int(LENGTH)
	_show("Flex %02d:%02d / %02d:00  (F stops)" % [t / 60, t % 60, left / 60])


func _show(text: String) -> void:
	_label.text = text
	_label.get_parent().visible = text != ""


func _largest_turn() -> float:
	var most := 0.0
	for j in _joints:
		var sk: Skeleton3D = j[0]
		var q: Quaternion = j[2]
		most = max(most, rad_to_deg(q.angle_to(sk.get_bone_pose_rotation(j[1]))))
	return most


# How many joints are away from their rest rotation: one while it plays.
func _joints_away() -> int:
	var n := 0
	for j in _joints:
		var q: Quaternion = j[2]
		if rad_to_deg(q.angle_to(j[0].get_bone_pose_rotation(j[1]))) > 0.001:
			n += 1
	return n


func _run_test() -> void:
	if _scene == null:
		printerr("FLEX-FAIL the model did not open")
		get_tree().quit(1)
		return
	if not start():
		print("FLEX-NONE no skeleton")
		get_tree().quit(2)
		return
	for i in 30:
		await get_tree().process_frame
	time = 7.0
	_apply()
	var moved := _largest_turn()
	var away := _joints_away()
	var shown := _label.text
	time = LENGTH - 0.001
	await get_tree().process_frame
	await get_tree().process_frame
	var back := _largest_turn()
	print(
		(
			"FLEX-RESULT joints=%d length=%d joints_away=%d moved_deg=%.2f after_end_deg=%.4f playing=%s label=%s"
			% [_joints.size(), int(LENGTH), away, moved, back, playing, shown]
		)
	)
	var ok := away == 1 and moved > 1.0 and moved <= DEGREES + 0.01 and back < 0.001 and not playing
	print("FLEX-OK" if ok else "FLEX-FAIL")
	get_tree().quit(0 if ok else 1)
