package session

import "testing"

func TestStoreSaveLoad(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(dir)
	sess := &Session{ID: "agent:test:main"}
	if err := store.Save(sess); err != nil {
		t.Fatalf("save: %v", err)
	}
	loaded, err := store.Load("agent:test:main")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if loaded.ID != sess.ID {
		t.Fatalf("expected id %q, got %q", sess.ID, loaded.ID)
	}
}
