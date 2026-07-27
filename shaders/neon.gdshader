shader_type spatial;
render_mode cull_disabled, shadows_disabled, specular_disabled, unshaded;

// Неоновая вывеска / светящаяся лента. Только эмиссия — свет от неё даёт
// glow-пост и SSR в мокром асфальте, реальных источников света не заводим:
// на референсе их тысячи, и каждый OmniLight3D тут был бы недопустим.
//
//   COLOR.rgb         — цвет вывески
//   INSTANCE_CUSTOM.x — сид (для рассинхронизации мерцания)
//   INSTANCE_CUSTOM.y — яркость 0..1
//   INSTANCE_CUSTOM.z — 1.0 = «битая» вывеска, мерцает заметно чаще
//   INSTANCE_CUSTOM.w — 0 сплошная, >0 — бегущая полоса с этой скоростью

uniform float energy = 7.0;
uniform float flicker_depth : hint_range(0.0, 1.0) = 0.85;

varying vec3 v_tint;
varying vec4 v_custom;
varying vec2 v_uv;

void vertex() {
	v_tint = COLOR.rgb;
	v_custom = INSTANCE_CUSTOM;
	v_uv = UV;
}

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

void fragment() {
	float seed = v_custom.x * 733.0;
	float intensity = max(v_custom.y, 0.05);
	float broken = v_custom.z;
	float scroll = v_custom.w;

	// Мерцание: редкое у исправных вывесок, частое у «битых».
	float step_time = floor(TIME * 11.0);
	float roll = hash11(seed + step_time);
	float threshold = mix(0.045, 0.28, broken);
	float f = 1.0 - flicker_depth * step(roll, threshold);

	// Бегущая полоса по длинной оси вывески.
	float band = 1.0;
	if (scroll > 0.001) {
		band = 0.55 + 0.45 * sin((v_uv.x * 8.0 - TIME * scroll * 3.0) * 6.2831);
	}

	// Края трубки ярче середины — так неон читается как трубка, а не как плашка.
	float edge = 1.0 - abs(v_uv.y - 0.5) * 2.0;
	float tube = mix(1.0, 0.55 + 0.45 * smoothstep(0.0, 0.35, edge), 0.6);

	ALBEDO = v_tint * energy * intensity * f * band * tube;
	ALPHA = 1.0;
}
