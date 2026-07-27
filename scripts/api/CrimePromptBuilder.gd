class_name NoirCrimePromptBuilder
extends RefCounted
## Сборка промптов для генерации дела.
##
## Принцип: модель не должна ничего «придумывать из воздуха». Ей выдаётся
## закрытый мир — реальные `citizen_id`, реальные `location_id`, закрытые списки
## типов улик, орудий, мотивов и допустимых атрибутов-ограничений. Любое значение
## вне этих списков будет отвергнуто `CrimeSchema`, поэтому промпт перечисляет
## их явно и требует строгий JSON без пояснений.

const CLUE_TYPES: PackedStringArray = [
	"FINGERPRINT", "FOOTPRINT", "DROPPED_ITEM", "BLOOD_SPATTER", "CAMERA_RECORDING",
	"WITNESS_STATEMENT", "WEAPON_TRACE", "FIBER", "NOTE", "PHONE_LOG", "TIRE_TRACK",
]

const WEAPON_TYPES: PackedStringArray = [
	"knife", "blunt", "firearm", "poison", "strangulation", "push_from_height", "improvised",
]

const MOTIVE_CATEGORIES: PackedStringArray = [
	"money", "jealousy", "revenge", "silence_witness", "blackmail",
	"inheritance", "territory", "passion", "accident_coverup", "ideology",
]

const DISPOSAL_OPTIONS: PackedStringArray = [
	"left_at_scene", "hidden_nearby", "thrown_in_river", "taken_home", "planted_on_innocent", "destroyed",
]

const ALIBI_STATUSES: PackedStringArray = ["verified", "unverified", "contradicted", "none"]


## Системный промпт. Держим его максимально жёстким — это главный предохранитель
## от логически битых дел.
static func system_prompt() -> String:
	var attributes: String = ", ".join(PackedStringArray(NoirCitizen.CONSTRAINT_FIELDS.keys()))
	return """Ты — детерминированный генератор криминальных дел для нуарного детективного симулятора.
Ты возвращаешь ТОЛЬКО один валидный JSON-объект. Без markdown, без ```-обёрток, без пояснений до или после.

ТВОЯ ЗАДАЧА
Составить одно логически безупречное дело об убийстве внутри закрытого мира, который тебе передан
в блоке WORLD. Ты НЕ имеешь права изобретать людей, места или идентификаторы.

ЖЁСТКИЕ ПРАВИЛА (нарушение любого = брак):
1. killer_id и victim_id ОБЯЗАНЫ быть из списка suspects. killer_id != victim_id.
2. Любой location_id ОБЯЗАН быть из списка locations.
3. Каждая улика в clues имеет поле points_to — ограничение вида
   {"attribute": <атрибут>, "value": <значение>}. Значение ОБЯЗАНО буквально совпадать
   с соответствующим полем убийцы из suspects. Нельзя написать shoe_size 44, если у убийцы 41.
4. Допустимые attribute: %s
   Для height_cm можно добавить "tolerance" (целое, 1..5).
5. Улики ОБЯЗАНЫ в совокупности указывать РОВНО на одного человека — на убийцу.
   Если по вашему набору улик под описание подходят двое, добавьте улику с уникальным признаком
   (fingerprint_id, vehicle_plate, tattoo — самые сильные).
6. Минимум одна улика должна быть типа FINGERPRINT или CAMERA_RECORDING (твёрдое доказательство).
7. red_herrings — ложные следы. Каждый ложный след ОБЯЗАН указывать на невиновного и
   ОБЯЗАН быть опровергаемым: поле refuted_by содержит id настоящей улики из clues.
8. У убийцы alibi_status ОБЯЗАН быть "unverified" или "contradicted", НИКОГДА "verified".
9. solution_chain — упорядоченный массив id улик из clues, минимально достаточный,
   чтобы прийти к убийце. Каждый элемент обязан существовать в clues.
10. time_of_death в формате "HH:MM". Все time_window — "HH:MM-HH:MM".
11. Мотив обязан опираться на реальные данные из suspects: relationships, debt, greed, temper,
    criminal_record. Не выдумывай отношений, которых нет в данных.
12. Все текстовые описания — на русском языке. Все ключи JSON и все enum-значения — на английском,
    ровно как в схеме.

СХЕМА ОТВЕТА (все поля обязательны):
{
  "case_title": "короткое название дела по-русски",
  "killer_id": "CIT_xxxx",
  "victim_id": "CIT_xxxx",
  "motive": "2-4 предложения по-русски, со ссылкой на конкретные факты о людях",
  "motive_category": "один из: %s",
  "weapon": {
    "name": "название по-русски",
    "type": "один из: %s",
    "owner_id": "CIT_xxxx или \\"unknown\\"",
    "disposal": "один из: %s",
    "disposal_location_id": "location_id или \\"\\""
  },
  "crime_scene": {
    "location_id": "location_id из списка",
    "room": "описание помещения по-русски",
    "coords": [x, y, z]
  },
  "time_of_death": "HH:MM",
  "clues": [
    {
      "id": "CLUE_1",
      "type": "один из: %s",
      "location_id": "location_id",
      "coords": [x, y, z],
      "points_to": {"attribute": "...", "value": ...},
      "reliability": 0.0-1.0,
      "description": "что именно видит детектив, по-русски",
      "requires_scan": true|false,
      "discovery_difficulty": 1-5
    }
  ],
  "alibi_data": [
    {
      "citizen_id": "CIT_xxxx",
      "claim": "что человек утверждает, по-русски",
      "claimed_location_id": "location_id",
      "time_window": "HH:MM-HH:MM",
      "status": "один из: %s",
      "witness_id": "CIT_xxxx или \\"\\""
    }
  ],
  "red_herrings": [
    {
      "id": "RH_1",
      "description": "ложный след, по-русски",
      "implicates_id": "CIT_xxxx (невиновный)",
      "refuted_by": "CLUE_x",
      "location_id": "location_id"
    }
  ],
  "solution_chain": ["CLUE_1", "CLUE_3"],
  "narrative": {
    "opening": "3-5 предложений атмосферного нуарного вступления по-русски",
    "police_report": "сухой протокольный текст по-русски"
  }
}

Координаты coords: массив из трёх чисел [x, y, z] в метрах. Если не уверен — ставь [0, 0, 0],
движок подставит точные координаты локации сам.""" % [
		attributes,
		", ".join(MOTIVE_CATEGORIES),
		", ".join(WEAPON_TYPES),
		", ".join(DISPOSAL_OPTIONS),
		", ".join(CLUE_TYPES),
		", ".join(ALIBI_STATUSES),
	]


## Бюджет входных токенов. GitHub Models (models.inference.ai.azure.com)
## отвечает 413 «Request body too large for gpt-4.1 model. Max size: 8000 tokens»,
## поэтому payload обязан сжиматься под лимит, а не надеяться на удачу.
const MAX_INPUT_TOKENS := 6200
const MIN_SUSPECTS := 5
const MIN_LOCATIONS := 6
const LOCATION_SHRINK_STEP := 3

## Поля карточки, без которых модель всё ещё строит логичный мотив.
## Удаляются первыми при нехватке бюджета.
const OPTIONAL_CARD_FIELDS: PackedStringArray = [
	"eye_color", "build", "hangout_location_id", "work_location_id", "age",
]

## Оценка числа токенов. Для смеси русского и латиницы ~2.5 символа на токен;
## берём с запасом в сторону завышения, чтобы никогда не влететь в 413.
static func estimate_tokens(text: String) -> int:
	return int(ceil(float(text.length()) / 2.4))


static func estimate_messages_tokens(messages: Array) -> int:
	var total: int = 0
	for message: Variant in messages:
		if message is Dictionary:
			total += estimate_tokens(str((message as Dictionary).get("content", "")))
			total += 4  # накладные на роль
	return total


## Пользовательское сообщение: закрытый мир + требования к текущему делу.
static func build_world_message(suspect_cards: Array[Dictionary], city_digest: Dictionary, options: Dictionary = {}, lean: bool = false) -> String:
	var min_clues: int = int(options.get("min_clues", 6))
	var max_clues: int = int(options.get("max_clues", 9))
	var time_hint: String = str(options.get("time_hint", "ночь"))
	var difficulty: String = str(options.get("difficulty", "средняя"))

	var locations: Array[Dictionary] = []
	var raw_locations: Variant = city_digest.get("landmarks_and_locations", [])
	if raw_locations is Array:
		for row: Variant in raw_locations as Array:
			if row is Dictionary:
				locations.append(row as Dictionary)

	var payload: Dictionary = {
		"suspects": suspect_cards,
		"locations": locations,
		"requirements": {
			"clue_count_min": min_clues,
			"clue_count_max": max_clues,
			"red_herring_count_min": 1,
			"red_herring_count_max": 3,
			"alibi_entries_min": mini(4, suspect_cards.size()),
			"time_of_day_hint": time_hint,
			"difficulty": difficulty,
			"require_hard_evidence": true,
		},
	}
	if not lean:
		payload["districts"] = city_digest.get("districts", [])

	# Компактный JSON без отступов: отступы — это чистая потеря токенов.
	return "WORLD\n" + JSON.stringify(payload) + """

ЗАДАНИЕ
Сгенерируй одно дело по схеме из системного сообщения.
Самопроверка перед ответом:
 - killer_id и victim_id есть в suspects и различны
 - каждый location_id есть в locations
 - каждое points_to.value буквально равно полю убийцы
 - набор clues сужает круг ровно до убийцы
 - есть FINGERPRINT или CAMERA_RECORDING
 - alibi убийцы не "verified"
 - каждый red_herring имеет refuted_by на существующую улику
 - solution_chain состоит только из существующих id улик
Верни только JSON."""


## Собирает сообщения и **гарантированно** укладывает их в бюджет токенов.
## Порядок сжатия: локации -> необязательные поля карточек -> число подозреваемых.
static func build_messages(suspect_cards: Array[Dictionary], city_digest: Dictionary, options: Dictionary = {}) -> Array:
	var budget: int = maxi(2000, int(options.get("max_input_tokens", MAX_INPUT_TOKENS)))
	var system_text: String = system_prompt()

	var suspects: Array[Dictionary] = []
	for card: Dictionary in suspect_cards:
		suspects.append(card.duplicate(true))

	var digest: Dictionary = city_digest.duplicate(true)
	var locations: Array = []
	var raw_locations: Variant = digest.get("landmarks_and_locations", [])
	if raw_locations is Array:
		locations = (raw_locations as Array).duplicate(true)

	var lean: bool = false
	var trimmed_fields: bool = false

	for _attempt: int in range(48):
		digest["landmarks_and_locations"] = locations
		var messages: Array = [
			{"role": "system", "content": system_text},
			{"role": "user", "content": build_world_message(suspects, digest, options, lean)},
		]
		var estimated: int = estimate_messages_tokens(messages)
		if estimated <= budget:
			Log.debug("PromptBuilder", "Промпт собран", {
				"оценка_токенов": estimated, "бюджет": budget,
				"подозреваемых": suspects.size(), "локаций": locations.size(),
				"lean": lean, "урезаны_поля": trimmed_fields,
			})
			return messages

		# --- сжатие, шаг за шагом ---
		if locations.size() > MIN_LOCATIONS:
			locations.resize(maxi(MIN_LOCATIONS, locations.size() - LOCATION_SHRINK_STEP))
			continue
		if not lean:
			lean = true
			continue
		if not trimmed_fields:
			trimmed_fields = true
			suspects = _trim_cards(suspects)
			continue
		if suspects.size() > MIN_SUSPECTS:
			suspects.resize(suspects.size() - 1)
			continue

		# Дальше сжимать нечего — отдаём минимальный вариант.
		Log.warn("PromptBuilder", "Промпт не влез в бюджет даже после сжатия", {
			"оценка_токенов": estimated, "бюджет": budget,
		})
		return messages

	return [
		{"role": "system", "content": system_text},
		{"role": "user", "content": build_world_message(suspects, digest, options, true)},
	]


## Убирает из карточек всё, что не нужно для построения логики дела.
static func _trim_cards(cards: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for card: Dictionary in cards:
		var trimmed: Dictionary = card.duplicate(true)
		for field: String in OPTIONAL_CARD_FIELDS:
			trimmed.erase(field)
		if str(trimmed.get("vehicle_type", "")) == "нет":
			trimmed.erase("vehicle_type")
		if str(trimmed.get("tattoo", "")) == "нет":
			trimmed.erase("tattoo")
		var items: Variant = trimmed.get("owned_items", null)
		if items is Array and (items as Array).size() > 1:
			trimmed["owned_items"] = (items as Array).slice(0, 1)
		var relationships: Variant = trimmed.get("relationships", null)
		if relationships is Array and (relationships as Array).size() > 2:
			trimmed["relationships"] = (relationships as Array).slice(0, 2)
		out.append(trimmed)
	return out


## Промпт-ремонт: отдаём модели её же ответ и список конкретных нарушений.
## Мир повторно НЕ пересылается — он уже был в диалоге, а бюджет жёсткий.
static func build_repair_messages(previous_json: Dictionary, errors: PackedStringArray, suspect_cards: Array[Dictionary], city_digest: Dictionary) -> Array:
	var error_lines: String = ""
	for i: int in range(errors.size()):
		error_lines += "%d) %s\n" % [i + 1, errors[i]]

	# Напоминаем только идентификаторы, а не полные карточки.
	var suspect_ids: PackedStringArray = []
	for card: Dictionary in suspect_cards:
		suspect_ids.append(str(card.get("id", "")))

	var location_ids: PackedStringArray = []
	var raw_locations: Variant = city_digest.get("landmarks_and_locations", [])
	if raw_locations is Array:
		for row: Variant in raw_locations as Array:
			if row is Dictionary:
				location_ids.append(str((row as Dictionary).get("id", "")))

	var system_text: String = system_prompt()
	var previous_text: String = JSON.stringify(previous_json)
	var messages: Array = []

	# Сжимаем напоминание, пока не влезет в бюджет.
	for _attempt: int in range(24):
		var request: String = """Твой предыдущий ответ отклонён валидатором. Ошибки:
%s
Допустимые citizen_id: %s
Допустимые location_id: %s

Отклонённый JSON:
%s

Исправь ТОЛЬКО перечисленные нарушения, сохранив сюжет и мотив.
Верни полный исправленный JSON-объект по той же схеме. Только JSON, без пояснений.""" % [
			error_lines,
			", ".join(suspect_ids),
			", ".join(location_ids),
			previous_text,
		]

		messages = [
			{"role": "system", "content": system_text},
			{"role": "user", "content": request},
		]
		if estimate_messages_tokens(messages) <= MAX_INPUT_TOKENS:
			return messages

		if location_ids.size() > MIN_LOCATIONS:
			location_ids.resize(maxi(MIN_LOCATIONS, location_ids.size() - LOCATION_SHRINK_STEP))
			continue
		if suspect_ids.size() > MIN_SUSPECTS:
			suspect_ids.resize(suspect_ids.size() - 1)
			continue
		break

	Log.warn("PromptBuilder", "Ремонтный промпт остался велик — отправляю как есть", {
		"оценка_токенов": estimate_messages_tokens(messages),
	})
	return messages
