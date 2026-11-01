pub mod player;

use std::collections::BTreeMap;
use glam::Vec2;

use crate::game::physics::movement::MovementController;
use crate::game::signals::{GameSignal, SignalBus};
use crate::game::tiles::TileRegistry;
use crate::game::world::chunk_manager::ChunkManager;

/// Base entity state ported from `src/entities/base_entity.gd`.
pub struct BaseEntity {
    pub entity_id: u64,
    pub position: Vec2,
    pub velocity: Vec2,
    pub collision_box_size: Vec2,
    pub movement: Option<MovementController>,
    pub move_input: Vec2,
}

impl BaseEntity {
    pub fn new(position: Vec2) -> Self {
        Self {
            entity_id: 0,
            position,
            velocity: Vec2::ZERO,
            collision_box_size: Vec2::new(10.0, 16.0),
            movement: None,
            move_input: Vec2::ZERO,
        }
    }

    pub fn setup_movement(&mut self) {
        let mut ctrl = MovementController::new();
        ctrl.collision_box_size = self.collision_box_size;
        self.movement = Some(ctrl);
    }

    pub fn entity_process(
        &mut self,
        delta: f32,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
    ) {
        if let Some(movement) = &mut self.movement {
            self.position = movement.move_body(
                self.position,
                self.move_input.x,
                self.move_input.y > 0.0,
                delta,
                chunk_manager,
                tile_registry,
            );
            self.velocity = movement.velocity;
        }
    }
}

/// Manages entity lifecycle (`src/entities/entity_manager.gd`).
pub struct EntityManager {
    entities: BTreeMap<u64, BaseEntity>,
    next_id: u64,
}

impl Default for EntityManager {
    fn default() -> Self {
        Self::new()
    }
}

impl EntityManager {
    pub fn new() -> Self {
        Self {
            entities: BTreeMap::new(),
            next_id: 1,
        }
    }

    pub fn physics_process(
        &mut self,
        delta: f32,
        chunk_manager: &ChunkManager,
        tile_registry: &TileRegistry,
    ) {
        for entity in self.entities.values_mut() {
            entity.entity_process(delta, chunk_manager, tile_registry);
        }
    }

    pub fn spawn(&mut self, mut entity: BaseEntity, signal_bus: &mut SignalBus) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        entity.entity_id = id;
        self.entities.insert(id, entity);
        signal_bus.emit(GameSignal::EntitySpawned(id));
        id
    }

    pub fn despawn(&mut self, id: u64, signal_bus: &mut SignalBus) {
        if self.entities.remove(&id).is_some() {
            signal_bus.emit(GameSignal::EntityDespawned(id));
        }
    }

    pub fn get_entity(&self, id: u64) -> Option<&BaseEntity> {
        self.entities.get(&id)
    }

    pub fn get_entity_count(&self) -> usize {
        self.entities.len()
    }
}
