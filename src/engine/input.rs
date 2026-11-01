use std::collections::HashSet;
use glam::Vec2;
use winit::event::{ElementState, MouseButton, MouseScrollDelta};
use winit::keyboard::{KeyCode, PhysicalKey};

/// Tracks keyboard and mouse input state across a single frame.
/// Supports `ui_consumed_mouse` so UI widgets (like the hotbar) can consume
/// clicks before gameplay systems (`TerrainEditController`) process them,
/// mirroring Godot's `_unhandled_input` behavior.
#[derive(Default)]
pub struct InputState {
    keys_held: HashSet<KeyCode>,
    keys_just_pressed: HashSet<KeyCode>,
    keys_just_released: HashSet<KeyCode>,

    mouse_held: HashSet<MouseButton>,
    mouse_just_pressed: HashSet<MouseButton>,
    mouse_just_released: HashSet<MouseButton>,

    pub mouse_pos: Vec2,
    pub scroll_delta: f32,
    pub ui_consumed_mouse: bool,
}

impl InputState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Clears per-frame transition sets (`just_pressed`, `just_released`, `scroll_delta`).
    pub fn end_frame(&mut self) {
        self.keys_just_pressed.clear();
        self.keys_just_released.clear();
        self.mouse_just_pressed.clear();
        self.mouse_just_released.clear();
        self.scroll_delta = 0.0;
        self.ui_consumed_mouse = false;
    }

    pub fn handle_key_event(&mut self, physical_key: PhysicalKey, state: ElementState, repeat: bool) {
        let PhysicalKey::Code(code) = physical_key else {
            return;
        };
        match state {
            ElementState::Pressed => {
                if !repeat && self.keys_held.insert(code) {
                    self.keys_just_pressed.insert(code);
                }
            }
            ElementState::Released => {
                if self.keys_held.remove(&code) {
                    self.keys_just_released.insert(code);
                }
            }
        }
    }

    pub fn handle_mouse_button(&mut self, button: MouseButton, state: ElementState) {
        match state {
            ElementState::Pressed => {
                if self.mouse_held.insert(button) {
                    self.mouse_just_pressed.insert(button);
                }
            }
            ElementState::Released => {
                if self.mouse_held.remove(&button) {
                    self.mouse_just_released.insert(button);
                }
            }
        }
    }

    pub fn handle_cursor_moved(&mut self, x: f32, y: f32) {
        self.mouse_pos = Vec2::new(x, y);
    }

    pub fn handle_mouse_wheel(&mut self, delta: MouseScrollDelta) {
        let ticks = match delta {
            MouseScrollDelta::LineDelta(_, y) => y,
            MouseScrollDelta::PixelDelta(pos) => (pos.y as f32 / 24.0).clamp(-3.0, 3.0),
        };
        self.scroll_delta += ticks;
    }

    pub fn key_held(&self, code: KeyCode) -> bool {
        self.keys_held.contains(&code)
    }

    pub fn key_just_pressed(&self, code: KeyCode) -> bool {
        self.keys_just_pressed.contains(&code)
    }

    pub fn mouse_held(&self, button: MouseButton) -> bool {
        self.mouse_held.contains(&button)
    }

    pub fn mouse_just_pressed(&self, button: MouseButton) -> bool {
        self.mouse_just_pressed.contains(&button)
    }

    pub fn mouse_just_released(&self, button: MouseButton) -> bool {
        self.mouse_just_released.contains(&button)
    }

    /// Returns a 1D movement axis in `[-1.0, 1.0]` matching `Input.get_axis(neg, pos)`.
    pub fn get_axis(&self, negative: KeyCode, positive: KeyCode) -> f32 {
        let neg = if self.key_held(negative) { -1.0 } else { 0.0 };
        let pos = if self.key_held(positive) { 1.0 } else { 0.0 };
        neg + pos
    }
}
