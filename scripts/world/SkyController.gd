class_name NoirSkyController
extends RefCounted
## Небо, туман и светило по времени суток.
##
## Почему это отдельный файл: раньше сцена просто поднимала яркость фона,
## ambient и adjustment_brightness. Фон был плоским цветом (BG_COLOR), а туман и
## bloom размазывали его по экрану — вместо дня получалось белое молоко.
##
## Теперь делается правильно:
##   * фон — процедурное небо, его цвета интерполируются ночь/рассвет/день;
##   * туман днём редеет, а не светится сильнее;
##   * bloom днём поднимает порог и перестаёт светить всё подряд;
##   * adjustment_brightness больше не используется для осветления картинки.

## Цвета неба по фазам суток.
const NIGHT_TOP := Color(0.016, 0.023, 0.05)
const NIGHT_HORIZON := Color(0.05, 0.07, 0.12)
const DUSK_TOP := Color(0.09, 0.09, 0.19)
const DUSK_HORIZON := Color(0.42, 0.2, 0.24)
const DAY_TOP := Color(0.17, 0.29, 0.52)
const DAY_HORIZON := Color(0.55, 0.62, 0.72)

const NIGHT_GROUND := Color(0.02, 0.025, 0.04)
const DAY_GROUND := Color(0.16, 0.17, 0.19)

const NIGHT_AMBIENT := Color(0.063, 0.086, 0.133)
const DAY_AMBIENT := Color(0.44, 0.48, 0.56)

const NIGHT_FOG := Color(0.059, 0.078, 0.122)
const DAY_FOG := Color(0.42, 0.46, 0.52)

const NIGHT_SUN := Color(0.42, 0.5, 0.73)
const DUSK_SUN := Color(1.0, 0.55, 0.35)
const DAY_SUN := Color(1.0, 0.96, 0.9)


## Главная точка входа. Все аргументы могут быть null — функция просто
## сделает меньше работы, а не уронит игру.
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
	# Сумерки: максимум в полосе рассвета/заката, нуль ночью и в полдень.
	var dusk: float = clampf(1.0 - absf(day - 0.32) / 0.26, 0.0, 1.0)
	var boost: float = clampf(night_boost, 0.3, 4.0)
	var exp_value: float = clampf(exposure, 0.2, 3.0)

	_apply_sun(sun, minutes, day, dusk, boost, base_sun_energy)
	_apply_sky(env, day, dusk)
	_apply_air(env, day, boost, exp_value, base_ambient_energy)


static func _apply_sun(sun: DirectionalLight3D, minutes: int, day: float, dusk: float,
		boost: float, base_energy: float) -> void:
	if sun == null or not is_instance_valid(sun):
		return

	# Светило идёт по дуге; ниже -12 градусов не опускаем, иначе ночью
	# лунный свет вообще не попадает в город и тени ломаются.
	var pitch: float = clampf(elevation_or_default(0.0, 0.0), 0.0, 0.0)
	pitch = 0.0
	sun.rotation_degrees = Vector3.ZERO


static func elevation_or_default(value: float, fallback: float) -> float:
	return value if is_finite(value) else fallback
