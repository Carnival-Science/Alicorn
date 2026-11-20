# Syntax token contrast in generated themes

Stored channels are linear-sRGB and both hosts write them unchanged into a
non-sRGB swapchain, so **displayed** is what the user sees and **authored**
is the design intent recovered by sRGB-encoding the stored value.

## cool-light

Editor background `#f4f6fd`, body text `#020305` (19.11:1 text contrast), editor baseline (syntax `variable`) `#0a0f16`. Authored intent `#fafbfe` / `#121a26` (16.89:1).

| Token | Displayed | vs background | vs editor baseline | dE vs baseline | Authored | vs background (intent) | vs baseline (intent) | dE vs baseline (intent) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| keyword | `#1e113f` | 16.11:1 | 1.10:1 | 30.6 | `#604a88` | 7.17:1 | 1.34:1 | 33.5 |
| function | `#071733` | 16.49:1 | 1.08:1 | 17.3 | `#2f557c` | 7.49:1 | 1.28:1 | 17.5 |
| string | `#321406` | 15.70:1 | 1.13:1 | 23.7 | `#7a502b` | 6.74:1 | 1.42:1 | 42.4 |
| comment | `#162132` | 14.99:1 | 1.19:1 | 11.7 | `#53657a` | 5.78:1 | 1.66:1 | 14.3 |
| number | `#041a2c` | 16.35:1 | 1.09:1 | 11.0 | `#245a73` | 7.29:1 | 1.32:1 | 14.6 |
| type | `#041b24` | 16.38:1 | 1.09:1 | 8.0 | `#245c69` | 7.22:1 | 1.33:1 | 15.3 |
| constant | `#331204` | 15.82:1 | 1.12:1 | 24.9 | `#7c4b20` | 7.04:1 | 1.36:1 | 47.7 |
| variable | `#0a0f16` | 17.80:1 | 1.00:1 | 0.0 | `#384452` | 9.59:1 | 1.00:1 | 0.0 |

Pre-compensated projection (syntax tokens only; plain text unchanged):

| Token | Displays as | vs background | vs editor baseline | dE vs baseline |
| --- | --- | --- | --- | --- |
| keyword | `#604a88` | 6.87:1 | 2.59:1 | 47.9 |
| function | `#2f557c` | 7.17:1 | 2.48:1 | 37.7 |
| string | `#7a502b` | 6.46:1 | 2.75:1 | 49.3 |
| comment | `#53657a` | 5.54:1 | 3.21:1 | 39.1 |
| number | `#245a73` | 6.98:1 | 2.55:1 | 36.2 |
| type | `#245c69` | 6.92:1 | 2.57:1 | 35.7 |
| constant | `#7c4b20` | 6.74:1 | 2.64:1 | 52.8 |
| variable | `#384452` | 9.19:1 | 1.94:1 | 24.8 |

## warm

Editor background `#f0ebdb`, body text `#2b2b26` (11.93:1 text contrast), editor baseline (syntax `variable`) `#12120e`. Authored intent `#f8f6ef` / `#73736c` (4.42:1).

| Token | Displayed | vs background | vs editor baseline | dE vs baseline | Authored | vs background (intent) | vs baseline (intent) | dE vs baseline (intent) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| keyword | `#211132` | 14.79:1 | 1.06:1 | 27.4 | `#654a7a` | 6.90:1 | 1.16:1 | 37.5 |
| function | `#061630` | 15.11:1 | 1.04:1 | 22.1 | `#2b5278` | 7.52:1 | 1.07:1 | 31.8 |
| string | `#321204` | 14.39:1 | 1.09:1 | 20.1 | `#7a4b1f` | 6.81:1 | 1.18:1 | 33.2 |
| comment | `#1f2218` | 13.54:1 | 1.16:1 | 8.9 | `#626657` | 5.46:1 | 1.47:1 | 10.9 |
| number | `#041b22` | 14.86:1 | 1.06:1 | 11.4 | `#235c66` | 6.95:1 | 1.15:1 | 21.9 |
| type | `#051b14` | 15.01:1 | 1.05:1 | 9.5 | `#285c4f` | 7.10:1 | 1.13:1 | 19.6 |
| constant | `#2d0f01` | 14.92:1 | 1.06:1 | 18.2 | `#754411` | 7.49:1 | 1.07:1 | 36.8 |
| variable | `#12120e` | 15.74:1 | 1.00:1 | 0.0 | `#4c4c42` | 8.03:1 | 1.00:1 | 0.0 |

Pre-compensated projection (syntax tokens only; plain text unchanged):

| Token | Displays as | vs background | vs editor baseline | dE vs baseline |
| --- | --- | --- | --- | --- |
| keyword | `#654a7a` | 6.26:1 | 2.52:1 | 45.5 |
| function | `#2b5278` | 6.82:1 | 2.31:1 | 39.8 |
| string | `#7a4b1f` | 6.17:1 | 2.55:1 | 47.3 |
| comment | `#626657` | 4.95:1 | 3.18:1 | 37.7 |
| number | `#235c66` | 6.30:1 | 2.50:1 | 36.3 |
| type | `#285c4f` | 6.44:1 | 2.44:1 | 36.2 |
| constant | `#754411` | 6.80:1 | 2.32:1 | 48.8 |
| variable | `#4c4c42` | 7.28:1 | 2.16:1 | 27.0 |

## charcoal-ink

Editor background `#060607`, body text `#ccc2af` (11.48:1 text contrast), editor baseline (syntax `variable`) `#ccc2af`. Authored intent `#292c2f` / `#e7e2d8` (10.88:1).

| Token | Displayed | vs background | vs editor baseline | dE vs baseline | Authored | vs background (intent) | vs baseline (intent) | dE vs baseline (intent) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| keyword | `#88435f` | 2.91:1 | 3.95:1 | 53.9 | `#c18ca4` | 5.05:1 | 2.15:1 | 36.8 |
| function | `#356382` | 3.14:1 | 3.65:1 | 51.1 | `#7ea7bd` | 5.45:1 | 2.00:1 | 32.9 |
| string | `#657332` | 3.91:1 | 2.94:1 | 43.1 | `#a9b37a` | 6.30:1 | 1.73:1 | 32.2 |
| comment | `#3e4c3d` | 2.22:1 | 5.16:1 | 49.1 | `#879486` | 4.42:1 | 2.46:1 | 31.0 |
| number | `#545090` | 2.82:1 | 4.07:1 | 64.4 | `#9b98c6` | 5.15:1 | 2.11:1 | 39.9 |
| type | `#2e6764` | 3.13:1 | 3.67:1 | 46.0 | `#76aaa8` | 5.41:1 | 2.01:1 | 31.3 |
| constant | `#a6702e` | 4.80:1 | 2.39:1 | 45.2 | `#d3b176` | 6.90:1 | 1.58:1 | 33.7 |
| variable | `#ccc2af` | 11.48:1 | 1.00:1 | 0.0 | `#e7e2d8` | 10.88:1 | 1.00:1 | 0.0 |

Pre-compensated projection (syntax tokens only; plain text unchanged):

| Token | Displays as | vs background | vs editor baseline | dE vs baseline |
| --- | --- | --- | --- | --- |
| keyword | `#c18ca4` | 7.29:1 | 1.58:1 | 31.8 |
| function | `#7ea7bd` | 7.86:1 | 1.46:1 | 30.6 |
| string | `#a9b37a` | 9.08:1 | 1.26:1 | 23.1 |
| comment | `#879486` | 6.38:1 | 1.80:1 | 21.0 |
| number | `#9b98c6` | 7.43:1 | 1.55:1 | 38.4 |
| type | `#76aaa8` | 7.80:1 | 1.47:1 | 26.7 |
| constant | `#d3b176` | 9.95:1 | 1.15:1 | 24.8 |
| variable | `#e7e2d8` | 15.69:1 | 1.37:1 | 12.5 |
