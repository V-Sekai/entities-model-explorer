extends SceneTree
# Knuckle crease score (RFD 2328). Bends every finger of a humanoid-named rig into a fist and
# scores, per knuckle, the sharpest fold of the skin in degrees per millimetre across a face pair,
# so a coarse and a fine mesh bent alike score alike: lower is rounder.
#   godot --headless --path . --script tools/finger_crease.gd -- <avatar.vrm|.glb> [--rigid] [--json=<out>]
# --rigid moves every vertex wholly onto its largest-weight bone, the control that must score worse.

const SIDES := ["Left", "Right"]
const FINGERS := ["Thumb", "Index", "Middle", "Ring", "Little"]
const BEND := 70.0
const THUMB_BEND := 40.0

var rigid := false
var ply := ""


func _initialize() -> void:
	var path := ""
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a == "--rigid":
			rigid = true
		elif a.begins_with("--ply="):
			ply = a.trim_prefix("--ply=")
		elif a.begins_with("--json="):
			out = a.trim_prefix("--json=")
		else:
			path = a
	var r := score(path)
	if r.has("error"):
		print("CREASE FAIL ", path, ": ", r.error)
		quit(1)
		return
	print(
		(
			"CREASE %s%s mean %.2f deg/mm over %d knuckles, worst %.2f deg/mm at %s, most shrink %.2f mm"
			% [
				path.get_file(),
				" (rigid)" if rigid else "",
				r.mean,
				r.count,
				r.worst,
				r.worst_at,
				r.shrink_mm
			]
		)
	)
	for u in r.unscored:
		print("CREASE UNSCORED ", u)
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify(r, " "))
	quit(0)


func chain(side: String, finger: String) -> Array:
	if finger == "Thumb":
		return [side + "ThumbMetacarpal", side + "ThumbProximal", side + "ThumbDistal"]
	return [side + finger + "Proximal", side + finger + "Intermediate", side + finger + "Distal"]


func score(path: String) -> Dictionary:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		return {"error": "cannot read"}
	var scene: Node = doc.generate_scene(state)
	# A VRM names its humanoid bones in its own table; other files must use the humanoid names.
	var alias := {}
	var vrm: Dictionary = state.json.get("extensions", {}).get("VRMC_vrm", {})
	var gnodes := state.get_nodes()
	for role in vrm.get("humanoid", {}).get("humanBones", {}):
		var node: int = vrm.humanoid.humanBones[role].node
		alias[role[0].to_upper() + role.substr(1)] = String(gnodes[node].resource_name)
	var skel: Skeleton3D
	for s in scene.find_children("*", "Skeleton3D", true, false):
		if s.find_bone(alias.get("LeftIndexProximal", "LeftIndexProximal")) >= 0:
			skel = s
	if skel == null:
		return {"error": "no skeleton with humanoid finger bone names"}
	var n := skel.get_bone_count()
	var rest_g := []
	for b in n:
		rest_g.append(skel.get_bone_global_rest(b))
	var pos := func(name: String) -> Vector3: return rest_g[find_role(skel, alias, name)].origin
	for side in SIDES:
		if find_role(skel, alias, side + "Hand") < 0:
			return {"error": "no bone %sHand" % side}
	# Fist: each finger joint turns about the axis that carries the finger toward the palm.
	var turn := {}  # bone -> global-space rotation about its own joint
	var knuckles := []  # [bone name, joint position, region radius]
	for side in SIDES:
		var hand: Vector3 = pos.call(side + "Hand")
		var mid: Vector3 = pos.call(side + "MiddleProximal")
		var across: Vector3 = pos.call(side + "IndexProximal") - pos.call(side + "LittleProximal")
		var palm := (mid - hand).cross(across).normalized()
		if palm.dot(pos.call(side + "ThumbProximal") - hand) < 0:
			palm = -palm
		for finger in FINGERS:
			var c := chain(side, finger)
			for k in 3:
				if find_role(skel, alias, c[k]) < 0:
					return {"error": "no bone " + c[k]}
			for k in 3:
				var here: Vector3 = pos.call(c[k])
				var dir: Vector3 = (pos.call(c[k + 1]) - here) if k < 2 else (here - pos.call(c[1]))
				var axis := dir.cross(palm).normalized()
				if (Basis(axis, 0.1) * dir - dir).dot(palm) <= 0.0:
					return {"error": "the fist would bend %s away from the palm" % c[k]}
				var angle := deg_to_rad(THUMB_BEND if finger == "Thumb" else BEND)
				turn[find_role(skel, alias, c[k])] = Basis(axis, angle)
				var seg: float = dir.length() * (0.5625 if k == 2 else 1.0)
				knuckles.append([c[k], here, 0.5 * seg, palm])
	# Posed global transforms: a turned bone rotates about its joint, and its children follow.
	var pose_g := []
	pose_g.resize(n)
	# Parents first: bones may be listed before their parents.
	var order := []
	var done := {}
	while order.size() < n:
		for b in n:
			if done.has(b):
				continue
			var p := skel.get_bone_parent(b)
			if p < 0 or done.has(p):
				order.append(b)
				done[b] = true
	for b in order:
		var parent := skel.get_bone_parent(b)
		var local: Transform3D = skel.get_bone_rest(b)
		var g: Transform3D = (pose_g[parent] * local) if parent >= 0 else local
		if turn.has(b):
			g = Transform3D(turn[b] * g.basis, g.origin)
		pose_g[b] = g
	# Skin every hand-region vertex at rest and in the fist.
	var hand_bones := {}
	for side in SIDES:
		hand_bones[find_role(skel, alias, side + "Hand")] = true
		for finger in FINGERS:
			for b in chain(side, finger):
				hand_bones[find_role(skel, alias, b)] = true
	var rest_v := PackedVector3Array()
	var fist_v := PackedVector3Array()
	var tris := PackedInt32Array()
	var weld := {}
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		var skin: Skin = mi.skin
		if mi.mesh == null or skin == null:
			continue
		var bind_bone := []
		for i in skin.get_bind_count():
			var bb := skin.get_bind_bone(i)
			if bb < 0:
				bb = skel.find_bone(skin.get_bind_name(i))
			bind_bone.append(bb)
		for s in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var bones = arr[Mesh.ARRAY_BONES]
			var weights = arr[Mesh.ARRAY_WEIGHTS]
			var idx = arr[Mesh.ARRAY_INDEX]
			if bones == null or weights == null or verts.is_empty():
				continue
			var per: int = bones.size() / verts.size()
			var local_id := PackedInt32Array()
			local_id.resize(verts.size())
			for v in verts.size():
				local_id[v] = -1
				var on_hand := false
				for j in per:
					if weights[v * per + j] > 0.0 and hand_bones.has(bind_bone[bones[v * per + j]]):
						on_hand = true
				if not on_hand:
					continue
				var r := Vector3.ZERO
				var f := Vector3.ZERO
				var best := 0
				for j in per:
					if weights[v * per + j] > weights[v * per + best]:
						best = j
				for j in per:
					var w: float = weights[v * per + j]
					if rigid:
						w = 1.0 if j == best else 0.0
					if w <= 0.0:
						continue
					var bi: int = bones[v * per + j]
					var bb: int = bind_bone[bi]
					var bind: Transform3D = skin.get_bind_pose(bi)
					r += w * ((rest_g[bb] * bind) * verts[v])
					f += w * ((pose_g[bb] * bind) * verts[v])
				var key := Vector3i((r * 1e5).round())
				if weld.has(key):
					local_id[v] = weld[key]
				else:
					weld[key] = rest_v.size()
					local_id[v] = rest_v.size()
					rest_v.append(r)
					fist_v.append(f)
			if idx == null:
				continue
			for t in range(0, idx.size(), 3):
				var a := local_id[idx[t]]
				var b := local_id[idx[t + 1]]
				var c := local_id[idx[t + 2]]
				if a >= 0 and b >= 0 and c >= 0 and a != b and b != c and a != c:
					tris.append_array([a, b, c])
	if tris.is_empty():
		return {"error": "no skinned triangles on the hands"}
	if ply != "":
		write_ply(ply, fist_v, tris)
	# Edge -> the faces on it, for the fold across each interior edge.
	var nt := tris.size() / 3
	var nr := PackedVector3Array()
	var nf := PackedVector3Array()
	var cen := PackedVector3Array()
	for t in nt:
		var a := tris[3 * t]
		var b := tris[3 * t + 1]
		var c := tris[3 * t + 2]
		nr.append((rest_v[b] - rest_v[a]).cross(rest_v[c] - rest_v[a]).normalized())
		nf.append((fist_v[b] - fist_v[a]).cross(fist_v[c] - fist_v[a]).normalized())
		cen.append((rest_v[a] + rest_v[b] + rest_v[c]) / 3.0)
	# Edge -> face pairs. Faces on one surface cross a shared edge in opposite directions; where
	# layers overlap (double-sided copies) each face pairs with its best-aligned opposite.
	var sides := {}
	for t in nt:
		for e in 3:
			var a := tris[3 * t + e]
			var b := tris[3 * t + (e + 1) % 3]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if not sides.has(key):
				sides[key] = [[], []]
			sides[key][0 if a < b else 1].append(t)
	var pairs := []  # [t0, t1]
	var lone := {}  # face -> true, for faces on an edge with no partner
	for key in sides:
		var fwd: Array = sides[key][0]
		var back: Array = sides[key][1]
		for t in fwd:
			var best := -1
			var best_angle := INF
			for u in back:
				var ang: float = nr[t].angle_to(nr[u])
				if ang < best_angle:
					best_angle = ang
					best = u
			if best >= 0:
				pairs.append([t, best])
		if fwd.is_empty() or back.is_empty():
			for t in fwd + back:
				lone[t] = true
	var per_knuckle := {}
	var unscored := []
	var total := 0.0
	var worst := 0.0
	var worst_at := ""
	var shrink := 0.0
	for kn in knuckles:
		var name: String = kn[0]
		var joint: Vector3 = kn[1]
		var d0 := INF
		for v in rest_v.size():
			d0 = minf(d0, rest_v[v].distance_to(joint))
		var radius: float = d0 + kn[2]  # a shell of half a segment over the nearest skin
		var fold := 0.0
		var near := {}
		var paired := 0
		var odd := 0
		for pr in pairs:
			var t0: int = pr[0]
			var t1: int = pr[1]
			if cen[t0].distance_to(joint) > radius or cen[t1].distance_to(joint) > radius:
				continue
			paired += 1
			var dr := rad_to_deg(nr[t0].angle_to(nr[t1]))
			var df := rad_to_deg(nf[t0].angle_to(nf[t1]))
			var span := maxf(cen[t0].distance_to(cen[t1]) * 1000.0, 0.05)
			fold = maxf(fold, (df - dr) / span)
			for t in [t0, t1]:
				for c in 3:
					near[tris[3 * t + c]] = true
		# The skin's distance to the joint, before and after: a fix must not cave the knuckle in.
		var b := find_role(skel, alias, name)
		var joint_fist: Vector3 = pose_g[b].origin
		var rmin := INF
		var fmin := INF
		for v in near:
			rmin = minf(rmin, rest_v[v].distance_to(joint))
			fmin = minf(fmin, fist_v[v].distance_to(joint_fist))
		if near.size() > 0:
			shrink = maxf(shrink, (rmin - fmin) * 1000.0)
		if paired == 0:
			for t in lone:
				if cen[t].distance_to(joint) <= radius:
					odd += 1
			unscored.append("%s (%d faces on open edges)" % [name, odd])
			continue
		per_knuckle[name] = fold
		total += fold
		if fold > worst:
			worst = fold
			worst_at = name
	scene.free()
	if per_knuckle.is_empty():
		return {"error": "no knuckle has skin around it"}
	return {
		"file": path.get_file(),
		"rigid": rigid,
		"mean": total / per_knuckle.size(),
		"count": per_knuckle.size(),
		"unscored": unscored,
		"worst": worst,
		"worst_at": worst_at,
		"shrink_mm": shrink,
		"knuckles": per_knuckle,
		"vertices": rest_v.size(),
		"triangles": nt
	}


# The posed hands as a binary PLY, for a render to check the score against.
func write_ply(path: String, v: PackedVector3Array, t: PackedInt32Array) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	var head := (
		"ply\nformat binary_little_endian 1.0\nelement vertex %d\nproperty float x\nproperty float y\n"
		% v.size()
	)
	head += (
		"property float z\nelement face %d\nproperty list uchar int vertex_indices\nend_header\n"
		% (t.size() / 3)
	)
	f.store_buffer(head.to_ascii_buffer())
	for p in v:
		f.store_float(p.x)
		f.store_float(p.y)
		f.store_float(p.z)
	for i in range(0, t.size(), 3):
		f.store_8(3)
		f.store_32(t[i])
		f.store_32(t[i + 1])
		f.store_32(t[i + 2])


func find_role(skel: Skeleton3D, alias: Dictionary, role: String) -> int:
	return skel.find_bone(alias.get(role, role))
