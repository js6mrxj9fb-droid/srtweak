// SourceRead 段评弹窗改造：FloatingPanel 半屏 -> 系统 UISheetPresentationController
// 日志: <Home>/Documents/sr_tweak.log
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void TLOG(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void TLOG(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[SRTweak %@] %@\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
                                       dateStyle:NSDateFormatterNoStyle
                                       timeStyle:NSDateFormatterMediumStyle], msg];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *path = [dir stringByAppendingPathComponent:@"sr_tweak.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) return;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    NSLog(@"%@", line);
}

static char kConvertedKey;

static UIViewController *SRTweakFindFPHost(UIViewController *vc) {
    UIViewController *p = vc.parentViewController;
    while (p) {
        if ([NSStringFromClass([p class]) containsString:@"FloatingPanelController"]) return p;
        p = p.parentViewController;
    }
    return nil;
}

// 兜底：把 FP 表面样式改成系统 sheet 观感（仅当该 FP 的内容就是段评面板时）
static void SRTweakRestyleFallback(UIViewController *fp) {
    @try {
        if (![fp respondsToSelector:NSSelectorFromString(@"contentViewController")]) return;
        id content = ((id(*)(id,SEL))objc_msgSend)(fp, NSSelectorFromString(@"contentViewController"));
        if (![NSStringFromClass([content class]) containsString:@"SRReadCommentPanel"]) return;

        id sv = nil, ap = nil;
        if ([fp respondsToSelector:NSSelectorFromString(@"surfaceView")])
            sv = ((id(*)(id,SEL))objc_msgSend)(fp, NSSelectorFromString(@"surfaceView"));
        if (sv && [sv respondsToSelector:NSSelectorFromString(@"appearance")])
            ap = ((id(*)(id,SEL))objc_msgSend)(sv, NSSelectorFromString(@"appearance"));
        if (!ap) { TLOG(@"fallback: no SurfaceAppearance"); return; }
        void (*setF)(id,SEL,double) = (void(*)(id,SEL,double))objc_msgSend;
        SEL cb = NSSelectorFromString(@"setCornerRadius:");
        if ([ap respondsToSelector:cb]) setF(ap, cb, 10.0);
        SEL bw = NSSelectorFromString(@"setBorderWidth:");
        if ([ap respondsToSelector:bw]) setF(ap, bw, 0.0);
        SEL bc = NSSelectorFromString(@"setBorderColor:");
        if ([ap respondsToSelector:bc]) ((void(*)(id,SEL,id))objc_msgSend)(ap, bc, [UIColor clearColor]);
        TLOG(@"fallback restyle applied");
    } @catch (NSException *e) { TLOG(@"restyle error: %@", e); }
}

static void SRTweakConvert(UIViewController *self_) {
    @try {
        if (objc_getAssociatedObject(self_, &kConvertedKey)) return;
        UIViewController *fp = SRTweakFindFPHost(self_);
        if (!fp) return; // 已不在 FP 内（例如以 sheet 呈现时），跳过
        objc_setAssociatedObject(self_, &kConvertedKey, @YES, OBJC_ASSOCIATION_RETAIN);
        UIViewController *presenter = fp.parentViewController;
        TLOG(@"convert: FP=%@ presenter=%@", NSStringFromClass([fp class]), NSStringFromClass([presenter class]));

        void (^convert)(void) = ^{
            SEL rm = NSSelectorFromString(@"removePanelFromParent:completion:");
            if ([fp respondsToSelector:rm]) {
                ((void(*)(id,SEL,id,id))objc_msgSend)(fp, rm, nil, nil);
                TLOG(@"removePanelFromParent called");
            } else {
                [fp.view removeFromSuperview];
                [fp removeFromParentViewController];
                TLOG(@"FP removed by force");
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *p = presenter;
                if (!p) p = self_.parentViewController;
                if (!p) {
                    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                            p = ((UIWindowScene *)scene).keyWindow.rootViewController;
                            while (p.presentedViewController) p = p.presentedViewController;
                            break;
                        }
                    }
                }
                if (!p) { TLOG(@"no presenter found"); return; }
                self_.modalPresentationStyle = UIModalPresentationPageSheet;
                if (@available(iOS 15.0, *)) {
                    UISheetPresentationController *sh = self_.sheetPresentationController;
                    if (sh) {
                        sh.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                                       UISheetPresentationControllerDetent.largeDetent];
                        sh.prefersGrabberVisible = YES;
                        sh.prefersScrollingExpandsWhenScrolledToEdge = YES;
                        TLOG(@"sheet detents configured");
                    }
                }
                [p presentViewController:self_ animated:YES completion:nil];
                TLOG(@"presented as system sheet");
            });
        };
        if ([NSThread isMainThread]) convert(); else dispatch_async(dispatch_get_main_queue(), convert);
    } @catch (NSException *e) {
        TLOG(@"convert error: %@", e);
    }
}

static IMP origPanelVDA = NULL, origFPVDA = NULL;
static void hookPanelVDA(id self_, SEL _cmd, BOOL anim) {
    if (origPanelVDA) ((void(*)(id,SEL,BOOL))origPanelVDA)(self_, _cmd, anim);
    SRTweakConvert(self_);
}
static void hookFPVDA(id self_, SEL _cmd, BOOL anim) {
    if (origFPVDA) ((void(*)(id,SEL,BOOL))origFPVDA)(self_, _cmd, anim);
    SRTweakRestyleFallback(self_);
}

// 在 cls 上加一个 viewDidAppear: 覆盖，不改父类（避免影响全 App 的 UIViewController）
static IMP overrideVDA(Class cls, IMP newImp) {
    Method m = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (!m) return NULL;
    IMP superImp = method_getImplementation(m);
    IMP old = class_replaceMethod(cls, @selector(viewDidAppear:), newImp, method_getTypeEncoding(m));
    return old ? old : superImp; // 若是继承来的，old 为 NULL，回落到父类实现
}

__attribute__((constructor))
static void SRTweakInit(void) {
    @autoreleasepool {
        TLOG(@"BOOT sr_tweak v1 pid=%d", (int)getpid());
        Class panelCls = objc_getClass("_TtC10SourceRead28SRReadCommentPanelController");
        Class fpCls    = objc_getClass("_TtC13FloatingPanel23FloatingPanelController");
        TLOG(@"panelCls=%p fpCls=%p", panelCls, fpCls);
        if (panelCls) {
            origPanelVDA = overrideVDA(panelCls, (IMP)hookPanelVDA);
            TLOG(@"panel viewDidAppear overridden orig=%p", origPanelVDA);
        }
        if (fpCls) {
            origFPVDA = overrideVDA(fpCls, (IMP)hookFPVDA);
            TLOG(@"FP viewDidAppear overridden orig=%p", origFPVDA);
        }
    }
}
