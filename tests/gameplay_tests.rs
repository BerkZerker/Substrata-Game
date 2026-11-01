use glam::{IVec2, Vec2};
use substrata::game::physics::collision::CollisionDetector;
use substrata::game::physics::movement::MovementController;
use substrata::game::settings::{CHUNK_BYTE_LEN, CHUNK_SIZE};
use substrata::game::signals::SignalBus;
use substrata::game::tiles::{TileRegistry, AIR, DIRT, GRASS, STONE};
use substrata::game::world::chunk_manager::{ChunkManager, WorldTileChange};
use substrata::game::world::generator::{
    BaseTerrainGenerator, SimplexConfig, SimplexTerrainGenerator,
};
use substrata::game::world::persistence::WorldSaveManager;
use substrata::game::world::terrain_editor::TerrainEditor;

#[test]
fn test_tile_registry_and_edge_hardness() {
    let registry = TileRegistry::new_default();
    assert!(!registry.is_solid(AIR));
    assert!(registry.is_solid(DIRT));
    assert!(registry.is_solid(GRASS));
    assert!(registry.is_solid(STONE));

    assert_eq!(registry.get_hardness(STONE), 8);
    assert_eq!(registry.get_damage_stages(STONE), 2);
    assert!((registry.get_effective_hardness(STONE, 0) - 8.0).abs() < 1e-4);
    assert!((registry.get_effective_hardness(STONE, 1) - 4.0).abs() < 1e-4);

    // Directional edge hardness should be positive and derived from texture luminance
    let stone_n = registry.get_directional_hardness(STONE, Vec2::new(0.0, -1.0));
    let stone_s = registry.get_directional_hardness(STONE, Vec2::new(0.0, 1.0));
    assert!(stone_n > 0.0);
    assert!(stone_s > 0.0);
}

#[test]
fn test_simplex_generator_determinism_and_shape() {
    let gen1 = SimplexTerrainGenerator::new(12345, SimplexConfig::default());
    let gen2 = SimplexTerrainGenerator::new(12345, SimplexConfig::default());

    let c0_a = gen1.generate_chunk(IVec2::new(0, 0));
    let c0_b = gen2.generate_chunk(IVec2::new(0, 0));
    assert_eq!(c0_a.len(), CHUNK_BYTE_LEN);
    assert_eq!(c0_a, c0_b);

    // Deep underground chunk (y = 10 -> world_y = 320..352) should be solid stone
    let deep = gen1.generate_chunk(IVec2::new(0, 10));
    for i in (0..deep.len()).step_by(2) {
        assert_eq!(deep[i], STONE);
        assert_eq!(deep[i + 1], 0);
    }

    // High sky chunk (y = -10 -> world_y = -320..-288) should be air
    let sky = gen1.generate_chunk(IVec2::new(0, -10));
    for i in (0..sky.len()).step_by(2) {
        assert_eq!(sky[i], AIR);
        assert_eq!(sky[i + 1], 0);
    }
}

#[test]
fn test_coordinate_conversions_negative_and_positive() {
    assert_eq!(
        ChunkManager::world_to_chunk_pos(Vec2::new(0.0, 0.0)),
        IVec2::new(0, 0)
    );
    assert_eq!(
        ChunkManager::world_to_chunk_pos(Vec2::new(31.9, 31.9)),
        IVec2::new(0, 0)
    );
    assert_eq!(
        ChunkManager::world_to_chunk_pos(Vec2::new(-0.1, -0.1)),
        IVec2::new(-1, -1)
    );
    assert_eq!(
        ChunkManager::world_to_tile_pos(Vec2::new(-1.0, -1.0)),
        IVec2::new(CHUNK_SIZE - 1, CHUNK_SIZE - 1)
    );
    assert_eq!(
        ChunkManager::world_to_tile_pos(Vec2::new(-32.0, -32.0)),
        IVec2::new(0, 0)
    );
}

#[test]
fn test_swept_aabb_collision_and_step_up() {
    let registry = TileRegistry::new_default();
    let mut signals = SignalBus::new();
    let mut chunk_manager = ChunkManager::new(42);

    // Pre-populate chunk (0, 0) using a saved chunk via WorldSaveManager or direct generation
    let temp_world = format!("test_phys_{}", std::process::id());
    let save_mgr = WorldSaveManager::new();
    let empty_chunk = vec![0u8; CHUNK_BYTE_LEN];
    save_mgr.save_chunk(&temp_world, IVec2::new(0, 0), &empty_chunk);
    chunk_manager.setup_persistence(save_mgr.clone(), temp_world.clone());
    chunk_manager.on_player_chunk_changed(IVec2::new(0, 0), &mut signals);

    // Build a flat stone floor at y = 20 across x = 0..31, plus a 2-tile step at x = 15 (y = 18, 19)
    let mut floor_changes = Vec::new();
    for x in 0..32 {
        floor_changes.push(WorldTileChange {
            pos: Vec2::new(x as f32, 20.0),
            tile_id: STONE,
            damage_stage: 0,
        });
    }
    floor_changes.push(WorldTileChange {
        pos: Vec2::new(15.0, 19.0),
        tile_id: STONE,
        damage_stage: 0,
    });
    floor_changes.push(WorldTileChange {
        pos: Vec2::new(15.0, 18.0),
        tile_id: STONE,
        damage_stage: 0,
    });
    chunk_manager.set_tiles_at_world_positions(&floor_changes, &mut signals);

    // Sweep a 10x16 player box downward onto the floor at y=20 (player center should stop at y = 12.0)
    let sweep = CollisionDetector::sweep_aabb(
        Vec2::new(6.0, 10.0),
        Vec2::new(10.0, 16.0),
        Vec2::new(0.0, 5.0),
        &chunk_manager,
        &registry,
    );
    assert!(sweep.collided);
    assert!((sweep.position.y - 12.0).abs() < 1e-3);
    assert!((sweep.normal.y - -1.0).abs() < 1e-3);

    // Now test MovementController walking right over the 2-unit step at x = 15
    let mut movement = MovementController::new();
    let mut pos = Vec2::new(6.0, 12.0);
    for _ in 0..60 {
        pos = movement.move_body(pos, 1.0, false, 1.0 / 60.0, &chunk_manager, &registry);
    }
    // Player should have stepped up onto the obstacle and passed x = 15
    assert!(pos.x > 15.0, "Expected player to step up past x=15, got {}", pos.x);

    save_mgr.delete_world(&temp_world);
}

#[test]
fn test_dijkstra_flood_fill_and_orphan_cleanup() {
    let registry = TileRegistry::new_default();
    let mut signals = SignalBus::new();
    let mut chunk_manager = ChunkManager::new(99);

    let temp_world = format!("test_edit_{}", std::process::id());
    let save_mgr = WorldSaveManager::new();
    let mut solid_dirt = vec![0u8; CHUNK_BYTE_LEN];
    for i in (0..solid_dirt.len()).step_by(2) {
        solid_dirt[i] = DIRT;
        solid_dirt[i + 1] = 0;
    }
    save_mgr.save_chunk(&temp_world, IVec2::new(0, 0), &solid_dirt);
    chunk_manager.setup_persistence(save_mgr.clone(), temp_world.clone());
    chunk_manager.on_player_chunk_changed(IVec2::new(0, 0), &mut signals);

    let editor = TerrainEditor::new();
    let changes = editor.edit_at(
        Vec2::new(16.0, 16.0),
        12.0,
        &mut chunk_manager,
        &registry,
        &mut signals,
    );
    assert!(!changes.is_empty());
    // Origin tile (16, 16) must be destroyed (turned to AIR)
    assert_eq!(
        chunk_manager.get_tile_at_world_pos(Vec2::new(16.0, 16.0))[0],
        AIR
    );

    // Test orphan cleanup: create an isolated 3-tile dirt cluster surrounded by air
    let empty_chunk = vec![0u8; CHUNK_BYTE_LEN];
    save_mgr.save_chunk(&temp_world, IVec2::new(1, 0), &empty_chunk);
    chunk_manager.on_player_chunk_changed(IVec2::new(4, 0), &mut signals);

    let cluster_tiles = [
        WorldTileChange {
            pos: Vec2::new(40.0, 10.0),
            tile_id: GRASS,
            damage_stage: 0,
        },
        WorldTileChange {
            pos: Vec2::new(41.0, 10.0),
            tile_id: DIRT,
            damage_stage: 0,
        },
        WorldTileChange {
            pos: Vec2::new(42.0, 10.0),
            tile_id: STONE,
            damage_stage: 0,
        },
    ];
    chunk_manager.set_tiles_at_world_positions(&cluster_tiles, &mut signals);

    // Break only the grass tile at (40, 10) with small force (2.5 breaks grass H=2, not dirt+stone)
    editor.edit_at(
        Vec2::new(40.0, 10.0),
        2.5,
        &mut chunk_manager,
        &registry,
        &mut signals,
    );

    // Because the remaining 2 tiles at (41,10) and (42,10) form an orphaned cluster <= 10 tiles,
    // the orphan cleanup pass should have destroyed all 3 tiles!
    assert_eq!(
        chunk_manager.get_tile_at_world_pos(Vec2::new(40.0, 10.0))[0],
        AIR
    );
    assert_eq!(
        chunk_manager.get_tile_at_world_pos(Vec2::new(41.0, 10.0))[0],
        AIR
    );
    assert_eq!(
        chunk_manager.get_tile_at_world_pos(Vec2::new(42.0, 10.0))[0],
        AIR
    );

    save_mgr.delete_world(&temp_world);
}

#[test]
fn test_wgpu_shaders_and_pipelines_validation() {
    use glam::Mat4;
    use substrata::engine::renderer::chunk_pass::{ChunkInstance, ChunkPass};
    use substrata::engine::renderer::debug_pass::{DebugBatch, DebugPass};
    use substrata::engine::renderer::sprite_pass::{SpriteInstance, SpritePass};
    use substrata::engine::renderer::ui_pass::UiPass;
    use substrata::engine::ui::UiBatch;

    let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
        backends: wgpu::Backends::PRIMARY,
        ..Default::default()
    });

    let Some(adapter) = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        compatible_surface: None,
        force_fallback_adapter: false,
    })) else {
        return;
    };

    let (device, queue) = pollster::block_on(adapter.request_device(
        &wgpu::DeviceDescriptor::default(),
        None,
    ))
    .expect("Failed to create headless wgpu device");

    let format = wgpu::TextureFormat::Bgra8Unorm;
    let registry = TileRegistry::new_default();
    let mut chunk_pass = ChunkPass::new(
        &device,
        &queue,
        format,
        32,
        registry.texture_size(),
        registry.texture_layers_rgba(),
    );

    let player_rgba = vec![255u8; 10 * 16 * 4];
    let sprite_pass = SpritePass::new(&device, &queue, format, &player_rgba, 10, 16);
    let debug_pass = DebugPass::new(&device, format);
    let ui_pass = UiPass::new(
        &device,
        &queue,
        format,
        chunk_pass.tile_array_view(),
        chunk_pass.tile_sampler(),
    );

    // Upload a generated chunk to the atlas
    let gen = SimplexTerrainGenerator::new(123, SimplexConfig::default());
    let chunk_data = gen.generate_chunk(IVec2::new(0, 0));
    let slot = chunk_pass.allocate_slot().unwrap();
    chunk_pass.write_chunk_data(&queue, slot, &chunk_data);

    // Render all 4 passes into an offscreen target to verify full pipeline + bind group compatibility
    let target = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("offscreen_test_target"),
        size: wgpu::Extent3d {
            width: 640,
            height: 360,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        view_formats: &[],
    });
    let view = target.create_view(&wgpu::TextureViewDescriptor::default());

    let mut debug_batch = DebugBatch::new();
    debug_batch.draw_circle_outline(Vec2::ZERO, 10.0, 1.0, 24, [1.0, 1.0, 1.0, 0.5]);

    let mut ui_batch = UiBatch::new();
    ui_batch.draw_panel(Vec2::new(10.0, 10.0), Vec2::new(120.0, 40.0));
    ui_batch.draw_text_shadowed(
        Vec2::new(20.0, 20.0),
        "Brush: 10",
        10.0,
        [1.0, 1.0, 1.0, 1.0],
    );

    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor::default());
    {
        let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("test_pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                    store: wgpu::StoreOp::Store,
                },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
        });

        let chunk_instances = [ChunkInstance {
            chunk_world_pos: [0.0, 0.0],
            atlas_slot: ChunkPass::slot_coords(slot),
        }];
        let sprite_instances = [SpriteInstance {
            center_pos: [16.0, 16.0],
            size: [10.0, 16.0],
            tint: [1.0, 1.0, 1.0, 1.0],
        }];

        chunk_pass.render(&queue, &mut rpass, Mat4::IDENTITY, &chunk_instances);
        sprite_pass.render(&queue, &mut rpass, Mat4::IDENTITY, &sprite_instances);
        debug_pass.render(&queue, &mut rpass, Mat4::IDENTITY, &debug_batch);
        ui_pass.render(
            &queue,
            &mut rpass,
            Vec2::new(640.0, 360.0),
            &ui_batch.instances,
        );
    }
    queue.submit(std::iter::once(encoder.finish()));
}
