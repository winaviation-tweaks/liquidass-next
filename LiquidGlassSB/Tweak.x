
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdarg.h>

// springboard logger
static void sblog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sblog(const char *fmt, ...) {
    FILE *f = fopen("/tmp/liquidglass.log", "a");
    if (!f) return;
    fputs("[LGSB] ", f);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

// must match kCustomFilterTypeName in Tweak.mm exactly
static NSString * const kLGFilterType = @"dylv.liquidglass.refraction";

@interface LGLiveBackdropView : UIView
@property (nonatomic, assign) CGFloat blurRadius;
- (instancetype)initWithFrame:(CGRect)frame blurRadius:(CGFloat)radius;
- (void)applyFilters;
- (void)forceReapplyForRegistrationRace;
@end

@implementation LGLiveBackdropView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame blurRadius:(CGFloat)radius {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _blurRadius             = radius;
    self.userInteractionEnabled = NO;
    self.backgroundColor    = [UIColor clearColor];
    self.opaque             = NO;
    [self applyFilters];
    return self;
}

- (void)didMoveToWindow { [super didMoveToWindow]; [self applyFilters]; }
- (void)layoutSubviews  { [super layoutSubviews];  [self applyFilters]; }

- (void)applyFilters {
    CALayer *layer = self.layer;
    Class backdropCls = NSClassFromString(@"CABackdropLayer");
    if (!backdropCls || ![layer isKindOfClass:backdropCls]) return;

    @try {
        [layer setValue:@NO  forKey:@"layerUsesCoreImageFilters"];
        [layer setValue:@YES forKey:@"windowServerAware"];
        if (![layer valueForKey:@"groupName"])
            [layer setValue:@"dylv.liquidglass.sharedGroup" forKey:@"groupName"];

        [layer setValue:@"dylv.liquidglass" forKey:@"groupNamespace"];
        [layer setValue:@(0.5) forKey:@"scale"];

        // skip if filter already set, prevents oom from repeated surface alloc
        NSArray *existing = layer.filters;
        if (existing.count == 1) {
            NSString *type = nil;
            @try { type = [existing[0] valueForKey:@"type"]; } @catch (...) {}
            if ([type isEqualToString:kLGFilterType]) return;
        }

        Class filterCls = NSClassFromString(@"CAFilter");
        if (!filterCls) { sblog("CAFilter class not found"); return; }

        id glassFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), kLGFilterType);

        if (!glassFilter) {
            sblog("applyFilters: filterWithType:%s returned nil (not registered yet?)",
                  kLGFilterType.UTF8String);
            return;
        }

        layer.filters = @[glassFilter];
        sblog("applyFilters: set [%s]", kLGFilterType.UTF8String);
    } @catch (NSException *e) {
        sblog("applyFilters exception: %s", e.reason.UTF8String);
    }
}

- (void)forceReapplyForRegistrationRace {
    CALayer *layer = self.layer;
    Class backdropCls = NSClassFromString(@"CABackdropLayer");
    if (!backdropCls || ![layer isKindOfClass:backdropCls]) return;
    Class filterCls = NSClassFromString(@"CAFilter");
    if (!filterCls) return;
    @try {
        id glassFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), kLGFilterType);
        if (!glassFilter) return;
        layer.filters = @[glassFilter];
        sblog("forceReapply: re-committed filter (defeating registration race)");
    } @catch (NSException *e) {
        sblog("forceReapply exception: %s", e.reason.UTF8String);
    }
}

@end

@interface LGFloatingTestView : UIView {
    LGLiveBackdropView     *_backdropView;
    UIView                 *_specularBorder;
    UIPanGestureRecognizer *_pan;
    CGPoint                 _dragOffset;
}
- (instancetype)initAtCenter:(CGPoint)center size:(CGSize)size;
@end

@implementation LGFloatingTestView

- (instancetype)initAtCenter:(CGPoint)center size:(CGSize)size {
    CGRect frame = CGRectMake(center.x - size.width  / 2,
                              center.y - size.height / 2,
                              size.width, size.height);
    self = [super initWithFrame:frame];
    if (!self) return nil;

    const CGFloat radius = 28.0;

    self.backgroundColor        = [UIColor clearColor];
    self.userInteractionEnabled = YES;
    self.layer.cornerRadius     = radius;
    self.layer.cornerCurve      = kCACornerCurveContinuous;
    self.layer.masksToBounds    = NO;

    _backdropView = [[LGLiveBackdropView alloc] initWithFrame:self.bounds
                                                   blurRadius:8.0];
    _backdropView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _backdropView.layer.cornerRadius  = radius;
    _backdropView.layer.cornerCurve   = kCACornerCurveContinuous;
    _backdropView.layer.masksToBounds = YES;
    [self addSubview:_backdropView];

    // recommit over the first ~12s to beat registration race
    __weak LGLiveBackdropView *weakBackdrop = _backdropView;
    for (NSNumber *delay in @[ @1.5, @3.0, @5.0, @8.0, @12.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakBackdrop forceReapplyForRegistrationRace];
        });
    }

    _specularBorder = [[UIView alloc] initWithFrame:self.bounds];
    _specularBorder.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _specularBorder.userInteractionEnabled = NO;
    _specularBorder.backgroundColor       = [UIColor clearColor];
    _specularBorder.layer.cornerRadius    = radius;
    _specularBorder.layer.cornerCurve     = kCACornerCurveContinuous;
    _specularBorder.layer.borderWidth     = 1.0;
    _specularBorder.layer.borderColor     =
        [[UIColor whiteColor] colorWithAlphaComponent:0.35].CGColor;
    [self addSubview:_specularBorder];

    _pan = [[UIPanGestureRecognizer alloc]
                initWithTarget:self action:@selector(_handlePan:)];
    [self addGestureRecognizer:_pan];

    sblog("LGFloatingTestView created center=(%.0f,%.0f) size=(%.0fx%.0f)",
          center.x, center.y, size.width, size.height);
    return self;
}

- (void)_handlePan:(UIPanGestureRecognizer *)gr {
    CGPoint pt = [gr locationInView:self.superview];
    switch (gr.state) {
        case UIGestureRecognizerStateBegan:
            _dragOffset = CGPointMake(pt.x - self.center.x,
                                      pt.y - self.center.y);
            break;
        case UIGestureRecognizerStateChanged: {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            self.center = CGPointMake(pt.x - _dragOffset.x,
                                      pt.y - _dragOffset.y);
            [CATransaction commit];
            break;
        }
        default: break;
    }
}

@end

@interface LGPassthroughWindow : UIWindow
@end
@implementation LGPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self.rootViewController.view) return nil;
    return hit;
}
@end

static LGPassthroughWindow *sTestWindow = nil;

static void installTestView(void) {
    if (sTestWindow) return;

    CGRect screen = [UIScreen mainScreen].bounds;

    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s; break;
        }
    }
    if (!scene) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                scene = (UIWindowScene *)s; break;
            }
        }
    }

    if (scene)
        sTestWindow = [[LGPassthroughWindow alloc] initWithWindowScene:scene];
    else
        sTestWindow = [[LGPassthroughWindow alloc] initWithFrame:screen];

    sTestWindow.windowLevel            = UIWindowLevelAlert + 200;
    sTestWindow.backgroundColor        = [UIColor clearColor];
    sTestWindow.userInteractionEnabled = YES;
    sTestWindow.alpha                  = 1.0;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    sTestWindow.rootViewController = vc;
    [sTestWindow makeKeyAndVisible];

    CGPoint center = CGPointMake(screen.size.width  / 2,
                                 screen.size.height / 2 - 80);
    CGSize  size   = CGSizeMake(220, 220);

    LGFloatingTestView *test =
        [[LGFloatingTestView alloc] initAtCenter:center size:size];
    [vc.view addSubview:test];

    sblog("test window live - center=(%.0f,%.0f) filter=%s",
          center.x, center.y, kLGFilterType.UTF8String);
}

%ctor {
    sblog("loaded into %s (pid %d)",
          [NSProcessInfo.processInfo.processName UTF8String], (int)getpid());

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installTestView();
    });
}
