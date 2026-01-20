# Spec for Cell-Based Editing

## Goal

Implement a realistic "cell-based" terrain destruction system where terrain breaks in logical units (e.g., individual stones) rather than arbitrary geometric shapes. This enhances immersion by mimicking physical fracture patterns.

## 1. Data Generation (TerrainGenerator)

The underlying terrain data needs to store a `cell_id` for every pixel, distinguishing individual "stones" or clusters.

- **Noise Source**: Add a new `FastNoiseLite` instance to `TerrainGenerator`.
  - `noise_type`: `TYPE_CELLULAR` (Voronoi).
  - `cellular_return_type`: `CellValue` (returns a constant value for the entire cell).
  - `frequency`: Tuned to determine the average size of a stone.
- **Generation Logic**:
  - In `generate_chunk`, sample this cellular noise.
  - Map the result to a `0-255` integer (`cell_id`).
  - Store this `cell_id` in the `PackedByteArray` (Green channel, index `i*2 + 1`), just as `tile_id` is stored in the Red channel.
  - _Note_: 0-255 range is sufficient for local separation (Four Color Theorem principle). Occasional ID collisions between non-adjacent cells are acceptable.

## 2. Visual Representation (Shader)

The shader must stop relying on repeating textures and instead draw distinct stones based on the `cell_id`.

- **File**: `src/world/chunks/terrain.gdshader`
- **Logic**:
  - Read `cell_id` from `chunk_data_texture` (Green channel).
  - **Cell Differentiation**: Use `cell_id` as a random seed to vary the color/brightness of the stone slightly, giving a "cobblestone" look.
  - **Edge Detection**: Calculate the derivative of `cell_id` (using `fwidth(cell_id)` or `dFdx`/`dFdy`) or sample neighboring pixels. If the derivative is non-zero (meaning `cell_id` changed), render a dark "crack" or border color.
  - **Texture Mapping**: (Optional) Map the `cell_id` to a random offset in the stone texture to prevent the "tiling" artifact, so each stone looks like a different slice of the texture.

## 3. Editing Logic (ChunkManager)

The breaking tool must be context-aware.

- **Input**: Mouse click `world_position`.
- **Algorithm**:
  1.Get `tile_id` and `cell_id` at `world_position`. 2.**Case A: Cellular Material (e.g., Stone)** - Identify the target `cell_id`. - Perform a **Flood Fill** (BFS/DFS) starting from the click position. - **Condition**: Expand to neighbors if `neighbor.tile_id == target_tile_id` AND `neighbor.cell_id == target_cell_id`. - **Action**: Collect all matching positions. - **Apply**: Set all collected positions to `tile_id = 0` (Air).
  3 **Case B: Amorphous Material (e.g., Dirt, Grass)** - Define a brush radius (e.g., 5-10 pixels). - Calculate all pixels within that radius. - **Apply**: Set all pixels to `tile_id = 0` (Air).
- **Optimization**: Use `get_tile_at_world_pos` and `set_tiles_at_world_positions` to batch the updates. Limit flood fill recursion depth to prevent crashes (though stone size should naturally limit it).

## 4. Placing Logic (Future)

- For now, focus on breaking.
- Placing will eventually require picking a new `cell_id` that doesn't conflict with neighbors (scan neighbors, pick unused ID).

## Implementation Steps

1. **Update Generator**: Modify `src/world/generators/terrain_generator.gd` to populate `cell_id`.
2. **Update Shader**: Modify `src/world/chunks/terrain.gdshader` to visualize cells.
3. **Implement Edit Tool**: Create a new tool script or add logic to `ChunkManager` (or `CollisionDetector`/`GuiManager` interaction) to handle the flood-fill breaking.
