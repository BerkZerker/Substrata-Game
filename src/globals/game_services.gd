extends Node

# Central registry for game systems. Populated by GameInstance on startup.
# Other scripts access shared services through this autoload instead of
# requiring manual wiring via setup methods.

var chunk_manager: ChunkManager = null
