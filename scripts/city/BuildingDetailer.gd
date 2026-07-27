class_name NoirBuildingDetailer
extends RefCounted
## ФАЗА 3. Превращение коробки в объёмную архитектуру.
##
## Как и `NoirBuildingFactory`, класс возвращает **только данные** — массивы
## трансформов, разложенные по материалам. Ноды из них собирает `NoirCityChunk`.
## Так каждый тип детали становится одним MultiMesh вместо тысяч отдельных нод.
##
## Детерминизм: генератор засеян `deco_seed` здания, поэтому детализация
## одинакова при любом уровне качества и не сдвигает поток случайных чисел
## основной застройки. Понизили настройки — деталей стало меньше, но те, что
## остались, стоят на тех же местах.
##
## Бюджет: [method detail] принимает словарь-бюджет (см. [method budget_defaults]).
## Любой отсутствующий ключ подменяется дефолтом, поэтому вызов с пустым
## словарём или с null не роняет генерацию.

const FLOOR_HEIGHT := 3.4
const SECTION_MIN := 3.6
const SECTION_MAX := 6.6
const SILL_DEPTH := 0.24
const CORNICE_DEPTH := 0.38
const COLUMN_DEPTH := 0.30
const NICHE_DEPTH := 0.34
const BAY_DEPTH := 0.95
const PARAPET_HEIGHT := 1.1
const LADDER_STEP := 0.45
## Жёсткий потолок на здание. Без него башня в 40 этажей даёт тысячи боксов
## и съедает весь выигрыш от MultiMesh на заливке инстансов.
const MAX_ELEMENTS := 320


## Бюджет по умолчанию: всё включено на средней плотности.
static func budget_defaults() -> Dictionary:
	return {
		"level": 0,
		"density": 0.7,
		"fixtures": true,
		"cables": true,
		"ladders": true,
		"drips": true,
		"billboards": true,
		"holograms": true,
		"billboard_lights": 2,
		"niches": true,
		"debris": true,
		"steam": true,
		"max_elements": MAX_ELEMENTS,
	}


## Главная точка входа. Возвращает словарь массивов; при любой проблеме —
## пустые массивы, но никогда не null и никогда не падение.
static func detail(building: Variant, district: Variant, budget: Variant) -> Dictionary:
	var out: Dictionary = _empty_result()

	if not (building is Dictionary):
		Log.warn("BuildingDetailer", "Передано не здание — детализация пропущена")
		return out
	var b: Dictionary = building as Dictionary
	if b.is_empty():
		return out

	var size: Vector3 = b.get("size", Vector3.ZERO)
	var center: Vector3 = b.get("center", Vector3.ZERO)
	var height: float = float(b.get("height", size.y))
	if size.x < 2.0 or size.z < 2.0 or height < 2.0:
		return out

	var cfg: Dictionary = _merge_budget(budget)
	var level: int = int(cfg["level"])
	if level >= 2:
		return out

	var density: float = clampf(float(cfg["density"]), 0.0, 1.0)
	if density <= 0.01:
		return out

	var limit: int = maxi(24, int(cfg["max_elements"]))
	var rng := _rng(b, 0x7F4A7C15)
	var tint: Color = b.get("tint", Color.WHITE)
	var custom: Color = b.get("custom", Color(0.5, 0.3, 0.2, 0.0))
	var palette: Array[Color] = _palette(district)

	# 1. Объём: стилобат, уступы, парапет, машинное отделение на крыше.
	_build_massing(out, size, center, height, tint, custom, rng)

	# 2. Разбивка фасадов на секции: подоконники, карнизы, колонны,
	#    эркеры и глубокие ниши окон.
	_build_facades(out, size, center, height, tint, custom, cfg, density, rng, limit)

	# 3. Внешняя инфраструктура: лестницы, трубы, кондиционеры, щитки, кабели.
	if level == 0:
		_build_infrastructure(out, size, center, height, cfg, density, rng, limit)

	# 4. Неон: объёмные щиты и голограммы, дающие живой свет на улицу.
	_build_neon(out, size, center, height, palette, cfg, density, rng)

	_collect_occluders(out)
	return out


static func _empty_result() -> Dictionary:
	return {
		"masses": [] as Array[Dictionary],      # facade-материал, цвет + custom
		"trims": [] as Array[Transform3D],      # бетон: подоконники, карнизы, колонны
		"niches": [] as Array[Dictionary],      # стекло окон в глубине ниши
		"fixtures": [] as Array[Transform3D],   # металл: кондиционеры, щитки
		"pipes": [] as Array[Transform3D],      # цилиндры вентиляции
		"cables": [] as Array[Transform3D],     # пучки кабелей
		"ladders": [] as Array[Transform3D],    # ступени и площадки пожарной лестницы
		"climb_zones": [] as Array[Dictionary], # зоны, по которым игрок лезет вверх
		"billboards": [] as Array[Dictionary],  # объёмные щиты
		"holograms": [] as Array[Dictionary],   # голограммы
		"lights": [] as Array[Dictionary],      # динамический свет от неона
		"drips": [] as Array[Vector3],          # точки капель воды
		"occluders": [] as Array[Dictionary],
		"roof_top_y": 0.0,
		"roof_size": Vector2.ZERO,
	}


static func _merge_budget(budget: Variant) -> Dictionary:
	var cfg: Dictionary = budget_defaults()
	if budget is Dictionary:
		for key: Variant in (budget as Dictionary).keys():
			if cfg.has(key):
				cfg[key] = (budget as Dictionary)[key]
	return cfg


static func _rng(building: Dictionary, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	var base: int = int(building.get("deco_seed", 0))
	if base == 0:
		var center: Vector3 = building.get("center", Vector3.ZERO)
		base = int(center.x * 71.0) ^ int(center.z * 131.0)
	rng.seed = absi(base ^ salt) | 0x40
	return rng


static func _palette(district: Variant) -> Array[Color]:
	var out: Array[Color] = []
	if district is Dictionary and (district as Dictionary).has("id"):
		var raw: Array[Color] = CityAtlas.district_palette(str((district as Dictionary)["id"]))
		if not raw.is_empty():
			return raw
	out.append(CityAtlas.palette("neon_cyan"))
	return out


# ============================================================ архитектурный объём

## Стилобат, уступы верхних этажей, парапет и надстройка на крыше. Именно они
## ломают силуэт кубика: сверху здание уже, чем внизу, а крыша не плоская.
static func _build_massing(out: Dictionary, size: Vector3, center: Vector3, height: float, tint: Color, custom: Color, rng: RandomNumberGenerator) -> void:
	var masses: Array = out["masses"]
	var trims: Array = out["trims"]

	# Стилобат: первые 1-2 этажа шире корпуса.
	var podium_floors: float = 1.0 if height < 20.0 else 2.0
	var podium_height: float = minf(height * 0.45, podium_floors * FLOOR_HEIGHT)
	var grow: float = clampf(minf(size.x, size.z) * 0.06, 0.3, 1.4)
	masses.append({
		"transform": Transform3D(
			Basis.IDENTITY.scaled(Vector3(size.x + grow * 2.0, podium_height, size.z + grow * 2.0)),
			Vector3(center.x, podium_height * 0.5, center.z)
		),
		"tint": tint.darkened(0.15),
		"custom": Color(custom.r, custom.g * 0.6, custom.b, custom.a),
	})

	# Карниз над стилобатом — тонкая плита по периметру.
	trims.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(size.x + grow * 2.0 + 0.5, 0.35, size.z + grow * 2.0 + 0.5)),
		Vector3(center.x, podium_height + 0.17, center.z)
	))

	# Уступы: чем выше здание, тем больше ступеней сужения.
	var setbacks: int = 0
	if height > 34.0:
		setbacks = 1
	if height > 58.0:
		setbacks = 2
	if height > 90.0:
		setbacks = 3

	var current_y: float = height
	var current_size := Vector2(size.x, size.z)
	for step: int in range(setbacks):
		var block_height: float = maxf(FLOOR_HEIGHT, height * rng.randf_range(0.08, 0.16))
		var shrink: float = rng.randf_range(0.12, 0.26)
		current_size = Vector2(
			maxf(2.5, current_size.x * (1.0 - shrink)),
			maxf(2.5, current_size.y * (1.0 - shrink))
		)
		masses.append({
			"transform": Transform3D(
				Basis.IDENTITY.scaled(Vector3(current_size.x, block_height, current_size.y)),
				Vector3(center.x, current_y + block_height * 0.5, center.z)
			),
			"tint": tint,
			"custom": custom,
		})
		trims.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(current_size.x + 0.6, 0.3, current_size.y + 0.6)),
			Vector3(center.x, current_y + 0.15, center.z)
		))
		current_y += block_height

	# Парапет: полый бортик по краю кровли (4 плиты, а не куб).
	var parapet_h: float = PARAPET_HEIGHT if height > 12.0 else 0.6
	var half_x: float = current_size.x * 0.5
	var half_z: float = current_size.y * 0.5
	trims.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(current_size.x, parapet_h, 0.3)),
		Vector3(center.x, current_y + parapet_h * 0.5, center.z - half_z)
	))
	trims.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(current_size.x, parapet_h, 0.3)),
		Vector3(center.x, current_y + parapet_h * 0.5, center.z + half_z)
	))
	trims.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(0.3, parapet_h, current_size.y)),
		Vector3(center.x - half_x, current_y + parapet_h * 0.5, center.z)
	))
	trims.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(0.3, parapet_h, current_size.y)),
		Vector3(center.x + half_x, current_y + parapet_h * 0.5, center.z)
	))

	# Надстройка над лифтовой шахтой: силуэт крыши перестаёт быть линейкой.
	if height > 22.0:
		var house := Vector3(
			clampf(current_size.x * rng.randf_range(0.2, 0.35), 2.0, 8.0),
			rng.randf_range(2.4, 4.2),
			clampf(current_size.y * rng.randf_range(0.2, 0.35), 2.0, 8.0)
		)
		masses.append({
			"transform": Transform3D(
				Basis.IDENTITY.scaled(house),
				Vector3(
					center.x + rng.randf_range(-current_size.x * 0.2, current_size.x * 0.2),
					current_y + house.y * 0.5,
					center.z + rng.randf_range(-current_size.y * 0.2, current_size.y * 0.2)
				)
			),
			"tint": tint.darkened(0.25),
			"custom": Color(custom.r, 0.05, 0.0, 0.0),
		})

	out["roof_top_y"] = current_y
	out["roof_size"] = current_size


# =================================================================== фасады

static func _sides(size: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append({"facing": Vector3.RIGHT, "tangent": Vector3.BACK, "half": size.x * 0.5, "along": size.z})
	out.append({"facing": Vector3.LEFT, "tangent": Vector3.BACK, "half": size.x * 0.5, "along": size.z})
	out.append({"facing": Vector3.BACK, "tangent": Vector3.RIGHT, "half": size.z * 0.5, "along": size.x})
	out.append({"facing": Vector3.FORWARD, "tangent": Vector3.RIGHT, "half": size.z * 0.5, "along": size.x})
	return out


## Бокс, прижатый к стене. [param inset] > 0 — утопить внутрь (ниша).
static func _side_box(side: Dictionary, center: Vector3, y: float, offset: float, width: float, height: float, depth: float, inset: float = 0.0) -> Transform3D:
	var facing: Vector3 = side["facing"]
	var tangent: Vector3 = side["tangent"]
	var half: float = float(side["half"])
	var pos: Vector3 = Vector3(center.x, y, center.z) + facing * (half + depth * 0.5 - inset) + tangent * offset
	var box_scale: Vector3 = Vector3(depth, height, width) if absf(facing.x) > 0.5 else Vector3(width, height, depth)
	return Transform3D(Basis.IDENTITY.scaled(box_scale), pos)


## Разбивает каждую стену на секции и наращивает на них объём.
static func _build_facades(out: Dictionary, size: Vector3, center: Vector3, height: float, tint: Color, custom: Color, cfg: Dictionary, density: float, rng: RandomNumberGenerator, limit: int) -> void:
	var trims: Array = out["trims"]
	var masses: Array = out["masses"]
	var niches: Array = out["niches"]
	var level: int = int(cfg["level"])
	var want_niches: bool = bool(cfg["niches"]) and level == 0

	var floors: int = maxi(1, int(height / FLOOR_HEIGHT))
	# Сколько этажей вообще детализируем. Выше 12-го этажа подоконник не
	# читается даже вплотную, поэтому там остаются только карнизы.
	var detailed_floors: int = clampi(int(round(float(floors) * density)), 1, 12 if level == 0 else 5)
	var podium_height: float = minf(height * 0.45, (1.0 if height < 20.0 else 2.0) * FLOOR_HEIGHT)

	for side: Dictionary in _sides(size):
		var along: float = float(side["along"])
		if along < SECTION_MIN:
			continue

		var section_count: int = maxi(1, int(round(along / rng.randf_range(SECTION_MIN, SECTION_MAX))))
		var section_w: float = along / float(section_count)
		var start: float = -along * 0.5

		# Декоративный карниз каждые 3-4 этажа по всей ширине стены.
		var cornice_every: int = 3 if height < 40.0 else 4
		var band: int = cornice_every
		while band < floors:
			if _count(out) >= limit:
				break
			trims.append(_side_box(side, center, float(band) * FLOOR_HEIGHT, 0.0, along * 0.99, 0.28, CORNICE_DEPTH))
			band += cornice_every

		for s: int in range(section_count):
			if _count(out) >= limit:
				return
			var offset: float = start + section_w * (float(s) + 0.5)

			# Колонна на стыке секций — только в пределах стилобата, где её видно.
			if s > 0:
				trims.append(_side_box(
					side, center, podium_height * 0.5, start + section_w * float(s),
					0.55, podium_height, COLUMN_DEPTH
				))

			# Эркер: секция выпирает на несколько этажей вверх.
			var bay_chance: float = 0.28 * density
			if height > 16.0 and section_w > 3.0 and rng.randf() < bay_chance:
				var bay_floors: int = rng.randi_range(2, maxi(2, mini(6, floors - 2)))
				var bay_from: int = rng.randi_range(1, maxi(1, floors - bay_floors))
				var bay_h: float = float(bay_floors) * FLOOR_HEIGHT
				var bay_y: float = float(bay_from) * FLOOR_HEIGHT + bay_h * 0.5
				masses.append({
					"transform": _side_box(side, center, bay_y, offset, section_w * 0.72, bay_h, BAY_DEPTH),
					"tint": tint.lightened(0.05),
					"custom": custom,
				})
				# Плита-донце эркера и карниз-крышка.
				trims.append(_side_box(side, center, float(bay_from) * FLOOR_HEIGHT, offset, section_w * 0.78, 0.24, BAY_DEPTH + 0.1))
				trims.append(_side_box(side, center, float(bay_from + bay_floors) * FLOOR_HEIGHT, offset, section_w * 0.78, 0.24, BAY_DEPTH + 0.1))
				continue

			# Подоконники и оконные ниши по этажам.
			for f: int in range(1, detailed_floors + 1):
				if _count(out) >= limit:
					return
				var window_y: float = float(f) * FLOOR_HEIGHT + 1.5
				if window_y > height - 1.0:
					break
				var window_w: float = section_w * 0.6

				# Выступающий подоконник.
				trims.append(_side_box(side, center, window_y - 0.95, offset, window_w + 0.35, 0.18, SILL_DEPTH))

				if not want_niches:
					continue

				# Глубокая ниша: рама из трёх плит + стекло, утопленное внутрь.
				var niche_h: float = 1.7
				trims.append(_side_box(side, center, window_y, offset - window_w * 0.5 - 0.12, 0.24, niche_h, NICHE_DEPTH))
				trims.append(_side_box(side, center, window_y, offset + window_w * 0.5 + 0.12, 0.24, niche_h, NICHE_DEPTH))
				trims.append(_side_box(side, center, window_y + niche_h * 0.5 + 0.12, offset, window_w + 0.5, 0.24, NICHE_DEPTH))

				var facing: Vector3 = side["facing"]
				var tangent: Vector3 = side["tangent"]
				var half: float = float(side["half"])
				var glass_pos: Vector3 = Vector3(center.x, window_y, center.z) + facing * (half - NICHE_DEPTH) + tangent * offset
				var glass_basis := Basis.looking_at(-facing, Vector3.UP).scaled(Vector3(window_w, niche_h, 1.0))
				var lit: bool = rng.randf() < clampf(custom.g, 0.05, 0.9)
				niches.append({
					"transform": Transform3D(glass_basis, glass_pos),
					"tint": CityAtlas.palette("window_warm") if lit else Color(0.05, 0.06, 0.08),
					"custom": Color(rng.randf(), 0.75 if lit else 0.05, 0.0, 0.0),
				})


# ======================================================= внешняя инфраструктура

static func _build_infrastructure(out: Dictionary, size: Vector3, center: Vector3, height: float, cfg: Dictionary, density: float, rng: RandomNumberGenerator, limit: int) -> void:
	var fixtures: Array = out["fixtures"]
	var pipes: Array = out["pipes"]
	var cables: Array = out["cables"]
	var ladders: Array = out["ladders"]
	var climb: Array = out["climb_zones"]
	var drips: Array = out["drips"]

	var sides: Array[Dictionary] = _sides(size)
	if sides.is_empty():
		return

	# --- Пожарная лестница: тетивы, ступени, площадки и зона лазания.
	if bool(cfg["ladders"]) and height > 9.0 and rng.randf() < 0.55 + 0.35 * density:
		var side: Dictionary = sides[rng.randi_range(0, sides.size() - 1)]
		var along: float = float(side["along"])
		var offset: float = rng.randf_range(-along * 0.3, along * 0.3)
		var top: float = height - 1.2
		var rails_w: float = 1.35

		ladders.append(_side_box(side, center, top * 0.5, offset - rails_w * 0.5, 0.12, top, 0.14))
		ladders.append(_side_box(side, center, top * 0.5, offset + rails_w * 0.5, 0.12, top, 0.14))

		var step_count: int = clampi(int(top / LADDER_STEP), 4, 120)
		for i: int in range(step_count):
			if _count(out) >= limit:
				break
			ladders.append(_side_box(side, center, 1.0 + float(i) * LADDER_STEP, offset, rails_w, 0.07, 0.12))

		# Площадки каждые три этажа: на них игрок отдыхает и заходит в окно.
		var platform_floor: int = 2
		while float(platform_floor) * FLOOR_HEIGHT < top:
			ladders.append(_side_box(side, center, float(platform_floor) * FLOOR_HEIGHT, offset, rails_w + 1.2, 0.14, 1.25))
			ladders.append(_side_box(side, center, float(platform_floor) * FLOOR_HEIGHT + 0.55, offset, rails_w + 1.2, 0.08, 1.3))
			platform_floor += 3

		# Зона лазания — область перед лестницей, её собирает NoirClimbArea.
		var facing: Vector3 = side["facing"]
		var tangent: Vector3 = side["tangent"]
		var half: float = float(side["half"])
		var zone_pos: Vector3 = Vector3(center.x, top * 0.5 + 0.5, center.z) + facing * (half + 0.55) + tangent * offset
		var zone_size: Vector3 = (
			Vector3(1.1, top, rails_w + 0.6) if absf(facing.x) > 0.5
			else Vector3(rails_w + 0.6, top, 1.1)
		)
		climb.append({
			"position": zone_pos,
			"size": zone_size,
			"normal": facing,
			"top_y": top,
		})

	if not bool(cfg["fixtures"]):
		return

	# --- Переплетения вентиляционных труб: вертикальный стояк + отводы.
	var pipe_runs: int = int(round(rng.randf_range(1.0, 3.0) * density))
	for _r: int in range(pipe_runs):
		if _count(out) >= limit:
			break
		var side: Dictionary = sides[rng.randi_range(0, sides.size() - 1)]
		var along: float = float(side["along"])
		var offset: float = rng.randf_range(-along * 0.42, along * 0.42)
		var radius: float = rng.randf_range(0.16, 0.32)
		var run_top: float = rng.randf_range(height * 0.5, height - 0.5)
		pipes.append(_side_box(side, center, run_top * 0.5, offset, radius * 2.0, run_top, radius * 2.0))

		var elbows: int = rng.randi_range(1, 3)
		for e: int in range(elbows):
			var y: float = rng.randf_range(3.0, maxf(3.5, run_top - 1.0))
			var span: float = rng.randf_range(1.2, minf(6.0, along * 0.35))
			var dir: float = 1.0 if rng.randf() < 0.5 else -1.0
			pipes.append(_side_box(side, center, y, offset + dir * span * 0.5, span, radius * 1.8, radius * 1.8))

	# --- Кондиционеры со стекающей водой и распределительные щитки.
	var ac_count: int = int(round(rng.randf_range(2.0, 7.0) * density))
	for _i: int in range(ac_count):
		if _count(out) >= limit:
			break
		var side: Dictionary = sides[rng.randi_range(0, sides.size() - 1)]
		var along: float = float(side["along"])
		var offset: float = rng.randf_range(-along * 0.42, along * 0.42)
		var y: float = rng.randf_range(3.4, maxf(4.0, minf(height - 1.5, 30.0)))
		var unit := Vector3(rng.randf_range(0.8, 1.25), rng.randf_range(0.55, 0.85), 0.55)
		fixtures.append(_side_box(side, center, y, offset, unit.x, unit.y, unit.z))
		fixtures.append(_side_box(side, center, y - unit.y * 0.5 - 0.08, offset, unit.x * 0.9, 0.1, unit.z * 0.9))

		if bool(cfg["drips"]) and rng.randf() < 0.55:
			var facing: Vector3 = side["facing"]
			var tangent: Vector3 = side["tangent"]
			var half: float = float(side["half"])
			drips.append(Vector3(center.x, y - unit.y * 0.6, center.z) + facing * (half + 0.45) + tangent * offset)

	# Щитки у земли.
	var boxes: int = int(round(rng.randf_range(1.0, 3.0) * density))
	for _i: int in range(boxes):
		var side: Dictionary = sides[rng.randi_range(0, sides.size() - 1)]
		var along: float = float(side["along"])
		fixtures.append(_side_box(
			side, center, rng.randf_range(1.2, 2.1), rng.randf_range(-along * 0.4, along * 0.4),
			rng.randf_range(0.45, 0.8), rng.randf_range(0.6, 0.95), 0.28
		))

	# --- Пучки свисающих кабелей с лёгким наклоном.
	if not bool(cfg["cables"]):
		return
	var bundles: int = int(round(rng.randf_range(1.0, 4.0) * density))
	for _i: int in range(bundles):
		if _count(out) >= limit:
			break
		var side: Dictionary = sides[rng.randi_range(0, sides.size() - 1)]
		var along: float = float(side["along"])
		var offset: float = rng.randf_range(-along * 0.4, along * 0.4)
		var from_y: float = rng.randf_range(4.0, maxf(4.5, minf(height - 1.0, 24.0)))
		var strands: int = rng.randi_range(2, 4)
		for s: int in range(strands):
			var length: float = rng.randf_range(2.0, minf(from_y - 1.0, 9.0))
			if length <= 0.5:
				continue
			var lateral: float = offset + float(s) * 0.09 + rng.randf_range(-0.12, 0.12)
			var xform: Transform3D = _side_box(side, center, from_y - length * 0.5, lateral, 0.05, length, 0.05)
			# Строго вертикальные провода выглядят нарисованными — даём наклон.
			var tilt: float = rng.randf_range(-0.09, 0.09)
			xform.basis = xform.basis.rotated(Vector3(side["tangent"]), tilt)
			cables.append(xform)


# ==================================================================== неон

## Объёмные щиты и голограммы. Они не только светятся сами, но и дают
## настоящий OmniLight — иначе неон не попадает на мокрый асфальт.
static func _build_neon(out: Dictionary, size: Vector3, center: Vector3, height: float, palette: Array[Color], cfg: Dictionary, density: float, rng: RandomNumberGenerator) -> void:
	if palette.is_empty():
		return
	var billboards: Array = out["billboards"]
	var holograms: Array = out["holograms"]
	var lights: Array = out["lights"]
	var sides: Array[Dictionary] = _sides(size)
	var light_budget: int = maxi(0, int(cfg["billboard_lights"]))

	if bool(cfg["billboards"]):
		var count: int = clampi(int(round(rng.randf_range(1.0, 3.0) * (0.4 + density))), 1, 4)
		for _i: int in range(count):
			var side: Dictionary = sides[rng.randi_range(0, sides.size() - 1)]
			var along: float = float(side["along"])
			if along < 3.0:
				continue
			var vertical: bool = height > 26.0 and rng.randf() < 0.6
			var w: float = 0.0
			var h: float = 0.0
			var y: float = 0.0
			if vertical:
				w = clampf(rng.randf_range(1.4, 2.6), 1.0, along * 0.4)
				h = clampf(height * rng.randf_range(0.25, 0.5), 4.0, maxf(4.0, height - 6.0))
				y = rng.randf_range(h * 0.5 + 5.0, maxf(h * 0.5 + 5.5, height - h * 0.5 - 1.0))
			else:
				w = clampf(along * rng.randf_range(0.4, 0.8), 2.0, maxf(2.0, along - 0.5))
				h = rng.randf_range(1.2, 2.6)
				y = rng.randf_range(4.2, minf(11.0, maxf(4.8, height - 1.5)))

			var depth: float = rng.randf_range(0.35, 0.75)
			var offset: float = rng.randf_range(-along * 0.3, along * 0.3)
			var color: Color = palette[rng.randi_range(0, palette.size() - 1)]
			var broken: float = 1.0 if rng.randf() < 0.12 else 0.0
			billboards.append({
				"transform": _side_box(side, center, y, offset, w, h, depth),
				"tint": color,
				"custom": Color(rng.randf(), rng.randf_range(0.6, 1.0), broken, rng.randf_range(0.0, 1.2)),
			})

			if lights.size() < light_budget and broken < 0.5:
				var facing: Vector3 = side["facing"]
				var tangent: Vector3 = side["tangent"]
				var half: float = float(side["half"])
				lights.append({
					"position": Vector3(center.x, y, center.z) + facing * (half + 1.6) + tangent * offset,
					"color": color,
					"energy": clampf(1.4 + h * 0.05, 1.2, 4.0),
					"range": clampf(9.0 + maxf(w, h) * 1.6, 10.0, 34.0),
				})

	if bool(cfg["holograms"]) and height > 18.0 and rng.randf() < 0.3 * (0.5 + density):
		var side: Dictionary = sides[rng.randi_range(0, sides.size() - 1)]
		var along: float = float(side["along"])
		var facing: Vector3 = side["facing"]
		var tangent: Vector3 = side["tangent"]
		var half: float = float(side["half"])
		var offset: float = rng.randf_range(-along * 0.25, along * 0.25)
		var y: float = rng.randf_range(8.0, maxf(9.0, height * 0.7))
		var hw: float = rng.randf_range(2.5, 5.0)
		var hh: float = rng.randf_range(4.0, 9.0)
		var holo_basis := Basis.looking_at(-facing, Vector3.UP).scaled(Vector3(hw, hh, 1.0))
		var color: Color = palette[rng.randi_range(0, palette.size() - 1)]
		holograms.append({
			"transform": Transform3D(holo_basis, Vector3(center.x, y, center.z) + facing * (half + 2.6) + tangent * offset),
			"tint": color,
			"custom": Color(rng.randf(), rng.randf_range(0.5, 1.0), 0.0, rng.randf_range(0.2, 1.0)),
		})
		if lights.size() < light_budget + 1:
			lights.append({
				"position": Vector3(center.x, y - hh * 0.35, center.z) + facing * (half + 3.2) + tangent * offset,
				"color": color,
				"energy": 2.2,
				"range": 26.0,
			})


# ================================================================ окклюдеры

## Крупные добавленные объёмы тоже должны перекрывать вид — иначе стилобат
## пропускает сквозь себя весь неон соседней улицы.
static func _collect_occluders(out: Dictionary) -> void:
	for entry: Variant in out["masses"] as Array:
		var mass: Dictionary = entry as Dictionary
		var xform: Transform3D = mass["transform"]
		var box := Vector3(xform.basis.x.length(), xform.basis.y.length(), xform.basis.z.length())
		if box.y < 4.0 or minf(box.x, box.z) < 4.0:
			continue
		(out["occluders"] as Array).append({
			"center": xform.origin,
			"size": Vector3(maxf(1.0, box.x - 0.6), maxf(1.0, box.y - 0.6), maxf(1.0, box.z - 0.6)),
		})


## Сколько инстансов уже набралось — по этому числу работает потолок.
static func _count(out: Dictionary) -> int:
	var total: int = 0
	for key: String in ["masses", "trims", "niches", "fixtures", "pipes", "cables", "ladders", "billboards", "holograms"]:
		var raw: Variant = out.get(key, null)
		if raw is Array:
			total += (raw as Array).size()
	return total
