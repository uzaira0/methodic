fun bypass() {
    // ruleid: exact-alarm-single-owner
    manager.setExact(type, trigger, pending)
    // ruleid: exact-alarm-single-owner
    manager.setExactAndAllowWhileIdle(type, trigger, pending)
    // ruleid: exact-alarm-single-owner
    manager.setAlarmClock(info, pending)
    // ruleid: exact-alarm-single-owner
    manager.canScheduleExactAlarms()
}
