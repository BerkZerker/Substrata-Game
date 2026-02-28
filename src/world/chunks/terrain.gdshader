shader_type canvas_item;

uniform sampler2D chunk_data_texture : filter_nearest;
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

	// Dual-channel baked lighting: A = sky light, B = block (emissive) light
	float sky_light = data.a;
	float block_light = data.b;

	// Compute dynamic light contribution
	float dynamic_contrib = 0.0;
	vec3 dynamic_color_sum = vec3(0.0);
	for (int i = 0; i < num_dynamic_lights; i++) {
		float dist = distance(world_position, dynamic_light_positions[i]);
		if (dist < dynamic_light_radii[i]) {
			float falloff = 1.0 - (dist / dynamic_light_radii[i]);
			falloff = falloff * falloff; // Quadratic falloff
			float contrib = falloff * dynamic_light_colors[i].a; // alpha = intensity
			dynamic_contrib += contrib;
			dynamic_color_sum += dynamic_light_colors[i].rgb * contrib;
		}
	}

	// Sky light modulated by time-of-day ambient, block light is constant
	float total_light = clamp(max(sky_light * ambient_light, block_light) + dynamic_contrib, 0.0, 1.0);
	vec3 light_tint = vec3(1.0);
	if (dynamic_contrib > 0.001) {
		light_tint = mix(vec3(1.0), dynamic_color_sum / dynamic_contrib, clamp(dynamic_contrib, 0.0, 1.0));
	}

	// Sample the tile texture from the Texture2DArray at the tile_id layer
	vec2 tile_uv = world_position / texture_size;
	vec4 tile_color = texture(tile_textures, vec3(tile_uv, tile_id));
	COLOR = vec4(tile_color.rgb * total_light * light_tint, tile_color.a);
}
