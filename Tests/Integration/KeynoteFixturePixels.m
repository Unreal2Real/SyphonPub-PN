#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Syphon/Syphon.h>

typedef struct {
    float x, y;
    uint8_t r, g, b;
} Patch;
// Four corner fields, central band at its plain right edge. Avoid the printed labels.
static const Patch patches[] = {
    {.1, .30, 213, 65, 54}, {.40, .32, 213, 65, 54}, {.60, .30, 33, 122, 80},  {.90, .32, 33, 122, 80},
    {.1, .66, 28, 87, 162}, {.40, .64, 28, 87, 162}, {.60, .66, 250, 222, 84}, {.90, .64, 250, 222, 84},
    {.97, .48, 17, 37, 52}, {.97, .52, 17, 37, 52}};
enum { N = sizeof(patches) / sizeof(Patch) };
typedef struct {
    uint8_t b, g, r, a;
} Pixel;
static NSString *classify(Pixel *pixels) {
    unsigned matched = 0, black = 0;
    for (int i = 0; i < N; i++) {
        Patch k = patches[i];
        Pixel p = pixels[i];
        matched += abs(p.r - k.r) <= 28 && abs(p.g - k.g) <= 28 && abs(p.b - k.b) <= 28;
        black += p.r <= 4 && p.g <= 4 && p.b <= 4;
    }
    return matched == N ? @"fixture-page1-patches"
           : black == N ? @"sampled-black"
                        : [NSString stringWithFormat:@"other(%u/%d-patches)", matched, N];
}
static void spin(double t) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:t]];
}
static NSString *inspectWindow(SCWindow *window) {
    SCStreamConfiguration *cfg = [SCStreamConfiguration new];
    CGRect rect = window.frame;
    cfg.width = 320;
    cfg.height = MAX(1, lround(320 * rect.size.height / rect.size.width));
    cfg.pixelFormat = kCVPixelFormatType_32BGRA;
    cfg.showsCursor = NO;
    cfg.ignoreShadowsSingleWindow = YES;
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
    __block NSString *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [SCScreenshotManager
        captureSampleBufferWithFilter:filter
                        configuration:cfg
                    completionHandler:^(CMSampleBufferRef frame, NSError *error) {
                      CVPixelBufferRef image = frame ? CMSampleBufferGetImageBuffer(frame) : NULL;
                      if (image && CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA &&
                          CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) ==
                              kCVReturnSuccess) {
                          const uint8_t *bytes = CVPixelBufferGetBaseAddress(image);
                          size_t w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image),
                                 stride = CVPixelBufferGetBytesPerRow(image);
                          Pixel pixels[N];
                          for (int i = 0; i < N; i++)
                              pixels[i] = *(const Pixel *)(bytes + (size_t)(patches[i].y * h) * stride +
                                                           4 * (size_t)(patches[i].x * w));
                          result = classify(pixels);
                          CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
                      } else
                          result = [NSString stringWithFormat:@"capture-error-%ld", (long)error.code];
                      dispatch_semaphore_signal(done);
                    }];
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))
               ? @"capture-timeout"
               : result;
}
static NSString *syphonFrame(id<MTLTexture> t, id<MTLCommandQueue> q) {
    if (!t)
        return @"no-texture";
    if (t.pixelFormat != MTLPixelFormatBGRA8Unorm && t.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB)
        return @"unsupported-format";
    id<MTLBuffer> b = [q.device newBufferWithLength:256 * N options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> c = q.commandBuffer;
    id<MTLBlitCommandEncoder> e = c.blitCommandEncoder;
    if (!b || !e)
        return @"gpu-unavailable";
    for (int i = 0; i < N; i++) {
        // The production publisher uses flipped:YES for Syphon textures.
        MTLOrigin o = MTLOriginMake((NSUInteger)(t.width * patches[i].x),
                                    t.height - 1 - (NSUInteger)(t.height * patches[i].y), 0);
        [e copyFromTexture:t
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:o
                          sourceSize:MTLSizeMake(1, 1, 1)
                            toBuffer:b
                   destinationOffset:256 * i
              destinationBytesPerRow:256
            destinationBytesPerImage:256];
    }
    [e endEncoding];
    [c commit];
    [c waitUntilCompleted];
    if (c.status != MTLCommandBufferStatusCompleted)
        return @"gpu-error";
    Pixel pixels[N];
    for (int i = 0; i < N; i++)
        pixels[i] = *(const Pixel *)((const uint8_t *)b.contents + 256 * i);
    return classify(pixels);
}
static BOOL allowed(NSString *title, NSString *base) {
    return [title isEqualToString:base] ||
           [title isEqualToString:[base stringByAppendingString:@".pptx"]] ||
           [title isEqualToString:[base stringByAppendingString:@".key"]];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *base = argc == 3 ? @(argv[2]) : @"";
        if (!([base isEqualToString:@"SyphonPub-Diag-29A"] ||
              [base isEqualToString:@"SyphonPub-Keynote-Audience-QA"]))
            return 64;
        int duration = atoi(argv[1]);
        if (duration < 1 || duration > 480)
            return 64;
        if (!CGPreflightScreenCaptureAccess()) {
            puts("Screen recording not preauthorized for this diagnostic");
            return 77;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = device.newCommandQueue;
        if (!q)
            return 69;
        SyphonServerDirectory *dir = SyphonServerDirectory.sharedDirectory;
        SyphonMetalClient *client = nil;
        NSISO8601DateFormatter *clock = [NSISO8601DateFormatter new];
        clock.timeZone = NSTimeZone.localTimeZone;
        clock.formatOptions =
            NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:duration];
        setbuf(stdout, NULL);
        while (end.timeIntervalSinceNow > 0)
            @autoreleasepool {
                __block NSArray<SCWindow *> *windows = nil;
                dispatch_semaphore_t wait = dispatch_semaphore_create(0);
                [SCShareableContent
                    getShareableContentExcludingDesktopWindows:YES
                                           onScreenWindowsOnly:NO
                                             completionHandler:^(SCShareableContent *content,
                                                                 NSError *error) {
                                               (void)error;
                                               windows = content.windows;
                                               dispatch_semaphore_signal(wait);
                                             }];
                if (dispatch_semaphore_wait(wait, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) ||
                    !windows) {
                    puts("enumeration-failed");
                    return 2;
                }
                NSString *stamp = [clock stringFromDate:NSDate.date];
                int visible = 0, offscreen = 0;
                for (SCWindow *w in windows) {
                    NSString *id = w.owningApplication.bundleIdentifier;
                    if (!([id isEqualToString:@"com.apple.Keynote"] ||
                          [id isEqualToString:@"com.apple.iWork.Keynote"]) ||
                        !allowed(w.title, base) || w.frame.size.width < 160 || w.frame.size.height < 90)
                        continue;
                    if (!w.isOnScreen) {
                        offscreen++;
                        continue;
                    }
                    visible++;
                    printf("%s SCK id=%u layer=%ld size=%.0fx%.0f %s\n", stamp.UTF8String, w.windowID,
                           (long)w.windowLayer, w.frame.size.width, w.frame.size.height,
                           inspectWindow(w).UTF8String);
                }
                if (!client.isValid) {
                    [client stop];
                    client = nil;
                    NSArray *descs = [dir serversMatchingName:@"SyphonPub Show Follow — Audience"
                                                      appName:@"SyphonPub PN"];
                    if (descs.count == 1)
                        client = [[SyphonMetalClient alloc] initWithServerDescription:descs[0]
                                                                               device:device
                                                                              options:nil
                                                                      newFrameHandler:nil];
                }
                id<MTLTexture> tex = [client newFrameImage];
                NSUInteger manual = 0, automatic = 0;
                for (NSDictionary *entry in [dir serversMatchingName:nil
                                                             appName:@"SyphonPub PN"]) {
                    NSString *name = entry[SyphonServerDescriptionNameKey];
                    if ([name isEqualToString:@"SyphonPub Show Follow — Audience"])
                        automatic++;
                    else
                        manual++;
                }
                printf(
                    "%s eligible=%d hidden=%d auto=%lu other-test-sources=%lu syphon=%s size=%lux%lu\n",
                    stamp.UTF8String, visible, offscreen, (unsigned long)automatic,
                    (unsigned long)manual, client ? syphonFrame(tex, q).UTF8String : "no-server",
                    (unsigned long)tex.width, (unsigned long)tex.height);
                spin(.6);
            }
        [client stop];
    }
}
