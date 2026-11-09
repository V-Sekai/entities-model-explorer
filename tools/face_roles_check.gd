extends SceneTree
# Test driver for FaceRoles.gd (not shipped). Windowed, never headless:
#   godot --path . --resolution 64x64 --script tools/face_roles_check.gd -- \
#       <model .vrm/.glb/.fbx> <mesh name> <reference> <order|nearest> [control]
# The reference holds one line per vertex: `role` (order: the surfaces' vertices in turn) or
# `x y z role` (nearest: each mesh vertex takes the role of the closest reference vertex, mesh-local
# metres). Prints the agreement and per-role counts; exit 0 when agreement >= 0.99. `control`
# swaps the eye and lash roles before comparing, and must fail.
const FaceRoles := preload("res://vsk_model_explorer/core/FaceRoles.gd")

var _done := false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	quit(check())
	return false


func check() -> int:
	var a := OS.get_cmdline_user_args()
	var path: String = a[0]
	var root: Node
	if path.get_extension().to_lower() == "fbx":
		var doc := FBXDocument.new()
		var st := FBXState.new()
		if doc.append_from_file(path, st) != OK:
			print("FACE-ROLES FAIL cannot read ", path)
			return 2
		root = doc.generate_scene(st)
	else:
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_file(path, st) != OK:
			print("FACE-ROLES FAIL cannot read ", path)
			return 2
		root = doc.generate_scene(st)
	var mesh: Mesh = null
	for n in root.find_children("*", "MeshInstance3D", true, false):
		if str(n.name) == a[1] or (n as MeshInstance3D).mesh.resource_name == a[1]:
			mesh = (n as MeshInstance3D).mesh
	if mesh == null:
		for n in root.find_children("*", "MeshInstance3D", true, false):
			print(
				"mesh ",
				n.name,
				" ",
				(n as MeshInstance3D).mesh.resource_name,
				" surfaces ",
				(n as MeshInstance3D).mesh.get_surface_count()
			)
		print("FACE-ROLES FAIL no mesh ", a[1])
		return 2
	for s in mesh.get_surface_count():
		print(
			"surface ",
			s,
			" ",
			FaceRoles.surface_name(mesh, s),
			" -> ",
			FaceRoles.role_of(FaceRoles.surface_name(mesh, s))
		)
	var got := FaceRoles.roles(mesh)
	if a.size() > 4 and a[4] == "control":
		for i in got.size():
			if got[i] == FaceRoles.EYE:
				got[i] = FaceRoles.LASH
			elif got[i] == FaceRoles.LASH:
				got[i] = FaceRoles.EYE
	var lines := FileAccess.get_file_as_string(a[2]).split("\n", false)
	var want := PackedInt32Array()
	if a[3] == "order":
		for l in lines:
			want.append(int(l))
	else:
		var rp := PackedVector3Array()
		var rr := PackedInt32Array()
		for l in lines:
			var f := l.split(" ", false)
			rp.append(Vector3(float(f[0]), float(f[1]), float(f[2])))
			rr.append(int(f[3]))
		var pts := PackedVector3Array()
		for s in mesh.get_surface_count():
			pts.append_array(mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX])
		# Vertices sharing a position (a seam between surfaces) are a tie: the role agreeing with the
		# mesh is taken when any tied reference vertex has it.
		var gr := FaceRoles.roles(mesh)
		for i in pts.size():
			var bd := INF
			for k in rp.size():
				bd = minf(bd, pts[i].distance_squared_to(rp[k]))
			var pick := -1
			for k in rp.size():
				if pts[i].distance_squared_to(rp[k]) <= bd + 1e-12:
					if pick < 0 or rr[k] == gr[i]:
						pick = rr[k]
			want.append(pick)
	if want.size() != got.size():
		print("FACE-ROLES FAIL ", got.size(), " vertices, reference ", want.size())
		return 1
	var same := 0
	var cg := [0, 0, 0, 0, 0]
	var cw := [0, 0, 0, 0, 0]
	for i in got.size():
		same += 1 if got[i] == want[i] else 0
		cg[got[i]] += 1
		cw[want[i]] += 1
	var agree := float(same) / float(got.size())
	print(
		(
			"FACE-ROLES %s agreement %.4f (%d of %d) roles skin/eye/lash/iris/brow got %s reference %s"
			% ["PASS" if agree >= 0.99 else "FAIL", agree, same, got.size(), str(cg), str(cw)]
		)
	)
	return 0 if agree >= 0.99 else 1
