// agent-display: named macOS virtual displays for AI agents.
//
//   agent-display up NAME [--size WxH] [--hidpi]          hold a display until killed
//   agent-display run NAME [--size WxH] [--hidpi] -- CMD   display lives exactly as long as CMD
//   agent-display down NAME                                 remove a display started by `up`
//   agent-display list                                      JSON list of all displays
//   agent-display shot NAME [PATH]                          PNG of that display only
//   agent-display record NAME PATH [--seconds N]            .mov of that display only (default 10 s)
//   agent-display open NAME APP                             launch APP, move its window onto NAME
//   agent-display click NAME X Y [--button B] [--double]    input on that display; X Y are points from
//   agent-display move NAME X Y                             its top left (= screenshot pixels at 1x)
//   agent-display drag NAME X1 Y1 X2 Y2
//   agent-display scroll NAME X Y [--dx N] [--dy N]         wheel notches; positive dy scrolls down
//   agent-display type NAME TEXT
//   agent-display key NAME COMBO...                         e.g. cmd+l enter
//   agent-display ui NAME                                   macOS: controls on that display, as JSON
//   agent-display press NAME ID [--action A]                macOS: press a control, pointer stays put
//   agent-display set NAME ID TEXT                          macOS: set the value of a field
//   agent-display serve NAME [--open] [--show-link]         tailnet-only browser viewer (needs screen-relay)
//   agent-display unserve NAME                              stop the viewer
//   agent-display setup HOST                                install on a Linux host over ssh
//   agent-display mcp                                       MCP server (stdio) exposing the above
//
// Add `--host HOST` to any display command to run it on a host prepared with `setup`.
//
// Build: clang -fobjc-arc -framework AppKit -framework CoreGraphics agent-display.m -o agent-display
//
// ponytail: CGVirtualDisplay* are private CoreGraphics classes, declared here from the runtime's
// own metadata (same API BetterDisplay and DeskPad use). Apple can change them in any macOS release.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/socket.h>
#import <netinet/in.h>

static NSString *const kVersion = @"0.3.0";      // must match VERSION in agent-display-linux.mjs
static NSString *const kScreenRelay = @"0.1.2";  // the screen-relay version that `setup` installs

@interface CGVirtualDisplayDescriptor : NSObject
@property (strong) NSString *name;
@property unsigned vendorID, productID, serialNum, maxPixelsWide, maxPixelsHigh;
@property CGSize sizeInMillimeters;
@property (strong) dispatch_queue_t queue;
@property (copy) void (^terminationHandler)(id, id);
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned)w height:(unsigned)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property unsigned hiDPI;
@property (strong) NSArray *modes;
@end
@interface CGVirtualDisplay : NSObject
@property (readonly) unsigned displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@end

extern char **environ;

// ---------- helpers ----------

static void emit(id obj) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:nil];
  printf("%s\n", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String);
  fflush(stdout);
}

static int fail(NSString *msg, int code) {
  fprintf(stderr, "agent-display: %s\n", msg.UTF8String);
  return code;
}

static NSDictionary *rectDict(CGRect r) {
  return @{@"x": @(r.origin.x), @"y": @(r.origin.y), @"width": @(r.size.width), @"height": @(r.size.height)};
}

// Displays by name. Fresh process = fresh NSScreen list, so callers run as subprocesses.
static NSArray<NSDictionary *> *allDisplays(void) {
  NSMutableArray *out = [NSMutableArray array];
  for (NSScreen *s in NSScreen.screens) {
    CGDirectDisplayID did = [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    [out addObject:@{@"name": s.localizedName, @"displayID": @(did), @"bounds": rectDict(CGDisplayBounds(did)),
                     @"scale": @(s.backingScaleFactor), @"main": CGDisplayIsMain(did) ? @YES : @NO}];
  }
  return out;
}

static NSDictionary *displayNamed(NSString *name) {
  for (NSDictionary *d in allDisplays()) if ([d[@"name"] isEqualToString:name]) return d;
  return nil;
}

static CGRect boundsOf(NSDictionary *d) {
  NSDictionary *b = d[@"bounds"];
  return CGRectMake([b[@"x"] doubleValue], [b[@"y"] doubleValue], [b[@"width"] doubleValue], [b[@"height"] doubleValue]);
}

static NSString *pidPath(NSString *name) {
  NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".cache/agent-display"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *safe = [[name componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]
                    componentsJoinedByString:@"_"];
  return [dir stringByAppendingPathComponent:[safe stringByAppendingString:@".pid"]];
}

static NSString *statePath(NSString *key, NSString *ext) {
  return [[pidPath(key) stringByDeletingPathExtension] stringByAppendingPathExtension:ext];
}

static unsigned fnv1a(NSString *s) {  // stable serial per name, so macOS remembers the arrangement
  unsigned h = 2166136261u;
  for (const char *p = s.UTF8String; *p; p++) h = (h ^ (unsigned char)*p) * 16777619u;
  return h;
}

static int runTool(NSString *path, NSArray *args) {
  NSTask *t = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:path] arguments:args error:nil terminationHandler:nil];
  [t waitUntilExit];
  return t.terminationStatus;
}

// ---------- up / run ----------

static CGVirtualDisplay *gDisplay;  // the display lives exactly as long as this object
static NSString *gPidFile, *gName, *gSelf;

static void cleanupAndExit(int code) {
  if (gName && [NSFileManager.defaultManager fileExistsAtPath:statePath(gName, @"serve")]) {  // stop its viewer too
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:gSelf];
    t.arguments = @[@"unserve", gName];
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    if ([t launchAndReturnError:nil]) [t waitUntilExit];
  }
  if (gPidFile) unlink(gPidFile.fileSystemRepresentation);
  exit(code);
}

static int cmdUp(NSString *name, unsigned w, unsigned h, BOOL hidpi, char **childArgv) {
  if (displayNamed(name)) return fail([NSString stringWithFormat:@"a display named \"%@\" already exists", name], 1);

  gName = name;

  // Place it right of every existing display, so several agent displays line up in a row.
  CGFloat right = 0;
  for (NSDictionary *d in allDisplays()) right = MAX(right, CGRectGetMaxX(boundsOf(d)));

  unsigned scale = hidpi ? 2 : 1;
  CGVirtualDisplayDescriptor *desc = [CGVirtualDisplayDescriptor new];
  desc.name = name;
  desc.vendorID = 0xF0F0;  // arbitrary, unregistered vendor
  desc.productID = 0xA6E7;
  desc.serialNum = fnv1a(name);
  desc.maxPixelsWide = w * scale;
  desc.maxPixelsHigh = h * scale;
  desc.sizeInMillimeters = CGSizeMake(w * 25.4 / 110, h * 25.4 / 110);  // ~110 points per inch
  desc.queue = dispatch_get_main_queue();
  desc.terminationHandler = ^(id a, id b) { fprintf(stderr, "agent-display: system removed the display\n"); cleanupAndExit(1); };

  gDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
  if (!gDisplay) return fail(@"CGVirtualDisplay init failed", 1);

  CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
  settings.hiDPI = hidpi;
  settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w * scale height:h * scale refreshRate:60]];
  if (![gDisplay applySettings:settings]) return fail(@"applySettings failed", 1);

  CGDirectDisplayID did = gDisplay.displayID;
  CGDisplayConfigRef cfg;
  CGBeginDisplayConfiguration(&cfg);
  CGConfigureDisplayOrigin(cfg, did, (int32_t)right, 0);
  CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);

  // Remove the pid file however we exit. SIG_IGN lets dispatch sources take the signals.
  static dispatch_source_t sources[3];
  int sigs[3] = {SIGINT, SIGTERM, SIGHUP};
  __block pid_t child = 0;
  for (int i = 0; i < 3; i++) {
    signal(sigs[i], SIG_IGN);
    sources[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sigs[i], 0, dispatch_get_main_queue());
    int sig = sigs[i];
    dispatch_source_set_event_handler(sources[i], ^{
      if (child) { if (sig != SIGINT) kill(child, sig); }  // Ctrl-C already reached the child's process group
      else cleanupAndExit(0);
    });
    dispatch_resume(sources[i]);
  }

  CGRect b = CGDisplayBounds(did);
  NSDictionary *info = @{@"name": name, @"displayID": @(did), @"bounds": rectDict(b), @"scale": @(scale), @"pid": @(getpid())};

  if (!childArgv) {
    gPidFile = pidPath(name);
    [[NSString stringWithFormat:@"%d", getpid()] writeToFile:gPidFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    emit(info);
    dispatch_main();
  }

  // run: hand the display to CMD through the environment, exit with CMD's status.
  setenv("AGENT_DISPLAY_NAME", name.UTF8String, 1);
  setenv("AGENT_DISPLAY_ID", [NSString stringWithFormat:@"%u", did].UTF8String, 1);
  setenv("AGENT_DISPLAY_BOUNDS", [NSString stringWithFormat:@"%g,%g,%g,%g", b.origin.x, b.origin.y, b.size.width, b.size.height].UTF8String, 1);
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  sigset_t dflt;
  sigemptyset(&dflt);
  for (int i = 0; i < 3; i++) sigaddset(&dflt, sigs[i]);
  posix_spawnattr_setsigdefault(&attr, &dflt);  // the child must not inherit our SIG_IGN
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF);
  int err = posix_spawnp(&child, childArgv[0], NULL, &attr, childArgv, environ);
  if (err) return fail([NSString stringWithFormat:@"cannot start %s: %s", childArgv[0], strerror(err)], 127);
  fprintf(stderr, "agent-display: \"%s\" is display %u at %g,%g (%gx%g); running %s\n",
          name.UTF8String, did, b.origin.x, b.origin.y, b.size.width, b.size.height, childArgv[0]);
  dispatch_async(dispatch_get_global_queue(0, 0), ^{
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    dispatch_async(dispatch_get_main_queue(), ^{ cleanupAndExit(code); });
  });
  dispatch_main();
}

// ---------- down / shot / record / open ----------

static int cmdDown(NSString *name) {
  NSString *pf = pidPath(name);
  pid_t pid = [[NSString stringWithContentsOfFile:pf encoding:NSUTF8StringEncoding error:nil] intValue];
  NSDictionary *d = displayNamed(name);
  if (!d) { unlink(pf.fileSystemRepresentation); return fail(@"no display with that name", 1); }
  if (pid <= 0) return fail(@"display was not started by `agent-display up` (no pid file)", 1);
  if (kill(pid, SIGTERM) != 0) return fail([NSString stringWithFormat:@"kill %d: %s", pid, strerror(errno)], 1);
  // NSScreen caches its list per process; ask CoreGraphics for the live list instead.
  CGDirectDisplayID did = [d[@"displayID"] unsignedIntValue], ids[32];
  BOOL online = YES;
  for (int i = 0; i < 50 && online; i++) {
    usleep(100000);
    uint32_t n = 0;
    CGGetOnlineDisplayList(32, ids, &n);
    online = NO;
    for (uint32_t k = 0; k < n; k++) if (ids[k] == did) online = YES;
  }
  emit(@{@"name": name, @"removed": online ? @NO : @YES});
  return 0;
}

static NSString *rectArg(CGRect r) {
  return [NSString stringWithFormat:@"-R%g,%g,%g,%g", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static int cmdShot(NSString *name, NSString *path) {
  NSDictionary *d = displayNamed(name);
  if (!d) return fail(@"no display with that name", 1);
  if (!path) path = [NSString stringWithFormat:@"%@/.cache/agent-display/%@-%ld.png", NSHomeDirectory(),
                     [pidPath(name).lastPathComponent stringByDeletingPathExtension], (long)NSDate.date.timeIntervalSince1970];
  if (runTool(@"/usr/sbin/screencapture", @[@"-x", rectArg(boundsOf(d)), path]) != 0 ||
      ![NSFileManager.defaultManager fileExistsAtPath:path])
    return fail(@"screencapture failed (does this terminal have Screen Recording permission?)", 1);
  emit(@{@"name": name, @"path": path});
  return 0;
}

static int cmdRecord(NSString *name, NSString *path, int seconds) {
  NSDictionary *d = displayNamed(name);
  if (!d) return fail(@"no display with that name", 1);
  if (runTool(@"/usr/sbin/screencapture", @[@"-x", @"-v", rectArg(boundsOf(d)), [NSString stringWithFormat:@"-V%d", seconds], path]) != 0 ||
      ![NSFileManager.defaultManager fileExistsAtPath:path])
    return fail(@"screencapture recording failed", 1);
  emit(@{@"name": name, @"path": path, @"seconds": @(seconds)});
  return 0;
}

static int cmdOpen(NSString *name, NSString *app) {
  NSDictionary *d = displayNamed(name);
  if (!d) return fail(@"no display with that name", 1);
  if (!AXIsProcessTrusted()) return fail(@"this terminal needs Accessibility permission (System Settings > Privacy & Security)", 1);
  if (runTool(@"/usr/bin/open", @[@"-a", app]) != 0) return fail([NSString stringWithFormat:@"cannot open %@", app], 1);

  // Find the app by name, then wait up to 10 s for a window.
  pid_t pid = 0;
  AXUIElementRef win = NULL;
  for (int i = 0; i < 100 && !win; i++, usleep(100000)) {
    for (NSRunningApplication *ra in NSWorkspace.sharedWorkspace.runningApplications)
      if ([ra.localizedName isEqualToString:app] || [ra.bundleURL.lastPathComponent isEqualToString:[app stringByAppendingString:@".app"]]) pid = ra.processIdentifier;
    if (!pid) continue;
    AXUIElementRef axApp = AXUIElementCreateApplication(pid);
    CFArrayRef wins = NULL;
    if (AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && CFArrayGetCount(wins) > 0)
      win = (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(wins, 0));
    if (wins) CFRelease(wins);
    CFRelease(axApp);
  }
  if (!win) return fail([NSString stringWithFormat:@"%@ has no window to move", app], 1);

  CGRect b = boundsOf(d);
  CGPoint pos = b.origin;
  CGSize size = b.size;
  AXValueRef p = AXValueCreate(kAXValueTypeCGPoint, &pos), s = AXValueCreate(kAXValueTypeCGSize, &size);
  AXUIElementSetAttributeValue(win, kAXPositionAttribute, p);  // move first, then fill the display
  AXUIElementSetAttributeValue(win, kAXSizeAttribute, s);
  CFRelease(p); CFRelease(s); CFRelease(win);
  emit(@{@"name": name, @"app": app, @"pid": @(pid), @"bounds": rectDict(b)});
  return 0;
}

// ---------- input (computer use) ----------
// ponytail: events go through the one system pointer and keyboard (CGEventPost), so they move the
// user's pointer and go to the focused app. macOS has no per-display input; a Linux host has.
// Upgrade path: per-app delivery with CGEventPostToPid when background input is needed.

static const char *kKeys[] = {  // index = macOS virtual key code
  "a","s","d","f","h","g","z","x","c","v","","b","q","w","e","r","y","t","1","2","3","4","6","5","=","9","7","-","8","0",
  "]","o","u","[","i","p","enter","l","j","'","k",";","\\",",","/","n","m",".","tab","space","`","backspace","","escape",
  "","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","","",
  "f5","f6","f7","f3","f8","f9","","f11","","","","","","f10","","f12","","","","home","pageup","delete","f4","end","f2",
  "pagedown","f1","left","right","down","up"};

static void postMouse(CGEventType type, CGPoint p, CGMouseButton b, int clicks) {
  CGEventRef e = CGEventCreateMouseEvent(NULL, type, p, b);
  if (clicks) CGEventSetIntegerValueField(e, kCGMouseEventClickState, clicks);
  CGEventPost(kCGHIDEventTap, e);
  CFRelease(e);
  usleep(20000);  // apps drop events that arrive in the same instant
}

static BOOL postCombo(NSString *combo) {
  CGEventFlags flags = 0;
  int code = -1;
  for (NSString *part in [combo.lowercaseString componentsSeparatedByString:@"+"]) {
    if ([@[@"cmd", @"command", @"super", @"meta"] containsObject:part]) flags |= kCGEventFlagMaskCommand;
    else if ([@[@"ctrl", @"control"] containsObject:part]) flags |= kCGEventFlagMaskControl;
    else if ([@[@"alt", @"option", @"opt"] containsObject:part]) flags |= kCGEventFlagMaskAlternate;
    else if ([part isEqualToString:@"shift"]) flags |= kCGEventFlagMaskShift;
    else {
      NSString *k = [@{@"return": @"enter", @"esc": @"escape"} objectForKey:part] ?: part;
      if (code >= 0 || !k.length) return NO;  // one key for each combo
      for (int i = 0; i < (int)(sizeof kKeys / sizeof *kKeys); i++) if (!strcmp(kKeys[i], k.UTF8String)) code = i;
      if (code < 0) return NO;
    }
  }
  if (code < 0) return NO;
  for (int down = 1; down >= 0; down--) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)code, down);
    CGEventSetFlags(e, flags);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    usleep(20000);
  }
  return YES;
}

// argv: the arguments after NAME.
static int cmdInput(NSString *cmd, NSString *name, NSArray<NSString *> *argv) {
  NSDictionary *d = displayNamed(name);
  if (!d) return fail(@"no display with that name", 1);
  if (!AXIsProcessTrusted()) return fail(@"this terminal needs Accessibility permission (System Settings > Privacy & Security)", 1);
  CGRect b = boundsOf(d);
  NSMutableArray<NSString *> *pos = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSString *> *opt = [NSMutableDictionary dictionary];
  BOOL text = [cmd isEqualToString:@"type"] || [cmd isEqualToString:@"key"];
  BOOL literal = NO;  // after `--` every argument is data
  for (NSUInteger i = 0; i < argv.count; i++) {
    NSString *a = argv[i];
    if (!literal && [a isEqualToString:@"--"]) literal = YES;
    else if (literal || text) [pos addObject:a];
    else if ([a isEqualToString:@"--double"]) opt[a] = @"1";
    else if ([@[@"--button", @"--dx", @"--dy"] containsObject:a] && i + 1 < argv.count) opt[a] = argv[++i];
    else [pos addObject:a];
  }
  NSUInteger want = text ? 1 : [cmd isEqualToString:@"drag"] ? 4 : 2;
  if (pos.count < want || (pos.count != want && ![cmd isEqualToString:@"key"]))
    return fail(@"usage: click|move|scroll NAME X Y, drag NAME X1 Y1 X2 Y2, type NAME TEXT, key NAME COMBO...", 2);

  CGPoint pt[2] = {CGPointZero, CGPointZero};
  if (!text) for (NSUInteger i = 0; i < want; i += 2) {
    char *e1, *e2;
    double x = strtod(pos[i].UTF8String, &e1), y = strtod(pos[i + 1].UTF8String, &e2);
    if (*e1 || *e2 || !pos[i].length || !pos[i + 1].length || !(x >= 0 && y >= 0 && x < b.size.width && y < b.size.height))
      return fail([NSString stringWithFormat:@"X Y must be inside the display: 0,0 to %d,%d", (int)b.size.width - 1, (int)b.size.height - 1], 2);
    pt[i / 2] = CGPointMake(b.origin.x + x, b.origin.y + y);
  }

  if ([cmd isEqualToString:@"type"]) {
    NSString *t = pos[0];
    if (!t.length) return fail(@"TEXT must not be empty", 2);
    for (NSUInteger i = 0; i < t.length;) {  // one composed character for each event pair
      NSRange r = [t rangeOfComposedCharacterSequenceAtIndex:i];
      unichar buf[r.length];
      [t getCharacters:buf range:r];
      if (r.length == 1 && (buf[0] == '\n' || buf[0] == '\t')) postCombo(buf[0] == '\n' ? @"enter" : @"tab");
      else for (int down = 1; down >= 0; down--) {
        CGEventRef e = CGEventCreateKeyboardEvent(NULL, 0, down);
        CGEventSetFlags(e, 0);
        CGEventKeyboardSetUnicodeString(e, r.length, buf);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
        usleep(4000);
      }
      i = NSMaxRange(r);
    }
    emit(@{@"name": name, @"typed": @(t.length)});
    return 0;
  }
  if ([cmd isEqualToString:@"key"]) {
    for (NSString *c in pos) if (!postCombo(c)) return fail([NSString stringWithFormat:@"unknown key combination \"%@\"; use e.g. cmd+l, shift+tab, enter, f5", c], 2);
    emit(@{@"name": name, @"keys": pos});
    return 0;
  }

  postMouse(kCGEventMouseMoved, pt[0], kCGMouseButtonLeft, 0);
  if ([cmd isEqualToString:@"click"]) {
    NSString *bn = opt[@"--button"] ?: @"left";
    NSUInteger bi = [@[@"left", @"right", @"middle"] indexOfObject:bn];
    if (bi == NSNotFound) return fail(@"--button must be left, right or middle", 2);
    CGEventType dn[] = {kCGEventLeftMouseDown, kCGEventRightMouseDown, kCGEventOtherMouseDown};
    CGEventType up[] = {kCGEventLeftMouseUp, kCGEventRightMouseUp, kCGEventOtherMouseUp};
    for (int n = 1; n <= (opt[@"--double"] ? 2 : 1); n++) {
      postMouse(dn[bi], pt[0], (CGMouseButton)bi, n);
      postMouse(up[bi], pt[0], (CGMouseButton)bi, n);
    }
  } else if ([cmd isEqualToString:@"drag"]) {
    postMouse(kCGEventLeftMouseDown, pt[0], kCGMouseButtonLeft, 1);
    for (int i = 1; i <= 10; i++)  // apps start a drag only after they see movement
      postMouse(kCGEventLeftMouseDragged, CGPointMake(pt[0].x + (pt[1].x - pt[0].x) * i / 10, pt[0].y + (pt[1].y - pt[0].y) * i / 10), kCGMouseButtonLeft, 1);
    postMouse(kCGEventLeftMouseUp, pt[1], kCGMouseButtonLeft, 1);
  } else if ([cmd isEqualToString:@"scroll"]) {
    int dx = opt[@"--dx"].intValue, dy = opt[@"--dy"].intValue;
    if ((!dx && !dy) || abs(dx) > 100 || abs(dy) > 100) return fail(@"scroll needs --dx N or --dy N, -100 to 100 notches", 2);
    CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 2, -dy, -dx);  // CG: positive is up/left
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
  }
  usleep(30000);
  CGEventRef now = CGEventCreate(NULL);  // read the pointer back: proof of where the event landed
  CGPoint at = CGEventGetLocation(now);
  CFRelease(now);
  emit(@{@"name": name, @"action": cmd, @"pointer": @{@"x": @(at.x - b.origin.x), @"y": @(at.y - b.origin.y)}});
  return 0;
}

// ---------- ui (accessibility: act on a control, the pointer stays where it is) ----------
// An ID is PID:WINDOW.CHILD.CHILD..., a path of child indexes in the accessibility tree.
// ponytail: an ID is a position, not an identity. It goes stale when the app changes its windows
// or its layout, so callers run `ui` again after each action. press and set print the role and
// label of the control they acted on. Upgrade path: match on role and label when the path moved.
// ponytail: windows only, no menu bar (use `key`), max 400 controls for each call.

static id axGet(AXUIElementRef e, NSString *attr) {
  CFTypeRef v = NULL;
  return AXUIElementCopyAttributeValue(e, (__bridge CFStringRef)attr, &v) == kAXErrorSuccess ? CFBridgingRelease(v) : nil;
}

static BOOL axFrame(AXUIElementRef e, CGRect *r) {
  id p = axGet(e, @"AXPosition"), s = axGet(e, @"AXSize");
  return p && s && CFGetTypeID((__bridge CFTypeRef)p) == AXValueGetTypeID() && CFGetTypeID((__bridge CFTypeRef)s) == AXValueGetTypeID()
      && AXValueGetValue((__bridge AXValueRef)p, kAXValueTypeCGPoint, &r->origin) && AXValueGetValue((__bridge AXValueRef)s, kAXValueTypeCGSize, &r->size);
}

static BOOL axOn(AXUIElementRef e, CGRect b) {  // is the centre of this element on the display?
  CGRect f;
  return axFrame(e, &f) && CGRectContainsPoint(b, CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f)));
}

static NSArray *axWindows(pid_t pid) {
  AXUIElementRef app = AXUIElementCreateApplication(pid);
  AXUIElementSetAttributeValue(app, CFSTR("AXManualAccessibility"), kCFBooleanTrue);  // Electron builds its tree on request
  NSArray *w = axGet(app, @"AXWindows");
  CFRelease(app);
  return [w isKindOfClass:NSArray.class] ? w : @[];
}

static NSString *axText(id v) {
  NSString *s = [v isKindOfClass:NSString.class] ? v : [v isKindOfClass:NSNumber.class] ? [v stringValue] : nil;
  return s.length > 200 ? [[s substringToIndex:200] stringByAppendingString:@"…"] : s;
}

static NSDictionary *axInfo(AXUIElementRef e, CGRect b) {
  NSMutableDictionary *m = [NSMutableDictionary dictionary];
  m[@"role"] = axText(axGet(e, @"AXRole")) ?: @"";
  NSString *label = axText(axGet(e, @"AXTitle"));
  if (!label.length) label = axText(axGet(e, @"AXDescription"));
  if (label.length) m[@"label"] = label;
  NSString *value = axText(axGet(e, @"AXValue"));
  if (value) m[@"value"] = value;
  CGRect f;
  if (axFrame(e, &f)) m[@"frame"] = rectDict(CGRectOffset(f, -b.origin.x, -b.origin.y));
  return m;
}

static void axWalk(AXUIElementRef e, NSString *path, CGRect b, int depth, NSMutableArray *out, int *visited) {
  if (depth > 40 || ++*visited > 5000 || out.count >= 400) return;
  CFArrayRef names = NULL;
  AXUIElementCopyActionNames(e, &names);
  NSArray *all = CFBridgingRelease(names) ?: @[];
  NSMutableArray *acts = [NSMutableArray array];
  for (NSString *a in @[@"AXPress", @"AXIncrement", @"AXDecrement", @"AXConfirm", @"AXCancel", @"AXPick", @"AXOpen"])
    if ([all containsObject:a]) [acts addObject:a];
  Boolean settable = false;
  AXUIElementIsAttributeSettable(e, kAXValueAttribute, &settable);
  NSMutableDictionary *m = [axInfo(e, b) mutableCopy];
  BOOL text = [m[@"role"] isEqualToString:@"AXStaticText"] && [m[@"value"] length];
  if ((acts.count || settable || text) && axOn(e, b)) {
    m[@"id"] = path;
    if (acts.count) m[@"actions"] = acts;
    if (settable) m[@"settable"] = @YES;
    [out addObject:m];
  }
  NSArray *kids = axGet(e, @"AXChildren");
  if (![kids isKindOfClass:NSArray.class]) return;
  for (NSUInteger i = 0; i < kids.count; i++)
    axWalk((__bridge AXUIElementRef)kids[i], [path stringByAppendingFormat:@".%lu", (unsigned long)i], b, depth + 1, out, visited);
}

// argv: the arguments after NAME.
static int cmdUi(NSString *cmd, NSString *name, NSArray<NSString *> *argv) {
  NSDictionary *d = displayNamed(name);
  if (!d) return fail(@"no display with that name", 1);
  if (!AXIsProcessTrusted()) return fail(@"this terminal needs Accessibility permission (System Settings > Privacy & Security)", 1);
  CGRect b = boundsOf(d);
  AXUIElementRef sys = AXUIElementCreateSystemWide();
  AXUIElementSetMessagingTimeout(sys, 2);  // for all elements: an app that hangs must not hang us
  CFRelease(sys);

  if ([cmd isEqualToString:@"ui"]) {
    if (argv.count) return fail(@"usage: ui NAME", 2);
    NSMutableArray *wins = [NSMutableArray array], *out = [NSMutableArray array];
    int visited = 0;
    for (NSRunningApplication *ra in NSWorkspace.sharedWorkspace.runningApplications) {
      if (ra.activationPolicy != NSApplicationActivationPolicyRegular) continue;
      NSArray *ws = axWindows(ra.processIdentifier);
      for (NSUInteger i = 0; i < ws.count; i++) {
        AXUIElementRef w = (__bridge AXUIElementRef)ws[i];
        if (!axOn(w, b)) continue;
        NSString *wid = [NSString stringWithFormat:@"%d:%lu", ra.processIdentifier, (unsigned long)i];
        [wins addObject:@{@"id": wid, @"app": ra.localizedName ?: @"", @"title": axText(axGet(w, @"AXTitle")) ?: @""}];
        axWalk(w, wid, b, 0, out, &visited);
      }
    }
    emit(@{@"name": name, @"windows": wins, @"elements": out, @"truncated": out.count >= 400 || visited > 5000 ? @YES : @NO});
    return 0;
  }

  BOOL set = [cmd isEqualToString:@"set"];
  NSString *ident = argv.count ? argv[0] : @"", *action = @"AXPress", *text = nil;
  NSArray *rest = argv.count ? [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)] : @[];
  if (set) {
    if (rest.count == 2 && [rest[0] isEqualToString:@"--"]) text = rest[1];
    else if (rest.count == 1) text = rest[0];
  } else if (rest.count == 2 && [rest[0] isEqualToString:@"--action"]) action = rest[1];
  if ((set && !text) || (!set && rest.count && rest.count != 2) || (!set && rest.count && ![rest[0] isEqualToString:@"--action"]))
    return fail(@"usage: press NAME ID [--action A], set NAME ID TEXT", 2);
  if ([ident rangeOfString:@"^[0-9]{1,9}:[0-9]{1,4}(\\.[0-9]{1,5}){0,40}$" options:NSRegularExpressionSearch].location == NSNotFound)
    return fail(@"ID must come from `ui`, e.g. 4242:0.3.1", 2);

  NSArray<NSString *> *head = [[ident componentsSeparatedByString:@"."][0] componentsSeparatedByString:@":"];
  NSArray<NSString *> *path = [ident componentsSeparatedByString:@"."];
  NSArray *ws = axWindows(head[0].intValue);
  NSString *stale = @"no control with that ID on this display; run `ui` again";
  if ((NSUInteger)head[1].integerValue >= ws.count) return fail(stale, 1);
  id el = ws[head[1].integerValue];
  if (!axOn((__bridge AXUIElementRef)el, b)) return fail(stale, 1);  // never act on a window of another display
  for (NSUInteger i = 1; i < path.count; i++) {
    NSArray *kids = axGet((__bridge AXUIElementRef)el, @"AXChildren");
    if (![kids isKindOfClass:NSArray.class] || (NSUInteger)path[i].integerValue >= kids.count) return fail(stale, 1);
    el = kids[path[i].integerValue];
  }
  AXUIElementRef e = (__bridge AXUIElementRef)el;
  AXError err = set ? AXUIElementSetAttributeValue(e, kAXValueAttribute, (__bridge CFTypeRef)text)
                    : AXUIElementPerformAction(e, (__bridge CFStringRef)action);
  if (err == kAXErrorCannotComplete)
    return fail(@"the app did not answer in 2 s. The action can have happened: look at the display before you repeat it", 1);
  if (err != kAXErrorSuccess)
    return fail([NSString stringWithFormat:@"this control does not support %@ (AXError %d)", set ? @"a new value" : action, (int)err], 1);
  NSMutableDictionary *m = [axInfo(e, b) mutableCopy];
  m[@"name"] = name; m[@"id"] = ident;
  if (!set) m[@"action"] = action;
  emit(m);
  return 0;
}

// ---------- mcp ----------
// Each tool call runs this binary as a subprocess (fresh display list). Displays created over MCP
// are removed when the MCP client disconnects, so a finished agent session leaves nothing behind.

static NSMutableArray<NSTask *> *gHolders;
static NSMutableArray<NSArray *> *gRemote;  // [host, name] of displays created on other hosts

static NSDictionary *callSelf(NSArray *args) {
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:gSelf];
  t.arguments = args;
  NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
  t.standardOutput = out; t.standardError = err;
  t.standardInput = NSFileHandle.fileHandleWithNullDevice;  // stdin is the JSON-RPC stream
  [t launchAndReturnError:nil];
  NSData *o = [out.fileHandleForReading readDataToEndOfFile], *e = [err.fileHandleForReading readDataToEndOfFile];
  [t waitUntilExit];
  NSString *text = [[NSString alloc] initWithData:(t.terminationStatus ? e : o) encoding:NSUTF8StringEncoding];
  return @{@"ok": @(t.terminationStatus == 0), @"text": [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]};
}

static NSDictionary *tool(NSString *name, NSString *desc, NSDictionary *props, NSArray *required) {
  NSMutableDictionary *p = [props mutableCopy];
  p[@"host"] = @{@"type": @"string", @"description": @"Optional. Run on this tailnet host (prepared with `agent-display setup HOST`), e.g. a Linux VPS. Default: this Mac"};
  return @{@"name": name, @"description": desc, @"inputSchema": @{@"type": @"object", @"properties": p, @"required": required}};
}

static NSArray *mcpTools(void) {
  NSDictionary *str = @{@"type": @"string"};
  NSDictionary *nameP = @{@"type": @"string", @"description": @"Display name, e.g. agent-1"};
  NSDictionary *num = @{@"type": @"number"};
  return @[
    tool(@"display_create", @"Create a named virtual display for this session. It is removed when the session ends.",
         @{@"name": nameP, @"size": @{@"type": @"string", @"description": @"WIDTHxHEIGHT in points, default 1440x900"},
           @"hidpi": @{@"type": @"boolean", @"description": @"2x pixels. Off by default: 1x screenshots cost fewer tokens"}}, @[@"name"]),
    tool(@"display_list", @"List all displays with names, IDs and bounds.", @{}, @[]),
    tool(@"display_remove", @"Remove a display created with display_create.", @{@"name": nameP}, @[@"name"]),
    tool(@"display_screenshot", @"Screenshot one display. Returns the PNG image and its path.", @{@"name": nameP}, @[@"name"]),
    tool(@"display_record", @"Record one display to a .mov file.",
         @{@"name": nameP, @"path": str, @"seconds": @{@"type": @"integer", @"description": @"default 10, max 600"}}, @[@"name", @"path"]),
    tool(@"display_open_app", @"Launch an app (or bring it forward) and move its first window onto the display.",
         @{@"name": nameP, @"app": @{@"type": @"string", @"description": @"App name, e.g. Google Chrome. On a Linux host: a command, e.g. chromium"}}, @[@"name", @"app"]),
    tool(@"display_click", @"Click on a display. x and y are pixels of its 1x screenshot, from the top left. On macOS this moves the user's pointer.",
         @{@"name": nameP, @"x": num, @"y": num, @"button": @{@"type": @"string", @"enum": @[@"left", @"right", @"middle"]}, @"double": @{@"type": @"boolean"}}, @[@"name", @"x", @"y"]),
    tool(@"display_move", @"Move the pointer to a point on a display.", @{@"name": nameP, @"x": num, @"y": num}, @[@"name", @"x", @"y"]),
    tool(@"display_drag", @"Press the left button at x,y, move to x2,y2, release.",
         @{@"name": nameP, @"x": num, @"y": num, @"x2": num, @"y2": num}, @[@"name", @"x", @"y", @"x2", @"y2"]),
    tool(@"display_scroll", @"Scroll at a point on a display. dy and dx are wheel notches; positive dy scrolls down.",
         @{@"name": nameP, @"x": num, @"y": num, @"dx": @{@"type": @"integer"}, @"dy": @{@"type": @"integer"}}, @[@"name", @"x", @"y"]),
    tool(@"display_type", @"Type text into the focused app. Click the target field first. On macOS the text goes to whatever has keyboard focus.",
         @{@"name": nameP, @"text": str}, @[@"name", @"text"]),
    tool(@"display_key", @"Press key combinations in order, e.g. [\"cmd+l\", \"enter\"]. Modifiers: cmd, ctrl, alt, shift.",
         @{@"name": nameP, @"keys": @{@"type": @"array", @"items": str}}, @[@"name", @"keys"]),
    tool(@"display_ui", @"macOS only. List the controls in the windows on a display: id, role, label, value, frame, actions. Use it to act without the user's pointer. Run it again after each action: an id is a position and goes stale.",
         @{@"name": nameP}, @[@"name"]),
    tool(@"display_press", @"macOS only. Press a control from display_ui by id. The user's pointer does not move and the app does not need focus.",
         @{@"name": nameP, @"id": str, @"action": @{@"type": @"string", @"description": @"Default AXPress. One of the actions that display_ui lists"}}, @[@"name", @"id"]),
    tool(@"display_set", @"macOS only. Set the value of a settable control from display_ui, e.g. the text of a field. No pointer, no keyboard focus.",
         @{@"name": nameP, @"id": str, @"text": str}, @[@"name", @"id", @"text"]),
    tool(@"display_serve", @"Start a browser viewer for the display, reachable only from the user's own Tailscale devices. Returns the URL and the path of a private file that holds the full link with its access token. Never print the token.",
         @{@"name": nameP, @"open": @{@"type": @"boolean", @"description": @"Open the viewer in the user's browser on this Mac"}}, @[@"name"]),
    tool(@"display_unserve", @"Stop the browser viewer of a display.", @{@"name": nameP}, @[@"name"]),
  ];
}

static NSDictionary *mcpCall(NSString *tname, NSDictionary *a) {
  NSString *name = [a[@"name"] isKindOfClass:NSString.class] ? a[@"name"] : nil;
  if (![tname isEqualToString:@"display_list"] && !name.length) return @{@"ok": @NO, @"text": @"name is required"};

  NSString *host = [a[@"host"] isKindOfClass:NSString.class] && [a[@"host"] length] ? a[@"host"] : nil;
  NSArray *(^at)(NSArray *) = ^(NSArray *args) { return host ? [args arrayByAddingObjectsFromArray:@[@"--host", host]] : args; };

  if ([tname isEqualToString:@"display_list"]) return callSelf(at(@[@"list"]));
  if ([@[@"display_click", @"display_move", @"display_drag", @"display_scroll", @"display_type", @"display_key"] containsObject:tname]) {
    // `--` ends option parsing in the child, so text or keys that look like options stay data.
    NSMutableArray *args = [@[[tname substringFromIndex:8], name] mutableCopy];
    NSString *(^n)(NSString *) = ^(NSString *k) { return [a[k] isKindOfClass:NSNumber.class] ? [a[k] stringValue] : @""; };
    if ([tname isEqualToString:@"display_type"]) [args addObjectsFromArray:@[@"--", [a[@"text"] isKindOfClass:NSString.class] ? a[@"text"] : @""]];
    else if ([tname isEqualToString:@"display_key"]) {
      [args addObject:@"--"];
      for (id k in ([a[@"keys"] isKindOfClass:NSArray.class] ? a[@"keys"] : @[])) if ([k isKindOfClass:NSString.class]) [args addObject:k];
    } else {
      if ([a[@"button"] isKindOfClass:NSString.class]) [args addObjectsFromArray:@[@"--button", a[@"button"]]];
      if ([a[@"double"] boolValue]) [args addObject:@"--double"];
      if (a[@"dx"]) [args addObjectsFromArray:@[@"--dx", n(@"dx")]];
      if (a[@"dy"]) [args addObjectsFromArray:@[@"--dy", n(@"dy")]];
      [args addObjectsFromArray:@[@"--", n(@"x"), n(@"y")]];
      if ([tname isEqualToString:@"display_drag"]) [args addObjectsFromArray:@[n(@"x2"), n(@"y2")]];
    }
    return callSelf(host ? [@[args[0], args[1], @"--host", host] arrayByAddingObjectsFromArray:[args subarrayWithRange:NSMakeRange(2, args.count - 2)]] : args);
  }
  if ([tname isEqualToString:@"display_ui"]) return callSelf(at(@[@"ui", name]));
  if ([tname isEqualToString:@"display_press"] || [tname isEqualToString:@"display_set"]) {
    NSString *(^sv)(NSString *) = ^(NSString *k) { return [a[k] isKindOfClass:NSString.class] ? (NSString *)a[k] : @""; };
    NSMutableArray *args = [@[[tname substringFromIndex:8], name] mutableCopy];
    if (host) [args addObjectsFromArray:@[@"--host", host]];  // before `--`, or it is data
    [args addObject:sv(@"id")];
    if ([tname isEqualToString:@"display_set"]) {
      if (![a[@"text"] isKindOfClass:NSString.class]) return @{@"ok": @NO, @"text": @"text is required"};
      [args addObjectsFromArray:@[@"--", sv(@"text")]];
    } else if ([a[@"action"] isKindOfClass:NSString.class]) [args addObjectsFromArray:@[@"--action", sv(@"action")]];
    return callSelf(args);
  }
  if ([tname isEqualToString:@"display_serve"]) return callSelf(at([a[@"open"] boolValue] ? @[@"serve", name, @"--open"] : @[@"serve", name]));
  if ([tname isEqualToString:@"display_unserve"]) return callSelf(at(@[@"unserve", name]));
  if (host && [tname isEqualToString:@"display_remove"]) {
    [gRemote removeObject:@[host, name]];
    return callSelf(at(@[@"down", name]));
  }
  if (host && [tname isEqualToString:@"display_create"]) {
    NSDictionary *r = callSelf(at(@[@"up", name, @"--size", a[@"size"] ?: @"1440x900"]));
    if ([r[@"ok"] boolValue]) [gRemote addObject:@[host, name]];
    return r;
  }
  if ([tname isEqualToString:@"display_remove"]) {
    for (NSTask *t in [gHolders copy]) if ([t.arguments[1] isEqualToString:name]) { [t terminate]; [t waitUntilExit]; [gHolders removeObject:t]; }
    return @{@"ok": @YES, @"text": [NSString stringWithFormat:@"removed %@", name]};
  }
  if ([tname isEqualToString:@"display_screenshot"]) return callSelf(at(@[@"shot", name]));
  if ([tname isEqualToString:@"display_open_app"]) return callSelf(at(@[@"open", name, a[@"app"] ?: @""]));
  if ([tname isEqualToString:@"display_record"]) {
    int secs = MAX(1, MIN(600, a[@"seconds"] ? [a[@"seconds"] intValue] : 10));
    return callSelf(at(@[@"record", name, a[@"path"] ?: @"", @"--seconds", @(secs).stringValue]));
  }
  if ([tname isEqualToString:@"display_create"]) {
    NSMutableArray *args = [@[@"up", name, @"--size", a[@"size"] ?: @"1440x900"] mutableCopy];
    if ([a[@"hidpi"] boolValue]) [args addObject:@"--hidpi"];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:gSelf];
    t.arguments = args;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    t.standardOutput = out; t.standardError = err;
    t.standardInput = NSFileHandle.fileHandleWithNullDevice;
    [t launchAndReturnError:nil];
    NSData *line = [out.fileHandleForReading availableData];  // `up` prints one JSON line once the display exists
    if (!line.length) {
      [t waitUntilExit];
      return @{@"ok": @NO, @"text": [[NSString alloc] initWithData:[err.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding]};
    }
    [gHolders addObject:t];
    return @{@"ok": @YES, @"text": [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding]};
  }
  return @{@"ok": @NO, @"text": [NSString stringWithFormat:@"unknown tool %@", tname]};
}

static int cmdMcp(void) {
  gHolders = [NSMutableArray array];
  gRemote = [NSMutableArray array];
  char *buf = NULL;
  size_t cap = 0;
  while (getline(&buf, &cap, stdin) > 0) {
    @autoreleasepool {
      NSDictionary *req = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buf length:strlen(buf)] options:0 error:nil];
      if (![req isKindOfClass:NSDictionary.class] || !req[@"id"]) continue;  // notifications need no reply
      NSString *method = req[@"method"];
      id result = nil;
      if ([method isEqualToString:@"initialize"])
        result = @{@"protocolVersion": req[@"params"][@"protocolVersion"] ?: @"2025-06-18",
                   @"capabilities": @{@"tools": @{}}, @"serverInfo": @{@"name": @"agent-display", @"version": kVersion}};
      else if ([method isEqualToString:@"tools/list"]) result = @{@"tools": mcpTools()};
      else if ([method isEqualToString:@"ping"]) result = @{};
      else if ([method isEqualToString:@"tools/call"]) {
        NSDictionary *args = [req[@"params"][@"arguments"] isKindOfClass:NSDictionary.class] ? req[@"params"][@"arguments"] : @{};
        NSDictionary *r = mcpCall(req[@"params"][@"name"], args);
        NSMutableArray *content = [@[@{@"type": @"text", @"text": r[@"text"] ?: @""}] mutableCopy];
        if ([r[@"ok"] boolValue] && [req[@"params"][@"name"] isEqualToString:@"display_screenshot"]) {
          NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[r[@"text"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
          NSData *png = [NSData dataWithContentsOfFile:j[@"path"]];
          if (png) [content addObject:@{@"type": @"image", @"mimeType": @"image/png", @"data": [png base64EncodedStringWithOptions:0]}];
        }
        result = @{@"content": content, @"isError": [r[@"ok"] boolValue] ? @NO : @YES};
      }
      NSDictionary *resp = result ? @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": result}
                                  : @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"error": @{@"code": @-32601, @"message": @"method not found"}};
      emit(resp);
    }
  }
  for (NSTask *t in gHolders) { [t terminate]; [t waitUntilExit]; }  // client gone: remove its displays
  for (NSArray *r in gRemote) callSelf(@[@"down", r[1], @"--host", r[0]]);
  return 0;
}

// ---------- serve (screen-relay + Tailscale Serve) ----------
// screen-relay streams one display to a browser and takes input for it. It listens on loopback and
// demands a token. Tailscale Serve puts HTTPS in front, reachable only from the user's own tailnet.

static NSString *findTool(NSString *name) {
  NSMutableArray *dirs = [[(NSProcessInfo.processInfo.environment[@"PATH"] ?: @"") componentsSeparatedByString:@":"] mutableCopy];
  [dirs addObjectsFromArray:@[@"/opt/homebrew/bin", @"/usr/local/bin", [NSHomeDirectory() stringByAppendingPathComponent:@".npm-global/bin"]]];
  NSString *nvm = [NSHomeDirectory() stringByAppendingPathComponent:@".nvm/versions/node"];
  NSArray *versions = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:nvm error:nil] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *v in versions.reverseObjectEnumerator) [dirs addObject:[NSString stringWithFormat:@"%@/%@/bin", nvm, v]];
  for (NSString *d in dirs) {
    NSString *p = [d stringByAppendingPathComponent:name];
    if (d.length && [NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
  }
  return nil;
}

// Run a tool and wait. `input` feeds stdin. `out` captures stdout; without it stdout is inherited,
// or dropped when `quiet`.
static int runCmd(NSString *path, NSArray *args, NSData *input, NSData **out, BOOL quiet) {
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:path];
  t.arguments = args;
  NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
  env[@"PATH"] = [NSString stringWithFormat:@"%@:%@", path.stringByDeletingLastPathComponent, env[@"PATH"] ?: @"/usr/bin:/bin"];  // node scripts find `node`
  t.environment = env;
  NSPipe *inPipe = input ? [NSPipe pipe] : nil, *outPipe = out ? [NSPipe pipe] : nil;
  if (inPipe) t.standardInput = inPipe;
  if (outPipe) t.standardOutput = outPipe;
  else if (quiet) t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  if (quiet) t.standardError = NSFileHandle.fileHandleWithNullDevice;
  if (![t launchAndReturnError:nil]) return 127;
  if (inPipe) dispatch_async(dispatch_get_global_queue(0, 0), ^{
    [inPipe.fileHandleForWriting writeData:input error:nil];
    [inPipe.fileHandleForWriting closeAndReturnError:nil];
  });
  if (outPipe) *out = [outPipe.fileHandleForReading readDataToEndOfFile];
  [t waitUntilExit];
  return t.terminationStatus;
}

static NSDictionary *lastJSONLine(NSData *data) {
  NSString *text = [[[NSString alloc] initWithData:data ?: NSData.data encoding:NSUTF8StringEncoding]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString *last = [text componentsSeparatedByString:@"\n"].lastObject ?: @"";
  id j = [NSJSONSerialization JSONObjectWithData:[last dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  return [j isKindOfClass:NSDictionary.class] ? j : @{};
}

// screen-relay with --json right after the subcommand.
static NSDictionary *srJSON(NSString *sr, NSArray *args, int *status) {
  NSMutableArray *a = [args mutableCopy];
  [a insertObject:@"--json" atIndex:1];
  NSData *out = nil;
  *status = runCmd(sr, a, nil, &out, NO);
  return lastJSONLine(out);
}

static NSString *srName(NSString *name) {  // screen-relay session name for a display
  NSString *safe = [pidPath(name).lastPathComponent stringByDeletingPathExtension].lowercaseString;
  return [@"ad-" stringByAppendingString:[safe stringByReplacingOccurrencesOfString:@"_" withString:@"-"]];
}

static int freePort(NSString *name) {  // stable per name, so a bookmark keeps working
  for (unsigned i = 0, h = fnv1a(name); i < 600; i++) {
    int port = 18400 + (int)((h + i) % 600), fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    BOOL ok = bind(fd, (struct sockaddr *)&a, sizeof a) == 0;
    close(fd);
    if (ok) return port;
  }
  return 0;
}

// The viewer link carries the session token: keep it in a private file, print it only on request,
// and hand it to the browser through LaunchServices, never through a command line.
static int finishServe(NSString *name, NSString *host, NSString *url, NSString *link, BOOL open, BOOL showLink) {
  NSString *p = statePath(host ? [NSString stringWithFormat:@"%@-%@", host, name] : name, @"link");
  NSData *bytes = [[link stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
  [NSFileManager.defaultManager removeItemAtPath:p error:nil];
  if (![NSFileManager.defaultManager createFileAtPath:p contents:bytes attributes:@{NSFilePosixPermissions: @0600}])
    return fail(@"cannot write the link file", 1);
  NSMutableDictionary *o = [@{@"name": name, @"url": url, @"linkFile": p} mutableCopy];
  if (host) o[@"host"] = host;
  if (showLink) o[@"link"] = link;
  emit(o);
  if (open) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:link]];
  return 0;
}

static int cmdUnserve(NSString *name) {
  NSString *marker = statePath(name, @"serve");
  NSArray *m = [[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
  if (m.count < 2) { emit(@{@"name": name, @"unserved": @NO}); return 0; }
  NSString *ts = findTool(@"tailscale"), *sr = findTool(@"screen-relay");
  if (ts) runCmd(ts, @[@"serve", [@"--https=" stringByAppendingString:m[0]], @"off"], nil, NULL, YES);
  if (sr) runCmd(sr, @[@"down", @"--name", m[1]], nil, NULL, YES);
  // Drop the stopped session's state (logs, spent token). m[1] comes from srName(): [a-z0-9-] only.
  NSString *state = NSProcessInfo.processInfo.environment[@"XDG_STATE_HOME"] ?: [NSHomeDirectory() stringByAppendingPathComponent:@".local/state"];
  [NSFileManager.defaultManager removeItemAtPath:[NSString stringWithFormat:@"%@/screen-relay/%@", state, m[1]] error:nil];
  [NSFileManager.defaultManager removeItemAtPath:marker error:nil];
  [NSFileManager.defaultManager removeItemAtPath:statePath(name, @"link") error:nil];
  emit(@{@"name": name, @"unserved": @YES});
  return 0;
}

static int cmdServe(NSString *name, BOOL open, BOOL showLink) {
  NSDictionary *d = displayNamed(name);
  if (!d) return fail(@"no display with that name", 1);
  NSString *sr = findTool(@"screen-relay"), *ts = findTool(@"tailscale");
  if (!sr) return fail(@"screen-relay not found; run `npm install -g screen-relay && screen-relay install --yes`", 1);
  if (!ts) return fail(@"tailscale not found", 1);
  NSData *out = nil;
  runCmd(ts, @[@"status", @"--json"], nil, &out, NO);
  NSDictionary *st = [NSJSONSerialization JSONObjectWithData:out ?: NSData.data options:0 error:nil];
  NSString *dns = [st isKindOfClass:NSDictionary.class] ? st[@"Self"][@"DNSName"] : nil;
  if ([dns hasSuffix:@"."]) dns = [dns substringToIndex:dns.length - 1];
  if (!dns.length) return fail(@"Tailscale is not connected", 1);

  if ([NSFileManager.defaultManager fileExistsAtPath:statePath(name, @"serve")])
    runCmd(gSelf, @[@"unserve", name], nil, NULL, YES);  // serve again = new session, new token
  int port = freePort(name), status = 0;
  if (!port) return fail(@"no free port between 18400 and 18999", 1);
  NSString *session = srName(name), *portS = @(port).stringValue;
  NSString *origin = [NSString stringWithFormat:@"https://%@:%d", dns, port];
  NSDictionary *j = srJSON(sr, @[@"up", @"-d", @"--name", session, @"--port", portS, @"--output", [d[@"displayID"] stringValue],
                                 @"--public", origin, @"--bind", @"127.0.0.1"], &status);
  if (status) return fail(j[@"message"] ?: @"screen-relay up failed", 1);
  [[NSString stringWithFormat:@"%@\n%@", portS, session] writeToFile:statePath(name, @"serve") atomically:YES encoding:NSUTF8StringEncoding error:nil];

  if (runCmd(ts, @[@"serve", @"--bg", [@"--https=" stringByAppendingString:portS], [@"http://127.0.0.1:" stringByAppendingString:portS]], nil, &out, NO) != 0) {
    runCmd(gSelf, @[@"unserve", name], nil, NULL, YES);
    return fail(@"tailscale serve failed", 1);
  }
  j = srJSON(sr, @[@"status", @"--name", session, @"--show-token"], &status);
  NSString *token = j[@"session"][@"token"];
  if (status || ![token isKindOfClass:NSString.class]) {
    runCmd(gSelf, @[@"unserve", name], nil, NULL, YES);
    return fail(@"screen-relay gave no token", 1);
  }
  return finishServe(name, nil, origin, [NSString stringWithFormat:@"%@/#token=%@", origin, token], open, showLink);
}

// ---------- --host (another machine over ssh) ----------
// The host runs agent-display-linux.mjs from ~/.local/bin (see `setup`). Tailscale SSH needs no keys.

static NSString *shq(NSString *s) {  // quote one argument for the remote shell
  return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *remoteCmd(NSArray<NSString *> *args) {
  NSMutableArray *q = [NSMutableArray array];
  for (NSString *a in args) [q addObject:shq(a)];
  return [NSString stringWithFormat:@"$HOME/.local/bin/agent-display --expect-version %@ %@", kVersion, [q componentsJoinedByString:@" "]];
}

static int sshRun(NSString *host, NSString *command, NSData *input, NSData **out) {
  // 120 s lets the user approve a Tailscale SSH check; its link goes to stderr.
  NSMutableArray *a = [@[@"-o", @"BatchMode=yes", @"-o", @"ConnectTimeout=120"] mutableCopy];
  if (!input) [a addObject:@"-n"];  // never read our stdin (it is the JSON-RPC stream under MCP)
  [a addObjectsFromArray:@[@"--", host, command]];
  return runCmd(@"/usr/bin/ssh", a, input, out, NO);
}

static int cmdRemote(NSString *host, NSArray<NSString *> *args) {
  NSString *cmd = args[0], *name = args.count > 1 ? args[1] : nil;
  NSData *out = nil;
  int st;
  BOOL shot = [cmd isEqualToString:@"shot"];
  if (shot || [cmd isEqualToString:@"record"]) {  // the host sends the bytes; the file lands here
    if (!name || (!shot && args.count < 3)) return fail(@"usage: agent-display record NAME PATH [--seconds N] --host HOST", 2);
    NSString *path = args.count > 2 ? args[2] : [NSString stringWithFormat:@"%@/.cache/agent-display/%@-%@-%ld.png",
                                                 NSHomeDirectory(), host, name, (long)NSDate.date.timeIntervalSince1970];
    NSMutableArray *r = [@[cmd, name, @"-"] mutableCopy];
    if (args.count > 3) [r addObjectsFromArray:[args subarrayWithRange:NSMakeRange(3, args.count - 3)]];
    if ((st = sshRun(host, remoteCmd(r), nil, &out)) != 0) return st;
    if (!out.length || ![out writeToFile:path atomically:YES]) return fail([@"cannot write " stringByAppendingString:path], 1);
    emit(@{@"name": name, @"host": host, @"path": path});
    return 0;
  }
  if ([cmd isEqualToString:@"serve"]) {
    if (!name) return fail(@"usage: agent-display serve NAME [--open] --host HOST", 2);
    if ((st = sshRun(host, remoteCmd(@[@"serve", name, @"--show-link"]), nil, &out)) != 0) return st;
    NSDictionary *j = lastJSONLine(out);
    if (![j[@"link"] isKindOfClass:NSString.class]) return fail(@"the host returned no viewer link", 1);
    return finishServe(name, host, j[@"url"], j[@"link"], [args containsObject:@"--open"], [args containsObject:@"--show-link"]);
  }
  if ([cmd isEqualToString:@"run"]) {
    // Become ssh: a signal to this process then reaches ssh, the connection drops, and the tty
    // hangup makes the host remove the display.
    const char *c = remoteCmd(args).UTF8String;
    execl("/usr/bin/ssh", "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=120", "-tt", "--", host.UTF8String, c, (char *)NULL);
    return fail(@"cannot start ssh", 127);
  }
  st = sshRun(host, remoteCmd(args), nil, NULL);
  if (st == 127) fprintf(stderr, "agent-display: not installed on %s; run `agent-display setup %s`\n", host.UTF8String, host.UTF8String);
  if (name && ([cmd isEqualToString:@"down"] || [cmd isEqualToString:@"unserve"]))
    [NSFileManager.defaultManager removeItemAtPath:statePath([NSString stringWithFormat:@"%@-%@", host, name], @"link") error:nil];
  return st;
}

// Copy the Linux script to a host and install screen-relay there. Run it again after an update.
static int cmdSetup(NSString *host) {
  NSString *mjs = [[gSelf.stringByResolvingSymlinksInPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"agent-display-linux.mjs"];
  NSData *script = [NSData dataWithContentsOfFile:mjs];
  if (!script) return fail([NSString stringWithFormat:@"%@ not found; keep it next to the agent-display binary", mjs], 1);
  if (sshRun(host, @"mkdir -p ~/.local/bin ~/.cache/agent-display && cat > ~/.local/bin/agent-display && chmod +x ~/.local/bin/agent-display", script, NULL) != 0)
    return fail(@"cannot copy agent-display to the host", 1);
  NSString *sh = [NSString stringWithFormat:
    @"export PATH=$HOME/.npm-global/bin:$HOME/.local/bin:$PATH\n"
    @"command -v node >/dev/null || { echo 'agent-display: node 22 or newer is required on this host' >&2; exit 1; }\n"
    @"command -v screen-relay >/dev/null || npm install -g screen-relay@%@ >&2 || exit 1\n"
    @"screen-relay doctor 2>/dev/null | grep -q 'engine: ok' || screen-relay install --yes --desktop none >&2 || exit 1\n"
    @"command -v ffmpeg >/dev/null || echo 'agent-display: ffmpeg is missing on this host; record will not work' >&2\n"
    @"$HOME/.local/bin/agent-display version\n", kScreenRelay];
  return sshRun(host, @"bash -s", [sh dataUsingEncoding:NSUTF8StringEncoding], NULL);
}

// ---------- main ----------

static int usage(void) {
  fprintf(stderr,
    "usage:\n"
    "  agent-display up NAME [--size WxH] [--hidpi]\n"
    "  agent-display run NAME [--size WxH] [--hidpi] -- CMD [ARGS...]\n"
    "  agent-display down NAME\n"
    "  agent-display list\n"
    "  agent-display shot NAME [PATH]\n"
    "  agent-display record NAME PATH [--seconds N]\n"
    "  agent-display open NAME APP\n"
    "  agent-display click NAME X Y [--button left|right|middle] [--double]\n"
    "  agent-display move NAME X Y\n"
    "  agent-display drag NAME X1 Y1 X2 Y2\n"
    "  agent-display scroll NAME X Y [--dx N] [--dy N]\n"
    "  agent-display type NAME TEXT\n"
    "  agent-display key NAME COMBO...\n"
    "  agent-display ui NAME\n"
    "  agent-display press NAME ID [--action A]\n"
    "  agent-display set NAME ID TEXT\n"
    "  agent-display serve NAME [--open] [--show-link]\n"
    "  agent-display unserve NAME\n"
    "  agent-display setup HOST\n"
    "  agent-display mcp\n"
    "Add --host HOST to run a display command on a host prepared with `setup`.\n");
  return 2;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    gSelf = NSBundle.mainBundle.executablePath;  // absolute, even when started by a relative path
    signal(SIGPIPE, SIG_IGN);

    NSString *host = nil;  // --host HOST, anywhere before a `--`
    for (int i = 1; i < argc - 1 && strcmp(argv[i], "--"); i++) {
      if (strcmp(argv[i], "--host")) continue;
      host = @(argv[i + 1]);
      memmove(&argv[i], &argv[i + 2], (size_t)(argc - i - 1) * sizeof *argv);
      argc -= 2;
      break;
    }
    if (argc < 2) return usage();
    NSString *cmd = @(argv[1]);
    if ([cmd isEqualToString:@"setup"] && argc == 3) host = @(argv[2]);
    // A host name goes to ssh, so allow only plain names: nothing that starts with `-`.
    if (host && [host rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$" options:NSRegularExpressionSearch].location == NSNotFound)
      return fail(@"HOST must be a plain host name", 2);
    if ([cmd isEqualToString:@"setup"]) return argc == 3 ? cmdSetup(host) : usage();
    if ([cmd isEqualToString:@"version"] && !host) { emit(@{@"version": kVersion, @"platform": @"macos"}); return 0; }
    if (host && ![cmd isEqualToString:@"mcp"]) {
      NSMutableArray *args = [NSMutableArray array];
      for (int i = 1; i < argc; i++) [args addObject:@(argv[i])];
      return cmdRemote(host, args);
    }
    if ([cmd isEqualToString:@"list"]) { emit(allDisplays()); return 0; }
    if ([cmd isEqualToString:@"mcp"]) return cmdMcp();
    if (argc < 3) return usage();
    NSString *name = @(argv[2]);

    if ([cmd isEqualToString:@"up"] || [cmd isEqualToString:@"run"]) {
      unsigned w = 1440, h = 900;  // fixed default size: same screenshots on every run
      BOOL hidpi = NO;
      char **child = NULL;
      for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--hidpi")) hidpi = YES;
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) {
          if (sscanf(argv[++i], "%ux%u", &w, &h) != 2 || w < 640 || h < 480 || w > 8192 || h > 8192)
            return fail(@"--size must be WIDTHxHEIGHT points, 640x480 to 8192x8192", 2);
        } else if (!strcmp(argv[i], "--") && i + 1 < argc) { child = &argv[i + 1]; break; }
        else return usage();
      }
      if (hidpi && (w > 4096 || h > 4096)) return fail(@"--hidpi supports up to 4096x4096 points", 2);
      if ([cmd isEqualToString:@"run"] && !child) return usage();
      if ([cmd isEqualToString:@"up"] && child) return usage();
      return cmdUp(name, w, h, hidpi, child);
    }
    if ([@[@"click", @"move", @"drag", @"scroll", @"type", @"key"] containsObject:cmd]) {
      NSMutableArray *rest = [NSMutableArray array];
      for (int i = 3; i < argc; i++) [rest addObject:@(argv[i])];
      return cmdInput(cmd, name, rest);
    }
    if ([@[@"ui", @"press", @"set"] containsObject:cmd]) {
      NSMutableArray *rest = [NSMutableArray array];
      for (int i = 3; i < argc; i++) [rest addObject:@(argv[i])];
      return cmdUi(cmd, name, rest);
    }
    if ([cmd isEqualToString:@"down"]) return cmdDown(name);
    if ([cmd isEqualToString:@"unserve"]) return cmdUnserve(name);
    if ([cmd isEqualToString:@"serve"]) {
      BOOL open = NO, show = NO;
      for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--open")) open = YES;
        else if (!strcmp(argv[i], "--show-link")) show = YES;
        else return usage();
      }
      return cmdServe(name, open, show);
    }
    if ([cmd isEqualToString:@"shot"]) return cmdShot(name, argc > 3 ? @(argv[3]) : nil);
    if ([cmd isEqualToString:@"open"] && argc == 4) return cmdOpen(name, @(argv[3]));
    if ([cmd isEqualToString:@"record"] && argc >= 4) {
      int secs = 10;
      if (argc == 6 && !strcmp(argv[4], "--seconds")) secs = atoi(argv[5]);
      if (secs < 1 || secs > 600) return fail(@"--seconds must be 1 to 600", 2);
      return cmdRecord(name, @(argv[3]), secs);
    }
    return usage();
  }
}
