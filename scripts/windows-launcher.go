//go:build windows

// Windows release launcher. Build once and copy under the command names below.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

func main() {
	executable, e := os.Executable()
	if e != nil {
		fail(e)
	}
	name := strings.ToLower(strings.TrimSuffix(filepath.Base(executable), ".exe"))
	installation := filepath.Dir(filepath.Dir(executable))
	root := installation
	if data, err := os.ReadFile(filepath.Join(installation, "current.json")); err == nil {
		var active struct {
			Version int    `json:"version"`
			Release string `json:"release"`
		}
		if err := json.Unmarshal(data, &active); err != nil {
			fail(err)
		}
		if active.Version != 1 || len(active.Release) != 32 || strings.Trim(active.Release, "0123456789abcdef") != "" {
			fail(fmt.Errorf("invalid Windows release pointer"))
		}
		root = filepath.Join(installation, "releases", active.Release)
		if e := os.Setenv("DEARMACHINE_BOOTSTRAP_PID", strconv.Itoa(os.Getpid())); e != nil {
			fail(e)
		}
		// The stable bootstrap only selects the release. Runtime environment and
		// launch behavior come from that release and can themselves be updated.
		run(filepath.Join(root, "bin", name+".exe"), os.Args[1:])
		return
	} else if !os.IsNotExist(err) {
		fail(err)
	} else if filepath.Base(filepath.Dir(installation)) == "releases" {
		// A release-local launcher must keep its matching runtime while updates
		// activate a new release. Persistence always points at the stable launcher.
		installation = filepath.Dir(filepath.Dir(installation))
	}
	home, e := os.UserHomeDir()
	if e != nil {
		fail(e)
	}
	values := map[string]string{
		"HOME":                      home,
		"PATH":                      strings.Join([]string{filepath.Join(root, "bin"), filepath.Join(root, "runtime", "node"), filepath.Join(root, "runtime", "git", "bin"), filepath.Join(root, "runtime", "git", "usr", "bin"), filepath.Join(root, "runtime", "ripgrep"), os.Getenv("PATH"), filepath.Join(home, ".local", "bin"), filepath.Join(os.Getenv("LOCALAPPDATA"), "omp")}, ";"),
		"DEARMACHINE_SOURCE_ROOT":   filepath.Join(root, "source"),
		"MACHTIANI_DISTRIBUTION":    filepath.Join(root, "distribution.json"),
		"DEARMACHINE_CONCIERGE_BIN": filepath.Join(root, "bin", "machtiani-installer.exe"),
		"DEARMACHINE_NATIVE_BIN":    filepath.Join(root, "runtime", "products", "dearmachine.exe"),
		"DEARMACHINE_LAUNCHER":      filepath.Join(installation, "bin", "dearmachine.exe"),
		"DEARMACHINE_INSTALL_ROOT":  installation,
	}
	if os.Getenv("CLAUDE_CODE_GIT_BASH_PATH") == "" {
		values["CLAUDE_CODE_GIT_BASH_PATH"] = filepath.Join(root, "runtime", "git", "bin", "bash.exe")
	}
	// A new supervisor cannot inherit the installer's temporary shell settings.
	// Pass the secure helper's file reference, never read or export its contents.
	// Explicit caller credentials keep their existing precedence.
	if strings.TrimSpace(os.Getenv("AGENTMAIL_API_KEY")) == "" && strings.TrimSpace(os.Getenv("AGENTMAIL_API_KEY_FILE")) == "" {
		credential := filepath.Join(home, ".config", "dearmachine", "agentmail-api-key")
		if info, err := os.Lstat(credential); err == nil && info.Mode().IsRegular() {
			values["AGENTMAIL_API_KEY_FILE"] = credential
		}
	}
	for k, v := range values {
		if e = os.Setenv(k, v); e != nil {
			fail(e)
		}
	}
	args := os.Args[1:]
	if _, err := os.Stat(filepath.Join(installation, ".uninstalling")); err == nil {
		if name != "dearmachine" || len(args) == 0 || args[0] != "uninstall" {
			fail(fmt.Errorf("this installation is being removed; see DearMachine-uninstall.log in LocalAppData"))
		}
	}
	var program string
	switch name {
	case "dearmachine", "machtiani", "agent-manager":
		program = filepath.Join(root, "runtime", "products", name+".exe")
	case "machtiani-installer", "machtiani-model-host":
		program = filepath.Join(root, "runtime", "node", "node.exe")
		pkg := "app"
		if name == "machtiani-model-host" {
			pkg = "model-host"
		}
		args = append([]string{filepath.Join(root, "runtime", "installer", "packages", pkg, "dist", "bin.mjs")}, args...)
	default:
		fail(fmt.Errorf("unsupported launcher name %q", name))
	}
	run(program, args)
}
func run(program string, args []string) {
	cmd := exec.Command(program, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if e := cmd.Run(); e != nil {
		if x, ok := e.(*exec.ExitError); ok {
			os.Exit(x.ExitCode())
		}
		fail(e)
	}
}
func fail(e error) { fmt.Fprintln(os.Stderr, e); os.Exit(1) }
