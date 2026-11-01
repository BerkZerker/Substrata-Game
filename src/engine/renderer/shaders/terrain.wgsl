struct ChunkUniforms {
    view_proj: mat4x4<f32>,
    texture_size: vec2<f32>,
    chunk_size: f32,
    debug_terrain: u32,
};

@group(0) @binding(0)
var<uniform> uniforms: ChunkUniforms;

@group(0) @binding(1)
var chunk_atlas_tex: texture_2d<f32>;

@group(0) @binding(2)
var tile_textures: texture_2d_array<f32>;

@group(0) @binding(3)
var tile_sampler: sampler;

struct InstanceInput {
    @location(0) chunk_world_pos: vec2<f32>,
    @location(1) atlas_slot: vec2<u32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) world_pos: vec2<f32>,
    @location(2) @interpolate(flat) atlas_slot: vec2<u32>,
};

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    instance: InstanceInput,
) -> VertexOutput {
    // Two triangles forming a [0..1, 0..1] unit quad
    var quad_uvs = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 0.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 1.0),
    );

    let uv = quad_uvs[vertex_index];
    let world_pos = instance.chunk_world_pos + uv * uniforms.chunk_size;

    var out: VertexOutput;
    out.clip_position = uniforms.view_proj * vec4<f32>(world_pos, 0.0, 1.0);
    out.uv = uv;
    out.world_pos = world_pos;
    out.atlas_slot = instance.atlas_slot;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let chunk_size_i = i32(uniforms.chunk_size);
    let local_tile = clamp(
        vec2<i32>(floor(in.uv * uniforms.chunk_size)),
        vec2<i32>(0, 0),
        vec2<i32>(chunk_size_i - 1, chunk_size_i - 1)
    );
    let atlas_origin = vec2<i32>(in.atlas_slot) * chunk_size_i;
    let data = textureLoad(chunk_atlas_tex, atlas_origin + local_tile, 0);

    let tile_id = round(data.r * 255.0);
    let damage_stage = round(data.g * 255.0);

    if (tile_id < 0.5) {
        discard;
    }

    let tile_uv = in.world_pos / uniforms.texture_size;
    var color = textureSampleLevel(tile_textures, tile_sampler, tile_uv, i32(tile_id), 0.0);

    // Uniform darkening per damage stage (matches terrain.gdshader)
    if (damage_stage > 1.5) {
        color = vec4<f32>(color.rgb * 0.65, color.a);
    } else if (damage_stage > 0.5) {
        color = vec4<f32>(color.rgb * 0.85, color.a);
    }

    // Debug visualization (T key toggle)
    if (uniforms.debug_terrain != 0u) {
        var rgb = color.rgb;
        if (damage_stage > 1.5) {
            rgb = mix(rgb, vec3<f32>(1.0, 0.2, 0.1), 0.5);
        } else if (damage_stage > 0.5) {
            rgb = mix(rgb, vec3<f32>(1.0, 0.9, 0.1), 0.4);
        }

        // Hardness heatmap: pixel luminance -> hardness proxy (inverted)
        // Dark pixels (mortar/gaps) = high hardness -> red tint
        // Bright pixels (stone face) = low hardness -> blue tint
        let lum = dot(rgb, vec3<f32>(0.299, 0.587, 0.114));
        rgb = mix(
            vec3<f32>(1.0, 0.3, 0.2),
            vec3<f32>(0.2, 0.4, 1.0),
            lum
        );
        color = vec4<f32>(rgb, color.a);
    }

    return color;
}
