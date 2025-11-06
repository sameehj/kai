package loader

import (
	"reflect"
	"testing"

	"github.com/cilium/ebpf"
)

func TestSanitizeMapName(t *testing.T) {
	t.Parallel()

	if got := sanitizeMapName("shortname"); got != "shortname" {
		t.Fatalf("expected shortname, got %s", got)
	}

	long := "averylongmapnamethatexceedslimit"
	if got := sanitizeMapName(long); len(got) != 15 {
		t.Fatalf("expected truncated name length 15, got %d", len(got))
	}
}

func TestParseMapType(t *testing.T) {
	t.Parallel()

	if parseMapType("ringbuf") != ebpf.RingBuf {
		t.Fatalf("expected ringbuf to map to ebpf.RingBuf")
	}
	if parseMapType("hash") != ebpf.Hash {
		t.Fatalf("expected hash to map to ebpf.Hash")
	}
	if parseMapType("array") != ebpf.Array {
		t.Fatalf("expected array to map to ebpf.Array")
	}
	if parseMapType("prog_array") != ebpf.ProgramArray {
		t.Fatalf("expected prog_array to map to ebpf.ProgramArray")
	}
	if parseMapType("unknown") != ebpf.Hash {
		t.Fatalf("unexpected fallback for unknown map type")
	}
}

func TestGetSizeForType(t *testing.T) {
	t.Parallel()

	cases := map[string]uint32{
		"u8":       1,
		"u16":      2,
		"u32":      4,
		"u64":      8,
		"char[16]": 16,
		"":         4,
	}

	for input, expected := range cases {
		if got := getSizeForType(input); got != expected {
			t.Errorf("getSizeForType(%q) = %d, want %d", input, got, expected)
		}
	}
}

func TestParseMapKey(t *testing.T) {
	t.Parallel()

	key, err := parseMapKey("42", "u32")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key.(uint32) != 42 {
		t.Fatalf("expected uint32 42, got %#v", key)
	}

	key64, err := parseMapKey("64", "u64")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key64.(uint64) != 64 {
		t.Fatalf("expected uint64 64, got %#v", key64)
	}

	keyStr, err := parseMapKey("foo", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if keyStr.(string) != "foo" {
		t.Fatalf("expected string foo, got %#v", keyStr)
	}
}

func TestEncodeMapValue(t *testing.T) {
	t.Parallel()

	tests := []struct {
		value    interface{}
		expected []byte
	}{
		{uint8(1), []byte{0x01}},
		{uint16(0x0201), []byte{0x01, 0x02}},
		{uint32(0x04030201), []byte{0x01, 0x02, 0x03, 0x04}},
		{uint64(1), []byte{1, 0, 0, 0, 0, 0, 0, 0}},
		{"text", []byte("text")},
		{[]byte{0xAA}, []byte{0xAA}},
	}

	for _, tc := range tests {
		got, err := encodeMapValue(tc.value)
		if err != nil {
			t.Fatalf("encodeMapValue(%T) returned error: %v", tc.value, err)
		}
		if !reflect.DeepEqual(got, tc.expected) {
			t.Fatalf("encodeMapValue(%T) = %v, want %v", tc.value, got, tc.expected)
		}
	}
}
