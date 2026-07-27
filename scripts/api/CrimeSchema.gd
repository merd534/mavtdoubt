class_name NoirCrimeSchema
extends RefCounted
## Нормализация и структурная валидация JSON дела.
##
## Делит работу с `SolvabilityValidator` так:
##   * **этот класс** отвечает на вопрос «структура и ссылки корректны?»
##     (существуют ли id, верны ли типы, попадают ли enum-значения в списки);
##   * **SolvabilityValidator** отвечает на вопрос «дело решаемо и непротиворечиво?».
##
## Класс терпим к вариациям формулировок модели: понимает синонимы ключей
## (`clues_left` → `clues`, `alibi_status` → `alibi_data`,
## `crime_scene_coords` → `crime_scene.coords`) и приводит типы.


## Результат проверки. Отчёт вместо исключения — так требует отсутствие try/catch.
class Report extends RefCounted:
	var errors: PackedStringArray = []
	var warnings: PackedStringArray = []
	var data: Dictionary = {}

	func ok() -> bool:
		return errors.is_empty()

	func fail(message: String) -> void:
		errors.append(message)

	func warn(message: String) -> void:
		warnings.append(message)

	func merge(other: Report) -> void:
		errors.append_array(other.errors)
		warnings.append_array(other.warnings)

	func summary() -> String:
		return "ошибок=%d предупреждений=%d" % [errors.size(), warnings.size()]


const KEY_ALIASES: Dictionary = {
	"clues_left": "clues",
	"evidence": "clues",
	"alibi_status": "alibi_data",
	"alibis": "alibi_data",
	"title": "case_title",
	"red_herring": "red_herrings",
	"false_leads": "red_herrings",
	"solution": "solution_chain",
	"chain": "solution_chain",
}

const CLUE_KEY_ALIASES: Dictionary = {
	"clue_id": "id",
	"clue_type": "type",
	"points_at": "points_to",
	"indicates": "points_to",
	"where": "location_id",
	"position": "coords",
	"needs_scan": "requires_scan",
	"difficulty": "discovery_difficulty",
	"confidence": "reliability",
}


## Главная точка входа: принимает сырой словарь от модели, возвращает [Report]
## с нормализованными данными в `data`.
static func validate(raw: Variant) -> Report:
	var report := Report.new()

	if not (raw is Dictionary):
		report.fail("Корень ответа не является JSON-объектом")
		return report

	var src: Dictionary = _apply_aliases(raw as Dictionary, KEY_ALIASES)
	var out: Dictionary = {}

	# --- участники -----------------------------------------------------------
	var killer_id: String = str(src.get("killer_id", "")).strip_edges()
	var victim_id: String = str(src.get("victim_id", "")).strip_edges()

	if killer_id.is_empty():
		report.fail("killer_id отсутствует")
	elif not Citizens.has(killer_id):
		report.fail("killer_id '%s' не существует в реестре жителей" % killer_id)

	if victim_id.is_empty():
		report.fail("victim_id отсутствует")
	elif not Citizens.has(victim_id):
		report.fail("victim_id '%s' не существует в реестре жителей" % victim_id)

	if not killer_id.is_empty() and killer_id == victim_id:
		report.fail("killer_id совпадает с victim_id")

	out["killer_id"] = killer_id
	out["victim_id"] = victim_id

	# --- заголовок и мотив ---------------------------------------------------
	out["case_title"] = _non_empty_string(src.get("case_title", ""), "Дело без названия")

	var motive: String = str(src.get("motive", "")).strip_edges()
	if motive.length() < 12:
		report.fail("motive пуст или слишком короток")
	out["motive"] = motive

	out["motive_category"] = _enum_or_default(
		src.get("motive_category", ""),
		NoirCrimePromptBuilder.MOTIVE_CATEGORIES,
		"revenge",
		"motive_category",
		report
	)

	# --- орудие --------------------------------------------------------------
	out["weapon"] = _validate_weapon(src.get("weapon", null), report)

	# --- место -------------------------------------------------------------
	out["crime_scene"] = _validate_scene(src, report)

	# --- время ---------------------------------------------------------------
	var tod_raw: String = str(src.get("time_of_death", "")).strip_edges()
	var tod_minutes: int = WorldClock.parse_hhmm(tod_raw, -1)
	if tod_minutes < 0:
		report.warn("time_of_death '%s' не разобран, подставлено 23:40" % tod_raw)
		tod_minutes = 23 * 60 + 40
	out["time_of_death"] = NoirWorldClock.format_minutes(tod_minutes)
	out["time_of_death_minutes"] = tod_minutes

	# --- улики ---------------------------------------------------------------
	var clues: Array[Dictionary] = _validate_clues(src.get("clues", null), out["crime_scene"], report)
	out["clues"] = clues

	if clues.is_empty():
		report.fail("Массив clues пуст — дело нераскрываемо")
	else:
		var has_hard: bool = false
		for clue: Dictionary in clues:
			if str(clue["type"]) in ["FINGERPRINT", "CAMERA_RECORDING"]:
				has_hard = true
				break
		if not has_hard:
			report.warn("Нет твёрдого доказательства (FINGERPRINT/CAMERA_RECORDING) — будет добавлено движком")

	# --- алиби ---------------------------------------------------------------
	out["alibi_data"] = _validate_alibis(src.get("alibi_data", null), killer_id, report)

	# --- ложные следы --------------------------------------------------------
	out["red_herrings"] = _validate_red_herrings(src.get("red_herrings", null), clues, killer_id, report)

	# --- цепочка решения -----------------------------------------------------
	out["solution_chain"] = _validate_chain(src.get("solution_chain", null), clues, report)

	# --- текст ---------------------------------------------------------------
	var narrative_raw: Variant = src.get("narrative", null)
	var narrative: Dictionary = {}
	if narrative_raw is Dictionary:
		narrative = narrative_raw as Dictionary
	else:
		report.warn("narrative отсутствует — будет сгенерирован движком")
	out["narrative"] = {
		"opening": _non_empty_string(narrative.get("opening", ""), ""),
		"police_report": _non_empty_string(narrative.get("police_report", ""), ""),
	}

	report.data = out
	return report


# ---------------------------------------------------------------- подпроверки

static func _validate_weapon(raw: Variant, report: Report) -> Dictionary:
	if not (raw is Dictionary):
		report.fail("weapon отсутствует или не является объектом")
		return {
			"name": "неустановленный предмет",
			"type": "improvised",
			"owner_id": "unknown",
			"disposal": "left_at_scene",
			"disposal_location_id": "",
		}

	var w: Dictionary = raw as Dictionary
	var owner_id: String = str(w.get("owner_id", "unknown")).strip_edges()
	if owner_id.is_empty():
		owner_id = "unknown"
	if owner_id != "unknown" and not Citizens.has(owner_id):
		report.warn("weapon.owner_id '%s' не найден — заменён на unknown" % owner_id)
		owner_id = "unknown"

	var disposal_location: String = str(w.get("disposal_location_id", "")).strip_edges()
	if not disposal_location.is_empty() and not CityAtlas.has_location(disposal_location):
		report.warn("weapon.disposal_location_id '%s' не существует — очищен" % disposal_location)
		disposal_location = ""

	return {
		"name": _non_empty_string(w.get("name", ""), "неустановленный предмет"),
		"type": _enum_or_default(w.get("type", ""), NoirCrimePromptBuilder.WEAPON_TYPES, "improvised", "weapon.type", report),
		"owner_id": owner_id,
		"disposal": _enum_or_default(w.get("disposal", ""), NoirCrimePromptBuilder.DISPOSAL_OPTIONS, "left_at_scene", "weapon.disposal", report),
		"disposal_location_id": disposal_location,
	}


static func _validate_scene(src: Dictionary, report: Report) -> Dictionary:
	var raw: Variant = src.get("crime_scene", null)
	var scene: Dictionary = raw as Dictionary if raw is Dictionary else {}

	if not (raw is Dictionary):
		report.warn("crime_scene отсутствует или не объект — восстанавливаю из доступных данных")

	var location_id: String = str(scene.get("location_id", "")).strip_edges()
	if location_id.is_empty() or not CityAtlas.has_location(location_id):
		if not location_id.is_empty():
			report.warn("crime_scene.location_id '%s' не существует — выбрана ближайшая валидная локация" % location_id)
		location_id = _fallback_location_id()
		if location_id.is_empty():
			report.fail("В атласе нет ни одной локации — место преступления не определить")

	# Координаты: сначала своё поле, потом корневой синоним crime_scene_coords.
	var coords_raw: Variant = scene.get("coords", null)
	if coords_raw == null:
		coords_raw = src.get("crime_scene_coords", null)
	var coords: Vector3 = _to_vector3(coords_raw)

	# Нулевые/мусорные координаты заменяем реальной позицией локации.
	if coords.length() < 0.01 and not location_id.is_empty():
		coords = CityAtlas.location_world_position(location_id)

	var district_id: String = str(CityAtlas.get_location(location_id).get("district", ""))

	return {
		"location_id": location_id,
		"district": district_id,
		"room": _non_empty_string(scene.get("room", ""), "основное помещение"),
		"coords": coords,
	}


static func _validate_clues(raw: Variant, scene: Dictionary, report: Report) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not (raw is Array):
		report.fail("clues отсутствует или не является массивом")
		return out

	var seen_ids: Dictionary = {}
	var index: int = 0
	for item: Variant in raw as Array:
		index += 1
		if not (item is Dictionary):
			report.warn("clues[%d] не объект — пропущен" % index)
			continue

		var clue: Dictionary = _apply_aliases(item as Dictionary, CLUE_KEY_ALIASES)

		var id: String = str(clue.get("id", "")).strip_edges()
		if id.is_empty():
			id = "CLUE_%d" % index
			report.warn("clues[%d].id пуст — присвоен %s" % [index, id])
		if seen_ids.has(id):
			var fixed: String = "%s_%d" % [id, index]
			report.warn("Дубликат id улики '%s' — переименован в %s" % [id, fixed])
			id = fixed
		seen_ids[id] = true

		var clue_type: String = _enum_or_default(clue.get("type", ""), NoirCrimePromptBuilder.CLUE_TYPES, "DROPPED_ITEM", "clues[%d].type" % index, report)

		var location_id: String = str(clue.get("location_id", "")).strip_edges()
		if location_id.is_empty() or not CityAtlas.has_location(location_id):
			if not location_id.is_empty():
				report.warn("clues[%d].location_id '%s' не существует — перенесён на место преступления" % [index, location_id])
			location_id = str(scene.get("location_id", ""))

		var coords: Vector3 = _to_vector3(clue.get("coords", null))
		if coords.length() < 0.01:
			coords = CityAtlas.location_world_position(location_id)

		var constraint: Dictionary = _validate_constraint(clue.get("points_to", null), index, report)

		var reliability: float = clampf(_to_float(clue.get("reliability", 0.8), 0.8), 0.05, 1.0)
		var difficulty: int = clampi(int(_to_float(clue.get("discovery_difficulty", 2), 2.0)), 1, 5)

		out.append({
			"id": id,
			"type": clue_type,
			"location_id": location_id,
			"coords": coords,
			"points_to": constraint,
			"reliability": reliability,
			"description": _non_empty_string(clue.get("description", ""), "След, оставленный на месте"),
			"requires_scan": bool(clue.get("requires_scan", clue_type in ["FINGERPRINT", "FIBER", "BLOOD_SPATTER"])),
			"discovery_difficulty": difficulty,
			"discovered": false,
			"synthetic": false,
		})

	return out


static func _validate_constraint(raw: Variant, clue_index: int, report: Report) -> Dictionary:
	if not (raw is Dictionary):
		report.fail("clues[%d].points_to отсутствует — улика ни на кого не указывает" % clue_index)
		return {}

	var c: Dictionary = raw as Dictionary
	var attr_name: String = str(c.get("attribute", "")).strip_edges()
	if attr_name.is_empty():
		# Иногда модель кладёт {"shoe_size": 43} вместо {"attribute":..,"value":..}
		for key: Variant in c.keys():
			if NoirCitizen.CONSTRAINT_FIELDS.has(str(key)):
				attr_name = str(key)
				c = {"attribute": attr_name, "value": c[key]}
				report.warn("clues[%d].points_to задан в сокращённой форме — нормализован" % clue_index)
				break

	if not NoirCitizen.CONSTRAINT_FIELDS.has(attr_name):
		report.fail("clues[%d].points_to.attribute '%s' не входит в список допустимых" % [clue_index, attr_name])
		return {}

	var value: Variant = c.get("value", null)
	if value == null:
		report.fail("clues[%d].points_to.value отсутствует" % clue_index)
		return {}

	var mode: String = str(NoirCitizen.CONSTRAINT_FIELDS[attr_name])
	var out: Dictionary = {"attribute": attr_name}

	if attr_name in ["shoe_size", "height_cm"]:
		out["value"] = int(_to_float(value, 0.0))
		if int(out["value"]) <= 0:
			report.fail("clues[%d].points_to.value для %s не число" % [clue_index, attr_name])
			return {}
	else:
		out["value"] = str(value).strip_edges()
		if str(out["value"]).is_empty():
			report.fail("clues[%d].points_to.value пуст" % clue_index)
			return {}

	if mode == "range":
		out["tolerance"] = clampi(int(_to_float(c.get("tolerance", 3), 3.0)), 1, 5)

	return out


static func _validate_alibis(raw: Variant, killer_id: String, report: Report) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not (raw is Array):
		report.warn("alibi_data отсутствует — будет достроено движком")
		return out

	var index: int = 0
	for item: Variant in raw as Array:
		index += 1
		if not (item is Dictionary):
			report.warn("alibi_data[%d] не объект — пропущен" % index)
			continue
		var a: Dictionary = item as Dictionary

		var citizen_id: String = str(a.get("citizen_id", "")).strip_edges()
		if citizen_id.is_empty() or not Citizens.has(citizen_id):
			report.warn("alibi_data[%d].citizen_id '%s' не найден — запись отброшена" % [index, citizen_id])
			continue

		var location_id: String = str(a.get("claimed_location_id", a.get("location_id", ""))).strip_edges()
		if not location_id.is_empty() and not CityAtlas.has_location(location_id):
			report.warn("alibi_data[%d].claimed_location_id '%s' не существует — очищен" % [index, location_id])
			location_id = ""

		var status: String = _enum_or_default(a.get("status", ""), NoirCrimePromptBuilder.ALIBI_STATUSES, "unverified", "alibi_data[%d].status" % index, report)

		# Ключевое правило: убийца не может иметь подтверждённое алиби.
		if citizen_id == killer_id and status == "verified":
			report.fail("У убийцы alibi_status = verified — дело нерешаемо")

		var witness_id: String = str(a.get("witness_id", "")).strip_edges()
		if not witness_id.is_empty() and not Citizens.has(witness_id):
			report.warn("alibi_data[%d].witness_id '%s' не найден — очищен" % [index, witness_id])
			witness_id = ""

		var window_text: String = str(a.get("time_window", "")).strip_edges()
		var window: Dictionary = _parse_window(window_text)
		if window.is_empty():
			report.warn("alibi_data[%d].time_window '%s' не разобран — подставлено 22:00-01:00" % [index, window_text])
			window = {"from": 22 * 60, "to": 25 * 60}

		out.append({
			"citizen_id": citizen_id,
			"claim": _non_empty_string(a.get("claim", ""), "Утверждает, что был не здесь"),
			"claimed_location_id": location_id,
			"time_window": NoirWorldClock.format_minutes(int(window["from"])) + "-" + NoirWorldClock.format_minutes(int(window["to"])),
			"window_from": int(window["from"]),
			"window_to": int(window["to"]),
			"status": status,
			"witness_id": witness_id,
			"checked": false,
		})

	return out


static func _validate_red_herrings(raw: Variant, clues: Array[Dictionary], killer_id: String, report: Report) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not (raw is Array):
		report.warn("red_herrings отсутствует — дело будет без ложных следов")
		return out

	var clue_ids: Dictionary = {}
	for clue: Dictionary in clues:
		clue_ids[str(clue["id"])] = true

	var index: int = 0
	for item: Variant in raw as Array:
		index += 1
		if not (item is Dictionary):
			continue
		var rh: Dictionary = item as Dictionary

		var implicates: String = str(rh.get("implicates_id", "")).strip_edges()
		if implicates.is_empty() or not Citizens.has(implicates):
			report.warn("red_herrings[%d].implicates_id '%s' не найден — след отброшен" % [index, implicates])
			continue
		if implicates == killer_id:
			report.warn("red_herrings[%d] указывает на настоящего убийцу — это не ложный след, отброшен" % index)
			continue

		var refuted_by: String = str(rh.get("refuted_by", "")).strip_edges()
		if not clue_ids.has(refuted_by):
			if clues.is_empty():
				report.warn("red_herrings[%d].refuted_by не привязать — след отброшен" % index)
				continue
			var replacement: String = str(clues[0]["id"])
			report.warn("red_herrings[%d].refuted_by '%s' не существует — привязан к %s" % [index, refuted_by, replacement])
			refuted_by = replacement

		var location_id: String = str(rh.get("location_id", "")).strip_edges()
		if location_id.is_empty() or not CityAtlas.has_location(location_id):
			location_id = str(clues[0]["location_id"]) if not clues.is_empty() else ""

		out.append({
			"id": _non_empty_string(rh.get("id", ""), "RH_%d" % index),
			"description": _non_empty_string(rh.get("description", ""), "Подозрительная деталь, не имеющая отношения к делу"),
			"implicates_id": implicates,
			"refuted_by": refuted_by,
			"location_id": location_id,
			"discovered": false,
		})

	return out


static func _validate_chain(raw: Variant, clues: Array[Dictionary], report: Report) -> PackedStringArray:
	var out: PackedStringArray = []
	var clue_ids: Dictionary = {}
	for clue: Dictionary in clues:
		clue_ids[str(clue["id"])] = true

	if raw is Array:
		for item: Variant in raw as Array:
			var id: String = str(item).strip_edges()
			if clue_ids.has(id) and not out.has(id):
				out.append(id)
			elif not id.is_empty():
				report.warn("solution_chain ссылается на несуществующую улику '%s' — элемент отброшен" % id)
	else:
		report.warn("solution_chain отсутствует — будет построена движком")

	if out.is_empty() and not clues.is_empty():
		report.warn("solution_chain пуста — движок построит её сам")

	return out


# -------------------------------------------------------------------- утилиты

static func _apply_aliases(source: Dictionary, aliases: Dictionary) -> Dictionary:
	var out: Dictionary = source.duplicate(true)
	for alias: Variant in aliases.keys():
		var canonical: String = str(aliases[alias])
		if out.has(alias) and not out.has(canonical):
			out[canonical] = out[alias]
	return out


static func _non_empty_string(value: Variant, fallback: String) -> String:
	var text: String = str(value).strip_edges() if value != null else ""
	return text if not text.is_empty() else fallback


static func _enum_or_default(value: Variant, allowed: PackedStringArray, fallback: String, field: String, report: Report) -> String:
	var text: String = str(value).strip_edges()
	if allowed.has(text):
		return text
	var lowered: String = text.to_lower()
	for option: String in allowed:
		if option.to_lower() == lowered:
			return option
	if not text.is_empty():
		report.warn("%s = '%s' вне списка допустимых — заменено на '%s'" % [field, text, fallback])
	return fallback


static func _to_float(value: Variant, fallback: float) -> float:
	if value is float:
		return value as float
	if value is int:
		return float(value)
	if value is bool:
		return 1.0 if value else 0.0
	if value is String and (value as String).is_valid_float():
		return (value as String).to_float()
	return fallback


static func _to_vector3(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw as Vector3
	if raw is Array:
		var arr: Array = raw as Array
		if arr.size() >= 3:
			return Vector3(_to_float(arr[0], 0.0), _to_float(arr[1], 0.0), _to_float(arr[2], 0.0))
		if arr.size() == 2:
			return Vector3(_to_float(arr[0], 0.0), 0.0, _to_float(arr[1], 0.0))
	if raw is Dictionary:
		var d: Dictionary = raw as Dictionary
		return Vector3(_to_float(d.get("x", 0), 0.0), _to_float(d.get("y", 0), 0.0), _to_float(d.get("z", 0), 0.0))
	return Vector3.ZERO


static func _parse_window(text: String) -> Dictionary:
	var normalized: String = text.replace("—", "-").replace("–", "-").replace(" ", "")
	var parts: PackedStringArray = normalized.split("-")
	if parts.size() < 2:
		return {}
	var from_min: int = WorldClock.parse_hhmm(parts[0], -1)
	var to_min: int = WorldClock.parse_hhmm(parts[1], -1)
	if from_min < 0 or to_min < 0:
		return {}
	if to_min <= from_min:
		to_min += 1440  # окно через полночь
	return {"from": from_min, "to": to_min}


static func _fallback_location_id() -> String:
	var ids: Array[String] = CityAtlas.location_ids()
	return ids[0] if not ids.is_empty() else ""
