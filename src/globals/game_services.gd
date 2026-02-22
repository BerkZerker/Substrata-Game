extends Node

## Central registry for game systems. Populated by GameInstance on startup.
##
## Other scripts access shared services through this autoload instead of
## requiring manual wiring via setup methods.

## Reference to the active ChunkManager, set by GameInstance._ready().
var chunk_manager: ChunkManager = null

## Reference to the TileIndex autoload (typed as Node since TileIndex has no class_name).
var tile_registry: Node = null

## Reference to the active terrain generator used by ChunkLoader.
var terrain_generator: RefCounted = null

## Reference to the WorldSaveManager instance.
var world_save_manager: RefCounted = null

## Reference to the EntityManager, set by GameInstance._ready().
var entity_manager: Node = null

## Reference to the LightManager, set by GameInstance._ready().
var light_manager: RefCounted = null

## Reference to the DynamicLightManager, set by GameInstance._ready().
var dynamic_light_manager: Node = null
