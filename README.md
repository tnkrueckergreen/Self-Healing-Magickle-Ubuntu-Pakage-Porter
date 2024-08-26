# 🧙‍♂️ Self-Healing Magickle Ubuntu Pakage Porter

**Version**: `2.4`

## OvErview

The Self-Healing Magickle Ubuntu Pakage Porter is your trusty lil' helper when it comes to moving `.deb` pakages from one Ubuntu to another. It's like a magical transporter, except it deals with dependencies, errors, and all the annoying stuff you don't wanna do yourself. Who needs stress, amirite?

With this script, you can:
1. **Make Ported Pakage**: Grab a `.deb` pakage, collect all its lil' friends (dependencies), and bundle 'em up for moving.
2. **Instal Ported Pakage**: Take that bundle of pakages and plop 'em down on a newer Ubuntu like nothing ever happened. Easy peasy.

## Feetchurs

- **Automatic Dependancee Resolving**: This script is like Sherlock Holmes for pakage dependancees—solving 'em all!
- **Colorful and Happy Output**: 🌈 Who said terminal commands gotta be boring? Not this script!
- **Retryy Mechanism**: Stubborn command? No worries, this lil' guy will try, try again until it works (or throws its hands up in the air).
- **Errrrr Handling**: Catches errors like a pro juggler (and fixes conflicts, too!). You won't even know there was a problem.
- **Loggingg**: Writes down everything it does in case you wanna snoop later. All in the logz, my friend.
- **Portable!**: It bundles everything up nice and tidy, so you can take it anywhere. Like packing for vacation, but nerdier.

## Requirements (BoOoring)

- You need an **Ubuntu** system. If you don’t have one, you're in the wrong place, buddy. 🤔
- Gotta have `apt` installed for pakage management. (Duh.)

## Instalashun

You wanna use this magic? Download the script or clone the repo. (Don't forget to make it executable or it ain't doin' nothin'.)

```bash
git clone https://github.com/tnkrueckergreen/self-healing-package-porter.git
cd self-healing-package-porter
chmod +x pakage_porter.sh
```

## Usge

1. **Make Ported Pakage** (on ol' Ubuntu system):
   - Run this script on your ancient Ubuntu system, and watch it work its magic. Give it a `.deb` pakage, and it’ll grab all the dependancees and pack ‘em up like a pro.

   ```bash
   sudo ./pakage_porter.sh
   ```

   Then choose Option 1. It'll do the rest. 

2. **Instal Ported Pakage** (on new Ubuntu system):
   - Got your bundle of joy? Now take that ported pakage and use the script again on your shiny new Ubuntu. It'll instal the pakage and all its friends.

   ```bash
   sudo ./pakage_porter.sh
   ```

   Choose Option 2. BOOM, done. 🎉

## Example Workflow (AKA: How to Make This Thang Werk)

1. **On Your Ol' Ubuntu System**:

   - Run this magical spell to make a ported pakage:

     ```bash
     sudo ./pakage_porter.sh
     ```

     - Select “Make Ported Pakage.”
     - Give it the path to your `.deb` file (like a good lil' helper).
     - It’ll put everything in `/tmp/ubuntu_package_porter`. All safe and sound. 🛡️

   - Transfer that folder to your new system.

2. **On Your Shiny New Ubuntu System**:

   - Run the script again on your new system:

     ```bash
     sudo ./pakage_porter.sh
     ```

     - Select “Instal Ported Pakage.”
     - The script installs everything for you. 🎉

## Configguration

Wanna tinker with the settings? You’re brave. Just crack open the script and fiddle with these variables:

- **Log Fil Path**: Default is `/tmp/ubuntu_package_porter/package_porter.log`. You can change it if you want, but why bother?
- **Retryy Settings**: Tweak `MAX_RETRIES` and `RETRY_DELAY` to make the retry mechanism more or less annoying.

## Logs and Conflict Stuff

- **Log Fil**: `$PACKAGE_DIR/package_porter.log` is where all the dirty laundry is aired out.
- **Conflict Resolushuns**: If the script fights with itself about pakage versions, it writes its feelings down in `$PACKAGE_DIR/conflict_resolution.log`. Therapy not included.

## Cleanup (When Things Go Brrrr)

Sometimes things go wrong. Maybe the universe doesn't like you today. Don’t worry. The script is designed to clean up after itself. Think of it like a roomba for broken pakages:

- **Partial Installs**: It’ll try to fix things using `apt-get install -f`.
- **Failed Installs**: No shame in failure. The script logs the losers and moves on. Better luck next time, dependen-sees. 💁‍♂️

## License (Oh Boy, Here We Go)

This project is licensed under the MIT License, cuz we’re cool like that. Check out the [LICENSE](LICENSE) file for deets.

## Acknolodgments

Thanks for using the Self-Healing Magickle Ubuntu Pakage Porter! It’s been a pleasure bringing some magic to your pakage problems. May your installations be smooth, your dependencies be satisfied, and your terminals forever colorful. 🌈
