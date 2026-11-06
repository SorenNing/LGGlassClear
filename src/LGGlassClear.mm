// LGGlassClear —— 把 SystemBox 的「清除」按钮换成航式液态玻璃（Metal 渲染）
// 运行在 SpringBoard：不注入 backboardd，不动 CA 滤镜，失败自动回退原生材质。
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define LGC_LOG(fmt, ...) [LGC log:[NSString stringWithFormat:fmt, ##__VA_ARGS__]]

static const int kGlassTag = 0x4C474331;   // 'LGC1'

@interface LGC : NSObject
@end
@implementation LGC
+ (void)log:(NSString *)m {
    static NSDateFormatter *f = nil;
    static dispatch_once_t once; dispatch_once(&once, ^{
        f = [NSDateFormatter new]; f.dateFormat = @"MM-dd HH:mm:ss";
    });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], m];
    NSString *p = @"/var/mobile/Library/Accessibility/lgglassclear.log";
    FILE *fp = fopen(p.UTF8String, "a");
    if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
}
@end

#pragma mark - uniforms（与 glass.metal 的 LiquidUniforms 完全对应，112 字节）

typedef struct {
    vector_float4 viewport;      // xy=底图像素尺寸, zw=按钮在底图中的像素原点
    vector_float4 geometry;      // xy=按钮像素尺寸, z=圆角, w=边缘带宽
    vector_float4 optical;       // x=折射高度, y=折射率, z=折射强度, w=采样模糊半径
    vector_float4 appearance;    // x=高光强度, y=饱和度, z=tint 比例, w=内阴影模糊
    vector_float4 tint;          // rgb=tint 颜色, a=保留
    vector_float4 innerShadow;   // rgb=内阴影颜色, w=扩散
    vector_float4 misc;          // y=高度曲线模式
} LGUniforms;

#pragma mark - 玻璃视图

@interface LGGlassView : MTKView
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) MTLTexture *bgTex;
@property (nonatomic) CGPoint bgOrigin;        // 按钮在底图中的像素坐标（左上为原点）
@property (nonatomic) CGSize  bgSize;          // 底图像素尺寸
@property (nonatomic) float scale;
@end

@implementation LGGlassView

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return nil;
    self.device = dev;
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO;
    self.framebufferOnly = NO;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.paused = YES;
    self.enableSetNeedsDisplay = YES;
    self.queue = [dev newCommandQueue];

    NSError *err = nil;
    id<MTLLibrary> lib = [self loadLibrary:&err];
    if (!lib) { LGC_LOG(@"metallib 加载失败: %@", err); return nil; }
    id<MTLFunction> vf = [lib newFunctionWithName:@"lgGlassVertex"];
    id<MTLFunction> ff = [lib newFunctionWithName:@"lgGlassFragment"];
    if (!vf || !ff) { LGC_LOG(@"找不到着色器函数"); return nil; }

    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vf;
    d.fragmentFunction = ff;
    d.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    self.pipeline = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!self.pipeline) { LGC_LOG(@"管线创建失败: %@", err); return nil; }
    return self;
}

- (id<MTLLibrary>)loadLibrary:(NSError **)err {
    Dl_info info;
    if (dladdr((void *)&OBJC_CLASS___LGC, &info) && info.dli_fname) {
        NSString *dir = [NSString stringWithUTF8String:info.dli_fname].stringByDeletingLastPathComponent;
        for (NSString *rel in @[@"../../share/glassclear/default.metallib",
                                @"../share/glassclear/default.metallib"]) {
            NSString *p = [dir stringByAppendingPathComponent:rel];
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
                return [self.device newLibraryWithFile:p error:err];
            }
        }
    }
    // 兜底：系统共享目录
    NSString *alt = @"/var/jb/usr/share/glassclear/default.metallib";
    if ([[NSFileManager defaultManager] fileExistsAtPath:alt])
        return [self.device newLibraryWithFile:alt error:err];
    if (err) *err = [NSError errorWithDomain:@"LGC" code:1
                                   userInfo:@{NSLocalizedDescriptionKey: @"metallib not found"}];
    return nil;
}

- (void)setBackdropImage:(UIImage *)img origin:(CGPoint)origin {
    CGImageRef cg = img.CGImage;
    if (!cg) return;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (!w || !h) return;

    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [self.device newTextureWithDescriptor:td];
    if (!tex) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    void *buf = calloc(w * h * 4, 1);
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0
               withBytes:buf bytesPerRow:w * 4];
        CGContextRelease(ctx);
    }
    free(buf);
    CGColorSpaceRelease(cs);
    self.bgTex = tex;
    self.bgSize = CGSizeMake(w, h);
    // 截图是 UIKit 坐标（左上原点），与纹理一致，只需按 scale 换算到像素
    self.bgOrigin = CGPointMake(origin.x, origin.y);
    [self setNeedsDisplay];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (!self.pipeline || !self.bgTex) return;
    id<CAMetalDrawable> dr = self.currentDrawable;
    MTLRenderPassDescriptor *rp = self.currentRenderPassDescriptor;
    if (!dr || !rp) return;

    float s = self.scale ?: (float)self.window.screen.scale ?: 3.0f;
    float w = (float)(self.bounds.size.width  * s);
    float h = (float)(self.bounds.size.height * s);
    if (w < 2 || h < 2) return;

    LGUniforms u;
    memset(&u, 0, sizeof(u));
    u.viewport     = (vector_float4){ (float)self.bgSize.width, (float)self.bgSize.height,
                                      (float)self.bgOrigin.x * s, (float)self.bgOrigin.y * s };
    float radius   = h * 0.5f;
    float bezel    = MAX(3.0f, MIN(h * 0.30f, 14.0f * s));
    u.geometry     = (vector_float4){ w, h, radius, bezel };
    u.optical      = (vector_float4){ 0.0f, 1.52f, 0.85f, 10.0f * s };
    u.appearance   = (vector_float4){ 0.90f, 1.18f, 0.07f, 7.0f * s };
    u.tint         = (vector_float4){ 1.0f, 1.0f, 1.0f, 1.0f };
    u.innerShadow  = (vector_float4){ 0.0f, 0.0f, 0.0f, 2.5f * s };
    u.misc         = (vector_float4){ 0.0f, 0.0f, 0.0f, 0.0f };

    id<MTLCommandBuffer> cb = [self.queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:self.pipeline];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentTexture:self.bgTex atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
    [cb presentDrawable:dr];
    [cb commit];
}
@end

#pragma mark - 按钮装扮

static CGFloat LGStatusBarBottom(void) { return 0; }

static void LGDressButton(UIButton *btn) {
    if (!btn || objc_getAssociatedObject(btn, (void *)&kGlassTag)) return;
    if (btn.bounds.size.width < 20 || btn.bounds.size.height < 10) {
        // 还没布局好，稍后再试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ LGDressButton(btn); });
        return;
    }
    UIWindow *win = btn.window;
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ LGDressButton(btn); });
        return;
    }

    // 1) 先把按钮背后的画面截下来（此时按钮还在，但我们会把它自己排除）
    CGRect inWin = [btn convertRect:btn.bounds toView:win];
    CGFloat alphaBackup = btn.alpha;
    BOOL hiddenFlag = btn.hidden;
    UIVisualEffectView *oldBlur = nil;
    for (UIView *v in btn.subviews) {
        if ([v isKindOfClass:UIVisualEffectView.class]) { oldBlur = (UIVisualEffectView *)v; break; }
    }
    CGFloat oldBlurAlpha = oldBlur.alpha;
    if (oldBlur) oldBlur.alpha = 0;
    btn.alpha = 0;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = win.screen.scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:win.bounds format:fmt];
    UIImage *shot = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
    }];

    btn.alpha = alphaBackup;
    if (oldBlur) oldBlur.alpha = oldBlurAlpha;
    btn.hidden = hiddenFlag;

    if (!shot) { LGC_LOG(@"截图失败，保留原生材质"); return; }

    // 2) 建 Metal 玻璃视图
    LGGlassView *g = [[LGGlassView alloc] initWithFrame:btn.bounds];
    if (!g) { LGC_LOG(@"Metal 初始化失败，保留原生材质"); return; }
    g.scale = (float)win.screen.scale;
    g.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [g setBackdropImage:shot origin:CGPointMake(inWin.origin.x, inWin.origin.y)];

    [btn insertSubview:g atIndex:0];
    if (oldBlur) oldBlur.alpha = 0;          // 原生磨砂让位给 Metal 玻璃
    btn.backgroundColor = UIColor.clearColor;
    btn.clipsToBounds = NO;

    objc_setAssociatedObject(btn, (void *)&kGlassTag, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGC_LOG(@"已装扮清除按钮 %@ glass=%@ blur=%@", NSStringFromCGRect(btn.bounds),
            g ? @"ok" : @"nil", oldBlur ? @"hidden" : @"none");
}

#pragma mark - 注入

static void (*orig_setTitle)(id, SEL, NSString *, UIControlState);

static void my_setTitle(id self, SEL _cmd, NSString *title, UIControlState state) {
    orig_setTitle(self, _cmd, title, state);
    if (![self isKindOfClass:UIButton.class] || !title) return;
    if (![title containsString:@"清除"]) return;
    __weak UIButton *b = (UIButton *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ if (b) LGDressButton(b); });
}

__attribute__((constructor)) static void LGCInit(void) {
    @autoreleasepool {
        Method m = class_getInstanceMethod(UIButton.class, @selector(setTitle:forState:));
        if (!m) { LGC_LOG(@"找不到 setTitle:forState:"); return; }
        orig_setTitle = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)my_setTitle);
        LGC_LOG(@"已安装 hook（SpringBoard）");
    }
}