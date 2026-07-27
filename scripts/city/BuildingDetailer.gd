class_name NoirBuildingDetailer
extends RefCounted
## ФАЗА 3. Превращение коробки в объёмную архитектуру.
##
## Класс возвращает **только данные** — массивы трансформов, разложенные
## по материалам. Ноды из них собирает `NoirCityChunk`, так каждый тип детали
## становится одним MultiMesh вместо тысяч отдельных нод.
##
## Уровни детализации (настройка `graphics/facade_detail`, 0..4):
##   0 — коробки: только объём и силуэт;
##   1 — базовая: подоконники, карнизы, колонны стилобата;
##   2 — подробная: глубокие ниши окон с переплётами, угловые лопатки,
##       водостоки, кровельное хозяйство;
##   3 — богатая: балконы с ограждениями, входные группы, маркизы,
##       пилястры на всю высоту, ступенчатые вершины;
##   4 — кино: всё выше плюс межэтажные тяги через два этажа и максимум
##       декорированных этажей.
##
## Внешняя обвеска (лестницы, трубы, кабели) и неон живут в `NoirFacadeExtras`.
##
## Детерминизм: генератор засеян `deco_seed` здания, поэтому детализация
## одинакова при любом качестве и не сдвигает поток случайных чисел застройки.

const FLOOR_HEIGHT := 3.4
const SECTION_MIN := 3.2
const SECTION_MAX := 5.4
const SILL_DEPTH := 0.24
const CORNICE_DEPTH := 0.38
const COLUMN_DEPTH := 0.30
const NICHE_DEPTH := 0.34
const BAY_DEPTH := 0.95
const PARAPET_HEIGHT := 1.1
const FRAME_DEPTH := 0.16
const BALCONY_DEPTH := 1.25
## Жёсткий потолок на здание на максимальном уровне.
const MAX_ELEMENTS := 1400
## Потолок инстансов по уровням facade_detail 0..4.
const DETAIL_LIMITS: Array[int] = [40, 260, 520, 900, 1400]
## Сколько этажей украшаем по уровням facade_detail 0..4.
const DETAIL_FLOORS: Array[int] = [0, 5, 10, 16, 26]


## Бюджет по умолчанию: всё включено на средней плотности.
## `facade_detail = -1` означает «взять уровень из настроек игры».
static func budget_defaults() -> Dictionary:
	return {
		"level": 0,
		"density": 0.7,
		"facade_detail": -1,
		"fixtures": true,
		"cables": true,
		"ladders": true,
		"drips": true,
		"billboards": true,
		"holograms": true,
		"billboard_lights": 2,
		"niches": true,
		"balconies": true,
		"roof_gear": true,
		"entrances": true,
		"debris": true,
		"steam": true,
		"max_elements": MAX_ELEMENTS,
	}


## Главная точка входа. При любой проблеме возвращает пустые массивы,
## но никогда null и никогда не падение.
static func detail(building: Variant, district: Variant, budget: Variant) -> Dictionary:
	var out: Dictionary = _empty_result()

	if not (building is Dictionary):
		Log.warn("BuildingDetailer", "Передано не здание — детализация пропущена")
		return out
	var b: Dictionary = building as Dictionary
	if b.is_empty():
		return out

	var box_size: Vector3 = b.get("size", Vector3.ZERO)
	var center: Vector3 = b.get("center", Vector3.ZERO)
	var height: float = float(b.get("height", box_size.y))
	if box_size.x < 2.0 or box_size.z < 2.0 or height < 2.0:
		return out

	var cfg: Dictionary = _merge_budget(budget)
	var level: int = int(cfg["level"])
	if level >= 2:
		return out

	var density: float = clampf(float(cfg["density"]), 0.0, 1.0)
	if density <= 0.01:
		return out

	var detail_level: int = _resolve_detail_level(cfg)
	var rng := _rng(b, 0x7F4A7C15)
	var tint: Color = b.get("tint", Color.WHITE)
	var custom: Color = b.get("custom", Color(0.5, 0.3, 0.2, 0.0))
	var palette: Array[Color] = _palette(district)

	# 1. Объём: стилобат, уступы, парапет, надстройка. Строится всегда:
	#    это единицы боксов, а без них город — кладбище параллелепипедов.
	_build_massing(out, box_size, center, height, tint, custom, rng, detail_level)

	if detail_level <= 0:
		_collect_occluders(out)
		return out

	var limit: int = mini(maxi(24, int(cfg["max_elements"])), DETAIL_LIMITS[detail_level])

	# 2. Фасады: секции, подоконники, карнизы, колонны, эркеры, ниши,
	#    рамы с переплётами, балконы и маркизы.
	_build_facades(out, box_size, center, height, tint, custom, cfg, density, rng, limit, detail_level)

	# 3. Угловые лопатки и водостоки: 6-8 инстансов, но угол сразу
	#    перестаёт быть голой гранью куба.
	if detail_level >= 2:
		_build_corners(out, box_size, center, height, rng, detail_level)

	# 4. Входная группа: ступени, козырёк, портал и два фонаря — масштаб.
	if detail_level >= 3 and bool(cfg["entrances"]):
		_build_entrance(out, box_size, center, palette, rng)

	# 5. Кровельное хозяйство: баки на опорах, вентблоки, антенны, тарелки.
	if detail_level >= 2 and bool(cfg["roof_gear"]):
		_build_roofscape(out, center, rng, density, detail_level)

	# 6. Внешняя инженерная обвеска — только вблизи от игрока.
	if level == 0:
		NoirFacadeExtras.build_infrastructure(out, box_size, center, height, cfg, density, rng, limit)

	# 7. Неон: объёмные щиты и голограммы с живым светом на улицу.
	NoirFacadeExtras.build_neon(out, box_size, center, height, palette, cfg, density, rng)

	_collect_occluders(out)
	return out


## Явное значение из бюджета важнее настроек — так тесты и отладка могут
## задать уровень напрямую.
static func _resolve_detail_level(cfg: Dictionary) -> int:
	var explicit: int = int(cfg.get("facade_detail", -1))
	if explicit >= 0:
		return clampi(explicit, 0, 4)
	if GameConfig != null:
		return clampi(GameConfig.get_int("graphics", "facade_detail"), 0, 4)
	return 3


static func _empty_result() -> Dictionary:
	return {
		"masses": [] as Array[Dictionary],      # facade-материал, цвет + custom
		"trims": [] as Array[Transform3D],      # бетон: подоконники, карнизы, колонны
		"niches": [] as Array[Dictionary],      # стекло окон в глубине ниши
		"fixtures": [] as Array[Transform3D],   # металл: ограждения, кондиционеры, щитки
		"pipes": [] as Array[Transform3D],      # цилиндры: вентиляция, водостоки, баки
		"cables": [] as Array[Transform3D],     # пучки кабелей
		"ladders": [] as Array[Transform3D],    # ступени и площадки пожарной лестницы
		"climb_zones": [] as Array[Dictionary], # зоны, по которым игрок лезет вверх
		"billboards": [] as Array[Dictionary],  # объёмные щиты
		"holograms": [] as Array[Dictionary],   # голограммы
		"lights": [] as Array[Dictionary],      # динамический свет
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

## Стилобат, уступы, парапет и надстройка на крыше. Именно они ломают
## силуэт кубика: сверху здание уже, чем внизу, а крыша не плоская.
static func _build_massing(out: Dictionary, box_size: Vector3, center: Vector3, height: float, tint: Color, custom: Color, rng: RandomNumberGenerator, detail_level: int) -> void:
	var masses: Array = out["masses"]
	var trims: Array = out["trims"]

	# Стилобат: первые 1-2 этажа шире корпуса.
	var podium_floors: float = 1.0 if height < 20.0 else 2.0
	var podium_height: float = minf(height * 0.45, podium_floors * FLOOR_HEIGHT)
	var grow: float = clampf(minf(box_size.x, box_size.z) * 0.06, 0.3, 1.4)
	masses.append({
		"transform": Transform3D(
			Basis.IDENTITY.scaled(Vector3(box_size.x + grow * 2.0, podium_height, box_size.z + grow * 2.0)),
			Vector3(center.x, podium_height * 0.5, center.z)
		),
		"tint": tint.darkened(0.15),
		"custom": Color(custom.r, custom.g * 0.6, custom.b, custom.a),
	})

	# Карниз над стилобатом — тонкая плита по периметру.
	trims.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(box_size.x + grow * 2.0 + 0.5, 0.35, box_size.z + grow * 2.0 + 0.5)),
		Vector3(center.x, podium_height + 0.17, center.z)
	))

	# Уступы: чем выше здание, тем больше ступеней сужения.
	var setbacks: int = 0
	if height > 26.0:
		setbacks = 1
	if height > 48.0:
		setbacks = 2
	if height > 74.0:
		setbacks = 3
	if height > 100.0:
		setbacks = 4

	var current_y: float = height
	var current_size := Vector2(box_size.x, box_size.z)
	for _step: int in range(setbacks):
		var block_height: float = maxf(FLOOR_HEIGHT, height * rng.randf_range(0.07, 0.15))
		var shrink: float = rng.randf_range(0.10, 0.24)
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

	# Надстройка над лифтовой шахтой и второй объём сверху.
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

		if detail_level >= 3 and rng.randf() < 0.6:
			var cap := Vector3(
				clampf(current_size.x * rng.randf_range(0.45, 0.7), 3.0, 16.0),
				rng.randf_range(1.4, 2.6),
				clampf(current_size.y * rng.randf_range(0.45, 0.7), 3.0, 16.0)
			)
			masses.append({
				"transform": Transform3D(
					Basis.IDENTITY.scaled(cap),
					Vector3(center.x, current_y + cap.y * 0.5, center.z)
				),
				"tint": tint.darkened(0.1),
				"custom": Color(custom.r, 0.08, 0.0, 0.0),
			})

	out["roof_top_y"] = current_y
	out["roof_size"] = current_size


# =================================================================== фасады

static func _sides(box_size: Vector3) -> Array[Dictionary]:
	return NoirFacadeExtras.sides(box_size)


static func _side_box(side: Dictionary, center: Vector3, y: float, offset: float, width: float, box_height: float, depth: float, inset: float = 0.0) -> Transform3D:
	return NoirFacadeExtras.side_box(side, center, y, offset, width, box_height, depth, inset)


## Разбивает каждую стену на секции и наращивает на них объём.
static func _build_facades(out: Dictionary, box_size: Vector3, center: Vector3, height: float, tint: Color, custom: Color, cfg: Dictionary, density: float, rng: RandomNumberGenerator, limit: int, detail_level: int) -> void:
	var trims: Array = out["trims"]
	var masses: Array = out["masses"]
	var niches: Array = out["niches"]
	var fixtures: Array = out["fixtures"]
	var level: int = int(cfg["level"])
	var want_niches: bool = bool(cfg["niches"]) and level == 0 and detail_level >= 2
	var want_frames: bool = detail_level >= 2 and level == 0
	var want_balconies: bool = bool(cfg["balconies"]) and detail_level >= 3 and level == 0

	var floors: int = maxi(1, int(height / FLOOR_HEIGHT))
	var floor_cap: int = DETAIL_FLOORS[detail_level]
	if level > 0:
		floor_cap = maxi(2, int(float(floor_cap) / 3.0))
	var detailed_floors: int = clampi(int(round(float(floors) * density)), 1, maxi(1, floor_cap))
	var podium_height: float = minf(height * 0.45, (1.0 if height < 20.0 else 2.0) * FLOOR_HEIGHT)

	for side: Dictionary in _sides(box_size):
		var along: float = float(side["along"])
		if along < SECTION_MIN:
			continue

		var section_count: int = maxi(1, int(round(along / rng.randf_range(SECTION_MIN, SECTION_MAX))))
		var section_w: float = along / float(section_count)
		var start: float = -along * 0.5

		# Межэтажные тяги по всей ширине стены: горизонтальный ритм фасада.
		var cornice_every: int = 4
		if detail_level >= 3:
			cornice_every = 3
		if detail_level >= 4:
			cornice_every = 2
		var band: int = cornice_every
		while band < floors:
			if _count(out) >= limit:
				break
			trims.append(_side_box(side, center, float(band) * FLOOR_HEIGHT, 0.0, along * 0.99, 0.28, CORNICE_DEPTH))
			band += cornice_every

		# Маркиз над витриной первого этажа: наклонная плита.
		if detail_level >= 3 and along > 5.0 and rng.randf() < 0.5:
			var awning: Transform3D = _side_box(
				side, center, 3.1, rng.randf_range(-along * 0.2, along * 0.2),
				minf(along * 0.5, 6.0), 0.16, 1.5
			)
			awning.basis = awning.basis.rotated(Vector3(side["tangent"]), 0.22)
			trims.append(awning)

		for s: int in range(section_count):
			if _count(out) >= limit:
				return
			var offset: float = start + section_w * (float(s) + 0.5)

			# Колонна на стыке секций и пилястра на всю высоту корпуса.
			if s > 0:
				trims.append(_side_box(
					side, center, podium_height * 0.5, start + section_w * float(s),
					0.55, podium_height, COLUMN_DEPTH
				))
				if detail_level >= 3 and height > 14.0:
					var pil_h: float = height - podium_height - 0.6
					if pil_h > 2.0:
						trims.append(_side_box(
							side, center, podium_height + pil_h * 0.5, start + section_w * float(s),
							0.42, pil_h, 0.18
						))

			# Эркер: секция выпирает на несколько этажей вверх.
			var bay_chance: float = (0.2 + 0.12 * float(detail_level)) * density
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
				trims.append(_side_box(side, center, float(bay_from) * FLOOR_HEIGHT, offset, section_w * 0.78, 0.24, BAY_DEPTH + 0.1))
				trims.append(_side_box(side, center, float(bay_from + bay_floors) * FLOOR_HEIGHT, offset, section_w * 0.78, 0.24, BAY_DEPTH + 0.1))
				continue

			# Подоконники, ниши, рамы и балконы по этажам.
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

				# Глубокая ниша: рама из трёх плит + стекло внутри.
				var niche_h: float = 1.7
				trims.append(_side_box(side, center, window_y, offset - window_w * 0.5 - 0.12, 0.24, niche_h, NICHE_DEPTH))
				trims.append(_side_box(side, center, window_y, offset + window_w * 0.5 + 0.12, 0.24, niche_h, NICHE_DEPTH))
				trims.append(_side_box(side, center, window_y + niche_h * 0.5 + 0.12, offset, window_w + 0.5, 0.24, NICHE_DEPTH))

				# Переплёт рамы: вертикальная стойка и горизонтальный импост.
				# Без них окно читается наклеенным прямоугольником — тот самый
				# эффект «коробка с напичканными окнами».
				if want_frames:
					trims.append(_side_box(side, center, window_y, offset, 0.10, niche_h, FRAME_DEPTH, NICHE_DEPTH * 0.45))
					trims.append(_side_box(side, center, window_y + niche_h * 0.16, offset, window_w, 0.09, FRAME_DEPTH, NICHE_DEPTH * 0.45))

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

				# Балкон: плита + перила из трёх прутьев и двух стоек.
				if want_balconies and section_w > 3.4 and rng.randf() < 0.34 * density:
					var bal_y: float = window_y - 1.05
					var bal_w: float = window_w + 0.9
					trims.append(_side_box(side, center, bal_y, offset, bal_w, 0.2, BALCONY_DEPTH))
					for rail: int in range(3):
						fixtures.append(_side_box(
							side, center, bal_y + 0.35 + float(rail) * 0.35, offset,
							bal_w, 0.06, 0.08, -BALCONY_DEPTH + 0.1
						))
					fixtures.append(_side_box(side, center, bal_y + 0.55, offset - bal_w * 0.5, 0.08, 1.1, 0.08, -BALCONY_DEPTH + 0.1))
					fixtures.append(_side_box(side, center, bal_y + 0.55, offset + bal_w * 0.5, 0.08, 1.1, 0.08, -BALCONY_DEPTH + 0.1))


# ============================================================ углы и водостоки

## Угловые лопатки и водосточные трубы на всю высоту.
static func _build_corners(out: Dictionary, box_size: Vector3, center: Vector3, height: float, rng: RandomNumberGenerator, detail_level: int) -> void:
	var trims: Array = out["trims"]
	var pipes: Array = out["pipes"]
	var half_x: float = box_size.x * 0.5
	var half_z: float = box_size.z * 0.5
	var quoin_h: float = height * 0.98
	var quoin_w: float = clampf(minf(box_size.x, box_size.z) * 0.08, 0.45, 1.1)

	var corners: Array[Vector2] = [
		Vector2(-1.0, -1.0), Vector2(1.0, -1.0), Vector2(-1.0, 1.0), Vector2(1.0, 1.0),
	]
	for corner: Vector2 in corners:
		trims.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(quoin_w, quoin_h, quoin_w)),
			Vector3(
				center.x + corner.x * (half_x + quoin_w * 0.15),
				quoin_h * 0.5,
				center.z + corner.y * (half_z + quoin_w * 0.15)
			)
		))

	var downpipes: int = 2 if detail_level >= 3 else 1
	for _i: int in range(downpipes):
		var corner: Vector2 = corners[rng.randi_range(0, corners.size() - 1)]
		var radius: float = rng.randf_range(0.10, 0.16)
		pipes.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(radius * 2.0, height * 0.96, radius * 2.0)),
			Vector3(
				center.x + corner.x * (half_x + radius + quoin_w * 0.4),
				height * 0.48,
				center.z + corner.y * (half_z + radius + quoin_w * 0.4)
			)
		))


# =============================================================== входная группа

## Крыльцо: ступени, козырёк на двух колоннах, портал и два фонаря.
## Даёт зданию масштаб: сразу понятно, где земля и какого роста человек.
static func _build_entrance(out: Dictionary, box_size: Vector3, center: Vector3, palette: Array[Color], rng: RandomNumberGenerator) -> void:
	var wall_list: Array[Dictionary] = _sides(box_size)
	if wall_list.is_empty():
		return
	var side: Dictionary = wall_list[rng.randi_range(0, wall_list.size() - 1)]
	var along: float = float(side["along"])
	if along < 4.0:
		return

	var trims: Array = out["trims"]
	var fixtures: Array = out["fixtures"]
	var offset: float = rng.randf_range(-along * 0.25, along * 0.25)
	var door_w: float = clampf(along * 0.22, 1.8, 3.6)

	# Ступени: три плиты разной глубины.
	for step: int in range(3):
		var depth: float = 1.6 - float(step) * 0.45
		trims.append(_side_box(side, center, 0.12 + float(step) * 0.18, offset, door_w + 1.6 - float(step) * 0.4, 0.18, depth))

	# Козырёк и две колонны под ним.
	trims.append(_side_box(side, center, 3.35, offset, door_w + 1.8, 0.3, 2.0))
	trims.append(_side_box(side, center, 1.65, offset - (door_w + 1.4) * 0.5, 0.35, 3.3, 0.35, -1.5))
	trims.append(_side_box(side, center, 1.65, offset + (door_w + 1.4) * 0.5, 0.35, 3.3, 0.35, -1.5))

	# Дверной портал и само полотно.
	trims.append(_side_box(side, center, 1.4, offset - door_w * 0.5, 0.25, 2.8, 0.4))
	trims.append(_side_box(side, center, 1.4, offset + door_w * 0.5, 0.25, 2.8, 0.4))
	trims.append(_side_box(side, center, 2.9, offset, door_w + 0.5, 0.3, 0.4))
	fixtures.append(_side_box(side, center, 1.05, offset, door_w * 0.9, 2.1, 0.12))

	# Фонари у входа: коробка + точечный свет, иначе крыльцо ночью не видно.
	var lamp_color: Color = Color(1.0, 0.85, 0.6)
	if not palette.is_empty():
		lamp_color = palette[rng.randi_range(0, palette.size() - 1)].lerp(Color(1.0, 0.9, 0.75), 0.5)
	var facing: Vector3 = side["facing"]
	var tangent: Vector3 = side["tangent"]
	var half: float = float(side["half"])
	for dir: int in [-1, 1]:
		var lamp_offset: float = offset + float(dir) * (door_w * 0.5 + 0.75)
		fixtures.append(_side_box(side, center, 2.55, lamp_offset, 0.3, 0.3, 0.3))
		(out["lights"] as Array).append({
			"position": Vector3(center.x, 2.45, center.z) + facing * (half + 0.8) + tangent * lamp_offset,
			"color": lamp_color,
			"energy": 1.5,
			"range": 9.0,
		})


# ============================================================== кровельное хозяйство

## Водяные баки на опорах, вентблоки, вытяжные трубы, антенны и тарелки.
## Геометрию берём с вершины, которую посчитал [method _build_massing], иначе
## оборудование повисло бы в воздухе над уступами.
static func _build_roofscape(out: Dictionary, center: Vector3, rng: RandomNumberGenerator, density: float, detail_level: int) -> void:
	var top_y: float = float(out.get("roof_top_y", 0.0))
	var roof: Vector2 = out.get("roof_size", Vector2.ZERO)
	if top_y <= 0.0 or roof.x < 3.0 or roof.y < 3.0:
		return

	var masses: Array = out["masses"]
	var fixtures: Array = out["fixtures"]
	var pipes: Array = out["pipes"]
	var limit_x: float = roof.x * 0.35
	var limit_z: float = roof.y * 0.35

	# Водяной бак на четырёх опорах — главный акцент силуэта крыши.
	if roof.x > 6.0 and roof.y > 6.0 and rng.randf() < 0.55 + 0.3 * density:
		var tank_r: float = clampf(minf(roof.x, roof.y) * 0.18, 1.1, 2.6)
		var tank_h: float = rng.randf_range(2.0, 3.4)
		var legs_h: float = rng.randf_range(1.2, 2.2)
		var tx: float = center.x + rng.randf_range(-limit_x, limit_x)
		var tz: float = center.z + rng.randf_range(-limit_z, limit_z)
		pipes.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(tank_r * 2.0, tank_h, tank_r * 2.0)),
			Vector3(tx, top_y + legs_h + tank_h * 0.5, tz)
		))
		for corner: Vector2 in [Vector2(-1.0, -1.0), Vector2(1.0, -1.0), Vector2(-1.0, 1.0), Vector2(1.0, 1.0)]:
			fixtures.append(Transform3D(
				Basis.IDENTITY.scaled(Vector3(0.16, legs_h, 0.16)),
				Vector3(tx + corner.x * tank_r * 0.7, top_y + legs_h * 0.5, tz + corner.y * tank_r * 0.7)
			))

	# Вентиляционные блоки и вытяжки.
	var units: int = clampi(int(round(rng.randf_range(2.0, 5.0) * (0.5 + density))), 1, 7)
	for _i: int in range(units):
		var unit := Vector3(rng.randf_range(1.0, 2.4), rng.randf_range(0.7, 1.6), rng.randf_range(1.0, 2.4))
		var ux: float = center.x + rng.randf_range(-limit_x, limit_x)
		var uz: float = center.z + rng.randf_range(-limit_z, limit_z)
		masses.append({
			"transform": Transform3D(Basis.IDENTITY.scaled(unit), Vector3(ux, top_y + unit.y * 0.5, uz)),
			"tint": Color(0.32, 0.34, 0.38),
			"custom": Color(rng.randf(), 0.02, 0.0, 0.0),
		})
		if rng.randf() < 0.6:
			var duct_h: float = rng.randf_range(0.8, 2.2)
			pipes.append(Transform3D(
				Basis.IDENTITY.scaled(Vector3(0.34, duct_h, 0.34)),
				Vector3(ux, top_y + unit.y + duct_h * 0.5, uz)
			))

	# Антенны с поперечинами и спутниковая тарелка.
	var masts: int = 1 if detail_level == 2 else rng.randi_range(1, 3)
	for _i: int in range(masts):
		var mast_h: float = rng.randf_range(3.0, 9.0)
		var mx: float = center.x + rng.randf_range(-limit_x, limit_x)
		var mz: float = center.z + rng.randf_range(-limit_z, limit_z)
		pipes.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(0.12, mast_h, 0.12)),
			Vector3(mx, top_y + mast_h * 0.5, mz)
		))
		for guy: int in range(3):
			var arm: Transform3D = Transform3D(
				Basis.IDENTITY.scaled(Vector3(rng.randf_range(0.6, 1.4), 0.06, 0.06)),
				Vector3(mx, top_y + mast_h * rng.randf_range(0.4, 0.95), mz)
			)
			arm.basis = arm.basis.rotated(Vector3.UP, float(guy) * 1.05)
			fixtures.append(arm)

	if detail_level >= 3 and rng.randf() < 0.5:
		var dish_r: float = rng.randf_range(0.7, 1.4)
		var dish: Transform3D = Transform3D(
			Basis.IDENTITY.scaled(Vector3(dish_r, 0.14, dish_r)),
			Vector3(
				center.x + rng.randf_range(-limit_x, limit_x),
				top_y + 0.7,
				center.z + rng.randf_range(-limit_z, limit_z)
			)
		)
		dish.basis = dish.basis.rotated(Vector3.RIGHT, rng.randf_range(0.5, 1.0))
		fixtures.append(dish)


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
	return NoirFacadeExtras.count(out)
