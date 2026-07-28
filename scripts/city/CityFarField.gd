class_name NoirCityFarField
extends RefCounted
## Дальнее поле — грубый силуэт города за пределами кольца стриминга.
##
## Два слоя:
## 1. ВНУТРЕННИЙ (в границах игровой зоны) — по одному кубу на квартал,
##    согласован с реальной застройкой и проявляется только там, где чанков уже нет.
## 2. ВНЕШНИЙ (за границей игровой зоны) — фальшивый город-заглушка до
##    горизонта: никаких текстур, шейдеров фасада, теней и коллизий —
##    только MultiMesh с плоским материалом и светящимися элементами.
##
## Внешнее кольцо разделено на три пояса, чтобы город не обрывался стеной:
##   • продолжение застройки вплотную за границей — плотно, с уступами;
##   • псевдо-окраины — зданий значительно меньше, они низкие и широкие;
##   • горизонт — редкие острова башен, уходящие в туман.
##
## ПОЧЕМУ ЗДЕСЬ БЫЛИ «ФАНТОМНЫЕ ОКНА». Две причины, обе закрыты:
##   1. внутренний силуэт включался на фиксированных 780 метрах, а стриминг
##      при высоких пресетах грузит чанки на 1500-1900. Грубые кубы кварталов
##      проступали поверх настоящих домов и висели окнами в воздухе там,
##      где реальной застройки в квартале не оказалось. Теперь дистанция
##      задаётся снаружи (см. [method build] и [method set_fade_begin]) и всегда
##      больше фактического радиуса чанков;
##   2. светящиеся ленты заглушки были ярче самих коробок и торчали над
##      гранью. Ночью тёмный корпус сливался с небом, а лента оставалась —
##      ровно эффект «окно без здания». Теперь ленты утоплены в грань,
##      слабее по энергии и гаснут по дистанции раньше, чем корпус.

const TILE_SIZE := 960.0            ## сторона супер-плитки в метрах
const FADE_BEGIN := 1400.0          ## запасная дистанция, если снаружи ничего не задали
const FADE_MARGIN := 260.0
const MIN_TILE_INSTANCES := 1
const FLOOR_HEIGHT := 3.4

## Внешнее кольцо-заглушка.
const OUTER_MARGIN := 4200.0        ## на сколько город уходит за границу карты
const OUTER_TILE := 1150.0
const OUTER_PITCH := 132.0          ## шаг фальшивых кварталов
const OUTER_FILL := 0.86            ## доля шага, занятая массой
const OUTER_H_MIN := 14.0
const OUTER_H_MAX := 82.0
const OUTER_TOWER_H := 235.0        ## высота кластерных высоток
const OUTER_MAX_PARTS := 1600       ## лимит масс на плитку
const OUTER_STRIPES := 220          ## лимит светящихся элементов на плитку
## Ленты гаснут раньше корпусов: иначе на пределе видимости остаются
## светящиеся полоски без зданий.
const GLOW_VISIBLE_TO := 2600.0

## Границы поясов в долях OUTER_MARGIN.
const BELT_CITY := 0.22             ## до этого — продолжение города
const BELT_SUBURB := 0.62           ## до этого — псевдо-окраины

static var _flat: StandardMaterial3D = null
static var _glow: StandardMaterial3D = null


## [param fade_begin] — с какой дистанции проявляется внутренний силуэт.
## Генератор передаёт сюда реальный радиус стриминга плюс запас.
static func build(fade_begin: float = FADE_BEGIN) -> Node3D:
	var root := Node3D.new()
	root.name = "FarField"

	var begin: float = maxf(320.0, fade_begin)
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

			var node: MultiMeshInstance3D = _make_tile(blocks, "FarTile_%d_%d" % [tx, ty], begin)
			root.add_child(node)
			total_instances += blocks.size()

	var outer: int = _build_outer(root, bounds)

	Log.info("CityFarField", "Дальнее поле построено", {
		"плиток": root.get_child_count(),
		"силуэтов": total_instances,
		"заглушка": outer,
		"силуэт_с_м": int(begin),
		"мс": int((Time.get_ticks_usec() - started) / 1000),
	})
	return root


## Меняет дистанцию появления внутреннего силуэта на лету. Вызывается
## при смене графического пресета: радиус стриминга там меняется в разы.
static func set_fade_begin(root: Node3D, fade_begin: float) -> void:
	if root == null or not is_instance_valid(root):
		return
	var begin: float = maxf(320.0, fade_begin)
	for child: Node in root.get_children():
		if not (child is MultiMeshInstance3D):
			continue
		if not child.name.begins_with("FarTile_"):
			continue
		var node: MultiMeshInstance3D = child as MultiMeshInstance3D
		node.visibility_range_begin = begin
		node.visibility_range_begin_margin = FADE_MARGIN


## Один куб на квартал: та же сетка, что у настоящей застройки, но без
## дробления на участки.
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
					"size": Vector3(block_size * 0.92, height, block_size * 0.92),
					"tint": tint,
					"custom": Color(noise, clampf(0.45 + wealth * 0.4, 0.3, 0.95), clampf(neon * 0.85, 0.0, 0.95), 0.0),
				})

	return out


static func _make_tile(blocks: Array[Dictionary], node_name: String, fade_begin: float) -> MultiMeshInstance3D:
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
	node.visibility_range_begin = fade_begin
	node.visibility_range_begin_margin = FADE_MARGIN
	node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return node


# --------------------------------------------------- внешнее кольцо-заглушка

## Плоский материал без текстур. Цвет берётся из instance color, чтобы
## пояса различались по тону, но оставались одним материалом.
static func flat_material() -> StandardMaterial3D:
	if _flat != null:
		return _flat
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.vertex_color_use_as_albedo = true
	# Заглушка не освещается сценой: ночью направленного света почти нет,
	# и корпуса уходили в чистый чёрный, оставляя на виду одни ленты.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	_flat = mat
	return _flat


## Светящиеся элементы заглушки: полосы, оконные ленты, маячки.
static func glow_material() -> StandardMaterial3D:
	if _glow != null:
		return _glow
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.02, 0.02, 0.03)
	mat.vertex_color_use_as_albedo = true
	mat.emission_enabled = true
	mat.emission = Color(1.0, 1.0, 1.0)
	# Было 1.6 — ленты пересвечивали корпуса и читались отдельно от них.
	mat.emission_energy_multiplier = 0.85
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_glow = mat
	return _glow


## Кольцо фальшивого города вокруг игровой зоны. Возвращает число масс.
## Ни одного физического тела здесь не создаётся сознательно.
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
			if bounds.encloses(tile):
				continue

			var masses: Array[Dictionary] = _outer_blocks(tile, bounds)
			if masses.is_empty():
				continue

			var node := MultiMeshInstance3D.new()
			node.name = "FakeTile_%d_%d" % [tx, ty]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = CityMaterials.box_mesh()
			mm.instance_count = masses.size()
			for i: int in range(masses.size()):
				var block: Dictionary = masses[i]
				mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(block["size"]), block["center"]))
				mm.set_instance_color(i, block["tint"])
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
			# Гаснут раньше корпусов — «окон без зданий» на горизонте больше нет.
			glow.visibility_range_end = GLOW_VISIBLE_TO
			glow.visibility_range_end_margin = GLOW_VISIBLE_TO * 0.2
			glow.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			root.add_child(glow)

	return total


## Фальшивые кварталы. Каждое здание — не один куб, а набор масс:
## основной объём, уступ, надстройка на крыше и антенна. Поэтому силуэт
## читается как город, а не как ряд коробок.
static func _outer_blocks(tile: Rect2, bounds: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var i_from: int = int(floor(tile.position.x / OUTER_PITCH))
	var i_to: int = int(ceil(tile.end.x / OUTER_PITCH))
	var j_from: int = int(floor(tile.position.y / OUTER_PITCH))
	var j_to: int = int(ceil(tile.end.y / OUTER_PITCH))
	var seed_value: int = CityAtlas.city_seed

	# Оттенки поясов. Подняты: раньше корпуса были темнее ночного неба и
	# визуально исчезали, оставляя висеть в воздухе одни светящиеся ленты.
	var near_tone := Color(0.168, 0.183, 0.226)
	var far_tone := Color(0.098, 0.110, 0.150)

	for i: int in range(i_from, i_to + 1):
		for j: int in range(j_from, j_to + 1):
			if out.size() >= OUTER_MAX_PARTS:
				return out

			var center := Vector2(float(i) * OUTER_PITCH, float(j) * OUTER_PITCH)
			if not tile.has_point(center):
				continue
			if bounds.has_point(center):
				continue
			if CityAtlas.is_in_river(center):
				continue

			# Расстояние наружу от границы карты в долях кольца.
			var dx: float = maxf(maxf(bounds.position.x - center.x, center.x - bounds.end.x), 0.0)
			var dz: float = maxf(maxf(bounds.position.y - center.y, center.y - bounds.end.y), 0.0)
			var away: float = clampf(maxf(dx, dz) / OUTER_MARGIN, 0.0, 1.0)

			# Три пояса с разной плотностью и этажностью.
			var fill: float = 0.0
			var h_lo: float = OUTER_H_MIN
			var h_hi: float = OUTER_H_MAX
			var wide: float = 1.0
			if away < BELT_CITY:
				# Продолжение города: плотно и высоко.
				fill = 0.92
				h_lo = 22.0
				h_hi = OUTER_H_MAX
			elif away < BELT_SUBURB:
				# Псевдо-окраины: зданий значительно меньше, они низкие,
				# широкие и расставлены редко — промзона и малоэтажка.
				var t: float = (away - BELT_CITY) / maxf(0.01, BELT_SUBURB - BELT_CITY)
				fill = lerpf(0.46, 0.2, t)
				h_lo = 8.0
				h_hi = lerpf(34.0, 20.0, t)
				wide = 1.35
			else:
				# Горизонт: только редкие острова застройки.
				fill = 0.14
				h_lo = 10.0
				h_hi = 46.0
				wide = 1.2

			var noise: float = _hash01(i * 92837111 + j * 689287499 + seed_value)
			if noise > fill:
				continue

			# Кластеры высоток: острова башен, чтобы горизонт имел ритм.
			var cluster: float = _hash01(int(floor(center.x / 640.0)) * 15485863 + int(floor(center.y / 640.0)) * 32452843 + seed_value)
			var tower_bias: float = clampf((cluster - 0.74) / 0.26, 0.0, 1.0) * (1.0 - away * 0.55)
			var roll: float = pow(_hash01(i * 2654435761 + j * 40503 + seed_value), 1.9)
			var height: float = lerpf(h_lo, h_hi, roll)
			if tower_bias > 0.0 and roll > 0.5 and away < BELT_SUBURB:
				height = lerpf(height, OUTER_TOWER_H * (0.45 + 0.55 * roll), tower_bias)
			height = maxf(7.0, height * (1.0 - away * 0.3))

			var shape: float = _hash01(i * 19349663 + j * 83492791)
			var side_x: float = OUTER_PITCH * OUTER_FILL * wide * (0.6 + 0.34 * shape)
			var side_z: float = side_x * (0.72 + 0.5 * _hash01(i * 374761393 + j * 668265263))
			var tone: Color = near_tone.lerp(far_tone, away)
			# Микроразнобой тона: даже без текстур застройка не читается заливкой.
			tone = tone * (0.85 + 0.34 * shape)
			var is_tower: bool = height > 95.0

			out.append({
				"center": Vector3(center.x, height * 0.5, center.y),
				"size": Vector3(side_x, height, side_z),
				"height": height,
				"tint": tone,
				"tower": is_tower,
				"away": away,
				"shape": shape,
			})

			# Уступ: верхний ярус уже основного объёма.
			if height > 34.0 and shape > 0.32:
				var setback_h: float = height * (0.2 + 0.28 * shape)
				out.append({
					"center": Vector3(center.x, height + setback_h * 0.5, center.y),
					"size": Vector3(side_x * 0.62, setback_h, side_z * 0.62),
					"height": height + setback_h,
					"tint": tone * 1.08,
					"tower": false,
					"away": away,
					"shape": shape,
				})

			# Надстройка на крыше: машинное отделение или бак.
			if shape < 0.55 and height > 16.0:
				var cap: float = clampf(height * 0.08, 1.6, 6.0)
				out.append({
					"center": Vector3(center.x + side_x * 0.16, height + cap * 0.5, center.y - side_z * 0.14),
					"size": Vector3(side_x * 0.34, cap, side_z * 0.32),
					"height": height + cap,
					"tint": tone * 0.86,
					"tower": false,
					"away": away,
					"shape": shape,
				})

			# Антенна на высотках — тонкий штырь, добивающий силуэт.
			if is_tower:
				var mast: float = height * 0.16
				out.append({
					"center": Vector3(center.x, height + mast * 0.5, center.y),
					"size": Vector3(0.9, mast, 0.9),
					"height": height + mast,
					"tint": tone * 0.7,
					"tower": false,
					"away": away,
					"shape": shape,
				})

	return out


## Светящиеся элементы: оконные ленты на ближних домах, вертикальные
## полосы на высотках и красные маячки на шпилях.
##
## Все ленты утоплены в грань (0.49 полуразмера, а не 0.51): торчащая наружу
## полоска на дальней дистанции отрывалась от корпуса и висела в воздухе.
static func _outer_stripes(masses: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var cold := Color(0.30, 0.72, 1.0)
	var warm := Color(1.0, 0.66, 0.32)
	var window_tone := Color(1.0, 0.80, 0.48)
	var beacon := Color(1.0, 0.2, 0.2)

	for block: Dictionary in masses:
		if out.size() >= OUTER_STRIPES:
			break
		var height: float = float(block["height"])
		var center: Vector3 = block["center"]
		var box_size: Vector3 = block["size"]
		var away: float = float(block.get("away", 0.0))
		var shape: float = float(block.get("shape", 0.5))

		# Оконные ленты: две-три горизонтальные светящиеся полоски на фасаде.
		# Дальние пояса их не получают: там важен только силуэт.
		if away < BELT_SUBURB and box_size.y > 12.0 and shape > 0.28:
			var rows: int = 2 if box_size.y < 40.0 else 3
			for r: int in range(rows):
				var t: float = (float(r) + 1.0) / (float(rows) + 1.0)
				out.append({
					"center": Vector3(center.x, center.y - box_size.y * 0.5 + box_size.y * t, center.z + box_size.z * 0.49),
					"size": Vector3(box_size.x * 0.74, 0.5, 0.12),
					"tint": window_tone * (0.45 + 0.4 * shape),
				})

		if height < 46.0:
			continue

		var pick: float = _hash01(int(center.x) * 73856093 + int(center.z) * 19349663)
		var tint: Color = cold if pick < 0.55 else warm

		# Две полосы на противоположных гранях — силуэт читается с любого ракурса.
		for k: float in [-1.0, 1.0]:
			out.append({
				"center": Vector3(center.x, center.y, center.z + k * box_size.z * 0.49),
				"size": Vector3(box_size.x * 0.12, box_size.y * 0.8, 0.16),
				"tint": tint,
			})

		if bool(block.get("tower", false)):
			out.append({
				"center": Vector3(center.x, height + 1.4, center.z),
				"size": Vector3(1.5, 1.5, 1.5),
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
