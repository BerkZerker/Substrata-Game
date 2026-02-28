# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Substrata is a 2D voxel-based game built in **Godot 4.6** using **GDScript**. It features procedurally generated, editable terrain with a multithreaded chunk loading system. The main scene is `src/game/game_instance.tscn`.

## Running the Project

Open in Godot 4.6 and press F5. See `docs/ENGINE_ARCHITECTURE.md` for full engine documentation.

## Code Style

- GDScript files use 4-space indentation (see `.editorconfig`)
- UTF-8 encoding, LF line endings
- High cohesion within files, low coupling between scripts

## Architecture

### Threading Model (Producer-Consumer)

The core system uses a background thread for chunk generation:

- **ChunkManager** (`src/world/chunks/chunk_manager.gd`) — Main thread orchestrator. Monitors player position, queues chunk generation/removal, and processes built chunks each frame (max 16 builds, 32 removals per frame).
- **ChunkLoader** (`src/world/chunks/chunk_loader.gd`) — Background worker using WorkerThreadPool. Generates terrain data and visual images off the main thread. Uses Mutex for synchronization with backpressure (pauses when build queue exceeds threshold). Also provides `generate_visual_image()` for main-thread use when loading saved chunks.
- **Chunk** (`src/world/chunks/chunk.gd`) — Individual chunk with terrain stored as `PackedByteArray` (2 bytes per tile: `[tile_id, cell_id]`). Uses a shared `QuadMesh` and a fragment shader for rendering. Mutex-protected terrain data.

### Rendering Pipeline

Terrain data flows: `PackedByteArray` → `Image` (RGBA8, R=tile_id, G=cell_id, B=light_level) → `ImageTexture` → fragment shader (`src/world/chunks/terrain.gdshader`) which decodes tile_id, samples a `Texture2DArray` (built by `TileIndex`) at the tile_id layer, and multiplies by the baked light level from the B channel plus dynamic light contributions.

### Terrain Generation

All terrain generators extend `BaseTerrainGenerator` (`src/world/generators/base_terrain_generator.gd`), which defines the `generate_chunk(chunk_pos) -> PackedByteArray` interface. The default implementation is `SimplexTerrainGenerator` (`src/world/generators/simplex_terrain_generator.gd`), which uses layered `FastNoiseLite` (Simplex noise) with configurable parameters for surface shape, layer boundaries, and cliff detection. Generators are passed to `ChunkLoader` at construction time. Runs entirely in the background thread — no Godot scene API calls allowed here.

### Collision System

Custom **swept AABB** collision detection (`src/physics/collision_detector.gd`) — does not use Godot's built-in physics. Sweeps X then Y axis separately, calculates collision normals and times. `sweep_aabb()` returns `hit_tile_ids` for tile-aware collision responses. Also provides `raycast()` (DDA grid traversal) and `query_area()` (AABB tile query). Physics layers: terrain (layer 1), player (layer 2).

### Global Autoloads

Four autoloaded singletons (registered in `project.godot`):

- **SignalBus** (`src/globals/signal_bus.gd`) — Global event bus. Signals: `player_chunk_changed`, `tile_changed`, `chunk_loaded`, `chunk_unloaded`, `world_ready`, `world_saving`, `world_saved`, `entity_spawned`, `entity_despawned`.
- **GlobalSettings** (`src/globals/global_settings.gd`) — World constants: `CHUNK_SIZE=32`, `REGION_SIZE=4`, `LOD_RADIUS=4`, `MAX_CHUNK_POOL_SIZE=1296` (calculated from LOD/region dimensions), frame budget limits.
- **TileIndex** (`src/globals/tile_index.gd`) — Data-driven tile registry. Registers tiles with ID, name, solidity, texture path, UI color, and properties (friction, damage, transparency, hardness, light_emission). Builds a `Texture2DArray` for the terrain shader. Default tiles: `AIR=0, DIRT=1, GRASS=2, STONE=3`. New tiles can be added via `register_tile()` + `rebuild_texture_array()`. Properties use a defaults-merge pattern via `DEFAULT_PROPERTIES`.
- **GameServices** (`src/globals/game_services.gd`) — Service locator for shared systems. Holds `chunk_manager`, `entity_manager`, `light_manager`, `tile_registry`, `terrain_generator`, and `world_save_manager` references, populated by `GameInstance._ready()`.

### Camera System

`CameraController` (`src/camera/camera_controller.gd`) — `extends Camera2D`. Smooth-follow camera decoupled from Player. Uses frame-rate independent lerp (`1.0 - exp(-smoothing * delta)`). Auto-discovers Player target via deferred scene tree lookup. Mouse wheel zoom with configurable step/limits. Z key cycles zoom presets (1x, 2x, 4x, 8x). `apply_shake(intensity, duration)` for screen shake with linear decay. Scripts using `get_viewport().get_camera_2d()` continue to work since CameraController IS the Camera2D.

### Entity System

- **BaseEntity** (`src/entities/base_entity.gd`) — `extends Node2D`. Base class for game entities with velocity, collision_box_size, `current_chunk` tracking, optional `MovementController` composition. Virtual methods: `entity_process(delta)`, `_entity_update(delta)`, `_get_movement_input()`.
- **EntityManager** (`src/entities/entity_manager.gd`) — `extends Node`. Manages entity lifecycle with `spawn()` / `despawn()`. Assigns monotonically increasing IDs. Drives `entity_process()` on all active entities each `_physics_process`. Tracks entities by chunk via `_entities_by_chunk`. On chunk unload, serializes and despawns entities; on chunk load, deserializes and respawns them. Emits `entity_spawned` / `entity_despawned` via SignalBus. Player is NOT managed by EntityManager.

### Lighting System

Three-layer lighting pipeline:

- **LightBaker** (`src/world/lighting/light_baker.gd`) — `RefCounted`. Static per-chunk light bake via BFS flood fill. Sunlight propagates from top (light=MAX_LIGHT in air, blocked by solid). Emissive tiles (including AIR with emission=40) seed from `TileIndex.get_light_emission()`. Cross-chunk border seeding for both sky AND block light from neighbor data. `bake_from_data()` is a pure-computation method that takes snapshot data (terrain, above terrain, neighbor sky/block light) — safe for background threads with zero chunk/scene access. `bake_chunk_light()` is the legacy main-thread version (no callers after background threading). Light baking runs in WorkerThreadPool, managed by ChunkManager: main thread gathers snapshots, submits tasks, applies results budget-limited (MAX_LIGHT_BAKE_RESULTS_PER_FRAME=8). Dedup mechanism handles edits during in-progress bakes.
- **LightManager** (`src/world/lighting/light_manager.gd`) — `extends Node`. Manages up to 16 dynamic point lights. Each `_process()`, packages light data into `PackedVector2Array`/`PackedFloat32Array`/`PackedColorArray` and pushes shader uniforms to all loaded chunks. Also drives `TimeOfDay` and updates `ambient_light` uniform.
- **TimeOfDay** (`src/world/lighting/time_of_day.gd`) — `RefCounted`. Tracks time (0.0=midnight, 0.5=noon). Sine-curve ambient level (0.05–1.0). Default 600s cycle. Owned by LightManager.

Shader (`terrain.gdshader`) combines: `max(baked_light, ambient_light) + dynamic_lights`, clamped to 1.0. Dynamic lights use quadratic distance falloff.

### Scene Tree Structure

```text
GameInstance (Node)
├── Player (CharacterBody2D)
├── CameraController (Camera2D) — smooth-follow camera
├── ChunkManager (Node2D) — owns all Chunk children
├── EntityManager (Node) — manages spawned entities
├── LightManager (Node) — dynamic lights + day/night (added at runtime)
├── ChunkDebugOverlay (Node2D) — debug visualization (F4-F10 sub-toggles)
└── UILayer (CanvasLayer)
    └── GUIManager (Control)
```

`GameInstance._ready()` registers all services (`chunk_manager`, `entity_manager`, `light_manager`, `tile_registry`, `terrain_generator`, `world_save_manager`) with `GameServices`, sets up `WorldSaveManager` for persistence, and creates `LightManager`.

### Persistence

`WorldSaveManager` (`src/world/persistence/world_save_manager.gd`) — `RefCounted` that handles saving/loading world data. Saves world metadata as JSON and chunk terrain data as raw `PackedByteArray` files. Save path: `res://data/{name}/`. ChunkManager tracks dirty chunks and auto-saves them on unload and on exit. On startup, saved chunks are loaded directly on the main thread (bypassing the generation thread). Only modified chunks are persisted. Validates chunk data size on load.

### Terrain Editing

GUI (`src/gui/gui_manager.gd`) captures mouse input → calculates affected tiles by brush shape/size → batches changes as `{pos, tile_id, cell_id}` arrays → ChunkManager groups by chunk → each chunk updates data + updates the existing `ImageTexture` in-place via `update()`.

### Player & Movement

`src/entities/player.gd` — Reads input and delegates to `MovementController` (`src/physics/movement_controller.gd`). The movement controller handles gravity, horizontal acceleration/friction, coyote jump, step-up mechanics, and swept AABB collision. It's a reusable `RefCounted` that can be composed into any entity. Opt-in tile interactions: `use_tile_friction` modulates deceleration by `TileIndex.get_friction()`, `use_tile_damage` + `on_tile_damage` callback for damage tiles. Exposes `last_floor_tile_ids` / `last_wall_tile_ids`. Player exposes `get_movement_velocity()` and `get_on_floor()` public getters for DebugHUD and other systems. Camera is handled separately by `CameraController`.

## Key Constraints

- **Thread safety**: Any code that touches chunk terrain data must acquire the chunk's mutex. Terrain generators and ChunkLoader must not call Godot scene tree APIs.
- **Frame budget**: Chunk builds and removals are capped per frame to prevent stuttering. These limits are in `GlobalSettings`.
- **Chunk pooling**: Chunks are recycled from a pool (up to `MAX_CHUNK_POOL_SIZE = 1296`, calculated to match max loaded chunks). Don't create chunk instances directly — use the pool in ChunkManager.
- **Y-inversion**: The `_generate_visual_image` method in ChunkLoader and the `edit_tiles` method in Chunk both apply Y-inversion when writing to the Image. This is required for correct rendering alignment between the PackedByteArray data layout and Image coordinate system. Do not remove it.
- **Coordinate convention**: Standard Godot Y-down (`+Y = down`). Gravity is positive (800), jump velocity is negative (-400).
