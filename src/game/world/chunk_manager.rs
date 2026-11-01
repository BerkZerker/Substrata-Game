use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use glam::{IVec2, Vec2};
use serde_json::json;

use crate::engine::renderer::chunk_pass::{ChunkInstance, ChunkPass};
use crate::engine::renderer::Renderer;
use crate::game::settings::{
    CHUNK_SIZE, LOD_RADIUS, MAX_CHUNK_BUILDS_PER_FRAME, MAX_CHUNK_POOL_SIZE,
    MAX_CHUNK_REMOVALS_PER_FRAME, REGION_SIZE, REMOVAL_BUFFER,
};
use crate::game::signals::{GameSignal, SignalBus};
use crate::game::tiles::TileRegistry;
use crate::game::world::chunk::{Chunk, LocalTileChange};
use crate::game::world::chunk_loader::ChunkLoader;
use crate::game::world::generator::{
    BaseTerrainGenerator, SimplexConfig, SimplexTerrainGenerator,
};
use crate::game::world::persistence::WorldSaveManager;

#[derive(Clone, Copy, Debug)]
pub struct WorldTileChange {
    pub pos: Vec2,
    pub tile_id: u8,
    pub damage_stage: u8,
}

#[derive(Clone, Debug, Default)]
pub struct ChunkDebugInfo {
    pub loaded_chunks: Vec<IVec2>,
    pub loaded_count: usize,
    pub removal_positions: Vec<IVec2>,
    pub removal_queue_size: usize,
    pub player_chunk: IVec2,
    pub player_region: IVec2,
    pub generation_queue: Vec<IVec2>,
    pub generation_queue_size: usize,
    pub build_queue_size: usize,
    pub in_progress: Vec<IVec2>,
    pub in_progress_size: usize,
    pub active_tasks: usize,
}

/// Manages chunk lifecycle: loading, building, removal, pooling, and persistence.
/// Ported from `src/world/chunks/chunk_manager.gd`.
pub struct ChunkManager {
    pub world_seed: i32,
    chunk_loader: ChunkLoader,
    terrain_generator: Arc<dyn BaseTerrainGenerator>,
    save_manager: Option<WorldSaveManager>,
    world_name: String,
    dirty_chunks: HashSet<IVec2>,

    removal_queue: VecDeque<Chunk>,
    player_region: IVec2,
    player_chunk: IVec2,
    last_sorted_player_chunk: IVec2,
    chunks: HashMap<IVec2, Chunk>,
    chunk_pool: Vec<Chunk>,
    initial_load_complete: bool,
    initial_expected_count: i32,
    has_initialized_region: bool,

    pending_gpu_uploads: HashSet<IVec2>,
}

impl ChunkManager {
    pub fn new(world_seed: i32) -> Self {
        let generator = Arc::new(SimplexTerrainGenerator::new(
            world_seed,
            SimplexConfig::default(),
        ));
        let chunk_loader = ChunkLoader::new(generator.clone());

        let mut chunk_pool = Vec::with_capacity(MAX_CHUNK_POOL_SIZE);
        for _ in 0..MAX_CHUNK_POOL_SIZE {
            chunk_pool.push(Chunk::new());
        }

        Self {
            world_seed,
            chunk_loader,
            terrain_generator: generator,
            save_manager: None,
            world_name: String::new(),
            dirty_chunks: HashSet::new(),
            removal_queue: VecDeque::new(),
            player_region: IVec2::ZERO,
            player_chunk: IVec2::ZERO,
            last_sorted_player_chunk: IVec2::ZERO,
            chunks: HashMap::new(),
            chunk_pool,
            initial_load_complete: false,
            initial_expected_count: -1,
            has_initialized_region: false,
            pending_gpu_uploads: HashSet::new(),
        }
    }

    pub fn get_terrain_generator(&self) -> Arc<dyn BaseTerrainGenerator> {
        Arc::clone(&self.terrain_generator)
    }

    pub fn setup_persistence(&mut self, save_manager: WorldSaveManager, world_name: String) {
        self.save_manager = Some(save_manager);
        self.world_name = world_name;
    }

    /// Main frame tick: processes built chunks, removals, and flushes pending GPU uploads.
    pub fn process(&mut self, renderer: &mut Renderer, signal_bus: &mut SignalBus) {
        self.process_build_queue(renderer, signal_bus);
        self.process_removal_queue(renderer);
        self.flush_pending_gpu_uploads(renderer);
    }

    pub fn flush_pending_gpu_uploads(&mut self, renderer: &mut Renderer) {
        if self.pending_gpu_uploads.is_empty() {
            return;
        }
        let positions: Vec<IVec2> = self.pending_gpu_uploads.drain().collect();
        for chunk_pos in positions {
            let Some(chunk) = self.chunks.get_mut(&chunk_pos) else {
                continue;
            };
            if chunk.atlas_slot.is_none() {
                if let Some(slot) = renderer.chunk_pass.allocate_slot() {
                    chunk.build(slot);
                }
            }
            if let Some(slot) = chunk.atlas_slot {
                renderer
                    .chunk_pass
                    .write_chunk_data(&renderer.queue, slot, chunk.terrain_data());
            }
        }
    }

    fn process_build_queue(&mut self, renderer: &mut Renderer, signal_bus: &mut SignalBus) {
        let build_batch = self
            .chunk_loader
            .get_built_chunks(MAX_CHUNK_BUILDS_PER_FRAME);

        let mut chunks_to_mark_done = Vec::with_capacity(build_batch.len());

        for build_data in build_batch {
            let chunk_pos = build_data.pos;
            let terrain_data = build_data.terrain_data;

            if self.chunks.contains_key(&chunk_pos) {
                chunks_to_mark_done.push(chunk_pos);
                continue;
            }

            if !self.is_chunk_in_valid_range(chunk_pos) {
                chunks_to_mark_done.push(chunk_pos);
                continue;
            }

            let mut chunk = self.get_pooled_chunk();
            chunk.generate(terrain_data, chunk_pos);
            if let Some(slot) = renderer.chunk_pass.allocate_slot() {
                renderer
                    .chunk_pass
                    .write_chunk_data(&renderer.queue, slot, chunk.terrain_data());
                chunk.build(slot);
            }
            self.chunks.insert(chunk_pos, chunk);
            chunks_to_mark_done.push(chunk_pos);
            signal_bus.emit(GameSignal::ChunkLoaded(chunk_pos));
        }

        if !chunks_to_mark_done.is_empty() {
            self.chunk_loader
                .mark_chunks_as_processed(&chunks_to_mark_done);
        }

        if !self.initial_load_complete
            && self.initial_expected_count > 0
            && (self.chunks.len() as i32) >= self.initial_expected_count
        {
            self.initial_load_complete = true;
            signal_bus.emit(GameSignal::WorldReady);
        }
    }

    fn process_removal_queue(&mut self, renderer: &mut Renderer) {
        let mut removals_this_frame = 0;
        while removals_this_frame < MAX_CHUNK_REMOVALS_PER_FRAME {
            let Some(chunk) = self.removal_queue.pop_back() else {
                break;
            };
            self.recycle_chunk(chunk, renderer);
            removals_this_frame += 1;
        }
    }

    pub fn get_chunk_region(chunk_pos: IVec2) -> IVec2 {
        IVec2::new(
            chunk_pos.x.div_euclid(REGION_SIZE),
            chunk_pos.y.div_euclid(REGION_SIZE),
        )
    }

    fn is_chunk_in_valid_range(&self, chunk_pos: IVec2) -> bool {
        let chunk_region = Self::get_chunk_region(chunk_pos);
        let removal_radius = LOD_RADIUS + REMOVAL_BUFFER;
        let min_region = self.player_region - IVec2::splat(removal_radius);
        let max_region = self.player_region + IVec2::splat(removal_radius);

        chunk_region.x >= min_region.x
            && chunk_region.x <= max_region.x
            && chunk_region.y >= min_region.y
            && chunk_region.y <= max_region.y
    }

    fn mark_chunks_for_removal(
        &mut self,
        center_region: IVec2,
        removal_radius: i32,
        signal_bus: &mut SignalBus,
    ) {
        let mut chunks_to_remove = Vec::new();
        for &chunk_pos in self.chunks.keys() {
            let chunk_region = Self::get_chunk_region(chunk_pos);
            if (chunk_region.x - center_region.x).abs() > removal_radius
                || (chunk_region.y - center_region.y).abs() > removal_radius
            {
                chunks_to_remove.push(chunk_pos);
            }
        }

        for chunk_pos in chunks_to_remove {
            if let Some(chunk) = self.chunks.remove(&chunk_pos) {
                if self.dirty_chunks.contains(&chunk_pos) {
                    self.save_dirty_chunk(chunk_pos, &chunk);
                }
                self.pending_gpu_uploads.remove(&chunk_pos);
                self.removal_queue.push_back(chunk);
                signal_bus.emit(GameSignal::ChunkUnloaded(chunk_pos));
            }
        }
    }

    fn queue_chunks_for_generation(
        &mut self,
        center_region: IVec2,
        gen_radius: i32,
        signal_bus: &mut SignalBus,
    ) {
        let mut chunks_to_queue = Vec::new();

        if !self.initial_load_complete && self.initial_expected_count < 0 {
            let gen_diameter = 2 * gen_radius + 1;
            let region_chunks = REGION_SIZE * REGION_SIZE;
            self.initial_expected_count = gen_diameter * gen_diameter * region_chunks;
        }

        for region_x in (center_region.x - gen_radius)..=(center_region.x + gen_radius) {
            for region_y in (center_region.y - gen_radius)..=(center_region.y + gen_radius) {
                let chunk_start_x = region_x * REGION_SIZE;
                let chunk_start_y = region_y * REGION_SIZE;

                for cx in chunk_start_x..(chunk_start_x + REGION_SIZE) {
                    for cy in chunk_start_y..(chunk_start_y + REGION_SIZE) {
                        let chunk_pos = IVec2::new(cx, cy);

                        if self.chunks.contains_key(&chunk_pos) {
                            continue;
                        }

                        // Load synchronously from saved data if available (bypass worker thread)
                        if self.has_saved_chunk(chunk_pos) {
                            if let Some(saved_data) = self.load_chunk_data(chunk_pos) {
                                let mut chunk = self.get_pooled_chunk();
                                chunk.generate(saved_data, chunk_pos);
                                self.chunks.insert(chunk_pos, chunk);
                                self.pending_gpu_uploads.insert(chunk_pos);
                                signal_bus.emit(GameSignal::ChunkLoaded(chunk_pos));
                                continue;
                            }
                        }

                        chunks_to_queue.push(chunk_pos);
                    }
                }
            }
        }

        self.chunk_loader
            .add_chunks_to_generation(&chunks_to_queue, self.player_chunk);
        self.last_sorted_player_chunk = self.player_chunk;
    }

    fn resort_queues(&mut self) {
        let distance_moved = (self.player_chunk - self.last_sorted_player_chunk).length_squared();
        if distance_moved < 4 {
            return;
        }
        self.chunk_loader.resort_queues(self.player_chunk);
        self.last_sorted_player_chunk = self.player_chunk;
    }

    pub fn on_player_chunk_changed(
        &mut self,
        new_player_chunk: IVec2,
        signal_bus: &mut SignalBus,
    ) {
        if self.has_initialized_region && new_player_chunk == self.player_chunk {
            return;
        }

        self.player_chunk = new_player_chunk;
        let new_player_region = Self::get_chunk_region(self.player_chunk);

        if !self.has_initialized_region || new_player_region != self.player_region {
            self.has_initialized_region = true;
            self.player_region = new_player_region;
            self.on_player_region_changed(new_player_region, signal_bus);
        } else {
            self.resort_queues();
        }
    }

    fn on_player_region_changed(&mut self, new_player_region: IVec2, signal_bus: &mut SignalBus) {
        let gen_radius = LOD_RADIUS;
        let removal_radius = LOD_RADIUS + REMOVAL_BUFFER;

        self.mark_chunks_for_removal(new_player_region, removal_radius, signal_bus);
        self.queue_chunks_for_generation(new_player_region, gen_radius, signal_bus);
    }

    fn get_pooled_chunk(&mut self) -> Chunk {
        self.chunk_pool.pop().unwrap_or_default()
    }

    fn recycle_chunk(&mut self, mut chunk: Chunk, renderer: &mut Renderer) {
        if let Some(slot) = chunk.reset() {
            renderer.chunk_pass.free_slot(slot);
        }
        if self.chunk_pool.len() < MAX_CHUNK_POOL_SIZE {
            self.chunk_pool.push(chunk);
        }
    }

    pub fn get_chunk_at(&self, chunk_pos: IVec2) -> Option<&Chunk> {
        self.chunks.get(&chunk_pos)
    }

    pub fn world_to_chunk_pos(world_pos: Vec2) -> IVec2 {
        IVec2::new(
            (world_pos.x / CHUNK_SIZE as f32).floor() as i32,
            (world_pos.y / CHUNK_SIZE as f32).floor() as i32,
        )
    }

    pub fn world_to_tile_pos(world_pos: Vec2) -> IVec2 {
        let tx = (world_pos.x.floor() as i32).rem_euclid(CHUNK_SIZE);
        let ty = (world_pos.y.floor() as i32).rem_euclid(CHUNK_SIZE);
        IVec2::new(tx, ty)
    }

    pub fn is_solid_at_world_pos(&self, world_pos: Vec2, tile_registry: &TileRegistry) -> bool {
        let chunk_pos = Self::world_to_chunk_pos(world_pos);
        let Some(chunk) = self.get_chunk_at(chunk_pos) else {
            return false;
        };
        let tile_pos = Self::world_to_tile_pos(world_pos);
        tile_registry.is_solid(chunk.get_tile_id_at(tile_pos.x, tile_pos.y))
    }

    pub fn get_tile_at_world_pos(&self, world_pos: Vec2) -> [u8; 2] {
        let chunk_pos = Self::world_to_chunk_pos(world_pos);
        let Some(chunk) = self.get_chunk_at(chunk_pos) else {
            return [0, 0];
        };
        let tile_pos = Self::world_to_tile_pos(world_pos);
        chunk.get_tile_at(tile_pos.x, tile_pos.y)
    }

    pub fn get_tiles_at_world_positions(
        &self,
        world_positions: &[Vec2],
    ) -> Vec<(Vec2, [u8; 2])> {
        let mut results = Vec::with_capacity(world_positions.len());
        for &pos in world_positions {
            results.push((pos, self.get_tile_at_world_pos(pos)));
        }
        results
    }

    pub fn set_tiles_at_world_positions(
        &mut self,
        changes: &[WorldTileChange],
        signal_bus: &mut SignalBus,
    ) {
        if changes.is_empty() {
            return;
        }

        struct IndexedLocalChange {
            local: LocalTileChange,
            idx: usize,
        }

        let mut batched: HashMap<IVec2, Vec<IndexedLocalChange>> = HashMap::new();
        for (i, change) in changes.iter().enumerate() {
            let chunk_pos = Self::world_to_chunk_pos(change.pos);
            let tile_pos = Self::world_to_tile_pos(change.pos);
            batched.entry(chunk_pos).or_default().push(IndexedLocalChange {
                local: LocalTileChange {
                    x: tile_pos.x,
                    y: tile_pos.y,
                    tile_id: change.tile_id,
                    damage_stage: change.damage_stage,
                },
                idx: i,
            });
        }

        let mut old_tile_ids = vec![0u8; changes.len()];

        for (chunk_pos, chunk_changes) in batched {
            if let Some(chunk) = self.chunks.get_mut(&chunk_pos) {
                let tile_positions: Vec<IVec2> = chunk_changes
                    .iter()
                    .map(|cc| IVec2::new(cc.local.x, cc.local.y))
                    .collect();
                let old_tiles = chunk.get_tiles(&tile_positions);
                for (j, cc) in chunk_changes.iter().enumerate() {
                    old_tile_ids[cc.idx] = old_tiles[j][0];
                }

                let locals: Vec<LocalTileChange> =
                    chunk_changes.iter().map(|cc| cc.local).collect();
                if chunk.edit_tiles(&locals) {
                    self.dirty_chunks.insert(chunk_pos);
                    self.pending_gpu_uploads.insert(chunk_pos);
                }
            }
        }

        for (i, change) in changes.iter().enumerate() {
            signal_bus.emit(GameSignal::TileChanged {
                world_pos: change.pos,
                old_tile_id: old_tile_ids[i],
                new_tile_id: change.tile_id,
            });
        }
    }

    pub fn collect_visible_chunk_instances(
        &self,
        visible_min: Vec2,
        visible_max: Vec2,
        out: &mut Vec<ChunkInstance>,
    ) {
        out.clear();
        let min_cx = (visible_min.x / CHUNK_SIZE as f32).floor() as i32 - 1;
        let max_cx = (visible_max.x / CHUNK_SIZE as f32).ceil() as i32 + 1;
        let min_cy = (visible_min.y / CHUNK_SIZE as f32).floor() as i32 - 1;
        let max_cy = (visible_max.y / CHUNK_SIZE as f32).ceil() as i32 + 1;

        for (&chunk_pos, chunk) in &self.chunks {
            if !chunk.visible {
                continue;
            }
            if chunk_pos.x < min_cx
                || chunk_pos.x > max_cx
                || chunk_pos.y < min_cy
                || chunk_pos.y > max_cy
            {
                continue;
            }
            if let Some(slot) = chunk.atlas_slot {
                out.push(ChunkInstance {
                    chunk_world_pos: chunk.position.to_array(),
                    atlas_slot: ChunkPass::slot_coords(slot),
                });
            }
        }
    }

    pub fn get_debug_info(&self) -> ChunkDebugInfo {
        let loader_info = self.chunk_loader.get_debug_info();
        let removal_positions: Vec<IVec2> =
            self.removal_queue.iter().map(|c| c.chunk_pos).collect();

        ChunkDebugInfo {
            loaded_chunks: self.chunks.keys().copied().collect(),
            loaded_count: self.chunks.len(),
            removal_positions,
            removal_queue_size: self.removal_queue.len(),
            player_chunk: self.player_chunk,
            player_region: self.player_region,
            generation_queue: loader_info.generation_queue,
            generation_queue_size: loader_info.generation_queue_size,
            build_queue_size: loader_info.build_queue_size,
            in_progress: loader_info.in_progress,
            in_progress_size: loader_info.in_progress_size,
            active_tasks: loader_info.active_tasks,
        }
    }

    // ─── Persistence ─────────────────────────────────────────────────────

    pub fn save_world(&mut self, signal_bus: &mut SignalBus) {
        let Some(save_manager) = &self.save_manager else {
            return;
        };
        if self.world_name.is_empty() {
            return;
        }

        signal_bus.emit(GameSignal::WorldSaving);

        let dirty_list: Vec<IVec2> = self.dirty_chunks.iter().copied().collect();
        for chunk_pos in dirty_list {
            if let Some(chunk) = self.chunks.get(&chunk_pos) {
                let tile_data = chunk.terrain_data();
                if !tile_data.is_empty() {
                    save_manager.save_chunk(&self.world_name, chunk_pos, tile_data);
                }
            }
        }
        self.dirty_chunks.clear();

        if let Some(save_manager) = &self.save_manager {
            save_manager.save_world_meta(&self.world_name, self.world_seed, "simplex", json!({}));
        }

        signal_bus.emit(GameSignal::WorldSaved);
    }

    pub fn load_chunk_data(&self, chunk_pos: IVec2) -> Option<Vec<u8>> {
        let save_manager = self.save_manager.as_ref()?;
        if self.world_name.is_empty() {
            return None;
        }
        save_manager.load_chunk(&self.world_name, chunk_pos)
    }

    pub fn has_saved_chunk(&self, chunk_pos: IVec2) -> bool {
        let Some(save_manager) = &self.save_manager else {
            return false;
        };
        if self.world_name.is_empty() {
            return false;
        }
        save_manager.has_saved_chunk(&self.world_name, chunk_pos)
    }

    fn save_dirty_chunk(&mut self, chunk_pos: IVec2, chunk: &Chunk) {
        if let Some(save_manager) = &self.save_manager {
            let tile_data = chunk.terrain_data();
            if !tile_data.is_empty() {
                save_manager.save_chunk(&self.world_name, chunk_pos, tile_data);
            }
        }
        self.dirty_chunks.remove(&chunk_pos);
    }

    pub fn shutdown(&mut self, signal_bus: &mut SignalBus) {
        self.save_world(signal_bus);
        self.chunk_loader.stop();
    }
}
