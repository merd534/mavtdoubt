class_name NoirRiverBuilder
extends RefCounted
## Река и четыре моста. Строятся один раз и живут всегда: геометрии мало,
## а видно их с любой точки карты, поэтому в стриминг чанков они не входят.
##
## Русло идёт по ломаной `CityAtlas.RIVER_POINTS` (северо-восток → юго-восток,
## как на референсе). Вода лежит чуть выше уровня улицы, чтобы перекрыть
## дорожное полотно чанков, проходящее под ней, — набережные прячут стык.

const WATER_Y := 0.12
const EMBANKMENT_HEIGHT := 1.6
const EMBANKMENT_WIDTH := 3.0
const BRIDGE_DECK_Y := 0.62
const BRIDGE_DECK_THICKNESS := 0.55
const RAILING_HEIGHT := 1.1
const BRIDGE_LAMP_SPACING := 18.0


## Создаёт узел со всей водной инфраструктурой.
static func build() -> Node3D:
	var root := Node3D.new()
	root.name = "RiverAndBridges"

	var points: Array[Vector2] = CityAtlas.river_points()
	if points.size() < 2:
		Log.error("RiverBuilder", "В атласе нет русла реки — вода не построена")
		return root

	_build_water(root, points)
	_build_embankments(root, points)
	_build_bridges(root)
	Log.info("RiverBuilder", "Река и мосты построены", {"точек_русла": points.size(), "мостов": CityAtlas.bridges().size()})
	return root


# ------------------------------------------------------------------- вода

static func _build_water(root: Node3D, points: Array[Vector2]) -> void:
	var half: float = CityAtlas.river_width() * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)

	for i: int in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]

		var a_left := Vector3(a.x - half, WATER_Y, a.y)
		var a_right := Vector3(a.x + half, WATER_Y, a.y)
		var b_left := Vector3(b.x - half, WATER_Y, b.y)
		var b_right := Vector3(b.x + half, WATER_Y, b.y)

		st.set_uv(Vector2(0.0, float(i))); st.add_vertex(a_left)
		st.set_uv(Vector2(1.0, float(i))); st.add_vertex(a_right)
		st.set_uv(Vector2(1.0, float(i + 1))); st.add_vertex(b_right)

		st.set_uv(Vector2(0.0, float(i))); st.add_vertex(a_left)
		st.set_uv(Vector2(1.0, float(i + 1))); st.add_vertex(b_right)
		st.set_uv(Vector2(0.0, float(i + 1))); st.add_vertex(b_left)

	var mesh: ArrayMesh = st.commit()
	if mesh == null:
		Log.error("RiverBuilder", "Полотно воды не собралось")
		return

	var water := MeshInstance3D.new()
	water.name = "Water"
	water.mesh = mesh
	water.material_override = CityMaterials.water
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(water)


## Набережные — низкие парапеты вдоль обоих берегов. Прячут стык воды с
## дорожным полотном и дают реке читаемый силуэт сверху.
static func _build_embankments(root: Node3D, points: Array[Vector2]) -> void:
	var half: float = CityAtlas.river_width() * 0.5
	var segments: Array[Dictionary] = []

	for i: int in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		for side: int in [-1, 1]:
			var a_edge := Vector2(a.x + float(side) * half, a.y)
			var b_edge := Vector2(b.x + float(side) * half, b.y)
			var mid: Vector2 = (a_edge + b_edge) * 0.5
			var delta: Vector2 = b_edge - a_edge
			var length: float = delta.length()
			if length < 0.5:
				continue
			var angle: float = atan2(delta.x, delta.y)
			var basis := Basis(Vector3.UP, angle).scaled(Vector3(EMBANKMENT_WIDTH, EMBANKMENT_HEIGHT, length))
			segments.append({
				"transform": Transform3D(basis, Vector3(mid.x, EMBANKMENT_HEIGHT * 0.5 - 0.4, mid.y)),
			})

	if segments.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = CityMaterials.box_mesh()
	mm.instance_count = segments.size()
	for i: int in range(segments.size()):
		mm.set_instance_transform(i, segments[i]["transform"])

	var instance := MultiMeshInstance3D.new()
	instance.name = "Embankments"
	instance.multimesh = mm
	instance.material_override = CityMaterials.concrete
	root.add_child(instance)


# ------------------------------------------------------------------ мосты

static func _build_bridges(root: Node3D) -> void:
	var bridges: Array[Dictionary] = CityAtlas.bridges()
	if bridges.is_empty():
		return

	var decks: Array[Transform3D] = []
	var railings: Array[Transform3D] = []
	var posts: Array[Transform3D] = []
	var heads: Array[Dictionary] = []

	for bridge: Dictionary in bridges:
		var from_point: Vector2 = bridge["from"]
		var to_point: Vector2 = bridge["to"]
		var width: float = float(bridge["width"])
		var span: float = absf(to_point.x - from_point.x)
		var center_x: float = (from_point.x + to_point.x) * 0.5
		var z: float = float(bridge["z"])

		# Полотно.
		decks.append(Transform3D(
			Basis.IDENTITY.scaled(Vector3(span, BRIDGE_DECK_THICKNESS, width)),
			Vector3(center_x, BRIDGE_DECK_Y, z)
		))

		# Перила по обеим сторонам.
		for side: int in [-1, 1]:
			railings.append(Transform3D(
				Basis.IDENTITY.scaled(Vector3(span, RAILING_HEIGHT, 0.3)),
				Vector3(center_x, BRIDGE_DECK_Y + RAILING_HEIGHT * 0.5, z + float(side) * width * 0.5)
			))

		# Опоры в воде.
		var support_count: int = maxi(2, int(span / 45.0))
		for i: int in range(support_count):
			var t: float = (float(i) + 0.5) / float(support_count)
			posts.append(Transform3D(
				Basis.IDENTITY.scaled(Vector3(2.2, 6.0, 2.2)),
				Vector3(lerpf(from_point.x, to_point.x, t), -2.6, z)
			))

		# Янтарные фонари вдоль пролёта — именно они рисуют мосты на референсе.
		var lamp_count: int = maxi(2, int(span / BRIDGE_LAMP_SPACING))
		for i: int in range(lamp_count):
			var t: float = (float(i) + 0.5) / float(lamp_count)
			var x: float = lerpf(from_point.x, to_point.x, t)
			for side: int in [-1, 1]:
				heads.append({
					"transform": Transform3D(
						Basis.IDENTITY.scaled(Vector3(0.5, 0.16, 0.5)),
						Vector3(x, BRIDGE_DECK_Y + RAILING_HEIGHT + 0.9, z + float(side) * width * 0.5)
					),
					"seed": float(i) * 0.11 + float(side) * 0.3,
				})

	_add_box_multimesh(root, "BridgeDecks", decks, CityMaterials.concrete)
	_add_box_multimesh(root, "BridgeRailings", railings, CityMaterials.metal)
	_add_box_multimesh(root, "BridgeSupports", posts, CityMaterials.concrete)

	if not heads.is_empty():
		var amber: Color = CityAtlas.palette("sodium_amber")
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = CityMaterials.box_mesh()
		mm.instance_count = heads.size()
		for i: int in range(heads.size()):
			var head: Dictionary = heads[i]
			mm.set_instance_transform(i, head["transform"])
			mm.set_instance_color(i, amber)
			mm.set_instance_custom_data(i, Color(float(head["seed"]), 0.95, 0.0, 0.0))

		var instance := MultiMeshInstance3D.new()
		instance.name = "BridgeLights"
		instance.multimesh = mm
		instance.material_override = CityMaterials.neon
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(instance)

	_add_bridge_collision(root, bridges)


static func _add_box_multimesh(root: Node3D, node_name: String, transforms: Array[Transform3D], material: Material) -> void:
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
	root.add_child(instance)


static func _add_bridge_collision(root: Node3D, bridges: Array[Dictionary]) -> void:
	var body := StaticBody3D.new()
	body.name = "BridgeCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	root.add_child(body)

	for bridge: Dictionary in bridges:
		var from_point: Vector2 = bridge["from"]
		var to_point: Vector2 = bridge["to"]
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(absf(to_point.x - from_point.x), BRIDGE_DECK_THICKNESS, float(bridge["width"]))
		shape.shape = box
		shape.position = Vector3((from_point.x + to_point.x) * 0.5, BRIDGE_DECK_Y, float(bridge["z"]))
		body.add_child(shape)
