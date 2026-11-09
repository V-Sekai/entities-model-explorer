extends Node
# Run: godot --headless --path . res://tools/xray_check.tscn (the autoloads need a scene run).
# Checks X-ray on a model built in code: x turns each StandardMaterial3D surface translucent on a
# copy, leaves the shared material untouched, and off restores the override it had.
const UI := preload("res://vsk_model_explorer/core/UIController.gd")


func _ready() -> void:
	var root_node := Node3D.new()
	root_node.add_to_group(GlobalSignal.GLTF_GROUP)
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var shared := StandardMaterial3D.new()
	shared.albedo_color = Color(0.2, 0.4, 0.6, 1.0)
	mi.mesh.surface_set_material(0, shared)
	root_node.add_child(mi)
	add_child(root_node)
	var ui := Node.new()
	ui.set_script(UI)
	# The panels the controller's _ready looks up, as empty stand-ins.
	var info := PanelContainer.new()
	info.name = "InfoPanel"
	var im := MarginContainer.new()
	im.name = "MarginContainer"
	var row := VBoxContainer.new()
	row.name = "Row"
	var head := Label.new()
	head.name = "Label"
	row.add_child(head)
	im.add_child(row)
	info.add_child(im)
	ui.add_child(info)
	var load_panel := PanelContainer.new()
	load_panel.name = "LoadingPanel"
	ui.add_child(load_panel)
	var msg := PanelContainer.new()
	msg.name = "MessagePanel"
	var mm := MarginContainer.new()
	mm.name = "MarginContainer"
	var ml := Label.new()
	ml.name = "Label"
	mm.add_child(ml)
	msg.add_child(mm)
	ui.add_child(msg)
	add_child(ui)
	var fails := 0
	ui._set_xray(true)
	var on := mi.get_active_material(0) as StandardMaterial3D
	if (
		on == shared
		or on.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA
		or on.albedo_color.a >= 0.5
	):
		fails += 1
		printerr("FAIL on: ", on, " ", on.albedo_color)
	if shared.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or shared.albedo_color.a != 1.0:
		fails += 1
		printerr("FAIL shared material was edited")
	ui._set_xray(false)
	if mi.get_active_material(0) != shared or mi.get_surface_override_material(0) != null:
		fails += 1
		printerr("FAIL off did not restore")
	print("XRAY-CHECK ", "FAIL" if fails else "OK")
	get_tree().quit(1 if fails else 0)
