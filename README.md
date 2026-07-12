# LocalDrop

LocalDrop is a native macOS app for sharing files, folders, and text with nearby devices using the [LocalSend](https://github.com/localsend/localsend) protocol. No internet connection, cloud account, or external server is required.

Built with SwiftUI for macOS 14 and later.

## Features

- Discover nearby devices on the same Wi-Fi network.
- Send files, folders, and text to any LocalSend peer.
- Receive files with optional PIN protection.
- Browse transfer history and reveal received files in Finder.
- Run from the menu bar with optional launch-at-login.
- Localize the UI into one of 17 supported languages.

## User Guide

### Getting Started

1. Open LocalDrop on your Mac.
2. Make sure your Mac and the other device are connected to the same local network.
3. LocalDrop will show nearby LocalSend devices automatically.

### Sending Files

1. Click **Send**.
2. Select the device you want to send to from the discovered list.
3. Choose files, folders, or enter text to send.
4. If the receiver has PIN protection enabled, enter the PIN when prompted.
5. Wait for the transfer to complete.

### Receiving Files

1. Make sure **Receive** is turned on in LocalDrop.
2. Optionally enable PIN protection in Settings so senders must enter a PIN.
3. When a transfer request arrives, accept or decline it.
4. Accepted files are saved to your chosen download folder.

### Settings

- **Download folder**: Choose where received files are saved.
- **PIN protection**: Require a PIN before accepting incoming transfers.
- **Menu bar mode**: Keep LocalDrop accessible from the menu bar.
- **Launch at login**: Start LocalDrop automatically when you log in.
- **Language**: Change the app language.

### Tips

- Both devices must be on the same local network.
- Firewall or VPN settings may block device discovery.
- For best results, disable network isolation/client isolation on your router.

## License

MIT. See [LICENSE](LICENSE).

