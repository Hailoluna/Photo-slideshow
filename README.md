# Photo Slideshow

A full-screen photo and video slideshow that runs in the browser and works with no internet connection. Nothing is uploaded: your photos stay on your device.

**Open it:** https://hailoluna.github.io/Photo-slideshow/

## Ways to play your photos

| Source | How |
| --- | --- |
| A folder on your computer | Open the slideshow, click **Choose folder** |
| Google Drive | Download the folder from drive.google.com (you get a .zip), then click **Choose files or .zip**. No need to unzip. |
| Google Photos shared album | Use the Windows kit below. It syncs the album to your PC and plays it offline. |

## Google Photos on Windows

1. [Download the kit](https://github.com/Hailoluna/Photo-slideshow/archive/refs/heads/main.zip).
2. Right-click the zip, choose **Properties**, tick **Unblock**, then click **OK**. Extract it somewhere permanent, such as `Documents`.
3. In Google Photos, open your album and click **Share → Create link** (or **Copy link**).
4. Double-click **Start Slideshow.cmd** and paste the link when it asks.

Every time you start it, it downloads only new photos and videos, removes ones taken out of the album, and opens the slideshow full screen. With no internet it plays what's already downloaded. Press **Esc** for settings and **Alt+F4** to close.

- **More albums:** add one shared-album link per line to `albums.txt`.
- **Photo frame mode:** press **Win+R**, type `shell:startup`, and put a shortcut to **Start Slideshow.cmd** in that folder.

Google has no official way for apps to read a whole album, so the sync reads the album's shared-link page. If Google changes that page, syncing may stop until the script is updated; photos already downloaded keep playing.

## Controls

| Key | Action |
| --- | --- |
| Space | Pause / play |
| ← / → | Previous / next |
| F | Full screen |
| M | Sound on / off |
| I | Show file name and date |
| Esc | Settings |

On a touchscreen, swipe to change photos and tap to show the controls.

## Files

| File | Purpose |
| --- | --- |
| `slideshow.html` | The whole slideshow in one file |
| `index.html` | Sends the hosted site to `slideshow.html` |
| `sync-google-photos.ps1` | Downloads Google Photos shared albums into `Photos/` |
| `Start Slideshow.cmd` | Runs the sync, then opens the slideshow full screen in Edge |

`albums.txt` and `Photos/` are created on your PC and are never committed.
