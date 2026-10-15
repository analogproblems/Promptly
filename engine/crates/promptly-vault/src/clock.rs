//! Logical time, as specified in VAULT.md section 6.
//!
//! A [`Timestamp`] is a Lamport counter plus the id of the device that produced
//! it. The device id breaks ties, so every timestamp in a vault is unique and
//! ordering is total: merge rules can always say "higher wins".

use serde::{Deserialize, Serialize};
use std::fmt;

/// 16 random bytes, hex encoded, chosen once when a device enrols.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DeviceId(String);

impl DeviceId {
    /// A fresh random id.
    pub fn generate() -> Self {
        let bytes = uuid::Uuid::new_v4().into_bytes();
        Self(bytes.iter().map(|b| format!("{b:02x}")).collect())
    }

    /// Wrap an id read from the vault. Accepts only lower-case hex of the
    /// right length so a malformed folder name cannot become a device.
    pub fn parse(s: &str) -> Option<Self> {
        (s.len() == 32 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')))
            .then(|| Self(s.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "DeviceId({}…)", &self.0[..6])
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// A Lamport timestamp with a device tiebreak. Serialises as `[counter, device]`.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Timestamp(pub u64, pub DeviceId);

impl Timestamp {
    pub fn counter(&self) -> u64 {
        self.0
    }
    pub fn device(&self) -> &DeviceId {
        &self.1
    }
}

/// One device's clock. See VAULT.md "Logical clock rules".
#[derive(Debug, Clone)]
pub struct Clock {
    device: DeviceId,
    counter: u64,
}

impl Clock {
    pub fn new(device: DeviceId) -> Self {
        Self { device, counter: 0 }
    }

    /// Resume a clock from a persisted counter.
    pub fn resume(device: DeviceId, counter: u64) -> Self {
        Self { device, counter }
    }

    pub fn device(&self) -> &DeviceId {
        &self.device
    }

    pub fn counter(&self) -> u64 {
        self.counter
    }

    /// Produce the timestamp for a new local operation.
    pub fn tick(&mut self) -> Timestamp {
        self.counter += 1;
        Timestamp(self.counter, self.device.clone())
    }

    /// Fold in a timestamp read from any device, so later local edits sort
    /// after everything this device has seen.
    pub fn observe(&mut self, seen: &Timestamp) {
        self.counter = self.counter.max(seen.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dev(c: char) -> DeviceId {
        DeviceId::parse(&std::iter::repeat_n(c, 32).collect::<String>()).unwrap()
    }

    #[test]
    fn ids_are_validated() {
        assert!(DeviceId::parse("abc").is_none());
        assert!(DeviceId::parse(&"G".repeat(32)).is_none());
        assert!(DeviceId::parse(&"a".repeat(32)).is_some());
        assert!(DeviceId::parse(DeviceId::generate().as_str()).is_some());
    }

    #[test]
    fn ticks_increase_and_observe_catches_up() {
        let mut a = Clock::new(dev('a'));
        let mut b = Clock::new(dev('b'));
        let t1 = a.tick();
        let t2 = a.tick();
        assert!(t2 > t1);
        b.observe(&t2);
        let t3 = b.tick();
        assert!(t3 > t2, "an edit made after seeing t2 must sort after it");
        assert_eq!(t3.counter(), 3);
    }

    #[test]
    fn same_counter_breaks_ties_by_device() {
        let ta = Timestamp(5, dev('a'));
        let tb = Timestamp(5, dev('b'));
        assert!(tb > ta);
        assert_ne!(ta, tb);
    }

    #[test]
    fn serialises_as_a_pair() {
        let t = Timestamp(812, dev('7'));
        let json = serde_json::to_string(&t).unwrap();
        assert_eq!(json, format!("[812,\"{}\"]", "7".repeat(32)));
        let back: Timestamp = serde_json::from_str(&json).unwrap();
        assert_eq!(back, t);
    }
}
