class_name GridBalls
extends MultiMeshInstance3D
# The floor grid as grid balls, from V-Sekai xr-grid (addons/procedural_3d_grid, MIT, commit
# ff71e92): a dot with three short axis ticks at every metre of a lattice, faded out a few metres
# from the focus (the camera's pivot, or the walking model). Replaces the old line-grid plane.

const SHADER := preload("res://vsk_model_explorer/shader/GridBalls.gdshader")
const SPACING := 1.0
const FAR_FADE := 4.0
const FADE_ZONE := 2.0
const N_CIRCLE := 32

var focus_path := NodePath("../CamController")
var _focus_override := Vector3.ZERO
var _focus_frame := -1
var _mat := ShaderMaterial.new()


func _ready() -> void:
	_mat.shader = SHADER
	_mat.set_shader_parameter("_Color", Color(1, 1, 1, 0.85))
	_mat.set_shader_parameter("_PointRadius", 0.025)
	_mat.set_shader_parameter("_FarFade", FAR_FADE)
	_mat.set_shader_parameter("_FadeZone", FADE_ZONE)
	_mat.set_shader_parameter("_NearFade", 0.3)
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scale = Vector3.ONE * SPACING
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _ball_mesh()
	var n := int((FAR_FADE + FADE_ZONE) * 2.0 / SPACING)
	multimesh.instance_count = n * n * n
	for i in multimesh.instance_count:
		var o := Vector3(i % n, i / n % n, i / (n * n)) - Vector3.ONE * (n / 2 - 1)
		multimesh.set_instance_transform(i, Transform3D(Basis(), o))
	# The lattice is placed in the shader each frame, so the node's own bounds mean nothing.
	custom_aabb = AABB(Vector3.ONE * -1e5, Vector3.ONE * 2e5)


func _process(_delta: float) -> void:
	var f := _focus_override
	if _focus_frame < Engine.get_process_frames() - 1:
		var n := get_node_or_null(focus_path) as Node3D
		f = n.global_position if n else global_position
	_mat.set_shader_parameter("_FocusPoint", f)
	_mat.set_shader_parameter("_GridCenter", global_position)


# Fade around p this frame (the walk calls it every frame for the model's root).
func set_focus(p: Vector3) -> void:
	_focus_override = p
	_focus_frame = Engine.get_process_frames()


# A lattice point at o.
func set_center(o: Vector3) -> void:
	global_position = o


# xr-grid's mesh: a unit circle fan (the ball, UV.x 0) and three unit ticks along X, Y and Z
# (UV.x 1), which the shader billboards toward the camera.
func _ball_mesh() -> ArrayMesh:
	var m := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var v := PackedVector3Array()
	var p := Vector3(1, 0, 0)
	for i in range(1, N_CIRCLE + 1):
		var q := Vector3(cos(i * TAU / N_CIRCLE), sin(i * TAU / N_CIRCLE), 0)
		v.append_array([p, Vector3.ZERO, q])
		p = q
	arrays[Mesh.ARRAY_VERTEX] = v
	var zn := PackedVector3Array()
	zn.resize(v.size())
	arrays[Mesh.ARRAY_NORMAL] = zn
	var zu := PackedVector2Array()
	zu.resize(v.size())
	arrays[Mesh.ARRAY_TEX_UV] = zu
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	for axis in [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]:
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(
			[Vector3(0, -0.5, 0), Vector3(0, 0.5, 0), Vector3(1, -0.5, 0), Vector3(1, 0.5, 0)]
		)
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([axis, axis, axis, axis])
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(
			[Vector2(1, 0), Vector2(1, 0), Vector2(1, 0), Vector2(1, 0)]
		)
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, arrays)
	return m
