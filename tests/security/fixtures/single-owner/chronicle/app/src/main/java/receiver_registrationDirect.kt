fun bypass() {
    // ruleid: receiver-registration-single-owner
    context.registerReceiver(receiver, filter)
    // ruleid: receiver-registration-single-owner
    registerReceiver(receiver, filter)
    // ruleid: receiver-registration-single-owner
    ContextCompat.registerReceiver(context, receiver, filter, flags)
}
