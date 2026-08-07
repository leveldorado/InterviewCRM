# Interview CRM

Interview CRM is a private, single-user job-search tracker that runs locally and stores its data in SQLite. Version 0.1 provides job-process tracking and the core interview workflow.

## Implemented

- Job processes
- Default interview stages
- Custom stages
- Stage progression
- Stage notes
- Interview scheduling
- Appointment cancellation

## Not yet implemented

- Process-level categorized notes
- Day/week interview dashboard
- Appointment editing and rescheduling
- Stage reordering
- Rejection and withdrawal reasons UI
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

This release has no authentication and is intended only for a trusted local machine. The Today and This week dashboard queries are not implemented yet. Process deletion and daemon packaging are also not included.

## License

Copyright (c) 2026 Interview CRM contributors. Released under the [MIT License](LICENSE).
