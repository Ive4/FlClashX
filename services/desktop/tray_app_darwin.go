package main

/*
#cgo LDFLAGS: -framework AppKit
#include <stdbool.h>
#include <stdlib.h>
void flclashConfigureTrayApplication(void);
bool flclashSetTrayTitle(const char *title);
*/
import "C"

import (
	"unsafe"

	"fyne.io/systray"
)

func configureTrayApplication() {
	C.flclashConfigureTrayApplication()
}

func setTrayTitle(title string) {
	text := C.CString(title)
	defer C.free(unsafe.Pointer(text))
	if !C.flclashSetTrayTitle(text) {
		systray.SetTitle(title)
	}
}
