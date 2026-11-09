extends Node
# Builds Model Explorer from its generated scene procedure (the main scene is an empty Node), then
# makes the first visit friendly: a light studio background instead of the procedural sky (which
# some browsers cannot draw: they show black), a sample model already loaded, and a one-line hint.
const ModelExplorerScene = preload("res://vsk_model_explorer/scene/ModelExplorer_scene.gd")
const KhrTransmission = preload("res://gltf/khr_materials_transmission.gd")
const SAMPLE := "res://sample/mire.glb"
const PAPER := Color(0.93, 0.93, 0.92)

var hint: Label
var cam_rig: Node3D
var chart_cam: Camera3D
var key_light: DirectionalLight3D


func _ready() -> void:
	# glTF files that require KHR_materials_transmission (glass) were refused by the importer.
	GLTFDocument.register_gltf_document_extension(KhrTransmission.new())
	RenderingServer.set_default_clear_color(PAPER)
	# Wireframe view needs wireframe index buffers, which Godot only builds for meshes created after
	# this is on (the editor turns it on; an exported game does not), so the W tool drew nothing.
	RenderingServer.set_debug_generate_wireframes(true)
	var root: Node = ModelExplorerScene.new().instantiate()
	var we: WorldEnvironment = root.get_node("WorldEnvironment")
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = PAPER
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.44
	# Linear tonemap: an unshaded ColorChecker comes out byte-exact (Filmic lifted neutral 5 from
	# 122 to 155). Ambient 0.44 + key light 0.73 sum to 1, so a lit chart facing the camera reads
	# its reference values instead of 1.37x them (ambient 0.6 + key 1.0 made the overbright look).
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	we.environment = env
	we.camera_attributes = null
	var cam: Camera3D = root.get_node("CamController/CamRotHelper/Camera3D")
	cam.attributes = null
	key_light = cam.get_node("DirectionalLight3D")
	key_light.light_energy = 0.73
	root.add_child(_backdrop())
	chart_cam = cam
	# UIController's Grid export is never set in ModelExplorer.tscn, so Hide Grid did nothing.
	root.get_node("Node").set("Grid", root.get_node("GizmoPlane"))
	cam_rig = root.get_node("CamController/CamRotHelper")
	var msg: Control = root.get_node("Node/MessagePanel")
	msg.visible = false
	get_tree().root.add_child.call_deferred(root)
	# WebGPU has no line polygon mode, so Godot's wireframe view draws solid there. On the web the
	# Wireframe tool instead adds a line copy of every mesh (same vertices, skin and skeleton).
	if OS.has_feature("web"):
		root.get_node("Node").wireframe_toggled.connect(_web_wireframe)
	hint = Label.new()
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.13, 0.13, 0.13))
	hint.text = "Sample: Mire by Mohka Noir (Apache-2.0).   Drop your own .glb, .gltf or .vrm to view it."
	var layer := CanvasLayer.new()
	layer.layer = 10
	layer.add_child(hint)
	add_child(layer)
	# Bottom left, clear of the information panel (300 px) and of the controls card on the right.
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 20)
	hint.position.x = 320
	root.gltf_is_loaded.connect(_on_loaded)
	await get_tree().process_frame
	await get_tree().process_frame
	root.call("_load_file", SAMPLE)
	print("BOOT built ", root.name, " sample=", SAMPLE)


func _print_chart_points() -> void:
	var chart: Node3D = get_tree().root.find_child("ColorCharts", true, false)
	if chart:
		chart.print_points(chart_cam)


var loads := 0
var wire_on := false


func _web_wireframe(on: bool) -> void:
	wire_on = on
	for n in get_tree().get_nodes_in_group("vsk_web_wire"):
		n.queue_free()
	var model_nodes: Array = get_tree().get_nodes_in_group("gltf group")
	model_nodes.append_array(get_tree().get_nodes_in_group("fbx group"))
	for model in model_nodes:
		for m in model.find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.is_in_group("vsk_web_wire"):
				continue
			mi.visible = not on
			if on and mi.mesh:
				_add_wire_copy(mi)


func _edges_of(tri: PackedInt32Array) -> PackedInt32Array:
	var edges := PackedInt32Array()
	edges.resize(tri.size() * 2)
	var t := 0
	while t + 2 < tri.size():
		var a := tri[t]
		var b := tri[t + 1]
		var c := tri[t + 2]
		var e := t * 2
		edges[e] = a
		edges[e + 1] = b
		edges[e + 2] = b
		edges[e + 3] = c
		edges[e + 4] = c
		edges[e + 5] = a
		t += 3
	return edges


func _add_wire_copy(mi: MeshInstance3D) -> void:
	var lines := ArrayMesh.new()
	for s in mi.mesh.get_surface_count():
		if mi.mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var src: Array = mi.mesh.surface_get_arrays(s)
		var tri: PackedInt32Array = src[Mesh.ARRAY_INDEX]
		if tri.is_empty():
			var n: int = (src[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			tri.resize(n)
			for i in n:
				tri[i] = i
		# In slices: the compiled loop copies the arrays it indexes into guest memory, and the host
		# refuses a window over 4096 elements ("Array window: count out of range"); 1536 indices in
		# give 3072 out.
		var edges := PackedInt32Array()
		var start := 0
		while start < tri.size():
			edges.append_array(_edges_of(tri.slice(start, mini(start + 1536, tri.size()))))
			start += 1536
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = src[Mesh.ARRAY_VERTEX]
		arr[Mesh.ARRAY_BONES] = src[Mesh.ARRAY_BONES]
		arr[Mesh.ARRAY_WEIGHTS] = src[Mesh.ARRAY_WEIGHTS]
		arr[Mesh.ARRAY_INDEX] = edges
		var flags := 0
		if (
			src[Mesh.ARRAY_BONES] != null
			and (
				(src[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array).size()
				== (src[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() * 8
			)
		):
			flags = Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		lines.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr, [], {}, flags)
	if lines.get_surface_count() == 0:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.15, 0.17, 0.2)
	var w := MeshInstance3D.new()
	w.name = mi.name + "_wire"
	w.mesh = lines
	w.material_override = mat
	w.transform = mi.transform
	w.skin = mi.skin
	w.skeleton = mi.skeleton  # a sibling of mi, so mi's relative skeleton path holds
	w.add_to_group("vsk_web_wire")
	mi.get_parent().add_child.call_deferred(w)


# The light background as geometry: a screen-filling quad at the far plane. Firefox's WebGPU does
# not show the render pass clear colour (the background came out black), but it draws meshes.
func _backdrop() -> MeshInstance3D:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;
uniform vec4 paper : source_color;
void vertex() {
	// Godot uses reversed depth: 0 is the far plane; stay just in front of it.
	POSITION = vec4(VERTEX.xy, 0.000001, 1.0);
}
void fragment() {
	ALBEDO = paper.rgb;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("paper", PAPER)
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	var mi := MeshInstance3D.new()
	mi.name = "Backdrop"
	mi.mesh = quad
	mi.material_override = mat
	mi.extra_cull_margin = 16384.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _on_loaded(ok: bool, _scene) -> void:
	print("BOOT loaded ok=", ok)
	if not ok:
		hint.text = "That file could not be opened. Try a .glb, .gltf or .vrm."
		return
	loads += 1
	# The camera starts level with the floor grid, which then shows edge-on as nothing; look down a
	# little so the grid is visible. Deferred: CamController resets the pitch on the same signal.
	cam_rig.set_deferred("rotation", Vector3(deg_to_rad(-12.0), 0.0, 0.0))
	# The app places the colour chart; print its patch centres for screen tests.
	get_tree().create_timer(1.0).timeout.connect(_print_chart_points)
	if loads > 1:
		hint.text = "Drop another .glb, .gltf or .vrm to replace it."
	if loads == 1 and "--warmup" in OS.get_cmdline_args():
		_warmup()


# Shader warm-up, run only by the export pipeline (page arg --warmup). Every material shader is
# converted GLSL -> SPIR-V -> WGSL in the browser the first time it draws, which is most of a cold
# start. So the pipeline opens the page once per browser, draws one small sphere for each
# StandardMaterial3D shader key the glTF importer produces (textures are not part of the key), then
# dumps user://shader_cache to the console as SCF lines. A harvester writes those lines back to
# files. Shipping them in the pck is not done yet. Mods and dropped models hit the same keys.
func _warmup_materials() -> Array:
	var out := []
	for rough_g in [false, true]:
		for normal in [false, true]:
			for emission in [false, true]:
				for scissor in [false, true]:
					out.append(_std(rough_g, normal, false, emission, scissor, false))
	for normal in [false, true]:
		for scissor in [false, true]:
			out.append(_std(true, normal, true, false, scissor, false))
			out.append(_std(true, normal, false, false, scissor, true))
	for cull_off in [false, true]:
		for scissor in [false, true]:
			var u := StandardMaterial3D.new()
			u.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			u.transparency = (
				BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				if scissor
				else BaseMaterial3D.TRANSPARENCY_DISABLED
			)
			u.cull_mode = BaseMaterial3D.CULL_DISABLED if cull_off else BaseMaterial3D.CULL_BACK
			out.append(u)
	var vc := StandardMaterial3D.new()
	vc.vertex_color_use_as_albedo = true
	out.append(vc)
	return out


func _std(
	rough_g: bool, normal: bool, ao: bool, emission: bool, scissor: bool, cull_off: bool
) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	if rough_g:
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	m.normal_enabled = normal
	m.ao_enabled = ao
	if emission:
		m.emission_enabled = true
		m.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	if scissor:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	if cull_off:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _warmup() -> void:
	var mats := _warmup_materials()
	var sphere := SphereMesh.new()
	sphere.radius = 0.004
	sphere.height = 0.008
	for i in mats.size():
		var mi := MeshInstance3D.new()
		mi.mesh = sphere
		mi.material_override = mats[i]
		mi.position = Vector3(-0.1 + 0.012 * (i % 16), 0.03 - 0.012 * (i / 16), -0.5)
		chart_cam.add_child(mi)
	print("WARMUP materials=", mats.size())
	for i in 30:
		await get_tree().process_frame
	_dump_dir("user://shader_cache", "")
	print("WARMUP done")


func _dump_dir(path: String, rel: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		var hex: String = FileAccess.get_file_as_bytes(path.path_join(f)).hex_encode()
		var n := (hex.length() + 7999) / 8000
		for i in n:
			print("SCF ", rel.path_join(f), " ", i, " ", n, " ", hex.substr(i * 8000, 8000))
	for sub in d.get_directories():
		_dump_dir(path.path_join(sub), rel.path_join(sub))
