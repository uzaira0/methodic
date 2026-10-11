fun owner() {
    manager.getActiveSessions(component)
    manager.addOnActiveSessionsChangedListener(listener, component, handler)
}
