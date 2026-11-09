extends SceneTree
# Check of the OpenUSD input (UsdImport.gd) against OpenUSD itself, inside usd.elf:
#   godot --headless --path <project with usd.elf and the sandbox add-on> -s res://tools/usd_check.gd \
#     -- <abs file.usd*> [more files] [--plant]
# For each file: convert to GLB, read the GLB back with GLTFDocument, then
#  1. counts: triangles, bones, blend shapes and clips of the GLB equal the guest's tables;
#  2. skinning: each skinned vertex, posed through the GLB's skeleton and binds, equals OpenUSD's
#     own linear blend skinning (usd_mesh_skin_pose) of the same pose, within TOL metres. The pose
#     is the rest pose with every joint turned 0.3 rad about a different axis.
# --plant moves one bind by 1 cm before the check, which must then FAIL (the control).
# Prints CHECK-OK / CHECK-FAIL per file and RESULT: PASS / FAIL.

const UsdImport = preload("res://vsk_model_explorer/core/UsdImport.gd")
# Godot keeps skin weights as 16-bit fractions (steps of 1/65535): on a 3 m model that alone moves
# a vertex by up to about 1e-4 m, so the bound is half a millimetre.
const TOL := 5e-4

var plant := false


func _initialize() -> void:
	var files := []
	for a in OS.get_cmdline_user_args():
		if a == "--plant":
			plant = true
		else:
			files.append(a)
	_run.call_deferred(files)


func _run(files: Array) -> void:
	var ok := not files.is_empty()
	for f in files:
		var r := await _check(f)
		print(("CHECK-OK " if r == "" else "CHECK-FAIL ") + f + (" " + r if r != "" else ""))
		ok = ok and r == ""
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _check(path: String) -> String:
	var imp := UsdImport.new()
	root.add_child(imp)
	var out := OS.get_user_data_dir().path_join(
		"usd_check_" + path.get_file().get_basename() + ".glb"
	)
	var why := imp.to_glb(path, out)
	if why != "":
		return why
	await process_frame
	# The guest's own tables, from a fresh document.
	var sb: Node = ClassDB.instantiate("Sandbox")
	sb.memory_max = 2048
	sb.references_max = 4096
	sb.allocations_max = 10000000
	sb.execution_timeout = 0
	root.add_child(sb)
	sb.load_buffer(FileAccess.get_file_as_bytes(UsdImport.ELF))
	sb.vmcall("usd_init")
	var bytes := FileAccess.get_file_as_bytes(path)
	for at in range(0, bytes.size(), UsdImport.CHUNK):
		sb.vmcall("usd_push", bytes.slice(at, at + UsdImport.CHUNK))
	var line := str(sb.vmcall("usd_open_staged"))
	var tris := 0
	var meshes := int(sb.vmcall("usd_mesh_count"))
	for i in meshes:
		tris += int(sb.vmcall("usd_mesh_info", i).triangles)
	var bones := 0
	for s in int(sb.vmcall("usd_skeleton_count")):
		bones += int(sb.vmcall("usd_skeleton_info", s).njoints)
	var shapes := int(sb.vmcall("usd_blend_shape_count"))
	var clips := 0
	for a in int(sb.vmcall("usd_skel_anim_count")):
		if int(sb.vmcall("usd_skel_anim_info", a).frames) > 0:
			clips += 1
	# The GLB, read back.
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(out, st) != OK:
		return "the GLB does not read back"
	var scene := doc.generate_scene(st) as Node3D
	root.add_child(scene)
	await process_frame
	var g_tris := 0
	var g_bones := 0
	var g_shapes := 0
	var g_clips := 0
	var mis := []
	for n in scene.find_children("*", "", true, false):
		if n is MeshInstance3D:
			mis.append(n)
			for sfc in n.mesh.get_surface_count():
				g_tris += n.mesh.surface_get_arrays(sfc)[Mesh.ARRAY_INDEX].size() / 3
			g_shapes += n.mesh.get_blend_shape_count()
		elif n is Skeleton3D:
			g_bones += n.get_bone_count()
		elif n is AnimationPlayer:
			for a in n.get_animation_list():
				if a != "RESET":
					g_clips += 1
	var counts := (
		"tris %d/%d bones %d/%d shapes %d/%d clips %d/%d"
		% [g_tris, tris, g_bones, bones, g_shapes, shapes, g_clips, clips]
	)
	print("  ", line.left(160))
	print("  ", counts)
	var bad := ""
	if g_tris != tris or g_bones != bones or g_shapes != shapes or g_clips != clips:
		bad = "counts differ: " + counts
	# Skinning against OpenUSD.
	var worst := 0.0
	var checked := 0
	for i in meshes:
		var info: Dictionary = sb.vmcall("usd_mesh_info", i)
		var s := int(info.skeleton)
		if s < 0 or typeof(sb.vmcall("usd_mesh_skin", i)) != TYPE_DICTIONARY:
			continue
		var sk_info: Dictionary = sb.vmcall("usd_skeleton_info", s)
		var skd: Dictionary = sb.vmcall("usd_mesh_skin", i)
		print(
			(
				"  mesh %s: %d weights a vertex (most non-zero %d)"
				% [info.name, skd.element_size, skd.max_nonzero]
			)
		)
		var nj := int(sk_info.njoints)
		var rests: PackedFloat32Array = sb.vmcall("usd_skeleton_rests", s)
		var mi: MeshInstance3D = null
		for m in mis:
			if m.name == str(info.name).validate_node_name():
				mi = m
		if mi == null or mi.skin == null:
			bad = "no skinned mesh %s in the GLB" % info.name
			continue
		var sk := mi.get_node(mi.skeleton) as Skeleton3D
		var names := str(sk_info.names).split("\n", false)
		var world := UsdImport._xf16(sk_info.xform)
		var angle := float(OS.get_environment("ANGLE")) if OS.has_environment("ANGLE") else 0.3
		var moved := 0
		# The pose is set on the GLB's skeleton first and read back, so that OpenUSD gets exactly
		# the transforms Godot can hold (a bone pose is position, rotation and scale: no shear).
		var pose := PackedFloat32Array()
		for j in nj:
			if not sk.get_bone_name(j).begins_with(names[j].replace(":", "_").replace("/", "_")):
				moved += 1
			var axis := Vector3(sin(j * 1.7), cos(j * 2.3), sin(j * 0.9 + 1.0)).normalized()
			var x := UsdImport._xf12(rests, j)
			if int(sk_info.parents[j]) < 0:
				x = world * x
			x.basis = x.basis * Basis(axis, angle)
			sk.set_bone_pose(j, x)
			var back := sk.get_bone_pose(j)
			if int(sk_info.parents[j]) < 0:
				back = world.affine_inverse() * back
			var b := back.basis
			pose.append_array(
				[
					b.x.x,
					b.y.x,
					b.z.x,
					b.x.y,
					b.y.y,
					b.z.y,
					b.x.z,
					b.y.z,
					b.z.z,
					back.origin.x,
					back.origin.y,
					back.origin.z
				]
			)
		var want: PackedFloat32Array = sb.vmcall("usd_mesh_skin_pose", i, pose, true)
		if moved:
			print("  bones out of order: ", moved)
		if OS.has_environment("DEBUG"):
			var binds_u: PackedFloat32Array = sb.vmcall("usd_skeleton_binds", s)
			for j in nj:
				if sk.get_bone_parent(j) != int(sk_info.parents[j]):
					print("  parent differs at ", j)
			for b in mi.skin.get_bind_count():
				var j := _bone_of(mi.skin, sk, b)
				var want_b := (
					(UsdImport._xf16(sk_info.xform) * UsdImport._xf12(binds_u, j)).affine_inverse()
				)
				var got := mi.skin.get_bind_pose(b)
				var d := (
					(got.origin - want_b.origin).length()
					+ (got.basis.x - want_b.basis.x).length()
					+ (got.basis.y - want_b.basis.y).length()
				)
				if d > 1e-4:
					print("  bind differs bone %d %s by %f" % [j, sk.get_bone_name(j), d])
		if plant:
			for b in mi.skin.get_bind_count():
				mi.skin.set_bind_pose(b, mi.skin.get_bind_pose(b).translated(Vector3(0.01, 0, 0)))
		# Each GLB vertex, skinned by hand, must sit on some OpenUSD vertex. Match by the rest
		# position: the GLB keeps the guest's per-vertex order only within a surface.
		var by_rest := {}
		var pts: PackedFloat32Array = sb.vmcall("usd_mesh_points", i)
		var gb := (
			UsdImport._xf16(sk_info.xform)
			* UsdImport._xf16(sb.vmcall("usd_mesh_skin", i).geom_bind)
		)
		for v in pts.size() / 3:
			var key := _key(gb * Vector3(pts[3 * v], pts[3 * v + 1], pts[3 * v + 2]))
			if not by_rest.has(key):
				by_rest[key] = []
			by_rest[key].append(v)
		var to_world := scene.global_transform.affine_inverse() * sk.global_transform
		for sfc in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(sfc)
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var bi: PackedInt32Array = arr[Mesh.ARRAY_BONES]
			var bw: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
			var per := bi.size() / vs.size()
			if sfc == 0:
				print("  GLB weights a vertex: ", per)
			for v in vs.size():
				var key := _key(vs[v])
				if not by_rest.has(key):
					continue
				var p := Vector3.ZERO
				for e in per:
					var w := bw[v * per + e]
					if w <= 0.0:
						continue
					var b := bi[v * per + e]
					p += (
						w
						* (
							sk.get_bone_global_pose(_bone_of(mi.skin, sk, b))
							* mi.skin.get_bind_pose(b)
							* vs[v]
						)
					)
				p = to_world * p
				# Vertices may share a rest position with different weights: take the closest.
				var q := Vector3.INF
				for u in by_rest[key]:
					var c := Vector3(want[3 * u], want[3 * u + 1], want[3 * u + 2])
					if q == Vector3.INF or p.distance_to(c) < p.distance_to(q):
						q = c
				if checked == 0 and OS.has_environment("DEBUG"):
					print("  v=", vs[v], " godot=", p, " usd=", q)
				if (
					OS.has_environment("DEBUG")
					and p.distance_to(q) > TOL
					and p.distance_to(q) > worst
				):
					var dbg := []
					for e in per:
						dbg.append(
							"%d:%.5f" % [_bone_of(mi.skin, sk, bi[v * per + e]), bw[v * per + e]]
						)
					var uw: PackedFloat32Array = sb.vmcall("usd_mesh_skin_weights", i)
					var ui: PackedInt32Array = sb.vmcall("usd_mesh_skin_indices", i)
					var es := int(skd.element_size)
					for u in by_rest[key]:
						var ud := []
						for e in es:
							ud.append("%d:%.5f" % [ui[u * es + e], uw[u * es + e]])
						dbg.append(ud)
					print("  far v=", vs[v], " d=", p.distance_to(q), " glb/usd=", dbg)
				worst = maxf(worst, p.distance_to(q))
				checked += 1
	# Blend shapes: each GLB shape's offsets equal OpenUSD's (in skeleton space).
	var shape_worst := 0.0
	var shape_checked := 0
	for k in shapes:
		var b: Dictionary = sb.vmcall("usd_blend_shape_info", k)
		var i := int(b.mesh)
		var info: Dictionary = sb.vmcall("usd_mesh_info", i)
		var mi: MeshInstance3D = null
		for m in mis:
			if m.name == str(info.name).validate_node_name():
				mi = m
		if mi == null:
			bad = "no mesh %s for blend shape %s" % [info.name, b.name]
			continue
		var gidx := -1
		for g in mi.mesh.get_blend_shape_count():
			if str(mi.mesh.get_blend_shape_name(g)) == str(b.name).replace(":", "_"):
				gidx = g
		if gidx < 0:
			bad = "blend shape %s missing in the GLB" % b.name
			continue
		var n := int(info.points)
		var off: PackedFloat32Array = sb.vmcall("usd_blend_shape_offsets_slice", k, 0, n)
		var pts: PackedFloat32Array = sb.vmcall("usd_mesh_points", i)
		var bake := Transform3D.IDENTITY
		var skd = sb.vmcall("usd_mesh_skin", i)
		if int(info.skeleton) >= 0 and typeof(skd) == TYPE_DICTIONARY:
			bake = (
				UsdImport._xf16(sb.vmcall("usd_skeleton_info", int(info.skeleton)).xform)
				* UsdImport._xf16(skd.geom_bind)
			)
		var by_rest := {}
		for v in n:
			var key := _key(bake * Vector3(pts[3 * v], pts[3 * v + 1], pts[3 * v + 2]))
			if not by_rest.has(key):
				by_rest[key] = []
			by_rest[key].append(v)
		for sfc in mi.mesh.get_surface_count():
			var base: PackedVector3Array = mi.mesh.surface_get_arrays(sfc)[Mesh.ARRAY_VERTEX]
			var shp: PackedVector3Array = mi.mesh.surface_get_blend_shape_arrays(sfc)[gidx][
				Mesh.ARRAY_VERTEX
			]
			for v in base.size():
				var key := _key(base[v])
				if not by_rest.has(key):
					continue
				var got := shp[v] - base[v]  # the importer's normalized mode: whole positions
				var best := INF
				for u in by_rest[key]:
					var d := bake.basis * Vector3(off[3 * u], off[3 * u + 1], off[3 * u + 2])
					best = minf(best, got.distance_to(d))
				shape_worst = maxf(shape_worst, best)
				shape_checked += 1
	print("  blend-shape vertices checked %d, worst %.7f m" % [shape_checked, shape_worst])
	if shape_worst > TOL:
		bad = "blend shapes differ from OpenUSD by %.7f m" % shape_worst
	# Clip weights with in-betweens: the GLB clip's shape weights, applied to the shapes' offsets,
	# against USD's own rule evaluated here from the guest's tables: the weight runs linearly
	# between its samples, the offsets piecewise linearly through (0, base), (in-between
	# positions, their offsets), (1, the target's).
	var clip_worst := 0.0
	var clip_checked := 0
	var player: AnimationPlayer = null
	for n in scene.find_children("*", "AnimationPlayer", true, false):
		player = n
	for a in int(sb.vmcall("usd_skel_anim_count")):
		var ai: Dictionary = sb.vmcall("usd_skel_anim_info", a)
		if int(ai.nshapes) == 0 or int(ai.frames) == 0 or player == null:
			continue
		var anim := player.get_animation(StringName(str(ai.path).get_file().validate_node_name()))
		if anim == null:
			bad = "clip %s missing in the GLB" % ai.path
			continue
		var fps := float(ai.fps) if float(ai.fps) > 0.0 else 24.0
		var times := str(ai.times).split("\n", false)
		var wts: PackedFloat32Array = sb.vmcall("usd_skel_anim_blend_weights", a)
		var cnames := str(ai.blend_shapes).split("\n", false)
		var ns := int(ai.nshapes)
		for c in ns:
			var target := -1
			var group := []  # [position, record]
			for k in shapes:
				var b: Dictionary = sb.vmcall("usd_blend_shape_info", k)
				if int(b.primary) == -1 and str(b.name) == cnames[c]:
					target = k
			if target < 0:
				continue
			for k in shapes:
				var b: Dictionary = sb.vmcall("usd_blend_shape_info", k)
				if k == target or int(b.primary) == target:
					group.append([float(b.position), k, str(b.name).replace(":", "_")])
			group.sort_custom(func(x, y): return x[0] < y[0])
			var mesh_i := int(sb.vmcall("usd_blend_shape_info", target).mesh)
			var n := int(sb.vmcall("usd_mesh_info", mesh_i).points)
			var offs := []
			for g in group:
				offs.append(sb.vmcall("usd_blend_shape_offsets_slice", g[1], 0, n))
			var t_end := (float(times[times.size() - 1]) - float(times[0])) / fps
			for step in 97:
				var t := t_end * step / 96.0
				# USD's weight at t.
				var w := wts[c]
				for f in range(1, times.size()):
					var ta := (float(times[f - 1]) - float(times[0])) / fps
					var tb := (float(times[f]) - float(times[0])) / fps
					if t >= ta and t <= tb:
						w = lerpf(
							wts[(f - 1) * ns + c],
							wts[f * ns + c],
							(t - ta) / (tb - ta) if tb > ta else 0.0
						)
				# Reference factors per record, then the GLB clip's weights.
				var pos := [0.0]
				for g in group:
					pos.append(g[0])
				var seg := 0
				while seg < pos.size() - 2 and w > pos[seg + 1]:
					seg += 1
				var u: float = (w - pos[seg]) / (pos[seg + 1] - pos[seg])
				for v in n:
					var want := Vector3.ZERO
					var got := Vector3.ZERO
					for gi in group.size():
						var o: PackedFloat32Array = offs[gi]
						var d := Vector3(o[3 * v], o[3 * v + 1], o[3 * v + 2])
						var f := 0.0
						if gi + 1 == seg:
							f = 1.0 - u
						elif gi + 1 == seg + 1:
							f = u
						want += f * d
						var tk := -1
						for k in anim.get_track_count():
							if (
								anim.track_get_type(k) == Animation.TYPE_BLEND_SHAPE
								and str(anim.track_get_path(k)).ends_with(":" + group[gi][2])
							):
								tk = k
						if tk >= 0:
							got += anim.blend_shape_track_interpolate(tk, t) * d
					clip_worst = maxf(clip_worst, got.distance_to(want))
					clip_checked += 1
	print(
		"  clip weight samples checked %d, worst %.7f (offset units)" % [clip_checked, clip_worst]
	)
	if clip_worst > 0.02:
		bad = "clip blend weights differ from OpenUSD's in-between rule by %.7f" % clip_worst
	# Joint clips: at each USD sample, the GLB clip's bone transform equals OpenUSD's.
	var joint_worst := 0.0
	var joint_checked := 0
	var jplayer: AnimationPlayer = null
	for n in scene.find_children("*", "AnimationPlayer", true, false):
		jplayer = n
	for a in int(sb.vmcall("usd_skel_anim_count")):
		var ai: Dictionary = sb.vmcall("usd_skel_anim_info", a)
		if int(ai.frames) == 0 or jplayer == null:
			continue
		var anim := jplayer.get_animation(StringName(str(ai.path).get_file().validate_node_name()))
		if anim == null:
			continue
		var s := -1
		for k in int(sb.vmcall("usd_skeleton_count")):
			if str(sb.vmcall("usd_skeleton_info", k).animation) == str(ai.path):
				s = k
		if s < 0:
			s = 0
		var ski: Dictionary = sb.vmcall("usd_skeleton_info", s)
		var paths := str(ski.joints).split("\n", false)
		var world := UsdImport._xf16(ski.xform)
		var sk: Skeleton3D = null
		for n in scene.find_children("*", "Skeleton3D", true, false):
			sk = n
		var fps := float(ai.fps) if float(ai.fps) > 0.0 else 24.0
		var times := str(ai.times).split("\n", false)
		var joints := str(ai.joints).split("\n", false)
		var nj := int(ai.njoints)
		var xf: PackedFloat32Array = sb.vmcall("usd_skel_anim_transforms", a)
		var frames := int(ai.frames)
		for j in nj:
			var bone := paths.find(joints[j])
			if bone < 0 or sk == null:
				continue
			var tracks := {}
			for k in anim.get_track_count():
				var tp := str(anim.track_get_path(k))
				if tp.ends_with(":" + sk.get_bone_name(bone)):
					tracks[anim.track_get_type(k)] = k
			for f in range(0, frames, maxi(1, frames / 12)):
				var t := (float(times[f]) - float(times[0])) / fps
				var want := UsdImport._xf12(xf, f * nj + j)
				if int(ski.parents[bone]) < 0:
					want = world * want
				var pos: Vector3 = (
					anim.position_track_interpolate(tracks[Animation.TYPE_POSITION_3D], t)
					if tracks.has(Animation.TYPE_POSITION_3D)
					else sk.get_bone_rest(bone).origin
				)
				var rot: Quaternion = (
					anim.rotation_track_interpolate(tracks[Animation.TYPE_ROTATION_3D], t)
					if tracks.has(Animation.TYPE_ROTATION_3D)
					else sk.get_bone_rest(bone).basis.get_rotation_quaternion()
				)
				var scl: Vector3 = (
					anim.scale_track_interpolate(tracks[Animation.TYPE_SCALE_3D], t)
					if tracks.has(Animation.TYPE_SCALE_3D)
					else Vector3.ONE
				)
				var got := Transform3D(Basis(rot).scaled_local(scl), pos)
				var d := (
					got.origin.distance_to(want.origin)
					+ (got.basis.x - want.basis.x).length()
					+ (got.basis.y - want.basis.y).length()
					+ (got.basis.z - want.basis.z).length()
				)
				joint_worst = maxf(joint_worst, d)
				joint_checked += 1
	print("  joint clip samples checked %d, worst %.7f" % [joint_checked, joint_worst])
	if joint_worst > 1e-3:
		bad = "joint clips differ from OpenUSD by %.7f" % joint_worst
	print("  skinned vertices checked %d, worst %.7f m" % [checked, worst])
	if worst > TOL:
		bad = "skinning differs from OpenUSD by %.7f m" % worst
	sb.vmcall("usd_close")
	sb.queue_free()
	scene.queue_free()
	imp.queue_free()
	return bad


# The skeleton bone of skin bind b (a vertex's bone index is a bind index; binds are named or indexed).
static func _bone_of(skin: Skin, sk: Skeleton3D, b: int) -> int:
	var nm := skin.get_bind_name(b)
	return sk.find_bone(nm) if nm != &"" else skin.get_bind_bone(b)


static func _key(v: Vector3) -> String:
	return "%.4f,%.4f,%.4f" % [v.x, v.y, v.z]
