class_name NoirClueSpawner
extends Node3D
## Материализует дело в мире: улики, ложные следы, метка тела, брызги крови.
##
## Конфликты исключены конструктивно:
##  * перед спавном нового дела старое **всегда** снимается ([method clear]);
##  * позиции разносятся минимальным интервалом, иначе маркеры слипаются в один;
##  * если узел-родитель ещё не готов (например, город не сгенерирован), спавн
##    не падает, а откладывается — дело помечается как «ожидает мир»,
##    и [method flush_pending] доспавнит его позже.

signal spawned(clue_count: int)
signal cleared()
signal clue_found(clue_id: String, is_red_herring: bool)

const MIN_SEPARATION := 0.45
const SEPARATION_TRIES := 12
const GROUND_OFFSET := 0.05

var _clue_nodes: Dictionary = {}       # clue_id -> NoirClueNode
var _decor_nodes: Array[Node3D] = []
var _case: NoirCaseFile = null
var _pending_case: NoirCaseFile = null
var _highlight_enabled: bool = true


func _ready() -> void:
	_highlight_enabled = GameConfig.get_bool("gameplay", "clue_highlight")
	GameConfig.setting_changed.connect(_on_setting_changed)


func _on_setting_changed(section: String, key: String, value: Variant) -> void:
	if section == "gameplay" and key == "clue_highlight":
		set_highlight_enabled(bool(value))


## Спавнит дело. Возвращает число созданных узлов-улик.
func spawn_case(case_file: NoirCaseFile) -> int:
	if case_file == null:
		Log.error("ClueSpawner", "Передано пустое дело — спавн отменён")
		return 0

	clear()
	_case = case_file

	if not is_inside_tree():
		_pending_case = case_file
		Log.warn("ClueSpawner", "Спавнер вне дерева сцены — дело отложено до flush_pending()")
		return 0

	var occupied: Array[Vector3] = []
	var created: int = 0

	# --- метка тела ----------------------------------------------------------
	var scene_pos: Vector3 = case_file.scene_position()
	_spawn_body_marker(scene_pos)
	occupied.append(scene_pos)

	# --- улики ---------------------------------------------------------------
	for clue: Dictionary in case_file.clues():
		var node: NoirClueNode = NoirClueNode.create(clue, false)
		var target: Vector3 = _resolve_position(clue, scene_pos)
		target = _separate(target, occupied)
		occupied.append(target)

		node.position = target + Vector3(0.0, GROUND_OFFSET, 0.0)
		add_child(node)
		node.discovered.connect(_on_clue_node_discovered.bind(false))
		node.set_highlight(_highlight_enabled and not bool(clue.get("discovered", false)))
		if bool(clue.get("discovered", false)):
			node.mark_discovered_silently()

		_clue_nodes[str(clue["id"])] = node
		created += 1

		if str(clue.get("type", "")) == "BLOOD_SPATTER":
			_spawn_blood_patch(target)

	# --- ложные следы --------------------------------------------------------
	for herring: Dictionary in case_file.red_herrings():
		var fake: Dictionary = {
			"id": str(herring.get("id", "")),
			"type": "DROPPED_ITEM",
			"requires_scan": false,
			"discovery_difficulty": 2,
			"description": str(herring.get("description", "")),
		}
		var node: NoirClueNode = NoirClueNode.create(fake, true)
		var location_id: String = str(herring.get("location_id", ""))
		var base: Vector3 = CityAtlas.location_world_position(location_id) if CityAtlas.has_location(location_id) else scene_pos
		var target: Vector3 = _separate(base + Vector3(randf_range(-1.5, 1.5), 0.0, randf_range(-1.5, 1.5)), occupied)
		occupied.append(target)

		node.position = target + Vector3(0.0, GROUND_OFFSET, 0.0)
		add_child(node)
		node.discovered.connect(_on_clue_node_discovered.bind(true))
		node.set_highlight(_highlight_enabled)
		_clue_nodes[str(fake["id"])] = node
		created += 1

	# --- брызги вокруг тела для «мокрых» орудий ------------------------------
	var weapon_type: String = str(case_file.weapon().get("type", ""))
	if weapon_type in ["knife", "blunt", "firearm", "improvised"]:
		var count: int = 3 if weapon_type == "knife" else 2
		for i: int in range(count):
			var angle: float = TAU * float(i) / float(count) + randf() * 0.7
			_spawn_blood_patch(scene_pos + Vector3(cos(angle) * randf_range(0.6, 1.8), 0.0, sin(angle) * randf_range(0.6, 1.8)))

	spawned.emit(created)
	Log.info("ClueSpawner", "Дело материализовано", {
		"улик": _clue_nodes.size(), "декора": _decor_nodes.size(), "узлов": created,
	})
	return created


## Доспавнивает дело, отложенное из-за отсутствия дерева сцены.
func flush_pending() -> int:
	if _pending_case == null:
		return 0
	var case_file: NoirCaseFile = _pending_case
	_pending_case = null
	return spawn_case(case_file)


func clear() -> void:
	for key: Variant in _clue_nodes.keys():
		var node: Variant = _clue_nodes[key]
		if node is Node and is_instance_valid(node as Node):
			(node as Node).queue_free()
	_clue_nodes.clear()

	for node: Node3D in _decor_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_decor_nodes.clear()

	_case = null
	cleared.emit()


func set_highlight_enabled(enabled: bool) -> void:
	_highlight_enabled = enabled
	for key: Variant in _clue_nodes.keys():
		var node: Variant = _clue_nodes[key]
		if node is NoirClueNode and is_instance_valid(node as NoirClueNode):
			var clue_node: NoirClueNode = node as NoirClueNode
			clue_node.set_highlight(enabled and not clue_node.is_discovered())


func clue_node(clue_id: String) -> NoirClueNode:
	var node: Variant = _clue_nodes.get(clue_id, null)
	return node as NoirClueNode if node is NoirClueNode and is_instance_valid(node as NoirClueNode) else null


func spawned_count() -> int:
	return _clue_nodes.size()


## Все улики в радиусе — используется сканером игрока.
func clues_near(point: Vector3, radius: float) -> Array[NoirClueNode]:
	var out: Array[NoirClueNode] = []
	for key: Variant in _clue_nodes.keys():
		var node: Variant = _clue_nodes[key]
		if not (node is NoirClueNode) or not is_instance_valid(node as NoirClueNode):
			continue
		var clue_node: NoirClueNode = node as NoirClueNode
		if clue_node.global_position.distance_to(point) <= radius:
			out.append(clue_node)
	return out


# -------------------------------------------------------------------- внутренне

func _on_clue_node_discovered(clue_id: String, is_red_herring: bool) -> void:
	if _case == null:
		Log.warn("ClueSpawner", "Улика найдена, но активного дела нет", {"id": clue_id})
		return
	if is_red_herring:
		_case.discover_herring(clue_id)
	else:
		_case.discover_clue(clue_id)
	clue_found.emit(clue_id, is_red_herring)


func _resolve_position(clue: Dictionary, fallback: Vector3) -> Vector3:
	var raw: Variant = clue.get("coords", null)
	if raw is Vector3 and (raw as Vector3).length() > 0.01:
		return raw as Vector3
	var location_id: String = str(clue.get("location_id", ""))
	if CityAtlas.has_location(location_id):
		return CityAtlas.location_world_position(location_id)
	return fallback


## Разносит совпадающие позиции по спирали — маркеры не должны слипаться.
func _separate(target: Vector3, occupied: Array[Vector3]) -> Vector3:
	var candidate: Vector3 = target
	for attempt: int in range(SEPARATION_TRIES):
		var collides: bool = false
		for taken: Vector3 in occupied:
			if candidate.distance_to(taken) < MIN_SEPARATION:
				collides = true
				break
		if not collides:
			return candidate
		var angle: float = TAU * float(attempt) / float(SEPARATION_TRIES)
		var radius: float = MIN_SEPARATION * (1.0 + float(attempt) * 0.35)
		candidate = target + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	return candidate


func _spawn_body_marker(position: Vector3) -> void:
	var marker := MeshInstance3D.new()
	marker.name = "BodyMarker"
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(1.9, 0.75)
	marker.mesh = mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#E8253F")
	material.albedo_color.a = 0.28
	material.emission_enabled = true
	material.emission = Color("#E8253F")
	material.emission_energy_multiplier = 0.55
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	marker.material_override = material
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.position = position + Vector3(0.0, 0.02, 0.0)

	add_child(marker)
	_decor_nodes.append(marker)


func _spawn_blood_patch(position: Vector3) -> void:
	var patch := MeshInstance3D.new()
	patch.name = "BloodPatch"
	var mesh := PlaneMesh.new()
	var size: float = randf_range(0.35, 0.9)
	mesh.size = Vector2(size, size * randf_range(0.7, 1.3))
	patch.mesh = mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.32, 0.02, 0.05, 0.82)
	material.roughness = 0.18
	material.metallic = 0.05
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	patch.material_override = material
	patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	patch.rotate_y(randf() * TAU)
	patch.position = position + Vector3(0.0, 0.015, 0.0)

	add_child(patch)
	_decor_nodes.append(patch)
