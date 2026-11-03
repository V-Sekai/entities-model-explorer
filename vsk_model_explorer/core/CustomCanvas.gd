extends Control

class_name CustomCanvas

var _drawData
var _tex: Texture2D   # the mesh's base colour image, drawn under the UV lines


func set_draw_data(data):
	_tex = null
	if data is Dictionary:   # {lines: PackedVector2Array, tex: Texture2D or null}
		_tex = data.get("tex")
		data = data.get("lines")
	_drawData = data
	queue_redraw()


# Up and down are swapped: the image and its UV lines are drawn upside down from the file's own frame
# (glTF, top-left origin), so they read like a UV editor with v pointing up. Both flip together, so
# the lines still sit on the paint they belong to.
func _draw():
	draw_set_transform(Vector2(0, size.y), 0, Vector2(1, -1))
	if _drawData is ImageTexture:
		draw_texture_rect_region(_drawData, Rect2(Vector2.ZERO, size), Rect2(Vector2.ZERO, _drawData.get_size()))   # size, not get_rect(): that one carries the offset in the parent
	elif _drawData is PackedVector2Array:
		# UV lines on a dark ground inside the 0..1 square (white lines on the white panel showed nothing).
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.09, 0.11, 0.15))
		if _tex != null:
			draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false)
		draw_set_transform(Vector2(0, size.y), 0, Vector2(size.x, -size.y))
		draw_multiline(_drawData, Color(0.55, 0.85, 1.0, 0.9))
		draw_set_transform(Vector2(0, size.y), 0, Vector2(1, -1))
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.5), false, 1.0)
	draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
