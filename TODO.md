# Engine Improvement Roadmap

## Phase 1: Core Engine Abstractions (Complete)

### 1. Data-Driven Tile Registry

- [x] Replace hardcoded `TileIndex` with data-driven registry
- [x] `register_tile(id, name, solid, texture_path, color)` API
- [x] Build `Texture2DArray` from registered tiles for shader
- [x] Update shader to use `sampler2DArray` instead of individual uniforms
- [x] Update `Chunk` to set texture array from registry
- [x] Update `EditingToolbar` to generate material buttons dynamically
- [x] Update `chunk.tscn` to remove hardcoded texture references
- [x] Backward-compatible: AIR/DIRT/GRASS/STONE constants preserved

### 2. Pluggable Terrain Generator

- [x] Create `BaseTerrainGenerator` abstract base class
- [x] Rename `TerrainGenerator` → `SimplexTerrainGenerator`
- [x] `ChunkLoader` accepts any `BaseTerrainGenerator` via constructor
- [x] `ChunkManager` creates generator and passes to loader
- [x] Data-driven config: generator parameters in dictionary
- [x] Support for future biome-aware generators

### 3. Headless Test Framework

- [x] Test runner script for `godot --headless --script`
- [x] Unit tests for TileRegistry (registration, lookup, texture array)
- [x] Unit tests for TerrainGenerator (chunk generation, data format, interface)

## Phase 2: Persistence & Signals (Complete)

### 4. Save/Load System

- [x] World serialization format (chunk data + metadata)
- [x] Chunk-level save/load (only modified chunks)
- [x] World metadata (seed, generator config, version)
- [x] Auto-save on chunk unload

### 5. Signal Bus Expansion

- [x] `tile_changed(world_pos, old_tile, new_tile)` signal
- [x] `chunk_loaded(chunk_pos)` / `chunk_unloaded(chunk_pos)` signals
- [x] `world_ready` signal (initial chunks loaded)
- [x] Decouple systems further through events

## Phase 3: Engine API & Core Systems (Complete)

### 6. GameServices as Engine API

- [x] Formalize GameServices as the public engine API
- [x] Add `tile_registry` reference to GameServices
- [x] Add `terrain_generator` reference to GameServices
- [x] Add `world_save_manager` and `entity_manager` references
- [x] ChunkManager exposes `get_terrain_generator()` getter
- [x] GameInstance registers all services in `_ready()`

### 7. Tile Properties System

- [x] Extend tile registration with arbitrary properties (friction, transparency, damage, hardness)
- [x] `DEFAULT_PROPERTIES` dict with defaults-merge pattern
- [x] Property lookup API on TileIndex (`get_tile_property()`, `get_friction()`, `get_damage()`, `get_transparency()`, `get_hardness()`)
- [x] Update collision system to use `TileIndex.is_solid()` instead of `tile_id > 0`
- [x] Foundation for movement modifiers, lighting, and gameplay systems

### 8. Camera System

- [x] CameraController decoupled from Player (`src/camera/camera_controller.gd`)
- [x] Smooth follow with frame-rate independent lerp
- [x] Mouse wheel zoom with configurable step and limits
- [x] Zoom presets (1x/2x/4x/8x) cycled with Z key
- [x] Screen shake via `apply_shake(intensity, duration)` method

### 9. Entity System Foundation

- [x] BaseEntity class with position, velocity, collision box, optional MovementController
- [x] EntityManager with spawn/despawn lifecycle and monotonic ID assignment
- [x] Entity signals on SignalBus (`entity_spawned`, `entity_despawned`)
- [x] Wired into GameInstance and GameServices
- [x] Entity-chunk awareness: serialize/despawn on chunk unload, respawn on chunk load

## Phase 4: Physics & Visuals (Complete)

### 10. Collision Extensions

- [x] Raycast queries via DDA grid traversal (`raycast()` on CollisionDetector)
- [x] Area queries (`query_area()` on CollisionDetector)
- [x] `get_tile_id_at_world_pos()` on ChunkManager for lightweight tile lookups
- [x] `hit_tile_ids` populated in `sweep_aabb()` results (backwards compatible)

### 11. Lighting System

- [x] Light emission property on TileIndex (`light_emission: 0-15`)
- [x] B channel in terrain image carries baked light level (0.0–1.0)
- [x] Static light baking via LightBaker (sunlight + emissive + BFS flood fill)
- [x] Cross-chunk border light propagation from neighbor chunks
- [x] Automatic rebake on terrain edits (edited chunk + neighbors)
- [x] Dynamic point lights via LightManager (up to 16, quadratic falloff in shader)
- [x] Day/night cycle via TimeOfDay (sine curve, 10-min default cycle)
- [x] Ambient light uniform modulates baked sunlight per time of day

### 12. Updated Movement Controller

- [x] Tile-driven friction (`use_tile_friction` opt-in, modulates by `TileIndex.get_friction()`)
- [x] Tile damage callback (`use_tile_damage` + `on_tile_damage: Callable`)
- [x] Exposed `last_floor_tile_ids` / `last_wall_tile_ids` for external systems

## Phase 5: More stuff

## Phase 6: Multiplayer (Planned)

### 15. Multiplayer Support

- [ ] Networked entity synchronization (position, state)
- [ ] Chunk data synchronization on player join
- [ ] LAN multiplayer support with Godot's high-level networking API

## Phase 7: Infrastructure & Tooling (Planned)

### 19. Performance Profiling

- [ ] Built-in frame time graph (beyond current debug HUD)
- [ ] Chunk generation throughput metrics
- [ ] Memory usage tracking (chunk pool, texture memory)
- [ ] Bottleneck identification tooling

### 20. Asset Pipeline

- [ ] Tile definition files (JSON/Resource) instead of code-only registration

## Human TODO

- Update `README.md` with screenshots once terrain generation is more visually interesting.
- Create contribution guidelines if the project goes public.
