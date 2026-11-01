use glam::{Mat4, Vec2};

/// 2D orthographic camera matching Godot's `Camera2D` conventions:
/// - World coordinates: +X right, +Y down, 1 unit = 1 pixel at 1.0x zoom.
/// - `zoom`: higher values zoom in (e.g. `4.0` means each world unit is 4 screen pixels).
#[derive(Clone, Debug)]
pub struct Camera2D {
    pub position: Vec2,
    pub zoom: Vec2,
    pub viewport_size: Vec2,
}

impl Default for Camera2D {
    fn default() -> Self {
        Self {
            position: Vec2::ZERO,
            zoom: Vec2::splat(4.0),
            viewport_size: Vec2::new(1920.0, 1080.0),
        }
    }
}

impl Camera2D {
    pub fn new(viewport_width: f32, viewport_height: f32) -> Self {
        Self {
            viewport_size: Vec2::new(viewport_width.max(1.0), viewport_height.max(1.0)),
            ..Self::default()
        }
    }

    pub fn set_viewport_size(&mut self, width: f32, height: f32) {
        self.viewport_size = Vec2::new(width.max(1.0), height.max(1.0));
    }

    /// Half-extents of the camera view in world units.
    pub fn world_half_extents(&self) -> Vec2 {
        (self.viewport_size * 0.5) / self.zoom.max(Vec2::splat(0.001))
    }

    /// Returns `(min_world, max_world)` visible bounds for frustum culling.
    pub fn visible_world_bounds(&self) -> (Vec2, Vec2) {
        let half = self.world_half_extents();
        (self.position - half, self.position + half)
    }

    /// Orthographic view-projection matrix mapping world coordinates `(x, y)`
    /// (with +Y down) into WebGPU NDC (`x: -1..1, y: -1..1, z: 0..1`).
    pub fn view_proj_matrix(&self) -> Mat4 {
        let (min, max) = self.visible_world_bounds();
        // Note: bottom is max.y and top is min.y because world +Y points down
        Mat4::orthographic_rh(min.x, max.x, max.y, min.y, -100.0, 100.0)
    }

    /// Converts screen pixel coordinates `(0..viewport_width, 0..viewport_height)`
    /// into world coordinates, matching `Camera2D.get_global_mouse_position()`.
    pub fn screen_to_world(&self, screen_pos: Vec2) -> Vec2 {
        let centered_px = screen_pos - self.viewport_size * 0.5;
        self.position + centered_px / self.zoom.max(Vec2::splat(0.001))
    }

    /// Converts world coordinates into screen pixel coordinates.
    pub fn world_to_screen(&self, world_pos: Vec2) -> Vec2 {
        (world_pos - self.position) * self.zoom + self.viewport_size * 0.5
    }
}
