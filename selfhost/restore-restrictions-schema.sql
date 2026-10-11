CREATE TABLE chronicle_restore_continuity.restricted_participants (
    study_id UUID NOT NULL,
    participant_id TEXT NOT NULL,
    participation_status TEXT NOT NULL CHECK (participation_status IN ('PAUSED', 'COLLECTION_COMPLETED')),
    capture_cutoff TIMESTAMPTZ,
    PRIMARY KEY (study_id, participant_id)
);
CREATE TABLE chronicle_restore_continuity.archived_studies (
    study_id UUID PRIMARY KEY
);
