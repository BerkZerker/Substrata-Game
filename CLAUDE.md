# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Substrata is a 2D voxel-based game built in **Godot 4.6** using **GDScript**. It features procedurally generated, editable terrain with a multithreaded chunk loading system. The main scene is `src/game/game_instance.tscn`.

## Running the Project

Open in Godot 4.6 and press F5. There is no external build system, test framework, or linter — everything runs through the Godot editor.

## Code Style

- GDScript files use 4-space indentation (see `.editorconfig`)
- UTF-8 encoding, LF line endings
- High cohesion within files, low coupling between scripts

## Architecture

### Threading Model (Producer-Consumer)

The core system uses a background thread for chunk generation:

- **ChunkManager** (`src/world/chunks/chunk_manager.gd`) — Main thread orchestrator. Monitors player position, queues chunk generation/removal, and processes built chunks each frame (max 16 builds, 32 removals per frame).
- **ChunkLoader** (`src/world/chunks/chunk_loader.gd`) — Background worker thread. Generates terrain data and visual images off the main thread. Uses Mutex/Semaphore for synchronization with backpressure (pauses when build queue exceeds threshold).
- **Chunk** (`src/world/chunks/chunk.gd`) — Individual chunk with terrain stored as `PackedByteArray` (2 bytes per tile: `[tile_id, cell_id]`). Uses a shared `QuadMesh` and a fragment shader for rendering. Mutex-protected terrain data.

### Rendering Pipeline

Terrain data flows: `PackedByteArray` → `Image` (RGBA8, R=tile_id, G=cell_id) → `ImageTexture` → fragment shader (`src/world/chunks/terrain.gdshader`) which decodes tile/cell IDs and maps to texture atlas (dirt/grass/stone).

### Terrain Generation

`TerrainGenerator` (`src/world/generators/terrain_generator.gd`) uses `FastNoiseLite` (Simplex noise) to produce layered terrain (grass surface → dirt → stone) with procedural caves. Runs entirely in the background thread — no Godot scene API calls allowed here.

### Collision System

Custom **swept AABB** collision detection (`src/physics/collision_detector.gd`) — does not use Godot's built-in physics. Sweeps X then Y axis separately, calculates collision normals and times. Physics layers: terrain (layer 1), player (layer 2).

### Global Autoloads

Three autoloaded singletons (registered in `project.godot`):

- **SignalBus** (`src/globals/signal_bus.gd`) — Global event bus. Emits `player_chunk_changed` to decouple player position tracking from chunk loading.
- **GlobalSettings** (`src/globals/global_settings.gd`) — World constants: `CHUNK_SIZE=32`, `REGION_SIZE=4`, `LOD_RADIUS=4`, `MAX_CHUNK_POOL_SIZE=512`, frame budget limits.
- **TileIndex** (`src/globals/tile_index.gd`) — Tile type constants: `AIR=0, DIRT=1, GRASS=2, STONE=3`.

### Scene Tree Structure

```text
GameInstance (Node)
├── World (Node2D)
│   ├── ChunkManager (Node2D) — owns all Chunk children
│   └── Player (CharacterBody2D)
└── UILayer (CanvasLayer)
    └── GUIManager (Control)
```

`GameInstance._ready()` wires cross-references: passes ChunkManager to both Player (for collision) and GUIManager (for editing).

### Terrain Editing

GUI (`src/gui/gui_manager.gd`) captures mouse input → calculates affected tiles by brush shape/size → batches changes as `{pos, tile_id, cell_id}` arrays → ChunkManager groups by chunk → each chunk updates data + re-uploads texture to GPU.

### Player

`src/entities/player.gd` — Platformer movement with gravity, coyote jump, and step-up mechanics. Uses the custom swept AABB collision system, not Godot's CharacterBody2D.

## Key Constraints

- **Thread safety**: Any code that touches chunk terrain data must acquire the chunk's mutex. TerrainGenerator and ChunkLoader must not call Godot scene tree APIs.
- **Frame budget**: Chunk builds and removals are capped per frame to prevent stuttering. These limits are in `GlobalSettings`.
- **Chunk pooling**: Chunks are recycled from a pool (up to `MAX_CHUNK_POOL_SIZE`) to avoid instantiation overhead. Don't create chunk instances directly — use the pool in ChunkManager.
- **Y-inversion**: The `_generate_visual_image` method in ChunkLoader and the `edit_tiles` method in Chunk both apply Y-inversion when writing to the Image. This is required for correct rendering alignment between the PackedByteArray data layout and Image coordinate system. Do not remove it.
- **Coordinate convention**: Standard Godot Y-down (`+Y = down`). Gravity is positive (800), jump velocity is negative (-400).
