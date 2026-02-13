# TODO

## Completed

- ~~Check over and clean up the chunk editing code~~ — Fixed lag spikes by switching to in-place `ImageTexture.update()` instead of allocating a new GPU texture per edit. Editing is batched by chunk.

- ~~Figure out a solution to the reference problem~~ — Implemented `GameServices` autoload as a service locator. `GameInstance._ready()` registers the ChunkManager, and any system accesses it via `GameServices.chunk_manager` without manual wiring.

- ~~Clean up the debug overlay code~~ — Fixed broken property references (was accessing ChunkLoader internals through ChunkManager). Added `get_debug_info()` API to ChunkManager/ChunkLoader. Wired up `ChunkDebugOverlay` in the game scene with F1-F6 keybindings. Starts with all overlays off.

- ~~Check over all recent AI-generated code and refactor~~ — Cleaned up terrain generator (clear variable names, removed dead code), brush preview (removed verbose comments), player (extracted movement logic). Reduced net line count by ~100.

- ~~Build a movement controller~~ — Extracted movement physics into `MovementController` (`src/physics/movement_controller.gd`). Handles gravity, acceleration, friction, coyote jump, step-up, and swept AABB collision. Player is now a thin input wrapper that delegates to it. Reusable for any entity.

- ~~Implement WorkerThreadPool for chunk generation~~ — Replaced single Thread+Semaphore with WorkerThreadPool (up to 8 concurrent tasks). Tasks collect work under mutex and submit outside the lock. Backpressure and clean shutdown preserved. Debug overlay shows active task count.

- ~~Improve terrain generation~~ — Replaced flat simplex noise thresholds with layered system: 1D heightmap for surface contour (hills), 2D cave noise for underground cavities, 2D surface noise for layer boundary variation. Terrain now has grass/dirt/stone layers, caves, and natural overhangs. Configurable via DEFAULT_CONFIG dictionary.

- ~~Component cleanup~~ — Removed unused CoyoteTimer node from player.tscn. Extracted movement init into `_try_init_movement()` in player.gd.

- ~~Futureproof the codebase~~ — Added `##` docstrings to 7 key files (class headers + public methods). Extended TileIndex with TILES lookup table, `is_solid()`, and `get_tile_name()`. Removed dead commented-out light() function from terrain shader. Made TerrainGenerator configurable via optional config dictionary.

## Human TODO

- Update `README.md` with screenshots once terrain generation is more visually interesting.
