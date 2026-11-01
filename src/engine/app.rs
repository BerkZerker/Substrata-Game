use std::sync::Arc;
use std::time::Instant;
use winit::application::ApplicationHandler;
use winit::dpi::LogicalSize;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::window::{Window, WindowAttributes, WindowId};

use crate::engine::input::InputState;
use crate::engine::renderer::Renderer;

const FIXED_PHYSICS_DT: f32 = 1.0 / 60.0;
const MAX_FRAME_DT: f32 = 0.1;

pub trait GameCallbacks {
    fn init(&mut self, renderer: &mut Renderer);
    fn physics_update(&mut self, dt: f32, input: &InputState);
    fn update(&mut self, dt: f32, fps: u32, input: &mut InputState, renderer: &mut Renderer);
    fn render(&mut self, renderer: &mut Renderer);
    fn on_resize(&mut self, width: u32, height: u32);
    fn on_exit(&mut self);
}

pub struct EngineConfig {
    pub title: String,
    pub width: u32,
    pub height: u32,
    pub chunk_size: u32,
    pub tile_texture_size: u32,
    pub tile_layers_rgba: Vec<Vec<u8>>,
    pub player_rgba: Vec<u8>,
    pub player_width: u32,
    pub player_height: u32,
}

pub struct EngineApp<G: GameCallbacks> {
    config: EngineConfig,
    game: G,
    window: Option<Arc<Window>>,
    renderer: Option<Renderer>,
    input: InputState,
    last_frame_instant: Instant,
    physics_accumulator: f32,
    physics_jump_buffered: bool,
    fps_counter: u32,
    fps_display: u32,
    fps_timer: f32,
}

impl<G: GameCallbacks> EngineApp<G> {
    pub fn new(config: EngineConfig, game: G) -> Self {
        Self {
            config,
            game,
            window: None,
            renderer: None,
            input: InputState::new(),
            last_frame_instant: Instant::now(),
            physics_accumulator: 0.0,
            physics_jump_buffered: false,
            fps_counter: 0,
            fps_display: 60,
            fps_timer: 0.0,
        }
    }

    pub fn run(mut self) {
        let event_loop = EventLoop::new().expect("Failed to create winit EventLoop");
        event_loop.set_control_flow(ControlFlow::Poll);
        event_loop
            .run_app(&mut self)
            .expect("EventLoop terminated with error");
    }
}

impl<G: GameCallbacks> ApplicationHandler for EngineApp<G> {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }

        let attrs = WindowAttributes::default()
            .with_title(&self.config.title)
            .with_inner_size(LogicalSize::new(self.config.width, self.config.height));

        let window = Arc::new(
            event_loop
                .create_window(attrs)
                .expect("Failed to create window"),
        );

        let mut renderer = Renderer::new(
            window.clone(),
            self.config.chunk_size,
            self.config.tile_texture_size,
            &self.config.tile_layers_rgba,
            &self.config.player_rgba,
            self.config.player_width,
            self.config.player_height,
        );

        let scale_factor = window.scale_factor() as f32;
        let logical_w = (renderer.size.0 as f32 / scale_factor).round().max(1.0) as u32;
        let logical_h = (renderer.size.1 as f32 / scale_factor).round().max(1.0) as u32;

        self.game.init(&mut renderer);
        self.game.on_resize(logical_w, logical_h);

        self.window = Some(window);
        self.renderer = Some(renderer);
        self.last_frame_instant = Instant::now();
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _window_id: WindowId,
        event: WindowEvent,
    ) {
        match event {
            WindowEvent::CloseRequested => {
                self.game.on_exit();
                event_loop.exit();
            }
            WindowEvent::Resized(new_size) => {
                if let Some(renderer) = &mut self.renderer {
                    renderer.resize(new_size.width, new_size.height);
                }
                let scale_factor = self
                    .window
                    .as_ref()
                    .map(|w| w.scale_factor() as f32)
                    .unwrap_or(1.0);
                let logical_w = (new_size.width as f32 / scale_factor).round().max(1.0) as u32;
                let logical_h = (new_size.height as f32 / scale_factor).round().max(1.0) as u32;
                self.game.on_resize(logical_w, logical_h);
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                if let Some(renderer) = &self.renderer {
                    let sf = scale_factor as f32;
                    let logical_w = (renderer.size.0 as f32 / sf).round().max(1.0) as u32;
                    let logical_h = (renderer.size.1 as f32 / sf).round().max(1.0) as u32;
                    self.game.on_resize(logical_w, logical_h);
                }
            }
            WindowEvent::KeyboardInput { event, .. } => {
                self.input
                    .handle_key_event(event.physical_key, event.state, event.repeat);
                if self.input.key_just_pressed(winit::keyboard::KeyCode::Space) {
                    self.physics_jump_buffered = true;
                }
            }
            WindowEvent::MouseInput { state, button, .. } => {
                self.input.handle_mouse_button(button, state);
            }
            WindowEvent::CursorMoved { position, .. } => {
                let scale_factor = self
                    .window
                    .as_ref()
                    .map(|w| w.scale_factor() as f32)
                    .unwrap_or(1.0);
                self.input.handle_cursor_moved(
                    (position.x as f32) / scale_factor,
                    (position.y as f32) / scale_factor,
                );
            }
            WindowEvent::MouseWheel { delta, .. } => {
                self.input.handle_mouse_wheel(delta);
            }
            WindowEvent::RedrawRequested => {
                let now = Instant::now();
                let dt = (now - self.last_frame_instant)
                    .as_secs_f32()
                    .clamp(0.0001, MAX_FRAME_DT);
                self.last_frame_instant = now;

                self.fps_counter += 1;
                self.fps_timer += dt;
                if self.fps_timer >= 0.5 {
                    self.fps_display = ((self.fps_counter as f32) / self.fps_timer).round() as u32;
                    self.fps_counter = 0;
                    self.fps_timer = 0.0;
                }

                if let Some(renderer) = &mut self.renderer {
                    // Run update first so UI can consume mouse clicks and hotkeys are processed
                    self.game
                        .update(dt, self.fps_display, &mut self.input, renderer);

                    // Fixed 60 Hz physics loop matching Godot's _physics_process
                    self.physics_accumulator += dt;
                    while self.physics_accumulator >= FIXED_PHYSICS_DT {
                        self.game.physics_update(FIXED_PHYSICS_DT, &self.input);
                        self.physics_accumulator -= FIXED_PHYSICS_DT;
                    }

                    self.game.render(renderer);
                }

                self.input.end_frame();
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(window) = &self.window {
            window.request_redraw();
        }
    }
}
