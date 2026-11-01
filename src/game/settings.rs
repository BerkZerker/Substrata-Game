/// World and gameplay constants ported 1:1 from `src/globals/global_settings.gd`.
pub const CHUNK_SIZE: i32 = 32;
pub const CHUNK_SIZE_U32: u32 = 32;
pub const CHUNK_BYTE_LEN: usize = (CHUNK_SIZE as usize) * (CHUNK_SIZE as usize) * 2;
pub const CHUNK_LIGHT_BYTE_LEN: usize = (CHUNK_SIZE as usize) * (CHUNK_SIZE as usize) * 4;
pub const PADDED_CHUNK_LIGHT_SIZE: u32 = CHUNK_SIZE_U32 + 2;
pub const PADDED_CHUNK_LIGHT_BYTE_LEN: usize =
    (PADDED_CHUNK_LIGHT_SIZE as usize) * (PADDED_CHUNK_LIGHT_SIZE as usize) * 4;

// Lighting
pub const MAX_STATIC_LIGHT_RADIUS: i32 = 44;
pub const DYN_LIGHT_STAMP_SIZE: i32 = 128;
pub const DYN_LIGHT_STAMP_SIZE_U32: u32 = 128;
pub const MAX_DYNAMIC_LIGHTS: usize = 8;

pub const REGION_SIZE: i32 = 4;
pub const LOD_RADIUS: i32 = 4;
pub const REMOVAL_BUFFER: i32 = 2;

pub const MAX_CHUNK_BUILDS_PER_FRAME: usize = 16;
pub const MAX_CHUNK_REMOVALS_PER_FRAME: usize = 32;
pub const MAX_BUILD_QUEUE_SIZE: usize = 128;

pub const MAX_CHUNK_POOL_SIZE: usize =
    ((2 * LOD_RADIUS + 1) * (2 * LOD_RADIUS + 1) * REGION_SIZE * REGION_SIZE) as usize;
pub const MAX_CONCURRENT_GENERATION_TASKS: usize = 8;

// Terrain editing
pub const MAX_FLOOD_FILL_RADIUS: i32 = 64;
pub const ORPHAN_CLUSTER_THRESHOLD: usize = 10;
pub const DEFAULT_BRUSH_VALUE: i32 = 10;
pub const MAX_BRUSH_VALUE: i32 = 50;
pub const FORCE_DECAY_PER_TILE: f32 = 0.85;
pub const FORCE_DISTANCE_FACTOR: f32 = 1.5;
