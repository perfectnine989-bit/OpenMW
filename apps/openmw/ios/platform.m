#include "platform.hpp"

#include <components/debug/debuglog.hpp>
#include <components/settings/values.hpp>

#include "../mwgui/windowmanagerimp.hpp"
#include "../mwrender/pingpongcanvas.hpp"
#include "metalfx.hpp"

#include <SDL_events.h>
#include <SDL_hints.h>
#include <SDL_keyboard.h>
#include <SDL_syswm.h>

#import <AVFAudio/AVFAudio.h>
#import <CoreText/CoreText.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <mach/mach.h>
#include <os/proc.h>

#include <cstdint>
#include <cmath>
#include <cstdlib>
#include <iterator>
#include <string>

// target of the two-finger tap on the game view
@interface OMWTwoFingerTap : NSObject
- (void)tapped:(UITapGestureRecognizer*)recognizer;
- (void)panned:(UIPanGestureRecognizer*)recognizer;
@end

// app-drawn touch controls over the game view: invisible floating stick (left), invisible look area (right), buttons
@interface OMWTouchOverlay : UIView
- (void)reset;
@end

namespace
{
    // on-screen controls (system-drawn GCVirtualController) while no keyboard, mouse or game controller is connected
    GCVirtualController* sTouchController = nil;
    // the touch controller is connected and its own (system) drawing is hidden
    bool sTouchReady = false;
    OMWTouchOverlay* sOverlay = nil;
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

    // console-style menus unless a keyboard or mouse is connected without a game controller
    bool wantsControllerMenus()
    {
        const bool keyboardOrMouse = GCKeyboard.coalescedKeyboard != nil || hasUserMouse();
        (void)keyboardOrMouse;
        return hasGameController();
    }

    // The touch controller has all elements of OpenMW's default controller bindings but sneak, view, game menu and
    // quicksave (it cannot draw L3, R3, Menu or Home). A two-finger tap opens the game menu, quicksave is Save there.
    // ponytail: no touch input for sneak and view (upgrade path: more gestures, or app-drawn controls via the hidden
    // configuration).
    void updateTouchController()
    {
        const bool wanted
            = sDevicesReported && GCKeyboard.coalescedKeyboard == nil && !hasUserMouse() && !hasGameController();
        if (wanted == (sTouchController != nil))
            return;

        if (!wanted)
        {
            sTouchReady = false;
            [sTouchController disconnect];
            [sTouchController release];
            sTouchController = nil;
            Log(Debug::Info) << "Touch controls off";
            return;
        }

        GCVirtualControllerConfiguration* configuration = [[GCVirtualControllerConfiguration alloc] init];
        configuration.elements = [NSSet setWithArray:@[ GCInputLeftThumbstick, GCInputRightThumbstick, GCInputButtonA,
            GCInputButtonB, GCInputButtonX, GCInputButtonY, GCInputLeftShoulder, GCInputRightShoulder,
            GCInputLeftTrigger, GCInputRightTrigger ]];
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
                // the overlay draws everything itself: hide the system's drawing, keep driving it by value
                for (NSString* element in @[ GCInputLeftThumbstick, GCInputRightThumbstick, GCInputButtonA, GCInputButtonB,
                         GCInputButtonX, GCInputButtonY, GCInputLeftShoulder, GCInputRightShoulder,
                         GCInputLeftTrigger, GCInputRightTrigger ])
                    [controller updateConfigurationForElement:element
                                                configuration:^GCVirtualControllerElementConfiguration*(
                                                    GCVirtualControllerElementConfiguration* elementConfiguration) {
                                                    elementConfiguration.hidden = YES;
                                                    return elementConfiguration;
                                                }];
                sTouchReady = true;
                Log(Debug::Info) << "Touch controls on";
            });
        }];
    }

    // the touch controller's undrawn Menu button is SDL's Start button (OpenMW: game menu)
    void pressStart()
    {
        GCVirtualController* controller = sTouchController;
        if (controller == nil)
            return;
        [controller setValue:1 forButtonElement:GCInputButtonMenu];
        // held across several frames: SDL reads the button state once per frame
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(),
            ^{ [controller setValue:0 forButtonElement:GCInputButtonMenu]; });
    }

    // adds the two-finger tap recognizer to SDL's window once it exists
    int addTwoFingerTap(void*, SDL_Event* event)
    {
        if (event->type != SDL_WINDOWEVENT)
            return 0;
        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        SDL_Window* window = SDL_GetWindowFromID(event->window.windowID);
        if (window == nullptr || !SDL_GetWindowWMInfo(window, &info))
            return 0;

        static OMWTwoFingerTap* target = [[OMWTwoFingerTap alloc] init]; // recognizers do not retain their target
        UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(tapped:)];
        tap.numberOfTouchesRequired = 2;
        // SDL still gets every touch, without delay
        tap.cancelsTouchesInView = NO;
        tap.delaysTouchesEnded = NO;
        [info.info.uikit.window addGestureRecognizer:tap];
        UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:target action:@selector(panned:)];
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = NO;
        pan.delaysTouchesBegan = NO;
        pan.delaysTouchesEnded = NO;
        [info.info.uikit.window addGestureRecognizer:pan];
        [pan release];
        sOverlay = [[OMWTouchOverlay alloc] initWithFrame:info.info.uikit.window.bounds];
        [info.info.uikit.window addSubview:sOverlay];
        [tap release];
        SDL_DelEventWatch(addTwoFingerTap, nullptr);
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
    enum ButtonKind
    {
        KindButton, // a GameController button element
        KindMenu,
    };

    struct ButtonSpec
    {
        const char* symbol; // SF Symbol
        const char* fallback; // text when the symbol does not exist
        __unsafe_unretained NSString* element;
        ButtonKind kind;
        // center relative to the safe area: positive from the left/top edge, negative from the right/bottom edge
        CGFloat x, y, size;
    };

    // ponytail: sizes in points, tuned for an iPhone 16 in landscape; the first thing to adjust after trying the game
    ButtonSpec* buttonSpecs(size_t* count)
    {
        static ButtonSpec specs[] = {
            // right thumb: attack in the corner, the rest in an arc around it
            { "figure.fencing", "ATK", nil, KindButton, -80, -90, 92 }, // filled in below: right trigger
            { "chevron.up", "JMP", nil, KindButton, -190, -50, 58 }, // left trigger
            { "hand.tap.fill", "USE", nil, KindButton, -70, -205, 62 }, // A
            { "hammer.fill", "WPN", nil, KindButton, -180, -140, 54 }, // X
            { "bolt.fill", "MGK", nil, KindButton, -255, -95, 54 }, // Y
            // top right: menus
            { "backpack.fill", "INV", nil, KindButton, -45, 40, 50 }, // B
            { "book.fill", "JRN", nil, KindButton, -105, 40, 50 }, // left shoulder
            { "moon.zzz.fill", "RST", nil, KindButton, -165, 40, 50 }, // right shoulder
            { "pause.fill", "ESC", nil, KindMenu, -225, 40, 50 },
            // left: sneak, view
            { "eye.slash.fill", "SNK", nil, KindButton, 55, -50, 54 }, // left thumbstick button
            { "camera.fill", "CAM", nil, KindButton, 55, 40, 46 }, // right thumbstick button
        };
        static bool init = false;
        if (!init)
        {
            init = true;
            specs[0].element = GCInputRightTrigger;
            specs[1].element = GCInputLeftTrigger;
            specs[2].element = GCInputButtonA;
            specs[3].element = GCInputButtonX;
            specs[4].element = GCInputButtonY;
            specs[5].element = GCInputButtonB;
            specs[6].element = GCInputLeftShoulder;
            specs[7].element = GCInputRightShoulder;
            specs[9].element = GCInputLeftThumbstickButton;
            specs[10].element = GCInputRightThumbstickButton;
        }
        *count = sizeof(specs) / sizeof(specs[0]);
        return specs;
    }

    void setButton(NSString* element, float value)
    {
        GCVirtualController* controller = sTouchController;
        if (controller == nil || !sTouchReady || element == nil)
            return;
        @try
        {
            [controller setValue:value forButtonElement:element];
        }
        @catch (NSException*)
        {
            // an element the controller does not have (the thumbstick buttons)
        }
    }

    void setStick(NSString* element, float x, float y)
    {
        GCVirtualController* controller = sTouchController;
        if (controller == nil || !sTouchReady)
            return;
        @try
        {
            [controller setPosition:CGPointMake(x, y) forDirectionPadElement:element];
        }
        @catch (NSException*)
        {
        }
    }

    // Escape (back out of a window or the settings) and close the on-screen keyboard
    void pressEscape()
    {
        if (SDL_IsTextInputActive() == SDL_TRUE)
            SDL_StopTextInput();
        for (int i = 0; i < 2; ++i)
        {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * (NSEC_PER_SEC / 20)), dispatch_get_main_queue(), ^{
                SDL_Event event{};
                event.type = i == 0 ? SDL_KEYDOWN : SDL_KEYUP;
                event.key.state = i == 0 ? SDL_PRESSED : SDL_RELEASED;
                event.key.keysym.scancode = SDL_SCANCODE_ESCAPE;
                event.key.keysym.sym = SDLK_ESCAPE;
                SDL_PushEvent(&event);
            });
        }
    }

    constexpr CGFloat stickRadius = 55; // finger travel for full speed
    constexpr CGFloat lookGain = 0.22f; // stick deflection per point of finger movement per frame
}

@implementation OMWTouchOverlay
{
    NSMutableArray<UIView*>* mViews;
    NSMutableDictionary<NSValue*, NSNumber*>* mTouchButton; // touch -> button index
    UITouch* mMoveTouch;
    CGPoint mMoveOrigin;
    UITouch* mLookTouch;
    CGPoint mLookLast;
    CGPoint mLookDelta;
    CADisplayLink* mLink;
    UIButton* mBack;
    BOOL mGui;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil)
        return nil;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.multipleTouchEnabled = YES;
    self.backgroundColor = UIColor.clearColor;
    self.hidden = YES;
    mViews = [[NSMutableArray alloc] init];
    mTouchButton = [[NSMutableDictionary alloc] init];

    size_t count = 0;
    ButtonSpec* specs = buttonSpecs(&count);
    for (size_t i = 0; i < count; ++i)
    {
        UIView* view = [[UIView alloc] init];
        view.userInteractionEnabled = NO;
        view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.45];
        view.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
        view.layer.borderWidth = 2;
        UIImage* image = [UIImage systemImageNamed:[NSString stringWithUTF8String:specs[i].symbol]];
        if (image != nil)
        {
            UIImageView* icon = [[UIImageView alloc] initWithImage:image];
            icon.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
            icon.contentMode = UIViewContentModeScaleAspectFit;
            icon.tag = 1;
            [view addSubview:icon];
            [icon release];
        }
        else
        {
            UILabel* label = [[UILabel alloc] init];
            label.text = [NSString stringWithUTF8String:specs[i].fallback];
            label.textColor = UIColor.whiteColor;
            label.textAlignment = NSTextAlignmentCenter;
            label.font = [UIFont boldSystemFontOfSize:13];
            label.tag = 1;
            [view addSubview:label];
            [label release];
        }
        [self addSubview:view];
        [mViews addObject:view];
        [view release];
    }

    // in menus: the only thing drawn, a big back button (also closes the keyboard)
    mBack = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    mBack.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.55];
    mBack.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    mBack.layer.borderWidth = 2;
    mBack.layer.cornerRadius = 28;
    UIImage* backImage = [UIImage systemImageNamed:@"chevron.backward"];
    if (backImage != nil)
    {
        [mBack setImage:backImage forState:UIControlStateNormal];
        mBack.tintColor = UIColor.whiteColor;
    }
    else
        [mBack setTitle:@"Back" forState:UIControlStateNormal];
    [mBack addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];
    mBack.hidden = YES;
    [self addSubview:mBack];

    mLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [mLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    const UIEdgeInsets inset = self.safeAreaInsets;
    const CGRect area = UIEdgeInsetsInsetRect(self.bounds, UIEdgeInsetsMake(inset.top, MAX(inset.left, 16),
                                                  MAX(inset.bottom, 12), MAX(inset.right, 16)));
    mBack.frame = CGRectMake(CGRectGetMaxX(area) - 64, CGRectGetMinY(area) + 8, 56, 56);
    size_t count = 0;
    ButtonSpec* specs = buttonSpecs(&count);
    for (size_t i = 0; i < count && i < mViews.count; ++i)
    {
        const ButtonSpec& spec = specs[i];
        const CGFloat cx = spec.x >= 0 ? CGRectGetMinX(area) + spec.x : CGRectGetMaxX(area) + spec.x;
        const CGFloat cy = spec.y >= 0 ? CGRectGetMinY(area) + spec.y : CGRectGetMaxY(area) + spec.y;
        UIView* view = mViews[i];
        view.frame = CGRectMake(cx - spec.size / 2, cy - spec.size / 2, spec.size, spec.size);
        view.layer.cornerRadius = spec.size / 2;
        UIView* content = [view viewWithTag:1];
        content.frame = CGRectInset(view.bounds, spec.size * 0.22, spec.size * 0.22);
    }
}

- (NSInteger)buttonAt:(CGPoint)point
{
    for (NSUInteger i = 0; i < mViews.count; ++i)
    {
        UIView* view = mViews[i];
        // a little generous: thumbs miss
        if (CGRectContainsPoint(CGRectInset(view.frame, -10, -10), point))
            return (NSInteger)i;
    }
    return -1;
}

- (void)press:(NSInteger)index down:(BOOL)down
{
    size_t count = 0;
    ButtonSpec* specs = buttonSpecs(&count);
    if (index < 0 || (size_t)index >= count)
        return;
    mViews[index].alpha = down ? 1.0 : 0.85;
    mViews[index].transform = down ? CGAffineTransformMakeScale(0.92, 0.92) : CGAffineTransformIdentity;
    if (specs[index].kind == KindMenu)
    {
        if (down)
            pressStart();
        return;
    }
    setButton(specs[index].element, down ? 1.f : 0.f);
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    for (UITouch* touch in touches)
    {
        const CGPoint point = [touch locationInView:self];
        const NSInteger button = [self buttonAt:point];
        if (button >= 0)
        {
            mTouchButton[[NSValue valueWithNonretainedObject:touch]] = @(button);
            [self press:button down:YES];
        }
        else if (point.x < self.bounds.size.width * 0.5)
        {
            if (mMoveTouch == nil)
            {
                mMoveTouch = touch;
                mMoveOrigin = point; // floating stick: wherever the thumb lands
            }
        }
        else if (mLookTouch == nil)
        {
            mLookTouch = touch;
            mLookLast = point;
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    for (UITouch* touch in touches)
    {
        const CGPoint point = [touch locationInView:self];
        if (touch == mMoveTouch)
        {
            CGFloat dx = (point.x - mMoveOrigin.x) / stickRadius;
            CGFloat dy = (point.y - mMoveOrigin.y) / stickRadius;
            const CGFloat length = hypot(dx, dy);
            if (length > 1)
            {
                dx /= length;
                dy /= length;
                // the stick follows a thumb that goes further
                mMoveOrigin.x = point.x - dx * stickRadius;
                mMoveOrigin.y = point.y - dy * stickRadius;
            }
            // small dead zone against a shaking thumb
            if (length < 0.12)
                dx = dy = 0;
            setStick(GCInputLeftThumbstick, dx, -dy);
        }
        else if (touch == mLookTouch)
        {
            mLookDelta.x += point.x - mLookLast.x;
            mLookDelta.y += point.y - mLookLast.y;
            mLookLast = point;
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    for (UITouch* touch in touches)
    {
        NSValue* key = [NSValue valueWithNonretainedObject:touch];
        NSNumber* button = mTouchButton[key];
        if (button != nil)
        {
            [self press:button.integerValue down:NO];
            [mTouchButton removeObjectForKey:key];
        }
        if (touch == mMoveTouch)
        {
            mMoveTouch = nil;
            setStick(GCInputLeftThumbstick, 0, 0);
        }
        if (touch == mLookTouch)
        {
            mLookTouch = nil;
            mLookDelta = CGPointZero;
            setStick(GCInputRightThumbstick, 0, 0);
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self touchesEnded:touches withEvent:event];
}

// let go of everything (menus open, controller gone)
- (void)reset
{
    for (NSValue* key in mTouchButton.allKeys)
        [self press:mTouchButton[key].integerValue down:NO];
    [mTouchButton removeAllObjects];
    mMoveTouch = nil;
    mLookTouch = nil;
    mLookDelta = CGPointZero;
    setStick(GCInputLeftThumbstick, 0, 0);
    setStick(GCInputRightThumbstick, 0, 0);
}

- (void)backTapped
{
    pressEscape();
}

- (void)tick:(CADisplayLink*)link
{
    const BOOL ready = sTouchReady;
    const BOOL gui = MWGui::WindowManager::guiModeActive();
    // the game's own views are added to the window later and would cover the overlay
    UIView* parent = self.superview;
    if (parent != nil && parent.subviews.lastObject != self)
        [parent bringSubviewToFront:self];
    static int lastLogged = -1;
    const int state = (ready ? 1 : 0) | (gui ? 2 : 0) | (parent != nil ? 4 : 0);
    if (state != lastLogged)
    {
        lastLogged = state;
        Log(Debug::Info) << "Touch overlay: ready " << (ready ? "yes" : "no") << ", menus " << (gui ? "yes" : "no")
                         << ", in window " << (parent != nil ? "yes" : "no") << ", frame "
                         << (int)self.bounds.size.width << "x" << (int)self.bounds.size.height;
    }
    if (self.hidden == ready)
        self.hidden = !ready;
    if (!ready)
        return;
    if (gui != mGui)
    {
        mGui = gui;
        if (gui)
            [self reset];
        for (UIView* view in mViews)
            view.hidden = gui;
        mBack.hidden = !gui;
    }
    if (gui)
        return;
    // look: the finger's movement since the last frame is the right stick's deflection this frame
    CGFloat x = MAX(-1, MIN(1, mLookDelta.x * lookGain));
    CGFloat y = MAX(-1, MIN(1, mLookDelta.y * lookGain));
    mLookDelta = CGPointZero;
    if (mLookTouch != nil || x != 0 || y != 0)
        setStick(GCInputRightThumbstick, x, -y);
}

// in the game everything is ours; in menus only the back button, the rest goes to SDL (taps become mouse clicks)
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event
{
    if (self.hidden)
        return nil;
    UIView* hit = [super hitTest:point withEvent:event];
    if (mGui)
        return hit == self ? nil : hit;
    return hit;
}
@end

@implementation OMWTwoFingerTap
- (void)tapped:(UITapGestureRecognizer*)recognizer
{
    // in the game the overlay has its own pause button, and two thumbs tapping at once must not open the menu
    if (MWGui::WindowManager::guiModeActive())
        pressStart();
}

// a finger drag in menus scrolls lists and text like a mouse wheel
- (void)panned:(UIPanGestureRecognizer*)recognizer
{
    static CGFloat rest = 0;
    if (!MWGui::WindowManager::guiModeActive())
        return;
    if (recognizer.state == UIGestureRecognizerStateBegan)
        rest = 0;
    rest += [recognizer translationInView:recognizer.view].y;
    [recognizer setTranslation:CGPointZero inView:recognizer.view];
    constexpr CGFloat step = 22; // points of finger travel per wheel notch
    while (std::abs(rest) >= step)
    {
        SDL_Event event{};
        event.type = SDL_MOUSEWHEEL;
        event.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
        // finger up -> content up -> wheel towards the user (negative)
        event.wheel.y = rest > 0 ? 1 : -1;
        SDL_PushEvent(&event);
        rest += rest > 0 ? -step : step;
    }
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
        SDL_AddEventWatch(addTwoFingerTap, nullptr);
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
    // a phone screen needs a much bigger menu/text scale than a desktop; only while it is at the default 1.0
    if (Settings::gui().mScalingFactor.get() == 1.0f)
        Settings::gui().mScalingFactor.set(2.6f);
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
