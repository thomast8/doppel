#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
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
        // re-sealed with an arbitrary signature after tampering. The instance's
        // own signing identifier is pinned here; when the bundle was signed with
        // a stable identity, DoppelPinnedRequirement adds the certificate leaf.
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *expectedIdentifier = info[@"DoppelSigningIdentifier"];
        if (expectedIdentifier.length == 0) {
            show_error(@"This bundle does not record its expected signing identifier. No engine code was executed.");
            return 1;
        }
        NSString *requirementText = info[@"DoppelPinnedRequirement"];
        if (requirementText.length == 0) {
            requirementText = [NSString stringWithFormat:@"identifier \"%@\"", expectedIdentifier];
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
