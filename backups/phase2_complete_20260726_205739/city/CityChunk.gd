class_name NoirCityChunk
extends Node3D
## Один чанк города. Превращает данные `NoirBuildingFactory` в узлы сцены.
##
## Бюджет вызовов отрисовки на чанк держится в районе 6-8 независимо от того,
## сколько в нём зданий: всё однотипное сливается в MultiMesh.
##
##   Buildings   — MultiMesh, куб + facade.gdshader        (1 вызов)
##   Signs       — MultiMesh, квад + neon.gdshader         (1 вызов)
##   Props       — MultiMesh, куб + бетон                  (1 вызов)
##   LampPosts   — MultiMesh, цилиндр + металл             (1 вызов)
##   LampHeads   — MultiMesh, куб + neon.gdshader          (1 вызов)
##   Roads       — 2 ArrayMesh (обычные + магистрали)      (2 вызова)
##   Occluder    — ArrayOccluder3D, геометрия не рисуется  (0 вызовов)
##
## Уровни детализации:
##   0 — вблизи: реквизит, коллизии, настоящие источники света, входы
##   1 — средне: здания, вывески, фонарные столбы, коллизии
##   2 — далеко: только здания и полотно дорог

const DETAIL_NEAR := 0
const DETAIL_MID := 1
const DETAIL_FAR := 2

const MAX_REAL_LIGHTS := 6            ## живых OmniLight3D на ближний чанк
const PROP_VISIBLE_TO := 240.0
const LAMP_POST_VISIBLE_TO := 420.0   ## столбы прячем далеко, светящиеся головы — нет

var coords: Vector2i = Vector2i.ZERO
var rect: Rect2 = Rect2()
var detail_level: int = DETAIL_FAR

var _content: Dictionary = {}
var _built: bool = false
var _build_msec: int = 0

var _buildings_mm: MultiMeshInstance3D = null
var _signs_mm: MultiMeshInstance3D = null
var _props_mm: MultiMeshInstance3D = null
var _posts_mm: MultiMeshInstance3D = null
var _heads_mm: MultiMeshInstance3D = null
var _roads_mesh: MeshInstance3D = null
var _arterial_mesh: MeshInstance3D = null
var _occluder: OccluderInstance3D = null
var _body: StaticBody3D = null
var _lights: Array[OmniLight3D] = []


static func create(chunk_coords: Vector2i, chunk_rect: Rect2, detail: int) -> NoirCityChunk:
	var chunk := NoirCityChunk.new()
	chunk.coords = chunk_coords
	chunk.rect = chunk_rect
	chunk.detail_level = clampi(detail, DETAIL_NEAR, DETAIL_FAR)
	chunk.name = "Chunk_%d_%d" % [chunk_coords.x, chunk_coords.y]
	chunk.position = Vector3.ZERO   # содержимое уже в мировых координатах
	return chunk


## Строит содержимое. Возвращает время сборки в миллисекундах.
func build(city_seed: int) -> int:
	var started: int = Time.get_ticks_usec()

	_content = NoirBuildingFactory.generate(rect, city_seed, detail_level)

	_build_buildings()
	_build_roads()
	# Вывески и фонари строятся на всех LOD — это по одной MultiMesh на чанк,
	# зато без них дальний план становится чёрным полем вместо неонового ковра.
	_build_signs()
	_build_lamps()
	if detail_level == DETAIL_NEAR:
		_build_props()
		_build_collision()
		_build_lights()
	_build_occluder()

	_built = true
	_build_msec = int((Time.get_ticks_usec() - started) / 1000)
	return _build_msec


## Меняет уровень детализации. Возвращает true, если потребовалась пересборка.
func set_detail(level: int, city_seed: int) -> bool:
	var target: int = clampi(level, DETAIL_NEAR, DETAIL_FAR)
	if target == detail_level:
		return false
	detail_level = target
	_clear_nodes()
	build(city_seed)
	return true


func is_built() -> bool:
	return _built


func entrances() -> Array:
	var raw: Variant = _content.get("entrances", null)
	return raw as Array if raw is Array else []


func building_count() -> int:
	var raw: Variant = _content.get("buildings", null)
	return (raw as Array).size() if raw is Array else 0


func stats() -> Dictionary:
	return {
		"coords": coords,
		"detail": detail_level,
		"build_ms": _build_msec,
		"buildings": building_count(),
		"signs": _count("signs"),
		"props": _count("props"),
		"lamps": _count("lamps"),
		"lights": _lights.size(),
		"occluders": _count("occluders"),
	}


func dispose() -> void:
	_clear_nodes()
	_content.clear()
	_built = false
	queue_free()


func _count(key: String) -> int:
	var raw: Variant = _content.get(key, null)
	return (raw as Array).size() if raw is Array else 0


func _clear_nodes() -> void:
	for child: Node in get_children():
		child.queue_free()
	_buildings_mm = null
	_signs_mm = null
	_props_mm = null
	_posts_mm = null
	_heads_mm = null
	_roads_mesh = null
	_arterial_mesh = null
	_occluder = null
	_body = null
	_lights.clear()


# ---------------------------------------------------------------- здания

func _build_buildings() -> void:
	var buildings: Array = _content.get("buildings", [])
	if buildings.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = CityMaterials.box_mesh()
	mm.instance_count = buildings.size()

	for i: int in range(buildings.size()):
		var b: Dictionary = buildings[i]
		var size: Vector3 = b["size"]
		var center: Vector3 = b["center"]
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(size), center))
		mm.set_instance_color(i, b["tint"])
		mm.set_instance_custom_data(i, b["custom"])

	_buildings_mm = MultiMeshInstance3D.new()
	_buildings_mm.name = "Buildings"
	_buildings_mm.multimesh = mm
	_buildings_mm.material_override = CityMaterials.facade
	_buildings_mm.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if detail_level <= DETAIL_MID
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	add_child(_buildings_mm)


# ---------------------------------------------------------------- дороги

func _build_roads() -> void:
	var roads: Array = _content.get("roads", [])
	if roads.is_empty():
		return

	var plain: Array[Dictionary] = []
	var arterial: Array[Dictionary] = []
	for entry: Variant in roads:
		var road: Dictionary = entry as Dictionary
		if bool(road.get("arterial", false)):
			arterial.append(road)
		else:
			plain.append(road)

	_roads_mesh = _make_surface(plain, "Roads", CityMaterials.road)
	_arterial_mesh = _make_surface(arterial, "Arterials", CityMaterials.road_arterial)


func _make_surface(rects: Array[Dictionary], node_name: String, material: Material) -> MeshInstance3D:
	if rects.is_empty():
		return null

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)

	for entry: Dictionary in rects:
		var r: Rect2 = entry["rect"]
		var y: float = float(entry.get("y", 0.0))
		var a := Vector3(r.position.x, y, r.position.y)
		var b := Vector3(r.end.x, y, r.position.y)
		var c := Vector3(r.end.x, y, r.end.y)
		var d := Vector3(r.position.x, y, r.end.y)

		st.set_uv(Vector2(0.0, 0.0)); st.add_vertex(a)
		st.set_uv(Vector2(1.0, 0.0)); st.add_vertex(b)
		st.set_uv(Vector2(1.0, 1.0)); st.add_vertex(c)

		st.set_uv(Vector2(0.0, 0.0)); st.add_vertex(a)
		st.set_uv(Vector2(1.0, 1.0)); st.add_vertex(c)
		st.set_uv(Vector2(0.0, 1.0)); st.add_vertex(d)

	var mesh: ArrayMesh = st.commit()
	if mesh == null:
		Log.warn("CityChunk", "Полотно дорог не собралось", {"чанк": str(coords), "узел": node_name})
		return null

	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance


# ---------------------------------------------------------------- вывески

func _build_signs() -> void:
	var signs: Array = _content.get("signs", [])
	if signs.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = CityMaterials.quad_mesh()
	mm.instance_count = signs.size()

	for i: int in range(signs.size()):
		var s: Dictionary = signs[i]
		mm.set_instance_transform(i, s["transform"])
		mm.set_instance_color(i, s["tint"])
		mm.set_instance_custom_data(i, s["custom"])

	_signs_mm = MultiMeshInstance3D.new()
	_signs_mm.name = "Signs"
	_signs_mm.multimesh = mm
	_signs_mm.material_override = CityMaterials.neon
	_signs_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Дистанционного отсечения у вывесок нет намеренно: они и есть дальний план.
	add_child(_signs_mm)


# ---------------------------------------------------------------- реквизит

func _build_props() -> void:
	var props: Array = _content.get("props", [])
	if props.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = CityMaterials.box_mesh()
	mm.instance_count = props.size()
	for i: int in range(props.size()):
		mm.set_instance_transform(i, (props[i] as Dictionary)["transform"])

	_props_mm = MultiMeshInstance3D.new()
	_props_mm.name = "Props"
	_props_mm.multimesh = mm
	_props_mm.material_override = CityMaterials.concrete
	_props_mm.visibility_range_end = PROP_VISIBLE_TO
	_props_mm.visibility_range_end_margin = 30.0
	_props_mm.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_props_mm)


# ---------------------------------------------------------------- фонари

func _build_lamps() -> void:
	var lamps: Array = _content.get("lamps", [])
	if lamps.is_empty():
		return

	var posts := MultiMesh.new()
	posts.transform_format = MultiMesh.TRANSFORM_3D
	posts.mesh = CityMaterials.cylinder_mesh()
	posts.instance_count = lamps.size()

	var heads := MultiMesh.new()
	heads.transform_format = MultiMesh.TRANSFORM_3D
	heads.use_colors = true
	heads.use_custom_data = true
	heads.mesh = CityMaterials.box_mesh()
	heads.instance_count = lamps.size()

	for i: int in range(lamps.size()):
		var lamp: Dictionary = lamps[i]
		var base: Vector3 = lamp["position"]
		var height: float = float(lamp["height"])

		posts.set_instance_transform(i, Transform3D(
			Basis.IDENTITY.scaled(Vector3(0.22, height, 0.22)),
			base + Vector3(0.0, height * 0.5, 0.0)
		))
		heads.set_instance_transform(i, Transform3D(
			Basis.IDENTITY.scaled(Vector3(0.75, 0.16, 0.45)),
			base + Vector3(0.0, height, 0.0)
		))
		heads.set_instance_color(i, lamp["color"])
		heads.set_instance_custom_data(i, Color(float(i) * 0.017, 0.9, 0.0, 0.0))

	_posts_mm = MultiMeshInstance3D.new()
	_posts_mm.name = "LampPosts"
	_posts_mm.multimesh = posts
	_posts_mm.material_override = CityMaterials.metal
	_posts_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_posts_mm.visibility_range_end = LAMP_POST_VISIBLE_TO
	_posts_mm.visibility_range_end_margin = 40.0
	_posts_mm.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_posts_mm)

	_heads_mm = MultiMeshInstance3D.new()
	_heads_mm.name = "LampHeads"
	_heads_mm.multimesh = heads
	_heads_mm.material_override = CityMaterials.neon
	_heads_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_heads_mm)


## Настоящих источников света — единицы на ближний чанк. На референсе их
## визуально тысячи, но там это эмиссия и glow, а не рассчитываемый свет.
func _build_lights() -> void:
	var lamps: Array = _content.get("lamps", [])
	if lamps.is_empty():
		return

	var step: int = maxi(1, int(ceil(float(lamps.size()) / float(MAX_REAL_LIGHTS))))
	var index: int = 0
	while index < lamps.size() and _lights.size() < MAX_REAL_LIGHTS:
		var lamp: Dictionary = lamps[index]
		var light := OmniLight3D.new()
		light.name = "Lamp_%d" % index
		light.light_color = lamp["color"]
		light.light_energy = 1.6
		light.omni_range = 17.0
		light.omni_attenuation = 1.4
		light.shadow_enabled = false
		light.position = (lamp["position"] as Vector3) + Vector3(0.0, float(lamp["height"]) - 0.3, 0.0)
		light.distance_fade_enabled = true
		light.distance_fade_begin = 60.0
		light.distance_fade_length = 25.0
		add_child(light)
		_lights.append(light)
		index += step


# ---------------------------------------------------------------- коллизии

func _build_collision() -> void:
	var buildings: Array = _content.get("buildings", [])
	_body = StaticBody3D.new()
	_body.name = "Collision"
	_body.collision_layer = 1
	_body.collision_mask = 0
	add_child(_body)

	# Земля чанка.
	var ground := CollisionShape3D.new()
	var ground_shape := BoxShape3D.new()
	ground_shape.size = Vector3(rect.size.x, 0.4, rect.size.y)
	ground.shape = ground_shape
	ground.position = Vector3(rect.get_center().x, -0.2, rect.get_center().y)
	_body.add_child(ground)

	for entry: Variant in buildings:
		var b: Dictionary = entry as Dictionary
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = b["size"]
		shape.shape = box
		shape.position = b["center"]
		_body.add_child(shape)


# ---------------------------------------------------------------- окклюзия

## Один ArrayOccluder3D на весь чанк вместо сотни BoxOccluder3D — иначе
## стоимость самой окклюзии съедает выигрыш от неё.
func _build_occluder() -> void:
	var boxes: Array = _content.get("occluders", [])
	if boxes.is_empty():
		return

	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	vertices.resize(boxes.size() * 8)
	indices.resize(boxes.size() * 36)

	const CORNERS: Array[Vector3] = [
		Vector3(-0.5, -0.5, -0.5), Vector3(0.5, -0.5, -0.5),
		Vector3(0.5, -0.5, 0.5), Vector3(-0.5, -0.5, 0.5),
		Vector3(-0.5, 0.5, -0.5), Vector3(0.5, 0.5, -0.5),
		Vector3(0.5, 0.5, 0.5), Vector3(-0.5, 0.5, 0.5),
	]
	const FACES: PackedInt32Array = [
		0, 2, 1, 0, 3, 2,   # низ
		4, 5, 6, 4, 6, 7,   # верх
		0, 1, 5, 0, 5, 4,   # -Z
		1, 2, 6, 1, 6, 5,   # +X
		2, 3, 7, 2, 7, 6,   # +Z
		3, 0, 4, 3, 4, 7,   # -X
	]

	for i: int in range(boxes.size()):
		var box: Dictionary = boxes[i]
		var center: Vector3 = box["center"]
		var size: Vector3 = box["size"]
		var base: int = i * 8
		for c: int in range(8):
			vertices[base + c] = center + CORNERS[c] * size
		var index_base: int = i * 36
		for f: int in range(36):
			indices[index_base + f] = base + FACES[f]

	var occluder := ArrayOccluder3D.new()
	occluder.set_arrays(vertices, indices)

	_occluder = OccluderInstance3D.new()
	_occluder.name = "Occluder"
	_occluder.occluder = occluder
	add_child(_occluder)
