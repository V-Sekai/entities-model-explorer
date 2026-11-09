extends SceneTree
# Test driver for FaceBlink.gd (not shipped). Windowed, never headless:
#   godot --path . --resolution 64x64 --script tools/face_blink_check.gd -- <in.vrm> <out.vrm> [force] [names_from]
# A VRM 0.x goes to VRM 1.0 first (AutoRig.save_vrm1), then FaceBlink adds the eye closes; `force`
# adds them when the avatar has its own blink too (to score them against it).
const AutoRig := preload("res://vsk_model_explorer/core/AutoRig.gd")
const FaceBlink := preload("res://vsk_model_explorer/core/FaceBlink.gd")

var _done := false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	quit(check())
	return false


func check() -> int:
	var a := OS.get_cmdline_user_args()
	var rig := AutoRig.new()
	var out: String = a[1]
	if rig.is_vrm1(a[0]):
		DirAccess.copy_absolute(a[0], out)
	else:
		# godot-vrm writes a binary file only for a .glb name, as AutoRig.run_vrm does.
		var tmp := out.get_basename() + ".tmp.glb"
		var why := rig.save_vrm1(a[0], tmp)
		if why != "":
			print("FACE-BLINK FAIL ", why)
			return 1
		DirAccess.rename_absolute(tmp, out)
	rig.free()
	var fb := FaceBlink.new()
	var why := fb.add(out, a.size() > 2 and a[2] == "force", a[3] if a.size() > 3 else "")
	print("FACE-BLINK ", "OK" if why == "" else "FAIL " + why, " ", JSON.stringify(fb.report))
	return 0 if why == "" and not fb.report.has("skipped") else 1
