fun registerSystemBroadcastReceiver() {
    context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
    registerReceiver(receiver, filter)
    ContextCompat.registerReceiver(context, receiver, filter, flags)
}

fun registerPrivateReceiver() {
    context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
}
