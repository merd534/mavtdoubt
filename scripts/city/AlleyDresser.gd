class_name NoirAlleyDresser
extends RefCounted
## ФАЗА 3. Подворотни на стыках зданий.
##
## Ищет узкие щели между соседними участками застройки и заваливает их
## мусорными баками, картонными коробками, трубами и паром. Работает по тем же
## правилам, что и остальная генерация: только данные, полный детерминизм от
## (city_seed, координаты щели), никаких нод.
##
## Почему не просто разбросать мусор вокруг здания: узнаваемость нуара даёт
## именно щель между двумя стенами, куда игрок сворачивает с улицы. Поэтому
## реквизит ставится строго в найденные проходы, а не по кольцу вокруг дома.

const MIN_GAP := 0.9        ## уже — не проход, а щель между плитами
const MAX_GAP := 5.5        ## шире — это уже улица, а не подворотня
const MAX_SPOTS := 14       ## потолок подворотен на чанк
const MAX_PAIRS_SCANNED := 4000


static func generate(buildings: Variant, city_seed: int, budget: Variant) -> Dictionary:
	var out: Dictionary = {
		"debris": [] as Array[Transform3D],   # баки — металл
		"boxes": [] as Array[Transform3D],    # картон
		"pipes": [] as Array[Transform3D],    # трубы, из которых идёт пар
		"steam": [] as Array[Dictionary],     # точки эмиттеров GPU-частиц
		"lights": [] as Array[Dictionary],    # тусклая лампа над задней дверью
		"spots": [] as Array[Dictionary],
	}

	if not (buildings is Array):
		return out
	var list: Array = buildings as Array
	if list.size() < 2:
		return out

	var cfg: Dictionary = NoirBuildingDetailer.budget_defaults()
	if budget is Dictionary:
		for key: Variant in (budget as Dictionary).keys():
			cfg[key] = (budget as Dictionary)[key]
	if int(cfg.get("level", 0)) != 0:
		return out

	var density: float = clampf(float(cfg.get("density", 0.7)), 0.0, 1.0)
	if density <= 0.01:
		return out
	var want_debris: bool = bool(cfg.get("debris", true))
	var want_steam: bool = bool(cfg.get("steam", true))

	var spots: Array[Dictionary] = _find_spots(list)
	if spots.is_empty():
		return out

	var allowed: int = clampi(int(round(float(MAX_SPOTS) * (0.35 + density * 0.65))), 1, MAX_SPOTS)
	var used: int = 0
	for spot: Dictionary in spots:
		if used >= allowed:
			break
		used += 1
		var center: Vector2 = spot["center"]
		var rng := RandomNumberGenerator.new()
		var h: int = city_seed ^ (int(center.x * 37.0) * 668265263) ^ (int(center.y * 41.0) * 374761393)
		rng.seed = absi(h) | 0x11

		(out["spots"] as Array).append(spot)
		_dress(out, spot, rng, density, want_debris, want_steam)

	Log.debug("AlleyDresser", "Подворотни готовы", {
		"мест": used,
		"баки": (out["debris"] as Array).size(),
		"коробки": (out["boxes"] as Array).size(),
		"пар": (out["steam"] as Array).size(),
	})
	return out


## Ищет пары зданий, между которыми остался узкий проход.
static func _find_spots(list: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var scanned: int = 0

	for i: int in range(list.size()):
		var a: Variant = list[i]
		if not (a is Dictionary):
			continue
		var ra: Variant = (a as Dictionary).get("rect", null)
		if not (ra is Rect2):
			continue
		var rect_a: Rect2 = ra as Rect2

		for j: int in range(i + 1, list.size()):
			scanned += 1
			if scanned > MAX_PAIRS_SCANNED or out.size() >= MAX_SPOTS * 3:
				return out
			var b: Variant = list[j]
			if not (b is Dictionary):
				continue
			var rb: Variant = (b as Dictionary).get("rect", null)
			if not (rb is Rect2):
				continue
			var rect_b: Rect2 = rb as Rect2
			var wall_height: float = minf(
				float((a as Dictionary).get("height", 12.0)),
				float((b as Dictionary).get("height", 12.0))
			)

			# Щель по X: прямоугольники перекрываются по Z и разнесены по X.
			var overlap_z: float = minf(rect_a.end.y, rect_b.end.y) - maxf(rect_a.position.y, rect_b.position.y)
			var gap_x: float = maxf(rect_a.position.x, rect_b.position.x) - minf(rect_a.end.x, rect_b.end.x)
			if overlap_z > 3.0 and gap_x >= MIN_GAP and gap_x <= MAX_GAP:
				var x: float = (minf(rect_a.end.x, rect_b.end.x) + maxf(rect_a.position.x, rect_b.position.x)) * 0.5
				var z: float = (maxf(rect_a.position.y, rect_b.position.y) + minf(rect_a.end.y, rect_b.end.y)) * 0.5
				out.append({
					"center": Vector2(x, z),
					"along": Vector3.BACK,
					"across": Vector3.RIGHT,
					"width": gap_x,
					"length": overlap_z,
					"wall_height": wall_height,
				})
				continue

			# Щель по Z.
			var overlap_x: float = minf(rect_a.end.x, rect_b.end.x) - maxf(rect_a.position.x, rect_b.position.x)
			var gap_z: float = maxf(rect_a.position.y, rect_b.position.y) - minf(rect_a.end.y, rect_b.end.y)
			if overlap_x > 3.0 and gap_z >= MIN_GAP and gap_z <= MAX_GAP:
				var z2: float = (minf(rect_a.end.y, rect_b.end.y) + maxf(rect_a.position.y, rect_b.position.y)) * 0.5
				var x2: float = (maxf(rect_a.position.x, rect_b.position.x) + minf(rect_a.end.x, rect_b.end.x)) * 0.5
				out.append({
					"center": Vector2(x2, z2),
					"along": Vector3.RIGHT,
					"across": Vector3.BACK,
					"width": gap_z,
					"length": overlap_x,
					"wall_height": wall_height,
				})

	return out


static func _dress(out: Dictionary, spot: Dictionary, rng: RandomNumberGenerator, density: float, want_debris: bool, want_steam: bool) -> void:
	var center: Vector2 = spot["center"]
	var along: Vector3 = spot["along"]
	var across: Vector3 = spot["across"]
	var width: float = float(spot["width"])
	var length: float = float(spot["length"])
	var wall_height: float = float(spot.get("wall_height", 12.0))
	var base := Vector3(center.x, 0.0, center.y)
	var half_len: float = maxf(1.0, length * 0.5 - 1.0)
	var half_wide: float = maxf(0.2, width * 0.5 - 0.35)

	if want_debris:
		# Мусорные баки у стены, слегка развёрнутые.
		var bins: int = clampi(int(round(rng.randf_range(1.0, 4.0) * density)), 1, 5)
		for _i: int in range(bins):
			var bin_size := Vector3(rng.randf_range(0.9, 1.35), rng.randf_range(1.0, 1.4), rng.randf_range(0.7, 1.05))
			var side_sign: float = 1.0 if rng.randf() < 0.5 else -1.0
			var pos: Vector3 = base + along * rng.randf_range(-half_len, half_len) + across * (half_wide * side_sign * rng.randf_range(0.3, 1.0))
			pos.y = bin_size.y * 0.5
			var bin_basis := Basis.IDENTITY.rotated(Vector3.UP, rng.randf_range(-0.35, 0.35)).scaled(bin_size)
			(out["debris"] as Array).append(Transform3D(bin_basis, pos))

		# Картонные коробки штабелями.
		var stacks: int = clampi(int(round(rng.randf_range(1.0, 3.0) * density)), 1, 4)
		for _s: int in range(stacks):
			var stack_pos: Vector3 = base + along * rng.randf_range(-half_len, half_len) + across * rng.randf_range(-half_wide, half_wide)
			var layers: int = rng.randi_range(1, 3)
			var y: float = 0.0
			for _l: int in range(layers):
				var box_size := Vector3(rng.randf_range(0.4, 0.75), rng.randf_range(0.3, 0.5), rng.randf_range(0.4, 0.75))
				var box_basis := Basis.IDENTITY.rotated(Vector3.UP, rng.randf_range(-0.6, 0.6)).scaled(box_size)
				var pos: Vector3 = stack_pos + Vector3(rng.randf_range(-0.1, 0.1), y + box_size.y * 0.5, rng.randf_range(-0.1, 0.1))
				(out["boxes"] as Array).append(Transform3D(box_basis, pos))
				y += box_size.y

	# Горизонтальный ствол вдоль подворотни. Базовый цилиндр стоит вертикально,
	# поэтому сначала масштаб, потом поворот вокруг поперечной оси.
	var pipe_y: float = rng.randf_range(2.2, 3.6)
	var run: float = maxf(2.0, length * 0.8)
	var pipe_r: float = rng.randf_range(0.14, 0.26)
	var pipe_basis := Basis.IDENTITY.scaled(Vector3(pipe_r * 2.0, run, pipe_r * 2.0))
	if along == Vector3.BACK:
		pipe_basis = pipe_basis.rotated(Vector3.RIGHT, PI * 0.5)
	else:
		pipe_basis = pipe_basis.rotated(Vector3.FORWARD, PI * 0.5)
	(out["pipes"] as Array).append(Transform3D(pipe_basis, base + Vector3(0.0, pipe_y, 0.0) + across * half_wide * 0.8))

	var risers: int = rng.randi_range(1, 3)
	for _i: int in range(risers):
		var riser_h: float = rng.randf_range(2.5, maxf(3.0, wall_height * 0.5))
		var pos: Vector3 = base + along * rng.randf_range(-half_len, half_len) + across * half_wide * 0.85
		pos.y = riser_h * 0.5
		(out["pipes"] as Array).append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(pipe_r * 1.8, riser_h, pipe_r * 1.8)), pos
		))

	# Пар из труб и решёток. Эмиттеры — самое дорогое в подворотне, поэтому
	# их число режется плотностью в первую очередь.
	if want_steam:
		var vents: int = clampi(int(round(rng.randf_range(1.0, 3.0) * density)), 1, 3)
		for _i: int in range(vents):
			var from_ground: bool = rng.randf() < 0.55
			var pos: Vector3 = base + along * rng.randf_range(-half_len, half_len) + across * rng.randf_range(-half_wide, half_wide)
			pos.y = 0.15 if from_ground else pipe_y - pipe_r
			(out["steam"] as Array).append({
				"position": pos,
				"strength": rng.randf_range(0.6, 1.0) if from_ground else rng.randf_range(0.35, 0.7),
				"width": clampf(width * 0.6, 0.4, 2.0),
			})

	# Одна дежурная лампа: подворотня должна читаться, а не быть чёрной дырой.
	if rng.randf() < 0.7:
		(out["lights"] as Array).append({
			"position": base + Vector3(0.0, rng.randf_range(2.6, 3.4), 0.0) + across * half_wide * 0.7,
			"color": CityAtlas.palette("sodium_amber"),
			"energy": rng.randf_range(0.8, 1.6),
			"range": rng.randf_range(7.0, 12.0),
		})
