extends Control

class_name CustomCanvas

var _drawData


func set_draw_data(data):
	_drawData = data
	queue_redraw()


func _draw():
	if _drawData is ImageTexture:
		draw_texture_rect_region(_drawData, Rect2(Vector2.ZERO, size), Rect2(Vector2.ZERO, _drawData.get_size()))   # size, not get_rect(): that one carries the offset in the parent
	elif _drawData is PackedVector2Array:
		# UV lines on a dark ground inside the 0..1 square (white lines on the white panel showed nothing).
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.09, 0.11, 0.15))
		draw_set_transform(Vector2.ZERO, 0, size)
		draw_multiline(_drawData, Color(0.55, 0.85, 1.0, 0.9))
		draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.5), false, 1.0)
