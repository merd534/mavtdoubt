class_name NoirClimbArea
extends Area3D
## ФАЗА 3. Зона лазания перед пожарной лестницей.
##
## Контроллер игрока может ничего не знать про лестницы: зона сама сообщает
## телу, что оно может лезть вверх. Поддерживаются два способа связи, и оба
## безопасны, если контроллер их не реализует:
##
##  1. Есть метод `enter_climb_zone(zone)` / `exit_climb_zone(zone)` — вызываем их.
##  2. Иначе выставляем на теле мету `climb_zone` — контроллер прочитает её,
##     когда будет готов, а до тех пор ничего не ломается.
##
## Слои: зона слушает слой игрока (2), сама лежит на слое 4, чтобы её не
## задевали лучи выстрелов и сканера улик.

signal climber_entered(body: Node3D)
signal climber_exited(body: Node3D)

var climb_normal: Vector3 = Vector3.FORWARD   ## наружу от стены
var top_y: float = 0.0                        ## докуда можно долезть
var climb_speed: float = 2.6

var _climbers: Array[Node3D] = []


static func create(position: Vector3, size: Vector3, normal: Vector3, top: float) -> NoirClimbArea:
	var area := NoirClimbArea.new()
	area.name = "ClimbZone"
	area.position = position
	area.climb_normal = normal.normalized() if normal.length() > 0.01 else Vector3.FORWARD
	area.top_y = top
	area.collision_layer = 4
	area.collision_mask = 2
	area.monitoring = true
	area.monitorable = false

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(0.4, size.x), maxf(1.0, size.y), maxf(0.4, size.z))
	shape.shape = box
	area.add_child(shape)
	return area


func _ready() -> void:
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if not body_exited.is_connected(_on_body_exited):
		body_exited.connect(_on_body_exited)


func _exit_tree() -> void:
	# Узел выгружается вместе с чанком: обязаны снять состояние с тел,
	# иначе игрок останется лезущим в воздухе после выгрузки геометрии.
	for body: Node3D in _climbers.duplicate():
		_release(body)
	_climbers.clear()


func climbers() -> Array[Node3D]:
	return _climbers.duplicate()


func is_climbing(body: Node3D) -> bool:
	return _climbers.has(body)


## Куда двигать тело при удержании вперёд: вверх вдоль стены.
func climb_velocity(input_up: float) -> Vector3:
	return Vector3.UP * clampf(input_up, -1.0, 1.0) * climb_speed


func _on_body_entered(body: Node3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	if _climbers.has(body):
		return
	_climbers.append(body)

	if body.has_method("enter_climb_zone"):
		body.call("enter_climb_zone", self)
	else:
		body.set_meta("climb_zone", self)

	climber_entered.emit(body)
	Log.trace("ClimbArea", "Тело вошло в зону лазания", {"тело": body.name, "вершина": top_y})


func _on_body_exited(body: Node3D) -> void:
	if body == null:
		return
	_release(body)


func _release(body: Node3D) -> void:
	_climbers.erase(body)
	if body == null or not is_instance_valid(body):
		return

	if body.has_method("exit_climb_zone"):
		body.call("exit_climb_zone", self)
	elif body.has_meta("climb_zone") and body.get_meta("climb_zone") == self:
		body.remove_meta("climb_zone")

	climber_exited.emit(body)
