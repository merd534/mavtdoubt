class_name NoirCaseFile
extends RefCounted
## Активное дело: состояние расследования, найденные улики, круг подозреваемых,
## проверка обвинения. Полностью сериализуемо для сохранений.

signal clue_discovered(clue_id: String)
signal herring_discovered(herring_id: String)
signal alibi_checked(citizen_id: String, status: String)
signal suspects_narrowed(remaining: int)
signal case_closed(correct: bool, accused_id: String)

var data: Dictionary = {}
var opened_at_minute: int = 0
var closed: bool = false
var accused_id: String = ""
var accusation_correct: bool = false
var generation_source: String = "unknown"   ## "llm" | "llm_repaired" | "offline"
var repair_notes: PackedStringArray = []

var _clue_index: Dictionary = {}      # clue_id -> Dictionary
var _herring_index: Dictionary = {}


static func from_data(enforced: Dictionary, source: String, repairs: PackedStringArray) -> NoirCaseFile:
	var case_file := NoirCaseFile.new()
	case_file.data = enforced.duplicate(true)
	case_file.generation_source = source
	case_file.repair_notes = repairs.duplicate()
	case_file.opened_at_minute = WorldClock.total_minutes_elapsed()
	case_file._reindex()
	return case_file


func _reindex() -> void:
	_clue_index.clear()
	_herring_index.clear()
	for clue: Dictionary in clues():
		_clue_index[str(clue["id"])] = clue
	for herring: Dictionary in red_herrings():
		_herring_index[str(herring["id"])] = herring


# ---------------------------------------------------------------- базовые поля

func title() -> String:
	return str(data.get("case_title", "Дело без названия"))


func killer_id() -> String:
	return str(data.get("killer_id", ""))


func victim_id() -> String:
	return str(data.get("victim_id", ""))


func motive() -> String:
	return str(data.get("motive", ""))


func motive_category() -> String:
	return str(data.get("motive_category", ""))


func weapon() -> Dictionary:
	var w: Variant = data.get("weapon", null)
	return (w as Dictionary).duplicate(true) if w is Dictionary else {}


func crime_scene() -> Dictionary:
	var s: Variant = data.get("crime_scene", null)
	return (s as Dictionary).duplicate(true) if s is Dictionary else {}


func scene_position() -> Vector3:
	var s: Dictionary = crime_scene()
	var coords: Variant = s.get("coords", null)
	if coords is Vector3:
		return coords as Vector3
	return CityAtlas.location_world_position(str(s.get("location_id", "")))


func time_of_death_minutes() -> int:
	return int(data.get("time_of_death_minutes", 0))


func time_of_death() -> String:
	return str(data.get("time_of_death", "??:??"))


func narrative() -> Dictionary:
	var n: Variant = data.get("narrative", null)
	return (n as Dictionary).duplicate(true) if n is Dictionary else {}


func is_solvable() -> bool:
	return bool(data.get("solvable", false))


func clues() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = data.get("clues", null)
	if raw is Array:
		for item: Variant in raw as Array:
			if item is Dictionary:
				out.append(item as Dictionary)
	return out


func clue(id: String) -> Dictionary:
	var c: Variant = _clue_index.get(id, null)
	return c as Dictionary if c is Dictionary else {}


func red_herrings() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = data.get("red_herrings", null)
	if raw is Array:
		for item: Variant in raw as Array:
			if item is Dictionary:
				out.append(item as Dictionary)
	return out


func alibis() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = data.get("alibi_data", null)
	if raw is Array:
		for item: Variant in raw as Array:
			if item is Dictionary:
				out.append(item as Dictionary)
	return out


func alibi_for(citizen_id: String) -> Dictionary:
	for entry: Dictionary in alibis():
		if str(entry.get("citizen_id", "")) == citizen_id:
			return entry
	return {}


func solution_chain() -> PackedStringArray:
	var raw: Variant = data.get("solution_chain", null)
	var out: PackedStringArray = []
	if raw is PackedStringArray:
		return (raw as PackedStringArray).duplicate()
	if raw is Array:
		for item: Variant in raw as Array:
			out.append(str(item))
	return out


# ------------------------------------------------------------- ход расследования

func discovered_clue_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	for c: Dictionary in clues():
		if bool(c.get("discovered", false)):
			out.append(str(c["id"]))
	return out


func discovered_count() -> int:
	return discovered_clue_ids().size()


## Отмечает улику найденной. Возвращает false, если id нет или уже найдена.
func discover_clue(id: String) -> bool:
	var c: Variant = _clue_index.get(id, null)
	if not (c is Dictionary):
		Log.warn("CaseFile", "Попытка открыть несуществующую улику", {"id": id})
		return false
	var clue_dict: Dictionary = c as Dictionary
	if bool(clue_dict.get("discovered", false)):
		return false
	clue_dict["discovered"] = true
	clue_dict["discovered_at"] = WorldClock.total_minutes_elapsed()
	clue_discovered.emit(id)

	var remaining: int = suspects_remaining().size()
	suspects_narrowed.emit(remaining)
	Log.info("CaseFile", "Улика найдена", {"id": id, "тип": str(clue_dict.get("type", "?")), "круг": remaining})
	return true


func discover_herring(id: String) -> bool:
	var h: Variant = _herring_index.get(id, null)
	if not (h is Dictionary):
		return false
	var herring: Dictionary = h as Dictionary
	if bool(herring.get("discovered", false)):
		return false
	herring["discovered"] = true
	herring_discovered.emit(id)
	return true


## Помечает алиби проверенным и возвращает его фактический статус.
func check_alibi(citizen_id: String) -> String:
	for entry: Dictionary in alibis():
		if str(entry.get("citizen_id", "")) == citizen_id:
			entry["checked"] = true
			var status: String = str(entry.get("status", "unverified"))
			alibi_checked.emit(citizen_id, status)
			return status
	return "none"


## Круг подозреваемых по **найденным** уликам. Это то, что видит игрок.
func suspects_remaining() -> Array[String]:
	var constraints: Array = []
	for c: Dictionary in clues():
		if not bool(c.get("discovered", false)):
			continue
		var constraint: Variant = c.get("points_to", null)
		if constraint is Dictionary and not (constraint as Dictionary).is_empty():
			constraints.append(constraint)
	if constraints.is_empty():
		return Citizens.alive_ids()
	return Citizens.candidates_matching(constraints)


## Прогресс 0..1: доля улик из минимальной цепочки решения, которые найдены.
func progress() -> float:
	var chain: PackedStringArray = solution_chain()
	if chain.is_empty():
		var total: int = clues().size()
		return 0.0 if total == 0 else float(discovered_count()) / float(total)
	var found: int = 0
	for id: String in chain:
		var c: Dictionary = clue(id)
		if not c.is_empty() and bool(c.get("discovered", false)):
			found += 1
	return float(found) / float(chain.size())


## Достаточно ли доказательств для обвинения. Не запрещает обвинять «на глаз»,
## но сообщает силу дела — от неё зависит, примет ли прокуратура.
func evidence_strength(target_id: String) -> float:
	var score: float = 0.0
	for c: Dictionary in clues():
		if not bool(c.get("discovered", false)):
			continue
		var constraint: Variant = c.get("points_to", null)
		if not (constraint is Dictionary):
			continue
		var citizen: NoirCitizen = Citizens.get_citizen(target_id)
		if citizen != null and citizen.matches(constraint as Dictionary):
			score += float(c.get("reliability", 0.5))
	return clampf(score / 2.5, 0.0, 1.0)


func can_accuse(target_id: String) -> Dictionary:
	if closed:
		return {"allowed": false, "reason": "Дело уже закрыто", "strength": 0.0}
	if not Citizens.has(target_id):
		return {"allowed": false, "reason": "Такого человека нет в реестре", "strength": 0.0}
	var strength: float = evidence_strength(target_id)
	if strength < 0.35:
		return {"allowed": false, "reason": "Недостаточно доказательств: прокуратура вернёт дело", "strength": strength}
	return {"allowed": true, "reason": "", "strength": strength}


## Выдвигает обвинение. Возвращает результат; закрывает дело.
func accuse(target_id: String) -> Dictionary:
	var gate: Dictionary = can_accuse(target_id)
	if not bool(gate["allowed"]):
		Log.warn("CaseFile", "Обвинение отклонено", {"кого": target_id, "причина": str(gate["reason"])})
		return {"accepted": false, "correct": false, "reason": str(gate["reason"]), "strength": float(gate["strength"])}

	closed = true
	accused_id = target_id
	accusation_correct = target_id == killer_id()
	case_closed.emit(accusation_correct, target_id)
	Log.info("CaseFile", "Дело закрыто", {
		"обвинён": target_id, "верно": accusation_correct,
		"сила_дела": "%.2f" % float(gate["strength"]),
	})
	return {
		"accepted": true,
		"correct": accusation_correct,
		"reason": "",
		"strength": float(gate["strength"]),
		"real_killer_id": killer_id(),
	}


# ---------------------------------------------------------------- сериализация

func to_dict() -> Dictionary:
	var scene: Dictionary = crime_scene()
	var scene_out: Dictionary = scene.duplicate(true)
	if scene_out.get("coords", null) is Vector3:
		var v: Vector3 = scene_out["coords"]
		scene_out["coords"] = [v.x, v.y, v.z]

	var clues_out: Array = []
	for c: Dictionary in clues():
		var copy: Dictionary = c.duplicate(true)
		if copy.get("coords", null) is Vector3:
			var cv: Vector3 = copy["coords"]
			copy["coords"] = [cv.x, cv.y, cv.z]
		clues_out.append(copy)

	var payload: Dictionary = data.duplicate(true)
	payload["crime_scene"] = scene_out
	payload["clues"] = clues_out

	return {
		"version": 1,
		"data": payload,
		"opened_at_minute": opened_at_minute,
		"closed": closed,
		"accused_id": accused_id,
		"accusation_correct": accusation_correct,
		"generation_source": generation_source,
		"repair_notes": Array(repair_notes),
	}


static func from_dict(saved: Dictionary) -> NoirCaseFile:
	var case_file := NoirCaseFile.new()
	var payload: Variant = saved.get("data", null)
	if not (payload is Dictionary):
		Log.error("CaseFile", "Сохранение дела повреждено — поле data отсутствует")
		return case_file

	case_file.data = (payload as Dictionary).duplicate(true)

	# Возвращаем Vector3 из массивов.
	var scene: Variant = case_file.data.get("crime_scene", null)
	if scene is Dictionary:
		var coords: Variant = (scene as Dictionary).get("coords", null)
		if coords is Array and (coords as Array).size() >= 3:
			var arr: Array = coords as Array
			(scene as Dictionary)["coords"] = Vector3(float(arr[0]), float(arr[1]), float(arr[2]))

	var raw_clues: Variant = case_file.data.get("clues", null)
	if raw_clues is Array:
		for item: Variant in raw_clues as Array:
			if not (item is Dictionary):
				continue
			var coords2: Variant = (item as Dictionary).get("coords", null)
			if coords2 is Array and (coords2 as Array).size() >= 3:
				var arr2: Array = coords2 as Array
				(item as Dictionary)["coords"] = Vector3(float(arr2[0]), float(arr2[1]), float(arr2[2]))

	case_file.opened_at_minute = int(saved.get("opened_at_minute", 0))
	case_file.closed = bool(saved.get("closed", false))
	case_file.accused_id = str(saved.get("accused_id", ""))
	case_file.accusation_correct = bool(saved.get("accusation_correct", false))
	case_file.generation_source = str(saved.get("generation_source", "unknown"))
	var notes: Variant = saved.get("repair_notes", [])
	if notes is Array:
		for note: Variant in notes as Array:
			case_file.repair_notes.append(str(note))
	case_file._reindex()
	return case_file


## Человекочитаемая сводка — для лога и дев-панели. Спойлеры отделены.
func debug_summary(reveal_killer: bool = false) -> String:
	var victim: NoirCitizen = Citizens.get_citizen(victim_id())
	var killer: NoirCitizen = Citizens.get_citizen(killer_id())
	var lines: PackedStringArray = []
	lines.append("=== %s ===" % title())
	lines.append("Источник: %s | решаемо: %s | правок при сборке: %d" % [generation_source, str(is_solvable()), repair_notes.size()])
	lines.append("Жертва: %s" % (victim.full_name() if victim != null else victim_id()))
	lines.append("Место: %s (%s), %s" % [
		str(CityAtlas.get_location(str(crime_scene().get("location_id", ""))).get("name", "?")),
		str(CityAtlas.get_district(str(crime_scene().get("district", ""))).get("ru", "?")),
		str(crime_scene().get("room", "?")),
	])
	lines.append("Время смерти: %s | орудие: %s (%s)" % [time_of_death(), str(weapon().get("name", "?")), str(weapon().get("type", "?"))])
	lines.append("Мотив «%s»: %s" % [motive_category(), motive()])
	lines.append("Улик: %d | ложных следов: %d | алиби: %d | цепочка: %s" % [
		clues().size(), red_herrings().size(), alibis().size(), ", ".join(solution_chain()),
	])
	for c: Dictionary in clues():
		var constraint: Dictionary = c.get("points_to", {})
		lines.append("  · %s | %s -> %s=%s (надёжн. %.2f%s)" % [
			str(c["id"]), str(c["type"]),
			str(constraint.get("attribute", "-")), str(constraint.get("value", "-")),
			float(c.get("reliability", 0.0)),
			", синтетическая" if bool(c.get("synthetic", false)) else "",
		])
	if reveal_killer:
		lines.append("СПОЙЛЕР — убийца: %s (%s)" % [killer.full_name() if killer != null else killer_id(), killer_id()])
	return "\n".join(lines)
