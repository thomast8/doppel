# Separate Chrome profiles

AI-written documentation; not human-reviewed.

Choose **Chrome Profiles → New Chrome Profile…** in Doppel and give the profile a name. Doppel opens the installed Google Chrome with a new data directory under its own Application Support folder. Cookies, site storage and extensions stay in that directory. Main Chrome's data, extension registrations and default-browser setting are not changed. Doppel does not clone or re-sign Chrome.

Install the official ChatGPT extension in the new Chrome window when Chrome asks. The ChatGPT Browser plugin must already be installed on this Mac: Doppel copies its native-host registration into only the managed profile and refreshes it each time you open that profile. If the host is missing or broken, Doppel reports an error rather than opening main Chrome. **Set Up Bridge…** opens the official extension listing again in that profile.

For one-time pairing, leave the Doppel connection tab open and choose **Copy Browser Instructions** from that profile's menu. Paste the instructions into your agent. They ask it to list connected extension browsers and their tabs, find the exact connection tab and return the matching extensionInstanceId. Paste that UUID into **Pair Bridge…**. Confirm that the matching tab belongs to this profile. Pairing is a user-confirmed mapping; Doppel cannot independently authenticate the UUID supplied by an agent.

After pairing, **Copy Browser Instructions** supplies the saved extension ID and requires the agent to select that exact bridge. Browser inventory IDs can change after restart, so they are never saved. The instructions tell the agent to stop when that identity is unavailable. Open the profile in Doppel to reconnect; normal browser restarts preserve the extension ID. Reinstalling the extension or clearing its storage may require pairing again. Profiles must be created fresh rather than copied from another user's browser.

Quit a profile normally in Chrome to preserve pending cookie writes. Doppel never terminates Chrome processes. The feasibility probe observed a freshly written cookie disappear after process termination; normal Quit preserved it. This feature separates browser data and provides explicit agent routing. Other agents with browser access can still select available bridges.

The first version provides create, open, bridge setup and pairing. It deliberately retains profile data and offers no delete action. Real site sign-in and extension upgrade recovery require further QA beyond the synthetic same-origin isolation and restart checks.
