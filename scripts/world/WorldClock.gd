class_name NoirWorldClock
extends Node
## Игровое время. Автозагрузка: `WorldClock`.
##
## Нужен уже в Фазе 1: алиби, расписания NPC и записи камер оперируют минутами
## суток, а лимит на раскрытие дела («убийца скроется») считается по этим часам.

const MINUTES_PER_DAY := 1440
const DEFAULT_SCALE := 60.0  ## 1 реальная секунда = 1 игровая минута

signal minute_changed(minutes_of_day: int)
signal hour_changed(hour: int)
signal day_changed(day: int)
signal night_started()
signal day_started()

var paused: bool = false
var time_scale: float = DEFAULT_SCALE

var _day: int = 1
var _minutes: float = 21.0 * 60.0  ## Стартуем в 21:00 — нуар начинается ночью.
var _last_minute: int = -1
var _last_hour: int = -1
var _was_night: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_last_minute = int(_minutes)
	_last_hour = _last_minute / 60
	_was_night = is_night()


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

		var night_now: bool = is_night()
		if night_now != _was_night:
			_was_night = night_now
			if night_now:
				night_started.emit()
			else:
				day_started.emit()


func set_time(hour: int, minute: int = 0) -> void:
	var h: int = clampi(hour, 0, 23)
	var m: int = clampi(minute, 0, 59)
	_minutes = float(h * 60 + m)
	_last_minute = int(_minutes)
	_last_hour = h
	_was_night = is_night()
	minute_changed.emit(_last_minute)
	hour_changed.emit(h)


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
