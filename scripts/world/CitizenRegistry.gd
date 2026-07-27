class_name NoirCitizenRegistry
extends Node
## Реестр жителей. Автозагрузка: `Citizens`.
##
## Генерация детерминирована по сиду: одинаковый сид -> одинаковый город и
## одинаковые люди. Это позволяет воспроизводить любое дело по номеру сида.
##
## Реестр же выполняет роль «решателя»: [method candidates_matching] сужает круг
## подозреваемых по набору улик, а [method unique_discriminator] находит признак,
## которым можно отделить конкретного человека от остальных. На этих двух
## функциях держится гарантия отсутствия логических тупиков.

const MALE_FIRST: PackedStringArray = [
	"Arthur", "Bernard", "Caleb", "Desmond", "Elias", "Frank", "Gideon", "Harlan",
	"Ivan", "Julius", "Karl", "Lionel", "Marcus", "Nathan", "Oscar", "Porter",
	"Quentin", "Roland", "Silas", "Theodore", "Ulric", "Victor", "Walter", "Xavier",
]
const FEMALE_FIRST: PackedStringArray = [
	"Adele", "Beatrix", "Clara", "Delia", "Edith", "Freya", "Greta", "Helena",
	"Irina", "Josephine", "Katya", "Lorena", "Mirabel", "Nadia", "Ottilie", "Petra",
	"Quilla", "Rosalind", "Sabine", "Thea", "Ursula", "Verity", "Wilhelmina", "Yvonne",
]
const SURNAMES: PackedStringArray = [
	"Ashcroft", "Blackwood", "Corrigan", "Dunmore", "Everhart", "Farrow", "Grimsby",
	"Hallow", "Iversen", "Jorgen", "Kalinin", "Lowell", "Marchetti", "Nordstrom",
	"Oleander", "Pryce", "Quintrell", "Rathbone", "Sandoval", "Thackeray", "Umbridge",
	"Volkov", "Whitlock", "Yarrowby", "Zabel", "Crane", "Vance", "Mercer",
]

const JOBS_BY_PROFILE: Dictionary = {
	"core": ["клерк", "бармен", "охранник", "журналист", "администратор отеля", "таксист", "курьер"],
	"financial": ["брокер", "юрист", "бухгалтер", "аудитор", "банковский клерк", "аналитик"],
	"industrial": ["сварщик", "крановщик", "механик", "сторож", "водитель погрузчика", "мастер цеха"],
	"commercial": ["продавец", "владелец лавки", "грузчик", "кассир", "торговый агент"],
	"residential": ["учитель", "медсестра", "домохозяйка", "электрик", "почтальон", "сантехник"],
	"slum": ["безработный", "скупщик", "уличный торговец", "курьер", "букмекер", "мусорщик"],
	"entertainment": ["диджей", "танцовщица", "швейцар", "музыкант", "бармен", "промоутер"],
	"waterfront": ["рыбак", "докер", "матрос", "смотритель склада", "мойщик"],
	"oldtown": ["антиквар", "пекарь", "часовщик", "смотритель церкви", "портной"],
	"harbor": ["докер", "стропальщик", "капитан баржи", "таможенник", "контрабандист"],
	"outskirts": ["дальнобойщик", "фермер", "сторож", "механик"],
}

const SHOE_TYPES: PackedStringArray = ["ботинки", "кроссовки", "туфли", "сапоги", "кеды", "рабочие боты"]
const BLOOD_TYPES: PackedStringArray = ["O+", "O-", "A+", "A-", "B+", "B-", "AB+", "AB-"]
const BLOOD_WEIGHTS: PackedInt32Array = [34, 7, 28, 6, 15, 3, 5, 2]
const HAIR_COLORS: PackedStringArray = ["тёмные", "чёрные", "русые", "светлые", "рыжие", "седые", "крашеные"]
const EYE_COLORS: PackedStringArray = ["серые", "карие", "голубые", "зелёные", "чёрные"]
const BUILDS: PackedStringArray = ["худой", "средний", "плотный", "крупный", "жилистый"]
const TATTOOS: PackedStringArray = ["нет", "нет", "нет", "якорь на кисти", "змея на шее", "цифры на предплечье", "роза на плече", "звезда за ухом"]
const VEHICLES: PackedStringArray = ["нет", "нет", "седан", "пикап", "мотоцикл", "фургон", "такси"]
const ITEMS: PackedStringArray = [
	"зажигалка с гравировкой", "серебряные запонки", "складной нож", "кожаные перчатки",
	"карманные часы", "связка отмычек", "зонт-трость", "пачка сигарет «Halo»",
	"диктофон", "фляжка", "медальон", "квитанция из ломбарда", "ключ-карта",
	"шарф в клетку", "оправа очков", "билет на паром",
]
const REL_KINDS: PackedStringArray = ["супруг", "родственник", "коллега", "сосед", "соперник", "должник", "кредитор", "любовник", "бывший партнёр", "друг"]

signal registry_built(count: int)

var _citizens: Dictionary = {}          # id -> NoirCitizen
var _ids: Array[String] = []
var _by_fingerprint: Dictionary = {}
var _built: bool = false
var _seed: int = 0


func _ready() -> void:
	# CityAtlas уже поднят (порядок автозагрузок), но подстрахуемся.
	if not CityAtlas.is_built():
		CityAtlas.build()
	var seed_value: int = GameConfig.get_int("crime", "seed")
	if seed_value == 0:
		seed_value = CityAtlas.city_seed
	build(GameConfig.get_int("crime", "citizen_count"), seed_value)


func build(count: int, seed_value: int) -> void:
	var target: int = clampi(count, 24, 4000)
	_seed = seed_value
	_citizens.clear()
	_ids.clear()
	_by_fingerprint.clear()
	_built = false

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x5EED_1234

	var location_pool: Array[String] = CityAtlas.location_ids()
	if location_pool.is_empty():
		Log.error("Citizens", "Атлас не дал ни одной локации — реестр не построен")
		return

	var homes: Array[String] = CityAtlas.locations_of_kind(CityAtlas.LocationKind.APARTMENTS)
	if homes.is_empty():
		homes = location_pool
	var hangouts: Array[String] = CityAtlas.locations_of_kind(CityAtlas.LocationKind.BAR_CLUB)
	hangouts.append_array(CityAtlas.locations_of_kind(CityAtlas.LocationKind.RESTAURANT))
	if hangouts.is_empty():
		hangouts = location_pool

	for index: int in range(target):
		var citizen: NoirCitizen = _make_citizen(index, rng, homes, hangouts, location_pool)
		_citizens[citizen.id] = citizen
		_ids.append(citizen.id)
		_by_fingerprint[citizen.fingerprint_id] = citizen.id

	_wire_relationships(rng)

	_built = true
	registry_built.emit(_ids.size())
	Log.info("Citizens", "Реестр жителей построен", {"seed": seed_value, "жителей": _ids.size()})


func is_built() -> bool:
	return _built


# ---------------------------------------------------------------- генерация

func _make_citizen(index: int, rng: RandomNumberGenerator, homes: Array[String], hangouts: Array[String], all_locations: Array[String]) -> NoirCitizen:
	var c := NoirCitizen.new()
	c.id = "CIT_%04d" % index

	var is_female: bool = rng.randf() < 0.5
	c.gender = "жен" if is_female else "муж"
	c.first_name = FEMALE_FIRST[rng.randi_range(0, FEMALE_FIRST.size() - 1)] if is_female else MALE_FIRST[rng.randi_range(0, MALE_FIRST.size() - 1)]
	c.last_name = SURNAMES[rng.randi_range(0, SURNAMES.size() - 1)]
	c.age = rng.randi_range(19, 74)

	# Рост/размер обуви скоррелированы — иначе улики выглядят абсурдно.
	var base_height: int = rng.randi_range(155, 176) if is_female else rng.randi_range(166, 197)
	c.height_cm = base_height
	c.shoe_size = clampi(int(round(float(base_height) * 0.235)) + rng.randi_range(-1, 1), 35, 48)
	c.shoe_type = SHOE_TYPES[rng.randi_range(0, SHOE_TYPES.size() - 1)]
	c.build = BUILDS[rng.randi_range(0, BUILDS.size() - 1)]
	c.weight_kg = clampi(int(float(base_height) * 0.42) + rng.randi_range(-9, 22), 44, 140)

	c.blood_type = BLOOD_TYPES[_weighted_index(BLOOD_WEIGHTS, rng)]
	c.fingerprint_id = "FP-%04X-%02X" % [(_seed + index * 2654435761) & 0xFFFF, index & 0xFF]
	c.hair_color = HAIR_COLORS[rng.randi_range(0, HAIR_COLORS.size() - 1)]
	c.eye_color = EYE_COLORS[rng.randi_range(0, EYE_COLORS.size() - 1)]
	c.handedness = "левша" if rng.randf() < 0.11 else "правша"
	c.tattoo = TATTOOS[rng.randi_range(0, TATTOOS.size() - 1)]

	c.home_location_id = homes[rng.randi_range(0, homes.size() - 1)]
	var home_loc: Dictionary = CityAtlas.get_location(c.home_location_id)
	c.home_district = str(home_loc.get("district", "outskirts"))

	var district: Dictionary = CityAtlas.get_district(c.home_district)
	var profile: String = str(district.get("profile", "outskirts"))
	var jobs: Array = JOBS_BY_PROFILE.get(profile, JOBS_BY_PROFILE["outskirts"])
	c.job = str(jobs[rng.randi_range(0, jobs.size() - 1)])

	c.employer_location_id = all_locations[rng.randi_range(0, all_locations.size() - 1)]
	c.hangout_location_id = hangouts[rng.randi_range(0, hangouts.size() - 1)]

	c.vehicle_type = VEHICLES[rng.randi_range(0, VEHICLES.size() - 1)]
	if c.vehicle_type != "нет":
		c.vehicle_plate = "%s%s-%03d" % [
			char(65 + rng.randi_range(0, 25)),
			char(65 + rng.randi_range(0, 25)),
			rng.randi_range(100, 999),
		]

	var item_count: int = rng.randi_range(1, 3)
	var picked: Dictionary = {}
	for _i: int in range(item_count):
		var item: String = ITEMS[rng.randi_range(0, ITEMS.size() - 1)]
		if not picked.has(item):
			picked[item] = true
			c.owned_items.append(item)

	var wealth: float = float(district.get("wealth", 0.4))
	var crime: float = float(district.get("crime", 0.4))
	c.temper = clampf(rng.randf() * 0.6 + crime * 0.4, 0.0, 1.0)
	c.greed = clampf(rng.randf() * 0.7 + (1.0 - wealth) * 0.3, 0.0, 1.0)
	c.loyalty = clampf(rng.randf(), 0.0, 1.0)
	c.debt = 0 if rng.randf() > (0.25 + crime * 0.4) else rng.randi_range(500, 90000)
	c.criminal_record = rng.randf() < (0.06 + crime * 0.28)

	var shift: int = rng.randi_range(0, 2)
	match shift:
		0:
			c.work_start_min = 8 * 60
			c.work_end_min = 17 * 60
			c.sleep_start_min = 23 * 60
		1:
			c.work_start_min = 14 * 60
			c.work_end_min = 23 * 60
			c.sleep_start_min = 2 * 60
		_:
			c.work_start_min = 21 * 60
			c.work_end_min = 6 * 60
			c.sleep_start_min = 8 * 60

	return c


func _wire_relationships(rng: RandomNumberGenerator) -> void:
	if _ids.size() < 2:
		return
	for id: String in _ids:
		var c: NoirCitizen = _citizens[id]
		var links: int = rng.randi_range(1, 4)
		for _i: int in range(links):
			var other_id: String = _ids[rng.randi_range(0, _ids.size() - 1)]
			if other_id == id or c.has_relationship_with(other_id):
				continue
			var kind: String = REL_KINDS[rng.randi_range(0, REL_KINDS.size() - 1)]
			var strength: float = snappedf(rng.randf(), 0.01)
			c.relationships.append({"other_id": other_id, "kind": kind, "strength": strength})
			# Симметричная связь — иначе опросы NPC дают противоречия.
			var other: NoirCitizen = _citizens[other_id]
			if not other.has_relationship_with(id):
				other.relationships.append({"other_id": id, "kind": kind, "strength": strength})


func _weighted_index(weights: PackedInt32Array, rng: RandomNumberGenerator) -> int:
	var total: int = 0
	for w: int in weights:
		total += w
	if total <= 0:
		return 0
	var roll: int = rng.randi_range(1, total)
	for i: int in range(weights.size()):
		roll -= weights[i]
		if roll <= 0:
			return i
	return weights.size() - 1


# ---------------------------------------------------------------- доступ

func count() -> int:
	return _ids.size()


func all_ids() -> Array[String]:
	return _ids.duplicate()


func has(id: String) -> bool:
	return _citizens.has(id)


func get_citizen(id: String) -> NoirCitizen:
	var c: Variant = _citizens.get(id, null)
	return c as NoirCitizen if c is NoirCitizen else null


func random_id(rng: RandomNumberGenerator) -> String:
	if _ids.is_empty():
		return ""
	return _ids[rng.randi_range(0, _ids.size() - 1)]


func alive_ids() -> Array[String]:
	var out: Array[String] = []
	for id: String in _ids:
		var c: NoirCitizen = _citizens[id]
		if c.is_alive:
			out.append(id)
	return out


func id_by_fingerprint(fingerprint: String) -> String:
	return str(_by_fingerprint.get(fingerprint, ""))


# ----------------------------------------------------- решатель / фильтрация

## Кто из жителей удовлетворяет одному ограничению улики.
func filter_by_constraint(constraint: Dictionary, pool: Array[String] = []) -> Array[String]:
	var source: Array[String] = pool if not pool.is_empty() else _ids
	var out: Array[String] = []
	for id: String in source:
		var c: NoirCitizen = get_citizen(id)
		if c != null and c.matches(constraint):
			out.append(id)
	return out


## Пересечение по набору ограничений. Это и есть «круг подозреваемых».
func candidates_matching(constraints: Array, pool: Array[String] = []) -> Array[String]:
	var current: Array[String] = pool if not pool.is_empty() else _ids.duplicate()
	for raw: Variant in constraints:
		if not (raw is Dictionary):
			continue
		var constraint: Dictionary = raw as Dictionary
		if str(constraint.get("attribute", "")).is_empty():
			continue
		current = filter_by_constraint(constraint, current)
		if current.is_empty():
			break
	return current


## Ищет признак, по которому [param target_id] уникален внутри [param pool].
## Возвращает готовое ограничение для новой улики или пустой словарь.
## Именно это спасает дело от «двух равновозможных убийц».
func unique_discriminator(target_id: String, pool: Array[String]) -> Dictionary:
	var target: NoirCitizen = get_citizen(target_id)
	if target == null:
		return {}

	# Порядок перебора — от самых «сильных» признаков к слабым.
	var order: PackedStringArray = [
		"fingerprint_id", "vehicle_plate", "tattoo", "shoe_size", "blood_type",
		"height_cm", "hair_color", "handedness", "eye_color", "shoe_type",
		"vehicle_type", "job", "home_district", "gender", "build",
	]

	for attr_name: String in order:
		var value: Variant = target.attribute(attr_name)
		if value == null:
			continue
		if attr_name == "tattoo" and str(value) == "нет":
			continue
		if attr_name == "vehicle_plate" and str(value).is_empty():
			continue
		if attr_name == "vehicle_type" and str(value) == "нет":
			continue

		var constraint: Dictionary = {"attribute": attr_name, "value": value}
		if attr_name == "height_cm":
			constraint["tolerance"] = 2
		var survivors: Array[String] = filter_by_constraint(constraint, pool)
		if survivors.size() == 1 and survivors[0] == target_id:
			return constraint

	# Ни один одиночный признак не уникален — комбинируем два.
	for first_attr: String in order:
		var first_value: Variant = target.attribute(first_attr)
		if first_value == null:
			continue
		var first_constraint: Dictionary = {"attribute": first_attr, "value": first_value}
		if first_attr == "height_cm":
			first_constraint["tolerance"] = 2
		var stage: Array[String] = filter_by_constraint(first_constraint, pool)
		if stage.size() <= 1:
			continue
		for second_attr: String in order:
			if second_attr == first_attr:
				continue
			var second_value: Variant = target.attribute(second_attr)
			if second_value == null:
				continue
			var second_constraint: Dictionary = {"attribute": second_attr, "value": second_value}
			if second_attr == "height_cm":
				second_constraint["tolerance"] = 2
			var survivors2: Array[String] = filter_by_constraint(second_constraint, stage)
			if survivors2.size() == 1 and survivors2[0] == target_id:
				return second_constraint

	Log.warn("Citizens", "Не найден уникальный признак — отпечаток будет использован как крайняя мера", {"цель": target_id, "пул": pool.size()})
	return {"attribute": "fingerprint_id", "value": target.fingerprint_id}


## Пул кандидатов для LLM: жертва, потенциальные убийцы и их окружение.
## Обязательно включает людей, связанных отношениями — чтобы мотив был логичен.
func build_llm_pool(rng: RandomNumberGenerator, size: int = 14) -> Array[String]:
	var target_size: int = clampi(size, 4, 40)
	if _ids.size() <= target_size:
		return _ids.duplicate()

	var pool: Array[String] = []
	var seed_id: String = random_id(rng)
	if seed_id.is_empty():
		return pool
	pool.append(seed_id)

	# Сначала берём социальное окружение — это даёт мотивы.
	var frontier: Array[String] = [seed_id]
	var guard: int = 0
	while pool.size() < target_size and not frontier.is_empty() and guard < 400:
		guard += 1
		var current_id: String = frontier.pop_front()
		var current: NoirCitizen = get_citizen(current_id)
		if current == null:
			continue
		for r: Dictionary in current.relationships:
			if pool.size() >= target_size:
				break
			var other_id: String = str(r.get("other_id", ""))
			if other_id.is_empty() or pool.has(other_id):
				continue
			pool.append(other_id)
			frontier.append(other_id)

	# Добираем случайными, если связей не хватило.
	guard = 0
	while pool.size() < target_size and guard < 800:
		guard += 1
		var extra: String = random_id(rng)
		if not extra.is_empty() and not pool.has(extra):
			pool.append(extra)

	return pool


func cards_for(ids: Array[String]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: String in ids:
		var c: NoirCitizen = get_citizen(id)
		if c != null:
			out.append(c.to_llm_card())
	return out
