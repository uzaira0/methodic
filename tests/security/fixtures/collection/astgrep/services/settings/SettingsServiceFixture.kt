// Positive fixture for collection-settings-service-no-rls-context-call (catalog #12).
// A settings service calling RLSContextManager directly.
package fixtures
class StudySettingsCollectionService(private val rls: RLSContextManager) {
    fun read(connection: Connection) {
        rls.setCurrentUserContext(connection) // VIOLATION: settings service must not manage RLS
    }
}
