use std::collections::HashSet;
use glam::{IVec2, Vec2};
use winit::event::MouseButton;
use winit::keyboard::KeyCode;

use crate::engine::camera::Camera2D;
use crate::engine::input::InputState;
use crate::engine::renderer::debug_pass::DebugBatch;
use crate::engine::ui::UiBatch;
use crate::game::entities::player::Player;
use crate::game::settings::{CHUNK_SIZE, REGION_SIZE};
use crate::game::signals::SignalBus;
use crate::game::tiles::{TileRegistry, AIR};
use crate::game::world::building::fixed_to_world;
use crate::game::world::chunk_manager::{ChunkDebugInfo, ChunkManager};
use crate::game::world::terrain_editor::TerrainEditController;

const MAX_SLOTS: usize = 9;
const CURSOR_UPDATE_INTERVAL: f32 = 0.05;
const CHUNK_DEBUG_UPDATE_INTERVAL: u32 = 10;

const CONTROLS_TEXT: &str = "=== Controls ===

Movement
  A / D ........... Move Left / Right
  Space ........... Jump
  Scroll .......... Zoom
  Z ............... Cycle Zoom Presets

Terrain Brush Mode (Default)
  B ............... Toggle Build Mode
  LMB Hold ........ Destroy Terrain (force)
  RMB Hold ........ Place Terrain (circle)
  1-9 ............. Select Material
  Q / E ........... Brush Value -/+
  T ............... Terrain Heatmap

Brick Build Mode (Press B)
  RMB Drag ........ Size & Place Pattern
  LMB Click ....... Remove Single Piece / Dig
  Q / E or [ / ] .. Prev / Next Pattern
  X or Tab ........ Switch Slot (Piece / Mortar)
  1-9 / 0 ......... Set Slot Material / Reset
  G ............... Toggle Snap to Adjacent
  V or O .......... Cycle Overlap Mode
  R / , / . ....... Rotate 90 / -15 / +15 deg

Lighting
  L ............... Cycle Mode (Smooth / Pixel-Art / Blocky / Off)
  F ............... Toggle Player Lantern (Dynamic)
  C ............... Toggle Cursor Light (Dynamic)
  9 ............... Select Lantern Tile (Static Baked)

Debug & UI
  F1 .............. This Help
  F2 .............. Cursor Info
  F3 .............. Debug HUD
  F4 .............. World Overlay";

/// Manages all HUD widgets (`Hotbar`, `CursorInfo`, `DebugHUD`, `ControlsOverlay`)
/// and world-space overlays (`ChunkDebugOverlay`, `BrushPreview`).
pub struct GuiSystem {
    pub show_controls_help: bool,  // F1 (default off)
    pub show_cursor_info: bool,    // F2 (default on)
    pub show_debug_hud: bool,      // F3 (default off)
    pub show_world_overlay: bool,  // F4 (default off)

    cursor_time_since_update: f32,
    cursor_cached_text: String,

    world_overlay_frame_counter: u32,
    cached_chunk_debug: Option<ChunkDebugInfo>,
}

impl Default for GuiSystem {
    fn default() -> Self {
        Self::new()
    }
}

impl GuiSystem {
    pub fn new() -> Self {
        Self {
            show_controls_help: false,
            show_cursor_info: true,
            show_debug_hud: false,
            show_world_overlay: false,
            cursor_time_since_update: CURSOR_UPDATE_INTERVAL,
            cursor_cached_text: String::new(),
            world_overlay_frame_counter: 0,
            cached_chunk_debug: None,
        }
    }

    pub fn update_and_build(
        &mut self,
        dt: f32,
        fps: u32,
        input: &mut InputState,
        camera: &Camera2D,
        player: &Player,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
        edit_controller: &mut TerrainEditController,
        signal_bus: &mut SignalBus,
        debug_batch: &mut DebugBatch,
        ui_batch: &mut UiBatch,
    ) {
        if input.key_just_pressed(KeyCode::F1) {
            self.show_controls_help = !self.show_controls_help;
        }
        if input.key_just_pressed(KeyCode::F2) {
            self.show_cursor_info = !self.show_cursor_info;
        }
        if input.key_just_pressed(KeyCode::F3) {
            self.show_debug_hud = !self.show_debug_hud;
        }
        if input.key_just_pressed(KeyCode::F4) {
            self.show_world_overlay = !self.show_world_overlay;
            if self.show_world_overlay {
                self.cached_chunk_debug = Some(chunk_manager.get_debug_info());
            }
        }

        debug_batch.clear();
        ui_batch.clear();

        // 1. World-space overlays (F4 ChunkDebugOverlay + BrushPreview)
        if self.show_world_overlay {
            self.world_overlay_frame_counter = self.world_overlay_frame_counter.wrapping_add(1);
            if self.world_overlay_frame_counter % CHUNK_DEBUG_UPDATE_INTERVAL == 0
                || self.cached_chunk_debug.is_none()
            {
                self.cached_chunk_debug = Some(chunk_manager.get_debug_info());
            }
            if let Some(info) = &self.cached_chunk_debug {
                Self::draw_chunk_debug_overlay(info, camera, debug_batch);
            }
        }

        if edit_controller.build_tool.active {
            let mouse_world = camera.screen_to_world(input.mouse_pos);
            let cursor_tile =
                IVec2::new(mouse_world.x.floor() as i32, mouse_world.y.floor() as i32);
            let movers = [(player.position, player.movement.collision_box_size)];
            edit_controller.build_tool.update_preview(
                cursor_tile,
                mouse_world,
                &edit_controller.patterns,
                &edit_controller.placements,
                chunk_manager,
                tile_registry,
                &movers,
            );
            Self::draw_build_preview(camera, edit_controller, debug_batch);
        } else {
            Self::draw_brush_preview(input, camera, edit_controller, debug_batch);
        }

        // 2. Screen-space UI (Hotbar, BuildPanel, DebugHUD, CursorInfo, ControlsOverlay)
        self.build_hotbar(
            input,
            camera.viewport_size,
            chunk_manager,
            tile_registry,
            edit_controller,
            signal_bus,
            ui_batch,
        );

        if edit_controller.build_tool.active {
            self.build_building_panel(
                input,
                camera.viewport_size,
                tile_registry,
                edit_controller,
                ui_batch,
            );
        }

        if self.show_debug_hud {
            self.build_debug_hud(fps, camera, player, chunk_manager, ui_batch);
        }

        if self.show_cursor_info {
            self.build_cursor_info(
                dt,
                input,
                camera,
                chunk_manager,
                tile_registry,
                edit_controller,
                ui_batch,
            );
        }

        if self.show_controls_help {
            self.build_controls_overlay(camera.viewport_size, ui_batch);
        }
    }

    fn build_hotbar(
        &self,
        input: &mut InputState,
        viewport_size: Vec2,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
        edit_controller: &mut TerrainEditController,
        signal_bus: &mut SignalBus,
        ui_batch: &mut UiBatch,
    ) {
        let tile_ids = tile_registry.get_tile_ids();
        let slot_count = tile_ids.len().min(MAX_SLOTS);
        if slot_count == 0 {
            return;
        }

        let slot_size = Vec2::splat(56.0);
        let separation = 6.0;
        let margin = 10.0;
        let font_size = 11.0;

        let slots_row_width =
            (slot_count as f32) * slot_size.x + ((slot_count.saturating_sub(1)) as f32) * separation;
        let light_mode_name = chunk_manager.dynamic_lights.lighting_mode.name();
        let value_text = if edit_controller.build_tool.active {
            let pat_name = edit_controller
                .patterns
                .get(edit_controller.build_tool.pattern)
                .map(|p| p.name())
                .unwrap_or("?");
            format!(
                "BUILD [B] : {}  |  {} (V)  |  Snap:{} (G)  |  Light [L]: {}",
                pat_name,
                edit_controller.build_tool.overlap.name(),
                if edit_controller.build_tool.snap {
                    "ON"
                } else {
                    "OFF"
                },
                light_mode_name
            )
        } else {
            format!(
                "BRUSH [B] : {} (Q/E)  |  Light [L]: {}",
                edit_controller.get_current_brush_value().round() as i32,
                light_mode_name
            )
        };
        let value_size = UiBatch::measure_text(&value_text, font_size);

        let content_width = slots_row_width.max(value_size.x).max(100.0);
        let content_height = slot_size.y + separation + value_size.y;
        let panel_size = Vec2::new(content_width + margin * 2.0, content_height + margin * 2.0);
        let panel_pos = Vec2::new((viewport_size.x - panel_size.x) * 0.5, 12.0);

        let mouse = input.mouse_pos;
        let mouse_in_panel = mouse.x >= panel_pos.x
            && mouse.x <= panel_pos.x + panel_size.x
            && mouse.y >= panel_pos.y
            && mouse.y <= panel_pos.y + panel_size.y;
        if mouse_in_panel {
            input.ui_consumed_mouse = true;
        }

        ui_batch.draw_panel(panel_pos, panel_size);

        let row_start_x = panel_pos.x + (panel_size.x - slots_row_width) * 0.5;
        let row_y = panel_pos.y + margin;
        let current_material = edit_controller.get_current_material();

        for (i, &tile_id) in tile_ids.iter().take(slot_count).enumerate() {
            let slot_pos = Vec2::new(
                row_start_x + (i as f32) * (slot_size.x + separation),
                row_y,
            );
            let hovered = mouse.x >= slot_pos.x
                && mouse.x <= slot_pos.x + slot_size.x
                && mouse.y >= slot_pos.y
                && mouse.y <= slot_pos.y + slot_size.y;
            let selected = tile_id == current_material;

            if hovered && input.mouse_just_pressed(MouseButton::Left) {
                edit_controller.set_material(tile_id, signal_bus);
            }

            ui_batch.draw_slot_box(slot_pos, slot_size, hovered, selected);

            // Icon area matching hotbar_slot.tscn: offset_left=6, top=6, right=-6, bottom=-20
            let icon_pos = slot_pos + Vec2::new(6.0, 6.0);
            let icon_size = Vec2::new(slot_size.x - 12.0, slot_size.y - 26.0);

            if let Some(def) = tile_registry.get_tile_def(tile_id) {
                if !def.texture_path.is_empty() {
                    ui_batch.draw_tile_icon(icon_pos, icon_size, tile_id as u32);
                } else {
                    ui_batch.draw_rounded_rect(
                        icon_pos,
                        icon_size,
                        def.color,
                        2.0,
                        0.0,
                        [0.0, 0.0, 0.0, 0.0],
                    );
                }
            }

            // Key number label in bottom-right of slot
            let key_str = format!("{}", i + 1);
            let key_pos = Vec2::new(
                slot_pos.x + slot_size.x - 12.0,
                slot_pos.y + slot_size.y - 12.0,
            );
            ui_batch.draw_text_shadowed(key_pos, &key_str, 9.0, [1.0, 1.0, 1.0, 0.95]);
        }

        // Centered status label below slots row (clickable to toggle Build Mode)
        let label_pos = Vec2::new(
            panel_pos.x + (panel_size.x - value_size.x) * 0.5,
            row_y + slot_size.y + separation,
        );
        let label_hovered = mouse.x >= label_pos.x - 4.0
            && mouse.x <= label_pos.x + value_size.x + 4.0
            && mouse.y >= label_pos.y - 2.0
            && mouse.y <= label_pos.y + value_size.y + 2.0;
        if label_hovered && input.mouse_just_pressed(MouseButton::Left) {
            edit_controller.build_tool.active = !edit_controller.build_tool.active;
            edit_controller.build_tool.cancel_drag();
        }
        let label_color = if edit_controller.build_tool.active {
            [0.45, 0.95, 0.55, 0.98]
        } else {
            [1.0, 1.0, 1.0, 0.9]
        };
        ui_batch.draw_text_shadowed(label_pos, &value_text, font_size, label_color);
    }

    fn build_building_panel(
        &self,
        input: &mut InputState,
        viewport_size: Vec2,
        tile_registry: &TileRegistry,
        edit_controller: &mut TerrainEditController,
        ui_batch: &mut UiBatch,
    ) {
        let Some(pattern) = edit_controller
            .patterns
            .get(edit_controller.build_tool.pattern)
            .cloned()
        else {
            return;
        };

        let effective_mats = edit_controller
            .build_tool
            .effective_materials(&edit_controller.patterns);
        let slot_names = pattern.slot_names();
        let active_slot = edit_controller.build_tool.active_slot;

        let mut slots_desc = String::new();
        for (idx, &slot_label) in slot_names.iter().enumerate() {
            let mat_name = tile_registry.get_tile_name(effective_mats[idx]);
            let marker = if idx == active_slot { ">" } else { " " };
            slots_desc.push_str(&format!(
                "{}Slot {} ({}): {} [1-9]\n",
                marker,
                idx + 1,
                slot_label,
                mat_name
            ));
        }

        let text = format!(
            "=== Brick Builder (B) ===\nPattern (Q/E): {} ({})\n{}Reset Slots: [0]  Switch Slot: [X]\nOverlap (V): {}\nSnap (G): {}\nYaw (R/,/.): {:.0} deg",
            pattern.name(),
            pattern.family_name(),
            slots_desc,
            edit_controller.build_tool.overlap.name(),
            if edit_controller.build_tool.snap {
                "ON"
            } else {
                "OFF"
            },
            edit_controller.build_tool.yaw_degrees(),
        );

        let font_size = 10.0;
        let margin = 10.0;
        let text_size = UiBatch::measure_text(&text, font_size);
        let panel_size = text_size + Vec2::splat(margin * 2.0);
        let panel_pos = Vec2::new(viewport_size.x - panel_size.x - 12.0, 12.0);

        let mouse = input.mouse_pos;
        if mouse.x >= panel_pos.x
            && mouse.x <= panel_pos.x + panel_size.x
            && mouse.y >= panel_pos.y
            && mouse.y <= panel_pos.y + panel_size.y
        {
            input.ui_consumed_mouse = true;
            if input.mouse_just_pressed(MouseButton::Left) {
                let rel_y = mouse.y - (panel_pos.y + margin);
                let line_h = font_size * 1.35;
                let line_idx = (rel_y / line_h).floor() as i32;
                if line_idx == 1 {
                    edit_controller
                        .build_tool
                        .cycle_pattern(1, &edit_controller.patterns);
                } else if line_idx >= 2 && (line_idx as usize) < 2 + slot_names.len() {
                    edit_controller.build_tool.active_slot = (line_idx - 2) as usize;
                }
            }
        }

        ui_batch.draw_panel(panel_pos, panel_size);
        ui_batch.draw_text_shadowed(
            panel_pos + Vec2::splat(margin),
            &text,
            font_size,
            [0.92, 0.96, 1.0, 0.95],
        );
    }

    fn build_debug_hud(
        &self,
        fps: u32,
        camera: &Camera2D,
        player: &Player,
        chunk_manager: &ChunkManager,
        ui_batch: &mut UiBatch,
    ) {
        let info = chunk_manager.get_debug_info();
        let pos = player.position;
        let vel = player.get_movement_velocity();
        let floor = player.get_on_floor();
        let dl = &chunk_manager.dynamic_lights;

        let text = format!(
            "FPS: {}\nPos: ({:.1}, {:.1})\nVel: ({:.1}, {:.1})  Floor: {}\nZoom: {:.1}x\nChunk: ({}, {})  Region: ({}, {})\n--- Lighting ---\nMode [L]: {}\nPlayer [F]: {}  Cursor [C]: {}\nStatic Rebakes: {}  Dyn Rebakes: {}\n--- Chunks ---\nLoaded: {}  Gen Queue: {}\nIn Progress: {}  Build: {}\nActive Tasks: {}  Removal: {}",
            fps,
            pos.x,
            pos.y,
            vel.x,
            vel.y,
            floor,
            camera.zoom.x,
            info.player_chunk.x,
            info.player_chunk.y,
            info.player_region.x,
            info.player_region.y,
            dl.lighting_mode.name(),
            if dl.player_light_enabled { "ON" } else { "OFF" },
            if dl.cursor_light_enabled { "ON" } else { "OFF" },
            dl.last_frame_static_rebakes,
            dl.last_frame_dynamic_rebakes,
            info.loaded_count,
            info.generation_queue_size,
            info.in_progress_size,
            info.build_queue_size,
            info.active_tasks,
            info.removal_queue_size,
        );

        let font_size = 10.0;
        let margin = 10.0;
        let text_size = UiBatch::measure_text(&text, font_size);
        let panel_pos = Vec2::new(12.0, 12.0);
        let panel_size = text_size + Vec2::splat(margin * 2.0);

        ui_batch.draw_panel(panel_pos, panel_size);
        ui_batch.draw_text_shadowed(
            panel_pos + Vec2::splat(margin),
            &text,
            font_size,
            [1.0, 1.0, 1.0, 0.9],
        );
    }

    fn build_cursor_info(
        &mut self,
        dt: f32,
        input: &InputState,
        camera: &Camera2D,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
        edit_controller: &TerrainEditController,
        ui_batch: &mut UiBatch,
    ) {
        self.cursor_time_since_update += dt;
        if self.cursor_time_since_update >= CURSOR_UPDATE_INTERVAL
            || self.cursor_cached_text.is_empty()
            || edit_controller.build_tool.active
        {
            self.cursor_time_since_update = 0.0;
            let world_pos = camera.screen_to_world(input.mouse_pos);
            let tile_pos = IVec2::new(world_pos.x.floor() as i32, world_pos.y.floor() as i32);
            let [tile_id, damage_stage] = chunk_manager.get_tile_at_world_pos(world_pos);
            let [lr, lg, lb, lsky] = chunk_manager.get_light_at_world_pos(world_pos);
            let tile_name = tile_registry.get_tile_name(tile_id);

            let mut base_line = if tile_id == AIR {
                format!(
                    "({}, {}) {}  Sky:{} RGB:({},{},{})",
                    tile_pos.x, tile_pos.y, tile_name, lsky, lr, lg, lb
                )
            } else {
                let hardness = tile_registry.get_hardness(tile_id);
                let eff_hardness = tile_registry.get_effective_hardness(tile_id, damage_stage);
                let max_stages = tile_registry.get_damage_stages(tile_id);
                format!(
                    "({}, {}) {}  H:{}  Eff:{:.1}  Dmg:{}/{}  Sky:{} RGB:({},{},{})",
                    tile_pos.x,
                    tile_pos.y,
                    tile_name,
                    hardness,
                    eff_hardness,
                    damage_stage,
                    max_stages,
                    lsky,
                    lr,
                    lg,
                    lb
                )
            };

            if let Some((serial, piece_id)) = edit_controller.placements.piece_at(tile_pos) {
                base_line.push_str(&format!("  [Piece #{} Rec #{}]", piece_id, serial));
            } else if let Some(serial) = edit_controller.placements.placement_at(tile_pos) {
                base_line.push_str(&format!("  [Joint Rec #{}]", serial));
            }

            if edit_controller.build_tool.active {
                if let Some(plan) = &edit_controller.build_tool.plan {
                    base_line.push('\n');
                    base_line.push_str(&plan.status_text);
                }
            }

            self.cursor_cached_text = base_line;
        }

        let font_size = 10.0;
        let pad = 6.0;
        let text_size = UiBatch::measure_text(&self.cursor_cached_text, font_size);
        let box_pos = input.mouse_pos + Vec2::new(16.0, 16.0);
        let box_size = text_size + Vec2::splat(pad * 2.0);

        ui_batch.draw_panel(box_pos, box_size);
        ui_batch.draw_text_shadowed(
            box_pos + Vec2::splat(pad),
            &self.cursor_cached_text,
            font_size,
            [1.0, 1.0, 1.0, 0.9],
        );
    }

    fn build_controls_overlay(&self, viewport_size: Vec2, ui_batch: &mut UiBatch) {
        let font_size = 10.0;
        let margin = 14.0;
        let text_size = UiBatch::measure_text(CONTROLS_TEXT, font_size);
        let panel_size = text_size + Vec2::splat(margin * 2.0);
        let panel_pos = (viewport_size - panel_size) * 0.5;

        ui_batch.draw_panel(panel_pos, panel_size);
        ui_batch.draw_text_shadowed(
            panel_pos + Vec2::splat(margin),
            CONTROLS_TEXT,
            font_size,
            [1.0, 1.0, 1.0, 0.9],
        );
    }

    fn draw_brush_preview(
        input: &InputState,
        camera: &Camera2D,
        edit_controller: &TerrainEditController,
        debug_batch: &mut DebugBatch,
    ) {
        let mouse_world = camera.screen_to_world(input.mouse_pos);
        let snapped = Vec2::new(mouse_world.x.round(), mouse_world.y.round());
        let radius = edit_controller.get_current_brush_value().round();
        let line_thickness = (1.5 / camera.zoom.x).max(0.15);

        debug_batch.draw_circle_outline(
            snapped,
            radius,
            line_thickness,
            48,
            [1.0, 1.0, 1.0, 0.5],
        );
    }

    fn draw_build_preview(
        camera: &Camera2D,
        edit_controller: &TerrainEditController,
        debug_batch: &mut DebugBatch,
    ) {
        let Some(plan) = &edit_controller.build_tool.plan else {
            return;
        };
        let line_thickness = (1.5 / camera.zoom.x).max(0.15);
        let accepted = plan.result.is_ok();
        let piece_color = if accepted {
            [0.25, 0.95, 0.40, 0.85]
        } else {
            [0.95, 0.25, 0.20, 0.85]
        };
        let bounds_color = if accepted {
            [0.85, 0.95, 1.0, 0.45]
        } else {
            [1.0, 0.5, 0.4, 0.45]
        };

        let pose = plan.cmd.pose();

        // Draw outer bounds of the placement
        if let Some(pattern) = edit_controller.patterns.get(plan.cmd.pattern) {
            let bounds = pattern.bounds(&plan.cmd);
            let corners = bounds.world_corners(pose);
            for i in 0..4 {
                debug_batch.draw_line(
                    corners[i],
                    corners[(i + 1) % 4],
                    line_thickness,
                    bounds_color,
                );
            }
        }

        // Draw individual piece outlines (ported from `build_overlay.rs`)
        for &(_, pbox) in &plan.boxes {
            let corners = pbox.world_corners(pose);
            for i in 0..4 {
                debug_batch.draw_line(
                    corners[i],
                    corners[(i + 1) % 4],
                    line_thickness,
                    piece_color,
                );
            }
        }

        // Draw anchor marker
        let anchor_world = fixed_to_world(pose.anchor);
        debug_batch.draw_circle_outline(
            anchor_world,
            0.35,
            line_thickness,
            12,
            [0.3, 0.85, 1.0, 0.9],
        );
    }

    fn draw_chunk_debug_overlay(
        info: &ChunkDebugInfo,
        camera: &Camera2D,
        debug_batch: &mut DebugBatch,
    ) {
        const COLOR_LOADED_REGION: [f32; 4] = [0.2, 0.8, 0.2, 0.15];
        const COLOR_CHUNK_OUTLINE: [f32; 4] = [1.0, 1.0, 1.0, 1.0];
        const COLOR_GENERATION_QUEUE: [f32; 4] = [1.0, 1.0, 0.0, 0.4];
        const COLOR_REMOVAL_QUEUE: [f32; 4] = [1.0, 0.0, 1.0, 0.4];
        const COLOR_IN_PROGRESS: [f32; 4] = [0.0, 1.0, 1.0, 0.4];

        let chunk_size_f = CHUNK_SIZE as f32;
        let region_size_pixels = (REGION_SIZE * CHUNK_SIZE) as f32;
        let outline_thickness = (1.0 / camera.zoom.x).max(0.2);

        // 1. Loaded regions
        let mut loaded_regions: HashSet<IVec2> = HashSet::new();
        for &chunk_pos in &info.loaded_chunks {
            loaded_regions.insert(ChunkManager::get_chunk_region(chunk_pos));
        }
        for region_pos in loaded_regions {
            let world_pos = Vec2::new(
                region_pos.x as f32 * region_size_pixels,
                region_pos.y as f32 * region_size_pixels,
            );
            debug_batch.draw_rect_filled(
                world_pos,
                Vec2::splat(region_size_pixels),
                COLOR_LOADED_REGION,
            );
        }

        // 2. Generation queue & in-progress
        for &chunk_pos in &info.generation_queue {
            let pos = Vec2::new(
                chunk_pos.x as f32 * chunk_size_f,
                chunk_pos.y as f32 * chunk_size_f,
            );
            debug_batch.draw_rect_filled(pos, Vec2::splat(chunk_size_f), COLOR_GENERATION_QUEUE);
        }
        for &chunk_pos in &info.in_progress {
            let pos = Vec2::new(
                chunk_pos.x as f32 * chunk_size_f,
                chunk_pos.y as f32 * chunk_size_f,
            );
            debug_batch.draw_rect_filled(pos, Vec2::splat(chunk_size_f), COLOR_IN_PROGRESS);
        }

        // 3. Removal queue
        for &chunk_pos in &info.removal_positions {
            let pos = Vec2::new(
                chunk_pos.x as f32 * chunk_size_f,
                chunk_pos.y as f32 * chunk_size_f,
            );
            debug_batch.draw_rect_filled(pos, Vec2::splat(chunk_size_f), COLOR_REMOVAL_QUEUE);
        }

        // 4. Chunk outlines
        for &chunk_pos in &info.loaded_chunks {
            let pos = Vec2::new(
                chunk_pos.x as f32 * chunk_size_f,
                chunk_pos.y as f32 * chunk_size_f,
            );
            debug_batch.draw_rect_outline(
                pos,
                Vec2::splat(chunk_size_f),
                outline_thickness,
                COLOR_CHUNK_OUTLINE,
            );
        }
    }
}
