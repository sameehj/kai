package attach

import "testing"

func TestSplitTracepoint(t *testing.T) {
	t.Parallel()

	category, name, err := splitTracepoint("sched/sched_process_exec")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if category != "sched" || name != "sched_process_exec" {
		t.Fatalf("splitTracepoint returned %s/%s", category, name)
	}

	if _, _, err := splitTracepoint("invalid-tracepoint"); err == nil {
		t.Fatalf("expected error for malformed tracepoint identifier")
	}
}
