class_name NoirMetroBuilder
extends RefCounted
## Подземка. Строит реально проходимую сеть метро по данным атласа:
## станции берутся из локаций типа TRANSIT_STATION, перегоны — из
## [method NoirCityAtlas.metro_links].
##
## Что строится на каждой станции:
##   • наземный павильон с козырьком и светящейся буквой над входом;
##   • лестничный марш вниз со ступенями-коллизиями — игрок спускается пешком;
##   • вестибюль с турникетами и колоннами;
##   • платформа с путями, рельсами и устьями туннелей в сторону соседних станций.
##
## Геометрия собирается один раз при старте и не участвует в стриминге чанков:
## станций десятки, а не тысячи. Всё подземное скрывается по
## visibility_range, поэтому издали оно ничего не стоит.

const DEPTH := 9.0                  ## глубина платформы от уровня улицы
const HALL_LENGTH := 46.0           ## длина зала
const HALL_WIDTH := 18.0
const HALL_HEIGHT := 5.2
const PLATFORM_WIDTH := 7.0
const PLATFORM_HEIGHT := 1.1
const TRACK_WIDTH := 4.6
const STAIR_STEPS := 18
const STAIR_WIDTH := 4.0
const STAIR_RUN := 0.62
const KIOSK_SIZE := Vector3(6.4, 3.4, 5.0)
const UNDER_VISIBLE_TO := 140.0     ## дальше этого подземка не рисуется
const KIOSK_VISIBLE_TO := 320.0
const MAX_STATIONS := 24


## Собирает всю сеть и возвращает корневой узел. Никогда не возвращает null.
static func build() -> Node3D:
	var root := Node3D.new()
	root.name = "Metro"

	if CityAtlas == null or not CityAtlas.is_built():
		Log.warn("MetroBuilder", "Атлас не готов — метро не построено")
		return root

	var station_ids: Array[String] = CityAtlas.locations_of_kind(NoirCityAtlas.LocationKind.TRANSIT_STATION)
	if station_ids.is_empty():
		Log.warn("MetroBuilder", "Станций в атласе нет — метро не построено")
		return root

	# Направления перегонов: куда смотрят туннели каждой станции.
	var links: Dictionary = {}
	for link: Dictionary in CityAtlas.metro_links():
		var from_id: String = str(link.get("from", ""))
		var to_id: String = str(link.get("to", ""))
		if from_id.is_empty() or to_id.is_empty():
			continue
		if not links.has(from_id):
			links[from_id] = [] as Array[String]
		(links[from_id] as Array).append(to_id)
		if not links.has(to_id):
			links[to_id] = [] as Array[String]
		(links[to_id] as Array).append(from_id)

	var built: int = 0
	var started: int = Time.get_ticks_usec()
	for station_id: String in station_ids:
		if built >= MAX_STATIONS:
			break
		var loc: Dictionary = CityAtlas.get_location(station_id)
		if loc.is_empty():
			continue
		var plan: Vector2 = loc["position"]
		var yaw: float = _station_yaw(plan, links.get(station_id, [] as Array[String]))
		var station: Node3D = _build_station(station_id, str(loc.get("ru", "Станция")), plan, yaw)
		if station == null:
			continue
		root.add_child(station)
		built += 1

	Log.info("MetroBuilder", "Подземка построена", {
		"станций": built,
		"перегонов": CityAtlas.metro_links().size(),
		"мс": int((Time.get_ticks_usec() - started) / 1000),
	})
	return root


## Ориентация зала: вдоль линии к соседней станции, иначе по оси X.
static func _station_yaw(plan: Vector2, neighbours: Variant) -> float:
	if neighbours is Array and (neighbours as Array).size() > 0:
		var other_id: String = str((neighbours as Array)[0])
		var other: Dictionary = CityAtlas.get_location(other_id)
		if not other.is_empty():
			var target: Vector2 = other["position"]
			var delta: Vector2 = target - plan
			if delta.length() > 1.0:
				return atan2(delta.x, delta.y)
	return 0.0


static func _build_station(station_id: String, title: String, plan: Vector2, yaw: float) -> Node3D:
	var station := Node3D.new()
	station.name = "Station_" + station_id
	station.position = Vector3(plan.x, 0.0, plan.y)
	station.rotation = Vector3(0.0, yaw, 0.0)

	_build_entrance(station, title)
	_build_stairs(station)
	_build_hall(station)
	_build_platform(station)
	return station


# ------------------------------------------------------------------ наземный вход

static func _build_entrance(station: Node3D, title: String) -> void:
	var concrete: Material = CityMaterials.concrete
	var metal: Material = CityMaterials.metal

	# Павильон — три стены и козырёк: четвёртая сторона — проём вниз.
	var half_w: float = KIOSK_SIZE.x * 0.5
	var half_d: float = KIOSK_SIZE.z * 0.5
	var wall_t: float = 0.35

	_add_box(station, "KioskBack", Vector3(KIOSK_SIZE.x, KIOSK_SIZE.y, wall_t),
		Vector3(0.0, KIOSK_SIZE.y * 0.5, -half_d), concrete, true, KIOSK_VISIBLE_TO)
	_add_box(station, "KioskLeft", Vector3(wall_t, KIOSK_SIZE.y, KIOSK_SIZE.z),
		Vector3(-half_w, KIOSK_SIZE.y * 0.5, 0.0), concrete, true, KIOSK_VISIBLE_TO)
	_add_box(station, "KioskRight", Vector3(wall_t, KIOSK_SIZE.y, KIOSK_SIZE.z),
		Vector3(half_w, KIOSK_SIZE.y * 0.5, 0.0), concrete, true, KIOSK_VISIBLE_TO)
	_add_box(station, "KioskRoof", Vector3(KIOSK_SIZE.x + 1.2, 0.3, KIOSK_SIZE.z + 1.4),
		Vector3(0.0, KIOSK_SIZE.y, 0.2), metal, true, KIOSK_VISIBLE_TO)

	# Ограждение проёма: чтобы в дыру не свалиться сбоку.
	for sign: float in [-1.0, 1.0]:
		_add_box(station, "Rail_%d" % int(sign), Vector3(0.16, 1.0, KIOSK_SIZE.z * 1.6),
			Vector3(sign * (half_w + 0.1), 0.5, half_d + KIOSK_SIZE.z * 0.5), metal, true, KIOSK_VISIBLE_TO)

	# Светящаяся вывеска над входом.
	var sign_mat := StandardMaterial3D.new()
	sign_mat.albedo_color = CityAtlas.palette("neon_cyan")
	sign_mat.emission_enabled = true
	sign_mat.emission = CityAtlas.palette("neon_cyan")
	sign_mat.emission_energy_multiplier = 4.0
	sign_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_add_box(station, "MetroSign", Vector3(2.2, 1.0, 0.16),
		Vector3(0.0, KIOSK_SIZE.y + 0.8, half_d + 0.1), sign_mat, false, KIOSK_VISIBLE_TO)

	var lamp := OmniLight3D.new()
	lamp.name = "EntranceLight"
	lamp.position = Vector3(0.0, KIOSK_SIZE.y - 0.6, half_d * 0.2)
	lamp.light_color = CityAtlas.palette("neon_ice")
	lamp.light_energy = 1.6
	lamp.omni_range = 12.0
	lamp.shadow_enabled = false
	lamp.distance_fade_enabled = true
	lamp.distance_fade_begin = 60.0
	lamp.distance_fade_length = 20.0
	station.add_child(lamp)

	var label := Label3D.new()
	label.name = "StationName"
	label.text = title
	label.font_size = 48
	label.pixel_size = 0.012
	label.modulate = Color(0.85, 0.95, 1.0)
	label.position = Vector3(0.0, KIOSK_SIZE.y + 1.7, half_d + 0.12)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.visibility_range_end = KIOSK_VISIBLE_TO
	station.add_child(label)


# --------------------------------------------------------------------- лестница

static func _build_stairs(station: Node3D) -> void:
	var concrete: Material = CityMaterials.concrete
	var step_h: float = DEPTH / float(STAIR_STEPS)
	var start_z: float = KIOSK_SIZE.z * 0.5

	for i: int in range(STAIR_STEPS):
		var y: float = -step_h * (float(i) + 0.5)
		var z: float = start_z + STAIR_RUN * (float(i) + 0.5)
		# Каждая ступень — плита с коллизией: по ним можно ходить.
		_add_box(station, "Step_%d" % i, Vector3(STAIR_WIDTH, step_h, STAIR_RUN * 1.6),
			Vector3(0.0, y, z), concrete, true, UNDER_VISIBLE_TO)

	# Стены лестничного марша.
	var run_len: float = STAIR_RUN * float(STAIR_STEPS)
	for sign: float in [-1.0, 1.0]:
		_add_box(station, "StairWall_%d" % int(sign), Vector3(0.4, DEPTH, run_len),
			Vector3(sign * (STAIR_WIDTH * 0.5 + 0.2), -DEPTH * 0.5, start_z + run_len * 0.5),
			concrete, true, UNDER_VISIBLE_TO)

	var lamp := OmniLight3D.new()
	lamp.name = "StairLight"
	lamp.position = Vector3(0.0, -DEPTH * 0.45, start_z + run_len * 0.5)
	lamp.light_color = Color(0.85, 0.9, 1.0)
	lamp.light_energy = 1.2
	lamp.omni_range = 14.0
	lamp.shadow_enabled = false
	station.add_child(lamp)


# --------------------------------------------------------------------- вестибюль

static func _build_hall(station: Node3D) -> void:
	var concrete: Material = CityMaterials.concrete
	var metal: Material = CityMaterials.metal
	var tile: Material = CityMaterials.interior_floor
	var floor_y: float = -DEPTH
	var center_z: float = KIOSK_SIZE.z * 0.5 + STAIR_RUN * float(STAIR_STEPS) + HALL_LENGTH * 0.5

	# Пол, потолок и четыре стены.
	_add_box(station, "HallFloor", Vector3(HALL_WIDTH, 0.4, HALL_LENGTH),
		Vector3(0.0, floor_y - 0.2, center_z), tile, true, UNDER_VISIBLE_TO)
	_add_box(station, "HallCeiling", Vector3(HALL_WIDTH, 0.4, HALL_LENGTH),
		Vector3(0.0, floor_y + HALL_HEIGHT, center_z), concrete, true, UNDER_VISIBLE_TO)
	for sign: float in [-1.0, 1.0]:
		_add_box(station, "HallWall_%d" % int(sign), Vector3(0.5, HALL_HEIGHT, HALL_LENGTH),
			Vector3(sign * HALL_WIDTH * 0.5, floor_y + HALL_HEIGHT * 0.5, center_z),
			concrete, true, UNDER_VISIBLE_TO)
	_add_box(station, "HallEnd", Vector3(HALL_WIDTH, HALL_HEIGHT, 0.5),
		Vector3(0.0, floor_y + HALL_HEIGHT * 0.5, center_z + HALL_LENGTH * 0.5),
		concrete, true, UNDER_VISIBLE_TO)

	# Турникеты на входе в зал.
	for i: int in range(4):
		var x: float = -4.5 + float(i) * 3.0
		_add_box(station, "Turnstile_%d" % i, Vector3(0.5, 1.1, 1.6),
			Vector3(x, floor_y + 0.55, center_z - HALL_LENGTH * 0.5 + 3.0), metal, true, UNDER_VISIBLE_TO)

	# Колонны по оси зала и свет между ними.
	var columns: int = 5
	for i: int in range(columns):
		var t: float = (float(i) + 0.5) / float(columns)
		var z: float = center_z - HALL_LENGTH * 0.5 + HALL_LENGTH * t
		for sign: float in [-1.0, 1.0]:
			_add_box(station, "Column_%d_%d" % [i, int(sign)], Vector3(0.8, HALL_HEIGHT, 0.8),
				Vector3(sign * 5.4, floor_y + HALL_HEIGHT * 0.5, z), concrete, true, UNDER_VISIBLE_TO)

		if i % 2 == 0:
			var lamp := OmniLight3D.new()
			lamp.name = "HallLight_%d" % i
			lamp.position = Vector3(0.0, floor_y + HALL_HEIGHT - 0.6, z)
			lamp.light_color = Color(0.82, 0.88, 1.0)
			lamp.light_energy = 1.5
			lamp.omni_range = 18.0
			lamp.shadow_enabled = false
			station.add_child(lamp)


# --------------------------------------------------------------------- платформа

static func _build_platform(station: Node3D) -> void:
	var concrete: Material = CityMaterials.concrete
	var metal: Material = CityMaterials.metal
	var floor_y: float = -DEPTH
	var center_z: float = KIOSK_SIZE.z * 0.5 + STAIR_RUN * float(STAIR_STEPS) + HALL_LENGTH * 0.5

	# Две платформы вдоль зала и пути между ними.
	for sign: float in [-1.0, 1.0]:
		_add_box(station, "Platform_%d" % int(sign), Vector3(PLATFORM_WIDTH, PLATFORM_HEIGHT, HALL_LENGTH * 0.86),
			Vector3(sign * (TRACK_WIDTH * 0.5 + PLATFORM_WIDTH * 0.5), floor_y + PLATFORM_HEIGHT * 0.5, center_z),
			concrete, true, UNDER_VISIBLE_TO)

		# Жёлтая предупреждающая полоса у края.
		var warn := StandardMaterial3D.new()
		warn.albedo_color = Color(0.85, 0.62, 0.12)
		warn.emission_enabled = true
		warn.emission = Color(0.9, 0.6, 0.15)
		warn.emission_energy_multiplier = 0.6
		_add_box(station, "PlatformEdge_%d" % int(sign), Vector3(0.5, 0.06, HALL_LENGTH * 0.86),
			Vector3(sign * (TRACK_WIDTH * 0.5 + 0.35), floor_y + PLATFORM_HEIGHT + 0.03, center_z),
			warn, false, UNDER_VISIBLE_TO)

	# Путевое корыто и две рельсы.
	_add_box(station, "TrackBed", Vector3(TRACK_WIDTH, 0.25, HALL_LENGTH),
		Vector3(0.0, floor_y + 0.12, center_z), CityMaterials.interior_floor, true, UNDER_VISIBLE_TO)
	for sign: float in [-1.0, 1.0]:
		_add_box(station, "Rail_%d" % int(sign * 10.0), Vector3(0.16, 0.16, HALL_LENGTH),
			Vector3(sign * 0.75, floor_y + 0.3, center_z), metal, false, UNDER_VISIBLE_TO)

	# Устья туннелей с обеих сторон: тёмный проём и красный сигнал.
	var tunnel_mat := StandardMaterial3D.new()
	tunnel_mat.albedo_color = Color(0.02, 0.02, 0.03)
	tunnel_mat.roughness = 1.0
	var signal_mat := StandardMaterial3D.new()
	signal_mat.albedo_color = CityAtlas.palette("police_red")
	signal_mat.emission_enabled = true
	signal_mat.emission = CityAtlas.palette("police_red")
	signal_mat.emission_energy_multiplier = 3.0
	signal_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	for sign: float in [-1.0, 1.0]:
		var z: float = center_z + sign * (HALL_LENGTH * 0.5 + 6.0)
		_add_box(station, "TunnelMouth_%d" % int(sign), Vector3(TRACK_WIDTH + 1.6, 4.2, 12.0),
			Vector3(0.0, floor_y + 2.1, z), tunnel_mat, false, UNDER_VISIBLE_TO)
		_add_box(station, "TunnelSignal_%d" % int(sign), Vector3(0.3, 0.3, 0.3),
			Vector3(TRACK_WIDTH * 0.5 + 0.6, floor_y + 2.4, z - sign * 5.0), signal_mat, false, UNDER_VISIBLE_TO)


# ------------------------------------------------------------------------ утилиты

## Коробка с материалом и, при необходимости, со статической коллизией.
static func _add_box(parent: Node3D, node_name: String, size: Vector3, position: Vector3, material: Material, collide: bool, visible_to: float) -> void:
	if parent == null:
		return
	var mesh := BoxMesh.new()
	mesh.size = size

	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = position
	if material != null:
		instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if visible_to > 0.0:
		instance.visibility_range_end = visible_to
		instance.visibility_range_end_margin = 20.0
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	parent.add_child(instance)

	if not collide:
		return
	var body := StaticBody3D.new()
	body.name = node_name + "_Body"
	body.position = position
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)
