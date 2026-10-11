package fixtures;

class CopiedMigrations {
    static final Migration MIGRATION_23_24 = new Migration(23, 24);
    static final Migration MIGRATION_24_25 = new Migration(24, 25);
    // ruleid: room-migrations-single-owner-java
    static final Migration SECOND_OWNER = MIGRATION_23_24;
    // ruleid: room-migrations-single-owner-java
    static final Migration MIGRATION_25_26 = MIGRATION_24_25;
}
