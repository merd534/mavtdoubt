class_name NoirStreetDresser
extends RefCounted
## Наполнение улиц: остановки, светофоры, урны, скамьи, гидранты, киоски,
## телефонные будки, газетные автоматы, паркоматы, мусор и припаркованные машины.
##
## Правила размещения (после фикса «объекты стоят посреди дороги»):
##  * весь реквизит стоит СТРОГО за кромкой асфальта, на полосе тротуара,
##    которую кладёт NoirSidewalkBuilder; поперечного разброса больше нет;
##  * зоны перекрёстков (END_CLEAR с каждого конца дороги) остаются пустыми,
##    поэтому светофор и остановка не могут оказаться на пересечении;
##  * каждый предмет развёрнут лицом к дороге, а не случайно;
##  * машины паркуются в кармане у кромки и всегда смотрят по направлению
##    движения своей стороны (правостороннее), а не «в тупик»;
##  * бордюры, разметка и зебры здесь больше НЕ рисуются — это работа
##    NoirSidewalkBuilder, иначе две разметки накладывались друг на друга.
##
## Возвращаются не узлы, а пачки трансформов по материалам: чанк сливает
## каждую пачку в один MultiMesh и не теряет бюджет вызовов отрисовки.

const WALK_CENTER := 2.3        ## от кромки асфальта до оси реквизита
const PARK_INSET := 1.9         ## от кромки внутрь: парковочный карман
const END_CLEAR := 13.0         ## пустая зона у перекрёстков
const STEP_MIN := 9.0
const STEP_MAX := 20.0
const MAX_ITEMS := 460
const MAX_CARS := 22
const MAX_LIGHTS := 4
const MIN_ROAD := 34.0          ## короткие связки — это по сути перекрёстки
const MIN_PARK_WIDTH := 9.0     ## на узкой улице парковка перекрыла бы проезд
const STOP_MIN_LEN := 78.0      ## остановка только на длинном пролёте


static func defaults() -> Dictionary:
	return {
		"density": 0.8,
		"cars": true,
		"debris": true,
		"neon": true,
		"puddles": true,
		"max_items": MAX_ITEMS,
	}


## Главная точка входа. [param roads] — массив словарей {rect, y, arterial}
## из NoirBuildingFactory.
static func generate(roads: Array, city_seed: int, coords: Vector2i, cfg: Dictionary) -> Dictionary:
	var out: Dictionary = _empty()
	if roads.is_empty():
		return out

	var density: float = clampf(float(cfg.get("density", 0.8)), 0.0, 1.5)
	if density <= 0.05:
		return out
	var limit: int = maxi(24, int(cfg.get("max_items", MAX_ITEMS)))

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(city_seed, coords.x, coords.y))

	var flags: Dictionary = {
		"cars": bool(cfg.get("cars", true)),
		"debris": bool(cfg.get("debris", true)),
		"neon": bool(cfg.get("neon", true)),
		"puddles": bool(cfg.get("puddles", true)),
	}

	for entry: Variant in roads:
		if not (entry is Dictionary):
			continue
		var road: Dictionary = entry as Dictionary
		var raw_rect: Variant = road.get("rect", null)
		if not (raw_rect is Rect2):
			continue
		var r: Rect2 = raw_rect as Rect2
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue

		var horizontal: bool = r.size.x >= r.size.y
		var length: float = r.size.x if horizontal else r.size.y
		var width: float = r.size.y if horizontal else r.size.x
		# Куски короче MIN_ROAD — это перемычки и перекрёстки: любой предмет там
		# гарантированно окажется «посреди дороги».
		if length < MIN_ROAD or width < 5.0:
			continue

		_dress_road(out, r, float(road.get("y", 0.0)), horizontal, length, width,
			bool(road.get("arterial", false)), density, rng, flags)

		if count(out) >= limit:
			break

	return out


static func _empty() -> Dictionary:
	return {
		"concrete": [] as Array[Transform3D],   ## скамьи, тумбы, козырьки, крыши
		"metal": [] as Array[Transform3D],      ## корпуса светофоров, щитки, ящики
		"poles": [] as Array[Transform3D],      ## стойки
		"rust": [] as Array[Transform3D],       ## урны и контейнеры
		"cardboard": [] as Array[Transform3D],  ## ящики и кипы газет
		"glass": [] as Array[Transform3D],      ## витрины, стёкла остановок и машин
		"cars": [] as Array[Transform3D],       ## кузова
		"wheels": [] as Array[Transform3D],     ## колёса
		"neon": [] as Array[Dictionary],        ## линзы, фары, вывески, табло
		"puddles": [] as Array[Transform3D],    ## лужи на асфальте
		"lights": [] as Array[Dictionary],      ## настоящие источники света
		"boxes": [] as Array[Transform3D],      ## что должно быть твёрдым
	}


static func count(out: Dictionary) -> int:
	var total: int = 0
	for key: Variant in out.keys():
		var raw: Variant = out[key]
		if raw is Array:
			total += (raw as Array).size()
	return total


# ------------------------------------------------------------------ геометрия

## Трансформ коробки: поворот вокруг Y, затем масштаб по локальным осям.
## Basis.scaled() здесь не годится — она масштабирует в мировых осях и
## разваливает повёрнутые машины.
static func _box(pos: Vector3, box_size: Vector3, yaw: float) -> Transform3D:
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
	basis.x *= maxf(0.01, box_size.x)
	basis.y *= maxf(0.01, box_size.y)
	basis.z *= maxf(0.01, box_size.z)
	return Transform3D(basis, pos)


## Лежащий цилиндр (колесо): ось длины разворачивается в горизонталь.
static func _wheel(pos: Vector3, radius: float, wheel_width: float, yaw: float) -> Transform3D:
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)) * Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))
	basis.x *= radius * 2.0
	basis.y *= wheel_width
	basis.z *= radius * 2.0
	return Transform3D(basis, pos)


## Точка у дороги: [param along] — координата вдоль дороги от её начала,
## [param side] — -1 или 1 (какая обочина), [param offset] — расстояние
## от осевой линии поперёк.
static func _spot(r: Rect2, horizontal: bool, along: float, side: float, offset: float, y: float) -> Vector3:
	var center: Vector2 = r.get_center()
	if horizontal:
		return Vector3(r.position.x + along, y, center.y + side * offset)
	return Vector3(center.x + side * offset, y, r.position.y + along)


## Направление «к дороге» для предмета на обочине [param side].
static func _to_road(horizontal: bool, side: float) -> Vector3:
	return Vector3(0.0, 0.0, -side) if horizontal else Vector3(-side, 0.0, 0.0)


## Разворот предмета лицом к дороге: локальная -Z смотрит на асфальт.
static func _face_yaw(yaw: float, side: float) -> float:
	return yaw + (PI if side < 0.0 else 0.0)


# ------------------------------------------------------------------ раскладка

static func _dress_road(out: Dictionary, r: Rect2, y: float, horizontal: bool, length: float,
		width: float, arterial: bool, density: float, rng: RandomNumberGenerator, flags: Dictionary) -> void:
	var half: float = width * 0.5
	var yaw: float = 0.0 if horizontal else PI * 0.5
	var walk: float = half + WALK_CENTER          ## ось тротуара
	var park: float = maxf(half - PARK_INSET, half * 0.55)
	var step: float = lerpf(STEP_MAX, STEP_MIN, clampf(density, 0.0, 1.0))
	var from: float = END_CLEAR
	var to: float = length - END_CLEAR
	if to - from < step * 0.5:
		return

	# Светофоры: на углу тротуара, стрела вынесена над проезжей частью.
	# Ставим только там, где есть что регулировать — магистрали и широкие улицы.
	if arterial or width >= 10.0:
		for side: float in [-1.0, 1.0]:
			var at: float = from if side < 0.0 else to
			_traffic_light(out, _spot(r, horizontal, at, side, walk, y), horizontal, side, yaw)

	# Автобусная остановка: одна на длинный пролёт, всегда лицом к дороге.
	if length >= STOP_MIN_LEN:
		var stop_side: float = 1.0 if rng.randf() < 0.5 else -1.0
		var stop_at: float = clampf(length * 0.5 + rng.randf_range(-10.0, 10.0), from + 6.0, to - 6.0)
		_bus_stop(out, _spot(r, horizontal, stop_at, stop_side, walk + 0.7, y),
			_face_yaw(yaw, stop_side), rng, bool(flags.get("neon", true)))

	# Основной проход по обеим обочинам с шагом step. Разброс — только вдоль
	# дороги: поперёк предмет обязан остаться на оси тротуара.
	var cars_made: int = 0
	var along: float = from + step * 0.5
	while along < to:
		for side: float in [-1.0, 1.0]:
			var at: float = clampf(along + rng.randf_range(-2.0, 2.0), from, to)
			var base: Vector3 = _spot(r, horizontal, at, side, walk, y)
			var item_yaw: float = _face_yaw(yaw, side)
			var roll: float = rng.randf()
			if roll < 0.17:
				_bin(out, base, item_yaw, rng)
			elif roll < 0.31:
				_bench(out, base, item_yaw)
			elif roll < 0.41:
				_hydrant(out, base)
			elif roll < 0.53 and bool(flags.get("neon", true)):
				_kiosk(out, base, item_yaw, rng)
			elif roll < 0.62 and bool(flags.get("neon", true)):
				_phone_booth(out, base, item_yaw, rng)
			elif roll < 0.71:
				_news_box(out, base, item_yaw, rng)
			elif roll < 0.80 and bool(flags.get("neon", true)):
				_vending(out, base, item_yaw, rng)
			elif roll < 0.87:
				_mailbox(out, base, item_yaw)
			elif roll < 0.94 and bool(flags.get("debris", true)):
				_street_junk(out, base, horizontal, side, rng)
			else:
				_parking_meter(out, base)

			# Парковка: карман у кромки, только если улица достаточно широкая.
			if bool(flags.get("cars", true)) and cars_made < MAX_CARS and width >= MIN_PARK_WIDTH \
					and rng.randf() < 0.3 + 0.24 * density:
				var car_at: float = clampf(at + rng.randf_range(-3.5, 3.5), from + 3.0, to - 3.0)
				var car_pos: Vector3 = _spot(r, horizontal, car_at, side, park, y)
				# Правостороннее движение: сторона обочины однозначно задаёт,
				# куда смотрит нос машины. Случайного разворота больше нет.
				var flip: bool = (side < 0.0) if horizontal else (side > 0.0)
				_car(out, car_pos, yaw + (PI if flip else 0.0), rng)
				cars_made += 1

		# Лужи — единственное, что намеренно лежит на асфальте.
		if bool(flags.get("puddles", true)) and rng.randf() < 0.5:
			var puddle_at: float = clampf(along + rng.randf_range(-4.0, 4.0), 2.0, length - 2.0)
			var puddle_off: float = rng.randf_range(-half + 1.2, half - 1.2)
			var puddle_pos: Vector3 = _spot(r, horizontal, puddle_at, 1.0, puddle_off, y + 0.02)
			var radius: float = rng.randf_range(1.1, 3.4)
			(out["puddles"] as Array[Transform3D]).append(_box(puddle_pos, Vector3(radius * 2.0, 0.04, radius * 1.4), rng.randf() * TAU))

		along += step


static func _add_light(out: Dictionary, position: Vector3, color: Color, energy: float, light_range: float) -> void:
	var lights: Array[Dictionary] = out["lights"]
	if lights.size() >= MAX_LIGHTS:
		return
	lights.append({"position": position, "color": color, "energy": energy, "range": light_range})


static func _add_neon(out: Dictionary, xform: Transform3D, tint: Color, flicker: float) -> void:
	(out["neon"] as Array[Dictionary]).append({
		"transform": xform,
		"tint": tint,
		"custom": Color(flicker, 0.9, 0.0, 0.0),
	})


static func _neon_palette() -> Array[Color]:
	return [Color(1.0, 0.28, 0.55), Color(0.25, 0.95, 1.0), Color(1.0, 0.72, 0.2), Color(0.6, 0.35, 1.0)]


# ------------------------------------------------------------------ предметы

## Светофор: стойка на тротуаре, стрела над проезжей частью, голова с тремя
## линзами смотрит навстречу потоку своей стороны.
static func _traffic_light(out: Dictionary, base: Vector3, horizontal: bool, side: float, yaw: float) -> void:
	var height: float = 5.4
	var to_road: Vector3 = _to_road(horizontal, side)
	var reach: float = WALK_CENTER + 2.4
	(out["poles"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(0.18, height, 0.18), 0.0))

	var arm_center: Vector3 = base + Vector3(0.0, height, 0.0) + to_road * (reach * 0.5)
	var arm_size: Vector3 = Vector3(0.14, 0.14, reach) if horizontal else Vector3(reach, 0.14, 0.14)
	(out["metal"] as Array[Transform3D]).append(_box(arm_center, arm_size, 0.0))

	var head: Vector3 = base + Vector3(0.0, height - 0.7, 0.0) + to_road * reach
	var head_yaw: float = _face_yaw(yaw, side)
	(out["metal"] as Array[Transform3D]).append(_box(head, Vector3(0.44, 1.2, 0.34), head_yaw))
	var lens_colors: Array[Color] = [Color(1.0, 0.22, 0.2), Color(1.0, 0.78, 0.2), Color(0.25, 1.0, 0.45)]
	for i: int in range(3):
		# Линзы вынесены на переднюю грань корпуса — в сторону водителя.
		var lens: Vector3 = head + Vector3(0.0, 0.36 - float(i) * 0.36, 0.0) - to_road * 0.2
		_add_neon(out, _box(lens, Vector3(0.22, 0.22, 0.1), head_yaw), lens_colors[i], float(i) * 0.31)
	_add_light(out, head + Vector3(0.0, -0.5, 0.0), lens_colors[2], 1.3, 11.0)


## Автобусная остановка: козырёк на двух стойках, застеклённая задняя стенка,
## скамья и светящееся табло маршрутов. Открытая сторона — к дороге.
static func _bus_stop(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator, neon: bool) -> void:
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
	var along: Vector3 = basis.x       ## вдоль дороги
	var back: Vector3 = basis.z        ## от дороги, к домам
	var height: float = 2.7
	var span: float = 4.4

	# Крыша.
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height, 0.0) + back * 0.35, Vector3(span, 0.16, 1.9), yaw))
	# Две стойки по краям, с открытой стороны.
	for k: float in [-1.0, 1.0]:
		var leg: Vector3 = base + along * (span * 0.46 * k) - back * 0.45 + Vector3(0.0, height * 0.5, 0.0)
		(out["poles"] as Array[Transform3D]).append(_box(leg, Vector3(0.14, height, 0.14), 0.0))
	# Задняя стенка: рама и стекло.
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0) + back * 1.1, Vector3(span, height, 0.1), yaw))
	(out["glass"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.55, 0.0) + back * 1.04, Vector3(span - 0.5, height * 0.68, 0.06), yaw))
	# Скамья внутри.
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.46, 0.0) + back * 0.75, Vector3(span - 1.0, 0.12, 0.5), yaw))
	for k: float in [-1.0, 1.0]:
		var bench_leg: Vector3 = base + along * (span * 0.32 * k) + back * 0.75 + Vector3(0.0, 0.22, 0.0)
		(out["metal"] as Array[Transform3D]).append(_box(bench_leg, Vector3(0.1, 0.44, 0.44), yaw))
	# Табло маршрутов на торце, лицом к дороге.
	if neon:
		var palette: Array[Color] = _neon_palette()
		var tint: Color = palette[rng.randi_range(0, palette.size() - 1)]
		var board: Vector3 = base + along * (span * 0.46) - back * 0.4 + Vector3(0.0, height * 0.62, 0.0)
		_add_neon(out, _box(board, Vector3(0.1, 1.1, 0.75), yaw), tint, rng.randf())
		_add_light(out, base + Vector3(0.0, height - 0.25, 0.0), tint, 1.7, 11.0)

	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0) + back * 0.9, Vector3(span, height, 0.5), yaw))


static func _bin(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var height: float = rng.randf_range(0.9, 1.15)
	(out["rust"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(0.72, height, 0.72), yaw))
	(out["rust"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height + 0.06, 0.0), Vector3(0.82, 0.1, 0.82), yaw))
	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(0.72, height, 0.72), yaw))


## Скамья: спинкой к домам, сиденьем к дороге.
static func _bench(out: Dictionary, base: Vector3, yaw: float) -> void:
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.45, 0.0), Vector3(2.0, 0.12, 0.6), yaw))
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.85, 0.0) + basis.z * 0.28, Vector3(2.0, 0.5, 0.1), yaw))
	for k: float in [-0.8, 0.8]:
		var leg: Vector3 = base + Vector3(0.0, 0.22, 0.0) + basis.x * k
		(out["metal"] as Array[Transform3D]).append(_box(leg, Vector3(0.12, 0.45, 0.5), yaw))
	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.5, 0.0), Vector3(2.0, 1.0, 0.6), yaw))


static func _hydrant(out: Dictionary, base: Vector3) -> void:
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.35, 0.0), Vector3(0.28, 0.7, 0.28), 0.0))
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.74, 0.0), Vector3(0.36, 0.14, 0.36), 0.0))
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.5, 0.0), Vector3(0.6, 0.16, 0.16), 0.0))


## Киоск: витрина и вывеска — на сторону дороги (локальная -Z).
static func _kiosk(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var height: float = rng.randf_range(2.4, 2.9)
	var front: Vector3 = -Basis.from_euler(Vector3(0.0, yaw, 0.0)).z
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(2.6, height, 1.9), yaw))
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height + 0.12, 0.0), Vector3(3.0, 0.18, 2.3), yaw))
	(out["glass"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.6, 0.0) + front * 0.98, Vector3(2.0, height * 0.5, 0.08), yaw))
	var palette: Array[Color] = _neon_palette()
	var tint: Color = palette[rng.randi_range(0, palette.size() - 1)]
	_add_neon(out, _box(base + Vector3(0.0, height + 0.5, 0.0) + front * 0.6, Vector3(2.2, 0.55, 0.12), yaw), tint, rng.randf())
	_add_light(out, base + Vector3(0.0, height + 0.3, 0.0) + front * 1.2, tint, 2.1, 13.0)
	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(2.6, height, 1.9), yaw))


static func _phone_booth(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var height: float = 2.35
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(1.05, height, 1.05), yaw))
	(out["glass"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.55, 0.0), Vector3(0.92, height * 0.7, 0.92), yaw))
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height + 0.1, 0.0), Vector3(1.2, 0.16, 1.2), yaw))
	_add_neon(out, _box(base + Vector3(0.0, height - 0.15, 0.0), Vector3(1.0, 0.22, 1.0), yaw), Color(0.3, 0.9, 1.0), rng.randf())
	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(1.05, height, 1.05), yaw))


## Газетные автоматы: выстроены вдоль тротуара, стеклом к дороге.
static func _news_box(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
	var total: int = rng.randi_range(1, 3)
	for i: int in range(total):
		var pos: Vector3 = base + basis.x * (float(i) * 0.75 - float(total - 1) * 0.37)
		(out["metal"] as Array[Transform3D]).append(_box(pos + Vector3(0.0, 0.6, 0.0), Vector3(0.62, 1.2, 0.5), yaw))
		(out["glass"] as Array[Transform3D]).append(_box(pos + Vector3(0.0, 0.9, 0.0) - basis.z * 0.2, Vector3(0.5, 0.45, 0.16), yaw))


## Торговый автомат: подсвеченная витрина, всегда лицом к прохожему.
static func _vending(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var front: Vector3 = -Basis.from_euler(Vector3(0.0, yaw, 0.0)).z
	var height: float = 1.95
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(1.15, height, 0.78), yaw))
	var palette: Array[Color] = _neon_palette()
	var tint: Color = palette[rng.randi_range(0, palette.size() - 1)]
	_add_neon(out, _box(base + Vector3(0.0, height * 0.58, 0.0) + front * 0.42, Vector3(0.9, height * 0.6, 0.06), yaw), tint, rng.randf())
	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(1.15, height, 0.78), yaw))


static func _mailbox(out: Dictionary, base: Vector3, yaw: float) -> void:
	(out["poles"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.4, 0.0), Vector3(0.14, 0.8, 0.14), 0.0))
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 1.05, 0.0), Vector3(0.68, 0.62, 0.5), yaw))
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 1.4, 0.0), Vector3(0.74, 0.1, 0.56), yaw))


## Мусор: разлетается только вдоль тротуара, на асфальт не выходит.
static func _street_junk(out: Dictionary, base: Vector3, horizontal: bool, side: float, rng: RandomNumberGenerator) -> void:
	var along: Vector3 = Vector3(1.0, 0.0, 0.0) if horizontal else Vector3(0.0, 0.0, 1.0)
	var inward: Vector3 = -_to_road(horizontal, side)
	var total: int = rng.randi_range(2, 5)
	for i: int in range(total):
		var offset: Vector3 = along * rng.randf_range(-1.0, 1.0) + inward * rng.randf_range(0.0, 0.7)
		var edge: float = rng.randf_range(0.35, 0.7)
		(out["cardboard"] as Array[Transform3D]).append(_box(
			base + offset + Vector3(0.0, edge * 0.5, 0.0),
			Vector3(edge, edge, edge * rng.randf_range(0.7, 1.3)),
			rng.randf_range(-PI, PI)
		))


static func _parking_meter(out: Dictionary, base: Vector3) -> void:
	(out["poles"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.55, 0.0), Vector3(0.12, 1.1, 0.12), 0.0))
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 1.24, 0.0), Vector3(0.3, 0.42, 0.22), 0.0))


## Припаркованная машина: кузов, кабина-стекло, четыре колеса, фары и стопы.
## [param turn] задаётся стороной обочины, поэтому машины стоят в ряд по
## направлению движения, а не носом в бордюр.
static func _car(out: Dictionary, base: Vector3, turn: float, rng: RandomNumberGenerator) -> void:
	var body_length: float = rng.randf_range(4.1, 5.2)
	var body_width: float = rng.randf_range(1.75, 2.05)
	var body_height: float = rng.randf_range(0.85, 1.05)
	var yaw: float = turn + rng.randf_range(-0.035, 0.035)
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
	var forward: Vector3 = basis.x
	var right: Vector3 = basis.z
	var floor_y: float = base.y + 0.42

	(out["cars"] as Array[Transform3D]).append(_box(Vector3(base.x, floor_y + body_height * 0.5, base.z), Vector3(body_length, body_height, body_width), yaw))
	(out["glass"] as Array[Transform3D]).append(_box(
		Vector3(base.x, floor_y + body_height + 0.32, base.z) - forward * body_length * 0.06,
		Vector3(body_length * 0.46, 0.66, body_width * 0.86), yaw))

	for fx: float in [0.32, -0.32]:
		for rx: float in [0.42, -0.42]:
			var wheel_pos: Vector3 = Vector3(base.x, base.y + 0.34, base.z) + forward * (body_length * fx) + right * (body_width * rx)
			(out["wheels"] as Array[Transform3D]).append(_wheel(wheel_pos, 0.34, 0.24, yaw))

	var head_tint := Color(1.0, 0.95, 0.82)
	var tail_tint := Color(1.0, 0.22, 0.18)
	for rx: float in [0.3, -0.3]:
		var head_pos: Vector3 = Vector3(base.x, floor_y + body_height * 0.55, base.z) + forward * (body_length * 0.49) + right * (body_width * rx)
		_add_neon(out, _box(head_pos, Vector3(0.1, 0.2, 0.42), yaw), head_tint, rng.randf())
		var tail_pos: Vector3 = Vector3(base.x, floor_y + body_height * 0.6, base.z) - forward * (body_length * 0.49) + right * (body_width * rx)
		_add_neon(out, _box(tail_pos, Vector3(0.08, 0.16, 0.38), yaw), tail_tint, rng.randf())

	(out["boxes"] as Array[Transform3D]).append(_box(Vector3(base.x, floor_y + body_height * 0.5, base.z), Vector3(body_length, body_height + 0.7, body_width), yaw))
