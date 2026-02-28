# Substrata Code Quality & Performance Review

Line-by-line review of every `.gd` file. Issues rated by severity with confidence levels. Generated February 2026.

---

## Table of Contents

1. [Critical Issues](#critical-issues)
2. [High Severity Issues](#high-severity-issues)
3. [Medium Severity Issues](#medium-severity-issues)
4. [Low Severity Issues](#low-severity-issues)
5. [Performance Analysis](#performance-analysis)
6. [Test Coverage Assessment](#test-coverage-assessment)
7. [Summary Table](#summary-table)

---

## Critical Issues

### CRIT-1: ~~`stop()` Busy-Polls the Main Thread~~ [RESOLVED]

**File:** `src/world/chunks/chunk_loader.gd`
**Category:** Bug / Performance | **Confidence:** 95%

**Resolution:** `stop()` now has a 2-second timeout. If active tasks don't finish in time, it logs a warning via `push_warning()` and breaks out of the loop. `_chunks_in_progress.clear()` is now called after the wait loop completes (or times out), under a separate mutex lock.

---

### CRIT-2: ~~Missing Path Separator in `_delete_directory_contents`~~ [RESOLVED]

**File:** `src/world/persistence/world_save_manager.gd`
**Category:** Bug / Safety | **Confidence:** 95%

**Resolution:** Now uses `dir_path.path_join(entry)` for safe path construction.

---

## High Severity Issues

### HIGH-1: ~~`world_ready` Signal Can Fire Prematurely~~ [RESOLVED]

**File:** `src/world/chunks/chunk_manager.gd`
**Category:** Bug | **Confidence:** 85%

**Resolution:** ChunkManager now calculates `_initial_expected_count` (total chunks in generation radius) on the first call to `_queue_chunks_for_generation()`, and only emits `world_ready` once `_chunks.size() >= _initial_expected_count`.

---

### HIGH-2: Player Extends CharacterBody2D Without Using It

**File:** `src/entities/player.gd:1`
**Category:** Quality / Architecture | **Confidence:** 85%

`Player extends CharacterBody2D` but never calls `move_and_slide()`, never uses the built-in `velocity`, and never uses any CharacterBody2D features. All physics is handled by `MovementController` + `CollisionDetector`. This wastes CPU (Godot processes the physics body every frame), shadows the velocity concept, and misleads users about the physics system.

**Fix:** Change to `extends Node2D` or `extends BaseEntity`.

---

### HIGH-3: ~~Camera Smoothing Formula Disables Smooth Follow~~ [RESOLVED]

**File:** `src/camera/camera_controller.gd`
**Category:** Bug | **Confidence:** 90%

**Resolution:** Formula corrected to `1.0 - exp(-smoothing * delta)` — the `* 60.0` multiplier was removed.

---

### HIGH-4: ~~Terrain Editing Pre-Pass Is O(N) Per Tile~~ [RESOLVED]

**File:** `src/world/chunks/chunk_manager.gd`
**Category:** Performance | **Confidence:** 88%

**Resolution:** `set_tiles_at_world_positions()` now groups changes by chunk first, then batch-reads old tile IDs using `chunk.get_tiles()` with a single mutex acquire per chunk, followed by `chunk.edit_tiles()` with a single mutex acquire per chunk. Total: 2 mutex acquires per affected chunk instead of 1 per tile.

---

### HIGH-5: ~~DebugHUD Accesses Private `_movement` Field~~ [RESOLVED]

**File:** `src/gui/debug_hud.gd`
**Category:** Quality / Maintainability | **Confidence:** 85%

**Resolution:** Player now exposes `get_movement_velocity() -> Vector2` and `get_on_floor() -> bool` public getters. DebugHUD uses `has_method("get_movement_velocity")` duck typing for safe access.

---

## Medium Severity Issues

### MED-1: ~~Deprecated String-Based Signal Emission~~ [RESOLVED]

**File:** `src/entities/player.gd`
**Category:** Quality | **Confidence:** 95%

**Resolution:** Now uses typed syntax: `SignalBus.player_chunk_changed.emit(_current_chunk)`.

---

### MED-2: `_apply_edit()` Fires Every Frame With No Throttle

**File:** `src/gui/gui_manager.gd:56-61, 143-165`
**Category:** Performance | **Confidence:** 85%

While mouse is held, `_apply_edit()` runs every frame. With brush size 64: 16,641 tile changes per frame, each emitting `tile_changed` signal. At 60fps: ~1M signal emissions/second, even when painting over already-painted tiles.

**Fix:** Only apply when mouse moves, or throttle to every 2-3 frames. Skip tiles that already match the target.

---

### MED-3: Thread-Unsafe Autoload Access in SimplexTerrainGenerator

**File:** `src/world/generators/simplex_terrain_generator.gd:81, 119-136`
**Category:** Safety | **Confidence:** 85%

`GlobalSettings.CHUNK_SIZE` and `TileIndex.AIR/DIRT/GRASS/STONE` are accessed from WorkerThreadPool threads. These are `const` values so no mutation occurs, but accessing Node properties from worker threads violates Godot's threading model and the project's own documented constraint.

**Fix:** Cache all autoload values into instance variables during `_init()`:

```gdscript
var _chunk_size: int
var _air_id: int
func _init(seed: int, config: Dictionary = {}):
    _chunk_size = GlobalSettings.CHUNK_SIZE  # main thread
    _air_id = TileIndex.AIR
```

---

### MED-4: ~~No Validation of Loaded Chunk Data Size~~ [RESOLVED]

**File:** `src/world/persistence/world_save_manager.gd`
**Category:** Robustness | **Confidence:** 82%

**Resolution:** `load_chunk()` now validates that `data.size() == CHUNK_SIZE * CHUNK_SIZE * 2`, logs an error on mismatch, and returns an empty `PackedByteArray`.

---

### MED-5: Duplicate `world_to_chunk_pos` Logic

**File:** `src/entities/player.gd`
**Category:** Quality / Duplication | **Confidence:** 85%

Player reimplements chunk position calculation inline instead of calling `GameServices.chunk_manager.world_to_chunk_pos()`. Still present — Player uses `GlobalSettings.CHUNK_SIZE` directly for its own chunk detection to avoid depending on ChunkManager initialization timing.

---

### MED-6: Duplicate Brush Constants

**File:** `src/gui/editing_toolbar.gd:7-8`, `src/gui/gui_manager.gd:17-18`
**Category:** Quality / Duplication | **Confidence:** 90%

`BRUSH_SQUARE = 0` and `BRUSH_CIRCLE = 1` defined identically in both files. Adding a new brush type requires updating both.

---

### MED-7: Missing Return Type Hint

**File:** `src/world/chunks/chunk.gd:59`
**Category:** Quality / Type Safety | **Confidence:** 80%

```gdscript
func _setup_visual_mesh(image: Image):  # missing -> void
```

All other functions in the file have return type annotations.

---

### MED-8: ~~Pool Size < Max Loaded Chunks~~ [RESOLVED]

**File:** `src/globals/global_settings.gd`
**Category:** Performance | **Confidence:** 85%

**Resolution:** `MAX_CHUNK_POOL_SIZE` is now calculated as `(2 * LOD_RADIUS + 1) * (2 * LOD_RADIUS + 1) * REGION_SIZE * REGION_SIZE = 1,296`, matching max loaded chunks.

---

### MED-9: BrushPreview Uses `set_meta`/`get_meta` for Dependency

**File:** `src/gui/gui_manager.gd:126-131`, `src/gui/brush_preview.gd:3-5`
**Category:** Quality / Safety | **Confidence:** 85%

```gdscript
_brush_preview.set_script(load("res://src/gui/brush_preview.gd"))
_brush_preview.set_meta("gui_manager", self)
```

Fragile: hardcoded path breaks on move, `get_meta()` returns untyped Variant, misspelled key causes silent failure.

**Fix:** Give BrushPreview a `class_name`, use typed property injection.

---

### MED-10: Full Queue Re-Sort on Every `add_chunks_to_generation`

**File:** `src/world/chunks/chunk_loader.gd:44-54`
**Category:** Performance | **Confidence:** 82%

Sorts entire merged queue O(N log N) under the mutex on every player region change. With 1,296 chunks in queue, this blocks both `get_built_chunks()` and worker task completion.

**Fix:** Sort only new chunks, then merge-insert. Or use a priority queue.

---

## Low Severity Issues

### LOW-1: No `class_name` on Autoloads

`GlobalSettings`, `SignalBus`, `TileIndex` lack `class_name` declarations, limiting IDE autocomplete and type-hinting in other scripts.

### LOW-2: ~~Test Accesses Private `TileIndex._tiles`~~ [N/A]

Test files have been removed from the repository.

### LOW-3: ~~`_removal_queue.has(chunk)` Is O(N)~~ [RESOLVED]

ChunkManager now uses `_removal_queue_set: Dictionary` for O(1) duplicate checking alongside the Array queue.

### LOW-4: ~~No Guard Against Empty `zoom_presets`~~ [RESOLVED]

`_cycle_zoom_preset()` now returns early if `zoom_presets.is_empty()`.

### LOW-5: Debug Overlay Mutex + Allocation Every Frame

`src/gui/chunk_debug_overlay.gd:23-30` — `get_debug_info()` acquires ChunkLoader mutex and duplicates the entire queue array every visible frame. Should throttle.

---

## Performance Analysis

### Threading Efficiency

| Concern                                   | Assessment                                                      |
| ----------------------------------------- | --------------------------------------------------------------- |
| Mutex hold time in `_generate_chunk_task` | Good — only held during queue operations, not during generation |
| Backpressure system                       | Good — pauses generation when build queue > 128                 |
| `stop()` main-thread block                | Fixed — busy-wait now has 2-second timeout                      |
| Queue sort under mutex                    | Medium — O(N log N) under lock on region change                 |
| `get_debug_info()` copies                 | Minor — full queue duplication every visible frame              |

### Memory Management

| Concern                         | Assessment                                                                        |
| ------------------------------- | --------------------------------------------------------------------------------- |
| Chunk pooling                   | Fixed — pool size now calculated to match max loaded chunks (1,296)               |
| Pool pre-creation               | Blocks `_ready()` — 1,296 synchronous instantiations                              |
| `_entities.values()` per frame  | Allocates new Array each `_physics_process`                                       |
| PackedByteArray COW             | Correct — comment says "reference" but GDScript COW means effective copy on write |
| ShaderMaterial `local_to_scene` | Correct — each chunk gets its own material (required for per-chunk data texture)  |

### Frame Budget

| Limit                          | Value     | Assessment                                                                |
| ------------------------------ | --------- | ------------------------------------------------------------------------- |
| `MAX_CHUNK_BUILDS_PER_FRAME`   | 16        | Reasonable — each build does one GPU texture upload                       |
| `MAX_CHUNK_REMOVALS_PER_FRAME` | 32        | Reasonable — removals are cheaper than builds                             |
| Terrain editing per frame      | Unbounded | Partially improved — batched per-chunk mutex, but still no frame throttle |

### Rendering Pipeline

| Concern                                       | Assessment                                            |
| --------------------------------------------- | ----------------------------------------------------- |
| `ImageTexture.update()` for edits             | Good — in-place GPU update, no new texture allocation |
| `ImageTexture.create_from_image()` for builds | Necessary — initial upload requires creation          |
| Shader tile lookup                            | Efficient — single texture sample per fragment        |
| `Texture2DArray` for tiles                    | Good — avoids texture atlas UV math                   |

---

## Test Coverage Assessment

**Note:** The test files (`tests/test_runner.gd`, etc.) have been removed from the repository. The coverage information below reflects what was tested before removal.

### Previously Covered Systems

| System                  | Test File        | Coverage                                |
| ----------------------- | ---------------- | --------------------------------------- |
| GameServices            | `test_runner.gd` | Service registration, retrieval         |
| TileIndex               | `test_runner.gd` | Registration, properties, texture array |
| BaseTerrainGenerator    | `test_runner.gd` | Interface compliance                    |
| SimplexTerrainGenerator | `test_runner.gd` | Output validation                       |
| WorldSaveManager        | `test_runner.gd` | Save, load, metadata, deletion          |
| CameraController        | `test_runner.gd` | Initialization, zoom                    |
| EntityManager           | `test_runner.gd` | Spawn, despawn, lifecycle               |
| SignalBus               | `test_runner.gd` | Signal declarations                     |

### NOT Covered (critical gaps)

| System                 | Risk      | Notes                                                       |
| ---------------------- | --------- | ----------------------------------------------------------- |
| **ChunkManager**       | Very High | Core orchestrator — no lifecycle, pool, or generation tests |
| **ChunkLoader**        | Very High | Threading, queues, backpressure — zero coverage             |
| **CollisionDetector**  | High      | Swept AABB correctness — zero coverage                      |
| **MovementController** | High      | Physics behavior — zero coverage                            |
| **Player**             | Medium    | Input handling, chunk detection — zero coverage             |
| **Chunk**              | Medium    | Data format, edit_tiles, mutex safety — zero coverage       |
| **All GUI classes**    | Low       | UI is hard to unit test, acceptable gap                     |

For a plugin release, integration tests for `CollisionDetector.sweep_aabb()`, `MovementController.move()`, and `ChunkManager` lifecycle are strongly recommended.

---

## Summary Table

| ID     | File                                  | Severity | Category   | Description                           | Status        |
| ------ | ------------------------------------- | -------- | ---------- | ------------------------------------- | ------------- |
| CRIT-1 | `chunk_loader.gd`                     | Critical | Bug/Perf   | `stop()` busy-polls main thread       | **RESOLVED**  |
| CRIT-2 | `world_save_manager.gd`               | Critical | Bug/Safety | Missing path separator                | **RESOLVED**  |
| HIGH-1 | `chunk_manager.gd`                    | High     | Bug        | `world_ready` fires prematurely       | **RESOLVED**  |
| HIGH-2 | `player.gd`                           | High     | Quality    | Unused CharacterBody2D inheritance    | Open          |
| HIGH-3 | `camera_controller.gd`                | High     | Bug        | Smoothing \*60 disables smooth follow | **RESOLVED**  |
| HIGH-4 | `chunk_manager.gd`                    | High     | Perf       | O(N) per-tile pre-pass in editing     | **RESOLVED**  |
| HIGH-5 | `debug_hud.gd`                        | High     | Quality    | Private field access across scripts   | **RESOLVED**  |
| MED-1  | `player.gd`                           | Medium   | Quality    | Deprecated `emit_signal()`            | **RESOLVED**  |
| MED-2  | `gui_manager.gd`                      | Medium   | Perf       | No edit throttle, 1M signals/sec      | Open          |
| MED-3  | `simplex_terrain_generator.gd`        | Medium   | Safety     | Autoload access from worker thread    | Open          |
| MED-4  | `world_save_manager.gd`               | Medium   | Robustness | No chunk data size validation         | **RESOLVED**  |
| MED-5  | `player.gd`                           | Medium   | Quality    | Duplicates world_to_chunk_pos         | Open          |
| MED-6  | `editing_toolbar.gd`/`gui_manager.gd` | Medium   | Quality    | Duplicate BRUSH\_\* constants         | Open          |
| MED-7  | `chunk.gd`                            | Medium   | Quality    | Missing return type hint              | Open          |
| MED-8  | `chunk_manager.gd`                    | Medium   | Perf       | Pool size 512 < max 1,296             | **RESOLVED**  |
| MED-9  | `gui_manager.gd`                      | Medium   | Safety     | Fragile meta-based dependency         | Open          |
| MED-10 | `chunk_loader.gd`                     | Medium   | Perf       | Full queue re-sort under mutex        | Open          |
| LOW-1  | `global_settings.gd`                  | Low      | Quality    | No class_name on autoloads            | Open          |
| LOW-2  | `test_runner.gd`                      | Low      | Quality    | Private field access in tests         | N/A (removed) |
| LOW-3  | `chunk_manager.gd`                    | Low      | Perf       | O(N) removal queue lookup             | **RESOLVED**  |
| LOW-4  | `camera_controller.gd`                | Low      | Robustness | No empty zoom_presets guard           | **RESOLVED**  |
| LOW-5  | `chunk_debug_overlay.gd`              | Low      | Perf       | Debug mutex + alloc every frame       | Open          |
