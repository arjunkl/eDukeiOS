#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>

#include "SDL.h"

#include "../../../source/build/include/compat.h"
#include "../../../source/duke3d/src/duke3d.h"
#include "../../../source/duke3d/src/function.h"
#include "../../../source/duke3d/src/in_android.h"
#include "../../../source/mact/include/control.h"

#include <cmath>

namespace
{
static void EDuke32UncaughtExceptionHandler(NSException *exception)
{
    fprintf(stderr, "\nEDUKE32_IOS_OBJC_EXCEPTION: %s: %s\n%s\n",
            exception.name.UTF8String,
            exception.reason.UTF8String,
            exception.callStackSymbols.description.UTF8String);
    fflush(stderr);
}

constexpr CGFloat kMovementDeadZone = 10.0;
constexpr CGFloat kLookScale = 0.018;
constexpr CGFloat kGyroScale = 6.0;
constexpr CGFloat kDirectMouseFactor = 2048.0;

static CGPoint g_mapDelta = CGPointZero;

static SDL_Window *ActiveSDLWindow()
{
    SDL_Window *window = SDL_GetKeyboardFocus();
    if (!window)
        window = SDL_GetMouseFocus();
    if (!window)
        window = SDL_GetWindowFromID(1);
    return window;
}

static void PushKey(SDL_Scancode scancode)
{
    SDL_Window *window = ActiveSDLWindow();
    Uint32 const windowID = window ? SDL_GetWindowID(window) : 0;

    SDL_Event event = {};
    event.type = SDL_KEYDOWN;
    event.key.windowID = windowID;
    event.key.state = SDL_PRESSED;
    event.key.repeat = 0;
    event.key.keysym.scancode = scancode;
    event.key.keysym.sym = SDL_GetKeyFromScancode(scancode);
    SDL_PushEvent(&event);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        SDL_Event release = {};
        release.type = SDL_KEYUP;
        release.key.windowID = windowID;
        release.key.state = SDL_RELEASED;
        release.key.repeat = 0;
        release.key.keysym.scancode = scancode;
        release.key.keysym.sym = SDL_GetKeyFromScancode(scancode);
        SDL_PushEvent(&release);
    });
}

static void PulseAction(int action)
{
    AndroidAction(1, action);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        AndroidAction(0, action);
    });
}

static void PushSwipeKey(CGPoint origin, CGPoint point)
{
    CGFloat const dx = point.x - origin.x;
    CGFloat const dy = point.y - origin.y;

    if (fabs(dx) > fabs(dy))
        PushKey(dx < 0.0 ? SDL_SCANCODE_LEFT : SDL_SCANCODE_RIGHT);
    else
        PushKey(dy < 0.0 ? SDL_SCANCODE_UP : SDL_SCANCODE_DOWN);
}

static CGRect CircleRect(CGPoint center, CGFloat radius)
{
    return CGRectMake(center.x - radius, center.y - radius, radius * 2.0, radius * 2.0);
}
}

extern "C" void AndroidMove(float forward, float strafe)
{
    droidinput.forwardmove = fmaxf(-1.f, fminf(1.f, forward));
    droidinput.sidemove = fmaxf(-1.f, fminf(1.f, strafe));
}

extern "C" void AndroidLook(float yaw, float pitch)
{
    droidinput.yaw += yaw;
    droidinput.pitch += droidinput.invertLook ? -pitch : pitch;
}

extern "C" void AndroidAction(int state, int action)
{
    uint64_t const mask = UINT64_C(1) << static_cast<uint64_t>(action);

    if (state)
    {
        droidinput.functionSticky |= mask;
        droidinput.functionHeld |= mask;
    }
    else
        droidinput.functionHeld &= ~mask;
}

extern "C" void AndroidAutomapControl(float zoom, float dx, float dy)
{
    (void)zoom;
    g_mapDelta.x += dx;
    g_mapDelta.y += dy;
}

void CONTROL_Android_ScrollMap(int32_t *angle, int32_t *x, int32_t *y, uint16_t *zoom)
{
    (void)angle;
    (void)zoom;
    *x += static_cast<int32_t>(g_mapDelta.x * 30000.f);
    *y += static_cast<int32_t>(g_mapDelta.y * 30000.f);
    g_mapDelta = CGPointZero;
}

void CONTROL_Android_SetLastWeapon(int weapon)
{
    droidinput.lastWeapon = weapon;
}

void CONTROL_Android_ClearButton(int32_t button)
{
    droidinput.functionHeld &= ~(UINT64_C(1) << static_cast<uint64_t>(button));
}

void CONTROL_Android_PollDevices(ControlInfo *info)
{
    info->dz += static_cast<int32_t>(-droidinput.forwardmove * ANDROIDMOVEFACTOR);
    info->dx += static_cast<int32_t>(droidinput.sidemove * ANDROIDMOVEFACTOR);

    // Duke treats dyaw/dpitch as full-range controller axes. Small, relative
    // touch and gyro deltas disappear after that path's 32767 normalization.
    // Feed relative aim through the mouse channels instead, where values are
    // consumed directly, and force free-look on for vertical aim.
    double const lookYaw = droidinput.yaw;
    double const lookPitch = droidinput.pitch;
    info->mousex += static_cast<int32_t>(nearbyint(lookYaw * kDirectMouseFactor));
    info->mousey += static_cast<int32_t>(nearbyint(lookPitch * kDirectMouseFactor));
    if (lookYaw != 0.0 || lookPitch != 0.0)
    {
        g_myAimMode = 1;
        static int32_t aimDiagnosticCount = 0;
        if (aimDiagnosticCount < 20)
        {
            fprintf(stderr, "EDUKE32_IOS_AIM: yaw=%.4f pitch=%.4f mouse=(%d,%d)\n",
                    lookYaw, lookPitch, info->mousex, info->mousey);
            fflush(stderr);
            ++aimDiagnosticCount;
        }
    }

    droidinput.pitch = 0.0;
    droidinput.yaw = 0.0;

    uint64_t const touchButtons = droidinput.functionSticky | droidinput.functionHeld;
    for (int32_t action = 0; action < CONTROL_NUM_FLAGS; ++action)
        if (touchButtons & (UINT64_C(1) << static_cast<uint64_t>(action)))
            CONTROL_ButtonFlags[action] = 1;

    droidinput.functionSticky = 0;
}

@interface EDuke32ControlsView : UIView
{
    UITouch *_moveTouch;
    UITouch *_lookTouch;
    CGPoint _moveOrigin;
    CGPoint _lookPrevious;
    CGPoint _lookOrigin;
    NSMutableDictionary *_touchActions;
    CMMotionManager *_motionManager;
    UITapGestureRecognizer *_gyroToggleGesture;
    UILabel *_gyroStatusLabel;
    BOOL _gyroEnabled;
}
@end

@implementation EDuke32ControlsView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;
    self.opaque = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _touchActions = [[NSMutableDictionary alloc] init];
    _gyroEnabled = YES;

    _gyroToggleGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleGyro:)];
    _gyroToggleGesture.numberOfTouchesRequired = 3;
    _gyroToggleGesture.numberOfTapsRequired = 2;
    _gyroToggleGesture.cancelsTouchesInView = YES;
    [self addGestureRecognizer:_gyroToggleGesture];

    _gyroStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, 150.0, 42.0)];
    _gyroStatusLabel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.72];
    _gyroStatusLabel.textColor = UIColor.whiteColor;
    _gyroStatusLabel.font = [UIFont boldSystemFontOfSize:15.0];
    _gyroStatusLabel.textAlignment = NSTextAlignmentCenter;
    _gyroStatusLabel.layer.cornerRadius = 12.0;
    _gyroStatusLabel.clipsToBounds = YES;
    _gyroStatusLabel.alpha = 0.0;
    [self addSubview:_gyroStatusLabel];

    _motionManager = [[CMMotionManager alloc] init];
    fprintf(stderr, "EDUKE32_IOS_GYRO: available=%d enabled=%d\n",
            _motionManager.deviceMotionAvailable ? 1 : 0, _gyroEnabled ? 1 : 0);
    fflush(stderr);
    if (_motionManager.deviceMotionAvailable)
    {
        _motionManager.deviceMotionUpdateInterval = 1.0 / 100.0;
        __block EDuke32ControlsView *view = self;
        [_motionManager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical
                                                            toQueue:NSOperationQueue.mainQueue
                                                        withHandler:^(CMDeviceMotion *motion, NSError *error) {
            if (error || !view->_gyroEnabled || UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
                return;

            CMRotationRate const rate = motion.rotationRate;
            UIInterfaceOrientation const orientation = view.window.windowScene.interfaceOrientation;
            CGFloat const direction = orientation == UIInterfaceOrientationLandscapeRight ? -1.0 : 1.0;
            AndroidLook(static_cast<float>(rate.y * kGyroScale * direction * _motionManager.deviceMotionUpdateInterval),
                        static_cast<float>(rate.x * kGyroScale * direction * _motionManager.deviceMotionUpdateInterval));
        }];
    }

    return self;
}

- (void)dealloc
{
    [_motionManager stopDeviceMotionUpdates];
    [_motionManager release];
    [_gyroToggleGesture release];
    [_gyroStatusLabel release];
    [_touchActions release];
    [super dealloc];
}

- (CGPoint)useCenter { return CGPointMake(CGRectGetWidth(self.bounds) - 150.0, CGRectGetHeight(self.bounds) - 105.0); }
- (CGPoint)jumpCenter { return CGPointMake(CGRectGetWidth(self.bounds) - 72.0, CGRectGetHeight(self.bounds) - 166.0); }
- (CGPoint)crouchCenter { return CGPointMake(CGRectGetWidth(self.bounds) - 153.0, CGRectGetHeight(self.bounds) - 42.0); }
- (CGPoint)weaponCenter { return CGPointMake(CGRectGetWidth(self.bounds) - 226.0, CGRectGetHeight(self.bounds) - 46.0); }
- (CGPoint)pauseCenter { return CGPointMake(CGRectGetWidth(self.bounds) - 35.0, 35.0); }

- (void)layoutSubviews
{
    [super layoutSubviews];
    _gyroStatusLabel.center = CGPointMake(CGRectGetMidX(self.bounds), 42.0);
}

- (void)toggleGyro:(UITapGestureRecognizer *)recognizer
{
    if (recognizer.state != UIGestureRecognizerStateRecognized)
        return;

    _gyroEnabled = !_gyroEnabled;
    _gyroStatusLabel.text = _gyroEnabled ? @"GYRO ON" : @"GYRO OFF";
    _gyroStatusLabel.alpha = 1.0;

    UINotificationFeedbackGenerator *feedback = [[[UINotificationFeedbackGenerator alloc] init] autorelease];
    [feedback notificationOccurred:_gyroEnabled ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeWarning];

    [UIView animateWithDuration:0.25
                          delay:0.8
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self->_gyroStatusLabel.alpha = 0.0;
    } completion:nil];
}

- (touchscreemode_t)touchMode
{
    DukePlayer_t *player = g_player[myconnectindex].ps;
    if (!player)
        return TOUCH_SCREEN_BLANK_TAP;
    if (player->gm & MODE_MENU)
        return TOUCH_SCREEN_MENU;
    if (player->gm & MODE_GAME)
        return TOUCH_SCREEN_GAME;
    return TOUCH_SCREEN_BLANK_TAP;
}

- (NSInteger)actionAtPoint:(CGPoint)point
{
    if (CGRectContainsPoint(CircleRect(self.pauseCenter, 25.0), point)) return -2;
    if ([self touchMode] != TOUCH_SCREEN_GAME)
        return -1;

    if (CGRectContainsPoint(CircleRect(self.useCenter, 31.0), point)) return gamefunc_Open;
    if (CGRectContainsPoint(CircleRect(self.jumpCenter, 31.0), point)) return gamefunc_Jump;
    if (CGRectContainsPoint(CircleRect(self.crouchCenter, 28.0), point)) return gamefunc_Crouch;
    if (CGRectContainsPoint(CircleRect(self.weaponCenter, 27.0), point)) return gamefunc_Next_Weapon;
    return -1;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)event;
    for (UITouch *touch in touches)
    {
        CGPoint const point = [touch locationInView:self];
        NSInteger const action = [self actionAtPoint:point];
        fprintf(stderr, "EDUKE32_IOS_TOUCH: began x=%.1f y=%.1f action=%ld\n",
                point.x, point.y, (long)action);
        fflush(stderr);

        if (action >= 0)
        {
            AndroidAction(1, static_cast<int>(action));
            [_touchActions setObject:@(action) forKey:[NSValue valueWithNonretainedObject:touch]];
        }
        else if (action == -2)
            PushKey(SDL_SCANCODE_ESCAPE);
        else if (!_moveTouch && point.x < CGRectGetWidth(self.bounds) * 0.46)
        {
            _moveTouch = touch;
            _moveOrigin = point;
        }
        else if (!_lookTouch)
        {
            _lookTouch = touch;
            _lookOrigin = point;
            _lookPrevious = point;
        }
    }
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)event;
    for (UITouch *touch in touches)
    {
        CGPoint const point = [touch locationInView:self];
        if ([self touchMode] == TOUCH_SCREEN_GAME)
        {
            if (touch == _moveTouch)
            {
                CGFloat const dx = point.x - _moveOrigin.x;
                CGFloat const dy = point.y - _moveOrigin.y;

                // Deliberately digital, like keyboard movement: each active
                // axis immediately reaches full speed, including diagonals.
                float const strafe = fabs(dx) >= kMovementDeadZone ? (dx < 0.0 ? -1.f : 1.f) : 0.f;
                float const forward = fabs(dy) >= kMovementDeadZone ? (dy < 0.0 ? 1.f : -1.f) : 0.f;
                AndroidMove(forward, strafe);
            }
            else if (touch == _lookTouch)
            {
                CGFloat const dx = point.x - _lookPrevious.x;
                CGFloat const dy = point.y - _lookPrevious.y;
                AndroidLook(static_cast<float>(dx * kLookScale), static_cast<float>(dy * kLookScale));
                _lookPrevious = point;
            }
        }
    }
    [self setNeedsDisplay];
}

- (void)finishTouches:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled
{
    for (UITouch *touch in touches)
    {
        NSValue *key = [NSValue valueWithNonretainedObject:touch];
        NSNumber *action = [_touchActions objectForKey:key];
        if (action)
        {
            AndroidAction(0, action.intValue);
            [_touchActions removeObjectForKey:key];
        }

        touchscreemode_t const mode = [self touchMode];
        CGPoint const point = [touch locationInView:self];

        if (touch == _moveTouch)
        {
            CGFloat const distance = hypot(point.x - _moveOrigin.x, point.y - _moveOrigin.y);
            _moveTouch = nil;
            AndroidMove(0.f, 0.f);

            if (!cancelled && mode != TOUCH_SCREEN_GAME)
            {
                if (distance < 18.0)
                    PushKey(SDL_SCANCODE_RETURN);
                else
                    PushSwipeKey(_moveOrigin, point);
            }
        }
        else if (touch == _lookTouch)
        {
            CGFloat const distance = hypot(point.x - _lookOrigin.x, point.y - _lookOrigin.y);
            _lookTouch = nil;

            if (!cancelled)
            {
                if (mode == TOUCH_SCREEN_GAME)
                {
                    if (distance < 12.0)
                        PulseAction(gamefunc_Fire);
                }
                else if (distance < 18.0)
                    PushKey(SDL_SCANCODE_RETURN);
                else
                    PushSwipeKey(_lookOrigin, point);
            }
        }
    }
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)event;
    [self finishTouches:touches cancelled:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)event;
    [self finishTouches:touches cancelled:YES];
}

- (void)drawCircleAt:(CGPoint)center radius:(CGFloat)radius label:(NSString *)label active:(BOOL)active
{
    CGContextRef const context = UIGraphicsGetCurrentContext();
    UIColor *fill = [UIColor colorWithWhite:active ? 0.95 : 0.12 alpha:active ? 0.45 : 0.30];
    UIColor *stroke = [UIColor colorWithWhite:1.0 alpha:0.58];
    CGContextSetFillColorWithColor(context, fill.CGColor);
    CGContextSetStrokeColorWithColor(context, stroke.CGColor);
    CGContextSetLineWidth(context, 1.5);
    CGContextAddEllipseInRect(context, CircleRect(center, radius));
    CGContextDrawPath(context, kCGPathFillStroke);

    NSDictionary *attributes = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:11.0],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.85]
    };
    CGSize const size = [label sizeWithAttributes:attributes];
    [label drawAtPoint:CGPointMake(center.x - size.width * 0.5, center.y - size.height * 0.5) withAttributes:attributes];
}

- (BOOL)isActionActive:(NSInteger)action
{
    return [[_touchActions allValues] containsObject:@(action)];
}

- (void)drawRect:(CGRect)rect
{
    (void)rect;
    if ([self touchMode] == TOUCH_SCREEN_GAME)
    {
        [self drawCircleAt:self.useCenter radius:31.0 label:@"USE" active:[self isActionActive:gamefunc_Open]];
        [self drawCircleAt:self.jumpCenter radius:31.0 label:@"JUMP" active:[self isActionActive:gamefunc_Jump]];
        [self drawCircleAt:self.crouchCenter radius:28.0 label:@"DUCK" active:[self isActionActive:gamefunc_Crouch]];
        [self drawCircleAt:self.weaponCenter radius:27.0 label:@"NEXT" active:[self isActionActive:gamefunc_Next_Weapon]];
    }
    [self drawCircleAt:self.pauseCenter radius:25.0 label:@"II" active:NO];
}

@end

@interface EDuke32ControlsInstaller : NSObject
@end

@implementation EDuke32ControlsInstaller

+ (void)load
{
    NSSetUncaughtExceptionHandler(&EDuke32UncaughtExceptionHandler);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(installControls)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [self performSelector:@selector(installControls) withObject:nil afterDelay:0.75];
    });
}

+ (UIWindow *)activeWindow
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (window.isKeyWindow)
                return window;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

+ (void)installControls
{
    UIWindow *window = [self activeWindow];
    if (!window)
    {
        [self performSelector:@selector(installControls) withObject:nil afterDelay:0.5];
        return;
    }

    NSInteger const tag = 0x4544554B;
    if ([window viewWithTag:tag])
        return;

    EDuke32ControlsView *controls = [[[EDuke32ControlsView alloc] initWithFrame:window.bounds] autorelease];
    controls.tag = tag;
    [window addSubview:controls];
}

@end
