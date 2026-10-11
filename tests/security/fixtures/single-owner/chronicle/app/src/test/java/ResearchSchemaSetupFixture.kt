package com.openlattice.chronicle.collection.state

import com.openlattice.chronicle.storage.MIGRATION_17_18
// ruleid: room-migrations-single-owner
import com.openlattice.chronicle.storage.MIGRATION_23_24

class StorageRefusalPersistenceTest {
    @Before fun setUp() {
        MIGRATION_17_18.migrate(database)
        // ruleid: room-migrations-single-owner
        builder.addMigrations(MIGRATION_17_18)
        // ruleid: room-migrations-single-owner
        MIGRATION_23_24.migrate(database)
        // ruleid: room-migrations-single-owner
        MIGRATION_17_18.migrate(databaseWith(arrayOf(MIGRATION_17_18)))
    }
    fun copiedMigration() {
        // ruleid: room-migrations-single-owner
        MIGRATION_17_18.migrate(database)
    }
}

class ResearchErasureRegressionTest {
    @Before fun setUp() {
        MIGRATION_17_18.migrate(database)
    }
}

class CopiedResearchSetup {
    @Before fun setUp() {
        // ruleid: room-migrations-single-owner
        MIGRATION_17_18.migrate(database)
    }
}
