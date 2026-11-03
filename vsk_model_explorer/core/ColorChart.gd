extends Node3D
const ViewerSettings = preload("res://vsk_model_explorer/core/ViewerSettings.gd")
# A ColorChecker board standing on the floor to the right (+X) of the model, like a real chart
# propped up beside a subject in a photo. Two charts on one board: the top one is lit like the
# model (it shows what the lights and ambient do), the bottom one is unshaded (it shows only the
# output transform: tonemapper, sRGB encode, canvas).
# Hidden at start; C shows or hides it. The board is axis aligned: upright, its face toward +Z
# (the camera's start side), never turned toward the camera or the light.
# Patch centres are printed as "CHART <lit|flat> <index> <x> <y>" (print_points) so a test can read
# the screen at those pixels.

# X-Rite ColorChecker Classic, sRGB 8-bit (D65), row by row from dark skin to black.
const CHECKER := [
	[115, 82, 68],
	[194, 150, 130],
	[98, 122, 157],
	[87, 108, 67],
	[133, 128, 177],
	[103, 189, 170],
	[214, 126, 44],
	[80, 91, 166],
	[193, 90, 99],
	[94, 60, 108],
	[157, 188, 64],
	[224, 163, 46],
	[56, 61, 150],
	[70, 148, 73],
	[175, 54, 60],
	[231, 199, 31],
	[187, 86, 149],
	[8, 133, 161],
	[243, 243, 242],
	[200, 200, 200],
	[160, 160, 160],
	[122, 122, 121],
	[85, 85, 85],
	[52, 52, 52],
]
const CHART_W := 0.16
const CHART_H := 0.107
# Board depth; its back face sits behind the patches so they never z-fight.
const BOARD_D := CHART_W * 0.04


func _init() -> void:
	name = "ColorCharts"
	visible = ViewerSettings.get_bool("color_chart", false)   # hidden at start unless it was left showing
	var img := Image.create(6 * 16, 4 * 16, false, Image.FORMAT_RGB8)
	for i in CHECKER.size():
		var c: Array = CHECKER[i]
		img.fill_rect(Rect2i((i % 6) * 16 + 1, (i / 6) * 16 + 1, 14, 14), Color8(c[0], c[1], c[2]))
	var tex := ImageTexture.create_from_image(img)
	var board := MeshInstance3D.new()
	board.name = "board"
	var bm := BoxMesh.new()
	bm.size = Vector3(CHART_W * 1.12, CHART_H * 2.24, BOARD_D)
	board.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.1, 0.1, 0.1)
	bmat.roughness = 1.0
	board.material_override = bmat
	board.position = Vector3(0, 0, -BOARD_D * 0.525)
	add_child(board)
	for lit in [true, false]:
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = tex
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mat.roughness = 1.0
		mat.metallic_specular = 0.0
		if not lit:
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var quad := QuadMesh.new()
		quad.size = Vector2(CHART_W, CHART_H)
		var mi := MeshInstance3D.new()
		mi.name = "lit" if lit else "flat"
		mi.mesh = quad
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Stacked: lit on top, unshaded below.
		mi.position = Vector3(0.0, CHART_H * 0.56 if lit else -CHART_H * 0.56, 0.0)
		add_child(mi)


# Size the board to half the model's height and stand it on the model's floor, clear of its +X side.
# Rotation stays identity (only a uniform scale), so the board is square to the world axes.
func place(model_box: AABB) -> void:
	var h := maxf(model_box.size.y, 0.001)
	var k := 0.5 * h / (2.24 * CHART_H)
	var at := Vector3(
		model_box.end.x + 0.08 * h + 0.56 * CHART_W * k,
		model_box.position.y + 1.12 * CHART_H * k,
		model_box.get_center().z
	)
	transform = Transform3D(Basis.from_scale(Vector3(k, k, k)), at)


# The merged world box of every visible mesh under the given model roots.
static func model_box_of(models: Array) -> AABB:
	var box := AABB()
	var first := true
	for model in models:
		for m in (model as Node).find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.mesh == null or mi.is_in_group("vsk_web_wire"):
				continue
			var b := mi.global_transform * mi.get_aabb()
			box = b if first else box.merge(b)
			first = false
	return box if not first else AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 1, 1))


func print_points(cam: Camera3D) -> void:
	for c in get_children():
		var m := c as MeshInstance3D
		if m.name == "board":
			continue
		for i in CHECKER.size():
			var local := Vector3(
				(float(i % 6) + 0.5) / 6.0 * CHART_W - CHART_W * 0.5,
				CHART_H * 0.5 - (float(i / 6) + 0.5) / 4.0 * CHART_H,
				0.0
			)
			var sp := cam.unproject_position(m.global_transform * local)
			print("CHART %s %d %d %d" % [m.name, i, int(sp.x), int(sp.y)])


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.keycode == KEY_C:
		visible = not visible
		ViewerSettings.set_bool("color_chart", visible)
