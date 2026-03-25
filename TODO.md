# TODO

- [ ] Build out terrain editing system, currently we have a basic "paint tiles" mechanic as v1. What we are aiming for is a omni-directional flood fill algorithm, with a force parameter to control how far the fill propagates. This will directly interact with the hardness values of the tiles, so that a stronger edit will break more soft tiles than hard tiles, and will also break tiles along their hardness lines. For example, if you have a cluster of 5 soft tiles surrounded by hard tiles, a weak edit will only break the soft tiles, while a strong edit will break the soft tiles and the surrounding hard tiles. This will allow for more dynamic terrain editing, where players can strategically choose how to modify the terrain based on their needs. Some materials will have variable amounts of hardness, so they can be edited in a more natural way. In a brick wall tile type, the bricks themselves would have a hardness of say 5, while the mortar between them would have a hardness of 3. This way, after the force breaks the mortar, the remaining force would be more focused on the "hollowed out" bricks, since they would be seperated from the rest of the wall. This will allow for more realistic destruction, where edits will still be roughly controllable, but will also break along that actual respective materials' shapes (stones, bricks, glass, planks, etc). This would all be data driven as well, so that new tile types can be added with different hardness values and behaviors without needing to change the underlying algorithm.

## Claude's notes

What works well:

- The force-vs-hardness flood fill is elegant — it naturally produces organic-looking destruction without needing  
  hand-authored break patterns. The force "draining" as it propagates through material gives players intuitive control.
- Sub-tile hardness maps (mortar vs brick) are the standout idea. It means destruction follows material structure rather  
  than arbitrary tile boundaries, which will feel great visually.
- Data-driven approach fits well with your existing TileIndex system — hardness maps are just another tile property.

Things to think through:

1. Sub-tile hardness granularity — Your tiles are currently 2 bytes (tile_id, cell_id). A per-pixel hardness map within a  
   tile means you'd need a separate hardness texture/array per tile type. This is fine as static data on TileIndex, but editing
   at sub-tile resolution means your terrain data needs to track partial destruction state per-cell, not just tile_id. That's
   a significant data model change.
2. "Hollowed out bricks" implication — Once mortar breaks and individual bricks are isolated, are they still part of the
   tile, or do they become separate entities (falling debris)? This is where the design gets complex. Connectivity detection  
   (flood fill to find disconnected sub-regions) is doable but adds cost.
3. Flood fill performance — Omnidirectional flood fill across chunk boundaries needs care with your threading model. The  
   fill itself should be fine on the main thread if capped in radius, but cross-chunk edits already batch by chunk in your  
   current system, so the plumbing is there.
