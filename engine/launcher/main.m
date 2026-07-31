#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <sys/xattr.h>
#include <unistd.h>

// Doppel instance launcher. Installed as the bundle's main executable; it
// validates the bundle's own signature, then hands off to the embedded
// self-healing engine, which either execs the preserved vendor binary or
// rebuilds the instance from the current primary app.

static NSString *instance_name(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
    return name ?: @"This Doppel instance";
}

static void show_error(NSString *message) {
    [NSApplication sharedApplication];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%@ could not start", instance_name()];
    alert.informativeText = message;
    alert.alertStyle = NSAlertStyleCritical;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

// TCC grants belong to a code identity, not to the vendor app an instance was
// copied from. Consequently every Doppel bundle has to ask for the capabilities
// Codex uses to see and work with other apps. Do this in the bundle executable
// before handing off to the engine: macOS then attributes both requests to the
// managed instance rather than to Doppel, zsh, or the preserved vendor binary.
static void request_missing_permissions(void) {
    BOOL needsAccessibility = !AXIsProcessTrusted();
    BOOL needsScreenCapture = !CGPreflightScreenCaptureAccess();
    if (!needsAccessibility && !needsScreenCapture) {
        return;
    }

    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    if (needsAccessibility) {
        [missing addObject:@"Accessibility (to work with other apps)"];
    }
    if (needsScreenCapture) {
        [missing addObject:@"Screen & System Audio Recording (to see on-screen content)"];
    }

    [NSApplication sharedApplication];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%@ needs permission", instance_name()];
    alert.informativeText = [NSString stringWithFormat:
        @"This managed Codex app is missing:\n\n• %@\n\nmacOS keeps permission separate for every Doppel instance. You can continue without it, but features that use other apps may not work.",
        [missing componentsJoinedByString:@"\n• "]];
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"Allow Permissions"];
    [alert addButtonWithTitle:@"Not Now"];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    // These are Apple's own consent flows. They deliberately run only after a
    // user action; denied grants are never modified or reset behind their back.
    if (needsAccessibility) {
        NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
    if (needsScreenCapture) {
        CGRequestScreenCaptureAccess();
    }
}

// The requirement recorded for a bundle installed at this exact path, or nil.
//
// It is deliberately not read from the bundle's own Info.plist. Doing that made
// the pin self-defeating: whoever could tamper with the bundle could also
// delete the DoppelPinnedRequirement key, re-seal ad hoc, and be checked
// against the far weaker identifier-only fallback. The install path is chosen
// by the person launching the app, so a tampered bundle cannot restate it.
static NSString *recorded_requirement(NSString *bundlePath) {
    const char *utf8 = bundlePath.fileSystemRepresentation;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }

    NSString *path = [NSString pathWithComponents:@[
        NSHomeDirectory(), @"Library", @"Application Support", @"Doppel", @"pins", hex]];
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    contents = [contents stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return contents.length > 0 ? contents : nil;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *bundlePath = NSBundle.mainBundle.bundlePath;
        NSString *enginePath = [NSBundle.mainBundle.resourcePath
            stringByAppendingPathComponent:@"Doppel/doppel-engine.zsh"];

        // Finder may attach these directory-only attributes after installation.
        // They are not executable content, but strict code validation rejects them.
        removexattr(bundlePath.fileSystemRepresentation, "com.apple.FinderInfo", 0);
        removexattr(bundlePath.fileSystemRepresentation, "com.apple.ResourceFork", 0);

        // Validate against a pinned requirement, not just internal
        // consistency: a NULL requirement would accept any bundle that had been
        // re-sealed with an arbitrary signature after tampering.
        //
        // The requirement recorded outside the bundle wins. Only when there is
        // none — an instance built before pins existed, or one signed ad hoc
        // because no local identity exists — does this fall back to what the
        // bundle says about itself.
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *requirementText = recorded_requirement(bundlePath);
        if (requirementText == nil) {
            NSString *expectedIdentifier = info[@"DoppelSigningIdentifier"];
            if (expectedIdentifier.length == 0) {
                show_error(@"This bundle does not record its expected signing identifier. No engine code was executed.");
                return 1;
            }
            requirementText = info[@"DoppelPinnedRequirement"];
            if (requirementText.length == 0) {
                requirementText = [NSString stringWithFormat:@"identifier \"%@\"", expectedIdentifier];
            }
        }

        SecRequirementRef requirement = NULL;
        OSStatus validationStatus = SecRequirementCreateWithString(
            (__bridge CFStringRef)requirementText, kSecCSDefaultFlags, &requirement);
        SecStaticCodeRef staticCode = NULL;
        if (validationStatus == errSecSuccess) {
            validationStatus = SecStaticCodeCreateWithPath(
                (__bridge CFURLRef)[NSURL fileURLWithPath:bundlePath],
                kSecCSDefaultFlags,
                &staticCode
            );
        }
        if (validationStatus == errSecSuccess) {
            validationStatus = SecStaticCodeCheckValidity(staticCode, kSecCSStrictValidate, requirement);
        }
        if (staticCode != NULL) {
            CFRelease(staticCode);
        }
        if (requirement != NULL) {
            CFRelease(requirement);
        }
        if (validationStatus != errSecSuccess) {
            show_error([NSString stringWithFormat:@"The bundle failed its signature check (error %d). No engine code was executed.", (int)validationStatus]);
            return 1;
        }

        if (![[NSFileManager defaultManager] isExecutableFileAtPath:enginePath]) {
            show_error([NSString stringWithFormat:@"The self-healing engine is missing:\n%@", enginePath]);
            return 1;
        }

        // The engine invokes this mode only after its health check (and any
        // rebuild) has completed. Requesting against the old ad-hoc signature
        // immediately before a rebuild would make the new grant stale.
        if (argc == 2 && strcmp(argv[1], "--doppel-request-permissions") == 0) {
            request_missing_permissions();
            return 0;
        }

        char **engineArgv = calloc((size_t)argc + 4, sizeof(char *));
        if (engineArgv == NULL) {
            show_error(@"The launcher could not allocate its argument list.");
            return 1;
        }

        engineArgv[0] = "/bin/zsh";
        engineArgv[1] = (char *)enginePath.fileSystemRepresentation;
        engineArgv[2] = "launch";
        engineArgv[3] = (char *)bundlePath.fileSystemRepresentation;
        for (int index = 1; index < argc; index++) {
            engineArgv[index + 3] = argv[index];
        }
        engineArgv[argc + 3] = NULL;

        execv(engineArgv[0], engineArgv);
        int launchError = errno;
        free(engineArgv);
        show_error([NSString stringWithFormat:@"The self-healing engine could not be executed (error %d).", launchError]);
        return launchError;
    }
}
