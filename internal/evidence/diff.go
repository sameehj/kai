package evidence

import "fmt"

func DiffSummary(baseDir, runA, runB string) (string, error) {
	a, err := Replay(baseDir, runA)
	if err != nil {
		return "", err
	}
	b, err := Replay(baseDir, runB)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("--- %s\n%s\n--- %s\n%s", runA, a, runB, b), nil
}
