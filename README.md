# Substrata

A 2D voxel-based game built in **Godot 4.7** with **GDScript**, using the Compatibility (OpenGL) renderer. Features procedurally generated, force-destructible terrain with a multithreaded chunk loading system and per-chunk world persistence.

## Running

Open in Godot 4.7 and press F5.

## Architecture

### Chunk System

Terrain is divided into 32x32 tile chunks, grouped into 4x4-chunk **regions** for streaming decisions. Chunks within `LOD_RADIUS` (4) regions of the player are generated; chunks beyond `LOD_RADIUS + REMOVAL_BUFFER` (6) regions are unloaded. Managed by a producer-consumer threading model:

- **ChunkManager** — Main thread orchestrator. Listens for `player_chunk_changed` on `SignalBus`, queues chunk generation/removal on region changes, re-sorts queues by player distance when the player moves ~2+ chunks within a region, and processes built chunks each frame (capped at 16 builds, 32 removals per frame to prevent stuttering). Emits `world_ready` once the initial region set has loaded. Chunks with saved data on disk are loaded synchronously on the main thread and never hit the worker.
- **ChunkLoader** — Parallel chunk generation scheduler using Godot's `WorkerThreadPool` (up to 8 concurrent tasks). Generates terrain data and the visual data image off the main thread. Uses Mutex synchronization with backpressure: generation pauses when the build queue reaches 128 and resumes once it drains below 64.
- **Chunk** — Individual chunk storing terrain as a `PackedByteArray` (2 bytes per tile: `[tile_id, damage_stage]`). Rendered via a shared `QuadMesh` and fragment shader. Chunks are pooled (pool pre-populated at startup to the max loadable count) and recycled to avoid instantiation overhead.

### Rendering

Terrain data flows through: `PackedByteArray` → `Image` (RGBA8, R=tile_id, G=damage_stage) → `ImageTexture` → fragment shader that decodes both channels, samples a `Texture2DArray` tile atlas (layer = tile_id), and darkens the tile per damage stage (85% at stage 1, 65% at stage 2). Edits update the existing `ImageTexture` in-place to avoid GPU allocations. A `debug_terrain` shader toggle (T key) swaps in a damage/hardness heatmap for tuning: yellow/red tint for damage stages, and a red (hard, dark pixels) to blue (soft, bright pixels) luminance heatmap.

### Terrain Generation

`SimplexTerrainGenerator` (implements `BaseTerrainGenerator`) uses layered `FastNoiseLite` (simplex) noise — a broad heightmap plus small-scale surface detail — with noisy dirt/stone layer boundaries and slope-based cliff detection (steep faces don't grow grass). All parameters live in a `DEFAULT_CONFIG` dictionary that can be partially overridden at construction. Runs entirely in the background thread; generators must not touch the scene tree.

### Physics

Custom swept AABB collision detection against the tile grid (`CollisionDetector`) — does not use Godot's built-in physics. Sweeps X then Y axis separately with collision normals and step-up support. Unloaded chunks are treated as non-solid.

### Movement

`MovementController` is a reusable physics controller handling gravity, horizontal acceleration/friction, coyote jump timing, and step-up mechanics. The player composes with it and just provides input — any future entity can reuse the same movement system via `BaseEntity`, whose `entity_process()` is driven by `EntityManager` each physics frame.

### Tile System

`TileIndex` is a data-driven tile registry autoload. Each tile has a solidity flag, a UI color, a texture path, and a properties dictionary (`friction`, `damage`, `transparency`, `hardness`, `damage_stages`, `break_noise`). Registered textures are packed into a `Texture2DArray` for the terrain shader (layer N = tile_id N).

Default tiles:

| ID  | Name  | Solid | Hardness | Damage stages | Break noise |
| --- | ----- | ----- | -------- | ------------- | ----------- |
| 0   | Air   | no    | 0        | 0             | 0.0         |
| 1   | Dirt  | yes   | 3        | 2             | 0.0         |
| 2   | Grass | yes   | 2        | 2             | 0.0         |
| 3   | Stone | yes   | 8        | 2             | 0.5         |

On `rebuild_texture_array()`, each tile's **directional edge hardness** (N/S/E/W) is auto-derived from its texture's edge-pixel luminance relative to the texture's average: `base_hardness * (avg_lum / edge_lum)`. Dark edges (e.g. mortar, gaps) end up **harder** than the base value and bright edges (e.g. a stone face) **softer**, so new tile art gets plausible destruction behavior for free with no hand-authored hardness table. Effective hardness scales linearly down with damage stage (`1 - stage / damage_stages`).

### Terrain Editing

`TerrainEditController` handles input (via `_unhandled_input`, so GUI widgets like the hotbar consume clicks first); `TerrainEditor` implements the actual edit:

- **Left-click (hold) — dig.** Runs a max-path Dijkstra flood fill (`TerrainEditor._flood_fill`) outward from the clicked tile through solid neighbors (8-connected). The clicked tile must be solid; air blocks propagation. A visited tile is destroyed (set to AIR) if the force reaching it is at least its effective hardness; otherwise it steps up one `damage_stage` (visually darkened) and stops propagation on that path. When a tile breaks, force passes to each neighbor after paying that neighbor's _effective directional hardness_ (sampled from the entry direction, scaled by its damage stage), then decays multiplicatively (`FORCE_DECAY_PER_TILE`, 0.85). Diagonal steps cost 1.4x more. Force also falls off linearly with path distance, reaching zero at `force * FORCE_DISTANCE_FACTOR` (1.5), and the fill is hard-capped at `MAX_FLOOD_FILL_RADIUS` (64) tiles. Tiles with `break_noise > 0` (e.g. stone) apply a deterministic per-position jitter to the outgoing force for jagged, non-circular breaks.
  - A cleanup pass then BFS-searches from tiles bordering the destruction for small orphaned solid clusters (≤ `ORPHAN_CLUSTER_THRESHOLD`, 10 tiles) and destroys them too, so single floating tiles don't linger — without needing physics.
- **Right-click (hold) — place.** Places the selected material (damage stage 0) in a circular brush of radius `brush_value`.
- **Q/E** — adjust a single `brush_value` (1–50, default 10) that drives both dig force and place radius. Emits `brush_value_changed` so the hotbar readout and world-space `BrushPreview` circle redraw.
- **1-9 / hotbar click** — select placement material. Slots are built from `TileIndex.get_tile_ids()`, so they track however many tiles are registered (capped at 9). Emits `material_selected`.
- **T** — toggle the shader's hardness/damage debug heatmap.

Both dig and place re-apply only when the mouse moves to a new tile while held. All edits are batched per-chunk via `ChunkManager.set_tiles_at_world_positions()` for efficient GPU updates, mark the chunk dirty for saving, and drive the `tile_changed` signal on `SignalBus`.

### Persistence

`WorldSaveManager` stores each world under `res://data/{world_name}/` (gitignored), with a `world_meta.json` (seed, generator name/config, format version, timestamps) and one raw `chunk_{x}_{y}.dat` per chunk (the `PackedByteArray` as-is). The world name is the `ChunkManager.world_seed` (random per run unless set in the scene). Only chunks edited since load are written: dirty chunks are saved when they unload and all remaining dirty chunks plus metadata are saved on exit (`save_world()`, bracketed by `world_saving`/`world_saved` signals). On load, a chunk with a save file is restored instead of regenerated.

### Service Locator

`GameServices` autoload holds references to shared systems (`chunk_manager`, `entity_manager`, `tile_registry`, `terrain_generator`, `world_save_manager`, `terrain_edit_controller`), populated by `GameInstance._ready()`. Systems access it lazily — no manual wiring required when adding new scripts that need shared state. Other autoloads: `SignalBus`, `GlobalSettings`, `TileIndex`.

## Scene Tree

```text
GameInstance (Node)
├── Player (CharacterBody2D)
├── CameraController (Camera2D)
├── ChunkManager (Node2D)
├── EntityManager (Node)
├── ChunkDebugOverlay (Node2D)
├── TerrainEditController (Node)
├── BrushPreview (Node2D)
└── UILayer (CanvasLayer)
    └── GUIManager (Control)
        ├── Hotbar
        ├── DebugHUD
        ├── CursorInfo
        └── ControlsOverlay
```

## Debug Overlay

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
| A/D                | Move left/right                                          |
| Space              | Jump                                                     |
| Left Click (hold)  | Dig (force-based destruction, Dijkstra flood fill)       |
| Right Click (hold) | Place selected material (circular brush)                 |
| Q/E                | Decrease/increase brush value (dig force / place radius) |
| Scroll wheel       | Zoom in/out (10% per tick, 0.5x–10x)                     |
| Z                  | Cycle zoom presets (1x/2x/4x/8x)                         |
| 1-9                | Select material (also clickable on the hotbar)           |
| T                  | Toggle terrain debug heatmap                             |

## Project Structure

```text
assets/
├── textures/                       # dirt, grass, stone tile art + player sprite
└── theme/hud_theme.tres            # Shared HUD theme
src/
├── camera/
│   └── camera_controller.gd        # Smooth-follow camera, zoom presets
├── entities/
│   ├── base_entity.gd              # Base class for game entities (optional MovementController composition)
│   ├── entity_manager.gd           # Entity lifecycle management
│   └── player.gd                   # Input handling, delegates to MovementController
├── game/
│   └── game_instance.gd            # Scene root, registers services, sets up persistence
├── globals/
│   ├── game_services.gd            # Service locator autoload
│   ├── global_settings.gd          # World constants (chunk size, frame budgets, terrain-edit tuning)
│   ├── signal_bus.gd               # Global event bus
│   └── tile_index.gd               # Data-driven tile registry, texture array, directional edge hardness
├── gui/
│   ├── debug/
│   │   ├── controls_overlay.gd     # F1 controls help panel (text authored in the .tscn)
│   │   ├── cursor_info.gd          # F2 tile-under-cursor readout
│   │   └── debug_hud.gd            # F3 perf/world debug HUD
│   ├── hotbar/
│   │   └── hotbar.gd               # Material hotbar + brush value readout, built at runtime from TileIndex
│   └── gui_manager.tscn            # Composes Hotbar/DebugHUD/CursorInfo/ControlsOverlay (no script)
├── physics/
│   ├── collision_detector.gd       # Swept AABB collision against the tile grid
│   └── movement_controller.gd      # Reusable movement physics
└── world/
    ├── brush_preview.gd            # World-space brush outline
    ├── chunk_debug_overlay.gd      # F4 debug visualization
    ├── terrain_edit_controller.gd  # Dig/place input handling, material + brush value selection
    ├── terrain_editor.gd           # Force/hardness Dijkstra flood fill + orphan cleanup
    ├── chunks/
    │   ├── chunk.gd                 # Terrain data + rendering per chunk
    │   ├── chunk_loader.gd          # WorkerThreadPool chunk generation
    │   ├── chunk_manager.gd         # Main thread chunk orchestration + dirty-chunk saving
    │   └── terrain.gdshader         # Tile rendering + debug heatmap shader
    ├── generators/
    │   ├── base_terrain_generator.gd    # Generator interface
    │   └── simplex_terrain_generator.gd # Simplex noise terrain generation
    └── persistence/
        └── world_save_manager.gd    # World save/load (metadata JSON + raw chunk files under res://data/)
```
