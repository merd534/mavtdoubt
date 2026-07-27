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
## Фазы 3-5 дёргают [method apply_quality], а не лезут в шейдеры руками.
##
## ФАЗА 3 добавила семь материалов детализации: стекло оконных ниш,
## кабели, ржавый металл инфраструктуры, картон, щиты, голограммы и два
## материала для GPU-частиц (пар и капли).

const FACADE_SHADER := "res://shaders/facade.gdshader"
const NEON_SHADER := "res://shaders/neon.gdshader"
const ROAD_SHADER := "res://shaders/road.gdshader"
const WATER_SHADER := "res://shaders/water.gdshader"
const HOLOGRAM_SHADER := "res://shaders/hologram.gdshader"

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

# --- ФАЗА 3 ---
## Стекло в глубине оконных ниш. Не прозрачное по-настоящему: прозрачность
## на тысячах инстансов ломает сортировку и стоит как отдельный проход.
var glass: StandardMaterial3D = null
var cable: StandardMaterial3D = null
var metal_rust: StandardMaterial3D = null
var cardboard: StandardMaterial3D = null
var billboard: ShaderMaterial = null
var hologram: ShaderMaterial = null
var steam_particle: StandardMaterial3D = null
var water_drop: StandardMaterial3D = null

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


## Единичный квад (стоит в XY, нормаль +Z). Вывески, стекло, голограммы.
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

	_build_detail_materials()


## ФАЗА 3. Материалы объёмной детализации.
func _build_detail_materials() -> void:
	# Оконное стекло в нишах. Цвет и светимость задаются цветом инстанса,
	# поэтому включаем vertex_color_use_as_albedo и emission от альбедо.
	glass = StandardMaterial3D.new()
	glass.albedo_color = Color(0.55, 0.62, 0.7)
	glass.vertex_color_use_as_albedo = true
	glass.roughness = 0.12
	glass.metallic = 0.55
	glass.metallic_specular = 0.9
	glass.emission_enabled = true
	glass.emission = Color(1.0, 0.86, 0.62)
	glass.emission_energy_multiplier = 0.35
	glass.cull_mode = BaseMaterial3D.CULL_BACK

	cable = StandardMaterial3D.new()
	cable.albedo_color = Color(0.045, 0.045, 0.05)
	cable.roughness = 0.85
	cable.metallic = 0.05
	cable.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Ржавая вентиляция и пожарные лестницы — теплее и грязнее чистого металла.
	metal_rust = StandardMaterial3D.new()
	metal_rust.albedo_color = Color(0.20, 0.13, 0.10)
	metal_rust.roughness = 0.78
	metal_rust.metallic = 0.45

	cardboard = StandardMaterial3D.new()
	cardboard.albedo_color = Color(0.26, 0.20, 0.14)
	cardboard.roughness = 0.95

	# Объёмные щиты — тот же неоновый шейдер, но со своими параметрами,
	# чтобы табло не пересвечивало мелкие вывески.
	if neon != null:
		billboard = neon.duplicate() as ShaderMaterial

	# Голограммы. Если шейдера нет, откатываемся на неон: лучше простой
	# светящийся квад, чем розовый материал-ошибка на всю улицу.
	hologram = _make_shader_material(HOLOGRAM_SHADER, "hologram")
	if hologram == null:
		Log.warn("CityMaterials", "Шейдер голограмм недоступен — беру неон")
		if neon != null:
			hologram = neon.duplicate() as ShaderMaterial

	# Частицы. Без теней и без записи в буфер глубины — иначе пар даёт
	# чёрные окантовки и ломает SSR на мокром асфальте.
	steam_particle = StandardMaterial3D.new()
	steam_particle.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	steam_particle.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	steam_particle.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	steam_particle.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	steam_particle.particles_anim_h_frames = 1
	steam_particle.particles_anim_v_frames = 1
	steam_particle.particles_anim_loop = false
	steam_particle.vertex_color_use_as_albedo = true
	steam_particle.albedo_color = Color(0.75, 0.8, 0.88, 0.16)
	steam_particle.disable_receive_shadows = true
	steam_particle.no_depth_test = false

	water_drop = StandardMaterial3D.new()
	water_drop.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water_drop.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	water_drop.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	water_drop.vertex_color_use_as_albedo = true
	water_drop.albedo_color = Color(0.66, 0.78, 0.9, 0.6)
	water_drop.disable_receive_shadows = true


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
## ФАЗА 3 добавила ключи детализации: яркость щитов и голограмм,
## светимость оконного стекла и плотность пара.
const QUALITY_TABLE: Dictionary = {
	"Картошка":      {"wetness": 0.0, "grime": 0.2, "neon_energy": 4.0, "facade_energy": 0.42, "waves": 0.0, "ripples": 0.0, "lane_glow": 0.9, "billboard_energy": 3.4, "hologram_energy": 0.0, "glass_glow": 0.15, "steam_alpha": 0.0, "scanlines": 24.0},
	"Очень Низкие":  {"wetness": 0.15, "grime": 0.3, "neon_energy": 4.5, "facade_energy": 0.44, "waves": 0.05, "ripples": 0.0, "lane_glow": 1.0, "billboard_energy": 3.8, "hologram_energy": 1.6, "glass_glow": 0.2, "steam_alpha": 0.08, "scanlines": 28.0},
	"Низкие":        {"wetness": 0.3, "grime": 0.4, "neon_energy": 5.0, "facade_energy": 0.46, "waves": 0.1, "ripples": 0.1, "lane_glow": 1.1, "billboard_energy": 4.2, "hologram_energy": 2.0, "glass_glow": 0.25, "steam_alpha": 0.11, "scanlines": 32.0},
	"Средние":       {"wetness": 0.45, "grime": 0.5, "neon_energy": 5.5, "facade_energy": 0.48, "waves": 0.15, "ripples": 0.2, "lane_glow": 1.2, "billboard_energy": 4.6, "hologram_energy": 2.6, "glass_glow": 0.3, "steam_alpha": 0.14, "scanlines": 40.0},
	"Высокие":       {"wetness": 0.6, "grime": 0.6, "neon_energy": 6.0, "facade_energy": 0.50, "waves": 0.22, "ripples": 0.35, "lane_glow": 1.3, "billboard_energy": 5.0, "hologram_energy": 3.0, "glass_glow": 0.35, "steam_alpha": 0.16, "scanlines": 48.0},
	"Ультра":        {"wetness": 0.75, "grime": 0.68, "neon_energy": 6.5, "facade_energy": 0.52, "waves": 0.28, "ripples": 0.5, "lane_glow": 1.4, "billboard_energy": 5.5, "hologram_energy": 3.6, "glass_glow": 0.4, "steam_alpha": 0.18, "scanlines": 64.0},
	"Экстремальные": {"wetness": 0.85, "grime": 0.72, "neon_energy": 7.0, "facade_energy": 0.54, "waves": 0.32, "ripples": 0.65, "lane_glow": 1.5, "billboard_energy": 6.0, "hologram_energy": 4.2, "glass_glow": 0.45, "steam_alpha": 0.2, "scanlines": 80.0},
	"Perfecto":      {"wetness": 1.0, "grime": 0.78, "neon_energy": 7.5, "facade_energy": 0.56, "waves": 0.38, "ripples": 0.85, "lane_glow": 1.6, "billboard_energy": 6.5, "hologram_energy": 5.0, "glass_glow": 0.5, "steam_alpha": 0.24, "scanlines": 110.0},
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

	# --- ФАЗА 3 ---
	if billboard != null:
		billboard.set_shader_parameter("energy", float(q["billboard_energy"]))
	if hologram != null:
		# Шейдер голограммы и фоллбек-неон делят юниформ `energy`,
		# поэтому лишние параметры просто игнорируются без ошибок.
		hologram.set_shader_parameter("energy", float(q["hologram_energy"]))
		hologram.set_shader_parameter("scan_density", float(q["scanlines"]))
		hologram.set_shader_parameter("flicker_amount", 0.35)
		hologram.set_shader_parameter("edge_softness", 0.45)
	if glass != null:
		glass.emission_energy_multiplier = float(q["glass_glow"])
	if steam_particle != null:
		var alpha: float = float(q["steam_alpha"])
		steam_particle.albedo_color = Color(0.75, 0.8, 0.88, alpha)

	quality_applied.emit(preset)
	Log.debug("CityMaterials", "Пресет применён к материалам", {"пресет": preset})


func _on_setting_changed(section: String, key: String, value: Variant) -> void:
	if section == "graphics" and key == "preset":
		apply_quality(str(value))
