#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <mach/mach_time.h>

typedef struct {
    float x, y, w, h;
    float vpW, vpH;
} Uniforms;

static const char *shaderSource =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct Uniforms {\n"
    "    float x, y, w, h;\n"
    "    float vpW, vpH;\n"
    "};\n"
    "\n"
    "struct V2F {\n"
    "    float4 pos [[position]];\n"
    "};\n"
    "\n"
    "vertex V2F vert_main(uint vid [[vertex_id]],\n"
    "                     constant Uniforms &u [[buffer(0)]]) {\n"
    "    float2 corners[6] = {\n"
    "        float2(u.x,       u.y),\n"
    "        float2(u.x + u.w, u.y),\n"
    "        float2(u.x,       u.y + u.h),\n"
    "        float2(u.x + u.w, u.y),\n"
    "        float2(u.x + u.w, u.y + u.h),\n"
    "        float2(u.x,       u.y + u.h),\n"
    "    };\n"
    "    float2 p = corners[vid];\n"
    "    float2 ndc = float2(2.0 * p.x / u.vpW - 1.0,\n"
    "                        1.0 - 2.0 * p.y / u.vpH);\n"
    "    V2F out;\n"
    "    out.pos = float4(ndc, 0.0, 1.0);\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 frag_main() {\n"
    "    return float4(1.0, 0.2, 0.1, 1.0);\n"
    "}\n";

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@interface MetalView : NSView <CAMetalDisplayLinkDelegate>
{
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    CAMetalLayer *_metalLayer;
    CAMetalDisplayLink *_displayLink;
}
@end

@implementation MetalView

- (instancetype)initWithFrame:(NSRect)frame device:(id<MTLDevice>)device {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    _device = device;
    _commandQueue = [device newCommandQueue];

    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.displaySyncEnabled = NO;
    _metalLayer.maximumDrawableCount = 2;
    _metalLayer.presentsWithTransaction = YES;
    _metalLayer.opaque = YES;

    self.layer = _metalLayer;
    NSError *err = nil;
    NSString *src = [NSString stringWithUTF8String:shaderSource];
    id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
    if (!lib) {
        NSLog(@"Shader compile error: %@", err);
        exit(1);
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [lib newFunctionWithName:@"vert_main"];
    desc.fragmentFunction = [lib newFunctionWithName:@"frag_main"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!_pipeline) {
        NSLog(@"Pipeline error: %@", err);
        exit(1);
    }

    return self;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        [_displayLink invalidate];
        _displayLink = nil;
        return;
    }

    _metalLayer.contentsScale = self.window.backingScaleFactor;

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(windowDidEnterFullScreen:)
        name:NSWindowDidEnterFullScreenNotification object:self.window];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(windowDidExitFullScreen:)
        name:NSWindowDidExitFullScreenNotification object:self.window];

    NSInteger maxFPS = (NSInteger)self.window.screen.maximumFramesPerSecond;

    _displayLink = [[CAMetalDisplayLink alloc] initWithMetalLayer:_metalLayer];
    _displayLink.delegate = self;
    _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(maxFPS, maxFPS, maxFPS);
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    id<CAMetalDrawable> drawable = update.drawable;
    if (!drawable) return;

    CFTimeInterval deadline = update.targetTimestamp;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval wakeAt = deadline - 0.003; // this is a bit of a hack, you should instead measure the average time it takes to render and give youself at least that amount of time
    if (wakeAt > now) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        uint64_t duration = (uint64_t)((wakeAt - now) * 1e9) * tb.denom / tb.numer;
        mach_wait_until(mach_absolute_time() + duration);
    }

    NSPoint windowPt = self.window.mouseLocationOutsideOfEventStream;
    NSPoint viewPt = [self convertPoint:windowPt fromView:nil];
    NSPoint backingPt = [self convertPointToBacking:viewPt];
    CGSize drawableSize = _metalLayer.drawableSize;

    float mx = backingPt.x;
    float my = drawableSize.height - backingPt.y;

    static const int RECT_SIZE = 40;
    Uniforms u;
    u.x = mx - RECT_SIZE / 2.0f;
    u.y = my - RECT_SIZE / 2.0f;
    u.w = RECT_SIZE;
    u.h = RECT_SIZE;
    u.vpW = drawableSize.width;
    u.vpH = drawableSize.height;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = drawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1, 1, 1.0);

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
    [enc setRenderPipelineState:_pipeline];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];

    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (!self.window) return;
    CGFloat scale = self.window.backingScaleFactor;
    _metalLayer.drawableSize = CGSizeMake(newSize.width * scale, newSize.height * scale);
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)windowDidEnterFullScreen:(NSNotification *)note {
    _metalLayer.displaySyncEnabled = YES;
}

- (void)windowDidExitFullScreen:(NSNotification *)note {
    // when not fullscreen, the compositor handles syncing with the display.
    _metalLayer.displaySyncEnabled = NO;
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    if (self.window) {
        _metalLayer.contentsScale = self.window.backingScaleFactor;
    }
}

@end

@implementation AppDelegate {
    NSWindow *_window;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        NSLog(@"No Metal device");
        exit(1);
    }

    NSRect screenFrame = [NSScreen mainScreen].frame;
    NSWindowStyleMask style= NSWindowStyleMaskClosable
                       | NSWindowStyleMaskTitled
                       | NSWindowStyleMaskMiniaturizable
                       | NSWindowStyleMaskResizable;
    _window = [[NSWindow alloc] initWithContentRect:screenFrame
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO];

    MetalView *view = [[MetalView alloc] initWithFrame:screenFrame device:device];
    _window.contentView = view;
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:view];
    [_window toggleFullScreen:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
