# Substrata Codebase Audit

Comprehensive architecture audit covering dependencies, scene tree, threading model, data flows, and API surface. Generated February 2026.

---

## Table of Contents

1. [File Dependency Map](#1-file-dependency-map)
2. [Autoload Dependency Graph](#2-autoload-dependency-graph)
3. [Scene Tree Architecture](#3-scene-tree-architecture)
4. [Threading Model](#4-threading-model)
5. [Data Flow Maps](#5-data-flow-maps)
6. [Public API Surface](#6-public-api-surface)
7. [Configuration and Constants](#7-configuration-and-constants)
8. [Architecture Strengths](#8-architecture-strengths)
9. [Architecture Issues](#9-architecture-issues)

---

## 1. File Dependency Map

Every dependency is traced from actual code — `preload`, `class_name` references, autoload access, and signal usage.

### Leaf Nodes (no external dependencies)

| File                     | Extends        | Notes                                                   |
| ------------------------ | -------------- | ------------------------------------------------------- |
| `signal_bus.gd`          | Node           | Pure signal declarations                                |
| `global_settings.gd`     | Node           | Pure constants                                          |
| `tile_index.gd`          | Node           | Loads textures at runtime from `res://assets/textures/` |
| `game_services.gd`       | Node           | Holds typed references, populated externally            |
| `world_save_manager.gd`  | RefCounted     | Pure file I/O                                           |
| `collision_detector.gd`  | RefCounted     | Receives ChunkManager via constructor                   |
| `movement_controller.gd` | RefCounted     | Receives CollisionDetector via constructor              |
| `camera_controller.gd`   | Camera2D       | Pure Godot APIs + hardcoded `"Player"` node lookup      |
| `controls_overlay.gd`    | PanelContainer | Hardcoded help text                                     |

### Core Engine Files

```text
base_terrain_generator.gd
  extends RefCounted
  dependencies: NONE (clean abstract base)

simplex_terrain_generator.gd
  extends BaseTerrainGenerator
  dependencies: GlobalSettings (line 81), TileIndex (lines 119, 124-136)
  ISSUE: Accesses autoload Nodes from worker thread

chunk_loader.gd (class_name ChunkLoader)
  extends RefCounted
  dependencies: GlobalSettings (lines 71, 139, 195, 209), BaseTerrainGenerator (constructor param)

chunk.gd (class_name Chunk)
  extends Node2D
  dependencies: GlobalSettings (10 references), TileIndex (lines 65-67)
  static var: _shared_quad_mesh (class-level shared state)

chunk_manager.gd (class_name ChunkManager)
  extends Node2D
  dependencies: GlobalSettings (15+ references), SignalBus (6 calls),
                TileIndex (line 291), ChunkLoader, SimplexTerrainGenerator (hardcoded line 35)
  preload: chunk.tscn via UID
```

### Entity System Files

```text
base_entity.gd (class_name BaseEntity)
  extends Node2D
  dependencies: MovementController, CollisionDetector (composition)

entity_manager.gd (class_name EntityManager)
  extends Node
  dependencies: SignalBus (lines 28, 38), BaseEntity (type)

player.gd (class_name Player)
  extends CharacterBody2D  (NOT BaseEntity)
  dependencies: GlobalSettings, SignalBus, GameServices,
                CollisionDetector, MovementController
```

### GUI Files

```text
gui_manager.gd (class_name GUIManager)
  dependencies: TileIndex, GameServices, EditingToolbar, DebugHUD, CursorInfo, ControlsOverlay
  runtime loads: brush_preview.gd via string path

brush_preview.gd (no class_name)
  dependencies: GUIManager private fields via get_meta()

editing_toolbar.gd (class_name EditingToolbar)
  dependencies: TileIndex (lines 12, 59, 63-64)

debug_hud.gd (class_name DebugHUD)
  dependencies: GameServices, Player._movement (private field access)

cursor_info.gd (class_name CursorInfo)
  dependencies: GameServices, TileIndex

chunk_debug_overlay.gd (class_name ChunkDebugOverlay)
  dependencies: GlobalSettings (5 calls), GameServices (lines 26, 29)
```

### Orchestration

```text
game_instance.gd (class_name GameInstance)
  extends Node
  dependencies: GameServices, ChunkManager, EntityManager, WorldSaveManager
  @onready: $ChunkManager, $EntityManager
```

---

## 2. Autoload Dependency Graph

### Registration Order (project.godot)

```text
1. SignalBus      — no deps
2. GlobalSettings — no deps
3. TileIndex      — no deps (loads textures in _ready)
4. GameServices   — no deps (populated by GameInstance)
```

### Initialization Sequence

```text
Godot autoload init:
  SignalBus._ready()      → declares signals
  GlobalSettings._ready() → declares constants
  TileIndex._ready()      → registers tiles 0-3, calls rebuild_texture_array()
  GameServices._ready()   → empty vars, waiting for population

Main scene loads:
  GameInstance._ready()
    → GameServices.chunk_manager = $ChunkManager
    → GameServices.entity_manager = $EntityManager
    → GameServices.tile_registry = TileIndex
    → GameServices.terrain_generator = chunk_manager.get_terrain_generator()
    → GameServices.world_save_manager = WorldSaveManager.new()
    → chunk_manager.setup_persistence(save_manager, world_name)
```

### Invisible Ordering Invariant

TileIndex must complete `rebuild_texture_array()` before ChunkManager starts generating chunks. This holds because autoloads run before the main scene, but nothing enforces this — a future change to lazy-load TileIndex could break chunk rendering silently.

### Circular Dependency (Logical, not Import)

```text
ChunkManager → creates SimplexTerrainGenerator
SimplexTerrainGenerator → reads TileIndex (autoload)
TileIndex → registered in GameServices by GameInstance
GameInstance → depends on ChunkManager being _ready first
```

Not a deadlock, but an implicit ordering constraint.

---

## 3. Scene Tree Architecture

### Full Runtime Scene Tree

```text
GameInstance (Node)                          [game_instance.tscn]
├── Player (CharacterBody2D)               [player.tscn]
│     collision_layer = 2
│     position = Vector2(94, -112)
│     └── Sprite2D
│           texture: assets/textures/player.png
├── CameraController (Camera2D)
│     zoom = Vector2(4, 4)
├── ChunkManager (Node2D)                  [chunk_manager.tscn]
│     └── [Chunk children — added dynamically from pool]
│           Chunk (Node2D)                 [chunk.tscn]
│             └── MeshInstance2D
│                   material: ShaderMaterial (local_to_scene=true)
│                     shader: terrain.gdshader
│                     shader_parameter/texture_size = Vector2(32, 32)
├── EntityManager (Node)
│     └── [BaseEntity children — added via spawn()]
├── ChunkDebugOverlay (Node2D)
│     z_index: 100, visible: false
└── UILayer (CanvasLayer)
      └── GUIManager (Control)             [gui_manager.tscn]
            └── [Built dynamically in _ready()]
                  ├── left_panel (VBoxContainer)
                  │     ├── EditingToolbar (PanelContainer)
                  │     └── DebugHUD (PanelContainer)
                  ├── CursorInfo (Control)
                  └── ControlsOverlay (PanelContainer)
      [BrushPreview added to GameInstance root, not UILayer — intentional for world-space coords]
```

### Hardcoded Node Path Lookups

| File                   | Line | Lookup                                   | Risk                                  |
| ---------------------- | ---- | ---------------------------------------- | ------------------------------------- |
| `camera_controller.gd` | 35   | `"Player"` via `get_node_or_null`        | Breaks if player renamed              |
| `debug_hud.gd`         | 26   | `"Player"` via `get_node_or_null`        | Breaks if player renamed              |
| `game_instance.gd`     | 4-5  | `$ChunkManager`, `$EntityManager`        | Breaks if nodes renamed in scene      |
| `gui_manager.gd`       | 129  | `load("res://src/gui/brush_preview.gd")` | Path-based, breaks on file move       |
| `gui_manager.gd`       | 131  | `get_tree().current_scene.add_child`     | Assumes GameInstance is current scene |

### Signal Wiring

All signal connections are code-based (`connect()` calls), none in `.tscn` files:

**Connections (listeners):**

| File               | Line  | Signal                           | Handler                    |
| ------------------ | ----- | -------------------------------- | -------------------------- |
| `chunk_manager.gd` | 45    | `SignalBus.player_chunk_changed` | `_on_player_chunk_changed` |
| `gui_manager.gd`   | 39-41 | `EditingToolbar.brush_*_changed` | `_on_brush_*_changed`      |

**Emissions:**

| File                | Line     | Signal                                         |
| ------------------- | -------- | ---------------------------------------------- |
| `player.gd`         | 60       | `SignalBus.player_chunk_changed`               |
| `chunk_manager.gd`  | 88       | `SignalBus.chunk_loaded`                       |
| `chunk_manager.gd`  | 99       | `SignalBus.world_ready`                        |
| `chunk_manager.gd`  | 159      | `SignalBus.chunk_unloaded`                     |
| `chunk_manager.gd`  | 381      | `SignalBus.tile_changed`                       |
| `chunk_manager.gd`  | 426, 437 | `SignalBus.world_saving`, `world_saved`        |
| `entity_manager.gd` | 28, 38   | `SignalBus.entity_spawned`, `entity_despawned` |

---

## 4. Threading Model

### What Runs Where

| Code                                          | Thread           | Notes                                                                                        |
| --------------------------------------------- | ---------------- | -------------------------------------------------------------------------------------------- |
| `SimplexTerrainGenerator.generate_chunk()`    | WorkerThreadPool | Must not touch scene tree                                                                    |
| `ChunkLoader._generate_visual_image()`        | WorkerThreadPool | Creates Image from PackedByteArray                                                           |
| `ChunkLoader._generate_chunk_task()`          | WorkerThreadPool | Orchestrates generation + image                                                              |
| `ChunkManager._process()`                     | Main             | Processes build/removal queues                                                               |
| `Chunk.generate()`, `build()`, `edit_tiles()` | Main             | GPU uploads happen here                                                                      |
| `Player._physics_process()`                   | Main             | Despite `run_on_separate_thread=true` in project.godot, GDScript callbacks still run on main |
| `EntityManager._physics_process()`            | Main             | Iterates all entities                                                                        |
| `WorldSaveManager.*`                          | Main             | File I/O on main thread                                                                      |

### Synchronization Primitives

| Instance             | Owner                | Protects                                                                                                                      |
| -------------------- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `ChunkLoader._mutex` | ChunkLoader (single) | `_generation_queue`, `_build_queue`, `_chunks_in_progress`, `_shutdown_requested`, `_generation_paused`, `_active_task_count` |
| `Chunk._mutex`       | Chunk (per-instance) | `_terrain_data`, `_terrain_image`, `_data_texture`                                                                            |

### Full Chunk Lifecycle (Threading Perspective)

```text
MAIN THREAD                              WORKER THREAD(S)
───────────                              ─────────────────
Player detects chunk change
  → SignalBus.player_chunk_changed
  → ChunkManager queues generation
  → ChunkLoader.add_chunks_to_generation()
    [LOCK] write to _generation_queue
    [UNLOCK]
    → _submit_tasks()
      [LOCK] pop from _generation_queue
             submit WorkerThreadPool tasks
      [UNLOCK]
                                         _generate_chunk_task(chunk_pos)
                                           [LOCK] check _shutdown, decrement _active
                                           [UNLOCK]
                                           → generate_chunk() (no locks held)
                                           → _generate_visual_image() (no locks held)
                                           [LOCK] append to _build_queue
                                                  backpressure check
                                           [UNLOCK]

ChunkManager._process() each frame:
  → ChunkLoader.get_built_chunks(16)
    [LOCK] pop up to 16 from _build_queue
    [UNLOCK]
  → For each: chunk.generate() + chunk.build()
    [CHUNK LOCK] write terrain data
    [CHUNK UNLOCK]
    → ImageTexture upload (GPU)
  → add_child(chunk) if needed
```

### Race Condition Analysis

**`stop()` busy-waits on main thread** (`chunk_loader.gd:238-245`): Called from `ChunkManager._exit_tree()`. Blocks main thread with `OS.delay_msec(1)` loop until all workers finish. No timeout — hangs if a generator has an infinite loop.

**`_shared_quad_mesh` lazy init** (`chunk.gd:21-25`): Safe today (all `_ready()` calls on main thread), but has no mutex protection. Would race if chunks were ever instantiated from workers.

**`_chunks_in_progress.clear()` during shutdown** (`chunk_loader.gd:233`): Called in `stop()` while tasks may still be between their two mutex acquisitions. Workers will still decrement `_active_task_count` correctly, but the tracking dict is prematurely cleared. Benign today, fragile for future changes.

**`_generate_chunk_task` TOCTOU window** (`chunk_loader.gd:169-203`): Between the first unlock (line 177) and second lock (line 184), `stop()` could set `_shutdown_requested`. The guard at line 187 handles this correctly, but the two-phase lock pattern is non-obvious and undocumented.

---

## 5. Data Flow Maps

### Terrain Data Pipeline

```text
Generation (worker thread):
  chunk_pos → SimplexTerrainGenerator.generate_chunk()
  → PackedByteArray [CHUNK_SIZE * CHUNK_SIZE * 2 bytes]
     layout: index = (y * CHUNK_SIZE + x) * 2
             byte[index]   = tile_id  (0-255)
             byte[index+1] = cell_id  (always 0 currently)

Visual Encoding (worker thread):
  PackedByteArray → ChunkLoader._generate_visual_image()
  → Image [CHUNK_SIZE x CHUNK_SIZE, FORMAT_RGBA8]
     Y-INVERTED: image_y = (CHUNK_SIZE-1) - data_y
     pixel = Color(tile_id/255.0, cell_id/255.0, 0, 0)

GPU Upload (main thread):
  Image → ImageTexture.create_from_image()
  → ShaderMaterial.set_shader_parameter("chunk_data_texture", texture)
  TileIndex.get_texture_array() → "tile_textures" parameter

Shader Decode (GPU):
  UV → sample chunk_data_texture → tile_id = R * 255
  if tile_id < 0.5: discard (air)
  world_uv = world_position / texture_size
  COLOR = texture(tile_textures, vec3(world_uv, tile_id))
```

### Terrain Editing Pipeline

```text
Mouse hold → GUIManager._process() → _apply_edit() [every frame]
  → camera.get_global_mouse_position() → world_pos
  → Generate changes array by brush shape/size
  → ChunkManager.set_tiles_at_world_positions(changes)
    1. Pre-read old tile IDs (per-tile mutex acquire)
    2. Group changes by chunk position
    3. Per chunk: Chunk.edit_tiles(batch)
       [LOCK] update PackedByteArray + Image (Y-inverted)
       [UNLOCK]
       → ImageTexture.update(_terrain_image) [in-place GPU update, no new alloc]
    4. Mark chunk dirty for save
    5. Emit SignalBus.tile_changed per change
```

### Entity Lifecycle

```text
Spawn:  EntityManager.spawn(entity)
  → entity.entity_id = _next_id++
  → _entities[id] = entity
  → add_child(entity)
  → SignalBus.entity_spawned.emit(entity)

Update: EntityManager._physics_process(delta) [every frame]
  → for entity in _entities.values():  [allocates new Array each call]
       entity.entity_process(delta)
         → MovementController.move() if configured
         → _entity_update(delta) [virtual]

Despawn: EntityManager.despawn(id)
  → _entities.erase(id)
  → SignalBus.entity_despawned.emit(entity)
  → entity.queue_free()
```

### Save/Load Pipeline

```text
Save triggers:
  - ChunkManager._exit_tree() → save_world()
  - ChunkManager._mark_chunks_for_removal() → _save_dirty_chunk() [per dirty chunk]

save_world():
  → SignalBus.world_saving.emit()
  → per dirty chunk:
       chunk.get_terrain_data() [mutex-locked copy]
       → WorldSaveManager.save_chunk(name, pos, data)
         → FileAccess.open(path, WRITE) → store_buffer(raw bytes, no header)
  → WorldSaveManager.save_world_meta(name, seed, generator, {})
       → JSON.stringify({seed, generator, version, timestamps})
  → SignalBus.world_saved.emit()

Load: *** NOT IMPLEMENTED ***
  ChunkManager has load_chunk_data() and has_saved_chunk() methods,
  but these are NEVER CALLED. ChunkLoader generates ALL chunks fresh.
  Saved edits are written to disk but never restored on load.
```

### Input Pipeline

```text
Movement:  A/D/Space → Player._physics_process()
  → MovementController.move() → CollisionDetector.sweep_aabb()
  → ChunkManager.is_solid_at_world_pos() → TileIndex.is_solid()
  → new position → _update_current_chunk() → SignalBus if chunk changed

Camera:    Mouse wheel / Z → CameraController._input()
  → zoom adjustment or preset cycle

Editing:   Mouse LMB → GUIManager._gui_input() → _is_editing flag
  → _process() → _apply_edit() → ChunkManager.set_tiles_at_world_positions()

Debug:     F1-F4 → GUIManager._unhandled_input() + ChunkDebugOverlay._unhandled_input()
  BUG: F1-F4 each map to TWO input actions (see Issues section)

Material:  1-9 → GUIManager._unhandled_input() → _set_material()
Brush:     Q/E → GUIManager._unhandled_input() → _change_brush_size()
```

---

## 6. Public API Surface

### Designed for Extension (public, documented)

**BaseTerrainGenerator** — Abstract base for custom terrain generators:

- `generate_chunk(chunk_pos: Vector2i) -> PackedByteArray`
- `get_generator_name() -> String`

**TileIndex** — Tile registry:

- `register_tile(id, name, solid, texture_path, color, properties)`
- `rebuild_texture_array()`
- `is_solid()`, `get_tile_name()`, `get_tile_color()`, `get_tile_ids()`, `get_tile_count()`
- `get_tile_def()`, `get_tile_property()`, `get_friction()`, `get_damage()`, `get_transparency()`, `get_hardness()`
- `get_texture_array()`

**ChunkManager** — Chunk lifecycle + terrain queries:

- `world_to_chunk_pos()`, `world_to_tile_pos()` — coordinate conversion
- `get_chunk_at()`, `is_solid_at_world_pos()` — queries
- `get_tile_at_world_pos()`, `get_tiles_at_world_positions()` — tile reads
- `set_tiles_at_world_positions()` — terrain editing
- `setup_persistence()`, `save_world()`, `load_chunk_data()`, `has_saved_chunk()` — persistence
- `get_terrain_generator()`, `get_debug_info()` — introspection

**EntityManager** — Entity lifecycle:

- `spawn(entity) -> int`, `despawn(id)`, `get_entity(id)`, `get_entity_count()`

**BaseEntity** — Entity base class (virtual methods for override):

- `_entity_update(delta)`, `_get_movement_input() -> Vector2`
- `setup_movement(collision_detector)` — composition helper

**SignalBus** — 9 global signals:

- `player_chunk_changed`, `tile_changed`, `chunk_loaded`, `chunk_unloaded`
- `world_ready`, `world_saving`, `world_saved`
- `entity_spawned`, `entity_despawned`

### Internal (prefixed `_`, not for external use)

All `ChunkLoader` internals, `Chunk._terrain_data/image/texture`, `ChunkManager._chunk_loader/_chunks/_chunk_pool`, `GUIManager._current_brush_*`, `Player._movement`.

Note: `brush_preview.gd` and `debug_hud.gd` both violate encapsulation by accessing private fields on `GUIManager` and `Player` respectively.

### Extension Patterns

| Class                  | Pattern     | Notes                                                |
| ---------------------- | ----------- | ---------------------------------------------------- |
| `BaseTerrainGenerator` | Inheritance | Override `generate_chunk()`                          |
| `BaseEntity`           | Inheritance | Override `_entity_update()`, `_get_movement_input()` |
| `MovementController`   | Composition | RefCounted, injected into entities                   |
| `CollisionDetector`    | Composition | RefCounted, injected into MovementController         |
| `WorldSaveManager`     | Standalone  | RefCounted, no scene coupling                        |

---

## 7. Configuration and Constants

### GlobalSettings (all used, all `const`)

| Constant                          | Value | Used By                                                                             |
| --------------------------------- | ----- | ----------------------------------------------------------------------------------- |
| `CHUNK_SIZE`                      | 32    | chunk, chunk_loader, chunk_manager, simplex_generator, debug_overlay, player, tests |
| `REGION_SIZE`                     | 4     | chunk_manager (6x), debug_overlay (2x), tests                                       |
| `LOD_RADIUS`                      | 4     | chunk_manager (2x)                                                                  |
| `REMOVAL_BUFFER`                  | 2     | chunk_manager                                                                       |
| `MAX_CHUNK_BUILDS_PER_FRAME`      | 16    | chunk_manager                                                                       |
| `MAX_CHUNK_REMOVALS_PER_FRAME`    | 32    | chunk_manager                                                                       |
| `MAX_BUILD_QUEUE_SIZE`            | 128   | chunk_loader (2x)                                                                   |
| `MAX_CHUNK_POOL_SIZE`             | 512   | chunk_manager (2x)                                                                  |
| `MAX_CONCURRENT_GENERATION_TASKS` | 8     | chunk_loader                                                                        |

### Hardcoded Values That Should Be Configurable

| Location                   | Value              | Description                                 |
| -------------------------- | ------------------ | ------------------------------------------- |
| `chunk_manager.gd:197`     | `4`                | Distance threshold for queue re-sort        |
| `chunk_loader.gd:71`       | `/ 2.0`            | Backpressure resume at 50%                  |
| `gui_manager.gd:102`       | `64`               | Max brush size                              |
| `gui_manager.gd:11`        | `2`                | Default brush size                          |
| `chunk_manager.gd:9`       | `% 1000000`        | Seed space limited to 1M values             |
| `world_save_manager.gd:18` | `"user://worlds/"` | Save path                                   |
| `chunk.tscn:9`             | `Vector2(32, 32)`  | Shader texture_size (must match CHUNK_SIZE) |

### Tile Properties (registered but unused)

| Property       | Default | Used By                                    |
| -------------- | ------- | ------------------------------------------ |
| `friction`     | 1.0     | Nothing — movement system ignores it       |
| `damage`       | 0.0     | Nothing                                    |
| `transparency` | 1.0     | Nothing — shader has its own discard logic |
| `hardness`     | 1       | Nothing — editing ignores it               |

### SimplexTerrainGenerator Config (all properly configurable via dict)

`heightmap_frequency=0.002`, `detail_frequency=0.008`, `layer_frequency=0.006`, `surface_level=0.0`, `heightmap_amplitude=96.0`, `detail_amplitude=20.0`, `grass_depth=4`, `dirt_depth=20`, `layer_variation=12.0`, `cliff_threshold=1.5`

---

## 8. Architecture Strengths

1. **Threading model is sound.** Producer-consumer with mutex-protected queues, backpressure, and WorkerThreadPool correctly respects Godot's threading rules (no scene API in workers).

2. **Chunk pooling works well.** `reset()` / `generate()` / `build()` lifecycle prevents per-frame allocation overhead.

3. **TileIndex is genuinely data-driven.** Defaults-merge pattern for properties, dynamic Texture2DArray construction, toolbar auto-generation from registry.

4. **Signal bus decouples cleanly.** Systems that shouldn't know about each other (Player ↔ ChunkManager, ChunkManager ↔ save system) communicate through typed signals.

5. **MovementController is properly composed.** RefCounted with no scene tree coupling — genuinely reusable.

6. **WorldSaveManager is clean.** Pure file I/O, no scene coupling, clear error handling, good path helpers.

7. **Swept AABB collision is correct.** X-then-Y sweep with proper normal calculation, no Godot physics dependency.

---

## 9. Architecture Issues

### P0 — Critical

**Persistence is write-only.** `ChunkLoader` never calls `ChunkManager.load_chunk_data()` or `has_saved_chunk()`. All terrain edits are saved to disk but never loaded. Every game start regenerates fresh terrain.

### P1 — High

**Input action key collisions.** `project.godot` maps F1-F4 each to TWO different input actions (e.g., `toggle_controls_help` and `debug_toggle_all` both on F1). Both handlers fire simultaneously.

**SimplexTerrainGenerator accesses autoloads from worker thread.** `TileIndex.AIR/DIRT/GRASS/STONE` and `GlobalSettings.CHUNK_SIZE` are read from worker threads. Safe today (const values), but violates the documented constraint and couples the generator to the tile registry.

**Player bypasses BaseEntity.** `Player` extends `CharacterBody2D`, not `BaseEntity`. It is not managed by `EntityManager`, has no `entity_id`, and is invisible to the entity system. `CharacterBody2D` features (physics body, `move_and_slide()`) are entirely unused.

**ChunkManager hardcodes SimplexTerrainGenerator.** Line 35: `SimplexTerrainGenerator.new(world_seed)`. Despite `BaseTerrainGenerator` existing as an abstraction, there's no way to substitute a generator without editing engine source.

**BrushPreview accesses GUIManager private fields.** Reads `_current_brush_size`, `_current_brush_type` via `get_meta()` — breaks encapsulation.

**DebugHUD accesses Player.\_movement.** Private field access from external script.

### P2 — Medium

**`stop()` busy-waits on main thread.** No timeout on the `OS.delay_msec(1)` loop — hangs if a generator loops infinitely.

**Pool size insufficient.** `MAX_CHUNK_POOL_SIZE=512` but max loaded chunks = `(2*LOD_RADIUS+1)^2 * REGION_SIZE^2 = 1,296`. Pool misses cause runtime instantiation, defeating its purpose.

**Chunk pool pre-population blocks `_ready()`.** 512 synchronous `instantiate()` calls with `local_to_scene` ShaderMaterial — significant startup hitch.

**Save format version never validated on load.** `SAVE_FORMAT_VERSION` is written but never checked, so format changes silently corrupt loaded data.

**Shader `texture_size` hardcoded.** `chunk.tscn` has `texture_size = Vector2(32, 32)` — no runtime link to `CHUNK_SIZE`. Changing chunk size requires manually updating the scene file.

**Duplicate brush constants.** `BRUSH_SQUARE=0, BRUSH_CIRCLE=1` defined identically in both `gui_manager.gd` and `editing_toolbar.gd`.

### P3 — Low

**`EntityManager._entities.values()` allocates each frame.** Creates a new Array every `_physics_process`. Minor now, scales poorly.

**Ghost texture imports.** `assets/textures/` has `.import` files for 12 textures (flowers, gravel, coal_ore, etc.) with no corresponding source `.png` files.

**`test_runner.gd` accesses `TileIndex._tiles` directly.** No `unregister_tile()` method exists for test cleanup.

**Camera zoom init redundancy.** `_current_preset_index = 2` and `zoom = Vector2(4, 4)` set the same thing twice in `_ready()`.
