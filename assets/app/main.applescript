-- DS3Bridge.app — starts DS3Bridge or runs one of its setup steps.
-- The programs, firmware and scripts live in Contents/Resources/DS3Bridge.

property docsURL : "https://github.com/comechejlg/DS3Bridge#readme"

on run
	set appPath to POSIX path of (path to me)
	set root to appPath & "Contents/Resources/DS3Bridge/"

	-- Files from a downloaded disk image carry macOS's quarantine flag, which would stop the
	-- command-line tools inside from running. The user has already approved this app.
	try
		do shell script "/usr/bin/xattr -dr com.apple.quarantine " & quoted form of appPath
	end try

	set addrFile to (POSIX path of (path to home folder)) & "Library/Application Support/DS3Bridge/adapter-address"
	set firstRun to ((do shell script "test -f " & quoted form of addrFile & " && echo no || echo yes") is "yes")

	if firstRun then
		showSetup(root, "Welcome! Set up DS3Bridge in this order (one step each time you open the app):")
	else
		set answer to display dialog "Plug in the USB Bluetooth adapter, start DS3Bridge and press PS on the controller." with title "DS3Bridge" buttons {"Setup…", "Quit", "Start"} default button "Start" cancel button "Quit" with icon (path to resource "applet.icns")
		if button returned of answer is "Setup…" then
			showSetup(root, "DS3Bridge setup:")
		else
			runScript(root, "Start DS3Bridge.command")
		end if
	end if
end run

on showSetup(root, promptText)
	set steps to {"1. Install the Karabiner driver (for OpenEmu)", "2. Install the keyboard service (asks for your password)", "3. Start DS3Bridge once (detects the Bluetooth adapter)", "4. Pair the controller (USB cable)", "Uninstall the keyboard service", "Read the documentation"}
	set choice to choose from list steps with title "DS3Bridge" with prompt promptText default items {item 1 of steps} OK button name "Run" cancel button name "Close"
	if choice is false then return
	set choice to item 1 of choice
	if choice starts with "1." then
		runScript(root, "Install Karabiner driver.command")
	else if choice starts with "2." then
		runScript(root, "Install service.command")
	else if choice starts with "3." then
		runScript(root, "Start DS3Bridge.command")
	else if choice starts with "4." then
		runScript(root, "Pair controller (USB cable).command")
	else if choice starts with "Uninstall" then
		runScript(root, "Uninstall service.command")
	else
		open location docsURL
	end if
end showSetup

on runScript(root, scriptName)
	do shell script "/usr/bin/open -a Terminal " & quoted form of (root & "scripts/" & scriptName)
end runScript
