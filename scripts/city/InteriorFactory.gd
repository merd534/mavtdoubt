class_name NoirInteriorFactory
extends RefCounted
## Интерьеры зданий: подвал, подъезд, коридоры, обставленные квартиры,
## лестничные пролёты, рабочий лифт и разветвлённые вентшахты.
##
## Строятся **лениво** — только для здания, к которому подошёл игрок, и
## выгружаются, когда он ушёл. Генерировать интерьеры всем домам сразу
## бессмысленно: игрок физически не может быть в двух подъездах.
##
## Два входа в фабрику:
##   • [method build] — по идентификатору локации атласа (отель, участок, клуб);
##   • [method build_for] — по данным любого здания города. Именно он
##     позволяет зайти в любой рядовой дом, а не только в сюжетный.
##
## Геометрия собирается в 4 MultiMesh (стены, полы, мебель, металл) плюс два
## StaticBody3D — интерьер целиком стоит около 6 вызовов отрисовки.
## Мебель и её коллизии вынесены в отдельные узлы: ФАЗА 4 умеет выгружать
## их отдельно от каркаса здания (см. [method unload_furniture]).
##
## Фасад снаружи рисуется с `cull_back`, поэтому изнутри он не мешает.
##
## Свет. Внутри было почти ничего не видно, поэтому теперь: коридоры и
## лестничная клетка светятся всегда, квартирные светильники горят почти
## всегда, а настоящих источников шесть вместо трёх и с большим радиусом.

const FLOOR_HEIGHT := 3.4
const WALL_THICKNESS := 0.22
const SLAB_THICKNESS := 0.25
const CORRIDOR_WIDTH := 2.4
const DOOR_WIDTH := 1.1
const MAX_GENERATED_FLOORS := 8
const MIN_ROOM := 3.2
const VENT_SIZE := 0.8
const ELEVATOR_WIDTH := 2.2
const STAIR_RUN := 3.6
const STAIR_STEPS := 12
## Сколько подземных уровней максимум. Два — потолок: глубже игроку
## уже некуда идти, а геометрия растёт линейно.
const MAX_BASEMENTS := 2
## Мебель видна только вблизи: в коридоре через стену её всё равно не видно.
const FURNITURE_VISIBLE_TO := 32.0
## Меньше этого пятна строить нечего: внутри не помещается даже коридор.
const MIN_FOOTPRINT := 7.0
## Настоящие источники света на один интерьер и их параметры.
const MAX_INTERIOR_LIGHTS := 6
const LIGHT_ENERGY := 2.8
const LIGHT_RANGE := 10.0


## Собирает интерьер для локации атласа. Возвращает узел или null.
static func build(location_id: String) -> Node3D:
	var loc: Dictionary = CityAtlas.get_location(location_id)
	if loc.is_empty():
		Log.warn("InteriorFactory", "Интерьер запрошен для неизвестной локации", {"id": location_id})
		return null

	var kind: int = int(loc["kind"])
	if NoirBuildingFactory.OPEN_AIR_KINDS.has(kind):
		return null

	var footprint: Vector2 = NoirBuildingFactory.LANDMARK_FOOTPRINT.get(kind, Vector2(22.0, 18.0))
	if footprint.x < MIN_ROOM * 2.0 or footprint.y < CORRIDOR_WIDTH + MIN_ROOM * 2.0:
		footprint = Vector2(maxf(footprint.x, 14.0), maxf(footprint.y, 12.0))

	return _assemble(
		location_id,
		loc["position"] as Vector2,
		footprint,
		int(loc["floors"]),
		true
	)


## Собирает интерьер по данным входа, которые пришли из `BuildingFactory`.
## Обязательные ключи: `location_id`, `footprint` (Vector2), `floors` (int).
## Необязательные: `origin` (Vector2 — центр здания в плане), `atlas` (bool).
##
## Габариты **не раздуваются** до минимума, как у локаций атласа: иначе
## комнаты вылезут сквозь фасад на улицу. Узкий дом просто получает
## открытые этажи без перегородок — чердак или цех, а не квартиры.
static func build_for(entry: Dictionary) -> Node3D:
	if entry.is_empty():
		return null

	var interior_id: String = str(entry.get("location_id", ""))
	if interior_id.is_empty():
		Log.warn("InteriorFactory", "Вход без идентификатора — интерьер не строится")
		return null

	# Сюжетные адреса идут прежним путём: у них свои габариты и этажность.
	if bool(entry.get("atlas", false)):
		return build(interior_id)

	var footprint: Vector2 = entry.get("footprint", Vector2.ZERO)
	if footprint.x < MIN_FOOTPRINT or footprint.y < MIN_FOOTPRINT:
		return null

	# Стены интерьера ставим внутрь коробки фасада, а не вровень с ней:
	# иначе две поверхности совпадают и начинают мерцать.
	footprint = Vector2(footprint.x - 0.35, footprint.y - 0.35)

	var origin: Vector2 = entry.get("origin", Vector2.ZERO)
	var floors: int = maxi(1, int(entry.get("floors", 1)))
	return _assemble(interior_id, origin, footprint, floors, false)


## Общая сборка. [param rich] — сюжетное здание: у него чаще два подвала.
static func _assemble(interior_id: String, origin: Vector2, footprint: Vector2, requested_floors: int, rich: bool) -> Node3D:
	var floors: int = clampi(requested_floors, 1, MAX_GENERATED_FLOORS)
	if requested_floors > MAX_GENERATED_FLOORS:
		Log.debug("InteriorFactory", "Этажность урезана для генерации", {
			"id": interior_id, "запрошено": requested_floors, "строим": floors,
		})

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(interior_id) ^ CityAtlas.city_seed

	# Подвал есть почти всегда: это основной скрытный путь детектива.
	var basements: int = 1
	if footprint.x < 9.0 or footprint.y < 9.0:
		basements = 0 if rng.randf() < 0.45 else 1
	if rich and rng.randf() < 0.25 and footprint.x > 18.0:
		basements = MAX_BASEMENTS

	var root := Node3D.new()
	root.name = "Interior_" + interior_id
	root.position = Vector3(origin.x, 0.0, origin.y)

	# Списки боксов по материалам: собираем данные, потом заливаем в MultiMesh.
	var walls: Array[Transform3D] = []
	var slabs: Array[Transform3D] = []
	var furniture: Array[Transform3D] = []
	var metal: Array[Transform3D] = []
	var lamps: Array[Dictionary] = []
	var rooms: Array[Dictionary] = []

	var inner := Vector2(footprint.x - WALL_THICKNESS * 2.0, footprint.y - WALL_THICKNESS * 2.0)

	for floor_index: int in range(-basements, floors):
		var y: float = float(floor_index) * FLOOR_HEIGHT
		_build_slab(slabs, footprint, y)
		_build_perimeter(walls, footprint, y)
		if floor_index < 0:
			_build_basement_plan(walls, furniture, metal, lamps, rooms, inner, y, floor_index, interior_id, rng)
		else:
			_build_floor_plan(walls, furniture, lamps, rooms, inner, y, floor_index, interior_id, rng)

	# Крышка верхнего этажа.
	_build_slab(slabs, footprint, float(floors) * FLOOR_HEIGHT)

	_build_stairwell(metal, walls, footprint, floors, basements)
	# Лифт только там, где для шахты есть место рядом с лестницей.
	if footprint.x > STAIR_RUN + ELEVATOR_WIDTH + 2.0 and floors > 1:
		_build_elevator(root, metal, walls, footprint, floors, basements)
	_build_vents(metal, footprint, floors, basements, rng)

	# Свет лестничной клетки на каждом уровне. Без него подъезд — чёрный
	# колодец, и игрок вошёл в дом буквально вслепую.
	var core_x: float = -footprint.x * 0.5 + WALL_THICKNESS + STAIR_RUN * 0.5
	var core_z: float = -footprint.y * 0.5 + 1.2
	for floor_index: int in range(-basements, floors):
		lamps.append({
			"position": Vector3(core_x, float(floor_index) * FLOOR_HEIGHT + FLOOR_HEIGHT - 0.5, core_z),
			"lit": true,
		})

	_emit_multimesh(root, "Walls", walls, CityMaterials.interior_wall, 0.0)
	_emit_multimesh(root, "Slabs", slabs, CityMaterials.interior_floor, 0.0)
	_emit_multimesh(root, "Furniture", furniture, CityMaterials.furniture, FURNITURE_VISIBLE_TO)
	_emit_multimesh(root, "Metal", metal, CityMaterials.metal, 0.0)
	_emit_lamps(root, lamps)
	_emit_collision(root, "Collision", [walls, slabs, metal], 0.0)
	# Коллизии мебели — отдельное тело: его можно убить вместе с мебелью.
	_emit_collision(root, "FurnitureCollision", [furniture], 0.4)

	root.set_meta("location_id", interior_id)
	root.set_meta("floors", floors)
	root.set_meta("basements", basements)
	root.set_meta("rooms", rooms)

	Log.info("InteriorFactory", "Интерьер построен", {
		"здание": interior_id, "этажей": floors, "подвалов": basements,
		"комнат": rooms.size(), "стен": walls.size(), "мебели": furniture.size(),
		"светильников": lamps.size(),
	})
	return root


# ============================================== ФАЗА 4: выгрузка мебели

## Полностью удаляет мебель и её коллизии из памяти, оставляя каркас
## здания. Используется, когда игрок вышел из здания, но ещё близко и сносить
## весь интерьер рано.
static func unload_furniture(root: Node3D) -> bool:
	if root == null or not is_instance_valid(root):
		return false
	var removed: bool = false
	for node_name: String in ["Furniture", "FurnitureCollision"]:
		var node: Node = root.get_node_or_null(node_name)
		if node != null:
			node.queue_free()
			removed = true
	if removed:
		Log.debug("InteriorFactory", "Мебель выгружена", {"интерьер": root.name})
	return removed


## Мягкий вариант: мебель остаётся в памяти, но не рисуется и не участвует
## в физике. Дешевле, чем повторная генерация, когда игрок ходит туда-сюда.
static func set_furniture_active(root: Node3D, active: bool) -> void:
	if root == null or not is_instance_valid(root):
		return
	var mesh: Node = root.get_node_or_null("Furniture")
	if mesh is MultiMeshInstance3D:
		(mesh as MultiMeshInstance3D).visible = active
	var body: Node = root.get_node_or_null("FurnitureCollision")
	if body is StaticBody3D:
		(body as StaticBody3D).collision_layer = 1 if active else 0


## Кабина лифта интерьера, если она была создана.
static func elevator(root: Node3D) -> NoirElevatorCar:
	if root == null or not is_instance_valid(root):
		return null
	return root.get_node_or_null("ElevatorCar") as NoirElevatorCar


# ------------------------------------------------------------------ оболочка

static func _build_slab(slabs: Array[Transform3D], footprint: Vector2, y: float) -> void:
	slabs.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(footprint.x, SLAB_THICKNESS, footprint.y)),
		Vector3(0.0, y - SLAB_THICKNESS * 0.5, 0.0)
	))


static func _build_perimeter(walls: Array[Transform3D], footprint: Vector2, y: float) -> void:
	var h: float = FLOOR_HEIGHT - SLAB_THICKNESS
	var cy: float = y + h * 0.5

	walls.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(footprint.x, h, WALL_THICKNESS)),
		Vector3(0.0, cy, -footprint.y * 0.5)
	))
	walls.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(footprint.x, h, WALL_THICKNESS)),
		Vector3(0.0, cy, footprint.y * 0.5)
	))
	walls.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(WALL_THICKNESS, h, footprint.y)),
		Vector3(-footprint.x * 0.5, cy, 0.0)
	))
	walls.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(WALL_THICKNESS, h, footprint.y)),
		Vector3(footprint.x * 0.5, cy, 0.0)
	))


# ---------------------------------------------------------------- планировка

## Коридор по оси X, квартиры по обе стороны. Двери — разрывы в стене коридора.
static func _build_floor_plan(walls: Array[Transform3D], furniture: Array[Transform3D], lamps: Array[Dictionary], rooms: Array[Dictionary], inner: Vector2, y: float, floor_index: int, location_id: String, rng: RandomNumberGenerator) -> void:
	var h: float = FLOOR_HEIGHT - SLAB_THICKNESS
	var cy: float = y + h * 0.5

	# Свет в коридоре ставим всегда и до любых ранних выходов из функции:
	# игрок заходит с улицы и должен видеть проход, а не чёрное пятно.
	var corridor_lamps: int = clampi(int(inner.x / 4.0), 1, 6)
	for i: int in range(corridor_lamps):
		var lx: float = -inner.x * 0.5 + inner.x * (float(i) + 0.5) / float(corridor_lamps)
		lamps.append({"position": Vector3(lx, y + FLOOR_HEIGHT - 0.4, 0.0), "lit": true})

	var side_depth: float = (inner.y - CORRIDOR_WIDTH) * 0.5
	if side_depth < MIN_ROOM:
		# Слишком узкое здание — оставляем открытый этаж, но со светом
		# и парой предметов: голая коробка выглядит как ошибка генератора.
		var open_rect := Rect2(Vector2(-inner.x * 0.5, -inner.y * 0.5), inner)
		rooms.append({
			"id": "%s_f%d_open" % [location_id, floor_index],
			"floor": floor_index,
			"rect": open_rect,
			"center": Vector3(0.0, y + 1.0, 0.0),
		})
		_furnish(furniture, lamps, open_rect, y, rng)
		return

	# Ядро с лестницей и лифтом занимает левый край: квартиры начинаются правее.
	var core_width: float = STAIR_RUN + ELEVATOR_WIDTH + 1.0
	var usable_x: float = inner.x - core_width
	if usable_x < MIN_ROOM:
		# Маленький дом: только лестничная клетка и одна комната.
		var small_rect := Rect2(
			Vector2(-inner.x * 0.5 + core_width * 0.5, -inner.y * 0.5),
			Vector2(maxf(2.0, inner.x - core_width * 0.5), inner.y)
		)
		rooms.append({
			"id": "%s_f%d_small" % [location_id, floor_index],
			"floor": floor_index,
			"rect": small_rect,
			"center": Vector3(small_rect.get_center().x, y + 1.0, small_rect.get_center().y),
		})
		_furnish(furniture, lamps, small_rect, y, rng)
		return

	var room_count: int = clampi(int(usable_x / rng.randf_range(4.5, 7.0)), 1, 6)
	var room_width: float = usable_x / float(room_count)
	var start_x: float = -inner.x * 0.5 + core_width

	for side: int in [-1, 1]:
		var room_center_z: float = float(side) * (CORRIDOR_WIDTH * 0.5 + side_depth * 0.5)

		# Стена вдоль коридора с дверными проёмами.
		var corridor_wall_z: float = float(side) * CORRIDOR_WIDTH * 0.5
		for i: int in range(room_count):
			var x0: float = start_x + float(i) * room_width
			var door_center: float = x0 + room_width * 0.5
			var left_len: float = maxf(0.0, (door_center - DOOR_WIDTH * 0.5) - x0)
			var right_len: float = maxf(0.0, (x0 + room_width) - (door_center + DOOR_WIDTH * 0.5))

			if left_len > 0.05:
				walls.append(Transform3D(
					Basis.IDENTITY.scaled(Vector3(left_len, h, WALL_THICKNESS)),
					Vector3(x0 + left_len * 0.5, cy, corridor_wall_z)
				))
			if right_len > 0.05:
				walls.append(Transform3D(
					Basis.IDENTITY.scaled(Vector3(right_len, h, WALL_THICKNESS)),
					Vector3(x0 + room_width - right_len * 0.5, cy, corridor_wall_z)
				))

			# Перегородка между квартирами.
			if i > 0:
				walls.append(Transform3D(
					Basis.IDENTITY.scaled(Vector3(WALL_THICKNESS, h, side_depth)),
					Vector3(x0, cy, room_center_z)
				))

			var room_rect := Rect2(
				Vector2(x0, room_center_z - side_depth * 0.5),
				Vector2(room_width, side_depth)
			)
			rooms.append({
				"id": "%s_f%d_%s%d" % [location_id, floor_index, "n" if side < 0 else "s", i],
				"floor": floor_index,
				"rect": room_rect,
				"center": Vector3(room_rect.get_center().x, y + 1.0, room_rect.get_center().y),
			})

			_furnish(furniture, lamps, room_rect, y, rng)


## Подвал: кладовые с сетчатыми перегородками, котельная, ящики. Коридор
## шире, чем на жилых этажах, а дверей нет — только проёмы.
static func _build_basement_plan(walls: Array[Transform3D], furniture: Array[Transform3D], metal: Array[Transform3D], lamps: Array[Dictionary], rooms: Array[Dictionary], inner: Vector2, y: float, floor_index: int, location_id: String, rng: RandomNumberGenerator) -> void:
	var h: float = FLOOR_HEIGHT - SLAB_THICKNESS
	var cy: float = y + h * 0.5
	var corridor: float = CORRIDOR_WIDTH + 0.8
	var side_depth: float = (inner.y - corridor) * 0.5
	if side_depth < 2.0:
		# Совсем маленький подвал — один открытый объём с парой ящиков.
		lamps.append({"position": Vector3(0.0, y + FLOOR_HEIGHT - 0.5, 0.0), "lit": rng.randf() < 0.8})
		return

	var cell_count: int = clampi(int(inner.x / rng.randf_range(3.0, 4.5)), 1, 8)
	var cell_width: float = inner.x / float(cell_count)

	for side: int in [-1, 1]:
		var center_z: float = float(side) * (corridor * 0.5 + side_depth * 0.5)
		for i: int in range(cell_count):
			var x0: float = -inner.x * 0.5 + float(i) * cell_width

			# Перегородка кладовки.
			if i > 0:
				walls.append(Transform3D(
					Basis.IDENTITY.scaled(Vector3(WALL_THICKNESS, h, side_depth)),
					Vector3(x0, cy, center_z)
				))
			# Сетка вдоль коридора: только верхняя перекладина и стойки,
			# чтобы внутрь можно было заглянуть и заметить улику.
			metal.append(Transform3D(
				Basis.IDENTITY.scaled(Vector3(cell_width, 0.12, 0.1)),
				Vector3(x0 + cell_width * 0.5, y + h - 0.2, float(side) * corridor * 0.5)
			))
			metal.append(Transform3D(
				Basis.IDENTITY.scaled(Vector3(0.1, h, 0.1)),
				Vector3(x0 + 0.05, cy, float(side) * corridor * 0.5)
			))

			var cell_rect := Rect2(
				Vector2(x0, center_z - side_depth * 0.5),
				Vector2(cell_width, side_depth)
			)
			rooms.append({
				"id": "%s_b%d_%s%d" % [location_id, absi(floor_index), "n" if side < 0 else "s", i],
				"floor": floor_index,
				"rect": cell_rect,
				"center": Vector3(cell_rect.get_center().x, y + 1.0, cell_rect.get_center().y),
				"basement": true,
			})

			# Штабель ящиков или стеллаж.
			var stack: int = rng.randi_range(0, 3)
			var stack_y: float = y
			for _s: int in range(stack):
				var crate := Vector3(
					minf(1.1, cell_width * 0.5),
					rng.randf_range(0.4, 0.7),
					minf(1.1, side_depth * 0.45)
				)
				furniture.append(Transform3D(
					Basis.IDENTITY.rotated(Vector3.UP, rng.randf_range(-0.3, 0.3)).scaled(crate),
					Vector3(
						cell_rect.get_center().x + rng.randf_range(-0.3, 0.3),
						stack_y + crate.y * 0.5,
						cell_rect.get_center().y + rng.randf_range(-0.3, 0.3)
					)
				))
				stack_y += crate.y

		# Аварийный свет в подвале. Раньше он горел в четырёх случаях из десяти,
		# и подвал был просто чёрным экраном.
		lamps.append({
			"position": Vector3(float(side) * inner.x * 0.2, y + FLOOR_HEIGHT - 0.5, 0.0),
			"lit": rng.randf() < 0.85,
		})

	# Коридорные лампы подвала: по ним игрок видит, куда идёт.
	var basement_lamps: int = clampi(int(inner.x / 5.0), 1, 5)
	for i: int in range(basement_lamps):
		var lx: float = -inner.x * 0.5 + inner.x * (float(i) + 0.5) / float(basement_lamps)
		lamps.append({"position": Vector3(lx, y + FLOOR_HEIGHT - 0.45, 0.0), "lit": true})

	# Котельная: два бака и трубы под потолком коридора.
	metal.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(1.6, 2.2, 1.6)),
		Vector3(-inner.x * 0.5 + 1.6, y + 1.1, 0.0)
	))
	metal.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(inner.x - 1.0, 0.28, 0.28)),
		Vector3(0.0, y + h - 0.5, 0.35)
	))


## Обстановка квартиры. Всё — боксы, но расставленные осмысленно: кровать к
## стене, стол по центру, шкаф в угол. Игроку важно, что комнату можно обыскать.
static func _furnish(furniture: Array[Transform3D], lamps: Array[Dictionary], room: Rect2, y: float, rng: RandomNumberGenerator) -> void:
	var center: Vector2 = room.get_center()

	# Потолочный светильник. Погашенные квартиры остались для настроения,
	# но их теперь меньшинство: в темноте комнату невозможно обыскать.
	lamps.append({
		"position": Vector3(center.x, y + FLOOR_HEIGHT - 0.45, center.y),
		"lit": rng.randf() < 0.9,
	})

	if room.size.x < 2.4 or room.size.y < 2.4:
		return

	# Кровать или диван у длинной стены.
	var bed_size := Vector3(minf(2.0, room.size.x * 0.55), 0.5, minf(1.4, room.size.y * 0.45))
	furniture.append(Transform3D(
		Basis.IDENTITY.scaled(bed_size),
		Vector3(room.position.x + bed_size.x * 0.5 + 0.35, y + bed_size.y * 0.5, room.position.y + bed_size.z * 0.5 + 0.3)
	))
	# Спинка кровати — мелочь, но без неё квартира выглядит складом кубов.
	furniture.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(bed_size.x, 0.7, 0.12)),
		Vector3(room.position.x + bed_size.x * 0.5 + 0.35, y + 0.6, room.position.y + 0.24)
	))

	# Стол и два стула.
	var table_size := Vector3(minf(1.3, room.size.x * 0.35), 0.75, minf(0.8, room.size.y * 0.3))
	var table_pos := Vector3(center.x + rng.randf_range(-0.4, 0.4), y + table_size.y * 0.5, center.y + rng.randf_range(-0.3, 0.3))
	furniture.append(Transform3D(Basis.IDENTITY.scaled(table_size), table_pos))
	for chair: int in [-1, 1]:
		furniture.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(0.42, 0.85, 0.42)),
			Vector3(table_pos.x + float(chair) * (table_size.x * 0.5 + 0.35), y + 0.42, table_pos.z)
		))

	# Шкаф в дальний угол.
	var wardrobe_size := Vector3(0.65, 2.0, minf(1.2, room.size.y * 0.4))
	furniture.append(Transform3D(
		Basis.IDENTITY.scaled(wardrobe_size),
		Vector3(room.end.x - wardrobe_size.x * 0.5 - 0.3, y + wardrobe_size.y * 0.5, room.end.y - wardrobe_size.z * 0.5 - 0.3)
	))

	# Полка на стене и телевизор/комод.
	furniture.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(minf(1.6, room.size.x * 0.4), 0.08, 0.3)),
		Vector3(center.x, y + 1.55, room.position.y + 0.35)
	))
	furniture.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(minf(1.2, room.size.x * 0.32), 0.55, 0.45)),
		Vector3(center.x, y + 0.28, room.end.y - 0.45)
	))

	# Тумба или стул — сюда удобно прятать улики.
	if rng.randf() < 0.7:
		var stand_size := Vector3(0.5, rng.randf_range(0.45, 0.9), 0.5)
		furniture.append(Transform3D(
			Basis.IDENTITY.scaled(stand_size),
			Vector3(
				room.position.x + rng.randf_range(0.6, maxf(0.7, room.size.x - 0.6)),
				y + stand_size.y * 0.5,
				room.end.y - rng.randf_range(0.5, 1.2)
			)
		))


# ------------------------------------------------- лестница, лифт, вентиляция

## Лестничные пролёты с площадками и перилами, включая спуск в подвал.
## Нечётные пролёты развернуты в обратную сторону — как в реальном подъезде.
static func _build_stairwell(metal: Array[Transform3D], walls: Array[Transform3D], footprint: Vector2, floors: int, basements: int) -> void:
	var x_base: float = -footprint.x * 0.5 + WALL_THICKNESS + STAIR_RUN * 0.5
	var step_height: float = FLOOR_HEIGHT / float(STAIR_STEPS)
	var step_depth: float = STAIR_RUN / float(STAIR_STEPS)
	var z_base: float = -footprint.y * 0.5 + 1.2

	for floor_index: int in range(-basements, maxi(0, floors - 1)):
		var base_y: float = float(floor_index) * FLOOR_HEIGHT
		var flip: bool = absi(floor_index) % 2 == 1
		for step: int in range(STAIR_STEPS):
			var y: float = base_y + float(step + 1) * step_height
			var along: float = float(step) * step_depth + step_depth * 0.5
			var x: float = (
				x_base + STAIR_RUN * 0.5 - along if flip
				else x_base - STAIR_RUN * 0.5 + along
			)
			metal.append(Transform3D(
				Basis.IDENTITY.scaled(Vector3(step_depth, 0.12, 1.4)),
				Vector3(x, y, z_base)
			))

		# Межэтажная площадка.
		metal.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(STAIR_RUN + 0.4, 0.16, 1.6)),
			Vector3(x_base, base_y + FLOOR_HEIGHT, z_base)
		))
		# Перила.
		metal.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(STAIR_RUN + 0.4, 0.08, 0.08)),
			Vector3(x_base, base_y + FLOOR_HEIGHT * 0.5 + 1.0, z_base + 0.75)
		))

	# Ограждение лестничной клетки.
	for floor_index: int in range(-basements, floors):
		walls.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(STAIR_RUN + 0.4, FLOOR_HEIGHT - SLAB_THICKNESS, WALL_THICKNESS)),
			Vector3(x_base, float(floor_index) * FLOOR_HEIGHT + FLOOR_HEIGHT * 0.5, -footprint.y * 0.5 + 2.1)
		))


## Шахта лифта и сама кабина. Кабина — отдельный узел (её нельзя влить
## в MultiMesh, она двигается), остальное — обычные боксы.
static func _build_elevator(root: Node3D, metal: Array[Transform3D], walls: Array[Transform3D], footprint: Vector2, floors: int, basements: int) -> void:
	var x: float = -footprint.x * 0.5 + WALL_THICKNESS + STAIR_RUN + 0.5 + ELEVATOR_WIDTH * 0.5
	var z: float = -footprint.y * 0.5 + 1.5
	var bottom: float = -float(basements) * FLOOR_HEIGHT
	var shaft_height: float = float(floors) * FLOOR_HEIGHT - bottom
	var shaft_center_y: float = bottom + shaft_height * 0.5

	# Стенки шахты (три стороны, четвёртая — двери).
	for side: int in [-1, 1]:
		walls.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(WALL_THICKNESS, shaft_height, ELEVATOR_WIDTH)),
			Vector3(x + float(side) * ELEVATOR_WIDTH * 0.5, shaft_center_y, z)
		))
	walls.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(ELEVATOR_WIDTH, shaft_height, WALL_THICKNESS)),
		Vector3(x, shaft_center_y, z - ELEVATOR_WIDTH * 0.5)
	))

	# Направляющие рельсы — только для вида, но без них шахта пустая.
	for side: int in [-1, 1]:
		metal.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(0.12, shaft_height, 0.12)),
			Vector3(x + float(side) * (ELEVATOR_WIDTH * 0.5 - 0.2), shaft_center_y, z - ELEVATOR_WIDTH * 0.5 + 0.25)
		))

	var car: NoirElevatorCar = NoirElevatorCar.create(
		Vector3(x, bottom, z),
		Vector3(ELEVATOR_WIDTH - 0.3, 2.3, ELEVATOR_WIDTH - 0.3),
		floors + basements,
		FLOOR_HEIGHT
	)
	if car != null:
		root.add_child(car)
	else:
		Log.warn("InteriorFactory", "Кабина лифта не создалась — ставлю глухую кабину")
		metal.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(ELEVATOR_WIDTH - 0.3, 2.3, ELEVATOR_WIDTH - 0.3)),
			Vector3(x, bottom + 1.15, z)
		))


## Вентиляция: две вертикальные шахты, горизонтальные короба под потолком
## коридора и ответвления в квартиры. По ним детектив попадает туда, куда
## не пускают двери, а ветвление даёт выбор маршрута, а не один коридор.
static func _build_vents(metal: Array[Transform3D], footprint: Vector2, floors: int, basements: int, rng: RandomNumberGenerator) -> void:
	var bottom: float = -float(basements) * FLOOR_HEIGHT
	var top: float = float(floors) * FLOOR_HEIGHT
	var shaft_height: float = top - bottom
	var x: float = footprint.x * 0.5 - WALL_THICKNESS - VENT_SIZE
	var z: float = footprint.y * 0.5 - WALL_THICKNESS - VENT_SIZE

	# Главный стояк и второй, в противоположном углу.
	metal.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(VENT_SIZE, shaft_height, VENT_SIZE)),
		Vector3(x, bottom + shaft_height * 0.5, z)
	))
	metal.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(VENT_SIZE, shaft_height, VENT_SIZE)),
		Vector3(-x, bottom + shaft_height * 0.5, -z)
	))

	for floor_index: int in range(-basements, floors):
		var y: float = float(floor_index) * FLOOR_HEIGHT + FLOOR_HEIGHT - VENT_SIZE * 0.5 - 0.25

		# Магистральный короб вдоль этажа.
		metal.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(maxf(1.0, footprint.x - WALL_THICKNESS * 2.0 - 1.0), VENT_SIZE, VENT_SIZE)),
			Vector3(0.0, y, z)
		))
		# Перемычка к противоположному стояку — то есть петля, а не тупик.
		metal.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(VENT_SIZE, VENT_SIZE, maxf(1.0, footprint.y - WALL_THICKNESS * 2.0 - 1.0))),
			Vector3(-x, y, 0.0)
		))

		# Ответвления в квартиры: 1-3 коротких рукава с решёткой на конце.
		var branches: int = rng.randi_range(1, 3)
		for _b: int in range(branches):
			var bx: float = rng.randf_range(-footprint.x * 0.35, footprint.x * 0.35)
			var length: float = rng.randf_range(1.6, maxf(2.0, footprint.y * 0.3))
			metal.append(Transform3D(
				Basis.IDENTITY.scaled(Vector3(VENT_SIZE * 0.8, VENT_SIZE * 0.8, length)),
				Vector3(bx, y, z - length * 0.5 - VENT_SIZE * 0.5)
			))
			# Решётка.
			metal.append(Transform3D(
				Basis.IDENTITY.scaled(Vector3(VENT_SIZE * 0.85, VENT_SIZE * 0.85, 0.08)),
				Vector3(bx, y, z - length - VENT_SIZE * 0.5)
			))


# -------------------------------------------------------------------- сборка

static func _emit_multimesh(root: Node3D, node_name: String, transforms: Array[Transform3D], material: Material, visible_to: float) -> void:
	if transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = CityMaterials.box_mesh()
	mm.instance_count = transforms.size()
	for i: int in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])

	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = mm
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if visible_to > 0.0:
		instance.visibility_range_end = visible_to
		instance.visibility_range_end_margin = visible_to * 0.2
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	root.add_child(instance)


## Светильники: эмиссивные панели для всех, настоящий свет — шести штукам,
## иначе подъезд на 8 этажей заведёт сотню источников.
##
## Сами источники берутся НЕ по порядку, а с равномерным шагом по списку:
## иначе всё шесть доставались подвалу и первому этажу, а выше стояла тьма.
static func _emit_lamps(root: Node3D, lamps: Array[Dictionary]) -> void:
	if lamps.is_empty():
		return

	var warm: Color = CityAtlas.palette("window_warm")
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = CityMaterials.box_mesh()
	mm.instance_count = lamps.size()

	# Сколько горящих светильников всего — отсюда шаг выборки.
	var lit_total: int = 0
	for lamp: Dictionary in lamps:
		if bool(lamp.get("lit", false)):
			lit_total += 1
	var step: int = maxi(1, int(ceil(float(maxi(1, lit_total)) / float(MAX_INTERIOR_LIGHTS))))

	var real_lights: int = 0
	var lit_seen: int = 0
	for i: int in range(lamps.size()):
		var lamp: Dictionary = lamps[i]
		var lit: bool = bool(lamp["lit"])
		mm.set_instance_transform(i, Transform3D(
			Basis.IDENTITY.scaled(Vector3(0.6, 0.08, 0.6)),
			lamp["position"]
		))
		mm.set_instance_color(i, warm)
		# Погашенный светильник всё равно слабо тлеет: в полной темноте
		# игрок не понимает, где потолок, а где проём.
		mm.set_instance_custom_data(i, Color(float(i) * 0.031, 1.0 if lit else 0.12, 0.0 if lit else 1.0, 0.0))

		if not lit:
			continue
		lit_seen += 1
		if real_lights >= MAX_INTERIOR_LIGHTS or (lit_seen - 1) % step != 0:
			continue

		var light := OmniLight3D.new()
		light.name = "InteriorLight_%d" % real_lights
		light.light_color = warm
		light.light_energy = LIGHT_ENERGY
		light.omni_range = LIGHT_RANGE
		light.omni_attenuation = 1.0
		light.shadow_enabled = false
		light.position = (lamp["position"] as Vector3) - Vector3(0.0, 0.2, 0.0)
		root.add_child(light)
		real_lights += 1

	var instance := MultiMeshInstance3D.new()
	instance.name = "CeilingLights"
	instance.multimesh = mm
	instance.material_override = CityMaterials.neon
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(instance)


## Сборщик тела. [param min_size] отсекает мелочь вроде полок: на них всё
## равно не встанешь, а форм в физике становится вдвое больше.
static func _emit_collision(root: Node3D, node_name: String, groups: Array, min_size: float) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = 1
	body.collision_mask = 0
	root.add_child(body)

	for raw: Variant in groups:
		if not (raw is Array):
			continue
		for entry: Variant in raw as Array:
			if not (entry is Transform3D):
				continue
			var xform: Transform3D = entry as Transform3D
			var size := Vector3(
				xform.basis.x.length(),
				xform.basis.y.length(),
				xform.basis.z.length()
			)
			if min_size > 0.0 and (size.x < min_size or size.y < min_size or size.z < min_size):
				continue
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = size
			shape.shape = box
			shape.position = xform.origin
			shape.basis = xform.basis.orthonormalized()
			body.add_child(shape)
