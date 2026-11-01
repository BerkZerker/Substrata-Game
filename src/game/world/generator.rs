use fastnoise_lite::{FastNoiseLite, NoiseType};
use glam::IVec2;
use serde::{Deserialize, Serialize};

use crate::game::settings::{CHUNK_BYTE_LEN, CHUNK_SIZE};
use crate::game::tiles::{AIR, DIRT, GRASS, STONE};

/// Abstract interface for chunk terrain generators (`src/world/generators/base_terrain_generator.gd`).
pub trait BaseTerrainGenerator: Send + Sync {
    fn generate_chunk(&self, chunk_pos: IVec2) -> Vec<u8>;
    fn get_generator_name(&self) -> &'static str;
    /// Returns the natural terrain surface Y coordinate (in world tiles, +Y down) at `world_x`.
    /// Used by the static lighting baker to determine open-sky columns without requiring high-altitude chunks.
    fn get_surface_height(&self, _world_x: i32) -> i32 {
        0
    }
}

/// Configuration for `SimplexTerrainGenerator` matching `DEFAULT_CONFIG` in
/// `src/world/generators/simplex_terrain_generator.gd`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SimplexConfig {
    pub heightmap_frequency: f32,
    pub detail_frequency: f32,
    pub layer_frequency: f32,
    pub surface_level: f32,
    pub heightmap_amplitude: f32,
    pub detail_amplitude: f32,
    pub grass_depth: i32,
    pub dirt_depth: i32,
    pub layer_variation: f32,
    pub cliff_threshold: f32,
}

impl Default for SimplexConfig {
    fn default() -> Self {
        Self {
            heightmap_frequency: 0.002,
            detail_frequency: 0.008,
            layer_frequency: 0.006,
            surface_level: 0.0,
            heightmap_amplitude: 96.0,
            detail_amplitude: 20.0,
            grass_depth: 4,
            dirt_depth: 20,
            layer_variation: 12.0,
            cliff_threshold: 1.5,
        }
    }
}

/// Layered simplex noise terrain generator ported from
/// `src/world/generators/simplex_terrain_generator.gd`.
pub struct SimplexTerrainGenerator {
    world_seed: i32,
    config: SimplexConfig,
    heightmap_noise: FastNoiseLite,
    detail_noise: FastNoiseLite,
    layer_noise: FastNoiseLite,
}

impl SimplexTerrainGenerator {
    pub fn new(generation_seed: i32, config: SimplexConfig) -> Self {
        let mut heightmap_noise = FastNoiseLite::with_seed(generation_seed);
        heightmap_noise.set_noise_type(Some(NoiseType::OpenSimplex2));
        heightmap_noise.set_frequency(Some(config.heightmap_frequency));

        let mut detail_noise = FastNoiseLite::with_seed(generation_seed.wrapping_add(1));
        detail_noise.set_noise_type(Some(NoiseType::OpenSimplex2));
        detail_noise.set_frequency(Some(config.detail_frequency));

        let mut layer_noise = FastNoiseLite::with_seed(generation_seed.wrapping_add(2));
        layer_noise.set_noise_type(Some(NoiseType::OpenSimplex2));
        layer_noise.set_frequency(Some(config.layer_frequency));

        Self {
            world_seed: generation_seed,
            config,
            heightmap_noise,
            detail_noise,
            layer_noise,
        }
    }

    pub fn world_seed(&self) -> i32 {
        self.world_seed
    }

    pub fn config(&self) -> &SimplexConfig {
        &self.config
    }

    #[inline]
    fn get_surface_y(&self, world_x: f32) -> f32 {
        self.config.surface_level
            + self.heightmap_noise.get_noise_2d(world_x, 0.0) * self.config.heightmap_amplitude
            + self.detail_noise.get_noise_2d(world_x, 0.0) * self.config.detail_amplitude
    }

    #[inline]
    fn get_tile_at(&self, world_x: f32, world_y: f32, surface_y: f32, slope: f32) -> u8 {
        let depth = world_y - surface_y; // Y-down: positive = underground

        if depth < 0.0 {
            return AIR;
        }

        let variation =
            self.layer_noise.get_noise_2d(world_x, world_y) * self.config.layer_variation;

        // Cliff faces: steep slopes don't grow grass
        if slope > self.config.cliff_threshold {
            if depth < (self.config.dirt_depth as f32) + variation {
                return DIRT;
            } else {
                return STONE;
            }
        }

        // Normal terrain: always at least 1 grass tile on surface
        if depth < (1.0f32).max((self.config.grass_depth as f32) + variation) {
            GRASS
        } else if depth < (self.config.dirt_depth as f32) + variation {
            DIRT
        } else {
            STONE
        }
    }
}

impl BaseTerrainGenerator for SimplexTerrainGenerator {
    fn get_generator_name(&self) -> &'static str {
        "simplex"
    }

    fn get_surface_height(&self, world_x: i32) -> i32 {
        self.get_surface_y(world_x as f32).floor() as i32
    }

    fn generate_chunk(&self, chunk_pos: IVec2) -> Vec<u8> {
        let mut data = vec![0u8; CHUNK_BYTE_LEN];
        let origin_x = chunk_pos.x * CHUNK_SIZE;
        let origin_y = chunk_pos.y * CHUNK_SIZE;

        for x in 0..CHUNK_SIZE {
            let world_x = (origin_x + x) as f32;
            let surface_y = self.get_surface_y(world_x);

            // Central difference slope for cliff detection
            let slope =
                (self.get_surface_y(world_x + 1.0) - self.get_surface_y(world_x - 1.0)).abs() / 2.0;

            for y in 0..CHUNK_SIZE {
                let world_y = (origin_y + y) as f32;
                let tile_id = self.get_tile_at(world_x, world_y, surface_y, slope);

                let index = ((y * CHUNK_SIZE + x) * 2) as usize;
                data[index] = tile_id;
                data[index + 1] = 0; // damage_stage (0 = intact)
            }
        }

        data
    }
}
