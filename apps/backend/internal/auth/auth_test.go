package auth

import (
	"regexp"
	"testing"
)

func TestGenerateCodeIsSixDigits(t *testing.T) {
	sixDigits := regexp.MustCompile(`^\d{6}$`)
	seen := map[string]int{}
	for range 2000 {
		code, err := GenerateCode()
		if err != nil {
			t.Fatal(err)
		}
		if !sixDigits.MatchString(code) {
			t.Fatalf("code %q is not six digits", code)
		}
		seen[code]++
	}
	// Sanity on the distribution: 2000 draws from 10^6 should almost never
	// repeat, and definitely spread across leading digits.
	leading := map[byte]bool{}
	for code := range seen {
		leading[code[0]] = true
	}
	if len(leading) < 8 {
		t.Fatalf("only %d distinct leading digits — not uniform", len(leading))
	}
}

func TestHashVerify(t *testing.T) {
	salt, err := NewSalt()
	if err != nil {
		t.Fatal(err)
	}
	hash := HashCode(salt, "123456")
	if !CodeMatches(hash, salt, "123456") {
		t.Fatal("correct code did not match")
	}
	if CodeMatches(hash, salt, "654321") {
		t.Fatal("wrong code matched")
	}
	// A different salt on the same code must not collide.
	otherSalt, _ := NewSalt()
	if CodeMatches(HashCode(otherSalt, "123456"), salt, "123456") {
		t.Fatal("salt was not mixed into the hash")
	}
}

func TestTokenHashIsStableAndOpaque(t *testing.T) {
	token, hash, err := NewToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(token) < 40 {
		t.Fatalf("token too short: %q", token)
	}
	if string(HashToken(token)) != string(hash) {
		t.Fatal("HashToken disagrees with NewToken's hash")
	}
	// The stored hash must not reveal the token.
	if string(hash) == token {
		t.Fatal("hash equals the token")
	}
}
