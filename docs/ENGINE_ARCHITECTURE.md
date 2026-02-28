# Substrata Engine Architecture

## Overview

Substrata is a 2D voxel engine built in Godot 4.6 (GDScript). It provides procedurally generated, editable terrain with multithreaded chunk streaming. This document describes the engine's architecture, data flow, and extension points.

## Directory Structure

```text
src/
├── camera/
│   └── camera_controller.gd  # Smooth-follow camera with zoom presets
├── entities/
│   ├── base_entity.gd        # Base entity class (velocity, collision, MovementController)
│   ├── entity_manager.gd     # Entity lifecycle: spawn/despawn, ID assignment
│   ├── player.gd             # Input handling, delegates to MovementController
│   └── player.tscn
├── game/
│   ├── game_instance.gd   # Root orchestrator, registers services
│   └── game_instance.tscn # Main scene
├── globals/
│   ├── game_services.gd   # Service locator (autoload)
│   ├── global_settings.gd # Engine constants (autoload)
│   ├── signal_bus.gd      # Global event bus (autoload)
│   └── tile_index.gd      # Tile registry with Texture2DArray (autoload)
├── gui/
│   ├── brush_preview.gd   # World-space brush outline
│   ├── chunk_debug_overlay.gd  # F4 debug visualization
│   ├── controls_overlay.gd     # F1 help screen
│   ├── cursor_info.gd          # F2 tile info under cursor
│   ├── debug_hud.gd            # F3 performance HUD
│   ├── editing_toolbar.gd      # Material/brush UI (dynamic from registry)
│   └── gui_manager.gd          # Main GUI orchestrator
├── physics/
│   ├── collision_detector.gd   # Swept AABB vs tile grid
│   └── movement_controller.gd  # Reusable physics controller
└── world/
    ├── chunks/
    │   ├── chunk.gd            # Individual chunk (data + rendering)
    │   ├── chunk.tscn          # Chunk scene template
    │   ├── chunk_loader.gd     # Background generation scheduler
    │   ├── chunk_manager.gd    # Chunk lifecycle orchestrator
    │   └── terrain.gdshader    # Fragment shader (Texture2DArray)
    └── generators/
        ├── base_terrain_generator.gd    # Abstract generator interface
        └── simplex_terrain_generator.gd # Simplex noise implementation
```

## Scene Tree

```text
GameInstance (Node)
├── Player (CharacterBody2D)
│   └── Sprite2D
├── CameraController (Camera2D)
├── ChunkManager (Node2D)
│   └── [Chunk instances...]
├── EntityManager (Node)
│   └── [BaseEntity instances...]
├── ChunkDebugOverlay (Node2D)    — debug visualization (F4-F10 sub-toggles)
└── UILayer (CanvasLayer)
    └── GUIManager (Control)
```

`GameInstance._ready()` registers all services with `GameServices`: `chunk_manager`, `entity_manager`, `tile_registry`, `terrain_generator`, `world_save_manager`. All other systems access them lazily through the service locator.

## Autoloads

| Name           | File                 | Purpose                                                                                                                                                            |
| -------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| SignalBus      | `signal_bus.gd`      | Global event bus. Signals include `player_chunk_changed`, `tile_changed`, `chunk_loaded`/`unloaded`, `world_ready`/`saving`/`saved`, `entity_spawned`/`despawned`. |
| GlobalSettings | `global_settings.gd` | Engine constants: chunk size, pool limits, frame budgets.                                                                                                          |
| TileIndex      | `tile_index.gd`      | Tile registry. Registers tiles with solidity, textures, and properties (friction, damage, transparency, hardness). Builds `Texture2DArray` for shader.             |
| GameServices   | `game_services.gd`   | Service locator. Holds `chunk_manager`, `entity_manager`, `tile_registry`, `terrain_generator`, `world_save_manager`.                                              |

## Tile Registry (TileIndex)

The tile registry is the central authority on tile types. It provides:

- **Registration**: `register_tile(id, name, solid, texture_path, color, properties)` adds a tile type
- **Queries**: `is_solid(id)`, `get_tile_name(id)`, `get_tile_color(id)`, `get_tile_ids()`
- **Properties**: `get_tile_property(id, key)`, `get_friction(id)`, `get_damage(id)`, `get_transparency(id)`, `get_hardness(id)`
- **Rendering**: `get_texture_array()` returns a `Texture2DArray` for the shader

Default tiles (AIR=0, DIRT=1, GRASS=2, STONE=3) are registered in `_ready()`. The constants are preserved for backward compatibility. New tiles can be registered before `rebuild_texture_array()` is called.

### Tile Properties

Each tile has a `properties` dictionary merged with `DEFAULT_PROPERTIES`:

| Property       | Default | Description                   |
| -------------- | ------- | ----------------------------- |
| `friction`     | 1.0     | Surface friction multiplier   |
| `damage`       | 0.0     | Contact damage per second     |
| `transparency` | 1.0     | Light transmission (0=opaque) |
| `hardness`     | 1       | Mining difficulty             |

Custom properties are passed as the last argument to `register_tile()`. Missing keys fall back to defaults. To add a new property, add it to `DEFAULT_PROPERTIES` and optionally add a convenience getter.

### Adding a New Tile

1. Add a texture to `assets/textures/` (must match existing tile texture dimensions)
2. In `tile_index.gd._ready()`, add: `register_tile(4, "Sand", true, "res://assets/textures/sand.png", Color(0.9, 0.8, 0.5), {"friction": 0.5})`
3. Call `rebuild_texture_array()` after all registrations
4. The shader, toolbar, and collision system automatically pick up the new tile

## Threading Model

```text
Main Thread                    WorkerThreadPool
─────────────                  ─────────────────
ChunkManager._process()   ←→   ChunkLoader._generate_chunk_task()
  ├─ get_built_chunks()         ├─ TerrainGenerator.generate_chunk()
  ├─ chunk.generate()           └─ _generate_visual_image()
  ├─ chunk.build()
  └─ _process_removal_queue()
```

### Synchronization

- **Mutex**: Protects ChunkLoader queues and Chunk terrain data
- **Backpressure**: Generation pauses when build queue exceeds `MAX_BUILD_QUEUE_SIZE` (128). Resumes when drained below 50%.
- **Shutdown**: `stop()` sets `_shutdown_requested`, clears queues, then busy-waits with a 2-second timeout for active tasks to finish.
- **Frame budget**: Max 16 builds and 32 removals per frame (configurable in GlobalSettings)

### Thread Safety Rules

1. TerrainGenerator must NOT call any Godot scene tree API
2. ChunkLoader's `_generate_visual_image()` runs in worker thread — only uses `Image` API
3. Chunk terrain data access requires mutex lock
4. `Chunk.build()` and `Chunk.edit_tiles()` run on main thread only

## Rendering Pipeline

### Data Flow

```text
1. TerrainGenerator.generate_chunk(chunk_pos)
   → PackedByteArray (32×32×2 bytes: [tile_id, cell_id] per tile)

2. ChunkLoader._generate_visual_image(terrain_data)
   → Image (RGBA8, 32×32: R=tile_id/255, G=cell_id/255)
   → Y-inverted for rendering alignment

3. Chunk.build(visual_image)
   → ImageTexture.create_from_image()
   → Sets shader uniforms: chunk_data_texture, tile_textures

4. terrain.gdshader (fragment)
   → Decodes tile_id from R channel
   → Samples Texture2DArray at layer = tile_id
   → Uses world-space UV for seamless tiling
```

### Y-Inversion

Data layout (row 0 = world Y=0) and Image layout (row 0 = top) are inverted. Both `ChunkLoader._generate_visual_image()` and `Chunk.edit_tiles()` apply `image_y = (CHUNK_SIZE - 1) - data_y`. This must be consistent or rendering breaks.

### Shader

The terrain shader uses a `Texture2DArray` indexed by tile_id:

- Layer 0 (AIR): discarded (transparent)
- Layer 1+ : tile textures sampled with world-space UV

## Terrain Generation

### Generator Interface

All terrain generators extend `BaseTerrainGenerator`:

```gdscript
class_name BaseTerrainGenerator extends RefCounted

func generate_chunk(chunk_pos: Vector2i) -> PackedByteArray:
    # Must return CHUNK_SIZE * CHUNK_SIZE * 2 bytes
    # Format: [tile_id, cell_id] pairs, row-major order
    pass

func get_generator_name() -> String:
    pass
```

### SimplexTerrainGenerator

The default implementation uses three layered `FastNoiseLite` instances:

- **Heightmap noise** (freq 0.002): Broad hills and valleys
- **Detail noise** (freq 0.008): Surface roughness
- **Layer noise** (freq 0.006): Dirt/stone boundary variation

Terrain layers from surface down: AIR → GRASS (1-4 tiles) → DIRT (~20 tiles) → STONE. Steep slopes suppress grass (cliff detection via central difference).

All parameters are configurable via the config dictionary passed to `_init()`.

### Creating a Custom Generator

1. Create a new script extending `BaseTerrainGenerator`
2. Override `generate_chunk()` to return terrain data
3. Pass the generator instance to `ChunkLoader` in `ChunkManager._ready()`

## Collision System

Custom swept AABB detection (not Godot physics). `CollisionDetector` sweeps X then Y axis against the tile grid. `MovementController` wraps this with gravity, acceleration, friction, jump, and step-up logic.

### Collision → Tile Mapping

`CollisionDetector` queries `ChunkManager.is_solid_at_world_pos()`, which delegates to `TileIndex.is_solid(tile_id)`. Any tile where `is_solid` returns `true` blocks movement. This decoupling enables future non-solid tiles (water, flowers) without collision changes.

### MovementController

Reusable `RefCounted` with exported parameters. Composed into entities (not inherited). Handles:

- Gravity and horizontal acceleration/friction
- Coyote jump timing
- Step-up mechanics (climb small ledges)
- Swept collision resolution with sliding

## Chunk Lifecycle

```text
Pool → _get_chunk() → generate(data, pos) → build(image) → visible
                                                              ↓
                         ← _recycle_chunk() ← reset() ← removal queue
```

1. **Pool**: Pre-populated with `MAX_CHUNK_POOL_SIZE` instances
2. **Generate**: Stores terrain data, sets world position
3. **Build**: Creates GPU texture, makes visible
4. **Removal**: Queued when player moves away, processed per-frame
5. **Recycle**: Reset and returned to pool (or freed if pool full)

## Terrain Editing

```text
Mouse input → GUIManager._apply_edit()
  → generates tile changes by brush shape/size
  → ChunkManager.set_tiles_at_world_positions(changes)
    → groups by chunk
    → Chunk.edit_tiles(changes)
      → updates PackedByteArray (mutex locked)
      → updates Image (Y-inverted)
      → ImageTexture.update() (GPU sync)
```

## Configuration

### GlobalSettings Constants

| Constant                        | Default | Purpose                                                         |
| ------------------------------- | ------- | --------------------------------------------------------------- |
| CHUNK_SIZE                      | 32      | Tiles per chunk side                                            |
| REGION_SIZE                     | 4       | Chunks per region side                                          |
| LOD_RADIUS                      | 4       | Regions to generate around player                               |
| REMOVAL_BUFFER                  | 2       | Extra regions before chunk removal                              |
| MAX_CHUNK_BUILDS_PER_FRAME      | 16      | Build budget per frame                                          |
| MAX_CHUNK_REMOVALS_PER_FRAME    | 32      | Removal budget per frame                                        |
| MAX_BUILD_QUEUE_SIZE            | 128     | Backpressure threshold                                          |
| MAX_CHUNK_POOL_SIZE             | 1296    | Chunk pool cap (calculated: `(2*LOD_RADIUS+1)² × REGION_SIZE²`) |
| MAX_CONCURRENT_GENERATION_TASKS | 8       | WorkerThreadPool parallelism                                    |

## Camera System

`CameraController` (`src/camera/camera_controller.gd`) extends `Camera2D`. It is a sibling of `Player` in the scene tree (not a child), enabling independent camera behavior.

### Features

- **Smooth follow**: Frame-rate independent lerp: `weight = 1.0 - exp(-smoothing * delta)`. Configurable `smoothing` export (default 10.0).
- **Mouse wheel zoom**: Multiplies current zoom by `(1 ± zoom_step)`, clamped to `[min_zoom, max_zoom]`.
- **Zoom presets**: Z key cycles through `[1x, 2x, 4x, 8x]`. Default starts at 4x.
- **Target discovery**: Deferred `_find_target()` locates `Player` node via `get_tree().current_scene.get_node_or_null("Player")`.

Since `CameraController` IS the scene's `Camera2D`, existing code using `get_viewport().get_camera_2d()` (GUIManager, CursorInfo, DebugHUD) continues to work.

## Entity System

### BaseEntity

`BaseEntity` (`src/entities/base_entity.gd`) extends `Node2D`. Provides:

- `velocity: Vector2` — current velocity (readable by external systems)
- `collision_box_size: Vector2` — exported collision dimensions
- `entity_id: int` — assigned by EntityManager (-1 if unmanaged)
- `setup_movement(collision_detector)` — initializes optional `MovementController`
- `entity_process(delta)` — called by EntityManager; runs movement then `_entity_update(delta)`
- `_entity_update(delta)` — virtual, override for per-entity logic
- `_get_movement_input() -> Vector2` — virtual, override to supply movement (x=axis, y>0=jump)

### EntityManager

`EntityManager` (`src/entities/entity_manager.gd`) extends `Node`. Manages the entity lifecycle:

- `spawn(entity) -> int` — adds entity as child, assigns monotonic ID, emits `entity_spawned`
- `despawn(id)` — removes entity, emits `entity_despawned`, frees node
- `get_entity(id)`, `get_entity_count()`, `get_debug_info()`
- `_physics_process(delta)` — iterates all entities and calls `entity_process(delta)`

Entity signals are typed as `Node2D` (not `BaseEntity`) on SignalBus to avoid coupling.

## Input Actions

| Action                        | Key         | System                   |
| ----------------------------- | ----------- | ------------------------ |
| move_left/right               | A/D         | Player movement          |
| jump                          | Space       | Player jump              |
| zoom presets                  | Z           | Cycle camera zoom        |
| mouse wheel                   | Scroll      | Camera zoom in/out       |
| 1/2/3/4                       | Number keys | Material selection       |
| Q/E                           | Size keys   | Brush size               |
| toggle_controls_help          | F1          | Controls overlay         |
| toggle_cursor_info            | F2          | Cursor info HUD          |
| toggle_debug_hud              | F3          | Debug HUD                |
| toggle_debug_world_overlay    | F4          | Chunk debug overlay      |
| debug_toggle_all              | F5          | Toggle all debug layers  |
| debug_toggle_chunk_borders    | F6          | Chunk border overlay     |
| debug_toggle_region_borders   | F7          | Region border overlay    |
| debug_toggle_generation_queue | F8          | Generation queue overlay |
| debug_toggle_removal_queue    | F9          | Removal queue overlay    |
| debug_toggle_queue_info       | F10         | Queue info text overlay  |
