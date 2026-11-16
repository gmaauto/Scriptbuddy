# VIGBT design review

`screen-review.html` is the interactive screen-approval page, published as a private artifact:
https://claude.ai/artifact/Rr6a9yfCtbh5gDYpj3a7qN

- **What it shows.** Each of the 16 iOS screens is mocked from the SwiftUI code using the app's
  contrast-tested palettes (`ThemePalette`). The page switches between the dark and light themes and
  between default, Large and Accessibility XL text sizes.
- **How to review.** For each screen, choose **Approve** or **Request changes** and leave a comment.
  Decisions are stored in the page's shared store (collection `reviews`, one document per screen), where
  Claude reads them.
- **Keep it in sync.** When the page changes, edit this file and republish it to the same link. The
  version shown on the page must match `VIGBT/VERSION`.

## Approval workflow and versioning (SPEC §10)

1. Claude reads the decisions from the review page.
2. Each **requested change** is made in the SwiftUI code and in the page's mock. That release gets a
   **patch** bump, for example 0.10.0 → 0.10.1, and a CHANGELOG entry naming the screen.
3. Each **approval** is recorded in `approvals.md` with its version. A batch of approvals with no code
   change still gets a patch bump, so the approved state can be referred to by version.
4. A new feature or an implemented **recommendation** (for example from the Monte Carlo study) gets a
   **minor** bump.
