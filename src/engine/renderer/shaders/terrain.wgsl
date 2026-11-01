struct ChunkUniforms {
    view_proj: mat4x4<f32>,
    texture_size: vec2<f32>,
    chunk_size: f32,
    debug_terrain: u32,
    lighting_mode: u32,
    dyn_light_count: u32,
    padded_light_slot_size: f32,
    dyn_stamp_size: f32,
    light_atlas_inv_size: vec2<f32>,
    dyn_atlas_inv_size: vec2<f32>,
    dyn_lights: array<vec4<f32>, 8>,
};

@group(0) @binding(0)
var<uniform> uniforms: ChunkUniforms;

@group(0) @binding(1)
var chunk_atlas_tex: texture_2d<f32>;

@group(0) @binding(2)
var tile_textures: texture_2d_array<f32>;

@group(0) @binding(3)
var tile_sampler: sampler;

@group(0) @binding(4)
var chunk_light_atlas_tex: texture_2d<f32>;

@group(0) @binding(5)
var dyn_light_atlas_tex: texture_2d<f32>;

@group(0) @binding(6)
var light_sampler: sampler;

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

// 2x2 Bayer ordered dither in [-0.375, +0.375] for Pixel-Art lighting mode
fn bayer2x2(p: vec2<i32>) -> f32 {
    let x = p.x & 1;
    let y = p.y & 1;
    let idx = x + (y << 1);
    var m = 0.0;
    if (idx == 0) {
        m = 0.0;
    } else if (idx == 1) {
        m = 2.0;
    } else if (idx == 2) {
        m = 3.0;
    } else {
        m = 1.0;
    }
    return (m / 4.0) - 0.375;
}

fn sample_combined_light(
    uv: vec2<f32>,
    world_pos: vec2<f32>,
    local_tile: vec2<i32>,
    atlas_slot: vec2<u32>,
) -> vec4<f32> {
    let padded_slot_i = i32(uniforms.padded_light_slot_size);
    let light_slot_origin_i = vec2<i32>(atlas_slot) * padded_slot_i;

    var static_light: vec4<f32>;
    if (uniforms.lighting_mode == 2u) {
        // Blocky (Per-Tile): integer texel load from the 34x34 padded slot (+1, +1 offset)
        static_light = textureLoad(
            chunk_light_atlas_tex,
            light_slot_origin_i + local_tile + vec2<i32>(1, 1),
            0
        );
    } else if (uniforms.lighting_mode == 1u) {
        // Pixel-Art: sample at the exact tile center so all pixels within a 1x1 voxel tile align cleanly
        let snapped_local = vec2<f32>(local_tile) + vec2<f32>(0.5, 0.5);
        let light_px = vec2<f32>(light_slot_origin_i) + snapped_local + vec2<f32>(1.0, 1.0);
        let light_uv = light_px * uniforms.light_atlas_inv_size;
        static_light = textureSampleLevel(chunk_light_atlas_tex, light_sampler, light_uv, 0.0);
    } else {
        // Smooth (Gradient): continuous bilinear interpolation across tile centers & chunk borders
        let light_px = vec2<f32>(light_slot_origin_i) + uv * uniforms.chunk_size + vec2<f32>(1.0, 1.0);
        let light_uv = light_px * uniforms.light_atlas_inv_size;
        static_light = textureSampleLevel(chunk_light_atlas_tex, light_sampler, light_uv, 0.0);
    }

    let sample_world = select(
        world_pos,
        floor(world_pos) + vec2<f32>(0.5, 0.5),
        uniforms.lighting_mode == 1u
    );

    var dyn_rgb = vec3<f32>(0.0);
    let stamp_size = uniforms.dyn_stamp_size;
    let stamp_max_i = i32(stamp_size) - 1;

    for (var i: u32 = 0u; i < uniforms.dyn_light_count; i = i + 1u) {
        let dl = uniforms.dyn_lights[i];
        let rel = sample_world - dl.xy;
        if (rel.x >= 1.0 && rel.x <= stamp_size - 1.0 && rel.y >= 1.0 && rel.y <= stamp_size - 1.0) {
            var sample_rgb: vec3<f32>;
            if (uniforms.lighting_mode == 2u) {
                let rel_tile = clamp(vec2<i32>(floor(rel)), vec2<i32>(0, 0), vec2<i32>(stamp_max_i, stamp_max_i));
                sample_rgb = textureLoad(dyn_light_atlas_tex, vec2<i32>(dl.zw) + rel_tile, 0).rgb;
            } else {
                let dyn_uv = (dl.zw + rel) * uniforms.dyn_atlas_inv_size;
                sample_rgb = textureSampleLevel(dyn_light_atlas_tex, light_sampler, dyn_uv, 0.0).rgb;
            }
            dyn_rgb = max(dyn_rgb, sample_rgb);
        }
    }

    var point_rgb = max(static_light.rgb, dyn_rgb);
    var sky = static_light.a;

    if (uniforms.lighting_mode == 1u) {
        // Retro Pixel-Art mode: ordered 2x2 Bayer dither + quantized light bands
        let world_tile_i = vec2<i32>(floor(world_pos));
        let dither = bayer2x2(world_tile_i);
        let bands = 10.0;
        point_rgb = clamp(floor(point_rgb * bands + 0.5 + dither) / bands, vec3<f32>(0.0), vec3<f32>(1.0));
        sky = clamp(floor(sky * bands + 0.5 + dither) / bands, 0.0, 1.0);
    } else if (uniforms.lighting_mode == 2u) {
        // Blocky mode: crisp quantized bands per tile without dithering
        let bands = 8.0;
        point_rgb = clamp(floor(point_rgb * bands + 0.5) / bands, vec3<f32>(0.0), vec3<f32>(1.0));
        sky = clamp(floor(sky * bands + 0.5) / bands, 0.0, 1.0);
    }

    return vec4<f32>(point_rgb, sky);
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

    let lighting_active = (uniforms.lighting_mode != 3u) && (uniforms.debug_terrain == 0u);
    var combined_light = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    if (lighting_active) {
        combined_light = sample_combined_light(in.uv, in.world_pos, local_tile, in.atlas_slot);
    }

    if (tile_id < 0.5) {
        if (!lighting_active) {
            discard;
        }
        let point_rgb = combined_light.rgb;
        let sky = combined_light.a;
        let point_max = max(point_rgb.r, max(point_rgb.g, point_rgb.b));
        if (sky >= 0.99 && point_max < 0.01) {
            discard;
        }
        // Atmospheric underground cave backdrop + soft volumetric glow from local lights
        let sky_bg = vec3<f32>(0.3, 0.3, 0.3);
        let cave_bg = vec3<f32>(0.028, 0.032, 0.046);
        let air_rgb = mix(cave_bg, sky_bg, sky) + point_rgb * 0.22 * (1.0 - sky * 0.65);
        return vec4<f32>(air_rgb, 1.0);
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
        return vec4<f32>(rgb, color.a);
    }

    if (lighting_active) {
        let point_rgb = combined_light.rgb;
        let sky = combined_light.a;
        let sun_rgb = vec3<f32>(1.0, 0.98, 0.94) * sky;
        let ambient = vec3<f32>(0.032, 0.036, 0.052);
        let light_rgb = clamp(
            max(sun_rgb, point_rgb) + min(sun_rgb, point_rgb) * 0.35 + ambient * (1.0 - sky),
            vec3<f32>(0.0),
            vec3<f32>(1.30)
        );
        color = vec4<f32>(color.rgb * light_rgb, color.a);
    }

    return color;
}
