CREATE TABLE job_processes (
 id INTEGER PRIMARY KEY, company_name TEXT NOT NULL, position_name TEXT NOT NULL,
 job_url TEXT, source TEXT, location TEXT, work_arrangement TEXT,
 salary_discussed INTEGER NOT NULL DEFAULT 0 CHECK (salary_discussed IN (0,1)),
 salary_amount_min INTEGER, salary_amount_max INTEGER, salary_currency TEXT, salary_period TEXT, salary_type TEXT, salary_notes TEXT,
 status TEXT NOT NULL DEFAULT 'active', current_stage_id INTEGER, closure_reason_code TEXT, closure_reason_text TEXT,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, closed_at TEXT,
 CHECK (salary_amount_min IS NULL OR salary_amount_max IS NULL OR salary_amount_min <= salary_amount_max)
);
CREATE TABLE stages (id INTEGER PRIMARY KEY, process_id INTEGER NOT NULL, name TEXT NOT NULL, position INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'planned', started_at TEXT, completed_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, FOREIGN KEY(process_id) REFERENCES job_processes(id) ON DELETE CASCADE);
CREATE TABLE appointments (id INTEGER PRIMARY KEY, process_id INTEGER NOT NULL, stage_id INTEGER, title TEXT NOT NULL, starts_at TEXT NOT NULL, ends_at TEXT, meeting_url TEXT, contact_name TEXT, location TEXT, preparation_note TEXT, status TEXT NOT NULL DEFAULT 'scheduled', created_at TEXT NOT NULL, updated_at TEXT NOT NULL, FOREIGN KEY(process_id) REFERENCES job_processes(id) ON DELETE CASCADE, FOREIGN KEY(stage_id) REFERENCES stages(id) ON DELETE SET NULL);
CREATE TABLE notes (id INTEGER PRIMARY KEY, process_id INTEGER NOT NULL, stage_id INTEGER, category TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, FOREIGN KEY(process_id) REFERENCES job_processes(id) ON DELETE CASCADE, FOREIGN KEY(stage_id) REFERENCES stages(id) ON DELETE CASCADE);
CREATE TABLE activity_log (id INTEGER PRIMARY KEY, process_id INTEGER NOT NULL, activity_type TEXT NOT NULL, description TEXT NOT NULL, created_at TEXT NOT NULL, FOREIGN KEY(process_id) REFERENCES job_processes(id) ON DELETE CASCADE);
CREATE INDEX idx_stages_process ON stages(process_id, position);
CREATE INDEX idx_appointments_start ON appointments(starts_at);
CREATE INDEX idx_appointments_process ON appointments(process_id);
CREATE INDEX idx_notes_process_category ON notes(process_id, category);
CREATE INDEX idx_processes_status_updated ON job_processes(status, updated_at);
