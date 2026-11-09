extends SceneTree
# Test-only picture: source rigged GLB (runtime glTF, PBR) beside the editor-imported .vrm (MToon),
# under the viewer's sky and light, framed on both. Run windowed:
# godot --path . --resolution 1200x700 --script tools/vrm_shot.gd -- <rigged.glb> <res://x.vrm> <out.png>
const VIEWER_LIGHT := "Transform3D(0.85798, -0.214782, 0.466625, -0.00966859, 0.901478, 0.432717, -0.513591, -0.375774, 0.771374, 0, 0, 0)"


func _aabb(n: Node) -> AABB:
	var box := AABB()
	var first := true
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var b: AABB = mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var a := OS.get_cmdline_user_args()
	var world := Node3D.new()
	root.add_child(world)
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.639216, 0.294118, 0.611765)
	sky_mat.sky_horizon_color = Color(0.541176, 0.666667, 0.811765)
	sky_mat.ground_bottom_color = Color(0.243137, 0.45098, 0.705882)
	sky_mat.ground_horizon_color = Color(0.32549, 0.694118, 0.917647)
	env.sky = Sky.new()
	env.sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	doc.append_from_file(a[0], st)
	var src: Node3D = doc.generate_scene(st)
	var vrm: Node3D = load(a[1]).instantiate()
	world.add_child(src)
	world.add_child(vrm)
	await process_frame
	# Place side by side, unscaled; the camera frames the taller one.
	var h := 0.0
	var gap := 0.0
	for n in [src, vrm]:
		var bb := _aabb(n)
		h = maxf(h, bb.size.y)
		gap = maxf(gap, bb.size.x)
	var x := -0.55 * gap
	for n in [src, vrm]:
		var bb := _aabb(n)
		n.position = Vector3(x - bb.get_center().x, -bb.position.y - h / 2, -bb.get_center().z)
		x += 1.1 * gap
	await process_frame
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 1.5 * maxf(h, 1.2 * gap))
	cam.attributes = CameraAttributesPhysical.new()  # the viewer's camera, exposure fixed
	world.add_child(cam)
	var light := DirectionalLight3D.new()
	cam.add_child(light)
	light.transform = str_to_var(VIEWER_LIGHT)
	cam.current = true
	print("AABB src ", _aabb(src), " vrm ", _aabb(vrm), " cam ", cam.position)
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(a[2])
	print("SHOT ", a[2])
	quit(0)
