shader_type canvas_item;

uniform sampler2D chunk_data_texture : filter_nearest;
uniform sampler2DArray tile_textures : source_color, repeat_enable, filter_nearest;

uniform vec2 texture_size = vec2(32.0, 32.0);
uniform float ambient_light : hint_range(0.0, 1.0) = 0.08;

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

	// Sample the tile texture from the Texture2DArray at the tile_id layer
	vec2 tile_uv = world_position / texture_size;
	vec4 tile_color = texture(tile_textures, vec3(tile_uv, tile_id));

	// Apply lighting: use max of tile light and ambient
	float brightness = max(light_level, ambient_light);
	COLOR = tile_color * vec4(brightness, brightness, brightness, 1.0);
}
