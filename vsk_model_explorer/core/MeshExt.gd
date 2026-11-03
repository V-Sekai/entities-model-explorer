extends Node

var _outline_material: ShaderMaterial


func _ready():
	_outline_material = ShaderMaterial.new()
	_outline_material.shader = preload("res://vsk_model_explorer/shader/Outline.gdshader")


# Created and optimized by https://github.com/fire
# Huge thank!
# Modified to extract UVs directly from surface arrays to avoid MeshDataTool crashes
func draw_uv_texture(mesh: Mesh) -> PackedVector2Array:
	var uvLines: PackedVector2Array = []

	if mesh == null:
		return uvLines

	# Only works with ArrayMesh
	if not (mesh is ArrayMesh):
		return uvLines

	var array_mesh = mesh as ArrayMesh

	for si in array_mesh.get_surface_count():
		var surface_arrays = array_mesh.surface_get_arrays(si)

		# Check for required arrays
		if surface_arrays.size() <= ArrayMesh.ARRAY_VERTEX:
			continue
		var vertex_array = surface_arrays[ArrayMesh.ARRAY_VERTEX]
		if vertex_array == null or not (vertex_array is PackedVector3Array):
			continue

		# Check if surface has UV data
		if surface_arrays.size() <= ArrayMesh.ARRAY_TEX_UV:
			continue
		var uv_array = surface_arrays[ArrayMesh.ARRAY_TEX_UV]
		if uv_array == null or not (uv_array is PackedVector2Array):
			continue

		# Check if surface has index array (indexed geometry)
		var has_index = (
			surface_arrays.size() > ArrayMesh.ARRAY_INDEX
			and surface_arrays[ArrayMesh.ARRAY_INDEX] != null
		)
		var index_array: PackedInt32Array = PackedInt32Array()
		if has_index and surface_arrays[ArrayMesh.ARRAY_INDEX] is PackedInt32Array:
			index_array = surface_arrays[ArrayMesh.ARRAY_INDEX]

		# Extract UV coordinates from triangle edges
		if has_index and index_array.size() > 0:
			# Indexed geometry - process triangles from index array
			var triangle_count = index_array.size() / 3
			for tri in range(triangle_count):
				var i0 = index_array[tri * 3]
				var i1 = index_array[tri * 3 + 1]
				var i2 = index_array[tri * 3 + 2]

				# Add edges: (0,1), (1,2), (2,0)
				if i0 < uv_array.size() and i1 < uv_array.size():
					uvLines.push_back(uv_array[i0])
					uvLines.push_back(uv_array[i1])
				if i1 < uv_array.size() and i2 < uv_array.size():
					uvLines.push_back(uv_array[i1])
					uvLines.push_back(uv_array[i2])
				if i2 < uv_array.size() and i0 < uv_array.size():
					uvLines.push_back(uv_array[i2])
					uvLines.push_back(uv_array[i0])
		else:
			# Non-indexed geometry - process sequential triangles
			var triangle_count = vertex_array.size() / 3
			for tri in range(triangle_count):
				var i0 = tri * 3
				var i1 = tri * 3 + 1
				var i2 = tri * 3 + 2

				# Add edges: (0,1), (1,2), (2,0)
				if i0 < uv_array.size() and i1 < uv_array.size():
					uvLines.push_back(uv_array[i0])
					uvLines.push_back(uv_array[i1])
				if i1 < uv_array.size() and i2 < uv_array.size():
					uvLines.push_back(uv_array[i1])
					uvLines.push_back(uv_array[i2])
				if i2 < uv_array.size() and i0 < uv_array.size():
					uvLines.push_back(uv_array[i2])
					uvLines.push_back(uv_array[i0])

	return uvLines


# What the UV viewer draws for a mesh: its UV lines, and the base colour image of its material (null when
# it has none), which the lines are drawn over. Lines are empty when the mesh has no UVs.
func uv_view(mi: MeshInstance3D) -> Dictionary:
	var out := {"lines": draw_uv_texture(mi.mesh), "tex": null}
	if mi.mesh == null:
		return out
	for i in mi.mesh.get_surface_count():
		var tex := _base_texture(mi.get_active_material(i))
		if tex != null:
			out["tex"] = tex
			break
	return out


func _base_texture(mat: Material) -> Texture2D:
	if mat is BaseMaterial3D:
		return (mat as BaseMaterial3D).albedo_texture
	if mat is ShaderMaterial:  # MToon and other shaders name their base image differently
		for param in [
			"_MainTex",
			"main_tex",
			"albedo_texture",
			"base_color_texture",
			"texture_albedo",
			"BaseColorTexture"
		]:
			var t = (mat as ShaderMaterial).get_shader_parameter(param)
			if t is Texture2D:
				return t
	return null


func face_count(mesh: Mesh) -> int:
	var current_face_count: int = 0

	if mesh == null:
		return current_face_count

	# Only works with ArrayMesh
	if not (mesh is ArrayMesh):
		return current_face_count

	var array_mesh = mesh as ArrayMesh

	for si in array_mesh.get_surface_count():
		var surface_arrays = array_mesh.surface_get_arrays(si)

		# Check for required arrays
		if surface_arrays.size() <= ArrayMesh.ARRAY_VERTEX:
			continue
		var vertex_array = surface_arrays[ArrayMesh.ARRAY_VERTEX]
		if vertex_array == null or not (vertex_array is PackedVector3Array):
			continue

		# Count triangles from index array or vertex array
		var has_index = (
			surface_arrays.size() > ArrayMesh.ARRAY_INDEX
			and surface_arrays[ArrayMesh.ARRAY_INDEX] != null
		)
		if has_index and surface_arrays[ArrayMesh.ARRAY_INDEX] is PackedInt32Array:
			var index_array = surface_arrays[ArrayMesh.ARRAY_INDEX] as PackedInt32Array
			# Index array should be divisible by 3 for triangles
			if index_array.size() % 3 == 0:
				current_face_count += index_array.size() / 3
		else:
			# Non-indexed geometry - count sequential triangles
			if vertex_array.size() % 3 == 0:
				current_face_count += vertex_array.size() / 3

	return current_face_count


const OUTLINE = "Outline"


func mesh_clear_all_outline():
	var nodes = get_tree().get_nodes_in_group(OUTLINE)
	for n in nodes:
		n.queue_free()


func mesh_create_outline(mesh: MeshInstance3D):
	if not mesh.has_node(OUTLINE):
		return
	var outline = mesh.get_node(OUTLINE)

	if outline == null:
		var outlineMesh: Mesh = mesh.mesh.create_outline(mesh.mesh.get_aabb().size.length() / 300.0)

		var instance = MeshInstance3D.new()
		instance.name = OUTLINE
		instance.mesh = outlineMesh
		instance.material_overlay = _outline_material
		# Bind skeleton
		if not mesh.skeleton.is_empty():
			instance.skeleton = "../%s" % mesh.skeleton.get_concatenated_names()

		instance.add_to_group(OUTLINE)

		mesh.add_child.call_deferred(instance)


func mesh_remove_outline(mesh: MeshInstance3D):
	if not mesh.has_node(OUTLINE):
		return
	var outline = mesh.get_node(OUTLINE)
	if outline != null:
		outline.queue_free()
