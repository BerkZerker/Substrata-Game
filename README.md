# Substrata

A 2D voxel-based game built in **Godot 4.7** with **GDScript**. Features procedurally generated, force-destructible terrain with a multithreaded chunk loading system.

## Running

Open in Godot 4.7 and press F5.

## Architecture

### Chunk System

Terrain is divided into 32x32 tile chunks, managed by a producer-consumer threading model:

- **ChunkManager** — Main thread orchestrator. Monitors player position, queues chunk generation/removal, and processes built chunks each frame (capped at 16 builds, 32 removals per frame to prevent stuttering).
- **ChunkLoader** — Parallel chunk generation scheduler using Godot's `WorkerThreadPool`. Submits tasks up to a concurrency limit, generates terrain data and visual images off the main thread. Uses Mutex synchronization with backpressure when the build queue gets too large.
- **Chunk** — Individual chunk storing terrain as a `PackedByteArray` (2 bytes per tile: `[tile_id, damage_stage]`). Rendered via a shared `QuadMesh` and fragment shader. Chunks are pooled and recycled to avoid instantiation overhead.

### Rendering

Terrain data flows through: `PackedByteArray` → `Image` (RGBA8, R=tile_id, G=damage_stage) → `ImageTexture` → fragment shader that decodes both channels, samples a `Texture2DArray` tile atlas (layer = tile_id), and darkens the tile per damage stage. Edits update the existing `ImageTexture` in-place to avoid GPU allocations. A `debug_terrain` shader toggle (T key) swaps in a damage/hardness heatmap for tuning.

### Terrain Generation

`SimplexTerrainGenerator` (implements `BaseTerrainGenerator`) uses layered `FastNoiseLite` (simplex) noise — a broad heightmap plus small-scale surface detail — with noisy dirt/stone layer boundaries and slope-based cliff detection (steep faces don't grow grass). Runs entirely in the background thread; generators must not touch the scene tree.

### Physics

Custom swept AABB collision detection against the tile grid (`CollisionDetector`) — does not use Godot's built-in physics. Sweeps X then Y axis separately with collision normals and step-up support.

### Movement

`MovementController` is a reusable physics controller handling gravity, horizontal acceleration/friction, coyote jump timing, and step-up mechanics. The player composes with it and just provides input — any future entity can reuse the same movement system via `BaseEntity`.

### Tile System

`TileIndex` is a data-driven tile registry (AIR, DIRT, GRASS, STONE registered by default). Each tile has a solidity flag, a UI color, a texture path, and a properties dictionary (`friction`, `damage`, `transparency`, `hardness`, `damage_stages`, `break_noise`). Registered textures are packed into a `Texture2DArray` for the terrain shader (layer N = tile_id N).

On `rebuild_texture_array()`, each tile's **directional edge hardness** (N/S/E/W) is auto-derived from its texture's edge-pixel brightness — dark edges (e.g. mortar) end up cheap to break, bright edges (e.g. a stone face) expensive — so new tile art gets plausible destruction behavior for free, with no separate hand-authored hardness table.

### Terrain Editing

`TerrainEditController` handles input; `TerrainEditor` implements the actual edit:

- **Left-click (hold) — dig.** Runs a max-path Dijkstra flood fill (`TerrainEditor._flood_fill`) outward from the clicked tile through solid neighbors. Each step pays the destination tile's *effective directional hardness* (base hardness scaled by current damage stage, sampled from the entry direction), and the propagating force decays multiplicatively per tile (`FORCE_DECAY_PER_TILE`) and falls off linearly with distance out to `force * FORCE_DISTANCE_FACTOR`. A tile that fully absorbs the incoming force is destroyed (set to AIR); one that doesn't steps up one `damage_stage` instead (visually darkened) and stops propagation on that path. Diagonal steps cost 1.4x more. Tiles with `break_noise > 0` (e.g. stone) get a deterministic per-position jitter on the outgoing force for jagged, non-circular breaks.
  - A cleanup pass then BFS-searches from tiles bordering the destruction for small orphaned solid clusters (≤ `ORPHAN_CLUSTER_THRESHOLD` tiles) and destroys them too, so single floating tiles don't linger — without needing physics.
- **Right-click (hold) — place.** Places the selected material in a circular brush.
- **Q/E** — adjust a single `brush_value` that drives both dig force and place radius.
- **1-9** — select placement material (built from `TileIndex.get_tile_ids()`, so it tracks however many tiles are registered).
- **T** — toggle the shader's hardness/damage debug heatmap.

All edits are batched per-chunk via `ChunkManager.set_tiles_at_world_positions()` for efficient GPU updates, and drive the `tile_changed` signal on `SignalBus`.

### Service Locator

`GameServices` autoload holds references to shared systems (`chunk_manager`, `entity_manager`, `tile_registry`, `terrain_generator`, `world_save_manager`, `terrain_edit_controller`). Systems access it lazily — no manual wiring required when adding new scripts that need shared state.

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

| Key | Overlay                                                                 |
| --- | ------------------------------------------------------------------------ |
| F1  | Controls help panel                                                     |
| F2  | Cursor info (tile under mouse: id, hardness, damage)                    |
| F3  | Debug HUD (FPS, position, velocity, chunk/queue stats)                  |
| F4  | Chunk debug world overlay (loaded regions, chunk borders, queues)       |
| T   | Terrain shader debug heatmap (hardness/damage visualization)            |

## Controls

| Key                | Action                                          |
| ------------------- | ----------------------------------------------- |
| A/D                 | Move left/right                                 |
| Space               | Jump                                            |
| Left Click (hold)   | Dig (force-based destruction, Dijkstra flood fill) |
| Right Click (hold)  | Place selected material (circular brush)        |
| Q/E                 | Decrease/increase brush value (dig force / place radius) |
| Scroll wheel        | Zoom in/out                                     |
| Z                   | Cycle zoom presets (1x-8x)                      |
| 1-9                 | Select material                                 |
| T                   | Toggle terrain debug heatmap                    |

## Project Structure

```text
src/
├── camera/
│   └── camera_controller.gd        # Smooth-follow camera, zoom presets
├── entities/
│   ├── base_entity.gd              # Base class for game entities (optional MovementController composition)
│   ├── entity_manager.gd           # Entity lifecycle management
│   └── player.gd                   # Input handling, delegates to MovementController
├── game/
│   └── game_instance.gd            # Scene root, registers services
├── globals/
│   ├── game_services.gd            # Service locator autoload
│   ├── global_settings.gd          # World constants (chunk size, frame budgets, terrain-edit tuning)
│   ├── signal_bus.gd               # Global event bus
│   └── tile_index.gd               # Data-driven tile registry, texture array, directional edge hardness
├── gui/
│   ├── debug/
│   │   ├── controls_overlay.gd     # F1 controls help panel
│   │   ├── cursor_info.gd          # F2 tile-under-cursor readout
│   │   └── debug_hud.gd            # F3 perf/world debug HUD
│   ├── hotbar/
│   │   └── hotbar.gd               # Material hotbar, built at runtime from TileIndex
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
    │   ├── chunk_manager.gd         # Main thread chunk orchestration
    │   └── terrain.gdshader         # Tile rendering + debug heatmap shader
    ├── generators/
    │   ├── base_terrain_generator.gd    # Generator interface
    │   └── simplex_terrain_generator.gd # Simplex noise terrain generation
    └── persistence/
        └── world_save_manager.gd    # World save/load (metadata + chunk data)
```
