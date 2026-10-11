package com.openlattice.chronicle.services.delete

@Suppress("LargeClass")
public open class RestoreContinuityReconciler {
    private fun setDeletionWorkerContext(connection: Connection) {
        // ruleid: rls-context-single-owner
        connection.execute("SELECT set_config('app.current_user_id', 'chronicle-deletion-worker', true)")
    }
    fun copiedContext(connection: Connection) {
        // ruleid: rls-context-single-owner
        connection.execute("SELECT set_config('app.new_setting', 'value', true)")
        // ruleid: rls-context-single-owner
        connection.execute("SELECT SET_CONFIG ( 'app.authorized_orgs', '', false)")
        setDeletionWorkerContext(connection)
    }
}
