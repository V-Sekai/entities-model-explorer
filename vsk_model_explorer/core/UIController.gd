extends Node

@export var Grid: Node

@onready var InfoPanel: PanelContainer = $InfoPanel
@onready var LoadingPanel: PanelContainer = $LoadingPanel
@onready var MsgPanel: PanelContainer = $MessagePanel
@onready var MsgLabel: Label = $MessagePanel/MarginContainer/Label
@onready var Row: VBoxContainer = $InfoPanel/MarginContainer/Row

# W, E and G toggle these. The controls card (bottom right) is the one place that lists them; there is
# no tool panel, so the right side has one surface.
signal wireframe_toggled(on: bool)
var wireframe_on := false
var grid_hidden := false
var exploded := false

var animationPlayers: Array[Node]
# The animation list's Loop toggle: on (the default) repeats the clip; off plays it once and then
# returns to RESET.
var loop_on := true
var playing: Array = []

const TextureViewer = preload("res://vsk_model_explorer/scene/TextureViewer.tscn")
var texViewer

const MaterialViewer = preload("res://vsk_model_explorer/scene/MaterialViewer.tscn")
var matViewer

const MeshInfoViewer = preload("res://vsk_model_explorer/scene/MeshInfo.tscn")
var meshViewer

const DYNAMIC_CONTROL_GROUP = "dynamic control"

const CardStyle = preload("res://vsk_model_explorer/core/CardStyle.gd")
const ViewerSettings = preload("res://vsk_model_explorer/core/ViewerSettings.gd")

var card_theme: Theme = CardStyle.make_theme()

var maxAabb: AABB
var exploder = preload("res://addons/model_explode/explode.gd").new()

# Touch tap tracking. A single-finger tap is a press with no meaningful drag (the
# camera's 1-finger orbit and 2-finger pinch/pan are the only other touch gestures,
# so a tap is otherwise indistinguishable from the start of an orbit). We confirm a
# tap on the finger lift and cancel it if the finger drags beyond the slop.
const UI_TAP_SLOP = 12.0
var _mesh_tap_mesh: MeshInstance3D = null
var _mesh_tap_index: int = -1
var _mesh_tap_press_pos: Vector2 = Vector2.ZERO
var _mesh_tap_cancelled: bool = false
var _ui_touch_index: int = -1
var _ui_touch_press_pos: Vector2 = Vector2.ZERO
var _ui_touch_cancelled: bool = false


func _ready():
	GlobalSignal.trigger_texture_viewer.connect(_show_texture_viewer)
	# The toggles come back as they were left.
	wireframe_on = ViewerSettings.get_bool("wireframe", false)
	grid_hidden = ViewerSettings.get_bool("grid_hidden", false)
	if wireframe_on:
		_set_wireframe(true)
	if grid_hidden:
		_set_grid_hidden(true)
	# Every control surface takes the controls card's look. The panels hang off this plain Node, and
	# Godot passes a theme down only through Controls, so each top-level panel gets it here.
	for panel in [InfoPanel, LoadingPanel, MsgPanel]:
		panel.theme = card_theme
	CardStyle.heading($InfoPanel/MarginContainer/Row/Label)
	MsgLabel.add_theme_font_size_override("font_size", 20)


# A popup (mesh, material, texture) gets a card heading and an Esc key cap to close it, the key the
# controls card names for that.
func _card_popup(p: Control) -> Control:
	p.theme = card_theme
	var head := p.find_child("HBoxContainer", true, false)
	for c in head.find_children("*", "Label", true, false):
		CardStyle.heading(c)
	for b in head.find_children("*", "Button", true, false):
		b.text = "Esc"
		b.custom_minimum_size = Vector2(44, 44) if DisplayServer.is_touchscreen_available() else Vector2.ZERO  # a fingertip needs 44 px
	return p


# A list heading in the information panel: upper case and to the left, like the card's CONTROLS.
func _card_list(tree: Tree, title: String) -> void:
	tree.set_column_title(0, title.to_upper())
	tree.set_column_title_alignment(0, HORIZONTAL_ALIGNMENT_LEFT)


func _process(_delta):
	# L, not W: W is walk forward in walk mode (MotionMatch.gd), and one key must not do both.
	if Input.is_action_just_pressed("toggle_wireframe"):
		wireframe_on = not wireframe_on
		_set_wireframe(wireframe_on)
		ViewerSettings.set_bool("wireframe", wireframe_on)
		wireframe_toggled.emit(wireframe_on)

	if Input.is_action_just_pressed("explode_meshes"):
		_set_exploded(not exploded)

	if Input.is_action_just_pressed("toggle_grid"):
		grid_hidden = not grid_hidden
		_set_grid_hidden(grid_hidden)
		ViewerSettings.set_bool("grid_hidden", grid_hidden)


func _on_scroll_input(event, from_control: Tree):
	if event is InputEventMouseButton:
		var child_count = from_control.get_root().get_child_count()
		var child_size: int = (
			from_control.get_item_area_rect(from_control.get_root().get_first_child()).size.y
		)
		var h_scroll_adjustment = 10 * int(from_control.get_column_width(0) > from_control.size.x)
		var max_scroll = (
			child_count * (child_size + 5) - from_control.size.y + 52 + h_scroll_adjustment
		)

		if (
			event.button_index == MOUSE_BUTTON_WHEEL_UP
			and from_control.get_scroll().y == 0
			and max_scroll > 0
		):
			from_control.accept_event()

		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if from_control.get_scroll().y == max_scroll:
				from_control.accept_event()


func _on_root_gltf_start_to_load():
	InfoPanel.visible = false
	MsgPanel.visible = false
	LoadingPanel.visible = true

	var dyna_controls = get_tree().get_nodes_in_group(DYNAMIC_CONTROL_GROUP)
	for ctl in dyna_controls:
		ctl.queue_free()


func _on_root_gltf_is_loaded(success, gltf: Node):
	Input.action_press("close_popup")
	if exploder.is_exploded():
		exploder.implode()
		exploded = false
	if not success:
		MsgLabel.text = "Failed to load model..."
		MsgPanel.visible = true
		return

	InfoPanel.visible = true
	LoadingPanel.visible = false

	var queue = []
	queue.append(gltf)
	var delete_queue = []

	while queue.size() > 0:
		var node = queue.front()
		queue.pop_front()
		var mesh_3d = node as ImporterMeshInstance3D

		if mesh_3d:
			var mesh_instance_node_3d = MeshInstance3D.new()
			var mesh = mesh_3d.mesh

			if mesh:
				var array_mesh = mesh.get_mesh()
				mesh_instance_node_3d.name = node.name
				mesh_instance_node_3d.transform = mesh_3d.transform
				mesh_instance_node_3d.mesh = array_mesh
				mesh_instance_node_3d.skin = mesh_3d.skin
				mesh_instance_node_3d.skeleton = mesh_3d.skeleton_path
				node.replace_by(mesh_instance_node_3d)
				delete_queue.append(node)
				node = mesh_instance_node_3d
			else:
				mesh_instance_node_3d.queue_free()

		var child_count = node.get_child_count()
		for i in range(child_count):
			queue.append(node.get_child(i))

	while delete_queue.size() > 0:
		var node = delete_queue.front()
		delete_queue.pop_front()
		node.queue_free()

	animationPlayers = gltf.find_children("*", "AnimationPlayer")

	var meshes: Array[Node] = gltf.find_children("*", "MeshInstance3D")

	if meshes.size() > 0:
		var meshInfoTree: Tree = Tree.new()
		meshInfoTree.add_to_group(DYNAMIC_CONTROL_GROUP)
		meshInfoTree.columns = 1
		meshInfoTree.column_titles_visible = true
		meshInfoTree.hide_root = true
		meshInfoTree.mouse_filter = Control.MOUSE_FILTER_PASS
		meshInfoTree.size_flags_vertical = Control.SIZE_EXPAND_FILL

		meshInfoTree.item_selected.connect(_on_mesh_item_selected.bind(meshInfoTree))
		meshInfoTree.item_mouse_selected.connect(_on_row_clicked.bind(_on_mesh_item_clicked, meshInfoTree))
		meshInfoTree.item_activated.connect(_on_mesh_item_double_clicked.bind(meshInfoTree))

		meshInfoTree.gui_input.connect(_on_scroll_input.bind(meshInfoTree))

		_card_list(meshInfoTree, "Mesh (%d)" % meshes.size())

		var meshParent: TreeItem = meshInfoTree.create_item()

		# Mesh section
		var material_array: Array[Material] = []
		var texture_array: Array[Variant] = []

		var add_texture_to_array = func(texture):
			if texture != null and not texture_array.has(texture):
				texture_array.append(texture)

		const MAX_NAME_LENGTH = 30
		for mesh in meshes:
			if mesh == null:
				continue
			if mesh.mesh == null:
				continue
			if mesh.get_class() != "MeshInstance3D":
				continue
			# Calculate max aabb
			var aabb = mesh.mesh.get_aabb()
			if maxAabb.position > aabb.position:
				maxAabb.position = aabb.position
			if maxAabb.end < aabb.end:
				maxAabb.end = aabb.end

			var short_name = String(mesh.name)

			if short_name.length() > MAX_NAME_LENGTH:
				short_name = short_name.substr(0, MAX_NAME_LENGTH) + "..."

			var meshItem: TreeItem = meshInfoTree.create_item(meshParent)

			meshItem.set_text(0, short_name)
			meshItem.set_tooltip_text(0, mesh.name)
			meshItem.set_metadata(0, mesh)

			# Gather material
			for si in mesh.mesh.get_surface_count():
				var mat = mesh.get_active_material(si) as Material
				if not material_array.has(mat):
					material_array.append(mat)

					if mat is BaseMaterial3D:
						# Gather texture
						add_texture_to_array.call(mat.albedo_texture)
						add_texture_to_array.call(mat.roughness_texture)
						add_texture_to_array.call(mat.metallic_texture)
						add_texture_to_array.call(mat.emission_texture)
						add_texture_to_array.call(mat.heightmap_texture)
						add_texture_to_array.call(mat.ao_texture)
						add_texture_to_array.call(mat.rim_texture)
						add_texture_to_array.call(mat.refraction_texture)
						add_texture_to_array.call(mat.heightmap_texture)
						add_texture_to_array.call(mat.normal_texture)
						add_texture_to_array.call(mat.clearcoat_texture)
						add_texture_to_array.call(mat.subsurf_scatter_texture)
					elif mat is ShaderMaterial:
						var parameters: Array[String] = [
							"_MainTex",
							"_ShadeTexture",
							"_ReceiveShadowTexture",
							"_ShadingGradeTexture",
							"_RimTexture",
							"_SphereAdd",
							"_EmissionMap",
						]
						for parameter_name in parameters:
							var parameter = (mat as ShaderMaterial).get_shader_parameter(
								parameter_name
							)
							add_texture_to_array.call(parameter)

		Row.add_child.call_deferred(meshInfoTree)

		# Material section
		if material_array.size() > 0:
			var materialInfoTree: Tree = Tree.new()
			materialInfoTree.add_to_group(DYNAMIC_CONTROL_GROUP)
			materialInfoTree.columns = 1
			materialInfoTree.column_titles_visible = true
			materialInfoTree.hide_root = true
			materialInfoTree.mouse_filter = Control.MOUSE_FILTER_PASS
			materialInfoTree.size_flags_vertical = Control.SIZE_EXPAND_FILL

			materialInfoTree.item_mouse_selected.connect(
				_on_row_clicked.bind(_on_material_item_double_clicked, materialInfoTree)
			)

			materialInfoTree.gui_input.connect(_on_scroll_input.bind(materialInfoTree))

			_card_list(materialInfoTree, "Material (%d)" % material_array.size())

			var matParent: TreeItem = materialInfoTree.create_item()

			for mat in material_array:
				var matItem: TreeItem = materialInfoTree.create_item(matParent)
				matItem.set_text(0, mat.resource_name)
				matItem.set_metadata(0, mat)

				if mat is StandardMaterial3D:
					var img: Image
					if mat.albedo_texture != null:
						matItem.set_text(0, mat.resource_name)

						img = mat.albedo_texture.get_image()
						img.resize(32, 32)
						img.flip_y()   # previews match the UV viewer: up and down swapped
					else:
						img = Image.create(32, 32, false, Image.FORMAT_RGBA8)
						img.fill(mat.albedo_color)

						matItem.set_icon(0, ImageTexture.create_from_image(img))
				elif mat is ShaderMaterial:
					var parameters: Array[String] = [
						"_MainTex",
						"_ShadeTexture",
						"_ReceiveShadowTexture",
						"_ShadingGradeTexture",
						"_RimTexture",
						"_SphereAdd",
						"_EmissionMap",
					]
					var img: Image
					for parameter_name in parameters:
						var parameter: Variant = (mat as ShaderMaterial).get_shader_parameter(
							parameter_name
						)
						if parameter is Image and parameter_name == "_MainTex":
							matItem.set_text(0, parameter_name.trim_prefix("_").capitalize())
							img = mat.albedo_texture.get_image()
							img.resize(32, 32)
							img.flip_y()   # previews match the UV viewer: up and down swapped
						elif parameter is Image:
							img = Image.create(32, 32, false, Image.FORMAT_RGBA8)
							img.fill(parameter)
							matItem.set_icon(0, ImageTexture.create_from_image(img))

			Row.add_child.call_deferred(materialInfoTree)

		# Texture section
		if texture_array.size() > 0:
			var textureInfoTree: Tree = Tree.new()
			textureInfoTree.add_to_group(DYNAMIC_CONTROL_GROUP)
			textureInfoTree.columns = 1
			textureInfoTree.column_titles_visible = true
			textureInfoTree.hide_root = true
			textureInfoTree.mouse_filter = Control.MOUSE_FILTER_PASS
			textureInfoTree.size_flags_vertical = Control.SIZE_EXPAND_FILL

			textureInfoTree.item_mouse_selected.connect(
				_on_row_clicked.bind(_on_texture_double_clicked, textureInfoTree)
			)

			textureInfoTree.gui_input.connect(_on_scroll_input.bind(textureInfoTree))

			_card_list(textureInfoTree, "Texture (%d)" % texture_array.size())

			var texParent = textureInfoTree.create_item()

			for tex in texture_array:
				if tex is Texture2D:
					var img = (tex as Texture2D).get_image()
					img.resize(50, 50)
					img.flip_y()   # previews match the UV viewer: up and down swapped

					var texItem: TreeItem = textureInfoTree.create_item(texParent)
					texItem.set_icon(0, ImageTexture.create_from_image(img))
					texItem.set_text(
						0,
						(
							"[%d x %d] %s"
							% [
								tex.get_width(),
								tex.get_height(),
								calc_data_size(tex.get_image().get_data().size())
							]
						)
					)
					texItem.set_metadata(0, tex)
				elif tex is Image:
					var img: Image = (tex as Image).duplicate()   # a copy: the preview must not change the image itself
					img.resize(50, 50)
					img.flip_y()   # previews match the UV viewer: up and down swapped

					var texItem: TreeItem = textureInfoTree.create_item(texParent)
					texItem.set_icon(0, ImageTexture.create_from_image(img))
					texItem.set_text(
						0,
						(
							"[%d x %d] %s"
							% [
								tex.get_width(),
								tex.get_height(),
								calc_data_size(tex.get_image().get_data().size())
							]
						)
					)
					texItem.set_metadata(0, tex)

			Row.add_child.call_deferred(textureInfoTree)

	for animationPlayer in animationPlayers:
		if animationPlayer == null:
			continue
		var animationArray: Array[Array] = []

		var animLibList: Array[StringName] = animationPlayer.get_animation_library_list()
		for animLibName in animLibList:
			var animLib: AnimationLibrary = animationPlayer.get_animation_library(animLibName)
			var animList: Array[StringName] = animLib.get_animation_list()
			for animName in animList:
				if String(animLibName).is_empty():
					animationArray.append([String(animName), animationPlayer])
				else:
					animationArray.append(["%s/%s" % [animLibName, animName], animationPlayer])

		if animationArray.size() > 0:
			var animationTree: Tree = Tree.new()
			animationTree.add_to_group(DYNAMIC_CONTROL_GROUP)
			animationTree.columns = 2
			animationTree.column_titles_visible = true
			animationTree.hide_root = true
			animationTree.mouse_filter = Control.MOUSE_FILTER_PASS
			animationTree.size_flags_vertical = Control.SIZE_EXPAND_FILL

			animationTree.item_mouse_selected.connect(
				_on_row_clicked.bind(_on_animation_item_double_clicked, animationTree)
			)

			animationTree.gui_input.connect(_on_scroll_input.bind(animationTree))

			_card_list(animationTree, "Animation (%d)" % animationArray.size())
			animationTree.select_mode = Tree.SELECT_ROW

			var animRoot = animationTree.create_item()

			for anim in animationArray:
				var animItem: TreeItem = animationTree.create_item(animRoot)
				animItem.set_text(0, anim[0])
				animItem.set_metadata(1, anim)

			Row.add_child.call_deferred(animationTree)
			var loopToggle := CheckButton.new()
			loopToggle.add_to_group(DYNAMIC_CONTROL_GROUP)
			loopToggle.text = "Loop"
			loopToggle.tooltip_text = "On: the clip repeats. Off: the clip plays once."
			loopToggle.button_pressed = loop_on
			loopToggle.focus_mode = Control.FOCUS_NONE
			loopToggle.toggled.connect(_set_loop)
			Row.add_child.call_deferred(loopToggle)

	# The motion list: a clip of the set for a model with a rig. Double-click makes it (Kimodo).
	var motion = owner.get("motion")
	if motion and not gltf.find_children("*", "Skeleton3D").is_empty():
		var clips: Array = motion.clips()
		if not clips.is_empty():
			var motionTree: Tree = Tree.new()
			motionTree.add_to_group(DYNAMIC_CONTROL_GROUP)
			motionTree.columns = 2
			motionTree.column_titles_visible = true
			motionTree.hide_root = true
			motionTree.mouse_filter = Control.MOUSE_FILTER_PASS
			motionTree.size_flags_vertical = Control.SIZE_EXPAND_FILL
			motionTree.select_mode = Tree.SELECT_ROW
			motionTree.tooltip_text = "Double-click a clip to make it for this rig."
			_card_list(motionTree, "Motion (%d)" % clips.size())
			motionTree.set_column_title(1, "")
			motionTree.item_mouse_selected.connect(
				_on_row_clicked.bind(_on_motion_item_double_clicked, motionTree)
			)
			motionTree.gui_input.connect(_on_scroll_input.bind(motionTree))
			var motionRoot = motionTree.create_item()
			for c in clips:
				var item: TreeItem = motionTree.create_item(motionRoot)
				item.set_text(0, c[0].replace("_", " "))
				item.set_text(1, "loop" if c[1] == "loop" else "once")
				item.set_metadata(0, c[0])
			Row.add_child.call_deferred(motionTree)
	_play_after_load.call_deferred()

	# Create convex collision
	for mesh in meshes:
		mesh = mesh as MeshInstance3D
		mesh.create_convex_collision()

		var staticBody: StaticBody3D = mesh.get_node("%s_col" % mesh.name)
		if not staticBody:
			continue
		staticBody.input_event.connect(_on_mesh_clicked.bind(mesh))
		staticBody.mouse_entered.connect(_on_mesh_mouse_entered.bind(mesh))
		staticBody.mouse_exited.connect(_on_mesh_mouse_exited.bind(mesh))


func calc_data_size(byte_size: int) -> String:
	var unit = "KB"

	# KB
	var size = byte_size / 1024.0

	# MB
	if size > 1024:
		size /= 1024.0
		unit = "MB"

	# GB
	if size > 1024:
		size /= 1024.0
		unit = "GB"

	return "%.2f %s" % [size, unit]


func _set_wireframe(button_pressed):
	if button_pressed:
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
	else:
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED


func _on_mesh_item_selected(tree: Tree):
	var meshItem: TreeItem = tree.get_selected()
	MeshExt.mesh_clear_all_outline()
	MeshExt.mesh_create_outline(meshItem.get_metadata(0))


# One click on a row does what the row is for. These lists used to act on item_activated, which
# needs a double click (or Enter), so every row took two clicks. item_mouse_selected fires on each
# click, including a second click on the row that is already selected.
func _on_row_clicked(_position: Vector2, button: int, act: Callable, tree: Tree) -> void:
	if button == MOUSE_BUTTON_LEFT and tree.get_selected() != null:
		act.call(tree)


# A mesh row: frame the mesh. Its UV viewer stays on a double click and on the details card's button.
func _on_mesh_item_clicked(tree: Tree) -> void:
	var mesh: MeshInstance3D = tree.get_selected().get_metadata(0)
	if mesh != null and mesh.mesh != null:
		GlobalSignal.reposition_camera.emit(mesh.mesh.get_aabb())


func _on_mesh_item_double_clicked(tree: Tree):
	var meshItem: TreeItem = tree.get_selected()
	var mesh: MeshInstance3D = meshItem.get_metadata(0)
	if mesh != null:
		var view := MeshExt.uv_view(mesh)
		if view["lines"].size() > 0:
			GlobalSignal.trigger_texture_viewer.emit(view)

		GlobalSignal.reposition_camera.emit(mesh.mesh.get_aabb())


func _on_material_item_double_clicked(tree: Tree):
	var matItem: TreeItem = tree.get_selected()
	var mat: Material = matItem.get_metadata(0)
	if mat != null and mat is Material:
		if matViewer != null and is_instance_valid(matViewer):   # a closed viewer is a freed object
			matViewer.queue_free()

		matViewer = _card_popup(MaterialViewer.instantiate())
		matViewer.set_material_view(mat)
		# The scene file placed it at (314, 772), below the bottom of a 720 px window. It sits at a fixed
		# spot instead: top left of the free area, right of the information panel.
		var info := get_node_or_null("InfoPanel") as Control
		var left := (info.get_global_rect().end.x if info != null and info.visible else 0.0) + CardStyle.MARGIN
		matViewer.custom_minimum_size = Vector2(373, minf(473.0, get_viewport().size.y - 2.0 * CardStyle.MARGIN))   # the scene's own size, kept on screen
		matViewer.set_anchors_preset(Control.PRESET_TOP_LEFT)
		matViewer.offset_left = left
		matViewer.offset_right = left
		matViewer.offset_top = CardStyle.MARGIN
		matViewer.offset_bottom = CardStyle.MARGIN
		add_child.call_deferred(matViewer)


func _on_texture_double_clicked(tree: Tree):
	var texItem: TreeItem = tree.get_selected()
	var tex: Texture2D = texItem.get_metadata(0)
	if tex != null:
		GlobalSignal.trigger_texture_viewer.emit(tex)


func _on_animation_item_double_clicked(tree: Tree):
	var animItem: TreeItem = tree.get_selected()
	var anim: String = animItem.get_text(0)
	var animationPlayer: AnimationPlayer = animItem.get_metadata(1)[1]
	if animationPlayer != null and animationPlayer.has_animation(anim):
		var player: AnimationPlayer = animationPlayer
		var callable: Callable = Callable(self, "_on_animation_item_finished")
		callable = callable.bind(player, animationPlayers)
		if not player.animation_finished.is_connected(callable):
			player.animation_finished.connect(callable)
		if anim != "RESET":
			playing = [player, anim]
			_apply_loop()
		player.play(anim)
	if anim == "RESET":
		var animation_players: Array[Node] = owner.find_children("*", "AnimationPlayer")
		for node in animation_players:
			if node is AnimationPlayer:
				node.play("RESET")
				node.seek(0, true)
				node.stop()
		var skeletons: Array[Node] = owner.find_children("*", "Skeleton3D")
		for node in skeletons:
			if node is Skeleton3D:
				node.reset_bone_poses()
		var mesh_instances: Array[Node] = owner.find_children("*", "MeshInstance3D")
		for node in mesh_instances:
			if node.get_mesh() is ArrayMesh:
				for i in range(node.get_mesh().get_blend_shape_count()):
					node.set("blend_shapes/" + node.get_mesh().get_blend_shape_name(i), 0)


func _on_motion_item_double_clicked(tree: Tree) -> void:
	var item: TreeItem = tree.get_selected()
	var motion = owner.get("motion")
	if item and motion:
		motion.make(item.get_metadata(0))


# After the motion step reopens the file, play the clip it added (Loop toggle applies).
func _play_after_load() -> void:
	var clip: String = owner.get("play_after_load") if owner.get("play_after_load") else ""
	if clip == "":
		return
	owner.set("play_after_load", "")
	for p in animationPlayers:
		if p is AnimationPlayer and p.has_animation(clip):
			playing = [p, clip]
			_apply_loop()
			p.play(clip)
			print("MOTION-PLAYING %s loop=%s" % [clip, loop_on])
			return


func _set_loop(on: bool) -> void:
	loop_on = on
	_apply_loop()


func _apply_loop() -> void:
	if playing.is_empty() or playing[0] == null or not playing[0].has_animation(playing[1]):
		return
	var a: Animation = playing[0].get_animation(playing[1])
	a.loop_mode = Animation.LOOP_LINEAR if loop_on else Animation.LOOP_NONE


func _on_animation_item_finished(
	animation_name: StringName, player: AnimationPlayer, _players: Array[Node]
):
	for animationPlayer in animationPlayers:
		if animationPlayer == null:
			continue
		for animation in (animationPlayer as AnimationPlayer).get_animation_list():
			animationPlayer.play("RESET")
			animationPlayer.seek(0, true)
			animationPlayer.stop()

	var mesh_instances: Array[Node] = owner.find_children("*", "MeshInstance3D")
	for node in mesh_instances:
		if node is MeshInstance3D and node.get_mesh() is ArrayMesh:
			for i in range(node.get_mesh().get_blend_shape_count()):
				node.set("blend_shapes/" + node.get_mesh().get_blend_shape_name(i), 0)


func _show_texture_viewer(tex):
	if texViewer and not texViewer.is_queued_for_deletion():
		texViewer.queue_free()

	texViewer = _card_popup(TextureViewer.instantiate())
	texViewer.set_draw_data(tex)
	add_child.call_deferred(texViewer)


# addons/model_explode: the model comes apart into its separate shells, moved so none intersect.
func _set_exploded(on: bool) -> void:
	exploded = on
	if on:
		var nodes = []
		nodes.append_array(get_tree().get_nodes_in_group(GlobalSignal.FBX_GROUP))
		nodes.append_array(get_tree().get_nodes_in_group(GlobalSignal.GLTF_GROUP))
		exploder.explode(nodes, get_tree().current_scene)
		exploder.print_layout()
	else:
		exploder.implode()


func _set_grid_hidden(button_pressed):
	if Grid != null:
		Grid.visible = not button_pressed


func _on_mesh_clicked(
	_camera: Node,
	event: InputEvent,
	position: Vector3,
	_normal: Vector3,
	_shape_idx: int,
	mesh: MeshInstance3D
):
	# In walk mode a click walks the model there (MotionMatch.gd); it opens no mesh details.
	if not get_tree().get_nodes_in_group("walk_mode").is_empty():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if meshViewer != null and not meshViewer.is_queued_for_deletion():
			meshViewer.queue_free()

		meshViewer = _card_popup(MeshInfoViewer.instantiate())
		meshViewer.set_mesh(mesh)

		# Docked at a fixed spot, top right, not beside the pointer: it covers none of the model, a
		# second click replaces its contents in place, and it blocks nothing (the camera still works
		# anywhere outside it). The bottom right belongs to the controls card.
		meshViewer.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		meshViewer.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		meshViewer.offset_left = -CardStyle.MARGIN
		meshViewer.offset_right = -CardStyle.MARGIN
		# Below the build label, which holds the top right corner.
		var below := CardStyle.MARGIN
		var owner_node = get_parent()
		if owner_node != null and "version_card" in owner_node and owner_node.version_card != null:
			below = owner_node.version_card.position.y + owner_node.version_card.size.y + 8.0
		meshViewer.offset_top = below
		meshViewer.offset_bottom = below
		_make_room_for(meshViewer)
		add_child.call_deferred(meshViewer)


# The controls card holds the right column below the build label, where the mesh details dock: it steps
# aside while the details show and comes back when they close (if it was showing).
var _card_hidden_for_details := false


func _make_room_for(details: Control) -> void:
	var owner_node = get_parent()
	if owner_node == null or not ("controls_card" in owner_node) or owner_node.controls_card == null:
		return
	var card: Control = owner_node.controls_card
	if card.visible:
		card.visible = false
		_card_hidden_for_details = true
	details.tree_exited.connect(
		func():
			if meshViewer != details and _card_hidden_for_details and is_instance_valid(card):
				pass  # replaced by the next click: the new details keep the card hidden
			elif _card_hidden_for_details and is_instance_valid(card):
				card.visible = true
				_card_hidden_for_details = false
	)


func _on_mesh_mouse_entered(mesh: MeshInstance3D):
	MeshExt.mesh_create_outline(mesh)


func _on_mesh_mouse_exited(mesh: MeshInstance3D):
	MeshExt.mesh_remove_outline(mesh)
