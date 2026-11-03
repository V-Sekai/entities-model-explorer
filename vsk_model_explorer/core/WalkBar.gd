extends HBoxContainer
# Three buttons for walk mode and its obstacle course, so none of it needs a keyboard: Walk (M), Course
# (O) and Grid (Shift+G, the metric grid). Bottom centre, 48 px tall, never in the way: it blocks only the
# pixels it covers. Each button mirrors its state (lit while on), so the bar also says what is on.
# It appears when walk mode is available (mm.elf and the clips), as the controls card's walk rows do.
const CardStyle = preload("res://vsk_model_explorer/core/CardStyle.gd")
const HEIGHT := 48.0
var move: Node  # MotionMatch.gd
var _walk: Button
var _course: Button
var _grid: Button


func _ready() -> void:
	theme = CardStyle.make_theme()
	add_theme_constant_override("separation", 8)
	_walk = _button("Walk", "M: the open rig walks (WASD, or click the floor)")
	_course = _button("Course", "O: the obstacle course")
	_grid = _button("Grid", "Shift+G: the metric grid")
	_walk.toggled.connect(_on_walk)
	_course.toggled.connect(_on_course)
	_grid.toggled.connect(_on_grid)


func _on_walk(on: bool) -> void:
	if move.on != on:
		move.toggle()


func _on_course(on: bool) -> void:
	if move.course:
		move.course.set_on(on)


func _on_grid(on: bool) -> void:
	if move.grid:
		move.grid.set_on(on)


func _button(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(96, HEIGHT)
	add_child(b)
	return b


# The buttons follow the state, whichever way it was changed (key, button, stop).
func _process(_delta: float) -> void:
	# Bottom centre, placed from the window and the bar's own size each frame (anchors left it at the
	# window's left edge, half off screen, because the bar's width is not known when they are applied).
	var window := get_viewport_rect().size
	position = Vector2((window.x - size.x) * 0.5, window.y - CardStyle.MARGIN - HEIGHT)
	if move == null:
		return
	_walk.set_pressed_no_signal(move.on)
	_course.visible = move.course != null
	_grid.visible = move.grid != null
	if move.course:
		_course.set_pressed_no_signal(move.course.visible)
	if move.grid:
		_grid.set_pressed_no_signal(move.grid.visible)
