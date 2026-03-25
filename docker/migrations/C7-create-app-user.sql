-- C-7: Create separate chronicle_app user for application connections.
-- The chronicle user owns all tables, so FORCE ROW LEVEL SECURITY is bypassed.
-- This script creates a non-owner user that is subject to RLS policies.
--
-- Run this manually against the database:
--   docker exec -i chronicle-postgres psql -U chronicle -d chronicle -f /migrations/C7-create-app-user.sql
--
-- After running, update docker/.env:
--   POSTGRES_APP_USER=chronicle_app
--   POSTGRES_APP_PASSWORD=<secure-random-password>
--
-- And update rhizome-docker.yaml.template to use the new user for HikariCP connections.

-- 1. Create the application user
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'chronicle_app') THEN
        CREATE ROLE chronicle_app WITH LOGIN PASSWORD 'CHANGE_ME_TO_SECURE_PASSWORD';
    END IF;
END
$$;

-- 2. Grant usage on schema
GRANT USAGE ON SCHEMA public TO chronicle_app;

-- 3. Grant DML (no DDL) on all existing tables
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO chronicle_app;

-- 4. Grant usage on sequences (needed for inserts with serial/sequence columns)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO chronicle_app;

-- 5. Set default privileges for future tables created by chronicle
ALTER DEFAULT PRIVILEGES FOR ROLE chronicle IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO chronicle_app;
ALTER DEFAULT PRIVILEGES FOR ROLE chronicle IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO chronicle_app;

-- 6. Enable FORCE ROW LEVEL SECURITY on all tables with RLS policies
-- This ensures chronicle_app is subject to RLS even though it has DML grants.
-- Note: The table owner (chronicle) is NEVER subject to FORCE RLS.
DO $$
DECLARE
    tbl RECORD;
BEGIN
    FOR tbl IN
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE schemaname = 'public'
        AND tablename IN (
            'studies', 'study_participants', 'candidates', 'devices',
            'sensor_data', 'android_sensor_data', 'chronicle_usage_events',
            'chronicle_usage_stats', 'preprocessed_usage_events',
            'questionnaire_submissions', 'time_use_diary_submissions',
            'app_usage_survey', 'participant_stats'
        )
    LOOP
        EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', tbl.schemaname, tbl.tablename);
    END LOOP;
END
$$;
