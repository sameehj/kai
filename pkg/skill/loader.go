package skill

import (
	"os"
)

func Load(path string) (*Skill, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return &Skill{Content: string(data)}, nil
}
