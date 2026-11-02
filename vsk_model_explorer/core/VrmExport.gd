extends RefCounted
# Writes a rigged humanoid as a VRM 1.0 file. The humanoid roles come from the rig program's
# matcher (role -> skeleton bone name). The export renames those bones to Godot's humanoid names,
# turns the model to face +Z (left on +X), swaps every material to MToon and writes the file with
# the VRM add-on's glTF extensions. The T-pose is not done here: skintokens.elf's VRM step does it
# afterwards, as for any .vrm. Materials are always MToon: many VRM players refuse PBR.
# Fingers: roles that name them (<side>_<finger>_<1..3>, base to tip) are used as given; else
# _find_fingers() reads them off the skeleton (see there), or the hand gets none.
# MToon defaults come from a ColorChecker calibration against the PBR look (24 patches, mean
# dE2000 1.5 under neutral light, 2.3 under the viewer's sky in physical light units): shade =
# 0.2 x base, toony 0.2, shift 0, giEqualization 0.1. The MToon 1.0 defaults score 7.0 there.

const SHADE := 0.2
const TOONY := 0.2
const SHIFT := 0.0
const INDIRECT := 0.9  # = 1 - giEqualizationFactor
const SHADER_DIR := "res://addons/Godot-MToon-Shader/"
const VRMTopLevel := preload("res://addons/vrm/vrm_toplevel.gd")
const VRMMeta := preload("res://addons/vrm/vrm_meta.gd")
const EXTENSIONS := [
	preload("res://addons/vrm/1.0/VRMC_vrm.gd"),
	preload("res://addons/vrm/1.0/VRMC_node_constraint.gd"),
	preload("res://addons/vrm/1.0/VRMC_springBone.gd"),
	preload("res://addons/vrm/1.0/VRMC_materials_hdr_emissiveMultiplier.gd"),
	preload("res://addons/vrm/1.0/VRMC_materials_mtoon.gd"),
]
const NAMED_SKIN_BINDS := 16  # EditorSceneFormatImporter.IMPORT_USE_NAMED_SKIN_BINDS
const ROLE_TO_HUMAN := {
	"hips": "Hips",
	"spine1": "Spine",
	"spine2": "Chest",
	"chest": "UpperChest",
	"neck": "Neck",
	"head": "Head",
	"left_shoulder": "LeftShoulder",
	"left_upper_arm": "LeftUpperArm",
	"left_forearm": "LeftLowerArm",
	"left_hand": "LeftHand",
	"right_shoulder": "RightShoulder",
	"right_upper_arm": "RightUpperArm",
	"right_forearm": "RightLowerArm",
	"right_hand": "RightHand",
	"left_upper_leg": "LeftUpperLeg",
	"left_shin": "LeftLowerLeg",
	"left_foot": "LeftFoot",
	"left_toe": "LeftToes",
	"right_upper_leg": "RightUpperLeg",
	"right_shin": "RightLowerLeg",
	"right_foot": "RightFoot",
	"right_toe": "RightToes",
	"left_thumb_1": "LeftThumbMetacarpal",
	"left_thumb_2": "LeftThumbProximal",
	"left_thumb_3": "LeftThumbDistal",
	"left_index_1": "LeftIndexProximal",
	"left_index_2": "LeftIndexIntermediate",
	"left_index_3": "LeftIndexDistal",
	"left_middle_1": "LeftMiddleProximal",
	"left_middle_2": "LeftMiddleIntermediate",
	"left_middle_3": "LeftMiddleDistal",
	"left_ring_1": "LeftRingProximal",
	"left_ring_2": "LeftRingIntermediate",
	"left_ring_3": "LeftRingDistal",
	"left_little_1": "LeftLittleProximal",
	"left_little_2": "LeftLittleIntermediate",
	"left_little_3": "LeftLittleDistal",
	"right_thumb_1": "RightThumbMetacarpal",
	"right_thumb_2": "RightThumbProximal",
	"right_thumb_3": "RightThumbDistal",
	"right_index_1": "RightIndexProximal",
	"right_index_2": "RightIndexIntermediate",
	"right_index_3": "RightIndexDistal",
	"right_middle_1": "RightMiddleProximal",
	"right_middle_2": "RightMiddleIntermediate",
	"right_middle_3": "RightMiddleDistal",
	"right_ring_1": "RightRingProximal",
	"right_ring_2": "RightRingIntermediate",
	"right_ring_3": "RightRingDistal",
	"right_little_1": "RightLittleProximal",
	"right_little_2": "RightLittleIntermediate",
	"right_little_3": "RightLittleDistal",
}
const FINGERS := ["thumb", "index", "middle", "ring", "little"]
const REQUIRED := [
	"hips",
	"spine1",
	"head",
	"left_upper_arm",
	"left_forearm",
	"left_hand",
	"right_upper_arm",
	"right_forearm",
	"right_hand",
	"left_upper_leg",
	"left_shin",
	"left_foot",
	"right_upper_leg",
	"right_shin",
	"right_foot",
]

var report := {}  # what the export decided, for logs and tests


# Returns "" on success, else why the model does not fit a VRM.
func export_vrm(glb_path: String, roles: Dictionary, out_path: String, meta := {}, source := "") -> String:
	for r in REQUIRED:
		if not roles.has(r):
			return "no %s bone" % r
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(glb_path, state) != OK:
		return "cannot read " + glb_path
	var scene: Node = doc.generate_scene(state)
	var asset: Dictionary = state.get_json().get("asset", {})
	if not asset.has("extras") and source != "":
		asset = _asset_of(source)  # a rig step may drop extras; the file it was made from still has them
	var why := _build(scene, roles, glb_path.get_file().get_basename().trim_suffix(".rigged"), asset, meta)
	if why == "":
		why = _write(scene, out_path)
	scene.free()
	return why


# The "asset" object of a .glb's JSON chunk, or {} when it cannot be read.
static func _asset_of(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 20 or f.get_32() != 0x46546C67:
		return {}
	f.seek(12)
	var n := f.get_32()
	f.get_32()
	var json = JSON.parse_string(f.get_buffer(n).get_string_from_utf8())
	return json.get("asset", {}) if json is Dictionary else {}
# The VRM meta comes from the source file: the glb's asset.extras (author, license, source, title), and
# `given` (keys: title, authors, license_url, references) wins over it. Nothing is invented: a model
# with no author or no licence URL is refused, because VRM 1.0 requires both.
# extras.author is "Name (url)" and extras.license is "SPDX-id (url)", the form Sketchfab writes.
static func _meta_from(asset: Dictionary, title: String, given: Dictionary) -> Variant:
	var extras: Dictionary = asset.get("extras", {})
	var rx := RegEx.create_from_string("^(.*?)\\s*\\((https?://[^)]*)\\)\\s*$")
	var meta: VRMMeta = VRMMeta.new()
	meta.spec_version = "1.0"
	meta.title = str(given.get("title", extras.get("title", title)))
	var authors: PackedStringArray = given.get("authors", PackedStringArray())
	if authors.is_empty() and extras.has("author"):
		var m := rx.search(str(extras.author))
		authors = PackedStringArray([m.get_string(1) if m else str(extras.author)])
	if authors.is_empty():
		return "no author: the file's asset.extras has none and none was given"
	meta.authors = authors
	var url: String = str(given.get("license_url", ""))
	if url == "" and extras.has("license"):
		var m := rx.search(str(extras.license))
		url = m.get_string(2) if m else ""
	if url == "":
		return "no licence URL: the file's asset.extras has none and none was given"
	meta.license_url = url
	var refs: PackedStringArray = given.get("references", PackedStringArray())
	if refs.is_empty() and extras.has("source"):
		refs = PackedStringArray([str(extras.source)])
	meta.references = refs
	return meta
func _build(scene: Node, roles: Dictionary, title: String, asset: Dictionary, given := {}) -> String:
	var meta_or_why: Variant = _meta_from(asset, title, given)
	if meta_or_why is String:
		return meta_or_why
	var skel: Skeleton3D
	for s in scene.find_children("*", "Skeleton3D", true, false):
		if s.find_bone(roles.hips) >= 0:
			skel = s
	if skel == null:
		return "no skeleton holds the hips bone"
	roles = roles.duplicate()
	if not roles.has("spine2") and roles.has("chest"):
		roles.spine2 = roles.chest  # VRM needs chest before upperChest
		roles.erase("chest")
	var to_scene := _to_root(skel, scene)
	var surfaces := _surface_count(scene)
	var p := func(role: String) -> Vector3:
		return to_scene * skel.get_bone_global_rest(skel.find_bone(roles[role])).origin
	if p.call("head").y <= p.call("hips").y:
		return "the model is not upright (head below hips)"
	# Facing: left-right from the upper legs; forward = left x up. The toes must agree, otherwise
	# the matcher's sides are swapped.
	var left: Vector3 = p.call("left_upper_leg") - p.call("right_upper_leg")
	left.y = 0
	var forward := left.cross(Vector3.UP).normalized()
	if roles.has("left_toe") and roles.has("right_toe"):
		var toes: Vector3 = (
			(p.call("left_toe") - p.call("left_foot"))
			+ (p.call("right_toe") - p.call("right_foot"))
		)
		toes.y = 0
		report.toe_agreement = toes.normalized().dot(forward)
		if report.toe_agreement < 0:
			roles = _swap_sides(roles)
			forward = -forward
	var yaw := atan2(forward.x, forward.z)
	report.turned_degrees = rad_to_deg(-yaw)
	_turn(scene, skel, Transform3D(Basis(Vector3.UP, -yaw), Vector3.ZERO), to_scene)
	# The T-pose comes after the export (skintokens.elf's VRM step: from any pose, with the mesh
	# skinned into it), so this file keeps the rig's own rest pose.
	# The VRM carries no clips: its rest pose is the pose.
	for ap in scene.find_children("*", "AnimationPlayer", true, false):
		ap.get_parent().remove_child(ap)
		ap.free()
	if _surface_count(scene) != surfaces:
		return (
			"lost mesh surfaces while turning or posing (%d of %d left)"
			% [_surface_count(scene), surfaces]
		)
	for side in ["left", "right"]:
		if not roles.has(side + "_thumb_1"):
			report[side + "_fingers"] = _find_fingers(scene, skel, roles, side)
	_rename_bones(scene, skel, roles)
	skel.name = "GeneralSkeleton"
	report.mtoon_materials = _to_mtoon(scene)
	report.roles = roles
	# Wrap in the VRM top level.
	var root := Node3D.new()
	root.name = title
	root.set_script(VRMTopLevel)
	root.vrm_meta = meta_or_why
	# Godot's multi-root export drops the joints of a Skeleton3D that is itself a scene root, so
	# the skeleton hangs under a plain "Armature" node.
	var armature := Node3D.new()
	armature.name = "Armature"
	root.add_child(armature)
	for c in scene.get_children():
		_own(c, null)
		c.owner = null
		scene.remove_child(c)
		armature.add_child(c)
	_own(root, root)
	skel.unique_name_in_owner = true
	scene.add_child(root)
	return ""


func _write(scene: Node, out_path: String) -> String:
	var root: Node = scene.get_child(0)
	scene.remove_child(root)
	var exts := []
	for e in EXTENSIONS:
		exts.append(e.new())
		GLTFDocument.register_gltf_document_extension(exts[-1])
	var doc := GLTFDocument.new()
	doc.root_node_mode = GLTFDocument.ROOT_NODE_MODE_MULTI_ROOT
	var state := GLTFState.new()
	state.set_meta("vrm", "1.0")
	state.set_meta("anim_player", null)  # VRMC_vrm reads it even when there is no clip
	var err := doc.append_from_scene(root, state, NAMED_SKIN_BINDS)
	# GLTFDocument picks binary output by the .glb extension only.
	var tmp := out_path + ".tmp.glb"
	if err == OK:
		err = doc.write_to_filesystem(state, tmp)
	if err == OK:
		DirAccess.remove_absolute(out_path)
		err = DirAccess.rename_absolute(tmp, out_path)
	for e in exts:
		GLTFDocument.unregister_gltf_document_extension(e)
	root.free()
	return "" if err == OK else "VRM write failed (%s)" % error_string(err)


static func _to_root(node: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != root and n is Node3D:
		t = n.transform * t
		n = n.get_parent()
	return t


static func _turn(scene: Node, skel: Skeleton3D, turn: Transform3D, to_scene: Transform3D) -> void:
	if turn.basis.is_equal_approx(Basis.IDENTITY):
		return
	var t := to_scene.affine_inverse() * turn * to_scene
	for b in skel.get_parentless_bones():
		skel.set_bone_rest(b, t * skel.get_bone_rest(b))
		skel.set_bone_pose(b, skel.get_bone_rest(b))
	var skins := {}
	var meshes := {}
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		if mi.skin != null and mi.mesh is ArrayMesh:
			skins[mi.skin] = true
			if not meshes.has(mi.mesh):
				meshes[mi.mesh] = _transformed_mesh(mi.mesh, t)
			mi.mesh = meshes[mi.mesh]
		elif not skel.is_ancestor_of(mi):
			mi.transform = turn * mi.transform
	for skin: Skin in skins:
		for i in skin.get_bind_count():
			skin.set_bind_pose(i, skin.get_bind_pose(i) * t.affine_inverse())


static func _transformed_mesh(src: ArrayMesh, t: Transform3D) -> ArrayMesh:
	var dst := ArrayMesh.new()
	dst.resource_name = src.resource_name
	dst.blend_shape_mode = src.blend_shape_mode
	for i in src.get_blend_shape_count():
		dst.add_blend_shape(src.get_blend_shape_name(i))
	var relative := src.blend_shape_mode == Mesh.BLEND_SHAPE_MODE_RELATIVE
	for s in src.get_surface_count():
		var arrays := _transform_arrays(src.surface_get_arrays(s), t, false)
		var shapes: Array = []
		for shape in src.surface_get_blend_shape_arrays(s):
			shapes.append(_transform_arrays(shape, t, relative))
		var flags := _rebuild_flags(src.surface_get_format(s))
		dst.add_surface_from_arrays(src.surface_get_primitive_type(s), arrays, shapes, {}, flags)
		dst.surface_set_material(s, src.surface_get_material(s))
		dst.surface_set_name(s, src.surface_get_name(s))
	return dst


# Flags a rebuilt surface must keep: 8 bone weights and the formats of the custom channels (a
# glTF's extra UV sets land there). Without them Godot reads every custom channel as RGBA8
# bytes and drops the surface.
static func _rebuild_flags(format: int) -> int:
	var keep := Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
	for c in 4:
		var shift := Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT + c * Mesh.ARRAY_FORMAT_CUSTOM_BITS
		keep |= Mesh.ARRAY_FORMAT_CUSTOM_MASK << shift
	return format & keep


static func _surface_count(scene: Node) -> int:
	var n := 0
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh:
			n += mi.mesh.get_surface_count()
	return n


static func _transform_arrays(arrays: Array, t: Transform3D, deltas: bool) -> Array:
	var basis := t.basis
	if arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i] = basis * v[i] if deltas else t * v[i]
		arrays[Mesh.ARRAY_VERTEX] = v
	if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in n.size():
			n[i] = basis * n[i]
		arrays[Mesh.ARRAY_NORMAL] = n
	if arrays[Mesh.ARRAY_TANGENT] is PackedFloat32Array:
		var tg: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		for i in range(0, tg.size(), 4):
			var r := basis * Vector3(tg[i], tg[i + 1], tg[i + 2])
			tg[i] = r.x
			tg[i + 1] = r.y
			tg[i + 2] = r.z
		arrays[Mesh.ARRAY_TANGENT] = tg
	return arrays


static func _swap_sides(roles: Dictionary) -> Dictionary:
	var out := {}
	for r in roles:
		var s: String = r
		if s.begins_with("left_"):
			s = "right_" + s.substr(5)
		elif s.begins_with("right_"):
			s = "left_" + s.substr(6)
		out[s] = roles[r]
	return out


# A hand's fingers from the skeleton, for rigs whose roles name none. The hand must have exactly
# five child chains of at least three joints (more joints: the first three count). The thumb is
# the chain whose base is nearest the wrist (its metacarpal starts at the wrist; this holds in a
# T-pose and with the arms down); in the model's frame after the turn (facing +Z) the other four go
# front to back as index, middle, ring, little. Adds the roles and returns "", or returns why the hand gets no finger bones.
static func _find_fingers(scene: Node, skel: Skeleton3D, roles: Dictionary, side: String) -> String:
	var hand := skel.find_bone(roles[side + "_hand"])
	var to_scene := _to_root(skel, scene)
	var pos := func(b: int) -> Vector3: return to_scene * skel.get_bone_global_rest(b).origin
	var chains := []
	for c in skel.get_bone_children(hand):
		var chain: Array[int] = [c]
		while chain.size() < 3 and skel.get_bone_children(chain[-1]).size() > 0:
			var next: PackedInt32Array = skel.get_bone_children(chain[-1])
			if next.size() != 1:
				break
			chain.append(next[0])
		if chain.size() == 3:
			chains.append(chain)
	if chains.size() != 5:
		return "%d three-joint chains under the hand, not 5" % chains.size()
	var wrist: Vector3 = pos.call(hand)
	var thumb := 0
	var nearest := INF
	for i in chains.size():
		var d: float = (pos.call(chains[i][0]) - wrist).length()
		if d < nearest:
			nearest = d
			thumb = i
	var rest := []
	for i in chains.size():
		if i != thumb:
			rest.append(chains[i])
	rest.sort_custom(func(a, b): return pos.call(a[0]).z > pos.call(b[0]).z)
	var ordered := [chains[thumb]] + rest
	for f in FINGERS.size():
		for k in 3:
			roles["%s_%s_%d" % [side, FINGERS[f], k + 1]] = skel.get_bone_name(ordered[f][k])
	return ""


static func _rename_bones(scene: Node, skel: Skeleton3D, roles: Dictionary) -> void:
	var rename := {}
	for r in roles:
		rename[roles[r]] = ROLE_TO_HUMAN[r]
	var taken := {}
	for v in rename.values():
		taken[v] = true
	for i in skel.get_bone_count():  # a source bone already called "Head" etc. moves aside
		var n := skel.get_bone_name(i)
		if taken.has(n) and not rename.has(n):
			rename[n] = n + "_source"
	var old_names := {}
	for i in skel.get_bone_count():
		old_names[i] = skel.get_bone_name(i)
	for i in skel.get_bone_count():
		if rename.has(old_names[i]):
			skel.set_bone_name(i, "__vrm_tmp_%d" % i)
	for i in skel.get_bone_count():
		if rename.has(old_names[i]):
			skel.set_bone_name(i, rename[old_names[i]])
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		var skin: Skin = mi.skin
		if skin == null:
			continue
		for b in skin.get_bind_count():
			if rename.has(String(skin.get_bind_name(b))):
				skin.set_bind_name(b, rename[String(skin.get_bind_name(b))])


static func _to_mtoon(scene: Node) -> int:
	var made := {}
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(s)
			if src == null:
				src = mi.mesh.surface_get_material(s)
			if not made.has(src):
				made[src] = mtoon_from(src as BaseMaterial3D)
			mi.set_surface_override_material(s, made[src])
	return made.size()


static func mtoon_from(src: BaseMaterial3D) -> ShaderMaterial:
	var col := Color.WHITE
	var tex: Texture2D
	var variant := "mtoon"
	var m := ShaderMaterial.new()
	if src != null:
		col = src.albedo_color
		tex = src.albedo_texture
		if src.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			variant = "mtoon_cutout"
			m.set_shader_parameter("_AlphaCutoutEnable", 1.0)
			m.set_shader_parameter("_Cutoff", src.alpha_scissor_threshold)
		elif src.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			variant = "mtoon_trans"
		if src.cull_mode == BaseMaterial3D.CULL_DISABLED:
			variant += "_cull_off"
		if src.normal_enabled and src.normal_texture:
			m.set_shader_parameter("_BumpMap", src.normal_texture)
			m.set_shader_parameter("_BumpScale", src.normal_scale)
		if src.emission_enabled:
			m.set_shader_parameter("_EmissionColor", src.emission)
			m.set_shader_parameter("_EmissionMultiplier", src.emission_energy_multiplier)
			if src.emission_texture:
				m.set_shader_parameter("_EmissionMap", src.emission_texture)
		m.resource_name = src.resource_name
	m.shader = load(SHADER_DIR + variant + ".gdshader")
	# The VRM add-on reads every uniform back, so store the shader defaults explicitly first.
	var defaults := uniform_defaults()
	for u in defaults:
		if m.get_shader_parameter(u) == null:
			m.set_shader_parameter(u, defaults[u])
	m.set_shader_parameter("_Color", col)
	m.set_shader_parameter("_ShadeColor", Color(col.r * SHADE, col.g * SHADE, col.b * SHADE, 1.0))
	if tex:
		m.set_shader_parameter("_MainTex", tex)
		m.set_shader_parameter("_ShadeTexture", tex)
	m.set_shader_parameter("_ShadeToony", TOONY)
	m.set_shader_parameter("_ShadeShift", SHIFT)
	m.set_shader_parameter("_IndirectLightIntensity", INDIRECT)
	m.set_shader_parameter("_OutlineWidthMode", 0.0)
	return m


# Float and vec4 uniform defaults, read from the MToon shader source. RenderingServer cannot give
# them on a headless (dummy) renderer, and the VRM add-on fails on any unset uniform.
static func uniform_defaults() -> Dictionary:
	var out := {}
	var inc: ShaderInclude = load(SHADER_DIR + "mtoon_common.gdshaderinc")
	var re := RegEx.create_from_string(
		"uniform\\s+(float|vec4)\\s+(\\w+)[^=;]*=\\s*(?:vec4\\s*\\(([^)]*)\\)|([-0-9.]+))\\s*;"
	)
	for r in re.search_all(inc.code):
		if r.get_string(1) == "float":
			out[r.get_string(2)] = float(r.get_string(4))
		else:
			var v := r.get_string(3).split(",")
			out[r.get_string(2)] = Vector4(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
	return out


static func _own(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		_own(c, owner)
