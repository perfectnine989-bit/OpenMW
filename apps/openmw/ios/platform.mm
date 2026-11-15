#include "platform.hpp"

#include <components/debug/debuglog.hpp>
#include <components/settings/values.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwgui/windowmanagerimp.hpp"
#include "../mwrender/pingpongcanvas.hpp"

#include "metalfx.hpp"

#include <SDL_events.h>
#include <SDL_hints.h>
#include <SDL_syswm.h>

#import <AVFAudio/AVFAudio.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <mach/mach.h>
#include <os/proc.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iterator>
#include <string>
#include <vector>

// On-screen controls drawn by the app itself: a floating left stick for walking, a look area on the rest of the
// screen and buttons around the edges. They drive an invisible GCVirtualController, so the engine sees an ordinary
// game controller.
@interface OMWTouchOverlay : UIView
- (instancetype)initWithFrame:(CGRect)frame controller:(GCVirtualController*)controller;
- (void)teardown;
@end

namespace
{
    // the engine's view of the on-screen controls (an invisible GCVirtualController) while no keyboard, mouse or
    // game controller is connected
    GCVirtualController* sTouchController = nil;
    // the controls the app draws and the SDL window they sit on
    OMWTouchOverlay* sOverlay = nil;
    UIWindow* sWindow = nil;
    // decided once GameController has reported the devices connected at launch
    bool sDevicesReported = false;
    // memory log while the app runs: a long session's trend
    dispatch_source_t sMemoryTimer = nil;

    // footprint = what iOS counts against the app's memory limit; footprint + available = that limit
    void logMemory(const char* when)
    {
        constexpr std::uint64_t mb = 1024 * 1024;
        constexpr const char* thermalStates[] = { "nominal", "fair", "serious", "critical" };
        task_vm_info_data_t info{};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        const bool ok
            = task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS;
        const NSUInteger thermal = static_cast<NSUInteger>(NSProcessInfo.processInfo.thermalState);
        Log(Debug::Info) << "Memory (" << when << "): footprint " << (ok ? info.phys_footprint / mb : 0) << " MB, peak "
                         << (ok ? info.ledger_phys_footprint_peak / mb : 0) << " MB, available "
                         << os_proc_available_memory() / mb << " MB, thermal state "
                         << (thermal < std::size(thermalStates) ? thermalStates[thermal] : "unknown");
    }

    // Xcode's CoreDevice adds a virtual mouse ("CoreDevice touchscreenGesture") while a Mac drives the device
    bool hasUserMouse()
    {
        for (GCMouse* mouse in GCMouse.mice)
            if (![mouse.vendorName hasPrefix:@"CoreDevice"])
                return true;
        return false;
    }

    // the touch controller is a GCController too, but never counts as one
    bool hasGameController()
    {
        for (GCController* controller in GCController.controllers)
            if (sTouchController == nil || controller != sTouchController.controller)
                return true;
        return false;
    }

    // Console-style menus only with a real game controller. With touch only (or keyboard/mouse) the menus are the
    // ordinary pointer ones, so a tap clicks them.
    bool wantsControllerMenus()
    {
        return hasGameController();
    }

    // true while a menu, dialog or window is open (the main menu counts)
    bool guiOpen()
    {
        MWBase::WindowManager* windowManager = MWBase::Environment::get().getWindowManager();
        return windowManager != nullptr && windowManager->isGuiMode();
    }

    // the Menu button is not an element a virtual controller can press, so it sends the Escape key (OpenMW's game menu:
    // save, load, options) straight to the engine instead
    bool isKeyButton(NSString* element)
    {
        return [element isEqualToString:@"key:escape"];
    }

    void pushKey(SDL_Scancode scancode, bool down)
    {
        SDL_Event event{};
        event.type = down ? SDL_KEYDOWN : SDL_KEYUP;
        event.key.state = down ? SDL_PRESSED : SDL_RELEASED;
        event.key.keysym.scancode = scancode;
        event.key.keysym.sym = SDL_GetKeyFromScancode(scancode);
        SDL_PushEvent(&event);
    }

    // While a menu is open the overlay turns finger gestures into ordinary mouse input for the engine.
    void pushMouseMotion(CGPoint to, CGPoint from, bool pressed)
    {
        SDL_Event event{};
        event.type = SDL_MOUSEMOTION;
        event.motion.state = pressed ? SDL_BUTTON_LMASK : 0;
        event.motion.x = static_cast<Sint32>(to.x);
        event.motion.y = static_cast<Sint32>(to.y);
        event.motion.xrel = static_cast<Sint32>(to.x - from.x);
        event.motion.yrel = static_cast<Sint32>(to.y - from.y);
        SDL_PushEvent(&event);
    }

    void pushMouseButton(CGPoint at, bool down)
    {
        SDL_Event event{};
        event.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
        event.button.button = SDL_BUTTON_LEFT;
        event.button.state = down ? SDL_PRESSED : SDL_RELEASED;
        event.button.clicks = 1;
        event.button.x = static_cast<Sint32>(at.x);
        event.button.y = static_cast<Sint32>(at.y);
        SDL_PushEvent(&event);
    }

    // steps > 0 scrolls up, steps < 0 scrolls down; at is where the finger is (the engine moves its cursor there)
    void pushMouseWheel(int steps, CGPoint at)
    {
        SDL_Event event{};
        event.type = SDL_MOUSEWHEEL;
        event.wheel.y = steps;
        event.wheel.preciseY = static_cast<float>(steps);
        event.wheel.mouseX = static_cast<Sint32>(at.x);
        event.wheel.mouseY = static_cast<Sint32>(at.y);
        event.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
        SDL_PushEvent(&event);
    }

    // Camera movement in the game: mouse movement as the engine's own mouse look takes it (scaled by Options >
    // Controls > Camera sensitivity). The position stays at the screen centre so the engine never wraps the pointer.
    void pushLookMotion(Sint32 xrel, Sint32 yrel, CGPoint centre)
    {
        SDL_Event event{};
        event.type = SDL_MOUSEMOTION;
        event.motion.state = 0;
        event.motion.x = static_cast<Sint32>(centre.x);
        event.motion.y = static_cast<Sint32>(centre.y);
        event.motion.xrel = xrel;
        event.motion.yrel = yrel;
        SDL_PushEvent(&event);
    }

    void installOverlay()
    {
        if (sOverlay != nil || sTouchController == nil || sWindow == nil)
            return;
        sOverlay = [[OMWTouchOverlay alloc] initWithFrame:sWindow.bounds controller:sTouchController];
        [sWindow addSubview:sOverlay];
        Log(Debug::Info) << "Touch overlay on";
    }

    void removeOverlay()
    {
        if (sOverlay == nil)
            return;
        [sOverlay teardown];
        [sOverlay removeFromSuperview];
        [sOverlay release];
        sOverlay = nil;
        Log(Debug::Info) << "Touch overlay off";
    }

    // The virtual controller has no elements for the system to draw: the overlay draws the controls and sets the
    // controller's values (sticks, buttons, triggers, Menu = SDL's Start = OpenMW's game menu).
    void updateTouchController()
    {
        const bool wanted
            = sDevicesReported && GCKeyboard.coalescedKeyboard == nil && !hasUserMouse() && !hasGameController();
        if (wanted == (sTouchController != nil))
            return;
        if (!wanted)
        {
            removeOverlay();
            [sTouchController disconnect];
            [sTouchController release];
            sTouchController = nil;
            Log(Debug::Info) << "Touch controls off";
            return;
        }
        GCVirtualControllerConfiguration* configuration = [[GCVirtualControllerConfiguration alloc] init];
        configuration.elements = [NSSet set];
        GCVirtualController* controller = [[GCVirtualController alloc] initWithConfiguration:configuration];
        [configuration release];
        sTouchController = controller;
        Log(Debug::Info) << "Touch controls requested";
        [controller connectWithReplyHandler:^(NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (controller != sTouchController)
                    return; // disconnected meanwhile
                if (error != nil)
                {
                    Log(Debug::Warning) << "Failed to show the touch controls: " << error.description.UTF8String;
                    [sTouchController release];
                    sTouchController = nil;
                    return;
                }
                Log(Debug::Info) << "Touch controls on";
                installOverlay();
            });
        }];
    }

    // remembers SDL's window once it exists, to put the touch overlay on it
    int captureWindow(void*, SDL_Event* event)
    {
        if (event->type != SDL_WINDOWEVENT)
            return 0;
        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        SDL_Window* window = SDL_GetWindowFromID(event->window.windowID);
        if (window == nullptr || !SDL_GetWindowWMInfo(window, &info))
            return 0;
        UIWindow* uiWindow = info.info.uikit.window;
        SDL_DelEventWatch(captureWindow, nullptr);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sWindow == nil)
                sWindow = [uiWindow retain];
            installOverlay();
        });
        return 0;
    }

    // Gamepad-style menus follow the connected devices. ponytail: the window manager saves the switched value to
    // settings.cfg like any setting; it is decided anew at every launch, so editing [GUI] controller menus there has no
    // effect on iOS (upgrade path: a runtime override that is not saved).
    std::string describe(NSArray<id<GCDevice>>* devices)
    {
        std::string result;
        for (id<GCDevice> device in devices)
            result += std::string(result.empty() ? "" : ", ") + device.productCategory.UTF8String + " ("
                + (device.vendorName != nil ? device.vendorName.UTF8String : "?") + ")";
        return result;
    }

    void updateInputDevices(NSString* when)
    {
        GCKeyboard* keyboard = GCKeyboard.coalescedKeyboard;
        Log(Debug::Info) << "Input devices (" << when.UTF8String << "): keyboard ["
                         << describe(keyboard ? @[ keyboard ] : @[]) << "], mice [" << describe(GCMouse.mice)
                         << "], controllers [" << describe(GCController.controllers) << "] -> controller menus "
                         << (wantsControllerMenus() ? "on" : "off");
        MWGui::WindowManager::requestControllerMenus(wantsControllerMenus());
        updateTouchController();
    }
}

namespace
{
    // Camera speed: how much of the finger's movement the camera follows. Higher = faster turning. On top of it
    // the engine's own setting applies (Options > Controls > Camera sensitivity, 0.2 to 5).
    constexpr CGFloat lookGain = 1.8;
    // The walking stick: the finger's distance from where it touched down for full deflection (points at scale 1).
    constexpr CGFloat stickRadiusBase = 64;
    // Touches left of this fraction of the screen width walk, the rest look.
    constexpr CGFloat walkZoneWidth = 0.42;

    enum Anchor
    {
        BottomRight,
        TopRight,
        TopLeft
    };

    struct TouchButton
    {
        NSString* icon; // SF Symbol name (a vector icon built into iOS)
        NSString* element; // the virtual controller's element this button drives
        Anchor anchor;
        CGFloat dx, dy, radius; // distance from the anchor's corner (inside the safe area) to the centre, radius
        CGPoint center = CGPointZero;
        CGFloat scaledRadius = 0;
        UITouch* touch = nil; // the finger holding it, not retained
        CFTimeInterval pressedAt = 0;
        CAShapeLayer* circle = nil; // owned by the overlay's layer
        CALayer* iconLayer = nil;
    };

    CGFloat clampUnit(CGFloat value)
    {
        return std::max<CGFloat>(-1, std::min<CGFloat>(1, value));
    }

    // Vector icons drawn in code (white on transparent) for what iOS has no symbol for.
    UIImage* drawnIcon(NSString* name)
    {
        UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat preferredFormat];
        format.opaque = NO;
        UIGraphicsImageRenderer* renderer =
            [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(96, 96) format:format] autorelease];
        const bool swords = [name isEqualToString:@"custom.swords"];
        return [renderer imageWithActions:^(UIGraphicsImageRendererContext* rendererContext) {
            CGContextRef context = rendererContext.CGContext;
            CGContextSetFillColorWithColor(context, UIColor.whiteColor.CGColor);
            CGContextSetStrokeColorWithColor(context, UIColor.whiteColor.CGColor);
            if (swords)
            {
                // two swords crossed in an X: blade, cross guard, grip, pommel
                for (const CGFloat angle : { M_PI / 4, -M_PI / 4 })
                {
                    CGContextSaveGState(context);
                    CGContextTranslateCTM(context, 48, 48);
                    CGContextRotateCTM(context, angle);
                    CGContextBeginPath(context);
                    CGContextMoveToPoint(context, 0, -45);
                    CGContextAddLineToPoint(context, 6, -31);
                    CGContextAddLineToPoint(context, 6, 14);
                    CGContextAddLineToPoint(context, -6, 14);
                    CGContextAddLineToPoint(context, -6, -31);
                    CGContextClosePath(context);
                    CGContextFillPath(context);
                    CGContextFillRect(context, CGRectMake(-18, 16, 36, 7));
                    CGContextFillRect(context, CGRectMake(-3.5, 24, 7, 15));
                    CGContextFillEllipseInRect(context, CGRectMake(-6, 38, 12, 12));
                    CGContextRestoreGState(context);
                }
            }
            else
            {
                // shield outline with a vertical rib
                CGContextSetLineWidth(context, 7);
                CGContextSetLineJoin(context, kCGLineJoinRound);
                CGContextBeginPath(context);
                CGContextMoveToPoint(context, 48, 12);
                CGContextAddLineToPoint(context, 80, 24);
                CGContextAddCurveToPoint(context, 80, 58, 62, 76, 48, 86);
                CGContextAddCurveToPoint(context, 34, 76, 16, 58, 16, 24);
                CGContextClosePath(context);
                CGContextStrokePath(context);
                CGContextSetLineWidth(context, 5);
                CGContextBeginPath(context);
                CGContextMoveToPoint(context, 48, 24);
                CGContextAddLineToPoint(context, 48, 72);
                CGContextStrokePath(context);
            }
        }];
    }
}

@interface OMWTouchOverlay ()
{
    GCVirtualController* _controller; // not retained; teardown clears it
    std::vector<TouchButton> _buttons;
    CAShapeLayer* _stickBase;
    CAShapeLayer* _stickKnob;
    UITouch* _stickTouch;
    CGPoint _stickCenter; // where the walking finger touched down
    CGPoint _stickRest; // where the stick waits when nobody walks
    CGPoint _stickOffset; // finger offset from the centre, clamped to the stick radius
    CGFloat _stickRadius;
    CGFloat _scale;
    UITouch* _lookTouch;
    CGPoint _lookLast;
    CGPoint _lookAcc; // fractional camera movement carried to the next event
    BOOL _guiActive; // a menu, dialog or window is open: the game buttons and sticks are off
    CADisplayLink* _link;
    UIButton* _keyboardButton; // shown only while the on-screen keyboard is up, to hide it
    UITouch* _guiTouch; // the finger that taps, drags or scrolls a menu
    CGPoint _guiStart, _guiLast;
    int _guiMode; // 0 = not decided yet (tap), 1 = scroll, 2 = drag
    CGFloat _scrollAccum;
}
@end

@implementation OMWTouchOverlay

- (instancetype)initWithFrame:(CGRect)frame controller:(GCVirtualController*)controller
{
    if ((self = [super initWithFrame:frame]))
    {
        _controller = controller;
        _scale = 1;
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _stickBase = [CAShapeLayer layer];
        _stickBase.fillColor = [UIColor colorWithWhite:1 alpha:0.03].CGColor;
        _stickBase.strokeColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
        _stickBase.lineWidth = 1.5;
        [self.layer addSublayer:_stickBase];
        _stickKnob = [CAShapeLayer layer];
        _stickKnob.fillColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
        _stickKnob.strokeColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        _stickKnob.lineWidth = 1.5;
        [self.layer addSublayer:_stickKnob];

        // Layout of the buttons (distances in points at scale 1; edit here to move them). The right thumb also looks
        // around: any spot that is not a button is look area.
        // Format: icon, controller element, corner, dx, dy, radius. The right-hand cluster is kept tight against the
        // screen edge so the rest of the right side stays free for looking around.
        const TouchButton specs[] = {
            { @"custom.swords", GCInputRightTrigger, BottomRight, 52, 78, 34 }, // attack
            { @"arrow.up", GCInputLeftTrigger, BottomRight, 30, 158, 22 }, // jump
            { @"hand.raised.fill", GCInputButtonA, BottomRight, 120, 48, 22 }, // action
            { @"custom.shield", GCInputButtonX, BottomRight, 124, 100, 20 }, // weapon
            { @"wand.and.stars", GCInputButtonY, BottomRight, 92, 140, 22 }, // magic
            { @"line.3.horizontal", @"key:escape", TopRight, 30, 30, 22 }, // game menu (save, options)
            { @"backpack.fill", GCInputButtonB, TopRight, 84, 30, 22 }, // inventory
            { @"book.fill", GCInputLeftShoulder, TopLeft, 30, 30, 22 }, // journal
            { @"eye.slash.fill", GCInputLeftThumbstickButton, TopLeft, 84, 30, 22 }, // sneak
        };
        UIImageSymbolConfiguration* symbolConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:48 weight:UIImageSymbolWeightMedium];
        for (TouchButton button : specs)
        {
            button.circle = [CAShapeLayer layer];
            button.circle.lineWidth = 1.5;
            button.circle.strokeColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
            [self.layer addSublayer:button.circle];
            button.iconLayer = [CALayer layer];
            button.iconLayer.contentsGravity = kCAGravityResizeAspect;
            button.iconLayer.opacity = 0.6;
            UIImage* image = nil;
            if ([button.icon hasPrefix:@"custom."])
                image = drawnIcon(button.icon);
            else
            {
                image = [UIImage systemImageNamed:button.icon withConfiguration:symbolConfiguration];
                if (image == nil) // symbol missing on this iOS: a plain fallback instead of an invisible button
                    image = [UIImage systemImageNamed:@"circle.fill" withConfiguration:symbolConfiguration];
                image = [image imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            }
            button.iconLayer.contents = (id)image.CGImage;
            [self.layer addSublayer:button.iconLayer];
            _buttons.push_back(button);
            [self styleButton:_buttons.back() pressed:NO];
        }

        // a way to hide the on-screen keyboard, which iOS otherwise leaves up after a tap on a text field
        _keyboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_keyboardButton setImage:[UIImage systemImageNamed:@"keyboard.chevron.compact.down"]
                         forState:UIControlStateNormal];
        _keyboardButton.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
        _keyboardButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        _keyboardButton.layer.cornerRadius = 24;
        _keyboardButton.hidden = YES;
        [_keyboardButton addTarget:self action:@selector(hideKeyboard) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_keyboardButton];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(keyboardChanged:)
                                                   name:UIKeyboardWillShowNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(keyboardChanged:)
                                                   name:UIKeyboardWillHideNotification
                                                 object:nil];

        _link = [[CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)] retain];
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc
{
    [self teardown];
    [super dealloc];
}

- (void)keyboardChanged:(NSNotification*)notification
{
    _keyboardButton.hidden = [notification.name isEqualToString:UIKeyboardWillHideNotification];
}

- (void)hideKeyboard
{
    SDL_StopTextInput();
    [sWindow endEditing:YES];
    _keyboardButton.hidden = YES;
}

// stops the display link (it retains this view) and lets go of every control
- (void)teardown
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_link invalidate];
    [_link release];
    _link = nil;
    if (_controller != nil)
    {
        [_controller setPosition:CGPointZero forDirectionPadElement:GCInputLeftThumbstick];
        [_controller setPosition:CGPointZero forDirectionPadElement:GCInputRightThumbstick];
        for (TouchButton& button : _buttons)
            if (button.touch != nil && !isKeyButton(button.element))
                [_controller setValue:0 forButtonElement:button.element];
    }
    _controller = nil;
    _stickTouch = nil;
    _lookTouch = nil;
    _guiTouch = nil;
}

- (void)safeAreaInsetsDidChange
{
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    const CGSize size = self.bounds.size;
    const UIEdgeInsets inset = self.safeAreaInsets;
    _scale = std::min<CGFloat>(1.5, std::max<CGFloat>(0.75, std::min(size.width, size.height) / 390));
    _stickRadius = stickRadiusBase * _scale;
    const CGFloat left = inset.left;
    const CGFloat right = size.width - inset.right;
    const CGFloat top = inset.top;
    const CGFloat bottom = size.height - inset.bottom;
    _stickRest = CGPointMake(left + 120 * _scale, bottom - 96 * _scale);
    _keyboardButton.frame = CGRectMake(size.width / 2 - 24, top + 10, 48, 48);
    const CGFloat screenScale = self.traitCollection.displayScale;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (TouchButton& button : _buttons)
    {
        const CGFloat dx = button.dx * _scale;
        const CGFloat dy = button.dy * _scale;
        switch (button.anchor)
        {
            case BottomRight:
                button.center = CGPointMake(right - dx, bottom - dy);
                break;
            case TopRight:
                button.center = CGPointMake(right - dx, top + dy);
                break;
            case TopLeft:
                button.center = CGPointMake(left + dx, top + dy);
                break;
        }
        const CGFloat radius = button.radius * _scale;
        button.scaledRadius = radius;
        button.circle.frame = CGRectMake(button.center.x - radius, button.center.y - radius, 2 * radius, 2 * radius);
        button.circle.path = [UIBezierPath bezierPathWithOvalInRect:button.circle.bounds].CGPath;
        const CGFloat side = radius * 1.1;
        button.iconLayer.contentsScale = screenScale;
        button.iconLayer.frame = CGRectMake(button.center.x - side / 2, button.center.y - side / 2, side, side);
    }
    [self updateStickLayers];
    [CATransaction commit];
}

- (void)styleButton:(TouchButton&)button pressed:(BOOL)pressed
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    button.circle.fillColor = [UIColor colorWithWhite:1 alpha:pressed ? 0.30 : 0.05].CGColor;
    button.iconLayer.opacity = pressed ? 0.95 : 0.6;
    [CATransaction commit];
}

- (void)updateStickLayers
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    const BOOL active = _stickTouch != nil;
    _stickBase.hidden = _guiActive;
    _stickKnob.hidden = _guiActive;
    const CGPoint center = active ? _stickCenter : _stickRest;
    const CGFloat radius = _stickRadius;
    _stickBase.opacity = active ? 1 : 0.6;
    _stickBase.frame = CGRectMake(center.x - radius, center.y - radius, 2 * radius, 2 * radius);
    _stickBase.path = [UIBezierPath bezierPathWithOvalInRect:_stickBase.bounds].CGPath;
    const CGFloat knob = radius * 0.42;
    const CGPoint knobCenter = CGPointMake(center.x + _stickOffset.x, center.y + _stickOffset.y);
    _stickKnob.opacity = active ? 1 : 0.6;
    _stickKnob.frame = CGRectMake(knobCenter.x - knob, knobCenter.y - knob, 2 * knob, 2 * knob);
    _stickKnob.path = [UIBezierPath bezierPathWithOvalInRect:_stickKnob.bounds].CGPath;
    [CATransaction commit];
}

- (void)sendStick
{
    CGFloat x = _stickOffset.x / _stickRadius;
    CGFloat y = -_stickOffset.y / _stickRadius; // up on the screen is forward
    if (std::hypot(x, y) < 0.1)
        x = y = 0;
    [_controller setPosition:CGPointMake(clampUnit(x), clampUnit(y)) forDirectionPadElement:GCInputLeftThumbstick];
    [self updateStickLayers];
}

// the game buttons and the stick only exist while the game is played; in a menu or a dialog only the menu button stays
- (void)tick:(CADisplayLink*)link
{
    [self syncGui];
}

- (void)syncGui
{
    if (_controller == nil)
        return;
    const BOOL open = guiOpen();
    if (open != _guiActive)
        [self setGuiActive:open];
}

- (void)setGuiActive:(BOOL)active
{
    _guiActive = active;
    // Let go of everything the game was holding. In a menu the engine moves its cursor with the controller's sticks,
    // so a stick left deflected would drag the cursor away from every tap.
    _stickTouch = nil;
    _stickOffset = CGPointZero;
    _lookTouch = nil;
    _lookAcc = CGPointZero;
    [_controller setPosition:CGPointZero forDirectionPadElement:GCInputLeftThumbstick];
    [_controller setPosition:CGPointZero forDirectionPadElement:GCInputRightThumbstick];
    for (TouchButton& button : _buttons)
        if (button.touch != nil && !isKeyButton(button.element))
            [self lift:button];
    if (_guiTouch != nil && _guiMode == 2)
        pushMouseButton(_guiLast, false);
    _guiTouch = nil;
    [self updateVisibility];
}

- (void)updateVisibility
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (TouchButton& button : _buttons)
    {
        const BOOL hidden = _guiActive && !isKeyButton(button.element);
        button.circle.hidden = hidden;
        button.iconLayer.hidden = hidden;
    }
    [CATransaction commit];
    [self updateStickLayers];
}

// the button under a point, the nearest one when buttons are close; nullptr for none
- (TouchButton*)buttonAt:(CGPoint)point
{
    TouchButton* best = nullptr;
    CGFloat bestScore = 1e9;
    for (TouchButton& button : _buttons)
    {
        if (_guiActive && !isKeyButton(button.element))
            continue;
        const CGFloat distance = std::hypot(point.x - button.center.x, point.y - button.center.y);
        if (distance > button.scaledRadius + 10 * _scale)
            continue;
        const CGFloat score = distance / button.scaledRadius;
        if (score < bestScore)
        {
            best = &button;
            bestScore = score;
        }
    }
    return best;
}

- (void)press:(TouchButton&)button touch:(UITouch*)touch
{
    button.touch = touch;
    button.pressedAt = CACurrentMediaTime();
    if (isKeyButton(button.element))
        pushKey(SDL_SCANCODE_ESCAPE, true);
    else
        [_controller setValue:1 forButtonElement:button.element];
    [self styleButton:button pressed:YES];
}

// held for at least 0.1 s: SDL reads the button state once per frame, a shorter tap could be missed
- (void)lift:(TouchButton&)button
{
    button.touch = nil;
    [self styleButton:button pressed:NO];
    if (isKeyButton(button.element))
    {
        pushKey(SDL_SCANCODE_ESCAPE, false);
        return;
    }
    const CFTimeInterval held = CACurrentMediaTime() - button.pressedAt;
    if (held >= 0.1)
    {
        [_controller setValue:0 forButtonElement:button.element];
        return;
    }
    NSString* element = button.element;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>((0.1 - held) * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (_controller == nil)
                return;
            for (TouchButton& other : _buttons)
                if (other.element == element && other.touch == nil)
                    [_controller setValue:0 forButtonElement:element];
        });
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self syncGui];
    for (UITouch* touch in touches)
    {
        const CGPoint point = [touch locationInView:self];
        if (TouchButton* button = [self buttonAt:point])
        {
            if (button->touch == nil)
                [self press:*button touch:touch];
        }
        else if (_guiActive)
        {
            // a menu is open: this finger works the menu (tap = click, vertical swipe = scroll, sideways = drag)
            if (_guiTouch == nil)
            {
                _guiTouch = touch;
                _guiStart = _guiLast = point;
                _guiMode = 0;
                _scrollAccum = 0;
                pushMouseMotion(point, point, false);
            }
        }
        else if (point.x < self.bounds.size.width * walkZoneWidth)
        {
            if (_stickTouch == nil)
            {
                _stickTouch = touch;
                _stickCenter = point;
                _stickOffset = CGPointZero;
                [self updateStickLayers];
            }
        }
        else if (_lookTouch == nil)
        {
            _lookTouch = touch;
            _lookLast = point;
            _lookAcc = CGPointZero;
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    for (UITouch* touch in touches)
    {
        const CGPoint point = [touch locationInView:self];
        if (touch == _stickTouch)
        {
            CGFloat dx = point.x - _stickCenter.x;
            CGFloat dy = point.y - _stickCenter.y;
            const CGFloat length = std::hypot(dx, dy);
            if (length > _stickRadius)
            {
                dx *= _stickRadius / length;
                dy *= _stickRadius / length;
            }
            _stickOffset = CGPointMake(dx, dy);
            [self sendStick];
        }
        else if (touch == _guiTouch)
        {
            if (_guiMode == 0)
            {
                const CGFloat dx = point.x - _guiStart.x;
                const CGFloat dy = point.y - _guiStart.y;
                if (std::hypot(dx, dy) < 10 * _scale)
                    continue;
                if (std::fabs(dy) > std::fabs(dx) * 1.2)
                {
                    _guiMode = 1;
                    _guiLast = point;
                    _scrollAccum = 0;
                }
                else
                {
                    _guiMode = 2;
                    pushMouseButton(_guiStart, true);
                }
            }
            if (_guiMode == 1)
            {
                // finger up = content up = wheel down
                _scrollAccum += point.y - _guiLast.y;
                _guiLast = point;
                const int steps = static_cast<int>(_scrollAccum / 16);
                if (steps != 0)
                {
                    pushMouseWheel(steps, point);
                    _scrollAccum -= steps * 16;
                }
            }
            else
            {
                pushMouseMotion(point, _guiLast, true);
                _guiLast = point;
            }
        }
        else if (touch == _lookTouch)
        {
            // direct camera control: the camera follows the finger
            _lookAcc.x += (point.x - _lookLast.x) * lookGain;
            _lookAcc.y += (point.y - _lookLast.y) * lookGain;
            _lookLast = point;
            const Sint32 ix = static_cast<Sint32>(_lookAcc.x);
            const Sint32 iy = static_cast<Sint32>(_lookAcc.y);
            _lookAcc.x -= ix;
            _lookAcc.y -= iy;
            if (ix != 0 || iy != 0)
                pushLookMotion(ix, iy, CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2));
        }
    }
}

- (void)endTouches:(NSSet<UITouch*>*)touches
{
    for (UITouch* touch in touches)
    {
        if (touch == _stickTouch)
        {
            _stickTouch = nil;
            _stickOffset = CGPointZero;
            [self sendStick];
        }
        else if (touch == _guiTouch)
        {
            _guiTouch = nil;
            if (_guiMode == 0)
            {
                // a tap: press now, release a moment later so the engine sees a click
                const CGPoint at = _guiStart;
                pushMouseButton(at, true);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.06 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{ pushMouseButton(at, false); });
            }
            else if (_guiMode == 2)
                pushMouseButton(_guiLast, false);
        }
        else if (touch == _lookTouch)
        {
            _lookTouch = nil;
            _lookAcc = CGPointZero;
        }
        else
        {
            for (TouchButton& button : _buttons)
                if (button.touch == touch)
                    [self lift:button];
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self endTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self endTouches:touches];
}

@end

void OMW::initIosPlatform()
{
    @autoreleasepool
    {
        // a swipe from the bottom edge first shows the home indicator, the second one leaves the game
        SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "2");

        // Mesa's shader cache in Library/Caches (its default, $HOME/.cache, is the container root); before the engine
        // creates the GL context. No overwrite: a launch environment can move or disable it
        NSString* caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        setenv("MESA_SHADER_CACHE_DIR", caches.fileSystemRepresentation, 0);

        // render scale: MetalFX scales the 3D world up
        MWRender::PingPongCanvas::setUpscaler(OMW::metalFxUpscale);

        // mixes with other apps' audio, muted by the silent switch
        NSError* error = nil;
        if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:&error])
            Log(Debug::Warning) << "Failed to set the audio session category: "
                                << error.localizedDescription.UTF8String;

        logMemory("launch");
        NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification*) { logMemory("memory warning"); }];
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification*) { logMemory("background"); }];
        [center addObserverForName:NSProcessInfoThermalStateDidChangeNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification*) { logMemory("thermal state change"); }];
        sMemoryTimer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(
            sMemoryTimer, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), 60 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(sMemoryTimer, ^{ logMemory("every 60 s"); });
        dispatch_resume(sMemoryTimer);

        // GameController reports connected devices shortly after launch, as connect notifications
        updateInputDevices(@"launch");
        // without connected devices there is no notification
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            sDevicesReported = true;
            updateTouchController();
        });
        // before SDL_Init: SDL keeps event watches added before its event loop starts
        SDL_AddEventWatch(captureWindow, nullptr);
        for (NSString* name in @[ GCKeyboardDidConnectNotification, GCKeyboardDidDisconnectNotification,
                 GCMouseDidConnectNotification, GCMouseDidDisconnectNotification, GCControllerDidConnectNotification,
                 GCControllerDidDisconnectNotification ])
            [center addObserverForName:name
                                object:nil
                                 queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification* notification) { updateInputDevices(notification.name); }];
    }
}

void OMW::configureMetalHud()
{
    // Off sets nothing; no overwrite: a launch environment can switch the HUD on or off
    const int mode = Settings::video().mMetalHud;
    if (mode == 0)
        return;
    const char* detailed = mode == 2 ? "1" : "0";
    setenv("MTL_HUD_ENABLED", "1", 0);
    setenv("MTL_HUD_ENCODER_TIMING_ENABLED", detailed, 0);
    setenv("MTL_HUD_SHOW_METRICS_RANGE", detailed, 0);
    setenv("MTL_HUD_INSIGHTS_ENABLED", detailed, 0);
    setenv("MTL_HUD_LOG_ENABLED", "0", 0);
    setenv("MTL_HUD_LOG_SHADER_ENABLED", "0", 0);
    Log(Debug::Info) << "Metal Performance HUD: " << (mode == 2 ? "detailed" : "standard");
}
