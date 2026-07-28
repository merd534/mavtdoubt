class_name NoirCityGenerator
extends Node3D
## Стриминг города. Держит вокруг наблюдателя кольцо чанков, строит их
## с покадровым бюджетом и выгружает всё, что вышло за радиус.
##
## Почему покадровый бюджет, а не поток: сборка чанка создаёт узлы сцены, а это
## можно делать только в главном потоке. Вместо этого сборка нарезана по времени —
## не больше [member build_budget_ms] миллисекунд за кадр. Город догружается за
## несколько кадров, но кадр не проваливается.
##
## ФАЗА 4 добавила третью ступень стриминга. Раньше было два состояния:
## «чанк есть» и «чанка нет», и на границе радиуса город постоянно пересобирался,
## стоит игроку сделать два шага вперёд-назад. Теперь:
##
##   1. ближнее кольцо         — видимо, детализировано, физика включена;
##   2. буферное кольцо        — геометрия жива, но скрыта целиком (0 вызовов
##      отрисовки, нет физики, нет частиц) — возврат стоит один флаг;
##   3. за буфером            — полная выгрузка из памяти.
##
## Уровни детализации назначаются по расстоянию в чанках и пересобираются
## на лету, когда игрок приближается или отдаляется.
##
## Интерьеры: войти можно в ЛЮБОЕ здание ближнего кольца, а не только в
## сюжетные адреса атласа. Генератор хранит полную запись входа
## (габариты, этажность, центр дома) и передаёт её фабрике интерьеров.

const CHUNK_SIZE_DEFAULT := 240.0
const DETAIL_NEAR_CHUNKS := 1
const DETAIL_MID_CHUNKS := 3
## Сколько интерьеров держим одновременно. На плотной улице в радиус 26 м
## попадает до шести подъездов — меньший лимит заставлял бы их моргать.
const MAX_INTERIORS := 6
const INTERIOR_ENTER_RADIUS := 26.0
const INTERIOR_RELEASE_RADIUS := 55.0
const INTERIOR_CHECK_INTERVAL := 0.25
const OBSERVER_MOVE_EPSILON := 12.0
## Сколько колец за видимым радиусом держать скрытыми, если в настройках
## ничего не указано.
const HIDE_RING_DEFAULT := 1
## Дальше этого расстояния от игрока мебель открытого интерьера гаснет,
## а потом выгружается: сам каркас остаётся, чтобы окна не стали дырами.
const FURNITURE_SLEEP_RADIUS := 34.0
const FURNITURE_UNLOAD_RADIUS := 48.0
## Точность окклюзии. Больше лучей — агрессивнее отсечение.
const OCCLUSION_RAYS_PER_THREAD := 32
## Качество BVH окклюдеров: 0 = LOW, 1 = MEDIUM, 2 = HIGH.
const OCCLUSION_BVH_QUALITY := 2
## Запас между краем реальной застройки и началом силуэтной заглушки,
## в чанках. Без него грубые кубы дальнего поля проступают поверх реальных
## домов — и игрок видит висящие в воздухе «фантомные окна» без зданий.
const FAR_FIELD_MARGIN_CHUNKS := 1.6

signal chunk_built(coords: Vector2i, build_ms: int)
signal chunk_released(coords: Vector2i)
signal chunk_hidden(coords: Vector2i, hidden: bool)
signal streaming_idle(loaded_chunks: int)
signal interior_opened(location_id: String)
signal interior_closed(location_id: String)

@export var chunk_size: float = CHUNK_SIZE_DEFAULT
@export var build_budget_ms: float = 6.0
@export var auto_stream: bool = true
## Жёсткий потолок на кадр. Бюджета по времени мало: сборка чанка дешёвая,
## и в один кадр их влезало по десятку, а платил за это уже не генератор,
## а физика и рендер, которым надо принять все новые узлы разом.
@export var max_builds_per_frame: int = 2
## Освобождение тоже размазываем: при быстром перелёте кольцо целиком
## становится ненужным, и разовое удаление 69 чанков роняло кадр до 14 FPS.
@export var max_releases_per_frame: int = 3
## ФАЗА 4. Агрессивное отсечение невидимого. Выключать только для отладки.
@export var use_occlusion_culling: bool = true

var _observer: Node3D = null
var _observer_position: Vector3 = Vector3.ZERO
var _last_stream_position: Vector3 = Vector3(1e9, 1e9, 1e9)

var _chunks: Dictionary = {}          # Vector2i -> NoirCityChunk
var _queue: Array[Vector2i] = []
var _queued: Dictionary = {}          # Vector2i -> уровень детализации
var _hidden_wanted: Dictionary = {}   # Vector2i -> bool, желаемая скрытость
var _release_queue: Array[Vector2i] = []
var _grid_size: Vector2i = Vector2i.ZERO
var _grid_origin: Vector2 = Vector2.ZERO

var _entrances: Dictionary = {}       # location_id -> полная запись входа (Dictionary)
var _interiors: Dictionary = {}       # location_id -> Node3D
var _interior_order: Array[String] = []
var _interior_timer: float = 0.0
## Адреса, для которых интерьер построить не вышло (слишком тесно и т.п.).
## Без этого списка генератор пытался бы строить их каждые 0.25 с.
var _interior_failed: Dictionary = {}

var _river: Node3D = null
var _far_field: Node3D = null
var _far_fade_radius: int = -1
var _chunk_root: Node3D = null
var _interior_root: Node3D = null

var _was_idle: bool = false
var _total_build_ms: int = 0
var _built_count: int = 0
var _hidden_count: int = 0


func _ready() -> void:
	if not CityAtlas.is_built():
		CityAtlas.build()
	if not CityMaterials.is_ready():
		Log.error("CityGenerator", "Материалы города не готовы — генерация отменена")
		set_process(false)
		return

	_chunk_root = Node3D.new()
	_chunk_root.name = "Chunks"
	add_child(_chunk_root)

	_interior_root = Node3D.new()
	_interior_root.name = "Interiors"
	add_child(_interior_root)

	_river = NoirRiverBuilder.build()
	add_child(_river)

	# Дальнее поле строится один раз и покрывает всю карту силуэтами.
	# Границу появления заглушки задаёт текущий радиус стриминга,
	# иначе на высоких пресетах она лезет внутрь реального города.
	_far_fade_radius = _stream_radius()
	_far_field = NoirCityFarField.build(_far_fade_distance())
	add_child(_far_field)

	var bounds: Rect2 = CityAtlas.world_bounds()
	_grid_origin = bounds.position
	_grid_size = Vector2i(
		int(ceil(bounds.size.x / chunk_size)),
		int(ceil(bounds.size.y / chunk_size))
	)

	_configure_occlusion_culling()

	Log.info("CityGenerator", "Генератор города поднят", {
		"чанк_м": chunk_size,
		"сетка": "%dx%d" % [_grid_size.x, _grid_size.y],
		"всего_чанков": _grid_size.x * _grid_size.y,
		"бюджет_мс": build_budget_ms,
		"окклюзия": use_occlusion_culling,
		"заглушка_от_м": _far_fade_distance(),
	})


## Расстояние, с которого разрешено показывать силуэтную заглушку.
func _far_fade_distance() -> float:
	var radius: float = float(maxi(1, _far_fade_radius))
	return (radius + FAR_FIELD_MARGIN_CHUNKS) * chunk_size


## ФАЗА 4. Отсечение невидимого. Громадные здания ставят окклюдеры
## (см. `CityChunk._build_occluder`), а здесь мы включаем сам механизм и поднимаем
## ему точность: без этого видеокарта обрабатывает тысячи вывесок и деталей
## интерьера, спрятанных за ближайшей стеной.
func _configure_occlusion_culling() -> void:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		Log.warn("CityGenerator", "Viewport недоступен — окклюзия не настроена")
		return

	RenderingServer.viewport_set_use_occlusion_culling(viewport.get_viewport_rid(), use_occlusion_culling)

	if not use_occlusion_culling:
		Log.info("CityGenerator", "Occlusion Culling выключен вручную")
		return

	# Точность окклюзии задаётся ТОЛЬКО настройками проекта: свойства
	# `RenderingServer.occlusion_rays_per_thread` не существует, сервер сам
	# перечитывает эти настройки. Пишем через guard, чтобы смена версии
	# движка не уронила запуск.
	_set_project_setting(
		"rendering/occlusion_culling/occlusion_rays_per_thread",
		OCCLUSION_RAYS_PER_THREAD
	)
	# HIGH: перестройка BVH идёт при загрузке чанка, а не каждый кадр.
	_set_project_setting(
		"rendering/occlusion_culling/bvh_build_quality",
		OCCLUSION_BVH_QUALITY
	)

	Log.info("CityGenerator", "Occlusion Culling включён", {
		"лучей_на_поток": OCCLUSION_RAYS_PER_THREAD,
		"качество_bvh": OCCLUSION_BVH_QUALITY,
	})


## Безопасная запись настройки проекта: незнакомый движку путь просто
## игнорируется с предупреждением в лог.
func _set_project_setting(path: String, value: Variant) -> void:
	if not ProjectSettings.has_setting(path):
		Log.warn("CityGenerator", "Настройка проекта не найдена", {"путь": path})
		return
	ProjectSettings.set_setting(path, value)


func _process(delta: float) -> void:
	if _observer != null and is_instance_valid(_observer):
		_observer_position = _observer.global_position

	if auto_stream and _observer_position.distance_to(_last_stream_position) > OBSERVER_MOVE_EPSILON:
		_last_stream_position = _observer_position
		_update_streaming()

	_drain_queue()

	_interior_timer -= delta
	if _interior_timer <= 0.0:
		_interior_timer = INTERIOR_CHECK_INTERVAL
		_update_interiors()
		_update_interior_detail()


# ---------------------------------------------------------------- публичный API

func set_observer(node: Node3D) -> void:
	if node == null or not is_instance_valid(node):
		Log.warn("CityGenerator", "Попытка назначить невалидного наблюдателя")
		return
	_observer = node
	_observer_position = node.global_position
	_last_stream_position = Vector3(1e9, 1e9, 1e9)
	Log.info("CityGenerator", "Наблюдатель назначен", {"узел": node.name})


func set_observer_position(position: Vector3) -> void:
	_observer = null
	_observer_position = position


func observer_position() -> Vector3:
	return _observer_position


func loaded_chunk_count() -> int:
	return _chunks.size()


func queued_chunk_count() -> int:
	return _queue.size()


func hidden_chunk_count() -> int:
	return _hidden_count


func is_idle() -> bool:
	return _queue.is_empty() and _release_queue.is_empty()


## Строит все запрошенные чанки немедленно, игнорируя бюджет кадра.
## Только для тестов и оффлайн-прогрева — в игре не вызывать.
func flush_queue(max_chunks: int = 4096) -> int:
	while not _release_queue.is_empty():
		_release_chunk(_release_queue.pop_front())
	var built: int = 0
	while not _queue.is_empty() and built < max_chunks:
		_build_next()
		built += 1
	return built


## Принудительно пересчитывает окружение наблюдателя.
func refresh() -> void:
	_last_stream_position = _observer_position
	_update_streaming()


func chunk_coords_at(point: Vector3) -> Vector2i:
	return Vector2i(
		int(floor((point.x - _grid_origin.x) / chunk_size)),
		int(floor((point.z - _grid_origin.y) / chunk_size))
	)


func chunk_rect(coords: Vector2i) -> Rect2:
	return Rect2(
		Vector2(_grid_origin.x + float(coords.x) * chunk_size, _grid_origin.y + float(coords.y) * chunk_size),
		Vector2(chunk_size, chunk_size)
	)


func stats() -> Dictionary:
	var by_detail: Array[int] = [0, 0, 0]
	var buildings: int = 0
	var hidden: int = 0
	for key: Variant in _chunks.keys():
		var chunk: NoirCityChunk = _chunks[key]
		if chunk == null or not is_instance_valid(chunk):
			continue
		by_detail[clampi(chunk.detail_level, 0, 2)] += 1
		buildings += chunk.building_count()
		if chunk.is_hidden_chunk():
			hidden += 1
	_hidden_count = hidden

	return {
		"chunks_loaded": _chunks.size(),
		"chunks_queued": _queue.size(),
		"chunks_hidden": hidden,
		"chunks_near": by_detail[0],
		"chunks_mid": by_detail[1],
		"chunks_far": by_detail[2],
		"buildings": buildings,
		"entrances": _entrances.size(),
		"interiors_open": _interiors.size(),
		"avg_build_ms": 0.0 if _built_count == 0 else float(_total_build_ms) / float(_built_count),
		"grid": "%dx%d" % [_grid_size.x, _grid_size.y],
		"occlusion": use_occlusion_culling,
	}


# ---------------------------------------------------------------- стриминг

func _stream_radius() -> int:
	var distance: float = GameConfig.get_float("graphics", "render_distance_m")
	var by_distance: int = int(ceil(maxf(chunk_size, distance) / chunk_size))
	var cap: int = maxi(1, GameConfig.get_int("graphics", "chunk_radius"))
	return clampi(by_distance, 1, cap)


## Ширина буферного кольца в чанках. На «Картошке» буфер нулевой:
## там важна память, а не плавность догрузки.
func _hide_ring() -> int:
	var graphics: Dictionary = GameConfig.section("graphics")
	var value: int = int(graphics.get("hide_radius_chunks", HIDE_RING_DEFAULT))
	return clampi(value, 0, 4)


func _update_streaming() -> void:
	var center: Vector2i = chunk_coords_at(_observer_position)
	var radius: int = _stream_radius()
	var total: int = radius + _hide_ring()

	# Радиус меняется вместе с графическим пресетом — заглушка дальнего
	# плана обязана отъехать за новую границу реальной застройки.
	if radius != _far_fade_radius:
		_far_fade_radius = radius
		if _far_field != null and is_instance_valid(_far_field):
			NoirCityFarField.set_fade_begin(_far_field, _far_fade_distance())

	var wanted: Dictionary = {}
	_hidden_wanted.clear()
	for dx: int in range(-total, total + 1):
		for dy: int in range(-total, total + 1):
			var coords := Vector2i(center.x + dx, center.y + dy)
			if coords.x < 0 or coords.y < 0 or coords.x >= _grid_size.x or coords.y >= _grid_size.y:
				continue
			# Круглое, а не квадратное кольцо — углы квадрата вдвое дальше центра
			# и стоили бы впустую.
			var length: float = Vector2(float(dx), float(dy)).length()
			if length > float(total) + 0.5:
				continue
			var hidden: bool = length > float(radius) + 0.5
			# Скрытый чанк всегда дальний: детали всё равно не видны, а при
			# возврате в видимое кольцо он пересоберётся на нужный LOD.
			wanted[coords] = NoirCityChunk.DETAIL_FAR if hidden else _detail_for(absi(dx), absi(dy))
			_hidden_wanted[coords] = hidden

	# Ставим в очередь на выгрузку всё, что вышло за буфер.
	_release_queue.clear()
	for key: Variant in _chunks.keys():
		var coords: Vector2i = key
		if not wanted.has(coords):
			_release_queue.append(coords)

	# Снимаем из очереди сборки то, что уже успело стать ненужным.
	var still_wanted: Array[Vector2i] = []
	for coords: Vector2i in _queue:
		if wanted.has(coords):
			still_wanted.append(coords)
		else:
			_queued.erase(coords)
	_queue = still_wanted

	# Ставим в очередь недостающие и правим детализацию существующих.
	var pending_detail: Array[Vector2i] = []
	for key: Variant in wanted.keys():
		var coords: Vector2i = key
		var detail: int = int(wanted[coords])
		var hidden: bool = bool(_hidden_wanted.get(coords, false))
		if _chunks.has(coords):
			var chunk: NoirCityChunk = _chunks[coords]
			if chunk == null or not is_instance_valid(chunk):
				continue
			# Сначала скрытость: это бесплатно и срабатывает в том же кадре.
			if chunk.is_hidden_chunk() != hidden:
				chunk.set_hidden(hidden)
				chunk_hidden.emit(coords, hidden)
			if chunk.detail_level != detail:
				pending_detail.append(coords)
				_queued[coords] = detail
			continue
		if _queued.has(coords):
			_queued[coords] = detail
			continue
		_queue.append(coords)
		_queued[coords] = detail

	# Пересборка LOD — тоже работа, её нельзя делать всю сразу: ставим в общую
	# очередь, там она поедет с тем же покадровым лимитом.
	for coords: Vector2i in pending_detail:
		if not _queue.has(coords):
			_queue.append(coords)

	_sort_queue(center)
	_was_idle = false


func _detail_for(dx: int, dy: int) -> int:
	var ring: int = maxi(dx, dy)
	if ring <= DETAIL_NEAR_CHUNKS:
		return NoirCityChunk.DETAIL_NEAR
	if ring <= DETAIL_MID_CHUNKS:
		return NoirCityChunk.DETAIL_MID
	return NoirCityChunk.DETAIL_FAR


func _sort_queue(center: Vector2i) -> void:
	_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da: int = (a.x - center.x) * (a.x - center.x) + (a.y - center.y) * (a.y - center.y)
		var db: int = (b.x - center.x) * (b.x - center.x) + (b.y - center.y) * (b.y - center.y)
		return da < db
	)


func _drain_queue() -> void:
	# Сначала освобождаем — так пик памяти не растёт при перелёте через город.
	var released: int = 0
	while not _release_queue.is_empty() and released < maxi(1, max_releases_per_frame):
		_release_chunk(_release_queue.pop_front())
		released += 1

	if _queue.is_empty():
		if _release_queue.is_empty() and not _was_idle:
			_was_idle = true
			streaming_idle.emit(_chunks.size())
		return

	var deadline: int = Time.get_ticks_usec() + int(maxf(0.5, build_budget_ms) * 1000.0)
	var built: int = 0
	var limit: int = maxi(1, max_builds_per_frame)
	while not _queue.is_empty() and built < limit and Time.get_ticks_usec() < deadline:
		_build_next()
		built += 1


func _build_next() -> void:
	if _queue.is_empty():
		return
	var coords: Vector2i = _queue.pop_front()
	var detail: int = int(_queued.get(coords, NoirCityChunk.DETAIL_FAR))
	var hidden: bool = bool(_hidden_wanted.get(coords, false))
	_queued.erase(coords)

	# Чанк уже стоит — значит это заявка на смену детализации.
	if _chunks.has(coords):
		var existing: Variant = _chunks[coords]
		if existing is NoirCityChunk and is_instance_valid(existing as NoirCityChunk):
			var typed: NoirCityChunk = existing as NoirCityChunk
			if typed.detail_level != detail:
				typed.set_detail(detail, CityAtlas.city_seed)
				_reindex_entrances(typed)
			if typed.is_hidden_chunk() != hidden:
				typed.set_hidden(hidden)
				chunk_hidden.emit(coords, hidden)
		return

	var chunk: NoirCityChunk = NoirCityChunk.create(coords, chunk_rect(coords), detail)
	_chunk_root.add_child(chunk)
	var build_ms: int = chunk.build(CityAtlas.city_seed)
	if hidden:
		chunk.set_hidden(true)

	_chunks[coords] = chunk
	_total_build_ms += build_ms
	_built_count += 1
	_reindex_entrances(chunk)

	chunk_built.emit(coords, build_ms)


func _release_chunk(coords: Vector2i) -> void:
	var chunk: Variant = _chunks.get(coords, null)
	_chunks.erase(coords)
	if chunk is NoirCityChunk and is_instance_valid(chunk as NoirCityChunk):
		var typed: NoirCityChunk = chunk as NoirCityChunk
		for entry: Variant in typed.entrances():
			var location_id: String = str((entry as Dictionary)["location_id"])
			_entrances.erase(location_id)
			# Интерьер без чанка висеть не должен: иначе после выгрузки города
			# останутся парящие в воздухе квартиры.
			if _interiors.has(location_id):
				_close_interior(location_id)
		typed.dispose()
	chunk_released.emit(coords)


## Запись входа сохраняется целиком: фабрике интерьеров нужны габариты
## и этажность дома, а не только точка двери.
func _reindex_entrances(chunk: NoirCityChunk) -> void:
	for entry: Variant in chunk.entrances():
		var data: Dictionary = entry as Dictionary
		if data == null or data.is_empty():
			continue
		var location_id: String = str(data.get("location_id", ""))
		if location_id.is_empty():
			continue
		if _interior_failed.has(location_id):
			continue
		_entrances[location_id] = data


## Точка двери по идентификатору. Возвращает `false` во втором элементе,
## если входа больше нет (чанк выгрузился).
func _entrance_position(location_id: String) -> Array:
	var raw: Variant = _entrances.get(location_id, null)
	if not (raw is Dictionary):
		return [Vector3.ZERO, false]
	var data: Dictionary = raw as Dictionary
	var position: Variant = data.get("position", null)
	if not (position is Vector3):
		return [Vector3.ZERO, false]
	return [position as Vector3, true]


# ---------------------------------------------------------------- интерьеры

func _update_interiors() -> void:
	if _entrances.is_empty():
		return

	# Открываем интерьер здания, к которому подошли вплотную. Если рядом
	# сразу несколько подъездов, берём ближайшие: лимит MAX_INTERIORS
	# должен тратиться на те дома, в которые игрок реально может войти.
	var candidates: Array[Dictionary] = []
	for key: Variant in _entrances.keys():
		var location_id: String = str(key)
		if _interiors.has(location_id):
			continue
		var found: Array = _entrance_position(location_id)
		if not bool(found[1]):
			continue
		var distance: float = _observer_position.distance_to(found[0] as Vector3)
		if distance <= INTERIOR_ENTER_RADIUS:
			candidates.append({"id": location_id, "distance": distance})

	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance"]) < float(b["distance"])
	)
	for candidate: Dictionary in candidates:
		_open_interior(str(candidate["id"]))

	# Закрываем то, от чего отошли.
	var to_close: Array[String] = []
	for key: Variant in _interiors.keys():
		var location_id: String = str(key)
		var found: Array = _entrance_position(location_id)
		if not bool(found[1]):
			to_close.append(location_id)
			continue
		if _observer_position.distance_to(found[0] as Vector3) > INTERIOR_RELEASE_RADIUS:
			to_close.append(location_id)
	for location_id: String in to_close:
		_close_interior(location_id)


## ФАЗА 4. Ступенчатая выгрузка мебели внутри ещё открытых интерьеров.
## Мебель — самая тяжёлая часть интерьера и самая бесполезная, пока игрок
## стоит на улице перед подъездом.
func _update_interior_detail() -> void:
	if _interiors.is_empty():
		return

	for key: Variant in _interiors.keys():
		var location_id: String = str(key)
		var node: Variant = _interiors[key]
		if not (node is Node3D) or not is_instance_valid(node as Node3D):
			continue
		var interior: Node3D = node as Node3D
		var found: Array = _entrance_position(location_id)
		if not bool(found[1]):
			continue
		var distance: float = _observer_position.distance_to(found[0] as Vector3)

		if distance > FURNITURE_UNLOAD_RADIUS:
			NoirInteriorFactory.unload_furniture(interior)
		else:
			NoirInteriorFactory.set_furniture_active(interior, distance <= FURNITURE_SLEEP_RADIUS)


func _open_interior(location_id: String) -> void:
	if _interiors.has(location_id) or _interior_failed.has(location_id):
		return

	var raw: Variant = _entrances.get(location_id, null)
	if not (raw is Dictionary):
		return

	while _interior_order.size() >= MAX_INTERIORS:
		_close_interior(_interior_order[0])

	var node: Node3D = NoirInteriorFactory.build_for(raw as Dictionary)
	if node == null:
		# Запоминаем отказ, чтобы не пытаться строить снова каждые 0.25 с.
		_interior_failed[location_id] = true
		_entrances.erase(location_id)
		return

	_interior_root.add_child(node)
	_interiors[location_id] = node
	_interior_order.append(location_id)
	interior_opened.emit(location_id)


func _close_interior(location_id: String) -> void:
	var node: Variant = _interiors.get(location_id, null)
	_interiors.erase(location_id)
	_interior_order.erase(location_id)
	if node is Node3D and is_instance_valid(node as Node3D):
		(node as Node3D).queue_free()
	interior_closed.emit(location_id)


## Принудительно открывает интерьер (например, когда дело требует осмотра).
func open_interior_now(location_id: String) -> Node3D:
	if _interiors.has(location_id):
		return _interiors[location_id]
	_interior_failed.erase(location_id)
	_open_interior(location_id)
	var node: Variant = _interiors.get(location_id, null)
	return node as Node3D if node is Node3D else null
