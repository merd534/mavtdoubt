class_name NoirCityFarField
extends RefCounted
## Дальнее поле — грубый силуэт всего города за пределами кольца стриминга.
##
## Зачем: кольцо чанков покрывает ~960 м, а с крыши или с высоты видно весь
## мегаполис. Без дальнего поля за кольцом начиналась чернота, и главный образ
## референса — неоновый ковёр до горизонта — не работал.
##
## Как устроено: карта режется на «супер-плитки» по [constant TILE_CHUNKS]
## чанков. У каждой плитки один MultiMesh с по одному кубу на квартал и
## `visibility_range_begin` чуть меньше радиуса стриминга. Пока плитка близко,
## её рисуют настоящие чанки, а силуэт скрыт; как только камера отдаляется —
## силуэт проявляется. Итог: не больше [code]20[/code] лишних вызовов отрисовки
## на весь город при полном обзоре.

const TILE_SIZE := 960.0            ## сторона супер-плитки в метрах
const FADE_BEGIN := 780.0           ## с какой дистанции силуэт включается
const FADE_MARGIN := 220.0
const MIN_TILE_INSTANCES := 1
const FLOOR_HEIGHT := 3.4


static func build() -> Node3D:
	var root := Node3D.new()
	root.name = "FarField"

	var bounds: Rect2 = CityAtlas.world_bounds()
	var tiles_x: int = int(ceil(bounds.size.x / TILE_SIZE))
	var tiles_y: int = int(ceil(bounds.size.y / TILE_SIZE))
	var started: int = Time.get_ticks_usec()
	var total_instances: int = 0

	for tx: int in range(tiles_x):
		for ty: int in range(tiles_y):
			var tile := Rect2(
				Vector2(bounds.position.x + float(tx) * TILE_SIZE, bounds.position.y + float(ty) * TILE_SIZE),
				Vector2(TILE_SIZE, TILE_SIZE)
			)
			var blocks: Array[Dictionary] = _coarse_blocks(tile)
			if blocks.size() < MIN_TILE_INSTANCES:
				continue

			var node: MultiMeshInstance3D = _make_tile(blocks, "FarTile_%d_%d" % [tx, ty])
			root.add_child(node)
			total_instances += blocks.size()

	Log.info("CityFarField", "Дальнее поле построено", {
		"плиток": root.get_child_count(),
		"силуэтов": total_instances,
		"мс": int((Time.get_ticks_usec() - started) / 1000),
	})
	return root


## Один куб на квартал: та же сетка, что у настоящей застройки, но без
## дробления на участки. Высота — усреднённая по району с той же поправкой
## «ближе к центру района выше», поэтому силуэт совпадает с реальным городом.
static func _coarse_blocks(tile: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for district_id: String in CityAtlas.district_ids():
		if district_id == "outskirts":
			continue
		var district: Dictionary = CityAtlas.get_district(district_id)
		if district.is_empty():
			continue
		var bounds: Rect2 = district["bounds"]
		if not bounds.intersects(tile):
			continue

		var block_size: float = float(district["block"])
		var pitch: float = block_size + float(district["street"])
		if pitch <= 1.0:
			continue

		var density: float = float(district["density"])
		var h_min: float = float(district["height_min"])
		var h_max: float = float(district["height_max"])
		var palette: Array[Color] = CityAtlas.district_palette(district_id)
		var neon: float = float(district["neon"])
		var wealth: float = float(district["wealth"])
		var half_diag: float = maxf(1.0, bounds.size.length() * 0.5)
		var district_center: Vector2 = bounds.get_center()

		var i_from: int = int(floor((tile.position.x - bounds.position.x) / pitch))
		var i_to: int = int(ceil((tile.end.x - bounds.position.x) / pitch))
		var j_from: int = int(floor((tile.position.y - bounds.position.y) / pitch))
		var j_to: int = int(ceil((tile.end.y - bounds.position.y) / pitch))

		for i: int in range(i_from, i_to + 1):
			for j: int in range(j_from, j_to + 1):
				var center := Vector2(
					bounds.position.x + float(i) * pitch + block_size * 0.5,
					bounds.position.y + float(j) * pitch + block_size * 0.5
				)
				if not tile.has_point(center) or not bounds.has_point(center):
					continue
				if CityAtlas.is_in_river(center):
					continue

				# Детерминированный шум по координатам квартала — без RNG,
				# чтобы силуэт был стабилен независимо от порядка сборки.
				var noise: float = _hash01(i * 73856093 + j * 19349663 + CityAtlas.city_seed)
				if noise > density + 0.15:
					continue

				var core_bias: float = clampf(1.0 - center.distance_to(district_center) / half_diag, 0.0, 1.0)
				core_bias = pow(core_bias, 1.6)
				var roll: float = pow(_hash01(i * 668265263 + j * 374761393), 2.1)
				var height: float = clampf(h_min + (h_max - h_min) * roll * (0.35 + 1.15 * core_bias), h_min, h_max)
				height = maxf(FLOOR_HEIGHT, round(height / FLOOR_HEIGHT) * FLOOR_HEIGHT)

				var tint: Color = Color.WHITE
				if not palette.is_empty():
					tint = palette[int(noise * float(palette.size())) % palette.size()]

				out.append({
					"center": Vector3(center.x, height * 0.5, center.y),
					# Квартал целиком, а не участок: вблизи это было бы грубо,
					# но силуэт виден только с 780 м и дальше.
					"size": Vector3(block_size * 0.92, height, block_size * 0.92),
					"tint": tint,
					# Светящихся окон намеренно больше, чем вблизи: с дистанции
					# они сливаются в тот самый неоновый ковёр.
					"custom": Color(noise, clampf(0.45 + wealth * 0.4, 0.3, 0.95), clampf(neon * 0.85, 0.0, 0.95), 0.0),
				})

	return out


static func _make_tile(blocks: Array[Dictionary], node_name: String) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = CityMaterials.box_mesh()
	mm.instance_count = blocks.size()

	for i: int in range(blocks.size()):
		var block: Dictionary = blocks[i]
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(block["size"]), block["center"]))
		mm.set_instance_color(i, block["tint"])
		mm.set_instance_custom_data(i, block["custom"])

	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	node.material_override = CityMaterials.facade_far
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Плитка проявляется только там, где настоящих чанков уже нет.
	node.visibility_range_begin = FADE_BEGIN
	node.visibility_range_begin_margin = FADE_MARGIN
	node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return node


## Детерминированный хеш в [0, 1) без RandomNumberGenerator.
static func _hash01(value: int) -> float:
	var h: int = value
	h = (h ^ (h >> 16)) * 0x7FEB352D
	h = (h ^ (h >> 15)) * 0x846CA68B
	h = h ^ (h >> 16)
	return float(absi(h) % 1000003) / 1000003.0
