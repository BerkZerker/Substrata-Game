shader_type canvas_item;

uniform sampler2D chunk_data_texture : filter_nearest;
uniform sampler2DArray tile_textures : source_color, repeat_enable, filter_nearest;

uniform vec2 texture_size = vec2(32.0, 32.0);
uniform float ambient_light : hint_range(0.0, 1.0) = 0.08;

// Animated tile IDs (must match TileIndex constants)
const float WATER_ID = 12.0;
const float LAVA_ID = 13.0;

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
	// Apply UV animation for water and lava tiles
	vec2 tile_uv = world_position / texture_size;

	if (abs(tile_id - WATER_ID) < 0.5) {
		// Water: gentle wave distortion
		float wave1 = sin(world_position.x * 1.5 + TIME * 1.2) * 0.02;
		float wave2 = sin(world_position.y * 2.0 + TIME * 0.8) * 0.015;
		tile_uv.x += wave1 + sin(TIME * 0.5 + world_position.y * 0.8) * 0.01;
		tile_uv.y += wave2 + cos(TIME * 0.7 + world_position.x * 1.2) * 0.01;
	} else if (abs(tile_id - LAVA_ID) < 0.5) {
		// Lava: slow roiling distortion with stronger effect
		float roil1 = sin(world_position.x * 0.8 + TIME * 0.5) * 0.035;
		float roil2 = cos(world_position.y * 0.6 + TIME * 0.4) * 0.03;
		tile_uv.x += roil1 + sin(TIME * 0.3 + world_position.y * 0.5) * 0.02;
		tile_uv.y += roil2 + cos(TIME * 0.25 + world_position.x * 0.7) * 0.02;
	}

	vec4 tile_color = texture(tile_textures, vec3(tile_uv, tile_id));

	// Animated color modulation for water and lava
	if (abs(tile_id - WATER_ID) < 0.5) {
		// Water: subtle brightness shimmer
		float shimmer = sin(world_position.x * 3.0 + world_position.y * 2.0 + TIME * 2.0) * 0.08 + 1.0;
		tile_color.rgb *= shimmer;
	} else if (abs(tile_id - LAVA_ID) < 0.5) {
		// Lava: pulsing glow between orange and bright yellow
		float pulse = sin(TIME * 1.5 + world_position.x * 0.4 + world_position.y * 0.3) * 0.5 + 0.5;
		tile_color.rgb = mix(tile_color.rgb, tile_color.rgb * vec3(1.3, 1.1, 0.7), pulse * 0.3);
	}

	// Apply lighting: use max of tile light, dynamic light, and ambient
	float brightness = max(light_level, max(dynamic_light, ambient_light));

	// Blend dynamic light color when dynamic light is the dominant source
	vec3 light_tint = vec3(1.0);
	if (dynamic_light > light_level && dynamic_light > ambient_light && dynamic_light > 0.0) {
		light_tint = mix(vec3(1.0), dynamic_color, 0.3);
	}

	COLOR = tile_color * vec4(light_tint * brightness, 1.0);
}
