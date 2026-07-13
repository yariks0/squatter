// Package auth holds the pure credential logic: one-time login codes and
// opaque session tokens. No I/O — the store persists, httpapi enforces
// policy, this package only generates and compares.
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"math/big"
)

// MaxCodeAttempts is how many wrong guesses burn a code. Together with the
// 10-minute expiry and single-use consumption, this is the real defense for
// a 6-digit space — at-rest hashing only keeps a DB dump useless within the
// window.
const MaxCodeAttempts = 5

// GenerateCode returns a uniform 6-digit code from crypto/rand.
func GenerateCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n), nil
}

// NewSalt returns the per-code random HMAC key.
func NewSalt() ([]byte, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	return salt, nil
}

// HashCode is HMAC-SHA256(salt, code). bcrypt/argon2 buy nothing against a
// 10^6 space — expiry and attempt caps do the guarding — so cheap and
// constant-time wins.
func HashCode(salt []byte, code string) []byte {
	mac := hmac.New(sha256.New, salt)
	mac.Write([]byte(code))
	return mac.Sum(nil)
}

// CodeMatches compares in constant time.
func CodeMatches(hash, salt []byte, code string) bool {
	return hmac.Equal(hash, HashCode(salt, code))
}
