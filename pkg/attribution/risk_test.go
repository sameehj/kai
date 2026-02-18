package attribution

import (
	"testing"
	"time"

	"github.com/kai-ai/kai/pkg/models"
)

func TestScoreEvent_GitPush(t *testing.T) {
	ev := &models.AgentEvent{
		Timestamp:  time.Now(),
		Agent:      models.AgentCursor,
		ActionType: models.ActionExec,
		Target:     "git push origin main",
	}
	score, labels := ScoreEvent(ev)
	if score < 65 {
		t.Fatalf("expected score >= 65, got %d", score)
	}
	found := false
	for _, l := range labels {
		if l == "git push" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected git push label, got %v", labels)
	}
}

func TestScoreEvent_MassFileOperations(t *testing.T) {
	now := time.Now()
	lastScore := 0
	lastLabels := []string{}
	for i := 0; i < 22; i++ {
		ev := &models.AgentEvent{
			Timestamp:  now.Add(time.Duration(i) * 100 * time.Millisecond),
			Agent:      models.AgentCursor,
			ActionType: models.ActionFileWrite,
			Target:     "/tmp/f.txt",
		}
		lastScore, lastLabels = ScoreEvent(ev)
	}
	if lastScore < 55 {
		t.Fatalf("expected mass-file-op score contribution, got %d labels=%v", lastScore, lastLabels)
	}
	found := false
	for _, l := range lastLabels {
		if l == "mass file operation" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected mass file operation label, got %v", lastLabels)
	}
}
