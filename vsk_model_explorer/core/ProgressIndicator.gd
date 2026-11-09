extends TextureProgressBar


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	radial_initial_angle += 10.0
	if radial_initial_angle > 360.0:
		radial_initial_angle = 0.0
