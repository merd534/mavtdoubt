class_name NoirTowerDetailer
extends RefCounted
## Архитектура высотных зданий. Превращает вытянутый бокс в силуэт башни.
##
## Почему отдельно от [NoirBuildingDetailer]: тот работает с фасадом вблизи
## (окна, ниши, лестницы, трубы), а здесь строится крупная форма, которая
## читается с любого расстояния — подиум, уступы, пилястры, вертикальные
## ребра, венец, шпиль, кровельное хозяйство. Именно её отсутствие делало
## небоскрёбы плоскими коробками.
##
## Вся геометрия — оси-выровненные боксы и цилиндры, чтобы уходить в MultiMesh
## без разворотов и без единой текстуры.

const TALL_MIN := 34.0        ## ниже этой высоты башенная логика не нужна
const FLOOR := 3.4
const MAX_PARTS := 260        ## жёсткий потолок элементов на одно здание
const MIN_FIN_STEP := 3.2
const MAX_FINS_PER_SIDE := 14


static func defaults() -> Dictionary:
	return {
		"density": 1.0,
		"podium": true,
		"setbacks": true,
		"pilasters": true,
		"fins": true,
		"crown": true,
		"roof_gear": true,
		"neon": true,
		"max_parts": MAX_PARTS,
	}


static func is_tower(building: Dictionary) -> bool:
	if building.is_empty():
		return false
	var box: Variant = building.get("size", null)
	if not (box is Vector3):
		return false
	var box_size: Vector3 = box
	return box_size.y >= TALL_MIN


static func empty_result() -> Dictionary:
	return {
		"masses": [],      # объёмы с фасадным шейдером (окна продолжаются)
		"concrete": [],    # бетон: пилястры, карнизы, парапеты
		"metal": [],       # металл: ребра, жалюзи техэтажей, антенны
		"glass": [],       # витражные вставки и остеклённые уступы
		"poles": [],       # цилиндры: шпиль, бак, вытяжки
		"neon": [],        # светящиеся полосы венца
		"lights": [],      # маячок на шпиле
		"occluders": [],   # крупные объёмы для окклюзии
		"boxes": [],       # объёмы, которым нужна коллизия
	}


## Главный вход. [param building] — запись из [NoirBuildingFactory]:
## ключи `size`, `center`, `tint`, `custom`.
static func detail(building: Dictionary, cfg: Dictionary) -> Dictionary:
	var out: Dictionary = empty_result()
	if not is_tower(building):
		return out

	var box_size: Vector3 = building.get("size", Vector3.ONE)
	var center: Vector3 = building.get("center", Vector3.ZERO)
	var tint: Color = building.get("tint", Color(0.4, 0.6, 1.0, 1.0))
	var custom: Color = building.get("custom", Color(0.5, 0.35, 0.4, 0.0))

	var density: float = clampf(float(cfg.get("density", 1.0)), 0.0, 1.5)
	if density <= 0.02:
		return out
	var budget: int = maxi(12, int(cfg.get("max_parts", MAX_PARTS)))

	var base_y: float = center.y - box_size.y * 0.5
	var top_y: float = center.y + box_size.y * 0.5
	var height: float = box_size.y
	var footprint: Vector2 = Vector2(box_size.x, box_size.z)
	var plan := Vector2(center.x, center.z)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(int(center.x), int(center.y), int(center.z)))

	var tall: bool = height >= 90.0
	var slim: bool = minf(footprint.x, footprint.y) <= 26.0

	# ------------------------------------------------------------- подиум
	# Первые 2-3 этажа шире корпуса: цоколь, козырёк, витрины.
	if bool(cfg.get("podium", true)):
		var podium_h: float = FLOOR * (3.0 if tall else 2.0)
		var grow: float = 1.7 if tall else 1.2
		var podium_size := Vector3(footprint.x + grow * 2.0, podium_h, footprint.y + grow * 2.0)
		var podium_center := Vector3(plan.x, base_y + podium_h * 0.5, plan.y)
		out["masses"].append({
			"transform": _box(podium_center, podium_size),
			"tint": tint,
			"custom": Color(custom.r, minf(1.0, custom.g + 0.25), custom.b, custom.a),
		})
		out["boxes"].append(_box(podium_center, podium_size))
		out["occluders"].append({"center": podium_center, "size": podium_size})

		# Козырёк по периметру подиума.
		var canopy_y: float = base_y + podium_h + 0.35
		out["concrete"].append(_box(
			Vector3(plan.x, canopy_y, plan.y),
			Vector3(podium_size.x + 1.4, 0.55, podium_size.z + 1.4)
		))
		# Витражная лента первого этажа.
		out["glass"].append(_box(
			Vector3(plan.x, base_y + FLOOR * 0.6, plan.y),
			Vector3(podium_size.x + 0.25, FLOOR * 0.9, podium_size.z + 0.25)
		))

	# ------------------------------------------------------------- уступы
	# Классическая ступенчатая башня: корпус к верху сужается.
	var shaft_top: float = top_y
	if bool(cfg.get("setbacks", true)) and height >= 55.0:
		var tiers: int = 3 if tall else 2
		var tier_plan: Vector2 = footprint
		var tier_base: float = base_y + height * (0.42 if tall else 0.55)
		for i: int in range(tiers):
			if out["masses"].size() >= budget:
				break
			var shrink: float = 0.86 if slim else 0.78
			tier_plan = Vector2(maxf(6.0, tier_plan.x * shrink), maxf(6.0, tier_plan.y * shrink))
			var tier_h: float = (top_y - tier_base) / float(tiers - i) * (1.0 if i == tiers - 1 else 0.9)
			if tier_h < FLOOR * 1.5:
				break
			var tier_center := Vector3(plan.x, tier_base + tier_h * 0.5, plan.y)
			var tier_size := Vector3(tier_plan.x, tier_h, tier_plan.y)
			out["masses"].append({
				"transform": _box(tier_center, tier_size),
				"tint": tint,
				"custom": custom,
			})
			out["occluders"].append({"center": tier_center, "size": tier_size})
			# Карниз на границе уступа.
			out["concrete"].append(_box(
				Vector3(plan.x, tier_base + 0.4, plan.y),
				Vector3(tier_plan.x + 2.2, 0.8, tier_plan.y + 2.2)
			))
			shaft_top = tier_base + tier_h
			tier_base += tier_h * 0.72

	# ------------------------------------------------------------- пилястры
	# Четыре угловые лопатки во всю высоту: главный признак объёма.
	if bool(cfg.get("pilasters", true)):
		var pil_w: float = clampf(minf(footprint.x, footprint.y) * 0.09, 0.7, 2.4)
		var pil_h: float = height + 1.2
		var pil_y: float = base_y + pil_h * 0.5
		var hx: float = footprint.x * 0.5
		var hz: float = footprint.y * 0.5
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				out["concrete"].append(_box(
					Vector3(plan.x + sx * hx, pil_y, plan.y + sz * hz),
					Vector3(pil_w * 2.2, pil_h, pil_w * 2.2)
				))

	# ------------------------------------------------------------- вертикальные ребра
	# Ребра между окнами: с земли дают глубокую светотень, издалека — фактуру.
	if bool(cfg.get("fins", true)):
		var fin_from: float = base_y + FLOOR * 3.0
		var fin_h: float = maxf(FLOOR, shaft_top - fin_from - 1.0)
		var fin_y: float = fin_from + fin_h * 0.5
		var fin_depth: float = 0.42
		var fin_width: float = 0.38
		for axis: int in range(2):
			var span: float = footprint.x if axis == 0 else footprint.y
			var step_count: int = clampi(int(span / MIN_FIN_STEP), 2, MAX_FINS_PER_SIDE)
			step_count = maxi(2, int(round(float(step_count) * clampf(density, 0.3, 1.0))))
			for i: int in range(step_count):
				if out["metal"].size() >= budget:
					break
				var t: float = (float(i) + 0.5) / float(step_count) - 0.5
				var offset: float = t * span
				var out_x: float = footprint.x * 0.5 + fin_depth * 0.5
				var out_z: float = footprint.y * 0.5 + fin_depth * 0.5
				if axis == 0:
					for sz: float in [-1.0, 1.0]:
						out["metal"].append(_box(
							Vector3(plan.x + offset, fin_y, plan.y + sz * out_z),
							Vector3(fin_width, fin_h, fin_depth)
						))
				else:
					for sx: float in [-1.0, 1.0]:
						out["metal"].append(_box(
							Vector3(plan.x + sx * out_x, fin_y, plan.y + offset),
							Vector3(fin_depth, fin_h, fin_width)
						))

	# ------------------------------------------------------------- техэтажи
	# Тёмные пояса с жалюзи на 1/3 и 2/3 высоты — разбивают монотонность.
	var bands: int = 2 if tall else 1
	for i: int in range(bands):
		var band_y: float = base_y + height * (0.34 + 0.31 * float(i))
		if band_y > shaft_top - FLOOR:
			continue
		out["concrete"].append(_box(
			Vector3(plan.x, band_y, plan.y),
			Vector3(footprint.x + 1.1, FLOOR * 0.9, footprint.y + 1.1)
		))
		var louvers: int = clampi(int(footprint.x / 4.0), 2, 8)
		for j: int in range(louvers):
			var lt: float = (float(j) + 0.5) / float(louvers) - 0.5
			out["metal"].append(_box(
				Vector3(plan.x + lt * footprint.x * 0.9, band_y, plan.y + footprint.y * 0.5 + 0.7),
				Vector3(footprint.x / float(louvers) * 0.7, FLOOR * 0.6, 0.3)
			))

	# ------------------------------------------------------------- венец
	var crown_top: float = shaft_top
	if bool(cfg.get("crown", true)):
		var crown_plan := Vector2(footprint.x, footprint.y)
		var step_h: float = FLOOR * 1.3
		var steps: int = 3 if tall else 2
		for i: int in range(steps):
			crown_plan *= 0.72
			if minf(crown_plan.x, crown_plan.y) < 3.0:
				break
			var crown_center := Vector3(plan.x, crown_top + step_h * 0.5, plan.y)
			out["concrete"].append(_box(crown_center, Vector3(crown_plan.x, step_h, crown_plan.y)))
			crown_top += step_h

		# Парапет по кровле корпуса.
		out["concrete"].append(_box(
			Vector3(plan.x, shaft_top + 0.6, plan.y),
			Vector3(footprint.x + 0.4, 1.2, footprint.y + 0.4)
		))

		# Шпиль с маячком.
		if tall:
			var mast_h: float = clampf(height * 0.16, 6.0, 42.0)
			out["poles"].append(_box(
				Vector3(plan.x, crown_top + mast_h * 0.5, plan.y),
				Vector3(0.9, mast_h, 0.9)
			))
			out["lights"].append({
				"position": Vector3(plan.x, crown_top + mast_h, plan.y),
				"color": Color(1.0, 0.16, 0.22),
				"energy": 2.4,
				"range": 26.0,
			})
			out["neon"].append({
				"transform": _box(
					Vector3(plan.x, crown_top + mast_h, plan.y),
					Vector3(1.6, 1.6, 1.6)
				),
				"tint": Color(1.0, 0.2, 0.26),
				"custom": Color(rng.randf(), 0.55, 1.0, 0.0),
			})

		# Светящаяся лента венца в цвете района.
		if bool(cfg.get("neon", true)):
			for sz: float in [-1.0, 1.0]:
				out["neon"].append({
					"transform": _box(
						Vector3(plan.x, shaft_top - FLOOR * 0.8, plan.y + sz * (footprint.y * 0.5 + 0.35)),
						Vector3(footprint.x * 0.92, 0.5, 0.22)
					),
					"tint": tint,
					"custom": Color(rng.randf(), 0.35, 0.0, 0.0),
				})
			for sx: float in [-1.0, 1.0]:
				out["neon"].append({
					"transform": _box(
						Vector3(plan.x + sx * (footprint.x * 0.5 + 0.35), shaft_top - FLOOR * 0.8, plan.y),
						Vector3(0.22, 0.5, footprint.y * 0.92)
					),
					"tint": tint,
					"custom": Color(rng.randf(), 0.35, 0.0, 0.0),
				})

	# ------------------------------------------------------------- кровля
	if bool(cfg.get("roof_gear", true)):
		var roof_y: float = shaft_top
		var gear: int = clampi(int(round(3.0 * density)), 1, 5)
		for i: int in range(gear):
			var gx: float = rng.randf_range(-0.32, 0.32) * footprint.x
			var gz: float = rng.randf_range(-0.32, 0.32) * footprint.y
			var gh: float = rng.randf_range(1.6, 3.4)
			out["metal"].append(_box(
				Vector3(plan.x + gx, roof_y + gh * 0.5, plan.y + gz),
				Vector3(rng.randf_range(1.8, 4.2), gh, rng.randf_range(1.8, 4.2))
			))
		# Водяной бак на опорах.
		var tank_h: float = rng.randf_range(3.0, 5.0)
		var tank_r: float = rng.randf_range(1.6, 2.6)
		var tank_x: float = plan.x + rng.randf_range(-0.25, 0.25) * footprint.x
		var tank_z: float = plan.y + rng.randf_range(-0.25, 0.25) * footprint.y
		out["poles"].append(_box(
			Vector3(tank_x, roof_y + 2.2 + tank_h * 0.5, tank_z),
			Vector3(tank_r * 2.0, tank_h, tank_r * 2.0)
		))
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				out["metal"].append(_box(
					Vector3(tank_x + sx * tank_r * 0.7, roof_y + 1.1, tank_z + sz * tank_r * 0.7),
					Vector3(0.24, 2.2, 0.24)
				))
		# Антенны.
		var antennas: int = clampi(int(round(2.0 * density)), 1, 4)
		for i: int in range(antennas):
			var ah: float = rng.randf_range(4.0, 11.0)
			out["metal"].append(_box(
				Vector3(
					plan.x + rng.randf_range(-0.4, 0.4) * footprint.x,
					roof_y + ah * 0.5,
					plan.y + rng.randf_range(-0.4, 0.4) * footprint.y
				),
				Vector3(0.16, ah, 0.16)
			))

	return out


## Число элементов в результате — для статистики HUD.
static func count(result: Dictionary) -> int:
	var total: int = 0
	for key: Variant in result.keys():
		var value: Variant = result[key]
		if value is Array:
			total += (value as Array).size()
	return total


static func _box(center: Vector3, box_size: Vector3) -> Transform3D:
	var safe := Vector3(maxf(0.02, box_size.x), maxf(0.02, box_size.y), maxf(0.02, box_size.z))
	return Transform3D(Basis.IDENTITY.scaled(safe), center)
