pub mod camera_controller;
pub mod entities;
pub mod gui;
pub mod physics;
pub mod settings;
pub mod signals;
pub mod tiles;
pub mod world;

use glam::Vec2;
use rand::Rng;

use crate::engine::app::GameCallbacks;
use crate::engine::camera::Camera2D;
use crate::engine::input::InputState;
use crate::engine::renderer::chunk_pass::ChunkInstance;
use crate::engine::renderer::debug_pass::DebugBatch;
use crate::engine::renderer::sprite_pass::SpriteInstance;
use crate::engine::renderer::Renderer;
use crate::engine::ui::UiBatch;
use crate::game::camera_controller::CameraController;
use crate::game::entities::player::Player;
use crate::game::entities::EntityManager;
use crate::game::gui::GuiSystem;
use crate::game::signals::{GameSignal, SignalBus};
use crate::game::tiles::TileRegistry;
use crate::game::world::chunk_manager::ChunkManager;
use crate::game::world::persistence::WorldSaveManager;
use crate::game::world::terrain_editor::TerrainEditController;

/// Main game state equivalent to `GameInstance` (`src/game/game_instance.gd` & `game_instance.tscn`).
pub struct SubstrataGame {
    pub tile_registry: TileRegistry,
    pub chunk_manager: ChunkManager,
    pub entity_manager: EntityManager,
    pub player: Player,
    pub camera: Camera2D,
    pub camera_controller: CameraController,
    pub terrain_edit_controller: TerrainEditController,
    pub gui: GuiSystem,
    pub signal_bus: SignalBus,

    chunk_instances: Vec<ChunkInstance>,
    sprite_instances: Vec<SpriteInstance>,
    debug_batch: DebugBatch,
    ui_batch: UiBatch,
}

impl SubstrataGame {
    pub fn new(tile_registry: TileRegistry, world_seed: Option<i32>) -> Self {
        let seed = world_seed.unwrap_or_else(|| rand::thread_rng().gen_range(0..1_000_000));
        let mut chunk_manager = ChunkManager::new(seed);
        let save_manager = WorldSaveManager::new();
        chunk_manager.setup_persistence(save_manager, seed.to_string());

        let player = Player::new(Vec2::new(94.0, -112.0));
        let mut camera = Camera2D::new(1920.0, 1080.0);
        camera.position = player.position;
        camera.zoom = Vec2::splat(4.0);

        Self {
            tile_registry,
            chunk_manager,
            entity_manager: EntityManager::new(),
            player,
            camera,
            camera_controller: CameraController::new(),
            terrain_edit_controller: TerrainEditController::new(),
            gui: GuiSystem::new(),
            signal_bus: SignalBus::new(),
            chunk_instances: Vec::with_capacity(512),
            sprite_instances: Vec::with_capacity(16),
            debug_batch: DebugBatch::new(),
            ui_batch: UiBatch::new(),
        }
    }

    fn dispatch_signals(&mut self) {
        loop {
            let signals = self.signal_bus.drain();
            if signals.is_empty() {
                break;
            }
            for signal in signals {
                if let GameSignal::PlayerChunkChanged(new_chunk) = signal {
                    self.chunk_manager
                        .on_player_chunk_changed(new_chunk, &mut self.signal_bus);
                }
            }
        }
    }
}

impl GameCallbacks for SubstrataGame {
    fn init(&mut self, _renderer: &mut Renderer) {
        self.camera.position = self.player.position;
        self.player.update_current_chunk(&mut self.signal_bus);
        self.dispatch_signals();
    }

    fn physics_update(&mut self, dt: f32, input: &InputState) {
        self.player.physics_process(
            dt,
            input,
            &self.chunk_manager,
            &self.tile_registry,
            &mut self.signal_bus,
        );
        self.entity_manager
            .physics_process(dt, &self.chunk_manager, &self.tile_registry);
        self.dispatch_signals();
    }

    fn update(&mut self, dt: f32, fps: u32, input: &mut InputState, renderer: &mut Renderer) {
        self.player.buffer_input(input);

        // Camera zoom and smooth follow
        self.camera_controller.handle_input(input, &mut self.camera);
        self.camera_controller
            .update(dt, self.player.position, &mut self.camera);

        // GUI updates first so hotbar clicks set `input.ui_consumed_mouse = true`
        self.gui.update_and_build(
            dt,
            fps,
            input,
            &self.camera,
            &self.player,
            &self.chunk_manager,
            &self.tile_registry,
            &mut self.terrain_edit_controller,
            &mut self.signal_bus,
            &mut self.debug_batch,
            &mut self.ui_batch,
        );

        // Terrain editing input & execution
        self.terrain_edit_controller
            .handle_input(input, &self.tile_registry, &mut self.signal_bus);
        self.terrain_edit_controller.update(
            input,
            &self.camera,
            &mut self.chunk_manager,
            &self.tile_registry,
            &mut self.signal_bus,
        );

        renderer.chunk_pass.debug_terrain = self.terrain_edit_controller.debug_terrain;

        // Process chunk build/removal queues and upload any modified chunks to the GPU atlas
        self.chunk_manager.process(renderer, &mut self.signal_bus);
        self.dispatch_signals();
    }

    fn render(&mut self, renderer: &mut Renderer) {
        let (vis_min, vis_max) = self.camera.visible_world_bounds();
        self.chunk_manager.collect_visible_chunk_instances(
            vis_min,
            vis_max,
            &mut self.chunk_instances,
        );

        self.sprite_instances.clear();
        self.sprite_instances.push(SpriteInstance {
            center_pos: self.player.position.to_array(),
            size: renderer.sprite_pass.player_size.to_array(),
            tint: [1.0, 1.0, 1.0, 1.0],
        });

        let view_proj = self.camera.view_proj_matrix();
        renderer.render_frame(
            view_proj,
            self.camera.viewport_size,
            &self.chunk_instances,
            &self.sprite_instances,
            &self.debug_batch,
            &self.ui_batch.instances,
        );
    }

    fn on_resize(&mut self, width: u32, height: u32) {
        self.camera.set_viewport_size(width as f32, height as f32);
    }

    fn on_exit(&mut self) {
        self.chunk_manager.shutdown(&mut self.signal_bus);
    }
}
