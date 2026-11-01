use glam::Vec2;
use winit::keyboard::KeyCode;

use crate::engine::camera::Camera2D;
use crate::engine::input::InputState;

/// Smooth-follow camera with mouse wheel zoom and zoom presets,
/// ported from `src/camera/camera_controller.gd`.
pub struct CameraController {
    pub smoothing: f32,
    pub zoom_presets: Vec<f32>,
    pub zoom_step: f32,
    pub min_zoom: Vec2,
    pub max_zoom: Vec2,
    current_preset_index: usize,
}

impl Default for CameraController {
    fn default() -> Self {
        Self {
            smoothing: 10.0,
            zoom_presets: vec![1.0, 2.0, 4.0, 8.0],
            zoom_step: 0.1,
            min_zoom: Vec2::splat(0.5),
            max_zoom: Vec2::splat(10.0),
            current_preset_index: 2, // Default to 4x
        }
    }
}

impl CameraController {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn handle_input(&mut self, input: &InputState, camera: &mut Camera2D) {
        if input.scroll_delta.abs() > 0.001 {
            let ticks = input.scroll_delta.round() as i32;
            let ticks = if ticks == 0 {
                input.scroll_delta.signum() as i32
            } else {
                ticks
            };
            for _ in 0..ticks.unsigned_abs() {
                let factor = if ticks > 0 {
                    1.0 + self.zoom_step
                } else {
                    1.0 - self.zoom_step
                };
                let new_val = (camera.zoom.x * factor).clamp(self.min_zoom.x, self.max_zoom.x);
                camera.zoom = Vec2::splat(new_val);
            }
        }

        if input.key_just_pressed(KeyCode::KeyZ) && !self.zoom_presets.is_empty() {
            self.current_preset_index = (self.current_preset_index + 1) % self.zoom_presets.len();
            let preset = self.zoom_presets[self.current_preset_index];
            camera.zoom = Vec2::splat(preset);
        }
    }

    pub fn update(&self, dt: f32, target_pos: Vec2, camera: &mut Camera2D) {
        // Frame-rate independent smoothing: 1.0 - exp(-smoothing * delta)
        let weight = 1.0 - (-self.smoothing * dt).exp();
        camera.position = camera.position.lerp(target_pos, weight);
    }
}
