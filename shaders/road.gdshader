shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Мокрый асфальт. Главный визуальный приём референса — вертикальные отражения
// вывесок в дороге. Их даёт SSR, а наша задача — правильная шероховатость:
// лужи почти зеркальные, сухой асфальт матовый.

uniform vec3 asphalt : source_color = vec3(0.032, 0.038, 0.052);
uniform vec3 marking : source_color = vec3(1.0, 0.63, 0.23);
uniform float wetness : hint_range(0.0, 1.0) = 0.8;
uniform float puddle_scale = 0.055;
uniform float grit_scale = 0.9;
uniform float lane_glow : hint_range(0.0, 4.0) = 0.0;
uniform float lane_pitch = 12.0;
uniform float lane_width = 0.22;
uniform bool lanes_along_x = true;

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
	// Мировые координаты фрагмента: VERTEX во фрагменте — во view-пространстве.
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 wp = world.xz;

	float puddle = smoothstep(0.52, 0.78, vnoise(wp * puddle_scale));
	float grit = vnoise(wp * grit_scale);

	vec3 albedo = asphalt * (0.75 + 0.5 * grit);
	float rough = mix(0.78, 0.03, puddle * wetness);
	float metal = mix(0.0, 0.35, puddle * wetness);

	vec3 emission = vec3(0.0);
	if (lane_glow > 0.001) {
		// Янтарная разметка магистрали — те самые светящиеся диагонали с референса.
		float axis = lanes_along_x ? wp.x : wp.y;
		float across = lanes_along_x ? wp.y : wp.x;
		float dash = step(0.45, fract(axis / 6.0));
		float line = 1.0 - smoothstep(lane_width, lane_width * 1.8, abs(fract(across / lane_pitch + 0.5) - 0.5) * lane_pitch);
		emission = marking * line * dash * lane_glow;
		albedo = mix(albedo, marking * 0.25, line * dash * 0.5);
	}

	ALBEDO = albedo;
	EMISSION = emission;
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = mix(0.32, 0.95, puddle * wetness);
}
