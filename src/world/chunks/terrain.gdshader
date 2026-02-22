shader_type canvas_item;

uniform sampler2D chunk_data_texture : filter_nearest;
uniform sampler2DArray tile_textures : source_color, repeat_enable, filter_nearest;

uniform vec2 texture_size = vec2(32.0, 32.0);
uniform float ambient_light : hint_range(0.0, 1.0) = 0.08;

global uniform int dynamic_light_count;
global uniform sampler2D dynamic_light_data;

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

	// Read light level from B channel
	float light_level = data.b;

	// Compute dynamic light contribution
	float dynamic_light = 0.0;
	vec3 dynamic_color = vec3(0.0);

	// Quantize fragment position to tile center for pixel-art look
	vec2 tile_pos = floor(world_position) + 0.5;

	int tex_width = textureSize(dynamic_light_data, 0).x;

	for (int i = 0; i < dynamic_light_count; i++) {
		// Read light data from 1D data texture
		// Pixel 0: (x, y, radius, intensity)
		float u0 = (float(i * 2) + 0.5) / float(tex_width);
		vec4 light_pos_data = texture(dynamic_light_data, vec2(u0, 0.5));
		vec2 light_pos = light_pos_data.rg;
		float radius = light_pos_data.b;
		float intensity = light_pos_data.a;

		// Pixel 1: (r, g, b, _)
		float u1 = (float(i * 2 + 1) + 0.5) / float(tex_width);
		vec4 light_color_data = texture(dynamic_light_data, vec2(u1, 0.5));

		// Quantized distance (tile-level granularity)
		float dist = distance(tile_pos, light_pos);
		float falloff = max(0.0, 1.0 - dist / radius);
		// Step falloff to discrete levels for pixel-art feel
		falloff = floor(falloff * radius) / radius;
		float contribution = falloff * intensity;

		if (contribution > dynamic_light) {
			dynamic_light = contribution;
			dynamic_color = light_color_data.rgb;
		}
	}

	// Sample the tile texture from the Texture2DArray at the tile_id layer
	vec2 tile_uv = world_position / texture_size;
	vec4 tile_color = texture(tile_textures, vec3(tile_uv, tile_id));

	// Apply lighting: use max of tile light, dynamic light, and ambient
	float brightness = max(light_level, max(dynamic_light, ambient_light));

	// Blend dynamic light color when dynamic light is the dominant source
	vec3 light_tint = vec3(1.0);
	if (dynamic_light > light_level && dynamic_light > ambient_light && dynamic_light > 0.0) {
		light_tint = mix(vec3(1.0), dynamic_color, 0.3);
	}

	COLOR = tile_color * vec4(light_tint * brightness, 1.0);
}
