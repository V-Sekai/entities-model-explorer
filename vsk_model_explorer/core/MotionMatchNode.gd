extends AnimationNodeExtension
# The motion-matching node of walk mode's AnimationTree. Each tree update it steps mm.elf
# (interactor-motion-matching-guest) by the frame time with the controller's input, and plays the
# clip frame mm.elf picks, alone and at full weight: a new pick replaces the previous clip at once,
# with no cross-fade, so every frame shows one clip under its own root turn.
# MotionMatch.gd sets the input fields before it advances the tree, and reads the output fields
# after.

# Set once.
var mm: Node
var names: PackedStringArray = []  # animation name of each mm.elf clip index
var lengths := PackedFloat32Array()  # its length in seconds
var loops := PackedByteArray()  # 1 for a loop (plays on through its seam), 0 for a one-shot
# Input, set before each advance. Velocity is in SOMA metres a second.
var velocity := Vector2.ZERO
var mode := 0
var jump := false
# With jump: the shortest flight in centimetres (SOMA metres x 100) the jump must cover, 0 for the best fitting take-off.
var jump_len_cm := 0
# Output of the last step.
var clip := -1
var time := 0.0
var result := PackedFloat32Array()
var seams := 0  # loop seams played through without a seek


func reset() -> void:
	clip = -1
	result = PackedFloat32Array()


func _process_animation_node(
	playback_info: PackedFloat64Array, test_only: bool
) -> PackedFloat32Array:
	var delta: float = playback_info[1]
	var info := PackedFloat32Array([0.0, time, delta, Animation.LOOP_NONE, 0.0, 1.0])
	if test_only or mm == null or delta <= 0.0:
		return info
	var r: PackedFloat32Array = mm.vmcall(
		"mm_step", delta, velocity.x, velocity.y, NAN, mode, (maxi(jump_len_cm, 1) if jump else 0)
	)
	jump = false
	jump_len_cm = 0
	if r.size() < 15:
		return info
	result = r
	var picked := int(r[0])
	var t := float(r[1])
	var seeked := false
	# mm.elf wraps a loop's time at its seam: that is play going on, not a seek.
	var wrapped: bool = (
		picked == clip
		and r[8] <= 0.5
		and is_loop(clip)
		and t < time
		and abs(time + delta - lengths[clip] - t) <= 0.05
	)
	seams += 1 if wrapped else 0
	if picked != clip or r[8] > 0.5:
		clip = picked
		seeked = true
	elif not wrapped and abs(time + delta - t) > 0.05:
		seeked = true
	time = t
	blend_animation(names[clip], t, delta, seeked, false, 1.0)
	info[1] = t
	info[3] = Animation.LOOP_LINEAR if is_loop(clip) else Animation.LOOP_NONE
	return info


func is_loop(i: int) -> bool:
	return i >= 0 and i < loops.size() and loops[i] == 1
