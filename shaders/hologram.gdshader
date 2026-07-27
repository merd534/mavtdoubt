shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

// ФАЗА 3. Объёмная голограмма на фасаде: полосы развёртки, глитчи, свечение контура.
// Цвет берётся из INSTANCE_COLOR, а INSTANCE_CUSTOM несёт:
//   x — сдвиг фазы (чтобы соседние голограммы не мигали синхронно)
//   y — яркость 0..1
//   z — флаг сбоя (1.0 — картинка рвётся)
//   w — скорость прокрутки развёртки
//
// ВАЖНО: встроенные INSTANCE_CUSTOM и INSTANCE_COLOR в Godot доступны ТОЛЬКО
// в vertex(). Обращение к ним из fragment() даёт ошибку компиляции
// "Unknown identifier in expression: 'INSTANCE_CUSTOM'", поэтому читаем их в vertex()
// и пробрасываем через varying. Значения одинаковы для всей инстанции,
// так что интерполяция их не портит, но flat дешевле и точнее.

uniform float energy : hint_range(0.0, 12.0) = 3.0;
uniform float scan_density : hint_range(2.0, 200.0) = 48.0;
uniform float flicker_amount : hint_range(0.0, 1.0) = 0.35;
uniform float edge_softness : hint_range(0.0, 1.0) = 0.45;

varying flat vec4 inst_params;
varying flat vec3 inst_tint;

float hash11(float x) {
	return fract(sin(x * 78.233) * 43758.5453);
}

void vertex() {
	inst_params = INSTANCE_CUSTOM;
	inst_tint = INSTANCE_COLOR.rgb;
}

void fragment() {
	vec2 uv = UV;
	float phase = inst_params.x * 6.2831853;
	float brightness = clamp(inst_params.y, 0.0, 1.0);
	float glitch = step(0.5, inst_params.z);
	float scroll = inst_params.w;

	// Горизонтальные полосы развёртки, ползущие вверх.
	float scan = 0.5 + 0.5 * sin((uv.y * scan_density) - TIME * (1.5 + scroll * 4.0) + phase);
	scan = pow(scan, 2.0);

	// Редкие срывы кадра: строка съезжает по горизонтали.
	float glitch_line = step(0.985, hash11(floor(uv.y * 60.0) + floor(TIME * 6.0)));
	uv.x += glitch_line * glitch * (hash11(floor(TIME * 6.0)) - 0.5) * 0.25;

	// Мягкие края: у голограммы не должно быть резкой рамки.
	vec2 edge = smoothstep(vec2(0.0), vec2(max(edge_softness, 0.001)), uv)
		* smoothstep(vec2(0.0), vec2(max(edge_softness, 0.001)), vec2(1.0) - uv);
	float mask = edge.x * edge.y;

	float flicker = 1.0 - flicker_amount * (0.5 + 0.5 * sin(TIME * 11.0 + phase)) * hash11(floor(TIME * 9.0) + phase);

	vec3 tint = inst_tint;
	float intensity = brightness * mask * flicker * (0.25 + 0.75 * scan);

	// Френель-подсветка силуэта.
	float rim = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.5);
	intensity += rim * brightness * mask * 0.6;

	ALBEDO = vec3(0.0);
	EMISSION = tint * intensity * energy;
	ALPHA = clamp(intensity * 1.4, 0.0, 1.0);
}
