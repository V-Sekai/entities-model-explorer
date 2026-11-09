// Grid balls from V-Sekai xr-grid (addons/procedural_3d_grid, MIT, commit ff71e92): a lattice of
// camera-facing dots with short axis ticks, faded out around a focus point.
// Changed: the lattice snaps to the focus point rather than the camera, so an orbit camera far from
// the model still sees the balls around it.
shader_type spatial;

render_mode unshaded;
render_mode skip_vertex_transform;

// Fix for double precision
#define INV_VIEW_MATRIX inverse(VIEW_MATRIX)

uniform float _PointRadius = .02;
uniform vec3 _GridCenter = vec3(0,0,0);

uniform vec4 _Color : source_color = vec4(0,0,0,1);

uniform float _NearFade = .5;
uniform float _FarFade = .5;
uniform float _FadeZone = .5;
uniform vec3 _FocusPoint = vec3(0,0,0);


vec3 xform(mat4 m, vec3 p, const int w){return (m * vec4(p,float(w))).xyz;}

// Calculates line billboard in view space
mat4 getLineBillboard(vec3 a,vec3 b){
    mat4 billboard = mat4(1);
    billboard[0].xyz = (b-a)/2.;
    billboard[1].xyz = normalize( cross(b,a) );
    billboard[2].xyz = normalize( cross(billboard[0].xyz, billboard[1].xyz) );
    billboard[3].xyz = (b+a)/2.;
    return billboard;
}

float computeOpacity(mat4 worldToView, vec3 viewSpacePos, float baseOpacity)
{
    float focus_point_distance = distance(viewSpacePos, xform(worldToView, _FocusPoint, 1));
    float opacity = baseOpacity;
    if (focus_point_distance > _FarFade)
    {
        opacity *= clamp(1.0 + (_FarFade - focus_point_distance) / _FadeZone, 0.0, 1.0);
    }

    float depth = viewSpacePos.z * -1.0;
    if (depth < _NearFade)
    {
        opacity *= clamp(-_FadeZone + depth / _NearFade, 0.0, 1.0);
    }

    return opacity;
}

void handlePoint(vec3 pos, mat4 worldToView, inout mat4 modelToView){
	modelToView[0].xyz = vec3(_PointRadius, 0, 0);
	modelToView[1].xyz = vec3(0, _PointRadius, 0);
	modelToView[2].xyz = vec3(0, 0, _PointRadius);
	modelToView[3].xyz = xform(worldToView, pos, 1);
}

void handleLine(vec3 pos, vec3 normal, mat4 worldToView, inout mat4 modelToView){
	float lineWidth = _PointRadius * 0.3;

	pos = xform(worldToView, pos, 1);

	normal = mat3(modelToView) * normal;

	modelToView = getLineBillboard(pos, pos+normal*2.0);
	modelToView[1].xyz *= lineWidth;
}

vec3 getGridSnapOffset(mat4 modelToWorld, vec3 world_snap_pos){
	modelToWorld[3].xyz = _GridCenter;
	vec3 offset = floor( xform(inverse(modelToWorld), world_snap_pos, 1) );
	return xform(modelToWorld, offset, 0);
}

void vertex(){
	COLOR = _Color;

	vec3 world_pos = MODEL_MATRIX[3].xyz + getGridSnapOffset(MODEL_MATRIX, _FocusPoint);

	mat4 eye_matrix = VIEW_MATRIX;
	eye_matrix[3].xyz -= EYE_OFFSET;
	MODELVIEW_MATRIX[3].xyz -= EYE_OFFSET;

	if(UV.x < 0.5){
		handlePoint(world_pos, eye_matrix, MODELVIEW_MATRIX);
		UV.x = dot(VERTEX,VERTEX);
	}
	else{
		handleLine(world_pos, NORMAL, eye_matrix, MODELVIEW_MATRIX);
		COLOR.a *= .4;
		UV.x = VERTEX.y * 2.0;
	}

	MODELVIEW_MATRIX[3].xyz += EYE_OFFSET;

	VERTEX = xform(MODELVIEW_MATRIX, VERTEX, 1);

	COLOR.a = computeOpacity(VIEW_MATRIX, VERTEX, COLOR.a);
}

void fragment(){
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;

	// Anti-aliasing
	ALPHA *= clamp( (1.0-abs(UV.x))/fwidth(UV.x), 0.0, 1.0);
}
