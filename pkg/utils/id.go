package utils

import (
	"crypto/rand"
	"encoding/hex"
)

func NewID(prefix string) string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return prefix + "_" + hex.EncodeToString(b)
}
