package com.openlattice.chronicle.storage

val MIGRATION_23_24 = object : Migration(23, 24) {}
val MIGRATION_24_25: Migration = object : Migration(24, 25) {}

@Database(entities = [], version = 25)
abstract class ChronicleDb : RoomDatabase() {
    companion object {
        val ALL_MIGRATIONS: Array<Migration> = arrayOf(MIGRATION_23_24, MIGRATION_24_25)
        // ruleid: room-migrations-single-owner
        val SECOND_LIST = arrayOf(MIGRATION_23_24)
    }
}

class CopiedOwner {
    companion object {
        // ruleid: room-migrations-single-owner
        val ALL_MIGRATIONS = arrayOf(MIGRATION_23_24)
    }
}

fun openDatabase() = builder.addMigrations(*ChronicleDb.ALL_MIGRATIONS)
