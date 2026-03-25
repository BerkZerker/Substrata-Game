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

	// Apply damage darkening (damaged tiles get progressively darker/cracked look)
	if (damage_stage > 0.5) {
		float damage_factor = damage_stage / 3.0; // Normalize (max ~3 stages)
		COLOR.rgb = mix(COLOR.rgb, COLOR.rgb * 0.4, clamp(damage_factor, 0.0, 0.8));

		// Add crack pattern overlay for damaged tiles
		vec2 crack_uv = fract(tile_uv * 4.0);
		float crack = abs(crack_uv.x - 0.5) + abs(crack_uv.y - 0.5);
		float crack_intensity = step(0.45, crack) * damage_factor * 0.5;
		COLOR.rgb = mix(COLOR.rgb, vec3(0.1, 0.05, 0.0), crack_intensity);
	}

	// Debug visualization: overlay hardness as color tint
	if (debug_terrain) {
		// Encode hardness info via tile_id ranges for debug coloring
		// Green = low hardness (easy), Yellow = medium, Red = high hardness
		// This is a rough visualization since we can't pass hardness per-tile to the shader
		// Instead, use damage_stage to show damage state clearly
		if (damage_stage > 1.5) {
			// Heavily damaged — red tint
			COLOR.rgb = mix(COLOR.rgb, vec3(1.0, 0.2, 0.1), 0.5);
		} else if (damage_stage > 0.5) {
			// Lightly damaged — yellow tint
			COLOR.rgb = mix(COLOR.rgb, vec3(1.0, 0.9, 0.1), 0.4);
		}
	}
}
