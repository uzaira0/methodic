-- Preserve stronger terminal restrictions already present in the selected backup.
UPDATE public.study_participants target
SET participation_status = source.participation_status, updated_at = now()
FROM chronicle_restore_continuity.restricted_participants source
WHERE target.study_id = source.study_id AND target.participant_id = source.participant_id
  AND (target.participation_status IN ('ENROLLED', 'UNKNOWN')
       OR (target.participation_status = 'PAUSED' AND source.participation_status = 'COLLECTION_COMPLETED'));

UPDATE public.studies target
SET lifecycle_status = 'ARCHIVED', updated_at = now()
FROM chronicle_restore_continuity.archived_studies source
WHERE target.study_id = source.study_id AND target.lifecycle_status = 'ACTIVE';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM chronicle_restore_continuity.restricted_participants source
        JOIN public.study_participants target USING (study_id, participant_id)
        WHERE target.participation_status IN ('ENROLLED', 'UNKNOWN')
           OR (source.participation_status = 'COLLECTION_COMPLETED' AND target.participation_status = 'PAUSED')
    ) OR EXISTS (
        SELECT 1 FROM chronicle_restore_continuity.archived_studies source
        JOIN public.studies target USING (study_id)
        WHERE target.lifecycle_status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Post-restore collection restrictions could not be proven';
    END IF;
END $$;
