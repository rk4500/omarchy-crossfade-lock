import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var shell: null
  property var settings: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || "User"
  readonly property string loginName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  readonly property string stateRoot: stateHome + "/omarchy"
  readonly property string shareRoot: "/usr/share/omarchy"
  readonly property string omarchyBin: "/usr/share/omarchy/bin/omarchy"
  readonly property string systemctlBin: "/usr/bin/systemctl"
  readonly property string sessionLockedBin: "/usr/share/omarchy/bin/omarchy-hyprland-session-locked"
  readonly property string wakeBin: "/usr/share/omarchy/bin/omarchy-system-wake"
  readonly property string brightKeyboardBin: "/usr/share/omarchy/bin/omarchy-brightness-keyboard"
  readonly property string brightDisplayBin: "/usr/share/omarchy/bin/omarchy-brightness-display"
  readonly property string fprintdListBin: "/usr/bin/fprintd-list"
  readonly property string fingerprintPamPath: "/etc/pam.d/omarchy-lock-fingerprint"
  readonly property string fixedPath: "/usr/local/sbin:/usr/local/bin:/usr/bin"
  property bool fingerprintPamFile: false
  property int maxHelperBytes: 4096
  property int helperTimeoutMs: 3000
  property int wakeTimeoutMs: 5000

  property string timeFormat: setting("timeFormat", "hh:mm AP")
  property string dateFormat: setting("dateFormat", "dddd, MMMM d")

  property bool lockRequested: false
  property bool pendingSessionLock: false

  // Lock-transition crossfade: capture the live desktop once via
  // Quickshell's native ScreencopyView, show it full-screen in a non-secure
  // overlay (pixel-identical to what's already on screen, so showing it is
  // imperceptible), then crossfade to the blurred lock content while the
  // real secure surface maps underneath — invisibly, since the overlay
  // already covers it with matching content. This is NOT the compositor
  // animating the secure surface (that's protocol-forbidden); it's our own
  // content crossfading in a surface we fully control, with the real lock
  // swapped in only once already hidden behind it. The overlay grabs
  // keyboard/pointer exclusively from its first frame — the session isn't
  // protocol-locked until `secure`, but nothing behind it is reachable
  // while it's up.
  //
  // ScreencopyView (in-process, GPU texture, no subprocess/disk I/O)
  // measured ~60ms to hasContent on this machine — over 10x faster than
  // shelling out to `grim`, which it replaced. No temp file either, so
  // there's nothing to clean up or leak on disk.
  // transitionOverlayVisible controls whether the overlay WINDOW is mapped
  // at all. transitionContentActive controls whether it's actually
  // grabbing focus/input and showing content. These are deliberately
  // separate: toggling the window's mapped state on and off is a fresh
  // surface-creation handshake with the compositor each time (not a warm
  // repaint), which measurably doesn't complete on any fixed timer you'd
  // want to wait on — confirmed by eye as "sometimes clean, sometimes the
  // real desktop pops through first." So the window, once first shown, stays
  // mapped continuously for the rest of the lock session; only
  // transitionContentActive toggles per phase. By the time unlock needs it,
  // the window has been warm for as long as you were locked, so a brief
  // settle is reliable instead of a guess.
  property bool transitionOverlayVisible: false
  property bool transitionContentActive: false
  property bool transitionCrossfadeTrigger: false
  // Unlock direction: on successful auth, pre-arm an overlay copy of the
  // current lock appearance (hidden behind the still-active secure
  // surface, same as the lock direction), release the real lock
  // underneath it (invisible hand-off, matching content), and only THEN
  // crossfade away to reveal the frame captured at lock time
  // (transitionCapture, untouched since — see showTransitionOverlay()).
  // Animating before releasing doesn't work here, unlike entrance: the
  // real secure surface renders on top of everything for as long as it
  // exists, so an animation played out while still locked is invisible —
  // see finishUnlock()'s comment. Also note this crossfades to a STALE
  // frame, not a live one: capturing the real desktop while our own
  // overlay still covers it is impossible (screencopy only sees what's
  // actually composited to the output, which while covered is us, not
  // what's hidden beneath) — so if anything changed on the desktop while
  // locked, the final hand-off to the live compositor will show a visible
  // correction. Accepted tradeoff, not a bug.
  property bool unlockTransitionActive: false
  property bool unlockCrossfadeTrigger: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  property bool previewVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property int backgroundVersion: 0
  // True once the background-path lookup has completed at least once
  // (whether it found a path or not) — distinguishes "still fetching" from
  // "fetched, no background configured" so the lock doesn't wait forever.
  property bool backgroundResolved: false

  // Blurring is done once, on disk, via `magick` — not live on the GPU.
  // An ext-session-lock surface gets zero render frames while unmapped, so
  // a live MultiEffect blur can't converge before the surface is shown no
  // matter how long we wait beforehand; baking the blur into a file sidesteps
  // that entirely; the lock view just displays a plain already-blurred image.
  readonly property string blurredDir: stateRoot + "/archer-lock"
  readonly property string blurredBackgroundPath: blurredDir + "/blurred-bg.png"
  property int blurredBackgroundVersion: 0
  property bool blurredBackgroundReady: false
  property string blurredSourcePath: ""

  readonly property bool backgroundReady: root.backgroundResolved && root.blurredBackgroundReady
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool strandedLock: false
  property bool strandedLockResolved: false

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating

  property var fileConfig: ({})
  function parseFileConfig(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""));
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : ({});
    } catch (e) {
      return ({});
    }
  }
  function setting(key, fallback) {
    var value = root.fileConfig ? root.fileConfig[key] : undefined;
    return value === undefined || value === null ? fallback : value;
  }
  property int maxConfigBytes: 65536
  property int configTimeoutMs: 5000
  readonly property string readScriptPath: Qt.resolvedUrl("read-config").toString().replace(/^file:\/\//, "")
  property string configRaw: ""
  property bool configApplied: false

  function loadConfig() {
    if (configProc.running)
      return;
    configProc.collected = "";
    configProc.collectedBytes = 0;
    configProc.overflowed = false;
    configProc.timedOut = false;
    configProc.command = [root.readScriptPath, Quickshell.env("HOME") + "/.config/omarchy/lock.json", String(root.maxConfigBytes)];
    configWatchdog.restart();
    configProc.running = true;
  }

  function applyConfig(ok, raw) {
    var next = ok ? String(raw || "") : "";
    if (next === root.configRaw && root.configApplied)
      return;
    root.configRaw = next;
    root.configApplied = true;
    root.fileConfig = root.parseFileConfig(next);
  }

  Timer {
    id: configWatchdog
    interval: root.configTimeoutMs
    repeat: false
    onTriggered: {
      if (configProc.running) {
        configProc.timedOut = true;
        configProc.collected = "";
        configProc.collectedBytes = 0;
        root.killProc(configProc);
      }
    }
  }

  Timer {
    id: configPoll
    interval: 10000
    repeat: true
    running: true
    onTriggered: root.loadConfig()
  }

  Process {
    id: configProc
    property string collected: ""
    property int collectedBytes: 0
    property bool overflowed: false
    property bool timedOut: false
    stdout: SplitParser {
      onRead: function (data) {
        if (configProc.overflowed || configProc.timedOut)
          return;
        var chunk = String(data + "\n");
        if (configProc.collectedBytes + chunk.length > root.maxConfigBytes) {
          configProc.overflowed = true;
          configProc.collected = "";
          configProc.collectedBytes = 0;
          root.killProc(configProc);
          return;
        }
        configProc.collected += chunk;
        configProc.collectedBytes += chunk.length;
      }
    }
    stderr: SplitParser {
      onRead: function (data) {
        if (configProc.overflowed || configProc.timedOut)
          return;
        configProc.collectedBytes += String(data + "\n").length;
        if (configProc.collectedBytes > root.maxConfigBytes) {
          configProc.overflowed = true;
          configProc.collected = "";
          configProc.collectedBytes = 0;
          root.killProc(configProc);
        }
      }
    }
    onExited: function (exitCode) {
      configWatchdog.stop();
      var ok = !configProc.overflowed && !configProc.timedOut && exitCode === 0;
      var output = String(configProc.collected);
      configProc.collected = "";
      configProc.collectedBytes = 0;
      configProc.overflowed = false;
      configProc.timedOut = false;
      root.applyConfig(ok, output);
    }
  }

  function realScreenCount() {
    var screens = Quickshell.screens || [];
    var count = 0;
    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i];
      if (screen && screen.name && screen.width > 0 && screen.height > 0)
        count += 1;
    }
    return count;
  }

  function hasRealScreen() {
    return realScreenCount() > 0;
  }

  function queueSessionLock() {
    pendingSessionLock = true;
    if (!sessionLockStabilizeTimer.running)
      logEvent("lock-pending: screen-stabilizing");
    sessionLockStabilizeTimer.restart();
    if (!pendingSessionLockTimer.running)
      pendingSessionLockTimer.start();
  }

  // Don't map the lock surface until the wallpaper has actually finished
  // decoding — otherwise the surface becomes visible (compositor "secure",
  // ~500ms after queueSessionLock()) before the image is ready and you see
  // plain Color.background for a beat. Bounded by backgroundWaitWatchdog so
  // a broken/missing wallpaper can never delay the actual lock indefinitely.
  function awaitBackgroundThenLock() {
    if (!root.lockRequested || sessionLock.locked || sessionLock.secure)
      return;
    if (root.backgroundReady) {
      backgroundWaitWatchdog.stop();
      queueSessionLock();
    } else if (!backgroundWaitWatchdog.running) {
      logEvent("lock-pending: waiting-for-background");
      backgroundWaitWatchdog.restart();
    }
  }

  onBackgroundReadyChanged: {
    if (root.lockRequested)
      root.awaitBackgroundThenLock();
  }

  Timer {
    id: backgroundWaitWatchdog
    // Generous: covers a cold-start `magick` blur run (first lock ever, or
    // right after a theme change). Every lock after that hits the cached
    // blurred-bg.png and resolves near-instantly, well under this.
    interval: 1800
    repeat: false
    onTriggered: {
      if (root.lockRequested && !sessionLock.locked && !sessionLock.secure) {
        logEvent("lock-pending: background-wait-timeout");
        queueSessionLock();
      }
    }
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure)
      return;
    if (sessionLockStabilizeTimer.running)
      return;
    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen")
        logEvent("lock-pending: no-real-screen");
      pendingSessionLock = true;
      if (!pendingSessionLockTimer.running)
        pendingSessionLockTimer.start();
      return;
    }
    pendingSessionLock = false;
    pendingSessionLockTimer.stop();
    sessionLock.locked = true;
  }

  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running)
      return;
    if (locked || lockRequested) {
      strandedLockResolved = true;
      return;
    }
    strandedLockCheckProc.running = true;
    strandedWatchdog.restart();
  }

  function killProc(proc) {
    try {
      proc.signal(9);
    } catch (e) {
    }
    proc.running = false;
  }

  function acceptBackground(raw) {
    var line = String(raw || "").split("\n")[0].trim();
    if (line === "" || line.charAt(0) !== "/" || line.length > 4096)
      return "";
    if (line.indexOf(root.stateRoot + "/") !== 0 && line.indexOf(root.shareRoot + "/") !== 0)
      return "";
    return line;
  }

  function recoverStrandedLock() {
    if (!strandedLock || locked || !passwordPamConfigured)
      return;
    strandedLock = false;
    logEvent("lock-stranded: recovering");
    beginLock();
  }

  function refreshBackground() {
    if (backgroundProc.running)
      return;
    backgroundProc.collected = "";
    backgroundProc.collectedBytes = 0;
    backgroundProc.overflowed = false;
    backgroundProc.timedOut = false;
    backgroundProc.command = ["/usr/bin/env", "-i", "/usr/bin/sh", "-c", "p=$(/usr/bin/readlink -f \"$0\" 2>/dev/null); [ -n \"$p\" ] || exit 0; case \"$p\" in \"$1\"/*|\"$2\"/*) ;; *) exit 0;; esac; [ -f \"$p\" ] && [ ! -L \"$p\" ] || exit 0; [ \"$(/usr/bin/stat -c %s \"$p\")\" -le 67108864 ] || exit 0; printf '%s' \"$p\"", root.currentBackgroundLink, root.stateRoot, root.shareRoot];
    backgroundProc.running = true;
    backgroundWatchdog.restart();
  }

  function refreshFingerprintStatus() {
    if (!root.fingerprintPamFile || root.loginName === "" || fingerprintListProc.running) {
      if (!root.fingerprintPamFile || root.loginName === "")
        setFingerprintConfigured(false);
      return;
    }
    fingerprintListProc.collected = "";
    fingerprintListProc.collectedBytes = 0;
    fingerprintListProc.overflowed = false;
    fingerprintListProc.timedOut = false;
    fingerprintListProc.command = [root.fprintdListBin, root.loginName];
    fingerprintListProc.running = true;
    fingerprintWatchdog.restart();
  }

  function setFingerprintConfigured(on) {
    root.fingerprintConfigured = on === true;
    if (root.lockRequested && root.fingerprintConfigured)
      root.startFingerprint();
    else if (!root.fingerprintConfigured && fingerprintPam.active)
      fingerprintPam.abort();
  }

  function logEvent(event) {
    lastEvent = event;
    lastEventAt = new Date().toISOString();
    console.log("omarchy lock " + lastEventAt + " " + event);
  }

  function resetAuthenticationState() {
    enteredPassword = "";
    pendingPassword = "";
    failureMessage = "";
    failedAttempts = 0;
    authenticatingPassword = false;
    fingerprintAuthenticating = false;
    fingerprintRetryTimer.stop();
    if (passwordPam.active)
      passwordPam.abort();
    if (fingerprintPam.active)
      fingerprintPam.abort();
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam");
      return false;
    }
    resetAuthenticationState();
    lockRequested = true;
    armBlankTimer();
    logEvent("lock-requested");
    Qt.callLater(function () {
        root.refreshBackground();
        root.refreshFingerprintStatus();
      });
    root.showTransitionOverlay();
    return true;
  }

  // IMPORTANT ordering, unlike the lock direction: ext-session-lock
  // surfaces render above every layer-shell surface unconditionally
  // WHENEVER THEY EXIST — so while still locked, our overlay is hidden
  // behind the real surface no matter what it does, including animating.
  // An earlier version animated the crossfade *before* releasing the real
  // lock, which played out entirely invisibly behind the still-active
  // secure surface — the user only ever saw its already-finished final
  // frame pop in the instant the real surface finally disappeared. Fix:
  // pre-arm fully opaque (matching the real lock screen, so the handoff
  // itself is invisible) → release the real lock → THEN animate, once our
  // overlay is actually the only thing on screen and nothing hides it.
  function finishUnlock() {
    if (!root.locked && !lockRequested)
      return;
    if (root.unlockTransitionActive)
      return;
    root.unlockTransitionActive = true;
    // Window has been mapped and warm since the lock-entrance transition
    // (pauseTransitionOverlay left transitionOverlayVisible true) — just
    // reactivating content/focus on an already-live surface, not a fresh
    // mapping, so the settle below only needs to cover a repaint.
    root.transitionOverlayVisible = true;
    root.transitionContentActive = true;
    root.unlockCrossfadeTrigger = false;
    unlockPrimeTimer.restart();
  }

  Timer {
    id: unlockPrimeTimer
    // Guarantees the overlay's hand-off frame (matching the real lock
    // screen) has actually been presented before releasing the real
    // surface out from under it. This used to need a long, flaky delay
    // because the window was being fully unmapped and remapped each time
    // (a cold surface-creation handshake with the compositor, not a warm
    // repaint) — confirmed by eye as "sometimes clean, sometimes the real
    // desktop pops through first." Now that the window stays mapped
    // continuously for the whole lock session (transitionContentActive),
    // this only needs to cover a repaint on an already-live surface, not a
    // fresh mapping.
    interval: 48
    repeat: false
    onTriggered: root.releaseLock()
  }

  // The actual protocol release. Our overlay is already showing matching
  // content, so the real surface disappearing underneath it is invisible.
  function releaseLock() {
    lockRequested = false;
    pendingSessionLock = false;
    sessionLockStabilizeTimer.stop();
    pendingSessionLockTimer.stop();
    resetAuthenticationState();
    idleBlankTimer.stop();
    sessionLock.locked = false;
    logEvent("unlocked");
    runWake();
    unlockRevealTimer.restart();
  }

  Timer {
    id: unlockRevealTimer
    // Session-locked/secure going false isn't instant either — give the
    // protocol teardown a moment so our now-topmost overlay's hand-off
    // frame has definitely been presented before animating away from it.
    interval: 32
    repeat: false
    onTriggered: {
      root.unlockCrossfadeTrigger = true;
      unlockOverlayDropTimer.restart();
    }
  }

  Timer {
    id: unlockOverlayDropTimer
    // Shorter than the lock-entrance crossfade (450ms) on purpose — you're
    // far more impatient leaving the lock screen than arriving at it.
    // Matches unlockFadeView's 200ms opacity Behavior + a small buffer.
    interval: 230
    repeat: false
    onTriggered: {
      root.hideTransitionOverlay();
      root.unlockTransitionActive = false;
    }
  }

  function armBlankTimer() {
    idleBlankTimer.armedAt = Date.now();
    idleBlankTimer.restart();
  }

  function runWake() {
    if (!wakeProcess.running) {
      wakeProcess.running = true;
      wakeWatchdog.restart();
    }
    if (lockRequested)
      armBlankTimer();
  }

  function runBlank() {
    if (!blankKeyboardProc.running) {
      blankKeyboardProc.running = true;
      blankWatchdog.restart();
    }
    if (!blankDisplayProc.running) {
      blankDisplayProc.running = true;
      blankWatchdog.restart();
    }
  }

  function requestShutdown() {
    root.runPower([root.omarchyBin, "system", "shutdown"]);
  }

  function requestReboot() {
    root.runPower([root.omarchyBin, "system", "reboot"]);
  }

  function requestSuspend() {
    root.runPower([root.systemctlBin, "suspend"]);
  }

  function runPower(args) {
    if (powerProc.running)
      return;
    powerProc.command = args;
    powerProc.running = true;
    powerWatchdog.restart();
  }

  function submitPassword(value) {
    var password = String(value || "");
    if (!lockRequested || authenticatingPassword || password.length === 0)
      return;
    runWake();
    pendingPassword = password;
    failureMessage = "";
    authenticatingPassword = true;
    if (!passwordPam.start()) {
      handlePasswordFailure();
      return;
    }
    Qt.callLater(respondToPasswordPrompt);
  }

  function respondToPasswordPrompt() {
    if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired)
      return;
    passwordPam.respond(pendingPassword);
  }

  function handlePasswordFailure() {
    if (!lockRequested)
      return;
    authenticatingPassword = false;
    enteredPassword = "";
    pendingPassword = "";
    failedAttempts += 1;
    failureMessage = "Authentication failed (" + failedAttempts + ")";
    runWake();
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured)
      return;
    if (fingerprintPam.active || fingerprintAuthenticating)
      return;
    fingerprintAuthenticating = true;
    if (!fingerprintPam.start()) {
      fingerprintAuthenticating = false;
    }
  }

  function handleFingerprintFinished(result) {
    fingerprintAuthenticating = false;
    if (!lockRequested)
      return;
    if (result === PamResult.Success) {
      finishUnlock();
    } else if (fingerprintConfigured) {
      fingerprintRetryTimer.restart();
    }
  }

  function generateBlurredBackground(sourcePath) {
    if (!sourcePath) {
      root.blurredBackgroundReady = true;
      return;
    }
    if (sourcePath === root.blurredSourcePath && root.blurredBackgroundReady)
      return;
    if (blurProc.running)
      return;
    blurProc.pendingSource = sourcePath;
    blurProc.command = [
      "magick", sourcePath,
      "-resize", "50%",
      "-blur", "0x24",
      "-brightness-contrast", "0x-12",
      root.blurredBackgroundPath
    ];
    blurWatchdog.restart();
    blurProc.running = true;
  }

  Timer {
    id: blurWatchdog
    interval: 4000
    repeat: false
    onTriggered: {
      if (blurProc.running)
        root.killProc(blurProc);
    }
  }

  Process {
    id: blurProc
    property string pendingSource: ""
    onExited: function (exitCode) {
      blurWatchdog.stop();
      if (exitCode === 0)
        root.blurredSourcePath = blurProc.pendingSource;
      else
        console.warn("bibek.lock: blur generation failed for", blurProc.pendingSource);
      // Fail open either way — never let a broken/slow blur step block
      // an actual lock from ever becoming ready.
      root.blurredBackgroundVersion += 1;
      root.blurredBackgroundReady = true;
    }
  }

  Process {
    id: blurredDirProc
    command: ["mkdir", "-p", root.blurredDir]
  }

  function showTransitionOverlay() {
    if (!root.lockRequested)
      return;
    root.transitionOverlayVisible = true;
    root.transitionContentActive = true;
    // Explicit capture request each time you actually lock — captureSource
    // itself never changes (see transitionCapture), so without this call
    // every lock after the first would keep showing whatever was captured
    // at the very first lock of the session.
    Qt.callLater(function () {
      transitionCapture.captureFrame();
      // hasContent can already be true from an earlier capture and does
      // NOT reliably toggle back through false on a fresh captureFrame()
      // call — confirmed empirically, onHasContentChanged simply never
      // fired again after the first-ever capture at shell startup, so
      // every lock after that one silently fell through its watchdog.
      // Don't gate on that signal; just give the capture (measured ~60ms)
      // a fixed, generous window and proceed regardless.
      transitionCaptureSettleTimer.restart();
    });
  }

  Timer {
    id: transitionCaptureSettleTimer
    interval: 150 // measured ~60ms; generous margin
    repeat: false
    onTriggered: root.onTransitionCaptureReady()
  }

  function onTransitionCaptureReady() {
    if (!root.lockRequested || root.transitionCrossfadeTrigger)
      return;
    root.transitionCrossfadeTrigger = true;
    transitionCrossfadeCompleteTimer.restart();
  }

  // ext-session-lock surfaces render above every layer-shell surface
  // unconditionally, by protocol — our overlay cannot stay "on top" once
  // the real surface maps, no matter what layer/z it requests. So the real
  // surface must not map until the overlay's own crossfade has *finished*;
  // mapping it mid-animation means the real surface jumps to the top and
  // cuts the crossfade off, showing its own black start underneath it.
  Timer {
    id: transitionCrossfadeCompleteTimer
    interval: 480 // matches the crossfade's 450ms duration + a small buffer
    repeat: false
    onTriggered: {
      if (!root.lockRequested)
        return;
      root.awaitBackgroundThenLock();
    }
  }

  // Content off, but the window itself stays mapped — see
  // transitionContentActive's comment for why. Used once the lock-entrance
  // crossfade has handed off to the real secure surface.
  function pauseTransitionOverlay() {
    root.transitionContentActive = false;
    root.transitionCrossfadeTrigger = false;
  }

  // Full teardown, window included — only used once actually unlocked, at
  // the very end of the unlock transition.
  function hideTransitionOverlay() {
    root.transitionOverlayVisible = false;
    root.transitionContentActive = false;
    root.transitionCrossfadeTrigger = false;
    root.unlockCrossfadeTrigger = false;
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure);
      if (secure) {
        root.pendingSessionLock = false;
        sessionLockStabilizeTimer.stop();
        pendingSessionLockTimer.stop();
        root.startFingerprint();
        // The real secure surface is now showing equivalent content
        // underneath — safe to pause the transition overlay. Window stays
        // mapped (pauseTransitionOverlay, not hideTransitionOverlay) so
        // it's already warm if this same lock session ends in an unlock.
        root.pauseTransitionOverlay();
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked);
      if (locked) {
        root.pendingSessionLock = false;
        sessionLockStabilizeTimer.stop();
        pendingSessionLockTimer.stop();
      }
      if (!locked && root.lockRequested) {
        root.lockRequested = false;
        root.pendingSessionLock = false;
        sessionLockStabilizeTimer.stop();
        pendingSessionLockTimer.stop();
        root.resetAuthenticationState();
        root.runWake();
      }
    }

    WlSessionLockSurface {
      id: lockSurface
      color: Color.background

      LockView {
        id: lockView
        anchors.fill: parent
        blurredBackgroundPath: root.blurredBackgroundPath
        blurredBackgroundVersion: root.blurredBackgroundVersion
        fingerprintConfigured: root.fingerprintConfigured
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        inputEnabled: root.lockRequested
        // Starts decoding at lockRequested (top of the stabilize window),
        // not at locked (after the surface maps) — gives the image the
        // whole pre-map window to be ready instead of starting cold.
        loadBackground: root.locked || root.lockRequested
        passwordText: root.enteredPassword
        userName: root.userName
        timeFormat: root.timeFormat
        dateFormat: root.dateFormat
        onPasswordTextEdited: function (password) {
          root.enteredPassword = password;
        }
        onSubmitPassword: function (password) {
          root.submitPassword(password);
        }
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
        onSleepRequested: root.runBlank()
        onShutdownRequested: root.requestShutdown()
        onRebootRequested: root.requestReboot()
        onSuspendRequested: root.requestSuspend()
      }
    }
  }

  PanelWindow {
    id: previewWindow
    visible: root.previewVisible
    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      blurredBackgroundPath: root.blurredBackgroundPath
      blurredBackgroundVersion: root.blurredBackgroundVersion
      fingerprintConfigured: root.fingerprintConfigured
      authenticatingPassword: false
      failureMessage: ""
      failedAttempts: 0
      inputEnabled: false
      loadBackground: root.previewVisible
      passwordText: ""
      userName: root.userName
      timeFormat: root.timeFormat
      dateFormat: root.dateFormat
      onWakeRequested: root.runWake()
      onSleepRequested: root.runBlank()
      onShutdownRequested: root.requestShutdown()
      onRebootRequested: root.requestReboot()
      onSuspendRequested: root.requestSuspend()
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.previewVisible = false
    }
  }

  // Lock-transition crossfade overlay. Shows a live-desktop capture
  // (pixel-identical to what's already on screen — imperceptible to show),
  // then crossfades it out over the same blurred-lock content the real
  // surface will show, while that real surface maps underneath. Stays
  // mapped (visible) continuously once first shown for the whole lock
  // session — only transitionContentActive toggles per phase — see the
  // comment on that property. WlrKeyboardFocus only goes Exclusive, and the
  // input-swallowing MouseArea only engages, while actually transitioning;
  // otherwise this window sits inertly mapped, granting focus/input to
  // whatever should actually have it.
  PanelWindow {
    id: transitionWindow
    visible: root.transitionOverlayVisible
    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }
    color: "transparent"
    WlrLayershell.namespace: "archer-lock-transition"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.transitionContentActive ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Everything visible lives under one opacity gate: the window itself
    // stays mapped for the whole lock session (see the comment above), but
    // should show and composite NOTHING while merely sitting there idle
    // between the lock-entrance finishing and an unlock actually starting.
    Item {
      anchors.fill: parent
      opacity: root.transitionContentActive ? 1 : 0

      // Target state, underneath — identical component to the real lock.
      LockView {
        anchors.fill: parent
        blurredBackgroundPath: root.blurredBackgroundPath
        blurredBackgroundVersion: root.blurredBackgroundVersion
        fingerprintConfigured: root.fingerprintConfigured
        authenticatingPassword: false
        failureMessage: ""
        failedAttempts: 0
        inputEnabled: false
        loadBackground: root.transitionOverlayVisible
        passwordText: ""
        userName: root.userName
        timeFormat: root.timeFormat
        dateFormat: root.dateFormat
      }

      // Sharp live-desktop snapshot, on top — crossfades out to reveal the
      // blurred lock content underneath. live:false means a single
      // capture, not a continuous feed — nothing new can appear in it
      // after the one frame lands, unlike a "blur the live desktop behind
      // a transparent surface" approach, which would keep exposing
      // real-time content.
      ScreencopyView {
        id: transitionCapture
        anchors.fill: parent
        // Deliberately NOT gated on transitionOverlayVisible: that would
        // null captureSource on every hide, which counts as "changed" and
        // forces a re-capture next time it's set — destroying the frame
        // before the unlock path ever gets to reuse it. Kept permanently
        // stable instead; showTransitionOverlay() calls captureFrame()
        // explicitly to force a fresh grab each time you actually lock.
        captureSource: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
        live: false
        opacity: root.transitionCrossfadeTrigger ? 0 : 1
        Behavior on opacity {
          NumberAnimation { duration: 450; easing.type: Easing.OutCubic }
        }
        // Redundant with transitionCaptureSettleTimer, kept as a harmless
        // fast-path for whenever this signal does fire correctly.
        onHasContentChanged: {
          if (hasContent)
            root.onTransitionCaptureReady();
        }
      }

      // Covers only the brief (~60ms measured) gap before the capture
      // above has its first frame — same Color.background the real lock
      // surface starts from, so there's no color mismatch. Gone as soon
      // as hasContent is true, handing off to the capture above it.
      Rectangle {
        anchors.fill: parent
        color: Color.background
        visible: !transitionCapture.hasContent
      }

      // Unlock direction, on top of everything above: shows the current
      // lock appearance, fading away to reveal transitionCapture's old
      // frame underneath (not a fresh one — see unlockTransitionActive's
      // comment).
      LockView {
        id: unlockFadeView
        anchors.fill: parent
        z: 10
        visible: root.unlockTransitionActive
        blurredBackgroundPath: root.blurredBackgroundPath
        blurredBackgroundVersion: root.blurredBackgroundVersion
        fingerprintConfigured: root.fingerprintConfigured
        authenticatingPassword: false
        failureMessage: ""
        failedAttempts: 0
        inputEnabled: false
        loadBackground: root.unlockTransitionActive
        passwordText: ""
        userName: root.userName
        timeFormat: root.timeFormat
        dateFormat: root.dateFormat
        opacity: root.unlockCrossfadeTrigger ? 0 : 1
        Behavior on opacity {
          // Shorter than the lock-entrance's 450ms — see unlockOverlayDropTimer.
          NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
        }
      }
    }

    // Not yet protocol-secure, so input must be swallowed here explicitly —
    // but only while actually transitioning; otherwise this window sits
    // mapped-but-inert and must not eat clicks meant for the real desktop
    // or the real secure surface.
    MouseArea {
      anchors.fill: parent
      enabled: root.transitionContentActive
      hoverEnabled: true
      acceptedButtons: Qt.AllButtons
      onClicked: {}
      onPositionChanged: {}
      onWheel: function (wheel) {
        wheel.accepted = true;
      }
    }
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function (result) {
      root.authenticatingPassword = false;
      root.pendingPassword = "";
      if (!root.lockRequested)
        return;
      if (result === PamResult.Success)
        root.finishUnlock();
      else
        root.handlePasswordFailure();
    }

    onError: function (error) {
      root.handlePasswordFailure();
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    onCompleted: function (result) {
      root.handleFingerprintFinished(result);
    }

    onError: function (error) {
      root.fingerprintAuthenticating = false;
      if (root.lockRequested && root.fingerprintConfigured)
        fingerprintRetryTimer.restart();
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: 250
    repeat: false
    onTriggered: root.startFingerprint()
  }

  Timer {
    id: backgroundWatchdog
    interval: root.helperTimeoutMs
    repeat: false
    onTriggered: {
      if (backgroundProc.running) {
        backgroundProc.timedOut = true;
        backgroundProc.collected = "";
        backgroundProc.collectedBytes = 0;
        root.killProc(backgroundProc);
      }
    }
  }

  Process {
    id: backgroundProc
    property string collected: ""
    property int collectedBytes: 0
    property bool overflowed: false
    property bool timedOut: false
    stdout: SplitParser {
      onRead: function (data) {
        if (backgroundProc.overflowed || backgroundProc.timedOut)
          return;
        var chunk = String(data + "\n");
        if (backgroundProc.collectedBytes + chunk.length > root.maxHelperBytes) {
          backgroundProc.overflowed = true;
          backgroundProc.collected = "";
          backgroundProc.collectedBytes = 0;
          root.killProc(backgroundProc);
          return;
        }
        backgroundProc.collected += chunk;
        backgroundProc.collectedBytes += chunk.length;
      }
    }
    stderr: SplitParser {
      onRead: function (data) {
        if (backgroundProc.overflowed || backgroundProc.timedOut)
          return;
        backgroundProc.collectedBytes += String(data + "\n").length;
        if (backgroundProc.collectedBytes > root.maxHelperBytes) {
          backgroundProc.overflowed = true;
          backgroundProc.collected = "";
          backgroundProc.collectedBytes = 0;
          root.killProc(backgroundProc);
        }
      }
    }
    onExited: function (exitCode) {
      backgroundWatchdog.stop();
      var failed = backgroundProc.overflowed || backgroundProc.timedOut;
      var output = String(backgroundProc.collected);
      backgroundProc.collected = "";
      backgroundProc.collectedBytes = 0;
      backgroundProc.overflowed = false;
      backgroundProc.timedOut = false;
      var next = (!failed && exitCode === 0) ? root.acceptBackground(output) : "";
      if (next !== "" && next !== root.backgroundPath) {
        root.backgroundPath = next;
        root.backgroundVersion += 1;
      } else if (next === "" && root.backgroundPath !== "") {
        root.backgroundPath = "";
        root.backgroundVersion += 1;
      }
      root.backgroundResolved = true;
      if (next !== root.blurredSourcePath)
        root.blurredBackgroundReady = false;
      root.generateBlurredBackground(next);
    }
  }

  Timer {
    id: fingerprintWatchdog
    interval: root.helperTimeoutMs
    repeat: false
    onTriggered: {
      if (fingerprintListProc.running) {
        fingerprintListProc.timedOut = true;
        fingerprintListProc.collected = "";
        fingerprintListProc.collectedBytes = 0;
        root.killProc(fingerprintListProc);
        root.setFingerprintConfigured(false);
      }
    }
  }

  Process {
    id: fingerprintListProc
    clearEnvironment: true
    environment: ({
        "PATH": root.fixedPath
      })
    property string collected: ""
    property int collectedBytes: 0
    property bool overflowed: false
    property bool timedOut: false
    stdout: SplitParser {
      onRead: function (data) {
        if (fingerprintListProc.overflowed || fingerprintListProc.timedOut)
          return;
        var chunk = String(data + "\n");
        if (fingerprintListProc.collectedBytes + chunk.length > root.maxHelperBytes) {
          fingerprintListProc.overflowed = true;
          fingerprintListProc.collected = "";
          fingerprintListProc.collectedBytes = 0;
          root.killProc(fingerprintListProc);
          return;
        }
        fingerprintListProc.collected += chunk;
        fingerprintListProc.collectedBytes += chunk.length;
      }
    }
    stderr: SplitParser {
      onRead: function (data) {
        if (fingerprintListProc.overflowed || fingerprintListProc.timedOut)
          return;
        fingerprintListProc.collectedBytes += String(data + "\n").length;
        if (fingerprintListProc.collectedBytes > root.maxHelperBytes) {
          fingerprintListProc.overflowed = true;
          fingerprintListProc.collected = "";
          fingerprintListProc.collectedBytes = 0;
          root.killProc(fingerprintListProc);
        }
      }
    }
    onExited: function (exitCode) {
      fingerprintWatchdog.stop();
      var failed = fingerprintListProc.overflowed || fingerprintListProc.timedOut;
      var output = String(fingerprintListProc.collected);
      fingerprintListProc.collected = "";
      fingerprintListProc.collectedBytes = 0;
      fingerprintListProc.overflowed = false;
      fingerprintListProc.timedOut = false;
      var enrolled = !failed && exitCode === 0 && output.toLowerCase().indexOf("finger") !== -1;
      root.setFingerprintConfigured(root.fingerprintPamFile && enrolled);
    }
  }

  Timer {
    id: strandedWatchdog
    interval: root.helperTimeoutMs
    repeat: false
    onTriggered: {
      if (strandedLockCheckProc.running) {
        root.killProc(strandedLockCheckProc);
        root.strandedLockResolved = true;
      }
    }
  }

  Process {
    id: strandedLockCheckProc
    command: [root.sessionLockedBin]
    clearEnvironment: true
    environment: ({
        "PATH": root.fixedPath,
        "HYPRLAND_INSTANCE_SIGNATURE": null,
        "XDG_RUNTIME_DIR": null
      })
    stderr: SplitParser {
      onRead: function (data) {
        strandedLockCheckProc.collectedBytes += String(data + "\n").length;
        if (strandedLockCheckProc.collectedBytes > root.maxHelperBytes)
          root.killProc(strandedLockCheckProc);
      }
    }
    property int collectedBytes: 0
    onExited: function (exitCode) {
      strandedWatchdog.stop();
      strandedLockCheckProc.collectedBytes = 0;
      if (exitCode === 2)
        return;
      root.strandedLockResolved = true;
      root.strandedLock = exitCode === 0 && !root.locked && !root.lockRequested;
      root.recoverStrandedLock();
    }
  }

  Timer {
    id: wakeWatchdog
    interval: root.wakeTimeoutMs
    repeat: false
    onTriggered: {
      if (wakeProcess.running)
        root.killProc(wakeProcess);
    }
  }

  Process {
    id: wakeProcess
    command: [root.wakeBin]
    clearEnvironment: true
    environment: ({
        "PATH": root.fixedPath,
        "HYPRLAND_INSTANCE_SIGNATURE": null,
        "XDG_RUNTIME_DIR": null
      })
    stderr: SplitParser {
      onRead: function (data) {
        wakeProcess.collectedBytes += String(data + "\n").length;
        if (wakeProcess.collectedBytes > root.maxHelperBytes)
          root.killProc(wakeProcess);
      }
    }
    property int collectedBytes: 0
    onExited: {
      wakeWatchdog.stop();
      wakeProcess.collectedBytes = 0;
    }
  }

  Timer {
    id: blankWatchdog
    interval: root.wakeTimeoutMs
    repeat: false
    onTriggered: {
      if (blankKeyboardProc.running)
        root.killProc(blankKeyboardProc);
      if (blankDisplayProc.running)
        root.killProc(blankDisplayProc);
    }
  }

  Process {
    id: blankKeyboardProc
    command: [root.brightKeyboardBin, "off"]
    clearEnvironment: true
    environment: ({
        "PATH": root.fixedPath,
        "HYPRLAND_INSTANCE_SIGNATURE": null,
        "XDG_RUNTIME_DIR": null
      })
    stderr: SplitParser {
      onRead: function (data) {
        blankKeyboardProc.collectedBytes += String(data + "\n").length;
        if (blankKeyboardProc.collectedBytes > root.maxHelperBytes)
          root.killProc(blankKeyboardProc);
      }
    }
    property int collectedBytes: 0
    onExited: {
      blankKeyboardProc.collectedBytes = 0;
      if (!blankKeyboardProc.running && !blankDisplayProc.running)
        blankWatchdog.stop();
    }
  }

  Process {
    id: blankDisplayProc
    command: [root.brightDisplayBin, "off"]
    clearEnvironment: true
    environment: ({
        "PATH": root.fixedPath,
        "HYPRLAND_INSTANCE_SIGNATURE": null,
        "XDG_RUNTIME_DIR": null
      })
    stderr: SplitParser {
      onRead: function (data) {
        blankDisplayProc.collectedBytes += String(data + "\n").length;
        if (blankDisplayProc.collectedBytes > root.maxHelperBytes)
          root.killProc(blankDisplayProc);
      }
    }
    property int collectedBytes: 0
    onExited: {
      blankDisplayProc.collectedBytes = 0;
      if (!blankKeyboardProc.running && !blankDisplayProc.running)
        blankWatchdog.stop();
    }
  }

  Timer {
    id: powerWatchdog
    interval: 30000
    repeat: false
    onTriggered: {
      if (powerProc.running)
        root.killProc(powerProc);
    }
  }

  Process {
    id: powerProc
    clearEnvironment: true
    environment: ({
        "PATH": root.fixedPath
      })
    stderr: SplitParser {
      onRead: function (data) {
        powerProc.collectedBytes += String(data + "\n").length;
        if (powerProc.collectedBytes > root.maxHelperBytes)
          root.killProc(powerProc);
      }
    }
    property int collectedBytes: 0
    onExited: {
      powerWatchdog.stop();
      powerProc.collectedBytes = 0;
    }
  }

  Timer {
    id: idleBlankTimer
    interval: 5000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer();
        return;
      }
      if (root.lockRequested && !root.authenticatingPassword)
        root.runBlank();
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved)
        remaining = budget;
    }

    onTriggered: {
      remaining -= 1;
      root.checkStrandedLock();
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.requestSessionLock();
      strandedLockRetryTimer.rearm();
      root.checkStrandedLock();
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested)
      return;
    if (authenticatingPassword)
      idleBlankTimer.stop();
    else
      armBlankTimer();
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  FileView {
    path: root.fingerprintPamPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.fingerprintPamFile = true;
      root.refreshFingerprintStatus();
    }
    onLoadFailed: {
      root.fingerprintPamFile = false;
      root.setFingerprintConfigured(false);
    }
    onFileChanged: reload()
  }

  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured)
      return;
    strandedLock = false;
    strandedLockResolved = false;
    strandedLockRetryTimer.rearm();
    checkStrandedLock();
  }

  Component.onCompleted: {
    blurredDirProc.running = true;
    refreshBackground();
    refreshFingerprintStatus();
    checkStrandedLock();
    root.loadConfig();
  }

  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured)
        return "missing-pam";
      if (!root.locked && !root.beginLock())
        return "failed";
      return "ok";
    }

    function isLocked(): string {
      return root.locked ? "true" : "false";
    }

    function status(): string {
      return JSON.stringify({
          "locked": root.locked,
          "requested": root.lockRequested,
          "pending": root.pendingSessionLock,
          "sessionLocked": sessionLock.locked,
          "secure": sessionLock.secure,
          "realScreens": root.realScreenCount(),
          "passwordPam": root.passwordPamConfigured,
          "fingerprint": root.fingerprintConfigured,
          "authenticating": root.authenticating,
          "lastEvent": root.lastEvent,
          "lastEventAt": root.lastEventAt
        });
    }

    function preview(): string {
      root.refreshBackground();
      root.refreshFingerprintStatus();
      root.previewVisible = true;
      return "ok";
    }

    function hidePreview(): string {
      root.previewVisible = false;
      return "ok";
    }
  }
}
