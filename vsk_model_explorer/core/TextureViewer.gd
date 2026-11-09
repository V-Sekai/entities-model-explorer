extends PanelContainer

@onready var BtnClose: Button = $Row/HBoxContainer/Button
@onready var Canvas = $Row/Panel/Canvas

var _draw_data


# Called when the node enters the scene tree for the first time.
func _ready():
	# Square, as large as the window allows (it was a fixed 800 px, taller than a 720 px window).
	custom_minimum_size = Vector2.ONE * clampf(get_viewport_rect().size.y - 96.0, 240.0, 800.0)
	BtnClose.pressed.connect(_on_btn_close_pressed)
	Canvas.set_draw_data(_draw_data)


func _process(_delta):
	if Input.is_action_just_released("close_popup"):
		queue_free()


func set_draw_data(data):
	_draw_data = data


func _on_btn_close_pressed():
	queue_free()
