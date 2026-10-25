package backupcodec

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"testing"

	"github.com/ulikunitz/xz"
)

const password = "example-password-123"

func TestXZRoundTrip(t *testing.T) {
	for _, data := range [][]byte{nil, []byte("hello"), bytes.Repeat([]byte("proxy-rule: example.com\n"), 150000)} {
		packed, err := Compress(data)
		if err != nil {
			t.Fatal(err)
		}
		restored, err := Decompress(packed)
		if err != nil || !bytes.Equal(restored, data) {
			t.Fatalf("round trip: %v", err)
		}
		if len(data) > 10000 && len(packed) >= len(data)/10 {
			t.Fatal("compression ineffective")
		}
		if len(data) > 0 {
			if _, err = decompress(packed, int64(len(data)-1)); err != errTooLarge {
				t.Fatalf("expansion limit: %v", err)
			}
		}
		packed[8] ^= 1
		if _, err = Decompress(packed); err != errInvalid {
			t.Fatalf("checksum: %v", err)
		}
	}
}

func TestReferenceXZ(t *testing.T) {
	data, _ := base64.StdEncoding.DecodeString("/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4AIbACRdACMbBGbnKW+r+kmXGQ4tFXwSXgKUJbz5Pu5lbaKuwmWkzsoAAAAbnc0CT8kyZAABQJwEAAAA94OZV7HEZ/sCAAAAAARZWg==")
	decoded, err := Decompress(data)
	if err != nil || !bytes.Equal(decoded, bytes.Repeat([]byte("FlClashX reference fixture\n"), 20)) {
		t.Fatalf("reference: %v", err)
	}
	if _, err = Decompress(append(data, data...)); err != errInvalid {
		t.Fatalf("concatenated streams: %v", err)
	}
	if _, err = Decompress(data[:len(data)-1]); err == nil {
		t.Fatal("accepted truncated XZ")
	}
	data[16] = 40
	if _, err = Decompress(data); err != errTooLarge {
		t.Fatalf("dictionary cap: %v", err)
	}
	if _, err = Decompress([]byte("PK\x03\x04")); err != errInvalid {
		t.Fatal("ZIP accepted")
	}
}

func TestMultipleBlocks(t *testing.T) {
	data := bytes.Repeat([]byte("abcd"), 1000)
	var output bytes.Buffer
	writer, err := (xz.WriterConfig{BlockSize: 512}).NewWriter(&output)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = writer.Write(data); err != nil {
		t.Fatal(err)
	}
	if err = writer.Close(); err != nil {
		t.Fatal(err)
	}
	decoded, err := Decompress(output.Bytes())
	if err != nil || !bytes.Equal(decoded, data) {
		t.Fatalf("multi-block: %v", err)
	}
}

func TestEncryptedEnvelope(t *testing.T) {
	data := []byte{1, 2, 3}
	encrypted, err := Encrypt(data, password)
	if err != nil {
		t.Fatal(err)
	}
	result, err := Decrypt(encrypted, password)
	if err != nil || !bytes.Equal(result, data) {
		t.Fatalf("decrypt: %v", err)
	}
	other, err := Encrypt(data, password)
	if err != nil || bytes.Equal(encrypted, other) {
		t.Fatal("salt/nonce reused")
	}
	if _, err = Decrypt(encrypted, "incorrect-password"); err != errDecryption {
		t.Fatalf("wrong password: %v", err)
	}
	var e envelope
	if err = json.Unmarshal(encrypted, &e); err != nil {
		t.Fatal(err)
	}
	e.MAC[0] ^= 1
	corrupt, _ := json.Marshal(e)
	if _, err = Decrypt(corrupt, password); err != errDecryption {
		t.Fatalf("tampering: %v", err)
	}
	e.Iterations++
	corrupt, _ = json.Marshal(e)
	if _, err = Decrypt(corrupt, password); err != errInvalid {
		t.Fatalf("KDF metadata: %v", err)
	}
	if _, err = Encrypt(data, "short"); err != errPassword {
		t.Fatal("weak password accepted")
	}
	if _, err = Encrypt(make([]byte, MaxEncryptedBytes+1), password); err != errTooLarge {
		t.Fatal("oversize accepted")
	}
	if _, err = Decrypt(encrypted, ""); err != errPassword {
		t.Fatal("empty password accepted")
	}
}

func TestProtocol(t *testing.T) {
	request, _ := json.Marshal(Request{Version: 1, Operation: "compress", Data: []byte("hello")})
	var output bytes.Buffer
	if err := Serve(bytes.NewReader(request), &output); err != nil {
		t.Fatal(err)
	}
	var response Response
	if err := json.Unmarshal(output.Bytes(), &response); err != nil || response.Error != "" {
		t.Fatalf("response: %v", err)
	}
	result, err := Decompress(response.Data)
	if err != nil || string(result) != "hello" {
		t.Fatalf("protocol data: %v", err)
	}
	for _, request := range []string{`{`, `{"version":2,"operation":"compress"}`, `{"version":1,"operation":"unknown"}`} {
		result := Handle([]byte(request))
		if string(result) != `{"error":"invalidBackup"}` {
			t.Fatalf("invalid request: %s", result)
		}
	}
}

func FuzzDecompress(f *testing.F) {
	packed, _ := Compress([]byte("test"))
	f.Add(packed)
	f.Add([]byte("invalid"))
	f.Fuzz(func(t *testing.T, data []byte) { _, _ = decompress(data, 1<<20) })
}

func TestReferenceEncryptedEnvelope(t *testing.T) {
	fixture := `{"salt":"AAECAwQFBgcICQoLDA0ODw==","nonce":"EBESExQVFhcYGRob","compression":"tar+xz","app":"FlClashX","schema":2,"iterations":600000,"ciphertext":"0Z7sVm7ocoS5eVlrKIQMJZYJ96KSLg==","kdf":"PBKDF2-SHA256","mac":"bIwH30eBbF60CsDN8Mda0A==","cipher":"AES-256-GCM"}`
	data, err := Decrypt([]byte(fixture), password)
	if err != nil || string(data) != "cross-platform fixture" {
		t.Fatalf("reference encryption: %v", err)
	}
}
