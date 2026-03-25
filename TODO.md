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

**3. Force propagation algorithm — Dijkstra BFS (max remaining force, not sum)**

The flood fill operates as a max-force Dijkstra from the edit origin:
- Each tile tracks the maximum remaining force that has reached it: `max(current, incoming - entry_cost)`
- A tile breaks when `max_force_reached > 0` (it absorbed the hit, remaining = max_force_reached)
- Propagation continues from broken tiles with remaining force; intact tiles absorb force but don't propagate
- Priority queue ordered by remaining force ensures high-force paths are resolved before low-force ones

The "hollowed bricks get focused force" behavior emerges naturally: once surrounding mortar breaks, bricks can be reached
via multiple paths without paying mortar entry costs again. Every subsequent edit hits them with fuller force. Within a
single edit, they receive the max force from the best path — no artificial boost needed.

**4. Two-phase editing: destruction → structural instability**

Phase 1 (Flood fill): Collect all tiles to destroy and all damage state updates, then batch-apply them through the
existing `ChunkManager.set_tiles_at_world_positions()` plumbing. No new cross-chunk machinery needed.

Phase 2 (Structural instability): After phase 1, run a secondary connectivity flood fill from all tiles that border
permanent world edges or are "ground-anchored". Any solid region not reachable from an anchor is disconnected. Spawn
these as falling `BaseEntity` instances via EntityManager. This phase is optional and can be implemented separately —
phase 1 alone already produces the core destruction behavior.

**5. Thread safety — flood fill stays on main thread**

Flood fill reads terrain data to decide what to break, then writes through the existing locked batch-edit path. Reading
terrain per-tile for pathfinding means temporarily holding chunk mutexes during the read phase, which is fine since the
main thread already does this. Cap flood fill radius (e.g., 64 tiles) to bound worst-case cost.

### Open questions to decide before implementing

1. **Tool parameterization** — Does the player dial in force directly (slider), or does tool type determine it (pickaxe =
   directional + force 8, explosive = radial + force 30)? Tool types also let you bake in initial directionality: a pickaxe
   starts the fill with bias toward the cursor direction, while an explosive starts truly omnidirectional.

2. **Force splitting vs. max-path** — The Dijkstra max-path model is recommended above, but if you want the "focus" effect
   to be stronger within a single edit (not just across edits), a sum-of-paths model gives that at the cost of more complex
   bookkeeping. Worth prototyping both.

3. **Scope of phase 2 (debris)** — Structural instability with spawned entities is a significant system on its own. Confirm
   whether it belongs in the same milestone as the flood fill or is deferred.

### Suggested implementation order

1. Wire force to the existing hardness values — make edits respect hardness (no flood fill yet, just "can I break this?")
2. Add damage stages via cell_id — tile takes partial hits before breaking
3. Implement basic omnidirectional Dijkstra flood fill from edit origin
4. Add directional edge hardness to TileIndex — unlock mortar/brick behavior
5. Add structural instability phase (optional, separate milestone)
