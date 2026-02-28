class_name GameInstance extends Node


@onready var chunk_manager: ChunkManager = $ChunkManager
@onready var entity_manager: EntityManager = $EntityManager

var _save_manager: WorldSaveManager
var _light_manager: LightManager


func _ready() -> void:
	# Register core services
	GameServices.chunk_manager = chunk_manager
	GameServices.entity_manager = entity_manager
	GameServices.tile_registry = TileIndex
	GameServices.terrain_generator = chunk_manager.get_terrain_generator()

	# Set up persistence
	_save_manager = WorldSaveManager.new()
	GameServices.world_save_manager = _save_manager
	chunk_manager.setup_persistence(_save_manager, str(chunk_manager.world_seed))

	# Set up dynamic lighting
	_light_manager = LightManager.new()
	_light_manager.name = "LightManager"
	_light_manager.setup(chunk_manager)
	add_child(_light_manager)
	GameServices.light_manager = _light_manager
