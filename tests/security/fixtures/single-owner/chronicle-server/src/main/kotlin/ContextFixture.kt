package com.openlattice.chronicle.storage.rls

public open class RLSContextManager {
    companion object {
        private const val SET_RLS_CONTEXT_SQL = "SELECT set_config('app.current_user_id', ?, false)"
        private const val CLEAR_RLS_CONTEXT_SQL = "SELECT set_config('app.current_user_id', '', false)"
    }
    fun copiedSetter() {
        // ruleid: rls-context-single-owner
        execute("SELECT set_config('app.is_admin', 'true', false)")
    }
}

private object RLSConnectionSql {
    private const val SET_RLS_CONTEXT_SQL = "SELECT set_config('app.authorized_studies', ?, false)"
    private const val CLEAR_RLS_CONTEXT_SQL = "SELECT set_config('app.authorized_studies', '', false)"
}

public object RLSConnectionCustomizer {
    public const val CONNECTION_INIT_SQL: String = "SELECT set_config('app.is_admin', 'false', false)"
    public const val ADMIN_CONTEXT_SQL: String = "SELECT set_config('app.is_admin', 'true', false)"
    public const val ADMIN_TRANSACTION_CONTEXT_SQL: String = "SELECT set_config('app.is_admin', 'true', true)"
    @JvmStatic
    public fun setDeletionWorkerContext(connection: Connection, transactionLocal: Boolean) {
        connection.execute("SELECT set_config('app.current_user_id', 'worker', $transactionLocal)")
    }
    fun copiedWorkerContext(connection: Connection) {
        // ruleid: rls-context-single-owner
        connection.execute("SELECT set_config('app.current_user_id', 'worker', true)")
    }
}

fun copiedEntityTag(value: String): String {
    // ruleid: entity-tags-single-owner
    val suffix = Regex("""(?:--(?:gzip|br|zstd|deflate)|-(?:gzip|br|zstd))$""")
    // ruleid: entity-tags-single-owner
    val gzip = value.removeSuffix("--gzip")
    // ruleid: entity-tags-single-owner
    val br = value.removeSuffix("-br")
    return gzip.replace(suffix, "")
}

fun permittedEntityTag(value: String): String = normalizeEntityTag(value)
// set_config('app.comment_only', '', false) and --gzip are documentation.
