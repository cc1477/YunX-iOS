# YunX iOS interface

The product is an iOS utility for opening shared links, browsing drives and managing downloads.
Use the existing Compose UI and business logic, with UIKit system text preferences.

- Use the platform font. Compose 1.8.2 maps its default sans-serif to `.AppleSystemUIFont` on iOS.
- Read Dynamic Type and Bold Text from UIKit; replace the text scale rather than multiplying it twice.
- Keep one compact page title and one primary action. Use a 4/8-point spacing rhythm and 20-point phone gutters.
- Use grouped neutral backgrounds, white grouped surfaces in light mode and dark grouped surfaces in dark mode.
- Use the same accessible blue accent throughout. Preserve theme and contrast settings.
- Settings opens with a short category list. Download tuning, network fields and credential backup belong in details.
- Inputs keep visible labels; errors stay beside the form and preserve the entered text.
- Use existing vector icons, visible pressed states, at least 44-point touch targets and safe-area insets.
- Respect large text, landscape, reduced motion and keyboard clearance. Avoid fixed-height text rows.
- Sharing accepts URL or share text and imports it when the user returns to YunX.

Sources: UI/UX Pro Max native accessibility/layout defaults, Apple Dynamic Type and grouped settings conventions,
and JetBrains Compose 1.8.2 `PlatformFont.skiko.kt`. The design-system search returned marketing-page patterns;
those layouts and external font recommendations are not used for this native utility.
