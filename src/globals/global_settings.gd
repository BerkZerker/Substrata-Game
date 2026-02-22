extends Node

const CHUNK_SIZE: int = 32 # Size of each chunk in tiles (chunk is square)
const REGION_SIZE: int = 4 # Number of chunks per region side (region is square)
const LOD_RADIUS: int = 4 # How many regions to generate around the player
const REMOVAL_BUFFER: int = 2 # How many extra regions to add to the LOD_RADIUS for removal purposes
const MAX_CHUNK_BUILDS_PER_FRAME: int = 16 # Max number of chunks to build per frame
const MAX_CHUNK_REMOVALS_PER_FRAME: int = 32 # Max number of chunks to remove per frame
const MAX_BUILD_QUEUE_SIZE: int = 128 # Max chunks waiting to be built (backpressure threshold)
const MAX_CHUNK_POOL_SIZE: int = 512 # Max number of chunks to keep in the pool for reuse
const MAX_CONCURRENT_GENERATION_TASKS: int = 8 # Max parallel chunk generation tasks in WorkerThreadPool
const MAX_LIGHT: int = 80 # Maximum light level (gives ~79 tile range through air, ~39 through stone)