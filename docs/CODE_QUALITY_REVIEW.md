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

### CRIT-1: `stop()` Busy-Polls the Main Thread

**File:** `src/world/chunks/chunk_loader.gd:228-245`
**Category:** Bug / Performance | **Confidence:** 95%

```gdscript
func stop() -> void:
    _mutex.lock()
    _shutdown_requested = true
    ...
    _mutex.unlock()
    while true:
        _mutex.lock()
        var remaining = _active_task_count
        _mutex.unlock()
        if remaining == 0:
            break
        OS.delay_msec(1)
```

Called from `ChunkManager._exit_tree()` on the main thread. Blocks the engine's shutdown for as long as workers take to finish (potentially hundreds of ms). No timeout — hangs permanently if a custom generator has an infinite loop.

Additionally, `_chunks_in_progress.clear()` at line 233 clears tracking while tasks are still between their two mutex acquisitions. Workers still decrement `_active_task_count` correctly, but the premature clear is logically incorrect.

**Fix:** Add a timeout. For plugin use, call `stop()` from a separate thread or use `Thread.wait_to_finish()`. At minimum, document the main-thread stall.

---

### CRIT-2: Missing Path Separator in `_delete_directory_contents`

**File:** `src/world/persistence/world_save_manager.gd:236`
**Category:** Bug / Safety | **Confidence:** 95%

```gdscript
var err := DirAccess.remove_absolute(dir_path + entry)
```

String concatenation instead of `path_join()`. Currently works because callers pass trailing-slash paths, but any future caller passing `"user://worlds/myworld/chunks"` produces `"user://worlds/myworld/chunksfile.dat"` — deleting the wrong path or failing silently.

**Fix:** `var full_path = dir_path.path_join(entry)`

---

## High Severity Issues

### HIGH-1: `world_ready` Signal Can Fire Prematurely

**File:** `src/world/chunks/chunk_manager.gd:94-99`
**Category:** Bug | **Confidence:** 85%

```gdscript
if not _initial_load_complete and not _chunks.is_empty():
    var loader_info = _chunk_loader.get_debug_info()
    if loader_info["generation_queue_size"] == 0 and loader_info["build_queue_size"] == 0 and loader_info["in_progress_size"] == 0:
        _initial_load_complete = true
        SignalBus.world_ready.emit()
```

Fires after the first batch of 1-16 chunks builds if the worker pool happens to be momentarily idle that frame. Does not wait for all chunks in the generation radius to complete.

**Fix:** Track the initial expected chunk count and only fire after all are built.

---

### HIGH-2: Player Extends CharacterBody2D Without Using It

**File:** `src/entities/player.gd:1`
**Category:** Quality / Architecture | **Confidence:** 85%

`Player extends CharacterBody2D` but never calls `move_and_slide()`, never uses the built-in `velocity`, and never uses any CharacterBody2D features. All physics is handled by `MovementController` + `CollisionDetector`. This wastes CPU (Godot processes the physics body every frame), shadows the velocity concept, and misleads users about the physics system.

**Fix:** Change to `extends Node2D` or `extends BaseEntity`.

---

### HIGH-3: Camera Smoothing Formula Disables Smooth Follow

**File:** `src/camera/camera_controller.gd:42`
**Category:** Bug | **Confidence:** 90%

```gdscript
var weight = 1.0 - exp(-smoothing * 60.0 * delta)
```

The standard formula is `1.0 - exp(-smoothing * delta)`. The extra `* 60.0` makes `weight ≈ 0.99995` at 60fps with `smoothing=10.0` — the camera snaps instantly every frame. Zero visible smoothing.

**Fix:** Remove `* 60.0`, or if 60fps-normalization is intended, use `1.0 - pow(1.0 - smoothing_per_frame, 60.0 * delta)`.

---

### HIGH-4: Terrain Editing Pre-Pass Is O(N) Per Tile

**File:** `src/world/chunks/chunk_manager.gd:345-381`
**Category:** Performance | **Confidence:** 88%

```gdscript
var old_tile_ids: Array = []
for change in changes:
    var tile_data = get_tile_at_world_pos(change["pos"])
    old_tile_ids.append(tile_data[0])
```

For a large brush (radius 64 = 16,641 tiles), this performs 16,641 individual mutex acquire/release + dictionary lookups before the actual edit pass. Each `get_tile_at_world_pos()` recalculates chunk position and acquires the chunk mutex separately.

**Fix:** Merge old-tile-id capture into the existing batch-by-chunk loop, acquiring mutex once per chunk.

---

### HIGH-5: DebugHUD Accesses Private `_movement` Field

**File:** `src/gui/debug_hud.gd:37-39`
**Category:** Quality / Maintainability | **Confidence:** 85%

```gdscript
if _player._movement:
    var vel = _player._movement.velocity
```

Direct access to `Player._movement` (private by convention). Breaks if Player refactors its movement system.

**Fix:** Add public getters to Player: `get_velocity() -> Vector2`, `get_is_on_floor() -> bool`.

---

## Medium Severity Issues

### MED-1: Deprecated String-Based Signal Emission

**File:** `src/entities/player.gd:60`
**Category:** Quality | **Confidence:** 95%

```gdscript
SignalBus.emit_signal("player_chunk_changed", _current_chunk)
```

Every other emission uses typed syntax (`SignalBus.chunk_loaded.emit(...)`). This is the only legacy string-based call. Deprecated in Godot 4.

**Fix:** `SignalBus.player_chunk_changed.emit(_current_chunk)`

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

### MED-4: No Validation of Loaded Chunk Data Size

**File:** `src/world/persistence/world_save_manager.gd:76-88`
**Category:** Robustness | **Confidence:** 82%

```gdscript
var data := file.get_buffer(file.get_length())
file.close()
return data
```

No check that loaded data matches expected size (`CHUNK_SIZE * CHUNK_SIZE * 2`). Truncated/corrupted files produce partial data that silently renders as partial air.

**Fix:** Validate size, log error, return empty array on mismatch.

---

### MED-5: Duplicate `world_to_chunk_pos` Logic

**File:** `src/entities/player.gd:53-60`
**Category:** Quality / Duplication | **Confidence:** 85%

Player reimplements chunk position calculation inline instead of calling `GameServices.chunk_manager.world_to_chunk_pos()`.

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

### MED-8: Pool Size < Max Loaded Chunks

**File:** `src/world/chunks/chunk_manager.gd:39-43`
**Category:** Performance | **Confidence:** 85%

Pool pre-creates 512 chunks, but max loaded = `(2*4+1)^2 * 4^2 = 1,296`. Once pool is exhausted, fallback to `_chunk_scene.instantiate()` at runtime defeats pooling.

**Fix:** Calculate pool size from `LOD_RADIUS` and `REGION_SIZE`, or increase to 1,296+.

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

### LOW-2: Test Accesses Private `TileIndex._tiles`

`tests/test_runner.gd:141` — `TileIndex._tiles.erase(4)` for cleanup. No `deregister_tile()` API exists.

### LOW-3: `_removal_queue.has(chunk)` Is O(N)

`src/world/chunks/chunk_manager.gd:157` — `Array.has()` linear scan for up to 512 chunk objects. A Dictionary set would give O(1).

### LOW-4: No Guard Against Empty `zoom_presets`

`src/camera/camera_controller.gd:62` — `zoom_presets[_current_preset_index]` crashes if the array is set to empty via Inspector.

### LOW-5: Debug Overlay Mutex + Allocation Every Frame

`src/gui/chunk_debug_overlay.gd:23-30` — `get_debug_info()` acquires ChunkLoader mutex and duplicates the entire queue array every visible frame. Should throttle.

---

## Performance Analysis

### Threading Efficiency

| Concern                                   | Assessment                                                      |
| ----------------------------------------- | --------------------------------------------------------------- |
| Mutex hold time in `_generate_chunk_task` | Good — only held during queue operations, not during generation |
| Backpressure system                       | Good — pauses generation when build queue > 128                 |
| `stop()` main-thread block                | Bad — busy-wait with no timeout                                 |
| Queue sort under mutex                    | Medium — O(N log N) under lock on region change                 |
| `get_debug_info()` copies                 | Minor — full queue duplication every visible frame              |

### Memory Management

| Concern                         | Assessment                                                                        |
| ------------------------------- | --------------------------------------------------------------------------------- |
| Chunk pooling                   | Functional but undersized (512 vs 1,296 needed)                                   |
| Pool pre-creation               | Blocks `_ready()` — 512 synchronous instantiations                                |
| `_entities.values()` per frame  | Allocates new Array each `_physics_process`                                       |
| PackedByteArray COW             | Correct — comment says "reference" but GDScript COW means effective copy on write |
| ShaderMaterial `local_to_scene` | Correct — each chunk gets its own material (required for per-chunk data texture)  |

### Frame Budget

| Limit                          | Value     | Assessment                                                   |
| ------------------------------ | --------- | ------------------------------------------------------------ |
| `MAX_CHUNK_BUILDS_PER_FRAME`   | 16        | Reasonable — each build does one GPU texture upload          |
| `MAX_CHUNK_REMOVALS_PER_FRAME` | 32        | Reasonable — removals are cheaper than builds                |
| Terrain editing per frame      | Unbounded | Bad — large brush = 16K+ tile changes per frame, no throttle |

### Rendering Pipeline

| Concern                                       | Assessment                                            |
| --------------------------------------------- | ----------------------------------------------------- |
| `ImageTexture.update()` for edits             | Good — in-place GPU update, no new texture allocation |
| `ImageTexture.create_from_image()` for builds | Necessary — initial upload requires creation          |
| Shader tile lookup                            | Efficient — single texture sample per fragment        |
| `Texture2DArray` for tiles                    | Good — avoids texture atlas UV math                   |

---

## Test Coverage Assessment

### Covered Systems

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

| ID     | File                                  | Line      | Severity | Category   | Description                           |
| ------ | ------------------------------------- | --------- | -------- | ---------- | ------------------------------------- |
| CRIT-1 | `chunk_loader.gd`                     | 228-245   | Critical | Bug/Perf   | `stop()` busy-polls main thread       |
| CRIT-2 | `world_save_manager.gd`               | 236       | Critical | Bug/Safety | Missing path separator                |
| HIGH-1 | `chunk_manager.gd`                    | 94-99     | High     | Bug        | `world_ready` fires prematurely       |
| HIGH-2 | `player.gd`                           | 1         | High     | Quality    | Unused CharacterBody2D inheritance    |
| HIGH-3 | `camera_controller.gd`                | 42        | High     | Bug        | Smoothing \*60 disables smooth follow |
| HIGH-4 | `chunk_manager.gd`                    | 345-381   | High     | Perf       | O(N) per-tile pre-pass in editing     |
| HIGH-5 | `debug_hud.gd`                        | 37-39     | High     | Quality    | Private field access across scripts   |
| MED-1  | `player.gd`                           | 60        | Medium   | Quality    | Deprecated `emit_signal()`            |
| MED-2  | `gui_manager.gd`                      | 56-61     | Medium   | Perf       | No edit throttle, 1M signals/sec      |
| MED-3  | `simplex_terrain_generator.gd`        | 81+       | Medium   | Safety     | Autoload access from worker thread    |
| MED-4  | `world_save_manager.gd`               | 86        | Medium   | Robustness | No chunk data size validation         |
| MED-5  | `player.gd`                           | 53-60     | Medium   | Quality    | Duplicates world_to_chunk_pos         |
| MED-6  | `editing_toolbar.gd`/`gui_manager.gd` | 7-8/17-18 | Medium   | Quality    | Duplicate BRUSH\_\* constants         |
| MED-7  | `chunk.gd`                            | 59        | Medium   | Quality    | Missing return type hint              |
| MED-8  | `chunk_manager.gd`                    | 39-43     | Medium   | Perf       | Pool size 512 < max 1,296             |
| MED-9  | `gui_manager.gd`                      | 126-131   | Medium   | Safety     | Fragile meta-based dependency         |
| MED-10 | `chunk_loader.gd`                     | 44-54     | Medium   | Perf       | Full queue re-sort under mutex        |
| LOW-1  | `global_settings.gd`                  | —         | Low      | Quality    | No class_name on autoloads            |
| LOW-2  | `test_runner.gd`                      | 141       | Low      | Quality    | Private field access in tests         |
| LOW-3  | `chunk_manager.gd`                    | 157       | Low      | Perf       | O(N) removal queue lookup             |
| LOW-4  | `camera_controller.gd`                | 62        | Low      | Robustness | No empty zoom_presets guard           |
| LOW-5  | `chunk_debug_overlay.gd`              | 29        | Low      | Perf       | Debug mutex + alloc every frame       |
