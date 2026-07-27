class_name NoirSidewalkBuilder
extends RefCounted
## Геометрия улицы: тротуары, бордюры, разметка, пешеходные переходы
## и мелкое наполнение тротуаров.
##
## Ответственность модуля сознательно отделена от [NoirStreetDresser]:
## тот ставит реквизит (урны, киоски, машины), а здесь живёт само
## дорожное полотно как архитектурный объект. Разделение важно для
## производительности: тротуары и разметка нужны и на средней дистанции
## (без них город выглядит пустым), а киоски и урны — только вблизи.
##
## Всё выдаётся как осевые боксы в мировых координатах, чтобы чанк мог
## слить их в несколько MultiMesh.

const SIDEWALK_WIDTH := 3.4        ## ширина тротуара
const SIDEWALK_HEIGHT := 0.18      ## выступ над асфальтом
const CURB_WIDTH := 0.35
const SLAB_LEN := 6.0              ## длина одной плиты тротуара
const PAINT_HEIGHT := 0.02
const LANE_DASH_LEN := 2.6
const LANE_GAP_LEN := 3.4
const CROSSWALK_STRIPES := 7
const MIN_ROAD_LEN := 10.0
const MIN_ROAD_WIDTH := 6.0
const MAX_SLABS := 900
const MAX_PAINT := 700
const MAX_PROPS := 320
const MAX_SIGNS := 90
const MAX_LIGHTS := 3


## Настройки по умолчанию. [code]center_boost[/code] докручивает насыщенность
## центральных районов: там у игрока всегда больше времени смотреть по сторонам.
static func defaults() -> Dictionary:
	return {
		"density": 1.0,
		"sidewalks": true,
		"markings": true,
		"crosswalks": true,
		"props": true,
		"signs": true,
		"center_boost": 1.0,
		"max_slabs": MAX_SLABS,
		"max_paint": MAX_PAINT,
		"max_props": MAX_PROPS,
	}


static func empty_result() -> Dictionary:
	return {
		"slabs": [] as Array[Transform3D],
		"curbs": [] as Array[Transform3D],
		"paint": [] as Array[Transform3D],
		"metal": [] as Array[Transform3D],
		"poles": [] as Array[Transform3D],
		"props": [] as Array[Transform3D],
		"signs": [] as Array[Dictionary],
		"boxes": [] as Array[Transform3D],
		"lights": [] as Array[Dictionary],
	}


static func count(result: Dictionary) -> int:
	var total: int = 0
	for key: Variant in result.keys():
		var raw: Variant = result[key]
		if raw is Array:
			total += (raw as Array).size()
	return total


## Осевой бокс без поворота. Вся уличная геометрия выровнена по сетке,
## поэтому повороты здесь не нужны.
static func _box(center: Vector3, box_size: Vector3) -> Transform3D:
	return Transform3D(Basis.IDENTITY.scaled(box_size), center)


## Главная точка входа.
##
## [param roads] — список словарей с ключами [code]rect[/code], [code]y[/code],
## [code]arterial[/code] — тот же формат, что у [NoirBuildingFactory].
static func generate(roads: Array, city_seed: int, coords: Vector2i, cfg: Dictionary) -> Dictionary:
	var out: Dictionary = empty_result()
	if roads.is_empty():
		return out

	var density: float = clampf(float(cfg.get("density", 1.0)), 0.0, 1.5)
	if density <= 0.02:
		return out

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(city_seed, coords.x, coords.y))

	var max_slabs: int = maxi(30, int(cfg.get("max_slabs", MAX_SLABS)))
	var max_paint: int = maxi(20, int(cfg.get("max_paint", MAX_PAINT)))
	var max_props: int = maxi(10, int(cfg.get("max_props", MAX_PROPS)))

	for entry: Variant in roads:
		if not (entry is Dictionary):
			continue
		var road: Dictionary = entry as Dictionary
		var raw_rect: Variant = road.get("rect", null)
		if not (raw_rect is Rect2):
			continue
		var r: Rect2 = raw_rect as Rect2
		if r.size.x <= 0.5 or r.size.y <= 0.5:
			continue

		var y: float = float(road.get("y", 0.0))
		var arterial: bool = bool(road.get("arterial", false))
		var horizontal: bool = r.size.x >= r.size.y
		var length: float = r.size.x if horizontal else r.size.y
		var width: float = r.size.y if horizontal else r.size.x
		if length < MIN_ROAD_LEN or width < MIN_ROAD_WIDTH:
			continue

		# Насыщенность квартала: в центре и деловых районах тротуары шире,
		# вывесок и реквизита больше, а на окраинах всё разреженнее.
		var center2 := r.get_center()
		var local_boost: float = _district_boost(Vector3(center2.x, y, center2.y), cfg)

		if bool(cfg.get("sidewalks", true)):
			_edge_walks(out, r, y, horizontal, local_boost, max_slabs)
		if bool(cfg.get("markings", true)):
			_lane_paint(out, r, y, horizontal, arterial, width, max_paint)
		if bool(cfg.get("crosswalks", true)) and (arterial or local_boost >= 1.1):
			_crosswalks(out, r, y, horizontal, width, max_paint)
		if bool(cfg.get("props", true)):
			_walk_props(out, r, y, horizontal, density * local_boost, rng, max_props)
		if bool(cfg.get("signs", true)) and local_boost >= 1.0:
			_shop_fronts(out, r, y, horizontal, density * local_boost, rng)

	return out


## Коэффициент насыщенности по району. Любая ошибка атласа не должна
## ронять генерацию улицы, поэтому всё через проверки.
static func _district_boost(world_pos: Vector3, cfg: Dictionary) -> float:
	var base: float = clampf(float(cfg.get("center_boost", 1.0)), 0.5, 2.0)
	if CityAtlas == null or not CityAtlas.has_method("district_at_world"):
		return base

	var district: Variant = CityAtlas.district_at_world(world_pos)
	if not (district is Dictionary):
		return base

	var data: Dictionary = district as Dictionary
	var profile: String = str(data.get("profile", ""))
	var factor: float = 1.0
	match profile:
		"core":
			factor = 1.55
		"financial":
			factor = 1.4
		"entertainment":
			factor = 1.45
		"commercial":
			factor = 1.25
		"oldtown":
			factor = 1.15
		"waterfront", "harbor":
			factor = 1.0
		"residential":
			factor = 0.9
		"industrial":
			factor = 0.8
		"slum":
			factor = 0.85
		"outskirts":
			factor = 0.6
		_:
			factor = 1.0
	return clampf(base * factor, 0.4, 2.2)


## Тротуары и бордюры по обеим сторонам проезжей части.
## Плиты режутся на сегменты: так видны швы, и тротуар не выглядит
## бесконечной серой лентой.
static func _edge_walks(out: Dictionary, r: Rect2, y: float, horizontal: bool, boost: float, max_slabs: int) -> void:
	var slabs: Array[Transform3D] = out["slabs"]
	var curbs: Array[Transform3D] = out["curbs"]
	if slabs.size() >= max_slabs:
		return

	var walk_w: float = clampf(SIDEWALK_WIDTH * clampf(boost, 0.7, 1.5), 2.2, 5.2)
	var length: float = r.size.x if horizontal else r.size.y
	var segments: int = maxi(1, int(round(length / SLAB_LEN)))
	var seg_len: float = length / float(segments)
	var top: float = y + SIDEWALK_HEIGHT * 0.5

	for side: int in [-1, 1]:
		for i: int in range(segments):
			if slabs.size() >= max_slabs:
				return
			var along: float = (float(i) + 0.5) * seg_len
			var slab_center: Vector3
			var slab_size: Vector3
			var curb_center: Vector3
			var curb_size: Vector3

			if horizontal:
				var edge_z: float = r.position.y if side < 0 else r.end.y
				var offset_z: float = edge_z + float(side) * walk_w * 0.5
				slab_center = Vector3(r.position.x + along, top, offset_z)
				slab_size = Vector3(seg_len * 0.985, SIDEWALK_HEIGHT, walk_w * 0.97)
				curb_center = Vector3(r.position.x + along, y + SIDEWALK_HEIGHT * 0.75, edge_z)
				curb_size = Vector3(seg_len * 0.99, SIDEWALK_HEIGHT * 1.5, CURB_WIDTH)
			else:
				var edge_x: float = r.position.x if side < 0 else r.end.x
				var offset_x: float = edge_x + float(side) * walk_w * 0.5
				slab_center = Vector3(offset_x, top, r.position.y + along)
				slab_size = Vector3(walk_w * 0.97, SIDEWALK_HEIGHT, seg_len * 0.985)
				curb_center = Vector3(edge_x, y + SIDEWALK_HEIGHT * 0.75, r.position.y + along)
				curb_size = Vector3(CURB_WIDTH, SIDEWALK_HEIGHT * 1.5, seg_len * 0.99)

			slabs.append(_box(slab_center, slab_size))
			if i % 2 == 0:
				curbs.append(_box(curb_center, curb_size))


## Разметка: прерывистая осевая и сплошные краевые линии.
static func _lane_paint(out: Dictionary, r: Rect2, y: float, horizontal: bool, arterial: bool, width: float, max_paint: int) -> void:
	var paint: Array[Transform3D] = out["paint"]
	if paint.size() >= max_paint:
		return

	var length: float = r.size.x if horizontal else r.size.y
	var paint_y: float = y + PAINT_HEIGHT
	var center2 := r.get_center()
	var step: float = LANE_DASH_LEN + LANE_GAP_LEN
	var dashes: int = maxi(1, int(length / step))
	var line_w: float = 0.16

	# Осевая. На магистралях двойная, на обычной улице одинарная прерывистая.
	var center_lines: Array[float] = [0.0]
	if arterial:
		center_lines = [-0.22, 0.22]

	for lane_offset: float in center_lines:
		for i: int in range(dashes):
			if paint.size() >= max_paint:
				return
			var along: float = (float(i) + 0.5) * step
			if horizontal:
				paint.append(_box(
					Vector3(r.position.x + along, paint_y, center2.y + lane_offset),
					Vector3(LANE_DASH_LEN, PAINT_HEIGHT, line_w)
				))
			else:
				paint.append(_box(
					Vector3(center2.x + lane_offset, paint_y, r.position.y + along),
					Vector3(line_w, PAINT_HEIGHT, LANE_DASH_LEN)
				))

	# Краевые линии — сплошные, одним длинным боксом на сторону.
	var inset: float = clampf(width * 0.5 - 0.9, 1.0, width * 0.5)
	for side: int in [-1, 1]:
		if paint.size() >= max_paint:
			return
		if horizontal:
			paint.append(_box(
				Vector3(center2.x, paint_y, center2.y + float(side) * inset),
				Vector3(length * 0.98, PAINT_HEIGHT, line_w)
			))
		else:
			paint.append(_box(
				Vector3(center2.x + float(side) * inset, paint_y, center2.y),
				Vector3(line_w, PAINT_HEIGHT, length * 0.98)
			))


## Пешеходные переходы на концах квартала плюс стоп-линия.
static func _crosswalks(out: Dictionary, r: Rect2, y: float, horizontal: bool, width: float, max_paint: int) -> void:
	var paint: Array[Transform3D] = out["paint"]
	var paint_y: float = y + PAINT_HEIGHT * 1.5
	var length: float = r.size.x if horizontal else r.size.y
	var band: float = clampf(width * 0.75, 4.0, 9.0)
	var stripe_w: float = 0.55
	var stripe_step: float = band / float(CROSSWALK_STRIPES)
	var center2 := r.get_center()

	for end_index: int in [0, 1]:
		var along: float = 4.5 if end_index == 0 else length - 4.5
		if along <= 1.0 or along >= length - 1.0:
			continue
		for s: int in range(CROSSWALK_STRIPES):
			if paint.size() >= max_paint:
				return
			var lateral: float = -band * 0.5 + (float(s) + 0.5) * stripe_step
			if horizontal:
				paint.append(_box(
					Vector3(r.position.x + along, paint_y, center2.y + lateral),
					Vector3(2.6, PAINT_HEIGHT, stripe_w)
				))
			else:
				paint.append(_box(
					Vector3(center2.x + lateral, paint_y, r.position.y + along),
					Vector3(stripe_w, PAINT_HEIGHT, 2.6)
				))

		# Стоп-линия чуть дальше перехода.
		if paint.size() >= max_paint:
			return
		var stop_along: float = along + (2.6 if end_index == 0 else -2.6)
		if horizontal:
			paint.append(_box(
				Vector3(r.position.x + stop_along, paint_y, center2.y),
				Vector3(0.4, PAINT_HEIGHT, band)
			))
		else:
			paint.append(_box(
				Vector3(center2.x, paint_y, r.position.y + stop_along),
				Vector3(band, PAINT_HEIGHT, 0.4)
			))


## Наполнение тротуара: люки, решётки метро, столбики, вазоны, шкафы,
## велопарковки и указатели. Шаг зависит от плотности: в центре гуще.
static func _walk_props(out: Dictionary, r: Rect2, y: float, horizontal: bool, density: float, rng: RandomNumberGenerator, max_props: int) -> void:
	var props: Array[Transform3D] = out["props"]
	var metal: Array[Transform3D] = out["metal"]
	var poles: Array[Transform3D] = out["poles"]
	var boxes: Array[Transform3D] = out["boxes"]
	if props.size() >= max_props:
		return

	var length: float = r.size.x if horizontal else r.size.y
	var walk_w: float = SIDEWALK_WIDTH
	var step: float = clampf(16.0 / maxf(0.25, density), 6.0, 34.0)
	var slots: int = maxi(1, int(length / step))
	var base_y: float = y + SIDEWALK_HEIGHT
	var center2 := r.get_center()

	for i: int in range(slots):
		if props.size() >= max_props:
			return
		var along: float = (float(i) + rng.randf_range(0.25, 0.75)) * step
		if along <= 2.0 or along >= length - 2.0:
			continue
		var side: int = 1 if rng.randf() > 0.5 else -1

		var pos: Vector3
		if horizontal:
			var edge_z: float = r.position.y if side < 0 else r.end.y
			pos = Vector3(r.position.x + along, base_y, edge_z + float(side) * walk_w * rng.randf_range(0.35, 0.75))
		else:
			var edge_x: float = r.position.x if side < 0 else r.end.x
			pos = Vector3(edge_x + float(side) * walk_w * rng.randf_range(0.35, 0.75), base_y, r.position.y + along)

		var kind: int = rng.randi_range(0, 6)
		match kind:
			0:
				# Люк: плоский квадрат в асфальте, ближе к центру дороги.
				var hole: Vector3 = pos
				if horizontal:
					hole = Vector3(pos.x, y + 0.03, lerpf(pos.z, center2.y, 0.55))
				else:
					hole = Vector3(lerpf(pos.x, center2.x, 0.55), y + 0.03, pos.z)
				metal.append(_box(hole, Vector3(0.92, 0.06, 0.92)))
			1:
				# Решётка вентиляции метро.
				metal.append(_box(pos + Vector3(0.0, 0.02, 0.0), Vector3(1.9, 0.08, 1.2)))
			2:
				# Антипарковочные столбики цепочкой.
				for k: int in range(3):
					var shift: float = (float(k) - 1.0) * 1.3
					var bollard: Vector3 = pos + (Vector3(shift, 0.0, 0.0) if horizontal else Vector3(0.0, 0.0, shift))
					poles.append(_box(bollard + Vector3(0.0, 0.45, 0.0), Vector3(0.16, 0.9, 0.16)))
			3:
				# Бетонный вазон с землёй.
				var planter: Transform3D = _box(pos + Vector3(0.0, 0.4, 0.0), Vector3(1.5, 0.8, 1.5))
				props.append(planter)
				boxes.append(planter)
				props.append(_box(pos + Vector3(0.0, 0.85, 0.0), Vector3(1.2, 0.12, 1.2)))
			4:
				# Указатель улицы на столбе.
				poles.append(_box(pos + Vector3(0.0, 1.3, 0.0), Vector3(0.12, 2.6, 0.12)))
				var plate_size: Vector3 = Vector3(1.5, 0.32, 0.08) if horizontal else Vector3(0.08, 0.32, 1.5)
				metal.append(_box(pos + Vector3(0.0, 2.5, 0.0), plate_size))
			5:
				# Велопарковка: две опоры и перекладина.
				for k: int in range(2):
					var shift: float = (float(k) * 2.0) - 1.0
					var rack: Vector3 = pos + (Vector3(shift, 0.0, 0.0) if horizontal else Vector3(0.0, 0.0, shift))
					poles.append(_box(rack + Vector3(0.0, 0.4, 0.0), Vector3(0.09, 0.8, 0.09)))
				var bar_size: Vector3 = Vector3(2.1, 0.09, 0.09) if horizontal else Vector3(0.09, 0.09, 2.1)
				metal.append(_box(pos + Vector3(0.0, 0.78, 0.0), bar_size))
			_:
				# Технический шкаф городских сетей.
				var cabinet: Transform3D = _box(pos + Vector3(0.0, 0.65, 0.0), Vector3(0.75, 1.3, 0.5))
				metal.append(cabinet)
				boxes.append(cabinet)


## Витрины первого этажа: козырёк, опоры и вывеска над входом.
## Именно это даёт ощущение живой улицы, а не коридора из стен.
static func _shop_fronts(out: Dictionary, r: Rect2, y: float, horizontal: bool, density: float, rng: RandomNumberGenerator) -> void:
	var signs: Array[Dictionary] = out["signs"]
	var props: Array[Transform3D] = out["props"]
	var lights: Array[Dictionary] = out["lights"]
	if signs.size() >= MAX_SIGNS:
		return

	var length: float = r.size.x if horizontal else r.size.y
	var step: float = clampf(22.0 / maxf(0.25, density), 9.0, 40.0)
	var slots: int = maxi(1, int(length / step))
	var palette: Array[String] = ["neon_magenta", "neon_cyan", "neon_purple", "neon_green", "sodium_amber", "neon_rose"]

	for i: int in range(slots):
		if signs.size() >= MAX_SIGNS:
			return
		var along: float = (float(i) + rng.randf_range(0.2, 0.8)) * step
		if along <= 3.0 or along >= length - 3.0:
			continue
		var side: int = 1 if rng.randf() > 0.5 else -1
		var out_dist: float = SIDEWALK_WIDTH * 1.05

		var anchor: Vector3
		var awning_size: Vector3
		var sign_size: Vector3
		if horizontal:
			var edge_z: float = r.position.y if side < 0 else r.end.y
			anchor = Vector3(r.position.x + along, y, edge_z + float(side) * out_dist)
			awning_size = Vector3(rng.randf_range(3.0, 5.5), 0.22, 1.7)
			sign_size = Vector3(rng.randf_range(2.2, 4.0), rng.randf_range(0.7, 1.2), 0.22)
		else:
			var edge_x: float = r.position.x if side < 0 else r.end.x
			anchor = Vector3(edge_x + float(side) * out_dist, y, r.position.y + along)
			awning_size = Vector3(1.7, 0.22, rng.randf_range(3.0, 5.5))
			sign_size = Vector3(0.22, rng.randf_range(0.7, 1.2), rng.randf_range(2.2, 4.0))

		# Козырёк над входом и две опоры.
		props.append(_box(anchor + Vector3(0.0, 3.1, 0.0), awning_size))
		var leg_shift: float = (awning_size.x if horizontal else awning_size.z) * 0.45
		for k: int in [-1, 1]:
			var leg: Vector3 = anchor + (Vector3(leg_shift * float(k), 1.55, 0.0) if horizontal else Vector3(0.0, 1.55, leg_shift * float(k)))
			props.append(_box(leg, Vector3(0.1, 3.1, 0.1)))

		# Сама вывеска — светящаяся коробка над козырьком.
		var key: String = palette[rng.randi_range(0, palette.size() - 1)]
		var tint: Color = Color(1.0, 0.45, 0.75)
		if CityAtlas != null and CityAtlas.has_method("palette"):
			var raw: Variant = CityAtlas.palette(key)
			if raw is Color:
				tint = raw as Color
		signs.append({
			"transform": _box(anchor + Vector3(0.0, 4.15, 0.0), sign_size),
			"tint": tint,
			"custom": Color(rng.randf(), rng.randf_range(0.7, 1.0), 0.0, 0.0),
		})

		# Один-два источника на квартал: свет из витрины на мокрый тротуар.
		if lights.size() < MAX_LIGHTS and rng.randf() < 0.35:
			lights.append({
				"position": anchor + Vector3(0.0, 3.4, 0.0),
				"color": tint,
				"energy": 1.7,
				"range": 13.0,
			})
