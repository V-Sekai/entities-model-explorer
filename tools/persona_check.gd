extends SceneTree
# Check of the persona guest (Persona.gd) in a real engine: a domain and a goal in, an exact
# plan out, with no weights. persona.elf must be beside the project and the sandbox add-on in it.
#   godot --path <project> --resolution 320x200 -s res://tools/persona_check.gd [-- --plant]
# The guest answers the default goal with the whole plan and refuses a goal it does not
# declare, by name. --plant shortens the expected plan by one action before comparing, which
# must then FAIL: a check that cannot report a mismatch certifies nothing.
# Prints CHECK-OK / CHECK-FAIL per check and RESULT: PASS / FAIL.

const Persona = preload("res://vsk_model_explorer/core/Persona.gd")
const PLAN := ["recharge", "move_to_storage", "pickup", "move_to_shipping", "dropoff"]
const VERSION := "0.1.0"

var plant := false


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--plant":
			plant = true
	_run.call_deferred()


func _run() -> void:
	var persona = Persona.new()
	var checks := 0
	var failed := 0

	var version := persona.version(root)
	checks += 1
	if version == VERSION:
		print("CHECK-OK   version ", version)
	else:
		failed += 1
		print("CHECK-FAIL version ", version, " (wanted ", VERSION, ")")

	var answer := persona.ask(root, "")
	var want := PLAN.duplicate()
	if plant:
		want = want.slice(0, want.size() - 1)
	var got: Array = answer.get("plan", [])
	var reached: bool = bool(answer.get("reached", false))
	checks += 1
	if got == want and reached and str(answer.get("goal", "")) == "delivered":
		print("CHECK-OK   plan ", got)
	else:
		failed += 1
		print("CHECK-FAIL plan ", got, " reached=", reached, " (wanted ", want, ")")

	var refused := persona.ask(root, "undeclared")
	checks += 1
	if str(refused.get("refused", "")) == "undeclared_goal" and not refused.has("plan"):
		print("CHECK-OK   a goal the persona does not declare is refused by name")
	else:
		failed += 1
		print("CHECK-FAIL the refusal read ", refused)

	persona.close()
	print("RESULT: ", "PASS" if failed == 0 else "FAIL", " (", checks - failed, " of ", checks, ")")
	quit(0 if failed == 0 else 1)
