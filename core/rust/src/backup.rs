use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;
use std::io::{Read, Write};

pub const MAX_EXPANDED: usize = 128 * 1024 * 1024;
pub const MAX_WIRE: usize = 180 * 1024 * 1024;
const MAX_ENCRYPTED: usize = 5 * 1024 * 1024;
const AAD: &[u8] = b"FlClashX|2|tar+xz|AES-256-GCM|PBKDF2-SHA256|600000";

#[derive(Serialize, Deserialize)]
struct Envelope {
    app: String,
    schema: u8,
    compression: String,
    cipher: String,
    kdf: String,
    iterations: u32,
    salt: String,
    nonce: String,
    mac: String,
    ciphertext: String,
}

type Result<T> = std::result::Result<T, &'static str>;

pub fn handle(input: &[u8]) -> Vec<u8> {
    let result = std::panic::catch_unwind(|| dispatch(input));
    let value = match result {
        Ok(Ok(data)) => json!({"data": STANDARD.encode(data)}),
        Ok(Err(error)) => json!({"error": error}),
        Err(_) => json!({"error": "internal"}),
    };
    serde_json::to_vec(&value).unwrap_or_else(|_| b"{\"error\":\"internal\"}".to_vec())
}

fn dispatch(input: &[u8]) -> Result<Vec<u8>> {
    if input.len() > MAX_WIRE {
        return Err("tooLarge");
    }
    let request: Value = serde_json::from_slice(input).map_err(|_| "invalidBackup")?;
    if request["version"] != 1 {
        return Err("invalidBackup");
    }
    let data = STANDARD
        .decode(request["data"].as_str().ok_or("invalidBackup")?)
        .map_err(|_| "invalidBackup")?;
    let password = request["password"].as_str().unwrap_or("");
    match request["operation"].as_str() {
        Some("compress") => {
            if data.len() > MAX_EXPANDED {
                return Err("tooLarge");
            }
            let mut stream = xz2::write::XzEncoder::new(Vec::new(), 6);
            stream.write_all(&data).map_err(|_| "internal")?;
            stream.finish().map_err(|_| "internal")
        }
        Some("decompress") => {
            if data.len() > MAX_EXPANDED + 1024 * 1024 {
                return Err("tooLarge");
            }
            let stream = xz2::stream::Stream::new_stream_decoder(32 * 1024 * 1024, 0)
                .map_err(|_| "invalidBackup")?;
            let reader = xz2::read::XzDecoder::new_stream(&data[..], stream);
            let mut output = Vec::new();
            reader
                .take(MAX_EXPANDED as u64 + 1)
                .read_to_end(&mut output)
                .map_err(|_| "invalidBackup")?;
            if output.len() > MAX_EXPANDED {
                return Err("tooLarge");
            }
            Ok(output)
        }
        Some("encrypt") => encrypt(&data, password),
        Some("decrypt") => decrypt(&data, password),
        _ => Err("invalidBackup"),
    }
}

fn cipher(password: &str, salt: &[u8]) -> Result<Aes256Gcm> {
    let mut key = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), salt, 600_000, &mut key);
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| "internal");
    key.fill(0);
    cipher
}

fn encrypt(data: &[u8], password: &str) -> Result<Vec<u8>> {
    if data.len() > MAX_ENCRYPTED {
        return Err("tooLarge");
    }
    if !(12..=1024).contains(&password.chars().count()) {
        return Err("password");
    }
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut salt);
    rand::thread_rng().fill_bytes(&mut nonce);
    let sealed = cipher(password, &salt)?
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: data,
                aad: AAD,
            },
        )
        .map_err(|_| "internal")?;
    let split = sealed.len() - 16;
    serde_json::to_vec(&Envelope {
        app: "FlClashX".into(),
        schema: 2,
        compression: "tar+xz".into(),
        cipher: "AES-256-GCM".into(),
        kdf: "PBKDF2-SHA256".into(),
        iterations: 600_000,
        salt: STANDARD.encode(salt),
        nonce: STANDARD.encode(nonce),
        mac: STANDARD.encode(&sealed[split..]),
        ciphertext: STANDARD.encode(&sealed[..split]),
    })
    .map_err(|_| "internal")
}

fn decrypt(data: &[u8], password: &str) -> Result<Vec<u8>> {
    if data.len() > 8 * 1024 * 1024 {
        return Err("tooLarge");
    }
    let envelope: Envelope = serde_json::from_slice(data).map_err(|_| "invalidBackup")?;
    if envelope.app != "FlClashX"
        || envelope.schema != 2
        || envelope.compression != "tar+xz"
        || envelope.cipher != "AES-256-GCM"
        || envelope.kdf != "PBKDF2-SHA256"
        || envelope.iterations != 600_000
    {
        return Err("invalidBackup");
    }
    let decode = |text: &str| STANDARD.decode(text).map_err(|_| "invalidBackup");
    let salt = decode(&envelope.salt)?;
    let nonce = decode(&envelope.nonce)?;
    let mac = decode(&envelope.mac)?;
    let mut ciphertext = decode(&envelope.ciphertext)?;
    if salt.len() != 16 || nonce.len() != 12 || mac.len() != 16 {
        return Err("invalidBackup");
    }
    if ciphertext.len() > MAX_ENCRYPTED {
        return Err("tooLarge");
    }
    if password.is_empty() || password.chars().count() > 1024 {
        return Err("password");
    }
    ciphertext.extend(mac);
    cipher(password, &salt)?
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad: AAD,
            },
        )
        .map_err(|_| "decryption")
}

pub fn serve() -> std::io::Result<()> {
    let mut input = Vec::new();
    std::io::stdin()
        .take(MAX_WIRE as u64 + 1)
        .read_to_end(&mut input)?;
    std::io::stdout().write_all(&handle(&input))
}
