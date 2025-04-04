# Small utility to draw on screen. 

![image](https://github.com/user-attachments/assets/475bd9d5-c0b3-4813-8ce4-9ce323167a71)
![image](https://github.com/user-attachments/assets/b615b390-e052-454c-818d-2f139788bb91)

## How to build.
Download zig master at least version 0.14.0-dev.2316 https://ziglang.org/download/
```sh
git clone git@github.com:AndrewKraevskii/screen-drawer.git
zig build
```
Works on linux x11. Probably will work on Wayland (since uses raylib) but I haven't checked. On windows it works but shows black background instead of transparent.

## Keybindings
You can look at keybindings at start of src/main.zig and change them however you like. Default once are just for my setup with stylus. Also mouse wheel works in sketches preview.

## Where it stores images
It stores images in default location for apps to store data on your OS.
- linux => ~/.local/share/screen-drawer/
- windows => %LOCALAPPDATA%\\screen-drawer\\



## TODO
- [x] Vector image format
- [ ] Better keybindings (with support for both drawing pad and mouse)
- [ ] Add optional icons to show current drawing mode
- [ ] Bring gallery back
- [ ] Figure out file format versioning
- [ ] Do some testing
- [ ] Support of image importing using clipboard
- [x] Use bounding boxes to not draw strokes not in view
- [x] Draw grid
- [x] Since it's now vector format do infinite canvas
- [ ] Export canvases
- [ ] Regular drawing board mode?
- [x] Selecting and dragging drawings
