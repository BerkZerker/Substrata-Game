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

	_test_tile_registry()
	_test_base_terrain_generator()
	_test_simplex_terrain_generator()
	_test_chunk_data_format()
	_test_world_save_manager()
	_test_signal_bus()

	_print_results()

	# Exit with appropriate code
	get_tree().quit(1 if _failed > 0 else 0)


# ─── Tile Registry Tests ─────────────────────────────────────────────

func _test_tile_registry() -> void:
	print("--- TileIndex (Tile Registry) ---")

	# Test backward-compatible constants
	_assert_eq(TileIndex.AIR, 0, "AIR constant is 0")
	_assert_eq(TileIndex.DIRT, 1, "DIRT constant is 1")
	_assert_eq(TileIndex.GRASS, 2, "GRASS constant is 2")
	_assert_eq(TileIndex.STONE, 3, "STONE constant is 3")

	# Test tile count (4 default tiles)
	_assert_eq(TileIndex.get_tile_count(), 4, "Default tile count is 4")

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
	_assert_eq(ids.size(), 4, "get_tile_ids returns 4 IDs")
	_assert_eq(ids[0], 0, "First tile ID is 0")
	_assert_eq(ids[3], 3, "Last tile ID is 3")

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

	# Test dynamic registration
	TileIndex.register_tile(4, "Sand", true, "", Color(0.9, 0.8, 0.5))
	_assert_eq(TileIndex.get_tile_count(), 5, "Tile count after registering Sand is 5")
	_assert_eq(TileIndex.get_tile_name(4), "Sand", "Sand name is correct")
	_assert_eq(TileIndex.is_solid(4), true, "Sand is solid")

	# Clean up: remove test tile (restore original state for other tests)
	TileIndex._tiles.erase(4)

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
