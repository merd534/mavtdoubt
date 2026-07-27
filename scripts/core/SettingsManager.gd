class_name NoirSettingsManager
extends Node
## Менеджер дисплея и рендера. Автозагрузка: `Settings`.
##
## Зачем отдельный автолоад рядом с `GameConfig`: `GameConfig` — это только
## хранилище чисел, он ничего не знает про Viewport и Environment. Здесь же живёт
## вся грязная работа: пресет -> десятки конкретных параметров рендера.
##
## Пресет жёстко перезаписывает ключи в `GameConfig`, а потом всё применяется
## из одного места ([method apply_all]).
##
## Важно: Environment не ищется по дереву автоматически. Сцена сама зовёт
## [method register_environment].

const PRESETS: Array[String] = [
	"Картошка",
	"Очень Низкие",
	"Низкие",
	"Средние",
	"Высокие",
	"Ультра",
	"Экстремальные",
	"Perfecto",
]

const FSR_MODE_NAMES: Array[String] = [
	"Производительность",
	"Сбалансированный",
	"Качество",
	"Нативное разрешение",
]

## Масштаб рендера для режимов FSR.
const FSR_SCALES: Array[float] = [0.5, 0.67, 0.77, 1.0]

## Потолок атласа теней. 16384 на многих видеокартах либо не создаётся
## вовсе, либо съедает больше гигабайта видеопамяти — именно из-за этого
## на «Экстремальных» и «Perfecto» тени ломались и мерцали.
const SHADOW_ATLAS_MAX := 8192

signal preset_applied(preset: String)
signal fov_changed(fov: float)
signal sensitivity_changed(normal: float, scan: float)
signal quality_reapplied()

## Таблица пресетов. Каждый пресет — полный набор ключей секции graphics,
## чтобы переключение не оставляло хвостов от предыдущего.
const PRESET_TABLE: Dictionary = {
	"Картошка": {
		"fsr_mode": 0, "fsr_sharpness": 0.2, "resolution_scale": 0.5,
		"shadow_atlas": 0, "sdfgi": false, "ssr": false, "ssao": false, "ssil": false,
		"volumetric_fog": false, "glow": false, "msaa": 0, "taa": false, "debanding": false,
		"anisotropy": 0, "texture_quality": 0,
		"render_distance_m": 220.0, "chunk_radius": 1, "npc_budget": 30,
		"detail_density": 0.0, "cables": false, "steam": false, "debris": false,
		"interior_furniture": false, "billboard_lights": 0, "hide_radius_chunks": 0,
		"facade_detail": 0,
	},
	"Очень Низкие": {
		"fsr_mode": 0, "fsr_sharpness": 0.25, "resolution_scale": 0.6,
		"shadow_atlas": 1024, "sdfgi": false, "ssr": false, "ssao": false, "ssil": false,
		"volumetric_fog": false, "glow": false, "msaa": 0, "taa": false, "debanding": false,
		"anisotropy": 0, "texture_quality": 0,
		"render_distance_m": 320.0, "chunk_radius": 2, "npc_budget": 60,
		"detail_density": 0.15, "cables": false, "steam": false, "debris": false,
		"interior_furniture": true, "billboard_lights": 0, "hide_radius_chunks": 0,
		"facade_detail": 1,
	},
	"Низкие": {
		"fsr_mode": 1, "fsr_sharpness": 0.25, "resolution_scale": 0.7,
		"shadow_atlas": 2048, "sdfgi": false, "ssr": false, "ssao": false, "ssil": false,
		"volumetric_fog": false, "glow": true, "msaa": 0, "taa": false, "debanding": true,
		"anisotropy": 1, "texture_quality": 1,
		"render_distance_m": 460.0, "chunk_radius": 3, "npc_budget": 100,
		"detail_density": 0.35, "cables": true, "steam": false, "debris": true,
		"interior_furniture": true, "billboard_lights": 1, "hide_radius_chunks": 1,
		"facade_detail": 2,
	},
	"Средние": {
		"fsr_mode": 2, "fsr_sharpness": 0.25, "resolution_scale": 0.85,
		"shadow_atlas": 2048, "sdfgi": false, "ssr": false, "ssao": true, "ssil": false,
		"volumetric_fog": false, "glow": true, "msaa": 0, "taa": true, "debanding": true,
		"anisotropy": 2, "texture_quality": 2,
		"render_distance_m": 650.0, "chunk_radius": 4, "npc_budget": 150,
		"detail_density": 0.55, "cables": true, "steam": true, "debris": true,
		"interior_furniture": true, "billboard_lights": 1, "hide_radius_chunks": 1,
		"facade_detail": 2,
	},
	"Высокие": {
		"fsr_mode": 2, "fsr_sharpness": 0.25, "resolution_scale": 1.0,
		"shadow_atlas": 4096, "sdfgi": true, "ssr": true, "ssao": true, "ssil": false,
		"volumetric_fog": true, "glow": true, "msaa": 1, "taa": true, "debanding": true,
		"anisotropy": 2, "texture_quality": 2,
		"render_distance_m": 900.0, "chunk_radius": 5, "npc_budget": 220,
		"detail_density": 0.8, "cables": true, "steam": true, "debris": true,
		"interior_furniture": true, "billboard_lights": 2, "hide_radius_chunks": 1,
		"facade_detail": 3,
	},
	"Ультра": {
		"fsr_mode": 3, "fsr_sharpness": 0.2, "resolution_scale": 1.0,
		"shadow_atlas": 8192, "sdfgi": true, "ssr": true, "ssao": true, "ssil": true,
		"volumetric_fog": true, "glow": true, "msaa": 2, "taa": true, "debanding": true,
		"anisotropy": 3, "texture_quality": 3,
		"render_distance_m": 1100.0, "chunk_radius": 6, "npc_budget": 300,
		"detail_density": 1.0, "cables": true, "steam": true, "debris": true,
		"interior_furniture": true, "billboard_lights": 3, "hide_radius_chunks": 2,
		"facade_detail": 4,
	},
	"Экстремальные": {
		"fsr_mode": 3, "fsr_sharpness": 0.15, "resolution_scale": 1.15,
		"shadow_atlas": 8192, "sdfgi": true, "ssr": true, "ssao": true, "ssil": true,
		"volumetric_fog": true, "glow": true, "msaa": 3, "taa": true, "debanding": true,
		"anisotropy": 3, "texture_quality": 3,
		"render_distance_m": 1400.0, "chunk_radius": 7, "npc_budget": 380,
		"detail_density": 1.25, "cables": true, "steam": true, "debris": true,
		"interior_furniture": true, "billboard_lights": 4, "hide_radius_chunks": 2,
		"facade_detail": 4,
	},
	"Perfecto": {
		"fsr_mode": 3, "fsr_sharpness": 0.1, "resolution_scale": 1.35,
		"shadow_atlas": 8192, "sdfgi": true, "ssr": true, "ssao": true, "ssil": true,
		"volumetric_fog": true, "glow": true, "msaa": 3, "taa": true, "debanding": true,
		"anisotropy": 3, "texture_quality": 3,
		"render_distance_m": 1800.0, "chunk_radius": 8, "npc_budget": 460,
		"detail_density": 1.5, "cables": true, "steam": true, "debris": true,
		"interior_furniture": true, "billboard_lights": 6, "hide_radius_chunks": 3,
		"facade_detail": 4,
	},
}

var _environment: Environment = null
var _sun: DirectionalLight3D = null
var _applying: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameConfig.setting_changed.connect(_on_setting_changed)
	# Дожидаемся кадра: в _ready() автолоада Viewport ещё не имеет финального
	# размера, и scaling_3d_scale применяется к нулевому буферу.
	await get_tree().process_frame
	apply_all()


# ------------------------------------------------------------------ пресеты

func preset_names() -> Array[String]:
	return PRESETS.duplicate()


func current_preset() -> String:
	var preset_name: String = GameConfig.get_string("graphics", "preset")
	return preset_name if PRESETS.has(preset_name) else "Высокие"


func preset_index() -> int:
	return maxi(0, PRESETS.find(current_preset()))


## Жёстко переключает все параметры рендера под пресет.
func apply_preset(preset: String) -> bool:
	if not PRESET_TABLE.has(preset):
		Log.warn("Settings", "Неизвестный пресет — проигнорирован", {"пресет": preset})
		return false

	_applying = true
	GameConfig.set_value("graphics", "preset", preset)
	var values: Dictionary = PRESET_TABLE[preset]
	for key: Variant in values.keys():
		GameConfig.set_value("graphics", str(key), values[key])
	_applying = false

	apply_all()
	GameConfig.save_settings()
	preset_applied.emit(preset)
	Log.info("Settings", "Применён графический пресет", {"пресет": preset})
	return true


func apply_preset_index(index: int) -> bool:
	if index < 0 or index >= PRESETS.size():
		return false
	return apply_preset(PRESETS[index])


# ------------------------------------------------------------------ применение

## Главная точка входа. Безопасна для повторных вызовов.
func apply_all() -> void:
	_apply_window()
	_apply_viewport()
	_apply_shadows()
	_apply_textures()
	_apply_environment()
	_apply_ui_scale()
	_apply_materials()
	sensitivity_changed.emit(
		GameConfig.get_float("controls", "mouse_sensitivity"),
		GameConfig.get_float("controls", "scan_sensitivity")
	)
	fov_changed.emit(GameConfig.get_float("controls", "fov"))


func _apply_window() -> void:
	var vsync: int = clampi(GameConfig.get_int("graphics", "vsync"), 0, 3)
	DisplayServer.window_set_vsync_mode(vsync as DisplayServer.VSyncMode)
	Engine.max_fps = maxi(0, GameConfig.get_int("graphics", "fps_limit"))


## FSR и масштабирование. Итоговый масштаб = режим FSR × ползунок игрока.
func _apply_viewport() -> void:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		Log.warn("Settings", "Viewport недоступен — настройки рендера не применены")
		return

	var mode: int = clampi(GameConfig.get_int("graphics", "fsr_mode"), 0, 3)
	var user_scale: float = clampf(GameConfig.get_float("graphics", "resolution_scale"), 0.25, 2.0)
	var scale: float = clampf(FSR_SCALES[mode] * user_scale, 0.25, 2.0)

	if scale >= 1.0:
		# Натив и сверхсемплинг: FSR2 выключаем. Апскейлер при масштабе > 1
		# только вредит: платим за пересборку кадра и получаем артефакты
		# на тонких деталях и кромках теней.
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	else:
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2

	viewport.scaling_3d_scale = scale
	viewport.fsr_sharpness = clampf(GameConfig.get_float("graphics", "fsr_sharpness"), 0.0, 2.0)
	viewport.msaa_3d = clampi(GameConfig.get_int("graphics", "msaa"), 0, 3) as Viewport.MSAA
	viewport.use_taa = GameConfig.get_bool("graphics", "taa")
	viewport.use_debanding = GameConfig.get_bool("graphics", "debanding")
	# FXAA включаем только там, где нет ни MSAA, ни TAA.
	var want_fxaa: bool = viewport.msaa_3d == Viewport.MSAA_DISABLED and not viewport.use_taa
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if want_fxaa else Viewport.SCREEN_SPACE_AA_DISABLED


## Тени. Здесь живут три исправления багов верхних пресетов:
## 1. атлас ограничен 8192 — 16384 многие гпу просто не выдают;
## 2. 16-битная точность теперь только на малых атласах (было наоборот,
##    из-за этого на «Perfecto» тени рябили и полосили);
## 3. биасы, сплиты и дальность теней задаются явно под каждый пресет.
func _apply_shadows() -> void:
	var requested: int = maxi(0, GameConfig.get_int("graphics", "shadow_atlas"))
	var viewport: Viewport = get_viewport()

	if requested <= 0:
		# Полное отключение теней (режим «Картошка»).
		if viewport != null:
			viewport.positional_shadow_atlas_size = 256
		RenderingServer.directional_shadow_atlas_set_size(256, false)
		_set_sun_shadow(false)
		_apply_shadow_filters(0)
		return

	var atlas: int = clampi(requested, 512, SHADOW_ATLAS_MAX)
	if atlas != requested:
		Log.debug("Settings", "Атлас теней ограничен потолком", {"запрошено": requested, "применено": atlas})

	var low_precision: bool = atlas <= 2048
	if viewport != null:
		viewport.positional_shadow_atlas_size = atlas
		viewport.positional_shadow_atlas_16_bits = low_precision
		# Квадранты атласа: город — это много мелких омни-ламп, а не
		# несколько огромных, поэтому дробим помельче.
		viewport.positional_shadow_atlas_quad_0 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_4
		viewport.positional_shadow_atlas_quad_1 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_16
		viewport.positional_shadow_atlas_quad_2 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_16
		viewport.positional_shadow_atlas_quad_3 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_64

	RenderingServer.directional_shadow_atlas_set_size(atlas, low_precision)
	_set_sun_shadow(true)
	_apply_shadow_filters(atlas)
	_apply_sun_shadow_tuning(atlas)


## Качество фильтра мягких теней. На верхних пресетах без этого большой
## атлас давал резкий шум по кромкам вместо плавной тени.
func _apply_shadow_filters(atlas: int) -> void:
	var quality: int = RenderingServer.SHADOW_QUALITY_HARD
	if atlas >= 8192:
		quality = RenderingServer.SHADOW_QUALITY_SOFT_ULTRA
	elif atlas >= 4096:
		quality = RenderingServer.SHADOW_QUALITY_SOFT_HIGH
	elif atlas >= 2048:
		quality = RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM
	elif atlas > 0:
		quality = RenderingServer.SHADOW_QUALITY_SOFT_LOW

	if RenderingServer.has_method("directional_soft_shadow_filter_set_quality"):
		RenderingServer.directional_soft_shadow_filter_set_quality(quality)
	if RenderingServer.has_method("positional_soft_shadow_filter_set_quality"):
		RenderingServer.positional_soft_shadow_filter_set_quality(quality)


## Настройка самого солнца/луны. Город из сотен высотных боксов — самый
## тяжёлый случай для PSSM: без явных сплитов и биасов на дальних
## каскадах тень отрывается от основания здания или полосит.
func _apply_sun_shadow_tuning(atlas: int) -> void:
	if _sun == null or not is_instance_valid(_sun):
		return

	var render_distance: float = clampf(GameConfig.get_float("graphics", "render_distance_m"), 200.0, 2000.0)
	# Дальность теней не равна дальности отрисовки: растянутый на километр
	# каскад — гарантированная гребёнка на ближних объектах.
	var shadow_distance: float = clampf(render_distance * 0.35, 180.0, 420.0)

	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun.directional_shadow_max_distance = shadow_distance
	_sun.directional_shadow_split_1 = 0.06
	_sun.directional_shadow_split_2 = 0.16
	_sun.directional_shadow_split_3 = 0.42
	_sun.directional_shadow_blend_splits = true
	_sun.directional_shadow_fade_start = 0.85
	# Размер pancake: высотные здания требуют большого запаса по высоте,
	# иначе тени от вершин обрезаются и мигают при повороте камеры.
	_sun.directional_shadow_pancake_size = 120.0

	# Биас масштабируем обратно разрешению атласа: чем больше атлас,
	# тем мельче тексель и тем меньше нужно смещение.
	var texel_scale: float = clampf(4096.0 / float(maxi(512, atlas)), 0.4, 4.0)
	_sun.shadow_bias = clampf(0.045 * texel_scale, 0.012, 0.16)
	_sun.shadow_normal_bias = clampf(1.4 * texel_scale, 0.6, 4.0)
	_sun.shadow_transmittance_bias = 0.05
	_sun.shadow_opacity = 1.0
	_sun.shadow_blur = clampf(0.9 * texel_scale, 0.5, 1.6)


func _set_sun_shadow(enabled: bool) -> void:
	if _sun != null and is_instance_valid(_sun):
		_sun.shadow_enabled = enabled


func _apply_textures() -> void:
	var aniso: int = clampi(GameConfig.get_int("graphics", "anisotropy"), 0, 3)
	if ProjectSettings.has_setting("rendering/textures/default_filters/anisotropic_filtering_level"):
		ProjectSettings.set_setting("rendering/textures/default_filters/anisotropic_filtering_level", aniso)

	# Масштаб текстур в нашей игре — это разрешение процедурного атласа
	# фасадов; его пересборка требует перезапуска сцены.


## Подключает Environment сцены. Одновременно применяет к нему настройки.
func register_environment(env: Environment, sun: DirectionalLight3D = null) -> void:
	if env == null:
		Log.warn("Settings", "register_environment получил null")
		return
	_environment = env
	if sun != null:
		_sun = sun
	_apply_environment()
	_apply_shadows()
	Log.debug("Settings", "Environment зарегистрирован", {"солнце": sun != null})


func _apply_environment() -> void:
	if _environment == null or not is_instance_valid(_environment):
		return

	var env: Environment = _environment
	var preset: String = current_preset()
	var heavy: bool = preset in ["Ультра", "Экстремальные", "Perfecto"]

	# Глобальное освещение.
	env.sdfgi_enabled = GameConfig.get_bool("graphics", "sdfgi")
	if env.sdfgi_enabled:
		env.sdfgi_cascades = 6 if heavy else 4
		env.sdfgi_use_occlusion = heavy
		env.sdfgi_energy = 1.15 if preset == "Perfecto" else 1.0
		env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_75_PERCENT
		# Без отступа пробы SDFGI цепляют стены и дают тёмные пятна
		# рядом с тенями небоскрёбов.
		env.sdfgi_normal_bias = 1.1
		env.sdfgi_probe_bias = 1.1

	# Отражения в экранном пространстве — главный источник нуара на мокром асфальте.
	env.ssr_enabled = GameConfig.get_bool("graphics", "ssr")
	if env.ssr_enabled:
		env.ssr_max_steps = 128 if preset == "Perfecto" else (64 if heavy else 32)
		env.ssr_fade_in = 0.15
		env.ssr_fade_out = 2.0
		env.ssr_depth_tolerance = 0.2

	env.ssao_enabled = GameConfig.get_bool("graphics", "ssao")
	if env.ssao_enabled:
		env.ssao_radius = 1.2
		env.ssao_intensity = 2.2
		env.ssao_detail = 0.5
	env.ssil_enabled = GameConfig.get_bool("graphics", "ssil")

	# Объёмный туман: свет от неонки в дождевом воздухе.
	# Плотность днём пересчитывает NoirSkyController — здесь только потолки.
	env.volumetric_fog_enabled = GameConfig.get_bool("graphics", "volumetric_fog")
	if env.volumetric_fog_enabled:
		env.volumetric_fog_length = 96.0 if heavy else 64.0
		env.volumetric_fog_detail_spread = 2.0
		env.volumetric_fog_gi_inject = 1.0 if env.sdfgi_enabled else 0.0
		env.volumetric_fog_albedo = Color(0.62, 0.66, 0.74)

	env.glow_enabled = GameConfig.get_bool("graphics", "glow")
	if env.glow_enabled:
		env.glow_intensity = 0.75
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
		# Порог и bloom докручивает NoirSkyController по времени суток.

	quality_reapplied.emit()


func _apply_ui_scale() -> void:
	var root: Window = get_tree().root
	if root == null:
		return
	var scale: float = clampf(GameConfig.get_float("accessibility", "ui_scale"), 0.7, 2.0)
	root.content_scale_factor = scale


## Пробрасывает пресет в материалы города (сила неона, блики, сканлайны).
func _apply_materials() -> void:
	if CityMaterials == null or not CityMaterials.has_method("apply_quality"):
		return
	CityMaterials.apply_quality(current_preset())


# ---------------------------------------------------------------- удобные сеттеры

func set_fsr_mode(mode: int) -> void:
	GameConfig.set_value("graphics", "fsr_mode", clampi(mode, 0, 3))


func fsr_mode_name(mode: int) -> String:
	return FSR_MODE_NAMES[clampi(mode, 0, 3)]


func set_fov(fov: float) -> void:
	GameConfig.set_value("controls", "fov", clampf(fov, 60.0, 110.0))


func set_mouse_sensitivity(value: float) -> void:
	GameConfig.set_value("controls", "mouse_sensitivity", clampf(value, 0.02, 1.2))


func set_scan_sensitivity(value: float) -> void:
	GameConfig.set_value("controls", "scan_sensitivity", clampf(value, 0.01, 0.6))


func set_ui_scale(value: float) -> void:
	GameConfig.set_value("accessibility", "ui_scale", clampf(value, 0.7, 2.0))


## Сводка для отладочного HUD.
func summary() -> Dictionary:
	var viewport: Viewport = get_viewport()
	var window_size: Vector2i = DisplayServer.window_get_size()
	var scale: float = viewport.scaling_3d_scale if viewport != null else 1.0
	return {
		"preset": current_preset(),
		"fsr": fsr_mode_name(GameConfig.get_int("graphics", "fsr_mode")),
		"scale": scale,
		"render": "%dx%d" % [int(float(window_size.x) * scale), int(float(window_size.y) * scale)],
		"window": "%dx%d" % [window_size.x, window_size.y],
		"fps_limit": Engine.max_fps,
	}


# ---------------------------------------------------------------- реакция на изменения

func _on_setting_changed(section: String, key: String, value: Variant) -> void:
	# Пока идёт массовая заливка пресета, не переприменяем рендер на каждый ключ.
	if _applying:
		return

	if section == "controls":
		match key:
			"fov":
				fov_changed.emit(float(value))
			"mouse_sensitivity", "scan_sensitivity":
				sensitivity_changed.emit(
					GameConfig.get_float("controls", "mouse_sensitivity"),
					GameConfig.get_float("controls", "scan_sensitivity")
				)
		return

	if section == "accessibility" and key == "ui_scale":
		_apply_ui_scale()
		return

	if section != "graphics":
		return

	match key:
		"vsync", "fps_limit":
			_apply_window()
		"fsr_mode", "fsr_sharpness", "resolution_scale", "msaa", "taa", "debanding":
			_apply_viewport()
		"shadow_atlas", "render_distance_m":
			_apply_shadows()
		"anisotropy", "texture_quality":
			_apply_textures()
		"sdfgi", "ssr", "ssao", "ssil", "volumetric_fog", "glow":
			_apply_environment()
		"preset":
			_apply_materials()
