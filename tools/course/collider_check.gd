extends SceneTree
# Do the MuJoCo colliders match the SolidCraft course? Casts the same rays at both: the course's
# exact surface (a fine STL from solidcraft-cli, as a Godot triangle mesh) and colliders.json
# loaded in mujoco.elf (mjc_load_primitives, mjc_ray). Rays go down on a 5 cm grid over the whole
# course, and level along and across it at three heights, so tops, risers, slopes, walls, roofs
# and the ring are all measured. Prints COLLIDERS-OK or COLLIDERS-FAIL with the worst misses.
#
#   godot --headless --path <project with godot-sandbox> --script tools/course/collider_check.gd \
#     -- <mujoco.double.elf> <colliders.json> <course.stl> [--plant-box Stairs_b]
#
# --plant-box NAME swaps NAME's pieces for one box around them (a convex stand-in for a concave
# shape, the way a mesh collider becomes its hull), the control that must fail.

const TOL := 0.006
const STEP := 0.05

var sb
var space: PhysicsDirectSpaceState3D
var player := -1


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 3:
		printerr(
			"COLLIDERS-FAIL usage: -- <mujoco.elf> <colliders.json> <course.stl> [--plant-box NAME]"
		)
		quit(2)
		return
	var plant := ""
	var i := a.find("--plant-box")
	if i >= 0 and i + 1 < a.size():
		plant = a[i + 1]
	var cols: Array = JSON.parse_string(FileAccess.get_file_as_string(a[1])).colliders
	if plant != "":
		cols = _plant_box(cols, plant)
	sb = ClassDB.instantiate("Sandbox")
	sb.memory_max = 256
	sb.references_max = 4096
	sb.allocations_max = 1000000
	sb.execution_timeout = 0
	get_root().add_child(sb)
	sb.load_buffer(FileAccess.get_file_as_bytes(a[0]))
	var prims := PackedFloat64Array()
	for c in cols:
		prims.append_array(PackedFloat64Array(c.prim))
	var n = sb.vmcall(
		"mjc_load_primitives",
		prims,
		PackedFloat64Array([0.0, 0.01, 0.0, 0.01]),
		2,
		2,
		PackedFloat64Array([1.0, 1.0, 10000.0, 10000.0])
	)
	if typeof(n) != TYPE_INT or n < 0:
		printerr("COLLIDERS-FAIL mujoco.elf refused the colliders")
		quit(1)
		return
	player = int(sb.vmcall("mjc_nbody")) - 1
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var tri := ConcavePolygonShape3D.new()
	tri.backface_collision = true
	tri.set_faces(_stl_faces(a[2]))
	shape.shape = tri
	body.add_child(shape)
	get_root().add_child(body)
	await physics_frame
	await physics_frame
	space = get_root().get_world_3d().direct_space_state
	print(
		(
			"COLLIDERS loaded %d pieces as %d geoms; surface %d triangles%s"
			% [
				cols.size(),
				n,
				tri.get_faces().size() / 3,
				("; planted a box for " + plant) if plant else ""
			]
		)
	)
	var bad := []
	var rays := 0
	var worst := 0.0
	var lo_x := -5.0
	var hi_x := 5.0
	var far_z := -58.0
	# Down: top surfaces.
	var x := lo_x
	while x <= hi_x + 1e-9:
		var z := 1.0
		while z >= far_z:
			rays += 1
			worst = max(worst, _cmp(Vector3(x, 5.0, z), Vector3.DOWN, 10.0, bad))
			z -= STEP
		x += STEP
	# Level along -z and across -x, at three heights between the step tops.
	for y in [0.33, 0.95, 1.55]:
		x = lo_x
		while x <= hi_x + 1e-9:
			rays += 1
			worst = max(worst, _cmp(Vector3(x, y, 2.0), Vector3.FORWARD, 62.0, bad))
			x += STEP
		var z := 1.0
		while z >= far_z:
			rays += 2
			worst = max(worst, _cmp(Vector3(6.0, y, z), Vector3.LEFT, 12.0, bad))
			worst = max(worst, _cmp(Vector3(-6.0, y, z), Vector3.RIGHT, 12.0, bad))
			z -= STEP
	bad.sort_custom(func(p, q): return p[0] > q[0])
	for b in bad.slice(0, 6):
		print("COLLIDERS-MISS %.3f m at %s dir %s: surface %s, mujoco %s" % b)
	print(
		(
			"%s rays=%d misses=%d worst=%.4f m (tolerance %.3f m)"
			% ["COLLIDERS-OK" if bad.is_empty() else "COLLIDERS-FAIL", rays, bad.size(), worst, TOL]
		)
	)
	quit(0 if bad.is_empty() else 1)


# Distance along the ray to the first hit in each, or -1 for no hit; a miss past TOL is recorded.
func _cmp(o: Vector3, d: Vector3, len: float, bad: Array) -> float:
	var q := PhysicsRayQueryParameters3D.create(o, o + d * len)
	q.hit_back_faces = true
	var h := space.intersect_ray(q)
	var gd: float = (h.position - o).length() if h else -1.0
	var r = sb.vmcall(
		"mjc_ray",
		PackedFloat64Array([o.x, o.y, o.z]),
		PackedFloat64Array([d.x, d.y, d.z]),
		len,
		player
	)
	var md: float = r[1] if r[0] == 1.0 else -1.0
	var diff := absf(gd - md) if (gd >= 0.0) == (md >= 0.0) else len
	if diff > TOL:
		bad.append([diff, o, d, "%.3f" % gd, "%.3f" % md])
	return diff


func _plant_box(cols: Array, name: String) -> Array:
	var lo := Vector3.ONE * 1e9
	var hi := -lo
	var keep := []
	for c in cols:
		if c.name != name:
			keep.append(c)
			continue
		var p: Array = c.prim
		var e := Vector3(p[4], p[5], p[6])
		var ctr := Vector3(p[1], p[2], p[3])
		lo = lo.min(ctr - e)
		hi = hi.max(ctr + e)
	var m := (lo + hi) / 2.0
	var h := (hi - lo) / 2.0
	keep.append({"name": name, "prim": [2, m.x, m.y, m.z, h.x, h.y, h.z, 1, 0, 0, 0, 0]})
	return keep


# A binary STL in SolidCraft's frame (x along, y across, z up, mm) as viewer-frame faces.
func _stl_faces(path: String) -> PackedVector3Array:
	var b := FileAccess.get_file_as_bytes(path)
	var n := b.decode_u32(80)
	var out := PackedVector3Array()
	out.resize(n * 3)
	for t in n:
		var o := 84 + t * 50 + 12
		for k in 3:
			var x := b.decode_float(o + k * 12)
			var y := b.decode_float(o + k * 12 + 4)
			var z := b.decode_float(o + k * 12 + 8)
			out[t * 3 + k] = Vector3(-y, z, -x) * 0.001
	return out
