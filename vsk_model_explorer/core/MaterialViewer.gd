extends PanelContainer

@onready var BtnClose: Button = $VBoxContainer/HBoxContainer/Button
@onready var MatNameLabel: Label = $VBoxContainer/HBoxContainer/MarginContainer/Label
@onready var MatTree: Tree = $VBoxContainer/Tree

var materialView: Material


func set_material_view(mat: Material):
	materialView = mat


# Called when the node enters the scene tree for the first time.
func _ready():
	BtnClose.pressed.connect(_on_btn_close_pressed)
	MatTree.item_mouse_selected.connect(_on_property_clicked.bind(MatTree))   # one click opens a texture, as in the left column

	if materialView != null:
		MatNameLabel.text = materialView.resource_name

		_setup_material_property(materialView)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	if Input.is_action_just_pressed("close_popup"):
		queue_free()


func _on_btn_close_pressed():
	queue_free()


func _on_property_clicked(_position: Vector2, button: int, tree: Tree) -> void:
	if button == MOUSE_BUTTON_LEFT and tree.get_selected() != null:
		_on_material_property_double_clicked(tree)


func _on_material_property_double_clicked(tree: Tree):
	var item: TreeItem = tree.get_selected()
	var tex = item.get_metadata(1)
	if tex != null:
		GlobalSignal.trigger_texture_viewer.emit(tex)


func _create_property(root: TreeItem, pname: String, value):
	if value == null:
		return

	var item: TreeItem = MatTree.create_item(root)
	item.set_text(0, pname)

	if value is Texture2D or value is ImageTexture:
		var img = value.get_image() as Image
		img.resize(50, 50)
		item.set_icon(1, ImageTexture.create_from_image(img))
		item.set_metadata(1, value)
	elif value is Image:
		var img = value as Image
		img.resize(50, 50)
		item.set_icon(1, ImageTexture.create_from_image(img))
		item.set_metadata(1, value)
	elif value is Color:
		var img = Image.create(50, 20, false, Image.FORMAT_RGBA8)
		img.fill(value)
		item.set_icon(1, ImageTexture.create_from_image(img))
	elif value is Plane:
		var plane: Plane = value as Plane
		if pname.to_lower().find("color") != -1:
			var img: Image = Image.create(50, 20, false, Image.FORMAT_RGBA8)
			img.fill(Color(plane.x, plane.y, plane.z, plane.d))
			item.set_icon(1, ImageTexture.create_from_image(img))
		else:
			var vector_4: Vector4 = Vector4(plane.x, plane.y, plane.z, plane.d)
			item.set_text(1, "%s" % vector_4)
	else:
		item.set_text(1, "%s" % value)


func _setup_material_property(mat: Material):
	var root = MatTree.create_item()

	if mat is StandardMaterial3D:
		_create_property(root, "albedo", mat.albedo_color)
		_create_property(root, "albedo texture", mat.albedo_texture)
		_create_property(root, "rough/metal", Vector2(mat.roughness, mat.metallic))
		_create_property(root, "rough/metal texture", mat.roughness_texture)
		_create_property(root, "emission", mat.emission)
		_create_property(root, "emission texture", mat.emission_texture)
		_create_property(root, "transparency", mat.transparency)
		_create_property(root, "normal map", mat.normal_texture)
		_create_property(root, "height map", mat.heightmap_texture)
	elif mat is ShaderMaterial:
		var parameters: Array[String] = [
			"_Cutoff",
			"_Color",
			"_ShadeColor",
			"_MainTex",
			"_MainTex_ST",
			"_ShadeTexture",
			"_BumpScale",
			"_BumpMap",
			"_ReceiveShadowTexture",
			"_ReceiveShadowRate",
			"_ShadingGradeTexture",
			"_ShadingGradeRate",
			"_ShadeShift",
			"_ShadeToony",
			"_LightColorAttenuation",
			"_IndirectLightIntensity",
			"_RimTexture",
			"_RimColor",
			"_RimLightingMix",
			"_RimFresnelPower",
			"_RimLift",
			"_SphereAdd",
			"_EmissionColor",
			"_AlphaCutoutEnable",
		]
		for parameter_name in parameters:
			var parameter: Variant = (mat as ShaderMaterial).get_shader_parameter(parameter_name)
			var capitalized_parameter_name = parameter_name.capitalize()
			_create_property(root, capitalized_parameter_name, parameter)
