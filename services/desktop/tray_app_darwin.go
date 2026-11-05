package main

/*
#cgo LDFLAGS: -framework AppKit
void flclashConfigureTrayApplication(void);
*/
import "C"

func configureTrayApplication() {
	C.flclashConfigureTrayApplication()
}
