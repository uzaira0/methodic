package fixtures

// ruleid: room-migrations-single-owner
import com.openlattice.chronicle.storage.MIGRATION_23_24

class SensitiveStorageInvariantTest {
    fun canonicalMigrationString() {
        assertTrue(database.contains("MIGRATION_27_28"))
        // ruleid: room-migrations-single-owner
        MIGRATION_23_24.migrate(database)
    }
}

class ChronicleDb {
    companion object {
        // ruleid: room-migrations-single-owner
        val ALL_MIGRATIONS = arrayOf(MIGRATION_23_24)
    }
}
