# Interview CRM

Interview CRM is a private, single-user job-search tracker that runs locally and stores its data in SQLite.

## Implemented

- Job processes with company and role details
- Company summaries and application dates
- Database-backed custom sources
- Interest, money, and growth ratings
- Advertised, discussed, and offer compensation snapshots
- Flexible interview stages and meaningful stage outcomes
- Stage notes
- Company and learning questions with answers
- Interview scheduling
- Appointment cancellation
- Permanent process deletion with cascading child-data cleanup

## Flexible workflow

Only the Applied stage is created automatically. Every later stage is optional, duplicate stage kinds are allowed, and stages can be added in the order used by the company. For example, both `Applied → Technical Interview → CTO Interview → Offer` and `Applied → HR Interview → Technical Interview → System Design Interview → Cultural Fit → Offer` are valid.

Stage outcomes keep the process and the individual interview history distinct. Applied and interview stages support Next step, Rejected, and Withdrawn. Offer supports Accepted, Declined, and Withdrawn. Completed history can be reopened to correct a mistake.

## Legacy migration

Databases created before Job Model V2 retain their existing processes, stage history, notes, appointments, activity entries, source values, and salary values. Existing source text is migrated into the `sources` table and existing salary information becomes a discussed compensation snapshot. The old source and salary columns remain physically present in SQLite for migration compatibility, but the application no longer reads or writes them.

## Not yet implemented

- Process-level categorized notes
- Day/week interview dashboard
- Appointment editing and rescheduling
- Stage reordering
- Notifications
- Calendar integration

## Technology

The application uses Zig 0.16, the system SQLite library, `zt` templates for server-rendered semantic HTML, progressively enhanced forms, embedded local assets, and pure CSS. HTMX 2.0.10 is vendored locally and embedded in the application binary; no CDN is used. There is no frontend JavaScript build, ORM, external database, cloud service, or authentication.

## Requirements

- Zig 0.16.0
- SQLite 3 development library and headers (`libsqlite3-dev` on Ubuntu; bundled with macOS/Homebrew SQLite)

## Build, test, and run

```sh
zig build
zig build fmt
zig build check
zig build test
zig build run
```

The server prints its URL and defaults to `http://127.0.0.1:7331`. A development database can be kept in the repository:

```sh
INTERVIEW_CRM_DATABASE=./data/interview-crm.sqlite zig build run
```

Configuration:

| Variable | Default |
| --- | --- |
| `INTERVIEW_CRM_ADDRESS` | `127.0.0.1` |
| `INTERVIEW_CRM_PORT` | `7331` |
| `INTERVIEW_CRM_DATABASE` | Platform data path below |

The default database is `~/Library/Application Support/InterviewCRM/interview-crm.sqlite` on macOS. Linux uses `$XDG_DATA_HOME/interview-crm/interview-crm.sqlite` when `XDG_DATA_HOME` is set, otherwise `~/.local/share/interview-crm/interview-crm.sqlite`. Parent directories are created automatically.

At every startup the app enables foreign keys and WAL, sets a five-second busy timeout, and applies embedded migrations transactionally before listening. Applied versions are recorded in `schema_migrations`; a migration failure stops startup.

Interview times are currently stored as local wall-clock times because Interview CRM is a local single-user application. Timezone-aware storage will be introduced if synchronization or remote access is added later.

## Current limitations

This release has no authentication and is intended only for a trusted local machine. The Today and This week dashboard queries, calendar synchronization, appointment rescheduling, notifications, analytics, and daemon packaging are not implemented yet.

## License

Copyright (c) 2026 Interview CRM contributors. Released under the [MIT License](LICENSE).
