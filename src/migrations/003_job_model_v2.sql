CREATE TABLE sources (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE,
    created_at TEXT NOT NULL
);

INSERT OR IGNORE INTO sources(name, created_at) VALUES
    ('Djinni', datetime('now')),
    ('LinkedIn', datetime('now')),
    ('DOU', datetime('now')),
    ('GolangProjects', datetime('now')),
    ('Gophers Slack', datetime('now'));

INSERT OR IGNORE INTO sources(name, created_at)
SELECT DISTINCT trim(source), datetime('now')
FROM job_processes
WHERE source IS NOT NULL AND trim(source) <> '';

ALTER TABLE job_processes ADD COLUMN source_id INTEGER REFERENCES sources(id);
ALTER TABLE job_processes ADD COLUMN company_summary TEXT;
ALTER TABLE job_processes ADD COLUMN applied_at TEXT;
ALTER TABLE job_processes ADD COLUMN interest_rating INTEGER CHECK (interest_rating IS NULL OR interest_rating BETWEEN 1 AND 5);
ALTER TABLE job_processes ADD COLUMN money_rating INTEGER CHECK (money_rating IS NULL OR money_rating BETWEEN 1 AND 5);
ALTER TABLE job_processes ADD COLUMN growth_rating INTEGER CHECK (growth_rating IS NULL OR growth_rating BETWEEN 1 AND 5);

UPDATE job_processes
SET source_id = (
        SELECT id FROM sources WHERE name = job_processes.source COLLATE NOCASE
    ),
    applied_at = created_at;

CREATE TABLE compensations (
    id INTEGER PRIMARY KEY,
    process_id INTEGER NOT NULL,
    kind TEXT NOT NULL,
    amount_min INTEGER,
    amount_max INTEGER,
    currency TEXT,
    period TEXT,
    salary_type TEXT,
    confirmed INTEGER NOT NULL DEFAULT 0 CHECK (confirmed IN (0, 1)),
    notes TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(process_id, kind),
    CHECK (kind IN ('advertised', 'discussed', 'offer')),
    CHECK (amount_min IS NULL OR amount_max IS NULL OR amount_min <= amount_max),
    FOREIGN KEY(process_id) REFERENCES job_processes(id) ON DELETE CASCADE
);

INSERT INTO compensations(
    process_id, kind, amount_min, amount_max, currency, period,
    salary_type, confirmed, notes, created_at, updated_at
)
SELECT
    id, 'discussed', salary_amount_min, salary_amount_max,
    salary_currency, salary_period, salary_type, salary_discussed,
    salary_notes, created_at, updated_at
FROM job_processes
WHERE salary_discussed = 1
   OR salary_amount_min IS NOT NULL
   OR salary_amount_max IS NOT NULL
   OR COALESCE(salary_currency, '') <> ''
   OR COALESCE(salary_period, '') <> ''
   OR COALESCE(salary_type, '') <> ''
   OR COALESCE(salary_notes, '') <> '';

ALTER TABLE stages ADD COLUMN kind TEXT NOT NULL DEFAULT 'custom';
ALTER TABLE stages ADD COLUMN outcome TEXT;
ALTER TABLE stages ADD COLUMN outcome_reason TEXT;

UPDATE stages SET name = 'Applied', kind = 'applied' WHERE name = 'Resume sent';
UPDATE stages SET kind = 'applied' WHERE name = 'Applied';
UPDATE stages SET kind = 'hr' WHERE name IN ('Recruiter / HR interview', 'HR Interview');
UPDATE stages SET kind = 'technical' WHERE name IN ('Technical interview', 'Technical Interview');
UPDATE stages SET kind = 'system_design' WHERE name = 'System Design Interview';
UPDATE stages SET kind = 'cultural_fit' WHERE name IN ('Cultural fit interview', 'Cultural Fit');
UPDATE stages SET kind = 'cto' WHERE name = 'CTO Interview';
UPDATE stages SET kind = 'offer' WHERE name = 'Offer';

CREATE TABLE questions (
    id INTEGER PRIMARY KEY,
    process_id INTEGER NOT NULL,
    stage_id INTEGER,
    kind TEXT NOT NULL,
    question TEXT NOT NULL,
    answer TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    CHECK (kind IN ('company', 'learning')),
    FOREIGN KEY(process_id) REFERENCES job_processes(id) ON DELETE CASCADE,
    FOREIGN KEY(stage_id) REFERENCES stages(id) ON DELETE CASCADE
);

CREATE INDEX idx_questions_process ON questions(process_id, kind, created_at);
CREATE INDEX idx_questions_stage ON questions(stage_id, kind, created_at);
CREATE INDEX idx_compensations_process ON compensations(process_id, kind);
CREATE INDEX idx_processes_source ON job_processes(source_id);
