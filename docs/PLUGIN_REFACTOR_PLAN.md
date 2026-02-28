# Substrata Plugin Refactor Plan

Blueprint for converting Substrata from a standalone game into a reusable Godot 4.6 addon/plugin. Target audience: Godot-savvy developers building 2D voxel games. Generated February 2026.

---

## Table of Contents

1. [Engine vs Game Code Classification](#1-engine-vs-game-code-classification)
2. [Target Plugin Architecture](#2-target-plugin-architecture)
3. [Public API Design](#3-public-api-design)
4. [Autoload Elimination Strategy](#4-autoload-elimination-strategy)
5. [Modular Boundaries](#5-modular-boundaries)
6. [Breaking Changes and Migration](#6-breaking-changes-and-migration)
7. [Example/Demo Structure](#7-exampledemo-structure)
8. [Critical Implementation Details](#8-critical-implementation-details)
9. [Phased Work Breakdown](#9-phased-work-breakdown)

---

## 1. Engine vs Game Code Classification

### Engine Code (moves to `addons/substrata/`)

| File                                                | Purpose                                  |
| --------------------------------------------------- | ---------------------------------------- |
| `src/world/chunks/chunk.gd`                         | Rendering/data primitive                 |
| `src/world/chunks/chunk.tscn`                       | Chunk scene with shader material         |
| `src/world/chunks/chunk_loader.gd`                  | Threaded generation scheduler            |
| `src/world/chunks/chunk_manager.gd`                 | Chunk lifecycle orchestrator             |
| `src/world/chunks/terrain.gdshader`                 | Tile-array rendering shader              |
| `src/world/generators/base_terrain_generator.gd`    | Generator interface                      |
| `src/world/generators/simplex_terrain_generator.gd` | Reference implementation                 |
| `src/world/persistence/world_save_manager.gd`       | File-based persistence                   |
| `src/physics/collision_detector.gd`                 | Swept AABB collision                     |
| `src/physics/movement_controller.gd`                | Reusable physics controller              |
| `src/globals/signal_bus.gd`                         | Event bus (becomes internal)             |
| `src/globals/global_settings.gd`                    | Constants (becomes WorldConfig resource) |
| `src/globals/tile_index.gd`                         | Tile registry (becomes TileRegistry)     |
| `src/globals/game_services.gd`                      | Service locator (eliminated)             |
| `src/camera/camera_controller.gd`                   | Follow camera                            |
| `src/entities/base_entity.gd`                       | Entity base class                        |
| `src/entities/entity_manager.gd`                    | Entity lifecycle manager                 |
| `src/gui/chunk_debug_overlay.gd`                    | Debug visualization                      |

### Game/Demo Code (moves to `example/`)

| File                          | Reason                   |
| ----------------------------- | ------------------------ |
| `src/game/game_instance.gd`   | Demo-specific wiring     |
| `src/game/game_instance.tscn` | Demo scene               |
| `src/entities/player.gd`      | Hardcoded input actions  |
| `src/entities/player.tscn`    | Demo asset               |
| `src/gui/gui_manager.gd`      | Demo editing UI          |
| `src/gui/editing_toolbar.gd`  | Demo tile picker         |
| `src/gui/debug_hud.gd`        | Accesses Player privates |
| `src/gui/cursor_info.gd`      | Demo cursor info         |
| `src/gui/controls_overlay.gd` | Hardcoded help text      |
| `src/gui/brush_preview.gd`    | Demo brush outline       |

### Hardcoded Assumptions That Break Reusability

| Location                               | Assumption                                       | Impact                                            |
| -------------------------------------- | ------------------------------------------------ | ------------------------------------------------- |
| `simplex_terrain_generator.gd:119-136` | `TileIndex.AIR/DIRT/GRASS/STONE`                 | Breaks with different tile ID scheme              |
| `chunk.gd:65-67`                       | `TileIndex.get_texture_array()`                  | Prevents multiple worlds with different tile sets |
| `chunk_manager.gd:35`                  | `SimplexTerrainGenerator.new(world_seed)`        | Can't swap generators without forking             |
| `camera_controller.gd:35`              | Node name `"Player"`                             | Camera breaks if player named differently         |
| `gui_manager.gd:129`                   | `load("res://src/gui/brush_preview.gd")`         | Breaks when moved to addons/                      |
| `world_save_manager.gd:18`             | `"user://worlds/"`                               | Users can't redirect saves                        |
| `chunk_manager.gd:434`                 | Generator name `"simplex"` hardcoded in metadata | Wrong for custom generators                       |
| `project.godot`                        | Input actions `move_left`, `jump`, etc.          | Conflicts with user's game input map              |
| `global_settings.gd`                   | All values are `const`                           | Users can't configure without editing source      |
| `chunk.tscn:9`                         | `texture_size = Vector2(32, 32)`                 | Must match CHUNK_SIZE but no runtime link         |

---

## 2. Target Plugin Architecture

### Directory Layout

```text
addons/
└── substrata/
    ├── plugin.cfg
    ├── plugin.gd                          # EditorPlugin entry point
    │
    ├── core/
    │   ├── world_config.gd                # Resource: replaces GlobalSettings
    │   ├── substrata_world.gd             # Main runtime node (entry point for users)
    │   ├── substrata_world.tscn           # Pre-assembled scene for drag-drop
    │   └── _substrata_signals.gd          # Internal signal bus (not public API)
    │
    ├── chunks/
    │   ├── chunk.gd
    │   ├── chunk.tscn
    │   ├── chunk_loader.gd
    │   ├── chunk_manager.gd
    │   └── terrain.gdshader
    │
    ├── tiles/
    │   ├── tile_registry.gd               # Renamed from TileIndex
    │   └── tile_definition.gd             # Resource type for tile data (future)
    │
    ├── generators/
    │   ├── base_terrain_generator.gd
    │   └── simplex_terrain_generator.gd
    │
    ├── physics/
    │   ├── collision_detector.gd
    │   └── movement_controller.gd
    │
    ├── entities/
    │   ├── base_entity.gd
    │   └── entity_manager.gd
    │
    ├── persistence/
    │   └── world_save_manager.gd
    │
    ├── camera/
    │   └── substrata_camera.gd            # Renamed from camera_controller
    │
    └── debug/
        ├── chunk_debug_overlay.gd
        └── substrata_debug_hud.gd         # Rewritten without Player coupling

example/                                   # Demo project
├── example_game.tscn
├── example_game.gd
├── tiles/
│   └── tile_setup.gd                      # Demo tile registration
├── player/
│   ├── example_player.gd
│   └── example_player.tscn
├── gui/
│   ├── example_gui_manager.gd
│   ├── editing_toolbar.gd
│   ├── cursor_info.gd
│   ├── controls_overlay.gd
│   └── brush_preview.gd
└── assets/
    └── textures/
```

### `plugin.cfg`

```ini
[plugin]
name="Substrata 2D Voxel Engine"
description="Chunk-based 2D voxel terrain with multithreaded streaming, swept AABB physics, and a data-driven tile registry."
author="Substrata Team"
version="1.0.0"
script="plugin.gd"
```

### `plugin.gd` Responsibilities

1. Register `SubstrataWorld` as custom type (appears in Add Node dialog)
2. Register `WorldConfig` as custom Resource type
3. Register `SubstrataCamera` as custom type
4. Add Substrata menu item for documentation access

Does NOT manage autoloads. The plugin avoids `add_autoload_singleton()` to prevent forcing global state on users. `SubstrataWorld._ready()` is the initialization boundary.

---

## 3. Public API Design

### WorldConfig Resource (replaces GlobalSettings)

```gdscript
class_name WorldConfig extends Resource

@export_group("Chunks")
@export var chunk_size: int = 32
@export var region_size: int = 4
@export var lod_radius: int = 4
@export var removal_buffer: int = 2

@export_group("Performance")
@export var max_chunk_builds_per_frame: int = 16
@export var max_chunk_removals_per_frame: int = 32
@export var max_build_queue_size: int = 128
@export var max_chunk_pool_size: int = 512
@export var max_concurrent_generation_tasks: int = 8

@export_group("Persistence")
@export var save_base_path: String = "user://worlds/"
@export var world_name: String = "default"
@export var enable_auto_save: bool = true
```

Serializes to `.tres`, can be shared across scenes, supports multiple worlds with different configs.

### SubstrataWorld Node (main entry point)

```gdscript
class_name SubstrataWorld extends Node

# Public signals (replaces SignalBus for external consumers)
signal world_ready()
signal chunk_loaded(chunk_pos: Vector2i)
signal chunk_unloaded(chunk_pos: Vector2i)
signal tile_changed(world_pos: Vector2, old_id: int, new_id: int)

@export var config: WorldConfig
@export var enable_persistence: bool = true

# Public references (replaces GameServices)
var chunk_manager: ChunkManager
var tile_registry: TileRegistry
var entity_manager: EntityManager
var save_manager: WorldSaveManager

# Lifecycle
func activate(generator: BaseTerrainGenerator = null) -> void
func save() -> void

# Queries
func get_tile_at(world_pos: Vector2) -> Array     # [tile_id, cell_id]
func set_tiles(changes: Array) -> void
func is_solid_at(world_pos: Vector2) -> bool
func world_to_chunk(world_pos: Vector2) -> Vector2i
func world_to_tile(world_pos: Vector2) -> Vector2i
```

Users access subsystems through this node instead of a global singleton:

```gdscript
# Before (autoload):
GameServices.chunk_manager.get_tile_at_world_pos(pos)
# After (node reference):
$SubstrataWorld.get_tile_at(pos)
```

### TileRegistry (renamed from TileIndex)

```gdscript
class_name TileRegistry extends Node

func register_tile(id: int, name: String, solid: bool, texture_path: String,
                   color: Color = Color.WHITE, properties: Dictionary = {}) -> void
func rebuild_texture_array() -> void
func get_texture_array() -> Texture2DArray
func is_solid(tile_id: int) -> bool
func get_tile_name(tile_id: int) -> String
func get_tile_color(tile_id: int) -> Color
func get_tile_ids() -> Array
func get_tile_count() -> int
func get_tile_def(tile_id: int) -> Dictionary
func get_tile_property(tile_id: int, property_name: String) -> Variant
func get_friction(tile_id: int) -> float
func get_damage(tile_id: int) -> float
func get_transparency(tile_id: int) -> float
func get_hardness(tile_id: int) -> int
func get_tile_id_by_name(name: String) -> int    # NEW: for generator decoupling
```

No built-in tiles registered by default. Plugin users call `register_tile()` before `world.activate()`.

### BaseTerrainGenerator (updated interface)

```gdscript
class_name BaseTerrainGenerator extends RefCounted

# NEW: called by ChunkManager before any generation begins
func configure(chunk_size: int, tile_registry: TileRegistry) -> void:
    _chunk_size = chunk_size
    _tile_registry = tile_registry

func generate_chunk(chunk_pos: Vector2i) -> PackedByteArray
func get_generator_name() -> String
```

`SimplexTerrainGenerator` caches tile IDs in `configure()` via `_tile_registry.get_tile_id_by_name()` instead of accessing `TileIndex` autoload constants.

### SubstrataCamera (replaces CameraController)

```gdscript
class_name SubstrataCamera extends Camera2D

@export var smoothing: float = 10.0
@export var zoom_presets: Array[float] = [1.0, 2.0, 4.0, 8.0]
@export var zoom_step: float = 0.1
@export var min_zoom: Vector2 = Vector2(0.5, 0.5)
@export var max_zoom: Vector2 = Vector2(10.0, 10.0)
@export var target_path: NodePath  # Set in inspector, replaces hardcoded "Player"

func set_target(node: Node2D) -> void  # OR set at runtime
```

### Physics (unchanged API)

Both `CollisionDetector` and `MovementController` are already well-encapsulated `RefCounted` objects with constructor injection. Only change: `CollisionDetector._init(chunk_manager)` receives reference from `SubstrataWorld` instead of `GameServices`.

### Entity System (unchanged API)

```gdscript
world.entity_manager.spawn(entity)   # -> int entity_id
world.entity_manager.despawn(id)
world.entity_manager.get_entity(id)  # -> BaseEntity
```

`EntityManager` emits signals directly instead of through `SignalBus`:

```gdscript
world.entity_manager.entity_spawned.connect(_on_spawn)
```

---

## 4. Autoload Elimination Strategy

| Current Autoload | Target                         | Action                                     |
| ---------------- | ------------------------------ | ------------------------------------------ |
| `GameServices`   | Eliminated                     | Replaced by properties on `SubstrataWorld` |
| `GlobalSettings` | `WorldConfig` Resource         | Inspector-editable, per-world config       |
| `TileIndex`      | `TileRegistry` instance        | Created by `SubstrataWorld`, not global    |
| `SignalBus`      | `_SubstrataSignals` (internal) | Private, not exposed in public API         |

### SignalBus → Direct Signals

External consumers connect to `SubstrataWorld` signals directly:

```gdscript
$SubstrataWorld.world_ready.connect(_on_world_ready)
$SubstrataWorld.chunk_loaded.connect(_on_chunk_loaded)
$SubstrataWorld.tile_changed.connect(_on_tile_changed)
```

`_SubstrataSignals` remains as an internal convenience for intra-plugin communication (e.g., ChunkManager notifying SubstrataWorld) without circular references.

---

## 5. Modular Boundaries

### Core (required)

**Files:** chunk.gd, chunk.tscn, chunk_loader.gd, chunk_manager.gd, terrain.gdshader, tile_registry.gd, world_config.gd, substrata_world.gd
**Dependencies:** None outside module
**Interface:** `SubstrataWorld`, `WorldConfig`, `TileRegistry`, chunk queries and editing

### Terrain Generation (required interface, optional implementations)

**Files:** base_terrain_generator.gd (required), simplex_terrain_generator.gd (optional)
**Dependencies:** Core (chunk_size from config, TileRegistry for IDs)
**Interface:** `BaseTerrainGenerator.generate_chunk()` + `configure()`

### Physics/Collision (optional)

**Files:** collision_detector.gd, movement_controller.gd
**Dependencies:** Core (ChunkManager reference for `is_solid_at_world_pos`)
**Use case:** Not needed for top-down games using Godot's built-in physics
**Interface:** `CollisionDetector.sweep_aabb()`, `MovementController.move()`

### Entity System (optional)

**Files:** base_entity.gd, entity_manager.gd
**Dependencies:** Core (signals), Physics (optional composition)
**Interface:** `EntityManager.spawn()`, `despawn()`, `BaseEntity` base class

### Persistence (optional)

**Files:** world_save_manager.gd
**Dependencies:** Core (chunk terrain data)
**Interface:** `save_chunk()`, `load_chunk()`, `save_world_meta()`, `list_worlds()`, `delete_world()`

### Camera (optional)

**Files:** substrata_camera.gd
**Dependencies:** None (pure Camera2D subclass)
**Interface:** `set_target(node)`, exported properties

### Debug Tools (optional, strip for production)

**Files:** chunk_debug_overlay.gd, substrata_debug_hud.gd
**Dependencies:** Core (ChunkManager debug info)
**Interface:** Add as child node, works automatically

---

## 6. Breaking Changes and Migration

### Migration Table

| Old Pattern                                             | New Pattern                                                  |
| ------------------------------------------------------- | ------------------------------------------------------------ |
| `GameServices.chunk_manager.get_tile_at_world_pos(pos)` | `$SubstrataWorld.get_tile_at(pos)`                           |
| `GlobalSettings.CHUNK_SIZE`                             | `$SubstrataWorld.config.chunk_size`                          |
| `TileIndex.is_solid(id)`                                | `$SubstrataWorld.tile_registry.is_solid(id)`                 |
| `TileIndex.register_tile(...)`                          | `tile_registry.register_tile(...)` before `world.activate()` |
| `SignalBus.tile_changed.connect(f)`                     | `$SubstrataWorld.tile_changed.connect(f)`                    |
| `SignalBus.world_ready.connect(f)`                      | `$SubstrataWorld.world_ready.connect(f)`                     |

### Dependency Injection Pattern

```gdscript
# OLD: Global autoload access
func _ready():
    return TileIndex.is_solid(chunk.get_tile_id_at(x, y))

# NEW: Constructor injection
func _init(config: WorldConfig, tile_registry: TileRegistry):
    _config = config
    _tile_registry = tile_registry

func check_solid(x, y):
    return _tile_registry.is_solid(chunk.get_tile_id_at(x, y))
```

### Scene-Based vs Code-Based Init

**Scene-based (recommended):**

```text
GameScene (Node)
├── SubstrataWorld (Node)         ← drag from Add Node dialog
│   (config assigned in Inspector)
├── MyPlayer (CharacterBody2D)
└── SubstrataCamera (Camera2D)
    target_path: ../MyPlayer
```

**Code-based:**

```gdscript
func _ready():
    var world = SubstrataWorld.new()
    var config = WorldConfig.new()
    config.chunk_size = 32
    world.config = config
    add_child(world)
    world.activate(MyGenerator.new())
```

---

## 7. Example/Demo Structure

### Example Scene Tree

```text
ExampleGame (Node)
├── SubstrataWorld (Node)              ← plugin node
│   config: res://example/world_config.tres
├── ExamplePlayer (CharacterBody2D)
├── SubstrataCamera (Camera2D)         ← plugin node
│   target_path: ../ExamplePlayer
├── ChunkDebugOverlay (Node2D)
└── UILayer (CanvasLayer)
    └── ExampleGUIManager (Control)
```

### Example Game Script (demonstrates plugin API)

```gdscript
extends Node

@onready var world: SubstrataWorld = $SubstrataWorld
@onready var player = $ExamplePlayer

func _ready() -> void:
    # 1. Register tiles before activation
    world.tile_registry.register_tile(0, "Air", false, "", Color(0.7, 0.8, 0.9, 0.5))
    world.tile_registry.register_tile(1, "Dirt", true, "res://example/assets/dirt.png", Color(0.55, 0.35, 0.2))
    world.tile_registry.register_tile(2, "Grass", true, "res://example/assets/grass.png", Color(0.3, 0.7, 0.2))
    world.tile_registry.register_tile(3, "Stone", true, "res://example/assets/stone.png", Color(0.5, 0.5, 0.5), {"hardness": 3})
    world.tile_registry.rebuild_texture_array()

    # 2. Give player a world reference for collision
    player.set_world(world)

    # 3. Activate
    world.activate(SimplexTerrainGenerator.new(randi()))
    world.world_ready.connect(func(): print("World loaded"))
```

---

## 8. Critical Implementation Details

### Every Autoload Reference to Replace

**GlobalSettings → `_config.*`** (30+ references across 7 files):

- `chunk.gd` — lines 24, 32, 81, 87, 104, 130-137, 150-157, 178-179
- `chunk_loader.gd` — lines 71, 139, 195, 209
- `chunk_manager.gd` — lines 39, 60, 106, 118-134, 168-176, 224-232, 248, 266
- `simplex_terrain_generator.gd` — line 81
- `chunk_debug_overlay.gd` — lines 44-45, 64, 69, 73, 83

**TileIndex → `_tile_registry.*`** (8 references across 3 files):

- `chunk.gd` — lines 65-67
- `simplex_terrain_generator.gd` — lines 119, 125, 128, 131, 133, 136
- `chunk_manager.gd` — line 291

**GameServices → eliminated** (5 references across 5 files):

- `player.gd` — line 38
- `gui_manager.gd` — line 164
- `chunk_debug_overlay.gd` — line 27
- `cursor_info.gd` — line 36
- `debug_hud.gd` — line 45

**SignalBus → `_SubstrataSignals` / direct signals** (11 references across 3 files):

- `chunk_manager.gd` — lines 45, 88, 99, 159, 381, 426, 437
- `entity_manager.gd` — lines 28, 38
- `player.gd` — line 60

### Shader `texture_size` Must Become Dynamic

`chunk.tscn` has `shader_parameter/texture_size = Vector2(32, 32)`. When `chunk_size` becomes configurable:

```gdscript
# In Chunk._ready() or configure():
_visual_mesh.material.set_shader_parameter("texture_size", Vector2(chunk_size, chunk_size))
```

### Generator Thread Safety

`BaseTerrainGenerator.configure(chunk_size, tile_registry)` must be called before `ChunkLoader` starts submitting tasks. The init sequence:

```text
SubstrataWorld.activate(generator) →
  generator.configure(config.chunk_size, tile_registry) →
  ChunkLoader.new(generator) →
  ChunkLoader starts submitting
```

If `configure()` is called after ChunkLoader starts, there is a race condition.

### Y-Inversion Invariant

**Do not modify.** `chunk_loader.gd`'s `_generate_visual_image()` and `chunk.gd`'s `edit_tiles()` both apply `effective_y = (chunk_size - 1) - y`. Any refactor moving these methods must preserve this calculation at exactly the same pipeline stages.

### SimplexTerrainGenerator Tile ID Caching

After injection, tile IDs should be cached by name in `configure()`:

```gdscript
func configure(chunk_size: int, tile_registry: TileRegistry) -> void:
    _chunk_size = chunk_size
    _tile_registry = tile_registry
    _air_id = tile_registry.get_tile_id_by_name("Air")
    _dirt_id = tile_registry.get_tile_id_by_name("Dirt")
    _grass_id = tile_registry.get_tile_id_by_name("Grass")
    _stone_id = tile_registry.get_tile_id_by_name("Stone")
```

Requires `get_tile_id_by_name()` to be added to `TileRegistry`. Documents that `SimplexTerrainGenerator` expects tiles named "Air", "Dirt", "Grass", "Stone" to exist.

---

## 9. Phased Work Breakdown

### Phase 1: Core Restructuring (Foundation)

| Task                                                     | Size | Details                                                        |
| -------------------------------------------------------- | ---- | -------------------------------------------------------------- |
| Create `addons/substrata/` directory + `plugin.cfg`      | S    | Scaffolding                                                    |
| Write `plugin.gd` with custom type registration          | S    | Register SubstrataWorld, WorldConfig, SubstrataCamera          |
| Create `WorldConfig` resource class                      | S    | Port GlobalSettings constants to `@export` vars                |
| Create `TileRegistry` (decouple from TileIndex autoload) | M    | Add `class_name`, remove autoload, add `get_tile_id_by_name()` |
| Move engine files to `addons/substrata/` subdirs         | S    | Update UIDs in .tscn files                                     |
| Remove old autoloads from `project.godot`                | S    | Delete 4 autoload lines                                        |

### Phase 2: Dependency Injection Refactor

| Task                                                       | Size | Details                                                                  |
| ---------------------------------------------------------- | ---- | ------------------------------------------------------------------------ |
| Refactor `BaseTerrainGenerator` — add `configure()`        | S    | Add `_chunk_size` and `_tile_registry` vars                              |
| Refactor `SimplexTerrainGenerator` — use injected registry | M    | Replace 6 `TileIndex.*` calls, cache IDs by name                         |
| Refactor `ChunkLoader` — use WorldConfig                   | M    | Replace 4 GlobalSettings references                                      |
| Refactor `Chunk` — accept TileRegistry reference           | M    | Replace GlobalSettings.CHUNK_SIZE (10 refs) + TileIndex (2 refs)         |
| Refactor `ChunkManager` — full injection                   | L    | Replace GlobalSettings (15+ refs), TileIndex, remove hardcoded generator |
| Refactor `WorldSaveManager` — configurable save path       | S    | Constructor param instead of const                                       |
| Refactor `EntityManager` — emit own signals                | M    | Add signals directly, remove SignalBus calls                             |

### Phase 3: SubstrataWorld Node

| Task                                  | Size | Details                                                           |
| ------------------------------------- | ---- | ----------------------------------------------------------------- |
| Write `SubstrataWorld` class          | L    | Owns all subsystems, public API surface                           |
| Implement init sequence in `_ready()` | M    | Instantiate registry, chunk_manager, entity_manager, save_manager |
| Implement `activate(generator)`       | M    | Wire generator, start world                                       |
| Build `substrata_world.tscn`          | S    | Default config embedded                                           |
| Implement signal forwarding           | S    | Forward chunk_loaded, tile_changed, etc.                          |

### Phase 4: Camera and Debug Decoupling

| Task                                                 | Size | Details                                                         |
| ---------------------------------------------------- | ---- | --------------------------------------------------------------- |
| Refactor CameraController → SubstrataCamera          | S    | `@export var target_path: NodePath` replaces hardcoded "Player" |
| Rewrite debug HUD without Player coupling            | M    | Duck typing or interface instead of `_movement`                 |
| Refactor ChunkDebugOverlay to use SubstrataWorld ref | S    | Replace GameServices dependency                                 |

### Phase 5: Demo Restructuring

| Task                                       | Size | Details                                 |
| ------------------------------------------ | ---- | --------------------------------------- |
| Create `example/`, move demo files         | M    | game_instance, player, GUI files        |
| Rewrite `example_game.gd` using plugin API | M    | Remove GameServices, use SubstrataWorld |
| Rewrite `example_player.gd`                | M    | `set_world(world)` pattern              |
| Update GUI files — remove autoload deps    | M    | Replace 6+ autoload references          |
| Move demo assets, update paths             | S    | Update texture paths in .tscn files     |

### Phase 6: Documentation and Tests

| Task                                             | Size | Details                                             |
| ------------------------------------------------ | ---- | --------------------------------------------------- |
| Write plugin README with quickstart              | M    | Install, setup, tile registration, custom generator |
| Update ENGINE_ARCHITECTURE.md                    | M    | Reflect new plugin structure                        |
| Port test_runner.gd to work without autoloads    | L    | Instantiate SubstrataWorld inline                   |
| Add integration tests for CollisionDetector      | M    | Test sweep_aabb correctness                         |
| Add integration tests for ChunkManager lifecycle | M    | Test pool, generation, removal                      |

### Phase 7: Polish and Packaging

| Task                                      | Size | Details                                               |
| ----------------------------------------- | ---- | ----------------------------------------------------- |
| Create plugin icon (16x16 SVG)            | S    | For Add Node dialog                                   |
| Audit all `res://src/` paths              | S    | Grep, fix any remaining hardcoded paths               |
| Verify UID references after file moves    | M    | .tscn import paths                                    |
| Test fresh install on blank Godot project | L    | End-to-end: enable plugin → add node → generate world |

### Summary

| Phase                         | Scope | Estimated Effort |
| ----------------------------- | ----- | ---------------- |
| Phase 1: Core Restructuring   | S-M   | Small            |
| Phase 2: Dependency Injection | M-L   | Medium-Large     |
| Phase 3: SubstrataWorld Node  | M-L   | Medium           |
| Phase 4: Camera + Debug       | S-M   | Small            |
| Phase 5: Demo Restructuring   | M     | Medium           |
| Phase 6: Docs + Tests         | M-L   | Medium           |
| Phase 7: Polish               | S-M   | Small            |

---

## Appendix: Bug Fixes to Complete Before Plugin Release

These issues from the Code Quality Review should be fixed during or before the refactor:

1. **Implement chunk loading from saved data** (P0) — persistence is currently write-only
2. **Fix `stop()` busy-wait** (CRIT-1) — add timeout, document main-thread stall
3. **Fix path separator in `_delete_directory_contents`** (CRIT-2) — use `path_join()`
4. **Fix camera smoothing formula** (HIGH-3) — remove `* 60.0`
5. **Fix `world_ready` premature firing** (HIGH-1) — track initial chunk count
6. **Fix input action key collisions** (P1) — deduplicate F1-F4 mappings
7. **Change Player to extend Node2D or BaseEntity** (HIGH-2) — remove unused CharacterBody2D
8. **Cache autoload values in SimplexTerrainGenerator** (MED-3) — thread safety
9. **Validate chunk data size on load** (MED-4) — robustness
10. **Fix deprecated `emit_signal()` call** (MED-1) — use typed `.emit()`
