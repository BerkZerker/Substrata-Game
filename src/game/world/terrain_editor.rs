use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashSet, VecDeque};
use glam::{IVec2, Vec2};
use winit::event::MouseButton;
use winit::keyboard::KeyCode;

use crate::engine::camera::Camera2D;
use crate::engine::input::InputState;
use crate::game::settings::{
    DEFAULT_BRUSH_VALUE, FORCE_DECAY_PER_TILE, FORCE_DISTANCE_FACTOR, MAX_BRUSH_VALUE,
    MAX_FLOOD_FILL_RADIUS, ORPHAN_CLUSTER_THRESHOLD,
};
use crate::game::signals::{GameSignal, SignalBus};
use crate::game::tiles::{TileRegistry, AIR, STONE};
use crate::game::world::chunk_manager::{ChunkManager, WorldTileChange};

/// 8-connected neighbor offsets (cardinal + diagonal) matching `TerrainEditor.NEIGHBORS`.
const NEIGHBORS: [IVec2; 8] = [
    IVec2::new(0, -1),
    IVec2::new(0, 1),
    IVec2::new(-1, 0),
    IVec2::new(1, 0),
    IVec2::new(-1, -1),
    IVec2::new(1, -1),
    IVec2::new(-1, 1),
    IVec2::new(1, 1),
];

#[derive(Copy, Clone, Debug)]
struct FloodEntry {
    remaining_force: f32,
    pos: IVec2,
    distance: f32,
}

impl PartialEq for FloodEntry {
    fn eq(&self, other: &Self) -> bool {
        self.remaining_force.to_bits() == other.remaining_force.to_bits() && self.pos == other.pos
    }
}
impl Eq for FloodEntry {}

impl PartialOrd for FloodEntry {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for FloodEntry {
    fn cmp(&self, other: &Self) -> Ordering {
        self.remaining_force
            .partial_cmp(&other.remaining_force)
            .unwrap_or(Ordering::Equal)
    }
}

/// Force-based terrain editor with max-path Dijkstra flood fill and BFS orphan cluster cleanup.
/// Ported from `src/world/terrain_editor.gd`.
#[derive(Default)]
pub struct TerrainEditor;

impl TerrainEditor {
    pub fn new() -> Self {
        Self
    }

    pub fn edit_at(
        &self,
        origin: Vec2,
        force: f32,
        chunk_manager: &mut ChunkManager,
        tile_registry: &TileRegistry,
        signal_bus: &mut SignalBus,
    ) -> Vec<WorldTileChange> {
        if force <= 0.0 {
            return Vec::new();
        }

        let origin_tile = IVec2::new(origin.x.floor() as i32, origin.y.floor() as i32);

        // Phase 1: Dijkstra flood fill
        let mut changes = self.flood_fill(origin_tile, force, chunk_manager, tile_registry);
        if changes.is_empty() {
            return Vec::new();
        }

        // Phase 2: Orphaned cluster cleanup
        let orphan_changes = self.cleanup_orphans(&changes, chunk_manager);
        changes.extend(orphan_changes);

        if !changes.is_empty() {
            chunk_manager.set_tiles_at_world_positions(&changes, signal_bus);
        }

        changes
    }

    fn flood_fill(
        &self,
        origin: IVec2,
        force: f32,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
    ) -> Vec<WorldTileChange> {
        let max_radius_sq = MAX_FLOOD_FILL_RADIUS * MAX_FLOOD_FILL_RADIUS;
        let mut changes = Vec::new();

        let origin_world = Vec2::new(origin.x as f32, origin.y as f32);
        let [origin_tile_id, _] = chunk_manager.get_tile_at_world_pos(origin_world);
        if origin_tile_id == AIR {
            return changes;
        }

        let max_dist = force * FORCE_DISTANCE_FACTOR;
        let mut open = BinaryHeap::new();
        let mut visited = HashSet::new();

        open.push(FloodEntry {
            remaining_force: force,
            pos: origin,
            distance: 0.0,
        });

        while let Some(entry) = open.pop() {
            let FloodEntry {
                remaining_force,
                pos,
                distance,
            } = entry;

            if !visited.insert(pos) {
                continue;
            }

            if (pos - origin).length_squared() > max_radius_sq {
                continue;
            }

            let dist_scale = (1.0 - distance / max_dist).max(0.0);
            let scaled_force = remaining_force * dist_scale;

            let world_pos = Vec2::new(pos.x as f32, pos.y as f32);
            let [tile_id, damage_stage] = chunk_manager.get_tile_at_world_pos(world_pos);

            if tile_id == AIR {
                continue;
            }

            let effective_hardness = tile_registry.get_effective_hardness(tile_id, damage_stage);

            if scaled_force >= effective_hardness {
                // Full break — destroy tile
                changes.push(WorldTileChange {
                    pos: world_pos,
                    tile_id: AIR,
                    damage_stage: 0,
                });

                let break_noise = tile_registry.get_break_noise(tile_id);
                for dir in NEIGHBORS {
                    let neighbor_pos = pos + dir;
                    if visited.contains(&neighbor_pos) {
                        continue;
                    }
                    let neighbor_world = Vec2::new(neighbor_pos.x as f32, neighbor_pos.y as f32);
                    let [neighbor_tile_id, neighbor_damage] =
                        chunk_manager.get_tile_at_world_pos(neighbor_world);
                    if neighbor_tile_id == AIR {
                        continue;
                    }

                    let dir_f = Vec2::new(dir.x as f32, dir.y as f32);
                    let is_diagonal = dir.x.abs() + dir.y.abs() > 1;
                    let mut dir_cost = tile_registry.get_effective_directional_hardness(
                        neighbor_tile_id,
                        neighbor_damage,
                        dir_f,
                    );
                    if is_diagonal {
                        dir_cost *= 1.4;
                    }

                    let mut force_after = (scaled_force - dir_cost) * FORCE_DECAY_PER_TILE;
                    if force_after <= 0.0 {
                        continue;
                    }

                    if break_noise > 0.0 {
                        let h = Self::hash_pos(neighbor_world);
                        force_after *= 1.0 + break_noise * (h * 2.0 - 1.0);
                        force_after = force_after.max(0.0);
                    }

                    let step_dist = if is_diagonal { 1.4 } else { 1.0 };
                    if force_after > 0.0 {
                        open.push(FloodEntry {
                            remaining_force: force_after,
                            pos: neighbor_pos,
                            distance: distance + step_dist,
                        });
                    }
                }
            } else {
                // Partial damage — step up damage stage and stop propagation along this path
                let max_stages = tile_registry.get_damage_stages(tile_id);
                if max_stages > 0 && (damage_stage as i32) < max_stages {
                    changes.push(WorldTileChange {
                        pos: world_pos,
                        tile_id,
                        damage_stage: damage_stage + 1,
                    });
                }
            }
        }

        changes
    }

    fn cleanup_orphans(
        &self,
        destruction_changes: &[WorldTileChange],
        chunk_manager: &ChunkManager,
    ) -> Vec<WorldTileChange> {
        let threshold = ORPHAN_CLUSTER_THRESHOLD;
        let mut orphan_changes = Vec::new();

        let mut destroyed_set: HashSet<IVec2> = HashSet::new();
        for change in destruction_changes {
            if change.tile_id == AIR {
                destroyed_set.insert(IVec2::new(
                    change.pos.x.floor() as i32,
                    change.pos.y.floor() as i32,
                ));
            }
        }

        if destroyed_set.is_empty() {
            return orphan_changes;
        }

        let mut border_set: HashSet<IVec2> = HashSet::new();
        for &destroyed_pos in &destroyed_set {
            for dir in NEIGHBORS {
                let neighbor_pos = destroyed_pos + dir;
                if destroyed_set.contains(&neighbor_pos) {
                    continue;
                }
                let neighbor_world = Vec2::new(neighbor_pos.x as f32, neighbor_pos.y as f32);
                let [tile_id, _] = chunk_manager.get_tile_at_world_pos(neighbor_world);
                if tile_id != AIR {
                    border_set.insert(neighbor_pos);
                }
            }
        }

        for change in destruction_changes {
            if change.tile_id != AIR {
                border_set.insert(IVec2::new(
                    change.pos.x.floor() as i32,
                    change.pos.y.floor() as i32,
                ));
            }
        }

        let mut processed: HashSet<IVec2> = HashSet::new();
        let mut already_orphaned: HashSet<IVec2> = HashSet::new();

        for start_pos in border_set {
            if processed.contains(&start_pos) || already_orphaned.contains(&start_pos) {
                continue;
            }

            let mut cluster: Vec<IVec2> = Vec::new();
            let mut bfs_queue: VecDeque<IVec2> = VecDeque::new();
            let mut bfs_visited: HashSet<IVec2> = HashSet::new();
            bfs_queue.push_back(start_pos);
            bfs_visited.insert(start_pos);
            let mut is_small = true;

            while let Some(pos) = bfs_queue.pop_front() {
                cluster.push(pos);
                if cluster.len() > threshold {
                    is_small = false;
                    break;
                }

                for dir in NEIGHBORS {
                    let neighbor_pos = pos + dir;
                    if bfs_visited.contains(&neighbor_pos) {
                        continue;
                    }
                    if destroyed_set.contains(&neighbor_pos)
                        || already_orphaned.contains(&neighbor_pos)
                    {
                        continue;
                    }

                    let neighbor_world = Vec2::new(neighbor_pos.x as f32, neighbor_pos.y as f32);
                    let [tile_id, _] = chunk_manager.get_tile_at_world_pos(neighbor_world);
                    if tile_id != AIR {
                        bfs_visited.insert(neighbor_pos);
                        bfs_queue.push_back(neighbor_pos);
                    }
                }
            }

            for pos in bfs_visited {
                processed.insert(pos);
            }

            if is_small {
                for pos in cluster {
                    already_orphaned.insert(pos);
                    orphan_changes.push(WorldTileChange {
                        pos: Vec2::new(pos.x as f32, pos.y as f32),
                        tile_id: AIR,
                        damage_stage: 0,
                    });
                }
            }
        }

        orphan_changes
    }

    fn hash_pos(pos: Vec2) -> f32 {
        let mut x = (pos.x * 374_761.0 + pos.y * 668_265.0) as i64;
        x = ((x >> 16) ^ x).wrapping_mul(0x45d9f3b);
        x = ((x >> 16) ^ x).wrapping_mul(0x45d9f3b);
        x = (x >> 16) ^ x;
        ((x & 0xFFFF) as f32) / 65535.0
    }
}

/// Mouse/keyboard-driven terrain editing controller (`src/world/terrain_edit_controller.gd`).
pub struct TerrainEditController {
    terrain_editor: TerrainEditor,
    current_material: u8,
    current_brush_value: f32,
    is_editing: bool,
    is_destroying: bool,
    last_edit_tile_pos: Option<IVec2>,
    pub debug_terrain: bool,
}

impl Default for TerrainEditController {
    fn default() -> Self {
        Self::new()
    }
}

impl TerrainEditController {
    pub fn new() -> Self {
        Self {
            terrain_editor: TerrainEditor::new(),
            current_material: STONE,
            current_brush_value: DEFAULT_BRUSH_VALUE as f32,
            is_editing: false,
            is_destroying: false,
            last_edit_tile_pos: None,
            debug_terrain: false,
        }
    }

    pub fn set_material(&mut self, tile_id: u8, signal_bus: &mut SignalBus) {
        self.current_material = tile_id;
        signal_bus.emit(GameSignal::MaterialSelected(tile_id));
    }

    pub fn change_brush_value(&mut self, delta: i32, signal_bus: &mut SignalBus) {
        self.current_brush_value =
            (self.current_brush_value + delta as f32).clamp(1.0, MAX_BRUSH_VALUE as f32);
        signal_bus.emit(GameSignal::BrushValueChanged(self.current_brush_value));
    }

    pub fn get_current_material(&self) -> u8 {
        self.current_material
    }

    pub fn get_current_brush_value(&self) -> f32 {
        self.current_brush_value
    }

    pub fn handle_input(
        &mut self,
        input: &InputState,
        tile_registry: &TileRegistry,
        signal_bus: &mut SignalBus,
    ) {
        // Respect UI click consumption (e.g. clicking a hotbar slot)
        if !input.ui_consumed_mouse {
            if input.mouse_just_pressed(MouseButton::Left) {
                self.is_destroying = true;
                self.last_edit_tile_pos = None;
            }
            if input.mouse_just_pressed(MouseButton::Right) {
                self.is_editing = true;
                self.last_edit_tile_pos = None;
            }
        } else {
            if input.mouse_just_pressed(MouseButton::Left) {
                self.is_destroying = false;
            }
            if input.mouse_just_pressed(MouseButton::Right) {
                self.is_editing = false;
            }
        }

        if input.mouse_just_released(MouseButton::Left) || !input.mouse_held(MouseButton::Left) {
            self.is_destroying = false;
        }
        if input.mouse_just_released(MouseButton::Right) || !input.mouse_held(MouseButton::Right) {
            self.is_editing = false;
        }

        if input.key_just_pressed(KeyCode::KeyQ) {
            self.change_brush_value(-1, signal_bus);
        } else if input.key_just_pressed(KeyCode::KeyE) {
            self.change_brush_value(1, signal_bus);
        } else if input.key_just_pressed(KeyCode::KeyT) {
            self.debug_terrain = !self.debug_terrain;
        }

        const NUMBER_KEYS: [KeyCode; 9] = [
            KeyCode::Digit1,
            KeyCode::Digit2,
            KeyCode::Digit3,
            KeyCode::Digit4,
            KeyCode::Digit5,
            KeyCode::Digit6,
            KeyCode::Digit7,
            KeyCode::Digit8,
            KeyCode::Digit9,
        ];
        let tile_ids = tile_registry.get_tile_ids();
        for (i, &key) in NUMBER_KEYS.iter().enumerate().take(tile_ids.len()) {
            if input.key_just_pressed(key) {
                self.set_material(tile_ids[i], signal_bus);
            }
        }
    }

    pub fn update(
        &mut self,
        input: &InputState,
        camera: &Camera2D,
        chunk_manager: &mut ChunkManager,
        tile_registry: &TileRegistry,
        signal_bus: &mut SignalBus,
    ) {
        if input.ui_consumed_mouse {
            return;
        }

        let mouse_world = camera.screen_to_world(input.mouse_pos);
        let center_tile = IVec2::new(mouse_world.x.floor() as i32, mouse_world.y.floor() as i32);

        if self.is_destroying {
            if self.last_edit_tile_pos == Some(center_tile) {
                return;
            }
            self.last_edit_tile_pos = Some(center_tile);
            let center_vec = Vec2::new(center_tile.x as f32, center_tile.y as f32);
            self.terrain_editor.edit_at(
                center_vec,
                self.current_brush_value,
                chunk_manager,
                tile_registry,
                signal_bus,
            );
        } else if self.is_editing {
            if self.last_edit_tile_pos == Some(center_tile) {
                return;
            }
            self.last_edit_tile_pos = Some(center_tile);

            let r = self.current_brush_value.round() as i32;
            let mut changes = Vec::new();
            for x in -r..=r {
                for y in -r..=r {
                    if x * x + y * y > r * r {
                        continue;
                    }
                    changes.push(WorldTileChange {
                        pos: Vec2::new((center_tile.x + x) as f32, (center_tile.y + y) as f32),
                        tile_id: self.current_material,
                        damage_stage: 0,
                    });
                }
            }
            if !changes.is_empty() {
                chunk_manager.set_tiles_at_world_positions(&changes, signal_bus);
            }
        }
    }
}
