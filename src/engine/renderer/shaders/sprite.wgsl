struct SpriteUniforms {
    view_proj: mat4x4<f32>,
};

@group(0) @binding(0)
var<uniform> uniforms: SpriteUniforms;

@group(0) @binding(1)
var sprite_tex: texture_2d<f32>;

@group(0) @binding(2)
var sprite_sampler: sampler;

struct SpriteInstance {
    @location(0) center_pos: vec2<f32>,
    @location(1) size: vec2<f32>,
    @location(2) tint: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) tint: vec4<f32>,
};

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    instance: SpriteInstance,
) -> VertexOutput {
    var quad_uvs = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 0.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 1.0),
    );

    let uv = quad_uvs[vertex_index];
    let local_offset = (uv - vec2<f32>(0.5, 0.5)) * instance.size;
    let world_pos = instance.center_pos + local_offset;

    var out: VertexOutput;
    out.clip_position = uniforms.view_proj * vec4<f32>(world_pos, 0.0, 1.0);
    out.uv = uv;
    out.tint = instance.tint;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let tex_color = textureSample(sprite_tex, sprite_sampler, in.uv);
    let color = tex_color * in.tint;
    if (color.a < 0.01) {
        discard;
    }
    return color;
}
