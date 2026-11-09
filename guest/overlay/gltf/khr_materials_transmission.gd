extends GLTFDocumentExtension
# KHR_materials_transmission + KHR_materials_volume + KHR_materials_ior for the viewer:
# see-through materials (glass, liquids, film).
#
# Godot's glTF importer does not know these extensions, so a file that lists one under
# extensionsRequired (Khronos CommercialRefrigerator) was refused before anything loaded.
# Registering this class makes Godot accept those files. After parsing, every glTF material
# with a transmission factor above 0 is swapped for a ShaderMaterial (SHADER_CODE below) that
# copies the StandardMaterial3D the importer made and adds transmission: the scene behind the
# surface (Godot's screen texture), tinted by the base colour and blurred by roughness.
#
# Thin-walled (no volume, or thicknessFactor 0): light passes straight through, no refraction.
# Volume: the view ray is refracted at the surface (IOR), walks the material's thickness
# (thicknessFactor x thicknessTexture.g, in the mesh's local units, times the model scale) and
# samples the screen where it leaves; the light is absorbed on the way by Beer-Lambert:
# attenuationColor ^ (distance / attenuationDistance). This follows the Khronos glTF sample
# viewer's approximation: one refraction, thickness taken from the material, not ray marched.
# Fresnel follows the glTF spec: 1 - F (Schlick, F0 from the IOR) of the light enters, at one
# interface; a reference path tracer that also counts the exit interface reads about 4% darker.
#
# Limits: objects that are themselves transparent do not show through, because the screen
# texture is copied after the opaque pass; a refracted ray that leaves the screen reads the edge.

const EXT := "KHR_materials_transmission"
const EXT_VOLUME := "KHR_materials_volume"
const EXT_IOR := "KHR_materials_ior"

const SHADER_CODE := """shader_type spatial;
render_mode blend_mix, depth_draw_opaque, CULL_MODE, diffuse_burley, specular_schlick_ggx;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform bool use_vertex_color = false;
uniform float metallic = 0.0;
uniform float roughness = 1.0;
// glTF metallicRoughnessTexture: roughness in G, metallic in B.
uniform sampler2D mr_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform bool use_normal_tex = false;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale = 1.0;
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 1.0;
uniform sampler2D emission_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
// KHR_materials_transmission: factor x texture.r.
uniform float transmission = 0.0;
uniform sampler2D transmission_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
// KHR_materials_ior.
uniform float ior = 1.5;
// KHR_materials_volume: thickness = factor x texture.g (mesh local units); 0 = thin-walled.
uniform float thickness = 0.0;
uniform sampler2D thickness_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
// Linear RGB. attenuation_distance <= 0 stands for glTF's default of +infinity (no absorption).
uniform vec3 attenuation_color = vec3(1.0);
uniform float attenuation_distance = 0.0;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

varying float model_scale;

void vertex() {
	UV = UV * uv1_scale.xy + uv1_offset.xy;
	model_scale = (length(MODEL_MATRIX[0].xyz) + length(MODEL_MATRIX[1].xyz) + length(MODEL_MATRIX[2].xyz)) / 3.0;
}

vec2 view_to_screen(vec3 p, mat4 proj) {
	vec4 c = proj * vec4(p, 1.0);
	return c.xy / c.w * 0.5 + 0.5;
}

void fragment() {
	vec4 base = albedo * texture(albedo_tex, UV);
	if (use_vertex_color) {
		base *= COLOR;
	}
	vec4 mr = texture(mr_tex, UV);
	float metal = clamp(metallic * mr.b, 0.0, 1.0);
	float rough = clamp(roughness * mr.g, 0.0, 1.0);
	if (use_normal_tex) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
	// Metals do not transmit (glTF spec): the transmitted part is scaled by (1 - metallic).
	float t = clamp(transmission * texture(transmission_tex, UV).r, 0.0, 1.0) * (1.0 - metal);

	// Volume: refract the view ray (view space) and walk the thickness to the exit point.
	// The screen offset is the difference of two projections of the same kind.
	float dist = max(thickness * texture(thickness_tex, UV).g, 0.0) * model_scale;
	vec2 uv = SCREEN_UV;
	if (dist > 0.0) {
		vec3 r = refract(-VIEW, normalize(NORMAL), 1.0 / max(ior, 1.0));
		vec3 exit_p = VERTEX + r * dist;
		uv += view_to_screen(exit_p, PROJECTION_MATRIX) - view_to_screen(VERTEX, PROJECTION_MATRIX);
	}
	// Rough surfaces blur what is behind them; a higher IOR spreads the blur further.
	float lod = rough * 12.0 * clamp(ior - 1.0, 0.0, 1.0);
	vec3 behind = textureLod(screen_tex, clamp(uv, vec2(0.0), vec2(1.0)), lod).rgb;
	// Beer-Lambert absorption along the path inside the volume.
	vec3 absorb = vec3(1.0);
	if (dist > 0.0 && attenuation_distance > 0.0) {
		absorb = pow(max(attenuation_color, vec3(1e-4)), vec3(dist / attenuation_distance));
	}
	// glTF spec: the dielectric layer reflects F (Schlick, F0 from the IOR) and only 1 - F of the
	// light enters, at the one interface the spec models. Godot's own specular lobe draws the
	// reflected part: SPECULAR is set so its F0 (0.16 * SPECULAR^2) equals the glTF F0.
	float f0 = pow((ior - 1.0) / (ior + 1.0), 2.0);
	float fresnel = f0 + (1.0 - f0) * pow(1.0 - clamp(dot(normalize(NORMAL), VIEW), 0.0, 1.0), 5.0);
	ALBEDO = base.rgb * (1.0 - t);
	METALLIC = metal;
	ROUGHNESS = rough;
	SPECULAR = sqrt(f0 / 0.16);
	EMISSION = emission * emission_energy * texture(emission_tex, UV).rgb + behind * absorb * base.rgb * t * (1.0 - fresnel);
}
"""

# One Shader per cull mode (glTF doubleSided -> cull_disabled), shared by every material.
var _shaders := {}


func _get_supported_extensions() -> PackedStringArray:
	return PackedStringArray([EXT, EXT_VOLUME, EXT_IOR])


func _import_preflight(_state: GLTFState, extensions: PackedStringArray) -> Error:
	if extensions.has(EXT) or extensions.has(EXT_VOLUME) or extensions.has(EXT_IOR):
		return OK
	return ERR_SKIP


func _import_post_parse(state: GLTFState) -> Error:
	var json: Dictionary = state.json
	var src: Array = json.get("materials", [])
	var mats: Array = state.get_materials()
	var swap := {}
	for i in range(mini(src.size(), mats.size())):
		var m: Dictionary = src[i]
		var exts: Dictionary = m.get("extensions", {})
		# Volume and IOR only change how transmitted light looks: without transmission the
		# surface is opaque and the importer's StandardMaterial3D is already right.
		if not exts.has(EXT):
			continue
		var tx: Dictionary = exts[EXT]
		var factor: float = float(tx.get("transmissionFactor", 0.0))
		if factor <= 0.0:
			continue
		var old: BaseMaterial3D = mats[i] as BaseMaterial3D
		if old == null:
			continue
		var nm := _transmission_material(
			old, factor, _texture(state, tx.get("transmissionTexture", {}))
		)
		if exts.has(EXT_IOR):
			nm.set_shader_parameter("ior", float((exts[EXT_IOR] as Dictionary).get("ior", 1.5)))
		if exts.has(EXT_VOLUME):
			_apply_volume(state, nm, exts[EXT_VOLUME])
		swap[old.get_instance_id()] = nm
		mats[i] = nm
	if swap.is_empty():
		return OK
	state.set_materials(mats)
	# Meshes were parsed before this hook and already hold the old materials: swap them there.
	for gm in state.get_meshes():
		var mesh: ImporterMesh = (gm as GLTFMesh).mesh
		if mesh == null:
			continue
		for s in range(mesh.get_surface_count()):
			var cur: Material = mesh.get_surface_material(s)
			if cur != null and swap.has(cur.get_instance_id()):
				mesh.set_surface_material(s, swap[cur.get_instance_id()])
		var inst: Array = (gm as GLTFMesh).instance_materials
		var changed := false
		for k in range(inst.size()):
			var im: Material = inst[k]
			if im != null and swap.has(im.get_instance_id()):
				inst[k] = swap[im.get_instance_id()]
				changed = true
		if changed:
			(gm as GLTFMesh).instance_materials = inst
	print("KHR_materials_transmission: ", swap.size(), " material(s)")
	return OK


func _apply_volume(state: GLTFState, m: ShaderMaterial, vol: Dictionary) -> void:
	m.set_shader_parameter("thickness", float(vol.get("thicknessFactor", 0.0)))
	var tt: Texture2D = _texture(state, vol.get("thicknessTexture", {}))
	if tt != null:
		m.set_shader_parameter("thickness_tex", tt)
	# glTF attenuationColor is linear RGB: a plain vec3 uniform, no sRGB hint.
	var ac: Array = vol.get("attenuationColor", [1.0, 1.0, 1.0])
	if ac.size() >= 3:
		m.set_shader_parameter(
			"attenuation_color", Vector3(float(ac[0]), float(ac[1]), float(ac[2]))
		)
	# Absent means +infinity in glTF; 0 tells the shader "no absorption".
	m.set_shader_parameter("attenuation_distance", float(vol.get("attenuationDistance", 0.0)))


func _texture(state: GLTFState, info: Dictionary) -> Texture2D:
	if not info.has("index"):
		return null
	var textures: Array = state.get_textures()
	var ti: int = int(info["index"])
	if ti < 0 or ti >= textures.size():
		return null
	var si: int = (textures[ti] as GLTFTexture).src_image
	var images: Array = state.get_images()
	if si < 0 or si >= images.size():
		return null
	return images[si] as Texture2D


func _shader(cull: String) -> Shader:
	if not _shaders.has(cull):
		var sh := Shader.new()
		sh.code = SHADER_CODE.replace("CULL_MODE", cull)
		_shaders[cull] = sh
	return _shaders[cull]


func _transmission_material(
	old: BaseMaterial3D, factor: float, tx_tex: Texture2D
) -> ShaderMaterial:
	var cull := "cull_back"
	if old.cull_mode == BaseMaterial3D.CULL_DISABLED:
		cull = "cull_disabled"
	var m := ShaderMaterial.new()
	m.shader = _shader(cull)
	m.resource_name = old.resource_name
	m.set_shader_parameter("albedo", old.albedo_color)
	if old.albedo_texture != null:
		m.set_shader_parameter("albedo_tex", old.albedo_texture)
	m.set_shader_parameter("use_vertex_color", old.vertex_color_use_as_albedo)
	m.set_shader_parameter("metallic", old.metallic)
	m.set_shader_parameter("roughness", old.roughness)
	var mr: Texture2D = old.roughness_texture
	if mr == null:
		mr = old.metallic_texture
	if mr != null:
		m.set_shader_parameter("mr_tex", mr)
	if old.normal_enabled and old.normal_texture != null:
		m.set_shader_parameter("use_normal_tex", true)
		m.set_shader_parameter("normal_tex", old.normal_texture)
		m.set_shader_parameter("normal_scale", old.normal_scale)
	if old.emission_enabled:
		m.set_shader_parameter("emission", old.emission)
		m.set_shader_parameter("emission_energy", old.emission_energy_multiplier)
		if old.emission_texture != null:
			m.set_shader_parameter("emission_tex", old.emission_texture)
	m.set_shader_parameter("transmission", factor)
	if tx_tex != null:
		m.set_shader_parameter("transmission_tex", tx_tex)
	m.set_shader_parameter("uv1_scale", old.uv1_scale)
	m.set_shader_parameter("uv1_offset", old.uv1_offset)
	return m
