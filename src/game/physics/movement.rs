use glam::Vec2;

use crate::game::physics::collision::CollisionDetector;
use crate::game::tiles::TileRegistry;
use crate::game::world::chunk_manager::ChunkManager;

/// Reusable physics controller for gravity, horizontal acceleration/friction,
/// coyote jump timing, and step-up mechanics (`src/physics/movement_controller.gd`).
#[derive(Clone, Debug)]
pub struct MovementController {
    pub speed: f32,
    pub acceleration: f32,
    pub friction: f32,
    pub jump_velocity: f32,
    pub gravity: f32,
    pub step_height: f32,
    pub coyote_time: f32,
    pub collision_box_size: Vec2,

    pub velocity: Vec2,
    pub is_on_floor: bool,
    coyote_timer: f32,
}

impl Default for MovementController {
    fn default() -> Self {
        Self {
            speed: 180.0,
            acceleration: 1500.0,
            friction: 2000.0,
            jump_velocity: -400.0,
            gravity: 800.0,
            step_height: 6.0,
            coyote_time: 0.1,
            collision_box_size: Vec2::new(10.0, 16.0),
            velocity: Vec2::ZERO,
            is_on_floor: false,
            coyote_timer: 0.0,
        }
    }
}

impl MovementController {
    pub fn new() -> Self {
        Self::default()
    }

    #[inline]
    fn move_toward(from: f32, to: f32, max_delta: f32) -> f32 {
        if (to - from).abs() <= max_delta {
            to
        } else {
            from + (to - from).signum() * max_delta
        }
    }

    pub fn move_body(
        &mut self,
        mut current_pos: Vec2,
        input_axis: f32,
        jump_pressed: bool,
        delta: f32,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
    ) -> Vec2 {
        // Coyote timer
        if self.is_on_floor {
            self.coyote_timer = self.coyote_time;
        } else {
            self.coyote_timer -= delta;
        }

        // Gravity
        self.velocity.y += self.gravity * delta;

        // Horizontal movement
        if input_axis != 0.0 {
            self.velocity.x = Self::move_toward(
                self.velocity.x,
                input_axis * self.speed,
                self.acceleration * delta,
            );
        } else {
            self.velocity.x = Self::move_toward(self.velocity.x, 0.0, self.friction * delta);
        }

        // Jump
        if jump_pressed && (self.is_on_floor || self.coyote_timer > 0.0) {
            self.velocity.y = self.jump_velocity;
            self.is_on_floor = false;
            self.coyote_timer = 0.0;
        }

        // Horizontal sweep
        let start_pos = current_pos;
        let x_move = Vec2::new(self.velocity.x * delta, 0.0);
        let result_x = CollisionDetector::sweep_aabb(
            current_pos,
            self.collision_box_size,
            x_move,
            chunk_manager,
            tile_registry,
        );

        if result_x.collided && self.is_on_floor && self.velocity.x.abs() > 0.1 {
            if let Some(stepped) =
                self.try_step_up(x_move, start_pos, chunk_manager, tile_registry)
            {
                current_pos = stepped;
            } else {
                current_pos = result_x.position;
                self.velocity.x = 0.0;
            }
        } else {
            current_pos = result_x.position;
            if result_x.collided {
                self.velocity.x = 0.0;
            }
        }

        // Vertical sweep
        let y_move = Vec2::new(0.0, self.velocity.y * delta);
        let result_y = CollisionDetector::sweep_aabb(
            current_pos,
            self.collision_box_size,
            y_move,
            chunk_manager,
            tile_registry,
        );

        current_pos = result_y.position;

        if result_y.collided {
            self.velocity.y = 0.0;
            if result_y.normal.y < -0.5 {
                self.is_on_floor = true;
            }
        } else {
            self.is_on_floor = false;
        }

        current_pos
    }

    fn try_step_up(
        &self,
        intended_move: Vec2,
        original_pos: Vec2,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
    ) -> Option<Vec2> {
        let lifted_pos = original_pos + Vec2::new(0.0, -self.step_height);

        if CollisionDetector::intersect_aabb(
            lifted_pos,
            self.collision_box_size,
            chunk_manager,
            tile_registry,
        ) {
            return None;
        }

        let result_fwd = CollisionDetector::sweep_aabb(
            lifted_pos,
            self.collision_box_size,
            intended_move,
            chunk_manager,
            tile_registry,
        );

        if result_fwd.position.distance_squared(lifted_pos) < 0.1 {
            return None;
        }

        let snap_vec = Vec2::new(0.0, self.step_height * 2.0);
        let result_down = CollisionDetector::sweep_aabb(
            result_fwd.position,
            self.collision_box_size,
            snap_vec,
            chunk_manager,
            tile_registry,
        );

        if result_down.collided && result_down.normal.y < -0.5 {
            return Some(result_down.position);
        }

        None
    }
}
