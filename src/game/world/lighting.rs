use std::collections::{HashMap, HashSet};
use glam::{IVec2, Vec2};

use crate::game::settings::{
    CHUNK_SIZE, DYN_LIGHT_STAMP_SIZE, MAX_DYNAMIC_LIGHTS, PADDED_CHUNK_LIGHT_BYTE_LEN,
    PADDED_CHUNK_LIGHT_SIZE,
};
use crate::game::tiles::{TileRegistry, AIR, GLASS};
use crate::game::world::chunk::Chunk;
use crate::game::world::generator::BaseTerrainGenerator;

/// Visual rendering style for terrain & sprite lighting (cycled with `L`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum LightingMode {
    /// Smooth bilinear gradient across tile centers (Terraria / Starbound smooth style).
    #[default]
    Smooth = 0,
    /// Retro pixel-art lighting: stepped light bands with ordered 2x2 Bayer pixel dithering.
    PixelArt = 1,
    /// Classic per-tile blocky lighting: uniform light value per 1x1 tile.
    Blocky = 2,
    /// Fullbright unlit mode for debugging/comparison.
    Off = 3,
}

impl LightingMode {
    pub fn next(self) -> Self {
        match self {
            Self::Smooth => Self::PixelArt,
            Self::PixelArt => Self::Blocky,
            Self::Blocky => Self::Off,
            Self::Off => Self::Smooth,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Smooth => "Smooth (Gradient)",
            Self::PixelArt => "Pixel-Art (Dithered)",
            Self::Blocky => "Blocky (Per-Tile)",
            Self::Off => "Off (Fullbright)",
        }
    }
}

/// 8-connected neighbor offsets: first 4 cardinal, last 4 diagonal.
const NEIGHBORS_8: [(IVec2, bool); 8] = [
    (IVec2::new(0, -1), false),
    (IVec2::new(0, 1), false),
    (IVec2::new(-1, 0), false),
    (IVec2::new(1, 0), false),
    (IVec2::new(-1, -1), true),
    (IVec2::new(1, -1), true),
    (IVec2::new(-1, 1), true),
    (IVec2::new(1, 1), true),
];

#[inline]
fn get_tile_id_from_chunks(chunks: &HashMap<IVec2, Chunk>, world_tile: IVec2) -> Option<u8> {
    let cx = world_tile.x.div_euclid(CHUNK_SIZE);
    let cy = world_tile.y.div_euclid(CHUNK_SIZE);
    let chunk = chunks.get(&IVec2::new(cx, cy))?;
    let tx = world_tile.x.rem_euclid(CHUNK_SIZE);
    let ty = world_tile.y.rem_euclid(CHUNK_SIZE);
    Some(chunk.get_tile_id_at(tx, ty))
}

#[inline]
fn get_baked_light_from_chunks(chunks: &HashMap<IVec2, Chunk>, world_tile: IVec2) -> [u8; 4] {
    let cx = world_tile.x.div_euclid(CHUNK_SIZE);
    let cy = world_tile.y.div_euclid(CHUNK_SIZE);
    let Some(chunk) = chunks.get(&IVec2::new(cx, cy)) else {
        return [0, 0, 0, 0];
    };
    if !chunk.light_baked {
        return [0, 0, 0, 0];
    }
    let tx = world_tile.x.rem_euclid(CHUNK_SIZE);
    let ty = world_tile.y.rem_euclid(CHUNK_SIZE);
    chunk.get_light_at(tx, ty)
}

/// Computes the initial vertical skylight beam (`0..=255`) entering world column `world_x`
/// at `start_y` by scanning any loaded chunks above `start_y` in that column.
fn compute_entering_sky_beam(
    chunks: &HashMap<IVec2, Chunk>,
    generator: &dyn BaseTerrainGenerator,
    tile_registry: &TileRegistry,
    world_x: i32,
    start_y: i32,
    min_loaded_cy: Option<i32>,
) -> u8 {
    let surface_y = generator.get_surface_height(world_x);
    let cx = world_x.div_euclid(CHUNK_SIZE);
    let tx = world_x.rem_euclid(CHUNK_SIZE);
    let start_cy = start_y.div_euclid(CHUNK_SIZE);

    let Some(top_cy) = min_loaded_cy else {
        return if start_y <= surface_y { 255 } else { 0 };
    };

    let top_world_y = top_cy * CHUNK_SIZE;
    let mut sky_beam: u8 = if top_world_y <= surface_y + CHUNK_SIZE {
        255
    } else {
        0
    };

    if sky_beam == 0 {
        return 0;
    }

    for cy in top_cy..=start_cy {
        let Some(chunk) = chunks.get(&IVec2::new(cx, chunk_y_clamp(cy))) else {
            continue;
        };
        let y_end = if cy == start_cy {
            start_y.rem_euclid(CHUNK_SIZE)
        } else {
            CHUNK_SIZE
        };
        for ty in 0..y_end {
            let tile_id = chunk.get_tile_id_at(tx, ty);
            if tile_id == AIR {
                continue;
            } else if tile_registry.blocks_skylight(tile_id) {
                return 0;
            } else if tile_id == GLASS {
                sky_beam = sky_beam.saturating_sub(2);
                if sky_beam == 0 {
                    return 0;
                }
            }
        }
    }

    sky_beam
}

#[inline]
fn chunk_y_clamp(cy: i32) -> i32 {
    cy
}

/// Runs a 256-bucket radix cellular flood-fill on a single channel grid (`width * height`)
/// where each cell has a precomputed cardinal step decay (`decays`).
fn propagate_channel_buckets(
    width: usize,
    height: usize,
    decays: &[u8],
    channel: &mut [u8],
    buckets: &mut [Vec<u32>; 256],
) {
    for b in buckets.iter_mut() {
        b.clear();
    }

    let mut max_level: usize = 0;
    for (idx, &val) in channel.iter().enumerate() {
        if val > 1 {
            let lvl = val as usize;
            buckets[lvl].push(idx as u32);
            if lvl > max_level {
                max_level = lvl;
            }
        }
    }

    if max_level <= 1 {
        return;
    }

    let w_i32 = width as i32;
    let h_i32 = height as i32;

    let mut level = max_level;
    while level > 1 {
        while let Some(idx_u32) = buckets[level].pop() {
            let idx = idx_u32 as usize;
            let current = channel[idx];
            if (current as usize) != level {
                continue;
            }

            let x = (idx % width) as i32;
            let y = (idx / width) as i32;

            for &(offset, is_diag) in &NEIGHBORS_8 {
                let nx = x + offset.x;
                let ny = y + offset.y;
                if nx < 0 || nx >= w_i32 || ny < 0 || ny >= h_i32 {
                    continue;
                }
                let n_idx = (ny as usize) * width + (nx as usize);
                let base_decay = decays[n_idx] as u16;
                let step_cost = if is_diag {
                    ((base_decay * 14) / 10).max(1)
                } else {
                    base_decay.max(1)
                };

                let next_val = (current as u16).saturating_sub(step_cost) as u8;
                if next_val > channel[n_idx] {
                    channel[n_idx] = next_val;
                    if next_val > 1 {
                        buckets[next_val as usize].push(n_idx as u32);
                    }
                }
            }
        }
        level -= 1;
    }
}

/// Solves and bakes static lighting (`[r, g, b, sky]`) for the world tile region
/// `[write_min..=write_max]`, seeding from the 1-tile boundary around it.
/// Returns the set of chunk coordinates whose GPU light atlas slot needs uploading
/// (including neighbors whose 1-tile padding border was updated).
pub fn bake_static_light_region(
    chunks: &mut HashMap<IVec2, Chunk>,
    generator: &dyn BaseTerrainGenerator,
    tile_registry: &TileRegistry,
    write_min: IVec2,
    write_max: IVec2,
) -> HashSet<IVec2> {
    let mut dirty_gpu_chunks = HashSet::new();
    if write_min.x > write_max.x || write_min.y > write_max.y || chunks.is_empty() {
        return dirty_gpu_chunks;
    }

    // Include a 1-tile outer ring so existing baked light outside the write box seeds inward
    let solve_min = write_min - IVec2::ONE;
    let solve_max = write_max + IVec2::ONE;

    let width = (solve_max.x - solve_min.x + 1) as usize;
    let height = (solve_max.y - solve_min.y + 1) as usize;
    let cell_count = width * height;
    if cell_count == 0 {
        return dirty_gpu_chunks;
    }

    let mut decays = vec![16u8; cell_count];
    let mut ch_r = vec![0u8; cell_count];
    let mut ch_g = vec![0u8; cell_count];
    let mut ch_b = vec![0u8; cell_count];
    let mut ch_sky = vec![0u8; cell_count];

    // Precompute minimum loaded chunk Y per chunk column for fast sky-beam checks
    let min_cx = solve_min.x.div_euclid(CHUNK_SIZE);
    let max_cx = solve_max.x.div_euclid(CHUNK_SIZE);
    let mut min_cy_per_col: HashMap<i32, i32> = HashMap::new();
    for &cpos in chunks.keys() {
        if cpos.x >= min_cx && cpos.x <= max_cx {
            min_cy_per_col
                .entry(cpos.x)
                .and_modify(|cy| *cy = (*cy).min(cpos.y))
                .or_insert(cpos.y);
        }
    }

    let mut any_r = false;
    let mut any_g = false;
    let mut any_b = false;
    let mut any_sky = false;

    // 1. Populate tile decays, emissive seeds, boundary seeds, and vertical sky beams
    for lx in 0..width {
        let wx = solve_min.x + lx as i32;
        let cx = wx.div_euclid(CHUNK_SIZE);
        let min_loaded_cy = min_cy_per_col.get(&cx).copied();
        let mut sky_beam = compute_entering_sky_beam(
            chunks,
            generator,
            tile_registry,
            wx,
            solve_min.y,
            min_loaded_cy,
        );

        for ly in 0..height {
            let wy = solve_min.y + ly as i32;
            let idx = ly * width + lx;
            let world_tile = IVec2::new(wx, wy);

            let is_boundary =
                lx == 0 || lx + 1 == width || ly == 0 || ly + 1 == height;

            if let Some(tile_id) = get_tile_id_from_chunks(chunks, world_tile) {
                decays[idx] = tile_registry.get_light_decay(tile_id);

                // Vertical sky shaft propagation
                if tile_id == AIR {
                    // Unattenuated vertical sunlight in open air
                } else if tile_registry.blocks_skylight(tile_id) {
                    sky_beam = 0;
                } else if tile_id == GLASS {
                    sky_beam = sky_beam.saturating_sub(2);
                }

                if sky_beam > 0 {
                    ch_sky[idx] = sky_beam;
                    any_sky = true;
                }

                let [er, eg, eb] = tile_registry.get_light_emission(tile_id);
                if er > 0 {
                    ch_r[idx] = er;
                    any_r = true;
                }
                if eg > 0 {
                    ch_g[idx] = eg;
                    any_g = true;
                }
                if eb > 0 {
                    ch_b[idx] = eb;
                    any_b = true;
                }

                if is_boundary {
                    let [br, bg, bb, bsky] = get_baked_light_from_chunks(chunks, world_tile);
                    if br > ch_r[idx] {
                        ch_r[idx] = br;
                        any_r = true;
                    }
                    if bg > ch_g[idx] {
                        ch_g[idx] = bg;
                        any_g = true;
                    }
                    if bb > ch_b[idx] {
                        ch_b[idx] = bb;
                        any_b = true;
                    }
                    if bsky > ch_sky[idx] {
                        ch_sky[idx] = bsky;
                        any_sky = true;
                    }
                }
            } else {
                // Unloaded chunk tile: treat as open air if above surface, opaque if underground
                let surface_y = generator.get_surface_height(wx);
                if wy <= surface_y {
                    decays[idx] = 6;
                    ch_sky[idx] = sky_beam;
                    if sky_beam > 0 {
                        any_sky = true;
                    }
                } else {
                    decays[idx] = 20;
                    sky_beam = 0;
                }
            }
        }
    }

    // 2. Cellular flood-fill per active channel using a shared 256-bucket queue
    let mut buckets: [Vec<u32>; 256] = std::array::from_fn(|_| Vec::new());
    if any_r {
        propagate_channel_buckets(width, height, &decays, &mut ch_r, &mut buckets);
    }
    if any_g {
        propagate_channel_buckets(width, height, &decays, &mut ch_g, &mut buckets);
    }
    if any_b {
        propagate_channel_buckets(width, height, &decays, &mut ch_b, &mut buckets);
    }
    if any_sky {
        propagate_channel_buckets(width, height, &decays, &mut ch_sky, &mut buckets);
    }

    // 3. Write back [write_min..=write_max] into loaded chunks and mark dirty GPU slots
    let min_write_cx = write_min.x.div_euclid(CHUNK_SIZE);
    let max_write_cx = write_max.x.div_euclid(CHUNK_SIZE);
    let min_write_cy = write_min.y.div_euclid(CHUNK_SIZE);
    let max_write_cy = write_max.y.div_euclid(CHUNK_SIZE);

    for cy in min_write_cy..=max_write_cy {
        for cx in min_write_cx..=max_write_cx {
            let chunk_pos = IVec2::new(cx, cy);
            let Some(chunk) = chunks.get_mut(&chunk_pos) else {
                continue;
            };

            let chunk_origin_x = cx * CHUNK_SIZE;
            let chunk_origin_y = cy * CHUNK_SIZE;
            let tx0 = (write_min.x - chunk_origin_x).clamp(0, CHUNK_SIZE - 1);
            let tx1 = (write_max.x - chunk_origin_x).clamp(0, CHUNK_SIZE - 1);
            let ty0 = (write_min.y - chunk_origin_y).clamp(0, CHUNK_SIZE - 1);
            let ty1 = (write_max.y - chunk_origin_y).clamp(0, CHUNK_SIZE - 1);

            let mut chunk_changed = !chunk.light_baked;
            let mut border_left = false;
            let mut border_right = false;
            let mut border_top = false;
            let mut border_bottom = false;

            let light_buf = chunk.static_light_mut();
            for ty in ty0..=ty1 {
                let wy = chunk_origin_y + ty;
                let ly = (wy - solve_min.y) as usize;
                for tx in tx0..=tx1 {
                    let wx = chunk_origin_x + tx;
                    let lx = (wx - solve_min.x) as usize;
                    let s_idx = ly * width + lx;
                    let new_rgba = [ch_r[s_idx], ch_g[s_idx], ch_b[s_idx], ch_sky[s_idx]];

                    let d_idx = ((ty * CHUNK_SIZE + tx) * 4) as usize;
                    let old_rgba = [
                        light_buf[d_idx],
                        light_buf[d_idx + 1],
                        light_buf[d_idx + 2],
                        light_buf[d_idx + 3],
                    ];
                    if old_rgba != new_rgba {
                        light_buf[d_idx..d_idx + 4].copy_from_slice(&new_rgba);
                        chunk_changed = true;
                        if tx == 0 {
                            border_left = true;
                        } else if tx == CHUNK_SIZE - 1 {
                            border_right = true;
                        }
                        if ty == 0 {
                            border_top = true;
                        } else if ty == CHUNK_SIZE - 1 {
                            border_bottom = true;
                        }
                    }
                }
            }

            chunk.light_baked = true;
            if chunk_changed {
                dirty_gpu_chunks.insert(chunk_pos);
                // If an edge tile changed, neighbor chunks that include this edge in their 1-tile
                // padded light slot border also need to refresh their padded GPU slot.
                if border_left {
                    dirty_gpu_chunks.insert(chunk_pos + IVec2::new(-1, 0));
                }
                if border_right {
                    dirty_gpu_chunks.insert(chunk_pos + IVec2::new(1, 0));
                }
                if border_top {
                    dirty_gpu_chunks.insert(chunk_pos + IVec2::new(0, -1));
                }
                if border_bottom {
                    dirty_gpu_chunks.insert(chunk_pos + IVec2::new(0, 1));
                }
                if border_left && border_top {
                    dirty_gpu_chunks.insert(chunk_pos + IVec2::new(-1, -1));
                }
                if border_right && border_top {
                    dirty_gpu_chunks.insert(chunk_pos + IVec2::new(1, -1));
                }
                if border_left && border_bottom {
                    dirty_gpu_chunks.insert(chunk_pos + IVec2::new(-1, 1));
                }
                if border_right && border_bottom {
                    dirty_gpu_chunks.insert(chunk_pos + IVec2::new(1, 1));
                }
            }
        }
    }

    dirty_gpu_chunks
}

/// Builds a `34x34x4` (`PADDED_CHUNK_LIGHT_BYTE_LEN`) RGBA8 buffer for `chunk_pos`
/// with a 1-tile border copied from neighboring chunks (or clamped from the chunk's own edge
/// when a neighbor isn't loaded yet) so hardware bilinear filtering in `terrain.wgsl`
/// is 100% seamless across chunk borders.
pub fn build_padded_chunk_light(
    chunks: &HashMap<IVec2, Chunk>,
    chunk_pos: IVec2,
    out_buf: &mut Vec<u8>,
) -> bool {
    let Some(center_chunk) = chunks.get(&chunk_pos) else {
        return false;
    };
    out_buf.resize(PADDED_CHUNK_LIGHT_BYTE_LEN, 0);
    let pad_w = PADDED_CHUNK_LIGHT_SIZE as i32; // 34

    for py in 0..pad_w {
        let local_y = py - 1; // -1..=32
        for px in 0..pad_w {
            let local_x = px - 1; // -1..=32
            let neighbor_offset = IVec2::new(
                local_x.div_euclid(CHUNK_SIZE),
                local_y.div_euclid(CHUNK_SIZE),
            );
            let n_tx = local_x.rem_euclid(CHUNK_SIZE);
            let n_ty = local_y.rem_euclid(CHUNK_SIZE);

            let rgba = if neighbor_offset == IVec2::ZERO {
                center_chunk.get_light_at(n_tx, n_ty)
            } else if let Some(neighbor) = chunks.get(&(chunk_pos + neighbor_offset)) {
                if neighbor.light_baked {
                    neighbor.get_light_at(n_tx, n_ty)
                } else {
                    center_chunk.get_light_at(
                        local_x.clamp(0, CHUNK_SIZE - 1),
                        local_y.clamp(0, CHUNK_SIZE - 1),
                    )
                }
            } else {
                center_chunk.get_light_at(
                    local_x.clamp(0, CHUNK_SIZE - 1),
                    local_y.clamp(0, CHUNK_SIZE - 1),
                )
            };

            let dst = ((py * pad_w + px) * 4) as usize;
            out_buf[dst..dst + 4].copy_from_slice(&rgba);
        }
    }

    true
}

// ============================================================================
// Dynamic Lighting System (Recalculated only when a dynamic light moves or
// when terrain inside its local stamp is edited)
// ============================================================================

#[derive(Clone, Copy, Debug)]
pub struct DynamicLightSource {
    pub position: Vec2,
    pub color: [u8; 3],
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GpuDynamicLight {
    pub world_origin: [f32; 2],
    pub slot_origin: [f32; 2],
}

struct CachedDynamicStamp {
    active: bool,
    last_subtile_pos: IVec2,
    last_color: [u8; 3],
    world_origin: IVec2,
    dirty: bool,
    rgba_data: Vec<u8>,
}

impl Default for CachedDynamicStamp {
    fn default() -> Self {
        Self {
            active: false,
            last_subtile_pos: IVec2::splat(i32::MIN),
            last_color: [0, 0, 0],
            world_origin: IVec2::ZERO,
            dirty: true,
            rgba_data: vec![0u8; (DYN_LIGHT_STAMP_SIZE * DYN_LIGHT_STAMP_SIZE * 4) as usize],
        }
    }
}

/// Manages moving dynamic lights (Player Lantern, Cursor Light, and custom lights)
/// using cached local `128x128` cellular flood-fill stamps so stationary dynamic lights
/// cost zero CPU/GPU work and moving lights only update their own stamp.
pub struct DynamicLightManager {
    pub lighting_mode: LightingMode,
    pub player_light_enabled: bool,
    pub cursor_light_enabled: bool,
    pub player_light_color: [u8; 3],
    pub cursor_light_color: [u8; 3],
    pub custom_lights: Vec<DynamicLightSource>,

    stamps: [CachedDynamicStamp; MAX_DYNAMIC_LIGHTS],
    gpu_lights: Vec<GpuDynamicLight>,
    pending_slot_uploads: Vec<usize>,
    buckets: [Vec<u32>; 256],

    pub last_frame_dynamic_rebakes: usize,
    pub last_frame_static_rebakes: usize,
}

impl Default for DynamicLightManager {
    fn default() -> Self {
        Self::new()
    }
}

impl DynamicLightManager {
    pub fn new() -> Self {
        Self {
            lighting_mode: LightingMode::Smooth,
            player_light_enabled: true,
            cursor_light_enabled: true,
            // Warm golden-amber lantern light on the player
            player_light_color: [255, 210, 135],
            // Crisp cool sky-cyan inspection light on the mouse cursor
            cursor_light_color: [185, 230, 255],
            custom_lights: Vec::new(),
            stamps: std::array::from_fn(|_| CachedDynamicStamp::default()),
            gpu_lights: Vec::with_capacity(MAX_DYNAMIC_LIGHTS),
            pending_slot_uploads: Vec::with_capacity(MAX_DYNAMIC_LIGHTS),
            buckets: std::array::from_fn(|_| Vec::new()),
            last_frame_dynamic_rebakes: 0,
            last_frame_static_rebakes: 0,
        }
    }

    /// Marks any dynamic light stamp overlapping the world tile box `[min_tile, max_tile]` dirty.
    pub fn invalidate_tile_region(&mut self, min_tile: IVec2, max_tile: IVec2) {
        let size = IVec2::splat(DYN_LIGHT_STAMP_SIZE);
        for stamp in &mut self.stamps {
            if !stamp.active {
                continue;
            }
            let stamp_min = stamp.world_origin;
            let stamp_max = stamp.world_origin + size;
            if max_tile.x >= stamp_min.x
                && min_tile.x <= stamp_max.x
                && max_tile.y >= stamp_min.y
                && min_tile.y <= stamp_max.y
            {
                stamp.dirty = true;
            }
        }
    }

    /// Updates active dynamic light stamps, recalculating only those whose position, color,
    /// or underlying terrain changed this frame.
    pub fn update(
        &mut self,
        player_pos: Vec2,
        cursor_world_pos: Vec2,
        chunks: &HashMap<IVec2, Chunk>,
        tile_registry: &TileRegistry,
    ) {
        self.gpu_lights.clear();
        self.pending_slot_uploads.clear();
        self.last_frame_dynamic_rebakes = 0;

        if self.lighting_mode == LightingMode::Off {
            return;
        }

        let mut desired: Vec<DynamicLightSource> = Vec::with_capacity(MAX_DYNAMIC_LIGHTS);
        if self.player_light_enabled {
            desired.push(DynamicLightSource {
                position: player_pos,
                color: self.player_light_color,
            });
        }
        if self.cursor_light_enabled {
            desired.push(DynamicLightSource {
                position: cursor_world_pos,
                color: self.cursor_light_color,
            });
        }
        for &custom in &self.custom_lights {
            if desired.len() >= MAX_DYNAMIC_LIGHTS {
                break;
            }
            desired.push(custom);
        }

        for (slot_idx, source) in desired.iter().enumerate() {
            // Quantize to 1/4 tile so sub-tile bilinear seeding is smooth while stationary lights stay cached
            let subtile_pos = IVec2::new(
                (source.position.x * 4.0).round() as i32,
                (source.position.y * 4.0).round() as i32,
            );
            let stamp = &mut self.stamps[slot_idx];
            let needs_rebake = !stamp.active
                || stamp.dirty
                || stamp.last_subtile_pos != subtile_pos
                || stamp.last_color != source.color;

            if needs_rebake {
                Self::bake_dynamic_stamp(
                    stamp,
                    source,
                    subtile_pos,
                    chunks,
                    tile_registry,
                    &mut self.buckets,
                );
                self.pending_slot_uploads.push(slot_idx);
                self.last_frame_dynamic_rebakes += 1;
            }

            let [slot_col, slot_row] = Self::slot_grid_coords(slot_idx as u32);
            let slot_px_x = (slot_col as i32 * DYN_LIGHT_STAMP_SIZE) as f32;
            let slot_px_y = (slot_row as i32 * DYN_LIGHT_STAMP_SIZE) as f32;

            self.gpu_lights.push(GpuDynamicLight {
                world_origin: [stamp.world_origin.x as f32, stamp.world_origin.y as f32],
                slot_origin: [slot_px_x, slot_px_y],
            });
        }

        for slot_idx in desired.len()..MAX_DYNAMIC_LIGHTS {
            self.stamps[slot_idx].active = false;
        }
    }

    pub fn slot_grid_coords(slot: u32) -> [u32; 2] {
        [slot % 4, slot / 4]
    }

    pub fn gpu_lights(&self) -> &[GpuDynamicLight] {
        &self.gpu_lights
    }

    pub fn drain_pending_uploads(&mut self) -> Vec<(u32, &[u8])> {
        let indices = std::mem::take(&mut self.pending_slot_uploads);
        let mut out = Vec::with_capacity(indices.len());
        // Collect slice references
        for (idx, stamp) in self.stamps.iter().enumerate() {
            if indices.contains(&idx) {
                out.push((idx as u32, stamp.rgba_data.as_slice()));
            }
        }
        out
    }

    /// Samples the combined static + dynamic light RGB (`[0.0..=1.2]`) at a world position,
    /// used to tint sprites (like the player) so entities react to caves and lanterns.
    pub fn sample_world_light_tint(
        &self,
        world_pos: Vec2,
        chunks: &HashMap<IVec2, Chunk>,
    ) -> [f32; 4] {
        if self.lighting_mode == LightingMode::Off {
            return [1.0, 1.0, 1.0, 1.0];
        }

        let tile_pos = IVec2::new(world_pos.x.floor() as i32, world_pos.y.floor() as i32);
        let [sr, sg, sb, ssky] = get_baked_light_from_chunks(chunks, tile_pos);

        let mut dr = 0u8;
        let mut dg = 0u8;
        let mut db = 0u8;
        for stamp in &self.stamps {
            if !stamp.active {
                continue;
            }
            let lx = tile_pos.x - stamp.world_origin.x;
            let ly = tile_pos.y - stamp.world_origin.y;
            if lx >= 0 && lx < DYN_LIGHT_STAMP_SIZE && ly >= 0 && ly < DYN_LIGHT_STAMP_SIZE {
                let idx = ((ly * DYN_LIGHT_STAMP_SIZE + lx) * 4) as usize;
                dr = dr.max(stamp.rgba_data[idx]);
                dg = dg.max(stamp.rgba_data[idx + 1]);
                db = db.max(stamp.rgba_data[idx + 2]);
            }
        }

        let sun_r = (ssky as f32 / 255.0) * 1.0;
        let sun_g = (ssky as f32 / 255.0) * 0.98;
        let sun_b = (ssky as f32 / 255.0) * 0.94;

        let pr = (sr.max(dr) as f32) / 255.0;
        let pg = (sg.max(dg) as f32) / 255.0;
        let pb = (sb.max(db) as f32) / 255.0;

        let r = (sun_r.max(pr) + sun_r.min(pr) * 0.35).clamp(0.08, 1.15);
        let g = (sun_g.max(pg) + sun_g.min(pg) * 0.35).clamp(0.08, 1.15);
        let b = (sun_b.max(pb) + sun_b.min(pb) * 0.35).clamp(0.10, 1.15);

        [r, g, b, 1.0]
    }

    fn bake_dynamic_stamp(
        stamp: &mut CachedDynamicStamp,
        source: &DynamicLightSource,
        subtile_pos: IVec2,
        chunks: &HashMap<IVec2, Chunk>,
        tile_registry: &TileRegistry,
        buckets: &mut [Vec<u32>; 256],
    ) {
        let size = DYN_LIGHT_STAMP_SIZE as usize;
        let half = DYN_LIGHT_STAMP_SIZE / 2;
        let center_tile = IVec2::new(
            source.position.x.floor() as i32,
            source.position.y.floor() as i32,
        );
        let world_origin = center_tile - IVec2::splat(half);

        stamp.active = true;
        stamp.dirty = false;
        stamp.last_subtile_pos = subtile_pos;
        stamp.last_color = source.color;
        stamp.world_origin = world_origin;

        let cell_count = size * size;
        let mut decays = vec![6u8; cell_count];
        for ly in 0..size {
            let wy = world_origin.y + ly as i32;
            for lx in 0..size {
                let wx = world_origin.x + lx as i32;
                let tile_id =
                    get_tile_id_from_chunks(chunks, IVec2::new(wx, wy)).unwrap_or(AIR);
                decays[ly * size + lx] = tile_registry.get_light_decay(tile_id);
            }
        }

        // Single-channel intensity propagation (0..=255), then tinted by `source.color`
        let mut intensity = vec![0u8; cell_count];

        // Bilinear sub-tile seeding over the 2x2 neighborhood around `source.position`
        // so moving the player or cursor smoothly glides the light without 1-tile stepping.
        let local_fx = source.position.x - world_origin.x as f32 - 0.5;
        let local_fy = source.position.y - world_origin.y as f32 - 0.5;
        let x0 = local_fx.floor() as i32;
        let y0 = local_fy.floor() as i32;

        for dy in 0..=1 {
            for dx in 0..=1 {
                let tx = x0 + dx;
                let ty = y0 + dy;
                if tx >= 1 && tx < (DYN_LIGHT_STAMP_SIZE - 1) && ty >= 1 && ty < (DYN_LIGHT_STAMP_SIZE - 1) {
                    let dist_x = (local_fx - tx as f32).abs();
                    let dist_y = (local_fy - ty as f32).abs();
                    let dist = (dist_x * dist_x + dist_y * dist_y).sqrt();
                    let idx = (ty as usize) * size + (tx as usize);
                    let seed_val = (255.0 - dist * (decays[idx] as f32)).round().clamp(0.0, 255.0) as u8;
                    intensity[idx] = seed_val;
                }
            }
        }

        propagate_channel_buckets(size, size, &decays, &mut intensity, buckets);

        // Zero out the 1-tile outer border so clamping at the stamp edge cleanly fades to 0
        for i in 0..size {
            intensity[i] = 0;
            intensity[(size - 1) * size + i] = 0;
            intensity[i * size] = 0;
            intensity[i * size + (size - 1)] = 0;
        }

        let [cr, cg, cb] = source.color;
        for (i, &val) in intensity.iter().enumerate() {
            let dst = i * 4;
            if val == 0 {
                stamp.rgba_data[dst..dst + 4].copy_from_slice(&[0, 0, 0, 0]);
            } else {
                let v = val as u16;
                stamp.rgba_data[dst] = ((v * cr as u16) / 255) as u8;
                stamp.rgba_data[dst + 1] = ((v * cg as u16) / 255) as u8;
                stamp.rgba_data[dst + 2] = ((v * cb as u16) / 255) as u8;
                stamp.rgba_data[dst + 3] = val;
            }
        }
    }
}
