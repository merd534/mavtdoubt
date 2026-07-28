shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Фасад здания целиком процедурный: материал стены, окна, витрины
// первого этажа, пилястры, подоконные ленты и подтёки дождя.
// Текстур в проекте нет намеренно — это даёт нулевой вес ассетов и позволяет
// рисовать тысячи зданий одним MultiMesh'ем.
//
// Данные приходят из MultiMesh:
//   COLOR.rgb      — неоновый оттенок района (CityAtlas.district_palette)
//   INSTANCE_CUSTOM.x — сид здания (0..1): из него же берётся семейство материала
//   INSTANCE_CUSTOM.y — доля светящихся окон (0..1)
//   INSTANCE_CUSTOM.z — насколько окна уходят в неон района вместо тёплого света
//   INSTANCE_CUSTOM.w — 1.0 если это landmark (усиленное свечение)

group_uniforms Facade;
// Базовый цвет остаётся ориентиром яркости, но конкретный оттенок стены
// выбирается по сиду здания из семейств ниже: город из одного цвета
// выглядит как чёрные коробки.
uniform vec3 wall_color : source_color = vec3(0.215, 0.230, 0.268);
uniform vec3 window_dark : source_color = vec3(0.042, 0.050, 0.068);
uniform vec3 window_warm : source_color = vec3(1.0, 0.80, 0.48);
// Сила разброса материалов: 0 — все здания одного цвета,
// 1 — полный набор семейств. Радуги не будет: палитра умышленно земляная,
// различаются только светлота и теплота оттенка.
uniform float material_variety : hint_range(0.0, 1.0) = 1.0;
uniform float floor_height = 3.4;
uniform float window_pitch = 2.3;
uniform float window_width = 1.3;
uniform float window_height = 1.5;
// Окно — это тусклый прямоугольник, а не прожектор. Яркими на референсе
// являются вывески; окна лишь набивают фактуру.
uniform float emission_energy = 0.5;
// Свечение крыши. С высоты видны именно крыши, а не фасады.
uniform float roof_glow : hint_range(0.0, 1.0) = 0.1;
// Насколько соседние дома одного семейства различаются по светлоте.
uniform float shade_spread : hint_range(0.0, 1.0) = 0.85;

group_uniforms Relief;
// Псевдорельеф: вертикальные пилястры и подоконные ленты рисуются
// в шейдере через нормаль и затенение: геометрию такие мелочи
// не тратят, но плоская стена перестаёт быть плоской.
uniform float pilaster_strength : hint_range(0.0, 1.0) = 0.62;
uniform float band_strength : hint_range(0.0, 1.0) = 0.5;
uniform float recess_strength : hint_range(0.0, 1.0) = 0.7;

group_uniforms Weather;
uniform float wetness : hint_range(0.0, 1.0) = 0.55;
uniform float grime : hint_range(0.0, 1.0) = 0.42;

varying vec3 v_local;
varying vec3 v_size;
varying vec3 v_onrm;
varying vec4 v_custom;
varying vec3 v_tint;

void vertex() {
	v_local = VERTEX;
	// Реальные габариты инстанса в метрах — из масштаба модельной матрицы.
	v_size = vec3(
		length(MODEL_MATRIX[0].xyz),
		length(MODEL_MATRIX[1].xyz),
		length(MODEL_MATRIX[2].xyz)
	);
	v_onrm = NORMAL;
	v_custom = INSTANCE_CUSTOM;
	v_tint = COLOR.rgb;
}

float hash11(float x) {
	return fract(sin(x * 127.1) * 43758.5453123);
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Семейство отделки стены по сиду. Оттенки нуарные, но ещё на треть
// светлее прежних: в ночном освещении разница между кирпичом и
// бетоном была видна только вплотную под фонарём.
// Насыщенность остаётся сдержанной — это городские материалы, а не радуга.
vec3 material_family(float seed01, out float rough_bias, out float metal_bias) {
	float pick = fract(seed01 * 7.0);
	int family = int(floor(seed01 * 7.0));
	vec3 base;
	rough_bias = 0.0;
	metal_bias = 0.0;

	if (family == 0) {
		// Светлый серый бетон.
		base = vec3(0.445, 0.462, 0.488);
		rough_bias = 0.08;
	} else if (family == 1) {
		// Красно-коричневый кирпич.
		base = vec3(0.482, 0.268, 0.212);
		rough_bias = 0.12;
	} else if (family == 2) {
		// Песчаник / тёплая штукатурка.
		base = vec3(0.522, 0.446, 0.330);
		rough_bias = 0.06;
	} else if (family == 3) {
		// Стеклянная башня: сине-стальной.
		base = vec3(0.272, 0.348, 0.472);
		rough_bias = -0.22;
		metal_bias = 0.25;
	} else if (family == 4) {
		// Окисленная медь / зелёный камень.
		base = vec3(0.282, 0.412, 0.366);
		rough_bias = 0.02;
		metal_bias = 0.12;
	} else if (family == 5) {
		// Грязно-бежевая старая застройка.
		base = vec3(0.552, 0.518, 0.446);
		rough_bias = 0.14;
	} else {
		// Тёмный сланец — базовый нуарный тон, он же самый тёмный.
		base = vec3(0.298, 0.312, 0.362);
		rough_bias = 0.05;
	}

	// Разброс светлоты внутри семейства: два соседних бетонных дома
	// всё равно отличаются.
	float shade = mix(1.0 - 0.38 * shade_spread, 1.0 + 0.52 * shade_spread, pick);
	return base * shade;
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

	float seed01 = fract(v_custom.x);
	float seed = v_custom.x * 977.0;
	float lit_ratio = clamp(v_custom.y, 0.0, 1.0);
	float neon_mix = clamp(v_custom.z, 0.0, 1.0);
	float landmark = v_custom.w;

	// Цвет отделки этого конкретного здания.
	float rough_bias = 0.0;
	float metal_bias = 0.0;
	vec3 family = material_family(seed01, rough_bias, metal_bias);
	vec3 wall = mix(wall_color, family, material_variety);
	// Чуть подмешиваем цвет района: дома квартала читаются как семья.
	wall = mix(wall, wall * (0.7 + 0.6 * v_tint), 0.14 * material_variety);

	vec3 albedo = wall;
	vec3 emission = vec3(0.0);
	float rough = clamp(mix(0.85, 0.22, wetness) + rough_bias, 0.05, 1.0);
	float metallic = clamp(0.05 + metal_bias, 0.0, 0.85);
	vec3 normal_offset = vec3(0.0);

	if (roof) {
		// Крыша: тёмный рубероид, шум под вентиляцию и подсветка техплощадок.
		float speck = hash12(floor(uv * 0.5) + seed);
		albedo = wall * (0.42 + 0.28 * speck);
		rough = mix(0.92, 0.45, wetness * 0.6);
		metallic = 0.05;
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

		albedo = mix(wall, window_dark, in_window);
		emission = win_color * lit * emission_energy
			* mix(1.0, 1.7, ground) * mix(1.0, 1.4, landmark);

		// Переплёты: тонкая тёмная рамка вокруг стекла.
		float frame = in_window * (1.0 - step(d.x, half_win.x - 0.035))
			+ in_window * (1.0 - step(d.y, half_win.y - 0.05));
		albedo = mix(albedo, wall * 0.55, clamp(frame, 0.0, 1.0));

		// Глубина оконной ниши: верхний откос темнее, подоконник светлее.
		float top_reveal = in_window * smoothstep(half_win.y - 0.06, half_win.y, d.y)
			* step(0.5, inner.y);
		float sill = in_window * smoothstep(half_win.y - 0.06, half_win.y, d.y)
			* (1.0 - step(0.5, inner.y));
		albedo *= 1.0 - recess_strength * 0.5 * top_reveal;
		albedo += wall * 0.38 * sill;

		// Пилястры: вертикальные выступы между осями окон.
		// Шаг пилястр зависит от сида: где-то каждая ось, где-то каждая третья.
		float pil_period = mix(1.0, 3.0, floor(hash11(seed01 + 4.7) * 3.0) / 2.0);
		float pil_phase = fract(grid.x / pil_period);
		float pil = 1.0 - smoothstep(0.06, 0.13, abs(pil_phase - 0.5));
		pil *= 1.0 - in_window;
		albedo = mix(albedo, wall * 1.34, pilaster_strength * pil);
		normal_offset.x += (pil_phase - 0.5) * pilaster_strength * pil * 1.4;

		// Подоконные ленты на границе этажей.
		float band = 1.0 - smoothstep(0.02, 0.09, abs(fract(grid.y) - 0.02));
		band *= 1.0 - in_window;
		albedo = mix(albedo, wall * 1.45, band_strength * band);
		normal_offset.y -= band_strength * band * 0.9;

		// Цоколь: нижние полтора метра — тёмный камень, как в реальной застройке.
		float plinth = 1.0 - smoothstep(1.1, 1.6, uv.y);
		albedo = mix(albedo, wall * 0.55, plinth * 0.75);

		// Углы здания темнее: грязь и собственная тень.
		float corner = smoothstep(0.42, 0.5, max(abs(v_local.x), abs(v_local.z)));
		albedo *= 1.0 - 0.13 * corner;

		rough = mix(rough, 0.06, in_window);
		metallic = mix(metallic, 0.35, in_window);
	}

	// Вертикальные подтёки от дождя.
	float streak = hash12(vec2(floor(uv.x * 2.5), seed * 0.37));
	albedo *= 1.0 - grime * 0.26 * streak;
	// Низ стены грязнее верха.
	albedo *= mix(0.86, 1.0, clamp(height_m / 14.0, 0.0, 1.0));

	ALBEDO = albedo;
	EMISSION = emission;
	ROUGHNESS = rough;
	METALLIC = metallic;
	SPECULAR = mix(0.35, 0.7, wetness);
	NORMAL_MAP = normalize(vec3(0.5, 0.5, 1.0) + vec3(normal_offset.x, normal_offset.y, 0.0) * 0.5);
	NORMAL_MAP_DEPTH = 0.8;
}
