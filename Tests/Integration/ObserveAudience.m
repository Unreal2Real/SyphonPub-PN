// Rehearsal-only receiver. It never starts the publisher or captures a display.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <Syphon/Syphon.h>
#import <stdatomic.h>

static const char *frontApp(void) {
    NSString *bundle = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    if ([bundle isEqualToString:@"com.figure53.QLab.5"]) return "QLab";
    if ([bundle isEqualToString:@"com.apple.Keynote"] || [bundle isEqualToString:@"com.apple.iWork.Keynote"]) return "Keynote";
    if ([bundle isEqualToString:@"com.microsoft.Powerpoint"]) return "PowerPoint";
    return bundle ? "other" : "unknown";
}

// Compare uniformly spaced rows. A change is evidence of new pixels; lack of a
// change is meaningful only for a known moving test pattern crossing these rows.
static BOOL sampleRows(id<MTLTexture> frame, id<MTLCommandQueue> queue,
                       id<MTLBuffer> buffer, NSUInteger stride, NSUInteger rows) {
    id<MTLCommandBuffer> commands = queue.commandBuffer;
    id<MTLBlitCommandEncoder> copy = commands.blitCommandEncoder;
    if (!copy) return NO;
    for (NSUInteger row = 0; row < rows; row++) {
        NSUInteger y = (2 * row + 1) * frame.height / (2 * rows);
        [copy copyFromTexture:frame sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, y, 0)
                   sourceSize:MTLSizeMake(frame.width, 1, 1) toBuffer:buffer destinationOffset:row * stride
       destinationBytesPerRow:stride destinationBytesPerImage:stride];
    }
    [copy endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    return commands.status == MTLCommandBufferStatusCompleted;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        char *end = NULL;
        long seconds = argc >= 2 ? strtol(argv[1], &end, 10) : 0;
        NSString *name = @"SyphonPub Show Follow — Audience";
        if (argc == 3 && [@(argv[2]) hasPrefix:@"SyphonPub-QA-"]) name = @(argv[2]);
        else if (argc != 2) seconds = 0;
        if (seconds < 1 || seconds > 3600 || *end) {
            fputs("Usage: observe-audience SECONDS [SyphonPub-QA-fixture-name] (1–3600 seconds)\n", stderr);
            return 64;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = device.newCommandQueue;
        if (!queue) { fputs("Metal unavailable\n", stderr); return 69; }
        SyphonServerDirectory *directory = SyphonServerDirectory.sharedDirectory;
        SyphonMetalClient *client = nil;
        __block atomic_uint notifications = 0;
        id<MTLBuffer> previous = nil, next = nil;
        NSUInteger width = 0, height = 0;
        BOOL haveSample = NO, everSampled = NO;
        NSProcessInfo *clock = NSProcessInfo.processInfo;
        double start = clock.systemUptime;
        puts("elapsed_s,front_app,notifications,width,height,observation,sampled_rgb_black");
        do {
            @autoreleasepool {
                const char *observation = "awaiting_server";
                const char *black = "";
                unsigned count = 0;
                if (!client) {
                    NSArray *matches = [directory serversMatchingName:name appName:nil];
                    if (matches.count > 1) { fputs("Multiple servers with exact name\n", stderr); return 2; }
                    if (matches.count == 1) {
                        client = [[SyphonMetalClient alloc] initWithServerDescription:matches.firstObject
                            device:device options:nil newFrameHandler:^(SyphonMetalClient *unused) {
                                atomic_fetch_add(&notifications, 1);
                            }];
                        if (!client) { fputs("Cannot create Syphon client\n", stderr); return 2; }
                    }
                }
                if (client) {
                    if (!client.isValid) { fputs("Server disconnected\n", stderr); return 2; }
                    count = atomic_exchange(&notifications, 0);
                    id<MTLTexture> frame = [client newFrameImage];
                    observation = "no_texture";
                    if (frame) {
                        if (frame.pixelFormat != MTLPixelFormatBGRA8Unorm && frame.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) {
                            fputs("Unexpected pixel format\n", stderr); return 3;
                        }
                        NSUInteger stride = (frame.width * 4 + 255) & ~(NSUInteger)255;
                        NSUInteger rows = MIN(16, frame.height);
                        if (frame.width != width || frame.height != height) {
                            width = frame.width;
                            height = frame.height;
                            previous = [device newBufferWithLength:stride * rows options:MTLResourceStorageModeShared];
                            next = [device newBufferWithLength:stride * rows options:MTLResourceStorageModeShared];
                            if (!previous || !next) { fputs("Sample buffers unavailable\n", stderr); return 3; }
                            haveSample = NO;
                        }
                        if (!sampleRows(frame, queue, next, stride, rows)) { fputs("GPU copy failed\n", stderr); return 3; }
                        BOOL changed = NO, allBlack = YES;
                        for (NSUInteger row = 0; row < rows; row++) {
                            const uint32_t *pixels = (const uint32_t *)((const char *)next.contents + row * stride);
                            const char *old = (const char *)previous.contents + row * stride;
                            if (haveSample && memcmp(old, pixels, width * 4)) changed = YES;
                            for (NSUInteger x = 0; allBlack && x < width; x++) {
                                if (pixels[x] & 0x00ffffff) allBlack = NO;
                            }
                        }
                        observation = !haveSample ? "first_at_size" : changed ? "changed" : "same";
                        black = allBlack ? "yes" : "no";
                        id<MTLBuffer> swap = previous;
                        previous = next;
                        next = swap;
                        haveSample = everSampled = YES;
                    }
                }
                printf("%.3f,%s,%u,%lu,%lu,%s,%s\n", clock.systemUptime - start, frontApp(), count,
                       (unsigned long)(black[0] ? width : 0), (unsigned long)(black[0] ? height : 0), observation, black);
                fflush(stdout);
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.25]];
            }
        } while (clock.systemUptime - start < seconds);
        [client stop];
        return everSampled ? 0 : 2;
    }
}
