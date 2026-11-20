// Standalone receiver. Only attaches to a unique test server created by the fixture.
// The pixel readback is for this assertion process only, never the publishing app.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <Syphon/Syphon.h>
#import <stdatomic.h>

static double now(void) { return NSProcessInfo.processInfo.systemUptime; }
static void pump(double seconds) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// Read two sparse pixels from the received IOSurface, even if its texture is private.
typedef NS_ENUM(NSInteger, FixturePattern) { PatternUnknown, PatternA, PatternB, PatternBlack };

static FixturePattern readPattern(id<MTLTexture> frame, id<MTLCommandQueue> queue, id<MTLBuffer> buffer) {
    if (!frame || frame.pixelFormat != MTLPixelFormatBGRA8Unorm) return PatternUnknown;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    for (NSUInteger i = 0; i < 2; i++) {
        NSUInteger row = i ? (3 * frame.height / 4) : (frame.height / 4);
        [blit copyFromTexture:frame sourceSlice:0 sourceLevel:0
                 sourceOrigin:MTLOriginMake(frame.width / 2, row, 0) sourceSize:MTLSizeMake(1, 1, 1)
                     toBuffer:buffer destinationOffset:i * 256
       destinationBytesPerRow:256 destinationBytesPerImage:256];
    }
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) return PatternUnknown;
    // With upstream's flipped:YES, red on the top input half appears on the bottom texture half.
    const uint32_t *p = buffer.contents;
    if (p[0] == 0xff00ff00 && p[64] == 0xffff0000) return PatternA;
    if (p[0] == 0xffff00ff && p[64] == 0xff0000ff) return PatternB;
    if (p[0] == 0xff000000 && p[64] == 0xff000000) return PatternBlack;
    return PatternUnknown;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL following = argc == 3 && strcmp(argv[2], "follow") == 0;
        if (!following && argc != 6 && argc != 7) return 64;
        BOOL expectBlank = argc == 7 && strcmp(argv[6], "empty") == 0;
        NSString *name = @(argv[1]);
        if (![name hasPrefix:@"SyphonPub-QA-"]) return 64;
        int width = following ? 0 : atoi(argv[2]), height = following ? 0 : atoi(argv[3]);
        BOOL alternate = !following && atoi(argv[4]) != 0;
        double duration = following ? 0 : atof(argv[5]);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "Metal device unavailable\n"); return 69; }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLBuffer> buffer = [device newBufferWithLength:512 options:MTLResourceStorageModeShared];
        SyphonServerDirectory *dir = [SyphonServerDirectory sharedDirectory];
        double begin = now();
        NSDictionary *description;
        do {
            description = [dir serversMatchingName:name appName:nil].firstObject;
            if (!description) pump(.005);
        } while (!description && now() - begin < 8);
        if (!description) { fprintf(stderr, "Fixture server was not discovered\n"); return 2; }
        double connectTime = now();
        __block atomic_uint count = 0;
        SyphonMetalClient *client = [[SyphonMetalClient alloc] initWithServerDescription:description device:device options:nil newFrameHandler:^(SyphonMetalClient *c) {
            atomic_fetch_add(&count, 1);
        }];
        if (following) {
            printf("SERVER %s\n", [description[SyphonServerDescriptionUUIDKey] UTF8String]);
            fflush(stdout);
            FixturePattern previous = PatternUnknown;
            unsigned events = 0;
            while (now() - connectTime < 60) {
                @autoreleasepool {
                    pump(.003);
                    unsigned observed = atomic_load(&count);
                    if (observed == events) continue;
                    events = observed;
                    id<MTLTexture> frame = [client newFrameImage];
                    if (!frame) continue;
                    FixturePattern current = readPattern(frame, queue, buffer);
                    if (current == PatternUnknown) return 5;
                    if (current != previous) {
                        printf("%s %lux%lu\n", current == PatternBlack ? "BLACK" : current == PatternA ? "A" : "B",
                               (unsigned long)frame.width, (unsigned long)frame.height);
                        fflush(stdout);
                        previous = current;
                    }
                }
            }
            [client stop];
            return 0;
        }
        double first = 0, lastVerified = 0, lastEvent = connectTime, maxGap = 0;
        unsigned previousCount = 0, verified = 0;
        BOOL sawTexture = NO;
        while (now() - connectTime < (first || expectBlank ? duration : 5)) {
            @autoreleasepool {
                pump(first ? .01 : .002);
                unsigned events = atomic_load(&count);
                if (events == previousCount) continue;
                previousCount = events;
                double t = now();
                if (first) maxGap = MAX(maxGap, t - lastEvent);
                lastEvent = t;
                if (first && t - lastVerified < .5) continue;
                id<MTLTexture> frame = [client newFrameImage];
                if (frame) sawTexture = YES;
                if (frame.width == width && frame.height == height && readPattern(frame, queue, buffer) == (alternate ? PatternB : PatternA)) {
                    if (!first) first = now();
                    lastVerified = now();
                    verified++;
                } else if (first) {
                    fprintf(stderr, "Received wrong size or color after first matching frame\n");
                    return 3;
                }
            }
        }
        maxGap = MAX(maxGap, now() - lastEvent);
        if (expectBlank && [client newFrameImage]) sawTexture = YES;
        [client stop];
        printf("{\"discovery_ms\":%.3f,\"first_correct_ms\":%.3f,\"duration_s\":%.3f,\"events\":%u,\"pixel_checks\":%u,\"max_gap_ms\":%.3f}\n",
               1000*(connectTime-begin), first ? 1000*(first-connectTime) : -1, now()-connectTime, atomic_load(&count), verified, maxGap*1000);
        if (expectBlank) return sawTexture ? 5 : 0;
        return first && first - connectTime <= 1 && maxGap <= 1 ? 0 : 4;
    }
}
