extends RefCounted

# Runtime state of one VRM spring bone chain.
# A top-level script rather than an inner class of vrm_spring_bone.gd: vrm_secondary.gd
# calls into it, and in godot-sandbox an inner class that extends RefCounted is a
# Dictionary only its own script can call methods on.

const VRMSpringBoneLogic = preload("./vrm_spring_bone_logic.gd")
const vrm_collider_group = preload("./vrm_collider_group.gd")
const VrmColliderRuntime = preload("./vrm_collider_runtime.gd")

# Props
var springbone: VRMSpringBone
var verlets: Array[VRMSpringBoneLogic]
var colliders: Array[VrmColliderRuntime]
var skel: Skeleton3D = null

var has_warned: bool = false
var disable_colliders: bool = false
var gravity_multiplier: float = 1.0
var gravity_rotation: Quaternion = Quaternion.IDENTITY
var add_force: Vector3 = Vector3.ZERO

var joint_nodes: PackedStringArray
var cached_center_bone: String
var cached_center_node: NodePath
var cached_collider_groups: Array[vrm_collider_group]


func _init(this_springbone: VRMSpringBone, skel: Skeleton3D):
	springbone = this_springbone
	joint_nodes = springbone.joint_nodes.duplicate()
	cached_center_bone = springbone.center_bone
	cached_center_node = springbone.center_node
	cached_collider_groups = springbone.collider_groups


func setup(center_transform_inv: Transform3D, force: bool = false):
	#if len(joint_nodes) < 2:
	#if force and not has_warned:
	#has_warned = true
	#push_warning(str(resource_name) + ": Springbone chain has insufficient joints.")
	#return
	if not joint_nodes.is_empty() && skel != null:
		if force || verlets.is_empty():
			if not verlets.is_empty():
				for verlet in verlets:
					verlet.reset(skel)
			verlets.clear()
			for id in range(len(joint_nodes) - 1):
				var verlet: VRMSpringBoneLogic = create_vertlet(id, center_transform_inv)
				verlets.append(verlet)


func create_vertlet(id: int, center_tr_inv: Transform3D) -> VRMSpringBoneLogic:
	var verlet: VRMSpringBoneLogic
	if id < len(joint_nodes) - 1:
		var bone_idx: int = skel.find_bone(joint_nodes[id])
		var pos: Vector3
		if joint_nodes[id + 1].is_empty():
			var delta: Vector3 = skel.get_bone_rest(bone_idx).origin
			pos = delta.normalized() * 0.07
		else:
			var first_child: int = skel.find_bone(joint_nodes[id + 1])
			var local_position: Vector3 = skel.get_bone_rest(first_child).origin
			var sca: Vector3 = skel.get_bone_rest(first_child).basis.get_scale()
			pos = Vector3(
				local_position.x * sca.x, local_position.y * sca.y, local_position.z * sca.z
			)
		verlet = VRMSpringBoneLogic.new(
			skel, bone_idx, center_tr_inv, pos, skel.get_bone_global_pose_no_override(id)
		)
	return verlet


func ready(
	ready_skel: Skeleton3D,
	colliders_ref: Array[VrmColliderRuntime],
	center_transform_inv: Transform3D
) -> void:
	if ready_skel != null:
		skel = ready_skel
	setup(center_transform_inv)
	colliders = colliders_ref.duplicate(false)


func pre_update() -> bool:  # Returns true if the springbone system must be fully reinitialized.
	if Engine.is_editor_hint():
		if (
			len(springbone.joint_nodes) == len(joint_nodes) + 1
			and len(springbone.joint_nodes) >= 2
			and not springbone.joint_nodes[-2].is_empty()
			and springbone.joint_nodes[-1].is_empty()
		):
			if springbone.resource_name.is_empty() and not springbone.joint_nodes[0].is_empty():
				springbone.resource_name = springbone.joint_nodes[0]
			var par_bone := skel.find_bone(springbone.joint_nodes[-2])
			if par_bone != -1:
				var child_bones := skel.get_bone_children(par_bone)
				if not child_bones.is_empty():
					springbone.joint_nodes[-1] = skel.get_bone_name(child_bones[0])
	if (
		springbone.center_bone != cached_center_bone
		or springbone.center_node != cached_center_node
		or springbone.joint_nodes != joint_nodes
		or springbone.collider_groups != cached_collider_groups
	):
		return true
	if not ClassDB.class_exists(&"SkeletonModifier3D"):
		for i in range(len(verlets)):
			verlets[i].pre_update(skel)
	return false


func update(delta: float, center_transform: Transform3D, center_transform_inv: Transform3D) -> void:
	if verlets.is_empty() or len(verlets) != len(springbone.joint_nodes):
		if joint_nodes.is_empty():
			return
		setup(center_transform_inv)

	var tmp_colliders: Array[VrmColliderRuntime]
	if not disable_colliders:
		tmp_colliders = colliders

	for i in range(len(verlets)):
		var pfa: PackedFloat64Array = springbone.gravity_power
		var external: Vector3 = (
			springbone.gravity_dir[i]
			if i < len(springbone.gravity_dir)
			else springbone.gravity_dir_default
		)
		external = (
			external
			* (1.0 if pfa.is_empty() else pfa[i] if i < len(pfa) else pfa[-1])
			* delta
			* springbone.gravity_scale
			* gravity_multiplier
		)
		if !gravity_rotation.is_equal_approx(Quaternion.IDENTITY):
			external = gravity_rotation * external
		if !center_transform.basis.is_equal_approx(Basis.IDENTITY):
			external = center_transform.basis.get_rotation_quaternion().inverse() * external
		external += add_force * delta

		pfa = springbone.stiffness_force
		var stiffness: float = (
			springbone.stiffness_scale
			* (1.0 if pfa.is_empty() else pfa[i] if i < len(pfa) else pfa[-1])
			* delta
		)
		pfa = springbone.drag_force
		var drag_force: float = (
			springbone.drag_force_scale
			* (1.0 if pfa.is_empty() else pfa[i] if i < len(pfa) else pfa[-1])
		)
		pfa = springbone.hit_radius
		verlets[i].radius = (
			springbone.hit_radius_scale
			* (1.0 if pfa.is_empty() else pfa[i] if i < len(pfa) else pfa[-1])
		)

		verlets[i].update(
			skel,
			center_transform,
			center_transform_inv,
			stiffness,
			drag_force,
			external,
			tmp_colliders
		)
