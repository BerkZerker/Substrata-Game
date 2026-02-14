shader_type canvas_item;

uniform sampler2D chunk_data_texture : filter_nearest;
uniform sampler2D dirt_texture : source_color, repeat_enable, filter_nearest;
uniform sampler2D grass_texture : source_color, repeat_enable, filter_nearest;
uniform sampler2D stone_texture : source_color, repeat_enable, filter_nearest;

uniform vec2 texture_size = vec2(32.0, 32.0);

varying vec2 world_position; // Pixel world pos

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// Decode tile_id from R channel (encoded by chunk_loader.gd)
	float tile_id = texture(chunk_data_texture, UV).r * 255.0;
	vec2 tile_uv = world_position / texture_size;

	if (tile_id < 0.5) {
		// 0 is air
		discard;
	} else if (abs(tile_id - 1.0) < 0.5) {
		// 1 is dirt
		COLOR = texture(dirt_texture, tile_uv);
	} else if (abs(tile_id - 2.0) < 0.5) {
		// 2 is grass
		COLOR = texture(grass_texture, tile_uv);
	} else if (abs(tile_id - 3.0) < 0.5) {
		// 3 is stone
		COLOR = texture(stone_texture, tile_uv);
	} else {
		// fallback if unidentified
		COLOR = vec4(1.0, 0.0, 1.0, 1.0); // Bright magenta
	}
}
