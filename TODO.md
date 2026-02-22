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
- [x] Screen shake and effects

### 9. Entity System Foundation

- [x] BaseEntity class with position, velocity, collision box, optional MovementController
- [x] EntityManager with spawn/despawn lifecycle and monotonic ID assignment
- [x] Entity signals on SignalBus (`entity_spawned`, `entity_despawned`)
- [x] Wired into GameInstance and GameServices
- [x] Entity spawn/despawn through ChunkManager awareness

## Phase 4: Physics & Visuals (Complete)

### 10. Collision Extensions

- [x] Raycast queries (DDA algorithm for line-of-sight, projectiles)
- [x] Area queries (AABB and circle for explosion radius, detection zones)
- [x] Collision responses driven by tile properties (friction modifier, damage detection, floor tile tracking)
- [ ] Moving tile support & physics-based tiles (rope bridge, falling sand, broken fragments etc.)

### 11. Lighting System

- [x] Light data channel in terrain (B channel of RGBA8 chunk data image)
- [x] Light propagation algorithm (BFS flood fill with per-tile light filtering)
- [x] Dynamic light sources (emissive tiles via TileIndex emission property)
- [x] Day/night cycle support (ambient_light shader uniform)
- [x] Emissive tiles (emission + light_filter tile properties)
- [x] Cross-chunk border light propagation

## Phase 5: Content & Gameplay (Planned)

### 12. Biome System

- [ ] Biome definition format (tile palette, generator params, spawn rules)
- [ ] Biome map generation (Voronoi or noise-based region assignment)
- [ ] Biome-aware terrain generator (swap palettes per biome)
- [ ] Biome transitions / blending at boundaries

### 13. Expanded Tile Set

- [ ] Sand, Water, Gravel, Clay, Snow, Ice tile types
- [ ] Ore tiles (Coal, Iron, Gold, etc.)
- [ ] Decorative tiles (Flowers, Mushrooms, Vines)
- [ ] Animated tiles (water flow, lava, fire, tree leaves sway)
- [ ] Living tiles (trees that actually grow, grass spreading, vines that climb or drop)

### 14. Health & Damage System

- [ ] Health component (reusable, attachable to any entity)
- [ ] Damage sources (fall damage, hazardous tiles, entity attacks)
- [ ] Death and respawn logic
- [ ] Invincibility frames / knockback

### 15. Updated Movement Controller

- [ ] Update player movement to support slippery tiles (ice), sticky tiles (mud), and damaging tiles (lava)
- [ ] Add support for tile-based movement modifiers (e.g. speed boost on ice, slow on mud)
- [ ] Make sure controller handles walls, slopes, moving platforms, and other complex terrain features

### 16. Tools & Mining

- [ ] Tool types with mining speed multipliers
- [ ] Tool durability system
- [ ] Tile hardness (time-to-break per tile type)
- [ ] Mining particles / break animation

## Phase 6: Multiplayer (Planned)

### 17. Multiplayer Support

- [ ] Networked entity synchronization (position, state)
- [ ] Chunk data synchronization on player join
- [ ] LAN multiplayer support with Godot's high-level networking API

## Phase 7: Infrastructure & Tooling (Planned)

### 18. CI / CD

- [ ] GitHub Actions workflow for headless test suite
- [ ] Automated export builds (Linux, Windows, macOS)
- [ ] Lint / static analysis pass (gdlint or equivalent)
- [ ] Version tagging and changelog generation

### 19. Performance Profiling

- [ ] Built-in frame time graph (beyond current debug HUD)
- [ ] Chunk generation throughput metrics
- [ ] Memory usage tracking (chunk pool, texture memory)
- [ ] Bottleneck identification tooling

### 20. Asset Pipeline

- [ ] Texture atlas auto-packing (beyond manual Texture2DArray)
- [ ] Tile definition files (JSON/Resource) instead of code-only registration
- [ ] Asset hot-reload support for rapid iteration
- [ ] Sprite sheet support for animated tiles

## Human TODO

- Update `README.md` with screenshots once terrain generation is more visually interesting.
- Create contribution guidelines if the project goes public.
