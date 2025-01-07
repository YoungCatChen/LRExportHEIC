# Developing LRExportHEIC

## How does it work?

The plugin creates what the Lightroom SDK calls an “Export post-process action”
or an “Export Filter Provider”. As the name suggests, it allows the plugin to
run some code after Lightroom has completed the initial processing of the image.
Here is roughly what happens:

- Lightroom renders the image according to the user’s settings.
- This plugin (ExportHEIC) starts executing and is provided with a list of
  images and their export settings.
- ExportHEIC requests a different version of the image to be rendered into a
  temporary location. According to the Lightroom SDK guide, now it becomes the
  plugin’s responsibility to place the final image in the originally requested
  location.
  - The rendering that ExportHEIC requests will be either an 8-bit or a 16-bit
    TIFF depending on the bit-depth selected in the HEIC settings panel.
 - ExportHEIC uses a helper executable to render the temporary TIFF file created
   in the previous step into an HEIC file.
 - The HEIC file is placed at the originally requested location.
   - This is why it has to have a .jpg extension. If the file had a .heic
     extension instead, Lightroom would say that the export failed because it
     couldn’t find the final rendered file.

## Build for development / debugging purposes

Simply run `make debug`.

A quick build using `swift build` will start to build the swift files
under the `ConvertToHeic` directory, and a plugin with `.lrdevplugin`
will be generated under the `build-debug/` directory.
Lightroom Classic should be able to import it and use it.

Note that this plugin will only work on the computer that built it,
so it’s not suitable for distribution.
We didn’t do code-sign nor notarization in this debug build process,
while macOS’s default setting requires them to help with safety.
To build a package for distribution, see the section below.

## Build for distribution

TL;DR: Run this command, assuming the code-signing certificate and
the notarization credentials are stored in your Keychain:

```sh
TEAM_ID=1111YOUR1TEAM1ID \
STORED_CRED=abc \
make release
```

Or this command, if you have notarization credentials as an API key file:

```sh
TEAM_ID=1111YOUR1TEAM1ID \
API_KEY_ID=1111YOUR1KEY1ID \
API_KEY_ISSUER=11111111-2222-3333-4444-5555555555 \
API_KEY_PATH=/path/to/your/authkey.p8 \
make release
```

### Step 1: Make your code signing certificate ready

Code signing is a macOS security technology that you use to certify that an app
was created by you, and a Developer ID Application certificate
with a private key will be needed.
If you already have one and can find it in the Keychain Access app
(shown as `Developer ID Application: [Your Name]` with a private key under it),
you are good to go, and can skip this step.

If you don’t, follow
[this guide](https://developer.apple.com/help/account/create-certificates/create-developer-id-certificates/)
to create a Developer ID Application certificate.
Don’t forget to import the created certificate to your Keychain.

### Step 2: Make the notarization credentials ready

Notarization is a process that you submit your Developer ID-signed software
to Apple, which then scans it and performs security checks.
Follow one of these two options to get the credentials ready:

#### Step 2 option A: App Specific Password

Follow [this guide](https://support.apple.com/en-us/102654) to get an
App Specific Password. Then run

```sh
xcrun notarytool store-credentials abc --apple-id your_apple_id@some_mail.com --team-id 1111YOUR1TEAM1ID
```

When prompted, enter the password you just got.
The profile “abc” can be changed to other meaningful names.
Just remember to change `STORED_CRED=abc` accordingly later.

#### Step 2 option B: App Store Connect API key

Follow
[this guide](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api#Generate-a-Team-Key-and-Assign-It-a-Role)
to generate a Team Key.
When prompted to select a “Role” or an “Access”, choose “App Manager”.

Save the key as a `.p8` file, the key ID string and the key issuer string.

### Step 3: Make a release build!

`make release` is the general idea to make a release build for distribution.
It runs three actions internally - build a code-signed macOS app, notarization,
and package it with the Lightroom plugin in Lua.

The first action requires a code signing certificate.
Assuming the certificate is already imported into your Keychain,
you would need to specify via a environment variables which certificate to use.

```sh
export TEAM_ID=1111YOUR1TEAM1ID
```

The second action, notarization, needs to know notarization credentials.

```sh
# If you did Step 2 Option A:
export STORED_CRED=abc

# Or, if you did Step 2 Option B:
export API_KEY_ID=1111YOUR1KEY1ID
export API_KEY_ISSUER=11111111-2222-3333-4444-5555555555
export API_KEY_PATH=/path/to/your/authkey.p8
```

After all environment variables are set, you may make a release build with:

```sh
make release
## OR ##
make release-build     # to just build and code-sign the app
make release-notarize  # to run notarization (after an app is built)
make release           # to package up a Lightroom plugin
```

Note that environment variables can be set in the same line of the command
for convenience, for example:

```sh
TEAM_ID=1111YOUR1TEAM1ID SOME_OTHER=env_vars make release-build
```
