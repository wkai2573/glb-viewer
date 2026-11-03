<img src="assets/icon.svg" alt="glb-viewer icon" width="96" align="right">

# glb-viewer

**English** | [繁體中文](README.zh-TW.md)

Preview 3D models directly on Windows by double-clicking `.glb` files, just like opening images. Windows File Explorer also displays thumbnails for `.glb` files directly.

- Lightweight standalone window: terminates completely when closed, leaving no background processes.
- Fully offline: models are processed locally and never uploaded. Connects to GitHub only when you click "Update" on the title bar to check for new versions.
- Per-user installation: installs under the current user profile without requiring administrator privileges.

## Installation

Paste this line into PowerShell to download and install from GitHub:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/wkai2573/glb-viewer/main/install.ps1).TrimStart([char]0xFEFF)))
```

Alternatively, clone/download the repository and run inside the project folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installation path is `%LOCALAPPDATA%\GlbViewer`. Running the installer again cleanly overwrites and updates the installation.

During installation, the thumbnail component is compiled using the system's built-in C# compiler and registered as the thumbnail provider for `.glb` files. See "Thumbnails and Icons" below for details.

### Set as Default Application

Windows does not permit applications to change file associations programmatically without user interaction, so you need to set it once manually:

1. Right-click any `.glb` file, select **Open with**, then choose **Choose another app**.
2. Select **GLB Viewer** and check **Always use this app to open .glb files**.

The installer automatically opens Windows Default Apps settings to assist you.

## Usage

Double-click any `.glb` file.
- **Left click & drag**: Rotate model
- **Scroll wheel**: Zoom in / out
- **Right click & drag**: Pan
- **Play Animation**: Appears in the title bar when the model contains animations.
- **Settings (⚙️)**: Open the settings dialog to switch language or check for updates.

### Lighting Effects

Click **Lighting** in the title bar to expand the right side panel:

- **Presets**: Studio, Noon, Rim, and Toon (one-click apply).
- **Display Modes**:
  - **Lit**: Retains original PBR materials with studio environment lighting and a directional light.
  - **Flat**: Unlit base color view to inspect textures directly.
  - **Toon**: Stylized three-tone cel-shading (highlight, midtone, shadow) with outlines.
- **Lighting Controls**: Adjust azimuth, elevation, brightness, and ambient intensity. Toon adds shadow threshold, highlight threshold, and outline thickness. When **Attach light to camera** is enabled, light direction is relative to your viewpoint.
- Hold **Shift** and drag on the canvas to freely rotate the light source.

Settings reset to "Studio" each time a file is opened.

A sample model `samples/triangle.glb` is included in the project for testing.

## Thumbnails and Icons

`.glb` files display preview thumbnails in File Explorer just like standard image files. Thumbnails are rendered by a lightweight native component compiled during installation, without opening the viewer or accessing the internet.

- Fixed view from the upper-front-right angle with a transparent background; models are automatically centered and fitted.
- Renders base color, vertex colors, base color textures, node transforms, and default poses of skinned skeletal meshes.
- Does not render normal maps, metallic-roughness, emissive, transparency, or alpha cutouts; cutouts (e.g. leaves, decals) appear solid.
- If a thumbnail cannot be generated (e.g. models compressed with Draco, Meshopt, KTX2, files > 100 MB, or generation exceeding ~4 seconds), File Explorer falls back to the `.glb` file icon without throwing errors.
- The file type icon is displayed when GLB Viewer is configured as the default handler.
- Windows caches thumbnails. If thumbnails do not show immediately after installation, clear the thumbnail cache in Disk Cleanup or restart Windows Explorer.

If another program already provides thumbnail handlers for `.glb`, the installer preserves existing settings and prints a notice. To override and use this project's thumbnail provider, re-run with `-ForceThumbnail`. The previous handler is remembered and automatically restored upon uninstallation:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -ForceThumbnail
```

## Updates

Click **Settings (⚙️)** in the title bar to open the settings dialog, which displays the current version and a **Check for Updates** button. Clicking it checks GitHub for the latest release:

1. When an update is available, click **Update** to begin downloading and installing.
2. Close and reopen the window once completed to start using the new version.
3. Does not check for updates automatically in the background.

Updates overwrite files in the installation folder and register or update thumbnail and icon handlers without altering your default file association. If a download fails or is incomplete, an error is reported and the existing installation remains untouched.

Thumbnail DLLs include version numbers in their filenames. If File Explorer holds a lock on the older DLL, the new version takes effect immediately, while older DLLs are cleaned up on the next installation or uninstallation.

Running directly from the repository source folder is treated as development mode, where updates are disabled.

## Uninstallation

Run the uninstaller one-liner in PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/wkai2573/glb-viewer/main/uninstall.ps1).TrimStart([char]0xFEFF)))
```

Or execute `uninstall.ps1` from the installation directory:

```powershell
& "$env:LOCALAPPDATA\GlbViewer\uninstall.ps1"
```

This removes the installation directory and registry entries (including thumbnail handlers). If Windows File Explorer locks the thumbnail DLL, the uninstaller leaves that file, displays its path, and permits manual deletion after logging out or restarting File Explorer.

## How It Works

- **Thumbnail Component**: Located in `src/GlbThumbnail.cs`. Compiled during installation via the built-in .NET Framework `csc.exe` into `GlbThumb_<version>.dll` and registered under current user `HKCU` using `CodeBase` as the `.glb` thumbnail provider. Features custom GLB parsing and software rasterization with zero browser dependencies.
- **Viewer**: Upon double-clicking, `GlbViewer.vbs` quietly spawns `GlbViewer.ps1`, which starts a temporary local HTTP server on a random port at `127.0.0.1`. It serves the viewer page, the model, and Three.js scripts, opening in a clean Microsoft Edge application window (or default browser if Edge is absent). The URL includes a random authorization token and validates request hosts. When the window is closed, the page sends a beacon notification to the server, and the server shuts down within seconds.

## Limitations

- Supports binary `.glb` files only (`.gltf` files with external assets are not supported).
- Models using Draco compression download Google's online Draco decoder and require internet connectivity.
- Models with KTX2 texture compression or Meshopt compression are not supported and will show an informative error message.
- Windows only. Requires Windows PowerShell 5.1 and .NET Framework 4 `csc.exe` (both pre-installed on Windows 10/11).

## Development and Testing

Run test suite:

```powershell
powershell -ExecutionPolicy Bypass -File .\test.ps1
```

Tests launch real Windows PowerShell instances to run the local server, verify behaviors over HTTP, and perform complete install, re-install, and uninstall runs in temporary directories and isolated test registry paths without affecting system settings.

Thumbnail tests are located in `test-thumbnail.ps1` and run as part of `test.ps1` (or standalone). They directly invoke the rasterizer to verify rendered PNG metrics without invoking File Explorer.

### Regenerate Icon

The vector icon source is at `assets/icon.svg`. After editing, run the following command to convert it via headless Edge into `src/GlbViewer.ico`:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\make-icon.ps1
```

### Releasing New Versions

Versions are defined in the root `VERSION` file as three digits (`X.Y.Z`). The update button checks this file on GitHub's `main` branch. To release a new version, bump `VERSION` and push to `main`.

During updates, the application downloads the repository archive from `main` and invokes `install.ps1 -InstallDir <dir> -UpdateOnly`. These parameters must remain backwards compatible.

## License

Released under the [MIT License](LICENSE).

Includes [three.js](https://github.com/mrdoob/three.js) r128 under the MIT License; see [src/three.LICENSE.txt](src/three.LICENSE.txt).
