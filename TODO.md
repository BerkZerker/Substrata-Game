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

## Phase 2: Persistence & Signals (Planned)

### 4. Save/Load System
- [ ] World serialization format (chunk data + metadata)
- [ ] Chunk-level save/load (only modified chunks)
- [ ] World metadata (seed, generator config, version)
- [ ] Auto-save on chunk unload

### 5. Signal Bus Expansion
- [ ] `tile_changed(world_pos, old_tile, new_tile)` signal
- [ ] `chunk_loaded(chunk_pos)` / `chunk_unloaded(chunk_pos)` signals
- [ ] `world_ready` signal (initial chunks loaded)
- [ ] Decouple systems further through events

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
- [ ] AI controller interface for NPCs/mobs

## Phase 4: Visual & Physics Enhancements (Planned)

### 8. Collision Extensions
- [ ] Raycast queries (line-of-sight, projectiles)
- [ ] Area queries (explosion radius, detection zones)
- [ ] Collision layers per tile type
- [ ] Moving platform support

### 9. Lighting System
- [ ] Light data channel in terrain (cell_id or separate array)
- [ ] Light propagation algorithm (flood fill)
- [ ] Dynamic light sources (torches, sun)
- [ ] Day/night cycle support

### 10. Camera System
- [ ] Camera controller decoupled from Player
- [ ] Smooth follow with configurable lag
- [ ] Screen shake and effects
- [ ] Zoom presets and limits

## Human TODO

- Update `README.md` with screenshots once terrain generation is more visually interesting.
