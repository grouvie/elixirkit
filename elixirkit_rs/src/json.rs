use std::fmt;

use serde::de::{self, IgnoredAny, MapAccess, Visitor};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Shared helper for capability payloads that should encode as an empty JSON
/// object (`{}`) and reject any non-empty object or non-object input.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct EmptyJsonObject;

impl Serialize for EmptyJsonObject {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let map = serializer.serialize_map(Some(0))?;
        map.end()
    }
}

impl<'de> Deserialize<'de> for EmptyJsonObject {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_map(EmptyJsonObjectVisitor)
    }
}

struct EmptyJsonObjectVisitor;

impl<'de> Visitor<'de> for EmptyJsonObjectVisitor {
    type Value = EmptyJsonObject;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("an empty JSON object")
    }

    fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        if map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {
            return Err(de::Error::custom("expected an empty JSON object"));
        }

        Ok(EmptyJsonObject)
    }
}
