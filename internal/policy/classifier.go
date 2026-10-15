package policy

import (
	"regexp"
	"strings"
)

type DangerLevel int

const (
	Safe DangerLevel = iota
	Moderate
	Dangerous
)

type Classification struct {
	Level   DangerLevel
	Reason  string
	Markers []string
}

var (
	shellWrapRe = regexp.MustCompile(`(?i)\b(bash|sh|zsh)\s+-l?c\s+['\"](.+)['\"]`)
	evalRe      = regexp.MustCompile(`(?i)\beval\s+['\"](.+)['\"]`)
	pyWrapRe    = regexp.MustCompile(`(?i)\b(python|python3|perl|ruby)\s+(-c|-e)\s+['\"](.+)['\"]`)
)

func ClassifyCommand(cmd string) Classification {
	cmd = strings.TrimSpace(cmd)
	lower := strings.ToLower(cmd)
	if cmd == "" {
		return Classification{Level: Safe, Reason: "empty command"}
	}

	if m := shellWrapRe.FindStringSubmatch(cmd); len(m) > 2 {
		inner := strings.TrimSpace(m[2])
		c := ClassifyCommand(inner)
		if c.Level == Safe {
			c.Level = Moderate
			c.Reason = "shell wrapper requires confirmation"
		}
		c.Markers = append(c.Markers, "shell-wrapper")
		return c
	}
	if m := evalRe.FindStringSubmatch(cmd); len(m) > 1 {
		inner := strings.TrimSpace(m[1])
		c := ClassifyCommand(inner)
		if c.Level == Safe {
			c.Level = Moderate
			c.Reason = "eval wrapper requires confirmation"
		}
		c.Markers = append(c.Markers, "eval")
		return c
	}
	if m := pyWrapRe.FindStringSubmatch(cmd); len(m) > 3 {
		inner := strings.TrimSpace(m[3])
		c := ClassifyCommand(inner)
		if c.Level == Safe {
			c.Level = Moderate
			c.Reason = "script wrapper requires confirmation"
		}
		c.Markers = append(c.Markers, "script-wrapper")
		return c
	}

	if containsAny(lower, "curl ", "wget ") && containsAny(lower, "| bash", "| sh", "| sudo bash", "| sudo sh") {
		return Classification{Level: Dangerous, Reason: "pipe-to-shell pattern", Markers: []string{"pipe-shell"}}
	}

	if containsAny(lower, "rm -rf /", "rm -rf ~") {
		return Classification{Level: Dangerous, Reason: "destructive filesystem operation", Markers: []string{"destructive-fs"}}
	}
	if strings.Contains(lower, "mkfs") || strings.Contains(lower, "wipefs") || strings.Contains(lower, "parted") || strings.Contains(lower, "fdisk") || strings.Contains(lower, "shred ") {
		return Classification{Level: Dangerous, Reason: "destructive disk operation", Markers: []string{"disk-destructive"}}
	}
	if strings.Contains(lower, "dd ") && strings.Contains(lower, "of=/dev/") {
		return Classification{Level: Dangerous, Reason: "raw disk write operation", Markers: []string{"dd-dev"}}
	}
	if containsAny(lower, "find ", " -delete") && containsAny(lower, " /", " .") {
		return Classification{Level: Dangerous, Reason: "broad delete operation", Markers: []string{"find-delete"}}
	}

	if containsAny(lower, "sudo ", " su ", " chmod +s", "chmod 777", "chown root", "/etc/sudoers", "/etc/passwd", "/etc/shadow") {
		return Classification{Level: Moderate, Reason: "privilege sensitive command", Markers: []string{"priv-escalation"}}
	}

	if containsAny(lower, "curl ", "wget ", "scp ", "rsync ", "nc ", "openssl s_client", "requests.", "urllib") && !containsAny(lower, "localhost", "127.0.0.1", "kernel.org") {
		return Classification{Level: Moderate, Reason: "network transfer command", Markers: []string{"network-exfil"}}
	}

	if containsAny(lower, "apt install", "apt remove", "dnf install", "dnf remove", "pip install", "npm install -g") {
		return Classification{Level: Moderate, Reason: "package management command", Markers: []string{"package-mgmt"}}
	}

	if containsAny(lower, "systemctl start", "systemctl stop", "systemctl restart", "systemctl enable", "systemctl disable", "service ") {
		return Classification{Level: Moderate, Reason: "service management command", Markers: []string{"service-mgmt"}}
	}

	return Classification{Level: Safe, Reason: "read-only command"}
}

func containsAny(s string, needles ...string) bool {
	for _, n := range needles {
		if strings.Contains(s, n) {
			return true
		}
	}
	return false
}
