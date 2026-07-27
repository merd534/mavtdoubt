extends Node3D
## Стенд проверки Фазы 1. Запускается как главная сцена.
##
## Прогоняет весь конвейер и проверяет инварианты, на которых держится
## «отсутствие багов»: целостность атласа, детерминизм реестра, устойчивость
## парсера JSON, ремонт битых дел, сходимость круга подозреваемых до одного
## человека, работоспособность обвинения и сериализации.
##
## Запуск в консоли:
##   godot --headless --path . res://scenes/dev/Phase1TestBench.tscn
## Стенд сам завершает процесс с кодом 0 (всё зелёное) или 1 (есть провалы).

const TEST_SEED := 987654321

@onready var _spawner: NoirClueSpawner = $ClueSpawner as NoirClueSpawner
@onready var _output: RichTextLabel = $UI/Panel/Output as RichTextLabel
@onready var _camera: Camera3D = $Camera3D as Camera3D
@onready var _ground: MeshInstance3D = $Ground as MeshInstance3D

var _lines: PackedStringArray = []
var _passed: int = 0
var _failed: int = 0
var _headless: bool = false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	if not _headless:
		_build_ground()
	CrimeDirector.attach_spawner(_spawner)
	CrimeDirector.case_ready.connect(_on_case_ready_focus)
	# Даём автозагрузкам завершить _ready перед прогоном.
	await get_tree().process_frame
	await _run_all()


func _run_all() -> void:
	_say("[b]NEON NOIR — ПРОВЕРКА ФАЗЫ 1[/b]")
	_say("Godot %s | рендер: %s | режим: %s" % [
		Engine.get_version_info().get("string", "?"),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")),
		"headless" if _headless else "оконный",
	])
	_say("")

	_test_atlas()
	_test_citizens()
	_test_json_parser()
	_test_schema_rejects_garbage()
	_test_schema_normalizes_aliases()
	await _test_offline_case()
	await _test_investigation_flow()
	await _test_serialization()
	await _test_repair_of_broken_llm_answer()
	await _test_live_llm()

	_say("")
	_say("[b]ИТОГ: пройдено %d, провалено %d[/b]" % [_passed, _failed])
	var log_problems: int = Log.problem_count()
	_say("Записей ERROR/FATAL в логе: %d (тесты 4, 8 и 9 умышленно подают битые данные, поэтому часть из них ожидаема)" % log_problems)

	if _failed == 0:
		_say("[color=#39FF88]ФАЗА 1 ГОТОВА.[/color]")
	else:
		_say("[color=#E8253F]ЕСТЬ ПРОВАЛЕННЫЕ ПРОВЕРКИ — см. выше.[/color]")

	_flush()

	if _headless:
		await get_tree().create_timer(0.2).timeout
		get_tree().quit(0 if _failed == 0 else 1)


# ------------------------------------------------------------------- проверки

func _test_atlas() -> void:
	_section("1. Атлас города")
	_check(CityAtlas.is_built(), "атлас собран")
	_check(CityAtlas.district_ids().size() == NoirCityAtlas.DISTRICT_TABLE.size(),
		"районов: %d" % CityAtlas.district_ids().size())
	_check(CityAtlas.location_count() >= 120,
		"играбельных локаций: %d (референс требует 120+)" % CityAtlas.location_count())
	_check(CityAtlas.bridges().size() == 4, "мостов через реку: %d" % CityAtlas.bridges().size())
	_check(CityAtlas.safehouses().size() == 15, "убежищ: %d (референс: 15)" % CityAtlas.safehouses().size())
	_check(CityAtlas.world_area_km2() >= 8.7,
		"площадь: %.2f км² (референс: 8.7)" % CityAtlas.world_area_km2())
	_check(not CityAtlas.metro_links().is_empty(), "подземная сеть: %d перегонов" % CityAtlas.metro_links().size())

	# Все 16 landmark'ов с референса на месте и попали в валидные районы.
	var landmarks_ok: bool = true
	for row: Dictionary in NoirCityAtlas.LANDMARK_TABLE:
		var loc: Dictionary = CityAtlas.get_location(str(row["id"]))
		if loc.is_empty() or str(loc.get("district", "")).is_empty():
			landmarks_ok = false
			_say("    · потерян landmark: %s" % str(row["id"]))
	_check(landmarks_ok, "все 16 landmark'ов референса зарегистрированы")

	# district_at обязан всегда что-то возвращать — иначе генератор упадёт.
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var bounds: Rect2 = CityAtlas.world_bounds()
	var all_resolved: bool = true
	var addresses_ok: bool = true
	for _i: int in range(400):
		var p := Vector2(
			rng.randf_range(bounds.position.x, bounds.end.x),
			rng.randf_range(bounds.position.y, bounds.end.y)
		)
		if CityAtlas.district_at(p).is_empty():
			all_resolved = false
		if CityAtlas.address_for_point(p).strip_edges().is_empty():
			addresses_ok = false
	_check(all_resolved, "district_at() покрывает 100% площади (400 проб)")
	_check(addresses_ok, "address_for_point() всегда даёт адрес (400 проб)")

	# Река и мосты согласованы.
	var bridges_span_river: bool = true
	for b: Dictionary in CityAtlas.bridges():
		var center: Vector2 = b["center"]
		if not CityAtlas.is_in_river(center):
			bridges_span_river = false
	_check(bridges_span_river, "каждый мост стоит над рекой")


func _test_citizens() -> void:
	_section("2. Реестр жителей")
	_check(Citizens.is_built(), "реестр собран")
	_check(Citizens.count() >= 24, "жителей: %d" % Citizens.count())

	var fingerprints: Dictionary = {}
	var duplicates: int = 0
	var bad_homes: int = 0
	var bad_correlation: int = 0
	for id: String in Citizens.all_ids():
		var c: NoirCitizen = Citizens.get_citizen(id)
		if c == null:
			continue
		if fingerprints.has(c.fingerprint_id):
			duplicates += 1
		fingerprints[c.fingerprint_id] = true
		if not CityAtlas.has_location(c.home_location_id):
			bad_homes += 1
		# Размер обуви должен быть правдоподобен для роста (иначе улики абсурдны).
		var expected: int = int(round(float(c.height_cm) * 0.235))
		if absi(c.shoe_size - expected) > 3:
			bad_correlation += 1

	_check(duplicates == 0, "отпечатки уникальны (дубликатов: %d)" % duplicates)
	_check(bad_homes == 0, "у всех есть валидный адрес (битых: %d)" % bad_homes)
	_check(bad_correlation == 0, "рост и размер обуви скоррелированы (выбросов: %d)" % bad_correlation)

	# Детерминизм: пересборка с тем же сидом даёт тот же результат.
	var sample_id: String = Citizens.all_ids()[3]
	var before: Dictionary = Citizens.get_citizen(sample_id).to_dict()
	Citizens.build(Citizens.count(), CityAtlas.city_seed)
	var after: NoirCitizen = Citizens.get_citizen(sample_id)
	_check(after != null and after.to_dict() == before, "генерация детерминирована по сиду")

	# Симметрия связей — иначе опросы NPC противоречат друг другу.
	var asymmetric: int = 0
	for id: String in Citizens.all_ids():
		var c: NoirCitizen = Citizens.get_citizen(id)
		if c == null:
			continue
		for r: Dictionary in c.relationships:
			var other: NoirCitizen = Citizens.get_citizen(str(r.get("other_id", "")))
			if other == null or not other.has_relationship_with(id):
				asymmetric += 1
	_check(asymmetric == 0, "социальные связи симметричны (разрывов: %d)" % asymmetric)


func _test_json_parser() -> void:
	_section("3. Устойчивость парсера ответа модели")

	var cases: Array[Dictionary] = [
		{"in": "{\"a\":1}", "want": true, "note": "чистый JSON"},
		{"in": "```json\n{\"a\":1}\n```", "want": true, "note": "markdown-обёртка"},
		{"in": "Вот дело:\n{\"a\":{\"b\":2}}\nГотово.", "want": true, "note": "текст вокруг JSON"},
		{"in": "{\"text\":\"скобка } внутри строки\",\"ok\":true}", "want": true, "note": "скобка в строке"},
		{"in": "{\"esc\":\"кавычка \\\" и скобка }\",\"n\":1}", "want": true, "note": "экранирование"},
		{"in": "совсем не json", "want": false, "note": "мусор отвергнут"},
		{"in": "{незакрытый", "want": false, "note": "обрыв отвергнут"},
		{"in": "", "want": false, "note": "пустая строка отвергнута"},
	]

	for case_data: Dictionary in cases:
		var parsed: Variant = NoirApiConnector.extract_json_object(str(case_data["in"]))
		var got: bool = parsed is Dictionary
		_check(got == bool(case_data["want"]), "парсер: %s" % str(case_data["note"]))


func _test_schema_rejects_garbage() -> void:
	_section("4. Схема отвергает битые дела")

	var garbage: Dictionary = {
		"killer_id": "НЕ_СУЩЕСТВУЕТ",
		"victim_id": "ТОЖЕ_НЕТ",
		"motive": "",
		"clues": "это должно быть массивом",
	}
	var report: NoirCrimeSchema.Report = NoirCrimeSchema.validate(garbage)
	_check(not report.ok(), "битое дело отклонено (ошибок: %d)" % report.errors.size())

	var not_object: NoirCrimeSchema.Report = NoirCrimeSchema.validate("строка вместо объекта")
	_check(not not_object.ok(), "не-объект отклонён")

	var empty_report: NoirCrimeSchema.Report = NoirCrimeSchema.validate({})
	_check(not empty_report.ok(), "пустой объект отклонён")


func _test_schema_normalizes_aliases() -> void:
	_section("5. Схема понимает синонимы ключей модели")

	var ids: Array[String] = Citizens.all_ids()
	if ids.size() < 2:
		_check(false, "недостаточно жителей для теста")
		return
	var killer: NoirCitizen = Citizens.get_citizen(ids[0])
	var victim: NoirCitizen = Citizens.get_citizen(ids[1])
	var location_id: String = CityAtlas.location_ids()[0]

	# Модель прислала clues_left / alibi_status / crime_scene_coords и
	# сокращённый points_to — схема обязана всё это нормализовать.
	var aliased: Dictionary = {
		"title": "Дело о синонимах",
		"killer_id": killer.id,
		"victim_id": victim.id,
		"motive": "Мотив достаточной длины для прохождения проверки.",
		"motive_category": "MONEY",
		"weapon": {"name": "нож", "type": "KNIFE", "owner_id": killer.id, "disposal": "hidden_nearby"},
		"crime_scene": {"location_id": location_id, "room": "кухня"},
		"crime_scene_coords": [12.0, 0.0, -8.0],
		"time_of_death": "23:15",
		"clues_left": [
			{"clue_id": "C1", "clue_type": "FINGERPRINT", "where": location_id,
				"points_to": {"fingerprint_id": killer.fingerprint_id}, "confidence": 0.9,
				"description": "Отпечаток на ручке"},
		],
		"alibi_status": [
			{"citizen_id": killer.id, "claim": "Был дома", "claimed_location_id": killer.home_location_id,
				"time_window": "22:00-01:00", "status": "unverified"},
		],
		"solution": ["C1"],
	}

	var report: NoirCrimeSchema.Report = NoirCrimeSchema.validate(aliased)
	_check(report.ok(), "дело с синонимами принято (ошибок: %d)" % report.errors.size())
	if not report.ok():
		for err: String in report.errors:
			_say("    · %s" % err)
		return

	_check(report.data.get("clues", []).size() == 1, "clues_left -> clues")
	_check(report.data.get("alibi_data", []).size() == 1, "alibi_status -> alibi_data")
	_check(str(report.data.get("case_title", "")) == "Дело о синонимах", "title -> case_title")
	_check(str(report.data.get("motive_category", "")) == "money", "MONEY -> money (регистр)")
	_check(str((report.data["weapon"] as Dictionary).get("type", "")) == "knife", "KNIFE -> knife")

	var first_clue: Dictionary = (report.data["clues"] as Array)[0]
	var constraint: Dictionary = first_clue["points_to"]
	_check(str(constraint.get("attribute", "")) == "fingerprint_id", "сокращённый points_to развёрнут")

	var chain: PackedStringArray = report.data.get("solution_chain", PackedStringArray())
	_check(chain.size() == 1 and chain[0] == "C1", "solution -> solution_chain")

	var scene: Dictionary = report.data["crime_scene"]
	_check(scene.get("coords", null) is Vector3, "crime_scene_coords -> Vector3")


func _test_offline_case() -> void:
	_section("6. Локальное дело: решаемость")

	GameConfig.set_value("crime", "force_offline_generator", true)
	var case_file: NoirCaseFile = await CrimeDirector.generate_case({"seed": TEST_SEED})
	GameConfig.set_value("crime", "force_offline_generator", false)

	if not _check(case_file != null, "дело сгенерировано"):
		return

	_check(case_file.is_solvable(), "дело помечено решаемым")
	_check(case_file.generation_source == "offline", "источник: %s" % case_file.generation_source)
	_check(case_file.killer_id() != case_file.victim_id(), "убийца и жертва — разные люди")
	_check(Citizens.has(case_file.killer_id()), "killer_id существует в реестре")
	_check(Citizens.has(case_file.victim_id()), "victim_id существует в реестре")
	_check(case_file.clues().size() >= 3, "улик: %d" % case_file.clues().size())

	# Ключевой инвариант: все улики вместе указывают ровно на убийцу.
	var pool: Variant = case_file.data.get("suspect_pool", [])
	var pool_size: int = (pool as Array).size() if pool is Array else 0
	_check(pool_size == 1, "круг подозреваемых сошёлся до %d человека" % pool_size)
	if pool_size == 1:
		_check(str((pool as Array)[0]) == case_file.killer_id(), "и это именно убийца")

	# Ни одна улика не может противоречить убийце.
	var killer: NoirCitizen = Citizens.get_citizen(case_file.killer_id())
	var contradictions: int = 0
	for clue: Dictionary in case_file.clues():
		var constraint: Variant = clue.get("points_to", null)
		if constraint is Dictionary and killer != null and not killer.matches(constraint as Dictionary):
			contradictions += 1
			_say("    · противоречие в улике %s" % str(clue.get("id", "?")))
	_check(contradictions == 0, "ни одна улика не противоречит убийце")

	# Твёрдое доказательство обязано быть.
	var has_hard: bool = false
	for clue: Dictionary in case_file.clues():
		if str(clue.get("type", "")) in NoirSolvabilityValidator.HARD_EVIDENCE_TYPES:
			has_hard = true
	_check(has_hard, "есть твёрдое доказательство (отпечаток или запись камеры)")

	# Алиби убийцы не может быть подтверждённым.
	var killer_alibi: Dictionary = case_file.alibi_for(case_file.killer_id())
	_check(not killer_alibi.is_empty(), "у убийцы есть запись алиби")
	_check(str(killer_alibi.get("status", "")) != "verified",
		"алиби убийцы: %s (не verified)" % str(killer_alibi.get("status", "?")))

	# Ложные следы указывают только на невиновных и опровергаются уликами.
	var clue_ids: Dictionary = {}
	for clue: Dictionary in case_file.clues():
		clue_ids[str(clue["id"])] = true
	var bad_herrings: int = 0
	for herring: Dictionary in case_file.red_herrings():
		if str(herring.get("implicates_id", "")) == case_file.killer_id():
			bad_herrings += 1
		if not clue_ids.has(str(herring.get("refuted_by", ""))):
			bad_herrings += 1
	_check(bad_herrings == 0, "ложные следы корректны (нарушений: %d)" % bad_herrings)

	# Цепочка решения ссылается только на существующие улики.
	var chain_ok: bool = not case_file.solution_chain().is_empty()
	for id: String in case_file.solution_chain():
		if not clue_ids.has(id):
			chain_ok = false
	_check(chain_ok, "цепочка решения корректна: %s" % ", ".join(case_file.solution_chain()))

	_assert_no_spoilers(case_file)

	# Материализация в мире.
	_check(_spawner.spawned_count() > 0, "улик заспавнено в мире: %d" % _spawner.spawned_count())

	_say("")
	for line: String in case_file.debug_summary(true).split("\n"):
		_say("  " + line)

	_dump_case_json(case_file)


func _test_investigation_flow() -> void:
	_section("7. Игровой цикл расследования")

	var case_file: NoirCaseFile = CrimeDirector.current_case()
	if not _check(case_file != null, "есть активное дело"):
		return

	var before: int = case_file.suspects_remaining().size()
	_check(before > 1, "до находок круг широк: %d человек" % before)

	# Улики со requires_scan нельзя найти без сканера.
	var scan_clue_id: String = ""
	for clue: Dictionary in case_file.clues():
		if bool(clue.get("requires_scan", false)):
			scan_clue_id = str(clue["id"])
			break
	if not scan_clue_id.is_empty():
		var node: NoirClueNode = _spawner.clue_node(scan_clue_id)
		if node != null:
			var denied: Dictionary = node.try_discover(false)
			_check(not bool(denied["ok"]) and str(denied["reason"]) == "needs_scanner",
				"улика %s недоступна без сканера" % scan_clue_id)
			var allowed: Dictionary = node.try_discover(true)
			_check(bool(allowed["ok"]), "со сканером улика %s найдена" % scan_clue_id)
			_check(not bool(node.try_discover(true)["ok"]), "повторная находка той же улики отклонена")

	# Обвинение без доказательств должно отклоняться.
	var innocent_id: String = ""
	for id: String in Citizens.all_ids():
		if id != case_file.killer_id() and id != case_file.victim_id():
			innocent_id = id
			break
	if not innocent_id.is_empty():
		var gate: Dictionary = case_file.can_accuse(innocent_id)
		_check(not bool(gate["allowed"]), "обвинение случайного человека отклонено: %s" % str(gate["reason"]))

	# Находим всю цепочку решения — круг обязан сойтись к одному.
	for id: String in case_file.solution_chain():
		var node: NoirClueNode = _spawner.clue_node(id)
		if node != null:
			node.try_discover(true)
		else:
			case_file.discover_clue(id)

	var after: int = case_file.suspects_remaining().size()
	_check(after == 1, "после цепочки круг сузился до %d человека" % after)
	if after == 1:
		_check(case_file.suspects_remaining()[0] == case_file.killer_id(), "остался именно убийца")

	_check(case_file.progress() >= 0.99, "прогресс дела: %.0f%%" % (case_file.progress() * 100.0))

	# Проверка алиби.
	var alibi_status: String = case_file.check_alibi(case_file.killer_id())
	_check(alibi_status != "verified", "проверка алиби убийцы вернула: %s" % alibi_status)

	# Обвинение настоящего убийцы принимается и признаётся верным.
	var verdict: Dictionary = case_file.accuse(case_file.killer_id())
	_check(bool(verdict["accepted"]), "обвинение убийцы принято (сила дела %.2f)" % float(verdict["strength"]))
	_check(bool(verdict["correct"]), "обвинение признано верным")
	_check(case_file.closed, "дело закрыто")

	var second: Dictionary = case_file.accuse(case_file.killer_id())
	_check(not bool(second["accepted"]), "повторное обвинение по закрытому делу отклонено")


func _test_serialization() -> void:
	_section("8. Сохранение и загрузка дела")

	var original: NoirCaseFile = CrimeDirector.current_case()
	if not _check(original != null, "есть дело для сериализации"):
		return

	var saved: Dictionary = original.to_dict()
	var json_text: String = JSON.stringify(saved)
	_check(not json_text.is_empty(), "дело сериализуется в JSON (%d символов)" % json_text.length())

	var reparsed: Variant = JSON.parse_string(json_text)
	if not _check(reparsed is Dictionary, "JSON дела читается обратно"):
		return

	var restored: NoirCaseFile = NoirCaseFile.from_dict(reparsed as Dictionary)
	_check(restored.killer_id() == original.killer_id(), "убийца сохранён")
	_check(restored.victim_id() == original.victim_id(), "жертва сохранена")
	_check(restored.clues().size() == original.clues().size(),
		"улик после загрузки: %d" % restored.clues().size())
	_check(restored.scene_position().distance_to(original.scene_position()) < 0.01,
		"координаты места преступления восстановлены")
	_check(restored.discovered_count() == original.discovered_count(),
		"найденные улики сохранены: %d" % restored.discovered_count())

	var broken: NoirCaseFile = NoirCaseFile.from_dict({"version": 1})
	_check(broken != null and broken.clues().is_empty(), "повреждённое сохранение не роняет игру")


func _test_repair_of_broken_llm_answer() -> void:
	_section("9. Ремонт логически битого ответа модели")

	var ids: Array[String] = Citizens.alive_ids()
	if ids.size() < 3:
		_check(false, "недостаточно живых жителей")
		return

	var killer: NoirCitizen = Citizens.get_citizen(ids[0])
	var victim: NoirCitizen = Citizens.get_citizen(ids[1])
	var location_id: String = CityAtlas.location_ids()[0]

	# Специально ломаем логику: улики указывают НЕ на убийцу, алиби убийцы
	# подтверждено, цепочка пустая, ложный след указывает на самого убийцу.
	var broken: Dictionary = {
		"case_title": "Сломанное дело",
		"killer_id": killer.id,
		"victim_id": victim.id,
		"motive": "Мотив, придуманный небрежно, но достаточно длинный.",
		"motive_category": "revenge",
		"weapon": {"name": "труба", "type": "blunt", "owner_id": "unknown", "disposal": "left_at_scene"},
		"crime_scene": {"location_id": location_id, "room": "подвал", "coords": [0, 0, 0]},
		"time_of_death": "01:20",
		"clues": [
			{"id": "B1", "type": "FOOTPRINT", "location_id": location_id,
				"points_to": {"attribute": "shoe_size", "value": killer.shoe_size + 5},
				"reliability": 0.8,
				# Модель любит вписывать имя убийцы прямо в улику — это спойлер.
				"description": "След обуви. Принадлежит %s." % killer.full_name()},
			{"id": "B2", "type": "WITNESS_STATEMENT", "location_id": location_id,
				"points_to": {"attribute": "hair_color", "value": "невозможный цвет"},
				"reliability": 0.5, "description": "Показание, противоречащее фактам"},
		],
		"alibi_data": [
			{"citizen_id": killer.id, "claim": "Меня видели в другом месте",
				"claimed_location_id": location_id, "time_window": "01:00-02:00", "status": "verified"},
		],
		"red_herrings": [
			{"id": "BR1", "description": "След на самого убийцу", "implicates_id": killer.id, "refuted_by": "НЕТ_ТАКОЙ"},
		],
		"solution_chain": ["НЕ_СУЩЕСТВУЕТ"],
		"narrative": {"opening": "", "police_report": ""},
	}

	var schema_report: NoirCrimeSchema.Report = NoirCrimeSchema.validate(broken)
	# Подтверждённое алиби убийцы — структурная ошибка, схема обязана её увидеть.
	_check(not schema_report.ok(), "схема поймала verified-алиби убийцы")

	# Убираем только это нарушение и проверяем, что остальное ремонтируется.
	(broken["alibi_data"] as Array)[0]["status"] = "unverified"
	var second_report: NoirCrimeSchema.Report = NoirCrimeSchema.validate(broken)
	if not _check(second_report.ok(), "после правки алиби структура принята (ошибок: %d)" % second_report.errors.size()):
		for err: String in second_report.errors:
			_say("    · %s" % err)
		return

	_check(second_report.warnings.size() > 0, "схема отметила %d проблем(ы) как исправимые" % second_report.warnings.size())

	var enforce_report: NoirSolvabilityValidator.Report = NoirSolvabilityValidator.enforce(second_report.data)
	_check(enforce_report.ok(), "валидатор решаемости отремонтировал дело")
	_check(enforce_report.repairs.size() > 0, "внесено правок: %d" % enforce_report.repairs.size())
	_check(enforce_report.candidate_count == 1, "круг после ремонта: %d человек" % enforce_report.candidate_count)
	_check(bool(enforce_report.data.get("solvable", false)), "дело стало решаемым")

	# Улики теперь обязаны совпадать с убийцей.
	var repaired_contradictions: int = 0
	var repaired_clues: Variant = enforce_report.data.get("clues", [])
	if repaired_clues is Array:
		for item: Variant in repaired_clues as Array:
			var constraint: Variant = (item as Dictionary).get("points_to", null)
			if constraint is Dictionary and not killer.matches(constraint as Dictionary):
				repaired_contradictions += 1
	_check(repaired_contradictions == 0, "после ремонта противоречий нет")

	var repaired_herrings: Variant = enforce_report.data.get("red_herrings", [])
	var herring_points_at_killer: bool = false
	if repaired_herrings is Array:
		for item: Variant in repaired_herrings as Array:
			if str((item as Dictionary).get("implicates_id", "")) == killer.id:
				herring_points_at_killer = true
	_check(not herring_points_at_killer, "ложный след больше не указывает на убийцу")

	var narrative: Dictionary = enforce_report.data.get("narrative", {})
	_check(not str(narrative.get("opening", "")).strip_edges().is_empty(), "вступление достроено движком")
	_check(not str(narrative.get("police_report", "")).strip_edges().is_empty(), "протокол достроен движком")

	# Имя убийцы, вписанное моделью в улику, обязано быть вычищено.
	var spoiler_leaks: int = 0
	if repaired_clues is Array:
		for item: Variant in repaired_clues as Array:
			if str((item as Dictionary).get("description", "")).contains(killer.full_name()):
				spoiler_leaks += 1
	_check(spoiler_leaks == 0, "имя убийцы вычищено из описаний улик (утечек: %d)" % spoiler_leaks)

	for repair: String in enforce_report.repairs:
		_say("    · %s" % repair)


func _test_live_llm() -> void:
	_section("10. Живой запрос к LLM")

	if not Api.is_available():
		_say("  [color=#FFA23A]ПРОПУЩЕНО[/color]: токен не задан или API выключен — игра работает на локальном генераторе.")
		return

	_say("  Эндпоинт: %s" % GameConfig.get_string("api", "endpoint"))
	_say("  Модель:   %s" % GameConfig.get_string("api", "model"))

	var case_file: NoirCaseFile = await CrimeDirector.generate_case({
		"seed": TEST_SEED + 7,
		"allow_llm": true,
		"difficulty": "высокая",
	})

	if case_file == null:
		_say("  [color=#FFA23A]Сеть недоступна или модель отказала[/color] — это не провал: конвейер обязан был уйти в оффлайн.")
		_check(CrimeDirector.state() != NoirCrimeDirector.State.FAILED or CrimeDirector.current_case() != null,
			"конвейер не оставил игру без дела")
		return

	_check(case_file.is_solvable(), "дело от LLM решаемо")
	_assert_no_spoilers(case_file)
	_say("  Источник: %s | правок при сборке: %d" % [case_file.generation_source, case_file.repair_notes.size()])
	if case_file.generation_source.begins_with("llm"):
		_say("  [color=#39FF88]Модель ответила и её дело прошло валидацию.[/color]")
		_say("")
		for line: String in case_file.debug_summary(true).split("\n"):
			_say("  " + line)
		_dump_case_json(case_file)
	else:
		_say("  Модель не дала валидного ответа — сработала деградация на локальный генератор (штатное поведение).")

	_say("  Статистика режиссёра: %s" % JSON.stringify(CrimeDirector.stats()))


# -------------------------------------------------------------------- служебное

## Имя убийцы не должно встречаться ни в одном тексте, который видит игрок,
## иначе дедукция бессмысленна.
func _assert_no_spoilers(case_file: NoirCaseFile) -> void:
	var killer: NoirCitizen = Citizens.get_citizen(case_file.killer_id())
	if killer == null:
		_check(false, "убийца найден для проверки спойлеров")
		return
	var killer_name: String = killer.full_name()

	var leaks: PackedStringArray = []
	for clue: Dictionary in case_file.clues():
		if str(clue.get("description", "")).contains(killer_name):
			leaks.append("улика " + str(clue.get("id", "?")))
	for herring: Dictionary in case_file.red_herrings():
		if str(herring.get("description", "")).contains(killer_name):
			leaks.append("ложный след " + str(herring.get("id", "?")))
	var narrative: Dictionary = case_file.narrative()
	for key: String in ["opening", "police_report"]:
		if str(narrative.get(key, "")).contains(killer_name):
			leaks.append(key)

	_check(leaks.is_empty(), "имя убийцы («%s») не утекло в игровые тексты%s" % [
		killer_name,
		"" if leaks.is_empty() else " — утечки: " + ", ".join(leaks),
	])


## Мокрый асфальт под уликами: пол нужен только для наглядности в оконном режиме.
func _build_ground() -> void:
	if _ground == null or not is_instance_valid(_ground):
		return
	var plane := PlaneMesh.new()
	plane.size = Vector2(220.0, 220.0)
	_ground.mesh = plane

	var material := StandardMaterial3D.new()
	material.albedo_color = CityAtlas.palette("base_asphalt")
	material.roughness = 0.12          # блеск от дождя
	material.metallic = 0.35
	material.metallic_specular = 0.7
	_ground.material_override = material
	_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Наводит камеру на место преступления, чтобы улики было видно.
func _on_case_ready_focus(case_file: NoirCaseFile) -> void:
	if _headless or _camera == null or not is_instance_valid(_camera) or case_file == null:
		return
	var target: Vector3 = case_file.scene_position()
	if _ground != null and is_instance_valid(_ground):
		_ground.global_position = Vector3(target.x, target.y - 0.02, target.z)
	_camera.global_position = target + Vector3(0.0, 9.0, 14.0)
	_camera.look_at(target, Vector3.UP)


func _dump_case_json(case_file: NoirCaseFile) -> void:
	var path: String = "user://last_case_%s.json" % case_file.generation_source
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		Log.warn("TestBench", "Не удалось выгрузить дело в файл", {"код": FileAccess.get_open_error()})
		return
	file.store_string(JSON.stringify(case_file.to_dict(), "  "))
	file.close()
	_say("  Дело выгружено: %s" % ProjectSettings.globalize_path(path))


func _section(title: String) -> void:
	_say("")
	_say("[b]%s[/b]" % title)


func _check(condition: bool, description: String) -> bool:
	if condition:
		_passed += 1
		_say("  [color=#39FF88]OK[/color]   %s" % description)
	else:
		_failed += 1
		_say("  [color=#E8253F]FAIL[/color] %s" % description)
	return condition


func _say(line: String) -> void:
	_lines.append(line)
	print(_strip_bbcode(line))
	if _output != null and is_instance_valid(_output):
		_output.append_text(line + "\n")


func _flush() -> void:
	var path := "user://phase1_report.txt"
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	for line: String in _lines:
		file.store_line(_strip_bbcode(line))
	file.close()
	print("Отчёт сохранён: " + ProjectSettings.globalize_path(path))


func _strip_bbcode(text: String) -> String:
	var regex := RegEx.new()
	if regex.compile("\\[/?[a-zA-Z][^\\]]*\\]") != OK:
		return text
	return regex.sub(text, "", true)
