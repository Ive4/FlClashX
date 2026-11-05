#import <AppKit/AppKit.h>

void flclashConfigureTrayApplication(void) {
	@autoreleasepool {
		[NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyAccessory];
	}
}
