use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use glam::IVec2;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::game::settings::CHUNK_BYTE_LEN;

pub const SAVE_FORMAT_VERSION: i32 = 1;
pub const WORLDS_BASE_PATH: &str = "data";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorldMeta {
    pub world_seed: i32,
    pub generator_name: String,
    pub generator_config: Value,
    pub version: i32,
    pub created_at: String,
    pub last_saved_at: String,
}

/// Manages saving and loading world data to disk (`src/world/persistence/world_save_manager.gd`).
/// File format and paths (`data/{world_name}/world_meta.json` and `chunks/chunk_{x}_{y}.dat`)
/// are 100% compatible with the Godot version.
#[derive(Default, Clone)]
pub struct WorldSaveManager;

impl WorldSaveManager {
    pub fn new() -> Self {
        Self
    }

    fn get_world_dir(&self, world_name: &str) -> PathBuf {
        Path::new(WORLDS_BASE_PATH).join(world_name)
    }

    fn get_chunks_dir(&self, world_name: &str) -> PathBuf {
        self.get_world_dir(world_name).join("chunks")
    }

    fn get_meta_path(&self, world_name: &str) -> PathBuf {
        self.get_world_dir(world_name).join("world_meta.json")
    }

    fn get_chunk_path(&self, world_name: &str, chunk_pos: IVec2) -> PathBuf {
        self.get_chunks_dir(world_name)
            .join(format!("chunk_{}_{}.dat", chunk_pos.x, chunk_pos.y))
    }

    fn ensure_world_dirs(&self, world_name: &str) -> bool {
        let chunks_dir = self.get_chunks_dir(world_name);
        if let Err(e) = fs::create_dir_all(&chunks_dir) {
            log::error!(
                "WorldSaveManager: Failed to create directory '{}': {}",
                chunks_dir.display(),
                e
            );
            return false;
        }
        true
    }

    pub fn save_chunk(&self, world_name: &str, chunk_pos: IVec2, terrain_data: &[u8]) -> bool {
        if terrain_data.is_empty() {
            return false;
        }
        if !self.ensure_world_dirs(world_name) {
            return false;
        }
        let path = self.get_chunk_path(world_name, chunk_pos);
        if let Err(e) = fs::write(&path, terrain_data) {
            log::error!(
                "WorldSaveManager: Failed to write chunk '{}': {}",
                path.display(),
                e
            );
            return false;
        }
        true
    }

    pub fn load_chunk(&self, world_name: &str, chunk_pos: IVec2) -> Option<Vec<u8>> {
        let path = self.get_chunk_path(world_name, chunk_pos);
        if !path.exists() {
            return None;
        }
        let data = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) => {
                log::error!(
                    "WorldSaveManager: Failed to read chunk '{}': {}",
                    path.display(),
                    e
                );
                return None;
            }
        };

        if data.len() != CHUNK_BYTE_LEN {
            log::error!(
                "WorldSaveManager: Chunk data size mismatch at '{}': got {}, expected {}",
                path.display(),
                data.len(),
                CHUNK_BYTE_LEN
            );
            return None;
        }
        Some(data)
    }

    pub fn has_saved_chunk(&self, world_name: &str, chunk_pos: IVec2) -> bool {
        self.get_chunk_path(world_name, chunk_pos).exists()
    }

    pub fn save_world_meta(
        &self,
        world_name: &str,
        world_seed: i32,
        generator_name: &str,
        generator_config: Value,
    ) -> bool {
        if !self.ensure_world_dirs(world_name) {
            return false;
        }

        let now = Self::get_iso_timestamp();
        let created_at = self
            .load_world_meta(world_name)
            .map(|m| m.created_at)
            .unwrap_or_else(|| now.clone());

        let meta = WorldMeta {
            world_seed,
            generator_name: generator_name.to_string(),
            generator_config,
            version: SAVE_FORMAT_VERSION,
            created_at,
            last_saved_at: now,
        };

        let Ok(json_string) = serde_json::to_string_pretty(&meta) else {
            return false;
        };
        let path = self.get_meta_path(world_name);
        if let Err(e) = fs::write(&path, json_string) {
            log::error!(
                "WorldSaveManager: Failed to write meta '{}': {}",
                path.display(),
                e
            );
            return false;
        }
        true
    }

    pub fn load_world_meta(&self, world_name: &str) -> Option<WorldMeta> {
        let path = self.get_meta_path(world_name);
        if !path.exists() {
            return None;
        }
        let text = fs::read_to_string(&path).ok()?;
        serde_json::from_str(&text).ok()
    }

    pub fn list_worlds(&self) -> Vec<String> {
        let mut worlds = Vec::new();
        let base = Path::new(WORLDS_BASE_PATH);
        let Ok(entries) = fs::read_dir(base) else {
            return worlds;
        };
        for entry in entries.flatten() {
            if entry.path().is_dir() && entry.path().join("world_meta.json").exists() {
                if let Some(name) = entry.file_name().to_str() {
                    worlds.push(name.to_string());
                }
            }
        }
        worlds.sort();
        worlds
    }

    pub fn delete_world(&self, world_name: &str) -> bool {
        let world_dir = self.get_world_dir(world_name);
        if !world_dir.exists() {
            return true;
        }
        fs::remove_dir_all(&world_dir).is_ok()
    }

    fn get_iso_timestamp() -> String {
        // Civil UTC calendar calculation from UNIX_EPOCH seconds (Howard Hinnant algorithm)
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let days = secs.div_euclid(86_400);
        let rem = secs.rem_euclid(86_400);
        let hour = rem / 3600;
        let minute = (rem % 3600) / 60;
        let second = rem % 60;

        let z = days + 719_468;
        let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
        let doe = (z - era * 146_097) as u32;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
        let y = (yoe as i64) + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        let year = if m <= 2 { y + 1 } else { y };

        format!("{year:04}-{m:02}-{d:02}T{hour:02}:{minute:02}:{second:02}Z")
    }
}
