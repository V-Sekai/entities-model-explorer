extends RefCounted
# Which meshes of an avatar are its base body and which are clothing, and the plan for a pair of avatars: take A's clothing off, hide A's
# base, and fit the clothing to B's base.
#
# A mesh is a base mesh when its node name matches one of base_patterns (full-name regular expressions, case-insensitive). The usual names
# are Body and BodyBase / BaseBody / Base, but they vary between avatars, so the list is an argument. Clothing is every other mesh that is
# visible in its avatar and whose name matches none of exclude_patterns (case-insensitive substrings: hair, ears, tail, eyes, face parts,
# debug objects), which are not clothing; both lists are arguments too. Nothing here moves a vertex.

const DEFAULT_BASE_PATTERNS := ["^Body$", "^BodyBase$", "^BaseBody$", "^Base$"]
const DEFAULT_EXCLUDE := [
	"hair",
	"ear",
	"tail",
	"eye",
	"brow",
	"lash",
	"mouth",
	"tongue",
	"teeth",
	"face",
	"head",
	"debug",
	"wing",
	"horn"
]

var base_patterns: Array = DEFAULT_BASE_PATTERNS.duplicate()
var exclude: Array = DEFAULT_EXCLUDE.duplicate()
var include_hidden := false


func _matches_base(name: String) -> bool:
	for p in base_patterns:
		var re := RegEx.new()
		if re.compile("(?i)" + String(p)) == OK and re.search(name) != null:
			return true
	return false


func _excluded(name: String) -> bool:
	var n := name.to_lower()
	for e in exclude:
		if n.contains(String(e).to_lower()):
			return true
	return false


func _visible_in(mi: Node3D, avatar: Node) -> bool:
	var n: Node = mi
	while n != null and n != avatar.get_parent():
		if n is Node3D and not (n as Node3D).visible:
			return false
		n = n.get_parent()
	return true


# {base: [MeshInstance3D], clothing: [MeshInstance3D], skipped: [MeshInstance3D]} for one avatar.
func classify(avatar: Node) -> Dictionary:
	var out := {"base": [], "clothing": [], "skipped": []}
	for m in avatar.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		if _matches_base(mi.name):
			out["base"].append(mi)
		elif _excluded(mi.name) or (not include_hidden and not _visible_in(mi, avatar)):
			out["skipped"].append(mi)
		else:
			out["clothing"].append(mi)
	return out


# The plan for moving A's clothing onto B: {garments, source_base, target_base, warnings}. Source and target may be the same avatar.
func plan(source: Node, target: Node) -> Dictionary:
	var a := classify(source)
	var b := classify(target)
	var warnings := []
	if a["base"].is_empty():
		warnings.append(
			"no base mesh found in the source avatar (names tried: %s)" % str(base_patterns)
		)
	if b["base"].is_empty():
		warnings.append(
			"no base mesh found in the target avatar (names tried: %s)" % str(base_patterns)
		)
	if a["clothing"].is_empty():
		warnings.append("the source avatar has no clothing meshes")
	if a["base"].size() > 3 or b["base"].size() > 3:
		warnings.append("more than three base meshes matched; check the base patterns")
	return {
		"garments": a["clothing"],
		"source_base": a["base"],
		"target_base": b["base"],
		"warnings": warnings
	}


# Hide the source avatar's base meshes (the other avatar's base). Returns the meshes that were visible and are now hidden, so a caller can restore them.
func hide_source_base(p: Dictionary) -> Array:
	var hidden := []
	for mi in p["source_base"]:
		if (mi as Node3D).visible:
			(mi as Node3D).visible = false
			hidden.append(mi)
	return hidden
