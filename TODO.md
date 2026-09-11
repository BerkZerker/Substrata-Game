# TODO

- [x] Build out terrain editing system — **implemented.** `TerrainEditor` runs an omni-directional max-path Dijkstra flood fill from the click origin, force decays through tile hardness (and by distance/decay factor), partial hits step up a `damage_stage` before a tile actually breaks, and small orphaned clusters get cleaned up after each edit. See `src/world/terrain_editor.gd` and the "Terrain Editing" section of README.md for the current behavior. Original ask, kept for context:

  Build out terrain editing system, currently we have a basic "paint tiles" mechanic as v1. What we are aiming for is a omni-directional flood fill algorithm, with a force parameter to control how far the fill propagates. This will directly interact with the hardness values of the tiles, so that a stronger edit will break more soft tiles than hard tiles, and will also break tiles along their hardness lines. For example, if you have a cluster of 5 soft tiles surrounded by hard tiles, a weak edit will only break the soft tiles, while a strong edit will break the soft tiles and the surrounding hard tiles. This will allow for more dynamic terrain editing, where players can strategically choose how to modify the terrain based on their needs. Some materials will have variable amounts of hardness, so they can be edited in a more natural way. In a brick wall tile type, the bricks themselves would have a hardness of say 5, while the mortar between them would have a hardness of 3. This way, after the force breaks the mortar, the remaining force would be more focused on the "hollowed out" bricks, since they would be seperated from the rest of the wall. This will allow for more realistic destruction, where edits will still be roughly controllable, but will also break along that actual respective materials' shapes (stones, bricks, glass, planks, etc). This would all be data driven as well, so that new tile types can be added with different hardness values and behaviors without needing to change the underlying algorithm.

## Remaining follow-ups

- [ ] Tool-driven force (pickaxe, explosive, drill with fixed force values and directional bias) — currently force comes from a single Q/E-adjustable `brush_value` (1–50) on `TerrainEditController` that doubles as the place radius, not per-tool.
- [ ] Directional edge hardness is auto-derived from texture luminance (`TileIndex._generate_edge_hardness`) rather than hand-authored per-tile N/S/E/W tables — works for the current three-texture tile set, but a manual override path may be worth adding for tiles where brightness doesn't correlate with structure (e.g. hand-painted brick/mortar art).
- [ ] Per-stage damage art. Damage stages are currently rendered as uniform darkening in `terrain.gdshader` (85% / 65%), not per-stage textures, and the shader only distinguishes stages 0/1/2+ even though `damage_stages` is per-tile data.
- [ ] Save path is `res://data/` (`WorldSaveManager.WORLDS_BASE_PATH`), and the world name is the random per-run seed, so every launch creates a new world folder unless `world_seed` is pinned in `chunk_manager.tscn`. The class docstring still says `user://worlds/`. Decide on the real location (`user://` for exports) and a world-selection flow, then reconcile the docstring and `.gitignore` (which still whitelists `data/.gdignore` / `data/.gitkeep`, both deleted in `055f32a`).
- [ ] `move_up` / `move_down` input actions (W/S) are still defined in `project.godot` but nothing reads them.

## As built vs. the design notes below

The design notes were written before implementation; these are the places where the code deliberately differs:

- **Force input** is Q/E on a `brush_value` with a hotbar readout, not a debug slider.
- **Orphan threshold** is 10 tiles (`GlobalSettings.ORPHAN_CLUSTER_THRESHOLD`), not 5.
- **Neighborhood** is 8-connected; diagonal steps cost 1.4x hardness and 1.4 distance.
- **Extra falloff** beyond the pure "drain by hardness" model: multiplicative `FORCE_DECAY_PER_TILE` (0.85) per break, linear distance falloff to zero at `force * FORCE_DISTANCE_FACTOR` (1.5), a hard `MAX_FLOOD_FILL_RADIUS` (64), and per-tile `break_noise` jitter (stone = 0.5) for jagged edges.
- **Break test vs. propagation cost** are separate: a tile breaks if incoming force ≥ its non-directional effective hardness; the directional edge hardness is what's paid when force crosses into a neighbor.
- **Edge hardness direction:** dark edge pixels are _harder_ (`base * avg_lum / edge_lum`), bright ones softer — the shader heatmap uses the same convention (red = hard/dark, blue = soft/bright).
- **`cell_id` → `damage_stage`** rename is done throughout (`Chunk`, `ChunkLoader`, generators, shader G channel).

## Claude's notes

### What works well

- The force-vs-hardness flood fill is elegant — it naturally produces organic-looking destruction without needing
  hand-authored break patterns. The force "draining" as it propagates through material gives players intuitive control.
- Sub-tile hardness maps (mortar vs brick) are the standout idea. It means destruction follows material structure rather
  than arbitrary tile boundaries, which will feel great visually.
- Data-driven approach fits well with your existing TileIndex system — hardness maps are just another tile property.

### Resolved design questions (grounded in the actual codebase)

### 1. Sub-tile hardness without data model changes — use directional edge hardness

The sub-tile mortar/brick distinction doesn't require per-pixel maps or a new data structure. Instead, give each tile type
four edge-directional hardness values (N, S, E, W) stored as static data in TileIndex. The flood fill pays the _destination
tile's entry cost from that direction_ when crossing a boundary.

Brick wall tile example:

- N/S entry (through horizontal mortar joint): hardness 3
- E/W entry (through brick face): hardness 5

Force naturally flows along mortar lines first (cheap), then stalls at brick faces (expensive). This exactly produces the
"breaks along material structure" behavior described, with zero terrain data changes. New tile types just define their own
edge hardness table.

### 2. cell_id is already the damage stage slot — use it

cell_id is currently always written as 0 and goes unused. It's the perfect fit for partial destruction state, requiring
no data model changes:

- cell_id 0: intact
- cell_id 1: lightly damaged
- cell_id 2: heavily damaged
- (destroyed = replaced with AIR)

note that if we do this, we should rename it from cell_id to damage_stage or something more intuitive.

Each tile type in TileIndex declares `damage_stages: int` and provides textures for each stage. The shader already reads
cell_id and samples the texture array; rendering is free. When force partially overcomes a tile's hardness — i.e.,
`0 < force < hardness` — the tile steps up one damage stage and the flood fill stops there. On subsequent edits, a damaged
tile's effective hardness is reduced, so it breaks before its intact neighbors.

### 3. Force propagation algorithm — max-path Dijkstra (chosen)

There are two reasonable models; here's a concrete example to make the difference clear.

_Setup_: force=10, mortar hardness=3, brick hardness=5. One brick surrounded by mortar on all 4 sides.

**Max-path (Dijkstra) — chosen:**
Force from the origin propagates outward, and each tile records the single best (highest) remaining force
that could reach it from any one direction.

- Origin → mortar: 10 − 3 = 7 remaining. Mortar breaks. Force = 7.
- Mortar → brick (from one side): 7 − 5 = 2 remaining. Brick breaks. Force = 2 continues outward.
- The other 3 mortar neighbors also arrive at the brick with 7, but since it already broke via the first
  path, they don't re-break it. The 2 remaining propagates outward.

The rule is simple: **force drains by hardness cost along each path; a tile breaks if the best path's
remaining force > 0 after paying that tile's cost.** Long paths through expensive material exhaust force
before reaching distant tiles. This is easy to predict and reason about as a player.

**Sum-of-paths (not chosen):**
Every separate path that arrives at a tile _adds_ its remaining force together.

- All 4 mortar neighbors arrive at the brick simultaneously, each contributing 7.
- Total force on brick = 4 × 7 = 28. Brick easily breaks.
- A tile exposed from many sides takes much more effective damage than one reached from only one direction.

This makes exposed/isolated tiles dramatically easier to break in a single edit — but it's harder to
predict ("why did this brick break but that one didn't?"), and combining multiple force values raises
questions without clear answers (sum? average? diminishing returns?).

**Why max-path wins here:** The "hollowed bricks get focused force" behavior works across edits, not
within one. Edit 1 breaks the mortar. Edit 2 arrives at the now-exposed brick with full force from any
direction since the mortar is already gone. The focusing is real and satisfying — it just plays out over
two clicks rather than one. Within a single edit, max-path is simpler, cheaper, and more legible.

Implementation: Dijkstra priority queue ordered by remaining force (highest first). Each tile visited
at most once. Priority queue entry: `(remaining_force, tile_pos)`.

### 4. Force input — debug slider for now, tool-driven later

A slider in the debug UI controls force (e.g., 1–50). In the future, different tools (pickaxe,
explosive, drill) will each have a fixed force value and potentially directional bias baked in. For now,
omnidirectional from click origin at whatever force the slider is set to.

### 5. Structural instability — destroy small orphaned clusters, no physics

No falling debris. Instead, after phase 1 (flood fill) completes, run a small cluster cleanup pass:

1. Collect all solid tiles adjacent to any newly-destroyed tile (the "border set").
2. For each border tile not yet processed, BFS outward through connected solid tiles. Stop early once
   the component size exceeds the threshold (e.g., 5 tiles, define this in settings).
3. If BFS completes within the threshold: the component is a small orphaned cluster → destroy it.
4. Batch the cluster destructions into the same `set_tiles_at_world_positions()` call (or a second
   immediate call) so the edit stays atomic from the chunk system's perspective.

This prevents single floating tiles and small orphaned fragments without physics. The early-exit BFS
keeps cost bounded — you never traverse more than `threshold` tiles per border tile. One pass is enough;
cascading re-checks are not needed for reasonable gameplay.

### 6. Thread safety — flood fill stays on main thread

Flood fill reads terrain data to decide what to break, then writes through the existing locked batch-edit
path. Cap flood fill radius (e.g., 64 tiles max from origin) to bound worst-case cost per click.

### Implementation order (all complete)

1. [x] Wire force to existing hardness values — make edits respect hardness
2. [x] Add a force control & update shader to visualize hardness & damage values (landed as Q/E `brush_value` + T heatmap, not a slider)
3. [x] Add damage stages via `damage_stage` — tile takes partial hits before breaking, effective hardness scales down
4. [x] Implement omnidirectional Dijkstra flood fill from click origin
5. [x] Add small orphaned cluster cleanup pass after flood fill
6. [x] Add directional edge hardness to TileIndex (texture-derived rather than hand-authored)
