extends PanelContainer

@onready var CloseButton: Button = $VBoxContainer/HBoxContainer/Button
@onready var TitleLabel: Label = $VBoxContainer/HBoxContainer/MarginContainer/Label
@onready var LbFaceCount: Label = $VBoxContainer/MarginContainer/VBoxContainer/LbFaceCount
@onready var LbPos: Label = $VBoxContainer/MarginContainer/VBoxContainer/LbPos
@onready var LbSize: Label = $VBoxContainer/MarginContainer/VBoxContainer/LbSize
@onready var LbBBox: Label = $VBoxContainer/MarginContainer/VBoxContainer/LbBBox
@onready var BtnViewUV: Button = $VBoxContainer/MarginContainer/VBoxContainer/BtnViewUV

var _mesh: MeshInstance3D


func set_mesh(mesh: MeshInstance3D):
	_mesh = mesh


# Called when the node enters the scene tree for the first time.
func _ready():
	CloseButton.pressed.connect(_on_close_button_pressed)
	BtnViewUV.pressed.connect(_on_btn_viewuv_pressed)

	var shortName: String = String(_mesh.name)
	if shortName.length() > 20:
		shortName = shortName.substr(0, 20)

	TitleLabel.text = shortName
	LbFaceCount.text = "Face count: %d" % MeshExt.face_count(_mesh.mesh)

	LbPos.text = "Pos: %s" % _mesh.position

	var aabbSize = _mesh.mesh.get_aabb().size
	LbBBox.text = "BBox: [%.2f %.2f %.2f]" % [aabbSize.x, aabbSize.y, aabbSize.z]
	LbSize.text = "Size: %.2f" % aabbSize.length()


func _on_close_button_pressed():
	queue_free()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	if Input.is_action_just_pressed("close_popup"):
		queue_free()


func _on_btn_viewuv_pressed():
	var view := MeshExt.uv_view(_mesh)
	if view["lines"].size() > 0:
		GlobalSignal.trigger_texture_viewer.emit(view)
