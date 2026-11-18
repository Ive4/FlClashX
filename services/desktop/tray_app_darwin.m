#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdbool.h>

void flclashConfigureTrayApplication(void) {
	@autoreleasepool {
		[NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyAccessory];
	}
}

bool flclashSetTrayTitle(const char *title) {
	__block bool updated = false;
	void (^apply)(void) = ^{
		@autoreleasepool {
			id delegate = NSApp.delegate;
			// The pinned systray delegate owns the item and exposes no button accessor.
			Ivar itemVariable = class_getInstanceVariable(object_getClass(delegate), "statusItem");
			NSStatusItem *item = itemVariable ? object_getIvar(delegate, itemVariable) : nil;
			NSStatusBarButton *button = item.button;
			if (button == nil) return;

			NSString *text = [NSString stringWithUTF8String:title] ?: @"";
			NSMutableParagraphStyle *style = [[[NSMutableParagraphStyle alloc] init] autorelease];
			style.alignment = NSTextAlignmentRight;
			style.maximumLineHeight = 10;
			NSDictionary *attributes = @{
				NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium],
				NSParagraphStyleAttributeName: style,
			};
			NSAttributedString *label = [[[NSAttributedString alloc] initWithString:text attributes:attributes] autorelease];
			button.attributedTitle = label;
			button.imagePosition = button.image == nil ? NSNoImage : (text.length ? NSImageLeft : NSImageOnly);
			NSCell *cell = button.cell;
			CGFloat buttonWidth = cell.cellSize.width;
			if (text.length && buttonWidth > 0) {
				CGFloat minimumWidth = [@"8888 MB/s" sizeWithAttributes:attributes].width;
				item.length = ceil(buttonWidth + MAX(0, minimumWidth - label.size.width));
			} else {
				item.length = NSVariableStatusItemLength;
			}
			updated = true;
		}
	};
	if (NSThread.isMainThread) {
		apply();
	} else {
		dispatch_sync(dispatch_get_main_queue(), apply);
	}
	return updated;
}
