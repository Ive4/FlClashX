package main

import (
	"errors"
	"fmt"
	"os"
)

var expectedCoreSHA256 string

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func coreHashConfigured() error {
	if !isLowerHex(expectedCoreSHA256, 64) {
		return errors.New("expected Core SHA256 is missing or invalid")
	}
	return nil
}
