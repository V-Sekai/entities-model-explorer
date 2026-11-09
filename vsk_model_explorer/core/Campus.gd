class_name Campus
extends Node
# The campus: Sakuragaoka Station (V-Sekai-fire/entities-sakuragaoka-station) as a scene the viewer can load.
# P (or --campus) builds the station at seed 1 under the viewer; P again frees it. The addon and its slug
# guests (slug.elf, slug.double.elf) are not source here: the release fetches the station at a pinned commit
# and tools/package_desktop.sh copies them into the pck (RFD66606-2360). A checkout without them has no P row.
const SCENE := "res://addons/sakuragaoka_station/station.tscn"
var station: Node3D


static func available() -> bool:
	return ResourceLoader.exists(SCENE)


func is_open() -> bool:
	return station != null and is_instance_valid(station)


func toggle() -> void:
	if is_open():
		station.queue_free()
		station = null
		return
	var packed := load(SCENE) as PackedScene
	if packed == null:
		push_warning("campus: %s did not load" % SCENE)
		return
	station = packed.instantiate()
	station.name = "Campus"
	get_parent().add_child(station)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.keycode == KEY_P:
		toggle()
		get_viewport().set_input_as_handled()
