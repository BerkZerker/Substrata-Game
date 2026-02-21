class_name GameInstance extends Node


@onready var chunk_manager: ChunkManager = $ChunkManager

var _save_manager: WorldSaveManager


func _ready() -> void:
	GameServices.chunk_manager = chunk_manager

	# Set up persistence
	_save_manager = WorldSaveManager.new()
	chunk_manager.setup_persistence(_save_manager, "default")
