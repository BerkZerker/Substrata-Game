shader_type canvas_item;

uniform sampler2D chunk_data_texture : filter_nearest;
uniform sampler2D dirt_texture : source_color, repeat_enable, filter_nearest;
uniform sampler2D grass_texture : source_color, repeat_enable, filter_nearest;
uniform sampler2D stone_texture : source_color, repeat_enable, filter_nearest;

uniform vec2 texture_size = vec2(32.0, 32.0);

// Stone cell visualization colors
uniform vec3 stone_base_color = vec3(0.6, 0.6, 0.6);  // Light gray base
uniform vec3 stone_crack_color = vec3(0.2, 0.2, 0.2); // Dark gray cracks
uniform float stone_color_variation = 0.15;           // How much cells vary in brightness
uniform float crack_threshold = 0.01;                 // Edge detection sensitivity

varying vec2 world_position; // Pixel world pos

// Simple hash function for per-cell color variation
float hash(float n) {
	return fract(sin(n) * 43758.5453123);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// Get tile id and cell id from the encoded data
	vec2 chunk_data = texture(chunk_data_texture, UV).rg;
	float tile_id = chunk_data.r * 255.0;
	float cell_id = chunk_data.g * 255.0;
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
		// 3 is stone - use cell-based rendering
		
		// Edge detection: check if cell_id changes across this pixel
		float cell_dx = dFdx(cell_id);
		float cell_dy = dFdy(cell_id);
		float edge = abs(cell_dx) + abs(cell_dy);
		
		if (edge > crack_threshold) {
			// This pixel is on a cell boundary - render crack
			COLOR = vec4(stone_crack_color, 1.0);
		} else {
			// Interior of cell - use cell_id for color variation
			float variation = hash(cell_id) * stone_color_variation;
			vec3 cell_color = stone_base_color + vec3(variation - stone_color_variation * 0.5);
			COLOR = vec4(cell_color, 1.0);
		}
	} else {
		// fallback if unidentified
		COLOR = vec4(1.0, 0.0, 1.0, 0.0); // Bright magenta
	}
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
