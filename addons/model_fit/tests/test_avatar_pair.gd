extends SceneTree
# Base / clothing split and the pair plan, on synthetic avatars. usage: godot --headless -s tests/test_avatar_pair.gd
const Pair := preload("../avatar_pair.gd")
var fails := 0


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1


func _avatar(names: Array, hidden: Array = []) -> Node3D:
	var root := Node3D.new()
	root.name = "Avatar"
	var arm := Node3D.new()
	arm.name = "Armature"
	root.add_child(arm)
	for n in names:
		var mi := MeshInstance3D.new()
		mi.name = n
		mi.mesh = BoxMesh.new()
		mi.visible = not hidden.has(n)
		root.add_child(mi)
	return root


func _names(a: Array) -> Array:
	return a.map(func(m): return String(m.name))


func _init() -> void:
	var p = Pair.new()
	var a := _avatar(
		["Body", "BaseBody", "Skirt", "Kimono", "Hair", "Tail", "Shoes", "Hidden_Dress"],
		["Hidden_Dress"]
	)
	var c: Dictionary = p.classify(a)
	_check(
		_names(c["base"]) == ["Body", "BaseBody"],
		"Body and BaseBody are the base (got %s)" % str(_names(c["base"]))
	)
	_check(
		_names(c["clothing"]) == ["Skirt", "Kimono", "Shoes"],
		"clothing is the visible rest without hair and tail (got %s)" % str(_names(c["clothing"]))
	)
	_check(
		_names(c["skipped"]) == ["Hair", "Tail", "Hidden_Dress"],
		"hair, tail and the hidden dress are skipped (got %s)" % str(_names(c["skipped"]))
	)

	p.include_hidden = true
	_check(
		"Hidden_Dress" in _names(p.classify(a)["clothing"]),
		"include_hidden brings the hidden dress back"
	)
	p.include_hidden = false

	# A different naming scheme: the base patterns are an argument.
	var b := _avatar(["Anny_Base", "Dress", "Jacket"])
	var p2 = Pair.new()
	p2.base_patterns = ["^Anny_Base$"]
	_check(_names(p2.classify(b)["base"]) == ["Anny_Base"], "custom base pattern finds Anny_Base")
	_check(
		_names(Pair.new().classify(b)["base"]).is_empty(),
		"control: the default patterns do not match Anny_Base"
	)

	# Pair plan: A's clothing, A's base to hide, B's base as the target.
	var plan: Dictionary = (
		p2.plan(a, b) if false else Pair.new().plan(a, _avatar(["Body", "Dress"]))
	)
	_check(
		(
			_names(plan["garments"]) == ["Skirt", "Kimono", "Shoes"]
			and _names(plan["source_base"]) == ["Body", "BaseBody"]
			and _names(plan["target_base"]) == ["Body"]
		),
		"pair plan lists garments, source base and target base"
	)
	_check(plan["warnings"].is_empty(), "a complete pair has no warnings")
	var hidden: Array = Pair.new().hide_source_base(plan)
	_check(
		(
			hidden.size() == 2
			and not (plan["source_base"][0] as Node3D).visible
			and (plan["target_base"][0] as Node3D).visible
		),
		"the source base is hidden and the target base stays visible"
	)

	# Warnings: no base in the target.
	var bad: Dictionary = Pair.new().plan(a, _avatar(["Anny_Base", "Dress"]))
	_check(
		bad["warnings"].size() == 1 and "target" in bad["warnings"][0],
		"a target without a base mesh gives a warning (got %s)" % str(bad["warnings"])
	)

	print("RESULT: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)
