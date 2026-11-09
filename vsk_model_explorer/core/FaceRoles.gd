# A role per vertex of a face mesh, from its surface material names, for headfit's anime eye close
# (hf_mesh_set_roles: 0 skin, 1 eye, 2 lash, 3 iris, 4 brow). Vertices follow the surfaces in order,
# each surface's ARRAY_VERTEX in turn: the order headfit's mesh is built in.
#
# A name is matched lower-cased, first rule first: an "eyebrow" is a brow and an "EyeIris" an iris,
# not an eye. A name no rule knows is skin. When no surface is named lash or iris, headfit splits the
# eye surface into its connected parts itself (a brow above, small highlights), so a face with one
# "Eyes" material still closes.
class_name FaceRoles
extends RefCounted

const SKIN := 0
const EYE := 1
const LASH := 2
const IRIS := 3
const BROW := 4


static func rules() -> Array:
	return [
		[IRIS, ["iris", "pupil", "hitomi", "highlight", "hilight", "瞳", "ハイライト"]],
		[LASH, ["lash", "matsuge", "mastuge", "eyeline", "eye_line", "まつげ", "睫毛", "まつ毛"]],
		[BROW, ["brow", "mayu", "眉", "まゆ"]],
		[EYE, ["eye", "white", "目", "白目"]],
	]


static func role_of(name: String) -> int:
	var n := name.to_lower()
	for r in rules():
		for word: String in r[1]:
			if n.contains(word):
				return r[0]
	return SKIN


# The name a surface is known by: its material's resource name, else the mesh's surface name.
static func surface_name(mesh: Mesh, s: int) -> String:
	var mat := mesh.surface_get_material(s)
	if mat != null and mat.resource_name != "":
		return mat.resource_name
	if mesh is ArrayMesh:
		return (mesh as ArrayMesh).surface_get_name(s)
	return ""


static func roles(mesh: Mesh) -> PackedInt32Array:
	var out := PackedInt32Array()
	for s in mesh.get_surface_count():
		var r := role_of(surface_name(mesh, s))
		var arr: Array = mesh.surface_get_arrays(s)
		var n: int = (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		for i in n:
			out.append(r)
	return out
