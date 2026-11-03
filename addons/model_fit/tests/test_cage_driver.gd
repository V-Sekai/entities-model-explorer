extends SceneTree
# Cage driver against the real guest, with OpenUSD inputs read through usd.elf. Needs, in the environment: CAGE_ELF (the cage guest), USD_ELF
# (usd.elf), CAGE_SHELL and CAGE_BODY (.usdz triangle meshes; tests/make_usd_fixtures.gd writes them). Without them the test says SKIP and exits
# 0 (CI has no guest files). CAGE_EXPECT_MAX_MOVE (optional): the largest vertex move (metres) an earlier run of the same shell measured, a regression check.
# usage: CAGE_ELF=cage.elf USD_ELF=usd.elf CAGE_SHELL=shell.usdz CAGE_BODY=body.usdz godot --headless -s tests/test_cage_driver.gd
# Turn binary translation on for speed (project setting sandbox/binary_translation/*); results are identical either way.
const Driver := preload("../cage_driver.gd")
const Knots := preload("../frontier_knots.gd")
var fails := 0


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1


# A triangle mesh from a .usdz, read with usd.elf: {v: PackedVector3Array, t: PackedInt32Array}.
func _usd(elf: PackedByteArray, path: String) -> Dictionary:
	var sb = ClassDB.instantiate("Sandbox")
	sb.memory_max = 1024
	sb.references_max = 4096
	sb.allocations_max = 1000000
	sb.execution_timeout = 300000
	root.add_child(sb)
	sb.load_buffer(elf)
	sb.vmcall("usd_init")
	var pkg := FileAccess.get_file_as_bytes(path)
	var at := 0
	while at < pkg.size():
		sb.vmcall("usd_push", pkg.slice(at, mini(at + 524288, pkg.size())))
		at += 524288
	sb.vmcall("usd_open_staged")
	var f = sb.vmcall("usd_mesh_points", 0)
	var v := PackedVector3Array()
	for i in range(0, f.size(), 3):
		v.append(Vector3(f[i], f[i + 1], f[i + 2]))
	var t: PackedInt32Array = sb.vmcall("usd_mesh_indices", 0)
	sb.queue_free()
	return {"v": v, "t": t}


func _init() -> void:
	var elf_path := OS.get_environment("CAGE_ELF")
	var usd_path := OS.get_environment("USD_ELF")
	if (
		elf_path == ""
		or usd_path == ""
		or OS.get_environment("CAGE_SHELL") == ""
		or OS.get_environment("CAGE_BODY") == ""
	):
		print("SKIP  set CAGE_ELF, USD_ELF, CAGE_SHELL and CAGE_BODY")
		quit(0)
		return
	var usd_elf := FileAccess.get_file_as_bytes(usd_path)
	var shell := _usd(usd_elf, OS.get_environment("CAGE_SHELL"))
	var body := _usd(usd_elf, OS.get_environment("CAGE_BODY"))
	_check(
		shell["v"].size() > 0 and shell["t"].size() % 3 == 0 and body["t"].size() > 0,
		(
			"the OpenUSD meshes load (shell %d points, body %d points)"
			% [shell["v"].size(), body["v"].size()]
		)
	)
	var d := Driver.new()
	_check(d.load_guest(root, FileAccess.get_file_as_bytes(elf_path)), "the guest loads")
	var b: Dictionary = await d.bind(shell["v"], shell["t"], 70)
	_check(
		b["ok"] and b["outside"] == 0,
		"bind at 70 knots binds (got %s)" % str({"ok": b["ok"], "outside": b["outside"]})
	)
	var f: Dictionary = await d.fit(shell["v"], shell["t"], body["v"], body["t"], 70)
	_check(
		f.has("result") and f["result"].size() == shell["v"].size(),
		"the fit returns every shell vertex"
	)
	_check(
		int(f.get("inside", -1)) == 0,
		"no vertex is left inside the body (inside=%s)" % str(f.get("inside"))
	)
	_check(
		float(f.get("dmin", 0.0)) >= 0.0015,
		"every vertex clears the body by about the margin (dmin=%s)" % str(f.get("dmin"))
	)
	_check(
		float(f.get("max_move", 0.0)) > 0.01,
		"a shell that starts inside the body moves (max %.4f m)" % float(f.get("max_move", 0.0))
	)
	if OS.get_environment("CAGE_EXPECT_MAX_MOVE") != "":
		_check(
			(
				absf(
					(
						float(f.get("max_move", 0.0))
						- float(OS.get_environment("CAGE_EXPECT_MAX_MOVE"))
					)
				)
				< 2e-3
			),
			"largest move matches the earlier run (%.5f m)" % float(f.get("max_move", 0.0))
		)

	# Planted control 1: the same shell against a body 5 m away has nothing to avoid, so it must stay exactly where it is.
	var far := PackedVector3Array()
	for p in body["v"]:
		far.append(p + Vector3(5, 0, 0))
	var g: Dictionary = await d.fit(shell["v"], shell["t"], far, body["t"], 70)
	_check(
		g.has("result") and float(g.get("max_move", -1.0)) == 0.0 and int(g.get("inside", -1)) == 0,
		"control: a far body leaves the shell in place (max %s m)" % str(g.get("max_move"))
	)

	# Planted control 2: with auto_orient off, a flipped winding is refused, not fitted; with it on, the driver recovers by flipping back.
	var w := Driver.new()
	w.load_guest(root, FileAccess.get_file_as_bytes(elf_path))
	w.flip_winding = true
	w.auto_orient = false
	var r: Dictionary = await w.bind(shell["v"], shell["t"], 70)
	_check(
		not r["ok"],
		(
			"control: flipped winding without auto_orient does not bind (got %s)"
			% str({"ok": r["ok"], "outside": r["outside"], "state": r["state"]})
		)
	)
	w.auto_orient = true
	r = await w.bind(shell["v"], shell["t"], 70)
	_check(
		r["ok"] and not r["flipped"],
		"auto_orient recovers a flipped winding (flipped=%s)" % str(r.get("flipped"))
	)

	# The whole search with the frontier class.
	var kn = Knots.new()
	var s: Dictionary = await d.search(kn, "spats0", shell["v"], shell["t"], body["v"], body["t"])
	_check(
		s["k"] > 0 and s.has("fit") and int(s["fit"]["inside"]) == 0,
		(
			"search returns a K with an accepted fit (got %s)"
			% str({"k": s["k"], "reason": s["reason"]})
		)
	)
	print("probed: %s" % str(kn.binds.map(func(x): return [x["k"], x["outside"]])))

	print("RESULT: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)
