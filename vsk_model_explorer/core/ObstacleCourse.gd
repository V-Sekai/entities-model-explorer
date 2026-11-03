class_name ObstacleCourse
extends Node3D
# The walk-mode obstacle course: a game-like run of stations (stairs, ramps, stepping stones,
# bumps, a beam and a tunnel to duck under, a jump gap, a finish ring). Its shapes are a
# parametric SolidCraft script (tools/course/course_script.py: constrained, dimensioned sketches
# extruded), built by the SolidCraft CAD kernel with tools/course/bake_course.gd. Laid out in
# metres for a 1.75 m person along -Z;
# placed at the walk's start, turned to face away from the camera and scaled to the model.
# O or --obstacle-course turns it on; the walk then follows the ground under the model.
# Collisions run in the MuJoCo guest (mujoco.elf, in the sandbox, stepped only by this viewer, so
# a run repeats exactly): colliders.json holds the course as the convex pieces MuJoCo collides,
# written from the same parameters as the shapes and checked against them by
# tools/course/collider_check.gd.

const SCENE := "res://vsk_model_explorer/course/obstacle_course.glb"
# COURSE_COLLIDERS=<path> reads another colliders file (a search over course parameters runs many courses at once).
var COLLIDERS: String = (
	OS.get_environment("COURSE_COLLIDERS")
	if OS.get_environment("COURSE_COLLIDERS") != ""
	else "res://vsk_model_explorer/course/colliders.json"
)
const MUJOCO_ELF := "res://mujoco.elf"
# A sign above each station, keyed by the start of its SolidCraft body names.
const SIGNS := {
	"StartPad": "Start: walk ahead",
	"Stairs_a": "Stairs: 10, 17 and 25 cm steps",
	"Ramp_a": "Ramps: 10, 20 and 30 degrees",
	"Stones": "Stepping stones",
	"Bumps": "Bumps",
	"Beam": "Duck under: crouch, then crawl",
	"PlatformNear": "Jump the gap",
	"FinishRing": "Finish",
}
# The highest ledge the walk steps onto (a 1.75 m person's 45 cm): anything higher stays a wall
# for the ground probe, so the model walks under a beam rather than onto it.
const STEP_UP := 0.45
# The body that walls stop, for a 1.75 m person: its radius, and its height standing,
# crouching and crawling (MotionMatch's STAND, CROUCH, CRAWL). A vertical cylinder from a step
# above the feet to that height (mjc_player_band), so steps, slopes and bumps stay walkable.
const BODY_RADIUS := 0.25
const BODY_HEIGHT := [1.75, 1.2, 0.6, 0.55]  # stand, crouch, crawl, prone (the belly crawl's head top, measured: 0.55 course metres; it must be above STEP_UP)
const RESOLVE_PASSES := 3

var _course: Node3D
var _scale := 1.0
var _sb: Node
var _prims := []  # colliders.json records, course frame
var _player := -1
var _band := -1  # the mode the guest's player body was built for


func _ready() -> void:
	visible = "--obstacle-course" in OS.get_cmdline_user_args()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and not k.shift_pressed and k.physical_keycode == KEY_O:
		set_on(not visible)
		get_viewport().set_input_as_handled()


func set_on(on: bool) -> void:
	visible = on
	if on and _course == null:
		_build()


# Put the course's start at `origin`, its -Z along `forward` (on the floor), sized by `scale`.
func place(origin: Vector3, forward: Vector3, scale_: float) -> void:
	_scale = scale_
	var f := Vector3(forward.x, 0, forward.z)
	f = f.normalized() if f.length() > 1e-4 else Vector3(0, 0, -1)
	var yaw := atan2(-f.x, -f.z)
	global_transform = Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_), origin)
	set_on(visible)
	_band = -1


# Move the body from `from` toward `to` on the floor plane, stopping at walls and sliding along
# them: steps of at most half the body's radius, each pushed out of every collider it overlaps.
func slide(from: Vector3, to: Vector3, mode: int, s: float) -> Vector3:
	var d := Vector3(to.x - from.x, 0, to.z - from.z)
	if not visible or not _ready_for(clampi(mode, 0, 3)) or d.length() < 1e-9:
		return to
	var n := maxi(1, ceili(d.length() / (BODY_RADIUS * s * 0.5)))
	var p := Vector2(from.x, from.z)
	for i in n:
		p += Vector2(d.x, d.z) / n
		p = _resolve(p, from.y)
	return Vector3(p.x, to.y, p.y)


# The floor height under p: the highest course top within STEP_UP of the current height, else
# the floor. Walls and roofs higher than a step are left out.
func ground(p: Vector3, floor_y: float) -> float:
	if not visible or not _ready_for(_band if _band >= 0 else 0):
		return floor_y
	var top := p.y + STEP_UP * _scale
	var r = _sb.vmcall(
		"mjc_ray",
		PackedFloat64Array([p.x, top, p.z]),
		PackedFloat64Array([0.0, -1.0, 0.0]),
		top - floor_y + 1.0,
		_player
	)
	if typeof(r) == TYPE_PACKED_FLOAT64_ARRAY and r.size() == 9 and r[0] == 1.0:
		return maxf(floor_y, r[3])
	return floor_y


# station_physics_stage's resolve: push the band out of every collider it overlaps, deepest
# contact per collider, in up to RESOLVE_PASSES passes.
func _resolve(p: Vector2, feet_y: float) -> Vector2:
	for i in RESOLVE_PASSES:
		_sb.vmcall("mjc_set_qpos", PackedFloat64Array([p.x, feet_y, p.y]))
		_sb.vmcall("mjc_forward")
		var c = _sb.vmcall("mjc_player_contacts")
		if typeof(c) != TYPE_PACKED_FLOAT64_ARRAY or c.size() == 0:
			break
		var deepest := {}
		for k in range(0, c.size(), 5):
			if c[k + 4] < -1e-12 and (not deepest.has(c[k]) or c[k + 4] < deepest[c[k]][2]):
				deepest[c[k]] = [c[k + 1], c[k + 3], c[k + 4]]
		if deepest.is_empty():
			break
		for g in deepest:
			var nrm := Vector2(deepest[g][0], deepest[g][1])
			if nrm.length() > 1e-6:
				p += nrm.normalized() * -deepest[g][2]
	return p


# The guest holds the course where it stands now, with the player body for `mode`; a new mode or
# a new place loads it again (the band is fixed per load).
func _ready_for(mode: int) -> bool:
	if _sb == null or _prims.is_empty():
		return false
	if mode == _band:
		return true
	var t := global_transform
	var turn := t.basis.orthonormalized().get_rotation_quaternion()
	var out := PackedFloat64Array()
	for c in _prims:
		var p: Array = c.prim
		var at := t * Vector3(p[1], p[2], p[3])
		var q := turn * Quaternion(p[8], p[9], p[10], p[7])
		out.append_array(
			PackedFloat64Array(
				[
					p[0],
					at.x,
					at.y,
					at.z,
					p[4] * _scale,
					p[5] * _scale,
					p[6] * _scale,
					q.w,
					q.x,
					q.y,
					q.z,
					0.0
				]
			)
		)
	var s := _scale
	_sb.vmcall("mjc_player_band", BODY_RADIUS * s, STEP_UP * s, float(BODY_HEIGHT[mode]) * s)
	var n = _sb.vmcall(
		"mjc_load_primitives",
		out,
		PackedFloat64Array([0.0, 0.01, 0.0, 0.01]),
		2,
		2,
		PackedFloat64Array([1.0, 1.0, 1e5, 1e5])
	)
	if typeof(n) != TYPE_INT or n < 0:
		push_error("mujoco.elf refused the course colliders")
		_prims = []
		return false
	_player = int(_sb.vmcall("mjc_nbody")) - 1
	_band = mode
	print("COURSE-COLLIDERS mujoco geoms=%d mode=%d" % [n, mode])
	return true


func _build() -> void:
	var packed := load(SCENE) as PackedScene
	if packed == null:
		push_error("obstacle course missing: " + SCENE)
		return
	_course = packed.instantiate() as Node3D
	add_child(_course)
	var j = JSON.parse_string(FileAccess.get_file_as_string(COLLIDERS))
	if j is Dictionary and ClassDB.class_exists("Sandbox") and FileAccess.file_exists(MUJOCO_ELF):
		_prims = j.get("colliders", [])
		_sb = preload("res://vsk_model_explorer/core/Bintr.gd").make(self, MUJOCO_ELF, 256, 4096)
	else:
		push_error(
			"obstacle course colliders need %s, %s and godot-sandbox" % [COLLIDERS, MUJOCO_ELF]
		)
	for m in _course.get_children():
		var mi := m as MeshInstance3D
		if mi == null or not SIGNS.has(str(mi.name)):
			continue
		var box := mi.get_aabb()
		var l := Label3D.new()
		l.text = SIGNS[str(mi.name)]
		l.position = Vector3(0, max(box.end.y, 1.0) + 0.8, box.end.z)
		# About 40 cm tall letters: readable from the far side of a station.
		l.pixel_size = 0.008
		l.font_size = 64
		l.outline_size = 16
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		add_child(l)
