extends SceneTree
# Packs the vendored lilToon (thirdparty/lilToon, a git subtree of lilxyzw/lilToon) into
# res://vsk_model_explorer/liltoon.tar: the asset package tar members of Assets/lilToon, each asset
# under lilToon's own GUID from its .meta file, so materials that name lilToon's shaders by GUID
# find them. AutoRig.gd passes the file to AssetPackageExport.sgd, which appends it to every
# package. Not shipped; tools/package_desktop.sh runs it before the export, and a source checkout
# runs it once:
#   godot --headless --path . --script tools/liltoon_pack.gd [-- control]
# Prints the asset count and the shader GUIDs the materials use; exit 0 when all three are present.
# `control` leaves the lilToon shader out, and must fail.
const SRC := "res://thirdparty/lilToon/Assets"
const OUT := "res://vsk_model_explorer/liltoon.tar"
const ASSET_PACKAGE := "res://vsk_model_explorer/asset_package/AssetPackageExport.sgd"
# lts, lts_cutout, lts_trans: the shaders AssetPackageExport.sgd writes into materials.
const SHADERS := [
	"df12117ecd77c31469c224178886498e",
	"85d6126cae43b6847aff4b13f4adb8ec",
	"165365ab7100a044ca85fc8c33548a62",
]


func _initialize() -> void:
	var control := OS.get_cmdline_user_args().has("control")
	var ex = load(ASSET_PACKAGE).new()
	if ex == null or not ex.has_method("members"):
		_end("FAIL AssetPackageExport.sgd did not compile", 1)
		return
	var paths: Array[String] = []
	_walk("lilToon", paths)
	paths.sort()
	var tar := PackedByteArray()
	var guids := {}
	for rel in paths:
		var meta := FileAccess.get_file_as_string(SRC.path_join(rel + ".meta"))
		var g := ""
		for line in meta.split("\n"):
			if line.begins_with("guid: "):
				g = line.trim_prefix("guid: ").strip_edges()
		if g.length() != 32:
			_end("FAIL no guid in %s.meta" % rel, 1)
			return
		if control and g == SHADERS[0]:
			continue
		var folder := DirAccess.dir_exists_absolute(SRC.path_join(rel))
		var data := (
			PackedByteArray() if folder else FileAccess.get_file_as_bytes(SRC.path_join(rel))
		)
		tar.append_array(ex.members(g, "Assets/" + rel, data, meta, folder))
		guids[g] = rel
	for g in SHADERS:
		if not guids.has(g):
			_end("FAIL shader %s is not in the pack" % g, 1)
			return
		print("shader ", g, " ", guids[g])
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f == null:
		_end("FAIL cannot write " + OUT, 1)
		return
	f.store_buffer(tar)
	f.close()
	_end("PASS %d lilToon assets, %d bytes in %s" % [guids.size(), tar.size(), OUT], 0)


# Every file and folder under SRC/rel that has a .meta, as paths relative to SRC.
func _walk(rel: String, out: Array[String]) -> void:
	out.append(rel)
	var d := DirAccess.open(SRC.path_join(rel))
	if d == null:
		return
	for name in d.get_files():
		if (
			not name.ends_with(".meta")
			and FileAccess.file_exists(SRC.path_join(rel.path_join(name)) + ".meta")
		):
			out.append(rel.path_join(name))
	for name in d.get_directories():
		if FileAccess.file_exists(SRC.path_join(rel.path_join(name)) + ".meta"):
			_walk(rel.path_join(name), out)


func _end(text: String, code: int) -> void:
	print(text)
	quit(code)
