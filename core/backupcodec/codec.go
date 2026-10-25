package backupcodec

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"unicode/utf8"

	"github.com/ulikunitz/xz"
)

const (
	MaxExpandedBytes  = 128 << 20
	MaxEncryptedBytes = 5 << 20
	MaxEnvelopeBytes  = 8 << 20
	MaxWireBytes      = 180 << 20
	iterations        = 600000
	associatedData    = "FlClashX|2|tar+xz|AES-256-GCM|PBKDF2-SHA256|600000"
)

var (
	errInvalid    = errors.New("invalidBackup")
	errTooLarge   = errors.New("tooLarge")
	errPassword   = errors.New("password")
	errDecryption = errors.New("decryption")
)

type Request struct {
	Version   int    `json:"version"`
	Operation string `json:"operation"`
	Data      []byte `json:"data"`
	Password  string `json:"password,omitempty"`
}

type Response struct {
	Data  []byte `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
}

type envelope struct {
	App         string `json:"app"`
	Schema      int    `json:"schema"`
	Compression string `json:"compression"`
	Cipher      string `json:"cipher"`
	KDF         string `json:"kdf"`
	Iterations  int    `json:"iterations"`
	Salt        []byte `json:"salt"`
	Nonce       []byte `json:"nonce"`
	MAC         []byte `json:"mac"`
	Ciphertext  []byte `json:"ciphertext"`
}

func Compress(data []byte) ([]byte, error) {
	if len(data) > MaxExpandedBytes {
		return nil, errTooLarge
	}
	var output bytes.Buffer
	writer, err := (xz.WriterConfig{DictCap: 16 << 20}).NewWriter(&output)
	if err != nil {
		return nil, err
	}
	if _, err = writer.Write(data); err != nil {
		return nil, err
	}
	if err = writer.Close(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func Decompress(data []byte) ([]byte, error) {
	return decompress(data, MaxExpandedBytes)
}

func decompress(data []byte, limit int64) ([]byte, error) {
	if len(data) > MaxExpandedBytes+(1<<20) {
		return nil, errTooLarge
	}
	if err := validateXZLimits(data, limit); err != nil {
		return nil, err
	}
	reader, err := (xz.ReaderConfig{DictCap: 16 << 20, SingleStream: true}).NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, errInvalid
	}
	output, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if int64(len(output)) > limit {
		return nil, errTooLarge
	}
	if err != nil {
		return nil, errInvalid
	}
	return output, nil
}

func passwordCipher(password string, salt []byte) (cipher.AEAD, error) {
	key, err := pbkdf2.Key(sha256.New, password, salt, iterations, 32)
	if err != nil {
		return nil, err
	}
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func Encrypt(data []byte, password string) ([]byte, error) {
	if len(data) > MaxEncryptedBytes {
		return nil, errTooLarge
	}
	if !utf8.ValidString(password) || utf8.RuneCountInString(password) < 12 || utf8.RuneCountInString(password) > 1024 {
		return nil, errPassword
	}
	e := envelope{App: "FlClashX", Schema: 2, Compression: "tar+xz", Cipher: "AES-256-GCM", KDF: "PBKDF2-SHA256", Iterations: iterations,
		Salt: make([]byte, 16), Nonce: make([]byte, 12)}
	if _, err := rand.Read(e.Salt); err != nil {
		return nil, err
	}
	if _, err := rand.Read(e.Nonce); err != nil {
		return nil, err
	}
	aead, err := passwordCipher(password, e.Salt)
	if err != nil {
		return nil, err
	}
	sealed := aead.Seal(nil, e.Nonce, data, []byte(associatedData))
	e.Ciphertext, e.MAC = sealed[:len(sealed)-aead.Overhead()], sealed[len(sealed)-aead.Overhead():]
	return json.Marshal(e)
}

func Decrypt(data []byte, password string) ([]byte, error) {
	if len(data) > MaxEnvelopeBytes {
		return nil, errTooLarge
	}
	var e envelope
	if json.Unmarshal(data, &e) != nil || e.App != "FlClashX" || e.Schema != 2 || e.Compression != "tar+xz" ||
		e.Cipher != "AES-256-GCM" || e.KDF != "PBKDF2-SHA256" || e.Iterations != iterations ||
		len(e.Salt) != 16 || len(e.Nonce) != 12 || len(e.MAC) != 16 {
		return nil, errInvalid
	}
	if len(e.Ciphertext) > MaxEncryptedBytes {
		return nil, errTooLarge
	}
	if !utf8.ValidString(password) || len(password) == 0 || utf8.RuneCountInString(password) > 1024 {
		return nil, errPassword
	}
	aead, err := passwordCipher(password, e.Salt)
	if err != nil {
		return nil, err
	}
	plaintext, err := aead.Open(nil, e.Nonce, append(e.Ciphertext, e.MAC...), []byte(associatedData))
	if err != nil {
		return nil, errDecryption
	}
	return plaintext, nil
}

func dispatch(request Request) ([]byte, error) {
	if request.Version != 1 {
		return nil, errInvalid
	}
	switch request.Operation {
	case "compress":
		return Compress(request.Data)
	case "decompress":
		return Decompress(request.Data)
	case "encrypt":
		return Encrypt(request.Data, request.Password)
	case "decrypt":
		return Decrypt(request.Data, request.Password)
	default:
		return nil, errInvalid
	}
}

func Handle(input []byte) (result []byte) {
	defer func() {
		if recover() != nil {
			result = []byte(`{"error":"internal"}`)
		}
	}()
	response := Response{}
	var request Request
	var err error
	if len(input) > MaxWireBytes {
		err = errTooLarge
	} else if json.Unmarshal(input, &request) != nil {
		err = errInvalid
	} else {
		response.Data, err = dispatch(request)
	}
	if err != nil {
		switch err {
		case errInvalid, errTooLarge, errPassword, errDecryption:
			response.Error = err.Error()
		default:
			response.Error = "internal"
		}
	}
	result, _ = json.Marshal(response)
	return result
}

func Serve(input io.Reader, output io.Writer) error {
	data, err := io.ReadAll(io.LimitReader(input, MaxWireBytes+1))
	if err != nil {
		_, err = output.Write([]byte(`{"error":"internal"}`))
		return err
	}
	defer clear(data)
	_, err = output.Write(Handle(data))
	return err
}
