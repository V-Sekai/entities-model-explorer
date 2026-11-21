# The wireframe tool. Each model mesh is hidden and a line copy of it (same vertices, skin and
# skeleton) is shown in its place. Godot's viewport wireframe mode redraws everything in the view,
# including the grid, which belongs to the editor class of helpers and must stay solid. WebGPU has no
# line polygon mode either, so the line copies work on every platform.
class_name WireView
extends RefCounted

const GROUP := "vsk_web_wire"


static func apply(tree: SceneTree, on: bool) -> void:
	for n in tree.get_nodes_in_group(GROUP):
		n.queue_free()
	var model_nodes: Array = tree.get_nodes_in_group("gltf group")
	model_nodes.append_array(tree.get_nodes_in_group("fbx group"))
	for model in model_nodes:
		for m in model.find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.is_in_group(GROUP):
				continue
			mi.visible = not on
			if on and mi.mesh:
				_add_wire_copy(mi)


static func _edges_of(tri: PackedInt32Array) -> PackedInt32Array:
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



static func _add_wire_copy(mi: MeshInstance3D) -> void:
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
	w.add_to_group(GROUP)
	mi.get_parent().add_child.call_deferred(w)
