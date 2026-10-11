package com.openlattice.chronicle.organizations

public open class ChronicleOrganizationService() {
    companion object {
        private val AUTHORIZE_NEW_ORGANIZATION_SQL = "SELECT set_config('app.authorized_orgs', ?, true)"
        // ruleid: rls-context-single-owner
        private val COPIED_ORGANIZATION_CONTEXT_SQL = "SELECT set_config('app.authorized_orgs', ?, true)"
    }
}

class CopiedOrganizationOwner {
    companion object {
        // ruleid: rls-context-single-owner
        private val AUTHORIZE_NEW_ORGANIZATION_SQL = "SELECT set_config('app.authorized_orgs', ?, true)"
    }
}
