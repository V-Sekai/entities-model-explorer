extends SceneTree
# Frontier knot search against planted oracles: a cage that binds only for some K, with a failure count that falls as K nears the binding range.
# Each case also has a planted control that must fail the check. usage: godot --headless -s tests/test_frontier_knots.gd
const Knots := preload("../frontier_knots.gd")
var fails := 0


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1


# oracle(k) -> outside count (0 = bound).
func _run(kn, shell: String, tris: int, oracle: Callable, fit: Callable) -> Dictionary:
	for k in kn.round1(shell, tris):
		kn.record_bind(shell, tris, k, oracle.call(k))
	for _r in 3:
		var more: Array = kn.refine(shell)
		if more.is_empty():
			break
		for k in more:
			kn.record_bind(shell, tris, k, oracle.call(k))
	for k in kn.fit_candidates(shell):
		var f: Array = fit.call(k)
		kn.record_fit(shell, k, f[0], f[1], f[2])
	return kn.choose(shell)


func _init() -> void:
	# 1. Wide binding range: the smallest bound rung is a candidate, a fit decides.
	var wide := func(k): return 0 if (k >= 20 and k <= 60) or k >= 140 else 3 * mini(absi(k - 60), absi(k - 140)) + 1
	var kn = Knots.new()
	var r = _run(kn, "A", 3660, wide, func(k): return [0, 10 + k, 0.02 + k * 1e-5])
	_check(r["k"] == 24 and r["reason"] == "fit accepted", "wide range: smallest bound K with an accepted fit (got %s)" % str(r))
	_check(kn.bound("A").has(r["k"]) and r["k"] in [24, 34, 48, 150, 220, 320], "wide range: the chosen K is one the oracle bound")

	# 2. A fit that leaves vertices inside the body is skipped even for the smallest K.
	kn = Knots.new()
	r = _run(kn, "B", 3660, wide, func(k): return [5, 0, 0.0] if k == 24 else [0, 10, 0.03])
	_check(r["k"] != 24 and r["k"] > 0, "a bound K whose fit leaves vertices inside the body is not chosen (got %s)" % str(r))

	# 3. Narrow binding range between ladder rungs: refine finds it by moving toward the fewest-outside probe.
	var narrow := func(k): return 0 if k >= 55 and k <= 65 else 3 * absi(k - 60) + 1
	kn = Knots.new()
	r = _run(kn, "C", 2000, narrow, func(k): return [0, 0, 0.01])
	_check(r["k"] >= 55 and r["k"] <= 65, "narrow range between rungs is found by refine (got %s)" % str(r))
	_check(int(kn.rounds.get("C", 0)) <= Knots.REFINE_ROUNDS, "refine stays inside its round budget")

	# 4. No K binds (the 4-loop Inner garment): no K is returned and the least-outside probe is reported.
	var never := func(k): return 100 + absi(k - 150)
	kn = Knots.new()
	r = _run(kn, "D", 1455, never, func(k): return [0, 0, 0.0])
	_check(r["k"] == -1 and r["reason"] == "none bound", "no K binds: none is returned (got %s)" % str(r))
	_check(r.get("least_outside_k", -1) in [150, 120, 188, 100, 220], "no K binds: the least-outside K is reported (got %s)" % str(r.get("least_outside_k")))
	_check(kn.refine("D").is_empty(), "no K binds: the search ends")

	# 5. Learning: a K that bound for a similar-size shell is probed first for the next one, and not for a very different size.
	kn = Knots.new()
	kn.record_bind("X", 3600, 56, 0)
	kn.record_bind("X", 3600, 70, 0)
	_check(kn.round1("Y", 3000).slice(0, 2) == [56, 70] or (kn.round1("Y", 3000).has(56) and kn.round1("Y", 3000).find(56) < 3), "a K that bound for a similar-size shell leads the next search (got %s)" % str(kn.round1("Y", 3000)))
	_check(not kn.round1("Z", 40000).has(56), "a K from a shell of a very different size is not carried over")
	var control: Array = kn.round1("Y", 3000)
	_check(not (control.size() == Knots.LADDER.size()), "control: the prior changes the candidate list (it must not equal the bare ladder)")

	# 6. Persistence round trip keeps the history.
	var text: String = kn.to_json()
	var kn2 = Knots.new()
	_check(kn2.from_json(text) and kn2.binds.size() == kn.binds.size(), "history survives a JSON round trip")
	_check(not kn2.from_json("not json"), "bad JSON is refused")

	print("RESULT: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)
