class_name NoirCitizen
extends RefCounted
## Модель жителя города со полным набором криминалистических признаков.
##
## Ключевая идея Фазы 1: каждая улика ссылается на **реальное поле** этого
## класса. Поэтому «улика указывает на рост 183 см» физически не может
## разойтись с параметрами NPC — проверку делает `SolvabilityValidator`.

## Поля, по которым улика может сузить круг подозреваемых.
## Ключ — имя атрибута в JSON улики, значение — режим сравнения.
const CONSTRAINT_FIELDS: Dictionary = {
	"fingerprint_id": "exact",
	"shoe_size": "exact",
	"shoe_type": "exact",
	"height_cm": "range",
	"blood_type": "exact",
	"hair_color": "exact",
	"eye_color": "exact",
	"handedness": "exact",
	"gender": "exact",
	"job": "exact",
	"home_district": "exact",
	"vehicle_type": "exact",
	"vehicle_plate": "exact",
	"tattoo": "exact",
	"build": "exact",
	"owned_item": "list",
}

var id: String = ""
var first_name: String = ""
var last_name: String = ""
var age: int = 30
var gender: String = "муж"

# --- криминалистика ---
var height_cm: int = 175
var weight_kg: int = 75
var build: String = "средний"
var shoe_size: int = 43
var shoe_type: String = "ботинки"
var blood_type: String = "O+"
var fingerprint_id: String = ""
var hair_color: String = "тёмные"
var eye_color: String = "серые"
var handedness: String = "правша"
var tattoo: String = "нет"

# --- социальное ---
var job: String = "рабочий"
var employer_location_id: String = ""
var home_location_id: String = ""
var home_district: String = "outskirts"
var hangout_location_id: String = ""
var vehicle_type: String = "нет"
var vehicle_plate: String = ""
var owned_items: PackedStringArray = []
var relationships: Array[Dictionary] = []   ## [{other_id, kind, strength}]

# --- психология (мотив генерируется с опорой на это) ---
var temper: float = 0.4        ## склонность к вспышкам
var greed: float = 0.4
var loyalty: float = 0.5
var debt: int = 0              ## долг в кредитах
var criminal_record: bool = false

# --- расписание ---
var work_start_min: int = 9 * 60
var work_end_min: int = 18 * 60
var sleep_start_min: int = 23 * 60

# --- рантайм ---
var is_alive: bool = true
var is_suspect: bool = false


func full_name() -> String:
	return "%s %s" % [first_name, last_name]


## Значение поля по имени атрибута улики. Возвращает null для неизвестного поля.
func attribute(name: String) -> Variant:
	match name:
		"fingerprint_id": return fingerprint_id
		"shoe_size": return shoe_size
		"shoe_type": return shoe_type
		"height_cm": return height_cm
		"blood_type": return blood_type
		"hair_color": return hair_color
		"eye_color": return eye_color
		"handedness": return handedness
		"gender": return gender
		"job": return job
		"home_district": return home_district
		"vehicle_type": return vehicle_type
		"vehicle_plate": return vehicle_plate
		"tattoo": return tattoo
		"build": return build
		"owned_item": return owned_items
		_: return null


## Соответствует ли житель ограничению улики.
## [param constraint] = {"attribute": String, "value": Variant, "tolerance": int}
func matches(constraint: Dictionary) -> bool:
	var attr_name: String = str(constraint.get("attribute", ""))
	if attr_name.is_empty() or not CONSTRAINT_FIELDS.has(attr_name):
		return true  # неизвестный атрибут никого не отсекает — безопасный дефолт

	var mine: Variant = attribute(attr_name)
	if mine == null:
		return true

	var wanted: Variant = constraint.get("value", null)
	if wanted == null:
		return true

	match str(CONSTRAINT_FIELDS[attr_name]):
		"range":
			var tolerance: float = float(constraint.get("tolerance", 3))
			return absf(float(mine) - float(wanted)) <= maxf(0.0, tolerance)
		"list":
			var wanted_text: String = str(wanted).to_lower()
			for item: String in (mine as PackedStringArray):
				if item.to_lower() == wanted_text:
					return true
			return false
		_:
			if mine is int or mine is float:
				return absf(float(mine) - float(wanted)) < 0.001
			return str(mine).to_lower() == str(wanted).to_lower()


func relationship_with(other_id: String) -> Dictionary:
	for r: Dictionary in relationships:
		if str(r.get("other_id", "")) == other_id:
			return r
	return {}


func has_relationship_with(other_id: String) -> bool:
	return not relationship_with(other_id).is_empty()


## Где житель находится в заданную минуту суток (для алиби и опросов).
func location_at_minute(minutes: int) -> String:
	var m: int = ((minutes % 1440) + 1440) % 1440
	if m >= sleep_start_min or m < 7 * 60:
		return home_location_id
	if m >= work_start_min and m < work_end_min:
		return employer_location_id if not employer_location_id.is_empty() else home_location_id
	if m >= 20 * 60 and m < sleep_start_min:
		return hangout_location_id if not hangout_location_id.is_empty() else home_location_id
	return home_location_id


func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": full_name(),
		"age": age,
		"gender": gender,
		"height_cm": height_cm,
		"weight_kg": weight_kg,
		"build": build,
		"shoe_size": shoe_size,
		"shoe_type": shoe_type,
		"blood_type": blood_type,
		"fingerprint_id": fingerprint_id,
		"hair_color": hair_color,
		"eye_color": eye_color,
		"handedness": handedness,
		"tattoo": tattoo,
		"job": job,
		"home_location_id": home_location_id,
		"home_district": home_district,
		"employer_location_id": employer_location_id,
		"hangout_location_id": hangout_location_id,
		"vehicle_type": vehicle_type,
		"vehicle_plate": vehicle_plate,
		"owned_items": Array(owned_items),
		"temper": temper,
		"greed": greed,
		"debt": debt,
		"criminal_record": criminal_record,
		"relationships": relationships.duplicate(true),
	}


## Урезанная карточка для системного промпта LLM: только то, что нужно,
## чтобы построить логичное дело, без раздувания токенов.
func to_llm_card() -> Dictionary:
	var rel_out: Array[Dictionary] = []
	for r: Dictionary in relationships:
		rel_out.append({"with": str(r.get("other_id", "")), "kind": str(r.get("kind", ""))})
	return {
		"id": id,
		"name": full_name(),
		"age": age,
		"gender": gender,
		"job": job,
		"height_cm": height_cm,
		"build": build,
		"shoe_size": shoe_size,
		"shoe_type": shoe_type,
		"blood_type": blood_type,
		"fingerprint_id": fingerprint_id,
		"hair_color": hair_color,
		"handedness": handedness,
		"tattoo": tattoo,
		"home_location_id": home_location_id,
		"home_district": home_district,
		"work_location_id": employer_location_id,
		"hangout_location_id": hangout_location_id,
		"vehicle_type": vehicle_type,
		"owned_items": Array(owned_items),
		"temper": snappedf(temper, 0.01),
		"greed": snappedf(greed, 0.01),
		"debt": debt,
		"criminal_record": criminal_record,
		"relationships": rel_out,
	}
