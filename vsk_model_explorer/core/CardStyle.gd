extends RefCounted
# The look of the controls card, shared by every control surface: the information panel, the
# popups (mesh, material, texture), the loading and message panels and the card itself.
# Light card, one hairline border, 8 px corners, ink text, small grey upper-case headings, blue for
# the thing in use. make_theme() builds the Theme that UIController sets on the window, so a Control
# added later takes the look with no code of its own.

const INK := Color(0.13, 0.13, 0.13)
const MUTE := Color(0.46, 0.46, 0.46)
const LINE := Color(0.78, 0.78, 0.76)
const LIT := Color(0.16, 0.47, 0.85)
const CARD := Color(0.985, 0.985, 0.98, 0.94)
const WHITE := Color(1, 1, 1)
const RADIUS := 8
const PAD := 14.0
const MARGIN := 16.0
const TEXT := 13
const HEADING := 11


# The colours for code that draws by hand (ControlsCard.gd). Read them through this call: the web
# build's GDScript compiler turns a constant copied from another script (const A := CardStyle.INK)
# into black.
static func palette() -> Dictionary:
	return {"ink": INK, "mute": MUTE, "lit": LIT}


static func card_box() -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = CARD
	b.border_color = LINE
	b.set_border_width_all(1)
	b.set_corner_radius_all(RADIUS)
	b.set_content_margin_all(PAD)
	return b


# A key cap, as the card draws W, E, G and Esc: white, ink outline, thicker bottom edge.
static func key_box(bg: Color, border: Color) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(1)
	b.border_width_bottom = 3
	b.set_corner_radius_all(4)
	b.content_margin_left = 10
	b.content_margin_right = 10
	b.content_margin_top = 4
	b.content_margin_bottom = 6
	return b


static func _line_below() -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = Color(0, 0, 0, 0)
	b.border_color = LINE
	b.border_width_bottom = 1
	b.content_margin_left = 2
	b.content_margin_top = 10
	b.content_margin_bottom = 6
	return b


static func _flat(c: Color, radius := 0) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = c
	b.set_corner_radius_all(radius)
	return b


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = ThemeDB.fallback_font
	t.default_font_size = TEXT
	var none := StyleBoxEmpty.new()

	t.set_stylebox("panel", "PanelContainer", card_box())
	# The texture viewer's picture area: white, with the same hairline.
	var well := _flat(WHITE, 4)
	well.border_color = LINE
	well.set_border_width_all(1)
	t.set_stylebox("panel", "Panel", well)

	t.set_color("font_color", "Label", INK)

	t.set_stylebox("normal", "Button", key_box(WHITE, INK))
	t.set_stylebox("hover", "Button", key_box(WHITE, LIT))
	t.set_stylebox("pressed", "Button", key_box(LIT, LIT))
	t.set_stylebox("disabled", "Button", key_box(CARD, LINE))
	t.set_stylebox("focus", "Button", none)
	for k in ["font_color", "font_focus_color"]:
		t.set_color(k, "Button", INK)
	t.set_color("font_hover_color", "Button", LIT)
	t.set_color("font_pressed_color", "Button", WHITE)
	t.set_color("font_hover_pressed_color", "Button", WHITE)
	t.set_color("font_disabled_color", "Button", MUTE)

	# Lists sit inside a card, so they have no box of their own. A column title is a section
	# heading like the card's CONTROLS: small, grey, a hairline under it.
	t.set_stylebox("panel", "Tree", none)
	t.set_stylebox("focus", "Tree", none)
	t.set_stylebox("title_button_normal", "Tree", _line_below())
	t.set_stylebox("title_button_hover", "Tree", _line_below())
	t.set_stylebox("title_button_pressed", "Tree", _line_below())
	t.set_color("title_button_color", "Tree", MUTE)
	t.set_font_size("title_button_font_size", "Tree", HEADING)
	t.set_color("font_color", "Tree", INK)
	t.set_color("font_hovered_color", "Tree", LIT)
	t.set_color("font_selected_color", "Tree", LIT)
	t.set_color("guide_color", "Tree", Color(LINE, 0.6))
	t.set_stylebox("selected", "Tree", _flat(Color(LIT, 0.12), 4))
	t.set_stylebox("selected_focus", "Tree", _flat(Color(LIT, 0.12), 4))
	t.set_stylebox("hovered", "Tree", _flat(Color(INK, 0.05), 4))
	t.set_stylebox("cursor", "Tree", none)
	t.set_stylebox("cursor_unfocused", "Tree", none)
	t.set_constant("v_separation", "Tree", 10)
	t.set_constant("item_margin", "Tree", 8)
	t.set_constant("inner_item_margin_left", "Tree", 4)
	t.set_constant("draw_guides", "Tree", 1)

	# Thin scroll bars: a hairline track and a grey thumb.
	for sb in ["VScrollBar", "HScrollBar"]:
		var track := _flat(Color(LINE, 0.35), 3)
		track.set_content_margin_all(3)
		t.set_stylebox("scroll", sb, track)
		t.set_stylebox("scroll_focus", sb, track)
		t.set_stylebox("grabber", sb, _flat(Color(MUTE, 0.6), 3))
		t.set_stylebox("grabber_highlight", sb, _flat(MUTE, 3))
		t.set_stylebox("grabber_pressed", sb, _flat(LIT, 3))
	return t


# Turn a Label into a section heading like the card's CONTROLS.
static func heading(l: Label) -> void:
	l.text = l.text.to_upper()
	l.label_settings = null
	l.add_theme_font_size_override("font_size", HEADING)
	l.add_theme_color_override("font_color", MUTE)
