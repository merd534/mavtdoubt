class_name NoirPhase3DetailBench
extends Node3D
## Стенд фаз 3-6. Проверяет детализацию зданий, стриминг, окклюзию,
## графические пресеты и меню настроек в боевом режиме.
##
## Клавиши:
##   F1 — открыть/закрыть меню настроек
##   F2 — следующий графический пресет (по кругу, от «Картошки» до Perfecto)
##   F3 — следующий пресет сложности
##   F4 — Occlusion Culling вкл/выкл (сравнить FPS и draw calls)
##   F5 — догрузить всю очередь чанков немедленно
##   F6 — открыть ближайший интерьер принудительно
##   F7 — пересчитать окружение (refresh)

const HUD_INTERVAL := 0.25

@export var start_position: Vector3 = Vector3(-120.0, 24.0, 260.0)

var _generator: NoirCityGenerator = null
var _player: Node3D = null
var _stats: RichTextLabel = null
var _menu: NoirSettingsMenu = null
var _world_env: WorldEnvironment = null
var _sun: DirectionalLight3D = null
var _hud_timer: float = 0.0
var _last_message: String = ""


func _ready() -> void:
	_generator = get_node_or_null("CityGenerator") as NoirCityGenerator
	_player = get_node_or_null("Player") as Node3D
	_stats = get_node_or_null("UI/Stats") as RichTextLabel
	_menu = get_node_or_null("SettingsMenu") as NoirSettingsMenu
	_world_env = get_node_or_null("WorldEnvironment") as WorldEnvironment
	_sun = get_node_or_null("MoonLight") as DirectionalLight3D

	if _generator == null:
		Log.error("Phase3Bench", "Узел CityGenerator не найден — стенд не работает")
		set_process(false)
		return

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

	_generator.chunk_built.connect(_on_chunk_built)
	_generator.interior_opened.connect(_on_interior_opened)
	Settings.preset_applied.connect(_on_preset_applied)
	Difficulty.difficulty_applied.connect(_on_difficulty_applied)

	_last_message = "Стенд готов. F1 — настройки."
	Log.info("Phase3Bench", "Стенд фаз 3-6 запущен", {
		"пресет": Settings.current_preset(),
		"сложность": Difficulty.current_preset(),
	})


func _process(delta: float) -> void:
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = HUD_INTERVAL
		_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event as InputEventKey
	if not key.pressed or key.echo:
		return

	match key.keycode:
		KEY_F1:
			if _menu != null:
				_menu.toggle_menu()
				get_viewport().set_input_as_handled()
		KEY_F2:
			_cycle_graphics_preset()
			get_viewport().set_input_as_handled()
		KEY_F3:
			_cycle_difficulty()
			get_viewport().set_input_as_handled()
		KEY_F4:
			_toggle_occlusion()
			get_viewport().set_input_as_handled()
		KEY_F5:
			var built: int = _generator.flush_queue()
			_last_message = "Догружено чанков сразу: %d" % built
			get_viewport().set_input_as_handled()
		KEY_F6:
			_open_nearest_interior()
			get_viewport().set_input_as_handled()
		KEY_F7:
			_generator.refresh()
			_last_message = "Окружение пересчитано"
			get_viewport().set_input_as_handled()


func _cycle_graphics_preset() -> void:
	var presets: Array[String] = Settings.preset_names()
	var next: int = (Settings.preset_index() + 1) % presets.size()
	Settings.apply_preset(presets[next])


func _cycle_difficulty() -> void:
	var presets: Array[String] = Difficulty.preset_names()
	var next: int = (Difficulty.preset_index() + 1) % presets.size()
	Difficulty.apply_preset(presets[next])


func _toggle_occlusion() -> void:
	_generator.use_occlusion_culling = not _generator.use_occlusion_culling
	var viewport: Viewport = get_viewport()
	if viewport != null:
		RenderingServer.viewport_set_use_occlusion_culling(
			viewport.get_viewport_rid(),
			_generator.use_occlusion_culling
		)
	_last_message = "Occlusion Culling: " + ("вкл" if _generator.use_occlusion_culling else "выкл")


func _open_nearest_interior() -> void:
	var stats: Dictionary = _generator.stats()
	if int(stats.get("entrances", 0)) <= 0:
		_last_message = "Вблизи нет подъездов — подойдите ближе к застройке"
		return

	# Берём ближайший вход из загруженных чанков и открываем его принудительно.
	var chunks_root: Node = _generator.get_node_or_null("Chunks")
	if chunks_root == null:
		_last_message = "Узел Chunks не найден"
		return

	var best_id: String = ""
	var best_distance: float = 1e12
	var origin: Vector3 = _generator.observer_position()
	for child: Node in chunks_root.get_children():
		if not (child is NoirCityChunk):
			continue
		for entry: Variant in (child as NoirCityChunk).entrances():
			var data: Dictionary = entry as Dictionary
			var position: Vector3 = data.get("position", Vector3.ZERO)
			var distance: float = origin.distance_to(position)
			if distance < best_distance:
				best_distance = distance
				best_id = str(data.get("location_id", ""))

	if best_id.is_empty():
		_last_message = "Подходящий вход не найден"
		return

	var interior: Node3D = _generator.open_interior_now(best_id)
	if interior == null:
		_last_message = "Интерьер не собрался: " + best_id
		return
	_last_message = "Открыт интерьер %s (%.0f м)" % [best_id, best_distance]


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
	lines.append("[b]ФАЗЫ 3-6 — стенд детализации[/b]   FPS: [b]%.0f[/b]" % fps)
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
	lines.append("F1 настройки | F2 пресет | F3 сложность | F4 окклюзия | F5 догрузка | F6 интерьер | F7 refresh")
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
