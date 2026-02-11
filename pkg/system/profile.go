package system

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

type Profile struct {
	OS            string
	Distro        string
	Version       string
	Kernel        string
	Arch          string
	Shell         string
	SecurityModel string
	AvailableBins []string
}

func Detect() (*Profile, error) {
	profile := &Profile{
		OS:   runtime.GOOS,
		Arch: detectArch(),
	}

	switch runtime.GOOS {
	case "linux":
		profile.Shell = os.Getenv("SHELL")
		profile.SecurityModel = detectLinuxSecurity()
		distro, version := parseOSRelease("/etc/os-release")
		profile.Distro = distro
		profile.Version = version
		profile.Kernel, _ = uname("-r")
	case "darwin":
		profile.Shell = os.Getenv("SHELL")
		profile.SecurityModel = detectGatekeeper()
		profile.Distro = "macos"
		if version, err := swVers("-productVersion"); err == nil {
			profile.Version = version
		}
		profile.Kernel, _ = uname("-r")
	case "windows":
		profile.Shell = detectWindowsShell()
		profile.SecurityModel = "n/a"
		if isWSL() {
			profile.Distro = "wsl"
			profile.Kernel, _ = uname("-r")
			profile.Version = os.Getenv("WSL_DISTRO_NAME")
		} else {
			profile.Distro = "windows"
			profile.Version = detectWindowsVersion()
		}
	}

	profile.AvailableBins = scanPathBins()
	return profile, nil
}

func (p *Profile) MissingBins(bins []string) []string {
	if len(bins) == 0 {
		return nil
	}
	available := make(map[string]bool, len(p.AvailableBins))
	for _, bin := range p.AvailableBins {
		available[strings.ToLower(bin)] = true
	}
	missing := []string{}
	for _, bin := range bins {
		if !available[strings.ToLower(bin)] {
			missing = append(missing, bin)
		}
	}
	return missing
}

func parseOSRelease(path string) (string, string) {
	file, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer file.Close()

	var distro, version string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "ID=") {
			distro = trimValue(strings.TrimPrefix(line, "ID="))
		}
		if strings.HasPrefix(line, "VERSION_ID=") {
			version = trimValue(strings.TrimPrefix(line, "VERSION_ID="))
		}
	}
	return distro, version
}

func trimValue(val string) string {
	return strings.Trim(val, "\"'")
}

func uname(arg string) (string, error) {
	out, err := exec.Command("uname", arg).Output()
	if err != nil {
		return "", fmt.Errorf("uname %s: %w", arg, err)
	}
	return strings.TrimSpace(string(out)), nil
}

func swVers(arg string) (string, error) {
	out, err := exec.Command("sw_vers", arg).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func detectLinuxSecurity() string {
	if _, err := os.Stat("/sys/module/apparmor/parameters/enabled"); err == nil {
		return "apparmor"
	}
	if _, err := os.Stat("/sys/fs/selinux/enforce"); err == nil {
		return "selinux"
	}
	return "none"
}

func detectGatekeeper() string {
	out, err := exec.Command("spctl", "--status").Output()
	if err != nil {
		return "gatekeeper"
	}
	if strings.Contains(strings.ToLower(string(out)), "enabled") {
		return "gatekeeper"
	}
	return "gatekeeper"
}

func detectWindowsShell() string {
	if os.Getenv("PSModulePath") != "" {
		return "powershell"
	}
	if os.Getenv("ComSpec") != "" {
		return "cmd"
	}
	return "powershell"
}

func detectWindowsVersion() string {
	if ver := os.Getenv("OS"); ver != "" {
		return ver
	}
	return "windows"
}

func detectArch() string {
	if runtime.GOOS == "windows" {
		if arch := os.Getenv("PROCESSOR_ARCHITECTURE"); arch != "" {
			return arch
		}
	}
	if out, err := uname("-m"); err == nil {
		return out
	}
	return runtime.GOARCH
}

func isWSL() bool {
	if os.Getenv("WSL_DISTRO_NAME") != "" {
		return true
	}
	data, err := os.ReadFile("/proc/version")
	if err != nil {
		return false
	}
	return strings.Contains(strings.ToLower(string(data)), "microsoft")
}

func scanPathBins() []string {
	bins := make(map[string]bool)
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			bins[entry.Name()] = true
		}
	}

	out := make([]string, 0, len(bins))
	for name := range bins {
		out = append(out, name)
	}
	return out
}
