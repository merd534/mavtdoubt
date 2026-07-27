class_name NoirInteriorFactory
extends RefCounted
## Интерьеры зданий: подъезд, коридоры, обставленные квартиры, лестничные
## пролёты, шахта лифта и вентиляция.
##
## Строятся **лениво** — только для здания, к которому подошёл игрок, и
## выгружаются, когда он ушёл. Генерировать интерьеры всем 237 адресам сразу
## бессмысленно: игрок физически не может быть в двух подъездах.
##
## Геометрия собирается в 4 MultiMesh (стены, полы, мебель, металл) плюс один
## StaticBody3D — интерьер целиком стоит около 5 вызовов отрисовки.
##
## Фасад снаружи рисуется с `cull_back`, поэтому изнутри он не мешает: стены
## здания прозрачны при взгляде изнутри, и интерьер видно без ухищрений.

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


## Собирает интерьер для локации. Возвращает узел или null, если строить нечего.
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

	var floors: int = clampi(int(loc["floors"]), 1, MAX_GENERATED_FLOORS)
	if int(loc["floors"]) > MAX_GENERATED_FLOORS:
		Log.debug("InteriorFactory", "Этажность урезана для генерации", {
			"id": location_id, "в_атласе": int(loc["floors"]), "строим": floors,
		})

	var origin: Vector2 = loc["position"]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(location_id) ^ CityAtlas.city_seed

	var root := Node3D.new()
	root.name = "Interior_" + location_id
	root.position = Vector3(origin.x, 0.0, origin.y)

	# Списки боксов по материалам: собираем данные, потом заливаем в MultiMesh.
	var walls: Array[Transform3D] = []
	var slabs: Array[Transform3D] = []
	var furniture: Array[Transform3D] = []
	var metal: Array[Transform3D] = []
	var lamps: Array[Dictionary] = []
	var rooms: Array[Dictionary] = []

	var inner := Vector2(footprint.x - WALL_THICKNESS * 2.0, footprint.y - WALL_THICKNESS * 2.0)

	for floor_index: int in range(floors):
		var y: float = float(floor_index) * FLOOR_HEIGHT
		_build_slab(slabs, footprint, y)
		_build_perimeter(walls, footprint, y)
		_build_floor_plan(walls, furniture, lamps, rooms, inner, y, floor_index, location_id, rng)

	# Крышка верхнего этажа.
	_build_slab(slabs, footprint, float(floors) * FLOOR_HEIGHT)

	_build_stairwell(metal, walls, footprint, floors)
	_build_elevator(metal, walls, footprint, floors)
	_build_vents(metal, footprint, floors)

	_emit_multimesh(root, "Walls", walls, CityMaterials.interior_wall)
	_emit_multimesh(root, "Slabs", slabs, CityMaterials.interior_floor)
	_emit_multimesh(root, "Furniture", furniture, CityMaterials.furniture)
	_emit_multimesh(root, "Metal", metal, CityMaterials.metal)
	_emit_lamps(root, lamps)
	_emit_collision(root, walls, slabs, metal)

	root.set_meta("location_id", location_id)
	root.set_meta("floors", floors)
	root.set_meta("rooms", rooms)

	Log.info("InteriorFactory", "Интерьер построен", {
		"локация": location_id, "этажей": floors, "комнат": rooms.size(),
		"стен": walls.size(), "мебели": furniture.size(),
	})
	return root


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

	var side_depth: float = (inner.y - CORRIDOR_WIDTH) * 0.5
	if side_depth < MIN_ROOM:
		return  # слишком узкое здание — оставляем открытый этаж

	# Ядро с лестницей и лифтом занимает левый край: квартиры начинаются правее.
	var core_width: float = STAIR_RUN + ELEVATOR_WIDTH + 1.0
	var usable_x: float = inner.x - core_width
	if usable_x < MIN_ROOM:
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


## Обстановка квартиры. Всё — боксы, но расставленные осмысленно: кровать к
## стене, стол по центру, шкаф в угол. Игроку важно, что комнату можно обыскать.
static func _furnish(furniture: Array[Transform3D], lamps: Array[Dictionary], room: Rect2, y: float, rng: RandomNumberGenerator) -> void:
	var center: Vector2 = room.get_center()

	# Потолочный светильник.
	lamps.append({
		"position": Vector3(center.x, y + FLOOR_HEIGHT - 0.45, center.y),
		"lit": rng.randf() < 0.45,
	})

	if room.size.x < 2.4 or room.size.y < 2.4:
		return

	# Кровать или диван у длинной стены.
	var bed_size := Vector3(minf(2.0, room.size.x * 0.55), 0.5, minf(1.4, room.size.y * 0.45))
	furniture.append(Transform3D(
		Basis.IDENTITY.scaled(bed_size),
		Vector3(room.position.x + bed_size.x * 0.5 + 0.35, y + bed_size.y * 0.5, room.position.y + bed_size.z * 0.5 + 0.3)
	))

	# Стол.
	var table_size := Vector3(minf(1.3, room.size.x * 0.35), 0.75, minf(0.8, room.size.y * 0.3))
	furniture.append(Transform3D(
		Basis.IDENTITY.scaled(table_size),
		Vector3(center.x + rng.randf_range(-0.4, 0.4), y + table_size.y * 0.5, center.y + rng.randf_range(-0.3, 0.3))
	))

	# Шкаф в дальний угол.
	var wardrobe_size := Vector3(0.65, 2.0, minf(1.2, room.size.y * 0.4))
	furniture.append(Transform3D(
		Basis.IDENTITY.scaled(wardrobe_size),
		Vector3(room.end.x - wardrobe_size.x * 0.5 - 0.3, y + wardrobe_size.y * 0.5, room.end.y - wardrobe_size.z * 0.5 - 0.3)
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

static func _build_stairwell(metal: Array[Transform3D], walls: Array[Transform3D], footprint: Vector2, floors: int) -> void:
	var x_base: float = -footprint.x * 0.5 + WALL_THICKNESS + STAIR_RUN * 0.5
	var step_height: float = FLOOR_HEIGHT / float(STAIR_STEPS)
	var step_depth: float = STAIR_RUN / float(STAIR_STEPS)

	for floor_index: int in range(maxi(0, floors - 1)):
		var base_y: float = float(floor_index) * FLOOR_HEIGHT
		for step: int in range(STAIR_STEPS):
			var y: float = base_y + float(step + 1) * step_height
			var x: float = x_base - STAIR_RUN * 0.5 + float(step) * step_depth + step_depth * 0.5
			metal.append(Transform3D(
				Basis.IDENTITY.scaled(Vector3(step_depth, 0.12, 1.4)),
				Vector3(x, y, -footprint.y * 0.5 + 1.2)
			))

	# Ограждение лестничной клетки.
	for floor_index: int in range(floors):
		walls.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(STAIR_RUN + 0.4, FLOOR_HEIGHT - SLAB_THICKNESS, WALL_THICKNESS)),
			Vector3(x_base, float(floor_index) * FLOOR_HEIGHT + FLOOR_HEIGHT * 0.5, -footprint.y * 0.5 + 2.1)
		))


static func _build_elevator(metal: Array[Transform3D], walls: Array[Transform3D], footprint: Vector2, floors: int) -> void:
	var x: float = -footprint.x * 0.5 + WALL_THICKNESS + STAIR_RUN + 0.5 + ELEVATOR_WIDTH * 0.5
	var z: float = -footprint.y * 0.5 + 1.5
	var shaft_height: float = float(floors) * FLOOR_HEIGHT

	# Стенки шахты (три стороны, четвёртая — двери).
	for side: int in [-1, 1]:
		walls.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(WALL_THICKNESS, shaft_height, ELEVATOR_WIDTH)),
			Vector3(x + float(side) * ELEVATOR_WIDTH * 0.5, shaft_height * 0.5, z)
		))
	walls.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(ELEVATOR_WIDTH, shaft_height, WALL_THICKNESS)),
		Vector3(x, shaft_height * 0.5, z - ELEVATOR_WIDTH * 0.5)
	))

	# Кабина стоит на первом этаже.
	metal.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(ELEVATOR_WIDTH - 0.3, 2.3, ELEVATOR_WIDTH - 0.3)),
		Vector3(x, 1.15, z)
	))


## Вентиляция: вертикальная шахта через все этажи плюс горизонтальные короба
## под потолком коридора. По ним детектив попадает туда, куда не пускают двери.
static func _build_vents(metal: Array[Transform3D], footprint: Vector2, floors: int) -> void:
	var shaft_height: float = float(floors) * FLOOR_HEIGHT
	var x: float = footprint.x * 0.5 - WALL_THICKNESS - VENT_SIZE
	var z: float = footprint.y * 0.5 - WALL_THICKNESS - VENT_SIZE

	metal.append(Transform3D(
		Basis.IDENTITY.scaled(Vector3(VENT_SIZE, shaft_height, VENT_SIZE)),
		Vector3(x, shaft_height * 0.5, z)
	))

	for floor_index: int in range(floors):
		var y: float = float(floor_index) * FLOOR_HEIGHT + FLOOR_HEIGHT - VENT_SIZE * 0.5 - 0.25
		metal.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(footprint.x - WALL_THICKNESS * 2.0 - 1.0, VENT_SIZE, VENT_SIZE)),
			Vector3(0.0, y, z)
		))


# -------------------------------------------------------------------- сборка

static func _emit_multimesh(root: Node3D, node_name: String, transforms: Array[Transform3D], material: Material) -> void:
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
	root.add_child(instance)


## Светильники: эмиссивные панели для всех, настоящий свет — только паре штук,
## иначе подъезд на 8 этажей заведёт сотню источников.
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

	var real_lights: int = 0
	for i: int in range(lamps.size()):
		var lamp: Dictionary = lamps[i]
		var lit: bool = bool(lamp["lit"])
		mm.set_instance_transform(i, Transform3D(
			Basis.IDENTITY.scaled(Vector3(0.6, 0.08, 0.6)),
			lamp["position"]
		))
		mm.set_instance_color(i, warm)
		# Погашенный светильник — почти нулевая яркость и «битый» флаг.
		mm.set_instance_custom_data(i, Color(float(i) * 0.031, 0.85 if lit else 0.04, 0.0 if lit else 1.0, 0.0))

		if lit and real_lights < 3:
			var light := OmniLight3D.new()
			light.light_color = warm
			light.light_energy = 1.1
			light.omni_range = 6.5
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


static func _emit_collision(root: Node3D, walls: Array[Transform3D], slabs: Array[Transform3D], metal: Array[Transform3D]) -> void:
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = 1
	body.collision_mask = 0
	root.add_child(body)

	for group: Array[Transform3D] in [walls, slabs, metal]:
		for xform: Transform3D in group:
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(
				xform.basis.x.length(),
				xform.basis.y.length(),
				xform.basis.z.length()
			)
			shape.shape = box
			shape.position = xform.origin
			body.add_child(shape)
