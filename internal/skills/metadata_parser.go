package skills

import (
	"bufio"
	"os"
	"strings"
)

func parseMetadata(path string) Metadata {
	f, err := os.Open(path)
	if err != nil {
		return Metadata{}
	}
	defer f.Close()

	meta := Metadata{}
	s := bufio.NewScanner(f)
	section := ""
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasSuffix(line, ":") {
			section = strings.TrimSuffix(line, ":")
			continue
		}
		if strings.HasPrefix(line, "- ") {
			v := strings.TrimSpace(strings.TrimPrefix(line, "- "))
			v = strings.Trim(v, "\"")
			switch section {
			case "required_binaries", "binaries":
				if v != "" {
					meta.RequiredBins = append(meta.RequiredBins, v)
				}
			case "common_commands":
				if v != "" {
					meta.CommonCommands = append(meta.CommonCommands, v)
				}
			}
			continue
		}
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.Trim(strings.TrimSpace(v), "\"")
		switch k {
		case "name":
			meta.Name = v
		case "version":
			meta.Version = v
		case "description":
			meta.Description = v
		case "category":
			meta.Category = v
		case "author":
			meta.Author = v
		case "root":
			meta.RequiresRoot = v
		case "kernel_min":
			meta.KernelMin = v
		}
	}
	return meta
}
