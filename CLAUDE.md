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

All terrain generators extend `BaseTerrainGenerator` (`src/world/generators/base_terrain_generator.gd`), which defines the `generate_chunk(chunk_pos) -> PackedByteArray` interface. The default generator is `BiomeTerrainGenerator` (`src/world/generators/biome_terrain_generator.gd`), which uses a `BiomeMap` (`src/world/biomes/biome_map.gd`) to vary terrain per-column. 5 biomes defined: Plains, Desert, Tundra, Forest, Mountains — each with its own tile palette and generator params. Heightmap blending at biome boundaries (16-tile radius). `SimplexTerrainGenerator` (`src/world/generators/simplex_terrain_generator.gd`) is still available as a simpler alternative. Generators are passed to `ChunkLoader` at construction time. Runs entirely in the background thread — no Godot scene API calls allowed here.

### Collision System

Custom **swept AABB** collision detection (`src/physics/collision_detector.gd`) — does not use Godot's built-in physics. Sweeps X then Y axis separately, calculates collision normals and times. Also provides `raycast()` (DDA tile stepping), `query_area()` (AABB), and `query_area_circle()` for spatial queries. Physics layers: terrain (layer 1), player (layer 2).

### Global Autoloads

Four autoloaded singletons (registered in `project.godot`):

- **SignalBus** (`src/globals/signal_bus.gd`) — Global event bus. Signals: `player_chunk_changed`, `tile_changed`, `chunk_loaded`, `chunk_unloaded`, `world_ready`, `world_saving`, `world_saved`, `entity_spawned`, `entity_despawned`, `entity_chunk_changed`, `light_level_changed`, `entity_damaged`, `entity_died`, `entity_healed`.
- **GlobalSettings** (`src/globals/global_settings.gd`) — World constants: `CHUNK_SIZE=32`, `REGION_SIZE=4`, `LOD_RADIUS=4`, `MAX_CHUNK_POOL_SIZE=512`, frame budget limits.
- **TileIndex** (`src/globals/tile_index.gd`) — Data-driven tile registry. Registers tiles with ID, name, solidity, texture path, UI color, and properties (friction, damage, transparency, hardness, emission, light_filter, speed_modifier). Builds a `Texture2DArray` for the terrain shader. 17 tiles: `AIR=0, DIRT=1, GRASS=2, STONE=3, SAND=4, GRAVEL=5, CLAY=6, SNOW=7, ICE=8, COAL_ORE=9, IRON_ORE=10, GOLD_ORE=11, WATER=12, LAVA=13, FLOWERS=14, MUSHROOM=15, VINES=16`. New tiles can be added via `register_tile()` + `rebuild_texture_array()`. Properties use a defaults-merge pattern via `DEFAULT_PROPERTIES`.
- **GameServices** (`src/globals/game_services.gd`) — Service locator for shared systems. Holds `chunk_manager`, `entity_manager`, `tile_registry`, `terrain_generator`, `world_save_manager`, `light_manager`, and `dynamic_light_manager` references, populated by `GameInstance._ready()`.

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
├── DynamicLightManager (Node) — GPU dynamic lights
├── ChunkDebugOverlay (Node2D) — debug visualization (F1-F6 toggles)
└── UILayer (CanvasLayer)
    └── GUIManager (Control)
```

`GameInstance._ready()` registers all services (`chunk_manager`, `entity_manager`, `tile_registry`, `terrain_generator`, `world_save_manager`, `light_manager`, `dynamic_light_manager`) with `GameServices` and sets up `WorldSaveManager` for persistence.

### Persistence

`WorldSaveManager` (`src/world/persistence/world_save_manager.gd`) — `RefCounted` that handles saving/loading world data. Saves world metadata as JSON and chunk terrain data as raw `PackedByteArray` files. Save path: `user://worlds/{name}/`. ChunkManager tracks dirty chunks and auto-saves them on unload and on exit. Only modified chunks are persisted.

### Terrain Editing

GUI (`src/gui/gui_manager.gd`) captures mouse input → calculates affected tiles by brush shape/size → batches changes as `{pos, tile_id, cell_id}` arrays → ChunkManager groups by chunk → each chunk updates terrain data with `edit_tiles(changes, skip_visual_update=true)` (skips stale GPU upload) → `LightManager.recalculate_chunks_light()` batch-recalculates all edited chunks with mutual border imports → cascading propagation updates neighboring chunks automatically.

### Player & Movement

`src/entities/player.gd` — Reads input and delegates to `MovementController` (`src/physics/movement_controller.gd`). The movement controller handles gravity, horizontal acceleration/friction (with tile speed_modifier), coyote jump, step-up mechanics, and swept AABB collision. `move()` returns a Dictionary `{position, velocity, is_on_floor, floor_tile_id, tile_damage}` — applies tile friction and speed_modifier from floor tile and detects damage tiles overlapping the entity. It's a reusable `RefCounted` that can be composed into any entity. Player has a `HealthComponent` (`src/components/health_component.gd`) for fall damage, tile damage, death/respawn, and invincibility frames with visual flicker. Player torch light (T key toggle) via `DynamicLightManager`. Camera is handled separately by `CameraController`.

### Health & Damage

`HealthComponent` (`src/components/health_component.gd`) — Composable `RefCounted` with max_health, current_health, invincibility timer. `take_damage(amount, knockback_direction)` applies damage with i-frames, `heal(amount)`, `is_dead()`, `reset()`. Emits `entity_damaged`/`entity_died`/`entity_healed` via SignalBus. Player wires fall damage (threshold 500 px/s), tile damage (per-second from movement result), death/respawn (1s delay, teleport to spawn), and knockback.

### Tools & Mining

- **ToolDefinition** (`src/items/tool_definition.gd`) — `RefCounted` with tool_name, mining_speed, durability, tool_level. Factory methods: `create_hand()`, `create_wood_pickaxe()`, `create_stone_pickaxe()`, `create_iron_pickaxe()`.
- **MiningSystem** (`src/gui/mining_system.gd`) — Tracks mining progress per tile. mining_time = hardness / tool.mining_speed. Hold right-click to mine, resets on cursor move.
- **GUIManager** integration: Left click = place (brush), Right click = mine (single tile). Shift+1-4 switches tools. Tool label shows name and durability.

### Lighting System

- **LightPropagator** (`src/world/lighting/light_propagator.gd`) — Thread-safe BFS flood-fill. `calculate_light(terrain_data) -> PackedByteArray` returns 2 bytes per tile `[sunlight, blocklight]`, values 0-MAX_LIGHT (80). Sunlight propagates straight down from sky (max MAX_LIGHT, no attenuation) then spreads via BFS with -1-filter attenuation per tile. `continue_light()` accepts border seeds for cross-chunk BFS continuation.
- **LightManager** (`src/world/lighting/light_manager.gd`) — Cross-chunk coordination using worklist-based cascading propagation. Two-phase algorithm handles both light increases (BFS continuation to neighbors) and decreases (full recalculation with neighbor imports). `propagate_border_light()` imports border light on chunk load and cascades outward. `recalculate_chunk_light()` / `recalculate_chunks_light()` handle tile edits with automatic cross-chunk cascading (bounded by `_MAX_CASCADE_DEPTH=3`). Border snapshots detect which neighbors need updating. `get_light_at_world_pos()` returns 0-MAX_LIGHT. `ambient_light` uniform for day/night cycle.
- Light runs in worker thread during chunk generation (thread-safe: only reads PackedByteArray + TileIndex). Cross-chunk border fixup and cascading propagation run on main thread in `_process_build_queue()` and `set_tiles_at_world_positions()`. Light is deterministic from tile state — no additional save data.

### Dynamic Lights (Shader-Based)

- **DynamicLightManager** (`src/world/lighting/dynamic_light_manager.gd`) — `extends Node`. Manages up to 64 dynamic lights, packs into 1D RGBAF data texture each frame, sets global shader uniforms via `RenderingServer.global_shader_parameter_*`. API: `add_light(pos, radius, intensity, color) -> id`, `remove_light(id)`, `update_light_position(id, pos)`, `update_light(id, pos, radius, intensity)`, `add_transient_light(pos, radius, intensity, ttl, color) -> id` (fire-and-forget with linear fade).
- Terrain shader loops over dynamic lights with quantized distance falloff (`floor(falloff * radius) / radius`) for pixel-art feel. Final brightness = `max(static_light, dynamic_light, ambient_light)` with subtle color tinting when dynamic light dominates.

## Key Constraints

- **Thread safety**: Any code that touches chunk terrain data must acquire the chunk's mutex. Terrain generators and ChunkLoader must not call Godot scene tree APIs.
- **Frame budget**: Chunk builds and removals are capped per frame to prevent stuttering. These limits are in `GlobalSettings`.
- **Chunk pooling**: Chunks are recycled from a pool (up to `MAX_CHUNK_POOL_SIZE`) to avoid instantiation overhead. Don't create chunk instances directly — use the pool in ChunkManager.
- **Y-inversion**: The `_generate_visual_image` method in ChunkLoader and the `edit_tiles` method in Chunk both apply Y-inversion when writing to the Image. This is required for correct rendering alignment between the PackedByteArray data layout and Image coordinate system. Do not remove it.
- **Coordinate convention**: Standard Godot Y-down (`+Y = down`). Gravity is positive (800), jump velocity is negative (-400).
