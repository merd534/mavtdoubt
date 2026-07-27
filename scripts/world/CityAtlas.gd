class_name NoirCityAtlas
extends Node
## Атлас города. Автозагрузка: `CityAtlas`.
##
## Это **авторитетный источник истины** о планировке: границы районов, река,
## мосты, метро, landmark'и и полный реестр играбельных локаций.
## Фаза 2 (`CityGenerator`) ничего не выдумывает — она только ставит геометрию
## по этим данным. Фаза 1 (`CrimeDirector`) ссылается на `location_id` отсюда.
##
## Планировка воспроизводит композицию референсов из `картинки/`:
## яркое ядро в центре, Financial к северо-западу от него, промзона по верхнему
## краю, река с северо-востока на юго-восток с 4 мостами, за рекой Old Town →
## Harbor, East End Slums на северо-востоке, Waterfront снизу,
## Entertainment на юго-западе, Slums на юго-востоке, Greyhollow на западе.
##
## Система координат: XZ — план (метры), +X восток, +Z юг, Y — высота.

# ---------------------------------------------------------------- палитра

## Палитра снята с референсов, см. docs/CITY_REFERENCE.md.
const PALETTE: Dictionary = {
	"base_asphalt": Color("#0A0C12"),
	"base_concrete": Color("#12151E"),
	"base_brick": Color("#1A1418"),
	"fog_near": Color("#0E1420"),
	"fog_far": Color("#151B29"),
	"neon_magenta": Color("#FF2A6D"),
	"neon_rose": Color("#FF5C8A"),
	"neon_cyan": Color("#05D9E8"),
	"neon_ice": Color("#7DF9FF"),
	"neon_purple": Color("#A855F7"),
	"neon_green": Color("#39FF88"),
	"sodium_amber": Color("#FFA23A"),
	"sodium_deep": Color("#FF6B1A"),
	"police_red": Color("#E8253F"),
	"window_warm": Color("#FFC46B"),
	"water_deep": Color("#070A11"),
}

# ---------------------------------------------------------------- типы локаций

enum LocationKind {
	MAIN_HUB, MISSION_SITE, POINT_OF_INTEREST, SHOP, HOTEL, RESTAURANT, BAR_CLUB,
	PARKING_STREET, PARKING_GARAGE, TRANSIT_STATION, PARK, BRIDGE, DOCK,
	CHURCH, SCHOOL, GOVERNMENT, ENTERTAINMENT, GATED_COMMUNITY, DANGER_ZONE,
	APARTMENTS, WAREHOUSE, POLICE_STATION, HOSPITAL, MARKET,
}

const KIND_NAMES: Dictionary = {
	LocationKind.MAIN_HUB: "Штаб",
	LocationKind.MISSION_SITE: "Место задания",
	LocationKind.POINT_OF_INTEREST: "Точка интереса",
	LocationKind.SHOP: "Магазин",
	LocationKind.HOTEL: "Отель",
	LocationKind.RESTAURANT: "Кафе",
	LocationKind.BAR_CLUB: "Бар",
	LocationKind.PARKING_STREET: "Парковка",
	LocationKind.PARKING_GARAGE: "Паркинг",
	LocationKind.TRANSIT_STATION: "Станция",
	LocationKind.PARK: "Парк",
	LocationKind.BRIDGE: "Мост",
	LocationKind.DOCK: "Док",
	LocationKind.CHURCH: "Церковь",
	LocationKind.SCHOOL: "Школа",
	LocationKind.GOVERNMENT: "Госучреждение",
	LocationKind.ENTERTAINMENT: "Развлечения",
	LocationKind.GATED_COMMUNITY: "Закрытый квартал",
	LocationKind.DANGER_ZONE: "Опасная зона",
	LocationKind.APARTMENTS: "Жилой дом",
	LocationKind.WAREHOUSE: "Склад",
	LocationKind.POLICE_STATION: "Участок",
	LocationKind.HOSPITAL: "Больница",
	LocationKind.MARKET: "Рынок",
}

# ---------------------------------------------------------------- габариты мира

const WORLD_HALF_X := 2300.0
const WORLD_HALF_Z := 1700.0
const RIVER_WIDTH := 150.0
const DEFAULT_CITY_SEED := 20260726

## Профиль застройки района. Ключи используются `CityGenerator` напрямую.
## Порядок в массиве = приоритет: первый подходящий район выигрывает,
## поэтому Outskirts стоит последним как «всё остальное».
const DISTRICT_TABLE: Array[Dictionary] = [
	{
		"id": "downtown_core", "name": "Downtown Core", "ru": "Центральное ядро",
		"profile": "core", "rect": [-500.0, -620.0, 900.0, 760.0],
		"height": [45.0, 260.0], "block": 62.0, "street": 22.0,
		"density": 0.94, "neon": 1.0, "wealth": 0.72, "crime": 0.45,
		"police_sec": 42.0, "fog": 0.6, "across_river": false, "venues": 26,
		"palette": ["neon_magenta", "neon_rose", "neon_cyan", "sodium_amber"],
	},
	{
		"id": "financial_district", "name": "Financial District", "ru": "Финансовый квартал",
		"profile": "financial", "rect": [-950.0, -1180.0, 650.0, 620.0],
		"height": [60.0, 300.0], "block": 74.0, "street": 26.0,
		"density": 0.88, "neon": 0.72, "wealth": 0.95, "crime": 0.18,
		"police_sec": 30.0, "fog": 0.55, "across_river": false, "venues": 14,
		"palette": ["neon_ice", "neon_cyan", "window_warm", "neon_magenta"],
	},
	{
		"id": "skyline_district", "name": "Skyline District", "ru": "Скайлайн",
		"profile": "core", "rect": [-300.0, -1180.0, 700.0, 560.0],
		"height": [70.0, 320.0], "block": 68.0, "street": 24.0,
		"density": 0.9, "neon": 0.95, "wealth": 0.84, "crime": 0.28,
		"police_sec": 36.0, "fog": 0.7, "across_river": false, "venues": 13,
		"palette": ["neon_magenta", "neon_purple", "neon_cyan", "neon_ice"],
	},
	{
		"id": "northview_industrial", "name": "Northview Industrial", "ru": "Нортвью-Индастриал",
		"profile": "industrial", "rect": [-1500.0, -1700.0, 1200.0, 520.0],
		"height": [12.0, 58.0], "block": 130.0, "street": 30.0,
		"density": 0.62, "neon": 0.3, "wealth": 0.3, "crime": 0.58,
		"police_sec": 120.0, "fog": 1.0, "across_river": false, "venues": 11,
		"palette": ["sodium_deep", "neon_ice", "sodium_amber"],
	},
	{
		"id": "industrial_zone", "name": "Industrial Zone", "ru": "Промзона",
		"profile": "industrial", "rect": [-300.0, -1700.0, 1150.0, 520.0],
		"height": [14.0, 72.0], "block": 145.0, "street": 32.0,
		"density": 0.6, "neon": 0.34, "wealth": 0.26, "crime": 0.66,
		"police_sec": 135.0, "fog": 1.0, "across_river": false, "venues": 12,
		"palette": ["sodium_deep", "neon_green", "neon_ice"],
	},
	{
		"id": "westfield_commercial", "name": "Westfield Commercial", "ru": "Уэстфилд",
		"profile": "commercial", "rect": [-2300.0, -1180.0, 800.0, 900.0],
		"height": [18.0, 96.0], "block": 80.0, "street": 24.0,
		"density": 0.82, "neon": 0.66, "wealth": 0.6, "crime": 0.34,
		"police_sec": 62.0, "fog": 0.8, "across_river": false, "venues": 15,
		"palette": ["neon_cyan", "sodium_amber", "neon_rose", "window_warm"],
	},
	{
		"id": "residential_area", "name": "Residential Area", "ru": "Жилой массив",
		"profile": "residential", "rect": [-1550.0, -560.0, 1050.0, 900.0],
		"height": [16.0, 74.0], "block": 70.0, "street": 20.0,
		"density": 0.8, "neon": 0.34, "wealth": 0.56, "crime": 0.3,
		"police_sec": 70.0, "fog": 0.65, "across_river": false, "venues": 14,
		"palette": ["window_warm", "neon_cyan", "sodium_amber"],
	},
	{
		"id": "southgate_residential", "name": "Southgate Residential", "ru": "Саутгейт",
		"profile": "residential", "rect": [-1000.0, 340.0, 1100.0, 700.0],
		"height": [14.0, 66.0], "block": 66.0, "street": 20.0,
		"density": 0.78, "neon": 0.38, "wealth": 0.46, "crime": 0.4,
		"police_sec": 84.0, "fog": 0.7, "across_river": false, "venues": 13,
		"palette": ["window_warm", "neon_cyan", "neon_rose"],
	},
	{
		"id": "greyhollow_ghetto", "name": "Greyhollow Ghetto", "ru": "Грейхоллоу",
		"profile": "slum", "rect": [-2300.0, -280.0, 750.0, 900.0],
		"height": [8.0, 34.0], "block": 44.0, "street": 12.0,
		"density": 0.7, "neon": 0.12, "wealth": 0.1, "crime": 0.9,
		"police_sec": 220.0, "fog": 0.95, "across_river": false, "venues": 10,
		"palette": ["sodium_deep", "window_warm"],
	},
	{
		"id": "entertainment_district", "name": "Entertainment District", "ru": "Квартал развлечений",
		"profile": "entertainment", "rect": [-1900.0, 620.0, 900.0, 800.0],
		"height": [12.0, 88.0], "block": 56.0, "street": 18.0,
		"density": 0.9, "neon": 1.0, "wealth": 0.52, "crime": 0.62,
		"police_sec": 68.0, "fog": 0.75, "across_river": false, "venues": 16,
		"palette": ["neon_magenta", "neon_purple", "neon_rose", "neon_cyan"],
	},
	{
		"id": "waterfront", "name": "Waterfront", "ru": "Набережная",
		"profile": "waterfront", "rect": [-1000.0, 1040.0, 1200.0, 660.0],
		"height": [10.0, 52.0], "block": 96.0, "street": 26.0,
		"density": 0.58, "neon": 0.46, "wealth": 0.4, "crime": 0.55,
		"police_sec": 110.0, "fog": 1.0, "across_river": false, "venues": 11,
		"palette": ["neon_cyan", "sodium_amber", "neon_ice"],
	},
	{
		"id": "riverside", "name": "Riverside", "ru": "Ривер-сайд",
		"profile": "commercial", "rect": [400.0, 140.0, 800.0, 760.0],
		"height": [14.0, 78.0], "block": 72.0, "street": 22.0,
		"density": 0.74, "neon": 0.58, "wealth": 0.5, "crime": 0.42,
		"police_sec": 88.0, "fog": 0.9, "across_river": false, "venues": 12,
		"palette": ["neon_cyan", "neon_rose", "sodium_amber"],
	},
	{
		"id": "slums", "name": "Slums", "ru": "Трущобы",
		"profile": "slum", "rect": [600.0, 900.0, 900.0, 800.0],
		"height": [7.0, 30.0], "block": 40.0, "street": 11.0,
		"density": 0.72, "neon": 0.14, "wealth": 0.08, "crime": 0.94,
		"police_sec": 240.0, "fog": 0.95, "across_river": false, "venues": 10,
		"palette": ["sodium_deep", "window_warm", "neon_magenta"],
	},
	{
		"id": "old_town", "name": "Old Town", "ru": "Старый город",
		"profile": "oldtown", "rect": [1250.0, -800.0, 700.0, 900.0],
		"height": [12.0, 56.0], "block": 48.0, "street": 14.0,
		"density": 0.86, "neon": 0.5, "wealth": 0.44, "crime": 0.5,
		"police_sec": 96.0, "fog": 0.85, "across_river": true, "venues": 14,
		"palette": ["sodium_amber", "neon_rose", "window_warm", "neon_green"],
	},
	{
		"id": "harbor_district", "name": "Harbor District", "ru": "Портовый район",
		"profile": "harbor", "rect": [1700.0, 100.0, 600.0, 800.0],
		"height": [9.0, 44.0], "block": 120.0, "street": 28.0,
		"density": 0.55, "neon": 0.42, "wealth": 0.24, "crime": 0.78,
		"police_sec": 165.0, "fog": 1.0, "across_river": true, "venues": 11,
		"palette": ["neon_cyan", "sodium_deep", "neon_ice"],
	},
	{
		"id": "east_end_slums", "name": "East End Slums", "ru": "Ист-Энд",
		"profile": "slum", "rect": [1100.0, -1700.0, 900.0, 900.0],
		"height": [8.0, 40.0], "block": 42.0, "street": 12.0,
		"density": 0.76, "neon": 0.3, "wealth": 0.12, "crime": 0.88,
		"police_sec": 210.0, "fog": 0.95, "across_river": true, "venues": 11,
		"palette": ["neon_magenta", "sodium_deep", "neon_purple"],
	},
	{
		"id": "outskirts", "name": "Outskirts", "ru": "Окраины",
		"profile": "outskirts", "rect": [-2300.0, -1700.0, 4600.0, 3400.0],
		"height": [6.0, 26.0], "block": 160.0, "street": 22.0,
		"density": 0.3, "neon": 0.1, "wealth": 0.2, "crime": 0.5,
		"police_sec": 260.0, "fog": 1.0, "across_river": false, "venues": 8,
		"palette": ["sodium_deep", "window_warm"],
	},
]

## Река: ломаная от северо-востока к юго-востоку (как на референсах).
const RIVER_POINTS: Array[Vector2] = [
	Vector2(880.0, -1700.0),
	Vector2(1180.0, -1120.0),
	Vector2(1420.0, -520.0),
	Vector2(1640.0, 120.0),
	Vector2(1900.0, 820.0),
	Vector2(2060.0, 1700.0),
]

## 4 моста — ровно как подсвечено на референсах.
const BRIDGE_TABLE: Array[Dictionary] = [
	{"id": "bridge_northgate", "name": "Northgate Span", "ru": "Нортгейтский пролёт", "z": -1150.0, "width": 26.0, "lanes": 4},
	{"id": "bridge_riverdale", "name": "Riverdale Bridge", "ru": "Ривердейлский мост", "z": -520.0, "width": 32.0, "lanes": 6},
	{"id": "bridge_ironworks", "name": "Ironworks Crossing", "ru": "Айронворкс", "z": 190.0, "width": 24.0, "lanes": 4},
	{"id": "bridge_south_reach", "name": "South Reach Bridge", "ru": "Саут-Рич", "z": 860.0, "width": 22.0, "lanes": 2},
]

## 16 именованных POI с панели референса №2. Координаты подобраны так, чтобы
## каждый попадал в тематически верный район.
const LANDMARK_TABLE: Array[Dictionary] = [
	{"id": "lm_grand_hotel", "name": "The Grand Hotel", "ru": "Отель «Гранд»", "pos": [-140.0, -300.0], "kind": LocationKind.HOTEL, "floors": 22, "camera": true, "lock": 2},
	{"id": "lm_neon_dreams", "name": "Neon Dreams Club", "ru": "Клуб «Неоновые сны»", "pos": [-1440.0, 980.0], "kind": LocationKind.BAR_CLUB, "floors": 3, "camera": true, "lock": 3},
	{"id": "lm_rain_city_market", "name": "Rain City Market", "ru": "Рынок «Рейн-Сити»", "pos": [1600.0, -350.0], "kind": LocationKind.MARKET, "floors": 1, "camera": false, "lock": 1},
	{"id": "lm_black_dock_yards", "name": "Black Dock Yards", "ru": "Чёрные доки", "pos": [1980.0, 470.0], "kind": LocationKind.DOCK, "floors": 2, "camera": true, "lock": 4},
	{"id": "lm_old_cemetery", "name": "Old Cemetery", "ru": "Старое кладбище", "pos": [-1980.0, 170.0], "kind": LocationKind.POINT_OF_INTEREST, "floors": 1, "camera": false, "lock": 1},
	{"id": "lm_skyline_observatory", "name": "Skyline Observatory", "ru": "Обсерватория «Скайлайн»", "pos": [60.0, -880.0], "kind": LocationKind.POINT_OF_INTEREST, "floors": 41, "camera": true, "lock": 3},
	{"id": "lm_city_hall", "name": "City Hall", "ru": "Ратуша", "pos": [-640.0, -820.0], "kind": LocationKind.GOVERNMENT, "floors": 8, "camera": true, "lock": 4},
	{"id": "lm_st_marys", "name": "St. Mary's Church", "ru": "Церковь Св. Марии", "pos": [1420.0, -110.0], "kind": LocationKind.CHURCH, "floors": 2, "camera": false, "lock": 2},
	{"id": "lm_victoria_park", "name": "Victoria Park", "ru": "Парк Виктории", "pos": [-1050.0, -120.0], "kind": LocationKind.PARK, "floors": 1, "camera": false, "lock": 0},
	{"id": "lm_eastside_slums", "name": "Eastside Slums", "ru": "Ист-сайдские трущобы", "pos": [1050.0, 1320.0], "kind": LocationKind.DANGER_ZONE, "floors": 4, "camera": false, "lock": 1},
	{"id": "lm_industrial_complex", "name": "Industrial Complex", "ru": "Промышленный комплекс", "pos": [280.0, -1450.0], "kind": LocationKind.WAREHOUSE, "floors": 3, "camera": true, "lock": 3},
	{"id": "lm_riverdale_bridge", "name": "Riverdale Bridge", "ru": "Ривердейлский мост", "pos": [1490.0, -520.0], "kind": LocationKind.BRIDGE, "floors": 1, "camera": true, "lock": 0},
	{"id": "lm_south_harbor", "name": "South Harbor", "ru": "Южная гавань", "pos": [-320.0, 1560.0], "kind": LocationKind.DOCK, "floors": 2, "camera": true, "lock": 2},
	{"id": "lm_west_end_station", "name": "West End Station", "ru": "Станция «Уэст-Энд»", "pos": [-1900.0, -700.0], "kind": LocationKind.TRANSIT_STATION, "floors": 2, "camera": true, "lock": 1},
	{"id": "lm_north_point_lighthouse", "name": "North Point Lighthouse", "ru": "Маяк Норт-Пойнт", "pos": [1760.0, -1560.0], "kind": LocationKind.POINT_OF_INTEREST, "floors": 6, "camera": false, "lock": 2},
	{"id": "lm_forgotten_tunnels", "name": "The Forgotten Tunnels", "ru": "Забытые туннели", "pos": [760.0, 520.0], "kind": LocationKind.DANGER_ZONE, "floors": 1, "camera": false, "lock": 4},
]

## Веса типов заведений по профилю района — определяют, что генерируется.
const VENUE_WEIGHTS: Dictionary = {
	"core": {LocationKind.APARTMENTS: 22, LocationKind.SHOP: 16, LocationKind.RESTAURANT: 14, LocationKind.BAR_CLUB: 12, LocationKind.HOTEL: 8, LocationKind.PARKING_GARAGE: 8, LocationKind.GOVERNMENT: 4, LocationKind.POLICE_STATION: 3, LocationKind.ENTERTAINMENT: 8, LocationKind.TRANSIT_STATION: 5},
	"financial": {LocationKind.GOVERNMENT: 24, LocationKind.SHOP: 12, LocationKind.RESTAURANT: 14, LocationKind.HOTEL: 10, LocationKind.PARKING_GARAGE: 14, LocationKind.APARTMENTS: 10, LocationKind.BAR_CLUB: 8, LocationKind.TRANSIT_STATION: 8},
	"industrial": {LocationKind.WAREHOUSE: 44, LocationKind.PARKING_STREET: 14, LocationKind.SHOP: 8, LocationKind.RESTAURANT: 8, LocationKind.DANGER_ZONE: 12, LocationKind.APARTMENTS: 8, LocationKind.TRANSIT_STATION: 6},
	"commercial": {LocationKind.SHOP: 30, LocationKind.RESTAURANT: 16, LocationKind.APARTMENTS: 16, LocationKind.MARKET: 10, LocationKind.PARKING_GARAGE: 8, LocationKind.BAR_CLUB: 8, LocationKind.HOSPITAL: 4, LocationKind.TRANSIT_STATION: 8},
	"residential": {LocationKind.APARTMENTS: 46, LocationKind.SHOP: 12, LocationKind.RESTAURANT: 10, LocationKind.PARK: 8, LocationKind.SCHOOL: 8, LocationKind.PARKING_STREET: 8, LocationKind.HOSPITAL: 4, LocationKind.GATED_COMMUNITY: 4},
	"slum": {LocationKind.APARTMENTS: 40, LocationKind.DANGER_ZONE: 20, LocationKind.SHOP: 10, LocationKind.BAR_CLUB: 10, LocationKind.WAREHOUSE: 10, LocationKind.MARKET: 6, LocationKind.PARKING_STREET: 4},
	"entertainment": {LocationKind.BAR_CLUB: 32, LocationKind.ENTERTAINMENT: 22, LocationKind.RESTAURANT: 16, LocationKind.HOTEL: 10, LocationKind.SHOP: 8, LocationKind.APARTMENTS: 8, LocationKind.PARKING_GARAGE: 4},
	"waterfront": {LocationKind.DOCK: 26, LocationKind.WAREHOUSE: 18, LocationKind.RESTAURANT: 14, LocationKind.BAR_CLUB: 12, LocationKind.APARTMENTS: 12, LocationKind.PARK: 10, LocationKind.PARKING_STREET: 8},
	"oldtown": {LocationKind.APARTMENTS: 26, LocationKind.MARKET: 16, LocationKind.RESTAURANT: 14, LocationKind.CHURCH: 8, LocationKind.SHOP: 14, LocationKind.BAR_CLUB: 10, LocationKind.POINT_OF_INTEREST: 6, LocationKind.SCHOOL: 6},
	"harbor": {LocationKind.DOCK: 34, LocationKind.WAREHOUSE: 26, LocationKind.BAR_CLUB: 12, LocationKind.APARTMENTS: 10, LocationKind.DANGER_ZONE: 10, LocationKind.RESTAURANT: 8},
	"outskirts": {LocationKind.APARTMENTS: 24, LocationKind.WAREHOUSE: 22, LocationKind.DANGER_ZONE: 18, LocationKind.PARKING_STREET: 14, LocationKind.SHOP: 12, LocationKind.PARK: 10},
}

const STREET_FIRST: PackedStringArray = [
	"Ashgrove", "Bellweather", "Carrow", "Drexel", "Eastcliff", "Fenmore",
	"Greywater", "Halloran", "Ivory", "Jarrow", "Kestrel", "Lament",
	"Mercer", "Northgate", "Osprey", "Pellham", "Quill", "Rothwell",
	"Saltmarsh", "Tannery", "Umber", "Vance", "Wexford", "Yarrow",
]
const STREET_SUFFIX: PackedStringArray = ["Street", "Avenue", "Row", "Lane", "Boulevard", "Way", "Terrace", "Alley"]

const VENUE_PREFIX: PackedStringArray = [
	"Blue", "Black", "Crimson", "Golden", "Silver", "Velvet", "Rusted", "Hollow",
	"Midnight", "Electric", "Paper", "Iron", "Glass", "Salt", "Ember", "Fading",
]
const VENUE_NOUN: PackedStringArray = [
	"Lantern", "Orchid", "Sparrow", "Anchor", "Kettle", "Dahlia", "Needle",
	"Marquee", "Cortex", "Arcade", "Terminal", "Vault", "Parlour", "Halo",
	"Circuit", "Rain", "Mirror", "Static",
]

# ---------------------------------------------------------------- состояние

var city_seed: int = DEFAULT_CITY_SEED

var _districts: Dictionary = {}          # id -> Dictionary (обогащённый DISTRICT_TABLE)
var _district_order: Array[String] = []  # порядок приоритета
var _locations: Dictionary = {}          # location_id -> Dictionary
var _locations_by_district: Dictionary = {}
var _locations_by_kind: Dictionary = {}
var _streets: Dictionary = {}            # district_id -> {"ns": Array, "ew": Array}
var _bridges: Array[Dictionary] = []
var _safehouses: Array[String] = []
var _metro: Array[Dictionary] = []
var _built: bool = false

signal atlas_built(location_count: int)


func _ready() -> void:
	var configured_seed: int = GameConfig.get_int("crime", "seed")
	if configured_seed != 0:
		city_seed = configured_seed
	build()


## Полная (пере)сборка атласа. Идемпотентна, безопасна к повторному вызову.
func build(new_seed: int = 0) -> void:
	if new_seed != 0:
		city_seed = new_seed

	_districts.clear()
	_district_order.clear()
	_locations.clear()
	_locations_by_district.clear()
	_locations_by_kind.clear()
	_streets.clear()
	_bridges.clear()
	_safehouses.clear()
	_metro.clear()
	_built = false

	var rng := RandomNumberGenerator.new()
	rng.seed = city_seed

	_build_districts()
	_build_streets(rng)
	_build_bridges()
	_build_landmarks()
	_build_venues(rng)
	_build_metro()
	_build_safehouses(rng)

	_built = true
	atlas_built.emit(_locations.size())
	Log.info("CityAtlas", "Атлас города собран", {
		"seed": city_seed,
		"районов": _districts.size(),
		"локаций": _locations.size(),
		"мостов": _bridges.size(),
		"убежищ": _safehouses.size(),
		"площадь_км2": "%.2f" % (WORLD_HALF_X * 2.0 * WORLD_HALF_Z * 2.0 / 1_000_000.0),
	})


func is_built() -> bool:
	return _built


# ---------------------------------------------------------------- сборка

func _build_districts() -> void:
	for row: Dictionary in DISTRICT_TABLE:
		var rect_data: Array = row["rect"]
		var entry: Dictionary = row.duplicate(true)
		entry["bounds"] = Rect2(float(rect_data[0]), float(rect_data[1]), float(rect_data[2]), float(rect_data[3]))
		entry["height_min"] = float((row["height"] as Array)[0])
		entry["height_max"] = float((row["height"] as Array)[1])
		var id: String = str(row["id"])
		_districts[id] = entry
		_district_order.append(id)
		_locations_by_district[id] = [] as Array[String]


func _build_streets(rng: RandomNumberGenerator) -> void:
	for id: String in _district_order:
		var d: Dictionary = _districts[id]
		var bounds: Rect2 = d["bounds"]
		var block: float = float(d["block"])
		var ns: Array[Dictionary] = []
		var ew: Array[Dictionary] = []

		var used: Dictionary = {}
		var x: float = bounds.position.x
		while x <= bounds.end.x:
			ns.append({"axis": "ns", "coord": x, "name": _unique_street_name(rng, used)})
			x += block + float(d["street"])
		var z: float = bounds.position.y
		while z <= bounds.end.y:
			ew.append({"axis": "ew", "coord": z, "name": _unique_street_name(rng, used)})
			z += block + float(d["street"])

		_streets[id] = {"ns": ns, "ew": ew}


func _unique_street_name(rng: RandomNumberGenerator, used: Dictionary) -> String:
	for _attempt: int in range(24):
		var candidate: String = "%s %s" % [
			STREET_FIRST[rng.randi_range(0, STREET_FIRST.size() - 1)],
			STREET_SUFFIX[rng.randi_range(0, STREET_SUFFIX.size() - 1)],
		]
		if not used.has(candidate):
			used[candidate] = true
			return candidate
	# Гарантированный выход: детерминированный суффикс вместо бесконечного цикла.
	var forced: String = "%s %s %d" % [
		STREET_FIRST[rng.randi_range(0, STREET_FIRST.size() - 1)],
		STREET_SUFFIX[rng.randi_range(0, STREET_SUFFIX.size() - 1)],
		used.size(),
	]
	used[forced] = true
	return forced


func _build_bridges() -> void:
	for row: Dictionary in BRIDGE_TABLE:
		var z: float = float(row["z"])
		var center_x: float = _river_x_at_z(z)
		var entry: Dictionary = row.duplicate(true)
		entry["center"] = Vector2(center_x, z)
		entry["from"] = Vector2(center_x - RIVER_WIDTH * 0.5 - 70.0, z)
		entry["to"] = Vector2(center_x + RIVER_WIDTH * 0.5 + 70.0, z)
		_bridges.append(entry)


func _build_landmarks() -> void:
	for row: Dictionary in LANDMARK_TABLE:
		var pos_data: Array = row["pos"]
		var pos := Vector2(float(pos_data[0]), float(pos_data[1]))
		var district_id: String = district_at(pos).get("id", "outskirts")
		var loc: Dictionary = {
			"id": str(row["id"]),
			"name": str(row["name"]),
			"ru": str(row["ru"]),
			"kind": int(row["kind"]),
			"district": district_id,
			"position": pos,
			"floors": int(row["floors"]),
			"has_camera": bool(row["camera"]),
			"lock_level": int(row["lock"]),
			"is_landmark": true,
			"is_public": int(row["lock"]) <= 1,
			"open_hour": 0,
			"close_hour": 24,
			"address": address_for_point(pos),
		}
		_register_location(loc)


func _build_venues(rng: RandomNumberGenerator) -> void:
	for id: String in _district_order:
		var d: Dictionary = _districts[id]
		var count: int = int(d["venues"])
		var weights: Dictionary = VENUE_WEIGHTS.get(str(d["profile"]), VENUE_WEIGHTS["outskirts"])
		var used_names: Dictionary = {}

		for index: int in range(count):
			var kind: int = _weighted_pick(weights, rng)
			var pos: Vector2 = _scatter_point(d, rng)
			# Не ставим заведение прямо на landmark.
			if _too_close_to_landmark(pos, 40.0):
				pos = _scatter_point(d, rng)

			var floors: int = _floors_for(kind, d, rng)
			var lock: int = _lock_for(kind, d, rng)
			var loc: Dictionary = {
				"id": "%s_%02d" % [id, index],
				"name": _venue_name(kind, rng, used_names),
				"ru": str(KIND_NAMES.get(kind, "Локация")),
				"kind": kind,
				"district": id,
				"position": pos,
				"floors": floors,
				"has_camera": _camera_for(kind, d, rng),
				"lock_level": lock,
				"is_landmark": false,
				"is_public": lock <= 1,
				"open_hour": _open_hour_for(kind),
				"close_hour": _close_hour_for(kind),
				"address": address_for_point(pos),
			}
			_register_location(loc)


func _build_metro() -> void:
	# Подземная сеть: все станции сцеплены в кольцо + связка через реку.
	var stations: Array[Dictionary] = []
	for loc_id: Variant in _locations_by_kind.get(LocationKind.TRANSIT_STATION, []):
		var loc: Dictionary = _locations[str(loc_id)]
		stations.append({"location_id": str(loc_id), "position": loc["position"], "district": loc["district"]})

	if stations.size() < 2:
		Log.warn("CityAtlas", "Станций слишком мало для метро — сеть не построена", {"станций": stations.size()})
		return

	stations.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: Vector2 = a["position"]
		var pb: Vector2 = b["position"]
		return atan2(pa.y, pa.x) < atan2(pb.y, pb.x)
	)

	for i: int in range(stations.size()):
		var next: Dictionary = stations[(i + 1) % stations.size()]
		var here: Dictionary = stations[i]
		var pa: Vector2 = here["position"]
		var pb: Vector2 = next["position"]
		_metro.append({
			"from": here["location_id"],
			"to": next["location_id"],
			"length_m": pa.distance_to(pb),
			"travel_sec": clampf(pa.distance_to(pb) / 22.0, 20.0, 180.0),
		})
	Log.debug("CityAtlas", "Подземная сеть построена", {"станций": stations.size(), "перегонов": _metro.size()})


func _build_safehouses(rng: RandomNumberGenerator) -> void:
	# Ровно 15, как на панели MAP INFO референса.
	var candidates: Array[String] = []
	for loc_id: Variant in _locations_by_kind.get(LocationKind.APARTMENTS, []):
		candidates.append(str(loc_id))
	if candidates.is_empty():
		Log.warn("CityAtlas", "Нет жилых домов — убежища не расставлены")
		return

	# По одному на район, затем добор случайными, чтобы вышло 15.
	var per_district: Dictionary = {}
	for loc_id: String in candidates:
		var district_id: String = str(_locations[loc_id]["district"])
		if not per_district.has(district_id):
			per_district[district_id] = loc_id
	for value: Variant in per_district.values():
		if _safehouses.size() >= 15:
			break
		_safehouses.append(str(value))

	var guard: int = 0
	while _safehouses.size() < 15 and guard < 500:
		guard += 1
		var pick: String = candidates[rng.randi_range(0, candidates.size() - 1)]
		if not _safehouses.has(pick):
			_safehouses.append(pick)

	for loc_id: String in _safehouses:
		(_locations[loc_id] as Dictionary)["is_safehouse"] = true


func _register_location(loc: Dictionary) -> void:
	var id: String = str(loc["id"])
	if _locations.has(id):
		Log.warn("CityAtlas", "Дубликат location_id — переименован", {"id": id})
		id = id + "_b"
		loc["id"] = id
	_locations[id] = loc

	var district_id: String = str(loc["district"])
	if not _locations_by_district.has(district_id):
		_locations_by_district[district_id] = [] as Array[String]
	(_locations_by_district[district_id] as Array).append(id)

	var kind: int = int(loc["kind"])
	if not _locations_by_kind.has(kind):
		_locations_by_kind[kind] = [] as Array[String]
	(_locations_by_kind[kind] as Array).append(id)


# ------------------------------------------------------------- геометрия/запросы

func world_bounds() -> Rect2:
	return Rect2(-WORLD_HALF_X, -WORLD_HALF_Z, WORLD_HALF_X * 2.0, WORLD_HALF_Z * 2.0)


func world_area_km2() -> float:
	return WORLD_HALF_X * 2.0 * WORLD_HALF_Z * 2.0 / 1_000_000.0


func district_ids() -> Array[String]:
	return _district_order.duplicate()


func get_district(id: String) -> Dictionary:
	var d: Variant = _districts.get(id, null)
	return (d as Dictionary).duplicate(true) if d is Dictionary else {}


## Район в точке плана. Никогда не возвращает пустой словарь: Outskirts —
## гарантированный fallback, поскольку его прямоугольник равен всему миру.
func district_at(point: Vector2) -> Dictionary:
	for id: String in _district_order:
		var d: Dictionary = _districts[id]
		var bounds: Rect2 = d["bounds"]
		if bounds.has_point(point):
			return d
	return _districts.get("outskirts", {})


func district_at_world(point: Vector3) -> Dictionary:
	return district_at(Vector2(point.x, point.z))


func random_point_in_district(id: String, rng: RandomNumberGenerator) -> Vector2:
	var d: Variant = _districts.get(id, null)
	if not (d is Dictionary):
		Log.warn("CityAtlas", "Запрошена точка в неизвестном районе", {"id": id})
		return Vector2.ZERO
	return _scatter_point(d as Dictionary, rng)


func river_points() -> Array[Vector2]:
	return RIVER_POINTS.duplicate()


func river_width() -> float:
	return RIVER_WIDTH


## X-координата осевой линии реки на заданном Z (линейная интерполяция ломаной).
func _river_x_at_z(z: float) -> float:
	if RIVER_POINTS.is_empty():
		return 0.0
	if z <= RIVER_POINTS[0].y:
		return RIVER_POINTS[0].x
	for i: int in range(RIVER_POINTS.size() - 1):
		var a: Vector2 = RIVER_POINTS[i]
		var b: Vector2 = RIVER_POINTS[i + 1]
		if z >= a.y and z <= b.y:
			var span: float = b.y - a.y
			if absf(span) < 0.0001:
				return b.x
			return lerpf(a.x, b.x, (z - a.y) / span)
	return RIVER_POINTS[RIVER_POINTS.size() - 1].x


func is_in_river(point: Vector2) -> bool:
	return absf(point.x - _river_x_at_z(point.y)) <= RIVER_WIDTH * 0.5


func is_across_river(point: Vector2) -> bool:
	return point.x > _river_x_at_z(point.y) + RIVER_WIDTH * 0.5


func distance_to_river(point: Vector2) -> float:
	return maxf(0.0, absf(point.x - _river_x_at_z(point.y)) - RIVER_WIDTH * 0.5)


func bridges() -> Array[Dictionary]:
	return _bridges.duplicate(true)


func nearest_bridge(point: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_dist: float = INF
	for b: Dictionary in _bridges:
		var center: Vector2 = b["center"]
		var dist: float = center.distance_to(point)
		if dist < best_dist:
			best_dist = dist
			best = b
	return best.duplicate(true)


## Плотность тумана 0..1: растёт к краям карты и у воды (как на референсах).
func fog_density_at(point: Vector2) -> float:
	var edge_x: float = clampf(absf(point.x) / WORLD_HALF_X, 0.0, 1.0)
	var edge_z: float = clampf(absf(point.y) / WORLD_HALF_Z, 0.0, 1.0)
	var edge: float = maxf(edge_x, edge_z)
	var water: float = clampf(1.0 - distance_to_river(point) / 600.0, 0.0, 1.0)
	var district_bonus: float = float(district_at(point).get("fog", 0.8))
	return clampf(0.22 + edge * 0.5 + water * 0.35, 0.0, 1.0) * district_bonus


func palette(key: String) -> Color:
	var c: Variant = PALETTE.get(key, null)
	if c is Color:
		return c
	Log.warn("CityAtlas", "Неизвестный цвет палитры", {"ключ": key})
	return Color.MAGENTA


func district_palette(id: String) -> Array[Color]:
	var out: Array[Color] = []
	var d: Variant = _districts.get(id, null)
	if not (d is Dictionary):
		return out
	for key: Variant in ((d as Dictionary).get("palette", []) as Array):
		out.append(palette(str(key)))
	return out


# ------------------------------------------------------------------- локации

func location_ids() -> Array[String]:
	var out: Array[String] = []
	for key: Variant in _locations.keys():
		out.append(str(key))
	return out


func location_count() -> int:
	return _locations.size()


func get_location(id: String) -> Dictionary:
	var loc: Variant = _locations.get(id, null)
	return (loc as Dictionary).duplicate(true) if loc is Dictionary else {}


func has_location(id: String) -> bool:
	return _locations.has(id)


func locations_in_district(district_id: String) -> Array[String]:
	var raw: Variant = _locations_by_district.get(district_id, null)
	var out: Array[String] = []
	if raw is Array:
		for v: Variant in raw as Array:
			out.append(str(v))
	return out


func locations_of_kind(kind: int) -> Array[String]:
	var raw: Variant = _locations_by_kind.get(kind, null)
	var out: Array[String] = []
	if raw is Array:
		for v: Variant in raw as Array:
			out.append(str(v))
	return out


func safehouses() -> Array[String]:
	return _safehouses.duplicate()


func metro_links() -> Array[Dictionary]:
	return _metro.duplicate(true)


## Мировая позиция локации. Y=0 — уровень улицы (Фаза 2 подставит рельеф).
func location_world_position(id: String) -> Vector3:
	var loc: Variant = _locations.get(id, null)
	if not (loc is Dictionary):
		Log.warn("CityAtlas", "Позиция запрошена для неизвестной локации", {"id": id})
		return Vector3.ZERO
	var p: Vector2 = (loc as Dictionary)["position"]
	return Vector3(p.x, 0.0, p.y)


## Все локации, попадающие в прямоугольник плана. Используется генератором
## чанков: landmark'и и адресные здания обязаны встать точно на свои места.
func locations_in_rect(rect: Rect2) -> Array[String]:
	var out: Array[String] = []
	for key: Variant in _locations.keys():
		var loc: Dictionary = _locations[key]
		var p: Vector2 = loc["position"]
		if rect.has_point(p):
			out.append(str(key))
	return out


func nearest_location(point: Vector2, kind_filter: int = -1) -> String:
	var best_id: String = ""
	var best_dist: float = INF
	for key: Variant in _locations.keys():
		var loc: Dictionary = _locations[key]
		if kind_filter >= 0 and int(loc["kind"]) != kind_filter:
			continue
		var p: Vector2 = loc["position"]
		var dist: float = p.distance_to(point)
		if dist < best_dist:
			best_dist = dist
			best_id = str(key)
	return best_id


## Человекочитаемый адрес точки — используется в описаниях улик и рапортах.
func address_for_point(point: Vector2) -> String:
	var d: Dictionary = district_at(point)
	if d.is_empty():
		return "неустановленный адрес"
	var district_id: String = str(d["id"])
	var grid: Variant = _streets.get(district_id, null)
	if not (grid is Dictionary):
		return "%s, координаты %d/%d" % [str(d["ru"]), int(point.x), int(point.y)]

	var streets: Array = (grid as Dictionary)["ew"]
	var best_name: String = ""
	var best_dist: float = INF
	for s: Dictionary in streets:
		var dist: float = absf(float(s["coord"]) - point.y)
		if dist < best_dist:
			best_dist = dist
			best_name = str(s["name"])
	if best_name.is_empty():
		return str(d["ru"])

	var bounds: Rect2 = d["bounds"]
	var number: int = 1 + int(absf(point.x - bounds.position.x) / 6.0)
	return "%d %s, %s" % [number, best_name, str(d["ru"])]


func street_names(district_id: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var grid: Variant = _streets.get(district_id, null)
	if not (grid is Dictionary):
		return out
	for axis: String in ["ns", "ew"]:
		for s: Dictionary in ((grid as Dictionary)[axis] as Array):
			out.append(str(s["name"]))
	return out


# -------------------------------------------------------------------- утилиты

func _scatter_point(d: Dictionary, rng: RandomNumberGenerator) -> Vector2:
	var bounds: Rect2 = d["bounds"]
	var inset: float = minf(60.0, minf(bounds.size.x, bounds.size.y) * 0.15)
	for _attempt: int in range(16):
		var p := Vector2(
			rng.randf_range(bounds.position.x + inset, bounds.end.x - inset),
			rng.randf_range(bounds.position.y + inset, bounds.end.y - inset)
		)
		if not is_in_river(p):
			return p
	# Детерминированный fallback: центр района, сдвинутый от воды.
	var center: Vector2 = bounds.get_center()
	if is_in_river(center):
		center.x = _river_x_at_z(center.y) - RIVER_WIDTH
	return center


func _too_close_to_landmark(point: Vector2, radius: float) -> bool:
	for row: Dictionary in LANDMARK_TABLE:
		var pos_data: Array = row["pos"]
		if point.distance_to(Vector2(float(pos_data[0]), float(pos_data[1]))) < radius:
			return true
	return false


func _weighted_pick(weights: Dictionary, rng: RandomNumberGenerator) -> int:
	var total: int = 0
	for value: Variant in weights.values():
		total += int(value)
	if total <= 0:
		return LocationKind.APARTMENTS
	var roll: int = rng.randi_range(1, total)
	for key: Variant in weights.keys():
		roll -= int(weights[key])
		if roll <= 0:
			return int(key)
	return int(weights.keys()[0])


func _venue_name(kind: int, rng: RandomNumberGenerator, used: Dictionary) -> String:
	for _attempt: int in range(20):
		var candidate: String = "The %s %s" % [
			VENUE_PREFIX[rng.randi_range(0, VENUE_PREFIX.size() - 1)],
			VENUE_NOUN[rng.randi_range(0, VENUE_NOUN.size() - 1)],
		]
		if not used.has(candidate):
			used[candidate] = true
			return candidate
	var forced: String = "%s No.%d" % [str(KIND_NAMES.get(kind, "Site")), used.size() + 1]
	used[forced] = true
	return forced


func _floors_for(kind: int, d: Dictionary, rng: RandomNumberGenerator) -> int:
	var h_min: float = float(d["height_min"])
	var h_max: float = float(d["height_max"])
	match kind:
		LocationKind.APARTMENTS, LocationKind.HOTEL, LocationKind.GOVERNMENT:
			return maxi(2, int(rng.randf_range(h_min, h_max) / 3.4))
		LocationKind.WAREHOUSE, LocationKind.DOCK, LocationKind.MARKET:
			return rng.randi_range(1, 3)
		LocationKind.PARK, LocationKind.PARKING_STREET, LocationKind.BRIDGE:
			return 1
		LocationKind.PARKING_GARAGE:
			return rng.randi_range(3, 8)
		_:
			return rng.randi_range(1, 4)


func _lock_for(kind: int, d: Dictionary, rng: RandomNumberGenerator) -> int:
	var wealth: float = float(d["wealth"])
	match kind:
		LocationKind.PARK, LocationKind.PARKING_STREET, LocationKind.BRIDGE, LocationKind.MARKET:
			return 0
		LocationKind.SHOP, LocationKind.RESTAURANT, LocationKind.BAR_CLUB, LocationKind.TRANSIT_STATION:
			return 1
		LocationKind.APARTMENTS:
			return clampi(1 + int(wealth * 3.0) + rng.randi_range(0, 1), 1, 5)
		LocationKind.GOVERNMENT, LocationKind.POLICE_STATION, LocationKind.HOSPITAL:
			return clampi(3 + rng.randi_range(0, 2), 3, 5)
		LocationKind.WAREHOUSE, LocationKind.DOCK:
			return clampi(2 + rng.randi_range(0, 2), 2, 4)
		LocationKind.GATED_COMMUNITY:
			return 5
		_:
			return clampi(1 + rng.randi_range(0, 2), 1, 4)


func _camera_for(kind: int, d: Dictionary, rng: RandomNumberGenerator) -> bool:
	var base: float = clampf(float(d["wealth"]) * 0.8 + 0.15, 0.05, 0.95)
	match kind:
		LocationKind.POLICE_STATION, LocationKind.GOVERNMENT, LocationKind.HOSPITAL, LocationKind.PARKING_GARAGE:
			return true
		LocationKind.PARK, LocationKind.PARKING_STREET, LocationKind.DANGER_ZONE:
			return rng.randf() < base * 0.2
		_:
			return rng.randf() < base


func _open_hour_for(kind: int) -> int:
	match kind:
		LocationKind.BAR_CLUB, LocationKind.ENTERTAINMENT:
			return 19
		LocationKind.RESTAURANT:
			return 8
		LocationKind.SHOP, LocationKind.MARKET:
			return 9
		LocationKind.GOVERNMENT, LocationKind.SCHOOL:
			return 8
		LocationKind.WAREHOUSE, LocationKind.DOCK:
			return 6
		_:
			return 0


func _close_hour_for(kind: int) -> int:
	match kind:
		LocationKind.BAR_CLUB, LocationKind.ENTERTAINMENT:
			return 4
		LocationKind.RESTAURANT:
			return 23
		LocationKind.SHOP, LocationKind.MARKET:
			return 21
		LocationKind.GOVERNMENT, LocationKind.SCHOOL:
			return 18
		LocationKind.WAREHOUSE, LocationKind.DOCK:
			return 22
		_:
			return 24


## Компактная сводка города для системного промпта LLM (Фаза 1).
func digest_for_llm(max_locations: int = 40) -> Dictionary:
	var districts_out: Array[Dictionary] = []
	for id: String in _district_order:
		var d: Dictionary = _districts[id]
		districts_out.append({
			"id": id,
			"name": str(d["name"]),
			"crime_rate": float(d["crime"]),
			"wealth": float(d["wealth"]),
			"police_response_sec": float(d["police_sec"]),
			"across_river": bool(d["across_river"]),
		})

	var locs_out: Array[Dictionary] = []
	var keys: Array = _locations.keys()
	var step: int = maxi(1, int(ceil(float(keys.size()) / float(maxi(1, max_locations)))))
	var i: int = 0
	while i < keys.size() and locs_out.size() < max_locations:
		var loc: Dictionary = _locations[keys[i]]
		locs_out.append({
			"id": str(loc["id"]),
			"name": str(loc["name"]),
			"kind": str(KIND_NAMES.get(int(loc["kind"]), "site")),
			"district": str(loc["district"]),
			"has_camera": bool(loc["has_camera"]),
			"lock_level": int(loc["lock_level"]),
			"address": str(loc["address"]),
		})
		i += step

	return {
		"area_km2": world_area_km2(),
		"districts": districts_out,
		"landmarks_and_locations": locs_out,
		"total_locations": _locations.size(),
	}
