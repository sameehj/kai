package attribution

import "testing"

func TestSplitHostPort(t *testing.T) {
	cases := []struct {
		in       string
		wantHost string
		wantPort int
	}{
		{"1.2.3.4:443", "1.2.3.4", 443},
		{"[2606:4700:4700::1111]:443", "2606:4700:4700::1111", 443},
		{"2606:4700:4700::1111:443", "2606:4700:4700::1111", 443},
		{"example.com:8443", "example.com", 8443},
		{"bad-value", "bad-value", 0},
	}
	for _, tc := range cases {
		h, p := splitHostPort(tc.in)
		if h != tc.wantHost || p != tc.wantPort {
			t.Fatalf("splitHostPort(%q) got (%q,%d), want (%q,%d)", tc.in, h, p, tc.wantHost, tc.wantPort)
		}
	}
}
