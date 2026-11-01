use glam::{IVec2, Vec2};

use crate::game::tiles::TileRegistry;
use crate::game::world::chunk_manager::ChunkManager;

const VELOCITY_EPSILON: f32 = 0.0001;
const TILE_CENTER_OFFSET: Vec2 = Vec2::new(0.5, 0.5);

#[derive(Clone, Copy, Debug)]
pub struct SweepResult {
    pub position: Vec2,
    pub velocity: Vec2,
    pub collided: bool,
    pub normal: Vec2,
}

/// Swept AABB collision detection against the tile grid,
/// ported 1:1 from `src/physics/collision_detector.gd`.
pub struct CollisionDetector;

impl CollisionDetector {
    pub fn sweep_aabb(
        aabb_pos: Vec2,
        aabb_size: Vec2,
        velocity: Vec2,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
    ) -> SweepResult {
        let mut result = SweepResult {
            position: aabb_pos,
            velocity,
            collided: false,
            normal: Vec2::ZERO,
        };

        if velocity.length_squared() < VELOCITY_EPSILON {
            return result;
        }

        let half_size = aabb_size * 0.5;
        let aabb_min = aabb_pos - half_size;
        let aabb_max = aabb_pos + half_size;

        let target_pos = aabb_pos + velocity;
        let target_min = target_pos - half_size;
        let target_max = target_pos + half_size;

        let check_min = aabb_min.min(target_min);
        let check_max = aabb_max.max(target_max);

        let tile_min = IVec2::new(check_min.x.floor() as i32, check_min.y.floor() as i32);
        let tile_max = IVec2::new(check_max.x.ceil() as i32, check_max.y.ceil() as i32);

        // Sweep along X axis first
        let x_collision = Self::sweep_axis(
            aabb_pos,
            half_size,
            velocity,
            Vec2::X,
            tile_min,
            tile_max,
            chunk_manager,
            tile_registry,
        );

        let aabb_pos = x_collision.position;
        let velocity = x_collision.velocity;
        if x_collision.collided {
            result.collided = true;
            result.normal = x_collision.normal;
        }

        // Recalculate bounds for Y sweep based on X result
        let aabb_min = aabb_pos - half_size;
        let aabb_max = aabb_pos + half_size;
        let target_pos = aabb_pos + velocity;
        let target_min = target_pos - half_size;
        let target_max = target_pos + half_size;
        let check_min = aabb_min.min(target_min);
        let check_max = aabb_max.max(target_max);
        let tile_min = IVec2::new(check_min.x.floor() as i32, check_min.y.floor() as i32);
        let tile_max = IVec2::new(check_max.x.ceil() as i32, check_max.y.ceil() as i32);

        // Sweep along Y axis
        let y_collision = Self::sweep_axis(
            aabb_pos,
            half_size,
            velocity,
            Vec2::Y,
            tile_min,
            tile_max,
            chunk_manager,
            tile_registry,
        );

        result.position = y_collision.position;
        result.velocity = y_collision.velocity;
        if y_collision.collided {
            result.collided = true;
            result.normal = y_collision.normal;
        }

        result
    }

    pub fn intersect_aabb(
        aabb_pos: Vec2,
        aabb_size: Vec2,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
    ) -> bool {
        let half_size = aabb_size * 0.5;
        let aabb_min = aabb_pos - half_size;
        let aabb_max = aabb_pos + half_size;

        let tile_min = IVec2::new(aabb_min.x.floor() as i32, aabb_min.y.floor() as i32);
        let tile_max = IVec2::new(aabb_max.x.ceil() as i32, aabb_max.y.ceil() as i32);

        for tile_x in tile_min.x..tile_max.x {
            for tile_y in tile_min.y..tile_max.y {
                let check_pos = Vec2::new(tile_x as f32, tile_y as f32) + TILE_CENTER_OFFSET;
                if chunk_manager.is_solid_at_world_pos(check_pos, tile_registry) {
                    return true;
                }
            }
        }
        false
    }

    #[allow(clippy::too_many_arguments)]
    fn sweep_axis(
        aabb_pos: Vec2,
        half_size: Vec2,
        velocity: Vec2,
        axis: Vec2,
        tile_min: IVec2,
        tile_max: IVec2,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
    ) -> SweepResult {
        let mut result = SweepResult {
            position: aabb_pos,
            velocity,
            collided: false,
            normal: Vec2::ZERO,
        };

        let axis_velocity = velocity.dot(axis) * axis;
        if axis_velocity.length_squared() < VELOCITY_EPSILON {
            return result;
        }

        let target_pos = aabb_pos + axis_velocity;
        let step_direction = if axis_velocity.dot(axis) > 0.0 {
            1.0
        } else {
            -1.0
        };

        let mut closest_hit_time = 1.0f32;
        let mut hit_normal = Vec2::ZERO;

        for tile_x in tile_min.x..=tile_max.x {
            for tile_y in tile_min.y..=tile_max.y {
                let tile_world_pos = Vec2::new(tile_x as f32, tile_y as f32);
                if !chunk_manager
                    .is_solid_at_world_pos(tile_world_pos + TILE_CENTER_OFFSET, tile_registry)
                {
                    continue;
                }

                let hit_time =
                    Self::aabb_vs_tile_sweep(aabb_pos, half_size, axis_velocity, tile_world_pos);
                if hit_time >= 0.0 && hit_time < closest_hit_time {
                    closest_hit_time = hit_time;
                    if axis.x.abs() > 0.5 {
                        hit_normal = Vec2::new(-step_direction, 0.0);
                    } else {
                        hit_normal = Vec2::new(0.0, -step_direction);
                    }
                }
            }
        }

        if closest_hit_time < 1.0 {
            result.collided = true;
            result.position = aabb_pos + axis_velocity * closest_hit_time;
            result.velocity = velocity - velocity.dot(hit_normal) * hit_normal;
            result.normal = hit_normal;
        } else {
            result.position = target_pos;
        }

        result
    }

    fn aabb_vs_tile_sweep(
        aabb_pos: Vec2,
        half_size: Vec2,
        velocity: Vec2,
        tile_pos: Vec2,
    ) -> f32 {
        let tile_min = tile_pos;
        let tile_max = tile_pos + Vec2::ONE;

        let aabb_min = aabb_pos - half_size;
        let aabb_max = aabb_pos + half_size;

        let (entry_x, exit_x) = if velocity.x > 0.0 {
            (
                (tile_min.x - aabb_max.x) / velocity.x,
                (tile_max.x - aabb_min.x) / velocity.x,
            )
        } else if velocity.x < 0.0 {
            (
                (tile_max.x - aabb_min.x) / velocity.x,
                (tile_min.x - aabb_max.x) / velocity.x,
            )
        } else {
            if aabb_max.x <= tile_min.x || aabb_min.x >= tile_max.x {
                return -1.0;
            }
            (f32::NEG_INFINITY, f32::INFINITY)
        };

        let (entry_y, exit_y) = if velocity.y > 0.0 {
            (
                (tile_min.y - aabb_max.y) / velocity.y,
                (tile_max.y - aabb_min.y) / velocity.y,
            )
        } else if velocity.y < 0.0 {
            (
                (tile_max.y - aabb_min.y) / velocity.y,
                (tile_min.y - aabb_max.y) / velocity.y,
            )
        } else {
            if aabb_max.y <= tile_min.y || aabb_min.y >= tile_max.y {
                return -1.0;
            }
            (f32::NEG_INFINITY, f32::INFINITY)
        };

        let entry = entry_x.max(entry_y);
        let exit = exit_x.min(exit_y);

        if entry > exit || (entry_x < 0.0 && entry_y < 0.0) || entry > 1.0 {
            return -1.0;
        }

        entry.max(0.0)
    }
}
