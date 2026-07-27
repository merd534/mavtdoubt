class_name NoirDevCamera
extends CharacterBody3D
## Камера-наблюдатель для осмотра города. Два режима: свободный полёт и ходьба
## по улицам с коллизией.
##
## Управление читается напрямую с клавиш, без InputMap — стенд обязан работать
## в чистом проекте, где действия ещё не настроены.
##
##   ЛКМ            захватить мышь, Esc — отпустить
##   W A S D        движение, Q/E — вниз/вверх (в полёте)
##   Shift          ускорение, Ctrl — замедление
##   F              переключить полёт/ходьбу
##   Space          прыжок (в ходьбе)

const WALK_SPEED := 5.2
const RUN_MULTIPLIER := 2.6
const SLOW_MULTIPLIER := 0.35
const FLY_SPEED := 34.0
const ACCELERATION := 12.0
const JUMP_VELOCITY := 4.8
const GRAVITY := 18.0
const MOUSE_BASE := 0.0022
const PITCH_LIMIT := 1.45

signal mode_changed(flying: bool)

@export var flying: bool = true
@export var eye_height: float = 1.7

var camera: Camera3D = null

var _yaw: float = 0.0
var _pitch: float = -0.12
var _captured: bool = false


func _ready() -> void:
	_ensure_collision()
	_ensure_camera()
	_yaw = rotation.y
	floor_max_angle = deg_to_rad(52.0)


func _ensure_collision() -> void:
	for child: Node in get_children():
		if child is CollisionShape3D:
			return
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.75
	shape.shape = capsule
	shape.position = Vector3(0.0, 0.9, 0.0)
	shape.name = "Body"
	add_child(shape)


func _ensure_camera() -> void:
	for child: Node in get_children():
		if child is Camera3D:
			camera = child as Camera3D
			return
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0.0, eye_height, 0.0)
	camera.near = 0.08
	camera.far = maxf(600.0, GameConfig.get_float("graphics", "render_distance_m") * 1.6)
	camera.fov = GameConfig.get_float("controls", "fov")
	add_child(camera)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if not _captured:
			_set_captured(true)
		return

	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var key: Key = (event as InputEventKey).keycode
		if key == KEY_ESCAPE:
			_set_captured(false)
		elif key == KEY_F:
			flying = not flying
			velocity = Vector3.ZERO
			mode_changed.emit(flying)
			Log.info("DevCamera", "Режим камеры", {"полёт": flying})

	if event is InputEventMouseMotion and _captured:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		var sensitivity: float = maxf(0.01, GameConfig.get_float("controls", "mouse_sensitivity"))
		var invert: float = -1.0 if GameConfig.get_bool("controls", "invert_y") else 1.0
		_yaw -= motion.relative.x * MOUSE_BASE * sensitivity * 100.0
		_pitch -= motion.relative.y * MOUSE_BASE * sensitivity * 100.0 * invert
		_pitch = clampf(_pitch, -PITCH_LIMIT, PITCH_LIMIT)


func _set_captured(value: bool) -> void:
	_captured = value
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if value else Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	rotation.y = _yaw
	if camera != null and is_instance_valid(camera):
		camera.rotation.x = _pitch

	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input.z += 1.0
	if Input.is_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input.x += 1.0

	var speed: float = FLY_SPEED if flying else WALK_SPEED
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= RUN_MULTIPLIER
	if Input.is_key_pressed(KEY_CTRL):
		speed *= SLOW_MULTIPLIER

	var direction: Vector3 = (transform.basis * input).normalized()

	if flying:
		var vertical: float = 0.0
		if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE):
			vertical += 1.0
		if Input.is_key_pressed(KEY_Q):
			vertical -= 1.0
		var target: Vector3 = direction * speed + Vector3.UP * vertical * speed
		velocity = velocity.lerp(target, clampf(ACCELERATION * delta, 0.0, 1.0))
		# В полёте сквозь геометрию не проваливаемся, но и не цепляемся за неё.
		global_position += velocity * delta
		velocity = velocity  # позиция обновлена вручную, move_and_slide не нужен
		return

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif Input.is_key_pressed(KEY_SPACE):
		velocity.y = JUMP_VELOCITY

	var planar: Vector3 = direction * speed
	velocity.x = lerpf(velocity.x, planar.x, clampf(ACCELERATION * delta, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, planar.z, clampf(ACCELERATION * delta, 0.0, 1.0))
	move_and_slide()


## Мгновенно переносит камеру (используется стендом для облёта города).
func teleport(to: Vector3, look_at_point: Vector3 = Vector3.INF) -> void:
	global_position = to
	velocity = Vector3.ZERO
	if look_at_point != Vector3.INF:
		var flat: Vector3 = (look_at_point - to)
		_yaw = atan2(-flat.x, -flat.z)
		var horizontal: float = Vector2(flat.x, flat.z).length()
		_pitch = clampf(atan2(flat.y, maxf(0.001, horizontal)), -PITCH_LIMIT, PITCH_LIMIT)
		rotation.y = _yaw
		if camera != null and is_instance_valid(camera):
			camera.rotation.x = _pitch
