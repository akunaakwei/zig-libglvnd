# libglvnd
This is [libglvnd](https://gitlab.freedesktop.org/glvnd/libglvnd) packaged for the zig build system.

# generating code
libglvnd generates some code with python. These files are pregenerated and live in the `include` directory, so depending on this package does not require a python installation.  
After updating the upstream, you should regenerate the code. This command requires a `python3` executable in path.
```bash
zig build gen
```