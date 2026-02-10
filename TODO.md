# TODO

## Completed

- ~~Check over and clean up the chunk editing code~~ — Fixed lag spikes by switching to in-place `ImageTexture.update()` instead of allocating a new GPU texture per edit. Editing is batched by chunk.

- ~~Figure out a solution to the reference problem~~ — Implemented `GameServices` autoload as a service locator. `GameInstance._ready()` registers the ChunkManager, and any system accesses it via `GameServices.chunk_manager` without manual wiring.

- ~~Clean up the debug overlay code~~ — Fixed broken property references (was accessing ChunkLoader internals through ChunkManager). Added `get_debug_info()` API to ChunkManager/ChunkLoader. Wired up `ChunkDebugOverlay` in the game scene with F1-F6 keybindings. Starts with all overlays off.

- ~~Check over all recent AI-generated code and refactor~~ — Cleaned up terrain generator (clear variable names, removed dead code), brush preview (removed verbose comments), player (extracted movement logic). Reduced net line count by ~100.

- ~~Build a movement controller~~ — Extracted movement physics into `MovementController` (`src/physics/movement_controller.gd`). Handles gravity, acceleration, friction, coyote jump, step-up, and swept AABB collision. Player is now a thin input wrapper that delegates to it. Reusable for any entity.

## Remaining

- Implement the `WorkerThreadPool` for chunk generation, editing, loading and saving. Currently uses a single `Thread` with Mutex/Semaphore. The debug overlay is now wired up to validate the migration. Chunk pooling is already in place (512 pool in ChunkManager).

- Consider moving to a component-based system where applicable — entities, terrain generation, items. The `MovementController` extraction is a first step in this direction.

- Improve terrain generation beyond simple simplex noise thresholds — density-based generation, caves, overhangs, biomes, cell IDs for visual variation.

- Update `README.md` with screenshots once terrain generation is more visually interesting.

- Futureproof the codebase: keep it extendable, readable, maintainable, efficient, and well documented.
