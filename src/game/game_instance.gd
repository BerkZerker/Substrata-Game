class_name GameInstance extends Node


@onready var chunk_manager: ChunkManager = $ChunkManager
@onready var entity_manager: EntityManager = $EntityManager

var _save_manager: WorldSaveManager


func _ready() -> void:
	# Register core services
	GameServices.chunk_manager = chunk_manager
	GameServices.entity_manager = entity_manager
	GameServices.tile_registry = TileIndex
	GameServices.terrain_generator = chunk_manager.get_terrain_generator()

	# Set up persistence
	_save_manager = WorldSaveManager.new()
	GameServices.world_save_manager = _save_manager
	chunk_manager.setup_persistence(_save_manager, "default")

	# Set up lighting
	var light_mgr = LightManager.new()
	light_mgr.setup(chunk_manager)
	GameServices.light_manager = light_mgr

	# Set up dynamic lights
	var dyn_light_mgr = DynamicLightManager.new()
	dyn_light_mgr.name = "DynamicLightManager"
	add_child(dyn_light_mgr)
	GameServices.dynamic_light_manager = dyn_light_mgr

	# Set up tile simulation (falling sand, etc.)
	var tile_sim = TileSimulation.new()
	tile_sim.name = "TileSimulation"
	tile_sim.setup(chunk_manager)
	add_child(tile_sim)

	# Set up tile growth (grass spreading, vine growth)
	var tile_growth = TileGrowthSystem.new()
	tile_growth.name = "TileGrowthSystem"
	add_child(tile_growth)
