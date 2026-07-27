class_name NoirPauseMenu
extends CanvasLayer
## Меню паузы. Вызывается Esc из любой игровой сцены.
##
## Сцена ставится на паузу через `get_tree().paused`, а само меню и меню
## настроек работают в режиме PROCESS_MODE_ALWAYS — иначе кнопки были бы
## мертвыми. Часы мира (PROCESS_MODE_PAUSABLE) на паузе стоят, но ползунок
## времени в настройках всё равно работает: он зовёт `set_minutes_of_day`
## напрямую, а не ждёт течения времени.

const MAIN_MENU_SCENE := "res://scenes/ui/MainMenu.tscn"
const SETTINGS_SCENE := "res://scenes/ui/SettingsMenu.tscn"
const PANEL_WIDTH := 380.0

## Игрок вернулся в игру — сцена должна снова захватить курсор.
signal resumed()
## Меню открыто — сцена должна отпустить курсор.
signal shown()

var _root: Control = null
var _settings: NoirSettingsMenu = null
var _clock_label: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 80
	_build_ui()
	_root.visible = false


## Сцена передаёт своё меню настроек, чтобы не создавать второе.
func set_settings_menu(menu: NoirSettingsMenu) -> void:
	if menu != null and is_instance_valid(menu):
		_settings = menu


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.04, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.set_anchors_preset(Control.PRESET_CENTER)
	column.anchor_left = 0.5
	column.anchor_top = 0.5
	column.anchor_right = 0.5
	column.anchor_bottom = 0.5
	column.offset_left = -PANEL_WIDTH * 0.5
	column.offset_top = -190.0
	column.offset_right = PANEL_WIDTH * 0.5
	column.offset_bottom = 190.0
	column.add_theme_constant_override("separation", 12)
	_root.add_child(column)

	var title := Label.new()
	title.text = "Пауза"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	column.add_child(title)

	_clock_label = Label.new()
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_label.add_theme_color_override("font_color", Color(0.62, 0.7, 0.82))
	column.add_child(_clock_label)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, 16.0)
	column.add_child(gap)

	column.add_child(_make_button("Продолжить", resume))
	column.add_child(_make_button("Настройки", _on_settings_pressed))
	column.add_child(_make_button("В главное меню", _on_main_menu_pressed))
	column.add_child(_make_button("Выход из игры", _on_quit_pressed))


func _make_button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(PANEL_WIDTH, 42.0)
	button.add_theme_font_size_override("font_size", 18)
	button.pressed.connect(handler)
	return button


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event as InputEventKey
	if not key.pressed or key.echo or key.keycode != KEY_ESCAPE:
		return
	# Если открыты настройки — Esc закрывает их и возвращает в паузу,
	# поэтому саму паузу не трогаем.
	if _settings != null and is_instance_valid(_settings) and _settings.is_open():
		return
	toggle()
	get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _root != null and _root.visible


func toggle() -> void:
	if is_open():
		resume()
	else:
		open()


func open() -> void:
	if _root == null:
		return
	_refresh_clock()
	_root.visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	shown.emit()


func resume() -> void:
	if _root == null:
		return
	if _settings != null and is_instance_valid(_settings) and _settings.is_open():
		_settings.hide_menu()
	_root.visible = false
	get_tree().paused = false
	GameConfig.save_settings()
	resumed.emit()


func _refresh_clock() -> void:
	if _clock_label == null:
		return
	if WorldClock == null:
		_clock_label.text = ""
		return
	_clock_label.text = "%s   •   %s" % [
		WorldClock.stamp_string(),
		"ночь" if WorldClock.is_night() else "день",
	]


func _on_settings_pressed() -> void:
	if _settings == null or not is_instance_valid(_settings):
		_settings = _spawn_settings()
	if _settings != null:
		_settings.show_menu()


func _spawn_settings() -> NoirSettingsMenu:
	if not ResourceLoader.exists(SETTINGS_SCENE):
		Log.error("PauseMenu", "Сцена настроек не найдена", {"путь": SETTINGS_SCENE})
		return null
	var packed: PackedScene = load(SETTINGS_SCENE) as PackedScene
	if packed == null:
		return null
	var instance: Node = packed.instantiate()
	instance.name = "SettingsMenu"
	add_child(instance)
	return instance as NoirSettingsMenu


func _on_main_menu_pressed() -> void:
	GameConfig.save_settings()
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not ResourceLoader.exists(MAIN_MENU_SCENE):
		Log.error("PauseMenu", "Главное меню не найдено", {"путь": MAIN_MENU_SCENE})
		return
	var error: int = get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	if error != OK:
		Log.error("PauseMenu", "Не удалось вернуться в главное меню", {"код": error})


func _on_quit_pressed() -> void:
	GameConfig.save_settings()
	get_tree().paused = false
	get_tree().quit()
