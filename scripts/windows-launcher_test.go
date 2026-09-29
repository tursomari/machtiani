//go:build windows

package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The product fixture records selectors and credential presence, never values.
func TestMain(m *testing.M) {
	if os.Getenv("IXE_LAUNCHER_PRODUCT_FIXTURE") == "1" {
		value, present := os.LookupEnv("MACHTIANI_CONFIG")
		_ = json.NewEncoder(os.Stdout).Encode(struct {
			Value   string
			Present bool
			KeyFile string
			KeySet  bool
		}{value, present, os.Getenv("AGENTMAIL_API_KEY_FILE"), os.Getenv("AGENTMAIL_API_KEY") != ""})
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func launcherFixture(t *testing.T) (home string, entries []string) {
	t.Helper()
	launcher := os.Getenv("IXE_TEST_WINDOWS_LAUNCHER")
	if launcher == "" {
		t.Skip("set IXE_TEST_WINDOWS_LAUNCHER to the compiled Windows launcher")
	}
	root := t.TempDir()
	home = filepath.Join(root, "ordinary user Ω")
	installation := filepath.Join(root, "Dear Machine Ω")
	release := "0123456789abcdef0123456789abcdef"
	runtime := filepath.Join(installation, "releases", release)
	for _, dir := range []string{home, filepath.Join(installation, "bin"), filepath.Join(runtime, "bin"), filepath.Join(runtime, "runtime", "products")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	copyFile := func(source, destination string) {
		t.Helper()
		data, err := os.ReadFile(source)
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(destination, data, 0700); err != nil {
			t.Fatal(err)
		}
	}
	stable := filepath.Join(installation, "bin", "machtiani.exe")
	direct := filepath.Join(runtime, "bin", "machtiani.exe")
	copyFile(launcher, stable)
	copyFile(launcher, direct)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	copyFile(self, filepath.Join(runtime, "runtime", "products", "machtiani.exe"))
	if err := os.WriteFile(filepath.Join(installation, "current.json"), []byte(`{"version":1,"release":"`+release+`"}`), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("USERPROFILE", home)
	t.Setenv("IXE_LAUNCHER_PRODUCT_FIXTURE", "1")
	return home, []string{stable, direct}
}

func TestWindowsLauncherPreservesConfigurationSelection(t *testing.T) {
	home, entries := launcherFixture(t)
	// Both entrypoints must let Machtiani select its normal global config, or
	// preserve the explicit private config supplied by DearMachine itself.
	for _, entry := range entries {
		for _, selection := range []string{"", filepath.Join(home, ".config", "machtiani", "config.toml"), filepath.Join(home, ".config", "dearmachine", "machtiani", "config.toml")} {
			t.Run(filepath.Base(filepath.Dir(filepath.Dir(entry)))+"/"+selection, func(t *testing.T) {
				t.Setenv("MACHTIANI_CONFIG", selection)
				if selection == "" {
					if err := os.Unsetenv("MACHTIANI_CONFIG"); err != nil {
						t.Fatal(err)
					}
				}
				output, err := exec.Command(entry, "config", "check").CombinedOutput()
				if err != nil {
					t.Fatalf("launcher failed: %v: %s", err, output)
				}
				var got struct {
					Value   string
					Present bool
				}
				if err := json.Unmarshal(output, &got); err != nil {
					t.Fatalf("invalid product observation: %v: %s", err, output)
				}
				if got.Value != selection || got.Present != (selection != "") {
					t.Fatalf("launcher changed configuration selection: got %#v; want value %q, present %v", got, selection, selection != "")
				}
			})
		}
	}
}

func TestWindowsLauncherSuppliesSavedAgentMailReference(t *testing.T) {
	home, entries := launcherFixture(t)
	credential := filepath.Join(home, ".config", "dearmachine", "agentmail-api-key")
	if err := os.MkdirAll(filepath.Dir(credential), 0700); err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		for _, test := range []struct {
			name, file, key, expected string
			saved                     bool
		}{
			{name: "absent"},
			{name: "saved", saved: true, expected: credential},
			{name: "explicit-file", saved: true, file: filepath.Join(home, "selected key"), expected: filepath.Join(home, "selected key")},
			{name: "explicit-value", saved: true, key: "counterfeit-launcher-key"},
		} {
			t.Run(filepath.Base(filepath.Dir(filepath.Dir(entry)))+"/"+test.name, func(t *testing.T) {
				if test.saved {
					if err := os.WriteFile(credential, []byte("counterfeit-file-key\n"), 0600); err != nil {
						t.Fatal(err)
					}
				} else {
					_ = os.Remove(credential)
				}
				t.Setenv("AGENTMAIL_API_KEY", test.key)
				t.Setenv("AGENTMAIL_API_KEY_FILE", test.file)
				output, err := exec.Command(entry, "config", "check").CombinedOutput()
				if err != nil {
					t.Fatalf("launcher failed: %v: %s", err, output)
				}
				var got struct {
					KeyFile string
					KeySet  bool
				}
				if err := json.Unmarshal(output, &got); err != nil {
					t.Fatal(err)
				}
				if got.KeyFile != test.expected || got.KeySet != (test.key != "") {
					t.Fatalf("unexpected credential reference: %#v", got)
				}
			})
		}
	}
}
