extends SceneTree
# Test driver for VrmExport.gd (not shipped).
# godot --headless --path . --script tools/vrm_check.gd -- <rigged.glb> <roles.json> <out.vrm>
# Exports, then reads the .vrm back with the VRM add-on and prints what a VRM player would get.
const VrmExport := preload("res://vsk_model_explorer/core/VrmExport.gd")
const EXTENSIONS := [
	preload("res://addons/vrm/1.0/VRMC_vrm.gd"),
	preload("res://addons/vrm/1.0/VRMC_node_constraint.gd"),
	preload("res://addons/vrm/1.0/VRMC_springBone.gd"),
	preload("res://addons/vrm/1.0/VRMC_materials_hdr_emissiveMultiplier.gd"),
	preload("res://addons/vrm/1.0/VRMC_materials_mtoon.gd"),
]


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var roles: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(a[1])).roles
	var ex := VrmExport.new()
	var why := ex.export_vrm(a[0], roles, a[2])
	print("VRM-EXPORT ", "OK" if why == "" else "FAIL " + why, " ", JSON.stringify(ex.report))
	if why != "":
		quit(1)
		return
	var exts := []
	for e in EXTENSIONS:
		exts.append(e.new())
		GLTFDocument.register_gltf_document_extension(exts[-1])
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(a[2], st) != OK:
		print("VRM-READBACK FAIL")
		quit(1)
		return
	var scene: Node = doc.generate_scene(st)
	var skel: Skeleton3D = scene.find_children("*", "Skeleton3D", true, false)[0]
	var g := func(n: String) -> Vector3:
		var i := skel.find_bone(n)
		return (
			VrmExport._to_root(skel, scene) * skel.get_bone_global_rest(i).origin
			if i >= 0
			else Vector3.INF
		)
	var mtoon := 0
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var m: Material = mi.get_surface_override_material(s)
			if m == null:
				m = mi.mesh.surface_get_material(s)
			if m is ShaderMaterial and m.shader.resource_path.get_file().begins_with("mtoon"):
				mtoon += 1
			else:
				print(
					"VRM-READBACK material ",
					m,
					" ",
					m.shader.resource_path if m is ShaderMaterial else ""
				)
	var arm := func(side: String) -> float:
		var d: Vector3 = g.call(side + "LowerArm") - g.call(side + "UpperArm")
		return rad_to_deg(atan2(-d.y, Vector2(d.x, d.z).length()))
	print(
		(
			"VRM-READBACK meta=%s skel_bones=%d mtoon_surfaces=%d left_x=%.3f right_x=%.3f toe_dz=%.3f head_y=%.3f hips_y=%.3f arm_drop_L=%.1f arm_drop_R=%.1f"
			% [
				scene.get("vrm_meta") != null,
				skel.get_bone_count(),
				mtoon,
				g.call("LeftUpperLeg").x,
				g.call("RightUpperLeg").x,
				(g.call("LeftToes") - g.call("LeftFoot")).z,
				g.call("Head").y,
				g.call("Hips").y,
				arm.call("Left"),
				arm.call("Right"),
			]
		)
	)
	scene.free()
	for e in exts:
		GLTFDocument.unregister_gltf_document_extension(e)
	quit(0)
