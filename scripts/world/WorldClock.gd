class_name NoirWorldClock
extends Node
## Игровое время. Автозагрузка: `WorldClock`.
##
## Нужен уже в Фазе 1: алиби, расписания NPC и записи камер оперируют минутами
## суток, а лимит на раскрытие дела («убийца скроется») считается по этим часам.
##
## ФАЗА 6. Время теперь живёт в настройках (секция `world`): игрок тянет ползунок
## в меню — часы прыгают сразу, небо и свет перестраиваются по сигналу
## [signal time_jumped]. Обратно в настройки текущее время пишется раз в игровой
## час, а не каждую минуту: иначе файл настроек переписывался бы постоянно.

const MINUTES_PER_DAY := 1440
const DEFAULT_SCALE := 60.0  ## 1 реальная секунда = 1 игровая минута

signal minute_changed(minutes_of_day: int)
signal hour_changed(hour_of_day: int)
signal day_changed(day_number: int)
signal night_started()
signal day_started()
## Время переведено вручную (ползунок, катсцена, загрузка сейва).
signal time_jumped(minutes_of_day: int)

var paused: bool = false
var time_scale: float = DEFAULT_SCALE

var _day: int = 1
var _minutes: float = 21.0 * 60.0  ## Стартуем в 21:00 — нуар начинается ночью.
var _last_minute: int = -1
var _last_hour: int = -1
var _was_night: bool = true
var _writing_config: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE

	_apply_config()
	_last_minute = int(_minutes)
	_last_hour = _last_minute / 60
	_was_night = is_night()

	if GameConfig != null:
		GameConfig.setting_changed.connect(_on_setting_changed)

	Log.info("WorldClock", "Часы мира запущены", {
		"время": time_string(),
		"темп": time_scale,
		"заморозка": paused,
	})


## Читает секцию `world` целиком. Отсутствующие ключи подменятся дефолтами
## внутри GameConfig, так что здесь не нужны проверки на мусор.
func _apply_config() -> void:
	if GameConfig == null:
		return
	var minutes: int = clampi(GameConfig.get_int("world", "time_of_day_min"), 0, MINUTES_PER_DAY - 1)
	_minutes = float(minutes)
	time_scale = maxf(0.0, GameConfig.get_float("world", "time_flow"))
	paused = GameConfig.get_bool("world", "freeze_time")


func _process(delta: float) -> void:
	if paused or time_scale <= 0.0:
		return
	advance_minutes(delta * time_scale / 60.0)


## Продвигает часы на [param amount] игровых минут. Безопасно к любым значениям.
func advance_minutes(amount: float) -> void:
	if amount <= 0.0 or not is_finite(amount):
		return
	_minutes += amount

	while _minutes >= float(MINUTES_PER_DAY):
		_minutes -= float(MINUTES_PER_DAY)
		_day += 1
		day_changed.emit(_day)

	var minute_now: int = int(_minutes)
	if minute_now != _last_minute:
		_last_minute = minute_now
		minute_changed.emit(minute_now)

		var hour_now: int = minute_now / 60
		if hour_now != _last_hour:
			_last_hour = hour_now
			hour_changed.emit(hour_now)
			_store_time()

		var night_now: bool = is_night()
		if night_now != _was_night:
			_was_night = night_now
			if night_now:
				night_started.emit()
			else:
				day_started.emit()


func set_time(hour_value: int, minute_value: int = 0) -> void:
	set_minutes_of_day(clampi(hour_value, 0, 23) * 60 + clampi(minute_value, 0, 59))


## Главная точка входа для ползунка времени в меню настроек.
func set_minutes_of_day(minutes: int) -> void:
	var wrapped: int = ((minutes % MINUTES_PER_DAY) + MINUTES_PER_DAY) % MINUTES_PER_DAY
	_minutes = float(wrapped)
	_last_minute = wrapped
	_last_hour = wrapped / 60
	_was_night = is_night()

	minute_changed.emit(_last_minute)
	hour_changed.emit(_last_hour)
	time_jumped.emit(_last_minute)
	_store_time()


## Пишет текущее время в настройки. Флаг `_writing_config` гасит обратную
## реакцию на setting_changed, иначе часы будут сами себя переводить.
func _store_time() -> void:
	if GameConfig == null:
		return
	_writing_config = true
	GameConfig.set_value("world", "time_of_day_min", int(_minutes))
	_writing_config = false


func _on_setting_changed(section_name: String, key: String, value: Variant) -> void:
	if section_name != "world" or _writing_config:
		return
	match key:
		"time_of_day_min":
			var minutes: int = clampi(int(value), 0, MINUTES_PER_DAY - 1)
			if minutes != int(_minutes):
				set_minutes_of_day(minutes)
		"time_flow":
			time_scale = maxf(0.0, float(value))
		"freeze_time":
			paused = bool(value)


func day() -> int:
	return _day


func minutes_of_day() -> int:
	return int(_minutes)


func hour() -> int:
	return int(_minutes) / 60


func minute() -> int:
	return int(_minutes) % 60


func total_minutes_elapsed() -> int:
	return (_day - 1) * MINUTES_PER_DAY + int(_minutes)


func is_night() -> bool:
	var h: int = hour()
	return h >= 20 or h < 6


## Доля светлого времени 0..1: 0 — глухая ночь (03:00), 1 — полдень.
## Используется освещением сцены для плавного рассвета и заката.
func daylight() -> float:
	var phase: float = float(_minutes) / float(MINUTES_PER_DAY)
	# Косинусоида с минимумом в 03:00 и максимумом в 15:00.
	var raw: float = 0.5 - 0.5 * cos((phase - 0.125) * TAU)
	return clampf(raw, 0.0, 1.0)


## Угол солнца/луны над горизонтом в градусах: -90 надир, 0 горизонт, 90 зенит.
func sun_elevation_deg() -> float:
	return -90.0 + 180.0 * daylight()


func time_string() -> String:
	return "%02d:%02d" % [hour(), minute()]


func stamp_string() -> String:
	return "День %d, %s" % [_day, time_string()]


## Парсит "HH:MM" в минуты суток. При мусоре возвращает [param fallback]
## и пишет предупреждение — вызывающему коду не нужен try/catch.
func parse_hhmm(text: String, fallback: int = -1) -> int:
	var trimmed: String = text.strip_edges()
	var parts: PackedStringArray = trimmed.split(":")
	if parts.size() < 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		if fallback < 0:
			Log.warn("WorldClock", "Не удалось разобрать время", {"вход": text})
		return fallback
	var h: int = clampi(parts[0].to_int(), 0, 23)
	var m: int = clampi(parts[1].to_int(), 0, 59)
	return h * 60 + m


static func format_minutes(minutes_of_day_value: int) -> String:
	var wrapped: int = ((minutes_of_day_value % MINUTES_PER_DAY) + MINUTES_PER_DAY) % MINUTES_PER_DAY
	return "%02d:%02d" % [wrapped / 60, wrapped % 60]


## Минимальная разница между двумя моментами суток с учётом перехода через полночь.
static func minute_distance(a: int, b: int) -> int:
	var diff: int = absi(a - b) % MINUTES_PER_DAY
	return mini(diff, MINUTES_PER_DAY - diff)
