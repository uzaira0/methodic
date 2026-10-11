fun bypass() {
    // ruleid: work-stop-reason-single-owner
    worker.getStopReason()
    // ruleid: work-stop-reason-single-owner
    val reason = worker.stopReason
    // ruleid: work-stop-reason-single-owner
    val other = stopReason
}
