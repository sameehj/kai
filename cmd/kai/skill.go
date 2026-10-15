package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/kai-agent/kai/internal/agent"
	"github.com/kai-agent/kai/internal/config"
	"github.com/kai-agent/kai/internal/executor"
	"github.com/kai-agent/kai/internal/skills"
)

func runSkill(args []string) {
	if len(args) < 2 {
		printSkillUsage()
		return
	}
	switch args[1] {
	case "add":
		if len(args) < 3 {
			fmt.Println("usage: kai skill add <github-url>")
			return
		}
		must(runSkillAdd(args[2]))
	case "list":
		must(listSkills())
	case "remove":
		if len(args) < 3 {
			fmt.Println("usage: kai skill remove <name>")
			return
		}
		must(removeSkill(args[2]))
	case "update":
		if len(args) < 3 {
			fmt.Println("usage: kai skill update <name>")
			return
		}
		must(updateSkill(args[2]))
	default:
		printSkillUsage()
	}
}

func printSkillUsage() {
	fmt.Println("usage: kai skill add <url> | list | remove <name> | update <name>")
}

func runSkillAdd(url string) error {
	cfg := loadConfigOrDefault()
	target := config.DefaultTargetName(cfg.Targets)
	ag, err := agent.NewForTarget(cfg, target)
	if err != nil {
		return err
	}
	defer ag.Close()

	repoName := guessRepoName(url)
	communityRoot := config.DefaultCommunitySkillRoot()
	cloneDir := filepath.Join(communityRoot, repoName)
	prompt := fmt.Sprintf(`## Task: Add a GitHub repository as a Kai skill

Repository: %s

Steps:
1. Clone to %s
2. Read README.md and infer dependencies.
3. Generate metadata.yaml with name/version/description/category/requires.
4. Generate SKILL.md operational playbook (not a README copy).
5. Check requirements against current target.
6. Report result with requirements met/missing and offer installs.
`, strings.TrimSpace(url), cloneDir)

	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	resp, err := ag.Run(ctx, prompt)
	if err != nil {
		return err
	}
	fmt.Println(resp)
	return nil
}

func listSkills() error {
	cfg := loadConfigOrDefault()
	target := config.DefaultTargetName(cfg.Targets)
	spec := cfg.Targets[target]
	execImpl, err := executor.BuildExecutor(executor.TargetSpec{
		Type:      spec.Type,
		Host:      spec.Host,
		Port:      spec.Port,
		User:      spec.User,
		KeyFile:   spec.Key,
		Container: spec.Container,
	})
	if err != nil {
		return err
	}
	probe, _ := executor.Probe(context.Background(), execImpl)
	all, err := skills.LoadAllSkills(probe, cfg.Skills.Disabled, cfg.Skills.Dirs)
	if err != nil {
		return err
	}
	enabledSet := map[string]struct{}{}
	for _, name := range cfg.Skills.Enabled {
		enabledSet[strings.TrimSpace(name)] = struct{}{}
	}
	builtIn := make([]skills.Skill, 0, len(all))
	community := make([]skills.Skill, 0, len(all))
	for _, s := range all {
		if strings.Contains(filepath.Clean(s.Path), filepath.Clean(config.DefaultCommunitySkillRoot())) {
			community = append(community, s)
		} else {
			builtIn = append(builtIn, s)
		}
	}

	fmt.Println("Built-in skills:")
	if len(builtIn) == 0 {
		fmt.Println("  (none)")
	} else {
		for _, s := range builtIn {
			printSkillLine(s, enabledSet)
		}
	}
	fmt.Println()
	fmt.Println("Community skills:")
	if len(community) == 0 {
		fmt.Println("  (none - add with: kai skill add <github-url>)")
	} else {
		for _, s := range community {
			printSkillLine(s, enabledSet)
		}
	}
	return nil
}

func printSkillLine(s skills.Skill, enabledSet map[string]struct{}) {
	icon := "⚪"
	if _, ok := enabledSet[s.Name]; ok {
		icon = "✅"
	}
	status := "full"
	if !s.Available {
		status = "unavailable"
	} else if s.Degraded {
		status = "degraded"
	}
	desc := strings.TrimSpace(s.Metadata.Description)
	if desc == "" {
		desc = "(no description)"
	}
	fmt.Printf("  %s %-16s %s [%s]\n", icon, s.Name, desc, status)
}

func removeSkill(name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("skill name required")
	}
	path := filepath.Join(config.DefaultCommunitySkillRoot(), name)
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return fmt.Errorf("community skill %q not found at %s", name, path)
	}
	return os.RemoveAll(path)
}

func updateSkill(name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("skill name required")
	}
	path := filepath.Join(config.DefaultCommunitySkillRoot(), name)
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("community skill not found: %s", path)
	}
	cmd := exec.Command("sh", "-lc", "cd "+shellEscape(path)+" && git pull --ff-only")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func guessRepoName(url string) string {
	url = strings.TrimSpace(url)
	url = strings.TrimSuffix(url, "/")
	url = strings.TrimSuffix(url, ".git")
	if idx := strings.LastIndex(url, "/"); idx >= 0 && idx < len(url)-1 {
		return url[idx+1:]
	}
	return "community-skill"
}

func shellEscape(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
