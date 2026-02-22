# Implementation Report — Substrata Engine Feature Sprint

**Date:** 2026-02-22
**Scope:** TODO items from Phase 4 through Phase 7
**Method:** 3 waves of parallel agent teams (10 agents total) + manual performance fix

---

## Summary

Implemented **27 TODO items** across 3 waves using parallel agent teams, each agent running in an isolated git worktree. All changes were merged, tested (155 tests passing), and pushed after each wave.

### Performance Fix

A critical 1 FPS performance regression was identified and fixed after wave 3. The `TileSimulation` system was scanning ~1.1 million tiles every 3 frames due to an oversized radius calculation (`LOD_RADIUS * REGION_SIZE = 16` chunk radius instead of a reasonable value). It was also calling `set_tiles_at_world_positions()` which triggers full light recalculation with cascading propagation. The fix uses dirty-chunk tracking, direct `edit_tiles()` calls, and strict frame budgets.

---

## Wave 1 — Core Gameplay (4 agents)

### Agent: `dynamic-lights`

**Files created:**

- `src/world/lighting/dynamic_light_manager.gd` — Manages up to 64 GPU-side dynamic lights, packs into 1D RGBAF data texture per frame via `RenderingServer.global_shader_parameter_*`

**Files modified:**

- `src/world/chunks/terrain.gdshader` — Added `global uniform` for dynamic light data, loops over lights with quantized distance falloff (`floor(falloff * radius) / radius`), subtle color tinting
- `src/globals/game_services.gd` — Added `dynamic_light_manager` property
- `src/game/game_instance.gd` — Creates and registers DynamicLightManager
- `src/entities/player.gd` — Player torch light (T key toggle), radius 12, warm color

**API:**

- `add_light(pos, radius, intensity, color) -> id`
- `remove_light(id)`
- `update_light_position(id, pos)`
- `add_transient_light(pos, radius, intensity, ttl, color) -> id`

### Agent: `biome-system`

**Files created:**

- `src/world/biomes/biome_definition.gd` — RefCounted: biome_name, tile_palette (surface/subsurface/deep/cliff), generator_params, color
- `src/world/biomes/biome_map.gd` — FastNoiseLite Cellular/Voronoi noise for biome region assignment, thread-safe
- `src/world/generators/biome_terrain_generator.gd` — Extends BaseTerrainGenerator, queries BiomeMap per column, blends heightmaps at boundaries (16-tile radius)
- `assets/textures/sand.png`, `snow.png`, `ice.png` — 16x16 placeholder textures

**Files modified:**

- `src/world/chunks/chunk_manager.gd` — Switched from SimplexTerrainGenerator to BiomeTerrainGenerator, defines 5 default biomes: Plains, Desert, Tundra, Forest, Mountains

### Agent: `health-damage`

**Files created:**

- `src/components/health_component.gd` — Composable RefCounted: max_health, current_health, invincibility timer, take_damage(), heal(), is_dead(), reset()

**Files modified:**

- `src/globals/signal_bus.gd` — Added `entity_damaged`, `entity_died`, `entity_healed` signals
- `src/globals/tile_index.gd` — Added `speed_modifier` property (default 1.0), `get_speed_modifier()` helper
- `src/physics/movement_controller.gd` — Reads speed_modifier from floor tile, reduces acceleration on low-friction surfaces
- `src/entities/player.gd` — Integrated HealthComponent, fall damage (threshold 500 px/s), tile damage per-second, death/respawn (1s delay), invincibility visual flicker, knockback on damage

### Agent: `tiles-mining`

**Files created:**

- `assets/textures/` — 13 new 16x16 PNG textures (gravel, clay, coal_ore, iron_ore, gold_ore, water, lava, flowers, mushroom, vines, plus sand/snow/ice already existed)
- `src/items/tool_definition.gd` — RefCounted: tool_name, mining_speed, durability, tool_level. Factory methods for Hand/Wood/Stone/Iron pickaxes
- `src/gui/mining_system.gd` — Tracks mining progress per tile, mining_time = hardness / tool.mining_speed

**Files modified:**

- `src/globals/tile_index.gd` — Registered 13 new tiles (SAND=4 through VINES=16) with properties
- `src/gui/editing_toolbar.gd` — Changed to GridContainer (5 columns) for 17 tiles
- `src/gui/gui_manager.gd` — Right-click mining, Shift+1-4 tool switching, tool label display

---

## Wave 2 — Polish & Infrastructure (4 agents)

### Agent: `visuals`

**Files modified:**

- `src/world/chunks/terrain.gdshader` — Water animation (layered sine wave UV distortion + brightness shimmer), lava animation (roiling UV distortion + color pulsing), uses built-in TIME uniform
- `src/gui/gui_manager.gd` — Mining particles: CPUParticles2D with 12 particles, tile-colored, gravity-affected, 0.5s lifetime, auto-cleanup

### Agent: `ci-cd`

**Files created:**

- `.github/workflows/test.yml` — Runs on push/PR, uses `barichello/godot-ci:4.6.1` Docker image, headless test execution
- `.github/workflows/build.yml` — Runs on version tags, matrix build for Linux/Windows/macOS, uploads artifacts
- `export_presets.cfg` — Export presets for 3 platforms
- `VERSION` — Set to `0.1.0`

### Agent: `profiling`

**Files created:**

- `src/gui/frame_graph.gd` — 120-frame history bar chart, color-coded (green/yellow/red), FPS + avg + 1% low stats, toggled with F7

**Files modified:**

- `src/world/chunks/chunk_loader.gd` — Added chunk generation timing (chunks/s, avg time, total count), mutex-protected metrics
- `src/world/chunks/chunk_manager.gd` — Pool size and texture memory estimates in debug info
- `src/gui/debug_hud.gd` — Added generation stats and memory sections
- `src/gui/controls_overlay.gd` — Listed F7 toggle
- `project.godot` — Added `toggle_frame_graph` input action

### Agent: `asset-pipeline`

**Files created:**

- `assets/tiles/tiles.json` — All 17 tile definitions in JSON format

**Files modified:**

- `src/globals/tile_index.gd` — Added `_load_tiles_from_json()` pipeline: scans `res://assets/tiles/` for JSON files, parses tile definitions, falls back to hardcoded registration if no JSON found. Supports both `{"tiles": [...]}` and bare array formats.

---

## Wave 3 — Simulation (2 agents)

### Agent: `falling-sand`

**Files created:**

- `src/world/simulation/tile_simulation.gd` — Gravity simulation for sand/gravel tiles

**Files modified:**

- `src/globals/tile_index.gd` — Added `gravity_affected` property + `get_gravity_affected()` helper
- `assets/tiles/tiles.json` — Set `gravity_affected: true` on Sand and Gravel
- `src/game/game_instance.gd` — Wired TileSimulation

### Agent: `living-tiles`

**Files created:**

- `src/world/simulation/tile_growth.gd` — Random tick growth: grass spreads to adjacent exposed dirt (10% chance), vines grow downward (5% chance, max 10 segments)

**Files modified:**

- `src/globals/tile_index.gd` — Added `growth_type` property + `get_growth_type()` helper
- `src/world/chunks/chunk_manager.gd` — Added `get_loaded_chunk_positions()` API
- `assets/tiles/tiles.json` — Set growth_type on Grass and Vines
- `src/game/game_instance.gd` — Wired TileGrowthSystem

---

## Post-Wave Performance Fix

**Root cause:** `TileSimulation._simulate_gravity()` used `radius = LOD_RADIUS * REGION_SIZE = 4 * 4 = 16`, scanning (16×2+1)² = 1,089 chunks × 1,024 tiles = **~1.1 million tiles every 3 frames**. Each gravity-affected tile also called `get_tile_at_world_pos()` (chunk lookup + mutex). The batch result then called `set_tiles_at_world_positions()` which triggers **full light recalculation with cascading propagation**.

**Fix applied:**

1. **Dirty-chunk tracking** — Only scan chunks where gravity tiles were recently placed (via `tile_changed` signal)
2. **Direct `edit_tiles()`** instead of `set_tiles_at_world_positions()` — Skips light recalculation (sand doesn't emit/block light meaningfully)
3. **Strict budgets** — Max 4 chunks/tick, 48 moves/tick, 6-frame interval
4. **Fast path** — Within-chunk swaps use direct PackedByteArray indexing, no chunk lookups
5. **TileGrowthSystem** also tuned — 2s interval (was 0.8s), 32 samples (was 64), cached chunk positions

---

## Final State

### TODO Completion

| Phase                        | Items Done | Items Remaining                                                    |
| ---------------------------- | ---------- | ------------------------------------------------------------------ |
| Phase 4 (Physics & Visuals)  | 12/13      | Moving platforms (needs design)                                    |
| Phase 5 (Content & Gameplay) | 17/19      | Slopes/platforms, entity attack wiring                             |
| Phase 6 (Multiplayer)        | 0/3        | Too large for automated implementation                             |
| Phase 7 (Infrastructure)     | 6/12       | Lint, atlas packing, hot-reload, sprite sheets, bottleneck tooling |

### Stats

- **10 agents** spawned across 3 waves
- **155 tests** passing (0 failures)
- **~2,500 lines** of new code
- **35+ files** created or modified
- **13 new tile textures** generated
- **5 biomes** defined
- **4 tool tiers** implemented
- **6 commits** pushed to main

### New Systems

| System            | File                                              | Type       |
| ----------------- | ------------------------------------------------- | ---------- |
| Dynamic Lights    | `src/world/lighting/dynamic_light_manager.gd`     | Node       |
| Biome Definitions | `src/world/biomes/biome_definition.gd`            | RefCounted |
| Biome Map         | `src/world/biomes/biome_map.gd`                   | RefCounted |
| Biome Generator   | `src/world/generators/biome_terrain_generator.gd` | RefCounted |
| Health Component  | `src/components/health_component.gd`              | RefCounted |
| Tool Definition   | `src/items/tool_definition.gd`                    | RefCounted |
| Mining System     | `src/gui/mining_system.gd`                        | RefCounted |
| Frame Graph       | `src/gui/frame_graph.gd`                          | Control    |
| Tile Simulation   | `src/world/simulation/tile_simulation.gd`         | Node       |
| Tile Growth       | `src/world/simulation/tile_growth.gd`             | Node       |

### New Controls

| Key         | Action                              |
| ----------- | ----------------------------------- |
| T           | Toggle player torch                 |
| Shift+1-4   | Switch tools (Hand/Wood/Stone/Iron) |
| Right-click | Mine tile (hold to progress)        |
| F7          | Toggle frame time graph             |
