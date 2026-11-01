# Substrata

A 2D voxel-based game featuring procedurally generated, force-destructible terrain with a multithreaded chunk loading system and per-chunk world persistence, built in Rust on a custom native **`winit` + `wgpu`** 2D engine.

## Running

```bash
# Run in release mode (recommended)
cargo run --release

# Run debug build
cargo run

# Run the unit, physics, Dijkstra destruction, and headless GPU shader/pipeline test suite
cargo test
```

## Architecture

### Chunk System

Terrain is divided into 32x32 tile chunks, grouped into 4x4-chunk **regions** for streaming decisions. Chunks within `LOD_RADIUS` (4) regions of the player are generated; chunks beyond `LOD_RADIUS + REMOVAL_BUFFER` (6) regions are unloaded. Managed by a producer-consumer threading model:

- **ChunkManager** (`src/game/world/chunk_manager.rs`) — Main thread orchestrator. Listens for `PlayerChunkChanged` events, queues chunk generation/removal on region changes, re-sorts queues by player distance when the player moves ~2+ chunks within a region, and processes built chunks each frame (capped at 16 builds, 32 removals per frame to prevent stuttering). Emits `WorldReady` once the initial region set has loaded. Chunks with saved data on disk are loaded synchronously on the main thread and never hit the worker pool.
- **ChunkLoader** (`src/game/world/chunk_loader.rs`) — Parallel chunk generation scheduler using an 8-thread worker pool. Generates terrain data off the main thread using `Mutex` + `Condvar` synchronization with backpressure: generation pauses when the build queue reaches 128 and resumes once it drains below 64.
- **Chunk** (`src/game/world/chunk.rs`) — Individual chunk storing terrain as a 2048-byte buffer (2 bytes per tile: `[tile_id, damage_stage]`) and an allocated GPU chunk atlas slot. Chunks are pooled (pool pre-populated at startup to the max loadable count) and recycled to avoid allocation overhead.

### Rendering

Active chunks are allocated 32x32 slots inside a `2048x2048` `Rg8Unorm` GPU **Chunk Data Atlas** (`64x64 = 4096` slots) and drawn in a **single instanced draw call** (`ChunkPass` in `src/engine/renderer/chunk_pass.rs`, `terrain.wgsl`). Each fragment loads `(tile_id, damage_stage)` via integer `textureLoad` (preventing any atlas bleed), samples the matching layer of the shared `Rgba8Unorm` `Texture2DArray` tile atlas (`tile_textures`), and applies per-stage darkening (85% at stage 1, 65% at stage 2) or the `debug_terrain` (T key) hardness/damage heatmap: yellow/red tint for damage stages, and a red (hard, dark pixels) to blue (soft, bright pixels) luminance heatmap. Edits update only the modified 32x32 sub-region in-place via `queue.write_texture`.

### Terrain Generation

`SimplexTerrainGenerator` (implements `BaseTerrainGenerator` in `src/game/world/generator.rs`) uses layered `fastnoise-lite` (simplex) noise — a broad heightmap plus small-scale surface detail — with noisy dirt/stone layer boundaries and slope-based cliff detection (steep faces don't grow grass). All parameters live in `GeneratorConfig::default()` and can be customized at construction. Runs entirely on background worker threads.

### Physics & Movement

- **CollisionDetector** (`src/game/physics/collision.rs`) — Custom swept AABB collision detection against the tile grid. Sweeps X then Y axis separately with collision normals and step-up support. Unloaded chunks are treated as non-solid.
- **MovementController** (`src/game/physics/movement.rs`) — Reusable physics controller handling gravity, horizontal acceleration/friction, coyote jump timing, and step-up mechanics. The player (`src/game/entities/player.rs`) composes with it and provides input; `EntityManager` (`src/game/entities/mod.rs`) drives entity updates each 60 Hz physics tick.

### Tile System

`TileRegistry` (`src/game/tiles.rs`) is a data-driven tile registry. Each tile has a solidity flag, a UI color, an optional texture path, and gameplay properties (`friction`, `damage`, `transparency`, `hardness`, `damage_stages`, `break_noise`). Registered textures are packed into an `Rgba8Unorm` `Texture2DArray` for the terrain shader (layer N = tile_id N).

Default tiles:

| ID  | Name  | Solid | Hardness | Damage stages | Break noise |
| --- | ----- | ----- | -------- | ------------- | ----------- |
| 0   | Air   | no    | 0        | 0             | 0.0         |
| 1   | Dirt  | yes   | 3        | 2             | 0.0         |
| 2   | Grass | yes   | 2        | 2             | 0.0         |
| 3   | Stone | yes   | 8        | 2             | 0.5         |

On `rebuild_texture_array()`, each tile's **directional edge hardness** (N/S/E/W) is auto-derived from its texture's edge-pixel luminance relative to the texture's average: `base_hardness * (avg_lum / edge_lum)`. Dark edges (e.g. mortar, gaps) end up **harder** than the base value and bright edges (e.g. a stone face) **softer**, so new tile art gets plausible destruction behavior for free with no hand-authored hardness table. Effective hardness scales linearly down with damage stage (`1 - stage / damage_stages`).

### Terrain Editing

`TerrainEditController` handles mouse/keyboard input (ignoring clicks consumed by the hotbar UI); `TerrainEditor` (`src/game/world/terrain_editor.rs`) implements the actual edit:

- **Left-click (hold) — dig.** Runs a max-path Dijkstra flood fill (`TerrainEditor::flood_fill`) outward from the clicked tile through solid neighbors (8-connected). The clicked tile must be solid; air blocks propagation. A visited tile is destroyed (set to AIR) if the force reaching it is at least its effective hardness; otherwise it steps up one `damage_stage` (visually darkened) and stops propagation on that path. When a tile breaks, force passes to each neighbor after paying that neighbor's _effective directional hardness_ (sampled from the entry direction, scaled by its damage stage), then decays multiplicatively (`FORCE_DECAY_PER_TILE`, 0.85). Diagonal steps cost 1.4x more. Force also falls off linearly with path distance, reaching zero at `force * FORCE_DISTANCE_FACTOR` (1.5), and the fill is hard-capped at `MAX_FLOOD_FILL_RADIUS` (64) tiles. Tiles with `break_noise > 0` (e.g. stone) apply a deterministic per-position jitter to the outgoing force for jagged, non-circular breaks.
  - A cleanup pass then BFS-searches from tiles bordering the destruction for small orphaned solid clusters (≤ `ORPHAN_CLUSTER_THRESHOLD`, 10 tiles) and destroys them too, so single floating tiles don't linger — without needing physics.
- **Right-click (hold) — place.** Places the selected material (damage stage 0) in a circular brush of radius `brush_value`.
- **Q/E** — adjust a single `brush_value` (1–50, default 10) that drives both dig force and place radius. Emits `BrushValueChanged` so the hotbar readout and world-space brush preview circle update.
- **1-9 / hotbar click** — select placement material. Slots are built dynamically from `TileRegistry::get_tile_ids()` (capped at 9). Emits `MaterialSelected`.
- **T** — toggle the shader's hardness/damage debug heatmap.

Both dig and place re-apply only when the mouse moves to a new tile while held. All edits are batched per-chunk via `ChunkManager::set_tiles_at_world_positions()` for efficient GPU updates, mark the chunk dirty for saving, and emit `TileChanged` events on `SignalBus`.

### Persistence

`WorldSaveManager` (`src/game/world/persistence.rs`) stores each world under `data/{world_name}/` (gitignored), with a `world_meta.json` (seed, generator name/config, format version, timestamps) and one raw `chunks/chunk_{x}_{y}.dat` per chunk (the 2048-byte buffer as-is). The world name is the `ChunkManager::world_seed` (random per run unless pinned). Only chunks edited since load are written: dirty chunks are saved when they unload and all remaining dirty chunks plus metadata are saved on exit (`save_world()`, bracketed by `WorldSaving`/`WorldSaved` events). On load, a chunk with a save file is restored instead of regenerated.

## Debug Overlays

| Key | Overlay                                                                    | Default |
| --- | -------------------------------------------------------------------------- | ------- |
| F1  | Controls help panel                                                        | off     |
| F2  | Cursor info (tile under mouse: name, hardness, effective hardness, damage) | on      |
| F3  | Debug HUD (FPS, position, velocity, zoom, chunk/queue stats)               | off     |
| F4  | Chunk debug world overlay (loaded regions, chunk borders, queues)          | off     |
| T   | Terrain shader debug heatmap (hardness/damage visualization)               | off     |

## Controls

| Key                | Action                                                   |
| ------------------ | -------------------------------------------------------- |
| A/D or Left/Right  | Move left/right                                          |
| Space              | Jump                                                     |
| Left Click (hold)  | Dig (force-based destruction, Dijkstra flood fill)       |
| Right Click (hold) | Place selected material (circular brush)                 |
| Q/E                | Decrease/increase brush value (dig force / place radius) |
| B                  | Toggle Brick Builder mode                                |
| Scroll wheel       | Zoom in/out (10% per tick, 0.5x–10x)                     |
| Z                  | Cycle zoom presets (1x/2x/4x/8x)                         |
| 1-9                | Select material (Slot 9 = Lantern static light tile)     |
| L                  | Cycle lighting style (Smooth / Pixel-Art / Blocky / Off) |
| F                  | Toggle player lantern (dynamic light)                    |
| C                  | Toggle cursor inspection light (dynamic light)           |
| T                  | Toggle terrain debug heatmap                             |

## Project Structure

```text
Cargo.toml                          # Rust package manifest (winit, wgpu, glam, fastnoise-lite, image, serde)
assets/
└── textures/                       # dirt, grass, stone tile art (32x32) + player sprite (10x16)
src/
├── main.rs                         # Binary entry point, loads assets & boots EngineApp
├── lib.rs                          # Library root exposing `engine` and `game` modules
├── engine/                         # Custom 2D native engine (winit + wgpu)
│   ├── app.rs                      # winit ApplicationHandler, 60 Hz fixed physics + render loop, HiDPI scaling
│   ├── camera.rs                   # Orthographic 2D camera, frustum bounds, screen <-> world transforms
│   ├── input.rs                    # Keyboard/mouse state, scroll delta, UI mouse-click consumption
│   ├── ui.rs                       # Embedded 8x8 ASCII bitmap font + SDF rounded-rect/icon UI batcher
│   └── renderer/
│       ├── mod.rs                  # wgpu Surface/Device/Queue initialization & 4-pass frame encoder
│       ├── chunk_pass.rs           # Instanced chunk renderer + 4096-slot Rg8Unorm atlas + Texture2DArray
│       ├── sprite_pass.rs          # Instanced 2D sprite renderer (player & entities)
│       ├── debug_pass.rs           # Immediate-mode world-space lines, rects, and circles
│       ├── ui_pass.rs              # Screen-space SDF panel, tile icon, and bitmap text renderer
│       └── shaders/                # WGSL shaders (terrain.wgsl, sprite.wgsl, debug.wgsl, ui.wgsl)
└── game/                           # Substrata gameplay systems
    ├── mod.rs                      # SubstrataGame root state (GameCallbacks implementation)
    ├── camera_controller.rs        # Smooth-follow camera, scroll zoom, Z presets
    ├── gui.rs                      # Hotbar, CursorInfo (F2), DebugHUD (F3), Controls (F1), World Overlay (F4)
    ├── settings.rs                 # World, streaming, and terrain-editing constants
    ├── signals.rs                  # Event bus (SignalBus)
    ├── tiles.rs                    # TileRegistry, Texture2DArray builder, luminance directional edge hardness
    ├── entities/
    │   ├── mod.rs                  # BaseEntity + EntityManager
    │   └── player.rs               # Player input & physics orchestration
    ├── physics/
    │   ├── collision.rs            # Swept AABB collision detection against the tile grid
    │   └── movement.rs             # Gravity, accel/friction, coyote jump, step-up mechanics
    └── world/
        ├── chunk.rs                # Per-chunk [tile_id, damage_stage] buffer + GPU atlas slot
        ├── chunk_loader.rs         # 8-thread background chunk generator with distance priority & backpressure
        ├── chunk_manager.rs        # Region streaming, pooling, batched tile edits, dirty-chunk tracking
        ├── generator.rs            # BaseTerrainGenerator trait + SimplexTerrainGenerator (fastnoise-lite)
        ├── persistence.rs          # WorldSaveManager (data/{world_name}/world_meta.json + chunks/*.dat)
        └── terrain_editor.rs       # Max-path Dijkstra flood fill + BFS orphan cleanup + TerrainEditController
tests/
└── gameplay_tests.rs               # Unit, physics, Dijkstra destruction, and headless wgpu pipeline tests
```
