# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| 0.1.x   | yes |

Only the latest published release receives security fixes. Security
fixes are released as patch versions as soon as possible after a fix is
available.

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub
issues, discussions or pull requests.**

Instead, report them by email to:

**bilalahmed24.dev@gmail.com**

Please include as much of the following as you can:

- The type of issue and its potential impact.
- A minimal reproduction (a snippet, a project, or step-by-step
  instructions).
- Affected versions — the plugin version and, if relevant, the Flutter,
  Android and iOS versions involved.
- Any mitigations you have already identified.

You should receive an acknowledgment within a few business days. If you
have not heard back after a week, please follow up once — the maintainer
is human and mail occasionally gets lost.

## Scope

In scope:

- The plugin's runtime code: the Dart sources (`lib/`), the Android
  implementation (`android/`) and the iOS implementation
  (`ios/mic_recorder/Sources/`).
- The example app as shipped in this repository.
- The repository's GitHub workflows and publishing configuration.

Out of scope:

- Vulnerabilities in applications that *use* this plugin — report those
  to the app's maintainers.
- Vulnerabilities in Flutter, the Android SDK or Apple SDKs themselves —
  report those upstream.
- Things an app must do by design (recording audio with a user-granted
  permission, showing a foreground notification during background
  recording) are not vulnerabilities of the plugin.
- Volumetric scanning reports without a demonstrated impact.

## Disclosure

We ask for coordinated disclosure: please allow reasonable time for the
issue to be diagnosed and fixed before any public announcement. We will
credit reporters in the release notes unless they prefer to remain
anonymous.
