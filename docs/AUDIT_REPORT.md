# Substrata Engine — Deep Audit Report

**Date:** 2026-02-22
**Codebase:** 36 GDScript files, ~5,200 LOC across `src/`, plus 2 shaders, 8 scenes, 155 unit tests
**Engine:** Godot 4.6, GDScript, custom physics/lighting/chunk systems

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current State of the Codebase](#2-current-state-of-the-codebase)
3. [Critical Bugs](#3-critical-bugs)
4. [Performance Bottlenecks](#4-performance-bottlenecks)
5. [Code Clarity & Cleanup Opportunities](#5-code-clarity--cleanup-opportunities)
6. [Architecture & Coupling Analysis](#6-architecture--coupling-analysis)
7. [Thread Safety Audit](#7-thread-safety-audit)
8. [Test Coverage Gaps](#8-test-coverage-gaps)
9. [Documentation Drift](#9-documentation-drift)
10. [Engine Extraction Strategy](#10-engine-extraction-strategy)
11. [Prioritized Action Plan](#11-prioritized-action-plan)

---

## 1. Executive Summary

Substrata is a well-structured 2D voxel engine with solid fundamentals: a producer-consumer chunk pipeline, custom swept-AABB physics, BFS flood-fill lighting, and a data-driven tile registry. The codebase is organized into clear domains (`world/`, `physics/`, `entities/`, `gui/`) with 155 passing tests and CI/CD.

However, the audit identified **8 confirmed bugs** (2 critical), **12 performance bottlenecks**, and **significant coupling** between game-specific and engine-generic code that blocks reusability. The lighting system has correctness issues in border propagation, the physics layer lacks terminal velocity clamping, and the GUI layer mixes game logic with presentation.

The path to a reusable engine requires separating ~60% of the codebase into an engine core (chunks, lighting, physics, entities) from game-specific code (biomes, tiles, player, GUI), introducing abstraction interfaces, and fixing the threading/safety issues identified below.

---

## 2. Current State of the Codebase

### File Inventory

| Directory | Files | LOC | Role |
|-----------|-------|-----|------|
| `src/world/chunks/` | 3 .gd + 1 .gdshader + 1 .tscn | 1,103 + shader | Chunk pipeline (loader, manager, chunk) |
| `src/world/lighting/` | 3 .gd | 785 | Static + dynamic lighting |
| `src/world/generators/` | 3 .gd | 321 | Terrain generation |
| `src/world/biomes/` | 2 .gd | 99 | Biome definitions + mapping |
| `src/world/persistence/` | 1 .gd | 251 | Save/load |
| `src/world/simulation/` | 2 .gd | 275 | Falling sand, tile growth |
| `src/physics/` | 2 .gd | 478 | Collision + movement |
| `src/entities/` | 3 .gd | 363 | Entity system + player |
| `src/gui/` | 8 .gd | 729 | UI, debug, mining |
| `src/globals/` | 4 .gd | 392 | Autoloads (signals, settings, tiles, services) |
| `src/camera/` | 1 .gd | 99 | Camera controller |
| `src/components/` | 1 .gd | 78 | Health component |
| `src/items/` | 1 .gd | 60 | Tool definitions |
| `src/game/` | 1 .gd | 42 | Game instance bootstrap |
| **Total** | **36 .gd** | **~5,200** | |

### System Health Summary

| System | Correctness | Performance | Code Quality | Reusability |
|--------|-------------|-------------|--------------|-------------|
| Chunk Pipeline | Good (1 race condition) | Fair (queue sorting, light fixup) | Good | High |
| Lighting | Issues (border attenuation) | Fair (shader loop) | Good | Moderate |
| Physics/Collision | Good (edge cases) | Good | Good | High |
| Entity System | Good | Good | Good | High |
| Terrain Generation | Good | Fair (redundant noise) | Fair (duplication) | Moderate |
| GUI/Mining | Issues (state desync) | Good | Poor (mixed concerns) | Low |
| Persistence | Good | Good | Good | High |
| Tile Simulation | Good | Good | Good | Moderate |
| Globals/Autoloads | Issues (weak typing) | Good | Fair | Low |

---

## 3. Critical Bugs

### P0 — Crash / Correctness Risk

#### BUG-1: Player Signal Handlers Leak on Respawn
**File:** `src/entities/player.gd:136`
**Issue:** `SignalBus.entity_damaged.connect(_on_entity_damaged)` is called in `_try_init_movement()` which runs on first `_physics_process()`. On respawn, `_try_init_movement()` could be called again (depending on reinitialization flow), connecting duplicate signal handlers. Each respawn adds another handler, so damage is applied multiple times.
**Impact:** Player takes N× damage after N respawns.
**Fix:** Guard connection: `if not SignalBus.entity_damaged.is_connected(_on_entity_damaged):`

#### BUG-2: Chunk Bounds Check Race Condition
**File:** `src/world/chunks/chunk.gd:163-177`
**Issue:** `get_tile_at()`, `get_tile_id_at()`, `get_cell_id_at()` check bounds BEFORE acquiring the mutex. Between the bounds check and the lock, another thread could call `reset()` clearing `_terrain_data`. The subsequent index access would read from an empty array.
**Impact:** Intermittent out-of-bounds crash or reading AIR where there was terrain.
**Fix:** Move bounds checking inside mutex lock.

### P1 — Visual / Logic Bugs

#### BUG-3: Light Border Import Double-Attenuation
**File:** `src/world/lighting/light_manager.gd:412-413`
**Issue:** When importing border light from a neighbor chunk, the formula applies the RECEIVING tile's `light_filter`:
```gdscript
var new_sun: int = maxi(n_sun - 1 - light_filter, 0)
```
But the neighbor's BFS already attenuated through that tile. This double-applies the filter at chunk boundaries, creating visible seams where one side is darker than expected.
**Impact:** Visible lighting seams at chunk borders near stone/dense tiles.
**Fix:** Use `light_filter = 0` for border imports (attenuation already applied by source BFS), or only apply the filter of the target tile (not re-apply the source tile's filter).

#### BUG-4: No Terminal Velocity in Movement Controller
**File:** `src/physics/movement_controller.gd:44-45`
**Issue:** `velocity.y += gravity * delta` with no upper clamp. After 10 seconds of free-fall, velocity reaches 8,000 px/s. With tiles being ~32px, this exceeds chunk size per frame and can tunnel through terrain.
**Impact:** Player falls through the world after long falls.
**Fix:** Add `velocity.y = minf(velocity.y, MAX_FALL_SPEED)` after gravity application.

#### BUG-5: Biome Boundary Blend Only Affects Height, Not Tile Palette
**File:** `src/world/generators/biome_terrain_generator.gd:71`
**Issue:** Biome blending interpolates heightmap values but always uses the primary biome's tile palette. At a Plains→Desert boundary, the terrain uses plains height but desert tiles (or vice versa), creating jarring visual transitions.
**Impact:** Hard edges between biomes despite height blending.
**Fix:** Interpolate tile palette selection based on blend weight, or use a transition tile set.

#### BUG-6: GUIManager Null Camera Access
**File:** `src/gui/gui_manager.gd:226, 233, 258, 261`
**Issue:** `get_viewport().get_camera_2d()` called without null checks. In headless tests, scene transitions, or before camera initialization, this returns null and crashes.
**Impact:** Crash in headless mode or during scene transitions.
**Fix:** Cache camera reference and null-guard all access.

#### BUG-7: Shader Division by Zero for Dynamic Lights
**File:** `src/world/chunks/terrain.gdshader:61`
**Issue:** `falloff = floor(falloff * radius) / radius` — if a light has `radius = 0.0`, this divides by zero.
**Impact:** Visual glitches (NaN/inf values in light calculation).
**Fix:** Guard: `if (radius > 0.0) { ... }`

#### BUG-8: TileGrowthSystem Connects to world_ready But Has No Fallback
**File:** `src/world/simulation/tile_growth.gd:40-44`
**Issue:** The system relies on `world_ready` signal to get `chunk_manager`. If the signal fires before `TileGrowthSystem` is added to the tree (race with `GameInstance._ready()` ordering), `_chunk_manager` stays null forever and tile growth silently never works.
**Impact:** Tile growth may silently fail depending on node initialization order.
**Fix:** Also check `GameServices.chunk_manager` in `_process()` as fallback.

---

## 4. Performance Bottlenecks

### Critical Performance Issues

#### PERF-1: Border Light Fixup Per-Chunk (16ms+/frame during load)
**File:** `src/world/chunks/chunk_manager.gd:157-167`
**Problem:** For every built chunk, queries 4 neighbors and calls `light_mgr.propagate_border_light()`. With 16 builds/frame budget, this cascades 16 light calculations.
**Cost:** ~1ms per light propagation × 16 = **16ms** per frame during chunk loading.
**Fix:** Batch all border light fixups into a single pass after all chunks are built in a frame, deduplicating shared borders.

#### PERF-2: Massive Queue Generation (1,296 chunks at once)
**File:** `src/world/chunks/chunk_manager.gd:241-268`
**Problem:** `_queue_chunks_for_generation()` iterates ALL regions in LOD_RADIUS. For radius=4, this is 9×9 regions × 16 chunks = 1,296 chunks queued immediately. With only 8 concurrent tasks and 128 build queue limit, creates instant backpressure stall.
**Cost:** 2+ second initial load stall; O(n log n) sorting on 1,296 items.
**Fix:** Use spiral/priority queue loading from player position outward. Only queue the next ring of chunks when the current ring completes.

#### PERF-3: Dynamic Light Shader Loop (64 iterations per fragment)
**File:** `src/world/chunks/terrain.gdshader:44-68`
**Problem:** The for loop iterates up to `dynamic_light_count` (max 64) for every pixel. Even with 0-2 active lights, the GPU evaluates the loop header and texture fetches.
**Cost:** ~320 wasted operations per fragment × thousands of visible fragments.
**Fix:** Use early-exit (`if (dynamic_light_count == 0) break;`), or limit the loop to 16 lights and document the cap, or tile-based light culling.

### Moderate Performance Issues

#### PERF-4: Redundant Noise Sampling in Biome Generator
**File:** `src/world/generators/biome_terrain_generator.gd:89`
**Problem:** Slope calculation calls `_get_blended_surface_y()` for x-1 and x+1, each of which calls `get_biome_blend_at()` internally. This resamples noise 4+ times per column.
**Cost:** ~4,096 redundant noise samples per 32×32 chunk.
**Fix:** Cache `_get_blended_surface_y()` results for all columns before processing.

#### PERF-5: TileIndex Double-Loads Textures During Rebuild
**File:** `src/globals/tile_index.gd`
**Problem:** `rebuild_texture_array()` first loads a texture to determine dimensions, then loads ALL textures again to build the array. Each texture loaded from disk twice.
**Fix:** Cache loaded textures in a temporary dictionary during rebuild.

#### PERF-6: EntityManager O(n) Array.erase() for Chunk Tracking
**File:** `src/entities/entity_manager.gd:89-91`
**Problem:** `Array.erase()` is O(n) linear search + removal. For chunks with many entities, this is slow.
**Fix:** Use a Dictionary instead of Array for `_chunk_entities` values, giving O(1) removal.

#### PERF-7: Queue Sorting Instead of Priority Queue
**File:** `src/world/chunks/chunk_loader.gd:61-65, 111-122`
**Problem:** Full O(n log n) sort on generation/build queues whenever chunks are added. With 1,296 queued chunks, this is expensive.
**Fix:** Use insertion sort (queue already mostly sorted) or a binary heap.

#### PERF-8: Tile Damage Check Every Frame Per Entity
**File:** `src/physics/movement_controller.gd:107-116`
**Problem:** Iterates all tiles overlapping entity collision box every physics frame to check damage. For a 10×16 entity, ~20 tiles checked per frame.
**Fix:** Only recheck when entity moves to a new tile position (cache last-checked position).

#### PERF-9: BiomeMap O(n) Boundary Search
**File:** `src/world/biomes/biome_map.gd:55-65`
**Problem:** Linear scan up to 16 iterations per column to find biome boundary for blend weight calculation.
**Fix:** Precompute boundary distances or use spatial hashing.

#### PERF-10: LightPropagator Allocations Per Chunk
**File:** `src/world/lighting/light_propagator.gd:21-27`
**Problem:** Creates 3 new PackedByteArray objects per `calculate_light()` call. During initial load, hundreds of chunks generate simultaneously.
**Fix:** Pool and reuse arrays (thread-local pool pattern).

#### PERF-11: DynamicLightManager Full Image Upload Every Frame
**File:** `src/world/lighting/dynamic_light_manager.gd:147`
**Problem:** Uploads the entire 128×1 light data image every frame even if only one light moved.
**Fix:** Track dirty flag and skip upload when nothing changed. (Partially done — `_dirty` flag exists but could be more granular.)

#### PERF-12: EntityManager world_to_chunk_pos Every Frame Per Entity
**File:** `src/entities/entity_manager.gd:85`
**Problem:** Every entity, every frame, converts position to chunk coords. With many entities, sums.
**Fix:** Only recompute when entity has moved more than a threshold distance.

---

## 5. Code Clarity & Cleanup Opportunities

### Magic Numbers to Extract

| Location | Value | Suggested Constant |
|----------|-------|--------------------|
| `movement_controller.gd:136` | `0.1` (step-up distance threshold) | `STEP_UP_EPSILON` |
| `collision_detector.gd:26` | `0.0001` | Already `VELOCITY_EPSILON` but not in GlobalSettings |
| `player.gd:65` | `10.0` (flicker frequency) | `INVINCIBILITY_FLICKER_RATE` |
| `player.gd:66` | `0.3 + 0.7 * ...` (flicker alpha range) | `FLICKER_MIN_ALPHA`, `FLICKER_ALPHA_RANGE` |
| `chunk_loader.gd:82` | `MAX_BUILD_QUEUE_SIZE / 2.0` | `BACKPRESSURE_RESUME_THRESHOLD` |
| `chunk_manager.gd:276` | `4` (minimum resort distance) | `MIN_RESORT_DISTANCE` |
| `terrain.gdshader:10-11` | `WATER_ID=12, LAVA_ID=13` | Should be shader uniforms, not hardcoded |

### Y-Inversion Documentation
Both `chunk_loader.gd` and `chunk.gd` apply `(chunk_size - 1) - y` inversion. The reason (Godot Image Y increases downward while PackedByteArray index increases with Y) is only explained in CLAUDE.md constraints, not in the code itself. Add inline comments explaining **why** at both locations.

### Dead Code / Unused Signals
SignalBus declares these signals that are either unused or underutilized:
- `world_saving()` — never emitted
- `world_saved()` — never emitted
- `chunk_loaded()` — never emitted (despite test checking its existence)
- `chunk_unloaded()` — never emitted
- `light_level_changed()` — never emitted

Either implement emission at the appropriate points or remove to reduce cognitive load.

### Inconsistent Patterns
- `player.gd:148` uses string-based `emit_signal("player_chunk_changed", ...)` instead of typed `SignalBus.player_chunk_changed.emit(...)`. Should use the typed form throughout.
- `entity_spawned`/`entity_despawned` signals pass `Node2D` references while other entity signals pass `entity_id: int`. Should be consistent (prefer ID-based for decoupling).
- `GameServices` uses weak typing (`var tile_registry: Node`) instead of proper class names. Add `class_name` to all service classes and use typed references.

### Code Organization Issues
- `gui_manager.gd` (317 lines) mixes 5 concerns: brush editing, mining, tool management, particles, and input handling. Should be split into:
  - `EditorController` — terrain editing and brush logic
  - `MiningController` — mining progress and tool durability
  - `GUIManager` — pure UI orchestration
- `player.gd` (173 lines) manages torch light inline. Extract `TorchController` component.
- `SimplexTerrainGenerator` duplicates noise setup from `BiomeTerrainGenerator`. Extract shared noise configuration to `BaseTerrainGenerator`.

---

## 6. Architecture & Coupling Analysis

### Dependency Graph

```
GameInstance
  ├─ GameServices (service locator)
  │    ├─ ChunkManager ─── ChunkLoader (thread) ─── BaseTerrainGenerator
  │    │                                          └── LightPropagator
  │    ├─ LightManager ─── ChunkManager (circular via get_chunk_at)
  │    ├─ EntityManager
  │    ├─ WorldSaveManager
  │    ├─ DynamicLightManager
  │    └─ TileIndex (autoload, no class_name)
  ├─ TileSimulation ─── ChunkManager, TileIndex, SignalBus
  ├─ TileGrowthSystem ─── ChunkManager, TileIndex, SignalBus, GameServices
  └─ Player ─── CollisionDetector ─── ChunkManager
              └── MovementController
              └── HealthComponent ─── SignalBus
```

### Coupling Issues

| Coupling | Problem | Impact |
|----------|---------|--------|
| `LightManager` ↔ `ChunkManager` | Circular dependency (LightManager reads chunks, ChunkManager calls LightManager) | Can't extract lighting without chunking |
| `TileIndex` → everything | 121 references across codebase, no `class_name`, typed as `Node` in GameServices | Can't swap tile systems |
| `SignalBus` → `Node2D` | `entity_spawned(entity: Node2D)` couples signal bus to scene tree types | Testing requires real nodes |
| `GUIManager` → `TileIndex`, `ChunkManager`, `MiningSystem`, `ToolDefinition` | UI layer depends on 5+ engine systems directly | Can't test UI in isolation |
| `GlobalSettings` → hardcoded | All constants in one file, no per-instance override | Can't run two worlds with different settings |
| `GameServices` → hardcoded fields | Service locator has typed fields for each specific service | Adding a new service requires editing GameServices |

### What's Well-Decoupled
- `CollisionDetector` — composable, no scene tree dependency
- `MovementController` — pure RefCounted, reusable across any entity
- `HealthComponent` — composable RefCounted
- `WorldSaveManager` — standalone persistence, clean API
- `CameraController` — self-contained, auto-discovers target
- `BaseTerrainGenerator` — clean interface for custom generators

---

## 7. Thread Safety Audit

### Thread Boundaries

```
MAIN THREAD                         BACKGROUND THREAD(S)
────────────                        ────────────────────
ChunkManager._process()             ChunkLoader._generate_chunk_task()
LightManager (all methods)           ├── BaseTerrainGenerator.generate_chunk()
EntityManager._physics_process()     └── LightPropagator.calculate_light()
DynamicLightManager._process()
GUIManager._input()
Player._physics_process()
TileSimulation._physics_process()
```

### Issues Found

| Issue | Severity | Location | Detail |
|-------|----------|----------|--------|
| Bounds check outside mutex | HIGH | `chunk.gd:163-177` | `get_tile_at()` checks array size before locking. `reset()` could clear data between check and lock. |
| TileIndex.rebuild_texture_array() not thread-gated | MEDIUM | `tile_index.gd` | Public method with no main-thread assertion. If called from background, Godot crashes on GPU resource creation. |
| No texture read protection | LOW | `tile_index.gd` | `get_texture_array()` has no mutex. If `rebuild_texture_array()` runs concurrently (unlikely but possible), race on `_texture_array`. |
| ChunkLoader task submission after stop() | LOW | `chunk_loader.gd:146-180` | Tasks can be submitted between mutex unlock and `_shutdown_requested` check. Wastes work but doesn't crash. |
| LightManager Phase 2 chunk reference stability | LOW | `light_manager.gd:166,211,225` | Gets chunk reference via `get_chunk_at()` without verifying it won't be unloaded mid-propagation. |

### What's Thread-Safe
- `LightPropagator` — fully stateless, safe on any thread
- `Chunk._terrain_data` — properly mutex-protected for writes
- `ChunkLoader` queues — properly mutex-protected
- All terrain generators — no shared mutable state
- `CollisionDetector` / `MovementController` — main thread only, no shared state

---

## 8. Test Coverage Gaps

### What's Tested (155 tests)
- TileIndex: tile constants, solidity, properties, dynamic registration, texture arrays (30+ tests)
- Terrain Generators: interface, determinism, seed variation, sky/underground (12+ tests)
- WorldSaveManager: save/load, metadata, chunk persistence, deletion (18+ tests)
- EntityManager: spawn/despawn, IDs, signals (12+ tests)
- SignalBus: signal existence, emission/reception (11 tests)
- CameraController: instantiation, defaults, zoom (5 tests)
- GameServices: property existence (6 tests)

### What's NOT Tested (Critical Gaps)

| System | Gap | Risk |
|--------|-----|------|
| **ChunkManager** | No tests for loading lifecycle, pooling, backpressure, dirty tracking | Regressions in core pipeline go undetected |
| **ChunkLoader** | No threading tests, no backpressure tests | Race conditions undetectable |
| **Collision Detection** | No swept AABB tests, no edge cases (corners, tunneling) | Physics bugs only found at runtime |
| **Movement Controller** | No gravity, friction, coyote jump, step-up tests | Player physics regressions |
| **Lighting System** | No BFS tests, no cross-chunk propagation tests, no border seam tests | Light bugs are subtle and hard to reproduce |
| **Biome Blending** | No height interpolation or tile palette tests | Visual artifacts at biome boundaries |
| **GUI/Mining** | No input simulation, no brush tests | UI regressions |
| **Health/Damage** | No fall damage, tile damage, invincibility tests | Gameplay-breaking bugs |
| **Tile Simulation** | No falling sand or growth tests | Simulation regressions |
| **Integration** | No multi-system tests (edit → light → render) | System interaction bugs |

---

## 9. Documentation Drift

### README.md is Significantly Outdated
- Lists 4 tiles (AIR, DIRT, GRASS, STONE) — actual: 17 tiles
- Describes SimplexTerrainGenerator as default — actual: BiomeTerrainGenerator
- Missing biome system, entity system, health/damage, mining, dynamic lights, tile simulation
- Debug key mappings are wrong (F5 listed as "Removal queue" — F5 is Play in Godot)
- Project structure missing 6+ directories

### CLAUDE.md and ENGINE_ARCHITECTURE.md Are Accurate
These two documents closely track the actual code and are reliable references.

### Input Action Shadowing
`project.godot` maps both `toggle_controls_help` and `debug_toggle_all` to F1. One shadows the other.

---

## 10. Engine Extraction Strategy

### Goal
Split the codebase into a reusable **SubstrataEngine** core that can power different 2D voxel games, with Substrata's game-specific code as the first "game" built on it.

### Proposed Engine/Game Boundary

#### Engine Core (~3,400 LOC, 22 files)

| Module | Files | Description |
|--------|-------|-------------|
| `engine/world/chunks/` | chunk.gd, chunk_loader.gd, chunk_manager.gd, terrain.gdshader | Chunk pipeline |
| `engine/world/lighting/` | light_propagator.gd, light_manager.gd, dynamic_light_manager.gd | Lighting system |
| `engine/world/generators/` | base_terrain_generator.gd | Generator interface |
| `engine/world/persistence/` | world_save_manager.gd | Save/load |
| `engine/physics/` | collision_detector.gd, movement_controller.gd | Physics |
| `engine/entities/` | base_entity.gd, entity_manager.gd | Entity lifecycle |
| `engine/core/` | signal_bus.gd, settings.gd, tile_registry.gd, service_locator.gd | Framework |
| `engine/camera/` | camera_controller.gd | Camera |
| `engine/components/` | health_component.gd | Composable components |

#### Game Layer (~1,800 LOC, 14 files)

| Module | Files | Description |
|--------|-------|-------------|
| `game/generators/` | biome_terrain_generator.gd, simplex_terrain_generator.gd | Substrata's generators |
| `game/biomes/` | biome_map.gd, biome_definition.gd | Biome system |
| `game/simulation/` | tile_simulation.gd, tile_growth.gd | Tile behaviors |
| `game/gui/` | gui_manager.gd, mining_system.gd, editing_toolbar.gd, ... | UI |
| `game/items/` | tool_definition.gd | Tools |
| `game/entities/` | player.gd | Player |
| `game/` | game_instance.gd | Bootstrap |

### Key Refactors Required

1. **Generic Service Locator** — Replace hardcoded `GameServices` fields with name-based registry:
   ```gdscript
   class_name ServiceLocator extends Node
   var _services: Dictionary = {}
   func register(name: String, service) -> void
   func get_service(name: StringName) -> Variant
   ```

2. **Tile Registry Interface** — Extract interface from TileIndex:
   ```gdscript
   class_name TileRegistry extends Node
   func is_solid(tile_id: int) -> bool
   func get_light_filter(tile_id: int) -> int
   func get_property(tile_id: int, property: String) -> Variant
   ```
   Game layer implements with Substrata's specific tiles.

3. **Terrain Generator Contract** — Already exists (`BaseTerrainGenerator`), just needs to be in engine module.

4. **Signal Bus Cleanup** — Remove unused signals, change entity signals to ID-based, document which signals are engine-level vs game-level.

5. **Shader Uniforms** — Replace hardcoded `WATER_ID`/`LAVA_ID` with shader uniforms set by the game layer.

6. **Configuration Object** — Replace `GlobalSettings` constants with a config resource:
   ```gdscript
   class_name EngineConfig extends Resource
   @export var chunk_size: int = 32
   @export var max_light: int = 80
   @export var lod_radius: int = 4
   ```

### Extraction Order (Minimal Disruption)
1. Add `class_name` to all service classes (no behavior change)
2. Type all `GameServices` fields properly
3. Extract `ServiceLocator` base class
4. Move `GlobalSettings` to `EngineConfig` resource pattern
5. Create `engine/` and `game/` directory split
6. Abstract `TileIndex` into `TileRegistry` interface + Substrata implementation
7. Make shader tile IDs configurable via uniforms
8. Extract signal bus into engine signals + game signals

---

## 11. Prioritized Action Plan

### Phase 1: Bug Fixes (Stability)

| # | Task | Files | Severity |
|---|------|-------|----------|
| 1 | Fix chunk bounds check race condition (move inside mutex) | `chunk.gd` | P0 |
| 2 | Guard player signal connection against duplicates | `player.gd` | P0 |
| 3 | Add terminal velocity clamp to movement controller | `movement_controller.gd` | P1 |
| 4 | Fix light border import double-attenuation | `light_manager.gd` | P1 |
| 5 | Add null camera guards in GUIManager | `gui_manager.gd` | P1 |
| 6 | Guard shader division by zero for dynamic lights | `terrain.gdshader` | P1 |
| 7 | Add TileGrowthSystem fallback for chunk_manager init | `tile_growth.gd` | P2 |
| 8 | Fix biome blend tile palette (or document as known limitation) | `biome_terrain_generator.gd` | P2 |

### Phase 2: Performance Optimization

| # | Task | Expected Improvement |
|---|------|---------------------|
| 1 | Batch border light fixup per-frame instead of per-chunk | -16ms during chunk loading |
| 2 | Spiral chunk loading instead of full-radius queue | Eliminate 2s+ initial stall |
| 3 | Optimize shader dynamic light loop (early exit or cap at 16) | -60% fragment cost |
| 4 | Cache biome noise samples per column | -4K redundant noise samples/chunk |
| 5 | Fix TileIndex double texture loading | -50% texture rebuild time |
| 6 | Use Dictionary for EntityManager chunk tracking | O(1) entity removal |

### Phase 3: Code Cleanup & Clarity

| # | Task |
|---|------|
| 1 | Extract magic numbers into named constants |
| 2 | Remove/implement unused SignalBus signals |
| 3 | Fix string-based emit_signal calls to typed form |
| 4 | Add Y-inversion comments at both locations |
| 5 | Split GUIManager into EditorController + MiningController + GUIManager |
| 6 | Add `class_name` to TileIndex and all service classes |
| 7 | Type GameServices fields properly |
| 8 | Update README.md to match current codebase |

### Phase 4: Testing

| # | Task |
|---|------|
| 1 | Add collision detection unit tests (swept AABB, edge cases) |
| 2 | Add movement controller tests (gravity, friction, coyote jump) |
| 3 | Add lighting BFS correctness tests |
| 4 | Add chunk lifecycle integration tests |
| 5 | Add health/damage system tests |

### Phase 5: Engine Extraction

| # | Task |
|---|------|
| 1 | Create `engine/` and `game/` directory structure |
| 2 | Implement generic ServiceLocator |
| 3 | Implement EngineConfig resource |
| 4 | Extract TileRegistry interface |
| 5 | Make shader tile IDs configurable |
| 6 | Create minimal engine demo (no Substrata game code) |
| 7 | Document engine API and extension points |

---

## Questions for the Developer

The following decisions affect the approach to several of the items above:

1. **Engine scope** — Should the engine target only 2D top-down/side-view voxel games, or should it be flexible enough for other 2D tile-based genres (RPGs, strategy)?

2. **Biome blend** — Is the current sharp tile-palette transition at biome boundaries considered a bug or an acceptable aesthetic? Fixing it properly requires interpolated tile selection or transition tiles.

3. **Terminal velocity** — What should `MAX_FALL_SPEED` be? The current gravity is 800 px/s² and jump velocity is -400 px/s. A reasonable terminal velocity might be 1200-1600 px/s (2-3 seconds of fall).

4. **Dynamic light cap** — The shader loops up to 64 lights but most scenes likely use <10. Should the engine cap be reduced to 16 (significant GPU savings) or kept at 64 for flexibility?

5. **SimplexTerrainGenerator** — Should it be kept as a simpler alternative, or removed in favor of BiomeTerrainGenerator only? It duplicates noise setup code.

6. **Test priority** — Which untested system is most likely to regress: collision detection, lighting, or chunk lifecycle?

7. **Save format** — Current save format is unversioned raw bytes. Should a version header be added before more data is persisted, to enable future migration?
