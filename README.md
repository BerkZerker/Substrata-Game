# Substrata

A 2D voxel-based game built in **Godot 4.6** with **GDScript**. Features procedurally generated, editable terrain with a multithreaded chunk loading system.

## Running

Open in Godot 4.6 and press F5.

## Architecture

### Chunk System

Terrain is divided into 32x32 tile chunks, managed by a producer-consumer threading model:

- **ChunkManager** — Main thread orchestrator. Monitors player position, queues chunk generation/removal, and processes built chunks each frame (capped at 16 builds, 32 removals per frame to prevent stuttering).
- **ChunkLoader** — Parallel chunk generation scheduler using Godot's `WorkerThreadPool`. Submits tasks up to a concurrency limit, generates terrain data and visual images off the main thread. Uses Mutex synchronization with backpressure when the build queue gets too large.
- **Chunk** — Individual chunk storing terrain as a `PackedByteArray` (2 bytes per tile: `[tile_id, cell_id]`). Rendered via a shared `QuadMesh` and fragment shader. Chunks are pooled and recycled to avoid instantiation overhead.

### Rendering

Terrain data flows through: `PackedByteArray` → `Image` (RGBA8, R=tile_id, G=cell_id) → `ImageTexture` → fragment shader that decodes IDs and maps to a texture atlas (dirt, grass, stone). Edits update the existing `ImageTexture` in-place to avoid GPU allocations.

### Terrain Generation

Uses `FastNoiseLite` (Simplex noise) with threshold-based material assignment. Runs entirely in the background thread.

### Physics

Custom swept AABB collision detection against the tile grid — does not use Godot's built-in physics. Sweeps X then Y axis separately with collision normals and step-up support.

### Movement

`MovementController` is a reusable physics controller handling gravity, horizontal acceleration/friction, coyote jump timing, and step-up mechanics. The player composes with it and just provides input — any future entity can reuse the same movement system.

### Terrain Editing

Click and hold to paint tiles. Square and circle brush shapes, Q/E to resize. Changes are batched by chunk for efficient GPU updates.

### Service Locator

`GameServices` autoload holds references to shared systems (`chunk_manager`, `entity_manager`, `tile_registry`, `terrain_generator`, `world_save_manager`). Systems access it lazily — no manual wiring required when adding new scripts that need shared state.

## Scene Tree

```text
GameInstance (Node)
├── Player (CharacterBody2D)
├── CameraController (Camera2D)
├── ChunkManager (Node2D)
├── EntityManager (Node)
├── ChunkDebugOverlay (Node2D)
└── UILayer (CanvasLayer)
    └── GUIManager (Control)
```

## Debug Overlay

Press F1-F6 to toggle debug visualizations:

| Key | Overlay                                                  |
| --- | -------------------------------------------------------- |
| F1  | Toggle all                                               |
| F2  | Chunk borders                                            |
| F3  | Region borders                                           |
| F4  | Generation queue                                         |
| F5  | Removal queue                                            |
| F6  | Queue info (loaded chunks, queue sizes, player position) |

## Controls

| Key               | Action                       |
| ----------------- | ---------------------------- |
| A/D               | Move left/right              |
| Space             | Jump                         |
| Left Click (hold) | Paint tiles                  |
| Q/E               | Decrease/increase brush size |
| Scroll wheel      | Zoom in/out                  |
| Z                 | Cycle zoom presets (1x–8x)   |
| 1-4               | Select material              |

## Project Structure

```text
src/
├── camera/
│   └── camera_controller.gd        # Smooth-follow camera, zoom presets
├── entities/
│   ├── base_entity.gd              # Base class for game entities
│   ├── entity_manager.gd           # Entity lifecycle management
│   └── player.gd                   # Input handling, delegates to MovementController
├── game/
│   └── game_instance.gd            # Scene root, registers services
├── globals/
│   ├── game_services.gd            # Service locator autoload
│   ├── global_settings.gd          # World constants (chunk size, frame budgets)
│   ├── signal_bus.gd               # Global event bus
│   └── tile_index.gd               # Tile registry (AIR, DIRT, GRASS, STONE)
├── gui/
│   ├── brush_preview.gd            # World-space brush outline
│   ├── chunk_debug_overlay.gd      # Debug visualization (F1-F6)
│   ├── controls_overlay.gd         # On-screen controls display
│   ├── cursor_info.gd              # Cursor position/tile info
│   ├── debug_hud.gd                # Debug HUD
│   ├── editing_toolbar.gd          # Brush type, material, size toolbar
│   └── gui_manager.gd              # Editing UI, brush logic
├── physics/
│   ├── collision_detector.gd        # Swept AABB collision against tile grid
│   └── movement_controller.gd       # Reusable movement physics
└── world/
    ├── chunks/
    │   ├── chunk.gd                 # Terrain data + rendering per chunk
    │   ├── chunk_loader.gd          # WorkerThreadPool chunk generation
    │   ├── chunk_manager.gd         # Main thread chunk orchestration
    │   └── terrain.gdshader         # Tile rendering shader
    ├── generators/
    │   ├── base_terrain_generator.gd  # Generator interface
    │   └── simplex_terrain_generator.gd # Simplex noise terrain generation
    └── persistence/
        └── world_save_manager.gd    # World save/load (metadata + chunk data)
```
