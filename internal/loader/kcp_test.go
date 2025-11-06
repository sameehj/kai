package loader

import "testing"

func TestParseVersion(t *testing.T) {
	t.Parallel()

	tests := map[string][]int{
		"":            {0, 0, 0},
		"5.10.42":     {5, 10, 42},
		"6.5":         {6, 5, 0},
		"4.19.257-1":  {4, 19, 257},
		"invalid.str": {0, 0, 0},
	}

	for input, expected := range tests {
		result := parseVersion(input)
		if len(result) != len(expected) {
			t.Fatalf("expected length %d for %q, got %d", len(expected), input, len(result))
		}
		for i := range expected {
			if result[i] != expected[i] {
				t.Fatalf("parseVersion(%q)[%d] = %d, expected %d", input, i, result[i], expected[i])
			}
		}
	}
}

func TestKernelVersionGTE(t *testing.T) {
	t.Parallel()

	cases := []struct {
		current  string
		required string
		want     bool
	}{
		{"5.10.0", "5.8.0", true},
		{"5.4.0", "5.8.0", false},
		{"5.10.12", "5.10.0", true},
		{"5.10", "", true},
		{"", "4.0.0", false},
	}

	for _, tc := range cases {
		got := kernelVersionGTE(tc.current, tc.required)
		if got != tc.want {
			t.Errorf("kernelVersionGTE(%q, %q) = %v, want %v", tc.current, tc.required, got, tc.want)
		}
	}
}
