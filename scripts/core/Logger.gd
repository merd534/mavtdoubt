class_name NoirLogger
extends Node
## Централизованный логгер. Автозагрузка: `Log`.
##
## В GDScript нет try/catch, поэтому роль «безопасного барьера» играют
## guard-методы этого класса: [method check], [method require] и
## [method require_valid]. Они возвращают bool, пишут диагностику и позволяют
## коду аккуратно выйти из функции вместо аварии.

enum Level { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, FATAL = 5 }

const LEVEL_NAMES: PackedStringArray = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL"]
const LOG_DIR := "user://logs"
const MAX_HISTORY := 4096
const FLUSH_EVERY := 12
const MAX_LOG_FILES := 10

## Испущено на каждую запись — используется дев-консолью.
signal entry_logged(level: int, tag: String, message: String)
## Испущено только на ERROR/FATAL — используется тестовым стендом.
signal problem_logged(level: int, tag: String, message: String)

var min_level: Level = Level.DEBUG
var echo_to_console: bool = true
var write_to_file: bool = true

var _history: Array[Dictionary] = []
var _file: FileAccess = null
var _pending_flush: int = 0
var _file_disabled: bool = false
var _counters: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for level_index: int in range(LEVEL_NAMES.size()):
		_counters[level_index] = 0
	_open_file()
	_prune_old_files()
	info("Logger", "Логгер поднят", {"файл": _file != null})


func _exit_tree() -> void:
	info("Logger", "Логгер остановлен", {"счётчики": _counters})
	_close_file()


# ---------------------------------------------------------------- публичный API

func trace(tag: String, message: String, context: Dictionary = {}) -> void:
	_emit(Level.TRACE, tag, message, context)


func debug(tag: String, message: String, context: Dictionary = {}) -> void:
	_emit(Level.DEBUG, tag, message, context)


func info(tag: String, message: String, context: Dictionary = {}) -> void:
	_emit(Level.INFO, tag, message, context)


func warn(tag: String, message: String, context: Dictionary = {}) -> void:
	_emit(Level.WARN, tag, message, context)


func error(tag: String, message: String, context: Dictionary = {}) -> void:
	_emit(Level.ERROR, tag, message, context)


func fatal(tag: String, message: String, context: Dictionary = {}) -> void:
	_emit(Level.FATAL, tag, message, context)


## Мягкая замена assert: если [param condition] ложно — пишет ERROR и
## возвращает false, чтобы вызывающий код мог корректно выйти.
## [codeblock]
## if not Log.check(index >= 0, "Spawner", "отрицательный индекс"):
##     return
## [/codeblock]
func check(condition: bool, tag: String, message: String, context: Dictionary = {}) -> bool:
	if not condition:
		error(tag, "Провалена проверка: " + message, context)
	return condition


## Проверка на null. Возвращает true, если значение пригодно к использованию.
func require(value: Variant, tag: String, what: String) -> bool:
	if value == null:
		error(tag, "Обязательное значение отсутствует: " + what)
		return false
	return true


## Проверка Object на живость (защита от freed-объектов между кадрами).
func require_valid(node: Object, tag: String, what: String) -> bool:
	if node == null or not is_instance_valid(node):
		error(tag, "Объект мёртв или не создан: " + what)
		return false
	return true


## Сколько записей каждого уровня накопилось. Тестовый стенд использует это,
## чтобы объявить прогон провальным при наличии ERROR/FATAL.
func counter(level: Level) -> int:
	return int(_counters.get(int(level), 0))


func problem_count() -> int:
	return counter(Level.ERROR) + counter(Level.FATAL)


func history(last_n: int = 0) -> Array[Dictionary]:
	if last_n <= 0 or last_n >= _history.size():
		return _history.duplicate()
	return _history.slice(_history.size() - last_n)


func flush() -> void:
	if _file != null:
		_file.flush()
		_pending_flush = 0


# -------------------------------------------------------------------- внутренне

func _emit(level: Level, tag: String, message: String, context: Dictionary) -> void:
	_counters[int(level)] = int(_counters.get(int(level), 0)) + 1
	if level < min_level:
		return

	var stamp: String = _timestamp()
	var suffix: String = ""
	if not context.is_empty():
		suffix = " | " + _format_context(context)
	var line: String = "[%s][%s][%s] %s%s" % [stamp, LEVEL_NAMES[int(level)], tag, message, suffix]

	_history.append({
		"time": stamp,
		"level": int(level),
		"tag": tag,
		"message": message,
		"context": context.duplicate(true),
	})
	if _history.size() > MAX_HISTORY:
		_history = _history.slice(_history.size() - MAX_HISTORY)

	if echo_to_console:
		match level:
			Level.WARN:
				push_warning(line)
			Level.ERROR, Level.FATAL:
				push_error(line)
			_:
				print(line)

	if _file != null:
		_file.store_line(line)
		_pending_flush += 1
		if _pending_flush >= FLUSH_EVERY or level >= Level.WARN:
			_file.flush()
			_pending_flush = 0

	entry_logged.emit(int(level), tag, message)
	if level >= Level.ERROR:
		problem_logged.emit(int(level), tag, message)


func _format_context(context: Dictionary) -> String:
	var parts: PackedStringArray = []
	for key: Variant in context.keys():
		parts.append("%s=%s" % [str(key), _stringify(context[key])])
	return ", ".join(parts)


func _stringify(value: Variant) -> String:
	if value is Dictionary or value is Array:
		var text: String = JSON.stringify(value)
		if text.length() > 400:
			return text.substr(0, 397) + "..."
		return text
	if value is float:
		return "%.3f" % (value as float)
	return str(value)


func _timestamp() -> String:
	var d: Dictionary = Time.get_datetime_dict_from_system()
	var ms: int = Time.get_ticks_msec() % 1000
	return "%02d:%02d:%02d.%03d" % [int(d.get("hour", 0)), int(d.get("minute", 0)), int(d.get("second", 0)), ms]


func _open_file() -> void:
	if not write_to_file or _file_disabled:
		return

	var mkdir_error: int = DirAccess.make_dir_recursive_absolute(LOG_DIR)
	if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
		_file_disabled = true
		push_warning("NoirLogger: не удалось создать %s (код %d). Логи только в консоль." % [LOG_DIR, mkdir_error])
		return

	var d: Dictionary = Time.get_datetime_dict_from_system()
	var path: String = "%s/noir_%04d-%02d-%02d.log" % [LOG_DIR, int(d.get("year", 0)), int(d.get("month", 0)), int(d.get("day", 0))]

	var is_new_file: bool = not FileAccess.file_exists(path)
	if is_new_file:
		_file = FileAccess.open(path, FileAccess.WRITE)
	else:
		_file = FileAccess.open(path, FileAccess.READ_WRITE)
		if _file != null:
			_file.seek_end()

	# BOM в новом файле: без него Notepad и PowerShell на Windows читают
	# кириллицу как мусор.
	if _file != null and is_new_file:
		_file.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]))

	if _file == null:
		_file_disabled = true
		push_warning("NoirLogger: не удалось открыть %s (код %d). Логи только в консоль." % [path, FileAccess.get_open_error()])
		return

	_file.store_line("")
	_file.store_line("=== Сессия начата %s ===" % Time.get_datetime_string_from_system(false, true))
	_file.flush()


func _close_file() -> void:
	if _file == null:
		return
	_file.store_line("=== Сессия завершена %s ===" % Time.get_datetime_string_from_system(false, true))
	_file.flush()
	_file.close()
	_file = null


## Держим каталог логов небольшим: оставляем MAX_LOG_FILES свежих файлов.
func _prune_old_files() -> void:
	var dir: DirAccess = DirAccess.open(LOG_DIR)
	if dir == null:
		return
	var names: PackedStringArray = []
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with("noir_") and entry.ends_with(".log"):
			names.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()

	if names.size() <= MAX_LOG_FILES:
		return
	var sorted: Array = Array(names)
	sorted.sort()
	var to_remove: int = sorted.size() - MAX_LOG_FILES
	for i: int in range(to_remove):
		var remove_error: int = dir.remove(str(sorted[i]))
		if remove_error != OK:
			push_warning("NoirLogger: не удалось удалить старый лог %s (код %d)" % [str(sorted[i]), remove_error])
