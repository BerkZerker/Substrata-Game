use bytemuck::{Pod, Zeroable};
use glam::Mat4;
use wgpu::util::DeviceExt;

/// Number of 32x32 chunk slots per side in the GPU chunk data atlas (64x64 = 4096 chunks max).
pub const ATLAS_SLOTS_PER_SIDE: u32 = 64;
pub const MAX_ATLAS_SLOTS: u32 = ATLAS_SLOTS_PER_SIDE * ATLAS_SLOTS_PER_SIDE;

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
struct ChunkUniforms {
    view_proj: [[f32; 4]; 4],
    texture_size: [f32; 2],
    chunk_size: f32,
    debug_terrain: u32,
}

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct ChunkInstance {
    pub chunk_world_pos: [f32; 2],
    pub atlas_slot: [u32; 2],
}

/// GPU rendering pass for terrain chunks.
/// Uses a `Rg8Unorm` chunk data atlas and a `Rgba8Unorm` `Texture2DArray` tile atlas
/// to draw all visible chunks in a single instanced draw call.
pub struct ChunkPass {
    pipeline: wgpu::RenderPipeline,
    uniform_buffer: wgpu::Buffer,
    instance_buffer: wgpu::Buffer,
    instance_capacity: usize,
    chunk_atlas_texture: wgpu::Texture,
    _chunk_atlas_view: wgpu::TextureView,
    _tile_array_texture: wgpu::Texture,
    tile_array_view: wgpu::TextureView,
    tile_sampler: wgpu::Sampler,
    _bind_group_layout: wgpu::BindGroupLayout,
    bind_group: wgpu::BindGroup,
    free_slots: Vec<u32>,
    chunk_size: u32,
    tile_texture_size: u32,
    pub debug_terrain: bool,
}

impl ChunkPass {
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        surface_format: wgpu::TextureFormat,
        chunk_size: u32,
        tile_texture_size: u32,
        tile_layers_rgba: &[Vec<u8>],
    ) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("terrain_shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shaders/terrain.wgsl").into()),
        });

        let atlas_dim = ATLAS_SLOTS_PER_SIDE * chunk_size;
        let chunk_atlas_texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("chunk_data_atlas"),
            size: wgpu::Extent3d {
                width: atlas_dim,
                height: atlas_dim,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rg8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let chunk_atlas_view = chunk_atlas_texture.create_view(&wgpu::TextureViewDescriptor::default());

        let (tile_array_texture, tile_array_view) = Self::create_tile_array_texture(
            device,
            queue,
            tile_texture_size,
            tile_layers_rgba,
        );

        let tile_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("tile_sampler"),
            address_mode_u: wgpu::AddressMode::Repeat,
            address_mode_v: wgpu::AddressMode::Repeat,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Nearest,
            min_filter: wgpu::FilterMode::Nearest,
            mipmap_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });

        let uniforms = ChunkUniforms {
            view_proj: Mat4::IDENTITY.to_cols_array_2d(),
            texture_size: [tile_texture_size as f32, tile_texture_size as f32],
            chunk_size: chunk_size as f32,
            debug_terrain: 0,
        };
        let uniform_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("chunk_uniform_buffer"),
            contents: bytemuck::cast_slice(&[uniforms]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("chunk_bind_group_layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        multisampled: false,
                        view_dimension: wgpu::TextureViewDimension::D2,
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        multisampled: false,
                        view_dimension: wgpu::TextureViewDimension::D2Array,
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        let bind_group = Self::create_bind_group(
            device,
            &bind_group_layout,
            &uniform_buffer,
            &chunk_atlas_view,
            &tile_array_view,
            &tile_sampler,
        );

        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("chunk_pipeline_layout"),
            bind_group_layouts: &[&bind_group_layout],
            push_constant_ranges: &[],
        });

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("chunk_pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<ChunkInstance>() as wgpu::BufferAddress,
                    step_mode: wgpu::VertexStepMode::Instance,
                    attributes: &[
                        wgpu::VertexAttribute {
                            offset: 0,
                            shader_location: 0,
                            format: wgpu::VertexFormat::Float32x2,
                        },
                        wgpu::VertexAttribute {
                            offset: 8,
                            shader_location: 1,
                            format: wgpu::VertexFormat::Uint32x2,
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

        let instance_capacity = MAX_ATLAS_SLOTS as usize;
        let instance_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("chunk_instance_buffer"),
            size: (instance_capacity * std::mem::size_of::<ChunkInstance>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let free_slots = (0..MAX_ATLAS_SLOTS).rev().collect();

        Self {
            pipeline,
            uniform_buffer,
            instance_buffer,
            instance_capacity,
            chunk_atlas_texture,
            _chunk_atlas_view: chunk_atlas_view,
            _tile_array_texture: tile_array_texture,
            tile_array_view,
            tile_sampler,
            _bind_group_layout: bind_group_layout,
            bind_group,
            free_slots,
            chunk_size,
            tile_texture_size,
            debug_terrain: false,
        }
    }

    fn create_tile_array_texture(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        tile_texture_size: u32,
        tile_layers_rgba: &[Vec<u8>],
    ) -> (wgpu::Texture, wgpu::TextureView) {
        let layer_count = tile_layers_rgba.len().max(2) as u32;
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("tile_texture_array"),
            size: wgpu::Extent3d {
                width: tile_texture_size,
                height: tile_texture_size,
                depth_or_array_layers: layer_count,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });

        for (layer_idx, layer_bytes) in tile_layers_rgba.iter().enumerate() {
            queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d {
                        x: 0,
                        y: 0,
                        z: layer_idx as u32,
                    },
                    aspect: wgpu::TextureAspect::All,
                },
                layer_bytes,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(tile_texture_size * 4),
                    rows_per_image: Some(tile_texture_size),
                },
                wgpu::Extent3d {
                    width: tile_texture_size,
                    height: tile_texture_size,
                    depth_or_array_layers: 1,
                },
            );
        }

        let view = texture.create_view(&wgpu::TextureViewDescriptor {
            label: Some("tile_texture_array_view"),
            dimension: Some(wgpu::TextureViewDimension::D2Array),
            ..Default::default()
        });
        (texture, view)
    }

    fn create_bind_group(
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        uniform_buffer: &wgpu::Buffer,
        chunk_atlas_view: &wgpu::TextureView,
        tile_array_view: &wgpu::TextureView,
        tile_sampler: &wgpu::Sampler,
    ) -> wgpu::BindGroup {
        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("chunk_bind_group"),
            layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: uniform_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(chunk_atlas_view),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(tile_array_view),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::Sampler(tile_sampler),
                },
            ],
        })
    }

    pub fn tile_array_view(&self) -> &wgpu::TextureView {
        &self.tile_array_view
    }

    pub fn tile_sampler(&self) -> &wgpu::Sampler {
        &self.tile_sampler
    }

    /// Allocates a slot in the GPU chunk data atlas.
    pub fn allocate_slot(&mut self) -> Option<u32> {
        self.free_slots.pop()
    }

    /// Returns a chunk slot to the pool when a chunk is unloaded.
    pub fn free_slot(&mut self, slot: u32) {
        self.free_slots.push(slot);
    }

    pub fn slot_coords(slot: u32) -> [u32; 2] {
        [slot % ATLAS_SLOTS_PER_SIDE, slot / ATLAS_SLOTS_PER_SIDE]
    }

    /// Writes a chunk's `[tile_id, damage_stage]` data (`32 * 32 * 2 = 2048` bytes)
    /// into its assigned GPU atlas slot in-place without reallocating textures.
    pub fn write_chunk_data(&self, queue: &wgpu::Queue, slot: u32, terrain_data: &[u8]) {
        let [slot_x, slot_y] = Self::slot_coords(slot);
        let expected_len = (self.chunk_size * self.chunk_size * 2) as usize;
        if terrain_data.len() != expected_len {
            return;
        }

        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &self.chunk_atlas_texture,
                mip_level: 0,
                origin: wgpu::Origin3d {
                    x: slot_x * self.chunk_size,
                    y: slot_y * self.chunk_size,
                    z: 0,
                },
                aspect: wgpu::TextureAspect::All,
            },
            terrain_data,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(self.chunk_size * 2),
                rows_per_image: Some(self.chunk_size),
            },
            wgpu::Extent3d {
                width: self.chunk_size,
                height: self.chunk_size,
                depth_or_array_layers: 1,
            },
        );
    }

    pub fn render<'a>(
        &'a self,
        queue: &wgpu::Queue,
        render_pass: &mut wgpu::RenderPass<'a>,
        view_proj: Mat4,
        instances: &[ChunkInstance],
    ) {
        if instances.is_empty() {
            return;
        }

        let uniforms = ChunkUniforms {
            view_proj: view_proj.to_cols_array_2d(),
            texture_size: [self.tile_texture_size as f32, self.tile_texture_size as f32],
            chunk_size: self.chunk_size as f32,
            debug_terrain: u32::from(self.debug_terrain),
        };
        queue.write_buffer(&self.uniform_buffer, 0, bytemuck::cast_slice(&[uniforms]));

        let count = instances.len().min(self.instance_capacity);
        queue.write_buffer(
            &self.instance_buffer,
            0,
            bytemuck::cast_slice(&instances[..count]),
        );

        render_pass.set_pipeline(&self.pipeline);
        render_pass.set_bind_group(0, &self.bind_group, &[]);
        render_pass.set_vertex_buffer(0, self.instance_buffer.slice(..));
        render_pass.draw(0..6, 0..count as u32);
    }
}
