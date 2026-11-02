extends Node3D

const ZOOM_FACTOR = 1.2
const ROTATE_SPEED = 0.1
const PAN_SPEED = 0.005
const TOUCH_PINCH_SLOP = 8.0  # px; a pinch moving less than this is a tap, not a zoom.

# Touch state: which fingers are down, and their last screen positions. A two-finger
# pinch/pan and a one-finger orbit are the camera's touch controls (the mouse uses
# right/middle-drag and scroll, and neither fires on a touch-only surface).
var _touch_pos: Dictionary = {}
var _last_pinch_dist: float = 0.0
var _last_two_center: Vector2 = Vector2.ZERO
var _last_single_pos: Vector2 = Vector2.ZERO

const MAX_SCALE = 20.0
const MIN_SCALE = 0.05

@export var UiNode: Control

@onready var CamRotHelper = $CamRotHelper

var enable_cam_control: bool = true


func _ready():
	var _discard = UiNode.connect("mouse_entered", _ui_mouse_entered)
	_discard = UiNode.connect("mouse_exited", _ui_mouse_exited)

	GlobalSignal.reposition_camera.connect(_on_reposition_camera)


func _ui_mouse_entered():
	enable_cam_control = false


func _ui_mouse_exited():
	enable_cam_control = true


func _on_reposition_camera(aabb: AABB):
	if aabb.size.length() > 0:
		scale = Vector3.ONE * (aabb.size.length() * 0.2)
	else:
		scale = Vector3.ONE

	rotation = Vector3.ZERO
	CamRotHelper.rotation = Vector3.ZERO


func _unhandled_input(event):
	if not enable_cam_control:
		return

	# Mouse path (unchanged): right-drag orbits, middle-drag pans, scroll zooms.
	if event is InputEventMouseMotion:
		if event.button_mask == MOUSE_BUTTON_MASK_RIGHT:
			# Rotate
			self.rotate_y(deg_to_rad(-1 * event.get_relative().x * ROTATE_SPEED))
			CamRotHelper.rotate_x(deg_to_rad(-1 * event.get_relative().y * ROTATE_SPEED))

			#Stop rotation over top or bottom
			var camera_rot = CamRotHelper.rotation
			camera_rot.x = clamp(camera_rot.x, -90, 90)
			CamRotHelper.rotation = camera_rot
		elif event.button_mask == MOUSE_BUTTON_MASK_MIDDLE:
			# Pan, the same direction as the two-finger pan below
			var rel: Vector2 = event.get_relative()
			_translate(Vector3(-rel.x * PAN_SPEED, rel.y * PAN_SPEED, 0.0))
	elif event is InputEventMouseButton and event.is_pressed():
		# Zoom
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1.0 / ZOOM_FACTOR)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(ZOOM_FACTOR)
	else:
		# Touch path: one-finger drag orbits, two-finger pinch zooms, two-finger
		# pan translates.
		if event is InputEventScreenTouch:
			_touch(event)


func _zoom(factor: float):
	var new_scale := scale * factor
	new_scale = _clamp_scale(new_scale)
	scale = new_scale  # scale_object_local multiplies, so it squared the scale and zoomed out did nothing from 1.2


func _clamp_scale(scale: Vector3) -> Vector3:
	var s := scale.x
	s = clamp(s, MIN_SCALE, MAX_SCALE)
	return Vector3(s, s, s)


func _touch(event: InputEventScreenTouch):
	var idx := event.index
	if event.position.y == -1.0:
		# Finger lifted. Remove it from the active set and re-baseline what is left
		# so the remaining finger (or none) continues without a jump.
		_touch_pos.erase(idx)
		if _touch_pos.size() == 0:
			_last_single_pos = Vector2.ZERO
			_last_pinch_dist = 0.0
		elif _touch_pos.size() == 1:
			# We went from two to one finger: reset the single-finger reference to
			# the remaining finger's position (no pinning the pinch state).
			var p: int = _touch_pos.keys()[0]
			_last_single_pos = _touch_pos[p]
		_touch_gesture()
	else:
		_touch_pos[event.index] = event.position
		_touch_gesture()


# Compute and apply the gesture from the current set of active touch positions.
func _touch_gesture():
	var pts: Array = _touch_pos.values()
	if pts.size() == 0:
		return
	if pts.size() == 1:
		# One finger down: orbit by the delta since the last frame with that finger.
		# Ignore the very first frame (delta ~0) and small moves (a tap).
		var now: Vector2 = pts[0]
		var delta := now - _last_single_pos
		if delta.length() > 1.0:
			_orbit(delta.x, delta.y)
			_last_single_pos = now
		return
	# Two fingers: pinch (zoom) and two-finger pan (translate) from the midpoint.
	var dist: float = pts[0].distance_to(pts[1])
	var center: Vector2 = (pts[0] + pts[1]) * 0.5
	if _last_pinch_dist <= 1.0:
		# First time we have two fingers; baseline the pinch and center.
		_last_pinch_dist = dist
		_last_two_center = center
		return
	# Zoom by how far the two fingers moved closer or farther apart.
	if dist > 1.0 and _last_pinch_dist > 1.0:
		var pinch_factor := _last_pinch_dist / dist
		_zoom(pinch_factor)
	_last_pinch_dist = dist
	# Pan by how far the two-finger midpoint moved (opposite of the camera's pan,
	# so the model follows the finger direction, like the middle-drag pan).
	var pan_delta := center - _last_two_center
	_last_two_center = center
	if pan_delta.length() > 0.0:
		_translate(Vector3(-pan_delta.x * PAN_SPEED, pan_delta.y * PAN_SPEED, 0.0))


func _orbit(dx: float, dy: float):
	# Same convention as the right-drag: move the camera around the model.
	self.rotate_y(deg_to_rad(-1 * dx * ROTATE_SPEED))
	CamRotHelper.rotate_x(deg_to_rad(-1 * dy * ROTATE_SPEED))
	var camera_rot: Vector3 = CamRotHelper.rotation
	camera_rot.x = clamp(camera_rot.x, -90, 90)
	CamRotHelper.rotation = camera_rot


func _translate(translate: Vector3):
	self.translate(translate)


func _on_root_gltf_is_loaded(_success, _gltf):
	# Reset camera local scale
	scale = Vector3.ONE
	rotation.y = 0
	CamRotHelper.rotation.x = 0
