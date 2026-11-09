@tool
class_name VRMSpringBone
extends Resource

const VRMSpringBoneLogic = preload("./vrm_spring_bone_logic.gd")
const vrm_collider_group = preload("./vrm_collider_group.gd")
const SpringBoneRuntimeState = preload("./vrm_spring_bone_runtime.gd")

# Annotation comment
@export var comment: String

@export_group("Bone List (End bone may be left blank)")
# bone name of the root bone of the swaying object, within skeleton.
@export var joint_nodes: PackedStringArray

@export_group("Spring Settings")
@export_range(0, 10, 0.001, "or_greater") var stiffness_scale: float = 1.0

@export_range(0, 3, 0.001, "or_greater") var drag_force_scale: float = 1.0

@export_range(0, 1, 0.001, "or_greater") var hit_radius_scale: float = 1.0

@export_range(-10, 10, 0.001, "or_lesser", "or_greater") var gravity_scale: float = 1.0

@export var gravity_dir_default: Vector3 = Vector3(0, -1, 0)

# Reference to the vrm_collidergroup for collisions with swaying objects.
@export var collider_groups: Array[vrm_collider_group]

@export_group("Per-Joint Bone Settings (Optional)")
# The resilience of the swaying object (the power of returning to the initial pose).
@export var stiffness_force: PackedFloat64Array
# The strength of gravity.
@export var gravity_power: PackedFloat64Array
# The direction of gravity. Set (0, -1, 0) for simulating the gravity.
# Set (1, 0, 0) for simulating the wind.
@export var gravity_dir: PackedVector3Array
# The resistance (deceleration) of automatic animation.
@export var drag_force: PackedFloat64Array
# The radius of the sphere used for the collision detection with colliders.
@export var hit_radius: PackedFloat64Array

@export_group("Frame of Reference Node")
# The reference point of a swaying object can be set at any location except the origin.
# When implementing UI moving with warp, the parent node to move with warp can be
# specified if you don't want to make the object swaying with warp movement.",
# Exactly one of the following must be set.
@export var center_bone: String = ""
@export var center_node: NodePath = NodePath()


func create_runtime(skel: Skeleton3D) -> SpringBoneRuntimeState:
	return SpringBoneRuntimeState.new(self, skel)
