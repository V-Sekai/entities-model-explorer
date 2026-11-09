extends RefCounted
# Exploded view that takes a model apart along the edges its artist made, and no others.
#
# Pieces: every connected shell of the model is one piece, a shell being the triangles that share
# vertices, across all meshes and materials, welded by world position (UV and material seams
# split vertices but are not edges of the shape). Nothing is cut, so every piece edge is an edge
# the artist made: a jacket comes off the body whole, the hair off the head, a shoe off the foot.
# A shell with less than MIN_SHARE of the model's triangles (an eye, a button, one hair card) is
# not a piece of its own: the small shells of one mesh travel together. Copies are static, taken
# at the current pose (skinned meshes through bake_mesh_from_current_skeleton_pose(),
# blend-shaped ones through bake_mesh_from_current_blend_shape_mix()).
#
# Joint cuts, only where the artist made no edges: a skinned shell with at least CUT_SHARE of the
# triangles (a body modelled in one piece) is cut at its skeleton's big branches (legs, arms,
# neck, waist: a branch holding at least BRANCH_SHARE of that shell), like an action figure. Each
# cut is a flat plane across the limb at the joint, square to the limb. No bone names are read.
# Cap, then cut: the shell is first made a closed solid (welded by position, duplicate triangles
# and triangles on an edge three or more share dropped, every hole filled), then Manifold (Godot
# CSG) cuts it with one capping box per part: the box starts at the joint plane and holds that
# part, deepest parts first, each part minus the boxes cut before it. Manifold makes the cut
# faces, so every opening is closed exactly and the original triangles and UVs stay; a cut face
# takes the base colour of the material around its joint. A shell Manifold refuses stays whole.
#
# Layout: piece i has a world-space box (centre c_i, half extents h_i) and a direction v_i out
# from the model centre. Pieces are placed nearest the centre first, larger first on ties; each
# moves along v_i by the smallest amount at which its box is at least `gap` away, on some axis,
# from every box placed before it (so the core stays put and outer pieces move only as far as
# they must). lean/Explode.lean defines that placement over exact rationals and proves
# (layout_sound, separated_disjoint) that no two boxes of a layout share a point, for any pieces,
# directions and order, so no two pieces intersect. `lake exe explode_check` re-checks a layout
# printed by `print_layout()` in exact arithmetic.
#
# The guarantee is for the resting layout; during the short move-out animation pieces may pass
# through each other.

const WIRE_GROUP := "vsk_web_wire"
const GAP := 0.03  # minimum distance between boxes, as a share of the model radius
const MOVE_TIME := 0.35
const MIN_SHARE := 0.01  # a shell with at least this share of the triangles is its own piece
const WELD := 1e-5  # vertices closer than this share of the model size are one vertex
const CUT_SHARE := 0.5  # a skinned shell with at least this share of the triangles gets joint cuts
const BRANCH_SHARE := 0.04  # a skeleton branch with at least this share of that shell is a part
const CAP_COLOR := Color(0.62, 0.6, 0.58)  # cut colour where a material has no base colour
const BOX_PAD := 0.08  # capping boxes reach this share of their part's size past it
# Placement works with a gap slightly above GAP: candidates aim at AIM x gap, a spot counts as
# free at KEEP x gap; float32 rounding (about 1e-7 of the model size) stays far below the margin.
const AIM := 1.002
const KEEP := 1.001
# Compiled guest loops copy the packed arrays they index into guest memory, and the host refuses a
# window over 4096 elements, so large arrays are read through blocks of at most BLOCK elements
# (`_blocks`, read as blocks[i / BLOCK][i % BLOCK]) and built with append only.
const BLOCK := 4092  # a multiple of 3 (triangles) and of 4 (tangents)

var root: Node3D  # holds the piece copies while exploded
var hidden: Array = []  # nodes this script hid, restored by implode()
var centres: Array = []  # world box centres (Vector3)
var halves: Array = []  # world box half extents (Vector3)
var dirs: Array = []  # directions (Vector3)
var pieces: Array = []  # Node3D per piece, holding its MeshInstance3D copies
var moves: Array = []  # how far each piece moves along its direction (float)
var gap := 0.0
var part_of := {}  # piece key -> index into pieces
var part_box: Array = []  # world AABB per piece
var part_depth: Array = []  # joint cuts above the piece (0 for whole shells)
var part_axis: Array = []  # world direction of a cut part's limb (Vector3), or null
var part_joint: Array = []  # world position of a cut part's joint (Vector3), or null
var base_of := {}  # Material -> [base colour image or null, base colour], for cap colours


# Builds the pieces and moves them out. `models` are the loaded model roots; `parent` receives the
# piece root (it must not be inside a model, so the model's own animation does not move pieces).
func explode(models: Array, parent: Node, animate := true) -> void:
	implode()
	root = Node3D.new()
	root.name = "ExplodedPieces"
	parent.add_child(root)
	# [arrays, prim, material, world xform, name, owner id, skeleton or null, dominant bones]
	var surfs: Array = []
	for model in models:
		for m in (model as Node).find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.is_in_group(WIRE_GROUP):
				if mi.visible:
					mi.visible = false
					hidden.append(mi)
				continue
			if mi.mesh == null or not _ancestors_visible(mi, model):
				continue
			_collect(mi, surfs)
			if mi.visible:
				mi.visible = false
				hidden.append(mi)
	if surfs.is_empty():
		return
	_split_shells(surfs)
	if pieces.is_empty():
		return
	for i in pieces.size():
		var box: AABB = part_box[i]
		centres.append(box.get_center())
		halves.append(box.size * 0.5)
	_layout()
	for i in pieces.size():
		var p: Node3D = pieces[i]
		var target: Vector3 = p.global_position + (dirs[i] as Vector3) * float(moves[i])
		if animate:
			(
				p
				. create_tween()
				. tween_property(p, "global_position", target, MOVE_TIME)
				. set_trans(Tween.TRANS_CUBIC)
				. set_ease(Tween.EASE_OUT)
			)
		else:
			p.global_position = target


func implode() -> void:
	for n in hidden:
		if is_instance_valid(n):
			(n as Node3D).visible = true
	hidden.clear()
	if root != null and is_instance_valid(root):
		root.queue_free()
	root = null
	centres.clear()
	halves.clear()
	dirs.clear()
	pieces.clear()
	moves.clear()
	part_of.clear()
	part_box.clear()
	part_depth.clear()
	part_axis.clear()
	part_joint.clear()
	base_of.clear()


func is_exploded() -> bool:
	return root != null


func _ancestors_visible(n: Node, stop: Node) -> bool:
	var p := n.get_parent()
	while p != null and p != stop.get_parent():
		if p is Node3D and not (p as Node3D).visible:
			return false
		p = p.get_parent()
	return true


# Static copies of `mi`'s surfaces at the current pose.
func _collect(mi: MeshInstance3D, surfs: Array) -> void:
	var src: Mesh = mi.mesh
	var sk := _skeleton_of(mi)
	var binds := PackedInt32Array()
	if sk != null:
		binds = _bind_bones(mi, sk)
		src = mi.bake_mesh_from_current_skeleton_pose()
	elif src.get_blend_shape_count() > 0:
		src = mi.bake_mesh_from_current_blend_shape_mix()
	if src == null:
		return
	for s in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(s)
		arrays[Mesh.ARRAY_BONES] = null
		arrays[Mesh.ARRAY_WEIGHTS] = null
		for c in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
			arrays[c] = null
		var nv: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if nv == 0:
			continue
		var dom := PackedInt32Array()
		if sk != null and s < mi.mesh.get_surface_count():
			dom = _dominant_bones(mi.mesh.surface_get_arrays(s), binds)
			if dom.size() != nv:
				dom = PackedInt32Array()
		surfs.append(
			[
				arrays,
				src.surface_get_primitive_type(s),
				mi.get_active_material(s),
				mi.global_transform,
				"%s_%d" % [mi.name, s],
				mi.get_instance_id(),
				sk if not dom.is_empty() else null,
				dom
			]
		)


func _indices(arrays: Array) -> PackedInt32Array:
	var idx := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		idx = arrays[Mesh.ARRAY_INDEX]
	if idx.is_empty():
		for i in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
			idx.append(i)
	return idx


# --- Shells ---------------------------------------------------------------------------------


func _find(up: Dictionary, a: int) -> int:
	var r := a
	while up.has(r):
		r = up[r]
	while up.has(a):  # path compression
		var n: int = up[a]
		up[a] = r
		a = n
	return r


func _union(up: Dictionary, a: int, b: int) -> void:
	var ra := _find(up, a)
	var rb := _find(up, b)
	if ra != rb:
		up[maxi(ra, rb)] = mini(ra, rb)


# Finds the shells of all surfaces together and emits one piece per shell (small shells of one
# mesh together).
func _split_shells(surfs: Array) -> void:
	var box := AABB()
	var first := true
	for e in surfs:
		var sb: AABB = (e[3] as Transform3D) * _surface_aabb(e[0])
		box = sb if first else box.merge(sb)
		first = false
	var q := maxf(box.size.length() * WELD, 1e-9)
	# Weld: one id per distinct world position (rounded to q); per surface, the id of each vertex.
	var weld := {}
	var vid: Array = []  # per surface: blocks of weld ids
	var tris: Array = []  # per surface: blocks of indices (triangles only)
	for e in surfs:
		var xf: Transform3D = e[3]
		var ids := PackedInt32Array()
		for blk in _blocks(e[0][Mesh.ARRAY_VERTEX]):
			for p in blk as PackedVector3Array:
				var w: Vector3 = xf * p
				var key := Vector3i(roundi(w.x / q), roundi(w.y / q), roundi(w.z / q))
				if not weld.has(key):
					weld[key] = weld.size()
				ids.append(weld[key])
		vid.append(_blocks(ids))
		tris.append(_blocks(_indices(e[0])) if int(e[1]) == Mesh.PRIMITIVE_TRIANGLES else [])
	# Union the three corners of every triangle.
	var up := {}
	var total := 0
	for si in surfs.size():
		var vb: Array = vid[si]
		for blk in tris[si]:
			var t := 0
			var ib := blk as PackedInt32Array
			while t + 2 < ib.size():
				var a: int = (vb[ib[t] / BLOCK] as PackedInt32Array)[ib[t] % BLOCK]
				var b: int = (vb[ib[t + 1] / BLOCK] as PackedInt32Array)[ib[t + 1] % BLOCK]
				var c: int = (vb[ib[t + 2] / BLOCK] as PackedInt32Array)[ib[t + 2] % BLOCK]
				_union(up, a, b)
				_union(up, b, c)
				total += 1
				t += 3
	# Triangles per shell.
	var size_of := {}
	var shell_tris: Array = []  # per surface: shell root of each triangle
	for si in surfs.size():
		var vb: Array = vid[si]
		var roots := PackedInt32Array()
		for blk in tris[si]:
			var t := 0
			var ib := blk as PackedInt32Array
			while t + 2 < ib.size():
				var r := _find(up, (vb[ib[t] / BLOCK] as PackedInt32Array)[ib[t] % BLOCK])
				roots.append(r)
				size_of[r] = int(size_of.get(r, 0)) + 1
				t += 3
		shell_tris.append(roots)
	var big := maxf(1.0, MIN_SHARE * float(total))
	# Shells that get joint cuts: skinned, and most of the model.
	var cut_root := {}  # shell root -> Skeleton3D
	for si in surfs.size():
		var e: Array = surfs[si]
		if e[6] == null:
			continue
		for r in shell_tris[si] as PackedInt32Array:
			if float(size_of[r]) >= CUT_SHARE * float(total) and not cut_root.has(r):
				cut_root[r] = e[6]
	var rigs := _rigs(surfs, tris, shell_tris, cut_root)
	var cut_src := {}  # shell root -> [[arrays, material, world xform], ...]
	# Emit: each surface split by piece key; triangles of a cut shell are kept for the cut.
	for si in surfs.size():
		var e: Array = surfs[si]
		if tris[si].is_empty():
			_add(_part("mesh:%d" % e[5]), e[1], e[0], e[2], e[3], e[4])
			continue
		var keys: Array = []
		var local := {}
		var tri_group := PackedInt32Array()
		for r in shell_tris[si] as PackedInt32Array:
			var k := "shell:%d" % r if float(size_of[r]) >= big else "small:%d" % e[5]
			if cut_root.has(r) and rigs.has(cut_root[r]):
				k = "cut:%d" % r
			if not local.has(k):
				local[k] = keys.size()
				keys.append(k)
			tri_group.append(local[k])
		var parts: Array = [e[0]]
		if keys.size() > 1:
			parts = _gather(
				e[0], _blocks(e[0][Mesh.ARRAY_VERTEX]), tris[si], tri_group, keys.size()
			)
		for g in parts.size():
			var k: String = keys[g]
			if k.begins_with("cut:"):
				var r := int(k.trim_prefix("cut:"))
				cut_src[r] = (cut_src.get(r, []) as Array) + [[parts[g], e[2], e[3]]]
				continue
			_add(_part(k), e[1], parts[g], e[2], e[3], "%s_%d" % [e[4], g])
	for r in cut_src:
		_cap_and_cut(cut_src[r], rigs[cut_root[r]], "shell:%d" % r)


# --- Joint cuts -----------------------------------------------------------------------------


func _skeleton_of(mi: MeshInstance3D) -> Skeleton3D:
	if mi.skin == null:
		return null
	return mi.get_node_or_null(mi.skeleton) as Skeleton3D


# Skeleton bone for each skin bind of `mi`.
func _bind_bones(mi: MeshInstance3D, sk: Skeleton3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	for b in mi.skin.get_bind_count():
		var bone := mi.skin.get_bind_bone(b)
		if bone < 0:
			bone = sk.find_bone(mi.skin.get_bind_name(b))
		out.append(bone)
	return out


# Per vertex of one surface, the skeleton bone with the largest weight (-1 if none).
func _dominant_bones(arrays: Array, binds: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	if arrays[Mesh.ARRAY_BONES] == null or arrays[Mesh.ARRAY_WEIGHTS] == null:
		return out
	var nv: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var bones_b := _blocks(arrays[Mesh.ARRAY_BONES])
	var wts_b := _blocks(arrays[Mesh.ARRAY_WEIGHTS])
	var nb: int = (arrays[Mesh.ARRAY_BONES] as PackedInt32Array).size()
	if nv == 0 or nb % nv != 0:
		return out
	var stride: int = nb / nv
	for v in nv:
		var best := -1
		var best_w := -1.0
		for k in stride:
			var i: int = v * stride + k
			var w: float = (wts_b[i / BLOCK] as PackedFloat32Array)[i % BLOCK]
			if w > best_w:
				best_w = w
				best = (bones_b[i / BLOCK] as PackedInt32Array)[i % BLOCK]
		var bone := -1
		if best >= 0 and best < binds.size():
			bone = binds[best]
		out.append(bone)
	return out


# Bones parent first.
func _bone_order(sk: Skeleton3D) -> PackedInt32Array:
	var order := PackedInt32Array(sk.get_parentless_bones())
	var i := 0
	while i < order.size():
		order.append_array(sk.get_bone_children(order[i]))
		i += 1
	return order


func _bone_world(sk: Skeleton3D, bone: int) -> Vector3:
	return sk.global_transform * sk.get_bone_global_pose(bone).origin


# Per skeleton with a cut shell, a rig: {seg, depth, root, parent part, children parts, axis,
# joint, reach}. seg[bone] is the part a bone belongs to (the bone that starts it). A bone starts
# a part when its subtree holds BRANCH_SHARE of the cut shell's skin and its parent has two such
# subtrees. A part's axis runs down its main chain (shoulder to elbow, hip to knee); its joint is
# where the limb's own skin starts: the cut bone's head, or further down the chain past bones that
# are short or hold little skin (a clavicle), so an arm comes off at the shoulder, not the neck.
func _rigs(surfs: Array, tris: Array, shell_tris: Array, cut_root: Dictionary) -> Dictionary:
	var mass := {}
	for si in surfs.size():
		var sk = surfs[si][6]
		if sk == null or not cut_root.values().has(sk):
			continue
		if not mass.has(sk):
			var z := PackedInt32Array()
			z.resize((sk as Skeleton3D).get_bone_count())
			mass[sk] = z
		var m: PackedInt32Array = mass[sk]
		var dom_b := _blocks(surfs[si][7])
		var roots: PackedInt32Array = shell_tris[si]
		var ti := 0
		for blk in tris[si]:
			var ib := blk as PackedInt32Array
			var t := 0
			while t + 2 < ib.size():
				if cut_root.has(roots[ti]):
					for k in 3:
						var bone: int = (dom_b[ib[t + k] / BLOCK] as PackedInt32Array)[
							ib[t + k] % BLOCK
						]
						if bone >= 0 and bone < m.size():
							m[bone] += 1
				ti += 1
				t += 3
		mass[sk] = m
	var out := {}
	for sk in mass:
		var skel := sk as Skeleton3D
		var m: PackedInt32Array = mass[sk]
		var order := _bone_order(skel)
		var sub := m.duplicate()
		var total := 0
		for b in m:
			total += b
		for j in range(order.size() - 1, -1, -1):
			var p := skel.get_bone_parent(order[j])
			if p >= 0:
				sub[p] += sub[order[j]]
		var thr := maxf(1.0, BRANCH_SHARE * float(total))
		var seg := PackedInt32Array()
		seg.resize(skel.get_bone_count())
		var depth := PackedInt32Array()
		depth.resize(skel.get_bone_count())
		var root := -1
		var up := {}  # part -> parent part
		var kids := {}  # part -> child parts
		for b in order:
			var p := skel.get_bone_parent(b)
			var cut := false
			if p >= 0 and float(sub[b]) >= thr:
				var bigs := 0
				for c in skel.get_bone_children(p):
					if float(sub[c]) >= thr:
						bigs += 1
				cut = bigs >= 2
			if p < 0:
				seg[b] = b
				if root < 0 or sub[b] > sub[root]:
					root = b
				kids[b] = []
			elif cut:
				seg[b] = b
				depth[b] = depth[p] + 1
				up[b] = seg[p]
				kids[b] = []
				(kids[seg[p]] as Array).append(b)
			else:
				seg[b] = seg[p]
				depth[b] = depth[p]
		var axis := {}
		var joint := {}
		for c in up:
			var chain: Array = [c]
			var half := 0.5 * float(sub[c])
			while true:
				var next := -1
				for k in skel.get_bone_children(chain[chain.size() - 1]):
					if seg[k] == c and float(sub[k]) >= half and (next < 0 or sub[k] > sub[next]):
						next = k
				if next < 0:
					break
				chain.append(next)
			var j0 := _bone_world(skel, c)
			var a := _bone_world(skel, chain[chain.size() - 1]) - j0
			if a.length() <= 1e-9:
				a = j0 - _bone_world(skel, skel.get_bone_parent(c))
			if a.length() <= 1e-9:
				continue
			# Move the joint one bone down the chain when the first bone is short or holds almost
			# none of the part's skin (a clavicle, a shoulder bone rooted inside the chest).
			var j := j0
			var at := 0
			var full := a.length()
			while at < 1 and at + 2 < chain.size():
				var bone_len := (
					(_bone_world(skel, chain[at + 1]) - _bone_world(skel, chain[at])).length()
				)
				if bone_len >= 0.25 * full and float(m[chain[at]]) >= 0.05 * float(sub[c]):
					break
				at += 1
			if at > 0:
				j = _bone_world(skel, chain[at])
				a = _bone_world(skel, chain[chain.size() - 1]) - j
			if a.length() <= 1e-9:
				continue
			axis[c] = a.normalized()
			joint[c] = j
		out[sk] = {
			"id": skel.get_instance_id(),
			"seg": seg,
			"depth": depth,
			"root": root,
			"up": up,
			"kids": kids,
			"axis": axis,
			"joint": joint,
			"reach": {},
		}
	# How far from its limb line a part and everything below it reaches: a body point beyond a joint plane joins that part
	# only within this distance of the limb, so the far side of the body is never taken.
	for si in surfs.size():
		var sk = surfs[si][6]
		if sk == null or not out.has(sk):
			continue
		var rig: Dictionary = out[sk]
		var xf: Transform3D = surfs[si][3]
		var pos_b := _blocks(surfs[si][0][Mesh.ARRAY_VERTEX])
		var dom_b := _blocks(surfs[si][7])
		var reach: Dictionary = rig["reach"]
		for b in pos_b.size():
			var pb := pos_b[b] as PackedVector3Array
			var db := dom_b[b] as PackedInt32Array
			for o in pb.size():
				var bone: int = db[o]
				if bone < 0:
					continue
				# The point counts toward its part and every part above it, so a part's reach
				# covers its whole branch (the spine's reach includes the arms).
				var part: int = (rig["seg"] as PackedInt32Array)[bone]
				var x: Vector3 = xf * pb[o]
				while part >= 0:
					if rig["axis"].has(part):
						reach[part] = maxf(float(reach.get(part, 0.0)), _lateral(x, rig, part))
					part = rig["up"].get(part, -1)
	return out


func _lateral(x: Vector3, rig: Dictionary, part: int) -> float:
	var n: Vector3 = rig["axis"][part]
	var d: Vector3 = x - (rig["joint"][part] as Vector3)
	return (d - n * d.dot(n)).length()


# The part a body point at world position x belongs to, by the planes alone: start at the root
# part and step into the nearest child part whose joint plane the point is beyond (and within
# that part's reach), until there is none. The same planes split the triangles, so the parts
# meet exactly on the cut.
func _label(x: Vector3, rig: Dictionary) -> int:
	var axis: Dictionary = rig["axis"]
	var joint: Dictionary = rig["joint"]
	var part: int = rig["root"]
	while true:
		var best := -1
		var best_d := INF
		for c in rig["kids"].get(part, []):
			if not axis.has(c):
				continue
			if (x - (joint[c] as Vector3)).dot(axis[c]) <= 0.0:
				continue
			if _lateral(x, rig, c) > 1.1 * float(rig["reach"].get(c, 0.0)):
				continue
			var d := x.distance_to(joint[c])
			if d < best_d:
				best_d = d
				best = c
		if best < 0:
			break
		part = best
	return part


func _cut_key(rig: Dictionary, part: int) -> String:
	return "cut:%d:%d" % [rig["id"], part]


func _cut_part(rig: Dictionary, part: int) -> int:
	return _part(
		_cut_key(rig, part),
		(rig["depth"] as PackedInt32Array)[part],
		rig["axis"].get(part, null),
		rig["joint"].get(part, null)
	)


# Cap, then cut, one shell. `src` holds [surface arrays, material, world xform] per surface.
func _cap_and_cut(src: Array, rig: Dictionary, whole_key: String) -> void:
	# World positions and UVs, one list over all surfaces; triangles per surface.
	var pos: Array = []
	var uv: Array = []
	var mat_of: Array = []  # per vertex: its surface
	var tris: Array = []  # per surface: PackedInt32Array into pos
	for si in src.size():
		var arrays: Array = src[si][0]
		var xf: Transform3D = src[si][2]
		var base := pos.size()
		var has_uv: bool = arrays[Mesh.ARRAY_TEX_UV] != null
		for blk in _blocks(arrays[Mesh.ARRAY_VERTEX]):
			for p in blk as PackedVector3Array:
				pos.append(xf * p)
				mat_of.append(si)
		if has_uv:
			for blk in _blocks(arrays[Mesh.ARRAY_TEX_UV]):
				for t in blk as PackedVector2Array:
					uv.append(t)
		else:
			for i in pos.size() - base:
				uv.append(Vector2.ZERO)
		var ix := PackedInt32Array()
		for blk in _blocks(_indices(arrays)):
			for v in blk as PackedInt32Array:
				ix.append(base + v)
		tris.append(ix)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for p in pos:
		lo = lo.min(p)
		hi = hi.max(p)
	var size := (hi - lo).length()
	var q := maxf(size * WELD, 1e-9)
	var weld := {}
	var w: Array = []
	for p in pos:
		var key := Vector3i(roundi(p.x / q), roundi(p.y / q), roundi(p.z / q))
		if not weld.has(key):
			weld[key] = weld.size()
		w.append(weld[key])
	# Repair: drop degenerate and duplicate triangles, then triangles on an edge three or more
	# triangles share, until every edge has one or two.
	var keep: Array = []  # [surface, a, b, c]
	var seen := {}
	for si in tris.size():
		for blk in _blocks(tris[si]):
			var ib := blk as PackedInt32Array
			var t := 0
			while t + 2 < ib.size():
				var a: int = ib[t]
				var b: int = ib[t + 1]
				var c: int = ib[t + 2]
				t += 3
				var s3 := [w[a], w[b], w[c]]
				if s3[0] == s3[1] or s3[1] == s3[2] or s3[0] == s3[2]:
					continue
				s3.sort()
				var tk := Vector3i(s3[0], s3[1], s3[2])
				if seen.has(tk):
					continue
				seen[tk] = true
				keep.append([si, a, b, c])
	var uses := {}
	for pass_i in 8:
		uses = {}
		for k in keep:
			for e in 3:
				var ek := _edge_key(w[k[1 + e]], w[k[1 + (e + 1) % 3]])
				uses[ek] = int(uses.get(ek, 0)) + 1
		var k2: Array = []
		for k in keep:
			var ok := true
			for e in 3:
				if int(uses[_edge_key(w[k[1 + e]], w[k[1 + (e + 1) % 3]])]) > 2:
					ok = false
			if ok:
				k2.append(k)
		if k2.size() == keep.size():
			break
		keep = k2
	# Cap: walk the boundary edges (edges one triangle uses) into loops and fill each with a fan.
	var outs := {}  # welded a -> [welded b]
	var at := {}  # welded vertex -> a source vertex
	for k in keep:
		for e in 3:
			var ia: int = k[1 + e]
			var ib: int = k[1 + (e + 1) % 3]
			if int(uses[_edge_key(w[ia], w[ib])]) == 1:
				outs[w[ia]] = (outs.get(w[ia], []) as Array) + [w[ib]]
				at[w[ia]] = ia
				at[w[ib]] = ib
	var fill := PackedVector3Array()
	var fill_col := Color(0, 0, 0, 0)
	var fill_n := 0
	for start in outs.keys():
		while not (outs[start] as Array).is_empty():
			var loop: Array = [start]
			var cur = (outs[start] as Array).pop_back()
			while cur != start:
				loop.append(cur)
				var nx: Array = outs.get(cur, [])
				if nx.is_empty():
					break
				cur = nx.pop_back()
			if cur != start or loop.size() < 3:
				continue
			var c := Vector3.ZERO
			for v in loop:
				c += pos[at[v]]
				fill_col += _base_uv(src[mat_of[at[v]]][1], uv[at[v]])
				fill_n += 1
			c /= float(loop.size())
			# The boundary runs a -> b in the shell's winding; the fill runs the other way.
			for i in loop.size():
				fill.append(c)
				fill.append(pos[at[loop[(i + 1) % loop.size()]]])
				fill.append(pos[at[loop[i]]])
	# The closed shell as one mesh, world space: a surface per source surface, then the fill.
	var am := ArrayMesh.new()
	for si in src.size():
		var p := PackedVector3Array()
		var t2 := PackedVector2Array()
		for k in keep:
			if k[0] != si:
				continue
			for e in 3:
				p.append(pos[k[1 + e]])
				t2.append(uv[k[1 + e]])
		if p.is_empty():
			continue
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = p
		a[Mesh.ARRAY_TEX_UV] = t2
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		am.surface_set_material(am.get_surface_count() - 1, src[si][1])
	if not fill.is_empty():
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = fill
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		am.surface_set_material(am.get_surface_count() - 1, _flat(fill_col, fill_n))
	# One capping box per cut part, in the limb's frame: from the joint plane out, around every
	# vertex the planes give that part.
	var frames := {}  # part -> [basis, lo, hi]
	var near := {}  # part -> [colour sum, count] of vertices near its joint plane
	var labelled := {}
	for v in pos.size():
		if labelled.has(w[v]):
			continue
		labelled[w[v]] = true
		var x: Vector3 = pos[v]
		var part := _label(x, rig)
		if rig["axis"].has(part):
			if not frames.has(part):
				var n: Vector3 = rig["axis"][part]
				var up := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
				var bx := up.cross(n).normalized()
				frames[part] = [
					Basis(bx, n.cross(bx), n), Vector3(INF, INF, INF), -Vector3(INF, INF, INF)
				]
			var f: Array = frames[part]
			var bs: Basis = f[0]
			var l: Vector3 = bs.transposed() * (x - (rig["joint"][part] as Vector3))
			f[1] = (f[1] as Vector3).min(l)
			f[2] = (f[2] as Vector3).max(l)
		# Colour of the cut: the material around each joint plane.
		for c in rig["axis"]:
			var d: float = (x - (rig["joint"][c] as Vector3)).dot(rig["axis"][c])
			if absf(d) < 0.03 * size and x.distance_to(rig["joint"][c]) < 0.3 * size:
				var nc: Array = near.get(c, [Color(0, 0, 0, 0), 0])
				nc[0] = (nc[0] as Color) + _base_uv(src[mat_of[v]][1], uv[v])
				nc[1] = int(nc[1]) + 1
				near[c] = nc
	var boxes: Array = []  # [part, Transform3D, size, cut material]
	for part in frames:
		var f: Array = frames[part]
		var l_lo: Vector3 = f[1]
		var l_hi: Vector3 = f[2]
		var pad := BOX_PAD * (l_hi - l_lo).length()
		l_lo -= Vector3(pad, pad, 0.0)
		l_hi += Vector3(pad, pad, pad)
		l_lo.z = 0.0
		var bs: Basis = f[0]
		var centre: Vector3 = (rig["joint"][part] as Vector3) + bs * ((l_lo + l_hi) * 0.5)
		var nc: Array = near.get(part, [Color(0, 0, 0, 0), 0])
		# Sibling parts (two legs on the hips, two arms on the chest) are also split by the plane
		# halfway between their joints, so one part's box never takes its sibling.
		var halves_of: Array = []
		var up_part: int = rig["up"].get(part, -1)
		for sib in rig["kids"].get(up_part, []):
			if sib == part or not rig["joint"].has(sib):
				continue
			var jc: Vector3 = rig["joint"][part]
			var js: Vector3 = rig["joint"][sib]
			if jc.distance_to(js) > 1e-9:
				halves_of.append([(jc + js) * 0.5, (jc - js).normalized()])
		boxes.append([part, Transform3D(bs, centre), l_hi - l_lo, _flat(nc[0], nc[1]), halves_of])
	boxes.sort_custom(
		func(a, b):
			return (
				(rig["depth"] as PackedInt32Array)[a[0]] > (rig["depth"] as PackedInt32Array)[b[0]]
			)
	)
	# Cut: each part is the closed shell inside its box minus the boxes cut before it; the root
	# part is the shell minus every box.
	var made: Array = []  # [part, ArrayMesh]
	for bi in boxes.size() + 1:
		var csg := CSGMesh3D.new()
		csg.mesh = am
		if bi < boxes.size():
			csg.add_child(_volume(boxes[bi], CSGShape3D.OPERATION_INTERSECTION, size))
		for bj in boxes.size():
			if bj < bi or bi == boxes.size():
				csg.add_child(_volume(boxes[bj], CSGShape3D.OPERATION_SUBTRACTION, size))
		root.add_child(csg)
		csg.call("_update_shape")
		var baked: ArrayMesh = csg.bake_static_mesh()
		root.remove_child(csg)
		csg.free()
		var part: int = boxes[bi][0] if bi < boxes.size() else int(rig["root"])
		if baked != null and baked.get_surface_count() > 0:
			made.append([part, baked])
	var root_made := false
	for m in made:
		if m[0] == int(rig["root"]):
			root_made = true
	if not root_made:
		# Manifold refused the shell: it stays one piece, uncut.
		push_warning("model_explode: the cut failed, the shell stays whole")
		for e in src:
			_add(_part(whole_key), Mesh.PRIMITIVE_TRIANGLES, e[0], e[1], e[2], "Shell")
		return
	for m in made:
		var pi := _cut_part(rig, m[0])
		var mi := MeshInstance3D.new()
		mi.name = "Cut%d" % m[0]
		mi.mesh = m[1]
		(pieces[pi] as Node3D).add_child(mi)
		mi.global_transform = Transform3D.IDENTITY
		var bb: AABB = (m[1] as ArrayMesh).get_aabb()
		part_box[pi] = bb if part_box[pi] == null else (part_box[pi] as AABB).merge(bb)


func _edge_key(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


# A part's capping volume: its box, cut by the half-spaces toward it from its siblings.
func _volume(b: Array, op: int, size: float) -> CSGShape3D:
	var box := CSGBox3D.new()
	box.size = b[2]
	box.transform = b[1]
	box.material = b[3]
	if (b[4] as Array).is_empty():
		box.operation = op
		return box
	var vol := CSGCombiner3D.new()
	vol.operation = op
	vol.add_child(box)
	for h in b[4]:
		# A cube 4x the model's size whose face lies on the plane, on the part's side.
		var n: Vector3 = h[1]
		var up := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
		var bx := up.cross(n).normalized()
		var half := CSGBox3D.new()
		var big := 4.0 * size
		half.size = Vector3(big, big, big)
		half.transform = Transform3D(Basis(bx, n.cross(bx), n), (h[0] as Vector3) + n * big * 0.5)
		half.operation = CSGShape3D.OPERATION_INTERSECTION
		half.material = b[3]
		vol.add_child(half)
	return vol


# A plain material in the mean of `n` summed colours (CAP_COLOR when n is 0).
func _flat(sum: Color, n: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var c := sum / float(n) if n > 0 else CAP_COLOR
	c.a = 1.0
	m.albedo_color = c
	m.roughness = 0.85
	return m


# The material's base colour at vertex v: its base colour texture at the vertex's UV times its
# base colour, so a cap shows the colour of the skin or cloth it cuts through.
func _base_at(mat: Material, uv: PackedVector2Array, v: int) -> Color:
	return _base_uv(mat, uv[v] if v < uv.size() else Vector2(-1, -1))


func _base_uv(mat: Material, t: Vector2) -> Color:
	if not base_of.has(mat):
		base_of[mat] = _base_of(mat)
	var b: Array = base_of[mat]
	var c: Color = b[1]
	var img := b[0] as Image
	if img != null and t.x >= -0.5:
		var x := clampi(int(fposmod(t.x, 1.0) * img.get_width()), 0, img.get_width() - 1)
		var y := clampi(int(fposmod(t.y, 1.0) * img.get_height()), 0, img.get_height() - 1)
		c *= img.get_pixel(x, y)
	c.a = 1.0
	return c


# [base colour image or null, base colour] of a material: a BaseMaterial3D's albedo, or the first
# colour and texture parameters a shader material names as its base (MToon _Color/_MainTex).
func _base_of(mat: Material) -> Array:
	var col := CAP_COLOR
	var tex: Texture2D = null
	if mat is BaseMaterial3D:
		col = (mat as BaseMaterial3D).albedo_color
		tex = (mat as BaseMaterial3D).albedo_texture
	elif mat is ShaderMaterial and (mat as ShaderMaterial).shader != null:
		var sm := mat as ShaderMaterial
		for u in sm.shader.get_shader_uniform_list():
			var n: String = String(u["name"]).to_lower()
			var val = sm.get_shader_parameter(u["name"])
			var base := (
				n in ["_color", "albedo", "albedo_color", "base_color", "_basecolor"]
				or n.ends_with("color_factor")
			)
			var base_tex := (
				n in ["_maintex", "texture_albedo", "albedo_texture", "base_color_texture"]
				or n.ends_with("basecolortexture")
			)
			if base and val is Color:
				col = val
			elif base_tex and val is Texture2D:
				tex = val
	var img: Image = null
	if tex != null:
		img = tex.get_image()
		if img != null:
			img = img.duplicate()
			if img.is_compressed():
				img.decompress()
			if img.has_mipmaps():
				img.clear_mipmaps()
			# Small copy: the cap only needs the colour around the cut.
			if img.get_width() > 256:
				img.resize(256, maxi(1, img.get_height() * 256 / img.get_width()))
	return [img, col]


# The piece for a key, made on first use; a cut part also has its depth, limb axis and joint.
func _part(key: String, depth := 0, axis = null, joint = null) -> int:
	if part_of.has(key):
		return part_of[key]
	part_depth.append(depth)
	part_axis.append(axis)
	part_joint.append(joint)
	var holder := Node3D.new()
	holder.name = "Piece%d" % pieces.size()
	root.add_child(holder)
	part_of[key] = pieces.size()
	pieces.append(holder)
	part_box.append(null)
	return part_of[key]


# One static mesh copy into piece `pi`, at world transform `xform`.
func _add(pi: int, prim: int, arrays: Array, mat: Material, xform: Transform3D, nm: String) -> void:
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(prim, arrays)
	if am.get_surface_count() == 0:
		return
	if mat != null:
		am.surface_set_material(0, mat)
	var p := MeshInstance3D.new()
	p.name = nm
	p.mesh = am
	(pieces[pi] as Node3D).add_child(p)
	p.global_transform = xform
	var box: AABB = xform * am.get_aabb()
	part_box[pi] = box if part_box[pi] == null else (part_box[pi] as AABB).merge(box)


func _surface_aabb(arrays: Array) -> AABB:
	var bl := _blocks(arrays[Mesh.ARRAY_VERTEX])
	var lo: Vector3 = (bl[0] as PackedVector3Array)[0]
	var hi: Vector3 = lo
	for blk in bl:
		for p in blk as PackedVector3Array:
			lo = lo.min(p)
			hi = hi.max(p)
	return AABB(lo, hi - lo)


func _blocks(arr) -> Array:
	var out := []
	var n: int = arr.size()
	var i := 0
	while i < n:
		out.append(arr.slice(i, mini(i + BLOCK, n)))
		i += BLOCK
	return out


# Builds one surface per group from the triangles whose tri_group entry names it, copying every
# per-vertex array the surface has and renumbering the vertices it uses.
func _gather(
	arrays: Array, pos_b: Array, idx_b: Array, tri_group: PackedInt32Array, ng: int
) -> Array:
	var remap: Array = []
	var verts: Array = []
	var tris: Array = []
	for g in ng:
		remap.append({})
		verts.append([])
		tris.append([])
	var tc_b := _blocks(tri_group)
	var tri_i := 0
	for b in idx_b.size():
		var blk: PackedInt32Array = idx_b[b]
		var t := 0
		while t + 2 < blk.size():
			var g: int = (tc_b[tri_i / BLOCK] as PackedInt32Array)[tri_i % BLOCK]
			var rm: Dictionary = remap[g]
			var vl: Array = verts[g]
			var tl: Array = tris[g]
			for k in 3:
				var v: int = blk[t + k]
				if not rm.has(v):
					rm[v] = vl.size()
					vl.append(v)
				tl.append(rm[v])
			tri_i += 1
			t += 3
	# Gather every per-vertex array the surface has.
	var out: Array = []
	var nrm_b := _blocks(arrays[Mesh.ARRAY_NORMAL]) if arrays[Mesh.ARRAY_NORMAL] != null else []
	var tan_b := _blocks(arrays[Mesh.ARRAY_TANGENT]) if arrays[Mesh.ARRAY_TANGENT] != null else []
	var col_b := _blocks(arrays[Mesh.ARRAY_COLOR]) if arrays[Mesh.ARRAY_COLOR] != null else []
	var uv_b := _blocks(arrays[Mesh.ARRAY_TEX_UV]) if arrays[Mesh.ARRAY_TEX_UV] != null else []
	var uv2_b := _blocks(arrays[Mesh.ARRAY_TEX_UV2]) if arrays[Mesh.ARRAY_TEX_UV2] != null else []
	for g in ng:
		var vl: Array = verts[g]
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		var p := PackedVector3Array()
		var nrm := PackedVector3Array()
		var tan := PackedFloat32Array()
		var col := PackedColorArray()
		var uv := PackedVector2Array()
		var uv2 := PackedVector2Array()
		for v in vl:
			var bi: int = v / BLOCK
			var o: int = v % BLOCK
			p.append((pos_b[bi] as PackedVector3Array)[o])
			if not nrm_b.is_empty():
				nrm.append((nrm_b[bi] as PackedVector3Array)[o])
			if not col_b.is_empty():
				col.append((col_b[bi] as PackedColorArray)[o])
			if not uv_b.is_empty():
				uv.append((uv_b[bi] as PackedVector2Array)[o])
			if not uv2_b.is_empty():
				uv2.append((uv2_b[bi] as PackedVector2Array)[o])
			if not tan_b.is_empty():
				var tv: int = v * 4
				var tb: PackedFloat32Array = tan_b[tv / BLOCK]
				var to: int = tv % BLOCK
				tan.append(tb[to])
				tan.append(tb[to + 1])
				tan.append(tb[to + 2])
				tan.append(tb[to + 3])
		a[Mesh.ARRAY_VERTEX] = p
		if not nrm_b.is_empty():
			a[Mesh.ARRAY_NORMAL] = nrm
		if not tan_b.is_empty():
			a[Mesh.ARRAY_TANGENT] = tan
		if not col_b.is_empty():
			a[Mesh.ARRAY_COLOR] = col
		if not uv_b.is_empty():
			a[Mesh.ARRAY_TEX_UV] = uv
		if not uv2_b.is_empty():
			a[Mesh.ARRAY_TEX_UV2] = uv2
		a[Mesh.ARRAY_INDEX] = PackedInt32Array(tris[g])
		out.append(a)
	return out


# Placement (Explode.layout in lean/Explode.lean): whole shells and the root part first, then cut
# parts by depth, each group nearest the model centre first (larger first on ties); each moves out along its direction by the smallest candidate amount at
# which its box is `gap` away, on some axis, from every box placed before it. Placed pieces never
# move again, so every pair is checked once, when the later one is placed.
func _layout() -> void:
	var all := AABB(centres[0] - halves[0], halves[0] * 2.0)
	for i in centres.size():
		all = all.merge(AABB(centres[i] - halves[i], halves[i] * 2.0))
	var centre := all.get_center()
	var radius := maxf(all.size.length() * 0.5, 1e-6)
	gap = GAP * radius
	var n := centres.size()
	var keys: Array = []
	for i in n:
		var d: float = ((centres[i] as Vector3) - centre).length()
		var hv: Vector3 = halves[i]
		keys.append([part_depth[i], d, -hv.x * hv.y * hv.z, i])
	keys.sort()
	var c2: Array = []
	var h2: Array = []
	var p2: Array = []
	var a2: Array = []
	var j2: Array = []
	for k in keys:
		var i: int = k[3]
		c2.append(centres[i])
		h2.append(halves[i])
		p2.append(pieces[i])
		a2.append(part_axis[i])
		j2.append(part_joint[i])
	centres = c2
	halves = h2
	pieces = p2
	dirs.clear()
	moves.clear()
	var placed: Array = []
	for i in n:
		# A cut part moves along its limb, tilted away from the body's centre line so paired limbs
		# spread apart; a whole shell moves out from the model centre.
		var off: Vector3 = (centres[i] as Vector3) - centre
		if a2[i] != null:
			off = (a2[i] as Vector3).normalized()
			var lat: Vector3 = (j2[i] as Vector3) - centre
			lat -= off * lat.dot(off)
			if lat.length() > 0.02 * radius:
				off += lat.normalized() * 0.5
		var v: Vector3 = (
			off.normalized() * radius
			if off.length() > 1e-6 * radius
			else _spread_dir(i, n) * radius
		)
		dirs.append(v)
		var t := _place(centres[i], halves[i], v, placed)
		moves.append(t)
		placed.append((centres[i] as Vector3) + v * t)


# Smallest candidate t >= 0 at which a box (c, h) moved by t * v is free of every placed box.
func _place(c: Vector3, h: Vector3, v: Vector3, placed: Array) -> float:
	var cands: Array = [0.0]
	for j in placed.size():
		var pc: Vector3 = placed[j]
		var ph: Vector3 = halves[j]
		for k in 3:
			if v[k] == 0.0:
				continue
			var d: float = c[k] - pc[k]
			# Candidates aim at a slightly larger gap than _free() demands, so the float32
			# rounding of positions (Vector3 in a single-precision build) cannot leave a box
			# just inside the gap; the printed and proved gap is `gap` itself.
			var hh: float = ph[k] + h[k] + gap * AIM
			var up := maxf((hh - d) / v[k], (-hh - d) / v[k])
			if up >= 0.0:
				cands.append(up)
	cands.sort()
	for t in cands:
		if _free(c + v * float(t), h, placed):
			return t
	# Not reached in exact arithmetic (the largest candidate is free); keep going outwards.
	push_warning("model_explode: no candidate was free, moving further out")
	var t2: float = cands[cands.size() - 1]
	for tries in 60:
		t2 = t2 * 1.5 + 1e-6
		if _free(c + v * t2, h, placed):
			return t2
	return t2


func _free(c: Vector3, h: Vector3, placed: Array) -> bool:
	for j in placed.size():
		var pc: Vector3 = placed[j]
		var ph: Vector3 = halves[j]
		var apart := false
		for k in 3:
			if absf(c[k] - pc[k]) >= ph[k] + h[k] + gap * KEEP:
				apart = true
				break
		if not apart:
			return false
	return true


# Point i of n on a Fibonacci sphere: well spread unit directions.
func _spread_dir(i: int, n: int) -> Vector3:
	var y := 1.0 - 2.0 * (float(i) + 0.5) / float(maxi(n, 1))
	var r := sqrt(maxf(0.0, 1.0 - y * y))
	var phi := float(i) * 2.399963229728653
	return Vector3(cos(phi) * r, y, sin(phi) * r)


# The layout in the format `lake exe explode_check` reads, one console line each, prefixed
# "EXPLODE " so a test can cut them out of the browser log.
func print_layout() -> void:
	print("EXPLODE gap %.17f" % gap)
	for i in centres.size():
		var c: Vector3 = centres[i]
		var h: Vector3 = halves[i]
		var v: Vector3 = dirs[i]
		print(
			(
				"EXPLODE piece %.17f %.17f %.17f %.17f %.17f %.17f %.17f %.17f %.17f %.17f"
				% [c.x, c.y, c.z, h.x, h.y, h.z, v.x, v.y, v.z, moves[i]]
			)
		)
	print("EXPLODE end %d" % centres.size())
