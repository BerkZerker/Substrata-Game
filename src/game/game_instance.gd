class_name GameInstance extends Node


@onready var chunk_manager: ChunkManager = $ChunkManager
@onready var entity_manager: EntityManager = $EntityManager
@onready var terrain_edit_controller: TerrainEditController = $TerrainEditController

var _save_manager: WorldSaveManager


func _ready() -> void:
	# Register core services
	GameServices.chunk_manager = chunk_manager
	GameServices.entity_manager = entity_manager
	GameServices.tile_registry = TileIndex
	GameServices.terrain_generator = chunk_manager.get_terrain_generator()
	GameServices.terrain_edit_controller = terrain_edit_controller

	# Set up persistence
	_save_manager = WorldSaveManager.new()
	GameServices.world_save_manager = _save_manager
	chunk_manager.setup_persistence(_save_manager, str(chunk_manager.world_seed))
