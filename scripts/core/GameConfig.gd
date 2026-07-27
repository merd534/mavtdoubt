class_name NoirGameConfig
extends Node
## Единое хранилище настроек. Автозагрузка: `GameConfig`.
##
## Гарантии:
##  * Любое отсутствующее/битое значение молча заменяется дефолтом того же типа —
##    повреждённый .cfg физически не может уронить игру.
##  * Запись на диск дебаунсится, чтобы двигание слайдера не писало файл 60 раз/сек.
##  * Секреты (токен LLM) никогда не попадают в settings.cfg.

const SETTINGS_PATH := "user://settings.cfg"
const SECRETS_RES := "res://secrets.cfg"
const SECRETS_USER := "user://secrets.cfg"
const ENV_TOKEN := "NOIR_LLM_TOKEN"
const SAVE_DEBOUNCE_SEC := 0.75

const DEFAULT_ENDPOINT := "https://models.inference.ai.azure.com/chat/completions"
const DEFAULT_MODEL := "gpt-4.1"

signal setting_changed(section: String, key: String, value: Variant)
signal settings_saved()

## Полная схема настроек. Тип дефолта = контракт типа для значения.
const DEFAULTS: Dictionary = {
	"api": {
		"enabled": true,
		"endpoint": DEFAULT_ENDPOINT,
		"model": DEFAULT_MODEL,
		"temperature": 0.85,
		"max_tokens": 4096,
		"timeout_sec": 45.0,
		"max_attempts": 4,
		# Сколько секунд готовы ждать, если сервер сам просит паузу (429).
		# Если он просит больше — уходим в оффлайн-генератор, а не морозим игру.
		"max_retry_wait_sec": 65.0,
		"max_concurrent": 2,
		"log_raw_bodies": false,
	},
	"crime": {
		"seed": 0,                      # 0 = взять из времени
		"citizen_count": 420,
		"min_clues": 5,
		"max_clues": 11,
		"allow_llm": true,
		"force_offline_generator": false,
	},
	"graphics": {
		"preset": "Высокие",
		"fsr_mode": 3,                  # 0 Performance .. 3 Native
		"fsr_sharpness": 0.25,          # 0 = максимально резко, 2 = мыло
		"resolution_scale": 1.0,
		"vsync": 0,
		"fps_limit": 0,
		"shadow_atlas": 4096,
		"sdfgi": true,
		"ssr": true,
		"ssao": true,
		"ssil": false,
		"volumetric_fog": true,
		"glow": true,
		"render_distance_m": 900.0,
		"chunk_radius": 5,
		"npc_budget": 220,
		"anisotropy": 2,
		"msaa": 0,
		"taa": false,
		"debanding": true,
		"texture_quality": 2,           # 0 низкое .. 3 максимальное
		# --- ФАЗА 3-4: плотность детализации и стриминг ---
		"detail_density": 0.8,          # 0 = только коробки зданий
		"cables": true,
		"steam": true,
		"debris": true,
		"interior_furniture": true,
		"billboard_lights": 2,          # живых источников от вывесок на здание
		"hide_radius_chunks": 1,        # буферное кольцо скрытых чанков
	},
	"gameplay": {
		"difficulty_preset": "Детектив",
		"clue_highlight": true,
		"police_reaction": 1.0,         # множитель скорости реакции
		"hack_alarm_speed": 1.0,        # скорость реакции полиции на взлом
		"case_time_limit_h": 72.0,      # 0 = без лимита
		"killer_moves_after_h": 0.0,    # 0 = убийца не совершает нового преступления
		"clue_scan_recharge": 1.0,      # перезарядка сканера улик, сек
		"permadeath": false,
		"autosave": true,
		"witness_reliability": 1.0,
	},
	"controls": {
		"mouse_sensitivity": 0.22,
		"scan_sensitivity": 0.09,       # отдельная чувствительность для лупы/сканера
		"fov": 78.0,
		"invert_y": false,
		"toggle_sprint": false,
	},
	"accessibility": {
		"ui_scale": 1.0,
		"font_size_bonus": 0,
		"high_contrast_clues": false,
		"reduce_camera_shake": false,
		"subtitles": true,
	},
	"audio": {
		"master_db": 0.0,
		"music_db": -6.0,
		"sfx_db": 0.0,
		"rain_db": -3.0,
	},
}

var _values: Dictionary = {}
var _file_dirty: bool = false
var _save_timer: float = 0.0
var _token_cache: String = ""
var _token_resolved: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_values = _deep_copy(DEFAULTS)
	load_settings()


func _process(delta: float) -> void:
	if not _file_dirty:
		return
	_save_timer -= delta
	if _save_timer <= 0.0:
		save_settings()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if _file_dirty:
			save_settings()


# ---------------------------------------------------------------- чтение/запись

func get_value(section: String, key: String) -> Variant:
	var sect: Variant = _values.get(section, null)
	if sect is Dictionary and (sect as Dictionary).has(key):
		return (sect as Dictionary)[key]
	var fallback: Variant = _default_for(section, key)
	if fallback == null:
		Log.warn("GameConfig", "Запрошен неизвестный ключ", {"секция": section, "ключ": key})
	return fallback


func get_bool(section: String, key: String) -> bool:
	var v: Variant = get_value(section, key)
	return bool(v) if v != null else false


func get_int(section: String, key: String) -> int:
	var v: Variant = get_value(section, key)
	return int(v) if v != null and (v is int or v is float or v is bool) else 0


func get_float(section: String, key: String) -> float:
	var v: Variant = get_value(section, key)
	return float(v) if v != null and (v is int or v is float or v is bool) else 0.0


func get_string(section: String, key: String) -> String:
	var v: Variant = get_value(section, key)
	return str(v) if v != null else ""


## Ставит значение с приведением к типу дефолта. Возвращает true, если значение
## реально изменилось (полезно, чтобы не переприменять тяжёлые графнастройки).
func set_value(section: String, key: String, value: Variant, save_now: bool = false) -> bool:
	var expected: Variant = _default_for(section, key)
	if expected == null:
		Log.warn("GameConfig", "Попытка записи неизвестного ключа — отклонена", {"секция": section, "ключ": key})
		return false

	var coerced: Variant = _coerce(value, expected)
	if not _values.has(section):
		_values[section] = {}
	var sect: Dictionary = _values[section]
	if sect.has(key) and _equal(sect[key], coerced):
		return false

	sect[key] = coerced
	setting_changed.emit(section, key, coerced)
	Log.trace("GameConfig", "Настройка изменена", {"секция": section, "ключ": key, "значение": coerced})

	if save_now:
		save_settings()
	else:
		_file_dirty = true
		_save_timer = SAVE_DEBOUNCE_SEC
	return true


func section(name: String) -> Dictionary:
	var sect: Variant = _values.get(name, null)
	if sect is Dictionary:
		return (sect as Dictionary).duplicate(true)
	return {}


func reset_section(name: String) -> void:
	if not DEFAULTS.has(name):
		Log.warn("GameConfig", "Сброс неизвестной секции", {"секция": name})
		return
	_values[name] = _deep_copy(DEFAULTS[name])
	for key: Variant in (_values[name] as Dictionary).keys():
		setting_changed.emit(name, str(key), (_values[name] as Dictionary)[key])
	_file_dirty = true
	_save_timer = 0.0
	Log.info("GameConfig", "Секция сброшена к дефолту", {"секция": name})


func reset_all() -> void:
	for name: Variant in DEFAULTS.keys():
		reset_section(str(name))


func load_settings() -> void:
	var cfg := ConfigFile.new()
	var err: int = cfg.load(SETTINGS_PATH)
	if err != OK:
		if err == ERR_FILE_NOT_FOUND:
			Log.info("GameConfig", "settings.cfg отсутствует — пишу дефолты")
			save_settings()
		else:
			Log.warn("GameConfig", "settings.cfg не читается, работаю на дефолтах", {"код": err})
		return

	var restored: int = 0
	var rejected: int = 0
	for sect_name: String in cfg.get_sections():
		if not DEFAULTS.has(sect_name):
			rejected += 1
			continue
		for key: String in cfg.get_section_keys(sect_name):
			var expected: Variant = _default_for(sect_name, key)
			if expected == null:
				rejected += 1
				continue
			var raw: Variant = cfg.get_value(sect_name, key)
			(_values[sect_name] as Dictionary)[key] = _coerce(raw, expected)
			restored += 1

	Log.info("GameConfig", "Настройки загружены", {"принято": restored, "отброшено": rejected})


func save_settings() -> void:
	_file_dirty = false
	_save_timer = 0.0
	var cfg := ConfigFile.new()
	for sect_name: Variant in _values.keys():
		var sect: Variant = _values[sect_name]
		if not (sect is Dictionary):
			continue
		for key: Variant in (sect as Dictionary).keys():
			cfg.set_value(str(sect_name), str(key), (sect as Dictionary)[key])

	var err: int = cfg.save(SETTINGS_PATH)
	if err != OK:
		Log.error("GameConfig", "Не удалось сохранить настройки", {"путь": SETTINGS_PATH, "код": err})
		return
	settings_saved.emit()
	Log.debug("GameConfig", "Настройки сохранены")


# -------------------------------------------------------------------- секреты

## Порядок: переменная окружения -> res://secrets.cfg -> user://secrets.cfg.
## Пустая строка означает «сети нет» — CrimeDirector уйдёт в оффлайн-генератор.
func resolve_llm_token() -> String:
	if _token_resolved:
		return _token_cache

	_token_resolved = true
	_token_cache = ""

	var from_env: String = OS.get_environment(ENV_TOKEN).strip_edges()
	if not from_env.is_empty():
		_token_cache = from_env
		Log.info("GameConfig", "Токен LLM взят из переменной окружения", {"переменная": ENV_TOKEN})
		return _token_cache

	for path: String in [SECRETS_RES, SECRETS_USER]:
		var cfg := ConfigFile.new()
		if cfg.load(path) != OK:
			continue
		var token: String = str(cfg.get_value("llm", "token", "")).strip_edges()
		var endpoint: String = str(cfg.get_value("llm", "endpoint", "")).strip_edges()
		var model: String = str(cfg.get_value("llm", "model", "")).strip_edges()
		if not endpoint.is_empty():
			set_value("api", "endpoint", endpoint)
		if not model.is_empty():
			set_value("api", "model", model)
		if not token.is_empty():
			_token_cache = token
			Log.info("GameConfig", "Токен LLM взят из файла", {"путь": path})
			return _token_cache

	Log.warn("GameConfig", "Токен LLM не найден — включён оффлайн-режим генерации дел")
	return _token_cache


func has_llm_token() -> bool:
	return not resolve_llm_token().is_empty()


## Сбрасывает кэш токена (например, после того как игрок вписал новый в меню).
func invalidate_token_cache() -> void:
	_token_resolved = false
	_token_cache = ""


func write_user_token(token: String) -> bool:
	var cfg := ConfigFile.new()
	cfg.load(SECRETS_USER)
	cfg.set_value("llm", "token", token.strip_edges())
	var err: int = cfg.save(SECRETS_USER)
	if err != OK:
		Log.error("GameConfig", "Не удалось записать user-токен", {"код": err})
		return false
	invalidate_token_cache()
	Log.info("GameConfig", "Пользовательский токен сохранён")
	return true


# ------------------------------------------------------------------ утилиты

func _default_for(section: String, key: String) -> Variant:
	var sect: Variant = DEFAULTS.get(section, null)
	if sect is Dictionary and (sect as Dictionary).has(key):
		return (sect as Dictionary)[key]
	return null


## Приводит произвольное значение к типу образца. Никогда не бросает.
func _coerce(value: Variant, like: Variant) -> Variant:
	if value == null:
		return like

	if like is bool:
		if value is bool:
			return value
		if value is int or value is float:
			return float(value) != 0.0
		if value is String:
			var low: String = (value as String).to_lower().strip_edges()
			return low in ["1", "true", "yes", "on", "да"]
		return like

	if like is int:
		if value is int:
			return value
		if value is float:
			return int(round(value as float))
		if value is bool:
			return 1 if value else 0
		if value is String and (value as String).is_valid_float():
			return int(round((value as String).to_float()))
		return like

	if like is float:
		if value is float:
			return value
		if value is int:
			return float(value)
		if value is bool:
			return 1.0 if value else 0.0
		if value is String and (value as String).is_valid_float():
			return (value as String).to_float()
		return like

	if like is String:
		if value is String:
			return value
		return str(value)

	if like is Dictionary:
		return (value as Dictionary).duplicate(true) if value is Dictionary else like
	if like is Array:
		return (value as Array).duplicate(true) if value is Array else like

	return value if typeof(value) == typeof(like) else like


func _equal(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return is_equal_approx(a as float, b as float)
	return a == b


func _deep_copy(source: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in source.keys():
		var v: Variant = source[key]
		if v is Dictionary:
			out[key] = _deep_copy(v as Dictionary)
		elif v is Array:
			out[key] = (v as Array).duplicate(true)
		else:
			out[key] = v
	return out
