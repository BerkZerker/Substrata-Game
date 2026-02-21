## Abstract base class for terrain generators.
##
## All terrain generators must extend this class and implement generate_chunk().
## Generators run in worker threads — they must NOT call Godot scene tree APIs.
class_name BaseTerrainGenerator extends RefCounted


## Generates terrain data for a chunk at the given position.
## Returns a PackedByteArray with 2 bytes per tile: [tile_id, cell_id].
## Size must be CHUNK_SIZE * CHUNK_SIZE * 2.
func generate_chunk(_chunk_pos: Vector2i) -> PackedByteArray:
	push_error("BaseTerrainGenerator.generate_chunk() must be overridden by subclass")
	return PackedByteArray()


## Returns a human-readable name for this generator type.
func get_generator_name() -> String:
	return "base"
