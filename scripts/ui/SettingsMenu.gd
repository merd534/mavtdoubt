class_name NoirSettingsMenu
extends CanvasLayer
## Игровое меню настроек. Вся разметка собирается кодом из декларативного
## списка [constant TABS], а не руками в редакторе.
##
## Почему так: настроек около пятидесяти, и каждая — это лейбл + контрол + связь
## с `GameConfig`. В .tscn это 200 узлов, которые невозможно поддерживать и легко
## рассинхронизировать со схемой настроек. Здесь же схема и UI — одно целое:
## добавил строку в TABS — появился рабочий контрол.
##
## Типы строк: "slider", "time", "check", "option", "preset", "difficulty", "header", "info".
##
## Меню открывается только кнопкой «Настройки» из главного меню или паузы:
## горячих клавиш больше нет. Esc возвращает в то меню, откуда пришли.

const PANEL_WIDTH := 760.0
const PANEL_HEIGHT := 640.0
const ROW_HEIGHT := 34.0
const LABEL_WIDTH := 310.0

signal closed()
signal opened()

const TABS: Array = [
	{
		"title": "Мир",
		"reset": "world",
		"rows": [
			{"type": "time", "section": "world", "key": "time_of_day_min", "label": "Время суток"},
			{"type": "info", "id": "clock_info", "label": "Сейчас в городе"},
			{"type": "slider", "section": "world", "key": "time_flow", "label": "Темп времени (мин/сек)", "min": 0.0, "max": 600.0, "step": 5.0},
			{"type": "check", "section": "world", "key": "freeze_time", "label": "Заморозить время на этом часе"},
			{"type": "header", "label": "Яркость и погода"},
			{"type": "slider", "section": "world", "key": "exposure", "label": "Общая яркость", "min": 0.4, "max": 2.5, "step": 0.05},
			{"type": "slider", "section": "world", "key": "night_brightness", "label": "Подъём теней ночью", "min": 0.5, "max": 3.0, "step": 0.05},
			{"type": "slider", "section": "world", "key": "rain", "label": "Сила дождя", "min": 0.0, "max": 1.0, "step": 0.05},
		],
	},
	{
		"title": "Графика",
		"reset": "graphics",
		"rows": [
			{"type": "preset", "label": "Графический пресет"},
			{"type": "info", "id": "render_info", "label": "Разрешение рендера"},
			{"type": "header", "label": "Масштабирование (AMD FSR)"},
			{"type": "option", "section": "graphics", "key": "fsr_mode", "label": "Режим FSR",
				"items": ["Производительность", "Сбалансированный", "Качество", "Нативное разрешение"], "values": [0, 1, 2, 3]},
			{"type": "slider", "section": "graphics", "key": "resolution_scale", "label": "Масштаб разрешения", "min": 0.5, "max": 1.5, "step": 0.05},
			{"type": "slider", "section": "graphics", "key": "fsr_sharpness", "label": "Резкость FSR", "min": 0.0, "max": 2.0, "step": 0.05},
			{"type": "header", "label": "Освещение и эффекты"},
			{"type": "check", "section": "graphics", "key": "sdfgi", "label": "Глобальное освещение (SDFGI)"},
			{"type": "check", "section": "graphics", "key": "ssr", "label": "Отражения в экранном пространстве (SSR)"},
			{"type": "check", "section": "graphics", "key": "ssao", "label": "Затенение (SSAO)"},
			{"type": "check", "section": "graphics", "key": "ssil", "label": "Непрямой свет (SSIL)"},
			{"type": "check", "section": "graphics", "key": "volumetric_fog", "label": "Объёмный туман"},
			{"type": "check", "section": "graphics", "key": "glow", "label": "Свечение неона (Glow)"},
			{"type": "option", "section": "graphics", "key": "shadow_atlas", "label": "Карты теней",
				"items": ["Выключены", "1024", "2048", "4096", "8192", "16384"], "values": [0, 1024, 2048, 4096, 8192, 16384]},
			{"type": "header", "label": "Сглаживание и текстуры"},
			{"type": "option", "section": "graphics", "key": "msaa", "label": "MSAA",
				"items": ["Выкл", "2x", "4x", "8x"], "values": [0, 1, 2, 3]},
			{"type": "check", "section": "graphics", "key": "taa", "label": "TAA"},
			{"type": "check", "section": "graphics", "key": "debanding", "label": "Устранение полос (Debanding)"},
			{"type": "option", "section": "graphics", "key": "anisotropy", "label": "Анизотропная фильтрация",
				"items": ["Выкл", "2x", "4x", "16x"], "values": [0, 1, 2, 3]},
			{"type": "option", "section": "graphics", "key": "texture_quality", "label": "Качество текстур",
				"items": ["Минимальное", "Низкое", "Среднее", "Максимальное"], "values": [0, 1, 2, 3]},
			{"type": "header", "label": "Детализация города"},
			{"type": "option", "section": "graphics", "key": "facade_detail", "label": "Архитектурная детализация",
				"items": ["Коробки", "Базовая", "Подробная", "Богатая", "Кино"], "values": [0, 1, 2, 3, 4]},
			{"type": "slider", "section": "graphics", "key": "detail_density", "label": "Плотность деталей фасадов", "min": 0.0, "max": 1.5, "step": 0.05},
			{"type": "check", "section": "graphics", "key": "cables", "label": "Кабели и провода"},
			{"type": "check", "section": "graphics", "key": "steam", "label": "Пар и капли (GPU-частицы)"},
			{"type": "check", "section": "graphics", "key": "debris", "label": "Мусор в подворотнях"},
			{"type": "check", "section": "graphics", "key": "interior_furniture", "label": "Мебель в интерьерах"},
			{"type": "option", "section": "graphics", "key": "billboard_lights", "label": "Живой свет от вывесок",
				"items": ["Нет", "1 на здание", "2", "3", "4", "6"], "values": [0, 1, 2, 3, 4, 6]},
			{"type": "header", "label": "Стриминг и дальность"},
			{"type": "slider", "section": "graphics", "key": "render_distance_m", "label": "Дальность прорисовки, м", "min": 200.0, "max": 2000.0, "step": 20.0},
			{"type": "slider", "section": "graphics", "key": "chunk_radius", "label": "Максимум чанков от игрока", "min": 1.0, "max": 8.0, "step": 1.0},
			{"type": "slider", "section": "graphics", "key": "hide_radius_chunks", "label": "Буфер скрытых чанков", "min": 0.0, "max": 3.0, "step": 1.0},
			{"type": "slider", "section": "graphics", "key": "npc_budget", "label": "Лимит живых горожан", "min": 20.0, "max": 500.0, "step": 10.0},
			{"type": "header", "label": "Окно"},
			{"type": "option", "section": "graphics", "key": "vsync", "label": "Вертикальная синхронизация",
				"items": ["Выкл", "Вкл", "Адаптивная", "Mailbox"], "values": [0, 1, 2, 3]},
			{"type": "option", "section": "graphics", "key": "fps_limit", "label": "Лимит FPS",
				"items": ["Без лимита", "30", "60", "90", "120", "144", "240"], "values": [0, 30, 60, 90, 120, 144, 240]},
		],
	},
	{
		"title": "Управление",
		"reset": "controls",
		"rows": [
			{"type": "slider", "section": "controls", "key": "mouse_sensitivity", "label": "Чувствительность мыши", "min": 0.02, "max": 1.2, "step": 0.01},
			{"type": "slider", "section": "controls", "key": "scan_sensitivity", "label": "Чувствительность в режиме сканера", "min": 0.01, "max": 0.6, "step": 0.01},
			{"type": "slider", "section": "controls", "key": "fov", "label": "Угол обзора (FOV)", "min": 60.0, "max": 110.0, "step": 1.0},
			{"type": "check", "section": "controls", "key": "invert_y", "label": "Инвертировать ось Y"},
			{"type": "check", "section": "controls", "key": "toggle_sprint", "label": "Спринт переключателем"},
			{"type": "header", "label": "Клавиши"},
			{"type": "info", "id": "keys_info", "label": "Управление"},
		],
	},
	{
		"title": "Геймплей",
		"reset": "gameplay",
		"rows": [
			{"type": "difficulty", "label": "Пресет сложности"},
			{"type": "info", "id": "difficulty_info", "label": "Правила"},
			{"type": "header", "label": "Детективная часть"},
			{"type": "check", "section": "gameplay", "key": "clue_highlight", "label": "Подсветка улик"},
			{"type": "slider", "section": "gameplay", "key": "clue_scan_recharge", "label": "Перезарядка сканера, с", "min": 0.0, "max": 5.0, "step": 0.1},
			{"type": "slider", "section": "gameplay", "key": "witness_reliability", "label": "Надёжность свидетелей", "min": 0.0, "max": 1.0, "step": 0.05},
			{"type": "header", "label": "Давление мира"},
			{"type": "slider", "section": "gameplay", "key": "police_reaction", "label": "Скорость реакции полиции", "min": 0.2, "max": 3.0, "step": 0.1},
			{"type": "slider", "section": "gameplay", "key": "hack_alarm_speed", "label": "Реакция на взлом", "min": 0.2, "max": 3.0, "step": 0.1},
			{"type": "slider", "section": "gameplay", "key": "case_time_limit_h", "label": "Лимит на раскрытие, ч (0 = нет)", "min": 0.0, "max": 168.0, "step": 6.0},
			{"type": "slider", "section": "gameplay", "key": "killer_moves_after_h", "label": "Новое преступление через, ч (0 = нет)", "min": 0.0, "max": 96.0, "step": 6.0},
			{"type": "check", "section": "gameplay", "key": "permadeath", "label": "Режим «одна жизнь» (Permadeath)"},
			{"type": "check", "section": "gameplay", "key": "autosave", "label": "Автосохранение"},
		],
	},
	{
		"title": "Доступность",
		"reset": "accessibility",
		"rows": [
			{"type": "slider", "section": "accessibility", "key": "ui_scale", "label": "Масштаб интерфейса", "min": 0.7, "max": 2.0, "step": 0.05},
			{"type": "slider", "section": "accessibility", "key": "font_size_bonus", "label": "Увеличение шрифта, пт", "min": 0.0, "max": 12.0, "step": 1.0},
			{"type": "check", "section": "accessibility", "key": "high_contrast_clues", "label": "Высококонтрастные улики"},
			{"type": "check", "section": "accessibility", "key": "reduce_camera_shake", "label": "Меньше тряски камеры"},
			{"type": "check", "section": "accessibility", "key": "subtitles", "label": "Субтитры"},
			{"type": "header", "label": "Звук"},
			{"type": "slider", "section": "audio", "key": "master_db", "label": "Общая громкость, дБ", "min": -40.0, "max": 6.0, "step": 1.0},
			{"type": "slider", "section": "audio", "key": "music_db", "label": "Музыка, дБ", "min": -40.0, "max": 6.0, "step": 1.0},
			{"type": "slider", "section": "audio", "key": "sfx_db", "label": "Эффекты, дБ", "min": -40.0, "max": 6.0, "step": 1.0},
			{"type": "slider", "section": "audio", "key": "rain_db", "label": "Дождь, дБ", "min": -40.0, "max": 6.0, "step": 1.0},
		],
	},
]

const KEYS_HINT := "WASD — движение, Shift — быстрее, Q/E — вниз/вверх в режиме полёта, F — полёт/ходьба, Esc — пауза и меню."

var _root: Control = null
var _tabs: TabContainer = null
var _preset_option: OptionButton = null
var _difficulty_option: OptionButton = null
var _info_labels: Dictionary = {}      # id -> Label
var _bound: Array[Dictionary] = []     # связанные контролы для обратного обновления
var _syncing: bool = false
var _clock_timer: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 90
	_build_ui()
	sync_from_config()
	hide_menu()

	if GameConfig != null:
		GameConfig.setting_changed.connect(_on_setting_changed)
	Log.info("SettingsMenu", "Меню настроек собрано", {"вкладок": TABS.size(), "контролов": _bound.size()})


func _process(delta: float) -> void:
	# Пока меню открыто, держим строку с временем живой: время может течь,
	# если меню открыто из главного меню без паузы.
	if _root == null or not _root.visible:
		return
	_clock_timer -= delta
	if _clock_timer <= 0.0:
		_clock_timer = 0.5
		_refresh_clock_info()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE and _root != null and _root.visible:
			hide_menu()
			get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ видимость

func show_menu() -> void:
	if _root == null:
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	sync_from_config()
	_root.visible = true
	opened.emit()


func hide_menu() -> void:
	if _root == null:
		return
	_root.visible = false
	GameConfig.save_settings()
	closed.emit()


func toggle_menu() -> void:
	if _root == null:
		return
	if _root.visible:
		hide_menu()
	else:
		show_menu()


func is_open() -> bool:
	return _root != null and _root.visible


# ------------------------------------------------------------------ сборка UI

func _build_ui() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.02, 0.02, 0.04, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -PANEL_WIDTH * 0.5
	panel.offset_top = -PANEL_HEIGHT * 0.5
	panel.offset_right = PANEL_WIDTH * 0.5
	panel.offset_bottom = PANEL_HEIGHT * 0.5
	_root.add_child(panel)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)

	var title := Label.new()
	title.text = "Настройки"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	column.add_child(title)

	_tabs = TabContainer.new()
	_tabs.name = "Tabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_tabs)

	for tab: Variant in TABS:
		_build_tab(tab as Dictionary)

	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	footer.add_theme_constant_override("separation", 10)
	column.add_child(footer)

	var reset_button := Button.new()
	reset_button.text = "Сбросить вкладку"
	reset_button.pressed.connect(_on_reset_pressed)
	footer.add_child(reset_button)

	var close_button := Button.new()
	close_button.text = "Назад (Esc)"
	close_button.pressed.connect(hide_menu)
	footer.add_child(close_button)


func _build_tab(tab: Dictionary) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = str(tab.get("title", "Вкладка"))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)

	var list := VBoxContainer.new()
	list.name = "List"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)

	var rows: Array = tab.get("rows", []) as Array
	for entry: Variant in rows:
		if not (entry is Dictionary):
			continue
		_build_row(list, entry as Dictionary)


func _build_row(parent: VBoxContainer, row: Dictionary) -> void:
	var row_type: String = str(row.get("type", ""))

	if row_type == "header":
		var header := Label.new()
		header.text = str(row.get("label", ""))
		header.add_theme_font_size_override("font_size", 15)
		header.add_theme_color_override("font_color", Color(0.75, 0.82, 0.95))
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0.0, 8.0)
		parent.add_child(spacer)
		parent.add_child(header)
		return

	var line := HBoxContainer.new()
	line.custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	line.add_theme_constant_override("separation", 10)
	parent.add_child(line)

	var label := Label.new()
	label.text = str(row.get("label", ""))
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(label)

	match row_type:
		"preset":
			_preset_option = OptionButton.new()
			_preset_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			for preset_name: String in NoirSettingsManager.PRESETS:
				_preset_option.add_item(preset_name)
			_preset_option.item_selected.connect(_on_preset_selected)
			line.add_child(_preset_option)

		"difficulty":
			_difficulty_option = OptionButton.new()
			_difficulty_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			for preset_name: String in NoirDifficultyManager.PRESETS:
				_difficulty_option.add_item(preset_name)
			_difficulty_option.item_selected.connect(_on_difficulty_selected)
			line.add_child(_difficulty_option)

		"info":
			var info := Label.new()
			info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			info.add_theme_color_override("font_color", Color(0.68, 0.72, 0.8))
			line.add_child(info)
			_info_labels[str(row.get("id", ""))] = info

		"check":
			var check := CheckButton.new()
			var section_c: String = str(row.get("section", ""))
			var key_c: String = str(row.get("key", ""))
			check.toggled.connect(func(pressed: bool) -> void:
				_write(section_c, key_c, pressed)
			)
			line.add_child(check)
			_bound.append({"type": "check", "section": section_c, "key": key_c, "node": check})

		"slider":
			var slider := HSlider.new()
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slider.min_value = float(row.get("min", 0.0))
			slider.max_value = float(row.get("max", 1.0))
			slider.step = float(row.get("step", 0.01))
			var value_label := Label.new()
			value_label.custom_minimum_size = Vector2(74.0, 0.0)
			value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			var section_s: String = str(row.get("section", ""))
			var key_s: String = str(row.get("key", ""))
			var step_s: float = slider.step
			slider.value_changed.connect(func(value: float) -> void:
				value_label.text = _format_number(value, step_s)
				_write(section_s, key_s, value)
			)
			line.add_child(slider)
			line.add_child(value_label)
			_bound.append({
				"type": "slider", "section": section_s, "key": key_s,
				"node": slider, "value_label": value_label, "step": step_s,
			})

		"time":
			# Ползунок времени суток. Шаг 5 минут — компромисс между точностью
			# и возможностью одним движением пройти все сутки.
			var time_slider := HSlider.new()
			time_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			time_slider.min_value = 0.0
			time_slider.max_value = float(NoirWorldClock.MINUTES_PER_DAY - 1)
			time_slider.step = 5.0
			var time_label := Label.new()
			time_label.custom_minimum_size = Vector2(74.0, 0.0)
			time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			time_label.add_theme_font_size_override("font_size", 17)
			var section_t: String = str(row.get("section", "world"))
			var key_t: String = str(row.get("key", "time_of_day_min"))
			time_slider.value_changed.connect(func(value: float) -> void:
				var minutes: int = int(round(value))
				time_label.text = NoirWorldClock.format_minutes(minutes)
				_write(section_t, key_t, minutes)
				# Сразу переводим часы: игрок должен видеть результат сквозь
				# полупрозрачное меню, не закрывая его.
				if WorldClock != null and not _syncing:
					WorldClock.set_minutes_of_day(minutes)
				_refresh_clock_info()
			)
			line.add_child(time_slider)
			line.add_child(time_label)
			_bound.append({
				"type": "time", "section": section_t, "key": key_t,
				"node": time_slider, "value_label": time_label,
			})

		"option":
			var option := OptionButton.new()
			option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var items: Array = row.get("items", []) as Array
			var values: Array = row.get("values", []) as Array
			for item: Variant in items:
				option.add_item(str(item))
			var section_o: String = str(row.get("section", ""))
			var key_o: String = str(row.get("key", ""))
			var values_o: Array = values.duplicate()
			option.item_selected.connect(func(index: int) -> void:
				if index < 0 or index >= values_o.size():
					return
				_write(section_o, key_o, values_o[index])
			)
			line.add_child(option)
			_bound.append({"type": "option", "section": section_o, "key": key_o, "node": option, "values": values_o})

		_:
			Log.warn("SettingsMenu", "Неизвестный тип строки меню", {"тип": row_type})


# ------------------------------------------------------------------ синхронизация

## Перечитывает все контролы из `GameConfig`. Защищено флагом `_syncing`,
## чтобы сигналы контролов не записали те же значения обратно.
func sync_from_config() -> void:
	_syncing = true

	for entry: Dictionary in _bound:
		var node: Variant = entry.get("node", null)
		if node == null or not is_instance_valid(node as Node):
			continue
		var section_name: String = str(entry.get("section", ""))
		var key: String = str(entry.get("key", ""))

		match str(entry.get("type", "")):
			"check":
				(node as CheckButton).button_pressed = GameConfig.get_bool(section_name, key)
			"slider":
				var slider: HSlider = node as HSlider
				var value: float = GameConfig.get_float(section_name, key)
				slider.value = clampf(value, slider.min_value, slider.max_value)
				var value_label: Variant = entry.get("value_label", null)
				if value_label is Label and is_instance_valid(value_label as Label):
					(value_label as Label).text = _format_number(slider.value, float(entry.get("step", 0.01)))
			"time":
				var time_slider: HSlider = node as HSlider
				var minutes: int = clampi(GameConfig.get_int(section_name, key), 0, NoirWorldClock.MINUTES_PER_DAY - 1)
				time_slider.value = float(minutes)
				var time_label: Variant = entry.get("value_label", null)
				if time_label is Label and is_instance_valid(time_label as Label):
					(time_label as Label).text = NoirWorldClock.format_minutes(minutes)
			"option":
				var option: OptionButton = node as OptionButton
				var values: Array = entry.get("values", []) as Array
				var current: int = GameConfig.get_int(section_name, key)
				var index: int = values.find(current)
				option.selected = index if index >= 0 else _nearest_index(values, current)

	if _preset_option != null and is_instance_valid(_preset_option):
		_preset_option.selected = Settings.preset_index()
	if _difficulty_option != null and is_instance_valid(_difficulty_option):
		_difficulty_option.selected = Difficulty.preset_index()

	_refresh_info()
	_syncing = false


func _refresh_info() -> void:
	var render_info: Variant = _info_labels.get("render_info", null)
	if render_info is Label and is_instance_valid(render_info as Label):
		var summary: Dictionary = Settings.summary()
		(render_info as Label).text = "%s -> %s, FSR: %s" % [
			str(summary.get("window", "?")),
			str(summary.get("render", "?")),
			str(summary.get("fsr", "?")),
		]

	var difficulty_info: Variant = _info_labels.get("difficulty_info", null)
	if difficulty_info is Label and is_instance_valid(difficulty_info as Label):
		(difficulty_info as Label).text = Difficulty.describe(Difficulty.current_preset())

	var keys_info: Variant = _info_labels.get("keys_info", null)
	if keys_info is Label and is_instance_valid(keys_info as Label):
		(keys_info as Label).text = KEYS_HINT

	_refresh_clock_info()


func _refresh_clock_info() -> void:
	var clock_info: Variant = _info_labels.get("clock_info", null)
	if not (clock_info is Label) or not is_instance_valid(clock_info as Label):
		return
	if WorldClock == null:
		(clock_info as Label).text = "часы недоступны"
		return
	var phase: String = "ночь" if WorldClock.is_night() else "день"
	(clock_info as Label).text = "%s — %s, света %d%%" % [
		WorldClock.stamp_string(), phase, int(round(WorldClock.daylight() * 100.0)),
	]


func _nearest_index(values: Array, current: int) -> int:
	var best: int = 0
	var best_delta: int = 1 << 30
	for i: int in range(values.size()):
		var delta: int = absi(int(values[i]) - current)
		if delta < best_delta:
			best_delta = delta
			best = i
	return best


func _format_number(value: float, step: float) -> String:
	if step >= 1.0:
		return "%d" % int(round(value))
	if step >= 0.1:
		return "%.1f" % value
	return "%.2f" % value


func _write(section_name: String, key: String, value: Variant) -> void:
	if _syncing or section_name.is_empty() or key.is_empty():
		return
	GameConfig.set_value(section_name, key, value)
	_refresh_info()


# ------------------------------------------------------------------ обработчики

func _on_preset_selected(index: int) -> void:
	if _syncing:
		return
	if Settings.apply_preset_index(index):
		sync_from_config()


func _on_difficulty_selected(index: int) -> void:
	if _syncing:
		return
	if Difficulty.apply_preset_index(index):
		sync_from_config()


## Сбрасывает секцию текущей вкладки. Имя секции берётся из самой вкладки,
## а не из параллельного списка: иначе любая новая вкладка ломала бы соответствие.
func _on_reset_pressed() -> void:
	if _tabs == null:
		return
	var index: int = clampi(_tabs.current_tab, 0, TABS.size() - 1)
	var tab: Dictionary = TABS[index] as Dictionary
	var section_name: String = str(tab.get("reset", ""))
	if section_name.is_empty():
		return
	GameConfig.reset_section(section_name)
	if section_name == "graphics":
		Settings.apply_all()
	if section_name == "world" and WorldClock != null:
		WorldClock.set_minutes_of_day(GameConfig.get_int("world", "time_of_day_min"))
	sync_from_config()


func _on_setting_changed(_section: String, _key: String, _value: Variant) -> void:
	# Настройку можно сменить не только из меню (консоль, сценарные события),
	# поэтому держим цифры в актуальном виде, пока меню открыто.
	if _syncing or _root == null or not _root.visible:
		return
	_refresh_info()
