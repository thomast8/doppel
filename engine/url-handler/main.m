#import <Cocoa/Cocoa.h>

// Tiny Launch Services helper used after installing a managed instance and
// after completing connector OAuth. Older Doppel builds let Electron claim
// codex:// merely by launching. The app.asar patch now claims it only for an
// active authorization, then uses this helper to return ownership to primary.

static void usage(void) {
    fprintf(stderr, "usage: doppel-url-handler {get <scheme>|set <scheme> <app-path> <bundle-id>}\n");
}

static NSString *handler_bundle_id(NSString *scheme) {
    NSURL *probe = [NSURL URLWithString:[NSString stringWithFormat:@"%@://doppel-handler-probe", scheme]];
    NSURL *applicationURL = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:probe];
    if (applicationURL == nil) return nil;
    return [NSBundle bundleWithURL:applicationURL].bundleIdentifier;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            usage();
            return 64;
        }
        NSString *operation = [NSString stringWithUTF8String:argv[1]];
        NSString *scheme = [NSString stringWithUTF8String:argv[2]];
        if (scheme.length == 0) {
            usage();
            return 64;
        }

        if ([operation isEqualToString:@"get"] && argc == 3) {
            NSString *handler = handler_bundle_id(scheme);
            if (handler == nil) return 1;
            printf("%s\n", handler.UTF8String);
            return 0;
        }

        if ([operation isEqualToString:@"set"] && argc == 5) {
            NSString *applicationPath = [NSString stringWithUTF8String:argv[3]];
            NSString *bundleID = [NSString stringWithUTF8String:argv[4]];
            NSURL *applicationURL = [NSURL fileURLWithPath:applicationPath isDirectory:YES];
            NSString *actualBundleID = [NSBundle bundleWithURL:applicationURL].bundleIdentifier;
            if (bundleID.length == 0 || ![actualBundleID isEqualToString:bundleID]) {
                fprintf(stderr, "doppel-url-handler: the application path does not have the expected bundle ID\n");
                return 1;
            }

            __block BOOL finished = NO;
            __block NSError *setError = nil;
            [[NSWorkspace sharedWorkspace]
                setDefaultApplicationAtURL:applicationURL
                toOpenURLsWithScheme:scheme
                completionHandler:^(NSError *error) {
                    setError = error;
                    finished = YES;
                }];

            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
            while (!finished && deadline.timeIntervalSinceNow > 0) {
                [[NSRunLoop currentRunLoop]
                    runMode:NSDefaultRunLoopMode
                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            if (!finished) {
                fprintf(stderr, "doppel-url-handler: timed out waiting for Launch Services\n");
                return 1;
            }
            if (setError != nil) {
                fprintf(stderr, "doppel-url-handler: %s\n", setError.localizedDescription.UTF8String);
                return 1;
            }

            NSString *handler = handler_bundle_id(scheme);
            if (![handler isEqualToString:bundleID]) {
                fprintf(stderr, "doppel-url-handler: Launch Services did not retain the requested handler\n");
                return 1;
            }
            return 0;
        }

        if ([operation isEqualToString:@"set"] && argc != 5) {
            usage();
            return 64;
        }

        usage();
        return 64;
    }
}
