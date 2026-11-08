# TaskMate — Flutter Daily Planner

A clean, responsive day planner and to-do app built with Flutter. It is designed for desktop/web, tablet and mobile layouts.

## Features
- Month calendar with previous/next navigation, selected-day highlighting and task indicators.
- Daily task list with search and All / Pending / Completed filters.
- Create, edit and delete tasks with form validation.
- Due date, optional time, category (Personal / Work / Health), priority and notes.
- Animated completion checkbox and calendar selection; swipe a task left to delete it.
- Dashboard statistics and an Insights screen with completion progress.
- Responsive desktop sidebar, tablet/mobile navigation bar and adaptive content layout.
- Provider state management and SharedPreferences local persistence.
- Optional Firebase Authentication and per-user Firestore task sync.
- Reusable widgets and Material 3 theme.

## Run locally
Install Flutter (stable) and enable web support, then from this folder run:

```bash
flutter doctor
flutter config --enable-web
flutter pub get
flutter run -d chrome
```

## Enable cloud sync

Cloud sync stays disabled until Firebase is configured. Local task storage continues to work without Firebase.

1. Create a Firebase project in the Firebase console.
2. In Authentication, enable the Email/Password provider. Create a Cloud Firestore database.
3. Install and sign in to the Firebase CLI, then generate this project's platform options:

```bash
npm install -g firebase-tools
firebase login
dart pub global activate flutterfire_cli
dart pub global run flutterfire_cli:flutterfire configure
```

The configure command replaces `lib/firebase_options.dart` with project-specific settings. On Windows, the `dart pub global run` form works even when the global executable folder is not on `PATH`.

4. Publish the rules from `firestore.rules` in Firebase Console under Firestore Database > Rules. These rules restrict task access to the signed-in owner.
5. Run `flutter pub get` and restart the app. In Settings > Cloud sync, create an account or sign in. Existing local tasks are copied to the account on its first sign-in; subsequent task changes sync live between signed-in devices.

Do not deploy Firestore with open/test-mode rules. The Firebase configuration file contains public client identifiers, but Firestore security depends on authentication and the owner-only rules, not on keeping those identifiers secret.

## Build for submission
```bash
flutter build web
```
The deployable website is generated in `build/web/`.

## Project structure
```text
taskmate/
  lib/
    main.dart
  web/
    index.html
  pubspec.yaml
  analysis_options.yaml
  README.md
```

## Notes
- On first launch, a few sample tasks are added so the calendar and dashboard are not empty. You can edit or delete them.
- Planning preferences are saved locally too. The Settings screen includes working controls for completed-task visibility, week start, delete confirmation, clearing completed items and restoring defaults.
- Tasks are stored locally in the browser/device using SharedPreferences. This is a client-side student project; it does not sync across devices or use a cloud account.
- For screenshots, run the app in Chrome at desktop width, then resize the browser to tablet and mobile widths to demonstrate responsiveness.
