# Pikes Peak Humanitix Resale Watcher

This watches the Humanitix resale page for Devils Playground tickets and emails you when a matching listing appears.

Use `Watch-PikesResale.ps1` on this Windows machine.

## Setup

1. Choose an SMTP-capable email account.
   - Gmail: create an app password at https://myaccount.google.com/apppasswords
   - Outlook/Hotmail: use `smtp-mail.outlook.com` with an app password if your account requires one.
2. Copy `.env.example` to `.env`.
3. Fill in:
   - `SMTP_HOST`
   - `SMTP_PORT`
   - `SMTP_USERNAME`
   - `SMTP_PASSWORD`
   - `EMAIL_FROM`
   - `EMAIL_TO`
4. Leave `POLL_MIN_SECONDS=30` and `POLL_MAX_SECONDS=120` to randomize checks between 30 seconds and 2 minutes.

The watcher uses built-in PowerShell commands only, so there are no packages to install.

## Commands

Send a test email:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Watch-PikesResale.ps1 -TestEmail
```

Check the resale page once without emailing:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Watch-PikesResale.ps1 -Once -NoEmail
```

Check once and show each ticket type/API result:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Watch-PikesResale.ps1 -Once -NoEmail -ShowDebug
```

Run continuously:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Watch-PikesResale.ps1
```

## Running In The Background On Windows

From this folder:

```powershell
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command "cd ''C:\Users\Jack\OneDrive - Georgia Institute of Technology\Code\Projects\Pikes''; .\Watch-PikesResale.ps1"'
```

## Notes

- The script writes `.pikes_resale_state.json` so it does not email you repeatedly for the same listing.
- If tickets disappear, the state resets. A new matching listing will send another email.
- Detection terms can be edited in `.env` if Humanitix changes the listing wording.
- The watcher queries Humanitix's resale API for each matching ticket type. It does not rely on raw page text alone.
- Continuous checks sleep for a random interval between `POLL_MIN_SECONDS` and `POLL_MAX_SECONDS`.
