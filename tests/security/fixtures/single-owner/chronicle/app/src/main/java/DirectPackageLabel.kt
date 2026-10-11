fun bypass() {
    // ruleid: package-label-single-owner
    manager.getApplicationInfo(packageName, flags)
    // ruleid: package-label-single-owner
    manager.getApplicationLabel(info)
}
