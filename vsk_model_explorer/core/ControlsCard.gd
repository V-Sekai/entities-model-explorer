extends Control
# A card that shows the viewer's controls as pictures: a mouse with the button that does the
# action lit, key caps for the keys, a file for drop. The rows are the controls CamController.gd
# and UIController.gd actually read; keep them in step. The card shows when the viewer starts;
# H hides it and shows it again. Its colours and sizes come from CardStyle.gd, which every other
# control surface uses too.
# ModelExplorer.gd adds the card to every build; a build that adds a control of its own appends a
# row with add_row().

const CardStyle = preload("res://vsk_model_explorer/core/CardStyle.gd")
const ViewerSettings = preload("res://vsk_model_explorer/core/ViewerSettings.gd")
var ROW := 34.0  # a row's height: row_max, or less when the rows would not fit the window
var _two := false  # two columns
var row_max := 34.0  # 44 on a touchscreen: the least a fingertip can hit
const PAD := 14.0
const ICON_W := 40.0
const MARGIN := 16.0
const TOGGLE := 48.0
const COL_W := 300.0  # one column of rows; the card has two when one would not fit the window
# Rows whose key moves the model (the pieces fly apart, the joints swing, the body walks). They sit
# together below a gap, away from the keys that only change how it looks, so a stray tap on a
# wireframe or grid row cannot set the model in motion.
const MOTION := ["E", "F", "M or Start"]
const GAP := 24.0
const FLASH_SECONDS := 0.25
# Keys a tap on a row presses (the row's keys, as the card names them).
const KEYS := {
	"L": KEY_L,
	"W": KEY_W,
	"E": KEY_E,
	"G": KEY_G,
	"X": KEY_X,
	"O": KEY_O,
	"F": KEY_F,
	"M": KEY_M,
	"C": KEY_C,
	"Z": KEY_Z,
	"Space": KEY_SPACE,
	"Esc": KEY_ESCAPE,
	"H": KEY_H
}

var INK: Color
var MUTE: Color
var LIT: Color

# kind: "mouse" (part = left / right / middle / wheel), "keys" (part = key names), "file".
const ROWS := [
	["mouse", "right", "Right-drag", "Orbit"],
	["mouse", "middle", "Middle-drag", "Pan"],
	["mouse", "wheel", "Scroll", "Zoom"],
	["mouse", "left", "Click a mesh", "Mesh details"],
	["keys", ["L"], "L", "Wireframe"],
	["keys", ["G"], "G", "Hide grid"],
	["keys", ["X"], "X", "X-ray"],
	["keys", ["Esc"], "Esc", "Close a popup"],
	["keys", ["E"], "E", "Explode"],
	["file", "", "Drop a file", ".glb .gltf .vrm .usd"],
]

var font: Font
var rows: Array = []
var flash := -1  # the row just tapped
var toggle: Button


func _init() -> void:
	var p := CardStyle.palette()
	INK = p["ink"]
	MUTE = p["mute"]
	LIT = p["lit"]
	for r in ROWS:
		rows.append(r)
	if DisplayServer.is_touchscreen_available():
		row_max = 44.0
		ROW = 44.0
		rows.insert(0, ["touch", "pinch", "Pinch", "Zoom"])
		rows.insert(0, ["touch", "two", "2 finger drag", "Pan"])
		rows.insert(0, ["touch", "one", "1 finger drag", "Orbit"])


# Insert a row above the file-drop row, which stays last.
func add_row(row: Array) -> void:
	var motion: bool = row[0] == "keys" and MOTION.has(row[2])
	var at := rows.size() - 1
	if not motion and _motion_start() >= 0:
		at = _motion_start()  # a row that only changes the look stays above the motion rows
	rows.insert(at, row)
	_fit()
	queue_redraw()


# Pinned to the bottom-right corner, MARGIN px in; the offsets follow the height as rows change.
func _fit() -> void:
	# The card must fit under the build label and above the ? button. Rows shrink to 26 px, and past that
	# the rows go in two columns, rather than let the top of the card run off the window.
	var free := get_viewport_rect().size.y - 2.0 * MARGIN - TOGGLE - 8.0 - 96.0
	var fixed := PAD * 2 + 22 + 18
	var gap := GAP if _motion_start() >= 0 else 0.0
	_two = free - fixed - gap < 26.0 * rows.size()
	ROW = clampf((free - fixed - (0.0 if _two else gap)) / _per_col(), 26.0, row_max)
	custom_minimum_size = Vector2(
		COL_W * (2 if _two else 1), fixed + ROW * _per_col() + (0.0 if _two else gap)
	)
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	offset_right = -MARGIN
	offset_bottom = -MARGIN - TOGGLE - 8.0
	offset_left = -MARGIN - custom_minimum_size.x
	offset_top = -MARGIN - TOGGLE - 8.0 - custom_minimum_size.y


func _ready() -> void:
	font = ThemeDB.fallback_font
	visible = ViewerSettings.get_bool("controls_card", true)  # shown or hidden as it was left
	mouse_filter = Control.MOUSE_FILTER_STOP  # taps on a row press its key; the rest of the screen is untouched
	_fit()
	get_viewport().size_changed.connect(
		func():
			_fit()
			queue_redraw()
	)
	# A touch screen has no H key: a button that stays when the card is hidden.
	toggle = Button.new()
	toggle.text = "?"
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.custom_minimum_size = Vector2(TOGGLE, TOGGLE)
	toggle.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	toggle.offset_right = -MARGIN
	toggle.offset_bottom = -MARGIN
	toggle.offset_left = -MARGIN - TOGGLE
	toggle.offset_top = -MARGIN - TOGGLE
	toggle.pressed.connect(_toggle_shown)
	get_parent().add_child.call_deferred(toggle)


func _toggle_shown() -> void:
	visible = not visible
	ViewerSettings.set_bool("controls_card", visible)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.keycode == KEY_H:
		_toggle_shown()


# Index of the first row that sets the model in motion, or -1.
func _motion_start() -> int:
	for k in rows.size():
		if rows[k][0] == "keys" and MOTION.has(rows[k][2]):
			return k
	return -1


# Where row k starts, with the gap above the motion rows.
func _per_col() -> int:
	return ceili(rows.size() / 2.0) if _two else maxi(rows.size(), 1)


# The x of the column row k is in.
func _row_x(k: int) -> float:
	return floorf(float(k) / _per_col()) * COL_W


func _row_top(k: int) -> float:
	var m := _motion_start()
	var gap := GAP if (m >= 0 and k >= m and not _two) else 0.0
	return PAD + 22.0 + (k % _per_col()) * ROW + gap


func _gui_input(event: InputEvent) -> void:
	# A tap arrives as a mouse click (the engine emulates one from a touch); read the touch itself only when it does not.
	var at := Vector2(-1, -1)
	var mb := event as InputEventMouseButton
	var st := event as InputEventScreenTouch
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		at = mb.position
	elif st and st.pressed and not Input.is_emulating_mouse_from_touch():
		at = st.position
	if at.x < 0:
		return
	var i := -1
	for k in rows.size():
		if (
			at.x >= _row_x(k)
			and at.x < _row_x(k) + COL_W
			and at.y >= _row_top(k)
			and at.y < _row_top(k) + ROW
		):
			i = k
	if i < 0:
		return
	accept_event()
	var r: Array = rows[i]
	if r[0] != "keys" or r[1].is_empty() or not KEYS.has(r[1][-1]):
		return
	flash = i
	queue_redraw()
	await _press(KEYS[r[1][-1]], r[1].size() > 1 and r[1][0] == "Shift")
	await get_tree().create_timer(FLASH_SECONDS).timeout  # the key takes two frames; the highlight must outlast a glance
	if flash == i:
		flash = -1
	queue_redraw()


# Press and release a key as the keyboard would; held for a frame so the actions see it.
func _press(code: int, shift: bool) -> void:
	for down in [true, false]:
		var e := InputEventKey.new()
		e.physical_keycode = code
		e.keycode = code
		e.pressed = down
		e.shift_pressed = shift
		Input.parse_input_event(e)
		await get_tree().process_frame


func _draw() -> void:
	draw_style_box(CardStyle.card_box(), Rect2(Vector2.ZERO, size))
	draw_string(font, Vector2(PAD, PAD + 13), "CONTROLS", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTE)
	var y := PAD + 22.0
	for r in rows:
		var k := rows.find(r)
		y = _row_top(k)
		var xo := _row_x(k)
		if k == flash:
			draw_rect(Rect2(xo + 4, y, COL_W - 8, ROW), Color(LIT, 0.55))
		var c := Vector2(xo + PAD + ICON_W * 0.5, y + ROW * 0.5)
		match r[0]:
			"mouse":
				# Drawn 1.3x about its centre so the lit button reads at a glance.
				draw_set_transform(c * (1.0 - 1.3), 0.0, Vector2(1.3, 1.3))
				_mouse(c, r[1])
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			"keys":
				_key(c, r[1][0])
			"file":
				_file(c)
			"touch":
				_fingers(c, r[1])
		draw_string(
			font,
			Vector2(xo + PAD + ICON_W + 10, y + ROW * 0.5 + 5),
			r[2],
			HORIZONTAL_ALIGNMENT_LEFT,
			110,
			13,
			INK
		)
		draw_string(
			font,
			Vector2(xo + PAD + ICON_W + 124, y + ROW * 0.5 + 5),
			r[3],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			13,
			MUTE
		)
	draw_string(
		font,
		Vector2(PAD, size.y - PAD + 2),
		"H  show or hide this card",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		11,
		MUTE
	)


# A mouse 16x24 seen from above: two buttons and a wheel; the part used is filled.
func _mouse(c: Vector2, part: String) -> void:
	var r := Rect2(c - Vector2(8, 12), Vector2(16, 24))
	var body := StyleBoxFlat.new()
	body.bg_color = Color(1, 1, 1)
	body.border_color = INK
	body.set_border_width_all(1)
	body.set_corner_radius_all(8)
	draw_style_box(body, r)
	var top := r.position.y
	var mid := r.position.x + 8
	# The lit button: its half of the mouse above the split, inside the rounded outline.
	if part == "left":
		draw_colored_polygon(
			PackedVector2Array(
				[
					Vector2(mid, top + 1),
					Vector2(mid, top + 10),
					Vector2(r.position.x + 1, top + 10),
					Vector2(r.position.x + 1, top + 7),
					Vector2(r.position.x + 3, top + 3),
					Vector2(mid - 3, top + 1)
				]
			),
			LIT
		)
	elif part == "right":
		draw_colored_polygon(
			PackedVector2Array(
				[
					Vector2(mid, top + 1),
					Vector2(mid + 3, top + 1),
					Vector2(r.end.x - 3, top + 3),
					Vector2(r.end.x - 1, top + 7),
					Vector2(r.end.x - 1, top + 10),
					Vector2(mid, top + 10)
				]
			),
			LIT
		)
	draw_line(Vector2(mid, top + 1), Vector2(mid, top + 10), INK, 1)
	draw_line(Vector2(r.position.x + 1, top + 10), Vector2(r.end.x - 1, top + 10), INK, 1)
	var wheel := Rect2(mid - 1.5, top + 3, 3, 6)
	draw_rect(wheel, LIT if part in ["middle", "wheel"] else Color(1, 1, 1))
	draw_rect(wheel, INK, false, 1)
	if part == "wheel":
		draw_line(Vector2(c.x + 12, top + 2), Vector2(c.x + 12, top + 10), LIT, 1.5)
		draw_line(Vector2(c.x + 9, top + 5), Vector2(c.x + 12, top + 2), LIT, 1.5)
		draw_line(Vector2(c.x + 15, top + 5), Vector2(c.x + 12, top + 2), LIT, 1.5)
		draw_line(Vector2(c.x + 9, top + 7), Vector2(c.x + 12, top + 10), LIT, 1.5)
		draw_line(Vector2(c.x + 15, top + 7), Vector2(c.x + 12, top + 10), LIT, 1.5)
	elif part in ["right", "middle"]:
		# Drag arrows beside the mouse.
		draw_line(Vector2(c.x + 11, c.y + 6), Vector2(c.x + 19, c.y + 6), LIT, 1.5)
		draw_line(Vector2(c.x + 16, c.y + 3), Vector2(c.x + 19, c.y + 6), LIT, 1.5)
		draw_line(Vector2(c.x + 16, c.y + 9), Vector2(c.x + 19, c.y + 6), LIT, 1.5)


func _key(c: Vector2, label: String) -> void:
	var w := maxf(22.0, font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 10)
	var r := Rect2(c - Vector2(w * 0.5, 11), Vector2(w, 22))
	var cap := StyleBoxFlat.new()
	cap.bg_color = Color(1, 1, 1)
	cap.border_color = INK
	cap.set_border_width_all(1)
	cap.border_width_bottom = 3
	cap.set_corner_radius_all(4)
	draw_style_box(cap, r)
	var ts := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
	draw_string(
		font, Vector2(c.x - ts.x * 0.5, c.y + 3), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK
	)


func _file(c: Vector2) -> void:
	var p := c - Vector2(8, 11)
	var pts := PackedVector2Array(
		[p, p + Vector2(11, 0), p + Vector2(16, 5), p + Vector2(16, 22), p + Vector2(0, 22), p]
	)
	draw_colored_polygon(pts, Color(1, 1, 1))
	draw_polyline(pts, INK, 1)
	draw_line(p + Vector2(11, 0), p + Vector2(11, 5), INK, 1)
	draw_line(p + Vector2(11, 5), p + Vector2(16, 5), INK, 1)
	draw_line(c + Vector2(0, -3), c + Vector2(0, 7), LIT, 1.5)
	draw_line(c + Vector2(-3, 4), c + Vector2(0, 7), LIT, 1.5)
	draw_line(c + Vector2(3, 4), c + Vector2(0, 7), LIT, 1.5)


# Fingers as dots with an arrow: one drag, two drag, or a pinch (arrows toward each other).
func _fingers(c: Vector2, part: String) -> void:
	var dots: Array = [c]
	if part != "one":
		dots = [c + Vector2(-8, 0), c + Vector2(8, 0)]
	for d in dots:
		draw_circle(d, 5.0, INK)
	if part == "pinch":
		draw_line(c + Vector2(-17, 0), c + Vector2(-12, 0), LIT, 1.5)
		draw_line(c + Vector2(17, 0), c + Vector2(12, 0), LIT, 1.5)
	else:
		draw_line(c + Vector2(-2, 12), c + Vector2(14, 12), LIT, 1.5)
		draw_line(c + Vector2(10, 9), c + Vector2(14, 12), LIT, 1.5)
		draw_line(c + Vector2(10, 15), c + Vector2(14, 12), LIT, 1.5)
