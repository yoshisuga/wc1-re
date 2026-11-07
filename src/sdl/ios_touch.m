/* iOS touch controls: a UIView over SDL's view.
 *
 * Outside flight only ESC, Return and the keyboard button show, and the
 * rest of the screen is a trackpad: a drag moves the pointer from where it
 * is, a tap clicks where the pointer is, and a two-finger tap right-clicks.
 * In flight the bars beside the 4:3 frame hold the cockpit
 * buttons, and a thumb put down anywhere else becomes the flight stick.
 * The stick and most buttons drive a virtual SDL game controller, so they
 * reach the game through the same four-button, four-axis joystick code as
 * a real controller; the rest send keys.  UIKit delivers the touches while
 * SDL pumps events on the main thread, so the handlers call SDL directly.
 *
 * The overlay stands aside while a hardware controller is in use, and
 * comes back on the next touch. */

#include "ios.h"

#include <SDL.h>
#include <SDL_syswm.h>

#import <UIKit/UIKit.h>

#include <math.h>
#include <stdlib.h>

int SdlIosGameMain(int argumentCount, char **arguments);

/* UIKit owns main(); SDL's application delegate calls the port's main
 * (launcher.c, built under this name) once the application is running. */
int main(int argumentCount, char **arguments)
{
    return SDL_UIKitRunApp(argumentCount, arguments, SdlIosGameMain);
}

/* ---------------- Virtual controller ---------------- */

static SDL_Joystick *g_pIosPad;
static SDL_JoystickID g_iosPadInstance = -1;
static SDL_JoystickID g_iosHardwareInstance = -1;
static SDL_Window *g_pIosWindow;

/* Set when a hardware controller is used, cleared by the next touch.  Being
 * connected is not enough, since a paired controller may be put away. */
static int g_bIosControllerInUse;

static void IosAttachPad(void)
{
    SDL_VirtualJoystickDesc desc;
    int deviceIndex;

    SDL_zero(desc);
    desc.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    desc.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    desc.naxes = SDL_CONTROLLER_AXIS_MAX;
    desc.nbuttons = SDL_CONTROLLER_BUTTON_MAX;
    desc.axis_mask = (1u << SDL_CONTROLLER_AXIS_LEFTX) |
                     (1u << SDL_CONTROLLER_AXIS_LEFTY) |
                     (1u << SDL_CONTROLLER_AXIS_RIGHTX) |
                     (1u << SDL_CONTROLLER_AXIS_RIGHTY);
    desc.button_mask = (1u << SDL_CONTROLLER_BUTTON_MAX) - 1u;
    desc.name = "Wing Commander Touch Controls";
    deviceIndex = SDL_JoystickAttachVirtualEx(&desc);
    if (deviceIndex < 0) {
        SDL_Log("Touch controller unavailable: %s", SDL_GetError());
        return;
    }
    g_pIosPad = SDL_JoystickOpen(deviceIndex);
    if (g_pIosPad == 0) {
        SDL_JoystickDetachVirtual(deviceIndex);
        return;
    }
    g_iosPadInstance = SDL_JoystickInstanceID(g_pIosPad);
}

static void IosSetPadAxis(SDL_GameControllerAxis axis, float value)
{
    if (g_pIosPad == 0)
        return;
    value = fmaxf(-1.0f, fminf(1.0f, value));
    SDL_JoystickSetVirtualAxis(g_pIosPad, axis,
                               (Sint16)lroundf(value * SDL_JOYSTICK_AXIS_MAX));
}

static void IosSetPadButton(SDL_GameControllerButton button, int pressed)
{
    if (g_pIosPad != 0)
        SDL_JoystickSetVirtualButton(g_pIosPad, button, pressed ? 1 : 0);
}

static int SDLCALL IosWatchEvent(void *userdata, SDL_Event *event)
{
    (void)userdata;
    switch (event->type) {
    case SDL_CONTROLLERBUTTONDOWN:
        if (event->cbutton.which != g_iosPadInstance) {
            g_bIosControllerInUse = 1;
            g_iosHardwareInstance = event->cbutton.which;
        }
        break;
    case SDL_CONTROLLERAXISMOTION:
        if (event->caxis.which != g_iosPadInstance &&
            abs(event->caxis.value) > SDL_JOYSTICK_AXIS_MAX / 2) {
            g_bIosControllerInUse = 1;
            g_iosHardwareInstance = event->caxis.which;
        }
        break;
    case SDL_CONTROLLERDEVICEREMOVED:
        if (event->cdevice.which == g_iosHardwareInstance) {
            g_bIosControllerInUse = 0;
            g_iosHardwareInstance = -1;
        }
        break;
    case SDL_FINGERDOWN:
        g_bIosControllerInUse = 0;
        break;
    default:
        break;
    }
    return 1;
}

static void IosSendKey(SDL_Keycode key, int pressed)
{
    SDL_Event event;

    SDL_zero(event);
    event.type = pressed ? SDL_KEYDOWN : SDL_KEYUP;
    event.key.windowID = g_pIosWindow != 0 ? SDL_GetWindowID(g_pIosWindow) : 0;
    event.key.state = pressed ? SDL_PRESSED : SDL_RELEASED;
    event.key.keysym.sym = key;
    event.key.keysym.scancode = SDL_GetScancodeFromKey(key);
    SDL_PushEvent(&event);
}

/* ---------------- Trackpad pointer ---------------- */

/* Points of pointer travel per point of finger travel. */
static const CGFloat IOS_POINTER_SPEED = 1.25;
/* A touch that lifts this soon, having moved less than this, is a tap. */
static const CFTimeInterval IOS_TAP_SECONDS = 0.3;
static const CGFloat IOS_TAP_SLOP = 10.0;
/* How long a tap holds the button, so screens that poll it see it. */
static const int64_t IOS_CLICK_NANOSECONDS = 80 * NSEC_PER_MSEC;

/* The game moves its pointer with SDL_WarpMouseInWindow (SetCursorPos), so
 * SDL's mouse position is the game's pointer.  A drag warps it by the
 * finger's travel, kept on the 4:3 frame; the warp posts the motion the
 * game reads. */
static void IosMovePointer(CGFloat dx, CGFloat dy, CGRect frame)
{
    int x;
    int y;

    if (g_pIosWindow == 0)
        return;
    SDL_GetMouseState(&x, &y);
    x = (int)lround(fmin(fmax(x + dx * IOS_POINTER_SPEED,
                              CGRectGetMinX(frame)),
                         CGRectGetMaxX(frame) - 1.0));
    y = (int)lround(fmin(fmax(y + dy * IOS_POINTER_SPEED,
                              CGRectGetMinY(frame)),
                         CGRectGetMaxY(frame) - 1.0));
    SDL_WarpMouseInWindow(g_pIosWindow, x, y);
}

static void IosSendMouseButton(Uint8 button, int pressed)
{
    SDL_Event event;
    int x;
    int y;

    SDL_GetMouseState(&x, &y);
    SDL_zero(event);
    event.type = pressed ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
    event.button.windowID =
        g_pIosWindow != 0 ? SDL_GetWindowID(g_pIosWindow) : 0;
    event.button.button = button;
    event.button.state = pressed ? SDL_PRESSED : SDL_RELEASED;
    event.button.clicks = 1;
    event.button.x = x;
    event.button.y = y;
    SDL_PushEvent(&event);
}

static void IosClickPointer(Uint8 button)
{
    IosSendMouseButton(button, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, IOS_CLICK_NANOSECONDS),
                   dispatch_get_main_queue(), ^{
                       IosSendMouseButton(button, 0);
                   });
}

/* ---------------- Buttons ---------------- */

typedef enum IosButtonKind {
    IOS_BUTTON_KEY,      /* holds a keyboard key */
    IOS_BUTTON_PAD,      /* holds a controller button */
    IOS_BUTTON_AXIS,     /* holds a controller axis at one end */
    IOS_BUTTON_KEYBOARD, /* shows or hides the screen keyboard */
} IosButtonKind;

typedef enum IosButtonPlace {
    IOS_PLACE_MENUS,  /* everywhere but flight */
    IOS_PLACE_FLIGHT, /* flight only */
} IosButtonPlace;

static UIImpactFeedbackGenerator *g_iosHaptic;

@interface WcTouchButton : UIView
@property(nonatomic) IosButtonKind kind;
@property(nonatomic) IosButtonPlace place;
@property(nonatomic) int code;
@property(nonatomic) float axisValue;
@property(nonatomic) BOOL held;
@property(nonatomic, strong) UILabel *label;
@end

@implementation WcTouchButton

- (instancetype)initWithTitle:(NSString *)title
                         kind:(IosButtonKind)kind
                         code:(int)code
                        place:(IosButtonPlace)place
{
    if ((self = [super initWithFrame:CGRectZero])) {
        _kind = kind;
        _code = code;
        _place = place;
        self.multipleTouchEnabled = NO;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor =
            [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.text = title;
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.4;
        _label.numberOfLines = 2;
        [self addSubview:_label];
        [self setHeld:NO];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.layer.cornerRadius =
        MIN(self.bounds.size.width, self.bounds.size.height) * 0.5;
    _label.frame = CGRectInset(self.bounds, 4, 2);
    _label.font = [UIFont
        boldSystemFontOfSize:MAX(9.0, MIN(self.bounds.size.height * 0.28,
                                          20.0))];
}

- (void)setHeld:(BOOL)held
{
    _held = held;
    self.backgroundColor = [UIColor colorWithWhite:held ? 0.85 : 0.15
                                             alpha:held ? 0.45 : 0.3];
}

- (void)press:(BOOL)down
{
    if (down == self.held)
        return;
    self.held = down;
    if (down)
        [g_iosHaptic impactOccurred];
    switch (self.kind) {
    case IOS_BUTTON_KEY:
        IosSendKey((SDL_Keycode)self.code, down);
        break;
    case IOS_BUTTON_PAD:
        IosSetPadButton((SDL_GameControllerButton)self.code, down);
        break;
    case IOS_BUTTON_AXIS:
        IosSetPadAxis((SDL_GameControllerAxis)self.code,
                      down ? self.axisValue : 0.0f);
        break;
    case IOS_BUTTON_KEYBOARD:
        if (!down)
            break;
        if (SDL_IsTextInputActive())
            SDL_StopTextInput();
        else
            SDL_StartTextInput();
        break;
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    g_bIosControllerInUse = 0;
    [self press:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self press:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event
{
    [self press:NO];
}

@end

/* ---------------- Overlay ---------------- */

@interface WcTouchOverlay : UIView
@property(nonatomic) BOOL flight;
@property(nonatomic, strong) NSArray<WcTouchButton *> *buttons;
@property(nonatomic, strong) NSArray<WcTouchButton *> *menuButtons;
@property(nonatomic, strong) NSArray<WcTouchButton *> *leftButtons;
@property(nonatomic, strong) NSArray<WcTouchButton *> *rightButtons;
@property(nonatomic, strong) WcTouchButton *fireButton;
@property(nonatomic, weak) UITouch *stickTouch;
@property(nonatomic) CGPoint stickOrigin;
@property(nonatomic, strong) CAShapeLayer *stickBase;
@property(nonatomic, strong) CAShapeLayer *stickKnob;
/* The trackpad gesture outside flight: the finger that moves the pointer,
 * where it was last, and whether the gesture is still a tap. */
@property(nonatomic, weak) UITouch *pointerTouch;
@property(nonatomic) CGPoint pointerLast;
@property(nonatomic) CGPoint pointerStart;
@property(nonatomic) CFTimeInterval pointerStartTime;
@property(nonatomic) BOOL pointerMoved;
@property(nonatomic) NSUInteger pointerFingers;
@end

static WcTouchButton *IosKey(NSString *title, SDL_Keycode key,
                             IosButtonPlace place)
{
    return [[WcTouchButton alloc] initWithTitle:title
                                           kind:IOS_BUTTON_KEY
                                           code:(int)key
                                          place:place];
}

static WcTouchButton *IosPad(NSString *title, SDL_GameControllerButton button)
{
    return [[WcTouchButton alloc] initWithTitle:title
                                           kind:IOS_BUTTON_PAD
                                           code:(int)button
                                          place:IOS_PLACE_FLIGHT];
}

static WcTouchButton *IosAxis(NSString *title, SDL_GameControllerAxis axis,
                              float value)
{
    WcTouchButton *button;

    button = [[WcTouchButton alloc] initWithTitle:title
                                             kind:IOS_BUTTON_AXIS
                                             code:(int)axis
                                            place:IOS_PLACE_FLIGHT];
    button.axisValue = value;
    return button;
}

@implementation WcTouchOverlay

- (instancetype)initWithFrame:(CGRect)frame
{
    NSMutableArray<WcTouchButton *> *all;

    if ((self = [super initWithFrame:frame])) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;

        /* Menus, briefings and conversations take clicks; these cover the
         * keys a mouse cannot. */
        self.menuButtons = @[
            IosKey(@"ESC", SDLK_ESCAPE, IOS_PLACE_MENUS),
            IosKey(@"ENTER", SDLK_RETURN, IOS_PLACE_MENUS),
            [[WcTouchButton alloc] initWithTitle:@"KEYS"
                                            kind:IOS_BUTTON_KEYBOARD
                                            code:0
                                           place:IOS_PLACE_MENUS],
        ];

        /* The joystick code maps the controller's buttons to the same
         * cockpit keys on every host (src/sdl/joystick.c).  In the
         * communications menu the D-pad picks a message, so FULL and STOP
         * move the choice and COMM and LOCK cancel and send it. */
        self.leftButtons = @[
            IosKey(@"ESC", SDLK_ESCAPE, IOS_PLACE_FLIGHT),
            IosPad(@"PAUSE", SDL_CONTROLLER_BUTTON_START),
            IosPad(@"NAV", SDL_CONTROLLER_BUTTON_LEFTSTICK),
            IosPad(@"AUTO", SDL_CONTROLLER_BUTTON_RIGHTSTICK),
            IosPad(@"COMM", SDL_CONTROLLER_BUTTON_DPAD_LEFT),
            IosPad(@"LOCK", SDL_CONTROLLER_BUTTON_DPAD_RIGHT),
            IosPad(@"FULL", SDL_CONTROLLER_BUTTON_DPAD_UP),
            IosPad(@"STOP", SDL_CONTROLLER_BUTTON_DPAD_DOWN),
            IosKey(@"FRONT", SDLK_F1, IOS_PLACE_FLIGHT),
            IosKey(@"REAR", SDLK_F4, IOS_PLACE_FLIGHT),
            IosKey(@"LEFT", SDLK_F2, IOS_PLACE_FLIGHT),
            IosKey(@"RIGHT", SDLK_F3, IOS_PLACE_FLIGHT),
        ];
        /* Twin-stick-roll: the right stick's X rolls and its Y moves the
         * throttle while held. */
        self.rightButtons = @[
            IosPad(@"GUNS", SDL_CONTROLLER_BUTTON_LEFTSHOULDER),
            IosPad(@"MSLS", SDL_CONTROLLER_BUTTON_RIGHTSHOULDER),
            IosPad(@"TGT", SDL_CONTROLLER_BUTTON_Y),
            IosPad(@"BURN", SDL_CONTROLLER_BUTTON_X),
            IosAxis(@"ROLL ◀", SDL_CONTROLLER_AXIS_RIGHTX, -1.0f),
            IosAxis(@"ROLL ▶", SDL_CONTROLLER_AXIS_RIGHTX, 1.0f),
            IosAxis(@"THR +", SDL_CONTROLLER_AXIS_RIGHTY, -1.0f),
            IosAxis(@"THR −", SDL_CONTROLLER_AXIS_RIGHTY, 1.0f),
            IosPad(@"MISSILE", SDL_CONTROLLER_BUTTON_B),
        ];
        self.fireButton = IosPad(@"FIRE", SDL_CONTROLLER_BUTTON_A);

        all = [NSMutableArray array];
        [all addObjectsFromArray:self.menuButtons];
        [all addObjectsFromArray:self.leftButtons];
        [all addObjectsFromArray:self.rightButtons];
        [all addObject:self.fireButton];
        self.buttons = all;
        for (WcTouchButton *button in self.buttons)
            [self addSubview:button];

        self.stickBase = [CAShapeLayer layer];
        self.stickBase.fillColor =
            [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
        self.stickBase.strokeColor =
            [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
        self.stickBase.lineWidth = 1.5;
        self.stickBase.hidden = YES;
        [self.layer addSublayer:self.stickBase];
        self.stickKnob = [CAShapeLayer layer];
        self.stickKnob.fillColor =
            [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
        self.stickKnob.hidden = YES;
        [self.layer addSublayer:self.stickKnob];
        [self updateVisibility];
    }
    return self;
}

/* The centred 4:3 frame, as SdlCalculateOutputViewport places it. */
- (CGRect)gameRect
{
    const CGSize size = self.bounds.size;
    CGFloat width;
    CGFloat height;

    width = MIN(size.width, size.height * 4.0 / 3.0);
    height = width * 3.0 / 4.0;
    return CGRectMake((size.width - width) / 2, (size.height - height) / 2,
                      width, height);
}

/* Two columns from the top; an odd last button spans both. */
static void IosLayoutPairs(NSArray<WcTouchButton *> *buttons, CGFloat x,
                           CGFloat y, CGFloat cell, CGFloat gap)
{
    NSUInteger index;

    for (index = 0; index < buttons.count; ++index) {
        const BOOL span = index + 1 == buttons.count && index % 2 == 0;

        buttons[index].frame =
            CGRectMake(x + (index % 2) * (cell + gap),
                       y + (index / 2) * (cell + gap),
                       span ? cell * 2 + gap : cell, cell);
    }
}

- (void)layoutSubviews
{
    const UIEdgeInsets safe = self.safeAreaInsets;
    const CGRect area = UIEdgeInsetsInsetRect(self.bounds, safe);
    const CGRect game = [self gameRect];
    const CGFloat gap = 6.0;
    const CGFloat top = CGRectGetMinY(area) + gap;
    const CGFloat height = area.size.height - gap * 2;
    const NSUInteger leftRows = (self.leftButtons.count + 1) / 2;
    const NSUInteger rightRows = (self.rightButtons.count + 1) / 2;
    const CGFloat fireRows = 1.6;
    CGFloat leftBar;
    CGFloat rightBar;
    CGFloat byWidth;
    CGFloat byHeight;
    CGFloat cell;
    CGFloat columnWidth;
    CGFloat leftX;
    CGFloat rightX;
    CGFloat fireTop;
    CGFloat fire;
    BOOL inBars;

    [super layoutSubviews];
    /* The bars beside the frame hold two columns each.  Where they are too
     * narrow, as on an iPad, the columns overlap the frame's edges. */
    leftBar = CGRectGetMinX(game) - CGRectGetMinX(area);
    rightBar = CGRectGetMaxX(area) - CGRectGetMaxX(game);
    byWidth = (MIN(leftBar, rightBar) - gap * 3) / 2;
    byHeight = MIN((height - gap * leftRows) / leftRows,
                   (height - gap * rightRows) / (rightRows + fireRows));
    cell = MIN(64.0, MAX(36.0, MIN(byWidth, byHeight)));
    columnWidth = cell * 2 + gap;
    inBars = byWidth >= 36.0;
    leftX = inBars ? CGRectGetMinX(area) + (leftBar - columnWidth) / 2
                   : CGRectGetMinX(area) + gap;
    rightX = inBars ? CGRectGetMaxX(game) + (rightBar - columnWidth) / 2
                    : CGRectGetMaxX(area) - gap - columnWidth;

    IosLayoutPairs(self.leftButtons, leftX, top, cell, gap);
    IosLayoutPairs(self.rightButtons, rightX, top, cell, gap);
    fireTop = top + rightRows * (cell + gap);
    fire = MIN(columnWidth, CGRectGetMaxY(area) - gap - fireTop);
    self.fireButton.frame = CGRectMake(rightX + (columnWidth - fire) / 2,
                                       fireTop, fire, fire);
    /* Outside flight the keys go down the left bar, clear of the frame. */
    IosLayoutPairs(@[ self.menuButtons[0] ], leftX, top, cell, gap);
    IosLayoutPairs(@[ self.menuButtons[1] ], leftX,
                   CGRectGetMaxY(area) - gap - cell, cell, gap);
    IosLayoutPairs(@[ self.menuButtons[2] ], rightX, top, cell, gap);
}

- (void)updateVisibility
{
    for (WcTouchButton *button in self.buttons) {
        const BOOL visible = (button.place == IOS_PLACE_FLIGHT) == self.flight;

        if (!visible && button.held)
            [button press:NO];
        button.hidden = !visible;
    }
}

- (void)setFlight:(BOOL)flight
{
    if (flight == _flight)
        return;
    _flight = flight;
    self.pointerTouch = nil;
    [self updateVisibility];
    if (!flight)
        [self endStick];
}

- (void)standAside:(BOOL)aside
{
    if (aside == self.hidden)
        return;
    self.hidden = aside;
    if (aside) {
        for (WcTouchButton *button in self.buttons)
            [button press:NO];
        [self endStick];
    }
}

- (CGFloat)stickRadius
{
    return MAX(50.0, self.bounds.size.height * 0.16);
}

- (void)drawStickAt:(CGPoint)point
{
    const CGFloat radius = [self stickRadius];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.stickBase.path =
        [UIBezierPath bezierPathWithArcCenter:self.stickOrigin
                                       radius:radius
                                   startAngle:0
                                     endAngle:2 * M_PI
                                    clockwise:YES]
            .CGPath;
    self.stickKnob.path =
        [UIBezierPath bezierPathWithArcCenter:point
                                       radius:radius * 0.4
                                   startAngle:0
                                     endAngle:2 * M_PI
                                    clockwise:YES]
            .CGPath;
    self.stickBase.hidden = NO;
    self.stickKnob.hidden = NO;
    [CATransaction commit];
}

- (void)moveStick:(CGPoint)point
{
    const CGFloat radius = [self stickRadius];
    CGFloat dx = (point.x - self.stickOrigin.x) / radius;
    CGFloat dy = (point.y - self.stickOrigin.y) / radius;
    const CGFloat length = hypot(dx, dy);

    if (length > 1.0) {
        dx /= length;
        dy /= length;
    }
    IosSetPadAxis(SDL_CONTROLLER_AXIS_LEFTX, (float)dx);
    IosSetPadAxis(SDL_CONTROLLER_AXIS_LEFTY, (float)dy);
    [self drawStickAt:CGPointMake(self.stickOrigin.x + dx * radius,
                                  self.stickOrigin.y + dy * radius)];
}

- (void)endStick
{
    self.stickTouch = nil;
    IosSetPadAxis(SDL_CONTROLLER_AXIS_LEFTX, 0.0f);
    IosSetPadAxis(SDL_CONTROLLER_AXIS_LEFTY, 0.0f);
    self.stickBase.hidden = YES;
    self.stickKnob.hidden = YES;
}

- (void)beginPointer:(NSSet<UITouch *> *)touches event:(UIEvent *)event
{
    NSUInteger fingers = 0;

    for (UITouch *touch in event.allTouches) {
        if (touch.view == self && touch.phase != UITouchPhaseEnded &&
            touch.phase != UITouchPhaseCancelled)
            fingers++;
    }
    if (self.pointerTouch == nil) {
        self.pointerTouch = touches.anyObject;
        self.pointerLast = [self.pointerTouch locationInView:self];
        self.pointerStart = self.pointerLast;
        self.pointerStartTime = CACurrentMediaTime();
        self.pointerMoved = NO;
        self.pointerFingers = 0;
    }
    self.pointerFingers = MAX(self.pointerFingers, fingers);
}

- (void)movePointer:(NSSet<UITouch *> *)touches
{
    CGPoint point;

    if (self.pointerTouch == nil || ![touches containsObject:self.pointerTouch])
        return;
    point = [self.pointerTouch locationInView:self];
    if (!self.pointerMoved &&
        hypot(point.x - self.pointerStart.x, point.y - self.pointerStart.y) <
            IOS_TAP_SLOP)
        return;
    self.pointerMoved = YES;
    /* Two fingers are a right click in waiting, not a drag. */
    if (self.pointerFingers < 2)
        IosMovePointer(point.x - self.pointerLast.x,
                       point.y - self.pointerLast.y, [self gameRect]);
    self.pointerLast = point;
}

- (void)endPointer:(NSSet<UITouch *> *)touches event:(UIEvent *)event
{
    BOOL fingersLeft = NO;

    for (UITouch *touch in event.allTouches) {
        if (touch.view == self && ![touches containsObject:touch] &&
            touch.phase != UITouchPhaseEnded &&
            touch.phase != UITouchPhaseCancelled)
            fingersLeft = YES;
    }
    if (fingersLeft || self.pointerTouch == nil)
        return;
    if (!self.pointerMoved &&
        CACurrentMediaTime() - self.pointerStartTime < IOS_TAP_SECONDS)
        IosClickPointer(self.pointerFingers >= 2 ? SDL_BUTTON_RIGHT
                                                 : SDL_BUTTON_LEFT);
    self.pointerTouch = nil;
}

/* In flight the stick starts wherever a thumb lands outside the buttons;
 * elsewhere the touch drives the pointer. */
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    g_bIosControllerInUse = 0;
    if (!self.flight) {
        [self beginPointer:touches event:event];
        return;
    }
    for (UITouch *touch in touches) {
        if (self.stickTouch != nil)
            break;
        self.stickTouch = touch;
        self.stickOrigin = [touch locationInView:self];
        [self moveStick:self.stickOrigin];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (!self.flight) {
        [self movePointer:touches];
        return;
    }
    if (self.stickTouch != nil && [touches containsObject:self.stickTouch])
        [self moveStick:[self.stickTouch locationInView:self]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (self.pointerTouch != nil || !self.flight)
        [self endPointer:touches event:event];
    if (self.stickTouch != nil && [touches containsObject:self.stickTouch])
        [self endStick];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event
{
    self.pointerMoved = YES;
    [self touchesEnded:touches withEvent:event];
}

@end

/* ---------------- Lifecycle ---------------- */

static WcTouchOverlay *g_iosOverlay;

void IosInitializeTouchControls(SDL_Window *window)
{
    SDL_SysWMinfo info;
    UIView *root;

    g_pIosWindow = window;
    IosAttachPad();
    SDL_AddEventWatch(IosWatchEvent, 0);
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) ||
        info.subsystem != SDL_SYSWM_UIKIT) {
        SDL_Log("No UIKit window for the touch controls");
        return;
    }
    root = info.info.uikit.window.rootViewController.view;
    if (root == nil) {
        SDL_Log("No UIKit view for the touch controls");
        return;
    }
    g_iosHaptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [g_iosHaptic prepare];
    g_iosOverlay = [[WcTouchOverlay alloc] initWithFrame:root.bounds];
    [root addSubview:g_iosOverlay];
}

void IosUpdateTouchControls(void)
{
    const int hardware = g_bIosControllerInUse && g_iosHardwareInstance >= 0;

    SdlSelectJoystickInstance(hardware ? g_iosHardwareInstance
                                       : g_iosPadInstance);
    if (g_iosOverlay == nil)
        return;
    [g_iosOverlay standAside:hardware];
    [g_iosOverlay setFlight:IosFlightActive() != 0];
    [g_iosOverlay.superview bringSubviewToFront:g_iosOverlay];
}

void IosShutdownTouchControls(void)
{
    SDL_DelEventWatch(IosWatchEvent, 0);
    [g_iosOverlay removeFromSuperview];
    g_iosOverlay = nil;
    if (g_pIosPad != 0) {
        SDL_JoystickClose(g_pIosPad);
        g_pIosPad = 0;
    }
    g_iosPadInstance = -1;
    g_pIosWindow = 0;
}
