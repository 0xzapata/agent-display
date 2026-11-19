// agent-display: named macOS virtual displays for AI agents.
//
//   agent-display up NAME [--size WxH] [--hidpi]          hold a display until killed
//   agent-display run NAME [--size WxH] [--hidpi] -- CMD   display lives exactly as long as CMD
//   agent-display down NAME                                 remove a display started by `up`
//   agent-display list                                      JSON list of all displays
//   agent-display shot NAME [PATH]                          PNG of that display only
//   agent-display record NAME PATH [--seconds N]            .mov of that display only (default 10 s)
//   agent-display open NAME APP                             launch APP, move its window onto NAME
//   agent-display mcp                                       MCP server (stdio) exposing the above
//
// Build: clang -fobjc-arc -framework AppKit -framework CoreGraphics agent-display.m -o agent-display
//
// ponytail: CGVirtualDisplay* are private CoreGraphics classes, declared here from the runtime's
// own metadata (same API BetterDisplay and DeskPad use). Apple can change them in any macOS release.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <spawn.h>
#import <sys/wait.h>

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
static NSString *gPidFile;

static void cleanupAndExit(int code) {
  if (gPidFile) unlink(gPidFile.fileSystemRepresentation);
  exit(code);
}

static int cmdUp(NSString *name, unsigned w, unsigned h, BOOL hidpi, char **childArgv) {
  if (displayNamed(name)) return fail([NSString stringWithFormat:@"a display named \"%@\" already exists", name], 1);

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

// ---------- mcp ----------
// Each tool call runs this binary as a subprocess (fresh display list). Displays created over MCP
// are removed when the MCP client disconnects, so a finished agent session leaves nothing behind.

static NSString *gSelf;
static NSMutableArray<NSTask *> *gHolders;

static NSDictionary *callSelf(NSArray *args) {
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:gSelf];
  t.arguments = args;
  NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
  t.standardOutput = out; t.standardError = err;
  [t launchAndReturnError:nil];
  NSData *o = [out.fileHandleForReading readDataToEndOfFile], *e = [err.fileHandleForReading readDataToEndOfFile];
  [t waitUntilExit];
  NSString *text = [[NSString alloc] initWithData:(t.terminationStatus ? e : o) encoding:NSUTF8StringEncoding];
  return @{@"ok": @(t.terminationStatus == 0), @"text": [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]};
}

static NSDictionary *tool(NSString *name, NSString *desc, NSDictionary *props, NSArray *required) {
  return @{@"name": name, @"description": desc, @"inputSchema": @{@"type": @"object", @"properties": props, @"required": required}};
}

static NSArray *mcpTools(void) {
  NSDictionary *str = @{@"type": @"string"};
  NSDictionary *nameP = @{@"type": @"string", @"description": @"Display name, e.g. agent-1"};
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
         @{@"name": nameP, @"app": @{@"type": @"string", @"description": @"App name, e.g. Google Chrome"}}, @[@"name", @"app"]),
  ];
}

static NSDictionary *mcpCall(NSString *tname, NSDictionary *a) {
  NSString *name = [a[@"name"] isKindOfClass:NSString.class] ? a[@"name"] : nil;
  if (![tname isEqualToString:@"display_list"] && !name.length) return @{@"ok": @NO, @"text": @"name is required"};

  if ([tname isEqualToString:@"display_list"]) return callSelf(@[@"list"]);
  if ([tname isEqualToString:@"display_remove"]) {
    for (NSTask *t in [gHolders copy]) if ([t.arguments[1] isEqualToString:name]) { [t terminate]; [t waitUntilExit]; [gHolders removeObject:t]; }
    return @{@"ok": @YES, @"text": [NSString stringWithFormat:@"removed %@", name]};
  }
  if ([tname isEqualToString:@"display_screenshot"]) return callSelf(@[@"shot", name]);
  if ([tname isEqualToString:@"display_open_app"]) return callSelf(@[@"open", name, a[@"app"] ?: @""]);
  if ([tname isEqualToString:@"display_record"]) {
    int secs = MAX(1, MIN(600, a[@"seconds"] ? [a[@"seconds"] intValue] : 10));
    return callSelf(@[@"record", name, a[@"path"] ?: @"", @"--seconds", @(secs).stringValue]);
  }
  if ([tname isEqualToString:@"display_create"]) {
    NSMutableArray *args = [@[@"up", name, @"--size", a[@"size"] ?: @"1440x900"] mutableCopy];
    if ([a[@"hidpi"] boolValue]) [args addObject:@"--hidpi"];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:gSelf];
    t.arguments = args;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    t.standardOutput = out; t.standardError = err;
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
                   @"capabilities": @{@"tools": @{}}, @"serverInfo": @{@"name": @"agent-display", @"version": @"0.1.0"}};
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
        result = @{@"content": content, @"isError": @(![r[@"ok"] boolValue])};
      }
      NSDictionary *resp = result ? @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": result}
                                  : @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"error": @{@"code": @-32601, @"message": @"method not found"}};
      emit(resp);
    }
  }
  for (NSTask *t in gHolders) { [t terminate]; [t waitUntilExit]; }  // client gone: remove its displays
  return 0;
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
    "  agent-display mcp\n");
  return 2;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    gSelf = NSBundle.mainBundle.executablePath;  // absolute, even when started by a relative path
    if (argc < 2) return usage();
    NSString *cmd = @(argv[1]);
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
    if ([cmd isEqualToString:@"down"]) return cmdDown(name);
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
