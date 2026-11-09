@tool
class_name VRMCollider
extends Resource

const VrmColliderRuntime = preload("./vrm_collider_runtime.gd")

# Bone name references are only valid within the given Skeleton.
# If the node was not a skeleton, bone is "" and contains a path to the node.
@export var node_path: NodePath:
	set(value):
		node_path = value
		recreate_collider.emit()

# The bone within the skeleton with the collider, or "" if not a bone.
@export var bone: String:
	set(value):
		bone = value
		emit_changed()

@export var offset: Vector3:
	set(value):
		offset = value
		emit_changed()
@export var tail: Vector3:  # if is_capsule
	set(value):
		tail = value
		emit_changed()
@export var radius: float:
	set(value):
		radius = value
		emit_changed()

@export var is_capsule: bool = false:
	set(value):
		if value != is_capsule:
			is_capsule = value
			recreate_collider.emit()

# (Array, Plane)
# Only use in editor
@export var gizmo_color: Color = Color.MAGENTA

signal recreate_collider


func create_runtime(secondary_node: Node3D, skeleton: Skeleton3D) -> VrmColliderRuntime:
	var node: Node3D = null
	var bone_idx: int = -1
	if node_path != NodePath():
		node = secondary_node.get_node(node_path)
	if node == null and bone != "":
		bone_idx = skeleton.find_bone(bone)
	if node == null and bone_idx == -1:
		push_warning(
			"spring collider: Unable to locate bone " + str(bone) + " or node " + str(node_path)
		)
		node = secondary_node
	return VrmColliderRuntime.new(self, bone_idx, node)

#func _ready(ready_parent: Node3D, ready_skel: Object):
#	self.parent = ready_parent
#	if ready_parent.get_class() == "Skeleton3D":
#		self.skel = ready_skel
#		bone_idx = ready_parent.find_bone(bone)
#	setup()

#func _process():
#	for collider in colliders:
#		collider.update(parent, skel)
