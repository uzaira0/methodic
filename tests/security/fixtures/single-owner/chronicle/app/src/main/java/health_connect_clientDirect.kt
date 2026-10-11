fun bypass() {
    // ruleid: health-connect-client-single-owner
    HealthConnectClient.getSdkStatus(context)
    // ruleid: health-connect-client-single-owner
    HealthConnectClient.getOrCreate(context)
}
