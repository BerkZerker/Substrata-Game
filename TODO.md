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

## Phase 5: Content & Gameplay (Planned)

### 11. Biome System
- [ ] Biome definition format (tile palette, generator params, spawn rules)
- [ ] Biome map generation (Voronoi or noise-based region assignment)
- [ ] Biome-aware terrain generator (swap palettes per biome)
- [ ] Biome transitions / blending at boundaries

### 12. Expanded Tile Set
- [ ] Sand, Water, Gravel, Clay, Snow, Ice tile types
- [ ] Ore tiles (Coal, Iron, Gold, etc.)
- [ ] Decorative tiles (Flowers, Mushrooms, Vines)
- [ ] Tile properties beyond solidity (transparency, friction, damage)

### 13. Health & Damage System
- [ ] Health component (reusable, attachable to any entity)
- [ ] Damage sources (fall damage, hazardous tiles, entity attacks)
- [ ] Death and respawn logic
- [ ] Invincibility frames / knockback

### 14. Inventory & Crafting
- [ ] Inventory data model (item stacks, slot management)
- [ ] Inventory UI (hotbar + grid)
- [ ] Item pickup / drop mechanics
- [ ] Basic crafting recipes (tile → item conversions)

### 15. Tools & Mining
- [ ] Tool types with mining speed multipliers
- [ ] Tool durability system
- [ ] Tile hardness (time-to-break per tile type)
- [ ] Mining particles / break animation

## Phase 6: Audio (Planned)

### 16. Sound Effects
- [ ] Audio manager singleton (pooled AudioStreamPlayer nodes)
- [ ] Tile interaction sounds (place, break, footstep per tile type)
- [ ] Player sounds (jump, land, damage, death)
- [ ] UI sounds (button clicks, inventory open/close)

### 17. Music & Ambient
- [ ] Background music system (crossfade, playlist)
- [ ] Ambient sound layers (wind, caves, water)
- [ ] Biome-specific audio profiles
- [ ] Volume controls (master, music, SFX, ambient)

## Phase 7: UI / UX (Planned)

### 18. Main Menu & Game Flow
- [ ] Main menu scene (New World, Load World, Settings, Quit)
- [ ] World creation screen (seed input, generator selection)
- [ ] Pause menu (Resume, Settings, Save & Quit)
- [ ] Loading screen with progress bar during world generation

### 19. Settings Menu
- [ ] Graphics settings (render distance, VSync, fullscreen)
- [ ] Audio settings (volume sliders)
- [ ] Controls settings (key rebinding)
- [ ] Settings persistence (save/load to user config file)

### 20. HUD Improvements
- [ ] Health bar display
- [ ] Hotbar with selected item highlight
- [ ] Minimap or chunk-level overview
- [ ] Toast / notification system for events

## Phase 8: Infrastructure & Tooling (Planned)

### 21. CI / CD
- [ ] GitHub Actions workflow for headless test suite
- [ ] Automated export builds (Linux, Windows, macOS)
- [ ] Lint / static analysis pass (gdlint or equivalent)
- [ ] Version tagging and changelog generation

### 22. Performance Profiling
- [ ] Built-in frame time graph (beyond current debug HUD)
- [ ] Chunk generation throughput metrics
- [ ] Memory usage tracking (chunk pool, texture memory)
- [ ] Bottleneck identification tooling

### 23. Asset Pipeline
- [ ] Texture atlas auto-packing (beyond manual Texture2DArray)
- [ ] Tile definition files (JSON/Resource) instead of code-only registration
- [ ] Asset hot-reload support for rapid iteration
- [ ] Sprite sheet support for animated tiles

## Human TODO

- Update `README.md` with screenshots once terrain generation is more visually interesting.
- Create contribution guidelines if the project goes public.
- Evaluate Godot 4.x LTS migration path when available.
