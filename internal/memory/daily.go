package memory

import (
	"os"
	"path/filepath"
	"time"
)

func AppendDaily(root, text string) error {
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	p := filepath.Join(root, time.Now().UTC().Format("2006-01-02")+".md")
	f, err := os.OpenFile(p, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(text + "\n")
	return err
}
