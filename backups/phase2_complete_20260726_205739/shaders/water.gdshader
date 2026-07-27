shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Река. На референсе она почти чёрная и зеркальная — отражает мосты и город
// на дальнем берегу. Волны мелкие, только чтобы отражение «дышало».

uniform vec3 deep_color : source_color = vec3(0.006, 0.010, 0.019);
uniform float wave_scale = 0.09;
uniform float wave_speed = 0.06;
uniform float wave_strength : hint_range(0.0, 1.0) = 0.22;
uniform float rain_ripples : hint_range(0.0, 1.0) = 0.35;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 wp = world.xz;

	float t = TIME * wave_speed;
	float n1 = vnoise(wp * wave_scale + vec2(t, t * 0.6));
	float n2 = vnoise(wp * wave_scale * 2.7 - vec2(t * 0.8, t));

	// Кольца от капель дождя.
	float ripple = 0.0;
	if (rain_ripples > 0.001) {
		vec2 cell = floor(wp * 0.5);
		float phase = fract(TIME * 0.9 + hash12(cell));
		float r = length(fract(wp * 0.5) - 0.5);
		ripple = smoothstep(0.02, 0.0, abs(r - phase * 0.5)) * (1.0 - phase) * rain_ripples;
	}

	vec2 slope = vec2(n1 - n2, n2 - n1) * wave_strength + vec2(ripple * 0.3);
	NORMAL = normalize(NORMAL + vec3(slope.x, 0.0, slope.y));

	ALBEDO = deep_color;
	ROUGHNESS = 0.02 + ripple * 0.25;
	METALLIC = 0.15;
	SPECULAR = 0.95;
}
