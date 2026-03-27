shader_type canvas_item;

uniform sampler2D chunk_data_texture : filter_nearest;
uniform sampler2DArray tile_textures : source_color, repeat_enable, filter_nearest;

uniform vec2 texture_size = vec2(32.0, 32.0);

// Debug visualization toggle (set from code)
uniform bool debug_terrain = false;

varying vec2 world_position; // Pixel world pos

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// Decode tile_id and damage_stage from R and G channels
	vec4 data = texture(chunk_data_texture, UV);
	float tile_id = data.r * 255.0;
	float damage_stage = data.g * 255.0;

	if (tile_id < 0.5) {
		// 0 is air — transparent
		discard;
	}

	// Sample the tile texture from the Texture2DArray at the tile_id layer
	vec2 tile_uv = world_position / texture_size;
	COLOR = texture(tile_textures, vec3(tile_uv, tile_id));

	// Uniform darkening per damage stage
	if (damage_stage > 1.5) {
		COLOR.rgb *= 0.65;
	} else if (damage_stage > 0.5) {
		COLOR.rgb *= 0.85;
	}

	// Debug visualization
	if (debug_terrain) {
		// Damage stage tint
		if (damage_stage > 1.5) {
			COLOR.rgb = mix(COLOR.rgb, vec3(1.0, 0.2, 0.1), 0.5);
		} else if (damage_stage > 0.5) {
			COLOR.rgb = mix(COLOR.rgb, vec3(1.0, 0.9, 0.1), 0.4);
		}

		// Hardness heatmap: pixel luminance → hardness proxy (inverted)
		// Dark pixels (mortar/gaps) = high hardness → red tint
		// Bright pixels (stone face) = low hardness → blue tint
		float lum = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
		COLOR.rgb = mix(
			vec3(1.0, 0.3, 0.2),  // Red = hard (low luminance / mortar)
			vec3(0.2, 0.4, 1.0),  // Blue = soft (high luminance / stone face)
			lum
		);
	}
}
