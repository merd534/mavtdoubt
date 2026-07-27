extends Node3D
## Стенд Фазы 2. В headless-режиме прогоняет проверки генерации и стриминга,
## в оконном — даёт свободную камеру по городу с HUD'ом производительности.
##
##   godot --headless --path . res://scenes/dev/Phase2CityBench.tscn
##   godot --path . res://scenes/dev/Phase2CityBench.tscn            (осмотр)
##   godot --path . res://scenes/dev/Phase2CityBench.tscn -- --flythrough
##       автоматический облёт с замером FPS и выходом

const FLY_POINTS: Array[Vector3] = [
	Vector3(-120.0, 180.0, 260.0),     # подлёт к ядру
	Vector3(-40.0, 90.0, 40.0),        # Downtown Core
	Vector3(-640.0, 120.0, -700.0),    # Financial / City Hall
	Vector3(1450.0, 70.0, -300.0),     # Old Town за рекой
	Vector3(1500.0, 40.0, -520.0),     # Ривердейлский мост
	Vector3(-1440.0, 45.0, 980.0),     # Entertainment
	Vector3(1050.0, 35.0, 1320.0),     # трущобы
]
const FLY_SEGMENT_SEC := 3.2
const WARMUP_SEC := 2.5

@onready var _generator: NoirCityGenerator = $CityGenerator as NoirCityGenerator
@onready var _player: NoirDevCamera = $Player as NoirDevCamera
@onready var _hud: RichTextLabel = $UI/Stats as RichTextLabel
@onready var _report: RichTextLabel = $UI/Report as RichTextLabel

var _headless: bool = false
var _flythrough: bool = false
var _fly_index: int = 0
var _fly_timer: float = 0.0
var _fps_samples: PackedFloat32Array = []
var _frame_ms: PackedFloat32Array = []
var _fly_elapsed: float = 0.0
var _lines: PackedStringArray = []
var _passed: int = 0
var _failed: int = 0
var _hud_timer: float = 0.0


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	_flythrough = OS.get_cmdline_user_args().has("--flythrough")

	# Если скрипт узла не скомпилировался, @onready даст null. Без этой проверки
	# headless-прогон не падал, а молча висел вечно — в CI это худший исход.
	if _generator == null or _player == null:
		var message: String = "Узлы сцены не готовы: генератор=%s, игрок=%s. Скорее всего скрипт не скомпилировался." % [
			str(_generator != null), str(_player != null),
		]
		push_error(message)
		print("FAIL " + message)
		if _headless:
			get_tree().quit(1)
		return

	if _headless:
		_report.visible = true
		_hud.visible = false
		await get_tree().process_frame
		_run_validation()
		return

	_report.visible = false
	_hud.visible = true
	_generator.set_observer(_player)
	_player.teleport(FLY_POINTS[0], Vector3(0.0, 20.0, 0.0))

	if OS.get_cmdline_user_args().has("--screenshot"):
		_flythrough = false
		await _capture_views()
		return

	if _flythrough:
		_player.flying = true
		Log.info("Phase2Bench", "Автоматический облёт запущен", {"точек": FLY_POINTS.size()})


func _process(delta: float) -> void:
	if _headless:
		return

	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.2
		_update_hud()

	if _flythrough:
		_advance_flythrough(delta)


# ------------------------------------------------------------------ проверки

func _run_validation() -> void:
	_say("[b]NEON NOIR — ПРОВЕРКА ФАЗЫ 2 (ГОРОД)[/b]")
	_say("Godot %s | сетка чанков %s" % [
		Engine.get_version_info().get("string", "?"),
		str(_generator.stats().get("grid", "?")),
	])

	_test_materials()
	_test_grid()
	_test_determinism()
	_test_seams()
	_test_river_and_landmarks()
	_test_streaming()
	_test_chunk_composition()
	_test_interiors()

	_say("")
	_say("[b]ИТОГ: пройдено %d, провалено %d[/b]" % [_passed, _failed])
	_say("Записей ERROR/FATAL в логе: %d" % Log.problem_count())
	if _failed == 0:
		_say("[color=#39FF88]ФАЗА 2: ГЕНЕРАЦИЯ И СТРИМИНГ РАБОТАЮТ.[/color]")
	else:
		_say("[color=#E8253F]ЕСТЬ ПРОВАЛЕННЫЕ ПРОВЕРКИ.[/color]")

	_flush()
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if _failed == 0 else 1)


func _test_materials() -> void:
	_section("1. Материалы и шейдеры")
	_check(CityMaterials.is_ready(), "все четыре шейдера скомпилированы")
	_check(CityMaterials.facade != null and CityMaterials.facade.shader != null, "facade.gdshader на месте")
	_check(CityMaterials.neon != null and CityMaterials.neon.shader != null, "neon.gdshader на месте")
	_check(CityMaterials.road_arterial != null, "магистральный вариант дорожного материала создан")
	_check(CityMaterials.box_mesh() != null and CityMaterials.quad_mesh() != null, "базовые меши созданы")

	# Пресеты качества обязаны применяться без ошибок для всех восьми названий.
	var applied: int = 0
	for preset: Variant in NoirCityMaterials.QUALITY_TABLE.keys():
		CityMaterials.apply_quality(str(preset))
		applied += 1
	CityMaterials.apply_quality(GameConfig.get_string("graphics", "preset"))
	_check(applied == 8, "пресетов качества в таблице: %d" % applied)


func _test_grid() -> void:
	_section("2. Сетка чанков покрывает мир")
	var bounds: Rect2 = CityAtlas.world_bounds()
	var stats: Dictionary = _generator.stats()
	_say("  Мир: %.0f x %.0f м (%.2f км²)" % [bounds.size.x, bounds.size.y, CityAtlas.world_area_km2()])

	var corners: Array[Vector3] = [
		Vector3(bounds.position.x + 1.0, 0.0, bounds.position.y + 1.0),
		Vector3(bounds.end.x - 1.0, 0.0, bounds.position.y + 1.0),
		Vector3(bounds.position.x + 1.0, 0.0, bounds.end.y - 1.0),
		Vector3(bounds.end.x - 1.0, 0.0, bounds.end.y - 1.0),
		Vector3.ZERO,
	]
	var all_inside: bool = true
	for corner: Vector3 in corners:
		var coords: Vector2i = _generator.chunk_coords_at(corner)
		var rect: Rect2 = _generator.chunk_rect(coords)
		if not rect.grow(0.01).has_point(Vector2(corner.x, corner.z)):
			all_inside = false
	_check(all_inside, "любая точка мира отображается в свой чанк (5 проб)")
	_check(str(stats["grid"]) != "0x0", "сетка построена: %s" % str(stats["grid"]))


func _test_determinism() -> void:
	_section("3. Детерминизм генерации")

	var probes: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(-1440.0, 0.0, 980.0),
		Vector3(1500.0, 0.0, -300.0),
	]
	var stable: int = 0
	for probe: Vector3 in probes:
		var coords: Vector2i = _generator.chunk_coords_at(probe)
		var rect: Rect2 = _generator.chunk_rect(coords)
		var first: Dictionary = NoirBuildingFactory.generate(rect, CityAtlas.city_seed, 0)
		var second: Dictionary = NoirBuildingFactory.generate(rect, CityAtlas.city_seed, 0)
		if _content_hash(first) == _content_hash(second):
			stable += 1
	_check(stable == probes.size(), "повторная генерация даёт тот же чанк (%d из %d)" % [stable, probes.size()])

	# Другой сид обязан дать другой город.
	var rect: Rect2 = _generator.chunk_rect(_generator.chunk_coords_at(Vector3.ZERO))
	var other: Dictionary = NoirBuildingFactory.generate(rect, CityAtlas.city_seed + 1, 0)
	var base: Dictionary = NoirBuildingFactory.generate(rect, CityAtlas.city_seed, 0)
	_check(_content_hash(other) != _content_hash(base), "смена сида меняет застройку")


func _test_seams() -> void:
	_section("4. Швы между чанками")

	# Квартал принадлежит чанку по своему центру, поэтому здание не имеет права
	# появиться в двух чанках сразу.
	var seen: Dictionary = {}
	var duplicates: int = 0
	var total: int = 0
	var center: Vector2i = _generator.chunk_coords_at(Vector3(-40.0, 0.0, 40.0))

	for dx: int in range(-1, 2):
		for dy: int in range(-1, 2):
			var coords := Vector2i(center.x + dx, center.y + dy)
			var content: Dictionary = NoirBuildingFactory.generate(_generator.chunk_rect(coords), CityAtlas.city_seed, 1)
			for entry: Variant in content["buildings"] as Array:
				var b: Dictionary = entry as Dictionary
				var pos: Vector3 = b["center"]
				var key: String = "%.1f_%.1f" % [pos.x, pos.z]
				total += 1
				if seen.has(key):
					duplicates += 1
				seen[key] = true

	_check(duplicates == 0, "в блоке 3x3 чанков нет задвоенных зданий (%d из %d)" % [duplicates, total])
	_check(total > 40, "плотность застройки разумна: %d зданий на 9 чанков" % total)


func _test_river_and_landmarks() -> void:
	_section("5. Река и landmark'и")

	# Ни одно здание не должно стоять в русле.
	var in_river: int = 0
	var checked: int = 0
	var probes: Array[Vector3] = [
		Vector3(1180.0, 0.0, -1120.0),
		Vector3(1420.0, 0.0, -520.0),
		Vector3(1640.0, 0.0, 120.0),
		Vector3(1900.0, 0.0, 820.0),
	]
	for probe: Vector3 in probes:
		var coords: Vector2i = _generator.chunk_coords_at(probe)
		var content: Dictionary = NoirBuildingFactory.generate(_generator.chunk_rect(coords), CityAtlas.city_seed, 1)
		for entry: Variant in content["buildings"] as Array:
			var pos: Vector3 = (entry as Dictionary)["center"]
			checked += 1
			if CityAtlas.is_in_river(Vector2(pos.x, pos.z)):
				in_river += 1
	_check(in_river == 0, "зданий в русле реки: %d (проверено %d)" % [in_river, checked])

	# Каждый landmark обязан получить здание и вход.
	var missing: PackedStringArray = []
	for row: Dictionary in NoirCityAtlas.LANDMARK_TABLE:
		var location_id: String = str(row["id"])
		var loc: Dictionary = CityAtlas.get_location(location_id)
		if loc.is_empty():
			missing.append(location_id)
			continue
		if NoirBuildingFactory.OPEN_AIR_KINDS.has(int(loc["kind"])):
			continue
		var position: Vector2 = loc["position"]
		var coords: Vector2i = _generator.chunk_coords_at(Vector3(position.x, 0.0, position.y))
		var content: Dictionary = NoirBuildingFactory.generate(_generator.chunk_rect(coords), CityAtlas.city_seed, 0)
		var found: bool = false
		for entry: Variant in content["buildings"] as Array:
			if str((entry as Dictionary).get("location_id", "")) == location_id:
				found = true
				break
		if not found:
			missing.append(location_id)
	_check(missing.is_empty(), "все landmark'и застроены%s" % ("" if missing.is_empty() else ": нет " + ", ".join(missing)))

	# Мосты стоят и имеют коллизию.
	var river_node: Node = _generator.get_node_or_null("RiverAndBridges")
	_check(river_node != null, "узел реки и мостов создан")
	if river_node != null:
		_check(river_node.get_node_or_null("Water") != null, "полотно воды построено")
		_check(river_node.get_node_or_null("BridgeDecks") != null, "пролёты мостов построены")
		var collision: Node = river_node.get_node_or_null("BridgeCollision")
		_check(collision != null and collision.get_child_count() == 4, "коллизия на всех 4 мостах")


func _test_streaming() -> void:
	_section("6. Стриминг: загрузка, выгрузка, детализация")

	var nodes_before: int = get_tree().get_node_count()

	_generator.set_observer_position(Vector3(-40.0, 30.0, 40.0))
	_generator.refresh()
	var queued: int = _generator.queued_chunk_count()
	_check(queued > 0, "чанки поставлены в очередь: %d" % queued)

	var built: int = _generator.flush_queue()
	var stats_near: Dictionary = _generator.stats()
	_check(_generator.is_idle(), "очередь опустела, собрано чанков: %d" % built)
	_check(int(stats_near["chunks_loaded"]) > 0, "загружено чанков: %d" % int(stats_near["chunks_loaded"]))
	_check(int(stats_near["buildings"]) > 200, "зданий вокруг наблюдателя: %d" % int(stats_near["buildings"]))
	_check(int(stats_near["chunks_near"]) > 0, "ближних чанков (полная детализация): %d" % int(stats_near["chunks_near"]))
	_check(int(stats_near["chunks_far"]) > 0, "дальних чанков (силуэты): %d" % int(stats_near["chunks_far"]))
	_say("  Средняя сборка чанка: %.1f мс" % float(stats_near["avg_build_ms"]))
	_check(float(stats_near["avg_build_ms"]) < 25.0, "сборка чанка укладывается в разумное время")

	var loaded_first: int = int(stats_near["chunks_loaded"])

	# Уезжаем в другую часть города — старые чанки обязаны освободиться,
	# а размер кольца остаться прежним (обе точки далеко от края карты).
	_generator.set_observer_position(Vector3(900.0, 30.0, 400.0))
	_generator.refresh()
	_generator.flush_queue()
	var stats_far: Dictionary = _generator.stats()
	_check(int(stats_far["chunks_loaded"]) > 0, "новое окружение загружено: %d чанков" % int(stats_far["chunks_loaded"]))
	_check(absi(int(stats_far["chunks_loaded"]) - loaded_first) <= 4,
		"размер кольца стабилен вдали от края (%d -> %d)" % [loaded_first, int(stats_far["chunks_loaded"])])

	# У края карты кольцо обязано обрезаться, а не пытаться грузить пустоту.
	var bounds: Rect2 = CityAtlas.world_bounds()
	_generator.set_observer_position(Vector3(bounds.position.x + 40.0, 30.0, bounds.end.y - 40.0))
	_generator.refresh()
	_generator.flush_queue()
	var stats_corner: Dictionary = _generator.stats()
	_check(int(stats_corner["chunks_loaded"]) < loaded_first,
		"у края карты кольцо обрезано: %d чанков вместо %d" % [int(stats_corner["chunks_loaded"]), loaded_first])

	# Возвращаемся: содержимое обязано совпасть с прежним (детерминизм выгрузки).
	_generator.set_observer_position(Vector3(-40.0, 30.0, 40.0))
	_generator.refresh()
	_generator.flush_queue()
	var stats_back: Dictionary = _generator.stats()
	_check(int(stats_back["buildings"]) == int(stats_near["buildings"]),
		"после возврата тот же город: %d зданий" % int(stats_back["buildings"]))

	# Утечка узлов: освободим всё и дадим движку удалить.
	_generator.set_observer_position(Vector3(9e6, 0.0, 9e6))
	_generator.refresh()
	await get_tree().process_frame
	await get_tree().process_frame
	var nodes_after: int = get_tree().get_node_count()
	_check(nodes_after <= nodes_before + 40,
		"узлы освобождаются при выгрузке (было %d, стало %d)" % [nodes_before, nodes_after])

	# Возвращаем наблюдателя в центр для остальных проверок.
	_generator.set_observer_position(Vector3(-40.0, 30.0, 40.0))
	_generator.refresh()
	_generator.flush_queue()


func _test_chunk_composition() -> void:
	_section("7. Состав чанка и бюджет отрисовки")

	var coords: Vector2i = _generator.chunk_coords_at(Vector3(-40.0, 0.0, 40.0))
	var rect: Rect2 = _generator.chunk_rect(coords)

	var near_chunk: NoirCityChunk = NoirCityChunk.create(coords, rect, NoirCityChunk.DETAIL_NEAR)
	add_child(near_chunk)
	var build_ms: int = near_chunk.build(CityAtlas.city_seed)
	var stats: Dictionary = near_chunk.stats()

	_say("  Ближний чанк: %d зданий, %d вывесок, %d реквизита, %d фонарей за %d мс" % [
		int(stats["buildings"]), int(stats["signs"]), int(stats["props"]), int(stats["lamps"]), build_ms,
	])

	var multimeshes: int = 0
	var meshes: int = 0
	var occluders: int = 0
	var bodies: int = 0
	var lights: int = 0
	for child: Node in near_chunk.get_children():
		if child is MultiMeshInstance3D:
			multimeshes += 1
		elif child is MeshInstance3D:
			meshes += 1
		elif child is OccluderInstance3D:
			occluders += 1
		elif child is StaticBody3D:
			bodies += 1
		elif child is OmniLight3D:
			lights += 1

	_check(multimeshes + meshes <= 8, "вызовов отрисовки на чанк: %d (MultiMesh %d + Mesh %d)" % [multimeshes + meshes, multimeshes, meshes])
	_check(occluders == 1, "окклюдер чанка создан (ArrayOccluder3D)")
	_check(bodies == 1, "коллизия ближнего чанка создана")
	_check(lights <= NoirCityChunk.MAX_REAL_LIGHTS, "настоящих источников света: %d (лимит %d)" % [lights, NoirCityChunk.MAX_REAL_LIGHTS])
	_check(int(stats["buildings"]) > 0, "чанк не пустой")
	_check(int(stats["signs"]) > 0, "неоновые вывески сгенерированы")

	# Дальний чанк обязан быть заметно легче ближнего.
	var far_chunk: NoirCityChunk = NoirCityChunk.create(coords, rect, NoirCityChunk.DETAIL_FAR)
	add_child(far_chunk)
	far_chunk.build(CityAtlas.city_seed)
	var far_stats: Dictionary = far_chunk.stats()
	_check(int(far_stats["props"]) == 0, "дальний чанк не тратится на реквизит")
	_check(int(far_stats["lights"]) == 0, "дальний чанк не заводит источников света")
	_check(int(far_stats["signs"]) == int(stats["signs"]),
		"неон сохраняется на дальнем LOD: %d вывесок (это и есть дальний план)" % int(far_stats["signs"]))
	_check(int(far_stats["buildings"]) == int(stats["buildings"]), "силуэт города на дальнем LOD сохраняется")

	# Переключение детализации на лету.
	var changed: bool = far_chunk.set_detail(NoirCityChunk.DETAIL_NEAR, CityAtlas.city_seed)
	_check(changed, "смена LOD пересобирает чанк")
	_check(int(far_chunk.stats()["props"]) > 0, "после приближения появился реквизит")

	near_chunk.dispose()
	far_chunk.dispose()


func _test_interiors() -> void:
	_section("8. Интерьеры зданий")

	var apartments: Array[String] = CityAtlas.locations_of_kind(NoirCityAtlas.LocationKind.APARTMENTS)
	if apartments.is_empty():
		_check(false, "в атласе есть жилые дома")
		return

	var location_id: String = apartments[0]
	var interior: Node3D = NoirInteriorFactory.build(location_id)
	if not _check(interior != null, "интерьер построен для %s" % location_id):
		return

	add_child(interior)
	var rooms: Variant = interior.get_meta("rooms", [])
	var room_count: int = (rooms as Array).size() if rooms is Array else 0
	_check(room_count > 0, "комнат сгенерировано: %d" % room_count)
	_check(int(interior.get_meta("floors", 0)) > 0, "этажей: %d" % int(interior.get_meta("floors", 0)))

	var walls: Node = interior.get_node_or_null("Walls")
	var slabs: Node = interior.get_node_or_null("Slabs")
	var furniture: Node = interior.get_node_or_null("Furniture")
	var metal: Node = interior.get_node_or_null("Metal")
	var collision: Node = interior.get_node_or_null("Collision")

	_check(walls != null, "стены построены")
	_check(slabs != null, "перекрытия построены")
	_check(furniture != null, "мебель расставлена")
	_check(metal != null, "лестница, лифт и вентиляция построены")
	_check(collision != null and collision.get_child_count() > 0,
		"коллизия интерьера: %d форм" % (collision.get_child_count() if collision != null else 0))

	var draw_calls: int = 0
	for child: Node in interior.get_children():
		if child is MultiMeshInstance3D:
			draw_calls += 1
	_check(draw_calls <= 6, "интерьер стоит %d вызовов отрисовки" % draw_calls)

	interior.queue_free()

	# LRU: генератор не должен держать больше MAX_INTERIORS подъездов сразу.
	var opened: int = 0
	for i: int in range(mini(apartments.size(), NoirCityGenerator.MAX_INTERIORS + 2)):
		if _generator.open_interior_now(apartments[i]) != null:
			opened += 1
	var open_now: int = int(_generator.stats()["interiors_open"])
	_check(open_now <= NoirCityGenerator.MAX_INTERIORS,
		"одновременно открыто интерьеров: %d (лимит %d, пытались %d)" % [open_now, NoirCityGenerator.MAX_INTERIORS, opened])


# --------------------------------------------------------------- облёт и HUD

func _advance_flythrough(delta: float) -> void:
	# Прогрев: счётчик FPS в Godot обновляется раз в секунду, и первые его
	# показания взяты из недосчитанной секунды. Плюс в это время компилируются
	# шейдеры. Меряем только после прогрева и по времени кадра, а не по счётчику.
	_fly_elapsed += delta
	if _fly_elapsed > WARMUP_SEC:
		_fps_samples.append(1.0 / maxf(0.0001, delta))
		_frame_ms.append(delta * 1000.0)

	_fly_timer += delta

	var from_index: int = _fly_index % FLY_POINTS.size()
	var to_index: int = (_fly_index + 1) % FLY_POINTS.size()
	var t: float = clampf(_fly_timer / FLY_SEGMENT_SEC, 0.0, 1.0)
	var position: Vector3 = FLY_POINTS[from_index].lerp(FLY_POINTS[to_index], smoothstep(0.0, 1.0, t))
	_player.teleport(position, FLY_POINTS[to_index] + Vector3(0.0, -30.0, 0.0))

	if t >= 1.0:
		_fly_timer = 0.0
		_fly_index += 1
		if _fly_index >= FLY_POINTS.size():
			_finish_flythrough()


func _finish_flythrough() -> void:
	_flythrough = false

	var sorted: Array = Array(_frame_ms)
	sorted.sort()
	var counted: int = sorted.size()
	if counted == 0:
		print("Облёт завершён, но замеров не набралось")
		get_tree().quit(0)
		return

	var total: float = 0.0
	for value: Variant in sorted:
		total += float(value)
	var average_ms: float = total / float(counted)
	# 1% худших кадров — честный показатель рывков, в отличие от единичного минимума.
	var low_index: int = maxi(0, int(float(counted) * 0.99) - 1)
	var one_percent_low_ms: float = float(sorted[low_index])
	var worst_ms: float = float(sorted[counted - 1])

	var stats: Dictionary = _generator.stats()
	var summary: String = "Облёт завершён | средний FPS %.1f (%.1f мс) | 1%% низких %.1f FPS (%.1f мс) | худший кадр %.1f мс | чанков %d | зданий %d | вызовов отрисовки %d" % [
		1000.0 / maxf(0.001, average_ms), average_ms,
		1000.0 / maxf(0.001, one_percent_low_ms), one_percent_low_ms,
		worst_ms,
		int(stats["chunks_loaded"]),
		int(stats["buildings"]),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	]
	Log.info("Phase2Bench", summary)
	print(summary)
	get_tree().quit(0)


## Виды для съёмки: те же ракурсы, что и на референсных картах, плюс
## уровень улицы — чтобы было видно и силуэт, и мокрый асфальт вблизи.
const SHOT_VIEWS: Array[Dictionary] = [
	{"name": "01_downtown_aerial", "from": Vector3(-620.0, 420.0, 720.0), "at": Vector3(-40.0, 60.0, 0.0)},
	{"name": "02_core_street", "from": Vector3(-60.0, 6.0, 120.0), "at": Vector3(-40.0, 40.0, -220.0)},
	{"name": "03_river_bridge", "from": Vector3(1180.0, 90.0, -260.0), "at": Vector3(1520.0, 10.0, -520.0)},
	{"name": "04_entertainment", "from": Vector3(-1720.0, 70.0, 1220.0), "at": Vector3(-1400.0, 20.0, 900.0)},
	{"name": "05_slums_street", "from": Vector3(1000.0, 5.5, 1400.0), "at": Vector3(1180.0, 25.0, 1150.0)},
	{"name": "06_skyline_high", "from": Vector3(240.0, 620.0, 980.0), "at": Vector3(-200.0, 80.0, -500.0)},
]


func _capture_views() -> void:
	var directory: String = "user://shots"
	var mkdir: int = DirAccess.make_dir_recursive_absolute(directory)
	if mkdir != OK and mkdir != ERR_ALREADY_EXISTS:
		Log.error("Phase2Bench", "Не создать каталог для снимков", {"код": mkdir})
		get_tree().quit(1)
		return

	_hud.visible = false
	_player.flying = true

	for view: Dictionary in SHOT_VIEWS:
		_player.teleport(view["from"], view["at"])
		_generator.refresh()

		# Ждём, пока стриминг догрузит окружение и отрисуется пара кадров:
		# снимок недостроенного города ничего не покажет.
		var guard: int = 0
		while not _generator.is_idle() and guard < 600:
			guard += 1
			await get_tree().process_frame
		for _i: int in range(6):
			await get_tree().process_frame

		var image: Image = get_viewport().get_texture().get_image()
		if image == null:
			Log.error("Phase2Bench", "Кадр не захвачен", {"вид": str(view["name"])})
			continue
		var path: String = "%s/%s.png" % [directory, str(view["name"])]
		var save_error: int = image.save_png(path)
		if save_error != OK:
			Log.error("Phase2Bench", "Снимок не сохранён", {"путь": path, "код": save_error})
			continue
		print("Снимок: " + ProjectSettings.globalize_path(path))

	print("Снимки готовы: " + ProjectSettings.globalize_path(directory))
	get_tree().quit(0)


func _update_hud() -> void:
	if _hud == null or not is_instance_valid(_hud):
		return

	var stats: Dictionary = _generator.stats()
	var position: Vector3 = _player.global_position
	var district: Dictionary = CityAtlas.district_at_world(position)

	_hud.clear()
	_hud.append_text("[b]%s[/b]  %s\n" % [
		str(district.get("ru", "вне города")),
		CityAtlas.address_for_point(Vector2(position.x, position.z)),
	])
	_hud.append_text("FPS %d   вызовов отрисовки %d   примитивов %s\n" % [
		int(Engine.get_frames_per_second()),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		_short(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
	])
	_hud.append_text("чанки %d (ближ %d / сред %d / дальн %d)  в очереди %d\n" % [
		int(stats["chunks_loaded"]), int(stats["chunks_near"]),
		int(stats["chunks_mid"]), int(stats["chunks_far"]), int(stats["chunks_queued"]),
	])
	_hud.append_text("зданий %d   входов %d   интерьеров открыто %d\n" % [
		int(stats["buildings"]), int(stats["entrances"]), int(stats["interiors_open"]),
	])
	_hud.append_text("позиция %d / %d   режим: %s   память %s\n" % [
		int(position.x), int(position.z),
		"полёт" if _player.flying else "ходьба",
		_short(Performance.get_monitor(Performance.MEMORY_STATIC)),
	])
	_hud.append_text("[color=#7DF9FF]ЛКМ — захват мыши, WASD+QE — движение, F — полёт/ходьба, Esc — отпустить[/color]")


func _short(value: float) -> String:
	if value > 1_000_000_000.0:
		return "%.1f млрд" % (value / 1_000_000_000.0)
	if value > 1_000_000.0:
		return "%.1f млн" % (value / 1_000_000.0)
	if value > 1_000.0:
		return "%.1f тыс" % (value / 1_000.0)
	return "%.0f" % value


# -------------------------------------------------------------------- служебное

func _content_hash(content: Dictionary) -> int:
	var parts: PackedStringArray = []
	for entry: Variant in content["buildings"] as Array:
		var b: Dictionary = entry as Dictionary
		var center: Vector3 = b["center"]
		var size: Vector3 = b["size"]
		parts.append("%.2f;%.2f;%.2f;%.2f" % [center.x, center.z, size.x, size.y])
	parts.sort()
	return hash("|".join(parts))


func _section(title: String) -> void:
	_say("")
	_say("[b]%s[/b]" % title)


func _check(condition: bool, description: String) -> bool:
	if condition:
		_passed += 1
		_say("  [color=#39FF88]OK[/color]   %s" % description)
	else:
		_failed += 1
		_say("  [color=#E8253F]FAIL[/color] %s" % description)
	return condition


func _say(line: String) -> void:
	_lines.append(line)
	print(_strip_bbcode(line))
	if _report != null and is_instance_valid(_report):
		_report.append_text(line + "\n")


func _flush() -> void:
	var file: FileAccess = FileAccess.open("user://phase2_report.txt", FileAccess.WRITE)
	if file == null:
		return
	file.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]))
	for line: String in _lines:
		file.store_line(_strip_bbcode(line))
	file.close()
	print("Отчёт сохранён: " + ProjectSettings.globalize_path("user://phase2_report.txt"))


func _strip_bbcode(text: String) -> String:
	var regex := RegEx.new()
	if regex.compile("\\[/?[a-zA-Z][^\\]]*\\]") != OK:
		return text
	return regex.sub(text, "", true)
