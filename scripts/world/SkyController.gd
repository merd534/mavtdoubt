class_name NoirSkyController
extends RefCounted
## Небо, воздух и светило по времени суток.
##
## Почему это отдельный файл: раньше сцена просто поднимала яркость фона,
## ambient и adjustment_brightness. Фон был плоским цветом (BG_COLOR), а туман и
## bloom размазывали его по экрану — вместо дня получалось белое молоко.
##
## Теперь:
##   * фон — процедурное небо, цвета идут ночь -> сумерки -> день;
##   * туман днём редеет, а не светится сильнее;
##   * bloom днём поднимает порог и перестаёт светить всё подряд;
##   * adjustment_brightness больше не используется для осветления картинки.

const NIGHT_TOP := Color(0.014, 0.02, 0.045)
const NIGHT_HORIZON := Color(0.05, 0.07, 0.12)
const DUSK_TOP := Color(0.08, 0.09, 0.19)
const DUSK_HORIZON := Color(0.44, 0.21, 0.24)
const DAY_TOP := Color(0.16, 0.29, 0.55)
const DAY_HORIZON := Color(0.56, 0.64, 0.74)

const NIGHT_GROUND := Color(0.014, 0.018, 0.03)
const DAY_GROUND := Color(0.15, 0.16, 0.18)

const NIGHT_AMBIENT := Color(0.063, 0.086, 0.133)
const DAY_AMBIENT := Color(0.45, 0.49, 0.57)

const NIGHT_FOG := Color(0.059, 0.078, 0.122)
const DAY_FOG := Color(0.44, 0.48, 0.55)

const NIGHT_SUN := Color(0.42, 0.5, 0.73)
const DUSK_SUN := Color(1.0, 0.56, 0.36)
const DAY_SUN := Color(1.0, 0.96, 0.9)

const NIGHT_FOG_DENSITY := 0.00035
const DAY_FOG_DENSITY := 0.00009
const NIGHT_VOLUME_DENSITY := 0.022
const DAY_VOLUME_DENSITY := 0.003


## Главная точка входа. Любой аргумент-узел может быть null — тогда
## делается меньше работы, но ошибки не будет.
##
## [param daylight] — 0 глухая ночь, 1 полдень (WorldClock.daylight()).
## [param minutes] — минуты суток, нужны для азимута светила.
static func apply(
		env: Environment,
		sun: DirectionalLight3D,
		minutes: int,
		daylight: float,
		elevation_deg: float,
		exposure: float,
		night_boost: float,
		base_sun_energy: float,
		base_ambient_energy: float
	) -> void:
	var day: float = clampf(daylight, 0.0, 1.0)
	# Сумерки: максимум в полосе рассвета и заката, нуль ночью и в полдень.
	var dusk: float = clampf(1.0 - absf(day - 0.3) / 0.25, 0.0, 1.0)
	var boost: float = clampf(night_boost, 0.3, 4.0)
	var exp_value: float = clampf(exposure, 0.2, 3.0)

	_apply_sun(sun, minutes, day, dusk, boost, base_sun_energy, elevation_deg)
	_apply_sky(env, day, dusk)
	_apply_air(env, day, dusk, boost, exp_value, base_ambient_energy)


# ------------------------------------------------------------------ светило

static func _apply_sun(sun: DirectionalLight3D, minutes: int, day: float, dusk: float,
		boost: float, base_energy: float, elevation_deg: float) -> void:
	if sun == null or not is_instance_valid(sun):
		return

	# Ночью светило не уводим глубоко под горизонт: иначе лунный свет
	# вообще не попадает в город и тени ложатся плашмя.
	var pitch: float = clampf(elevation_deg, 8.0, 84.0) if day > 0.5 else clampf(elevation_deg, 8.0, 84.0)
	if elevation_deg < 8.0:
		pitch = lerpf(14.0, 8.0, clampf(dusk, 0.0, 1.0))
	var azimuth: float = -35.0 + 360.0 * (float(posmod(minutes, 1440)) / 1440.0)
	sun.rotation_degrees = Vector3(-pitch, azimuth, 0.0)

	# Ночью — тусклая луна, днём — полноценное солнце. Без пересвета:
	# вся прибавка яркости идёт от света, а не от тумана и bloom.
	var night_energy: float = maxf(0.04, base_energy) * boost
	var day_energy: float = 2.3
	sun.light_energy = lerpf(night_energy, day_energy, day)
	sun.light_specular = lerpf(0.2, 0.6, day)

	var tint: Color = NIGHT_SUN.lerp(DAY_SUN, day)
	sun.light_color = tint.lerp(DUSK_SUN, dusk * 0.75)


# ------------------------------------------------------------------ небо

## Собирает процедурное небо на лету, если в сцене его не было.
static func _apply_sky(env: Environment, day: float, dusk: float) -> void:
	if env == null or not is_instance_valid(env):
		return

	if env.sky == null:
		var sky := Sky.new()
		sky.radiance_size = Sky.RADIANCE_SIZE_128
		sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
		sky.sky_material = ProceduralSkyMaterial.new()
		env.sky = sky
	if env.sky.sky_material == null:
		env.sky.sky_material = ProceduralSkyMaterial.new()

	env.background_mode = Environment.BG_SKY
	# Яркость фона больше не крутим — именно она давала белую засветку.
	env.background_energy_multiplier = 1.0

	var material: ProceduralSkyMaterial = env.sky.sky_material as ProceduralSkyMaterial
	if material == null:
		return

	var top: Color = NIGHT_TOP.lerp(DAY_TOP, day)
	var horizon: Color = NIGHT_HORIZON.lerp(DAY_HORIZON, day)
	material.sky_top_color = top.lerp(DUSK_TOP, dusk * 0.7)
	material.sky_horizon_color = horizon.lerp(DUSK_HORIZON, dusk * 0.8)
	material.sky_curve = 0.15
	material.sky_energy_multiplier = lerpf(0.55, 1.0, day)
	material.ground_bottom_color = NIGHT_GROUND.lerp(DAY_GROUND, day)
	material.ground_horizon_color = material.sky_horizon_color.darkened(0.4)
	material.ground_curve = 0.02
	material.ground_energy_multiplier = lerpf(0.4, 0.9, day)
	material.sun_angle_max = 12.0
	material.sun_curve = 0.12
	material.use_debanding = true


# ------------------------------------------------------------------ воздух

static func _apply_air(env: Environment, day: float, dusk: float, boost: float,
		exposure: float, base_ambient: float) -> void:
	if env == null or not is_instance_valid(env):
		return

	# Амбиент берём цветом, а не от неба: так он не взрывается вместе
	# с яркостью фона и картинка остаётся контрастной.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = NIGHT_AMBIENT.lerp(DAY_AMBIENT, day)
	env.ambient_light_energy = clampf(maxf(0.1, base_ambient) * lerpf(boost, 1.5, day), 0.05, 3.0)

	env.tonemap_exposure = exposure
	# Никакого осветления через adjustment: оно даёт ровно то самое
	# молочное свечение, на которое жаловался игрок.
	env.adjustment_enabled = false
	env.adjustment_brightness = 1.0

	# Дальний туман: днём его почти нет, иначе город тонет в молоке.
	if env.fog_enabled:
		var fog_tint: Color = NIGHT_FOG.lerp(DAY_FOG, day)
		env.fog_light_color = fog_tint.lerp(DUSK_HORIZON, dusk * 0.5)
		env.fog_light_energy = lerpf(0.8, 0.35, day)
		env.fog_density = lerpf(NIGHT_FOG_DENSITY, DAY_FOG_DENSITY, day)
		env.fog_sun_scatter = lerpf(0.05, 0.12, day)
		env.fog_aerial_perspective = lerpf(0.15, 0.05, day)
		# Главный виновник белого экрана: туман поверх неба.
		env.fog_sky_affect = lerpf(0.25, 0.0, day)

	if env.volumetric_fog_enabled:
		env.volumetric_fog_density = lerpf(NIGHT_VOLUME_DENSITY, DAY_VOLUME_DENSITY, day)
		env.volumetric_fog_emission_energy = lerpf(0.35, 0.0, day)
		env.volumetric_fog_ambient_inject = lerpf(0.6, 0.1, day)
		env.volumetric_fog_albedo = Color(0.078, 0.102, 0.153).lerp(Color(0.5, 0.54, 0.6), day)

	# Bloom: ночью он нужен для неона, днём — только мешает.
	if env.glow_enabled:
		env.glow_intensity = lerpf(0.75, 0.25, day)
		env.glow_bloom = lerpf(0.1, 0.0, day)
		env.glow_strength = 1.0
		env.glow_hdr_threshold = lerpf(1.05, 2.2, day)
		env.glow_hdr_scale = 2.0
