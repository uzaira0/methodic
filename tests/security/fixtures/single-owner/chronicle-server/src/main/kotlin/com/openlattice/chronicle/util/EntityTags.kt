package com.openlattice.chronicle.util

private val CONTENT_CODING_SUFFIX = Regex("""(?:--(?:gzip|br|zstd|deflate)|-(?:gzip|br|zstd))$""")
fun normalizeEntityTag(value: String): String = value.replace(CONTENT_CODING_SUFFIX, "")

private object RLSConnectionSql {
    // ruleid: rls-context-single-owner
    private const val SET_RLS_CONTEXT_SQL = "SELECT set_config('app.is_admin', 'true', false)"
}
