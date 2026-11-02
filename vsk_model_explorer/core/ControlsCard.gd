extends Control
# A card that shows the viewer's controls as pictures: a mouse with the button that does the
# action lit, key caps for the keys, a file for drop. The rows are the controls CamController.gd
# and UIController.gd actually read; keep them in step. The card shows when the viewer starts;
# H hides it and shows it again. Its colours and sizes come from CardStyle.gd, which every other
# control surface uses too.
# ModelExplorer.gd adds the card to every build; a build that adds a control of its own appends a
# row with add_row().

const CardStyle = preload("res://vsk_model_explorer/core/CardStyle.gd")
const ROW := 34.0
const PAD := 14.0
const ICON_W := 40.0
const MARGIN := 16.0

var INK: Color
var MUTE: Color
var LIT: Color

# kind: "mouse" (part = left / right / middle / wheel), "keys" (part = key names), "file".
const ROWS := [
	["mouse", "right", "Right-drag", "Orbit"],
	["mouse", "middle", "Middle-drag", "Pan"],
	["mouse", "wheel", "Scroll", "Zoom"],
	["mouse", "left", "Click a mesh", "Mesh details"],
	["keys", ["W"], "W", "Wireframe"],
	["keys", ["E"], "E", "Explode"],
	["keys", ["G"], "G", "Hide grid"],
	["keys", ["Esc"], "Esc", "Close a popup"],
	["file", "", "Drop a file", ".glb .gltf .vrm .usd"],
]

var font: Font
var rows: Array = []


func _init() -> void:
	var p := CardStyle.palette()
	INK = p["ink"]
	MUTE = p["mute"]
	LIT = p["lit"]
	for r in ROWS:
		rows.append(r)


# Insert a row above the file-drop row, which stays last.
func add_row(row: Array) -> void:
	rows.insert(rows.size() - 1, row)
	_fit()
	queue_redraw()


# Pinned to the bottom-right corner, MARGIN px in; the offsets follow the height as rows change.
func _fit() -> void:
	custom_minimum_size = Vector2(300, PAD * 2 + 22 + ROW * rows.size() + 18)
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	offset_right = -MARGIN
	offset_bottom = -MARGIN
	offset_left = -MARGIN - custom_minimum_size.x
	offset_top = -MARGIN - custom_minimum_size.y


func _ready() -> void:
	font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fit()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.keycode == KEY_H:
		visible = not visible


func _draw() -> void:
	draw_style_box(CardStyle.card_box(), Rect2(Vector2.ZERO, size))
	draw_string(font, Vector2(PAD, PAD + 13), "CONTROLS", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTE)
	var y := PAD + 22.0
	for r in rows:
		var c := Vector2(PAD + ICON_W * 0.5, y + ROW * 0.5)
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
		draw_string(
			font,
			Vector2(PAD + ICON_W + 10, y + ROW * 0.5 + 5),
			r[2],
			HORIZONTAL_ALIGNMENT_LEFT,
			110,
			13,
			INK
		)
		draw_string(
			font,
			Vector2(PAD + ICON_W + 124, y + ROW * 0.5 + 5),
			r[3],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			13,
			MUTE
		)
		y += ROW
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
