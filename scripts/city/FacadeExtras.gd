class_name NoirFacadeExtras
extends RefCounted
## ФАЗА 3, вторая половина детализации: внешняя инженерная обвеска
## (пожарные лестницы, трубы, кондиционеры, щитки, кабели) и неон
## (объёмные щиты, голограммы, источники света).
##
## Вынесено из `NoirBuildingDetailer`, чтобы оба файла оставались читаемыми.
## Маленькие геометрические хелперы здесь свои: взаимная ссылка двух классов
## дала бы циклическую зависимость при разборе скриптов.
##
## Как и весь генератор города, класс возвращает только данные: он дописывает
## трансформы в уже созданные массивы словаря `out`, ноды собирает `NoirCityChunk`.

const FLOOR_HEIGHT := 3.4
const LADDER_STEP := 0.45


## Стороны коробки здания: направление наружу, направление вдоль стены,
## половина толщины и длина стены.
static func sides(box_size: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append({"facing": Vector3.RIGHT, "tangent": Vector3.BACK, "half": box_size.x * 0.5, "along": box_size.z})
	out.append({"facing": Vector3.LEFT, "tangent": Vector3.BACK, "half": box_size.x * 0.5, "along": box_size.z})
	out.append({"facing": Vector3.BACK, "tangent": Vector3.RIGHT, "half": box_size.z * 0.5, "along": box_size.x})
	out.append({"facing": Vector3.FORWARD, "tangent": Vector3.RIGHT, "half": box_size.z * 0.5, "along": box_size.x})
	return out


## Бокс, прижатый к стене. [param inset] > 0 — утопить внутрь (ниша).
static func side_box(side: Dictionary, center: Vector3, y: float, offset: float, width: float, box_height: float, depth: float, inset: float = 0.0) -> Transform3D:
	var facing: Vector3 = side["facing"]
	var tangent: Vector3 = side["tangent"]
	var half: float = float(side["half"])
	var pos: Vector3 = Vector3(center.x, y, center.z) + facing * (half + depth * 0.5 - inset) + tangent * offset
	var box_scale: Vector3 = Vector3(depth, box_height, width) if absf(facing.x) > 0.5 else Vector3(width, box_height, depth)
	return Transform3D(Basis.IDENTITY.scaled(box_scale), pos)


## Сколько инстансов уже набралось — по этому числу работает потолок.
static func count(out: Dictionary) -> int:
	var total: int = 0
	for key: String in ["masses", "trims", "niches", "fixtures", "pipes", "cables", "ladders", "billboards", "holograms"]:
		var raw: Variant = out.get(key, null)
		if raw is Array:
			total += (raw as Array).size()
	return total


# ======================================================= внешняя инфраструктура

## Пожарные лестницы с зонами лазания, венттрубы с отводами, кондиционеры
## с капельницами, распределительные щитки и пучки кабелей.
static func build_infrastructure(out: Dictionary, box_size: Vector3, center: Vector3, height: float, cfg: Dictionary, density: float, rng: RandomNumberGenerator, limit: int) -> void:
	var fixtures: Array = out["fixtures"]
	var pipes: Array = out["pipes"]
	var cables: Array = out["cables"]
	var ladders: Array = out["ladders"]
	var climb: Array = out["climb_zones"]
	var drips: Array = out["drips"]

	var wall_list: Array[Dictionary] = sides(box_size)
	if wall_list.is_empty():
		return

	# --- Пожарная лестница: тетивы, ступени, площадки и зона лазания.
	if bool(cfg.get("ladders", true)) and height > 9.0 and rng.randf() < 0.55 + 0.35 * density:
		var side: Dictionary = wall_list[rng.randi_range(0, wall_list.size() - 1)]
		var along: float = float(side["along"])
		var offset: float = rng.randf_range(-along * 0.3, along * 0.3)
		var top: float = height - 1.2
		var rails_w: float = 1.35

		ladders.append(side_box(side, center, top * 0.5, offset - rails_w * 0.5, 0.12, top, 0.14))
		ladders.append(side_box(side, center, top * 0.5, offset + rails_w * 0.5, 0.12, top, 0.14))

		var step_count: int = clampi(int(top / LADDER_STEP), 4, 120)
		for i: int in range(step_count):
			if count(out) >= limit:
				break
			ladders.append(side_box(side, center, 1.0 + float(i) * LADDER_STEP, offset, rails_w, 0.07, 0.12))

		# Площадки каждые три этажа: на них игрок отдыхает и заходит в окно.
		var platform_floor: int = 2
		while float(platform_floor) * FLOOR_HEIGHT < top:
			ladders.append(side_box(side, center, float(platform_floor) * FLOOR_HEIGHT, offset, rails_w + 1.2, 0.14, 1.25))
			ladders.append(side_box(side, center, float(platform_floor) * FLOOR_HEIGHT + 0.55, offset, rails_w + 1.2, 0.08, 1.3))
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

	if not bool(cfg.get("fixtures", true)):
		return

	# --- Переплетения вентиляционных труб: вертикальный стояк + отводы.
	var pipe_runs: int = int(round(rng.randf_range(1.0, 3.0) * density))
	for _r: int in range(pipe_runs):
		if count(out) >= limit:
			break
		var side: Dictionary = wall_list[rng.randi_range(0, wall_list.size() - 1)]
		var along: float = float(side["along"])
		var offset: float = rng.randf_range(-along * 0.42, along * 0.42)
		var radius: float = rng.randf_range(0.16, 0.32)
		var run_top: float = rng.randf_range(height * 0.5, height - 0.5)
		pipes.append(side_box(side, center, run_top * 0.5, offset, radius * 2.0, run_top, radius * 2.0))

		var elbows: int = rng.randi_range(1, 3)
		for _e: int in range(elbows):
			var y: float = rng.randf_range(3.0, maxf(3.5, run_top - 1.0))
			var span: float = rng.randf_range(1.2, minf(6.0, along * 0.35))
			var dir: float = 1.0 if rng.randf() < 0.5 else -1.0
			pipes.append(side_box(side, center, y, offset + dir * span * 0.5, span, radius * 1.8, radius * 1.8))

	# --- Кондиционеры со стекающей водой.
	var ac_count: int = int(round(rng.randf_range(2.0, 7.0) * density))
	for _i: int in range(ac_count):
		if count(out) >= limit:
			break
		var side: Dictionary = wall_list[rng.randi_range(0, wall_list.size() - 1)]
		var along: float = float(side["along"])
		var offset: float = rng.randf_range(-along * 0.42, along * 0.42)
		var y: float = rng.randf_range(3.4, maxf(4.0, minf(height - 1.5, 30.0)))
		var unit := Vector3(rng.randf_range(0.8, 1.25), rng.randf_range(0.55, 0.85), 0.55)
		fixtures.append(side_box(side, center, y, offset, unit.x, unit.y, unit.z))
		fixtures.append(side_box(side, center, y - unit.y * 0.5 - 0.08, offset, unit.x * 0.9, 0.1, unit.z * 0.9))

		if bool(cfg.get("drips", true)) and rng.randf() < 0.55:
			var facing: Vector3 = side["facing"]
			var tangent: Vector3 = side["tangent"]
			var half: float = float(side["half"])
			drips.append(Vector3(center.x, y - unit.y * 0.6, center.z) + facing * (half + 0.45) + tangent * offset)

	# --- Щитки у земли.
	var boxes: int = int(round(rng.randf_range(1.0, 3.0) * density))
	for _i: int in range(boxes):
		var side: Dictionary = wall_list[rng.randi_range(0, wall_list.size() - 1)]
		var along: float = float(side["along"])
		fixtures.append(side_box(
			side, center, rng.randf_range(1.2, 2.1), rng.randf_range(-along * 0.4, along * 0.4),
			rng.randf_range(0.45, 0.8), rng.randf_range(0.6, 0.95), 0.28
		))

	# --- Пучки свисающих кабелей с лёгким наклоном.
	if not bool(cfg.get("cables", true)):
		return
	var bundles: int = int(round(rng.randf_range(1.0, 4.0) * density))
	for _i: int in range(bundles):
		if count(out) >= limit:
			break
		var side: Dictionary = wall_list[rng.randi_range(0, wall_list.size() - 1)]
		var along: float = float(side["along"])
		var offset: float = rng.randf_range(-along * 0.4, along * 0.4)
		var from_y: float = rng.randf_range(4.0, maxf(4.5, minf(height - 1.0, 24.0)))
		var strands: int = rng.randi_range(2, 4)
		for s: int in range(strands):
			var length: float = rng.randf_range(2.0, minf(from_y - 1.0, 9.0))
			if length <= 0.5:
				continue
			var lateral: float = offset + float(s) * 0.09 + rng.randf_range(-0.12, 0.12)
			var xform: Transform3D = side_box(side, center, from_y - length * 0.5, lateral, 0.05, length, 0.05)
			# Строго вертикальные провода выглядят нарисованными — даём наклон.
			var tilt: float = rng.randf_range(-0.09, 0.09)
			xform.basis = xform.basis.rotated(Vector3(side["tangent"]), tilt)
			cables.append(xform)


# ==================================================================== неон

## Объёмные щиты и голограммы. Они не только светятся сами, но и дают
## настоящий OmniLight — иначе неон не попадает на мокрый асфальт.
static func build_neon(out: Dictionary, box_size: Vector3, center: Vector3, height: float, palette: Array[Color], cfg: Dictionary, density: float, rng: RandomNumberGenerator) -> void:
	if palette.is_empty():
		return
	var billboards: Array = out["billboards"]
	var holograms: Array = out["holograms"]
	var lights: Array = out["lights"]
	var wall_list: Array[Dictionary] = sides(box_size)
	if wall_list.is_empty():
		return
	var light_budget: int = maxi(0, int(cfg.get("billboard_lights", 2)))

	if bool(cfg.get("billboards", true)):
		var signs: int = clampi(int(round(rng.randf_range(1.0, 3.0) * (0.4 + density))), 1, 4)
		for _i: int in range(signs):
			var side: Dictionary = wall_list[rng.randi_range(0, wall_list.size() - 1)]
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
				"transform": side_box(side, center, y, offset, w, h, depth),
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

	if bool(cfg.get("holograms", true)) and height > 18.0 and rng.randf() < 0.3 * (0.5 + density):
		var side: Dictionary = wall_list[rng.randi_range(0, wall_list.size() - 1)]
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
