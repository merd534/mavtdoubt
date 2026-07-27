class_name NoirDistrictInfill
extends RefCounted
## Заполнение дыр между районами.
##
## Проблема: районы в атласе — это прямоугольники, и они не стыкуются встык.
## Между ними остаются полосы и карманы, которые ни один район не застраивает
## (а «Окраины» — только фолбэк для запросов, они не генерируют геометрию).
## В итоге посреди карты образовывались пустые поля.
##
## Решение: чанк разбивается на клетки, непокрытые клетки сливаются в
## прямоугольники, и каждый такой прямоугольник получает синтетический
## район-«переходник»: параметры и палитра берутся у ближайшего реального
## района, но застройка чуть ниже и мелкозернистее, чтобы переход читался
## как связка между кварталами, а не как клон соседа.
##
## Всё детерминировано по (city_seed, координаты), так же как остальной город.

const CELL := 30.0        ## шаг сетки поиска дыр
const MIN_SIDE := 46.0    ## узкие щели не застраиваем: там и должна быть улица
const GROW := 10.0        ## запас по краю, чтобы кварталы смыкались с соседом
const MAX_GAPS := 6       ## потолок зон на чанк


## Незастроенные зоны внутри чанка. [param covered] — границы реальных
## районов (без «Окраин»).
static func gaps(chunk_rect: Rect2, covered: Array[Rect2]) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if chunk_rect.size.x <= 0.0 or chunk_rect.size.y <= 0.0:
		return out

	var cols: int = maxi(1, int(round(chunk_rect.size.x / CELL)))
	var rows: int = maxi(1, int(round(chunk_rect.size.y / CELL)))
	var cell_w: float = chunk_rect.size.x / float(cols)
	var cell_h: float = chunk_rect.size.y / float(rows)

	var free: Array[bool] = []
	free.resize(cols * rows)
	for j: int in range(rows):
		for i: int in range(cols):
			var center := Vector2(
				chunk_rect.position.x + (float(i) + 0.5) * cell_w,
				chunk_rect.position.y + (float(j) + 0.5) * cell_h
			)
			free[j * cols + i] = _is_free(center, covered)

	# Жадное слияние: сначала вправо, затем вниз пока вся полоса свободна.
	for j: int in range(rows):
		for i: int in range(cols):
			if not free[j * cols + i]:
				continue

			var span: int = 0
			while i + span < cols and free[j * cols + i + span]:
				span += 1

			var depth: int = 1
			var growing: bool = true
			while growing and j + depth < rows:
				for k: int in range(span):
					if not free[(j + depth) * cols + i + k]:
						growing = false
						break
				if growing:
					depth += 1

			for jj: int in range(j, j + depth):
				for ii: int in range(i, i + span):
					free[jj * cols + ii] = false

			var rect := Rect2(
				Vector2(chunk_rect.position.x + float(i) * cell_w, chunk_rect.position.y + float(j) * cell_h),
				Vector2(float(span) * cell_w, float(depth) * cell_h)
			)
			if rect.size.x < MIN_SIDE or rect.size.y < MIN_SIDE:
				continue
			out.append(rect.grow(GROW))
			if out.size() >= MAX_GAPS:
				return out

	return out


## Клетка свободна, если не занята районом и не лежит в русле реки.
static func _is_free(center: Vector2, covered: Array[Rect2]) -> bool:
	if CityAtlas.is_in_river(center):
		return false
	for rect: Rect2 in covered:
		if rect.has_point(center):
			return false
	return true


## Синтетический район для зоны [param rect]. Формат словаря — тот же, что
## у CityAtlas.get_district(), поэтому NoirBuildingFactory работает с ним без правок.
## Ключ "id" остаётся реальным: иначе district_palette() вернёт пустоту
## и все дома в зоне стали бы белыми.
static func district_for(rect: Rect2, city_seed: int) -> Dictionary:
	var center: Vector2 = rect.get_center()
	var best_id: String = ""
	var best_dist: float = INF

	for id: String in CityAtlas.district_ids():
		if id == "outskirts":
			continue
		var candidate: Dictionary = CityAtlas.get_district(id)
		if candidate.is_empty():
			continue
		var bounds: Rect2 = candidate["bounds"]
		var nearest := Vector2(
			clampf(center.x, bounds.position.x, bounds.end.x),
			clampf(center.y, bounds.position.y, bounds.end.y)
		)
		var dist: float = nearest.distance_to(center)
		if dist < best_dist:
			best_dist = dist
			best_id = id

	if best_id.is_empty():
		return {}

	var base: Dictionary = CityAtlas.get_district(best_id)
	if base.is_empty():
		return {}

	var world: Rect2 = CityAtlas.world_bounds()
	var edge: float = clampf(maxf(
		absf(center.x) / maxf(1.0, world.size.x * 0.5),
		absf(center.y) / maxf(1.0, world.size.y * 0.5)
	), 0.0, 1.0)
	var noise: float = _hash01(int(center.x) * 73856093 + int(center.y) * 19349663 + city_seed)

	base["bounds"] = rect
	# Мельче соседа: переходная застройка всегда дробнее ядра квартала.
	base["block"] = clampf(float(base["block"]) * (0.62 + 0.28 * noise), 34.0, 88.0)
	base["street"] = clampf(float(base["street"]) * 0.85, 11.0, 24.0)
	# Плотно в центре карты, разреженно у границ: полей посередине быть не должно,
	# а по краю город обязан плавно разрежаться.
	base["density"] = clampf(0.9 - edge * 0.45, 0.32, 0.92)
	base["height_min"] = maxf(7.0, float(base["height_min"]) * 0.7)
	base["height_max"] = clampf(float(base["height_max"]) * (0.5 + 0.3 * noise), 18.0, 140.0)
	base["neon"] = clampf(float(base["neon"]) * 0.8, 0.08, 0.9)
	base["is_infill"] = true
	return base


static func _hash01(value: int) -> float:
	var h: int = value
	h = (h ^ (h >> 16)) * 0x7FEB352D
	h = (h ^ (h >> 15)) * 0x846CA68B
	h = h ^ (h >> 16)
	return float(absi(h) % 1000003) / 1000003.0
