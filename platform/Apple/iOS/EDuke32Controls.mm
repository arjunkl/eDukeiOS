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

constexpr CGFloat kMovementDeadZone = 12.0;
constexpr CGFloat kMovementDiagonalRatio = 0.55;
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
    kControlCount
};

constexpr NSInteger kNoControl = -1;

static NSString *LayoutKey(NSInteger control, NSString *component)
{
    return [NSString stringWithFormat:@"eDukeiOS.control.%ld.%@", (long)control, component];
}

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
    UIButton *_gyroButton;
    UILabel *_touchSensitivityLabel;
    UILabel *_gyroSensitivityLabel;
    UISlider *_touchSensitivitySlider;
    UISlider *_gyroSensitivitySlider;
    BOOL _gyroEnabled;
    float _touchAimScale;
    float _gyroAimScale;
    BOOL _lookMoved;
    BOOL _lookFiring;

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

    _gyroButton = [[UIButton buttonWithType:UIButtonTypeSystem] retain];
    _gyroButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    _gyroButton.layer.cornerRadius = 10.0;
    [_gyroButton addTarget:self action:@selector(toggleGyroFromEditor:) forControlEvents:UIControlEventTouchUpInside];
    [_editorPanel addSubview:_gyroButton];

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
    [_gyroButton release];
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

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self ensureControlLayout];
    _gyroStatusLabel.center = CGPointMake(CGRectGetMidX(self.bounds), 42.0);

    CGFloat const panelWidth = fmin(CGRectGetWidth(self.bounds) - 32.0, 520.0);
    _editorPanel.frame = CGRectMake((CGRectGetWidth(self.bounds) - panelWidth) * 0.5, 12.0, panelWidth, 124.0);
    UILabel *title = (UILabel *)[_editorPanel viewWithTag:7001];
    title.frame = CGRectMake(16.0, 10.0, 180.0, 30.0);
    _gyroButton.frame = CGRectMake(panelWidth - 118.0, 9.0, 102.0, 32.0);
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

- (void)toggleControlEditor
{

    if (_moveTouch)
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
    _editTouch = nil;
    _editingControl = kNoControl;

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

            // A quick tap fires once. Holding still briefly begins continuous
            // fire; after it starts, the same finger may drag to aim.
            if ([self touchMode] == TOUCH_SCREEN_GAME)
            {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_MSEC),
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
                if (!_lookFiring && hypot(point.x - _lookOrigin.x, point.y - _lookOrigin.y) >= 12.0)
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
            _lookTouch = nil;
            _lookMoved = NO;
            _lookFiring = NO;

            if (wasFiring)
                AndroidAction(0, gamefunc_Fire);

            if (!cancelled)
            {
                if (mode == TOUCH_SCREEN_GAME)
                {
                    if (!wasFiring && distance < 12.0)
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
    }
    [self drawControl:kControlPause active:NO];
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
