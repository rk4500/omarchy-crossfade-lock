import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

Item {
  id: root

  // Already-blurred file, baked once by Service.qml's `magick` step — no
  // live GPU blur here. An ext-session-lock surface gets zero render
  // frames while unmapped, so a live shader can't converge before the
  // surface is shown no matter how it's gated; a plain pre-blurred image
  // just displays, no convergence to wait for.
  property string blurredBackgroundPath: ""
  property int blurredBackgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property string passwordText: ""
  property bool syncingPasswordText: false
  property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || "User"
  property string timeFormat: "hh:mm AP"
  property string dateFormat: "dddd, MMMM d"
  property int focusIndex: 0

  readonly property string placeholderText: "Enter Password"
  readonly property int fieldWidth: 381
  readonly property int fieldHeight: 67
  readonly property int outlineThickness: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.33)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.19)
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12) : 0
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0 ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth) : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState ? Border.surfaceSpec("lock", "border-error", Color.lock.borderError, root.outlineThickness, "border-alpha") : (passwordInput.activeFocus ? Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, root.outlineThickness, "border-alpha") : Border.surfaceSpec("lock", "border", Color.lock.border, 1, "border-alpha"))

  property string currentTimeString: ""
  property string currentDateString: ""

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested
  signal wakeRequested
  signal sleepRequested
  signal shutdownRequested
  signal rebootRequested
  signal suspendRequested

  function moveFocus(delta) {
    var list = [0, 1, 2, 3];
    var currentPos = list.indexOf(focusIndex);
    if (currentPos === -1)
      currentPos = 0;
    var nextPos = (currentPos + delta + list.length) % list.length;
    focusIndex = list[nextPos];
    if (focusIndex === 0) {
      forcePasswordFocus();
    }
  }

  function activateFocused() {
    if (focusIndex === 0) {
      var submitted = root.passwordText;
      root.passwordTextEdited("");
      if (submitted.length > 0)
        root.submitPassword(submitted);
    } else if (focusIndex === 1) {
      root.suspendRequested();
    } else if (focusIndex === 2) {
      root.shutdownRequested();
    } else if (focusIndex === 3) {
      root.rebootRequested();
    }
  }

  function fileUrl(path) {
    if (!path)
      return "";
    var encoded = String(path).split("/").map(encodeURIComponent).join("/");
    return "file://" + encoded + "?v=" + blurredBackgroundVersion;
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus();
  }

  function clearPassword() {
    passwordTextEdited("");
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText)
      return;
    syncingPasswordText = true;
    passwordInput.text = passwordText;
    syncingPasswordText = false;
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled)
      Qt.callLater(forcePasswordFocus);
  }
  Component.onCompleted: {
    syncPasswordText();
    if (inputEnabled)
      Qt.callLater(forcePasswordFocus);
  }

  Component.onDestruction: {
    dateTimeTimer.stop();
  }

  Timer {
    id: dateTimeTimer
    interval: 1000
    running: root.visible
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var now = new Date();
      currentTimeString = Qt.formatDateTime(now, root.timeFormat);
      currentDateString = Qt.formatDateTime(now, root.dateFormat);
    }
  }

  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background
    focus: true

    Keys.onPressed: function (event) {
      root.wakeRequested();
      if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down) {
        root.moveFocus(1);
        event.accepted = true;
      } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Up) {
        root.moveFocus(-1);
        event.accepted = true;
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        root.activateFocused();
        event.accepted = true;
      } else if (event.key === Qt.Key_Escape) {
        root.focusIndex = 0;
        root.forcePasswordFocus();
        event.accepted = true;
      } else if (event.text.length > 0) {
        root.focusIndex = 0;
        root.forcePasswordFocus();
      }
    }

    // No fade/reveal animation here by design: the lock-transition overlay
    // in Service.qml owns the entire reveal (crossfading a live-desktop
    // grab to this exact content) before this real surface ever maps, so
    // by the time this is visible it should already match the overlay's
    // final frame exactly — showing it instantly is the point.
    Item {
      id: contentLayer
      anchors.fill: parent

      Image {
        id: wallpaper
        anchors.fill: parent
        source: root.loadBackground ? root.fileUrl(root.blurredBackgroundPath) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: width
        sourceSize.height: height
      }

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.35)
      }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: {
        root.wakeRequested();
        root.forcePasswordFocus();
      }
      onPositionChanged: root.wakeRequested()
    }

    Column {
      id: timeDateColumn
      anchors.bottom: inputField.top
      anchors.bottomMargin: 48
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 6

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.currentTimeString
        color: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.heading * 3.2)
        font.weight: Font.Bold
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.currentDateString
        color: Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.heading * 1.25)
        horizontalAlignment: Text.AlignHCenter
      }
    }

    BorderSurface {
      id: inputField
      width: root.fieldWidth
      height: root.fieldHeight
      anchors.centerIn: parent
      color: Color.lock.background
      borderSpec: root.inputBorderSpec
      radius: Style.cornerRadius
      clip: true

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.topMargin: inputField.borderTop
        anchors.rightMargin: inputField.borderRight + 18 + root.fingerprintReserve
        anchors.bottomMargin: inputField.borderBottom
        anchors.leftMargin: inputField.borderLeft + 18 + root.fingerprintReserve
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword
        echoMode: TextInput.Password
        passwordCharacter: "●"
        passwordMaskDelay: 0
        color: Color.lock.text
        selectionColor: Color.lock.selection
        selectedTextColor: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
        font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
        cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
        cursorDelegate: Rectangle {
          width: 2
          color: Color.lock.text
          visible: passwordInput.cursorVisible
        }

        onTextChanged: {
          if (!root.syncingPasswordText)
            root.passwordTextEdited(text);
          if (text.length > 0) {
            root.wakeRequested();
            root.focusIndex = 0;
          }
          if (text.length > 0 && root.failureMessage.length > 0)
            root.clearFailureRequested();
        }

        onAccepted: {
          var submitted = root.passwordText;
          root.passwordTextEdited("");
          if (submitted.length > 0)
            root.submitPassword(submitted);
        }

        Keys.onPressed: function (event) {
          root.wakeRequested();
          if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down) {
            root.moveFocus(1);
            event.accepted = true;
          } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Up) {
            root.moveFocus(-1);
            event.accepted = true;
          } else if (event.key === Qt.Key_Escape) {
            root.passwordTextEdited("");
            event.accepted = true;
          } else if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U) {
            root.passwordTextEdited("");
            event.accepted = true;
          }
        }
      }

      Text {
        anchors.fill: passwordInput
        text: root.authenticatingPassword ? "Checking…" : (root.failureMessage.length > 0 ? root.failureMessage : root.placeholderText)
        visible: passwordInput.text.length === 0
        color: root.authenticatingPassword ? Color.lock.text : (root.failureMessage.length > 0 ? Color.lock.textError : Color.lock.placeholder)
        font.family: Style.font.family
        font.pixelSize: root.fieldFontSize
        font.italic: !root.authenticatingPassword && root.failureMessage.length > 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      Text {
        id: fingerprintIcon
        objectName: "fingerprintIndicator"
        anchors.right: parent.right
        anchors.rightMargin: inputField.borderRight + 18
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: "󰈷"
        color: Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }

    Row {
      id: powerControls
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 40
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 16

      Button {
        id: sleepButton
        text: "Sleep"
        iconText: "󰤄"
        bordered: true
        horizontalPadding: 20
        verticalPadding: 10
        hasCursor: root.focusIndex === 1
        onClicked: root.suspendRequested()
      }

      Button {
        id: shutdownButton
        text: "Shutdown"
        iconText: "󰐥"
        bordered: true
        horizontalPadding: 20
        verticalPadding: 10
        hasCursor: root.focusIndex === 2
        onClicked: root.shutdownRequested()
      }

      Button {
        id: restartButton
        text: "Restart"
        iconText: "󰜉"
        bordered: true
        horizontalPadding: 20
        verticalPadding: 10
        hasCursor: root.focusIndex === 3
        onClicked: root.rebootRequested()
      }
    }
    }
  }
}
