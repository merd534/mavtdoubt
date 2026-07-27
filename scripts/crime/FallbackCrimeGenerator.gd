class_name NoirFallbackCrimeGenerator
extends RefCounted
## Локальный генератор дел. Работает без сети и без токена.
##
## Зачем он есть: игра обязана быть играбельной, даже если API недоступен,
## лимит запросов исчерпан или модель вернула мусор. Генератор выдаёт **сырой
## словарь в той же схеме**, что и LLM, поэтому дальше проходит через
## `NoirCrimeSchema.validate` и `NoirSolvabilityValidator.enforce` — те же
## гарантии, тот же формат, никакой отдельной ветки кода в игре.

const MOTIVE_TEMPLATES: Dictionary = {
	"money": [
		"Долг в %d кредитов рос быстрее, чем %s успевал придумывать отговорки. Разговор на лестнице кончился тем, чем обычно кончаются такие разговоры.",
		"Речь шла о деньгах, которых у одного было слишком много, а у другого — ни одного. Расчёт вышел окончательным.",
	],
	"jealousy": [
		"Их видели вместе слишком часто, чтобы это осталось без внимания. Ревность в этом городе стоит дешевле пули.",
		"Один из них не смог смириться с тем, что выбрали не его.",
	],
	"revenge": [
		"Старая история, о которой все предпочли забыть. Кроме одного человека — он помнил каждую деталь.",
		"Расплата пришла с опозданием на несколько лет, но пришла.",
	],
	"silence_witness": [
		"Жертва видела то, чего видеть не следовало, и слишком громко об этом думала.",
		"Молчание можно купить, а можно обеспечить. Выбрали второе.",
	],
	"blackmail": [
		"Конверт с фотографиями оказался дороже, чем чья-то жизнь.",
		"Вымогательство работает, пока жертва боится. В ту ночь бояться перестали оба.",
	],
	"inheritance": [
		"Наследство делили ещё до похорон. Одна подпись стояла между кем-то и очень крупной суммой.",
		"Родственные связи в этом городе — просто список тех, кто выигрывает от твоей смерти.",
	],
	"territory": [
		"Спор о том, чей это квартал, длился месяцами. Точку поставили ночью.",
		"Границы здесь не рисуют на картах — их обозначают телами.",
	],
	"passion": [
		"Разговор сорвался в крик, крик — в удар. Никто не планировал так далеко заходить.",
		"Вспышка длилась секунд десять. Хватило.",
	],
	"accident_coverup": [
		"Сначала была случайность. Потом — паника. И только потом появился умысел: скрыть первое.",
		"Одна ошибка тянет за собой вторую, а вторая уже требует, чтобы свидетель молчал.",
	],
	"ideology": [
		"Для убийцы это была не личная неприязнь, а принцип. Такие мотивы самые холодные.",
		"Кто-то решил, что жертва — часть проблемы, а не человек.",
	],
}

const REL_TO_MOTIVE: Dictionary = {
	"супруг": "jealousy",
	"любовник": "jealousy",
	"бывший партнёр": "revenge",
	"родственник": "inheritance",
	"коллега": "blackmail",
	"сосед": "passion",
	"соперник": "territory",
	"должник": "money",
	"кредитор": "money",
	"друг": "silence_witness",
}

const WEAPON_BY_TYPE: Dictionary = {
	"knife": ["кухонный нож", "складной нож", "осколок стекла", "заточка"],
	"blunt": ["чугунная лампа", "гаечный ключ", "бутылка", "обрезок трубы"],
	"firearm": ["револьвер .38", "пистолет без номера", "обрез"],
	"poison": ["флакон с сердечным препаратом", "яд в бокале"],
	"strangulation": ["шёлковый шарф", "телефонный шнур", "ремень"],
	"push_from_height": ["перила пожарной лестницы", "открытое окно девятого этажа"],
	"improvised": ["пресс-папье", "печатная машинка", "тяжёлая пепельница"],
}

const ROOMS: PackedStringArray = [
	"кухня", "спальня", "коридор у входа", "лестничная клетка", "подсобка",
	"служебный вход", "мужская уборная", "подсобный коридор", "парковка в подвале",
	"пожарная лестница", "кабинет на втором этаже", "холл",
]


## Генерирует сырое дело. [param seed_value] задаёт воспроизводимость.
static func generate(seed_value: int, options: Dictionary = {}) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	if Citizens.count() < 4:
		Log.error("Fallback", "Слишком мало жителей для генерации дела", {"жителей": Citizens.count()})
		return {}

	# --- жертва: предпочитаем того, у кого есть социальные связи --------------
	var victim: NoirCitizen = _pick_victim(rng)
	if victim == null:
		Log.error("Fallback", "Не удалось выбрать жертву")
		return {}

	# --- убийца: из окружения жертвы (иначе мотив висит в воздухе) ------------
	var killer_result: Dictionary = _pick_killer(victim, rng)
	var killer: NoirCitizen = killer_result.get("citizen", null)
	if killer == null:
		Log.error("Fallback", "Не удалось выбрать убийцу")
		return {}
	var relationship_kind: String = str(killer_result.get("relationship", "сосед"))

	# --- мотив ---------------------------------------------------------------
	var motive_category: String = str(REL_TO_MOTIVE.get(relationship_kind, "passion"))
	if killer.debt > 20000 and rng.randf() < 0.6:
		motive_category = "money"
	elif killer.temper > 0.8 and rng.randf() < 0.5:
		motive_category = "passion"
	elif killer.criminal_record and rng.randf() < 0.35:
		motive_category = "silence_witness"

	var motive_text: String = _motive_text(motive_category, killer, victim, relationship_kind, rng)

	# --- место и время -------------------------------------------------------
	var scene_location_id: String = _pick_scene(victim, killer, rng)
	var scene_position: Vector3 = CityAtlas.location_world_position(scene_location_id)
	var scene_district: String = str(CityAtlas.get_location(scene_location_id).get("district", ""))
	var time_of_death: int = _pick_time(rng)

	# --- орудие --------------------------------------------------------------
	var weapon_type: String = _pick_weapon_type(motive_category, killer, rng)
	var weapon_names: Array = WEAPON_BY_TYPE.get(weapon_type, WEAPON_BY_TYPE["improvised"])
	var weapon_name: String = str(weapon_names[rng.randi_range(0, weapon_names.size() - 1)])
	var disposal: String = _pick_disposal(weapon_type, rng)
	var disposal_location: String = ""
	if disposal == "hidden_nearby":
		disposal_location = scene_location_id
	elif disposal == "taken_home":
		disposal_location = killer.home_location_id
	elif disposal == "thrown_in_river":
		var bridge: Dictionary = CityAtlas.nearest_bridge(Vector2(scene_position.x, scene_position.z))
		disposal_location = str(bridge.get("id", ""))
		if not CityAtlas.has_location(disposal_location):
			disposal_location = ""

	# --- улики ---------------------------------------------------------------
	var clues: Array = _build_clues(killer, victim, scene_location_id, scene_position, weapon_type, weapon_name, time_of_death, options, rng)

	# --- алиби ---------------------------------------------------------------
	var alibis: Array = _build_alibis(killer, victim, time_of_death, rng)

	# --- ложные следы --------------------------------------------------------
	var herrings: Array = _build_red_herrings(killer, victim, clues, scene_location_id, rng)

	# --- цепочка -------------------------------------------------------------
	var chain: Array = []
	for clue: Variant in clues:
		var c: Dictionary = clue as Dictionary
		if float(c.get("reliability", 0.0)) >= 0.85:
			chain.append(str(c["id"]))
	if chain.is_empty() and not clues.is_empty():
		chain.append(str((clues[0] as Dictionary)["id"]))

	var location_name: String = str(CityAtlas.get_location(scene_location_id).get("name", "неизвестное место"))
	var district_name: String = str(CityAtlas.get_district(scene_district).get("ru", "город"))
	var address: String = str(CityAtlas.get_location(scene_location_id).get("address", ""))
	var room: String = ROOMS[rng.randi_range(0, ROOMS.size() - 1)]

	return {
		"case_title": _case_title(victim, weapon_type, district_name, rng),
		"killer_id": killer.id,
		"victim_id": victim.id,
		"motive": motive_text,
		"motive_category": motive_category,
		"weapon": {
			"name": weapon_name,
			"type": weapon_type,
			"owner_id": killer.id if rng.randf() < 0.55 else "unknown",
			"disposal": disposal,
			"disposal_location_id": disposal_location,
		},
		"crime_scene": {
			"location_id": scene_location_id,
			"room": room,
			"coords": [scene_position.x, scene_position.y, scene_position.z],
		},
		"time_of_death": NoirWorldClock.format_minutes(time_of_death),
		"clues": clues,
		"alibi_data": alibis,
		"red_herrings": herrings,
		"solution_chain": chain,
		"narrative": {
			"opening": _opening_text(victim, location_name, district_name, address, time_of_death, weapon_type, rng),
			"police_report": _report_text(victim, location_name, district_name, address, time_of_death, weapon_name, room),
		},
		"generated_offline": true,
	}


# ---------------------------------------------------------------- выбор людей

static func _pick_victim(rng: RandomNumberGenerator) -> NoirCitizen:
	for _attempt: int in range(64):
		var id: String = Citizens.random_id(rng)
		var c: NoirCitizen = Citizens.get_citizen(id)
		if c != null and c.is_alive and not c.relationships.is_empty():
			return c
	# Fallback: любой живой.
	for id: String in Citizens.alive_ids():
		var c: NoirCitizen = Citizens.get_citizen(id)
		if c != null:
			return c
	return null


static func _pick_killer(victim: NoirCitizen, rng: RandomNumberGenerator) -> Dictionary:
	# Взвешиваем связи: агрессивные/жадные/должники вероятнее.
	var best: NoirCitizen = null
	var best_kind: String = "сосед"
	var best_score: float = -1.0

	for r: Dictionary in victim.relationships:
		var other_id: String = str(r.get("other_id", ""))
		var other: NoirCitizen = Citizens.get_citizen(other_id)
		if other == null or not other.is_alive or other.id == victim.id:
			continue
		var score: float = other.temper * 1.4 + other.greed * 0.9 + float(r.get("strength", 0.5)) * 0.6
		if other.debt > 20000:
			score += 0.7
		if other.criminal_record:
			score += 0.5
		score += rng.randf() * 0.8  # шум, чтобы дела не были однотипными
		if score > best_score:
			best_score = score
			best = other
			best_kind = str(r.get("kind", "сосед"))

	if best != null:
		return {"citizen": best, "relationship": best_kind}

	# Нет подходящих связей — берём случайного и заводим связь, чтобы мотив
	# опирался на реальные данные, а не на пустоту.
	for _attempt: int in range(48):
		var id: String = Citizens.random_id(rng)
		var candidate: NoirCitizen = Citizens.get_citizen(id)
		if candidate != null and candidate.is_alive and candidate.id != victim.id:
			var kind: String = "соперник"
			candidate.relationships.append({"other_id": victim.id, "kind": kind, "strength": 0.6})
			victim.relationships.append({"other_id": candidate.id, "kind": kind, "strength": 0.6})
			return {"citizen": candidate, "relationship": kind}

	return {}


static func _pick_scene(victim: NoirCitizen, killer: NoirCitizen, rng: RandomNumberGenerator) -> String:
	var options: Array[String] = []
	for candidate: String in [victim.home_location_id, victim.hangout_location_id, killer.home_location_id, victim.employer_location_id]:
		if not candidate.is_empty() and CityAtlas.has_location(candidate) and not options.has(candidate):
			options.append(candidate)
	if options.is_empty():
		var all_ids: Array[String] = CityAtlas.location_ids()
		if all_ids.is_empty():
			return ""
		return all_ids[rng.randi_range(0, all_ids.size() - 1)]
	# Дом жертвы — самый частый вариант, но не единственный.
	if rng.randf() < 0.55:
		return options[0]
	return options[rng.randi_range(0, options.size() - 1)]


static func _pick_time(rng: RandomNumberGenerator) -> int:
	# Нуар: почти всегда ночь. 21:00–04:00.
	var hour: int = [21, 22, 23, 0, 1, 2, 3][rng.randi_range(0, 6)]
	return hour * 60 + rng.randi_range(0, 59)


static func _pick_weapon_type(motive_category: String, killer: NoirCitizen, rng: RandomNumberGenerator) -> String:
	if motive_category == "poison" or (motive_category == "inheritance" and rng.randf() < 0.45):
		return "poison"
	if motive_category == "passion":
		return "blunt" if rng.randf() < 0.6 else "improvised"
	if motive_category == "territory" and killer.criminal_record:
		return "firearm"
	if motive_category == "silence_witness":
		return "strangulation" if rng.randf() < 0.5 else "firearm"
	var pool: PackedStringArray = ["knife", "blunt", "firearm", "strangulation", "push_from_height", "improvised"]
	return pool[rng.randi_range(0, pool.size() - 1)]


static func _pick_disposal(weapon_type: String, rng: RandomNumberGenerator) -> String:
	if weapon_type == "push_from_height":
		return "left_at_scene"
	var pool: PackedStringArray = ["left_at_scene", "hidden_nearby", "thrown_in_river", "taken_home", "destroyed"]
	return pool[rng.randi_range(0, pool.size() - 1)]


# ------------------------------------------------------------------- улики

static func _build_clues(killer: NoirCitizen, victim: NoirCitizen, scene_id: String, scene_pos: Vector3, weapon_type: String, weapon_name: String, tod: int, options: Dictionary, rng: RandomNumberGenerator) -> Array:
	var wanted: int = clampi(
		int(options.get("clue_count", rng.randi_range(
			clampi(GameConfig.get_int("crime", "min_clues"), 3, 10),
			clampi(GameConfig.get_int("crime", "max_clues"), 4, 12)
		))), 3, 12)

	var pool: Array[Dictionary] = []

	# Отпечаток — твёрдое доказательство, всегда в наборе.
	pool.append({
		"type": "FINGERPRINT",
		"attr": "fingerprint_id", "value": killer.fingerprint_id, "tolerance": 0,
		"reliability": 0.97, "difficulty": 4, "scan": true,
		"text": "Частичный отпечаток на %s. Криминалистическая база выдаёт идентификатор %s." % [_surface(weapon_type), killer.fingerprint_id],
	})
	pool.append({
		"type": "FOOTPRINT",
		"attr": "shoe_size", "value": killer.shoe_size, "tolerance": 0,
		"reliability": 0.82, "difficulty": 2, "scan": false,
		"text": "Мокрый след обуви ведёт к выходу. Размер %d, тип — %s." % [killer.shoe_size, killer.shoe_type],
	})
	pool.append({
		"type": "CAMERA_RECORDING",
		"attr": "height_cm", "value": killer.height_cm, "tolerance": 3,
		"reliability": 0.78, "difficulty": 3, "scan": false,
		"text": "Камера напротив пишет с потерей кадров, но по дверному проёму рост определяется: около %d см." % killer.height_cm,
	})
	pool.append({
		"type": "BLOOD_SPATTER",
		"attr": "blood_type", "value": killer.blood_type, "tolerance": 0,
		"reliability": 0.9, "difficulty": 4, "scan": true,
		"text": "Вторая группа крови на кромке — не жертвы. Группа %s." % killer.blood_type,
	})
	pool.append({
		"type": "FIBER",
		"attr": "hair_color", "value": killer.hair_color, "tolerance": 0,
		"reliability": 0.68, "difficulty": 3, "scan": true,
		"text": "На вороте жертвы — чужой волос, %s." % killer.hair_color,
	})
	pool.append({
		"type": "WEAPON_TRACE",
		"attr": "handedness", "value": killer.handedness, "tolerance": 0,
		"reliability": 0.72, "difficulty": 3, "scan": false,
		"text": "Характер повреждений от «%s» указывает: бил %s." % [weapon_name, killer.handedness],
	})

	if killer.owned_items.size() > 0:
		pool.append({
			"type": "DROPPED_ITEM",
			"attr": "owned_item", "value": killer.owned_items[0], "tolerance": 0,
			"reliability": 0.86, "difficulty": 2, "scan": false,
			"text": "Под радиатором — %s. Явно выпало в спешке." % killer.owned_items[0],
		})

	if killer.vehicle_type != "нет":
		pool.append({
			"type": "TIRE_TRACK",
			"attr": "vehicle_type", "value": killer.vehicle_type, "tolerance": 0,
			"reliability": 0.7, "difficulty": 2, "scan": false,
			"text": "След протектора у чёрного хода: судя по колее, %s." % killer.vehicle_type,
		})
		if not killer.vehicle_plate.is_empty():
			pool.append({
				"type": "CAMERA_RECORDING",
				"attr": "vehicle_plate", "value": killer.vehicle_plate, "tolerance": 0,
				"reliability": 0.94, "difficulty": 4, "scan": false,
				"text": "Камера на выезде с парковки поймала номер: %s." % killer.vehicle_plate,
			})

	if killer.tattoo != "нет":
		pool.append({
			"type": "WITNESS_STATEMENT",
			"attr": "tattoo", "value": killer.tattoo, "tolerance": 0,
			"reliability": 0.65, "difficulty": 2, "scan": false,
			"text": "Ночной сторож запомнил примету: %s." % killer.tattoo,
		})

	pool.append({
		"type": "PHONE_LOG",
		"attr": "job", "value": killer.job, "tolerance": 0,
		"reliability": 0.6, "difficulty": 3, "scan": false,
		"text": "В журнале звонков жертвы за %s — входящий. Абонент представился по работе: %s." % [NoirWorldClock.format_minutes(tod - 40), killer.job],
	})
	pool.append({
		"type": "NOTE",
		"attr": "home_district", "value": killer.home_district, "tolerance": 0,
		"reliability": 0.58, "difficulty": 2, "scan": false,
		"text": "Смятый билет транзита в кармане жертвы. Зона — %s." % str(CityAtlas.get_district(killer.home_district).get("ru", killer.home_district)),
	})

	# Первая улика (отпечаток) всегда включена, остальные тасуем.
	var head: Dictionary = pool[0]
	var tail: Array[Dictionary] = pool.slice(1)
	for i: int in range(tail.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: Dictionary = tail[i]
		tail[i] = tail[j]
		tail[j] = tmp

	var chosen: Array[Dictionary] = [head]
	chosen.append_array(tail.slice(0, maxi(0, wanted - 1)))

	var out: Array = []
	var index: int = 0
	for template: Dictionary in chosen:
		index += 1
		var constraint: Dictionary = {"attribute": str(template["attr"]), "value": template["value"]}
		if int(template.get("tolerance", 0)) > 0:
			constraint["tolerance"] = int(template["tolerance"])

		# Часть улик рассеиваем по городу: не всё лежит у трупа.
		var clue_location: String = scene_id
		var clue_pos: Vector3 = scene_pos + Vector3(rng.randf_range(-4.0, 4.0), 0.0, rng.randf_range(-4.0, 4.0))
		if str(template["type"]) in ["TIRE_TRACK", "CAMERA_RECORDING", "PHONE_LOG"] and rng.randf() < 0.5:
			var nearby: String = CityAtlas.nearest_location(Vector2(scene_pos.x, scene_pos.z), CityAtlas.LocationKind.PARKING_GARAGE)
			if not nearby.is_empty():
				clue_location = nearby
				clue_pos = CityAtlas.location_world_position(nearby)

		out.append({
			"id": "CLUE_%d" % index,
			"type": str(template["type"]),
			"location_id": clue_location,
			"coords": [clue_pos.x, clue_pos.y, clue_pos.z],
			"points_to": constraint,
			"reliability": float(template["reliability"]),
			"description": str(template["text"]),
			"requires_scan": bool(template["scan"]),
			"discovery_difficulty": int(template["difficulty"]),
		})

	return out


static func _surface(weapon_type: String) -> String:
	match weapon_type:
		"knife": return "рукояти"
		"firearm": return "гильзе"
		"poison": return "стекле бокала"
		"strangulation": return "пряжке"
		"blunt": return "основании предмета"
		"push_from_height": return "перилах"
		_: return "полированной поверхности"


# ------------------------------------------------------------------- алиби

static func _build_alibis(killer: NoirCitizen, victim: NoirCitizen, tod: int, rng: RandomNumberGenerator) -> Array:
	var out: Array = []

	out.append({
		"citizen_id": killer.id,
		"claim": "Утверждает, что весь вечер был дома один. Никто не может это подтвердить.",
		"claimed_location_id": killer.home_location_id,
		"time_window": "%s-%s" % [NoirWorldClock.format_minutes(tod - 90), NoirWorldClock.format_minutes(tod + 90)],
		"status": "contradicted" if rng.randf() < 0.5 else "unverified",
		"witness_id": "",
	})

	var added: Dictionary = {killer.id: true, victim.id: true}
	for r: Dictionary in victim.relationships:
		if out.size() >= 5:
			break
		var other_id: String = str(r.get("other_id", ""))
		if added.has(other_id):
			continue
		var other: NoirCitizen = Citizens.get_citizen(other_id)
		if other == null:
			continue
		added[other_id] = true

		var where: String = other.location_at_minute(tod)
		var verified: bool = rng.randf() < 0.7
		var witness_id: String = ""
		if verified:
			for r2: Dictionary in other.relationships:
				var w: String = str(r2.get("other_id", ""))
				if w != killer.id and w != victim.id and Citizens.has(w):
					witness_id = w
					break
			if witness_id.is_empty():
				verified = false

		out.append({
			"citizen_id": other_id,
			"claim": "Говорит, что был в «%s» и ушёл до полуночи." % str(CityAtlas.get_location(where).get("name", "неизвестном месте")),
			"claimed_location_id": where,
			"time_window": "%s-%s" % [NoirWorldClock.format_minutes(tod - 120), NoirWorldClock.format_minutes(tod + 60)],
			"status": "verified" if verified else "unverified",
			"witness_id": witness_id,
		})

	return out


static func _build_red_herrings(killer: NoirCitizen, victim: NoirCitizen, clues: Array, scene_id: String, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	if clues.is_empty():
		return out

	var refuter: String = str((clues[0] as Dictionary)["id"])
	var count: int = rng.randi_range(1, 2)
	var used: Dictionary = {killer.id: true, victim.id: true}

	for r: Dictionary in victim.relationships:
		if out.size() >= count:
			break
		var other_id: String = str(r.get("other_id", ""))
		if used.has(other_id):
			continue
		var other: NoirCitizen = Citizens.get_citizen(other_id)
		if other == null:
			continue
		used[other_id] = true

		out.append({
			"id": "RH_%d" % (out.size() + 1),
			"description": "%s (%s) ссорился с жертвой на прошлой неделе — об этом знает половина квартала. Удобная версия, и неверная." % [other.full_name(), other.job],
			"implicates_id": other_id,
			"refuted_by": refuter,
			"location_id": scene_id,
		})

	return out


# ------------------------------------------------------------------- тексты

static func _motive_text(category: String, killer: NoirCitizen, victim: NoirCitizen, relationship: String, rng: RandomNumberGenerator) -> String:
	var templates: Array = MOTIVE_TEMPLATES.get(category, MOTIVE_TEMPLATES["passion"])
	var base: String = str(templates[rng.randi_range(0, templates.size() - 1)])
	if base.contains("%d") and base.contains("%s"):
		base = base % [maxi(killer.debt, 4200), killer.full_name()]
	elif base.contains("%s"):
		base = base % killer.full_name()

	return "%s Связь с жертвой: %s. %s" % [
		base,
		relationship,
		"Характер вспыльчивый, срыв был вопросом времени." if killer.temper > 0.7 else "Действовал расчётливо и не в первый раз." if killer.criminal_record else "Действовал не по плану — импровизировал на месте.",
	]


static func _case_title(victim: NoirCitizen, weapon_type: String, district_name: String, rng: RandomNumberGenerator) -> String:
	var patterns: PackedStringArray = [
		"Дело о смерти %s",
		"Тихая ночь в %s",
		"Последний вечер %s",
		"Мокрый след в %s",
		"Никто ничего не видел: %s",
	]
	var pattern: String = patterns[rng.randi_range(0, patterns.size() - 1)]
	if pattern.contains("%s"):
		if pattern.contains("в %s") or pattern.contains(": %s"):
			return pattern % district_name
		return pattern % victim.full_name()
	return "Дело №%d" % rng.randi_range(1000, 9999)


static func _opening_text(victim: NoirCitizen, location_name: String, district_name: String, address: String, tod: int, weapon_type: String, rng: RandomNumberGenerator) -> String:
	var weather: PackedStringArray = [
		"Дождь идёт третьи сутки и смывает всё, кроме того, что важно.",
		"Туман с реки поднялся до второго этажа и в нём вязнет даже неон.",
		"Вода стоит в выбоинах, и каждая лужа отражает чужую вывеску.",
	]
	return "%s %s, %s. %s лежит там, где её оставили — %s. Часы на стене показывают %s, и это единственный свидетель, который не будет врать." % [
		weather[rng.randi_range(0, weather.size() - 1)],
		district_name,
		location_name,
		victim.full_name(),
		address if not address.is_empty() else "адрес не установлен",
		NoirWorldClock.format_minutes(tod),
	]


static func _report_text(victim: NoirCitizen, location_name: String, district_name: String, address: String, tod: int, weapon_name: String, room: String) -> String:
	return "РАПОРТ О ПРОИСШЕСТВИИ. Погибший: %s, %d лет, %s. Место обнаружения: %s (%s), %s, %s. Предполагаемое время смерти: %s. Предполагаемое орудие: %s. Признаков взлома входной двери не обнаружено. Опрос жильцов начат." % [
		victim.full_name(), victim.age, victim.job,
		location_name, district_name, address, room,
		NoirWorldClock.format_minutes(tod), weapon_name,
	]
