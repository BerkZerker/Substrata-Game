# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Substrata is a 2D voxel-based game built in **Godot 4.6** using **GDScript**. It features procedurally generated, editable terrain with a multithreaded chunk loading system. The main scene is `src/game/game_instance.tscn`.

## Running the Project

Open in Godot 4.6 and press F5. To run headless tests: `./tests/run_tests.sh /path/to/godot`. See `docs/ENGINE_ARCHITECTURE.md` for full engine documentation.

## Code Style

- GDScript files use 4-space indentation (see `.editorconfig`)
- UTF-8 encoding, LF line endings
- High cohesion within files, low coupling between scripts

## Architecture

### Threading Model (Producer-Consumer)

The core system uses a background thread for chunk generation:

- **ChunkManager** (`src/world/chunks/chunk_manager.gd`) — Main thread orchestrator. Monitors player position, queues chunk generation/removal, and processes built chunks each frame (max 16 builds, 32 removals per frame).
- **ChunkLoader** (`src/world/chunks/chunk_loader.gd`) — Background worker thread. Generates terrain data and visual images off the main thread. Uses Mutex/Semaphore for synchronization with backpressure (pauses when build queue exceeds threshold).
- **Chunk** (`src/world/chunks/chunk.gd`) — Individual chunk with terrain stored as `PackedByteArray` (2 bytes per tile: `[tile_id, cell_id]`). Uses a shared `QuadMesh` and a fragment shader for rendering. Mutex-protected terrain data.

### Rendering Pipeline

Terrain data flows: `PackedByteArray` → `Image` (RGBA8, R=tile_id, G=cell_id, B=light_level) → `ImageTexture` → fragment shader (`src/world/chunks/terrain.gdshader`) which decodes tile_id, samples a `Texture2DArray` (built by `TileIndex`) at the tile_id layer, and applies lighting from the B channel.

### Terrain Generation

All terrain generators extend `BaseTerrainGenerator` (`src/world/generators/base_terrain_generator.gd`), which defines the `generate_chunk(chunk_pos) -> PackedByteArray` interface. The default implementation is `SimplexTerrainGenerator` (`src/world/generators/simplex_terrain_generator.gd`), which uses layered `FastNoiseLite` (Simplex noise) with configurable parameters for surface shape, layer boundaries, and cliff detection. Generators are passed to `ChunkLoader` at construction time. Runs entirely in the background thread — no Godot scene API calls allowed here.

### Collision System

Custom **swept AABB** collision detection (`src/physics/collision_detector.gd`) — does not use Godot's built-in physics. Sweeps X then Y axis separately, calculates collision normals and times. Also provides `raycast()` (DDA tile stepping), `query_area()` (AABB), and `query_area_circle()` for spatial queries. Physics layers: terrain (layer 1), player (layer 2).

### Global Autoloads

Four autoloaded singletons (registered in `project.godot`):

- **SignalBus** (`src/globals/signal_bus.gd`) — Global event bus. Signals: `player_chunk_changed`, `tile_changed`, `chunk_loaded`, `chunk_unloaded`, `world_ready`, `world_saving`, `world_saved`, `entity_spawned`, `entity_despawned`, `entity_chunk_changed`, `light_level_changed`.
- **GlobalSettings** (`src/globals/global_settings.gd`) — World constants: `CHUNK_SIZE=32`, `REGION_SIZE=4`, `LOD_RADIUS=4`, `MAX_CHUNK_POOL_SIZE=512`, frame budget limits.
- **TileIndex** (`src/globals/tile_index.gd`) — Data-driven tile registry. Registers tiles with ID, name, solidity, texture path, UI color, and properties (friction, damage, transparency, hardness, emission, light_filter). Builds a `Texture2DArray` for the terrain shader. Default tiles: `AIR=0, DIRT=1, GRASS=2, STONE=3`. New tiles can be added via `register_tile()` + `rebuild_texture_array()`. Properties use a defaults-merge pattern via `DEFAULT_PROPERTIES`.
- **GameServices** (`src/globals/game_services.gd`) — Service locator for shared systems. Holds `chunk_manager`, `entity_manager`, `tile_registry`, `terrain_generator`, `world_save_manager`, and `light_manager` references, populated by `GameInstance._ready()`.

### Camera System

`CameraController` (`src/camera/camera_controller.gd`) — `extends Camera2D`. Smooth-follow camera decoupled from Player. Uses frame-rate independent lerp (`1.0 - exp(-smoothing * 60.0 * delta)`). Auto-discovers Player target via deferred scene tree lookup. Mouse wheel zoom with configurable step/limits. `[` / `]` keys cycle zoom presets (1x, 2x, 4x, 8x). `shake(intensity, duration, decay)` triggers screen shake with exponential decay. Scripts using `get_viewport().get_camera_2d()` continue to work since CameraController IS the Camera2D.

### Entity System

- **BaseEntity** (`src/entities/base_entity.gd`) — `extends Node2D`. Base class for game entities with velocity, collision_box_size, chunk_pos, optional `MovementController` composition. Virtual methods: `entity_process(delta)`, `_entity_update(delta)`, `_get_movement_input()`.
- **EntityManager** (`src/entities/entity_manager.gd`) — `extends Node`. Manages entity lifecycle with `spawn()` / `despawn()`. Assigns monotonically increasing IDs. Drives `entity_process()` on all active entities each `_physics_process`. Tracks entity-chunk mapping (`_chunk_entities`). Auto-despawns entities in unloaded chunks. Spatial queries via `get_entities_in_chunk()` and `get_entities_in_area()`. Emits `entity_spawned` / `entity_despawned` / `entity_chunk_changed` via SignalBus.

### Scene Tree Structure

```text
GameInstance (Node)
├── Player (CharacterBody2D)
├── CameraController (Camera2D) — smooth-follow camera
├── ChunkManager (Node2D) — owns all Chunk children
├── EntityManager (Node) — manages spawned entities
├── ChunkDebugOverlay (Node2D) — debug visualization (F1-F6 toggles)
└── UILayer (CanvasLayer)
    └── GUIManager (Control)
```

`GameInstance._ready()` registers all services (`chunk_manager`, `entity_manager`, `tile_registry`, `terrain_generator`, `world_save_manager`, `light_manager`) with `GameServices` and sets up `WorldSaveManager` for persistence.

### Persistence

`WorldSaveManager` (`src/world/persistence/world_save_manager.gd`) — `RefCounted` that handles saving/loading world data. Saves world metadata as JSON and chunk terrain data as raw `PackedByteArray` files. Save path: `user://worlds/{name}/`. ChunkManager tracks dirty chunks and auto-saves them on unload and on exit. Only modified chunks are persisted.

### Terrain Editing

GUI (`src/gui/gui_manager.gd`) captures mouse input → calculates affected tiles by brush shape/size → batches changes as `{pos, tile_id, cell_id}` arrays → ChunkManager groups by chunk → each chunk updates terrain data with `edit_tiles(changes, skip_visual_update=true)` (skips stale GPU upload) → `LightManager.recalculate_chunks_light()` batch-recalculates all edited chunks with mutual border imports → cascading propagation updates neighboring chunks automatically.

### Player & Movement

`src/entities/player.gd` — Reads input and delegates to `MovementController` (`src/physics/movement_controller.gd`). The movement controller handles gravity, horizontal acceleration/friction, coyote jump, step-up mechanics, and swept AABB collision. `move()` returns a Dictionary `{position, velocity, is_on_floor, floor_tile_id, tile_damage}` — applies tile friction from floor tile and detects damage tiles overlapping the entity. It's a reusable `RefCounted` that can be composed into any entity. Camera is handled separately by `CameraController`.

### Lighting System

- **LightPropagator** (`src/world/lighting/light_propagator.gd`) — Thread-safe BFS flood-fill. `calculate_light(terrain_data) -> PackedByteArray` returns 2 bytes per tile `[sunlight, blocklight]`, values 0-MAX_LIGHT (80). Sunlight propagates straight down from sky (max MAX_LIGHT, no attenuation) then spreads via BFS with -1-filter attenuation per tile. `continue_light()` accepts border seeds for cross-chunk BFS continuation.
- **LightManager** (`src/world/lighting/light_manager.gd`) — Cross-chunk coordination using worklist-based cascading propagation. Two-phase algorithm handles both light increases (BFS continuation to neighbors) and decreases (full recalculation with neighbor imports). `propagate_border_light()` imports border light on chunk load and cascades outward. `recalculate_chunk_light()` / `recalculate_chunks_light()` handle tile edits with automatic cross-chunk cascading (bounded by `_MAX_CASCADE_DEPTH=3`). Border snapshots detect which neighbors need updating. `get_light_at_world_pos()` returns 0-MAX_LIGHT. `ambient_light` uniform for day/night cycle.
- Light runs in worker thread during chunk generation (thread-safe: only reads PackedByteArray + TileIndex). Cross-chunk border fixup and cascading propagation run on main thread in `_process_build_queue()` and `set_tiles_at_world_positions()`. Light is deterministic from tile state — no additional save data.

## Key Constraints

- **Thread safety**: Any code that touches chunk terrain data must acquire the chunk's mutex. Terrain generators and ChunkLoader must not call Godot scene tree APIs.
- **Frame budget**: Chunk builds and removals are capped per frame to prevent stuttering. These limits are in `GlobalSettings`.
- **Chunk pooling**: Chunks are recycled from a pool (up to `MAX_CHUNK_POOL_SIZE`) to avoid instantiation overhead. Don't create chunk instances directly — use the pool in ChunkManager.
- **Y-inversion**: The `_generate_visual_image` method in ChunkLoader and the `edit_tiles` method in Chunk both apply Y-inversion when writing to the Image. This is required for correct rendering alignment between the PackedByteArray data layout and Image coordinate system. Do not remove it.
- **Coordinate convention**: Standard Godot Y-down (`+Y = down`). Gravity is positive (800), jump velocity is negative (-400).
