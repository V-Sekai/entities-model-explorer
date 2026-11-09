extends SceneTree
# Bake the walk-mode obstacle course: run the parametric SolidCraft script course.json in the
# SolidCraft CAD kernel (interactor-solidcraft-guest's solid_script, in godot-sandbox) and write
# every body it builds to glTF:
#
#   godot --headless --path <viewer project with godot-sandbox> --script tools/course/bake_course.gd \
#     -- <solidcraft-guest.elf> <course.json> <out .glb>
#
# The shapes are the script's: sketches fixed by constraints and parameter-driven dimensions,
# then extruded (tools/course/course_script.py writes it). This file only converts: SolidCraft is
# Z-up in mm with the course along +X; the viewer's course is Y-up in metres along -Z.
# Body colours come from the script's own appearance.assign commands.

const MM := 0.001

var sandbox
var course := Node3D.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		printerr("COURSE-FAIL usage: -- <solidcraft-guest.elf> <course.json> <out.glb>")
		quit(2)
		return
	if not ClassDB.class_exists("Sandbox"):
		printerr("COURSE-FAIL godot-sandbox did not load")
		quit(1)
		return
	sandbox = ClassDB.instantiate("Sandbox")
	sandbox.set_memory_max(1024)
	# One script builds many solids: far more small heap blocks than the default allows.
	sandbox.set_allocations_max(1 << 22)
	# ... and far more instructions than one solid (millions; the default is 8000).
	sandbox.set_instructions_max(400000)
	# Each body comes back as five Variants (name and four arrays): lift the 100-Variant cap.
	sandbox.set_max_refs(4096)
	sandbox.load_buffer(FileAccess.get_file_as_bytes(args[0]))
	if not sandbox.has_function("solid_script"):
		printerr("COURSE-FAIL this solidcraft-guest.elf has no solid_script")
		quit(1)
		return
	var text := FileAccess.get_file_as_string(args[1])
	var colours := _colours(JSON.parse_string(text))
	var t0 := Time.get_ticks_msec()
	var r = sandbox.vmcall("solid_script", text)
	if typeof(r) != TYPE_ARRAY or r.size() != 3 or not r[0]:
		printerr(
			"COURSE-FAIL solid_script: ", r[1] if typeof(r) == TYPE_ARRAY and r.size() > 1 else r
		)
		quit(1)
		return
	var tris := 0
	var names := []
	for b in r[2]:
		tris += _add_body(b, colours)
		names.append(b[0])
	course.name = "ObstacleCourse"
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_scene(course, state) != OK or doc.write_to_filesystem(state, args[2]) != OK:
		printerr("COURSE-FAIL could not write ", args[2])
		quit(1)
		return
	print(
		(
			"COURSE-OK bodies=%d triangles=%d ms=%d out=%s"
			% [names.size(), tris, Time.get_ticks_msec() - t0, args[2].get_file()]
		)
	)
	print("COURSE-BODIES ", ", ".join(names))
	quit(0)


# Body name -> colour, from the script's appearance.assign commands ("Stones" also colours the
# "Stones (2)" ... bodies that one sketch's several profiles became).
func _colours(script) -> Dictionary:
	var out := {}
	if script is Dictionary:
		for c in script.get("commands", []):
			if c.get("command") == "appearance.assign" and c.params.has("color"):
				for b in c.params.get("bodies", []):
					out[b] = Color.html(str(c.params.color))
	return out


func _add_body(b: Array, colours: Dictionary) -> int:
	var body: String = b[0]
	var pos: Array = b[2]
	var nrm: Array = b[3]
	var n := pos.size() / 3
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	verts.resize(n)
	normals.resize(n)
	# SolidCraft (x along the course, y across, z up) -> viewer (-z along, -x across, y up);
	# a rotation, so faces keep their outside.
	for i in n:
		verts[i] = Vector3(-pos[i * 3 + 1], pos[i * 3 + 2], -pos[i * 3]) * MM
		if nrm.size() == pos.size():
			normals[i] = Vector3(-nrm[i * 3 + 1], nrm[i * 3 + 2], -nrm[i * 3])
	# The kernel winds front faces counter-clockwise (glTF); Godot takes clockwise as the front.
	var idx := PackedInt32Array(b[4])
	for t in range(0, idx.size() - 2, 3):
		var keep := idx[t + 1]
		idx[t + 1] = idx[t + 2]
		idx[t + 2] = keep
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colours.get(body, colours.get(body.get_slice(" (", 0), Color(0.8, 0.8, 0.8)))
	mat.roughness = 0.8
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = body.replace(" ", "").replace("(", "_").replace(")", "")
	mi.mesh = mesh
	course.add_child(mi)
	mi.owner = course
	return int(b[1])
