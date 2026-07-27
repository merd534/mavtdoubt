class_name NoirParticleFactory
extends RefCounted
## ФАЗА 3. GPU-частицы: пар из труб и капли с кондиционеров.
##
## Все системы строятся кодом: ни одного .tres, поэтому пресеты качества могут
## менять количество частиц без перезагрузки ресурсов. Плотность приходит
## извне (0..1); при 0 система не создаётся вовсе и не тратит ни байта:
## именно так работает пресет Картошка, где пара и капель нет совсем.

const STEAM_BASE_AMOUNT := 24
const DRIP_BASE_AMOUNT := 14


## Пар из трубы или решётки. [param strength] — напор (0..1).
static func make_steam(position: Vector3, strength: float, width: float, density: float) -> GPUParticles3D:
	if density <= 0.01:
		return null

	var amount: int = maxi(4, int(round(
		float(STEAM_BASE_AMOUNT) * clampf(density, 0.0, 1.5) * clampf(0.4 + strength, 0.4, 1.4)
	)))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(maxf(0.1, width * 0.4), 0.05, maxf(0.1, width * 0.4))
	process.direction = Vector3.UP
	process.spread = 18.0
	process.initial_velocity_min = 0.35 + strength * 0.6
	process.initial_velocity_max = 0.9 + strength * 1.6
	process.gravity = Vector3(0.0, 0.25, 0.0)
	process.damping_min = 0.4
	process.damping_max = 1.2
	process.scale_min = 0.8 + strength
	process.scale_max = 2.4 + strength * 2.0
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.angular_velocity_min = -12.0
	process.angular_velocity_max = 12.0
	process.color = Color(0.72, 0.78, 0.86, clampf(0.10 + strength * 0.10, 0.05, 0.24))

	var node := GPUParticles3D.new()
	node.name = "Steam"
	node.position = position
	node.amount = amount
	node.lifetime = 3.4
	node.lifetime_randomness = 0.4
	node.preprocess = 1.5
	node.randomness = 0.6
	node.local_coords = false
	node.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	node.fixed_fps = 20            # пару не нужна частота кадров, экономим GPU
	node.interpolate = true
	node.process_material = process
	node.draw_pass_1 = _billboard_mesh(CityMaterials.steam_particle, Vector2.ONE)
	node.visibility_aabb = AABB(Vector3(-3.0, -0.5, -3.0), Vector3(6.0, 9.0, 6.0))
	# За 95 м пар не читается, но продолжает симулироваться — гасим по дистанции.
	node.visibility_range_end = 95.0
	node.visibility_range_end_margin = 12.0
	node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return node


## Капли воды, стекающие с кондиционера.
static func make_drip(position: Vector3, density: float) -> GPUParticles3D:
	if density <= 0.01:
		return null

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(0.08, 0.02, 0.08)
	process.direction = Vector3.DOWN
	process.spread = 3.0
	process.initial_velocity_min = 0.2
	process.initial_velocity_max = 0.6
	process.gravity = Vector3(0.0, -9.0, 0.0)
	process.scale_min = 0.25
	process.scale_max = 0.5
	process.color = Color(0.62, 0.74, 0.86, 0.55)

	var node := GPUParticles3D.new()
	node.name = "Drip"
	node.position = position
	node.amount = maxi(3, int(round(float(DRIP_BASE_AMOUNT) * clampf(density, 0.0, 1.5))))
	node.lifetime = 1.6
	node.lifetime_randomness = 0.5
	node.randomness = 0.8
	node.fixed_fps = 30
	node.interpolate = true
	node.local_coords = false
	node.process_material = process
	node.draw_pass_1 = _billboard_mesh(CityMaterials.water_drop, Vector2(0.05, 0.22))
	node.visibility_aabb = AABB(Vector3(-0.6, -12.0, -0.6), Vector3(1.2, 13.0, 1.2))
	node.visibility_range_end = 45.0
	node.visibility_range_end_margin = 8.0
	node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return node


static func _billboard_mesh(material: Material, size: Vector2) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = size
	if material != null:
		mesh.material = material
	return mesh
