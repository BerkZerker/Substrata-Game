shader_type canvas_item;

uniform sampler2D chunk_data_texture : filter_nearest;
uniform sampler2D chunk_light_texture : filter_nearest;
uniform sampler2DArray tile_textures : source_color, repeat_enable, filter_nearest;

uniform vec2 texture_size = vec2(32.0, 32.0);
uniform float ambient_light = 0.05;

// Dynamic point lights
uniform int num_dynamic_lights = 0;
uniform vec2 dynamic_light_positions[16];
uniform float dynamic_light_radii[16];
uniform vec4 dynamic_light_colors[16];

varying vec2 world_position; // Pixel world pos

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 data = texture(chunk_data_texture, UV);
	// Decode tile_id from R channel (encoded by chunk_loader.gd)
	float tile_id = data.r * 255.0;

	if (tile_id < 0.5) {
		// 0 is air — transparent
		discard;
	}

	// Sample light from separate texture: RGB = block light color, A = sky intensity
	vec4 light_data = texture(chunk_light_texture, UV);
	vec3 block_rgb = light_data.rgb;
	float sky_light = light_data.a;

	// Accumulate dynamic lights as vec3
	vec3 dynamic_rgb = vec3(0.0);
	for (int i = 0; i < num_dynamic_lights; i++) {
		float dist = distance(world_position, dynamic_light_positions[i]);
		if (dist < dynamic_light_radii[i]) {
			float falloff = 1.0 - (dist / dynamic_light_radii[i]);
			falloff = falloff * falloff; // Quadratic falloff
			float intensity = falloff * dynamic_light_colors[i].a;
			dynamic_rgb += dynamic_light_colors[i].rgb * intensity;
		}
	}

	// Combine: sky (modulated by ambient), block light, and dynamic lights
	vec3 total_light = clamp(max(vec3(sky_light * ambient_light), block_rgb) + dynamic_rgb, 0.0, 1.0);

	// Sample the tile texture from the Texture2DArray at the tile_id layer
	vec2 tile_uv = world_position / texture_size;
	vec4 tile_color = texture(tile_textures, vec3(tile_uv, tile_id));
	COLOR = vec4(tile_color.rgb * total_light, tile_color.a);
}
