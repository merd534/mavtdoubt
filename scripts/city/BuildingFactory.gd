class_name NoirBuildingFactory
extends RefCounted
## Генерация содержимого одного чанка: здания, вывески, реквизит, фонари, дороги.
##
## Класс возвращает **только данные** — ни одного узла сцены. Благодаря этому
## содержимое чанка проверяется в headless-прогоне и может считаться в потоке.
## Превращением данных в MultiMesh занимается `CityChunk`.
##
## Порядок работы важен и устроен так:
##   1. резерв под landmark'и атласа, включая соседние чанки;
##   2. **сначала дороги** всех районов чанка, включая зоны-заполнители;
##   3. и только потом застройка, которая обязана обходить дорожные коридоры.
##
## Три правила, без которых город расползается:
##   • коридор резервируется под КАЖДУЮ улицу сетки, а не только под
##     магистраль — иначе кварталы соседнего района садятся прямо на асфальт;
##   • участок обрезается по границе своей зоны — иначе кварталы разных
##     районов и синтетических заполнителей врастают друг в друга;
##   • занятые пятна резервируются с зазором и проверяются уже ПОСЛЕ обрезки.
##
## Входы (`entrances`) выдаются НЕ только локациям атласа, но и каждому
## рядовому дому ближнего чанка. Вход — это не только точка: дом получает
## крыльцо с козырьком и лампой, а его коллизия в `CityChunk` собирается
## оболочкой с проёмом, так что внутрь можно банально войти пешком.
##
## Детерминизм: всё зависит только от (city_seed, координаты чанка).
## Бесшовность: квартал обрабатывает тот чанк, в который попал его центр.

const ARTERIAL_EVERY := 4        ## каждая N-я линия сетки — магистраль
const ALLEY_WIDTH := 2.2
const LOT_INSET := 1.0
const MIN_LOT := 5.0
const OCCLUDER_MIN_HEIGHT := 18.0
const LAMP_SPACING := 26.0
const FLOOR_HEIGHT := 3.4
const PODIUM_MIN_HEIGHT := 26.0   ## от какого дома имеет смысл стилобат
const PODIUM_CHANCE := 0.62
const ROAD_OVERRUN := 26.0        ## насколько магистраль выходит за границу района
const CORRIDOR_MARGIN := 1.4      ## зазор между кромкой асфальта и стеной
## Меньше этого дом не получает подъезда: внутри не помещается ни коридор,
## ни лестница — это трансформаторная будка, а не здание.
const ENTERABLE_MIN_SIDE := 7.5
## Габариты входного проёма. Те же значения читает `CityChunk`, когда
## собирает коллизию-оболочку: дыра в физике обязана совпасть с крыльцом.
const DOOR_WIDTH := 2.6
const DOOR_HEIGHT := 3.0
const PORCH_DEPTH := 1.5
## Зазор вокруг занятого пятна. Без него два дома стоят вплотную и на экране
## выглядят одним слипшимся объёмом.
const PLOT_CLEARANCE := 0.5

## Габариты landmark'ов по типу локации (метры).
const LANDMARK_FOOTPRINT: Dictionary = {
	NoirCityAtlas.LocationKind.HOTEL: Vector2(30.0, 24.0),
	NoirCityAtlas.LocationKind.GOVERNMENT: Vector2(34.0, 28.0),
	NoirCityAtlas.LocationKind.APARTMENTS: Vector2(24.0, 20.0),
	NoirCityAtlas.LocationKind.WAREHOUSE: Vector2(46.0, 32.0),
	NoirCityAtlas.LocationKind.DOCK: Vector2(52.0, 30.0),
	NoirCityAtlas.LocationKind.CHURCH: Vector2(20.0, 34.0),
	NoirCityAtlas.LocationKind.MARKET: Vector2(42.0, 28.0),
	NoirCityAtlas.LocationKind.TRANSIT_STATION: Vector2(32.0, 26.0),
	NoirCityAtlas.LocationKind.PARKING_GARAGE: Vector2(36.0, 30.0),
	NoirCityAtlas.LocationKind.HOSPITAL: Vector2(40.0, 30.0),
	NoirCityAtlas.LocationKind.POLICE_STATION: Vector2(28.0, 24.0),
	NoirCityAtlas.LocationKind.SCHOOL: Vector2(38.0, 26.0),
	NoirCityAtlas.LocationKind.BAR_CLUB: Vector2(22.0, 18.0),
	NoirCityAtlas.LocationKind.RESTAURANT: Vector2(18.0, 16.0),
	NoirCityAtlas.LocationKind.SHOP: Vector2(16.0, 14.0),
	NoirCityAtlas.LocationKind.ENTERTAINMENT: Vector2(30.0, 24.0),
}

## Типы, которые зданием не являются — на их месте открытая площадка.
const OPEN_AIR_KINDS: PackedInt32Array = [
	NoirCityAtlas.LocationKind.PARK,
	NoirCityAtlas.LocationKind.BRIDGE,
	NoirCityAtlas.LocationKind.PARKING_STREET,
	NoirCityAtlas.LocationKind.POINT_OF_INTEREST,
	NoirCityAtlas.LocationKind.DANGER_ZONE,
]


## Главная точка входа. [param chunk_rect] — прямоугольник чанка в плане.
static func generate(chunk_rect: Rect2, city_seed: int, detail_level: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = _chunk_seed(city_seed, chunk_rect)

	var result: Dictionary = {
		"buildings": [] as Array[Dictionary],
		"signs": [] as Array[Dictionary],
		"props": [] as Array[Dictionary],
		"lamps": [] as Array[Dictionary],
		"roads": [] as Array[Dictionary],
		"entrances": [] as Array[Dictionary],
		"occluders": [] as Array[Dictionary],
	}

	# Landmark'и ставим первыми: обычная застройка обязана их обойти.
	var reserved: Array[Rect2] = []
	_place_atlas_locations(chunk_rect, result, reserved, rng, detail_level)
	# Сюжетные здания соседних чанков тоже занимают место. Без этого дом
	# у границы чанка врастал в отель, стоящий в двадцати метрах за ней.
	_reserve_neighbor_landmarks(chunk_rect, reserved)

	# Полный список зон чанка: реальные районы + синтетические заполнители
	# пустырей между ними.
	var zones: Array[Dictionary] = []
	for district_id: String in _districts_touching(chunk_rect):
		var district: Dictionary = CityAtlas.get_district(district_id)
		if not district.is_empty():
			zones.append(district)
	zones.append_array(_gap_zones(chunk_rect, city_seed))

	# Фаза дорог: собираем полотно и запоминаем коридоры, куда застройке нельзя.
	var corridors: Array[Rect2] = []
	for zone: Dictionary in zones:
		_generate_roads(chunk_rect, zone, result, rng, corridors)

	# Фаза застройки: теперь каждый участок знает про все улицы чанка,
	# в том числе про улицы соседнего района.
	for zone: Dictionary in zones:
		_generate_district_blocks(chunk_rect, zone, result, reserved, corridors, rng, detail_level)

	_collect_occluders(result)
	return result


## Зоны, которые не покрыты ни одним реальным районом. Без них в середине
## карты остаются голые поля между кварталами.
static func _gap_zones(chunk_rect: Rect2, city_seed: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var covered: Array[Rect2] = []
	for id: String in CityAtlas.district_ids():
		if id == "outskirts":
			continue
		var district: Dictionary = CityAtlas.get_district(id)
		if district.is_empty():
			continue
		covered.append(district["bounds"] as Rect2)

	for gap: Rect2 in NoirDistrictInfill.gaps(chunk_rect, covered):
		var synth: Dictionary = NoirDistrictInfill.district_for(gap, city_seed)
		if not synth.is_empty():
			out.append(synth)
	return out


## Сид чанка. Биты перемешиваются, ноль правится явно.
static func _chunk_seed(city_seed: int, chunk_rect: Rect2) -> int:
	var cx: int = int(round(chunk_rect.position.x))
	var cz: int = int(round(chunk_rect.position.y))
	var h: int = city_seed * 374761393 + cx * 668265263 + cz * 1442695040888963407
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	h = absi(h)
	return h if h != 0 else 0x9E3779B9


static func _districts_touching(rect: Rect2) -> Array[String]:
	var out: Array[String] = []
	for id: String in CityAtlas.district_ids():
		var district: Dictionary = CityAtlas.get_district(id)
		if district.is_empty():
			continue
		var bounds: Rect2 = district["bounds"]
		if id == "outskirts":
			continue  # окраины — фолбэк для запросов, застраивать весь мир ими нельзя
		if bounds.intersects(rect):
			out.append(id)
	return out


# ------------------------------------------------------------- квартальная сетка

static func _generate_district_blocks(chunk_rect: Rect2, district: Dictionary, result: Dictionary, reserved: Array[Rect2], corridors: Array[Rect2], rng: RandomNumberGenerator, detail_level: int) -> void:
	var bounds: Rect2 = district["bounds"]
	var block_size: float = float(district["block"])
	var street: float = float(district["street"])
	var pitch: float = block_size + street
	if pitch <= 1.0:
		return

	var i_from: int = int(floor((chunk_rect.position.x - bounds.position.x) / pitch)) - 1
	var i_to: int = int(ceil((chunk_rect.end.x - bounds.position.x) / pitch)) + 1
	var j_from: int = int(floor((chunk_rect.position.y - bounds.position.y) / pitch)) - 1
	var j_to: int = int(ceil((chunk_rect.end.y - bounds.position.y) / pitch)) + 1

	for i: int in range(i_from, i_to + 1):
		for j: int in range(j_from, j_to + 1):
			var origin := Vector2(bounds.position.x + float(i) * pitch, bounds.position.y + float(j) * pitch)
			var block := Rect2(origin, Vector2(block_size, block_size))
			var center: Vector2 = block.get_center()

			# Квартал принадлежит тому чанку, где лежит его центр — это и даёт бесшовность.
			if not chunk_rect.has_point(center):
				continue
			if not bounds.has_point(center):
				continue
			if CityAtlas.is_in_river(center):
				continue

			_fill_block(block, district, result, reserved, corridors, rng, detail_level)


static func _fill_block(block: Rect2, district: Dictionary, result: Dictionary, reserved: Array[Rect2], corridors: Array[Rect2], rng: RandomNumberGenerator, detail_level: int) -> void:
	var density: float = float(district["density"])
	if rng.randf() > density + 0.12:
		return  # пустырь или парковка — город не должен быть сплошной стеной

	var zone_bounds: Rect2 = district["bounds"]
	var lots: Array[Rect2] = _subdivide(block, district, rng)
	for lot: Rect2 in lots:
		if lot.size.x < MIN_LOT or lot.size.y < MIN_LOT:
			continue

		# 1. Участок не имеет права выходить за границу своей зоны: сетки
		# районов не согласованы между собой, и именно здесь рождались
		# здания, вросшие одно в другое на стыке кварталов.
		var plot: Rect2 = lot.intersection(zone_bounds)
		if plot.size.x < MIN_LOT or plot.size.y < MIN_LOT:
			continue

		# 2. Улицы важнее домов: если участок залез на асфальт, обрезаем,
		# а если обрезок мал — не строим вовсе.
		plot = _clip_from_roads(plot, corridors)
		if plot.size.x < MIN_LOT or plot.size.y < MIN_LOT:
			continue

		# 3. И только теперь проверяем занятость — по итоговому пятну,
		# а не по исходному участку, как было раньше.
		if _overlaps_any(plot.grow(PLOT_CLEARANCE * 0.8), reserved):
			continue
		if _lot_in_river(plot):
			continue
		if rng.randf() > density:
			continue
		var building: Dictionary = _make_building(plot, district, rng)
		if building.is_empty():
			continue

		# Стилобат: башню поджимаем и ставим вокруг низкий объём на весь
		# участок: два уступа вместо одной коробки.
		var podium: Dictionary = _make_podium(building, district)

		(result["buildings"] as Array).append(building)
		if not podium.is_empty():
			(result["buildings"] as Array).append(podium)
		reserved.append(plot.grow(PLOT_CLEARANCE))

		_add_signs(building, district, result)
		if detail_level == 0:
			_add_props(building, district, result)
			# Подъезд рядового дома. Стилобат важнее башни: вход всегда
			# в нижний объём, и именно он задаёт габариты интерьера.
			_add_entrance(podium if not podium.is_empty() else building, result, corridors)


# -------------------------------------------------------------------- подъезды

## Вход в дом. Делает три вещи:
##   • помечает дом проходимым — `CityChunk` соберёт ему оболочку с проёмом;
##   • ставит крыльцо с козырьком и лампой, чтобы вход было видно с улицы;
##   • записывает данные для фабрики интерьеров.
## Идентификатор строится от координат, поэтому устойчив между пересборками
## чанка: игрок вышел и вернулся — квартиры те же.
static func _add_entrance(building: Dictionary, result: Dictionary, corridors: Array[Rect2]) -> void:
	var size: Vector3 = building["size"]
	if size.x < ENTERABLE_MIN_SIDE or size.z < ENTERABLE_MIN_SIDE:
		return

	var center: Vector3 = building["center"]
	var floors: int = maxi(1, int(building.get("floors", 1)))
	var side: int = _street_side(center, size, corridors)
	var normal: Vector3 = _side_normal(side)
	var half: float = size.x * 0.5 if absf(normal.x) > 0.5 else size.z * 0.5
	var door_point: Vector3 = Vector3(center.x, 0.0, center.z) + normal * (half + PORCH_DEPTH + 0.4)
	var interior_id: String = "bld_%d_%d" % [int(round(center.x * 4.0)), int(round(center.z * 4.0))]

	building["enterable"] = true
	building["door_side"] = side
	_add_porch(building, side, result)

	(result["entrances"] as Array).append({
		"location_id": interior_id,
		# Точка перед крыльцом: именно от неё считается радиус открытия.
		"position": door_point,
		"origin": Vector2(center.x, center.z),
		"footprint": Vector2(size.x, size.z),
		"floors": floors,
		"door_side": side,
		"kind": -1,
		"lock_level": 0,
		"has_camera": false,
		"atlas": false,
	})


## Крыльцо: две боковые стенки, козырёк, ступень и лампа над проёмом.
## Коллизий у крыльца нет намеренно — сквозь него игрок и заходит внутрь.
static func _add_porch(building: Dictionary, side: int, result: Dictionary) -> void:
	var size: Vector3 = building["size"]
	var center: Vector3 = building["center"]
	var normal: Vector3 = _side_normal(side)
	var tangent := Vector3(normal.z, 0.0, normal.x)
	var along_x: bool = absf(normal.x) > 0.5
	var half: float = size.x * 0.5 if along_x else size.z * 0.5
	var face: Vector3 = Vector3(center.x, 0.0, center.z) + normal * half
	var width: float = DOOR_WIDTH + 1.0
	var thickness: float = 0.3
	var wall_height: float = DOOR_HEIGHT + 0.2

	for s: int in [-1, 1]:
		var pos: Vector3 = face + normal * (PORCH_DEPTH * 0.5) + tangent * (float(s) * width * 0.5)
		var wall_size: Vector3 = (
			Vector3(PORCH_DEPTH, wall_height, thickness) if along_x
			else Vector3(thickness, wall_height, PORCH_DEPTH)
		)
		(result["props"] as Array).append({
			"transform": Transform3D(Basis.IDENTITY.scaled(wall_size), Vector3(pos.x, wall_height * 0.5, pos.z)),
			"kind": "porch_wall",
		})

	# Козырёк над входом.
	var canopy_size: Vector3 = (
		Vector3(PORCH_DEPTH + 0.5, 0.26, width + 0.6) if along_x
		else Vector3(width + 0.6, 0.26, PORCH_DEPTH + 0.5)
	)
	var canopy_pos: Vector3 = face + normal * (PORCH_DEPTH * 0.5)
	(result["props"] as Array).append({
		"transform": Transform3D(
			Basis.IDENTITY.scaled(canopy_size),
			Vector3(canopy_pos.x, DOOR_HEIGHT + 0.38, canopy_pos.z)
		),
		"kind": "porch_canopy",
	})

	# Ступень перед проёмом.
	var step_size: Vector3 = (
		Vector3(1.2, 0.18, width + 0.4) if along_x
		else Vector3(width + 0.4, 0.18, 1.2)
	)
	var step_pos: Vector3 = face + normal * (PORCH_DEPTH + 0.55)
	(result["props"] as Array).append({
		"transform": Transform3D(Basis.IDENTITY.scaled(step_size), Vector3(step_pos.x, 0.09, step_pos.z)),
		"kind": "porch_step",
	})

	# Лампа над дверью: главный ориентир ночью — по ней вход и находят.
	var lamp_basis := Basis.looking_at(-normal, Vector3.UP).scaled(Vector3(width * 0.7, 0.34, 1.0))
	var lamp_pos: Vector3 = face + normal * (PORCH_DEPTH + 0.06) + Vector3(0.0, DOOR_HEIGHT + 0.66, 0.0)
	(result["signs"] as Array).append({
		"transform": Transform3D(lamp_basis, lamp_pos),
		"tint": CityAtlas.palette("window_warm"),
		"custom": Color(0.31, 0.95, 0.0, 0.0),
	})


## Сторона, обращённая к улице: 0 = +X, 1 = -X, 2 = +Z, 3 = -Z.
## Вход всегда смотрит на ближайший дорожный коридор, иначе дверь упирается
## в стену соседнего дома.
static func _street_side(center: Vector3, size: Vector3, corridors: Array[Rect2]) -> int:
	var best: int = 2
	var best_distance: float = INF
	for side: int in range(4):
		var normal: Vector3 = _side_normal(side)
		var half: float = size.x * 0.5 if absf(normal.x) > 0.5 else size.z * 0.5
		var probe := Vector2(
			center.x + normal.x * (half + 3.5),
			center.z + normal.z * (half + 3.5)
		)
		var distance: float = INF
		for corridor: Rect2 in corridors:
			distance = minf(distance, _rect_distance(corridor, probe))
			if distance <= 0.0:
				break
		if distance < best_distance:
			best_distance = distance
			best = side
	return best


static func _side_normal(side: int) -> Vector3:
	match side:
		0:
			return Vector3.RIGHT
		1:
			return Vector3.LEFT
		2:
			return Vector3.BACK
		_:
			return Vector3.FORWARD


## Расстояние от точки до прямоугольника. Внутри прямоугольника — ноль.
static func _rect_distance(rect: Rect2, point: Vector2) -> float:
	var dx: float = maxf(maxf(rect.position.x - point.x, 0.0), point.x - rect.end.x)
	var dy: float = maxf(maxf(rect.position.y - point.y, 0.0), point.y - rect.end.y)
	return sqrt(dx * dx + dy * dy)


## Обрезка участка от дорожных коридоров. Отрезаем только то, что торчит
## на проезжую часть, с той стороны, где перекрытие меньше: так улица
## проходит насквозь, а квартал теряет лишь полоску по краю.
static func _clip_from_roads(lot: Rect2, corridors: Array[Rect2]) -> Rect2:
	var plot: Rect2 = lot
	for corridor: Rect2 in corridors:
		var hit: Rect2 = plot.intersection(corridor)
		if hit.size.x <= 0.01 or hit.size.y <= 0.01:
			continue
		# Коридор проглотил участок целиком — строить негде.
		if hit.size.x >= plot.size.x - 0.01 and hit.size.y >= plot.size.y - 0.01:
			return Rect2(plot.position, Vector2.ZERO)

		var cut_left: float = hit.end.x - plot.position.x
		var cut_right: float = plot.end.x - hit.position.x
		var cut_top: float = hit.end.y - plot.position.y
		var cut_bottom: float = plot.end.y - hit.position.y
		var best: float = minf(minf(cut_left, cut_right), minf(cut_top, cut_bottom))

		if is_equal_approx(best, cut_left):
			plot = Rect2(Vector2(hit.end.x, plot.position.y), Vector2(plot.end.x - hit.end.x, plot.size.y))
		elif is_equal_approx(best, cut_right):
			plot = Rect2(plot.position, Vector2(hit.position.x - plot.position.x, plot.size.y))
		elif is_equal_approx(best, cut_top):
			plot = Rect2(Vector2(plot.position.x, hit.end.y), Vector2(plot.size.x, plot.end.y - hit.end.y))
		else:
			plot = Rect2(plot.position, Vector2(plot.size.x, hit.position.y - plot.position.y))

		if plot.size.x < MIN_LOT or plot.size.y < MIN_LOT:
			return Rect2(plot.position, Vector2.ZERO)
	return plot


## Стилобат для высокого дома. Меняет [param building] на месте.
static func _make_podium(building: Dictionary, district: Dictionary) -> Dictionary:
	var height: float = float(building["height"])
	if height < PODIUM_MIN_HEIGHT:
		return {}

	var rng := _deco_rng(building, 0x7F4A7C15)
	if rng.randf() > PODIUM_CHANCE:
		return {}

	var lot: Rect2 = building["rect"]
	var shrink: float = minf(2.8, minf(lot.size.x, lot.size.y) * 0.17)
	if lot.size.x - shrink * 2.0 < MIN_LOT or lot.size.y - shrink * 2.0 < MIN_LOT:
		return {}

	var floors: int = rng.randi_range(2, 4)
	var podium_height: float = clampf(float(floors) * FLOOR_HEIGHT, FLOOR_HEIGHT * 2.0, height * 0.42)
	var center: Vector3 = building["center"]
	var tower_lot: Rect2 = lot.grow(-shrink)

	building["size"] = Vector3(tower_lot.size.x, height, tower_lot.size.y)
	building["rect"] = tower_lot
	# Башня не должна закупоривать стилобат изнутри: её коллизия начинается
	# там, где заканчивается нижний объём, иначе внутрь не войти.
	building["collision_from_y"] = podium_height

	var tint: Color = building["tint"]
	var custom: Color = building["custom"]
	return {
		"center": Vector3(center.x, podium_height * 0.5, center.z),
		"size": Vector3(lot.size.x, podium_height, lot.size.y),
		"height": podium_height,
		"floors": maxi(1, int(podium_height / FLOOR_HEIGHT)),
		"tint": tint,
		# У стилобата первые этажи — витрины, светящихся окон больше.
		"custom": Color(rng.randf(), clampf(custom.g + 0.22, 0.1, 0.95), custom.b, 0.0),
		"district": str(district["id"]),
		"is_landmark": false,
		"is_podium": true,
		"location_id": "",
		"deco_seed": rng.randi(),
		"rect": lot,
	}


## Делит квартал на 1-9 участков с переулками между ними.
static func _subdivide(block: Rect2, district: Dictionary, rng: RandomNumberGenerator) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var profile: String = str(district["profile"])

	var splits: int = 1
	if profile in ["industrial", "harbor"]:
		splits = [1, 2, 4][rng.randi_range(0, 2)]
	elif profile == "waterfront":
		splits = [2, 4, 4][rng.randi_range(0, 2)]
	elif profile in ["slum", "oldtown"]:
		splits = 9 if rng.randf() < 0.55 else 4
	else:
		splits = [2, 4, 4, 9][rng.randi_range(0, 3)]

	var inset: Rect2 = block.grow(-LOT_INSET)
	if inset.size.x <= MIN_LOT or inset.size.y <= MIN_LOT:
		return out

	while splits > 1 and (inset.size.x / sqrt(float(splits))) < MIN_LOT + ALLEY_WIDTH:
		splits = 4 if splits == 9 else (2 if splits == 4 else 1)

	if splits == 1:
		out.append(inset)
		return out

	if splits == 2:
		if rng.randf() < 0.5:
			var w: float = (inset.size.x - ALLEY_WIDTH) * 0.5
			out.append(Rect2(inset.position, Vector2(w, inset.size.y)))
			out.append(Rect2(Vector2(inset.position.x + w + ALLEY_WIDTH, inset.position.y), Vector2(w, inset.size.y)))
		else:
			var h: float = (inset.size.y - ALLEY_WIDTH) * 0.5
			out.append(Rect2(inset.position, Vector2(inset.size.x, h)))
			out.append(Rect2(Vector2(inset.position.x, inset.position.y + h + ALLEY_WIDTH), Vector2(inset.size.x, h)))
		return out

	var side: int = 2 if splits == 4 else 3
	var gaps: float = ALLEY_WIDTH * float(side - 1)
	var lot_w: float = (inset.size.x - gaps) / float(side)
	var lot_h: float = (inset.size.y - gaps) / float(side)
	if lot_w < MIN_LOT or lot_h < MIN_LOT:
		out.append(inset)
		return out

	for sx: int in range(side):
		for sy: int in range(side):
			var pos := Vector2(
				inset.position.x + float(sx) * (lot_w + ALLEY_WIDTH),
				inset.position.y + float(sy) * (lot_h + ALLEY_WIDTH)
			)
			out.append(Rect2(pos, Vector2(lot_w, lot_h)))
	return out


static func _make_building(lot: Rect2, district: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var h_min: float = float(district["height_min"])
	var h_max: float = float(district["height_max"])
	var bounds: Rect2 = district["bounds"]
	var center: Vector2 = lot.get_center()

	# Ближе к центру района — выше.
	var half_diag: float = maxf(1.0, bounds.size.length() * 0.5)
	var core_bias: float = clampf(1.0 - center.distance_to(bounds.get_center()) / half_diag, 0.0, 1.0)
	core_bias = pow(core_bias, 1.6)

	var roll: float = pow(rng.randf(), 2.1)
	var height: float = h_min + (h_max - h_min) * roll * (0.35 + 1.15 * core_bias)
	height = clampf(height, h_min, h_max)
	height = maxf(FLOOR_HEIGHT, round(height / FLOOR_HEIGHT) * FLOOR_HEIGHT)

	var palette: Array[Color] = CityAtlas.district_palette(str(district["id"]))
	var tint: Color = palette[rng.randi_range(0, palette.size() - 1)] if not palette.is_empty() else Color.WHITE

	var neon_budget: float = float(district["neon"])
	var wealth: float = float(district["wealth"])
	var deco_seed: int = rng.randi()

	return {
		"center": Vector3(center.x, height * 0.5, center.y),
		"size": Vector3(lot.size.x, height, lot.size.y),
		"height": height,
		"floors": maxi(1, int(height / FLOOR_HEIGHT)),
		"tint": tint,
		# x=сид, y=доля светящихся окон, z=примесь неона, w=landmark
		"custom": Color(
			rng.randf(),
			clampf(0.18 + wealth * 0.35 + rng.randf() * 0.25, 0.05, 0.85),
			clampf(neon_budget * 0.55, 0.0, 0.8),
			0.0
		),
		"district": str(district["id"]),
		"is_landmark": false,
		"location_id": "",
		"deco_seed": deco_seed,
		"rect": lot,
	}


# ------------------------------------------------------------------ landmark'и

static func _place_atlas_locations(chunk_rect: Rect2, result: Dictionary, reserved: Array[Rect2], rng: RandomNumberGenerator, detail_level: int) -> void:
	for location_id: String in CityAtlas.locations_in_rect(chunk_rect):
		var loc: Dictionary = CityAtlas.get_location(location_id)
		if loc.is_empty():
			continue

		var kind: int = int(loc["kind"])
		var position: Vector2 = loc["position"]
		var district: Dictionary = CityAtlas.get_district(str(loc["district"]))
		if district.is_empty():
			continue

		if OPEN_AIR_KINDS.has(kind):
			reserved.append(Rect2(position - Vector2(24.0, 24.0), Vector2(48.0, 48.0)))
			continue

		var footprint: Vector2 = LANDMARK_FOOTPRINT.get(kind, Vector2(22.0, 18.0))
		var floors: int = maxi(1, int(loc["floors"]))
		var height: float = maxf(FLOOR_HEIGHT, float(floors) * FLOOR_HEIGHT)
		height = clampf(height, float(district["height_min"]), maxf(float(district["height_max"]), height))

		var lot := Rect2(position - footprint * 0.5, footprint)
		if _lot_in_river(lot):
			Log.warn("BuildingFactory", "Локация атласа попала в русло — здание не ставится", {"id": location_id})
			continue

		var palette: Array[Color] = CityAtlas.district_palette(str(district["id"]))
		var tint: Color = palette[0] if not palette.is_empty() else Color.WHITE
		var is_landmark: bool = bool(loc.get("is_landmark", false))
		var deco_seed: int = rng.randi()

		var building: Dictionary = {
			"center": Vector3(position.x, height * 0.5, position.y),
			"size": Vector3(footprint.x, height, footprint.y),
			"height": height,
			"floors": floors,
			"tint": tint,
			"custom": Color(
				rng.randf(),
				clampf(0.35 + float(district["wealth"]) * 0.4, 0.1, 0.95),
				clampf(float(district["neon"]) * 0.7, 0.0, 0.9),
				1.0 if is_landmark else 0.5
			),
			"district": str(district["id"]),
			"is_landmark": true,
			"location_id": location_id,
			"deco_seed": deco_seed,
			"rect": lot,
		}

		var podium: Dictionary = _make_podium(building, district)

		(result["buildings"] as Array).append(building)
		if not podium.is_empty():
			(result["buildings"] as Array).append(podium)
		reserved.append(lot.grow(2.0))

		# Сюжетное здание тоже должно открываться пешком, а не по сценарию:
		# вход всегда со стороны +Z, там же стоит крыльцо.
		var host: Dictionary = podium if not podium.is_empty() else building
		var host_size: Vector3 = host["size"]
		if detail_level == 0 and host_size.x >= ENTERABLE_MIN_SIDE and host_size.z >= ENTERABLE_MIN_SIDE:
			host["enterable"] = true
			host["door_side"] = 2
			_add_porch(host, 2, result)

		(result["entrances"] as Array).append({
			"location_id": location_id,
			"position": Vector3(position.x, 0.0, position.y + footprint.y * 0.5 + PORCH_DEPTH + 0.4),
			"origin": position,
			"footprint": footprint,
			"kind": kind,
			"lock_level": int(loc["lock_level"]),
			"has_camera": bool(loc["has_camera"]),
			"floors": floors,
			"door_side": 2,
			# Сюжетный адрес: интерьер строится по данным атласа.
			"atlas": true,
		})

		_add_signs(building, district, result, true)
		if detail_level == 0:
			_add_props(building, district, result)


## Резерв под сюжетные здания соседних чанков. Геометрию они получат в своём
## чанке, здесь важно только не застроить их пятно.
static func _reserve_neighbor_landmarks(chunk_rect: Rect2, reserved: Array[Rect2]) -> void:
	for location_id: String in CityAtlas.locations_in_rect(chunk_rect.grow(60.0)):
		var loc: Dictionary = CityAtlas.get_location(location_id)
		if loc.is_empty():
			continue
		var position: Vector2 = loc["position"]
		if chunk_rect.has_point(position):
			continue
		var footprint: Vector2 = LANDMARK_FOOTPRINT.get(int(loc["kind"]), Vector2(22.0, 18.0))
		reserved.append(Rect2(position - footprint * 0.5, footprint).grow(2.0))


# ---------------------------------------------------------------- вывески

static func _add_signs(building: Dictionary, district: Dictionary, result: Dictionary, force: bool = false) -> void:
	var rng := _deco_rng(building, 0x51ED270B)
	var neon_budget: float = float(district["neon"])
	if not force and rng.randf() > neon_budget:
		return

	var size: Vector3 = building["size"]
	var center: Vector3 = building["center"]
	var height: float = float(building["height"])
	var palette: Array[Color] = CityAtlas.district_palette(str(district["id"]))
	if palette.is_empty():
		return

	var count: int = 1
	if neon_budget > 0.8:
		count = rng.randi_range(1, 3)
	elif neon_budget > 0.45:
		count = rng.randi_range(1, 2)

	for _i: int in range(count):
		var side: int = rng.randi_range(0, 3)
		var facing: Vector3 = Vector3.ZERO
		var half: float = 0.0
		var along: float = 0.0
		match side:
			0:
				facing = Vector3.RIGHT
				half = size.x * 0.5
				along = size.z
			1:
				facing = Vector3.LEFT
				half = size.x * 0.5
				along = size.z
			2:
				facing = Vector3.BACK
				half = size.z * 0.5
				along = size.x
			_:
				facing = Vector3.FORWARD
				half = size.z * 0.5
				along = size.x

		var vertical: bool = height > 26.0 and rng.randf() < 0.72
		var sign_w: float = 0.0
		var sign_h: float = 0.0
		var y: float = 0.0

		if vertical:
			sign_w = clampf(rng.randf_range(1.1, 2.4), 1.0, along * 0.35)
			sign_h = clampf(height * rng.randf_range(0.32, 0.62), 4.0, height - 6.0)
			y = rng.randf_range(sign_h * 0.5 + 5.0, height - sign_h * 0.5 - 1.5)
		else:
			sign_w = clampf(along * rng.randf_range(0.45, 0.85), 2.0, along - 1.0)
			sign_h = rng.randf_range(0.7, 1.6)
			y = rng.randf_range(4.0, minf(9.0, maxf(4.5, height - 2.0)))

		if sign_h <= 0.2 or sign_w <= 0.2:
			continue

		var lateral: float = rng.randf_range(-along * 0.35, along * 0.35)
		var offset: Vector3 = facing * (half + 0.12)
		var position: Vector3 = Vector3(center.x, y, center.z) + offset
		if absf(facing.x) > 0.5:
			position.z += lateral
		else:
			position.x += lateral

		var basis := Basis.looking_at(-facing, Vector3.UP)
		basis = basis.scaled(Vector3(sign_w, sign_h, 1.0))

		var color: Color = palette[rng.randi_range(0, palette.size() - 1)]
		var broken: float = 1.0 if rng.randf() < 0.14 else 0.0
		var scroll: float = rng.randf_range(0.4, 1.4) if rng.randf() < 0.22 else 0.0

		(result["signs"] as Array).append({
			"transform": Transform3D(basis, position),
			"tint": color,
			"custom": Color(rng.randf(), rng.randf_range(0.55, 1.0), broken, scroll),
		})

	_add_roof_crown(building, palette, result, rng)


## Светящаяся «корона» под крышей башни и маяк наверху.
static func _add_roof_crown(building: Dictionary, palette: Array[Color], result: Dictionary, rng: RandomNumberGenerator) -> void:
	var height: float = float(building["height"])
	if height < 45.0:
		return

	var size: Vector3 = building["size"]
	var center: Vector3 = building["center"]
	var color: Color = palette[rng.randi_range(0, palette.size() - 1)]
	var band_height: float = clampf(height * 0.02, 0.8, 2.2)
	var y: float = height - band_height * 1.6

	for side: int in range(4):
		var facing: Vector3 = Vector3.ZERO
		var half: float = 0.0
		var along: float = 0.0
		match side:
			0:
				facing = Vector3.RIGHT
				half = size.x * 0.5
				along = size.z
			1:
				facing = Vector3.LEFT
				half = size.x * 0.5
				along = size.z
			2:
				facing = Vector3.BACK
				half = size.z * 0.5
				along = size.x
			_:
				facing = Vector3.FORWARD
				half = size.z * 0.5
				along = size.x

		var basis := Basis.looking_at(-facing, Vector3.UP)
		basis = basis.scaled(Vector3(along * 0.92, band_height, 1.0))
		(result["signs"] as Array).append({
			"transform": Transform3D(basis, Vector3(center.x, y, center.z) + facing * (half + 0.1)),
			"tint": color,
			"custom": Color(rng.randf(), 0.7, 0.0, 0.0),
		})

	if height > 85.0:
		var beacon_basis := Basis.looking_at(Vector3.DOWN, Vector3.BACK).scaled(Vector3(1.2, 1.2, 1.0))
		(result["signs"] as Array).append({
			"transform": Transform3D(beacon_basis, Vector3(center.x, height + 0.4, center.z)),
			"tint": CityAtlas.palette("police_red"),
			"custom": Color(rng.randf(), 0.9, 1.0, 0.0),
		})


# ---------------------------------------------------------------- реквизит

static func _add_props(building: Dictionary, district: Dictionary, result: Dictionary) -> void:
	var rng := _deco_rng(building, 0x2545F491)
	var size: Vector3 = building["size"]
	var center: Vector3 = building["center"]
	var height: float = float(building["height"])

	var roof_units: int = rng.randi_range(0, 3)
	for _i: int in range(roof_units):
		var unit_size := Vector3(rng.randf_range(1.0, 2.2), rng.randf_range(0.6, 1.4), rng.randf_range(1.0, 2.2))
		var pos := Vector3(
			center.x + rng.randf_range(-size.x * 0.35, size.x * 0.35),
			height + unit_size.y * 0.5,
			center.z + rng.randf_range(-size.z * 0.35, size.z * 0.35)
		)
		(result["props"] as Array).append({
			"transform": Transform3D(Basis.IDENTITY.scaled(unit_size), pos),
			"kind": "roof_unit",
		})

	if height > 12.0 and rng.randf() < 0.55:
		var side_sign: float = 1.0 if rng.randf() < 0.5 else -1.0
		var ladder_size := Vector3(0.9, height - 3.0, 0.35)
		var pos := Vector3(
			center.x + side_sign * (size.x * 0.5 + 0.2),
			(height - 3.0) * 0.5 + 1.5,
			center.z + rng.randf_range(-size.z * 0.3, size.z * 0.3)
		)
		(result["props"] as Array).append({
			"transform": Transform3D(Basis.IDENTITY.scaled(ladder_size), pos),
			"kind": "fire_escape",
		})

	var ground_units: int = rng.randi_range(0, 2)
	for _i: int in range(ground_units):
		var unit_size := Vector3(rng.randf_range(1.4, 2.4), rng.randf_range(1.0, 1.5), rng.randf_range(0.9, 1.4))
		var angle: float = rng.randf() * TAU
		var pos := Vector3(
			center.x + cos(angle) * (size.x * 0.5 + rng.randf_range(0.8, 2.4)),
			unit_size.y * 0.5,
			center.z + sin(angle) * (size.z * 0.5 + rng.randf_range(0.8, 2.4))
		)
		(result["props"] as Array).append({
			"transform": Transform3D(Basis.IDENTITY.scaled(unit_size), pos),
			"kind": "dumpster",
		})


# -------------------------------------------------------------------- дороги

## Дороги района. Магистрали намеренно выпускаются за границу района
## на ROAD_OVERRUN метров, чтобы стыковаться с сеткой соседа, а не обрываться
## ровно по его торцу. Каждая полоса попадает в [param corridors] — туда
## застройка не залезет.
static func _generate_roads(chunk_rect: Rect2, district: Dictionary, result: Dictionary, rng: RandomNumberGenerator, corridors: Array[Rect2]) -> void:
	var bounds: Rect2 = district["bounds"]
	var block_size: float = float(district["block"])
	var street: float = float(district["street"])
	var pitch: float = block_size + street
	if pitch <= 1.0:
		return

	var overlap: Rect2 = chunk_rect.intersection(bounds)
	if overlap.size.x <= 0.0 or overlap.size.y <= 0.0:
		return

	# Полотно района под чанком — на нём стоят здания.
	(result["roads"] as Array).append({
		"rect": overlap,
		"arterial": false,
		"along_x": true,
		"y": 0.0,
	})

	# Зона, в которой разрешено тянуть магистрали этого района.
	var reach: Rect2 = chunk_rect.intersection(bounds.grow(ROAD_OVERRUN))
	if reach.size.x <= 0.0 or reach.size.y <= 0.0:
		return

	var i_from: int = int(floor((reach.position.x - bounds.position.x) / pitch))
	var i_to: int = int(ceil((reach.end.x - bounds.position.x) / pitch))
	for i: int in range(i_from, i_to + 1):
		# Коридор обычной улицы: раньше застройка знала только про
		# магистрали, поэтому кварталы соседнего района спокойно садились
		# на рядовую улицу — дома стояли прямо на асфальте.
		var lane_x: float = bounds.position.x + float(i) * pitch + block_size
		var lane := Rect2(Vector2(lane_x, reach.position.y), Vector2(street, reach.size.y))
		var lane_clip: Rect2 = lane.intersection(reach)
		if lane_clip.size.x > 0.5 and lane_clip.size.y > 0.5:
			corridors.append(lane_clip.grow(CORRIDOR_MARGIN * 0.5))

		if i % ARTERIAL_EVERY != 0:
			continue
		var x: float = bounds.position.x + float(i) * pitch - street * 0.5
		var strip := Rect2(Vector2(x - street * 0.5, reach.position.y), Vector2(street * 2.0, reach.size.y))
		var clipped: Rect2 = strip.intersection(reach)
		if clipped.size.x <= 0.5 or clipped.size.y <= 0.5:
			continue
		(result["roads"] as Array).append({"rect": clipped, "arterial": true, "along_x": false, "y": 0.02})
		corridors.append(clipped.grow(CORRIDOR_MARGIN))
		_add_lamps(clipped, false, result, rng)

	var j_from: int = int(floor((reach.position.y - bounds.position.y) / pitch))
	var j_to: int = int(ceil((reach.end.y - bounds.position.y) / pitch))
	for j: int in range(j_from, j_to + 1):
		var lane_z: float = bounds.position.y + float(j) * pitch + block_size
		var lane := Rect2(Vector2(reach.position.x, lane_z), Vector2(reach.size.x, street))
		var lane_clip: Rect2 = lane.intersection(reach)
		if lane_clip.size.x > 0.5 and lane_clip.size.y > 0.5:
			corridors.append(lane_clip.grow(CORRIDOR_MARGIN * 0.5))

		if j % ARTERIAL_EVERY != 0:
			continue
		var z: float = bounds.position.y + float(j) * pitch - street * 0.5
		var strip := Rect2(Vector2(reach.position.x, z - street * 0.5), Vector2(reach.size.x, street * 2.0))
		var clipped: Rect2 = strip.intersection(reach)
		if clipped.size.x <= 0.5 or clipped.size.y <= 0.5:
			continue
		(result["roads"] as Array).append({"rect": clipped, "arterial": true, "along_x": true, "y": 0.02})
		corridors.append(clipped.grow(CORRIDOR_MARGIN))
		_add_lamps(clipped, true, result, rng)


static func _add_lamps(strip: Rect2, along_x: bool, result: Dictionary, rng: RandomNumberGenerator) -> void:
	var length: float = strip.size.x if along_x else strip.size.y
	var count: int = maxi(1, int(length / LAMP_SPACING))
	var amber: Color = CityAtlas.palette("sodium_amber")

	for i: int in range(count):
		var t: float = (float(i) + 0.5) / float(count)
		var pos: Vector2
		if along_x:
			pos = Vector2(strip.position.x + strip.size.x * t, strip.get_center().y + strip.size.y * 0.42)
		else:
			pos = Vector2(strip.get_center().x + strip.size.x * 0.42, strip.position.y + strip.size.y * t)
		(result["lamps"] as Array).append({
			"position": Vector3(pos.x, 0.0, pos.y),
			"height": rng.randf_range(6.0, 8.5),
			"color": amber,
		})


# ------------------------------------------------------------------ окклюдеры

static func _collect_occluders(result: Dictionary) -> void:
	for building: Variant in result["buildings"] as Array:
		var b: Dictionary = building as Dictionary
		if float(b["height"]) < OCCLUDER_MIN_HEIGHT:
			continue
		var size: Vector3 = b["size"]
		var center: Vector3 = b["center"]
		(result["occluders"] as Array).append({
			"center": center,
			"size": Vector3(maxf(1.0, size.x - 1.0), maxf(1.0, size.y - 1.0), maxf(1.0, size.z - 1.0)),
		})


static func _overlaps_any(rect: Rect2, others: Array[Rect2]) -> bool:
	for other: Rect2 in others:
		if rect.intersects(other):
			return true
	return false


static func _lot_in_river(lot: Rect2) -> bool:
	if CityAtlas.is_in_river(lot.get_center()):
		return true
	var corners: Array[Vector2] = [
		lot.position,
		Vector2(lot.end.x, lot.position.y),
		lot.end,
		Vector2(lot.position.x, lot.end.y),
	]
	for corner: Vector2 in corners:
		if CityAtlas.is_in_river(corner):
			return true
	return false


## Персональный генератор для декора здания.
static func _deco_rng(building: Dictionary, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	var base: int = int(building.get("deco_seed", 0))
	if base == 0:
		var center: Vector3 = building.get("center", Vector3.ZERO)
		base = int(center.x * 71.0) ^ int(center.z * 131.0)
	rng.seed = absi(base ^ salt) | 0x40
	return rng
