// Renders an app's Dock and Finder icon the way macOS draws it in light and in
// dark appearance, so QA can see whether an icon actually follows dark mode.
// Drawing NSWorkspace's icon under a different NSAppearance does not work: the
// appearance is resolved when the icon is created. IconServices, the private
// framework behind the Dock and Finder, takes the appearance per request.
//
//   icon-appearance <app> <output dir>
//     writes light.png and dark.png and prints, per appearance,
//     the average colour and mean luminance (0-255) of the opaque pixels.
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/message.h>

static void report(CGImageRef image, NSString *name, NSString *directory) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSString *path = [directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];

    size_t width = 64, height = 64;
    uint8_t *pixels = calloc(width * height * 4, 1);
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4,
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB), (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    double r = 0, g = 0, b = 0, n = 0;
    for (size_t i = 0; i < width * height * 4; i += 4) {
        if (pixels[i + 3] < 200) continue;
        r += pixels[i]; g += pixels[i + 1]; b += pixels[i + 2]; n += 1;
    }
    free(pixels);
    CGContextRelease(context);
    if (n == 0) { printf("%s none 0\n", name.UTF8String); return; }
    r /= n; g /= n; b /= n;
    printf("%s #%02X%02X%02X %.0f\n", name.UTF8String, (int)r, (int)g, (int)b,
           0.2126 * r + 0.7152 * g + 0.0722 * b);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: icon-appearance <app> <output dir>\n"); return 2; }
        if (!dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW)) return 1;
        NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
        id icon = ((id (*)(id, SEL, id))objc_msgSend)(
            [NSClassFromString(@"ISBundleIcon") alloc], @selector(initWithBundleURL:), url);
        if (!icon) return 1;
        NSString *directory = @(argv[2]);
        NSArray *names = @[@"light", @"dark"];
        for (long appearance = 0; appearance < 2; appearance++) {
            id descriptor = ((id (*)(id, SEL, CGSize, CGFloat))objc_msgSend)(
                [NSClassFromString(@"ISImageDescriptor") alloc], @selector(initWithSize:scale:),
                CGSizeMake(256, 256), 1);
            ((void (*)(id, SEL, long))objc_msgSend)(descriptor, @selector(setAppearance:), appearance);
            // Without preparing first, IconServices hands back its placeholder.
            ((void (*)(id, SEL, id))objc_msgSend)(icon, @selector(prepareImagesForImageDescriptors:), @[descriptor]);
            CGImageRef image = ((CGImageRef (*)(id, SEL, id))objc_msgSend)(
                icon, @selector(CGImageForDescriptor:), descriptor);
            if (!image) return 1;
            report(image, names[appearance], directory);
        }
    }
    return 0;
}
