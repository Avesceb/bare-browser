# Bare Browser Agent Instructions

The canonical working branch for this project is `andres-vesce-main`. For every user-requested fix, feature, or project change, switch to this branch before editing and commit and push the completed work to this branch. Do not use or merge into `dev` or `main` unless the user explicitly requests it.

When the user says "update app", switch to `andres-vesce-main`, pull every available change from its configured upstream, rebuild the app, replace the installed `/Applications/Lumen Browser.app`, and launch it to verify the update. Preserve local user data by replacing only the application bundle; do not delete or alter any application-support, preferences, cache, profile, or other user-data directories.

The installed application is the only persistent app copy to keep. Remove any generated `.app` bundle from `dist` after installation. If a `dist` app is needed temporarily for development, use it only temporarily and ensure it has a visibly different icon from the installed application.

Keep Picture-in-Picture hidden/disabled in the browser UI and web content.
