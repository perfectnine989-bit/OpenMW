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
    // How far a finger has to move per second to push the look stick fully (points/s): smaller = more sensitive.
    // Was 650. Try 200 for even faster turning, 400 for a bit slower.
    constexpr CGFloat lookFullSpeed = 300;
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
    CGPoint _lookDelta; // finger movement since the last frame
    CGPoint _lookSmooth; // points per second, smoothed over a few frames
    CADisplayLink* _link;
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
        // Format: icon, controller element, corner, dx, dy, radius.
        const TouchButton specs[] = {
            { @"burst.fill", GCInputRightTrigger, BottomRight, 78, 88, 46 }, // attack
            { @"hand.tap.fill", GCInputButtonA, BottomRight, 178, 56, 34 }, // action
            { @"arrow.up", GCInputLeftTrigger, BottomRight, 58, 194, 34 }, // jump
            { @"bag.fill", GCInputButtonB, BottomRight, 172, 150, 28 }, // inventory
            { @"shield.fill", GCInputButtonX, BottomRight, 262, 100, 28 }, // weapon
            { @"sparkles", GCInputButtonY, BottomRight, 250, 196, 28 }, // magic
            { @"line.3.horizontal", GCInputButtonMenu, TopRight, 38, 38, 24 }, // menu
            { @"book.fill", GCInputLeftShoulder, TopRight, 100, 38, 24 }, // journal
            { @"eye.slash.fill", GCInputLeftThumbstickButton, TopLeft, 44, 38, 26 }, // sneak
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
            UIImage* image = [UIImage systemImageNamed:button.icon withConfiguration:symbolConfiguration];
            image = [image imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            button.iconLayer.contents = (id)image.CGImage;
            [self.layer addSublayer:button.iconLayer];
            _buttons.push_back(button);
            [self styleButton:_buttons.back() pressed:NO];
        }

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

// While a menu or dialog is open, touches that are not on a button go through to the game window underneath, where
// SDL turns them into ordinary clicks. Buttons stay usable.
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event
{
    if (guiOpen() && [self buttonAt:point] == nullptr)
        return nil;
    return [super hitTest:point withEvent:event];
}

// stops the display link (it retains this view) and lets go of every control
- (void)teardown
{
    [_link invalidate];
    [_link release];
    _link = nil;
    if (_controller != nil)
    {
        [_controller setPosition:CGPointZero forDirectionPadElement:GCInputLeftThumbstick];
        [_controller setPosition:CGPointZero forDirectionPadElement:GCInputRightThumbstick];
        for (TouchButton& button : _buttons)
            if (button.touch != nil)
                [_controller setValue:0 forButtonElement:button.element];
    }
    _controller = nil;
    _stickTouch = nil;
    _lookTouch = nil;
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
        const CGFloat side = radius * 1.0;
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

// the look stick follows how fast the finger moves; it centers by itself when the finger stops
- (void)tick:(CADisplayLink*)link
{
    if (_lookTouch == nil || _controller == nil)
        return;
    const CFTimeInterval frame = link.targetTimestamp - link.timestamp;
    const CFTimeInterval dt = frame > 0 ? frame : 1.0 / 60;
    const CGPoint velocity = CGPointMake(_lookDelta.x / dt, _lookDelta.y / dt);
    _lookDelta = CGPointZero;
    _lookSmooth.x += (velocity.x - _lookSmooth.x) * 0.5;
    _lookSmooth.y += (velocity.y - _lookSmooth.y) * 0.5;
    const CGFloat full = lookFullSpeed * _scale;
    [_controller setPosition:CGPointMake(clampUnit(_lookSmooth.x / full), clampUnit(-_lookSmooth.y / full))
        forDirectionPadElement:GCInputRightThumbstick];
}

// the button under a point, the nearest one when buttons are close; nullptr for none
- (TouchButton*)buttonAt:(CGPoint)point
{
    TouchButton* best = nullptr;
    CGFloat bestScore = 1e9;
    for (TouchButton& button : _buttons)
    {
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
    [_controller setValue:1 forButtonElement:button.element];
    [self styleButton:button pressed:YES];
}

// held for at least 0.1 s: SDL reads the button state once per frame, a shorter tap could be missed
- (void)lift:(TouchButton&)button
{
    button.touch = nil;
    [self styleButton:button pressed:NO];
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
    for (UITouch* touch in touches)
    {
        const CGPoint point = [touch locationInView:self];
        if (TouchButton* button = [self buttonAt:point])
        {
            if (button->touch == nil)
                [self press:*button touch:touch];
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
            _lookDelta = CGPointZero;
            _lookSmooth = CGPointZero;
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
        else if (touch == _lookTouch)
        {
            _lookDelta.x += point.x - _lookLast.x;
            _lookDelta.y += point.y - _lookLast.y;
            _lookLast = point;
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
        else if (touch == _lookTouch)
        {
            _lookTouch = nil;
            _lookDelta = CGPointZero;
            _lookSmooth = CGPointZero;
            [_controller setPosition:CGPointZero forDirectionPadElement:GCInputRightThumbstick];
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
