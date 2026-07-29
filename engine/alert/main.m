#import <Cocoa/Cocoa.h>

// Doppel alert helper: doppel-alert <instance name> <message>
// Shows a blocking critical alert. Used by the engine's fail_closed path so
// launch failures are visible even when the instance was opened from Finder.

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *name = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"Doppel";
        NSString *message = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"An unknown error occurred.";
        [NSApplication sharedApplication];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"%@ could not start", name];
        alert.informativeText = message;
        alert.alertStyle = NSAlertStyleCritical;
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
    return 0;
}
