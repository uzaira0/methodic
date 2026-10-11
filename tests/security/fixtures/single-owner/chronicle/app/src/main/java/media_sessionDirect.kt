fun bypass() {
    // ruleid: media-session-single-owner
    manager.getActiveSessions(component)
    // ruleid: media-session-single-owner
    manager.addOnActiveSessionsChangedListener(listener, component, handler)
}
