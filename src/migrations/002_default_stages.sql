CREATE TEMP TABLE migration_002_stage_less_processes (
    process_id INTEGER PRIMARY KEY
);

INSERT INTO migration_002_stage_less_processes(process_id)
SELECT process.id
FROM job_processes AS process
WHERE NOT EXISTS (
    SELECT 1
    FROM stages AS existing
    WHERE existing.process_id = process.id
);

INSERT INTO stages (
    process_id,
    name,
    position,
    status,
    started_at,
    created_at,
    updated_at
)
SELECT
    process.id,
    defaults.name,
    defaults.position,
    CASE defaults.position
        WHEN 1 THEN 'in_progress'
        ELSE 'planned'
    END,
    CASE defaults.position
        WHEN 1 THEN datetime('now')
        ELSE NULL
    END,
    datetime('now'),
    datetime('now')
FROM job_processes AS process
JOIN migration_002_stage_less_processes AS stage_less
    ON stage_less.process_id = process.id
CROSS JOIN (
    SELECT 1 AS position, 'Resume sent' AS name
    UNION ALL SELECT 2, 'Recruiter / HR interview'
    UNION ALL SELECT 3, 'Technical interview'
    UNION ALL SELECT 4, 'Technical assignment'
    UNION ALL SELECT 5, 'Cultural fit interview'
    UNION ALL SELECT 6, 'Final interview'
    UNION ALL SELECT 7, 'Offer'
) AS defaults;

UPDATE job_processes
SET current_stage_id = (
    SELECT stage.id
    FROM stages AS stage
    WHERE stage.process_id = job_processes.id
    ORDER BY stage.position, stage.id
    LIMIT 1
)
WHERE current_stage_id IS NULL
  AND id IN (
      SELECT process_id
      FROM migration_002_stage_less_processes
  );

DROP TABLE migration_002_stage_less_processes;

CREATE INDEX IF NOT EXISTS idx_notes_stage
    ON notes(stage_id, created_at);

CREATE INDEX IF NOT EXISTS idx_appointments_stage
    ON appointments(stage_id, starts_at);
