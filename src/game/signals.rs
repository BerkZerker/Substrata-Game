use glam::{IVec2, Vec2};

/// Events corresponding to Godot's `SignalBus` (`src/globals/signal_bus.gd`).
#[derive(Clone, Debug)]
pub enum GameSignal {
    PlayerChunkChanged(IVec2),
    ChunkLoaded(IVec2),
    ChunkUnloaded(IVec2),
    WorldReady,
    WorldSaving,
    WorldSaved,
    TileChanged {
        world_pos: Vec2,
        old_tile_id: u8,
        new_tile_id: u8,
    },
    MaterialSelected(u8),
    BrushValueChanged(f32),
    EntitySpawned(u64),
    EntityDespawned(u64),
}

#[derive(Default)]
pub struct SignalBus {
    queue: Vec<GameSignal>,
}

impl SignalBus {
    pub fn new() -> Self {
        Self {
            queue: Vec::with_capacity(64),
        }
    }

    pub fn emit(&mut self, signal: GameSignal) {
        self.queue.push(signal);
    }

    pub fn drain(&mut self) -> Vec<GameSignal> {
        std::mem::take(&mut self.queue)
    }
}
