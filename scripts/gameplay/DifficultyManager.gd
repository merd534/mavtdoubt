class_name NoirDifficultyManager
extends Node
## Сложность детективной части. Автозагрузка: `Difficulty`.
##
## Здесь нет ни одного числа про урон или хитпойнты: сложность в нуарном
## детективе — это количество информации, которую игра даёт бесплатно, и скорость,
## с которой мир наказывает за ошибки: подсветка улик, реакция полиции на взлом,
## лимит времени до того, как убийца скроется или ударит снова, и permadeath.
##
## Пресеты пишут те же ключи `GameConfig`, что крутятся вручную в меню, —
## единый источник истины для CrimeDirector и UI.

const PRESETS: Array[String] = [
	"Расследование",
	"Детектив",
	"Нуар",
	"Кошмар",
]

const PRESET_TABLE: Dictionary = {
	# Режим для тех, кто хочет атмосферы, а не борьбы.
	"Расследование": {
		"clue_highlight": true,
		"police_reaction": 0.6,
		"hack_alarm_speed": 0.5,
		"case_time_limit_h": 0.0,
		"killer_moves_after_h": 0.0,
		"clue_scan_recharge": 0.5,
		"witness_reliability": 1.0,
		"permadeath": false,
	},
	"Детектив": {
		"clue_highlight": true,
		"police_reaction": 1.0,
		"hack_alarm_speed": 1.0,
		"case_time_limit_h": 72.0,
		"killer_moves_after_h": 48.0,
		"clue_scan_recharge": 1.0,
		"witness_reliability": 0.9,
		"permadeath": false,
	},
	# С этого уровня улики не подсвечиваются вообще: только глаза и сканер.
	"Нуар": {
		"clue_highlight": false,
		"police_reaction": 1.4,
		"hack_alarm_speed": 1.6,
		"case_time_limit_h": 48.0,
		"killer_moves_after_h": 24.0,
		"clue_scan_recharge": 1.8,
		"witness_reliability": 0.7,
		"permadeath": false,
	},
	"Кошмар": {
		"clue_highlight": false,
		"police_reaction": 2.0,
		"hack_alarm_speed": 2.4,
		"case_time_limit_h": 24.0,
		"killer_moves_after_h": 12.0,
		"clue_scan_recharge": 2.6,
		"witness_reliability": 0.5,
		"permadeath": true,
	},
}

signal difficulty_applied(preset: String)
signal rule_changed(key: String, value: Variant)

var _applying: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameConfig.setting_changed.connect(_on_setting_changed)
	Log.info("Difficulty", "Менеджер сложности готов", {"пресет": current_preset()})


func preset_names() -> Array[String]:
	return PRESETS.duplicate()


func current_preset() -> String:
	var name: String = GameConfig.get_string("gameplay", "difficulty_preset")
	return name if PRESET_TABLE.has(name) else "Детектив"


func preset_index() -> int:
	return maxi(0, PRESETS.find(current_preset()))


func apply_preset(preset: String) -> bool:
	if not PRESET_TABLE.has(preset):
		Log.warn("Difficulty", "Неизвестный пресет сложности", {"пресет": preset})
		return false

	_applying = true
	GameConfig.set_value("gameplay", "difficulty_preset", preset)
	var values: Dictionary = PRESET_TABLE[preset]
	for key: Variant in values.keys():
		GameConfig.set_value("gameplay", str(key), values[key])
	_applying = false

	GameConfig.save_settings()
	difficulty_applied.emit(preset)
	Log.info("Difficulty", "Применён пресет сложности", {"пресет": preset})
	return true


func apply_preset_index(index: int) -> bool:
	if index < 0 or index >= PRESETS.size():
		return false
	return apply_preset(PRESETS[index])


# ------------------------------------------------------------- правила для систем

## Подсвечивать ли улики обводкой.
func clue_highlight_enabled() -> bool:
	return GameConfig.get_bool("gameplay", "clue_highlight")


## Множитель общей реактивности полиции (патрули, вызовы, погоня).
func police_reaction() -> float:
	return maxf(0.05, GameConfig.get_float("gameplay", "police_reaction"))


## Сколько секунд есть у игрока на взлом до срабатывания тревоги.
## База — 12 секунд, делим на скорость реакции.
func hack_alarm_delay_sec(base: float = 12.0) -> float:
	var speed: float = maxf(0.05, GameConfig.get_float("gameplay", "hack_alarm_speed"))
	return maxf(0.5, base / speed)


## Лимит игровых часов на раскрытие. 0 = без лимита.
func case_time_limit_h() -> float:
	return maxf(0.0, GameConfig.get_float("gameplay", "case_time_limit_h"))


func has_case_time_limit() -> bool:
	return case_time_limit_h() > 0.0


## Через сколько игровых часов убийца совершит новое преступление. 0 = никогда.
func killer_moves_after_h() -> float:
	return maxf(0.0, GameConfig.get_float("gameplay", "killer_moves_after_h"))


func killer_will_move() -> bool:
	return killer_moves_after_h() > 0.0


## Перезарядка сканера улик в секундах.
func clue_scan_recharge_sec() -> float:
	return maxf(0.0, GameConfig.get_float("gameplay", "clue_scan_recharge"))


## Надёжность свидетелей: 1.0 — всегда говорят правду, 0.5 — половина врёт.
func witness_reliability() -> float:
	return clampf(GameConfig.get_float("gameplay", "witness_reliability"), 0.0, 1.0)


func permadeath_enabled() -> bool:
	return GameConfig.get_bool("gameplay", "permadeath")


## Проверка для системы сохранений: в режиме «одна жизнь» автосейв не спасает,
## он только фиксирует прогресс до смерти.
func autosave_enabled() -> bool:
	return GameConfig.get_bool("gameplay", "autosave")


## Сводка всех активных правил — для HUD, логов и экрана итогов дела.
func rules() -> Dictionary:
	return {
		"preset": current_preset(),
		"clue_highlight": clue_highlight_enabled(),
		"police_reaction": police_reaction(),
		"hack_alarm_sec": hack_alarm_delay_sec(),
		"case_time_limit_h": case_time_limit_h(),
		"killer_moves_after_h": killer_moves_after_h(),
		"clue_scan_recharge": clue_scan_recharge_sec(),
		"witness_reliability": witness_reliability(),
		"permadeath": permadeath_enabled(),
	}


## Короткое описание пресета для меню.
func describe(preset: String) -> String:
	if not PRESET_TABLE.has(preset):
		return ""
	var values: Dictionary = PRESET_TABLE[preset]
	var parts: Array[String] = []
	parts.append("подсветка улик: " + ("есть" if bool(values["clue_highlight"]) else "нет"))
	var limit: float = float(values["case_time_limit_h"])
	parts.append("лимит: " + ("нет" if limit <= 0.0 else "%d ч" % int(limit)))
	var killer: float = float(values["killer_moves_after_h"])
	if killer > 0.0:
		parts.append("новое убийство через %d ч" % int(killer))
	parts.append("полиция ×%.1f" % float(values["police_reaction"]))
	if bool(values["permadeath"]):
		parts.append("одна жизнь")
	return ", ".join(parts)


func _on_setting_changed(section: String, key: String, value: Variant) -> void:
	if _applying or section != "gameplay":
		return
	if key == "difficulty_preset":
		return
	rule_changed.emit(key, value)
