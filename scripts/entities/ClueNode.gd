class_name NoirClueNode
extends Area3D
## Физическая улика в мире. Вся визуальная часть строится в коде, чтобы узел
## не зависел от внешних .tscn/.tres и не мог «отвалиться» из-за битого ресурса.
##
## Взаимодействие: `try_discover(has_scanner)` — единственная точка входа.
## Улики с `requires_scan = true` невозможно найти без сканера, что и делает
## криминалистику осмысленной механикой.

signal discovered(clue_id: String)
signal highlight_changed(active: bool)

const INTERACT_RADIUS := 1.1
const MARKER_HEIGHT := 0.32

@export var clue_id: String = ""
@export var clue_type: String = "DROPPED_ITEM"
@export var requires_scan: bool = false
@export var discovery_difficulty: int = 2
@export var description: String = ""
@export var is_red_herring: bool = false

var _discovered: bool = false
var _highlighted: bool = false
var _mesh: MeshInstance3D = null
var _light: OmniLight3D = null
var _material: StandardMaterial3D = null
var _base_color: Color = Color("#05D9E8")
var _pulse_time: float = 0.0


static func create(clue_data: Dictionary, as_red_herring: bool = false) -> NoirClueNode:
	var node := NoirClueNode.new()
	node.clue_id = str(clue_data.get("id", ""))
	node.clue_type = str(clue_data.get("type", "DROPPED_ITEM"))
	node.requires_scan = bool(clue_data.get("requires_scan", false))
	node.discovery_difficulty = clampi(int(clue_data.get("discovery_difficulty", 2)), 1, 5)
	node.description = str(clue_data.get("description", ""))
	node.is_red_herring = as_red_herring
	node.name = "Clue_" + node.clue_id if not node.clue_id.is_empty() else "Clue"
	return node


func _ready() -> void:
	_base_color = _color_for_type(clue_type)
	_build_collision()
	_build_visual()
	set_process(true)
	monitoring = false
	monitorable = true
	input_ray_pickable = true
	collision_layer = 4    # слой «улики»
	collision_mask = 0


func _process(delta: float) -> void:
	if not _highlighted or _mesh == null or not is_instance_valid(_mesh):
		return
	_pulse_time += delta
	var pulse: float = 0.55 + 0.45 * sin(_pulse_time * 3.4)
	if _material != null:
		_material.emission_energy_multiplier = 1.2 + pulse * 2.2
	if _light != null and is_instance_valid(_light):
		_light.light_energy = 0.6 + pulse * 1.1


func _build_collision() -> void:
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = INTERACT_RADIUS
	shape.shape = sphere
	shape.name = "InteractShape"
	add_child(shape)


func _build_visual() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = _base_color
	_material.emission_enabled = true
	_material.emission = _base_color
	_material.emission_energy_multiplier = 1.0
	_material.metallic = 0.1
	_material.roughness = 0.35
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.albedo_color.a = 0.85

	_mesh = MeshInstance3D.new()
	_mesh.name = "Marker"
	_mesh.mesh = _mesh_for_type(clue_type)
	_mesh.material_override = _material
	_mesh.position.y = MARKER_HEIGHT
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)

	_light = OmniLight3D.new()
	_light.name = "Glow"
	_light.light_color = _base_color
	_light.light_energy = 0.0
	_light.omni_range = 3.2
	_light.shadow_enabled = false
	_light.position.y = MARKER_HEIGHT + 0.15
	add_child(_light)

	_apply_discovered_look()


## Попытка найти улику. [param has_scanner] — включён ли криминалистический режим.
## Возвращает словарь-результат вместо исключения.
func try_discover(has_scanner: bool) -> Dictionary:
	if _discovered:
		return {"ok": false, "reason": "already", "message": "Улика уже зафиксирована"}
	if requires_scan and not has_scanner:
		return {"ok": false, "reason": "needs_scanner", "message": "Здесь что-то есть, но невооружённым глазом не разобрать"}

	_discovered = true
	_apply_discovered_look()
	discovered.emit(clue_id)
	Log.info("Clue", "Улика зафиксирована в мире", {"id": clue_id, "тип": clue_type, "ложная": is_red_herring})
	return {"ok": true, "reason": "", "message": description}


func is_discovered() -> bool:
	return _discovered


func mark_discovered_silently() -> void:
	_discovered = true
	_apply_discovered_look()


## Подсветка улик — управляется настройкой сложности `gameplay/clue_highlight`.
func set_highlight(active: bool) -> void:
	if _highlighted == active:
		return
	_highlighted = active
	if not active:
		if _material != null:
			_material.emission_energy_multiplier = 1.0
		if _light != null and is_instance_valid(_light):
			_light.light_energy = 0.35 if not _discovered else 0.0
	highlight_changed.emit(active)


func _apply_discovered_look() -> void:
	if _material == null:
		return
	if _discovered:
		_material.emission = Color("#39FF88") if not is_red_herring else Color("#FFA23A")
		_material.albedo_color = _material.emission
		_material.albedo_color.a = 0.5
		_material.emission_energy_multiplier = 0.7
		if _light != null and is_instance_valid(_light):
			_light.light_color = _material.emission
			_light.light_energy = 0.0
	else:
		_material.emission = _base_color
		_material.albedo_color = _base_color
		_material.albedo_color.a = 0.85
		if _light != null and is_instance_valid(_light):
			_light.light_color = _base_color
			_light.light_energy = 0.35


func _mesh_for_type(type_name: String) -> Mesh:
	match type_name:
		"FINGERPRINT", "FIBER":
			var plane := PlaneMesh.new()
			plane.size = Vector2(0.22, 0.22)
			return plane
		"FOOTPRINT", "TIRE_TRACK":
			var footprint := BoxMesh.new()
			footprint.size = Vector3(0.3, 0.02, 0.52)
			return footprint
		"BLOOD_SPATTER":
			var blood := PlaneMesh.new()
			blood.size = Vector2(0.55, 0.55)
			return blood
		"CAMERA_RECORDING":
			var cam := BoxMesh.new()
			cam.size = Vector3(0.18, 0.18, 0.3)
			return cam
		"WEAPON_TRACE":
			var weapon := CylinderMesh.new()
			weapon.top_radius = 0.03
			weapon.bottom_radius = 0.03
			weapon.height = 0.4
			return weapon
		"NOTE", "PHONE_LOG", "WITNESS_STATEMENT":
			var note := BoxMesh.new()
			note.size = Vector3(0.21, 0.01, 0.29)
			return note
		_:
			var sphere := SphereMesh.new()
			sphere.radius = 0.11
			sphere.height = 0.22
			return sphere


func _color_for_type(type_name: String) -> Color:
	match type_name:
		"FINGERPRINT": return Color("#05D9E8")
		"FOOTPRINT", "TIRE_TRACK": return Color("#7DF9FF")
		"BLOOD_SPATTER": return Color("#E8253F")
		"CAMERA_RECORDING": return Color("#A855F7")
		"WEAPON_TRACE": return Color("#FF2A6D")
		"FIBER": return Color("#FF5C8A")
		"NOTE", "PHONE_LOG": return Color("#FFC46B")
		"WITNESS_STATEMENT": return Color("#FFA23A")
		_: return Color("#39FF88")
