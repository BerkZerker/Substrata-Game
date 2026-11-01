struct UiUniforms {
    screen_size: vec2<f32>,
    _pad: vec2<f32>,
};

@group(0) @binding(0)
var<uniform> uniforms: UiUniforms;

@group(0) @binding(1)
var font_tex: texture_2d<f32>;

@group(0) @binding(2)
var tile_textures: texture_2d_array<f32>;

@group(0) @binding(3)
var ui_sampler: sampler;

struct UiInstance {
    @location(0) rect_pos: vec2<f32>,
    @location(1) rect_size: vec2<f32>,
    @location(2) uv_min: vec2<f32>,
    @location(3) uv_max: vec2<f32>,
    @location(4) color: vec4<f32>,
    @location(5) border_color: vec4<f32>,
    // params: (corner_radius_or_layer, border_width, mode_f32, 0.0)
    // mode 0 = SDF rounded rect, mode 1 = tile array texture icon, mode 2 = font glyph
    @location(6) params: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) local_uv: vec2<f32>,
    @location(1) tex_uv: vec2<f32>,
    @location(2) rect_size: vec2<f32>,
    @location(3) color: vec4<f32>,
    @location(4) border_color: vec4<f32>,
    @location(5) params: vec4<f32>,
};

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    inst: UiInstance,
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
    let screen_pos = inst.rect_pos + uv * inst.rect_size;
    let ndc = vec2<f32>(
        (screen_pos.x / uniforms.screen_size.x) * 2.0 - 1.0,
        1.0 - (screen_pos.y / uniforms.screen_size.y) * 2.0,
    );

    var out: VertexOutput;
    out.clip_position = vec4<f32>(ndc, 0.0, 1.0);
    out.local_uv = uv;
    out.tex_uv = mix(inst.uv_min, inst.uv_max, uv);
    out.rect_size = inst.rect_size;
    out.color = inst.color;
    out.border_color = inst.border_color;
    out.params = inst.params;
    return out;
}

fn sd_rounded_box(p: vec2<f32>, b: vec2<f32>, r: f32) -> f32 {
    let q = abs(p) - b + vec2<f32>(r, r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2<f32>(0.0, 0.0))) - r;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let mode = i32(round(in.params.z));

    if (mode == 0) {
        // SDF Rounded Rectangle with optional border
        let half_size = in.rect_size * 0.5;
        let p = (in.local_uv - vec2<f32>(0.5, 0.5)) * in.rect_size;
        let radius = min(in.params.x, min(half_size.x, half_size.y));
        let border_w = in.params.y;
        let dist = sd_rounded_box(p, half_size, radius);

        let outer_alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
        if (outer_alpha <= 0.001) {
            discard;
        }

        if (border_w > 0.0) {
            let inner_t = 1.0 - smoothstep(-border_w - 0.5, -border_w + 0.5, dist);
            let final_col = mix(in.border_color, in.color, inner_t);
            return vec4<f32>(final_col.rgb, final_col.a * outer_alpha);
        } else {
            return vec4<f32>(in.color.rgb, in.color.a * outer_alpha);
        }
    } else if (mode == 1) {
        // Tile texture array icon
        let layer = i32(round(in.params.x));
        let tex_col = textureSampleLevel(tile_textures, ui_sampler, in.tex_uv, layer, 0.0);
        return tex_col * in.color;
    } else {
        // Bitmap font glyph
        let coverage = textureSampleLevel(font_tex, ui_sampler, in.tex_uv, 0.0).r;
        if (coverage < 0.5) {
            discard;
        }
        return in.color;
    }
}
