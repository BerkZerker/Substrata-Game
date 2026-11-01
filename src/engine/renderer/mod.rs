pub mod chunk_pass;
pub mod debug_pass;
pub mod sprite_pass;
pub mod ui_pass;

use std::sync::Arc;
use glam::{Mat4, Vec2};
use winit::window::Window;

use self::chunk_pass::{ChunkInstance, ChunkPass};
use self::debug_pass::{DebugBatch, DebugPass};
use self::sprite_pass::{SpriteInstance, SpritePass};
use self::ui_pass::{UiInstance, UiPass};

pub struct Renderer {
    pub surface: wgpu::Surface<'static>,
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub config: wgpu::SurfaceConfiguration,
    pub render_format: wgpu::TextureFormat,
    pub size: (u32, u32),
    pub chunk_pass: ChunkPass,
    pub sprite_pass: SpritePass,
    pub debug_pass: DebugPass,
    pub ui_pass: UiPass,
}

impl Renderer {
    pub fn new(
        window: Arc<Window>,
        chunk_size: u32,
        tile_texture_size: u32,
        tile_layers_rgba: &[Vec<u8>],
        player_rgba: &[u8],
        player_width: u32,
        player_height: u32,
    ) -> Self {
        let window_size = window.inner_size();
        let width = window_size.width.max(1);
        let height = window_size.height.max(1);

        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::PRIMARY,
            ..Default::default()
        });

        let surface = instance
            .create_surface(window)
            .expect("Failed to create wgpu surface");

        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
        }))
        .expect("Failed to find suitable GPU adapter");

        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("substrata_device"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::default(),
                memory_hints: wgpu::MemoryHints::Performance,
            },
            None,
        ))
        .expect("Failed to create wgpu device");

        let caps = surface.get_capabilities(&adapter);
        // Prefer non-sRGB surface/view format so 2D pixel art and colors match Godot's gl_compatibility
        let surface_format = caps
            .formats
            .iter()
            .copied()
            .find(|f| !f.is_srgb())
            .unwrap_or(caps.formats[0]);
        let render_format = surface_format.remove_srgb_suffix();
        let view_formats = if render_format != surface_format {
            vec![render_format]
        } else {
            vec![]
        };

        let present_mode = if caps.present_modes.contains(&wgpu::PresentMode::AutoVsync) {
            wgpu::PresentMode::AutoVsync
        } else {
            wgpu::PresentMode::Fifo
        };

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_format,
            width,
            height,
            present_mode,
            alpha_mode: caps.alpha_modes[0],
            view_formats,
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);

        let chunk_pass = ChunkPass::new(
            &device,
            &queue,
            render_format,
            chunk_size,
            tile_texture_size,
            tile_layers_rgba,
        );

        let sprite_pass = SpritePass::new(
            &device,
            &queue,
            render_format,
            player_rgba,
            player_width,
            player_height,
        );

        let debug_pass = DebugPass::new(&device, render_format);

        let ui_pass = UiPass::new(
            &device,
            &queue,
            render_format,
            chunk_pass.tile_array_view(),
            chunk_pass.tile_sampler(),
        );

        Self {
            surface,
            device,
            queue,
            config,
            render_format,
            size: (width, height),
            chunk_pass,
            sprite_pass,
            debug_pass,
            ui_pass,
        }
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        if width > 0 && height > 0 {
            self.size = (width, height);
            self.config.width = width;
            self.config.height = height;
            self.surface.configure(&self.device, &self.config);
        }
    }

    pub fn render_frame(
        &mut self,
        view_proj: Mat4,
        screen_size: Vec2,
        chunk_instances: &[ChunkInstance],
        sprite_instances: &[SpriteInstance],
        debug_batch: &DebugBatch,
        ui_instances: &[UiInstance],
    ) {
        let output = match self.surface.get_current_texture() {
            Ok(frame) => frame,
            Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                self.surface.configure(&self.device, &self.config);
                return;
            }
            Err(e) => {
                log::warn!("Surface error: {e:?}");
                return;
            }
        };

        let view = output.texture.create_view(&wgpu::TextureViewDescriptor {
            format: Some(self.render_format),
            ..Default::default()
        });

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("frame_encoder"),
            });

        {
            // Default Godot 2D clear color: Color(0.3, 0.3, 0.3, 1.0)
            let mut render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("main_render_pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.3,
                            g: 0.3,
                            b: 0.3,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });

            self.chunk_pass
                .render(&self.queue, &mut render_pass, view_proj, chunk_instances);
            self.sprite_pass
                .render(&self.queue, &mut render_pass, view_proj, sprite_instances);
            self.debug_pass
                .render(&self.queue, &mut render_pass, view_proj, debug_batch);
            self.ui_pass
                .render(&self.queue, &mut render_pass, screen_size, ui_instances);
        }

        self.queue.submit( std::iter::once(encoder.finish()) );
        output.present();
    }
}
