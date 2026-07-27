class_name NoirSolvabilityValidator
extends RefCounted
## Гарант решаемости дела. Не просто проверяет — **ремонтирует**.
##
## Инвариант, который держит этот класс: после [method enforce] набор улик
## сужает круг подозреваемых **ровно до одного человека — убийцы**, при этом
## каждая улика буквально согласована с реальными полями NPC.
##
## Ремонтные операции (в порядке применения):
##  1. Улика противоречит убийце -> значение улики правится на фактическое.
##  2. Круг шире одного -> добавляется улика с уникальным признаком.
##  3. Нет твёрдого доказательства -> добавляется отпечаток.
##  4. Пустая/битая цепочка решения -> строится жадным минимальным покрытием.
##  5. Алиби убийцы «подтверждено»/отсутствует -> переводится в contradicted.
##  6. Улик слишком мало -> добираются производные от признаков убийцы.
##
## Из-за этого «логический тупик» невозможен: даже полностью бессмысленный ответ
## модели превращается в корректное дело (с пометкой о числе правок).

const MAX_DISCRIMINATOR_ROUNDS := 6
const HARD_EVIDENCE_TYPES: PackedStringArray = ["FINGERPRINT", "CAMERA_RECORDING"]


class Report extends RefCounted:
	var errors: PackedStringArray = []
	var repairs: PackedStringArray = []
	var data: Dictionary = {}
	var candidate_count: int = 0

	func ok() -> bool:
		return errors.is_empty()

	func summary() -> String:
		return "правок=%d ошибок=%d круг=%d" % [repairs.size(), errors.size(), candidate_count]


## Приводит дело к решаемому виду. [param data] — нормализованный вывод
## `NoirCrimeSchema.validate`. Возвращает отчёт с исправленными данными.
static func enforce(data: Dictionary) -> Report:
	var report := Report.new()
	report.data = data.duplicate(true)

	var killer_id: String = str(report.data.get("killer_id", ""))
	var killer: NoirCitizen = Citizens.get_citizen(killer_id)
	if killer == null:
		report.errors.append("Убийца '%s' отсутствует в реестре — дело неремонтопригодно" % killer_id)
		return report

	var victim_id: String = str(report.data.get("victim_id", ""))
	var victim: NoirCitizen = Citizens.get_citizen(victim_id)
	if victim == null:
		report.errors.append("Жертва '%s' отсутствует в реестре — дело неремонтопригодно" % victim_id)
		return report

	var clues: Array[Dictionary] = _clues_of(report.data)

	_repair_contradicting_clues(clues, killer, report)
	_ensure_minimum_clues(clues, killer, report)
	_ensure_hard_evidence(clues, killer, report)
	_narrow_to_single_suspect(clues, killer, report)
	_clamp_clue_positions(clues, report)

	report.data["clues"] = clues
	report.data["solution_chain"] = _build_solution_chain(clues, killer_id, report)
	report.data["alibi_data"] = _repair_alibis(report.data, killer, victim, report)
	report.data["red_herrings"] = _repair_red_herrings(report.data, clues, killer_id, report)
	_ensure_narrative(report.data, killer, victim, report)
	_scrub_spoilers(report.data, killer, report)

	var final_candidates: Array[String] = _candidates_for(clues)
	report.candidate_count = final_candidates.size()
	report.data["suspect_pool"] = final_candidates
	report.data["solvable"] = final_candidates.size() == 1 and final_candidates[0] == killer_id
	report.data["repair_count"] = report.repairs.size()

	if not bool(report.data["solvable"]):
		# Последний рубеж: жёстко добавляем отпечаток убийцы и пересчитываем.
		_append_clue(clues, _make_fingerprint_clue(clues, killer, report.data), report, "аварийная улика-отпечаток для схождения круга")
		report.data["clues"] = clues
		var recheck: Array[String] = _candidates_for(clues)
		report.candidate_count = recheck.size()
		report.data["suspect_pool"] = recheck
		report.data["solvable"] = recheck.size() == 1 and recheck[0] == killer_id
		report.data["solution_chain"] = _build_solution_chain(clues, killer_id, report)
		if not bool(report.data["solvable"]):
			report.errors.append("Круг подозреваемых не сошёлся к одному даже после аварийной улики (осталось %d)" % recheck.size())

	return report


# ------------------------------------------------------------------ ремонт улик

## Шаг 1. Улика, противоречащая убийце, — главный источник тупиков.
## Правим её значение на фактическое значение поля убийцы.
static func _repair_contradicting_clues(clues: Array[Dictionary], killer: NoirCitizen, report: Report) -> void:
	for clue: Dictionary in clues:
		var constraint: Variant = clue.get("points_to", null)
		if not (constraint is Dictionary) or (constraint as Dictionary).is_empty():
			continue
		var c: Dictionary = constraint as Dictionary
		if killer.matches(c):
			continue

		var attr_name: String = str(c.get("attribute", ""))
		var actual: Variant = killer.attribute(attr_name)
		if actual == null:
			continue

		var old_value: Variant = c.get("value", null)
		if attr_name == "owned_item":
			c["value"] = killer.owned_items[0] if killer.owned_items.size() > 0 else "зажигалка с гравировкой"
		else:
			c["value"] = actual
		clue["points_to"] = c
		clue["repaired"] = true
		report.repairs.append("Улика %s (%s): значение %s -> %s (согласовано с убийцей)" % [
			str(clue.get("id", "?")), attr_name, str(old_value), str(c["value"]),
		])


## Шаг 6. Слишком мало улик — детективу не за что зацепиться.
static func _ensure_minimum_clues(clues: Array[Dictionary], killer: NoirCitizen, report: Report) -> void:
	var minimum: int = clampi(GameConfig.get_int("crime", "min_clues"), 3, 12)
	if clues.size() >= minimum:
		return

	var derivable: Array[Dictionary] = [
		{"attribute": "shoe_size", "value": killer.shoe_size, "type": "FOOTPRINT",
			"text": "Отпечаток подошвы, размер %d, %s" % [killer.shoe_size, killer.shoe_type]},
		{"attribute": "height_cm", "value": killer.height_cm, "tolerance": 3, "type": "CAMERA_RECORDING",
			"text": "Запись камеры: силуэт роста около %d см" % killer.height_cm},
		{"attribute": "blood_type", "value": killer.blood_type, "type": "BLOOD_SPATTER",
			"text": "Капля крови не принадлежит жертве: группа %s" % killer.blood_type},
		{"attribute": "hair_color", "value": killer.hair_color, "type": "FIBER",
			"text": "Волос на воротнике жертвы: %s" % killer.hair_color},
		{"attribute": "handedness", "value": killer.handedness, "type": "WEAPON_TRACE",
			"text": "Характер удара выдаёт: %s" % killer.handedness},
		{"attribute": "shoe_type", "value": killer.shoe_type, "type": "FOOTPRINT",
			"text": "Рисунок протектора: %s" % killer.shoe_type},
	]

	var existing_attrs: Dictionary = {}
	for clue: Dictionary in clues:
		var c: Variant = clue.get("points_to", null)
		if c is Dictionary:
			existing_attrs[str((c as Dictionary).get("attribute", ""))] = true

	for template: Dictionary in derivable:
		if clues.size() >= minimum:
			break
		var attr_name: String = str(template["attribute"])
		if existing_attrs.has(attr_name):
			continue
		existing_attrs[attr_name] = true

		var constraint: Dictionary = {"attribute": attr_name, "value": template["value"]}
		if template.has("tolerance"):
			constraint["tolerance"] = int(template["tolerance"])

		_append_clue(clues, {
			"id": "CLUE_AUTO_%d" % (clues.size() + 1),
			"type": str(template["type"]),
			"location_id": _scene_location_of(clues),
			"coords": _scene_coords_of(clues),
			"points_to": constraint,
			"reliability": 0.75,
			"description": str(template["text"]),
			"requires_scan": str(template["type"]) in ["FINGERPRINT", "FIBER", "BLOOD_SPATTER"],
			"discovery_difficulty": 3,
			"discovered": false,
			"synthetic": true,
		}, report, "добор улик до минимума (%d)" % minimum)


## Шаг 3. Без твёрдого доказательства обвинение недоказуемо.
static func _ensure_hard_evidence(clues: Array[Dictionary], killer: NoirCitizen, report: Report) -> void:
	for clue: Dictionary in clues:
		if HARD_EVIDENCE_TYPES.has(str(clue.get("type", ""))):
			return
	_append_clue(clues, _make_fingerprint_clue(clues, killer, {}), report, "нет твёрдого доказательства")


## Шаг 2. Сужаем круг до одного человека.
static func _narrow_to_single_suspect(clues: Array[Dictionary], killer: NoirCitizen, report: Report) -> void:
	for round_index: int in range(MAX_DISCRIMINATOR_ROUNDS):
		var candidates: Array[String] = _candidates_for(clues)
		if candidates.size() <= 1:
			return

		var discriminator: Dictionary = Citizens.unique_discriminator(killer.id, candidates)
		if discriminator.is_empty():
			break

		var attr_name: String = str(discriminator["attribute"])
		_append_clue(clues, {
			"id": "CLUE_KEY_%d" % (round_index + 1),
			"type": _clue_type_for_attribute(attr_name),
			"location_id": _scene_location_of(clues),
			"coords": _scene_coords_of(clues),
			"points_to": discriminator,
			"reliability": 0.95,
			"description": _describe_constraint(discriminator),
			"requires_scan": attr_name in ["fingerprint_id", "blood_type"],
			"discovery_difficulty": 4,
			"discovered": false,
			"synthetic": true,
		}, report, "круг был шире одного (%d кандидатов)" % candidates.size())

	var leftover: Array[String] = _candidates_for(clues)
	if leftover.size() > 1:
		_append_clue(clues, _make_fingerprint_clue(clues, killer, {}), report, "принудительное сужение круга (%d кандидатов)" % leftover.size())


static func _clamp_clue_positions(clues: Array[Dictionary], report: Report) -> void:
	var bounds: Rect2 = CityAtlas.world_bounds()
	for clue: Dictionary in clues:
		var pos: Variant = clue.get("coords", null)
		if not (pos is Vector3):
			clue["coords"] = CityAtlas.location_world_position(str(clue.get("location_id", "")))
			continue
		var p: Vector3 = pos as Vector3
		var clamped := Vector3(
			clampf(p.x, bounds.position.x, bounds.end.x),
			clampf(p.y, -40.0, 400.0),
			clampf(p.z, bounds.position.y, bounds.end.y)
		)
		if not clamped.is_equal_approx(p):
			clue["coords"] = clamped
			report.repairs.append("Улика %s: координаты выведены за пределы мира и подрезаны" % str(clue.get("id", "?")))


# --------------------------------------------------------------- цепочка решения

## Шаг 4. Жадное минимальное покрытие: берём улики, сильнее всего сужающие круг,
## пока не останется один подозреваемый.
static func _build_solution_chain(clues: Array[Dictionary], killer_id: String, report: Report) -> PackedStringArray:
	var chain: PackedStringArray = []
	var pool: Array[String] = Citizens.all_ids()
	var remaining: Array[Dictionary] = clues.duplicate()
	var guard: int = 0

	while pool.size() > 1 and not remaining.is_empty() and guard < 32:
		guard += 1
		var best_index: int = -1
		var best_size: int = pool.size() + 1

		for i: int in range(remaining.size()):
			var constraint: Variant = remaining[i].get("points_to", null)
			if not (constraint is Dictionary) or (constraint as Dictionary).is_empty():
				continue
			var narrowed: Array[String] = Citizens.filter_by_constraint(constraint as Dictionary, pool)
			if not narrowed.has(killer_id):
				continue  # такая улика исключила бы убийцу — в цепочку не годится
			if narrowed.size() < best_size:
				best_size = narrowed.size()
				best_index = i

		if best_index < 0:
			break

		var chosen: Dictionary = remaining[best_index]
		remaining.remove_at(best_index)
		var constraint_used: Dictionary = chosen["points_to"]
		var next_pool: Array[String] = Citizens.filter_by_constraint(constraint_used, pool)
		if next_pool.size() >= pool.size():
			continue  # улика ничего не сузила — в цепочку не добавляем
		pool = next_pool
		chain.append(str(chosen["id"]))

	if chain.is_empty() and not clues.is_empty():
		chain.append(str(clues[0]["id"]))
		report.repairs.append("Цепочка решения не строилась — использована первая улика как минимум")

	return chain


# --------------------------------------------------------------------- алиби

## Шаг 5. Алиби убийцы всегда опровержимо; остальным добираем правдоподобные.
static func _repair_alibis(data: Dictionary, killer: NoirCitizen, victim: NoirCitizen, report: Report) -> Array[Dictionary]:
	var alibis: Array[Dictionary] = []
	var raw: Variant = data.get("alibi_data", null)
	if raw is Array:
		for item: Variant in raw as Array:
			if item is Dictionary:
				alibis.append(item as Dictionary)

	var tod: int = int(data.get("time_of_death_minutes", 23 * 60 + 40))
	var scene: Dictionary = data.get("crime_scene", {})
	var scene_location: String = str(scene.get("location_id", ""))

	var killer_entry_index: int = -1
	for i: int in range(alibis.size()):
		if str(alibis[i].get("citizen_id", "")) == killer.id:
			killer_entry_index = i
			break

	if killer_entry_index < 0:
		alibis.append(_make_alibi(killer, tod, "contradicted", scene_location, true))
		report.repairs.append("У убийцы не было записи алиби — добавлена опровергнутая")
	else:
		var entry: Dictionary = alibis[killer_entry_index]
		var status: String = str(entry.get("status", "unverified"))
		if status == "verified":
			entry["status"] = "contradicted"
			entry["witness_id"] = ""
			report.repairs.append("Алиби убийцы было verified -> переведено в contradicted")
		if str(entry.get("claimed_location_id", "")) == scene_location:
			entry["claimed_location_id"] = killer.home_location_id
			report.repairs.append("Убийца «утверждал», что был на месте убийства — заявленное место заменено на его дом")
		# Окно алиби обязано накрывать время смерти, иначе его нечем опровергать.
		if not _window_covers(entry, tod):
			entry["window_from"] = tod - 60
			entry["window_to"] = tod + 60
			entry["time_window"] = "%s-%s" % [NoirWorldClock.format_minutes(tod - 60), NoirWorldClock.format_minutes(tod + 60)]
			report.repairs.append("Окно алиби убийцы не накрывало время смерти — расширено")
		alibis[killer_entry_index] = entry

	# Жертва не даёт показаний.
	var filtered: Array[Dictionary] = []
	for entry: Dictionary in alibis:
		if str(entry.get("citizen_id", "")) == victim.id:
			report.repairs.append("Удалено алиби жертвы — она не может давать показания")
			continue
		filtered.append(entry)
	alibis = filtered

	# Добираем алиби до разумного минимума из круга подозреваемых.
	var wanted: int = 4
	if alibis.size() < wanted:
		var pool: Array[String] = []
		var raw_pool: Variant = data.get("suspect_pool", null)
		if raw_pool is Array:
			for v: Variant in raw_pool as Array:
				pool.append(str(v))
		for r: Dictionary in killer.relationships:
			var other_id: String = str(r.get("other_id", ""))
			if not pool.has(other_id):
				pool.append(other_id)

		var rng := RandomNumberGenerator.new()
		rng.seed = hash(killer.id + victim.id)
		var guard: int = 0
		while alibis.size() < wanted and guard < 60:
			guard += 1
			var pick_id: String = pool[rng.randi_range(0, pool.size() - 1)] if not pool.is_empty() else Citizens.random_id(rng)
			if pick_id.is_empty() or pick_id == victim.id:
				continue
			var already: bool = false
			for entry: Dictionary in alibis:
				if str(entry.get("citizen_id", "")) == pick_id:
					already = true
					break
			if already:
				continue
			var person: NoirCitizen = Citizens.get_citizen(pick_id)
			if person == null:
				continue
			var status: String = "verified" if pick_id != killer.id and rng.randf() < 0.65 else "unverified"
			alibis.append(_make_alibi(person, tod, status, person.location_at_minute(tod), false))

	return alibis


static func _make_alibi(person: NoirCitizen, tod: int, status: String, claimed_location: String, is_killer: bool) -> Dictionary:
	var from_min: int = tod - 60
	var to_min: int = tod + 60
	var claim_text: String = ""
	if is_killer:
		claim_text = "Утверждает, что весь вечер был у себя (%s). Подтвердить некому." % (claimed_location if not claimed_location.is_empty() else "дома")
	else:
		claim_text = "Утверждает, что находился в «%s»." % str(CityAtlas.get_location(claimed_location).get("name", "неизвестном месте"))

	return {
		"citizen_id": person.id,
		"claim": claim_text,
		"claimed_location_id": claimed_location,
		"time_window": "%s-%s" % [NoirWorldClock.format_minutes(from_min), NoirWorldClock.format_minutes(to_min)],
		"window_from": from_min,
		"window_to": to_min,
		"status": status,
		"witness_id": "",
		"checked": false,
	}


static func _window_covers(entry: Dictionary, minute: int) -> bool:
	var from_min: int = int(entry.get("window_from", -1))
	var to_min: int = int(entry.get("window_to", -1))
	if from_min < 0 or to_min < 0:
		return false
	var m: int = minute
	if to_min > 1440 and m < from_min:
		m += 1440
	return m >= from_min and m <= to_min


# ---------------------------------------------------------------- ложные следы

static func _repair_red_herrings(data: Dictionary, clues: Array[Dictionary], killer_id: String, report: Report) -> Array[Dictionary]:
	var herrings: Array[Dictionary] = []
	var raw: Variant = data.get("red_herrings", null)
	if raw is Array:
		for item: Variant in raw as Array:
			if item is Dictionary:
				herrings.append(item as Dictionary)

	var clue_ids: Dictionary = {}
	for clue: Dictionary in clues:
		clue_ids[str(clue["id"])] = true

	# Каждый ложный след обязан быть опровергаемым существующей уликой.
	for entry: Dictionary in herrings:
		if not clue_ids.has(str(entry.get("refuted_by", ""))) and not clues.is_empty():
			entry["refuted_by"] = str(clues[0]["id"])
			report.repairs.append("Ложный след %s перепривязан к существующей улике" % str(entry.get("id", "?")))

	if not herrings.is_empty():
		return herrings

	# Ни одного ложного следа — генерируем один, чтобы дело не было тривиальным.
	var killer: NoirCitizen = Citizens.get_citizen(killer_id)
	if killer == null or clues.is_empty():
		return herrings

	var patsy_id: String = ""
	for r: Dictionary in killer.relationships:
		var candidate: String = str(r.get("other_id", ""))
		if candidate != killer_id and candidate != str(data.get("victim_id", "")) and Citizens.has(candidate):
			patsy_id = candidate
			break
	if patsy_id.is_empty():
		return herrings

	var patsy: NoirCitizen = Citizens.get_citizen(patsy_id)
	herrings.append({
		"id": "RH_AUTO_1",
		"description": "Рядом с телом найден предмет, который многие связывают с %s. Совпадение — но следствие уже пошло по этому следу." % patsy.full_name(),
		"implicates_id": patsy_id,
		"refuted_by": str(clues[0]["id"]),
		"location_id": str(clues[0]["location_id"]),
		"discovered": false,
	})
	report.repairs.append("Ложных следов не было — добавлен один, указывающий на %s" % patsy.full_name())
	return herrings


# ---------------------------------------------------------------- повествование

static func _ensure_narrative(data: Dictionary, killer: NoirCitizen, victim: NoirCitizen, report: Report) -> void:
	var narrative: Variant = data.get("narrative", null)
	var n: Dictionary = narrative as Dictionary if narrative is Dictionary else {}

	var scene: Dictionary = data.get("crime_scene", {})
	var location_name: String = str(CityAtlas.get_location(str(scene.get("location_id", ""))).get("name", "неизвестное место"))
	var district: Dictionary = CityAtlas.get_district(str(scene.get("district", "")))
	var district_name: String = str(district.get("ru", "город"))
	var time_text: String = str(data.get("time_of_death", "??:??"))

	if str(n.get("opening", "")).strip_edges().is_empty():
		n["opening"] = "Дождь не прекращался с полуночи. %s, %s — неон отражается в лужах, и в этих отражениях лежит %s. Время смерти: %s. Город уже забыл это имя; ты пока нет." % [
			district_name, location_name, victim.full_name(), time_text,
		]
		report.repairs.append("Вступление отсутствовало — сгенерировано движком")

	if str(n.get("police_report", "")).strip_edges().is_empty():
		n["police_report"] = "РАПОРТ. Обнаружено тело: %s, %d лет, %s. Место: %s (%s). Предполагаемое время смерти: %s. Орудие: %s. Свидетели опрашиваются. Дело передано в отдел тяжких." % [
			victim.full_name(), victim.age, victim.job, location_name, district_name, time_text,
			str((data.get("weapon", {}) as Dictionary).get("name", "не установлено")),
		]
		report.repairs.append("Протокол отсутствовал — сгенерирован движком")

	data["narrative"] = n


## Вычищает имя убийцы из всех игровых текстов.
##
## Модель охотно пишет «Медальон принадлежит Clara Grimsby» — и дедукция теряет
## смысл: игрок получает ответ бесплатно. Подстановка синонима сломала бы падежи,
## поэтому описание улики **переписывается заново** из её же ограничения через
## [method _describe_constraint] — так текст всегда грамматичен и нейтрален.
##
## Сравнивается только полное имя «Имя Фамилия»: фамилии в городе повторяются,
## и замена одной фамилии искалечила бы текст про жертву или свидетеля.
static func _scrub_spoilers(data: Dictionary, killer: NoirCitizen, report: Report) -> void:
	var killer_name: String = killer.full_name()
	if killer_name.strip_edges().length() < 4:
		return

	# --- улики ---------------------------------------------------------------
	var clues: Variant = data.get("clues", null)
	if clues is Array:
		for item: Variant in clues as Array:
			if not (item is Dictionary):
				continue
			var clue: Dictionary = item as Dictionary
			var description: String = str(clue.get("description", ""))
			if not description.contains(killer_name):
				continue
			var constraint: Variant = clue.get("points_to", null)
			if constraint is Dictionary and not (constraint as Dictionary).is_empty():
				clue["description"] = _describe_constraint(constraint as Dictionary)
			else:
				clue["description"] = "След, оставленный на месте. Личность пока не установлена."
			report.repairs.append("Улика %s: описание называло убийцу по имени — переписано нейтрально" % str(clue.get("id", "?")))

	# --- ложные следы --------------------------------------------------------
	# Указывать на невиновного по имени — это и есть смысл ложного следа,
	# но упоминание убийцы здесь недопустимо.
	var herrings: Variant = data.get("red_herrings", null)
	if herrings is Array:
		for item: Variant in herrings as Array:
			if not (item is Dictionary):
				continue
			var herring: Dictionary = item as Dictionary
			var description: String = str(herring.get("description", ""))
			if not description.contains(killer_name):
				continue
			var patsy: NoirCitizen = Citizens.get_citizen(str(herring.get("implicates_id", "")))
			var patsy_name: String = patsy.full_name() if patsy != null else "один из жильцов"
			herring["description"] = "Следствие зацепилось за %s: слишком много совпадений, и все поверхностные." % patsy_name
			report.repairs.append("Ложный след %s: описание называло убийцу — переписано" % str(herring.get("id", "?")))

	# --- вступление и протокол ----------------------------------------------
	var narrative: Variant = data.get("narrative", null)
	if narrative is Dictionary:
		var n: Dictionary = narrative as Dictionary
		for key: String in ["opening", "police_report"]:
			var text: String = str(n.get(key, ""))
			if text.contains(killer_name):
				n[key] = text.replace(killer_name, "неизвестный")
				report.repairs.append("Из текста «%s» удалено имя убийцы — спойлер" % key)


# -------------------------------------------------------------------- утилиты

static func _clues_of(data: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = data.get("clues", null)
	if raw is Array:
		for item: Variant in raw as Array:
			if item is Dictionary:
				out.append(item as Dictionary)
	return out


static func _candidates_for(clues: Array[Dictionary]) -> Array[String]:
	var constraints: Array = []
	for clue: Dictionary in clues:
		var c: Variant = clue.get("points_to", null)
		if c is Dictionary and not (c as Dictionary).is_empty():
			constraints.append(c)
	return Citizens.candidates_matching(constraints)


static func _append_clue(clues: Array[Dictionary], clue: Dictionary, report: Report, reason: String) -> void:
	if clue.is_empty():
		return
	clues.append(clue)
	report.repairs.append("Добавлена улика %s (%s): %s" % [str(clue.get("id", "?")), str(clue.get("type", "?")), reason])


static func _make_fingerprint_clue(clues: Array[Dictionary], killer: NoirCitizen, data: Dictionary) -> Dictionary:
	var location_id: String = _scene_location_of(clues)
	if location_id.is_empty() and data.has("crime_scene"):
		location_id = str((data["crime_scene"] as Dictionary).get("location_id", ""))
	return {
		"id": "CLUE_FP_%d" % (clues.size() + 1),
		"type": "FINGERPRINT",
		"location_id": location_id,
		"coords": _scene_coords_of(clues),
		"points_to": {"attribute": "fingerprint_id", "value": killer.fingerprint_id},
		"reliability": 0.98,
		"description": "Частичный отпечаток на поверхности. Идентификатор в базе: %s." % killer.fingerprint_id,
		"requires_scan": true,
		"discovery_difficulty": 4,
		"discovered": false,
		"synthetic": true,
	}


static func _scene_location_of(clues: Array[Dictionary]) -> String:
	for clue: Dictionary in clues:
		var id: String = str(clue.get("location_id", ""))
		if not id.is_empty():
			return id
	var ids: Array[String] = CityAtlas.location_ids()
	return ids[0] if not ids.is_empty() else ""


static func _scene_coords_of(clues: Array[Dictionary]) -> Vector3:
	for clue: Dictionary in clues:
		var pos: Variant = clue.get("coords", null)
		if pos is Vector3 and (pos as Vector3).length() > 0.01:
			return pos as Vector3
	return CityAtlas.location_world_position(_scene_location_of(clues))


static func _clue_type_for_attribute(attr_name: String) -> String:
	match attr_name:
		"fingerprint_id": return "FINGERPRINT"
		"shoe_size", "shoe_type": return "FOOTPRINT"
		"blood_type": return "BLOOD_SPATTER"
		"hair_color", "eye_color": return "FIBER"
		"height_cm", "build", "gender": return "CAMERA_RECORDING"
		"vehicle_plate", "vehicle_type": return "TIRE_TRACK"
		"owned_item": return "DROPPED_ITEM"
		"handedness": return "WEAPON_TRACE"
		"job", "home_district": return "WITNESS_STATEMENT"
		"tattoo": return "WITNESS_STATEMENT"
		_: return "DROPPED_ITEM"


static func _describe_constraint(constraint: Dictionary) -> String:
	var attr_name: String = str(constraint.get("attribute", ""))
	var value: Variant = constraint.get("value", "")
	match attr_name:
		"fingerprint_id": return "Чёткий отпечаток. В базе он значится как %s." % str(value)
		"shoe_size": return "Отпечаток обуви: размер %s." % str(value)
		"shoe_type": return "По рисунку протектора — %s." % str(value)
		"height_cm": return "Запись камеры позволяет оценить рост: около %s см." % str(value)
		"blood_type": return "Кровь на осколке не жертвы. Группа %s." % str(value)
		"hair_color": return "Волос, оставленный не жертвой: %s." % str(value)
		"eye_color": return "Свидетель запомнил глаза: %s." % str(value)
		"handedness": return "Траектория удара говорит, что бил %s." % str(value)
		"vehicle_plate": return "Камера у выезда поймала номер: %s." % str(value)
		"vehicle_type": return "У чёрного хода стоял %s." % str(value)
		"tattoo": return "Свидетель заметил татуировку: %s." % str(value)
		"job": return "По манере обращения с предметом — профессия: %s." % str(value)
		"home_district": return "Билет в кармане указывает на район: %s." % str(value)
		"gender": return "По походке на записи — %s." % str(value)
		"build": return "Телосложение на записи: %s." % str(value)
		"owned_item": return "На месте забыт предмет: %s." % str(value)
		_: return "След, указывающий на признак «%s» = %s." % [attr_name, str(value)]
