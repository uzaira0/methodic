-- ============================================
-- Chronicle Row-Level Security (RLS) Test Script
-- ============================================
-- Run this script to verify RLS is working correctly.
-- Execute as chronicle_admin user first to set up test data,
-- then test with chronicle_app user to verify isolation.

-- ============================================
-- STEP 1: Setup (Run as chronicle_admin)
-- ============================================

-- Create test studies
INSERT INTO studies (id, title, created_at) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Study Alpha', NOW()),
    ('22222222-2222-2222-2222-222222222222', 'Study Beta', NOW()),
    ('33333333-3333-3333-3333-333333333333', 'Study Gamma', NOW())
ON CONFLICT (id) DO NOTHING;

-- Create test participants in each study
INSERT INTO participants (id, study_id, participant_id, created_at) VALUES
    ('aaaa0001-0001-0001-0001-000000000001', '11111111-1111-1111-1111-111111111111', 'P001-Alpha', NOW()),
    ('aaaa0002-0002-0002-0002-000000000002', '11111111-1111-1111-1111-111111111111', 'P002-Alpha', NOW()),
    ('bbbb0001-0001-0001-0001-000000000001', '22222222-2222-2222-2222-222222222222', 'P001-Beta', NOW()),
    ('bbbb0002-0002-0002-0002-000000000002', '22222222-2222-2222-2222-222222222222', 'P002-Beta', NOW()),
    ('cccc0001-0001-0001-0001-000000000001', '33333333-3333-3333-3333-333333333333', 'P001-Gamma', NOW())
ON CONFLICT (id) DO NOTHING;

-- ============================================
-- STEP 2: Test as Admin (should see all data)
-- ============================================

-- Set admin context
SET app.is_admin = 'true';
SET app.authorized_studies = '';
SET app.current_user_id = '00000000-0000-0000-0000-000000000000';

-- Admin should see ALL participants (5 total)
SELECT 'ADMIN TEST' as test_case, count(*) as participant_count FROM participants;
-- Expected: 5

-- ============================================
-- STEP 3: Test as User with Study Alpha access only
-- ============================================

-- Set user context - only authorized for Study Alpha
SET app.is_admin = 'false';
SET app.authorized_studies = '11111111-1111-1111-1111-111111111111';
SET app.current_user_id = 'user-alpha-researcher';

-- User should see ONLY Study Alpha participants (2 total)
SELECT 'USER_ALPHA TEST' as test_case, count(*) as participant_count FROM participants;
-- Expected: 2

SELECT 'USER_ALPHA DETAILS' as test_case, participant_id, study_id FROM participants;
-- Expected: P001-Alpha, P002-Alpha only

-- ============================================
-- STEP 4: Test as User with Studies Alpha and Beta access
-- ============================================

-- Set user context - authorized for both Study Alpha and Beta
SET app.is_admin = 'false';
SET app.authorized_studies = '11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222';
SET app.current_user_id = 'user-multi-study';

-- User should see Study Alpha + Beta participants (4 total)
SELECT 'USER_MULTI TEST' as test_case, count(*) as participant_count FROM participants;
-- Expected: 4

-- ============================================
-- STEP 5: Test as User with NO study access
-- ============================================

-- Set user context - no authorized studies
SET app.is_admin = 'false';
SET app.authorized_studies = '';
SET app.current_user_id = 'user-no-access';

-- User should see NO participants (0 total)
SELECT 'USER_NO_ACCESS TEST' as test_case, count(*) as participant_count FROM participants;
-- Expected: 0

-- ============================================
-- STEP 6: Test INSERT restrictions
-- ============================================

-- User with Study Alpha access tries to insert into Study Beta (should fail or be invisible)
SET app.is_admin = 'false';
SET app.authorized_studies = '11111111-1111-1111-1111-111111111111';

-- This INSERT should either fail or the row should not be visible to this user
-- depending on your RLS policy configuration
INSERT INTO participants (id, study_id, participant_id, created_at) VALUES
    ('test0001-0001-0001-0001-000000000001', '22222222-2222-2222-2222-222222222222', 'UNAUTHORIZED-INSERT', NOW())
ON CONFLICT (id) DO NOTHING;

-- Verify the unauthorized insert is not visible
SELECT 'UNAUTHORIZED_INSERT TEST' as test_case, count(*) as found
FROM participants WHERE participant_id = 'UNAUTHORIZED-INSERT';
-- Expected: 0 (not visible to this user)

-- ============================================
-- STEP 7: Cleanup (Run as chronicle_admin)
-- ============================================

SET app.is_admin = 'true';

-- Remove test data
DELETE FROM participants WHERE study_id IN (
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333'
);

DELETE FROM studies WHERE id IN (
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333'
);

-- ============================================
-- VERIFICATION SUMMARY
-- ============================================
-- If RLS is working correctly:
--   - Admin sees all 5 participants
--   - User with Alpha access sees 2 participants
--   - User with Alpha+Beta access sees 4 participants
--   - User with no access sees 0 participants
--   - Unauthorized inserts are not visible to restricted users
