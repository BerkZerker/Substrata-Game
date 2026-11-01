use std::path::Path;

use substrata::engine::app::{EngineApp, EngineConfig};
use substrata::game::settings::CHUNK_SIZE_U32;
use substrata::game::tiles::TileRegistry;
use substrata::game::SubstrataGame;

fn load_player_sprite() -> (Vec<u8>, u32, u32) {
    let path = Path::new("assets/textures/player.png");
    if let Ok(img) = image::open(path) {
        let rgba = img.to_rgba8();
        let (w, h) = rgba.dimensions();
        return (rgba.into_raw(), w, h);
    }
    // Fallback 10x16 cyan sprite if asset is missing
    let (w, h) = (10u32, 16u32);
    let mut bytes = Vec::with_capacity((w * h * 4) as usize);
    for _ in 0..(w * h) {
        bytes.extend_from_slice(&[80, 200, 255, 255]);
    }
    (bytes, w, h)
}

fn main() {
    env_logger::init();

    let tile_registry = TileRegistry::new_default();
    let tile_texture_size = tile_registry.texture_size();
    let tile_layers_rgba = tile_registry.texture_layers_rgba().to_vec();
    let (player_rgba, player_width, player_height) = load_player_sprite();

    let game = SubstrataGame::new(tile_registry, None);

    let config = EngineConfig {
        title: "Substrata (Rust / wgpu Native Engine)".to_string(),
        width: 1920,
        height: 1080,
        chunk_size: CHUNK_SIZE_U32,
        tile_texture_size,
        tile_layers_rgba,
        player_rgba,
        player_width,
        player_height,
    };

    EngineApp::new(config, game).run();
}
