import QtQuick

// A damped spring for retargetable motion. Changing the target mid-flight keeps
// the current velocity, and each frame is solved exactly from the elapsed time,
// so the curve is identical at any refresh rate or after a dropped frame.
QtObject {
    id: spring

    property real target: 0
    property real value: target
    property real velocity: 0
    // Seconds per undamped oscillation: lower is snappier.
    property real response: 0.35
    // 1 settles without overshoot; lower values bounce.
    property real damping: 1
    // Settles within this distance of the target, below ten times it per second.
    property real precision: 0.05
    // While disabled, the value follows the target without animating.
    property bool enabled: true
    readonly property bool moving: clock.running

    function settle() {
        value = target;
        velocity = 0;
    }

    function advance(seconds) {
        let omega = 2 * Math.PI / response;
        let zeta = Math.min(damping, 1);
        let offset = value - target;
        let decay = Math.exp(-zeta * omega * seconds);
        let position, speed;
        if (zeta < 1) {
            let frequency = omega * Math.sqrt(1 - zeta * zeta);
            let cos = Math.cos(frequency * seconds), sin = Math.sin(frequency * seconds);
            position = decay * (offset * cos + (velocity + zeta * omega * offset) / frequency * sin);
            speed = decay * (velocity * cos - (omega * omega * offset + zeta * omega * velocity) / frequency * sin);
        } else {
            let slope = velocity + omega * offset;
            position = decay * (offset + slope * seconds);
            speed = decay * (velocity - omega * slope * seconds);
        }
        if (Math.abs(position) < precision && Math.abs(speed) < precision * 10) {
            position = 0;
            speed = 0;
        }
        velocity = speed;
        value = target + position;
    }

    onTargetChanged: if (!enabled) settle()
    onEnabledChanged: if (!enabled) settle()
    // Start at rest on the initial target (or an explicitly assigned value).
    Component.onCompleted: value = value

    property FrameAnimation clock: FrameAnimation {
        property bool started: false
        running: spring.enabled && (spring.value !== spring.target || spring.velocity !== 0)
        onRunningChanged: started = false
        // The first tick also measures the wait for a frame, e.g. while a window maps.
        onTriggered: {
            spring.advance(started ? frameTime : 0);
            started = true;
        }
    }
}
