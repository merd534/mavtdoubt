class_name NoirCityFarField
extends RefCounted
## Дальнее поле — грубый силуэт города за пределами кольца стриминга.
##
## Два слоя:
## 1. ВНУТРЕННИЙ (в границах игровой зоны) — по одному кубу на квартал,
##    согласован с реальной застройкой и проявляется только там, где чанков уже нет.
## 2. ВНЕШНИЙ (за границей игровой зоны) — фальшивый город-заглушка до
##    горизонта: никаких текстур и шейдеров фасада, только массы с плоским
##    материалом и тонкие светящиеся полосы на высотках. Игрок туда не
##    попадает, поэтому геометрия максимально дешёвая.
##
## Карта режется на «супер-плитки»; у каждой — свой MultiMesh, поэтому весь
## дальний город стоит несколько десятков вызовов отрисовки.

const TILE_SIZE := 960.0            ## сторона супер-плитки в метрах
const FADE_BEGIN := 780.0           ## с какой дистанции включается внутренний силуэт
const FADE_MARGIN := 220.0
const MIN_TILE_INSTANCES := 1
const FLOOR_HEIGHT := 3.4

## Внешнее кольцо-заглушка.
const OUTER_MARGIN := 3400.0        ## на сколько город уходит за границу карты
const OUTER_TILE := 1150.0
const OUTER_PITCH := 138.0          ## шаг фальшивых кварталов
const OUTER_FILL := 0.86            ## доля шага, занятая массой
const OUTER_H_MIN := 16.0
const OUTER_H_MAX := 78.0
const OUTER_TOWER_H := 210.0        ## высота кластерных высоток
const OUTER_STRIPES := 70           ## лимит светящихся полос на плитку

static var _flat: StandardMaterial3D = null
static var _glow: StandardMaterial3D = null


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

	var outer: int = _build_outer(root, bounds)

	Log.info("CityFarField", "Дальнее поле построено", {
		"плиток": root.get_child_count(),
		"силуэтов": total_instances,
		"заглушка": outer,
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


# --------------------------------------------------- внешнее кольцо-заглушка

## Плоский материал без текстур и без шейдера фасада: за границей игровой
## зоны важен только образ, а не поверхность.
static func flat_material() -> StandardMaterial3D:
	if _flat != null:
		return _flat
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.055, 0.065, 0.095)
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.vertex_color_use_as_albedo = false
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	_flat = mat
	return _flat


## Светящиеся полосы на высотках заглушки — единственное украшение внешнего
## кольца. Цвет идёт из instance color, текстур нет.
static func glow_material() -> StandardMaterial3D:
	if _glow != null:
		return _glow
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.02, 0.02, 0.03)
	mat.vertex_color_use_as_albedo = true
	mat.emission_enabled = true
	mat.emission = Color(1.0, 1.0, 1.0)
	mat.emission_energy_multiplier = 1.6
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_glow = mat
	return _glow


## Кольцо фальшивого города вокруг игровой зоны. Возвращает число масс.
static func _build_outer(root: Node3D, bounds: Rect2) -> int:
	var outer := Rect2(
		bounds.position - Vector2(OUTER_MARGIN, OUTER_MARGIN),
		bounds.size + Vector2(OUTER_MARGIN * 2.0, OUTER_MARGIN * 2.0)
	)
	var tiles_x: int = int(ceil(outer.size.x / OUTER_TILE))
	var tiles_y: int = int(ceil(outer.size.y / OUTER_TILE))
	var total: int = 0

	for tx: int in range(tiles_x):
		for ty: int in range(tiles_y):
			var tile := Rect2(
				Vector2(outer.position.x + float(tx) * OUTER_TILE, outer.position.y + float(ty) * OUTER_TILE),
				Vector2(OUTER_TILE, OUTER_TILE)
			)
			# Плитки целиком внутри игровой зоны строит не надо — там есть
			# реальные чанки и внутренние силуэтные плитки.
			if bounds.encloses(tile):
				continue

			var masses: Array[Dictionary] = _outer_blocks(tile, bounds)
			if masses.is_empty():
				continue

			var node := MultiMeshInstance3D.new()
			node.name = "FakeTile_%d_%d" % [tx, ty]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = CityMaterials.box_mesh()
			mm.instance_count = masses.size()
			for i: int in range(masses.size()):
				var block: Dictionary = masses[i]
				mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(block["size"]), block["center"]))
			node.multimesh = mm
			node.material_override = flat_material()
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(node)
			total += masses.size()

			var stripes: Array[Dictionary] = _outer_stripes(masses)
			if stripes.is_empty():
				continue
			var glow := MultiMeshInstance3D.new()
			glow.name = "FakeGlow_%d_%d" % [tx, ty]
			var gm := MultiMesh.new()
			gm.transform_format = MultiMesh.TRANSFORM_3D
			gm.use_colors = true
			gm.mesh = CityMaterials.box_mesh()
			gm.instance_count = stripes.size()
			for i: int in range(stripes.size()):
				var stripe: Dictionary = stripes[i]
				gm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(stripe["size"]), stripe["center"]))
				gm.set_instance_color(i, stripe["tint"])
			glow.multimesh = gm
			glow.material_override = glow_material()
			glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(glow)

	return total


## Фальшивые кварталы: ровная сетка с кластерами высоток и затуханием
## плотности к горизонту, чтобы город растворялся в тумане, а не обрывался
## стеной. Река продолжается и за границей: там ничего не строим.
static func _outer_blocks(tile: Rect2, bounds: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var i_from: int = int(floor(tile.position.x / OUTER_PITCH))
	var i_to: int = int(ceil(tile.end.x / OUTER_PITCH))
	var j_from: int = int(floor(tile.position.y / OUTER_PITCH))
	var j_to: int = int(ceil(tile.end.y / OUTER_PITCH))
	var seed_value: int = CityAtlas.city_seed

	for i: int in range(i_from, i_to + 1):
		for j: int in range(j_from, j_to + 1):
			var center := Vector2(float(i) * OUTER_PITCH, float(j) * OUTER_PITCH)
			if not tile.has_point(center):
				continue
			# Внутри игровой зоны заглушки быть не должно.
			if bounds.has_point(center):
				continue
			if CityAtlas.is_in_river(center):
				continue

			# Расстояние наружу от границы карты.
			var dx: float = maxf(maxf(bounds.position.x - center.x, center.x - bounds.end.x), 0.0)
			var dz: float = maxf(maxf(bounds.position.y - center.y, center.y - bounds.end.y), 0.0)
			var away: float = clampf(maxf(dx, dz) / OUTER_MARGIN, 0.0, 1.0)
			var fill: float = 0.95 - 0.75 * away

			var noise: float = _hash01(i * 92837111 + j * 689287499 + seed_value)
			if noise > fill:
				continue

			# Кластеры высоток: редкие острова башен, чтобы горизонт имел ритм.
			var cluster: float = _hash01(int(floor(center.x / 620.0)) * 15485863 + int(floor(center.y / 620.0)) * 32452843 + seed_value)
			var tower_bias: float = clampf((cluster - 0.72) / 0.28, 0.0, 1.0) * (1.0 - away * 0.7)
			var roll: float = pow(_hash01(i * 2654435761 + j * 40503 + seed_value), 1.9)
			var height: float = lerpf(OUTER_H_MIN, OUTER_H_MAX, roll)
			if tower_bias > 0.0 and roll > 0.55:
				height = lerpf(height, OUTER_TOWER_H * (0.55 + 0.45 * roll), tower_bias)
			height *= 1.0 - away * 0.45
			height = maxf(8.0, height)

			var side: float = OUTER_PITCH * OUTER_FILL * (0.72 + 0.28 * _hash01(i * 19349663 + j * 83492791))
			out.append({
				"center": Vector3(center.x, height * 0.5, center.y),
				"size": Vector3(side, height, side * (0.8 + 0.4 * _hash01(i * 374761393 + j * 668265263))),
				"height": height,
				"tower": tower_bias > 0.0 and height > 90.0,
			})

	return out


## Тонкие вертикальные полосы по граням высоток и красные маячки на шпилях.
static func _outer_stripes(masses: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var cold := Color(0.32, 0.78, 1.0)
	var warm := Color(1.0, 0.68, 0.32)
	var beacon := Color(1.0, 0.2, 0.2)

	for block: Dictionary in masses:
		if out.size() >= OUTER_STRIPES:
			break
		var height: float = float(block["height"])
		if height < 46.0:
			continue
		var center: Vector3 = block["center"]
		var box_size: Vector3 = block["size"]
		var pick: float = _hash01(int(center.x) * 73856093 + int(center.z) * 19349663)
		var tint: Color = cold if pick < 0.55 else warm

		# Две полосы на противоположных гранях — силуэт читается с любого ракурса.
		for k: float in [-1.0, 1.0]:
			out.append({
				"center": Vector3(center.x, height * 0.52, center.z + k * box_size.z * 0.51),
				"size": Vector3(box_size.x * 0.16, height * 0.74, 0.5),
				"tint": tint,
			})

		if bool(block.get("tower", false)):
			out.append({
				"center": Vector3(center.x, height + 1.6, center.z),
				"size": Vector3(1.6, 1.6, 1.6),
				"tint": beacon,
			})

	return out


## Детерминированный хеш в [0, 1) без RandomNumberGenerator.
static func _hash01(value: int) -> float:
	var h: int = value
	h = (h ^ (h >> 16)) * 0x7FEB352D
	h = (h ^ (h >> 15)) * 0x846CA68B
	h = h ^ (h >> 16)
	return float(absi(h) % 1000003) / 1000003.0
