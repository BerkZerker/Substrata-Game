use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;
use glam::{I64Vec2, IVec2, Vec2};

use crate::game::signals::SignalBus;
use crate::game::tiles::{TileRegistry, AIR, BRICK, GLASS, MORTAR, PLANK, STONE};
use crate::game::world::chunk_manager::{ChunkManager, WorldTileChange};

/// Fixed-point units per tile (`1/256` tile), matching LithiumEngine (`place/families/mod.rs`).
pub const FX: i32 = 256;
/// Material slots a [`PlaceCommand`] carries (`0` = piece, `1` = joint/mortar).
pub const MAX_PATTERN_MATERIALS: usize = 4;
/// Integer extent parameters a 2D [`PlaceCommand`] carries.
pub const MAX_EXTENT: usize = 2;
/// Largest local bounds of one placement on any axis, in tiles.
pub const MAX_PLACE_TILES: i32 = 512;
/// Fixed-point units of a unit sine or cosine (`2^30`).
pub const TRIG_ONE: i64 = 1 << 30;
/// Reach in tiles for snapping to nearby placements.
pub const SNAP_REACH: i32 = 16;
/// Maximum piece outlines drawn in the build preview.
pub const MAX_OUTLINE_PIECES: usize = 512;
/// Serial reserved for dry-run previews (never stored as a record).
pub const PREVIEW_SERIAL: u64 = u64::MAX;

/// 2π in units of `2^-60`, rounded.
const TWO_PI_Q60: i128 = 7_244_019_458_077_122_842;
/// Yaw units per quarter turn (`65536 / 4`).
const QUARTER: u32 = 1 << 14;

#[inline]
pub fn floor_div(a: i32, b: i32) -> i32 {
    a.div_euclid(b)
}

#[inline]
pub fn ceil_div(a: i32, b: i32) -> i32 {
    (a + b - 1).div_euclid(b)
}

#[inline]
pub fn size_ok(n: i64) -> bool {
    (1..=MAX_PLACE_TILES as i64).contains(&n)
}

/// `(sin, cos)` of `x` radians in `2^-60` (`0 <= x <= π/4`): Taylor terms to `x^19`.
fn taylor(x: i128) -> (i128, i128) {
    const ONE: i128 = 1 << 60;
    let x2 = (x * x) >> 60;
    let (mut sin, mut cos) = (x, ONE);
    let (mut ts, mut tc) = (x, ONE);
    for k in 1..=9i128 {
        ts = -((ts * x2) >> 60) / ((2 * k) * (2 * k + 1));
        tc = -((tc * x2) >> 60) / ((2 * k - 1) * (2 * k));
        sin += ts;
        cos += tc;
    }
    (sin, cos)
}

/// `(sin, cos)` of `yaw` turns/65536 in units of [`TRIG_ONE`], exact at the quarter turns.
/// Ported from LithiumEngine (`crates/lithium-core/src/place/rotate.rs`).
pub fn sin_cos(yaw: u16) -> (i64, i64) {
    let a = yaw as u32;
    let (quadrant, r) = (a / QUARTER, a % QUARTER);
    let q60 = |r: u32| (TWO_PI_Q60 * r as i128) >> 16;
    let round = |v: i128| ((v + (1 << 29)) >> 30) as i64;
    let (s, c) = if r <= QUARTER / 2 {
        let (s, c) = taylor(q60(r));
        (round(s), round(c))
    } else {
        let (s, c) = taylor(q60(QUARTER - r));
        (round(c), round(s))
    };
    match quadrant {
        0 => (s, c),
        1 => (c, -s),
        2 => (-s, -c),
        _ => (-c, s),
    }
}

#[inline]
fn round30(v: i64) -> i64 {
    (v + (1 << 29)) >> 30
}

/// A 2D rotation in fixed-point units.
/// At `yaw = 0`, pattern-local `+x` runs along world `+X` (right) and pattern-local `+y`
/// (courses upward) runs along world `-Y` (up in Substrata's Y-down world space).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Yaw2D {
    pub sin: i64,
    pub cos: i64,
}

impl Yaw2D {
    pub fn new(yaw: u16) -> Self {
        let (sin, cos) = sin_cos(yaw);
        Self { sin, cos }
    }

    /// World offset of pattern-local offset `l` (both in `1/256` tile fixed-point).
    #[inline]
    pub fn to_world(&self, l: I64Vec2) -> I64Vec2 {
        I64Vec2::new(
            round30(l.x * self.cos - l.y * self.sin),
            round30(-l.x * self.sin - l.y * self.cos),
        )
    }

    /// Pattern-local offset of world offset `w` (inverse of [`Yaw2D::to_world`]).
    #[inline]
    pub fn to_local(&self, w: I64Vec2) -> I64Vec2 {
        I64Vec2::new(
            round30(w.x * self.cos - w.y * self.sin),
            round30(-w.x * self.sin - w.y * self.cos),
        )
    }
}

/// Fixed-point center of global tile `v` (`1/256` tile).
#[inline]
pub fn tile_centre(v: IVec2) -> I64Vec2 {
    v.as_i64vec2() * (FX as i64) + (FX as i64 / 2)
}

/// Computes the anchor for a free placement starting at `tile` with rotation `yaw`
/// such that `tile`'s center maps to local `(128, 128)` (the `(0, 0)` local tile).
#[inline]
pub fn free_anchor_for_tile(tile: IVec2, yaw: u16) -> I64Vec2 {
    let rot = Yaw2D::new(yaw);
    let half = FX as i64 / 2;
    tile_centre(tile) - rot.to_world(I64Vec2::splat(half))
}

/// Converts a fixed-point anchor/point (`1/256` tile) to world `Vec2`.
#[inline]
pub fn fixed_to_world(p: I64Vec2) -> Vec2 {
    Vec2::new(p.x as f32 / FX as f32, p.y as f32 / FX as f32)
}

/// What happens to existing solid tiles in the way of a placement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Overlap {
    /// Refuse the entire placement if any written tile is already solid.
    #[default]
    Refuse,
    /// Write only into `AIR` tiles, keeping existing solid tiles intact.
    FillAir,
    /// Overwrite all tiles covered by the pattern.
    Overwrite,
}

impl Overlap {
    pub const ALL: [Overlap; 3] = [Overlap::Refuse, Overlap::FillAir, Overlap::Overwrite];

    pub fn name(self) -> &'static str {
        match self {
            Overlap::Refuse => "refuse",
            Overlap::FillAir => "fill air",
            Overlap::Overwrite => "overwrite",
        }
    }

    pub fn next(self) -> Self {
        match self {
            Overlap::Refuse => Overlap::FillAir,
            Overlap::FillAir => Overlap::Overwrite,
            Overlap::Overwrite => Overlap::Refuse,
        }
    }
}

/// Position and orientation of a placement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PlacePose {
    pub anchor: I64Vec2,
    pub yaw: u16,
}

/// A deterministic command to place a pattern into the world (`crates/lithium-core/src/place.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PlaceCommand {
    pub pattern: u16,
    pub anchor: I64Vec2,
    pub yaw: u16,
    pub extent: [i32; MAX_EXTENT],
    pub materials: [u8; MAX_PATTERN_MATERIALS],
    pub seed: u32,
    pub overlap: Overlap,
    pub serial: u64,
}

impl PlaceCommand {
    pub fn pose(&self) -> PlacePose {
        PlacePose {
            anchor: self.anchor,
            yaw: self.yaw,
        }
    }
}

/// Axis-aligned bounding box in pattern-local tile coordinates `[min, max)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocalBox {
    pub min: IVec2,
    pub max: IVec2,
}

impl LocalBox {
    pub fn new(min: IVec2, max: IVec2) -> Self {
        Self { min, max }
    }

    pub fn is_empty(&self) -> bool {
        self.min.x >= self.max.x || self.min.y >= self.max.y
    }

    pub fn intersect(&self, other: &Self) -> Self {
        Self {
            min: self.min.max(other.min),
            max: self.max.min(other.max),
        }
    }

    /// Returns the 4 corners of this local box transformed into world space for `pose`.
    pub fn world_corners(&self, pose: PlacePose) -> [Vec2; 4] {
        let yaw = Yaw2D::new(pose.yaw);
        let corners_local = [
            IVec2::new(self.min.x, self.min.y),
            IVec2::new(self.max.x, self.min.y),
            IVec2::new(self.max.x, self.max.y),
            IVec2::new(self.min.x, self.max.y),
        ];
        corners_local.map(|c| {
            let w = pose.anchor + yaw.to_world(c.as_i64vec2() * (FX as i64));
            fixed_to_world(w)
        })
    }
}

/// What a pattern classifies a local point as.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cell {
    Empty,
    Joint { slot: u8 },
    Piece { piece: u32, slot: u8 },
}

/// Direction of a snap slot relative to a previous placement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SlotKind {
    Next,
    Previous,
    Above,
    Below,
}

impl SlotKind {
    pub fn name(self) -> &'static str {
        match self {
            SlotKind::Next => "next",
            SlotKind::Previous => "prev",
            SlotKind::Above => "above",
            SlotKind::Below => "below",
        }
    }
}

/// A snap slot offset in pattern-local fixed-point coordinates (`1/256` tile).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Slot {
    pub kind: SlotKind,
    pub offset: IVec2,
}

/// A family of 2D placements (`Masonry`, `Stone`, `Plank`, `Pane`).
/// Ported from LithiumEngine (`crates/lithium-core/src/place/pattern.rs`).
pub trait Pattern: Send + Sync + std::fmt::Debug {
    fn name(&self) -> &str;
    fn family_name(&self) -> &'static str;
    fn material_slots(&self) -> usize;
    fn slot_names(&self) -> &[&'static str];
    fn default_materials(&self) -> [u8; MAX_PATTERN_MATERIALS];
    fn check(&self, place: &PlaceCommand) -> Result<(), &'static str>;
    fn bounds(&self, place: &PlaceCommand) -> LocalBox;
    fn classify(&self, place: &PlaceCommand, p: IVec2) -> Cell;
    fn piece_box(&self, place: &PlaceCommand, piece: u32) -> Option<LocalBox>;
    fn next_slots(&self, place: &PlaceCommand, out: &mut Vec<Slot>);
    fn drag_extent(&self, size: IVec2) -> [i32; MAX_EXTENT] {
        size.max(IVec2::ONE).to_array()
    }
}

pub type SharedPattern = Arc<dyn Pattern>;

/// Visits every world tile `v` whose center, turned into the pattern frame of `pose`,
/// lies within `bounds` (`[bounds.min * 256, bounds.max * 256)`).
pub fn for_each_tile(pose: PlacePose, bounds: LocalBox, mut f: impl FnMut(IVec2, IVec2)) {
    if bounds.is_empty() {
        return;
    }
    let corners = bounds.world_corners(pose);
    let mut min_x = f32::INFINITY;
    let mut max_x = f32::NEG_INFINITY;
    let mut min_y = f32::INFINITY;
    let mut max_y = f32::NEG_INFINITY;
    for c in corners {
        min_x = min_x.min(c.x);
        max_x = max_x.max(c.x);
        min_y = min_y.min(c.y);
        max_y = max_y.max(c.y);
    }

    let x0 = (min_x.floor() as i32) - 1;
    let x1 = (max_x.ceil() as i32) + 1;
    let y0 = (min_y.floor() as i32) - 1;
    let y1 = (max_y.ceil() as i32) + 1;

    let yaw = Yaw2D::new(pose.yaw);
    let lo = bounds.min * FX;
    let hi = bounds.max * FX;

    for y in y0..=y1 {
        for x in x0..=x1 {
            let v = IVec2::new(x, y);
            let local64 = yaw.to_local(tile_centre(v) - pose.anchor);
            let p = IVec2::new(local64.x as i32, local64.y as i32);
            if p.x >= lo.x && p.x < hi.x && p.y >= lo.y && p.y < hi.y {
                f(v, p);
            }
        }
    }
}

/// Converts a world tile `v`'s center into the pattern-local frame of `(pose, bounds)`,
/// returning `Some(local_point)` if it lies inside `bounds`.
pub fn local_point(pose: PlacePose, yaw: &Yaw2D, bounds: &LocalBox, v: IVec2) -> Option<IVec2> {
    let local64 = yaw.to_local(tile_centre(v) - pose.anchor);
    let p = IVec2::new(local64.x as i32, local64.y as i32);
    let lo = bounds.min * FX;
    let hi = bounds.max * FX;
    (p.x >= lo.x && p.x < hi.x && p.y >= lo.y && p.y < hi.y).then_some(p)
}

/// Collects the local bounding boxes of up to `cap` pieces in `place`, clipped to `bounds`.
pub fn piece_boxes(
    pattern: &dyn Pattern,
    place: &PlaceCommand,
    cap: usize,
    out: &mut Vec<(u32, LocalBox)>,
) {
    out.clear();
    if pattern.check(place).is_err() {
        return;
    }
    let bounds = pattern.bounds(place);
    if bounds.is_empty() {
        return;
    }
    let mut seen: BTreeMap<u32, LocalBox> = BTreeMap::new();
    let mut ny = bounds.min.y;
    while ny < bounds.max.y {
        let mut nx = bounds.min.x;
        while nx < bounds.max.x {
            let p = IVec2::new(nx * FX + FX / 2, ny * FX + FX / 2);
            if let Cell::Piece { piece, .. } = pattern.classify(place, p) {
                let tile_box = LocalBox::new(IVec2::new(nx, ny), IVec2::new(nx + 1, ny + 1));
                seen.entry(piece)
                    .and_modify(|b| {
                        b.min = b.min.min(tile_box.min);
                        b.max = b.max.max(tile_box.max);
                    })
                    .or_insert_with(|| {
                        pattern
                            .piece_box(place, piece)
                            .map(|pb| pb.intersect(&bounds))
                            .unwrap_or(tile_box)
                    });
            }
            nx += 1;
        }
        ny += 1;
    }
    for (piece, b) in seen.into_iter().take(cap) {
        if !b.is_empty() {
            out.push((piece, b));
        }
    }
}

// ============================================================================
// Family 1: Masonry (Running, Stack, Flemish bonds)
// Ported from `crates/lithium-core/src/place/families/masonry.rs`
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Bond {
    /// Stretchers, odd courses shifted by half a brick.
    Running,
    /// Stretchers, every joint lined up.
    Stack,
    /// Headers and stretchers alternating, odd courses shifted so each header sits centered on a stretcher.
    Flemish,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Masonry {
    pub name: String,
    pub bond: Bond,
    pub brick: IVec2,
    pub mortar: i32,
    pub materials: [u8; MAX_PATTERN_MATERIALS],
    unit_seq: [i32; 2],
    unit_len: usize,
}

impl Masonry {
    pub fn new(
        name: impl Into<String>,
        bond: Bond,
        brick: IVec2,
        mortar: i32,
        piece_mat: u8,
        mortar_mat: u8,
    ) -> Self {
        let (unit_seq, unit_len) = match bond {
            Bond::Running | Bond::Stack => ([brick.x, 0], 1),
            Bond::Flemish => ([brick.y, brick.x], 2),
        };
        Self {
            name: name.into(),
            bond,
            brick,
            mortar,
            materials: [piece_mat, mortar_mat, 0, 0],
            unit_seq,
            unit_len,
        }
    }

    fn units(&self) -> &[i32] {
        &self.unit_seq[..self.unit_len]
    }

    fn period(&self) -> i32 {
        self.units().iter().map(|u| u + self.mortar).sum()
    }

    fn course(&self) -> i32 {
        self.brick.y + self.mortar
    }

    fn length(&self, n: i32) -> i64 {
        let u = self.units();
        (0..n.max(0) as usize)
            .map(|i| (u[i % u.len()] + self.mortar) as i64)
            .sum()
    }

    fn shift(&self, j: i32) -> i32 {
        match self.bond {
            Bond::Stack => 0,
            Bond::Running | Bond::Flemish => (j & 1) * self.period() * FX / 2,
        }
    }

    fn per_course(&self, place: &PlaceCommand) -> i32 {
        self.length(place.extent[0]) as i32 + 2 * self.units().len() as i32 + 2
    }
}

impl Pattern for Masonry {
    fn name(&self) -> &str {
        &self.name
    }

    fn family_name(&self) -> &'static str {
        "masonry"
    }

    fn material_slots(&self) -> usize {
        if self.mortar > 0 { 2 } else { 1 }
    }

    fn slot_names(&self) -> &[&'static str] {
        if self.mortar > 0 {
            &["brick", "mortar"]
        } else {
            &["brick"]
        }
    }

    fn default_materials(&self) -> [u8; MAX_PATTERN_MATERIALS] {
        self.materials
    }

    fn check(&self, place: &PlaceCommand) -> Result<(), &'static str> {
        let [n, c] = place.extent;
        if n < 1 || c < 1 {
            return Err("masonry: at least one unit and one course");
        }
        if !size_ok(self.length(n)) || !size_ok(c as i64 * self.course() as i64) {
            return Err("masonry: wall too large");
        }
        Ok(())
    }

    fn bounds(&self, place: &PlaceCommand) -> LocalBox {
        let [n, c] = place.extent;
        LocalBox::new(IVec2::ZERO, IVec2::new(self.length(n) as i32, c * self.course()))
    }

    fn classify(&self, place: &PlaceCommand, p: IVec2) -> Cell {
        let (m, py) = (self.mortar * FX, self.course() * FX);
        let j = floor_div(p.y, py);
        if p.y - j * py < m {
            return Cell::Joint { slot: 1 };
        }
        let units = self.units();
        let period = self.period() * FX;
        let t = p.x - self.shift(j) - m;
        let q = floor_div(t, period);
        let mut r = t - q * period;
        for (i, &u) in units.iter().enumerate() {
            if r < u * FX {
                let k = q * units.len() as i32 + i as i32 + units.len() as i32;
                let piece = (j * self.per_course(place) + k) as u32;
                return Cell::Piece { piece, slot: 0 };
            }
            r -= u * FX;
            if r < m {
                return Cell::Joint { slot: 1 };
            }
            r -= m;
        }
        Cell::Joint { slot: 1 }
    }

    fn piece_box(&self, place: &PlaceCommand, piece: u32) -> Option<LocalBox> {
        let k_per = self.per_course(place);
        if k_per <= 0 {
            return None;
        }
        let (j, k) = (piece as i32 / k_per, piece as i32 % k_per);
        let units = self.units();
        let len = units.len() as i32;
        let k = k - len;
        let (q, i) = (floor_div(k, len), k.rem_euclid(len) as usize);
        let before: i32 = units[..i].iter().map(|u| u + self.mortar).sum();
        let x0 = self.shift(j) + self.mortar * FX + q * self.period() * FX + before * FX;
        let y0 = j * self.course() + self.mortar;
        let b = LocalBox::new(
            IVec2::new(floor_div(x0, FX), y0),
            IVec2::new(ceil_div(x0 + units[i] * FX, FX), y0 + self.brick.y),
        )
        .intersect(&self.bounds(place));
        (!b.is_empty()).then_some(b)
    }

    fn drag_extent(&self, size: IVec2) -> [i32; MAX_EXTENT] {
        let mut n = 1;
        while self.length(n) < size.x as i64 && self.length(n) < MAX_PLACE_TILES as i64 {
            n += 1;
        }
        let courses = ceil_div(size.y.max(1), self.course()).max(1);
        [n, courses]
    }

    fn next_slots(&self, place: &PlaceCommand, out: &mut Vec<Slot>) {
        let [n, c] = place.extent;
        let l = self.length(n) as i32 * FX;
        let h = c * self.course() * FX;
        out.push(Slot {
            kind: SlotKind::Next,
            offset: IVec2::new(l, 0),
        });
        out.push(Slot {
            kind: SlotKind::Previous,
            offset: IVec2::new(-l, 0),
        });
        out.push(Slot {
            kind: SlotKind::Above,
            offset: IVec2::new(self.shift(c), h),
        });
        out.push(Slot {
            kind: SlotKind::Below,
            offset: IVec2::new(self.shift(c), -h),
        });
    }
}

// ============================================================================
// Family 2: Stone (2D Voronoi fracture cells with optional mortar)
// Ported from `crates/lithium-core/src/place/families/stone.rs` & `fracture.rs`
// ============================================================================

const STONE_SALT: u32 = 0x5701_7E5D;
const FRACTURE_SALT: u32 = 0xF4AC_7C31;

#[inline]
fn hash2(seed: u32, x: i32, y: i32) -> u32 {
    let mut h = seed.wrapping_add((x as u32).wrapping_mul(0x9E37_79B1));
    h ^= (y as u32).wrapping_mul(0x85EB_CA77);
    h = (h ^ (h >> 16)).wrapping_mul(0x7FEB_352D);
    h = (h ^ (h >> 15)).wrapping_mul(0x846C_A68B);
    h ^ (h >> 16)
}

#[inline]
fn feature_2d(seed: u32, s: i32, g: IVec2) -> IVec2 {
    let h = hash2(seed ^ FRACTURE_SALT, g.x, g.y);
    let su = s as u32;
    g * s + IVec2::new((h % su) as i32, ((h >> 11) % su) as i32)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellHit2D {
    pub cell: IVec2,
    pub gap: i64,
}

/// Deterministic 2D Voronoi cell lookup for cell edge `s` and `seed`.
pub fn cell_at_2d(seed: u32, s: u16, v: IVec2) -> CellHit2D {
    let s = (s as i32).max(2);
    let g = v.div_euclid(IVec2::splat(s));
    let mut best_cell = g;
    let mut f1 = i64::MAX;
    let mut f2 = i64::MAX;

    for dy in -1..=1 {
        for dx in -1..=1 {
            let c = g + IVec2::new(dx, dy);
            let fp = feature_2d(seed, s, c);
            let diff = (v - fp).as_i64vec2();
            let d = diff.x * diff.x + diff.y * diff.y;
            if d < f1 {
                f2 = f1;
                f1 = d;
                best_cell = c;
            } else if d < f2 {
                f2 = d;
            }
        }
    }

    CellHit2D {
        cell: best_cell,
        gap: f2.saturating_sub(f1),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StonePattern {
    pub name: String,
    pub cell: i32,
    pub mortar: i32,
    pub materials: [u8; MAX_PATTERN_MATERIALS],
}

impl StonePattern {
    pub fn new(
        name: impl Into<String>,
        cell: i32,
        mortar: i32,
        stone_mat: u8,
        mortar_mat: u8,
    ) -> Self {
        Self {
            name: name.into(),
            cell,
            mortar,
            materials: [stone_mat, mortar_mat, 0, 0],
        }
    }

    fn grid(&self, place: &PlaceCommand) -> IVec2 {
        let e = IVec2::from_array(place.extent);
        IVec2::new(ceil_div(e.x, self.cell), ceil_div(e.y, self.cell)) + 2
    }

    fn seed(place: &PlaceCommand) -> u32 {
        place.seed ^ STONE_SALT
    }
}

impl Pattern for StonePattern {
    fn name(&self) -> &str {
        &self.name
    }

    fn family_name(&self) -> &'static str {
        "stone"
    }

    fn material_slots(&self) -> usize {
        if self.mortar > 0 { 2 } else { 1 }
    }

    fn slot_names(&self) -> &[&'static str] {
        if self.mortar > 0 {
            &["stone", "mortar"]
        } else {
            &["stone"]
        }
    }

    fn default_materials(&self) -> [u8; MAX_PATTERN_MATERIALS] {
        self.materials
    }

    fn check(&self, place: &PlaceCommand) -> Result<(), &'static str> {
        if !(2..=64).contains(&self.cell) {
            return Err("stone: cell edge out of range");
        }
        if !place.extent.iter().all(|&e| size_ok(e as i64)) {
            return Err("stone: extent out of range");
        }
        Ok(())
    }

    fn bounds(&self, place: &PlaceCommand) -> LocalBox {
        LocalBox::new(IVec2::ZERO, IVec2::from_array(place.extent))
    }

    fn classify(&self, place: &PlaceCommand, p: IVec2) -> Cell {
        let q = IVec2::new(floor_div(p.x, FX), floor_div(p.y, FX));
        let hit = cell_at_2d(Self::seed(place), self.cell as u16, q);
        if self.mortar > 0 && hit.gap <= (self.mortar * self.cell) as i64 {
            return Cell::Joint { slot: 1 };
        }
        let g = self.grid(place);
        let c = hit.cell + 1;
        let piece = (c.x.max(0) + g.x * c.y.max(0)) as u32;
        Cell::Piece { piece, slot: 0 }
    }

    fn piece_box(&self, place: &PlaceCommand, piece: u32) -> Option<LocalBox> {
        let g = self.grid(place);
        let i = piece as i32;
        if i >= g.x * g.y {
            return None;
        }
        let cell = IVec2::new(i % g.x, i / g.x) - 1;
        let b = LocalBox::new((cell - 1) * self.cell, (cell + 2) * self.cell)
            .intersect(&self.bounds(place));
        (!b.is_empty()).then_some(b)
    }

    fn drag_extent(&self, size: IVec2) -> [i32; MAX_EXTENT] {
        size.max(IVec2::splat(self.cell)).to_array()
    }

    fn next_slots(&self, place: &PlaceCommand, out: &mut Vec<Slot>) {
        let [x, y] = place.extent;
        out.push(Slot {
            kind: SlotKind::Next,
            offset: IVec2::new(x * FX, 0),
        });
        out.push(Slot {
            kind: SlotKind::Previous,
            offset: IVec2::new(-x * FX, 0),
        });
        out.push(Slot {
            kind: SlotKind::Above,
            offset: IVec2::new(0, y * FX),
        });
        out.push(Slot {
            kind: SlotKind::Below,
            offset: IVec2::new(0, -y * FX),
        });
    }
}

// ============================================================================
// Family 3: Plank (Floor & Wall boards)
// Ported from `crates/lithium-core/src/place/families/plank.rs`
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PlankLayout {
    /// Horizontal boards running along local X, stacked across local Y.
    Floor,
    /// Vertical boards running along local Y, laid side-by-side across local X.
    Wall,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlankPattern {
    pub name: String,
    pub width: i32,
    pub gap: i32,
    pub layout: PlankLayout,
    pub materials: [u8; MAX_PATTERN_MATERIALS],
}

impl PlankPattern {
    pub fn new(
        name: impl Into<String>,
        width: i32,
        gap: i32,
        layout: PlankLayout,
        plank_mat: u8,
    ) -> Self {
        Self {
            name: name.into(),
            width,
            gap,
            layout,
            materials: [plank_mat, 0, 0, 0],
        }
    }

    fn pitch(&self) -> i32 {
        self.width + self.gap
    }

    fn across(&self, boards: i32) -> i64 {
        boards as i64 * self.pitch() as i64 - self.gap as i64
    }

    fn across_of(&self, v: IVec2) -> i32 {
        match self.layout {
            PlankLayout::Floor => v.y,
            PlankLayout::Wall => v.x,
        }
    }

    fn along_of(&self, v: IVec2) -> i32 {
        match self.layout {
            PlankLayout::Floor => v.x,
            PlankLayout::Wall => v.y,
        }
    }

    fn local(&self, along: i32, across: i32) -> IVec2 {
        match self.layout {
            PlankLayout::Floor => IVec2::new(along, across),
            PlankLayout::Wall => IVec2::new(across, along),
        }
    }
}

impl Pattern for PlankPattern {
    fn name(&self) -> &str {
        &self.name
    }

    fn family_name(&self) -> &'static str {
        "plank"
    }

    fn material_slots(&self) -> usize {
        1
    }

    fn slot_names(&self) -> &[&'static str] {
        &["plank"]
    }

    fn default_materials(&self) -> [u8; MAX_PATTERN_MATERIALS] {
        self.materials
    }

    fn check(&self, place: &PlaceCommand) -> Result<(), &'static str> {
        let [len, boards] = place.extent;
        if self.width < 1 || self.gap < 0 {
            return Err("plank: width at least 1, gap at least 0");
        }
        if !size_ok(len as i64) || boards < 1 || !size_ok(self.across(boards)) {
            return Err("plank: extent out of range");
        }
        Ok(())
    }

    fn bounds(&self, place: &PlaceCommand) -> LocalBox {
        let [len, boards] = place.extent;
        LocalBox::new(IVec2::ZERO, self.local(len, self.across(boards) as i32))
    }

    fn classify(&self, _place: &PlaceCommand, p: IVec2) -> Cell {
        let a = self.across_of(p);
        let k = floor_div(a, self.pitch() * FX);
        if a - k * self.pitch() * FX < self.width * FX {
            Cell::Piece {
                piece: k as u32,
                slot: 0,
            }
        } else {
            Cell::Empty
        }
    }

    fn piece_box(&self, place: &PlaceCommand, piece: u32) -> Option<LocalBox> {
        let [len, boards] = place.extent;
        if piece as i32 >= boards {
            return None;
        }
        let a = piece as i32 * self.pitch();
        Some(LocalBox::new(
            self.local(0, a),
            self.local(len, a + self.width),
        ))
    }

    fn drag_extent(&self, size: IVec2) -> [i32; MAX_EXTENT] {
        let along_size = self.along_of(size).max(1);
        let across_size = self.across_of(size).max(1);
        let len = (ceil_div(along_size, 4) * 4).max(4);
        let boards = ceil_div(across_size + self.gap, self.pitch()).max(1);
        [len, boards]
    }

    fn next_slots(&self, place: &PlaceCommand, out: &mut Vec<Slot>) {
        let [len, boards] = place.extent;
        let across_step = (boards * self.pitch()) * FX;
        let along_step = len * FX;
        out.push(Slot {
            kind: SlotKind::Next,
            offset: self.local(along_step, 0),
        });
        out.push(Slot {
            kind: SlotKind::Previous,
            offset: self.local(-along_step, 0),
        });
        out.push(Slot {
            kind: SlotKind::Above,
            offset: self.local(0, across_step),
        });
        out.push(Slot {
            kind: SlotKind::Below,
            offset: self.local(0, -across_step),
        });
    }
}

// ============================================================================
// Family 4: Pane (Framed or frameless tiles)
// Ported from `crates/lithium-core/src/place/families/pane.rs`
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanePattern {
    pub name: String,
    pub tile: IVec2,
    pub joint: i32,
    pub materials: [u8; MAX_PATTERN_MATERIALS],
}

impl PanePattern {
    pub fn new(
        name: impl Into<String>,
        tile: IVec2,
        joint: i32,
        pane_mat: u8,
        joint_mat: u8,
    ) -> Self {
        Self {
            name: name.into(),
            tile,
            joint,
            materials: [pane_mat, joint_mat, 0, 0],
        }
    }

    fn pitch(&self) -> IVec2 {
        self.tile + self.joint
    }

    fn columns(&self, place: &PlaceCommand) -> i32 {
        ceil_div(place.extent[0], self.pitch().x) + 1
    }

    fn tile_of(&self, v: i32, tile: i32, pitch: i32) -> Option<i32> {
        let t = v - self.joint * FX;
        if t < 0 {
            return None;
        }
        let k = floor_div(t, pitch * FX);
        (t - k * pitch * FX < tile * FX).then_some(k)
    }
}

impl Pattern for PanePattern {
    fn name(&self) -> &str {
        &self.name
    }

    fn family_name(&self) -> &'static str {
        "pane"
    }

    fn material_slots(&self) -> usize {
        if self.joint > 0 { 2 } else { 1 }
    }

    fn slot_names(&self) -> &[&'static str] {
        if self.joint > 0 {
            &["pane", "frame"]
        } else {
            &["pane"]
        }
    }

    fn default_materials(&self) -> [u8; MAX_PATTERN_MATERIALS] {
        self.materials
    }

    fn check(&self, place: &PlaceCommand) -> Result<(), &'static str> {
        let [w, h] = place.extent;
        if self.tile.min_element() < 1 || self.joint < 0 {
            return Err("pane: tile at least 1, joint at least 0");
        }
        if !size_ok(w as i64) || !size_ok(h as i64) {
            return Err("pane: extent out of range");
        }
        Ok(())
    }

    fn bounds(&self, place: &PlaceCommand) -> LocalBox {
        let [w, h] = place.extent;
        LocalBox::new(IVec2::ZERO, IVec2::new(w, h))
    }

    fn classify(&self, place: &PlaceCommand, p: IVec2) -> Cell {
        let pitch = self.pitch();
        match (
            self.tile_of(p.x, self.tile.x, pitch.x),
            self.tile_of(p.y, self.tile.y, pitch.y),
        ) {
            (Some(tx), Some(ty)) => Cell::Piece {
                piece: (tx + ty * self.columns(place)) as u32,
                slot: 0,
            },
            _ => Cell::Joint { slot: 1 },
        }
    }

    fn piece_box(&self, place: &PlaceCommand, piece: u32) -> Option<LocalBox> {
        let cols = self.columns(place);
        if cols <= 0 {
            return None;
        }
        let (tx, ty) = (piece as i32 % cols, piece as i32 / cols);
        let lo = IVec2::splat(self.joint) + IVec2::new(tx, ty) * self.pitch();
        let hi = lo + self.tile;
        let b = LocalBox::new(lo, hi).intersect(&self.bounds(place));
        (!b.is_empty()).then_some(b)
    }

    fn drag_extent(&self, size: IVec2) -> [i32; MAX_EXTENT] {
        let p = self.pitch();
        let k = |s: i32, pitch: i32| ceil_div(s - self.joint, pitch).max(1) * pitch + self.joint;
        [k(size.x, p.x), k(size.y, p.y)]
    }

    fn next_slots(&self, place: &PlaceCommand, out: &mut Vec<Slot>) {
        let [w, h] = place.extent;
        let step_x = (w - self.joint).max(1) * FX;
        let step_y = (h - self.joint).max(1) * FX;
        out.push(Slot {
            kind: SlotKind::Next,
            offset: IVec2::new(step_x, 0),
        });
        out.push(Slot {
            kind: SlotKind::Previous,
            offset: IVec2::new(-step_x, 0),
        });
        out.push(Slot {
            kind: SlotKind::Above,
            offset: IVec2::new(0, step_y),
        });
        out.push(Slot {
            kind: SlotKind::Below,
            offset: IVec2::new(0, -step_y),
        });
    }
}

// ============================================================================
// PatternRegistry
// ============================================================================

#[derive(Clone, Default)]
pub struct PatternRegistry {
    patterns: Vec<SharedPattern>,
}

impl std::fmt::Debug for PatternRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PatternRegistry")
            .field("count", &self.patterns.len())
            .finish()
    }
}

impl PatternRegistry {
    pub fn new() -> Self {
        Self {
            patterns: Vec::new(),
        }
    }

    /// Creates the default pattern registry matching LithiumEngine's `patterns.toml`.
    pub fn with_defaults() -> Self {
        let mut reg = Self::new();
        // Masonry patterns: 8x4 bricks + 1-tile mortar
        reg.register(Masonry::new(
            "brick_running",
            Bond::Running,
            IVec2::new(8, 4),
            1,
            BRICK,
            MORTAR,
        ));
        reg.register(Masonry::new(
            "brick_stack",
            Bond::Stack,
            IVec2::new(8, 4),
            1,
            BRICK,
            MORTAR,
        ));
        reg.register(Masonry::new(
            "brick_flemish",
            Bond::Flemish,
            IVec2::new(8, 4),
            1,
            BRICK,
            MORTAR,
        ));

        // Stone Voronoi patterns: cell=5, mortared & dry
        reg.register(StonePattern::new("stone_mortared", 5, 1, STONE, MORTAR));
        reg.register(StonePattern::new("stone_dry", 5, 0, STONE, MORTAR));

        // Plank patterns: floor (horizontal) & wall (vertical)
        reg.register(PlankPattern::new(
            "plank_floor",
            2,
            0,
            PlankLayout::Floor,
            PLANK,
        ));
        reg.register(PlankPattern::new(
            "plank_wall",
            2,
            0,
            PlankLayout::Wall,
            PLANK,
        ));

        // Pane pattern: 4x4 glass pane with 1-tile plank frame
        reg.register(PanePattern::new(
            "glass_pane",
            IVec2::new(4, 4),
            1,
            GLASS,
            PLANK,
        ));
        reg
    }

    pub fn register<P: Pattern + 'static>(&mut self, pattern: P) -> u16 {
        let id = self.patterns.len() as u16;
        self.patterns.push(Arc::new(pattern));
        id
    }

    pub fn len(&self) -> usize {
        self.patterns.len()
    }

    pub fn is_empty(&self) -> bool {
        self.patterns.is_empty()
    }

    pub fn get(&self, id: u16) -> Option<&SharedPattern> {
        self.patterns.get(id as usize)
    }

    pub fn id_of(&self, name: &str) -> Option<u16> {
        self.patterns
            .iter()
            .position(|p| p.name() == name)
            .map(|i| i as u16)
    }

    pub fn iter(&self) -> impl Iterator<Item = (u16, &SharedPattern)> {
        self.patterns
            .iter()
            .enumerate()
            .map(|(i, p)| (i as u16, p))
    }

    pub fn command(
        &self,
        name: &str,
        pose: PlacePose,
        extent: [i32; MAX_EXTENT],
    ) -> Option<PlaceCommand> {
        let id = self.id_of(name)?;
        let p = self.get(id)?;
        Some(PlaceCommand {
            pattern: id,
            anchor: pose.anchor,
            yaw: pose.yaw,
            extent,
            materials: p.default_materials(),
            seed: 1,
            overlap: Overlap::Refuse,
            serial: PREVIEW_SERIAL,
        })
    }
}

// ============================================================================
// Placement Records, Material Use & Refusals
// Ported from `crates/lithium-core/src/place/records.rs` & `apply.rs`
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlaceRefusal {
    Invalid(&'static str),
    Unloaded,
    Occupied,
    Nothing,
    PlayerOverlap,
    NotAPiece,
}

impl PlaceRefusal {
    pub fn message(&self) -> &'static str {
        match self {
            PlaceRefusal::Invalid(msg) => msg,
            PlaceRefusal::Unloaded => "chunk not loaded",
            PlaceRefusal::Occupied => "blocked by solid terrain",
            PlaceRefusal::Nothing => "nothing to write",
            PlaceRefusal::PlayerOverlap => "overlaps player",
            PlaceRefusal::NotAPiece => "not a placed piece",
        }
    }
}

/// Counts of tiles written and replaced by a placement or piece removal.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MaterialUse {
    pub written: Vec<(u8, u32)>,
    pub replaced: Vec<(u8, u32)>,
}

impl MaterialUse {
    pub fn from_counts(written_counts: &[u32; 256], replaced_counts: &[u32; 256]) -> Self {
        let written = written_counts
            .iter()
            .enumerate()
            .filter(|(_, &c)| c > 0)
            .map(|(id, &c)| (id as u8, c))
            .collect();
        let replaced = replaced_counts
            .iter()
            .enumerate()
            .filter(|(_, &c)| c > 0)
            .map(|(id, &c)| (id as u8, c))
            .collect();
        Self { written, replaced }
    }

    pub fn total_written(&self) -> u32 {
        self.written.iter().map(|(_, c)| *c).sum()
    }
}

/// Dry-run preview of a placement or piece removal.
#[derive(Debug, Clone)]
pub struct PlacePreview {
    pub writes: Vec<WorldTileChange>,
    pub piece_tiles: Vec<(IVec2, u32)>,
    pub pieces: u32,
    pub report: MaterialUse,
}

/// Stored record of a completed placement (`PlacementRecord` in LithiumEngine).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlacementRecord {
    pub serial: u64,
    pub pattern: u16,
    pub anchor: I64Vec2,
    pub yaw: u16,
    pub extent: [i32; MAX_EXTENT],
    pub materials: [u8; MAX_PATTERN_MATERIALS],
    pub seed: u32,
    pub overlap: Overlap,
    pub pieces: u32,
}

impl PlacementRecord {
    pub fn from_command(place: &PlaceCommand, pieces: u32) -> Self {
        Self {
            serial: place.serial,
            pattern: place.pattern,
            anchor: place.anchor,
            yaw: place.yaw,
            extent: place.extent,
            materials: place.materials,
            seed: place.seed,
            overlap: place.overlap,
            pieces,
        }
    }

    pub fn command(&self) -> PlaceCommand {
        PlaceCommand {
            pattern: self.pattern,
            anchor: self.anchor,
            yaw: self.yaw,
            extent: self.extent,
            materials: self.materials,
            seed: self.seed,
            overlap: self.overlap,
            serial: self.serial,
        }
    }

    pub fn pose(&self) -> PlacePose {
        PlacePose {
            anchor: self.anchor,
            yaw: self.yaw,
        }
    }
}

/// Tracks active placement records and per-tile piece ownership for snapping and piece removal.
#[derive(Debug, Clone, Default)]
pub struct Placements {
    records: BTreeMap<u64, PlacementRecord>,
    /// Maps world tile position -> `(record_serial, piece_id)` for placed piece tiles.
    tile_pieces: HashMap<IVec2, (u64, u32)>,
    /// Maps world tile position -> `record_serial` for joint/mortar tiles as well as piece tiles.
    tile_records: HashMap<IVec2, u64>,
    next_serial: u64,
}

impl Placements {
    pub fn new() -> Self {
        Self {
            records: BTreeMap::new(),
            tile_pieces: HashMap::new(),
            tile_records: HashMap::new(),
            next_serial: 1,
        }
    }

    pub fn allocate_serial(&mut self) -> u64 {
        let s = self.next_serial.max(1);
        self.next_serial = s + 1;
        s
    }

    pub fn get(&self, serial: u64) -> Option<&PlacementRecord> {
        self.records.get(&serial)
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    pub fn record_placement(
        &mut self,
        record: PlacementRecord,
        writes: &[WorldTileChange],
        piece_tiles: &[(IVec2, u32)],
    ) {
        let serial = record.serial;
        self.next_serial = self.next_serial.max(serial.saturating_add(1));

        let mut affected_serials = HashSet::new();
        for w in writes {
            let pos = IVec2::new(w.pos.x.floor() as i32, w.pos.y.floor() as i32);
            if let Some((old_s, _)) = self.tile_pieces.remove(&pos) {
                affected_serials.insert(old_s);
            }
            if let Some(old_s) = self.tile_records.insert(pos, serial) {
                affected_serials.insert(old_s);
            }
        }

        for &(pos, piece_id) in piece_tiles {
            self.tile_pieces.insert(pos, (serial, piece_id));
        }

        self.records.insert(serial, record);
        self.prune_empty_records(affected_serials);
    }

    /// Updates piece/record tracking when terrain is modified by digging or brush edits.
    pub fn on_tiles_changed(&mut self, changes: &[WorldTileChange]) {
        let mut affected_serials = HashSet::new();
        for change in changes {
            let pos = IVec2::new(change.pos.x.floor() as i32, change.pos.y.floor() as i32);
            if let Some((s, _)) = self.tile_pieces.remove(&pos) {
                affected_serials.insert(s);
            }
            if let Some(s) = self.tile_records.remove(&pos) {
                affected_serials.insert(s);
            }
        }
        if !affected_serials.is_empty() {
            self.prune_empty_records(affected_serials);
        }
    }

    fn prune_empty_records(&mut self, candidates: HashSet<u64>) {
        for serial in candidates {
            let has_piece = self.tile_pieces.values().any(|&(s, _)| s == serial);
            if !has_piece {
                self.records.remove(&serial);
                self.tile_records.retain(|_, &mut s| s != serial);
            }
        }
    }

    /// Returns `(serial, piece_id)` if `tile` is part of a placed piece.
    pub fn piece_at(&self, tile: IVec2) -> Option<(u64, u32)> {
        self.tile_pieces.get(&tile).copied()
    }

    /// Returns the newest placement record covering `tile`.
    pub fn placement_at(&self, tile: IVec2) -> Option<u64> {
        self.tile_records
            .get(&tile)
            .copied()
            .filter(|s| self.records.contains_key(s))
    }

    /// Returns all placement serials (ascending) with tiles within `radius` of `tile`.
    pub fn placements_near(&self, tile: IVec2, radius: i32) -> Vec<u64> {
        let r = radius.max(0);
        let mut out = Vec::new();
        for (&pos, &serial) in &self.tile_records {
            if (pos.x - tile.x).abs() <= r
                && (pos.y - tile.y).abs() <= r
                && self.records.contains_key(&serial)
            {
                out.push(serial);
            }
        }
        out.sort_unstable();
        out.dedup();
        out
    }

    /// Computes the snap slots (`SlotKind`, `PlacePose`) offered next to placement `serial`.
    pub fn next_slots(&self, serial: u64, patterns: &PatternRegistry) -> Vec<(SlotKind, PlacePose)> {
        let Some(record) = self.records.get(&serial) else {
            return Vec::new();
        };
        let Some(pattern) = patterns.get(record.pattern) else {
            return Vec::new();
        };
        let cmd = record.command();
        let yaw = Yaw2D::new(record.yaw);
        let mut slots = Vec::new();
        pattern.next_slots(&cmd, &mut slots);
        slots
            .into_iter()
            .map(|s| {
                let offset_world = yaw.to_world(s.offset.as_i64vec2());
                (
                    s.kind,
                    PlacePose {
                        anchor: record.anchor + offset_world,
                        yaw: record.yaw,
                    },
                )
            })
            .collect()
    }
}

/// Checks whether a world tile `v` (`[v.x, v.x + 1] x [v.y, v.y + 1]`) overlaps an AABB
/// centered at `center` with `size`.
fn tile_overlaps_aabb(v: IVec2, center: Vec2, size: Vec2) -> bool {
    let half = size * 0.5;
    let aabb_min = center - half;
    let aabb_max = center + half;
    let tile_min = Vec2::new(v.x as f32, v.y as f32);
    let tile_max = tile_min + Vec2::ONE;

    tile_max.x > aabb_min.x
        && tile_min.x < aabb_max.x
        && tile_max.y > aabb_min.y
        && tile_min.y < aabb_max.y
}

/// Plans a placement against the current world and mover AABBs without modifying the world.
pub fn plan_placement(
    place: &PlaceCommand,
    patterns: &PatternRegistry,
    chunk_manager: &ChunkManager,
    tile_registry: &TileRegistry,
    movers: &[(Vec2, Vec2)],
) -> Result<PlacePreview, PlaceRefusal> {
    let pattern = patterns
        .get(place.pattern)
        .ok_or(PlaceRefusal::Invalid("unknown pattern"))?;
    pattern.check(place).map_err(PlaceRefusal::Invalid)?;

    for &m in &place.materials[..pattern.material_slots()] {
        if m == AIR || tile_registry.get_tile_def(m).is_none() {
            return Err(PlaceRefusal::Invalid("invalid placement material"));
        }
    }

    let bounds = pattern.bounds(place);
    if (bounds.max - bounds.min).max_element() > MAX_PLACE_TILES {
        return Err(PlaceRefusal::Invalid("placement too large"));
    }

    let material_for_slot = |slot: u8| place.materials[slot as usize % MAX_PATTERN_MATERIALS];

    struct Cand {
        v: IVec2,
        material: u8,
        piece: Option<u32>,
    }

    let mut cands = Vec::new();
    for_each_tile(place.pose(), bounds, |v, p| match pattern.classify(place, p) {
        Cell::Empty => {}
        Cell::Joint { slot } => cands.push(Cand {
            v,
            material: material_for_slot(slot),
            piece: None,
        }),
        Cell::Piece { piece, slot } => cands.push(Cand {
            v,
            material: material_for_slot(slot),
            piece: Some(piece),
        }),
    });

    if cands.is_empty() {
        return Err(PlaceRefusal::Nothing);
    }

    // Sort deterministically by (y, x)
    cands.sort_unstable_by_key(|c| (c.v.y, c.v.x));
    cands.dedup_by_key(|c| c.v);

    let mut writes = Vec::with_capacity(cands.len());
    let mut piece_tiles = Vec::new();
    let mut distinct_pieces = HashSet::new();
    let mut written_counts = [0u32; 256];
    let mut replaced_counts = [0u32; 256];

    for c in cands {
        let world_pos = Vec2::new(c.v.x as f32, c.v.y as f32);
        let chunk_pos = ChunkManager::world_to_chunk_pos(world_pos);
        if chunk_manager.get_chunk_at(chunk_pos).is_none() {
            return Err(PlaceRefusal::Unloaded);
        }

        let [old_tile, _] = chunk_manager.get_tile_at_world_pos(world_pos);
        let is_open = old_tile == AIR || !tile_registry.is_solid(old_tile);

        let should_write = match place.overlap {
            Overlap::Refuse => {
                if !is_open {
                    return Err(PlaceRefusal::Occupied);
                }
                true
            }
            Overlap::FillAir => is_open,
            Overlap::Overwrite => true,
        };

        if !should_write {
            continue;
        }

        // Check player/entity mover AABBs
        for &(center, size) in movers {
            if tile_overlaps_aabb(c.v, center, size) {
                return Err(PlaceRefusal::PlayerOverlap);
            }
        }

        written_counts[c.material as usize] += 1;
        if old_tile != AIR {
            replaced_counts[old_tile as usize] += 1;
        }

        writes.push(WorldTileChange {
            pos: world_pos,
            tile_id: c.material,
            damage_stage: 0,
        });

        if let Some(p) = c.piece {
            piece_tiles.push((c.v, p));
            distinct_pieces.insert(p);
        }
    }

    if writes.is_empty() || distinct_pieces.is_empty() {
        return Err(PlaceRefusal::Nothing);
    }

    Ok(PlacePreview {
        writes,
        piece_tiles,
        pieces: distinct_pieces.len() as u32,
        report: MaterialUse::from_counts(&written_counts, &replaced_counts),
    })
}

/// Applies a placement command to `ChunkManager` and records it in `Placements`.
pub fn apply_placement(
    place: &PlaceCommand,
    patterns: &PatternRegistry,
    placements: &mut Placements,
    chunk_manager: &mut ChunkManager,
    tile_registry: &TileRegistry,
    movers: &[(Vec2, Vec2)],
    signal_bus: &mut SignalBus,
) -> Result<PlacePreview, PlaceRefusal> {
    let preview = plan_placement(place, patterns, chunk_manager, tile_registry, movers)?;
    chunk_manager.set_tiles_at_world_positions(&preview.writes, signal_bus);
    let record = PlacementRecord::from_command(place, preview.pieces);
    placements.record_placement(record, &preview.writes, &preview.piece_tiles);
    Ok(preview)
}

/// Removes the single placed piece at `tile_pos`, leaving mortar/joints and other pieces intact.
/// Ported from `crates/lithium-core/src/place/remove.rs`.
pub fn remove_piece_at(
    tile_pos: IVec2,
    placements: &mut Placements,
    chunk_manager: &mut ChunkManager,
    signal_bus: &mut SignalBus,
) -> Result<MaterialUse, PlaceRefusal> {
    let (serial, piece_id) = placements
        .piece_at(tile_pos)
        .ok_or(PlaceRefusal::NotAPiece)?;

    let mut tiles_to_remove: Vec<IVec2> = placements
        .tile_pieces
        .iter()
        .filter(|(_, &(s, p))| s == serial && p == piece_id)
        .map(|(&pos, _)| pos)
        .collect();

    if tiles_to_remove.is_empty() {
        return Err(PlaceRefusal::NotAPiece);
    }

    tiles_to_remove.sort_unstable_by_key(|v| (v.y, v.x));

    let mut replaced_counts = [0u32; 256];
    let mut changes = Vec::with_capacity(tiles_to_remove.len());

    for v in tiles_to_remove {
        let world_pos = Vec2::new(v.x as f32, v.y as f32);
        let [old_id, _] = chunk_manager.get_tile_at_world_pos(world_pos);
        if old_id != AIR {
            replaced_counts[old_id as usize] += 1;
            changes.push(WorldTileChange {
                pos: world_pos,
                tile_id: AIR,
                damage_stage: 0,
            });
        }
    }

    if changes.is_empty() {
        return Err(PlaceRefusal::NotAPiece);
    }

    chunk_manager.set_tiles_at_world_positions(&changes, signal_bus);
    placements.on_tiles_changed(&changes);

    Ok(MaterialUse::from_counts(&[0u32; 256], &replaced_counts))
}

// ============================================================================
// BuildTool (App-level interactive tool state, drag sizing & preview)
// Ported from `crates/lithium-app/src/building.rs`
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PoseSource {
    Free,
    NoSnap,
    Snapped(SlotKind),
}

#[derive(Debug, Clone, Copy)]
struct DragState {
    start_tile: IVec2,
    pose: PlacePose,
    source: PoseSource,
}

#[derive(Debug, Clone)]
pub struct PlannedPlacement {
    pub cmd: PlaceCommand,
    pub result: Result<PlacePreview, PlaceRefusal>,
    pub boxes: Vec<(u32, LocalBox)>,
    pub source: PoseSource,
    pub status_text: String,
}

/// Interactive building tool state (`BuildTool` in LithiumEngine).
pub struct BuildTool {
    pub active: bool,
    pub pattern: u16,
    /// Custom material per slot (`0` uses the pattern's default material for that slot).
    pub custom_materials: [u8; MAX_PATTERN_MATERIALS],
    /// Currently selected slot index (`0` = piece material, `1` = joint/mortar material) when assigning from hotbar.
    pub active_slot: usize,
    pub overlap: Overlap,
    pub snap: bool,
    pub yaw: u16,
    pub seed: u32,
    drag: Option<DragState>,
    pub plan: Option<PlannedPlacement>,
    pub last_refusal: Option<String>,
}

impl Default for BuildTool {
    fn default() -> Self {
        Self::new()
    }
}

impl BuildTool {
    pub fn new() -> Self {
        Self {
            active: false,
            pattern: 0,
            custom_materials: [0; MAX_PATTERN_MATERIALS],
            active_slot: 0,
            overlap: Overlap::Refuse,
            snap: true,
            yaw: 0,
            seed: 1,
            drag: None,
            plan: None,
            last_refusal: None,
        }
    }

    pub fn is_dragging(&self) -> bool {
        self.drag.is_some()
    }

    pub fn cycle_pattern(&mut self, delta: i32, patterns: &PatternRegistry) {
        if patterns.is_empty() {
            return;
        }
        let len = patterns.len() as i32;
        let next = (self.pattern as i32 + delta).rem_euclid(len) as u16;
        self.select_pattern(next, patterns);
    }

    pub fn select_pattern(&mut self, id: u16, patterns: &PatternRegistry) {
        if let Some(p) = patterns.get(id) {
            self.pattern = id;
            if self.active_slot >= p.material_slots() {
                self.active_slot = 0;
            }
            self.drag = None;
        }
    }

    /// Assigns `tile_id` to the currently active material slot (`0` = piece, `1` = joint/mortar).
    pub fn set_slot_material(&mut self, tile_id: u8) {
        if self.active_slot < MAX_PATTERN_MATERIALS {
            self.custom_materials[self.active_slot] = tile_id;
        }
    }

    /// Resets material slots to the current pattern's defaults.
    pub fn reset_materials(&mut self) {
        self.custom_materials = [0; MAX_PATTERN_MATERIALS];
    }

    /// Returns the effective material IDs `[slot0, slot1, ...]` for the current pattern.
    pub fn effective_materials(&self, patterns: &PatternRegistry) -> [u8; MAX_PATTERN_MATERIALS] {
        let Some(p) = patterns.get(self.pattern) else {
            return self.custom_materials;
        };
        let mut mats = p.default_materials();
        for (i, &custom) in self.custom_materials.iter().enumerate() {
            if custom != AIR {
                mats[i] = custom;
            }
        }
        mats
    }

    pub fn turn(&mut self, delta: i16) {
        self.yaw = self.yaw.wrapping_add(delta as u16);
    }

    pub fn yaw_degrees(&self) -> f32 {
        (self.yaw as f32 / 65536.0) * 360.0
    }

    /// Computes the placement pose at `cursor_tile` (either snapped to a nearby placement's `next_slots` or free).
    pub fn pose_at(
        &self,
        cursor_tile: IVec2,
        mouse_world: Vec2,
        patterns: &PatternRegistry,
        placements: &Placements,
    ) -> (PlacePose, PoseSource) {
        if self.snap {
            let serial = placements
                .placement_at(cursor_tile)
                .or_else(|| placements.placements_near(cursor_tile, SNAP_REACH).last().copied());
            let best = serial.and_then(|s| {
                placements
                    .next_slots(s, patterns)
                    .into_iter()
                    .min_by(|a, b| {
                        let da = fixed_to_world(a.1.anchor).distance_squared(mouse_world);
                        let db = fixed_to_world(b.1.anchor).distance_squared(mouse_world);
                        da.total_cmp(&db)
                    })
            });
            if let Some((kind, pose)) = best {
                return (pose, PoseSource::Snapped(kind));
            }
        }

        let pose = PlacePose {
            anchor: free_anchor_for_tile(cursor_tile, self.yaw),
            yaw: self.yaw,
        };
        let source = if self.snap {
            PoseSource::NoSnap
        } else {
            PoseSource::Free
        };
        (pose, source)
    }

    /// Builds this frame's [`PlaceCommand`] from either the active drag or a single-unit preview.
    pub fn build_command(
        &self,
        cursor_tile: IVec2,
        pose: PlacePose,
        patterns: &PatternRegistry,
    ) -> Option<PlaceCommand> {
        let pattern = patterns.get(self.pattern)?.clone();
        let (mut pose, mut extent) = (pose, pattern.drag_extent(IVec2::ONE));

        if let Some(d) = self.drag {
            let yaw = Yaw2D::new(pose.yaw);
            let local = yaw.to_local((cursor_tile - d.start_tile).as_i64vec2() * (FX as i64));
            let delta = IVec2::new(
                (local.x as f64 / FX as f64).round() as i32,
                (local.y as f64 / FX as f64).round() as i32,
            );
            let size = delta.abs() + 1;
            extent = pattern.drag_extent(size);

            let mut cmd = patterns.command(pattern.name(), pose, extent)?;
            let len = pattern.bounds(&cmd).max;
            let mut shift = IVec2::ZERO;
            for i in 0..MAX_EXTENT {
                let mut flat = size;
                flat[i] = 1;
                if delta[i] < 0 && pattern.drag_extent(flat) != extent {
                    shift[i] = 1 - len[i];
                }
            }
            pose.anchor += yaw.to_world(shift.as_i64vec2() * (FX as i64));
            cmd.anchor = pose.anchor;
            return Some(self.finish_command(cmd, patterns));
        }

        let cmd = patterns.command(pattern.name(), pose, extent)?;
        Some(self.finish_command(cmd, patterns))
    }

    fn finish_command(&self, mut cmd: PlaceCommand, patterns: &PatternRegistry) -> PlaceCommand {
        cmd.materials = self.effective_materials(patterns);
        cmd.overlap = self.overlap;
        cmd.seed = self.seed;
        cmd.serial = PREVIEW_SERIAL;
        cmd
    }

    pub fn begin_drag(
        &mut self,
        cursor_tile: IVec2,
        mouse_world: Vec2,
        patterns: &PatternRegistry,
        placements: &Placements,
    ) {
        let (pose, source) = self.pose_at(cursor_tile, mouse_world, patterns, placements);
        self.drag = Some(DragState {
            start_tile: cursor_tile,
            pose,
            source,
        });
        self.last_refusal = None;
    }

    pub fn cancel_drag(&mut self) {
        self.drag = None;
    }

    pub fn finish_drag(
        &mut self,
        cursor_tile: IVec2,
        patterns: &PatternRegistry,
        placements: &mut Placements,
        chunk_manager: &mut ChunkManager,
        tile_registry: &TileRegistry,
        movers: &[(Vec2, Vec2)],
        signal_bus: &mut SignalBus,
    ) -> Option<Result<PlacePreview, PlaceRefusal>> {
        let drag = self.drag.take()?;
        let mut cmd = self.build_command_with_drag(cursor_tile, drag, patterns)?;
        cmd.serial = placements.allocate_serial();
        let res = apply_placement(
            &cmd,
            patterns,
            placements,
            chunk_manager,
            tile_registry,
            movers,
            signal_bus,
        );
        if let Err(ref e) = res {
            self.last_refusal = Some(e.message().to_string());
        } else {
            self.last_refusal = None;
            self.seed = self.seed.wrapping_add(1);
        }
        Some(res)
    }

    fn build_command_with_drag(
        &self,
        cursor_tile: IVec2,
        d: DragState,
        patterns: &PatternRegistry,
    ) -> Option<PlaceCommand> {
        let prev = self.drag;
        let mut temp = Self {
            active: self.active,
            pattern: self.pattern,
            custom_materials: self.custom_materials,
            active_slot: self.active_slot,
            overlap: self.overlap,
            snap: self.snap,
            yaw: self.yaw,
            seed: self.seed,
            drag: Some(d),
            plan: None,
            last_refusal: None,
        };
        let cmd = temp.build_command(cursor_tile, d.pose, patterns);
        temp.drag = prev;
        cmd
    }

    /// Updates this frame's planned placement preview and piece outlines.
    pub fn update_preview(
        &mut self,
        cursor_tile: IVec2,
        mouse_world: Vec2,
        patterns: &PatternRegistry,
        placements: &Placements,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
        movers: &[(Vec2, Vec2)],
    ) {
        if !self.active {
            self.plan = None;
            return;
        }

        let (pose, source) = match self.drag {
            Some(d) => (d.pose, d.source),
            None => self.pose_at(cursor_tile, mouse_world, patterns, placements),
        };

        let Some(cmd) = self.build_command(cursor_tile, pose, patterns) else {
            self.plan = None;
            return;
        };

        let mut boxes = Vec::new();
        if let Some(pattern) = patterns.get(cmd.pattern) {
            piece_boxes(pattern.as_ref(), &cmd, MAX_OUTLINE_PIECES, &mut boxes);
        }

        let result = plan_placement(&cmd, patterns, chunk_manager, tile_registry, movers);
        let pattern_name = patterns
            .get(cmd.pattern)
            .map(|p| p.name())
            .unwrap_or("?");
        let source_str = match source {
            PoseSource::Free => "free".to_string(),
            PoseSource::NoSnap => "snap (free)".to_string(),
            PoseSource::Snapped(k) => format!("snap:{}", k.name()),
        };

        let status_text = match &result {
            Ok(preview) => {
                let mut mat_summary = String::new();
                for (i, &(mat_id, count)) in preview.report.written.iter().enumerate() {
                    if i > 0 {
                        mat_summary.push_str(", ");
                    }
                    mat_summary.push_str(&format!(
                        "{}:{}",
                        tile_registry.get_tile_name(mat_id),
                        count
                    ));
                }
                format!(
                    "{} [{}x{}] ({})\n{} pcs | {}",
                    pattern_name,
                    cmd.extent[0],
                    cmd.extent[1],
                    source_str,
                    preview.pieces,
                    mat_summary
                )
            }
            Err(err) => {
                format!(
                    "{} [{}x{}] ({})\nRefused: {}",
                    pattern_name,
                    cmd.extent[0],
                    cmd.extent[1],
                    source_str,
                    err.message()
                )
            }
        };

        self.plan = Some(PlannedPlacement {
            cmd,
            result,
            boxes,
            source,
            status_text,
        });
    }
}
