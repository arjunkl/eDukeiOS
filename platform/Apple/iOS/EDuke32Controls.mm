#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include "SDL.h"

#include "../../../source/build/include/compat.h"
#include "../../../source/duke3d/src/duke3d.h"
#include "../../../source/duke3d/src/function.h"
#include "../../../source/duke3d/src/in_android.h"
#include "../../../source/mact/include/control.h"

#include <cmath>

namespace
{
static BOOL g_usePolymost = NO;

static void EDuke32UncaughtExceptionHandler(NSException *exception)
{
    fprintf(stderr, "\nEDUKE32_IOS_OBJC_EXCEPTION: %s: %s\n%s\n",
            exception.name.UTF8String,
            exception.reason.UTF8String,
            exception.callStackSymbols.description.UTF8String);
    fflush(stderr);
}

constexpr CGFloat kMovementDeadZone = 12.0;
constexpr CGFloat kMovementDiagonalRatio = 0.55;
constexpr CGFloat kLookGestureDisplacementSlop = 4.0;
constexpr CGFloat kLookGestureTravelSlop = 6.0;
constexpr int64_t kLookHoldFireDelayMilliseconds = 125;
constexpr CGFloat kDefaultLookScale = 0.018;
constexpr CGFloat kDefaultGyroScale = 6.0;
constexpr CGFloat kDirectMouseFactor = 2048.0;

enum IOSControlIndex : NSInteger
{
    kControlUse = 0,
    kControlJump,
    kControlCrouch,
    kControlWeapon,
    kControlPause,
    // Keep Fire after the existing controls so previously saved layout keys
    // continue to refer to the same buttons.
    kControlFire,
    kControlCount
};

constexpr NSInteger kNoControl = -1;

static NSString *LayoutKey(NSInteger control, NSString *component)
{
    return [NSString stringWithFormat:@"eDukeiOS.control.%ld.%@", (long)control, component];
}

static CGPoint g_mapDelta = CGPointZero;
static volatile BOOL g_launcherActive = NO;

static SDL_Window *ActiveSDLWindow()
{
    SDL_Window *window = SDL_GetKeyboardFocus();
    if (!window)
        window = SDL_GetMouseFocus();
    if (!window)
        window = SDL_GetWindowFromID(1);
    return window;
}

static void PushApplicationEvent(Uint32 type)
{
    SDL_Event event = {};
    event.type = type;
    if (SDL_PushEvent(&event) < 0)
    {
        fprintf(stderr, "EDUKE32_IOS_LIFECYCLE: could not push event %u: %s\n",
                type, SDL_GetError());
        fflush(stderr);
    }
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

extern "C" void EDuke32_IOS_GetRenderSize(int32_t *width, int32_t *height)
{
    CGRect const bounds = UIScreen.mainScreen.bounds;
    CGFloat const longEdge = fmax(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat const shortEdge = fmin(CGRectGetWidth(bounds), CGRectGetHeight(bounds));

    // Preserve the exact device aspect ratio while keeping the 8-bit software
    // renderer at a practical resolution on larger iPads.
    CGFloat const renderScale = shortEdge > 600.0 ? 600.0 / shortEdge : 1.0;
    *width = static_cast<int32_t>(floor(longEdge * renderScale)) & ~1;
    *height = static_cast<int32_t>(floor(shortEdge * renderScale)) & ~1;
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
    // These are digital touch directions, so use the controller's full axis
    // extent. ANDROIDMOVEFACTOR is only about 20% of full keyboard speed.
    constexpr int32_t kTouchMovementAxis = 31129; // 95% of the full controller range
    info->dz += static_cast<int32_t>(-droidinput.forwardmove * kTouchMovementAxis);
    info->dx += static_cast<int32_t>(droidinput.sidemove * kTouchMovementAxis);

    // Duke treats dyaw/dpitch as full-range controller axes. Small, relative
    // touch and gyro deltas disappear after that path's 32767 normalization.
    // Feed relative aim through the mouse channels instead, where values are
    // consumed directly, and force free-look on for vertical aim.
    double const lookYaw = droidinput.yaw;
    double const lookPitch = droidinput.pitch;
    info->mousex += static_cast<int32_t>(nearbyint(lookYaw * kDirectMouseFactor));
    // UIKit's vertical touch/motion coordinates increase downward, opposite
    // Duke's horizon direction.
    info->mousey -= static_cast<int32_t>(nearbyint(lookPitch * kDirectMouseFactor));
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

@interface EDuke32ControlsView : UIView <UIGestureRecognizerDelegate>
{
    UITouch *_moveTouch;
    UITouch *_lookTouch;
    CGPoint _moveOrigin;
    CGPoint _lookPrevious;
    CGPoint _lookOrigin;
    NSMutableDictionary *_touchActions;
    CMMotionManager *_motionManager;
    UILongPressGestureRecognizer *_pauseLongPressGesture;
    UILabel *_gyroStatusLabel;
    UIView *_editorPanel;
    UIButton *_fireToggleButton;
    UIButton *_gyroButton;
    UIButton *_doneButton;
    UILabel *_touchSensitivityLabel;
    UILabel *_gyroSensitivityLabel;
    UISlider *_touchSensitivitySlider;
    UISlider *_gyroSensitivitySlider;
    BOOL _gyroEnabled;
    BOOL _fireButtonEnabled;
    float _touchAimScale;
    float _gyroAimScale;
    BOOL _lookMoved;
    BOOL _lookFiring;
    CGFloat _lookTotalTravel;

    BOOL _layoutEditing;
    BOOL _controlLayoutReady;
    CGSize _controlLayoutSize;
    CGPoint _controlCenters[kControlCount];
    CGFloat _controlRadii[kControlCount];
    UITouch *_editTouch;
    NSInteger _editingControl;
    BOOL _editingResize;
    UITouch *_pauseTouch;
    BOOL _pauseHoldActivated;
}
- (void)cancelActiveTouchesForBackground;
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

    NSUserDefaults *preferences = NSUserDefaults.standardUserDefaults;
    _gyroEnabled = [preferences objectForKey:@"eDukeiOS.gyro.enabled"]
        ? [preferences boolForKey:@"eDukeiOS.gyro.enabled"] : YES;
    _fireButtonEnabled = [preferences objectForKey:@"eDukeiOS.fireButton.enabled"]
        ? [preferences boolForKey:@"eDukeiOS.fireButton.enabled"] : YES;
    _touchAimScale = [preferences objectForKey:@"eDukeiOS.aim.touch"]
        ? [preferences floatForKey:@"eDukeiOS.aim.touch"] : kDefaultLookScale;
    _gyroAimScale = [preferences objectForKey:@"eDukeiOS.aim.gyro"]
        ? [preferences floatForKey:@"eDukeiOS.aim.gyro"] : kDefaultGyroScale;

    _editingControl = kNoControl;

    _pauseLongPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(pauseLongPress:)];
    _pauseLongPressGesture.minimumPressDuration = 2.0;
    _pauseLongPressGesture.allowableMovement = 32.0;
    _pauseLongPressGesture.cancelsTouchesInView = NO;
    _pauseLongPressGesture.delegate = self;
    [self addGestureRecognizer:_pauseLongPressGesture];

    _gyroStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, 330.0, 42.0)];
    _gyroStatusLabel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.72];
    _gyroStatusLabel.textColor = UIColor.whiteColor;
    _gyroStatusLabel.font = [UIFont boldSystemFontOfSize:15.0];
    _gyroStatusLabel.textAlignment = NSTextAlignmentCenter;
    _gyroStatusLabel.layer.cornerRadius = 12.0;
    _gyroStatusLabel.clipsToBounds = YES;
    _gyroStatusLabel.alpha = 0.0;
    [self addSubview:_gyroStatusLabel];

    _editorPanel = [[UIView alloc] initWithFrame:CGRectZero];
    _editorPanel.backgroundColor = [UIColor colorWithWhite:0.03 alpha:0.90];
    _editorPanel.layer.cornerRadius = 16.0;
    _editorPanel.layer.borderWidth = 1.0;
    _editorPanel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
    _editorPanel.hidden = YES;
    [self addSubview:_editorPanel];

    UILabel *editorTitle = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    editorTitle.text = @"CONTROL EDITOR";
    editorTitle.textColor = UIColor.whiteColor;
    editorTitle.font = [UIFont boldSystemFontOfSize:14.0];
    [_editorPanel addSubview:editorTitle];
    editorTitle.tag = 7001;

    _fireToggleButton = [[UIButton buttonWithType:UIButtonTypeSystem] retain];
    _fireToggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    _fireToggleButton.layer.cornerRadius = 10.0;
    [_fireToggleButton addTarget:self action:@selector(toggleFireButtonFromEditor:)
               forControlEvents:UIControlEventTouchUpInside];
    [_editorPanel addSubview:_fireToggleButton];

    _gyroButton = [[UIButton buttonWithType:UIButtonTypeSystem] retain];
    _gyroButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    _gyroButton.layer.cornerRadius = 10.0;
    [_gyroButton addTarget:self action:@selector(toggleGyroFromEditor:) forControlEvents:UIControlEventTouchUpInside];
    [_editorPanel addSubview:_gyroButton];

    _doneButton = [[UIButton buttonWithType:UIButtonTypeSystem] retain];
    _doneButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    _doneButton.layer.cornerRadius = 10.0;
    _doneButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    [_doneButton setTitle:@"DONE" forState:UIControlStateNormal];
    [_doneButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [_doneButton addTarget:self action:@selector(finishControlEditor:)
          forControlEvents:UIControlEventTouchUpInside];
    [_editorPanel addSubview:_doneButton];

    _touchSensitivityLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _touchSensitivityLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    _touchSensitivityLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    [_editorPanel addSubview:_touchSensitivityLabel];

    _gyroSensitivityLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _gyroSensitivityLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    _gyroSensitivityLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    [_editorPanel addSubview:_gyroSensitivityLabel];

    _touchSensitivitySlider = [[UISlider alloc] initWithFrame:CGRectZero];
    _touchSensitivitySlider.minimumValue = 0.006f;
    _touchSensitivitySlider.maximumValue = 0.060f;
    _touchSensitivitySlider.value = _touchAimScale;
    _touchSensitivitySlider.minimumTrackTintColor = [UIColor colorWithRed:0.05 green:0.78 blue:0.90 alpha:1.0];
    [_touchSensitivitySlider addTarget:self action:@selector(sensitivityChanged:)
                      forControlEvents:UIControlEventValueChanged];
    [_editorPanel addSubview:_touchSensitivitySlider];

    _gyroSensitivitySlider = [[UISlider alloc] initWithFrame:CGRectZero];
    _gyroSensitivitySlider.minimumValue = 1.0f;
    _gyroSensitivitySlider.maximumValue = 12.0f;
    _gyroSensitivitySlider.value = _gyroAimScale;
    _gyroSensitivitySlider.minimumTrackTintColor = [UIColor colorWithRed:1.0 green:0.47 blue:0.08 alpha:1.0];
    [_gyroSensitivitySlider addTarget:self action:@selector(sensitivityChanged:)
                     forControlEvents:UIControlEventValueChanged];
    [_editorPanel addSubview:_gyroSensitivitySlider];
    [self updateEditorControls];

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
            AndroidLook(static_cast<float>(rate.x * view->_gyroAimScale * direction * view->_motionManager.deviceMotionUpdateInterval),
                        static_cast<float>(rate.y * view->_gyroAimScale * direction * view->_motionManager.deviceMotionUpdateInterval));
        }];
    }

    return self;
}

- (void)dealloc
{
    [_motionManager stopDeviceMotionUpdates];
    [_motionManager release];
    [_pauseLongPressGesture release];
    [_gyroStatusLabel release];
    [_editorPanel release];
    [_fireToggleButton release];
    [_gyroButton release];
    [_doneButton release];
    [_touchSensitivityLabel release];
    [_gyroSensitivityLabel release];
    [_touchSensitivitySlider release];
    [_gyroSensitivitySlider release];
    [_touchActions release];
    [super dealloc];
}

- (CGPoint)defaultCenterForControl:(NSInteger)control
{
    CGFloat const width = CGRectGetWidth(self.bounds);
    CGFloat const height = CGRectGetHeight(self.bounds);
    switch (control)
    {
        case kControlUse: return CGPointMake(width - 150.0, height - 105.0);
        case kControlJump: return CGPointMake(width - 72.0, height - 166.0);
        case kControlCrouch: return CGPointMake(width - 153.0, height - 42.0);
        case kControlWeapon: return CGPointMake(width - 226.0, height - 46.0);
        case kControlPause: return CGPointMake(width - 35.0, 35.0);
        case kControlFire: return CGPointMake(width - 72.0, height - 88.0);
        default: return CGPointMake(width * 0.5, height * 0.5);
    }
}

- (CGFloat)defaultRadiusForControl:(NSInteger)control
{
    switch (control)
    {
        case kControlUse:
        case kControlJump: return 31.0;
        case kControlCrouch: return 28.0;
        case kControlWeapon: return 27.0;
        case kControlPause: return 25.0;
        case kControlFire: return 38.0;
        default: return 28.0;
    }
}

- (void)ensureControlLayout
{
    CGSize const size = self.bounds.size;
    if (size.width <= 0.0 || size.height <= 0.0)
        return;

    if (_controlLayoutReady)
    {
        if (!CGSizeEqualToSize(size, _controlLayoutSize))
        {
            CGFloat const sx = size.width / _controlLayoutSize.width;
            CGFloat const sy = size.height / _controlLayoutSize.height;
            CGFloat const sr = fmin(sx, sy);
            for (NSInteger control = 0; control < kControlCount; ++control)
            {
                _controlCenters[control].x *= sx;
                _controlCenters[control].y *= sy;
                _controlRadii[control] *= sr;
            }
            _controlLayoutSize = size;
        }
        return;
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    CGFloat const scale = fmin(size.width, size.height);
    for (NSInteger control = 0; control < kControlCount; ++control)
    {
        NSNumber *x = [defaults objectForKey:LayoutKey(control, @"x")];
        NSNumber *y = [defaults objectForKey:LayoutKey(control, @"y")];
        NSNumber *radius = [defaults objectForKey:LayoutKey(control, @"r")];

        if (x && y && radius)
        {
            _controlCenters[control] = CGPointMake(x.doubleValue * size.width, y.doubleValue * size.height);
            _controlRadii[control] = radius.doubleValue * scale;
        }
        else
        {
            _controlCenters[control] = [self defaultCenterForControl:control];
            _controlRadii[control] = [self defaultRadiusForControl:control];
        }
    }
    _controlLayoutSize = size;
    _controlLayoutReady = YES;
}

- (void)saveControlLayout
{
    [self ensureControlLayout];
    CGFloat const width = CGRectGetWidth(self.bounds);
    CGFloat const height = CGRectGetHeight(self.bounds);
    CGFloat const scale = fmin(width, height);
    if (width <= 0.0 || height <= 0.0 || scale <= 0.0)
        return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSInteger control = 0; control < kControlCount; ++control)
    {
        [defaults setDouble:_controlCenters[control].x / width forKey:LayoutKey(control, @"x")];
        [defaults setDouble:_controlCenters[control].y / height forKey:LayoutKey(control, @"y")];
        [defaults setDouble:_controlRadii[control] / scale forKey:LayoutKey(control, @"r")];
    }
}

- (CGPoint)centerForControl:(NSInteger)control
{
    [self ensureControlLayout];
    return _controlCenters[control];
}

- (CGFloat)radiusForControl:(NSInteger)control
{
    [self ensureControlLayout];
    return _controlRadii[control];
}

- (CGPoint)useCenter { return [self centerForControl:kControlUse]; }
- (CGPoint)jumpCenter { return [self centerForControl:kControlJump]; }
- (CGPoint)crouchCenter { return [self centerForControl:kControlCrouch]; }
- (CGPoint)weaponCenter { return [self centerForControl:kControlWeapon]; }
- (CGPoint)pauseCenter { return [self centerForControl:kControlPause]; }
- (CGPoint)fireCenter { return [self centerForControl:kControlFire]; }

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self ensureControlLayout];
    _gyroStatusLabel.center = CGPointMake(CGRectGetMidX(self.bounds), 42.0);

    CGFloat const panelWidth = fmin(CGRectGetWidth(self.bounds) - 32.0, 520.0);
    _editorPanel.frame = CGRectMake((CGRectGetWidth(self.bounds) - panelWidth) * 0.5, 12.0, panelWidth, 124.0);
    UILabel *title = (UILabel *)[_editorPanel viewWithTag:7001];
    title.frame = CGRectMake(16.0, 10.0, 176.0, 30.0);
    _fireToggleButton.frame = CGRectMake(panelWidth - 324.0, 9.0, 114.0, 32.0);
    _gyroButton.frame = CGRectMake(panelWidth - 202.0, 9.0, 102.0, 32.0);
    _doneButton.frame = CGRectMake(panelWidth - 92.0, 9.0, 76.0, 32.0);
    _touchSensitivityLabel.frame = CGRectMake(16.0, 47.0, 118.0, 27.0);
    _touchSensitivitySlider.frame = CGRectMake(134.0, 45.0, panelWidth - 150.0, 31.0);
    _gyroSensitivityLabel.frame = CGRectMake(16.0, 84.0, 118.0, 27.0);
    _gyroSensitivitySlider.frame = CGRectMake(134.0, 82.0, panelWidth - 150.0, 31.0);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    if (gestureRecognizer != _pauseLongPressGesture)
        return YES;

    CGPoint const point = [touch locationInView:self];
    return CGRectContainsPoint(CircleRect(self.pauseCenter, [self radiusForControl:kControlPause] + 10.0), point);
}

- (void)pauseLongPress:(UILongPressGestureRecognizer *)recognizer
{
    if (recognizer.state != UIGestureRecognizerStateBegan || _pauseHoldActivated)
        return;

    _pauseHoldActivated = YES;
    [self toggleControlEditor];
}

- (void)cancelActiveTouchesForBackground
{
    AndroidMove(0.f, 0.f);
    if (_lookFiring)
        AndroidAction(0, gamefunc_Fire);
    for (NSNumber *action in _touchActions.allValues)
        AndroidAction(0, action.intValue);
    [_touchActions removeAllObjects];

    _moveTouch = nil;
    _lookTouch = nil;
    _lookFiring = NO;
    _lookMoved = NO;
    _lookTotalTravel = 0.0;
    _editTouch = nil;
    _editingControl = kNoControl;
    _editingResize = NO;
    _pauseTouch = nil;
    _pauseHoldActivated = NO;
    [self setNeedsDisplay];
}

- (void)toggleControlEditor
{
    [self cancelActiveTouchesForBackground];

    _layoutEditing = !_layoutEditing;
    _editorPanel.hidden = !_layoutEditing;
    if (!_layoutEditing)
        [self saveControlLayout];

    [self updateEditorControls];
    _gyroStatusLabel.text = @"CONTROL LAYOUT SAVED";
    _gyroStatusLabel.alpha = _layoutEditing ? 0.0 : 1.0;

    UINotificationFeedbackGenerator *feedback = [[[UINotificationFeedbackGenerator alloc] init] autorelease];
    [feedback notificationOccurred:_layoutEditing ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeWarning];

    if (!_layoutEditing)
    {
        [UIView animateWithDuration:0.25 delay:0.8 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ self->_gyroStatusLabel.alpha = 0.0; } completion:nil];
    }
    [self setNeedsDisplay];
}

- (void)updateEditorControls
{
    [_fireToggleButton setTitle:(_fireButtonEnabled ? @"FIRE ON" : @"FIRE OFF")
                       forState:UIControlStateNormal];
    _fireToggleButton.backgroundColor = _fireButtonEnabled
        ? [UIColor colorWithRed:0.88 green:0.24 blue:0.12 alpha:0.88]
        : [UIColor colorWithRed:0.48 green:0.16 blue:0.16 alpha:0.85];
    [_fireToggleButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];

    [_gyroButton setTitle:(_gyroEnabled ? @"GYRO ON" : @"GYRO OFF") forState:UIControlStateNormal];
    _gyroButton.backgroundColor = _gyroEnabled
        ? [UIColor colorWithRed:0.10 green:0.68 blue:0.35 alpha:0.85]
        : [UIColor colorWithRed:0.48 green:0.16 blue:0.16 alpha:0.85];
    [_gyroButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];

    _touchSensitivityLabel.text =
        [NSString stringWithFormat:@"TOUCH AIM %.1fx", _touchAimScale / kDefaultLookScale];
    _gyroSensitivityLabel.text =
        [NSString stringWithFormat:@"GYRO AIM %.1fx", _gyroAimScale / kDefaultGyroScale];
}

- (void)finishControlEditor:(UIButton *)sender
{
    (void)sender;
    if (_layoutEditing)
        [self toggleControlEditor];
}

- (void)toggleFireButtonFromEditor:(UIButton *)sender
{
    (void)sender;
    _fireButtonEnabled = !_fireButtonEnabled;
    [NSUserDefaults.standardUserDefaults setBool:_fireButtonEnabled
                                          forKey:@"eDukeiOS.fireButton.enabled"];
    [self updateEditorControls];
    [self setNeedsDisplay];

    UISelectionFeedbackGenerator *feedback = [[[UISelectionFeedbackGenerator alloc] init] autorelease];
    [feedback selectionChanged];
}

- (void)toggleGyroFromEditor:(UIButton *)sender
{
    (void)sender;
    _gyroEnabled = !_gyroEnabled;
    [NSUserDefaults.standardUserDefaults setBool:_gyroEnabled forKey:@"eDukeiOS.gyro.enabled"];
    [self updateEditorControls];

    UISelectionFeedbackGenerator *feedback = [[[UISelectionFeedbackGenerator alloc] init] autorelease];
    [feedback selectionChanged];
}

- (void)sensitivityChanged:(UISlider *)slider
{
    (void)slider;
    _touchAimScale = _touchSensitivitySlider.value;
    _gyroAimScale = _gyroSensitivitySlider.value;
    NSUserDefaults *preferences = NSUserDefaults.standardUserDefaults;
    [preferences setFloat:_touchAimScale forKey:@"eDukeiOS.aim.touch"];
    [preferences setFloat:_gyroAimScale forKey:@"eDukeiOS.aim.gyro"];
    [self updateEditorControls];
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
    if ([self touchMode] != TOUCH_SCREEN_GAME)
        return -1;

    if (CGRectContainsPoint(CircleRect(self.useCenter, [self radiusForControl:kControlUse]), point)) return gamefunc_Open;
    if (CGRectContainsPoint(CircleRect(self.jumpCenter, [self radiusForControl:kControlJump]), point)) return gamefunc_Jump;
    if (CGRectContainsPoint(CircleRect(self.crouchCenter, [self radiusForControl:kControlCrouch]), point)) return gamefunc_Crouch;
    if (CGRectContainsPoint(CircleRect(self.weaponCenter, [self radiusForControl:kControlWeapon]), point)) return gamefunc_Next_Weapon;
    if (_fireButtonEnabled
        && CGRectContainsPoint(CircleRect(self.fireCenter, [self radiusForControl:kControlFire]), point))
        return gamefunc_Fire;
    return -1;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)event;
    for (UITouch *touch in touches)
    {
        CGPoint const point = [touch locationInView:self];

        if (CGRectContainsPoint(CircleRect(self.pauseCenter, [self radiusForControl:kControlPause] + 10.0), point))
        {
            _pauseTouch = touch;
            _pauseHoldActivated = NO;
            continue;
        }

        if (_layoutEditing)
        {
            if (!_editTouch)
            {
                [self ensureControlLayout];
                NSInteger nearest = kNoControl;
                CGFloat nearestDistance = CGFLOAT_MAX;
                for (NSInteger control = 0; control < kControlCount; ++control)
                {
                    if (control == kControlFire && !_fireButtonEnabled)
                        continue;
                    CGFloat const distance = hypot(point.x - _controlCenters[control].x,
                                                   point.y - _controlCenters[control].y);
                    if (distance <= _controlRadii[control] + 18.0 && distance < nearestDistance)
                    {
                        nearest = control;
                        nearestDistance = distance;
                    }
                }

                if (nearest != kNoControl)
                {
                    _editTouch = touch;
                    _editingControl = nearest;
                    _editingResize = nearestDistance >= _controlRadii[nearest] * 0.62;
                    UISelectionFeedbackGenerator *feedback = [[[UISelectionFeedbackGenerator alloc] init] autorelease];
                    [feedback selectionChanged];
                }
            }
            continue;
        }

        NSInteger const action = [self actionAtPoint:point];
        fprintf(stderr, "EDUKE32_IOS_TOUCH: began x=%.1f y=%.1f action=%ld\n",
                point.x, point.y, (long)action);
        fflush(stderr);

        if (action >= 0)
        {
            AndroidAction(1, static_cast<int>(action));
            [_touchActions setObject:@(action) forKey:[NSValue valueWithNonretainedObject:touch]];
        }
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
            _lookMoved = NO;
            _lookFiring = NO;
            _lookTotalTravel = 0.0;

            // A quick tap fires once. Holding still begins continuous fire;
            // any meaningful aim movement permanently cancels firing for this
            // touch. After hold-fire starts, the finger may still drag to aim.
            if ([self touchMode] == TOUCH_SCREEN_GAME)
            {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                  kLookHoldFireDelayMilliseconds * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    if (self->_lookTouch == touch && !self->_lookMoved && !self->_lookFiring
                        && [self touchMode] == TOUCH_SCREEN_GAME)
                    {
                        AndroidAction(1, gamefunc_Fire);
                        self->_lookFiring = YES;
                    }
                });
            }
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

        if (_layoutEditing)
        {
            if (touch == _editTouch && _editingControl != kNoControl)
            {
                if (_editingResize)
                {
                    CGFloat const distance = hypot(point.x - _controlCenters[_editingControl].x,
                                                   point.y - _controlCenters[_editingControl].y);
                    _controlRadii[_editingControl] = fmax(20.0, fmin(64.0, distance));
                }
                else
                {
                    CGFloat const radius = _controlRadii[_editingControl];
                    _controlCenters[_editingControl] = CGPointMake(
                        fmax(radius + 4.0, fmin(CGRectGetWidth(self.bounds) - radius - 4.0, point.x)),
                        fmax(radius + 4.0, fmin(CGRectGetHeight(self.bounds) - radius - 4.0, point.y)));
                }
                [self setNeedsDisplay];
            }
            continue;
        }

        if ([self touchMode] == TOUCH_SCREEN_GAME)
        {
            if (touch == _moveTouch)
            {
                CGFloat const dx = point.x - _moveOrigin.x;
                CGFloat const dy = point.y - _moveOrigin.y;

                // Deliberately digital, like keyboard movement. Snap toward
                // the dominant cardinal direction so minor finger drift does
                // not accidentally turn a pure strafe into a diagonal.
                CGFloat const adx = fabs(dx);
                CGFloat const ady = fabs(dy);
                float strafe = 0.f;
                float forward = 0.f;
                if (fmax(adx, ady) >= kMovementDeadZone)
                {
                    if (adx >= ady * kMovementDiagonalRatio)
                        strafe = dx < 0.0 ? -1.f : 1.f;
                    if (ady >= adx * kMovementDiagonalRatio)
                        forward = dy < 0.0 ? 1.f : -1.f;
                }
                AndroidMove(forward, strafe);
            }
            else if (touch == _lookTouch)
            {
                CGFloat const dx = point.x - _lookPrevious.x;
                CGFloat const dy = point.y - _lookPrevious.y;
                _lookTotalTravel += hypot(dx, dy);
                CGFloat const displacement =
                    hypot(point.x - _lookOrigin.x, point.y - _lookOrigin.y);
                if (!_lookFiring
                    && (displacement >= kLookGestureDisplacementSlop
                        || _lookTotalTravel >= kLookGestureTravelSlop))
                    _lookMoved = YES;
                // Touch coordinates grow downward; gyro is already correct,
                // so invert only the touch pitch before the shared aim path.
                AndroidLook(static_cast<float>(dx * _touchAimScale), static_cast<float>(-dy * _touchAimScale));
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
        if (touch == _pauseTouch)
        {
            BOOL const openedEditor = _pauseHoldActivated;
            _pauseTouch = nil;
            _pauseHoldActivated = NO;
            if (!cancelled && !openedEditor)
                PushKey(SDL_SCANCODE_ESCAPE);
            [self setNeedsDisplay];
            continue;
        }

        if (_layoutEditing && touch == _editTouch)
        {
            _editTouch = nil;
            _editingControl = kNoControl;
            _editingResize = NO;
            [self saveControlLayout];
            [self setNeedsDisplay];
            continue;
        }

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
            BOOL const wasFiring = _lookFiring;
            BOOL const wasMoved = _lookMoved;
            _lookTouch = nil;
            _lookMoved = NO;
            _lookFiring = NO;
            _lookTotalTravel = 0.0;

            if (wasFiring)
                AndroidAction(0, gamefunc_Fire);

            if (!cancelled)
            {
                if (mode == TOUCH_SCREEN_GAME)
                {
                    if (!wasFiring && !wasMoved
                        && distance < kLookGestureDisplacementSlop)
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

- (NSString *)symbolForControl:(NSInteger)control
{
    switch (control)
    {
        case kControlUse: return @"hand.tap.fill";
        case kControlJump: return @"arrow.up";
        case kControlCrouch: return @"arrow.down.to.line";
        case kControlWeapon: return @"arrow.triangle.2.circlepath";
        case kControlPause: return @"pause.fill";
        case kControlFire: return @"scope";
        default: return @"circle.fill";
    }
}

- (UIColor *)accentForControl:(NSInteger)control
{
    (void)control;
    return UIColor.whiteColor;
}

- (void)drawControl:(NSInteger)control active:(BOOL)active
{
    CGPoint const center = [self centerForControl:control];
    CGFloat const radius = [self radiusForControl:control];
    CGContextRef const context = UIGraphicsGetCurrentContext();
    UIColor *accent = [self accentForControl:control];
    CGRect const circle = CircleRect(center, radius);

    CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:1.0 alpha:active ? 0.22 : 0.075].CGColor);
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1.0 alpha:active ? 0.68 : 0.38].CGColor);
    CGContextSetLineWidth(context, active ? 2.4 : 1.4);
    CGContextAddEllipseInRect(context, circle);
    CGContextDrawPath(context, kCGPathFillStroke);

    CGRect const inset = CGRectInset(circle, radius * 0.16, radius * 0.16);
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1.0 alpha:0.16].CGColor);
    CGContextSetLineWidth(context, 1.0);
    CGContextStrokeEllipseInRect(context, inset);

    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:radius * 0.78
                                                        weight:UIImageSymbolWeightBold];
    UIImage *symbol = [[UIImage systemImageNamed:[self symbolForControl:control]]
                        imageByApplyingSymbolConfiguration:configuration];
    symbol = [symbol imageWithTintColor:[UIColor colorWithWhite:1.0 alpha:active ? 0.92 : 0.70]
                         renderingMode:UIImageRenderingModeAlwaysOriginal];
    CGSize const symbolSize = symbol.size;
    [symbol drawAtPoint:CGPointMake(center.x - symbolSize.width * 0.5,
                                    center.y - symbolSize.height * 0.5)];

    if (_layoutEditing)
    {
        CGFloat dash[] = { 5.0, 4.0 };
        CGContextSaveGState(context);
        CGContextSetLineDash(context, 0.0, dash, 2);
        CGContextSetStrokeColorWithColor(context, [accent colorWithAlphaComponent:0.95].CGColor);
        CGContextSetLineWidth(context, 2.0);
        CGContextStrokeEllipseInRect(context, CGRectInset(circle, -5.0, -5.0));
        CGContextRestoreGState(context);

        CGPoint const handle = CGPointMake(center.x + radius * 0.72, center.y + radius * 0.72);
        CGContextSetFillColorWithColor(context, UIColor.whiteColor.CGColor);
        CGContextFillEllipseInRect(context, CircleRect(handle, 5.5));
        CGContextSetStrokeColorWithColor(context, accent.CGColor);
        CGContextSetLineWidth(context, 2.0);
        CGContextStrokeEllipseInRect(context, CircleRect(handle, 5.5));
    }
}

- (BOOL)isActionActive:(NSInteger)action
{
    return [[_touchActions allValues] containsObject:@(action)];
}

- (void)drawRect:(CGRect)rect
{
    (void)rect;
    if ([self touchMode] == TOUCH_SCREEN_GAME || _layoutEditing)
    {
        [self drawControl:kControlUse active:[self isActionActive:gamefunc_Open]];
        [self drawControl:kControlJump active:[self isActionActive:gamefunc_Jump]];
        [self drawControl:kControlCrouch active:[self isActionActive:gamefunc_Crouch]];
        [self drawControl:kControlWeapon active:[self isActionActive:gamefunc_Next_Weapon]];
        if (_fireButtonEnabled)
            [self drawControl:kControlFire active:[self isActionActive:gamefunc_Fire]];
    }
    [self drawControl:kControlPause active:NO];
}

@end


@interface EDuke32ControlsInstaller : NSObject
+ (UIWindow *)activeWindow;
+ (void)scheduleRefresh;
+ (void)applicationWillResignActive:(NSNotification *)notification;
+ (void)applicationDidBecomeActive:(NSNotification *)notification;
@end

typedef void (^EDuke32LaunchCompletion)(NSString *grpName);

@interface EDuke32LauncherViewController : UIViewController
{
    EDuke32LaunchCompletion _completion;
    NSString *_documentsPath;
    UILabel *_statusLabel;
}
- (instancetype)initWithCompletion:(EDuke32LaunchCompletion)completion;
@end

@implementation EDuke32LauncherViewController

- (instancetype)initWithCompletion:(EDuke32LaunchCompletion)completion
{
    self = [super initWithNibName:nil bundle:nil];
    if (self)
    {
        _completion = [completion copy];
        _documentsPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                NSUserDomainMask, YES)
                           firstObject] copy];
    }
    return self;
}

- (void)dealloc
{
    [_completion release];
    [_documentsPath release];
    [_statusLabel release];
    [super dealloc];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (NSString *)fileNamed:(NSString *)wanted
{
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_documentsPath error:nil];
    for (NSString *file in files)
        if ([file caseInsensitiveCompare:wanted] == NSOrderedSame)
            return file;
    return nil;
}

- (UIButton *)gameButtonWithTitle:(NSString *)title
                         subtitle:(NSString *)subtitle
                              tag:(NSInteger)tag
                          enabled:(BOOL)enabled
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = tag;
    button.enabled = enabled;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.75;
    button.contentEdgeInsets = UIEdgeInsetsMake(12.0, 16.0, 12.0, 16.0);
    button.layer.cornerRadius = 14.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:enabled ? 0.22 : 0.10].CGColor;
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:enabled ? 0.085 : 0.035];
    NSString *text = [NSString stringWithFormat:@"%@\n%@", title, subtitle];
    NSMutableAttributedString *attributed =
        [[[NSMutableAttributedString alloc] initWithString:text] autorelease];
    [attributed addAttribute:NSForegroundColorAttributeName
                       value:[UIColor colorWithWhite:1.0 alpha:enabled ? 0.96 : 0.42]
                       range:NSMakeRange(0, title.length)];
    [attributed addAttribute:NSFontAttributeName
                       value:[UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular]
                       range:NSMakeRange(title.length + 1, subtitle.length)];
    [attributed addAttribute:NSForegroundColorAttributeName
                       value:[UIColor colorWithWhite:1.0 alpha:enabled ? 0.58 : 0.30]
                       range:NSMakeRange(title.length + 1, subtitle.length)];
    [button setAttributedTitle:attributed forState:UIControlStateNormal];
    [button addTarget:self action:@selector(gameSelected:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)loadView
{
    UIView *root = [[[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds] autorelease];
    root.backgroundColor = [UIColor colorWithRed:0.035 green:0.043 blue:0.060 alpha:1.0];
    self.view = root;

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = root.bounds;
    gradient.colors = @[
        (id)[UIColor colorWithRed:0.11 green:0.06 blue:0.04 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.035 green:0.043 blue:0.060 alpha:1.0].CGColor
    ];
    gradient.startPoint = CGPointMake(0.0, 0.0);
    gradient.endPoint = CGPointMake(1.0, 1.0);
    [root.layer addSublayer:gradient];

    UILabel *title = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    title.text = @"eDukeiOS";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightBlack];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitle = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    subtitle.text = @"CHOOSE A GAME";
    subtitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.48];
    subtitle.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
    subtitle.textAlignment = NSTextAlignmentCenter;

    UIStackView *cards = [[[UIStackView alloc] initWithArrangedSubviews:@[
        [self gameButtonWithTitle:@"Duke Nukem 3D"
                         subtitle:@"DUKE3D.GRP" tag:1 enabled:YES],
        [self gameButtonWithTitle:@"Ion Fury"
                         subtitle:@"FURY.GRP · base game or Aftershock" tag:2 enabled:YES],
        [self gameButtonWithTitle:@"Shadow Warrior"
                         subtitle:@"SW.GRP · VoidSW engine coming next" tag:3 enabled:YES],
        [self gameButtonWithTitle:@"Custom"
                         subtitle:@"CUSTOM.GRP · Duke-compatible game data" tag:4 enabled:YES]
    ]] autorelease];
    cards.axis = UILayoutConstraintAxisVertical;
    cards.spacing = 9.0;
    cards.distribution = UIStackViewDistributionFillEqually;

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.text = @"Place your legally owned game files in the eDukeiOS Files folder.";
    _statusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.54];
    _statusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;

    UIStackView *stack = [[[UIStackView alloc] initWithArrangedSubviews:@[
        title, subtitle, cards, _statusLabel
    ]] autorelease];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:root.centerYAnchor],
        [stack.widthAnchor constraintEqualToAnchor:root.widthAnchor multiplier:0.72],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:620.0],
        [cards.heightAnchor constraintEqualToConstant:238.0],
        [title.heightAnchor constraintEqualToConstant:38.0],
        [subtitle.heightAnchor constraintEqualToConstant:18.0],
        [_statusLabel.heightAnchor constraintEqualToConstant:34.0]
    ]];
}

- (uint32_t)crc32ForFileAtPath:(NSString *)path
{
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    uint32_t crc = UINT32_C(0xffffffff);
    uint8_t buffer[64 * 1024];
    NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0)
    {
        for (NSInteger i = 0; i < count; ++i)
        {
            crc ^= buffer[i];
            for (int bit = 0; bit < 8; ++bit)
                crc = (crc >> 1) ^ (UINT32_C(0xedb88320) & (uint32_t)-(int32_t)(crc & 1));
        }
    }
    [stream close];
    return crc ^ UINT32_C(0xffffffff);
}

- (BOOL)writeFuryMetadataForFile:(NSString *)file
{
    NSString *path = [_documentsPath stringByAppendingPathComponent:file];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attributes)
        return NO;

    unsigned long long size = [attributes fileSize];
    _statusLabel.text = @"Preparing Ion Fury…";
    uint32_t crc = [self crc32ForFileAtPath:path];

    // Aftershock packages use ashock.def as their root definition file,
    // while the original Ion Fury package uses fury.def. The released
    // Aftershock GRP is substantially larger than every base-game GRP; keep
    // the published CRC as an exact match and the size check for later retail
    // revisions of the same package.
    BOOL const aftershock = (size == UINT64_C(160826590) && crc == UINT32_C(0xE175FB41))
                         || size > UINT64_C(125000000);
    NSString *gameName = aftershock ? @"Ion Fury: Aftershock" : @"Ion Fury";
    NSString *definitions = aftershock ? @"ashock.def" : @"fury.def";
    NSString *metadata = [NSString stringWithFormat:
        @"grpinfo\n{\n"
         "    name \"%@\"\n"
         "    scriptname \"scripts/main.con\"\n"
         "    defname \"%@\"\n"
         "    size %llu\n"
         "    crc 0x%08X\n"
         "    flags 1664\n"
         "    dependency 0\n"
         "}\n", gameName, definitions, size, crc];
    NSString *metadataPath = [_documentsPath stringByAppendingPathComponent:@"edukeios-fury.grpinfo"];
    NSError *error = nil;
    BOOL ok = [metadata writeToFile:metadataPath atomically:YES
                           encoding:NSUTF8StringEncoding error:&error];
    if (!ok)
        _statusLabel.text = [NSString stringWithFormat:@"Could not prepare Ion Fury: %@",
                                                       error.localizedDescription];
    return ok;
}

- (void)showMessage:(NSString *)title body:(NSString *)body
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:body
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)gameSelected:(UIButton *)sender
{
    NSString *wanted = nil;
    switch (sender.tag)
    {
        case 1: wanted = @"DUKE3D.GRP"; break;
        case 2: wanted = @"FURY.GRP"; break;
        case 3:
            [self showMessage:@"Shadow Warrior"
                         body:@"The launcher entry is ready, but SW.GRP needs the separate VoidSW game engine. That engine is the next compatibility target."];
            return;
        case 4: wanted = @"CUSTOM.GRP"; break;
        default: return;
    }

    NSString *file = [self fileNamed:wanted];
    if (!file)
    {
        [self showMessage:@"Game file not found"
                     body:[NSString stringWithFormat:
                         @"Add %@ to the eDukeiOS folder in Files, then reopen the launcher.", wanted]];
        return;
    }

    if (sender.tag == 2 && ![self writeFuryMetadataForFile:file])
        return;

    g_usePolymost = sender.tag == 2;
    _statusLabel.text = [NSString stringWithFormat:@"Starting %@…", file];
    if (_completion)
        _completion(file);
}

@end

extern "C" int EDuke32_IOS_WantsPolymost(void)
{
    return g_usePolymost ? 1 : 0;
}

extern "C" char *EDuke32_IOS_SelectGame(void)
{
    g_launcherActive = YES;
    __block NSString *selected = nil;
    __block UIWindow *launcherWindow = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    void (^showLauncher)(void) = ^{
        EDuke32LauncherViewController *launcher =
            [[[EDuke32LauncherViewController alloc] initWithCompletion:^(NSString *grpName) {
                selected = [grpName copy];
                dispatch_semaphore_signal(semaphore);
            }] autorelease];

        CGRect frame = UIScreen.mainScreen.bounds;
        if (@available(iOS 13.0, *))
        {
            UIWindowScene *windowScene = nil;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
            {
                if ([scene isKindOfClass:UIWindowScene.class] &&
                    (scene.activationState == UISceneActivationStateForegroundActive ||
                     scene.activationState == UISceneActivationStateForegroundInactive))
                {
                    windowScene = (UIWindowScene *)scene;
                    break;
                }
            }

            if (windowScene)
            {
                launcherWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
                frame = windowScene.coordinateSpace.bounds;
            }
        }

        if (!launcherWindow)
            launcherWindow = [[UIWindow alloc] initWithFrame:frame];

        launcherWindow.frame = frame;
        launcherWindow.backgroundColor = UIColor.blackColor;
        launcherWindow.windowLevel = UIWindowLevelAlert;
        launcherWindow.rootViewController = launcher;
        [launcherWindow makeKeyAndVisible];
    };

    if (NSThread.isMainThread)
    {
        showLauncher();
        while (!selected)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    else
    {
        dispatch_async(dispatch_get_main_queue(), showLauncher);
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    }

    void (^removeLauncher)(void) = ^{
        launcherWindow.hidden = YES;
        launcherWindow.rootViewController = nil;
        [launcherWindow release];
        launcherWindow = nil;
    };
    if (NSThread.isMainThread)
        removeLauncher();
    else
        dispatch_sync(dispatch_get_main_queue(), removeLauncher);

#if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
#endif
    g_launcherActive = NO;
    return selected ? strdup(selected.fileSystemRepresentation) : NULL;
}


@implementation EDuke32ControlsInstaller

+ (void)load
{
    NSSetUncaughtExceptionHandler(&EDuke32UncaughtExceptionHandler);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillResignActive:)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(installControls)
                                                     name:UIWindowDidBecomeKeyNotification
                                                   object:nil];
        [self performSelector:@selector(installControls) withObject:nil afterDelay:0.75];
    });
}

+ (void)applicationWillResignActive:(NSNotification *)notification
{
    (void)notification;
    NSInteger const tag = 0x4544554B;
    for (UIWindow *window in UIApplication.sharedApplication.windows)
    {
        UIView *view = [window viewWithTag:tag];
        if ([view isKindOfClass:EDuke32ControlsView.class])
            [(EDuke32ControlsView *)view cancelActiveTouchesForBackground];
    }
    PushApplicationEvent(SDL_APP_WILLENTERBACKGROUND);
    fprintf(stderr, "EDUKE32_IOS_LIFECYCLE: UIKit will-resign-active\n");
    fflush(stderr);
}

+ (void)applicationDidBecomeActive:(NSNotification *)notification
{
    (void)notification;
    // SDL's iOS backend normally generates this event, but pushing an
    // idempotent copy here guarantees that EDuke32 clears a stale minimized
    // flag even when UIKit omits SDL_WINDOWEVENT_RESTORED.
    PushApplicationEvent(SDL_APP_DIDENTERFOREGROUND);
    fprintf(stderr, "EDUKE32_IOS_LIFECYCLE: UIKit did-become-active\n");
    fflush(stderr);
    [self installControls];
}

+ (void)scheduleRefresh
{
    // Menus, loading screens, and gameplay all share one UIKit overlay.  The
    // engine can change MODE_MENU/MODE_GAME without causing UIKit to redraw,
    // so refresh the inexpensive transparent overlay while the app is active.
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(installControls)
                                               object:nil];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
        [self performSelector:@selector(installControls) withObject:nil afterDelay:0.15];
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
    if (g_launcherActive)
    {
        [self performSelector:@selector(installControls) withObject:nil afterDelay:0.5];
        return;
    }

    UIWindow *window = [self activeWindow];
    if (!window)
    {
        [self performSelector:@selector(installControls) withObject:nil afterDelay:0.5];
        return;
    }

    NSInteger const tag = 0x4544554B;
    UIView *existing = [window viewWithTag:tag];
    if (existing)
    {
        existing.frame = window.bounds;
        [window bringSubviewToFront:existing];
        [existing setNeedsDisplay];
        [self scheduleRefresh];
        return;
    }

    EDuke32ControlsView *controls = [[[EDuke32ControlsView alloc] initWithFrame:window.bounds] autorelease];
    controls.tag = tag;
    [window addSubview:controls];
    [controls setNeedsDisplay];
    [self scheduleRefresh];
}

@end
