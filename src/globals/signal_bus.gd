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

## Emitted by TerrainEditController when the selected placement material changes
## (via hotbar click or number key), so the hotbar can update its highlight.
signal material_selected(tile_id: int)
## Emitted by TerrainEditController when the unified dig-force/place-radius value
## changes (Q/E), so the hotbar readout and world brush preview can redraw.
signal brush_value_changed(value: float)
