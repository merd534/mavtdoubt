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
## Уровни детализации назначаются по расстоянию в чанках и пересобираются
## на лету, когда игрок приближается или отдаляется.

const CHUNK_SIZE_DEFAULT := 240.0
const DETAIL_NEAR_CHUNKS := 1
const DETAIL_MID_CHUNKS := 3
const MAX_INTERIORS := 4
const INTERIOR_ENTER_RADIUS := 26.0
const INTERIOR_RELEASE_RADIUS := 55.0
const INTERIOR_CHECK_INTERVAL := 0.25
const OBSERVER_MOVE_EPSILON := 12.0

signal chunk_built(coords: Vector2i, build_ms: int)
signal chunk_released(coords: Vector2i)
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

var _observer: Node3D = null
var _observer_position: Vector3 = Vector3.ZERO
var _last_stream_position: Vector3 = Vector3(1e9, 1e9, 1e9)

var _chunks: Dictionary = {}          # Vector2i -> NoirCityChunk
var _queue: Array[Vector2i] = []
var _queued: Dictionary = {}          # Vector2i -> уровень детализации
var _release_queue: Array[Vector2i] = []
var _grid_size: Vector2i = Vector2i.ZERO
var _grid_origin: Vector2 = Vector2.ZERO

var _entrances: Dictionary = {}       # location_id -> Vector3
var _interiors: Dictionary = {}       # location_id -> Node3D
var _interior_order: Array[String] = []
var _interior_timer: float = 0.0

var _river: Node3D = null
var _far_field: Node3D = null
var _chunk_root: Node3D = null
var _interior_root: Node3D = null

var _was_idle: bool = false
var _total_build_ms: int = 0
var _built_count: int = 0


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
	_far_field = NoirCityFarField.build()
	add_child(_far_field)

	var bounds: Rect2 = CityAtlas.world_bounds()
	_grid_origin = bounds.position
	_grid_size = Vector2i(
		int(ceil(bounds.size.x / chunk_size)),
		int(ceil(bounds.size.y / chunk_size))
	)

	Log.info("CityGenerator", "Генератор города поднят", {
		"чанк_м": chunk_size,
		"сетка": "%dx%d" % [_grid_size.x, _grid_size.y],
		"всего_чанков": _grid_size.x * _grid_size.y,
		"бюджет_мс": build_budget_ms,
	})


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
	for key: Variant in _chunks.keys():
		var chunk: NoirCityChunk = _chunks[key]
		if chunk == null or not is_instance_valid(chunk):
			continue
		by_detail[clampi(chunk.detail_level, 0, 2)] += 1
		buildings += chunk.building_count()

	return {
		"chunks_loaded": _chunks.size(),
		"chunks_queued": _queue.size(),
		"chunks_near": by_detail[0],
		"chunks_mid": by_detail[1],
		"chunks_far": by_detail[2],
		"buildings": buildings,
		"entrances": _entrances.size(),
		"interiors_open": _interiors.size(),
		"avg_build_ms": 0.0 if _built_count == 0 else float(_total_build_ms) / float(_built_count),
		"grid": "%dx%d" % [_grid_size.x, _grid_size.y],
	}


# ---------------------------------------------------------------- стриминг

func _stream_radius() -> int:
	var distance: float = GameConfig.get_float("graphics", "render_distance_m")
	var by_distance: int = int(ceil(maxf(chunk_size, distance) / chunk_size))
	var cap: int = maxi(1, GameConfig.get_int("graphics", "chunk_radius"))
	return clampi(by_distance, 1, cap)


func _update_streaming() -> void:
	var center: Vector2i = chunk_coords_at(_observer_position)
	var radius: int = _stream_radius()

	var wanted: Dictionary = {}
	for dx: int in range(-radius, radius + 1):
		for dy: int in range(-radius, radius + 1):
			var coords := Vector2i(center.x + dx, center.y + dy)
			if coords.x < 0 or coords.y < 0 or coords.x >= _grid_size.x or coords.y >= _grid_size.y:
				continue
			# Круглое, а не квадратное кольцо — углы квадрата вдвое дальше центра
			# и стоили бы впустую.
			if Vector2(float(dx), float(dy)).length() > float(radius) + 0.5:
				continue
			wanted[coords] = _detail_for(absi(dx), absi(dy))

	# Ставим в очередь на выгрузку всё, что вышло за кольцо.
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
		if _chunks.has(coords):
			var chunk: NoirCityChunk = _chunks[coords]
			if chunk != null and is_instance_valid(chunk) and chunk.detail_level != detail:
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
	_queued.erase(coords)

	# Чанк уже стоит — значит это заявка на смену детализации.
	if _chunks.has(coords):
		var existing: Variant = _chunks[coords]
		if existing is NoirCityChunk and is_instance_valid(existing as NoirCityChunk):
			var typed: NoirCityChunk = existing as NoirCityChunk
			if typed.detail_level != detail:
				typed.set_detail(detail, CityAtlas.city_seed)
				_reindex_entrances(typed)
		return

	var chunk: NoirCityChunk = NoirCityChunk.create(coords, chunk_rect(coords), detail)
	_chunk_root.add_child(chunk)
	var build_ms: int = chunk.build(CityAtlas.city_seed)

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
			_entrances.erase(str((entry as Dictionary)["location_id"]))
		typed.dispose()
	chunk_released.emit(coords)


func _reindex_entrances(chunk: NoirCityChunk) -> void:
	for entry: Variant in chunk.entrances():
		var data: Dictionary = entry as Dictionary
		_entrances[str(data["location_id"])] = data["position"]


# ---------------------------------------------------------------- интерьеры

func _update_interiors() -> void:
	if _entrances.is_empty():
		return

	# Открываем интерьер здания, к которому подошли вплотную.
	for key: Variant in _entrances.keys():
		var location_id: String = str(key)
		if _interiors.has(location_id):
			continue
		var entrance: Vector3 = _entrances[key]
		if _observer_position.distance_to(entrance) <= INTERIOR_ENTER_RADIUS:
			_open_interior(location_id)

	# Закрываем то, от чего отошли.
	var to_close: Array[String] = []
	for key: Variant in _interiors.keys():
		var location_id: String = str(key)
		var entrance: Variant = _entrances.get(location_id, null)
		if entrance == null:
			to_close.append(location_id)
			continue
		if _observer_position.distance_to(entrance as Vector3) > INTERIOR_RELEASE_RADIUS:
			to_close.append(location_id)
	for location_id: String in to_close:
		_close_interior(location_id)


func _open_interior(location_id: String) -> void:
	while _interior_order.size() >= MAX_INTERIORS:
		_close_interior(_interior_order[0])

	var node: Node3D = NoirInteriorFactory.build(location_id)
	if node == null:
		# Помечаем, чтобы не пытаться строить снова каждые 0.25 с.
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
	_open_interior(location_id)
	var node: Variant = _interiors.get(location_id, null)
	return node as Node3D if node is Node3D else null
