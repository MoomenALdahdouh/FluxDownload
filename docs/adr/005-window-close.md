# ADR-005: Window close does not quit

## Status
Accepted

## Context
A download manager that dies when the last window closes cannot honor queues or schedules.

## Decision
`applicationShouldTerminateAfterLastWindowClosed` returns `false`. An optional menu bar extra remains. Full Quit flushes the database and cancels URLSession tasks. Launch at Login uses `SMAppService.mainApp`.

Schedules do **not** fire while the process is fully quit. A wake-on-schedule LaunchAgent is a later enhancement, not a fake.

## Consequences
- Closing the window continues downloads.
- Users must Quit to stop the engine.
- Onboarding explains this behavior.
