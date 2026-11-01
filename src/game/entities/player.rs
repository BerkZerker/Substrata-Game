use glam::{IVec2, Vec2};
use winit::keyboard::KeyCode;

use crate::engine::input::InputState;
use crate::game::physics::movement::MovementController;
use crate::game::settings::CHUNK_SIZE;
use crate::game::signals::{GameSignal, SignalBus};
use crate::game::tiles::TileRegistry;
use crate::game::world::chunk_manager::ChunkManager;

/// Player entity ported from `src/entities/player.gd` and `src/entities/player.tscn`.
pub struct Player {
    pub position: Vec2,
    pub movement: MovementController,
    current_chunk: IVec2,
    has_emitted_initial_chunk: bool,
    jump_buffered: bool,
}

impl Default for Player {
    fn default() -> Self {
        Self::new(Vec2::new(94.0, -112.0))
    }
}

impl Player {
    pub fn new(start_pos: Vec2) -> Self {
        Self {
            position: start_pos,
            movement: MovementController::new(),
            current_chunk: IVec2::ZERO,
            has_emitted_initial_chunk: false,
            jump_buffered: false,
        }
    }

    pub fn buffer_input(&mut self, input: &InputState) {
        if input.key_just_pressed(KeyCode::Space) {
            self.jump_buffered = true;
        }
    }

    pub fn physics_process(
        &mut self,
        delta: f32,
        input: &InputState,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
        signal_bus: &mut SignalBus,
    ) {
        // Only run physics once the chunk containing the player is loaded so the player
        // doesn't fall into the void while initial worker threads finish the spawn chunk.
        let player_chunk = Self::pos_to_chunk(self.position);
        if chunk_manager.get_chunk_at(player_chunk).is_some() {
            let input_axis = input.get_axis(KeyCode::KeyA, KeyCode::KeyD);
            let jump_pressed = self.jump_buffered || input.key_just_pressed(KeyCode::Space);
            self.jump_buffered = false;

            self.position = self.movement.move_body(
                self.position,
                input_axis,
                jump_pressed,
                delta,
                chunk_manager,
                tile_registry,
            );
        }

        self.update_current_chunk(signal_bus);
    }

    pub fn get_movement_velocity(&self) -> Vec2 {
        self.movement.velocity
    }

    pub fn get_on_floor(&self) -> bool {
        self.movement.is_on_floor
    }

    pub fn pos_to_chunk(pos: Vec2) -> IVec2 {
        IVec2::new(
            (pos.x / CHUNK_SIZE as f32).floor() as i32,
            (pos.y / CHUNK_SIZE as f32).floor() as i32,
        )
    }

    pub fn update_current_chunk(&mut self, signal_bus: &mut SignalBus) {
        let new_chunk = Self::pos_to_chunk(self.position);
        if !self.has_emitted_initial_chunk || new_chunk != self.current_chunk {
            self.has_emitted_initial_chunk = true;
            self.current_chunk = new_chunk;
            signal_bus.emit(GameSignal::PlayerChunkChanged(self.current_chunk));
        }
    }
}
