-- =============================================================================
-- Chronicle Database Role Initialization Script
-- =============================================================================
-- This script creates the database roles required for Row-Level Security (RLS).
--
-- Roles:
--   chronicle_app   - Application user with RLS enforced
--   chronicle_admin - Admin user that bypasses RLS for maintenance
--
-- Usage:
--   1. Run this script as the PostgreSQL superuser (postgres)
--   2. Configure your application to use chronicle_app for normal operations
--   3. Use chronicle_admin only for migrations and maintenance
--
-- Security:
--   - chronicle_app has RLS enforced (FORCE ROW LEVEL SECURITY)
--   - chronicle_admin bypasses RLS (BYPASSRLS attribute)
--   - Passwords should be set via environment variables or secrets management
-- =============================================================================

-- Create application role (RLS enforced)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'chronicle_app') THEN
        CREATE ROLE chronicle_app WITH
            LOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOINHERIT
            NOREPLICATION
            CONNECTION LIMIT -1;

        RAISE NOTICE 'Created role: chronicle_app';
    ELSE
        RAISE NOTICE 'Role chronicle_app already exists';
    END IF;
END $$;

-- Create admin role (bypasses RLS)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'chronicle_admin') THEN
        CREATE ROLE chronicle_admin WITH
            LOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOINHERIT
            NOREPLICATION
            BYPASSRLS
            CONNECTION LIMIT 5;

        RAISE NOTICE 'Created role: chronicle_admin';
    ELSE
        RAISE NOTICE 'Role chronicle_admin already exists';
    END IF;
END $$;

-- Grant schema usage to both roles
GRANT USAGE ON SCHEMA public TO chronicle_app;
GRANT USAGE ON SCHEMA public TO chronicle_admin;

-- Grant table permissions to application role
-- chronicle_app can SELECT, INSERT, UPDATE, DELETE on all tables
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO chronicle_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO chronicle_app;

-- Grant full permissions to admin role (including TRUNCATE for maintenance)
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO chronicle_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO chronicle_admin;

-- Set default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO chronicle_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO chronicle_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL PRIVILEGES ON TABLES TO chronicle_admin;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL PRIVILEGES ON SEQUENCES TO chronicle_admin;

-- Grant execute on functions (needed for RLS helper function)
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO chronicle_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO chronicle_admin;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO chronicle_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO chronicle_admin;

-- =============================================================================
-- Password Configuration
-- =============================================================================
-- Set passwords for the roles. In production, use environment variables or
-- secrets management instead of hardcoded passwords.
--
-- Example (run separately with actual passwords):
--   ALTER ROLE chronicle_app PASSWORD 'your-secure-app-password';
--   ALTER ROLE chronicle_admin PASSWORD 'your-secure-admin-password';
-- =============================================================================

-- Placeholder for password setting (uncomment and modify in deployment)
-- ALTER ROLE chronicle_app PASSWORD :'CHRONICLE_APP_PASSWORD';
-- ALTER ROLE chronicle_admin PASSWORD :'CHRONICLE_ADMIN_PASSWORD';

-- =============================================================================
-- Verification Queries (optional - uncomment to verify setup)
-- =============================================================================
-- SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname LIKE 'chronicle_%';
-- SELECT * FROM information_schema.role_table_grants WHERE grantee LIKE 'chronicle_%';
