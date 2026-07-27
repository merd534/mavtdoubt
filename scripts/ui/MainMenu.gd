class_name NoirMainMenu
extends Control
## Главное меню — первая сцена игры.
##
## Почему UI собирается кодом: так же работает [NoirSettingsMenu], и меню
## остаётся одним файлом — масштаб интерфейса и шрифты из раздела
## «Доступность» применяются без ручной правки сцены.
##
## Горячих клавиш больше нет: все настройки доступны кнопкой «Настройки»
## здесь и в меню паузы.

const GAME_SCENE := "res://scenes/dev/Phase3DetailBench.tscn"
const SETTINGS_SCENE := "res://scenes/ui/SettingsMenu.tscn"

var _settings: NoirSettingsMenu = null
var _status: Label = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# В главном меню игра всегда распаузена и курсор виден:
	# сюда можно попасть из паузы, где оба состояния были другими.
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	_build_ui()
	_attach_settings()
	Log.info("MainMenu", "Главное меню открыто")


func _build_ui() -> void:
	var background := ColorRect.new()
	background.name = "Background"
	background.color = Color(0.035, 0.042, 0.062, 1.0)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var glow := ColorRect.new()
	glow.name = "Glow"
	glow.color = Color(0.10, 0.16, 0.28, 0.55)
	glow.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	glow.custom_minimum_size = Vector2(0.0, 240.0)
	glow.offset_top = -240.0
	add_child(glow)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.set_anchors_preset(Control.PRESET_CENTER)
	column.anchor_left = 0.5
	column.anchor_top = 0.5
	column.anchor_right = 0.5
	column.anchor_bottom = 0.5
	column.offset_left = -220.0
	column.offset_top = -220.0
	column.offset_right = 220.0
	column.offset_bottom = 220.0
	column.add_theme_constant_override("separation", 12)
	add_child(column)

	var title := Label.new()
	title.text = "MAVT DOUBT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(0.85, 0.93, 1.0))
	column.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "нуарный детектив в дождливом мегаполисе"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", Color(0.6, 0.68, 0.8))
	column.add_child(subtitle)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, 28.0)
	column.add_child(gap)

	column.add_child(_make_button("Новое дело", _on_play_pressed))
	column.add_child(_make_button("Настройки", _on_settings_pressed))
	column.add_child(_make_button("Выход", _on_quit_pressed))

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", Color(0.55, 0.62, 0.74))
	_status.text = "Время суток, графика и сложность — в настройках"
	column.add_child(_status)


func _make_button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(320.0, 46.0)
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(handler)
	return button


## Меню настроек — отдельная сцена, поэтому добавляем её в рунтайме,
## а не дублируем сотни контролов в каждой сцене.
func _attach_settings() -> void:
	_settings = get_node_or_null("SettingsMenu") as NoirSettingsMenu
	if _settings != null:
		return
	if not ResourceLoader.exists(SETTINGS_SCENE):
		Log.error("MainMenu", "Сцена настроек не найдена", {"путь": SETTINGS_SCENE})
		return
	var packed: PackedScene = load(SETTINGS_SCENE) as PackedScene
	if packed == null:
		Log.error("MainMenu", "Сцена настроек не загрузилась", {"путь": SETTINGS_SCENE})
		return
	var instance: Node = packed.instantiate()
	instance.name = "SettingsMenu"
	add_child(instance)
	_settings = instance as NoirSettingsMenu
	if _settings == null:
		Log.error("MainMenu", "Корень сцены настроек — не NoirSettingsMenu")


func _on_play_pressed() -> void:
	if not ResourceLoader.exists(GAME_SCENE):
		Log.error("MainMenu", "Игровая сцена не найдена", {"путь": GAME_SCENE})
		if _status != null:
			_status.text = "Игровая сцена не найдена"
		return
	GameConfig.save_settings()
	var error: int = get_tree().change_scene_to_file(GAME_SCENE)
	if error != OK:
		Log.error("MainMenu", "Не удалось загрузить сцену", {"код": error})
		if _status != null:
			_status.text = "Не удалось загрузить город (код %d)" % error


func _on_settings_pressed() -> void:
	if _settings == null:
		_attach_settings()
	if _settings != null:
		_settings.show_menu()


func _on_quit_pressed() -> void:
	GameConfig.save_settings()
	get_tree().quit()
