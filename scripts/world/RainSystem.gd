class_name NoirRainSystem
extends Node3D
## Дождь и мокрые поверхности.
##
## Система делает три вещи:
##   1. держит над камерой коробку GPU-частиц с каплями и моросью;
##   2. передаёт текущую влажность в шейдеры фасадов, дорог и воды;
##   3. подстраивается под графический пресет: на «Картошке» частиц нет вовсе,
##      на «Perfecto» их максимум.
##
## Источник истины по силе дождя — `GameConfig.world.rain` (0..1), там же,
## где живёт время суток. Меняется из меню настроек, раздел «Мир».
##
## Частицы живут в мировых координатах (`local_coords = false`), иначе при
## движении игрока весь дождь едет вместе с ним и выглядит как стеклянная клетка.

const BOX_HALF := 26.0             ## полуразмер области дождя вокруг камеры
const BOX_TOP := 22.0              ## на какой высоте рождаются капли
const DROPS_MAX := 5200            ## потолок капель при rain = 1 и максимальном пресете
const MIST_MAX := 900              ## потолок частиц мороси у земли
const FOLLOW_STEP := 4.0           ## на сколько должна сместиться камера для переноса
const BASE_WETNESS := 0.28         ## город никогда не бывает совсем сухим

## Множитель количества частиц по пресету.
const PRESET_SCALE: Dictionary = {
	"Картошка": 0.0,
	"Очень Низкие": 0.2,
	"Низкие": 0.35,
	"Средние": 0.55,
	"Высокие": 0.75,
	"Ультра": 0.9,
	"Экстремальные": 1.0,
	"Perfecto": 1.15,
}

var _drops: GPUParticles3D = null
var _mist: GPUParticles3D = null
var _camera: Camera3D = null
var _last_anchor: Vector3 = Vector3.ZERO
var _intensity: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_build_particles()

	if GameConfig != null:
		GameConfig.setting_changed.connect(_on_setting_changed)
	if CityMaterials != null:
		# Пресет перезаписывает wetness в шейдерах — после этого надо заново
		# наложить влажность от дождя, иначе асфальт внезапно высыхает.
		CityMaterials.quality_applied.connect(_on_quality_applied)

	_apply_intensity()
	Log.info("RainSystem", "Система дождя готова", {"сила": "%.2f" % _intensity})


func _process(_delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d() if get_viewport() != null else null
		if _camera == null:
			return

	var target: Vector3 = _camera.global_position
	# Переносим эмиттер не каждый кадр, а шагами: так дождь не дёргается
	# вместе с камерой и остаётся в мировых координатах.
	if target.distance_to(_last_anchor) < FOLLOW_STEP:
		return
	_last_anchor = target
	global_position = Vector3(target.x, target.y, target.z)


# ------------------------------------------------------------------ частицы

func _build_particles() -> void:
	_drops = _make_emitter("RainDrops", true)
	if _drops != null:
		add_child(_drops)
	_mist = _make_emitter("RainMist", false)
	if _mist != null:
		add_child(_mist)


func _make_emitter(node_name: String, heavy: bool) -> GPUParticles3D:
	var node := GPUParticles3D.new()
	node.name = node_name
	node.local_coords = false
	node.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.randomness = 0.35
	node.amount = 1
	node.emitting = false

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.direction = Vector3(0.08, -1.0, 0.04)
	process.spread = 3.0
	process.gravity = Vector3(0.0, -32.0, 0.0)

	var mesh := QuadMesh.new()

	if heavy:
		# Капли: длинные вертикальные штрихи, падают быстро.
		process.emission_box_extents = Vector3(BOX_HALF, 1.0, BOX_HALF)
		process.initial_velocity_min = 16.0
		process.initial_velocity_max = 22.0
		process.scale_min = 0.7
		process.scale_max = 1.3
		process.color = Color(0.72, 0.82, 0.95, 0.55)
		node.lifetime = 1.6
		node.preprocess = 1.2
		mesh.size = Vector2(0.035, 0.95)
	else:
		# Морось у земли: медленная взвесь, которая ловит свет фонарей.
		process.emission_box_extents = Vector3(BOX_HALF * 0.7, 2.0, BOX_HALF * 0.7)
		process.initial_velocity_min = 0.4
		process.initial_velocity_max = 1.6
		process.gravity = Vector3(0.0, -1.4, 0.0)
		process.scale_min = 0.6
		process.scale_max = 2.4
		process.color = Color(0.7, 0.78, 0.9, 0.12)
		node.lifetime = 3.4
		node.preprocess = 2.0
		mesh.size = Vector2(0.7, 0.7)

	node.process_material = process
	node.draw_pass_1 = mesh
	node.material_override = CityMaterials.water_drop if CityMaterials != null else null
	# AABB задаём вручную: без него частицы отсекаются на краю экрана.
	node.visibility_aabb = AABB(
		Vector3(-BOX_HALF, -BOX_TOP, -BOX_HALF),
		Vector3(BOX_HALF * 2.0, BOX_TOP * 2.0, BOX_HALF * 2.0)
	)
	return node


## Высота точки рождения капель относительно камеры.
func _position_emitters() -> void:
	if _drops != null:
		_drops.position = Vector3(0.0, BOX_TOP, 0.0)
	if _mist != null:
		_mist.position = Vector3(0.0, 1.5, 0.0)


# ------------------------------------------------------------ сила и влажность

## Пересчёт всего: количество частиц и влажность материалов.
func _apply_intensity() -> void:
	_intensity = 0.7
	if GameConfig != null:
		_intensity = clampf(GameConfig.get_float("world", "rain"), 0.0, 1.0)

	var preset: String = "Высокие"
	if GameConfig != null:
		preset = GameConfig.get_string("graphics", "preset")
	var scale: float = float(PRESET_SCALE.get(preset, 0.75))

	_position_emitters()

	var drops: int = int(round(float(DROPS_MAX) * _intensity * scale))
	if _drops != null:
		_drops.amount = maxi(1, drops)
		_drops.emitting = drops > 0

	var mist: int = int(round(float(MIST_MAX) * _intensity * scale))
	if _mist != null:
		_mist.amount = maxi(1, mist)
		_mist.emitting = mist > 0

	_apply_wetness()


## Влажность поверхностей. Пресет задаёт потолок качества бликов,
## а дождь — то, насколько этот потолок выбран.
func _apply_wetness() -> void:
	if CityMaterials == null:
		return
	var wet: float = clampf(BASE_WETNESS + _intensity * 0.72, 0.0, 1.0)
	var ripples: float = clampf(_intensity, 0.0, 1.0)

	if CityMaterials.facade != null:
		CityMaterials.facade.set_shader_parameter("wetness", wet)
	if CityMaterials.road != null:
		CityMaterials.road.set_shader_parameter("wetness", wet)
	if CityMaterials.road_arterial != null:
		CityMaterials.road_arterial.set_shader_parameter("wetness", wet)
	if CityMaterials.water != null:
		CityMaterials.water.set_shader_parameter("rain_ripples", ripples)


# ------------------------------------------------------------------- сигналы

func _on_setting_changed(section: String, key: String, _value: Variant) -> void:
	if section == "world" and key == "rain":
		_apply_intensity()
	elif section == "graphics" and key == "preset":
		_apply_intensity()


func _on_quality_applied(_preset: String) -> void:
	_apply_intensity()


## Текущая сила дождя 0..1 — пригодится геймплею (следы, звук, улики).
func intensity() -> float:
	return _intensity
