package policy

type Policy struct {
	Allow []string
	Block []string
}

func Default() *Policy {
	return &Policy{Allow: []string{"exec", "read", "write", "ls", "search", "replace"}}
}

func (p *Policy) IsAllowed(sessionType string, toolName string) bool {
	if len(p.Allow) == 0 {
		return true
	}
	for _, name := range p.Allow {
		if name == toolName {
			return true
		}
	}
	return false
}
