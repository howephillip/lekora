# Design system

Code: `app/Lekora/DesignSystem/`. Targets iOS 26 minimum (Liquid Glass), built with the iOS 27 SDK.

## Principle
Following Apple's guidance, **Liquid Glass is for the control layer** that floats above content: the message bar, buttons, status badges, toolbars, blocking progress. **Content uses solid surfaces**: message bubbles, cards, notices. This keeps chats calm and legible and the glass meaningful.

## Tokens (`LKTheme.swift`, namespace `LK`)
| Group | Values |
|---|---|
| `LK.Palette` | `accent` (system blue, like iMessage; the one place to change the brand colour), `onAccent`, `success`, `warning`, `danger` |
| `LK.Surface` | `base` (screen), `raised` (cards, notices), `inset` (agent bubbles, form fields), `accent` (user bubbles, solid). All adapt to dark mode. |
| `LK.Glass` | `bar` (badges, overlays), `control` (interactive, e.g. the composer field) |
| `LK.Typography` | `largeTitle`, `title`, `headline`, `body`, `callout`, `caption`, `captionStrong`, `footnote`, `code`. All Dynamic Type text styles. |
| `LK.Spacing` | 2, 4, 8, 12, 16, 24, 32 (`xxs` … `xxl`) |
| `LK.Radius` | `small` 10, `bubble` 20, `card` 22, `field` 22 |

## Components
| Component | Use |
|---|---|
| `lkScreenBackground()` | Every screen: base surface with a soft accent wash at the top |
| `LKCard`, `LKNotice` (progress / warning / info) | Grouped content and connection messages |
| `LKPrimaryButton` (glass prominent, accent), `LKSecondaryButton` (glass, optional destructive role) | Actions |
| `LKTextField` (`.surface` in forms, `.glass` in bars) | Text input |
| `LKStatusBadge` (connected / connecting / offline / problem) | Connection state on the Reconnecting screen. Not used in chat: "connected" is the normal state and needs no badge. |
| `LKMessageBubble` (user / agent, sending / failed) | Chat content |
| `LKComposer` | Message bar: glass field + send button in one `GlassEffectContainer`, placed with `safeAreaBar` so messages scroll under it with the system edge blur |
| `LKBlockingProgress` | "Forgetting host…" style overlays |

Previews of all of the above, plus the setup screen, are in `LKPreviews.swift` (checked in light, dark, and AX3 text size).

## Applied to
Setup wizard, Reconnecting screen, Chat (profile name as title, host as subtitle, a "…" menu with Forget Host in the toolbar; no connection badge, since any problem switches to the Reconnecting screen). The chat's debug "Seq #" counter is no longer shown.
