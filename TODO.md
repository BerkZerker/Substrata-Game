# TODO

- [ ] Build out terrain editing system, currently we have a basic "paint tiles" mechanic as v1. What we are aiming for is a omni-directional flood fill algorithm, with a force parameter to control how far the fill propagates. This will directly interact with the hardness values of the tiles, so that a stronger edit will break more soft tiles than hard tiles, and will also break tiles along their hardness lines. For example, if you have a cluster of 5 soft tiles surrounded by hard tiles, a weak edit will only break the soft tiles, while a strong edit will break the soft tiles and the surrounding hard tiles. This will allow for more dynamic terrain editing, where players can strategically choose how to modify the terrain based on their needs. Some materials will have variable amounts of hardness, so they can be edited in a more natural way. In a brick wall tile type, the bricks themselves would have a hardness of say 5, while the mortar between them would have a hardness of 3. This way, after the force breaks the mortar, the remaining force would be more focused on the "hollowed out" bricks, since they would be seperated from the rest of the wall. This will allow for more realistic destruction, where edits will still be roughly controllable, but will also break along that actual respective materials' shapes (stones, bricks, glass, planks, etc). This would all be data driven as well, so that new tile types can be added with different hardness values and behaviors without needing to change the underlying algorithm.

## Claude's notes

### What works well

- The force-vs-hardness flood fill is elegant — it naturally produces organic-looking destruction without needing
  hand-authored break patterns. The force "draining" as it propagates through material gives players intuitive control.
- Sub-tile hardness maps (mortar vs brick) are the standout idea. It means destruction follows material structure rather
  than arbitrary tile boundaries, which will feel great visually.
- Data-driven approach fits well with your existing TileIndex system — hardness maps are just another tile property.

### Resolved design questions (grounded in the actual codebase)

**1. Sub-tile hardness without data model changes — use directional edge hardness**

The sub-tile mortar/brick distinction doesn't require per-pixel maps or a new data structure. Instead, give each tile type
four edge-directional hardness values (N, S, E, W) stored as static data in TileIndex. The flood fill pays the *destination
tile's entry cost from that direction* when crossing a boundary.

Brick wall tile example:
- N/S entry (through horizontal mortar joint): hardness 3
- E/W entry (through brick face): hardness 5

Force naturally flows along mortar lines first (cheap), then stalls at brick faces (expensive). This exactly produces the
"breaks along material structure" behavior described, with zero terrain data changes. New tile types just define their own
edge hardness table.

**2. cell_id is already the damage stage slot — use it**

cell_id is currently always written as 0 and goes unused. It's the perfect fit for partial destruction state, requiring
no data model changes:
- cell_id 0: intact
- cell_id 1: lightly damaged
- cell_id 2: heavily damaged
- (destroyed = replaced with AIR)

Each tile type in TileIndex declares `damage_stages: int` and provides textures for each stage. The shader already reads
cell_id and samples the texture array; rendering is free. When force partially overcomes a tile's hardness — i.e.,
`0 < force < hardness` — the tile steps up one damage stage and the flood fill stops there. On subsequent edits, a damaged
tile's effective hardness is reduced, so it breaks before its intact neighbors.

**3. Force propagation algorithm — max-path Dijkstra (chosen)**

There are two reasonable models; here's a concrete example to make the difference clear.

*Setup*: force=10, mortar hardness=3, brick hardness=5. One brick surrounded by mortar on all 4 sides.

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
Every separate path that arrives at a tile *adds* its remaining force together.
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

**4. Force input — debug slider for now, tool-driven later**

A slider in the debug UI controls force (e.g., 1–50). In the future, different tools (pickaxe,
explosive, drill) will each have a fixed force value and potentially directional bias baked in. For now,
omnidirectional from click origin at whatever force the slider is set to.

**5. Structural instability — destroy small orphaned clusters, no physics**

No falling debris. Instead, after phase 1 (flood fill) completes, run a small cluster cleanup pass:

1. Collect all solid tiles adjacent to any newly-destroyed tile (the "border set").
2. For each border tile not yet processed, BFS outward through connected solid tiles. Stop early once
   the component size exceeds the threshold (e.g., 5 tiles).
3. If BFS completes within the threshold: the component is a small orphaned cluster → destroy it.
4. Batch the cluster destructions into the same `set_tiles_at_world_positions()` call (or a second
   immediate call) so the edit stays atomic from the chunk system's perspective.

This prevents single floating tiles and small orphaned fragments without physics. The early-exit BFS
keeps cost bounded — you never traverse more than `threshold` tiles per border tile. One pass is enough;
cascading re-checks are not needed for reasonable gameplay.

**6. Thread safety — flood fill stays on main thread**

Flood fill reads terrain data to decide what to break, then writes through the existing locked batch-edit
path. Cap flood fill radius (e.g., 64 tiles max from origin) to bound worst-case cost per click.

### Suggested implementation order

1. Wire force to existing hardness values — make edits respect hardness (no flood fill yet, just "can I break this?")
2. Add debug UI slider for force value
3. Add damage stages via cell_id — tile takes partial hits before breaking, effective hardness scales down
4. Implement omnidirectional Dijkstra flood fill from click origin
5. Add small orphaned cluster cleanup pass after flood fill
6. Add directional edge hardness to TileIndex — unlock mortar/brick behavior (separate milestone)
