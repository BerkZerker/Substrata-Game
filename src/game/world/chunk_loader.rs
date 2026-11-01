use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use glam::IVec2;

use crate::game::settings::{MAX_BUILD_QUEUE_SIZE, MAX_CONCURRENT_GENERATION_TASKS};
use crate::game::world::generator::BaseTerrainGenerator;

#[derive(Clone, Debug)]
pub struct BuiltChunkData {
    pub pos: IVec2,
    pub terrain_data: Vec<u8>,
}

#[derive(Clone, Debug, Default)]
pub struct ChunkLoaderDebugInfo {
    pub generation_queue: Vec<IVec2>,
    pub generation_queue_size: usize,
    pub build_queue_size: usize,
    pub in_progress: Vec<IVec2>,
    pub in_progress_size: usize,
    pub active_tasks: usize,
}

struct LoaderSharedState {
    generation_queue: VecDeque<IVec2>,
    generation_queue_set: HashSet<IVec2>,
    build_queue: VecDeque<BuiltChunkData>,
    chunks_in_progress: HashSet<IVec2>,
    player_chunk_for_priority: IVec2,
    shutdown_requested: bool,
    generation_paused: bool,
    active_task_count: usize,
}

/// Parallel chunk generation scheduler ported from `src/world/chunks/chunk_loader.gd`.
/// Runs up to `MAX_CONCURRENT_GENERATION_TASKS` (8) worker threads with priority
/// sorting by player distance and backpressure when `build_queue` reaches 128.
pub struct ChunkLoader {
    shared: Arc<(Mutex<LoaderSharedState>, Condvar)>,
    workers: Vec<JoinHandle<()>>,
}

impl ChunkLoader {
    pub fn new(terrain_generator: Arc<dyn BaseTerrainGenerator>) -> Self {
        let state = LoaderSharedState {
            generation_queue: VecDeque::new(),
            generation_queue_set: HashSet::new(),
            build_queue: VecDeque::new(),
            chunks_in_progress: HashSet::new(),
            player_chunk_for_priority: IVec2::ZERO,
            shutdown_requested: false,
            generation_paused: false,
            active_task_count: 0,
        };
        let shared = Arc::new((Mutex::new(state), Condvar::new()));

        let mut workers = Vec::with_capacity(MAX_CONCURRENT_GENERATION_TASKS);
        for worker_idx in 0..MAX_CONCURRENT_GENERATION_TASKS {
            let shared_clone = Arc::clone(&shared);
            let gen_clone = Arc::clone(&terrain_generator);
            let handle = thread::Builder::new()
                .name(format!("chunk-worker-{worker_idx}"))
                .spawn(move || Self::worker_loop(shared_clone, gen_clone))
                .expect("Failed to spawn chunk loader worker thread");
            workers.push(handle);
        }

        Self { shared, workers }
    }

    fn worker_loop(
        shared: Arc<(Mutex<LoaderSharedState>, Condvar)>,
        generator: Arc<dyn BaseTerrainGenerator>,
    ) {
        let (lock, cvar) = &*shared;
        loop {
            let next_pos = {
                let mut state = lock.lock().unwrap();
                loop {
                    if state.shutdown_requested {
                        return;
                    }
                    if !state.generation_paused {
                        if let Some(pos) = state.generation_queue.pop_front() {
                            state.generation_queue_set.remove(&pos);
                            if !state.chunks_in_progress.contains(&pos) {
                                state.chunks_in_progress.insert(pos);
                                state.active_task_count += 1;
                                break pos;
                            }
                            continue;
                        }
                    }
                    state = cvar.wait(state).unwrap();
                }
            };

            let terrain_data = generator.generate_chunk(next_pos);

            {
                let mut state = lock.lock().unwrap();
                state.active_task_count = state.active_task_count.saturating_sub(1);
                if state.shutdown_requested {
                    state.chunks_in_progress.remove(&next_pos);
                    cvar.notify_all();
                    return;
                }

                state.build_queue.push_back(BuiltChunkData {
                    pos: next_pos,
                    terrain_data,
                });

                if state.build_queue.len() >= MAX_BUILD_QUEUE_SIZE {
                    state.generation_paused = true;
                }
            }
        }
    }

    pub fn add_chunks_to_generation(&self, new_chunks: &[IVec2], player_chunk: IVec2) {
        if new_chunks.is_empty() {
            return;
        }

        let (lock, cvar) = &*self.shared;
        let mut state = lock.lock().unwrap();

        let mut added = false;
        for &pos in new_chunks {
            if !state.generation_queue_set.contains(&pos)
                && !state.chunks_in_progress.contains(&pos)
            {
                state.generation_queue.push_front(pos);
                state.generation_queue_set.insert(pos);
                added = true;
            }
        }

        if added {
            state.player_chunk_for_priority = player_chunk;
            let mut vec: Vec<IVec2> = state.generation_queue.drain(..).collect();
            vec.sort_by_key(|&a| (a - player_chunk).length_squared());
            state.generation_queue = vec.into();
            cvar.notify_all();
        }
    }

    pub fn get_built_chunks(&self, limit: usize) -> Vec<BuiltChunkData> {
        let (lock, cvar) = &*self.shared;
        let mut state = lock.lock().unwrap();

        let batch_size = state.build_queue.len().min(limit);
        let mut batch = Vec::with_capacity(batch_size);
        for _ in 0..batch_size {
            if let Some(item) = state.build_queue.pop_front() {
                batch.push(item);
            }
        }

        if state.generation_paused && state.build_queue.len() < MAX_BUILD_QUEUE_SIZE / 2 {
            state.generation_paused = false;
            cvar.notify_all();
        }

        batch
    }

    pub fn mark_chunks_as_processed(&self, chunk_positions: &[IVec2]) {
        if chunk_positions.is_empty() {
            return;
        }
        let (lock, _) = &*self.shared;
        let mut state = lock.lock().unwrap();
        for pos in chunk_positions {
            state.chunks_in_progress.remove(pos);
        }
    }

    pub fn resort_queues(&self, player_chunk: IVec2) {
        let (lock, _) = &*self.shared;
        let mut state = lock.lock().unwrap();
        state.player_chunk_for_priority = player_chunk;

        if state.generation_queue.len() >= 2 {
            let mut vec: Vec<IVec2> = state.generation_queue.drain(..).collect();
            vec.sort_by_key(|&a| (a - player_chunk).length_squared());
            state.generation_queue = vec.into();
        }

        if state.build_queue.len() >= 2 {
            let mut vec: Vec<BuiltChunkData> = state.build_queue.drain(..).collect();
            vec.sort_by_key(|a| (a.pos - player_chunk).length_squared());
            state.build_queue = vec.into();
        }
    }

    pub fn get_debug_info(&self) -> ChunkLoaderDebugInfo {
        let (lock, _) = &*self.shared;
        let state = lock.lock().unwrap();
        ChunkLoaderDebugInfo {
            generation_queue: state.generation_queue.iter().copied().collect(),
            generation_queue_size: state.generation_queue.len(),
            build_queue_size: state.build_queue.len(),
            in_progress: state.chunks_in_progress.iter().copied().collect(),
            in_progress_size: state.chunks_in_progress.len(),
            active_tasks: state.active_task_count,
        }
    }

    pub fn stop(&mut self) {
        let (lock, cvar) = &*self.shared;
        {
            let mut state = lock.lock().unwrap();
            state.shutdown_requested = true;
            state.generation_paused = false;
            state.generation_queue.clear();
            state.generation_queue_set.clear();
            state.build_queue.clear();
            cvar.notify_all();
        }

        let start = Instant::now();
        while start.elapsed() < Duration::from_millis(2000) {
            let remaining = lock.lock().unwrap().active_task_count;
            if remaining == 0 {
                break;
            }
            thread::sleep(Duration::from_millis(1));
        }

        for handle in self.workers.drain(..) {
            let _ = handle.join();
        }

        lock.lock().unwrap().chunks_in_progress.clear();
    }
}

impl Drop for ChunkLoader {
    fn drop(&mut self) {
        self.stop();
    }
}
