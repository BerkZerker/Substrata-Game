use glam::{IVec2, Vec2};
use crate::game::settings::{CHUNK_BYTE_LEN, CHUNK_LIGHT_BYTE_LEN, CHUNK_SIZE};

#[derive(Clone, Copy, Debug)]
pub struct LocalTileChange {
    pub x: i32,
    pub y: i32,
    pub tile_id: u8,
    pub damage_stage: u8,
}

/// Individual terrain chunk ported from `src/world/chunks/chunk.gd`.
/// Stores terrain as a 2048-byte buffer (`[tile_id, damage_stage]` per tile),
/// baked static lighting as a 4096-byte buffer (`[r, g, b, sky]` per tile),
/// and holds a slot index in the GPU chunk data & light atlases.
pub struct Chunk {
    pub chunk_pos: IVec2,
    pub position: Vec2,
    pub visible: bool,
    pub atlas_slot: Option<u32>,
    terrain_data: Vec<u8>,
    static_light: Vec<u8>,
    pub light_baked: bool,
}

impl Default for Chunk {
    fn default() -> Self {
        Self::new()
    }
}

impl Chunk {
    pub fn new() -> Self {
        Self {
            chunk_pos: IVec2::ZERO,
            position: Vec2::ZERO,
            visible: false,
            atlas_slot: None,
            terrain_data: Vec::new(),
            static_light: Vec::new(),
            light_baked: false,
        }
    }

    pub fn generate(&mut self, chunk_data: Vec<u8>, chunk_pos: IVec2) {
        self.terrain_data = chunk_data;
        self.chunk_pos = chunk_pos;
        self.position = Vec2::new(
            (chunk_pos.x * CHUNK_SIZE) as f32,
            (chunk_pos.y * CHUNK_SIZE) as f32,
        );
        self.static_light.resize(CHUNK_LIGHT_BYTE_LEN, 0);
        self.static_light.fill(0);
        self.light_baked = false;
    }

    pub fn build(&mut self, atlas_slot: u32) {
        self.atlas_slot = Some(atlas_slot);
        self.visible = true;
    }

    pub fn reset(&mut self) -> Option<u32> {
        self.visible = false;
        self.terrain_data.clear();
        self.static_light.clear();
        self.light_baked = false;
        self.atlas_slot.take()
    }

    pub fn terrain_data(&self) -> &[u8] {
        &self.terrain_data
    }

    pub fn static_light(&self) -> &[u8] {
        &self.static_light
    }

    pub fn static_light_mut(&mut self) -> &mut [u8] {
        if self.static_light.len() < CHUNK_LIGHT_BYTE_LEN {
            self.static_light.resize(CHUNK_LIGHT_BYTE_LEN, 0);
        }
        &mut self.static_light
    }

    pub fn get_light_at(&self, tile_x: i32, tile_y: i32) -> [u8; 4] {
        if tile_x < 0 || tile_x >= CHUNK_SIZE || tile_y < 0 || tile_y >= CHUNK_SIZE {
            return [0, 0, 0, 0];
        }
        let index = ((tile_y * CHUNK_SIZE + tile_x) * 4) as usize;
        if index + 3 >= self.static_light.len() {
            return [0, 0, 0, 0];
        }
        [
            self.static_light[index],
            self.static_light[index + 1],
            self.static_light[index + 2],
            self.static_light[index + 3],
        ]
    }

    pub fn get_terrain_data_copy(&self) -> Vec<u8> {
        self.terrain_data.clone()
    }

    /// Applies a batch of local tile changes `(x, y, tile_id, damage_stage)`.
    /// Returns `true` if any tile was modified so the caller can upload to the GPU atlas.
    pub fn edit_tiles(&mut self, changes: &[LocalTileChange]) -> bool {
        if changes.is_empty() || self.terrain_data.len() < CHUNK_BYTE_LEN {
            return false;
        }

        let mut changed_something = false;
        for change in changes {
            if change.x < 0 || change.x >= CHUNK_SIZE || change.y < 0 || change.y >= CHUNK_SIZE {
                continue;
            }
            let index = ((change.y * CHUNK_SIZE + change.x) * 2) as usize;
            if index + 1 >= self.terrain_data.len() {
                continue;
            }
            self.terrain_data[index] = change.tile_id;
            self.terrain_data[index + 1] = change.damage_stage;
            changed_something = true;
        }

        changed_something
    }

    pub fn get_tiles(&self, positions: &[IVec2]) -> Vec<[u8; 2]> {
        let mut results = Vec::with_capacity(positions.len());
        for &pos in positions {
            results.push(self.get_tile_at(pos.x, pos.y));
        }
        results
    }

    pub fn get_tile_at(&self, tile_x: i32, tile_y: i32) -> [u8; 2] {
        if tile_x < 0 || tile_x >= CHUNK_SIZE || tile_y < 0 || tile_y >= CHUNK_SIZE {
            return [0, 0];
        }
        let index = ((tile_y * CHUNK_SIZE + tile_x) * 2) as usize;
        if index + 1 >= self.terrain_data.len() {
            return [0, 0];
        }
        [self.terrain_data[index], self.terrain_data[index + 1]]
    }

    pub fn get_tile_id_at(&self, tile_x: i32, tile_y: i32) -> u8 {
        if tile_x < 0 || tile_x >= CHUNK_SIZE || tile_y < 0 || tile_y >= CHUNK_SIZE {
            return 0;
        }
        let index = ((tile_y * CHUNK_SIZE + tile_x) * 2) as usize;
        if index >= self.terrain_data.len() {
            return 0;
        }
        self.terrain_data[index]
    }
}
