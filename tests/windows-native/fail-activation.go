//go:build windows

// A deliberately broken release for the disposable VM activation rollback gate.
package main

import "os"

func main() {
	if os.Getenv("COMPUTERNAME") != "DM-WIN-TEST" {
		os.Exit(2)
	}
	if len(os.Args) == 2 && os.Args[1] == "--help" {
		return
	}
	os.Exit(1)
}
