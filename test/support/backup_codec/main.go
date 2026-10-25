package main

import (
	"core/backupcodec"
	"os"
)

func main() {
	if backupcodec.Serve(os.Stdin, os.Stdout) != nil {
		os.Exit(1)
	}
}
