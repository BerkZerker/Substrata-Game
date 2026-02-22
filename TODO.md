# Engine Improvement Roadmap

## Phase 1: Core Engine Abstractions (Current)

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

## Phase 2: Persistence & Signals (Current)

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

## Phase 3: Engine API Surface (Planned)

### 6. GameServices as Engine API

- [ ] Formalize GameServices as the public engine API
- [ ] Add `tile_registry` reference to GameServices
- [ ] Add `terrain_generator` reference to GameServices
- [ ] Document the API contract for each service

### 7. Entity System

- [ ] Base entity class with position, velocity, collision
- [ ] Entity registry and lifecycle management
- [ ] Entity spawn/despawn through ChunkManager awareness

### 8. Multiplayer Support

- [ ] Networked entity synchronization (position, state)
- [ ] Chunk data synchronization on player join
- [ ] LAN multiplayer support with Godot's high-level networking API

## Phase 4: Visual & Physics Enhancements (Planned)

### 9. Collision Extensions

- [ ] Raycast queries (line-of-sight, projectiles)
- [ ] Area queries (explosion radius, detection zones)
- [ ] Collision based on tile properties (e.g. slippery ice, damaging lava, solid stone, liquid water)
- [ ] Moving tile support & physics-based tiles (rope bridge, falling sand, broken fragements etc.)

### 10. Lighting System

- [ ] Light data channel in terrain (cell_id or separate array)
- [ ] Light propagation algorithm (flood fill or see if engine has built in tools that would work)
- [ ] Dynamic light sources (torches, sun)
- [ ] Day/night cycle support
- [ ] Emissive tiles (glowing mushrooms, lava)

### 11. Camera System

- [ ] Camera controller decoupled from Player
- [ ] Smooth follow with configurable lag
- [ ] Screen shake and effects
- [ ] Zoom presets and limits

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
- [ ] Tile properties beyond solidity (transparency, friction, damage)
- [ ] Animated tiles (water flow, lava, fire, tree leaves sway)
- [ ] Living tiles (trees that actually grow, grass spreading, vines that climb or drop)

### 14. Health & Damage System

- [ ] Health component (reusable, attachable to any entity)
- [ ] Damage sources (fall damage, hazardous tiles, entity attacks)
- [ ] Death and respawn logic
- [ ] Invincibility frames / knockback

### 15. Updated Movement Controller

- Update player movement to support slippery tiles (ice), sticky tiles (mud), and damaging tiles (lava)
- Add support for tile-based movement modifiers (e.g. speed boost on ice, slow on mud)
- Make sure controller handles walls, slopes, moving platforms, and other complex terrain features

### 16. Tools & Mining

- [ ] Tool types with mining speed multipliers
- [ ] Tool durability system
- [ ] Tile hardness (time-to-break per tile type)
- [ ] Mining particles / break animation

## Phase 6: Infrastructure & Tooling (Planned)

### 17. CI / CD

- [ ] GitHub Actions workflow for headless test suite
- [ ] Automated export builds (Linux, Windows, macOS)
- [ ] Lint / static analysis pass (gdlint or equivalent)
- [ ] Version tagging and changelog generation

### 18. Performance Profiling

- [ ] Built-in frame time graph (beyond current debug HUD)
- [ ] Chunk generation throughput metrics
- [ ] Memory usage tracking (chunk pool, texture memory)
- [ ] Bottleneck identification tooling

### 19. Asset Pipeline

- [ ] Texture atlas auto-packing (beyond manual Texture2DArray)
- [ ] Tile definition files (JSON/Resource) instead of code-only registration
- [ ] Asset hot-reload support for rapid iteration
- [ ] Sprite sheet support for animated tiles

## Human TODO

- Update `README.md` with screenshots once terrain generation is more visually interesting.
- Create contribution guidelines if the project goes public.
