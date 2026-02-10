class_name GameInstance extends Node


@onready var chunk_manager: ChunkManager = $ChunkManager


func _ready() -> void:
	GameServices.chunk_manager = chunk_manager
