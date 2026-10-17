# Test Runways on your iPhone

You can run a development build on your phone without publishing to the App Store or paying for Apple Developer Program membership.

1. Connect the iPhone to the Mac with a data-capable cable. Unlock it and accept Trust This Computer if prompted.
2. In Xcode open Settings → Accounts and add your Apple Account.
3. Select your project, then the application target → Signing & Capabilities. Enable Automatically manage signing and choose your Personal Team. Use a unique bundle identifier such as `com.yourname.runways`.
4. Choose your actual iPhone as the run destination in Xcode's top toolbar, rather than an iOS simulator. Xcode may need to download device support or ask you to register the device.
5. If prompted, on the phone open Settings → Privacy & Security → Developer Mode, enable it and follow the restart/confirmation steps. Developer Mode may only appear after pairing with Xcode.
6. Press Command-R in Xcode. If iOS asks you to trust the developer, use Settings → General → VPN & Device Management and trust your Apple Account's development profile.
7. Launch Runways. The configured HTTPS Render backend works from the physical phone; the Mac does not need to run the backend. Reconnect Strava on this device and choose home again if needed. Saved routes and Keychain sessions in the simulator do not automatically transfer to the phone.

Free Personal Team signing normally expires after seven days, so reconnect to Xcode and rebuild when it expires. Paid membership is useful later for TestFlight/App Store distribution and longer-lived distribution options; it is not necessary for this initial personal test. TestFlight is not the same workflow as directly running a development build.

Confirm the `runways` URL scheme is still registered under the app target's Info → URL Types so Strava can return to the app. Backend redeployments currently discard server sessions and require reconnecting Strava; this is separate from Apple signing expiry.
