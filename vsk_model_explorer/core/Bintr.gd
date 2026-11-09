extends RefCounted
# Binary translation: godot-sandbox runs a guest ELF as native code when a translation of it,
# bintr-<HASH>.dylib, .dll or .so, is in the folder `bintr` beside the program; the add-on looks
# there by itself once that folder exists (res://bintr in the editor, set by setup()). The hash
# covers the ELF, the Sandbox options and the host, so each OS has its own files, compiled from
# the C that this viewer writes on that OS (tools/compile_bintr.sh):
#   mkdir bintr; GODOT_SANDBOX_BINTR_EMIT=<dir> skintokens-viewer -- --bintr-emit
# loads every guest the viewer uses, with the options it uses, writes <dir>/bintr-<HASH>.c for
# each, and quits. A guest with no matching file runs in the interpreter, with the same results;
# a package without the bintr folder is the interpreted control.

# Every guest the viewer loads: the ELF, memory_max in MiB, references_max.
const GUESTS := [
	["res://skintokens.elf", 2048, 4096],  # AutoRig
	["res://usd.elf", 2048, 4096],  # UsdImport
	["res://motion.elf", 2048, 65536],  # Motion: Kimodo
	["res://skintokens.elf", 2048, 65536],  # Motion: the clip cut and retarget
	["res://mujoco.elf", 256, 4096],  # ObstacleCourse: the course's colliders
	["res://persona.elf", 128, 4096],  # Persona: the ask
]


# The editor runs from the project, not beside a bintr folder: point the add-on at res://bintr.
static func setup() -> void:
	if OS.has_feature("editor"):
		ProjectSettings.set_setting("sandbox/binary_translation/enabled", true)
		ProjectSettings.set_setting("sandbox/binary_translation/cache_dir", "res://bintr/")


# A Sandbox with `elf` loaded, under `parent`; prints whether the guest runs translated.
static func make(parent: Node, elf: String, memory_mb: int, refs: int) -> Node:
	var sb: Node = ClassDB.instantiate("Sandbox")
	sb.memory_max = memory_mb
	sb.references_max = refs
	sb.allocations_max = 10000000
	sb.execution_timeout = 0
	parent.add_child(sb)
	sb.load_buffer(FileAccess.get_file_as_bytes(elf))
	print(
		(
			"BINTR %s %d MiB hash=%08X translated=%s"
			% [
				elf.get_file(),
				memory_mb,
				int(sb.get_translation_hash()) & 0xFFFFFFFF,
				"yes" if sb.is_binary_translated() else "no",
			]
		)
	)
	return sb


# --bintr-emit: load each guest once (the add-on writes its C), then quit.
static func emit(parent: Node) -> void:
	for g in GUESTS:
		if FileAccess.file_exists(g[0]):
			make(parent, g[0], g[1], g[2]).queue_free()
	parent.get_tree().quit(0)
