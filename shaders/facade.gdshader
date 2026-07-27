shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Фасад здания целиком процедурный: окна, витрины первого этажа, подтёки дождя.
// Текстур в проекте нет намеренно — это даёт нулевой вес ассетов и позволяет
// рисовать тысячи зданий одним MultiMesh'ем.
//
// Данные приходят из MultiMesh:
//   COLOR.rgb      — неоновый оттенок района (CityAtlas.district_palette)
//   INSTANCE_CUSTOM.x — сид здания (0..1)
//   INSTANCE_CUSTOM.y — доля светящихся окон (0..1)
//   INSTANCE_CUSTOM.z — насколько окна уходят в неон района вместо тёплого света
//   INSTANCE_CUSTOM.w — 1.0 если это landmark (усиленное свечение)

group_uniforms Facade;
uniform vec3 wall_color : source_color = vec3(0.055, 0.062, 0.086);
uniform vec3 window_dark : source_color = vec3(0.016, 0.020, 0.032);
uniform vec3 window_warm : source_color = vec3(1.0, 0.77, 0.42);
uniform float floor_height = 3.4;
uniform float window_pitch = 2.3;
uniform float window_width = 1.3;
uniform float window_height = 1.5;
// Окно — это тусклый прямоугольник, а не прожектор. Яркими на референсе
// являются вывески; окна лишь набивают фактуру. При энергии выше ~0.8 они
// выжигаются в белый и съедают весь неон.
uniform float emission_energy = 0.5;
// Свечение крыши. С высоты видны именно крыши, а не фасады, и без этого
// город сверху превращается в чёрное поле. У дальнего плана значение выше:
// там окна мельче пикселя и в кадр попадает только кровля.
uniform float roof_glow : hint_range(0.0, 1.0) = 0.1;

group_uniforms Weather;
uniform float wetness : hint_range(0.0, 1.0) = 0.55;
uniform float grime : hint_range(0.0, 1.0) = 0.6;

varying vec3 v_local;
varying vec3 v_size;
varying vec3 v_onrm;
varying vec4 v_custom;
varying vec3 v_tint;

void vertex() {
	v_local = VERTEX;
	// Реальные габариты инстанса в метрах — из масштаба модельной матрицы.
	// Благодаря этому окно всегда ~1.75 x 1.95 м, как бы ни был растянут бокс.
	v_size = vec3(
		length(MODEL_MATRIX[0].xyz),
		length(MODEL_MATRIX[1].xyz),
		length(MODEL_MATRIX[2].xyz)
	);
	v_onrm = NORMAL;
	v_custom = INSTANCE_CUSTOM;
	v_tint = COLOR.rgb;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec3 an = abs(v_onrm);
	bool roof = an.y > 0.5;

	float height_m = (v_local.y + 0.5) * v_size.y;

	vec2 uv;
	if (roof) {
		uv = vec2(v_local.x * v_size.x, v_local.z * v_size.z);
	} else if (an.x > 0.5) {
		uv = vec2(v_local.z * v_size.z, height_m);
	} else {
		uv = vec2(v_local.x * v_size.x, height_m);
	}

	float seed = v_custom.x * 977.0;
	float lit_ratio = clamp(v_custom.y, 0.0, 1.0);
	float neon_mix = clamp(v_custom.z, 0.0, 1.0);
	float landmark = v_custom.w;

	vec3 albedo = wall_color;
	vec3 emission = vec3(0.0);
	float rough = mix(0.85, 0.22, wetness);

	if (roof) {
		// Крыша: тёмный рубероид, немного шума под вентиляцию и надстройки,
		// плюс подсветка технических площадок и лифтовых будок.
		float speck = hash12(floor(uv * 0.5) + seed);
		albedo = wall_color * (0.45 + 0.25 * speck);
		rough = mix(0.92, 0.45, wetness * 0.6);
		emission = mix(window_warm, v_tint, 0.65) * roof_glow
			* (0.35 + 0.65 * speck) * mix(1.0, 1.8, landmark);
	} else {
		vec2 grid = vec2(uv.x / window_pitch, uv.y / floor_height);
		vec2 cell = floor(grid);
		vec2 inner = fract(grid);

		vec2 half_win = vec2(window_width / window_pitch, window_height / floor_height) * 0.5;
		vec2 d = abs(inner - vec2(0.5));
		float in_window = step(d.x, half_win.x) * step(d.y, half_win.y);

		float roll = hash12(cell + vec2(seed, seed * 1.7));
		float lit = step(roll, lit_ratio) * in_window;

		// Первый этаж — витрины: светятся почти всегда и в цвет района.
		float ground = 1.0 - step(floor_height, uv.y);
		lit = max(lit, in_window * ground * step(hash12(cell + seed * 3.1), 0.82));

		vec3 win_color = mix(window_warm, v_tint, neon_mix);
		win_color = mix(win_color, v_tint, ground * 0.85);

		albedo = mix(wall_color, window_dark, in_window);
		emission = win_color * lit * emission_energy
			* mix(1.0, 1.7, ground) * mix(1.0, 1.4, landmark);

		// Переплёты: тонкая тёмная рамка вокруг стекла.
		float frame = in_window * (1.0 - step(d.x, half_win.x - 0.035))
			+ in_window * (1.0 - step(d.y, half_win.y - 0.05));
		albedo = mix(albedo, wall_color * 0.5, clamp(frame, 0.0, 1.0));

		rough = mix(rough, 0.06, in_window);
	}

	// Вертикальные подтёки от дождя.
	float streak = hash12(vec2(floor(uv.x * 2.5), seed * 0.37));
	albedo *= 1.0 - grime * 0.4 * streak;
	// Низ стены грязнее верха.
	albedo *= mix(0.72, 1.0, clamp(height_m / 14.0, 0.0, 1.0));

	ALBEDO = albedo;
	EMISSION = emission;
	ROUGHNESS = rough;
	METALLIC = 0.05;
	SPECULAR = mix(0.35, 0.7, wetness);
}
