use bytemuck::{Pod, Zeroable};
use glam::{Mat4, Vec2};
use wgpu::util::DeviceExt;

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
struct DebugUniforms {
    view_proj: [[f32; 4]; 4],
}

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct DebugVertex {
    pub pos: [f32; 2],
    pub color: [f32; 4],
}

/// Immediate-mode 2D world-space primitive batcher (`BrushPreview` circle, `ChunkDebugOverlay` F4).
#[derive(Default)]
pub struct DebugBatch {
    pub vertices: Vec<DebugVertex>,
}

impl DebugBatch {
    pub fn new() -> Self {
        Self {
            vertices: Vec::with_capacity(8192),
        }
    }

    pub fn clear(&mut self) {
        self.vertices.clear();
    }

    pub fn draw_rect_filled(&mut self, pos: Vec2, size: Vec2, color: [f32; 4]) {
        let p0 = [pos.x, pos.y];
        let p1 = [pos.x + size.x, pos.y];
        let p2 = [pos.x + size.x, pos.y + size.y];
        let p3 = [pos.x, pos.y + size.y];
        self.vertices.extend_from_slice(&[
            DebugVertex { pos: p0, color },
            DebugVertex { pos: p1, color },
            DebugVertex { pos: p2, color },
            DebugVertex { pos: p0, color },
            DebugVertex { pos: p2, color },
            DebugVertex { pos: p3, color },
        ]);
    }

    pub fn draw_line(&mut self, a: Vec2, b: Vec2, thickness: f32, color: [f32; 4]) {
        let dir = b - a;
        let len = dir.length();
        if len < 1e-5 {
            return;
        }
        let normal = Vec2::new(-dir.y / len, dir.x / len) * (thickness * 0.5);
        let p0 = (a + normal).to_array();
        let p1 = (b + normal).to_array();
        let p2 = (b - normal).to_array();
        let p3 = (a - normal).to_array();
        self.vertices.extend_from_slice(&[
            DebugVertex { pos: p0, color },
            DebugVertex { pos: p1, color },
            DebugVertex { pos: p2, color },
            DebugVertex { pos: p0, color },
            DebugVertex { pos: p2, color },
            DebugVertex { pos: p3, color },
        ]);
    }

    pub fn draw_rect_outline(&mut self, pos: Vec2, size: Vec2, thickness: f32, color: [f32; 4]) {
        let tl = pos;
        let tr = Vec2::new(pos.x + size.x, pos.y);
        let br = pos + size;
        let bl = Vec2::new(pos.x, pos.y + size.y);
        self.draw_line(tl, tr, thickness, color);
        self.draw_line(tr, br, thickness, color);
        self.draw_line(br, bl, thickness, color);
        self.draw_line(bl, tl, thickness, color);
    }

    pub fn draw_circle_outline(
        &mut self,
        center: Vec2,
        radius: f32,
        thickness: f32,
        segments: usize,
        color: [f32; 4],
    ) {
        if radius <= 0.0 || segments < 3 {
            return;
        }
        let step = std::f32::consts::TAU / segments as f32;
        for i in 0..segments {
            let a0 = i as f32 * step;
            let a1 = (i + 1) as f32 * step;
            let p0 = center + Vec2::new(a0.cos(), a0.sin()) * radius;
            let p1 = center + Vec2::new(a1.cos(), a1.sin()) * radius;
            self.draw_line(p0, p1, thickness, color);
        }
    }
}

pub struct DebugPass {
    pipeline: wgpu::RenderPipeline,
    uniform_buffer: wgpu::Buffer,
    vertex_buffer: wgpu::Buffer,
    vertex_capacity: usize,
    bind_group: wgpu::BindGroup,
}

impl DebugPass {
    pub fn new(device: &wgpu::Device, surface_format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("debug_shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shaders/debug.wgsl").into()),
        });

        let uniforms = DebugUniforms {
            view_proj: Mat4::IDENTITY.to_cols_array_2d(),
        };
        let uniform_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("debug_uniform_buffer"),
            contents: bytemuck::cast_slice(&[uniforms]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("debug_bind_group_layout"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });

        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("debug_bind_group"),
            layout: &bind_group_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: uniform_buffer.as_entire_binding(),
            }],
        });

        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("debug_pipeline_layout"),
            bind_group_layouts: &[&bind_group_layout],
            push_constant_ranges: &[],
        });

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("debug_pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<DebugVertex>() as wgpu::BufferAddress,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &[
                        wgpu::VertexAttribute {
                            offset: 0,
                            shader_location: 0,
                            format: wgpu::VertexFormat::Float32x2,
                        },
                        wgpu::VertexAttribute {
                            offset: 8,
                            shader_location: 1,
                            format: wgpu::VertexFormat::Float32x4,
                        },
                    ],
                }],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: surface_format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        let vertex_capacity = 131_072;
        let vertex_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("debug_vertex_buffer"),
            size: (vertex_capacity * std::mem::size_of::<DebugVertex>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        Self {
            pipeline,
            uniform_buffer,
            vertex_buffer,
            vertex_capacity,
            bind_group,
        }
    }

    pub fn render<'a>(
        &'a self,
        queue: &wgpu::Queue,
        render_pass: &mut wgpu::RenderPass<'a>,
        view_proj: Mat4,
        batch: &DebugBatch,
    ) {
        if batch.vertices.is_empty() {
            return;
        }

        let uniforms = DebugUniforms {
            view_proj: view_proj.to_cols_array_2d(),
        };
        queue.write_buffer(&self.uniform_buffer, 0, bytemuck::cast_slice(&[uniforms]));

        let count = batch.vertices.len().min(self.vertex_capacity);
        queue.write_buffer(
            &self.vertex_buffer,
            0,
            bytemuck::cast_slice(&batch.vertices[..count]),
        );

        render_pass.set_pipeline(&self.pipeline);
        render_pass.set_bind_group(0, &self.bind_group, &[]);
        render_pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
        render_pass.draw(0..count as u32, 0..1);
    }
}
