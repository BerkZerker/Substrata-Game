## Headless test runner for Substrata engine.
##
## Run via: tests/run_tests.sh
## (swaps main scene temporarily, runs headless, restores)
extends Node

var _passed: int = 0
var _failed: int = 0
var _errors: Array[String] = []


func _ready() -> void:
	# Defer to ensure all autoloads are fully initialized
	call_deferred("_run_all_tests")


func _run_all_tests() -> void:
	print("\n========================================")
	print("  Substrata Engine — Test Suite")
	print("========================================\n")

	_test_game_services()
	_test_tile_registry()
	_test_base_terrain_generator()
	_test_simplex_terrain_generator()
	_test_chunk_data_format()
	_test_world_save_manager()
	_test_camera_controller()
	_test_entity_system()
	_test_signal_bus()

	_print_results()

	# Exit with appropriate code
	get_tree().quit(1 if _failed > 0 else 0)


# ─── GameServices Tests ──────────────────────────────────────────────

func _test_game_services() -> void:
	print("--- GameServices ---")

	# Verify service properties exist
	_assert_true("chunk_manager" in GameServices, "GameServices has chunk_manager property")
	_assert_true("tile_registry" in GameServices, "GameServices has tile_registry property")
	_assert_true("terrain_generator" in GameServices, "GameServices has terrain_generator property")
	_assert_true("world_save_manager" in GameServices, "GameServices has world_save_manager property")
	_assert_true("entity_manager" in GameServices, "GameServices has entity_manager property")
	_assert_true("dynamic_light_manager" in GameServices, "GameServices has dynamic_light_manager property")

	# In headless test mode, services won't be populated by GameInstance,
	# but we can verify they accept assignment and return null by default
	_assert_true(GameServices.chunk_manager == null, "chunk_manager is null in test context")
	_assert_true(GameServices.tile_registry == null, "tile_registry is null in test context")
	_assert_true(GameServices.terrain_generator == null, "terrain_generator is null in test context")
	_assert_true(GameServices.world_save_manager == null, "world_save_manager is null in test context")
	_assert_true(GameServices.entity_manager == null, "entity_manager is null in test context")

	# Test that tile_registry can be set to TileIndex autoload
	GameServices.tile_registry = TileIndex
	_assert_true(GameServices.tile_registry != null, "tile_registry accepts TileIndex assignment")
	_assert_true(GameServices.tile_registry == TileIndex, "tile_registry is TileIndex")
	GameServices.tile_registry = null # Reset

	print("")


# ─── Tile Registry Tests ─────────────────────────────────────────────

func _test_tile_registry() -> void:
	print("--- TileIndex (Tile Registry) ---")

	# Test backward-compatible constants
	_assert_eq(TileIndex.AIR, 0, "AIR constant is 0")
	_assert_eq(TileIndex.DIRT, 1, "DIRT constant is 1")
	_assert_eq(TileIndex.GRASS, 2, "GRASS constant is 2")
	_assert_eq(TileIndex.STONE, 3, "STONE constant is 3")

	# Test extended tile constants
	_assert_eq(TileIndex.SAND, 4, "SAND constant is 4")
	_assert_eq(TileIndex.ICE, 8, "ICE constant is 8")
	_assert_eq(TileIndex.LAVA, 13, "LAVA constant is 13")
	_assert_eq(TileIndex.VINES, 16, "VINES constant is 16")

	# Test tile count (17 tiles: AIR + 16 material tiles)
	_assert_eq(TileIndex.get_tile_count(), 17, "Default tile count is 17")

	# Test is_solid
	_assert_eq(TileIndex.is_solid(TileIndex.AIR), false, "AIR is not solid")
	_assert_eq(TileIndex.is_solid(TileIndex.DIRT), true, "DIRT is solid")
	_assert_eq(TileIndex.is_solid(TileIndex.GRASS), true, "GRASS is solid")
	_assert_eq(TileIndex.is_solid(TileIndex.STONE), true, "STONE is solid")
	_assert_eq(TileIndex.is_solid(999), false, "Unknown tile is not solid")

	# Test get_tile_name
	_assert_eq(TileIndex.get_tile_name(TileIndex.AIR), "Air", "AIR name is Air")
	_assert_eq(TileIndex.get_tile_name(TileIndex.DIRT), "Dirt", "DIRT name is Dirt")
	_assert_eq(TileIndex.get_tile_name(TileIndex.GRASS), "Grass", "GRASS name is Grass")
	_assert_eq(TileIndex.get_tile_name(TileIndex.STONE), "Stone", "STONE name is Stone")
	_assert_eq(TileIndex.get_tile_name(999), "Unknown", "Unknown tile name is Unknown")

	# Test get_tile_ids returns sorted array
	var ids = TileIndex.get_tile_ids()
	_assert_eq(ids.size(), 17, "get_tile_ids returns 17 IDs")
	_assert_eq(ids[0], 0, "First tile ID is 0")
	_assert_eq(ids[16], 16, "Last tile ID is 16")

	# Test get_tile_color
	var air_color = TileIndex.get_tile_color(TileIndex.AIR)
	_assert_true(air_color is Color, "AIR color is a Color")
	var unknown_color = TileIndex.get_tile_color(999)
	_assert_eq(unknown_color, Color.WHITE, "Unknown tile color is white")

	# Test get_tile_def
	var dirt_def = TileIndex.get_tile_def(TileIndex.DIRT)
	_assert_true(dirt_def != null, "DIRT definition exists")
	_assert_eq(dirt_def["name"], "Dirt", "DIRT def name is Dirt")
	_assert_eq(dirt_def["solid"], true, "DIRT def solid is true")
	_assert_true(dirt_def["texture_path"] != "", "DIRT has a texture path")
	_assert_true(TileIndex.get_tile_def(999) == null, "Unknown tile def is null")

	# Test texture array
	var tex_array = TileIndex.get_texture_array()
	_assert_true(tex_array != null, "Texture array is built")
	_assert_true(tex_array is Texture2DArray, "Texture array is Texture2DArray")

	# Test tile properties
	_assert_eq(TileIndex.get_friction(TileIndex.DIRT), 1.0, "DIRT friction is 1.0 (default)")
	_assert_eq(TileIndex.get_damage(TileIndex.DIRT), 0.0, "DIRT damage is 0.0 (default)")
	_assert_eq(TileIndex.get_transparency(TileIndex.AIR), 0.0, "AIR transparency is 0.0 (custom)")
	_assert_eq(TileIndex.get_hardness(TileIndex.AIR), 0, "AIR hardness is 0 (custom)")
	_assert_eq(TileIndex.get_hardness(TileIndex.STONE), 3, "STONE hardness is 3 (custom)")
	_assert_eq(TileIndex.get_hardness(TileIndex.DIRT), 1, "DIRT hardness is 1 (default)")

	# Test get_tile_property for unknown tile returns default
	_assert_eq(TileIndex.get_tile_property(999, "friction"), 1.0, "Unknown tile friction returns default")
	_assert_eq(TileIndex.get_tile_property(TileIndex.DIRT, "friction"), 1.0, "DIRT friction via get_tile_property")

	# Test dynamic registration with properties (use high ID to avoid conflict)
	TileIndex.register_tile(100, "TestTile", true, "", Color(0.9, 0.8, 0.5), {"friction": 0.5})
	_assert_eq(TileIndex.get_tile_count(), 18, "Tile count after registering TestTile is 18")
	_assert_eq(TileIndex.get_tile_name(100), "TestTile", "TestTile name is correct")
	_assert_eq(TileIndex.is_solid(100), true, "TestTile is solid")
	_assert_eq(TileIndex.get_friction(100), 0.5, "TestTile friction is 0.5 (custom)")
	_assert_eq(TileIndex.get_damage(100), 0.0, "TestTile damage is 0.0 (default)")

	# Test extended tile properties
	_assert_eq(TileIndex.get_friction(TileIndex.ICE), 0.1, "ICE friction is 0.1")
	_assert_eq(TileIndex.get_damage(TileIndex.LAVA), 10.0, "LAVA damage is 10.0")
	_assert_eq(TileIndex.get_emission(TileIndex.LAVA), 60, "LAVA emission is 60")
	_assert_eq(TileIndex.get_speed_modifier(TileIndex.WATER), 0.5, "WATER speed_modifier is 0.5")
	_assert_eq(TileIndex.get_speed_modifier(TileIndex.DIRT), 1.0, "DIRT speed_modifier is 1.0 (default)")
	_assert_eq(TileIndex.is_solid(TileIndex.WATER), false, "WATER is not solid")
	_assert_eq(TileIndex.is_solid(TileIndex.LAVA), false, "LAVA is not solid")

	# Clean up: remove test tile (restore original state for other tests)
	TileIndex._tiles.erase(100)

	# Test collision solidity (verifies is_solid matches expected for all default tiles)
	_assert_eq(TileIndex.is_solid(TileIndex.AIR), false, "Collision: AIR is not solid")
	_assert_eq(TileIndex.is_solid(TileIndex.DIRT), true, "Collision: DIRT is solid")
	_assert_eq(TileIndex.is_solid(TileIndex.GRASS), true, "Collision: GRASS is solid")
	_assert_eq(TileIndex.is_solid(TileIndex.STONE), true, "Collision: STONE is solid")

	print("")


# ─── BaseTerrainGenerator Tests ──────────────────────────────────────

func _test_base_terrain_generator() -> void:
	print("--- BaseTerrainGenerator ---")

	var base_gen = BaseTerrainGenerator.new()
	_assert_eq(base_gen.get_generator_name(), "base", "Base generator name is 'base'")

	# Base class generate_chunk should return empty PackedByteArray
	var data = base_gen.generate_chunk(Vector2i(0, 0))
	_assert_eq(data.size(), 0, "Base generate_chunk returns empty data")

	print("")


# ─── SimplexTerrainGenerator Tests ───────────────────────────────────

func _test_simplex_terrain_generator() -> void:
	print("--- SimplexTerrainGenerator ---")

	var gen = SimplexTerrainGenerator.new(12345)
	_assert_eq(gen.get_generator_name(), "simplex", "Simplex generator name is 'simplex'")

	# Generate a chunk
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var data = gen.generate_chunk(Vector2i(0, 0))
	var expected_size = chunk_size * chunk_size * 2
	_assert_eq(data.size(), expected_size, "Chunk data size is correct (%d bytes)" % expected_size)

	# Verify all tile IDs are valid (0-3 for default tiles)
	var valid = true
	for i in range(0, data.size(), 2):
		var tile_id = data[i]
		if tile_id > 3:
			valid = false
			_errors.append("Invalid tile_id %d at index %d" % [tile_id, i])
			break
	_assert_true(valid, "All tile IDs are valid (0-3)")

	# Verify cell_ids are all 0 (unused)
	var all_zero_cells = true
	for i in range(1, data.size(), 2):
		if data[i] != 0:
			all_zero_cells = false
			break
	_assert_true(all_zero_cells, "All cell_ids are 0")

	# Test determinism: same seed produces same chunk
	var gen2 = SimplexTerrainGenerator.new(12345)
	var data2 = gen2.generate_chunk(Vector2i(0, 0))
	_assert_eq(data, data2, "Same seed produces identical chunk data")

	# Test different seeds produce different chunks
	var gen3 = SimplexTerrainGenerator.new(99999)
	var data3 = gen3.generate_chunk(Vector2i(0, 0))
	_assert_true(data != data3, "Different seeds produce different chunks")

	# Test chunk at surface level has both air and solid tiles
	var has_air = false
	var has_solid = false
	for i in range(0, data.size(), 2):
		if data[i] == TileIndex.AIR:
			has_air = true
		elif data[i] > 0:
			has_solid = true
	_assert_true(has_air, "Surface chunk has air tiles")
	_assert_true(has_solid, "Surface chunk has solid tiles")

	# Test deep underground chunk is all solid
	var deep_data = gen.generate_chunk(Vector2i(0, 100))
	var all_solid = true
	for i in range(0, deep_data.size(), 2):
		if deep_data[i] == TileIndex.AIR:
			all_solid = false
			break
	_assert_true(all_solid, "Deep underground chunk (y=100) is all solid")

	# Test high sky chunk is all air
	var sky_data = gen.generate_chunk(Vector2i(0, -100))
	var all_air = true
	for i in range(0, sky_data.size(), 2):
		if sky_data[i] != TileIndex.AIR:
			all_air = false
			break
	_assert_true(all_air, "High sky chunk (y=-100) is all air")

	# Test custom config
	var custom_gen = SimplexTerrainGenerator.new(12345, {"grass_depth": 10, "dirt_depth": 5})
	var custom_data = custom_gen.generate_chunk(Vector2i(0, 0))
	_assert_eq(custom_data.size(), expected_size, "Custom config generates correct size")
	_assert_true(custom_data != data, "Custom config produces different terrain")

	print("")


# ─── Chunk Data Format Tests ─────────────────────────────────────────

func _test_chunk_data_format() -> void:
	print("--- Chunk Data Format ---")

	var chunk_size = GlobalSettings.CHUNK_SIZE
	_assert_eq(chunk_size, 32, "CHUNK_SIZE is 32")

	# Test data indexing convention: (y * CHUNK_SIZE + x) * 2
	var gen = SimplexTerrainGenerator.new(42)
	var data = gen.generate_chunk(Vector2i(0, 0))

	# Verify we can index every tile without out-of-bounds
	var all_in_bounds = true
	for y in range(chunk_size):
		for x in range(chunk_size):
			var index = (y * chunk_size + x) * 2
			if index + 1 >= data.size():
				all_in_bounds = false
				break
	_assert_true(all_in_bounds, "All tile indices are within bounds")

	# GlobalSettings constants exist and are reasonable
	_assert_true(GlobalSettings.REGION_SIZE > 0, "REGION_SIZE > 0")
	_assert_true(GlobalSettings.LOD_RADIUS > 0, "LOD_RADIUS > 0")
	_assert_true(GlobalSettings.MAX_CHUNK_POOL_SIZE > 0, "MAX_CHUNK_POOL_SIZE > 0")
	_assert_true(GlobalSettings.MAX_CHUNK_BUILDS_PER_FRAME > 0, "MAX_CHUNK_BUILDS_PER_FRAME > 0")

	print("")


# ─── WorldSaveManager Tests ──────────────────────────────────────────

func _test_world_save_manager() -> void:
	print("--- WorldSaveManager ---")

	var save_mgr = WorldSaveManager.new()

	# Test constants
	_assert_eq(WorldSaveManager.SAVE_FORMAT_VERSION, 1, "Save format version is 1")
	_assert_eq(WorldSaveManager.WORLDS_BASE_PATH, "user://worlds/", "Worlds base path is correct")

	# Test save and load world metadata
	var test_world = "_test_world_%d" % randi()
	var saved = save_mgr.save_world_meta(test_world, 12345, "simplex", {"grass_depth": 3})
	_assert_true(saved, "save_world_meta returns true")

	var meta = save_mgr.load_world_meta(test_world)
	_assert_true(not meta.is_empty(), "load_world_meta returns non-empty dict")
	_assert_eq(int(meta.get("world_seed", 0)), 12345, "Metadata seed is 12345")
	_assert_eq(meta.get("generator_name", ""), "simplex", "Metadata generator is simplex")
	_assert_eq(int(meta.get("version", 0)), 1, "Metadata version is 1")
	_assert_true(meta.has("created_at"), "Metadata has created_at")
	_assert_true(meta.has("last_saved_at"), "Metadata has last_saved_at")

	# Test save_world_meta preserves created_at on update
	var original_created_at = meta["created_at"]
	save_mgr.save_world_meta(test_world, 12345, "simplex", {})
	var meta2 = save_mgr.load_world_meta(test_world)
	_assert_eq(meta2["created_at"], original_created_at, "created_at preserved on update")

	# Test chunk save and load
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var test_data = PackedByteArray()
	test_data.resize(chunk_size * chunk_size * 2)
	test_data[0] = TileIndex.DIRT
	test_data[1] = 0
	test_data[2] = TileIndex.STONE
	test_data[3] = 0

	var chunk_saved = save_mgr.save_chunk(test_world, Vector2i(5, -3), test_data)
	_assert_true(chunk_saved, "save_chunk returns true")

	_assert_true(save_mgr.has_saved_chunk(test_world, Vector2i(5, -3)), "has_saved_chunk returns true for saved chunk")
	_assert_true(not save_mgr.has_saved_chunk(test_world, Vector2i(99, 99)), "has_saved_chunk returns false for unsaved chunk")

	var loaded_data = save_mgr.load_chunk(test_world, Vector2i(5, -3))
	_assert_eq(loaded_data.size(), test_data.size(), "Loaded chunk data size matches")
	_assert_eq(loaded_data[0], TileIndex.DIRT, "Loaded chunk tile 0 is DIRT")
	_assert_eq(loaded_data[2], TileIndex.STONE, "Loaded chunk tile 1 is STONE")

	# Test load_chunk returns empty for nonexistent chunk
	var missing = save_mgr.load_chunk(test_world, Vector2i(999, 999))
	_assert_eq(missing.size(), 0, "load_chunk returns empty for missing chunk")

	# Test list_worlds includes test world
	var worlds = save_mgr.list_worlds()
	_assert_true(worlds.has(test_world), "list_worlds includes test world")

	# Test load_world_meta returns empty for nonexistent world
	var no_meta = save_mgr.load_world_meta("_nonexistent_world_xyz")
	_assert_true(no_meta.is_empty(), "load_world_meta returns empty for missing world")

	# Test delete_world
	var deleted = save_mgr.delete_world(test_world)
	_assert_true(deleted, "delete_world returns true")
	_assert_true(not save_mgr.has_saved_chunk(test_world, Vector2i(5, -3)), "Chunk gone after delete_world")
	var deleted_meta = save_mgr.load_world_meta(test_world)
	_assert_true(deleted_meta.is_empty(), "Metadata gone after delete_world")

	# Test delete_world on nonexistent world returns true
	_assert_true(save_mgr.delete_world("_nonexistent_world_xyz"), "delete_world on missing world returns true")

	print("")


# ─── Camera Controller Tests ─────────────────────────────────────────

func _test_camera_controller() -> void:
	print("--- CameraController ---")

	# Test instantiation
	var cam = CameraController.new()
	_assert_true(cam is Camera2D, "CameraController extends Camera2D")

	# Test default values
	_assert_eq(cam.smoothing, 10.0, "Default smoothing is 10.0")
	_assert_eq(cam.zoom_presets.size(), 4, "Default zoom_presets has 4 entries")
	_assert_eq(cam.zoom_presets[0], 1.0, "First zoom preset is 1x")
	_assert_eq(cam.zoom_presets[1], 2.0, "Second zoom preset is 2x")
	_assert_eq(cam.zoom_presets[2], 4.0, "Third zoom preset is 4x")
	_assert_eq(cam.zoom_presets[3], 8.0, "Fourth zoom preset is 8x")
	_assert_eq(cam.zoom_step, 0.1, "Default zoom_step is 0.1")

	# Test zoom preset cycling
	cam._current_preset_index = 2 # Start at 4x
	cam._cycle_zoom_preset()
	_assert_eq(cam.zoom, Vector2(8, 8), "After one cycle: zoom is 8x")
	cam._cycle_zoom_preset()
	_assert_eq(cam.zoom, Vector2(1, 1), "After two cycles: zoom wraps to 1x")

	cam.queue_free()
	print("")


# ─── Entity System Tests ─────────────────────────────────────────────

func _test_entity_system() -> void:
	print("--- Entity System ---")

	# Test BaseEntity defaults
	var entity = BaseEntity.new()
	_assert_true(entity is Node2D, "BaseEntity extends Node2D")
	_assert_eq(entity.velocity, Vector2.ZERO, "BaseEntity default velocity is ZERO")
	_assert_eq(entity.entity_id, -1, "BaseEntity default entity_id is -1")
	_assert_eq(entity.collision_box_size, Vector2(10, 16), "BaseEntity default collision_box_size")
	_assert_eq(entity._get_movement_input(), Vector2.ZERO, "BaseEntity default movement input is ZERO")

	# Test EntityManager spawn/despawn
	var mgr = EntityManager.new()
	add_child(mgr) # Must be in tree to add children

	var e1 = BaseEntity.new()
	var e2 = BaseEntity.new()

	# Track signals
	var spawned_entities = []
	var despawned_entities = []
	var spawn_handler = func(e): spawned_entities.append(e)
	var despawn_handler = func(e): despawned_entities.append(e)
	SignalBus.entity_spawned.connect(spawn_handler)
	SignalBus.entity_despawned.connect(despawn_handler)

	var id1 = mgr.spawn(e1)
	var id2 = mgr.spawn(e2)

	_assert_eq(id1, 1, "First entity gets ID 1")
	_assert_eq(id2, 2, "Second entity gets ID 2")
	_assert_eq(e1.entity_id, 1, "Entity 1 has correct entity_id")
	_assert_eq(e2.entity_id, 2, "Entity 2 has correct entity_id")
	_assert_eq(mgr.get_entity_count(), 2, "EntityManager has 2 entities")
	_assert_true(mgr.get_entity(1) == e1, "get_entity returns correct entity")
	_assert_eq(spawned_entities.size(), 2, "entity_spawned emitted twice")

	# Test monotonic IDs
	_assert_true(id2 > id1, "Entity IDs are monotonically increasing")

	# Test despawn
	mgr.despawn(id1)
	_assert_eq(mgr.get_entity_count(), 1, "EntityManager has 1 entity after despawn")
	_assert_true(mgr.get_entity(id1) == null, "Despawned entity is null")
	_assert_eq(despawned_entities.size(), 1, "entity_despawned emitted once")

	# Test debug info
	var debug = mgr.get_debug_info()
	_assert_eq(debug["entity_count"], 1, "Debug info entity_count is 1")
	_assert_eq(debug["next_id"], 3, "Debug info next_id is 3")

	# Test despawn of nonexistent ID (should not error)
	mgr.despawn(999)
	_assert_eq(mgr.get_entity_count(), 1, "Despawn of nonexistent ID has no effect")

	# Cleanup
	SignalBus.entity_spawned.disconnect(spawn_handler)
	SignalBus.entity_despawned.disconnect(despawn_handler)
	mgr.queue_free()
	entity.queue_free()

	print("")


# ─── Signal Bus Tests ────────────────────────────────────────────────

func _test_signal_bus() -> void:
	print("--- SignalBus ---")

	# Verify all expected signals exist on SignalBus
	_assert_true(SignalBus.has_signal("player_chunk_changed"), "SignalBus has player_chunk_changed")
	_assert_true(SignalBus.has_signal("tile_changed"), "SignalBus has tile_changed")
	_assert_true(SignalBus.has_signal("chunk_loaded"), "SignalBus has chunk_loaded")
	_assert_true(SignalBus.has_signal("chunk_unloaded"), "SignalBus has chunk_unloaded")
	_assert_true(SignalBus.has_signal("world_ready"), "SignalBus has world_ready")
	_assert_true(SignalBus.has_signal("world_saving"), "SignalBus has world_saving")
	_assert_true(SignalBus.has_signal("world_saved"), "SignalBus has world_saved")
	_assert_true(SignalBus.has_signal("entity_spawned"), "SignalBus has entity_spawned")
	_assert_true(SignalBus.has_signal("entity_despawned"), "SignalBus has entity_despawned")
	_assert_true(SignalBus.has_signal("entity_damaged"), "SignalBus has entity_damaged")
	_assert_true(SignalBus.has_signal("entity_died"), "SignalBus has entity_died")
	_assert_true(SignalBus.has_signal("entity_healed"), "SignalBus has entity_healed")

	# Test signal emission and reception for tile_changed
	var received_args = []
	var handler = func(pos, old_id, new_id): received_args.append([pos, old_id, new_id])
	SignalBus.tile_changed.connect(handler)
	SignalBus.tile_changed.emit(Vector2(10, 20), TileIndex.AIR, TileIndex.DIRT)
	_assert_eq(received_args.size(), 1, "tile_changed signal received once")
	_assert_eq(received_args[0][1], TileIndex.AIR, "tile_changed old_tile_id is AIR")
	_assert_eq(received_args[0][2], TileIndex.DIRT, "tile_changed new_tile_id is DIRT")
	SignalBus.tile_changed.disconnect(handler)

	# Test chunk_loaded signal
	var loaded_chunks = []
	var load_handler = func(pos): loaded_chunks.append(pos)
	SignalBus.chunk_loaded.connect(load_handler)
	SignalBus.chunk_loaded.emit(Vector2i(3, 7))
	_assert_eq(loaded_chunks.size(), 1, "chunk_loaded signal received once")
	_assert_eq(loaded_chunks[0], Vector2i(3, 7), "chunk_loaded position is correct")
	SignalBus.chunk_loaded.disconnect(load_handler)

	print("")


# ─── Test Helpers ─────────────────────────────────────────────────────

func _assert_eq(actual, expected, description: String) -> void:
	if actual == expected:
		_passed += 1
		print("  PASS: %s" % description)
	else:
		_failed += 1
		var msg = "  FAIL: %s (expected %s, got %s)" % [description, str(expected), str(actual)]
		print(msg)
		_errors.append(msg)


func _assert_true(condition: bool, description: String) -> void:
	if condition:
		_passed += 1
		print("  PASS: %s" % description)
	else:
		_failed += 1
		var msg = "  FAIL: %s" % description
		print(msg)
		_errors.append(msg)


func _print_results() -> void:
	print("\n========================================")
	print("  Results: %d passed, %d failed" % [_passed, _failed])
	print("========================================")
	if _failed > 0:
		print("\nFailed tests:")
		for err in _errors:
			print(err)
	print("")
