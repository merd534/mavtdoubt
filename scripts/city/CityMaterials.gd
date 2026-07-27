class_name NoirCityMaterials
extends Node
## Общая библиотека материалов и базовых мешей. Автозагрузка: `CityMaterials`.
##
## Весь город рисуется горсткой общих материалов — это условие батчинга:
## MultiMesh склеивает тысячи зданий в один вызов отрисовки только если у них
## один и тот же материал. Разницу между районами даёт не материал, а цвет
## инстанса и `INSTANCE_CUSTOM`.
##
## Здесь же живёт применение графических пресетов к шейдерным юниформам —
## Фаза 3 будет дёргать [method apply_quality], а не лезть в шейдеры руками.

const FACADE_SHADER := "res://shaders/facade.gdshader"
const NEON_SHADER := "res://shaders/neon.gdshader"
const ROAD_SHADER := "res://shaders/road.gdshader"
const WATER_SHADER := "res://shaders/water.gdshader"

signal quality_applied(preset: String)

var facade: ShaderMaterial = null
## Вариант фасада для дальнего плана: ярче и со светящейся кровлей.
## На дистанции 780 м+ окно мельче пикселя, поэтому обычный материал там
## вырождается в чёрный прямоугольник.
var facade_far: ShaderMaterial = null
var neon: ShaderMaterial = null
var road: ShaderMaterial = null
var road_arterial: ShaderMaterial = null
var water: ShaderMaterial = null
var concrete: StandardMaterial3D = null
var metal: StandardMaterial3D = null
var interior_wall: StandardMaterial3D = null
var interior_floor: StandardMaterial3D = null
var furniture: StandardMaterial3D = null

var _box: BoxMesh = null
var _plane: PlaneMesh = null
var _quad: QuadMesh = null
var _cylinder: CylinderMesh = null
var _ready_ok: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_meshes()
	_build_materials()
	apply_quality(GameConfig.get_string("graphics", "preset"))
	GameConfig.setting_changed.connect(_on_setting_changed)
	Log.info("CityMaterials", "Библиотека материалов готова", {"успешно": _ready_ok})


func is_ready() -> bool:
	return _ready_ok


# ------------------------------------------------------------------- меши

## Единичный куб. Все здания — это он, растянутый модельной матрицей.
func box_mesh() -> BoxMesh:
	return _box


## Единичная плоскость (лежит в XZ, нормаль вверх). Дороги, полы, вода.
func plane_mesh() -> PlaneMesh:
	return _plane


## Единичный квад (стоит в XY, нормаль +Z). Вывески.
func quad_mesh() -> QuadMesh:
	return _quad


## Единичный цилиндр. Столбы фонарей, трубы.
func cylinder_mesh() -> CylinderMesh:
	return _cylinder


func _build_meshes() -> void:
	_box = BoxMesh.new()
	_box.size = Vector3.ONE

	_plane = PlaneMesh.new()
	_plane.size = Vector2.ONE
	_plane.orientation = PlaneMesh.FACE_Y

	_quad = QuadMesh.new()
	_quad.size = Vector2.ONE

	_cylinder = CylinderMesh.new()
	_cylinder.top_radius = 0.5
	_cylinder.bottom_radius = 0.5
	_cylinder.height = 1.0
	_cylinder.radial_segments = 6      # столбов тысячи, 6 граней достаточно
	_cylinder.rings = 1


# --------------------------------------------------------------- материалы

func _build_materials() -> void:
	facade = _make_shader_material(FACADE_SHADER, "facade")
	neon = _make_shader_material(NEON_SHADER, "neon")
	road = _make_shader_material(ROAD_SHADER, "road")
	water = _make_shader_material(WATER_SHADER, "water")

	if road != null:
		road_arterial = road.duplicate() as ShaderMaterial
		if road_arterial != null:
			road_arterial.set_shader_parameter("lane_glow", 1.6)

	if facade != null:
		facade_far = facade.duplicate() as ShaderMaterial

	_ready_ok = facade != null and facade_far != null and neon != null and road != null and water != null

	concrete = StandardMaterial3D.new()
	concrete.albedo_color = CityAtlas.palette("base_concrete")
	concrete.roughness = 0.82
	concrete.metallic = 0.0

	metal = StandardMaterial3D.new()
	metal.albedo_color = Color(0.10, 0.11, 0.13)
	metal.roughness = 0.42
	metal.metallic = 0.75

	interior_wall = StandardMaterial3D.new()
	interior_wall.albedo_color = Color(0.13, 0.12, 0.14)
	interior_wall.roughness = 0.9
	interior_wall.cull_mode = BaseMaterial3D.CULL_DISABLED

	interior_floor = StandardMaterial3D.new()
	interior_floor.albedo_color = Color(0.08, 0.075, 0.085)
	interior_floor.roughness = 0.55
	interior_floor.metallic = 0.1

	furniture = StandardMaterial3D.new()
	furniture.albedo_color = Color(0.16, 0.13, 0.12)
	furniture.roughness = 0.72


func _make_shader_material(path: String, label: String) -> ShaderMaterial:
	if not ResourceLoader.exists(path):
		Log.error("CityMaterials", "Шейдер не найден", {"путь": path})
		return null
	var shader: Shader = load(path) as Shader
	if shader == null:
		Log.error("CityMaterials", "Шейдер не загрузился", {"путь": path})
		return null
	var material := ShaderMaterial.new()
	material.shader = shader
	material.resource_name = "noir_" + label
	return material


# ---------------------------------------------------------------- качество

## Настройки, зависящие от пресета. Значения подобраны так, чтобы «Картошка»
## оставалась читаемой, а «Perfecto» соответствовала референсу.
const QUALITY_TABLE: Dictionary = {
	"Картошка":      {"wetness": 0.0, "grime": 0.2, "neon_energy": 4.0, "facade_energy": 0.42, "waves": 0.0, "ripples": 0.0, "lane_glow": 0.9},
	"Очень Низкие":  {"wetness": 0.15, "grime": 0.3, "neon_energy": 4.5, "facade_energy": 0.44, "waves": 0.05, "ripples": 0.0, "lane_glow": 1.0},
	"Низкие":        {"wetness": 0.3, "grime": 0.4, "neon_energy": 5.0, "facade_energy": 0.46, "waves": 0.1, "ripples": 0.1, "lane_glow": 1.1},
	"Средние":       {"wetness": 0.45, "grime": 0.5, "neon_energy": 5.5, "facade_energy": 0.48, "waves": 0.15, "ripples": 0.2, "lane_glow": 1.2},
	"Высокие":       {"wetness": 0.6, "grime": 0.6, "neon_energy": 6.0, "facade_energy": 0.50, "waves": 0.22, "ripples": 0.35, "lane_glow": 1.3},
	"Ультра":        {"wetness": 0.75, "grime": 0.68, "neon_energy": 6.5, "facade_energy": 0.52, "waves": 0.28, "ripples": 0.5, "lane_glow": 1.4},
	"Экстремальные": {"wetness": 0.85, "grime": 0.72, "neon_energy": 7.0, "facade_energy": 0.54, "waves": 0.32, "ripples": 0.65, "lane_glow": 1.5},
	"Perfecto":      {"wetness": 1.0, "grime": 0.78, "neon_energy": 7.5, "facade_energy": 0.56, "waves": 0.38, "ripples": 0.85, "lane_glow": 1.6},
}


func apply_quality(preset: String) -> void:
	var settings: Variant = QUALITY_TABLE.get(preset, null)
	if not (settings is Dictionary):
		Log.warn("CityMaterials", "Неизвестный пресет — беру «Высокие»", {"пресет": preset})
		settings = QUALITY_TABLE["Высокие"]
	var q: Dictionary = settings as Dictionary

	if facade != null:
		facade.set_shader_parameter("wetness", float(q["wetness"]))
		facade.set_shader_parameter("grime", float(q["grime"]))
		facade.set_shader_parameter("emission_energy", float(q["facade_energy"]))
		facade.set_shader_parameter("roof_glow", 0.1)
	if facade_far != null:
		facade_far.set_shader_parameter("wetness", 0.0)   # блики вдали не читаются
		facade_far.set_shader_parameter("grime", float(q["grime"]) * 0.5)
		facade_far.set_shader_parameter("emission_energy", float(q["facade_energy"]) * 8.5)
		facade_far.set_shader_parameter("roof_glow", 0.95)
	if neon != null:
		neon.set_shader_parameter("energy", float(q["neon_energy"]))
	if road != null:
		road.set_shader_parameter("wetness", float(q["wetness"]))
	if road_arterial != null:
		road_arterial.set_shader_parameter("wetness", float(q["wetness"]))
		road_arterial.set_shader_parameter("lane_glow", float(q["lane_glow"]))
	if water != null:
		water.set_shader_parameter("wave_strength", float(q["waves"]))
		water.set_shader_parameter("rain_ripples", float(q["ripples"]))

	quality_applied.emit(preset)
	Log.debug("CityMaterials", "Пресет применён к материалам", {"пресет": preset})


func _on_setting_changed(section: String, key: String, value: Variant) -> void:
	if section == "graphics" and key == "preset":
		apply_quality(str(value))
