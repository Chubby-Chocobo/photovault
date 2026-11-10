# 0.4.1 changelog notes

## Bug fixes

- Import from Google Drive: the Picker sign-in no longer fails with `Error 400: invalid_scope`. Google does not allow `drive.file` to be combined with another scope for the Picker, so the import now asks twice for the same account: first the Picker (`drive.file`), then "Step 2 of 2" to read the chosen folder (`drive.readonly`). Choosing a different account in step 2 is refused. Only the `drive.readonly` sign-in is kept for the import.

## Setup

No setup change beyond 0.4.0's: the OAuth consent screen keeps `drive.file`, `drive.readonly`, `openid` and `email`.
