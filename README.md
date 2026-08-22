# Notion Offline Batch Automator for macOS

Batch-mark the pages in a Notion database as **Available offline** with one keyboard shortcut.

This small Hammerspoon automation is intended for people who use the Notion desktop app in enterprise or corporate environments where a firewall, proxy, VPN, or network policy can make Notion unavailable or unreliable. Run it while Notion is reachable to prepare the pages you need before moving onto the restricted or disconnected network.

> [!IMPORTANT]
> This tool does not bypass a network restriction or an organizational security control. It only automates Notion's built-in **Available offline** switch. Follow your organization's policies and ask its IT team to allow Notion when appropriate.

## What it does

- Starts and stops with **Option + Command + O**.
- Begins with the database page currently open in Notion.
- Checks whether that page is already available offline.
- Leaves an already-offline page unchanged.
- Enables **Available offline** once when it is off.
- Moves to the next page in the current database view and repeats.
- Stops at the last page, on a repeated page, on an error, or at the 1,500-page safety limit.
- Shows running and final statistics:
  - **Total pages** — pages successfully checked.
  - **Already offline pages** — pages that needed no change.
  - **Newly offline ready pages** — pages enabled during this run.

The script is local macOS automation. It does not inject JavaScript into Notion, use the Notion API, send credentials, or make its own network requests.

## Requirements

- A Mac running macOS.
- The [Notion desktop app](https://www.notion.com/help/notion-for-desktop). Offline pages are not available in the web browser.
- [Hammerspoon](https://www.hammerspoon.org/).
- Hammerspoon permission to use macOS **Accessibility**.
- Hammerspoon permission for **Screen Recording** or **Screen & System Audio Recording**. The exact name depends on the macOS version.
- Notion's interface language set to English. The script currently looks for the labels `Actions` and `Available offline`.
- A Notion database page that opens in Side Peek or Center Peek.

## 1. Install Hammerspoon

1. Download Hammerspoon from the [official website](https://www.hammerspoon.org/) and move it into the macOS **Applications** folder.
2. Open Hammerspoon.
3. Open **System Settings → Privacy & Security → Accessibility** and enable Hammerspoon.
4. Open **System Settings → Privacy & Security → Screen Recording** (or **Screen & System Audio Recording**) and enable Hammerspoon.
5. Quit and reopen Hammerspoon if macOS does not apply the permissions immediately.
6. Optional: enable **Launch Hammerspoon at login** from the Hammerspoon menu-bar menu.

Hammerspoon's [Getting Started guide](https://www.hammerspoon.org/go/) has additional installation help.

## 2. Install the script

Clone this repository:

```sh
git clone https://github.com/YOUR-USERNAME/notion-offline-batch-macos.git
```

Create Hammerspoon's configuration folder if necessary:

```sh
mkdir -p ~/.hammerspoon
```

If `~/.hammerspoon/init.lua` already exists, back it up before continuing:

```sh
cp ~/.hammerspoon/init.lua ~/.hammerspoon/init.lua.backup
```

Copy this repository's script into place:

```sh
cp notion-offline-batch-macos/init.lua ~/.hammerspoon/init.lua
```

Then select **Reload Config** from the Hammerspoon menu-bar menu.

> [!WARNING]
> Copying the file replaces an existing Hammerspoon configuration. If you already use Hammerspoon for other automations, merge this script into your existing `init.lua` instead. Keep only one binding for **Option + Command + O**.

## 3. Test it on a small database view

Before processing a large database, create or filter a view containing two or three pages.

1. Open the Notion desktop app while the network can reach Notion.
2. Open the test database view.
3. Open its first page in **Side Peek** or **Center Peek**.
4. Leave Notion as the active application.
5. Press **Option + Command + O**.
6. Let the script finish without using the mouse or keyboard in Notion.
7. Review the final statistics shown by Hammerspoon.
8. Manually inspect the test pages or open **Notion Settings → Offline** to confirm that they are available offline.

Press **Option + Command + O** again at any time to stop the run safely.

## 4. Run it on all pages in a database view

1. Connect the Mac to a network on which the Notion desktop app works.
2. Open the database view you want to process, such as **All Tasks** or **All Projects**.
3. Apply the desired filters and sorting. The automation follows the page order of that view.
4. Open the first page in Side Peek or Center Peek.
5. Press **Option + Command + O** once.
6. Do not switch applications or interact with Notion while the batch is running.
7. Wait for the **Finished** notification, or press the same shortcut to stop early.
8. Give Notion time to finish downloading and syncing the selected pages before going offline.

The automation starts at the page you opened and proceeds forward. To cover the complete view, start on its first page.

## How it works

Hammerspoon runs the Lua code in `init.lua` and connects it to macOS system services:

1. macOS Accessibility exposes a structured description of Notion's visible interface.
2. The script finds the current peek window and its **Actions** control in that accessibility tree.
3. It uses the control's screen position to perform a normal mouse-style click and open the menu.
4. It finds the **Available offline** menu item and inspects the switch before changing anything.
5. If the switch is off, it invokes that item exactly once. If it is on, it closes the menu without pressing it.
6. It sends Notion's **Control + Shift + J** shortcut to open the next database page.
7. A page signature and polling loop confirm that the next page loaded before processing continues.

The script captures only the small rectangle containing the **Available offline** menu row, analyzes it in memory to read the switch color, and does not save the image.

## Configuration

The main timing and safety values are at the top of `init.lua`:

```lua
local MENU_WAIT_SECONDS = 0.7
local APPLY_WAIT_SECONDS = 1.1
local NEXT_POLL_SECONDS = 0.25
local NEXT_POLL_LIMIT = 24
local MAX_PAGES_PER_RUN = 1500
```

Slower Macs or workspaces may need slightly larger wait values. Change one value at a time and retest on a small database view.

The only user-facing hotkey binding is at the bottom of the file:

```lua
notionOfflineToggleHotkey = hs.hotkey.bind(
    { "alt", "cmd" },
    "O",
    toggleBatch
)
```

In Hammerspoon, `alt` means the Mac's **Option** key.

## Troubleshooting

### Nothing happens when I press the shortcut

- Confirm that Hammerspoon is running in the menu bar.
- Select **Reload Config** from its menu.
- Confirm that no other application or Hammerspoon script owns **Option + Command + O**.
- Open **Hammerspoon → Console** and look for an error.

### “Open the first database page in peek view”

- Use the Notion desktop app, not a browser.
- Open a page from a database in Side Peek or Center Peek before starting.
- Keep Notion as the frontmost application.

### “Actions button not found” or “Available offline not found”

- Confirm that Notion is using English interface labels.
- Confirm that the current item is a database page opened in peek view.
- Reload Hammerspoon and try again.
- A Notion interface update may have changed the accessibility labels used by the script.

### “Could not determine offline state”

- Enable Hammerspoon under macOS **Privacy & Security → Screen Recording** or **Screen & System Audio Recording**.
- Quit and reopen Hammerspoon after changing the permission.
- Keep the Actions menu visible and avoid moving the pointer or typing while the script runs.
- A change to Notion's colors or switch design may require adjustment to the pixel thresholds in `isOfflineEnabled()`.

### The batch stops before the expected last page

- Keep Notion active and do not navigate manually during the run.
- Check whether filters changed or the database view was reordered.
- For slow page loads, increase `NEXT_POLL_LIMIT` or `NEXT_POLL_SECONDS` slightly.
- Review the final toast and the Hammerspoon Console for the stop reason.

## Limitations and important Notion behavior

- This is a macOS-only automation for the Notion desktop app.
- It processes the current database view from the open page forward; it does not discover every database in a workspace.
- Making a parent page available offline does not automatically make all of its subpages available offline.
- Offline availability is device-specific. Run the process separately on each Mac that needs the pages.
- The content must be downloaded while Notion is reachable. If the active network completely blocks Notion, connect through an organization-approved network first.
- The script depends on Notion's current Accessibility labels, layout, colors, and keyboard shortcut. A Notion update could require changes.
- Notion may continue syncing or downloading after the automation finishes. Verify completion before disconnecting.
- Not every advanced Notion block or operation is supported offline.

See Notion's official documentation for [using pages offline](https://www.notion.com/help/use-pages-offline), [keyboard shortcuts](https://www.notion.com/help/keyboard-shortcuts), and [network-related error messages](https://www.notion.com/help/notion-error-messages).

## Privacy and security

- The script runs locally on the Mac.
- It does not collect analytics or transmit data.
- It does not contain Notion login details or tokens.
- The actual offline download and storage are handled by the Notion desktop app.
- Hammerspoon receives powerful Accessibility and screen-reading permissions, so review `init.lua` before enabling it and install only code you trust.

## Disclaimer

This is an unofficial community automation and is not affiliated with or endorsed by Notion or Hammerspoon. Use it on a small test view first and follow your organization's information-security and data-handling policies.

## Suggested GitHub repository details

- **Repository name:** `notion-offline-batch-macos`
- **Description:** `Batch-mark Notion database pages as available offline on macOS using Hammerspoon and Accessibility.`
- **Topics:** `notion`, `hammerspoon`, `lua`, `macos`, `accessibility`, `offline`, `automation`
- **Initial commit subject:** `feat: add Notion offline batch automation for macOS`

An MIT license is a common choice for a small open-source utility, but add a `LICENSE` file only after choosing the terms under which you want others to use and modify the project.
