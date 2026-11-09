extends RefCounted
# The persona: a domain and a goal in, an exact plan out, with no weights and no sampling.
# persona.elf runs the persona's Lean (Bintr.gd); this is the viewer's side of it, one ask per
# call. RigTools.gd exposes it to an MCP client as `persona_ask`. The answer is JSON: the plan
# and whether executing it lands on the goal, or the refusal by name.

const Bintr = preload("res://vsk_model_explorer/core/Bintr.gd")

const ELF := "res://persona.elf"
# One ask measured 68 MiB of guest memory; the arena wants a power of two.
const MEMORY_MB := 128
const REFS := 4096

var _sb: Node


func available() -> bool:
	return FileAccess.file_exists(ELF)


# The version of the guest's surface: the cheapest proof that persona.elf loaded and its API
# is registered, without asking it anything.
func version(parent: Node) -> String:
	if not _ready(parent):
		return ""
	return str(_sb.vmcall("persona_version"))


func _ready(parent: Node) -> bool:
	if not available():
		return false
	if _sb == null or not is_instance_valid(_sb):
		_sb = Bintr.make(parent, ELF, MEMORY_MB, REFS)
	return _sb.has_function("persona_ask")


# The answer the guest composed, or {"error": ...} when it could not be asked.
func ask(parent: Node, goal: String = "") -> Dictionary:
	if not available():
		return {"error": "persona.elf is missing from this program"}
	if not _ready(parent):
		return {"error": "persona.elf did not load"}
	var answer := str(_sb.vmcall("persona_ask", goal))
	var parsed = JSON.parse_string(answer)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"error": "persona.elf answered " + answer}
	return parsed


# The Sandbox is one machine for a batch of asks: release it with free(), never queue_free()
# inside a loop, or every arena stays alive until the loop ends.
func close() -> void:
	if _sb != null and is_instance_valid(_sb):
		_sb.free()
		_sb = null
