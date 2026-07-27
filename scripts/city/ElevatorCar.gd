class_name NoirElevatorCar
extends AnimatableBody3D
## ФАЗА 3. Рабочий лифт внутри здания.
##
## Почему AnimatableBody3D, а не Node3D с твином: кабина возит на себе
## игрока. AnimatableBody3D синхронизирует движение с физикой и передаёт
## скорость телам сверху, поэтому CharacterBody3D не проваливается сквозь пол
## и не отстаёт от кабины.
##
## Лифт живёт внутри интерьера и выгружается вместе с ним.

signal arrived(floor_index: int)
signal departed(floor_index: int)

const DOOR_TIME := 1.2      ## сколько стоит с открытыми дверями
const DEFAULT_SPEED := 2.6  ## м/с

var floor_height: float = 3.4
var floors: int = 1
var speed: float = DEFAULT_SPEED
var base_y: float = 0.0

var _current_floor: int = 0
var _target_floor: int = 0
var _moving: bool = false
var _wait_left: float = 0.0


static func create(position: Vector3, size: Vector3, total_floors: int, height_per_floor: float) -> NoirElevatorCar:
	var car := NoirElevatorCar.new()
	car.name = "ElevatorCar"
	car.position = position
	car.base_y = position.y
	car.floors = maxi(1, total_floors)
	car.floor_height = maxf(1.0, height_per_floor)
	car.collision_layer = 1
	car.collision_mask = 0
	car.sync_to_physics = true

	# Пол кабины и три стенки: четвёртая сторона — вход.
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(size.x, 0.2, size.z)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0.0, -0.1, 0.0)
	car.add_child(floor_shape)

	var ceiling := CollisionShape3D.new()
	var ceiling_box := BoxShape3D.new()
	ceiling_box.size = Vector3(size.x, 0.15, size.z)
	ceiling.shape = ceiling_box
	ceiling.position = Vector3(0.0, size.y, 0.0)
	car.add_child(ceiling)

	car._add_visual(size)
	return car


func _add_visual(size: Vector3) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "Cabin"
	mesh.mesh = CityMaterials.box_mesh()
	mesh.scale = Vector3(size.x, 0.16, size.z)
	mesh.position = Vector3(0.0, -0.08, 0.0)
	if CityMaterials.metal != null:
		mesh.material_override = CityMaterials.metal
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)

	# Лампа в кабине: без неё внутри абсолютная темнота.
	var light := OmniLight3D.new()
	light.name = "CabinLight"
	light.light_color = CityAtlas.palette("window_warm")
	light.light_energy = 1.0
	light.omni_range = maxf(2.5, size.x * 1.6)
	light.shadow_enabled = false
	light.position = Vector3(0.0, maxf(1.6, size.y - 0.3), 0.0)
	add_child(light)


func _ready() -> void:
	set_physics_process(false)


func current_floor() -> int:
	return _current_floor


func is_busy() -> bool:
	return _moving or _wait_left > 0.0


## Вызов кабины на этаж. Повторный вызов во время движения игнорируется:
## реальные лифты тоже не меняют направление посреди пролёта.
func call_to_floor(target: int) -> bool:
	var clamped: int = clampi(target, 0, floors - 1)
	if _moving:
		return false
	if clamped == _current_floor and _wait_left <= 0.0:
		_wait_left = DOOR_TIME
		set_physics_process(true)
		return true

	_target_floor = clamped
	_moving = true
	_wait_left = 0.0
	set_physics_process(true)
	departed.emit(_current_floor)
	Log.debug("ElevatorCar", "Лифт поехал", {"с": _current_floor, "на": _target_floor})
	return true


## Следующий этаж вверх/вниз — удобно для кнопок в кабине.
func step(direction: int) -> bool:
	if direction == 0:
		return false
	return call_to_floor(_current_floor + signi(direction))


func _physics_process(delta: float) -> void:
	if _wait_left > 0.0:
		_wait_left -= delta
		if _wait_left <= 0.0 and not _moving:
			set_physics_process(false)
		return

	if not _moving:
		set_physics_process(false)
		return

	var target_y: float = base_y + float(_target_floor) * floor_height
	var diff: float = target_y - position.y
	var step_len: float = speed * delta

	if absf(diff) <= step_len:
		position.y = target_y
		_current_floor = _target_floor
		_moving = false
		_wait_left = DOOR_TIME
		arrived.emit(_current_floor)
		Log.debug("ElevatorCar", "Лифт приехал", {"этаж": _current_floor})
		return

	position.y += signf(diff) * step_len
