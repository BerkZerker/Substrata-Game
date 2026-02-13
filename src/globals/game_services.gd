extends Node

## Central registry for game systems. Populated by GameInstance on startup.
##
## Other scripts access shared services through this autoload instead of
## requiring manual wiring via setup methods.

## Reference to the active ChunkManager, set by GameInstance._ready().
var chunk_manager: ChunkManager = null
