fun owner() {
    manager.registerListener(listener, sensor, rate)
    manager.requestTriggerSensor(listener, sensor)
}
