//go:build !android

package main

import (
	"core"
	"core/backupcodec"
	"fmt"
	"os"
)

func main() {
	args := os.Args
	if len(args) == 2 && args[1] == "--backup-codec" {
		if backupcodec.Serve(os.Stdin, os.Stdout) != nil {
			os.Exit(1)
		}
		return
	}
	if len(args) <= 1 {
		fmt.Fprintln(os.Stderr, "Arguments error")
		os.Exit(1)
	}
	go core.ExitOnTermination()
	core.StartServer(args[1])
}
