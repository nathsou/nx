// iOS / iPadOS: Apple's on-screen controller (GCVirtualController) over the game, for playing with touch alone. It is a
// GCController like a real one, so SDL - and the game's input (runtime/hle/input.c) - takes it as a controller. Shown
// while no other controller is connected (Controls tab: or always, or never), hidden while the menu is open (its
// touches are the menu's). The buttons carry the Switch's letters where the game expects them: the bottom one is B.
#include "menu.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if TARGET_OS_IPHONE
#import <CoreText/CoreText.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

extern "C" {
#include "../settings.h"
}

static GCVirtualController *g_pad;

// A label drawn as the button's glyph: the text's outline, centred on the button
static UIBezierPath *label(NSString *text) {
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, text.length > 1 ? 11 : 14, NULL);
    NSAttributedString *s = [[NSAttributedString alloc] initWithString:text attributes:@{(id)kCTFontAttributeName: (__bridge id)font}];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)s);
    CGMutablePathRef path = CGPathCreateMutable();
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CTFontRef rf = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        for (CFIndex i = 0; i < CTRunGetGlyphCount(run); i++) {
            CGGlyph g;
            CGPoint at;
            CTRunGetGlyphs(run, CFRangeMake(i, 1), &g);
            CTRunGetPositions(run, CFRangeMake(i, 1), &at);
            CGPathRef gp = CTFontCreatePathForGlyph(rf, g, NULL);
            if (!gp) continue;
            CGAffineTransform t = CGAffineTransformMakeTranslation(at.x, at.y);
            CGPathAddPath(path, &t, gp);
            CGPathRelease(gp);
        }
    }
    CGRect b = CGPathGetPathBoundingBox(path);  // (centred on 0,0; y up, as the controller draws paths)
    CGAffineTransform t = CGAffineTransformMakeTranslation(-CGRectGetMidX(b), -CGRectGetMidY(b));
    CGPathRef moved = CGPathCreateCopyByTransformingPath(path, &t);
    UIBezierPath *p = [UIBezierPath bezierPathWithCGPath:moved];
    CGPathRelease(moved);
    CGPathRelease(path);
    CFRelease(line);
    CFRelease(font);
    return p;
}

static void relabel(NSString *element, NSString *text) {
    [g_pad updateConfigurationForElement:element configuration:^GCVirtualControllerElementConfiguration *(GCVirtualControllerElementConfiguration *c) {
        c.path = label(text);
        return c;
    }];
}

static void show(bool on) {
    if (on == (g_pad != nil)) return;
    if (!on) {
        [g_pad disconnect];
        g_pad = nil;
        return;
    }
    static bool failed;  // (a layout iOS refuses throws: logged once, no on-screen controller)
    if (failed) return;
    GCVirtualControllerConfiguration *c = [GCVirtualControllerConfiguration new];
    // (no Plus / Minus: iOS's touch controller has neither - runtime/ui/menu.mm draws them beside the menu button)
    c.elements = [NSSet setWithArray:@[GCInputLeftThumbstick, GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
                                       GCInputLeftShoulder, GCInputRightShoulder, GCInputLeftTrigger, GCInputRightTrigger]];
    @try {
        g_pad = [[GCVirtualController alloc] initWithConfiguration:c];
    } @catch (NSException *e) {
        fprintf(stderr, "[touch] on-screen controller refused: %s: %s\n", e.name.UTF8String, e.reason.UTF8String);
        failed = true;
        g_pad = nil;
        return;
    }
    // (SDL's buttons by position: bottom = south = the Switch's B, right = A, left = Y, top = X)
    relabel(GCInputButtonA, @"B");
    relabel(GCInputButtonB, @"A");
    relabel(GCInputButtonX, @"Y");
    relabel(GCInputButtonY, @"X");
    relabel(GCInputLeftShoulder, @"L");
    relabel(GCInputRightShoulder, @"R");
    relabel(GCInputLeftTrigger, @"ZL");
    relabel(GCInputRightTrigger, @"ZR");
    [g_pad connectWithReplyHandler:^(NSError *e) {
        if (e) fprintf(stderr, "[touch] on-screen controller: %s\n", e.localizedDescription.UTF8String);
        else fprintf(stderr, "[touch] on-screen controller shown\n");
    }];
}

extern "C" bool touch_pad_shown(void) { return g_pad != nil; }

// (main thread, every pass of the window's event loop) a real controller: any but the on-screen one
extern "C" void touch_pad_update(bool menu_open) {
    bool other = false;
    for (GCController *c in GCController.controllers)
        if (!g_pad || c != g_pad.controller) other = true;
    static NSUInteger seen = (NSUInteger)-1;  // (the log: each change of the connected controllers)
    if (GCController.controllers.count != seen) {
        seen = GCController.controllers.count;
        for (GCController *c in GCController.controllers)
            fprintf(stderr, "[touch] controller: %s (%s)%s\n", c.vendorName.UTF8String ?: "?", c.productCategory.UTF8String ?: "?",
                    g_pad && c == g_pad.controller ? " - the on-screen one" : "");
        if (!seen) fprintf(stderr, "[touch] no controller connected\n");
    }
    int mode = g_settings.touch_pad;
    show(!menu_open && (mode == TOUCH_PAD_ALWAYS || (mode == TOUCH_PAD_AUTO && !other)));
}

#else
extern "C" void touch_pad_update(bool menu_open) { (void)menu_open; }
extern "C" bool touch_pad_shown(void) { return false; }
#endif
