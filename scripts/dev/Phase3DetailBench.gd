class_name NoirPhase3DetailBench
extends Node3D
## Игровая сцена фаз 3-6: детализация зданий, наполнение улиц, стриминг,
## окклюзия, графические пресеты и время суток.
##
## Управление: WASD — движение, мышь — обзор, Esc — пауза и настройки.
## Горячие клавиши F1-F7 удалены: всё, что они делали, живёт в меню настроек.
##
## Свет, небо и туман считает [NoirSkyController]: сцена только сообщает ему
## текущее время и настройки раздела «Мир».

const HUD_INTERVAL := 0.25
const PAUSE_MENU_SCENE := "res://scenes/ui/PauseMenu.tscn"

@export var start_position: Vector3 = Vector3(-120.0, 24.0, 260.0)

var _generator: NoirCityGenerator = null
var _player: Node3D = null
var _stats: RichTextLabel = null
var _menu: NoirSettingsMenu = null
var _pause: NoirPauseMenu = null
var _world_env: WorldEnvironment = null
var _sun: DirectionalLight3D = null
var _hud_timer: float = 0.0
var _last_message: String = ""
var _base_sun_energy: float = 1.0
var _base_ambient_energy: float = 1.0


func _ready() -> void:
	_generator = get_node_or_null("CityGenerator") as NoirCityGenerator
	_player = get_node_or_null("Player") as Node3D
	_stats = get_node_or_null("UI/Stats") as RichTextLabel
	_menu = get_node_or_null("SettingsMenu") as NoirSettingsMenu
	_world_env = get_node_or_null("WorldEnvironment") as WorldEnvironment
	_sun = get_node_or_null("MoonLight") as DirectionalLight3D

	if _generator == null:
		Log.error("Phase3Bench", "Узел CityGenerator не найден — сцена не работает")
		set_process(false)
		return

	if _sun != null:
		_base_sun_energy = _sun.light_energy
	if _world_env != null and _world_env.environment != null:
		_base_ambient_energy = _world_env.environment.ambient_light_energy

	if _player != null:
		_player.global_position = start_position
		_generator.set_observer(_player)
	else:
		_generator.set_observer_position(start_position)
		Log.warn("Phase3Bench", "Игрок не найден — наблюдатель задан точкой")

	# Отдаём Environment менеджеру настроек: только после этого пресеты
	# умеют гасить SDFGI/SSR/туман в этой сцене.
	if _world_env != null and _world_env.environment != null:
		Settings.register_environment(_world_env.environment, _sun)
	else:
		Log.warn("Phase3Bench", "WorldEnvironment пуст — пресеты не управляют эффектами неба")

	_setup_pause_menu()

	_generator.chunk_built.connect(_on_chunk_built)
	_generator.interior_opened.connect(_on_interior_opened)
	Settings.preset_applied.connect(_on_preset_applied)
	# Пресет может выключить туман или bloom — после этого надо заново
	# разложить время суток по оставшимся параметрам.
	Settings.quality_reapplied.connect(_apply_world_look)
	Difficulty.difficulty_applied.connect(_on_difficulty_applied)

	if WorldClock != null:
		WorldClock.minute_changed.connect(_on_minute_changed)
		WorldClock.time_jumped.connect(_on_time_jumped)
	if GameConfig != null:
		GameConfig.setting_changed.connect(_on_setting_changed)
	_apply_world_look()

	_last_message = "Esc — пауза и настройки"
	Log.info("Phase3Bench", "Сцена фаз 3-6 запущена", {
		"пресет": Settings.current_preset(),
		"сложность": Difficulty.current_preset(),
		"время": WorldClock.time_string() if WorldClock != null else "?",
	})


## Меню паузы создаётся в рунтайме: так любая игровая сцена получает паузу
## одной строкой и не надо править .tscn.
func _setup_pause_menu() -> void:
	_pause = get_node_or_null("PauseMenu") as NoirPauseMenu
	if _pause == null:
		if not ResourceLoader.exists(PAUSE_MENU_SCENE):
			Log.error("Phase3Bench", "Сцена паузы не найдена", {"путь": PAUSE_MENU_SCENE})
			return
		var packed: PackedScene = load(PAUSE_MENU_SCENE) as PackedScene
		if packed == null:
			Log.error("Phase3Bench", "Сцена паузы не загрузилась")
			return
		var instance: Node = packed.instantiate()
		instance.name = "PauseMenu"
		add_child(instance)
		_pause = instance as NoirPauseMenu
	if _pause == null:
		return
	if _menu != null:
		_pause.set_settings_menu(_menu)
	_pause.resumed.connect(_on_resumed)


func _process(delta: float) -> void:
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = HUD_INTERVAL
		_update_hud()


# ------------------------------------------------------------- свет и время

## Всю грязную работу делает [NoirSkyController]; сцена только собирает
## входные числа. Подпись без аргументов — подходит и для сигналов.
func _apply_world_look() -> void:
	if WorldClock == null:
		return
	if _world_env == null or _world_env.environment == null:
		return

	var exposure: float = 1.0
	var night_boost: float = 1.0
	if GameConfig != null:
		exposure = GameConfig.get_float("world", "exposure")
		night_boost = GameConfig.get_float("world", "night_brightness")

	NoirSkyController.apply(
		_world_env.environment,
		_sun,
		WorldClock.minutes_of_day(),
		WorldClock.daylight(),
		WorldClock.sun_elevation_deg(),
		exposure,
		night_boost,
		_base_sun_energy,
		_base_ambient_energy
	)


func _on_minute_changed(_minutes_of_day: int) -> void:
	_apply_world_look()


func _on_time_jumped(_minutes_of_day: int) -> void:
	_apply_world_look()


func _on_setting_changed(section_name: String, key: String, _value: Variant) -> void:
	if section_name != "world":
		return
	if key == "exposure" or key == "night_brightness" or key == "time_of_day_min":
		_apply_world_look()


func _on_resumed() -> void:
	# После выхода из паузы возвращаем захват мыши — иначе обзор не работает.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ------------------------------------------------------------------------ HUD

func _update_hud() -> void:
	if _stats == null:
		return

	var stats: Dictionary = _generator.stats()
	var display: Dictionary = Settings.summary()
	var rules: Dictionary = Difficulty.rules()
	var fps: float = Engine.get_frames_per_second()
	var draw_calls: int = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var primitives: int = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var memory_mb: float = float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0

	var lines: Array[String] = []
	lines.append("[b]Неоновый мегаполис[/b]   FPS: [b]%.0f[/b]   время: [b]%s[/b]" % [
		fps,
		WorldClock.stamp_string() if WorldClock != null else "?",
	])
	lines.append("Пресет: [b]%s[/b]   FSR: %s   %s -> %s" % [
		str(display.get("preset", "?")),
		str(display.get("fsr", "?")),
		str(display.get("window", "?")),
		str(display.get("render", "?")),
	])
	lines.append("Чанки: %d (ближние %d / средние %d / дальние %d), скрытых %d, в очереди %d" % [
		int(stats.get("chunks_loaded", 0)),
		int(stats.get("chunks_near", 0)),
		int(stats.get("chunks_mid", 0)),
		int(stats.get("chunks_far", 0)),
		int(stats.get("chunks_hidden", 0)),
		int(stats.get("chunks_queued", 0)),
	])
	lines.append("Зданий: %d   подъездов: %d   открытых интерьеров: %d   ср. сборка: %.1f мс" % [
		int(stats.get("buildings", 0)),
		int(stats.get("entrances", 0)),
		int(stats.get("interiors_open", 0)),
		float(stats.get("avg_build_ms", 0.0)),
	])
	lines.append("Draw calls: %d   примитивов: %d   видеопамять: %.0f МБ   окклюзия: %s" % [
		draw_calls, primitives, memory_mb,
		"вкл" if bool(stats.get("occlusion", false)) else "выкл",
	])
	lines.append("Сложность: [b]%s[/b] — %s" % [
		str(rules.get("preset", "?")),
		Difficulty.describe(Difficulty.current_preset()),
	])
	lines.append("WASD — движение, мышь — обзор, [b]Esc — пауза и настройки[/b]")
	if not _last_message.is_empty():
		lines.append("[i]%s[/i]" % _last_message)

	_stats.text = "\n".join(lines)


func _on_chunk_built(coords: Vector2i, build_ms: int) -> void:
	if build_ms > 12:
		Log.debug("Phase3Bench", "Тяжёлый чанк", {"координаты": str(coords), "мс": build_ms})


func _on_interior_opened(location_id: String) -> void:
	_last_message = "Интерьер подгружен: " + location_id


func _on_preset_applied(preset: String) -> void:
	_last_message = "Графика: " + preset
	# После смены пресета меняются радиус стриминга и плотность деталей,
	# поэтому город надо пересобрать — иначе старые чанки останутся с деталями
	# от предыдущего качества.
	if _generator != null and is_instance_valid(_generator):
		_generator.refresh()


func _on_difficulty_applied(preset: String) -> void:
	_last_message = "Сложность: " + preset
