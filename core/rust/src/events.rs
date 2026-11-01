use parking_lot::Mutex;
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    sync::atomic::{AtomicBool, Ordering},
};

#[derive(Default)]
pub struct Events {
    queues: Mutex<Queues>,
    pub enabled: AtomicBool,
    pub logs: AtomicBool,
}

#[derive(Default)]
struct Queues {
    state: VecDeque<Value>,
    priority: VecDeque<Value>,
    bulk: VecDeque<Value>,
    priority_run: usize,
}

impl Events {
    pub fn push(&self, kind: &str, data: Value) {
        if !self.enabled.load(Ordering::Relaxed) {
            return;
        }
        let mut queues = self.queues.lock();
        let (queue, evict) = match kind {
            "loaded" | "geoUpdate" | "routeChanged" => (&mut queues.state, false),
            "dns" | "requestTraffic" => (&mut queues.bulk, false),
            "log" | "request" => (&mut queues.bulk, true),
            _ => (&mut queues.priority, true),
        };
        if queue.len() == 256 {
            if evict {
                queue.pop_front();
            } else {
                return;
            }
        }
        queue.push_back(json!({"type": kind, "data": data}));
    }

    pub fn batch(&self) -> Option<Vec<u8>> {
        let mut queues = self.queues.lock();
        let mut messages = Vec::new();
        for _ in 0..32 {
            let next = if let Some(event) = queues.state.pop_front() {
                Some(event)
            } else if queues.priority_run >= 8 && !queues.bulk.is_empty() {
                queues.priority_run = 0;
                queues.bulk.pop_front()
            } else if let Some(event) = queues.priority.pop_front() {
                queues.priority_run += 1;
                Some(event)
            } else {
                queues.priority_run = 0;
                queues.bulk.pop_front()
            };
            if let Some(event) = next {
                messages.push(event);
            } else {
                break;
            }
        }
        if messages.is_empty() {
            None
        } else {
            serde_json::to_vec(&json!({"method":"message", "arguments":messages})).ok()
        }
    }

    pub fn clear(&self) {
        *self.queues.lock() = Queues::default();
    }
}
