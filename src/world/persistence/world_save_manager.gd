## Manages saving and loading world data to disk.
##
## Handles world metadata (seed, generator config, timestamps) stored as JSON,
## and individual chunk terrain data stored as raw PackedByteArray files.
## Called from the main thread only — no internal mutex needed.
##
## Save directory layout:
##   res://data/
##     {world_name}/
##       world_meta.json
##       chunks/
##         chunk_0_0.dat
##         chunk_1_-2.dat
class_name WorldSaveManager extends RefCounted

const SAVE_FORMAT_VERSION: int = 1
const WORLDS_BASE_PATH: String = "res://data/"


# ─── Path Helpers ────────────────────────────────────────────────────────────


func _get_world_dir(world_name: String) -> String:
	return WORLDS_BASE_PATH + world_name + "/"


func _get_chunks_dir(world_name: String) -> String:
	return _get_world_dir(world_name) + "chunks/"


func _get_meta_path(world_name: String) -> String:
	return _get_world_dir(world_name) + "world_meta.json"


func _get_chunk_path(world_name: String, chunk_pos: Vector2i) -> String:
	return _get_chunks_dir(world_name) + "chunk_%d_%d.dat" % [chunk_pos.x, chunk_pos.y]


# ─── Directory Management ────────────────────────────────────────────────────


## Ensures the world and chunks directories exist.
func _ensure_world_dirs(world_name: String) -> bool:
	var chunks_dir := _get_chunks_dir(world_name)
	if not DirAccess.dir_exists_absolute(chunks_dir):
		var err := DirAccess.make_dir_recursive_absolute(chunks_dir)
		if err != OK:
			push_error("WorldSaveManager: Failed to create directory '%s': %s" % [chunks_dir, error_string(err)])
			return false
	return true


# ─── Chunk Operations ────────────────────────────────────────────────────────


## Saves a single chunk's terrain data to disk. Returns true on success.
func save_chunk(world_name: String, chunk_pos: Vector2i, terrain_data: PackedByteArray) -> bool:
	if terrain_data.is_empty():
		return false
	if not _ensure_world_dirs(world_name):
		return false

	var path := _get_chunk_path(world_name, chunk_pos)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("WorldSaveManager: Failed to write chunk '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return false

	file.store_buffer(terrain_data)
	file.close()
	return true


## Loads a single chunk's terrain data from disk.
## Returns empty PackedByteArray if no save exists.
func load_chunk(world_name: String, chunk_pos: Vector2i) -> PackedByteArray:
	var path := _get_chunk_path(world_name, chunk_pos)
	if not FileAccess.file_exists(path):
		return PackedByteArray()

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("WorldSaveManager: Failed to read chunk '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return PackedByteArray()

	var data := file.get_buffer(file.get_length())
	file.close()

	var expected_size := GlobalSettings.CHUNK_SIZE * GlobalSettings.CHUNK_SIZE * 2
	if data.size() != expected_size:
		push_error("WorldSaveManager: Chunk data size mismatch at '%s': got %d, expected %d" % [path, data.size(), expected_size])
		return PackedByteArray()

	return data


## Returns true if a save file exists for the given chunk position.
func has_saved_chunk(world_name: String, chunk_pos: Vector2i) -> bool:
	return FileAccess.file_exists(_get_chunk_path(world_name, chunk_pos))


# ─── Metadata Operations ─────────────────────────────────────────────────────


## Saves world metadata to world_meta.json.
## Preserves the original created_at timestamp if the file already exists.
func save_world_meta(world_name: String, seed: int, generator_name: String, generator_config: Dictionary) -> bool:
	if not _ensure_world_dirs(world_name):
		return false

	var now := _get_iso_timestamp()

	# Preserve created_at from existing metadata
	var created_at := now
	var existing := load_world_meta(world_name)
	if not existing.is_empty() and existing.has("created_at"):
		created_at = existing["created_at"]

	var meta := {
		"world_seed": seed,
		"generator_name": generator_name,
		"generator_config": generator_config,
		"version": SAVE_FORMAT_VERSION,
		"created_at": created_at,
		"last_saved_at": now,
	}

	var json_string := JSON.stringify(meta, "\t")
	var path := _get_meta_path(world_name)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("WorldSaveManager: Failed to write meta '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return false

	file.store_string(json_string)
	file.close()
	return true


## Loads world metadata from world_meta.json.
## Returns empty Dictionary if the file doesn't exist or can't be parsed.
func load_world_meta(world_name: String) -> Dictionary:
	var path := _get_meta_path(world_name)
	if not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("WorldSaveManager: Failed to read meta '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return {}

	var json_string := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(json_string) != OK:
		push_error("WorldSaveManager: Failed to parse meta JSON '%s': %s" % [path, json.get_error_message()])
		return {}

	var data = json.get_data()
	if data is Dictionary:
		return data

	push_error("WorldSaveManager: Meta root is not a Dictionary '%s'" % path)
	return {}


# ─── World-Level Operations ──────────────────────────────────────────────────


## Lists saved world names by scanning the worlds base directory.
## Only includes directories containing a valid world_meta.json.
func list_worlds() -> Array[String]:
	var worlds: Array[String] = []
	if not DirAccess.dir_exists_absolute(WORLDS_BASE_PATH):
		return worlds

	var dir := DirAccess.open(WORLDS_BASE_PATH)
	if dir == null:
		return worlds

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and entry != "." and entry != "..":
			if FileAccess.file_exists(WORLDS_BASE_PATH + entry + "/world_meta.json"):
				worlds.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()

	worlds.sort()
	return worlds


## Deletes a world directory and all its contents.
## Returns true if deleted successfully or the world didn't exist.
func delete_world(world_name: String) -> bool:
	var world_dir := _get_world_dir(world_name)
	if not DirAccess.dir_exists_absolute(world_dir):
		return true

	# Delete chunk files
	var chunks_dir := _get_chunks_dir(world_name)
	if DirAccess.dir_exists_absolute(chunks_dir):
		if not _delete_directory_contents(chunks_dir):
			return false
		var err := DirAccess.remove_absolute(chunks_dir)
		if err != OK:
			push_error("WorldSaveManager: Failed to remove chunks dir '%s': %s" % [chunks_dir, error_string(err)])
			return false

	# Delete metadata
	var meta_path := _get_meta_path(world_name)
	if FileAccess.file_exists(meta_path):
		var err := DirAccess.remove_absolute(meta_path)
		if err != OK:
			push_error("WorldSaveManager: Failed to remove meta '%s': %s" % [meta_path, error_string(err)])
			return false

	# Delete world directory
	var err := DirAccess.remove_absolute(world_dir)
	if err != OK:
		push_error("WorldSaveManager: Failed to remove world dir '%s': %s" % [world_dir, error_string(err)])
		return false

	return true


# ─── Internal Helpers ────────────────────────────────────────────────────────


func _delete_directory_contents(dir_path: String) -> bool:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return false

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			var full_path := dir_path.path_join(entry)
			var err := DirAccess.remove_absolute(full_path)
			if err != OK:
				push_error("WorldSaveManager: Failed to remove '%s': %s" % [full_path, error_string(err)])
				dir.list_dir_end()
				return false
		entry = dir.get_next()
	dir.list_dir_end()
	return true


func _get_iso_timestamp() -> String:
	var dt := Time.get_datetime_dict_from_system(true)
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [
		dt["year"], dt["month"], dt["day"],
		dt["hour"], dt["minute"], dt["second"],
	]
