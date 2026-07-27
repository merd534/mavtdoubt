class_name NoirCrimeDirector
extends Node
## Режиссёр преступлений. Автозагрузка: `CrimeDirector`.
##
## Конвейер одного дела (строгая машина состояний, повторный вход невозможен):
##
##   IDLE -> PREPARING -> REQUESTING -> VALIDATING -> [REPAIRING -> VALIDATING]
##        -> ENFORCING -> SPAWNING -> ACTIVE
##
## На любом шаге сбой не приводит к падению: ветка деградации всегда ведёт
## в `FallbackCrimeGenerator`, который проходит те же VALIDATING/ENFORCING.
## Поэтому дело появляется **всегда** — либо от LLM, либо локально.

enum State { IDLE, PREPARING, REQUESTING, VALIDATING, REPAIRING, ENFORCING, SPAWNING, ACTIVE, FAILED }

const STATE_NAMES: Dictionary = {
	State.IDLE: "IDLE",
	State.PREPARING: "PREPARING",
	State.REQUESTING: "REQUESTING",
	State.VALIDATING: "VALIDATING",
	State.REPAIRING: "REPAIRING",
	State.ENFORCING: "ENFORCING",
	State.SPAWNING: "SPAWNING",
	State.ACTIVE: "ACTIVE",
	State.FAILED: "FAILED",
}

const SUSPECT_POOL_SIZE := 9
const LOCATION_DIGEST_SIZE := 18
const MAX_LLM_REPAIR_ROUNDS := 1
## Бюджет входа при повторе после 413 — заметно ниже штатного.
const TIGHT_INPUT_TOKENS := 3600

signal state_changed(from_state: int, to_state: int)
signal stage_reported(stage: String, detail: String)
signal case_ready(case_file: NoirCaseFile)
signal case_failed(reason: String)
signal case_expired()
signal case_closed(correct: bool, accused_id: String)

var _state: State = State.IDLE
var _case: NoirCaseFile = null
var _spawner: NoirClueSpawner = null
var _generating: bool = false
var _last_seed: int = 0
var _deadline_minute: int = -1
var _stats: Dictionary = {"llm_ok": 0, "llm_repaired": 0, "offline": 0, "failed": 0}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	WorldClock.minute_changed.connect(_on_minute_changed)
	Log.info("CrimeDirector", "Режиссёр готов", {
		"LLM": "доступен" if Api.is_available() else "оффлайн",
		"локаций": CityAtlas.location_count(),
		"жителей": Citizens.count(),
	})


# ---------------------------------------------------------------- публичный API

func state() -> State:
	return _state


func state_name() -> String:
	return str(STATE_NAMES.get(_state, "?"))


func current_case() -> NoirCaseFile:
	return _case


func is_busy() -> bool:
	return _generating


func stats() -> Dictionary:
	return _stats.duplicate()


## Привязывает спавнер мира. Если дело уже активно — материализует его сразу.
func attach_spawner(spawner: NoirClueSpawner) -> void:
	if spawner == null or not is_instance_valid(spawner):
		Log.warn("CrimeDirector", "Попытка привязать невалидный спавнер")
		return
	_spawner = spawner
	Log.info("CrimeDirector", "Спавнер улик привязан")
	if _case != null:
		var count: int = _spawner.spawn_case(_case)
		Log.info("CrimeDirector", "Активное дело перематериализовано", {"улик": count})


## Главная точка входа. Возвращает готовое дело или null.
## [param options]: seed, allow_llm, difficulty, min_clues, max_clues, time_hint.
func generate_case(options: Dictionary = {}) -> NoirCaseFile:
	if _generating:
		Log.warn("CrimeDirector", "Генерация уже идёт — повторный запрос отклонён")
		return null

	_generating = true
	var result: NoirCaseFile = await _run_pipeline(options)
	_generating = false
	return result


## Снимает текущее дело, не закрывая его (например, при выходе в меню).
func abandon_case() -> void:
	if _spawner != null and is_instance_valid(_spawner):
		_spawner.clear()
	_case = null
	_deadline_minute = -1
	_set_state(State.IDLE)
	Log.info("CrimeDirector", "Дело снято")


# ---------------------------------------------------------------- конвейер

func _run_pipeline(options: Dictionary) -> NoirCaseFile:
	_set_state(State.PREPARING)

	# --- 0. Предпосылки ------------------------------------------------------
	if not CityAtlas.is_built():
		Log.warn("CrimeDirector", "Атлас не собран — собираю")
		CityAtlas.build()
	if not Citizens.is_built() or Citizens.count() < 8:
		Log.warn("CrimeDirector", "Реестр жителей не готов — перестраиваю")
		Citizens.build(GameConfig.get_int("crime", "citizen_count"), CityAtlas.city_seed)
	if CityAtlas.location_count() == 0 or Citizens.count() < 4:
		return _fail("Мир не готов: локаций %d, жителей %d" % [CityAtlas.location_count(), Citizens.count()])

	var seed_value: int = int(options.get("seed", 0))
	if seed_value == 0:
		seed_value = int(Time.get_unix_time_from_system()) ^ (Time.get_ticks_usec() & 0xFFFF)
	_last_seed = seed_value

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	_report("preparing", "сид дела %d" % seed_value)

	# --- 1. Пробуем LLM ------------------------------------------------------
	var allow_llm: bool = bool(options.get("allow_llm", GameConfig.get_bool("crime", "allow_llm")))
	var force_offline: bool = GameConfig.get_bool("crime", "force_offline_generator")
	var enforced: Dictionary = {}
	var source: String = ""
	var repairs: PackedStringArray = []

	if allow_llm and not force_offline and Api.is_available():
		var llm_outcome: Dictionary = await _try_llm(seed_value, rng, options)
		if bool(llm_outcome.get("ok", false)):
			enforced = llm_outcome["data"]
			source = str(llm_outcome["source"])
			repairs = llm_outcome["repairs"]
		else:
			Log.warn("CrimeDirector", "LLM-ветка не дала валидного дела — перехожу на локальный генератор", {
				"причина": str(llm_outcome.get("reason", "?")),
			})
	else:
		var why: String = "выключено в настройках" if force_offline or not allow_llm else "API недоступен"
		Log.info("CrimeDirector", "Работаю локально", {"причина": why})

	# --- 2. Локальный генератор как гарантия ---------------------------------
	if enforced.is_empty():
		var offline_outcome: Dictionary = _try_offline(seed_value, options)
		if not bool(offline_outcome.get("ok", false)):
			return _fail("Локальный генератор тоже не смог собрать дело: %s" % str(offline_outcome.get("reason", "?")))
		enforced = offline_outcome["data"]
		source = "offline"
		repairs = offline_outcome["repairs"]

	# --- 3. Сборка дела ------------------------------------------------------
	var case_file: NoirCaseFile = NoirCaseFile.from_data(enforced, source, repairs)
	if not case_file.is_solvable():
		return _fail("Дело собрано, но признано нерешаемым — отказ от публикации")

	_apply_world_state(case_file)
	_case = case_file
	_arm_deadline()

	# --- 4. Материализация ---------------------------------------------------
	_set_state(State.SPAWNING)
	if _spawner != null and is_instance_valid(_spawner):
		var spawned: int = _spawner.spawn_case(case_file)
		_report("spawning", "создано узлов: %d" % spawned)
	else:
		_report("spawning", "спавнер не привязан — дело существует только в данных")

	match source:
		"llm": _stats["llm_ok"] = int(_stats["llm_ok"]) + 1
		"llm_repaired": _stats["llm_repaired"] = int(_stats["llm_repaired"]) + 1
		_: _stats["offline"] = int(_stats["offline"]) + 1

	_set_state(State.ACTIVE)
	case_ready.emit(case_file)
	Log.info("CrimeDirector", "Дело опубликовано", {
		"название": case_file.title(),
		"источник": source,
		"улик": case_file.clues().size(),
		"правок": repairs.size(),
		"сид": seed_value,
	})
	return case_file


## Ветка LLM: запрос -> валидация -> (ремонт-запрос -> валидация) -> enforce.
func _try_llm(seed_value: int, rng: RandomNumberGenerator, options: Dictionary) -> Dictionary:
	var pool: Array[String] = Citizens.build_llm_pool(rng, int(options.get("pool_size", SUSPECT_POOL_SIZE)))
	if pool.size() < 3:
		return {"ok": false, "reason": "не удалось собрать пул подозреваемых"}

	var cards: Array[Dictionary] = Citizens.cards_for(pool)
	var digest: Dictionary = CityAtlas.digest_for_llm(LOCATION_DIGEST_SIZE)
	var prompt_options: Dictionary = {
		"min_clues": GameConfig.get_int("crime", "min_clues"),
		"max_clues": GameConfig.get_int("crime", "max_clues"),
		"time_hint": "ночь" if WorldClock.is_night() else "вечер",
		"difficulty": str(options.get("difficulty", "средняя")),
	}

	_set_state(State.REQUESTING)
	_report("requesting", "модель %s, подозреваемых в пуле: %d" % [GameConfig.get_string("api", "model"), pool.size()])

	var messages: Array = NoirCrimePromptBuilder.build_messages(cards, digest, prompt_options)
	var api_result: Dictionary = await Api.request_chat(messages, {"label": "crime_case", "expect_json": true})

	# 413 = провайдер урезал лимит входа сильнее, чем мы рассчитывали.
	# Повторяем один раз с жёстко сжатым промптом вместо отказа.
	if not bool(api_result.get("ok", false)) and int(api_result.get("http_status", 0)) == 413:
		Log.warn("CrimeDirector", "Провайдер вернул 413 — пересобираю промпт под жёсткий бюджет", {
			"бюджет_токенов": TIGHT_INPUT_TOKENS,
		})
		prompt_options["max_input_tokens"] = TIGHT_INPUT_TOKENS
		var tight_digest: Dictionary = CityAtlas.digest_for_llm(NoirCrimePromptBuilder.MIN_LOCATIONS)
		var tight_cards: Array[Dictionary] = cards.slice(0, mini(cards.size(), NoirCrimePromptBuilder.MIN_SUSPECTS + 1))
		messages = NoirCrimePromptBuilder.build_messages(tight_cards, tight_digest, prompt_options)
		cards = tight_cards
		digest = tight_digest
		_report("requesting", "повтор после 413: подозреваемых %d, локаций %d" % [tight_cards.size(), NoirCrimePromptBuilder.MIN_LOCATIONS])
		api_result = await Api.request_chat(messages, {"label": "crime_case_tight", "expect_json": true})

	if not bool(api_result.get("ok", false)):
		return {"ok": false, "reason": "API: %s (%s)" % [str(api_result.get("code_name", "?")), str(api_result.get("error", ""))]}

	var raw_json: Variant = api_result.get("json", null)

	# --- валидация + возможный круг ремонта ---------------------------------
	for round_index: int in range(MAX_LLM_REPAIR_ROUNDS + 1):
		_set_state(State.VALIDATING)
		var schema_report: NoirCrimeSchema.Report = NoirCrimeSchema.validate(raw_json)
		_report("validating", "структура: %s" % schema_report.summary())

		for warning: String in schema_report.warnings:
			Log.debug("CrimeDirector", "Схема: " + warning)

		if schema_report.ok():
			_set_state(State.ENFORCING)
			var solvability: NoirSolvabilityValidator.Report = NoirSolvabilityValidator.enforce(schema_report.data)
			_report("enforcing", "решаемость: %s" % solvability.summary())
			for repair: String in solvability.repairs:
				Log.debug("CrimeDirector", "Ремонт: " + repair)

			if solvability.ok():
				var all_notes: PackedStringArray = schema_report.warnings.duplicate()
				all_notes.append_array(solvability.repairs)
				return {
					"ok": true,
					"data": solvability.data,
					"source": "llm_repaired" if round_index > 0 else "llm",
					"repairs": all_notes,
				}
			for err: String in solvability.errors:
				Log.warn("CrimeDirector", "Решаемость: " + err)
			return {"ok": false, "reason": "дело нерешаемо: " + ", ".join(solvability.errors)}

		for err: String in schema_report.errors:
			Log.warn("CrimeDirector", "Схема: " + err)

		if round_index >= MAX_LLM_REPAIR_ROUNDS:
			return {"ok": false, "reason": "структурные ошибки не устранены за %d круг(ов)" % (MAX_LLM_REPAIR_ROUNDS + 1)}

		# --- круг ремонта --------------------------------------------------
		_set_state(State.REPAIRING)
		_report("repairing", "ошибок структуры: %d, отправляю на исправление" % schema_report.errors.size())

		var previous: Dictionary = raw_json as Dictionary if raw_json is Dictionary else {}
		var repair_messages: Array = NoirCrimePromptBuilder.build_repair_messages(previous, schema_report.errors, cards, digest)
		var repair_result: Dictionary = await Api.request_chat(repair_messages, {"label": "crime_repair", "expect_json": true, "temperature": 0.3})

		if not bool(repair_result.get("ok", false)):
			return {"ok": false, "reason": "ремонтный запрос провален: %s" % str(repair_result.get("code_name", "?"))}
		raw_json = repair_result.get("json", null)

	return {"ok": false, "reason": "конвейер LLM завершился без результата"}


## Локальная ветка: те же VALIDATING/ENFORCING, что и у LLM.
func _try_offline(seed_value: int, options: Dictionary) -> Dictionary:
	_set_state(State.VALIDATING)
	var raw: Dictionary = NoirFallbackCrimeGenerator.generate(seed_value, options)
	if raw.is_empty():
		return {"ok": false, "reason": "генератор вернул пустое дело"}

	var schema_report: NoirCrimeSchema.Report = NoirCrimeSchema.validate(raw)
	_report("validating", "локальное дело, структура: %s" % schema_report.summary())
	if not schema_report.ok():
		for err: String in schema_report.errors:
			Log.error("CrimeDirector", "Локальный генератор нарушил свою же схему: " + err)
		return {"ok": false, "reason": "локальное дело не прошло схему"}

	_set_state(State.ENFORCING)
	var solvability: NoirSolvabilityValidator.Report = NoirSolvabilityValidator.enforce(schema_report.data)
	_report("enforcing", "локальное дело, решаемость: %s" % solvability.summary())
	if not solvability.ok():
		for err: String in solvability.errors:
			Log.error("CrimeDirector", "Локальное дело нерешаемо: " + err)
		return {"ok": false, "reason": "локальное дело нерешаемо"}

	var notes: PackedStringArray = schema_report.warnings.duplicate()
	notes.append_array(solvability.repairs)
	return {"ok": true, "data": solvability.data, "repairs": notes}


# ------------------------------------------------------------- состояние мира

## Применяет дело к миру: жертва мертва, круг помечен как подозреваемые.
func _apply_world_state(case_file: NoirCaseFile) -> void:
	# Снимаем метки с прошлого дела.
	for id: String in Citizens.all_ids():
		var person: NoirCitizen = Citizens.get_citizen(id)
		if person != null:
			person.is_suspect = false

	var victim: NoirCitizen = Citizens.get_citizen(case_file.victim_id())
	if victim != null:
		victim.is_alive = false
	else:
		Log.error("CrimeDirector", "Жертва не найдена при применении дела", {"id": case_file.victim_id()})

	var pool: Variant = case_file.data.get("suspect_pool", null)
	if pool is Array:
		for raw_id: Variant in pool as Array:
			var suspect: NoirCitizen = Citizens.get_citizen(str(raw_id))
			if suspect != null:
				suspect.is_suspect = true

	case_file.case_closed.connect(_on_case_closed)


func _arm_deadline() -> void:
	var limit_hours: float = GameConfig.get_float("gameplay", "case_time_limit_h")
	if limit_hours <= 0.0:
		_deadline_minute = -1
		return
	_deadline_minute = WorldClock.total_minutes_elapsed() + int(limit_hours * 60.0)
	Log.info("CrimeDirector", "Установлен лимит на раскрытие", {"часов": limit_hours})


func _on_minute_changed(_minutes_of_day: int) -> void:
	if _case == null or _case.closed or _deadline_minute < 0:
		return
	if WorldClock.total_minutes_elapsed() < _deadline_minute:
		return
	_deadline_minute = -1
	Log.warn("CrimeDirector", "Время на раскрытие вышло — убийца скрылся", {"дело": _case.title()})
	case_expired.emit()


func _on_case_closed(correct: bool, accused_id: String) -> void:
	_deadline_minute = -1
	case_closed.emit(correct, accused_id)


# -------------------------------------------------------------------- служебное

func _set_state(next_state: State) -> void:
	if _state == next_state:
		return
	var previous: State = _state
	_state = next_state
	state_changed.emit(int(previous), int(next_state))
	Log.debug("CrimeDirector", "Состояние: %s -> %s" % [str(STATE_NAMES[previous]), str(STATE_NAMES[next_state])])


func _report(stage: String, detail: String) -> void:
	stage_reported.emit(stage, detail)
	Log.debug("CrimeDirector", "Этап «%s»" % stage, {"деталь": detail})


func _fail(reason: String) -> NoirCaseFile:
	_stats["failed"] = int(_stats["failed"]) + 1
	_set_state(State.FAILED)
	case_failed.emit(reason)
	Log.error("CrimeDirector", "Дело не создано", {"причина": reason})
	return null
