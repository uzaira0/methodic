fun bypass() {
    // ruleid: sensor-registration-single-owner
    manager.registerListener(listener, sensor, rate)
    // ruleid: sensor-registration-single-owner
    manager.requestTriggerSensor(listener, sensor)
}
