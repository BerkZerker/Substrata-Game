## Global event bus for decoupled communication between systems.
extends Node

@warning_ignore_start("unused_signal")

signal player_chunk_changed(new_chunk_pos: Vector2i)

signal tile_changed(world_pos: Vector2, old_tile_id: int, new_tile_id: int)
signal chunk_loaded(chunk_pos: Vector2i)
signal chunk_unloaded(chunk_pos: Vector2i)
signal world_ready()
signal world_saving()
signal world_saved()

signal entity_spawned(entity: Node2D)
signal entity_despawned(entity: Node2D)
signal entity_chunk_changed(entity: Node2D, old_chunk: Vector2i, new_chunk: Vector2i)

signal light_level_changed(chunk_pos: Vector2i)
