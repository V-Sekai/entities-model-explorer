extends Node
# OpenUSD input: usd.elf (OpenUSD in the godot-sandbox add-on) opens a .usd, .usda, .usdc or .usdz
# file from its bytes and answers with packed arrays. This script makes Godot nodes from them
# (meshes, materials, skeletons, skins, blend shapes, skeletal clips) and saves one GLB that the
# viewer opens and the auto-rig reads.
#
# Conversion rules (interactor-flow's MeshConverter / AnimationConverter):
# - USD triangles are counter-clockwise, Godot's clockwise: corners 1 and 2 swap. USD's st origin
#   is bottom left: v -> 1 - v.
# - A 4x4 (mesh xform, geomBindTransform) is GfMatrix4d, row-vector: row i = image of axis i,
#   row 3 = origin. A joint's 12 floats are a row-major 3x3 in the column-vector convention, then
#   the translation.
# - A skinned mesh is baked into its skeleton's space (geomBindTransform) and hangs under the
#   Skeleton3D; each bind is the inverse of the joint's bindTransform.
# - An in-between is its own blend shape; clip weights are baked through the piecewise-linear
#   basis (base at 0, in-betweens at their positions, the target at 1), as USD interpolates.
# - A Z-up stage turns to Y-up and metersPerUnit scales to metres, on the single root node.

signal converted(source: String, glb: String, why: String)

const Bintr = preload("res://vsk_model_explorer/core/Bintr.gd")
const ELF := "res://usd.elf"
const CHUNK := 8 << 20  # bytes per usd_push (the 16 MiB view)
const ASSET_CHUNK := 8 << 20  # bytes per usd_asset_push
const SLICE := 1 << 18  # items per array slice
const MAX_WEIGHTS := 8
# The extensions a loose document is made of: its layers and its textures. Only
# these are streamed, so opening one layer in a busy folder does not sweep the
# folder in.
const DOC_EXT := [
	"usd",
	"usda",
	"usdc",
	"usdz",
	"png",
	"jpg",
	"jpeg",
	"exr",
	"webp",
	"tif",
	"tiff",
	"bmp",
	"hdr",
	"tx",
]

var _sb: Node
var why := ""


# Web: converts on the next frame, from the engine's main loop rather than from inside the
# caller (a guest script), emits `converted`, then frees itself.
func convert_later(path: String, out: String) -> void:
	_convert_now.call_deferred(path, out)


func _convert_now(path: String, out: String) -> void:
	var w := to_glb(path, out)
	converted.emit(path, out, w)
	queue_free()


# Converts `path` to a GLB at `out`. Returns "" when done, else the reason.
func to_glb(path: String, out: String) -> String:
	why = ""
	var root := to_scene(path)
	if root == null:
		return why
	add_child(root)
	var doc := GLTFDocument.new()
	doc.root_node_mode = GLTFDocument.ROOT_NODE_MODE_SINGLE_ROOT
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state, 16)  # 16 = named skin binds
	if err == OK:
		err = doc.write_to_filesystem(state, out)
	remove_child(root)
	root.free()
	if err != OK:
		return "cannot save %s (error %d)" % [out.get_file(), err]
	return ""


# Streams a loose document into `sb` (the guest): every layer and texture under
# `path`'s directory, each under its path relative to that directory, then opens
# the root layer at `path`. A .usdz is not needed first. Returns the guest's
# open line ("ok ..." or "ERR: ...").
static func stream_document(sb: Node, path: String) -> String:
	var base := path.get_base_dir()
	var root := path.get_file()
	var files: Array = []
	_collect_files(base, base, files)
	for f in files:
		var rel: String = (f as String).substr(base.length() + 1)
		var bytes := FileAccess.get_file_as_bytes(f)
		if bytes.is_empty():
			continue
		if bytes.size() <= ASSET_CHUNK:
			var r := str(sb.vmcall("usd_asset", rel, bytes))
			if not r.begins_with("ok"):
				return "ERR: streaming %s: %s" % [rel, r]
		else:
			var at := 0
			while at < bytes.size():
				var r := str(sb.vmcall("usd_asset_push", rel, bytes.slice(at, at + ASSET_CHUNK)))
				if not r.begins_with("staged"):
					return "ERR: streaming %s: %s" % [rel, r]
				at += ASSET_CHUNK
			var e := str(sb.vmcall("usd_asset_end", rel))
			if not e.begins_with("ok"):
				return "ERR: streaming %s: %s" % [rel, e]
	return str(sb.vmcall("usd_open_asset", root))


# Every layer and texture under `at`, depth first, into `out`.
static func _collect_files(base: String, at: String, out: Array) -> void:
	var d := DirAccess.open(at)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not n.begins_with("."):
			var full := at.path_join(n)
			if d.current_is_dir():
				_collect_files(base, full, out)
			elif DOC_EXT.has(full.get_extension().to_lower()):
				out.append(full)
		n = d.get_next()
	d.list_dir_end()


func to_scene(path: String) -> Node3D:
	if not ClassDB.class_exists("Sandbox"):
		return _fail("OpenUSD needs the godot-sandbox library beside the program.")
	if not FileAccess.file_exists(ELF):
		return _fail("usd.elf is missing from the program.")
	if not FileAccess.file_exists(path):
		return _fail("cannot read " + path.get_file())
	# wasm32 has one 4 GiB address space shared with the engine: a 2 GiB guest arena does not fit.
	_sb = Bintr.make(self, ELF, 512 if OS.has_feature("web") else 2048, 4096)
	if not _sb.has_function("usd_skeleton_info"):
		return _close(_fail("usd.elf did not load"))
	_sb.vmcall("usd_init")
	var line := ""
	if path.get_extension().to_lower() == "usdz":
		# One package: its own resolver reads the zip's members, so the whole
		# file goes in, in CHUNK pieces past the 16 MiB view.
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			return _close(_fail("cannot read " + path.get_file()))
		if bytes.size() <= CHUNK:
			line = str(_sb.vmcall("usd_open", bytes))
		else:
			for at in range(0, bytes.size(), CHUNK):
				var r := str(_sb.vmcall("usd_push", bytes.slice(at, at + CHUNK)))
				if not r.begins_with("staged="):
					return _close(_fail("OpenUSD: " + r))
			line = str(_sb.vmcall("usd_open_staged"))
	else:
		# A loose layer: stream every layer and texture beside it in, then open
		# the root. No .usdz has to be built first.
		line = stream_document(_sb, path)
	print("USD-OPEN ", line)
	if not line.begins_with("ok"):
		return _close(_fail("OpenUSD cannot open %s: %s" % [path.get_file(), line]))
	var root := Node3D.new()
	root.name = path.get_file().get_basename().validate_node_name()
	var up := _field(line, "up", "Y")
	var mpu := float(_field(line, "mpu", "1"))
	var fix := Basis.IDENTITY
	if up == "Z":
		fix = Basis(Vector3.RIGHT, -PI / 2)
	if mpu > 0.0 and not is_equal_approx(mpu, 1.0):
		fix = fix.scaled(Vector3.ONE * mpu)
	root.transform = Transform3D(fix, Vector3.ZERO)
	_build(root)
	_close(null)
	return root


func _build(root: Node3D) -> void:
	var mats := []
	var tex_cache := {}
	for i in int(_sb.vmcall("usd_material_count")):
		mats.append(_material(i, tex_cache))
	var skels := []
	for s in int(_sb.vmcall("usd_skeleton_count")):
		skels.append(_skeleton(s, root))
	var shapes_of := {}  # mesh index -> [blend-shape records]
	for k in int(_sb.vmcall("usd_blend_shape_count")):
		var b = _sb.vmcall("usd_blend_shape_info", k)
		if typeof(b) != TYPE_DICTIONARY:
			continue
		var rec: Dictionary = b.duplicate()
		rec["k"] = k
		if not shapes_of.has(int(b.mesh)):
			shapes_of[int(b.mesh)] = []
		shapes_of[int(b.mesh)].append(rec)
	var used_names := {}
	for i in int(_sb.vmcall("usd_mesh_count")):
		var info = _sb.vmcall("usd_mesh_info", i)
		if typeof(info) != TYPE_DICTIONARY:
			continue
		var s := int(info.skeleton)
		var skin = _sb.vmcall("usd_mesh_skin", i) if s >= 0 and s < skels.size() else null
		var skinned := typeof(skin) == TYPE_DICTIONARY
		var mi := MeshInstance3D.new()
		mi.name = _unique(str(info.name).validate_node_name(), used_names)
		var bake := Transform3D.IDENTITY
		if skinned:
			bake = skels[s].world * _xf16(skin.geom_bind)
			skels[s].node.add_child(mi)
		else:
			mi.transform = _xf16(info.xform)
			root.add_child(mi)
		mi.mesh = _mesh(i, info, mats, shapes_of.get(i, []), skin if skinned else null, bake)
		if skinned:
			mi.skin = skels[s].skin
			mi.skeleton = NodePath("..")
		mi.set_meta("usd_skeleton", s if skinned else -1)
	for a in int(_sb.vmcall("usd_skel_anim_count")):
		_clip(a, root, skels)


func _skeleton(s: int, root: Node3D) -> Dictionary:
	var info: Dictionary = _sb.vmcall("usd_skeleton_info", s)
	var names := str(info.names).split("\n", false)
	var paths := str(info.joints).split("\n", false)
	var parents: PackedInt32Array = info.parents
	var rests := _floats("usd_skeleton_rests_slice", s, parents.size(), 12)
	var binds := _floats("usd_skeleton_binds_slice", s, parents.size(), 12)
	# The skeleton prim's world transform is baked into the root joints' rests and every bind:
	# Godot's glTF writer drops a Skeleton3D node's own transform.
	var world := _xf16(info.xform)
	var sk := Skeleton3D.new()
	sk.name = "Skeleton" if s == 0 else "Skeleton%d" % s
	root.add_child(sk)
	var used := {}
	var skin := Skin.new()
	for j in parents.size():
		var nm := names[j] if j < names.size() else "joint%d" % j
		nm = _unique(nm.replace(":", "_").replace("/", "_"), used)
		sk.add_bone(nm)
	for j in parents.size():
		if parents[j] >= 0:
			sk.set_bone_parent(j, parents[j])
		var rest := _xf12(rests, j)
		if parents[j] < 0:
			rest = world * rest
		sk.set_bone_rest(j, rest)
		sk.set_bone_pose(j, rest)
		skin.add_named_bind(sk.get_bone_name(j), (world * _xf12(binds, j)).affine_inverse())
	return {
		"node": sk,
		"skin": skin,
		"paths": paths,
		"animation": str(info.animation),
		"world": world,
		"parents": parents
	}


func _mesh(
	i: int, info: Dictionary, mats: Array, shapes: Array, skin, bake: Transform3D
) -> ArrayMesh:
	var n := int(info.points)
	var p := _floats("usd_mesh_points_slice", i, n, 3)
	var nr := (
		_floats("usd_mesh_normals_slice", i, n, 3) if info.has_normals else PackedFloat32Array()
	)
	var uv := _floats("usd_mesh_uvs_slice", i, n, 2) if info.has_uvs else PackedFloat32Array()
	var tri := _ints("usd_mesh_indices_slice", i, int(info.triangles), 3)
	var pts := PackedVector3Array()
	pts.resize(n)
	for v in n:
		pts[v] = bake * Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2])
	var nrm := PackedVector3Array()
	nrm.resize(n)
	var nb := bake.basis.inverse().transposed()
	if nr.size() == 3 * n:
		for v in n:
			nrm[v] = (nb * Vector3(nr[3 * v], nr[3 * v + 1], nr[3 * v + 2])).normalized()
	else:
		# Smooth normals, area weighted, from USD's counter-clockwise corners.
		for t in range(0, tri.size(), 3):
			var a := tri[t]
			var b := tri[t + 1]
			var c := tri[t + 2]
			var fn := (pts[b] - pts[a]).cross(pts[c] - pts[a])
			nrm[a] += fn
			nrm[b] += fn
			nrm[c] += fn
		for v in n:
			nrm[v] = nrm[v].normalized() if nrm[v].length_squared() > 0.0 else Vector3.UP
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var per := 0
	if skin != null:
		var es := int(skin.element_size)
		var ji := _ints("usd_mesh_skin_indices_slice", i, n, es)
		var jw := _floats("usd_mesh_skin_weights_slice", i, n, es)
		per = 4 if es <= 4 else MAX_WEIGHTS
		bones.resize(n * per)
		weights.resize(n * per)
		for v in n:
			var pairs := []
			for e in es:
				if jw[v * es + e] > 0.0:
					pairs.append([jw[v * es + e], ji[v * es + e]])
			pairs.sort_custom(func(x, y): return x[0] > y[0])
			pairs.resize(mini(pairs.size(), per))
			var sum := 0.0
			for q in pairs:
				sum += q[0]
			for e in pairs.size():
				bones[v * per + e] = pairs[e][1]
				weights[v * per + e] = pairs[e][0] / sum if sum > 0.0 else 0.0
	# Blend shapes: one Godot shape per record (target or in-between). In the normalized mode the
	# arrays hold whole positions and normals (base + offset); the glTF writer stores the
	# differences. (The relative mode would need zero normal offsets, which Godot's normal
	# encoding cannot hold.)
	var am := ArrayMesh.new()
	am.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_NORMALIZED
	var shape_pts := []
	var shape_nrm := []
	var shape_names := {}
	for rec in shapes:
		var nm := _unique(str(rec.name).replace(":", "_"), shape_names)
		rec["godot"] = nm
		am.add_blend_shape(nm)
		var off := _floats("usd_blend_shape_offsets_slice", int(rec.k), n, 3)
		var sp := PackedVector3Array()
		sp.resize(n)
		for v in n:
			var d := (
				Vector3(off[3 * v], off[3 * v + 1], off[3 * v + 2])
				if off.size() == 3 * n
				else Vector3.ZERO
			)
			sp[v] = pts[v] + bake.basis * d
		shape_pts.append(sp)
		var sn := PackedVector3Array()
		if rec.has_normals:
			var no := _floats("usd_blend_shape_normals_slice", int(rec.k), n, 3)
			sn.resize(n)
			for v in n:
				var d := (
					Vector3(no[3 * v], no[3 * v + 1], no[3 * v + 2])
					if no.size() == 3 * n
					else Vector3.ZERO
				)
				sn[v] = (nrm[v] + nb * d).normalized()
		shape_nrm.append(sn)
	am.set_meta("usd_shapes", shapes)
	# Surfaces: one per GeomSubset run, each with only the vertices it uses.
	var runs: PackedInt32Array = info.surfaces
	if runs.is_empty():
		runs = PackedInt32Array([int(info.material), 0, tri.size() / 3])
	for r in range(0, runs.size(), 3):
		var remap := {}
		var order := PackedInt32Array()
		var idx := PackedInt32Array()
		for t in range(runs[r + 1], runs[r + 1] + runs[r + 2]):
			for c in [0, 2, 1]:
				var v := tri[3 * t + c]
				if not remap.has(v):
					remap[v] = order.size()
					order.append(v)
				idx.append(remap[v])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = _pick3(pts, order)
		arrays[Mesh.ARRAY_NORMAL] = _pick3(nrm, order)
		if uv.size() == 2 * n:
			var tv := PackedVector2Array()
			tv.resize(order.size())
			for o in order.size():
				tv[o] = Vector2(uv[2 * order[o]], 1.0 - uv[2 * order[o] + 1])
			arrays[Mesh.ARRAY_TEX_UV] = tv
		if per > 0:
			var bb := PackedInt32Array()
			var ww := PackedFloat32Array()
			bb.resize(order.size() * per)
			ww.resize(order.size() * per)
			for o in order.size():
				for e in per:
					bb[o * per + e] = bones[order[o] * per + e]
					ww[o * per + e] = weights[order[o] * per + e]
			arrays[Mesh.ARRAY_BONES] = bb
			arrays[Mesh.ARRAY_WEIGHTS] = ww
		arrays[Mesh.ARRAY_INDEX] = idx
		var blends := []
		for b in shape_pts.size():
			var ba := []
			ba.resize(Mesh.ARRAY_MAX)
			ba[Mesh.ARRAY_VERTEX] = _pick3(shape_pts[b], order)
			# Godot requires a normal array beside the vertex one; no authored offsets = the base's.
			ba[Mesh.ARRAY_NORMAL] = (
				_pick3(shape_nrm[b], order)
				if not shape_nrm[b].is_empty()
				else arrays[Mesh.ARRAY_NORMAL]
			)
			blends.append(ba)
		var flags := Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if per == 8 else 0
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, blends, {}, flags)
		var m := runs[r]
		if m >= 0 and m < mats.size():
			am.surface_set_material(am.get_surface_count() - 1, mats[m])
	return am


# A UsdSkelAnimation as an AnimationPlayer clip on its skeleton: joint transforms per frame,
# and the blend-shape weights baked to the in-between shapes.
func _clip(a: int, root: Node3D, skels: Array) -> void:
	var info = _sb.vmcall("usd_skel_anim_info", a)
	if typeof(info) != TYPE_DICTIONARY or int(info.frames) == 0:
		return
	var sk: Dictionary = {}
	for s in skels:
		if s.animation == str(info.path):
			sk = s
	if sk.is_empty():
		if skels.size() != 1:
			return
		sk = skels[0]
	var node: Skeleton3D = sk.node
	var fps := float(info.fps) if float(info.fps) > 0.0 else 24.0
	var times := str(info.times).split("\n", false)
	var frames := int(info.frames)
	var t0 := float(times[0]) if times.size() > 0 else 0.0
	var anim := Animation.new()
	anim.length = maxf(
		(float(times[frames - 1]) - t0) / fps if times.size() >= frames else 0.0, 1.0 / fps
	)
	var joints := str(info.joints).split("\n", false)
	var nj := int(info.njoints)
	var xf: PackedFloat32Array = _sb.vmcall("usd_skel_anim_transforms", a)
	var to_path := "%s:" % str(root.get_path_to(node))
	for j in nj:
		var bone: int = sk.paths.find(joints[j]) if j < joints.size() else -1
		if bone < 0:
			continue
		var bn := node.get_bone_name(bone)
		var tp := anim.add_track(Animation.TYPE_POSITION_3D)
		var tr := anim.add_track(Animation.TYPE_ROTATION_3D)
		var ts := anim.add_track(Animation.TYPE_SCALE_3D)
		for tk in [tp, tr, ts]:
			anim.track_set_path(tk, to_path + bn)
		for f in frames:
			var t := (float(times[f]) - t0) / fps if f < times.size() else f / fps
			var x := _xf12(xf, f * nj + j)
			if sk.parents[bone] < 0:
				x = sk.world * x
			anim.position_track_insert_key(tp, t, x.origin)
			anim.rotation_track_insert_key(tr, t, x.basis.get_rotation_quaternion())
			anim.scale_track_insert_key(ts, t, x.basis.get_scale())
	var ns := int(info.nshapes)
	if ns > 0:
		var wts: PackedFloat32Array = _sb.vmcall("usd_skel_anim_blend_weights", a)
		var names := str(info.blend_shapes).split("\n", false)
		for mi in node.get_children():
			if mi is MeshInstance3D:
				_bake_weights(anim, root, mi, names, wts, ns, frames, times, t0, fps)
	var player := root.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player == null:
		player = AnimationPlayer.new()
		player.name = "AnimationPlayer"
		root.add_child(player)
		player.add_animation_library("", AnimationLibrary.new())
	var lib := player.get_animation_library("")
	var name := str(info.path).get_file().validate_node_name()
	while lib.has_animation(name):
		name += "_"
	lib.add_animation(name, anim)


func _bake_weights(
	anim: Animation,
	root: Node3D,
	mi: MeshInstance3D,
	names: PackedStringArray,
	wts: PackedFloat32Array,
	ns: int,
	frames: int,
	times: PackedStringArray,
	t0: float,
	fps: float
) -> void:
	var recs: Array = mi.mesh.get_meta("usd_shapes", [])
	var mp := str(root.get_path_to(mi))
	for c in ns:
		# The target record and its in-betweens, sorted by position.
		var target := -1
		for r in recs.size():
			if int(recs[r].primary) == -1 and str(recs[r].name) == names[c]:
				target = r
		if target < 0:
			continue
		var group := [[0.0, -1]]
		for r in recs.size():
			if r == target or int(recs[r].primary) == int(recs[target].k):
				group.append([float(recs[r].position), r])
		group.sort_custom(func(x, y): return x[0] < y[0])
		var tracks := {}
		for g in group:
			if g[1] >= 0:
				var tk := anim.add_track(Animation.TYPE_BLEND_SHAPE)
				anim.track_set_path(tk, "%s:%s" % [mp, recs[g[1]].godot])
				tracks[g[1]] = tk
		# USD interpolates the weight linearly between samples and then through the basis, which
		# is linear only between two positions: add a key wherever the weight crosses one.
		var keys := []
		for f in frames:
			var t := (float(times[f]) - t0) / fps if f < times.size() else f / fps
			var w := wts[f * ns + c]
			if not keys.is_empty():
				var a: Array = keys[keys.size() - 1]
				var cross := []
				for g in group:
					var p: float = g[0]
					if (p - a[1]) * (p - w) < 0.0:
						cross.append(a[0] + (t - a[0]) * (p - a[1]) / (w - a[1]))
				cross.sort()
				for ct in cross:
					keys.append([ct, a[1] + (w - a[1]) * (ct - a[0]) / (t - a[0])])
			keys.append([t, w])
		for key in keys:
			var w: float = key[1]
			var seg := 0
			while seg < group.size() - 2 and w > group[seg + 1][0]:
				seg += 1
			var lo: float = group[seg][0]
			var hi: float = group[seg + 1][0]
			var u := (w - lo) / (hi - lo) if hi > lo else 0.0
			for g in range(1, group.size()):
				var val := 0.0
				if g == seg:
					val = 1.0 - u
				elif g == seg + 1:
					val = u
				anim.blend_shape_track_insert_key(tracks[group[g][1]], key[0], val)


func _material(i: int, cache: Dictionary) -> StandardMaterial3D:
	var sm := StandardMaterial3D.new()
	var m = _sb.vmcall("usd_material", i)
	if typeof(m) != TYPE_DICTIONARY:
		return sm
	sm.resource_name = str(m.name)
	var d: PackedFloat32Array = m.diffuse
	sm.albedo_color = Color(d[0], d[1], d[2])
	sm.metallic = float(m.metallic)
	sm.roughness = float(m.roughness)
	var albedo := _texture(m, "diffuse", cache)
	if albedo:
		sm.albedo_texture = albedo
		sm.albedo_color = Color.WHITE
	var metal := _texture(m, "metallic", cache)
	if metal:
		sm.metallic = 1.0
		sm.metallic_texture = metal
		sm.metallic_texture_channel = _channel(str(m.metallic_channel))
	var rough := _texture(m, "roughness", cache)
	if rough:
		sm.roughness = 1.0
		sm.roughness_texture = rough
		sm.roughness_texture_channel = _channel(str(m.roughness_channel))
	var normal := _texture(m, "normal", cache)
	if normal:
		sm.normal_enabled = true
		sm.normal_texture = normal
	var opacity := float(m.opacity)
	if opacity < 1.0 or int(m.opacity_texture) >= 0:
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.albedo_color.a = opacity
	return sm


func _texture(m: Dictionary, key: String, cache: Dictionary) -> ImageTexture:
	var t := int(m.get(key + "_texture", -1))
	if t < 0:
		return null
	if cache.has(t):
		return cache[t]
	var info = _sb.vmcall("usd_texture_info", t)
	var bytes := PackedByteArray()
	if typeof(info) == TYPE_DICTIONARY:
		var size := int(info.size)
		while bytes.size() < size:
			var r = _sb.vmcall(
				"usd_texture_slice", t, bytes.size(), mini(CHUNK, size - bytes.size())
			)
			if typeof(r) != TYPE_PACKED_BYTE_ARRAY or r.is_empty():
				break
			bytes.append_array(r)
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes.size() > 4:
		if bytes[0] == 0x89 and bytes[1] == 0x50:
			err = img.load_png_from_buffer(bytes)
		elif bytes[0] == 0xFF and bytes[1] == 0xD8:
			err = img.load_jpg_from_buffer(bytes)
		elif bytes[0] == 0x52 and bytes[1] == 0x49:
			err = img.load_webp_from_buffer(bytes)
	var tex: ImageTexture = ImageTexture.create_from_image(img) if err == OK else null
	cache[t] = tex
	return tex


static func _channel(c: String) -> int:
	match c:
		"r":
			return BaseMaterial3D.TEXTURE_CHANNEL_RED
		"g":
			return BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		"b":
			return BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		"a":
			return BaseMaterial3D.TEXTURE_CHANNEL_ALPHA
	return BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE


# GfMatrix4d, row-vector: row i is the image of axis i, row 3 the origin.
static func _xf16(x: PackedFloat32Array) -> Transform3D:
	if x.size() != 16:
		return Transform3D.IDENTITY
	var b := Basis(Vector3(x[0], x[1], x[2]), Vector3(x[4], x[5], x[6]), Vector3(x[8], x[9], x[10]))
	return Transform3D(b, Vector3(x[12], x[13], x[14]))


# 12 floats at item j: row-major 3x3 in the column-vector convention, then the translation.
static func _xf12(x: PackedFloat32Array, j: int) -> Transform3D:
	var o := 12 * j
	if x.size() < o + 12:
		return Transform3D.IDENTITY
	var b := Basis(
		Vector3(x[o], x[o + 3], x[o + 6]),
		Vector3(x[o + 1], x[o + 4], x[o + 7]),
		Vector3(x[o + 2], x[o + 5], x[o + 8])
	)
	return Transform3D(b, Vector3(x[o + 9], x[o + 10], x[o + 11]))


static func _pick3(a: PackedVector3Array, order: PackedInt32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(order.size())
	for o in order.size():
		out[o] = a[order[o]]
	return out


static func _unique(n: String, used: Dictionary) -> String:
	var base := n if n != "" else "item"
	var out := base
	var k := 1
	while used.has(out):
		out = "%s_%d" % [base, k]
		k += 1
	used[out] = true
	return out


static func _field(line: String, key: String, def: String) -> String:
	var at := line.find(" %s=" % key)
	if at < 0:
		return def
	var v := line.substr(at + key.length() + 2)
	var sp := v.find(" ")
	return v if sp < 0 else v.substr(0, sp)


func _floats(fn: String, i: int, n: int, stride: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for at in range(0, n, SLICE):
		var r = _sb.vmcall(fn, i, at, mini(SLICE, n - at))
		if typeof(r) != TYPE_PACKED_FLOAT32_ARRAY:
			push_warning("usd: %s(%d) -> %s" % [fn, i, str(r).left(200)])
			return PackedFloat32Array()
		out.append_array(r)
	return out


func _ints(fn: String, i: int, n: int, stride: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for at in range(0, n, SLICE):
		var r = _sb.vmcall(fn, i, at, mini(SLICE, n - at))
		if typeof(r) != TYPE_PACKED_INT32_ARRAY:
			push_warning("usd: %s(%d) -> %s" % [fn, i, str(r).left(200)])
			return PackedInt32Array()
		out.append_array(r)
	return out


func _fail(text: String) -> Node3D:
	why = text
	printerr("USD-FAIL ", text)
	return null


func _close(ret):
	if _sb:
		if _sb.has_function("usd_close"):
			_sb.vmcall("usd_close")
		# Freed now, not at the end of the frame: on the web the next guest arena needs the memory.
		remove_child(_sb)
		_sb.free()
		_sb = null
	return ret
