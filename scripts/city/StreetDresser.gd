class_name NoirStreetDresser
extends RefCounted
## Наполнение улиц. Пустая мостовая между домами — главная причина ощущения
## «скучно, ничего нет», поэтому здесь генерируется вся уличная мелочь:
## светофоры, урны, скамьи, гидранты, киоски с неоном, телефонные будки,
## ограждения, припаркованные машины, лужи и разметка переходов.
##
## Возвращаются не узлы, а пачки трансформов, сгруппированные по материалу:
## чанк сливает каждую пачку в один MultiMesh и не теряет бюджет вызовов.

const INSET := 1.7          ## отступ от кромки дороги до реквизита
const STEP_MIN := 8.0
const STEP_MAX := 19.0
const MAX_ITEMS := 460
const MAX_CARS := 22
const MAX_LIGHTS := 4
const MIN_ROAD := 12.0      ## короткие куски дороги не обставляем


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
		if length < MIN_ROAD or width < 5.0:
			continue

		_dress_road(out, r, float(road.get("y", 0.0)), horizontal, length, width,
			bool(road.get("arterial", false)), density, rng, flags)

		if count(out) >= limit:
			break

	return out


static func _empty() -> Dictionary:
	return {
		"concrete": [] as Array[Transform3D],   ## бордюры, скамьи, тумбы, разметка
		"metal": [] as Array[Transform3D],      ## корпуса светофоров, щитки, ящики
		"poles": [] as Array[Transform3D],      ## круглые стойки (цилиндр)
		"rust": [] as Array[Transform3D],       ## урны, контейнеры, решётки
		"cardboard": [] as Array[Transform3D],  ## ящики и кипы газет
		"glass": [] as Array[Transform3D],      ## витрины будок и стёкла машин
		"cars": [] as Array[Transform3D],       ## кузова
		"wheels": [] as Array[Transform3D],     ## колёса (цилиндр)
		"neon": [] as Array[Dictionary],        ## светящееся: линзы, фары, вывески
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


## Точка на тротуаре: [param along] — координата вдоль дороги,
## [param side] — -1 или 1 (какая обочина).
static func _spot(r: Rect2, horizontal: bool, along: float, side: float, offset: float, y: float) -> Vector3:
	var center: Vector2 = r.get_center()
	if horizontal:
		return Vector3(r.position.x + along, y, center.y + side * offset)
	return Vector3(center.x + side * offset, y, r.position.y + along)


# ------------------------------------------------------------------ раскладка

static func _dress_road(out: Dictionary, r: Rect2, y: float, horizontal: bool, length: float,
		width: float, arterial: bool, density: float, rng: RandomNumberGenerator, flags: Dictionary) -> void:
	var curb: float = maxf(1.2, width * 0.5 - INSET)
	var yaw: float = 0.0 if horizontal else PI * 0.5
	var step: float = lerpf(STEP_MAX, STEP_MIN, clampf(density, 0.0, 1.0))

	# Бордюры по обеим сторонам: узкая полоса, которая отделяет асфальт от
	# домов и сразу убирает ощущение «дома стоят в поле».
	for side: float in [-1.0, 1.0]:
		var curb_pos: Vector3 = _spot(r, horizontal, length * 0.5, side, width * 0.5 - 0.35, y + 0.09)
		var curb_size: Vector3 = Vector3(length, 0.18, 0.7) if horizontal else Vector3(0.7, 0.18, length)
		(out["concrete"] as Array[Transform3D]).append(_box(curb_pos, curb_size, 0.0))

	# Разметка: пунктир по центру обычных улиц, двойная полоса на магистралях.
	var stripe_step: float = 7.0
	var stripe: float = 3.0
	while stripe < length - 3.0:
		if arterial:
			for lane: float in [-0.35, 0.35]:
				var lane_pos: Vector3 = _spot(r, horizontal, stripe, lane, 1.0, y + 0.03)
				var lane_size: Vector3 = Vector3(4.2, 0.06, 0.22) if horizontal else Vector3(0.22, 0.06, 4.2)
				(out["concrete"] as Array[Transform3D]).append(_box(lane_pos, lane_size, 0.0))
		else:
			var dash_pos: Vector3 = _spot(r, horizontal, stripe, 0.0, 0.0, y + 0.03)
			var dash_size: Vector3 = Vector3(3.4, 0.06, 0.2) if horizontal else Vector3(0.2, 0.06, 3.4)
			(out["concrete"] as Array[Transform3D]).append(_box(dash_pos, dash_size, 0.0))
		stripe += stripe_step

	# Пешеходный переход у начала квартала.
	var zebra_at: float = 6.0
	var bar: int = 0
	while bar < 7:
		var bar_pos: Vector3 = _spot(r, horizontal, zebra_at + float(bar) * 0.9, 0.0, 0.0, y + 0.035)
		var bar_size: Vector3 = Vector3(0.45, 0.07, width - 1.4) if horizontal else Vector3(width - 1.4, 0.07, 0.45)
		(out["concrete"] as Array[Transform3D]).append(_box(bar_pos, bar_size, 0.0))
		bar += 1

	# Светофоры на въезде в квартал — по одному на каждую сторону.
	for side: float in [-1.0, 1.0]:
		var at: float = 4.0 if side < 0.0 else length - 4.0
		_traffic_light(out, _spot(r, horizontal, at, side, curb, y), yaw, side)

	# Основной проход: реквизит вдоль обеих обочин с шагом step.
	var cars_made: int = 0
	var along: float = step * 0.6
	while along < length - 4.0:
		for side: float in [-1.0, 1.0]:
			var jitter: float = rng.randf_range(-1.6, 1.6)
			var base: Vector3 = _spot(r, horizontal, clampf(along + jitter, 2.0, length - 2.0), side, curb, y)
			var roll: float = rng.randf()
			if roll < 0.16:
				_bin(out, base, yaw, rng)
			elif roll < 0.29:
				_bench(out, base, yaw)
			elif roll < 0.38:
				_hydrant(out, base)
			elif roll < 0.47:
				_bollards(out, r, horizontal, along, side, curb, y, rng)
			elif roll < 0.57 and bool(flags.get("neon", true)):
				_kiosk(out, base, yaw, rng)
			elif roll < 0.65 and bool(flags.get("neon", true)):
				_phone_booth(out, base, yaw, rng)
			elif roll < 0.73:
				_news_box(out, base, yaw, rng)
			elif roll < 0.80:
				_planter(out, base, yaw)
			elif roll < 0.86 and bool(flags.get("debris", true)):
				_street_junk(out, base, yaw, rng)
			elif roll < 0.92:
				_grate(out, base, yaw)
			else:
				_parking_meter(out, base)

			# Машины у самой кромки асфальта.
			if bool(flags.get("cars", true)) and cars_made < MAX_CARS and rng.randf() < 0.34 + 0.22 * density:
				var car_at: float = clampf(along + rng.randf_range(-3.0, 3.0), 4.0, length - 5.0)
				var car_pos: Vector3 = _spot(r, horizontal, car_at, side, maxf(1.4, curb - 2.4), y)
				_car(out, car_pos, yaw, rng)
				cars_made += 1

		if bool(flags.get("puddles", true)) and rng.randf() < 0.5:
			var puddle_pos: Vector3 = _spot(r, horizontal, clampf(along + rng.randf_range(-4.0, 4.0), 2.0, length - 2.0),
				rng.randf_range(-0.6, 0.6), width * 0.35, y + 0.02)
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


# ------------------------------------------------------------------ предметы

static func _traffic_light(out: Dictionary, base: Vector3, yaw: float, side: float) -> void:
	var height: float = 5.2
	(out["poles"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(0.18, height, 0.18), 0.0))
	# Вынос над проезжей частью.
	var arm_dir: Vector3 = Vector3(0.0, 0.0, -side) if is_zero_approx(yaw) else Vector3(-side, 0.0, 0.0)
	var arm_center: Vector3 = base + Vector3(0.0, height, 0.0) + arm_dir * 1.5
	var arm_size: Vector3 = Vector3(0.14, 0.14, 3.0) if is_zero_approx(yaw) else Vector3(3.0, 0.14, 0.14)
	(out["metal"] as Array[Transform3D]).append(_box(arm_center, arm_size, 0.0))

	var head: Vector3 = base + Vector3(0.0, height - 0.6, 0.0) + arm_dir * 2.8
	(out["metal"] as Array[Transform3D]).append(_box(head, Vector3(0.42, 1.15, 0.34), yaw))
	var lens_colors: Array[Color] = [Color(1.0, 0.22, 0.2), Color(1.0, 0.78, 0.2), Color(0.25, 1.0, 0.45)]
	for i: int in range(3):
		var lens: Vector3 = head + Vector3(0.0, 0.36 - float(i) * 0.36, 0.0) + arm_dir * -0.2
		_add_neon(out, _box(lens, Vector3(0.22, 0.22, 0.1), yaw), lens_colors[i], float(i) * 0.31)
	_add_light(out, head + Vector3(0.0, -0.4, 0.0), lens_colors[2], 1.3, 11.0)


static func _bin(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var height: float = rng.randf_range(0.9, 1.15)
	(out["rust"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(0.72, height, 0.72), yaw))
	(out["rust"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height + 0.06, 0.0), Vector3(0.82, 0.1, 0.82), yaw))
	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(0.72, height, 0.72), yaw))


static func _bench(out: Dictionary, base: Vector3, yaw: float) -> void:
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.45, 0.0), Vector3(2.0, 0.12, 0.6), yaw))
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.85, 0.0), Vector3(2.0, 0.5, 0.1), yaw))
	for k: float in [-0.8, 0.8]:
		var leg: Vector3 = base + Vector3(0.0, 0.22, 0.0) + Basis.from_euler(Vector3(0.0, yaw, 0.0)).x * k
		(out["metal"] as Array[Transform3D]).append(_box(leg, Vector3(0.12, 0.45, 0.5), yaw))
	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.5, 0.0), Vector3(2.0, 1.0, 0.6), yaw))


static func _hydrant(out: Dictionary, base: Vector3) -> void:
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.35, 0.0), Vector3(0.28, 0.7, 0.28), 0.0))
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.74, 0.0), Vector3(0.36, 0.14, 0.36), 0.0))
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.5, 0.0), Vector3(0.6, 0.16, 0.16), 0.0))


static func _bollards(out: Dictionary, r: Rect2, horizontal: bool, along: float, side: float,
		curb: float, y: float, rng: RandomNumberGenerator) -> void:
	var total: int = rng.randi_range(3, 6)
	for i: int in range(total):
		var at: float = along + float(i) * 1.7
		var pos: Vector3 = _spot(r, horizontal, at, side, curb, y)
		(out["poles"] as Array[Transform3D]).append(_box(pos + Vector3(0.0, 0.45, 0.0), Vector3(0.16, 0.9, 0.16), 0.0))


static func _kiosk(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var height: float = rng.randf_range(2.4, 2.9)
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(2.6, height, 1.9), yaw))
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height + 0.12, 0.0), Vector3(3.0, 0.18, 2.3), yaw))
	var facing: Vector3 = Basis.from_euler(Vector3(0.0, yaw, 0.0)).z
	# Витрина и вывеска смотрят на улицу.
	(out["glass"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.6, 0.0) - facing * 0.98, Vector3(2.0, height * 0.5, 0.08), yaw))
	var palette: Array[Color] = [Color(1.0, 0.28, 0.55), Color(0.25, 0.95, 1.0), Color(1.0, 0.72, 0.2), Color(0.6, 0.35, 1.0)]
	var tint: Color = palette[rng.randi_range(0, palette.size() - 1)]
	_add_neon(out, _box(base + Vector3(0.0, height + 0.5, 0.0) - facing * 0.6, Vector3(2.2, 0.55, 0.12), yaw), tint, rng.randf())
	_add_light(out, base + Vector3(0.0, height + 0.3, 0.0) - facing * 1.2, tint, 2.1, 13.0)
	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(2.6, height, 1.9), yaw))


static func _phone_booth(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var height: float = 2.35
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(1.05, height, 1.05), yaw))
	(out["glass"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.55, 0.0), Vector3(0.92, height * 0.7, 0.92), yaw))
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height + 0.1, 0.0), Vector3(1.2, 0.16, 1.2), yaw))
	var tint := Color(0.3, 0.9, 1.0)
	_add_neon(out, _box(base + Vector3(0.0, height - 0.15, 0.0), Vector3(1.0, 0.22, 1.0), yaw), tint, rng.randf())
	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, height * 0.5, 0.0), Vector3(1.05, height, 1.05), yaw))


static func _news_box(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var total: int = rng.randi_range(1, 3)
	var dir: Vector3 = Basis.from_euler(Vector3(0.0, yaw, 0.0)).x
	for i: int in range(total):
		var pos: Vector3 = base + dir * (float(i) * 0.75)
		(out["metal"] as Array[Transform3D]).append(_box(pos + Vector3(0.0, 0.6, 0.0), Vector3(0.62, 1.2, 0.5), yaw))
		(out["glass"] as Array[Transform3D]).append(_box(pos + Vector3(0.0, 0.9, 0.0), Vector3(0.5, 0.45, 0.55), yaw))


static func _planter(out: Dictionary, base: Vector3, yaw: float) -> void:
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.32, 0.0), Vector3(1.3, 0.64, 1.3), yaw))
	(out["concrete"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.68, 0.0), Vector3(1.05, 0.12, 1.05), yaw))
	(out["poles"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 1.7, 0.0), Vector3(0.16, 2.1, 0.16), 0.0))
	(out["boxes"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.32, 0.0), Vector3(1.3, 0.64, 1.3), yaw))


static func _street_junk(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var total: int = rng.randi_range(2, 5)
	for i: int in range(total):
		var offset := Vector3(rng.randf_range(-0.9, 0.9), 0.0, rng.randf_range(-0.7, 0.7))
		var edge: float = rng.randf_range(0.35, 0.7)
		(out["cardboard"] as Array[Transform3D]).append(_box(
			base + offset + Vector3(0.0, edge * 0.5, 0.0),
			Vector3(edge, edge, edge * rng.randf_range(0.7, 1.3)),
			yaw + rng.randf_range(-0.6, 0.6)
		))


static func _grate(out: Dictionary, base: Vector3, yaw: float) -> void:
	(out["rust"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.04, 0.0), Vector3(1.1, 0.08, 0.8), yaw))
	for i: int in range(4):
		(out["rust"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.1, 0.0) + Basis.from_euler(Vector3(0.0, yaw, 0.0)).x * (-0.4 + float(i) * 0.26), Vector3(0.08, 0.06, 0.7), yaw))


static func _parking_meter(out: Dictionary, base: Vector3) -> void:
	(out["poles"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 0.55, 0.0), Vector3(0.12, 1.1, 0.12), 0.0))
	(out["metal"] as Array[Transform3D]).append(_box(base + Vector3(0.0, 1.24, 0.0), Vector3(0.3, 0.42, 0.22), 0.0))


## Припаркованная машина: кузов, кабина-стекло, четыре колеса, фары и стопы.
static func _car(out: Dictionary, base: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var body_length: float = rng.randf_range(4.1, 5.2)
	var body_width: float = rng.randf_range(1.75, 2.05)
	var body_height: float = rng.randf_range(0.85, 1.05)
	var turn: float = yaw + (PI if rng.randf() < 0.5 else 0.0) + rng.randf_range(-0.05, 0.05)
	var basis := Basis.from_euler(Vector3(0.0, turn, 0.0))
	var forward: Vector3 = basis.x
	var right: Vector3 = basis.z
	var floor_y: float = base.y + 0.42

	(out["cars"] as Array[Transform3D]).append(_box(Vector3(base.x, floor_y + body_height * 0.5, base.z), Vector3(body_length, body_height, body_width), turn))
	# Кабина: чуть назад и уже кузова.
	(out["glass"] as Array[Transform3D]).append(_box(
		Vector3(base.x, floor_y + body_height + 0.32, base.z) - forward * body_length * 0.06,
		Vector3(body_length * 0.46, 0.66, body_width * 0.86), turn))

	for fx: float in [0.32, -0.32]:
		for rx: float in [0.42, -0.42]:
			var wheel_pos: Vector3 = Vector3(base.x, base.y + 0.34, base.z) + forward * (body_length * fx) + right * (body_width * rx)
			(out["wheels"] as Array[Transform3D]).append(_wheel(wheel_pos, 0.34, 0.24, turn))

	var head_tint := Color(1.0, 0.95, 0.82)
	var tail_tint := Color(1.0, 0.22, 0.18)
	for rx: float in [0.3, -0.3]:
		var head_pos: Vector3 = Vector3(base.x, floor_y + body_height * 0.55, base.z) + forward * (body_length * 0.49) + right * (body_width * rx)
		_add_neon(out, _box(head_pos, Vector3(0.1, 0.2, 0.42), turn), head_tint, rng.randf())
		var tail_pos: Vector3 = Vector3(base.x, floor_y + body_height * 0.6, base.z) - forward * (body_length * 0.49) + right * (body_width * rx)
		_add_neon(out, _box(tail_pos, Vector3(0.08, 0.16, 0.38), turn), tail_tint, rng.randf())

	(out["boxes"] as Array[Transform3D]).append(_box(Vector3(base.x, floor_y + body_height * 0.5, base.z), Vector3(body_length, body_height + 0.7, body_width), turn))
