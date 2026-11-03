extends RefCounted
# Drives the cage guest (cage.elf, V-Sekai-fire/interactor-cage) for one garment shell against a body mesh: build a coarse cage with K knots
# around the shell, push it until it contains every shell vertex, bind the shell to it (biharmonic coordinates), and fit the cage so the
# shell leaves the body by a margin while moving as little as it can. The body never moves; only the shell does.
#
# Steps, as the guest exposes them (each runs in slices of cage_tick and is polled until it reports idle, bound, done or failed):
#   net      cage_net_from_patches(shell, K): cap the open loops, decimate to K knots, inflate until nearly all vertices are inside.
#   contain  the guest's inflate can leave a few vertices outside, so here every vertex with generalized winding < 0.5 pulls the
#            nearest cage triangle outward (1.5 x its distance + 2 mm along the knot normals) until none is outside (80 rounds at most).
#   bind     cage_bind: every shell vertex must have winding 1 in the cage. It fails with "N of M bound vertices lie outside the cage"
#            when the cage self-overlaps or cannot contain the shell: the outcome the knot search probes.
#   fit      cage_body_frames (the body cropped to the shell's box + 10 cm), cage_fit_set, cage_queue_fit: minimise the move with every vertex
#            outside the body by `margin`; the report carries inside_per_pose, below_margin and dmin.
# The guest wants counter-clockwise-outward faces. Shells from the Unity scene dump already wind outward; pass flip_winding = true for the
# FBX-frame islands that wind the other way (a wrong winding gives "bind: inverted: signed volume ... faces must wind outward").
#
# Coroutines: every call that runs the guest is awaited (`await driver.fit(...)`). `yielder` (a Callable that returns something awaitable, for
# example `func(): await get_tree().process_frame`) is awaited between slices so a UI stays alive; with none set the calls block. Turn binary
# translation on (vsk_model_explorer/core/Bintr.gd): on the Maple skirt it made net 3.6x, bind 4.3x and fit 8.3x faster with identical output.

const MEMORY_MB := 2048
const BODY_CROP := 0.10
const CONTAIN_ROUNDS := 80
const NET_CAP_MS := 120000
const BIND_CAP_MS := 900000
const FIT_CAP_MS := 1500000

var sandbox: Object = null
var yielder: Callable = Callable()
var flip_winding := false
# When the net or bind refuses the winding ("inverted ... faces must wind outward"), retry once with the opposite winding. Double-sided cloth has
# no meaningful outward side, so its orientation is whatever makes the cage valid; the result says which one worked (`flipped`).
var auto_orient := true
var margin := 0.002
var log: PackedStringArray = []


# A Sandbox under `parent` with the cage ELF loaded. Returns false when the class or the ELF is missing.
func load_guest(parent: Node, elf: PackedByteArray) -> bool:
	if not ClassDB.class_exists("Sandbox") or elf.is_empty():
		return false
	sandbox = ClassDB.instantiate("Sandbox")
	sandbox.memory_max = MEMORY_MB
	sandbox.references_max = 4096
	sandbox.allocations_max = 1000000
	sandbox.execution_timeout = 300000
	parent.add_child(sandbox)
	sandbox.load_buffer(elf)
	return true


func _flat(v: PackedVector3Array) -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(v.size() * 3)
	for i in v.size():
		f[i * 3] = v[i].x
		f[i * 3 + 1] = v[i].y
		f[i * 3 + 2] = v[i].z
	return f


func _wait(cap_ms: int) -> String:
	var t0 := Time.get_ticks_msec()
	var last := ""
	while Time.get_ticks_msec() - t0 < cap_ms:
		last = str(sandbox.vmcall("cage_tick", float(Time.get_ticks_usec()), 200))
		var st := last.get_slice(" ", 0)
		if st == "state=idle" or st == "state=failed" or st == "state=bound" or st == "state=done" or st.ends_with("_done"):
			break
		if yielder.is_valid():
			await yielder.call()
	return last


# Triangles of the body with a vertex inside the shell's box grown by BODY_CROP; returns {v, t}.
static func crop_body(shell_v: PackedVector3Array, body_v: PackedVector3Array, body_t: PackedInt32Array) -> Dictionary:
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	for p in shell_v:
		lo = lo.min(p)
		hi = hi.max(p)
	lo -= Vector3.ONE * BODY_CROP
	hi += Vector3.ONE * BODY_CROP
	var keep := PackedInt32Array()
	var remap := {}
	var cv := PackedVector3Array()
	for t in body_t.size() / 3:
		var inside := false
		for k in 3:
			var p: Vector3 = body_v[body_t[t * 3 + k]]
			if p.x >= lo.x and p.x <= hi.x and p.y >= lo.y and p.y <= hi.y and p.z >= lo.z and p.z <= hi.z:
				inside = true
		if inside:
			for k in 3:
				var vi: int = body_t[t * 3 + k]
				if not remap.has(vi):
					remap[vi] = cv.size()
					cv.append(body_v[vi])
				keep.append(remap[vi])
	return {"v": cv, "t": keep}


# Weld vertices by position (1 um), as USD and glTF meshes duplicate vertices along UV and normal seams. Returns {v, t, map}: the welded
# vertices, the triangles over them (collapsed ones dropped) and, for every original vertex, its welded index.
static func weld(v: PackedVector3Array, t: PackedInt32Array) -> Dictionary:
	var key := {}
	var map := PackedInt32Array()
	map.resize(v.size())
	var wv := PackedVector3Array()
	for i in v.size():
		var k := Vector3i((v[i] * 1e6).round())
		if not key.has(k):
			key[k] = wv.size()
			wv.append(v[i])
		map[i] = key[k]
	var wt := PackedInt32Array()
	for i in range(0, t.size(), 3):
		var a: int = map[t[i]]
		var b: int = map[t[i + 1]]
		var c: int = map[t[i + 2]]
		if a != b and b != c and a != c:
			wt.append_array([a, b, c])
	return {"v": wv, "t": wt, "map": map}


# Net, containment and bind for one K, on the welded shell. Returns {ok, outside, state, knots, ms, line, error, flipped, map}. `outside` is 0 when
# bound, N when the bind reported N vertices outside the cage, -1 when there was no bind result (the net failed or it timed out). `flipped` is the
# winding that worked; `map` maps every original shell vertex to its welded vertex.
func bind(shell_v: PackedVector3Array, shell_t: PackedInt32Array, knots: int) -> Dictionary:
	var w := weld(shell_v, shell_t)
	var r := await _bind_welded(w["v"], w["t"], knots, flip_winding)
	if not r["ok"] and auto_orient and str(r["line"]).contains("inverted"):
		r = await _bind_welded(w["v"], w["t"], knots, not flip_winding)
	r["map"] = w["map"]
	return r


func _bind_welded(shell_v: PackedVector3Array, shell_t: PackedInt32Array, knots: int, flip: bool) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var gt := shell_t.duplicate()
	if flip:
		for t in gt.size() / 3:
			var tmp := gt[t * 3 + 1]
			gt[t * 3 + 1] = gt[t * 3 + 2]
			gt[t * 3 + 2] = tmp
	var gv := _flat(shell_v)
	sandbox.vmcall("cage_reset")
	var err := str(sandbox.vmcall("cage_net_from_patches", gv, gt, gv, knots))
	var net_line := await _wait(NET_CAP_MS)
	if net_line.contains("state=failed"):
		return {"ok": false, "outside": -1, "state": "net failed", "knots": 0, "ms": Time.get_ticks_msec() - t0, "line": net_line, "error": err, "flipped": flip, "wt": gt, "wv": shell_v}
	var nv = sandbox.vmcall("cage_net_vertices")
	var ct: PackedInt32Array = sandbox.vmcall("cage_net_indices")
	var cage := PackedVector3Array()
	for i in nv.size() / 3:
		cage.append(Vector3(nv[i * 3], nv[i * 3 + 1], nv[i * 3 + 2]))
	cage = _contain(cage, ct, shell_v)
	var counts := PackedInt32Array()
	for t in ct.size() / 3:
		counts.append(3)
	sandbox.vmcall("cage_net_from_mesh", _flat(cage), ct, counts)
	await _wait(NET_CAP_MS)
	sandbox.vmcall("cage_bind", gv, 1)
	var line := await _wait(BIND_CAP_MS)
	var out := -1
	if line.contains("state=bound"):
		out = 0
	elif line.contains("lie outside the cage"):
		var re := RegEx.new()
		re.compile("bind: (\\d+) of")
		var m := re.search(line)
		if m != null:
			out = int(m.get_string(1))
	log.append("bind K=%d%s: %s" % [knots, " (flipped)" if flip else "", line.left(200)])
	return {"ok": out == 0, "outside": out, "state": line.get_slice(" ", 0), "knots": cage.size(), "ms": Time.get_ticks_msec() - t0, "line": line, "error": "", "flipped": flip}


# bind() then the fit. Returns bind()'s dictionary plus, when bound: result (the fitted vertices, one per ORIGINAL shell vertex), report, inside,
# below, dmin, move (mean displacement over the welded vertices, metres), max_move, fit_ms. A shell with no body triangle within BODY_CROP of its
# box is returned unchanged (nothing can clip).
func fit(shell_v: PackedVector3Array, shell_t: PackedInt32Array, body_v: PackedVector3Array, body_t: PackedInt32Array, knots: int) -> Dictionary:
	var r := await bind(shell_v, shell_t, knots)
	if not r["ok"]:
		return r
	var map: PackedInt32Array = r["map"]
	var w := weld(shell_v, shell_t)
	var wv: PackedVector3Array = w["v"]
	var t0 := Time.get_ticks_msec()
	var crop := crop_body(wv, body_v, body_t)
	if (crop["t"] as PackedInt32Array).is_empty():
		r["report"] = "no body triangle within %s m of the shell" % str(BODY_CROP)
		r["fit_ms"] = 0
		r["inside"] = 0
		r["below"] = 0
		r["dmin"] = INF
		r["result"] = PackedVector3Array(shell_v)
		r["move"] = 0.0
		r["max_move"] = 0.0
		return r
	sandbox.vmcall("cage_body_frames", _flat(crop["v"]), crop["t"], 1, PackedFloat32Array([1.0]))
	var n := wv.size()
	var rowptr := PackedInt32Array()
	var col := PackedInt32Array()
	var wt := PackedFloat32Array()
	for i in n + 1:
		rowptr.append(i)
	for i in n:
		col.append(0)
		wt.append(1.0)
	var bones := PackedFloat32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])
	sandbox.vmcall("cage_fit_set", bones, rowptr, col, wt, PackedInt32Array(), "margin %s w_L 0.001 w_r 0.0001" % str(margin))
	sandbox.vmcall("cage_queue_fit")
	await _wait(FIT_CAP_MS)
	var report := str(sandbox.vmcall("cage_report"))
	var y = sandbox.vmcall("cage_result")
	r["report"] = report
	r["fit_ms"] = Time.get_ticks_msec() - t0
	r["inside"] = _key(report, "inside_per_pose", -1)
	r["below"] = _key(report, "below_margin", -1)
	r["dmin"] = _keyf(report, "dmin", NAN)
	if y.size() != n * 3:
		r["ok"] = false
		r["result"] = PackedVector3Array()
		return r
	var fitted := PackedVector3Array()
	var sum := 0.0
	var mx := 0.0
	for i in n:
		fitted.append(Vector3(y[i * 3], y[i * 3 + 1], y[i * 3 + 2]))
		var d := fitted[i].distance_to(wv[i])
		sum += d
		mx = maxf(mx, d)
	var out := PackedVector3Array()
	for i in shell_v.size():
		out.append(fitted[map[i]])
	r["result"] = out
	r["move"] = sum / maxf(n, 1)
	r["max_move"] = mx
	log.append("fit K=%d: %s" % [knots, report.left(200)])
	return r


static func _key(text: String, key: String, fallback: int) -> int:
	var re := RegEx.new()
	re.compile(key + "=(-?\\d+)")
	var m := re.search(text)
	return int(m.get_string(1)) if m != null else fallback


static func _keyf(text: String, key: String, fallback: float) -> float:
	var re := RegEx.new()
	re.compile(key + "=(-?[0-9.eE+-]+)")
	var m := re.search(text)
	return float(m.get_string(1)) if m != null else fallback


# The full search for one shell with the frontier class: probe, refine, fit the candidates, choose. `frontier` is a frontier_knots.gd
# instance and keeps what was learned; `shell` is its key for this shell. Returns {k, reason, fit} (fit is the chosen K's fit dictionary,
# with the fitted vertices) or {k = -1, reason, ...} when no K could be used.
func search(frontier, shell: String, shell_v: PackedVector3Array, shell_t: PackedInt32Array, body_v: PackedVector3Array, body_t: PackedInt32Array) -> Dictionary:
	var tris := shell_t.size() / 3
	for k in frontier.round1(shell, tris):
		var r := await bind(shell_v, shell_t, k)
		frontier.record_bind(shell, tris, k, r["outside"], r["ms"])
	for _round in frontier.REFINE_ROUNDS + 1:
		var more: Array = frontier.refine(shell)
		if more.is_empty():
			break
		for k in more:
			var r := await bind(shell_v, shell_t, k)
			frontier.record_bind(shell, tris, k, r["outside"], r["ms"])
	var fits := {}
	for k in frontier.fit_candidates(shell):
		var f := await fit(shell_v, shell_t, body_v, body_t, k)
		fits[k] = f
		if f.has("result"):
			frontier.record_fit(shell, k, int(f["inside"]), int(f["below"]), float(f["move"]), int(f["fit_ms"]))
		else:
			frontier.record_fit(shell, k, 1 << 20, 1 << 20, 1e9, int(f.get("ms", 0)))
	var c: Dictionary = frontier.choose(shell)
	if c["k"] > 0 and fits.has(c["k"]):
		c["fit"] = fits[c["k"]]
	return c


func _winding(p: Vector3, v: PackedVector3Array, t: PackedInt32Array) -> float:
	var s := 0.0
	for i in t.size() / 3:
		var a := v[t[i * 3]] - p
		var b := v[t[i * 3 + 1]] - p
		var c := v[t[i * 3 + 2]] - p
		var la := a.length()
		var lb := b.length()
		var lc := c.length()
		var num := a.dot(b.cross(c))
		var den := la * lb * lc + a.dot(b) * lc + b.dot(c) * la + c.dot(a) * lb
		s += 2.0 * atan2(num, den)
	return s / (4.0 * PI)


func _outside(v: PackedVector3Array, t: PackedInt32Array, pts: PackedVector3Array) -> Array:
	var o := []
	for i in pts.size():
		if _winding(pts[i], v, t) < 0.5:
			o.append(i)
	return o


func _vertex_normals(v: PackedVector3Array, t: PackedInt32Array) -> PackedVector3Array:
	var n := PackedVector3Array()
	n.resize(v.size())
	for i in t.size() / 3:
		var a: int = t[i * 3]
		var b: int = t[i * 3 + 1]
		var c: int = t[i * 3 + 2]
		var fn := (v[b] - v[a]).cross(v[c] - v[a])
		n[a] += fn
		n[b] += fn
		n[c] += fn
	for i in n.size():
		n[i] = n[i].normalized()
	return n


# Push the cage out until every shell vertex has winding >= 0.5 in it.
func _contain(cage: PackedVector3Array, ct: PackedInt32Array, pts: PackedVector3Array) -> PackedVector3Array:
	var cv := PackedVector3Array(cage)
	for _it in CONTAIN_ROUNDS:
		var outside := _outside(cv, ct, pts)
		if outside.is_empty():
			break
		var vn := _vertex_normals(cv, ct)
		var push := {}
		for vi in outside:
			var best := 1e30
			var best_t := -1
			for t in ct.size() / 3:
				var d := _closest_on_tri(pts[vi], cv[ct[t * 3]], cv[ct[t * 3 + 1]], cv[ct[t * 3 + 2]]).distance_to(pts[vi])
				if d < best:
					best = d
					best_t = t
			for k in 3:
				var kv: int = ct[best_t * 3 + k]
				push[kv] = maxf(push.get(kv, 0.0), best * 1.5 + 0.002)
		for kv in push:
			cv[kv] += vn[kv] * push[kv]
	return cv


func _closest_on_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denom := 1.0 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)
