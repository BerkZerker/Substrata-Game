use std::collections::BTreeMap;
use std::path::Path;
use glam::Vec2;

/// Built-in tile IDs matching `TileIndex` (`src/globals/tile_index.gd`) plus building materials.
pub const AIR: u8 = 0;
pub const DIRT: u8 = 1;
pub const GRASS: u8 = 2;
pub const STONE: u8 = 3;
pub const BRICK: u8 = 4;
pub const MORTAR: u8 = 5;
pub const PLANK: u8 = 6;
pub const GLASS: u8 = 7;

#[derive(Clone, Copy, Debug)]
pub struct EdgeHardness {
    pub n: f32,
    pub s: f32,
    pub e: f32,
    pub w: f32,
}

impl Default for EdgeHardness {
    fn default() -> Self {
        Self {
            n: 0.0,
            s: 0.0,
            e: 0.0,
            w: 0.0,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct TileProperties {
    pub friction: f32,
    pub damage: f32,
    pub transparency: f32,
    pub hardness: i32,
    pub damage_stages: i32,
    pub break_noise: f32,
}

impl Default for TileProperties {
    fn default() -> Self {
        Self {
            friction: 1.0,
            damage: 0.0,
            transparency: 1.0,
            hardness: 1,
            damage_stages: 2,
            break_noise: 0.0,
        }
    }
}

#[derive(Clone, Debug)]
pub struct TileDef {
    pub id: u8,
    pub name: String,
    pub solid: bool,
    pub texture_path: String,
    pub color: [f32; 4],
    pub properties: TileProperties,
    pub edge_hardness: EdgeHardness,
}

/// Data-driven tile registry ported from `src/globals/tile_index.gd`.
pub struct TileRegistry {
    tiles: BTreeMap<u8, TileDef>,
    texture_size: u32,
    texture_layers_rgba: Vec<Vec<u8>>,
}

impl TileRegistry {
    pub fn new_default() -> Self {
        let mut registry = Self {
            tiles: BTreeMap::new(),
            texture_size: 32,
            texture_layers_rgba: Vec::new(),
        };

        registry.register_tile(
            AIR,
            "Air",
            false,
            "",
            [0.7, 0.8, 0.9, 0.5],
            TileProperties {
                transparency: 0.0,
                hardness: 0,
                damage_stages: 0,
                ..TileProperties::default()
            },
        );
        registry.register_tile(
            DIRT,
            "Dirt",
            true,
            "assets/textures/dirt.png",
            [0.55, 0.35, 0.2, 1.0],
            TileProperties {
                hardness: 3,
                ..TileProperties::default()
            },
        );
        registry.register_tile(
            GRASS,
            "Grass",
            true,
            "assets/textures/grass.png",
            [0.3, 0.7, 0.2, 1.0],
            TileProperties {
                hardness: 2,
                ..TileProperties::default()
            },
        );
        registry.register_tile(
            STONE,
            "Stone",
            true,
            "assets/textures/stone.png",
            [0.5, 0.5, 0.5, 1.0],
            TileProperties {
                hardness: 8,
                damage_stages: 2,
                break_noise: 0.5,
                ..TileProperties::default()
            },
        );
        registry.register_tile(
            BRICK,
            "Brick",
            true,
            "assets/textures/brick.png",
            [0.65, 0.28, 0.20, 1.0],
            TileProperties {
                hardness: 6,
                damage_stages: 2,
                break_noise: 0.25,
                ..TileProperties::default()
            },
        );
        registry.register_tile(
            MORTAR,
            "Mortar",
            true,
            "assets/textures/mortar.png",
            [0.76, 0.74, 0.68, 1.0],
            TileProperties {
                hardness: 3,
                damage_stages: 2,
                break_noise: 0.1,
                ..TileProperties::default()
            },
        );
        registry.register_tile(
            PLANK,
            "Plank",
            true,
            "assets/textures/plank.png",
            [0.58, 0.40, 0.22, 1.0],
            TileProperties {
                hardness: 4,
                damage_stages: 2,
                break_noise: 0.2,
                ..TileProperties::default()
            },
        );
        registry.register_tile(
            GLASS,
            "Glass",
            true,
            "assets/textures/glass.png",
            [0.65, 0.88, 0.95, 0.85],
            TileProperties {
                hardness: 1,
                damage_stages: 1,
                transparency: 0.8,
                break_noise: 0.0,
                ..TileProperties::default()
            },
        );

        registry.rebuild_texture_array();
        registry
    }

    pub fn register_tile(
        &mut self,
        id: u8,
        name: &str,
        solid: bool,
        texture_path: &str,
        color: [f32; 4],
        properties: TileProperties,
    ) {
        self.tiles.insert(
            id,
            TileDef {
                id,
                name: name.to_string(),
                solid,
                texture_path: texture_path.to_string(),
                color,
                properties,
                edge_hardness: EdgeHardness::default(),
            },
        );
    }

    /// Loads all registered tile textures into RGBA8 layers and computes
    /// directional edge hardness from texture edge luminance (`TileIndex.rebuild_texture_array()`).
    pub fn rebuild_texture_array(&mut self) {
        if self.tiles.is_empty() {
            return;
        }

        let max_id = *self.tiles.keys().max().unwrap_or(&0);
        self.texture_size = 0;

        for tile in self.tiles.values() {
            if !tile.texture_path.is_empty() {
                if let Ok(img) = image::open(Path::new(&tile.texture_path)) {
                    self.texture_size = img.width();
                    break;
                }
            }
        }
        if self.texture_size == 0 {
            self.texture_size = 32;
        }

        let tex_size = self.texture_size;
        self.texture_layers_rgba.clear();

        for id in 0..=max_id {
            if let Some(tile) = self.tiles.get(&id) {
                if !tile.texture_path.is_empty() {
                    if let Ok(img) = image::open(Path::new(&tile.texture_path)) {
                        let rgba = img.to_rgba8();
                        let resized = if rgba.width() != tex_size || rgba.height() != tex_size {
                            image::imageops::resize(
                                &rgba,
                                tex_size,
                                tex_size,
                                image::imageops::FilterType::Nearest,
                            )
                        } else {
                            rgba
                        };
                        self.texture_layers_rgba.push(resized.into_raw());
                        continue;
                    }
                    // Fallback procedural pixel-art texture for solid tiles if texture file is absent
                    self.texture_layers_rgba
                        .push(Self::generate_procedural_texture(id, tile.color, tex_size));
                    continue;
                }
            }
            // Transparent placeholder for tiles without textures (e.g. Air)
            self.texture_layers_rgba
                .push(vec![0u8; (tex_size * tex_size * 4) as usize]);
        }

        self.generate_edge_hardness();
    }

    pub fn generate_procedural_texture(id: u8, base_color: [f32; 4], tex_size: u32) -> Vec<u8> {
        let mut bytes = Vec::with_capacity((tex_size * tex_size * 4) as usize);
        let hash = |x: u32, y: u32, salt: u32| -> f32 {
            let mut n = x
                .wrapping_mul(374_761_393)
                .wrapping_add(y.wrapping_mul(668_265_263))
                .wrapping_add(salt.wrapping_mul(1_442_695_041));
            n = (n ^ (n >> 13)).wrapping_mul(1_274_126_177);
            n ^= n >> 16;
            ((n & 0xFFFF) as f32) / 65535.0
        };

        for y in 0..tex_size {
            for x in 0..tex_size {
                let h = hash(x, y, id as u32);
                let mut r = base_color[0];
                let mut g = base_color[1];
                let mut b = base_color[2];
                let a = base_color[3];

                match id {
                    BRICK => {
                        // Terracotta clay variation with darker speckles and slight horizontal grain
                        let row_tint = (hash(0, y / 2, 41) - 0.5) * 0.08;
                        let speck = (h - 0.5) * 0.14;
                        let edge = if x == 0 || y == 0 || x == tex_size - 1 || y == tex_size - 1 {
                            -0.06
                        } else {
                            0.0
                        };
                        let delta = row_tint + speck + edge;
                        r = (r + delta * 1.1).clamp(0.0, 1.0);
                        g = (g + delta * 0.8).clamp(0.0, 1.0);
                        b = (b + delta * 0.7).clamp(0.0, 1.0);
                    }
                    MORTAR => {
                        // Fine sandy-grey aggregate
                        let grain = (h - 0.5) * 0.12;
                        r = (r + grain).clamp(0.0, 1.0);
                        g = (g + grain).clamp(0.0, 1.0);
                        b = (b + grain * 0.9).clamp(0.0, 1.0);
                    }
                    PLANK => {
                        // Wood grain bands + dark board seam lines
                        let band = ((y as f32 * 0.9 + hash(x / 4, y, 73) * 1.5).sin()) * 0.06;
                        let streak = (hash(x / 3, y, 19) - 0.5) * 0.08;
                        let seam = if y % 8 == 0 { -0.10 } else { 0.0 };
                        let delta = band + streak + seam;
                        r = (r + delta).clamp(0.0, 1.0);
                        g = (g + delta * 0.85).clamp(0.0, 1.0);
                        b = (b + delta * 0.65).clamp(0.0, 1.0);
                    }
                    GLASS => {
                        // Crisp glass with diagonal specular glints and subtle border
                        let diag = (x.wrapping_add(y)) % 16;
                        let glint = if diag == 3 || diag == 4 {
                            0.18
                        } else if diag == 9 {
                            0.10
                        } else {
                            (h - 0.5) * 0.03
                        };
                        let border = if x == 0 || y == 0 || x == tex_size - 1 || y == tex_size - 1 {
                            -0.12
                        } else {
                            0.0
                        };
                        let delta = glint + border;
                        r = (r + delta).clamp(0.0, 1.0);
                        g = (g + delta).clamp(0.0, 1.0);
                        b = (b + delta).clamp(0.0, 1.0);
                    }
                    _ => {
                        let grain = (h - 0.5) * 0.12;
                        r = (r + grain).clamp(0.0, 1.0);
                        g = (g + grain).clamp(0.0, 1.0);
                        b = (b + grain).clamp(0.0, 1.0);
                    }
                }

                bytes.push((r * 255.0).round() as u8);
                bytes.push((g * 255.0).round() as u8);
                bytes.push((b * 255.0).round() as u8);
                bytes.push((a * 255.0).round() as u8);
            }
        }
        bytes
    }

    fn generate_edge_hardness(&mut self) {
        let size = self.texture_size as usize;
        for (&id, tile) in self.tiles.iter_mut() {
            let base_hardness = tile.properties.hardness as f32;
            if tile.texture_path.is_empty() || base_hardness <= 0.0 || size == 0 {
                tile.edge_hardness = EdgeHardness::default();
                continue;
            }

            let Some(layer_bytes) = self.texture_layers_rgba.get(id as usize) else {
                tile.edge_hardness = EdgeHardness {
                    n: base_hardness,
                    s: base_hardness,
                    e: base_hardness,
                    w: base_hardness,
                };
                continue;
            };

            let pixel_lum = |x: usize, y: usize| -> f32 {
                let idx = (y * size + x) * 4;
                let r = layer_bytes[idx] as f32 / 255.0;
                let g = layer_bytes[idx + 1] as f32 / 255.0;
                let b = layer_bytes[idx + 2] as f32 / 255.0;
                0.299 * r + 0.587 * g + 0.114 * b
            };

            let mut total_lum = 0.0f32;
            for y in 0..size {
                for x in 0..size {
                    total_lum += pixel_lum(x, y);
                }
            }
            let avg_lum = total_lum / ((size * size) as f32);
            if avg_lum < 0.001 {
                tile.edge_hardness = EdgeHardness {
                    n: base_hardness,
                    s: base_hardness,
                    e: base_hardness,
                    w: base_hardness,
                };
                continue;
            }

            let mut north_lum = 0.0f32;
            let mut south_lum = 0.0f32;
            let mut west_lum = 0.0f32;
            let mut east_lum = 0.0f32;
            for i in 0..size {
                north_lum += pixel_lum(i, 0);
                south_lum += pixel_lum(i, size - 1);
                west_lum += pixel_lum(0, i);
                east_lum += pixel_lum(size - 1, i);
            }
            north_lum /= size as f32;
            south_lum /= size as f32;
            west_lum /= size as f32;
            east_lum /= size as f32;

            tile.edge_hardness = EdgeHardness {
                n: base_hardness * (avg_lum / north_lum.max(0.001)),
                s: base_hardness * (avg_lum / south_lum.max(0.001)),
                e: base_hardness * (avg_lum / east_lum.max(0.001)),
                w: base_hardness * (avg_lum / west_lum.max(0.001)),
            };

            println!(
                "TileIndex: {} edge hardness N={:.2} S={:.2} E={:.2} W={:.2} (base={})",
                tile.name,
                tile.edge_hardness.n,
                tile.edge_hardness.s,
                tile.edge_hardness.e,
                tile.edge_hardness.w,
                tile.properties.hardness
            );
        }
    }

    pub fn texture_size(&self) -> u32 {
        self.texture_size
    }

    pub fn texture_layers_rgba(&self) -> &[Vec<u8>] {
        &self.texture_layers_rgba
    }

    pub fn is_solid(&self, tile_id: u8) -> bool {
        self.tiles.get(&tile_id).map(|t| t.solid).unwrap_or(false)
    }

    pub fn get_tile_name(&self, tile_id: u8) -> &str {
        self.tiles
            .get(&tile_id)
            .map(|t| t.name.as_str())
            .unwrap_or("Unknown")
    }

    pub fn get_tile_color(&self, tile_id: u8) -> [f32; 4] {
        self.tiles
            .get(&tile_id)
            .map(|t| t.color)
            .unwrap_or([1.0, 1.0, 1.0, 1.0])
    }

    pub fn get_tile_ids(&self) -> Vec<u8> {
        self.tiles.keys().copied().collect()
    }

    pub fn find_tile_by_name(&self, name: &str) -> Option<u8> {
        self.tiles
            .values()
            .find(|t| t.name.eq_ignore_ascii_case(name))
            .map(|t| t.id)
    }

    pub fn get_tile_def(&self, tile_id: u8) -> Option<&TileDef> {
        self.tiles.get(&tile_id)
    }

    pub fn get_hardness(&self, tile_id: u8) -> i32 {
        self.tiles
            .get(&tile_id)
            .map(|t| t.properties.hardness)
            .unwrap_or(1)
    }

    pub fn get_damage_stages(&self, tile_id: u8) -> i32 {
        self.tiles
            .get(&tile_id)
            .map(|t| t.properties.damage_stages)
            .unwrap_or(2)
    }

    pub fn get_break_noise(&self, tile_id: u8) -> f32 {
        self.tiles
            .get(&tile_id)
            .map(|t| t.properties.break_noise)
            .unwrap_or(0.0)
    }

    pub fn get_effective_hardness(&self, tile_id: u8, damage_stage: u8) -> f32 {
        let base_hardness = self.get_hardness(tile_id) as f32;
        let max_stages = self.get_damage_stages(tile_id);
        if max_stages <= 0 {
            return base_hardness;
        }
        let scale = 1.0 - (damage_stage as f32 / max_stages as f32);
        base_hardness * scale
    }

    pub fn get_directional_hardness(&self, tile_id: u8, entry_dir: Vec2) -> f32 {
        let Some(tile) = self.tiles.get(&tile_id) else {
            return self.get_hardness(tile_id) as f32;
        };
        let edges = &tile.edge_hardness;
        let mut h = 0.0f32;
        let mut count = 0;
        if entry_dir.y < -0.5 {
            h += edges.n;
            count += 1;
        }
        if entry_dir.y > 0.5 {
            h += edges.s;
            count += 1;
        }
        if entry_dir.x < -0.5 {
            h += edges.w;
            count += 1;
        }
        if entry_dir.x > 0.5 {
            h += edges.e;
            count += 1;
        }
        if count == 0 {
            return self.get_hardness(tile_id) as f32;
        }
        h / (count as f32)
    }

    pub fn get_effective_directional_hardness(
        &self,
        tile_id: u8,
        damage_stage: u8,
        entry_dir: Vec2,
    ) -> f32 {
        let base = self.get_directional_hardness(tile_id, entry_dir);
        let max_stages = self.get_damage_stages(tile_id);
        if max_stages <= 0 {
            return base;
        }
        let scale = 1.0 - (damage_stage as f32 / max_stages as f32);
        base * scale
    }
}
