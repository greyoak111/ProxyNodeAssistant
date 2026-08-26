package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

type controllerEncryptionKey struct {
	DeviceID string
	Public   string
}

type driveEscrowCiphertext struct {
	Nonce string `json:"nonce"`
	Data  string `json:"data"`
}

type driveEscrowEnvelope struct {
	DeviceID        string `json:"deviceId"`
	EncryptionKey   string `json:"encryptionPublicKey"`
	EphemeralPublic string `json:"ephemeralPublicKey"`
	Nonce           string `json:"nonce"`
	WrappedKey      string `json:"wrappedKey"`
}

type driveCredentialEscrow struct {
	Version    int                   `json:"version"`
	NodeID     string                `json:"nodeId"`
	AccountID  string                `json:"accountId"`
	SpaceID    string                `json:"spaceId"`
	Username   string                `json:"username"`
	Ciphertext driveEscrowCiphertext `json:"ciphertext"`
	Envelopes  []driveEscrowEnvelope `json:"envelopes"`
}

var driveAccountIDPattern = regexp.MustCompile(`^tna-account-[a-f0-9]{32}$`)
var driveSpaceIDPattern = regexp.MustCompile(`^tna-space-[a-f0-9]{32}$`)

func driveEscrowAAD(value driveCredentialEscrow) []byte {
	return []byte("TNA-DRIVE-CREDENTIAL-ESCROW-V1\nNODE_ID=" + value.NodeID + "\nACCOUNT_ID=" + value.AccountID + "\nSPACE_ID=" + value.SpaceID + "\nUSERNAME=" + value.Username + "\n")
}

func randomToken(prefix string, bytesCount int) (string, error) {
	data := make([]byte, bytesCount)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return prefix + fmt.Sprintf("%x", data), nil
}

func aesGCMSeal(key, plaintext, aad []byte) (nonce, sealed []byte, err error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, err
	}
	nonce = make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, nil, err
	}
	return nonce, gcm.Seal(nil, nonce, plaintext, aad), nil
}

func aesGCMOpen(key, nonce, sealed, aad []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return gcm.Open(nil, nonce, sealed, aad)
}

func driveEnvelopeKey(shared, aad []byte) []byte {
	mac := hmac.New(sha256.New, shared)
	mac.Write([]byte("TNA-DRIVE-DEK-WRAP-V1\x00"))
	mac.Write(aad)
	return mac.Sum(nil)
}

func parseControllerEncryptionKeys(stdout string) ([]controllerEncryptionKey, error) {
	block, err := extractMarkerBlock(stdout, "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_BEGIN__", "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_END__")
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	keys := []controllerEncryptionKey{}
	for _, line := range strings.Split(block, "\n") {
		parts := strings.Split(line, "\t")
		if len(parts) != 3 || parts[0] != "CONTROLLER" || !deviceIDPattern.MatchString(parts[1]) || !deviceEncryptionPublicPattern.MatchString(parts[2]) || seen[parts[1]] {
			return nil, errors.New("controller encryption-key protocol is invalid")
		}
		seen[parts[1]] = true
		keys = append(keys, controllerEncryptionKey{DeviceID: parts[1], Public: parts[2]})
	}
	if len(keys) == 0 {
		return nil, errors.New("no active controller encryption key is available")
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i].DeviceID < keys[j].DeviceID })
	return keys, nil
}

func encryptDriveCredential(nodeID, accountID, spaceID, username, password string, controllers []controllerEncryptionKey) (driveCredentialEscrow, error) {
	value := driveCredentialEscrow{Version: 1, NodeID: nodeID, AccountID: accountID, SpaceID: spaceID, Username: username}
	if !nodeIDPattern.MatchString(nodeID) || !driveAccountIDPattern.MatchString(accountID) || !driveSpaceIDPattern.MatchString(spaceID) || !driveUsernamePattern.MatchString(username) || !drivePasswordPattern.MatchString(password) || len(controllers) == 0 {
		return value, errors.New("invalid drive credential escrow input")
	}
	dek := make([]byte, 32)
	if _, err := rand.Read(dek); err != nil {
		return value, err
	}
	aad := driveEscrowAAD(value)
	nonce, sealed, err := aesGCMSeal(dek, []byte(password), aad)
	if err != nil {
		return value, err
	}
	value.Ciphertext = driveEscrowCiphertext{Nonce: base64.RawURLEncoding.EncodeToString(nonce), Data: base64.RawURLEncoding.EncodeToString(sealed)}
	curve := ecdh.X25519()
	seen := map[string]bool{}
	for _, controller := range controllers {
		if seen[controller.DeviceID] || !deviceIDPattern.MatchString(controller.DeviceID) || !deviceEncryptionPublicPattern.MatchString(controller.Public) {
			return driveCredentialEscrow{}, errors.New("invalid or duplicate controller encryption key")
		}
		seen[controller.DeviceID] = true
		raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(controller.Public, "tna-x25519:"))
		if err != nil {
			return driveCredentialEscrow{}, err
		}
		public, err := curve.NewPublicKey(raw)
		if err != nil {
			return driveCredentialEscrow{}, err
		}
		ephemeral, err := curve.GenerateKey(rand.Reader)
		if err != nil {
			return driveCredentialEscrow{}, err
		}
		shared, err := ephemeral.ECDH(public)
		if err != nil {
			return driveCredentialEscrow{}, err
		}
		wrapNonce, wrapped, err := aesGCMSeal(driveEnvelopeKey(shared, aad), dek, append(aad, []byte(controller.DeviceID)...))
		if err != nil {
			return driveCredentialEscrow{}, err
		}
		value.Envelopes = append(value.Envelopes, driveEscrowEnvelope{
			DeviceID: controller.DeviceID, EncryptionKey: controller.Public,
			EphemeralPublic: "tna-x25519:" + base64.RawURLEncoding.EncodeToString(ephemeral.PublicKey().Bytes()),
			Nonce:           base64.RawURLEncoding.EncodeToString(wrapNonce), WrappedKey: base64.RawURLEncoding.EncodeToString(wrapped),
		})
	}
	return value, nil
}

func decryptDriveCredential(value driveCredentialEscrow, identity DeviceIdentity, private *ecdh.PrivateKey) (string, error) {
	if private == nil || value.Version != 1 || identity.DeviceID == "" {
		return "", errors.New("drive escrow decryption context is invalid")
	}
	var envelope *driveEscrowEnvelope
	for index := range value.Envelopes {
		if value.Envelopes[index].DeviceID == identity.DeviceID {
			envelope = &value.Envelopes[index]
			break
		}
	}
	if envelope == nil || envelope.EncryptionKey != identity.EncryptionPublic {
		return "", errors.New("this controller has no matching drive credential envelope")
	}
	decode := func(text string) ([]byte, error) { return base64.RawURLEncoding.DecodeString(text) }
	ephemeralRaw, err := decode(strings.TrimPrefix(envelope.EphemeralPublic, "tna-x25519:"))
	if err != nil {
		return "", err
	}
	ephemeral, err := ecdh.X25519().NewPublicKey(ephemeralRaw)
	if err != nil {
		return "", err
	}
	shared, err := private.ECDH(ephemeral)
	if err != nil {
		return "", err
	}
	aad := driveEscrowAAD(value)
	wrapNonce, err := decode(envelope.Nonce)
	if err != nil {
		return "", err
	}
	wrapped, err := decode(envelope.WrappedKey)
	if err != nil {
		return "", err
	}
	dek, err := aesGCMOpen(driveEnvelopeKey(shared, aad), wrapNonce, wrapped, append(aad, []byte(identity.DeviceID)...))
	if err != nil {
		return "", errors.New("drive credential envelope authentication failed")
	}
	cipherNonce, err := decode(value.Ciphertext.Nonce)
	if err != nil {
		return "", err
	}
	sealed, err := decode(value.Ciphertext.Data)
	if err != nil {
		return "", err
	}
	password, err := aesGCMOpen(dek, cipherNonce, sealed, aad)
	if err != nil || !drivePasswordPattern.Match(password) {
		return "", errors.New("drive credential ciphertext authentication failed")
	}
	return string(password), nil
}

func encodeDriveEscrow(value driveCredentialEscrow) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	if len(data) > 32768 {
		return "", errors.New("drive credential escrow is unexpectedly large")
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func decodeDriveEscrow(encoded string) (driveCredentialEscrow, error) {
	var value driveCredentialEscrow
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil || len(data) > 32768 || json.Unmarshal(data, &value) != nil {
		return value, errors.New("invalid drive credential escrow encoding")
	}
	if value.Version != 1 || !nodeIDPattern.MatchString(value.NodeID) || !driveAccountIDPattern.MatchString(value.AccountID) || !driveSpaceIDPattern.MatchString(value.SpaceID) || !driveUsernamePattern.MatchString(value.Username) || len(value.Envelopes) == 0 {
		return value, errors.New("invalid drive credential escrow fields")
	}
	return value, nil
}
