use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const MAX_FRAME: usize = 64 * 1024 * 1024;
pub const SPILL_THRESHOLD: usize = 1024 * 1024;

#[derive(Debug, Deserialize)]
pub struct Call {
    #[serde(default)]
    pub id: Option<String>,
    pub method: String,
    #[serde(default)]
    pub arguments: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MethodError {
    pub code: String,
    pub message: String,
    pub details: Value,
}

impl MethodError {
    pub fn new(code: &str, message: impl ToString) -> Self {
        Self {
            code: code.into(),
            message: message.to_string(),
            details: Value::Null,
        }
    }

    pub fn details(mut self, details: Value) -> Self {
        self.details = details;
        self
    }
}

impl std::fmt::Display for MethodError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for MethodError {}

impl From<anyhow::Error> for MethodError {
    fn from(error: anyhow::Error) -> Self {
        Self::new("core_error", format!("{error:#}"))
    }
}

pub type Result<T> = std::result::Result<T, MethodError>;

#[derive(Serialize)]
pub struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub result: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<MethodError>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

pub fn string(value: &Value) -> Result<&str> {
    value
        .as_str()
        .ok_or_else(|| MethodError::new("invalid_arguments", "Expected a string"))
}

pub fn field<'a>(value: &'a Value, name: &str) -> Result<&'a str> {
    value.get(name).and_then(Value::as_str).ok_or_else(|| {
        MethodError::new("invalid_arguments", format!("Expected string field {name}"))
    })
}

pub fn list(value: &Value) -> Result<&Vec<Value>> {
    value
        .as_array()
        .ok_or_else(|| MethodError::new("invalid_arguments", "Expected a list"))
}

pub fn object(value: &Value) -> Result<&serde_json::Map<String, Value>> {
    value
        .as_object()
        .ok_or_else(|| MethodError::new("invalid_arguments", "Expected an object"))
}

pub fn message_method(method: &str) -> bool {
    matches!(
        method,
        "validateConfig"
            | "setupConfig"
            | "updateConfig"
            | "sideLoadExternalProvider"
            | "updateExternalProvider"
            | "updateGeoData"
            | "clearEffect"
    )
}

pub fn encode(response: Response) -> Vec<u8> {
    serde_json::to_vec(&response).unwrap_or_else(|_| b"{\"result\":null,\"error\":{\"code\":\"internal_error\",\"message\":\"Response encoding failed\",\"details\":null}}".to_vec())
}
