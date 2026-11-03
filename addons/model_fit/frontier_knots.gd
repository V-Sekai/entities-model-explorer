extends RefCounted
# Frontier search for the cage knot count K of a garment shell.
#
# Every (shell, K) probe is an experiment with a cheap outcome: the cage bind (bind-only run, seconds with binary translation) is
# bound, or fails with N vertices outside the cage. A fit that follows a bound probe gives a second, costlier outcome (vertices left
# inside the body, vertices below the margin, how far the shell moved). The search keeps every experiment (the history) and learns
# across shells: shells of similar size share what worked.
#
#   round1(shell, tris)  K values to probe first: the K values that bound for shells within SIMILAR x of this size (exploit), then a fixed
#                        ladder (explore, so the history can correct itself). K values already probed for the shell are left out.
#   refine(shell)        up to REFINE_ROUNDS follow-ups: with a bound K, the unprobed ladder rungs below the smallest bound K and the
#                        midpoint to the next lower probe (a smaller K is a smoother cage and a faster fit); with none bound, K x 0.8
#                        and K x 1.25 of the probe with the fewest vertices outside.
#   fit_candidates(shell) up to FIT_CANDIDATES bound K values (smallest, median, largest) that still need a fit.
#   choose(shell)        the K to use: among bound K values with a fit and no vertex inside the body, the fewest vertices below the margin,
#                        then the smallest move, then the smallest K. Otherwise a reason: bind probes missing, fits missing, none bound
#                        (the cage cannot contain this shell, another route is needed) or no fit accepted.
# Every list is finite and each shell has a fixed probe budget, so the search ends. The class does no I/O of its own: the caller runs the
# probes and fits and records what they returned (that keeps it testable with a planted oracle: tests/test_frontier_knots.gd).

const LADDER := [24, 34, 48, 70, 100, 150, 220, 320]
const REFINE_ROUNDS := 2
const SIMILAR := 2.0
const FIT_CANDIDATES := 3
const MIN_K := 8

# {shell, tris, k, outside, ms}; outside is 0 when bound, N > 0 when N vertices lay outside the cage, -1 when there was no bind result.
var binds: Array = []
# {shell, k, inside, below, move, ms}: inside = vertices still inside the body, below = vertices under the margin, move = mean displacement (m).
var fits: Array = []
var rounds: Dictionary = {}


func record_bind(shell: String, tris: int, k: int, outside: int, ms: int = 0) -> void:
	binds.append({"shell": shell, "tris": tris, "k": k, "outside": outside, "ms": ms})


func record_fit(shell: String, k: int, inside: int, below: int, move: float, ms: int = 0) -> void:
	fits.append({"shell": shell, "k": k, "inside": inside, "below": below, "move": move, "ms": ms})


func _probed(shell: String) -> Dictionary:
	var d := {}
	for b in binds:
		if b["shell"] == shell:
			d[int(b["k"])] = int(b["outside"])
	return d


func bound(shell: String) -> Array:
	var r := []
	for k in _probed(shell):
		if _probed(shell)[k] == 0:
			r.append(k)
	r.sort()
	return r


# K values that bound for shells of similar size, most common first (ties: smaller K), at most three.
func prior(tris: int, own_shell: String = "") -> Array:
	var votes := {}
	for b in binds:
		if b["shell"] == own_shell or int(b["outside"]) != 0:
			continue
		var t := float(b["tris"])
		if t >= tris / SIMILAR and t <= tris * SIMILAR:
			votes[int(b["k"])] = int(votes.get(int(b["k"]), 0)) + 1
	var ks := votes.keys()
	ks.sort_custom(func(x, y): return votes[x] > votes[y] or (votes[x] == votes[y] and x < y))
	return ks.slice(0, 3)


func round1(shell: String, tris: int) -> Array:
	var seen := _probed(shell)
	var out := []
	for k in prior(tris, shell) + LADDER:
		if not seen.has(k) and not out.has(k):
			out.append(k)
	return out


func refine(shell: String) -> Array:
	if int(rounds.get(shell, 0)) >= REFINE_ROUNDS:
		return []
	var seen := _probed(shell)
	if seen.is_empty():
		return []
	var cand := []
	var b := bound(shell)
	if not b.is_empty():
		var smallest: int = b[0]
		for k in LADDER:
			if k < smallest and not seen.has(k):
				cand.append(k)
		var lower := -1
		for k in seen:
			if k < smallest:
				lower = maxi(lower, k)
		if lower >= 0 and (lower + smallest) / 2 >= MIN_K:
			cand.append((lower + smallest) / 2)
	else:
		var least := -1
		for k in seen:
			if seen[k] >= 0 and (least < 0 or seen[k] < seen[least] or (seen[k] == seen[least] and k < least)):
				least = k
		if least < 0:
			return []
		cand = [maxi(MIN_K, int(least * 0.8)), int(ceil(least * 1.25))]
	var out := []
	for k in cand:
		if not seen.has(k) and not out.has(k):
			out.append(k)
	if out.is_empty():
		return []
	rounds[shell] = int(rounds.get(shell, 0)) + 1
	out.sort()
	return out


func _fit_of(shell: String, k: int) -> Variant:
	for f in fits:
		if f["shell"] == shell and f["k"] == k:
			return f
	return null


func fit_candidates(shell: String) -> Array:
	var b := bound(shell)
	if b.is_empty():
		return []
	var pick := []
	for k in [b[0], b[b.size() / 2], b[b.size() - 1]]:
		if not pick.has(k):
			pick.append(k)
	return pick.filter(func(k): return _fit_of(shell, k) == null).slice(0, FIT_CANDIDATES)


func choose(shell: String) -> Dictionary:
	var b := bound(shell)
	if b.is_empty():
		if int(rounds.get(shell, 0)) < REFINE_ROUNDS and not _probed(shell).is_empty() and not refine_preview(shell).is_empty():
			return {"k": -1, "reason": "refine pending"}
		var seen := _probed(shell)
		var least := -1
		for k in seen:
			if seen[k] >= 0 and (least < 0 or seen[k] < seen[least]):
				least = k
		return {"k": -1, "reason": "none bound", "least_outside_k": least}
	var pending := fit_candidates(shell)
	var best = null
	for k in b:
		var f = _fit_of(shell, k)
		if f == null or int(f["inside"]) != 0:
			continue
		if best == null or [f["below"], f["move"], k] < [best["below"], best["move"], best["k"]]:
			best = {"k": k, "below": f["below"], "move": f["move"]}
	if best != null:
		return {"k": best["k"], "reason": "fit accepted"}
	if not pending.is_empty():
		return {"k": -1, "reason": "fits pending", "pending": pending}
	return {"k": -1, "reason": "no fit accepted"}


# What refine() would return, without spending a round.
func refine_preview(shell: String) -> Array:
	var saved: int = int(rounds.get(shell, 0))
	var r := refine(shell)
	rounds[shell] = saved
	return r


func to_json() -> String:
	return JSON.stringify({"binds": binds, "fits": fits, "rounds": rounds})


func from_json(text: String) -> bool:
	var d = JSON.parse_string(text)
	if typeof(d) != TYPE_DICTIONARY:
		return false
	binds = d.get("binds", [])
	fits = d.get("fits", [])
	rounds = d.get("rounds", {})
	return true
