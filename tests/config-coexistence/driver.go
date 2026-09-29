// This probe calls the production DearMachine boundary without a mail daemon.
// The runner builds it inside a temporary snapshot of the DearMachine module.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/dearmachine/dearmachine/internal/client"
	"github.com/dearmachine/dearmachine/internal/machtianiconfig"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: driver sync|migrate MACHTIANI PROJECT")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	var err error
	switch os.Args[1] {
	case "sync":
		var runner *client.AgentRunner
		runner, err = client.NewAgentRunner(os.Args[2], os.Args[3], "")
		if err == nil {
			err = runner.Sync(ctx)
		}
	case "migrate":
		err = machtianiconfig.Migrate(ctx, os.Args[2], os.Getenv("HOME"))
	default:
		err = fmt.Errorf("unknown action")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
