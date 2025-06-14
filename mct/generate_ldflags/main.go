package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

func main() {
	// Get Git commit hash
	cmd := exec.Command("git", "rev-parse", "HEAD")
	commitBytes, err := cmd.Output()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error getting commit hash: %v\n", err)
		os.Exit(1)
	}
	headOID := strings.TrimSpace(string(commitBytes))

	// Get build date
	buildDate := time.Now().Format(time.RFC3339)

	// Start constructing ldflags

    ldflags := fmt.Sprintf("-X 'github.com/tursomari/machtiani/mct/internal/api.HeadOID=%s' -X 'github.com/tursomari/machtiani/mct/internal/api.BuildDate=%s' -X 'github.com/tursomari/machtiani/mct/internal/api.MachtianiGitRemoteURL=%s' -X 'github.com/tursomari/machtiani/mct/internal/cli.SystemMessageFrequencyHours=24'",
		headOID,
		buildDate,
		"https://github.com/tursomari/machtiani")

	fmt.Println(ldflags)
}
