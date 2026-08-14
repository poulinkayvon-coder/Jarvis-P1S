# Jarvis P1S

An iPhone-first Jarvis controller for a Bambu Lab P1S + AMS.

## Target workflow

“Hey Jarvis, find me a Benchy and print it in red using AMS slot 3.”

Jarvis:
1. Parses the command.
2. Searches for an already-prepared Bambu Studio 3MF print profile.
3. Filters for P1S-compatible profiles.
4. Reads the print's filament/color requirements.
5. Reads the AMS slot state.
6. Maps requested colors/materials to actual AMS slots, respecting an explicit slot request.
7. Shows a confirmation screen.
8. Uploads the prepared print job.
9. Starts the job only after confirmation.
10. Monitors status and reports progress.

## Important implementation boundary

This repository deliberately does not pretend that an arbitrary 3MF is automatically printable or that an undocumented printer command is guaranteed to work. The model provider and Bambu transport are isolated behind protocols so they can be implemented/tested against the user's actual P1S firmware.

## Current contents

- SwiftUI app skeleton
- Voice input
- Jarvis command parser
- 3MF-first model provider abstraction
- AMS slot/material/color models
- AMS mapping engine
- P1S transport abstraction
- Keychain storage
- GitHub Actions macOS build workflow
- Tests for command parsing and AMS mapping

## $0 development route

The GitHub repository should remain public. GitHub documents that standard GitHub-hosted macOS runners are free and unlimited for public repositories.

Apple's free Personal Team provisioning is separate: Apple says device provisioning expires after 7 days. The GitHub workflow therefore builds/tests the project, but it does not claim to magically create a permanent installable iPhone app.

## Never commit

Do not commit:
- Apple passwords
- Apple authentication tokens
- P1S access codes
- private certificates/provisioning profiles
- API keys
