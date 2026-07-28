class_name NoirCityChunk
extends Node3D
## Один чанк города. Превращает данные фабрик в узлы сцены.
##
## Всё однотипное сливается в MultiMesh, поэтому число вызовов отрисовки на чанк
## почти не зависит от количества зданий и деталей.
##
## Уровни детализации:
##   0 — вблизи: архитектурная детализация, подворотни, улицы, тротуары, частицы,
##       зоны лазания, коллизии, настоящий свет, входы
##   1 — средне: здания, крупные объёмы, силуэт башен, вывески, тротуары, разметка
##   2 — далеко: только здания и полотно дорог
##
## Проходимые дома (флаг `enterable` от BuildingFactory) получают в физике не
## монолитный куб, а оболочку из стен с дверным проёмом — именно поэтому внутрь
## можно войти пешком, а не по скрипту.

const DETAIL_NEAR := 0
const DETAIL_MID := 1
const DETAIL_FAR := 2

const MAX_REAL_LIGHTS := 6
const MAX_DETAIL_LIGHTS := 8
const MAX_STREET_LIGHTS := 3
const MAX_TOWER_LIGHTS := 2
const MAX_WALK_LIGHTS := 2
const MAX_PARTICLE_SYSTEMS := 10
const MAX_CLIMB_ZONES := 12
const PROP_VISIBLE_TO := 240.0
const LAMP_POST_VISIBLE_TO := 420.0
const TRIM_VISIBLE_TO := 190.0
const SMALL_DETAIL_VISIBLE_TO := 120.0
const STREET_VISIBLE_TO := 210.0
const STREET_SMALL_VISIBLE_TO := 130.0
const TOWER_SMALL_VISIBLE_TO := 520.0
const MASS_SMALL_VISIBLE_TO := 330.0
const SIDEWALK_VISIBLE_TO := 430.0
const PAINT_VISIBLE_TO := 270.0
const WALK_PROP_VISIBLE_TO := 155.0

## Толщина стены в коллизии-оболочке проходимого дома.
const SHELL_THICKNESS := 0.5

## Порог «крупного» объёма: мелочь тени не отбрасывает — на экране она занимает
## доли пикселя, а в проход теней уходит полноценный инстанс.
const MASS_SHADOW_MIN_HEIGHT := 3.5
const MASS_SHADOW_MIN_SIDE := 1.6

static var _paint_material: StandardMaterial3D = null

var coords: Vector2i = Vector2i.ZERO
var rect: Rect2 = Rect2()
var detail_level: int = DETAIL_FAR

var _content: Dictionary = {}
var _built: bool = false
var _hidden: bool = false
var _build_msec: int = 0
var _city_seed: int = 0
var _detail_stats: Dictionary = {}

var _buildings_mm: MultiMeshInstance3D = null
var _signs_mm: MultiMeshInstance3D = null
var _props_mm: MultiMeshInstance3D = null
var _posts_mm: MultiMeshInstance3D = null
var _heads_mm: MultiMeshInstance3D = null
var _roads_mesh: MeshInstance3D = null
var _arterial_mesh: MeshInstance3D = null
var _occluder: OccluderInstance3D = null
var _body: StaticBody3D = null
var _lights: Array[OmniLight3D] = []

var _detail_nodes: Array[MultiMeshInstance3D] = []
var _detail_lights: Array[OmniLight3D] = []
var _tower_lights: Array[OmniLight3D] = []
var _walk_lights: Array[OmniLight3D] = []
var _particles: Array[GPUParticles3D] = []
var _climb_areas: Array[NoirClimbArea] = []
var _detail_boxes: Array[Dictionary] = []
var _detail_occluders: Array[Dictionary] = []
var _enterable_count: int = 0


static func create(chunk_coords: Vector2i, chunk_rect: Rect2, detail: int) -> NoirCityChunk:
	var chunk := NoirCityChunk.new()
	chunk.coords = chunk_coords
	chunk.rect = chunk_rect
	chunk.detail_level = clampi(detail, DETAIL_NEAR, DETAIL_FAR)
	chunk.name = "Chunk_%d_%d" % [chunk_coords.x, chunk_coords.y]
	chunk.position = Vector3.ZERO
	return chunk


## Материал дорожной краски создаётся один раз на всю игру.
static func paint_material() -> StandardMaterial3D:
	if _paint_material != null:
		return _paint_material
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.56, 0.54, 0.48)
	mat.roughness = 0.78
	mat.metallic = 0.0
	mat.metallic_specular = 0.35
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	_paint_material = mat
	return _paint_material


## Строит содержимое. Возвращает время сборки в миллисекундах.
func build(city_seed: int) -> int:
	var started: int = Time.get_ticks_usec()
	_city_seed = city_seed

	_content = NoirBuildingFactory.generate(rect, city_seed, detail_level)

	_build_buildings()
	_build_roads()
	_build_signs()
	_build_lamps()
	_build_details()
	_build_sidewalks()
	if detail_level == DETAIL_NEAR:
		_build_streets()
		_build_props()
		_build_collision()
		_build_lights()
	_build_occluder()

	_built = true
	_build_msec = int((Time.get_ticks_usec() - started) / 1000)
	return _build_msec


func set_detail(level: int, city_seed: int) -> bool:
	var target: int = clampi(level, DETAIL_NEAR, DETAIL_FAR)
	if target == detail_level:
		return false
	detail_level = target
	_clear_nodes()
	build(city_seed)
	if _hidden:
		_apply_hidden(true)
	return true


func is_built() -> bool:
	return _built


func is_hidden_chunk() -> bool:
	return _hidden


## Полное скрытие чанка без разборки геометрии.
func set_hidden(hide_chunk: bool) -> void:
	if _hidden == hide_chunk:
		return
	_hidden = hide_chunk
	_apply_hidden(hide_chunk)


func _apply_hidden(hide_chunk: bool) -> void:
	visible = not hide_chunk

	for emitter: GPUParticles3D in _particles:
		if is_instance_valid(emitter):
			emitter.emitting = not hide_chunk
			emitter.visible = not hide_chunk

	for light: OmniLight3D in _lights:
		if is_instance_valid(light):
			light.visible = not hide_chunk
	for light: OmniLight3D in _detail_lights:
		if is_instance_valid(light):
			light.visible = not hide_chunk
	for light: OmniLight3D in _tower_lights:
		if is_instance_valid(light):
			light.visible = not hide_chunk
	for light: OmniLight3D in _walk_lights:
		if is_instance_valid(light):
			light.visible = not hide_chunk

	if _body != null and is_instance_valid(_body):
		_body.collision_layer = 0 if hide_chunk else 1
	for area: NoirClimbArea in _climb_areas:
		if is_instance_valid(area):
			area.monitoring = not hide_chunk

	if _occluder != null and is_instance_valid(_occluder):
		_occluder.visible = not hide_chunk

	Log.trace("CityChunk", "Смена видимости чанка", {"чанк": str(coords), "скрыт": hide_chunk})


func entrances() -> Array:
	var raw: Variant = _content.get("entrances", null)
	return raw as Array if raw is Array else []


func building_count() -> int:
	var raw: Variant = _content.get("buildings", null)
	return (raw as Array).size() if raw is Array else 0


func climb_zones() -> Array[NoirClimbArea]:
	return _climb_areas.duplicate()


func stats() -> Dictionary:
	var out: Dictionary = {
		"coords": coords,
		"detail": detail_level,
		"hidden": _hidden,
		"build_ms": _build_msec,
		"buildings": building_count(),
		"enterable": _enterable_count,
		"signs": _count("signs"),
		"props": _count("props"),
		"lamps": _count("lamps"),
		"lights": _lights.size() + _detail_lights.size() + _tower_lights.size() + _walk_lights.size(),
		"particles": _particles.size(),
		"climb_zones": _climb_areas.size(),
		"occluders": _count("occluders") + _detail_occluders.size(),
	}
	for key: Variant in _detail_stats.keys():
		out[str(key)] = _detail_stats[key]
	return out


func dispose() -> void:
	_clear_nodes()
	_content.clear()
	_detail_stats.clear()
	_built = false
	queue_free()


func _count(key: String) -> int:
	var raw: Variant = _content.get(key, null)
	return (raw as Array).size() if raw is Array else 0


func _clear_nodes() -> void:
	for area: NoirClimbArea in _climb_areas:
		if is_instance_valid(area):
			area.monitoring = false
	for emitter: GPUParticles3D in _particles:
		if is_instance_valid(emitter):
			emitter.emitting = false

	for child: Node in get_children():
		child.queue_free()

	_buildings_mm = null
	_signs_mm = null
	_props_mm = null
	_posts_mm = null
	_heads_mm = null
	_roads_mesh = null
	_arterial_mesh = null
	_occluder = null
	_body = null
	_lights.clear()
	_detail_nodes.clear()
	_detail_lights.clear()
	_tower_lights.clear()
	_walk_lights.clear()
	_particles.clear()
	_climb_areas.clear()
	_detail_boxes.clear()
	_detail_occluders.clear()
	_enterable_count = 0


# ---------------------------------------------------------------- здания

func _build_buildings() -> void:
	var buildings: Array = _content.get("buildings", [])
	if buildings.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = CityMaterials.box_mesh()
	mm.instance_count = buildings.size()

	for i: int in range(buildings.size()):
		var b: Dictionary = buildings[i]
		var box_size: Vector3 = b["size"]
		var center: Vector3 = b["center"]
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(box_size), center))
		mm.set_instance_color(i, b["tint"])
		mm.set_instance_custom_data(i, b["custom"])

	_buildings_mm = MultiMeshInstance3D.new()
	_buildings_mm.name = "Buildings"
	_buildings_mm.multimesh = mm
	_buildings_mm.material_override = CityMaterials.facade
	_buildings_mm.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if detail_level <= DETAIL_MID
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	add_child(_buildings_mm)


# =========================================================== детали зданий

func _detail_budget() -> Dictionary:
	var cfg: Dictionary = NoirBuildingDetailer.budget_defaults()
	cfg["level"] = detail_level

	var graphics: Dictionary = GameConfig.section("graphics")
	if not graphics.is_empty():
		cfg["density"] = clampf(float(graphics.get("detail_density", cfg["density"])), 0.0, 1.0)
		cfg["cables"] = bool(graphics.get("cables", cfg["cables"]))
		cfg["steam"] = bool(graphics.get("steam", cfg["steam"]))
		cfg["debris"] = bool(graphics.get("debris", cfg["debris"]))
		cfg["drips"] = bool(graphics.get("steam", cfg["drips"]))
		cfg["billboard_lights"] = maxi(0, int(graphics.get("billboard_lights", cfg["billboard_lights"])))

	var density: float = float(cfg["density"])
	cfg["niches"] = density > 0.25
	cfg["holograms"] = density > 0.15
	cfg["max_elements"] = maxi(24, int(round(float(NoirBuildingDetailer.MAX_ELEMENTS) * clampf(0.3 + density, 0.3, 1.0))))

	# Мелочь фасада отсекается на 120-190 м, а средний чанк начинается в 240 м:
	# генерировать её там — чистая потеря памяти без единого видимого пикселя.
	if detail_level != DETAIL_NEAR:
		cfg["cables"] = false
		cfg["steam"] = false
		cfg["debris"] = false
		cfg["drips"] = false
		cfg["niches"] = false
		cfg["max_elements"] = maxi(16, int(round(float(cfg["max_elements"]) * 0.4)))

	return cfg


## Конфиг объёмной детализации небоскрёбов. Силуэт башни нужен даже на слабых
## машинах, поэтому минимум остаётся заметным.
func _tower_config() -> Dictionary:
	var cfg: Dictionary = NoirTowerDetailer.defaults()
	var graphics: Dictionary = GameConfig.section("graphics")
	var density: float = 1.0
	if not graphics.is_empty():
		density = clampf(float(graphics.get("detail_density", 1.0)), 0.0, 1.5)
	cfg["density"] = clampf(density, 0.0, 1.5)

	if detail_level != DETAIL_NEAR:
		cfg["roof_gear"] = density >= 0.8
		cfg["fins"] = density >= 0.55
		cfg["neon"] = density >= 0.35

	if density < 0.35:
		cfg["fins"] = false
		cfg["roof_gear"] = false

	cfg["max_parts"] = maxi(40, int(round(float(NoirTowerDetailer.MAX_PARTS) * clampf(0.35 + density * 0.65, 0.35, 1.0))))
	return cfg


func _build_details() -> void:
	var buildings: Array = _content.get("buildings", [])
	if buildings.is_empty() or detail_level >= DETAIL_FAR:
		return

	var near: bool = detail_level == DETAIL_NEAR
	var budget: Dictionary = _detail_budget()
	var tower_cfg: Dictionary = _tower_config()
	if float(budget.get("density", 0.0)) <= 0.01:
		return

	var masses: Array[Transform3D] = []
	var mass_colors: Array[Color] = []
	var mass_customs: Array[Color] = []
	var small_masses: Array[Transform3D] = []
	var small_colors: Array[Color] = []
	var small_customs: Array[Color] = []
	var trims: Array[Transform3D] = []
	var niches: Array[Transform3D] = []
	var niche_colors: Array[Color] = []
	var niche_customs: Array[Color] = []
	var fixtures: Array[Transform3D] = []
	var pipes: Array[Transform3D] = []
	var cables: Array[Transform3D] = []
	var ladders: Array[Transform3D] = []
	var billboards: Array[Transform3D] = []
	var billboard_colors: Array[Color] = []
	var billboard_customs: Array[Color] = []
	var holograms: Array[Transform3D] = []
	var holo_colors: Array[Color] = []
	var holo_customs: Array[Color] = []
	var drips: Array[Vector3] = []
	var lights: Array[Dictionary] = []
	var climb: Array[Dictionary] = []

	var tower_concrete: Array[Transform3D] = []
	var tower_metal: Array[Transform3D] = []
	var tower_glass: Array[Transform3D] = []
	var tower_poles: Array[Transform3D] = []
	var tower_neon: Array[Transform3D] = []
	var tower_neon_colors: Array[Color] = []
	var tower_neon_customs: Array[Color] = []
	var tower_lights: Array[Dictionary] = []
	var tower_parts: int = 0
	var towers: int = 0

	for entry: Variant in buildings:
		if not (entry is Dictionary):
			continue
		var b: Dictionary = entry as Dictionary
		var district: Variant = CityAtlas.get_district(str(b.get("district", "")))
		var result: Dictionary = NoirBuildingDetailer.detail(b, district, budget)
		if not result.is_empty():
			for item: Variant in result.get("masses", []) as Array:
				var mass: Dictionary = item as Dictionary
				var xf: Transform3D = mass["transform"]
				if _is_big_mass(xf):
					masses.append(xf)
					mass_colors.append(mass["tint"])
					mass_customs.append(mass["custom"])
				else:
					small_masses.append(xf)
					small_colors.append(mass["tint"])
					small_customs.append(mass["custom"])
				if near:
					_detail_boxes.append({"transform": xf})

			_detail_occluders.append_array(result.get("occluders", []) as Array)

			if near:
				trims.append_array(result.get("trims", []) as Array)
				fixtures.append_array(result.get("fixtures", []) as Array)
				pipes.append_array(result.get("pipes", []) as Array)
				cables.append_array(result.get("cables", []) as Array)
				ladders.append_array(result.get("ladders", []) as Array)
				drips.append_array(result.get("drips", []) as Array)

				for item: Variant in result.get("niches", []) as Array:
					var niche: Dictionary = item as Dictionary
					niches.append(niche["transform"])
					niche_colors.append(niche["tint"])
					niche_customs.append(niche["custom"])

			for item: Variant in result.get("billboards", []) as Array:
				var sign_data: Dictionary = item as Dictionary
				billboards.append(sign_data["transform"])
				billboard_colors.append(sign_data["tint"])
				billboard_customs.append(sign_data["custom"])

			for item: Variant in result.get("holograms", []) as Array:
				var holo: Dictionary = item as Dictionary
				holograms.append(holo["transform"])
				holo_colors.append(holo["tint"])
				holo_customs.append(holo["custom"])

			if lights.size() < MAX_DETAIL_LIGHTS:
				lights.append_array(result.get("lights", []) as Array)
			if near and climb.size() < MAX_CLIMB_ZONES:
				climb.append_array(result.get("climb_zones", []) as Array)

		if not NoirTowerDetailer.is_tower(b):
			continue
		var tower: Dictionary = NoirTowerDetailer.detail(b, tower_cfg)
		if tower.is_empty():
			continue
		towers += 1
		tower_parts += NoirTowerDetailer.count(tower)

		for item: Variant in tower.get("masses", []) as Array:
			var tower_mass: Dictionary = item as Dictionary
			masses.append(tower_mass["transform"])
			mass_colors.append(tower_mass.get("tint", b.get("tint", Color.WHITE)))
			mass_customs.append(tower_mass.get("custom", b.get("custom", Color(0.0, 0.5, 0.0, 0.0))))

		tower_concrete.append_array(tower.get("concrete", []) as Array)
		tower_metal.append_array(tower.get("metal", []) as Array)
		tower_glass.append_array(tower.get("glass", []) as Array)
		tower_poles.append_array(tower.get("poles", []) as Array)
		_detail_occluders.append_array(tower.get("occluders", []) as Array)

		for item: Variant in tower.get("neon", []) as Array:
			var strip: Dictionary = item as Dictionary
			tower_neon.append(strip["transform"])
			tower_neon_colors.append(strip.get("tint", Color.WHITE))
			tower_neon_customs.append(strip.get("custom", Color(0.0, 0.9, 0.0, 0.0)))

		if near:
			for xform: Transform3D in tower.get("boxes", []) as Array:
				_detail_boxes.append({"transform": xform})
		if tower_lights.size() < MAX_TOWER_LIGHTS * 4:
			tower_lights.append_array(tower.get("lights", []) as Array)

	var alley: Dictionary = {}
	if near:
		alley = NoirAlleyDresser.generate(buildings, _city_seed, budget)

	_emit_detail_meshes(
		masses, mass_colors, mass_customs,
		small_masses, small_colors, small_customs,
		trims, niches, niche_colors, niche_customs,
		fixtures, pipes, cables, ladders,
		billboards, billboard_colors, billboard_customs,
		holograms, holo_colors, holo_customs
	)
	_emit_tower_meshes(
		tower_concrete, tower_metal, tower_glass, tower_poles,
		tower_neon, tower_neon_colors, tower_neon_customs
	)
	_emit_tower_lights(tower_lights)
	_emit_alley(alley)
	_emit_detail_lights(lights, alley)
	if near:
		_emit_particles(drips, alley, float(budget.get("density", 0.7)))
		_emit_climb_zones(climb)

	_detail_stats = {
		"detail_masses": masses.size() + small_masses.size(),
		"detail_shadow_masses": masses.size(),
		"detail_trims": trims.size(),
		"detail_niches": niches.size(),
		"detail_fixtures": fixtures.size(),
		"detail_pipes": pipes.size(),
		"detail_cables": cables.size(),
		"detail_ladders": ladders.size(),
		"detail_billboards": billboards.size(),
		"detail_holograms": holograms.size(),
		"towers": towers,
		"tower_parts": tower_parts,
	}


func _is_big_mass(xform: Transform3D) -> bool:
	var h: float = xform.basis.y.length()
	var side: float = minf(xform.basis.x.length(), xform.basis.z.length())
	return h >= MASS_SHADOW_MIN_HEIGHT and side >= MASS_SHADOW_MIN_SIDE


func _emit_detail_meshes(
	masses: Array[Transform3D], mass_colors: Array[Color], mass_customs: Array[Color],
	small_masses: Array[Transform3D], small_colors: Array[Color], small_customs: Array[Color],
	trims: Array[Transform3D], niches: Array[Transform3D], niche_colors: Array[Color], niche_customs: Array[Color],
	fixtures: Array[Transform3D], pipes: Array[Transform3D], cables: Array[Transform3D], ladders: Array[Transform3D],
	billboards: Array[Transform3D], billboard_colors: Array[Color], billboard_customs: Array[Color],
	holograms: Array[Transform3D], holo_colors: Array[Color], holo_customs: Array[Color]
) -> void:
	_emit_multimesh("Massing", CityMaterials.box_mesh(), CityMaterials.facade, masses, mass_colors, mass_customs, true, 0.0)
	_emit_multimesh("MassingSmall", CityMaterials.box_mesh(), CityMaterials.facade, small_masses, small_colors, small_customs, false, MASS_SMALL_VISIBLE_TO)
	_emit_multimesh("Trims", CityMaterials.box_mesh(), CityMaterials.concrete, trims, [], [], false, TRIM_VISIBLE_TO)
	_emit_multimesh("Niches", CityMaterials.quad_mesh(), CityMaterials.glass, niches, niche_colors, niche_customs, false, TRIM_VISIBLE_TO)
	_emit_multimesh("Fixtures", CityMaterials.box_mesh(), CityMaterials.metal_rust, fixtures, [], [], false, SMALL_DETAIL_VISIBLE_TO)
	_emit_multimesh("Pipes", CityMaterials.box_mesh(), CityMaterials.metal, pipes, [], [], false, TRIM_VISIBLE_TO)
	_emit_multimesh("Cables", CityMaterials.box_mesh(), CityMaterials.cable, cables, [], [], false, SMALL_DETAIL_VISIBLE_TO)
	_emit_multimesh("Ladders", CityMaterials.box_mesh(), CityMaterials.metal_rust, ladders, [], [], false, TRIM_VISIBLE_TO)
	_emit_multimesh("Billboards", CityMaterials.box_mesh(), CityMaterials.billboard, billboards, billboard_colors, billboard_customs, false, 0.0)
	_emit_multimesh("Holograms", CityMaterials.quad_mesh(), CityMaterials.hologram, holograms, holo_colors, holo_customs, false, 0.0)


## Слои небоскрёбов. Пилястры, карнизы и венцы не отсекаются по дистанции:
## именно они ломают силуэт коробки.
func _emit_tower_meshes(
	concrete: Array[Transform3D], metal: Array[Transform3D], glass: Array[Transform3D],
	poles: Array[Transform3D], neon: Array[Transform3D],
	neon_colors: Array[Color], neon_customs: Array[Color]
) -> void:
	var concrete_shadows: bool = detail_level == DETAIL_NEAR
	_emit_multimesh("TowerConcrete", CityMaterials.box_mesh(), CityMaterials.concrete, concrete, [], [], concrete_shadows, 0.0)
	_emit_multimesh("TowerGlass", CityMaterials.box_mesh(), CityMaterials.glass, glass, [], [], false, 0.0)
	_emit_multimesh("TowerMetal", CityMaterials.box_mesh(), CityMaterials.metal, metal, [], [], false, TOWER_SMALL_VISIBLE_TO)
	_emit_multimesh("TowerPoles", CityMaterials.cylinder_mesh(), CityMaterials.metal, poles, [], [], false, TOWER_SMALL_VISIBLE_TO)
	_emit_multimesh("TowerNeon", CityMaterials.box_mesh(), CityMaterials.neon, neon, neon_colors, neon_customs, false, 0.0)


func _emit_tower_lights(lights: Array[Dictionary]) -> void:
	if lights.is_empty():
		return
	var made: int = 0
	var step: int = maxi(1, int(ceil(float(lights.size()) / float(MAX_TOWER_LIGHTS))))
	var index: int = 0
	while index < lights.size() and made < MAX_TOWER_LIGHTS:
		var data: Dictionary = lights[index]
		var light := OmniLight3D.new()
		light.name = "TowerBeacon_%d" % made
		light.position = data.get("position", Vector3.ZERO)
		light.light_color = data.get("color", Color(1.0, 0.2, 0.25))
		light.light_energy = clampf(float(data.get("energy", 2.0)), 0.2, 8.0)
		light.omni_range = clampf(float(data.get("range", 18.0)), 3.0, 60.0)
		light.omni_attenuation = 1.6
		light.shadow_enabled = false
		light.distance_fade_enabled = true
		light.distance_fade_begin = 260.0
		light.distance_fade_length = 90.0
		add_child(light)
		_tower_lights.append(light)
		made += 1
		index += step


func _emit_alley(alley: Dictionary) -> void:
	if alley.is_empty():
		return
	var debris: Array[Transform3D] = []
	var boxes: Array[Transform3D] = []
	var pipes: Array[Transform3D] = []
	debris.append_array(alley.get("debris", []) as Array)
	boxes.append_array(alley.get("boxes", []) as Array)
	pipes.append_array(alley.get("pipes", []) as Array)

	_emit_multimesh("AlleyBins", CityMaterials.box_mesh(), CityMaterials.metal_rust, debris, [], [], false, SMALL_DETAIL_VISIBLE_TO)
	_emit_multimesh("AlleyBoxes", CityMaterials.box_mesh(), CityMaterials.cardboard, boxes, [], [], false, SMALL_DETAIL_VISIBLE_TO)
	_emit_multimesh("AlleyPipes", CityMaterials.cylinder_mesh(), CityMaterials.metal, pipes, [], [], false, SMALL_DETAIL_VISIBLE_TO)

	for xform: Transform3D in debris:
		_detail_boxes.append({"transform": xform})


# =========================================================== тротуары

func _build_sidewalks() -> void:
	var roads: Array = _content.get("roads", [])
	if roads.is_empty() or detail_level >= DETAIL_FAR:
		return

	var near: bool = detail_level == DETAIL_NEAR
	var cfg: Dictionary = NoirSidewalkBuilder.defaults()
	var density: float = 1.0
	var graphics: Dictionary = GameConfig.section("graphics")
	if not graphics.is_empty():
		density = clampf(float(graphics.get("detail_density", 1.0)), 0.0, 1.5)
	if density <= 0.02:
		return

	cfg["density"] = density
	cfg["props"] = near and density > 0.15
	cfg["signs"] = near and density > 0.1
	cfg["crosswalks"] = density > 0.05
	cfg["max_paint"] = int(round(float(NoirSidewalkBuilder.MAX_PAINT) * (1.0 if near else 0.45)))
	cfg["max_slabs"] = int(round(float(NoirSidewalkBuilder.MAX_SLABS) * clampf(0.5 + density * 0.5, 0.5, 1.0)))
	cfg["max_props"] = int(round(float(NoirSidewalkBuilder.MAX_PROPS) * clampf(density, 0.2, 1.0)))

	var walk: Dictionary = NoirSidewalkBuilder.generate(roads, _city_seed, coords, cfg)
	if walk.is_empty():
		return

	var slabs: Array[Transform3D] = []
	var curbs: Array[Transform3D] = []
	var paint: Array[Transform3D] = []
	var metal: Array[Transform3D] = []
	var poles: Array[Transform3D] = []
	var props: Array[Transform3D] = []
	slabs.append_array(walk.get("slabs", []) as Array)
	curbs.append_array(walk.get("curbs", []) as Array)
	paint.append_array(walk.get("paint", []) as Array)
	metal.append_array(walk.get("metal", []) as Array)
	poles.append_array(walk.get("poles", []) as Array)
	props.append_array(walk.get("props", []) as Array)

	var signs: Array[Transform3D] = []
	var sign_colors: Array[Color] = []
	var sign_customs: Array[Color] = []
	for entry: Variant in walk.get("signs", []) as Array:
		if not (entry is Dictionary):
			continue
		var item: Dictionary = entry as Dictionary
		signs.append(item["transform"])
		sign_colors.append(item.get("tint", Color.WHITE))
		sign_customs.append(item.get("custom", Color(0.0, 0.9, 0.0, 0.0)))

	_emit_multimesh("Sidewalks", CityMaterials.box_mesh(), CityMaterials.concrete, slabs, [], [], false, SIDEWALK_VISIBLE_TO)
	_emit_multimesh("Curbs", CityMaterials.box_mesh(), CityMaterials.concrete, curbs, [], [], false, SIDEWALK_VISIBLE_TO)
	_emit_multimesh("RoadPaint", CityMaterials.box_mesh(), paint_material(), paint, [], [], false, PAINT_VISIBLE_TO)
	_emit_multimesh("WalkMetal", CityMaterials.box_mesh(), CityMaterials.metal, metal, [], [], false, WALK_PROP_VISIBLE_TO)
	_emit_multimesh("WalkPoles", CityMaterials.cylinder_mesh(), CityMaterials.metal, poles, [], [], false, WALK_PROP_VISIBLE_TO)
	_emit_multimesh("WalkProps", CityMaterials.box_mesh(), CityMaterials.concrete, props, [], [], false, WALK_PROP_VISIBLE_TO)
	_emit_multimesh("WalkSigns", CityMaterials.box_mesh(), CityMaterials.neon, signs, sign_colors, sign_customs, false, 0.0)

	if near:
		for xform: Transform3D in walk.get("boxes", []) as Array:
			_detail_boxes.append({"transform": xform})
		_emit_walk_lights(walk.get("lights", []) as Array)

	_detail_stats["walk_items"] = NoirSidewalkBuilder.count(walk)
	_detail_stats["walk_signs"] = signs.size()


func _emit_walk_lights(lights: Array) -> void:
	var made: int = 0
	for entry: Variant in lights:
		if made >= MAX_WALK_LIGHTS:
			return
		if not (entry is Dictionary):
			continue
		var data: Dictionary = entry as Dictionary
		var light := OmniLight3D.new()
		light.name = "ShopLight_%d" % made
		light.position = data.get("position", Vector3.ZERO)
		light.light_color = data.get("color", Color(1.0, 0.75, 0.45))
		light.light_energy = clampf(float(data.get("energy", 1.7)), 0.2, 6.0)
		light.omni_range = clampf(float(data.get("range", 13.0)), 3.0, 40.0)
		light.omni_attenuation = 1.5
		light.shadow_enabled = false
		light.distance_fade_enabled = true
		light.distance_fade_begin = 55.0
		light.distance_fade_length = 25.0
		add_child(light)
		_walk_lights.append(light)
		made += 1


# =========================================================== улицы

func _build_streets() -> void:
	var roads: Array = _content.get("roads", [])
	if roads.is_empty():
		return

	var cfg: Dictionary = NoirStreetDresser.defaults()
	var graphics: Dictionary = GameConfig.section("graphics")
	if not graphics.is_empty():
		var density: float = clampf(float(graphics.get("detail_density", 0.8)), 0.0, 1.5)
		cfg["density"] = density
		cfg["debris"] = bool(graphics.get("debris", true))
		cfg["cars"] = density > 0.2
		cfg["neon"] = density > 0.1
		cfg["puddles"] = bool(graphics.get("ssr", true))
		cfg["max_items"] = maxi(40, int(round(float(NoirStreetDresser.MAX_ITEMS) * clampf(0.35 + density, 0.35, 1.0))))

	if float(cfg.get("density", 0.0)) <= 0.05:
		return

	var street: Dictionary = NoirStreetDresser.generate(roads, _city_seed, coords, cfg)
	if street.is_empty():
		return

	var concrete: Array[Transform3D] = []
	var metal: Array[Transform3D] = []
	var poles: Array[Transform3D] = []
	var rust: Array[Transform3D] = []
	var cardboard: Array[Transform3D] = []
	var glass: Array[Transform3D] = []
	var cars: Array[Transform3D] = []
	var wheels: Array[Transform3D] = []
	var puddles: Array[Transform3D] = []
	concrete.append_array(street.get("concrete", []) as Array)
	metal.append_array(street.get("metal", []) as Array)
	poles.append_array(street.get("poles", []) as Array)
	rust.append_array(street.get("rust", []) as Array)
	cardboard.append_array(street.get("cardboard", []) as Array)
	glass.append_array(street.get("glass", []) as Array)
	cars.append_array(street.get("cars", []) as Array)
	wheels.append_array(street.get("wheels", []) as Array)
	puddles.append_array(street.get("puddles", []) as Array)

	var neon: Array[Transform3D] = []
	var neon_colors: Array[Color] = []
	var neon_customs: Array[Color] = []
	for entry: Variant in street.get("neon", []) as Array:
		if not (entry is Dictionary):
			continue
		var item: Dictionary = entry as Dictionary
		neon.append(item["transform"])
		neon_colors.append(item.get("tint", Color.WHITE))
		neon_customs.append(item.get("custom", Color(0.0, 0.9, 0.0, 0.0)))

	_emit_multimesh("StreetConcrete", CityMaterials.box_mesh(), CityMaterials.concrete, concrete, [], [], false, STREET_VISIBLE_TO)
	_emit_multimesh("StreetMetal", CityMaterials.box_mesh(), CityMaterials.metal, metal, [], [], false, STREET_VISIBLE_TO)
	_emit_multimesh("StreetPoles", CityMaterials.cylinder_mesh(), CityMaterials.metal, poles, [], [], false, STREET_VISIBLE_TO)
	_emit_multimesh("StreetRust", CityMaterials.box_mesh(), CityMaterials.metal_rust, rust, [], [], false, STREET_SMALL_VISIBLE_TO)
	_emit_multimesh("StreetJunk", CityMaterials.box_mesh(), CityMaterials.cardboard, cardboard, [], [], false, STREET_SMALL_VISIBLE_TO)
	_emit_multimesh("StreetGlass", CityMaterials.box_mesh(), CityMaterials.glass, glass, [], [], false, STREET_VISIBLE_TO)
	_emit_multimesh("Cars", CityMaterials.box_mesh(), CityMaterials.metal, cars, [], [], true, STREET_VISIBLE_TO)
	_emit_multimesh("CarWheels", CityMaterials.cylinder_mesh(), CityMaterials.cable, wheels, [], [], false, STREET_SMALL_VISIBLE_TO)
	_emit_multimesh("Puddles", CityMaterials.box_mesh(), CityMaterials.glass, puddles, [], [], false, STREET_VISIBLE_TO)
	_emit_multimesh("StreetNeon", CityMaterials.box_mesh(), CityMaterials.neon, neon, neon_colors, neon_customs, false, 0.0)

	for xform: Transform3D in street.get("boxes", []) as Array:
		_detail_boxes.append({"transform": xform})

	_emit_street_lights(street.get("lights", []) as Array)

	_detail_stats["street_items"] = NoirStreetDresser.count(street)
	_detail_stats["street_cars"] = cars.size()


func _emit_street_lights(lights: Array) -> void:
	var made: int = 0
	for entry: Variant in lights:
		if made >= MAX_STREET_LIGHTS or _detail_lights.size() >= MAX_DETAIL_LIGHTS + MAX_STREET_LIGHTS:
			return
		if not (entry is Dictionary):
			continue
		var data: Dictionary = entry as Dictionary
		var light := OmniLight3D.new()
		light.name = "StreetLight_%d" % made
		light.position = data.get("position", Vector3.ZERO)
		light.light_color = data.get("color", Color.WHITE)
		light.light_energy = clampf(float(data.get("energy", 1.6)), 0.2, 6.0)
		light.omni_range = clampf(float(data.get("range", 12.0)), 3.0, 40.0)
		light.omni_attenuation = 1.5
		light.shadow_enabled = false
		light.distance_fade_enabled = true
		light.distance_fade_begin = 50.0
		light.distance_fade_length = 25.0
		add_child(light)
		_detail_lights.append(light)
		made += 1


## Сборщик MultiMesh. visible_to > 0 включает дистанционное отсечение.
func _emit_multimesh(node_name: String, mesh: Mesh, material: Material, transforms: Array[Transform3D], colors: Array[Color], customs: Array[Color], shadows: bool, visible_to: float) -> void:
	if transforms.is_empty():
		return
	if mesh == null:
		Log.warn("CityChunk", "Нет меша для деталей", {"узел": node_name})
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.use_custom_data = not customs.is_empty()
	mm.mesh = mesh
	mm.instance_count = transforms.size()

	for i: int in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
		if mm.use_colors and i < colors.size():
			mm.set_instance_color(i, colors[i])
		if mm.use_custom_data and i < customs.size():
			mm.set_instance_custom_data(i, customs[i])

	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = mm
	if material != null:
		instance.material_override = material
	instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	if visible_to > 0.0:
		instance.visibility_range_end = visible_to
		instance.visibility_range_end_margin = visible_to * 0.15
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(instance)
	_detail_nodes.append(instance)


func _emit_detail_lights(lights: Array[Dictionary], alley: Dictionary) -> void:
	if detail_level != DETAIL_NEAR:
		return

	var all: Array[Dictionary] = lights.duplicate()
	if not alley.is_empty():
		all.append_array(alley.get("lights", []) as Array)
	if all.is_empty():
		return

	var allowed: int = mini(MAX_DETAIL_LIGHTS, all.size())
	var step: int = maxi(1, int(ceil(float(all.size()) / float(allowed))))
	var index: int = 0
	while index < all.size() and _detail_lights.size() < MAX_DETAIL_LIGHTS:
		var data: Dictionary = all[index]
		var light := OmniLight3D.new()
		light.name = "NeonLight_%d" % index
		light.position = data.get("position", Vector3.ZERO)
		light.light_color = data.get("color", Color.WHITE)
		light.light_energy = clampf(float(data.get("energy", 1.6)), 0.2, 6.0)
		light.omni_range = clampf(float(data.get("range", 16.0)), 3.0, 40.0)
		light.omni_attenuation = 1.5
		light.shadow_enabled = false
		light.distance_fade_enabled = true
		light.distance_fade_begin = 55.0
		light.distance_fade_length = 25.0
		add_child(light)
		_detail_lights.append(light)
		index += step


func _emit_particles(drips: Array[Vector3], alley: Dictionary, density: float) -> void:
	if density <= 0.01:
		return

	var steam_spots: Array = alley.get("steam", []) as Array if not alley.is_empty() else []
	var steam_allowed: int = maxi(0, MAX_PARTICLE_SYSTEMS - 3)
	var made: int = 0

	for entry: Variant in steam_spots:
		if made >= steam_allowed:
			break
		if not (entry is Dictionary):
			continue
		var spot: Dictionary = entry as Dictionary
		var emitter: GPUParticles3D = NoirParticleFactory.make_steam(
			spot.get("position", Vector3.ZERO),
			float(spot.get("strength", 0.6)),
			float(spot.get("width", 1.0)),
			density
		)
		if emitter == null:
			continue
		add_child(emitter)
		_particles.append(emitter)
		made += 1

	if drips.is_empty():
		return
	var drip_allowed: int = MAX_PARTICLE_SYSTEMS - _particles.size()
	if drip_allowed <= 0:
		return
	var step: int = maxi(1, int(ceil(float(drips.size()) / float(drip_allowed))))
	var i: int = 0
	while i < drips.size() and _particles.size() < MAX_PARTICLE_SYSTEMS:
		var drop: GPUParticles3D = NoirParticleFactory.make_drip(drips[i], density)
		if drop != null:
			add_child(drop)
			_particles.append(drop)
		i += step


func _emit_climb_zones(zones: Array[Dictionary]) -> void:
	for entry: Variant in zones:
		if _climb_areas.size() >= MAX_CLIMB_ZONES:
			return
		if not (entry is Dictionary):
			continue
		var zone: Dictionary = entry as Dictionary
		var area: NoirClimbArea = NoirClimbArea.create(
			zone.get("position", Vector3.ZERO),
			zone.get("size", Vector3.ONE),
			zone.get("normal", Vector3.FORWARD),
			float(zone.get("top_y", 0.0))
		)
		if area == null:
			continue
		add_child(area)
		_climb_areas.append(area)


# ---------------------------------------------------------------- дороги

func _build_roads() -> void:
	var roads: Array = _content.get("roads", [])
	if roads.is_empty():
		return

	var plain: Array[Dictionary] = []
	var arterial: Array[Dictionary] = []
	for entry: Variant in roads:
		var road: Dictionary = entry as Dictionary
		if bool(road.get("arterial", false)):
			arterial.append(road)
		else:
			plain.append(road)

	_roads_mesh = _make_surface(plain, "Roads", CityMaterials.road)
	_arterial_mesh = _make_surface(arterial, "Arterials", CityMaterials.road_arterial)


func _make_surface(rects: Array[Dictionary], node_name: String, material: Material) -> MeshInstance3D:
	if rects.is_empty():
		return null

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)

	for entry: Dictionary in rects:
		var r: Rect2 = entry["rect"]
		var y: float = float(entry.get("y", 0.0))
		var a := Vector3(r.position.x, y, r.position.y)
		var b := Vector3(r.end.x, y, r.position.y)
		var c := Vector3(r.end.x, y, r.end.y)
		var d := Vector3(r.position.x, y, r.end.y)

		st.set_uv(Vector2(0.0, 0.0))
		st.add_vertex(a)
		st.set_uv(Vector2(1.0, 0.0))
		st.add_vertex(b)
		st.set_uv(Vector2(1.0, 1.0))
		st.add_vertex(c)

		st.set_uv(Vector2(0.0, 0.0))
		st.add_vertex(a)
		st.set_uv(Vector2(1.0, 1.0))
		st.add_vertex(c)
		st.set_uv(Vector2(0.0, 1.0))
		st.add_vertex(d)

	var mesh: ArrayMesh = st.commit()
	if mesh == null:
		Log.warn("CityChunk", "Полотно дорог не собралось", {"чанк": str(coords), "узел": node_name})
		return null

	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance


# ---------------------------------------------------------------- вывески

func _build_signs() -> void:
	var signs: Array = _content.get("signs", [])
	if signs.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = CityMaterials.quad_mesh()
	mm.instance_count = signs.size()

	for i: int in range(signs.size()):
		var s: Dictionary = signs[i]
		mm.set_instance_transform(i, s["transform"])
		mm.set_instance_color(i, s["tint"])
		mm.set_instance_custom_data(i, s["custom"])

	_signs_mm = MultiMeshInstance3D.new()
	_signs_mm.name = "Signs"
	_signs_mm.multimesh = mm
	_signs_mm.material_override = CityMaterials.neon
	_signs_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_signs_mm)


# ---------------------------------------------------------------- реквизит

func _build_props() -> void:
	var props: Array = _content.get("props", [])
	if props.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = CityMaterials.box_mesh()
	mm.instance_count = props.size()
	for i: int in range(props.size()):
		mm.set_instance_transform(i, (props[i] as Dictionary)["transform"])

	_props_mm = MultiMeshInstance3D.new()
	_props_mm.name = "Props"
	_props_mm.multimesh = mm
	_props_mm.material_override = CityMaterials.concrete
	_props_mm.visibility_range_end = PROP_VISIBLE_TO
	_props_mm.visibility_range_end_margin = 30.0
	_props_mm.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_props_mm)


# ---------------------------------------------------------------- фонари

func _build_lamps() -> void:
	var lamps: Array = _content.get("lamps", [])
	if lamps.is_empty():
		return

	var posts := MultiMesh.new()
	posts.transform_format = MultiMesh.TRANSFORM_3D
	posts.mesh = CityMaterials.cylinder_mesh()
	posts.instance_count = lamps.size()

	var heads := MultiMesh.new()
	heads.transform_format = MultiMesh.TRANSFORM_3D
	heads.use_colors = true
	heads.use_custom_data = true
	heads.mesh = CityMaterials.box_mesh()
	heads.instance_count = lamps.size()

	for i: int in range(lamps.size()):
		var lamp: Dictionary = lamps[i]
		var base: Vector3 = lamp["position"]
		var height: float = float(lamp["height"])

		posts.set_instance_transform(i, Transform3D(
			Basis.IDENTITY.scaled(Vector3(0.22, height, 0.22)),
			base + Vector3(0.0, height * 0.5, 0.0)
		))
		heads.set_instance_transform(i, Transform3D(
			Basis.IDENTITY.scaled(Vector3(0.75, 0.16, 0.45)),
			base + Vector3(0.0, height, 0.0)
		))
		heads.set_instance_color(i, lamp["color"])
		heads.set_instance_custom_data(i, Color(float(i) * 0.017, 0.9, 0.0, 0.0))

	_posts_mm = MultiMeshInstance3D.new()
	_posts_mm.name = "LampPosts"
	_posts_mm.multimesh = posts
	_posts_mm.material_override = CityMaterials.metal
	_posts_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_posts_mm.visibility_range_end = LAMP_POST_VISIBLE_TO
	_posts_mm.visibility_range_end_margin = 40.0
	_posts_mm.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_posts_mm)

	_heads_mm = MultiMeshInstance3D.new()
	_heads_mm.name = "LampHeads"
	_heads_mm.multimesh = heads
	_heads_mm.material_override = CityMaterials.neon
	_heads_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_heads_mm)


func _build_lights() -> void:
	var lamps: Array = _content.get("lamps", [])
	if lamps.is_empty():
		return

	var step: int = maxi(1, int(ceil(float(lamps.size()) / float(MAX_REAL_LIGHTS))))
	var index: int = 0
	while index < lamps.size() and _lights.size() < MAX_REAL_LIGHTS:
		var lamp: Dictionary = lamps[index]
		var light := OmniLight3D.new()
		light.name = "Lamp_%d" % index
		light.light_color = lamp["color"]
		light.light_energy = 1.6
		light.omni_range = 17.0
		light.omni_attenuation = 1.4
		light.shadow_enabled = false
		light.position = (lamp["position"] as Vector3) + Vector3(0.0, float(lamp["height"]) - 0.3, 0.0)
		light.distance_fade_enabled = true
		light.distance_fade_begin = 60.0
		light.distance_fade_length = 25.0
		add_child(light)
		_lights.append(light)
		index += step


# ---------------------------------------------------------------- коллизии

func _build_collision() -> void:
	var buildings: Array = _content.get("buildings", [])
	_body = StaticBody3D.new()
	_body.name = "Collision"
	_body.collision_layer = 1
	_body.collision_mask = 0
	add_child(_body)

	var ground := CollisionShape3D.new()
	var ground_shape := BoxShape3D.new()
	ground_shape.size = Vector3(rect.size.x, 0.4, rect.size.y)
	ground.shape = ground_shape
	ground.position = Vector3(rect.get_center().x, -0.2, rect.get_center().y)
	_body.add_child(ground)

	for entry: Variant in buildings:
		if not (entry is Dictionary):
			continue
		var b: Dictionary = entry as Dictionary

		# Проходимый дом получает оболочку с проёмом вместо монолитного куба.
		if bool(b.get("enterable", false)):
			_add_shell_collision(b)
			_enterable_count += 1
			continue

		var size: Vector3 = b["size"]
		var center: Vector3 = b["center"]

		# Башня со стилобатом не должна закупоривать его изнутри: её коллизия
		# начинается там, где заканчивается нижний объём.
		var from_y: float = clampf(float(b.get("collision_from_y", 0.0)), 0.0, maxf(0.0, size.y - 1.0))
		if from_y > 0.01:
			var rest: float = size.y - from_y
			size = Vector3(size.x, rest, size.z)
			center = Vector3(center.x, from_y + rest * 0.5, center.z)

		_add_box_shape(size, center)

	for entry: Dictionary in _detail_boxes:
		var xform: Transform3D = entry["transform"]
		var box_size := Vector3(
			xform.basis.x.length(),
			xform.basis.y.length(),
			xform.basis.z.length()
		)
		if box_size.x < 0.1 or box_size.y < 0.1 or box_size.z < 0.1:
			continue
		_add_box_shape(box_size, xform.origin)


## Коллизия проходимого дома: четыре стены с дверным проёмом и плита крыши.
## Полы и перекрытия приносит интерьер — он грузится раньше, чем игрок дойдёт
## до крыльца, поэтому провалиться внутрь пустой оболочки нельзя.
func _add_shell_collision(b: Dictionary) -> void:
	var size: Vector3 = b["size"]
	var center: Vector3 = b["center"]
	var base_y: float = center.y - size.y * 0.5
	var top: float = base_y + size.y
	var side: int = int(b.get("door_side", 2))
	var t: float = SHELL_THICKNESS
	var door_w: float = minf(NoirBuildingFactory.DOOR_WIDTH, minf(size.x, size.z) - 2.0)
	var door_h: float = minf(NoirBuildingFactory.DOOR_HEIGHT, size.y - 0.6)

	# 0 = +X, 1 = -X, 2 = +Z, 3 = -Z
	for face: int in range(4):
		var along_x: bool = face >= 2
		var normal_sign: float = 1.0 if face % 2 == 0 else -1.0
		var wall_size: Vector3 = (
			Vector3(size.x, size.y, t) if along_x else Vector3(t, size.y, size.z)
		)
		var wall_center: Vector3 = (
			Vector3(center.x, base_y + size.y * 0.5, center.z + normal_sign * (size.z * 0.5 - t * 0.5)) if along_x
			else Vector3(center.x + normal_sign * (size.x * 0.5 - t * 0.5), base_y + size.y * 0.5, center.z)
		)

		if face != side or door_w <= 1.2 or door_h <= 1.8:
			_add_box_shape(wall_size, wall_center)
			continue

		# Стена с проёмом: два простенка по бокам и перемычка сверху.
		var span: float = wall_size.x if along_x else wall_size.z
		var segment: float = (span - door_w) * 0.5
		if segment > 0.05:
			for s: int in [-1, 1]:
				var offset: float = float(s) * (door_w * 0.5 + segment * 0.5)
				var seg_size: Vector3 = (
					Vector3(segment, size.y, t) if along_x else Vector3(t, size.y, segment)
				)
				var seg_center: Vector3 = wall_center + (
					Vector3(offset, 0.0, 0.0) if along_x else Vector3(0.0, 0.0, offset)
				)
				_add_box_shape(seg_size, seg_center)

		var lintel: float = maxf(0.2, size.y - door_h)
		var lintel_size: Vector3 = (
			Vector3(door_w, lintel, t) if along_x else Vector3(t, lintel, door_w)
		)
		_add_box_shape(lintel_size, Vector3(wall_center.x, base_y + door_h + lintel * 0.5, wall_center.z))

	# Крыша: по ней можно ходить, и сквозь неё нельзя провалиться внутрь.
	_add_box_shape(
		Vector3(size.x, SHELL_THICKNESS, size.z),
		Vector3(center.x, top - SHELL_THICKNESS * 0.5, center.z)
	)


func _add_box_shape(box_size: Vector3, box_position: Vector3) -> void:
	if _body == null or not is_instance_valid(_body):
		return
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(0.05, box_size.x), maxf(0.05, box_size.y), maxf(0.05, box_size.z))
	shape.shape = box
	shape.position = box_position
	_body.add_child(shape)


# ---------------------------------------------------------------- окклюдеры

func _build_occluder() -> void:
	var occluders: Array = (_content.get("occluders", []) as Array).duplicate()
	occluders.append_array(_detail_occluders)
	if occluders.is_empty():
		return

	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for entry: Variant in occluders:
		if not (entry is Dictionary):
			continue
		var o: Dictionary = entry as Dictionary
		_append_occluder_box(
			vertices,
			indices,
			o.get("center", Vector3.ZERO),
			o.get("size", Vector3.ONE)
		)

	if vertices.is_empty():
		return

	var shape := ArrayOccluder3D.new()
	shape.set_arrays(vertices, indices)

	_occluder = OccluderInstance3D.new()
	_occluder.name = "Occluder"
	_occluder.occluder = shape
	add_child(_occluder)


## Добавляет один параллелепипед в массивы окклюдера.
func _append_occluder_box(vertices: PackedVector3Array, indices: PackedInt32Array, center: Vector3, size: Vector3) -> void:
	var h: Vector3 = size * 0.5
	if h.x <= 0.05 or h.y <= 0.05 or h.z <= 0.05:
		return

	var base: int = vertices.size()
	vertices.append(center + Vector3(-h.x, -h.y, -h.z))
	vertices.append(center + Vector3(h.x, -h.y, -h.z))
	vertices.append(center + Vector3(h.x, -h.y, h.z))
	vertices.append(center + Vector3(-h.x, -h.y, h.z))
	vertices.append(center + Vector3(-h.x, h.y, -h.z))
	vertices.append(center + Vector3(h.x, h.y, -h.z))
	vertices.append(center + Vector3(h.x, h.y, h.z))
	vertices.append(center + Vector3(-h.x, h.y, h.z))

	var faces: PackedInt32Array = [
		0, 2, 1, 0, 3, 2,   # низ
		4, 5, 6, 4, 6, 7,   # верх
		0, 1, 5, 0, 5, 4,   # -Z
		3, 2, 6, 3, 6, 7,   # +Z
		1, 2, 6, 1, 6, 5,   # +X
		0, 4, 7, 0, 7, 3,   # -X
	]
	for i: int in faces:
		indices.append(base + i)
